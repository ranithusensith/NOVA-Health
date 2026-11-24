import asyncio
import base64
from io import BytesIO
import json
import logging
from pathlib import Path
import shutil
import sys

from fastapi.testclient import TestClient
import httpx
from PIL import Image, ImageDraw, ImageFont, PngImagePlugin
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import ai_privacy
from db import DBError
import llm
import main
import safety


ACCOUNT = "00000000-0000-4000-8000-000000000001"
NAME = "Synthetic Patient"
EMAIL = "test-person@example.invalid"
BODY_MARKER = "SYNTHETIC-PROVIDER-ECHO"
CURRENT = ai_privacy.DISCLOSURE_VERSION


class FakeDB:
    user_id = ACCOUNT

    def __init__(self):
        self.version = CURRENT
        self.consent_down = False
        self.selections = []
        self.deleted = False
        self.delete_down = False

    async def select(self, table, columns, **kwargs):
        self.selections.append((table, columns, kwargs))
        if table == "ai_processing_consents":
            assert kwargs["filters"] == {"user_id": f"eq.{ACCOUNT}"}
            if self.consent_down:
                raise DBError(BODY_MARKER)
            return [{"disclosure_version": self.version}] if self.version else []
        if table == "profiles":
            return [{"full_name": NAME, "conditions": []}]
        if table == "lab_results":
            return [{
                "test_name": "Haemoglobin",
                "value": None,
                "unit": "g/dL",
                "reported_on": "2025-01-04",
                "value_text": "<=12.10",
                "extracted_value_text": "<=12.50",
                "reference_text": ">=13.0",
                "reported_flag": "L",
                "test_notes": "unexpected id",
            }]
        return []

    async def insert(self, *_):
        pytest.fail("C4 AI processing must not persist chat messages or photos")

    async def set_ai_consent(self, version):
        self.version = version

    async def delete_legacy_ai_chats(self):
        if self.delete_down:
            raise DBError(BODY_MARKER)
        self.deleted = True
        return 2


@pytest.fixture
def harness(monkeypatch):
    monkeypatch.setenv("AI_PRIVACY_PROVIDER_APPROVAL", "gemini-reviewed-paid")
    monkeypatch.setenv("LLM_API_KEY", "synthetic-test-key")
    monkeypatch.setenv("LLM_MODEL", "gemini-fixture")
    db = FakeDB()
    requests = []
    replies = []

    async def provider(_, url, **kwargs):
        assert url.startswith(llm.BASE_URL + "/") and url.endswith(":generateContent")
        requests.append(kwargs["json"])
        response = replies.pop(0) if replies else {"action": "final", "answer": "Fixture answer."}
        if isinstance(response, Exception):
            raise response
        if isinstance(response, httpx.Response):
            return response
        return httpx.Response(200, json={
            "candidates": [{"content": {"parts": [{"text": json.dumps(response)}]}}],
        })

    async def no_network(*_, **__):
        pytest.fail("Unexpected network call")

    monkeypatch.setattr(httpx.AsyncClient, "post", provider)
    monkeypatch.setattr(httpx.AsyncClient, "get", no_network)
    monkeypatch.setattr(httpx.AsyncClient, "delete", no_network)
    main.app.dependency_overrides[main.current_user] = lambda: {"id": ACCOUNT, "email": EMAIL}
    main.app.dependency_overrides[main.get_db] = lambda: db
    main._scan_counts.clear()
    main._chat_counts.clear()
    try:
        with TestClient(main.app) as client:
            yield client, db, requests, replies
    finally:
        main.app.dependency_overrides.clear()


def chat(client, **overrides):
    return client.post("/api/v1/assistant/chat", json={
        "message": "How much water did I drink?", "reviewed": True, **overrides,
    })


def photo(*, rich=False):
    image = Image.new("RGB", (80, 40), "white")
    out = BytesIO()
    metadata = PngImagePlugin.PngInfo()
    if rich:
        metadata.add_text("Comment", NAME)
        metadata.add_itxt("XML:com.adobe.xmp", EMAIL)
    exif = Image.Exif()
    if rich:
        exif[274] = 6
        exif[315] = NAME
        exif[34853] = {1: "N", 2: (1.0, 2.0, 3.0)}
    image.save(out, format="PNG", pnginfo=metadata, exif=exif if rich else b"")
    return out.getvalue()


@pytest.mark.parametrize("condition, status", [
    ("disabled", 503), ("no_key", 503), ("invalid_model", 503), ("absent", 403), ("stale", 403), ("db_down", 503),
])
def test_every_ai_route_fails_closed(harness, monkeypatch, condition, status):
    client, db, requests, _ = harness
    if condition == "disabled":
        monkeypatch.delenv("AI_PRIVACY_PROVIDER_APPROVAL")
    elif condition == "no_key":
        monkeypatch.delenv("LLM_API_KEY")
    elif condition == "invalid_model":
        monkeypatch.setenv("LLM_MODEL", "../unexpected")
    elif condition == "absent":
        db.version = None
    elif condition == "stale":
        db.version = "old-version"
    else:
        db.consent_down = True

    responses = [
        chat(client),
        client.post("/api/v1/scan/prescription", json={"text": "Paracetamol", "reviewed": True}),
        client.post("/api/v1/scan/report", json={"text": "Haemoglobin 12.1", "reviewed": True}),
        client.post("/api/v1/scan/food", data={"reviewed": "true"}, files={"image": ("scan", photo())}),
        client.post("/api/v1/scan/medical-text", files={"image": ("scan", photo())}),
    ]
    assert all(res.status_code == status and res.headers["cache-control"] == "no-store" for res in responses)
    assert all(BODY_MARKER not in res.text for res in responses)
    assert not requests


def test_consent_requires_current_disclosure_and_can_be_revoked(harness, monkeypatch):
    client, db, requests, _ = harness
    db.version = None
    assert client.get("/api/v1/privacy/ai").json()["data"] == {
        "enabled": False, "provider_available": True, "disclosure_version": CURRENT,
    }
    assert client.post("/api/v1/privacy/ai", json={"enabled": True, "disclosure_version": "old"}).status_code == 409
    assert chat(client).status_code == 403
    assert client.post("/api/v1/privacy/ai", json={"enabled": True, "disclosure_version": CURRENT}).status_code == 200
    assert chat(client).status_code == 200
    monkeypatch.delenv("AI_PRIVACY_PROVIDER_APPROVAL")
    assert client.post("/api/v1/privacy/ai", json={"enabled": False}).status_code == 200
    assert db.version is None
    assert chat(client).status_code == 503
    assert len(requests) == 1


def test_each_provider_call_rechecks_consent_before_retry(harness, monkeypatch):
    client, db, _, _ = harness
    calls = 0

    async def malformed_response(*_, **__):
        nonlocal calls
        calls += 1
        db.version = None
        return httpx.Response(200, json={"candidates": [{"content": {"parts": [{"text": "not-json"}]}}]})

    monkeypatch.setattr(httpx.AsyncClient, "post", malformed_response)
    assert chat(client).status_code == 403
    assert calls == 1


def test_no_client_side_consent_bypass_or_implicit_review(harness):
    client, _, requests, _ = harness
    assert chat(client, reviewed=False).status_code == 400
    assert client.post("/api/v1/scan/prescription", json={"text": "medicine", "reviewed": False}).status_code == 400
    assert client.post("/api/v1/scan/report", files={"image": ("should-not-upload", photo())}).status_code == 422
    assert client.post("/api/v1/scan/food", files={"image": ("photo", photo())}).status_code == 400
    with pytest.raises(ai_privacy.PrivacyError):
        asyncio.run(llm.generate_json("Unapproved request"))
    assert not requests


def test_assistant_redacts_questions_and_does_not_replay_legacy_chats(harness):
    client, db, requests, replies = harness
    replies.extend([
        {"action": "tool", "tool": "get_lab_results", "args": {"id": BODY_MARKER}},
        {"action": "final", "answer": f"Hello {NAME}, here is some guidance."},
    ])
    result = chat(
        client, message=f"I'm {NAME}. My email is {EMAIL}. What is sleep?",
        recent_questions=[f"Patient ID: SECR-123; my name is Third Party, is rest helpful?"],
    )
    assert result.status_code == 200
    assert NAME not in result.text
    for request in requests:
        outbound = json.dumps(request)
        assert all(secret not in outbound for secret in (NAME, EMAIL, ACCOUNT, "Third Party", "SECR-123", BODY_MARKER))
        assert "is rest helpful" in outbound
    assert [table for table, _, _ in db.selections if table not in ("profiles", "ai_processing_consents")] == []


def test_assistant_only_uses_selected_tools_and_minimizes_results(harness):
    client, db, requests, replies = harness
    replies.extend([
        {"action": "tool", "tool": "get_medications"},
        {"action": "tool", "tool": "get_lab_results", "args": {"id": BODY_MARKER}},
        {"action": "final", "answer": "Talk to a clinician about your results."},
    ])
    assert chat(client, health_data=["lab_results"]).status_code == 200
    final_prompt = json.dumps(requests[-1])
    assert all(text in final_prompt for text in ("Haemoglobin", "<=12.10", ">=13.0", 'L'))
    assert all(secret not in final_prompt for secret in
               ("2025-01-04", "<=12.50", "unexpected id", "get_medications", BODY_MARKER))
    assert [table for table, _, _ in db.selections if table not in ("profiles", "ai_processing_consents")] == ["lab_results"]


@pytest.mark.parametrize("kind, result, clinical", [
    ("prescription", {
        "is_prescription": True, "medications": [{
            "name": "Paracetamol", "frequency": "Every 8 hours", "duration_text": "until 2025-12-10",
        }],
    }, "Paracetamol 500 mg every 8 hours until 2025-12-10"),
    ("report", {
        "is_report": True, "results": [{"test": "Haemoglobin", "value_text": "12.1", "unit": "g/dL",
                                        "source_line": "Haemoglobin 12.1 g/dL 13.0 - 17.0"}],
    }, "Haemoglobin 12.1 g/dL 13.0 - 17.0"),
])
def test_medical_scans_only_send_reviewed_scrubbed_text(harness, kind, result, clinical):
    client, _, requests, replies = harness
    replies.append(result)
    raw = f"Patient name: {NAME}\nDOB: 1980-01-01\nDoctor: Synthetic Doctor\n{clinical}\nMRN: X-4455\n{EMAIL}"
    response = client.post(f"/api/v1/scan/{kind}", json={"text": raw, "reviewed": True})
    assert response.status_code == 200
    parts = requests[0]["contents"][0]["parts"]
    assert list(parts[0]) == ["text"] and len(parts) == 1
    assert clinical in parts[0]["text"]
    assert all(secret not in parts[0]["text"] for secret in (NAME, EMAIL, "Synthetic Doctor", "X-4455", "1980-01-01"))
    if kind == "prescription":
        assert response.json()["data"]["safety_check_status"] == "completed"
        assert response.json()["data"]["medications"][0]["duration_text"] == "until 2025-12-10"


def test_ocr_uses_only_local_process_and_returns_a_scrubbed_draft(harness, monkeypatch):
    client, _, requests, _ = harness

    def run(command, *, input, **kwargs):
        assert command[0] == "tesseract" and command[1:3] == ["stdin", "stdout"]
        assert kwargs["timeout"] == 15
        assert "LLM_API_KEY" not in kwargs["env"]
        with Image.open(BytesIO(input)) as image:
            assert not image.getexif()
            assert not image.info
        return type("Result", (), {"stdout": f"Patient name: {NAME}\nParacetamol 500 mg\n{EMAIL}".encode()})()

    monkeypatch.setattr(ai_privacy.subprocess, "run", run)
    response = client.post("/api/v1/scan/medical-text", files={"image": ("fixture", photo(rich=True))})
    assert response.status_code == 200
    assert "Paracetamol 500 mg" in response.json()["data"]["text"]
    assert NAME not in response.text and EMAIL not in response.text
    assert not requests


@pytest.mark.skipif(not shutil.which("tesseract"), reason="local Tesseract is not installed")
def test_local_ocr_reads_a_generated_image():
    image = Image.new("RGB", (800, 210), "white")
    draw = ImageDraw.Draw(image)
    draw.text((20, 60), "Haemoglobin 12.1 g/dL", fill="black", font=ImageFont.load_default(size=52))
    output = BytesIO()
    image.save(output, format="PNG")
    assert "12.1" in asyncio.run(ai_privacy.extract_medical_text(output.getvalue()))


def test_ocr_failure_does_not_fall_back_to_provider(harness, monkeypatch):
    client, _, requests, _ = harness

    def fail(*_, **__):
        raise OSError(BODY_MARKER)

    monkeypatch.setattr(ai_privacy.subprocess, "run", fail)
    response = client.post("/api/v1/scan/medical-text", files={"image": ("fixture", photo())})
    assert response.status_code == 503 and response.json()["error"]["code"] == "OCR_UNAVAILABLE"
    assert BODY_MARKER not in response.text
    assert not requests


def test_food_pixels_are_reencoded_and_metadata_is_removed(harness):
    client, _, requests, replies = harness
    replies.append({"is_food": True, "description": "Rice", "calories": 200})
    response = client.post("/api/v1/scan/food", files={"image": (NAME, photo(rich=True))}, data={"reviewed": "true"})
    assert response.status_code == 200
    inline = requests[0]["contents"][0]["parts"][0]["inline_data"]
    clean = base64.b64decode(inline["data"])
    assert inline["mime_type"] == "image/jpeg"
    assert all(secret.encode() not in clean for secret in (NAME, EMAIL))
    with Image.open(BytesIO(clean)) as image:
        assert image.size == (40, 80)
        assert not image.getexif()
        assert not ({"exif", "xmp", "icc_profile", "comment"} & image.info.keys())


def test_invalid_or_oversized_pixel_payload_does_not_go_to_google(harness):
    client, _, requests, _ = harness
    oversized = BytesIO()
    Image.new("RGB", (4000, 10), "white").save(oversized, format="PNG")
    for data in (oversized.getvalue(), b"\x89PNG\r\n\x1a\ntruncated"):
        response = client.post("/api/v1/scan/food", files={"image": ("scan", data)}, data={"reviewed": "true"})
        assert response.status_code == 400
    assert not requests


@pytest.mark.parametrize("failure,status,code", [
    ("rejected", 502, "AI_REQUEST_REJECTED"),
    ("bad_json", 502, "AI_RESPONSE_INVALID"),
    ("network", 503, "AI_UNAVAILABLE"),
])
def test_provider_errors_and_logs_contain_no_sensitive_payload(harness, caplog, failure, status, code):
    client, _, _, replies = harness
    caplog.set_level(logging.WARNING)
    if failure == "rejected":
        replies.append(httpx.Response(400, text=BODY_MARKER))
    elif failure == "bad_json":
        replies.extend([httpx.Response(200, json={
            "candidates": [{"content": {"parts": [{"text": '{"secret":"' + BODY_MARKER}]}}],
        })] * 2)
    else:
        replies.append(httpx.ReadTimeout(BODY_MARKER))
    res = chat(client, message=f"I am {NAME}, {EMAIL}")
    assert res.status_code == status and res.json()["error"]["code"] == code
    assert all(secret not in res.text + caplog.text for secret in (BODY_MARKER, NAME, EMAIL))
    assert "LLM" in caplog.text


def test_legacy_delete_reports_verified_result_even_with_ai_disabled(harness, monkeypatch):
    client, db, requests, _ = harness
    monkeypatch.delenv("AI_PRIVACY_PROVIDER_APPROVAL")
    response = client.delete("/api/v1/privacy/ai/chats")
    assert response.json() == {"data": {"deleted": 2}} and db.deleted
    db.delete_down = True
    response = client.delete("/api/v1/privacy/ai/chats")
    assert response.status_code == 503 and BODY_MARKER not in response.text
    assert not requests


def test_emergency_chat_and_daily_report_work_without_external_ai(harness, monkeypatch):
    client, db, requests, _ = harness
    db.version = None
    monkeypatch.delenv("AI_PRIVACY_PROVIDER_APPROVAL")
    local = chat(client, message="I can't breathe", reviewed=False)
    assert local.status_code == 200 and local.json()["data"]["emergency"]
    daily = client.get("/api/v1/reports/daily")
    assert daily.status_code == 200 and daily.json()["data"]["ai"] is False
    assert not requests


def test_redaction_keeps_clinical_intervals_ranges_and_duration_dates():
    source = "Clinical: 500 mg every 8 hours. Until 2025-12-10. Ref. 13.0 - 17.0"
    assert safety.redact(source) == source


def test_food_image_with_identifying_text_is_blocked(harness, monkeypatch):
    client, _, requests, _ = harness
    monkeypatch.setattr(ai_privacy, "_ocr_text", lambda _: f"Patient name: {NAME}")
    response = client.post("/api/v1/scan/food", files={"image": ("fixture", photo())}, data={"reviewed": "true"})
    assert response.status_code == 400
    assert NAME not in response.text
    assert not requests


def test_unexpected_provider_result_does_not_surface_a_sensitive_trace(harness, caplog):
    client, _, _, replies = harness
    replies.append({"is_prescription": True, "medications": 1, "notes": BODY_MARKER})
    response = client.post("/api/v1/scan/prescription", json={"text": "Paracetamol", "reviewed": True})
    assert response.status_code == 502 and response.json()["error"]["code"] == "AI_RESPONSE_INVALID"
    assert BODY_MARKER not in response.text + caplog.text
