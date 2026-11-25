"""On-demand comparisons of saved observations on matched, completed local dates."""

import asyncio
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime
from typing import Literal

import daily_metrics
import nutrition
import wearable_daily
from db import DBError

Comparison = Literal["sleep_steps", "medication_symptoms", "meals_water"]
Source = Literal["sleep", "steps", "scheduled_doses", "symptoms", "meals", "water"]

PAIRS: dict[Comparison, tuple[Source, Source]] = {
    "sleep_steps": ("sleep", "steps"),
    "medication_symptoms": ("scheduled_doses", "symptoms"),
    "meals_water": ("meals", "water"),
}
LABELS = {
    "sleep": "Sleep logs", "steps": "Imported steps", "scheduled_doses": "Scheduled dose logs",
    "symptoms": "Symptom logs", "meals": "Confirmed meal logs", "water": "Water logs",
}

_TABLES = {
    "sleep": ("sleep_logs", "logged_at", "hours", {}),
    "scheduled_doses": ("medication_logs", "taken_at", "medication_id,occurrence_key",
                        {"status": "eq.taken", "occurrence_key": "not.is.null"}),
    "symptoms": ("symptom_logs", "started_at", "", {}),
    "meals": ("meal_logs", "logged_at", "calories", {"status": "eq.confirmed"}),
    "water": ("water_logs", "logged_at", "amount_ml", {}),
}
_LIMIT = 500
_INTERPRETATION = (
    "These are saved observations on local calendar dates. Shared dates cannot establish a link, "
    "a cause, or a diagnosis. Missing entries do not establish what happened."
)


@dataclass(frozen=True)
class Reading:
    value: str | None = None
    issue: str | None = None

    @property
    def display(self) -> str:
        return self.value or self.issue or "unknown (no usable entry)"


def _daily(source: Source, rows: list[dict]) -> Reading:
    if source == "sleep":
        try:
            hours = daily_metrics.sleep_hours(rows)
        except daily_metrics.ConflictingMeasurements:
            return Reading(issue="unknown (latest entries disagree)")
        return (Reading(f"{hours:g} hours in the latest entry") if hours is not None
                else Reading(issue="unknown (latest duration incomplete)"))
    if source == "water":
        total = daily_metrics.total(rows, "amount_ml")
        return (Reading(f"{total} mL logged") if total is not None
                else Reading(issue="unknown (logged amounts incomplete)"))
    if source == "meals":
        calories = nutrition.total(rows, "calories")
        estimate = "calorie total unknown" if calories is None else f"{calories} kcal estimated"
        count = len(rows)
        return Reading(f"{count} confirmed {'entry' if count == 1 else 'entries'}, {estimate}")
    if source == "scheduled_doses":
        keys = [(row.get("medication_id"), row.get("occurrence_key")) for row in rows]
        if not all(isinstance(med, str) and med and isinstance(key, str) and key for med, key in keys):
            return Reading(issue="unknown (dose occurrences incomplete)")
        count = len(set(keys))
        return Reading(f"{count} scheduled {'dose' if count == 1 else 'doses'} marked taken")
    count = len(rows)
    return Reading(f"{count} {'entry' if count == 1 else 'entries'} with onset on this date")


async def _steps(db, windows: dict[date, wearable_daily.Window], now: datetime) -> dict[date, Reading]:
    rows = await wearable_daily.rows_for_windows(db, windows, metric="steps")
    if len(rows) >= wearable_daily.ROW_LIMIT:
        return dict.fromkeys(windows, Reading(issue="unknown (too many entries to verify)"))
    observations: dict[date, set[tuple[str, int]]] = defaultdict(set)
    partial: set[date] = set()
    invalid: set[date] = set()
    for row in rows:
        if row.get("metric") != "steps":
            continue
        try:
            day = date.fromisoformat(row["local_date"])
        except (TypeError, ValueError, KeyError):
            return dict.fromkeys(windows, Reading(issue="unknown (unverified calendar date)"))
        if day not in windows:
            continue
        try:
            entry = wearable_daily.observation(row, windows)
        except (TypeError, ValueError, KeyError):
            invalid.add(day)
            continue
        if entry is None:
            continue
        _, _, provider, count, captured_at = entry
        if captured_at < windows[day][1]:
            partial.add(day)
        elif captured_at > now:
            invalid.add(day)
        else:
            observations[day].add((provider, count))
    results = {}
    for day in observations.keys() | partial | invalid:
        entries = observations.get(day, set())
        if len(entries) > 1:
            results[day] = Reading(issue="unknown (imports disagree)")
        elif day in invalid:
            results[day] = Reading(issue="unknown (unverified import)")
        elif day in partial:
            results[day] = Reading(issue="unknown (import was captured before the day ended)")
        else:
            provider, count = next(iter(entries))
            results[day] = Reading(f"{count} steps from {provider}")
    return results


async def _read(db, source: Source, windows: dict[date, wearable_daily.Window],
                calendar: daily_metrics.LocalCalendar, now: datetime) -> dict[date, Reading]:
    try:
        if source == "steps":
            return await _steps(db, windows, now)
        table, stamp, fields, filters = _TABLES[source]
        start, end = windows[min(windows)][0], windows[max(windows)][1]
        rows = await db.select(
            table, f"{stamp},{fields}" if fields else stamp,
            filters={**filters, stamp: f"gte.{start.isoformat()}", "and": f"({stamp}.lt.{end.isoformat()})"},
            order=f"{stamp}.asc", limit=_LIMIT,
        )
    except DBError:
        return dict.fromkeys(windows, Reading(issue="unknown (records unavailable)"))
    if len(rows) >= _LIMIT:
        return dict.fromkeys(windows, Reading(issue="unknown (too many entries to verify)"))
    by_day: dict[date, list[dict]] = defaultdict(list)
    try:
        for row in rows:
            at = daily_metrics.instant(row[stamp])
            if start <= at < end:
                by_day[calendar.day_for(row[stamp])].append(row)
    except (TypeError, ValueError, KeyError):
        return dict.fromkeys(windows, Reading(issue="unknown (unverified record time)"))
    return {day: _daily(source, group) for day, group in by_day.items()}


async def compare(db, pair: Comparison, calendar: daily_metrics.LocalCalendar, now: datetime) -> tuple[str, list[str]]:
    windows = {
        day: (start, end) for day, start, end in zip(
            calendar.days[-9:-2], calendar.boundaries[-9:-2], calendar.boundaries[-8:-1], strict=True,
        )
    }
    first, second = PAIRS[pair]
    left, right = await asyncio.gather(
        _read(db, first, windows, calendar, now), _read(db, second, windows, calendar, now),
    )
    title = f"{LABELS[first]} and {LABELS[second].lower()}"
    lines = [title, f"Completed local dates: {min(windows)} through {max(windows)}."]
    paired = sum(bool(left.get(day, Reading()).value and right.get(day, Reading()).value) for day in windows)
    if paired:
        lines.append(f"Both sources have verified observations on {paired} of {len(windows)} dates.")
    else:
        lines.append("No completed date has verified observations from both sources.")

    for day in windows:
        if day in left or day in right:
            lines.append(f"{day} · {LABELS[first]}: {left.get(day, Reading()).display} · "
                         f"{LABELS[second]}: {right.get(day, Reading()).display}")
    if pair == "medication_symptoms":
        lines.append("Dose counts reflect saved confirmations on those dates. They do not measure adherence or missed doses.")
    lines.append(_INTERPRETATION)
    sources = [source for source, values in ((first, left), (second, right))
               if any(reading.value is not None for reading in values.values())]
    return "\n\n".join(lines), sources
