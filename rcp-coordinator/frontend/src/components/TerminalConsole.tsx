import { useEffect, useRef } from "react";
import { fmtTs } from "../lib/format";
import type { LogEvent } from "../lib/types";

interface Props {
  logs: LogEvent[];
  mcpCallCounts: Record<string, number>;
}

const LEVEL_TONE: Record<LogEvent["level"], string> = {
  info: "text-ink",
  warn: "text-amber",
  error: "text-halt",
  ok: "text-ok",
  mcp: "text-mcp",
};

export function TerminalConsole({ logs, mcpCallCounts }: Props): JSX.Element {
  const bodyRef = useRef<HTMLDivElement | null>(null);
  const pinnedRef = useRef(true);

  // Autoscroll only while the user is pinned to the bottom.
  const handleScroll = (): void => {
    const el = bodyRef.current;
    if (el === null) return;
    pinnedRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 24;
  };

  useEffect(() => {
    const el = bodyRef.current;
    if (el !== null && pinnedRef.current) {
      el.scrollTop = el.scrollHeight;
    }
  }, [logs]);

  return (
    <section aria-label="System log terminal" className="flex min-h-0 flex-col border border-line bg-panel">
      <header className="flex items-center justify-between border-b border-line px-3 py-2">
        <h2 className="font-display text-[11px] font-semibold uppercase tracking-[0.18em] text-dim">
          System Terminal
        </h2>
        <p className="text-[10px] tabular-nums text-dim">
          mcp calls — read_coords:{mcpCallCounts["read_model_coordinates"] ?? 0}{" "}
          clash:{mcpCallCounts["execute_clash_detection"] ?? 0}{" "}
          pdf/dwg:{mcpCallCounts["read_pdf_dwg_metadata"] ?? 0}{" "}
          <span className="text-amber">
            update_loc:{mcpCallCounts["update_element_location"] ?? 0}
          </span>{" "}
          tag/dim:{mcpCallCounts["create_tag_and_dimension"] ?? 0}
        </p>
      </header>
      <div
        ref={bodyRef}
        onScroll={handleScroll}
        className="h-56 overflow-y-auto bg-bg px-3 py-2 leading-5"
        role="log"
        aria-live="polite"
      >
        {logs.length === 0 ? (
          <p className="text-[12px] text-dim">— no output. Run Phase 1 to begin. —</p>
        ) : (
          logs.map((l, i) => (
            <p key={`${l.ts}-${i}`} className="whitespace-pre-wrap text-[12px]">
              <span className="text-dim">{fmtTs(l.ts)}</span>{" "}
              <span className="text-dim">[{l.source.padEnd(4, " ")}]</span>{" "}
              <span className={LEVEL_TONE[l.level]}>{l.message}</span>
            </p>
          ))
        )}
      </div>
    </section>
  );
}
