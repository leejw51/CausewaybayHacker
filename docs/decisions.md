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
