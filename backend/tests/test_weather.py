from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

import main
import weather
from fakes import FakeDB, enable_test_ai, script_llm


CITY = {
    "id": 13579, "name": "Synthetic City", "admin1": "Synthetic Region", "country": "Synthetic Country",
    "feature_code": "PPLC", "latitude": 6.9271, "longitude": 79.8612, "timezone": "Asia/Colombo",
}
NOW = datetime(2026, 11, 25, 6, tzinfo=timezone.utc)


def forecast():
    local_midnight = datetime(2026, 11, 24, 18, 30, tzinfo=timezone.utc)
    return {
        "current": {
            "time": int((NOW - timedelta(minutes=5)).timestamp()), "temperature_2m": 30.5,
            "apparent_temperature": 34, "relative_humidity_2m": 72, "weather_code": 2,
        },
        "current_units": {
            "temperature_2m": "°C", "apparent_temperature": "°C",
            "relative_humidity_2m": "%", "weather_code": "wmo code",
        },
        "daily": {
            "time": [int((local_midnight + timedelta(days=i)).timestamp()) for i in range(3)],
            "temperature_2m_min": [22, 23, 24], "temperature_2m_max": [31, 30, 29],
            "precipitation_probability_max": [60, 20, 0], "weather_code": [61, 2, 3],
        },
        "daily_units": {
            "temperature_2m_min": "°C", "temperature_2m_max": "°C",
            "precipitation_probability_max": "%", "weather_code": "wmo code",
        },
    }


@pytest.fixture
def session(monkeypatch):
    requests = []
    clock = [NOW]
    responses = {"search": {"results": [CITY, {**CITY, "feature_code": "ADM1"}]},
                 "get": CITY, "forecast": forecast()}

    async def send(client, request, **kwargs):
        requests.append(request)
        assert request.url.scheme == "https"
        assert request.url.host in {
            "geocoding-api.open-meteo.com", "api.open-meteo.com",
            "customer-geocoding-api.open-meteo.com", "customer-api.open-meteo.com",
        }
        assert "authorization" not in request.headers
        label = request.url.path.split("/")[-1]
        payload = responses[label]
        if isinstance(payload, Exception):
            raise payload
        if isinstance(payload, httpx.Response):
            return payload
        return httpx.Response(200, json=payload)

    monkeypatch.setenv("WEATHER_PROVIDER", "open-meteo-public")
    monkeypatch.setattr(httpx.AsyncClient, "send", send)
    monkeypatch.setattr(weather, "now", lambda: clock[0])
    monkeypatch.setattr(weather, "service", weather.WeatherService())
    monkeypatch.setattr(main, "_weather_counts", {})
    monkeypatch.setattr(main, "_chat_counts", {})
    db = FakeDB(user_id="synthetic-test-account")
    monkeypatch.setitem(main.app.dependency_overrides, main.current_user, lambda: {"id": db.user_id})
    monkeypatch.setitem(main.app.dependency_overrides, main.get_db, lambda: db)
    return TestClient(main.app), db, requests, responses, clock


def test_search_and_live_forecast_use_only_city_inputs_and_provider_units(session):
    client, _, requests, _, _ = session
    result = client.get("/api/v1/weather/cities", params={"query": "Synthetic City"})
    assert result.headers["cache-control"] == "no-store"
    assert result.json()["data"]["cities"] == [{
        "id": CITY["id"], "name": CITY["name"], "region": CITY["admin1"], "country": CITY["country"],
    }]
    response = client.get("/api/v1/weather/current", params={"city_id": CITY["id"]})
    data = response.json()["data"]
    assert data["status"] == "live" and data["source"] == "Open-Meteo"
    assert data["current"] == {"temperature_c": 30.5, "feels_like_c": 34, "humidity_pct": 72, "condition": "Partly cloudy"}
    assert data["forecast"][0] == {"date": "2026-11-25", "low_c": 22, "high_c": 31, "precipitation_pct": 60, "condition": "Rain"}
    assert "care team" in data["wellness"] and "drink more" not in data["wellness"]
    assert response.headers["cache-control"] == "no-store"
    assert "latitude" not in response.text and "longitude" not in response.text
    assert requests[-1].url.params["latitude"] == "6.93"
    assert requests[-1].url.params["longitude"] == "79.86"
    assert "apikey" not in requests[-1].url.params
    client.get("/api/v1/weather/current", params={"city_id": CITY["id"]})
    assert len(requests) == 3


def test_individual_missing_fields_stay_unknown_and_bad_units_are_rejected(session):
    client, _, _, responses, _ = session
    payload = responses["forecast"]
    payload["current"]["weather_code"] = 700
    payload["current_units"]["temperature_2m"] = "°F"
    payload["current"].pop("relative_humidity_2m")
    payload["daily"]["temperature_2m_min"] = [40]
    payload["daily"]["precipitation_probability_max"] = [None, 1]
    result = client.get("/api/v1/weather/current", params={"city_id": CITY["id"]}).json()["data"]
    assert result["status"] == "live"
    assert result["current"] == {"temperature_c": None, "feels_like_c": 34, "humidity_pct": None, "condition": None}
    assert result["forecast"][0]["low_c"] is result["forecast"][0]["high_c"] is None
    assert result["forecast"][0]["precipitation_pct"] is None


@pytest.mark.parametrize("problem", [httpx.ReadTimeout("fixture"), httpx.Response(503), httpx.Response(302)])
def test_provider_outage_uses_bounded_stale_cache_then_unavailable(session, problem):
    client, _, _, responses, clock = session
    endpoint = f"/api/v1/weather/current?city_id={CITY['id']}"
    assert client.get(endpoint).json()["data"]["status"] == "live"
    responses["forecast"] = problem
    clock[0] = NOW + timedelta(minutes=16)
    stale = client.get(endpoint).json()["data"]
    assert stale["status"] == "stale" and stale["current"]["temperature_c"] == 30.5
    assert stale["wellness"] is None and weather.assistant_evidence(stale) is None
    clock[0] = NOW + timedelta(hours=3)
    assert client.get(endpoint).json()["data"] == {"status": "unavailable"}


def test_provider_current_timestamp_controls_staleness_and_missing_current_stays_unknown(session):
    client, _, _, responses, _ = session
    payload = responses["forecast"]
    payload["current"]["time"] = int((NOW - timedelta(minutes=70)).timestamp())
    endpoint = f"/api/v1/weather/current?city_id={CITY['id']}"
    data = client.get(endpoint).json()["data"]
    assert data["status"] == "stale" and not data["wellness"]

    weather.service._cache.clear()
    del payload["current"]["time"]
    data = client.get(endpoint).json()["data"]
    assert data["status"] == "live" and data["current"] is None and data["observed_at"] is None
    assert data["forecast"]
    assert "Model conditions" not in weather.assistant_evidence({
        **data, "fetched_at": NOW, "fresh_until": NOW + timedelta(minutes=15),
    })


def test_invalid_unknown_and_unavailable_cities_are_distinct(session):
    client, _, requests, responses, _ = session
    assert client.get("/api/v1/weather/cities", params={"query": "22 Synthetic Street"}).status_code == 400
    assert not requests
    responses["search"] = {}
    assert client.get("/api/v1/weather/cities", params={"query": "Synthetic missing"}).json()["data"] == {"cities": []}
    responses["search"] = httpx.Response(503)
    assert client.get("/api/v1/weather/cities", params={"query": "Synthetic City"}).status_code == 503
    responses["get"] = httpx.Response(400, json={"reason": "Location ID not found.", "error": True})
    assert client.get("/api/v1/weather/current?city_id=42").status_code == 404
    assert client.get("/api/v1/weather/current?city_id=-1").status_code == 422


def test_provider_configuration_is_explicit_and_key_is_server_only(session, monkeypatch):
    client, _, requests, responses, _ = session
    monkeypatch.delenv("WEATHER_PROVIDER")
    endpoint = f"/api/v1/weather/current?city_id={CITY['id']}"
    assert client.get(endpoint).json()["data"] == {"status": "unavailable"}
    assert not requests
    monkeypatch.setenv("WEATHER_PROVIDER", "open-meteo-customer")
    monkeypatch.setenv("OPEN_METEO_API_KEY", "synthetic-test-credential")
    responses["forecast"] = httpx.Response(401, text="synthetic-test-credential")
    result = client.get(endpoint)
    assert result.json()["data"] == {"status": "unavailable"}
    assert "synthetic-test-credential" not in result.text
    assert all(request.url.host.startswith("customer-") for request in requests)
    assert all(request.url.params["apikey"] == "synthetic-test-credential" for request in requests)


def test_assistant_uses_weather_only_with_review_and_consent_keeps_it_out_of_ai(session, monkeypatch):
    client, db, requests, _, _ = session
    enable_test_ai(monkeypatch, db)
    prompts = []
    payload = {"message": "Help plan my afternoon", "reviewed": True}
    opt_in = {"city_id": CITY["id"], "consent": True}

    script_llm(monkeypatch, [{"action": "final"}], prompts)
    response = client.post("/api/v1/assistant/chat", json={**payload, "weather": {**opt_in, "consent": False}})
    assert response.status_code == 200 and not requests

    script_llm(monkeypatch, [{"action": "final", "answer": "Synthetic invented 95 degrees and personal risk"}], prompts)
    response = client.post("/api/v1/assistant/chat", json={**payload, "weather": opt_in})
    data = response.json()["data"]
    assert data["sources"] == ["weather"] and "Open-Meteo weather for Synthetic City" in data["reply"]
    assert "30.5 °C" in data["reply"] and "95 degrees" not in data["reply"]
    assert all(CITY["name"] not in prompt and "30.5" not in prompt and str(CITY["id"]) not in prompt for prompt in prompts)
    requests.clear()

    db.tables["ai_processing_consents"] = []
    assert client.post("/api/v1/assistant/chat", json={**payload, "weather": opt_in}).status_code == 403
    assert not requests
    assert client.post("/api/v1/assistant/chat", json={**payload, "weather": opt_in, "message": "I have chest pain now"}).json()["data"]["emergency"]
    assert not requests


def test_stale_forecast_does_not_become_assistant_evidence(session, monkeypatch):
    client, db, _, responses, clock = session
    enable_test_ai(monkeypatch, db)
    client.get(f"/api/v1/weather/current?city_id={CITY['id']}")
    clock[0] = NOW + timedelta(minutes=20)
    responses["forecast"] = httpx.Response(503)
    script_llm(monkeypatch, [{"action": "final"}])
    result = client.post("/api/v1/assistant/chat", json={
        "message": "Help plan my afternoon", "reviewed": True, "weather": {"city_id": CITY["id"], "consent": True},
    }).json()["data"]
    assert "Live weather for the selected city is unavailable." in result["reply"]
    assert "30.5" not in result["reply"] and result["sources"] == []


def test_weather_routes_require_authentication():
    assert TestClient(main.app).get("/api/v1/weather/current?city_id=42").status_code == 401
