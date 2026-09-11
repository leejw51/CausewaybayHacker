/**
 * The envelope, encoded and decoded, and nothing else.
 *
 * It is its own module, with no dependency on a socket, because the framing is
 * the thing both ends have to agree on byte for byte — so it is the thing that
 * gets a unit test. Every decode failure comes back as a *value* rather than a
 * throw: a frame from a server that is mid-deploy should show the player an
 * error, not stop the render loop.
 */
import { PROTOCOL_VERSION, type Envelope, type ErrorPayload, isErrorCode } from "./protocol";

export type Decoded =
  { kind: "ok"; frame: Envelope } | { kind: "bad"; reason: string; raw: string };

/**
 * PROTOCOL §2: exactly `v`, `id`, `type`, `payload`, and `payload` is always an
 * object. The server answers a frame with a fifth key `bad_request` rather than
 * ignoring it, so this never adds one.
 */
export function encode(id: string | null, type: string, payload: unknown): string {
  const body = payload && typeof payload === "object" && !Array.isArray(payload) ? payload : {};
  return JSON.stringify({ v: PROTOCOL_VERSION, id, type, payload: body } satisfies Envelope);
}

export function decode(raw: string): Decoded {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { kind: "bad", reason: "not json", raw };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { kind: "bad", reason: "frame is not an object", raw };
  }
  const f = parsed as Record<string, unknown>;
  if (typeof f.v !== "number") return { kind: "bad", reason: "missing v", raw };
  if (typeof f.type !== "string" || f.type === "") {
    return { kind: "bad", reason: "missing type", raw };
  }
  // `id: null` is meaningful — it is what marks a server event — so undefined
  // and null are not interchangeable here the way they usually are in JSON.
  if (!(f.id === null || typeof f.id === "string")) {
    return { kind: "bad", reason: "id must be a string or null", raw };
  }
  // Extra top-level keys are tolerated on the way *in*. The server is strict
  // about what it receives (§2); a client that was equally strict about what it
  // receives could not be forward-compatible, which §2.3 requires it to be.
  const payload =
    f.payload && typeof f.payload === "object" && !Array.isArray(f.payload) ? f.payload : {};
  return {
    kind: "ok",
    frame: { v: f.v, id: f.id, type: f.type, payload: payload as Record<string, unknown> },
  };
}

export function isEvent(frame: Envelope): boolean {
  return frame.id === null;
}

/** §2.3: a reply is `<type>.ok` or `<type>.err`. Anything else is not a reply. */
export function replyKind(type: string): { base: string; ok: boolean } | null {
  if (type.endsWith(".ok")) return { base: type.slice(0, -3), ok: true };
  if (type.endsWith(".err")) return { base: type.slice(0, -4), ok: false };
  return null;
}

/**
 * Coerce an `.err` payload into §3.3's shape. "A code not in this table is a
 * server bug. A client encountering one should treat it as `internal`" — and
 * keep what it actually said, so the bug is reportable.
 */
export function asError(payload: unknown): ErrorPayload {
  const p = (payload ?? {}) as Record<string, unknown>;
  const code = p.code;
  const detail = (p.detail as Record<string, unknown>) ?? {};
  if (isErrorCode(code)) {
    return { code, message: typeof p.message === "string" ? p.message : code, detail };
  }
  return {
    code: "internal",
    message: typeof p.message === "string" ? p.message : "the server sent an unknown error",
    detail: { unknown_code: code ?? null, ...detail },
  };
}

/**
 * The client's correlation ids: `c-<n>` (§2.2). A monotonic counter, so an id
 * is never reused while one is in flight — reuse is `bad_request`.
 */
export function makeIdSource(prefix = "c"): () => string {
  let n = 0;
  return () => `${prefix}-${++n}`;
}
