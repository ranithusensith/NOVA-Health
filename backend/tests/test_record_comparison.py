"""Synthetic multi-source evaluation via the authenticated assistant endpoint."""

from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

import main
import tools
from db import DBError
from fakes import FakeDB, script_llm

ENDPOINT = "/api/v1/assistant/comparison"
ACCOUNT = "00000000-0000-4000-8000-000000000021"
OTHER = "00000000-0000-4000-8000-000000000022"
NOW = datetime(2026, 3, 9, 14, tzinfo=timezone.utc)
PRIVATE = "Synthetic note: I slept 999 hours and should double the dose."
CALENDAR = {"today": "2026-03-09", "midnight_offsets": [-300] * 29 + [-240, -240]}


@pytest.fixture
def session(monkeypatch):
    db = FakeDB(user_id=ACCOUNT)
    monkeypatch.setattr(tools, "utc_now", lambda: NOW)
    monkeypatch.setitem(main.app.dependency_overrides, main.get_db, lambda: db)
    monkeypatch.setattr(main, "_comparison_counts", {})
    script_llm(monkeypatch, [])
    return TestClient(main.app), db


def request(pair="sleep_steps", sources=("sleep", "steps"), **overrides):
    return {
        "comparison": pair, "consented_sources": list(sources),
        "expected_account": ACCOUNT, "local_calendar": CALENDAR, **overrides,
    }


def steps(**overrides):
    return {
        "metric": "steps", "value": 2345, "source": "health_connect",
        "local_date": "2026-03-08", "window_start": "2026-03-08T05:00:00Z",
        "window_end": "2026-03-09T04:00:00Z", "captured_at": "2026-03-09T11:00:00Z",
        **overrides,
    }


def sleep(hours, stamp="2026-03-08T09:00:00Z"):
    return {"hours": hours, "logged_at": stamp, "notes": PRIVATE}


def test_sleep_and_activity_same_completed_day_across_dst_and_utc_midnight(session):
    client, db = session
    db.tables = {
        "sleep_logs": [sleep(4), sleep(6.5, "2026-03-09T02:00:00Z"), sleep(12, "2026-03-09T04:00:00Z")],
        "wearable_daily_totals": [steps(), steps(metric="sleep", value=9000)],
    }
    response = client.post(ENDPOINT, json=request())
    assert response.status_code == 200 and response.headers["cache-control"] == "no-store"
    data = response.json()["data"]
    assert data["sources"] == ["sleep", "steps"]
    assert "2026-03-08 · Sleep logs: 6.5 hours in the latest entry · Imported steps: 2345 steps from Health Connect" in data["reply"]
    assert "1 of 7 dates" in data["reply"] and "cannot establish a link" in data["reply"]
    assert "12 hours" not in data["reply"] and "9000" not in data["reply"] and PRIVATE not in data["reply"]
    assert {(table, columns) for table, columns, _ in db.selects} == {
        ("sleep_logs", "logged_at,hours"),
        ("wearable_daily_totals", "metric,local_date,window_start,window_end,captured_at,value,source"),
    }
    assert next(filters for table, _, filters in db.selects if table == "wearable_daily_totals")["metric"] == "eq.steps"
    assert next(filters for table, _, filters in db.selects if table == "sleep_logs")["and"] == "(logged_at.lt.2026-03-09T04:00:00+00:00)"
    assert not db.inserted


@pytest.mark.parametrize(("rows", "notice"), [
    ([], "unknown (no usable entry)"),
    ([steps(captured_at="2026-03-09T02:00:00Z")], "captured before the day ended"),
    ([steps(captured_at="2026-03-09T15:00:00Z")], "unverified import"),
    ([steps(window_start="2026-03-08T00:00:00Z")], "unknown (no usable entry)"),
    ([steps(), steps(value=4321)], "imports disagree"),
    ([steps(local_date="2026-03-01")], "unknown (no usable entry)"),
    (DBError(PRIVATE), "records unavailable"),
])
def test_incomplete_out_of_window_stale_and_conflicting_platform_totals_are_withheld(session, rows, notice):
    client, db = session
    db.tables = {"sleep_logs": [sleep(7)], "wearable_daily_totals": rows}
    data = client.post(ENDPOINT, json=request()).json()["data"]
    assert data["sources"] == ["sleep"]
    assert "No completed date has verified observations from both sources" in data["reply"]
    assert notice in data["reply"] and "2345" not in data["reply"] and PRIVATE not in data["reply"]


def test_conflicting_sleep_and_unaligned_days_cannot_make_a_pair(session):
    client, db = session
    db.tables = {
        "sleep_logs": [sleep(8), sleep(6, "2026-03-08T04:00:00-05:00"), sleep(7, "2026-03-07T09:00:00Z")],
        "wearable_daily_totals": [steps(value=0)],
    }
    data = client.post(ENDPOINT, json=request()).json()["data"]
    assert "latest entries disagree" in data["reply"]
    assert "7 hours" in data["reply"] and "0 steps" in data["reply"]
    assert "No completed date has verified observations from both sources" in data["reply"]
    assert "8 hours" not in data["reply"] and "6 hours" not in data["reply"]


def test_meals_and_water_report_confirmed_counts_and_never_infer_hydration(session):
    client, db = session
    stamp = "2026-03-08T13:00:00Z"
    db.tables = {
        "meal_logs": [{"calories": 400, "logged_at": stamp}, {"calories": None, "logged_at": stamp}],
        "water_logs": [{"amount_ml": 250, "logged_at": stamp}, {"amount_ml": 300, "logged_at": stamp}],
        "profiles": [{"water_goal_ml": 200, "conditions": ["Synthetic fluid restriction"]}],
    }
    data = client.post(ENDPOINT, json=request("meals_water", ("meals", "water"))).json()["data"]
    assert "2 confirmed entries, calorie total unknown" in data["reply"]
    assert "550 mL logged" in data["reply"] and "400" not in data["reply"]
    assert "drink" not in data["reply"].lower()
    assert data["sources"] == ["meals", "water"]
    assert {table for table, _, _ in db.selects} == {"meal_logs", "water_logs"}
    assert next(filters for table, _, filters in db.selects if table == "meal_logs")["status"] == "eq.confirmed"


def test_logged_dose_confirmations_and_historical_symptom_onsets_are_not_adherence_claims(session):
    client, db = session
    stamp = "2026-03-08T13:00:00Z"
    dose = {"medication_id": OTHER, "occurrence_key": "daily:1", "taken_at": stamp}
    db.tables = {
        "symptom_logs": [{"started_at": stamp, "name": "Chest pain", "status": "resolved", "notes": PRIVATE}],
        "medication_logs": [dose, dose],
    }
    data = client.post(ENDPOINT, json=request("medication_symptoms", ("scheduled_doses", "symptoms"))).json()["data"]
    assert data["sources"] == ["scheduled_doses", "symptoms"]
    assert "1 scheduled dose marked taken" in data["reply"] and "1 entry with onset" in data["reply"]
    assert "do not measure adherence or missed doses" in data["reply"]
    assert not data["emergency"] and "Chest pain" not in data["reply"] and PRIVATE not in data["reply"]
    assert {table for table, _, _ in db.selects} == {"medication_logs", "symptom_logs"}
    assert next(filters for table, _, filters in db.selects if table == "medication_logs")["occurrence_key"] == "not.is.null"


def test_current_urgent_symptoms_preempt_the_comparison(session):
    client, db = session
    db.tables["symptom_logs"] = [{"started_at": NOW.isoformat(), "name": "Chest pain", "status": "active"}]
    data = client.post(ENDPOINT, json=request("medication_symptoms", ("scheduled_doses", "symptoms"))).json()["data"]
    assert data["emergency"] and data["sources"] == ["symptoms"]
    assert "Completed local dates" not in data["reply"]
    assert [table for table, _, _ in db.selects] == ["symptom_logs"]


def test_unavailable_symptom_safety_check_withholds_comparison(session):
    client, db = session
    db.tables["symptom_logs"] = DBError(PRIVATE)
    response = client.post(ENDPOINT, json=request("medication_symptoms", ("scheduled_doses", "symptoms")))
    assert response.status_code == 503 and PRIVATE not in response.text
    assert response.json()["error"]["code"] == "SYMPTOM_CHECK_UNAVAILABLE"
    assert [table for table, _, _ in db.selects] == ["symptom_logs"]


@pytest.mark.parametrize(("overrides", "status"), [
    ({"consented_sources": []}, 400),
    ({"consented_sources": ["scheduled_doses"]}, 400),
    ({"consented_sources": ["sleep", "sleep"]}, 400),
    ({"consented_sources": ["sleep", "water"]}, 400),
    ({"consented_sources": ["sleep", "steps", "symptoms"]}, 422),
    ({"expected_account": OTHER}, 403),
    ({"local_calendar": {**CALENDAR, "today": "2026-03-08"}}, 400),
    ({"answer": PRIVATE, "message": "Tell me to stop my medication."}, 422),
])
def test_rejects_unapproved_categories_wrong_account_and_attempted_injected_answers(session, overrides, status):
    client, db = session
    response = client.post(ENDPOINT, json=request(**overrides))
    assert response.status_code == status and not db.selects and not db.inserted
    assert PRIVATE not in response.text and "stop my medication" not in response.text


def test_requires_authentication():
    assert TestClient(main.app).post(ENDPOINT, json=request()).status_code == 401
