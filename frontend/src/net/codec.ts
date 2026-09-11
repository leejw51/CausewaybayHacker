/**
 * The envelope, encoded and decoded, with nothing else in it.
 *
 * This is deliberately its own module and deliberately has no dependency on a
 * socket: the framing is the thing both ends have to agree on, so it is the
 * thing that gets a unit test. Every decode failure comes back as a value
 * rather than a throw, because a frame from a server that is mid-deploy should
 * show the player an error, not stop the render loop.
 */
import { PROTOCOL_VERSION, type Envelope, type ErrorPayload, isErrorCode } from "./protocol";

export type Decoded =
  | { kind: "ok"; frame: Envelope }
  | { kind: "bad"; reason: string; raw: string };

export function encode(id: string | null, type: string, payload: unknown): string {
  // `payload` is an object, never a bare value and never absent (SPEC §6.1).
  const body = payload && typeof payload === "object" ? payload : {};
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

/** §6.1: a reply is `<type>.ok` or `<type>.err`. */
export function replyKind(type: string): { base: string; ok: boolean } | null {
  if (type.endsWith(".ok")) return { base: type.slice(0, -3), ok: true };
  if (type.endsWith(".err")) return { base: type.slice(0, -4), ok: false };
  return null;
}

/**
 * Coerce an `.err` payload into the §6.1 shape. A code outside the closed set
 * becomes `internal` with the original kept in `detail`, so an unexpected
 * server never crashes the client and never loses what it said.
 */
export function asError(payload: unknown): ErrorPayload {
  const p = (payload ?? {}) as Record<string, unknown>;
  const code = p.code;
  if (isErrorCode(code)) {
    return {
      code,
      message: typeof p.message === "string" ? p.message : code,
      detail: (p.detail as Record<string, unknown>) ?? {},
    };
  }
  return {
    code: "internal",
    message: typeof p.message === "string" ? p.message : "the server sent an unknown error",
    detail: { unknown_code: code ?? null, ...((p.detail as Record<string, unknown>) ?? {}) },
  };
}

/** The client's correlation ids: `c-<n>`, per §6.1. */
export function makeIdSource(prefix = "c"): () => string {
  let n = 0;
  return () => `${prefix}-${++n}`;
}
