from __future__ import annotations

import asyncio
import os
import secrets
import signal
import time

from fastapi import APIRouter, Depends, HTTPException, Request, WebSocket, WebSocketDisconnect

from backend.api.routers import _require_engineer
from backend.schemas import TerminalTicketResponse

router = APIRouter(tags=["terminal"])


class TerminalTickets:
    def __init__(self):
        self.items: dict[str, tuple[str, float]] = {}

    def issue(self, router_uuid: str) -> str:
        now = time.monotonic()
        self.items = {
            ticket: value for ticket, value in self.items.items() if value[1] > now
        }
        ticket = secrets.token_urlsafe(32)
        self.items[ticket] = (router_uuid, now + 30)
        return ticket

    def consume(self, ticket: str) -> str | None:
        item = self.items.pop(ticket, None)
        if not item or item[1] <= time.monotonic():
            return None
        return item[0]


@router.post(
    "/api/routers/{router_uuid}/terminal/ticket",
    response_model=TerminalTicketResponse,
    dependencies=[Depends(_require_engineer)],
)
def create_terminal_ticket(router_uuid: str, request: Request):
    # Validate access and active session before issuing a browser credential.
    request.app.state.session_manager.terminal_spec(router_uuid)
    ticket = request.app.state.terminal_tickets.issue(router_uuid)
    return TerminalTicketResponse(ticket=ticket)


@router.websocket("/api/terminal/{ticket}")
async def terminal_socket(websocket: WebSocket, ticket: str):
    router_uuid = websocket.app.state.terminal_tickets.consume(ticket)
    if not router_uuid:
        await websocket.close(code=4401)
        return
    try:
        session_id, command = websocket.app.state.session_manager.terminal_spec(router_uuid)
    except HTTPException:
        await websocket.close(code=4403)
        return
    await websocket.accept()
    process = await asyncio.create_subprocess_exec(
        *command,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        start_new_session=True,
    )
    websocket.app.state.session_manager.register_terminal(session_id, process)

    async def ssh_to_browser():
        while True:
            data = await process.stdout.read(4096)
            if not data:
                break
            await websocket.send_text(data.decode("utf-8", errors="replace"))

    async def browser_to_ssh():
        while True:
            data = await websocket.receive_text()
            process.stdin.write(data.encode())
            await process.stdin.drain()

    tasks = [asyncio.create_task(ssh_to_browser()), asyncio.create_task(browser_to_ssh())]
    try:
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
    except WebSocketDisconnect:
        pass
    finally:
        for task in tasks:
            task.cancel()
        if process.returncode is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(process.wait(), timeout=2)
            except asyncio.TimeoutError:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        websocket.app.state.session_manager.unregister_terminal(session_id, process)
        try:
            await websocket.close()
        except RuntimeError:
            pass

