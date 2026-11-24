import logging
import sys
from pathlib import Path
from uuid import uuid4

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import main
import notify
from db import DBError

# Reserved synthetic North American fiction numbers. Every provider call is mocked.
ACCOUNT = "AC" + "a" * 32
MESSAGE = "SM" + "b" * 32
PHONE_A = "+12025550101"
PHONE_B = "+12025550102"
TRIGGER = "/api/v1/emergency/trigger"


class FakeDB:
    user_id = "synthetic-owner"

    def __init__(self):
        self.contacts = [{"id": "contact-a", "phone": PHONE_A}]
        self.audit = []

    async def select(self, table, columns, **kwargs):
        if table == "emergency_contacts":
            assert kwargs["filters"] == {"user_id": f"eq.{self.user_id}"}
            if isinstance(self.contacts, Exception):
                raise self.contacts
            return self.contacts
        assert table == "profiles"
        return [{"full_name": "Synthetic User"}]

    async def insert(self, table, rows):
        assert table == "audit_log"
        self.audit.append(rows)


@pytest.fixture
def db():
    return FakeDB()


@pytest.fixture
def client(db, monkeypatch):
    async def forbid_network(*args, **kwargs):
        raise AssertionError("All provider traffic must be mocked")

    monkeypatch.setattr(httpx.AsyncClient, "post", forbid_network)
    monkeypatch.setattr(httpx.AsyncClient, "get", forbid_network)
    monkeypatch.setenv("NOTIFY_PROVIDER", "log")
    monkeypatch.setenv("TWILIO_ACCOUNT_SID", ACCOUNT)
    monkeypatch.setenv("TWILIO_AUTH_TOKEN", "synthetic-test-token")
    monkeypatch.setenv("TWILIO_FROM", "+12025550103")
    monkeypatch.setattr(main, "_sos_last", {})
    monkeypatch.setattr(main, "_sos_sending", set())
    monkeypatch.setattr(main, "_sos_attempts", {})
    monkeypatch.setitem(main.app.dependency_overrides, main.get_db, lambda: db)
    monkeypatch.setitem(main.app.dependency_overrides, main.current_user, lambda: {"id": db.user_id})
    with TestClient(main.app) as test_client:
        yield test_client


def message(status, *, sid=MESSAGE, account=ACCOUNT, code=200):
    return httpx.Response(code, json={"sid": sid, "account_sid": account, "status": status})


def mock_post(monkeypatch, *, status="queued"):
    async def post(*args, **kwargs):
        assert kwargs["auth"] == (ACCOUNT, "synthetic-test-token")
        return message(status, code=201)

    monkeypatch.setattr(httpx.AsyncClient, "post", post)


def mock_poll(monkeypatch, *, status="delivered", sid=MESSAGE, account=ACCOUNT):
    async def get(*args, **kwargs):
        response = message(status, sid=sid, account=account)
        return httpx.Response(200, json=response.json(), request=httpx.Request("GET", args[1]))

    monkeypatch.setattr(httpx.AsyncClient, "get", get)


def request_status(client, data):
    return client.get(f"/api/v1/emergency/{data['attempt_id']}/status")


def test_simulation_is_explicit_and_keeps_contact_data_out_of_logs(client, db, caplog):
    with caplog.at_level(logging.INFO):
        response = client.post(TRIGGER, json={"note": "synthetic private note"})
    assert response.status_code == 200
    result = response.json()["data"]
    assert result["status"] == "simulated"
    assert result["simulated"] is True
    assert result["delivered"] is False
    assert result["recipients"] == [{"contact_id": "contact-a", "status": "manual_required"}]
    for sensitive in (PHONE_A, "Synthetic User", "synthetic private note", "contact-a"):
        assert sensitive not in caplog.text
        assert sensitive not in str(db.audit)


def test_unexpected_background_audit_failure_has_no_trace(client, db, caplog):
    secret = f"Synthetic contact {PHONE_A} and private note"

    async def broken_audit(*args):
        raise RuntimeError(secret)

    db.insert = broken_audit
    response = client.post(TRIGGER, json={"note": secret})
    assert response.status_code == 200
    assert response.json()["data"]["status"] == "simulated"
    assert "SOS audit could not be recorded" in caplog.text
    assert secret not in response.text + caplog.text
    assert all(record.exc_info is None for record in caplog.records)


def test_manual_mode_requires_the_phone_composer(client, monkeypatch):
    monkeypatch.setenv("NOTIFY_PROVIDER", "manual")
    result = client.post(TRIGGER).json()["data"]
    assert result["status"] == "manual_required"
    assert result["delivered"] is False


def test_zero_contacts_is_safe_and_does_not_consume_cooldown(client, db, monkeypatch):
    monkeypatch.setenv("NOTIFY_PROVIDER", "twilio")
    db.contacts = []
    for _ in range(2):
        result = client.post(TRIGGER).json()["data"]
        assert result["status"] == "no_contacts"
        assert result["contacts_total"] == 0
        assert result["delivered"] is False


@pytest.mark.parametrize("provider_status", ["accepted", "queued", "sending"])
def test_acceptance_is_queued_until_receipt(client, monkeypatch, provider_status):
    monkeypatch.setenv("NOTIFY_PROVIDER", "twilio")
    mock_post(monkeypatch, status=provider_status)
    result = client.post(TRIGGER).json()["data"]
    assert result["status"] == "queued"
    assert result["contacts_notified"] == 0
    assert result["delivered"] is False
    assert result["can_refresh"] is True

    mock_poll(monkeypatch, status="sent")
    pending = request_status(client, result).json()["data"]
    assert pending["status"] == "sent"
    assert pending["delivered"] is False

    mock_poll(monkeypatch)
    delivered = request_status(client, result).json()["data"]
    assert delivered["status"] == "delivered"
    assert delivered["delivered"] is True
    assert delivered["contacts_notified"] == 1
    assert delivered["can_refresh"] is False


def test_create_response_alone_cannot_confirm_delivery(client, monkeypatch):
    monkeypatch.setenv("NOTIFY_PROVIDER", "twilio")
    mock_post(monkeypatch, status="delivered")
    result = client.post(TRIGGER).json()["data"]
    assert result["status"] == "sent"
    assert result["delivered"] is False


@pytest.mark.parametrize("key,value", [("sid", "SM" + "c" * 32), ("account", "AC" + "d" * 32)])
def test_mismatched_provider_receipt_cannot_confirm_delivery(client, monkeypatch, key, value):
    monkeypatch.setenv("NOTIFY_PROVIDER", "twilio")
    mock_post(monkeypatch)
    result = client.post(TRIGGER).json()["data"]
    mock_poll(monkeypatch, **{key: value})
    polled = request_status(client, result).json()["data"]
    assert polled["delivered"] is False
    assert polled["status_check_unavailable"] is True


def test_partial_failure_remains_visible_after_other_recipient_is_delivered(client, db, monkeypatch):
    monkeypatch.setenv("NOTIFY_PROVIDER", "twilio")
    db.contacts.append({"id": "contact-b", "phone": PHONE_B})

    async def post(*args, **kwargs):
        if kwargs["data"]["To"] == PHONE_B:
            # The upstream error body may contain private data. The app must not return it.
            return httpx.Response(400, json={"message": PHONE_B})
        return message("queued", code=201)

    monkeypatch.setattr(httpx.AsyncClient, "post", post)
    response = client.post(TRIGGER)
    assert PHONE_B not in response.text
    initial = response.json()["data"]
    assert initial["status"] == "partial_failure"
    assert initial["delivered"] is False
    mock_poll(monkeypatch)
    result = request_status(client, initial).json()["data"]
    assert result["status"] == "partial_failure"
    assert result["delivered"] is False
    assert result["contacts_notified"] == 1
    assert result["recipients"] == [
        {"contact_id": "contact-a", "status": "delivered"},
        {"contact_id": "contact-b", "status": "failed"},
    ]


def test_provider_undelivered_becomes_failed(client, monkeypatch):
    monkeypatch.setenv("NOTIFY_PROVIDER", "twilio")
    mock_post(monkeypatch)
    initial = client.post(TRIGGER).json()["data"]
    mock_poll(monkeypatch, status="undelivered")
    failed = request_status(client, initial).json()["data"]
    assert failed["status"] == "failed"
    assert failed["delivered"] is False
    assert failed["can_refresh"] is False


def test_provider_timeout_is_unknown_and_not_a_delivery(client, monkeypatch):
    async def timeout(*args, **kwargs):
        raise httpx.ReadTimeout("Synthetic request timed out")

    monkeypatch.setenv("NOTIFY_PROVIDER", "twilio")
    monkeypatch.setattr(httpx.AsyncClient, "post", timeout)
    result = client.post(TRIGGER).json()["data"]
    assert result["status"] == "unknown"
    assert result["delivered"] is False


def test_missing_provider_configuration_is_failed_without_network(client, monkeypatch):
    monkeypatch.setenv("NOTIFY_PROVIDER", "twilio")
    monkeypatch.delenv("TWILIO_AUTH_TOKEN")
    result = client.post(TRIGGER).json()["data"]
    assert result["status"] == "failed"
    assert result["delivered"] is False


def test_unavailable_database_does_not_report_success(client, db):
    db.contacts = DBError("Synthetic database is offline")
    assert client.post(TRIGGER).status_code == 502
    db.contacts = []
    assert client.post(TRIGGER).json()["data"]["status"] == "no_contacts"


def test_status_is_only_available_to_the_owner(client, monkeypatch):
    monkeypatch.setenv("NOTIFY_PROVIDER", "twilio")
    mock_post(monkeypatch)
    result = client.post(TRIGGER).json()["data"]
    monkeypatch.setitem(main.app.dependency_overrides, main.current_user, lambda: {"id": "other-user"})
    assert request_status(client, result).status_code == 404


def test_sos_endpoints_require_authentication():
    with TestClient(main.app) as client:
        assert client.post(TRIGGER).status_code == 401
        assert client.get(f"/api/v1/emergency/{uuid4()}/status").status_code == 401
