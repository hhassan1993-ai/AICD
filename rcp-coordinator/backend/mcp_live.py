"""Live Revit MCP client — connects to the open-source ``revit-mcp`` Node server.

Drop-in replacement for the mock ``RevitMCPClient`` (same ``MCPClientProtocol``):
spawns the revit-mcp server (https://github.com/revit-mcp/revit-mcp) as a child
process over stdio using the official ``mcp`` Python SDK, and adapts the
orchestrator's five tool calls onto the tools revit-mcp actually exposes.

Mapping strategy
----------------
revit-mcp has no native equivalents for most of the orchestrator's tool surface
(it offers element creation/manipulation plus a ``send_code_to_revit`` escape
hatch that executes C# inside Revit). The adapter therefore routes:

==========================  =====================================================
Orchestrator tool           revit-mcp implementation
==========================  =====================================================
read_model_coordinates      send_code_to_revit → read survey/base points
execute_clash_detection     send_code_to_revit → bounding-box intersection scan
read_pdf_dwg_metadata       local JSON file (RCP_SHEET_METADATA_FILE) — the 2D
                            sheet metadata lives outside the Revit model
update_element_location     send_code_to_revit → ElementTransformUtils.MoveElement
create_tag_and_dimension    send_code_to_revit → IndependentTag.Create
==========================  =====================================================

The C# snippets are starting points written against the Revit API; verify them
against your revit-mcp-plugin version and model conventions before relying on
the results (in particular the clash scan, which approximates penetration depth
from bounding-box overlap).

Configuration (environment variables)
-------------------------------------
REVIT_MCP_COMMAND        executable for the server (default: ``node``)
REVIT_MCP_ARGS           arguments, e.g. ``C:\\revit-mcp\\build\\index.js``
RCP_SHEET_METADATA_FILE  JSON file backing read_pdf_dwg_metadata (optional)
"""
from __future__ import annotations

import asyncio
import json
import os
import shlex
from contextlib import AsyncExitStack
from pathlib import Path
from typing import Any, Protocol

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.types import TextContent

from mcp_client import TOOL_NAMES, MCPToolError

M_TO_FT = 1.0 / 0.3048


class _SessionLike(Protocol):
    """The slice of ``mcp.ClientSession`` the adapter uses (injectable in tests)."""

    async def call_tool(self, name: str, arguments: dict[str, Any] | None = None) -> Any: ...


# --------------------------------------------------------------------------- #
# C# snippets executed in Revit via revit-mcp's send_code_to_revit tool.
# All distances are converted to metres before being serialized to JSON.
# --------------------------------------------------------------------------- #

CSHARP_READ_POINTS = """
var doc = uiapp.ActiveUIDocument.Document;
const double F = 0.3048;
Func<BuiltInCategory, XYZ> pt = (cat) => {
    var bp = new FilteredElementCollector(doc).OfCategory(cat)
        .WhereElementIsNotElementType().FirstElement() as BasePoint;
    return bp == null ? XYZ.Zero : bp.Position;
};
var sp = pt(BuiltInCategory.OST_SharedBasePoint);
var pbp = pt(BuiltInCategory.OST_ProjectBasePoint);
return string.Format(System.Globalization.CultureInfo.InvariantCulture,
    "{{\\"survey_point\\":{{\\"x\\":{0},\\"y\\":{1},\\"z\\":{2}}}," +
    "\\"project_base_point\\":{{\\"x\\":{3},\\"y\\":{4},\\"z\\":{5}}}}}",
    sp.X * F, sp.Y * F, sp.Z * F, pbp.X * F, pbp.Y * F, pbp.Z * F);
"""

CSHARP_CLASH_SCAN = """
var doc = uiapp.ActiveUIDocument.Document;
const double F = 0.3048;
var rcpCats = new[] { BuiltInCategory.OST_LightingFixtures, BuiltInCategory.OST_DuctTerminal,
                      BuiltInCategory.OST_FireAlarmDevices, BuiltInCategory.OST_Sprinklers };
var strCats = new[] { BuiltInCategory.OST_StructuralFraming, BuiltInCategory.OST_StructuralFoundation };
var sb = new System.Text.StringBuilder("[");
int n = 0;
foreach (var rc in rcpCats) {
    foreach (Element a in new FilteredElementCollector(doc).OfCategory(rc).WhereElementIsNotElementType()) {
        var ba = a.get_BoundingBox(null);
        if (ba == null) continue;
        var outline = new Outline(ba.Min, ba.Max);
        foreach (var sc in strCats) {
            foreach (Element b in new FilteredElementCollector(doc).OfCategory(sc)
                     .WhereElementIsNotElementType()
                     .WherePasses(new BoundingBoxIntersectsFilter(outline))) {
                var bb = b.get_BoundingBox(null);
                if (bb == null) continue;
                double pen = Math.Min(ba.Max.Z, bb.Max.Z) - Math.Max(ba.Min.Z, bb.Min.Z);
                if (pen <= 0) continue;
                var c = (ba.Min + ba.Max) / 2.0;
                if (n++ > 0) sb.Append(",");
                sb.Append(string.Format(System.Globalization.CultureInfo.InvariantCulture,
                    "{{\\"clash_id\\":\\"CL-{0:D4}\\",\\"element_a_id\\":\\"{1}\\"," +
                    "\\"element_a_name\\":\\"{2}\\",\\"element_b_id\\":\\"{3}\\"," +
                    "\\"element_b_name\\":\\"{4}\\",\\"category_a\\":\\"{5}\\"," +
                    "\\"category_b\\":\\"{6}\\"," +
                    "\\"location\\":{{\\"x\\":{7},\\"y\\":{8},\\"z\\":{9}}}," +
                    "\\"penetration_depth_m\\":{10}," +
                    "\\"severity\\":\\"{11}\\"}}",
                    n, a.Id, a.Name.Replace("\\"", ""), b.Id, b.Name.Replace("\\"", ""),
                    a.Category.Name, b.Category.Name,
                    c.X * F, c.Y * F, c.Z * F, pen * F,
                    pen * F > 0.04 ? "critical" : (pen * F > 0.01 ? "major" : "minor")));
            }
        }
    }
}
sb.Append("]");
return sb.ToString();
"""

CSHARP_MOVE_ELEMENT = """
var doc = uiapp.ActiveUIDocument.Document;
const double M = 1.0 / 0.3048;
var id = new ElementId(long.Parse("__ELEMENT_ID__"));
var target = new XYZ(__X__ * M, __Y__ * M, __Z__ * M);
using (var t = new Transaction(doc, "RCP coordination move")) {
    t.Start();
    var el = doc.GetElement(id);
    var lp = el.Location as LocationPoint;
    if (lp == null) { t.RollBack(); return "{\\"error\\":\\"element has no point location\\"}"; }
    ElementTransformUtils.MoveElement(doc, id, target - lp.Point);
    t.Commit();
}
return "{\\"transaction\\":\\"committed\\"}";
"""

CSHARP_TAG_ELEMENT = """
var doc = uiapp.ActiveUIDocument.Document;
var view = uiapp.ActiveUIDocument.ActiveView;
var id = new ElementId(long.Parse("__ELEMENT_ID__"));
string tagId;
using (var t = new Transaction(doc, "RCP coordination tag")) {
    t.Start();
    var el = doc.GetElement(id);
    var lp = el.Location as LocationPoint;
    var pos = lp != null ? lp.Point : XYZ.Zero;
    var tag = IndependentTag.Create(doc, view.Id, new Reference(el), false,
        TagMode.TM_ADDBY_CATEGORY, TagOrientation.Horizontal, pos);
    tagId = tag.Id.ToString();
    t.Commit();
}
return string.Format("{{\\"tag_id\\":\\"TAG-{0}\\",\\"view\\":\\"{1}\\"}}", tagId, view.Name);
"""


class RevitMCPLiveClient:
    """MCP-backed implementation of the orchestrator tool surface."""

    def __init__(
        self,
        *,
        command: str = "node",
        args: list[str] | None = None,
        sheet_metadata_file: str | None = None,
        timeout_s: float = 60.0,
        session: _SessionLike | None = None,
    ) -> None:
        self._command = command
        self._args = args or []
        self._sheet_metadata_file = sheet_metadata_file
        self._timeout_s = timeout_s
        self._session: _SessionLike | None = session
        self._stack: AsyncExitStack | None = None
        self._connect_lock = asyncio.Lock()
        self.call_counts: dict[str, int] = {name: 0 for name in TOOL_NAMES}

    @classmethod
    def from_env(cls) -> "RevitMCPLiveClient":
        args = shlex.split(os.environ.get("REVIT_MCP_ARGS", ""))
        if not args:
            raise MCPToolError(
                "Live MCP mode requires REVIT_MCP_ARGS (path to revit-mcp build/index.js)"
            )
        return cls(
            command=os.environ.get("REVIT_MCP_COMMAND", "node"),
            args=args,
            sheet_metadata_file=os.environ.get("RCP_SHEET_METADATA_FILE"),
        )

    def reset_counts(self) -> None:
        self.call_counts = {name: 0 for name in TOOL_NAMES}

    # ------------------------------------------------------------------ #
    # Connection lifecycle
    # ------------------------------------------------------------------ #

    async def _ensure_session(self) -> _SessionLike:
        async with self._connect_lock:
            if self._session is not None:
                return self._session
            stack = AsyncExitStack()
            try:
                params = StdioServerParameters(command=self._command, args=self._args)
                read, write = await stack.enter_async_context(stdio_client(params))
                session = await stack.enter_async_context(ClientSession(read, write))
                await session.initialize()
            except BaseException as exc:
                await stack.aclose()
                raise MCPToolError(
                    f"Failed to start revit-mcp server "
                    f"({self._command} {' '.join(self._args)}): {exc}"
                ) from exc
            self._stack = stack
            self._session = session
            return session

    async def aclose(self) -> None:
        async with self._connect_lock:
            if self._stack is not None:
                await self._stack.aclose()
            self._stack = None
            self._session = None

    # ------------------------------------------------------------------ #
    # Public MCP-compatible entry point
    # ------------------------------------------------------------------ #

    async def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name not in TOOL_NAMES:
            raise MCPToolError(f"Unknown MCP tool: {name!r}")
        self.call_counts[name] += 1
        handler = getattr(self, f"_map_{name}")
        try:
            async with asyncio.timeout(self._timeout_s):
                result: dict[str, Any] = await handler(arguments)
                return result
        except TimeoutError as exc:
            raise MCPToolError(f"MCP tool {name!r} timed out after {self._timeout_s:.1f}s") from exc

    # ------------------------------------------------------------------ #
    # revit-mcp plumbing
    # ------------------------------------------------------------------ #

    async def _send_code(self, code: str) -> dict[str, Any]:
        """Run a C# snippet in Revit via send_code_to_revit; parse JSON output."""
        session = await self._ensure_session()
        result = await session.call_tool("send_code_to_revit", {"code": code})
        if getattr(result, "isError", False):
            raise MCPToolError(f"send_code_to_revit failed: {self._text_of(result)}")
        text = self._text_of(result)
        try:
            payload: Any = json.loads(text)
        except json.JSONDecodeError as exc:
            raise MCPToolError(
                f"send_code_to_revit returned non-JSON output: {text[:200]!r}"
            ) from exc
        if isinstance(payload, dict) and "error" in payload:
            raise MCPToolError(f"Revit-side execution error: {payload['error']}")
        if isinstance(payload, dict):
            return payload
        return {"data": payload}

    @staticmethod
    def _text_of(result: Any) -> str:
        parts = [
            block.text for block in getattr(result, "content", []) if isinstance(block, TextContent)
        ]
        return "\n".join(parts).strip()

    # ------------------------------------------------------------------ #
    # Tool mappings (orchestrator surface → revit-mcp)
    # ------------------------------------------------------------------ #

    async def _map_read_model_coordinates(self, arguments: dict[str, Any]) -> dict[str, Any]:
        model_id = str(arguments.get("model_id", ""))
        if not model_id:
            raise MCPToolError("read_model_coordinates requires 'model_id'")
        points = await self._send_code(CSHARP_READ_POINTS)
        return {
            "model_id": model_id,
            "survey_point": points["survey_point"],
            "project_base_point": points["project_base_point"],
            "units": "m",
        }

    async def _map_execute_clash_detection(self, arguments: dict[str, Any]) -> dict[str, Any]:
        payload = await self._send_code(CSHARP_CLASH_SCAN)
        clashes = payload.get("data", payload)
        if not isinstance(clashes, list):
            raise MCPToolError("Clash scan returned unexpected payload shape")
        return {"units": "m", "clashes": clashes}

    async def _map_read_pdf_dwg_metadata(self, arguments: dict[str, Any]) -> dict[str, Any]:
        if not self._sheet_metadata_file:
            raise MCPToolError(
                "read_pdf_dwg_metadata in live mode requires RCP_SHEET_METADATA_FILE — "
                "the 2D sheet metadata (annotated ceiling EL, revision) lives outside Revit"
            )
        path = Path(self._sheet_metadata_file)
        if not path.is_file():
            raise MCPToolError(f"Sheet metadata file not found: {path}")
        meta: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
        required = {"sheet_number", "revision", "annotated_ceiling_elevation_m", "dwg_pdf_pair_verified"}
        missing = required - meta.keys()
        if missing:
            raise MCPToolError(f"Sheet metadata file missing keys: {sorted(missing)}")
        return meta

    async def _map_update_element_location(self, arguments: dict[str, Any]) -> dict[str, Any]:
        element_id = str(arguments.get("element_id", ""))
        new_location = arguments.get("new_location")
        if not element_id or not isinstance(new_location, dict):
            raise MCPToolError("update_element_location requires 'element_id' and 'new_location'")
        # Defence-in-depth mirrors the mock: refuse writes without explicit consent.
        if arguments.get("authorized") is not True:
            raise MCPToolError(
                "update_element_location rejected: explicit boolean True authorization required"
            )
        code = (
            CSHARP_MOVE_ELEMENT
            .replace("__ELEMENT_ID__", _numeric_id(element_id))
            .replace("__X__", repr(float(new_location["x"])))
            .replace("__Y__", repr(float(new_location["y"])))
            .replace("__Z__", repr(float(new_location["z"])))
        )
        await self._send_code(code)
        return {
            "element_id": element_id,
            "new_location": new_location,
            "transaction": "committed",
            "units": "m",
        }

    async def _map_create_tag_and_dimension(self, arguments: dict[str, Any]) -> dict[str, Any]:
        element_id = str(arguments.get("element_id", ""))
        if not element_id:
            raise MCPToolError("create_tag_and_dimension requires 'element_id'")
        code = CSHARP_TAG_ELEMENT.replace("__ELEMENT_ID__", _numeric_id(element_id))
        payload = await self._send_code(code)
        return {
            "element_id": element_id,
            "tag_id": str(payload.get("tag_id", "")),
            # Dimensions need project-specific references; tag-only for now.
            "dimension_id": "",
            "view": str(payload.get("view", arguments.get("view", ""))),
            "transaction": "committed",
        }


def _numeric_id(element_id: str) -> str:
    """Extract the numeric part of IDs like 'RVT-553102' for ElementId construction."""
    digits = "".join(ch for ch in element_id if ch.isdigit())
    if not digits:
        raise MCPToolError(f"Element id {element_id!r} contains no numeric Revit ElementId")
    return digits
