# Causewaybay Hacker — Shared Specification

> **This document is the contract.** The backend, the frontend, the test suite
> and the quest content are built against it, in parallel, by people who cannot
> see each other's code. Where this file and an implementation disagree, this
> file is right and the implementation is a bug.
>
> Changes go through the PM. Nobody edits a section they do not own without
> saying so in `docs/decisions.md`.

One server owns the truth. The browser owns the view and the keyboard, and
nothing else.

```
   browser                          server (Rust)                host
   ───────                          ─────────────                ────
   vite + ts + three.js  ──ws──▶    axum + tokio         ──▶     rustc / cargo
   scenes, sprites, input   json    sqlite (bm25+vec)    ──▶     go build / go test
   key derivation (local)           ~/.causewaybayhacker
```

## 0. The shape of the thing

A 16-bit trainer. A rust coder in Causeway Bay lost their craft to vibe coding —
Skynet's plan all along — and takes it back one street at a time.

* Two **lands**: `rust`, `go`. The player picks one; the other is still there.
* Three **categories** per land: `basic` (grammar), `advanced` (threads,
  mutexes, lifetimes, channels), `hacker` (HackerRank-style timed quests).
* Each category is a **map** — a Super Mario World overworld of numbered nodes
  joined by paths. Clear a node and it is stamped `CLEARED`, for good.
* A node holds one **quest**. A quest is code the player writes, that the server
  compiles and runs against hidden tests.
* Everything the player types is kept. The mistakes are the point: the server
  classifies them by the compiler's own error identity and the **AI mode**
  feeds them back until they stop happening.

---

## 1. Storage

Root directory (the "home"), in precedence order:

1. `--home <PATH>` flag on the server binary
2. `CAUSEWAYBAY_HACKER_HOME` environment variable
3. `~/.causewaybayhacker`

Created on demand with mode `0700`; every file inside is created `0600`. The
convention is the one `CausewaybayWallet` uses, for the same reason: the
directory holds a user's own work and nothing else on the machine needs it.

```
~/.causewaybayhacker/
├── hacker.db                       sqlite: users, progress, attempts, quests, vectors
├── hacker.db-wal                   (WAL mode; do not delete while the server runs)
├── content/                        quest packs the server loaded, by pack id
├── users/
│   └── <address>/                  lowercase 0x-hex, 42 chars — see §3.4
│       ├── profile.json            display name, chosen land, settings
│       └── attempts/
│           └── <attempt_id>/       one directory per submission, kept
│               ├── main.rs | main.go
│               ├── stdout.txt
│               ├── stderr.txt
│               └── result.json
├── build/                          scratch; safe to delete when the server is down
│   ├── go/{gocache,gomodcache}
│   └── rust/{cargo-home,target}
└── logs/server.jsonl               one JSON object per line
```

**The server writes nothing outside the home.** No `/tmp`, no project
directory; an attempt that needs scratch space gets a directory under `build/`.

That is a statement about *the server*, and not about the code it runs. A
submission can write wherever the user can — §5.3 says plainly that this is not
a sandbox, and the rlimits and the timeout do not change it. An earlier version
of this paragraph did not draw that line and read as a containment guarantee
the implementation has never made. If you want containment, do not expose the
port (§5.3) — the file system is not where it comes from.

### 1.1 The LÖVE client's own store

`~/.causewaybayhacker` is the **server's**. The LÖVE desktop client is a
separate program that may be talking to a server on another machine, so it
keeps its own state in `~/.causewaybaylove2d` — `0700` directory, `0600` files,
append-only JSONL, state derived by replaying the log.

Resolved in the same precedence order `CausewaybayWallet` uses, because a
family of programs that each invent their own is a family nobody can script:

1. `--home <PATH>`
2. the `CWBH_LOVE2D_HOME` environment variable
3. `~/.causewaybaylove2d`

The name follows the wallet's shape — `.causewaybay` plus the component — and
it was once `.causewaybayhackerlove2d`. **A store found at the old path is
migrated once and the old directory left alone**, the same way the first
version migrated out of LÖVE's own save directory. Somebody is playing with a
session and a cleared map in there; a rename that silently starts them fresh
would be a self-inflicted version of the thing this project warns players
about.

The JSONL rules, in full, so this section does not depend on another document:

* One compact JSON object per line, UTF-8, `\n` terminated, no trailing spaces.
* **Append-only.** State is derived by replaying every line in order; later
  records supersede earlier ones. A crash can at worst lose the last, partial
  line — and an append that finds the previous line unterminated **starts a
  fresh one**, so a torn write costs that line and not the next one too.
* Every record carries `schema` (currently `1`), `kind`, and an RFC3339 UTC
  timestamp.
* A malformed or unparsable line is **skipped with a warning** rather than
  aborting the replay. A line whose `schema` is greater than the reader's is
  skipped.
* Removing something — forgetting a session — is a record (`session.clear`),
  not an edit to an earlier line.

These are `CausewaybayWallet`'s conventions, and its `rustcli/core/src/store.rs`
is the reference implementation if a detail is ever in doubt.

It holds only what a client owns: the session token, the chosen server, the
orientation and fullscreen pins, the code-size step, and where each map was
left. **No key
material, ever** — not the mnemonic, not the private key, not the seed.

**The token is stored per server.** A session token is minted by one server
and means nothing to another; a client that keeps one token and points it at a
new address will send a stranger's credential and be told `unauthorized` for
reasons the player cannot see. Key it by the server URL.

**Attempts are never deleted by the server.** They are the training data for
§7. `hacker prune` (a CLI subcommand) is the only thing that removes them, and
only when the user asks.

---

## 2. The database

SQLite, WAL mode, `foreign_keys=ON`. `rusqlite` with the `bundled` and `fts5`
features — the bundled amalgamation, so the build does not depend on whatever
SQLite the host happens to ship. (The host's own SQLite is 3.51.2 with FTS5,
but that is not a thing to rely on.)

Schema version lives in `PRAGMA user_version`. Migrations are forward-only,
numbered `backend/core/migrations/NNNN_name.sql`, applied in order at startup
inside one transaction.

### 2.1 DDL

```sql
-- ---------- identity ----------
CREATE TABLE users (
  address       TEXT PRIMARY KEY,          -- lowercase 0x hex, 42 chars (§3.4)
  address_eip55 TEXT NOT NULL,             -- the checksummed form, for display
  name          TEXT NOT NULL,             -- freely chosen; NOT unique
  created_at    TEXT NOT NULL,             -- RFC3339 UTC
  last_seen_at  TEXT NOT NULL,
  settings      TEXT NOT NULL DEFAULT '{}' -- JSON blob, frontend-owned
);

-- ---------- content ----------
CREATE TABLE quests (
  id            TEXT PRIMARY KEY,          -- 'rust.basic.03.shadowing' (§4.1)
  pack          TEXT NOT NULL,             -- content pack that supplied it
  land          TEXT NOT NULL CHECK (land IN ('rust','go')),
  category      TEXT NOT NULL CHECK (category IN ('basic','advanced','hacker')),
  node          INTEGER NOT NULL,          -- position on the map, 1-based
  title         TEXT NOT NULL,
  brief         TEXT NOT NULL,             -- markdown shown in the quest panel
  story         TEXT NOT NULL DEFAULT '',  -- the in-world line the NPC says
  difficulty    INTEGER NOT NULL,          -- 1..5, drives the star display
  time_limit_s  INTEGER,                   -- NULL = untimed; set for 'hacker'
  starter       TEXT NOT NULL,             -- code the editor opens with
  solution      TEXT NOT NULL,             -- reference answer, never sent to a
                                           -- client that has not cleared it
  hints         TEXT NOT NULL DEFAULT '[]',-- JSON array of strings
  concepts      TEXT NOT NULL DEFAULT '[]',-- JSON array: 'ownership','channels'
  tests         TEXT NOT NULL,             -- JSON, see §5.2
  checksum      TEXT NOT NULL,             -- sha256 of the pack's quest source
  UNIQUE (land, category, node)
);

CREATE TABLE quest_deps (                  -- map edges: what unlocks what
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  requires_id   TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  PRIMARY KEY (quest_id, requires_id)
);

-- ---------- progress ----------
CREATE TABLE progress (
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  state         TEXT NOT NULL CHECK (state IN ('locked','open','cleared')),
                -- 'locked' is legacy: every node is playable (PROTOCOL §4.7).
                -- The column keeps the value so an old row still reads.
  stars         INTEGER NOT NULL DEFAULT 0,   -- 0..3, see §6.3
  best_ms       INTEGER,                      -- fastest clear, wall clock
  attempts      INTEGER NOT NULL DEFAULT 0,
  hints_used    INTEGER NOT NULL DEFAULT 0,
  opened_at     TEXT,                    -- PROTOCOL §4.8b: when the clock started
  first_clear_at TEXT,
  updated_at    TEXT NOT NULL,
  PRIMARY KEY (address, quest_id)
);

-- ---------- every attempt, pass or fail ----------
CREATE TABLE attempts (
  id            TEXT PRIMARY KEY,          -- 'att_' + 16 hex (§4.2)
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  lang          TEXT NOT NULL CHECK (lang IN ('rust','go')),
  mode          TEXT NOT NULL DEFAULT 'submit'
                  CHECK (mode IN ('run','submit')),  -- PROTOCOL §4.9b
  source        TEXT NOT NULL,             -- the whole file, verbatim
  verdict       TEXT NOT NULL CHECK (verdict IN
                  ('accepted','wrong_answer','compile_error','runtime_error',
                   'timeout','output_limit','internal_error')),
  compile_ms    INTEGER NOT NULL DEFAULT 0,
  run_ms        INTEGER NOT NULL DEFAULT 0,
  exit_code     INTEGER,
  stdout_bytes  INTEGER NOT NULL DEFAULT 0,
  stderr        TEXT NOT NULL DEFAULT '',  -- truncated to 64 KiB
  tests_passed  INTEGER NOT NULL DEFAULT 0,
  tests_total   INTEGER NOT NULL DEFAULT 0,
  within_limit  INTEGER,                 -- PROTOCOL §4.8b; NULL when untimed
  created_at    TEXT NOT NULL
);
CREATE INDEX attempts_by_user ON attempts(address, created_at DESC);
CREATE INDEX attempts_by_quest ON attempts(address, quest_id, created_at DESC);

-- ---------- what went wrong, in the compiler's own words ----------
CREATE TABLE mistakes (
  id            INTEGER PRIMARY KEY,
  attempt_id    TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL,             -- taxonomy slug, §7.1
  code          TEXT,                      -- 'E0382', 'go:undefined', NULL
  message       TEXT NOT NULL,             -- the normalized one-line message
  line          INTEGER,
  col           INTEGER,
  created_at    TEXT NOT NULL
);
CREATE INDEX mistakes_by_user ON mistakes(address, kind, created_at DESC);

-- a rolled-up view the AI mode reads, one row per (user, kind)
CREATE TABLE mistake_stats (
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  kind          TEXT NOT NULL,
  count         INTEGER NOT NULL DEFAULT 0,
  last_at       TEXT NOT NULL,
  cleared_since INTEGER NOT NULL DEFAULT 0, -- consecutive clean *submits* (§7.2)
  PRIMARY KEY (address, kind)
);

-- ---------- the playground (PROTOCOL §4.9c) ----------
-- Snippets are kept; playground *runs* are not. A run has no quest, so it has
-- no concepts, so a mistake from it could never be joined to a drill — it
-- would be dead weight in the table §7 derives the whole curriculum from.
CREATE TABLE snippets (
  id            TEXT PRIMARY KEY,          -- 'pg_' + 16 hex
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  lang          TEXT NOT NULL CHECK (lang IN ('rust','go')),
  source        TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);
CREATE INDEX snippets_by_user ON snippets(address, updated_at DESC);

-- ---------- AI drill sessions ----------
CREATE TABLE drills (
  id            TEXT PRIMARY KEY,          -- 'drl_' + 16 hex
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  mode          TEXT NOT NULL CHECK (mode IN ('repeat','weakness','spaced')),
  plan          TEXT NOT NULL,             -- JSON array of quest ids, in order
  cursor        INTEGER NOT NULL DEFAULT 0,
  created_at    TEXT NOT NULL,
  finished_at   TEXT
);

-- ---------- search ----------
CREATE VIRTUAL TABLE quest_fts USING fts5(
  title, brief, concepts, story,
  content='quests', content_rowid='rowid',
  tokenize='porter unicode61'
);
-- kept in sync by AFTER INSERT/UPDATE/DELETE triggers on quests.

CREATE TABLE quest_vec (
  quest_id      TEXT PRIMARY KEY REFERENCES quests(id) ON DELETE CASCADE,
  dim           INTEGER NOT NULL,
  model         TEXT NOT NULL,             -- embedder id, §8.2
  vec           BLOB NOT NULL              -- dim * f32, little-endian
);

-- ---------- sessions ----------
CREATE TABLE sessions (
  token_hash    TEXT PRIMARY KEY,          -- sha256 of the bearer token
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  created_at    TEXT NOT NULL,
  expires_at    TEXT NOT NULL
);
```

### 2.2 Rules

* Every timestamp is RFC3339 UTC with seconds: `2026-09-11T04:12:33Z`.
* `attempts.source` is stored verbatim, including trailing whitespace. It is
  the record of what the player actually typed.
* **A `run` is an attempt too.** `mode` separates the two: only `submit` rows
  move `progress`, count toward a node's `attempts`, or enter
  `stats.summary.accuracy`. Both kinds feed `mistakes` — the errors a player
  makes while iterating are the truest record of what they are struggling
  with, and SPEC §7's drills would otherwise train on a tidied-up version of
  the week. A query that forgets to filter on `mode` will overstate how often
  someone fails; a query that filters it out of `mistakes` will understate
  what they need to practise.
* `attempts.stderr` is truncated at 64 KiB with a trailing
  `\n…truncated N bytes` line. The untruncated copy is on disk (§1).
* A quest whose `checksum` changed keeps its `progress` rows. Content is edited
  constantly; progress is not thrown away for a typo fix.

---

## 3. Identity and login

The user id **is** a wallet address. The name is decoration and may collide.

### 3.1 Derivation — in the browser, never on the wire

The client derives locally with `@scure/bip39`, `@scure/bip32` and
`@noble/curves/secp256k1`:

```
mnemonic ──BIP-39──▶ seed ──BIP-32──▶ m/44'/60'/0'/0/0 ──▶ secp256k1 privkey
                                                        └─▶ keccak256(pubkey[1..])[12..] ──▶ address
```

The path and the address rendering are **exactly** `CausewaybayWallet`'s EVM
account 0: `m/44'/60'/0'/0/i`, EIP-55 checksummed. The same mnemonic must
produce the same address in both programs. A drift here reads to the user as
losing their account. There is a conformance test for this in §9.

A raw private key (`0x` + 64 hex) is accepted as an alternative to a mnemonic
and skips straight to the last arrow.

> **The mnemonic and the private key never leave the browser.** Not over the
> websocket, not in a log, not in `localStorage` unencrypted, not "just on
> localhost". The only thing that crosses the wire is a signature.

### 3.2 Challenge–response

1. Client sends `auth.challenge` with its address.
2. Server returns a `nonce` (32 random bytes, hex), an `expires_at` 120 seconds
   out, and the exact `message` string to sign:

   ```
   Causewaybay Hacker login
   address: 0xAbC…                (EIP-55)
   nonce: <64 hex>
   expires: 2026-09-11T04:14:33Z
   ```

3. Client signs `keccak256("\x19Ethereum Signed Message:\n" + len + message)`
   (EIP-191) and sends `auth.login` with the 65-byte `r||s||v` signature, hex.
4. Server recovers the address with `k256`, compares it case-insensitively to
   the claimed one, checks the nonce is unused and unexpired, burns the nonce,
   upserts the user, mints a session token.

Nonces live in memory with their expiry, and are single-use. A replay after
`expires_at` is `auth_expired`; a replay inside it is `auth_nonce_used`.

### 3.3 Sessions

The token is 32 random bytes, base64url. The server stores only its sha256.
Default lifetime 30 days, refreshed on use. `auth.resume` trades a stored token
for a live connection without touching the key material again — which is what
lets the client keep the key in memory only, and forget it on reload.

### 3.4 Address normalization

`users.address` — and the directory name under `users/` — is **lowercase**.
The checksummed form is `address_eip55`, for display only. Anything that looks
up a user lowercases first. Two spellings of one wallet must never become two
players; on a case-insensitive filesystem they would silently share a
directory while having two database rows, which is worse.

### 3.5 Multi-user

The server holds many users at once and never mixes them: every query that
touches `progress`, `attempts`, `mistakes` or `drills` is filtered by the
address on the *connection's session*, never by an address in the payload. A
payload that carries an address is ignored, not trusted.

---

## 4. Identifiers

### 4.1 Quest ids

`<land>.<category>.<node:02d>.<slug>` — `rust.basic.03.shadowing`,
`go.hacker.07.two-sum`. Stable forever; the slug is part of it so a reordered
map does not renumber someone's cleared list into nonsense. If a node moves,
the `node` column changes and the id does not.

### 4.2 Other ids

`att_` / `drl_` / `pack_` followed by 16 lowercase hex characters, from a CSPRNG.

---

## 5. Running code

### 5.1 What the runner does

One attempt, one directory under `~/.causewaybayhacker/build/<lang>/<attempt_id>/`.

**Rust**

```
rustc --edition 2021 -O --error-format=json main.rs -o prog
```

A quest that needs `cargo` (dependencies, `#[test]`) sets `harness: "cargo"` in
its test spec and gets a minimal generated `Cargo.toml`; `CARGO_HOME` and
`CARGO_TARGET_DIR` point into `build/rust/` so the first run is the slow one and
the rest are not.

**Go**

```
go build -o prog main.go        # or: go test -run . -json
```

with `GOCACHE`, `GOMODCACHE`, `GOFLAGS=-mod=mod`, `GOPATH` all under
`build/go/`, and `GOPROXY=off` — a quest does not fetch the internet.

### 5.2 The test spec

`quests.tests` is JSON:

```json
{
  "harness": "stdio",            // "stdio" | "cargo" | "gotest"
  "timeout_ms": 5000,
  "compile_timeout_ms": 30000,
  "max_stdout_bytes": 262144,
  "cases": [
    { "name": "sample", "stdin": "3\n1 2 3\n", "expect": "6\n", "visible": true },
    { "name": "big",    "stdin": "…",          "expect": "…",   "visible": false }
  ],
  "match": "trim"                // "exact" | "trim" | "tokens" | "float:1e-6"
}
```

* `visible: true` cases are shown to the player with their expected output.
  Hidden cases report pass/fail and the case name, never the data.
* `match: "trim"` strips trailing whitespace per line and at the end. This is
  the default because "your answer is right but has a trailing newline" is not
  a lesson worth teaching.

### 5.3 Limits, and what this is not

Every run gets: a hard wall-clock timeout (`timeout_ms`, killed with SIGKILL
after a SIGTERM grace of 500 ms), an output byte cap, a stripped environment
(`PATH`, `HOME` pointed at the build dir, the toolchain vars above, nothing
else), no inherited stdin beyond the case's, and `setrlimit` for address space
(1 GiB), file size (64 MiB) and processes where the platform provides it.

**The timeout is the runner's clock, not the submission's.** Output is drained
on its own threads, and they are abandoned half a second after the kill.
Everything a submission spawns inherits the same stdout pipe, so waiting for
that pipe to close is waiting for a process the runner may not be able to kill
— a submission that spawned `sleep 30` used to choose its own wall clock that
way, and returned at 6.4 s against a 5 s timeout.

**What the kill reaches.** The child is put in its own process group and the
group is killed — SIGTERM, 500 ms, SIGKILL — which takes every child that
stayed in the group, the ordinary fork bomb included. But a process can *leave*
a group (`setsid`, `setpgid`, `Command::process_group(0)`), and a group kill
cannot reach one that has. So the runner also samples the process table every
100 ms for the life of the attempt, recording every process that was, at that
moment, in the submission's group or a descendant of something already
recorded. On every exit — clean, output-capped or timed out — everything on
that list that is still alive is stopped and then killed by pid, with each
recorded start time checked first so that a recycled pid is never signalled.
A fork bomb whose children each leave the group is stopped by this; a
submission that exits cleanly having left `sleep 120` behind is too.

**What it does not reach.** Said plainly, because an earlier version of this
paragraph claimed a containment the implementation did not have:

* A process that both leaves the group **and** is orphaned between two
  samples. Once its parent has exited the kernel keeps no link back to the
  attempt, and macOS will not report a session id to a non-root process, so
  there is no third key left to match on. It survives, and
  `backend/runner/tests/limits.rs` contains a test that says so out loud.
* Anything at all on a platform that is neither macOS nor Linux, where the
  sweep is a no-op and the group kill is the whole of it.

This is a best effort, not a boundary. A cgroup or a jail would be a boundary;
this project has deliberately not built one, which is what the next paragraph
is about.

> **This is not a sandbox.** Causewaybay Hacker compiles and runs code you
> typed, on your machine, as you. It is a single-trusted-user local trainer.
> Do not point it at the internet, and do not paste in code you would not run
> in a shell. The README says this in the same words.

### 5.4 Streaming

Compilation and run output stream to the client as `run.log` events while the
attempt is in flight (§6.2), so the player watches `rustc` think instead of a
spinner. The final verdict arrives as the response to the original request.

---

## 6. The wire

> **[`PROTOCOL.md`](PROTOCOL.md) is the authority for the wire.** This section
> is the summary; where the two differ, `PROTOCOL.md` is right. Every client —
> the browser, the LÖVE desktop client, the smoke harness — implements it, and
> its §8 conformance checklist is what "the client works" means.

WebSocket at `ws://127.0.0.1:5390/ws`. Text frames. One JSON object per frame.
The HTTP server also serves the built frontend from `/` and the art from
`/art/…`, so there is one port and no CORS.

### 6.1 The envelope

Every frame, both directions:

```json
{ "v": 1, "id": "c-42", "type": "quest.submit", "payload": { } }
```

* `v` — protocol version, currently `1`. A frame with an unknown `v` is
  answered with `proto_version` and the connection stays open.
* `id` — correlation. The client generates `c-<n>`; the server echoes it on the
  reply. A **server-initiated event** has `id: null`.
* `type` — dotted, lowercase. A reply is `<type>.ok` or `<type>.err`.
* `payload` — object, never a bare value, never absent (use `{}`).

An error payload is always:

```json
{ "code": "auth_expired", "message": "the challenge expired", "detail": {} }
```

Codes are a closed set: `proto_version`, `bad_request`, `unauthorized`,
`auth_expired`, `auth_nonce_used`, `auth_bad_signature`, `not_found`, `locked`,
`rate_limited`, `busy`, `unavailable`, `internal`. See PROTOCOL.md §3.3 —
in particular why an unbuilt feature is `unavailable` and never `internal`,
and why it must not write an `attempt` row.

### 6.2 Message catalogue

Client → server, and the reply payload:

| type | payload | `.ok` payload |
| --- | --- | --- |
| `auth.challenge` | `{address}` | `{nonce, message, expires_at}` |
| `auth.login` | `{address, signature}` | `{token, user}` |
| `auth.resume` | `{token}` | `{token, user}` |
| `profile.update` | `{name?, settings?}` | `{user}` |
| `world.lands` | `{}` | `{lands:[{land, categories:[{category, total, cleared}]}]}` |
| `world.map` | `{land, category}` | `{nodes:[MapNode], edges:[[from,to]]}` |
| `quest.get` | `{quest_id}` | `{quest}` — no `solution` unless cleared |
| `quest.submit` | `{quest_id, source, lang}` | `{attempt}` |
| `quest.hint` | `{quest_id, index}` | `{hint, hints_used}` |
| `quest.reset` | `{quest_id}` | `{starter}` |
| `search.query` | `{q, mode, filters?, limit?}` | `{hits:[SearchHit]}` |
| `stats.summary` | `{}` | `{cleared, attempts, accuracy, streak, by_land}` |
| `stats.mistakes` | `{limit?}` | `{mistakes:[MistakeStat]}` |
| `stats.history` | `{quest_id?, limit?}` | `{attempts:[AttemptBrief]}` |
| `ai.plan` | `{mode, land?, size?}` | `{drill}` |
| `ai.next` | `{drill_id}` | `{quest, position, total}` |
| `ai.finish` | `{drill_id}` | `{summary}` |
| `ping` | `{}` | `{t}` |

Server → client, unsolicited (`id: null`):

| type | payload |
| --- | --- |
| `run.log` | `{attempt_id, stream:"compile"\|"stdout"\|"stderr", chunk}` |
| `run.stage` | `{attempt_id, stage:"queued"\|"compiling"\|"running"\|"judging"}` |
| `progress.update` | `{quest_id, state, stars, cleared_total}` |
| `award` | `{kind, title, detail}` — a stamp, a badge, a level-up |
| `server.bye` | `{reason}` |

### 6.3 Shared shapes

```ts
type MapNode = {
  quest_id: string; node: number; title: string; difficulty: 1|2|3|4|5;
  state: "locked" | "open" | "cleared"; stars: 0|1|2|3;
  x: number; y: number;           // map position, 0..1 of the map image
  kind: "quest" | "boss" | "gate";
};

type Attempt = {
  id: string; verdict: Verdict; tests_passed: number; tests_total: number;
  compile_ms: number; run_ms: number; stderr: string;
  cases: { name: string; passed: boolean; visible: boolean;
           stdin?: string; expect?: string; got?: string }[];
  mistakes: { kind: string; code: string | null; message: string;
              line: number | null }[];
  stars: 0|1|2|3; cleared: boolean;
};

type SearchHit = {
  quest_id: string; title: string; snippet: string;
  score: number; bm25: number | null; cosine: number | null;
};

type MistakeStat = {
  kind: string; label: string; count: number; last_at: string;
  cleared_since: number; example_quest_id: string | null;
};
```

**Stars** (`progress.stars`): 3 — cleared with no failed attempt and no hint;
2 — cleared with hints or ≤2 failed attempts; 1 — cleared. The map draws them.

### 6.4 Connection rules

* A connection is anonymous until `auth.login` or `auth.resume` succeeds.
  Anything else before that is `unauthorized`, except `ping` and
  `auth.challenge`.
* One in-flight `quest.submit` per connection. A second is `busy`.
* The server pings every 30 s; a connection that misses two is dropped.
* A reconnect resumes with the token; nothing in the game is lost by a reload,
  because nothing in the game lives in the browser.

---

## 7. Mistakes

### 7.1 The taxonomy

A mistake is classified by the compiler's own identity for it, not by a
regex on prose. Rust: `--error-format=json` gives `code.code` (`E0382`) and a
span. Go: the message text is matched against a small table and normalized.

Kinds (the slug stored in `mistakes.kind`), each mapped from one or more codes:

| kind | rust | go |
| --- | --- | --- |
| `borrow-after-move` | E0382, E0505 | — |
| `borrow-conflict` | E0499, E0502 | — |
| `lifetime` | E0106, E0597, E0621, E0373 | — |
| `type-mismatch` | E0308 | `cannot use … as … value` |
| `unknown-name` | E0425, E0433 | `undefined: X` |
| `missing-trait` | E0277 | — |
| `unused` | unused_variables, unused_imports | `declared and not used`, `imported and not used` |
| `mutability` | E0596, E0594 | — |
| `nil-deref` | — | runtime `nil pointer dereference` |
| `index-range` | runtime `index out of bounds` | runtime `index out of range` |
| `data-race` | — | `go test -race` report |
| `deadlock` | — | `all goroutines are asleep` |
| `unhandled-error` | E0277 *discriminated*, see below | `err` assigned and not checked |
| `syntax` | any parse error | any parse error |
| `wrong-answer` | — | — (verdict, not a compiler code) |
| `timeout` | — | — |
| `other` | anything unmatched, with its code kept | same |

An unmatched code is stored as `other` with `code` set, so the taxonomy can
grow from real data instead of guesses. **Never drop a code you did not
recognize.**

### 7.2 Rollup

On every attempt: insert the `mistakes` rows, then for each distinct kind bump
`mistake_stats.count` and reset `cleared_since` to 0. For every kind *not* in
this attempt that the user has a row for, increment `cleared_since` — **but
only when the attempt is a `submit`.** A kind with `cleared_since >= 5` is
considered learned and drops out of the AI plan's priority list, without being
deleted.

**The rollup is deliberately asymmetric, and this is the sentence that says so.**
A `run` (PROTOCOL §4.9b) *can* reset `cleared_since` to zero and does bump
`count` — making a mistake is making a mistake, whichever button produced it.
Only a `submit` advances it.

The reason is what the threshold of 5 was calibrated against. It was written
when an attempt meant a considered answer. Five clean *runs* is a minute of
pressing a button while fixing an unrelated typo; if that retired a kind,
"learned" would mean "compiled five times" and the weakness drill would stop
teaching the thing the player is worst at. **Evidence that you have stopped
making a mistake should cost more than evidence that you are still making it.**

Nothing is lost from the ranking: `count` still sees every run.

### 7.3 AI mode

Three plans, all built server-side from the tables above. No external model
is required for any of them.

* `repeat` — the quests the user failed most, ordered by failures, newest
  first. The plain "do it again until it sticks".
* `weakness` — group by `mistake_stats.kind`, take the top kinds by
  `count` with `cleared_since < 5`, then pull quests whose `concepts` overlap
  that kind's concept set — including quests already cleared. This is the one
  that actually teaches: it finds *borrow-after-move* and hands over five
  different shapes of it.
* `spaced` — cleared quests due for review on an SM-2-ish interval from
  `first_clear_at` and the star count. 3 stars comes back in 14 days, 1 star
  in 2.

A plan is a fixed ordered list of quest ids written into `drills.plan` at
creation, so the session is reproducible and a reconnect resumes it.

---

## 8. Search

One box. `search.query` with `mode` in `bm25 | semantic | unified`, and
`unified` is the default.

### 8.1 BM25

FTS5 over `title, brief, concepts, story`, `porter unicode61`, with the
standard `bm25()` ranking and column weights `(4.0, 1.0, 2.0, 0.5)` — a title
match beats a story match. `snippet()` supplies `SearchHit.snippet`.

### 8.2 Semantic

Behind a trait:

```rust
pub trait Embedder: Send + Sync {
    fn id(&self) -> &str;          // written into quest_vec.model
    fn dim(&self) -> usize;
    fn embed(&self, text: &str) -> Vec<f32>;   // L2-normalized
}
```

Two implementations:

* `hashed` — the **default**, always compiled in, no downloads, no network,
  deterministic: character 3-grams and word unigrams hashed into `dim=512`
  buckets with sub-linear term frequency and an IDF learned from the quest
  corpus at index time. It is not a language model and will not find
  *"concurrency"* from *"parallel"*, but it starts instantly and never fails.
* `onnx` — behind the `embed-onnx` cargo feature, **off by default**. A real
  sentence embedder. Only wired in if the dependency's real footprint and
  offline behaviour are verified first; it must never be required for a cold
  start.

Vectors are a `BLOB` of `dim` little-endian `f32`, and the search is a
brute-force cosine over every row. A few hundred quests makes an index
pointless; do not build one.

A `quest_vec` row whose `model` does not match the live embedder's `id()` is
recomputed at startup.

### 8.3 Unified

Reciprocal-rank fusion over the two rankings:

```
score(q) = Σ  1 / (60 + rank_r(q))     for r in {bm25, cosine}
```

`k = 60`, the usual. A document missing from one ranking simply contributes
nothing from it. RRF is used rather than a weighted sum of scores because
BM25 scores and cosine similarities are not on the same scale and pretending
they are produces a ranking that is neither.

The response carries the component scores as well as the fused one, so the
search screen can show *why* something matched.

---

## 9. Tests that are not optional

These are the ones that catch a whole class of "it works on my machine":

1. **Address conformance.** A table of mnemonics → addresses, generated from
   `CausewaybayWallet`'s own output, asserted in the frontend's unit tests.
   If this fails, users lose their accounts.
2. **Signature round trip.** A known private key signs the exact §3.2 message;
   the Rust verifier recovers the exact address. Run in both `backend` and
   `frontend` suites against the same fixture vector in `tests/vectors/`.
3. **FTS5 present.** A startup assertion, not a hope.
4. **Every quest's reference solution is accepted.** The whole content pack
   goes through the real runner in CI. A quest whose own answer fails is a
   broken quest, and there is no other way to find out.
5. **Every quest's starter code is *not* accepted.** Otherwise the map clears
   itself.
6. **Runner limits.** Infinite loop → `timeout`. Huge output → `output_limit`.
   Fork bomb → killed, server alive — both shapes: children that stay in the
   process group, and children that leave it, which `killpg` alone never
   reached. A submission cannot extend its own wall clock by spawning
   something that outlives it. And the hole §5.3 admits to — a descendant
   orphaned out of the group between two samples — has a test that asserts it
   is still there, so the day it closes the claim is rewritten rather than
   left stale. `GOPROXY=off` → a quest that tries to fetch fails cleanly.
7. **Mistake classification.** Fixture sources → expected `kind`, one per row
   of the §7.1 table.
8. **Multi-user isolation.** Two sessions, two addresses, interleaved
   submissions: neither sees the other's progress, attempts or mistakes.

---

## 10. Frontend

Vite + TypeScript + three.js. **No wasm core.** The game rules live on the
server; the browser draws and listens.

Lifted, not reinvented, from the sibling repos:

* `CausewaybayGolang/typescript/src/engine/layout.ts` — the virtual canvas.
  It already does exactly what "support vertical/horizontal mode" means here:
  authored at 1280×720 or 720×1280, uniform integer-ish scale, the canvas
  *grows* along the long axis up to 1.5× rather than letterboxing, touch type
  boost, `F1` to pin an orientation. Take it as it stands.
* `engine/{text,ui,particles,burst,ease,theme,input,assets}.ts` — the same
  16-bit furniture: Press Start 2P, the panel chrome, confetti and ribbons.
* `public/art/manifest.json` — the art convention, including the `box`
  metadata that lets a sprite sit on its feet rather than its bounding box.
* `CausewaybayRaiden` — the retro palette, the chip audio in `audio/chip.ts`,
  and the sprite look.

Screens: `boot → login → lands → map → quest → result`, plus `search`, `stats`
and `ai` reachable from the map.

`lands` is **one** screen, not the two this section first called for. Land and
category are a 2×3 grid of six choices; splitting them made the player press a
button to reach a screen with three buttons on it, and a 16-bit select screen
shows you the whole world at once. Categories are always drawn in the fixed
order `basic`, `advanced`, `hacker` — never in the server's order, which is
incidental. three.js carries the
map's parallax layers and the effects; the quest screen is a 2D canvas overlay
with the editor (CodeMirror 6) on top — pixel art behind, a real editor in
front, because a hand-rolled textarea is not something anyone will solve a
HackerRank problem in.

Both orientations are first-class on every screen, not just the map.

---

## 11. Layout of the repository

```
backend/            Rust workspace
  core/             domain: store, quests, progress, mistakes, search, drills
  runner/           compile + run, rust and go, limits and streaming
  server/           axum, the websocket, the message catalogue, static files
  cli/              `cwbhacker`: serve, import, prune, doctor
love2d/             LÖVE 11.5 desktop client, same protocol
  src/              scenes, layout, the websocket and JSON in Lua
  ffi/              a small Rust cdylib: bip39/bip32/secp256k1 for LuaJIT
frontend/           vite + ts + three.js
  src/engine/       layout, text, ui, input, assets, particles  (ported)
  src/net/          the websocket client, typed against §6
  src/scenes/       boot, login, lands, map, quest, result, search, stats, ai
  src/wallet/       bip39/bip32/secp256k1 derivation and signing
  public/art/       sprites, backgrounds, manifest.json
content/            quest packs (TOML), one file per land+category
  rust/{basic,advanced,hacker}.toml
  go/{basic,advanced,hacker}.toml
docs/               decisions.md, story.md, art.md
tests/vectors/      shared fixtures: addresses, signatures, mistake sources
e2e/                playwright: the whole loop, both orientations
```

Ownership, so two people do not edit one file:

| directory | owner |
| --- | --- |
| `backend/**` | BE |
| `frontend/**` | FE |
| `love2d/**` | L2D |
| `content/**`, `docs/**`, `SPEC.md`, `README.md` | PM |
| `tests/**`, `e2e/**`, `backend/*/tests/**` | QA |

A change that crosses a boundary is proposed in `docs/decisions.md` and taken
by the owner.

---

## 12. Content packs

One TOML file per land + category, in `content/<land>/<category>.toml`. The
server imports them at startup (and on `cwbhacker import`), upserting by
`quests.id` and recomputing `checksum`.

```toml
pack = "rust.basic"
land = "rust"
category = "basic"
version = 1

[[quest]]
id          = "rust.basic.01.hello"
node        = 1
title       = "FIRST LIGHT"
difficulty  = 1
story       = "The terminal blinks. You used to know this one."
concepts    = ["io", "strings"]      # from the closed vocabulary in docs/concepts.md
requires    = []                     # quest ids that unlock this node
map         = { x = 0.12, y = 0.74, kind = "quest" }
# time_limit_s = 600                 # the player's clock; `hacker` only (see below)
brief       = '''
Print `hello, causewaybay` and nothing else.
'''
starter     = '''
fn main() {
    // your code here
}
'''
solution    = '''
fn main() {
    println!("hello, causewaybay");
}
'''
hints = [
  "`println!` is a macro, so it takes a `!`.",
  "The string is exact: lowercase, one comma, one space.",
]

[quest.tests]
harness      = "stdio"
timeout_ms   = 5000
match        = "trim"
cases = [
  { name = "greets", stdin = "", expect = "hello, causewaybay\n", visible = true },
]
```

> **Use `'''`, not `"""`, for every field holding code.** TOML's `"""` is a
> multi-line *basic* string and processes backslash escapes, so a `'\n'` inside
> a quest's Rust or Go source is silently rewritten to a real newline before
> the compiler ever sees it, and the quest breaks in a way that looks like a
> compiler bug. `'''` is a multi-line *literal* string and passes the bytes
> through. `brief`, `story`, `starter` and `solution` are always `'''`.
>
> The `"…"` form is correct — and required — for `stdin` and `expect`, where
> `\n` is meant as a newline.

Rules:

* `id` must be `<land>.<category>.<NN>.<slug>`, agree with the file's `land`
  and `category`, and be unique within the pack. **`NN` is the node the quest
  was created at, and it does not have to equal its `node` today.**

  This is the half of §4.1 that matters: *"Stable forever… If a node moves, the
  `node` column changes and the id does not."* An earlier version of this
  clause required `NN == node`, which contradicts §4.1 outright — and the
  contradiction was not theoretical. Lengthening a map moves its boss, so the
  rule renumbered four boss ids on three separate occasions, and every rename
  is a delete-and-insert that throws away whoever had cleared it. It was free
  only because nobody had a real save yet.

  §4.1 wins. The importer checks the shape, the land, the category and
  uniqueness; it does not check the number against `node`, and a quest that
  moves keeps the id it was born with. A pack may therefore be perfectly valid
  with ids that look out of order — that is the point, and `node` is the
  authority on where it sits.
* `node` is unique within a pack and 1-based and contiguous. A gap is an error,
  because the map draws a path through them.
* `map.x` / `map.y` are 0..1 of the map image, so the art can be replaced
  without touching content. `map.kind` is `quest`, `boss` or `gate`.
* `requires` is the **suggested** route: the order the pack was written to be
  learned in, and the line the map draws between nodes. It does **not** gate
  anything — every node is playable from the start (PROTOCOL §4.7). A pack
  still declares it, because "what should I do next" is a question worth
  answering; it is advice, not a lock.
* At least one case must be `visible = true`, so a player is never guessing
  blind about the output format. No `expect` may be empty once its `match`
  normalisation is applied — an empty expectation is cleared by an empty
  `fn main() {}`, which clears the map for free.
* `time_limit_s` is a **quest-level** key, set on `hacker` quests and omitted
  elsewhere. It is the player's clock, and is not `tests.timeout_ms`, which is
  one run's wall clock — a quest can give you twenty minutes to write something
  that must execute in five seconds. The importer enforces the biconditional
  **on `time_limit_s` alone**: a `hacker` quest has one, a quest outside
  `hacker` does not. Hidden cases are a separate matter and are welcome
  anywhere — a `basic` quest that only ever showed its own test cases would be
  teaching the player to write to the example rather than to the brief. A
  `hacker` quest must additionally carry at least one hidden case.
* `solution` is mandatory and is run by CI (SPEC §9.4). A quest without a
  working reference answer does not get imported.
