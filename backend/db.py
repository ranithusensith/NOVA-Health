"""
Reads and writes Supabase tables AS THE SIGNED-IN USER.

The backend forwards the user's own login token (JWT) to Supabase, so row-level
security applies: a user can only ever read or write their own rows. This also
means the backend does NOT need the secret (service_role) key.
"""

from datetime import datetime, timezone
import os

import httpx
from upstream import decode_json


class DBError(Exception):
    def __init__(self, message: str, status: int = 503):
        super().__init__(message)
        self.message = message
        self.status = status


class InvalidDBResponse(DBError):
    def __init__(self):
        super().__init__("The database returned an unreadable response.", status=502)


def _check_status(response: httpx.Response) -> None:
    status = response.status_code
    if 200 <= status < 300:
        return
    if status in (401, 403):
        raise DBError("Database access was denied.", status=status)
    if status in (408, 429) or status >= 500:
        raise DBError("The database is unavailable.")
    raise DBError("The database rejected the request.", status=502)


class UserDB:
    def __init__(self, token: str, user_id: str):
        self.token = token
        self.user_id = user_id

    @property
    def _base(self) -> str:
        return os.environ.get("SUPABASE_URL", "").rstrip("/") + "/rest/v1"

    def _headers(self) -> dict:
        return {
            "apikey": os.environ.get("SUPABASE_PUBLISHABLE_KEY", ""),
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
        }

    async def select(
        self,
        table: str,
        columns: str = "*",
        *,
        filters: dict | None = None,
        order: str | None = None,
        limit: int | None = None,
    ) -> list[dict]:
        """filters use PostgREST syntax, for example {"status": "eq.confirmed"}."""
        params: dict = {"select": columns}
        params.update(filters or {})
        owner_column = "id" if table == "profiles" else "user_id"
        params[owner_column] = f"eq.{self.user_id}"
        if order:
            params["order"] = order
        if limit:
            params["limit"] = str(limit)
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                res = await client.get(f"{self._base}/{table}", params=params, headers=self._headers())
        except (httpx.HTTPError, httpx.InvalidURL):
            raise DBError("Could not reach the database.") from None
        _check_status(res)
        try:
            data = decode_json(res.content)
        except ValueError:
            raise InvalidDBResponse() from None
        if not isinstance(data, list) or not all(isinstance(row, dict) for row in data):
            raise InvalidDBResponse()
        return data

    async def insert(self, table: str, rows: dict | list[dict]) -> None:
        if any(row.get("user_id") != self.user_id for row in ([rows] if isinstance(rows, dict) else rows)):
            raise DBError("The record must belong to the signed-in account.", status=403)
        headers = {**self._headers(), "Prefer": "return=minimal"}
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                res = await client.post(f"{self._base}/{table}", json=rows, headers=headers)
        except (httpx.HTTPError, httpx.InvalidURL):
            raise DBError("Could not reach the database.") from None
        _check_status(res)

    async def set_ai_consent(self, disclosure_version: str | None) -> None:
        headers = {**self._headers(), "Prefer": "return=minimal,resolution=merge-duplicates"}
        url = f"{self._base}/ai_processing_consents"
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                if disclosure_version is None:
                    res = await client.delete(url, params={"user_id": f"eq.{self.user_id}"}, headers=headers)
                else:
                    res = await client.post(
                        url, params={"on_conflict": "user_id"}, headers=headers,
                        json={
                            "user_id": self.user_id, "disclosure_version": disclosure_version,
                            "consented_at": datetime.now(timezone.utc).isoformat(),
                        },
                    )
        except (httpx.HTTPError, httpx.InvalidURL):
            raise DBError("Could not update AI consent.") from None
        _check_status(res)

    async def delete_legacy_ai_chats(self) -> int:
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                res = await client.post(
                    f"{self._base}/rpc/delete_legacy_ai_chats", json={}, headers=self._headers(),
                )
            _check_status(res)
            count = decode_json(res.content)
            if type(count) is not int or count < 0:
                raise InvalidDBResponse()
            return count
        except (httpx.HTTPError, httpx.InvalidURL):
            raise DBError("Could not verify chat deletion.") from None
        except ValueError:
            raise InvalidDBResponse() from None
