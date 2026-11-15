from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from backend.api.routers import _require_engineer
from backend.schemas import SupportSessionResponse

router = APIRouter(tags=["support"], dependencies=[Depends(_require_engineer)])


@router.post(
    "/api/routers/{router_uuid}/support/start",
    response_model=SupportSessionResponse,
)
def start_support(router_uuid: str, request: Request):
    return request.app.state.session_manager.start(router_uuid)


@router.post("/api/sessions/{session_id}/stop")
def stop_support(session_id: int, request: Request):
    request.app.state.session_manager.stop(session_id)
    return {"status": "stopped"}


@router.get("/api/sessions")
def list_sessions(request: Request):
    with request.app.state.database.connect() as connection:
        rows = connection.execute(
            """SELECT s.id, r.uuid, r.name, s.started_at, s.ended_at,
                      s.expires_at, s.status
               FROM support_sessions s
               JOIN routers r ON r.id = s.router_id
               ORDER BY s.id DESC LIMIT 100"""
        ).fetchall()
    return [dict(row) for row in rows]

