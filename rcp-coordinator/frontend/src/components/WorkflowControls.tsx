import { AlertTriangle, OctagonX, Play, RotateCcw } from "lucide-react";
import type { StateSnapshot } from "../lib/types";

interface Props {
  state: StateSnapshot;
  busy: boolean;
  simulateMismatch: boolean;
  onToggleMismatch: (value: boolean) => void;
  onRunPhase: (phase: number) => void;
  onReset: () => void;
}

const STATUS_LABEL: Record<StateSnapshot["status"], string> = {
  idle: "STANDBY",
  running: "EXECUTING",
  awaiting_authorization: "HITL GATE OPEN",
  halted: "HARD HALT",
  complete: "PIPELINE COMPLETE",
  error: "ERROR",
};

export function WorkflowControls({
  state,
  busy,
  simulateMismatch,
  onToggleMismatch,
  onRunPhase,
  onReset,
}: Props): JSX.Element {
  const nextPhase = state.completed_phase + 1;
  const canRunNext =
    !busy &&
    state.status === "idle" &&
    nextPhase >= 1 &&
    nextPhase <= 5;

  return (
    <section aria-label="Workflow controls" className="border border-line bg-panel">
      <header className="flex items-center justify-between border-b border-line px-3 py-2">
        <h2 className="font-display text-[11px] font-semibold uppercase tracking-[0.18em] text-dim">
          Phase Sequence
        </h2>
        <span
          className={`text-[11px] uppercase tracking-wider ${
            state.status === "halted" || state.status === "error"
              ? "text-halt"
              : state.status === "awaiting_authorization"
                ? "text-amber"
                : state.status === "complete"
                  ? "text-ok"
                  : "text-dim"
          }`}
        >
          {STATUS_LABEL[state.status]}
        </span>
      </header>

      {/* Revision-strip phase rail: sequence is real, so numbering is information. */}
      <ol className="divide-y divide-line">
        {state.phases.map((p) => {
          const isNext = p.phase === nextPhase && state.status === "idle";
          const tone =
            p.status === "complete"
              ? "text-ok"
              : p.status === "running"
                ? "text-amber"
                : p.status === "halted"
                  ? "text-halt"
                  : p.status === "skipped_locked"
                    ? "text-halt/60"
                    : "text-dim";
          return (
            <li key={p.phase} className="flex items-stretch">
              <div
                className={`flex w-12 items-center justify-center border-r border-line font-display text-lg font-bold ${tone}`}
              >
                {p.phase}
              </div>
              <div className="flex flex-1 items-center justify-between gap-2 px-3 py-2">
                <div className="min-w-0">
                  <p className="truncate text-[12px] text-ink">{p.name}</p>
                  <p className={`text-[10px] uppercase tracking-wider ${tone}`}>
                    {p.status === "skipped_locked" ? "locked" : p.status}
                  </p>
                </div>
                {isNext && (
                  <button
                    type="button"
                    disabled={!canRunNext}
                    onClick={() => onRunPhase(p.phase)}
                    className="flex items-center gap-1 border border-amber px-2 py-1 text-[11px] uppercase tracking-wider text-amber hover:bg-amber hover:text-bg disabled:cursor-not-allowed disabled:opacity-40"
                  >
                    <Play size={12} aria-hidden /> Run
                  </button>
                )}
              </div>
            </li>
          );
        })}
      </ol>

      {state.status === "halted" && state.halt_reason !== null && (
        <div className="flex items-start gap-2 border-t border-halt/50 bg-halt/10 px-3 py-2 text-[11px] text-halt">
          <OctagonX size={14} className="mt-0.5 shrink-0" aria-hidden />
          <p>{state.halt_reason}</p>
        </div>
      )}

      <footer className="space-y-2 border-t border-line px-3 py-3">
        <label className="flex cursor-pointer items-center gap-2 text-[11px] text-dim">
          <input
            type="checkbox"
            checked={simulateMismatch}
            onChange={(e) => onToggleMismatch(e.target.checked)}
            className="h-3.5 w-3.5 accent-amber"
          />
          <AlertTriangle size={12} className="text-amber" aria-hidden />
          Edge Case 1 — simulate survey-point mismatch on next reset
        </label>
        <button
          type="button"
          disabled={state.status === "running"}
          onClick={onReset}
          className="flex w-full items-center justify-center gap-2 border border-line px-2 py-1.5 text-[11px] uppercase tracking-wider text-dim hover:border-dim hover:text-ink disabled:cursor-not-allowed disabled:opacity-40"
        >
          <RotateCcw size={12} aria-hidden /> Reset pipeline
        </button>
      </footer>
    </section>
  );
}
