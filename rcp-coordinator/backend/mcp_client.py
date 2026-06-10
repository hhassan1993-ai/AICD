"""Mocked Revit MCP client.

Simulates the tool surface of a Revit MCP server with realistic latency
(0.5 s – 2.0 s per call by default) and deterministic mock payloads.

The interface mirrors the MCP ``ClientSession.call_tool(name, arguments)``
contract so this class can be swapped for a real ``mcp`` SDK session
(`mcp.client.session.ClientSession`) without changing the orchestrator.
"""
from __future__ import annotations

import asyncio
import random
from typing import Any, Protocol

from models import Coordinate

# Project shared-coordinate base point (Ghaf Woods P13 — mock values, metres).
BASE_SURVEY_POINT = Coordinate(x=251_837.420, y=2_786_412.950, z=14.750)

TOOL_NAMES: tuple[str, ...] = (
    "read_model_coordinates",
    "execute_clash_detection",
    "read_pdf_dwg_metadata",
    "update_element_location",
    "create_tag_and_dimension",
)


class MCPClientProtocol(Protocol):
    """Structural type for any MCP-compatible client (real or mocked)."""

    call_counts: dict[str, int]

    async def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]: ...


class MCPToolError(RuntimeError):
    """Raised when a tool call fails or an unknown tool is requested."""


class RevitMCPClient:
    """Mock implementation of the Revit MCP tool surface."""

    def __init__(
        self,
        *,
        latency_range: tuple[float, float] = (0.5, 2.0),
        simulate_coordinate_mismatch: bool = False,
        timeout_s: float = 10.0,
        rng_seed: int | None = None,
    ) -> None:
        if latency_range[0] < 0 or latency_range[1] < latency_range[0]:
            raise ValueError("latency_range must be (min, max) with 0 <= min <= max")
        self._latency_range = latency_range
        self._timeout_s = timeout_s
        self._simulate_mismatch = simulate_coordinate_mismatch
        self._rng = random.Random(rng_seed)
        self.call_counts: dict[str, int] = {name: 0 for name in TOOL_NAMES}

    # ------------------------------------------------------------------ #
    # Public MCP-compatible entry point
    # ------------------------------------------------------------------ #

    async def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name not in TOOL_NAMES:
            raise MCPToolError(f"Unknown MCP tool: {name!r}")
        self.call_counts[name] += 1
        handler = getattr(self, f"_tool_{name}")
        try:
            async with asyncio.timeout(self._timeout_s):
                await self._simulate_latency()
                result: dict[str, Any] = handler(arguments)
                return result
        except TimeoutError as exc:
            raise MCPToolError(f"MCP tool {name!r} timed out after {self._timeout_s:.1f}s") from exc

    async def _simulate_latency(self) -> None:
        await asyncio.sleep(self._rng.uniform(*self._latency_range))

    # ------------------------------------------------------------------ #
    # Tool implementations (mock payloads)
    # ------------------------------------------------------------------ #

    def _tool_read_model_coordinates(self, arguments: dict[str, Any]) -> dict[str, Any]:
        model_id = str(arguments.get("model_id", ""))
        if not model_id:
            raise MCPToolError("read_model_coordinates requires 'model_id'")

        # Nominal survey-point reporting noise: ±0.0002 m.
        def jitter() -> float:
            return self._rng.uniform(-0.0002, 0.0002)

        sp = BASE_SURVEY_POINT.shifted(jitter(), jitter(), jitter())

        # Edge Case 1: the MEP model reports a survey point displaced by
        # ~4.2 mm — exceeds the 0.001 m tolerance and must hard-halt Phase 1.
        if self._simulate_mismatch and model_id.endswith("MEP"):
            sp = BASE_SURVEY_POINT.shifted(0.0030, -0.0028, 0.0008)

        return {
            "model_id": model_id,
            "survey_point": sp.model_dump(),
            "project_base_point": BASE_SURVEY_POINT.model_dump(),
            "units": "m",
        }

    def _tool_execute_clash_detection(self, arguments: dict[str, Any]) -> dict[str, Any]:
        return {
            "units": "m",
            "clashes": [
                {
                    "clash_id": "CL-0001",
                    "element_a_id": "RVT-553102",
                    "element_a_name": "Light Fixture LF-23 (600x600 LED)",
                    "element_b_id": "RVT-118447",
                    "element_b_name": "RC Beam B-114 (300x600)",
                    "category_a": "Lighting Fixtures",
                    "category_b": "Structural Framing",
                    "location": {"x": 251_842.115, "y": 2_786_420.338, "z": 17.450},
                    "penetration_depth_m": 0.045,
                    "severity": "critical",
                },
                {
                    "clash_id": "CL-0002",
                    "element_a_id": "RVT-553290",
                    "element_a_name": "Supply Diffuser SD-07",
                    "element_b_id": "RVT-118512",
                    "element_b_name": "RC Beam B-121 (300x750)",
                    "category_a": "Air Terminals",
                    "category_b": "Structural Framing",
                    "location": {"x": 251_848.660, "y": 2_786_417.902, "z": 17.420},
                    "penetration_depth_m": 0.082,
                    "severity": "critical",
                },
                {
                    "clash_id": "CL-0003",
                    "element_a_id": "RVT-553371",
                    "element_a_name": "Smoke Detector SD-114",
                    "element_b_id": "RVT-119008",
                    "element_b_name": "Post-tension Slab Zone PT-B01-04",
                    "category_a": "Fire Alarm Devices",
                    "category_b": "Structural Foundations",
                    "location": {"x": 251_839.204, "y": 2_786_425.117, "z": 17.980},
                    "penetration_depth_m": 0.012,
                    "severity": "major",
                },
                {
                    "clash_id": "CL-0004",
                    "element_a_id": "RVT-553415",
                    "element_a_name": "Sprinkler Head SP-228",
                    "element_b_id": "RVT-118447",
                    "element_b_name": "RC Beam B-114 (300x600)",
                    "category_a": "Sprinklers",
                    "category_b": "Structural Framing",
                    "location": {"x": 251_842.530, "y": 2_786_419.870, "z": 17.515},
                    "penetration_depth_m": 0.006,
                    "severity": "minor",
                },
            ],
        }

    def _tool_read_pdf_dwg_metadata(self, arguments: dict[str, Any]) -> dict[str, Any]:
        sheet = str(arguments.get("sheet_number", "i125-UAE044106-STR-RCP-B01-101"))
        return {
            "sheet_number": sheet,
            "title": "REFLECTED CEILING PLAN — LEVEL B01 (ZONE 1)",
            "revision": "C02",
            "scale": "1:100",
            "units": "m",
            "annotated_ceiling_elevation_m": 17.400,
            "grid_origin": {"x": 251_830.000, "y": 2_786_405.000, "z": 0.000},
            "dwg_pdf_pair_verified": True,
        }

    def _tool_update_element_location(self, arguments: dict[str, Any]) -> dict[str, Any]:
        element_id = str(arguments.get("element_id", ""))
        new_location = arguments.get("new_location")
        authorized = arguments.get("authorized")
        if not element_id or not isinstance(new_location, dict):
            raise MCPToolError("update_element_location requires 'element_id' and 'new_location'")
        # Defence-in-depth: the tool itself refuses unauthorized writes.
        if authorized is not True:
            raise MCPToolError(
                "update_element_location rejected: explicit boolean True authorization required"
            )
        return {
            "element_id": element_id,
            "new_location": new_location,
            "transaction": "committed",
            "units": "m",
        }

    def _tool_create_tag_and_dimension(self, arguments: dict[str, Any]) -> dict[str, Any]:
        element_id = str(arguments.get("element_id", ""))
        if not element_id:
            raise MCPToolError("create_tag_and_dimension requires 'element_id'")
        return {
            "element_id": element_id,
            "tag_id": f"TAG-{self._rng.randint(100000, 999999)}",
            "dimension_id": f"DIM-{self._rng.randint(100000, 999999)}",
            "view": str(arguments.get("view", "RCP-B01-Z1")),
            "transaction": "committed",
        }
