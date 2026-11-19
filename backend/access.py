from __future__ import annotations

import threading
import time
from collections import defaultdict, deque
from ipaddress import IPv4Address, ip_address

from starlette.responses import PlainTextResponse


PUBLIC_PATHS = {
    "/healthz",
    "/api/routers/register",
    "/api/routers/heartbeat",
}


def external_client_ip(scope) -> IPv4Address | None:
    client = scope.get("client")
    if not client:
        return None
    try:
        peer = ip_address(client[0])
    except ValueError:
        return None

    # Uvicorn is bound to loopback. Only its local reverse proxy is trusted to
    # supply X-Forwarded-For; the last address is the one Apache appended.
    if peer.is_loopback:
        forwarded_values = [
            value.decode("latin-1")
            for name, value in scope.get("headers", [])
            if name.lower() == b"x-forwarded-for"
        ]
        if forwarded_values:
            candidate = forwarded_values[-1].split(",")[-1].strip()
            try:
                forwarded = ip_address(candidate)
            except ValueError:
                return None
            if isinstance(forwarded, IPv4Address):
                return forwarded
            return None
    return peer if isinstance(peer, IPv4Address) else None


class PanelAccessMiddleware:
    def __init__(self, app, settings):
        self.app = app
        self.allowed_networks = settings.panel_allowed_networks

    async def __call__(self, scope, receive, send):
        if scope["type"] not in {"http", "websocket"}:
            await self.app(scope, receive, send)
            return
        path = scope.get("path", "").rstrip("/") or "/"
        if path in PUBLIC_PATHS:
            await self.app(scope, receive, send)
            return
        client_ip = external_client_ip(scope)
        if client_ip is not None and any(
            client_ip in network for network in self.allowed_networks
        ):
            await self.app(scope, receive, send)
            return
        if scope["type"] == "websocket":
            await send({"type": "websocket.close", "code": 4403})
            return
        await PlainTextResponse(
            "Panel access is forbidden from this IP address",
            status_code=403,
            headers={"Cache-Control": "no-store"},
        )(scope, receive, send)


class LoginAttemptLimiter:
    max_failures = 5
    failure_window_seconds = 300
    block_seconds = 300
    max_tracked_ips = 10_000

    def __init__(self):
        self._failures: dict[str, deque[float]] = defaultdict(deque)
        self._blocked_until: dict[str, float] = {}
        self._lock = threading.Lock()

    def retry_after(self, client_ip: str, now: float | None = None) -> int:
        current = time.monotonic() if now is None else now
        with self._lock:
            blocked_until = self._blocked_until.get(client_ip, 0)
            if blocked_until <= current:
                self._blocked_until.pop(client_ip, None)
                return 0
            return max(1, int(blocked_until - current + 0.999))

    def record_failure(self, client_ip: str, now: float | None = None) -> int:
        current = time.monotonic() if now is None else now
        cutoff = current - self.failure_window_seconds
        with self._lock:
            if client_ip not in self._failures and len(self._failures) >= self.max_tracked_ips:
                oldest_ip = next(iter(self._failures))
                self._failures.pop(oldest_ip, None)
                self._blocked_until.pop(oldest_ip, None)
            failures = self._failures[client_ip]
            while failures and failures[0] <= cutoff:
                failures.popleft()
            failures.append(current)
            if len(failures) < self.max_failures:
                return 0
            failures.clear()
            self._blocked_until[client_ip] = current + self.block_seconds
            return self.block_seconds

    def record_success(self, client_ip: str) -> None:
        with self._lock:
            self._failures.pop(client_ip, None)
            self._blocked_until.pop(client_ip, None)
