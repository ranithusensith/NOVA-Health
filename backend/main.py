"""
NOVA Health backend (FastAPI), v0.3

Role: AI endpoints. Supabase handles auth, profile and tracking tables from the app.
Every endpoint returns the format from docs/architecture/api-contract.md:
  success -> {"data": ...}      error -> {"error": {"code": ..., "message": ...}}

The backend reads the user's data with the user's OWN token (see db.py), so
row-level security applies and no secret key is needed here.
"""

import asyncio
import hashlib
import json
import logging
import os
import time
import uuid
from dataclasses import dataclass, field
from datetime import date
from functools import partial
from typing import Annotated, Literal

import httpx
from dotenv import load_dotenv
from fastapi import BackgroundTasks, Depends, FastAPI, File, Form, Header, Query, Request, Response, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import AwareDatetime, BaseModel, Field, StrictBool, StringConstraints, model_validator
from starlette.exceptions import HTTPException

load_dotenv()

import ai_privacy  # noqa: E402
import agent  # noqa: E402  (after load_dotenv so env vars are set)
import lab_results  # noqa: E402
import llm  # noqa: E402
import notify  # noqa: E402
import reports  # noqa: E402
import rules  # noqa: E402
import safety  # noqa: E402
import scan  # noqa: E402
import tools  # noqa: E402
from db import DBError, InvalidDBResponse, UserDB  # noqa: E402
from upstream import decode_json  # noqa: E402

logging.basicConfig(level=logging.INFO)
# These libraries can log URLs, headers or parser fragments controlled by callers.
for sensitive_logger in (
    "httpx", "httpcore", "python_multipart", "python_multipart.multipart",
    "multipart", "multipart.multipart", "uvicorn.access",
):
    library_log = logging.getLogger(sensitive_logger)
    library_log.disabled = True
    library_log.propagate = False
    library_log.handlers[:] = [logging.NullHandler()]
error_log = logging.getLogger("nova.api")

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_PUBLISHABLE_KEY = os.environ.get("SUPABASE_PUBLISHABLE_KEY", "")

MAX_IMAGE_BYTES = 8 * 1024 * 1024
SCAN_DAILY_LIMIT = int(os.environ.get("SCAN_DAILY_LIMIT", "30"))
CHAT_DAILY_LIMIT = int(os.environ.get("CHAT_DAILY_LIMIT", "100"))

app = FastAPI(title="NOVA Health API", version="0.3.0")

# ---------------------------------------------------------------
# Errors (match the API contract)
# ---------------------------------------------------------------
class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def _error_response(status: int, code: str, message: str, *, headers=None) -> JSONResponse:
    response_headers = {**(headers or {}), "Cache-Control": "no-store"}
    if status == 401:
        response_headers["WWW-Authenticate"] = "Bearer"
    return JSONResponse(status_code=status, content={"error": {"code": code, "message": message}},
                        headers=response_headers)


@app.exception_handler(ApiError)
async def api_error_handler(_: Request, exc: ApiError):
    return _error_response(exc.status, exc.code, exc.message)


@app.exception_handler(ai_privacy.PrivacyError)
async def privacy_error_handler(_: Request, exc: ai_privacy.PrivacyError):
    return _error_response(exc.status, exc.code, str(exc))


@app.middleware("http")
async def safe_api_responses(request: Request, call_next):
    try:
        response = await call_next(request)
    except Exception:
        # Exception messages, tracebacks, request URLs and bodies may include patient data.
        error_log.error("API request failed unexpectedly")
        return _error_response(500, "SERVER_ERROR", "Could not process this request.")
    if request.url.path.startswith(("/api/v1/privacy/", "/api/v1/assistant/", "/api/v1/scan/")):
        response.headers["Cache-Control"] = "no-store"
    return response


app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in os.environ.get("ALLOWED_ORIGINS", "*").split(",") if o.strip()],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(HTTPException)
async def http_error_handler(_: Request, exc: HTTPException):
    code, message = {
        400: ("INVALID_INPUT", "Invalid request."),
        401: ("UNAUTHORIZED", "Sign in again."),
        403: ("FORBIDDEN", "Access is not allowed."),
        404: ("NOT_FOUND", "The requested resource was not found."),
        405: ("METHOD_NOT_ALLOWED", "This request method is not supported."),
        422: ("INVALID_INPUT", "Invalid input."),
        429: ("RATE_LIMITED", "Too many requests. Try again later."),
    }.get(exc.status_code, ("SERVER_ERROR", "Could not process this request.") if exc.status_code >= 500
          else ("INVALID_INPUT", "Invalid request."))
    headers = {key: value for key, value in (exc.headers or {}).items() if key.lower() in ("allow", "retry-after")}
    return _error_response(exc.status_code, code, message, headers=headers)


@app.exception_handler(RequestValidationError)
async def validation_error_handler(_: Request, exc: RequestValidationError):
    return _error_response(422, "INVALID_INPUT", "Invalid input.")


@app.exception_handler(llm.LLMError)
async def llm_error_handler(_: Request, exc: llm.LLMError):
    if exc.status == 429:
        return _error_response(429, "RATE_LIMITED", "The AI service is busy. Try again in a minute.")
    specific = {
        "AI_RESPONSE_INVALID": (502, "The AI returned an unreadable answer. Try again."),
        "AI_REQUEST_REJECTED": (502, "The AI service could not process this request. Try again later."),
        "AI_PROVIDER_AUTH_FAILED": (503, "The AI service is unavailable. Try again later."),
    }
    if exc.code in specific:
        status, message = specific[exc.code]
        return _error_response(status, exc.code, message)
    return _error_response(503, "AI_UNAVAILABLE", "The AI service is unavailable. Try again later.")


@app.exception_handler(DBError)
async def database_error_handler(_: Request, exc: DBError):
    if isinstance(exc, InvalidDBResponse):
        return _error_response(502, "DATABASE_RESPONSE_INVALID", "The database returned an unreadable response.")
    if exc.status == 401:
        return _error_response(401, "UNAUTHORIZED", "Sign in again.")
    if exc.status == 403:
        return _error_response(403, "FORBIDDEN", "Access is not allowed.")
    if exc.status == 502:
        return _error_response(502, "DATABASE_REQUEST_FAILED", "The database could not process this request.")
    return _error_response(503, "DATABASE_UNAVAILABLE", "The database is unavailable. Try again later.")


# ---------------------------------------------------------------
# Auth: ask Supabase who owns this token
# ---------------------------------------------------------------
async def current_user(authorization: str | None = Header(default=None)) -> dict:
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not token or any(not "!" <= char <= "~" for char in token):
        raise ApiError(401, "UNAUTHORIZED", "Sign in again.")
    if not SUPABASE_URL or not SUPABASE_PUBLISHABLE_KEY:
        raise ApiError(503, "AUTH_UNAVAILABLE", "Could not verify your session. Try again later.")
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            res = await client.get(
                f"{SUPABASE_URL}/auth/v1/user",
                headers={"Authorization": f"Bearer {token}", "apikey": SUPABASE_PUBLISHABLE_KEY},
            )
    except (httpx.HTTPError, httpx.InvalidURL, UnicodeError):
        raise ApiError(503, "AUTH_UNAVAILABLE", "Could not verify your session. Try again later.") from None
    if res.status_code in (400, 401, 403):
        raise ApiError(401, "UNAUTHORIZED", "Invalid or expired session. Sign in again.")
    if res.status_code != 200:
        raise ApiError(503, "AUTH_UNAVAILABLE", "Could not verify your session. Try again later.")
    try:
        user = decode_json(res.content)
        if not isinstance(user, dict) or not isinstance(user.get("id"), str):
            raise ValueError("Invalid account")
        user["id"] = str(uuid.UUID(user["id"]))
        for field, expected in (("email", str), ("phone", str), ("user_metadata", dict)):
            if user.get(field) is not None and not isinstance(user[field], expected):
                raise ValueError("Invalid account metadata")
    except ValueError:
        raise ApiError(502, "AUTH_RESPONSE_INVALID", "Could not verify your session. Try again later.") from None
    return user


async def get_db(
    user: dict = Depends(current_user),
    authorization: str | None = Header(default=None),
) -> UserDB:
    """Database access as the signed-in user (their own token, so row-level security applies)."""
    token = authorization.split(" ", 1)[1] if authorization and " " in authorization else ""
    return UserDB(token, user["id"])


# ---------------------------------------------------------------
# Daily quotas (protect the free AI tier; in memory, reset on restart)
# ---------------------------------------------------------------
_scan_counts: dict[tuple[str, str], int] = {}
_chat_counts: dict[tuple[str, str], int] = {}


def _check_quota(bucket: dict, user_id: str, limit: int, what: str) -> None:
    today = date.today().isoformat()
    for key in [k for k in bucket if k[1] != today]:
        del bucket[key]
    used = bucket.get((user_id, today), 0)
    if used >= limit:
        raise ApiError(429, "RATE_LIMITED", f"Daily {what} limit reached ({limit}). Try again tomorrow.")
    bucket[(user_id, today)] = used + 1


def check_scan_quota(user_id: str) -> None:
    _check_quota(_scan_counts, user_id, SCAN_DAILY_LIMIT, "scan")


def check_chat_quota(user_id: str) -> None:
    _check_quota(_chat_counts, user_id, CHAT_DAILY_LIMIT, "message")


async def read_image(upload: UploadFile) -> tuple[bytes, str]:
    try:
        data = await upload.read(MAX_IMAGE_BYTES + 1)
    finally:
        await upload.close()
    if len(data) > MAX_IMAGE_BYTES:
        raise ApiError(400, "INVALID_INPUT", "Image is too large (8 MB maximum).")
    mime = scan.detect_image_mime(data)
    if mime is None:
        raise ApiError(400, "INVALID_INPUT", "Upload a JPEG, PNG, or WebP image.")
    return data, mime


async def prescription_safety(db: UserDB, proposed: list[dict]) -> dict:
    """Check a prescription against the signed-in user's current health data."""
    try:
        allergies = (await tools.get_allergies(db, {}))["allergies"]
        profile = await db.select("profiles", "conditions", filters={"id": f"eq.{db.user_id}"}, limit=1)
        conditions = profile[0]["conditions"] if profile else None
        existing = (await tools.get_medications(db, {}))["medications"]
        if conditions is None:
            conditions = []
        if not isinstance(conditions, list):
            raise ValueError("Invalid conditions")
        warnings = [
            {"severity": w.severity, "message": w.message}
            for w in rules.check_all(proposed + existing, allergies, conditions)
        ]
    except Exception:  # noqa: BLE001  (any failed lookup or rule must prevent activation)
        return {"safety_check_status": "unavailable", "warnings": []}
    return {"safety_check_status": "completed" if profile else "unavailable", "warnings": warnings}


# ---------------------------------------------------------------
# Models
# ---------------------------------------------------------------
class ChatRequest(BaseModel):
    message: str
    reviewed: StrictBool = False
    emergency_only: StrictBool = False
    health_data: list[Literal["profile", "medications", "logs", "heart_rate", "cycle", "lab_results"]] = Field(
        default_factory=list, max_length=6,
    )
    recent_questions: list[Annotated[str, StringConstraints(max_length=400)]] = Field(default_factory=list, max_length=4)


class AIConsentRequest(BaseModel):
    enabled: StrictBool
    disclosure_version: str | None = Field(default=None, max_length=60)


class ReviewedMedicalText(BaseModel):
    text: str = Field(min_length=1, max_length=10_000)
    reviewed: StrictBool


class PrescriptionPlan(BaseModel):
    kind: Literal["daily", "interval", "as_needed", "unscheduled"]
    dosage_text: str | None = Field(default=None, max_length=60)
    frequency: str | None = Field(default=None, max_length=160)
    instructions: str | None = Field(default=None, max_length=500)
    duration_text: str | None = Field(default=None, max_length=80)
    interval_minutes: int | None = Field(default=None, strict=True, ge=1, le=525600)
    first_dose_at: AwareDatetime | None = None


class PrescriptionMedicationDraft(BaseModel):
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)]
    dosage: Annotated[str, StringConstraints(strip_whitespace=True, max_length=60)] | None = None
    times: list[Annotated[str, StringConstraints(pattern=r"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$")]] = Field(
        max_length=24,
    )
    start_date: date
    end_date: date | None
    prescription_plan: PrescriptionPlan
    reminders_enabled: bool = Field(strict=True)
    schedule_confirmed: bool = Field(strict=True)

    @model_validator(mode="after")
    def validate_schedule(self):
        plan = self.prescription_plan
        if not self.schedule_confirmed:
            raise ValueError("Confirm the schedule and course dates.")
        if self.end_date is not None and self.end_date < self.start_date:
            raise ValueError("The last day must be on or after the first day.")
        if plan.kind == "daily":
            if not self.times or len(set(self.times)) != len(self.times):
                raise ValueError("Choose distinct daily dose times.")
        elif self.times:
            raise ValueError("Only a daily schedule can have fixed dose times.")
        if plan.kind == "interval":
            if plan.interval_minutes is None or plan.first_dose_at is None:
                raise ValueError("Confirm the interval and first dose time.")
            if plan.first_dose_at.date() != self.start_date:
                raise ValueError("The first dose must be on the course start date.")
        elif plan.interval_minutes is not None or plan.first_dose_at is not None:
            raise ValueError("Only an interval schedule can have an interval and first dose time.")
        if self.reminders_enabled and plan.kind in ("as_needed", "unscheduled"):
            raise ValueError("Reminders require a scheduled dose.")
        return self


class PrescriptionConfirmation(BaseModel):
    scan_id: uuid.UUID
    medications: list[PrescriptionMedicationDraft] = Field(min_length=1, max_length=10)
    review_token: str | None = Field(default=None, pattern=r"^[0-9a-f]{64}$")


# ---------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------
@app.get("/health")
async def health():
    return {"data": {"status": "ok"}}


@app.get("/api/v1/me")
async def me(user: dict = Depends(current_user)):
    """Quick test that token checking works."""
    return {"data": {"id": user["id"], "email": user.get("email")}}


@app.get("/api/v1/privacy/ai")
async def ai_consent(db: UserDB = Depends(get_db)):
    return {"data": {
        "disclosure_version": ai_privacy.DISCLOSURE_VERSION,
        "provider_available": ai_privacy.provider_ready(),
        "enabled": await ai_privacy.has_consent(db),
    }}


@app.post("/api/v1/privacy/ai")
async def update_ai_consent(body: AIConsentRequest, db: UserDB = Depends(get_db)):
    if body.enabled:
        ai_privacy.require_provider()
        if body.disclosure_version != ai_privacy.DISCLOSURE_VERSION:
            raise ApiError(409, "AI_DISCLOSURE_OUTDATED", "Update the app to review the current AI disclosure.")
    try:
        await db.set_ai_consent(ai_privacy.DISCLOSURE_VERSION if body.enabled else None)
    except DBError:
        raise ApiError(503, "AI_PRIVACY_UNAVAILABLE", "AI consent could not be updated. Try again later.") from None
    return {"data": {"enabled": body.enabled}}


@app.delete("/api/v1/privacy/ai/chats")
async def delete_ai_chats(db: UserDB = Depends(get_db)):
    try:
        count = await db.delete_legacy_ai_chats()
    except DBError:
        raise ApiError(503, "CHAT_DELETION_UNVERIFIED", "Could not verify older chat deletion. Try again later.") from None
    return {"data": {"deleted": count}}


async def _known_identifiers(user: dict, db: UserDB) -> tuple[str, ...]:
    metadata = user.get("user_metadata")
    names = [user.get("email"), user.get("phone"), user.get("id")]
    if isinstance(metadata, dict):
        names.extend(metadata.get(key) for key in ("full_name", "name", "display_name"))
    try:
        profiles = await db.select("profiles", "full_name", filters={"id": f"eq.{db.user_id}"}, limit=1)
        if profiles:
            full_name = profiles[0].get("full_name")
            if full_name is not None and not isinstance(full_name, str):
                raise InvalidDBResponse()
            names.append(full_name)
    except (DBError, ValueError, AttributeError):
        raise ai_privacy.PrivacyError(
            503, "AI_PRIVACY_UNAVAILABLE", "Could not prepare your data for private processing. Try again later.",
        ) from None
    return tuple(name for name in names if isinstance(name, str) and 2 <= len(name.strip()) <= 300)


@app.post("/api/v1/assistant/chat")
async def chat(body: ChatRequest, user: dict = Depends(current_user), db: UserDB = Depends(get_db)):
    message = body.message.strip()
    if not message:
        raise ApiError(400, "INVALID_INPUT", "Message must not be empty.")
    if len(message) > agent.MAX_QUESTION_CHARS:
        raise ApiError(400, "INVALID_INPUT", f"Message is too long ({agent.MAX_QUESTION_CHARS} characters maximum).")

    emergency = safety.detect_emergency(message)
    saved = None
    if not emergency and body.reviewed and "logs" in body.health_data:
        saved = await tools.recent_saved_emergency(db)
    if emergency:
        # Local emergency advice must work without the external provider or consent.
        result = agent.AgentResult(reply=safety.emergency_reply(emergency, text=message), emergency=True)
    elif saved:
        kind, text = saved
        result = agent.AgentResult(reply=safety.saved_emergency_reply(kind, text=text),
                                   sources=["symptoms"], emergency=True)
    elif body.emergency_only:
        result = agent.AgentResult(reply="")
    else:
        await ai_privacy.require_consent(db)
        if not body.reviewed:
            raise ApiError(400, "REVIEW_REQUIRED", "Review this question before sharing it with Google Gemini.")
        check_chat_quota(user["id"])
        result = await agent.run_agent(
            message, db, history=[{"role": "user", "content": item} for item in body.recent_questions],
            health_data=set(body.health_data),
            identifiers=await _known_identifiers(user, db),
            authorize=partial(ai_privacy.require_consent, db),
        )

    return {"data": {
        "reply": result.reply,
        "sources": result.sources,
        "warnings": [{"severity": w["severity"], "message": w["message"]} for w in result.warnings],
        "emergency": result.emergency,
    }}


@app.get("/api/v1/reports/daily")
async def daily_report(
    response: Response,
    date_: date | None = Query(default=None, alias="date"),
    user: dict = Depends(current_user),
    db: UserDB = Depends(get_db),
):
    day = date_ or tools.local_today()
    if day in (date.min, date.max):
        raise ApiError(400, "INVALID_INPUT", "Select a date within the supported range.")
    data = await reports.daily_report(db, day)
    response.headers["Cache-Control"] = "no-store"
    return {"data": data}


@app.post("/api/v1/scan/medical-text")
async def extract_medical_text(
    image: UploadFile = File(...), user: dict = Depends(current_user), db: UserDB = Depends(get_db),
):
    await ai_privacy.require_consent(db)
    check_scan_quota(user["id"] + ":ocr")
    data, _ = await read_image(image)
    text = await ai_privacy.extract_medical_text(data)
    return {"data": {"text": safety.clinical_text(text, await _known_identifiers(user, db))[:10_000]}}


async def _reviewed_clinical_text(body: ReviewedMedicalText, user: dict, db: UserDB) -> tuple[str, tuple[str, ...]]:
    await ai_privacy.require_consent(db)
    if not body.reviewed:
        raise ApiError(400, "REVIEW_REQUIRED", "Review the text and remove identifying details before sharing it.")
    identifiers = await _known_identifiers(user, db)
    text = safety.clinical_text(body.text, identifiers)
    if not text or not any(char.isalpha() for char in text.replace("[redacted]", "")):
        raise ApiError(400, "INVALID_INPUT", "Enter the clinical details to scan.")
    check_scan_quota(user["id"])
    return text, identifiers


@app.post("/api/v1/scan/prescription")
async def scan_prescription(
    body: ReviewedMedicalText, user: dict = Depends(current_user), db: UserDB = Depends(get_db),
):
    text, identifiers = await _reviewed_clinical_text(body, user, db)
    try:
        result = await scan.scan_prescription(text, identifiers=identifiers, authorize=partial(ai_privacy.require_consent, db))
    except scan.ScanError:
        raise ApiError(422, "SCAN_FAILED", "We could not find a prescription in this photo. Try again with better light.") from None
    meds = [m.model_dump() for m in result.medications]
    safety_check = await prescription_safety(db, [{**m, "times": []} for m in meds])
    return {"data": {
        "scan_id": str(uuid.uuid4()),
        "is_prescription": True,
        "medications": meds,
        **safety_check,
        "confidence": result.confidence,
        "notes": result.notes,
        "needs_user_confirmation": True,  # the app must confirm before saving
    }}


@app.post("/api/v1/scan/prescription/confirm")
async def confirm_prescription(body: PrescriptionConfirmation, db: UserDB = Depends(get_db)):
    """Recheck the final draft and write the checked rows in one batch."""
    medications = [m.model_dump(mode="json", exclude={"schedule_confirmed"}) for m in body.medications]
    safety_check = await prescription_safety(db, medications)
    if safety_check["safety_check_status"] != "completed":
        return {"data": {**safety_check, "activated": False}}

    warnings = safety_check["warnings"]
    if warnings:
        # Bind the acknowledgement to this account, the exact draft and the current warnings.
        review = json.dumps(
            [db.user_id, str(body.scan_id), medications,
             sorted(warnings, key=lambda warning: (warning["severity"], warning["message"]))],
            sort_keys=True,
        )
        review_token = hashlib.sha256(review.encode()).hexdigest()
        if body.review_token != review_token:
            return {"data": {**safety_check, "activated": False, "review_token": review_token}}

    rows = [
        {
            **medication,
            # The same scan cannot create a duplicate batch if the response is lost.
            "id": str(uuid.uuid5(body.scan_id, f"nova-prescription:{db.user_id}:{index}")),
            "user_id": db.user_id,
            "source": "scan",
            "status": "confirmed",
        }
        for index, medication in enumerate(medications)
    ]
    try:
        await db.insert("medications", rows)
    except DBError as e:
        raise ApiError(
            502, "PRESCRIPTION_SAVE_UNVERIFIED",
            "Could not verify that the prescription was saved. Check Medications before trying again.",
        ) from e
    return {"data": {**safety_check, "activated": True}}


@app.post("/api/v1/scan/report")
async def scan_report(
    body: ReviewedMedicalText, user: dict = Depends(current_user), db: UserDB = Depends(get_db),
):
    text, identifiers = await _reviewed_clinical_text(body, user, db)
    try:
        result = await scan.scan_report(
            text, identifiers=identifiers, today=tools.local_today(),
            authorize=partial(ai_privacy.require_consent, db),
        )
    except scan.ScanError:
        raise ApiError(422, "SCAN_FAILED", "We could not find lab results in this photo. Use good light and keep the whole table in view.") from None
    return {"data": {
        "scan_id": str(uuid.uuid4()),
        "report_type": result.report_type,
        "report_date": result.report_date,
        "results": [r.model_dump() for r in result.results],
        "confidence": result.confidence,
        "notes": result.notes,
        "needs_user_confirmation": True,
    }}


@app.post("/api/v1/scan/report/confirm")
async def confirm_lab_report(body: lab_results.ReviewedLabReport, db: UserDB = Depends(get_db)):
    if str(body.expected_user_id) != db.user_id:
        raise ApiError(403, "FORBIDDEN", "Sign in to the account that opened this report.")
    if not body.reviewed:
        raise ApiError(400, "REVIEW_REQUIRED", "Check the results against your report before saving.")
    date_text = lab_results.report_date(body.report_date, tools.local_today())
    if body.report_date is not None and date_text is None:
        raise ApiError(400, "INVALID_INPUT", "Use a valid report date or leave it unknown.")
    rows = [
        {
            **row.database_row(user_id=db.user_id, date_text=date_text, report_type=body.report_type),
            # One atomic insert with stable IDs prevents duplicate batches on retry.
            "id": str(uuid.uuid5(body.scan_id, f"nova-lab:{db.user_id}:{index}")),
        }
        for index, row in enumerate(body.results)
    ]
    try:
        await db.insert("lab_results", rows)
    except DBError:
        raise ApiError(
            502, "LAB_SAVE_UNVERIFIED",
            "Could not verify the save. Check Medical records before trying again.",
        ) from None
    return {"data": {"saved": len(rows)}}


@app.post("/api/v1/scan/food")
async def scan_food(
    image: UploadFile = File(...), reviewed: bool = Form(False),
    user: dict = Depends(current_user), db: UserDB = Depends(get_db),
):
    await ai_privacy.require_consent(db)
    if not reviewed:
        raise ApiError(400, "REVIEW_REQUIRED", "Review the food photo before sharing it.")
    data, _ = await read_image(image)
    check_scan_quota(user["id"])
    try:
        result = await scan.scan_food(data, authorize=partial(ai_privacy.require_consent, db))
    except scan.ScanError:
        raise ApiError(422, "SCAN_FAILED", "We could not find food in this photo. Try again with the whole plate in view.") from None
    return {"data": {
        "scan_id": str(uuid.uuid4()),
        "description": result.description,
        "calories": result.calories,
        "nutrients": {"protein_g": result.protein_g, "carbs_g": result.carbs_g, "fat_g": result.fat_g},
        "confidence": result.confidence,
        "needs_user_confirmation": True,
    }}


SOS_COOLDOWN_SECONDS = 30
SOS_STATUS_TTL_SECONDS = 30 * 60
_sos_last: dict[str, float] = {}
_sos_sending: set[str] = set()


@dataclass
class _SosAttempt:
    id: uuid.UUID
    expires_at: float
    report: notify.SendReport
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)


_sos_attempts: dict[str, _SosAttempt] = {}


def _prune_sos(now: float) -> None:
    for user_id in [key for key, attempt in _sos_attempts.items() if attempt.expires_at <= now]:
        del _sos_attempts[user_id]
    for user_id in [key for key, started in _sos_last.items() if now - started >= SOS_COOLDOWN_SECONDS]:
        del _sos_last[user_id]


class EmergencyBody(BaseModel):
    note: str | None = Field(default=None, max_length=200)


@app.post("/api/v1/emergency/trigger")
async def emergency_trigger(
    background: BackgroundTasks, body: EmergencyBody | None = None,
    user: dict = Depends(current_user), db: UserDB = Depends(get_db),
):
    """Submit an SOS and report only the provider states known at this point."""
    now = time.monotonic()
    _prune_sos(now)
    user_id = user["id"]
    if user_id in _sos_sending or user_id in _sos_last:
        raise ApiError(429, "RATE_LIMITED", "An SOS was recently requested. Check its status or call 1990 now.")
    _sos_sending.add(user_id)
    try:
        data = await _submit_sos(db, user_id, body)
    finally:
        _sos_sending.discard(user_id)
    background.add_task(_audit_sos, db, user_id, data["contacts_total"], data["status"])
    return {"data": data}


async def _submit_sos(db: UserDB, user_id: str, body: EmergencyBody | None) -> dict:
    try:
        contacts = await asyncio.wait_for(
            db.select("emergency_contacts", "id,phone", filters={"user_id": f"eq.{db.user_id}"}), timeout=4,
        )
    except (DBError, ValueError, TimeoutError) as e:
        raise ApiError(502, "SOS_UNAVAILABLE", "Could not read your emergency contacts. Call 1990 or your contacts directly.") from e

    mode = notify.provider()
    if not contacts:
        return notify.SendReport(mode, []).payload()

    name = None
    if mode == "twilio":
        try:
            profile = await asyncio.wait_for(
                db.select("profiles", "full_name", filters={"id": f"eq.{db.user_id}"}, limit=1), timeout=2,
            )
            name = profile[0].get("full_name") if profile else None
        except (DBError, ValueError, TimeoutError):
            pass  # The alert can still use the generic message.
    _sos_last[user_id] = time.monotonic()
    report = await notify.send_sos(contacts, notify.build_message(name, body.note if body else None), mode=mode)
    data = report.payload()
    now = time.monotonic()
    _sos_last[user_id] = now
    if report.can_refresh:
        attempt = _SosAttempt(uuid.uuid4(), now + SOS_STATUS_TTL_SECONDS, report)
        _sos_attempts[user_id] = attempt
        data["attempt_id"] = str(attempt.id)
    return data


async def _audit_sos(db: UserDB, user_id: str, count: int, status: str) -> None:
    try:
        await db.insert("audit_log", {
            "user_id": user_id,
            "action": "sos_triggered",
            "detail": {"contacts": count, "status": status, "provider": notify.provider()},
        })
    except DBError:
        pass
    except Exception:
        # This task runs after the response. Never propagate its exception to ASGI logging.
        error_log.error("SOS audit could not be recorded")


@app.get("/api/v1/emergency/{attempt_id}/status")
async def emergency_status(attempt_id: uuid.UUID, user: dict = Depends(current_user)):
    _prune_sos(time.monotonic())
    attempt = _sos_attempts.get(user["id"])
    if attempt is None or attempt.id != attempt_id:
        raise ApiError(404, "SOS_STATUS_UNAVAILABLE", "Delivery status is unavailable for this SOS.")
    async with attempt.lock:
        refreshed = await notify.refresh_delivery(attempt.report)
        return {"data": {
            **attempt.report.payload(),
            "attempt_id": str(attempt.id),
            "status_check_unavailable": not refreshed,
        }}
