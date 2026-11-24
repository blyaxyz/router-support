from __future__ import annotations

import logging
from datetime import UTC, datetime


logger = logging.getLogger("uvicorn.error")


def record_event(
    database,
    level: str,
    category: str,
    message: str,
    router_uuid: str | None = None,
) -> None:
    normalized_level = level.upper()
    created_at = datetime.now(UTC).replace(microsecond=0).isoformat()
    with database.connect() as connection:
        connection.execute(
            """INSERT INTO event_logs
               (created_at, level, category, router_uuid, message)
               VALUES (?, ?, ?, ?, ?)""",
            (created_at, normalized_level, category, router_uuid, message[:2000]),
        )
        connection.execute(
            """DELETE FROM event_logs WHERE id NOT IN
               (SELECT id FROM event_logs ORDER BY id DESC LIMIT 5000)"""
        )
    log_method = getattr(logger, normalized_level.lower(), logger.info)
    log_method(
        "router event category=%s router_uuid=%s message=%s",
        category,
        router_uuid or "-",
        message,
    )
