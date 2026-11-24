"""Decode upstream JSON that can safely be forwarded as JSON again."""

import json


def decode_json(content: bytes | str):
    try:
        data = json.loads(content)
        # Reject non-finite numbers and lone surrogates, which cannot be sent as API JSON.
        json.dumps(data, allow_nan=False, ensure_ascii=False).encode("utf-8")
    except (ValueError, RecursionError):
        raise ValueError("Invalid upstream JSON") from None
    return data
