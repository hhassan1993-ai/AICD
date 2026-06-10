import { CheckCircle2, XCircle } from "lucide-react";
import { fmtM } from "../lib/format";
import type { ModelInfo } from "../lib/types";

interface Props {
  models: ModelInfo[];
}

export function ModelStatusTable({ models }: Props): JSX.Element {
  return (
    <section aria-label="Model coordinate status" className="border border-line bg-panel">
      <header className="border-b border-line px-3 py-2">
        <h2 className="font-display text-[11px] font-semibold uppercase tracking-[0.18em] text-dim">
          Linked Models — Shared Coordinate Validation (tolerance 0.001 m)
        </h2>
      </header>
      {models.length === 0 ? (
        <p className="px-3 py-4 text-[12px] text-dim">
          No models ingested. Run Phase 1 to read survey points over MCP.
        </p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-[12px]">
            <thead>
              <tr className="border-b border-line text-[10px] uppercase tracking-wider text-dim">
                <th className="px-3 py-1.5 font-medium">Model</th>
                <th className="px-3 py-1.5 font-medium">Disc.</th>
                <th className="px-3 py-1.5 font-medium">Survey E (m)</th>
                <th className="px-3 py-1.5 font-medium">Survey N (m)</th>
                <th className="px-3 py-1.5 font-medium">EL (m)</th>
                <th className="px-3 py-1.5 font-medium">Deviation (m)</th>
                <th className="px-3 py-1.5 font-medium">Check</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line/60">
              {models.map((m) => (
                <tr key={m.model_id} className={m.within_tolerance ? "" : "bg-halt/10"}>
                  <td className="px-3 py-1.5 text-ink">{m.model_id}</td>
                  <td className="px-3 py-1.5 text-dim">{m.discipline}</td>
                  <td className="px-3 py-1.5 tabular-nums">{fmtM(m.survey_point.x)}</td>
                  <td className="px-3 py-1.5 tabular-nums">{fmtM(m.survey_point.y)}</td>
                  <td className="px-3 py-1.5 tabular-nums">{fmtM(m.survey_point.z)}</td>
                  <td
                    className={`px-3 py-1.5 tabular-nums ${m.within_tolerance ? "text-ok" : "text-halt"}`}
                  >
                    {fmtM(m.deviation_m)}
                  </td>
                  <td className="px-3 py-1.5">
                    {m.within_tolerance ? (
                      <span className="flex items-center gap-1 text-ok">
                        <CheckCircle2 size={13} aria-hidden /> PASS
                      </span>
                    ) : (
                      <span className="flex items-center gap-1 text-halt">
                        <XCircle size={13} aria-hidden /> FAIL
                      </span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
