from __future__ import annotations

import secrets
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response, status

from backend.access import external_client_ip
from backend.auth import (
    ENGINEER_COOKIE,
    ENGINEER_COOKIE_SECONDS,
    issue_engineer_cookie,
    require_engineer,
)


router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.get("/connection-token", dependencies=[Depends(require_engineer)])
def connection_token(request: Request, response: Response) -> dict[str, str | int]:
    response.headers["Cache-Control"] = "no-store"
    settings = request.app.state.settings
    return {
        "token": settings.bootstrap_token,
        "ssh_host": settings.ssh_host,
        "ssh_port": settings.ssh_port,
        "install_command": (
            "curl -fsSL https://raw.githubusercontent.com/blyaxyz/"
            "router-support/main/bootstrap-openwrt.sh | sh"
        ),
    }


@router.post("/login", status_code=status.HTTP_204_NO_CONTENT)
def login(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> Response:
    client_ip = str(external_client_ip(request.scope) or "unknown")
    limiter = request.app.state.login_attempt_limiter
    retry_after = limiter.retry_after(client_ip)
    if retry_after:
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            "too many failed login attempts",
            headers={
                "Cache-Control": "no-store",
                "Retry-After": str(retry_after),
            },
        )
    expected = request.app.state.settings.engineer_token
    supplied = ""
    if authorization and authorization.startswith("Bearer "):
        supplied = authorization.removeprefix("Bearer ").strip()
    if not supplied or not secrets.compare_digest(supplied, expected):
        retry_after = limiter.record_failure(client_ip)
        if retry_after:
            raise HTTPException(
                status.HTTP_429_TOO_MANY_REQUESTS,
                "too many failed login attempts",
                headers={
                    "Cache-Control": "no-store",
                    "Retry-After": str(retry_after),
                },
            )
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            "invalid engineer token",
            headers={"Cache-Control": "no-store"},
        )

    limiter.record_success(client_ip)
    response = Response(status_code=status.HTTP_204_NO_CONTENT)
    response.headers["Cache-Control"] = "no-store"
    response.set_cookie(
        ENGINEER_COOKIE,
        issue_engineer_cookie(request.app.state.settings),
        max_age=ENGINEER_COOKIE_SECONDS,
        httponly=True,
        secure=True,
        samesite="strict",
        path="/",
    )
    return response


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout() -> Response:
    response = Response(status_code=status.HTTP_204_NO_CONTENT)
    response.headers["Cache-Control"] = "no-store"
    response.delete_cookie(
        ENGINEER_COOKIE,
        httponly=True,
        secure=True,
        samesite="strict",
        path="/",
    )
    return response
