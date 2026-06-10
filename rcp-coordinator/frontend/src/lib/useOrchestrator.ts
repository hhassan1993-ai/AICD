import { useCallback, useEffect, useRef, useState } from "react";
import { api, ApiRequestError, WS_URL } from "./api";
import {
  WsMessageSchema,
  type LogEvent,
  type StateSnapshot,
} from "./types";

const MAX_LOG_LINES = 500;
const RECONNECT_BASE_MS = 500;
const RECONNECT_MAX_MS = 8_000;

export type ConnectionStatus = "connecting" | "open" | "closed";

export interface Orchestrator {
  state: StateSnapshot | null;
  logs: LogEvent[];
  connection: ConnectionStatus;
  lastError: string | null;
  runPhase: (phase: number) => Promise<void>;
  authorize: (decisions: Record<string, boolean>) => Promise<void>;
  reset: (simulateMismatch: boolean) => Promise<void>;
  clearError: () => void;
}

export function useOrchestrator(): Orchestrator {
  const [state, setState] = useState<StateSnapshot | null>(null);
  const [logs, setLogs] = useState<LogEvent[]>([]);
  const [connection, setConnection] = useState<ConnectionStatus>("connecting");
  const [lastError, setLastError] = useState<string | null>(null);

  const wsRef = useRef<WebSocket | null>(null);
  const attemptRef = useRef(0);
  const disposedRef = useRef(false);

  useEffect(() => {
    disposedRef.current = false;

    const connect = (): void => {
      if (disposedRef.current) return;
      setConnection("connecting");
      const ws = new WebSocket(WS_URL);
      wsRef.current = ws;

      ws.onopen = () => {
        attemptRef.current = 0;
        setConnection("open");
        // A reconnect replays the server-side backlog; reset the local
        // buffer so replayed lines are not duplicated.
        setLogs([]);
      };

      ws.onmessage = (event: MessageEvent<string>) => {
        let raw: unknown;
        try {
          raw = JSON.parse(event.data);
        } catch {
          console.warn("WS frame is not JSON; dropped");
          return;
        }
        const parsed = WsMessageSchema.safeParse(raw);
        if (!parsed.success) {
          console.warn("WS frame failed schema validation; dropped", parsed.error.issues);
          return;
        }
        const msg = parsed.data;
        if (msg.type === "state") {
          setState(msg.payload);
        } else {
          const entry = msg.payload;
          setLogs((prev) => {
            const next = [...prev, entry];
            return next.length > MAX_LOG_LINES ? next.slice(-MAX_LOG_LINES) : next;
          });
        }
      };

      ws.onclose = () => {
        if (disposedRef.current) return;
        setConnection("closed");
        const delay = Math.min(RECONNECT_BASE_MS * 2 ** attemptRef.current, RECONNECT_MAX_MS);
        attemptRef.current += 1;
        window.setTimeout(connect, delay);
      };

      ws.onerror = () => {
        ws.close();
      };
    };

    connect();
    return () => {
      disposedRef.current = true;
      wsRef.current?.close();
    };
  }, []);

  const guard = useCallback(async (op: () => Promise<void>): Promise<void> => {
    try {
      setLastError(null);
      await op();
    } catch (err) {
      const msg = err instanceof ApiRequestError ? err.message : "Unexpected client error";
      setLastError(msg);
    }
  }, []);

  const runPhase = useCallback((phase: number) => guard(() => api.runPhase(phase)), [guard]);
  const authorize = useCallback(
    (decisions: Record<string, boolean>) => guard(() => api.authorize({ decisions })),
    [guard],
  );
  const reset = useCallback(
    (simulateMismatch: boolean) => guard(() => api.reset(simulateMismatch)),
    [guard],
  );
  const clearError = useCallback(() => setLastError(null), []);

  return { state, logs, connection, lastError, runPhase, authorize, reset, clearError };
}
