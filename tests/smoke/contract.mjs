#!/usr/bin/env node
/**
 * The contract checker.
 *
 * It speaks SPEC §6 to a running server on :5390 and nothing else — no
 * browser, no frontend, no build. When BE and FE disagree about a frame, this
 * is the thing that says which one is wrong, in about two seconds, without
 * anybody having to reproduce a click.
 *
 *     node tests/smoke/contract.mjs
 *     node tests/smoke/contract.mjs --url ws://127.0.0.1:5390/ws
 *     node tests/smoke/contract.mjs --only auth       # substring filter
 *     node tests/smoke/contract.mjs --json            # machine-readable
 *
 * Exit 0 if every check passed, 1 if any failed, 2 if it could not even
 * start (nothing listening, no signer).
 *
 * Zero npm dependencies. Node has had a global `WebSocket` since 22, and the
 * one thing it cannot do — produce a recoverable secp256k1 signature over a
 * nonce the server just invented — is shelled out to `CausewaybayWallet`'s
 * `utils sign`, the same binary that generated `tests/vectors/signatures.json`.
 * A fixture cannot cover that half: the nonce is fresh every time.
 */

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import process from "node:process";

// ------------------------------------------------------------------ config

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : fallback;
};
const has = (name) => args.includes(`--${name}`);

const URL_WS = flag("url", process.env.SMOKE_WS_URL ?? "ws://127.0.0.1:5390/ws");
const ONLY = flag("only", null);
const AS_JSON = has("json");
const TIMEOUT_MS = Number(flag("timeout", "10000"));

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const VECTORS = `${ROOT}/tests/vectors/addresses.json`;
const WALLET =
  process.env.CWBWALLET ??
  `${ROOT}/../CausewaybayWallet/rustcli/target/debug/cwbwallet`;

// SPEC §6.1. Closed. A code outside this set is a bug wherever it came from.
const ERROR_CODES = new Set([
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
]);

// SPEC §6.2, server → client, unsolicited.
const EVENT_TYPES = new Set([
  "run.log",
  "run.stage",
  "progress.update",
  "award",
  "server.bye",
]);

// ------------------------------------------------------------------ colours

const tty = process.stdout.isTTY && !AS_JSON;
const c = (code, s) => (tty ? `\x1b[${code}m${s}\x1b[0m` : s);
const green = (s) => c("32", s);
const red = (s) => c("31", s);
const dim = (s) => c("2", s);
const yellow = (s) => c("33", s);

// ------------------------------------------------------------- the wallet

function sign(privateKey, message) {
  if (!existsSync(WALLET)) {
    throw new SkipError(
      `no signer at ${WALLET}. Build CausewaybayWallet (\`make -C ` +
        `../CausewaybayWallet build\`) or set $CWBWALLET. Everything that needs ` +
        `a live signature is skipped without it; the anonymous half still runs.`,
    );
  }
  const out = spawnSync(
    WALLET,
    ["--json", "utils", "sign", "--private-key", privateKey, "--message", message],
    { encoding: "utf8" },
  );
  if (out.status !== 0) throw new Error(`signer failed: ${out.stderr || out.stdout}`);
  const env = JSON.parse(out.stdout);
  if (!env.ok) throw new Error(`signer said not-ok: ${out.stdout}`);
  return env.data.signature;
}

class SkipError extends Error {}

/**
 * Five well-known accounts from `tests/vectors/addresses.json`.
 *
 * Checks that change state take one each. Sharing an account between checks
 * makes the suite order-dependent, and an order-dependent contract checker is
 * the thing you stop trusting the first time it disagrees with itself.
 */
function accounts() {
  const doc = JSON.parse(readFileSync(VECTORS, "utf8"));
  const canonical = doc.mnemonics.find((m) => m.name === "bip39-canonical");
  return canonical.accounts;
}
const ACCOUNT = {
  reader: 0, // never submits: challenge, resume, map and quest shapes
  busy: 1,
  streamer: 2,
  alice: 3, // the isolation pair
  bob: 4,
};
const account = (role) => accounts()[ACCOUNT[role]];

/**
 * A Rust source that prints exactly what a visible test case expects.
 *
 * Milestone 1 is three print-one-line quests (PLAN.md), so this is enough to
 * make a submission the server will accept without QA needing to know the
 * content PM is still writing. Returns null for anything else, and the check
 * that uses it degrades to asserting only what it still can.
 */
function sourceThatPrints(expected) {
  if (typeof expected !== "string") return null;
  if (!expected.endsWith("\n") || expected.slice(0, -1).includes("\n")) return null;
  const line = expected.slice(0, -1);
  if (/["\\{}]/.test(line)) return null;
  return `fn main() {\n    println!("${line}");\n}\n`;
}

// --------------------------------------------------------------- the client

/**
 * One connection, with the envelope rules of SPEC §6.1 enforced on the way in.
 *
 * Every frame the server sends is checked before any test sees it: `v` is a
 * number, `payload` is an object and never absent, an error payload has the
 * three fields, an error code is in the closed set, and a frame with `id:
 * null` is one of the five event types. A malformed frame is recorded as a
 * protocol violation against whatever check was running.
 */
class Client {
  constructor(url, label = "c") {
    this.url = url;
    this.label = label;
    this.n = 0;
    this.pending = new Map();
    this.events = [];
    this.violations = [];
    this.frames = [];
    this.rawIds = new Set();
    this.closed = null;
  }

  connect() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url);
      this.ws = ws;
      const timer = setTimeout(
        () => reject(new Error(`no open within ${TIMEOUT_MS}ms`)),
        TIMEOUT_MS,
      );
      ws.addEventListener("open", () => {
        clearTimeout(timer);
        resolve(this);
      });
      ws.addEventListener("error", () => {
        clearTimeout(timer);
        reject(
          new SkipError(
            `nothing answered ${this.url}.\n` +
              `  Start the server:  make serve   (or: cd backend && cargo run -p cwbhacker -- serve)\n` +
              `  Point elsewhere:   node tests/smoke/contract.mjs --url ws://host:port/ws`,
          ),
        );
      });
      ws.addEventListener("close", (e) => {
        this.closed = { code: e.code, reason: e.reason };
        for (const [, p] of this.pending) p.reject(new Error("socket closed"));
        this.pending.clear();
      });
      ws.addEventListener("message", (e) => this.#onMessage(String(e.data)));
    });
  }

  #violate(why, frame) {
    this.violations.push({ why, frame });
  }

  #onMessage(text) {
    let f;
    try {
      f = JSON.parse(text);
    } catch {
      this.#violate("frame is not JSON", text.slice(0, 200));
      return;
    }
    this.frames.push(f);

    if (typeof f !== "object" || f === null || Array.isArray(f))
      return this.#violate("frame is not a JSON object", f);
    if (f.v !== 1) this.#violate(`v is ${JSON.stringify(f.v)}, expected 1`, f);
    if (typeof f.type !== "string") this.#violate("type is not a string", f);
    if (f.type !== f.type.toLowerCase()) this.#violate("type is not lowercase", f);
    if (typeof f.payload !== "object" || f.payload === null || Array.isArray(f.payload))
      this.#violate("payload must be an object, never absent and never bare", f);
    if (!("id" in f)) this.#violate("id is absent; an event must say id: null", f);

    if (f.type.endsWith(".err")) {
      const p = f.payload ?? {};
      if (typeof p.code !== "string") this.#violate("error payload has no code", f);
      else if (!ERROR_CODES.has(p.code))
        this.#violate(
          `error code ${JSON.stringify(p.code)} is outside SPEC §6.1's closed set`,
          f,
        );
      if (typeof p.message !== "string")
        this.#violate("error payload has no message string", f);
      if (!("detail" in p)) this.#violate("error payload has no detail", f);
    }

    if (f.id === null) {
      // An `.err` with a null id is allowed: a frame the server could not
      // parse has no id to echo, and SPEC §6.1 does not say what to do about
      // that. Flagged as an open question in docs/decisions.md, tolerated
      // here so it does not drown the real findings.
      if (!EVENT_TYPES.has(f.type) && !f.type.endsWith(".err"))
        this.#violate(`id:null but ${f.type} is not a SPEC §6.2 event`, f);
      this.events.push(f);
      return;
    }

    const p = this.pending.get(f.id);
    if (!p) {
      // `raw()` frames are sent without registering a waiter, on purpose —
      // they are the malformed ones. Their ids are known and not a violation.
      if (!this.rawIds.has(f.id))
        this.#violate(`reply correlated to ${f.id}, which was never sent`, f);
      return;
    }
    this.pending.delete(f.id);
    p.resolve(f);
  }

  /** Send a request and wait for the reply the server correlates to it. */
  send(type, payload = {}, { v = 1, id = null } = {}) {
    const frameId = id ?? `${this.label}-${++this.n}`;
    const frame = { v, id: frameId, type, payload };
    const p = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(frameId);
        reject(new Error(`no reply to ${type} (${frameId}) within ${TIMEOUT_MS}ms`));
      }, TIMEOUT_MS);
      this.pending.set(frameId, {
        resolve: (f) => {
          clearTimeout(timer);
          resolve(f);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
    });
    this.ws.send(JSON.stringify(frame));
    return p;
  }

  /** Send without waiting — for the frames whose reply order is the test. */
  fire(type, payload = {}, opts = {}) {
    return this.send(type, payload, opts).catch(() => null);
  }

  /** Send a frame verbatim, without waiting. `id` is remembered so a reply
   *  to it is not mistaken for a reply to nothing. */
  raw(text, id = null) {
    if (id !== null) this.rawIds.add(id);
    this.ws.send(text);
  }

  close() {
    try {
      this.ws?.close();
    } catch {
      /* already gone */
    }
  }

  get open() {
    return this.ws?.readyState === WebSocket.OPEN;
  }
}

// ----------------------------------------------------------------- harness

const checks = [];
const check = (name, fn) => checks.push({ name, fn });

function assert(cond, message) {
  if (!cond) throw new Error(message);
}
function assertEq(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected))
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function assertErr(frame, code, what) {
  assert(frame.type.endsWith(".err"), `${what}: expected an .err, got ${frame.type}`);
  assertEq(frame.payload.code, code, `${what} code`);
}

/** A logged-in connection, or a SkipError explaining why not. */
async function session(account, label) {
  const cl = new Client(URL_WS, label);
  await cl.connect();
  const ch = await cl.send("auth.challenge", { address: account.address });
  assert(ch.type === "auth.challenge.ok", `challenge refused: ${JSON.stringify(ch)}`);
  const sig = sign(account.private_key, ch.payload.message);
  const login = await cl.send("auth.login", {
    address: account.address,
    signature: sig,
  });
  assert(
    login.type === "auth.login.ok",
    `login refused: ${JSON.stringify(login.payload)}`,
  );
  cl.token = login.payload.token;
  cl.account = account;
  return cl;
}

// ------------------------------------------------------------- the checks
// SPEC §6.1 — the envelope

check("ping answers with a well-formed envelope", async () => {
  const cl = new Client(URL_WS, "env");
  await cl.connect();
  try {
    const r = await cl.send("ping", {});
    assertEq(r.type, "ping.ok", "reply type");
    assertEq(r.v, 1, "protocol version");
    assert(typeof r.payload.t !== "undefined", "ping.ok payload has no `t`");
  } finally {
    cl.close();
  }
});

check("replies are correlated by id, not by arrival order", async () => {
  // Three requests in flight at once, answered in whatever order the server
  // likes. A client that matched on order instead of `id` passes a serial
  // test and corrupts the moment anything is concurrent.
  const cl = new Client(URL_WS, "corr");
  await cl.connect();
  try {
    const ids = ["corr-a", "corr-b", "corr-c"];
    const replies = await Promise.all(
      ids.map((id) => cl.send("ping", {}, { id })),
    );
    assertEq(
      replies.map((r) => r.id),
      ids,
      "each reply must carry the id of its own request",
    );
  } finally {
    cl.close();
  }
});

check("an unknown protocol version is refused and the socket stays open", async () => {
  // SPEC §6.1: "A frame with an unknown `v` is answered with `proto_version`
  // and the connection stays open." Dropping the connection here is the
  // failure mode that makes a version bump unshippable.
  const cl = new Client(URL_WS, "ver");
  await cl.connect();
  try {
    const r = await cl.send("ping", {}, { v: 99 });
    assertErr(r, "proto_version", "unknown v");
    assert(cl.open, "the connection was closed; §6.1 says it stays open");
    const after = await cl.send("ping", {});
    assertEq(after.type, "ping.ok", "the connection must still work afterwards");
  } finally {
    cl.close();
  }
});

check("a malformed frame is a bad_request, not a disconnect", async () => {
  const cl = new Client(URL_WS, "junk");
  await cl.connect();
  try {
    cl.raw("this is not json");
    cl.raw(JSON.stringify({ v: 1, id: "junk-1", type: "ping" }), "junk-1"); // no payload
    cl.raw(JSON.stringify({ v: 1, id: "junk-2", type: "ping", payload: 7 }), "junk-2"); // bare
    await new Promise((r) => setTimeout(r, 500));
    assert(cl.open, "the connection was dropped on malformed input");
    const after = await cl.send("ping", {});
    assertEq(after.type, "ping.ok", "still usable after junk");
    const codes = cl.frames
      .filter((f) => f.type?.endsWith(".err"))
      .map((f) => f.payload.code);
    assert(
      codes.every((c) => ERROR_CODES.has(c)),
      `error codes outside the closed set: ${codes}`,
    );
  } finally {
    cl.close();
  }
});

// SPEC §6.4 — anonymous connections

check("everything but ping and auth.challenge is unauthorized before login", async () => {
  const cl = new Client(URL_WS, "anon");
  await cl.connect();
  try {
    // The allowed two.
    assertEq((await cl.send("ping", {})).type, "ping.ok", "ping before login");
    const ch = await cl.send("auth.challenge", {
      address: account("reader").address,
    });
    assertEq(ch.type, "auth.challenge.ok", "auth.challenge before login");

    // Everything else in the §6.2 catalogue.
    const forbidden = [
      ["profile.update", { name: "nope" }],
      ["world.lands", {}],
      ["world.map", { land: "rust", category: "basic" }],
      ["quest.get", { quest_id: "rust.basic.01.hello" }],
      ["quest.submit", { quest_id: "rust.basic.01.hello", source: "fn main(){}", lang: "rust" }],
      ["quest.hint", { quest_id: "rust.basic.01.hello", index: 0 }],
      ["quest.reset", { quest_id: "rust.basic.01.hello" }],
      ["search.query", { q: "hello", mode: "unified" }],
      ["stats.summary", {}],
      ["stats.mistakes", {}],
      ["stats.history", {}],
      ["ai.plan", { mode: "repeat" }],
      ["ai.next", { drill_id: "drl_0000000000000000" }],
      ["ai.finish", { drill_id: "drl_0000000000000000" }],
    ];
    const bad = [];
    for (const [type, payload] of forbidden) {
      const r = await cl.send(type, payload);
      if (!r.type.endsWith(".err") || r.payload.code !== "unauthorized")
        bad.push(`${type} → ${r.type} ${r.payload.code ?? ""}`);
    }
    assert(bad.length === 0, `not unauthorized before login:\n    ${bad.join("\n    ")}`);
  } finally {
    cl.close();
  }
});

// SPEC §3.2 — the challenge

check("the challenge message is exactly the four lines of §3.2", async () => {
  const alice = account("reader");
  const cl = new Client(URL_WS, "chal");
  await cl.connect();
  try {
    const r = await cl.send("auth.challenge", { address: alice.address });
    const { nonce, message, expires_at } = r.payload;
    assert(/^[0-9a-f]{64}$/.test(nonce), `nonce is not 32 hex bytes: ${nonce}`);
    assert(
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(expires_at),
      `expires_at is not RFC3339 UTC with seconds: ${expires_at}`,
    );
    const lines = message.split("\n");
    assertEq(lines[0], "Causewaybay Hacker login", "line 1");
    assertEq(lines[1], `address: ${alice.address}`, "line 2 (EIP-55, no annotation)");
    assertEq(lines[2], `nonce: ${nonce}`, "line 3");
    assertEq(lines[3], `expires: ${expires_at}`, "line 4");
    assertEq(lines.length, 4, "line count — a trailing newline changes the digest");

    // §3.2 says 120 seconds out. Allow a little clock slack, not a minute.
    const secs = (Date.parse(expires_at) - Date.now()) / 1000;
    assert(secs > 100 && secs < 140, `expiry is ${secs.toFixed(0)}s out, §3.2 says 120`);

    // §3.4: the claim is case-insensitive, so the lowercase spelling of the
    // same wallet must get a challenge too — and the message still shows the
    // checksummed form, because that is what gets signed.
    const lower = await cl.send("auth.challenge", { address: alice.address_lower });
    assertEq(lower.type, "auth.challenge.ok", "lowercase address refused");
    assert(
      lower.payload.message.includes(alice.address),
      "the message must carry the EIP-55 spelling whichever case was claimed",
    );
  } finally {
    cl.close();
  }
});

check("a bad signature is auth_bad_signature, and the nonce is not burned", async () => {
  const alice = account("reader");
  const cl = new Client(URL_WS, "badsig");
  await cl.connect();
  try {
    const ch = await cl.send("auth.challenge", { address: alice.address });
    const r = await cl.send("auth.login", {
      address: alice.address,
      signature: `0x${"00".repeat(65)}`,
    });
    assertErr(r, "auth_bad_signature", "all-zero signature");
    // A rejected signature must not consume the nonce: otherwise one bad
    // frame from anywhere locks the real client out of its own challenge.
    const sig = sign(alice.private_key, ch.payload.message);
    const ok = await cl.send("auth.login", { address: alice.address, signature: sig });
    assertEq(ok.type, "auth.login.ok", "the good signature after a bad one");
  } finally {
    cl.close();
  }
});

check("a signature by the wrong key does not log in as the claimed address", async () => {
  const alice = account("reader");
  const bob = account("bob");
  const cl = new Client(URL_WS, "wrongkey");
  await cl.connect();
  try {
    const ch = await cl.send("auth.challenge", { address: alice.address });
    const r = await cl.send("auth.login", {
      address: alice.address,
      signature: sign(bob.private_key, ch.payload.message),
    });
    assertErr(r, "auth_bad_signature", "bob signing alice's challenge");
  } finally {
    cl.close();
  }
});

check("a nonce is single-use", async () => {
  const alice = account("reader");
  const cl = new Client(URL_WS, "replay");
  await cl.connect();
  try {
    const ch = await cl.send("auth.challenge", { address: alice.address });
    const sig = sign(alice.private_key, ch.payload.message);
    const first = await cl.send("auth.login", { address: alice.address, signature: sig });
    assertEq(first.type, "auth.login.ok", "first login");
    const second = await cl.send("auth.login", {
      address: alice.address,
      signature: sig,
    });
    assertErr(second, "auth_nonce_used", "replay inside the expiry window");
  } finally {
    cl.close();
  }
});

check("login stores the address lowercased and echoes the EIP-55 form", async () => {
  // SPEC §3.4: two spellings of one wallet must never become two players.
  const alice = account("reader");
  const cl = await session({ ...alice, address: alice.address_lower }, "case");
  try {
    const user = cl.token && (await cl.send("auth.resume", { token: cl.token })).payload.user;
    assertEq(user.address, alice.address_lower, "users.address");
    assertEq(user.address_eip55, alice.address, "users.address_eip55");
  } finally {
    cl.close();
  }
});

check("auth.resume trades a token for a session without the key", async () => {
  // SPEC §3.3. This is what lets the client keep key material in memory only
  // and forget it on reload — the whole reason §3.1 is affordable.
  const alice = account("reader");
  const first = await session(alice, "res1");
  const token = first.token;
  first.close();

  const second = new Client(URL_WS, "res2");
  await second.connect();
  try {
    const r = await second.send("auth.resume", { token });
    assertEq(r.type, "auth.resume.ok", "resume with a live token");
    assertEq(r.payload.user.address, alice.address_lower, "the resumed identity");
    const lands = await second.send("world.lands", {});
    assertEq(lands.type, "world.lands.ok", "a resumed session is a real session");
  } finally {
    second.close();
  }

  const third = new Client(URL_WS, "res3");
  await third.connect();
  try {
    const r = await third.send("auth.resume", { token: "not-a-token" });
    assert(r.type.endsWith(".err"), "a junk token must not resume");
    assert(
      ["unauthorized", "bad_request", "not_found"].includes(r.payload.code),
      `junk token gave ${r.payload.code}`,
    );
  } finally {
    third.close();
  }
});

// SPEC §6.2 — the catalogue, authenticated

check("world.lands and world.map answer with the §6.3 shapes", async () => {
  const alice = account("reader");
  const cl = await session(alice, "world");
  try {
    const lands = await cl.send("world.lands", {});
    assertEq(lands.type, "world.lands.ok", "world.lands");
    assert(Array.isArray(lands.payload.lands), "lands is not an array");
    for (const l of lands.payload.lands) {
      assert(["rust", "go"].includes(l.land), `unknown land ${l.land}`);
      for (const cat of l.categories) {
        assert(
          ["basic", "advanced", "hacker"].includes(cat.category),
          `unknown category ${cat.category}`,
        );
        assert(typeof cat.total === "number", "category.total");
        assert(typeof cat.cleared === "number", "category.cleared");
        assert(cat.cleared <= cat.total, "cleared exceeds total");
      }
    }

    const map = await cl.send("world.map", { land: "rust", category: "basic" });
    assertEq(map.type, "world.map.ok", "world.map");
    assert(Array.isArray(map.payload.nodes), "nodes is not an array");
    assert(Array.isArray(map.payload.edges), "edges is not an array");
    const seen = new Set();
    for (const n of map.payload.nodes) {
      assert(
        /^(rust|go)\.(basic|advanced|hacker)\.\d{2}\..+$/.test(n.quest_id),
        `quest_id does not match SPEC §4.1: ${n.quest_id}`,
      );
      assert(["locked", "open", "cleared"].includes(n.state), `state ${n.state}`);
      assert(n.stars >= 0 && n.stars <= 3, `stars ${n.stars}`);
      assert(n.difficulty >= 1 && n.difficulty <= 5, `difficulty ${n.difficulty}`);
      assert(["quest", "boss", "gate"].includes(n.kind), `kind ${n.kind}`);
      assert(n.x >= 0 && n.x <= 1 && n.y >= 0 && n.y <= 1, `map position ${n.x},${n.y}`);
      assert(!seen.has(n.node), `node ${n.node} appears twice`);
      seen.add(n.node);
    }
    // SPEC §12: 1-based and contiguous — a gap is an error, the map draws a
    // path through them.
    const nodes = [...seen].sort((a, b) => a - b);
    assertEq(nodes, nodes.map((_, i) => i + 1), "node numbering is not contiguous from 1");
    // At least one node must be reachable or the game cannot be started.
    assert(
      map.payload.nodes.some((n) => n.state !== "locked"),
      "every node is locked; §12 says an empty `requires` is open from the start",
    );
  } finally {
    cl.close();
  }
});

check("quest.get withholds the solution until it is cleared", async () => {
  // SPEC §6.2: "no `solution` unless cleared". A reference answer handed to a
  // client that has not earned it is the map clearing itself.
  const alice = account("reader");
  const cl = await session(alice, "quest");
  try {
    const map = await cl.send("world.map", { land: "rust", category: "basic" });
    const open = map.payload.nodes.find((n) => n.state === "open");
    assert(open, "no open node to ask about");
    const r = await cl.send("quest.get", { quest_id: open.quest_id });
    assertEq(r.type, "quest.get.ok", "quest.get");
    const q = r.payload.quest;
    assert(typeof q.starter === "string" && q.starter.length > 0, "no starter code");
    assert(
      q.solution === undefined || q.solution === null,
      "the solution was sent for a quest this user has not cleared",
    );
    // And the hidden test data is not in the brief either.
    const blob = JSON.stringify(q);
    assert(!blob.includes('"visible":false'), "hidden cases leaked in quest.get");

    const missing = await cl.send("quest.get", { quest_id: "rust.basic.99.nope" });
    assertErr(missing, "not_found", "a quest id that does not exist");
  } finally {
    cl.close();
  }
});

check("a second quest.submit while one is in flight is busy", async () => {
  // SPEC §6.4: one in-flight submit per connection.
  const alice = account("busy");
  const cl = await session(alice, "busy");
  try {
    const map = await cl.send("world.map", { land: "rust", category: "basic" });
    const open = map.payload.nodes.find((n) => n.state === "open");
    assert(open, "no open node to submit to");
    const body = {
      quest_id: open.quest_id,
      // Deliberately slow to compile, so the second frame is genuinely
      // concurrent rather than racing a finished job.
      source: "fn main() { println!(\"hello, causewaybay\"); }",
      lang: "rust",
    };
    const first = cl.send("quest.submit", body);
    const second = await cl.send("quest.submit", body);
    assertErr(second, "busy", "the second concurrent submit");
    const done = await first;
    assertEq(done.type, "quest.submit.ok", "the first submit still finished");
  } finally {
    cl.close();
  }
});

check("run.stage and run.log arrive as events with id: null", async () => {
  // SPEC §5.4 / §6.2: the player watches rustc think. An event with a
  // non-null id would be correlated to a request nobody made.
  const alice = account("streamer");
  const cl = await session(alice, "stream");
  try {
    const map = await cl.send("world.map", { land: "rust", category: "basic" });
    const open = map.payload.nodes.find((n) => n.state === "open");
    assert(open, "no open node to submit to");
    await cl.send("quest.submit", {
      quest_id: open.quest_id,
      source: "fn main() { println!(\"hello, causewaybay\"); }",
      lang: "rust",
    });
    const stages = cl.events.filter((e) => e.type === "run.stage");
    assert(stages.length > 0, "no run.stage events during a submit");
    assert(
      stages.every((e) => e.id === null),
      "a run.stage arrived with a non-null id",
    );
    const names = stages.map((e) => e.payload.stage);
    assert(
      names.every((s) => ["queued", "compiling", "running", "judging"].includes(s)),
      `stage outside the §6.2 set: ${names}`,
    );
    // Only the two run events carry one; `progress.update` and `award` do not.
    assert(
      cl.events
        .filter((e) => e.type === "run.log" || e.type === "run.stage")
        .every((e) => typeof e.payload.attempt_id === "string"),
      "a run.log/run.stage event without an attempt_id",
    );
    // Clearing a quest must announce itself, or the map only updates on a
    // screen the player might not go back to (SPEC §6.2).
    const updates = cl.events.filter((e) => e.type === "progress.update");
    assert(
      updates.every((e) => ["locked", "open", "cleared"].includes(e.payload.state)),
      "a progress.update with a state outside the §2.1 CHECK constraint",
    );
  } finally {
    cl.close();
  }
});

// SPEC §3.5 / §9.8 — multi-user isolation

check("two sessions never see each other's progress, attempts or mistakes", async () => {
  // SPEC §9.8, and §3.5's rule underneath it. Two addresses, two sessions,
  // submissions that overlap in time.
  const alice = account("alice");
  const bob = account("bob");
  const a = await session(alice, "iso-a");
  const b = await session(bob, "iso-b");
  try {
    const map = await a.send("world.map", { land: "rust", category: "basic" });
    const open = map.payload.nodes.find((n) => n.state === "open");
    assert(open, "no open node for alice — the map starts fully locked");

    // What would clear it, read off the quest's own visible case rather than
    // hard-coded here: QA does not own the content.
    const got = await a.send("quest.get", { quest_id: open.quest_id });
    const visible = (got.payload.quest.cases ?? []).find((c) => c.visible);
    const right = sourceThatPrints(visible?.expect);
    const wrong = 'fn main() { println!("deliberately not the answer"); }';

    const [aDone, bDone] = await Promise.all([
      a.send("quest.submit", {
        quest_id: open.quest_id,
        source: right ?? wrong,
        lang: "rust",
      }),
      b.send("quest.submit", { quest_id: open.quest_id, source: wrong, lang: "rust" }),
    ]);
    assertEq(aDone.type, "quest.submit.ok", "alice's submit");
    assertEq(bDone.type, "quest.submit.ok", "bob's submit");
    assert(
      bDone.payload.attempt.verdict !== "accepted",
      "a source that prints the wrong thing was accepted",
    );
    assert(
      aDone.payload.attempt.id !== bDone.payload.attempt.id,
      "the two attempts share an id",
    );

    // History does not cross. This is the assertion §9.8 is really about,
    // and it holds whatever the verdicts were.
    const aHist = await a.send("stats.history", { limit: 50 });
    const bHist = await b.send("stats.history", { limit: 50 });
    const aIds = new Set(aHist.payload.attempts.map((x) => x.id));
    const bIds = new Set(bHist.payload.attempts.map((x) => x.id));
    assert(aIds.has(aDone.payload.attempt.id), "alice cannot see her own attempt");
    assert(bIds.has(bDone.payload.attempt.id), "bob cannot see his own attempt");
    assert(!aIds.has(bDone.payload.attempt.id), "alice can see bob's attempt");
    assert(!bIds.has(aDone.payload.attempt.id), "bob can see alice's attempt");

    // Mistakes do not cross: bob earned one, and it is his.
    const aMistakes = await a.send("stats.mistakes", { limit: 50 });
    const bMistakes = await b.send("stats.mistakes", { limit: 50 });
    assert(Array.isArray(aMistakes.payload.mistakes), "stats.mistakes shape");
    assert(Array.isArray(bMistakes.payload.mistakes), "stats.mistakes shape");
    const total = (r) => r.payload.mistakes.reduce((s, m) => s + m.count, 0);
    assert(total(bMistakes) > 0, "bob's wrong answer produced no mistake row");

    // Progress does not cross — only assertable if alice actually cleared it,
    // which needs a quest this checker could compose an answer for.
    if (aDone.payload.attempt.verdict === "accepted") {
      const aMap = await a.send("world.map", { land: "rust", category: "basic" });
      const bMap = await b.send("world.map", { land: "rust", category: "basic" });
      const aNode = aMap.payload.nodes.find((n) => n.quest_id === open.quest_id);
      const bNode = bMap.payload.nodes.find((n) => n.quest_id === open.quest_id);
      assertEq(aNode.state, "cleared", "alice's node after clearing it");
      assert(bNode.state !== "cleared", "bob's node went cleared on alice's work");
      const aSum = await a.send("stats.summary", {});
      const bSum = await b.send("stats.summary", {});
      assert(aSum.payload.cleared >= 1, "alice's cleared count");
      assert(
        bSum.payload.cleared < aSum.payload.cleared,
        "bob's cleared count includes alice's work",
      );
    } else {
      assert(
        total(aMistakes) > 0,
        "neither side cleared anything and alice has no mistake either — " +
          "this check asserted almost nothing; see tests/PLAN.md §9.8",
      );
    }
  } finally {
    a.close();
    b.close();
  }
});

check("an address in a payload is ignored, never trusted", async () => {
  // SPEC §3.5: "every query ... is filtered by the address on the
  // connection's session, never by an address in the payload. A payload that
  // carries an address is ignored, not trusted." This is the check that
  // catches a server that helpfully honours it.
  const alice = account("alice");
  const bob = account("bob");
  const b = await session(bob, "spoof");
  try {
    const hist = await b.send("stats.history", {
      limit: 50,
      address: alice.address_lower,
    });
    assertEq(hist.type, "stats.history.ok", "stats.history with a spoofed address");
    const sum = await b.send("stats.summary", { address: alice.address_lower });
    const own = await b.send("stats.summary", {});
    assertEq(
      sum.payload,
      own.payload,
      "a payload address changed the answer — §3.5 says it is ignored",
    );
  } finally {
    b.close();
  }
});

check("the frames the server sent never broke the envelope rules", async () => {
  // Every Client validates as it goes; this rolls the whole run up so a
  // violation in the middle of an otherwise-passing check is still reported.
  const total = allViolations.length;
  assert(
    total === 0,
    `${total} envelope violation(s):\n    ` +
      allViolations
        .slice(0, 10)
        .map((v) => `${v.why}  ${JSON.stringify(v.frame).slice(0, 160)}`)
        .join("\n    "),
  );
});

// --------------------------------------------------------------------- run

const allViolations = [];
const origClose = Client.prototype.close;
Client.prototype.close = function close() {
  allViolations.push(...this.violations);
  this.violations = [];
  return origClose.call(this);
};

async function main() {
  const selected = ONLY ? checks.filter((c) => c.name.includes(ONLY)) : checks;
  const results = [];
  let hardStop = null;

  for (const { name, fn } of selected) {
    if (hardStop) {
      results.push({ name, status: "skipped", detail: hardStop });
      continue;
    }
    const t0 = Date.now();
    try {
      await fn();
      results.push({ name, status: "pass", ms: Date.now() - t0 });
      if (!AS_JSON) console.log(`${green("pass")}  ${name} ${dim(`${Date.now() - t0}ms`)}`);
    } catch (err) {
      const detail = err instanceof Error ? err.message : String(err);
      if (err instanceof SkipError) {
        // Nothing listening, or no signer: every later check would report the
        // same thing. Say it once.
        hardStop = detail;
        results.push({ name, status: "skipped", detail });
        if (!AS_JSON) console.log(`${yellow("skip")}  ${name}\n      ${detail}`);
        continue;
      }
      results.push({ name, status: "fail", detail, ms: Date.now() - t0 });
      if (!AS_JSON) console.log(`${red("FAIL")}  ${name}\n      ${detail}`);
    }
  }

  const pass = results.filter((r) => r.status === "pass").length;
  const fail = results.filter((r) => r.status === "fail").length;
  const skip = results.filter((r) => r.status === "skipped").length;

  if (AS_JSON) {
    console.log(JSON.stringify({ url: URL_WS, pass, fail, skip, results }, null, 2));
  } else {
    console.log(
      `\n${pass} passed, ${fail > 0 ? red(`${fail} failed`) : "0 failed"}, ${skip} skipped` +
        `  ${dim(URL_WS)}`,
    );
  }
  if (fail > 0) return 1;
  if (pass === 0) return 2; // nothing ran: a green with no checks is a lie
  return 0;
}

main().then(
  (code) => process.exit(code),
  (err) => {
    console.error(red("the checker itself fell over:"), err);
    process.exit(2);
  },
);
