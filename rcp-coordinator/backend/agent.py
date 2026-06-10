"""RCPCoordinationAgent — deterministic 5-phase orchestration state machine.

Invariants enforced here (not in the UI):
  1. Phases run strictly sequentially: phase N requires completed_phase == N-1.
  2. All spatial data is processed in metres.
  3. Phase 4 pauses; ``update_element_location`` is called only for proposals
     carrying an explicit boolean ``True`` decision from the frontend payload.
  4. Phase 1 hard-halts if any model's survey-point deviation > 0.001 m.
"""
from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from typing import Any

from mcp_client import BASE_SURVEY_POINT, MCPClientProtocol
from models import (
    COORDINATE_TOLERANCE_M,
    PHASE_NAMES,
    AgentStatus,
    ClashResult,
    Coordinate,
    LogEvent,
    ModelInfo,
    Phase,
    PhaseRecord,
    ProposalStatus,
    ResolutionProposal,
    StateSnapshot,
)

EventSink = Callable[[LogEvent], Awaitable[None]]
StateSink = Callable[[StateSnapshot], Awaitable[None]]

MODEL_REGISTRY: tuple[tuple[str, str, str], ...] = (
    ("i125-UAE044106-ARC", "Ghaf Woods P13 — Architecture", "ARC"),
    ("i125-UAE044106-STR", "Ghaf Woods P13 — Structure", "STR"),
    ("i125-UAE044106-MEP", "Ghaf Woods P13 — MEP", "MEP"),
)

CLEARANCE_M = 0.025  # additional clearance applied beyond penetration depth


class OrchestrationError(Exception):
    """Base class for orchestration violations (mapped to HTTP 4xx)."""


class PhaseOrderError(OrchestrationError):
    """Phase requested out of sequence."""


class StateError(OrchestrationError):
    """Operation invalid in the current agent status."""


class AuthorizationError(OrchestrationError):
    """Invalid HITL authorization payload."""


class RCPCoordinationAgent:
    def __init__(
        self,
        client: MCPClientProtocol,
        *,
        on_log: EventSink,
        on_state: StateSink,
        simulate_coordinate_mismatch: bool = False,
    ) -> None:
        self._client = client
        self._on_log = on_log
        self._on_state = on_state
        self._lock = asyncio.Lock()
        self._simulate_mismatch = simulate_coordinate_mismatch

        self.status: AgentStatus = AgentStatus.IDLE
        self.current_phase: int = 0
        self.completed_phase: int = 0
        self.halt_reason: str | None = None
        self.models: list[ModelInfo] = []
        self.clashes: list[ClashResult] = []
        self.proposals: list[ResolutionProposal] = []

    # ------------------------------------------------------------------ #
    # Snapshot / telemetry
    # ------------------------------------------------------------------ #

    def snapshot(self) -> StateSnapshot:
        phases: list[PhaseRecord] = []
        for p in Phase:
            if self.status == AgentStatus.HALTED and p > self.completed_phase:
                st = "skipped_locked" if p != self.current_phase else "halted"
            elif p <= self.completed_phase:
                st = "complete"
            elif p == self.current_phase and self.status in (
                AgentStatus.RUNNING,
                AgentStatus.AWAITING_AUTHORIZATION,
            ):
                st = "running"
            else:
                st = "pending"
            phases.append(PhaseRecord(phase=p, name=PHASE_NAMES[p], status=st))  # type: ignore[arg-type]
        return StateSnapshot(
            status=self.status,
            current_phase=self.current_phase,
            completed_phase=self.completed_phase,
            halt_reason=self.halt_reason,
            phases=phases,
            models=self.models,
            clashes=self.clashes,
            proposals=self.proposals,
            mcp_call_counts=dict(self._client.call_counts),
            simulate_coordinate_mismatch=self._simulate_mismatch,
        )

    async def _log(self, level: str, source: str, message: str) -> None:
        await self._on_log(LogEvent(level=level, source=source, message=message))  # type: ignore[arg-type]

    async def _push_state(self) -> None:
        await self._on_state(self.snapshot())

    @staticmethod
    def _m(value: float) -> str:
        """Format a metre value to 3 decimal places (display convention)."""
        return f"{value:.3f}"

    # ------------------------------------------------------------------ #
    # Phase dispatch — sequential enforcement
    # ------------------------------------------------------------------ #

    async def run_phase(self, phase: int) -> None:
        if phase not in (1, 2, 3, 4, 5):
            raise PhaseOrderError(f"Unknown phase: {phase}")
        if self._lock.locked():
            raise StateError("A phase is already executing; concurrent execution is prohibited")
        async with self._lock:
            if self.status == AgentStatus.HALTED:
                raise StateError(f"Pipeline halted: {self.halt_reason}. Reset required.")
            if self.status == AgentStatus.AWAITING_AUTHORIZATION:
                raise StateError("Phase 4 is awaiting HITL authorization; submit decisions first")
            if self.status == AgentStatus.COMPLETE:
                raise StateError("Pipeline already complete; reset to run again")
            if phase != self.completed_phase + 1:
                raise PhaseOrderError(
                    f"Phase {phase} requested but phase {self.completed_phase + 1} is next. "
                    "Sequential execution is enforced."
                )

            self.current_phase = phase
            self.status = AgentStatus.RUNNING
            await self._log("info", "ORCH", f"── PHASE {phase}: {PHASE_NAMES[Phase(phase)]} ──")
            await self._push_state()

            try:
                handler = {
                    1: self._phase_1_ingestion,
                    2: self._phase_2_clash_detection,
                    3: self._phase_3_reconciliation,
                    4: self._phase_4_resolution_routing,
                    5: self._phase_5_documentation,
                }[phase]
                await handler()
            except OrchestrationError:
                raise
            except Exception as exc:  # MCP/transport failures
                self.status = AgentStatus.ERROR
                await self._log("error", "ORCH", f"Phase {phase} failed: {exc}")
                await self._push_state()
                raise

    # ------------------------------------------------------------------ #
    # Phase 1 — Ingestion & coordinate validation (hard halt > 0.001 m)
    # ------------------------------------------------------------------ #

    async def _phase_1_ingestion(self) -> None:
        self.models = []
        base = BASE_SURVEY_POINT
        await self._log(
            "info", "ORCH",
            f"Validating shared coordinates against base survey point "
            f"E {self._m(base.x)} / N {self._m(base.y)} / EL {self._m(base.z)} m "
            f"(tolerance {COORDINATE_TOLERANCE_M:.3f} m)",
        )
        for model_id, name, discipline in MODEL_REGISTRY:
            await self._log("mcp", "MCP", f"read_model_coordinates(model_id={model_id})")
            result = await self._client.call_tool(
                "read_model_coordinates", {"model_id": model_id}
            )
            sp = Coordinate.model_validate(result["survey_point"])
            deviation = sp.distance_to(base)
            within = deviation <= COORDINATE_TOLERANCE_M
            self.models.append(
                ModelInfo(
                    model_id=model_id,
                    name=name,
                    discipline=discipline,  # type: ignore[arg-type]
                    survey_point=sp,
                    deviation_m=deviation,
                    within_tolerance=within,
                )
            )
            level = "ok" if within else "error"
            await self._log(
                level, "ORCH",
                f"{model_id}: deviation {self._m(deviation)} m "
                f"({'WITHIN' if within else 'EXCEEDS'} tolerance {COORDINATE_TOLERANCE_M:.3f} m)",
            )
            await self._push_state()

            if not within:
                self.halt_reason = (
                    f"Coordinate deviation {self._m(deviation)} m on {model_id} exceeds "
                    f"hard tolerance {COORDINATE_TOLERANCE_M:.3f} m"
                )
                self.status = AgentStatus.HALTED
                await self._log("error", "ORCH", f"HARD HALT — {self.halt_reason}")
                await self._log("error", "ORCH", "Subsequent phases are locked. Reset required.")
                await self._push_state()
                return

        self.completed_phase = 1
        self.status = AgentStatus.IDLE
        await self._log("ok", "ORCH", "Phase 1 complete — all models within coordinate tolerance")
        await self._push_state()

    # ------------------------------------------------------------------ #
    # Phase 2 — Clash detection
    # ------------------------------------------------------------------ #

    async def _phase_2_clash_detection(self) -> None:
        await self._log(
            "mcp", "MCP",
            "execute_clash_detection(set_a='RCP Elements', set_b='Structural Framing')",
        )
        result = await self._client.call_tool(
            "execute_clash_detection",
            {"set_a": "RCP Elements", "set_b": "Structural Framing", "units": "m"},
        )
        self.clashes = [ClashResult.model_validate(c) for c in result["clashes"]]
        for c in self.clashes:
            await self._log(
                "warn", "ORCH",
                f"{c.clash_id} [{c.severity.upper()}] {c.element_a_name} ⟂ {c.element_b_name} — "
                f"penetration {self._m(c.penetration_depth_m)} m @ "
                f"({self._m(c.location.x)}, {self._m(c.location.y)}, {self._m(c.location.z)})",
            )
        self.completed_phase = 2
        self.status = AgentStatus.IDLE
        await self._log("ok", "ORCH", f"Phase 2 complete — {len(self.clashes)} clash(es) registered")
        await self._push_state()

    # ------------------------------------------------------------------ #
    # Phase 3 — 2D/3D reconciliation → resolution proposals
    # ------------------------------------------------------------------ #

    async def _phase_3_reconciliation(self) -> None:
        await self._log("mcp", "MCP", "read_pdf_dwg_metadata(sheet_number=i125-UAE044106-STR-RCP-B01-101)")
        meta = await self._client.call_tool(
            "read_pdf_dwg_metadata", {"sheet_number": "i125-UAE044106-STR-RCP-B01-101"}
        )
        ceiling_el = float(meta["annotated_ceiling_elevation_m"])
        await self._log(
            "info", "ORCH",
            f"Sheet {meta['sheet_number']} rev {meta['revision']} — annotated ceiling "
            f"elevation {self._m(ceiling_el)} m; DWG/PDF pair verified: {meta['dwg_pdf_pair_verified']}",
        )

        self.proposals = []
        for c in self.clashes:
            # Resolution strategy: drop the RCP element along -Z by penetration
            # depth + clearance, then clamp to the 2D annotated ceiling
            # elevation if the drop would pass below it.
            dz = -(c.penetration_depth_m + CLEARANCE_M)
            proposed = c.location.shifted(0.0, 0.0, dz)
            if proposed.z < ceiling_el:
                proposed = Coordinate(x=proposed.x, y=proposed.y, z=ceiling_el)
                dz = proposed.z - c.location.z
            shift = Coordinate(x=0.0, y=0.0, z=dz)
            self.proposals.append(
                ResolutionProposal(
                    clash_id=c.clash_id,
                    element_id=c.element_a_id,
                    element_name=c.element_a_name,
                    current_location=c.location,
                    proposed_location=proposed,
                    shift_vector=shift,
                    rationale=(
                        f"Lower {c.element_a_name} by {abs(dz):.3f} m to clear "
                        f"{c.element_b_name} (penetration {c.penetration_depth_m:.3f} m "
                        f"+ {CLEARANCE_M:.3f} m clearance), clamped to RCP annotated "
                        f"ceiling EL {ceiling_el:.3f} m"
                    ),
                )
            )
        for p in self.proposals:
            await self._log(
                "info", "ORCH",
                f"{p.proposal_id} → {p.element_name}: ΔZ {self._m(p.shift_vector.z)} m "
                f"(EL {self._m(p.current_location.z)} → {self._m(p.proposed_location.z)})",
            )
        self.completed_phase = 3
        self.status = AgentStatus.IDLE
        await self._log("ok", "ORCH", f"Phase 3 complete — {len(self.proposals)} proposal(s) generated")
        await self._push_state()

    # ------------------------------------------------------------------ #
    # Phase 4 — Resolution routing: HITL gate
    # ------------------------------------------------------------------ #

    async def _phase_4_resolution_routing(self) -> None:
        if not self.proposals:
            await self._log("warn", "ORCH", "No proposals to route; Phase 4 completes as no-op")
            self.completed_phase = 4
            self.status = AgentStatus.IDLE
            await self._push_state()
            return
        self.status = AgentStatus.AWAITING_AUTHORIZATION
        await self._log(
            "warn", "ORCH",
            f"EXECUTION PAUSED — {len(self.proposals)} proposal(s) require explicit human "
            "authorization. update_element_location is gated on boolean True per proposal.",
        )
        await self._push_state()
        # Phase 4 completes only via authorize().

    async def authorize(self, decisions: dict[str, bool]) -> None:
        if self._lock.locked():
            raise StateError("A phase is already executing")
        async with self._lock:
            if self.status != AgentStatus.AWAITING_AUTHORIZATION:
                raise StateError("No authorization is pending")

            pending_ids = {p.proposal_id for p in self.proposals if p.status == ProposalStatus.PENDING}
            unknown = set(decisions) - pending_ids
            missing = pending_ids - set(decisions)
            if unknown:
                raise AuthorizationError(f"Unknown proposal id(s): {sorted(unknown)}")
            if missing:
                raise AuthorizationError(
                    f"Decision missing for proposal id(s): {sorted(missing)}. "
                    "Every pending proposal requires an explicit boolean decision."
                )

            applied = 0
            for p in self.proposals:
                decision = decisions[p.proposal_id]
                if decision is not True:
                    p.status = ProposalStatus.REJECTED
                    await self._log("warn", "HITL", f"{p.proposal_id} REJECTED — element {p.element_id} unchanged")
                    await self._push_state()
                    continue
                p.status = ProposalStatus.APPROVED
                await self._log("ok", "HITL", f"{p.proposal_id} APPROVED (authorization=True)")
                await self._log(
                    "mcp", "MCP",
                    f"update_element_location(element_id={p.element_id}, "
                    f"new_location=({self._m(p.proposed_location.x)}, "
                    f"{self._m(p.proposed_location.y)}, {self._m(p.proposed_location.z)}))",
                )
                await self._client.call_tool(
                    "update_element_location",
                    {
                        "element_id": p.element_id,
                        "new_location": p.proposed_location.model_dump(),
                        "authorized": True,
                    },
                )
                p.status = ProposalStatus.APPLIED
                applied += 1
                await self._push_state()

            self.completed_phase = 4
            self.status = AgentStatus.IDLE
            await self._log(
                "ok", "ORCH",
                f"Phase 4 complete — {applied} applied, {len(self.proposals) - applied} rejected. "
                f"update_element_location calls this session: "
                f"{self._client.call_counts['update_element_location']}",
            )
            await self._push_state()

    # ------------------------------------------------------------------ #
    # Phase 5 — Documentation & annotation
    # ------------------------------------------------------------------ #

    async def _phase_5_documentation(self) -> None:
        applied = [p for p in self.proposals if p.status == ProposalStatus.APPLIED]
        if not applied:
            await self._log(
                "info", "ORCH",
                "No applied relocations — documentation limited to clash register export. "
                f"update_element_location call count remains "
                f"{self._client.call_counts['update_element_location']}.",
            )
        for p in applied:
            await self._log("mcp", "MCP", f"create_tag_and_dimension(element_id={p.element_id})")
            await self._client.call_tool(
                "create_tag_and_dimension",
                {"element_id": p.element_id, "view": "RCP-B01-Z1"},
            )
            await self._log("ok", "ORCH", f"Tag + dimension placed for {p.element_name}")
            await self._push_state()
        self.completed_phase = 5
        self.status = AgentStatus.COMPLETE
        await self._log("ok", "ORCH", "Phase 5 complete — pipeline finished")
        await self._push_state()
