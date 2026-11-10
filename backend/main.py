"""
NOVA Health backend (FastAPI), v0.2

Role: AI endpoints only. Supabase handles auth, profile, and tracking tables.
Every endpoint returns the format from docs/architecture/api-contract.md:
  success -> {"data": ...}      error -> {"error": {"code": ..., "message": ...}}
"""

import logging
import os
import uuid
from datetime import date

import httpx
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Header, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel

load_dotenv()

import llm  # noqa: E402  (after load_dotenv so env vars are set)
import scan  # noqa: E402

logging.basicConfig(level=logging.INFO)

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_PUBLISHABLE_KEY = os.environ.get("SUPABASE_PUBLISHABLE_KEY", "")
DISCLAIMER = "This is guidance, not medical advice."

MAX_IMAGE_BYTES = 8 * 1024 * 1024
SCAN_DAILY_LIMIT = int(os.environ.get("SCAN_DAILY_LIMIT", "30"))

app = FastAPI(title="NOVA Health API", version="0.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # tighten before the final demo
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


# ---------------------------------------------------------------
# Scan helpers: image validation and a per-user daily quota
# (the quota protects the free API tier; in-memory, resets on restart)
# ---------------------------------------------------------------
_scan_counts: dict[tuple[str, str], int] = {}


def check_scan_quota(user_id: str) -> None:
    today = date.today().isoformat()
    for key in [k for k in _scan_counts if k[1] != today]:
        del _scan_counts[key]
    used = _scan_counts.get((user_id, today), 0)
    if used >= SCAN_DAILY_LIMIT:
        raise ApiError(429, "RATE_LIMITED", f"Daily scan limit reached ({SCAN_DAILY_LIMIT}). Try again tomorrow.")
    _scan_counts[(user_id, today)] = used + 1


async def read_image(upload: UploadFile) -> tuple[bytes, str]:
    data = await upload.read(MAX_IMAGE_BYTES + 1)
    if len(data) > MAX_IMAGE_BYTES:
        raise ApiError(400, "INVALID_INPUT", "Image is too large (8 MB maximum).")
    mime = scan.detect_image_mime(data)
    if mime is None:
        raise ApiError(400, "INVALID_INPUT", "Upload a JPEG, PNG, or WebP image.")
    return data, mime


# ---------------------------------------------------------------
# Models
# ---------------------------------------------------------------
class ChatRequest(BaseModel):
    message: str


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
async def chat(body: ChatRequest, user: dict = Depends(current_user)):
    if not body.message.strip():
        raise HTTPException(400, "message must not be empty")
    # TODO (next step): replace with the agent in ai-engine/engine.py
    reply = ("Your sleep averaged about 5.5 hours and water intake was low on several "
             "days. Try going to bed earlier and drinking more water.")
    return {"data": {"reply": f"{reply}\n\n{DISCLAIMER}", "sources": ["sleep", "water"]}}


@app.get("/api/v1/reports/daily")
async def daily_report(date_: date | None = None, user: dict = Depends(current_user)):
    # TODO: replace with engine.generate_daily_report(user["id"], date_)
    return {"data": {"date": (date_ or date.today()).isoformat(),
                     "report": f"Sample report: sleep was short and water was low today.\n\n{DISCLAIMER}"}}


@app.post("/api/v1/scan/prescription")
async def scan_prescription(image: UploadFile = File(...), user: dict = Depends(current_user)):
    data, mime = await read_image(image)
    check_scan_quota(user["id"])
    try:
        result = await scan.scan_prescription(data, mime)
    except scan.ScanError as e:
        raise ApiError(422, "SCAN_FAILED", str(e))
    except llm.LLMError as e:
        raise llm_to_api_error(e)
    return {"data": {
        "scan_id": str(uuid.uuid4()),
        "is_prescription": True,
        "medications": [m.model_dump() for m in result.medications],
        "confidence": result.confidence,
        "notes": result.notes,
        "needs_user_confirmation": True,  # the app must confirm before saving
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


@app.post("/api/v1/emergency/trigger")
async def emergency_trigger(user: dict = Depends(current_user)):
    # TODO: notify emergency contacts (push/SMS) and log in audit_log
    return {"data": {"status": "triggered", "contacts_notified": 0}}
