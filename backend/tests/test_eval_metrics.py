import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from eval import metrics as m  # noqa: E402


def test_similar_names():
    assert m.similar("Haemoglobin", "Hemoglobin")
    assert m.similar("Amoxicillin", "amoxicillin ")
    assert not m.similar("Cetirizine", "Paracetamol")
    assert not m.similar("", "x")


def test_times_per_day():
    assert m.times_per_day("3 times a day") == 3
    assert m.times_per_day("three times daily") == 3
    assert m.times_per_day("twice a day") == 2
    assert m.times_per_day("every 8 hours") == 3
    assert m.times_per_day("every 6-8 hours") == 4
    assert m.times_per_day("1 tablet at night") == 1
    assert m.times_per_day("once daily") == 1
    assert m.times_per_day("as needed") is None
    assert m.times_per_day(None) is None


def test_same_number_and_text():
    assert m.same_number(11.2, 11.2) and m.same_number(7400, 7400.0)
    assert not m.same_number(11.2, 12.0)
    assert m.same_number(None, None) and not m.same_number(None, 1)
    assert m.same_text("500 mg", "500mg") and not m.same_text("250 mg", "500 mg")


def test_prf():
    assert m.prf(6, 0, 0) == (1.0, 1.0, 1.0)
    p, r, f = m.prf(3, 3, 1)
    assert round(p, 2) == 0.75 and round(r, 2) == 0.5 and round(f, 2) == 0.6
    assert m.prf(0, 0, 0)[0] == 1.0


def test_prescription_scoring():
    expected = [{"name": "Amoxicillin", "dosage": "500 mg", "times_per_day": 3, "duration_days": 7}]
    perfect = [{"name": "amoxicillin", "dosage": "500mg", "frequency": "3 times a day", "duration_days": 7}]
    s = m.score_prescription(expected, perfect)
    assert (s["tp"], s["fn"], s["fp"], s["dosage"], s["frequency"], s["duration"]) == (1, 0, 0, 1, 1, 1)
    wrong = [{"name": "Amoxicillin", "dosage": "250 mg", "frequency": "twice a day", "duration_days": 14},
             {"name": "Extra drug"}]
    s = m.score_prescription(expected, wrong)
    assert (s["tp"], s["fp"], s["dosage"], s["frequency"], s["duration"]) == (1, 1, 0, 0, 0)
    assert m.score_prescription(expected, [])["fn"] == 1


def test_report_scoring():
    expected = [{"test": "Haemoglobin", "value": 11.2, "unit": "g/dL", "ref_low": 13.0, "ref_high": 17.0, "flag": "low"},
                {"test": "Urine protein", "value": None, "value_text": "Negative", "unit": None,
                 "ref_low": None, "ref_high": None, "flag": "unknown"}]
    got = [{"test": "Hemoglobin", "value": 11.2, "unit": "g/dL", "ref_low": 13.0, "ref_high": 17.0, "flag": "low"},
           {"test": "Urine protein", "value": None, "value_text": "negative", "unit": None, "ref_low": None,
            "ref_high": None, "flag": "unknown"}]
    s = m.score_report(expected, got)
    assert (s["tp"], s["value"], s["unit"], s["range"], s["flag"]) == (2, 2, 2, 2, 2)
    got[0]["flag"] = "normal"
    assert m.score_report(expected, got)["flag"] == 1


def test_percentile_and_mean_sd():
    assert m.percentile([1, 2, 3, 4, 5], 0.5) == 3
    assert m.percentile([], 0.5) == 0.0
    mean, sd = m.mean_sd([1.0, 1.0])
    assert mean == 1.0 and sd == 0.0
