/**
 * PROTOCOL §2 framing, §3.3 errors, and the client half of the §8 conformance
 * checklist.
 *
 * The codec gets a test of its own because it is the one piece both ends have
 * to agree on byte for byte. The client gets one because the rules that are
 * easiest to get wrong — out-of-order replies, token rotation, one in-flight
 * submit — all look fine in a happy-path demo and only fail in production.
 */
import { describe, expect, it, vi } from "vitest";
import { asError, decode, encode, makeIdSource, replyKind } from "../src/net/codec";
import { Client, WireError } from "../src/net/client";
import { actionFor, ERROR_CODES } from "../src/net/protocol";
import type { Transport, TransportHandlers } from "../src/net/transport";

describe("the envelope", () => {
  it("always carries v, id, type and an object payload", () => {
    expect(JSON.parse(encode("c-42", "quest.submit", { quest_id: "rust.basic.01.hello" }))).toEqual({
      v: 1,
      id: "c-42",
      type: "quest.submit",
      payload: { quest_id: "rust.basic.01.hello" },
    });
  });

  it("never sends a bare value or a missing payload (§6.1)", () => {
    expect(JSON.parse(encode("c-1", "ping", undefined)).payload).toEqual({});
    expect(JSON.parse(encode("c-1", "ping", 7 as unknown)).payload).toEqual({});
    expect(JSON.parse(encode(null, "run.log", null)).payload).toEqual({});
  });

  it("round-trips", () => {
    const d = decode(encode("c-9", "world.map", { land: "rust", category: "basic" }));
    expect(d.kind).toBe("ok");
    if (d.kind !== "ok") return;
    expect(d.frame).toEqual({
      v: 1,
      id: "c-9",
      type: "world.map",
      payload: { land: "rust", category: "basic" },
    });
  });

  it("keeps id: null distinct from a missing id, because it marks an event", () => {
    const ev = decode('{"v":1,"id":null,"type":"run.log","payload":{"chunk":"x"}}');
    expect(ev.kind).toBe("ok");
    if (ev.kind === "ok") expect(ev.frame.id).toBeNull();
    expect(decode('{"v":1,"type":"run.log","payload":{}}').kind).toBe("bad");
  });

  it("refuses a malformed frame as a value, not a throw", () => {
    expect(decode("not json").kind).toBe("bad");
    expect(decode("[1,2,3]").kind).toBe("bad");
    expect(decode('{"id":"c-1","type":"ping","payload":{}}').kind).toBe("bad"); // no v
    expect(decode('{"v":1,"id":"c-1","payload":{}}').kind).toBe("bad"); // no type
  });

  it("tolerates a payload that is absent or the wrong shape", () => {
    const d = decode('{"v":1,"id":"c-1","type":"ping"}');
    expect(d.kind).toBe("ok");
    if (d.kind === "ok") expect(d.frame.payload).toEqual({});
  });

  it("splits a reply into its base type and its verdict", () => {
    expect(replyKind("quest.submit.ok")).toEqual({ base: "quest.submit", ok: true });
    expect(replyKind("quest.submit.err")).toEqual({ base: "quest.submit", ok: false });
    expect(replyKind("run.log")).toBeNull();
  });

  it("numbers client ids c-1, c-2, …", () => {
    const next = makeIdSource();
    expect([next(), next(), next()]).toEqual(["c-1", "c-2", "c-3"]);
  });
});

describe("the closed error-code set (§6.1)", () => {
  it("passes a known code through", () => {
    expect(asError({ code: "locked", message: "clear the node before it", detail: { node: 2 } })).toEqual(
      { code: "locked", message: "clear the node before it", detail: { node: 2 } },
    );
  });

  it("folds an unknown code into internal without losing it", () => {
    const e = asError({ code: "teapot", message: "no" });
    expect(e.code).toBe("internal");
    expect(e.detail.unknown_code).toBe("teapot");
  });
});

// ---------------------------------------------------------------------------

/** A transport that records what was sent and lets a test answer it. */
function harness() {
  const sent: Array<{ id: string | null; type: string; payload: Record<string, unknown> }> = [];
  let handlers: TransportHandlers | null = null;
  const client = new Client({
    transport: (h) => {
      handlers = h;
      const t: Transport = {
        send: (text) => {
          const d = decode(text);
          if (d.kind === "ok") {
            sent.push({
              id: d.frame.id,
              type: d.frame.type,
              payload: d.frame.payload as Record<string, unknown>,
            });
          }
        },
        close: () => h.onClose("test closed"),
      };
      queueMicrotask(() => h.onOpen());
      return t;
    },
    storage: memoryStorage(),
    keepalive: false,
  });
  return {
    client,
    sent,
    reply: (id: string, type: string, payload: unknown) =>
      handlers!.onMessage(encode(id, type, payload)),
    event: (type: string, payload: unknown) => handlers!.onMessage(encode(null, type, payload)),
    raw: (text: string) => handlers!.onMessage(text),
  };
}

function memoryStorage() {
  const m = new Map<string, string>();
  return {
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => void m.set(k, v),
    removeItem: (k: string) => void m.delete(k),
  };
}

const USER = {
  address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", // EIP-55 on the wire
  name: "hacker",
  created_at: "2026-09-11T04:12:33Z",
  last_seen_at: "2026-09-11T04:12:33Z",
  settings: {},
  level: 1,
  xp: 0,
};

describe("the client", () => {
  it("correlates a reply to its request by id", async () => {
    const h = harness();
    h.client.connect();
    await h.client.waitFor("open");
    const p = h.client.request("ping", {});
    expect(h.sent[0].type).toBe("ping");
    h.reply(h.sent[0].id!, "ping.ok", { t: 99 });
    await expect(p).resolves.toEqual({ t: 99 });
  });

  it("rejects with the server's error code", async () => {
    const h = harness();
    h.client.connect();
    await h.client.waitFor("open");
    const p = h.client.request("auth.challenge", { address: "0x00" });
    h.reply(h.sent[0].id!, "auth.challenge.err", {
      code: "bad_request",
      message: "that is not an address",
      detail: {},
    });
    await expect(p).rejects.toBeInstanceOf(WireError);
    await p.catch((e: WireError) => expect(e.payload.code).toBe("bad_request"));
  });

  it("refuses anything but ping and auth before login (§6.4)", async () => {
    const h = harness();
    h.client.connect();
    await h.client.waitFor("open");
    await expect(h.client.request("world.lands", {})).rejects.toMatchObject({
      payload: { code: "unauthorized" },
    });
    expect(h.sent).toHaveLength(0);
  });

  it("allows one in-flight quest.submit and calls the second busy (§6.4)", async () => {
    const h = harness();
    h.client.connect();
    await h.client.waitFor("open");
    const login = h.client.login(USER.address, "0x" + "11".repeat(65));
    h.reply(h.sent[0].id!, "auth.login.ok", { token: "tok", user: USER });
    await login;

    const first = h.client.request("quest.submit", {
      quest_id: "rust.basic.01.hello",
      source: "fn main() {}",
      lang: "rust",
    });
    await expect(
      h.client.request("quest.submit", {
        quest_id: "rust.basic.01.hello",
        source: "fn main() {}",
        lang: "rust",
      }),
    ).rejects.toMatchObject({ payload: { code: "busy" } });

    const submitId = h.sent[h.sent.length - 1].id!;
    h.reply(submitId, "quest.submit.ok", { attempt: { id: "att_0", verdict: "accepted" } });
    await first;
    // Once the first one lands, the slot is free again.
    const third = h.client.request("quest.submit", {
      quest_id: "rust.basic.01.hello",
      source: "fn main() {}",
      lang: "rust",
    });
    h.reply(h.sent[h.sent.length - 1].id!, "quest.submit.ok", { attempt: { id: "att_1" } });
    await expect(third).resolves.toBeTruthy();
  });

  it("delivers id:null frames to event listeners and not to pending requests", async () => {
    const h = harness();
    h.client.connect();
    await h.client.waitFor("open");
    const chunks: string[] = [];
    h.client.on("run.log", (p) => chunks.push(p.chunk));
    h.event("run.log", { attempt_id: "att_0", stream: "compile", chunk: "Compiling\n" });
    h.event("run.log", { attempt_id: "att_0", stream: "stdout", chunk: "hello\n" });
    expect(chunks).toEqual(["Compiling\n", "hello\n"]);
  });

  it("persists only the token, never key material", async () => {
    const storage = memoryStorage();
    let handlers: TransportHandlers | null = null;
    const client = new Client({
      transport: (h) => {
        handlers = h;
        queueMicrotask(() => h.onOpen());
        return { send: () => {}, close: () => h.onClose("bye") };
      },
      storage,
      keepalive: false,
    });
    client.connect();
    await client.waitFor("open");
    const p = client.login(USER.address, "0xdeadbeef");
    handlers!.onMessage(encode("c-1", "auth.login.ok", { token: "sess-token", user: USER }));
    await p;
    expect(client.token).toBe("sess-token");
    expect(storage.getItem("cwbhacker.token")).toBe("sess-token");
    client.forgetToken();
    expect(client.token).toBeNull();
  });

  it("fails every pending request when the connection drops", async () => {
    const h = harness();
    h.client.connect();
    await h.client.waitFor("open");
    const p = h.client.request("ping", {});
    const caught = p.catch((e: WireError) => e.payload.code);
    h.client.close();
    // `close()` is the deliberate kind; the drop path is what a scene sees.
    await expect(caught).resolves.toBe("internal");
    vi.useRealTimers();
  });
});

describe("§8 conformance, the parts that are the client's", () => {
  it("§8.2 matches out-of-order replies by id", async () => {
    const h = harness();
    h.client.connect();
    await h.client.waitFor("open");
    const login = h.client.login(USER.address, "0x" + "11".repeat(65));
    h.reply(h.sent[0].id!, "auth.login.ok", { token: "tok", user: USER });
    await login;

    const slow = h.client.request("quest.submit", {
      quest_id: "rust.basic.01.hello",
      lang: "rust",
      source: "fn main() {}",
    });
    const fast = h.client.request("ping", {});
    const slowId = h.sent[1].id!;
    const fastId = h.sent[2].id!;
    // The ping was sent second and comes back first, which is exactly what a
    // client that queued replies would get wrong.
    h.reply(fastId, "ping.ok", { t: "2026-09-11T04:12:33Z" });
    await expect(fast).resolves.toEqual({ t: "2026-09-11T04:12:33Z" });
    h.reply(slowId, "quest.submit.ok", { attempt: { id: "att_0", verdict: "accepted" } });
    await expect(slow).resolves.toHaveProperty("attempt.id", "att_0");
  });

  it("§8.3 ignores an unknown event type instead of erroring", async () => {
    const h = harness();
    h.client.connect();
    await h.client.waitFor("open");
    const seen: string[] = [];
    h.client.on("award", () => seen.push("award"));
    // A type this version of the client has never heard of.
    expect(() => h.event("leaderboard.update", { who: "someone" })).not.toThrow();
    h.event("award", { kind: "stamp", id: "cleared", title: "CLEARED", detail: {} });
    expect(seen).toEqual(["award"]);
  });

  it("§8.3 leaves a request pending when an unknown non-reply carries its id", async () => {
    const h = harness();
    h.client.connect();
    await h.client.waitFor("open");
    let settled = false;
    const p = h.client.request("ping", {}).then(
      () => (settled = true),
      () => (settled = true),
    );
    const id = h.sent[0].id!;
    h.reply(id, "ping.progress", { pct: 50 }); // neither .ok nor .err
    await Promise.resolve();
    expect(settled).toBe(false);
    h.reply(id, "ping.ok", { t: "now" });
    await p;
    expect(settled).toBe(true);
  });

  it("§8.4 gives every code an action, and folds an unknown one to internal", () => {
    for (const code of ERROR_CODES) expect(typeof actionFor(code)).toBe("string");
    expect(actionFor("locked")).toBe("show-lock");
    expect(actionFor("busy")).toBe("wait");
    expect(new WireError(asError({ code: "teapot" })).action).toBe("retry");
  });

  it("§8.7 stores the token auth.resume returns, not the one it sent", async () => {
    const h = harness();
    h.client.connect();
    await h.client.waitFor("open");
    const p = h.client.resume("old-token");
    expect(h.sent[0].payload.token).toBe("old-token");
    h.reply(h.sent[0].id!, "auth.resume.ok", { token: "rotated-token", user: USER });
    await p;
    expect(h.client.token).toBe("rotated-token");
  });

  it("§4.21 drops a revoked session rather than reconnecting onto a dead token", async () => {
    const h = harness();
    h.client.connect();
    await h.client.waitFor("open");
    const login = h.client.login(USER.address, "0x" + "11".repeat(65));
    h.reply(h.sent[0].id!, "auth.login.ok", { token: "tok", user: USER });
    await login;
    expect(h.client.token).toBe("tok");
    h.event("server.bye", { reason: "revoked" });
    expect(h.client.token).toBeNull();
    expect(h.client.needsLogin).toBe(true);
  });

  it("§2.1 keeps the connection when the server speaks another version", async () => {
    const h = harness();
    h.client.connect();
    await h.client.waitFor("open");
    const byes: string[] = [];
    h.client.on("server.bye", (p) => byes.push(p.reason));
    h.raw(JSON.stringify({ v: 99, id: null, type: "run.log", payload: {} }));
    expect(byes).toHaveLength(1);
    expect(h.client.state).not.toBe("offline");
  });
});
