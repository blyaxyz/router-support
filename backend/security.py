from __future__ import annotations

import hashlib
import hmac
import secrets


def new_device_token() -> str:
    return secrets.token_urlsafe(32)


def token_digest(token: str, pepper: str) -> str:
    return hmac.new(pepper.encode(), token.encode(), hashlib.sha256).hexdigest()


def tokens_match(token: str, expected_digest: str, pepper: str) -> bool:
    return hmac.compare_digest(token_digest(token, pepper), expected_digest)

