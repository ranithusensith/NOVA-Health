"""
Daily health report computed and written entirely within NOVA.
"""

from datetime import date, timedelta

import daily_metrics as metrics
import safety
import tools
from db import DBError

async def _day_rows(db, table: str, cols: str, ts: str, bounds, extra: dict | None = None):
    start, end = bounds
    filters = {"and": f"({ts}.gte.{start.isoformat()},{ts}.lt.{end.isoformat()})"}
    filters.update(extra or {})
    try:
        rows = await db.select(table, cols, filters=filters, order=f"{ts}.asc", limit=500)
    except DBError:
        return None
    return rows if len(rows) < 500 else None


async def _day_doses(db, day: date, bounds) -> tuple[int, int]:
    start, end = (instant.isoformat() for instant in bounds)
    wall_start = f"{day}T00:00:00"
    wall_end = f"{day + timedelta(days=1)}T00:00:00"
    filters = {
        "status": "eq.taken",
        "or": (
            f"(and(scheduled_local_at.gte.{wall_start},scheduled_local_at.lt.{wall_end}),"
            f"and(scheduled_local_at.is.null,scheduled_at.gte.{start},scheduled_at.lt.{end}),"
            f"and(scheduled_at.is.null,taken_at.gte.{start},taken_at.lt.{end}))"
        ),
    }
    taken = unassigned = 0
    page_size = 250
    while True:
        rows = await db.select("medication_logs", "id,status,occurrence_key",
                               filters=filters, order="id.asc", limit=page_size)
        for row in rows:
            if row.get("status") == "taken":
                if row.get("occurrence_key") is None:
                    unassigned += 1
                else:
                    taken += 1
        if len(rows) < page_size:
            return taken, unassigned
        filters["id"] = f"gt.{rows[-1]['id']}"


async def build_daily_data(db, day: date, *, bounds=None) -> dict:
    bounds = bounds or tuple(map(tools.parse_ts, tools.day_bounds_utc(day)))
    urgent = await tools.recent_saved_emergency(db) if bounds[0] <= tools.utc_now() < bounds[1] else None
    water = await _day_rows(db, "water_logs", "amount_ml,logged_at", "logged_at", bounds)
    sleep = await _day_rows(db, "sleep_logs", "hours,logged_at", "logged_at", bounds)
    mood_rows = await _day_rows(db, "mood_logs", "mood,logged_at", "logged_at", bounds)
    meals = await _day_rows(db, "meal_logs", "calories,logged_at", "logged_at", bounds,
                            {"status": "eq.confirmed"})
    heart = await _day_rows(db, "wearable_samples", "value,recorded_at,context", "recorded_at", bounds,
                            {"metric": "eq.heart_rate"})
    try:
        profiles = await db.select("profiles", "water_goal_ml,sleep_goal_hours", limit=1)
        goals = profiles[0] if profiles else {}
    except DBError:
        goals = {}
    taken, unassigned = await _day_doses(db, day, bounds)
    meds = (await tools.get_medications(db, {}, day=day, history=True))["medications"]
    labs = await tools.get_lab_results(db, {}, day=day)

    try:
        warnings = await tools.get_safety_warnings(db, meds=[m for m in meds if m["status"] == "confirmed"])
    except DBError:
        warnings = [safety.SAFETY_UNAVAILABLE]

    scheduled = sum(tools.scheduled_doses_on(m, day, bounds=bounds) for m in meds)
    try:
        sleep_hours = metrics.sleep_hours(sleep)
    except (TypeError, ValueError, KeyError):
        sleep_hours = None
    try:
        mood = metrics.mood(mood_rows)
    except (TypeError, ValueError, KeyError):
        mood = None
    heart_summary = tools.verified_heart_summary(heart or [])
    return {
        "date": day.isoformat(),
        "water_ml": metrics.total(water, "amount_ml"),
        "water_goal_ml": metrics.number(goals.get("water_goal_ml"), minimum=1, maximum=20000, integer=True),
        "sleep_hours": sleep_hours,
        "sleep_goal_hours": metrics.number(goals.get("sleep_goal_hours"), minimum=0.1, maximum=24),
        "mood": mood,
        "meals": len(meals) if meals is not None else None,
        "calories": metrics.total(meals, "calories"),
        "heart": heart_summary,
        "doses_scheduled": scheduled,
        "doses_taken": taken,
        "unassigned_dose_logs": unassigned,
        "lab_results": labs.get("results", []),
        "warnings": warnings,
        "emergency": urgent,
    }


def highlights(d: dict) -> list[str]:
    out: list[str] = []
    water = "unknown" if d["water_ml"] is None else f"{d['water_ml'] / 1000:g} L logged"
    if d["water_goal_ml"] is not None:
        water += f" · saved target {d['water_goal_ml'] / 1000:g} L"
    out.append(f"Water: {water}")
    sleep = "unknown" if d["sleep_hours"] is None else f"{d['sleep_hours']:g} hours logged"
    if d["sleep_goal_hours"] is not None:
        sleep += f" · saved goal {d['sleep_goal_hours']:g} hours"
    out.append(f"Sleep: {sleep}")
    if d["mood"]:
        out.append(f"Mood: {d['mood']}")
    if d["meals"]:
        calories = "calorie total unknown" if d["calories"] is None else f"about {d['calories']} kcal"
        out.append(f"Meals: {d['meals']} logged, {calories}")
    else:
        out.append("Meals: unavailable" if d["meals"] is None else "Meals: none logged")
    h = d["heart"]
    if h.get("count"):
        out.append(f"Heart rate: average {h['average_bpm']} bpm (range {h['min_bpm']} to {h['max_bpm']})")
    else:
        out.append("Heart rate: unknown")
    if d["doses_scheduled"]:
        out.append(f"Medicines: {d['doses_taken']} of {d['doses_scheduled']} doses marked taken")
    if d["unassigned_dose_logs"]:
        out.append(f"Medicines: {d['unassigned_dose_logs']} dose log(s) without a scheduled time")
    for lab in d["lab_results"]:
        if lab["result"] is None:
            continue
        observation = f"{lab['result']} {lab['unit'] or ''}".rstrip()
        if isinstance(lab["reference"], str):
            observation += f" · reference {lab['reference']}"
        if lab["flag"] not in (None, "unknown"):
            observation += f" · recorded flag {lab['flag']}"
        out.append(f"Lab result: {lab['test']} {observation}")
    return [safety.guard_output(item, limit=None) for item in out]


def tips(d: dict) -> list[str]:
    out: list[str] = []
    if d["water_ml"] is not None or d["water_goal_ml"] is not None:
        out.append("Follow any fluid instructions from your care team.")
    if not d["unassigned_dose_logs"] and d["doses_scheduled"] and d["doses_taken"] < d["doses_scheduled"]:
        out.append("Check your medicines in the app and mark the ones you took.")
    if d["mood"] in ("low", "bad"):
        out.append("If you feel low for several days, talk to someone you trust or a doctor.")
    return [safety.guard_output(item, limit=None) for item in out[:3]]


def fallback_text(d: dict, items: list[str]) -> str:
    t = tips(d)
    text = "Here is your day at a glance:\n" + "\n".join(f"- {h}" for h in items)
    if t:
        text += "\n\nSuggestions:\n" + "\n".join(f"- {x}" for x in t)
    return text


async def daily_report(db, day: date, *, bounds=None) -> dict:
    data = await build_daily_data(db, day, bounds=bounds)
    items = highlights(data)
    text = fallback_text(data, items)
    if data["emergency"]:
        kind, symptom = data["emergency"]
        text = safety.saved_emergency_reply(kind, text=symptom) + "\n\n" + text
    return {
        "date": day.isoformat(),
        "calendar_basis": "device" if bounds is not None else "configured",
        "report": safety.finalize(text, data["warnings"]),
        "highlights": items,
        "ai": False,
    }
