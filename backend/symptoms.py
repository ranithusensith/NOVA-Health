"""Patient-recorded symptom observations and the existing local red-flag policy."""

from datetime import datetime, timedelta

import daily_metrics
import safety

SUMMARY_COLUMNS = "name,severity,status,started_at"
SAFETY_COLUMNS = "name,notes,status,started_at"
SEVERITIES = ("mild", "moderate", "severe")
STATUSES = ("active", "resolved")


def observation(row: dict) -> dict:
    name = row.get("name")
    severity = row.get("severity")
    status = row.get("status")
    return {
        "name": " ".join(name.split())[:120] if isinstance(name, str) else "",
        "severity": severity if severity in SEVERITIES else None,
        "status": status if status in STATUSES else None,
    }


def description(row: dict) -> str:
    name = row["name"] or "Symptom type unknown"
    severity = f"severity {row['severity']}" if row["severity"] else "severity unknown"
    status = f"marked {row['status']}" if row["status"] else "status unknown"
    return f"“{name}” ({severity}, {status})"


def recent_emergency(rows: list[dict], now: datetime) -> tuple[str, str] | None:
    """Use the P0-2 window and statuses for saved rows and unsaved drafts."""
    cutoff = now - timedelta(hours=24)
    medical = None
    for row in rows:
        if row.get("status") != "active":
            continue
        try:
            started = daily_metrics.instant(row["started_at"])
        except (TypeError, ValueError, KeyError):
            continue
        if not cutoff <= started <= now:
            continue
        for text in (row.get("name"), row.get("notes")):
            if not isinstance(text, str):
                continue
            kind = safety.detect_emergency(text)
            if kind == "self_harm":
                return kind, text
            if kind == "medical" and medical is None:
                medical = kind, text
    return medical
