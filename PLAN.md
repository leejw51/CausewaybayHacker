# Causewaybay Hacker — Plan

The contract is [`SPEC.md`](SPEC.md). This is the order things get built in and
who builds them.

## The one decision everything else hangs off

**The server owns the truth.** Users, progress, quests, judging, search,
mistakes — all in Rust, all in SQLite. The browser draws and takes input.

The sibling repos (`CausewaybayRaiden`, `CausewaybayGolang`) put their game
rules in Rust compiled to wasm with TypeScript as a shell. **We do not copy
that**, because a server that compiles code, holds multiple users and owns a
database would then be a *second* home for the same state, and the two would
drift. What we lift from those repos is the **engine layer** — the virtual
canvas, the pixel font, the particles, the art manifest — not the core.

## Milestone 1 — the vertical slice (everything else is blocked on this)

One path, end to end, proven with a real player sitting in front of it:

```
login with a mnemonic → RUST land → BASIC category → map with 3 nodes
→ pick node 1 → editor → submit → server runs rustc → verdict streams back
→ node stamped CLEARED and still cleared after a restart
→ the failed attempt shows up in stats.mistakes
```

Nothing in that list is optional and nothing outside it is in milestone 1. Three
quests, one land, one category. No Go, no search, no AI mode, no three.js
parallax, no badges.

The slice is what proves the wire format, the auth, the runner, the persistence
and the orientation handling all at once. Until it runs, parallel content work
is guesswork.

**Definition of done for M1:** `make dev` starts the server and the frontend;
a human logs in with a mnemonic, clears a quest, kills the server, restarts it,
reloads the page and the quest is still cleared; `make test` is green.

## Milestone 2 — breadth

Once the slice holds, these are genuinely parallel:

| stream | work |
| --- | --- |
| BE | the Go runner; search (BM25 → semantic → unified); mistake taxonomy in full; drills |
| FE | the three.js map proper; land/category select; search, stats and AI screens; both orientations on all of them; the 16-bit polish — stamps, ribbons, confetti, chip audio |
| PM | the content: 6 packs, ~20 quests each; the story beats; the art manifest |
| QA | the §9 test list, all eight; e2e in both orientations; the content CI that runs every reference solution |

## Milestone 3 — the game

Badges, levels, XP, combo and the clear-fanfare. The HackerRank-style timed
`hacker` category with its countdown. Boss nodes at the end of each map. The
Skynet framing: each cleared street is a skill taken back.

## Milestone 4 — two more lands, and the quests in the player's language

`cpp` and `python`, each with the same three roads and the same quest counts
as the first two (18 / 17 / 34, boss last), and the hacker road the same 34
interview problems so one interview can be sat in any land. The runner
grows two stdio-only toolchains (`c++ -std=c++20`, `py_compile` then
`python3 -I`), the §7.1 taxonomy grows `cpp:` and `py:` columns without a
single new kind, and the mistake fixtures are captured from the real
compilers as before. Alongside: quest text translated per locale under
`content/i18n/`, served by `quest.get`/`world.map` on a `locale`, so the
brief a Korean player reads is Korean and not "in English, sorry". The
interface catalogues are unchanged; the content is what moves.

---

## The team

Four agents, disjoint directories (see SPEC §11). They share one tree and one
frozen contract rather than worktrees, because they have to integrate.

* **PM** — owns `SPEC.md`, `content/**`, `docs/**`, `README.md`. Writes the
  quests and the story. Arbitrates contract changes.
* **BE** — owns `backend/**`. Rust: axum, tokio, rusqlite, the runner, search.
* **FE** — owns `frontend/**`. Vite, TypeScript, three.js, the engine port,
  the wallet derivation.
* **QA** — owns `tests/**`, `e2e/**`, and the fixture vectors. Writes the §9
  tests, including the ones that will fail at first.

Rules they all work under:

1. **The spec is frozen for the duration of a milestone.** A change goes in
   `docs/decisions.md` as a proposal, and the owning agent applies it.
2. **Do not edit another agent's directory.** Need something there? Write the
   request in `docs/decisions.md`.
3. **Commit early, commit small**, with a one-line subject that says what
   changed, not which agent changed it.
4. **No secret ever crosses the websocket** (SPEC §3.1). This is not
   negotiable and not subject to a convenience argument.
5. **Verify, do not assume.** FTS5 present, the toolchain version, the address
   vectors against the real wallet — each of these has a test, not a belief.

## Known risks

| risk | what we do about it |
| --- | --- |
| Address derivation drifts from `CausewaybayWallet` → users "lose" accounts | conformance vectors in `tests/vectors/`, asserted in CI (SPEC §9.1) |
| Running arbitrary code on the host | limits in SPEC §5.3, and the README says plainly it is a local single-user trainer, not a sandbox |
| First `cargo` build is slow enough to look broken | warm the toolchain at startup; stream `run.stage` so the player sees `compiling` |
| Quest content rots — a quest whose own solution no longer compiles | CI runs every reference solution through the real runner (SPEC §9.4) |
| ONNX embedder pulls a large runtime and wants to download a model | it is off by default behind a cargo feature; the built-in `hashed` embedder is the one that ships |
| Four agents, one tree | disjoint directory ownership, a frozen contract, and M1 before any fan-out |
