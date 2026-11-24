import asyncio
from datetime import date, datetime, timedelta, timezone

from fastapi.testclient import TestClient

import daily_metrics
import main
import reports
import scan
import tools
from fakes import FakeDB, enable_test_ai, script_llm


DAY = date(2026, 3, 8)
OLDER = {"hours": 8, "logged_at": "2026-03-08T06:30:00Z"}
LATEST = {"hours": 6.5, "logged_at": "2026-03-08T07:00:00Z"}


def test_report_and_assistant_use_the_latest_sleep_total():
    db = FakeDB({"sleep_logs": [LATEST, OLDER]})
    data = asyncio.run(reports.build_daily_data(db, DAY))
    evidence = asyncio.run(tools.get_recent_logs(db, {"kind": "sleep", "days": 1}))
    assert data["sleep_hours"] == evidence["average_hours_on_logged_days"] == 6.5
    assert asyncio.run(reports.build_daily_data(FakeDB({
        "sleep_logs": [LATEST, {**LATEST, "hours": 8}],
    }), DAY))["sleep_hours"] is None


def test_local_midnight_dst_and_exclusive_boundary():
    start, end = daily_metrics.day_window(DAY, (-300, -240))
    assert start.isoformat() == "2026-03-08T05:00:00+00:00"
    assert end.isoformat() == "2026-03-09T04:00:00+00:00"
    assert end - start == timedelta(hours=23)
    calendar = daily_metrics.LocalCalendar(DAY, [-300, -300, -240])
    assert calendar.day_for("2026-03-08T04:59:59Z") == date(2026, 3, 7)
    assert calendar.day_for("2026-03-08T05:00:00Z") == DAY
    sleep = tools.summarize_logs("sleep", [
        {**OLDER, "logged_at": "2026-03-08T04:59:59Z"}, LATEST,
    ], 2, calendar)
    assert sleep["hours_per_day"] == {"2026-03-07": 8, "2026-03-08": 6.5}


def test_report_uses_exact_device_bounds_and_only_confirmed_meals(monkeypatch):
    db = FakeDB(user_id="synthetic")
    monkeypatch.setitem(main.app.dependency_overrides, main.get_db, lambda: db)
    monkeypatch.setitem(main.app.dependency_overrides, main.current_user, lambda: {"id": db.user_id})
    client = TestClient(main.app)
    result = client.get("/api/v1/reports/daily?date=2026-03-08&start_offset_minutes=-300&end_offset_minutes=-240")
    assert result.status_code == 200 and result.json()["data"]["calendar_basis"] == "device"
    for table, _, filters in db.selects:
        if table in ("water_logs", "sleep_logs", "mood_logs", "meal_logs", "wearable_samples"):
            assert "gte.2026-03-08T05:00:00+00:00" in filters["and"]
            assert "lt.2026-03-09T04:00:00+00:00" in filters["and"]
        if table == "meal_logs":
            assert filters["status"] == "eq.confirmed"
    assert client.get("/api/v1/reports/daily?date=2026-03-08&start_offset_minutes=-300").status_code == 400


def test_missing_measurements_and_partial_nutrition_do_not_turn_into_zero():
    db = FakeDB({"meal_logs": [{"calories": 250}, {"calories": None}]})
    data = asyncio.run(reports.build_daily_data(db, DAY))
    assert data["water_ml"] is data["sleep_hours"] is data["calories"] is data["mood"] is None
    assert data["water_goal_ml"] is data["sleep_goal_hours"] is None
    assert data["meals"] == 2 and "Meals: 2 logged, calorie total unknown" in reports.highlights(data)
    assert "Heart rate: unknown" in reports.highlights(data)
    assert daily_metrics.total([{"calories": 0}], "calories") == 0
    parsed = scan.parse_food({"is_food": True, "description": "Synthetic meal", "protein_g": 0})
    assert parsed.calories is parsed.carbs_g is parsed.fat_g is None and parsed.protein_g == 0


def test_only_the_accounts_saved_target_is_shown_and_fluid_limits_take_priority():
    for target in (750, 3200, None):
        db = FakeDB({"profiles": [{"water_goal_ml": target, "sleep_goal_hours": 8, "conditions": ["Synthetic fluid restriction"]}],
                     "water_logs": [{"amount_ml": 200}]})
        data = asyncio.run(reports.build_daily_data(db, DAY))
        assert data["water_goal_ml"] == target and data["sleep_goal_hours"] == 8
        items = reports.highlights(data)
        assert items[0] == ("Water: 0.2 L logged" + (f" · saved target {target / 1000:g} L" if target else ""))
        suggestions = " ".join(reports.tips(data)).lower()
        assert "fluid instructions from your care team" in suggestions
        assert "more glasses" not in suggestions and "drink" not in suggestions


def test_local_calendar_is_used_for_grounded_evidence_but_kept_out_of_provider_prompt(monkeypatch):
    now = datetime(2026, 3, 9, 3, tzinfo=timezone.utc)
    monkeypatch.setattr(tools, "utc_now", lambda: now)
    db = FakeDB({"water_logs": [{"amount_ml": 200, "logged_at": "2026-03-09T01:00:00Z"}]})
    enable_test_ai(monkeypatch, db)
    monkeypatch.setitem(main.app.dependency_overrides, main.get_db, lambda: db)
    monkeypatch.setitem(main.app.dependency_overrides, main.current_user, lambda: {"id": db.user_id})
    prompts = []
    script_llm(monkeypatch, [
        {"action": "tool", "tool": "get_recent_logs", "args": {"kind": "water", "days": 1}},
        {"action": "final", "answer": "Drink another litre."},
    ], prompts)
    response = TestClient(main.app).post("/api/v1/assistant/chat", json={
        "message": "Show logged water", "reviewed": True, "health_data": ["logs"],
        "local_calendar": {"today": "2026-03-08", "midnight_offsets": [-300] * 30 + [-240]},
    })
    assert response.status_code == 200
    assert "200 mL" in response.json()["data"]["reply"] and "another litre" not in response.text
    filters = next(filters for table, _, filters in db.selects if table == "water_logs")
    assert filters["logged_at"] == "gte.2026-03-08T05:00:00+00:00"
    assert all("midnight_offsets" not in prompt and "2026-03-08" not in prompt for prompt in prompts)
