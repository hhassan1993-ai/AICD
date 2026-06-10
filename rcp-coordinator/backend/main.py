"""FastAPI entry point for the RCP Coordination Orchestrator.

Run: ``python main.py``  (serves on http://127.0.0.1:8000)

State is in-memory by design (no external database). Logs are kept in a
bounded ring buffer and replayed to newly connected WebSocket clients.
"""
from __future__ import annotations

import asyncio
import logging
import os
from collections import deque
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator

import uvicorn
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from agent import (
    AuthorizationError,
    OrchestrationError,
    PhaseOrderError,
    RCPCoordinationAgent,
    StateError,
)
from mcp_client import MCPClientProtocol, RevitMCPClient
from models import (
    AuthorizationRequest,
    LogEvent,
    ResetRequest,
    StateSnapshot,
)

logger = logging.getLogger("rcp.orchestrator")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

LOG_BUFFER_SIZE = 500

# "mock" (default) uses the simulated RevitMCPClient; "live" connects to the
# open-source revit-mcp Node server over stdio (see mcp_live.py for config).
MCP_MODE = os.environ.get("RCP_MCP_MODE", "mock").strip().lower()


class Hub:
    """In-memory state container + WebSocket fan-out."""

    def __init__(self) -> None:
        self.clients: set[WebSocket] = set()
        self.log_buffer: deque[LogEvent] = deque(maxlen=LOG_BUFFER_SIZE)
        # In live mode a single MCP session (and its spawned revit-mcp child
        # process) is shared across resets; only its call counters reset.
        self._live_client: Any = None
        if MCP_MODE == "live":
            from mcp_live import RevitMCPLiveClient

            self._live_client = RevitMCPLiveClient.from_env()
            logger.info("MCP mode: live (revit-mcp over stdio)")
        else:
            logger.info("MCP mode: mock")
        self.agent: RCPCoordinationAgent = self._build_agent(simulate_mismatch=False)
        self._send_lock = asyncio.Lock()

    def _build_client(self, *, simulate_mismatch: bool) -> MCPClientProtocol:
        if self._live_client is not None:
            self._live_client.reset_counts()
            return self._live_client  # type: ignore[no-any-return]
        return RevitMCPClient(simulate_coordinate_mismatch=simulate_mismatch)

    def _build_agent(self, *, simulate_mismatch: bool) -> RCPCoordinationAgent:
        client = self._build_client(simulate_mismatch=simulate_mismatch)
        return RCPCoordinationAgent(
            client,
            on_log=self.broadcast_log,
            on_state=self.broadcast_state,
            simulate_coordinate_mismatch=simulate_mismatch,
            mcp_mode="live" if self._live_client is not None else "mock",
        )

    async def shutdown(self) -> None:
        if self._live_client is not None:
            await self._live_client.aclose()

    async def reset(self, *, simulate_mismatch: bool) -> None:
        self.log_buffer.clear()
        self.agent = self._build_agent(simulate_mismatch=simulate_mismatch)
        if simulate_mismatch and self._live_client is not None:
            await self.broadcast_log(
                LogEvent(
                    level="warn",
                    source="ORCH",
                    message=(
                        "Edge Case 1 simulation has no effect in live MCP mode — "
                        "coordinates are read from the real model"
                    ),
                )
            )
        await self.broadcast_log(
            LogEvent(
                level="info",
                source="ORCH",
                message=(
                    "Pipeline reset"
                    + (" — Edge Case 1 armed: simulated survey-point mismatch" if simulate_mismatch else "")
                ),
            )
        )
        await self.broadcast_state(self.agent.snapshot())

    # ----------------------------- fan-out ----------------------------- #

    async def _send_all(self, message: dict[str, Any]) -> None:
        async with self._send_lock:
            dead: list[WebSocket] = []
            for ws in self.clients:
                try:
                    await ws.send_json(message)
                except Exception:
                    dead.append(ws)
            for ws in dead:
                self.clients.discard(ws)

    async def broadcast_log(self, event: LogEvent) -> None:
        self.log_buffer.append(event)
        await self._send_all({"type": "log", "payload": event.model_dump()})

    async def broadcast_state(self, snapshot: StateSnapshot) -> None:
        await self._send_all({"type": "state", "payload": snapshot.model_dump()})


hub = Hub()


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    logger.info("RCP Coordination Orchestrator started (in-memory state)")
    try:
        yield
    finally:
        await hub.shutdown()


app = FastAPI(title="RCP Coordination Orchestrator", version="1.0.0", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://127.0.0.1:5173"],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


def _http_error(exc: OrchestrationError) -> HTTPException:
    if isinstance(exc, PhaseOrderError):
        return HTTPException(status_code=409, detail=str(exc))
    if isinstance(exc, AuthorizationError):
        return HTTPException(status_code=422, detail=str(exc))
    if isinstance(exc, StateError):
        return HTTPException(status_code=409, detail=str(exc))
    return HTTPException(status_code=400, detail=str(exc))


@app.get("/api/state", response_model=StateSnapshot)
async def get_state() -> StateSnapshot:
    return hub.agent.snapshot()


@app.post("/api/phase/{phase}/run", status_code=202)
async def run_phase(phase: int) -> dict[str, str]:
    agent = hub.agent
    # Validate sequencing synchronously so the caller receives a 409 instead
    # of a deferred failure; execution itself streams over the WebSocket.
    try:
        if phase not in (1, 2, 3, 4, 5):
            raise PhaseOrderError(f"Unknown phase: {phase}")
        if agent.status.value in ("halted",):
            raise StateError(f"Pipeline halted: {agent.halt_reason}. Reset required.")
        if agent.status.value == "awaiting_authorization":
            raise StateError("Phase 4 awaiting HITL authorization")
        if agent.status.value == "running":
            raise StateError("A phase is already executing")
        if agent.status.value == "complete":
            raise StateError("Pipeline complete; reset to run again")
        if phase != agent.completed_phase + 1:
            raise PhaseOrderError(
                f"Phase {phase} requested but phase {agent.completed_phase + 1} is next"
            )
    except OrchestrationError as exc:
        raise _http_error(exc) from exc

    async def _execute() -> None:
        try:
            await agent.run_phase(phase)
        except OrchestrationError as exc:
            await hub.broadcast_log(LogEvent(level="error", source="ORCH", message=str(exc)))
        except Exception:
            logger.exception("Phase %s crashed", phase)

    asyncio.create_task(_execute())
    return {"status": "accepted", "phase": str(phase)}


@app.post("/api/authorize", status_code=202)
async def authorize(body: AuthorizationRequest) -> dict[str, str]:
    agent = hub.agent
    if agent.status.value != "awaiting_authorization":
        raise HTTPException(status_code=409, detail="No authorization is pending")
    # Validate id coverage synchronously for immediate 422 feedback.
    pending = {p.proposal_id for p in agent.proposals if p.status.value == "pending"}
    unknown = set(body.decisions) - pending
    missing = pending - set(body.decisions)
    if unknown or missing:
        raise HTTPException(
            status_code=422,
            detail=f"unknown={sorted(unknown)} missing={sorted(missing)}",
        )

    async def _execute() -> None:
        try:
            await agent.authorize(dict(body.decisions))
        except OrchestrationError as exc:
            await hub.broadcast_log(LogEvent(level="error", source="ORCH", message=str(exc)))
        except Exception:
            logger.exception("Authorization crashed")

    asyncio.create_task(_execute())
    return {"status": "accepted"}


@app.post("/api/reset")
async def reset(body: ResetRequest) -> dict[str, str]:
    if hub.agent.status.value == "running":
        raise HTTPException(status_code=409, detail="Cannot reset while a phase is executing")
    await hub.reset(simulate_mismatch=body.simulate_coordinate_mismatch)
    return {"status": "reset"}


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket) -> None:
    await ws.accept()
    hub.clients.add(ws)
    try:
        # Replay backlog + current state to the new client.
        await ws.send_json({"type": "state", "payload": hub.agent.snapshot().model_dump()})
        for event in list(hub.log_buffer):
            await ws.send_json({"type": "log", "payload": event.model_dump()})
        while True:
            # Server-push channel; inbound frames are ignored (keepalive only).
            await ws.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        hub.clients.discard(ws)


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="info")
