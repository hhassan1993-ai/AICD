"""Unit tests for the revit-mcp live client adapter (stubbed MCP session)."""
from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any, Coroutine

import pytest
from mcp.types import TextContent

from mcp_client import MCPToolError
from mcp_live import RevitMCPLiveClient


class _FakeResult:
    def __init__(self, text: str, *, is_error: bool = False) -> None:
        self.content = [TextContent(type="text", text=text)]
        self.isError = is_error


class _FakeSession:
    """Records calls and replays canned per-tool responses."""

    def __init__(self, responses: dict[str, str]) -> None:
        self.responses = responses
        self.calls: list[tuple[str, dict[str, Any] | None]] = []

    async def call_tool(self, name: str, arguments: dict[str, Any] | None = None) -> _FakeResult:
        self.calls.append((name, arguments))
        return _FakeResult(self.responses[name])


def _client(session: _FakeSession, **kwargs: Any) -> RevitMCPLiveClient:
    return RevitMCPLiveClient(session=session, **kwargs)


def run(coro: Coroutine[Any, Any, Any]) -> Any:
    return asyncio.run(coro)


def test_read_model_coordinates_maps_to_send_code() -> None:
    session = _FakeSession({
        "send_code_to_revit": json.dumps({
            "survey_point": {"x": 251837.42, "y": 2786412.95, "z": 14.75},
            "project_base_point": {"x": 0.0, "y": 0.0, "z": 0.0},
        })
    })
    client = _client(session)
    result = run(client.call_tool("read_model_coordinates", {"model_id": "i125-UAE044106-ARC"}))
    assert result["model_id"] == "i125-UAE044106-ARC"
    assert result["survey_point"]["z"] == 14.75
    assert result["units"] == "m"
    assert session.calls[0][0] == "send_code_to_revit"
    assert client.call_counts["read_model_coordinates"] == 1


def test_clash_detection_returns_clash_list() -> None:
    clashes = [{
        "clash_id": "CL-0001", "element_a_id": "553102", "element_a_name": "LF-23",
        "element_b_id": "118447", "element_b_name": "B-114",
        "category_a": "Lighting Fixtures", "category_b": "Structural Framing",
        "location": {"x": 1.0, "y": 2.0, "z": 17.45},
        "penetration_depth_m": 0.045, "severity": "critical",
    }]
    session = _FakeSession({"send_code_to_revit": json.dumps(clashes)})
    result = run(_client(session).call_tool("execute_clash_detection", {}))
    assert result["units"] == "m"
    assert result["clashes"][0]["clash_id"] == "CL-0001"


def test_update_location_requires_authorization() -> None:
    session = _FakeSession({"send_code_to_revit": '{"transaction":"committed"}'})
    client = _client(session)
    with pytest.raises(MCPToolError, match="authorization"):
        run(client.call_tool(
            "update_element_location",
            {"element_id": "RVT-553102", "new_location": {"x": 1.0, "y": 2.0, "z": 3.0}},
        ))
    assert session.calls == []  # nothing reached Revit

    result = run(client.call_tool(
        "update_element_location",
        {"element_id": "RVT-553102", "new_location": {"x": 1.0, "y": 2.0, "z": 3.0},
         "authorized": True},
    ))
    assert result["transaction"] == "committed"
    # The numeric Revit ElementId is extracted from the prefixed id.
    assert "553102" in str(session.calls[0][1])


def test_sheet_metadata_from_file(tmp_path: Path) -> None:
    meta = {
        "sheet_number": "S-101", "revision": "C02",
        "annotated_ceiling_elevation_m": 17.4, "dwg_pdf_pair_verified": True,
    }
    path = tmp_path / "sheet.json"
    path.write_text(json.dumps(meta), encoding="utf-8")
    session = _FakeSession({})
    client = _client(session, sheet_metadata_file=str(path))
    result = run(client.call_tool("read_pdf_dwg_metadata", {"sheet_number": "S-101"}))
    assert result["annotated_ceiling_elevation_m"] == 17.4

    unconfigured = _client(session)
    with pytest.raises(MCPToolError, match="RCP_SHEET_METADATA_FILE"):
        run(unconfigured.call_tool("read_pdf_dwg_metadata", {}))


def test_unknown_tool_rejected() -> None:
    client = _client(_FakeSession({}))
    with pytest.raises(MCPToolError, match="Unknown MCP tool"):
        run(client.call_tool("delete_everything", {}))
