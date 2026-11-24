"""Render assistant facts from authenticated tool results, never model prose."""

import math
import re
from collections import defaultdict
from datetime import date


NO_EVIDENCE = (
    "I could not verify any personal health information for this question. "
    "Choose which records to share for this reply, or review your saved records in NOVA."
)
CLINICAL_LIMIT = (
    "Saved records alone cannot establish a diagnosis or rule out a health problem. "
    "Ask a doctor or pharmacist about symptoms or treatment."
)

_LABELS = {
    "water": "Water logs", "sleep": "Sleep logs", "meals": "Meal logs",
    "mood": "Mood logs", "symptoms": "Symptom logs", "heart rate": "Heart-rate records",
    "cycle": "Period logs", "lab results": "Lab results", "profile": "Health profile",
    "medications": "Medication records", "allergies": "Allergy records",
}


def _number(value):
    if type(value) is int or (type(value) is float and math.isfinite(value)):
        return value
    return None


def _measured(result, field, label, unit):
    value = _number(result.get(field))
    return f"{label}: {value} {unit}." if value is not None and value >= 0 else None


def _labs(result):
    observations = defaultdict(dict)
    records = result.get("results", [])
    for record in records:
        # Treat display fields as data. The unit and value must be single
        # measurement tokens. Never repeat free-form flags or interpretations.
        name, value, unit = (record.get(key) for key in ("test", "result", "unit"))
        if type(value) in (int, float) and _number(value) is not None:
            value = str(value)
        if not isinstance(name, str) or not re.fullmatch(r"[\w .()+/-]{1,80}", name):
            continue
        if not isinstance(value, str) or not re.fullmatch(
            r"(?:[<>]=?|[≤≥])? *[+-]?[0-9]+(?:\.[0-9]+)?", value
        ) or len(value) > 40:
            continue
        if unit is not None and (
            not isinstance(unit, str) or not re.fullmatch(r"[\w%µμ/^.*·-]{1,24}", unit)
        ):
            continue
        raw_date = record.get("date")
        try:
            reported_on = date.fromisoformat(raw_date).isoformat() if raw_date else None
        except (ValueError, TypeError):
            reported_on = None
        key = (" ".join(name.split()).casefold(), reported_on)
        observations[key].setdefault((value, unit), name)

    lines = []
    conflict = any(len(values) != 1 for values in observations.values())
    if conflict:
        return "Some saved lab results disagree. Check the original reports in Medical records.", False
    for (_, day), values in list(observations.items())[:3]:
        (value, unit), name = next(iter(values.items()))
        measurement = f"{value} {unit}" if unit else value
        lines.append(f'“{name}” ({day or "report date unknown"}): {measurement}.')
    if not lines:
        return None, False
    # Point to the full reviewed record for printed ranges, flags, and the rest of the rows.
    return "Saved lab results:\n" + "\n".join(lines) + "\nSee Medical records for the full results.", True


def summarize(source, args, result):
    """Return display text and whether it contains a record-backed fact."""
    label = _LABELS.get(source)
    if not label:
        return None, False
    if result is None:
        return f"{label}: NOVA could not read these records right now.", False
    if result.get("conflicting"):
        return f"{label}: some saved entries disagree. Check your records before relying on a summary.", False
    if result.get("incomplete"):
        return f"{label}: the available entries are incomplete or could not be verified.", False

    if source == "lab results":
        text, verified = _labs(result)
        if text:
            return text, verified

    fields = {
        "sleep": ("average_hours_on_logged_days", "hours"),
        "water": ("average_ml_on_logged_days", "mL"),
        "meals": ("average_kcal_on_logged_days", "kcal"),
    }
    if source in fields:
        field, unit = fields[source]
        window = args["days"]
        period = "today" if window == 1 else f"last {window} calendar days, including today"
        text = _measured(result, field, f"{label} ({period}), average per logged day", unit)
        if text:
            return text, True
    if source == "heart rate":
        window = args["days"]
        period = "today" if window == 1 else f"last {window} calendar days, including today"
        text = _measured(result, "latest_saved_bpm", f"Most recent saved heart rate ({period})", "bpm")
        if text:
            return text, True
    if source == "cycle":
        text = _measured(result, "average_cycle_days", "Average interval from recent period logs", "days")
        if text:
            return text, True
    if source == "profile":
        fields = (("height_cm", "Saved height", "cm"), ("weight_kg", "Saved weight", "kg"))
        lines = [line for field, title, unit in fields if (line := _measured(result, field, title, unit))]
        if lines:
            return "\n".join(lines), True

    present = {
        "mood": "days_with_data", "symptoms": "count", "allergies": "allergies",
        "medications": "medications", "cycle": "logged_periods",
    }
    if source in present and result.get(present[source]):
        return f"{label}: saved entries are available in NOVA.", True
    return f"{label}: no usable entries were found for this reply.", False
