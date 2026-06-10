import type { AuthorizationRequest } from "./types";

const API_BASE = "http://127.0.0.1:8000";
const REQUEST_TIMEOUT_MS = 10_000;

export class ApiRequestError extends Error {
  constructor(
    public readonly status: number,
    public readonly detail: string,
  ) {
    super(`HTTP ${status}: ${detail}`);
    this.name = "ApiRequestError";
  }
}

async function post(path: string, body: unknown): Promise<void> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const res = await fetch(`${API_BASE}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    if (!res.ok) {
      let detail = res.statusText;
      try {
        const data: unknown = await res.json();
        if (typeof data === "object" && data !== null && "detail" in data) {
          detail = String((data as { detail: unknown }).detail);
        }
      } catch {
        /* non-JSON error body — keep statusText */
      }
      throw new ApiRequestError(res.status, detail);
    }
  } catch (err) {
    if (err instanceof ApiRequestError) throw err;
    if (err instanceof DOMException && err.name === "AbortError") {
      throw new ApiRequestError(0, `Request timed out after ${REQUEST_TIMEOUT_MS / 1000}s`);
    }
    throw new ApiRequestError(0, err instanceof Error ? err.message : "Network failure");
  } finally {
    clearTimeout(timer);
  }
}

export const api = {
  runPhase: (phase: number) => post(`/api/phase/${phase}/run`, {}),
  authorize: (payload: AuthorizationRequest) => post("/api/authorize", payload),
  reset: (simulateCoordinateMismatch: boolean) =>
    post("/api/reset", { simulate_coordinate_mismatch: simulateCoordinateMismatch }),
};

export const WS_URL = "ws://127.0.0.1:8000/ws";
