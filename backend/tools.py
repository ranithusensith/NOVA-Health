"""
Read-only tools the assistant may call. Each returns small, summarised data
(never raw rows, never the user's name or date of birth).
"""

import os
import re
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Awaitable, Callable

import rules

TZ_OFFSET_MIN = int(os.environ.get("LOCAL_TZ_OFFSET_MIN", "330"))  # Sri Lanka = UTC+5:30


def local_tz() -> timezone:
    return timezone(timedelta(minutes=TZ_OFFSET_MIN))


def local_today() -> date:
    return datetime.now(local_tz()).date()


def parse_ts(value: str) -> datetime:
    """Parse a Supabase timestamptz string (any fraction length, 'Z' or offset)."""
    v = value.strip().replace("Z", "+00:00").replace(" ", "T")
    m = re.match(r"^(.*?\d{2}:\d{2}:\d{2})(\.\d+)?(.*)$", v)
    if m:
        frac = (m.group(2) or "")[1:7].ljust(6, "0") if m.group(2) else ""
        v = m.group(1) + ("." + frac if frac else "") + m.group(3)
    dt = datetime.fromisoformat(v)
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def local_day(value: str) -> date:
    return parse_ts(value).astimezone(local_tz()).date()


def day_bounds_utc(day: date) -> tuple[str, str]:
    start = datetime(day.year, day.month, day.day, tzinfo=local_tz())
    end = start + timedelta(days=1)
    fmt = lambda d: d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")  # noqa: E731
    return fmt(start), fmt(end)


def since_utc(days: int) -> str:
    today = local_today()
    start = datetime(today.year, today.month, today.day, tzinfo=local_tz()) - timedelta(days=days - 1)
    return start.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ------------------------------------------------------------------ pure summaries
KINDS = {
    "water": ("water_logs", "amount_ml,logged_at", "logged_at"),
    "sleep": ("sleep_logs", "hours,logged_at", "logged_at"),
    "mood": ("mood_logs", "mood,logged_at", "logged_at"),
    "meals": ("meal_logs", "description,calories,logged_at", "logged_at"),
    "symptoms": ("symptom_logs", "name,severity,status,started_at", "started_at"),
}


def _avg(values: list[float], digits: int = 1):
    return round(sum(values) / len(values), digits) if values else None


def summarize_logs(kind: str, rows: list[dict], days: int) -> dict:
    out: dict = {"kind": kind, "days": days}
    if kind == "symptoms":
        items = []
        for r in rows[:20]:
            items.append({
                "name": r.get("name"),
                "severity": r.get("severity"),
                "status": r.get("status"),
                "since": local_day(r["started_at"]).isoformat() if r.get("started_at") else None,
            })
        out["symptoms"] = items
        out["count"] = len(items)
        return out

    by_day: dict[str, list] = defaultdict(list)
    ts_key = "logged_at"
    for r in rows:
        if r.get(ts_key):
            by_day[local_day(r[ts_key]).isoformat()].append(r)

    if kind == "water":
        per_day = {d: sum(int(x.get("amount_ml") or 0) for x in v) for d, v in by_day.items()}
        out["ml_per_day"] = dict(sorted(per_day.items()))
        out["average_ml_on_logged_days"] = round(sum(per_day.values()) / len(per_day)) if per_day else None
    elif kind == "sleep":
        per_day = {d: round(sum(float(x.get("hours") or 0) for x in v), 1) for d, v in by_day.items()}
        out["hours_per_day"] = dict(sorted(per_day.items()))
        out["average_hours_on_logged_days"] = _avg(list(per_day.values()))
    elif kind == "mood":
        per_day = {d: [x.get("mood") for x in v] for d, v in by_day.items()}
        out["moods_per_day"] = dict(sorted(per_day.items()))
        out["low_or_bad_days"] = sum(1 for v in per_day.values() if any(m in ("low", "bad") for m in v))
    elif kind == "meals":
        per_day = {
            d: {"kcal": sum(int(x.get("calories") or 0) for x in v), "meals": len(v)} for d, v in by_day.items()
        }
        out["per_day"] = dict(sorted(per_day.items()))
        kc = [v["kcal"] for v in per_day.values()]
        out["average_kcal_on_logged_days"] = round(sum(kc) / len(kc)) if kc else None
    out["days_with_data"] = len(by_day)
    return out


def summarize_heart(rows: list[dict]) -> dict:
    vals = [(parse_ts(r["recorded_at"]), int(round(float(r["value"]))), r.get("context")) for r in rows
            if r.get("recorded_at") and r.get("value") is not None]
    if not vals:
        return {"count": 0, "note": "No heart rate readings in this period."}
    vals.sort(key=lambda x: x[0])
    bpm = [v[1] for v in vals]
    resting = [v[1] for v in vals if v[2] == "resting"]
    latest = vals[-1]
    return {
        "count": len(vals),
        "latest_bpm": latest[1],
        "latest_at": latest[0].astimezone(local_tz()).strftime("%Y-%m-%d %H:%M"),
        "average_bpm": round(sum(bpm) / len(bpm)),
        "min_bpm": min(bpm),
        "max_bpm": max(bpm),
        "resting_average_bpm": round(sum(resting) / len(resting)) if resting else None,
    }


def summarize_cycle(rows: list[dict], today: date | None = None) -> dict:
    today = today or local_today()
    periods = []
    for r in rows:
        try:
            start = date.fromisoformat(r["start_date"])
        except (KeyError, ValueError, TypeError):
            continue
        end = None
        if r.get("end_date"):
            try:
                end = date.fromisoformat(r["end_date"])
            except ValueError:
                end = None
        periods.append((start, end))
    if not periods:
        return {"logged_periods": 0, "note": "No periods logged."}
    periods.sort()
    starts = [p[0] for p in periods]
    gaps = [(starts[i] - starts[i - 1]).days for i in range(1, len(starts))]
    gaps = [g for g in gaps if 15 <= g <= 60][-6:]
    avg = round(sum(gaps) / len(gaps)) if gaps else None
    last = starts[-1]
    since = (today - last).days
    return {
        "logged_periods": len(periods),
        "last_start": last.isoformat(),
        "days_since_last_start": since,
        "on_period_now": periods[-1][1] is None and 0 <= since < 10,
        "average_cycle_days": avg,
        "note": "Estimates from the user's own logs only.",
    }


def bmi_of(height_cm, weight_kg):
    try:
        h, w = float(height_cm), float(weight_kg)
        return round(w / ((h / 100) ** 2), 1) if h > 0 else None
    except (TypeError, ValueError):
        return None


def age_range_of(birth_date: str | None, today: date | None = None) -> str | None:
    if not birth_date:
        return None
    try:
        b = date.fromisoformat(birth_date)
    except ValueError:
        return None
    t = today or local_today()
    years = t.year - b.year - ((t.month, t.day) < (b.month, b.day))
    lo = (years // 10) * 10
    return f"{lo}-{lo + 9}"


# ------------------------------------------------------------------ tools (take db + args)
async def get_profile(db, args: dict) -> dict:
    rows = await db.select(
        "profiles", "birth_date,sex,blood_type,height_cm,weight_kg,conditions,goals",
        filters={"id": f"eq.{db.user_id}"}, limit=1,
    )
    if not rows:
        return {"note": "Health profile not filled in yet."}
    r = rows[0]
    return {
        "age_range": age_range_of(r.get("birth_date")),
        "sex": r.get("sex"),
        "blood_type": r.get("blood_type"),
        "height_cm": r.get("height_cm"),
        "weight_kg": r.get("weight_kg"),
        "bmi": bmi_of(r.get("height_cm"), r.get("weight_kg")),
        "conditions": r.get("conditions") or [],
        "goals": r.get("goals") or [],
    }


async def get_allergies(db, args: dict) -> dict:
    rows = await db.select("allergies", "name", filters={"status": "eq.confirmed"}, order="name.asc")
    return {"allergies": [r["name"] for r in rows if r.get("name")]}


def _active_meds(rows: list[dict], today: date) -> list[dict]:
    out = []
    for m in rows:
        try:
            start = date.fromisoformat(m["start_date"]) if m.get("start_date") else None
            end = date.fromisoformat(m["end_date"]) if m.get("end_date") else None
        except ValueError:
            start = end = None
        if start and start > today:
            continue
        if end and end < today:
            continue
        out.append({
            "name": m.get("name"),
            "dosage": m.get("dosage"),
            "times": m.get("times") or [],
            "until": m.get("end_date"),
        })
    return out


async def get_medications(db, args: dict) -> dict:
    rows = await db.select(
        "medications", "name,dosage,times,start_date,end_date", filters={"status": "eq.confirmed"},
    )
    return {"medications": _active_meds(rows, local_today())}


async def get_recent_logs(db, args: dict) -> dict:
    kind = args["kind"]
    days = args["days"]
    table, cols, ts = KINDS[kind]
    rows = await db.select(
        table, cols, filters={ts: f"gte.{since_utc(days)}"}, order=f"{ts}.desc", limit=500,
    )
    return summarize_logs(kind, rows, days)


async def get_heart_rate(db, args: dict) -> dict:
    days = args["days"]
    rows = await db.select(
        "wearable_samples", "value,recorded_at,context",
        filters={"metric": "eq.heart_rate", "recorded_at": f"gte.{since_utc(days)}"},
        order="recorded_at.desc", limit=1000,
    )
    return summarize_heart(rows)


async def get_cycle(db, args: dict) -> dict:
    rows = await db.select("period_logs", "start_date,end_date", order="start_date.desc", limit=8)
    return summarize_cycle(rows)


async def get_lab_results(db, args: dict) -> dict:
    rows = await db.select(
        "lab_results", "test_name,value,value_text,unit,ref_low,ref_high,flag,reported_on",
        order="reported_on.desc.nullslast,created_at.desc", limit=40,
    )
    if not rows:
        return {"count": 0, "note": "No lab results saved yet."}
    items = []
    for r in rows:
        items.append({
            "test": r.get("test_name"),
            "result": r.get("value") if r.get("value") is not None else r.get("value_text"),
            "unit": r.get("unit"),
            "reference": [r.get("ref_low"), r.get("ref_high")],
            "flag": r.get("flag"),
            "date": r.get("reported_on"),
        })
    return {"count": len(items), "results": items,
            "note": "Copied from the user's own reports. Do not diagnose from these."}


async def get_safety_warnings(db) -> list[dict]:
    """Runs the rule engine on the user's current medicines, allergies and conditions."""
    meds = (await get_medications(db, {}))["medications"]
    if not meds:
        return []
    allergies = (await get_allergies(db, {}))["allergies"]
    conditions = (await get_profile(db, {})).get("conditions") or []
    return [w.as_dict() for w in rules.check_all(meds, allergies, conditions)]


async def check_medication_safety(db, args: dict) -> dict:
    warnings = await get_safety_warnings(db)
    return {"warnings": [{"severity": w["severity"], "message": w["message"]} for w in warnings],
            "note": "Fixed safety rules, not a full drug database." }


# ------------------------------------------------------------------ registry
@dataclass
class ToolSpec:
    description: str
    args: str  # human text for the prompt
    fn: Callable[[object, dict], Awaitable[dict]]
    source: str  # label shown to the user


TOOLS: dict[str, ToolSpec] = {
    "get_profile": ToolSpec(
        "Age range, sex, blood type, height, weight, BMI, listed medical conditions, goals.",
        "no args", get_profile, "profile"),
    "get_allergies": ToolSpec("The user's listed allergies.", "no args", get_allergies, "allergies"),
    "get_medications": ToolSpec(
        "Medicines the user currently takes: name, dosage, daily times, end date.",
        "no args", get_medications, "medications"),
    "get_recent_logs": ToolSpec(
        "Daily totals and averages from the user's logs.",
        'args: {"kind": "water"|"sleep"|"mood"|"meals"|"symptoms", "days": 1-30 (default 7)}',
        get_recent_logs, "logs"),
    "get_heart_rate": ToolSpec(
        "Heart rate summary (latest, average, min, max, resting average).",
        'args: {"days": 1-30 (default 7)}', get_heart_rate, "heart rate"),
    "get_lab_results": ToolSpec(
        "Lab test results the user saved from scanned reports: value, unit, reference range, low/normal/high flag, date.",
        "no args", get_lab_results, "lab results"),
    "get_cycle": ToolSpec(
        "Menstrual cycle summary from the user's own period logs.", "no args", get_cycle, "cycle"),
    "check_medication_safety": ToolSpec(
        "Runs the fixed safety rules (allergy conflicts, cautions, duplicates, paracetamol limit).",
        "no args", check_medication_safety, "medicine safety"),
}


def describe_tools() -> str:
    return "\n".join(f'- {name}: {t.description} {t.args}' for name, t in TOOLS.items())


def clean_args(name: str, raw) -> dict:
    """Validate and clamp the model's arguments. Raises ValueError with a helpful message."""
    raw = raw if isinstance(raw, dict) else {}
    if name == "get_recent_logs":
        kind = str(raw.get("kind", "")).lower()
        if kind not in KINDS:
            raise ValueError("kind must be one of: " + ", ".join(KINDS))
        return {"kind": kind, "days": _days(raw.get("days"))}
    if name == "get_heart_rate":
        return {"days": _days(raw.get("days"))}
    return {}


def _days(v) -> int:
    try:
        return max(1, min(30, int(v)))
    except (TypeError, ValueError):
        return 7


async def run_tool(name: str, raw_args, db) -> dict:
    if name not in TOOLS:
        raise ValueError("Unknown tool. Available: " + ", ".join(TOOLS))
    return await TOOLS[name].fn(db, clean_args(name, raw_args))


def source_label(name: str, args: dict) -> str:
    if name == "get_recent_logs":
        return args.get("kind", "logs")
    return TOOLS[name].source if name in TOOLS else name
