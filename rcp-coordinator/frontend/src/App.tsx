import { useState } from "react";
import { Plug, PlugZap, XCircle } from "lucide-react";
import { ModelStatusTable } from "./components/ModelStatusTable";
import { ResolutionTable } from "./components/ResolutionTable";
import { TerminalConsole } from "./components/TerminalConsole";
import { WorkflowControls } from "./components/WorkflowControls";
import { useOrchestrator } from "./lib/useOrchestrator";

export default function App(): JSX.Element {
  const { state, logs, connection, lastError, runPhase, authorize, reset, clearError } =
    useOrchestrator();
  const [simulateMismatch, setSimulateMismatch] = useState(false);

  return (
    <div className="mx-auto flex h-full max-w-[1400px] flex-col gap-3 p-3">
      {/* Drawing title block — sheet-style header */}
      <header className="grid grid-cols-2 border border-line bg-panel md:grid-cols-[2fr_1fr_1fr_1fr_auto]">
        <div className="border-b border-r border-line px-3 py-2 md:border-b-0">
          <p className="text-[9px] uppercase tracking-[0.2em] text-dim">Project</p>
          <h1 className="font-display text-sm font-bold uppercase tracking-wide text-ink">
            Ghaf Woods — Package 13 (i125)
          </h1>
        </div>
        <div className="border-b border-line px-3 py-2 md:border-b-0 md:border-r">
          <p className="text-[9px] uppercase tracking-[0.2em] text-dim">Document</p>
          <p className="text-[12px] text-ink">UAE044106-RCP-COORD</p>
        </div>
        <div className="border-r border-line px-3 py-2">
          <p className="text-[9px] uppercase tracking-[0.2em] text-dim">Scope</p>
          <p className="text-[12px] text-ink">RCP Coordination — B01 Z1</p>
        </div>
        <div className="border-r border-line px-3 py-2">
          <p className="text-[9px] uppercase tracking-[0.2em] text-dim">Units</p>
          <p className="text-[12px] text-ink">ISO — metres (0.000)</p>
        </div>
        <div className="col-span-2 flex items-center gap-2 px-3 py-2 md:col-span-1">
          {connection === "open" ? (
            <span className="flex items-center gap-1.5 text-[11px] uppercase tracking-wider text-ok">
              <PlugZap size={13} aria-hidden /> Orchestrator linked
            </span>
          ) : (
            <span className="flex items-center gap-1.5 text-[11px] uppercase tracking-wider text-halt">
              <Plug size={13} aria-hidden />
              {connection === "connecting" ? "Connecting…" : "Reconnecting…"}
            </span>
          )}
        </div>
      </header>

      {lastError !== null && (
        <div
          role="alert"
          className="flex items-center justify-between border border-halt/60 bg-halt/10 px-3 py-2 text-[12px] text-halt"
        >
          <p>Request rejected by orchestrator: {lastError}</p>
          <button
            type="button"
            onClick={clearError}
            aria-label="Dismiss error"
            className="text-halt hover:text-ink"
          >
            <XCircle size={15} aria-hidden />
          </button>
        </div>
      )}

      {state === null ? (
        <main className="flex flex-1 items-center justify-center border border-line bg-panel text-[12px] text-dim">
          Waiting for orchestrator state on ws://127.0.0.1:8000/ws — start the backend with
          `python main.py`.
        </main>
      ) : (
        <main className="grid flex-1 grid-cols-1 gap-3 lg:grid-cols-[340px_1fr]">
          <WorkflowControls
            state={state}
            busy={state.status === "running"}
            simulateMismatch={simulateMismatch}
            onToggleMismatch={setSimulateMismatch}
            onRunPhase={(p) => void runPhase(p)}
            onReset={() => void reset(simulateMismatch)}
          />
          <div className="flex min-w-0 flex-col gap-3">
            <ModelStatusTable models={state.models} />
            <ResolutionTable state={state} onAuthorize={(d) => void authorize(d)} />
          </div>
        </main>
      )}

      <TerminalConsole logs={logs} mcpCallCounts={state?.mcp_call_counts ?? {}} />
    </div>
  );
}
