"""Domain models for the RCP Coordination Orchestrator.

All spatial values are ISO units: metres (m). Serialization keeps full float
precision; 3-decimal formatting is a presentation concern (frontend).
"""
from __future__ import annotations

import math
import time
import uuid
from enum import IntEnum, StrEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, StrictBool

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

COORDINATE_TOLERANCE_M: float = 0.001  # Phase 1 hard-halt threshold (metres)


# --------------------------------------------------------------------------- #
# Enums
# --------------------------------------------------------------------------- #

class Phase(IntEnum):
    INGESTION = 1
    CLASH_DETECTION = 2
    RECONCILIATION = 3
    RESOLUTION_ROUTING = 4
    DOCUMENTATION = 5


PHASE_NAMES: dict[Phase, str] = {
    Phase.INGESTION: "Model Ingestion & Coordinate Validation",
    Phase.CLASH_DETECTION: "Clash Detection",
    Phase.RECONCILIATION: "2D/3D Reconciliation",
    Phase.RESOLUTION_ROUTING: "Resolution Routing (HITL)",
    Phase.DOCUMENTATION: "Documentation & Annotation",
}


class AgentStatus(StrEnum):
    IDLE = "idle"
    RUNNING = "running"
    AWAITING_AUTHORIZATION = "awaiting_authorization"
    HALTED = "halted"
    COMPLETE = "complete"
    ERROR = "error"


class ProposalStatus(StrEnum):
    PENDING = "pending"
    APPROVED = "approved"
    REJECTED = "rejected"
    APPLIED = "applied"


# --------------------------------------------------------------------------- #
# Spatial primitives
# --------------------------------------------------------------------------- #

class Coordinate(BaseModel):
    """Cartesian coordinate in metres (project shared coordinate system)."""

    model_config = ConfigDict(frozen=True)

    x: float = Field(description="Easting (m)")
    y: float = Field(description="Northing (m)")
    z: float = Field(description="Elevation (m)")

    def distance_to(self, other: "Coordinate") -> float:
        return math.sqrt(
            (self.x - other.x) ** 2
            + (self.y - other.y) ** 2
            + (self.z - other.z) ** 2
        )

    def shifted(self, dx: float, dy: float, dz: float) -> "Coordinate":
        return Coordinate(x=self.x + dx, y=self.y + dy, z=self.z + dz)


# --------------------------------------------------------------------------- #
# Aggregates
# --------------------------------------------------------------------------- #

class ModelInfo(BaseModel):
    model_id: str
    name: str
    discipline: Literal["ARC", "STR", "MEP"]
    survey_point: Coordinate
    deviation_m: float = Field(ge=0.0)
    within_tolerance: bool


class ClashResult(BaseModel):
    clash_id: str
    element_a_id: str
    element_a_name: str
    element_b_id: str
    element_b_name: str
    category_a: str
    category_b: str
    location: Coordinate
    penetration_depth_m: float = Field(ge=0.0)
    severity: Literal["critical", "major", "minor"]


class ResolutionProposal(BaseModel):
    proposal_id: str = Field(default_factory=lambda: f"RP-{uuid.uuid4().hex[:8].upper()}")
    clash_id: str
    element_id: str
    element_name: str
    current_location: Coordinate
    proposed_location: Coordinate
    shift_vector: Coordinate
    rationale: str
    status: ProposalStatus = ProposalStatus.PENDING


class LogEvent(BaseModel):
    ts: float = Field(default_factory=time.time)
    level: Literal["info", "warn", "error", "ok", "mcp"]
    source: str
    message: str


class PhaseRecord(BaseModel):
    phase: Phase
    name: str
    status: Literal["pending", "running", "complete", "halted", "skipped_locked"]


class StateSnapshot(BaseModel):
    status: AgentStatus
    current_phase: int  # 0 = none started
    completed_phase: int  # highest phase fully completed (0..5)
    halt_reason: str | None
    phases: list[PhaseRecord]
    models: list[ModelInfo]
    clashes: list[ClashResult]
    proposals: list[ResolutionProposal]
    mcp_call_counts: dict[str, int]
    simulate_coordinate_mismatch: bool


# --------------------------------------------------------------------------- #
# API payloads
# --------------------------------------------------------------------------- #

class AuthorizationRequest(BaseModel):
    """HITL gate payload. Values MUST be strict booleans — no truthy coercion."""

    decisions: dict[str, StrictBool]


class ResetRequest(BaseModel):
    simulate_coordinate_mismatch: bool = False


class ApiError(BaseModel):
    detail: str
