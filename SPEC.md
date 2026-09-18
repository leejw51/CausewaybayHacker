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
   key derivation (local)           ~/.causewaybayhacker ──▶     c++ -std=c++20
                                                         ──▶     python3 -I
```

## 0. The shape of the thing

A 16-bit trainer. A rust coder in Causeway Bay lost their craft to vibe coding —
Skynet's plan all along — and takes it back one street at a time.

* Four **lands**: `rust`, `go`, `cpp`, `python`. The player picks one; the
  others are still there.
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
│       ├── progress.json           where they are, what each quest cost,
│       │                           and the stages they are weakest at (§1.2)
│       └── attempts/
│           └── <attempt_id>/       one directory per submission, kept
│               ├── main.rs | main.go | main.cpp | main.py
│               ├── stdout.txt
│               ├── stderr.txt
│               └── result.json
├── edits/                          the undo/redo stacks' sources (§2.3)
│   └── <address>/
│       └── <quest_id>/
│           └── <sha256>.rs | .go | .cpp | .py     content-addressed
├── build/                          scratch; safe to delete when the server is down
│   ├── go/{gocache,gomodcache}
│   ├── rust/{cargo-home,target}
│   ├── cpp/                        one directory per attempt; no cache to keep
│   └── python/                     one directory per attempt; no cache to keep
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

### 1.2 `progress.json`

The same bargain `profile.json` makes, for the rest of what the database knows:
**sqlite is the truth, and this is so a player can read their own directory
without it.** Nothing reads it back. If it disagrees with `hacker.db` the file
is wrong, and the next write fixes it.

It holds, for one address: `position` (the quest last worked on, `null` for an
account that has attempted nothing — which is *not* the same as being at the
start of rust), `totals` (the `stats.summary` figures), `weakest`, and a
`quests` table of every quest they have touched — state, stars, submits,
failures, hints, timings, and where that quest's undo stack stands.

The undo/redo **sources** are not copied in. They stay in `edits/` for the
reason given above: that tree is the trail behind the work, not the work, and
`cwbhacker prune` may drop all of it. What lands here is the stack's position —
depth, cursor, whether undo and redo are available.

`weakest` is the only part that is a judgement rather than a copy, and the
obvious ranking is wrong: ordering by raw failure count returns the quests a
player has *practised* most, which for anyone working steadily through a land
is simply the ones they have reached. Two groups, in this order:

1. `stuck` — failed submits, still not cleared. It is beating them now.
2. `costly` — cleared, but it took failures. Real weakness, already survived.

Within a group: more failures first, then the higher failure rate, so four
failures out of four outranks four out of twenty. Ties break on `quest_id` so
the order is total and the file does not churn between writes. RUN attempts are
never counted — §4.9b — and a quest never failed is not weakness.

Written on login, on a clear, and when the socket closes — not on every
attempt: it is a whole-account snapshot, and putting one through the disk per
RUN would cost more than the file is worth. The close is what catches the
common shape of an evening, which is a run of failed submits on one quest and
then the window shutting; without it the file would lag until the next clear.
The close write is best-effort, because a player whose disk is full should
still get a clean close.

### 1.3 Where the player is

One row per player in `user_position`: `land`, an optional `category`, an
optional `quest_id`. **The server owns it.** A client stores the session and
nothing else durable — logging out and back in restores the land, the category
and the stage, and so does opening the other client, because the browser and
the LÖVE desktop client talk to one server and therefore share one place.

Nothing new is asked of a client to keep it current. The server already
receives every move as a request: `world.map` names the land and category the
player just chose, `quest.get` names the stage they just opened. The bookmark
is written from that traffic, after the request has resolved, so a land that
does not exist or a quest the player cannot reach never becomes somewhere they
get put back. Writing it from the traffic rather than from a "save my place"
message is also what stops the two clients drifting: neither of them is the one
keeping score.

`quest_id` is null when they are in a lobby rather than on a stage, and that is
a real state — "I chose rust/basic and have not opened anything" should restore
to the map they were reading, not to a quest they never opened. Walking back
out to a lobby clears it.

It is a bookmark, not a history; the history is `attempts`, kept forever. The
row is deliberately not a foreign key onto `quests`: a bookmark pointing at a
quest a reimport has dropped degrades to the lobby of that land, because the
land outlives any particular pack and sending a client to a quest id it cannot
open is worse than sending it one screen out.

Handed to the client by `auth.login` and `auth.resume` (PROTOCOL §4.3, §4.4),
and written into `progress.json` as `position` so the file and the game never
disagree. An account that stopped playing before this existed has no row, and
the file falls back to the last quest its `attempts` trail names.

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

-- ---------- the chatroom under a snippet (PROTOCOL §4.9f) ----------
-- The AI coder's transcript about one pad, scoped by owner exactly as the
-- snippet is. The model runs in the browser with the player's own key; the
-- server keeps the messages, the photos and an index over them. A photo is a
-- file under the snippet's folder, not a column: the websocket frame is 4 MiB
-- and a picture can be most of it, so the row keeps the file name and a
-- 32-hex capability token that `GET /photos/{id}/{token}.{ext}` checks.
CREATE TABLE snippet_messages (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,  -- the identity, never reused
  timeid        INTEGER NOT NULL UNIQUE,   -- ms since the epoch, strictly increasing; the sync cursor
  snippet_id    TEXT NOT NULL REFERENCES snippets(id) ON DELETE CASCADE,
  address       TEXT NOT NULL,
  role          TEXT NOT NULL CHECK (role IN ('user','agent','tool')),
  kind          TEXT NOT NULL CHECK (kind IN ('text','image')),
  text          TEXT NOT NULL DEFAULT '',  -- the message, or the image's prompt
  photo         TEXT,                      -- file name under photos/ ('<id>.<ext>'), image rows only
  photo_token   TEXT,                      -- 32 hex; the capability that fetches it
  provider      TEXT,                      -- 'openai' | 'anthropic' | 'grok' | NULL
  model         TEXT,
  created_at    TEXT NOT NULL,
  edited        INTEGER NOT NULL DEFAULT 0,  -- the text changed after it was said
  deleted       INTEGER NOT NULL DEFAULT 0   -- a tombstone: text '' and photo NULL, timeid moved
);
CREATE INDEX snippet_messages_by_snippet ON snippet_messages(snippet_id, timeid);
CREATE INDEX snippet_messages_by_address ON snippet_messages(address, timeid);

-- The last timeid handed out, bumped in the same transaction as the row
-- that takes it (max(last, now_ms) + 1). Its own row rather than max() over
-- the messages, so a cleared room cannot let the next post land under what
-- a client already saw.
CREATE TABLE chat_clock (
  one           INTEGER PRIMARY KEY CHECK (one = 1),
  last_timeid   INTEGER NOT NULL
);

CREATE VIRTUAL TABLE snippet_message_fts USING fts5(
  text,
  content='snippet_messages', content_rowid='id',
  tokenize='porter unicode61'
);
-- kept in sync by the same three triggers quest_fts has.

CREATE TABLE snippet_message_vec (
  message_id    INTEGER PRIMARY KEY REFERENCES snippet_messages(id) ON DELETE CASCADE,
  dim           INTEGER NOT NULL,
  model         TEXT NOT NULL,             -- embedder id, §8.2
  vec           BLOB NOT NULL              -- dim * f32, little-endian
);

-- ---------- the edit stack (PROTOCOL §4.11c) ----------
-- The order of the undo/redo entries lives here; the source itself lives on
-- disk, content-addressed under `edits/` (§1). A row is tens of bytes and a
-- source is up to 256 KiB — see §2.3 for why the blob is not a column.
CREATE TABLE edit_stack (
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  seq           INTEGER NOT NULL,          -- 1-based position, contiguous
  sha           TEXT NOT NULL,             -- sha256 of the source; names the file
  bytes         INTEGER NOT NULL,          -- length of that source, so "how
                                           -- big is this stack" is a query and
                                           -- not a hundred stat() calls. It is
                                           -- an upper bound: entries sharing a
                                           -- sha share one file on disk.
  created_at    TEXT NOT NULL,
  PRIMARY KEY (address, quest_id, seq)
);

-- One row per stack. The cursor is not a column on `edit_stack` because
-- `cursor = 0` — "the editor shows the starter" — is a legal state with no
-- entry to hang it on, on a stack that may have no entries at all.
CREATE TABLE edit_cursor (
  address       TEXT NOT NULL REFERENCES users(address) ON DELETE CASCADE,
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  cursor        INTEGER NOT NULL DEFAULT 0, -- 0..the stack's depth
                -- No CHECK: the bound is a count of rows in the other table,
                -- which SQLite cannot express here. This invariant is the
                -- code's, and `backend/core/tests/edits.rs` is where it is held.
  PRIMARY KEY (address, quest_id)
);

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

-- The quests' prose in other languages (§12.1). English stays on `quests`
-- and is what search indexes and the checksum covers; a translation is a
-- row per (quest, locale) that the read path substitutes on request.
CREATE TABLE quest_text (
  quest_id      TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  locale        TEXT NOT NULL,             -- ko | yue | zh | ja | cs
  title         TEXT NOT NULL,
  story         TEXT NOT NULL,
  brief         TEXT NOT NULL,             -- markdown; same code blocks as the English
  hints         TEXT NOT NULL,             -- JSON array, same length as quests.hints
  PRIMARY KEY (quest_id, locale)
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

### 2.3 The edit stack

PROTOCOL §4.11c's undo/redo, stored in two halves: SQLite owns the order, the
file system owns the text.

**Why not a `source` column.** The rows are small and the text is not. The cap
is 100 entries per quest per player and a source may be 256 KiB, so at the
ceiling a table with the source in a column is 25 MiB *per quest* for one
player who used their undo button — inside a database whose every other row is
a few hundred bytes and which is read on every map draw. Real sources are a few
KB and the worst case will not happen; the shape is the argument, not the
number. The order of the entries is a query; a source file is a blob; putting
the blob where the queries are makes the database the wrong shape. So
`edit_stack` holds a sha and a file holds the bytes:

```
~/.causewaybayhacker/edits/<address>/<quest_id>/<sha256>.<ext>
```

`<ext>` is the land's source extension — `rs`, `go`, `cpp`, `py`, the same
`source_filename(lang)` that names the file in an attempt directory (§1), so
one of these opens in an editor and compiles by hand like anything else the
player wrote. `<address>` is the lowercase form (§3.4), as it is under
`users/`.

**Content-addressed**, which pays for itself twice. An undo, a redo, and an
edit back to a text the stack has already seen write no new bytes, because the
sha is already on disk — a player toggling between two versions costs two
files, not twenty. And a file is unlinked only when no row anywhere references
its sha, which is what makes CLEAR STACK give the disk back rather than merely
forgetting the rows that pointed at it.

The invariant is in both directions: no row may name a sha with no file, and no
file may outlive the last row that named it. A foreign key does the first half
of that when a quest or a user disappears, but `ON DELETE CASCADE` deletes rows
and not files — whatever removes the rows has to sweep the directory in the
same breath, or the home directory quietly keeps the history of a quest that no
longer exists.

**Why the cursor is its own table.** `cursor` is a property of the stack rather
than of any entry in it, and `cursor = 0` — "show the starter" — is a legal
state with no entry to hang it on, on a stack that may itself be empty. A
`current` flag on `edit_stack` would have to be maintained across every undo,
and a stack with no flag set would be indistinguishable from a corrupt one.

A stack is per `(address, quest_id)`: two quests never share one, and neither
do two players.

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
`go.hacker.07.two-sum`, `cpp.basic.01.hello`, `python.advanced.17.the-gil`.
Stable forever; the slug is part of it so a reordered
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

**C++**

```
c++ -std=c++20 -O2 -pthread -Wall main.cpp -o prog
```

`c++` is the system driver (clang on macOS, gcc on Linux). No package cache.
Formatter: `clang-format --style=LLVM` on stdin (optional: `is_supported` may be true
only when `clang-format` is on PATH).

**Python**

```
python3 -m py_compile main.py        # the "compile" phase: SyntaxError ⇒ compile_error
python3 -I main.py                    # the run, per case, under the same limits
```

`-I` = isolated mode (no user site, no PYTHON* env). Needs Python ≥ 3.10.
No formatter (`is_supported("python") == false`).

Both are stdio-harness only. `Harness::Cargo` / `Harness::Gotest` remain
rust-only / go-only; `unsupported()` returns a message for any other pairing.

### 5.2 The test spec

`quests.tests` is JSON:

```json
{
  "harness": "stdio",            // "stdio" | "cargo" | "gotest" — cargo is rust-only, gotest go-only; cpp and python are stdio-only
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

**And it starts when the program does.** On macOS the first launch of a
binary the system has not seen is held in `execve` while Gatekeeper assesses
it — 8 to 20 s on one Mac, per new binary, with the child asleep at zero CPU
— and counting that against `timeout_ms` made every new program a timeout
with no output. The runner polls the child's CPU time and starts the clock at
the first nanosecond of it; the hold has its own bound of 120 s. `run_ms`
counts from the same moment, and a hold over a second is logged with the
remedy (the terminal the server runs from, under System Settings → Privacy &
Security → Developer Tools, skips the assessment). Elsewhere `exec` waits on
nothing and the clock starts at spawn as before.

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
The HTTP server also serves the built frontend from `/`, the art from
`/art/…` and the chatroom's photos from `/photos/…` (PROTOCOL §4.9f), so
there is one port and no CORS.

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
| `quest.get` | `{quest_id}` | `{quest}` — no `solution` unless cleared, `draft` if any |
| `quest.submit` | `{quest_id, source, lang}` | `{attempt}` |
| `quest.hint` | `{quest_id, index}` | `{hint, hints_used}` |
| `quest.solve` | `{quest_id}` | `{source, hints_used}` — PROTOCOL §4.11b |
| `quest.reset` | `{quest_id}` | `{starter}` |
| `edit.state` | `{quest_id}` | `EditState` — PROTOCOL §4.11c |
| `edit.push` | `{quest_id, source}` | `EditState` |
| `edit.undo` / `edit.redo` / `edit.clear` | `{quest_id}` | `EditState` |
| `search.query` | `{q, mode, filters?, limit?}` | `{hits:[SearchHit]}` |
| `playground.chat.list` | `{id, limit?}` | `{messages:[ChatMessage]}` — PROTOCOL §4.9f |
| `playground.chat.post` | `{id, role, text?, image_b64?, image_type?, provider?, model?}` | `{message}` |
| `playground.chat.clear` | `{id}` | `{id, cleared}` |
| `playground.chat.search` | `{q, id?, mode?, limit?}` | `{hits:[ChatHit], mode, took_ms}` |
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
C++: the same, over clang's and gcc's prose (they word one mistake two ways,
and the slug is what they share); a program the kernel stopped is identified
by its signal. Python: `py_compile` for the one compile-time row, and
otherwise the last `XxxError:` line of the traceback, which is the whole
identity Python gives. Every code is prefixed by its land except Rust's,
whose codes are the compiler's own: `go:`, `cpp:`, `py:`.

Kinds (the slug stored in `mistakes.kind`), each mapped from one or more codes:

| kind | rust | go | cpp | python |
| --- | --- | --- | --- | --- |
| `borrow-after-move` | E0382, E0505 | — | `cpp:use-after-move` (clang `-Wall`) | — |
| `borrow-conflict` | E0499, E0502 | — | — | — |
| `lifetime` | E0106, E0597, E0621, E0373 | — | — | — |
| `type-mismatch` | E0308 | `cannot use … as … value` | `cpp:no-matching-function`, `cpp:cannot-convert` | `py:type-error` (`TypeError`) |
| `unknown-name` | E0425, E0433 | `undefined: X` | `cpp:undeclared-identifier` | `py:name-error` (`NameError`) |
| `missing-trait` | E0277 | — | — | `py:attribute-error` (`AttributeError`, not on `None`) |
| `unused` | unused_variables, unused_imports | `declared and not used`, `imported and not used` | `cpp:unused` (`-Wall`) | — |
| `mutability` | E0596, E0594 | — | `cpp:const-discard` | — |
| `nil-deref` | — | runtime `nil pointer dereference` | `cpp:segfault` (signal 11 / `Segmentation fault`) | `py:none-attribute` (`AttributeError: 'NoneType'`) |
| `index-range` | runtime `index out of bounds` | runtime `index out of range` | `cpp:out-of-range` (`std::out_of_range`) | `py:index-error`, `py:key-error` |
| `data-race` | — | `go test -race` report | — | — |
| `deadlock` | — | `all goroutines are asleep` | — (not detectable; it is a `timeout`) | — |
| `unhandled-error` | E0277 *discriminated*, see below | `err` assigned and not checked | `cpp:abort` (`terminate called` / signal 6) | `py:zero-division`, `py:value-error`, `py:exception` (any other uncaught) |
| `syntax` | any parse error | any parse error | `cpp:expected-token` | `py:syntax` (`SyntaxError`, `IndentationError`) |
| `wrong-answer` | — | — (verdict, not a compiler code) | — | `py:recursion` (`RecursionError`) |
| `timeout` | — | — | — | — |
| `other` | anything unmatched, with its code kept | same | `cpp:other` | same |

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
  runner/           compile + run, rust, go, cpp and python, limits and streaming
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
  cpp/{basic,advanced,hacker}.toml
  python/{basic,advanced,hacker}.toml
  i18n/<locale>/<land>.<category>.toml   translations of the packs above (§12.1)
docs/               decisions.md, story.md, art.md
tests/vectors/      shared fixtures: addresses, signatures, mistake sources (four lands)
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
> a quest's source (in any land) is silently rewritten to a real newline before
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

### 12.1 Translations

A pack is written in English and stays English: `content/<land>/<category>.toml`
is the source, the thing the checksum covers and the thing search indexes. A
translation is a second file, in a tree of its own so the importer can never
mistake one for the other:

```
content/i18n/<locale>/<land>.<category>.toml      locale ∈ ko yue zh ja cs
```

```toml
pack   = "rust.basic"
locale = "ko"

[[quest]]
id    = "rust.basic.01.first-light"
title = "첫 불빛"
story = "06:40, 자딘스 바자 위. 커서만 깜박이고 회색 안내문은 사라졌다."
brief = '''
정확히 다음을 출력하세요:

```
hello, causewaybay
```

소문자, 쉼표 하나, 공백 하나, 한 줄. 그 외에는 아무것도 없어야 합니다.
'''
hints = [
  "println!은 매크로이므로 느낌표를 붙입니다.",
  "문자열은 정확해야 합니다: 소문자, 쉼표 하나, 그 뒤 공백 하나.",
]
```

It carries the four prose fields and nothing else. There is no `node`, no
`starter`, no `solution`, no `tests`: a translation cannot move a quest or
change what it checks, only say it in another language. The directory is the
locale and the file name is the pack, so a reader — and CI — finds the file
for a language without opening every one; a file whose `locale` or `pack`
disagrees with where it sits is misfiled and refused.

Rules:

* `locale` is one of `ko`, `yue`, `zh`, `ja`, `cs`. English is not a locale
  here because English is the source. Anything else is refused.
* `brief` and `story` are `'''` literal strings, for the reason §12 gives:
  the brief carries the English brief's code blocks verbatim, and a `"""`
  string would eat their escapes.
* **Code is not translated.** Code blocks, identifiers, sample stdin and
  stdout, and the exact strings the program must print are the English pack's,
  copied byte for byte; `verify_pack.py --i18n` compares the fenced blocks.
  Titles are translated — they were uppercase in English because that is how
  the map draws them; in a CJK locale write them naturally.
* `hints` has exactly as many entries as the English quest. Hints are revealed
  by index and priced per hint (§6.3), so a count that differs would hand out
  a hint the English does not have or run out one early. The importer refuses
  the whole file rather than trimming it.
* Every `id` is `<land>.<category>.<NN>.<slug>` and belongs to `pack`. An id
  that no imported pack supplies is logged and skipped, not fatal: a
  translation that runs ahead of a content edit is stale, not wrong, and the
  rows that still match are worth serving. A file may therefore cover a pack
  partially and the importer keeps what it can.
* **Coverage is reported, correctness is enforced.** `verify_pack.py --i18n`
  fails on a file that breaks any rule above, and prints — without failing —
  how far each language has got. Translating 207 quests into five languages is
  incremental by nature, and a gate that only goes green on the last one is
  red for months and stops meaning anything, while a player whose language is
  half done gets the translated quests and English for the rest, which is the
  design working rather than a bug. `--require-complete` turns coverage back
  into a failure, for the sweep that finishes a language.

How to write one — the register per language, the terminology that is fixed,
what is never translated, and the order to work in — is `docs/translating.md`.

The importer runs after every English pack, in one transaction per file,
replacing whatever that locale had for that pack (there is no user state on
`quest_text`, so delete-and-insert is the honest reconciliation, and a quest
the file no longer translates goes back to English). On the wire
(PROTOCOL §4.7, §4.8, §4.10) a client sends its UI locale; where a row exists
the server substitutes the four fields and marks the object `text_locale`
with the language, and where none does the English goes out marked `"en"`.
Search hits stay English: the index is the English text, and a hit is a
pointer to a quest, not a rendering of it.
