"""Render retained daily report observations without a model or clinical inference."""

from daily_metrics import number
from safety import finalize
from wearable_daily import SOURCES
from db import InvalidDBResponse


def render(snapshot: dict) -> str:
    observations = snapshot.get("observations")
    if not isinstance(observations, dict):
        raise InvalidDBResponse()

    def measure(key, unit, *, minimum=0, maximum=None, integer=False):
        value = number(observations.get(key), minimum=minimum, maximum=maximum, integer=integer)
        return "unknown" if value is None else f"{value:g} {unit}".strip()

    water = measure("water_ml", "mL logged", integer=True)
    water_goal = measure("water_goal_ml", "mL", minimum=1, maximum=20_000, integer=True)
    sleep = measure("sleep_hours", "hours", maximum=24)
    sleep_goal = measure("sleep_goal_hours", "hours", minimum=0.1, maximum=24)
    sleep_source = observations.get("sleep_source")
    if sleep != "unknown" and isinstance(sleep_source, str):
        origin = "manual log" if sleep_source == "manual" else SOURCES.get(sleep_source)
        if origin:
            sleep += f" ({origin})"
        else:
            sleep = "unknown"
    elif sleep != "unknown":
        sleep = "unknown"

    steps = measure("steps", "steps", maximum=1_000_000, integer=True)
    step_source = observations.get("steps_source")
    if steps != "unknown":
        if isinstance(step_source, str) and step_source in SOURCES:
            steps += f" ({SOURCES[step_source]})"
        else:
            steps = "unknown"

    return finalize("\n".join([
        "Saved observations at the time of generation",
        f"Water: {water}. Saved water target: {water_goal}.",
        f"Sleep: {sleep}. Saved sleep goal: {sleep_goal}.",
        f"Activity: {steps}.",
        f"Confirmed meal count: {measure('meal_count', '', minimum=1, integer=True)}.",
        f"Estimated calories from confirmed meals: {measure('calories', 'kcal', integer=True)}.",
        f"Scheduled doses marked taken: {measure('dose_confirmations', '', minimum=1, integer=True)}.",
        f"Symptom entries with onset on this date: {measure('symptom_onsets', '', minimum=1, integer=True)}.",
        "",
        "Missing measurements and entries are unknown. Recorded counts cannot establish adherence, symptoms outside the log, or a diagnosis.",
    ]), [])
