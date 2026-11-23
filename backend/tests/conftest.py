import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import httpx
import pytest


@pytest.fixture(autouse=True)
def forbid_external_http(monkeypatch):
    """Fail on unexpected outbound HTTP. TestClient uses HTTPX's sync transport."""
    async def fail(*args, **kwargs):
        pytest.fail("Unmocked outbound HTTP request")

    monkeypatch.setattr(httpx.AsyncClient, "send", fail)
