"""Matching and scoring helpers for the evaluation (pure functions, unit tested)."""

import difflib
import re
import statistics


def norm_name(s: str | None) -> str:
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())


def similar(a: str | None, b: str | None, threshold: float = 0.85) -> bool:
    x, y = norm_name(a), norm_name(b)
    if not x or not y:
        return False
    return x == y or difflib.SequenceMatcher(None, x, y).ratio() >= threshold


def times_per_day(text: str | None) -> int | None:
    """'3 times a day' -> 3, 'twice daily' -> 2, 'every 8 hours' -> 3, '1 tablet at night' -> 1."""
    if not text:
        return None
    t = text.lower()
    m = re.search(r"every\s+(\d+)\s*(?:-\s*\d+\s*)?hours?", t)
    if m and int(m.group(1)) > 0:
        return max(1, round(24 / int(m.group(1))))
    words = {"once": 1, "one time": 1, "twice": 2, "two times": 2, "thrice": 3, "three times": 3,
             "four times": 4, "five times": 5}
    for w, n in words.items():
        if w in t:
            return n
    m = re.search(r"(\d+)\s*(?:x|times)", t)
    if m:
        return int(m.group(1))
    if any(k in t for k in ("daily", "a day", "per day", "night", "morning", "evening", "bedtime", "each day")):
        return 1
    return None


def same_text(a: str | None, b: str | None) -> bool:
    return norm_name(a) == norm_name(b) and bool(norm_name(a) or not norm_name(b))


def same_number(a, b, rel: float = 0.01) -> bool:
    if a is None or b is None:
        return a is None and b is None
    try:
        a, b = float(a), float(b)
    except (TypeError, ValueError):
        return False
    return abs(a - b) <= max(abs(b) * rel, 1e-9)


def match_items(expected: list[dict], got: list[dict], key: str):
    """Greedy name matching. Returns (pairs[(exp, got)], missed[exp], extra[got])."""
    remaining = list(got)
    pairs, missed = [], []
    for e in expected:
        hit = next((g for g in remaining if similar(e.get(key), g.get(key))), None)
        if hit is None:
            missed.append(e)
        else:
            pairs.append((e, hit))
            remaining.remove(hit)
    return pairs, missed, remaining


def prf(tp: int, fn: int, fp: int) -> tuple[float, float, float]:
    p = tp / (tp + fp) if tp + fp else 1.0
    r = tp / (tp + fn) if tp + fn else 1.0
    f = 2 * p * r / (p + r) if p + r else 0.0
    return p, r, f


# ---------------------------------------------------------------- scoring one image
def score_prescription(expected: list[dict], got: list[dict]) -> dict:
    pairs, missed, extra = match_items(expected, got, "name")
    fields = {"dosage": 0, "frequency": 0, "duration": 0}
    for e, g in pairs:
        fields["dosage"] += same_text(e["dosage"], g.get("dosage"))
        fields["frequency"] += times_per_day(g.get("frequency")) == e["times_per_day"]
        fields["duration"] += g.get("duration_days") == e["duration_days"]
    return {"tp": len(pairs), "fn": len(missed), "fp": len(extra), "pairs": len(pairs), **fields}


def score_report(expected: list[dict], got: list[dict]) -> dict:
    pairs, missed, extra = match_items(expected, got, "test")
    fields = {"value": 0, "unit": 0, "range": 0, "flag": 0}
    for e, g in pairs:
        if "reference_text" in e:
            fields["value"] += g.get("value_text") == e["value_text"]
            fields["unit"] += g.get("unit") == e["unit"]
            fields["range"] += g.get("reference_text") == e["reference_text"]
            fields["flag"] += g.get("reported_flag") == e.get("reported_flag")
            continue
        if e.get("value") is None:
            fields["value"] += same_text(e.get("value_text"), g.get("value_text"))
        else:
            fields["value"] += same_number(g.get("value"), e["value"])
        fields["unit"] += same_text(e.get("unit"), g.get("unit")) or (not e.get("unit") and not g.get("unit"))
        fields["range"] += same_number(g.get("ref_low"), e.get("ref_low")) and same_number(g.get("ref_high"), e.get("ref_high"))
        fields["flag"] += g.get("flag") == e["flag"]
    return {"tp": len(pairs), "fn": len(missed), "fp": len(extra), "pairs": len(pairs), **fields}


def add_scores(a: dict, b: dict) -> dict:
    return {k: a.get(k, 0) + b.get(k, 0) for k in set(a) | set(b)}


# ---------------------------------------------------------------- timing
def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    v = sorted(values)
    k = (len(v) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def mean_sd(values: list[float]) -> tuple[float, float]:
    if not values:
        return 0.0, 0.0
    return statistics.mean(values), (statistics.pstdev(values) if len(values) > 1 else 0.0)
