from __future__ import annotations

import json
import re
from datetime import UTC, datetime
from urllib.parse import quote

import httpx
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, Response

from backend.security import tokens_match


HOP_HEADERS = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "content-encoding",
    "content-length",
}

AUTH_PAGE = """<!doctype html><meta charset=utf-8><title>Подключение</title>
<body style="font:16px system-ui;background:#0b1015;color:#edf5f2;padding:40px">
<p id=s>Проверка доступа…</p><script>
const token=location.hash.slice(1);fetch('/_router_support/auth',{method:'POST',
headers:{'content-type':'application/json'},body:JSON.stringify({token})})
.then(r=>{if(!r.ok)throw Error('Доступ запрещён');location.replace('/')})
.catch(e=>document.querySelector('#s').textContent=e.message);
</script></body>"""


class SupportProxyMiddleware:
    def __init__(self, app, database, settings):
        self.app = app
        self.database = database
        self.settings = settings
        domain = re.escape(settings.public_base_domain.lower())
        self.host_pattern = re.compile(
            rf"^(luci|v2raya|app)-r(\d+)\.{domain}(?::\d+)?$"
        )
        self.client = httpx.AsyncClient(follow_redirects=False, timeout=30)

    def _session(self, router_id: int):
        with self.database.connect() as connection:
            return connection.execute(
                """SELECT * FROM support_sessions
                   WHERE router_id = ? AND status = 'active'
                   ORDER BY id DESC LIMIT 1""",
                (router_id,),
            ).fetchone()

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        request = Request(scope, receive)
        host = request.headers.get("host", "").lower()
        matched = self.host_pattern.match(host)
        if not matched:
            await self.app(scope, receive, send)
            return
        service, router_id_text = matched.groups()
        router_id = int(router_id_text)
        session = self._session(router_id)
        if not session or datetime.fromisoformat(session["expires_at"]) <= datetime.now(UTC):
            await Response("Support session is not active", status_code=403)(scope, receive, send)
            return

        if request.url.path == "/_router_support/auth":
            if request.method == "GET":
                await HTMLResponse(AUTH_PAGE)(scope, receive, send)
                return
            try:
                payload = json.loads((await request.body()) or b"{}")
                token = payload.get("token", "")
            except (ValueError, AttributeError):
                token = ""
            if not tokens_match(
                token, session["token_digest"], self.settings.device_token_pepper
            ):
                await JSONResponse({"detail": "invalid session token"}, status_code=401)(
                    scope, receive, send
                )
                return
            response = JSONResponse({"ok": True})
            response.set_cookie(
                "rs_access", token, httponly=True, secure=True, samesite="lax",
                max_age=self.settings.support_session_seconds,
            )
            await response(scope, receive, send)
            return

        token = request.cookies.get("rs_access", "")
        if not tokens_match(token, session["token_digest"], self.settings.device_token_pepper):
            await Response("Support authorization required", status_code=401)(scope, receive, send)
            return

        port = session[f"{service}_port"]
        query = request.url.query
        target = f"http://127.0.0.1:{port}{request.url.path}"
        if query:
            target += f"?{query}"
        body = await request.body()
        headers = {
            key: value
            for key, value in request.headers.items()
            if key.lower() not in HOP_HEADERS and key.lower() not in {"host", "cookie"}
        }
        upstream = await self.client.request(
            request.method, target, content=body, headers=headers
        )
        response_headers = {
            key: value
            for key, value in upstream.headers.items()
            if key.lower() not in HOP_HEADERS
        }
        await Response(
            content=upstream.content,
            status_code=upstream.status_code,
            headers=response_headers,
        )(scope, receive, send)

