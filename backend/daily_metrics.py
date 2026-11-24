"""Daily tracking rules shared by the report and grounded assistant tools."""

from datetime import date, datetime, time, timedelta, timezone
from math import isfinite


def instant(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    if parsed.utcoffset() is None:
        raise ValueError("An instant needs an offset")
    return parsed


def utc_midnight(day: date, offset: int) -> datetime:
    return datetime.combine(day, time(), timezone(timedelta(minutes=offset))).astimezone(timezone.utc)


def day_window(day: date, offsets: tuple[int, int]) -> tuple[datetime, datetime]:
    start, end = (utc_midnight(day + timedelta(days=i), offset) for i, offset in enumerate(offsets))
    if not start < end:
        raise ValueError("Invalid local date window")
    return start, end


class LocalCalendar:
    """A contiguous sequence of device-local midnights, ending after the device's today."""

    def __init__(self, today: date, offsets: list[int]):
        first = today - timedelta(days=len(offsets) - 2)
        self.days = [first + timedelta(days=i) for i in range(len(offsets))]
        self.boundaries = [utc_midnight(day, offset) for day, offset in zip(self.days, offsets, strict=True)]
        if any(a >= b for a, b in zip(self.boundaries, self.boundaries[1:])):
            raise ValueError("Non-increasing local midnights")

    def day_for(self, value: str) -> date:
        point = instant(value)
        for day, start, end in zip(self.days, self.boundaries, self.boundaries[1:]):
            if start <= point < end:
                return day
        raise ValueError("Record outside the device calendar")


def number(value, *, minimum=0, maximum=None, integer=False):
    if type(value) not in (int, float) or (type(value) is float and not isfinite(value)):
        return None
    if value < minimum or (maximum is not None and value > maximum) or (integer and type(value) is not int):
        return None
    return value


def total(rows, key):
    if not rows:
        return None
    values = [number(row.get(key), integer=True) for row in rows]
    return sum(values) if all(value is not None for value in values) else None


class ConflictingMeasurements(ValueError):
    """Multiple different values were saved at the same latest instant."""


def latest_value(rows, key, normalize):
    """Latest entry supersedes earlier ones. A disagreement at the latest instant is unknown."""
    if not rows:
        return None
    instants = [(instant(row["logged_at"]), normalize(row.get(key))) for row in rows]
    latest = max(recorded for recorded, _ in instants)
    values = {value for recorded, value in instants if recorded == latest}
    if len(values) > 1:
        raise ConflictingMeasurements
    return values.pop()


def sleep_hours(rows):
    return latest_value(rows, "hours", lambda value: number(value, maximum=24))


def mood(rows):
    return latest_value(rows, "mood", lambda value: value if value in ("bad", "low", "ok", "good", "great") else None)
