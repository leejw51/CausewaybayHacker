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

## 2026-09-11 — QA: the e2e hook contract (proposal to FE)

A 16-bit game draws on a canvas. Playwright cannot see a sprite, cannot click
one and cannot read text off one, so `e2e/` is 20 skipping tests until the
frontend publishes a seam. The sibling repo
(`CausewaybayGolang/typescript/src/main.ts`) solved this with `<html
data-state>` plus a `window.__view()` accessor, and its e2e suite is readable
because of it. The same convention, asked for here:

1. **`<html data-state>`** — the current screen, one of
   `boot | login | lands | categories | map | quest | result`.
2. **`window.__cwb`** — `view(): string` (the whole view model, JSON),
   `login(secret): Promise<void>`, `setSource(source): void`, `submit(): void`,
   `forget(): void`. `login()` exists because typing twelve words into a
   canvas one keypress at a time tests the keyboard handler, not the login.
3. **`window.__cwbSocket`** — the live `WebSocket`. Two tests need to kill a
   socket and forge a frame with an unknown `v`; there is no button for "your
   wifi died".

Gate all three on `import.meta.env.DEV || location.search.includes("e2e=1")`
so a shipped bundle carries no "log me in" function.

The `View` type — every field the suite reads — is in `e2e/fixtures.ts`, and
`e2e/README.md` has a table explaining each. Four of them are worth naming
here because they are not obvious from "expose the view model":

* **`quest.tests.visible[0].expect`** — how the suite composes a right answer
  instead of hard-coding a string PM owns. The path matters: the wire shape
  is `Quest.tests.visible[]` (PROTOCOL.md §4.8), not `Quest.visible[]` and
  not `tests.cases`. Passing the server's `Quest` straight through is both
  the least work and the correct answer.
* **`lands[]`** — `world.lands` passed through, so the GO test can tell
  whether a GO row exists before trying to select it.
* **`errors[]`** — every `.err` payload the client has received, so a test can
  prove `busy` or `proto_version` actually *reached* the client rather than
  being swallowed. No server counterpart; this one is purely a client
  observation.
* **`console`** — the streaming console's text so far. The only way to assert
  that `run.log` paints *during* a compile rather than after it.

And `login(secret, index?)` takes a BIP-44 index (default 0), because the
server persists: a suite that always logs in as account 0 asserts "node 1 is
open" against a node a previous run cleared, and it runs twice per invocation
(landscape then portrait, one database), so it would break on its own first
run. Every test that submits derives a fresh high index off the same
published mnemonic.

FE owns `frontend/**` and takes this. QA does not edit there.

## 2026-09-11 — QA: three SPEC §9 items have no assertion QA can write

SPEC §11's ownership table gives QA `backend/*/tests/**`, but the working
instruction for milestone 1 is that QA writes nothing under `backend/` or
`frontend/`. Under that rule these three §9 items are **unownable as
written**, and the deliverable from QA is the fixture plus this note:

* **§9.1 address conformance** — "asserted in the frontend's unit tests".
  `tests/vectors/addresses.json` is done and cross-checked against two
  independent implementations. The assertion is owed by FE (vitest), BE
  (`backend/core`) and now L2D (the Rust cdylib).
* **§9.2 signature round trip** — "run in both `backend` and `frontend`
  suites". `tests/vectors/signatures.json` is done. The recovery assertion is
  BE's; the signing assertion is FE's and L2D's. The wire-level half — that
  the server rejects a signature over a *rebuilt* message — is written and
  lives in `tests/smoke/contract.mjs` §8.6.
* **§9.3 FTS5 present** — "a startup assertion". It is inside a process QA
  does not own. The only QA-side proxy is "search returns a hit", which is
  milestone 2 and much weaker.

Either the ownership rule relaxes for these three files, or BE/FE/L2D pick up
the rows in `tests/PLAN.md` §9.1.a–c, §9.2.a–e and §9.3.a–c. Both are fine;
leaving them unassigned is not.

## 2026-09-11 — QA: the Go half of the `unhandled-error` taxonomy row has no fixture

SPEC §7.1 maps `unhandled-error` on the Go side to "`err` assigned and not
checked (vet)". That is not what `go vet` does. Plain `go vet` — the standard
analyzer set in the Go distribution — reports nothing for a discarded error;
the check is `errcheck`, a separate third-party tool that is not installed
here and is not part of Go.

Evidence: `tests/vectors/mistakes/go/unhandled-error.go` compiles, runs, and
`go vet ./main.go` exits 0 with empty output. Both are captured in the
fixture.

Two ways out, PM's call:

1. **BE vendors `errcheck`** and runs it as part of the Go pipeline. It is a
   real dependency and an offline one, so this is viable — but it is a
   toolchain decision, not a test decision.
2. **The row loses its Go half**, and §7.1's Go column for
   `unhandled-error` becomes `—` like `borrow-after-move`'s.

Until then the case is marked `assert_me: false` in
`tests/vectors/mistakes/expected.json` with the reason attached, so it is a
recorded gap rather than a silent omission.

## 2026-09-11 — QA: `E0277` maps to two kinds, and `E0373` maps to none

Two findings from compiling the §7.1 taxonomy against `rustc 1.97.1`:

* **`E0277` is both `missing-trait` and `unhandled-error`.** §7.1 lists it in
  both rows — `{:?}` on a struct with no `Debug`, and `?` in a `fn main()`
  returning `()`. The code alone cannot decide; the classifier needs the
  message text or the span. Both fixtures are present
  (`rust/missing-trait.rs`, `rust/unhandled-error.rs`) so the disambiguation
  has something to be tested against.
* **`E0373` is in no row of §7.1** — and it is the code produced by a
  *shipped quest's own starter*, `rust.advanced.02.move` ("closure may
  outlive the current function"). §7.1 says an unmatched code is stored as
  `other` with the code kept, which is legal and correct. But a player's
  first real encounter with the training loop filing itself under `other` is
  a poor first impression, and `lifetime` is the obvious home.

Proposal to PM: add `E0373` to the `lifetime` row, and add a note to §7.1
that `E0277` needs a message discriminator. No code change is implied by
either — `expected.json` already records both under
`code_collisions` and `rust_codes_outside_the_71_table`.

## 2026-09-11 — QA: `verify_pack.py` lifted into `tests/content/`

PM's pack verifier was living outside the repo. It is SPEC §9.4 and §9.5
already implemented and already proven on real content, so it is now
`tests/content/verify_pack.py` rather than a second implementation written by
QA. Two changes, both mechanical:

* `REPO` is derived from the file's own location, and `SCRATCH`/`CACHE` moved
  under `$CAUSEWAYBAY_HACKER_HOME/build/content-ci` (or the system temp
  directory when that is unset), honouring SPEC §1's "nothing outside the
  home is written". They were absolute paths to one machine, which CI cannot
  be.
* `path.relative_to(REPO)` is guarded, so a pack given by an absolute path
  outside the checkout prints rather than raising.

**It runs and it is green: 60/60 quests, six packs, ~65 seconds cold.** Every
reference solution compiles and passes every case; every starter is rejected.

**Request to whoever owns the Makefile:** a `make test-content` target, and
`make test` left alone — 65 seconds is too much to charge every `make test`,
and the packs only change when content changes.

```make
test-content: ## every reference solution and starter, through the real runner
	python3 tests/content/verify_pack.py content/rust/*.toml content/go/*.toml
```

## 2026-09-11 — QA: packs the importer must refuse

`tests/content/invalid-packs/` holds nine content packs that are valid TOML
and invalid content, with `expected.json` naming the rule each one breaks.
They are for BE's importer tests: SPEC §12's rules are only enforced if
something proves the importer refuses a pack that breaks them.

All nine **parse** on purpose. A fixture that is merely malformed tests the
TOML parser and nothing else.

One deserves BE's attention before the importer is written.
`basic-escapes.toml` uses `"""` for `starter` instead of SPEC §12's `'''`,
and the damage is demonstrable: `tomllib` turns the two characters written
`\n` inside the quest's own comment into a real newline before the compiler
ever sees them. That quest is *about* printing a literal backslash-n, so the
corruption destroys the lesson silently.

**A TOML parser cannot report which quote style a string used.** So an
importer enforcing the `'''` rule has to scan the raw bytes for a quest-level
`starter =` / `solution =` followed by `"""`, before or alongside parsing.
Checking the parsed value is not enough and never will be.

## 2026-09-11 — QA: two gaps in PROTOCOL.md, found by writing the checker

Neither is urgent; both are places where an implementer has to guess.

1. **What `id` does a server echo on a frame it could not parse?** §1.2 says
   a frame that is not a JSON object is closed with 1003, which covers the
   worst case. But a frame that *is* a JSON object with no `id` — or an
   unparseable `id` — still needs an answer, and §2.2 only says the reply
   carries "the same `id`". `tests/smoke/contract.mjs` tolerates `id: null`
   on an `.err` for this reason. Proposal: §3.3 gains one sentence —
   "an error about a frame whose `id` could not be read carries `id: null`".

2. **`map.x` / `map.y` outside 0..1.** SPEC §12 says they are 0..1 of the map
   image; nothing says whether an importer refuses a value outside that or
   clamps it. There is no fixture in `tests/content/invalid-packs/` for it
   because QA does not know which behaviour to assert. PM's call.

## 2026-09-11 — QA: what is actually green today

So that nobody plans against an overstated test suite. Full detail in
`tests/PLAN.md`.

**Green, run, and proven:**

* `tests/vectors/` — three fixtures, all generated from real tools, all
  idempotent under `--check`. Addresses cross-checked against `eth-account`;
  the EIP-191 digest assembly cross-checked against four published vectors.
* `tests/vectors/mistakes/` — 33 cases, 0 unverified, against real
  `rustc 1.97.1` and `go1.27.1` output captured on disk.
* `tests/content/verify_pack.py` — 60/60 quests.
* `tests/smoke/selftest.mjs` — 20/20: a correct mock scores §8 12/12, and
  each of 19 injected faults is caught by the §8 point that owns that rule.

**Written, not yet meaningful:**

* `tests/smoke/contract.mjs` — 12/12 against a mock QA also wrote. It has
  never met BE's server, and the first run against it will find things.
* `e2e/` — 20 tests, all skipping, each naming what has to exist.

**Not written:** every SPEC §9.6 runner-limit case (blocked on a runner), the
§7.2 mistake rollup, and the three items in the "unownable as written" entry
above.

## 2026-09-11 — QA: what the first real run of the contract checker found

`node tests/smoke/contract.mjs` against `cargo run -p cwbhacker -- serve` on
:5390. **18 passed, 1 failed. PROTOCOL.md §8: 11/12.** Three divergences.

**1. An absent `payload` is accepted as `{}` (the one failure).**

PROTOCOL.md §2: a frame "is an object with **exactly** these four keys", and
`payload` is "**always an object**, never a bare value, never absent". The
server accepts `{"v":1,"id":"x","type":"ping"}` and answers `ping.ok`. A
payload that is *present* but bare (`7`) or an array is correctly refused, so
this is specifically the absent case.

§2's own justification for strictness is "a silently ignored field is how a
client ships a bug that looks like it works", and that applies word for word
to a silently defaulted one — a LÖVE client that forgets `payload` on one
message type would work everywhere and be non-conformant everywhere. Either
§2 relaxes to say an absent payload is treated as `{}`, or the server
refuses it. QA has no preference; what it cannot do is assert a rule the
document states and the server does not keep.

**2. A rejected signature burns the nonce, and the retry says `auth_expired`.**

Observed on a fresh connection: `auth.challenge` → a bad signature →
`auth_bad_signature` (correct) → the *good* signature over the same message
→ `auth_expired`. The nonce did not expire; it was consumed by the failure.

SPEC §3.2 step 4 orders it recover → compare → check the nonce is unused and
unexpired → **burn** → upsert → mint, so the burn belongs to the success
path. Two separable questions:

* Should a failed verification burn the challenge? Arguably yes as
  anti-grinding, arguably no because one malformed frame from anywhere then
  invalidates the real client's challenge. PM's call.
* Whichever it is, **`auth_expired` is the wrong code.** §3.3 defines it as
  "the challenge's `expires_at` passed". `auth_nonce_used` — "that nonce was
  already spent" — says what actually happened. Benign in effect, because the
  client's prescribed reaction to both is "start `auth.challenge` again", and
  actively misleading in a log at 2am.

**3. A second `auth.login` on an authenticated connection is `bad_request`.**

Message: "this connection is already authenticated; open a new one to change
user". This is **right** — it is §3.1's "A connection never goes back to
ANONYMOUS", enforced — and it is written down nowhere. Worth one sentence in
§4.3. It was also a bug in this checker, which reused one connection for
several login attempts; every attempt now gets its own.

**Everything else BE already does**, first time, no negotiation: the
envelope, the closed error set, `proto_version` with `detail.supported`,
`locked` with `detail.requires`, the four-line challenge byte-for-byte,
refusing a signature over a rebuilt message, `v` as 27/28 *and* 0/1,
`auth.resume` rotating the token with the old one dying, `run.log` `seq` from
0 per stream with no gaps, `run.stage` strictly ordered and each sent once,
`busy` per connection rather than per user, `progress.update` reaching the
same user's second window with `unlocked`, and full multi-user isolation
including a spoofed payload address.

## 2026-09-11 — QA: a Go submission should not read as a crash

`search.query` and `ai.*` answer `not_found` with `detail: {"milestone": 2}`.
That is exactly the right shape — a closed-set code plus a machine-readable
reason — and a client can grey the button out with it.

A **Go submission** comes back `internal_error`. PROTOCOL.md §3.3 tells a
client to render that as "the server broke — show a retry, log
`detail.trace_id`". So a player who picks the GO land on day one gets a crash
report for a feature that was never built, and will retry it, and get the
same crash report.

Proposal: a Go submission answers the way search does —
`not_found` with `detail: {"milestone": 2}`, or a `quest.submit.ok` whose
`Attempt.verdict` is `internal_error` only for genuine internal faults. Then
the client can say "GO opens in milestone 2" and mean it.

`tests/smoke/contract.mjs` asserts the behaviour as it stands and prints the
complaint as a note rather than a failure; `e2e/journey.spec.ts` has the
browser-side test, which records it as a Playwright annotation. Neither will
go red when this is fixed.

## 2026-09-11 — QA: the e2e hook contract, verified as still missing

The suite was pointed at the backend's own `frontend/dist` on :5390
(PROTOCOL.md §1: one port, no CORS). The page loads and boots. It exposes
`window.__THREE__` and nothing else: no `data-state` on `<html>`, no
`window.__cwb`, no `window.__cwbSocket` — and none of them with `?e2e=1`
either.

So all 24 e2e tests skip, and the earlier proposal ("the e2e hook contract")
stands unchanged and is the entire gap. The suite is written against the
amended six-screen flow, `boot → login → lands → map → quest → result`, with
no `categories` screen.

Two of the 24 are worth FE's attention because they close holes nobody could
confirm from inside a unit test:

* **the mid-run streaming console** — FE reported that headless RAF
  starvation defeated its timing attempts, so `run.log` painting *while*
  rustc thinks is currently believed rather than known. The test races the
  console against the screen change over a deliberately slow-to-compile
  source, so "before the verdict" is a real interval and not a coin flip.
* **the Go-gap message**, above.

## 2026-09-11 — QA: `Quest.tests.cases` does not exist, and a client reading it fails silently

PROTOCOL.md §4.8 named `Quest.tests.cases` before it was corrected. There is
no such key: it is `tests.visible[]` plus `tests.hidden_count`, and the live
server confirms it.

The failure mode is the reason this is worth an entry. A client reading
`tests.cases` gets `undefined`/`nil` and renders an **empty test list**,
which looks like a quest that has no tests rather than like a bug. Nothing
throws, nothing logs, and the player just sees a quest panel with a blank
section.

`tests/smoke/contract.mjs` now asserts the key's absence on `Quest`
explicitly, in both spellings (`tests.cases` and a top-level `cases`), with
that explanation in the failure message. Three clients read this shape now;
one of them getting it wrong should be a red test and not a shrug.

## 2026-09-11 — QA: the signature byte order has a negative test now

PROTOCOL.md §4.3 pins `r || s || v`. `@noble/curves` v2 hands a signature
back as `[recid, r, s]`, so a client that concatenates them in the order it
received produces `v || r || s` — 65 bytes, all valid hex, and wrong.

`tests/smoke/contract.mjs` §8.6 now signs correctly and then submits two
deliberate mis-assemblies of the same signature, `s||r||v` and `v||r||s`, and
requires `auth_bad_signature` for both. The server refuses both today. The
value is for the next client: a login that fails with "bad signature" when
the key is right is a day of debugging, and this turns it into one red line
naming the byte order.

`tests/vectors/signatures.json` already carries `r`, `s` and `v` as separate
fields beside the assembled `signature`, so a client can assert its assembly
against the fixture without a server at all.

## 2026-09-11 — BE: the four QA findings, and why a login now tries every challenge

QA's smoke suite scored the server 11/12 on PROTOCOL §8. All four items are
fixed; it now scores **12/12, 19/19**, including the real 70-second keepalive
window.

**An absent `payload` is `bad_request`.** §2 says the field is never absent —
"use `{}`" — and the server was defaulting it. Being lenient there is the same
failure as silently ignoring an unknown key, one frame later: a client ships a
bug that looks like it works and breaks against the next server.

**A rejected signature no longer spends the challenge, and a replay says
`auth_nonce_used`.** Finding the challenge, checking the signature and burning
the nonce are now one operation (`Challenges::login`), because *which*
challenge was signed is part of the answer. `auth.login` carries
`{address, signature}` and not the nonce, so the server tries every live
challenge for that address, newest first:

* it verifies against an unused one → burn it, log in;
* it verifies against a **used** one → `auth_nonce_used` ("ask for a new
  challenge"), never `auth_expired` ("wait");
* it verifies against none, but an unused one exists → `auth_bad_signature`
  ("your key is wrong"), and **every challenge stays live** — a mistyped
  mnemonic should cost a retry, not a round trip.

Those three codes are three different instructions to the player, which is
what §3.3 has them for. The old code burned on lookup and then reported
whatever the *next* challenge said, which is how "spent" came out as
"expired" and later as "bad signature".

**§7.1's amendments are in.** `E0373` → `lifetime` (a closure outliving the
local it borrowed did not move anything; the value escaped). `E0277` is
discriminated on the message: the trait named is `Termination`/`Try`, or the
text is about the `?` operator over `Result`/`Option` → `unhandled-error`;
anything else → `missing-trait`. The code is kept either way. Both readings
are asserted against QA's captured real `rustc` output, not against a
diagnostic I wrote.

**Go's `unhandled-error` row stays unpopulated.** Plain `go vet` is silent on
an unchecked error — that is `errcheck`, which is not in the Go distribution,
and SPEC §5.3 gets no new toolchain dependency for one taxonomy row. When the
Go runner lands in M2 it will detect it from the source or not at all.

**New assertions (SPEC §9.2, §9.3, §9.7), inside the backend crates:**

* `core/tests/auth.rs` loads `tests/vectors/signatures.json` and asserts the
  verifier recovers every signer, agrees with each vector's `eip191_digest`,
  reassembles `r`/`s`/`v` in the right order, accepts both the 0/1 and 27/28
  encodings of `v`, and refuses all four `must_reject` cases with the code the
  fixture names.
* `core/tests/store.rs` asserts the FTS5 check is an assertion and not a log
  line: a connection whose FTS5 cannot work makes `db::prepare` return `Err`,
  and `PRAGMA user_version` is still 0 afterwards — it refuses *before*
  migrating, because 0001 itself creates a `USING fts5` table and a half-built
  database is worse than none.
* `core/tests/mistakes.rs` runs the classifier over all 20 captured `rustc`
  outputs in `tests/vectors/mistakes/` (including the content starters) and
  asserts the kind and the kept code for each.

**Also fixed from a review, not from QA:** any inbound frame now resets the
missed-ping counter, so a client that keeps itself alive with the
application-level `ping` (PROTOCOL §1.1 — the LÖVE client) is no longer hung
up on at ninety seconds; a second `auth.login` on an authenticated connection
is refused rather than half-handled, because the hub would otherwise keep that
connection filed under the address it used to have; and a frame over the 4 MiB
cap now closes with **1009** instead of resetting the socket.

**Open, and QA is right about it:** a Go submission comes back as
`internal_error`, which a client renders as "the server broke". It is a
missing feature, not a failure. The honest fix is a payload field on the
attempt — `verdict: "internal_error"` with a `reason: "unsupported_language"`
— or a `not_found` error before an attempt row is ever written. **PM: which?**
I lean to refusing the submit with `not_found` and `detail.milestone = 2`, so
no attempt is recorded for a quest the server cannot judge.

## 2026-09-11 — BE: E0277's second wording, and `auth.resume` on a live connection

Two corrections to the entry above, both found by checking rather than
assuming.

**`E0277` has two `?` wordings and the first fix only caught one.** QA's
fixture covers *"the `?` operator can only be used in a function that
returns…"*. Compiling the other common shape — a `?` whose error type does not
convert — on this toolchain gives ``` `?` couldn't convert the error to
`MyError` ```, which shares no words with it and was landing in
`missing-trait`: exactly the misclassification the amendment exists to
prevent. The discriminator is now the operator itself (a message mentioning
`` `?` ``), plus `Termination` / `Try` / `FromResidual`.

Checked against real compiles, not guessed: `fn main() -> Result<(), MyError>`
where `MyError` lacks `Debug` says ``` `MyError` doesn't implement `Debug` ```
and stays `missing-trait` — it looks like an error-handling context and the
lesson really is to implement the trait — and `` `Point` is not an iterator ``
stays `missing-trait` too. All four wordings are in
`core/tests/mistakes.rs`.

**`auth.resume` may be re-sent on a live connection; `auth.login` may not.**
The first version of the §3.1 guard refused both. But §4.4 also makes
`auth.resume` the way a client refreshes its token, and a client refreshing on
a connection it already holds is not changing user — it would have got
`bad_request`, which §3.3 tells clients to log loudly as a bug. The guard is
now "the resolved address differs from this connection's", so a same-user
re-resume works and a different-user one is still refused. `auth.login` keeps
the stricter guard, because it is the message that means "become somebody".

## 2026-09-11 — `unavailable`, and why an unjudgeable submission writes nothing

BE asked what a Go submission should do while the Go runner is milestone 2. It
currently answers `internal_error`, which every client renders as "the server
broke — try again", for something that is not broken and will not work on a
retry.

New code in the §3.3 closed set: **`unavailable`**, with `detail.milestone`.
Adding to the set is safe because §3.3 already tells clients to treat an
unknown code as `internal` — an old client degrades to exactly today's
behaviour.

The more important half is BE's: **no `attempt` row is written.** An attempt
carrying a fabricated verdict flows into `mistakes`, into `mistake_stats`, and
from there into the AI drills — and the player is handed a lesson about a
mistake they never made. The whole curriculum is derived from that table
(SPEC §7), so nothing may enter it that did not really happen. That argument
applies to any future "cannot judge" path, not just Go.

## 2026-09-11 — BE: `unavailable` implemented, and a request to QA

Both halves of the decision are in.

**`unavailable` is a code in `core::error::Code`,** with a constructor that
takes the milestone so nothing can raise it without saying *when*:
`unavailable(reason, 2)`. `search.query`, `ai.plan`, `ai.next`, `ai.finish`
and a Go submission all answer it with `detail.milestone = 2`.

**Nothing is written for a submission this build cannot judge.** The check
(`cwbhacker_runner::unsupported(lang, spec)`) is asked *before* the attempt id
is minted and before `progress.bump_attempt` — the earliest point at which the
language and the harness are both known. It lives in the runner rather than
the server because the runner is the thing that knows what it can run, and it
covers the `cargo` and `gotest` harnesses as well as the Go land, so the same
rule holds for every future "cannot judge" path rather than for Go alone.

`backend/server/tests/protocol.rs::a_go_submission_is_unavailable_and_records_nothing`
asserts the whole of it against a live server: the code, the milestone, and
then that `stats.history` is empty, `stats.mistakes` is empty, and the node's
`attempts` counter is still 0 — the three places a fabricated verdict would
have leaked into the curriculum.

**QA: `tests/smoke/contract.mjs` needs `unavailable` added to its
`ERROR_CODES` set** (line ~77 — the list ends `"busy", "internal"`). §8
conformance is still 12/12, but two "beyond the checklist" cases now fail
against the amended §3.3:

```
FAIL  beyond: milestone-2 endpoints say so, and are not failures
      search.query answered unavailable, outside §3.3
FAIL  beyond: no frame the server sent broke the envelope rules
      error code "unavailable" is outside §3.3's closed set
```

Both are the checker holding the pre-amendment table, not the server. I have
not touched `tests/smoke/` — it is yours.

## 2026-09-11 — The smoke checker's copy of the closed set, updated by the lead

`tests/smoke/` is QA's, but its `ERROR_CODES` set and its milestone-2 case are
transcriptions of PROTOCOL §3.3, and §3.3 changed under them when `unavailable`
was added. Updated by the lead rather than routed back, since the edit is
derived from the spec change and not a judgement call.

The Go case gained teeth while it was open. It previously asserted only that
the verdict was one of a tolerated set, and printed a complaint. It now asserts
the refusal, the code, the milestone, **and that `stats.history` and
`stats.mistakes` are both empty** — the two places a fabricated verdict would
surface in the player's curriculum. Verified against a live server with a fresh
wallet: `unavailable`, milestone 2, 0 attempts, 0 mistakes.

## 2026-09-11 — FE: three.js carries the whole game, not just the map

The WebGL canvas was owned by the map scene, created and destroyed with it.
Two bugs came out of that, and one of them was invisible: `#fx` was never
sized, so it kept the browser's default **300×150** backing store stretched by
CSS to the window — every pixel on it was drawn at a quarter resolution and in
the wrong place. `App` now owns exactly one `Backdrop`, sizes it from `Layout`
alongside the 2D canvas on every resize and orientation change, and each scene
only declares a `mood`.

The backdrop is a **procedurally drawn Causeway Bay** in three parallax bands
(`src/gfx/skyline.ts`): the harbour towers, the mid blocks with their grid of
lit windows, and in front the two things that name the place — vertical
signage stacked down a building's face, and the tram wire. Generated rather
than shipped as art because it tiles seamlessly at any width, re-tints per
land without a second set of files, and stays crisp at `NearestFilter`. The
generator is seeded, so the city is the same on every run and a screenshot is
comparable to the last one.

Panel faces went from 0.94 to 0.84 opacity to let it through. The mood table
is the design: the quest screen nearly stops the city and nearly darkens it,
because that is the screen where somebody is trying to think and motion behind
text is a tax on reading it.

## 2026-09-11 — FE: exponential easing is the house curve

`engine/ease.ts` gains `expInOut`; `engine/motion.ts` holds every duration in
the game in one table, plus `Tween` and `Chase`. No scene picks a duration out
of the air — six screens each choosing their own is how a game ends up feeling
assembled rather than designed.

Expo is almost still, then very fast, then almost still. That shape needs
*longer* than a cubic to read as deliberate rather than abrupt: a screen
change is 0.62 s where a cubic would be fine at 0.3 s. `prefers-reduced-motion`
cuts every duration to a quarter rather than to zero — someone who asked for
less animation still needs to see *what changed*.

Nothing in the render path reads the wall clock; every tween is driven by the
`dt` it is handed. That is what makes `dev/capture.ts` able to step the game at
a fixed 1/60 and get the same frame every run.

## 2026-09-11 — FE: the capture hook, for screenshots and for QA

A canvas game never stops changing, so a screenshot tool that waits for the
page to be idle waits for ever — Playwright's own screenshot call times out on
this app, frozen or not. `src/dev/capture.ts` exposes `window.__cwbCapture`
with `freeze`/`resume`/`step`/`settle`/`orient`/`png`, and `?freeze=1` brings
the page up already settled and stopped.

It is dev **and** e2e, not dev alone: QA needs it in a *built* bundle, so the
guard is `import.meta.env.DEV || import.meta.env.VITE_E2E === "1"` and there is
an `npm run build:e2e` that emits `dist-e2e/`. The production build contains
neither the hook nor the mock, which is checked by grepping `dist/` for their
sentinels.

`png()` re-draws the DOM overlay — the seed field and the CodeMirror editor —
into the composite, because a canvas cannot composite a DOM element and a shot
of the quest screen without its editor would be missing the point of the
screen. It is a *rendering*, not a screengrab: no caret, no selection, no
syntax colour. It skips the overlay entirely when a modal has hidden it, so a
capture never shows a z-order bug that is not there.

## 2026-09-11 — FE: a socket that has been replaced must stop talking

Logging out closes one websocket and opens the next in the same turn. A real
websocket reports its close on a later task, so the *old* socket's `onClose`
arrived after the new connection was already up, knocked the client back to
`offline`, and scheduled a reconnect for a connection nobody had lost. On
screen that was a red CONNECTION LOST — RECONNECTING banner across the login
screen the player had just asked for — found by looking at a screenshot, not
by reading the code.

`Client.connect()` now stamps each transport with a generation number and
ignores `onOpen`/`onMessage`/`onClose` from any transport that is no longer the
current one; `close()` bumps the same counter. Because a deliberate close can
no longer rely on its own socket's callback, `close()` fails the requests that
were riding on it directly (`failPending`), which is what §6.6 asks for. There
is a test for the exact ordering — close, connect, *then* the first socket's
close arrives.

The app suppresses the offline toast for the one close it asked for. Both
halves are needed: the flag catches the synchronous transition, the generation
catches the late one.

## 2026-09-11 — FE: the flat path is walkable, not merely believed in

`Backdrop.create()` returning `null` is the whole second look at this game and
claiming it "degrades silently" without ever seeing it is not evidence. In dev,
`?nogl=1` forces that path. Walking it found that `MapScene` cleared the canvas
to transparent on the assumption that WebGL was behind it, which on the flat
path left the map floating on the page background; every scene now goes through
`App.clear`, which fills when there is no backdrop and clears when there is.

## 2026-09-11 — Screenshots stay out of the tree

`frontend/shots/` is 6.6 MB of PNGs regenerable from the `__cwbCapture` hook.
Gitignored: they would churn on every visual change and bloat every future
diff, and a screenshot in git goes stale silently — it keeps looking like
evidence long after it stops being true. Regenerate them to review; do not
archive them.

## 2026-09-11 — Seen with eyes, not read from code

The lead looked at six of FE's 26 shots. What the capture hook bought, beyond
unblocking QA: the login screen's explanatory slab has no panel frame while
everything beside it does; the CLEARED stamp lands across the star row rather
than beside it; both result panels are 50/50 while their content is 10/90; the
map plate shows a five-star difficulty row two screens away from a three-star
earned row, and nothing tells the player they are different scales; and an
internal `attempt att_…` id is on the victory screen.

None of these are visible in the source. All of them are obvious in a PNG.

## 2026-09-11 — FE: the front door was locked, and now it opens

Nothing in the project could produce a BIP-39 phrase. The login screen offered
one field placeheld "twelve words, or 0x + 64 hex" and two buttons, so a player
who had never run `CausewaybayWallet` had nothing to type and no way to get
anything to type. Everything else in a design review is decoration next to
that.

`wallet/newMnemonic()` is `@scure/bip39`'s `generateMnemonic(wordlist, 128)` —
128 bits from `crypto.getRandomValues`, nothing reseeded and nothing
post-processed. The login screen's `NEW WALLET` shows the twelve words on a
panel that says they are the only copy, and the phrase does not reach the field
until the player says they have written it down. It lives in one field on that
scene, `leave()` drops it, and it is never logged, never stored and never sent —
the same rules as a phrase that was typed.

The custody paragraph went from six unframed lines above the fold to two framed
ones below it. The first screen's job is to say what to do; why it is safe is
the footnote to that, and it was answering the second question before the
first.

## 2026-09-11 — FE: VT323 stays, and it was a choice

`docs/art.md` §1 says "Type is Press Start 2P" and warns that a hacker-terminal
look "is the one thing that would make it feel like homework". All body copy in
this client is set in VT323, a DEC VT220 face. Nobody had written down which one
won, so: VT323 stays, for the brief and the quest text, and Press Start 2P keeps
every piece of chrome — headers, buttons, labels, the stamp.

The reason is measure. A quest brief is sixty characters to a line and Press
Start 2P at a legible size gives about twenty-five. Setting the brief in the
pixel face would mean either three words a line or type too small to read, and
the screen a player stares at longest is the one that has to be comfortable.
The register is held by the chrome, the palette and the art, which is where a
16-bit game actually keeps it.

The twelve-size ladder the review objected to is not rebuilt here — renaming
and re-scaling twelve fonts touches every measured panel in every scene, and a
half-migrated ladder is worse than the one we have. The two places where the
ladder was visibly wrong are fixed: the map's node numbers came off the 8px
pixel font onto `ui`, and the sample input/output — the most load-bearing text
on the quest screen and previously the smallest — is set in `code`.

## 2026-09-11 — FE: the overworld is the picture, not a crop of it

SPEC §6.3 says node `x`/`y` are fractions **of the map image**. The map drew the
art `cover` — scaled to fill and centre-cropped — while spreading the node
fractions across the whole plate, so the nodes were laid out against a picture
that was not the one on screen. In portrait the crop took about 30% off the
sides and node 1 came down in the harbour.

The plate now takes the art's aspect ratio from the manifest, is centred in
whatever the layout leaves over, and the art is drawn into it exactly. A
fraction is a place on the picture again, in both orientations, with no content
change. The aspect comes from the manifest rather than from `naturalWidth`
because backgrounds are fetched lazily and a plate that resized when the JPEG
landed would move every node out from under the cursor.

The camera pan went with it. Panning existed to look around a crop; with the
whole picture on screen there is nothing to pan to, and the over-scan that kept
the pan from exposing the plate's edge went too.

## 2026-09-11 — FE: what the art is used for, and what it is not

DESIGN's set is 32 assets. Wired up this round: both overworlds, the title
plate, six per-street backdrops on the quest screen, three node markers, the
`CLEARED` ring, six boss portraits on the map's info plate, the two mascots, the
victory ribbon, and the medal.

Four are deliberately not drawn, and it is worth saying why rather than leaving
them looking forgotten. `fx_trophy` would be a third award on a screen that
already has a stamp, a ribbon and three stars — Chanel's rule, take one thing
off. `sprite_mei`, `sprite_alex` and `agent_skynet` are the cast, and `content/`
carries no speaker on a quest's `story` line: choosing a portrait by looking for
a name in the prose would be wrong exactly when it mattered. That is a content
schema question, not a rendering one.

The `box` metadata is what makes a sprite stand on its feet rather than on the
bottom of its transparent margin, and it is used for the mascots and the boss
portraits. Per DESIGN's note, nothing anchors a panel frame to `feet`.

## 2026-09-11 — L2D: `generate` is the one op that returns key material

The design review's §1 is right and it applied to the LÖVE client as much as
to the browser: a player who does not already own a BIP-39 phrase had no way
into the game, and the README invited them to bring one as though phrases
appear from somewhere.

The LÖVE client now has a **NEW WALLET** path, and the generation is in the
Rust cdylib (`love2d/ffi`) rather than in Lua. `rand::rngs::OsRng` into 128
bits of entropy, checksummed to 12 words. There is deliberately no Lua
fallback: a phrase out of `math.random` is a wallet anybody can re-derive from
the clock, and it looks exactly like a good one.

**This breaks the rule that nothing returns key material, and the break is
deliberate and bounded.** The ABI went 1 → 2 for it, so a binding cannot
silently get the wrong contract either way. The generated phrase crosses the
boundary exactly once, to be shown; it is not stored in the library, not
written to disk, not logged, and not sent. The private key derived from it
still never crosses. `describe()` says so in data — `never_returns` is now
`["private_key", "seed"]` and `returns_key_material_once` is
`["generate.mnemonic"]` — so the exception is auditable rather than folklore.

**The confirmation is three words typed back, not a checkbox.** SPEC §3 makes
the wallet the identity: there is no reset and no support desk, so a phrase
that was never actually written down is an account that ends with the machine.
A checkbox measures clicking a checkbox. `B` re-shows the list for somebody
who needs it, because a gate nobody can pass is a gate people route around.

*FE may want the same wording and the same confirmation; the browser side is
FE's to build, and this entry is here so the two clients do not disagree about
how serious the moment is.*

**Also from the review, in `love2d/`:** difficulty (1..5) and earned stars
(0..3) no longer share the gold star glyph — difficulty is a segmented bar in
`brick`, stars stay stars, and the category rows stopped drawing a third scale
(`stars / 4`) as a star row too. The 32 `art/` assets are wired in, including
the per-land overworlds, the boss portraits, and `node_quest` / `node_boss` /
`node_locked` in place of coloured circles.

**One bug worth naming, because it was mine and it was in the safety code.**
`store.lua` refused to persist "a value that looks like a mnemonic" using a
heuristic that counted runs of letters. A base64url session token has twelve
such runs often enough, and the refusal *raised*, through the reply handler,
so roughly one login in three hung on a spinner forever. The detector now
describes the actual thing — space-separated alphabetic words, twelve or more
— and refuses by returning rather than raising: a false positive must cost a
saved session and never the login itself.

## 2026-09-11 — FE: the browser's gate is L2D's gate

L2D's entry landed while this round was in flight and it is right, so the
browser matches it rather than inventing a second standard for the same
moment. The confirmation is **three of the twelve typed back**, not a checkbox:
SPEC §3 makes the wallet the identity, there is no reset and no support desk,
and a checkbox measures whether somebody can click a checkbox. The list is put
away first, the three are named by number, a wrong one is rejected *by its
number* rather than as a blanket "wrong", and `SHOW THEM AGAIN` re-opens the
list — a gate nobody can pass is a gate people route around.

Two places where the browser genuinely differs, stated rather than diverged
silently. There is one field on this screen and the three words go into it
separated by spaces, because the phrase itself arrives in that field by paste
and a second input surface would be a second thing to explain. And the three
indices are drawn from `crypto.getRandomValues`, not `Math.random` — the choice
of which words to ask is not itself a secret, but `Math.random` has no business
anywhere on the screen that mints a wallet.

Generation is `@scure/bip39`'s `generateMnemonic(wordlist, 128)`, which draws
from `crypto.getRandomValues`. There is no fallback path and there will not be
one: a phrase out of `Math.random` is a wallet anybody can re-derive from the
clock and it looks exactly like a good one. The browser has no ABI to bump, but
the boundary is the same shape — the phrase crosses out of `wallet.ts` exactly
once, to be shown, and the derived key still never crosses at all.

**On L2D's store bug, checked here:** this client has no "looks like a
mnemonic" heuristic to get wrong. `net/client.ts` persists exactly one value,
the session token, under one key, and both the read and the write are wrapped
in a `try`/`catch` that *returns* — a browser in private mode costs a
remembered session and never the login. That is the property L2D's fix
restored, and it is worth having checked rather than assumed.

## 2026-09-11 — BE: the Go land runs

`go build -o prog main.go` and the same stdio harness Rust uses. Both lands
now compile and run, and all 60 shipped quests are playable.

**The harness is shared, not copied.** `runner/src/harness.rs` holds the case
loop — run, compare, verdict — and `rust.rs` and `go.rs` each do only their
own compile step before handing over. Two copies of that loop would drift, and
a `trim` that forgave a trailing newline in one land and not the other is
exactly the difference a player reads as the server being unfair.

**The Go build environment** (SPEC §5.1): `GOCACHE`, `GOMODCACHE` and `GOPATH`
under `build/go/`, `GOFLAGS=-mod=mod`, `GOPROXY=off`. Two more than §5.1 lists,
both to stop a network fetch that `GOPROXY=off` would then fail confusingly:
`GOTOOLCHAIN=local`, so a `go.mod` naming a newer toolchain does not send `go`
to the internet, and `CGO_ENABLED=0`, so a quest cannot depend on the host
having a C compiler. A quest that imports a non-stdlib package fails as a
compile error in under a second, which is SPEC §9.6's `GOPROXY=off` case and
is asserted in `runner/tests/go_runner.rs`.

**Which §7.1 Go rows this build can actually produce.** Go gives prose, not
codes, so the identity is *made* from the message's shape and kept in
`mistakes.code`:

| row | identity | where it comes from |
| --- | --- | --- |
| `type-mismatch` | `go:cannot-use-as` | `go build` |
| `unknown-name` | `go:undefined` | `go build` |
| `unused` | `go:declared-not-used`, `go:imported-not-used` | `go build` |
| `syntax` | `go:syntax` | `go build` |
| `nil-deref` | `go:nil-deref` | runtime panic |
| `index-range` | `go:index-out-of-range` | runtime panic |
| `deadlock` | `go:deadlock` | runtime `fatal error` |
| `other` | `go:<shape of the message>` | anything else |
| `data-race` | `go:data-race` | **recognised, not reachable — see below** |
| `unhandled-error` | — | **unpopulated for Go — see below** |

All of them are asserted against QA's captured `go1.27.1` output rather than
against my idea of what Go says: 11 Go fixtures and 21 Rust ones, in
`core/tests/mistakes.rs`.

**The player's identifiers never reach the identity.** `undefined: tolal` and
`undefined: subtotal` are one mistake, so `go_identity` strips quoted text,
parenthesised asides and everything after the colon, and stops at the first
word that looks like a name — a single letter or anything with a capital in
it. Better a coarse identity two mistakes share than a fine one that splits a
mistake into one row per variable. The full text is still in
`mistakes.message`.

**`data-race` is recognised but not reachable in this build, and no shipped
quest needs it to be.** A race only shows up under `-race`, which is a
different build: on darwin/arm64 it wants cgo, it costs 2–10× in run time, and
it is non-deterministic by nature — three runs of QA's own race fixture
detected it zero times out of three. `content/go/advanced.10.race` declares
`harness = "stdio"` and is judged on its output, which is the right way to
teach it: the fixed program is deterministic and the broken one is not.
`classify_go_runtime` recognises a `WARNING: DATA RACE` report if one ever
appears in stderr, so the row costs nothing and is ready. **Proposal:** when
the `gotest` harness is built, it takes a `race = true` flag in the test spec
and that is the only place `-race` is used.

**`unhandled-error` stays unpopulated for Go.** Established earlier with QA:
plain `go vet` is silent on a discarded error (exit 0, empty output, captured
in the fixtures); that check is `errcheck`, which is not in the Go
distribution. SPEC §5.3's environment gets no new toolchain dependency for one
taxonomy row.

**Still refused, and now the only things that are:** the `cargo` and `gotest`
harnesses. No shipped quest declares either — all 60 are `stdio` — and both
answer `unavailable` with `detail.milestone = 2` *before* an attempt row is
written, which keeps the "nothing untrue enters the curriculum" rule tested
now that Go itself works
(`backend/server/tests/protocol.rs::an_unjudgeable_submission_records_nothing`).

**`cwbhacker doctor` now treats a missing `go` as fatal,** alongside `rustc`.
Half the map cannot be played without it.

### Two notes for other agents

**QA — `tests/smoke/contract.mjs` asserts the old gap.** Its Go case expects
`unavailable` with `detail.milestone = 2` and no attempt row. Go now compiles,
runs and records, so that assertion is correctly stale. I have not touched the
file; the coordinator is routing the change.

**QA — `backend/runner/tests/limits.rs` has a flaky assertion.**
`the_runner_itself_writes_only_under_the_home_it_was_given` snapshots the
*parent* of its temp home before and after, and the other six tests in the
same binary create their own `tempfile::tempdir()` in that same `$TMPDIR`
while it runs — so a sibling's directory shows up as "the runner created
`.tmpXXXX`". It failed once for me and passed on the next two runs, serial and
parallel. The fix is to give the harness its own parent directory
(`tempdir()` → `home/` inside it) and snapshot that, rather than `$TMPDIR`.
The property it asserts is a good one and worth keeping — I added the Go half
of it in `runner/tests/go_runner.rs`, which checks the developer's own
`~/Library/Caches/go-build` and `~/go` are not conjured up by a build.

## 2026-09-11 — QA: `make test-all`, and the Makefile lines to wire in

`node tests/run-all.mjs` runs every suite and prints a summary that names
what ran, what passed, and **what was skipped and why**. It starts a server
on a throwaway home (`--home <tmpdir>`, SPEC §1's first precedence) serving
`frontend/dist-e2e`, runs the suites that need one against it, and stops it —
including on `^C`. Nothing touches the developer's own
`~/.causewaybayhacker`, and every run starts from an empty database, which is
what makes "node 1 is open" true on the second run as well as the first.

Exit 0 only if every suite that ran passed. A skip is never counted as a
pass, and a suite that passed while skipping something *inside* itself says
so too — the LÖVE suite's layout tests need a real window, and the smoke
checker's keepalive check runs over 6 s rather than §1.1's 70 s unless
`--slow`.

**For the root Makefile** (QA does not edit it):

```make
test-all: ## every suite, one command, with an honest summary of what was skipped
	node tests/run-all.mjs

test-all-list: ## what test-all would run, and why anything would not
	node tests/run-all.mjs --list
```

`make test` is best left as it is. `test-all` takes about six minutes — the
content CI compiles 60 quests, the runner limits compile eight pathological
programs, and the browser suite does two real logins and a `rustc` per
orientation.

## 2026-09-11 — QA: SPEC §1's "nothing outside the home is written" is not a containment promise

Writing SPEC §9.6.g the obvious way produced a failing test, and the failure
is the finding.

A submission that uses an absolute path, or `..`, can write anywhere the
person running the server can write. That was confirmed rather than assumed:
the first version of the test wrote to a sibling directory and succeeded.

This is not a bug. SPEC §5.3 says it in as many words: *"**This is not a
sandbox.** Causewaybay Hacker compiles and runs code you typed, on your
machine, as you. It is a single-trusted-user local trainer."* But SPEC §1's
flat sentence — *"**Nothing outside the home is written.** No `/tmp`, no
project directory"* — reads as a containment guarantee, and somebody will
eventually quote it as one.

**Proposal to PM:** §1 gains a clause. Something like "Nothing outside the
home is written *by the server*. Code a player submits runs as the player —
see §5.3." One sentence, and it stops the two paragraphs contradicting each
other.

The row is now three tests, each asserting something true:

* the **runner's own** footprint stays under the home it was given — which
  catches a `CARGO_HOME` left unset, warming the developer's `~/.cargo` and
  making one machine's run differ from another's invisibly;
* the submission's **environment** is stripped to `PATH`, `HOME` pointed at
  the build dir and the toolchain vars (SPEC §5.3). This is the half that
  *is* enforceable without a sandbox: ordinary code doing ordinary things
  lands somewhere harmless, and whatever the shell that started the server
  was carrying is not readable by every submission;
* `it_is_not_a_sandbox_and_this_test_says_so_out_loud`, which asserts the
  *weak* thing deliberately and fails the day somebody adds a real sandbox,
  with instructions to rewrite it. A test claiming containment that does not
  exist would be the most dangerous file in the repository.

## 2026-09-11 — QA: §9.6.d cannot be written yet, and is not being faked

SPEC §9.6 wants `GOPROXY=off` to make a Go quest that fetches the internet
fail cleanly. There is no Go runner in this build: `unsupported("go", …)`
returns a reason rather than a judgement, and a Go submission comes back
`unavailable` with `detail.milestone: 2`.

A test pointed at it today would pass **because Go is unsupported**, not
because the proxy was off — green for the wrong reason, which is worse than
no test. It stays unwritten, with the reason in
`backend/runner/tests/limits.rs`'s module docs and in `tests/PLAN.md` §9.6's
ownership table, so nobody counts it as covered.

Related, and also not faked: `RLIMIT_NPROC` is deliberately unset (it is
per-user on macOS, so setting it would throttle the whole machine rather
than the child). So "fork bomb" is really "the child dies with the process
group", which is what the tests assert — not an NPROC behaviour that is not
there.

## 2026-09-11 — QA: the e2e suite is off the ground, and the capture hook was the right half

FE shipped `frontend/src/dev/capture.ts` — freeze, settle, step, orient, png,
scene — instead of the driving API QA asked for. That turned out better.

`settle()` runs the game at a fixed 1/60 step until every transition has
finished, which makes a canvas game **deterministic**. That is the thing a
browser test genuinely cannot do for itself. The driving half was not needed:
the seed field is a real `<textarea class="cwb-field">`, the editor is
CodeMirror with real DOM lines, and every screen is reachable by keyboard or
a click. So the suite drives the game the way a person does — and **verifies
on the wire**, through a second websocket session opened as the same wallet.

That is a stronger assertion than any view model could have supported: a
frontend that draws CLEARED over a server that never heard about it fails
here and passes every unit test on both sides.

**9 tests × 2 orientations, all green**, including the journey the user
asked for: login → train → logout → login as a second wallet → that wallet's
own map, its own empty history, and the first wallet's address gone from
local storage.

Three things worth knowing, because each cost real time:

1. **`settle()` freezes the loop.** Reading the scene with it and carrying on
   leaves the app frozen for ever, so the `quest.get` reply is never drawn,
   the editor stays `hidden`, and the symptom arrives thirty seconds later as
   a locator timeout on `.cm-content`. The helper settles, reads, then
   `resume()`s.
2. **Category selection is pointer-only and canvas-drawn.** `lands.key()`
   handles the land toggle and nothing else. The scan originally started at
   28% of the canvas height — *inside the ADVANCED row* — so the browser
   trained on `rust.advanced.01.threads` while the test asserted against
   `rust.basic.01.first-light`, and the symptom was "expected cleared, got
   open" on a quest the UI never opened. There is now an assertion that names
   that failure when it recurs.
3. **The same scan then failed in portrait**, because it swept one x column
   at 72% of the width and portrait stacks the panel elsewhere. It is a grid
   now.

**A request to FE, small and worth it:** a stable hit-test hook for the
canvas buttons — even just `__cwbCapture.buttons()` returning
`{id, rect}[]` — would delete the scan and with it a whole class of
silent-wrong-row failures. Not urgent; the grid works. But every time that
panel moves, this suite finds out the slow way.

## 2026-09-11 — QA: a test that asserts its own helper

Worth recording because it looked exactly like a server bug for ten minutes.

The restart integration test failed with *"the resumed session is the same
player: expected `0x9d8A62…`, got `0x9d8a62…`"*. The obvious reading is that
`auth.resume` spells the address differently from `auth.login` after a
restart — which would be a real §3.4 hazard, since that is precisely when the
server stops having the string the client sent and must read it back out of
`users`, whose primary key is the lowercase form.

It was not. The test helper returned the address it had **claimed**
(`eth::address_from_pubkey`, the lowercase storage form) rather than the one
the server **echoed** (EIP-55, per PROTOCOL.md §2.4). The test was asserting
its own helper.

The helper now returns the server's spelling, the reason is a comment on the
function, and there is a test — `every_reply_spells_the_address_the_same_way`
— that checks all four places the address arrives, including after a
restart. The server is right in all four.

## 2026-09-11 — The server binds 0.0.0.0, and says so every time

Asked for, so a phone on the tailnet can play. `BIND` defaults to `0.0.0.0`;
`make start LOCAL=1` pins it back to loopback.

Two things make this defensible rather than careless. First, `make start` and
`make remote` print exactly what is reachable — the tailnet address, the LAN
address, and one line saying the port compiles and runs submitted code as the
user. A machine whose exposure you have to go and check is a machine whose
exposure you will get wrong. Second, the intended path is Tailscale, which is
the user's own devices, not the open internet.

**Use 5390 from a phone, not 5291.** The page and the websocket must share an
origin: `net/endpoint.ts` derives the socket from `location.host` in a
production build, so the bundle served by the Rust server on 5390 connects to
the right place from any address it was loaded from. The vite dev server on
5291 reads `VITE_WS_URL` from `.env.development`, which is pinned to
`127.0.0.1` — loaded on a phone, that resolves to the *phone's* loopback and
fails. Rather than teach the dev server about tailnets, `start` builds
`frontend/dist` if it is missing so the one-origin path is always the one on
offer, and prints the note.

Verified over `100.93.166.76`: `GET /` 200, `GET /art/manifest.json` 200, and a
full login → map → wrong answer → compile error → accepted → cleared with a
fresh wallet.

**README needs amending** — it currently says "do not expose the port to a
network", which is no longer the default. PM owns it.

## 2026-09-11 — PM: the packs grew to interview scale, and the bosses were renumbered

The content brief sharpened to *cover coding-interview preparation for Go and
Rust*. An audit of the first 60 found `hacker` covering roughly 8 of the ~19
topics an interview actually draws from — no linked lists, trees, tries,
heaps-as-heaps, backtracking, graph algorithms beyond flood fill, DP beyond
coins, bit manipulation, matrix work or prefix sums.

The six packs are now **116 quests**: 18 + 18 `basic`, 16 + 16 `advanced`,
24 + 24 `hacker`.

**Quest ids changed for four bosses.** SPEC §12 requires the id's number to
equal `node`, and each map's boss has to stay last, so lengthening a map moves
it:

| was | is |
| --- | --- |
| `rust.basic.12.traits` | `rust.basic.18.traits` |
| `go.basic.12.nil-and-order` | `go.basic.18.nil-and-order` |
| `rust.advanced.10.deadlock` | `rust.advanced.16.deadlock` |
| `go.advanced.10.race` | `go.advanced.16.race` |

Their slugs — and so their meaning — are unchanged, and no other id moved.
SPEC §4.1 allows a node to move while its id stays put, but §12's rule that
the id must match `<node:02d>` is the one the importer enforces, and the two
cannot both hold. Renumbering is free right now because nothing has been
played; it would not be free after release, and at that point §4.1 wins and
the id freezes. **BE and QA: the four ids above changed.**

The two `hacker` packs kept every id. Their old node 8 simply stopped being a
boss — `rust.hacker.08.top-k` and `go.hacker.08.kth-largest` are ordinary
quests now, and THE WHITEBOARD / THE CLOCK moved to the new node 24, both LRU
caches.

**Vocabulary: 38 → 58 slugs.** Nineteen algorithm and language slugs added
(`trees`, `tries`, `heaps`, `backtracking`, `disjoint-set`, `bit-manipulation`,
`matrix`, `math`, `prefix-sums`, `greedy`, `recursion`, `linked-lists`,
`async`, `dispatch`, `thread-safety`, `testing`, `panics`, `zero-values`,
`serialization`, `interior-mutability`). Two rules are now mechanical rather
than aspirational, and `--complete` fails the run on either:

1. every slug is used by at least one shipped quest;
2. every slug is named by at least one §7.1 mistake-kind row, or the
   `weakness` drill cannot reach it.

Rule 2 forced the `wrong-answer` and `timeout` rows to grow, and the split is
deliberate: `wrong-answer` reaches the *structure* concepts (trees, linked
lists, recursion, backtracking, matrix, bits), `timeout` reaches the concepts
whose whole job is making something cheaper (heaps, prefix sums, binary
search, hashing, DP). A player who keeps timing out should be handed heaps,
not more tree traversals.

**Two verifier checks added**, both of which caught real bugs in this round:

* **The brief's worked example must match a visible case.** `rust.hacker.24`
  shipped a brief whose sample output contradicted its own test, which would
  have read to a player as the quest being broken. Nothing else in the
  pipeline can see that class of error.
* **`--complete`**, above.

Four expectations in this round were wrong when first written and were caught
by running them, not by reading them: an `edit-distance` case, a `trie` node
count, a `prefix-sums` count, and a `knapsack` sample whose greedy answer
happened to equal the optimal one — which would have made the quest teach the
opposite of its point. That is the argument for SPEC §9.4 being CI and not a
review step.

*Owner to apply: BE (four boss ids), QA (four boss ids in any fixture).*

## 2026-09-11 — PM: README amended for the 0.0.0.0 bind

The warning paragraph said "do not expose the port to a network", which stopped
being true when `make start` began binding `0.0.0.0` so a phone on the tailnet
could play. Rewritten to say what is now true and still be worth reading: the
trainer runs submitted code on this machine as you; it listens on every
interface; a tailnet is your own devices and a café network is not;
`make start LOCAL=1` closes it; `make start` and `make remote` print what is
live. The run section also now says plainly that a phone uses **5390**, not the
dev server's 5291, and why — the page and the websocket have to share an
origin.

## 2026-09-11 — L2D: fullscreen, and a pin is not the same as a guess

**F / F11 toggles window ⇄ fullscreen**, matching `CausewaybayRaiden`'s README
("F / F11 | Toggle window / fullscreen") so a player who has used a sibling
already knows the key. `F` is swallowed only on screens that are not taking
text — in the editor and the login fields it is the letter — and `F11` always
works. Both are shown in the footer, which now carries the display keys
globally instead of each scene remembering to mention them.

`desktop` by default. `exclusive` changes the display mode, and a game that
exits badly while in it leaves the desktop rearranged; `CWBH_FULLSCREEN=
exclusive` is the way in, matching the sibling's `GOSET_FULLSCREEN`.

Two things taken verbatim from `CausewaybayRaiden/love2d/src/display.lua`,
both of which had been got wrong here: use `love.window.setFullscreen` rather
than `setMode` on an open window (macOS keeps the native Space instead of
dropping to legacy fullscreen), and keep the window **resizable even in
fullscreen** (SDL only puts a resizable window into a Space; a fixed-size one
falls back to `CGShieldingWindowLevel` and paints over the Shift-Command-5
capture UI).

### The orientation bug FE is chasing — this client had a version of it

The question was whether a *restored* orientation is treated as strongly as a
*pressed* one. It was, because there was no difference: `Layout.mode` was a
single value, saved and restored, with no record of where it came from.

It did not bite yet, for a reason that stops being true with fullscreen: this
client sized its own window to match the mode, so the mode and the window
shape could not disagree. **In fullscreen the shape is the display's**, so the
moment the toggle exists the bug is real — a landscape inferred once on a wide
monitor would survive into a fullscreen portrait display and never
re-evaluate.

Fixed with one persisted boolean, `pinned`:

* **pinned** — the player pressed F1, or `CWBH_ORIENT` was set. The window's
  shape gets no vote, in a window or fullscreen.
* **not pinned** — the mode was derived from the window and is derived again
  every time the window changes shape, the fullscreen transition included.
* A record written before the field existed reads as *not pinned*, which is
  the safe side: an unpinned mode is re-derived and a wrongly-pinned one
  never is.
* F1 cycles **landscape → portrait → automatic**, three states rather than
  two, because after one press a two-way toggle leaves a player pinned
  forever with no way back — and automatic is usually what you want in
  fullscreen.

`tests/test_display.lua` asserts all of it headlessly, including the
migration case. *FE: the one-line summary is that "restored" and "chosen"
must be different values, and the third state has to be reachable.*

### Two observations for BE, from driving the live server

Neither is reproducible now and both may have been a transient, so they are
recorded as observations rather than as bug reports.

1. **`world.map` briefly returned nodes not ordered by `node`.** §4.7 says
   "ordered by node"; for `rust/basic` the first array element was
   `rust.basic.12.traits`. A re-probe minutes later returned 18 nodes in
   correct order. If that window is the content re-import transaction (the
   negative-node parking described in BE's own entry), then a client reading
   `world.map` during an import can see it.
2. **`world.lands` disagreed with `world.map` at the same moment** —
   `rust/basic` reported `open: false` with `1/19` cleared while `world.map`
   showed a cleared node 1 and an open node 2, and `rust/hacker` reported
   `open: true` with nothing cleared. Consistent with `open` being derived
   from the same partially-imported ordering. Also clean on re-probe.

The LÖVE client now sorts `world.map`'s nodes by `node` on arrival. Nothing
depends on array order for correctness — positions come from `x`/`y`, paths
from `edges`, labels from `node.node` — but "the first node the player can
play" is a walk over that list, and one sort makes the screen right whatever
arrives.

## 2026-09-11 — L2D: the new-wallet confirmation is removed, at the user's call

`I HAVE WRITTEN IT DOWN` now derives, signs and logs straight in. The three-
word type-back is gone.

I argued for that gate and the argument still holds on its own terms — the
phrase *is* the account (SPEC §3), so one never actually written down is an
account that ends with the machine. The user looked at the screen and decided
the friction was not worth it. It is their wallet and their call, and it is
settled.

**No softer gate was substituted.** Not a checkbox, not one word instead of
three. A half-gate costs the interruption without buying the check, which is
the worst of both — so what does the work now is the copy and the address:
the words on screen, "this is the only copy. there is no reset." in red, and
the account the phrase derives shown beside it so a player can check the paper
in the drawer against what they are signed in to later. `src/scenes/login.lua`
says all of this in its header, so the next person to read that file finds the
reasoning rather than re-deriving it and re-adding the gate.

**Unchanged:** the ABI. `generate` returning the phrase exactly once is still
the design, still version 2, still the only op that returns key material, and
`describe()` still declares it. Only the screen flow moved.

Two properties the flow has to keep, both now asserted by
`tests/drive/newwallet.lua` against the live server:

* **a double press creates one account.** The button is the whole gate now, so
  a fast double-tap must not race two `auth.challenge`s. `create_wallet`
  returns early on `busy` *or* on `words` already being nil, and `submit`
  clears both before the first request goes out. Observed:
  `double press: 1 auth.challenge, 1 auth.login`.
* **the phrase does not outlive the screen**, whether it was used or
  cancelled. Observed: `cancel: phrase dropped, no account created` and
  `phrase: gone from Lua state after signing in`.

*FE: the model I passed on earlier is withdrawn — the browser should not gate
either, and should not gate more softly.*

## 2026-09-11 — BE: the importer reconciles a pack instead of parking it

Half the packs had stopped importing and the server was serving yesterday's
map behind a `WARN` line. Fixed, and the live database repaired: 116 quests,
six packs, zero failures, zero stranded rows.

**What it was.** `UNIQUE (land, category, node)` meeting an upsert keyed on
`id`. The old code parked a pack's nodes at `-node`, wrote the new ones, then
tried to put back whatever the pack no longer mentioned with an
`UPDATE OR IGNORE`. When a quest was *removed*, the node it used to hold was
already taken by a renumbered survivor, the `OR IGNORE` silently declined, and
the removed quest was left sitting on a negative node — **permanently, not
transiently**. The next import's parking pass then tried to move a survivor
onto that same negative number, hit the constraint, and rolled the whole pack
back. Every time, for good.

The real database carried the fingerprint exactly: `rust.basic.12.traits` at
node **-12**, `go.advanced.10.race` at **-10**, and two more.

**What it does now.** One `BEGIN IMMEDIATE` transaction per pack:

1. delete the rows this pack has that the file no longer names — which also
   frees the nodes they were holding;
2. park every survivor at `-1000000 - rowid`, unique per row and far outside
   anything content can ask for, so it cannot collide with a stranded row an
   older import left behind;
3. upsert each quest at its real node;
4. refuse to commit if anything is still parked.

Step 4 is the one that turns "a quest quietly off the map" into "this import
did not happen and here is why".

**Progress.** SPEC §2.2 is kept: an edited quest keeps its `progress`, because
this is still an upsert by `id`. A quest the file no longer names is deleted
and its progress goes with it — there is nothing left for it to be progress
*on*. Four ids moved this week (`rust.basic.12.traits` →
`rust.basic.18.traits` and three like it) because §12 makes the id carry the
node number and lengthening a map moves the boss. A rename is
indistinguishable from a delete-plus-insert without guessing, so it is treated
as the latter: those four clears are lost, which is free now and would not be
after release.

**Atomic for readers, not only on failure.** L2D saw `world.map` return
`rust.basic.12.traits` first, out of node order, with `world.lands` disagreeing
in the same window — `basic` reporting `open:false` despite a cleared node 1.
Both symptoms are the same stranded row: `ORDER BY node` puts -12 first, and
`first_node_open` therefore asks whether *traits* is unlocked instead of node
1. Not a race, and not a missing sort — the node values really were wrong, and
had been for as long as the old importer left them there.

The property is now asserted rather than assumed.
`a_reader_never_sees_a_half_reconciled_map` runs a second connection reading
the map in a loop while a 41-quest pack is reconciled on the first, and
insists every single observation is wholly the old map or wholly the new one,
ordered, 1-based and without duplicates. With the transaction removed it
fails on observation 119 with a 39-row mid-renumber map, so it is not
vacuous. `BEGIN` became `BEGIN IMMEDIATE` so a second writer is refused before
the first statement rather than half-way through.

**Loud, finally.**

* `serve` logs a failed pack at ERROR *and* prints it to stderr, with a line
  saying the database still holds whatever was there before. `--strict-content`
  refuses to start at all.
* `import` audits the database against the files afterwards and exits non-zero
  on either a failure or any drift, naming the missing and left-over ids.
* `doctor` prints a per-pack line — `in step`, `DRIFT: file 18 / db 19`, `NOT
  IMPORTED`, or `UNREADABLE` — and exits non-zero. That is the check that would
  have caught this on day one.

**Also:** `CONCEPT_VOCABULARY` was 38 slugs and `docs/concepts.md` now has 58.
Re-synced; the import of the new content is warning-free again.

**And the flaky test is fixed.** `limits.rs`'s harness now puts its home in a
directory of its own rather than at the top of `$TMPDIR`, so
`the_runner_itself_writes_only_under_the_home_it_was_given` snapshots a parent
nobody else is writing into. Five consecutive green runs.

---

## FE — a preference is an answer to a question, and the question was the window

The reported bug was "vertical/horizontal mode does not work": Chrome in a
window 1080 wide and 1730 tall, rendering the **landscape** layout into a band
across the top with nearly half the window left over. The login screen itself
was correct — the right layout for the wrong window.

It was not a CSS or a canvas-sizing fault. `Layout` follows the window unless
the player has pinned an orientation, and the browser build wrote that pin to
`localStorage` and restored it on every boot. One F1 press, once, in a wide
window, and every later session in every window was landscape for ever. The
canvases were covering the viewport the whole time; the *playfield* inside them
was 1075x907 of it.

Three changes, and they are three because the bug had three halves.

**A choice remembers the window it was made in.** `chosen,<mode>,<w>,<h>`. It
holds for as long as that window holds. The moment the window is a different
shape *and* that shape is decisive — 1.2:1 or more lopsided, so a phone or a
column, not a near-square desktop window that is not saying anything — the
choice is suspended and the layout follows the window again. Drag the window
back to the shape the key was pressed in and the choice returns. Suspended,
never discarded: a preference that evaporates on the first resize is not a
preference.

**Restored and chosen are different stored values.** A bare `portrait` or
`landscape` — everything written by the build that had this bug — now reads as
*not pinned*. That is the safe side and it is the one that unbreaks the players
who already have the bad record: nothing in that string says anybody ever asked
for it. (L2D reached the same conclusion on the LÖVE client independently and
sent the one-line version: "restored" and "chosen" must be different stored
values, and the third state has to be reachable.)

**F1 cycles landscape → portrait → automatic.** A two-way toggle strands a
player who has pinned an orientation with no way back to following the window
except clearing site data, and "no way back" is half of why a stale pin could
do this much damage. Three states, and the toast says which one you landed on.

Verified at five real window shapes rather than at one: a phone in portrait
(390x844), a phone on its side (844x390), the user's column (1080x1730), a wide
desktop (1920x1080) and a square one (1000x1000). Every one of them fills the
window edge to edge with no bands. The pair of orientation screenshots the
capture hook produces is *not* this test — it forces an orientation and then
looks at it, which is exactly the gap the bug lived in.

The bands themselves got better too, for the case where somebody chooses an
orientation the window disagrees with on purpose. The fall-off was computed
from the smaller of the two offsets, so a window with a two-pixel side band and
a four-hundred-pixel top band treated the top with a two-pixel gradient. It is
per axis now, and the playfield is edged in ink and gold: a screen set into a
cabinet, rather than a picture that stops.

## FE — the map is a place now, and the camera does not wander

Mode 7, the way the hardware meant it: the overworld painting is a texture on a
plane, a perspective camera looks at it, and the whole thing is rendered as a
second scissored pass inside the map plate. `gfx/mode7.ts` owns the projection,
and both the drawing and the hit-testing of every node go through the same
`project()` — that property is why the nodes have stayed where they are
clickable through three rounds of this screen.

Two things were tried and rejected in front of the frame.

**A steep tilt.** `map_rust.jpg` is an axonometric painting: the projection is
already baked into the pixels, and laying it down at eleven degrees makes the
buildings lean and turns the overworld into a photograph of a map lying on a
table. It is just under six degrees now — enough that the near edge is wider
than the far one and the ground has somewhere to go.

**A camera that leans toward the selected street while you browse.** This is
the thing the round asked for and it is not shippable on a *finite* plane. Any
resting lean means the fit has to hold the plate covered at the extremes of it,
and the slack that buys shows up immediately as the overworld sitting in the
middle of its own plate with a band of floor all round — the first frame of it
is unmistakable. The alternative is to fit tight and crop the difference, and
node 1 of `rust/hacker` stands at u=0.06, so a three percent crop takes half of
it off the map.

So the plate is filled exactly and the camera move is spent where it reads:
going *in*. Pressing ENTER pushes the camera toward the chosen street on the
expo curve while a circular iris closes on that exact point, swaps, and opens
on the quest screen. While the zoom is pushing, the plane over-fills the plate
and the lean is free. The map holds still while you read it and moves when you
commit, which is the better trade anyway.

`fg_wires` hangs in front of the ground and behind the markers. In front of the
markers it put the awning squarely over node 1. Only the top 55% of the source
is used: stretched whole across a plate this wide it is half the plate tall, and
the bottom two thirds of it are four hanging sign panels the size of awnings,
which sat over nodes 1 to 9. The signs are used at full size on the lands
screen instead, where there is sky to hang them in.

## FE — the tube, and what it is not allowed to touch

`gfx/crt.ts` is `CausewaybayGolang/love2d/src/crt.lua` — a dark line every other
row and one soft bar rolling down the screen — with three changes the browser
forces. The mask is a 1xn pattern stamped in one fill rather than four hundred
`fillRect`s. The vignette is built on resize, because `createRadialGradient` per
frame costs more than the gradient does. The scanline period follows the layout
scale, so the lines stay two *virtual* pixels apart at any window size.

No barrel distortion. Warping the frame means resampling the whole canvas on the
CPU every frame, and the thing it would bend most is the one thing that has to
stay straight: eighty columns of code.

It never touches the editor, and not by a rule somebody has to remember. The
stylesheet stacks `#overlay` — CodeMirror and the seed field — *above* `#game`,
and the tube is drawn onto `#game`. The editor's glyphs are structurally out of
reach of the pass. F2 toggles it, default on, and the choice is kept.

## FE — weight, and the frame it is actually visible on

Screen shake is `trauma²` with two sines on an accumulated clock — never
`Math.random`, so a shaken frame is the same shaken frame every run and the
capture hook stays deterministic. It is scaled by how you failed: a program that
would not compile is a wall, a wrong answer on case 3 of 8 is a near miss, and
shaking equally for both teaches nothing.

Two corrections that only came from taking the frame:

* At an amplitude of nine pixels a wrong answer moved the screen two pixels.
  It is twenty-six now.
* It fired while the result screen was still *sliding in*, so it was invisible:
  a shake underneath a whole-frame transition is not a shake. It waits for the
  screen to arrive and then hits.

`App.shake` refuses outright while the DOM overlay has anything in it. The
editor is a real element stacked above the canvas and a canvas transform does
not move it; a screen trembling around a perfectly still block of code reads as
a rendering fault, not as impact.

`ACCEPTED` gets hit-stop instead: the stamp travels, and then everything stands
still for an eighth of a second before it lands.

## FE — the opening is a sequence, not a loop

`scenes/story.ts` plays `docs/story.md` §2 over the eight `open_*` panels DESIGN
composed for it, typed a character at a time, with an iris on the cut to the
datacentre and a chip sting on the frame SKYNET is named. §2 only: the two
lands, the mascots and the antagonists are §3 and later, and an opening is the
loss and the reason, not the plot.

The skip is real. Any key, any click, at any point, goes straight to the login
screen — checked before anything else in `key()` and `pointer()`, and there is
no state in the scene that has to finish first. This screen creates no overlay
element, so there is nothing that can eat the first keystroke; it was tested by
dispatching exactly one and watching the scene change.

**It is not a loop, and that is deliberate.** A title screen that spontaneously
animates away while somebody is typing twelve words into the seed field is a bug
with a nice name, and the new-wallet panel makes that window long. So it plays
once from a cold boot when there is no session, ends on the logo, and hands
over. `STORY` on the login screen replays it on purpose. A boot that cannot
reach the server goes straight to login and not to the story — an error nobody
can see behind an attract sequence is worse than no attract sequence.

The captions are bottom-anchored rather than placed at a fraction of the height,
because every one of the fourteen panels was composed with its lower fifth left
quiet for exactly this and a box measured down from a fraction drifts out of
that band as the canvas grows.

The hold between beats is *not* cut by the reduced-motion scale. It is reading
time, not animation. Somebody who asked for less movement asked for less
movement, not for three sentences to be taken away faster than they can be read.

## FE — the gate on the new wallet is gone, at the user's instruction

`I HAVE WRITTEN IT DOWN` now derives, signs the challenge and logs in. It does
not return to the form and it does not ask for three of the twelve words back.

What that costs, once: the gate existed to catch somebody who clicks past the
phrase without recording it, and it will no longer catch them. The warning on
the panel — "This is the only copy. There is no reset" — is now the whole of the
protection, which is why it is unchanged. No softened replacement was added; a
half-gate has the cost and not the benefit.

Two properties held on to. The words are taken out of the scene and the field is
cleared *before* the first await, so a double press finds nothing to log in with
and one account is created rather than two challenges racing — verified by
pressing it twice in the same frame. And the phrase still never outlives the
screen: it is dropped the instant it is used and wiped again in `leave()`.

## 2026-09-11 — QA: the importer test that would have caught the stale-content bug

`store.rs::a_clear_survives_a_restart_and_a_reimport` re-imports a pack whose
**text** changed — a title edited — and asserts progress survives. That passes
whether the importer works or not, because nothing moved.

Content does not stay still. A quest gets inserted mid-map, one gets cut, a
boss moves to the end of a longer map — and SPEC §12 ties the id's number to
`node`, so every quest after the change is a new id *and* a new number.
`quests` has `UNIQUE (land, category, node)`, so an importer that upserts row
by row collides with rows still holding the old numbering.

The symptom when it happened was the worst kind: three of six packs silently
failed, the server logged a WARN and carried on serving **stale content**, and
the database and the TOML disagreed by whole quests. Nothing was red.

`backend/core/tests/importer_shape.rs`, 4 tests, all green:

* a quest inserted mid-map renumbers the rest, and the **old ids are gone**
  rather than lingering beside the new ones;
* a removed quest leaves no orphan `progress` row, and the quests that did
  not move keep their clear and their stars — SPEC §2.2's "progress is not
  thrown away for a typo fix";
* a boss moving from node 12 to node 18 of a grown map, built so the new
  quests take exactly the numbers the old boss and its neighbours are still
  holding — the maximally-collision-prone shape, and the one that shipped;
* an unappliable import is **reported**, and `content::audit_dir` then says
  the database and the file disagree. That last one is the important half:
  the failure mode was not "the import errored", it was "the import
  half-failed and nobody could tell".

The assertion throughout is not "the import returned Ok" but **the database
matches the file, exactly**, via `content::audit_file`. Three of the four
pass against the current code, so the collision is already fixed; these now
guard the fix.

**Worth wiring into `cwbhacker doctor`:** the audit is exactly the check an
operator needs, and a `doctor` that fails when the database and `content/`
disagree turns a silent WARN into something CI can catch. BE's call.

## 2026-09-11 — QA: the Go assertions are real now

BE built the Go runner, so the smoke case that asserted *"a Go submission is
refused"* was stale and has been replaced. It now asserts what matters:

* a Go submission is **judged** — a verdict from §5.4's set, and never
  `internal_error`, which tells a player their machine is broken and invites
  a retry that cannot work;
* the attempt reaches `stats.history` (PROTOCOL.md §4.9, "always recorded");
* a failed Go submission carries a **classified mistake**, because one that
  does not teaches nothing (SPEC §7.1);
* `undefined: tolal` classifies as `unknown-name`, and **the mistake code does
  not carry the player's own identifier** — otherwise `undefined: tolal` and
  `undefined: subtotal` are two rows, and §7.2's rollup never reaches five and
  never learns anything;
* the wrong `lang` for a quest is still `bad_request`, not a judgement.

The rule underneath is unchanged and is the one worth protecting: nothing
untrue may enter the curriculum. A verdict the server invented flows into
`mistakes`, then `mistake_stats`, then the drills, and the player is taught to
fix something they never did.

`search.query` and `ai.*` keep their `unavailable` + `detail.milestone: 2`
case. `unsupported()` still refuses the `cargo` and `gotest` harnesses, but
**no pack declares either** — all 116 quests are `stdio` — so that path is not
reachable over the wire and is not asserted from here. It is covered in
`backend/runner/tests/rust_runner.rs::unsupported_names_what_this_build_cannot_judge`.

## 2026-09-11 — QA: PM's verifier re-lifted, with its two new gates

`tests/content/verify_pack.py` is PM's file again as of today, picking up:

* **a brief's worked example must match a visible case.** It caught a quest
  whose brief showed `1 3` where its test expected `3 1` — unsolvable as
  written, and invisible to every other check including the reference
  solution, because the solution was right and the *prose* was wrong.
* **`--complete`**, which fails on any concept slug no SPEC §7.1 mistake kind
  can reach. A concept nothing can reach is a dead end the AI drills would
  point a player at.

Both are now in `tests/run-all.mjs`'s content step. The only local change to
PM's file is the paths, which were absolute to one machine; they derive from
the file's own location now and the scratch goes under
`$CAUSEWAYBAY_HACKER_HOME/build` or the system temp directory, never the
project tree.

**All 116 quests pass, with `--complete`**: 58 rust + 58 go, every reference
solution accepted and every starter rejected through the real runner, 58 of 58
concept slugs reachable.

## 2026-09-11 — RUN and SUBMIT are two different things

The HackerRank split, asked for directly. RUN compiles and runs against the
**visible** cases as often as you like; SUBMIT judges against all of them and
is the one that counts.

New message `quest.run` (PROTOCOL §4.9b), same payload shape as `quest.submit`
so a client can send either down one path. A run never clears a node, never
awards stars, never unlocks, does not count toward the node's `attempts`, and
is excluded from `stats.summary.accuracy` — otherwise iterating honestly would
look like failing repeatedly.

**But a run is still recorded, and its mistakes still enter the curriculum.**
`attempts.mode` is `'run'` or `'submit'`. A borrow-checker error is the same
lesson whichever button produced it, and the errors made while iterating are
the truest record of what someone is actually struggling with. SPEC §7 builds
the drills from that table, so discarding runs would mean training on the
tidied-up version of the player's week. The failure modes are symmetric and
both are easy: a query that forgets `mode` overstates how often someone fails,
and one that filters runs out of `mistakes` understates what they need to
practise.

`mode` defaults to `'submit'`, so every row written before today reads
correctly.

## 2026-09-11 — Every node is playable; the map's shape is advice

Asked for: "user can click any stage in the map." Nothing is locked. The server
never refuses a quest because an earlier one is unfinished, and `MapNode.state`
is now `open` or `cleared` only.

`requires` and `edges` stay, and clients should keep drawing the route — "where
do I go next" is a real question and the packs are written in a deliberate
order. It is advice rather than a gate.

The reasoning is what this product is. A trainer is not a platformer: somebody
with an interview on Thursday needs the dynamic-programming street on Tuesday
without first grinding eighteen quests about `&str`, and somebody who already
writes Go should not have to prove it to reach the concurrency map. Locking
optimises for a sense of progression the player did not ask for, at the cost of
the thing they came for.

`locked` stays in PROTOCOL §3.3's closed set, unemitted. Removing a code from a
closed set is the one change that breaks a client switching exhaustively on it,
and the cost of keeping a dead row in a table is nothing.

## 2026-09-11 — BE: RUN and SUBMIT, and why a clean run does not retire a mistake

`quest.run` is in (PROTOCOL §4.9b), one code path with `quest.submit` and a
flag. Migration `0002_attempt_mode` adds `attempts.mode` with a `'submit'`
default, so the 144 attempts already in the live database read correctly.

**The decision you asked for: a clean run does *not* advance `cleared_since`.**
The rollup is deliberately asymmetric between the modes.

* A run **can** reset it to zero, and does bump `count` and `last_at`. Evidence
  that you *still* make a mistake counts whoever produced it — that is the
  whole reason runs enter the curriculum.
* A run **cannot** advance it. Only a submit does.

The argument is about what the threshold was calibrated against. §7.3 retires a
kind at `cleared_since >= 5`, written when the only attempt there was was a
submit — five separate goes at a problem, each one a considered answer. If runs
advanced it, five clean runs would retire a kind, and five clean runs is one
minute of pressing a button while you fix an unrelated typo. "Learned" would
come to mean "compiled five times", and the weakness drill would quietly stop
teaching the thing the player is worst at — the exact failure the mode exists
to prevent.

The asymmetry is the point: evidence that you have stopped making a mistake
should cost more than evidence that you are still making it. A submit is what
costs something. And nothing is lost from the ranking, because `count` sees
every run.

`a_clean_run_does_not_advance_cleared_since` asserts both halves: six clean
runs leave it at 0, and the next clean submit moves it to 1.

**Queries changed.** `progress::record_clear`'s failure count (stars are about
the record), and `stats::summary`'s `attempts` and `accepted` — both, because
`accuracy` is one divided by the other and a numerator and denominator drawn
from different populations is not a number.

**Queries deliberately left alone.** `attempts::history` returns both modes and
now carries `mode` per row: a player looking at their own week wants to see the
iteration, not a tidied-up list of the times they pressed SUBMIT.
`mistakes::stats` and the `mistakes` insert take both, which is the whole
point. `stats::summary`'s **streak** counts both — a streak is "days you turned
up", and a day spent iterating is a day you turned up. `prune` deletes both.

**Hidden cases in a run.** A run is given a `TestSpec` built with
`visible_only()`, so the hidden cases are not "run and then withheld" — the
runner never receives them. Nothing to leak and nothing to accidentally report,
and `tests_total` counts the visible ones because those are the ones that ran.

## 2026-09-11 — BE: nothing is locked

PROTOCOL §4.7. `MapNode.state` is `open` or `cleared`; the server refuses
nothing on the grounds that an earlier node is unfinished.

`requires` and `edges` still travel and are still computed — they are the
suggested route and the line the map draws, and "where do I go next" is a real
question. They gate nothing. `progress::derive_state` lost its `requires`
argument entirely rather than keeping a parameter it ignores.

`State::Locked` stays in the enum and in `progress.state`'s CHECK so rows
written before this still read, and `Code::Locked` stays in §3.3's closed set
unemitted — removing a code from a closed set is the one change that breaks an
exhaustive client.

**`world::first_node_open` is gone.** Its answer was always true, and it was
the query that made the stranded-node bug visible in `world.lands` (the lowest
node was a parked -12, so it asked whether *that* was unlocked). A function
whose answer is a constant is worse than no function.

**`world.lands`'s per-category `open` is kept and made honest:** it is now
`total > 0` — is there anything here to play. A land-select screen can grey out
a category whose pack failed to import, which is more use than a hard-coded
`true`, and clients that read the field keep working.

**`progress.update`'s `unlocked`** keeps its name and its contents: the
dependents whose suggested prerequisites are now all cleared. The set is the
same; the claim softens from "these became playable" to "these are what comes
next on the route". A map still has something to light up.

### Tests changed, for QA's audit

Mine, all inverted rather than deleted — each still asserts something, and in
each case the new assertion is the stronger half of the old one:

* `core/tests/store.rs::locked_nodes_open_as_their_requirements_clear` →
  `every_node_is_playable_and_the_route_is_still_advertised`. Asserts every
  node is open on a fresh map, that the last node opens before the first is
  touched, **and** that `requires`/`edges` still describe the route. The risk
  when a gate is removed is that the dependency plumbing is deleted with it.
* `core/tests/store.rs::two_users_do_not_leak_into_each_other` — the two maps
  used to differ by a lock; they now differ by the stamp and the attempt count,
  which is what the test was always about.
* `server/tests/ws_flow.rs` — the `quest.get` → `locked` case became "the third
  node opens for a player who has touched nothing", and the two map assertions
  now check that *every* node is open.

**QA's, which I have not touched** — `backend/server/tests/integration.rs`,
two tests failing in four places:

* `clearing_a_node_unlocks_exactly_the_next_one_and_announces_it` (line 522)
  * line 548 — `let expected = if n["node"] == 1 { "open" } else { "locked" }`
  * lines 556–570 — submitting to a locked node expecting `quest.submit.err`
    with code `locked` and `detail.requires`
  * line 614 — `(3, "locked".into())` in the expected `by_node` vector
* `two_players_on_one_quest_at_the_same_time_stay_separate` (line 655)
  * lines 697–700 — `"locked"`, *"bob's node 2 unlocked on alice's clear"*

The `unlocked` half of the first test still holds and is worth keeping: §4.19
still carries the field and it is still the dependents of the node just
cleared. What needs rewriting is the gate, not the announcement. The isolation
test's point survives too — Bob's map differs from Alice's in the stamps, not
in what he may enter.

## 2026-09-11 — L2D: RUN / SUBMIT, an unlocked map, and Mei walks

### RUN and SUBMIT (§4.9b)

One code path, as the amendment intended: `Quest:execute(mode)` takes
`quest.run` or `quest.submit` and the payload is identical.

**RUN keeps F5**, the key the old single button had, because it is the reflex
one. **SUBMIT is F10** — five keys away, and the right-hand button of a pair
with a deliberate gap between them. Neither is a slip of the other by a
centimetre or by one finger. ctrl-Enter and ctrl-shift-Enter do the same two
things for hands that already know that idiom; the pane toggle moved off F10
to ctrl-TAB.

**A passing run is not a verdict.** It says `SAMPLE PASSES` in `Theme.cyan`,
never `ACCEPTED` and never in `Theme.admit`, the green this game uses for a
clear — and it stays on the quest screen rather than going to the result
screen, because a run is an iteration and bouncing the player out after every
one would make the reflex button feel expensive. The strip names what ran and
what did not: `1 / 1 samples`, `now SUBMIT — 2 hidden cases have not run yet`.

The copy is exact about the nuance: **"runs do not count against your stars —
but they are kept, and what went wrong feeds your drills."** "Runs aren't
saved" is false and is written nowhere; the line wraps rather than clipping,
because half of that sentence says the opposite of the whole of it.

The in-flight slot is now one slot for both (`M.EXECUTES`), not two checks on
`quest.submit` — a slot taken by one message type and released by the other is
a slot that wedges. Tested in all three orders, plus release on `.err`, a
wrong-type reply and teardown.

### Nothing is locked (§4.7)

`node_locked.png` is retired from the map. A padlock on a node the player can
walk into is a lie that costs them the quest they came for. `requires` and
`edges` still draw the route and the node card says `SUGGESTED AFTER …` in
cyan — advice, in the colour this client now uses for advice.

**One normalisation worth flagging:** a server that has not shipped §4.7 still
sends `state: "locked"`, and this client folds it to `open` on arrival. Not to
override the server — `quest.get` may still answer `locked` and the quest
screen renders exactly that — but because the map must not print a word that
contradicts what the map itself will let you do. It becomes a no-op the moment
BE ships.

### The walk

`Ease.expInOut` was already in the ported `ease.lua`; added `expo*` aliases and
`E.apply` so the curve is named the same thing as the browser's rather than
inlined in a scene.

She follows the drawn `edges`, by breadth-first search, so she walks the street
rather than the harbour; an unconnected node — reachable now that nothing is
locked — is a straight line, which is honest because there is no path to show.
One expo ease over the whole route, not per segment: accelerate once, arrive
once.

**Duration: 0.34 s floor, 0.85 s ceiling, square root in between.** The ceiling
is the number that matters — node 1 to node 24 is one press now, and a second
and a half of walking would make the map a toll. Expo's fast middle does most
of the work, so a long jump needs less extra time than you would guess.

**Skippable by any key**, not just the one that started it: a player reaching
for the next thing has already decided. A second ENTER lands her and does not
open the quest, so the press is never one they have to repeat.

**On DESIGN's caveat about frames 2 and 4.** Watched it moving in a real
window: at 4 fps the two passing poses do read as a slight limp, visibly. By
about 7 the eye stops resolving them as different poses and it reads as a
walk. **7 fps** is what shipped, and the cycle only runs while she is moving.

### Observed against the live server

Both server halves are still landing, so the drive script *reports* them and
asserts only this client's half:

* `quest.run` → `not_found`. The client shows "RUN is not on this server yet —
  SUBMIT still works", greys the button, and SUBMIT is unaffected — the same
  probe-and-render pattern as the milestone-2 screens.
* `world.map` still sends `locked` for 16 of 18 nodes. The client entered one
  anyway and let the server answer, which is the correct division either way.
* `Attempt.mode` is not yet on the wire; the client tolerates its absence.

### Two more for QA, from the same change

`tests/smoke/contract.mjs` §8.4 now scores 11/12. It provokes error codes and
asserts "7+ of the closed set"; `locked` was the seventh and PROTOCOL §4.7 has
just made it unemittable on purpose. The guard at line 773 (`find(n => n.state
=== "locked")`) already handles its absence — it is only the count at line 809
that needs to be 6+. Lines 1347 and 1403 accept `open`/`cleared` already and
need nothing.

The §8.4 *point* is still worth keeping exactly as it is otherwise: "every code
a client can meet is reachable" is the assertion that stops a code being
specified and never emitted. `locked` is now deliberately in that state, which
is the one exception the contract names.

## 2026-09-11 — QA: every test that asserted `locked`, and what it asserts now

PROTOCOL.md §4.7 made every node playable. Six assertions of mine were about
the old behaviour. **None of them was deleted and none was quietly relaxed** —
each became the inverse assertion, which is the one with consequences.

| where | asserted | now asserts |
| --- | --- | --- |
| `contract.mjs` §8.4 | a locked node refuses a submit with `locked` + `detail.requires` | **the deepest node on the map takes a submission from a player who has cleared nothing** — §4.7's own worked reason, the interview on Thursday. Plus: no node is ever `locked` |
| `contract.mjs` shapes | `state ∈ locked\|open\|cleared` | `state ∈ open\|cleared`, and the envelope validator now flags `locked` on **any** frame as a violation — a server that starts emitting it again has reintroduced a rule the spec removed |
| `contract.mjs` §8.4 closed set | "7+ codes provoked" | the set and the *reachable* subset are now separate claims. `locked` stays in `ERROR_CODES` (removing it would break an exhaustive client) and is listed in a new `NOT_EMITTED` set, with an explicit `assert(!seen.has("locked"))` |
| `integration.rs` unlock cascade | node 1 open, the rest locked; a locked node refuses | renamed `every_node_is_playable_and_a_clear_still_announces_the_route`. Asserts no node is locked, the **last** node accepts a solution from a fresh player and pays full stars, `edges` and `requires` still describe the route, and `progress.update` still carries `unlocked` — advice a client redraws from, not permission the server granted |
| `integration.rs` isolation | "bob's node 2 is still locked" | that is now true for bob whatever alice did, so it tested nothing. Replaced with what is genuinely private: **bob's node 2 has 0 attempts and 0 stars** |
| `integration.rs` restart | "node 2 is open after the restart" | also trivially true now. Replaced with the thing that must survive: the node's own `attempts` count (2 — a failure and a clear), and that an untouched node comes back with 0 |
| `e2e/journey.spec.ts` | node 1 open, the rest locked | renamed "every node on it is playable": nothing is `locked`, every node is `open` with 0 stars for a brand-new player, and `edges` are still there |

`e2e/fixtures.ts`'s `MapNode.state` is two values now, and
`identifyOpenQuest` no longer skips locked nodes because there are none.

## 2026-09-11 — QA: the `quest.run` invariant, which is asymmetric on purpose

PROTOCOL.md §4.9b. The property worth a test is not "a run runs" — it is the
accounting, which is easy to get backwards in **either** direction:

* a run does **not** count toward the node's `attempts` or
  `stats.summary.accuracy`;
* a run **does** put its mistakes into `mistakes` / `mistake_stats`.

Get the first wrong and iterating honestly looks like flailing — the star
grade goes with it, and a player is punished for using the button that exists
to be used. Get the second wrong and the curriculum is trained on the
tidied-up version of the player's week, which is precisely the thing SPEC §7
says the mistakes table is for.

Written twice, deliberately, because the two levels catch different bugs:

* `tests/smoke/contract.mjs`, "a run is for the player, a submit is for the
  record" — five runs then one submit over the wire. Asserts `mode: "run"`,
  `cleared: false`, `stars: 0`, **no `progress.update`**, `tests_total` equal
  to the *visible* count, every reported case `visible: true` (a run must not
  reveal whether the hidden cases pass — that is what submitting is for), the
  node still at **0 attempts** after five runs and **1** after the submit,
  the mistake total strictly up, `stats.history` holding all five runs, and
  accuracy that is 0 or 1 rather than something in between.
* `backend/server/tests/integration.rs`, `a_run_is_for_the_player_and_a_submit_is_for_the_record`
  — the same arithmetic through the real runner, which is where a
  `WHERE mode = 'submit'` in the wrong query shows up.

And §8.10 now covers the **mixed** pair, not just submit-then-submit: a run
while a submit is in flight, a submit while a run is in flight, and a run
while a run is in flight. A server keeping two locks — one per kind — passes
the old test and then compiles two programs at once the first time a player
presses RUN during a SUBMIT.

Both pass against the live server: smoke **20 checks, §8 12/12**;
`integration.rs` **8/8**.

## 2026-09-11 — L2D: land and category switch from the map

**TAB** switches land, **Q** switches category, both from the map itself, plus
two land buttons and three category tabs in the header for anyone who would
rather click. A keybinding nobody can see is not a feature, so the buttons and
the keys ship together and the footer names both.

The keys are `CausewaybayGolang`'s, deliberately: it switches its three
language tracks with TAB and its quests with Q, and the user has pointed at
that repo twice now for this kind of question. Its map puts "the three big
buttons" for the tracks on the map screen for exactly this reason; these are
the same idea with this game's two lands and three categories.

**A land switch keeps the category.** Somebody comparing how Rust and Go do
concurrency wants the concurrency map, not the top of GO BASIC. Asserted for
all three categories in `tests/test_mapswitch.lua`, because it is the one part
of this that is easy to get subtly wrong and never notice.

**A switch is a cut, not a walk.** Mei stands on a node of the map being left;
on the next map she is somewhere else entirely, and a walk left running would
interpolate between nodes that no longer exist. `switch` drops `walk`, `at`,
`adjacency`, `nodes` and the stamp animations in one place — the same thing
`CausewaybayGolang`'s `Game:setQuest` does when the track changes. The walk is
for moving *within* a map.

**Each map remembers the node it was left on**, keyed `land.category`, at
module level so it survives the scene being rebuilt — the sibling's
`Game.trackQuest` idea. That is what makes "nothing is lost by looking" true
rather than merely cheap.

Why this mattered more than it looked: removing the gates was so that somebody
with an interview on Thursday could go straight to the dynamic-programming
street. Reaching HACKER still cost ESC → lands → land → category, so the gate
was gone and the friction was not. It is now one keypress from the map.

### Re-run against the shipped server

BE's `quest.run` and unlocking are live, so the two things the last round could
only report are now verified end to end:

```
map states as the server reports them: cleared=1 open=17
run:    mode=run    verdict=wrong_answer 0/1 cleared=false
in flight: 1 quest.run, 0 quest.submit left the client
run:    accepted, 1/1 samples, cleared=false — still on the quest screen: true
submit: mode=submit verdict=accepted     1/1 cleared=false stars=2
switch: GO / HACKER in one keypress, straight from the map
memory: came back to node 5, where it was left
```

* `world.map` no longer emits `locked`, so the fold-to-`open` is the no-op it
  was predicted to be. It stays as one line, because a client that breaks when
  an old server is on the other end is a client that breaks during a rollout.
* `Attempt.mode` is on the wire — `run` and `submit` both observed.
* The shared execution slot held against the real thing: a second RUN and a
  SUBMIT pressed while a run was in flight were both refused locally, and one
  `quest.run` left the client.
* **`S1`/`S2` are retired.** Those screenshots were rendered from a synthetic
  `Attempt` and were labelled as proving the rendering and not the wire;
  `R5-run-failed.png` and `R6-run-passes.png` are the same screen from real
  server replies.

## 2026-09-11 — The playground, and why it is the opposite of RUN

A scratchpad: any Rust or Go, run it, see what it prints. No quest, no tests,
no verdict. Snippets are saved server-side per user so the same scratchpad
opens in the browser and in LÖVE.

**A playground run is not recorded and does not feed the curriculum** — which
reads as inconsistent with §4.9b, where a quest RUN *does*. The difference is
the join. A quest RUN is an attempt at a known problem, so its errors say
something about what the player cannot do yet, and §7.3's `weakness` drill
reaches them through that quest's `concepts`. A playground has no quest and
therefore no concepts: a `mistakes` row from it could never be joined to
anything, and would be dead weight in the table the entire curriculum is
derived from.

The second reason is about what a scratchpad is *for*. It is where somebody
deliberately writes something broken to find out what the compiler says. That
is the last thing that should be counted against them.

## 2026-09-11 — L2D: a server field, and the client's own store (SPEC §1.1)

### The server field

On the login screen, validated, saved, and applied by dropping the connection
and coming back on the new address. `Client:set_url` suppresses the reconnect
backoff across the teardown so the timer cannot race the move and bring the
*old* server back.

**Precedence, written down because a control that is silently ignored is a
lie:** `CWBH_SERVER` is a launch-time override and wins for that run;
otherwise the saved field; otherwise the default. Editing always persists, and
when an override is active the screen says *"CWBH_SERVER=… is overriding this
run — the field is saved for next launch"* rather than pretending.

Validation names the fault rather than letting the connection fail mutely:

```
""                         -> type a server address
"localhost:5390"           -> needs a scheme: ws://host:port/ws
"http://127.0.0.1:5390/ws" -> this is a websocket address — try ws://…
"wss://example.com/ws"     -> wss:// needs TLS, which this client does not have
"ws://127.0.0.1/ws"        -> needs a port: ws://host:5390/ws
"ws://:5390/ws"            -> no host before the port
"ws://127.0.0.1:5390"      -> needs a path: ws://host:5390/ws
```

`wss://` is refused rather than accepted-and-broken: LuaSocket has no TLS, so
this client genuinely cannot open one, and a tailnet or an SSH tunnel is the
answer rather than a scheme change.

Also added: a connection that will not open, with no token for that address,
now lands on the login screen. Before, a player who typed a wrong address sat
on the map with a CLOSED badge and nowhere to fix it.

### The store

`~/.causewaybayhackerlove2d`, `0700`/`0600`, append-only JSONL, replayed. The
four properties the wallet's own suite tests are asserted in
`tests/test_store.lua`: a malformed line is skipped, a newer `schema` is
skipped, a crash mid-write costs at worst the last line, and a value is the
last line that set it.

**The token is per server**, keyed by URL, as §1.1 requires. Switching to a
second address finds no token and asks; switching back finds the first one
still there. Verified live.

**Permissions needed the cdylib.** LÖVE has no `chmod` and `love.filesystem`
is sandboxed to a save directory this store deliberately does not use, so the
key library grew a `secure` op (ABI 2 → 3). It is the one operation there that
is not cryptography, and the header says so: it exists because the file holds
a credential and `0600` is not decorative. The fallback when the library is
missing is `os.execute("chmod")`, at most twice per launch rather than per
write; if neither works the store still functions and says so once.

**The old save is migrated once**, not silently discarded. Somebody is playing
right now with a session and a cleared map behind `love.filesystem`, and
losing them to a storage change would be a self-inflicted version of the thing
this game keeps warning players about. The old files are not deleted.

### Two bugs the new tests caught immediately

* **`map.cursor` was never written.** Its field was named `key`, and
  `check_no_secrets` refuses any field whose name contains "key" — which is
  there to catch `private_key` and its spellings. The refusal was correct and
  the field name was wrong; it is `map` now. Nothing in the game would have
  reported this, it would simply have forgotten where you were, forever.
* **An append after a torn line spliced onto it.** A crash mid-write leaves a
  line with no newline; appending straight onto that produced one unparseable
  line and lost the *good* record as well as the torn one. `append` now starts
  on a fresh line when the previous one did not end. That is the difference
  between "a crash costs the last line" and "a crash costs the last line and
  the next one".

### One note for PM

SPEC §1.1 says "the rules in §1.2 below apply unchanged", but there is no
§1.2 in `SPEC.md` — §1.1 is followed by §2. The rules were clear enough from
§1.1's own sentence and from `CausewaybayWallet`'s `store.rs`, which is what
§1.1 names, so nothing was blocked. Worth either writing §1.2 or pointing the
sentence at the wallet directly.

## 2026-09-11 — SPEC §1.1 pointed at a section that did not exist

Caught by L2D while implementing it. §1.1 said "the rules in §1.2 below apply
unchanged" — but §1.2 is in *CausewaybayWallet's* SPEC, not this one; ours goes
§1.1 straight to §2. The renumbering that was supposed to create it silently
matched nothing.

Fixed by inlining the JSONL rules so §1.1 stands on its own, with the wallet's
`store.rs` named as the reference implementation rather than as a load-bearing
cross-document reference. A spec that cites a section that is not there is
worse than one that repeats itself.

L2D was right to implement from the sentence plus the wallet's source and flag
the gap rather than guess at what §1.2 might have said.

---

## FE — a correction to the orientation entry above

The entry that says the vertical/horizontal fault "was not a CSS or a
canvas-sizing fault" and that one F1 press stranded every later session is
**wrong about the user's screenshot**, and this is the retraction.

The coordinator measured it: a restored pin does *not* survive a disagreeing
window in the shipped client, so that mechanism cannot have produced the
landscape band the user photographed. What the window-scoped pin and the
three-state F1 actually are is a correctness and usability improvement —
"restored" and "chosen" really are different stored values now, and the third
state really is reachable — and they should stay. They are not the fix for the
screenshot.

The defect in that screenshot was composition on the no-WebGL lands screen: a
background blitted with `drawImage(bg, 0, 0, vw, vh)` (a 2.3× vertical stretch
at 1080×1750, which is why it read as three rooms tiled down the page), a neon
strip of six untextured slabs, two land plates of different sizes, and a record
line drawn on the panel border. Those are fixed and photographed at 1080×1750.

The rule I am taking from it: when a bug arrives as a picture, reproduce the
picture at the reported size before naming a cause. I named a plausible
mechanism from the code, and a plausible mechanism that is not the one in the
photograph is a wrong answer that reads like a right one.

---

## FE — the twelve words are never thrown away

`I HAVE WRITTEN IT DOWN` used to take the phrase, null it, and then start the
login. When the socket was down — which is what the user's screenshot caught,
with `CONNECTION LOST — RECONNECTING` across the top — that sequence dropped the
player back on the login form having destroyed the only copy of the key they had
just been told to write down. The screen's own warning says "there is no reset:
nobody can give it back to you"; losing it to a transient socket error is the
worst thing this screen can do, and it was doing it.

Now: the words are held until the login *succeeds* (at which point the screen is
gone) or the player presses CANCEL (at which point it is their decision). A
sign-in that cannot reach the server parks on `reachable()`, which resolves when
the client's own reconnect gets back to `open`, and then goes — the button means
"sign me in as soon as you can". Five goes for a minted phrase; one for a typed
one, because a typed phrase still exists on paper and its owner is standing in
front of a form they can press ENTER on again.

Verified in the browser, against a socket deliberately pointed at a dead port:
the twelve words stay on screen, CANCEL stays live while WAITING FOR THE SERVER
is dim, the status wraps rather than clipping, and when the port comes back the
login completes on its own with no second press. A double press one frame apart
still produces exactly one `auth.challenge` and one `auth.login` — `busy` is set
synchronously before the first await, so the second press finds it already set.

The save/run split on the playground is the same lesson applied early: an
autosave failure and a run failure have separate lines, because the first
overwrote the second within two seconds of typing and the player could not see
why their program had not run.

---

## FE — the six maps, reachable from any one of them

TAB switches land, Q and E step the category, and the same six choices are on
screen as buttons — RUST | GO, BASIC | ADVANCED | HACKER — with ALL MAPS and
PLAYGROUND at the end. Keys and buttons ship together because a binding nobody
can see is not a feature, and a button is what the player who does not yet know
where anything is will find. The lit land wears its own colour (the orange and
cyan the lands screen and the map haze already use) and the lit category wears
gold, with a coin pip under each so the answer survives a colour-blind eye.

Switching **cuts**. Mei is standing on a street in Rust Land and the next frame
she is standing on a different street in Go Land, which is not a journey anybody
can animate honestly; the plate and the nodes replay their arrival instead. Each
of the six remembers where it was left, keyed by land and category, so going to
look at GO·HACKER and coming back costs nothing — which is the point of removing
the gates in the first place. Somebody with an interview on Thursday can be on
the dynamic-programming street in one keystroke.

One bug worth recording because it is a class: `barLayout` returned its rects
grouped by *line* while `drawBar` consumed them in *label* order, so on a narrow
window ALL MAPS was painted on top of PLAYGROUND. Two orders that are equal in
the common case and different in the rare one is a bug that ships. The layout
now returns rects in label order whatever line they land on.

---

## FE — measure the row before you reserve its height

The quest bench reserved one button row's height and drew the console drawer
under it. At 1280 across, RESET wraps onto a second line — and that second line
was painted straight through the run report, taking its first line off the
screen. It is the same fault as the phrase card that was sized for one row and
drawn with two, in a different file, three weeks apart.

So `rowsIn(font, labels, width, minH)` now lives in `engine/ui.ts` next to
`btnBox`, does exactly the arithmetic `Buttons.row` does, and anything that puts
something below a button row asks it first.

The run report is clamped twice on top of that: at most three lines, and never
more than three fifths of the drawer. `expected` and `got` are arbitrary program
output, so a program that prints a paragraph would otherwise size the strip off
the bottom of the panel. And the hidden-case count is on *both* paths now — the
failing one especially, because that is exactly when somebody might think they
have seen the worst of it.

TRY AGAIN carries the source back into the quest screen. It used to reload the
starter, which threw away the attempt the player had just made in order to show
them the verdict on it.

---

## FE — the rows are places now

The user's word was "not fun", and the diagnosis was right: three large blue
slabs holding a word, a count and a hundred and thirty pixels of nothing read as
a settings menu, not as three roads out of town.

Four things, in order of how much they changed it:

* **DESIGN's six emblems.** 3:1 bands, drawn from the manifest `box` and inset,
  owning the right of each row while the words own the left. The counts moved
  under the title to make that clean: a count floating over the picture read as
  a caption for it rather than as the score for the road. `emblem_rust_advanced`
  — the one DESIGN flagged as its weakest — reads fine in situ; the two tills
  are distinguishable at 1280 and at 900 portrait.
* **The mascot follows the cursor.** Hover ADVANCED and Ferris is working two
  tills; hover HACKER and he is stuck at a blank board. It ties the two columns
  together and it is the cheapest "this is a game" signal on the screen.
* **A line from the bible per road** (`docs/story.md` §4), clamped to the lines
  that actually fit — in portrait it wraps to four and the fourth was spilling
  over the row's own bottom edge.
* **Selection with weight.** The hovered row slides, takes the land's colour at
  a whisper, grows a chevron, and blips once on arrival rather than once per
  mouse-move event. The chosen land's mascot has an idle with a hop every few
  seconds, a shadow that tightens as he leaves the ground and a squash on the
  landing; the other land's mascot is still, which is the difference between
  "not selected" and "not drawn yet".

`LOCKED` is gone from this screen too. §4.7 says nothing is locked, so `open` is
no longer consulted; only a genuinely empty pack is dimmed, and it says EMPTY.
`badge_locked` therefore stays unused, which is the right outcome for it.

---

## FE — the playground, and why its rule is the opposite one

`scenes/playground.ts`. Write Rust or Go, press RUN, see what it prints. No
quest, no tests, no verdict, and — stated on the screen, where it cannot be
missed — **nothing here is part of your record**. That is deliberately the
opposite of the quest RUN rule, and the player has to be told which of the two
screens they are standing on, because a scratchpad is exactly where somebody
writes something broken on purpose to see what the compiler says.

The text is the whole point and there is no starter to fall back on, so it is
saved three times over: a debounced `playground.save` 2.5 s after the last
keystroke, a save on window blur, a save on leaving the screen — and a mirror
into `localStorage` on every keystroke, so a reload, a dropped socket or a
server that has not shipped §4.9c yet cannot cost work either. Identical content
is never sent at all; an autosave timer that posts the same bytes every two
seconds is a denial of service with good intentions.

There is a stdin box, which matters here in a way it never does on a quest
screen: there is no test case to supply the input, so without it there is no way
to write a program that reads anything.

Today the server answers `not_found` to `playground.run`, `list`, `load` and
`save`. The screen says so in plain words — "this server does not have the
playground yet", "snippets are not kept on this server yet — saved in this
browser" — rather than showing an empty list and pretending. Nothing is faked.

---

## FE — two notes for whoever takes the next screenshot

**The dev server serves a copy of the art.** `frontend/public/art/` is what
`:5291` reads; `art/` is the source of truth. DESIGN's fourteen new assets were
committed to `art/` and were simply not there for the browser until I rsynced
them across, and the symptom is an emblem that silently does not draw — the
manifest the page fetched has 49 entries while the repo's has 63. Worth
automating; until then, `rsync -a --exclude tools/ art/ frontend/public/art/`.

**A WebGL screenshot has to be read in the same task as the frame.** The context
is not `preserveDrawingBuffer`, so `__cwbCapture.png()` called after an `await`
composites an empty `#fx` — the Mode 7 ground and the whole city backdrop go
missing and the picture looks like a rendering bug that is not there. The
capture that works is `freeze(); step(1); png()` with nothing between them, and
that is also the deterministic one. Several of the shots I took earlier today
are wrong for exactly this reason and have been retaken.

`app.setOrientation` no longer persists a preference, either. It is the capture
hook's entry point, and a screenshot run was writing `chosen,landscape,…` into
whatever machine took the shots. The capture hook is not the player.

## 2026-09-11 — BE: the playground

`playground.run`, `.list`, `.load`, `.save`, `.delete`. PROTOCOL §4.9c
describes `run` and `save`; the other three I implemented in the obvious shape
and they want pinning in the contract:

```
→ playground.list    {}                    ← { snippets: [SnippetBrief] }   newest-updated first
→ playground.load    { id }                ← { snippet: Snippet }
→ playground.delete  { id }                ← { id, deleted: true }
```

`load` and `delete` on somebody else's id answer **`not_found`**, not
`unauthorized`: whether an id exists is itself none of that user's business.

**A playground run is not recorded, and the reasoning is a comment in
`server/src/playground.rs` where someone would otherwise "fix" it.** The
`address` argument is taken and deliberately unused, which makes the claim
visible at the signature.

**The caps.** An autosave timer against an unbounded table is a disk-filling
bug waiting for a stuck client, so: **64 snippets per user** and **256 KiB per
snippet**, names truncated at 80 characters. 64 is more scratchpads than anyone
keeps and small enough that a runaway client hits a wall in minutes rather than
filling a disk overnight; 256 KiB is the same limit `quest.submit` already has,
because one number for "a source file this server accepts" is easier to hold in
your head than two. Both refusals name the limit.

**Snippets are on disk as well as in the database** —
`users/<address>/snippets/<id>/{main.rs,snippet.json}`, 0600, beside the
attempts. Same reason as attempts (SPEC §1): it is the player's own writing,
and a database is a worse place to lose it from. A delete removes the
directory.

**Autosave is idempotent**: a save whose source, lang and name all match costs
one SELECT and no write, and returns the same `updated_at`. Without that a list
sorted by `updated_at` shuffles every few seconds while nobody is typing.

## 2026-09-11 — BE: XP, levels and the badge set (for DESIGN)

**XP** is `25 × stars × difficulty × category`, where `basic` = 1,
`advanced` = 2, `hacker` = 3. An easy first clear is 25–75; a three-star
five-difficulty HACKER quest is 1125. The spread is the point: the far end of
the map should not feel like the near end. It is **derived from the record**
(a join over `progress` and `quests`) rather than stored, so it cannot drift
from the truth.

**Levels** are triangular: level *n* begins at `100 × (n-1) × n / 2` — level 2
at 100, 3 at 300, 4 at 600, 10 at 4500. Every level costs a little more than
the last and none of them stalls. The whole content set three-starred is around
level 36. `User` carries `level`, `xp`, and now `xp_into_level` and
`xp_for_next` so a client can draw the bar without knowing the curve.

A level-up fires `award` with `kind: "level"` **for every level crossed**, so
somebody who jumps four at once is told four times rather than silently
skipped.

### The badge set, and its families

DESIGN's binding limit is distinguishability at 48px, not beauty at 256px, so
the set is built as **eight badge families plus the level chevron — nine
shapes**. Within a family the tiers differ by **colour and number only**; the
silhouette is the family. That is what keeps a row of them readable while
still letting the set grow.

| # | family (one shape) | ids | earn rule | how many |
| --- | --- | --- | --- | --- |
| 1 | **STAMP** — progress | `first-clear` | first quest cleared | 1 |
| | | `quarter-century` | 25 quests cleared | 1 |
| | | `cleared-<land>-<category>` | every quest in one map cleared | up to 6 |
| 2 | **STAR** — craft | `perfectionist` | 10 quests cleared at 3 stars | 1 |
| | | `no-hints` | 10 quests cleared without taking a hint | 1 |
| 3 | **FLAME** — streak | `streak-3`, `streak-7`, `streak-30` | that many consecutive days with at least one attempt | 3 |
| 4 | **CHAIN** — combo | `combo-5`, `combo-10`, `combo-25` | that many accepted **submits** in a row with no failure between | 3 |
| 5 | **STOPWATCH** — the clock | `beat-the-clock` | one HACKER quest cleared with `within_limit` true | 1 |
| | | `interview-ready` | five of them | 1 |
| 6 | **BROKEN SHACKLE** — mastery | `tamed-<kind>` | a mistake kind made ≥5 times whose `cleared_since` has reached 5 | up to 16 |
| 7 | **TWO FLAGS** — reach | `polyglot` | at least one quest cleared in **both** lands | 1 |
| | | `big-o` | 5 HACKER quests cleared | 1 |
| 8 | **TALLY** — volume | `century` | 100 submits | 1 |
| | | `iterator` | 50 runs — the RUN button is worth celebrating | 1 |
| 9 | **CHEVRON** — level | `level-<n>` | reaching level *n* | open-ended |

Family 6 is the one this game should be proudest of: *you used to make this
mistake five times over and you have not made it in five submits since*. It is
the premise of the AI mode expressed as a reward, and it is honest because
`cleared_since` only moves on a submit. Its detail carries the `kind`, so the
art can be one shackle with the taxonomy slug beside it rather than sixteen
drawings.

**Titles** are already in the data — every award row carries `title` and a
`detail` object, so DESIGN does not need a second copy of the naming.

### What is deliberately absent, and why

* **NIGHT OWL** — every timestamp here is UTC and the server does not know what
  time it is where the player is sitting. It would fire for an afternoon.
* **FAST CLEAR / SPEED** — `best_ms` is compile-plus-run time, not how long
  somebody took to solve it, and nothing measures thinking. The honest version
  of this is family 5, which exists because PROTOCOL §4.8b made the server own
  the clock.

The rule behind both: **only award what can be truly detected.** A badge that
fires on the wrong thing is worse than one nobody earns, because it makes every
other badge mean nothing. `awards.rs` states that at the top and every rule in
it is a query against the record.

### Wire shape, for pinning

Implemented and **not yet in PROTOCOL.md** — please spec or amend:

```
→ stats.awards  {}   ← { awards: [Award] }          newest first

type Award = {
  kind: "badge" | "stamp" | "level" | "streak";
  id: string;                 // "first-clear", "level-4", "tamed-borrow-after-move"
  title: string;              // "FIRST CLEAR"
  detail: object;             // whatever the rule counted
  created_at: string;
};
```

The live `award` event (§4.20) now carries the same `id`/`title`/`detail`, and
is broadcast to the player's other windows as `progress.update` already is.
`stats.awards` exists because the event is easy to miss and a client wants to
draw the shelf as well as the fanfare.

**`kind: "stamp"` is the exception**: the per-clear stamp fires every time a
node turns gold and is *not* stored, because it is not something a player
"has". Everything else is a row, and the `UNIQUE (address, kind, award_id)`
index is what makes "never awarded twice" a property of the database rather
than something the code has to remember.

## 2026-09-11 — BE: the countdown clock

PROTOCOL §4.8b, implemented. Migration 0005 adds `progress.opened_at` and
`attempts.within_limit`, both nullable with a NULL default — which is what
makes it safe on the live database.

**The two edge cases, decided:**

* **A quest cleared before the clock existed has no `opened_at`, and never
  grows one.** `open_clock` returns early on a cleared quest, so nothing is
  invented after the fact — the same rule as not writing an attempt row for a
  submission nobody made. Those quests report `opened_at: null`,
  `deadline_at: null`, and their old attempts report `within_limit: null`,
  which is the honest answer to "did they beat the clock": *nobody knows*.
* **Re-entering a cleared quest is untimed**, for the same reason and because
  your instinct is right: the clock is done, and replaying for practice is not
  a second interview. `deadline_at` comes back null.

`COALESCE(opened_at, ?)` is what makes the "same pair every time" guarantee
hold even when two windows open the quest in the same instant. `quest.reset`
does not touch it. A run never sets `within_limit`, because a run is not an
answer to the interview.

## 2026-09-11 — `code.format`, and why bad syntax is not an error

A FORMAT button on the coding screens, running `rustfmt` and `gofmt` — the
tools the player's colleagues use, not a house style invented here. Never
recorded: formatting is not an attempt at the problem.

**Unparseable source returns `.ok`, not `.err`.** A formatter is most often
pressed mid-edit, and half-written code is the normal state of a text editor
rather than a fault. So the original comes back byte for byte with `changed:
false` and the formatter's own one-line complaint in `problem`, and the client
says it quietly. Making this an error would put a failure dialogue in front of
somebody for the ordinary act of typing.

The rule underneath: **never return partially formatted text.** A formatter
that mangles code it could not parse leaves the player with two problems
instead of one, and destroys work that was not backed up anywhere.

## 2026-09-11 — BE: the formatter

`code.format` (PROTOCOL §4.9d), using `rustfmt --edition 2021` and `gofmt`
over stdin. Never recorded — formatting is not an attempt at the problem, the
same reasoning as the playground.

**Unparseable source returns the original byte for byte.** The tests assert
equality against the input rather than "an error was reported", because that
is the failure that would actually hurt: a formatter that hands back mangled
text destroys work backed up nowhere and leaves the player with two problems.
On a non-zero exit, a timeout, *or* an empty stdout from a zero exit, the
original comes back untouched with the tool's own one-line complaint in
`problem`. There is no path that returns partial output.

Ten-second timeout of its own, the submit cap on size, and it does **not**
take the execution slot: pressing FORMAT while a submission compiles is a
normal thing to do. It runs on a blocking thread because it spawns a process.

The tools keep their environment and get no rlimits — they are trusted tools
rather than the player's code. What they do get is the timeout and the output
cap, through exactly the same `proc::run` a submission uses.

## 2026-09-11 — PM: complexity is enforced by a seeded generator, not a big file

The acceptance criterion became "a player who clears everything can pass a
live screen". The audit is `docs/coverage.md`; its worst finding was that
**no quest rejected a correct-but-slow answer** — every hidden case was ten
elements, while several briefs claimed the quadratic answer would not finish.

The obstacle was that `stdin` lives literally in the TOML, so a 200000-element
case is about a megabyte of unreadable pack. **The input is generated instead
of stored**: `stdin` is `n seed`, the brief specifies an exact LCG, and the
program builds its own array. Twelve bytes of pack for 200000 elements.

Measured on this machine, with the two programs that ship inside the quest:

```
n=200000  merge-sort inversion count   0.02s
n=200000  O(n^2) double loop          >5s TIMEOUT (killed by the runner)
```

Verified that Rust's `wrapping_mul`/`wrapping_add` and Go's naturally-wrapping
`uint64` produce byte-identical arrays across six seeds, so the two packs can
share expected values.

`24.inversions` ships the naive answer **as its starter**; it is rejected for
being slow. That is the only quest in the repository where the complexity claim
in the brief is a thing the tests actually do, and the brief says exactly that.

**QA:** one hidden case in each `24.inversions` deliberately runs for the full
5 s timeout. A content-CI run costs ~10 s more because of it. That is the
feature, not a flake.

**`match = "float:1e-6"`** (SPEC §5.2) was unused by all 116 quests and is now
exercised by `26.statistics` in both languages — worth knowing before the
importer and the runner are assumed to handle only `trim`.

**Four boss ids moved again**, for the same §12 reason as last round: the boss
must be the last node, and the maps grew.

| was | is |
| --- | --- |
| `rust.hacker.24.lru` | `rust.hacker.28.lru` |
| `go.hacker.24.lru` | `go.hacker.28.lru` |
| `rust.advanced.16.deadlock` | `rust.advanced.17.deadlock` |
| `go.advanced.16.race` | `go.advanced.17.race` |

Slugs unchanged. This is the second renumbering and it is the last one that is
free: once anyone has cleared a node, §4.1 wins and ids freeze, at which point
a lengthened map means an id whose number no longer matches its node. **That
conflict between §4.1 and §12 should be resolved in the spec before release** —
PM's recommendation is that §12's rule be relaxed to "the id's number is the
node it was *created* at", which keeps ids stable and keeps the importer's
check meaningful.

**`time_limit_s` re-reviewed** now that PROTOCOL §4.8b makes it enforced and
displayed. Ten limits moved; the banding and the reasoning are in
`docs/coverage.md` §3. The one that is worth repeating: the same problem is not
the same length in both languages — `linked-list` went to 1200 s in Rust and
stayed at 900 s in Go, because `Option<Box<Node>>` reversal is fiddly in a way
the `*Node` version is not.


## 2026-09-11 — L2D: the art round, the motion, the clock, and FORMAT

### `src/anim.lua` — one pure module, so motion stays headless-testable

Every effect is a function of time returning a number: `bob`, `lift`, `press`,
`shake`, `stamp`, `iris`. No `love.`, no clock of its own — the game hands it
`love.timer.getTime`. That is what makes "no effect may require a window to
test" true rather than aspirational: a bob is a formula, and a formula can be
asserted at chosen instants.

A drive script can `freeze` that clock, so a screenshot of a bobbing mascot is
the same screenshot every run. The game still animates; only captures stand
still. `Anim.shake` is built from two sines rather than `random` for the same
reason — a screenshot of a shake must repeat.

### The screens

**Lands** — the user's note was "add more sprites in each button — not fun".
Eight sprites now instead of two: each land's mascot idling on top, and every
category row carrying its own action sprite (`mascot_<land>_<category>` —
Ferris up a crate, Ferris working two tills, Ferris stuck at a blank board),
each on its own bob phase so the row does not pulse in lockstep. Plus a
progress rule per row, `badge_cleared` on a finished category, and a card that
physically lifts with a shadow under it.

Also fixed while in there: the rows were arriving **alphabetical** — ADVANCED,
BASIC, HACKER — which reads as a list of words rather than a path through a
subject. `src/scenes/categories.lua` had been sorted and this screen had been
left out of that change.

**Categories** — the full-width emblem bands, and **the trap was real**.
DESIGN composed each with an empty left quarter for the label and `process.py`
then cropped to the ink and re-centred; the manifest proves it
(`emblem_go_basic` has ink from x=24 to x=359 of 384). So the label sits in
its own gutter with the band inset beside it, not on top of it.

And a second adaptation the brief invited: a 3:1 emblem drawn `cover`-style
into a row nearer 9:1 threw away two thirds of the picture — what shipped
first was a horizontal slice of a tram. The band is now drawn at its own
aspect, as tall as the row, anchored right, with a short fade on its left
edge. Checked against this client's proportions rather than assumed from the
browser's, as instructed.

**Map** — every node bobs on its own phase with a shadow grounding it, and
picking one irises out of that node into the quest screen. Measured live:
1.00 → 0.00 over 0.26 s, then the handover. Any key lands it immediately.

**Feedback** — a failed verdict shakes the banner; a failed run shakes the run
strip. **Only** those. The editor pane never moves: it is where somebody is
reading their own program, and shaking the code would have been the worst
thing this round could ship. The CLEARED stamp holds a beat, then lands
oversize and settles — an instant stamp reads as a state change, a held one
reads as a verdict.

### The clock (§4.8b)

`src/clock.lua`, pure: `(deadline_at, now)` in, remaining/phase/format out, so
the suite asserts a countdown without waiting a second. Four phases with
thresholds that are `max(fraction, floor)` — a pure fraction gives a
one-minute quest a five-second warning, a pure constant warns for half its
length.

**Calm for most of its life.** `Ease.attention` is flat zero until the last
quarter; the motion is three one-shot pulses (arrival, threshold, deadline).
Overtime counts up, in red, with a sign and a caption that says the quest is
still open.

Wall time is `os.time()` pinned to `love.timer.getTime()` at startup: real
time, sub-second, and — unlike a counter fed by `dt` — still counting while
the window is occluded. That is the same trap that once turned a 90-second
drive timeout into half an hour, and the same fix.

### FORMAT (§4.9d)

**F2**, not F4 — `main.lua` takes F1/F3/F4/F11 globally and a FORMAT bound to
one of those would silently never fire.

The caret work is in `Editor:replace_all` and is the part that mattered:
`rustfmt` overwhelmingly changes whitespace, so the caret is anchored to the
**text** — the line's stripped form, and the count of non-whitespace
characters before the caret — not to a coordinate. Indentation can change by
any amount and the caret lands between the same two characters; a file of
twenty `}` lines picks the nearest; a line the formatter destroyed falls back
to the line number. One `push_undo`, so ctrl-Z is one press. Nine headless
cases.

`problem` renders in the hint register and the buffer is untouched;
`changed: false` says "already tidy" rather than flashing an identical buffer.

### What I tried and rejected

* **A blink, and a steam drift.** Built and tested, then **deleted**. Every
  mascot in `art/` is a single frame with no closed-eye variant, so a blink
  could only be faked by squashing a whole crab vertically — which reads as a
  rendering bug. A steam plume in front of a 28px sprite on a category row is
  noise at that size. Three tested functions nothing can call is worse than
  their absence.
* **The neon palette cycle.** `art/palette.json`'s six measured tube/face
  pairs are exactly the right data for it, and I wrote and tested the hue
  rotation — then deleted that too. There is no screen in this client that
  composes a neon sign: the map plates are painted with the signs already in
  them, and the only surface a separate strip could overlay is the one
  somebody writes code on. Inventing a composition DESIGN did not ask for, on
  the screen the legibility constraint protects, was the wrong trade. The data
  is still there the day a screen wants it.
* **The view pushing in on the map on select.** The iris does that job for a
  fraction of the risk: a zoom of a `cover`-drawn plate has to rescale the
  node coordinate mapping mid-animation, and Mei and the cursor drifting off
  the path during a transition would be a real bug in exchange for a small
  effect.
* **Anything on the editor pane.** No shake, no bob, no colour cycle. The
  constraint is not negotiable and it is the reason the shake is on the strip
  and the banner instead.

### Server status at the time of writing

`quest.get` returns `time_limit_s: 600` but no `opened_at` / `deadline_at`, and
`code.format` answers `not_found`. Both degrade the way the milestone-2 screens
do: the clock simply does not appear, and FORMAT greys itself and says "FORMAT
is not on this server yet — SUBMIT still works". The clock's four registers
were verified from a synthetic `opened_at`/`deadline_at` pair in §5.3's shape —
**rendering, not wire**, and to be re-captured against the real thing the way
`S1`/`S2` were.

---

## FE — the clock is the server's, and the screen only reads it

§4.8b. `Quest` carries `opened_at` and `deadline_at`; the quest screen derives
"how long is left" from the deadline and the app's clock **every frame** rather
than decrementing a counter of its own. A decremented counter is wrong by
exactly the time a backgrounded tab was away, and a trainer that lies about the
clock is worse than one with no clock.

It blocks nothing, which is the part worth writing down. Time runs out, the
quest stays open, the countdown keeps going — `OVERTIME +00:03` in the brick
colour, bar full — and SUBMIT is exactly as live as it was a second earlier.
The server records `within_limit`; the screen records nothing and stops nobody.
A trainer that throws you out mid-thought has taught you that you are out of
time, which you already knew.

The motion is deliberately almost all in the transitions. It arrives on the expo
curve and settles; it beats once when it crosses a minute, once at thirty
seconds and once when it runs out, each with a chip note; and the rest of its
life it is a number that does not move, because somebody is reading code two
inches to the right of it. The pulse is a swell of the *plate*, never a shake of
the digits — the number has to stay readable at a glance the whole time —
and `prefers-reduced-motion` halves the swell rather than removing it.
`CLOCK.warn`, `CLOCK.urgent` and `clockPulse()` live in `engine/motion.ts` with
the other durations, so the next screen that needs a countdown does not invent
its own numbers.

The one place the game is now allowed to read the wall clock is `App.now()`,
and it stands still while the capture hook is frozen. A clock is exactly the
thing that turns a reproducible screenshot into a flaky one, so the exception is
one function with a comment on it rather than a `Date.now()` in a draw call.

Verified against a stand-in for the server (the reply rewritten in the browser
so it carried a deadline): `TIME LEFT 01:01` in cyan, the threshold beats, and
`OVERTIME` counting up with the quest still open and SUBMIT still green.

---

## FE — FORMAT, and the caret

§4.9d, on the quest screen and in the playground, on a button and on
Ctrl/Cmd+Shift+F. Three outcomes, three registers: formatted, "already tidy"
(nothing is touched — replacing a buffer with an identical one makes a button
feel broken), and a formatter's complaint about source that does not parse,
shown *quietly* and with the buffer left exactly as it is. Half-written code is
the normal state of an editor, not a fault.

The part that is ours alone is the caret. `Editor.replaceAll` trims the common
prefix and suffix and dispatches only the span that differs, so CodeMirror maps
the existing selection through the edit: a caret above or below the reformatted
span does not move at all, and one inside it lands at the end of the span. A
`setState` would have been one line and would have dumped the cursor to the top
of the file, which is infuriating when FORMAT was pressed mid-thought.

The binding is Ctrl+Shift+F rather than the editor-conventional Shift+Alt+F
because of this game's own plumbing: a keystroke only reaches a scene from
inside the editor when Ctrl or Cmd is held, so Shift+Alt+F could never have
arrived. It is in the footer, which is where a player finds out.

While adding the button I found the message bar painting over the button row —
the row wraps to two lines at 1280 with FORMAT on it, and the bar was an overlay
across the bottom of the body. The panels give up its height now instead, so
nothing is ever drawn underneath it. That is twice in one round that something
was drawn over a button, both times because a height was assumed rather than
measured.

---

## FE — the lands screen says which kind of nothing

A category with `open: false` is no longer drawn as a locked road, because
nothing is locked (§4.7) — it means the pack did not import, which is a fault
and not a rule. The row says `NOT INSTALLED` and wears `badge_locked`, which is
the one place in the game that padlock is allowed to appear. It never goes on
the map.

## 2026-09-11 — QA: e2e is 6/9, and the reason is one missing hook

Three e2e tests went red when `quest.run` landed, and the diagnosis is
complete:

* `Ctrl/Cmd+Enter` used to submit. §4.9b gave that key to **RUN**,
  deliberately — *"Submitting is a decision and it is made with a button, not
  with the shortcut somebody's hands press without looking"*. A run stays on
  the quest screen, so the suite waited three minutes for a result screen that
  was never coming. **That is the test working**: no unit test on either side
  would have noticed the key moving.
* SUBMIT is now a canvas-drawn button with no keyboard binding, and it raises
  a confirmation dialogue. A geometric scan over the bottom half of the plate,
  answering the dialogue with Enter after each click, does not reach the
  result screen.

The three red tests are `a wrong answer…`, `the right answer…` and `logout,
then a second wallet…`. The six that pass include the two with the most
teeth — the seed never crossing the wire, and the map being playable.

**This is the third time a canvas-only control has cost a full run** — the
category rows twice (wrong column, then wrong y range), the submit button now.
More scanning is not the answer. The ask from the earlier entry stands and is
now the single highest-value thing anybody could hand this suite:

```ts
// on __cwbCapture
buttons(): { id: string; rect: [number, number, number, number] }[];
```

Every scene already builds a `Buttons` list with exactly that shape
(`ui/chrome.ts`), so it is a getter, not a feature. With it, `submit()`
becomes one click on `#submit`, `pickFirstCategory` becomes one click on
`cat:basic`, and three fragile helpers and a whole class of
silent-wrong-thing failures go away.

Until it lands, treat an e2e failure in `submit()` or `enterRustQuest()` as
"a canvas control moved" before believing it is a product bug — the error
messages say so.

## 2026-09-11 — SPEC §12 and §4.1 contradicted each other; §4.1 wins

§4.1: an id is stable forever, and if a node moves the `node` column changes
and the id does not. §12: the id's number must equal `node`. Both cannot hold,
and §12 was the one being enforced.

It cost four boss quests their ids on three separate occasions — every one a
delete-and-insert that discards whoever had cleared them. Free so far only
because nobody has a real save. PM flagged it as the last free renumbering and
was right to.

§12 is now relaxed: the number in an id is the node the quest was **created**
at, `node` is the authority on where it sits today, and a pack may legitimately
have ids that look out of order. The importer still checks shape, land,
category and uniqueness.

The lesson worth keeping: a spec can hold two rules that are each sensible and
jointly impossible, and the way it surfaced was someone implementing them both
and noticing the cost — not review.

## 2026-09-11 — L2D: the clock and FORMAT from the wire, and the playground

### The clock, re-captured — and the caret anchor was wrong

Both flags are cleared. `quest.get` returns the real pair
(`opened_at=2026-09-11T07:04:33Z`, `deadline_at=…T07:14:33Z`,
`time_limit_s=600`) and all four registers were photographed from **that
pair**: only the client's view of *now* was moved, by `Clock.shift`, which is
the same affordance as `Anim.freeze` and the only honest way to see ten
minutes of a server-issued deadline inside one run. `calm` is captured with no
shift at all.

BE's two null-pair rules are pinned in `tests/test_clock.lua`: a quest cleared
before the clock existed never grows an `opened_at`, and re-entering a cleared
quest is untimed. Both already produced "no clock" — a limit with no deadline
is a fact about the quest, not half a clock — but they are asserted now rather
than assumed.

**And running FORMAT against the real `rustfmt` found a real bug in my caret
anchoring.** Against a fixture that only re-indents, matching the caret's line
by its stripped content was perfect. Against a real formatter on a long
one-liner — which is *exactly* when somebody reaches for FORMAT — rustfmt
splits the line, no line matches, the fallback fired, and the caret went to the
end of line 1.

The anchor is now the **ink stream**: "after the Nth non-whitespace character
of the whole document", restored by counting to the same N. Indentation,
spacing and line breaks can all change and the caret still lands between the
same two characters. The exact-line pass is kept as a fast path because it is
exact when a line does survive. Measured on the wire: **42 document ink before
→ 42 after**, caret still immediately before the same `=`, having moved from
line 1 col 46 to line 3 col 16 across a genuine rustfmt split. New headless
cases cover split, join and total rewrite.

This is the second time a fixture flattered an implementation that a real tool
broke. Worth remembering: a formatter test that only re-indents is testing the
easy half.

### The playground (§4.9c)

Mei's desk: snippets list, editor, stdin, RUN, FORMAT, and an output pane.
Reachable with **P** from the map *and* from the land select, because it
belongs to nobody's curriculum and should not require picking a land first.

DESIGN's note was that nothing there is scored, so compiler output must not
speak in the failure register and the word "wrong" must not appear. That is a
constraint on language, and language is the easiest thing to break by accident
six months later — so `tests/test_playground.lua` pins it: every string
literal the scene can put on screen is checked against a banned vocabulary
(*wrong, fail, invalid, accepted, rejected, verdict, correct*), and the scene
is asserted not to reference `Theme.red`, `Theme.verdict`, or the rejection
chime. The five outcomes are described rather than judged — `ran`, `did not
compile`, `stopped early`, `took too long`, `printed too much`.

Its background scrim is lighter than every other screen's (0.52 against 0.76):
DESIGN made `bg_playground` and deliberately nothing else, and a dim that hid
the one asset the screen has would have been drawing it and then covering it
up.

**Verified from the wire that a playground run does not feed the curriculum.**
Ran a deliberate `borrow-after-move` — a real `E0382` with two diagnostics —
and compared `stats.summary` and `stats.mistakes` either side:
`attempts 9 → 9`, `accuracy 0.222 → 0.222`, `mistake kinds 3 → 3`. That is the
claim §4.9c makes and it holds.

**`playground.run` shares the one execution slot.** §4.9c says "the playground
is the same runner", and the server confirmed it: three concurrent
`playground.run`s came back `busy`. Added to `M.EXECUTES` so this client
refuses the second locally rather than sending a request whose answer it
already knows. `code.format` is deliberately *not* in that set — formatting is
not a run and must not block one.

### One note for PM

**PROTOCOL §4.9c documents two playground messages; five shipped.**
`playground.run` and `playground.save` are in the contract; `playground.list`,
`playground.load` and `playground.delete` are not, and this client is written
against them. Their shapes were established by probing the live server:

```
playground.list   -> { snippets: SnippetBrief[] }
playground.load   -> { snippet: Snippet }          not_found on an unknown id
playground.delete -> { }                           not_found on an unknown id
```

`SnippetBrief` is §5.9's shape and carries `bytes`, as documented. The probe
also distinguished a real-but-empty answer from an absent message type: an
unknown id answers `not_found` with "no such snippet", while a message type
that does not exist answers "no message type 'x'" — which is how the five were
identified in the first place.

---

## FE — `__cwbCapture.buttons()`, and SUBMIT gets a key

QA asked for the button list and it was the right thing to ask for. A canvas
control has no DOM node, so an automated run has either a list of ids or a
geometric scan of the pixels — and the scan breaks every time a row re-wraps,
which is exactly what happened when FORMAT pushed RESET onto a second line and
took three tests with it.

`Buttons.list()` exposes the array the class already hit-tests against; every
scene with buttons implements `Scene.controls()`; `capture.ts` flattens them
into `{id, label, dim, rect, client}` and `buttonAt(id)` gives the centre in CSS
pixels. The rects come from the same objects a click is tested against, so the
hook and the game cannot disagree about where a button is. Dev and
`build:e2e` only — verified absent from `dist/assets/*.js` and present in
`dist-e2e`.

**SUBMIT is Ctrl/Cmd+Shift+Enter.** Not a new shortcut to learn: it is the RUN
key with SHIFT, an escalation of the one the hands already know, and not
something a thumb finds by accident. It exists because a primary action
reachable only with a mouse is an accessibility gap — FORMAT had a binding and
the button that decides whether a street is cleared did not. It is in the
footer.

While driving the new hook I found a real bug that no unit test would have
caught: **`auth.login` on an already-authenticated socket is refused** —
`bad_request`, "open a new one to change user", and the server is right (§3.1).
A player who reaches the login screen with a live session (a second wallet in
the same tab) got "something went wrong here, not on the server" and could not
get in. `Client.restart()` now trades the live session for a fresh anonymous
connection before the challenge, which is what "log in as somebody else" means
at the wire level. Reproduced, fixed, and re-run: the new wallet signs straight
in.

---

## FE — verified against BE's implementations

Everything I had marked as unverified is now verified against the real server,
except where noted:

* **Playground** — `playground.save` and `playground.list` round-trip (the
  server names a new snippet by date, and the row appears in the list);
  `playground.run` compiled and ran, `IT RAN · 170 ms compile · 372 ms run ·
  exit 0`, printing `42`. Fixed one thing the real data exposed: a
  server-assigned name is a date and it ran straight under the language tag, so
  the name is now measured against the width the tag leaves.
* **`code.format`** — real `rustfmt` reformatted the buffer through both the
  button and Ctrl+Shift+F.
* **The clock** — `TIME LEFT 09:12` on `rust.hacker.01`, from BE's
  `deadline_at`. The overtime shot in `frontend/shots/` is still the forced one
  (`45-…-forced`): reaching overtime honestly takes ten minutes, and the state
  it shows is the same code path.
* **The caret through FORMAT** — this one is *not* verified end to end. The DOM
  selection is not a reliable probe for CodeMirror's own selection in this
  harness, so instead the half that is ours is now a unit test:
  `narrowEdit(cur, next)` trims the common prefix and suffix, and
  `tests/editor.test.ts` checks that a change at the top cannot reach a caret at
  the bottom and vice versa. The mapping itself is CodeMirror's guarantee.

Also fixed while looking at a real HACKER brief: the text ran under its own
scrollbar. The brief now reserves that gutter permanently — a width that
changed when the bar appeared would reflow the text that decides whether the
bar appears.

## 2026-09-11 — PM: six interview gaps closed; and a collision with PM2 to reconcile

`coverage.md` §5's ordered list was the brief: Dijkstra, range queries with
updates, longest palindromic substring, a modular counting problem, grid DP
with obstacles, and a stability-sensitive sort. All six are written **in both
languages**, as `hacker` nodes 28–33, taking each pack to 34.

**Collision.** The Go half was finished and verified before the message
arriving that PM2 owns `content/go/**`. No further writes to `content/go/`
have been made since. The six Go quests occupy **nodes 28–33**, with ids
`go.hacker.29.dijkstra`, `.30.range-queries`, `.31.palindrome`, `.32.modular`,
`.33.grid-paths`, `.34.stable-sort`; the LRU boss sits at node 34 keeping its
original id `go.hacker.28.lru`. All 4/4 on every case, every starter rejected.
If PM2 appends its own six, the pack gets duplicate slugs and the reorder tool
will refuse it. **Coordinator to decide which half survives.** They are not
quite interchangeable: the Go half's expected values were derived from the
*same* LCG draw order as the Rust half and checked byte-for-byte against it
across six seeds, so the two packs currently share their generated data. A
freshly authored Go half re-derives every expected value independently, and
that cross-check is gone. The recommendation is therefore to keep this one —
but it should be discarded without argument if PM2's is further along on
anything not visible from here.

**No new concept slugs are needed for the six.** They are covered by the
existing 58: `graphs`, `heaps`, `complexity`, `prefix-sums`, `collections`,
`strings`, `two-pointers`, `math`, `recursion`, `dynamic-programming`,
`matrix`, `sorting`, `slices`. PM2 can use those directly.

**Complexity enforcement: four of the six carry it, two do not, and the briefs
say which.** Measured on this machine with the programs that ship in each
quest:

```
dijkstra       heap            0.02s   |  linear-scan min   >5s TIMEOUT
range-queries  Fenwick         0.10s   |  loop-per-query    >8s TIMEOUT
modular        factorial table 0.04s   |  per-query inverse >5s TIMEOUT
palindrome     expand-centre   0.13s   |  check-every-substring >5s TIMEOUT
grid-paths     DP              0.01s   |  (enumeration is super-exponential)
stable-sort    n/a — this one is about correctness, not speed
```

`range-queries` needed `n = 500000, q = 4000000` to get there: the naive
range sum is a contiguous loop the compiler **vectorises**, and at
`n = q = 100000` it finished in 0.13 s. Anyone sizing a "the slow answer must
fail" case should assume the slow answer is eight times faster than they
expect.

`palindrome`'s brief states outright that the tests reject cubic, accept
quadratic, and **do not demand Manacher** — the honest version of a complexity
claim we cannot enforce.

**Sorting stability needed the case built empirically.** Measured: at `n = 8`
Rust's `sort_unstable_by_key` and Go's `sort.Slice` both happen to agree with
the stable answer, so a small case proves nothing. At `n >= 40` both
demonstrably scramble ties. The visible sample is therefore `n = 8` (readable,
and does not judge) and the hidden cases are `n = 60` and `n = 200`. **This
is the one quest in the repository whose test depends on a library's internal
behaviour** — if a future rustc or Go changes its unstable sort, the case could
stop separating. QA should know that is why it exists and why it is sized that
way.

**Cross-language asymmetries are written up in `coverage.md` §5b** — the places
where the same problem is genuinely different work in the two languages
(`linked-list`, the LRU boss, `inversions`, `dijkstra`, `range-queries`,
`stable-sort`). Mirroring a pack without reading that section produces a quest
that teaches the wrong language's difficulty.

Noted with thanks: **SPEC §12 no longer requires an id's number to equal its
node**, which resolves the §4.1 conflict in §4.1's favour. The bosses kept
their ids this round — `rust.hacker.28.lru` sits at node 34 — and no future
lengthening will rename anything. `tools/verify_pack.py` was updated to the new
rule and now checks id uniqueness and slug uniqueness instead.

**Two counts earlier in this file are now stale, and this is the correction**
rather than an edit, because the log is append-only and those entries were true
when written. The `unsupported()` entry says "no pack declares either — all 116
quests are `stdio`"; the substance still holds — **all 138 quests are `stdio`,
and no pack declares `cargo` or `gotest`** — only the number has moved. The
harness author should read that as a statement about today, not a count. The
`float:1e-6` entry is still accurate as written: it was unused at 116 quests and
is exercised now by `26.statistics` in both languages, which remain the only two
quests in the repository that do not compare as text.

## 2026-09-11 — L2D: search, stats and AI mode, and a new code in the closed set

### `unavailable` is now in §3.3, and my client had eleven codes

The contract grew a twelfth code and my `errors.lua` asserted *exactly eleven*
— which is the assertion earning its keep: the suite failed the moment the
contract moved, rather than the client quietly folding a new code into
`internal`. Added, with the distinction §3.3 insists on: `unavailable` gets
its own action, never `internal`'s. Telling a player their machine is broken
invites a retry that will never work; naming the chapter is something they can
plan around. `errors.milestone` reads `detail.milestone` so a screen can say
which one.

`locked` stays in the table with a note that §4.7 amended it out of existence
— removing a code from a closed set is the one change that breaks an
exhaustive client.

### Stats — live, and `cleared_since` gets the weight

All four calls are real. `cleared_since` is drawn as a **five-step track with
the remaining steps visible**, so the shape says how far there is to go, and
said in words underneath — "3 clean submits since — 2 to go", "you did this on
your last submit", "learned — out of the drill". The number alone is a table
row; the sentence is about a person.

The shelf uses `badge_slot` exactly as DESIGN intended: earned awards from
`stats.awards`, sockets for the rest. **No award id is invented.** A test
asserts the file contains no hard-coded award name, because the moment it does
the client is claiming something the server did not say.

### Search and AI — built, not stubbed

Both are complete screens that render whatever comes back. They answer
`unavailable` today and say so in the story's voice; the day the endpoints
land they render hits and drills with no change.

Search shows *why* something matched, which §8.3 says the components exist
for. A `null` component is drawn as **absence** (an em dash), not as a
zero-length bar: §5.5 says null means the quest was not in that ranking at
all, and a zero bar would assert it scored nothing there, which is a different
and untrue thing. The FTS5 `<b>` markup is stripped rather than shown —
showing a player raw markup is showing them the plumbing.

AI mode draws `why` as the largest thing on the screen with the quest under
it. A drill that showed the quest and hid the reason would be a playlist.

### Empty states, since a new player has all three

Every panel says something. The one that mattered most to get right is the
mistakes list: **having made no mistakes yet is the correct state** for
somebody who has just arrived, so it explains what fills it rather than
apologising for being blank. AI mode checks `stats.mistakes` on entry so it
can say "nothing to drill yet, and here is what changes that" *before* the
player picks a mode rather than after.

A test pins the register — no "sorry", "oops", "unfortunately", "afraid". It
does **not** ban "failed": SPEC §7.3 calls the `repeat` plan "the quests the
user failed most", and describing what a drill selects is a statement of fact.
The thing to keep out is the register that makes a blank screen feel like the
player's fault. (My first version of that test banned the word outright and
failed on the spec's own sentence, which is a good argument for writing the
reason into the test.)

### A real bug the screenshots caught

**The keystroke that opens a scene was leaking into it as typed text.** LÖVE
delivers `textinput` for a printable key *after* `keypressed` for the same
press, so pressing `S` on the map opened the search screen and then typed "s"
into its query box — the first capture read `sborrow checker`. `App:go` now
swallows text input for exactly that frame. It would have hit `P` for the
playground and `Q` for a category too.

### What I deliberately left out

* **A filter row on search.** §4.12 has `filters` for land, category and
  state, and the browser should have them. Here the box is one line and the
  screen is 126 quests; adding three dropdowns to a feature nobody can use yet
  would be designing against a shape I have not seen return a single hit. When
  search is live and I can see what a real result set looks like, that is the
  moment to decide whether filters earn their space.
* **A history *chart*.** `stats.history` gives twelve attempts with verdicts;
  a sparkline of accuracy over time is the obvious next thing and I did not
  build it. Twelve points is not a trend, and a chart that is mostly noise
  teaches a player to ignore the panel it is in.
* **Award detail.** `Award.detail` is "whatever the rule counted" and I show
  only the title. Rendering an arbitrary object would mean guessing at shapes
  the server has not committed to; the shelf says *what* you have, and the
  fanfare already said *why* when it happened.
* **Drill progress persistence across a restart.** §4.16 says the plan is
  fixed at creation so a reconnect resumes it — which means the *server*
  remembers, and a client that also cached the cursor would be a second home
  for the same state. The screen asks `ai.next` and renders the answer.

## 2026-09-11 — `cargo` and `gotest` are built, and both run in two phases

SPEC §5.1 names `cargo test` and `go test -run . -json`; SPEC §5.3 says every
limit applies to every run. Taken literally at the same time, those two
sentences do not fit: `cargo test` and `go test` **compile and then run in one
process**, so either the toolchain runs under a 1 GiB address-space cap, a
stripped `PATH` and a `HOME` in the build directory — which no toolchain
survives — or the player's tests run with the toolchain's environment and none
of §5.3. The second is what a naive implementation ships, and it would make a
test-harness quest the only place in the game where arbitrary code runs
unlimited.

So both harnesses split the job the way `rust.rs` and `go.rs` already split it:

* **compile** — `cargo test --offline --no-run --message-format=json`, and
  `go test -c -o prog .` — with a working environment, the scratch redirected
  into `build/<lang>/` (§5.1), and `compile_timeout_ms`;
* **run** — the test binaries it produced, executed exactly the way
  `harness.rs` executes a stdio submission: own process group, stripped
  environment, rlimits, output cap enforced while draining, SIGTERM then
  SIGKILL.

`gotest` still reads **the JSON event stream the brief asks for**: the captured
output is handed to `go tool test2json`, which is the program `go test -json`
pipes through internally. The events are Go's own, and the player's code is
held to §5.3 rather than to the compiler's environment. If the tool cannot be
reached, a fallback reads the `--- PASS:` lines directly, because a toolchain
oddity should not turn a real submission into an `internal_error`.

`cargo` has no equivalent: libtest's `--format json` is still nightly-only, so
`suite.rs` reads the `test tests::x ... ok` lines that have looked the same
since 1.0. No `-Z` flags, no `RUSTC_BOOTSTRAP`.

### The case loop is shared, and it holds three rules nothing else holds

`suite.rs` is to these two what `harness.rs` is to stdio, and for the same
reason: a rule that forgave a skipped test in one land and not the other reads
to a player as the server being unfair. Three of its rules exist because each
is a way to clear a node without writing a working test:

1. **A suite that ran no tests never passes.** `cargo test` on a file with no
   `#[test]` prints `test result: ok. 0 passed` and exits 0; `go test` on a
   package with no `TestXxx` says `no tests to run` and exits 0. This is
   exactly the hole SPEC §12 closes for stdio with "no `expect` may be empty" —
   an empty submission clearing the node for free — and it is the single thing
   most likely to have shipped broken.
2. **A skipped or ignored test has not passed.** Otherwise `#[ignore]` and
   `t.Skip()` are a cheat code for whichever test was failing.
3. **A declared case with no matching test fails, by name.** "You did not
   write it" and "you wrote it and it failed" are different lessons.

Names are matched in one place: an exact name always matches, a declared name
with no separator matches the leaf of a Rust module path (`adds` finds
`tests::adds`), and a Go subtest is never satisfied by its parent
(`TestTable` does not answer for `TestTable/negative`).

### `test_source`: the two quest shapes, and whose fault a failure is

A new optional key in the test spec, for these harnesses only. Present, the
quest ships its own tests (`tests/quest.rs`, `quest_test.go`) and the player
writes the implementation; absent, the player writes the tests too. Which file
the submission lands in follows from the spec, never from scanning the source:
`src/lib.rs` always for Rust, and for Go `solution.go` when the quest brings
tests and `solution_test.go` when it does not, because Go only registers
`TestXxx` from a `_test.go` file.

`test_source` creates the failure mode these harnesses have and stdio cannot:
**the quest's own tests may be the thing that does not compile.** The rule:

* an error in the player's file → `compile_error`, diagnostics kept in
  `compiler_stderr` where SPEC §7.1 classifies them;
* an error in the *quest's* file that is about the player's API — `undefined:
  Add`, `E0425`, `E0308`, a wrong signature — → `compile_error`, because the
  player really did fail to provide what the tests call, but with **no**
  `compiler_stderr`: a span pointing into a file the player has never seen
  would put a wrong line number into `mistakes`, and the drills are built from
  that table. They are told, in words, what the tests could not find;
* anything else in the quest's file — a syntax error, a bad import — →
  `internal_error` that says *"this is not something you did. Nothing has been
  recorded against you."* No attempt row's verdict is ever invented, which is
  the rule submit.rs already states.

Getting this backwards in the generous direction shows `internal_error` for a
function the player forgot to write; backwards the other way blames them for a
typo in a file they cannot open. Both directions are tested, in both lands.

### Four things measured rather than assumed

* **`go` was silently dropping out of module mode.** `go` ignores a `go.mod`
  that sits inside `os.TempDir()`, and `os.TempDir()` is `$TMPDIR`, which the
  toolchain environment points at the build directory. Every gotest quest would
  have built in GOPATH mode with the warning buried in the compile log — and
  with no `go` directive in force, the language version falls back to 1.16 and
  generics stop compiling. The scratch now gets its own subdirectory one level
  down. Found by a test asserting the *wording* of a `GOPROXY=off` refusal.
* **The compile budget.** Cold, with empty caches and no dependencies,
  `cargo test --no-run` takes 0.15 s and `go test -c` takes 2.8 s — it builds
  `testing`, `fmt` and `runtime` before it sees the quest — and 4.3 s with
  `-race`. Warm, both are ~0.15 s. SPEC §5.2's 30 s default is right for one
  `rustc`; for these two the default is now **60 s**, which is not a claim that
  the compile is slow but the budget before the runner calls a *compiler* hung.
  A pack that names its own `compile_timeout_ms` still gets it.
* **The output cap binds differently under `cargo`.** libtest *captures* a
  test's stdout and stderr into memory and prints them only if the test fails,
  so a test in an infinite `println!` puts nothing on the pipe the runner is
  draining and `max_stdout_bytes` never fires — what stops it is the wall clock
  (and `RLIMIT_AS`, where the platform honours it; on darwin `setrlimit`
  returns `EINVAL` for `RLIMIT_AS`, so there it is already a no-op). Output
  that goes around the capture *is* capped, and there is a test for each.
  `go test` streams, so the cap fires there exactly as it does for stdio.
* **A cargo timeout still names the test.** libtest writes `test tests::x ... `
  *before* running it, but through a line buffer, so on a kill that half-line
  is usually still in the buffer. On a timeout only, the harness re-runs the
  binary with `--list` and names the first test with no result. Paid for on the
  failing path, never on the common one.

### A RUN of a quest that ships its own tests runs only the declared ones

PROTOCOL §4.9b — "a run cannot tell you whether the hidden cases pass" — is
guaranteed for stdio by never handing the hidden cases to the runner. That
guarantee does not survive `test_source`: the hidden tests are functions in one
file, so filtering the pack's *cases* would leave `cargo test` and `go test`
running them anyway, streaming each result to `run.log` and failing the run on
one the player is not allowed to see.

So `visible_only()` now also sets `only_declared`, and when a quest ships its
own tests a RUN executes only the declared ones — `-test.run '^(TestA|TestB)$'`
for Go, and for libtest the names resolved against the binary's own `--list`
and passed `--exact`, because a substring filter would drag in `adds_zero` on
its way to `adds`. A SUBMIT runs everything, as it must. Both lands have the
test: the hidden test fails, the submit says so, the run comes back green and
the hidden name appears nowhere in the report, the log or the verdict.

When the *player* wrote the tests, everything runs on a RUN. There is nothing
hidden to protect, and watching your own tests go green is what RUN is for.

## 2026-09-11 — `-race` is implemented, and no quest should depend on it yet

`race = true` in the test spec, `gotest` only, refused at parse time anywhere
else — a quest that believed it was judged under `-race` and was not would be
worse than one that failed to import.

Measured here (go1.27.1, darwin/arm64), 20 runs each:

| fixture | detected |
| --- | --- |
| four goroutines incrementing one `int` | **20/20** |
| a flag written by a goroutine, read after a `time.Sleep` — no synchronisation at all | **20/20** |
| a result written by a goroutine, read after `select { case <-done: case <-time.After(50ms): }` | **0/20** |

The third one is racy code. The detector is right not to report it: when the
goroutine wins the `select` — which it does every time — closing `done`
establishes a happens-before edge, and there is no race *in that execution*.
This is what QA saw as "0 times in 3", and it is not flakiness in the detector;
it is that `-race` reports races that **happened**, not races that **exist**.
Note also what the second row disproves: two accesses that never overlap in
wall-clock time are still caught, because the detector reasons about
happens-before, not about timing.

Two more facts. `-race` builds without cgo on this Go and this platform
(go1.27, darwin/arm64) — the premise that it needs cgo here is out of date —
but it needs cgo nearly everywhere else, so the harness sets `CGO_ENABLED=1`
when the flag is on. And a `-race` binary reserves far more *virtual* address
space than 1 GiB before it runs a line, so §5.3's `RLIMIT_AS` would not limit
it but delete it; `proc::Limits` now separates the address-space cap from the
rest for this one caller. Every other §5.3 limit still applies to a race run.

**The recommendation: a race quest stays `stdio`, or runs under plain
`gotest`.** Judge the *fix* — a `sync.Mutex`, an atomic, a channel — with a
deterministic test that fails when the fix is absent, which is what
`go.advanced`'s concurrency quests already do. `-race` as a *pass* condition is
only reliable for the blatant shape in row one, and a quest author cannot tell
from the outside which shape they have written. A flaky judge is worse than an
absent one; the flag is here so that the day a quest wants it, the wiring is
tested rather than invented under time pressure.

## 2026-09-11 — Proposal for BE: the importer must let a test-harness case have no `expect`

**Nothing in `content/` can use these harnesses until this lands**, so it is
the blocking item, not a tidy-up.

`core/src/content.rs` refuses any case whose `expect` is empty — "an empty
expectation is cleared by an empty `fn main() {}`". That rule is exactly right
for `stdio` and meaningless for `cargo`/`gotest`, where a case names a **test**
and there is no expected output to write: the test is the expectation. As it
stands, every cargo or gotest quest fails to import with *"case 'adds' expects
nothing; an empty main would clear it"*.

The equivalent guard for the test harnesses is that the case must **name**
something, and the "empty submission clears it" hole is closed in the runner
instead, by `suite.rs`'s rule that a suite which ran no tests never passes.

Requested change, in `validate` (the `for case in cases` loop):

```rust
let harness = tests.get("harness").and_then(|v| v.as_str()).unwrap_or("stdio");
for case in cases {
    let name = case.get("name").and_then(|v| v.as_str()).unwrap_or("");
    if harness == "stdio" {
        let expect = case.get("expect").and_then(|v| v.as_str()).unwrap_or("");
        if expect.trim().is_empty() {
            return Err(bad_request(format!(
                "quest '{}' case '{}' expects nothing; an empty main would clear it",
                quest.id, if name.is_empty() { "?" } else { name },
            )));
        }
    } else if name.trim().is_empty() {
        // A cargo/gotest case names a test that must pass; there is no
        // expected output to compare. An unnamed case names nothing and
        // could never be satisfied.
        return Err(bad_request(format!(
            "quest '{}' has a {harness} case with no name; a case here names \
             the test that must pass",
            quest.id
        )));
    }
}
```

Nothing else in `backend/server/` or `backend/core/` needs to change:
`runner::unsupported()` lives in the runner and already opens the gate,
`submit.rs` dispatches on `lang` and classifies whatever `compiler_stderr`
holds, and the `cargo` harness emits the same `rustc` JSON-per-line that
`mistakes::classify_rust_json` already reads.

## 2026-09-11 — CLI: the fourth client, and what the wire actually does

`cli/` is a Rust terminal client, binary `cwbh`: command mode for people who
live in a shell, plus `cwbh tui`. It is the fourth implementation of
`PROTOCOL.md` and the first one that can be driven from a script, so most of
this note is things the other three could not easily have found out.

### The editor loop

`cwbh edit <id>` writes the starter to
`~/.causewaybayhackercli/work/<address-lower>/<quest-id>.rs` **only if that
file does not exist**, then opens `$VISUAL`/`$EDITOR` on it and waits. `run`
and `submit` send that same file; there is no second buffer. `cwbh reset` is
the only thing that overwrites, and it asks. `$EDITOR` is split on whitespace
so `code -w` keeps its wait flag, and the file is compared before and after —
an editor that returns without waiting is reported as "unchanged" rather than
silently submitting the starter.

`lang` is always taken from the quest's `land`, never from the file extension:
§4.9 makes a disagreement `bad_request`, and a client that infers it from the
filename will one day rename a file and not understand the answer.

### `run.log` really does paint mid-compile — and the `compile` stream is JSON

Measured on the live server, `rust.hacker.24.inversions` with three deliberate
warnings added to the O(n²) starter:

```
   0ms queued / compiling
  33ms ─── compile ───      four rustc warnings
1754ms ─── stdout ───       19 / MAX 908834774 / …
6878ms judging
first compile chunk at 33ms, first stdout chunk at 1754ms, reply at 6882ms
```

The compiler's words were on screen **6.8 seconds before the verdict**. A
120-error file gives the same answer from the other end: 122 separate `run.log`
frames arriving over 28–50 ms with the reply at 86 ms.

**But §4.18's example is not what the `compile` stream carries.** The example
shows `"chunk": "error[E0382]: borrow of moved value: \`s\`\n"` — rendered
text. SPEC §5.1 compiles with `rustc --error-format=json` and
`backend/server/src/submit.rs` streams the compiler's stderr verbatim, so what
actually arrives for a Rust attempt is one JSON diagnostic object per line,
several kilobytes each, most of it `explanation` prose nobody asked for.
Printed raw it is unreadable, which is a plausible reason nobody had watched
this stream before. `Attempt.stderr` **is** rendered (`mistakes::rendered_from_json`),
so a client that only reads the final attempt never notices.

This client buffers to line boundaries and prints each diagnostic's own
`rendered` field, which is exactly the text the example promised; `--raw`
turns that off. §4.18 is worth amending either to say what the stream carries,
or to render it server-side the way `Attempt.stderr` already is. The second
would be better: three clients would each otherwise have to learn rustc's JSON.

### `server.bye` has never been sent on a shutdown

Against a throwaway server on 5391 (never the shared one), killed while a TUI
was connected:

* **SIGTERM** — no `server.bye`, no close frame. `backend/server/src/lib.rs`'s
  `shutdown()` awaits `ctrl_c()` only, so SIGTERM kills the process outright.
* **SIGINT** — also no `server.bye`. Axum's graceful shutdown drains HTTP
  requests; the upgraded websocket task is not told, and the client sees
  `Connection reset without closing handshake`.

The two places `ws.rs` emits `server.bye` are the keepalive-missed branch and
the end of the per-connection task — the latter runs *after* the client has
gone, so nobody hears it. So §4.21's `reason: "shutdown"` and §6's "reconnect
on `shutdown`" have never fired in practice. §8.11 is still satisfiable — this
client survives both halves, and the close-without-goodbye path is the one
that actually happens — but the contract currently describes something the
server does not do.

Related: the keepalive-missed branch sends `reason: "shutdown"`, which is not
true. §1.2 distinguishes "server going away" from "keepalive missed" in the
close codes; §4.21's `reason` set (`shutdown | revoked | replaced`) has no
value for the second.

### `detail.milestone` is an integer

§3.3 requires `unavailable` to carry `detail.milestone` and shows a client
saying *"the GO land opens in the next chapter"*, which reads as a phrase. The
server sends `{"milestone": 2}` (`handlers::unimplemented`). Neither type is
written down. This client accepts both rather than dropping the one it did not
expect and printing a sentence with a hole in it, and renders the integer as
"milestone 2". Worth pinning in §3.3 either way.

### §4.10 `quest.hint` has no heading

Between §4.9d and §4.11, the hint request/response block and its "taking a hint
costs stars" paragraph sit directly under `code.format`'s text with no
`### 4.10 quest.hint` header. Read straight through, the hint payload looks
like part of the formatter's section. Also, the section order runs 4.8, 4.9,
4.8b, 4.9b, 4.9c, 4.9d, (4.10), 4.11 — and §5 runs 5.4, 5.9, 5.5, 5.10, 5.6.

### §4.9c: the three undocumented playground messages, probed independently

Confirming L2D's note from the other direction, against the live server, with
one correction:

```
playground.list   -> { snippets: SnippetBrief[] }            agrees
playground.load   -> { snippet: Snippet }                    agrees; not_found on an unknown id
playground.delete -> { deleted: true, id: "pg_…" }           L2D recorded `{ }`
```

`playground.save`'s idempotence holds: saving identical content under the same
`id` returned the same `updated_at` to the second.

### Warnings become `mistakes` rows

A submit whose only compiler output was four `unused_variables` /`unused_mut`
warnings came back with four `mistakes` entries of kind `unused`, and they are
now in `stats.mistakes` beside `borrow-after-move` and `timeout`. That may be
intended — an unused binding is a real habit — but it means the curriculum will
drill a player on warnings from a program that compiled and passed, and
`stats.mistakes` ranks them by raw count against genuine errors. Flagging it
for BE/PM rather than asserting it is wrong.

### The client's own store

`~/.causewaybayhackercli`, SPEC §1.1 to the letter: `0700`/`0600`, append-only
JSONL, state by replay, `session.clear` as a record. Every directory from the
home down is forced to `0700` — `create_dir_all` applies the umask, which left
the intermediate `work/` at `0755` on macOS and made the `0700`s either side of
it decoration.

Tokens are keyed by a **canonical** server URL: `localhost:5390`,
`http://localhost:5390`, `HTTP://LocalHost:5390/` and `ws://localhost:5390/ws`
all reduce to one key, so the "one token, two servers" failure §1.1 warns about
cannot happen through a spelling. Precedence is written down and tested:
`--server` > `$CWBH_SERVER` > the last server used > `ws://127.0.0.1:5390/ws`.

### Key material

Derivation and EIP-191 signing are checked against `tests/vectors/*.json` —
every mnemonic, every index, and the full `r ‖ s ‖ v` signature byte for byte,
so this is the fourth implementation to agree on
`0x9858EfFD232B4033E47d90003D41EC34EcaEda94`. §4.3's recovery-id warning is
asserted rather than described: a test builds `v ‖ r ‖ s` and proves it
recovers a different address.

There is **no `--mnemonic` flag**. Not one with a warning — the flag does not
exist, because argv lands in shell history and in `ps`. The phrase is read
without echo (not even asterisks: counting twelve groups of stars tells a
shoulder-surfer the word count) or from a pipe, lives in `Zeroizing<String>`,
and is dropped before the socket is touched.

### §8, and where each item is checked

`cli/tests/conformance.rs` runs the client against a mock websocket server for
the half of §8 that a real server will not perform on request: a reply arriving
out of order (§8.2 — two requests in flight, answered backwards), three unknown
event types (§8.3), every error code plus an invented one (§8.4), the whole
login handshake swept for the phrase, the private key and the BIP-39 seed
(§8.5, §8.6), a rotated `auth.resume` token (§8.7), a `seq` gap and a line split
across three chunks (§8.8), a port that is not listening yet (§8.9), and both
`server.bye`-then-close and close-with-no-goodbye (§8.11).

§8.2's evidence is not contrived: the 20-second keepalive `ping` fires *during*
a long submit, so §2.2's own example — "a `ping` sent after it will come back
first" — happens on every slow run. Replies for ids nobody is waiting on are
stashed, not dropped.

§1.1/§8.12 confirmed against the live server with `cwbh doctor --hold 75`:
alive after 75 idle seconds, 2 websocket pings from the server (auto-ponged by
`tokio-tungstenite`) and 3 application pings sent. Both halves, belt and
braces.

### Not finished

`search.query` and `ai.plan`/`next`/`finish` are wired as `cwbh search` and
`cwbh drill` and render `unavailable` in the story's voice — they are not
implemented on the server, so there is nothing more to do until milestone 2.
`profile.update` has no command. The TUI has a node list rather than a drawn
overworld, and no `x`/`y` map layout.
## 2026-09-11 — FE2: search, stats and AI mode, built against a server that has not built them

Three new screens — `frontend/src/scenes/{search,stats,ai}.ts` — plus five new
modules under `src/ui` and `src/net` that hold the parts of them that can be
*wrong* rather than merely ugly. Everything below was checked against the live
server on 127.0.0.1:5390, not against a mock.

### What the server actually answers today

Probed on a real authenticated connection:

```
search.query   (all four modes, with and without filters)  -> unavailable, detail.milestone = 2
ai.plan / ai.next / ai.finish                              -> unavailable, detail.milestone = 2
stats.summary / stats.mistakes / stats.history             -> ok
stats.awards                                               -> ok, { awards: [] }
```

So two of the three screens open on the `unavailable` path and one is fully
real. All three are written to render whatever comes back.

### `unavailable` was missing from the client's closed code set

`net/protocol.ts`'s `ERROR_CODES` did not contain `unavailable`, so
`codec.ts::asError` folded it to `internal` — and every one of those replies
would have been shown to the player as **"the server broke — try again"**, which
is the exact failure PROTOCOL §3.3 spends a paragraph forbidding. Added, with
its own `ErrorAction` (`next-chapter`) and its own `playerText`.

`net/milestone.ts` detects it **both ways** — `code === "unavailable"` *or*
`detail.unknown_code === "unavailable"` — and reads `detail.milestone` from
either. The fold preserves `detail`, so the second form still carries the
milestone; the tolerance exists so a merge that lands an older `protocol.ts` on
top degrades to the right words instead of silently back to "the server broke".

### Three states, not two

Every one of these screens has an unbuilt state, a built-but-empty state and a
state with data, and the middle one is the one a new player sees. `ui/coach.ts`
gives each of §7.3's three plans its own answer for *why* it is empty —
`repeat` with nothing failed is not `weakness` with nothing classified is not
`spaced` with nothing cleared — and each points somewhere. They are unit-tested
because `ai.plan` cannot be made to return an empty plan by hand today.

### `stats.mistakes` is asked with `include_learned: true`

§4.14's default hides any kind whose `cleared_since` has reached five — which is
exactly the moment worth showing. The screen asks for all of them and keeps the
beaten ones in a BEATEN section under the live ones. A drill list that drops a
kind the instant it is beaten throws away the only evidence a player ever gets
that the loop worked.

### The shelf needs a catalogue on the client, and that is deliberate

`stats.awards` returns only what the player *has*. DESIGN drew `badge_slot` so
an unearned badge reads as a thing you can go and get, which only works if the
client knows what the gettable things are — so `ui/awards.ts` carries the
sixteen single-instance awards from BE's own table, earned ones first and empty
sockets after. The three open-ended families (`tamed-<kind>`, `level-<n>`,
`cleared-<land>-<category>`) are deliberately **not** drawn as sockets: there is
no fixed number of them and a socket labelled "LEVEL 37" is a promise this
client has no business making. An award id the client has never heard of still
gets a badge rather than a hole.

### Nav: F4 / F5 / F6, and one thing I did not do

`app.ts` gains a module-level `AUX` map and one block in `wireKeys` — F4 search,
F5 stats, F6 AI, next to F1/F2/F3, dynamically imported like the login screen.
Cross-navigation between the three, and the way out, is `ui/auxnav.ts`, drawn on
all three and touching nothing existing.

**What is missing is a visible entry point from the map or the lands screen.**
`map.ts`'s `barLayout()` is hand-written width arithmetic with a one-line and a
two-line case, and three more ids do not fit either without rewriting it; the
lands screen's bottom band is one button tall. Both are FE's hottest files and
the change is not small. **Requested of FE:** three buttons appended to the
map bar's tail group (`menu`, `play`, then `search`, `stats`, `ai`), with
`barLayout`'s `menuW`/`tailLeft` arithmetic widened to match, and the three ids
handed to `openAux()` from `ui/auxnav.ts` in the existing `onBar` branch.

### For PM — three things §4.12/§4.16/§5.7 do not say

1. **`SearchHit.bm25` has no stated sign convention.** §8.1 uses SQLite's
   `bm25()`, which is negative-is-better; §5.5 calls the field only
   "component". A screen that draws a bar has to know which end is good.
   `ui/relevance.ts` detects it — all values ≤ 0 means lower-is-better — and
   never compares the two columns against each other, because §8.3 is explicit
   that they are not on one scale. Please pin the convention in §5.5.
2. **§4.16 does not say what `ai.next` does at `cursor === 0`,** nor whether
   `Drill.plan` may be empty. A new player with no mistakes is the normal case
   for `weakness`, and "empty plan" and "not_found" are different screens. This
   client treats an empty `plan` as a legitimate answer and says which kind of
   empty it is.
3. **`ai.next`'s `position` and `Drill.cursor` have no stated base.** §4.16's
   example shows `"position": 2, "total": 5` and §5.8 says only
   `cursor: number`. This client assumes **0-based** — the head reads
   `position + 1 OF total` and the plan strip marks `i < position` complete. If
   the server is 1-based the head reads one ahead and the strip marks one pip
   too many, and neither is detectable from the client without a live drill,
   which `unavailable` currently makes impossible. Please state the base.
4. **`AttemptBrief` carries `mode: "run" | "submit"` on the wire and §5.7 does
   not list it.** It matters: a run never clears a node (§4.9b), so a history
   that does not distinguish them reads as a string of failures on a quest the
   player went on to clear. Added to the client type as optional and printed.
   Related, and worth resolving rather than guessing: **SPEC §7.2 says
   `cleared_since` is updated "on every attempt", while BE's own note says it
   only moves on a submit.** The number on screen means different things under
   the two readings, and the live history does show `mode: "run"` rows carrying
   `kinds`.

### A pre-existing rendering fault, not ours

After an orientation change (`__cwbCapture.orient()`, and presumably F1) a dark
rectangle roughly 0.6 × 0.6 of the canvas is left in the top-left of `#game`.
It is on the **lands** screen too, so it predates these three and is not in FE2's
files — most likely a buffer in `gfx/crt.ts` that is not resized. Flagging only.
