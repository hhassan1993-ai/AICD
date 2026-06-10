# RCP Coordination Orchestrator — i125 Ghaf Woods P13

AI orchestration dashboard for Reflected Ceiling Plan coordination over a (mocked) Revit MCP interface. In-memory state only; no external database.

## Run

```bash
# Backend (Python 3.12+) — http://127.0.0.1:8000
cd backend
pip install -r requirements.txt
python main.py

# Frontend (Node 18+) — http://localhost:5173
cd frontend
npm install
npm run dev
```

## Architecture

| Layer | Location | Responsibility |
|---|---|---|
| Frontend dashboard | `frontend/src` | React 18 + TS strict + Tailwind v4 + Zod. Components: `WorkflowControls`, `ModelStatusTable`, `ResolutionTable`, `TerminalConsole`. WebSocket client with exponential-backoff reconnect; every inbound frame is Zod-validated and dropped on failure. |
| Agent orchestrator | `backend/agent.py` | `RCPCoordinationAgent` — deterministic 5-phase state machine, shift-vector calculation, unit consistency, HITL gate. |
| MCP interface | `backend/mcp_client.py` | `RevitMCPClient` mock — 0.5–2.0 s simulated latency per call, per-tool call accounting, `call_tool(name, arguments)` signature compatible with a real `mcp` `ClientSession` (swap path documented in `requirements.txt`). |
| API / transport | `backend/main.py` | FastAPI. WS `/ws` streams `{type: state|log}` with backlog replay. REST: `POST /api/phase/{n}/run`, `POST /api/authorize`, `POST /api/reset`, `GET /api/state`. |

## Constraint enforcement (server-side, UI is advisory only)

| Constraint | Mechanism | Verified by |
|---|---|---|
| Sequential phases | `run_phase` rejects `phase != completed_phase + 1` (HTTP 409); `asyncio.Lock` prohibits concurrent execution | `test_phase_order_is_enforced`, integration: 409 on out-of-order |
| ISO metres, 3 d.p. | Floats transmitted at full precision; all display via `fmtM` / `_m` → `0.000` | Visual + log inspection |
| HITL gate (Phase 4) | Status `awaiting_authorization` blocks all phases; `authorize()` requires a complete `dict[str, StrictBool]` decision set; `update_element_location` called only for `True`; the mock tool additionally rejects any call without `authorized: True` (defence-in-depth) | `test_phase_4_pauses_and_gates_writes`, `test_approved_subset_applies_only_approved`, `test_authorization_requires_complete_decision_set` |
| 0.001 m tolerance halt | Phase 1 computes Euclidean deviation per model vs base survey point; first violation → `HALTED`, all phases locked until reset | `test_edge_case_1_hard_halt_on_coordinate_mismatch` |
| Edge Case 2 | Reject-all → Phase 4 completes, Phase 5 runs, `update_element_location` count stays 0 (count surfaced in terminal header) | `test_edge_case_2_reject_all_then_phase_5_without_writes` |

## QA status (executed in this build)

- `pytest`: 7/7 passing (`backend/tests/test_agent.py`)
- `mypy --strict`: clean on all 4 backend modules
- `tsc -b` (strict + `noUncheckedIndexedAccess` + `exactOptionalPropertyTypes`): clean; `vite build` succeeds
- Live HTTP integration: full 5-phase run, both mandated edge cases, 409 on out-of-order/gated calls, 422 on partial authorization payloads

## Edge-case reproduction in the UI

- **EC1**: tick "Edge Case 1 — simulate survey-point mismatch", press **Reset pipeline**, run Phase 1. MEP model fails at 0.004 m deviation; rail shows phases 2–5 `LOCKED`.
- **EC2**: run Phases 1–4, **Reject** all proposals, **Submit authorization**, run Phase 5. Terminal header shows `update_loc:0`.

## Live Revit mode (open-source revit-mcp)

By default the backend uses the mocked `RevitMCPClient`. Setting `RCP_MCP_MODE=live`
swaps in `mcp_live.RevitMCPLiveClient`, which spawns the open-source
[revit-mcp](https://github.com/revit-mcp/revit-mcp) Node server over stdio (the
same server Claude Desktop uses) and talks to Revit through the
`revit-mcp-plugin` socket.

```powershell
# Prerequisites: Revit open with revit-mcp-plugin enabled, revit-mcp built (npm run build)
$env:RCP_MCP_MODE = "live"
$env:REVIT_MCP_ARGS = "C:\path\to\revit-mcp\build\index.js"
$env:RCP_SHEET_METADATA_FILE = "sheet_metadata.json"   # copy from sheet_metadata.example.json
py main.py
```

| Variable | Default | Purpose |
|---|---|---|
| `RCP_MCP_MODE` | `mock` | `live` connects to revit-mcp |
| `REVIT_MCP_COMMAND` | `node` | Executable for the MCP server |
| `REVIT_MCP_ARGS` | — | Path to revit-mcp `build/index.js` (required in live mode) |
| `RCP_SHEET_METADATA_FILE` | — | JSON backing `read_pdf_dwg_metadata` (2D sheet data lives outside Revit) |

How the orchestrator's five tools map onto revit-mcp (which has no native
clash/coordinate tools): coordinates, clash scan, element moves, and tagging go
through revit-mcp's `send_code_to_revit` (C# executed in Revit — snippets in
`mcp_live.py`, written as reviewable starting points); sheet metadata comes
from the configured JSON file. The HITL gate is preserved: the live client also
refuses `update_element_location` without `authorized: true`. Edge Case 1's
simulated mismatch only applies in mock mode — live mode reads real coordinates.

## Known scope boundaries

- The live clash scan approximates penetration depth from bounding-box overlap —
  verify the C# snippets in `mcp_live.py` against your model conventions before
  trusting results.
- `create_tag_and_dimension` places tags only in live mode; dimensions need
  project-specific references.
- Single-process, in-memory state per the execution parameters; restart clears all state.
- No authentication on the API — local development build only.
