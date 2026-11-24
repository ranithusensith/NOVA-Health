import sys
from datetime import date
from pathlib import Path
from uuid import uuid4

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import ai_privacy
import main
import scan
import tools
from db import DBError, UserDB


class PrescriptionDB:
    user_id = "test-user"

    def __init__(self):
        self.tables = {"profiles": [{"conditions": []}], "allergies": [], "medications": []}
        self.rows = []

    async def select(self, table, columns, **kwargs):
        rows = self.tables[table]
        if isinstance(rows, Exception):
            raise rows
        return rows

    async def insert(self, table, rows):
        assert table == "medications"
        if {row["id"] for row in rows}.intersection(row["id"] for row in self.rows):
            raise DBError("Duplicate medication ID")
        self.rows.extend(rows)


@pytest.fixture
def db():
    return PrescriptionDB()


@pytest.fixture
def client(db, monkeypatch):
    monkeypatch.setitem(main.app.dependency_overrides, main.get_db, lambda: db)
    monkeypatch.setitem(main.app.dependency_overrides, main.current_user, lambda: {"id": db.user_id})
    monkeypatch.setattr(main, "_scan_counts", {})
    with TestClient(main.app) as client:
        yield client


@pytest.fixture
def draft():
    return {
        "scan_id": str(uuid4()),
        "medications": [{
            "name": "Cetirizine",
            "dosage": "10 mg",
            "times": ["20:00"],
            "start_date": "2026-11-23",
            "end_date": "2026-11-26",
            "prescription_plan": {"kind": "daily"},
            "reminders_enabled": True,
            "schedule_confirmed": True,
        }],
    }


@pytest.mark.parametrize("outcome", ["clear", "warning", "unavailable"])
def test_scan_preview_reports_safety_outcome_without_saving(client, db, monkeypatch, outcome):
    async def fake_scan(*args, **kwargs):
        return scan.PrescriptionResult(
            is_prescription=True, medications=[scan.Medication(name="Amoxicillin")], confidence=0.9,
        )

    monkeypatch.setattr(scan, "scan_prescription", fake_scan)
    monkeypatch.setenv("AI_PRIVACY_PROVIDER_APPROVAL", "gemini-reviewed-paid")
    monkeypatch.setenv("LLM_API_KEY", "synthetic-test-key")
    monkeypatch.setenv("LLM_MODEL", "gemini-fixture")
    db.tables["ai_processing_consents"] = [{"disclosure_version": ai_privacy.DISCLOSURE_VERSION}]
    if outcome == "warning":
        db.tables["allergies"] = [{"name": "Penicillin"}]
    if outcome == "unavailable":
        db.tables["allergies"] = DBError("Unavailable")

    response = client.post(
        "/api/v1/scan/prescription",
        json={"text": "Amoxicillin", "reviewed": True},
    )
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["safety_check_status"] == ("unavailable" if outcome == "unavailable" else "completed")
    assert [warning["severity"] for warning in data["warnings"]] == (["high"] if outcome == "warning" else [])
    assert db.rows == []


def test_success_activates_exact_edited_values_as_authenticated_user(client, db, draft):
    draft["medications"][0]["user_id"] = "other-user"
    response = client.post("/api/v1/scan/prescription/confirm", json=draft)
    assert response.status_code == 200
    assert response.json()["data"] == {"activated": True, "safety_check_status": "completed", "warnings": []}
    assert len(db.rows) == 1
    saved = db.rows[0]
    assert saved["user_id"] == db.user_id
    assert saved["status"] == "confirmed"
    assert saved["source"] == "scan"
    for key in ("name", "dosage", "times", "start_date", "end_date"):
        assert saved[key] == draft["medications"][0][key]

    retry = client.post("/api/v1/scan/prescription/confirm", json=draft)
    assert retry.status_code == 502
    assert len(db.rows) == 1


def test_warning_requires_acknowledgement_bound_to_edited_details(client, db, draft):
    db.tables["allergies"] = [{"name": "Penicillin"}]
    draft["medications"][0]["name"] = "Amoxicillin"
    first = client.post("/api/v1/scan/prescription/confirm", json=draft).json()["data"]
    assert first["activated"] is False
    assert first["warnings"][0]["severity"] == "high"
    assert db.rows == []

    draft["review_token"] = first["review_token"]
    draft["medications"][0]["dosage"] = "Edited strength"
    changed = client.post("/api/v1/scan/prescription/confirm", json=draft).json()["data"]
    assert changed["activated"] is False
    assert changed["review_token"] != first["review_token"]
    assert db.rows == []

    draft["review_token"] = changed["review_token"]
    db.tables["allergies"] = DBError("Unavailable")
    failed = client.post("/api/v1/scan/prescription/confirm", json=draft).json()["data"]
    assert failed["safety_check_status"] == "unavailable"
    assert failed["activated"] is False
    assert db.rows == []

    db.tables["allergies"] = [{"name": "Penicillin"}]
    result = client.post("/api/v1/scan/prescription/confirm", json=draft).json()["data"]
    assert result["activated"] is True
    assert db.rows[0]["dosage"] == "Edited strength"


@pytest.mark.parametrize("table", ["allergies", "profiles", "medications"])
def test_failed_safety_lookup_never_activates(client, db, draft, table):
    db.tables[table] = DBError("Unavailable")
    response = client.post("/api/v1/scan/prescription/confirm", json=draft)
    assert response.json()["data"] == {"activated": False, "safety_check_status": "unavailable", "warnings": []}
    assert db.rows == []


def test_missing_profile_never_activates(client, db, draft):
    db.tables["profiles"] = []
    response = client.post("/api/v1/scan/prescription/confirm", json=draft)
    assert response.json()["data"]["safety_check_status"] == "unavailable"
    assert db.rows == []


def test_invalid_database_response_is_not_treated_as_zero_allergies(client, monkeypatch, draft):
    async def invalid_table_response(*args, **kwargs):
        return httpx.Response(200, json={"unexpected": []})

    monkeypatch.setattr(httpx.AsyncClient, "get", invalid_table_response)
    monkeypatch.setitem(main.app.dependency_overrides, main.get_db, lambda: UserDB("synthetic", "test-user"))
    response = client.post("/api/v1/scan/prescription/confirm", json=draft)
    assert response.json()["data"] == {"activated": False, "safety_check_status": "unavailable", "warnings": []}


def test_confirmation_requires_authentication(draft):
    with TestClient(main.app) as client:
        assert client.post("/api/v1/scan/prescription/confirm", json=draft).status_code == 401


@pytest.mark.parametrize("field", ["prescription_plan", "start_date", "end_date", "schedule_confirmed"])
def test_schedule_and_course_choices_are_required(client, db, draft, field):
    del draft["medications"][0][field]
    assert client.post("/api/v1/scan/prescription/confirm", json=draft).status_code == 422
    assert db.rows == []


@pytest.mark.parametrize(
    "overrides",
    [
        {"end_date": "2026-11-22"},
        {"schedule_confirmed": False},
        {"schedule_confirmed": 1},
        {"times": []},
        {"times": ["08:00", "08:00"]},
        {"prescription_plan": {"kind": "as_needed"}},
        {"prescription_plan": {"kind": "as_needed"}, "times": []},
        {"prescription_plan": {"kind": "interval"}, "times": []},
    ],
)
def test_invalid_or_unconfirmed_schedule_never_activates(client, db, draft, overrides):
    draft["medications"][0].update(overrides)
    assert client.post("/api/v1/scan/prescription/confirm", json=draft).status_code == 422
    assert db.rows == []


def test_as_needed_preserves_original_directions_without_schedule_or_notifications(client, db, draft):
    plan = {
        "kind": "as_needed", "dosage_text": "1 tablet", "frequency": "p.r.n.",
        "instructions": "Follow the prescriber's written instructions.", "duration_text": "5–7 days",
    }
    draft["medications"][0].update(
        prescription_plan=plan, times=[], reminders_enabled=False, end_date=None,
    )
    response = client.post("/api/v1/scan/prescription/confirm", json=draft)
    assert response.json()["data"]["activated"] is True
    saved = db.rows[0]
    assert {key: saved["prescription_plan"][key] for key in plan} == plan
    assert saved["times"] == []
    assert saved["end_date"] is None
    assert saved["reminders_enabled"] is False
    assert "schedule_confirmed" not in saved


def test_same_day_course_preserves_daily_schedule_with_notifications_off(client, db, draft):
    draft["medications"][0].update(end_date="2026-11-23", reminders_enabled=False)
    response = client.post("/api/v1/scan/prescription/confirm", json=draft)
    assert response.json()["data"]["activated"] is True
    assert db.rows[0]["start_date"] == db.rows[0]["end_date"]
    assert db.rows[0]["times"] == ["20:00"]
    assert db.rows[0]["reminders_enabled"] is False


@pytest.mark.parametrize("first_dose_at", ["2026-11-23T22:00:00", "2026-11-24T22:00:00+05:30"])
def test_interval_anchor_requires_an_offset_and_matching_start_date(client, db, draft, first_dose_at):
    draft["medications"][0].update(
        times=[],
        prescription_plan={"kind": "interval", "interval_minutes": 420, "first_dose_at": first_dose_at},
    )
    assert client.post("/api/v1/scan/prescription/confirm", json=draft).status_code == 422
    assert db.rows == []


def test_exact_interval_preserves_c1_check_and_review_is_bound_to_the_interval(client, db, draft):
    plan = {"kind": "interval", "interval_minutes": 420, "first_dose_at": "2026-11-23T22:00:00+05:30"}
    draft["medications"][0].update(
        name="Paracetamol", dosage="1800 mg per dose", times=[], prescription_plan=plan, reminders_enabled=False,
    )
    first = client.post("/api/v1/scan/prescription/confirm", json=draft).json()["data"]
    assert first["activated"] is False
    assert first["warnings"][0]["severity"] == "high"
    assert db.rows == []

    draft["review_token"] = first["review_token"]
    plan["interval_minutes"] = 480
    changed = client.post("/api/v1/scan/prescription/confirm", json=draft).json()["data"]
    assert changed["activated"] is False
    assert changed["review_token"] != first["review_token"]

    draft["review_token"] = changed["review_token"]
    result = client.post("/api/v1/scan/prescription/confirm", json=draft).json()["data"]
    assert result["activated"] is True
    assert db.rows[0]["prescription_plan"]["first_dose_at"] == plan["first_dose_at"]
    assert db.rows[0]["prescription_plan"]["interval_minutes"] == 480
    assert db.rows[0]["times"] == []


def test_backend_counts_elapsed_interval_occurrences_in_the_selected_day(monkeypatch):
    monkeypatch.setattr(tools, "TZ_OFFSET_MIN", 330)
    med = {
        "times": [],
        "prescription_plan": {"interval_minutes": 420, "first_dose_at": "2026-11-23T22:00:00+05:30"},
    }
    assert tools.scheduled_doses_on(med, date(2026, 11, 22)) == 0
    assert tools.scheduled_doses_on(med, date(2026, 11, 23)) == 1
    assert tools.scheduled_doses_on(med, date(2026, 11, 24)) == 3


@pytest.mark.parametrize("wording", ["5–7 days", "1 week", "3 days then stop"])
def test_scan_does_not_convert_ambiguous_duration_to_a_number(wording):
    draft = scan.Medication(name="Test medicine", duration_days=wording, duration_text=wording)
    assert draft.duration_days is None
    assert draft.duration_text == wording
