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

export type Land = "rust" | "go" | "cpp" | "python";
/**
 * Every land, in the order the lands screen shows them and the keys cycle
 * through them. One list so a fifth land is one edit, not a hunt through every
 * ternary that used to spell out "rust or go".
 */
export const LANDS: readonly Land[] = ["rust", "go", "cpp", "python"];
export function isLand(v: unknown): v is Land {
  return typeof v === "string" && (LANDS as readonly string[]).includes(v);
}
export type Category = "basic" | "advanced" | "hacker";
/** The languages quest prose can arrive in (SPEC §12.1); `"en"` is the source. */
export type TextLocale = "en" | "ko" | "yue" | "zh" | "ja" | "cs";
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
  /**
   * §4.7 — the language `title` is in: the `locale` the map was asked with
   * when a translation of this quest exists, `"en"` otherwise. Per node, since
   * a translation may cover a pack partially. Optional because a server that
   * has not shipped §12.1 omits it, which reads as English.
   */
  text_locale?: TextLocale;
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
  /**
   * §4.8 — which language `title`, `story`, `brief` and the hints are in.
   * `"en"` unless the server substituted a translation for the `locale` we
   * sent; the code fields are the same in every language. A scene compares it
   * with the UI locale to decide whether to say "the brief is in English".
   * Optional for the usual reason: an older server omits it, meaning English.
   */
  text_locale?: TextLocale;
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
  /**
   * §4.8 — the source of the player's own most recent run or submit on this
   * quest, `null` on a quest nobody has touched. Not a second copy of
   * anything: every run and submit already stores its source (SPEC §2.2), so
   * this is a read of what the server had. A client opens the editor on
   * `draft ?? starter`.
   *
   * Optional in this type for the same reason `opened_at` is — a server that
   * has not shipped §4.8's field omits it, and `??` treats that exactly like
   * the `null` an interview sends.
   */
  draft?: string | null;
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

/**
 * §5.6b. What to practise, ranked by the server so both clients agree.
 * `reason` is "stuck" (failed submits, not cleared) or "costly" (cleared, but
 * it took failures); every stuck entry precedes every costly one.
 */
export interface Weak {
  quest_id: string;
  land: Land;
  category: Category;
  node: number;
  title: string;
  failures: number;
  submits: number;
  failure_rate: number;
  hints_used: number;
  cleared: boolean;
  reason: "stuck" | "costly";
}

/**
 * §5.13. Where the server last saw this player. `category` and `quest_id` are
 * null when they were in a lobby rather than on a stage — a real place to be,
 * and not the same as never having played.
 */
export interface Position {
  land: Land;
  category: Category | null;
  quest_id: string | null;
  updated_at: string;
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
  /** What the program reads. A scratchpad has no test cases to supply it. */
  stdin: string;
  created_at: string;
  updated_at: string;
}

/** The same thing without the text, for the list. */
export type SnippetBrief = Omit<Snippet, "source" | "stdin"> & { bytes: number };

/**
 * The edit stack for one quest: a stack with a cursor, which is what makes
 * redo possible at all.
 *
 * `cursor` is how many entries are applied, so the text the player should be
 * looking at is entry `cursor - 1` — and `source` is `null` when the cursor is
 * at the bottom, which means "the quest's starter" rather than "no text". A
 * client renders exactly what it is told here and never models the stack
 * itself: every one of the five `edit.*` messages answers the whole state, so
 * there is no way for a client's idea of the depth to drift from the server's.
 */
export interface EditState {
  quest_id: string;
  /** The text at the cursor. `null` means the quest's starter. */
  source: string | null;
  /** 0..depth. */
  cursor: number;
  /** How many entries are on the stack. */
  depth: number;
  /** `cursor > 0`, sent rather than derived so the rule lives in one place. */
  can_undo: boolean;
  /** `cursor < depth`. */
  can_redo: boolean;
}

export interface Requests {
  ping: Record<string, never>;
  "auth.challenge": { address: string };
  "auth.login": { address: string; signature: string; name?: string };
  "auth.resume": { token: string };
  "profile.update": { name?: string; settings?: Record<string, unknown> };
  "world.lands": Record<string, never>;
  /** `locale` on these four is the UI language; §4.7/§4.8 substitute quest
   *  prose where a translation exists and answer `text_locale` either way. */
  "world.map": { land: Land; category: Category; locale?: string };
  "quest.get": { quest_id: string; locale?: string };
  "quest.submit": { quest_id: string; lang: Land; source: string };
  /** §4.9b — the same shape, deliberately, so one code path sends either. */
  "quest.run": { quest_id: string; lang: Land; source: string };
  "quest.hint": { quest_id: string; index: number; locale?: string };
  /** §4.11b — the whole answer, priced like the largest hint there is. */
  "quest.solve": { quest_id: string };
  "quest.reset": { quest_id: string };
  // The edit stack. Five messages, one shape of reply, and `source` is the
  // only payload field any of them adds — everything else the screen needs to
  // draw its three buttons comes back in the state.
  "edit.state": { quest_id: string };
  /** Over 256 KiB is `bad_request`, the same cap `quest.submit` uses. */
  "edit.push": { quest_id: string; source: string };
  "edit.undo": { quest_id: string };
  "edit.redo": { quest_id: string };
  "edit.clear": { quest_id: string };
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
  "playground.save": { id?: string; name?: string; lang: Land; source: string; stdin?: string };
  "playground.list": Record<string, never>;
  "playground.load": { id: string };
  "playground.delete": { id: string };
  "stats.summary": Record<string, never>;
  "stats.mistakes": { limit?: number; include_learned?: boolean };
  /** §4.14c */
  "stats.weakest": { limit?: number };
  /** §4.14b. Documented in PROTOCOL but absent from this file until now. */
  "stats.awards": Record<string, never>;
  "stats.history": { quest_id?: string; limit?: number };
  "ai.plan": { mode: DrillMode; land?: Land; size?: number };
  "ai.next": { drill_id: string; locale?: string };
  "ai.finish": { drill_id: string };
}

export interface Responses {
  ping: { t: string };
  "auth.challenge": { nonce: string; message: string; expires_at: string };
  /** §4.3. `position` is null for a player who has never been anywhere. */
  "auth.login": { token: string; user: User; position: Position | null };
  "auth.resume": { token: string; user: User; position: Position | null };
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
  /**
   * §4.11b. `hints_used` comes back because the call just moved it — to the
   * quest's own hint count, in practice — and the screen has a control whose
   * label is that number. Nothing is recorded by asking: no attempt, no
   * history row. Only a later `quest.submit` writes anything.
   */
  "quest.solve": { source: string; hints_used: number };
  "quest.reset": { starter: string };
  /**
   * All five answer the whole state, unwrapped — the payload *is* the
   * `EditState`. That is not a shortcut: it is what makes the five messages
   * interchangeable at the call site, so one `applyEdit` handles every reply
   * and a client can never end up drawing a stale depth next to a fresh
   * cursor.
   */
  "edit.state": EditState;
  "edit.push": EditState;
  "edit.undo": EditState;
  "edit.redo": EditState;
  "edit.clear": EditState;
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
  /** §4.14c. An empty list is the normal answer for a player who has failed
   *  nothing — never an error. */
  "stats.weakest": { weakest: Weak[] };
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
