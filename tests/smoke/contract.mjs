#!/usr/bin/env node
/**
 * The contract checker — PROTOCOL.md §8, point by point.
 *
 * It speaks the wire protocol to a running server on :5390 and nothing else:
 * no browser, no frontend, no build. When two clients disagree about a frame
 * this is the thing that says which one is wrong, in about two seconds,
 * without anybody having to reproduce a click.
 *
 * PROTOCOL.md §8 is a twelve-point conformance checklist and it is the shared
 * definition of "the client works" for three clients now — the browser, the
 * LÖVE desktop client, and this. So the twelve are the spine of this file:
 * one named case each, reported by number. Everything else runs after them,
 * under "beyond the checklist", and never obscures the score.
 *
 *     node tests/smoke/contract.mjs
 *     node tests/smoke/contract.mjs --url ws://127.0.0.1:5390/ws
 *     node tests/smoke/contract.mjs --only 8.6        # one point
 *     node tests/smoke/contract.mjs --only beyond     # substring match
 *     node tests/smoke/contract.mjs --json            # machine-readable
 *     node tests/smoke/contract.mjs --slow            # the real 70s keepalive
 *
 * Exit 0 if every check passed, 1 if any failed, 2 if it could not start
 * (nothing listening, no signer).
 *
 * Several of the twelve are rules about *the client*. This checker is a
 * client, so it asserts them against itself — every frame it sends is kept
 * and inspected. A conformance suite that only ever audits the other side is
 * half a suite.
 *
 * Zero npm dependencies. Node has had a global `WebSocket` since 22; the one
 * thing it cannot do — a recoverable secp256k1 signature over a nonce the
 * server invented a moment ago — is shelled out to `CausewaybayWallet`'s
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
const SLOW = has("slow");
const TIMEOUT_MS = Number(flag("timeout", "20000"));

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const VECTORS = `${ROOT}/tests/vectors/addresses.json`;
const WALLET =
  process.env.CWBWALLET ??
  `${ROOT}/../CausewaybayWallet/rustcli/target/debug/cwbwallet`;

/** PROTOCOL.md §2: exactly these four top-level keys, no others. */
const ENVELOPE_KEYS = ["id", "payload", "type", "v"]; // sorted

/**
 * PROTOCOL.md §3.3. Closed. A code outside it is a server bug.
 *
 * "Closed" and "reachable" are two different claims and this suite keeps them
 * apart. `locked` is still *in* the set and is no longer *emitted* (§4.7:
 * every node is playable). It stays in the set because removing a code from a
 * closed set is the one change that breaks a client switching exhaustively —
 * so a client must still handle it, and a test that deleted it from here
 * would stop noticing if a server started emitting it again.
 */
const ERROR_CODES = new Set([
  "proto_version",
  "bad_request",
  "unauthorized",
  "auth_expired",
  "auth_nonce_used",
  "auth_bad_signature",
  "not_found",
  // In the set, never emitted — see NOT_EMITTED below.
  "locked",
  "rate_limited",
  "busy",
  // Real and specified, but not built yet — carries detail.milestone. Never
  // `internal`, which tells the player their machine is broken and invites a
  // retry that cannot work.
  "unavailable",
  "internal",
]);

/**
 * Codes that are in the closed set and that this build must never send.
 *
 * `locked` went this way when §4.7 made every node playable. A server that
 * starts emitting one again has quietly reintroduced a rule the spec
 * removed, and the player finds out by being refused a quest they can see.
 */
const NOT_EMITTED = new Set(["locked"]);

/** PROTOCOL.md §4.17–§4.21, the server-initiated events. */
const EVENT_TYPES = new Set([
  "run.stage",
  "run.log",
  "progress.update",
  "award",
  "server.bye",
]);

/** PROTOCOL.md §3.1: the four messages an ANONYMOUS connection accepts. */
const ANONYMOUS_OK = new Set(["ping", "auth.challenge", "auth.login", "auth.resume"]);

// ----------------------------------------------------------------- colours

const tty = process.stdout.isTTY && !AS_JSON;
const c = (code, s) => (tty ? `\x1b[${code}m${s}\x1b[0m` : s);
const green = (s) => c("32", s);
const red = (s) => c("31", s);
const dim = (s) => c("2", s);
const yellow = (s) => c("33", s);

// ------------------------------------------------------------- the signer

class SkipError extends Error {}

function sign(privateKey, message) {
  if (!existsSync(WALLET)) {
    throw new SkipError(
      `no signer at ${WALLET}. Build CausewaybayWallet ` +
        `(\`make -C ../CausewaybayWallet build\`) or set $CWBWALLET.`,
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

/**
 * Five well-known accounts from `tests/vectors/addresses.json`.
 *
 * Checks that change state take one each. Sharing an account across checks
 * makes the suite order-dependent, and an order-dependent contract checker is
 * the thing you stop trusting the first time it disagrees with itself.
 */
function allAccounts() {
  const doc = JSON.parse(readFileSync(VECTORS, "utf8"));
  return doc.mnemonics.find((m) => m.name === "bip39-canonical").accounts;
}
const ROLE = { reader: 0, busy: 1, streamer: 2, alice: 3, bob: 4 };
const account = (role) => allAccounts()[ROLE[role]];

/**
 * A throwaway account nobody has played before.
 *
 * The real server persists: `~/.causewaybayhacker/hacker.db` remembers that
 * the fixture accounts cleared node 1 on the last run, so a checker pinned to
 * five fixed addresses gets a different map every time and is only honest on
 * a fresh home. Deriving a high index off the same published mnemonic gives a
 * new user per run — the phrase is still the BIP-39 all-zero vector, still
 * holds nothing, and index 1000+ is somewhere no human ever browses.
 *
 * This is the difference between a checker that can be run twice and one that
 * has to be run against a wiped database.
 */
const FRESH_BASE = 1_000 + Math.floor(Math.random() * 1_000_000);
let freshN = 0;
const freshCache = new Map();
function freshAccount(role) {
  if (freshCache.has(role)) return freshCache.get(role);
  if (!existsSync(WALLET))
    throw new SkipError(
      `no wallet at ${WALLET}; fresh accounts cannot be derived. Set $CWBWALLET.`,
    );
  const index = FRESH_BASE + freshN++;
  const phrase = JSON.parse(readFileSync(VECTORS, "utf8")).mnemonics.find(
    (m) => m.name === "bip39-canonical",
  ).phrase;
  const out = spawnSync(
    WALLET,
    ["--json", "utils", "derive", "--mnemonic", phrase, "--index", String(index)],
    { encoding: "utf8" },
  );
  if (out.status !== 0) throw new Error(`derive failed: ${out.stderr || out.stdout}`);
  const d = JSON.parse(out.stdout).data;
  const acct = {
    index,
    role,
    address: d.address,
    address_lower: d.address.toLowerCase(),
    private_key: d.private_key,
  };
  freshCache.set(role, acct);
  return acct;
}

/** Every private key this process knows, for the §8.5 audit. */
const SECRETS = () => allAccounts().map((a) => a.private_key.replace(/^0x/, ""));

/**
 * A Rust source that prints exactly what a visible case expects.
 *
 * Milestone 1 is print-one-line quests, so this is enough to make a
 * submission the server will accept without QA having to know content PM
 * owns. Returns null for anything else, and the caller degrades to asserting
 * only what it still can — loudly, never silently.
 */
function sourceThatPrints(visible) {
  // Only a case that reads no stdin can be answered by printing a constant;
  // one that transforms its input needs the lesson, which is the point of the
  // quest and not something a contract checker should be able to shortcut.
  if (!visible || typeof visible.expect !== "string") return null;
  if (visible.stdin) return null;
  const expected = visible.expect;
  if (!expected.endsWith("\n")) return null;
  const lines = expected.slice(0, -1).split("\n");
  if (lines.some((l) => /["\\{}]/.test(l))) return null;
  const body = lines.map((l) => `    println!("${l}");`).join("\n");
  return `fn main() {\n${body}\n}\n`;
}

// --------------------------------------------------------------- the client

/**
 * One connection, with PROTOCOL.md §2's envelope rules enforced on the way in
 * and §8's client rules enforced on the way out.
 *
 * Nothing a check sees has skipped validation: every inbound frame is
 * structurally checked before it is handed over, and every outbound frame is
 * kept so §8.1 and §8.5 can audit this client's own behaviour rather than
 * taking its word for it.
 */
class Client {
  constructor(url, label = "c") {
    this.url = url;
    this.label = label;
    this.n = 0;
    this.pending = new Map();
    this.events = [];
    this.violations = [];
    this.inbound = [];
    this.outbound = [];
    this.unknownTypes = [];
    this.rawIds = new Set();
    this.closed = null;
    /** run.log reassembly, per attempt per stream — PROTOCOL.md §8.8. */
    this.logs = new Map();
  }

  connect() {
    return new Promise((resolve, reject) => {
      let ws;
      try {
        ws = new WebSocket(this.url);
      } catch (err) {
        return reject(new SkipError(`bad url ${this.url}: ${err.message}`));
      }
      this.ws = ws;
      const timer = setTimeout(
        () => reject(new Error(`no open within ${TIMEOUT_MS}ms`)),
        TIMEOUT_MS,
      );
      ws.addEventListener("open", () => {
        clearTimeout(timer);
        this.openedAt = Date.now();
        resolve(this);
      });
      ws.addEventListener("error", () => {
        clearTimeout(timer);
        reject(
          new SkipError(
            `nothing answered ${this.url}.\n` +
              `  Start the server:  make serve` +
              `   (or: cd backend && cargo run -p cwbhacker -- serve)\n` +
              `  Point elsewhere:   node tests/smoke/contract.mjs --url ws://host:port/ws`,
          ),
        );
      });
      ws.addEventListener("close", (e) => {
        this.closed = { code: e.code, reason: e.reason, at: Date.now() };
        for (const [, p] of this.pending) p.reject(new Error("socket closed"));
        this.pending.clear();
      });
      ws.addEventListener("message", (e) => this.receive(String(e.data)));
    });
  }

  violate(why, frame) {
    this.violations.push({ why, frame });
  }

  /**
   * The receive path. Public on purpose: two of §8's points are about how a
   * client reacts to a frame, and feeding one in through the same path a real
   * frame takes is the only honest way to test that.
   */
  receive(text) {
    let f;
    try {
      f = JSON.parse(text);
    } catch {
      this.violate("frame is not JSON", text.slice(0, 200));
      return;
    }
    this.inbound.push(f);

    // ---- PROTOCOL.md §2, the envelope ---------------------------------
    if (typeof f !== "object" || f === null || Array.isArray(f))
      return this.violate("frame is not a JSON object", f);
    const keys = Object.keys(f).sort();
    if (JSON.stringify(keys) !== JSON.stringify(ENVELOPE_KEYS))
      this.violate(
        `top-level keys are ${JSON.stringify(keys)}; §2 says exactly ` +
          `${JSON.stringify(ENVELOPE_KEYS)}`,
        f,
      );
    if (f.v !== 1) this.violate(`v is ${JSON.stringify(f.v)}, expected 1`, f);
    if (typeof f.type !== "string") this.violate("type is not a string", f);
    else if (f.type !== f.type.toLowerCase())
      this.violate("type is not lowercase (§2.3)", f);
    if (typeof f.payload !== "object" || f.payload === null || Array.isArray(f.payload))
      this.violate("payload must be an object, never bare, never absent (§2)", f);

    // ---- PROTOCOL.md §3.3, the error shape ----------------------------
    if (typeof f.type === "string" && f.type.endsWith(".err")) {
      const p = f.payload ?? {};
      const pk = Object.keys(p).sort();
      if (JSON.stringify(pk) !== JSON.stringify(["code", "detail", "message"]))
        this.violate(
          `error payload keys are ${JSON.stringify(pk)}; §3.3 says exactly ` +
            `["code","detail","message"] and no extra keys`,
          f,
        );
      if (typeof p.code !== "string") this.violate("error payload has no code", f);
      else if (!ERROR_CODES.has(p.code))
        this.violate(
          `error code ${JSON.stringify(p.code)} is outside §3.3's closed set`,
          f,
        );
      else if (NOT_EMITTED.has(p.code))
        this.violate(
          `error code ${JSON.stringify(p.code)} is in §3.3's set but §4.7 says ` +
            `it is never emitted — every node is playable`,
          f,
        );
      if (typeof p.message === "string" && p.message.includes("\n"))
        this.violate("§3.3: `message` is one line", f);
    }

    // ---- PROTOCOL.md §2.2, correlation --------------------------------
    if (f.id === null) {
      if (EVENT_TYPES.has(f.type)) {
        this.track(f);
      } else {
        // §2.3 tells a client to *ignore* an unknown type, not to error on
        // it. Recorded so §8.3 can prove the ignoring actually happened.
        this.unknownTypes.push(f.type);
      }
      this.events.push(f);
      return;
    }

    const p = this.pending.get(f.id);
    if (!p) {
      // `raw()` frames are sent deliberately without a waiter — they are the
      // malformed ones — so a reply to one is expected, not a violation.
      if (!this.rawIds.has(f.id))
        this.violate(`reply correlated to ${f.id}, which was never sent`, f);
      return;
    }
    this.pending.delete(f.id);
    p.resolve(f);
  }

  /** PROTOCOL.md §8.8: buffer chunks, never assume line boundaries. */
  track(f) {
    if (f.type !== "run.log") return;
    const { attempt_id, stream, chunk, seq } = f.payload ?? {};
    const key = `${attempt_id}|${stream}`;
    const rec = this.logs.get(key) ?? { text: "", seqs: [] };
    rec.text += typeof chunk === "string" ? chunk : "";
    rec.seqs.push(seq);
    this.logs.set(key, rec);
  }

  /** Send a request and wait for the reply the server correlates to it. */
  send(type, payload = {}, { v = 1, id = null, extra = null } = {}) {
    const frameId = id ?? `${this.label}-${++this.n}`;
    const frame = { v, id: frameId, type, payload };
    if (extra) Object.assign(frame, extra); // §8.1's negative case, on purpose
    const p = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(frameId);
        reject(new Error(`no reply to ${type} (${frameId}) within ${TIMEOUT_MS}ms`));
      }, TIMEOUT_MS);
      this.pending.set(frameId, {
        resolve: (f) => (clearTimeout(timer), resolve(f)),
        reject: (e) => (clearTimeout(timer), reject(e)),
      });
    });
    // An abandoned request whose socket dies later would otherwise be an
    // unhandled rejection and take the process with it. Registering a no-op
    // handler here marks it handled; a caller that does await it still gets
    // the rejection, because this is the same promise.
    p.catch(() => {});
    this.write(frame);
    return p;
  }

  write(frame) {
    const text = JSON.stringify(frame);
    this.outbound.push({ frame, text, at: Date.now() });
    this.ws.send(text);
  }

  /** Send verbatim without waiting. `id` is remembered so a reply to it is
   *  not mistaken for a reply to nothing. */
  raw(text, id = null) {
    if (id !== null) this.rawIds.add(id);
    this.outbound.push({ frame: null, text, at: Date.now() });
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
/** `point` is the PROTOCOL.md §8 number, or null for a supplementary check. */
const check = (point, name, fn) => checks.push({ point, name, fn });

function assert(cond, message) {
  if (!cond) throw new Error(message);
}
function assertEq(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected))
    throw new Error(
      `${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
}
function assertErr(frame, code, what) {
  assert(
    typeof frame.type === "string" && frame.type.endsWith(".err"),
    `${what}: expected an .err, got ${frame.type}`,
  );
  assertEq(frame.payload.code, code, `${what} code`);
}

/** Every frame every client sent, for the §8.5 audit. */
const allOutbound = [];
const allViolations = [];
const origClose = Client.prototype.close;
Client.prototype.close = function close() {
  allViolations.push(...this.violations);
  allOutbound.push(...this.outbound);
  this.violations = [];
  this.outbound = [];
  return origClose.call(this);
};

/** An authenticated connection. PROTOCOL.md §4.2–§4.3, done properly. */
async function session(acct, label, { name } = {}) {
  const cl = new Client(URL_WS, label);
  await cl.connect();
  const ch = await cl.send("auth.challenge", { address: acct.address });
  assert(
    ch.type === "auth.challenge.ok",
    `challenge refused: ${JSON.stringify(ch.payload)}`,
  );
  // §8.6: the message is signed exactly as given, never rebuilt.
  const payload = { address: acct.address, signature: sign(acct.private_key, ch.payload.message) };
  if (name) payload.name = name;
  const login = await cl.send("auth.login", payload);
  assert(
    login.type === "auth.login.ok",
    `login refused: ${JSON.stringify(login.payload)}`,
  );
  cl.token = login.payload.token;
  cl.user = login.payload.user;
  cl.account = acct;
  return cl;
}

/** The first node a player can actually attempt, with its quest. */
async function firstOpenQuest(cl) {
  const map = await cl.send("world.map", { land: "rust", category: "basic" });
  assertEq(map.type, "world.map.ok", "world.map");
  const open = map.payload.nodes.find((n) => n.state === "open");
  assert(open, "the map has no open node, and §4.7 says every node is playable");
  const got = await cl.send("quest.get", { quest_id: open.quest_id });
  assertEq(got.type, "quest.get.ok", "quest.get");
  return { node: open, quest: got.payload.quest, map: map.payload };
}

/**
 * An open node whose visible case this checker can compose an answer for.
 *
 * Not every quest is answerable by printing a constant, and it should not be
 * — one that reads stdin is teaching something. So: walk the open nodes and
 * take the first that is. A checker that hard-codes `rust.basic.01` breaks
 * the day PM renumbers the map.
 */
async function anAnswerableQuest(cl) {
  const map = await cl.send("world.map", { land: "rust", category: "basic" });
  assertEq(map.type, "world.map.ok", "world.map");
  for (const node of map.payload.nodes.filter((n) => n.state === "open")) {
    const got = await cl.send("quest.get", { quest_id: node.quest_id });
    if (got.type !== "quest.get.ok") continue;
    const quest = got.payload.quest;
    const source = rightSourceFor(quest);
    if (source) return { node, quest, source, map: map.payload };
  }
  throw new Error(
    "no open quest whose visible case this checker can answer by printing a " +
      "constant. Either every open node reads stdin, or this account has " +
      "already cleared the ones that do not — fresh accounts are derived per " +
      `run (index ${FRESH_BASE}+), so the former is the likely one.`,
  );
}

const WRONG_SOURCE = 'fn main() { println!("deliberately not the answer"); }';
const rightSourceFor = (quest) => sourceThatPrints(quest?.tests?.visible?.[0]);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Feed a frame through the real receive path, as if the server sent it. */
const inject = (cl, frame) => cl.receive(JSON.stringify(frame));

// ====================================================================
// PROTOCOL.md §8 — the conformance checklist, one case per point
// ====================================================================

check("8.1", "every frame is exactly v/id/type/payload, payload an object", async () => {
  const cl = new Client(URL_WS, "p1");
  await cl.connect();
  try {
    const ok = await cl.send("ping", {});
    assertEq(ok.type, "ping.ok", "a well-formed ping");
    assert(typeof ok.payload.t === "string", "§4.1: ping.ok payload has no `t`");

    // §2: "the server does not silently ignore fields, because a silently
    // ignored field is how a client ships a bug that looks like it works."
    const extra = await cl.send("ping", {}, { extra: { trace: "please-reject-me" } });
    assertErr(extra, "bad_request", "a frame with an unknown top-level key");

    // payload absent, bare, and an array.
    cl.raw(JSON.stringify({ v: 1, id: "p1-a", type: "ping" }), "p1-a");
    cl.raw(JSON.stringify({ v: 1, id: "p1-b", type: "ping", payload: 7 }), "p1-b");
    cl.raw(JSON.stringify({ v: 1, id: "p1-c", type: "ping", payload: [] }), "p1-c");
    await sleep(800);
    const answers = new Map(
      cl.inbound.filter((f) => ["p1-a", "p1-b", "p1-c"].includes(f.id)).map((f) => [f.id, f]),
    );
    assertEq(answers.size, 3, "one answer per malformed frame");
    // A payload that is present but not an object is unambiguously wrong.
    assertErr(answers.get("p1-b"), "bad_request", "payload: 7 (a bare value)");
    assertErr(answers.get("p1-c"), "bad_request", "payload: [] (an array)");
    // An ABSENT payload is the softer case. §2's table says "never absent.
    // Use {}", and §2 opens with "an object with exactly these four keys" —
    // so a three-key frame is not a conformant frame. A server that treats it
    // as {} is being generous, which is defensible and is also how a client
    // ships a bug that looks like it works. Raised in docs/decisions.md;
    // asserted here, because the alternative is to stop asserting §2.
    assertErr(
      answers.get("p1-a"),
      "bad_request",
      "payload absent — §2: a frame has exactly v, id, type, payload",
    );
    assert(cl.open, "§3.3: an application error never closes the connection");

    // And this client's own frames obey the rule.
    for (const { frame } of cl.outbound) {
      if (!frame || "trace" in frame) continue; // the deliberate negatives
      assertEq(Object.keys(frame).sort(), ENVELOPE_KEYS, "a frame this checker sent");
    }
  } finally {
    cl.close();
  }
});

check("8.2", "replies are matched by id and may arrive out of order", async () => {
  const cl = await session(freshAccount("ordering"), "p2");
  try {
    // §2.2: "quest.submit takes seconds and a ping sent after it will come
    // back first." Start the slow one, then the fast one; require the fast
    // one back first, with both correctly correlated.
    const { node, quest } = await firstOpenQuest(cl);
    const order = [];
    const slow = cl
      .send("quest.submit", {
        quest_id: node.quest_id,
        lang: "rust",
        source: rightSourceFor(quest) ?? WRONG_SOURCE,
      })
      .then((f) => (order.push("submit"), f));
    const fast = cl.send("ping", {}).then((f) => (order.push("ping"), f));
    const [pong, attempt] = await Promise.all([fast, slow]);
    assertEq(pong.type, "ping.ok", "the ping sent during a submit");
    assertEq(attempt.type, "quest.submit.ok", "the submit");
    assertEq(
      order[0],
      "ping",
      "the ping did not come back first. Either the server serialises its " +
        "replies — legal, but it means §2.2's out-of-order promise is " +
        "untested here — or the compile was instant.",
    );

    // §2.2: "Reusing an `id` that is still in flight is bad_request."
    //
    // Both frames go out with `raw`, no waiter on either: two promises on one
    // id would be this client's bug, not the server's, and the point is to
    // test the server. The replies are read back off the inbound log.
    cl.rawIds.add("p2-held");
    cl.raw(
      JSON.stringify({
        v: 1,
        id: "p2-held",
        type: "quest.submit",
        payload: { quest_id: node.quest_id, lang: "rust", source: WRONG_SOURCE },
      }),
    );
    await sleep(50); // let it become in-flight
    cl.raw(JSON.stringify({ v: 1, id: "p2-held", type: "ping", payload: {} }));

    const until = Date.now() + 15_000;
    let dup = null;
    let finished = null;
    while (Date.now() < until && !(dup && finished)) {
      dup ??= cl.inbound.find((x) => x.id === "p2-held" && x.type === "ping.err");
      finished ??= cl.inbound.find(
        (x) => x.id === "p2-held" && x.type.startsWith("quest.submit."),
      );
      if (!(dup && finished)) await sleep(100);
    }
    assert(
      dup !== null && dup.payload.code === "bad_request",
      `§2.2: reusing an in-flight id must be bad_request, got ${JSON.stringify(dup)}`,
    );
    assert(
      finished !== null && finished.type === "quest.submit.ok",
      "§2.2: the original request must still complete; the duplicate is what is refused",
    );
  } finally {
    cl.close();
  }
});

check("8.3", "an unknown type is ignored, not an error and not a close", async () => {
  // Authenticated on purpose: an unknown type sent while ANONYMOUS is
  // answered `unauthorized` by §3.1 before the server ever reaches its
  // unknown-type path, and a test that stops there proves nothing.
  const cl = await session(freshAccount("unknown-type"), "p3");
  try {
    // The server's half: a type it does not know gets an error from the
    // closed set, and the connection lives.
    const r = await cl.send("no.such.message", {});
    assert(r.type.endsWith(".err"), `an unknown type gave ${r.type}`);
    assert(
      ERROR_CODES.has(r.payload.code),
      `an unknown type gave ${r.payload.code}, outside §3.3`,
    );
    assert(cl.open, "the server closed the connection over an unknown type");

    // This client's half: an unsolicited frame whose type it does not know
    // is dropped on the floor, not thrown. Fed through the same receive path
    // a real frame takes — §2.3 is what lets the server add events without
    // breaking an older client, so it has to be tested, not assumed.
    const before = cl.violations.length;
    inject(cl, {
      v: 1,
      id: null,
      type: "future.event.from.a.newer.server",
      payload: { whatever: true },
    });
    assertEq(
      cl.violations.length,
      before,
      "an unknown event type was recorded as a protocol violation",
    );
    assert(
      cl.unknownTypes.includes("future.event.from.a.newer.server"),
      "the unknown event never reached the handler — the test proved nothing",
    );
    assert(cl.open, "this client closed the connection over an unknown event");
  } finally {
    cl.close();
  }
});

check("8.4", "every error code is in §3.3's closed set, and they are reachable", async () => {
  const seen = new Set();
  const cl = new Client(URL_WS, "p4");
  await cl.connect();
  try {
    // unauthorized — anything outside §3.1's four, before login.
    assertErr(await cl.send("world.lands", {}), "unauthorized", "world.lands before login");
    seen.add("unauthorized");

    // proto_version — §2.1, with detail.supported.
    const v = await cl.send("ping", {}, { v: 99 });
    assertErr(v, "proto_version", "an unknown v");
    assert(
      Array.isArray(v.payload.detail?.supported),
      '§2.1: proto_version\'s detail must carry {"supported":[1]}',
    );
    assert(cl.open, "§2.1: the connection stays open on an unknown version");
    seen.add("proto_version");

    // bad_request — a frame with an extra top-level key.
    assertErr(
      await cl.send("ping", {}, { extra: { nope: 1 } }),
      "bad_request",
      "an extra top-level key",
    );
    seen.add("bad_request");

    // auth_bad_signature — on its own connection, because a connection that
    // has authenticated refuses a second auth.login (§3.1: "A connection
    // never goes back to ANONYMOUS").
    const acct = freshAccount("codes");
    {
      const bad = new Client(URL_WS, "p4bad");
      await bad.connect();
      await bad.send("auth.challenge", { address: acct.address });
      assertErr(
        await bad.send("auth.login", {
          address: acct.address,
          signature: `0x${"00".repeat(65)}`,
        }),
        "auth_bad_signature",
        "an all-zero signature",
      );
      seen.add("auth_bad_signature");
      bad.close();
    }

    // auth_nonce_used — a genuine replay of a signature that already worked.
    {
      const one = new Client(URL_WS, "p4rep");
      await one.connect();
      const ch = await one.send("auth.challenge", { address: acct.address });
      const sig = sign(acct.private_key, ch.payload.message);
      assertEq(
        (await one.send("auth.login", { address: acct.address, signature: sig })).type,
        "auth.login.ok",
        "the first login",
      );
      one.close();

      const two = new Client(URL_WS, "p4rep2");
      await two.connect();
      const replay = await two.send("auth.login", {
        address: acct.address,
        signature: sig,
      });
      assert(replay.type.endsWith(".err"), "a replayed signature must not log in");
      assert(
        ["auth_nonce_used", "auth_expired"].includes(replay.payload.code),
        `§3.3: a replay should be auth_nonce_used (auth_expired tolerated), got ` +
          `${replay.payload.code}`,
      );
      seen.add(replay.payload.code);
      two.close();
    }

    // The rest needs an authenticated connection, and `cl` is still the
    // anonymous one on purpose (the codes above are anonymous-reachable).
    cl.close();
    const auth = await session(freshAccount("codes2"), "p4auth");
    Object.assign(cl, {}); // keep the finally-block harmless
    // not_found — a quest id that does not exist.
    assertErr(
      await auth.send("quest.get", { quest_id: "rust.basic.99.nope" }),
      "not_found",
      "a quest id that does not exist",
    );
    seen.add("not_found");

    // §4.7: **every node is playable**, so `locked` is no longer reachable.
    // This is the inverse assertion — the map offers nothing locked, and the
    // deepest node on it takes a submission like any other.
    //
    // The rule it protects is the reason §4.7 exists: "somebody with an
    // interview on Thursday needs to open the dynamic-programming street on
    // Tuesday without grinding through eighteen quests about `&str` first."
    const map = await auth.send("world.map", { land: "rust", category: "basic" });
    const nodes = map.payload.nodes;
    assert(nodes.length > 1, "the rust/basic map has more than one node");
    const stillLocked = nodes.filter((n) => n.state === "locked");
    assertEq(
      stillLocked.map((n) => n.quest_id),
      [],
      "§4.7 and §5.2: `state` is `open` or `cleared`, never `locked`",
    );

    const deepest = nodes.reduce((a, b) => (a.node > b.node ? a : b));
    assert(
      deepest.node > 1,
      "the map is one node deep, so 'you may start anywhere' is untestable",
    );
    const straightIn = await auth.send("quest.submit", {
      quest_id: deepest.quest_id,
      lang: "rust",
      source: WRONG_SOURCE,
    });
    assertEq(
      straightIn.type,
      "quest.submit.ok",
      `§4.7: the last node of the map (${deepest.quest_id}) refused a ` +
        `submission from a player who has cleared nothing`,
    );
    assertEq(straightIn.payload.attempt.cleared, false, "it was the wrong answer");

    // bad_request — `lang` disagreeing with the quest (§4.9).
    const open = map.payload.nodes.find((n) => n.state === "open");
    if (open) {
      assertErr(
        await auth.send("quest.submit", {
          quest_id: open.quest_id,
          lang: "go",
          source: "package main\nfunc main() {}\n",
        }),
        "bad_request",
        "§4.9: lang disagreeing with the quest's land",
      );
    }
    auth.close();
  } finally {
    cl.close();
  }
  // Seven of the eleven are provoked here. The rest are reachable but not
  // from one connection in one pass — `rate_limited` needs a limit nothing in
  // this suite knows, `internal` needs a broken server, `auth_expired` needs
  // a 120-second wait — and `locked` is in the set and deliberately
  // unreachable (§4.7). Naming that is the point: "every code is in the set"
  // and "every code can be produced" are different claims.
  assert(
    seen.size >= 6,
    `only provoked ${[...seen].sort().join(", ")} — expected 6+ of the closed set`,
  );
  assert(
    !seen.has("locked"),
    "`locked` was emitted. §4.7 says every node is playable and this code is " +
      "kept in the closed set only so an exhaustive client still compiles.",
  );
});

check("8.5", "no mnemonic or private key is ever sent, in any field", async () => {
  // §8.5, and SPEC §3.1's non-negotiable. This checker holds five private
  // keys in memory and signs with them, so the assertion has something real
  // to be wrong about. It audits every frame every connection has sent so
  // far, which is why it runs after the auth points rather than before.
  const cl = await session(account("reader"), "p5");
  try {
    await cl.send("world.lands", {});
    await cl.send("profile.update", { name: "smoke" });
  } finally {
    cl.close();
  }

  const secrets = SECRETS();
  const phrases = JSON.parse(readFileSync(VECTORS, "utf8")).mnemonics.map((m) => m.phrase);
  const offenders = [];
  for (const { text } of allOutbound) {
    const hay = text.toLowerCase();
    for (const s of secrets)
      if (hay.includes(s.toLowerCase())) offenders.push(`a private key in ${text.slice(0, 120)}`);
    for (const p of phrases)
      if (hay.includes(p.toLowerCase())) offenders.push(`a mnemonic in ${text.slice(0, 120)}`);
    for (const k of ["mnemonic", "private_key", "privkey", "seed", "passphrase"])
      if (hay.includes(`"${k}"`)) offenders.push(`a "${k}" field in ${text.slice(0, 120)}`);
  }
  assert(offenders.length === 0, `key material on the wire:\n    ${offenders.join("\n    ")}`);
  assert(
    allOutbound.length > 10,
    `only ${allOutbound.length} frames were audited — this point is only ` +
      `meaningful across the whole suite, not under --only`,
  );
});

check("8.6", "the challenge message is signed byte-for-byte, not rebuilt", async () => {
  // §4.2's warning, made into a test. A client that reassembles the string
  // from `nonce` and `expires_at` will disagree about a space or a trailing
  // newline and fail for reasons that take a day to find — so the server must
  // reject a signature over a reconstruction, and this proves it does.
  const acct = account("reader");
  const cl = new Client(URL_WS, "p6");
  await cl.connect();
  try {
    const ch = await cl.send("auth.challenge", { address: acct.address });
    const { nonce, message, expires_at } = ch.payload;

    // §4.2's exact shape, asserted against the server's own string.
    const lines = message.split("\n");
    assertEq(lines.length, 4, "§4.2: four lines, no trailing newline");
    assertEq(lines[0], "Causewaybay Hacker login", "line 1");
    assertEq(lines[1], `address: ${acct.address}`, "line 2 — EIP-55, no annotation");
    assertEq(lines[2], `nonce: ${nonce}`, "line 3");
    assertEq(lines[3], `expires: ${expires_at}`, "line 4");
    assert(/^[0-9a-f]{64}$/.test(nonce), `§4.2: nonce is 64 lowercase hex, got ${nonce}`);
    assert(
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(expires_at),
      `§2.4: RFC3339 UTC with seconds, got ${expires_at}`,
    );
    const secs = (Date.parse(expires_at) - Date.now()) / 1000;
    assert(secs > 100 && secs < 140, `§4.2 says 120s out; this is ${secs.toFixed(0)}s`);

    // §4.3: r || s || v, 65 bytes, v = 27 or 28.
    const good = sign(acct.private_key, message);
    const v = parseInt(good.slice(-2), 16);
    assert([27, 28].includes(v), `§4.3: v should be 27 or 28, the signer gave ${v}`);
    assertEq(good.length, 132, "§4.3: 0x + 130 hex = 65 bytes");

    // The most plausible reconstruction: the same parts, one trailing
    // newline. It must not authenticate.
    //
    // Every login below gets its OWN connection. A connection that has
    // authenticated refuses a second `auth.login` (§3.1: "A connection never
    // goes back to ANONYMOUS"), and a rejected signature may or may not have
    // burned the nonce — see the decisions.md entry of 2026-09-11. Neither is
    // what this point is testing, so neither is allowed to confuse it.
    const attempt = async (label, signature, address = acct.address) => {
      const c = new Client(URL_WS, label);
      await c.connect();
      try {
        const fresh = await c.send("auth.challenge", { address });
        const sig = typeof signature === "function" ? signature(fresh.payload) : signature;
        return await c.send("auth.login", { address, signature: sig });
      } finally {
        c.close();
      }
    };

    assertErr(
      await attempt("p6-rebuilt", (p) => sign(acct.private_key, `${p.message}\n`)),
      "auth_bad_signature",
      "a signature over a rebuilt message (one trailing newline)",
    );
    assertEq(
      (await attempt("p6-good", (p) => sign(acct.private_key, p.message))).type,
      "auth.login.ok",
      "a signature over the message exactly as given",
    );

    // §4.3's byte order, as a negative: r||s||v is not s||r||v, and it is not
    // v||r||s. A client assembling noble's [recid, r, s] in the order it was
    // handed them produces exactly these, and both must be refused.
    const r = good.slice(2, 66);
    const s = good.slice(66, 130);
    const vv = good.slice(130);
    assertErr(
      await attempt("p6-srv", (p) => {
        const g = sign(acct.private_key, p.message);
        return `0x${g.slice(66, 130)}${g.slice(2, 66)}${g.slice(130)}`;
      }),
      "auth_bad_signature",
      "§4.3: s||r||v must not authenticate",
    );
    assertErr(
      await attempt("p6-vrs", (p) => {
        const g = sign(acct.private_key, p.message);
        return `0x${g.slice(130)}${g.slice(2, 130)}`;
      }),
      "auth_bad_signature",
      "§4.3: v||r||s must not authenticate — noble v2 hands back [recid, r, s]",
    );
    void r, s, vv;

    // §4.3: "0 or 1 is also accepted and normalised."
    assertEq(
      (
        await attempt("p6-v01", (p) => {
          const g = sign(acct.private_key, p.message);
          return (
            g.slice(0, -2) +
            (parseInt(g.slice(-2), 16) - 27).toString(16).padStart(2, "0")
          );
        })
      ).type,
      "auth.login.ok",
      "§4.3: a v of 0/1 must be accepted and normalised",
    );
  } finally {
    cl.close();
  }
});

check("8.7", "auth.resume rotates the token; the returned one is the live one", async () => {
  const acct = account("reader");
  const first = await session(acct, "p7a");
  const sent = first.token;
  first.close();

  const cl = new Client(URL_WS, "p7b");
  await cl.connect();
  try {
    const r = await cl.send("auth.resume", { token: sent });
    assertEq(r.type, "auth.resume.ok", "resume with a live token");
    const returned = r.payload.token;
    assert(typeof returned === "string" && returned.length > 0, "no token returned");
    assertEq(
      r.payload.user.address,
      acct.address,
      "§2.4: addresses are EIP-55 on the wire, in both directions",
    );
    assertEq(
      (await cl.send("world.lands", {})).type,
      "world.lands.ok",
      "a resumed connection is a real session",
    );

    // §4.4: "The returned token may differ from the one sent — the server
    // rotates on use. Store the returned one." A client that keeps the old
    // one works right up until the server actually rotates, and then logs
    // the player out for no visible reason.
    const withNew = new Client(URL_WS, "p7c");
    await withNew.connect();
    assertEq(
      (await withNew.send("auth.resume", { token: returned })).type,
      "auth.resume.ok",
      "the token auth.resume returned must itself work",
    );
    withNew.close();

    if (returned !== sent) {
      const withOld = new Client(URL_WS, "p7d");
      await withOld.connect();
      assertErr(
        await withOld.send("auth.resume", { token: sent }),
        "unauthorized",
        "§4.4: a token that was rotated away must be dead",
      );
      withOld.close();
    }

    const junk = new Client(URL_WS, "p7e");
    await junk.connect();
    assertErr(
      await junk.send("auth.resume", { token: "not-a-token" }),
      "unauthorized",
      "an unknown token",
    );
    assert(junk.open, "§3.3: the connection stays open");
    junk.close();
  } finally {
    cl.close();
  }
});

check("8.8", "run.log seq starts at 0 per stream with no gaps, chunks buffer", async () => {
  const cl = await session(freshAccount("streamer"), "p8");
  try {
    const { node, quest } = await firstOpenQuest(cl);
    const r = await cl.send("quest.submit", {
      quest_id: node.quest_id,
      lang: "rust",
      source: rightSourceFor(quest) ?? WRONG_SOURCE,
    });
    assertEq(r.type, "quest.submit.ok", "the submit");
    const attemptId = r.payload.attempt.id;
    await sleep(400); // §4's note: events may trail the reply they relate to

    const stages = cl.events.filter(
      (e) => e.type === "run.stage" && e.payload.attempt_id === attemptId,
    );
    assert(stages.length > 0, "§4.17: no run.stage during a submit");
    assert(
      stages.every((e) => e.id === null),
      "§2.2: a server-initiated event must carry id: null",
    );
    const order = ["queued", "compiling", "running", "judging"];
    const seenStages = stages.map((e) => e.payload.stage);
    assert(
      seenStages.every((s) => order.includes(s)),
      `§4.17: a stage outside the set: ${seenStages}`,
    );
    // "Strictly ordered, each sent once."
    assertEq(seenStages, [...new Set(seenStages)], "§4.17: a stage was sent twice");
    const idx = seenStages.map((s) => order.indexOf(s));
    assertEq(
      idx,
      [...idx].sort((a, b) => a - b),
      `§4.17: stages out of order: ${seenStages}`,
    );

    const logs = [...cl.logs.entries()].filter(([k]) => k.startsWith(attemptId));
    assert(logs.length > 0, "§4.18: no run.log at all for an attempt that compiled");
    for (const [key, rec] of logs) {
      const stream = key.split("|")[1];
      assert(
        ["compile", "stdout", "stderr"].includes(stream),
        `§4.18: stream ${stream} is outside the set`,
      );
      assertEq(rec.seqs[0], 0, `§4.18: the ${stream} stream's seq must start at 0`);
      assertEq(
        rec.seqs,
        rec.seqs.map((_, i) => i),
        `§4.18: the ${stream} stream has a seq gap or repeat: ${rec.seqs}`,
      );
    }

    // The buffering half, tested where it can be: a chunk split mid-line and
    // mid-codepoint-sequence must reassemble, and must not be treated as a
    // line. Injected because the server has no way to be asked for one.
    const probe = new Client(URL_WS, "p8b");
    for (const [i, chunk] of ["error[E00", "01]: half a li", "ne\nand more"].entries())
      inject(probe, {
        v: 1,
        id: null,
        type: "run.log",
        payload: { attempt_id: "att_probe", stream: "compile", chunk, seq: i },
      });
    assertEq(
      probe.logs.get("att_probe|compile").text,
      "error[E0001]: half a line\nand more",
      "§8.8: chunks split mid-line must reassemble exactly",
    );
    assertEq(probe.violations.length, 0, "the injected chunks were read as violations");
  } finally {
    cl.close();
  }
});

check("8.9", "a reconnect resumes with the token and the map is refetched", async () => {
  const acct = freshAccount("alice");
  const first = await session(acct, "p9a");
  let token = first.token;
  const before = await firstOpenQuest(first);
  // A drop rather than a polite goodbye — the sleeping-laptop case. 1006 is
  // reserved and cannot be *sent* by an endpoint, so the nearest honest
  // simulation is a close in the private-use range with no server.bye first.
  first.ws.close(4000, "simulated drop");
  await sleep(150);
  assert(!first.open, "the socket did not actually drop");

  // §6.2's schedule, asserted as code rather than by waiting fifteen seconds:
  // 0.5, 1, 2, 4, 8, then 8s, each with ±20% jitter.
  const schedule = backoff(7);
  assert(
    schedule.every((d, i) => {
      const base = Math.min(500 * 2 ** i, 8000);
      return d >= base * 0.8 && d <= base * 1.2;
    }),
    `§6.2: the backoff schedule is off: ${schedule}`,
  );

  const cl = new Client(URL_WS, "p9b");
  await cl.connect();
  try {
    const r = await cl.send("auth.resume", { token });
    assertEq(r.type, "auth.resume.ok", "§6.3: resume with the stored token");
    token = r.payload.token; // §6.3: store the one it returns
    assert(typeof token === "string" && token.length > 0, "no token after resume");
    // §6.5: "Do not trust a map cached across a disconnect."
    const after = await firstOpenQuest(cl);
    assertEq(
      after.map.nodes.map((n) => n.quest_id),
      before.map.nodes.map((n) => n.quest_id),
      "the refetched map is a different overworld",
    );
    // §6.6: an in-flight submit survives the drop and is findable in history.
    const hist = await cl.send("stats.history", { quest_id: before.node.quest_id, limit: 5 });
    assertEq(hist.type, "stats.history.ok", "§6.6: stats.history after a resume");
    assert(Array.isArray(hist.payload.attempts), "§5.7: attempts is an array");
  } finally {
    cl.close();
  }
});

/** PROTOCOL.md §6.2's schedule, as code so the rule is testable. */
function backoff(n) {
  const out = [];
  for (let i = 0; i < n; i++) {
    const base = Math.min(500 * 2 ** i, 8000);
    out.push(Math.round(base * (1 + (Math.random() * 0.4 - 0.2))));
  }
  return out;
}

check("8.10", "a second quest.submit while one is in flight is busy", async () => {
  const acct = freshAccount("busy");
  const cl = await session(acct, "p10");
  try {
    const { node, quest } = await firstOpenQuest(cl);
    const body = {
      quest_id: node.quest_id,
      lang: "rust",
      source: rightSourceFor(quest) ?? WRONG_SOURCE,
    };
    const first = cl.send("quest.submit", body);
    assertErr(
      await cl.send("quest.submit", { ...body, source: WRONG_SOURCE }),
      "busy",
      "§3.2: the second concurrent submit on one connection",
    );
    // §4.9b: runs and submits share the one-execution rule, so the pair that
    // matters is the *mixed* one. A server that keeps two locks — one for
    // runs, one for submits — passes submit-then-submit and then compiles two
    // programs at once the first time a player presses RUN while a SUBMIT is
    // still going.
    assertErr(
      await cl.send("quest.run", { ...body, source: WRONG_SOURCE }),
      "busy",
      "§4.9b: a run while a submit is in flight",
    );
    assertEq((await first).type, "quest.submit.ok", "the first submit still finished");

    const running = cl.send("quest.run", body);
    assertErr(
      await cl.send("quest.submit", { ...body, source: WRONG_SOURCE }),
      "busy",
      "§4.9b: a submit while a run is in flight — the other half of the pair",
    );
    assertErr(
      await cl.send("quest.run", { ...body, source: WRONG_SOURCE }),
      "busy",
      "§4.9b: a run while a run is in flight",
    );
    assertEq((await running).type, "quest.run.ok", "the first run still finished");

    // §3.2: "This is per connection, not per user" — the same wallet in two
    // windows gets two slots, and the server serialises the compiler behind
    // them. A server that keys the lock on the address instead looks correct
    // until somebody opens a second window.
    const other = await session(acct, "p10b");
    try {
      const third = cl.send("quest.submit", body);
      const onOther = await other.send("quest.submit", { ...body, source: WRONG_SOURCE });
      assert(
        !(onOther.type.endsWith(".err") && onOther.payload.code === "busy"),
        "§3.2: `busy` is per connection, but the user's second connection was refused",
      );
      await third;
    } finally {
      other.close();
    }
  } finally {
    cl.close();
  }
});

check("8.11", "an abrupt close is survivable, and server.bye is understood", async () => {
  const cl = new Client(URL_WS, "p11");
  await cl.connect();
  await cl.send("ping", {});
  // A close with no goodbye — the common case, and the harder one. (1006 is
  // reserved and cannot be sent; 4000 is the private-use range.)
  cl.ws.close(4000, "simulated drop");
  await sleep(250);
  assert(cl.closed !== null, "the close was never observed");
  assert(!cl.open, "the socket reports open after a close");
  assertEq(
    cl.pending.size,
    0,
    "in-flight requests were not rejected on close — a reconnect would leak waiters",
  );

  // The `server.bye`-then-close half needs a server willing to shut down, so
  // what is asserted here is that a client handles the frame when it comes:
  // through the real receive path it is a known event, not a violation.
  const cl2 = new Client(URL_WS, "p11b");
  await cl2.connect();
  try {
    const before = cl2.violations.length;
    inject(cl2, { v: 1, id: null, type: "server.bye", payload: { reason: "shutdown" } });
    assertEq(cl2.violations.length, before, "server.bye was read as a violation");
    const bye = cl2.events.find((e) => e.type === "server.bye");
    assert(bye, "server.bye never reached the event list");
    assert(
      ["shutdown", "revoked", "replaced"].includes(bye.payload.reason),
      `§4.21: reason ${bye.payload.reason} is outside the set`,
    );
    assert(cl2.open, "a server.bye must not make the client close first");
  } finally {
    cl2.close();
  }
});

check("8.12", "an idle connection survives the keepalive window", async () => {
  // §1.1: the server sends a websocket ping every 30 s and drops a connection
  // that misses two. Node's WebSocket answers pongs itself, so what is
  // honestly assertable here is that an idle connection survives — plus the
  // application-level `ping` that §1.1 requires of a client whose library
  // cannot answer pongs (the LÖVE client's hand-rolled one). The full
  // 70-second version is behind --slow, because a two-second contract checker
  // is one people actually run.
  const idleMs = SLOW ? 70_000 : 6_000;
  const cl = new Client(URL_WS, "p12");
  await cl.connect();
  try {
    const started = Date.now();
    while (Date.now() - started < idleMs) {
      await sleep(Math.min(2_000, idleMs));
      if (!cl.open) break;
      // §1.1's fallback cadence, compressed. Harmless for a client that can
      // answer websocket pings; required for one that cannot.
      const t = await cl.send("ping", {});
      assertEq(t.type, "ping.ok", "an application-level keepalive ping");
    }
    assert(
      cl.open,
      `the connection closed after ${((Date.now() - started) / 1000).toFixed(0)}s of ` +
        `keepalive-only traffic` + (cl.closed ? ` with code ${cl.closed.code}` : ""),
    );
    if (!SLOW && !AS_JSON)
      console.log(
        dim(`      ${idleMs / 1000}s only — pass --slow for the real 70s window`),
      );
  } finally {
    cl.close();
  }
});

// ====================================================================
// Beyond the checklist — server-side rules that no §8 point covers but
// that a client would be broken by.
// ====================================================================

check(null, "beyond: the four ANONYMOUS messages, and nothing else", async () => {
  // PROTOCOL.md §3.1's state machine, exhaustively over §4's catalogue.
  const cl = new Client(URL_WS, "anon");
  await cl.connect();
  try {
    assertEq((await cl.send("ping", {})).type, "ping.ok", "ping while anonymous");
    const acct = account("reader");
    assertEq(
      (await cl.send("auth.challenge", { address: acct.address })).type,
      "auth.challenge.ok",
      "auth.challenge while anonymous",
    );
    // auth.login and auth.resume must be reachable, or a connection could
    // never leave ANONYMOUS. Asserted by their being answered with an *auth*
    // error rather than `unauthorized`.
    const login = await cl.send("auth.login", {
      address: acct.address,
      signature: `0x${"11".repeat(65)}`,
    });
    assert(
      login.payload.code !== "unauthorized",
      "§3.1: auth.login must be reachable while anonymous",
    );
    assertErr(
      await cl.send("auth.resume", { token: "nope" }),
      "unauthorized",
      "§4.4: an unknown token",
    );

    const rest = [
      ["profile.update", { name: "nope" }],
      ["world.lands", {}],
      ["world.map", { land: "rust", category: "basic" }],
      ["quest.get", { quest_id: "rust.basic.01.hello" }],
      ["quest.submit", { quest_id: "rust.basic.01.hello", lang: "rust", source: "fn main(){}" }],
      ["quest.hint", { quest_id: "rust.basic.01.hello", index: 0 }],
      ["quest.reset", { quest_id: "rust.basic.01.hello" }],
      ["search.query", { q: "hello" }],
      ["stats.summary", {}],
      ["stats.mistakes", {}],
      ["stats.history", {}],
      ["ai.plan", { mode: "repeat" }],
      ["ai.next", { drill_id: "drl_0000000000000000" }],
      ["ai.finish", { drill_id: "drl_0000000000000000" }],
    ];
    const bad = [];
    for (const [type, payload] of rest) {
      assert(!ANONYMOUS_OK.has(type), `${type} is in §3.1's anonymous set`);
      const r = await cl.send(type, payload);
      if (!r.type.endsWith(".err") || r.payload.code !== "unauthorized")
        bad.push(`${type} → ${r.type} ${r.payload.code ?? ""}`);
    }
    assert(bad.length === 0, `not unauthorized before login:\n    ${bad.join("\n    ")}`);
    assert(cl.open, "§3.1: the connection stays open through all of that");
  } finally {
    cl.close();
  }
});

check(null, "beyond: world.lands, world.map and quest.get match §5", async () => {
  const cl = await session(account("reader"), "shapes");
  try {
    const lands = await cl.send("world.lands", {});
    assertEq(lands.type, "world.lands.ok", "world.lands");
    for (const l of lands.payload.lands) {
      assert(
        ["rust", "go", "cpp", "python", "pytorch", "typescript"].includes(l.land),
        `§4.6: land ${l.land}`,
      );
      for (const cat of l.categories) {
        assert(
          ["verybasic", "basic", "advanced", "hacker"].includes(cat.category),
          `§4.6: category ${cat.category}`,
        );
        assert(cat.cleared <= cat.total, "§4.6: cleared exceeds total");
        assert(typeof cat.open === "boolean", "§4.6: `open` is missing");
        assert(typeof cat.stars === "number", "§4.6: `stars` is missing");
      }
    }

    const map = await cl.send("world.map", { land: "rust", category: "basic" });
    const nodes = map.payload.nodes;
    assertEq(map.payload.land, "rust", "§4.7: the map echoes its land");
    assertEq(map.payload.category, "basic", "§4.7: the map echoes its category");
    for (const n of nodes) {
      assert(
        /^(rust|go|cpp|python|pytorch|typescript)\.(verybasic|basic|advanced|hacker)\.\d{2}\..+$/.test(
          n.quest_id,
        ),
        `SPEC §4.1: quest_id ${n.quest_id}`,
      );
      // §5.2: `open` | `cleared`. Never `locked` — see §4.7.
      assert(["open", "cleared"].includes(n.state), `§5.2: state ${n.state}`);
      assert(n.stars >= 0 && n.stars <= 3, `§5.2: stars ${n.stars}`);
      assert(n.difficulty >= 1 && n.difficulty <= 5, `§5.2: difficulty ${n.difficulty}`);
      assert(["quest", "boss", "gate"].includes(n.kind), `§5.2: kind ${n.kind}`);
      assert(n.x >= 0 && n.x <= 1 && n.y >= 0 && n.y <= 1, `§5.2: position ${n.x},${n.y}`);
      assert(Array.isArray(n.requires), "§5.2: `requires` is missing");
      assert(typeof n.attempts === "number", "§5.2: `attempts` is missing");
    }
    // §5.2: 1-based and contiguous, "ordered by node".
    const numbers = nodes.map((n) => n.node);
    assertEq(numbers, numbers.map((_, i) => i + 1), "§4.7/§5.2: node numbering");
    // §4.7: edges are derived from `requires` and given explicitly, so a
    // client never has to infer the overworld's shape.
    const declared = new Set(map.payload.edges.map((e) => e.join("\u2192")));
    for (const n of nodes)
      for (const r of n.requires)
        assert(
          declared.has(`${r}\u2192${n.quest_id}`),
          `§4.7: the edge ${r} → ${n.quest_id} is missing from edges`,
        );

    const { quest } = await firstOpenQuest(cl);
    assert(typeof quest.starter === "string" && quest.starter, "§5.3: no starter code");
    assert(
      !("solution" in quest),
      "§4.8: `solution` is omitted entirely until cleared — not null, not empty",
    );
    assert(typeof quest.tests?.hidden_count === "number", "§5.3: tests.hidden_count");
    assert(Array.isArray(quest.tests?.visible), "§5.3: tests.visible");
    // PROTOCOL.md §4.8 named `Quest.tests.cases` before it was corrected, and
    // there is no such key on the wire. A client that reads it gets nothing
    // and renders an empty test list — which looks like a quest with no tests
    // rather than like a bug, so nobody investigates. Assert the key's
    // absence in both spellings.
    assert(
      !("cases" in quest.tests),
      "§4.8: `tests.cases` does not exist on the wire; it is `tests.visible` " +
        "plus `tests.hidden_count`. A client reading `cases` silently renders " +
        "an empty test list.",
    );
    assert(!("cases" in quest), "§5.3: `cases` is on Attempt, never on Quest");
    assert(quest.tests.visible.length > 0, "SPEC §12: at least one visible case");
    for (const v of quest.tests.visible)
      assert(
        typeof v.name === "string" && typeof v.expect === "string",
        "§5.3: a visible case is {name, stdin, expect}",
      );
    assert(
      !JSON.stringify(quest).includes('"visible":false'),
      "§4.8: hidden case data leaked into quest.get",
    );
    assert(typeof quest.hints_total === "number", "§5.3: hints_total");
    assert(
      quest.time_limit_s === null || typeof quest.time_limit_s === "number",
      "§5.3: time_limit_s is a number or null",
    );
    assert(["open", "cleared"].includes(quest.state), "§5.3: quest.state");
  } finally {
    cl.close();
  }
});

check(null, "beyond: progress.update reaches the same user's other connection", async () => {
  // PROTOCOL.md §4.19: "Also sent to the same user's other open connections,
  // which is how two windows stay in step." No §8 point covers it, and a
  // server that only answers the socket that asked looks entirely correct
  // until somebody opens a second window.
  // Its own account: this check clears a node, and an account shared with
  // the isolation check below would arrive there already cleared.
  const acct = freshAccount("two-windows");
  const a = await session(acct, "two-a");
  const b = await session(acct, "two-b"); // the same wallet, a second window
  try {
    const { node, source } = await anAnswerableQuest(a);
    const r = await a.send("quest.submit", {
      quest_id: node.quest_id,
      lang: "rust",
      source,
    });
    assertEq(r.type, "quest.submit.ok", "the submit");
    assertEq(r.payload.attempt.verdict, "accepted", "the composed answer");
    await sleep(500); // the event may trail the reply

    const onB = b.events.filter(
      (e) => e.type === "progress.update" && e.payload.quest_id === node.quest_id,
    );
    assert(onB.length > 0, "§4.19: the user's second connection never heard about it");
    const ev = onB[0];
    assertEq(ev.id, null, "§2.2: a server-initiated event carries id: null");
    assertEq(ev.payload.state, "cleared", "§4.19: state");
    assert(Array.isArray(ev.payload.unlocked), "§4.19: `unlocked` is missing");
    assert(typeof ev.payload.cleared_total === "number", "§4.19: `cleared_total`");
  } finally {
    a.close();
    b.close();
  }
});

check(null, "beyond: a saved pad and its room reach the same user's other connection", async () => {
  // PROTOCOL.md §4.22, §4.23: the same pad open on the tablet and the laptop.
  // A save or a post on one arrives on the other, and not on the one that
  // made the change.
  const acct = freshAccount("two-pads");
  const a = await session(acct, "pad-a");
  const b = await session(acct, "pad-b");
  try {
    const saved = await a.send("playground.save", {
      lang: "python",
      source: 'print("from a")\n',
      stdin: "3\n",
    });
    assertEq(saved.type, "playground.save.ok", "the save");
    const pad = saved.payload.snippet.id;
    await sleep(300);
    const onB = b.events.filter((e) => e.type === "playground.updated");
    assert(onB.length === 1, `§4.22: expected one playground.updated on the other window, got ${onB.length}`);
    assertEq(onB[0].id, null, "§2.2: an event carries id: null");
    assertEq(onB[0].payload.snippet.id, pad, "§4.22: the pad that was saved");
    assertEq(onB[0].payload.snippet.source, 'print("from a")\n', "§4.22: the snippet in full");
    assertEq(onB[0].payload.snippet.stdin, "3\n", "§4.22: stdin travels with it");
    assert(
      !a.events.some((e) => e.type === "playground.updated"),
      "§4.22: the window that saved must not be told about its own save",
    );

    const posted = await a.send("playground.chat.post", { id: pad, role: "user", text: "hi" });
    assertEq(posted.type, "playground.chat.post.ok", "the post");
    await a.send("playground.chat.clear", { id: pad });
    await sleep(300);
    const room = b.events.filter((e) => e.type === "playground.chat.updated").map((e) => e.payload);
    assert(room.length === 2, `§4.23: expected a post and a clear on the other window, got ${room.length}`);
    assertEq(room[0].id, pad);
    assertEq(room[0].message.id, posted.payload.message.id, "§4.23: the row as recorded, by id");
    assertEq(room[0].message.text, "hi");
    assertEq(room[1].cleared, true, "§4.23: clear");
  } finally {
    a.close();
    b.close();
  }
});

check(null, "beyond: two users never see each other's progress or attempts", async () => {
  // SPEC §9.8 and §3.5. Two addresses, two sessions, submissions that overlap
  // in time.
  const alice = freshAccount("alice");
  const bob = freshAccount("bob");
  const a = await session(alice, "iso-a");
  const b = await session(bob, "iso-b");
  try {
    const { node, source } = await anAnswerableQuest(a);

    const [aDone, bDone] = await Promise.all([
      a.send("quest.submit", {
        quest_id: node.quest_id,
        lang: "rust",
        source,
      }),
      b.send("quest.submit", {
        quest_id: node.quest_id,
        lang: "rust",
        source: WRONG_SOURCE,
      }),
    ]);
    assertEq(aDone.type, "quest.submit.ok", "alice's submit");
    assertEq(bDone.type, "quest.submit.ok", "bob's submit");
    assert(
      bDone.payload.attempt.verdict !== "accepted",
      "a source printing the wrong thing was accepted",
    );
    assert(
      aDone.payload.attempt.id !== bDone.payload.attempt.id,
      "the two attempts share an id",
    );

    const aHist = await a.send("stats.history", { limit: 50 });
    const bHist = await b.send("stats.history", { limit: 50 });
    const aIds = new Set(aHist.payload.attempts.map((x) => x.id));
    const bIds = new Set(bHist.payload.attempts.map((x) => x.id));
    assert(aIds.has(aDone.payload.attempt.id), "alice cannot see her own attempt");
    assert(bIds.has(bDone.payload.attempt.id), "bob cannot see his own attempt");
    assert(!aIds.has(bDone.payload.attempt.id), "alice can see bob's attempt");
    assert(!bIds.has(aDone.payload.attempt.id), "bob can see alice's attempt");

    const bMistakes = await b.send("stats.mistakes", { limit: 50 });
    assert(Array.isArray(bMistakes.payload.mistakes), "§5.6: stats.mistakes shape");
    const total = bMistakes.payload.mistakes.reduce((s, m) => s + m.count, 0);
    assert(total > 0, "bob's wrong answer produced no mistake row");

    if (aDone.payload.attempt.verdict === "accepted") {
      const aMap = await a.send("world.map", { land: "rust", category: "basic" });
      const bMap = await b.send("world.map", { land: "rust", category: "basic" });
      const aNode = aMap.payload.nodes.find((n) => n.quest_id === node.quest_id);
      const bNode = bMap.payload.nodes.find((n) => n.quest_id === node.quest_id);
      assertEq(aNode.state, "cleared", "alice's node after she cleared it");
      assert(bNode.state !== "cleared", "bob's node went cleared on alice's work");
      const aSum = await a.send("stats.summary", {});
      const bSum = await b.send("stats.summary", {});
      assert(aSum.payload.cleared >= 1, "§4.13: alice's cleared count");
      assert(
        bSum.payload.cleared < aSum.payload.cleared,
        "bob's cleared count includes alice's work",
      );
    }
  } finally {
    a.close();
    b.close();
  }
});

check(null, "beyond: what is not built says so, and what is built is judged", async () => {
  // `search.query` is SPEC §8 and it ships: BM25, the hashed embedder and
  // the fusion of the two, with the shape §5.5 fixes. `ai.*` is SPEC §7.3
  // and PLAN.md still puts it in milestone 2; it answers `unavailable` with
  // `detail: {"milestone": 2}`, which is the right shape — a closed-set code
  // plus a machine-readable reason, so a client can grey the button out.
  //
  // The `ai.*` half is a PENDING check, not a failing one. What it asserts is
  // that the gap is *declared* — the day the drills ship, this check starts
  // failing and that is the signal to write the real one.
  const cl = await session(freshAccount("m2"), "m2");
  try {
    for (const mode of ["bm25", "semantic", "unified"]) {
      const r = await cl.send("search.query", { q: "borrow", mode, limit: 5 });
      assertEq(r.type, "search.query.ok", `search.query in ${mode} mode`);
      assertEq(r.payload.mode, mode, "the mode it ran in");
      assert(Number.isInteger(r.payload.took_ms), "took_ms is an integer");
      assert(Array.isArray(r.payload.hits) && r.payload.hits.length > 0, `${mode}: "borrow" finds a quest`);
      assert(r.payload.hits.length <= 5, "limit is a limit");
      for (const h of r.payload.hits) {
        for (const key of ["quest_id", "title", "land", "category", "snippet", "score", "state"])
          assert(key in h, `SearchHit.${key} (§5.5)`);
        assert(typeof h.score === "number" && h.score > 0, "the fused score is positive");
        assert(["open", "cleared"].includes(h.state), `state is open|cleared, got ${h.state}`);
        if (mode === "bm25") assert(h.cosine === null && typeof h.bm25 === "number", "bm25 alone");
        if (mode === "semantic") assert(h.bm25 === null && typeof h.cosine === "number", "cosine alone");
      }
      const scores = r.payload.hits.map((h) => h.score);
      assert(scores.every((v, i) => i === 0 || v <= scores[i - 1]), "hits come best first");
    }
    const filtered = await cl.send("search.query", { q: "borrow", filters: { land: "go" } });
    assertEq(filtered.type, "search.query.ok");
    assert(filtered.payload.hits.every((h) => h.land === "go"), "a land filter is honoured");
    const nothing = await cl.send("search.query", { q: "   " });
    assertEq(nothing.type, "search.query.ok");
    assertEq(nothing.payload.hits.length, 0, "an empty box returns nothing, not everything");
    const punct = await cl.send("search.query", { q: "Box<dyn Error>" });
    assertEq(punct.type, "search.query.ok", "punctuation is a search, not a syntax error");
    const badMode = await cl.send("search.query", { q: "borrow", mode: "psychic" });
    assertEq(badMode.payload.code, "bad_request", "an unknown mode is refused");

    // §4.16: the drills answer for real. A fresh account has no mistakes, so
    // every plan is legitimately empty — `.ok` with `plan: []`, never an
    // error — and the ids and codes around it are what the section says.
    for (const mode of ["repeat", "weakness", "spaced"]) {
      const r = await cl.send("ai.plan", { mode });
      assertEq(r.type, "ai.plan.ok", `ai.plan ${mode}`);
      assert(r.payload.drill?.id?.startsWith("drl_"), `ai.plan ${mode}: a drl_ id`);
      assertEq(r.payload.drill.mode, mode);
      assertEq(r.payload.drill.cursor, 0, "§4.16: cursor is 0-based");
      assert(Array.isArray(r.payload.drill.plan), `ai.plan ${mode}: plan is an array`);
    }
    const empty = await cl.send("ai.plan", { mode: "repeat" });
    const drillId = empty.payload.drill.id;
    if (empty.payload.drill.plan.length === 0) {
      const past = await cl.send("ai.next", { drill_id: drillId });
      assertEq(past.payload.code, "not_found", "§4.16: ai.next past the end is not_found");
    }
    const fin = await cl.send("ai.finish", { drill_id: drillId });
    assertEq(fin.type, "ai.finish.ok");
    assert(typeof fin.payload.summary?.attempted === "number", "summary.attempted");
    const badMode2 = await cl.send("ai.plan", { mode: "psychic" });
    assertEq(badMode2.payload.code, "bad_request", "an unknown drill mode is refused");
    const noDrill = await cl.send("ai.next", { drill_id: "drl_0000000000000000" });
    assertEq(noDrill.payload.code, "not_found", "a drill that does not exist is not_found");

    // Go used to be the other declared gap. It is not any more — BE built
    // the runner — so the assertion that used to live here ("a Go submission
    // is refused") has done its job and is replaced by the real one: Go is
    // judged, like Rust, and a wrong Go answer produces a *Go* mistake kind.
    //
    // The rule underneath is unchanged and is the one worth protecting:
    // nothing untrue may enter the curriculum. A verdict the server invented
    // flows into `mistakes`, then `mistake_stats`, then the drills, and the
    // player is taught to fix something they never did (SPEC §7).
    const goMap = await cl.send("world.map", { land: "go", category: "basic" });
    const goNode = goMap.payload.nodes?.find((n) => n.state === "open");
    assert(
      goNode,
      "the go/basic map has no open node — Go content is missing, since §4.7 " +
        "says every node is playable",
    );

    const before = (await cl.send("stats.history", { quest_id: goNode.quest_id })).payload
      .attempts.length;
    const r = await cl.send("quest.submit", {
      quest_id: goNode.quest_id,
      lang: "go",
      source:
        'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("not the answer") }\n',
    });
    assertEq(r.type, "quest.submit.ok", "a Go submission must now be judged");
    const attempt = r.payload.attempt;
    assert(
      [
        "accepted",
        "wrong_answer",
        "compile_error",
        "runtime_error",
        "timeout",
        "output_limit",
      ].includes(attempt.verdict),
      `§5.4: verdict ${attempt.verdict} is outside the set`,
    );
    assert(
      attempt.verdict !== "internal_error",
      "a Go submission came back `internal_error`, which tells the player " +
        "their machine is broken. If Go cannot be judged, the answer is " +
        "`unavailable` with detail.milestone, before an attempt is written.",
    );

    // It really ran: the attempt is on record (PROTOCOL.md §4.9, "always
    // recorded"), and a wrong answer left a classified mistake behind.
    const after = (await cl.send("stats.history", { quest_id: goNode.quest_id })).payload
      .attempts;
    assertEq(after.length, before + 1, "the Go attempt was not recorded");
    assertEq(after[0].id, attempt.id, "the recorded attempt is the one that ran");

    if (attempt.verdict !== "accepted") {
      assert(
        Array.isArray(attempt.mistakes) && attempt.mistakes.length > 0,
        "a failed Go submission produced no classified mistake, so it teaches " +
          "nothing (SPEC §7.1)",
      );
      for (const m of attempt.mistakes) {
        assert(typeof m.kind === "string" && m.kind, "a mistake with no kind");
        // Go has no error codes, so §7.1's identity is the normalised
        // message. A `code` that still carries the player's own identifier
        // would make `undefined: tolal` and `undefined: subtotal` two
        // different mistakes, and the rollup would never reach five.
        if (typeof m.code === "string" && m.code.startsWith("go:"))
          assert(
            m.code === m.code.toLowerCase() && !/\s/.test(m.code),
            `a Go mistake code should be a normalised slug, got ${m.code}`,
          );
      }
    }

    // A compile error in Go classifies the way the fixtures say it should.
    const broken = await cl.send("quest.submit", {
      quest_id: goNode.quest_id,
      lang: "go",
      source: 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println(tolal) }\n',
    });
    assertEq(broken.type, "quest.submit.ok", "a Go compile error is still judged");
    assertEq(broken.payload.attempt.verdict, "compile_error", "an undefined name");
    const kinds = broken.payload.attempt.mistakes.map((m) => m.kind);
    assert(
      kinds.includes("unknown-name"),
      `§7.1: \`undefined: tolal\` is the unknown-name row, got ${JSON.stringify(kinds)}`,
    );
    const codes = broken.payload.attempt.mistakes.map((m) => m.code).filter(Boolean);
    assert(
      !codes.some((c) => String(c).includes("tolal")),
      `a mistake code carries the player's own identifier (${JSON.stringify(codes)}), ` +
        "so two spellings of one lesson are two rows and the §7.2 rollup " +
        "never learns anything",
    );

    // The wrong `lang` for a quest is still a `bad_request`, not a judgement.
    assertErr(
      await cl.send("quest.submit", {
        quest_id: goNode.quest_id,
        lang: "rust",
        source: 'fn main() { println!("x"); }',
      }),
      "bad_request",
      "§4.9: lang disagreeing with the quest's land",
    );
  } finally {
    cl.close();
  }
});

check(null, "beyond: a run is for the player, a submit is for the record", async () => {
  // PROTOCOL.md §4.9b. The invariant here is **asymmetric**, and it is easy
  // to get backwards in either direction:
  //
  //   a run does NOT count toward the node's `attempts` or the accuracy,
  //   a run DOES put its mistakes into the curriculum.
  //
  // A query that forgets `mode` overstates how much the player is failing —
  // iterating honestly starts to look like flailing, and the stars go with
  // it. A query that filters runs out of `mistakes` understates what they are
  // actually struggling with, and SPEC §7 builds the drills from that table,
  // so the AI mode would train on the tidied-up version of their week.
  //
  // So: many runs, one submit, and count both sides.
  const cl = await session(freshAccount("runmode"), "run");
  try {
    const { node, quest } = await firstOpenQuest(cl);
    const right = rightSourceFor(quest);
    const body = { quest_id: node.quest_id, lang: "rust" };

    const before = await cl.send("stats.summary", {});
    const beforeMistakes = (await cl.send("stats.mistakes", { limit: 50 })).payload
      .mistakes.reduce((s, m) => s + m.count, 0);

    // Five runs that fail the way a player iterating fails: a compile error,
    // then wrong output. Five rather than twenty because each one is a real
    // `rustc`, and the invariant does not get truer at twenty.
    const RUNS = 5;
    for (let i = 0; i < RUNS; i++) {
      const r = await cl.send("quest.run", {
        ...body,
        source:
          i % 2 === 0
            ? "fn main() { let x: i32 = \"nope\"; }"
            : `fn main() { println!("iteration {i}"); }`,
      });
      assertEq(r.type, "quest.run.ok", `run ${i}`);
      const a = r.payload.attempt;
      assertEq(a.mode, "run", "§5.4: an Attempt from quest.run carries mode: run");
      assertEq(a.cleared, false, "§4.9b: a run never clears a node");
      assertEq(a.stars, 0, "§4.9b: a run never awards stars");
      // §4.9b: only the visible cases run, and a run must not leak whether
      // the hidden ones pass — not in `cases`, and not in the counts.
      const visible = quest.tests.visible.length;
      assertEq(
        a.tests_total,
        visible,
        `§4.9b: a run counts the ${visible} visible case(s), not the hidden ones`,
      );
      assert(
        a.cases.every((c) => c.visible),
        "§4.9b: a run reported a hidden case, which is what submitting is for",
      );
      assert(
        a.tests_passed <= visible,
        "a run passed more cases than it ran",
      );
    }

    // No progress.update followed any of them.
    assertEq(
      cl.events.filter((e) => e.type === "progress.update").length,
      0,
      "§4.9b: a run must not announce progress",
    );

    // The node has seen no attempts at all yet.
    const midway = (await cl.send("world.map", { land: "rust", category: "basic" })).payload
      .nodes.find((n) => n.quest_id === node.quest_id);
    assertEq(
      midway.attempts,
      0,
      `§4.9b: ${RUNS} runs counted toward the node's \`attempts\`; iterating ` +
        "honestly must not look like failing repeatedly",
    );
    assertEq(midway.state, "open", "a run cleared the node");

    // ...but the curriculum has them. This is the half that quietly rots:
    // nothing else in the suite would notice if runs stopped being recorded.
    const afterRunsMistakes = (await cl.send("stats.mistakes", { limit: 50 })).payload
      .mistakes.reduce((s, m) => s + m.count, 0);
    assert(
      afterRunsMistakes > beforeMistakes,
      "§4.9b: the mistakes a player made while iterating never reached the " +
        "curriculum. SPEC §7 builds the drills from that table, so the AI " +
        "mode would be training on the tidied-up version of their week.",
    );
    const runHistory = (await cl.send("stats.history", { quest_id: node.quest_id }))
      .payload.attempts;
    assertEq(runHistory.length, RUNS, "§4.9b: a run is still recorded");

    // Now one submit, and the node's counter moves by exactly one.
    const done = await cl.send("quest.submit", { ...body, source: right ?? WRONG_SOURCE });
    assertEq(done.type, "quest.submit.ok", "the submit");
    assertEq(done.payload.attempt.mode, "submit", "§5.4: mode on a submit");

    const after = (await cl.send("world.map", { land: "rust", category: "basic" })).payload
      .nodes.find((n) => n.quest_id === node.quest_id);
    assertEq(
      after.attempts,
      1,
      `§4.9b: ${RUNS} runs then one submit must leave the node at 1 attempt, ` +
        `got ${after.attempts}`,
    );

    // And the accuracy is computed over submits only. With one submit, it is
    // either 0 or 1 — anything between means the runs were counted.
    const summary = (await cl.send("stats.summary", {})).payload;
    assert(
      summary.accuracy === 0 || summary.accuracy === 1,
      `§4.9b: accuracy is ${summary.accuracy} after exactly one submit, so ` +
        "the runs are in the denominator",
    );
    assertEq(
      summary.attempts - before.payload.attempts,
      1,
      "§4.9b: stats.summary counted the runs as attempts",
    );

    // If the submit was right, the stars are the clean-clear grade — the runs
    // did not spend them.
    if (done.payload.attempt.verdict === "accepted") {
      assertEq(
        done.payload.attempt.stars,
        3,
        `§6.3 + §4.9b: ${RUNS} runs before a first-time clear cost a star; ` +
          "a run is not a failed attempt",
      );
    }
  } finally {
    cl.close();
  }
});

check(null, "beyond: an address in a payload is ignored, never trusted", async () => {
  // SPEC §3.5. The server filters by the connection's session; an address in
  // the payload is ignored, not honoured. This catches a server that
  // helpfully obeys it — which reads as a feature until it is a data leak.
  const alice = freshAccount("alice");
  const b = await session(freshAccount("bob"), "spoof");
  try {
    const spoofed = await b.send("stats.summary", { address: alice.address });
    const own = await b.send("stats.summary", {});
    assert(
      spoofed.type === "stats.summary.ok" || spoofed.payload.code === "bad_request",
      `a spoofed address gave ${spoofed.type} ${spoofed.payload.code ?? ""}`,
    );
    if (spoofed.type === "stats.summary.ok")
      assertEq(spoofed.payload, own.payload, "§3.5: a payload address changed the answer");

    const hist = await b.send("stats.history", { limit: 5, address: alice.address });
    const ownHist = await b.send("stats.history", { limit: 5 });
    if (hist.type === "stats.history.ok")
      assertEq(
        hist.payload.attempts.map((x) => x.id),
        ownHist.payload.attempts.map((x) => x.id),
        "§3.5: a payload address changed stats.history",
      );
  } finally {
    b.close();
  }
});

check(null, "beyond: a scratchpad's chatroom keeps, serves and searches (§4.9f)", async () => {
  // The chatroom under a pad: the four messages and the photo route, driven
  // the way the Rust coder drives them. A server without §4.9f answers
  // `not_found` to the first call, and that is reported as one line rather
  // than four failures.
  const cl = await session(freshAccount("room"), "room");
  try {
    const pad = await cl.send("playground.save", {
      lang: "rust",
      source: "fn main() {}\n",
      name: "smoke room",
    });
    assertEq(pad.type, "playground.save.ok", "a pad to hang the room on");
    const id = pad.payload.snippet.id;
    const first = await cl.send("playground.chat.post", { id, role: "user", text: "hello room" });
    if (first.type.endsWith(".err") && first.payload.code === "not_found") {
      throw new Error("playground.chat.* is not on this server (PROTOCOL §4.9f)");
    }
    assertEq(first.type, "playground.chat.post.ok", "a text post");
    const m = first.payload.message;
    assertEq(m.snippet_id, id, "a message names its pad");
    assertEq(m.role, "user");
    assertEq(m.kind, "text");
    assertEq(m.photo_url, null, "a text row has no photo");
    for (const key of ["id", "timeid", "text", "created_at", "provider", "model"])
      assert(key in m, `ChatMessage.${key} (§5.14)`);
    assert(Number.isInteger(m.id) && m.id > 0, "id is an int64");
    assert(Number.isInteger(m.timeid) && m.timeid > 1_600_000_000_000, "timeid is ms since the epoch");

    // A 1x1 PNG, as base64: a real picture, posted as the agent would.
    const png =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==";
    const photo = await cl.send("playground.chat.post", {
      id,
      role: "agent",
      text: "a crab",
      image_b64: png,
      image_type: "image/png",
      provider: "openai",
      model: "gpt-image-1",
    });
    assertEq(photo.type, "playground.chat.post.ok", "an image post");
    const url = photo.payload.message.photo_url;
    assert(
      typeof url === "string" && /^\/photos\/[0-9]+\/[0-9a-f]{32}\.png$/.test(url),
      `a photo is fetched by capability path, got ${url}`,
    );
    const http = new URL(URL_WS.replace(/^ws/, "http"));
    const res = await fetch(new URL(url, http));
    assertEq(res.status, 200, "the photo route serves the owner's token");
    assertEq(res.headers.get("content-type"), "image/png");
    const bytes = new Uint8Array(await res.arrayBuffer());
    assertEq(bytes.length, Buffer.from(png, "base64").length, "the bytes as posted");
    const wrong = await fetch(new URL(url.replace(/[0-9a-f]{32}\.png$/, "0".repeat(32) + ".png"), http));
    assertEq(wrong.status, 404, "a wrong token is nothing");

    const list = await cl.send("playground.chat.list", { id });
    assertEq(list.type, "playground.chat.list.ok");
    assertEq(list.payload.messages.length, 2, "oldest first, both there");
    assertEq(list.payload.messages[0].text, "hello room");

    const hits = await cl.send("playground.chat.search", { q: "hello", id });
    assertEq(hits.type, "playground.chat.search.ok");
    assertEq(hits.payload.mode, "unified", "the default mode");
    assert(hits.payload.hits.length >= 1, "the word is found");
    assertEq(hits.payload.hits[0].message.text, "hello room");
    assertEq(hits.payload.hits[0].snippet_name, "smoke room");

    // A messenger's two verbs, delivered through the same cursor as changes
    // to the same id: the edit keeps the row, the delete leaves a tombstone.
    const cursor = list.payload.messages[1].timeid;
    const edited = await cl.send("playground.chat.edit", { message_id: m.id, text: "hello room, edited" });
    assertEq(edited.type, "playground.chat.edit.ok");
    assertEq(edited.payload.message.id, m.id, "an edit keeps the id");
    assert(edited.payload.message.timeid > cursor, "and takes a later timeid");
    assertEq(edited.payload.message.edited, true);
    const gone = await cl.send("playground.chat.delete", { message_id: photo.payload.message.id });
    assertEq(gone.type, "playground.chat.delete.ok");
    assertEq(gone.payload.message.deleted, true, "a delete is a tombstone");
    assertEq(gone.payload.message.photo_url, null, "with no photo");
    const sync = await cl.send("playground.chat.sync", { after: cursor });
    assertEq(sync.type, "playground.chat.sync.ok");
    assertEq(
      sync.payload.messages.map((x) => [x.id, x.edited, x.deleted]),
      [[m.id, true, false], [photo.payload.message.id, false, true]],
      "a cursor past the originals receives both changes, in order",
    );
    assertEq(sync.payload.head, gone.payload.message.timeid, "head is the newest timeid");
    assertEq(sync.payload.more, false);
    const fresh = await cl.send("playground.chat.list", { id });
    assertEq(fresh.payload.messages.length, 1, "a room read from the start hides the tombstone");
    assertEq(fresh.payload.messages[0].text, "hello room, edited");
    const cleared = await cl.send("playground.chat.clear", { id });
    assertEq(cleared.type, "playground.chat.clear.ok");
    assertEq(cleared.payload.cleared, 2, "clear says how many went — the tombstone counts");
    const afterClear = await fetch(new URL(url, http));
    assertEq(afterClear.status, 404, "a cleared photo is gone from the web too");
    await cl.send("playground.delete", { id });
  } finally {
    cl.close();
  }
});

check(null, "beyond: no frame the server sent broke the envelope rules", async () => {
  // Every Client validates as it goes; this rolls the whole run up, so a
  // violation in the middle of an otherwise-passing check is still reported.
  // It runs last, deliberately.
  assert(
    allViolations.length === 0,
    `${allViolations.length} envelope violation(s):\n    ` +
      allViolations
        .slice(0, 12)
        .map((v) => `${v.why}\n      ${JSON.stringify(v.frame).slice(0, 200)}`)
        .join("\n    "),
  );
});

// --------------------------------------------------------------------- run

async function main() {
  const selected = ONLY
    ? checks.filter((c) => (c.point ?? "").includes(ONLY) || c.name.includes(ONLY))
    : checks;
  if (selected.length === 0) {
    console.error(`no check matches --only ${ONLY}`);
    return 2;
  }

  const results = [];
  let hardStop = null;

  for (const { point, name, fn } of selected) {
    const label = point ? `${`§${point}`.padEnd(6)}${name}` : `      ${name}`;
    if (hardStop) {
      results.push({ point, name, status: "skipped", detail: hardStop });
      continue;
    }
    const t0 = Date.now();
    try {
      await fn();
      results.push({ point, name, status: "pass", ms: Date.now() - t0 });
      if (!AS_JSON)
        console.log(`${green("pass")}  ${label} ${dim(`${Date.now() - t0}ms`)}`);
    } catch (err) {
      const detail = err instanceof Error ? err.message : String(err);
      if (err instanceof SkipError) {
        hardStop = detail; // every later check would say the same thing
        results.push({ point, name, status: "skipped", detail });
        if (!AS_JSON) console.log(`${yellow("skip")}  ${label}\n      ${detail}`);
        continue;
      }
      results.push({ point, name, status: "fail", detail, ms: Date.now() - t0 });
      if (!AS_JSON) console.log(`${red("FAIL")}  ${label}\n      ${detail}`);
    }
  }

  const by = (s) => results.filter((r) => r.status === s);
  const conformance = results.filter((r) => r.point);
  const passed = conformance.filter((r) => r.status === "pass");

  if (AS_JSON) {
    console.log(
      JSON.stringify(
        {
          url: URL_WS,
          protocol_8: {
            passed: passed.map((r) => r.point),
            failed: conformance.filter((r) => r.status === "fail").map((r) => r.point),
            skipped: conformance.filter((r) => r.status === "skipped").map((r) => r.point),
          },
          pass: by("pass").length,
          fail: by("fail").length,
          skip: by("skipped").length,
          results,
        },
        null,
        2,
      ),
    );
  } else {
    const score = `${passed.length}/${conformance.length}`;
    console.log(
      `\nPROTOCOL.md §8 conformance: ` +
        (passed.length === conformance.length ? green(score) : red(score)) +
        (conformance.length < 12 && !ONLY ? red("  (fewer than 12 points ran)") : ""),
    );
    console.log(
      `${by("pass").length} passed, ` +
        (by("fail").length > 0 ? red(`${by("fail").length} failed`) : "0 failed") +
        `, ${by("skipped").length} skipped  ${dim(URL_WS)}`,
    );
  }

  if (by("fail").length > 0) return 1;
  if (by("pass").length === 0) return 2; // a green with no checks is a lie
  return 0;
}

main().then(
  (code) => process.exit(code),
  (err) => {
    console.error(red("the checker itself fell over:"), err);
    process.exit(2);
  },
);
