from __future__ import annotations

import hashlib
import hmac
import secrets
import time
from typing import Annotated

from fastapi import Header, HTTPException, Request, status

from backend.config import Settings


ENGINEER_COOKIE = "router_support_engineer"
ENGINEER_COOKIE_SECONDS = 12 * 60 * 60


def _signature(expires_at: int, settings: Settings) -> str:
    message = f"{expires_at}:{settings.engineer_token}".encode()
    return hmac.new(
        settings.device_token_pepper.encode(), message, hashlib.sha256
    ).hexdigest()


def issue_engineer_cookie(settings: Settings) -> str:
    expires_at = int(time.time()) + ENGINEER_COOKIE_SECONDS
    return f"{expires_at}.{_signature(expires_at, settings)}"


def valid_engineer_cookie(value: str | None, settings: Settings) -> bool:
    if not value:
        return False
    try:
        raw_expiry, supplied_signature = value.split(".", 1)
        expires_at = int(raw_expiry)
    except (TypeError, ValueError):
        return False
    if expires_at < int(time.time()):
        return False
    return secrets.compare_digest(
        supplied_signature, _signature(expires_at, settings)
    )


def engineer_authorized(
    request: Request, authorization: str | None = None
) -> bool:
    settings = request.app.state.settings
    if authorization and authorization.startswith("Bearer "):
        token = authorization.removeprefix("Bearer ").strip()
        if secrets.compare_digest(token, settings.engineer_token):
            return True
    return valid_engineer_cookie(request.cookies.get(ENGINEER_COOKIE), settings)


def require_engineer(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> None:
    if not engineer_authorized(request, authorization):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "engineer access denied")
