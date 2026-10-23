# The LÖVE client's UI kit

`love2d/src/theme.lua` (tokens), `love2d/src/ui.lua` (components),
`love2d/src/juice.lua` (motion), `love2d/src/fx.lua` (particles). The idiom is
Balatro's, adapted to a coding game: a calm dark felt, rounded cards and
buttons with a **solid same-hue shadow** so everything has depth, four accents
that each mean one thing, one chunky pixel face at three sizes, tactile
buttons, very little chrome. **Code is the hero; chrome recedes.** The
designer's spec is the source of the numbers; this is what was built from it.

Proof screens: `src/scenes/title.lua` and `src/scenes/lands.lua`. Build every
other screen the same way.

## 1. Tokens (`Theme`)

### Palette, by role

| Token | Hex | Job |
|---|---|---|
| `Theme.felt` (= `bg`, `void`) | `#16203A` | the backdrop; over scene art at 72 % landscape / 80 % portrait |
| `Theme.bar` | `#1E2A4A` | header and footer bars, unselected chips |
| `Theme.card` (= `surface`, `navy`) | `#26345A` | a card |
| `Theme.cardHi` (= `surface2`) | `#30406C` | a hovered card, a keycap face |
| `Theme.edge` (= `shadow`, **`ink`**) | `#0B1020` | every outline and every neutral shadow |
| `Theme.codeBg` | `#0E1426` | code wells |
| `Theme.text` (= `fg`, `cream`) | `#F4ECDC` | all prose and labels |
| `Theme.mute` (= `inkDim`, `dim`) | `#9AA3BF` | captions, metadata, a hint's verb |
| `Theme.gold` / `goldD` (= `accent`, `coin`) | `#F5B83D` / `#A8741A` | **act and reward**: the primary button, the selection, stars, XP |
| `Theme.blue` / `blueD` (= `accent2`, `sky`) | `#3E8EF0` / `#1F4E94` | **run and info**: RUN, concepts |
| `Theme.redA` / `redD` (= `bad`, `red`) | `#E8504A` / `#8E2A26` | **wrong and danger** |
| `Theme.green` / `greenD` (= `good`, `admit`) | `#3FBF6A` / `#1F7A40` | **right**, the online dot |
| `Theme.land[key]` | unchanged | **only** as a strip or a badge fill, never as text |

**`Theme.ink` is dark.** It is `edge`, and 60-odd call sites use it as the
border and the drop under a label. The text role is `Theme.text`.
`Theme.shadowOf(accent)` returns the dark pair; `Theme.roles` holds the spec's
names (`bg surface surface2 ink inkDim accent good bad warn gold shadow`).
At most two accents on one screen besides land strips.

### Spacing, radius, shadow, type, motion

- `Theme.space = { xs 4, sm 8, md 12, lg 16, xl 24, xxl 32, xxxl 48 }` — no other values.
  Gutter `Layout.gutter()` 24 / 16 upright; card padding the same; `Theme.gap` 16 between cards; `Theme.rowGap` 12.
- `Theme.radius` 8 (card, button) · `radiusInner` 6 (chip, well) · `radiusSm` 4 (keycap) · `stroke` 2.
- `Theme.shadowDy` 6 (card) · `buttonShadowDy` 5 · `chipShadowDy` 3 · `shadowAlpha` 0.85 · `stripH` 4 · `landStripeH` 6.
- `Theme.type = { display 48, title 32, label 16, read 24, code 16, button 16, buttonWide 24 }` **pixels**, `Theme.leading = { 52, 36, 20, 30 }`. `Theme.buttonPx(vw)` picks the button size from the canvas width (`Theme.wideCanvas` = 1600).
- `Theme.control = { buttonL 56, buttonM 44, chip 32, keycap 24, keycapIn 28, footer 48, footerP 64, header 56, headerP 72, gear 40 }`.
- `Theme.maxContentW` 1232 — `Layout.bounded()` / `UI.bounded()` centre content past it.
- `Theme.motion` — hover 0.12 · press 0.06 / release 0.12 · enter 0.26 · stagger 0.04 · toastIn 0.20 / hold 2.4 / out 0.16 · modal 0.22 · transition 0.12 · count 0.6 · sway 0.4 Hz.

## 2. Type

One interface face — **Neo둥근모** (`dunggeunmo`, the default `App:load` sets;
F8 still cycles, and ARCADE = Press Start 2P is on the cycle) — at exactly
16 / 32 / 48. Galmuri11 at 24 for paragraphs. The code face for code only.
Press Start 2P stays on the logo (`UI.logoFont`).

- `UI.font("label" | "title" | "display" | px)` — the interface face at that pixel size, whatever F8 chose. **Never scales with F12.**
- `UI.lead(role)` — the role's line height. `UI.px(role)`.
- `UI.readFont()` / `UI.readPx()` — Galmuri at 24 × the type step on its 12-grid (the one chrome role F12 moves, with code).
- `UI.label(text, x, y, role, { color, align, width, caps, ellipsis, shadow, alpha })` → line height. Titles never wrap: `ellipsis = true` with a `width`.
- `UI.read(text, x, y, w, { maxLines, color, align })` → height; `UI.readHeight(text, w, maxLines)`. Ends in "…" at `maxLines`.
- `UI.labelWidth(text, role)`, `UI.ellipsizeWith(text, w, font)`, `UI.wrapWith(text, w, font)`.

Legacy `UI.text(text, x, y, authoredSize, …)`, `textWidth`, `lineHeight`, `wrap`,
`fitSize`, `ellipsize`, `paragraph` still work; under a 16-cell face an
authored size lands on 16 / 32 / 48 (`UI.legacyPx`). Move screens to the roles.

## 3. Components (`UI`)

| Call | What |
|---|---|
| `UI.card(x, y, w, h, opts)` → `cx, cy, cw, ch` | `variant`: `card` (default: card fill, 2 px edge, shadow +6) · `well` (codeBg, inset 1 px line, no shadow) · `hero` (the gold art frame, `art = "ui_quiz_card"` or `"ui_plaque"`, **once per screen**) · `bar` (header/footer fill) · `flat`. `strip = colour` (4 px top accent; `stripH = 6` for a land), `stripe = colour` (6 px left land stripe), `hot` 0..1, `selected` (gold edge), `alpha`, `shadow = false`, `shadowDy`, `pad`, `fill`, `edge`. Returns the content rect inside the padding. |
| `UI.buttonSize(label, { key, role, h, padx })` → `w, h, font, bold, padx, capW` | **Size every button from this.** The label face is `UI.buttonFont()`: the interface face at 16 on a canvas under `Theme.wideCanvas` (1600) wide, **Galmuri11 at 24 drawn twice a pixel apart** on a wider one (a 1920 fullscreen) — on the canvas width, never on F12 — and the 32 title face for a button 56 tall or more (`role = "title"`). |
| `UI.button(x, y, w, h, label, state, size, opts)` → rect | `state`: `"normal" / "hot" / "disabled"` — **hot is the keyboard cursor as well as the pointer** and changes colour (gold edge, lighter fill), not only motion. `opts.variant`: `primary` (gold, one per screen) · `run` (blue) · `secondary` (default) · `ghost` · `danger`. `opts.id` keys the motion (default the label; never the position). `opts.key = "F5"` draws a keycap inside. `opts.lift`, `opts.scale`, `opts.sway = false`, `opts.role`, `opts.align = "left"`, `opts.padx`, `opts.alpha`. **The label is never ellipsised or shrunk**: a box too small for it grows, centred on the rect it was given, and the rect actually drawn is returned. Faces: secondary `cardHi`, primary gold with dark ink, run blue / danger red with white text; every light label has a 1 px edge drop; hover brightens the face and golds the edge; disabled = `bar` face, mute label, no shadow. |
| `UI.press(id, rect, { fx, sfx })` | Call from your hit test when a button fires: pushes it in (`Juice.trigger`), a spark puff, the select sound. |
| `UI.chip(x, y, label, { selected, color, hot, w, h, alpha })` → w | 32 tall, CAPS 16 in full text on a `cardHi` face. Selected = gold with ink and a 3 px shadow; `color` = a land badge. `UI.chipWidth(label)`. |
| `UI.keycap(x, y, key, { h, font, bold, alpha })` → w | 24 tall (the button's font height + 8 inside a button), lifted `cardHi` face, 2 px edge, 3 px lip, label in full text with its drop. `UI.keycapWidth(key, h, font)`. |
| `UI.buttonLabel(text, x, y, font, color, bold, { w, align, alpha, shadow })` | A label with the button's lift (1 px edge drop, doubled when `bold`). |
| `UI.hint(x, y, items, { w, align, color, alpha })` → w | A row of keycap + verb pairs. `UI.parseHint(str)`, `UI.hintWidth(items)`, `UI.fitHints(items, room, cap, measure)` (pure). |
| `UI.bar(x, y, w, h, fraction, color)` | A rounded progress bar on an edge track. |
| `UI.pips`, `UI.stars` | Difficulty pips; earned stars. |
| `UI.scrollbar(x, y, h, visibleFrac, offsetFrac, { alpha })` | 6 px, `cardHi` thumb ≥ 32, radius 3. Fade it yourself after 800 ms. |
| `UI.scrollFade(x, y, w, color, "top" / "bottom", h)` | The 24 px fade at a clipped edge, so "more below" is visible. |
| `UI.modal({ id, title, w, h, strip })` → `x, y, w, h, closeRect, sheetRect` | Scrim felt 70 %; centred card ≤ 640 (landscape) or bottom sheet (upright); arrives over 220 ms outBack. Caller handles ESC / scrim click. `UI.modalReset(id)` to replay the arrival. |
| `UI.pushToast(text, { kind, seconds, role })` | The dock: top centre, 12 px under the header, slides down (outBack), holds 2.4 s, slides up; max 2; `kind` = `info` (blue strip) / `good` / `bad` / `warn`. Via `app:toast(text, seconds, kind)`. `UI.clearToasts()`. |
| `UI.bounded(maxw, top, bottom)` → `x, y, w, h` | Centred content rect from the header to the footer, ≤ `Theme.maxContentW`. |
| `UI.headerHeight()` / `UI.footerHeight()` | 56 / 48 (72 / 64 upright). |
| `UI.gear(cx, cy, r, color)`, `UI.rrect`, `UI.shadow`, `UI.stroke`, `UI.setColor`, `UI.inside`, `UI.pointer` | Drawing helpers. |
| `UI.panel`, `UI.well` (legacy) | Drawn as cards now; keep the cream panel only where dark text sits on it. |

## 4. The footer rule

**One line, always: 48 px (64 upright).** `app:footer(hint, opts)` from every
scene (`tests/test_screens.lua` asserts it).

- Left: `LV n` (title 32, gold) · an XP bar 96×8 · `450 XP` (landscape only). The XP **counts up** over 600 ms on arrival and after a clear. Nothing when signed out.
- Middle: the scene's key hints as keycap + verb, **the longest prefix that fits**, at most 4 (3 upright). `hint` is a string (`"1-4 pick   F7 hint   ESC map"` — items split at two or more spaces, the first word is the key; translated strings parse the same way) or a list `{ { key = "F5", verb = "run" }, … }` in priority order. `UI.hint_clipped` says whether any were dropped; `app.last_hint` stays a string.
- Right: the connection dot (green open; red + OFFLINE otherwise) and the **⚙** (40×40). The ⚙ or **F9** opens the settings sheet.
- `opts.bare = true` (the title card): no bar, no status, only the ⚙.
- **Never in the footer:** the name, the address, the display controls.

Set `self.header_h` on your scene (a number or a method) so the toast dock
lands 12 px under your header; use `UI.headerHeight()` for the band.

### The settings sheet

`App:open_settings()` / `App:close_settings()`; `app.settings_open`. Drawn from
`App:draw` over every scene (`UI.displayControls(state)`), hit-tested in
`App:mousepressed` **before** the scene, and it takes every key while up (ESC
or F9 closes). Rows: WINDOW · ORIENTATION · TYPE SIZE · LANGUAGE · INTERFACE
FACE · CODE FACE · SOUND · ACCOUNT (name, short address, COPY) · LOG OUT
(danger). `App:display_state()` is what the rows read; `App:display_pressed`
is what they do. F1 / F11 / F12 / L / F8 / F4 keep working.

## 5. Motion rules (`Juice`)

`Juice.update(dt)` runs once a frame from `App:update`. Under `Anim.freeze`
everything completes at once, so drive screenshots are deterministic.

| What | Rule | How |
|---|---|---|
| Hover | lift −2 (cards −8), scale 1.03 (1.05 cards), sway ±1.5° at 0.4 Hz, gold edge; enters over 120 ms | built into `UI.button`; cards: `local a = Juice.follow("scene:hot" .. i, hot and 1 or 0, { speed = 18 })` |
| Press | +4 y, shadow to +1, springs back | `UI.press(id, rect)` / `Juice.pressed("press:" .. id)` |
| Deal-in | from +24 y and alpha 0, 260 ms outCubic, stagger 40 ms in reading order | `local k = Juice.enter("scene:card" .. i, { delay = Juice.stagger(i), dur = Theme.motion.enter })`; `Juice.forget("scene:")` in `enter()` |
| Scene change | a 120 ms fade up from the felt (`App.transition`), then the new scene's deal-in. No wipes. | automatic |
| Count-up | 600 ms, fast first | `Juice.counter(key, value)` → shown, moving |
| Toast / modal | §3 | automatic |
| Retained tweens | `Juice.to(obj, { x = 10 }, dur, ease, { delay, after }):chain(...)`, `Juice.spring(obj, key, target, { k, d })`, `Juice.cancel(obj)` | for a scene that owns its state |
| Curves | `Juice.ease.{linear, outQuad, outCubic, inCubic, inOutCubic, outExpo, inExpo, inOutExpo, cosine, outBack, outBounce, outElastic}` | ease-outs for arrivals, `outBack` for landings |
| Shake | `Juice.shake(seconds, { duration, amount })` (= `Anim.shake`) | a wrong pick |

Keyed state (`follow`, `enter`, `counter`, `trigger/since/pressed`) is
namespaced by kind, so one key can carry all four. Keys are strings you
choose; prefix them with the scene so `Juice.forget(prefix)` can clear them.

## 6. Particles (`Fx`)

`Fx.update(dt)` and `Fx.draw()` run from `App` (bursts draw over the scene).
`Fx.burst(x, y, kind, { n, scale, color, dir, spread, area = { w, h } })`:

| Kind | Use |
|---|---|
| `stars` | a right pick, a toast arriving |
| `confetti` | a clear; `area = { w, 1 }` for a rain from a ribbon |
| `sparks` | a button press (`UI.press` does it) |
| `smoke`, `shards` | a wrong pick |
| `coins` | a node cleared on the map |
| `embers` | a verdict that burned |

`Fx.ambient("dust" | "neon" | "rain", vw, vh)` then `Fx.drawAmbient()` right after
your backdrop (the title and the lands do `dust`); `Fx.ambient(nil)` to stop.
Live bursts are capped at `Fx.MAX_LIVE` (24). The module loads without `love`.

## 7. What a scene agent must know

- **Paint by role, never by land colour on navy** (C++'s blue on navy was 2:1). Land colours are strips and badges.
- `UI.card(..., { variant = "hero" })` **at most once per screen**, for the thing the screen is about. Everything else is `card`.
- Roles never scale with F12; only `UI.readFont()` and `Layout.codeSize` do. A header or footer built on roles cannot overprint itself at step 4. Measure with the active face (`UI.labelWidth`), never with a constant.
- Content is bounded: lay out inside `UI.bounded()`; a 1920 canvas gets the same layout centred, not stretched.
- Give every button an `id` that does not change when it moves. Call `UI.press(id, rect)` from your hit test.
- **Size rows from `UI.buttonSize`** (width and height); a button never shrinks its label, so a rect sized from a label-16 width overflows on a wide canvas where the label is 24. Use `local _, h = UI.buttonSize("A")` for a row's height.
- Hints: hand `app:footer` your keys in priority order; the footer drops from the end. Keep `app:footer(` in your `draw`.
- Toasts: `app:toast(text, seconds, kind)`. The "welcome, name" and "CLEARED" toasts are gone — a clear is the quiz's own right state.
- New `I18n.t` literals need entries in all five `src/lang/*.lua` files (`tests/test_i18n.lua`), and Czech may have fewer than six entries identical to the English.
- `tests/test_screens.lua` greps `src/ui.lua` for `UI.CHIP_MIN_H`, `UI.CHIP_SIZE`, the `chip.every` loop, `function UI.controlRow()` and the `footerRow() * hint_rows + controlRow()` formula; leave them.
- Headless-testable: `make test-headless` (`tests/test_juice.lua` covers Juice and the footer's fit); `make test` draws every scene at both design sizes (`tests/test_layout.lua`) — your scene must draw with an unanswered session.
