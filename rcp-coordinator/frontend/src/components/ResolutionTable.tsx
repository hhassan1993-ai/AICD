import { useEffect, useMemo, useState } from "react";
import { Check, Lock, Send, X } from "lucide-react";
import { fmtCoord, fmtM } from "../lib/format";
import type { ClashResult, ResolutionProposal, StateSnapshot } from "../lib/types";

interface Props {
  state: StateSnapshot;
  onAuthorize: (decisions: Record<string, boolean>) => void;
}

const SEVERITY_TONE: Record<ClashResult["severity"], string> = {
  critical: "text-halt",
  major: "text-amber",
  minor: "text-dim",
};

const PROPOSAL_TONE: Record<ResolutionProposal["status"], string> = {
  pending: "text-amber",
  approved: "text-ok",
  applied: "text-ok",
  rejected: "text-dim",
};

export function ResolutionTable({ state, onAuthorize }: Props): JSX.Element {
  const gateOpen = state.status === "awaiting_authorization";
  const pendingIds = useMemo(
    () => state.proposals.filter((p) => p.status === "pending").map((p) => p.proposal_id),
    [state.proposals],
  );
  const [decisions, setDecisions] = useState<Record<string, boolean>>({});

  // Drop stale local decisions whenever the pending set changes (reset / new run).
  useEffect(() => {
    setDecisions((prev) => {
      const next: Record<string, boolean> = {};
      for (const id of pendingIds) {
        const v = prev[id];
        if (v !== undefined) next[id] = v;
      }
      return next;
    });
  }, [pendingIds]);

  const allDecided = pendingIds.length > 0 && pendingIds.every((id) => decisions[id] !== undefined);
  const approvedCount = pendingIds.filter((id) => decisions[id] === true).length;

  return (
    <section aria-label="Clashes and resolution proposals" className="border border-line bg-panel">
      <header className="flex items-center justify-between border-b border-line px-3 py-2">
        <h2 className="font-display text-[11px] font-semibold uppercase tracking-[0.18em] text-dim">
          Clash Register &amp; Resolution Proposals
        </h2>
        {gateOpen && (
          <span className="flex items-center gap-1 text-[11px] uppercase tracking-wider text-amber">
            <Lock size={12} aria-hidden /> writes gated — authorization required
          </span>
        )}
      </header>

      {/* Clash register */}
      {state.clashes.length === 0 ? (
        <p className="px-3 py-3 text-[12px] text-dim">
          No clashes registered. Run Phase 2 to execute clash detection.
        </p>
      ) : (
        <div className="overflow-x-auto border-b border-line">
          <table className="w-full text-left text-[12px]">
            <thead>
              <tr className="border-b border-line text-[10px] uppercase tracking-wider text-dim">
                <th className="px-3 py-1.5 font-medium">Clash</th>
                <th className="px-3 py-1.5 font-medium">Severity</th>
                <th className="px-3 py-1.5 font-medium">RCP Element</th>
                <th className="px-3 py-1.5 font-medium">Structural Element</th>
                <th className="px-3 py-1.5 font-medium">Location (m)</th>
                <th className="px-3 py-1.5 font-medium">Penetration (m)</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line/60">
              {state.clashes.map((c) => (
                <tr key={c.clash_id}>
                  <td className="px-3 py-1.5 text-ink">{c.clash_id}</td>
                  <td className={`px-3 py-1.5 uppercase ${SEVERITY_TONE[c.severity]}`}>
                    {c.severity}
                  </td>
                  <td className="px-3 py-1.5">{c.element_a_name}</td>
                  <td className="px-3 py-1.5">{c.element_b_name}</td>
                  <td className="px-3 py-1.5 tabular-nums text-dim">{fmtCoord(c.location)}</td>
                  <td className="px-3 py-1.5 tabular-nums text-amber">
                    {fmtM(c.penetration_depth_m)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* Proposals + HITL gate */}
      {state.proposals.length > 0 && (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-[12px]">
            <thead>
              <tr className="border-b border-line text-[10px] uppercase tracking-wider text-dim">
                <th className="px-3 py-1.5 font-medium">Proposal</th>
                <th className="px-3 py-1.5 font-medium">Element</th>
                <th className="px-3 py-1.5 font-medium">ΔZ (m)</th>
                <th className="px-3 py-1.5 font-medium">EL current → proposed (m)</th>
                <th className="px-3 py-1.5 font-medium">Status</th>
                {gateOpen && <th className="px-3 py-1.5 font-medium">Decision</th>}
              </tr>
            </thead>
            <tbody className="divide-y divide-line/60">
              {state.proposals.map((p) => {
                const decision = decisions[p.proposal_id];
                return (
                  <tr key={p.proposal_id}>
                    <td className="px-3 py-1.5 text-ink" title={p.rationale}>
                      {p.proposal_id}
                    </td>
                    <td className="px-3 py-1.5">{p.element_name}</td>
                    <td className="px-3 py-1.5 tabular-nums">{fmtM(p.shift_vector.z)}</td>
                    <td className="px-3 py-1.5 tabular-nums text-dim">
                      {fmtM(p.current_location.z)} → {fmtM(p.proposed_location.z)}
                    </td>
                    <td className={`px-3 py-1.5 uppercase ${PROPOSAL_TONE[p.status]}`}>
                      {p.status}
                    </td>
                    {gateOpen && (
                      <td className="px-3 py-1.5">
                        {p.status === "pending" ? (
                          <div className="flex gap-1" role="group" aria-label={`Decision for ${p.proposal_id}`}>
                            <button
                              type="button"
                              aria-pressed={decision === true}
                              onClick={() =>
                                setDecisions((d) => ({ ...d, [p.proposal_id]: true }))
                              }
                              className={`flex items-center gap-1 border px-2 py-0.5 text-[10px] uppercase ${
                                decision === true
                                  ? "border-ok bg-ok/15 text-ok"
                                  : "border-line text-dim hover:border-ok hover:text-ok"
                              }`}
                            >
                              <Check size={11} aria-hidden /> Approve
                            </button>
                            <button
                              type="button"
                              aria-pressed={decision === false}
                              onClick={() =>
                                setDecisions((d) => ({ ...d, [p.proposal_id]: false }))
                              }
                              className={`flex items-center gap-1 border px-2 py-0.5 text-[10px] uppercase ${
                                decision === false
                                  ? "border-halt bg-halt/15 text-halt"
                                  : "border-line text-dim hover:border-halt hover:text-halt"
                              }`}
                            >
                              <X size={11} aria-hidden /> Reject
                            </button>
                          </div>
                        ) : (
                          <span className="text-[10px] uppercase text-dim">—</span>
                        )}
                      </td>
                    )}
                  </tr>
                );
              })}
            </tbody>
          </table>

          {gateOpen && (
            <footer className="flex items-center justify-between border-t border-amber/40 bg-amber/10 px-3 py-2">
              <p className="text-[11px] text-amber">
                {allDecided
                  ? `${approvedCount} of ${pendingIds.length} proposals will call update_element_location.`
                  : `Decide all ${pendingIds.length} proposals to submit. Undecided proposals block submission.`}
              </p>
              <button
                type="button"
                disabled={!allDecided}
                onClick={() => onAuthorize(decisions)}
                className="flex items-center gap-1.5 border border-amber px-3 py-1 text-[11px] uppercase tracking-wider text-amber hover:bg-amber hover:text-bg disabled:cursor-not-allowed disabled:opacity-40"
              >
                <Send size={12} aria-hidden /> Submit authorization
              </button>
            </footer>
          )}
        </div>
      )}
    </section>
  );
}
