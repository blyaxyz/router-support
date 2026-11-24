from __future__ import annotations

import errno
import logging
import os
import secrets
import signal
import socket
import subprocess
import tempfile
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

from fastapi import HTTPException

from backend.event_log import record_event
from backend.schemas import SupportSessionResponse
from backend.security import token_digest

# Reuse Uvicorn's configured logger so INFO diagnostics reach journald too.
logger = logging.getLogger("uvicorn.error")


class SessionManager:
    def __init__(self, database, settings):
        self.database = database
        self.settings = settings
        self.processes: dict[int, subprocess.Popen] = {}
        self.terminal_processes: dict[int, set] = {}
        self.router_states: dict[str, str] = {}
        self.known_hosts = settings.support_private_key.parent / "router_known_hosts"

    @staticmethod
    def tunnel_is_listening(ssh_port: int) -> bool:
        """Check a localhost listener without opening a noisy SSH connection."""
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            probe.bind(("127.0.0.1", ssh_port))
            return False
        except OSError as error:
            if error.errno == errno.EADDRINUSE:
                return True
            logger.warning(
                "reverse tunnel probe failed port=%s error=%s", ssh_port, error
            )
            return False
        finally:
            probe.close()

    @staticmethod
    def _ssh_failure_detail(stderr: str) -> str:
        normalized = stderr.lower()
        if "host key verification failed" in normalized:
            return "SSH host key verification failed for the router tunnel"
        if "remote host identification has changed" in normalized:
            return "router SSH host key changed; wait for its next heartbeat and retry"
        if "permission denied" in normalized:
            return "router rejected the server support SSH key"
        if "connection refused" in normalized:
            return "router reverse SSH port refused the connection"
        if "connection timed out" in normalized or "operation timed out" in normalized:
            return "router reverse SSH port timed out"
        if "no route to host" in normalized:
            return "router reverse SSH port is unreachable"
        if "could not resolve hostname" in normalized:
            return "router SSH endpoint hostname could not be resolved"
        if "address already in use" in normalized:
            return "a local support forwarding port is already in use"
        summary = " ".join(stderr.strip().split())
        if summary:
            return f"support SSH failed: {summary[:300]}"
        return "support SSH process exited without an error message"

    @staticmethod
    def _terminate_process(process: subprocess.Popen) -> None:
        if process.poll() is not None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=2)
        except ProcessLookupError:
            pass
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)

    def mark_interrupted_sessions(self) -> None:
        now = datetime.now(UTC).replace(microsecond=0).isoformat()
        with self.database.connect() as connection:
            connection.execute(
                """UPDATE support_sessions SET status = 'failed', ended_at = ?
                   WHERE status = 'active'""",
                (now,),
            )

    def monitor_router_connections(self) -> None:
        now = datetime.now(UTC)
        with self.database.connect() as connection:
            routers = connection.execute(
                "SELECT uuid, name, ssh_port, last_seen FROM routers"
            ).fetchall()
        current_uuids = set()
        for router in routers:
            router_uuid = router["uuid"]
            current_uuids.add(router_uuid)
            heartbeat_fresh = datetime.fromisoformat(router["last_seen"]) >= now - timedelta(
                seconds=self.settings.heartbeat_timeout_seconds
            )
            tunnel_connected = self.tunnel_is_listening(router["ssh_port"])
            if not heartbeat_fresh:
                state = "offline"
                level = "warning"
                message = (
                    f"{router['name']}: heartbeat timeout; last_seen={router['last_seen']}, "
                    f"reverse_port={router['ssh_port']}, tunnel_connected={tunnel_connected}"
                )
            elif not tunnel_connected:
                state = "heartbeat_without_tunnel"
                level = "warning"
                message = (
                    f"{router['name']}: heartbeat is active but reverse SSH tunnel is absent; "
                    f"reverse_port={router['ssh_port']}"
                )
            else:
                state = "online"
                level = "info"
                message = (
                    f"{router['name']}: heartbeat and reverse SSH tunnel are active; "
                    f"reverse_port={router['ssh_port']}"
                )
            if self.router_states.get(router_uuid) != state:
                previous = self.router_states.get(router_uuid, "unknown")
                record_event(
                    self.database,
                    level,
                    "router_connection",
                    f"state {previous} -> {state}; {message}",
                    router_uuid,
                )
                self.router_states[router_uuid] = state
        for removed_uuid in set(self.router_states) - current_uuids:
            self.router_states.pop(removed_uuid, None)

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
                with self.database.connect() as connection:
                    row = connection.execute(
                        """SELECT r.uuid FROM support_sessions s
                           JOIN routers r ON r.id = s.router_id WHERE s.id = ?""",
                        (session_id,),
                    ).fetchone()
                record_event(
                    self.database,
                    "error",
                    "support_session",
                    f"support SSH process exited unexpectedly; session_id={session_id}, "
                    f"exit_code={process.returncode}",
                    row["uuid"] if row else None,
                )

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
        if not self.tunnel_is_listening(router["ssh_port"]):
            logger.warning(
                "router access denied: heartbeat active but reverse tunnel missing "
                "router_uuid=%s router_id=%s reverse_port=%s",
                router_uuid,
                router["id"],
                router["ssh_port"],
            )
            raise HTTPException(
                409,
                f"router heartbeat is active, but reverse SSH tunnel is not listening "
                f"on 127.0.0.1:{router['ssh_port']}; check the OpenWrt router-support log",
            )
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

    def disconnect_router_agent(
        self, router_uuid: str, ssh_port: int, router_host_key: str
    ) -> None:
        if not self.tunnel_is_listening(ssh_port):
            logger.info(
                "router agent disconnect skipped: tunnel absent router_uuid=%s reverse_port=%s",
                router_uuid,
                ssh_port,
            )
            return
        try:
            self._write_known_host(ssh_port, router_host_key)
            result = subprocess.run(
                [
                    *self._ssh_base_command(ssh_port),
                    "root@127.0.0.1",
                    "nohup sh -c 'sleep 1; /etc/init.d/router-support stop' "
                    ">/dev/null 2>&1 &",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                timeout=8,
                check=False,
            )
            if result.returncode != 0:
                logger.warning(
                    "router agent disconnect command failed router_uuid=%s "
                    "reverse_port=%s exit_code=%s stderr=%r",
                    router_uuid,
                    ssh_port,
                    result.returncode,
                    result.stderr[-1000:],
                )
            else:
                logger.info(
                    "router agent disconnect requested router_uuid=%s reverse_port=%s",
                    router_uuid,
                    ssh_port,
                )
        except (OSError, subprocess.TimeoutExpired, HTTPException) as error:
            logger.warning(
                "router agent disconnect failed router_uuid=%s reverse_port=%s error=%s",
                router_uuid,
                ssh_port,
                error,
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
                logger.warning(
                    "support start rejected: router offline router_uuid=%s last_seen=%s",
                    router_uuid,
                    router["last_seen"],
                )
                raise HTTPException(409, "router is offline")
            if not self.tunnel_is_listening(router["ssh_port"]):
                logger.warning(
                    "support start rejected: heartbeat active but reverse tunnel missing "
                    "router_uuid=%s router_id=%s reverse_port=%s last_seen=%s",
                    router_uuid,
                    router["id"],
                    router["ssh_port"],
                    router["last_seen"],
                )
                raise HTTPException(
                    409,
                    f"router heartbeat is active, but reverse SSH tunnel is not listening "
                    f"on 127.0.0.1:{router['ssh_port']}; check the OpenWrt router-support log",
                )
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

        logger.info(
            "support start requested router_uuid=%s router_id=%s session_id=%s "
            "reverse_port=%s luci_port=%s v2raya_port=%s app_enabled=%s",
            router_uuid,
            router_id,
            session_id,
            router["ssh_port"],
            luci_port,
            v2raya_port,
            app_enabled,
        )
        record_event(
            self.database,
            "info",
            "support_session",
            f"support start requested; session_id={session_id}, reverse_port={router['ssh_port']}",
            router_uuid,
        )

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
        ssh_errors = tempfile.TemporaryFile(mode="w+t", encoding="utf-8")
        try:
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=ssh_errors,
                start_new_session=True,
            )
        except OSError as error:
            ssh_errors.close()
            self._mark_stopped(session_id, "failed")
            logger.exception(
                "could not start support SSH process router_uuid=%s session_id=%s",
                router_uuid,
                session_id,
            )
            record_event(
                self.database,
                "error",
                "support_session",
                f"could not start SSH process; session_id={session_id}; error={error}",
                router_uuid,
            )
            raise HTTPException(
                502, f"could not start support SSH process: {error}"
            ) from error
        deadline = time.monotonic() + 5
        ready = False
        while time.monotonic() < deadline and process.poll() is None:
            try:
                with socket.create_connection(("127.0.0.1", luci_port), timeout=0.2):
                    ready = True
                    break
            except OSError:
                time.sleep(0.1)
        if not ready:
            self._terminate_process(process)
            ssh_errors.flush()
            ssh_errors.seek(0)
            stderr = ssh_errors.read(8192)
            ssh_errors.close()
            self._mark_stopped(session_id, "failed")
            detail = self._ssh_failure_detail(stderr)
            logger.error(
                "support SSH startup failed router_uuid=%s router_id=%s session_id=%s "
                "reverse_port=%s exit_code=%s detail=%s stderr=%r",
                router_uuid,
                router_id,
                session_id,
                router["ssh_port"],
                process.returncode,
                detail,
                stderr[-2000:],
            )
            record_event(
                self.database,
                "error",
                "support_session",
                f"support SSH startup failed; session_id={session_id}; {detail}",
                router_uuid,
            )
            raise HTTPException(502, detail)
        ssh_errors.close()
        self.processes[session_id] = process
        with self.database.connect() as connection:
            connection.execute(
                "UPDATE support_sessions SET process_pid = ? WHERE id = ?",
                (process.pid, session_id),
            )
        logger.info(
            "support SSH established router_uuid=%s router_id=%s session_id=%s pid=%s",
            router_uuid,
            router_id,
            session_id,
            process.pid,
        )
        record_event(
            self.database,
            "info",
            "support_session",
            f"support SSH established; session_id={session_id}, pid={process.pid}",
            router_uuid,
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
        with self.database.connect() as connection:
            router = connection.execute(
                """SELECT r.uuid FROM support_sessions s
                   JOIN routers r ON r.id = s.router_id WHERE s.id = ?""",
                (session_id,),
            ).fetchone()
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
        record_event(
            self.database,
            "info",
            "support_session",
            f"support session stopped; session_id={session_id}",
            router["uuid"] if router else None,
        )

