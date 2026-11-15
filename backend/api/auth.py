from __future__ import annotations

import secrets
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response, status

from backend.auth import (
    ENGINEER_COOKIE,
    ENGINEER_COOKIE_SECONDS,
    issue_engineer_cookie,
    require_engineer,
)


router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.get("/connection-token", dependencies=[Depends(require_engineer)])
def connection_token(request: Request, response: Response) -> dict[str, str]:
    response.headers["Cache-Control"] = "no-store"
    return {"token": request.app.state.settings.bootstrap_token}


@router.post("/login", status_code=status.HTTP_204_NO_CONTENT)
def login(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> Response:
    expected = request.app.state.settings.engineer_token
    supplied = ""
    if authorization and authorization.startswith("Bearer "):
        supplied = authorization.removeprefix("Bearer ").strip()
    if not supplied or not secrets.compare_digest(supplied, expected):
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            "invalid engineer token",
            headers={"Cache-Control": "no-store"},
        )

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
