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
from uuid import UUID

import daily_metrics
import lab_results
import rules
import safety
import symptoms
from db import InvalidDBResponse

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
    "symptoms": ("symptom_logs", f"{symptoms.SUMMARY_COLUMNS},notes", "started_at"),
}


def _avg(values: list[float], digits: int = 1):
    return round(sum(values) / len(values), digits) if values else None


def summarize_logs(kind: str, rows: list[dict], days: int, calendar=None) -> dict:
    out: dict = {"kind": kind, "days": days}
    day_for = calendar.day_for if calendar else local_day
    if kind == "symptoms":
        items = []
        for r in rows[:20]:
            item = symptoms.observation(r)
            try:
                started = daily_metrics.instant(r["started_at"]).isoformat()
                item["since"] = day_for(started).isoformat()
            except (KeyError, TypeError, ValueError):
                item["since"] = None
            items.append(item)
        out["symptoms"] = items
        out["count"] = len(items)
        return out

    by_day: dict[str, list] = defaultdict(list)
    ts_key = "logged_at"
    for r in rows:
        if r.get(ts_key):
            by_day[day_for(r[ts_key]).isoformat()].append(r)

    if kind == "water":
        per_day = {d: daily_metrics.total(v, "amount_ml") for d, v in by_day.items()}
        out["ml_per_day"] = dict(sorted(per_day.items()))
        known = [value for value in per_day.values() if value is not None]
        out["average_ml_on_logged_days"] = round(sum(known) / len(known)) if known else None
    elif kind == "sleep":
        per_day = {d: daily_metrics.sleep_hours(v) for d, v in by_day.items()}
        out["hours_per_day"] = dict(sorted(per_day.items()))
        out["average_hours_on_logged_days"] = _avg([v for v in per_day.values() if v is not None])
    elif kind == "mood":
        per_day = {d: [daily_metrics.mood(v)] for d, v in by_day.items()}
        out["moods_per_day"] = dict(sorted(per_day.items()))
        out["low_or_bad_days"] = sum(1 for v in per_day.values() if any(m in ("low", "bad") for m in v))
    elif kind == "meals":
        per_day = {
            d: {"kcal": daily_metrics.total(v, "calories"), "meals": len(v)} for d, v in by_day.items()
        }
        out["per_day"] = dict(sorted(per_day.items()))
        kc = [v["kcal"] for v in per_day.values() if v["kcal"] is not None]
        out["average_kcal_on_logged_days"] = round(sum(kc) / len(kc)) if kc else None
    out["days_with_data"] = len(by_day)
    return out


def summarize_heart(rows: list[dict]) -> dict:
    try:
        vals = [(parse_ts(r["recorded_at"]), round(float(r["value"])), r.get("context")) for r in rows
                if r.get("recorded_at") and r.get("value") is not None]
    except (ValueError, TypeError, AttributeError, OverflowError):
        raise InvalidDBResponse() from None
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


def _active_meds(rows: list[dict], today: date, *, history: bool = False) -> list[dict]:
    out = []
    for m in rows:
        try:
            start = date.fromisoformat(m["start_date"]) if m.get("start_date") else None
            end = date.fromisoformat(m["end_date"]) if m.get("end_date") else None
        except TypeError:
            raise InvalidDBResponse() from None
        except ValueError:
            start = end = None
        if start and start > today:
            continue
        if end and end < today:
            continue
        times = m.get("times")
        if times is not None and not isinstance(times, list):
            raise InvalidDBResponse()
        med = {
            "name": m.get("name"),
            "dosage": m.get("dosage"),
            "times": times or [],
            "until": m.get("end_date"),
        }
        if history:
            med["status"] = m.get("status", "confirmed")
        if isinstance(plan := m.get("prescription_plan"), dict):
            med["prescription_plan"] = plan
        out.append(med)
    return out


async def get_medications(db, args: dict, *, day: date | None = None, excluding: UUID | None = None,
                          history: bool = False) -> dict:
    filters = {"status": "in.(confirmed,ended)" if history else "eq.confirmed"}
    if excluding is not None:
        filters["id"] = f"neq.{excluding}"
    cols = "name,dosage,times,start_date,end_date,prescription_plan"
    rows = await db.select("medications", cols + (",status" if history else ""), filters=filters)
    return {"medications": _active_meds(rows, day or local_today(), history=history)}


def scheduled_doses_on(med: dict, day: date, *, bounds=None) -> int:
    plan = med.get("prescription_plan")
    if not plan or plan.get("kind") == "daily":
        return len(med["times"])
    if plan.get("kind") not in (None, "interval"):
        return 0
    minutes = plan.get("interval_minutes")
    if type(minutes) is not int or not 1 <= minutes <= 525600:
        return 0
    try:
        anchor = plan["first_dose_at"]
        if datetime.fromisoformat(anchor).utcoffset() is None:
            return 0
        first = parse_ts(anchor)
    except (KeyError, ValueError, TypeError, AttributeError):
        return 0
    start, end = bounds or tuple(map(parse_ts, day_bounds_utc(day)))
    interval = timedelta(minutes=minutes)
    before_start = max(timedelta(), start - first)
    before_end = max(timedelta(), end - first)
    following_start = -(-before_start // interval)
    following_end = -(-before_end // interval)
    return following_end - following_start


async def get_recent_logs(db, args: dict, *, calendar=None) -> dict:
    kind = args["kind"]
    days = args["days"]
    table, cols, ts = KINDS[kind]
    latest = utc_now()
    start = calendar.boundaries[-days - 1].isoformat() if calendar else since_utc(days)
    end = min(latest, calendar.boundaries[-1]) if calendar else latest
    filters = {ts: f"gte.{start}", "and": f"({ts}.lt.{end.isoformat()})"}
    if kind == "meals":
        filters["status"] = "eq.confirmed"
    rows = await db.select(table, cols, filters=filters, order=f"{ts}.desc", limit=500)
    if kind != "symptoms" and len(rows) >= 500:
        return {"kind": kind, "incomplete": True}
    try:
        if kind != "symptoms" and any(not row.get(ts) for row in rows):
            return {"kind": kind, "incomplete": True}
        result = summarize_logs(kind, rows, days, calendar)
    except daily_metrics.ConflictingMeasurements:
        return {"kind": kind, "conflicting": True}
    except (TypeError, ValueError, KeyError):
        return {"kind": kind, "incomplete": True}
    values = {
        "water": lambda: result["ml_per_day"].values(),
        "sleep": lambda: result["hours_per_day"].values(),
        "meals": lambda: (row["kcal"] for row in result["per_day"].values()),
    }
    if kind in values and any(value is None for value in values[kind]()):
        # Partial windows cannot support a reliable whole-window claim.
        return {"kind": kind, "incomplete": True}
    if kind == "symptoms" and (alert := symptoms.recent_emergency(rows, utc_now())):
        result["urgent"] = alert
    return result


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


async def recent_saved_emergency(db) -> tuple[str, str] | None:
    """Check recent active symptoms using the caller's database session."""
    now = utc_now()
    cutoff = (now - timedelta(hours=24)).isoformat()
    rows = await db.select(
        "symptom_logs", symptoms.SAFETY_COLUMNS,
        filters={"status": "eq.active", "and": f"(started_at.gte.{cutoff},started_at.lte.{now.isoformat()})"},
        order="started_at.desc", limit=100,
    )
    return symptoms.recent_emergency(rows, now)


async def get_heart_rate(db, args: dict, *, calendar=None) -> dict:
    days = args["days"]
    now = utc_now()
    start = calendar.boundaries[-days - 1].isoformat() if calendar else since_utc(days)
    end = min(now, calendar.boundaries[-1]) if calendar else now
    rows = await db.select(
        "wearable_samples", "value,recorded_at,context",
        filters={"metric": "eq.heart_rate", "recorded_at": f"gte.{start}",
                 "and": f"(recorded_at.lt.{end.isoformat()})"},
        order="recorded_at.desc", limit=1000,
    )
    return {"incomplete": True} if len(rows) >= 1000 else verified_heart_summary(rows)


def verified_heart_summary(rows: list[dict]) -> dict:
    by_instant = defaultdict(set)
    try:
        for row in rows:
            value = daily_metrics.number(row.get("value"), minimum=20, maximum=250)
            if value is None:
                return {"incomplete": True}
            by_instant[daily_metrics.instant(row["recorded_at"])].add(value)
    except (TypeError, ValueError, KeyError):
        return {"incomplete": True}
    if any(len(values) > 1 for values in by_instant.values()):
        return {"conflicting": True}
    summary = summarize_heart(rows)
    if by_instant:
        summary["latest_saved_bpm"] = next(iter(by_instant[max(by_instant)]))
    return summary


async def get_cycle(db, args: dict) -> dict:
    rows = await db.select("period_logs", "start_date,end_date", order="start_date.desc", limit=8)
    return summarize_cycle(rows)


async def get_lab_results(db, args: dict, *, day: date | None = None) -> dict:
    rows = await db.select(
        "lab_results", lab_results.RESULT_COLUMNS,
        filters={"reported_on": f"eq.{day.isoformat()}"} if day is not None else None,
        order="reported_on.desc.nullslast,created_at.desc", limit=40 if day is None else 200,
    )
    if not rows:
        return {"count": 0, "note": "No lab results saved yet."}
    items = [lab_results.saved_observation(row) for row in rows]
    return {"count": len(items), "results": items,
            "note": "Copied from the user's own reports. Do not diagnose from these."}


async def get_safety_warnings(db, *, meds: list[dict] | None = None) -> list[dict]:
    """Runs the rule engine on the user's current medicines, allergies and conditions."""
    if meds is None:
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
        "Age range, sex, blood type, height, weight, BMI and listed medical conditions.",
        "no args", get_profile, "profile"),
    "get_allergies": ToolSpec("The user's listed allergies.", "no args", get_allergies, "allergies"),
    "get_medications": ToolSpec(
        "Names and dosages of medicines the user currently takes.",
        "no args", get_medications, "medications"),
    "get_recent_logs": ToolSpec(
        "Daily totals and averages from the user's logs.",
        'args: {"kind": "water"|"sleep"|"mood"|"meals"|"symptoms", "days": 1-30 (default 7)}',
        get_recent_logs, "logs"),
    "get_heart_rate": ToolSpec(
        "Heart rate summary (latest, average, min, max, resting average).",
        'args: {"days": 1-30 (default 7)}', get_heart_rate, "heart rate"),
    "get_lab_results": ToolSpec(
        "Saved lab observations. Quote result text and comparison operators exactly. A threshold is not an exact "
        "measurement. Report a flag only as recorded; never infer normality or diagnose from these observations.",
        "no args", get_lab_results, "lab results"),
    "get_cycle": ToolSpec(
        "Menstrual cycle summary from the user's own period logs.", "no args", get_cycle, "cycle"),
    "check_medication_safety": ToolSpec(
        "Runs the fixed safety rules (allergy conflicts, cautions, duplicates, paracetamol limit).",
        "no args", check_medication_safety, "medicine safety"),
}


def describe_tools(allowed: frozenset[str] | None = None) -> str:
    return "\n".join(
        f"- {name}: {spec.description} {spec.args}"
        for name, spec in TOOLS.items() if allowed is None or name in allowed
    )


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


async def run_tool(name: str, raw_args, db, *, calendar=None) -> dict:
    if name not in TOOLS:
        raise ValueError("Unknown tool. Available: " + ", ".join(TOOLS))
    args = clean_args(name, raw_args)
    if name == "get_recent_logs":
        return await get_recent_logs(db, args, calendar=calendar)
    if name == "get_heart_rate":
        return await get_heart_rate(db, args, calendar=calendar)
    return await TOOLS[name].fn(db, args)


def source_label(name: str, args: dict) -> str:
    if name == "get_recent_logs":
        return args.get("kind", "logs")
    return TOOLS[name].source if name in TOOLS else name
