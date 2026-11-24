from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import FileResponse, RedirectResponse

from backend.access import LoginAttemptLimiter, PanelAccessMiddleware
from backend.api.auth import router as auth_router
from backend.api.logs import router as logs_router
from backend.api.routers import router as routers_router
from backend.api.sessions import router as sessions_router
from backend.api.terminal import TerminalTickets, router as terminal_router
from backend.config import Settings
from backend.auth import ENGINEER_COOKIE, valid_engineer_cookie
from backend.database import Database
from backend.proxy import SupportProxyMiddleware
from backend.services.session_manager import SessionManager


def create_app(settings: Settings | None = None) -> FastAPI:
    configured = settings or Settings.from_env()
    database = Database(configured.database_path)
    session_manager = SessionManager(database, configured)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        database.initialize()
        session_manager.mark_interrupted_sessions()
        session_manager.monitor_router_connections()
        async def cleanup_sessions():
            while True:
                await asyncio.sleep(30)
                session_manager.cleanup_expired()
                session_manager.monitor_router_connections()

        cleanup_task = asyncio.create_task(cleanup_sessions())
        try:
            yield
        finally:
            cleanup_task.cancel()
            try:
                await cleanup_task
            except asyncio.CancelledError:
                pass

    app = FastAPI(
        title="Router Support Panel",
        version="0.1.0",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.state.settings = configured
    app.state.database = database
    app.state.session_manager = session_manager
    app.state.terminal_tickets = TerminalTickets()
    app.state.login_attempt_limiter = LoginAttemptLimiter()
    app.include_router(auth_router)
    app.include_router(logs_router)
    app.include_router(routers_router)
    app.include_router(sessions_router)
    app.include_router(terminal_router)
    app.add_middleware(
        SupportProxyMiddleware,
        database=database,
        settings=configured,
    )
    app.add_middleware(PanelAccessMiddleware, settings=configured)

    @app.get("/healthz", tags=["system"])
    def healthcheck():
        return {"status": "ok"}

    frontend = Path(__file__).resolve().parent.parent / "frontend"
    if frontend.is_dir():
        @app.get("/login", include_in_schema=False)
        def login_page():
            return FileResponse(
                frontend / "login.html", headers={"Cache-Control": "no-store"}
            )

        @app.get("/login.js", include_in_schema=False)
        def login_script():
            return FileResponse(
                frontend / "login.js", headers={"Cache-Control": "no-store"}
            )

        def redirect_to_login():
            response = RedirectResponse("/login", status_code=303)
            response.headers["Cache-Control"] = "no-store"
            response.delete_cookie(
                ENGINEER_COOKIE,
                httponly=True,
                secure=True,
                samesite="strict",
                path="/",
            )
            return response

        def protected_file(request: Request, filename: str):
            cookie = request.cookies.get(ENGINEER_COOKIE)
            if not cookie:
                if filename == "index.html":
                    return redirect_to_login()
                raise HTTPException(
                    status.HTTP_403_FORBIDDEN,
                    "engineer access denied",
                    headers={"Cache-Control": "no-store"},
                )
            if not valid_engineer_cookie(cookie, request.app.state.settings):
                if filename == "index.html":
                    return redirect_to_login()
                raise HTTPException(
                    status.HTTP_403_FORBIDDEN,
                    "engineer access denied",
                    headers={"Cache-Control": "no-store"},
                )
            return FileResponse(
                frontend / filename, headers={"Cache-Control": "no-store"}
            )

        @app.get("/", include_in_schema=False)
        def index(request: Request):
            return protected_file(request, "index.html")

        @app.get("/index.html", include_in_schema=False)
        def index_html(request: Request):
            return protected_file(request, "index.html")

        @app.get("/app.js", include_in_schema=False)
        def app_script(request: Request):
            return protected_file(request, "app.js")

        @app.get("/styles.css", include_in_schema=False)
        def styles(request: Request):
            return protected_file(request, "styles.css")

    return app


app = create_app()

