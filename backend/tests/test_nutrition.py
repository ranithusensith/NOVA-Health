import asyncio
from datetime import date

import pytest

import daily_metrics
import nutrition
import reports
import scan
from fakes import FakeDB


@pytest.mark.parametrize("invalid", [-1, float("nan"), float("inf"), "12 g", "1e2",
                                     "3.14", 501, True, [], "0.00000000000000000001"])
def test_invalid_estimates_are_unknown(invalid):
    assert scan.parse_food({"protein_g": invalid}).protein_g is None


def test_well_formed_estimates_preserve_zero_and_decimal_values():
    result = scan.parse_food({"calories": 0, "protein_g": "12,4", "carbs_g": 800, "fat_g": 5.1})
    assert (result.calories, result.protein_g, result.carbs_g, result.fat_g) == (0, 12.4, 800, 5.1)
    assert scan.parse_food({"calories": 1.5}).calories is None


def test_confirmed_corrections_flow_to_daily_report_and_missing_fields_stay_unknown():
    meals = [
        {"calories": 420, "nutrients": {"protein_g": 12.4, "carbs_g": 0, "fat_g": None}},
        {"calories": 0, "nutrients": {"protein_g": 0.2, "carbs_g": 33.5, "fat_g": 6}},
    ]
    db = FakeDB({"meal_logs": meals})
    day = date(2025, 9, 23)
    result = asyncio.run(reports.daily_report(db, day, bounds=daily_metrics.day_window(day, (0, 0))))
    assert ("meal_logs", "calories,nutrients,logged_at", {
        "and": "(logged_at.gte.2025-09-23T00:00:00+00:00,logged_at.lt.2025-09-24T00:00:00+00:00)",
        "status": "eq.confirmed",
    }) in db.selects
    assert {"Meals: 2 logged, about 420 kcal", "Protein: 12.6 g estimated",
            "Carbs: 33.5 g estimated", "Fat: unknown"}.issubset(result["highlights"])
    assert nutrition.total(meals + [{"calories": 5001}], "calories") is None
    assert nutrition.total(meals + [{"nutrients": {"protein_g": "12"}}], "protein_g") is None
    assert nutrition.total([], "calories") is None
