"""External AI privacy gate and local image preparation."""

import asyncio
from io import BytesIO
import os
import re
import subprocess

from PIL import Image, ImageOps, UnidentifiedImageError

import safety

DISCLOSURE_VERSION = "gemini-health-v1"
_PROVIDER_APPROVAL = "gemini-reviewed-paid"
_MAX_PIXELS = 8_000_000
_MAX_EDGE = 3200
_MAX_TEXT = 10_000
_image_slots = asyncio.Semaphore(2)


class PrivacyError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def provider_ready() -> bool:
    return (
        os.environ.get("AI_PRIVACY_PROVIDER_APPROVAL") == _PROVIDER_APPROVAL
        and bool(os.environ.get("LLM_API_KEY", "").strip())
        and re.fullmatch(r"[A-Za-z0-9_.-]+", os.environ.get("LLM_MODEL", "").strip()) is not None
    )


def require_provider() -> None:
    if not provider_ready():
        raise PrivacyError(503, "AI_PRIVACY_UNAVAILABLE", "External AI is disabled on this server.")


async def has_consent(db) -> bool:
    try:
        rows = await db.select(
            "ai_processing_consents", "disclosure_version",
            filters={"user_id": f"eq.{db.user_id}"}, limit=1,
        )
        return bool(rows) and rows[0].get("disclosure_version") == DISCLOSURE_VERSION
    except Exception:
        raise PrivacyError(
            503, "AI_PRIVACY_UNAVAILABLE", "AI consent could not be verified. Try again later.",
        ) from None


async def require_consent(db) -> None:
    require_provider()
    if not await has_consent(db):
        raise PrivacyError(
            403, "AI_CONSENT_REQUIRED", "Review and enable Google Gemini processing in Privacy and consent.",
        )


def _clean_image(data: bytes, *, food: bool) -> bytes:
    try:
        with Image.open(BytesIO(data), formats=("JPEG", "PNG", "WEBP")) as source:
            width, height = source.size
            if width * height > _MAX_PIXELS or max(width, height) > _MAX_EDGE:
                raise PrivacyError(400, "INVALID_INPUT", "Image dimensions are too large.")
            if getattr(source, "is_animated", False):
                raise PrivacyError(400, "INVALID_INPUT", "Upload a single still image.")
            oriented = ImageOps.exif_transpose(source).convert("RGBA")
            # Fresh pixel canvas drops EXIF, GPS, ICC, XMP and PNG text chunks.
            clean = Image.new("RGB", oriented.size, "white")
            clean.paste(oriented, mask=oriented.getchannel("A"))
            if food:
                clean.thumbnail((1280, 1280))
            output = BytesIO()
            clean.save(output, format="JPEG" if food else "PNG", quality=88)
            return output.getvalue()
    except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError, SyntaxError):
        raise PrivacyError(400, "INVALID_INPUT", "The image could not be read.") from None


def _review_food_image(data: bytes) -> bytes:
    clean = _clean_image(data, food=True)
    try:
        text = _ocr_text(clean)
    except PrivacyError:
        raise PrivacyError(503, "OCR_UNAVAILABLE", "The food photo could not be checked for identifying text.") from None
    if safety.redact(text) != text or any(safety.is_identity_line(line) for line in text.splitlines()):
        raise PrivacyError(400, "REVIEW_REQUIRED", "Identifying text may be visible. Take a photo of the food alone.")
    return clean


async def clean_food_image(data: bytes) -> bytes:
    async with _image_slots:
        return await asyncio.to_thread(_review_food_image, data)


def _ocr_text(clean: bytes) -> str:
    try:
        result = subprocess.run(
            ["tesseract", "stdin", "stdout", "-l", "eng"],
            input=clean, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=15, check=True,
            env={"PATH": os.environ.get("PATH", os.defpath), "OMP_THREAD_LIMIT": "1"},
        )
    except (OSError, subprocess.SubprocessError):
        raise PrivacyError(
            503, "OCR_UNAVAILABLE", "Private text extraction is unavailable. You can enter the clinical text manually.",
        ) from None
    return result.stdout.decode("utf-8", errors="replace")[:_MAX_TEXT]


def _extract_text(data: bytes) -> str:
    return _ocr_text(_clean_image(data, food=False))


async def extract_medical_text(data: bytes) -> str:
    async with _image_slots:
        return await asyncio.to_thread(_extract_text, data)
