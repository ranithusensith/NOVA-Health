"""Send SOS alerts and verify provider delivery without logging contact data."""

import asyncio
import os
import re
from dataclasses import dataclass

import httpx

DEFAULT_COUNTRY_CODE = os.environ.get("DEFAULT_COUNTRY_CODE", "94")  # Sri Lanka
TWILIO_ROOT = "https://api.twilio.com/2010-04-01/Accounts"
_MESSAGE_SID = re.compile(r"(?:SM|MM)[0-9a-fA-F]{32}")


def provider() -> str:
    return os.environ.get("NOTIFY_PROVIDER", "log").strip().lower() or "log"


def normalize_phone(raw: str) -> str | None:
    text = raw.strip()
    if not re.fullmatch(r"[+0-9().\s-]+", text) or text.count("+") > 1 or "+" in text[1:]:
        return None
    digits = re.sub(r"[^0-9]", "", text)
    if not digits:
        return None
    if not text.startswith("+"):
        if digits.startswith("00"):
            digits = digits[2:]
        elif digits.startswith("0"):
            digits = DEFAULT_COUNTRY_CODE + digits[1:]
        elif not digits.startswith(DEFAULT_COUNTRY_CODE):
            digits = DEFAULT_COUNTRY_CODE + digits
    if not 9 <= len(digits) <= 15 or digits.startswith("0"):
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
class Recipient:
    contact_id: str
    status: str
    message_sid: str | None = None

    @property
    def can_refresh(self) -> bool:
        return self.message_sid is not None and self.status in ("queued", "sent", "unknown")


@dataclass
class SendReport:
    mode: str
    recipients: list[Recipient]

    @property
    def can_refresh(self) -> bool:
        return any(recipient.can_refresh for recipient in self.recipients)

    def payload(self) -> dict:
        statuses = {recipient.status for recipient in self.recipients}
        if not statuses:
            status = "no_contacts"
        elif self.mode == "log":
            status = "simulated"
        elif len(statuses) == 1:
            status = self.recipients[0].status
        elif "failed" in statuses:
            status = "partial_failure"
        elif "unknown" in statuses:
            status = "unknown"
        elif "queued" in statuses:
            status = "queued"
        else:
            status = "sent"

        confirmed = sum(recipient.status == "delivered" for recipient in self.recipients)
        return {
            "status": status,
            "contacts_total": len(self.recipients),
            "contacts_notified": confirmed,
            "delivered": status == "delivered",
            "simulated": status == "simulated",
            "can_refresh": self.can_refresh,
            "recipients": [
                {"contact_id": recipient.contact_id, "status": recipient.status}
                for recipient in self.recipients
            ],
        }


def _twilio_config() -> tuple[str, str, str]:
    return (
        os.environ.get("TWILIO_ACCOUNT_SID", ""),
        os.environ.get("TWILIO_AUTH_TOKEN", ""),
        os.environ.get("TWILIO_FROM", ""),
    )


def _provider_state(status: object, *, confirmed: bool) -> str:
    if status == "delivered":
        return "delivered" if confirmed else "sent"
    if status == "sent":
        return "sent"
    if status in ("accepted", "queued", "sending", "scheduled"):
        return "queued"
    if status in ("failed", "undelivered", "canceled"):
        return "failed"
    return "unknown"


async def send_sos(contacts: list[dict], text: str, *, mode: str | None = None) -> SendReport:
    mode = mode or provider()
    account, token, sender = _twilio_config()
    limit = asyncio.Semaphore(5)
    async with httpx.AsyncClient(timeout=8) as client:
        async def send(contact: dict) -> Recipient:
            contact_id = str(contact["id"])
            phone = normalize_phone(str(contact.get("phone") or ""))
            if phone is None:
                return Recipient(contact_id, "failed")
            if mode in ("log", "manual"):
                return Recipient(contact_id, "manual_required")
            if mode != "twilio" or not (account and token and sender):
                return Recipient(contact_id, "failed")

            try:
                async with limit:
                    res = await client.post(
                        f"{TWILIO_ROOT}/{account}/Messages.json",
                        auth=(account, token),
                        data={"To": phone, "From": sender, "Body": text},
                    )
                if 400 <= res.status_code < 500 and res.status_code != 408:
                    return Recipient(contact_id, "failed")
                if not res.is_success:
                    return Recipient(contact_id, "unknown")
                data = res.json()
                sid = data.get("sid") if isinstance(data, dict) else None
                if not isinstance(sid, str) or not _MESSAGE_SID.fullmatch(sid):
                    return Recipient(contact_id, "unknown")
                if data.get("account_sid") != account:
                    return Recipient(contact_id, "unknown")
                return Recipient(contact_id, _provider_state(data.get("status"), confirmed=False), sid)
            except (httpx.HTTPError, ValueError):
                return Recipient(contact_id, "unknown")

        recipients = await asyncio.gather(*(send(contact) for contact in contacts))
    return SendReport(mode, list(recipients))


async def refresh_delivery(report: SendReport) -> bool:
    """Refresh pending messages; return false if some statuses could not be refreshed."""
    pending = [recipient for recipient in report.recipients if recipient.can_refresh]
    if not pending:
        return True
    account, token, _ = _twilio_config()
    if not account or not token:
        return False

    limit = asyncio.Semaphore(5)
    async with httpx.AsyncClient(timeout=8) as client:
        async def refresh(recipient: Recipient) -> bool:
            try:
                async with limit:
                    res = await client.get(
                        f"{TWILIO_ROOT}/{account}/Messages/{recipient.message_sid}.json",
                        auth=(account, token),
                    )
                res.raise_for_status()
                data = res.json()
                if not isinstance(data, dict) or data.get("sid") != recipient.message_sid or data.get("account_sid") != account:
                    return False
                status = _provider_state(data.get("status"), confirmed=True)
                if status == "unknown":
                    return False
                if recipient.status != "sent" or status != "queued":
                    recipient.status = status
                return True
            except (httpx.HTTPError, ValueError):
                return False

        refreshed = await asyncio.gather(*(refresh(recipient) for recipient in pending))
    return all(refreshed)
