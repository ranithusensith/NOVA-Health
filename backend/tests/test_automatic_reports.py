import httpx
import pytest
from fastapi.testclient import TestClient

import main
from fakes import script_llm

OWNER = "00000000-0000-4000-8000-000000000016"
OTHER = "00000000-0000-4000-8000-000000000017"
BASE = "/api/v1/reports/automatic"
AUTH = {"Authorization": "Bearer synthetic-session"}
DETAIL = BASE + "/2026-03-08"
SAFE_ROW = {
    "local_date": "2026-03-08", "time_zone": "America/New_York", "generated_at": "2026-03-09T12:00:00Z",
    "observations": {
        "water_ml": 325, "water_goal_ml": 850, "sleep_hours": 7.5, "sleep_source": "manual",
        "steps": 0, "steps_source": "health_connect", "meal_count": 1, "calories": None,
        "dose_confirmations": None, "symptom_onsets": None,
    },
}


@pytest.fixture
def session(monkeypatch):
    origin = "https://supabase.invalid"
    monkeypatch.setattr(main, "SUPABASE_URL", origin)
    monkeypatch.setattr(main, "SUPABASE_PUBLISHABLE_KEY", "synthetic-publishable")
    monkeypatch.setenv("SUPABASE_URL", origin)
    script_llm(monkeypatch, [])
    calls = []
    responses = {}

    async def send(_, request, **kwargs):
        assert request.url.host == "supabase.invalid"
        assert request.headers["Authorization"] == AUTH["Authorization"]
        if request.url.path == "/auth/v1/user":
            return httpx.Response(200, json={"id": OWNER})
        if "/rpc/" not in request.url.path:
            assert request.url.params["user_id"] == "eq." + OWNER
        calls.append(request)
        return responses[request.url.path]

    monkeypatch.setattr(httpx.AsyncClient, "send", send)
    return TestClient(main.app), calls, responses


def test_reads_are_account_bound_no_store_and_deterministic(session):
    client, calls, responses = session
    responses["/rest/v1/daily_report_settings"] = httpx.Response(200, json=[{"time_zone": "America/New_York"}])
    responses["/rest/v1/daily_report_snapshots"] = httpx.Response(200, json=[
        {key: value for key, value in SAFE_ROW.items() if key != "observations"},
    ])
    index = client.get(BASE, headers=AUTH)
    assert index.status_code == 200 and index.headers["cache-control"] == "no-store"
    assert index.json()["data"]["time_zone"] == "America/New_York"
    assert "observations" not in calls[-1].url.params["select"]

    responses["/rest/v1/daily_report_snapshots"] = httpx.Response(200, json=[SAFE_ROW])
    detail = client.get(DETAIL, headers=AUTH)
    assert detail.status_code == 200 and detail.headers["cache-control"] == "no-store"
    report = detail.json()["data"]["report"]
    assert "325 mL logged" in report and "850 mL" in report
    assert "7.5 hours (manual log)" in report and "0 steps (Health Connect)" in report
    assert "Estimated calories from confirmed meals: unknown" in report
    assert "Symptom entries with onset on this date: unknown" in report
    assert "should drink" not in report and "missed dose" not in report


def test_missing_snapshot_is_unavailable_and_invalid_fields_do_not_become_claims(session):
    client, _, responses = session
    path = "/rest/v1/daily_report_snapshots"
    responses[path] = httpx.Response(200, json=[])
    assert client.get(DETAIL, headers=AUTH).status_code == 404
    responses[path] = httpx.Response(200, json=[{**SAFE_ROW, "observations": {
        "sleep_hours": "Synthetic invented diagnosis",
        "steps": 4200, "steps_source": "Synthetic invented source",
        "water_goal_ml": -500, "dose_confirmations": True,
    }}])
    result = client.get(DETAIL, headers=AUTH)
    assert result.status_code == 200
    assert "Synthetic invented" not in result.text and "4200" not in result.text
    assert "Activity: unknown" in result.text and "Saved water target: unknown" in result.text


def test_schedule_and_notice_write_use_authenticated_rpc(session):
    import json

    client, calls, responses = session
    responses["/rest/v1/rpc/set_daily_report_schedule"] = httpx.Response(204)
    responses["/rest/v1/rpc/claim_daily_report_notice"] = httpx.Response(200, json=True)
    settings = {"expected_account": OWNER, "enabled": True, "time_zone": "Asia/Colombo"}
    assert client.put(BASE, headers=AUTH, json=settings).json()["data"] == {"enabled": True}
    assert json.loads(calls[-1].content) == {"expected_account": OWNER, "enabled": True, "zone_name": "Asia/Colombo"}
    assert client.post(BASE + "/notice", headers=AUTH, json={"expected_account": OWNER}).json()["data"] == {"claimed": True}
    assert json.loads(calls[-1].content) == {"expected_account": OWNER}
    assert client.put(BASE, headers=AUTH, json={**settings, "enabled": False}).json()["data"] == {"enabled": False}
    assert json.loads(calls[-1].content)["zone_name"] is None


def test_wrong_account_invalid_zone_and_missing_auth_cannot_access_reports(session):
    client, calls, _ = session
    assert client.get(BASE).status_code == 401
    assert client.put(BASE, headers=AUTH, json={
        "expected_account": OTHER, "enabled": True, "time_zone": "UTC",
    }).status_code == 403
    assert client.post(BASE + "/notice", headers=AUTH, json={"expected_account": OTHER}).status_code == 403
    response = client.put(BASE, headers=AUTH, json={
        "expected_account": OWNER, "enabled": True, "time_zone": "INVALID/ZONE",
    })
    assert response.status_code == 400 and response.json()["error"]["code"] == "INVALID_REPORT_ZONE"
    assert not calls
