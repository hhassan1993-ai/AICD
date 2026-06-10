import type { Coordinate } from "./types";

/** Format a metre value to exactly 3 decimal places (ISO display convention). */
export function fmtM(value: number): string {
  if (!Number.isFinite(value)) return "—";
  // Avoid "-0.000" artefacts from tiny negative floats.
  const v = Object.is(value, -0) || Math.abs(value) < 5e-4 ? Math.abs(value) * Math.sign(value || 1) : value;
  const s = v.toFixed(3);
  return s === "-0.000" ? "0.000" : s;
}

/** "(x, y, z)" tuple in metres, 3 d.p. */
export function fmtCoord(c: Coordinate): string {
  return `(${fmtM(c.x)}, ${fmtM(c.y)}, ${fmtM(c.z)})`;
}

/** HH:MM:SS.mmm local timestamp for log lines. */
export function fmtTs(epochSeconds: number): string {
  const d = new Date(epochSeconds * 1000);
  const pad = (n: number, w = 2) => String(n).padStart(w, "0");
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`;
}
