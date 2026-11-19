from __future__ import annotations

import secrets
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status

from backend.auth import require_engineer as _require_engineer
from backend.authorized_keys import sync_authorized_keys
from backend.schemas import (
    HeartbeatRequest,
    HeartbeatResponse,
    RegisterRequest,
    RegisterResponse,
    RenameRouterRequest,
    RouterResponse,
)
from backend.security import new_device_token, token_digest, tokens_match

router = APIRouter(prefix="/api/routers", tags=["routers"])


def _bearer(authorization: Annotated[str | None, Header()] = None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing bearer token")
    return authorization.removeprefix("Bearer ").strip()


def _now() -> datetime:
    return datetime.now(UTC).replace(microsecond=0)


def _all_key_rows(connection: sqlite3.Connection) -> list[dict]:
    return [
        dict(row)
        for row in connection.execute(
            "SELECT uuid, public_key, ssh_port FROM routers ORDER BY ssh_port"
        ).fetchall()
    ]


@router.post("/register", response_model=RegisterResponse, status_code=201)
def register(payload: RegisterRequest, request: Request, token: str = Depends(_bearer)):
    settings = request.app.state.settings
    if not secrets.compare_digest(token, settings.bootstrap_token):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid bootstrap token")

    database = request.app.state.database
    device_token = new_device_token()
    now = _now().isoformat()
    with database.connect() as connection:
        # Serialize allocation so concurrent registrations cannot select one port.
        connection.execute("BEGIN IMMEDIATE")
        existing = connection.execute(
            "SELECT id, public_key, ssh_port FROM routers WHERE uuid = ?",
            (str(payload.uuid),),
        ).fetchone()
        if existing:
            if not secrets.compare_digest(existing["public_key"], payload.public_key):
                raise HTTPException(
                    status.HTTP_409_CONFLICT,
                    "UUID is registered with another SSH key",
                )
            reverse_port = existing["ssh_port"]
            connection.execute(
                """UPDATE routers SET name = ?, model = ?, firmware = ?, ram_mb = ?, mac_address = ?,
                   token_digest = ?, last_seen = ? WHERE id = ?""",
                (
                    payload.hostname, payload.model, payload.firmware, payload.ram_mb,
                    payload.mac_address,
                    token_digest(device_token, settings.device_token_pepper), now,
                    existing["id"],
                ),
            )
        else:
            used = {
                row[0]
                for row in connection.execute("SELECT ssh_port FROM routers").fetchall()
            }
            reverse_port = next(
                (
                    port
                    for port in range(
                        settings.reverse_port_start, settings.reverse_port_end + 1
                    )
                    if port not in used
                ),
                None,
            )
            if reverse_port is None:
                raise HTTPException(503, "reverse SSH port pool exhausted")
            cursor = connection.execute(
                """INSERT INTO routers
                   (uuid, name, model, firmware, ram_mb, mac_address, ssh_port, public_key,
                    token_digest, created_at, last_seen)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    str(payload.uuid), payload.hostname, payload.model,
                    payload.firmware, payload.ram_mb, payload.mac_address, reverse_port,
                    payload.public_key,
                    token_digest(device_token, settings.device_token_pepper),
                    now, now,
                ),
            )
            for name, local_port in (("luci", 80), ("v2raya", 2017), ("app", 2018)):
                connection.execute(
                    """INSERT INTO services (router_id, name, local_port, enabled)
                       VALUES (?, ?, ?, ?)""",
                    (cursor.lastrowid, name, local_port, 0 if name == "app" else 1),
                )
        sync_authorized_keys(settings.authorized_keys_file, _all_key_rows(connection))

    return RegisterResponse(
        uuid=payload.uuid,
        device_token=device_token,
        ssh_host=settings.ssh_host,
        ssh_host_key=settings.ssh_host_key,
        ssh_user=settings.ssh_user,
        ssh_server_port=settings.ssh_port,
        reverse_port=reverse_port,
    )


@router.post("/heartbeat", response_model=HeartbeatResponse)
def heartbeat(payload: HeartbeatRequest, request: Request, token: str = Depends(_bearer)):
    settings = request.app.state.settings
    now = _now()
    with request.app.state.database.connect() as connection:
        row = connection.execute(
            "SELECT token_digest FROM routers WHERE uuid = ?", (str(payload.uuid),)
        ).fetchone()
        if not row or not tokens_match(token, row["token_digest"], settings.device_token_pepper):
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid device credentials")
        updates = {"last_seen": now.isoformat()}
        for field in (
            "hostname", "model", "firmware", "ram_mb", "mac_address", "ssh_host_key"
        ):
            value = getattr(payload, field)
            if value is not None:
                database_field = {
                    "hostname": "name",
                    "ssh_host_key": "router_ssh_host_key",
                }.get(field, field)
                updates[database_field] = value
        assignments = ", ".join(f"{field} = ?" for field in updates)
        connection.execute(
            f"UPDATE routers SET {assignments} WHERE uuid = ?",  # fields are fixed above
            (*updates.values(), str(payload.uuid)),
        )
    support_public_key = settings.support_public_key.read_text(encoding="utf-8").strip()
    return HeartbeatResponse(
        server_time=now,
        support_public_key=support_public_key,
        ssh_host=settings.ssh_host,
        ssh_host_key=settings.ssh_host_key,
        ssh_server_port=settings.ssh_port,
    )


def _router_status(request: Request, last_seen: str, ssh_port: int) -> tuple[str, str]:
    threshold = _now() - timedelta(seconds=request.app.state.settings.heartbeat_timeout_seconds)
    tunnel_connected = request.app.state.session_manager.tunnel_is_listening(ssh_port)
    tunnel_status = "connected" if tunnel_connected else "disconnected"
    if datetime.fromisoformat(last_seen) < threshold:
        return "offline", tunnel_status
    return ("online" if tunnel_connected else "degraded"), tunnel_status


@router.get("", response_model=list[RouterResponse], dependencies=[Depends(_require_engineer)])
def list_routers(request: Request):
    with request.app.state.database.connect() as connection:
        rows = connection.execute(
            """SELECT uuid, name, model, firmware, ram_mb, mac_address, ssh_port,
                      created_at, last_seen FROM routers ORDER BY name"""
        ).fetchall()
    result = []
    for row in rows:
        status_value, tunnel_status = _router_status(
            request, row["last_seen"], row["ssh_port"]
        )
        result.append(
            RouterResponse(
                **dict(row), status=status_value, tunnel_status=tunnel_status
            )
        )
    return result


@router.patch(
    "/{router_uuid}",
    dependencies=[Depends(_require_engineer)],
)
def rename_router(router_uuid: str, payload: RenameRouterRequest, request: Request):
    request.app.state.session_manager.rename_router(router_uuid, payload.hostname)
    return {"hostname": payload.hostname}


@router.get(
    "/{router_uuid}",
    response_model=RouterResponse,
    dependencies=[Depends(_require_engineer)],
)
def get_router(router_uuid: str, request: Request):
    with request.app.state.database.connect() as connection:
        row = connection.execute(
            """SELECT uuid, name, model, firmware, ram_mb, mac_address, ssh_port,
                      created_at, last_seen FROM routers WHERE uuid = ?""",
            (router_uuid,),
        ).fetchone()
    if not row:
        raise HTTPException(404, "router not found")
    status_value, tunnel_status = _router_status(
        request, row["last_seen"], row["ssh_port"]
    )
    return RouterResponse(
        **dict(row),
        status=status_value,
        tunnel_status=tunnel_status,
    )

