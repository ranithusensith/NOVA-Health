"""City-level, model-derived weather kept separate from patient records."""

import asyncio
import os
import unicodedata
from collections import OrderedDict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from math import isfinite
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import httpx

from upstream import decode_json

SOURCE = "Open-Meteo"
FRESH_FOR = timedelta(minutes=15)
MAX_CURRENT_AGE = timedelta(hours=1)
KEEP_FOR = timedelta(hours=3)
CACHE_LIMIT = 128
TIMEOUT = 4.0
MAX_CITY_ID = 2_147_483_647


class Unavailable(Exception):
    pass


class CityNotFound(Exception):
    pass


@dataclass(frozen=True)
class City:
    id: int
    name: str
    region: str
    country: str
    latitude: float
    longitude: float
    zone: ZoneInfo

    def public(self) -> dict:
        return {"id": self.id, "name": self.name, "region": self.region, "country": self.country}


def now() -> datetime:
    return datetime.now(timezone.utc)


def city_query(raw: str) -> str:
    query = " ".join(raw.split())
    if not 2 <= len(query) <= 80 or sum(c.isalpha() for c in query) < 2:
        raise ValueError("A city name is required")
    if any(not (unicodedata.category(c)[0] in "LM" or c in " .,'’-") for c in query):
        raise ValueError("Enter a city name, optionally followed by its region or country")
    return query


def _number(value, minimum, maximum):
    if (type(value) not in (int, float) or not minimum <= value <= maximum
            or not isfinite(value)):
        return None
    return value


def _label(value) -> str:
    return " ".join(value.split())[:100] if isinstance(value, str) else ""


def _city(row) -> City | None:
    if not isinstance(row, dict):
        return None
    identifier, feature, zone = (row.get(key) for key in ("id", "feature_code", "timezone"))
    lat = _number(row.get("latitude"), -90, 90)
    lon = _number(row.get("longitude"), -180, 180)
    name = _label(row.get("name"))
    if (type(identifier) is not int or not 1 <= identifier <= MAX_CITY_ID
            or not isinstance(feature, str) or not feature.startswith("PPL")
            or not name or lat is None or lon is None or not isinstance(zone, str)):
        return None
    try:
        return City(identifier, name, _label(row.get("admin1")), _label(row.get("country")), lat, lon, ZoneInfo(zone))
    except (ValueError, ZoneInfoNotFoundError):
        return None


def _condition(code):
    if type(code) is not int:
        return None
    return {
        0: "Clear", 1: "Mainly clear", 2: "Partly cloudy", 3: "Overcast",
        45: "Fog", 48: "Fog", 51: "Drizzle", 53: "Drizzle", 55: "Drizzle",
        56: "Freezing drizzle", 57: "Freezing drizzle",
        61: "Rain", 63: "Rain", 65: "Heavy rain", 66: "Freezing rain", 67: "Freezing rain",
        71: "Snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains",
        80: "Rain showers", 81: "Rain showers", 82: "Heavy showers",
        85: "Snow showers", 86: "Heavy snow showers",
        95: "Thunderstorms", 96: "Thunderstorms with hail", 99: "Thunderstorms with hail",
    }.get(code)


def _forecast(raw: dict, city: City, fetched: datetime) -> dict:
    current = raw.get("current")
    units = raw.get("current_units")
    observed = None
    conditions = None
    if isinstance(current, dict) and isinstance(units, dict):
        timestamp = current.get("time")
        if type(timestamp) is int:
            try:
                candidate = datetime.fromtimestamp(timestamp, timezone.utc)
                if fetched - KEEP_FOR < candidate <= fetched + timedelta(minutes=15):
                    observed = candidate
            except (ValueError, OverflowError, OSError):
                pass
        if observed is not None:
            conditions = {
                "temperature_c": _number(current.get("temperature_2m"), -100, 80)
                if units.get("temperature_2m") == "°C" else None,
                "feels_like_c": _number(current.get("apparent_temperature"), -120, 100)
                if units.get("apparent_temperature") == "°C" else None,
                "humidity_pct": _number(current.get("relative_humidity_2m"), 0, 100)
                if units.get("relative_humidity_2m") == "%" else None,
                "condition": _condition(current.get("weather_code"))
                if units.get("weather_code") == "wmo code" else None,
            }
            if not any(value is not None for value in conditions.values()):
                conditions = observed = None
    days = []
    daily = raw.get("daily")
    daily_units = raw.get("daily_units")
    if isinstance(daily, dict) and isinstance(daily_units, dict) and isinstance(daily.get("time"), list):
        local_today = fetched.astimezone(city.zone).date()
        seen = set()
        for index, timestamp in enumerate(daily["time"][:3]):
            if type(timestamp) is not int:
                continue
            try:
                day = datetime.fromtimestamp(timestamp, city.zone).date()
            except (OverflowError, ValueError, OSError):
                continue
            if day in seen or not local_today <= day <= local_today + timedelta(days=2):
                continue
            seen.add(day)

            def field(key, unit):
                values = daily.get(key)
                return values[index] if (isinstance(values, list) and index < len(values)
                                         and daily_units.get(key) == unit) else None

            low = _number(field("temperature_2m_min", "°C"), -100, 80)
            high = _number(field("temperature_2m_max", "°C"), -100, 80)
            if low is not None and high is not None and high < low:
                low = high = None
            info = {
                "low_c": low, "high_c": high,
                "precipitation_pct": _number(field("precipitation_probability_max", "%"), 0, 100),
                "condition": _condition(field("weather_code", "wmo code")),
            }
            if any(value is not None for value in info.values()):
                days.append({"date": day.isoformat(), **info})
    if conditions is None and not days:
        raise Unavailable
    fresh = fetched + FRESH_FOR
    expires = fetched + KEEP_FOR
    if observed is not None:
        fresh = min(fresh, observed + MAX_CURRENT_AGE)
        expires = min(expires, observed + KEEP_FOR)
    return {"city": city.public(), "source": SOURCE, "observed_at": observed,
            "fetched_at": fetched, "fresh_until": fresh, "expires_at": expires,
            "current": conditions, "forecast": days}


def wellness(snapshot: dict) -> str | None:
    current = snapshot.get("current") or {}
    feels = current.get("feels_like_c")
    if feels is not None and feels >= 32:
        return "If you are outdoors in the heat, consider taking breaks in a cooler place. Follow any fluid instructions from your care team."
    outlook = snapshot.get("forecast") or []
    chance = outlook[0]["precipitation_pct"] if outlook else None
    if chance is not None and chance >= 60:
        return "If you plan to be outdoors, check local conditions before leaving."
    return None


class WeatherService:
    def __init__(self):
        self._cache: OrderedDict[tuple[str, int], tuple[City, dict]] = OrderedDict()

    @staticmethod
    def _provider() -> tuple[str, str | None]:
        mode = os.environ.get("WEATHER_PROVIDER", "")
        if mode == "open-meteo-public":
            return mode, None
        if mode == "open-meteo-customer" and (key := os.environ.get("OPEN_METEO_API_KEY", "").strip()):
            return mode, key
        raise Unavailable

    async def _get(self, host: str, path: str, params: dict, key: str | None) -> dict:
        if key:
            host = f"customer-{host}"
            params = {**params, "apikey": key}
        try:
            async with httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=False, trust_env=False) as client:
                response = await asyncio.wait_for(
                    client.get(f"https://{host}.open-meteo.com/v1/{path}", params=params),
                    timeout=TIMEOUT,
                )
            if response.status_code == 404 and path == "get":
                raise CityNotFound
            if len(response.content) > 128_000:
                raise Unavailable
            if response.status_code == 400 and path == "get":
                error = decode_json(response.content)
                if isinstance(error, dict) and error.get("reason") == "Location ID not found.":
                    raise CityNotFound
            if response.status_code != 200:
                raise Unavailable
            data = decode_json(response.content)
            if not isinstance(data, dict) or data.get("error"):
                raise Unavailable
            return data
        except (httpx.HTTPError, TimeoutError, ValueError):
            raise Unavailable from None

    async def search(self, query: str) -> list[dict]:
        _, key = self._provider()
        raw = await self._get("geocoding-api", "search", {"name": query, "count": 10, "language": "en"}, key)
        rows = raw.get("results", [])
        if not isinstance(rows, list):
            raise Unavailable
        return [city.public() for row in rows[:10] if (city := _city(row)) is not None]

    async def forecast(self, city_id: int) -> dict:
        try:
            mode, key = self._provider()
        except Unavailable:
            return {"status": "unavailable"}
        cache_key = mode, city_id
        cached = self._cache.get(cache_key)
        if cached and now() < cached[1]["fresh_until"]:
            self._cache.move_to_end(cache_key)
            return self._view(*cached, stale=False)
        city = cached[0] if cached else None
        try:
            if city is None:
                city = _city(await self._get("geocoding-api", "get", {"id": city_id}, key))
                if city is None or city.id != city_id:
                    raise CityNotFound
            raw = await self._get("api", "forecast", {
                "latitude": round(city.latitude, 2), "longitude": round(city.longitude, 2),
                "timezone": city.zone.key, "forecast_days": 3, "timeformat": "unixtime",
                "current": "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code",
                "daily": "temperature_2m_min,temperature_2m_max,precipitation_probability_max,weather_code",
            }, key)
            snapshot = _forecast(raw, city, now())
        except Unavailable:
            if cached and now() < cached[1]["expires_at"]:
                return self._view(*cached, stale=True)
            self._cache.pop(cache_key, None)
            return {"status": "unavailable"}
        if now() < snapshot["fresh_until"] or not cached:
            self._cache[cache_key] = city, snapshot
            self._cache.move_to_end(cache_key)
            if len(self._cache) > CACHE_LIMIT:
                self._cache.popitem(last=False)
        elif now() < cached[1]["expires_at"]:
            return self._view(*cached, stale=True)
        return self._view(city, snapshot, stale=now() >= snapshot["fresh_until"])

    @staticmethod
    def _view(city: City, snapshot: dict, *, stale: bool) -> dict:
        day = now().astimezone(city.zone).date()
        today = day.isoformat()
        forecast = [day for day in snapshot["forecast"] if day["date"] >= today]
        if snapshot["current"] is None and not forecast:
            return {"status": "unavailable"}
        next_midnight = datetime.combine(day + timedelta(days=1), datetime.min.time(), tzinfo=city.zone)
        data = {**snapshot, "forecast": forecast, "status": "stale" if stale else "live",
                "city_date": today, "city_day_ends_at": next_midnight}
        return {**data, "wellness": None if stale else wellness(data)}


service = WeatherService()


def outdoor_notice(snapshot: dict, city_id: int, at: datetime) -> dict:
    state = snapshot.get("status")
    if state == "stale":
        return {"status": "stale"}
    if state != "live" or snapshot.get("source") != SOURCE or (snapshot.get("city") or {}).get("id") != city_id:
        return {"status": "unavailable"}
    fetched = snapshot.get("fetched_at")
    bounds = [snapshot.get(key) for key in ("fresh_until", "expires_at", "city_day_ends_at")]
    if not isinstance(fetched, datetime) or any(not isinstance(value, datetime) for value in bounds):
        return {"status": "unavailable"}
    valid_until = min(bounds)
    if not fetched <= at < valid_until:
        return {"status": "stale"}
    city_date = snapshot.get("city_date")
    matches = [day for day in snapshot["forecast"] if day["date"] == city_date]
    chance = _number(matches[0].get("precipitation_pct"), 0, 100) if len(matches) == 1 else None
    if chance is None:
        return {"status": "missing"}
    return {
        "status": "eligible" if chance >= 60 else "below_threshold",
        "city_id": city_id, "date": city_date, "source": SOURCE,
        "precipitation_pct": chance, "fetched_at": fetched, "valid_until": valid_until,
    }


def assistant_evidence(snapshot: dict) -> str | None:
    if snapshot["status"] != "live":
        return None
    city = snapshot["city"]
    location = ", ".join(filter(None, (city["name"], city["region"], city["country"])))
    lines = [f"Open-Meteo weather for {location}."]
    current = snapshot["current"]
    if current:
        facts = [
            current["condition"],
            f"{current['temperature_c']:g} °C" if current["temperature_c"] is not None else None,
            f"feels like {current['feels_like_c']:g} °C" if current["feels_like_c"] is not None else None,
            f"humidity {current['humidity_pct']:g}%" if current["humidity_pct"] is not None else None,
        ]
        observed = snapshot["observed_at"].strftime("%Y-%m-%d %H:%M UTC")
        lines.append(f"Model conditions at {observed}: {', '.join(filter(None, facts))}.")
    for day in snapshot["forecast"][:2]:
        facts = [
            day["condition"],
            f"low {day['low_c']:g} °C" if day["low_c"] is not None else None,
            f"high {day['high_c']:g} °C" if day["high_c"] is not None else None,
            f"up to {day['precipitation_pct']:g}% precipitation chance"
            if day["precipitation_pct"] is not None else None,
        ]
        lines.append(f"Forecast for {day['date']}: {', '.join(filter(None, facts))}.")
    if snapshot["wellness"]:
        lines.append(snapshot["wellness"])
    return "\n".join(lines)
