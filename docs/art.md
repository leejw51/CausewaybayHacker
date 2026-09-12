# Art brief — Causewaybay Hacker

For FE. This says what the game needs drawn, what the two sibling repos
already have that can stand in unchanged, and what genuinely has to be new.
**Nothing here generates art.** It is a shopping list with a register attached.

Sources of truth this brief is written against:

* `/Volumes/nvidia/vivid/CausewaybayGolang/typescript/public/art/` — the
  manifest convention we take, including `box`
* `/Volumes/nvidia/vivid/CausewaybayRaiden/typescript/public/art/` — the
  sprite look, the enemy cast, the parallax backgrounds
* `CausewaybayGolang/typescript/src/engine/theme.ts` — the palette, as numbers

---

## 1. The register

**Super Mario World sky and Wonder Boy candy, not neon cyberpunk.** That line
is already in `theme.ts` and it is the whole brief in one sentence. A coding
game wants to look like a *game*, and the "hacker terminal" look is the one
thing that would make it feel like homework.

* 16-bit, SNES/Mega Drive. Chunky pixels, hard edges, no soft gradients, no
  drop shadows, no bevel.
* Backgrounds are painted and warm; sprites are read at a glance and sit on a
  flat colour, not a texture.
* Type is Press Start 2P, in the panel chrome that `engine/ui.ts` already draws.
* Hong Kong specifics carry the whole identity: tram wires, bamboo scaffolding,
  the Sogo crossing, an MTR platform edge, a Lucky Mac counter, shop signs
  stacked vertically. Do **not** draw generic "Asian city at night".

## 2. The palette

Take `theme.ts` as it stands. It is already tuned and already shipped twice.

| token | rgb | where |
| --- | --- | --- |
| `sky` | 92,148,252 | the daytime overworld |
| `void` / `navy` | 20,28,72 / 28,36,92 | night, the plant room, the datacentre |
| `panel` | 248,208,136 | quest panel, dialogue box |
| `cream` | 252,236,200 | body text on panel |
| `ink` | 40,24,16 | outlines, panel text |
| `wood` / `brick` | 176,104,40 / 200,76,12 | tenement fronts, tram |
| `coin` | 248,208,48 | stars, XP, the stamp's ring |
| `grass` | 0,168,0 | Victoria Park, the map's path |
| `cyan` | 80,216,248 | **GO LAND** |
| `cppblue` | 0,89,156 | **C++ LAND** — ISO C++ blue, `#00599C` |
| `pygold` | 255,212,59 | **PYTHON LAND** — Python gold, `#FFD43B` |
| `red` | 216,40,0 | Skynet, failure states |
| `pink` | 248,120,168 | confetti, ribbon |
| `admit` | 0,168,68 | CLEARED, accepted verdict |
| `dim` | 120,104,88 | locked nodes, disabled UI |

Four land tints, also in `theme.ts`:

* **RUST LAND** — `TRACK_COL.rust` = `[0.95, 0.47, 0.16]`, Ferris orange, with
  `TRACK_HAZE.rust` over the overworld.
* **GO LAND** — `TRACK_COL.go` = `Theme.cyan`, with `TRACK_HAZE.go`.
* **C++ LAND** — `TRACK_COL.cpp` = `Theme.cppblue`, `#00599C`, with
  `TRACK_HAZE.cpp` a deep blue: noon, harsh sun off the typhoon shelter.
* **PYTHON LAND** — `TRACK_COL.python` = `Theme.pygold`, `#FFD43B`, with
  `TRACK_HAZE.python` a warm amber: dawn under the wet market's fluorescents.

The land tint is a haze layer over the map and a border colour on the panels.
It is **not** a recolour of the sprites; the hero looks the same in both lands
because she is the same person.

## 3. The manifest

Take `CausewaybayGolang`'s `public/art/manifest.json` convention exactly — it
is the better of the two. One entry per asset:

```json
{ "name": "sprite_hero", "file": "sprite_hero.png", "w": 32, "h": 48,
  "box": { "cx": 15.5, "feet": 48.0, "h": 48.0,
           "minx": 4, "miny": 0, "maxx": 26, "maxy": 47 } }
```

`box` is the part that matters and the part Raiden's flat string-array manifest
does not have: it is the sprite's **ink** bounds inside its transparent canvas,
so a sprite is placed by its feet and its centre of mass rather than by the
corner of its bounding box. A map node's sprite stands *on* the path. Keep it.

Served from `/art/…` by the same axum server that serves the frontend
(SPEC §6), so there is one port and no CORS.

## 4. Sprites

### 4.1 The cast

| name | size | status | note |
| --- | --- | --- | --- |
| `sprite_mei` | 32×48 | **exists** — `CausewaybayGolang/.../sprite_mei.png` | Mei Cheung, the player character (docs/story.md §1). She is already drawn as the Rustacean in the sibling. Use it as-is for M1 and M2. |
| `sprite_alex` | 32×48 | **stand-in**: `sprite_hero.png` | Alex the Go coder. The sibling's hero sprite is him. |
| `sprite_ferris` | 128×128 | **exists** — `sprite_ferris.png` | RUST LAND mascot. Sits on the map's land button and on the quest panel's corner. |
| `sprite_gogo` | 128×128 | **exists** — `sprite_gogo.png` | GO LAND mascot, the gopher with the milk tea. |
| `sprite_cpp` | 128×128 | **exists** — `sprite_cpp.png`, generated | C++ LAND mascot, the platypus (오리너구리): duck bill, beaver tail, venomous spur, sits on the harbour wall by the Noon Day Gun. Four animals in one, which is the language (docs/story.md §1). Drawn from the recipe in `art/prompts.toml`; re-run `art/tools/gen.sh` to re-roll it. |
| `sprite_python` | 128×128 | **exists** — `sprite_python.png`, generated | PYTHON LAND mascot, a small coiled python asleep on a price board. Asleep because this is the warm land. |
| `sprite_bo` | 32×48 | **stand-in**: `sprite_cook.png` | Chef Bo, the night kitchen. |
| `sprite_clerk` | 32×48 | **exists** — `sprite_clerk.png` | Generic till NPC for `basic` shopfront nodes. |

### 4.2 Skynet

The antagonists are the **agents** — the things that finished your sentences.
Raiden already drew them, as *pickups*. Here they are enemies, which is the
same art with a different role and, eventually, a red rim.

| name | stand-in | is |
| --- | --- | --- |
| `agent_ghost` | `Raiden/.../claude.png`, `codex.png`, `grok.png`, `gemini.png` | the four suggestion sprites, used as the ambient Skynet agents on the overworld |
| `boss_autocomplete` | **new** | `rust.basic` boss. A phone kiosk whose screen is a wall of grey ghost text. Nothing in either sibling is this. |
| `boss_deadlock` | **exists** — `Raiden/.../bossDeadlock.png` | `rust.advanced` boss. Already named DEADLOCK in Raiden. Take it. |
| `boss_nullptr` | **stand-in** — `Raiden/.../nullptr.png`, scaled up | `go.basic` boss. Works at boss size with a bigger outline. |
| `boss_race` | **new** | `go.advanced` boss. Two turnstiles, one counter, the number flickering. |
| `boss_whiteboard` | **new** | the rust and go `hacker` bosses. A whiteboard and a wall clock. One asset, two maps, different tint. |
| `boss_segfault` | **exists** — `boss_segfault.png` | `cpp.basic` boss, SEGFAULT. The Noon Day Gun fires at an address nobody owns. |
| `boss_dangling` | **exists** — `boss_dangling.png` | `cpp.advanced` boss, THE DANGLING. Victoria Park's pump room: a thread still holding a reference to a buffer that was freed. |
| `boss_linker` | **exists** — `boss_linker.png` | `cpp.hacker` boss, THE LINKER. Room 7-32 again, the same whiteboard and clock, a shorter clock. |
| `boss_none` | **exists** — `boss_none.png` | `python.basic` boss, NONE. The price board at 05:59. |
| `boss_gil` | **exists** — `boss_gil.png` | `python.advanced` boss, THE GIL. Twelve stalls, one lock. |
| `boss_recursion` | **exists** — `boss_recursion.png` | `python.hacker` boss, THE RECURSION LIMIT. The fourth interview; depth 1000. |

Only **three genuinely new sprites**: `boss_autocomplete`, `boss_race`,
`boss_whiteboard`. Everything else in the cast has a stand-in good enough to
ship M2 with.

### 4.3 Map nodes

`node_quest`, `node_boss`, `node_gate`, `node_locked` — 32×32 each, **new**,
but they are the cheapest new art in the list: a circle, a skull-ish boss ring,
a gate, and the same circle in `dim`. Three states each (`locked` / `open` /
`cleared`) per SPEC §6.3, and `cleared` gets the stamp on top rather than a
fourth sprite.

## 5. Backgrounds

Screens, in the order SPEC §10 lists them, and what each one needs behind it.

| screen | background | status |
| --- | --- | --- |
| `boot` | black, the engine's own | — |
| `login` | `title_bg.jpg` / `title_bg_p.jpg` | **exists**, both orientations |
| `lands` | a split: Causeway Bay street left, MTR platform right | **stand-in**: `bg_street.jpg` and `bg_mtr.jpg` side by side |
| `map` (rust) | `map_bg.jpg` / `map_bg_p.jpg` + rust haze | **exists** |
| `map` (go) | same plate, cyan haze | **exists** — the haze is what separates them, do not commission a second overworld for M2 |
| `map` (cpp) | `map_cpp.jpg` / `map_cpp_p.jpg` + `cppblue` haze | **exists** — cpp and python reuse the rust plate under their own haze: the files are copies of it, so a new overworld is a drop-in, and the tint and the mascot are what make the land |
| `map` (python) | `map_python.jpg` / `map_python_p.jpg` + `pygold` haze | **exists** — as above |
| `quest` (rust basic) | `bg_street.jpg` | exists |
| `quest` (rust advanced) | `bg_times.jpg` | exists |
| `quest` (go basic) | `bg_till.jpg` | exists |
| `quest` (go advanced) | `bg_mtr.jpg` | exists |
| `quest` (cpp basic / advanced) | `bg_street.jpg` / `bg_times.jpg` under the `cppblue` haze | exists — the typhoon shelter and the pump room are a tint away until drawn |
| `quest` (python basic / advanced) | `bg_till.jpg` / `bg_mtr.jpg` under the `pygold` haze | exists — the wet market and the food hall, same rule |
| `quest` (hacker, all four) | **new** — a seminar room: whiteboard, clock, one window onto Pok Fu Lam | the only new background |
| `result` | reuse the quest's own, dimmed by `Theme.paper` | — |
| `search` / `stats` / `ai` | `bg_flat.jpg` under a full-width panel | exists |
| ending | `Raiden/.../storyEnd.png` | stand-in |

**One new background for M2.** The rest of the screen list is covered by
`CausewaybayGolang`'s twelve plates, which are already 1152×768 landscape with
768×1152 portrait variants where it matters.

Both orientations are first-class on **every** screen (SPEC §10), so a new
plate is two files, `_p` suffixed, not one.

## 6. Map overworld art

The map is a Super Mario World overworld: numbered nodes joined by a path that
**winds**. The node positions are already authored — `map.x` / `map.y` in each
content pack, `0..1` of the map image (SPEC §12), so the plate can be replaced
without touching content. Twelve layouts exist today:

| pack | nodes | shape |
| --- | --- | --- |
| `rust.basic` | 18 | three rows, serpentine, left to right and back |
| `rust.advanced` | 17 | three rows, serpentine |
| `rust.hacker` | 28 | five rows, serpentine, boss on the last row |
| `go.basic` | 18 | three rows, serpentine, mirrored from Rust Land |
| `go.advanced` | 17 | three rows, serpentine, mirrored |
| `go.hacker` | 28 | five rows, serpentine, mirrored |
| `cpp.basic` | 18 | three rows, serpentine, the rust layout |
| `cpp.advanced` | 17 | three rows, serpentine, the rust layout |
| `cpp.hacker` | 34 | five rows, serpentine, boss on the last row |
| `python.basic` | 18 | three rows, serpentine, mirrored like go |
| `python.advanced` | 17 | three rows, serpentine, mirrored |
| `python.hacker` | 34 | five rows, serpentine, mirrored |

Every layout is generated and then checked against the same rules the content
verifier enforces: inside `0..1`, no two nodes closer than `0.06`, real spread
on both axes, and a direction change at more than half the interior nodes — so
the path winds rather than queueing. The 28-node maps turn 26 times.

The path between nodes is drawn by the engine, not painted into the plate —
three.js carries the parallax layers and the effects (SPEC §10) and the path is
a strip along the segment between two node positions. That is what keeps the
plate reusable across both lands.

Locked nodes draw in `dim` with no path beyond them. A node whose `requires`
are all cleared lights up; the path segment lights with it.

## 7. FX — the stamp, the ribbon, the medal

All four already exist in `CausewaybayGolang/typescript/public/art/` and all
four are 16-bit correct. Take them.

| file | use here |
| --- | --- |
| `stamp_served.png` | **needs one new variant**: `stamp_cleared.png`, the same ring and the same angle, the word changed to `CLEARED`. SPEC §0 says the node is stamped CLEARED for good, and that word is on the sprite. |
| `fx_ribbon.png` | the banner that drops on a clear |
| `fx_medal.png` | 3 stars — cleared with no failed attempt and no hint (SPEC §6.3) |
| `fx_trophy.png` | a whole map cleared |
| `fx_star.png` | the 0–3 stars on each map node |
| `fx_confetti.png` | `engine/particles.ts` and `burst.ts` already drive this |
| `ui_panel.png` | the quest panel chrome |
| `ui_coin.png` | XP / score |

The clear sequence is the sibling's and does not need redesigning: sparkle on
the accepted verdict → ribbon drops → confetti → medal if PERFECT → the stamp
lands on the map node with a shockwave. `engine/burst.ts` and `ease.ts` already
do the timing.

**One new FX asset:** `stamp_cleared.png`.

## 8. What is actually new

The whole commission, in order of how much it matters:

1. `boss_autocomplete` (128×128) — the one enemy that *is* the premise
2. `bg_room732` + `bg_room732_p` — the seminar room, both orientations
3. `stamp_cleared.png` (96×96) — the word on the stamp
4. `node_quest` / `node_boss` / `node_gate` / `node_locked` (32×32 ×4)
5. `boss_race` (128×128)
6. `boss_whiteboard` (128×128)

Six items. Everything else on this page has a stand-in in a sibling repo that
is good enough to ship milestone 2 and, in the cases of `sprite_mei`,
`sprite_ferris`, `sprite_gogo`, `bossDeadlock` and the whole FX set, good
enough to ship for good.

## 9. Rules for whoever draws it

* Power-of-two canvases, transparent PNG, no anti-aliased edges. The sprite is
  scaled by an integer factor by `engine/layout.ts`; a soft edge becomes mud.
* Every sprite gets a `box` in the manifest, measured from the actual ink.
  A sprite without one will sit wrong on the map path and nobody will be able
  to say why.
* Backgrounds are JPEG at 1152×768 (and 768×1152), sprites and FX are PNG.
  That is what the sibling ships and what the sizes are tuned for.
* No text baked into a background. The game runs in seven languages in its
  sibling and will want to here.
* One sprite, one silhouette. If `boss_race` and `boss_autocomplete` read the
  same at 32 px on the overworld, one of them is wrong.
