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
from typing import Annotated, Literal

import httpx
from dotenv import load_dotenv
from fastapi import BackgroundTasks, Depends, FastAPI, File, Header, HTTPException, Query, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import AwareDatetime, BaseModel, Field, StringConstraints, model_validator

load_dotenv()

import agent  # noqa: E402  (after load_dotenv so env vars are set)
import llm  # noqa: E402
import notify  # noqa: E402
import reports  # noqa: E402
import rules  # noqa: E402
import safety  # noqa: E402
import scan  # noqa: E402
import tools  # noqa: E402
from db import DBError, UserDB  # noqa: E402

logging.basicConfig(level=logging.INFO)

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_PUBLISHABLE_KEY = os.environ.get("SUPABASE_PUBLISHABLE_KEY", "")

MAX_IMAGE_BYTES = 8 * 1024 * 1024
SCAN_DAILY_LIMIT = int(os.environ.get("SCAN_DAILY_LIMIT", "30"))
CHAT_DAILY_LIMIT = int(os.environ.get("CHAT_DAILY_LIMIT", "100"))

app = FastAPI(title="NOVA Health API", version="0.3.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in os.environ.get("ALLOWED_ORIGINS", "*").split(",") if o.strip()],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------
# Errors (match the API contract)
# ---------------------------------------------------------------
class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def _error_response(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": {"code": code, "message": message}})


@app.exception_handler(ApiError)
async def api_error_handler(_: Request, exc: ApiError):
    return _error_response(exc.status, exc.code, exc.message)


@app.exception_handler(HTTPException)
async def http_error_handler(_: Request, exc: HTTPException):
    code = {400: "INVALID_INPUT", 401: "UNAUTHORIZED", 403: "FORBIDDEN",
            404: "NOT_FOUND", 422: "INVALID_INPUT", 429: "RATE_LIMITED"}.get(exc.status_code, "SERVER_ERROR")
    return _error_response(exc.status_code, code, str(exc.detail))


@app.exception_handler(RequestValidationError)
async def validation_error_handler(_: Request, exc: RequestValidationError):
    first = exc.errors()[0] if exc.errors() else {}
    field = ".".join(str(x) for x in first.get("loc", []) if x != "body")
    return _error_response(422, "INVALID_INPUT", f"Invalid input{': ' + field if field else ''}.")


def llm_to_api_error(e: llm.LLMError) -> ApiError:
    code = "RATE_LIMITED" if e.status == 429 else "AI_UNAVAILABLE"
    return ApiError(e.status if e.status in (429, 503) else 502, code, e.message)


# ---------------------------------------------------------------
# Auth: ask Supabase who owns this token
# ---------------------------------------------------------------
async def current_user(authorization: str | None = Header(default=None)) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Missing bearer token")
    token = authorization.split(" ", 1)[1]
    async with httpx.AsyncClient(timeout=10) as client:
        res = await client.get(
            f"{SUPABASE_URL}/auth/v1/user",
            headers={"Authorization": f"Bearer {token}", "apikey": SUPABASE_PUBLISHABLE_KEY},
        )
    if res.status_code != 200:
        raise HTTPException(401, "Invalid or expired token")
    return res.json()  # contains "id" and "email"


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
    data = await upload.read(MAX_IMAGE_BYTES + 1)
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


@app.post("/api/v1/assistant/chat")
async def chat(body: ChatRequest, user: dict = Depends(current_user), db: UserDB = Depends(get_db)):
    message = body.message.strip()
    if not message:
        raise HTTPException(400, "message must not be empty")
    if len(message) > agent.MAX_QUESTION_CHARS:
        raise HTTPException(400, f"message is too long ({agent.MAX_QUESTION_CHARS} characters maximum)")

    # Emergency messages are never blocked by the daily limit.
    if safety.detect_emergency(message) is None:
        check_chat_quota(user["id"])

    history: list[dict] = []
    try:
        rows = await db.select("chat_messages", "role,content,created_at", order="created_at.desc", limit=6)
        history = list(reversed(rows))
    except Exception:  # noqa: BLE001  (no history is fine)
        pass

    try:
        result = await agent.run_agent(message, db, history=history)
    except llm.LLMError as e:
        raise llm_to_api_error(e)

    try:  # save the conversation for next time (best effort)
        await db.insert("chat_messages", {"user_id": user["id"], "role": "user", "content": message})
        await db.insert("chat_messages", {"user_id": user["id"], "role": "assistant", "content": result.reply[:4000]})
    except Exception:  # noqa: BLE001
        pass

    return {"data": {
        "reply": result.reply,
        "sources": result.sources,
        "warnings": [{"severity": w["severity"], "message": w["message"]} for w in result.warnings],
        "emergency": result.emergency,
    }}


@app.get("/api/v1/reports/daily")
async def daily_report(
    date_: date | None = Query(default=None, alias="date"),
    user: dict = Depends(current_user),
    db: UserDB = Depends(get_db),
):
    day = date_ or tools.local_today()
    try:
        data = await reports.daily_report(db, day)
    except DBError as e:
        raise ApiError(502, "SERVER_ERROR", e.message)
    return {"data": data}


@app.post("/api/v1/scan/prescription")
async def scan_prescription(
    image: UploadFile = File(...), user: dict = Depends(current_user), db: UserDB = Depends(get_db),
):
    data, mime = await read_image(image)
    check_scan_quota(user["id"])
    try:
        result = await scan.scan_prescription(data, mime)
    except scan.ScanError as e:
        raise ApiError(422, "SCAN_FAILED", str(e))
    except llm.LLMError as e:
        raise llm_to_api_error(e)
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
async def scan_report(image: UploadFile = File(...), user: dict = Depends(current_user)):
    """Reads a lab report photo into structured test results (a draft until the user confirms)."""
    data, mime = await read_image(image)
    check_scan_quota(user["id"])
    try:
        result = await scan.scan_report(data, mime)
    except scan.ScanError as e:
        raise ApiError(422, "SCAN_FAILED", str(e))
    except llm.LLMError as e:
        raise llm_to_api_error(e)
    return {"data": {
        "scan_id": str(uuid.uuid4()),
        "report_type": result.report_type,
        "report_date": result.report_date,
        "results": [r.model_dump() for r in result.results],
        "confidence": result.confidence,
        "notes": result.notes,
        "needs_user_confirmation": True,
    }}


@app.post("/api/v1/scan/food")
async def scan_food(image: UploadFile = File(...), user: dict = Depends(current_user)):
    data, mime = await read_image(image)
    check_scan_quota(user["id"])
    try:
        result = await scan.scan_food(data, mime)
    except scan.ScanError as e:
        raise ApiError(422, "SCAN_FAILED", str(e))
    except llm.LLMError as e:
        raise llm_to_api_error(e)
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
