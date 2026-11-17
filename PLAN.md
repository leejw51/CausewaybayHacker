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

## Where it stands — v0.1.8 (2026-11-17)

Milestones 1–4 shipped, and a good deal past them:

* **Nine lands, 1117 quests:** RUST, GO, C++, PYTHON, PYTORCH, TYPESCRIPT,
  REMIX, ZIG, LUA. Every land has VERY BASIC, BASIC, ADVANCED, HACKER and the
  two CHEATSHEET roads; RUST alone has FRAMEWORKS on a pinned crate shelf. Every
  quest is translated (`content/i18n/`).
* **The game:** XP and levels, stars, combo, badges, boss nodes, AUTO SELECT,
  the drill, spaced review and AI mode, search (BM25 + meaning, fused).
* **The playground:** 1000 pads synced across devices; CODE, CONSOLE (APPLE ][,
  MSX, AMIGA), AGENT, POSTER and DISK READER; the waiting wave; motion.dev
  transitions; both orientations on every screen.
* **Shipping:** `v*` tags build server tarballs for macOS and Linux and the
  desktop app for macOS (signed, notarised), Linux and Windows, attached to a
  GitHub release.

The old milestone text lives in git (`git show 56f2be0:PLAN.md`).

## Milestone 5 — finish the job: the interview gaps, the iPad, the release path

Three streams, all parallel. Each ticket has an owner, the work, and the line
that says it is done. Take the lowest number in your stream first.

### Content — the interview gaps (`docs/coverage.md` §5)

The runner has had the `cargo` and `gotest` harnesses (`backend/runner/src/`)
for a while, and no quest uses them: all 1117 are `harness = "stdio"`. That
was §5's item 1, "worth more than the other three together", and it is now
only content.

| # | owner | ticket | done when |
| --- | --- | --- | --- |
| C1 | PM | **A test that runs.** Quests in RUST and GO where the player writes the test, judged by `cargo test` / `go test`: a table test, a failing case caught, a helper under test. | ≥ 6 per land on the ADVANCED road, each reference solution passing and each starter failing in CI (SPEC §9.4) |
| C2 | PM | **Kruskal.** Union-find and sorting are both in the packs; put them together. | HACKER node 35 in every language land, same question in each |
| C3 | PM | **Segment tree with lazy propagation:** range update, range query. | HACKER node 36 in every language land; the tests time out a naive O(n·q) |
| C4 | PM | **KMP / Z-function.** | HACKER node 37 in every language land; the tests time out a naive O(n·m) |
| C5 | PM | **Bit-mask DP** over subsets (assignment, TSP on n ≤ 16). | HACKER node 38 in every language land |
| C6 | PM | Translate C1–C5 into every locale. | `content/i18n/` complete; the i18n check is green |
| C7 | PM | Rewrite `docs/coverage.md` §5 once C1–C5 land. | §5 lists only what is still missing |

### iPad and portrait — the device the game is actually played on

The game is tested from an iPad over the tailnet, held upright. v0.1.8 fixed
the playground's waiting wave, the AI coach card and the header title; a sweep
at 768×960 found what is left.

| # | owner | ticket | done when |
| --- | --- | --- | --- |
| D1 | FE | **Installable web app.** A `manifest.webmanifest` (name, the coder icons already in `public/icons/`, `display: standalone`, indigo theme colour) so Add to Home Screen opens full screen with no Safari bar. | Launched from the iPad home screen, the game fills the screen and keeps its login |
| D2 | FE | **Panels sized to what they hold, upright.** RESULT's THE RUN, STATS' drill and log, and AI MODE's coach are each a tall empty well when there is little in them. | At 768×960 no panel is more than half empty; the space goes to the panel that has content |
| D3 | FE | **The map on a 4:5 screen.** Upright on an iPad the map is a narrow column with wide dead gutters. | The map uses ≥ 80 % of the width at 768×960 |
| D4 ✅ | FE | **A busy RUN that can be stopped.** *(done 2026-11-17: `run.cancel`, RUN turns STOP, a stopped run is not a failure — `docs/decisions.md`)* While compiling or running, RUN is dimmed and there is no way out but the time limit. | A STOP in its place ends the run; the next RUN works |
| D5 | QA | **An iPad project in e2e.** 768×960, touch, Korean, next to `landscape` and `portrait`. | `npx playwright test --project=ipad` runs the sweep and saves its shots |

### Release and tooling

| # | owner | ticket | done when |
| --- | --- | --- | --- |
| R1 | BE | **`make tauri` on an external volume.** Bundling fails with `Failed to create app icon: Operation not permitted` when `desktop/target` is on `/Volumes/…`. | `make tauri` puts the target on the internal disk (or works around the copy) and passes from this checkout |
| R2 | QA | **The sweep is green again.** `sweep.spec.ts` 3b waits for an editor on a quest (quests are picked now, SPEC §0); 3d expects the face cycle to come back to VT323 and gets PlexMono. | `npx playwright test sweep.spec.ts` passes in both orientations |
| R3 | BE | **One command for a release.** Bump every manifest, tag, push, and rebuild the local server, instead of eight files by hand. | `make bump V=0.1.9` then `make release-push`; `make version` agrees |
| R4 | QA | **`make test-all` in CI on the tag.** A release is cut only from a tree whose whole suite passed. | The Release workflow needs `test-all` before it builds |

**Definition of done for M5:** C1–C5 are playable in every land they name, the
iPad home-screen app opens full screen with no half-empty panel, and a release
is `make bump` + `make release-push` with a green suite behind it.

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
| A fix that only reaches the source, not the server the player tests on | every change ends with `make rebuild` (frontend) or `make restart` (backend), so :5390 always runs the tree |
| Harness quests (C1) are slow: `cargo test` builds a crate per submit | the crate shelf is warmed once per machine (`cwbhacker warm`), and the runner streams `compiling` |
