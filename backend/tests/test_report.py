import asyncio
from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient

import llm
import main
import reports
import scan
import tools
from fakes import FakeDB, enable_test_ai, post_reviewed_text, script_llm

REPORT_TEXT = "WBC 7400 /uL reference 4000 - 11000"

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
def test_flags_are_computed_from_the_numbers():
    assert scan.compute_flag(9.0, 13.0, 17.0) == "low"
    assert scan.compute_flag(15.0, 13.0, 17.0) == "normal"
    assert scan.compute_flag(18.2, 13.0, 17.0) == "high"
    assert scan.compute_flag(7.0, None, 5.6) == "high"
    assert scan.compute_flag(40.0, 50.0, None) == "low"


def test_model_flag_is_only_used_when_numbers_are_missing():
    assert scan.compute_flag(None, None, None, "high") == "high"
    assert scan.compute_flag(None, None, None, "dangerous") == "unknown"
    # the model says normal but the numbers say high: the numbers win
    assert scan.compute_flag(20.0, 10.0, 15.0, "normal") == "high"


def test_range_text_is_understood():
    assert scan._parse_range_text("13.0 - 17.0") == (13.0, 17.0)
    assert scan._parse_range_text("13,0-17,0 g/dL") == (13.0, 17.0)
    assert scan._parse_range_text("< 5.6") == (None, 5.6)
    assert scan._parse_range_text("> 40") == (40.0, None)
    assert scan._parse_range_text("see note") == (None, None)
    assert scan._parse_range_text("4,000 - 11,000") == (4000.0, 11000.0)


def test_number_parsing():
    assert scan._num_or_none("5,2") == 5.2
    assert scan._num_or_none("7,400") == 7400.0
    assert scan._num_or_none("<0.5") == 0.5
    assert scan._num_or_none("-1.5") == -1.5
    assert scan._num_or_none("12 mg/dL") == 12.0
    assert scan._num_or_none("Negative") is None
    assert scan._num_or_none(None) is None


def test_parse_report_cleans_messy_model_output():
    raw = {
        "is_report": True,
        "report_type": "Full blood count",
        "report_date": "2025-10-20",
        "results": [
            {"test": "Haemoglobin", "value": "11.2", "unit": "g/dL", "ref_low": 13, "ref_high": "17.0"},
            {"test": "WBC", "value": "7,400", "unit": "/uL", "reference_range": "4000 - 11000"},
            {"test": "Urine protein", "value": None, "value_text": "Negative"},
            {"test": "", "value": 1},
            {"test": "Empty row", "value": None},
            "junk",
        ],
        "confidence": 80,
    }
    r = scan.parse_report(raw)
    names = [x.test for x in r.results]
    assert names == ["Haemoglobin", "WBC", "Urine protein"]
    hb = r.results[0]
    assert hb.value == 11.2 and hb.flag == "low"
    assert r.results[1].value == 7400 and r.results[1].flag == "normal"
    assert r.results[2].value_text == "Negative" and r.results[2].flag == "unknown"
    assert r.confidence == 0.8 and r.report_date == "2025-10-20"


def test_bad_or_future_dates_are_dropped():
    assert scan._clean_date("not a date") is None
    assert scan._clean_date((date.today() + timedelta(days=30)).isoformat()) is None
    assert scan._clean_date("1999-01-01") is None
    assert scan._clean_date("2025-10-20T08:00:00") == "2025-10-20"


def test_results_are_capped():
    raw = {"is_report": True, "results": [{"test": f"T{i}", "value": i} for i in range(200)], "confidence": 1}
    assert len(scan.parse_report(raw).results) == 60


def test_not_a_report_is_rejected(monkeypatch):
    script_llm(monkeypatch, [{"is_report": False, "results": []}])

    async def authorized():
        pass

    with pytest.raises(scan.ScanError):
        asyncio.run(scan.scan_report("A grocery list", authorize=authorized))


# ------------------------------------------------------------ endpoint
@pytest.fixture(autouse=True)
def overrides(monkeypatch):
    db = FakeDB()
    enable_test_ai(monkeypatch, db)
    main.app.dependency_overrides[main.current_user] = lambda: {"id": "user-1", "email": "t@example.com"}
    main.app.dependency_overrides[main.get_db] = lambda: db
    main._scan_counts.clear()
    yield
    main.app.dependency_overrides.clear()


def test_report_endpoint_success(monkeypatch):
    prompts = []
    script_llm(monkeypatch, [{
        "is_report": True,
        "report_type": "Lipid profile",
        "results": [
            {"test": "LDL cholesterol", "value": 4.1, "unit": "mmol/L", "ref_low": None, "ref_high": 3.0},
            {"test": "WBC", "value": 7400, "unit": "/uL", "reference_range": "4000 - 11000"},
        ],
        "confidence": 0.9,
    }], prompts)
    res = post_reviewed_text(TestClient(main.app), "report", REPORT_TEXT + "\nPhone: 4000 - 11000")
    assert res.status_code == 200
    d = res.json()["data"]
    assert d["needs_user_confirmation"] is True and d["report_type"] == "Lipid profile"
    assert d["results"][0]["flag"] == "high"
    assert prompts[0].count("4000 - 11000") == 1 and REPORT_TEXT in prompts[0]
    assert (d["results"][1]["ref_low"], d["results"][1]["ref_high"], d["results"][1]["flag"]) == (4000, 11000, "normal")


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
