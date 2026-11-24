"""Exercise API error contracts with synthetic upstreams only."""

import json

import httpx
import pytest
from fastapi.testclient import TestClient

import ai_privacy
import llm
import main

ACCOUNT = "00000000-0000-4000-8000-000000000801"
MARKER = "SYNTHETIC-PRIVATE-ERROR-MARKER"
AUTH = {"Authorization": "Bearer synthetic-session"}
CHAT = {"message": "Synthetic question", "reviewed": True}


def provider_response(model_output):
    return httpx.Response(200, json={
        "candidates": [{"content": {"parts": [{"text": json.dumps(model_output)}]}}],
    })


@pytest.fixture
def upstreams(monkeypatch):
    url = "https://supabase.invalid"
    key = "sb_publishable_synthetic"
    monkeypatch.setattr(main, "SUPABASE_URL", url)
    monkeypatch.setattr(main, "SUPABASE_PUBLISHABLE_KEY", key)
    monkeypatch.setenv("SUPABASE_URL", url)
    monkeypatch.setenv("SUPABASE_PUBLISHABLE_KEY", key)
    monkeypatch.setenv("AI_PRIVACY_PROVIDER_APPROVAL", "gemini-reviewed-paid")
    monkeypatch.setenv("LLM_API_KEY", "synthetic-fixture-key")
    monkeypatch.setenv("LLM_MODEL", "gemini-fixture")
    main._scan_counts.clear()
    main._chat_counts.clear()
    requests = []
    responses = {
        "/auth/v1/user": httpx.Response(200, json={"id": ACCOUNT}),
        "/rest/v1/ai_processing_consents": httpx.Response(200, json=[{
            "disclosure_version": ai_privacy.DISCLOSURE_VERSION,
        }]),
        "/rest/v1/profiles": httpx.Response(200, json=[{"full_name": "Synthetic User"}]),
        "provider": provider_response({"action": "final", "answer": "Synthetic answer."}),
    }

    async def send(_, request, **kwargs):
        assert request.url.host in {"supabase.invalid", "generativelanguage.googleapis.com"}
        if request.url.host == "supabase.invalid":
            assert request.headers["Authorization"] == AUTH["Authorization"]
            destination = request.url.path
            if destination.startswith("/rest/v1/"):
                owner = "id" if destination.endswith("/profiles") else "user_id"
                assert request.url.params[owner] == f"eq.{ACCOUNT}"
        else:
            assert request.headers["x-goog-api-key"] == "synthetic-fixture-key"
            destination = "provider"
        requests.append(destination)
        result = responses.get(destination, httpx.Response(200, json=[]))
        if isinstance(result, Exception):
            raise result
        return result

    monkeypatch.setattr(httpx.AsyncClient, "send", send)
    return TestClient(main.app), responses, requests


def assert_error(response, status, code, caplog):
    assert response.status_code == status
    assert response.headers["Cache-Control"] == "no-store"
    data = response.json()
    assert set(data) == {"error"} and set(data["error"]) == {"code", "message"}
    assert data["error"]["code"] == code and data["error"]["message"]
    assert MARKER not in response.text + caplog.text
    assert AUTH["Authorization"] not in response.text + caplog.text


@pytest.mark.parametrize("auth_response,status,code", [
    (httpx.Response(401, text=MARKER), 401, "UNAUTHORIZED"),
    (httpx.Response(403, text=MARKER), 401, "UNAUTHORIZED"),
    (httpx.Response(429, text=MARKER), 503, "AUTH_UNAVAILABLE"),
    (httpx.Response(503, text=MARKER), 503, "AUTH_UNAVAILABLE"),
    (httpx.ConnectTimeout(MARKER), 503, "AUTH_UNAVAILABLE"),
    (httpx.Response(200, text=MARKER), 502, "AUTH_RESPONSE_INVALID"),
    (httpx.Response(200, json=[{"id": ACCOUNT}]), 502, "AUTH_RESPONSE_INVALID"),
    (httpx.Response(200, json={"id": MARKER}), 502, "AUTH_RESPONSE_INVALID"),
    (httpx.Response(200, json={"id": ACCOUNT, "user_metadata": [MARKER]}), 502, "AUTH_RESPONSE_INVALID"),
])
def test_auth_failures_are_distinct_and_fail_closed(upstreams, caplog, auth_response, status, code):
    client, responses, requests = upstreams
    responses["/auth/v1/user"] = auth_response
    response = client.post("/api/v1/assistant/chat", headers=AUTH, json=CHAT)
    assert_error(response, status, code, caplog)
    assert requests == ["/auth/v1/user"]
    if status == 401:
        assert response.headers["WWW-Authenticate"] == "Bearer"


def test_invalid_authorization_header_never_leaves_api(upstreams, caplog):
    client, _, requests = upstreams
    response = client.post("/api/v1/assistant/chat", headers=[(b"Authorization", b"Bearer \xe9")], json=CHAT)
    assert_error(response, 401, "UNAUTHORIZED", caplog)
    assert not requests


def test_multipart_parser_does_not_log_an_untrusted_header(upstreams, caplog):
    client, _, requests = upstreams
    body = (
        '--fixture\r\nContent-Disposition: form-data; name="image"; filename="fixture"\r\n'
        f'!{MARKER}\r\n\r\nsynthetic\r\n--fixture--\r\n'
    ).encode()
    response = client.post(
        "/api/v1/scan/food",
        headers={**AUTH, "Content-Type": "multipart/form-data; boundary=fixture"},
        content=body,
    )
    assert_error(response, 400, "INVALID_INPUT", caplog)
    assert not requests
    assert all(record.name != "python_multipart.multipart" for record in caplog.records)


@pytest.mark.parametrize("provider,status,code", [
    (httpx.ReadTimeout(MARKER), 503, "AI_UNAVAILABLE"),
    (httpx.Response(503, text=MARKER), 503, "AI_UNAVAILABLE"),
    (httpx.Response(401, text=MARKER), 503, "AI_PROVIDER_AUTH_FAILED"),
    (httpx.Response(400, json={"error": {"details": [None, {"reason": "API_KEY_INVALID", "extra": MARKER}]}}),
     503, "AI_PROVIDER_AUTH_FAILED"),
    (httpx.Response(429, text=MARKER), 429, "RATE_LIMITED"),
    (httpx.Response(400, json={"error": {"details": MARKER}}), 502, "AI_REQUEST_REJECTED"),
])
def test_provider_statuses_do_not_expose_body(upstreams, caplog, provider, status, code):
    client, responses, requests = upstreams
    responses["provider"] = provider
    response = client.post("/api/v1/assistant/chat", headers=AUTH, json=CHAT)
    assert_error(response, status, code, caplog)
    assert requests.count("provider") == 1


@pytest.mark.parametrize("envelope", [
    httpx.Response(200, text=MARKER),
    httpx.Response(200, json={"candidates": {"0": MARKER}}),
    httpx.Response(200, json={"candidates": [{"content": {"parts": 7}}]}),
    httpx.Response(200, json={"candidates": [{"content": {"parts": [{"text": {"private": MARKER}}]}}]}),
    provider_response([MARKER]),
    httpx.Response(200, json={
        "candidates": [{"content": {"parts": [{"text": '{"action":"final","answer":"\\ud800"}'}]}}],
    }),
])
def test_malformed_provider_envelope_is_retried_and_reported(upstreams, caplog, envelope):
    client, responses, requests = upstreams
    responses["provider"] = envelope
    response = client.post("/api/v1/assistant/chat", headers=AUTH, json=CHAT)
    assert_error(response, 502, "AI_RESPONSE_INVALID", caplog)
    assert requests.count("provider") == requests.count("/rest/v1/ai_processing_consents") - 1 == 2


def test_invalid_optional_telemetry_does_not_break_a_valid_answer(upstreams, monkeypatch):
    client, responses, _ = upstreams
    monkeypatch.setattr(llm, "USAGE", [])
    responses["provider"] = httpx.Response(200, json={
        "usageMetadata": {"promptTokenCount": {"invalid": MARKER}},
        "candidates": [{"content": {"parts": [
            {"text": MARKER, "thought": True},
            {"text": '{"action":"final",'},
            {"text": '"answer":"Synthetic answer."}'},
        ]}}],
    })
    response = client.post("/api/v1/assistant/chat", headers=AUTH, json=CHAT)
    assert response.status_code == 200
    assert "could not verify" in response.json()["data"]["reply"]
    assert "Synthetic answer." not in response.text
    assert MARKER not in response.text and llm.USAGE == []


def test_assistant_summary_reads_evidence_as_the_authenticated_account(upstreams, monkeypatch):
    client, responses, requests = upstreams
    responses["/rest/v1/water_logs"] = httpx.Response(200, json=[
        {"amount_ml": 725, "logged_at": "2026-10-24T05:00:00Z"},
    ])
    actions = iter([
        {"action": "tool", "tool": "get_recent_logs", "args": {"kind": "water", "days": 1}},
        {"action": "final", "answer": "You drank 925 mL.", "used": ["profile"]},
    ])
    original_send = httpx.AsyncClient.send

    async def send(client, request, **kwargs):
        if request.url.host == "generativelanguage.googleapis.com":
            responses["provider"] = provider_response(next(actions))
        return await original_send(client, request, **kwargs)

    monkeypatch.setattr(httpx.AsyncClient, "send", send)
    response = client.post(
        "/api/v1/assistant/chat", headers=AUTH, json={**CHAT, "health_data": ["logs"]},
    )
    assert response.status_code == 200 and response.headers["Cache-Control"] == "no-store"
    data = response.json()["data"]
    assert "725 mL" in data["reply"] and "925 mL" not in data["reply"]
    assert data["sources"] == ["water"]
    assert requests.count("/rest/v1/water_logs") == 1
    assert requests.count("/rest/v1/ai_processing_consents") == 3


@pytest.mark.parametrize("model_output", [
    {"is_report": "true", "results": []},
    {"is_report": True, "results": {"invalid": MARKER}},
    {"is_report": True, "results": [MARKER]},
    {"is_report": True, "results": [{"test": [MARKER]}]},
])
def test_malformed_lab_result_uses_upstream_error(upstreams, caplog, model_output):
    client, responses, _ = upstreams
    responses["provider"] = provider_response(model_output)
    response = client.post("/api/v1/scan/report", headers=AUTH, json={"text": "Synthetic lab test 4.5", "reviewed": True})
    assert_error(response, 502, "AI_RESPONSE_INVALID", caplog)


def test_valid_non_report_keeps_scan_failed_code(upstreams, caplog):
    client, responses, _ = upstreams
    responses["provider"] = provider_response({"is_report": False, "results": []})
    response = client.post("/api/v1/scan/report", headers=AUTH, json={"text": "Synthetic grocery list", "reviewed": True})
    assert_error(response, 422, "SCAN_FAILED", caplog)


def test_scan_error_never_returns_exception_details(upstreams, caplog, monkeypatch):
    client, _, _ = upstreams

    async def broken_scan(*args, **kwargs):
        raise main.scan.ScanError(MARKER)

    monkeypatch.setattr(main.scan, "scan_report", broken_scan)
    response = client.post(
        "/api/v1/scan/report", headers=AUTH, json={"text": "Synthetic report", "reviewed": True},
    )
    assert_error(response, 422, "SCAN_FAILED", caplog)


def test_extra_nested_provider_fields_are_not_read_or_returned(upstreams):
    client, responses, _ = upstreams
    nested = MARKER
    for _ in range(550):
        nested = [nested]
    responses["provider"] = provider_response({
        "is_prescription": True, "medications": [{"name": "Synthetic medicine", "extra": nested}],
    })
    response = client.post("/api/v1/scan/prescription", headers=AUTH, json={
        "text": "Synthetic medicine", "reviewed": True,
    })
    assert response.status_code == 200
    assert response.json()["data"]["medications"][0]["name"] == "Synthetic medicine"
    assert MARKER not in response.text


@pytest.mark.parametrize("day", ["0001-01-01", "9999-12-31"])
def test_out_of_range_daily_report_date_is_client_error(upstreams, caplog, day):
    client, _, requests = upstreams
    response = client.get("/api/v1/reports/daily", params={"date": day}, headers=AUTH)
    assert_error(response, 400, "INVALID_INPUT", caplog)
    assert requests == ["/auth/v1/user"]


def test_unusable_assistant_step_is_bounded_then_returns_upstream_error(upstreams, caplog, monkeypatch):
    client, responses, requests = upstreams
    monkeypatch.setattr(main.agent, "MAX_STEPS", 1)
    responses["provider"] = provider_response({"action": [MARKER], "answer": [MARKER]})
    response = client.post("/api/v1/assistant/chat", headers=AUTH, json=CHAT)
    assert_error(response, 502, "AI_RESPONSE_INVALID", caplog)
    assert requests.count("provider") == 2


@pytest.mark.parametrize("data", [
    httpx.Response(200, text=MARKER),
    httpx.Response(200, json=[MARKER]),
    httpx.Response(200, json=[{"amount_ml": {"invalid": MARKER}}]),
    httpx.Response(400, text=MARKER),
    httpx.Response(503, text=MARKER),
    httpx.ReadTimeout(MARKER),
])
def test_local_report_keeps_other_data_when_a_measurement_is_unavailable(upstreams, caplog, data):
    client, responses, requests = upstreams
    responses["/rest/v1/water_logs"] = data
    response = client.get("/api/v1/reports/daily?date=2025-01-02", headers=AUTH)
    assert response.status_code == 200 and response.headers["Cache-Control"] == "no-store"
    assert "Water: unknown" in response.json()["data"]["highlights"]
    assert not any(value in response.text + caplog.text for value in (MARKER, AUTH["Authorization"]))
    assert "provider" not in requests


def test_internal_fault_is_generic_and_cors_still_applies(upstreams, caplog, monkeypatch):
    client, _, _ = upstreams

    async def fail(*args):
        raise RuntimeError(MARKER)

    origin = "https://client.invalid"
    monkeypatch.setattr(main.reports, "daily_report", fail)
    response = client.get("/api/v1/reports/daily", headers={**AUTH, "Origin": origin})
    assert_error(response, 500, "SERVER_ERROR", caplog)
    assert response.headers["Access-Control-Allow-Origin"] in ("*", origin)
    assert any(record.message == "API request failed unexpectedly" and not record.exc_info for record in caplog.records)


def test_router_and_validation_errors_use_safe_envelope(upstreams, caplog):
    client, _, _ = upstreams
    assert_error(client.get(f"/api/v1/{MARKER}"), 404, "NOT_FOUND", caplog)
    method = client.get("/api/v1/assistant/chat")
    assert_error(method, 405, "METHOD_NOT_ALLOWED", caplog)
    assert method.headers["Allow"] == "POST"
    report = client.post("/api/v1/scan/report/confirm", headers=AUTH, json={
        "scan_id": ACCOUNT, "expected_user_id": ACCOUNT, "reviewed": True,
        "results": [{"test": "Synthetic", "value_text": "<0.40", MARKER: MARKER}],
    })
    assert_error(report, 422, "INVALID_INPUT", caplog)
