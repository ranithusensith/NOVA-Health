"""Verbatim lab observations and conservative projections for database storage."""

import re
from datetime import date
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictBool, field_validator

_DECIMAL = r"[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)"
_RANGE = re.compile(rf"({_DECIMAL})\s*(?:-|–|—|\bto\b)\s*({_DECIMAL})", re.I)
_BOUND = re.compile(rf"(<=|>=|[<>≤≥])\s*({_DECIMAL})")
_FLAGS = {"h": "high", "high": "high", "hh": "high", "↑": "high",
          "l": "low", "low": "low", "ll": "low", "↓": "low"}

RESULT_COLUMNS = "test_name,value,value_text,unit,ref_low,ref_high,flag,reported_on,reference_text,reported_flag"


def exact_number(text: str | None) -> str | None:
    """An exact decimal only. Keep other notations in the authoritative text."""
    if text is not None and len(text) <= 32 and re.fullmatch(_DECIMAL, text):
        return text
    return None


def reference_bounds(text: str | None) -> tuple[str | None, str | None]:
    if not text:
        return None, None
    if match := _RANGE.fullmatch(text):
        low, high = map(exact_number, match.groups())
        if low is not None and high is not None and Decimal(low) <= Decimal(high):
            return low, high
    if match := _BOUND.fullmatch(text):
        operator, boundary = match.groups()
        value = exact_number(boundary)
        return (None, value) if operator in ("<", "<=", "≤") else (value, None)
    return None, None


def reported_flag(text: str | None) -> str:
    # Preserve every other printed label separately without assigning clinical meaning.
    return _FLAGS.get((text or "").casefold(), "unknown")


def saved_observation(row: dict) -> dict:
    """Display reviewed text first, with fallbacks for pre-H6 records."""
    return {
        "test": row.get("test_name"),
        "result": row.get("value_text") or row.get("value"),
        "unit": row.get("unit"),
        "reference": row.get("reference_text") or [row.get("ref_low"), row.get("ref_high")],
        "flag": row.get("reported_flag") or row.get("flag"),
        "date": row.get("reported_on"),
    }


def report_date(text: str | None, today: date) -> str | None:
    if not isinstance(text, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", text):
        return None
    try:
        parsed = date.fromisoformat(text)
    except ValueError:
        return None
    return text if date(1900, 1, 1) <= parsed <= today else None


class ReviewedLabRow(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    test: str = Field(min_length=1, max_length=80)
    value_text: str = Field(min_length=1, max_length=160)
    extracted_value_text: str | None = Field(default=None, min_length=1, max_length=160)
    unit: str | None = Field(default=None, min_length=1, max_length=40)
    reference_text: str | None = Field(default=None, min_length=1, max_length=240)
    reported_flag: str | None = Field(default=None, min_length=1, max_length=40)

    @field_validator("test", "value_text", "extracted_value_text", "unit", "reference_text", "reported_flag")
    @classmethod
    def single_printed_field(cls, value: str | None) -> str | None:
        if value is not None and not value.isprintable():
            raise ValueError("Use printable characters on one line.")
        return value

    @field_validator("value_text")
    @classmethod
    def has_result(cls, value: str) -> str:
        if re.fullmatch(r"[<>=≤≥\s]+", value):
            raise ValueError("Enter the complete printed result.")
        return value

    def database_row(self, *, user_id: str, date_text: str | None, report_type: str | None) -> dict:
        low, high = reference_bounds(self.reference_text)
        return {
            "user_id": user_id, "test_name": self.test,
            "value_text": self.value_text, "value": exact_number(self.value_text),
            "extracted_value_text": self.extracted_value_text, "unit": self.unit,
            "reference_text": self.reference_text, "ref_low": low, "ref_high": high,
            "reported_flag": self.reported_flag, "flag": reported_flag(self.reported_flag),
            "report_type": report_type, "reported_on": date_text, "source": "scan_reviewed",
        }


class ReviewedLabReport(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    scan_id: UUID
    expected_user_id: UUID
    reviewed: StrictBool
    report_type: str | None = Field(default=None, min_length=1, max_length=80)
    report_date: str | None = Field(default=None, max_length=10)
    results: list[ReviewedLabRow] = Field(min_length=1, max_length=60)
