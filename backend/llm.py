"""
Thin Gemini client (REST) that returns parsed JSON.

All model calls in the backend go through generate_json(), so changing the
provider later means rewriting this one file.

Provider access requires explicit operator approval and current account consent.
"""

from collections.abc import Awaitable, Callable
import base64
import logging
import os
import re

import httpx

import ai_privacy
from upstream import decode_json

log = logging.getLogger("nova.llm")

# Token counts reported by the provider (read by the evaluation script to estimate cost).
USAGE: list[dict] = []

BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"


class LLMError(Exception):
    """Raised for any failure talking to the model. `status` is an HTTP-like code."""

    def __init__(self, message: str, status: int = 502, *, code: str = "AI_UNAVAILABLE"):
        super().__init__(message)
        self.message = message
        self.status = status
        self.code = code


class InvalidLLMResponse(LLMError):
    def __init__(self):
        super().__init__("The AI returned an unreadable answer. Try again.", code="AI_RESPONSE_INVALID")


def _extract_text(payload) -> str:
    candidates = payload.get("candidates") if isinstance(payload, dict) else None
    candidate = candidates[0] if isinstance(candidates, list) and candidates else None
    content = candidate.get("content") if isinstance(candidate, dict) else None
    parts = content.get("parts") if isinstance(content, dict) else None
    if not isinstance(parts, list) or not all(
        isinstance(part, dict) and isinstance(part.get("thought", False), bool) for part in parts
    ):
        raise ValueError("Invalid model response parts")
    texts = [part["text"] for part in parts if "text" in part and part.get("thought") is not True]
    if not texts or not all(isinstance(value, str) for value in texts):
        raise ValueError("Invalid model response text")
    return "".join(texts)


def parse_json_text(text: str) -> dict:
    """Parse model text into a JSON object, tolerating ```json fences."""
    cleaned = re.sub(r"^\s*```(?:json)?\s*|\s*```\s*$", "", text.strip())
    data = decode_json(cleaned)
    if not isinstance(data, dict):
        raise ValueError("model returned JSON that is not an object")
    return data


def _record_usage(usage) -> None:
    if not isinstance(usage, dict):
        return
    counts = [usage.get(key, 0) for key in ("promptTokenCount", "candidatesTokenCount", "thoughtsTokenCount")]
    if all(type(count) is int and count >= 0 for count in counts):
        USAGE.append({"in": counts[0], "out": counts[1] + counts[2]})
        del USAGE[:-2000]


def _credentials_rejected(response: httpx.Response) -> bool:
    if response.status_code in (401, 403):
        return True
    if response.status_code != 400:
        return False
    try:
        payload = decode_json(response.content)
    except ValueError:
        return False
    error = payload.get("error") if isinstance(payload, dict) else None
    details = error.get("details") if isinstance(error, dict) else None
    return isinstance(details, list) and any(
        isinstance(item, dict) and item.get("reason") == "API_KEY_INVALID" for item in details
    )


async def generate_json(
    prompt: str,
    *,
    food_image: bytes | None = None,
    authorize: Callable[[], Awaitable[None]] | None = None,
    system: str | None = None,
    retries: int = 1,
) -> dict:
    ai_privacy.require_provider()
    if authorize is None:
        raise ai_privacy.PrivacyError(403, "AI_CONSENT_REQUIRED", "Current AI consent is required.")
    api_key = os.environ.get("LLM_API_KEY", "").strip()
    model = os.environ.get("LLM_MODEL", "").strip()
    if any(not "!" <= char <= "~" for char in api_key):
        raise LLMError("Invalid AI provider credentials.", 503, code="AI_PROVIDER_AUTH_FAILED")

    parts: list[dict] = []
    if food_image is not None:
        clean = await ai_privacy.clean_food_image(food_image)
        parts.append({"inline_data": {"mime_type": "image/jpeg", "data": base64.b64encode(clean).decode()}})
    parts.append({"text": prompt})

    body: dict = {
        "contents": [{"role": "user", "parts": parts}],
        "generationConfig": {"responseMimeType": "application/json", "temperature": 0.1},
    }
    if system:
        body["system_instruction"] = {"parts": [{"text": system}]}

    url = f"{BASE_URL}/{model}:generateContent"
    headers = {"x-goog-api-key": api_key, "Content-Type": "application/json"}

    for _ in range(retries + 1):
        await authorize()
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(90.0), trust_env=False) as client:
                res = await client.post(url, headers=headers, json=body)
        except (httpx.HTTPError, httpx.InvalidURL):
            log.warning("LLM network error")
            raise LLMError("Could not reach the AI service.", 503) from None

        if res.status_code == 429:
            raise LLMError("The AI service is busy. Try again in a minute.", 429)
        if not 200 <= res.status_code < 300:
            log.warning("LLM request failed (HTTP %d)", res.status_code)
            if _credentials_rejected(res):
                raise LLMError("The AI provider rejected its credentials.", 503, code="AI_PROVIDER_AUTH_FAILED")
            if res.status_code == 408 or res.status_code >= 500:
                raise LLMError("The AI service is unavailable.", 503)
            raise LLMError("The AI provider rejected the request.", code="AI_REQUEST_REJECTED")

        try:
            payload = decode_json(res.content)
            usage = payload.get("usageMetadata") if isinstance(payload, dict) else None
            _record_usage(usage)
            return parse_json_text(_extract_text(payload))
        except ValueError:
            log.warning("LLM returned unreadable output")

    raise InvalidLLMResponse()
