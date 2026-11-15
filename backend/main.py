from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from backend.api.routers import router as routers_router
from backend.api.sessions import router as sessions_router
from backend.api.terminal import TerminalTickets, router as terminal_router
from backend.config import Settings
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
        async def cleanup_sessions():
            while True:
                await asyncio.sleep(30)
                session_manager.cleanup_expired()

        cleanup_task = asyncio.create_task(cleanup_sessions())
        try:
            yield
        finally:
            cleanup_task.cancel()
            try:
                await cleanup_task
            except asyncio.CancelledError:
                pass

    app = FastAPI(title="Router Support Panel", version="0.1.0", lifespan=lifespan)
    app.state.settings = configured
    app.state.database = database
    app.state.session_manager = session_manager
    app.state.terminal_tickets = TerminalTickets()
    app.include_router(routers_router)
    app.include_router(sessions_router)
    app.include_router(terminal_router)
    app.add_middleware(
        SupportProxyMiddleware,
        database=database,
        settings=configured,
    )

    @app.get("/healthz", tags=["system"])
    def healthcheck():
        return {"status": "ok"}

    frontend = Path(__file__).resolve().parent.parent / "frontend"
    if frontend.is_dir():
        app.mount("/", StaticFiles(directory=frontend, html=True), name="frontend")

    return app


app = create_app()

