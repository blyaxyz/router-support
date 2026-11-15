from __future__ import annotations

import os
import secrets
import signal
import socket
import subprocess
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

from fastapi import HTTPException

from backend.schemas import SupportSessionResponse
from backend.security import token_digest


class SessionManager:
    def __init__(self, database, settings):
        self.database = database
        self.settings = settings
        self.processes: dict[int, subprocess.Popen] = {}
        self.terminal_processes: dict[int, set] = {}
        self.known_hosts = settings.support_private_key.parent / "router_known_hosts"

    def mark_interrupted_sessions(self) -> None:
        now = datetime.now(UTC).replace(microsecond=0).isoformat()
        with self.database.connect() as connection:
            connection.execute(
                """UPDATE support_sessions SET status = 'failed', ended_at = ?
                   WHERE status = 'active'""",
                (now,),
            )

    def cleanup_expired(self) -> None:
        now = datetime.now(UTC).replace(microsecond=0)
        with self.database.connect() as connection:
            expired = connection.execute(
                """SELECT id FROM support_sessions
                   WHERE status = 'active' AND expires_at <= ?""",
                (now.isoformat(),),
            ).fetchall()
        for row in expired:
            self.stop(row["id"])
        for session_id, process in list(self.processes.items()):
            if process.poll() is not None:
                self.processes.pop(session_id, None)
                self._mark_stopped(session_id, "failed")

    def _write_known_host(self, ssh_port: int, host_key: str) -> None:
        if not host_key:
            raise HTTPException(409, "router has not reported its SSH host key yet")
        self.known_hosts.parent.mkdir(parents=True, exist_ok=True)
        target = f"[127.0.0.1]:{ssh_port}"
        existing: list[str] = []
        if self.known_hosts.exists():
            existing = self.known_hosts.read_text(encoding="utf-8").splitlines()
        lines = [line for line in existing if not line.startswith(f"{target} ")]
        key_parts = host_key.split()
        lines.append(f"{target} {' '.join(key_parts[:2])}")
        temporary = self.known_hosts.with_suffix(".tmp")
        temporary.write_text("\n".join(lines) + "\n", encoding="utf-8")
        temporary.chmod(0o600)
        temporary.replace(self.known_hosts)

    def _urls(
        self,
        session_id: int,
        router_id: int,
        expires_at: datetime,
        token: str,
        app_enabled: bool,
    ):
        domain = self.settings.public_base_domain
        base = f"https://{{service}}-r{router_id}.{domain}/_router_support/auth#{token}"
        return SupportSessionResponse(
            id=session_id,
            status="active",
            expires_at=expires_at,
            luci_url=base.format(service="luci"),
            v2raya_url=base.format(service="v2raya"),
            app_url=base.format(service="app") if app_enabled else None,
        )

    def _ssh_base_command(self, ssh_port: int) -> list[str]:
        return [
            "ssh", "-i", str(self.settings.support_private_key),
            "-o", "IdentitiesOnly=yes",
            "-o", f"UserKnownHostsFile={self.known_hosts}",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-p", str(ssh_port),
        ]

    def _router_for_access(self, router_uuid: str):
        with self.database.connect() as connection:
            router = connection.execute(
                """SELECT id, ssh_port, router_ssh_host_key, last_seen
                   FROM routers WHERE uuid = ?""",
                (router_uuid,),
            ).fetchone()
        if not router:
            raise HTTPException(404, "router not found")
        now = datetime.now(UTC)
        if datetime.fromisoformat(router["last_seen"]) < now - timedelta(
            seconds=self.settings.heartbeat_timeout_seconds
        ):
            raise HTTPException(409, "router is offline")
        self._write_known_host(router["ssh_port"], router["router_ssh_host_key"])
        return router

    def rename_router(self, router_uuid: str, hostname: str) -> None:
        router = self._router_for_access(router_uuid)
        remote_command = (
            f"uci set system.@system[0].hostname='{hostname}'; "
            "uci commit system; /etc/init.d/system reload"
        )
        result = subprocess.run(
            [*self._ssh_base_command(router["ssh_port"]), "root@127.0.0.1", remote_command],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=12,
            check=False,
        )
        if result.returncode != 0:
            raise HTTPException(502, "failed to change router hostname")
        with self.database.connect() as connection:
            connection.execute(
                "UPDATE routers SET name = ? WHERE uuid = ?", (hostname, router_uuid)
            )

    def terminal_spec(self, router_uuid: str) -> tuple[int, list[str]]:
        router = self._router_for_access(router_uuid)
        with self.database.connect() as connection:
            session = connection.execute(
                """SELECT id FROM support_sessions
                   WHERE router_id = ? AND status = 'active' AND expires_at > ?
                   ORDER BY id DESC LIMIT 1""",
                (router["id"], datetime.now(UTC).isoformat()),
            ).fetchone()
        if not session:
            raise HTTPException(409, "an active support session is required")
        command = [
            *self._ssh_base_command(router["ssh_port"]),
            "-tt", "root@127.0.0.1",
        ]
        return session["id"], command

    def register_terminal(self, session_id: int, process) -> None:
        self.terminal_processes.setdefault(session_id, set()).add(process)

    def unregister_terminal(self, session_id: int, process) -> None:
        processes = self.terminal_processes.get(session_id)
        if processes:
            processes.discard(process)
            if not processes:
                self.terminal_processes.pop(session_id, None)

    def start(self, router_uuid: str) -> SupportSessionResponse:
        now = datetime.now(UTC).replace(microsecond=0)
        with self.database.connect() as connection:
            router = connection.execute(
                """SELECT id, ssh_port, router_ssh_host_key, last_seen
                   FROM routers WHERE uuid = ?""",
                (router_uuid,),
            ).fetchone()
            if not router:
                raise HTTPException(404, "router not found")
            last_seen = datetime.fromisoformat(router["last_seen"])
            if last_seen < now - timedelta(seconds=self.settings.heartbeat_timeout_seconds):
                raise HTTPException(409, "router is offline")
            active = connection.execute(
                """SELECT id FROM support_sessions
                   WHERE router_id = ? AND status = 'active'""",
                (router["id"],),
            ).fetchone()
            if active:
                raise HTTPException(409, "router already has an active support session")
            app_service = connection.execute(
                """SELECT enabled FROM services
                   WHERE router_id = ? AND name = 'app'""",
                (router["id"],),
            ).fetchone()
            app_enabled = bool(app_service and app_service["enabled"])

            router_id = router["id"]
            port_base = 31000 + router_id * 10
            if port_base + 3 > 65535:
                raise HTTPException(503, "support port pool exhausted")
            luci_port, v2raya_port, app_port = port_base + 1, port_base + 2, port_base + 3
            token = secrets.token_urlsafe(32)
            expires_at = now + timedelta(seconds=self.settings.support_session_seconds)
            cursor = connection.execute(
                """INSERT INTO support_sessions
                   (router_id, started_at, expires_at, status, token_digest,
                    luci_port, v2raya_port, app_port)
                   VALUES (?, ?, ?, 'active', ?, ?, ?, ?)""",
                (
                    router_id,
                    now.isoformat(),
                    expires_at.isoformat(),
                    token_digest(token, self.settings.device_token_pepper),
                    luci_port,
                    v2raya_port,
                    app_port,
                ),
            )
            session_id = cursor.lastrowid

        try:
            self._write_known_host(router["ssh_port"], router["router_ssh_host_key"])
        except Exception:
            self._mark_stopped(session_id, "failed")
            raise
        command = [
            "ssh", "-N", "-T", "-i", str(self.settings.support_private_key),
            "-o", "IdentitiesOnly=yes",
            "-o", f"UserKnownHostsFile={self.known_hosts}",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=3",
            "-p", str(router["ssh_port"]),
            "-L", f"127.0.0.1:{luci_port}:127.0.0.1:80",
            "-L", f"127.0.0.1:{v2raya_port}:127.0.0.1:2017",
            "root@127.0.0.1",
        ]
        if app_enabled:
            command[-1:-1] = ["-L", f"127.0.0.1:{app_port}:127.0.0.1:2018"]
        try:
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as error:
            self._mark_stopped(session_id, "failed")
            raise HTTPException(502, "could not start support SSH process") from error
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and process.poll() is None:
            try:
                with socket.create_connection(("127.0.0.1", luci_port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.1)
        if process.poll() is not None:
            self._mark_stopped(session_id, "failed")
            raise HTTPException(502, "failed to establish support SSH connection")
        self.processes[session_id] = process
        with self.database.connect() as connection:
            connection.execute(
                "UPDATE support_sessions SET process_pid = ? WHERE id = ?",
                (process.pid, session_id),
            )
        return self._urls(session_id, router_id, expires_at, token, app_enabled)

    def _mark_stopped(self, session_id: int, status: str = "stopped") -> None:
        now = datetime.now(UTC).replace(microsecond=0).isoformat()
        with self.database.connect() as connection:
            connection.execute(
                """UPDATE support_sessions SET status = ?, ended_at = ?
                   WHERE id = ?""",
                (status, now, session_id),
            )

    def stop(self, session_id: int) -> None:
        for terminal in self.terminal_processes.pop(session_id, set()):
            if terminal.returncode is None:
                try:
                    os.killpg(terminal.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        process = self.processes.pop(session_id, None)
        if process and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=2)
        self._mark_stopped(session_id)

