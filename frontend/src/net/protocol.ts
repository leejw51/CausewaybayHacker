/**
 * SPEC §6, transcribed by hand into types.
 *
 * Nothing here is generated, and nothing here is inferred from what the server
 * happens to send: the spec is the contract, so a field the server stops
 * sending should break a build rather than quietly become `undefined` three
 * screens later. Every `.ok` payload in §6.2 has a type, every server event in
 * §6.2's second table has a type, and the error code set in §6.1 is closed.
 */

export const PROTOCOL_VERSION = 1;

/** §6.1. `id` is null on a server-initiated event, and only then. */
export interface Envelope<T = unknown> {
  v: number;
  id: string | null;
  type: string;
  payload: T;
}

/** §6.1, closed. An unknown code is a protocol bug, not a new case to handle. */
export const ERROR_CODES = [
  "proto_version",
  "bad_request",
  "unauthorized",
  "auth_expired",
  "auth_nonce_used",
  "auth_bad_signature",
  "not_found",
  "locked",
  "rate_limited",
  "busy",
  "internal",
] as const;
export type ErrorCode = (typeof ERROR_CODES)[number];

export interface ErrorPayload {
  code: ErrorCode;
  message: string;
  detail: Record<string, unknown>;
}

export function isErrorCode(x: unknown): x is ErrorCode {
  return typeof x === "string" && (ERROR_CODES as readonly string[]).includes(x);
}

// ---------------------------------------------------------------------------
// §6.3 shared shapes
// ---------------------------------------------------------------------------

export type Land = "rust" | "go";
export type Category = "basic" | "advanced" | "hacker";
export type NodeState = "locked" | "open" | "cleared";
export type Stars = 0 | 1 | 2 | 3;
export type Difficulty = 1 | 2 | 3 | 4 | 5;

export type Verdict =
  | "accepted"
  | "wrong_answer"
  | "compile_error"
  | "runtime_error"
  | "timeout"
  | "output_limit"
  | "internal_error";

export interface MapNode {
  quest_id: string;
  node: number;
  title: string;
  difficulty: Difficulty;
  state: NodeState;
  stars: Stars;
  /** 0..1 of the map image, so the art can be swapped without touching content. */
  x: number;
  y: number;
  kind: "quest" | "boss" | "gate";
}

export interface AttemptCase {
  name: string;
  passed: boolean;
  visible: boolean;
  stdin?: string;
  expect?: string;
  got?: string;
}

export interface AttemptMistake {
  kind: string;
  code: string | null;
  message: string;
  line: number | null;
}

export interface Attempt {
  id: string;
  verdict: Verdict;
  tests_passed: number;
  tests_total: number;
  compile_ms: number;
  run_ms: number;
  stderr: string;
  cases: AttemptCase[];
  mistakes: AttemptMistake[];
  stars: Stars;
  cleared: boolean;
}

export interface SearchHit {
  quest_id: string;
  title: string;
  snippet: string;
  score: number;
  bm25: number | null;
  cosine: number | null;
}

export interface MistakeStat {
  kind: string;
  label: string;
  count: number;
  last_at: string;
  cleared_since: number;
  example_quest_id: string | null;
}

/** §2.1 `users`, as it comes back on the wire. */
export interface User {
  address: string;
  address_eip55: string;
  name: string;
  created_at: string;
  last_seen_at: string;
  settings: Record<string, unknown>;
}

/**
 * `quest.get`'s quest. `solution` is absent unless the player has cleared it
 * (SPEC §6.2), so it is optional here and must be treated as usually missing.
 */
export interface Quest {
  id: string;
  land: Land;
  category: Category;
  node: number;
  title: string;
  brief: string;
  story: string;
  difficulty: Difficulty;
  time_limit_s: number | null;
  starter: string;
  hints_total: number;
  concepts: string[];
  solution?: string;
}

// ---------------------------------------------------------------------------
// §6.2 client → server
// ---------------------------------------------------------------------------

export interface Requests {
  "auth.challenge": { address: string };
  "auth.login": { address: string; signature: string };
  "auth.resume": { token: string };
  "profile.update": { name?: string; settings?: Record<string, unknown> };
  "world.lands": Record<string, never>;
  "world.map": { land: Land; category: Category };
  "quest.get": { quest_id: string };
  "quest.submit": { quest_id: string; source: string; lang: Land };
  "quest.hint": { quest_id: string; index: number };
  "quest.reset": { quest_id: string };
  "search.query": {
    q: string;
    mode: "bm25" | "semantic" | "unified";
    filters?: Record<string, unknown>;
    limit?: number;
  };
  "stats.summary": Record<string, never>;
  "stats.mistakes": { limit?: number };
  "stats.history": { quest_id?: string; limit?: number };
  "ai.plan": { mode: "repeat" | "weakness" | "spaced"; land?: Land; size?: number };
  "ai.next": { drill_id: string };
  "ai.finish": { drill_id: string };
  ping: Record<string, never>;
}

export interface Responses {
  "auth.challenge": { nonce: string; message: string; expires_at: string };
  "auth.login": { token: string; user: User };
  "auth.resume": { token: string; user: User };
  "profile.update": { user: User };
  "world.lands": {
    lands: Array<{
      land: Land;
      categories: Array<{ category: Category; total: number; cleared: number }>;
    }>;
  };
  "world.map": { nodes: MapNode[]; edges: Array<[number, number]> };
  "quest.get": { quest: Quest };
  "quest.submit": { attempt: Attempt };
  "quest.hint": { hint: string; hints_used: number };
  "quest.reset": { starter: string };
  "search.query": { hits: SearchHit[] };
  "stats.summary": {
    cleared: number;
    attempts: number;
    accuracy: number;
    streak: number;
    by_land: Array<{ land: Land; cleared: number; total: number }>;
  };
  "stats.mistakes": { mistakes: MistakeStat[] };
  "stats.history": { attempts: AttemptBrief[] };
  "ai.plan": { drill: Drill };
  "ai.next": { quest: Quest; position: number; total: number };
  "ai.finish": { summary: Record<string, unknown> };
  ping: { t: number };
}

export interface AttemptBrief {
  id: string;
  quest_id: string;
  verdict: Verdict;
  tests_passed: number;
  tests_total: number;
  created_at: string;
}

export interface Drill {
  id: string;
  mode: "repeat" | "weakness" | "spaced";
  plan: string[];
  cursor: number;
}

export type RequestType = keyof Requests & keyof Responses;

// ---------------------------------------------------------------------------
// §6.2 server → client, `id: null`
// ---------------------------------------------------------------------------

export interface Events {
  "run.log": { attempt_id: string; stream: "compile" | "stdout" | "stderr"; chunk: string };
  "run.stage": {
    attempt_id: string;
    stage: "queued" | "compiling" | "running" | "judging";
  };
  "progress.update": {
    quest_id: string;
    state: NodeState;
    stars: Stars;
    cleared_total: number;
  };
  award: { kind: string; title: string; detail: Record<string, unknown> };
  "server.bye": { reason: string };
}

export type EventType = keyof Events;

export const EVENT_TYPES: EventType[] = [
  "run.log",
  "run.stage",
  "progress.update",
  "award",
  "server.bye",
];
