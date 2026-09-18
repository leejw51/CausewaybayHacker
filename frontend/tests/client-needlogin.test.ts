/**
 * `Client#onNeedLogin`: the signal the app signs in again on, or goes to the
 * login screen on. It has to fire *after* `needsLogin` is set — the state
 * watcher's "open" comes before the resume is answered, which is how a tab
 * whose token was rotated under it used to sit open and anonymous for ever.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { decode, encode } from "../src/net/codec";
import { Client } from "../src/net/client";
import type { Transport, TransportHandlers } from "../src/net/transport";

function memoryStorage() {
  const m = new Map<string, string>();
  return {
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => void m.set(k, v),
    removeItem: (k: string) => void m.delete(k),
  };
}

function harness(token: string | null) {
  const sent: Array<{ id: string | null; type: string }> = [];
  let handlers: TransportHandlers | null = null;
  const storage = memoryStorage();
  if (token) storage.setItem("cwbhacker.token", token);
  const client = new Client({
    transport: (h) => {
      handlers = h;
      const t: Transport = {
        send: (text) => {
          const d = decode(text);
          if (d.kind === "ok") sent.push({ id: d.frame.id, type: d.frame.type });
        },
        close: () => h.onClose("test closed"),
      };
      queueMicrotask(() => h.onOpen());
      return t;
    },
    storage,
    keepalive: false,
  });
  return {
    client,
    sent,
    storage,
    reply: (id: string, type: string, payload: unknown) =>
      handlers!.onMessage(encode(id, type, payload)),
    event: (type: string, payload: unknown) => handlers!.onMessage(encode(null, type, payload)),
    drop: () => handlers!.onClose("the network went"),
  };
}

const flush = () => new Promise<void>((r) => queueMicrotask(() => r()));

describe("Client#onNeedLogin", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("fires `unauthorized`, with the flag set and the token gone, when a resume is refused", async () => {
    const h = harness("t0");
    const seen: string[] = [];
    const flagWhenSeen: boolean[] = [];
    const openSawFlag: boolean[] = [];
    h.client.onNeedLogin((why) => {
      seen.push(why);
      flagWhenSeen.push(h.client.needsLogin);
    });
    h.client.onState((s) => {
      if (s === "open") openSawFlag.push(h.client.needsLogin);
    });
    h.client.connect();
    await flush();
    expect(h.client.state).toBe("open");
    // The socket drops; the reconnect resumes with the stored token.
    h.drop();
    await vi.advanceTimersByTimeAsync(2000);
    await flush();
    const resume = h.sent.find((f) => f.type === "auth.resume");
    expect(resume?.id).toBeTruthy();
    // "open" has already fired, and the flag was not up yet: this is the
    // race the dedicated signal exists for.
    expect(openSawFlag).toEqual([false, false]);
    expect(seen).toEqual([]);
    h.reply(resume!.id!, "auth.resume.err", {
      code: "unauthorized",
      message: "that session is gone",
      detail: {},
    });
    await flush();
    expect(seen).toEqual(["unauthorized"]);
    expect(flagWhenSeen).toEqual([true]);
    expect(h.client.token).toBeNull();
    expect(h.client.state).toBe("open");
  });

  it("fires `revoked` on the server's bye, and drops the token", async () => {
    const h = harness("t0");
    const seen: string[] = [];
    h.client.onNeedLogin((why) => seen.push(why));
    h.client.connect();
    await flush();
    h.event("server.bye", { reason: "revoked" });
    expect(seen).toEqual(["revoked"]);
    expect(h.client.token).toBeNull();
    expect(h.client.needsLogin).toBe(true);
  });

  it("stays quiet for a bye that is a shutdown", async () => {
    const h = harness("t0");
    const seen: string[] = [];
    h.client.onNeedLogin((why) => seen.push(why));
    h.client.connect();
    await flush();
    h.event("server.bye", { reason: "shutdown" });
    expect(seen).toEqual([]);
    expect(h.client.token).toBe("t0");
  });
});
