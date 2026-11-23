from datetime import date

import pytest

import tools
from fakes import FakeDB


def test_parse_timestamps_with_any_fraction_and_zone():
    assert tools.parse_ts("2026-10-24T05:00:00+00:00").hour == 5
    assert tools.parse_ts("2026-10-24T05:00:00Z").hour == 5
    assert tools.parse_ts("2026-10-24T05:00:00.5+00:00").microsecond == 500000
    assert tools.parse_ts("2026-10-24T05:00:00.123456789Z").microsecond == 123456
    assert tools.parse_ts("2026-10-24 05:00:00").tzinfo is not None


def test_water_is_bucketed_by_local_day():
    # 05:00 UTC = 10:30 in Sri Lanka (same day); 20:00 UTC = 01:30 NEXT day locally
    rows = [
        {"amount_ml": 250, "logged_at": "2026-10-24T05:00:00+00:00"},
        {"amount_ml": 500, "logged_at": "2026-10-24T20:00:00+00:00"},
    ]
    out = tools.summarize_logs("water", rows, 7)
    assert out["ml_per_day"] == {"2026-10-24": 250, "2026-10-25": 500}
    assert out["average_ml_on_logged_days"] == 375
    assert out["days_with_data"] == 2


def test_sleep_average():
    rows = [{"hours": 5.5, "logged_at": "2026-10-23T03:00:00Z"}, {"hours": 6.5, "logged_at": "2026-10-24T03:00:00Z"}]
    out = tools.summarize_logs("sleep", rows, 7)
    assert out["average_hours_on_logged_days"] == 6.0


def test_mood_counts_low_days():
    rows = [{"mood": "low", "logged_at": "2026-10-23T03:00:00Z"}, {"mood": "good", "logged_at": "2026-10-24T03:00:00Z"}]
    assert tools.summarize_logs("mood", rows, 7)["low_or_bad_days"] == 1


def test_meals_and_empty_data():
    assert tools.summarize_logs("meals", [], 7)["average_kcal_on_logged_days"] is None
    assert tools.summarize_logs("water", [], 7)["days_with_data"] == 0


def test_heart_summary():
    rows = [
        {"value": 70, "recorded_at": "2026-10-24T03:00:00Z", "context": "resting"},
        {"value": 130, "recorded_at": "2026-10-24T09:00:00Z", "context": "active"},
    ]
    out = tools.summarize_heart(rows)
    assert out["count"] == 2 and out["latest_bpm"] == 130 and out["min_bpm"] == 70 and out["max_bpm"] == 130
    assert out["resting_average_bpm"] == 70
    assert tools.summarize_heart([])["count"] == 0


def test_cycle_summary():
    rows = [{"start_date": "2026-10-01", "end_date": "2026-10-05"}, {"start_date": "2026-09-03", "end_date": "2026-09-07"}]
    out = tools.summarize_cycle(rows, today=date(2026, 10, 10))
    assert out["average_cycle_days"] == 28
    assert out["days_since_last_start"] == 9
    assert out["on_period_now"] is False
    assert tools.summarize_cycle([])["logged_periods"] == 0


def test_age_range_hides_exact_age_and_bmi():
    assert tools.age_range_of("2000-10-20", today=date(2026, 10, 19)) == "20-29"
    assert tools.age_range_of(None) is None
    assert tools.bmi_of(170, 65) == 22.5
    assert tools.bmi_of(None, 65) is None


def test_clean_args_validates_and_clamps():
    assert tools.clean_args("get_recent_logs", {"kind": "SLEEP", "days": 99}) == {"kind": "sleep", "days": 30}
    assert tools.clean_args("get_recent_logs", {"kind": "sleep", "days": "x"}) == {"kind": "sleep", "days": 7}
    assert tools.clean_args("get_heart_rate", {"days": 0}) == {"days": 1}
    with pytest.raises(ValueError):
        tools.clean_args("get_recent_logs", {"kind": "blood"})


def test_profile_tool_never_returns_name_or_birth_date():
    import asyncio

    db = FakeDB({"profiles": [{
        "birth_date": "2000-10-20", "sex": "female", "blood_type": "O+", "height_cm": 165, "weight_kg": 58,
        "conditions": ["Asthma"], "goals": [],
    }]})
    out = asyncio.run(tools.get_profile(db, {}))
    assert out["age_range"] in ("20-29", "30-39") and out["conditions"] == ["Asthma"]
    assert "birth_date" not in out and "full_name" not in out


def test_unknown_tool_is_rejected():
    import asyncio

    with pytest.raises(ValueError):
        asyncio.run(tools.run_tool("delete_everything", {}, FakeDB()))
