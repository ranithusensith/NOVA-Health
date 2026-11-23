import sys
from pathlib import Path
from uuid import uuid4

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import main
import scan
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
        }],
    }


@pytest.mark.parametrize("outcome", ["clear", "warning", "unavailable"])
def test_scan_preview_reports_safety_outcome_without_saving(client, db, monkeypatch, outcome):
    async def fake_scan(*args):
        return scan.PrescriptionResult(
            is_prescription=True, medications=[scan.Medication(name="Amoxicillin")], confidence=0.9,
        )

    monkeypatch.setattr(scan, "scan_prescription", fake_scan)
    if outcome == "warning":
        db.tables["allergies"] = [{"name": "Penicillin"}]
    if outcome == "unavailable":
        db.tables["allergies"] = DBError("Unavailable")

    response = client.post(
        "/api/v1/scan/prescription",
        files={"image": ("fixture.jpg", b"\xff\xd8\xff\x00", "image/jpeg")},
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
