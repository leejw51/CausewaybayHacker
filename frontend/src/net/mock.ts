/**
 * A stand-in server, for development only.
 *
 * CWBHACKER_MOCK_SENTINEL — grep for this in `dist/` after a build. It must
 * not be there. This module is only ever reached through a dynamic `import()`
 * behind `import.meta.env.DEV`, which Vite folds to `false` in a production
 * build so Rollup drops the whole chunk.
 *
 * It exists because the backend is written in parallel and may not run yet.
 * It is a *server*: the game rules it contains are the ones that belong on the
 * far side of the websocket, and none of them are reachable from a scene. When
 * the real server is up, `VITE_WS_URL` points at it and nothing here loads.
 *
 * The judging is deliberately crude — a substring check, not a compiler. What
 * it faithfully reproduces is the *protocol*: the envelope, the correlation,
 * the `run.stage`/`run.log` stream arriving before the reply, the error codes,
 * the nonce burn. Those are the parts the frontend has to be right about.
 */
import { secp256k1 } from "@noble/curves/secp256k1.js";
import { keccak_256 } from "@noble/hashes/sha3.js";
import { decode, encode } from "./codec";
import type { Attempt, MapNode, Quest, User } from "./protocol";
import type { Transport, TransportFactory, TransportHandlers } from "./transport";

interface MockQuest extends Quest {
  hints: string[];
  solution_marker: string;
  expect: string;
  x: number;
  y: number;
  requires: string[];
}

/**
 * Three nodes of RUST/BASIC, which is exactly the PLAN.md vertical slice. The
 * real text comes from `content/rust/basic.toml`, which PM owns; these are
 * placeholders in the same shape so the screens can be built against them.
 */
const QUESTS: MockQuest[] = [
  {
    id: "rust.basic.01.hello",
    land: "rust",
    category: "basic",
    node: 1,
    title: "FIRST LIGHT",
    difficulty: 1,
    time_limit_s: null,
    story: "The terminal blinks. You used to know this one.",
    brief: "Print `hello, causewaybay` and nothing else.",
    concepts: ["io", "macros"],
    hints_total: 2,
    hints: ["`println!` is a macro, so it takes a `!`.", "The string is exact: one comma, one space."],
    starter: "fn main() {\n    // your code here\n}\n",
    solution_marker: 'println!("hello, causewaybay")',
    expect: "hello, causewaybay\n",
    x: 0.14,
    y: 0.72,
    requires: [],
  },
  {
    id: "rust.basic.02.bindings",
    land: "rust",
    category: "basic",
    node: 2,
    title: "LET IT BE",
    difficulty: 1,
    time_limit_s: null,
    story: "Skynet wrote this for you once. Write it yourself.",
    brief: "Bind the number 42 and print it.",
    concepts: ["bindings"],
    hints_total: 1,
    hints: ["`let n = 42;` and then print `n`."],
    starter: "fn main() {\n    let n = 0;\n    println!(\"{n}\");\n}\n",
    solution_marker: "42",
    expect: "42\n",
    x: 0.42,
    y: 0.55,
    requires: ["rust.basic.01.hello"],
  },
  {
    id: "rust.basic.03.shadowing",
    land: "rust",
    category: "basic",
    node: 3,
    title: "SECOND SELF",
    difficulty: 2,
    time_limit_s: null,
    story: "A name can mean two things. That is not a bug.",
    brief: "Shadow `x` so the program prints `9`.",
    concepts: ["shadowing", "bindings"],
    hints_total: 1,
    hints: ["A second `let x` in the same scope shadows the first."],
    starter: "fn main() {\n    let x = 3;\n    // shadow x here\n    println!(\"{x}\");\n}\n",
    solution_marker: "9",
    expect: "9\n",
    x: 0.73,
    y: 0.33,
    requires: ["rust.basic.02.bindings"],
  },
];

type ProgressRow = { state: "locked" | "open" | "cleared"; stars: 0 | 1 | 2 | 3; fails: number; hints: number };

function hex(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += b.toString(16).padStart(2, "0");
  return s;
}

function randomHex(n: number): string {
  const b = new Uint8Array(n);
  crypto.getRandomValues(b);
  return hex(b);
}

/** The server half of SPEC §3.2, so the client's signature is really checked. */
function recoverAddress(message: string, signature: string): string {
  const sig = signature.replace(/^0x/, "");
  if (sig.length !== 130) throw new Error("a signature is 65 bytes");
  const body = new TextEncoder().encode(message);
  const prefix = new TextEncoder().encode(`\x19Ethereum Signed Message:\n${body.length}`);
  const buf = new Uint8Array(prefix.length + body.length);
  buf.set(prefix, 0);
  buf.set(body, prefix.length);
  const hash = keccak_256(buf);

  const rs = new Uint8Array(64);
  for (let i = 0; i < 64; i++) rs[i] = parseInt(sig.slice(i * 2, i * 2 + 2), 16);
  const v = parseInt(sig.slice(128, 130), 16);
  // v is 27/28 on the wire; noble wants the bare 0/1 recovery bit in front.
  const recovery = v >= 27 ? v - 27 : v;
  const recovered = new Uint8Array(65);
  recovered[0] = recovery;
  recovered.set(rs, 1);
  const pub = secp256k1.recoverPublicKey(recovered, hash, { prehash: false });
  const point = secp256k1.Point.fromBytes(pub).toBytes(false);
  return "0x" + hex(keccak_256(point.subarray(1)).subarray(12));
}

function eip55(lower: string): string {
  const body = lower.replace(/^0x/, "");
  const h = hex(keccak_256(new TextEncoder().encode(body)));
  let out = "0x";
  for (let i = 0; i < 40; i++) out += parseInt(h[i], 16) >= 8 ? body[i].toUpperCase() : body[i];
  return out;
}

/**
 * The mock's whole world, kept outside the transport so a reconnect resumes it
 * — and mirrored into `sessionStorage` so a *reload* does too.
 *
 * That last part matters more than it looks. "Kill it, reload, the quest is
 * still cleared" is the milestone-1 acceptance test (PLAN.md), and a mock whose
 * state evaporated with the page would make that test impossible to write until
 * the real server existed. The real server keeps this in SQLite; this keeps it
 * in a tab. Nonces are deliberately *not* persisted: they are single-use and
 * live 120 seconds, exactly as SPEC §3.2 says.
 */
const WORLD_KEY = "cwbhacker.mockworld";

const world = {
  nonces: new Map<string, { address: string; message: string; expires: number }>(),
  tokens: new Map<string, string>(),
  users: new Map<string, User>(),
  progress: new Map<string, Map<string, ProgressRow>>(),
};

type Saved = {
  tokens: Array<[string, string]>;
  users: Array<[string, User]>;
  progress: Array<[string, Array<[string, ProgressRow]>]>;
};

function loadWorld(): void {
  try {
    const raw = sessionStorage.getItem(WORLD_KEY);
    if (!raw) return;
    const s = JSON.parse(raw) as Saved;
    world.tokens = new Map(s.tokens);
    world.users = new Map(s.users);
    world.progress = new Map(s.progress.map(([a, rows]) => [a, new Map(rows)]));
  } catch {
    /* a corrupt blob just means a fresh world, which is what a dev wants anyway */
  }
}

function saveWorld(): void {
  try {
    const s: Saved = {
      tokens: [...world.tokens],
      users: [...world.users],
      progress: [...world.progress].map(([a, rows]) => [a, [...rows]]),
    };
    sessionStorage.setItem(WORLD_KEY, JSON.stringify(s));
  } catch {
    /* storage disabled: the mock still works, it just forgets on reload */
  }
}

loadWorld();

function progressFor(address: string): Map<string, ProgressRow> {
  let p = world.progress.get(address);
  if (!p) {
    p = new Map();
    for (const q of QUESTS) {
      p.set(q.id, { state: q.requires.length === 0 ? "open" : "locked", stars: 0, fails: 0, hints: 0 });
    }
    world.progress.set(address, p);
  }
  return p;
}

function relock(rows: Map<string, ProgressRow>): void {
  for (const q of QUESTS) {
    const row = rows.get(q.id)!;
    if (row.state === "cleared") continue;
    row.state = q.requires.every((r) => rows.get(r)?.state === "cleared") ? "open" : "locked";
  }
}

function mapNodes(address: string): MapNode[] {
  const rows = progressFor(address);
  return QUESTS.map((q) => ({
    quest_id: q.id,
    node: q.node,
    title: q.title,
    difficulty: q.difficulty,
    state: rows.get(q.id)!.state,
    stars: rows.get(q.id)!.stars,
    x: q.x,
    y: q.y,
    kind: "quest" as const,
  }));
}

function publicQuest(q: MockQuest, cleared: boolean): Quest {
  const { id, land, category, node, title, brief, story, difficulty, time_limit_s, starter, hints_total, concepts } = q;
  const out: Quest = {
    id,
    land,
    category,
    node,
    title,
    brief,
    story,
    difficulty,
    time_limit_s,
    starter,
    hints_total,
    concepts,
  };
  // §6.2: no `solution` unless the player has cleared it.
  if (cleared) out.solution = q.starter.replace("// your code here", q.solution_marker + ";");
  return out;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * A mock connection. One per `connect()`, so closing and reopening exercises
 * the client's reconnect-with-token path for real.
 */
export function mockTransport(): TransportFactory {
  return (h: TransportHandlers): Transport => {
    let closed = false;
    let address: string | null = null;

    const emit = (id: string | null, type: string, payload: unknown) => {
      if (closed) return;
      h.onMessage(encode(id, type, payload));
    };
    const ok = (id: string, type: string, payload: unknown) => emit(id, `${type}.ok`, payload);
    const err = (id: string, type: string, code: string, message: string) =>
      emit(id, `${type}.err`, { code, message, detail: {} });

    setTimeout(() => {
      if (!closed) h.onOpen();
    }, 30);

    const handle = async (id: string, type: string, p: Record<string, unknown>) => {
      // §6.4: anonymous connections may only ping or start a login.
      const preauth = type === "ping" || type.startsWith("auth.");
      if (!address && !preauth) return err(id, type, "unauthorized", "log in first");

      switch (type) {
        case "ping":
          return ok(id, type, { t: Date.now() });

        case "auth.challenge": {
          const claimed = String(p.address ?? "");
          if (!/^0x[0-9a-fA-F]{40}$/.test(claimed)) {
            return err(id, type, "bad_request", "that is not an address");
          }
          const nonce = randomHex(32);
          const expires = new Date(Date.now() + 120_000);
          const message = [
            "Causewaybay Hacker login",
            `address: ${eip55(claimed.toLowerCase())}`,
            `nonce: ${nonce}`,
            `expires: ${expires.toISOString().replace(/\.\d+Z$/, "Z")}`,
          ].join("\n");
          world.nonces.set(nonce, {
            address: claimed.toLowerCase(),
            message,
            expires: expires.getTime(),
          });
          return ok(id, type, {
            nonce,
            message,
            expires_at: expires.toISOString().replace(/\.\d+Z$/, "Z"),
          });
        }

        case "auth.login": {
          const claimed = String(p.address ?? "").toLowerCase();
          const entry = [...world.nonces.entries()].find(([, n]) => n.address === claimed);
          if (!entry) return err(id, type, "auth_nonce_used", "no live challenge for that address");
          const [nonce, n] = entry;
          if (Date.now() > n.expires) {
            world.nonces.delete(nonce);
            return err(id, type, "auth_expired", "the challenge expired");
          }
          let recovered: string;
          try {
            recovered = recoverAddress(n.message, String(p.signature ?? ""));
          } catch {
            return err(id, type, "auth_bad_signature", "the signature did not parse");
          }
          if (recovered !== claimed) {
            return err(id, type, "auth_bad_signature", "that signature is somebody else's");
          }
          world.nonces.delete(nonce); // single use, burned on success
          address = claimed;
          const now = new Date().toISOString().replace(/\.\d+Z$/, "Z");
          const user: User = world.users.get(claimed) ?? {
            address: claimed,
            address_eip55: eip55(claimed),
            name: `hacker-${claimed.slice(2, 8)}`,
            created_at: now,
            last_seen_at: now,
            settings: {},
          };
          user.last_seen_at = now;
          world.users.set(claimed, user);
          const token = randomHex(24);
          world.tokens.set(token, claimed);
          progressFor(claimed);
          saveWorld();
          return ok(id, type, { token, user });
        }

        case "auth.resume": {
          const token = String(p.token ?? "");
          const owner = world.tokens.get(token);
          if (!owner) return err(id, type, "unauthorized", "that session is gone");
          address = owner;
          return ok(id, type, { token, user: world.users.get(owner)! });
        }

        case "profile.update": {
          const user = world.users.get(address!)!;
          if (typeof p.name === "string") user.name = p.name;
          if (p.settings && typeof p.settings === "object") {
            user.settings = p.settings as Record<string, unknown>;
          }
          saveWorld();
          return ok(id, type, { user });
        }

        case "world.lands": {
          const rows = progressFor(address!);
          const cleared = QUESTS.filter((q) => rows.get(q.id)!.state === "cleared").length;
          return ok(id, type, {
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
          if (p.land !== "rust" || p.category !== "basic") {
            return ok(id, type, { nodes: [], edges: [] });
          }
          const edges: Array<[number, number]> = [];
          for (const q of QUESTS) {
            for (const r of q.requires) {
              const from = QUESTS.find((x) => x.id === r);
              if (from) edges.push([from.node, q.node]);
            }
          }
          return ok(id, type, { nodes: mapNodes(address!), edges });
        }

        case "quest.get": {
          const q = QUESTS.find((x) => x.id === p.quest_id);
          if (!q) return err(id, type, "not_found", "no such quest");
          const rows = progressFor(address!);
          if (rows.get(q.id)!.state === "locked") {
            return err(id, type, "locked", "clear the node before it");
          }
          return ok(id, type, { quest: publicQuest(q, rows.get(q.id)!.state === "cleared") });
        }

        case "quest.reset": {
          const q = QUESTS.find((x) => x.id === p.quest_id);
          if (!q) return err(id, type, "not_found", "no such quest");
          return ok(id, type, { starter: q.starter });
        }

        case "quest.hint": {
          const q = QUESTS.find((x) => x.id === p.quest_id);
          if (!q) return err(id, type, "not_found", "no such quest");
          const row = progressFor(address!).get(q.id)!;
          const i = Math.max(0, Math.min(q.hints.length - 1, Number(p.index ?? 0)));
          row.hints = Math.max(row.hints, i + 1);
          saveWorld();
          return ok(id, type, { hint: q.hints[i], hints_used: row.hints });
        }

        case "quest.submit": {
          const q = QUESTS.find((x) => x.id === p.quest_id);
          if (!q) return err(id, type, "not_found", "no such quest");
          const rows = progressFor(address!);
          const row = rows.get(q.id)!;
          const source = String(p.source ?? "");
          const attemptId = "att_" + randomHex(8);

          emit(null, "run.stage", { attempt_id: attemptId, stage: "queued" });
          await sleep(120);
          emit(null, "run.stage", { attempt_id: attemptId, stage: "compiling" });
          for (const line of [
            "   Compiling attempt v0.1.0\n",
            `rustc --edition 2021 -O main.rs -o prog\n`,
          ]) {
            await sleep(180);
            emit(null, "run.log", { attempt_id: attemptId, stream: "compile", chunk: line });
          }

          const broken = !/fn\s+main\s*\(/.test(source);
          if (broken) {
            await sleep(200);
            const stderr = "error: `main` function not found in crate `main`\n";
            emit(null, "run.log", { attempt_id: attemptId, stream: "stderr", chunk: stderr });
            row.fails++;
            const attempt: Attempt = {
              id: attemptId,
              verdict: "compile_error",
              tests_passed: 0,
              tests_total: 1,
              compile_ms: 480,
              run_ms: 0,
              stderr,
              cases: [],
              mistakes: [{ kind: "syntax", code: "E0601", message: "`main` function not found", line: 1 }],
              stars: 0,
              cleared: false,
            };
            return ok(id, type, { attempt });
          }

          emit(null, "run.stage", { attempt_id: attemptId, stage: "running" });
          await sleep(200);
          const passed = source.includes(q.solution_marker);
          const got = passed ? q.expect : "\n";
          emit(null, "run.log", { attempt_id: attemptId, stream: "stdout", chunk: got });
          emit(null, "run.stage", { attempt_id: attemptId, stage: "judging" });
          await sleep(120);

          if (!passed) row.fails++;
          const stars: 0 | 1 | 2 | 3 = !passed
            ? row.stars
            : row.fails === 0 && row.hints === 0
              ? 3
              : row.fails <= 2 || row.hints > 0
                ? 2
                : 1;
          if (passed) {
            row.state = "cleared";
            row.stars = stars;
            relock(rows);
          }
          saveWorld();
          const attempt: Attempt = {
            id: attemptId,
            verdict: passed ? "accepted" : "wrong_answer",
            tests_passed: passed ? 1 : 0,
            tests_total: 1,
            compile_ms: 480,
            run_ms: 12,
            stderr: "",
            cases: [
              {
                name: "sample",
                passed,
                visible: true,
                stdin: "",
                expect: q.expect,
                got,
              },
            ],
            mistakes: passed
              ? []
              : [{ kind: "wrong-answer", code: null, message: "output did not match", line: null }],
            stars,
            cleared: passed,
          };
          if (passed) {
            const clearedTotal = QUESTS.filter((x) => rows.get(x.id)!.state === "cleared").length;
            emit(null, "progress.update", {
              quest_id: q.id,
              state: "cleared",
              stars,
              cleared_total: clearedTotal,
            });
            emit(null, "award", {
              kind: "stamp",
              title: "STREET CLEARED",
              detail: { quest_id: q.id },
            });
          }
          return ok(id, type, { attempt });
        }

        case "stats.summary": {
          const rows = progressFor(address!);
          const cleared = QUESTS.filter((q) => rows.get(q.id)!.state === "cleared").length;
          return ok(id, type, {
            cleared,
            attempts: [...rows.values()].reduce((n, r) => n + r.fails, 0) + cleared,
            accuracy: cleared === 0 ? 0 : 0.5,
            streak: cleared,
            by_land: [{ land: "rust", cleared, total: QUESTS.length }],
          });
        }

        case "stats.mistakes":
          return ok(id, type, { mistakes: [] });
        case "stats.history":
          return ok(id, type, { attempts: [] });
        case "search.query":
          return ok(id, type, { hits: [] });

        default:
          return err(id, type, "bad_request", `the mock does not answer ${type}`);
      }
    };

    return {
      send(text: string) {
        const d = decode(text);
        if (d.kind === "bad") return;
        const f = d.frame;
        if (f.v !== 1) {
          return emit(f.id, `${f.type}.err`, {
            code: "proto_version",
            message: "this server speaks v1",
            detail: {},
          });
        }
        if (f.id === null) return; // clients do not send events
        // Never echo a payload: a login frame carries a signature, and a mock
        // that logged what it received is exactly how a secret ends up in a
        // console. Nothing here logs the frame body.
        void handle(f.id, f.type, f.payload as Record<string, unknown>);
      },
      close() {
        closed = true;
        h.onClose("mock closed");
      },
    };
  };
}
