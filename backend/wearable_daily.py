"""Account-scoped platform totals with explicit local calendar boundaries."""

from datetime import date, datetime

from daily_metrics import instant

SOURCES = {"apple_health": "Apple Health", "health_connect": "Health Connect"}
Window = tuple[datetime, datetime]
ROW_LIMIT = 500


async def rows_for_windows(db, windows: dict[date, Window], *, metric: str | None = None) -> list[dict]:
    start, end = min(windows), max(windows)
    filters = {"and": f"(local_date.gte.{start},local_date.lte.{end})"}
    if metric is not None:
        filters["metric"] = f"eq.{metric}"
    return await db.select(
        "wearable_daily_totals", "metric,local_date,window_start,window_end,captured_at,value,source",
        filters=filters, order="local_date.desc", limit=ROW_LIMIT,
    )


def observation(row: dict, windows: dict[date, Window]):
    day = date.fromisoformat(row["local_date"])
    bounds = (instant(row["window_start"]), instant(row["window_end"]))
    if windows.get(day) != bounds:
        return None
    captured_at = instant(row["captured_at"])
    metric, source, value = row["metric"], row["source"], row["value"]
    if captured_at <= bounds[0] or source not in SOURCES or type(value) is not int:
        raise ValueError("Invalid wearable observation")
    if not (metric == "steps" and 0 <= value <= 1_000_000 or metric == "sleep" and 0 < value <= 86_400):
        raise ValueError("Invalid wearable total")
    return day, metric, SOURCES[source], value, captured_at


async def read(db, windows: dict[date, Window]) -> dict:
    if not windows:
        return {}
    rows = await rows_for_windows(db, windows)
    if len(rows) >= ROW_LIMIT:
        return {}
    verified = {}
    for row in rows:
        try:
            entry = observation(row, windows)
        except (TypeError, ValueError, KeyError):
            continue
        if entry:
            day, metric, source, value, _ = entry
            verified.setdefault(day.isoformat(), {})[metric] = {"value": value, "source": source}
    return verified
