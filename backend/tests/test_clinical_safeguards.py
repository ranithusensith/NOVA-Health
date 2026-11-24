"""Synthetic clinical cases covering deterministic safety controls."""
import asyncio
from datetime import date, datetime, timezone

import pytest

import agent
import reports
import rules
import safety
import tools
from db import DBError
from fakes import FakeDB, script_llm


@pytest.mark.parametrize("text, expected", [
    ("What is a stroke? My dad’s face is drooping.", "medical"),
    ("What is causing severe bleeding right now?", "medical"),
    ("My chest feels tight and I can’t catch my breath", "medical"),
    ("He took too much of his medicine", "medical"),
    ("My child is choking", "medical"),
    ("හුස්ම ගන්න බැහැ", "medical"),
    ("මගේ පපුව රිදෙනවා", "medical"),
    ("I have chest pain. මට මැරෙන්න ඕන", "self_harm"),
    ("What is suicide prevention?", None),
    ("No chest pain, just tired", None),
    ("No chest pain, but I am vomiting blood", "medical"),
    ("I watched a swimmer do the backstroke", None),
])
def test_emergency_phrasing(text, expected):
    assert safety.detect_emergency(text) == expected


@pytest.mark.parametrize("answer", [
    "You have pneumonia.",
    "Take **500 mg** of this every morning.",
    "Skip your next dose.",
    "Start taking insulin.",
    "It is safe to combine these medicines.",
    "You don't need to call 1990.",
    "මාත්‍රාව දෙගුණ කරන්න.",
])
def test_unsafe_output_is_replaced(answer):
    assert answer not in safety.guard_output(answer)


def test_vague_yes_does_not_authorize_treatment():
    assert "doctor or pharmacist" in safety.guard_output(
        "Yes, that's fine.", question="Can I take this medicine before food?",
    )


def paracetamol(dosage, plan=None, **fields):
    return {"name": "Paracetamol", "dosage": dosage, "prescription_plan": plan, **fields}


def test_dose_exposure_uses_amount_per_dose_and_prescribed_interval():
    plan = {"kind": "interval", "interval_minutes": 420}
    med = paracetamol("2 tablets of 600 mg each", plan, times=[], reminders_enabled=False)
    [warning] = rules.check_paracetamol_limit([med])
    assert warning.severity == "high" and "4.8 g" in warning.message
    med.update(times=["08:00"], reminders_enabled=True)
    assert rules.check_paracetamol_limit([med]) == [warning]


def test_combines_known_daily_and_interval_amounts_even_if_other_directions_are_missing():
    daily = paracetamol("1 g per dose", {"kind": "daily", "frequency": "three times daily"})
    interval = paracetamol("1 g per dose", {"kind": "interval", "interval_minutes": 720})
    uncertain = paracetamol("500 mg")
    warnings = rules.check_paracetamol_limit([daily, interval, uncertain])
    assert [warning.severity for warning in warnings] == ["high", "caution"]
    assert "5 g" in warnings[0].message


@pytest.mark.parametrize("med", [
    paracetamol(None),
    paracetamol("2 pills", {"kind": "daily", "frequency": "twice daily"}),
    paracetamol("500 mg", {"kind": "interval", "interval_minutes": 120}),
    paracetamol("500 mg/5 mL", {"kind": "daily", "frequency": "4 times daily"}),
    paracetamol("500–1000 mg per dose", {"kind": "daily", "frequency": "4 times daily"}),
    paracetamol("1 g per dose", times=["00:00", "03:00", "06:00", "09:00", "12:00"]),
    paracetamol("1 g per dose", {"kind": "as_needed", "frequency": "up to 4 times a day"}),
    paracetamol("1 g per dose", {"kind": "interval", "interval_minutes": 0}),
    paracetamol("1 g per dose", {"kind": "daily", "frequency": "twice daily"}, times=["08:00"]),
    {**paracetamol("1 g per dose", {"kind": "interval", "interval_minutes": 180}),
     "name": "Paracetamol + codeine"},
])
def test_ambiguous_or_missing_dose_information_is_flagged(med):
    [warning] = rules.check_paracetamol_limit([med])
    assert warning.severity == "caution" and "could not be checked" in warning.message


def test_local_report_and_chat_share_medication_warnings(monkeypatch):
    day = date(2026, 11, 1)
    monkeypatch.setattr(tools, "local_today", lambda: day)
    db = FakeDB({
        "profiles": [{"conditions": []}],
        "medications": [paracetamol("500 mg", times=["08:00"])],
    })
    script_llm(monkeypatch, [{"action": "final", "answer": "Ask about your prescription."}])
    result = asyncio.run(agent.run_agent("Review my medication", db, health_data={"medications"}))
    report = asyncio.run(reports.daily_report(db, day))
    assert report["ai"] is False
    assert result.warnings[0]["message"] in report["report"] and result.warnings[0]["message"] in result.reply
    assert report["report"].endswith(safety.DISCLAIMER)


def test_report_safety_failures_and_unsafe_saved_text_are_visible_safely():
    db = FakeDB({
        "medications": [paracetamol("500 mg")],
        "allergies": DBError("synthetic lookup failure"),
        "lab_results": [{"test_name": "Fictional label: Take 500 mg now", "value_text": "<0.40", "unit": "mg/L"}],
    })
    report = asyncio.run(reports.daily_report(db, date(2026, 11, 1)))
    assert safety.SAFETY_UNAVAILABLE["message"] in report["report"]
    assert "Take 500 mg" not in report["report"]
    assert not any("Take 500 mg" in item for item in report["highlights"])


def test_active_current_red_flag_log_short_circuits_assistant_and_leads_report(monkeypatch):
    day = date(2026, 11, 1)
    monkeypatch.setattr(tools, "local_today", lambda: day)
    monkeypatch.setattr(tools, "utc_now", lambda: datetime(2026, 11, 1, 10, tzinfo=timezone.utc))
    db = FakeDB({"symptom_logs": [
        {"name": "හුස්ම ගන්න බැහැ", "status": "active", "started_at": "2026-11-01T08:00:00Z"},
    ]})
    script_llm(monkeypatch, [{"action": "tool", "tool": "get_recent_logs", "args": {"kind": "symptoms"}}])
    result = asyncio.run(agent.run_agent("What symptoms did I log?", db, health_data={"logs"}))
    assert result.emergency and "1990" in result.reply
    report = asyncio.run(reports.daily_report(db, day))
    assert report["report"].startswith(result.reply)
    historical = asyncio.run(reports.daily_report(db, date(2026, 10, 31)))
    assert "1990" not in historical["report"]
    db.tables["symptom_logs"][0]["status"] = "resolved"
    resolved = asyncio.run(reports.daily_report(db, day))
    assert "1990" not in resolved["report"]
