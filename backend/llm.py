"""
Thin Gemini client (REST) that returns parsed JSON.

All model calls in the backend go through generate_json(), so changing the
provider later means rewriting this one file.

Provider access requires explicit operator approval and current account consent.
"""

from collections.abc import Awaitable, Callable
import base64
import json
import logging
import os
import re

import httpx

import ai_privacy

log = logging.getLogger("nova.llm")

# Token counts reported by the provider (read by the evaluation script to estimate cost).
USAGE: list[dict] = []

BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"


class LLMError(Exception):
    """Raised for any failure talking to the model. `status` is an HTTP-like code."""

    def __init__(self, message: str, status: int = 502):
        super().__init__(message)
        self.message = message
        self.status = status


def _extract_text(payload: dict) -> str:
    try:
        parts = payload["candidates"][0]["content"]["parts"]
    except (KeyError, IndexError, TypeError) as e:
        raise ValueError("response has no candidates") from e
    texts = [p["text"] for p in parts if isinstance(p, dict) and "text" in p and not p.get("thought")]
    if not texts:
        raise ValueError("response has no text")
    return texts[-1]


def parse_json_text(text: str) -> dict:
    """Parse model text into a JSON object, tolerating ```json fences."""
    cleaned = re.sub(r"^\s*```(?:json)?\s*|\s*```\s*$", "", text.strip())
    data = json.loads(cleaned)  # json.JSONDecodeError is a ValueError
    if not isinstance(data, dict):
        raise ValueError("model returned JSON that is not an object")
    return data


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
        except httpx.HTTPError:
            log.warning("LLM network error")
            raise LLMError("Could not reach the AI service.", 502) from None

        if res.status_code == 429:
            raise LLMError("The AI service is busy. Try again in a minute.", 429)
        if not 200 <= res.status_code < 300:
            log.warning("LLM request failed (HTTP %d)", res.status_code)
            raise LLMError("The AI service could not process the request.", 502)

        try:
            payload = res.json()
            usage = payload.get("usageMetadata") if isinstance(payload, dict) else None
            if isinstance(usage, dict):
                USAGE.append({
                    "in": int(usage.get("promptTokenCount") or 0),
                    "out": int(usage.get("candidatesTokenCount") or 0) + int(usage.get("thoughtsTokenCount") or 0),
                })
                del USAGE[:-2000]
            return parse_json_text(_extract_text(payload))
        except (ValueError, TypeError, AttributeError):
            log.warning("LLM returned unreadable output")

    raise LLMError("The AI returned an unreadable answer. Try again.", 502)
