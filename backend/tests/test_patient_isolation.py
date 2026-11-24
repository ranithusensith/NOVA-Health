import asyncio

import httpx
import pytest
from fastapi.testclient import TestClient

import main
from db import DBError, UserDB

ALICE = "00000000-0000-0000-0000-000000000101"
BOB = "00000000-0000-0000-0000-000000000102"


@pytest.fixture
def supabase(monkeypatch):
    requests = []
    url = "https://supabase.invalid"
    key = "sb_publishable_synthetic"
    monkeypatch.setattr(main, "SUPABASE_URL", url)
    monkeypatch.setattr(main, "SUPABASE_PUBLISHABLE_KEY", key)
    monkeypatch.setenv("SUPABASE_URL", url)
    monkeypatch.setenv("SUPABASE_PUBLISHABLE_KEY", key)

    async def send(_, request, **kwargs):
        requests.append(request)
        assert request.url.host == "supabase.invalid"
        assert request.headers["apikey"] == key
        token = request.headers["authorization"].split()[-1]
        if request.url.path == "/auth/v1/user":
            if token == "expired":
                return httpx.Response(403, json={"code": "bad_jwt"})
            if token == "invalid":
                return httpx.Response(401, json={"code": "bad_jwt"})
            if token == "outage":
                raise httpx.ConnectError("synthetic outage", request=request)
            if token == "invalid-user-response":
                return httpx.Response(200, json={"id": "missing UUID"})
            return httpx.Response(200, json={"id": {"alice": ALICE, "bob": BOB}[token]})
        if request.url.path.endswith("/rpc/delete_legacy_ai_chats"):
            return httpx.Response(200, json=1)
        if request.method == "GET":
            return httpx.Response(200, json=[])
        return httpx.Response(204)

    monkeypatch.setattr(httpx.AsyncClient, "send", send)
    return requests


@pytest.mark.parametrize("header", [None, "Basic synthetic", "Bearer ", "Bearer invalid", "Bearer expired"])
def test_rejected_sessions_never_reach_database(supabase, header):
    headers = {"Authorization": header} if header is not None else {}
    response = TestClient(main.app).delete("/api/v1/privacy/ai/chats", headers=headers)
    assert response.status_code == 401
    paths = [request.url.path for request in supabase]
    assert paths == (["/auth/v1/user"] if header in {"Bearer invalid", "Bearer expired"} else [])


@pytest.mark.parametrize("token", ["outage", "invalid-user-response"])
def test_auth_verification_failure_never_reaches_database(supabase, token):
    response = TestClient(main.app).get("/api/v1/privacy/ai", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 503
    assert [request.url.path for request in supabase] == ["/auth/v1/user"]


@pytest.mark.parametrize(("token", "owner"), [("alice", ALICE), ("bob", BOB)])
def test_consent_and_chat_cleanup_use_the_validated_account(supabase, token, owner):
    client = TestClient(main.app)
    headers = {"Authorization": f"Bearer {token}"}
    assert client.get("/api/v1/privacy/ai", headers=headers).status_code == 200
    assert client.post("/api/v1/privacy/ai", headers=headers, json={"enabled": False}).status_code == 200
    assert client.delete("/api/v1/privacy/ai/chats", headers=headers).json() == {"data": {"deleted": 1}}
    _, read, _, delete, _, rpc = supabase
    assert read.url.params["user_id"] == delete.url.params["user_id"] == f"eq.{owner}"
    assert rpc.content == b"{}"
    assert all(request.headers["authorization"] == f"Bearer {token}" for request in supabase)


def test_owner_filter_takes_precedence_and_foreign_inserts_never_leave_backend(supabase):
    db = UserDB("alice", ALICE)
    asyncio.run(db.select("profiles", filters={"id": f"eq.{BOB}"}))
    asyncio.run(db.select("medications", filters={"user_id": f"eq.{BOB}", "status": "eq.confirmed"}))
    with pytest.raises(DBError) as exc:
        asyncio.run(db.insert("medications", [{"user_id": ALICE}, {"user_id": BOB}]))
    assert exc.value.status == 403
    profile, meds = supabase
    assert profile.url.params["id"] == meds.url.params["user_id"] == f"eq.{ALICE}"
    assert meds.url.params["status"] == "eq.confirmed"
