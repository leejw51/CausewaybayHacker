# e2e

The milestone-1 journey in a real browser, in both orientations.

```
login with a mnemonic → RUST → BASIC → map → quest
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

## Status: 20 tests, all skipping, and that is correct today

Nothing here has ever passed. The frontend (:5291) and the backend (:5390)
are being written in parallel with this suite. Every test skips with a reason
that names what is missing, and the suite is built so it cannot pass
vacuously:

* **Nothing is listening** → `global-setup.ts` probes both ports *before* a
  browser is launched and every test skips saying "start it: `make dev`". A
  browser that navigates to a dead port reports a connection error, which
  tells you nothing about the product.
* **Listening, but no hooks** → the fixture marks the test `fixme` naming the
  contract below. That is "the product is not there yet", which is a
  different thing from "you did not run it right", and collapsing the two
  into one red line is how a suite stops being read.

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

One of `boot | login | lands | categories | map | quest | result`
(SPEC §10's screen list, minus the three reachable from the map). Set it
whenever the scene changes; that is the only thing a `toHaveAttribute` can
wait on.

### 2. `window.__cwb`

```ts
interface CwbHooks {
  view(): string;                    // the whole view model, JSON-stringified
  login(secret: string): Promise<void>;  // mnemonic or 0x-key → derive, sign, land on `lands`
  setSource(source: string): void;   // replace the editor's contents
  submit(): void;                    // fire quest.submit
  forget(): void;                    // drop the session token
}
```

`login()` exists because typing twelve words into a canvas one
`keyboard.press` at a time tests the keyboard handler, not the login — and
the keyboard handler is FE's own unit test, not this one's job.

Gate the whole object on `import.meta.env.DEV ||
location.search.includes("e2e=1")` so a shipped bundle does not carry a "log
me in" function.

### 3. The view model

The fields this suite reads are typed in `fixtures.ts` as `View`. In short:
`state`, `address` (lowercase) and `address_eip55`, `land`, `category`,
`nodes[]` mirroring PROTOCOL.md §5.2, `quest`, `attempt` mirroring §5.4, and
`errors[]` — every `.err` payload the client has received, so a test can
assert that `busy` or `proto_version` actually reached the client rather than
being swallowed.

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
| `journey.spec.ts` | the milestone-1 loop |
| `resilience.spec.ts` | PROTOCOL.md §6.4's connection rules, from the browser |

The wire-level versions of the resilience tests — the ones that forge frames
a browser client would never send — live in `tests/smoke/`. What is tested
here is that **the frontend copes**, not that the server answers.
