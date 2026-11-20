from datetime import date

import pytest
from fastapi.testclient import TestClient

import llm
import main
import tools
from fakes import FakeDB, script_llm

JPEG = b"\xff\xd8\xff\xe0" + b"0" * 64


@pytest.fixture
def db():
    return FakeDB({"water_logs": [{"amount_ml": 1000, "logged_at": "2026-10-24T05:00:00Z"}]})


@pytest.fixture(autouse=True)
def overrides(db):
    main.app.dependency_overrides[main.current_user] = lambda: {"id": "user-1", "email": "t@example.com"}
    main.app.dependency_overrides[main.get_db] = lambda: db
    main._chat_counts.clear()
    main._scan_counts.clear()
    yield
    main.app.dependency_overrides.clear()


@pytest.fixture
def client():
    return TestClient(main.app)


# ------------------------------------------------------------ chat
def test_chat_returns_reply_sources_and_saves_the_conversation(client, db, monkeypatch):
    script_llm(monkeypatch, [
        {"action": "tool", "tool": "get_recent_logs", "args": {"kind": "water", "days": 7}},
        {"action": "final", "answer": "You drank about 1 litre.", "used": ["water"]},
    ])
    res = client.post("/api/v1/assistant/chat", json={"message": "How much water did I drink?"})
    assert res.status_code == 200
    data = res.json()["data"]
    assert "1 litre" in data["reply"] and data["sources"] == ["water"] and data["emergency"] is False
    roles = [rows["role"] for table, rows in db.inserted if table == "chat_messages"]
    assert roles == ["user", "assistant"]


def test_emergency_works_without_any_ai_and_is_not_rate_limited(client, monkeypatch):
    def boom(*a, **k):
        raise AssertionError("no model call for an emergency")

    monkeypatch.setattr(llm, "generate_json", boom)
    monkeypatch.setattr(main, "CHAT_DAILY_LIMIT", 0)  # normal chat would be blocked
    res = client.post("/api/v1/assistant/chat", json={"message": "I can't breathe"})
    assert res.status_code == 200
    assert res.json()["data"]["emergency"] is True and "1990" in res.json()["data"]["reply"]


def test_chat_input_validation(client):
    assert client.post("/api/v1/assistant/chat", json={"message": "   "}).status_code == 400
    too_long = client.post("/api/v1/assistant/chat", json={"message": "a" * 1500})
    assert too_long.status_code == 400 and too_long.json()["error"]["code"] == "INVALID_INPUT"


def test_chat_daily_limit(client, monkeypatch):
    monkeypatch.setattr(main, "CHAT_DAILY_LIMIT", 1)
    script_llm(monkeypatch, [{"action": "final", "answer": "Ok.", "used": []}] * 2)
    assert client.post("/api/v1/assistant/chat", json={"message": "hi"}).status_code == 200
    res = client.post("/api/v1/assistant/chat", json={"message": "hi again"})
    assert res.status_code == 429 and res.json()["error"]["code"] == "RATE_LIMITED"


def test_chat_reports_ai_problems_in_the_standard_error_format(client, monkeypatch):
    script_llm(monkeypatch, [llm.LLMError("AI is not configured on the server.", 503)])
    res = client.post("/api/v1/assistant/chat", json={"message": "hello"})
    assert res.status_code == 503 and res.json()["error"]["code"] == "AI_UNAVAILABLE"


def test_chat_still_works_if_saving_history_fails(client, db, monkeypatch):
    async def broken_insert(*a, **k):
        raise RuntimeError("db down")

    db.insert = broken_insert
    script_llm(monkeypatch, [{"action": "final", "answer": "Ok.", "used": []}])
    assert client.post("/api/v1/assistant/chat", json={"message": "hi"}).status_code == 200


def test_chat_requires_login():
    main.app.dependency_overrides.clear()
    res = TestClient(main.app).post("/api/v1/assistant/chat", json={"message": "hi"})
    assert res.status_code == 401


# ------------------------------------------------------------ daily report
def test_daily_report_works_without_ai(client, monkeypatch):
    script_llm(monkeypatch, [llm.LLMError("AI is not configured on the server.", 503)])
    res = client.get("/api/v1/reports/daily?date=2026-10-24")
    assert res.status_code == 200
    data = res.json()["data"]
    assert data["date"] == "2026-10-24" and data["ai"] is False
    assert any(h.startswith("Water:") for h in data["highlights"])
    assert "Guidance, not medical advice." in data["report"]


def test_daily_report_uses_ai_text_when_available(client, monkeypatch):
    script_llm(monkeypatch, [{"summary": "Nice work on water today.", "tips": ["Go to bed earlier."]}])
    data = client.get("/api/v1/reports/daily?date=2026-10-24").json()["data"]
    assert data["ai"] is True and "Nice work" in data["report"] and "Go to bed earlier." in data["report"]


def test_daily_report_ignores_an_unsafe_ai_summary(client, monkeypatch):
    script_llm(monkeypatch, [{"summary": "You definitely have a thyroid problem.", "tips": []}])
    data = client.get("/api/v1/reports/daily?date=2026-10-24").json()["data"]
    assert "thyroid" not in data["report"].lower()


def test_daily_report_defaults_to_local_today(client, monkeypatch):
    script_llm(monkeypatch, [llm.LLMError("x", 503)])
    assert client.get("/api/v1/reports/daily").json()["data"]["date"] == tools.local_today().isoformat()


def test_daily_report_numbers_come_from_the_database_not_the_ai(client, monkeypatch):
    script_llm(monkeypatch, [llm.LLMError("x", 503)])
    data = client.get("/api/v1/reports/daily?date=2026-10-24").json()["data"]
    assert "Water: 1.0 of 2.5 L (40%)" in data["highlights"]


# ------------------------------------------------------------ scan + safety rules
def test_prescription_scan_includes_allergy_warnings(client, db, monkeypatch):
    db.tables["allergies"] = [{"name": "Penicillin"}]
    script_llm(monkeypatch, [{
        "is_prescription": True,
        "medications": [{"name": "Amoxicillin", "dosage": "500 mg", "frequency": "3 times a day", "duration_days": 7}],
        "confidence": 0.9,
    }])
    res = client.post("/api/v1/scan/prescription", files={"image": ("p.jpg", JPEG, "image/jpeg")})
    assert res.status_code == 200
    warnings = res.json()["data"]["warnings"]
    assert warnings and warnings[0]["severity"] == "high" and "Amoxicillin" in warnings[0]["message"]


def test_prescription_scan_has_no_warnings_when_safe(client, db, monkeypatch):
    script_llm(monkeypatch, [{
        "is_prescription": True,
        "medications": [{"name": "Cetirizine", "dosage": "10 mg", "frequency": "once a day", "duration_days": 5}],
        "confidence": 0.9,
    }])
    res = client.post("/api/v1/scan/prescription", files={"image": ("p.jpg", JPEG, "image/jpeg")})
    assert res.json()["data"]["warnings"] == []


def test_scan_still_works_if_the_safety_lookup_fails(client, db, monkeypatch):
    db.tables["allergies"] = RuntimeError("db down")
    script_llm(monkeypatch, [{
        "is_prescription": True,
        "medications": [{"name": "Amoxicillin", "dosage": "500 mg", "frequency": "daily", "duration_days": 3}],
        "confidence": 0.9,
    }])
    res = client.post("/api/v1/scan/prescription", files={"image": ("p.jpg", JPEG, "image/jpeg")})
    assert res.status_code == 200 and res.json()["data"]["warnings"] == []
