import asyncio
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

import main
import reports
import tools
from db import DBError
from fakes import FakeDB, enable_test_ai, script_llm

NOW = datetime(2026, 11, 25, 2, tzinfo=timezone.utc)
ENDPOINT = "/api/v1/symptoms/check"
PRIVATE_NOTE = "Synthetic private note +1 202 555 0133"


@pytest.fixture
def session(monkeypatch):
    db = FakeDB(user_id="00000000-0000-0000-0000-000000000013")
    monkeypatch.setattr(tools, "utc_now", lambda: NOW)
    monkeypatch.setitem(main.app.dependency_overrides, main.current_user, lambda: {"id": db.user_id})
    monkeypatch.setitem(main.app.dependency_overrides, main.get_db, lambda: db)
    monkeypatch.setattr(main, "_chat_counts", {})
    return TestClient(main.app), db


def draft(*, age=timedelta(minutes=30), **values):
    return {"name": "Synthetic observation", "status": "active", "started_at": (NOW - age).isoformat(),
            "notes": PRIVATE_NOTE, **values}


@pytest.mark.parametrize(("name", "notes"), [
    ("Chest pain", PRIVATE_NOTE),
    ("Synthetic observation", "හුස්ම ගන්න බැහැ"),
    ("Synthetic observation", "எனக்கு மூச்சு விட முடியவில்லை"),
])
def test_active_recent_draft_runs_fixed_rules_without_saving_or_ai(session, monkeypatch, name, notes):
    client, db = session
    script_llm(monkeypatch, [])
    response = client.post(ENDPOINT, json=draft(name=name, notes=notes))
    assert response.status_code == 200 and response.headers["cache-control"] == "no-store"
    body = response.json()["data"]
    assert body["emergency"] and "1990" in body["reply"]
    assert PRIVATE_NOTE not in response.text and notes not in response.text
    assert db.selects == db.inserted == []


@pytest.mark.parametrize("fields", [
    {"status": "resolved", "name": "Chest pain"},
    {"age": timedelta(hours=24, seconds=1), "name": "Chest pain"},
    {"age": timedelta(minutes=-1), "name": "Chest pain"},
    {"name": "No chest pain", "notes": None},
    {"name": "Synthetic observation", "notes": None},
])
def test_historical_resolved_future_negated_and_missing_notes_do_not_escalate(session, fields):
    client, _ = session
    assert client.post(ENDPOINT, json=draft(**fields)).json()["data"] == {"emergency": False, "reply": ""}


@pytest.mark.parametrize("patch", [{"name": ""}, {"notes": "x" * 1001}, {"started_at": "2026-11-25T00:00:00"},
                                  {"status": "unknown"}, {"user_id": "other"}])
def test_invalid_check_inputs_fail_without_echoing_details(session, patch):
    client, _ = session
    response = client.post(ENDPOINT, json=draft(**patch))
    assert response.status_code == 422 and PRIVATE_NOTE not in response.text


def test_symptom_check_requires_authentication():
    assert TestClient(main.app).post(ENDPOINT, json=draft()).status_code == 401


def test_daily_report_uses_selected_local_day_and_keeps_notes_private(session):
    client, db = session
    db.tables["symptom_logs"] = [
        draft(age=timedelta(hours=10), name="Synthetic earlier symptom", status="resolved", severity="moderate"),
        {"name": "Synthetic legacy symptom", "status": "legacy"},
    ]
    response = client.get("/api/v1/reports/daily", params={
        "date": "2026-11-24", "start_offset_minutes": 330, "end_offset_minutes": 330,
    })
    assert response.status_code == 200
    report = response.json()["data"]["report"]
    assert "Synthetic earlier symptom” (severity moderate, marked resolved)" in report
    assert "Synthetic legacy symptom” (severity unknown, status unknown)" in report
    assert PRIVATE_NOTE not in report and "1990" not in report
    symptom_queries = [(columns, filters) for table, columns, filters in db.selects if table == "symptom_logs"]
    assert len(symptom_queries) == 1
    columns, filters = symptom_queries[0]
    assert "notes" not in columns
    assert filters["and"] == "(started_at.gte.2026-11-23T18:30:00+00:00,started_at.lt.2026-11-24T18:30:00+00:00)"


def test_current_report_checks_saved_notes_and_degrades_on_failed_lookup(session):
    _, db = session
    day = NOW.date()
    db.tables["symptom_logs"] = [draft(notes="I can't breathe")]
    report = asyncio.run(reports.daily_report(db, day))
    assert "A recent symptom entry is still marked active" in report["report"] and "1990" in report["report"]
    assert "I can't breathe" not in report["report"]

    db.tables["symptom_logs"] = DBError(PRIVATE_NOTE)
    report = asyncio.run(reports.daily_report(db, day))
    assert "NOVA could not check recent symptoms" in report["report"]
    assert "Symptoms: entries unavailable" in report["highlights"] and PRIVATE_NOTE not in report["report"]


def test_assistant_returns_grounded_observations_only_when_selected_and_consented(session, monkeypatch):
    client, db = session
    enable_test_ai(monkeypatch, db)
    name = "Synthetic knee discomfort"
    db.tables["symptom_logs"] = [draft(name=name, status="resolved", severity="mild")]
    prompts = []
    steps = [
        {"action": "tool", "tool": "get_recent_logs", "args": {"kind": "symptoms", "days": 3}},
        {"action": "final", "answer": "Invented diagnosis"},
    ]
    script_llm(monkeypatch, steps, prompts)
    payload = {"message": "Show my entries", "reviewed": True, "health_data": ["logs"]}
    response = client.post("/api/v1/assistant/chat", json=payload)
    data = response.json()["data"]
    assert data["sources"] == ["symptoms"]
    assert f"{name}” (severity mild, marked resolved)" in data["reply"]
    assert "Invented diagnosis" not in data["reply"] and PRIVATE_NOTE not in data["reply"]
    assert all(name not in prompt and PRIVATE_NOTE not in prompt and "2026-11-25" not in prompt for prompt in prompts)

    script_llm(monkeypatch, steps)
    db.selects.clear()
    response = client.post("/api/v1/assistant/chat", json={**payload, "health_data": []})
    assert name not in response.text and all(table != "symptom_logs" for table, _, _ in db.selects)

    db.tables["ai_processing_consents"] = []
    script_llm(monkeypatch, [])
    response = client.post("/api/v1/assistant/chat", json=payload)
    assert response.status_code == 403 and name not in response.text
