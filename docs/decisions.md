# Decisions

Append-only. Newest at the bottom. One entry per decision, dated.

A proposal that crosses a directory boundary goes here first; the owning agent
applies it and appends the outcome.

---

## 2026-09-11 — Server-authoritative, no wasm core

The sibling repos put game rules in Rust→wasm with TS as a shell. We do not.
The server compiles code, holds multiple users and owns a database; a wasm
core would be a second home for the same state and the two would drift.

Lifted from the siblings: the **engine layer** only — `layout.ts`, the pixel
font, particles, the art manifest convention.

## 2026-09-11 — Wallet key material never crosses the wire

Login derives the address in the browser (`@scure/bip39` + `@scure/bip32` +
`@noble/curves`) on `m/44'/60'/0'/0/0`, matching CausewaybayWallet exactly, and
proves it with an EIP-191 signature over a server nonce. Not even on localhost,
not even "for convenience".

## 2026-09-11 — Semantic search ships with a built-in embedder

`hashed` (3-gram + unigram hashing into 512 dims, corpus IDF) is compiled in and
is the default: no download, no network, deterministic, instant cold start. A
real ONNX sentence embedder sits behind the `embed-onnx` cargo feature, off by
default, and only gets wired in after its real footprint and offline behaviour
are verified.

## 2026-09-11 — Mistakes are classified by compiler error identity

`rustc --error-format=json` gives `E0382` and a span; Go's text is normalized
into the same taxonomy. Codes, not prose regexes, are what make "your top
mistake is borrow-after-move" a query instead of a pile of strings. An
unrecognized code is stored as `other` with the code kept — never dropped.

## 2026-09-11 — PM proposal: `time_limit_s` is a quest-level key in the TOML

SPEC §2.1 gives `quests.time_limit_s` a column and §12 never says where it
comes from in a pack. The `hacker` category is defined by it (SPEC §0, §12's
`time_limit_s` comment "set for 'hacker'"), so it cannot be left to inference.

**Proposed:** a top-level key inside `[[quest]]`, sibling to `difficulty`:

```toml
[[quest]]
id           = "rust.hacker.01.two-sum"
difficulty   = 3
time_limit_s = 600
```

Omitted entirely for `basic` and `advanced`, where it imports as `NULL`. It is
*not* `[quest.tests].timeout_ms` — that is the per-run wall clock for one
execution (SPEC §5.2); `time_limit_s` is the player's clock for the whole
quest, and the frontend draws it.

All six packs are written this way. The importer (BE) and the pack schema test
(QA) need to accept it. Rule the content packs hold themselves to: a `hacker`
quest without `time_limit_s` is an error, and a non-`hacker` quest *with* one
is also an error — the verifier asserts both.

*Owner to apply: BE (importer), QA (pack fixture).*

## 2026-09-11 — PM: content packs use TOML literal strings for code

SPEC §12's example writes `starter`/`solution`/`brief` in `"""` — TOML
*multi-line basic* strings, which process backslash escapes. Any `\n`, `\t` or
`\\` inside a code sample is then rewritten by the parser before the compiler
ever sees it, and the failure is silent: the quest imports, and the reference
solution is subtly not the source that was written.

Two of the shipped quests hit this directly — `rust.basic.06.strings` and
`go.basic.06.strings` both contain `'\n'` in the source they hand the player.

**Decided, in the content:** `brief`, `starter`, `solution` and `story` use
`'''` (multi-line *literal*) strings. `expect` and `stdin` stay `"…"` basic
strings, because there the `\n` is meant as a real newline. `hints` are basic
strings and contain no backslashes.

This is a change of convention, not of contract — §12's example should be
re-spelled with `'''` when the spec next opens. Until then the packs are the
authority on it, and QA's importer fixtures should be written against `'''` so
they do not encode the escaping bug as expected behaviour.

*Owner to apply: PM (SPEC §12 example) at the next spec window.*

## 2026-09-11 — PM: `concepts` is a closed vocabulary, in `docs/concepts.md`

SPEC §7.3's `weakness` drill joins `mistake_stats.kind` → concepts → quests.
A free-form tag therefore does not merely look untidy, it makes a drill return
nothing. `docs/concepts.md` fixes 39 slugs and maps every §7.1 mistake kind to
the concepts that teach it. Packs may use nothing outside it; the verifier
parses the doc and rejects a pack that does.

`other` is deliberately unmapped: an unrecognized compiler code says nothing
about which idea is missing, so the drill falls back to the quest the mistake
happened on.

*Owner to apply: BE (the `weakness` query reads the §2 table of that doc).*

## 2026-09-11 — BE: what the spec did not say, and what the backend did about it

Milestone 1's backend is built. Thirteen places needed a decision the spec did
not make; none of them contradict it, and each is listed here so the owner can
overrule it.

**`rusqlite` has no `fts5` feature.** SPEC §2 asks for `bundled` and `fts5`.
`bundled` is real; `fts5` is not a feature of `rusqlite` 0.37. The bundled
amalgamation is compiled with `-DSQLITE_ENABLE_FTS5` unconditionally by
`libsqlite3-sys`, so FTS5 is there — and §9.3's startup assertion (a real
`CREATE VIRTUAL TABLE … USING fts5` plus a `MATCH` that has to return the row)
is what proves it rather than the feature list. *Proposed: strike `fts5` from
§2's sentence.*

**`quests` had nowhere to put the map position.** §12 carries
`map = { x, y, kind }` in the pack and §6.3's `MapNode` carries `x`, `y` and
`kind` on the wire, but §2.1's DDL has no column between them. Added as
`map_x REAL`, `map_y REAL`, `map_kind TEXT` in `0001_init.sql` rather than a
JSON blob, because `world.map` reads them on every draw. *Proposed: add the
three columns to §2.1.*

**`auth.login` does not carry the nonce.** §6.2's payload is
`{address, signature}`, so the server remembers which challenge it issued for
that address and redeems the newest live one. A client may also send `nonce`
to pick a specific challenge, which is what a test harness wants. The message
verified against is the exact string the server handed out, kept in memory
with the nonce — so no rendering difference between issuing and checking is
possible.

**Stars are an ordered cascade.** §6.3's rungs overlap: a clear with one
failure and no hint satisfies neither "no failed attempt and no hint" nor
"hints". Implemented as: 3 if no failed attempt and no hint; else 2 if a hint
was used or there were ≤2 failures; else 1. Failures counted before the clear;
stars never regress on a re-clear, and `best_ms` keeps the fastest.

**`locked` / `open` are derived, never stored.** Only the cleared fact and the
counters are persisted. A stored `locked` goes stale the moment content
changes a dependency, and then the map and the quest screen disagree. One
function (`world::state_of`) answers it for `world.map`, `quest.get`,
`quest.hint` and `quest.submit` alike.

**The importer upserts and never deletes.** `progress.quest_id` cascades on
`quests`, so a delete-then-insert import would wipe every player's progress on
the next restart — the exact thing milestone 1 exists to prove does not happen.
A quest dropped from a pack keeps its row and its progress (§2.2). Node
collisions during a reorder are handled by parking the pack's nodes on
negative numbers inside the import transaction.

**`quest.get` on a locked node answers `locked`,** not `not_found`: the node
exists and the player can see it on the map.

**`/art/…` is served from `frontend/dist/art` if it exists and
`frontend/public/art` otherwise,** so the art works before the first frontend
build. `frontend/dist` missing is not a startup error; `/` then returns one
line of plain text saying where the websocket is.

**`stats.summary.streak` is days, not attempts:** consecutive UTC days with at
least one attempt, ending today or yesterday. Yesterday still counts so a
streak does not break at midnight while the player is asleep. §6.2 names the
field and not the rule.

**The compiler gets a working environment; the player's program does not.**
§5.3's stripped environment is applied to the run of `prog`, with `PATH`,
`HOME` and `TMPDIR` pointed into the build directory and nothing else. `rustc`
is very often a rustup shim that cannot pick a toolchain without `HOME` and
`RUSTUP_HOME`, so the compile step keeps its environment and has only its
scratch redirected (`CARGO_HOME`, `CARGO_TARGET_DIR`, `TMPDIR` under
`build/rust/`). Nothing outside the home is written either way.

**`RLIMIT_NPROC` is deliberately not set on macOS.** It is per real UID there,
not per process: a low value locks the whole login session out of forking,
including the server. §5.3 says "where the platform provides it", and this is
the platform not providing it. `RLIMIT_AS` (1 GiB) and `RLIMIT_FSIZE` (64 MiB)
are set, and the defence that actually works is the process-group kill —
SIGTERM, 500 ms, SIGKILL — which is tested with a program that leaves a
`sleep 30` behind it.

**A `rustc` diagnostic with no error code** is stored as `syntax` when the
message reads like a parse error and `other` otherwise. Codes that are not in
§7.1's table are stored as `other` **with the code kept**, never dropped.
`unused_variables` / `unused_imports` / `unused_mut` arrive as warnings, so the
classifier keeps those warnings and drops the rest — filtering on
`level == "error"` would silently lose a whole row of the table.

**`quest.reset` hands back the starter and does not undo a clear.** The map
stamp is permanent (§0); a player asking for the blank page again is not
asking to lose it.

**Milestone 2 stubs answer `not_found` with `detail: {"milestone": 2}`.**
§6.1's code set is closed and has no "unimplemented"; `not_found` is the
honest member of it. `search.query`, `ai.plan`, `ai.next`, `ai.finish` and the
Go runner all answer that way rather than panicking.

## 2026-09-11 — PROTOCOL.md is the authority for the wire

Three clients now speak it (browser, LÖVE, smoke harness). SPEC §6 is the
summary; PROTOCOL.md is normative, and its §8 conformance checklist is what
"the client works" means. A protocol change lands there first.

## 2026-09-11 — A second client, in LÖVE

The sibling repos all ship twice — LÖVE/Lua and TypeScript/web — from one
design. We do the same. The LÖVE client is a *client*, not a second game: the
server still owns every rule, so the two clients cannot drift on anything that
matters.

Key derivation in Lua is the one genuinely infeasible part, so it goes through
a small Rust cdylib loaded with LuaJIT FFI — exactly the pattern
CausewaybayWallet's `luacli/causewaybay/ffi.lua` already uses over
`causewaybay-ffi`. The websocket stays in pure Lua over LuaSocket, which LÖVE
bundles: RFC 6455 is a few hundred lines and being able to read them beats
another binary dependency.

## 2026-09-11 — PM: the pack verifier, and a request to QA

SPEC §9.4 and §9.5 are the two tests that keep content honest: every reference
solution is accepted, every starter is not. They are QA's to own and they do
not exist yet, so PM wrote a standalone one to author against:

```
/private/tmp/claude-502/-Volumes-nvidia-vivid-CausewaybayHacker/tools/verify_pack.py
```

Python 3.13, stdlib only (`tomllib`), no repo dependency. Per quest it
compiles and runs `solution` and `starter` with the **exact** SPEC §5.1
commands — `rustc --edition 2021 -O --error-format=json main.rs -o prog`, and
`go build -o prog main.go` with `GOPROXY=off GOFLAGS=-mod=mod` — against every
case, under the declared `match` mode. Structurally it checks id shape against
`<land>.<category>.<node:02d>.<slug>`, node contiguity, that every `requires`
names a lower node in the same pack, one visible case minimum, `map.x`/`map.y`
inside 0..1 with a real spread and real direction changes, and that every
`concepts` entry is in `docs/concepts.md`.

Two checks in it are worth lifting verbatim, because both are silent failures:

1. **No `expect` may be empty after its `match` normalisation.** An empty
   `fn main() {}` compiles and prints nothing, so an empty expectation means
   the starter passes and the map clears itself.
2. **`hacker` ⇔ `time_limit_s` ⇔ a hidden case**, in both directions.

*Request to QA:* take this as the seed of the §9.4/§9.5 content CI, under
`tests/`. PM will keep running it on every content change either way, but the
copy that gates a merge should live in QA's tree, not in a scratch directory.

Toolchain checked on this machine, for the record: `rustc 1.97.1`,
`go1.27.1 darwin/arm64`. A bare `go build -o prog main.go` with no `go.mod`
and `GOPROXY=off` works, so SPEC §5.1's Go command needs no amendment.

## 2026-09-11 — BE: rebuilt against PROTOCOL.md, and one contradiction in §12

`PROTOCOL.md` landed mid-build and is now the authority for the wire. The
backend was reworked against it rather than patched around it. What changed,
and what it supersedes from the BE entry above:

* **Addresses are EIP-55 on the wire, both directions** (§2.4). `User.address`
  is the checksummed spelling; `address_eip55` is gone from the payload because
  there is no longer a second form to distinguish it from. Lowercase remains
  the only spelling *inside* the server and on disk (SPEC §3.4).
* **`auth.resume` rotates the token** (§4.4). The old token stops working the
  moment the new one is handed over, so a token read off a disk backup is good
  for exactly one resume rather than thirty days.
* **`ping.ok` carries `t` as an RFC3339 string**, not epoch milliseconds.
* **`quest.get` omits `solution`** rather than sending null, and `tests`
  carries only the visible cases plus `hidden_count`.
* **`Attempt.cleared` means "this submission just cleared the node"** — false
  when re-solving something already cleared.
* **`run.log` carries a per-stream `seq` from 0**, and the server stops
  streaming after 256 KiB per attempt with one final `\n…output truncated\n`
  chunk. The whole text is still on disk and the 64 KiB copy still in the
  `Attempt`.
* **`progress.update` carries `unlocked`** and is pushed to the same user's
  other open connections through a small in-memory hub.
* **Transport rules**: unknown top-level keys are `bad_request`; a reused
  in-flight `id` is `bad_request`; a frame that is not a JSON object, and any
  binary frame, closes with 1003; 4 MiB inbound cap; `server.bye` before every
  close. `backend/server/tests/protocol.rs` asserts these, because two more
  clients are being written against them and "the frontend seems happy" is not
  evidence.

**`User.level` and `User.xp`** are `xp = 10 × stars` and
`level = 1 + xp / 100`. PROTOCOL §5.1 fixes the fields and not the curve;
writing it down here is what keeps the browser and the LÖVE client drawing the
same number.

**SPEC §12's `time_limit_s` biconditional is enforced; its hidden-case clause
is not, because the shipped content contradicts it.** §12 now reads "a
`hacker` quest has a `time_limit_s` and at least one hidden case, and a quest
outside `hacker` has neither". The first half is enforced both ways and all
six packs satisfy it. The second half cannot be: `content/rust/basic.toml` and
`advanced.toml` carry 22 and 20 hidden cases between them, and hidden cases in
a grammar quest are plainly intentional and good — a player should not be able
to read the whole test sheet. The importer therefore enforces: `hacker` ⇒
`time_limit_s` **and** ≥1 hidden case; non-`hacker` ⇒ no `time_limit_s`; and
says nothing about hidden cases outside `hacker`. **PM: either the sentence or
the packs wants changing — the packs look right to me.**

**The importer refuses a `"""`-quoted `brief`/`story`/`starter`/`solution`**
with the file and line number, before TOML has parsed it. After parsing, a
mangled `'\n'` is invisible and fails as what looks like a compiler bug.

**Concept slugs outside `docs/concepts.md` are a warning, not a refusal.** The
vocabulary is compiled into the importer and the §7.1 kind → concepts join is
that file's table verbatim. A refusal would mean a whole pack stops importing
because this list lagged a slug by an hour; a warning names the quest and the
slug, and the drill that would reach nothing is the only thing lost.

---

## 2026-09-11 — FE: what the browser persists, and what it refuses to

`localStorage` holds exactly two keys: `cwbhacker.token` (the session token,
PROTOCOL §6.1) and `cwbhacker.orientation` (a display preference). Nothing
else, ever. The mnemonic and the private key live in a module-local variable in
`frontend/src/wallet/wallet.ts`; no export returns them, no scene holds a
reference, and the login textarea is emptied before the first byte goes near
the socket.

The derivation is pinned to `CausewaybayWallet`'s EVM account 0 by vectors
asserted in `frontend/tests/wallet.test.ts`: `m/44'/60'/0'/0/i`, EIP-55, and
the EIP-191 signature compared byte for byte against `eth-account`'s own
output — including a `"héllo 🌏"` case, which is the only one that catches a
length prefix counting characters instead of UTF-8 bytes.

**Request to QA.** `tests/vectors/` is still empty, so those vectors are
inlined with their provenance rather than read across repositories. When the
shared fixtures land, FE will switch to reading them — `addresses.json`
(mnemonic → path → address → private key) and `eip191.json` (key, message,
prefixed hash, signature, signer) in `CausewaybayWallet/testvectors/`'s shape
would need no translation on either side.

## 2026-09-11 — FE: the dev mock is a server, and it is strict on purpose

`frontend/src/net/mock.ts` implements the PROTOCOL §4 catalogue in the browser
so the frontend could be built and tested before the backend ran. It is dev
only: the sole reference to it is a dynamic `import()` behind
`import.meta.env.DEV`, which Vite folds to `false` in a production build, and
the build is checked by grepping `dist/` for a sentinel string in the file.

It is deliberately **stricter than a demo needs**, because a lenient mock is
worse than none — it certifies bugs. It rotates the token on `auth.resume`,
splits `run.log` chunks mid-line with a per-stream `seq`, answers a second
`quest.submit` with `busy`, refuses everything but `ping`/`auth.*` before
authentication, and recovers the address from the signature with real
secp256k1 rather than trusting the claim. Each of those exists to fail a
client that got PROTOCOL §8 wrong.

Its world is mirrored into `sessionStorage`, so "clear it, reload, it is still
cleared" — the milestone-1 acceptance test — can be exercised before the
server exists. The real server keeps that in SQLite; the mock keeps it in a
tab, and nothing in the game is ever read from it by a scene.

## 2026-09-11 — FE: the browser sends the application-level `ping` anyway

PROTOCOL §8.12 requires the 20-second `ping` only of a client that cannot
answer websocket pings, which a browser can. The browser client sends it
regardless. A laptop that slept leaves a socket that looks open and is not,
and the application ping is what discovers that in twenty seconds rather than
at the player's next click. It is cheap and it makes the reconnect path
(§6) something that runs in normal use instead of only in a test.

## 2026-09-11 — BE: `cleared_since` counts attempts without *that* kind

SPEC §7.2 says "for every kind **not in this attempt** that the user has a row
for, increment `cleared_since`", and that is what the server does — read as
"you have not made this particular mistake in N attempts", which is the
question §7.3's `cleared_since >= 5` asks.

The `mistake_stats` column comment calls it "consecutive clean attempts", which
suggests the stricter reading: only an attempt with **no** mistakes at all
counts. That reading is not implemented, because a player who fails in a new
way every time would then never age anything out of the weakness plan and the
mode would keep drilling mistakes they stopped making months ago.

Whoever builds the `weakness` plan in M2 inherits this: it is one
`if mistakes.is_empty()` away if the other reading turns out to teach better,
and `backend/core/tests/mistakes.rs::the_rollup_counts_clean_attempts` asserts
the current one deliberately rather than by accident.

## 2026-09-11 — SPEC §12's hidden-case clause was wrong; the packs were right

BE's importer found the contradiction: §12 said a quest outside `hacker` has
neither a `time_limit_s` nor a hidden case, while `content/rust/basic.toml` and
`advanced.toml` ship 22 and 20 hidden cases between them.

The packs are right and the sentence was wrong. Hidden cases belong anywhere —
a `basic` quest that only ever showed its own test cases teaches the player to
write to the example rather than to the brief. The biconditional the importer
enforces is on `time_limit_s` alone; a `hacker` quest additionally needs at
least one hidden case. §12 amended.

## 2026-09-11 — Verified independently, not taken on report

The backend's own suite is green, but the vertical slice was also driven by a
third client written for the purpose (Node's built-in WebSocket, `@scure/bip39`
+ `@scure/bip32` + `@noble/curves`, no backend or frontend code). It derived
`0x9858EfFD232B4033E47d90003D41EC34EcaEda94` from the BIP-39 "abandon … about"
vector on `m/44'/60'/0'/0/0` — the ecosystem's canonical address for that
mnemonic — signed the challenge, cleared `rust.basic.01.first-light`, and saw
`rust.basic.02.bindings` unlock. Three implementations of the derivation now
agree.

Note for the noble v2 API, since it cost time: `secp256k1.sign(..., {format:
'recovered'})` returns `[recid, r, s]` with the recovery id **first**, while
Ethereum wants `r || s || v`. A client that concatenates it as-is produces a
signature that verifies as the wrong address.

## 2026-09-11 — L2D: the LÖVE client is built, and three notes from building it

Milestone 1 runs end to end in `love2d/` against the real server: mnemonic →
`auth.challenge` → local EIP-191 signature → `auth.login` → RUST → BASIC →
a 12-node map → the editor → a wrong answer → `run.stage`/`run.log` streaming
→ `WRONG ANSWER` with the mistake → the real answer → `ACCEPTED` / `CLEARED`
with two stars → the node stamped on the map with node 2 unlocked → the
failed attempt visible in `stats.mistakes` → still cleared after a restart,
through `auth.resume` alone. Both orientations on every implemented screen.

Three things worth writing down; only the first is a contract question.

**PROTOCOL §4.8 names a field that does not exist: `Quest.tests.cases`.**
§4.8's prose says "`Quest.tests.cases` contains only `visible: true` cases;
hidden ones are reported by name and count only." §5.3's `Quest` type has no
`cases` — it has `visible: {name, stdin, expect}[]` and `hidden_count:
number`, and that is what the server actually sends
(`backend/core/src/quests.rs` builds `{"visible": …, "hidden_count": …}`).
The LÖVE client reads §5.3's shape, which is the one on the wire.

*Proposed:* re-spell §4.8's sentence as "`Quest.tests.visible` contains only
`visible: true` cases; hidden ones are reported by count only" — and drop
"by name", since `hidden_count` is a number and carries no names. A client
written from §4.8 alone renders an empty test list and looks like it works.
*Owner to apply: PM (PROTOCOL §4.8) at the next spec window.*

**`docs/art.md` §7's one new FX asset is not drawn yet.** `stamp_cleared.png`
is listed as the only new effect asset; the LÖVE client stands in
`stamp_served.png` for it under the name `stamp_cleared`, so the day the real
one lands it is a file drop and no code change. No action needed, recorded so
the stand-in is not mistaken for the finished thing.

**A client-side ordering convention, for the record.** `world.lands` does not
promise an order for its lands or its categories, and does not need to. The
LÖVE client sorts them `rust, go` and `basic, advanced, hacker` for display
and appends anything it does not recognise. That is presentation, not a rule
— but two clients that order them differently look like two different games,
so FE may want the same convention.

*No action required from another agent except the §4.8 re-spelling.*

## 2026-09-11 — FE: two screens merged, and one line of the spec not followed

**`land select` and `category select` are one screen, not two.** SPEC §10
lists them separately. They are a two-button row and a three-row list; as
separate screens the second one is a list of three items with a back button,
which is a keystroke charged for nothing. `LandsScene` draws both halves —
lands on the left in landscape, above in portrait — and the categories are
re-rendered when the land changes. **QA: the e2e flow is
`boot → login → lands → map → quest → result`, six screens, not seven.**

**Category rows are drawn in a fixed `basic, advanced, hacker` order**, not in
the order `world.lands` sends them. The protocol does not promise an order and
a map whose rows move between sessions is a map nobody can learn.

**A quest `brief` is markdown (SPEC §2.1) and the canvas has no renderer**, so
`frontend/src/ui/markdown.ts` flattens it: fenced blocks become an indented
run drawn in the code font, and inline `**` / backtick / heading / bullet
markers are stripped. Showing the source would mean a player reads
`**in the order**`, which is worse than plain prose — the emphasis existed to
help them. The brief panel scrolls, because the real packs' briefs are longer
than the panel in every portrait window and a clipped sample case is the one
thing a player cannot work around.

## 2026-09-11 — PROTOCOL §4.8 named a field that does not exist

L2D's client found it: §4.8 said "`Quest.tests.cases` contains only `visible:
true` cases", while §5.3 and the server both use `tests.visible` +
`tests.hidden_count`. A client written from §4.8 alone reads `nil` and renders
an empty test list — which looks like a quest with no tests, not like a bug,
so it would have survived review. §4.8 rewritten to name the real fields and
to say what happens if you get it wrong.

`cases` is the *content pack's* name for them (SPEC §12). The wire deliberately
uses different names, because the wire form is a strict subset: the hidden
cases' data never leaves the server.
