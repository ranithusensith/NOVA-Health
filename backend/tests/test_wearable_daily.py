import asyncio
from datetime import date, datetime, timezone

from fastapi.testclient import TestClient

import daily_metrics
import main
import reports
import tools
import wearable_daily
from db import DBError
from fakes import FakeDB, enable_test_ai, script_llm

DAY = date(2026, 3, 8)
NOW = datetime(2026, 3, 8, 19, tzinfo=timezone.utc)
BOUNDS = daily_metrics.day_window(DAY, (-300, -240))


def row(metric, value, *, source="apple_health", bounds=BOUNDS):
    return {"local_date": DAY.isoformat(), "metric": metric, "value": value, "source": source,
            "window_start": bounds[0].isoformat(), "window_end": bounds[1].isoformat(),
            "captured_at": NOW.isoformat()}


def test_read_only_accepts_exact_calendar_window_and_keeps_explicit_zero():
    wrong = daily_metrics.day_window(DAY, (330, 330))
    db = FakeDB({"wearable_daily_totals": [row("steps", 5000, bounds=wrong), row("steps", 0),
                                          row("sleep", 25200), row("sleep", -1)]})
    result = asyncio.run(wearable_daily.read(db, {DAY: BOUNDS}))
    assert result[DAY.isoformat()] == {
        "steps": {"source": "Apple Health", "value": 0},
        "sleep": {"source": "Apple Health", "value": 25200},
    }
    assert db.selects[0][2] == {"and": "(local_date.gte.2026-03-08,local_date.lte.2026-03-08)"}


def test_report_sleep_fallback_keeps_manual_precedence_and_separate_observation(monkeypatch):
    monkeypatch.setattr(tools, "utc_now", lambda: NOW)
    db = FakeDB({"wearable_daily_totals": [row("steps", 5500, source="health_connect"), row("sleep", 25200)]})
    data = asyncio.run(reports.build_daily_data(db, DAY, bounds=BOUNDS))
    assert data["sleep_hours"] == 7 and data["sleep_source"] == "Apple Health"
    assert "Steps: 5500 · Health Connect" in reports.highlights(data)
    assert "Sleep: 7 hours logged · Apple Health" in reports.highlights(data)

    db.tables["sleep_logs"] = [{"logged_at": NOW.isoformat(), "hours": 6}]
    data = asyncio.run(reports.build_daily_data(db, DAY, bounds=BOUNDS))
    assert data["sleep_hours"] == 6 and data["sleep_source"] is None
    assert "Imported sleep: 7.00 hours · Apple Health" in reports.highlights(data)
    db.tables["sleep_logs"] = DBError("Synthetic sleep read failure")
    data = asyncio.run(reports.build_daily_data(db, DAY, bounds=BOUNDS))
    assert data["sleep_hours"] is None
    assert "Imported sleep: 7.00 hours · Apple Health" in reports.highlights(data)

    db.tables["wearable_daily_totals"] = DBError("Synthetic provider failure")
    data = asyncio.run(reports.build_daily_data(db, DAY, bounds=BOUNDS))
    assert "Steps: unknown" in reports.highlights(data) and data["imported_sleep"] is None


def test_assistant_uses_separate_consent_and_keeps_capture_time_out_of_provider(monkeypatch):
    db = FakeDB({"wearable_daily_totals": [row("steps", 1324), row("sleep", 23400)]})
    enable_test_ai(monkeypatch, db)
    monkeypatch.setitem(main.app.dependency_overrides, main.current_user, lambda: {"id": db.user_id})
    monkeypatch.setitem(main.app.dependency_overrides, main.get_db, lambda: db)
    monkeypatch.setattr(tools, "utc_now", lambda: NOW)
    monkeypatch.setattr(main, "_chat_counts", {})
    prompts = []
    steps = [{"action": "tool", "tool": "get_wearable_activity", "args": {"days": 1}},
             {"action": "final", "answer": "You took 10000 steps."}]
    client = TestClient(main.app)
    request = {"message": "What did I import?", "reviewed": True,
               "local_calendar": {"today": DAY.isoformat(), "midnight_offsets": [-300] * 30 + [-240]}}
    script_llm(monkeypatch, steps)
    assert client.post("/api/v1/assistant/chat", json={**request, "health_data": ["logs"]}).status_code == 200
    assert all(table != "wearable_daily_totals" for table, _, _ in db.selects)

    script_llm(monkeypatch, steps, prompts)
    response = client.post("/api/v1/assistant/chat", json={**request, "health_data": ["wearable_activity"]})
    data = response.json()["data"]
    assert data["sources"] == ["wearable activity"]
    assert "1324 steps (Apple Health)" in data["reply"] and "6.50 hours asleep" in data["reply"]
    assert "10000 steps" not in data["reply"]
    assert any("1324" in prompt for prompt in prompts)
    assert all(DAY.isoformat() not in prompt and "Apple Health" not in prompt and "captured_at" not in prompt
               for prompt in prompts)
