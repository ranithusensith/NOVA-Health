"""
Thin Gemini client (REST) that returns parsed JSON.

All model calls in the backend go through generate_json(), so changing the
provider later means rewriting this one file.

PRIVACY: free API tiers may use prompts for training. Send fake or minimal
data only, and never include names or ID numbers in a prompt.
"""

import base64
import json
import logging
import os
import re

import httpx

log = logging.getLogger("nova.llm")

# Token counts reported by the provider (read by the evaluation script to estimate cost).
USAGE: list[dict] = []

BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"
DEFAULT_MODEL = "gemini-3.5-flash"  # override with LLM_MODEL in .env


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
    image: bytes | None = None,
    mime: str = "image/jpeg",
    system: str | None = None,
    retries: int = 1,
) -> dict:
    api_key = os.environ.get("LLM_API_KEY", "").strip()
    if not api_key:
        raise LLMError("AI is not configured on the server.", 503)
    model = os.environ.get("LLM_MODEL", DEFAULT_MODEL).strip() or DEFAULT_MODEL

    parts: list[dict] = []
    if image is not None:
        parts.append({"inline_data": {"mime_type": mime, "data": base64.b64encode(image).decode()}})
    parts.append({"text": prompt})

    body: dict = {
        "contents": [{"role": "user", "parts": parts}],
        "generationConfig": {"responseMimeType": "application/json", "temperature": 0.1},
    }
    if system:
        body["system_instruction"] = {"parts": [{"text": system}]}

    url = f"{BASE_URL}/{model}:generateContent"
    headers = {"x-goog-api-key": api_key, "Content-Type": "application/json"}

    last_error: Exception | None = None
    for _ in range(retries + 1):
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(180.0)) as client:
                res = await client.post(url, headers=headers, json=body)
        except httpx.HTTPError as e:
            log.warning("LLM network error: %s", type(e).__name__)
            raise LLMError("Could not reach the AI service.", 502) from e

        if res.status_code == 429:
            raise LLMError("The AI service is busy. Try again in a minute.", 429)
        if res.status_code in (400, 401, 403, 404):
            log.error("LLM rejected request (%s): %s", res.status_code, res.text[:300])
            raise LLMError("The AI service rejected the request. Check LLM_API_KEY and LLM_MODEL.", 502)
        if res.status_code >= 400:
            log.error("LLM error %s: %s", res.status_code, res.text[:300])
            raise LLMError(f"AI service error ({res.status_code}).", 502)

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
        except ValueError as e:
            last_error = e
            log.warning("LLM returned unreadable output: %s", e)

    raise LLMError("The AI returned an unreadable answer. Try again.", 502) from last_error
