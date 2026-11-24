import asyncio
import hmac
import json
from uuid import uuid4

import httpx
import pytest
from fastapi.testclient import TestClient

import main
import rules
from db import DBError, UserDB

ALICE = "00000000-0000-0000-0000-000000000001"
BOB = "00000000-0000-0000-0000-000000000002"
ENDPOINT = "/api/v1/medications/confirm"


class MedicationDB:
    def __init__(self):
        self.user_id = ALICE
        self.medications = []
        self.allergies = []
        self.profile = [{"conditions": []}]
        self.unavailable_table = None
        self.stale_write = False
        self.context_version = str(uuid4())
        self.writes = []

    async def select(self, table, columns, *, filters, **kwargs):
        if table == self.unavailable_table:
            raise DBError("synthetic lookup failure")
        if table == "profiles":
            return self.profile
        if table == "allergies":
            return self.allergies
        assert table == "medications"
        own_rows = [row for row in self.medications if row["user_id"] == self.user_id]
        if filters.get("id", "").startswith("eq."):
            return [row for row in own_rows if f'eq.{row["id"]}' == filters["id"]]
        assert filters["status"] == "eq.confirmed"
        return [
            row for row in own_rows if row["status"] == "confirmed" and f'neq.{row["id"]}' != filters.get("id")
        ]

    async def medication_safety_version(self):
        return self.context_version

    async def save_reviewed_medications(self, payload, signature):
        key = bytes.fromhex("a1" * 32)
        assert signature == hmac.digest(key, b"medication-write:" + payload.encode(), "sha256").hex()
        review = json.loads(payload)
        assert review["account"] == self.user_id
        assert review["context_version"] == self.context_version
        if self.stale_write:
            return False
        self.writes.append(review)
        return True


@pytest.fixture
def db():
    return MedicationDB()


@pytest.fixture
def client(db, monkeypatch):
    monkeypatch.setitem(main.app.dependency_overrides, main.get_db, lambda: db)
    with TestClient(main.app) as client:
        yield client


@pytest.fixture
def draft():
    return {
        "draft_id": str(uuid4()), "expected_account_id": ALICE, "timing": "daily", "name": "Cetirizine",
        "dosage": "10 mg", "times": ["20:00"], "start_date": "2026-11-23", "end_date": None,
        "reminders_enabled": False, "instructions": "Synthetic original directions",
    }


def test_manual_creation_reviews_and_saves_actual_schedule_without_reminders(client, db, draft):
    response = client.post(ENDPOINT, json=draft)
    assert response.headers["cache-control"] == "no-store"
    assert response.json()["data"] == {"safety_check_status": "completed", "warnings": [], "activated": True}
    review, = db.writes
    assert review["expected_revision"] is None
    row, = review["rows"]
    assert row == {
        "name": draft["name"], "dosage": draft["dosage"], "times": ["20:00"], "start_date": "2026-11-23",
        "end_date": None, "reminders_enabled": False, "user_id": ALICE, "source": "manual",
        "status": "confirmed", "prescription_plan": {"kind": "daily", "instructions": draft["instructions"]},
        "id": row["id"],
    }


def test_acknowledgement_is_required_for_final_details_and_current_warnings(client, db, draft):
    draft["name"] = "Amoxicillin"
    db.allergies = [{"name": "Penicillin"}]
    first = client.post(ENDPOINT, json=draft).json()["data"]
    assert not first["activated"] and first["warnings"][0]["severity"] == "high"
    assert db.writes == []

    draft.update(review_token=first["review_token"], dosage="Synthetic revised dose")
    edited = client.post(ENDPOINT, json=draft).json()["data"]
    assert not edited["activated"] and edited["review_token"] != first["review_token"]
    assert db.writes == []

    draft["review_token"] = edited["review_token"]
    db.allergies = [{"name": "Amoxicillin"}]
    updated = client.post(ENDPOINT, json=draft).json()["data"]
    assert not updated["activated"] and updated["review_token"] != edited["review_token"]
    assert db.writes == []

    draft["review_token"] = updated["review_token"]
    assert client.post(ENDPOINT, json=draft).json()["data"]["activated"]
    assert db.writes[0]["rows"][0]["dosage"] == "Synthetic revised dose"


def test_context_change_requires_fresh_acknowledgement_even_for_same_warning(client, db, draft):
    draft["name"] = "Amoxicillin"
    db.allergies = [{"name": "Penicillin"}]
    first = client.post(ENDPOINT, json=draft).json()["data"]
    draft["review_token"] = first["review_token"]

    db.context_version = str(uuid4())
    updated = client.post(ENDPOINT, json=draft).json()["data"]
    assert updated["warnings"] == first["warnings"]
    assert not updated["activated"] and updated["review_token"] != first["review_token"]
    assert db.writes == []


@pytest.mark.parametrize("failure", ["allergies", "profiles", "medications", "rules", "missing_key", "missing_profile", "missing_context"])
def test_failed_or_unavailable_safety_check_blocks_activation(client, db, draft, monkeypatch, failure):
    draft["review_token"] = "f" * 64
    if failure == "missing_key":
        monkeypatch.delenv("MEDICATION_REVIEW_SIGNING_KEY")
    elif failure == "missing_profile":
        db.profile = []
    elif failure == "missing_context":
        db.context_version = None
    elif failure == "rules":
        def broken_rules(*args):
            raise ValueError("synthetic rules failure")
        monkeypatch.setattr(rules, "check_all", broken_rules)
    else:
        db.unavailable_table = failure
    result = client.post(ENDPOINT, json=draft).json()["data"]
    assert result == {"safety_check_status": "unavailable", "warnings": [], "activated": False}
    assert db.writes == []


def test_manual_written_frequency_uses_the_same_dose_rules(client, db, draft):
    draft.update(
        name="Paracetamol", dosage="2500 mg per dose", frequency="twice daily", times=["07:00", "19:00"],
    )
    result = client.post(ENDPOINT, json=draft).json()["data"]
    assert not result["activated"] and result["warnings"][0]["severity"] == "high"
    assert db.writes == []


def edit_draft(db, draft, *, source="scan", plan=None, name="Ibuprofen"):
    draft.pop("timing")
    draft.pop("instructions")
    draft["medication_id"] = str(uuid4())
    draft["expected_revision"] = str(uuid4())
    draft["name"] = name
    db.medications.append({
        "id": draft["medication_id"], "review_revision": draft["expected_revision"], "status": "confirmed",
        "user_id": ALICE, "source": source, "prescription_plan": plan, "start_date": draft["start_date"],
        "name": name, "times": draft["times"],
    })


def test_edit_replaces_own_row_in_check_and_preserves_original_directions(client, db, draft):
    plan = {"kind": "daily", "frequency": "once daily", "dosage_text": "Printed dose",
            "instructions": "Synthetic printed directions", "duration_text": "Synthetic course"}
    edit_draft(db, draft, plan=plan)
    draft.update(times=["19:00"], dosage="Updated recorded dose")
    response = client.post(ENDPOINT, json=draft).json()["data"]
    assert response["activated"] and response["warnings"] == []
    review, = db.writes
    row, = review["rows"]
    assert review["expected_revision"] == draft["expected_revision"]
    assert row["id"] == draft["medication_id"]
    assert row["prescription_plan"] == plan
    assert row["source"] == "scan" and row["times"] == ["19:00"]


def test_edit_excludes_only_target_and_rechecks_other_current_medications(client, db, draft):
    edit_draft(db, draft, source="manual")
    db.medications.append({
        "id": str(uuid4()), "user_id": ALICE, "status": "confirmed", "name": "Naproxen", "times": [],
    })
    response = client.post(ENDPOINT, json=draft).json()["data"]
    assert not response["activated"]
    assert "Ibuprofen, Naproxen" in response["warnings"][0]["message"]
    assert db.writes == []


def test_prn_creation_and_edit_keep_instructions_and_disable_scheduling(client, db, draft):
    draft.update(times=[], timing="as_needed")
    result = client.post(ENDPOINT, json=draft).json()["data"]
    assert result["activated"]
    row, = db.writes[0]["rows"]
    assert row["times"] == [] and not row["reminders_enabled"]
    assert row["prescription_plan"] == {"kind": "as_needed", "instructions": "Synthetic original directions"}

    edit_draft(db, draft, source="manual", plan=row["prescription_plan"], name="Cetirizine")
    draft.update(reminders_enabled=True)
    assert client.post(ENDPOINT, json=draft).status_code == 422
    draft.update(reminders_enabled=False)
    assert client.post(ENDPOINT, json=draft).json()["data"]["activated"]
    assert db.writes[-1]["rows"][0]["prescription_plan"] == row["prescription_plan"]

    draft.update(timing="daily", times=["07:00"])
    assert client.post(ENDPOINT, json=draft).json()["data"]["activated"]
    plan = db.writes[-1]["rows"][0]["prescription_plan"]
    assert plan == {"kind": "daily", "instructions": "Synthetic original directions"}


def test_prescribed_interval_anchor_and_instructions_are_preserved(client, db, draft):
    plan = {"kind": "interval", "first_dose_at": "2026-11-23T22:00:00+05:30", "interval_minutes": 360,
            "instructions": "Synthetic printed directions"}
    draft["times"] = []
    edit_draft(db, draft, plan=plan, name="Cetirizine")
    assert client.post(ENDPOINT, json={**draft, "start_date": "2026-11-24"}).status_code == 422
    assert client.post(ENDPOINT, json={**draft, "timing": "daily", "times": ["07:00"]}).status_code == 422
    assert client.post(ENDPOINT, json=draft).json()["data"]["activated"]
    assert db.writes[0]["rows"][0]["prescription_plan"] == plan


def test_unreadable_legacy_interval_cannot_be_saved(client, db, draft):
    draft["times"] = []
    edit_draft(db, draft, plan={"kind": "interval", "first_dose_at": "invalid"}, name="Cetirizine")
    result = client.post(ENDPOINT, json=draft).json()["data"]
    assert result == {"safety_check_status": "unavailable", "warnings": [], "activated": False}
    assert db.writes == []


def test_review_token_and_target_are_account_bound(client, db, draft):
    draft["name"] = "Amoxicillin"
    db.allergies = [{"name": "Penicillin"}]
    token = client.post(ENDPOINT, json=draft).json()["data"]["review_token"]
    db.user_id = BOB
    draft["review_token"] = token
    assert client.post(ENDPOINT, json=draft).status_code == 403
    draft["expected_account_id"] = BOB
    result = client.post(ENDPOINT, json=draft).json()["data"]
    assert not result["activated"] and result["review_token"] != token

    edit_draft(db, draft)
    assert client.post(ENDPOINT, json=draft).status_code == 404
    assert db.writes == []


def test_stale_edit_is_rejected_before_or_during_save(client, db, draft):
    edit_draft(db, draft)
    stale = {**draft, "expected_revision": str(uuid4())}
    assert client.post(ENDPOINT, json=stale).status_code == 409
    db.stale_write = True
    assert client.post(ENDPOINT, json=draft).status_code == 409
    assert db.writes == []


def test_requires_authentication(draft):
    with TestClient(main.app) as client:
        assert client.post(ENDPOINT, json=draft).status_code == 401


@pytest.mark.parametrize("db_response", [True, False, {"saved": True}])
def test_reviewed_write_rpc_forwards_only_callers_token(monkeypatch, db_response):
    async def post(client, url, *, json, headers):
        assert url == "https://synthetic.invalid/rest/v1/rpc/save_reviewed_medications"
        assert headers["Authorization"] == "Bearer synthetic-patient-token"
        assert headers["apikey"] == "synthetic-publishable"
        assert json == {"review_payload": "reviewed", "review_signature": "signature"}
        return httpx.Response(200, json=db_response)

    monkeypatch.setenv("SUPABASE_URL", "https://synthetic.invalid")
    monkeypatch.setenv("SUPABASE_PUBLISHABLE_KEY", "synthetic-publishable")
    monkeypatch.setattr(httpx.AsyncClient, "post", post)
    db = UserDB("synthetic-patient-token", ALICE)
    if type(db_response) is bool:
        assert asyncio.run(db.save_reviewed_medications("reviewed", "signature")) is db_response
    else:
        with pytest.raises(DBError):
            asyncio.run(db.save_reviewed_medications("reviewed", "signature"))
