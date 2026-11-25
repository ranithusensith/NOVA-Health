"""Backend tests. Run from backend/:  python -m pytest -q
The model is mocked, so no API key or internet is needed."""

from io import BytesIO

import pytest
from fastapi.testclient import TestClient
from PIL import Image

import llm  # noqa: E402
import main  # noqa: E402
import scan  # noqa: E402
import tools  # noqa: E402
from fakes import FakeDB, enable_test_ai, post_reviewed_text  # noqa: E402

JPEG = b"\xff\xd8\xff\xe0" + b"0" * 64
PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 64


@pytest.fixture(autouse=True)
def fake_user_and_reset(monkeypatch):
    db = FakeDB()
    enable_test_ai(monkeypatch, db)
    main.app.dependency_overrides[main.current_user] = lambda: {"id": "user-1", "email": "t@example.com"}
    main.app.dependency_overrides[main.get_db] = lambda: db
    main._scan_counts.clear()
    yield
    main.app.dependency_overrides.clear()


@pytest.fixture
def client():
    return TestClient(main.app)


def mock_llm(monkeypatch, payload=None, error=None):
    async def fake(*args, **kwargs):
        if error:
            raise error
        return payload

    monkeypatch.setattr(llm, "generate_json", fake)


def post_image(client, path, data=JPEG, name="photo.jpg"):
    return client.post(
        path, files={"image": (name, data, "application/octet-stream")},
        data={"reviewed": "true"} if path.endswith("/food") else None,
    )


@pytest.fixture
def meal_photo():
    with Image.new("RGB", (30, 30), "white") as image:
        output = BytesIO()
        image.save(output, "PNG")
    return output.getvalue()


# ------------------------------------------------------------ prescription
def test_prescription_success(client, monkeypatch):
    mock_llm(monkeypatch, {
        "is_prescription": True,
        "medications": [{"name": "Amoxicillin", "dosage": "500 mg", "frequency": "3 times a day",
                         "duration_days": "7 days", "instructions": "after meals"}],
        "confidence": 85,
        "notes": None,
    })
    res = post_reviewed_text(client, "prescription", "Amoxicillin 500 mg 3 times a day for 7 days")
    assert res.status_code == 200
    data = res.json()["data"]
    assert data["needs_user_confirmation"] is True
    assert data["confidence"] == 0.85  # percentage normalised
    med = data["medications"][0]
    assert med["name"] == "Amoxicillin" and med["duration_days"] == 7


def test_prescription_drops_bad_rows_keeps_good(client, monkeypatch):
    mock_llm(monkeypatch, {
        "is_prescription": True,
        "medications": [{"name": ""}, "junk", {"name": "Cetirizine", "duration_days": "abc"}],
        "confidence": 0.9,
    })
    res = post_reviewed_text(client, "prescription", "Amoxicillin 500 mg 3 times a day for 7 days")
    meds = res.json()["data"]["medications"]
    assert [m["name"] for m in meds] == ["Cetirizine"]
    assert meds[0]["duration_days"] is None


def test_not_a_prescription(client, monkeypatch):
    mock_llm(monkeypatch, {"is_prescription": False, "medications": [], "confidence": 0.2})
    res = post_reviewed_text(client, "prescription", "A grocery list")
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "SCAN_FAILED"


# ------------------------------------------------------------ food
def test_food_success_and_unknown_for_out_of_range_estimates(client, monkeypatch, meal_photo):
    mock_llm(monkeypatch, {"is_food": True, "description": "Rice and curry", "calories": 99999,
                           "protein_g": "20", "carbs_g": 90, "fat_g": -5, "confidence": 0.7})
    res = post_image(client, "/api/v1/scan/food", meal_photo, "meal.png")
    assert res.status_code == 200
    d = res.json()["data"]
    assert d["calories"] is None
    assert d["nutrients"] == {"protein_g": 20.0, "carbs_g": 90.0, "fat_g": None}


def test_food_not_food(client, monkeypatch, meal_photo):
    mock_llm(monkeypatch, {"is_food": False})
    assert post_image(client, "/api/v1/scan/food", meal_photo).status_code == 422


# ------------------------------------------------------------ input and errors
def test_rejects_non_image(client, monkeypatch):
    mock_llm(monkeypatch, {})
    res = post_image(client, "/api/v1/scan/medical-text", b"%PDF-1.4 not an image", "doc.pdf")
    assert res.status_code == 400
    assert res.json()["error"]["code"] == "INVALID_INPUT"


def test_rejects_huge_image(client, monkeypatch):
    mock_llm(monkeypatch, {})
    big = JPEG + b"0" * (main.MAX_IMAGE_BYTES + 10)
    assert post_image(client, "/api/v1/scan/medical-text", big).status_code == 400


def test_ai_not_configured(client, monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    res = post_reviewed_text(client, "prescription", "Amoxicillin 500 mg 3 times a day for 7 days")
    assert res.status_code == 503
    assert res.json()["error"]["code"] == "AI_PRIVACY_UNAVAILABLE"


def test_rate_limited_from_provider(client, monkeypatch, meal_photo):
    mock_llm(monkeypatch, error=llm.LLMError("busy", 429))
    res = post_image(client, "/api/v1/scan/food", meal_photo)
    assert res.status_code == 429
    assert res.json()["error"]["code"] == "RATE_LIMITED"


def test_daily_quota(client, monkeypatch, meal_photo):
    mock_llm(monkeypatch, {"is_food": True, "description": "Apple", "calories": 80, "confidence": 0.9})
    monkeypatch.setattr(main, "SCAN_DAILY_LIMIT", 2)
    assert post_image(client, "/api/v1/scan/food", meal_photo).status_code == 200
    assert post_image(client, "/api/v1/scan/food", meal_photo).status_code == 200
    third = post_image(client, "/api/v1/scan/food", meal_photo)
    assert third.status_code == 429 and third.json()["error"]["code"] == "RATE_LIMITED"


def test_requires_login():
    main.app.dependency_overrides.clear()
    res = TestClient(main.app).post("/api/v1/scan/food", files={"image": ("a.jpg", JPEG, "image/jpeg")})
    assert res.status_code == 401
    assert res.json()["error"]["code"] == "UNAUTHORIZED"


# ------------------------------------------------------------ llm helpers
def test_parse_json_text_handles_fences():
    assert llm.parse_json_text('```json\n{"a": 1}\n```') == {"a": 1}
    with pytest.raises(ValueError):
        llm.parse_json_text("[1, 2]")


def test_detect_image_mime():
    assert scan.detect_image_mime(JPEG) == "image/jpeg"
    assert scan.detect_image_mime(PNG) == "image/png"
    assert scan.detect_image_mime(b"RIFF\x00\x00\x00\x00WEBPVP8 ") == "image/webp"
    assert scan.detect_image_mime(b"hello") is None


# ------------------------------------------------------------ daily report date
def test_daily_report_uses_date_query_param(client):
    res = client.get("/api/v1/reports/daily?date=2026-10-20")
    assert res.status_code == 200
    assert res.json()["data"]["date"] == "2026-10-20"


def test_daily_report_defaults_to_today(client):
    res = client.get("/api/v1/reports/daily")
    assert res.status_code == 200
    assert res.json()["data"]["date"] == tools.local_today().isoformat()
