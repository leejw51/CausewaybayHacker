#!/usr/bin/env node
/**
 * A deliberately minimal SPEC §6 server, for testing the *checker*.
 *
 * This is not a second implementation of the game and must never become one.
 * It exists so `selftest.mjs` can answer the only question that matters about
 * a test tool: **does it actually catch anything?** A contract checker that
 * has only ever run against a dead port is a file, not a test.
 *
 * It implements enough of the catalogue to satisfy `contract.mjs` when
 * correct, and takes a `--break <fault>` flag that makes it wrong in one
 * specific, realistic way. The checker is then required to notice.
 *
 *     node mock-server.mjs --port 5399
 *     node mock-server.mjs --port 5399 --break correlation
 *
 * Faults, each one a bug somebody actually ships:
 *   correlation      replies in arrival order with a fresh id
 *   error-code       invents `not_authorized`, outside §6.1's closed set
 *   version-kills    closes the socket on an unknown `v`
 *   anon-leak        serves world.lands before login
 *   nonce-reuse      accepts the same nonce twice
 *   solution-leak    sends `solution` on quest.get
 *   trust-payload    filters stats by an address in the payload
 *   cross-user       shows every user's attempts to everyone
 *   no-busy          queues a second submit instead of refusing it
 *   event-id         gives run.stage a correlation id
 *   trailing-newline ends the challenge message with a newline
 */

import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "ws";

const args = process.argv.slice(2);
const flag = (n, d) => {
  const i = args.indexOf(`--${n}`);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : d;
};
const PORT = Number(flag("port", "5399"));
const BREAK = flag("break", null);

// ------------------------------------------------------------------- state

const QUESTS = [
  {
    quest_id: "rust.basic.01.hello",
    node: 1,
    title: "FIRST LIGHT",
    difficulty: 1,
    kind: "quest",
    x: 0.12,
    y: 0.74,
    requires: [],
    starter: "fn main() {\n    // your code here\n}\n",
    solution: 'fn main() {\n    println!("hello, causewaybay");\n}\n',
    expect: "hello, causewaybay\n",
  },
  {
    quest_id: "rust.basic.02.shadowing",
    node: 2,
    title: "SECOND STREET",
    difficulty: 2,
    kind: "quest",
    x: 0.3,
    y: 0.6,
    requires: ["rust.basic.01.hello"],
    starter: "fn main() {}\n",
    solution: 'fn main() { println!("shadow"); }\n',
    expect: "shadow\n",
  },
  {
    quest_id: "rust.basic.03.borrow",
    node: 3,
    title: "THIRD STREET",
    difficulty: 3,
    kind: "boss",
    x: 0.55,
    y: 0.4,
    requires: ["rust.basic.02.shadowing"],
    starter: "fn main() {}\n",
    solution: 'fn main() { println!("borrow"); }\n',
    expect: "borrow\n",
  },
];

const users = new Map(); // lower address -> { address, address_eip55, name }
const progress = new Map(); // `${addr}|${quest}` -> { state, stars }
const attempts = new Map(); // addr -> [attempt]
const mistakes = new Map(); // addr -> [{kind, code, message}]
const nonces = new Map(); // nonce -> { address, expires_at, used }
const tokens = new Map(); // sha256(token) -> lower address

const now = () => new Date().toISOString().replace(/\.\d+Z$/, "Z");
const sha = (s) => createHash("sha256").update(s).digest("hex");

function nodeState(addr, q) {
  const key = `${addr}|${q.quest_id}`;
  if (progress.get(key)?.state === "cleared") return "cleared";
  if (q.requires.every((r) => progress.get(`${addr}|${r}`)?.state === "cleared"))
    return "open";
  return "locked";
}

// --------------------------------------------------------------- the server

const http = createServer((_req, res) => {
  res.writeHead(200, { "content-type": "text/plain" });
  res.end("causewaybay-hacker mock\n");
});
const wss = new WebSocketServer({ server: http, path: "/ws" });

wss.on("connection", (ws) => {
  const session = { address: null, inFlight: false, queue: [] };

  const emit = (type, payload) =>
    ws.send(
      JSON.stringify({
        v: 1,
        id: BREAK === "event-id" ? "s-1" : null,
        type,
        payload,
      }),
    );
  const reply = (id, type, payload) =>
    ws.send(
      JSON.stringify({
        v: 1,
        id: BREAK === "correlation" ? `s-${Math.random().toString(36).slice(2, 8)}` : id,
        type,
        payload,
      }),
    );
  const err = (id, type, code, message, detail = {}) =>
    reply(id, `${type}.err`, {
      code: BREAK === "error-code" && code === "unauthorized" ? "not_authorized" : code,
      message,
      detail,
    });

  ws.on("message", async (raw) => {
    let f;
    try {
      f = JSON.parse(String(raw));
    } catch {
      return err(null, "frame", "bad_request", "not JSON");
    }
    const { id = null, type, payload } = f ?? {};
    if (typeof type !== "string") return err(id, "frame", "bad_request", "no type");

    if (f.v !== 1) {
      err(id, type, "proto_version", `unsupported protocol version ${f.v}`);
      if (BREAK === "version-kills") ws.close(1002, "bad version");
      return;
    }
    if (typeof payload !== "object" || payload === null || Array.isArray(payload))
      return err(id, type, "bad_request", "payload must be an object");

    // SPEC §6.4 reads "Anything else before that is `unauthorized`, except
    // `ping` and `auth.challenge`" — which, taken literally, would make
    // `auth.login` itself unauthorized and nobody could ever log in. The
    // sentence before it names login and resume as the things that end the
    // anonymous state, so all four are anonymous-reachable. Raised in
    // docs/decisions.md.
    const anonymousOk =
      type === "ping" ||
      type === "auth.challenge" ||
      type === "auth.login" ||
      type === "auth.resume";
    const leaky = BREAK === "anon-leak" && type === "world.lands";
    if (!session.address && !anonymousOk && !leaky)
      return err(id, type, "unauthorized", "log in first");

    switch (type) {
      case "ping":
        return reply(id, "ping.ok", { t: now() });

      case "auth.challenge": {
        const claimed = String(payload.address ?? "");
        if (!/^0x[0-9a-fA-F]{40}$/.test(claimed))
          return err(id, type, "bad_request", "not an address");
        let eip55;
        try {
          eip55 = toEip55(claimed);
        } catch {
          return err(id, type, "bad_request", "unknown address (mock has no keccak)");
        }
        const nonce = randomBytes(32).toString("hex");
        const expires_at = new Date(Date.now() + 120_000)
          .toISOString()
          .replace(/\.\d+Z$/, "Z");
        const message =
          `Causewaybay Hacker login\n` +
          `address: ${eip55}\n` +
          `nonce: ${nonce}\n` +
          `expires: ${expires_at}` +
          (BREAK === "trailing-newline" ? "\n" : "");
        nonces.set(nonce, {
          address: eip55.toLowerCase(),
          expires_at,
          message,
          used: false,
        });
        return reply(id, "auth.challenge.ok", { nonce, message, expires_at });
      }

      case "auth.login": {
        const sig = String(payload.signature ?? "");
        const claimed = String(payload.address ?? "").toLowerCase();
        const live = [...nonces.entries()].filter(
          ([, n]) => n.address === claimed && Date.parse(n.expires_at) > Date.now(),
        );
        if (!/^0x[0-9a-f]{130}$/i.test(sig))
          return err(id, type, "auth_bad_signature", "not 65 bytes of hex");
        if (live.length === 0) return err(id, type, "auth_expired", "no live nonce");
        const [nonce, rec] = live[live.length - 1];
        // SPEC §3.2 step 4, in order: recover, compare, check the nonce, burn
        // it. A bad signature must not consume anyone's challenge.
        const who = recover(rec.message, sig);
        if (!who || who !== claimed)
          return err(id, type, "auth_bad_signature", "recovered a different address");
        if (rec.used && BREAK !== "nonce-reuse")
          return err(id, type, "auth_nonce_used", "that nonce is spent");
        rec.used = true;
        nonces.set(nonce, rec);

        const eip55 = toEip55(claimed);
        const user = users.get(claimed) ?? {
          address: claimed,
          address_eip55: eip55,
          name: "hacker",
          created_at: now(),
        };
        users.set(claimed, user);
        session.address = claimed;
        const token = randomBytes(32).toString("base64url");
        tokens.set(sha(token), claimed);
        return reply(id, "auth.login.ok", { token, user });
      }

      case "auth.resume": {
        const addr = tokens.get(sha(String(payload.token ?? "")));
        if (!addr) return err(id, type, "unauthorized", "unknown token");
        session.address = addr;
        const token = randomBytes(32).toString("base64url");
        tokens.set(sha(token), addr);
        return reply(id, "auth.resume.ok", { token, user: users.get(addr) });
      }

      case "world.lands": {
        const addr = session.address ?? "0x";
        const cleared = QUESTS.filter(
          (q) => progress.get(`${addr}|${q.quest_id}`)?.state === "cleared",
        ).length;
        return reply(id, "world.lands.ok", {
          lands: [
            {
              land: "rust",
              categories: [
                { category: "basic", total: QUESTS.length, cleared },
                { category: "advanced", total: 0, cleared: 0 },
                { category: "hacker", total: 0, cleared: 0 },
              ],
            },
            {
              land: "go",
              categories: [
                { category: "basic", total: 0, cleared: 0 },
                { category: "advanced", total: 0, cleared: 0 },
                { category: "hacker", total: 0, cleared: 0 },
              ],
            },
          ],
        });
      }

      case "world.map": {
        if (payload.land !== "rust" || payload.category !== "basic")
          return reply(id, "world.map.ok", { nodes: [], edges: [] });
        const addr = session.address;
        return reply(id, "world.map.ok", {
          nodes: QUESTS.map((q) => ({
            quest_id: q.quest_id,
            node: q.node,
            title: q.title,
            difficulty: q.difficulty,
            state: nodeState(addr, q),
            stars: progress.get(`${addr}|${q.quest_id}`)?.stars ?? 0,
            x: q.x,
            y: q.y,
            kind: q.kind,
          })),
          edges: QUESTS.flatMap((q) => q.requires.map((r) => [r, q.quest_id])),
        });
      }

      case "quest.get": {
        const q = QUESTS.find((x) => x.quest_id === payload.quest_id);
        if (!q) return err(id, type, "not_found", "no such quest");
        const cleared =
          progress.get(`${session.address}|${q.quest_id}`)?.state === "cleared";
        const quest = {
          quest_id: q.quest_id,
          node: q.node,
          title: q.title,
          brief: "Print `hello, causewaybay` and nothing else.",
          story: "The terminal blinks.",
          difficulty: q.difficulty,
          starter: q.starter,
          hints: ["`println!` is a macro."],
          concepts: ["io", "macros"],
          cases: [{ name: "greets", stdin: "", expect: q.expect, visible: true }],
        };
        if (cleared || BREAK === "solution-leak") quest.solution = q.solution;
        return reply(id, "quest.get.ok", { quest });
      }

      case "quest.submit": {
        if (session.inFlight && BREAK !== "no-busy")
          return err(id, type, "busy", "one submit at a time");
        session.inFlight = true;
        const q = QUESTS.find((x) => x.quest_id === payload.quest_id);
        if (!q) {
          session.inFlight = false;
          return err(id, type, "not_found", "no such quest");
        }
        const addr = session.address;
        const attemptId = "att_" + randomBytes(8).toString("hex");
        for (const stage of ["queued", "compiling", "running", "judging"]) {
          emit("run.stage", { attempt_id: attemptId, stage });
          await sleep(25);
        }
        emit("run.log", {
          attempt_id: attemptId,
          stream: "compile",
          chunk: "Compiling main.rs\n",
        });
        // "Judging": does the source print what the case expects?
        const printed = /println!\("([^"]*)"\)/.exec(String(payload.source ?? ""))?.[1];
        const ok = printed !== undefined && printed + "\n" === q.expect;
        const prev = progress.get(`${addr}|${q.quest_id}`);
        const attempt = {
          id: attemptId,
          verdict: ok ? "accepted" : "wrong_answer",
          tests_passed: ok ? 1 : 0,
          tests_total: 1,
          compile_ms: 120,
          run_ms: 3,
          stderr: "",
          cases: [
            {
              name: "greets",
              passed: ok,
              visible: true,
              stdin: "",
              expect: q.expect,
              got: printed === undefined ? "" : printed + "\n",
            },
          ],
          mistakes: ok ? [] : [{ kind: "wrong-answer", code: null, message: "output differs", line: null }],
          stars: ok ? (prev ? 2 : 3) : 0,
          cleared: ok,
        };
        (attempts.get(addr) ?? attempts.set(addr, []).get(addr)).push(attempt);
        if (!ok)
          (mistakes.get(addr) ?? mistakes.set(addr, []).get(addr)).push({
            kind: "wrong-answer",
            code: null,
            message: "output differs",
          });
        if (ok) {
          progress.set(`${addr}|${q.quest_id}`, {
            state: "cleared",
            stars: attempt.stars,
          });
          emit("progress.update", {
            quest_id: q.quest_id,
            state: "cleared",
            stars: attempt.stars,
            cleared_total: QUESTS.filter(
              (x) => progress.get(`${addr}|${x.quest_id}`)?.state === "cleared",
            ).length,
          });
        } else {
          progress.set(`${addr}|${q.quest_id}`, {
            state: "open",
            stars: prev?.stars ?? 0,
          });
        }
        session.inFlight = false;
        return reply(id, "quest.submit.ok", { attempt });
      }

      case "stats.history": {
        const who =
          BREAK === "trust-payload" && payload.address
            ? String(payload.address).toLowerCase()
            : session.address;
        const rows = BREAK === "cross-user" ? [...attempts.values()].flat() : attempts.get(who) ?? [];
        return reply(id, "stats.history.ok", {
          attempts: rows.slice(-Number(payload.limit ?? 20)).map((a) => ({
            id: a.id,
            verdict: a.verdict,
            tests_passed: a.tests_passed,
            tests_total: a.tests_total,
            created_at: now(),
          })),
        });
      }

      case "stats.mistakes": {
        const who =
          BREAK === "trust-payload" && payload.address
            ? String(payload.address).toLowerCase()
            : session.address;
        const rows = mistakes.get(who) ?? [];
        const byKind = new Map();
        for (const m of rows)
          byKind.set(m.kind, (byKind.get(m.kind) ?? 0) + 1);
        return reply(id, "stats.mistakes.ok", {
          mistakes: [...byKind].map(([kind, count]) => ({
            kind,
            label: kind,
            count,
            last_at: now(),
            cleared_since: 0,
            example_quest_id: null,
          })),
        });
      }

      case "stats.summary": {
        const who =
          BREAK === "trust-payload" && payload.address
            ? String(payload.address).toLowerCase()
            : session.address;
        const rows = attempts.get(who) ?? [];
        const cleared = QUESTS.filter(
          (q) => progress.get(`${who}|${q.quest_id}`)?.state === "cleared",
        ).length;
        return reply(id, "stats.summary.ok", {
          cleared,
          attempts: rows.length,
          accuracy: rows.length ? rows.filter((a) => a.cleared).length / rows.length : 0,
          streak: 0,
          by_land: { rust: cleared, go: 0 },
        });
      }

      default:
        return err(id, type, "bad_request", `unknown type ${type}`);
    }
  });
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * EIP-55 and signature recovery, both borrowed rather than implemented.
 *
 * The mock has no business owning a keccak or a secp256k1 — a second, subtly
 * different implementation living in the test tree is exactly the drift SPEC
 * §9.1 exists to prevent. The checksummed spellings come out of
 * `tests/vectors/addresses.json`, and recovery is `cwbwallet verify`, the
 * same binary that generated the fixture.
 */
const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const WALLET =
  process.env.CWBWALLET ?? `${ROOT}/../CausewaybayWallet/rustcli/target/debug/cwbwallet`;

const EIP55 = new Map();
try {
  const doc = JSON.parse(readFileSync(`${ROOT}/tests/vectors/addresses.json`, "utf8"));
  for (const m of doc.mnemonics)
    for (const a of m.accounts) EIP55.set(a.address_lower, a.address);
} catch {
  console.error("mock: could not read tests/vectors/addresses.json");
}

function toEip55(address) {
  const lower = address.toLowerCase();
  const known = EIP55.get(lower);
  if (known) return known;
  // Not a fixture address. The mock has no keccak, so it says so rather than
  // inventing a checksum that would look right and be wrong.
  throw new Error(`mock knows no EIP-55 spelling for ${lower}`);
}

/** Who really signed this? Asked of the wallet, not guessed. */
function recover(message, signature) {
  const out = spawnSync(
    WALLET,
    ["--json", "verify", "--message", message, "--signature", signature],
    { encoding: "utf8" },
  );
  if (out.status !== 0) return null;
  try {
    const env = JSON.parse(out.stdout);
    return env.ok ? String(env.data.recovered).toLowerCase() : null;
  } catch {
    return null;
  }
}

http.listen(PORT, "127.0.0.1", () => {
  console.log(
    `mock §6 server on ws://127.0.0.1:${PORT}/ws` +
      (BREAK ? `  [broken on purpose: ${BREAK}]` : ""),
  );
});
