"""
Sends the SOS text message to a user's emergency contacts.

Providers (set NOTIFY_PROVIDER in .env):
  log     (default) Writes the message to the server log only. Nothing is sent.
          The app then opens the phone's own messages app with the text ready to send.
  twilio  Sends real SMS through Twilio. Needs TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM.

No health data is ever put in the message: only the user's name and a request for help.
"""

import logging
import os
import re
from dataclasses import dataclass, field

import httpx

log = logging.getLogger("nova.notify")

DEFAULT_COUNTRY_CODE = os.environ.get("DEFAULT_COUNTRY_CODE", "94")  # Sri Lanka


def provider() -> str:
    return os.environ.get("NOTIFY_PROVIDER", "log").strip().lower() or "log"


def normalize_phone(raw: str) -> str | None:
    """'+94 77 123 4567', '077-123-4567' or '94771234567' -> '+94771234567'. None when it is not a phone number."""
    text = (raw or "").strip()
    plus = text.startswith("+")
    digits = re.sub(r"\D", "", text)
    if not digits:
        return None
    if plus:
        pass
    elif digits.startswith("00"):
        digits = digits[2:]
    elif digits.startswith("0"):
        digits = DEFAULT_COUNTRY_CODE + digits[1:]
    elif not digits.startswith(DEFAULT_COUNTRY_CODE):
        digits = DEFAULT_COUNTRY_CODE + digits
    if not 9 <= len(digits) <= 15:
        return None
    return "+" + digits


def build_message(name: str | None, note: str | None = None) -> str:
    who = (name or "").strip() or "A NOVA Health user"
    text = f"NOVA Health SOS: {who} needs help. Please call them or go to them now."
    note = (note or "").strip()
    if note:
        text += f" Note: {note[:200]}"
    return text


@dataclass
class SendReport:
    total: int = 0
    sent: int = 0
    simulated: bool = False
    failed: list[str] = field(default_factory=list)  # contact names


async def _twilio_post(url: str, auth: tuple[str, str], data: dict) -> int:
    async with httpx.AsyncClient(timeout=15) as client:
        res = await client.post(url, auth=auth, data=data)
    return res.status_code


async def send_sos(contacts: list[dict], text: str) -> SendReport:
    """contacts: rows with name and phone. Never raises; failures are listed in the report."""
    report = SendReport(total=len(contacts))
    mode = provider()

    for c in contacts:
        name = str(c.get("name") or "contact")
        phone = normalize_phone(str(c.get("phone") or ""))
        if phone is None:
            report.failed.append(name)
            continue

        if mode == "twilio":
            sid = os.environ.get("TWILIO_ACCOUNT_SID", "")
            token = os.environ.get("TWILIO_AUTH_TOKEN", "")
            sender = os.environ.get("TWILIO_FROM", "")
            if not (sid and token and sender):
                log.error("NOTIFY_PROVIDER=twilio but the TWILIO_* settings are missing")
                report.failed.append(name)
                continue
            try:
                status = await _twilio_post(
                    f"https://api.twilio.com/2010-04-01/Accounts/{sid}/Messages.json",
                    (sid, token),
                    {"To": phone, "From": sender, "Body": text},
                )
            except httpx.HTTPError:
                status = 0
            if 200 <= status < 300:
                report.sent += 1
            else:
                log.warning("SMS to %s failed (status %s)", name, status)
                report.failed.append(name)
        else:
            report.simulated = True
            log.info("[SOS simulated] to %s (%s***): %s", name, phone[:5], text)

    return report
