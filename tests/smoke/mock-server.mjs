#!/usr/bin/env node
/**
 * A deliberately minimal PROTOCOL.md server, for testing the *checker*.
 *
 * This is not a second implementation of the game and must never become one.
 * It exists so `selftest.mjs` can answer the only question that matters about
 * a test tool: **does it actually catch anything?** A contract checker that
 * has only ever run against a dead port is a file, not a test.
 *
 * It implements enough of the protocol to satisfy `contract.mjs` when
 * correct, and takes a `--break <fault>` flag that makes it wrong in one
 * specific, realistic way. The checker is then required to notice, on the
 * §8 point that owns that rule.
 *
 *     node mock-server.mjs --port 5399
 *     node mock-server.mjs --port 5399 --break correlation
 *
 * Faults, each one a bug somebody actually ships:
 *
 *   extra-key-ok     silently ignores an unknown top-level key        §8.1
 *   correlation      replies with a fresh id instead of echoing       §8.2
 *   unknown-closes   closes the connection on an unknown type         §8.3
 *   error-code       invents `not_authorized`, outside the closed set §8.4
 *   no-supported     proto_version without detail.supported           §8.4
 *   nonce-reuse      accepts the same nonce twice                     §8.4
 *   trailing-newline ends the challenge message with a newline        §8.6
 *   accepts-rebuilt  accepts a signature over a reconstruction        §8.6
 *   token-static     rotates the token but keeps the old one alive    §8.7
 *   seq-gap          run.log seq skips a number                       §8.8
 *   seq-from-one     run.log seq starts at 1                          §8.8
 *   event-id         gives a server event a correlation id            §8.8
 *   no-busy          queues a second submit instead of refusing it    §8.10
 *   busy-per-user    refuses the user's *second connection* as busy   §8.10
 *   anon-leak        serves world.lands before login                  beyond
 *   solution-leak    sends `solution` on quest.get                    beyond
 *   trust-payload    filters stats by an address in the payload       beyond
 *   cross-user       shows every user's attempts to everyone          beyond
 *   no-broadcast     never tells a user's other connection            beyond
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
const broke = (f) => BREAK === f;

// ------------------------------------------------------- borrowed, not built

/**
 * EIP-55 spellings and signature recovery both come from elsewhere.
 *
 * The mock has no business owning a keccak or a secp256k1 — a second, subtly
 * different implementation living in the test tree is exactly the drift SPEC
 * §9.1 exists to prevent. Checksummed addresses come out of
 * `tests/vectors/addresses.json`; recovery is `cwbwallet verify`, the same
 * binary that generated the fixture.
 */
const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const WALLET =
  process.env.CWBWALLET ?? `${ROOT}/../CausewaybayWallet/rustcli/target/debug/cwbwallet`;

// Seeded from the fixture so the common addresses need no subprocess, then
// filled in by `cwbwallet utils checksum` for anything else — the checker
// derives a fresh account per run, and those are not in the fixture.
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
  // Borrowed, not computed. A keccak of the mock's own would be the second
  // implementation SPEC §9.1 exists to prevent.
  const out = spawnSync(WALLET, ["--json", "utils", "checksum", lower], {
    encoding: "utf8",
  });
  if (out.status !== 0) throw new Error(`checksum failed for ${lower}`);
  const eip55 = JSON.parse(out.stdout).data.address;
  EIP55.set(lower, eip55);
  return eip55;
}

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

// ------------------------------------------------------------------- content

const QUESTS = [
  {
    id: "rust.basic.01.hello",
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
    hints: ["`println!` is a macro, so it takes a `!`."],
  },
  {
    id: "rust.basic.02.bindings",
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
    hints: [],
  },
  {
    id: "rust.basic.03.borrow",
    node: 3,
    title: "THIRD STREET",
    difficulty: 3,
    kind: "boss",
    x: 0.55,
    y: 0.4,
    requires: ["rust.basic.02.bindings"],
    starter: "fn main() {}\n",
    solution: 'fn main() { println!("borrow"); }\n',
    expect: "borrow\n",
    hints: [],
  },
];

/**
 * One Go quest, because the checker asserts that Go is judged now that BE
 * built the runner (§4.9b, and "what is not built says so, and what is built
 * is judged"). A mock with an empty GO map made that check fail for a reason
 * that was about the mock and not about any server.
 */
const GO_QUESTS = [
  {
    id: "go.basic.01.package-main",
    node: 1,
    title: "FIRST LIGHT",
    difficulty: 1,
    kind: "quest",
    x: 0.12,
    y: 0.74,
    requires: [],
    starter: 'package main\n\nfunc main() {\n}\n',
    solution: 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("hello, causewaybay") }\n',
    expect: "hello, causewaybay\n",
    hints: [],
  },
];

/**
 * One quest each for the four newer lands, for the same reason as the Go one:
 * `world.lands` fabricates six lands and a land with an empty map is a mock
 * bug, not a server one.
 */
const CPP_QUESTS = [
  {
    id: "cpp.basic.01.hello",
    node: 1,
    title: "FIRST LIGHT",
    difficulty: 1,
    kind: "quest",
    x: 0.12,
    y: 0.74,
    requires: [],
    starter: "#include <iostream>\n\nint main() {\n}\n",
    solution: '#include <iostream>\n\nint main() { std::cout << "hello, causewaybay\\n"; }\n',
    expect: "hello, causewaybay\n",
    hints: [],
  },
];
const PYTHON_QUESTS = [
  {
    id: "python.basic.01.hello",
    node: 1,
    title: "FIRST LIGHT",
    difficulty: 1,
    kind: "quest",
    x: 0.12,
    y: 0.74,
    requires: [],
    starter: "def main():\n    pass\n\n\nmain()\n",
    solution: 'print("hello, causewaybay")\n',
    expect: "hello, causewaybay\n",
    hints: [],
  },
];

const PYTORCH_QUESTS = [
  {
    id: "pytorch.basic.01.hello",
    node: 1,
    title: "FIRST LIGHT",
    difficulty: 1,
    kind: "quest",
    x: 0.12,
    y: 0.74,
    requires: [],
    starter: "import torch\n\n\ndef main():\n    pass\n\n\nmain()\n",
    solution: 'import torch\n\nprint("hello, causewaybay")\n',
    expect: "hello, causewaybay\n",
    hints: [],
  },
];

const TYPESCRIPT_QUESTS = [
  {
    id: "typescript.basic.01.hello",
    node: 1,
    title: "FIRST LIGHT",
    difficulty: 1,
    kind: "quest",
    x: 0.12,
    y: 0.74,
    requires: [],
    starter:
      'const input: string = require("fs").readFileSync(0, "utf8");\n\nfunction main(): void {}\n\nmain();\n',
    solution: 'console.log("hello, causewaybay");\n',
    expect: "hello, causewaybay\n",
    hints: [],
  },
];

const LANDS = {
  rust: QUESTS,
  go: GO_QUESTS,
  cpp: CPP_QUESTS,
  python: PYTHON_QUESTS,
  pytorch: PYTORCH_QUESTS,
  typescript: TYPESCRIPT_QUESTS,
};
const questsOf = (land) => LANDS[land] ?? [];
const findQuest = (id) => Object.values(LANDS).flat().find((q) => q.id === id);
// The land is the first segment of the id (SPEC §4.1), never a lookup.
const langOf = (id) => id.split(".", 1)[0];

// --------------------------------------------------------------------- state

const users = new Map(); // lower -> User
const progress = new Map(); // `${lower}|${quest}` -> { state, stars, tries }
const attempts = new Map(); // lower -> [Attempt]
const mistakes = new Map(); // lower -> [{kind, code, message}]
const nonces = new Map(); // nonce -> { address, expires_at, message, used }
const tokens = new Map(); // sha256(token) -> lower
const connections = new Set(); // every live session, for §4.19's broadcast

const now = () => new Date().toISOString().replace(/\.\d+Z$/, "Z");
const sha = (s) => createHash("sha256").update(s).digest("hex");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const push = (map, key, value) => {
  const list = map.get(key) ?? [];
  list.push(value);
  map.set(key, list);
};

// §4.7: every node is playable. `requires` and `edges` stay in the payload as
// the suggested route, and are no longer a gate.
const stateOf = (lower, q) =>
  progress.get(`${lower}|${q.id}`)?.state === "cleared" ? "cleared" : "open";
const clearedCount = (lower) =>
  QUESTS.filter((q) => progress.get(`${lower}|${q.id}`)?.state === "cleared").length;
const starsOf = (lower) =>
  QUESTS.reduce((s, q) => s + (progress.get(`${lower}|${q.id}`)?.stars ?? 0), 0);

// -------------------------------------------------------------------- server

const http = createServer((_req, res) => {
  res.writeHead(200, { "content-type": "text/plain" });
  res.end("causewaybay-hacker mock\n");
});
const wss = new WebSocketServer({ server: http, path: "/ws" });

wss.on("connection", (ws) => {
  const session = { ws, address: null, inFlight: false, ids: new Set() };
  connections.add(session);
  ws.on("close", () => connections.delete(session));

  const frame = (id, type, payload) =>
    ws.send(JSON.stringify({ v: 1, id, type, payload }));
  const reply = (id, type, payload) =>
    frame(broke("correlation") ? `s-${randomBytes(3).toString("hex")}` : id, type, payload);
  const emit = (type, payload) => frame(broke("event-id") ? "s-1" : null, type, payload);
  const err = (id, type, code, message, detail = {}) =>
    reply(id, `${type}.err`, {
      code: broke("error-code") && code === "unauthorized" ? "not_authorized" : code,
      message,
      detail,
    });

  ws.on("message", async (raw) => {
    let f;
    try {
      f = JSON.parse(String(raw));
    } catch {
      // PROTOCOL.md §1.2: a frame that is not a JSON object is a transport
      // error, closed with 1003 — not an application error.
      return ws.close(1003, "not a JSON object");
    }
    if (typeof f !== "object" || f === null || Array.isArray(f))
      return ws.close(1003, "not a JSON object");

    const id = "id" in f ? f.id : null;
    const type = f.type;
    if (typeof type !== "string") return err(id, "frame", "bad_request", "no type");

    // §2: exactly four top-level keys. "The server does not silently ignore
    // fields, because a silently ignored field is how a client ships a bug
    // that looks like it works."
    // §2: "an object with exactly these four keys". An absent `payload` is a
    // three-key frame, so it is not one — the mock is strict, because the
    // point of the mock is to be what the checker asserts against.
    const keys = Object.keys(f).sort().join(",");
    if (keys !== "id,payload,type,v" && !broke("extra-key-ok"))
      return err(id, type, "bad_request", `top-level keys are ${keys}`);

    if (f.v !== 1)
      return err(
        id,
        type,
        "proto_version",
        `unsupported protocol version ${JSON.stringify(f.v)}`,
        broke("no-supported") ? {} : { supported: [1] },
      );

    if (!("payload" in f)) return err(id, type, "bad_request", "payload is absent");
    const payload = f.payload;
    if (typeof payload !== "object" || payload === null || Array.isArray(payload))
      return err(id, type, "bad_request", "payload must be an object");

    // §2.2: reusing an id that is still in flight is bad_request.
    if (id !== null && id !== undefined) {
      if (session.ids.has(id))
        return err(id, type, "bad_request", `id ${id} is already in flight`);
      session.ids.add(id);
    }
    const done = () => session.ids.delete(id);

    // §3.1: exactly four messages while ANONYMOUS.
    const anonOk = ["ping", "auth.challenge", "auth.login", "auth.resume"].includes(type);
    const leak = broke("anon-leak") && type === "world.lands";
    if (!session.address && !anonOk && !leak) {
      done();
      return err(id, type, "unauthorized", "log in first");
    }

    try {
      await handle(type, id, payload);
    } catch (e) {
      err(id, type, "internal", String(e?.message ?? e), { trace_id: "mock" });
    } finally {
      done();
    }
  });

  async function handle(type, id, payload) {
    const me = session.address;
    switch (type) {
      // ---------------------------------------------------------- §4.1
      case "ping":
        return reply(id, "ping.ok", { t: now() });

      // ---------------------------------------------------------- §4.2
      case "auth.challenge": {
        const claimed = String(payload.address ?? "");
        if (!/^0x[0-9a-fA-F]{40}$/.test(claimed))
          return err(id, type, "bad_request", "not an address");
        let eip55;
        try {
          eip55 = toEip55(claimed);
        } catch {
          return err(id, type, "bad_request", "unknown address (the mock has no keccak)");
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
          (broke("trailing-newline") ? "\n" : "");
        nonces.set(nonce, {
          address: eip55.toLowerCase(),
          expires_at,
          message,
          used: false,
        });
        return reply(id, "auth.challenge.ok", { nonce, message, expires_at });
      }

      // ---------------------------------------------------------- §4.3
      case "auth.login": {
        const sig = String(payload.signature ?? "");
        const claimed = String(payload.address ?? "").toLowerCase();
        if (!/^0x[0-9a-f]{130}$/i.test(sig))
          return err(id, type, "auth_bad_signature", "not 65 bytes of hex");
        const live = [...nonces.entries()].filter(
          ([, n]) => n.address === claimed && Date.parse(n.expires_at) > Date.now(),
        );
        if (live.length === 0) return err(id, type, "auth_expired", "no live nonce");
        const [nonce, rec] = live[live.length - 1];

        // §4.3: v is 27/28; 0/1 is also accepted and normalised.
        let normalised = sig;
        const v = parseInt(sig.slice(-2), 16);
        if (v === 0 || v === 1)
          normalised = sig.slice(0, -2) + (v + 27).toString(16).padStart(2, "0");

        // In order: recover, compare, check the nonce, burn it. A bad
        // signature must never consume anyone's challenge.
        let who = recover(rec.message, normalised);
        if (who !== claimed && broke("accepts-rebuilt"))
          if (recover(`${rec.message}\n`, normalised) === claimed) who = claimed;
        if (who !== claimed)
          return err(id, type, "auth_bad_signature", "recovered a different address");
        if (rec.used && !broke("nonce-reuse"))
          return err(id, type, "auth_nonce_used", "that nonce is spent");
        rec.used = true;
        nonces.set(nonce, rec);

        const eip55 = toEip55(claimed);
        const user = users.get(claimed) ?? {
          address: eip55, // §2.4: EIP-55 on the wire, both directions
          name: String(payload.name ?? `hacker-${claimed.slice(2, 8)}`),
          created_at: now(),
          last_seen_at: now(),
          settings: {},
          level: 1,
          xp: 0,
        };
        user.last_seen_at = now();
        users.set(claimed, user);
        session.address = claimed;
        const token = randomBytes(32).toString("base64url");
        tokens.set(sha(token), claimed);
        return reply(id, "auth.login.ok", { token, user });
      }

      // ---------------------------------------------------------- §4.4
      case "auth.resume": {
        const sent = String(payload.token ?? "");
        const who = tokens.get(sha(sent));
        if (!who) return err(id, type, "unauthorized", "unknown or expired token");
        session.address = who;
        const token = randomBytes(32).toString("base64url");
        tokens.set(sha(token), who);
        // "the server rotates on use" — so the old one dies. A server that
        // rotates but leaves the old one alive teaches clients to keep it.
        if (!broke("token-static")) tokens.delete(sha(sent));
        return reply(id, "auth.resume.ok", { token, user: users.get(who) });
      }

      // ---------------------------------------------------------- §4.5
      case "profile.update": {
        const user = users.get(me);
        if (payload.name !== undefined) user.name = String(payload.name);
        if (payload.settings !== undefined) user.settings = payload.settings;
        return reply(id, "profile.update.ok", { user });
      }

      // ---------------------------------------------------------- §4.6
      case "world.lands": {
        const lower = me ?? "0x";
        const empty = (category) => ({
          category,
          total: 0,
          cleared: 0,
          stars: 0,
          open: false,
        });
        // Progress is only kept for the rust quests (the checker clears
        // those); the other three lands are present so a client sees the
        // real shape of the world, with one open basic map each.
        return reply(id, "world.lands.ok", {
          lands: Object.entries(LANDS).map(([land, quests]) => ({
            land,
            categories: [
              {
                category: "basic",
                total: quests.length,
                cleared: land === "rust" ? clearedCount(lower) : 0,
                stars: land === "rust" ? starsOf(lower) : 0,
                open: true,
              },
              empty("advanced"),
              empty("hacker"),
            ],
          })),
        });
      }

      // ---------------------------------------------------------- §4.7
      case "world.map": {
        const { land, category } = payload;
        if (category !== "basic" || !(land in LANDS))
          return reply(id, "world.map.ok", { land, category, nodes: [], edges: [] });
        return reply(id, "world.map.ok", {
          land,
          category,
          nodes: questsOf(land).map((q) => ({
            quest_id: q.id,
            node: q.node,
            title: q.title,
            difficulty: q.difficulty,
            state: stateOf(me, q),
            stars: progress.get(`${me}|${q.id}`)?.stars ?? 0,
            x: q.x,
            y: q.y,
            kind: q.kind,
            requires: q.requires,
            // §4.9b: a node's `attempts` counts **submits only**. Counting
            // runs here is exactly the invariant `contract.mjs` asserts —
            // iterating honestly must not look like failing repeatedly — and
            // the selftest caught this mock getting it wrong, which is the
            // selftest doing its job.
            attempts: (attempts.get(me) ?? []).filter(
              (a) => a.quest_id === q.id && a.mode !== "run",
            ).length,
          })),
          edges: questsOf(land).flatMap((q) => q.requires.map((r) => [r, q.id])),
        });
      }

      // ---------------------------------------------------------- §4.8
      case "quest.get": {
        const q = findQuest(payload.quest_id);
        if (!q) return err(id, type, "not_found", "no such quest");
        const state = stateOf(me, q);
        const quest = {
          id: q.id,
          land: langOf(q.id),
          category: "basic",
          node: q.node,
          title: q.title,
          brief: "Print `hello, causewaybay` and nothing else.",
          story: "The terminal blinks. You used to know this one.",
          difficulty: q.difficulty,
          time_limit_s: null,
          starter: q.starter,
          concepts: ["io", "macros"],
          hints_total: q.hints.length,
          hints_used: 0,
          state,
          stars: progress.get(`${me}|${q.id}`)?.stars ?? 0,
          tests: {
            match: "trim",
            timeout_ms: 5000,
            visible: [{ name: "greets", stdin: "", expect: q.expect }],
            hidden_count: 0,
          },
        };
        // §4.8: omitted entirely unless cleared — not null, not empty.
        if (state === "cleared" || broke("solution-leak")) quest.solution = q.solution;
        return reply(id, "quest.get.ok", { quest });
      }

      // ---------------------------------------------------------- §4.9
      case "quest.run":
      case "quest.submit": {
        const isRun = type === "quest.run";
        const q = findQuest(payload.quest_id);
        if (!q) return err(id, type, "not_found", "no such quest");
        if (payload.lang !== langOf(q.id))
          return err(id, type, "bad_request", "lang does not match the quest's land");
        // §3.2: one in flight per CONNECTION, not per user.
        const isBusy = broke("busy-per-user")
          ? [...connections].some((s) => s.address === me && s.inFlight)
          : session.inFlight;
        if (isBusy && !broke("no-busy"))
          return err(id, type, "busy", "a submission is already in flight");
        session.inFlight = true;

        try {
          const attemptId = "att_" + randomBytes(8).toString("hex");
          let seq = broke("seq-from-one") ? 1 : 0;
          const log = (stream, chunk) => {
            emit("run.log", { attempt_id: attemptId, stream, chunk, seq: seq++ });
            if (broke("seq-gap")) seq++;
          };
          for (const [i, stage] of ["queued", "compiling", "running", "judging"].entries()) {
            emit("run.stage", {
              attempt_id: attemptId,
              stage,
              queued: 0,
              elapsed_ms: i * 40,
            });
            if (stage === "compiling") {
              log("compile", "   Compiling main ");
              log("compile", "v0.1.0\n");
            }
            await sleep(30);
          }

          // "Judging": does the source print what the visible case expects?
          const src = String(payload.source ?? "");
          const isGo = langOf(q.id) === "go";
          // The mock has no compiler. It recognises one shape of compile
          // error — a bare identifier where a value is printed — because the
          // checker asserts that `undefined: tolal` classifies as
          // `unknown-name` with a code that does not carry the identifier.
          const bare = isGo
            ? /Println\(\s*([A-Za-z_]\w*)\s*\)/.exec(src)?.[1]
            : null;
          if (bare && !["true", "false", "nil"].includes(bare)) {
            const attemptId = "att_" + randomBytes(8).toString("hex");
            const attempt = {
              id: attemptId,
              quest_id: q.id,
              verdict: "compile_error",
              tests_passed: 0,
              tests_total: 1,
              compile_ms: 90,
              run_ms: 0,
              exit_code: 1,
              stderr: `./main.go:5:14: undefined: ${bare}`,
              cases: [],
              mistakes: [
                {
                  kind: "unknown-name",
                  // Normalised: the identifier is stripped, so two spellings
                  // of one lesson are one row (§7.2's rollup).
                  code: "go:undefined",
                  message: "undefined name",
                  line: 5,
                  col: 14,
                },
              ],
              stars: 0,
              cleared: false,
              mode: isRun ? "run" : "submit",
              created_at: now(),
            };
            push(attempts, me, attempt);
            push(mistakes, me, { kind: "unknown-name", code: "go:undefined", message: "undefined name" });
            return reply(id, `${type}.ok`, { attempt });
          }
          const printed = {
            go: () => /Println\("([^"]*)"\)/.exec(src)?.[1],
            rust: () => /println!\("([^"]*)"\)/.exec(src)?.[1],
            // `std::cout << "…\n"` carries its own newline, unlike the others.
            cpp: () => /std::cout << "([^"]*)\\n"/.exec(src)?.[1],
            python: () => /print\("([^"]*)"\)/.exec(src)?.[1],
            // Same shape as Python's, because it is Python's runner.
            pytorch: () => /print\("([^"]*)"\)/.exec(src)?.[1],
            typescript: () => /console\.log\("([^"]*)"\)/.exec(src)?.[1],
          }[langOf(q.id)]?.();
          const ok = printed !== undefined && `${printed}\n` === q.expect;
          const had = progress.get(`${me}|${q.id}`);
          const firstClear = ok && had?.state !== "cleared";
          const attempt = {
            id: attemptId,
            quest_id: q.id,
            verdict: ok ? "accepted" : "wrong_answer",
            tests_passed: ok ? 1 : 0,
            tests_total: 1,
            compile_ms: 120,
            run_ms: 3,
            exit_code: 0,
            stderr: "",
            cases: [
              {
                name: "greets",
                passed: ok,
                visible: true,
                stdin: "",
                expect: q.expect,
                got: printed === undefined ? "" : `${printed}\n`,
              },
            ],
            mistakes: ok
              ? []
              : [
                  {
                    kind: "wrong-answer",
                    code: null,
                    message: "output differs from the expected value",
                    line: null,
                    col: null,
                  },
                ],
            stars: isRun || !ok ? 0 : had?.tries ? 2 : 3,
            cleared: isRun ? false : firstClear,
            mode: isRun ? "run" : "submit",
            created_at: now(),
          };
          push(attempts, me, attempt);
          // §4.9b: a run is recorded and its mistakes enter the curriculum,
          // but it never clears, never scores and never counts as an attempt
          // on the node.
          if (isRun) {
            if (!ok)
              push(mistakes, me, {
                kind: "wrong-answer",
                code: null,
                message: "output differs",
              });
            return reply(id, "quest.run.ok", { attempt });
          }
          if (!ok)
            push(mistakes, me, {
              kind: "wrong-answer",
              code: null,
              message: "output differs",
            });

          if (ok) {
            progress.set(`${me}|${q.id}`, {
              state: "cleared",
              stars: attempt.stars,
              tries: (had?.tries ?? 0) + 1,
            });
            const unlocked = QUESTS.filter(
              (x) => x.requires.includes(q.id) && stateOf(me, x) === "open",
            ).map((x) => x.id);
            const update = {
              quest_id: q.id,
              state: "cleared",
              stars: attempt.stars,
              cleared_total: clearedCount(me),
              unlocked,
            };
            // §4.19: to this connection, and to the same user's others.
            for (const s of connections) {
              if (s.address !== me) continue;
              if (s !== session && broke("no-broadcast")) continue;
              s.ws.send(
                JSON.stringify({
                  v: 1,
                  id: broke("event-id") ? "s-1" : null,
                  type: "progress.update",
                  payload: update,
                }),
              );
            }
            if (firstClear)
              emit("award", { kind: "stamp", id: "cleared", title: "CLEARED", detail: {} });
          } else {
            progress.set(`${me}|${q.id}`, {
              state: "open",
              stars: had?.stars ?? 0,
              tries: (had?.tries ?? 0) + 1,
            });
          }
          return reply(id, "quest.submit.ok", { attempt });
        } finally {
          session.inFlight = false;
        }
      }

      // --------------------------------------------------------- §4.10-11
      case "quest.hint": {
        const q = QUESTS.find((x) => x.id === payload.quest_id);
        if (!q) return err(id, type, "not_found", "no such quest");
        const index = Number(payload.index ?? 0);
        if (!(index >= 0 && index < q.hints.length))
          return err(id, type, "not_found", "no such hint");
        return reply(id, "quest.hint.ok", {
          hint: q.hints[index],
          index,
          total: q.hints.length,
          hints_used: index + 1,
        });
      }
      case "quest.reset": {
        const q = QUESTS.find((x) => x.id === payload.quest_id);
        if (!q) return err(id, type, "not_found", "no such quest");
        return reply(id, "quest.reset.ok", { starter: q.starter });
      }

      // --------------------------------------------------------- §4.13-15
      case "stats.summary": {
        const who =
          broke("trust-payload") && payload.address
            ? String(payload.address).toLowerCase()
            : me;
        const rows = attempts.get(who) ?? [];
        const cleared = clearedCount(who);
        return reply(id, "stats.summary.ok", {
          cleared,
          total: QUESTS.length,
          // §4.9b: submits only.
          attempts: rows.filter((a) => a.mode !== "run").length,
          // §4.9b: runs are excluded from accuracy for the same reason.
          accuracy: (() => {
            const submits = rows.filter((a) => a.mode !== "run");
            return submits.length
              ? submits.filter((a) => a.verdict === "accepted").length / submits.length
              : 0;
          })(),
          streak_days: 0,
          stars: starsOf(who),
          by_land: Object.entries(LANDS).map(([land, quests]) => ({
            land,
            cleared: land === "rust" ? cleared : 0,
            total: land === "rust" ? quests.length : 0,
          })),
        });
      }
      case "stats.mistakes": {
        const who =
          broke("trust-payload") && payload.address
            ? String(payload.address).toLowerCase()
            : me;
        const byKind = new Map();
        for (const m of mistakes.get(who) ?? [])
          byKind.set(m.kind, (byKind.get(m.kind) ?? 0) + 1);
        return reply(id, "stats.mistakes.ok", {
          mistakes: [...byKind]
            .sort((a, b) => b[1] - a[1])
            .slice(0, Number(payload.limit ?? 10))
            .map(([kind, count]) => ({
              kind,
              label: kind,
              count,
              last_at: now(),
              cleared_since: 0,
              example_quest_id: null,
              concepts: [],
            })),
        });
      }
      case "stats.history": {
        const who =
          broke("trust-payload") && payload.address
            ? String(payload.address).toLowerCase()
            : me;
        let rows = broke("cross-user")
          ? [...attempts.values()].flat()
          : attempts.get(who) ?? [];
        if (payload.quest_id) rows = rows.filter((a) => a.quest_id === payload.quest_id);
        return reply(id, "stats.history.ok", {
          attempts: rows
            .slice()
            .reverse()
            .slice(0, Number(payload.limit ?? 20))
            .map((a) => ({
              id: a.id,
              quest_id: a.quest_id,
              verdict: a.verdict,
              tests_passed: a.tests_passed,
              tests_total: a.tests_total,
              created_at: a.created_at,
              kinds: a.mistakes.map((m) => m.kind),
            })),
        });
      }

      // ----------------------------------------------------- milestone 2
      //
      // `unavailable`, not `not_found`: PROTOCOL.md §3.3 gained the code
      // precisely for this — a feature that is real and specified but not
      // built. `not_found` says "no such thing", which is a different
      // sentence to say to a player, and `internal` would tell them their
      // machine is broken and invite a retry that cannot work.
      case "search.query":
        return err(id, type, "unavailable", "search (SPEC §8) is not in this build yet", {
          milestone: 2,
        });
      case "ai.plan":
      case "ai.next":
      case "ai.finish":
        return err(id, type, "unavailable", "AI drills (SPEC §7.3) are not in this build yet", {
          milestone: 2,
        });

      default:
        // §2.3 tells a *client* to ignore an unknown type. The server has to
        // answer something; `bad_request` is the honest one.
        if (broke("unknown-closes")) return ws.close(1003, "unknown type");
        return err(id, type, "bad_request", `unknown type ${type}`);
    }
  }
});

http.listen(PORT, "127.0.0.1", () => {
  console.log(
    `mock PROTOCOL.md server on ws://127.0.0.1:${PORT}/ws` +
      (BREAK ? `  [broken on purpose: ${BREAK}]` : ""),
  );
});
