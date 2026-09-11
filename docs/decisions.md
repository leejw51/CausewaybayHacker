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
