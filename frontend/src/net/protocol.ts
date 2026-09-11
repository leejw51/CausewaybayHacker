/**
 * `PROTOCOL.md`, transcribed by hand into types.
 *
 * That file is the authority for everything that crosses the network; SPEC §6
 * is a summary of it. Nothing here is generated and nothing is inferred from
 * what a server happened to send — the shapes are copied from PROTOCOL §5, so
 * a field the server stops sending breaks a build rather than quietly becoming
 * `undefined` three screens later.
 *
 * Two habits this file exists to enforce:
 *
 *   - the error code set (§3.3) is closed, so a `switch` over it can be
 *     exhaustive and an unknown code is folded to `internal` in one place;
 *   - an unknown `type` is ignored rather than treated as an error (§2.3,
 *     conformance §8.3), which is what lets the server add events without
 *     breaking a client that is already shipped.
 */

export const PROTOCOL_VERSION = 1;

/** §2. Exactly these four keys, `payload` always an object. */
import { t } from "../i18n";

export interface Envelope<T = unknown> {
  v: number;
  id: string | null;
  type: string;
  payload: T;
}

/** §3.3, closed. An unknown code is a server bug and is treated as `internal`. */
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
  // §3.3, and it is **not** `internal`. A feature that is real, specified and
  // merely unbuilt answers this with `detail.milestone`, and a client that
  // folded it into `internal` would tell the player their machine is broken
  // and invite them to retry something that will never work.
  "unavailable",
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

/**
 * What a screen should do about an error, from §3.3's table. Kept next to the
 * codes so the table and the behaviour cannot drift.
 */
export type ErrorAction =
  | "update-client" // proto_version
  | "log-bug" // bad_request
  | "relogin" // unauthorized, auth_bad_signature
  | "rechallenge" // auth_expired, auth_nonce_used
  | "refresh-map" // not_found
  | "show-lock" // locked
  | "back-off" // rate_limited
  | "wait" // busy
  | "next-chapter" // unavailable
  | "retry"; // internal

export function actionFor(code: ErrorCode): ErrorAction {
  switch (code) {
    case "proto_version":
      return "update-client";
    case "bad_request":
      return "log-bug";
    case "unauthorized":
    case "auth_bad_signature":
      return "relogin";
    case "auth_expired":
    case "auth_nonce_used":
      return "rechallenge";
    case "not_found":
      return "refresh-map";
    case "locked":
      return "show-lock";
    case "rate_limited":
      return "back-off";
    case "busy":
      return "wait";
    case "unavailable":
      return "next-chapter";
    case "internal":
      return "retry";
  }
}

/**
 * What the player is told. PROTOCOL §3.3 is explicit that the `message` on an
 * error is "English, one line, for a log or a developer — **not** for the
 * player. A client renders its own text from `code`." So the server's prose
 * goes to `console.warn` and this goes on screen.
 */
export function playerText(code: ErrorCode): string {
  // One key per code, so the closed set in §3.3 and the closed set of strings
  // are the same set and a code added later is a missing key rather than a
  // silent fall-through.
  return t(`err.${code}` as "err.internal");
}

// ---------------------------------------------------------------------------
// §5 shared shapes
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

/** §5.1. `address` is EIP-55 on the wire, both directions (§2.4). */
export interface User {
  address: string;
  name: string;
  created_at: string;
  last_seen_at: string;
  settings: Record<string, unknown>;
  level: number;
  xp: number;
}

/** §5.2 */
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
  requires: string[];
  attempts: number;
}

/** §5.3. `tests.visible` carries only the shown cases; hidden ones are a count. */
export interface QuestTests {
  match: "exact" | "trim" | "tokens" | string;
  timeout_ms: number;
  visible: Array<{ name: string; stdin: string; expect: string }>;
  hidden_count: number;
}

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
  /**
   * §4.8b — the server's clock, not ours. The first `quest.get` stamps the
   * pair and every later one returns the same two instants, so a reload or a
   * second window shows *one* countdown rather than starting a new one. Both
   * are null on an untimed quest, and on a server that has not shipped §4.8b.
   */
  opened_at?: string | null;
  deadline_at?: string | null;
  starter: string;
  concepts: string[];
  hints_total: number;
  hints_used: number;
  state: NodeState;
  stars: Stars;
  tests: QuestTests;
  /** Omitted entirely until the player has cleared it (§4.8). */
  solution?: string;
}

/** §5.4 */
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
  col: number | null;
}

/**
 * §4.9b. A run is for the player and a submit is for the record, and this is
 * the field that says which one an attempt was. A `run` never clears a node,
 * never awards stars and is not counted among the node's attempts — but it *is*
 * recorded, and its mistakes do feed the drills.
 */
export type AttemptMode = "run" | "submit";

export interface Attempt {
  id: string;
  quest_id: string;
  /** Optional only so an older server's reply still parses; treat as "submit". */
  mode?: AttemptMode;
  verdict: Verdict;
  tests_passed: number;
  tests_total: number;
  compile_ms: number;
  run_ms: number;
  exit_code: number | null;
  stderr: string;
  cases: AttemptCase[];
  mistakes: AttemptMistake[];
  stars: Stars;
  /** "did *this* submission clear the node", not "is the node cleared". */
  cleared: boolean;
  created_at: string;
  /** §4.8b: whether it landed inside the time limit. Never a gate — a late
   *  submit is judged exactly like an early one; this only records it. */
  within_limit?: boolean;
}

/** §5.5 */
export interface SearchHit {
  quest_id: string;
  title: string;
  land: string;
  category: string;
  snippet: string;
  score: number;
  bm25: number | null;
  cosine: number | null;
  state: NodeState;
}

/**
 * §5.10. The shelf, as opposed to the fanfare (§4.14b).
 *
 * `kind: "stamp"` is deliberately absent from the union even though the live
 * `award` event can carry it: the per-clear stamp is a moment, not something a
 * player *has*, and it is never in `stats.awards`.
 */
export interface Award {
  kind: "badge" | "level" | "streak";
  id: string;
  title: string;
  detail: Record<string, unknown>;
  created_at: string;
}

/** §5.6 */
export interface MistakeStat {
  kind: string;
  label: string;
  count: number;
  last_at: string;
  cleared_since: number;
  example_quest_id: string | null;
  concepts: string[];
}

/** §5.7 */
export interface AttemptBrief {
  id: string;
  quest_id: string;
  verdict: string;
  tests_passed: number;
  tests_total: number;
  created_at: string;
  kinds: string[];
  /**
   * Observed on the wire and **not** in §5.7 — see `docs/decisions.md`. It
   * matters: a `run` never clears a node (§4.9b), so a history that does not
   * say which kind an attempt was reads as a string of failures on a quest the
   * player went on to clear. Optional, so an older server still parses.
   */
  mode?: AttemptMode;
}

/** §5.8 */
export interface Drill {
  id: string;
  mode: DrillMode;
  plan: string[];
  cursor: number;
  reason: string;
  created_at: string;
}

export type DrillMode = "repeat" | "weakness" | "spaced";
export type SearchMode = "bm25" | "semantic" | "unified";

export interface CategorySummary {
  category: Category;
  total: number;
  cleared: number;
  stars: number;
  /** False while the category's first node is still locked (§4.6). */
  open: boolean;
}

// ---------------------------------------------------------------------------
// §4 client → server
// ---------------------------------------------------------------------------

/**
 * §5.9 — what one playground run printed.
 *
 * Note what is *not* here: no verdict, no stars, no tests. A playground run is
 * not recorded and does not feed the drills (§4.9c), which is the deliberate
 * opposite of the quest RUN rule, because a scratchpad is exactly where
 * somebody writes something broken on purpose to see what the compiler says.
 */
export interface PlaygroundRun {
  /** Minted so the stream can be correlated; never stored. */
  attempt_id: string;
  lang: Land;
  outcome: "ok" | "compile_error" | "runtime_error" | "timeout" | "output_limit";
  compile_ms: number;
  run_ms: number;
  exit_code: number | null;
  stdout: string;
  stderr: string;
  diagnostics: Array<{
    kind: string;
    code: string | null;
    message: string;
    line: number | null;
    col: number | null;
  }>;
}

/** §5.9 — a saved scratchpad, per user, server-side. */
export interface Snippet {
  id: string;
  name: string;
  lang: Land;
  source: string;
  created_at: string;
  updated_at: string;
}

/** The same thing without the text, for the list. */
export type SnippetBrief = Omit<Snippet, "source"> & { bytes: number };

export interface Requests {
  ping: Record<string, never>;
  "auth.challenge": { address: string };
  "auth.login": { address: string; signature: string; name?: string };
  "auth.resume": { token: string };
  "profile.update": { name?: string; settings?: Record<string, unknown> };
  "world.lands": Record<string, never>;
  "world.map": { land: Land; category: Category };
  "quest.get": { quest_id: string };
  "quest.submit": { quest_id: string; lang: Land; source: string };
  /** §4.9b — the same shape, deliberately, so one code path sends either. */
  "quest.run": { quest_id: string; lang: Land; source: string };
  "quest.hint": { quest_id: string; index: number };
  "quest.reset": { quest_id: string };
  "search.query": {
    q: string;
    mode?: SearchMode;
    filters?: { land?: Land; category?: Category; state?: NodeState };
    limit?: number;
  };
  // §4.9c. `list`, `load` and `delete` are the snippet half; a server that
  // has not shipped them answers `not_found`, which the screen says out loud
  // rather than silently pretending the scratchpad is empty.
  // §4.9d. Never recorded: formatting is not an attempt at the problem.
  "code.format": { lang: Land; source: string };
  "playground.run": { lang: Land; source: string; stdin?: string };
  "playground.save": { id?: string; name?: string; lang: Land; source: string };
  "playground.list": Record<string, never>;
  "playground.load": { id: string };
  "playground.delete": { id: string };
  "stats.summary": Record<string, never>;
  "stats.mistakes": { limit?: number; include_learned?: boolean };
  /** §4.14b. Documented in PROTOCOL but absent from this file until now. */
  "stats.awards": Record<string, never>;
  "stats.history": { quest_id?: string; limit?: number };
  "ai.plan": { mode: DrillMode; land?: Land; size?: number };
  "ai.next": { drill_id: string };
  "ai.finish": { drill_id: string };
}

export interface Responses {
  ping: { t: string };
  "auth.challenge": { nonce: string; message: string; expires_at: string };
  "auth.login": { token: string; user: User };
  "auth.resume": { token: string; user: User };
  "profile.update": { user: User };
  "world.lands": { lands: Array<{ land: Land; categories: CategorySummary[] }> };
  "world.map": {
    land: Land;
    category: Category;
    nodes: MapNode[];
    /** Pairs of quest ids, given explicitly so a client never infers the shape. */
    edges: Array<[string, string]>;
  };
  "quest.get": { quest: Quest };
  "quest.submit": { attempt: Attempt };
  "quest.run": { attempt: Attempt };
  "quest.hint": { hint: string; index: number; total: number; hints_used: number };
  "quest.reset": { starter: string };
  /**
   * §4.9d. Source that does not parse is **not** an error: the reply is `.ok`,
   * `source` comes back byte for byte, `changed` is false and `problem` carries
   * the formatter's own one-line complaint.
   */
  "code.format": { source: string; changed: boolean; problem?: string };
  "playground.run": { run: PlaygroundRun };
  "playground.save": { snippet: Snippet };
  "playground.list": { snippets: SnippetBrief[] };
  "playground.load": { snippet: Snippet };
  "playground.delete": Record<string, never>;
  "search.query": { hits: SearchHit[]; mode: SearchMode; took_ms: number };
  "stats.summary": {
    cleared: number;
    total: number;
    attempts: number;
    accuracy: number;
    streak_days: number;
    stars: number;
    by_land: Array<{ land: Land; cleared: number; total: number }>;
  };
  "stats.mistakes": { mistakes: MistakeStat[] };
  "stats.awards": { awards: Award[] };
  "stats.history": { attempts: AttemptBrief[] };
  "ai.plan": { drill: Drill };
  "ai.next": { quest: Quest; position: number; total: number; why: string };
  "ai.finish": {
    summary: { attempted: number; cleared: number; kinds_improved: string[] };
  };
}

export type RequestType = keyof Requests & keyof Responses;

// ---------------------------------------------------------------------------
// §4.17–§4.21 server → client, `id: null`
// ---------------------------------------------------------------------------

export type RunStage = "queued" | "compiling" | "running" | "judging";
export type LogStream = "compile" | "stdout" | "stderr";

export interface Events {
  "run.stage": {
    attempt_id: string;
    stage: RunStage;
    queued?: number;
    elapsed_ms: number;
  };
  "run.log": {
    attempt_id: string;
    stream: LogStream;
    chunk: string;
    /** From 0, per stream per attempt, so a gap is detectable (§4.18). */
    seq: number;
  };
  "progress.update": {
    quest_id: string;
    state: NodeState;
    stars: Stars;
    cleared_total: number;
    /** The nodes this clear opened, so the map updates without refetching. */
    unlocked: string[];
  };
  award: {
    kind: "badge" | "stamp" | "level" | "streak" | string;
    id: string;
    title: string;
    detail: Record<string, unknown>;
  };
  "server.bye": { reason: "shutdown" | "revoked" | "replaced" | string };
}

export type EventType = keyof Events;
