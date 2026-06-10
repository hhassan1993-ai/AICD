/**
 * Runtime-validated types mirroring the backend Pydantic models.
 * Every inbound WebSocket frame is parsed through these schemas; frames that
 * fail validation are dropped (never rendered) and logged to the console.
 *
 * All spatial values are metres (ISO). Formatting to 3 d.p. lives in format.ts.
 */
import { z } from "zod";

export const CoordinateSchema = z.object({
  x: z.number(),
  y: z.number(),
  z: z.number(),
});
export type Coordinate = z.infer<typeof CoordinateSchema>;

export const AgentStatusSchema = z.enum([
  "idle",
  "running",
  "awaiting_authorization",
  "halted",
  "complete",
  "error",
]);
export type AgentStatus = z.infer<typeof AgentStatusSchema>;

export const PhaseRecordSchema = z.object({
  phase: z.number().int().min(1).max(5),
  name: z.string(),
  status: z.enum(["pending", "running", "complete", "halted", "skipped_locked"]),
});
export type PhaseRecord = z.infer<typeof PhaseRecordSchema>;

export const ModelInfoSchema = z.object({
  model_id: z.string(),
  name: z.string(),
  discipline: z.enum(["ARC", "STR", "MEP"]),
  survey_point: CoordinateSchema,
  deviation_m: z.number().nonnegative(),
  within_tolerance: z.boolean(),
});
export type ModelInfo = z.infer<typeof ModelInfoSchema>;

export const ClashResultSchema = z.object({
  clash_id: z.string(),
  element_a_id: z.string(),
  element_a_name: z.string(),
  element_b_id: z.string(),
  element_b_name: z.string(),
  category_a: z.string(),
  category_b: z.string(),
  location: CoordinateSchema,
  penetration_depth_m: z.number().nonnegative(),
  severity: z.enum(["critical", "major", "minor"]),
});
export type ClashResult = z.infer<typeof ClashResultSchema>;

export const ProposalStatusSchema = z.enum(["pending", "approved", "rejected", "applied"]);
export type ProposalStatus = z.infer<typeof ProposalStatusSchema>;

export const ResolutionProposalSchema = z.object({
  proposal_id: z.string(),
  clash_id: z.string(),
  element_id: z.string(),
  element_name: z.string(),
  current_location: CoordinateSchema,
  proposed_location: CoordinateSchema,
  shift_vector: CoordinateSchema,
  rationale: z.string(),
  status: ProposalStatusSchema,
});
export type ResolutionProposal = z.infer<typeof ResolutionProposalSchema>;

export const LogEventSchema = z.object({
  ts: z.number(),
  level: z.enum(["info", "warn", "error", "ok", "mcp"]),
  source: z.string(),
  message: z.string(),
});
export type LogEvent = z.infer<typeof LogEventSchema>;

export const StateSnapshotSchema = z.object({
  status: AgentStatusSchema,
  current_phase: z.number().int().min(0).max(5),
  completed_phase: z.number().int().min(0).max(5),
  halt_reason: z.string().nullable(),
  phases: z.array(PhaseRecordSchema),
  models: z.array(ModelInfoSchema),
  clashes: z.array(ClashResultSchema),
  proposals: z.array(ResolutionProposalSchema),
  mcp_call_counts: z.record(z.string(), z.number().int().nonnegative()),
  simulate_coordinate_mismatch: z.boolean(),
});
export type StateSnapshot = z.infer<typeof StateSnapshotSchema>;

export const WsMessageSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("state"), payload: StateSnapshotSchema }),
  z.object({ type: z.literal("log"), payload: LogEventSchema }),
]);
export type WsMessage = z.infer<typeof WsMessageSchema>;

/** HITL gate payload — values are strict booleans by construction. */
export interface AuthorizationRequest {
  decisions: Record<string, boolean>;
}
