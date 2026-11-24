"""
Daily health report computed and written entirely within NOVA.
"""

from datetime import date, timedelta

import safety
import tools
from db import DBError

WATER_GOAL_ML = 2500
SLEEP_GOAL_H = 7.0


async def _day_rows(db, table: str, cols: str, ts: str, day: date, extra: dict | None = None) -> list[dict]:
    start, end = tools.day_bounds_utc(day)
    filters = {"and": f"({ts}.gte.{start},{ts}.lt.{end})"}
    filters.update(extra or {})
    return await db.select(table, cols, filters=filters, order=f"{ts}.asc", limit=500)


async def _day_doses(db, day: date) -> tuple[int, int]:
    start, end = tools.day_bounds_utc(day)
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


async def build_daily_data(db, day: date) -> dict:
    symptoms = []
    if day == tools.local_today():
        symptoms = await _day_rows(db, "symptom_logs", "name,status,started_at", "started_at", day,
                                   {"status": "eq.active"})
    water = await _day_rows(db, "water_logs", "amount_ml,logged_at", "logged_at", day)
    sleep = await _day_rows(db, "sleep_logs", "hours,logged_at", "logged_at", day)
    mood = await _day_rows(db, "mood_logs", "mood,logged_at", "logged_at", day)
    meals = await _day_rows(db, "meal_logs", "calories,logged_at", "logged_at", day)
    heart = await _day_rows(db, "wearable_samples", "value,recorded_at,context", "recorded_at", day,
                            {"metric": "eq.heart_rate"})
    taken, unassigned = await _day_doses(db, day)
    meds = (await tools.get_medications(db, {}, day=day))["medications"]
    labs = await tools.get_lab_results(db, {}, day=day)

    try:
        warnings = await tools.get_safety_warnings(db, meds=meds)
    except DBError:
        warnings = [safety.SAFETY_UNAVAILABLE]

    scheduled = sum(tools.scheduled_doses_on(m, day) for m in meds)
    return {
        "date": day.isoformat(),
        "water_ml": sum(int(r.get("amount_ml") or 0) for r in water),
        "water_goal_ml": WATER_GOAL_ML,
        "sleep_hours": round(sum(float(r.get("hours") or 0) for r in sleep), 1) if sleep else None,
        "sleep_goal_hours": SLEEP_GOAL_H,
        "moods": [r.get("mood") for r in mood],
        "meals": len(meals),
        "calories": sum(int(r.get("calories") or 0) for r in meals),
        "heart": tools.summarize_heart(heart),
        "doses_scheduled": scheduled,
        "doses_taken": taken,
        "unassigned_dose_logs": unassigned,
        "lab_results": labs.get("results", []),
        "warnings": warnings,
        "emergency": safety.logged_emergency(symptoms),
    }


def highlights(d: dict) -> list[str]:
    out: list[str] = []
    water_pct = d["water_ml"] / d["water_goal_ml"] * 100 if d["water_goal_ml"] else 0
    out.append(f"Water: {d['water_ml'] / 1000:.1f} of {d['water_goal_ml'] / 1000:.1f} L ({water_pct:.0f}%)")
    out.append(
        "Sleep: not logged" if d["sleep_hours"] is None
        else f"Sleep: {d['sleep_hours']:g} of {d['sleep_goal_hours']:g} hours")
    if d["moods"]:
        out.append("Mood: " + ", ".join(m for m in d["moods"] if m))
    if d["meals"]:
        out.append(f"Meals: {d['meals']} logged, about {d['calories']} kcal")
    h = d["heart"]
    if h.get("count"):
        out.append(f"Heart rate: average {h['average_bpm']} bpm (range {h['min_bpm']} to {h['max_bpm']})")
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
    if d["water_ml"] < d["water_goal_ml"] * 0.6:
        out.append("Review your recorded water intake against your usual hydration plan.")
    if d["sleep_hours"] is not None and d["sleep_hours"] < 6:
        out.append("Try to go to bed a little earlier tonight.")
    if d["sleep_hours"] is None:
        out.append("Log last night's sleep so NOVA can spot patterns.")
    if not d["unassigned_dose_logs"] and d["doses_scheduled"] and d["doses_taken"] < d["doses_scheduled"]:
        out.append("Check your medicines in the app and mark the ones you took.")
    if any(m in ("low", "bad") for m in d["moods"]):
        out.append("If you feel low for several days, talk to someone you trust or a doctor.")
    return [safety.guard_output(item, limit=None) for item in out[:3]]


def fallback_text(d: dict, items: list[str]) -> str:
    t = tips(d)
    text = "Here is your day at a glance:\n" + "\n".join(f"- {h}" for h in items)
    if t:
        text += "\n\nSuggestions:\n" + "\n".join(f"- {x}" for x in t)
    return text


async def daily_report(db, day: date) -> dict:
    data = await build_daily_data(db, day)
    items = highlights(data)
    text = fallback_text(data, items)
    if data["emergency"]:
        kind, symptom = data["emergency"]
        text = safety.emergency_reply(kind, text=symptom) + "\n\n" + text
    return {
        "date": day.isoformat(),
        "report": safety.finalize(text, data["warnings"]),
        "highlights": items,
        "ai": False,
    }
