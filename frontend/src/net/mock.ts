/**
 * A stand-in server, for development only.
 *
 * CWBHACKER_MOCK_SENTINEL — grep for this in `dist/` after a build. It must
 * not be there. This module is only ever reached through a dynamic `import()`
 * behind `import.meta.env.DEV`, which Vite folds to `false` in a production
 * build so Rollup drops the whole chunk.
 *
 * It exists because the backend is written in parallel and may not run yet.
 * It is a *server*: the game rules in it are the ones that belong on the far
 * side of the websocket, and none of them are reachable from a scene. When the
 * real server is up, `VITE_WS_URL` points at it and nothing here loads.
 *
 * The judging is deliberately crude — a substring check, not a compiler. What
 * it reproduces faithfully is the **protocol**, because a mock that is lenient
 * where the server is strict is worse than no mock at all. In particular it
 * obeys the parts of PROTOCOL §8 that are the client's to get wrong:
 *
 *   - replies come back **out of order** (a `ping` overtakes a `quest.submit`);
 *   - `run.log` chunks are split **mid-line** and carry a per-stream `seq`;
 *   - `auth.resume` **rotates** the token;
 *   - `progress.update` carries `unlocked`;
 *   - a second `quest.submit` while one is running is `busy`;
 *   - only `ping` and `auth.*` are accepted before authentication.
 */
import { secp256k1 } from "@noble/curves/secp256k1.js";
import { keccak_256 } from "@noble/hashes/sha3.js";
import { decode, encode } from "./codec";
import type { XpGain, Attempt, Category, Land, MapNode, Position, Quest, User } from "./protocol";
import type { Transport, TransportFactory, TransportHandlers } from "./transport";
import { deterministicUsername } from "../wallet/username";

interface MockQuest extends Quest {
  hints: string[];
  marker: string;
  expect: string;
  mapx: number;
  mapy: number;
  /** Lives on `MapNode` on the wire, not on `Quest`; the pack has it. */
  requires: string[];
}

const now = () => new Date().toISOString().replace(/\.\d+Z$/, "Z");

/**
 * Three nodes of RUST/BASIC, which is exactly the PLAN.md vertical slice. The
 * real text comes from `content/rust/basic.toml`, which PM owns; these are
 * placeholders in the same shape so the screens have something to draw.
 */
function quests(): MockQuest[] {
  const base = {
    land: "rust" as const,
    category: "basic" as const,
    time_limit_s: null,
    hints_used: 0,
    state: "open" as const,
    stars: 0 as const,
  };
  return [
    {
      ...base,
      id: "rust.basic.01.hello",
      node: 1,
      title: "FIRST LIGHT",
      difficulty: 1,
      story: "The terminal blinks. You used to know this one.",
      brief: "Print `hello, causewaybay` and nothing else.",
      concepts: ["io", "macros"],
      hints_total: 2,
      hints: [
        "`println!` is a macro, so it takes a `!`.",
        "The string is exact: lowercase, one comma, one space.",
      ],
      starter: "fn main() {\n    // your code here\n}\n",
      marker: 'println!("hello, causewaybay")',
      expect: "hello, causewaybay\n",
      mapx: 0.14,
      mapy: 0.72,
      requires: [],
      tests: {
        match: "trim",
        timeout_ms: 5000,
        visible: [{ name: "greets", stdin: "", expect: "hello, causewaybay\n" }],
        hidden_count: 0,
      },
    },
    {
      ...base,
      id: "rust.basic.02.bindings",
      node: 2,
      title: "LET IT BE",
      difficulty: 1,
      story: "Skynet wrote this for you once. Write it yourself.",
      brief: "Bind the number 42 and print it.",
      concepts: ["bindings"],
      hints_total: 1,
      hints: ["`let n = 42;` and then print `n`."],
      starter: 'fn main() {\n    let n = 0;\n    println!("{n}");\n}\n',
      marker: "42",
      expect: "42\n",
      mapx: 0.42,
      mapy: 0.55,
      requires: ["rust.basic.01.hello"],
      tests: {
        match: "trim",
        timeout_ms: 5000,
        visible: [{ name: "prints", stdin: "", expect: "42\n" }],
        hidden_count: 1,
      },
    },
    {
      ...base,
      id: "rust.basic.03.shadowing",
      node: 3,
      title: "SECOND SELF",
      difficulty: 2,
      story: "A name can mean two things. That is not a bug.",
      brief: "Shadow `x` so the program prints `9`.",
      concepts: ["shadowing", "bindings"],
      hints_total: 1,
      hints: ["A second `let x` in the same scope shadows the first."],
      starter: 'fn main() {\n    let x = 3;\n    // shadow x here\n    println!("{x}");\n}\n',
      marker: "9",
      expect: "9\n",
      mapx: 0.73,
      mapy: 0.33,
      requires: ["rust.basic.02.bindings"],
      tests: {
        match: "trim",
        timeout_ms: 5000,
        visible: [{ name: "prints", stdin: "", expect: "9\n" }],
        hidden_count: 2,
      },
    },
  ] as MockQuest[];
}

const QUESTS = quests();

type Row = {
  // Never `locked`: PROTOCOL §4.7 says every node is playable and the code
  // is no longer emitted, so the mock does not emit it either.
  state: "open" | "cleared";
  stars: 0 | 1 | 2 | 3;
  fails: number;
  hints: number;
  attempts: number;
};

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

function eip55(lower: string): string {
  const body = lower.replace(/^0x/, "").toLowerCase();
  const h = hex(keccak_256(new TextEncoder().encode(body)));
  let out = "0x";
  for (let i = 0; i < 40; i++) out += parseInt(h[i], 16) >= 8 ? body[i].toUpperCase() : body[i];
  return out;
}

/** The server half of PROTOCOL §4.3, so a real signature is really checked. */
function recoverAddress(message: string, signature: string): string {
  const sig = signature.replace(/^0x/, "");
  if (sig.length !== 130) throw new Error("a signature is 65 bytes");
  const body = new TextEncoder().encode(message);
  const prefix = new TextEncoder().encode(`\x19Ethereum Signed Message:\n${body.length}`);
  const buf = new Uint8Array(prefix.length + body.length);
  buf.set(prefix, 0);
  buf.set(body, prefix.length);
  const digest = keccak_256(buf);

  const rs = new Uint8Array(64);
  for (let i = 0; i < 64; i++) rs[i] = parseInt(sig.slice(i * 2, i * 2 + 2), 16);
  const v = parseInt(sig.slice(128, 130), 16);
  // 27/28 on the wire; 0/1 accepted and normalised, exactly as §4.3 says.
  const recovered = new Uint8Array(65);
  recovered[0] = v >= 27 ? v - 27 : v;
  recovered.set(rs, 1);
  const pub = secp256k1.recoverPublicKey(recovered, digest, { prehash: false });
  const point = secp256k1.Point.fromBytes(pub).toBytes(false);
  return "0x" + hex(keccak_256(point.subarray(1)).subarray(12));
}

/**
 * The mock's whole world, mirrored into `sessionStorage` so a *reload* keeps it.
 *
 * That matters more than it looks: "clear it, reload, it is still cleared" is
 * the milestone-1 acceptance test (PLAN.md), and a mock whose state evaporated
 * with the page would make that test unwritable until the real server existed.
 * The real server keeps this in SQLite; this keeps it in a tab. Nonces are
 * deliberately *not* persisted — they are single-use and live 120 seconds.
 */
const WORLD_KEY = "cwbhacker.mockworld";

const world = {
  nonces: new Map<string, { address: string; message: string; expires: number }>(),
  tokens: new Map<string, string>(),
  users: new Map<string, User>(),
  progress: new Map<string, Map<string, Row>>(),
  // §1.3. Kept here rather than faked at login, so the mock reproduces the
  // actual mechanism: the place is written from the navigation requests, not
  // from anything the client says about itself.
  positions: new Map<string, Position>(),
};

type Saved = {
  tokens: Array<[string, string]>;
  users: Array<[string, User]>;
  progress: Array<[string, Array<[string, Row]>]>;
  positions?: Array<[string, Position]>;
};

function loadWorld(): void {
  try {
    const raw = sessionStorage.getItem(WORLD_KEY);
    if (!raw) return;
    const s = JSON.parse(raw) as Saved;
    world.tokens = new Map(s.tokens);
    world.users = new Map(s.users);
    // A blob written while the mock still locked nodes is read as open ones:
    // `locked` is not a state a row can be in any more (§4.7).
    world.progress = new Map(
      s.progress.map(([a, rows]) => [
        a,
        new Map(
          rows.map(([id, row]) => [
            id,
            { ...row, state: row.state === "cleared" ? "cleared" : "open" } as Row,
          ]),
        ),
      ]),
    );
    // Optional: a blob written before §1.3 existed is still a good world.
    world.positions = new Map(s.positions ?? []);
  } catch {
    /* a corrupt blob just means a fresh world, which is what a dev wants */
  }
}

function saveWorld(): void {
  try {
    const s: Saved = {
      tokens: [...world.tokens],
      users: [...world.users],
      progress: [...world.progress].map(([a, rows]) => [a, [...rows]]),
      positions: [...world.positions],
    };
    sessionStorage.setItem(WORLD_KEY, JSON.stringify(s));
  } catch {
    /* storage disabled: the mock still works, it just forgets on reload */
  }
}

loadWorld();

function progressFor(address: string): Map<string, Row> {
  let p = world.progress.get(address);
  if (!p) {
    p = new Map();
    for (const q of QUESTS) {
      p.set(q.id, {
        state: "open",
        stars: 0,
        fails: 0,
        hints: 0,
        attempts: 0,
      });
    }
    world.progress.set(address, p);
  }
  return p;
}

/**
 * What clearing `questId` just finished the prerequisites for — §4.19's
 * `unlocked`. Nothing is gated (§4.7), so this is not "these became playable"
 * but "the suggested route says these come next and you have now done
 * everything they asked for": the same set the server's `unlocked_by` sends.
 */
function unlockedBy(rows: Map<string, Row>, questId: string): string[] {
  const cleared = (id: string) => rows.get(id)?.state === "cleared";
  return QUESTS.filter(
    (q) => q.requires.includes(questId) && !cleared(q.id) && q.requires.every(cleared),
  ).map((q) => q.id);
}

function mapNodes(address: string): MapNode[] {
  const rows = progressFor(address);
  return QUESTS.map((q) => {
    const row = rows.get(q.id)!;
    return {
      quest_id: q.id,
      node: q.node,
      title: q.title,
      difficulty: q.difficulty,
      state: row.state,
      stars: row.stars,
      x: q.mapx,
      y: q.mapy,
      kind: "quest" as const,
      requires: q.requires,
      attempts: row.attempts,
      // The mock has no translation packs, so every title is the English one
      // and says so — the same answer a real server gives for `locale: "xx"`.
      text_locale: "en",
    };
  });
}

function publicQuest(q: MockQuest, row: Row): Quest {
  const out: Quest = {
    id: q.id,
    land: q.land,
    category: q.category,
    node: q.node,
    title: q.title,
    brief: q.brief,
    story: q.story,
    text_locale: "en",
    difficulty: q.difficulty,
    time_limit_s: q.time_limit_s,
    starter: q.starter,
    concepts: q.concepts,
    hints_total: q.hints_total,
    hints_used: row.hints,
    state: row.state,
    stars: row.stars,
    tests: q.tests,
  };
  // §4.8: `solution` is omitted entirely until cleared — not null, not empty.
  if (row.state === "cleared") out.solution = q.starter.replace(/\/\/.*$/m, q.marker + ";");
  return out;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Split a string into ragged pieces, so a client that assumes lines breaks. */
function ragged(text: string): string[] {
  const out: string[] = [];
  let i = 0;
  while (i < text.length) {
    const n = 5 + Math.floor(Math.random() * 20);
    out.push(text.slice(i, i + n));
    i += n;
  }
  return out;
}

/**
 * A mock connection. One per `connect()`, so closing and reopening exercises
 * the client's reconnect-with-token path for real.
 */
/** The mock's XP ledger: one number, because there is one player here. */
let XP_TOTAL = 0;

export function mockTransport(): TransportFactory {
  return (h: TransportHandlers): Transport => {
    let closed = false;
    let address: string | null = null;
    let submitting = false;
    const seq = new Map<string, number>();

    const emit = (id: string | null, type: string, payload: unknown) => {
      if (closed) return;
      h.onMessage(encode(id, type, payload));
    };
    const ok = (id: string, type: string, payload: unknown) => emit(id, `${type}.ok`, payload);
    const err = (id: string, type: string, code: string, message: string, detail = {}) =>
      emit(id, `${type}.err`, { code, message, detail });

    const log = (attemptId: string, stream: "compile" | "stdout" | "stderr", text: string) => {
      for (const chunk of ragged(text)) {
        const key = `${attemptId}:${stream}`;
        const n = seq.get(key) ?? 0;
        seq.set(key, n + 1);
        emit(null, "run.log", { attempt_id: attemptId, stream, chunk, seq: n });
      }
    };

    setTimeout(() => {
      if (!closed) h.onOpen();
    }, 30);

    const handle = async (id: string, type: string, p: Record<string, unknown>) => {
      // §3.1: exactly four messages on an ANONYMOUS connection.
      const preauth = type === "ping" || type.startsWith("auth.");
      if (!address && !preauth) return err(id, type, "unauthorized", "log in first");

      switch (type) {
        case "ping":
          return ok(id, type, { t: now() });

        case "auth.challenge": {
          const claimed = String(p.address ?? "");
          if (!/^0x[0-9a-fA-F]{40}$/.test(claimed)) {
            return err(id, type, "bad_request", "that is not an address");
          }
          const nonce = randomHex(32);
          const expires = new Date(Date.now() + 120_000);
          const expiresAt = expires.toISOString().replace(/\.\d+Z$/, "Z");
          // §4.2: four lines, `\n` separated, no trailing newline.
          const message = [
            "Causewaybay Hacker login",
            `address: ${eip55(claimed)}`,
            `nonce: ${nonce}`,
            `expires: ${expiresAt}`,
          ].join("\n");
          world.nonces.set(nonce, {
            address: claimed.toLowerCase(),
            message,
            expires: expires.getTime(),
          });
          return ok(id, type, { nonce, message, expires_at: expiresAt });
        }

        case "auth.login": {
          // §3.1: a connection never goes back to anonymous; to change user
          // you open a new one (`handlers.rs`, `must_be_anonymous`).
          if (address !== null) {
            return err(
              id,
              type,
              "bad_request",
              "this connection is already authenticated; open a new one to change user",
            );
          }
          const claimed = String(p.address ?? "").toLowerCase();
          // Newest first, as the server does: the challenge a client just
          // asked for is the one it is most likely to have signed.
          const entry = [...world.nonces.entries()]
            .reverse()
            .find(([, n]) => n.address === claimed);
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
          const checksummed = eip55(claimed);
          const user: User = world.users.get(claimed) ?? {
            address: checksummed,
            // The same deterministic name the server gives a row nobody seeded
            // (`username::deterministic`), so the login preview and the mock agree.
            name: typeof p.name === "string" && p.name ? p.name : deterministicUsername(claimed),
            created_at: now(),
            last_seen_at: now(),
            settings: {},
            level: 1,
            xp: 0,
          };
          user.last_seen_at = now();
          world.users.set(claimed, user);
          const token = randomHex(24);
          world.tokens.set(token, claimed);
          progressFor(claimed);
          saveWorld();
          return ok(id, type, { token, user, position: world.positions.get(claimed) ?? null });
        }

        case "auth.resume": {
          const sent = String(p.token ?? "");
          const owner = world.tokens.get(sent);
          if (!owner) return err(id, type, "unauthorized", "that session is gone");
          address = owner;
          // §4.4: the server rotates on use. A client that stores the token it
          // sent rather than the one it got will fail on the *second* resume,
          // which is exactly the kind of bug a lenient mock hides.
          world.tokens.delete(sent);
          const rotated = randomHex(24);
          world.tokens.set(rotated, owner);
          saveWorld();
          return ok(id, type, {
            token: rotated,
            user: world.users.get(owner)!,
            position: world.positions.get(owner) ?? null,
          });
        }

        case "profile.update": {
          const user = world.users.get(address!)!;
          if (typeof p.name === "string") user.name = p.name;
          // §4.5: a partial settings object replaces the whole thing.
          if (p.settings && typeof p.settings === "object") {
            user.settings = p.settings as Record<string, unknown>;
          }
          saveWorld();
          return ok(id, type, { user });
        }

        case "world.lands": {
          const rows = progressFor(address!);
          const cleared = QUESTS.filter((q) => rows.get(q.id)!.state === "cleared");
          const stars = cleared.reduce((n, q) => n + rows.get(q.id)!.stars, 0);
          return ok(id, type, {
            lands: [
              {
                land: "rust",
                categories: [
                  {
                    category: "basic",
                    total: QUESTS.length,
                    cleared: cleared.length,
                    stars,
                    open: true,
                  },
                  { category: "advanced", total: 0, cleared: 0, stars: 0, open: false },
                  { category: "hacker", total: 0, cleared: 0, stars: 0, open: false },
                ],
              },
              // The other three lands exist and are empty: enough for the lands
              // screen to draw four plates and for a click on any of them to
              // reach a map that says "no streets here yet".
              ...(["go", "cpp", "python"] as const).map((land) => ({
                land,
                categories: [
                  { category: "basic" as const, total: 0, cleared: 0, stars: 0, open: false },
                  { category: "advanced" as const, total: 0, cleared: 0, stars: 0, open: false },
                  { category: "hacker" as const, total: 0, cleared: 0, stars: 0, open: false },
                ],
              })),
            ],
          });
        }

        case "world.map": {
          const land = p.land as string;
          const category = p.category as string;
          if (land !== "rust" || category !== "basic") {
            return ok(id, type, { land, category, nodes: [], edges: [] });
          }
          const edges: Array<[string, string]> = [];
          for (const q of QUESTS) for (const r of q.requires) edges.push([r, q.id]);
          world.positions.set(address!, {
            land: land as Land,
            category: category as Category,
            quest_id: null,
            updated_at: now(),
          });
          saveWorld();
          return ok(id, type, { land, category, nodes: mapNodes(address!), edges });
        }

        case "quest.get": {
          const q = QUESTS.find((x) => x.id === p.quest_id);
          if (!q) return err(id, type, "not_found", "no such quest");
          const row = progressFor(address!).get(q.id)!;
          world.positions.set(address!, {
            land: q.land as Land,
            category: q.category as Category,
            quest_id: q.id,
            updated_at: now(),
          });
          saveWorld();
          return ok(id, type, { quest: publicQuest(q, row) });
        }

        case "quest.reset": {
          const q = QUESTS.find((x) => x.id === p.quest_id);
          if (!q) return err(id, type, "not_found", "no such quest");
          return ok(id, type, { starter: q.starter });
        }

        case "quest.hint": {
          const q = QUESTS.find((x) => x.id === p.quest_id);
          if (!q) return err(id, type, "not_found", "no such quest");
          const i = Number(p.index ?? 0);
          if (!Number.isInteger(i) || i < 0 || i >= q.hints_total) {
            return err(id, type, "not_found", "no hint at that index");
          }
          const row = progressFor(address!).get(q.id)!;
          row.hints = Math.max(row.hints, i + 1);
          saveWorld();
          return ok(id, type, {
            hint: q.hints[i],
            index: i,
            total: q.hints_total,
            hints_used: row.hints,
          });
        }

        case "quest.submit": {
          const q = QUESTS.find((x) => x.id === p.quest_id);
          if (!q) return err(id, type, "not_found", "no such quest");
          // §3.2: one in flight per connection.
          if (submitting) return err(id, type, "busy", "an attempt is already running");
          if (p.lang !== q.land)
            return err(id, type, "bad_request", "lang disagrees with the quest");
          const source = String(p.source ?? "");
          if (source.length > 262144) return err(id, type, "bad_request", "source over 256 KiB");

          submitting = true;
          const rows = progressFor(address!);
          const row = rows.get(q.id)!;
          row.attempts++;
          const attemptId = "att_" + randomHex(8);
          const t0 = Date.now();
          const stage = (s: string, extra = {}) =>
            emit(null, "run.stage", {
              attempt_id: attemptId,
              stage: s,
              elapsed_ms: Date.now() - t0,
              ...extra,
            });

          stage("queued", { queued: 0 });
          await sleep(120);
          stage("compiling");
          log(attemptId, "compile", "   Compiling attempt v0.1.0 (mock)\n");
          await sleep(220);
          log(attemptId, "compile", "rustc --edition 2021 -O main.rs -o prog\n");
          await sleep(180);

          const broken = !/fn\s+main\s*\(/.test(source);
          let attempt: Attempt;
          let xp: XpGain | undefined;
          if (broken) {
            const stderr = "error[E0601]: `main` function not found in crate `main`\n";
            log(attemptId, "stderr", stderr);
            row.fails++;
            attempt = {
              id: attemptId,
              quest_id: q.id,
              verdict: "compile_error",
              tests_passed: 0,
              tests_total: 1 + q.tests.hidden_count,
              compile_ms: Date.now() - t0,
              run_ms: 0,
              exit_code: 1,
              stderr,
              cases: [],
              mistakes: [
                {
                  kind: "syntax",
                  code: "E0601",
                  message: "`main` function not found",
                  line: 1,
                  col: 1,
                },
              ],
              stars: row.stars,
              cleared: false,
              created_at: now(),
            };
          } else {
            stage("running");
            await sleep(180);
            const passed = source.includes(q.marker);
            const got = passed ? q.expect : "\n";
            log(attemptId, "stdout", got);
            stage("judging");
            await sleep(120);

            const first = passed && row.state !== "cleared";
            if (!passed) row.fails++;
            const stars: 0 | 1 | 2 | 3 = !passed
              ? row.stars
              : row.fails === 0 && row.hints === 0
                ? 3
                : row.fails <= 2 || row.hints > 0
                  ? 2
                  : 1;
            let unlocked: string[] = [];
            if (passed) {
              row.state = "cleared";
              row.stars = Math.max(row.stars, stars) as 0 | 1 | 2 | 3;
              unlocked = unlockedBy(rows, q.id);
            }
            saveWorld();

            attempt = {
              id: attemptId,
              quest_id: q.id,
              verdict: passed ? "accepted" : "wrong_answer",
              tests_passed: passed ? 1 + q.tests.hidden_count : 0,
              tests_total: 1 + q.tests.hidden_count,
              compile_ms: 480,
              run_ms: 12,
              exit_code: 0,
              stderr: "",
              cases: [
                {
                  name: q.tests.visible[0].name,
                  passed,
                  visible: true,
                  stdin: q.tests.visible[0].stdin,
                  expect: q.tests.visible[0].expect,
                  got,
                },
                ...Array.from({ length: q.tests.hidden_count }, (_, i) => ({
                  name: `hidden-${i + 1}`,
                  passed,
                  visible: false,
                })),
              ],
              mistakes: passed
                ? []
                : [
                    {
                      kind: "wrong-answer",
                      code: null,
                      message: "output did not match",
                      line: null,
                      col: null,
                    },
                  ],
              stars: row.stars,
              // §5.4: `cleared` is "did *this* submission clear the node".
              cleared: first,
              created_at: now(),
            };
            // §4.9: the XP this submit was worth, on the server's own curve
            // (`awards.rs`): 25 × stars × difficulty × the category weight,
            // once, on the first clear.
            const weight = q.category === "hacker" ? 3 : q.category === "advanced" ? 2 : 1;
            const gained = first ? 25 * row.stars * q.difficulty * weight : 0;
            XP_TOTAL += gained;
            const levelOf = (xp: number) => {
              let level = 1;
              while ((100 * level * (level + 1)) / 2 <= xp) level++;
              return level;
            };
            const xpAt = (level: number) => (100 * (level - 1) * level) / 2;
            const level = levelOf(XP_TOTAL);
            xp = {
              gained,
              total: XP_TOTAL,
              level,
              into_level: XP_TOTAL - xpAt(level),
              for_next: xpAt(level + 1) - xpAt(level),
              level_up: level > levelOf(XP_TOTAL - gained),
            };

            if (passed) {
              emit(null, "progress.update", {
                quest_id: q.id,
                state: "cleared",
                stars: row.stars,
                cleared_total: QUESTS.filter((x) => rows.get(x.id)!.state === "cleared").length,
                unlocked,
                xp,
              });
              if (first) {
                emit(null, "award", {
                  kind: "stamp",
                  id: "cleared",
                  title: "STREET CLEARED",
                  detail: { quest_id: q.id },
                });
              }
            }
          }
          saveWorld();
          submitting = false;
          return ok(id, type, { attempt, xp });
        }

        case "stats.summary": {
          const rows = progressFor(address!);
          const cleared = QUESTS.filter((q) => rows.get(q.id)!.state === "cleared");
          const attempts = [...rows.values()].reduce((n, r) => n + r.attempts, 0);
          return ok(id, type, {
            cleared: cleared.length,
            total: QUESTS.length,
            attempts,
            accuracy: attempts === 0 ? 0 : cleared.length / attempts,
            streak_days: cleared.length > 0 ? 1 : 0,
            stars: cleared.reduce((n, q) => n + rows.get(q.id)!.stars, 0),
            by_land: [{ land: "rust", cleared: cleared.length, total: QUESTS.length }],
          });
        }

        case "stats.mistakes":
          return ok(id, type, { mistakes: [] });
        // An empty list is the normal answer for a player who has failed
        // nothing (§4.14c) — which is every player of the mock.
        case "stats.weakest":
          return ok(id, type, { weakest: [] });
        case "stats.history":
          return ok(id, type, { attempts: [] });
        case "search.query":
          return ok(id, type, { hits: [], mode: p.mode ?? "unified", took_ms: 1 });

        default:
          // Not in the catalogue. The real server answers `not_found` with
          // this message (`ws.rs`); the mock does the same rather than staying
          // silent, so a typo in a scene surfaces here instead of as a hang.
          return err(id, type, "not_found", `no message type '${type}'`);
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
            detail: { supported: [1] },
          });
        }
        if (f.id === null) return; // clients do not send events
        // Never echo a payload. A login frame carries a signature, and a mock
        // that logged what it received is exactly how a secret ends up in a
        // console. Nothing here logs a frame body.
        void handle(f.id, f.type, f.payload as Record<string, unknown>);
      },
      close() {
        closed = true;
        h.onClose("mock closed");
      },
    };
  };
}
