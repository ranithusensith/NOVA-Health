import asyncio
from datetime import date

import pytest
from fastapi.testclient import TestClient

import lab_results
import llm
import main
import reports
import scan
import tools
from db import DBError
from fakes import FakeDB, enable_test_ai, post_reviewed_text, script_llm

REPORT_TEXT = "WBC 7400 /uL reference 4000 - 11000"
ACCOUNT = "00000000-0000-4000-8000-000000000601"
SCAN_ID = "00000000-0000-4000-8000-000000000603"


def printed_row(test, value, *, unit=None, reference=None, flag=None):
    line = " | ".join(part for part in (test, value, unit, reference, flag) if part is not None)
    return {"source_line": line, "test": test, "value_text": value, "unit": unit,
            "reference_text": reference, "reported_flag": flag}


def test_daily_report_filters_by_schedule_and_separates_unassigned_doses():
    db = FakeDB({
        "medications": [{"name": "Synthetic", "times": ["08:00", "21:00"]}],
        "medication_logs": [
            {"status": "taken", "occurrence_key": "daily:1793566800000000"},
            {"status": "taken", "occurrence_key": None},
            {"status": "skipped", "occurrence_key": None},
        ],
    })
    data = asyncio.run(reports.build_daily_data(db, date(2026, 11, 1)))
    assert (data["doses_taken"], data["doses_scheduled"], data["unassigned_dose_logs"]) == (1, 2, 1)
    _, _, filters = next(query for query in db.selects if query[0] == "medication_logs")
    assert "scheduled_local_at.gte.2026-11-01T00:00:00" in filters["or"]
    assert "scheduled_local_at.is.null,scheduled_at.gte." in filters["or"]
    assert "scheduled_at.is.null,taken_at.gte." in filters["or"]
    assert "Medicines: 1 dose log(s) without a scheduled time" in reports.highlights(data)


# ------------------------------------------------------------ parsing and flags
@pytest.mark.parametrize("printed", ["<0.4", ">0.4", "<=0.40", ">=0.40", "≤ 0.40", "≥ 0.40",
                                      "7,400", "7 400", "1.2e3", "Not detected", "Indeterminate"])
def test_thresholds_and_other_non_exact_text_round_trip(printed):
    item = printed_row("Synthetic test", printed, unit="mg/L", reference=">0.10 (method A)", flag="Check")
    result = scan.parse_report({"is_report": True, "results": [item]}, item["source_line"]).results[0]
    assert (result.value_text, result.value, result.unit) == (printed, None, "mg/L")
    assert (result.reference_text, result.ref_low, result.ref_high) == (">0.10 (method A)", None, None)
    assert (result.reported_flag, result.flag) == ("Check", "unknown")


@pytest.mark.parametrize("printed,shortened", [("<=0.4", "0.4"), (">= 0.4", "0.4"), ("7 400", "7"),
                                                ("0.4-0.8", "0.4"), ("0.40", "0.4"), ("< 0.4", "<"),
                                                ("1.2 × 10^3", "1.2"), ("4 ± 1", "4")])
def test_model_cannot_turn_partial_text_into_measurement(printed, shortened):
    item = printed_row("Synthetic test", printed)
    item["value_text"] = shortened
    r = scan.parse_report({"results": [item]}, item["source_line"]).results[0]
    assert r.value is None and r.value_text is None and r.flag == "unknown"


def test_exact_value_retains_printed_precision_and_only_printed_flags():
    item = printed_row("Synthetic test", "-1.2300", unit="g/L", reference="-2.00 – 2.00", flag="↓")
    r = scan.parse_report({"results": [item]}, item["source_line"]).results[0]
    assert (r.value_text, r.value, r.ref_low, r.ref_high) == ("-1.2300", -1.23, -2, 2)
    assert (r.reported_flag, r.flag) == ("↓", "low")
    without_flag = {**item, "reported_flag": None}
    assert scan.parse_report({"results": [without_flag]}, item["source_line"]).results[0].flag == "unknown"
    assert lab_results.reference_bounds("<= 3.00") == (None, "3.00")
    assert lab_results.reference_bounds(">= 0.25") == ("0.25", None)


def test_flag_cannot_reuse_unit_or_reference_text():
    printed = printed_row("Synthetic test", "0.40", unit="L", reference="0.1–1.0 (method H)")
    for flag in ("L", "H"):
        raw = {"results": [{**printed, "reported_flag": flag}]}
        assert scan.parse_report(raw, printed["source_line"]).results[0].reported_flag is None
    distinct = printed_row("Synthetic test", "0.40", unit="L", flag="L")
    assert scan.parse_report({"results": [distinct]}, distinct["source_line"]).results[0].flag == "low"


def test_unverified_fields_require_review_and_hallucinated_rows_are_dropped():
    line = "WBC\t7400 /uL reference 4000 - 11000"
    row = {"source_line": line, "test": "WBC", "value_text": "7400", "unit": "mg/L",
           "reference_text": "5000 - 11000", "reported_flag": "normal"}
    raw = {"is_report": True, "results": [row, {"test": "Invented test"}, {"test": "Unreadable"}, "junk"], "confidence": 80}
    report = scan.parse_report(raw, f"{line}\nUnreadable")
    verified, incomplete = report.results
    assert verified.value_text == "7400" and verified.unit is None and verified.reference_text is None
    assert verified.reported_flag is None and verified.flag == "unknown"
    assert incomplete.test == "Unreadable" and incomplete.value_text is None
    assert report.confidence == 0.8


@pytest.mark.parametrize("claimed,line,expected", [
    ("2025-10-20", "Report date: 2025-10-20", "2025-10-20"),
    ("2025-10-20", "DOB: 2025-10-20", None),
    ("2025-10-20", "Report date: 2025-10-21", None),
    ("2025-10-20T08:00:00", "Report date: 2025-10-20T08:00:00", None),
    ("2099-10-20", "Report date: 2099-10-20", None),
    (None, "", None),
])
def test_report_date_requires_evidence(claimed, line, expected):
    raw = {"report_date": claimed, "report_date_line": line}
    assert scan.parse_report(raw, line, today=date(2026, 11, 24)).report_date == expected
    assert scan.parse_report(raw, "", today=date(2026, 11, 24)).report_date is None


def test_results_are_capped():
    rows = [printed_row(f"T{i}", str(i)) for i in range(200)]
    raw = {"is_report": True, "results": rows}
    assert len(scan.parse_report(raw, "\n".join(row["source_line"] for row in rows)).results) == 60


def test_not_a_report_is_rejected(monkeypatch):
    script_llm(monkeypatch, [{"is_report": False, "results": []}])

    async def authorized():
        pass

    with pytest.raises(scan.ScanError):
        asyncio.run(scan.scan_report("A grocery list", authorize=authorized))


# ------------------------------------------------------------ endpoint
@pytest.fixture(autouse=True)
def overrides(monkeypatch):
    db = FakeDB(user_id=ACCOUNT)
    enable_test_ai(monkeypatch, db)
    main.app.dependency_overrides[main.current_user] = lambda: {"id": ACCOUNT, "email": "t@example.com"}
    main.app.dependency_overrides[main.get_db] = lambda: db
    main._scan_counts.clear()
    yield db
    main.app.dependency_overrides.clear()


def test_report_endpoint_success(monkeypatch):
    prompts = []
    threshold = printed_row("LDL cholesterol", ">= 4.10", unit="mmol/L", reference="< 3.0", flag="H")
    script_llm(monkeypatch, [{
        "is_report": True,
        "report_type": "Lipid profile",
        "results": [threshold, {"source_line": REPORT_TEXT, "test": "WBC", "value_text": "7400",
                                "unit": "/uL", "reference_text": "4000 - 11000"}],
        "confidence": 0.9,
    }], prompts)
    source = threshold["source_line"] + "\n" + REPORT_TEXT + "\nPhone: 4000 - 11000"
    res = post_reviewed_text(TestClient(main.app), "report", source)
    assert res.status_code == 200 and res.headers["cache-control"] == "no-store"
    d = res.json()["data"]
    assert d["needs_user_confirmation"] is True and d["report_type"] == "Lipid profile"
    assert d["results"][0]["value_text"] == ">= 4.10" and d["results"][0]["value"] is None
    assert d["results"][0]["reported_flag"] == "H" and d["results"][0]["flag"] == "high"
    assert prompts[0].count("4000 - 11000") == 1 and REPORT_TEXT in prompts[0]
    assert (d["results"][1]["ref_low"], d["results"][1]["ref_high"], d["results"][1]["flag"]) == (4000, 11000, "unknown")


def test_report_endpoint_errors(monkeypatch):
    script_llm(monkeypatch, [{"is_report": False, "results": []}])
    c = TestClient(main.app)
    res = post_reviewed_text(c, "report", REPORT_TEXT)
    assert res.status_code == 422 and res.json()["error"]["code"] == "SCAN_FAILED"
    bad = c.post("/api/v1/scan/medical-text", files={"image": ("r.pdf", b"%PDF-1.4", "application/pdf")})
    assert bad.status_code == 400 and bad.json()["error"]["code"] == "INVALID_INPUT"
    legacy = c.post("/api/v1/scan/report", files={"image": ("r.pdf", b"%PDF-1.4", "application/pdf")})
    assert legacy.status_code == 422 and legacy.json()["error"]["code"] == "INVALID_INPUT"
    script_llm(monkeypatch, [llm.LLMError("busy", 429)])
    busy = post_reviewed_text(c, "report", REPORT_TEXT)
    assert busy.status_code == 429 and busy.json()["error"]["code"] == "RATE_LIMITED"


def reviewed_payload(**changes):
    return {"scan_id": SCAN_ID, "expected_user_id": ACCOUNT, "reviewed": True, "report_type": "Synthetic report",
            "report_date": None, "results": [{"test": "Synthetic protein", "value_text": "<=0.40",
                                               "extracted_value_text": "<=0.50", "unit": "mg/L",
                                               "reference_text": ">0.10 (method A)", "reported_flag": "Check"}],
            **changes}


def test_confirmation_saves_corrected_text_without_provider_or_date(monkeypatch, overrides):
    script_llm(monkeypatch, [])
    overrides.tables["ai_processing_consents"] = []
    path = "/api/v1/scan/report/confirm"
    client = TestClient(main.app)
    payload = reviewed_payload()
    response = client.post(path, json=payload)
    assert response.json() == {"data": {"saved": 1}}
    assert response.headers["cache-control"] == "no-store"
    table, rows = overrides.inserted[0]
    assert table == "lab_results"
    row = rows[0]
    assert row == {"id": row["id"], "user_id": ACCOUNT, "test_name": "Synthetic protein",
                   "value_text": "<=0.40", "extracted_value_text": "<=0.50", "value": None,
                   "unit": "mg/L", "reference_text": ">0.10 (method A)", "ref_low": None,
                   "ref_high": None, "reported_flag": "Check", "flag": "unknown",
                   "reported_on": None, "report_type": "Synthetic report", "source": "scan_reviewed"}
    client.post(path, json=payload)
    assert overrides.inserted[1][1][0]["id"] == row["id"]


@pytest.mark.parametrize("changes,code", [
    ({"expected_user_id": "00000000-0000-4000-8000-000000000602"}, "FORBIDDEN"),
    ({"reviewed": False}, "REVIEW_REQUIRED"),
    ({"reviewed": "true"}, "INVALID_INPUT"),
    ({"report_date": "2099-12-01"}, "INVALID_INPUT"),
    ({"report_date": "2025-02-29"}, "INVALID_INPUT"),
    ({"results": []}, "INVALID_INPUT"),
    ({"results": [{"test": "Synthetic", "value_text": "<="}]}, "INVALID_INPUT"),
    ({"results": [{"test": "Synthetic", "value_text": "<0.4", "value": 0.4}]}, "INVALID_INPUT"),
    ({"results": [{"test": "Synthetic", "value_text": "a\nb"}]}, "INVALID_INPUT"),
])
def test_confirmation_rejects_unreviewed_invalid_or_cross_account_writes(overrides, changes, code):
    response = TestClient(main.app).post("/api/v1/scan/report/confirm", json=reviewed_payload(**changes))
    assert response.json()["error"]["code"] == code and not overrides.inserted
    assert response.headers["cache-control"] == "no-store"


def test_confirmation_does_not_expose_database_error(monkeypatch, overrides):
    async def fail(*args):
        raise DBError("synthetic private details")

    monkeypatch.setattr(overrides, "insert", fail)
    response = TestClient(main.app).post("/api/v1/scan/report/confirm", json=reviewed_payload())
    assert response.status_code == 502 and response.json()["error"]["code"] == "LAB_SAVE_UNVERIFIED"
    assert "synthetic private details" not in response.text


def test_daily_report_and_assistant_use_the_same_corrected_observation(overrides, monkeypatch):
    client = TestClient(main.app)
    script_llm(monkeypatch, [])
    assert client.post("/api/v1/scan/report/confirm", json=reviewed_payload(report_date="2025-06-07")).status_code == 200
    overrides.tables["lab_results"] = overrides.inserted[0][1]
    item = asyncio.run(tools.get_lab_results(overrides, {}))["results"][0]
    assert item == {"test": "Synthetic protein", "result": "<=0.40", "unit": "mg/L",
                    "reference": ">0.10 (method A)", "flag": "Check", "date": "2025-06-07"}
    response = client.get("/api/v1/reports/daily?date=2025-06-07")
    assert response.headers["cache-control"] == "no-store"
    report = response.json()["data"]["report"]
    assert "Synthetic protein <=0.40 mg/L · reference >0.10 (method A) · recorded flag Check" in report
    assert "<=0.50" not in report
    assert overrides.selects[-1][0] == "lab_results"
    assert overrides.selects[-1][2] == {"reported_on": "eq.2025-06-07"}


# ------------------------------------------------------------ assistant tool
def test_lab_results_tool():
    db = FakeDB({"lab_results": [
        {"test_name": "Haemoglobin", "value": 11.2, "value_text": None, "unit": "g/dL",
         "ref_low": 13, "ref_high": 17, "flag": "low", "reported_on": "2025-10-20"},
        {"test_name": "Urine protein", "value": None, "value_text": "Negative", "unit": None,
         "ref_low": None, "ref_high": None, "flag": "unknown", "reported_on": None},
    ]})
    out = asyncio.run(tools.get_lab_results(db, {}))
    assert out["count"] == 2
    assert out["results"][0] == {"test": "Haemoglobin", "result": 11.2, "unit": "g/dL",
                                 "reference": [13, 17], "flag": "low", "date": "2025-10-20"}
    assert out["results"][1]["result"] == "Negative"
    assert asyncio.run(tools.get_lab_results(FakeDB(), {}))["count"] == 0


def test_lab_tool_is_registered_for_the_assistant():
    assert "get_lab_results" in tools.TOOLS
    assert "get_lab_results" in tools.describe_tools()
    assert tools.source_label("get_lab_results", {}) == "lab results"
