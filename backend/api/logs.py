from __future__ import annotations

from fastapi import APIRouter, Depends, Query, Request

from backend.auth import require_engineer


router = APIRouter(
    prefix="/api/logs",
    tags=["logs"],
    dependencies=[Depends(require_engineer)],
)


@router.get("")
def list_event_logs(request: Request, limit: int = Query(default=200, ge=1, le=500)):
    with request.app.state.database.connect() as connection:
        rows = connection.execute(
            """SELECT id, created_at, level, category, router_uuid, message
               FROM event_logs ORDER BY id DESC LIMIT ?""",
            (limit,),
        ).fetchall()
    return [dict(row) for row in reversed(rows)]
