/**
 * `Client#reconnect` when the store has no token any more.
 *
 * The token lives in `localStorage`, shared by every tab. Another tab's
 * logout removes it; this tab stays authenticated on its live socket until
 * that socket drops. The reconnect then found no token and returned without
 * a word: the header still showed the address, every request was refused
 * locally with "needs a session", and nothing ever put the login screen up.
 * Now a tab that *had* a session treats the missing token as the session
 * being gone (§6.4), so the kept key signs in again. A tab that never had
 * one — it is on the login screen already — is left alone.
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
    drop: () => handlers!.onClose("the network went"),
  };
}

const flush = () => new Promise<void>((r) => queueMicrotask(() => r()));

const USER = { address: "0xabc", name: "x", created_at: "2026-01-01T00:00:00Z" };

describe("Client#reconnect with no token in the store", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("fires `unauthorized` for a tab that had a session, and marks it `resume`d before", async () => {
    const h = harness("t0");
    const seen: string[] = [];
    h.client.onNeedLogin((why) => seen.push(why));
    h.client.connect();
    await flush();
    // First drop: the reconnect resumes with the stored token and is adopted.
    h.drop();
    await vi.advanceTimersByTimeAsync(2000);
    await flush();
    const resume = h.sent.find((f) => f.type === "auth.resume");
    expect(resume?.id).toBeTruthy();
    h.reply(resume!.id!, "auth.resume.ok", { token: "t1", user: USER, position: null });
    await flush();
    expect(h.client.state).toBe("authed");
    expect(h.client.lastAuth).toBe("resume");
    expect(seen).toEqual([]);

    // Another tab logs out: the shared token is gone. Then this socket drops.
    h.storage.removeItem("cwbhacker.token");
    h.drop();
    await vi.advanceTimersByTimeAsync(4000);
    await flush();
    expect(seen).toEqual(["unauthorized"]);
    // Once. The next drop, still with no token, is a tab on the login screen.
    h.drop();
    await vi.advanceTimersByTimeAsync(9000);
    await flush();
    expect(seen).toEqual(["unauthorized"]);
  });

  it("stays quiet for a tab that never had a session", async () => {
    const h = harness(null);
    const seen: string[] = [];
    h.client.onNeedLogin((why) => seen.push(why));
    h.client.connect();
    await flush();
    h.drop();
    await vi.advanceTimersByTimeAsync(4000);
    await flush();
    expect(h.client.state).toBe("open");
    expect(seen).toEqual([]);
  });

  it("marks a login `login`, so a scene's own sign-in is not mistaken for a background resume", async () => {
    const h = harness(null);
    h.client.connect();
    await flush();
    const p = h.client.login("0xabc", "0xsig");
    await flush();
    const login = h.sent.find((f) => f.type === "auth.login");
    h.reply(login!.id!, "auth.login.ok", { token: "t9", user: USER, position: null });
    await p;
    expect(h.client.lastAuth).toBe("login");
    expect(h.client.state).toBe("authed");
  });
});
