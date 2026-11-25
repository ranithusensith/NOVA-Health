"""Confirmed meal quantities and validated food-scan estimates."""

from decimal import Decimal, InvalidOperation
import re

LIMITS = {"calories": 5000, "protein_g": 500, "carbs_g": 800, "fat_g": 500}
_ESTIMATE = re.compile(r"[0-9]+(?:[.,][0-9]+)?")


def quantity(key, raw, *, estimate=False):
    if estimate and isinstance(raw, str):
        raw = raw.strip()
        if not _ESTIMATE.fullmatch(raw):
            return None
        raw = raw.replace(",", ".")
    elif type(raw) not in (int, float):
        return None
    if key == "calories" and not estimate and type(raw) is not int:
        return None
    try:
        value = Decimal(str(raw))
        if not value.is_finite() or not 0 <= value <= LIMITS[key]:
            return None
        precision = Decimal("1") if key == "calories" else Decimal("0.1")
        if value != value.quantize(precision):
            return None
    except (InvalidOperation, ValueError):
        return None
    return int(value) if key == "calories" else float(value)


def total(rows, key):
    if not rows:
        return None
    scaled_sum = 0
    for row in rows:
        nutrients = row.get("nutrients")
        raw = row.get(key) if key == "calories" else (
            nutrients.get(key) if isinstance(nutrients, dict) else None
        )
        value = quantity(key, raw)
        if value is None:
            return None
        scaled_sum += round(value * 10)
    return scaled_sum // 10 if key == "calories" else scaled_sum / 10
