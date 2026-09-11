# e2e

The milestone-1 journey in a real browser, in both orientations.

```
login with a mnemonic → RUST × BASIC → map → quest
→ submit a wrong answer → submit the right one → CLEARED
→ reload → still cleared
```

```bash
cd e2e
npm install
npx playwright install chromium
npx playwright test                      # both orientations
npx playwright test --project=portrait   # one
```

## Status: 24 tests, all skipping, and that is correct today

Nothing here has ever passed. The frontend (:5291) and the backend (:5390)
are being written in parallel with this suite. Every test skips with a reason
that names what is missing, and the suite is built so it cannot pass
vacuously:

* **Nothing is listening** → `global-setup.ts` probes both ports *before* a
  browser is launched and every test skips saying "start it: `make dev`". A
  browser that navigates to a dead port reports a connection error, which
  tells you nothing about the product.
* **Listening, but no hooks** → the fixture marks the test `fixme` naming the
  contract below. Verified: pointed at the backend's own `frontend/dist` on
  :5390, the page boots and exposes `window.__THREE__` and nothing else — no
  `data-state`, no `__cwb`, and none with `?e2e=1`. So the skips are the
  honest answer and the contract below is the entire gap.

The two are kept apart on purpose. The first is "you did not run it right";
the second is "the product is not there yet". Collapsing them into one red
line is how a suite stops being read.

The suite **never starts a server**. Four agents share this tree; a
`webServer` block that spawns `vite` or `cargo run` would fight whatever
build is in flight, and a Playwright-owned server that dies mid-run looks
like a product bug.

`E2E_BASE_URL` and `E2E_BACKEND_URL` point it somewhere else — at the release
build the backend serves itself on :5390, for instance, which is the artifact
that actually ships (PROTOCOL.md §1: one port, no CORS).

## What has to exist for it to go green

A 16-bit game draws on a canvas. There are no DOM nodes to click and no text
to read — **Playwright cannot see a sprite**. The sibling repo
(`CausewaybayGolang/typescript`) solved this by publishing the current screen
on `<html data-state>` and the whole view model through a `window.__view()`
accessor, and its suite is readable because of it.

The same convention, named:

### 1. `<html data-state>`

One of `boot | login | lands | map | quest | result`. Set it whenever the
scene changes; it is the only thing a `toHaveAttribute` can wait on.

**Six, not SPEC §10's original seven.** FE merged land select and category
select into one `LandsScene` — a 2×3 grid, lands down and categories across
in the fixed order `basic`, `advanced`, `hacker` — and SPEC §10 was amended
to match. There is no `categories` screen, so RUST × BASIC is one Enter from
`lands`, and a test that waits for `categories` waits forever.

### 2. `window.__cwb`

```ts
interface CwbHooks {
  view(): string;                    // the whole view model, JSON-stringified
  login(secret: string, index?: number): Promise<void>;
  setSource(source: string): void;   // replace the editor's contents
  submit(): void;                    // fire quest.submit
  forget(): void;                    // drop the session token
}
```

`login()` exists because typing twelve words into a canvas one
`keyboard.press` at a time tests the keyboard handler, not the login — and
the keyboard handler is FE's own unit test, not this one's job.

**`index` is not optional decoration.** It is the BIP-44 index, default 0.
The server persists, so a suite that always logs in as account 0 asserts
"node 1 is open" against a node a previous run already cleared — and this
suite runs twice per invocation (landscape, then portrait, against one
database), so it would break on its own first run. Every test that submits
derives a fresh high index off the same published mnemonic.

Gate the whole object on `import.meta.env.DEV ||
location.search.includes("e2e=1")` so a shipped bundle does not carry a "log
me in" function.

### 3. The view model

Typed in `fixtures.ts` as `View`, and every field below is read by a test —
a missing one is a red test, so the list is the contract and not a wish.

| field | shape | why a test needs it |
| --- | --- | --- |
| `state` | one of the six screens | mirrors `data-state`; lets a test read the screen and the model in one call |
| `address` | lowercase 0x hex, null before login | SPEC §3.4's storage key |
| `address_eip55` | the checksummed form, null before login | SPEC §9.1's conformance assertion |
| `land`, `category` | the selected cell of the 2×3 grid | proves RUST × BASIC was reached |
| `lands[]` | `{land, categories:[{category,total,cleared,open}]}` — `world.lands` passed through | the GO test has to know whether a GO row exists before selecting it |
| `nodes[]` | `MapNode` (PROTOCOL.md §5.2) | locked / open / cleared and stars |
| `quest` | `{quest_id, title, source, tests:{visible:[{name,stdin,expect}], hidden_count}}` | **`tests.visible[0].expect` is how the suite composes a right answer.** Content is PM's; a suite that hard-codes an answer breaks the day a string changes. Note the path: the wire shape is `Quest.tests.visible[]` (PROTOCOL.md §4.8), **not** `Quest.visible[]` and **not** `tests.cases` — pass the server's `Quest` straight through and it is already right |
| `attempt` | `Attempt` (PROTOCOL.md §5.4) | verdict, `cleared`, stars |
| `errors[]` | `{code, message, detail?}`, newest last | proves `busy` / `proto_version` actually **reached** the client rather than being swallowed |
| `console` | the streaming console's text so far | the one test that can prove `run.log` paints *during* a compile rather than after it — see below |

`source` is whatever is in the editor right now, starter or edited, so a test
can assert the editor opened with something and that `setSource` took.

### 4. `window.__cwbSocket`

The live `WebSocket`, for the two resilience tests. One kills the socket —
there is no button for "your wifi died" — and one forges a frame with an
unknown `v`. Same dev-only gate.

All four are proposed to FE in `docs/decisions.md` (2026-09-11, "the e2e hook
contract"). FE owns `frontend/**` and takes them; QA does not edit there.

## Why two projects rather than one test with a resize

SPEC §10: "Both orientations are first-class on every screen, not just the
map." So the whole journey runs twice — 1280×720 and 720×1280, the two sizes
the lifted `layout.ts` authors at — rather than one extra test that checks the
map looks right sideways. A portrait-only bug in the result screen is exactly
the kind this catches and a single resize test does not.

The portrait project is a desktop browser at phone proportions, **not** a
phone: touch and mobile emulation change the input path as well as the
layout, and what SPEC §10 asks for here is the orientation. A touch project
belongs to milestone 2.

## Files

| file | what |
| --- | --- |
| `playwright.config.ts` | two projects, no `webServer`, base URL from `E2E_BASE_URL` |
| `global-setup.ts` | probes :5291 and :5390 once, before any browser starts |
| `fixtures.ts` | the hook contract, the `View` type, the preflight gate, the skip reasons |
| `journey.spec.ts` | the milestone-1 loop, plus the mid-run console and the Go-gap message |
| `resilience.spec.ts` | PROTOCOL.md §6.4's connection rules, from the browser |

Two tests in `journey.spec.ts` close holes nobody could confirm from inside a
unit test:

* **the streaming console paints mid-run.** FE reported that headless RAF
  starvation defeated its timing attempts, so `run.log` painting *while*
  rustc thinks is currently believed rather than known. SPEC §5.4 is explicit
  about why it matters — "so the player watches `rustc` think instead of a
  spinner" — and a console that only fills in once the verdict lands is a
  spinner with extra steps, with every unit test on both sides still passing.
  The test races `view().console` against `data-state="result"` over a
  deliberately slow-to-compile source (deep generic nesting, which costs
  rustc real time and still compiles, so the attempt is genuine rather than a
  syntax error that fails instantly).
* **a Go submission says "not built yet", not "the server broke".** Go is
  milestone 2 and the server answers `internal_error`, which PROTOCOL.md §3.3
  tells a client to render as a crash. `search.query` already has the right
  shape — `not_found` with `detail: {"milestone": 2}`. The test asserts what
  exists and records the complaint as an annotation, so it will not go red
  when this is fixed.

The wire-level versions of the resilience tests — the ones that forge frames
a browser client would never send — live in `tests/smoke/`. What is tested
here is that **the frontend copes**, not that the server answers.
