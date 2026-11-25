"""Account-scoped platform totals with explicit local calendar boundaries."""

from datetime import date, datetime

from daily_metrics import instant

SOURCES = {"apple_health": "Apple Health", "health_connect": "Health Connect"}
Window = tuple[datetime, datetime]


async def read(db, windows: dict[date, Window]) -> dict:
    if not windows:
        return {}
    start, end = min(windows), max(windows)
    rows = await db.select(
        "wearable_daily_totals", "metric,local_date,window_start,window_end,captured_at,value,source",
        filters={"and": f"(local_date.gte.{start},local_date.lte.{end})"},
        order="local_date.desc", limit=500,
    )
    if len(rows) >= 500:
        return {}
    verified = {}
    for row in rows:
        try:
            day = date.fromisoformat(row["local_date"])
            bounds = (instant(row["window_start"]), instant(row["window_end"]))
            captured_at = instant(row["captured_at"])
        except (TypeError, ValueError, KeyError):
            continue
        if windows.get(day) != bounds or captured_at <= bounds[0]:
            continue
        metric, source, value = row.get("metric"), row.get("source"), row.get("value")
        if not isinstance(source, str) or source not in SOURCES or type(value) is not int:
            continue
        if metric == "steps" and 0 <= value <= 1_000_000 or metric == "sleep" and 0 < value <= 86_400:
            verified.setdefault(day.isoformat(), {})[metric] = {"value": value, "source": SOURCES[source]}
    return verified
