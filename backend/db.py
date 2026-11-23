"""
Reads and writes Supabase tables AS THE SIGNED-IN USER.

The backend forwards the user's own login token (JWT) to Supabase, so row-level
security applies: a user can only ever read or write their own rows. This also
means the backend does NOT need the secret (service_role) key.
"""

import os

import httpx


class DBError(Exception):
    def __init__(self, message: str, status: int = 502):
        super().__init__(message)
        self.message = message
        self.status = status


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
        if order:
            params["order"] = order
        if limit:
            params["limit"] = str(limit)
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                res = await client.get(f"{self._base}/{table}", params=params, headers=self._headers())
        except httpx.HTTPError as e:
            raise DBError("Could not reach the database.") from e
        if res.status_code >= 400:
            raise DBError(f"Database error ({res.status_code}).")
        data = res.json()
        if not isinstance(data, list):
            raise DBError("Unexpected database response.")
        return data

    async def insert(self, table: str, rows: dict | list[dict]) -> None:
        headers = {**self._headers(), "Prefer": "return=minimal"}
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                res = await client.post(f"{self._base}/{table}", json=rows, headers=headers)
        except httpx.HTTPError as e:
            raise DBError("Could not reach the database.") from e
        if res.status_code >= 400:
            raise DBError(f"Database error ({res.status_code}).")
