# Design review — Causewaybay Hacker

DESIGN, 2026-09-11. Reviewed against the register the game claims for itself:
SNES/Mega Drive, *Super Mario World* and *Wonder Boy in Monster World*, Press
Start 2P, and Causeway Bay as a real place.

## What this review is based on

**Seen.** Every capture in `frontend/shots/`, both orientations, opened and
looked at — the 26-shot set for §1-§17, and the regenerated set for the later
rounds. Where a finding says SEEN, it is something visible in a named file.

**Read.** `frontend/src/**` — `engine/theme.ts`, `engine/text.ts`,
`engine/layout.ts`, `ui/chrome.ts`, `scenes/{login,lands,map,quest,result}.ts`,
`gfx/{backdrop,skyline}.ts`, `engine/assets.ts`, `app.ts`. Where a finding says
READ, it is something in the source with a line reference.

**Not judged.** FE reports the editor in these captures is a *rendering* of the
buffer, not a screengrab: no caret, no selection, no syntax colour. So the
quest screen — the screen a player stares at longest — is the one surface I
cannot review from a PNG. **Nothing below comments on the editor's caret,
selection, focus ring or token colours.** That needs a live look, and it should
get one, because it is where the game is actually played.

Every finding is marked **FE** (code) or **DESIGN** (asset), ordered by how much
it hurts.

**Status.** §1–§17 were written against the first round of captures, and FE and
L2D have since acted on most of them — see `docs/decisions.md` for what changed
and why, including the wallet-generation path (§1), difficulty no longer drawn
as stars (§4), the art wired up (§5), and the overworld plate no longer cropped
(§13). They are kept as written rather than edited down to their verdicts,
because the reasoning is what makes the next round of judgements.

Everything after §17 is a later round and is current: **the opening sequence**,
**CHOOSE YOUR LAND**, **the technique assets**, and the pipeline findings. Each
of those names the captures it was written against, since the shot set is
regenerated between rounds and the filenames move.

---

## 1. A first-time player cannot start the game — FE

SEEN `09-logged-out-landscape.png`, `01-login-landscape.png`.
READ `scenes/login.ts:61,264-265`; `grep -rn "generateMnemonic\|entropyToMnemonic\|randomBytes" frontend/src` returns nothing.

The login screen offers one field placeheld `twelve words, or 0x + 64 hex`, and
two buttons, `ENTER` and `CLEAR`. There is no way to obtain a phrase. A player
who has never run `CausewaybayWallet` has nothing to type and no affordance
that suggests what to do about it. This is not a polish item; it is the front
door being locked.

It reads worse because the six-line paragraph below the field explains
*custody* — derivation paths, signatures, what is not sent — to somebody who
does not yet have a key to be custodial about. The screen answers the second
question before the first.

**Do:** a third button, `MAKE ME A PHRASE`, that generates a BIP-39 mnemonic in
the tab, shows the twelve words large enough to copy down, and only then fills
the field. Demote the custody paragraph to two lines under the field
(*"The phrase never leaves this tab. The server only sees a signature."*) and
move the rest behind the `F1`-style help the game already has. The first screen
should say what to do; the second can say why it is safe.

## 2. The CLEARED stamp is drawn in the failure colour — FE

SEEN `06-result-cleared-landscape.png`, `07-map-cleared-landscape.png`.
READ `ui/chrome.ts:246-270` (`clearedStamp` strokes and fills `Theme.red`),
`ui/chrome.ts:235` (`clearRibbon` fills `Theme.red`).

On the victory screen, `ACCEPTED` is set in `Theme.admit` green and the stamp
directly beneath it is `Theme.red` — the same red as `WRONG ANSWER` two screens
earlier. The one moment the whole loop exists to produce is painted in the
colour that everywhere else means you failed. The map's cleared node gets the
same red banner.

Two more things in the same 24 pixels: the stamp is a **rectangle** (a rubber
stamp in this register is a ring), and it **lands on top of the star row**,
crossing it diagonally. The payoff of the loop reads as a collision.

**Do:** `Theme.admit` for the fill, `Theme.coin` for the ring. `art/stamp_cleared.png`
is now a wordless gold-and-green ring sized for a seven-glyph word; blit it and
print `CLEARED` over it in `font("stamp")`, which is exactly what
`CausewaybayGolang/typescript/src/game/render.ts:1642-1647` does with
`stamp_served`. Then give the stamp and the stars separate rows.

## 3. RUST LAND and GO LAND are the same place — FE + DESIGN

SEEN `03-map-landscape.png`; `12-go-land-message.png` for the quest side.
READ `scenes/map.ts:270` draws `map_bg` for both lands; `drawPlate` sets
`globalAlpha = 0.72` and applies no tint. `TRACK_HAZE` appears in
`engine/theme.ts:47-51` and **nowhere else in `src/`**.

`docs/art.md` §5 says one overworld plate carries both lands and "the haze is
what separates them". The haze was never implemented. So RUST LAND and GO LAND
are pixel-identical overworlds, and the only thing distinguishing them is the
accent colour on the info strip below. The quest screen is worse: in
`12-go-land-message.png` the GO panel chrome is the same orange as RUST's.

Land identity is the game's whole spatial premise — one land has one owner,
the other has many things at once — and right now the player cannot see it.

**I amended the art direction here, against `docs/art.md` §5.** Rather than one
plate and a tint, `art/` now ships four overworlds: `map_rust` / `map_rust_p`
(daylight, tram, bamboo scaffolding, market awnings, warm tan paving) and
`map_go` / `map_go_p` (night, MTR platform, neon stalls, delivery bikes, cool
concrete). The story already justifies it — Rust Land is "morning into
afternoon", Go Land is "the lunch rush into the night shift" — and a tint over
one plate was never going to carry that. Two plates also mean the lands stay
distinguishable if the haze is never written.

**Do:** point the map at `map_rust` / `map_go`, and apply `TRACK_HAZE` anyway —
it is four lines and it ties the panel borders to the ground.

## 4. Two different scales, drawn with the same glyph, on the same row — FE

SEEN `07-map-cleared-landscape.png` — the info strip reads `★☆☆☆☆` immediately
followed by `CLEARED · 1/3 STARS`.
READ `scenes/map.ts:417-423` calls `drawStars(..., n.difficulty, 5)`, then
`scenes/map.ts:424-447` prints `${n.stars}/3 STARS` on the same line.

A five-star row (difficulty, authored in the content pack) and a three-star
score (earned, SPEC §6.3) sit two centimetres apart in the same gold star
glyph. A player will read the difficulty row as their score and conclude they
got one star out of five on a quest they three-starred.

This is the one finding here that is a comprehension bug rather than a
refinement. A structural device should encode information, and this one encodes
the wrong information twice.

**Do:** difficulty is not a score, so do not draw it as one. Five small filled
pips, or a short segmented bar in `Theme.dim`/`Theme.brick`, labelled by
position rather than by glyph. Keep the star exclusively for earned stars.

## 5. Four of the thirty-three shipped art assets are ever drawn — FE

READ. Every `name` in `frontend/public/art/manifest.json` (33 entries), matched
against string literals in `frontend/src`, allowing for the `_p` portrait
suffix `engine/assets.ts:94-97` appends internally:

| | |
| --- | --- |
| **Drawn, normally** (4) | `map_bg`, `map_bg_p`, `sprite_ferris`, `sprite_gogo` |
| **Drawn only when WebGL fails** (3) | `title_bg`, `title_bg_p` (`scenes/login.ts:195`), `bg_night` (`scenes/lands.ts:93`) — both behind `if (!this.app.backdrop)`, see §6 |
| **Never drawn at all** (26) | `bg_flat`, `bg_street`, `bg_mtr`, `bg_times`, `bg_mall`, `bg_queue`, `bg_till`, `bg_kitchen`, `bg_set`, `bg_lab`, `bg_market`, `sprite_hero`, `sprite_clerk`, `sprite_mei`, `sprite_cook`, `sprite_monty`, `item_hashbrown`, `item_set`, `ui_coin`, `ui_panel`, `stamp_served`, `fx_star`, `fx_confetti`, `fx_ribbon`, `fx_trophy`, `fx_medal` |

So on a machine with a working GPU — the normal case — the entire visible art of
this game is one overworld plate and two mascots. Eleven painted backgrounds,
five character sprites and the whole FX set are dead weight.

`engine/assets.ts:64` fetches every `.png` eagerly at boot, so the sprites
are downloaded on every load and then never used. The quest screen has no
backdrop at all: `scenes/quest.ts` draws panels straight onto the WebGL
skyline, which is why `04-quest-landscape.png` is the same night city behind
Jardine's Bazaar, an MTR platform and a seminar room alike.

The clear sequence `docs/art.md` §7 describes — sparkle, ribbon, confetti,
medal, stamp, shockwave — has no ribbon, no medal, no trophy and no confetti in
the code, because none of those five assets is referenced. (I am not claiming
this from the frozen frame; I am claiming it from the grep.)

**Do:** this is the largest gap between the specified game and the running one,
and most of it is a one-line lookup per screen. Start with the quest backdrop —
one `picture()` call keyed on land+category — because it is the screen with the
most dwell time and currently the least sense of place.

## 6. The painted title plate only renders when WebGL fails — FE

SEEN `01-login-landscape.png` (procedural skyline) vs `13-no-webgl-map.png`.
READ `scenes/login.ts:195-203` — `title_bg` is inside `if (!this.app.backdrop)`.

Everyone with a working GPU gets `gfx/skyline.ts`'s generated city. The
generator is well-intentioned and its header names the right things — "vertical
signage stacked down a building's face, and the tram wire strung across the
street" — but at the size it renders, the signage reads as coloured window
pips and the tram wire is not visible at all. What lands on screen is a
generic blue night skyline: no tram, no bamboo, no banyan, no shutters, nothing
that says Causeway Bay. `docs/art.md` §1 rules out exactly this
("Do **not** draw generic 'Asian city at night'"), and it is what ships on the
first screen a player ever sees.

**Do:** composite, don't choose. Keep the parallax bands for motion and depth,
and draw `art/title_bg` (or `title_bg_p`) as the still layer behind them at
full strength, with the bands in front. The generated city is a good *middle
distance*; it is a poor *establishing shot*.

## 7. Panels are sized to the viewport, not to their contents — FE

SEEN `02-lands-landscape.png`, `02-lands-portrait.png`,
`05-result-wrong-landscape.png`, `06-result-cleared-landscape.png`,
`04-quest-landscape.png`.

* Lands: the LAND panel is ~620px tall and holds two small buttons at the top,
  then roughly 350px of nothing, then a crab and one sentence. The single most
  important choice in the game — which land — is two small buttons in a corner
  of an otherwise empty box.
* Lands, right: three 76px rows and ~370px of empty panel below them.
* Result: a 50/50 split where the left column holds five short rows and the
  right holds the single line `PASS  greets`, both over ~600px of empty.
* Quest: the brief panel ends 400px above its own bottom edge.

The 16-bit register tolerates emptiness — *Super Mario World*'s message boxes
are mostly air — but that air is *composed*: the box is sized to the message.
Here the box is sized to the screen and the message falls to the top. It reads
as unfinished rather than as breathing room, and it is the thing that most
makes the game look like a work in progress.

**Do:** measure content height, add padding, clamp to a max, and centre the
resulting group in the space. On the lands screen, promote RUST/GO to full-width
stacked plates with the mascot and the sentence *inside* the chosen one — the
choice becomes the panel instead of sitting in its corner.

## 8. The type ladder is twelve sizes across two families that cannot be compared — FE

READ `engine/text.ts:93-106`. In authoring order the sizes are
40, 40, 16, 30, 28, 22, 30, 16, 8, 16, 24, 32 — and they alternate between two
families with very different apparent size at the same nominal px. Press Start
2P at 16 reads larger than VT323 at 30, so `ui`, `station`, `button` (16, pixel)
and `small`, `bubble` (30, body) are not two rungs of one ladder; they are two
ladders leaning on each other. Three fonts are the same size (16) and three more
cluster at 28–32, which means the scale has roughly four usable steps and twelve
names for them.

Two consequences are visible. `stationSm` is `snap8(8 * s)` — an 8px pixel font
— and it sets the map's node numbers inside an 18px-radius circle
(`scenes/map.ts:214, 362-370`), where it is a smudge (SEEN `03-map-landscape.png`).
And on the quest panel the `SAMPLE · greets` label, which is the most
load-bearing information on the screen, is the smallest type on it.

Separately: `docs/art.md` §1 says "Type is Press Start 2P" and that the "hacker
terminal" look "is the one thing that would make it feel like homework".
`text.ts:30` routes all body copy through **VT323**, a DEC VT220 terminal face.
The brief's own register and the shipping typography disagree, and nobody has
written down which one won. That should be a line in `docs/decisions.md` either
way — VT323 is legible and it does set 60-character measures that Press Start 2P
cannot, so keeping it is defensible; keeping it *by accident* is not.

**Do:** collapse to a ratio ladder with one number per rung and a named role, and
measure the rungs in *apparent* size (cap height), not nominal px. Something like
— pixel: `stamp` 24, `ui` 16, `micro` 12 (not 8); body: `display` 36, `read` 26,
`meta` 18. Then raise the map node number to `ui` and the sample I/O to `read`.

## 9. The quest screen's hierarchy is inverted — FE

SEEN `04-quest-landscape.png`, `12-go-land-message.png`.

Reading down the brief panel: the story quote is the largest and brightest text
on the screen (cyan, body-display size); `Print exactly:` is smaller; the thing
to print is smaller still; the constraint prose is smaller again; and the sample
input/output is the smallest thing on the panel. That is exactly the reverse of
the order a player needs while working.

The story line is good writing and it deserves to be there. It does not deserve
to be the loudest thing on a screen someone is trying to code in.

**Do:** invert it. The requirement and the sample I/O take the top of the panel
at `read` size in `Theme.cream`; the story line goes underneath in `meta`, in
`Theme.dim` or a muted cyan, set apart by a rule rather than by size. Give the
sample block the panel's only inset well so the eye can find it without reading.

## 10. The failure screen buries the one thing the player needs — FE

SEEN `05-result-wrong-landscape.png`.

`WRONG ANSWER` is enormous and red. The `expected` / `got` pair — the entire
content of the failure — is set small in `Theme.dim`, lower contrast than the
decoration above it, and `got  ""` is easy to miss entirely. Meanwhile the left
column gives `attempt att_0aa965e83151246d` the same weight as `tests 0/1`, and
reports `exit 0` on a screen whose headline is that something went wrong.

An error should say what happened and how to fix it. This one shouts that
something happened and whispers what.

**Do:** promote `expected` / `got` to `read` size in `Theme.cream`, aligned as a
two-row diff with the differing region marked. Shrink the headline by half — the
red header bar already carries the verdict. Drop `exit` unless it is non-zero.
Move the attempt id to a `meta`-size line at the bottom of the panel, where it
belongs (it is a log handle, not a result).

## 11. Map nodes have no boss language and no lock language — FE + DESIGN

SEEN `03-map-landscape.png`, `07-map-cleared-landscape.png`.
READ `scenes/map.ts:334-388` — `face` is chosen from `n.state` only; `n.kind`
is never read.

Twelve nodes, eleven of them identical dim circles. Node 12 is **THE
AUTOCOMPLETE**, the boss the whole premise is named after, and it is drawn
exactly like node 5. Locked nodes are grey circles with a number: legible, but
nothing says *why* they are unavailable, so a new player reads "these eleven
are broken" rather than "these eleven are ahead of you".

Also: only `quest` and `boss` kinds exist in `content/*/*.toml` —
`node_gate` in `docs/art.md` §4.3 has nothing to point at. I dropped it.

**Do:** `art/node_quest.png`, `art/node_boss.png` and `art/node_locked.png` now
exist. `node_boss` is a spiked crimson gear — a different silhouette, not a
recoloured circle, so it reads at 32px. `node_locked` carries a padlock, which
is the lock language that is missing. Delivered at **64×64**, not the 32×32 the
brief asked for: the map draws at `r = 18 * uiScale` and `uiScale` reaches 1.5,
so a 32px source would be upscaled past 1:1 on a large window.

## 12. The overworld paths are hairlines that ignore the road painted in the plate — FE

SEEN `03-map-landscape.png`. READ `scenes/map.ts:301-332`.

The plate has an authored tan road winding through it. The node graph ignores
it completely: edges are `moveTo`/`lineTo` straight segments that cut across
water, buildings and the tower. The module header promises "a thick ink line, a
lighter core, and a row of dots along it… as a Super Mario World map draws
them", and the ink line and dots *are* there — but a Mario map's path bends, and
a straight chord between two nodes on a drawn landscape is a wire, not a walk.

**Do:** one quadratic per edge, control point offset perpendicular to the
midpoint by ~12% of segment length, alternating sign by edge index. That is four
lines and it converts every chord into an arc that looks authored. The node
coordinates in `content/` do not have to change.

## 13. In portrait, node 1 is in the harbour — FE + DESIGN

SEEN `03-map-portrait.png`: node 1 sits in the water beside the ferry; node 3 is
also in the water. In `03-map-landscape.png` the same node sits on a grassy
hill.

Cause: `map.x` / `map.y` are fractions of the plate (SPEC §12) and the same
fractions are applied to a portrait plate composed differently, so the nodes
keep their numbers and lose their ground. This is the clearest evidence in the
whole set that the orientations are reflowed rather than designed — the
landscape layout was authored against a picture, and the portrait one inherited
the coordinates without the picture.

**My half is done, and it removes most of this.** Every new overworld plate was
generated under an explicit "land fills the entire frame — no water, no sky, no
void, out to all four corners" constraint, written into the prompt precisely
because node coordinates span x 0.06–0.91 and y 0.13–0.88, so any large water
region guarantees nodes in the sea. On `map_rust_p` and `map_go_p` there is
nowhere for a node to fall that is not ground. That is the fix for the symptom,
and it needs no content change.

**Yours is the remaining half:** the plate is drawn `cover`
(`scenes/map.ts:268-299`), scaled to `max(w/aw, h/ah)` and centre-cropped, so a
3:2 plate in the near-square portrait portlet loses roughly 30% off the sides —
and the node fractions are still computed against the *full* plate. Even with a
correct plate, a node at x 0.06 lands outside the visible crop. Use `contain`
for the portrait plate, or map the fractions through the same crop rectangle the
art is drawn into. (I am not proposing per-pack portrait node tables; that is a
content-schema change, it is not mine, and a correct crop makes it unnecessary.)

## 14. The skyline bleeds past the play area and nothing treats the seam — FE

SEEN every portrait capture, e.g. `01-login-portrait.png`, `04-quest-portrait.png`.
READ `app.ts:253` — `this.backdrop?.resize(this.layout.dw, this.layout.dh)`
sizes the WebGL canvas to the **whole window**, while the 2D layer draws the
virtual canvas inset at `layout.ox`/`layout.oy` (`engine/layout.ts:170-171`).

The bleed is deliberate and I think it is the right instinct — black bars would
be worse, and `scenes/login.ts:206-209` says as much. But it is untreated: the
header's orange rule and the footer bar stop dead at `ox` with the city
continuing behind them, so the play area's edge reads as a crop rather than as a
frame. The bands are 300px wide at the capture size; they are too large to
ignore.

**Do:** pick one. Either let the chrome go full-bleed (header and footer span
`dw`, content stays inset), or frame the playfield deliberately — a 2px
`Theme.ink` rule plus a soft `Theme.void` vignette over the bands, which is the
16-bit way of saying "the game is in here".

## 15. Red is doing three jobs — FE

SEEN `05` (failure), `06`/`07` (the CLEARED stamp, §2), `12-go-land-message.png`
(the neutral notice *"the GO land opens in the next chapter"*, in `Theme.red`
across the bottom).

`Theme.red` currently means failure, success and information. A player cannot
learn a colour that means three things.

**Do:** red is failure, and only failure. Success is `Theme.admit`. Neutral
notices are `Theme.coin` on `Theme.paper`, which the game already uses for the
header bars.

## 16. Smaller things, all FE, all SEEN

* **`HINT 2` / `HINT 3`** (`04`, `12`) reads as "hint number two". It means two
  hints remain. `HINT ·· ` with pips, or `2 HINTS LEFT`.
* **`RUN` and `RESET` are the same button** (`04`). The primary action and the
  destructive one are identical in weight and adjacent. Give `RUN` the filled
  `Theme.coin` treatment, leave the rest outlined, and move `RESET` to the far
  end.
* **The hotkey footer duplicates the button row** (`04`: `CTRL+ENTER RUN`,
  `ESC MAP` under buttons that already say `RUN` and `MAP`). Put the shortcut on
  the button, drop the duplicate from the footer.
* **`attempt att_c428ab966a13718d` is on the victory screen** (`06`). Nobody
  needs an internal id at the moment of winning.
* **The log-out dialog is the best-composed screen in the set** (`08`) — real
  modal, real dimming, two clearly differentiated buttons. One thing is
  backwards: the destructive `LOG OUT` has the brighter fill while
  `KEEP WRITING` merely has focus, so the eye is pulled to the action that
  throws work away.
* **The login copy block is the only unframed element on its screen** (`01`) —
  a soft-edged translucent slab under a hard-edged 16-bit panel. In this
  register everything is framed or nothing is.

## 17. The palette is genuinely 16-bit, with two exceptions — FE

READ `engine/theme.ts:13-33`.

The answer to "is it a real 16-bit palette or arbitrary hex" is: real.
`sky` 92,148,252, `grass` 0,168,0, `coin` 248,208,48, `cream` 252,236,200,
`brick` 200,76,12 are NES/SNES-derived values on the 8-per-channel grid, and
they hold together because they came from a palette rather than from a picker.

Two values are not:

* **`paper: [0.1, 0.09, 0.24, 0.84]`** — ad-hoc floats, off the grid, and it is
  the surface *every panel in the game is built on*. The one colour the player
  looks at most is the one that was never chosen from the palette. Nearest
  on-grid equivalent: `navy` 28,36,92 at α 0.84 → `[0.11, 0.14, 0.36, 0.84]`.
  It is a small change and it warms the panels into the same family as the rest.
* **`TRACK_COL.rust: [0.95, 0.47, 0.16]`** — 242,120,41, off-grid, and it is the
  land's identity colour. `brick` 200,76,12 or a 248,152,56 rung would sit in the
  palette and still read as Ferris orange.

Fixing `paper` is the highest-yield colour change available, because it is under
every panel on every screen.

---

## What I changed in the art direction, and why

Four amendments to `docs/art.md`. Each is in `art/prompts.toml` next to the
prompt that implements it.

1. **Two overworlds per land, not one plate plus a haze** (§5). The haze was
   never implemented and one plate cannot carry "morning street" and "night
   network". See §3.
2. **The CLEARED stamp is wordless** (§8 item 3). `docs/art.md` asks for the word
   baked into the sprite. That is wrong twice: Grok cannot spell, so asking for
   lettering guarantees a re-roll; and the sibling already prints the word in
   Press Start 2P over a blank ring at runtime
   (`CausewaybayGolang/.../render.ts:1642-1647`), which is also what lets the
   word be translated. `art/stamp_cleared.png` is a gold ring with a flat green
   field and a thinner rim than `stamp_served`, because `CLEARED` is seven
   glyphs where `SERVED` was six.
3. **`node_gate` is dropped; node markers are 64×64** (§4.3). No pack contains a
   `gate` kind, and 32×32 is upscaled past 1:1 at `uiScale` 1.5. See §11.
4. **The hero is a 128×128 standing figure, not a 32×48 walk cell** (§4.1). Grok
   renders at ~1024px; a reduction to 32×48 is mud, and no prompt fixes a
   resampler. The 128 cell holds real detail and the measured `box`
   (`cx` 63, `feet` 121) places her on her feet exactly as a 32×48 cell would.

**Two things I deliberately did not make.** `fx_star` and `ui_coin` are drawn as
vectors by `ui/chrome.ts:211-215`, at any size the layout asks for. A 48×48
bitmap is strictly worse than that — it has one correct scale — so the budget
went to the six bosses instead, none of which existed in any form.

## The opening sequence — second round

`docs/story.md` §2 is the script and it is already shot-listed; I cut it into
**seven beats**, each delivered in both orientations (14 files, `open_*` and
`open_*_p`):

| beat | what it is |
| --- | --- |
| `open_flat` | the walk-up above the bazaar at 06:40 — desk, laptop, dawn not yet up |
| `open_cursor` | the screen, empty but for one block cursor |
| `open_ghost` | three characters typed, and a long grey bar finishing the line |
| `open_face` | Mei, lit from below by the screen, understanding it |
| `open_tills` | the lane at dawn, every till showing the same grey panel |
| `open_stairs` | going down into the bazaar with a laptop and no plan |
| `open_lands` | the two lands offered, as a promise |

**Both orientations are composed, not cropped.** A 3:2 master centre-cropped to
2:3 keeps 44% of its width, which would have made the cutscene exactly the thing
§13 of this review complains about. So each beat was written twice — the tall
version of `open_lands` splits top/bottom where the wide one splits left/right;
the tall `open_tills` sends the tenements up the frame where the wide one sends
the lane away from you. Every panel keeps its **lower fifth quiet** — plain
floor, plain ground, plain shadow — because an SNES cutscene is a still held
under a caption box, and there has to be somewhere to put it.

**No lettering, and the constraint made the sequence better.** `open_cursor` and
`open_ghost` are the two panels that had to show code without showing code. What
they show is one white block cursor, then three white blocks and a long flat
grey bar running away from them with four more bars beneath. No glyphs, nothing
to misread, nothing to translate — and it says *something else finished your
line* more plainly than legible code would have. The same grey-bar language then
repeats across every till screen in `open_tills`, which is what ties the private
moment to the street.

**Skynet's side is not a new panel.** `bg_datacentre` from the first round is
already that image — racks serving the whole island, indifferent, no face — and
the opening should not spend a beat on the ending's location. Use it if the
sequence wants an eighth card.

## CHOOSE YOUR LAND — third round

The user's note was "add more sprites in each button — not fun", and that is the
right diagnosis of the right screen. SEEN `20-lands-landscape.png`:
READ `scenes/lands.ts:286-338`.

The row is `[right[0], y, barW, rowH]` at full panel width, with the category
label pinned left at `+10*s` and the counts pinned right, both vertically
centred, and `rowH` computed by dividing the leftover panel height by three —
so the row **grows** with the window while its contents stay at the two ends.
At the captured size that is an 807×168 slab with roughly 580px of nothing
between the word and the numbers. Three of them stacked. The land plates beside
them have Ferris and Gogo and read as a place; the rows read as a settings menu.

What is already right, and I did not touch: the 3px bottom rule doubling as a
progress bar (`Theme.admit` filled to `cleared/total`) is good, quiet design —
the row already tells you how far in you are without a number.

**Shape: a wide band, not a square badge.** The empty space is 4.8:1, and the
two ends are spoken for, so an emblem that fills it has to be a band. Each one
is 384×128 (3:1), an object group on transparency rather than a scene plate —
no sky, no ground, no painted background — so it composites onto the navy row
without fighting the panel colour, and onto a different colour later if the
panel changes.

**Placement is FE's, and the band needs insetting.** I composed each emblem with
an empty left quarter so the label would have clean space, and then my own
`process.py` cropped it to the ink and re-centred it, which is correct for every
other sprite in the set and wrong for this one. So the ink now fills the cell:
draw it inset from the label and clear of the counts, and the `box` gives the
exact ink extent. Worth knowing rather than rediscovering.

| emblem | what is in it |
| --- | --- |
| `emblem_rust_basic` | tram, striped awning, crates of oranges, roller shutter, bamboo |
| `emblem_rust_advanced` | one counter, **two** tills, steam, trays, two workers waiting |
| `emblem_rust_hacker` | blank whiteboard, clock, one chair — three objects, nothing else |
| `emblem_go_basic` | turquoise station arch, delivery bike, parcels, lit bollard |
| `emblem_go_advanced` | **six** bikes racked, **two** turnstiles, platform edge, train |
| `emblem_go_hacker` | the same board, clock and chair, lit cold |

Two things the set is doing deliberately. The ADVANCED emblems say their
category by **quantity** — two tills on one counter, six bikes and two
turnstiles — because that road is about two things happening at once, and the
picture can say that without a word. And the two HACKER emblems are **the same
three objects in two different lights**, which is what `docs/story.md` §5 says
the second interview is: same room, and this time the clock is shorter.

**The mascots are the part that answers "not fun".** Emblems fill the row;
they do not make it playful. So each row also gets its land's mascot *doing that
category's job* — Ferris up a crate holding an orange, Ferris working two tills
at once with a tray on his shell, Ferris stuck at a blank board with a marker;
Gogo with a parcel, Gogo flat out on a delivery bike, Gogo holding a clock he is
running out of. Six 128×128 sprites, feet-boxed, sized to sit at row height
between the label and the emblem. That is the literal reading of the request and
also the right one: a mascot reacting is character, and character is what the
land plates already have and the rows did not.

**Two state badges**, because a row that never changes is furniture and a row
that visibly changes is a game: `badge_cleared` (a gold rosette with a green
centre, for a category finished) and `badge_locked` (a shut brass padlock,
deliberately desaturated). The locked row currently only dims, which is §11 of
this review happening again on a different screen — dimming says *not now* but
never says *why*.

**Checked at the size they are drawn, not the size they were made.** Every
emblem was composited onto the real row colour at 384×128 and at 192×64, every
mascot at 120px and 60px, every badge at 64px and 32px. That caught two:
`emblem_rust_hacker` came back as seven pale boxes that turned to mud when
small, and `mascot_rust_hacker` put a huge whiteboard next to a tiny crab. Both
re-rolled — the emblem down to three high-contrast objects and nothing else, the
mascot with Ferris as the subject and the board reduced to a corner behind him.
This is the `boss_deadlock` lesson applied before shipping rather than after.

## For the technique round

Three assets aimed at what FE is building rather than at another still:

* **`walk_mei`** — a four-frame walk cycle, 64×96 per frame, 256×96 strip, side
  profile, feet on one line. The manifest carries `frames`, `fw`, `fh` and a
  **box per frame**, so the renderer can place each frame by its own feet.
  Generated as one image of four figures and cut apart by `art/tools/strip.py`,
  which takes the largest four ink components left to right — Grok will not lay
  frames on an even grid, so nothing assumes one.
* **`fg_wires`** — a 1152×384 near-parallax overlay for the Mode-7 plane: tram
  wires, insulators, two poles, a banyan branch with aerial roots, an awning
  edge and four hanging sign panels, all hanging from the top with the lower
  half transparent. Scroll it faster than the plane.
* **`neon_signs`** — six vertical signs, each one flat hue over a darker face of
  the same hue, for palette cycling. `art/palette.json` carries the measured
  tube/face pair and `hue_deg` for all six (352°, 213°, 127°, 47°, 25°, 282°),
  so the cycle can rotate hues without eyedropping the PNG.

## Two pipeline findings from this round

**Trapped backdrop was showing on five sprites, and I missed it last round.**
The knockout is seeded from the border, which is what protects pink *inside* a
sprite — but backdrop the silhouette *encloses* (under a whiteboard's board,
inside a turnstile's display slot, between two padlocks) was never reachable and
stayed magenta. At 128px I read it as intentional pink; at the 32–64px the map
actually draws these at, it is plainly a rendering fault. `process.py` now drops
enclosed magenta components under 10% of the ink area. Flatness does not
separate the two cases — `fx_ribbon`'s painted cloth came back *flatter* than
the pockets — but size does, by 20×: pockets ran 0.2–3.8% of ink, the ribbon's
cloth is 33%. This fixed five existing sprites with no new generations.

**Never ask for magenta-family colour in a sprite's artwork.** Asked for a hot
pink neon sign, Grok painted it in (252,35,176) — the studio backdrop's own
colour — and the knockout removed it, correctly, because they are the same
pixels. No predicate can separate them; this is a prompt rule, not a tuning
problem. Sprites that want a pink use crimson or violet. Both rules are now in
`art/prompts.toml`'s header.

## The art, and what is in it

63 assets in `art/` — 27 backgrounds and story panels, 35 sprites and one
animation strip — from 82 generations across three rounds, so 19 re-rolls. The
per-asset count is in `art/prompts.toml`, which is also the recipe: change a
prompt, re-run `art/tools/gen.sh`, and that asset is re-rolled.
`art/manifest.json` is in `CausewaybayGolang`'s shape with all 35
sprite boxes measured from the actual alpha — plus a box per frame on the
`walk_mei` strip: `art/tools/manifest.py` calls the same `ink_bounds` the
knockout uses, so no box is guessed.

**One caveat on `box`.** `feet` means "the row the ink stands on", and for the
cast, the bosses and the node markers that is exactly what it is — place
`sprite_mei` at `feet` and she stands on the path. For `ui_panel`, `fx_ribbon`,
`fx_medal` and `fx_trophy` nothing stands on anything: there `minx`/`miny`/
`maxx`/`maxy` are the load-bearing numbers (they are what lets a banner be
stretched by its cloth and not by its transparent margin) and `feet` is
incidental. The sibling manifest has the same shape for the same assets, so this
is a note, not a difference — but do not anchor a panel frame to `feet`.

**The pipeline is not the sibling's, and this matters.** `love2d/src/assets.lua`
knocks the magenta out at load time; `frontend/src/engine/assets.ts:64` does
no pixel work at all — it fetches a PNG and draws it. Raw Grok output dropped
into `frontend/public/art/` would render as **magenta squares**. So
`art/tools/process.py` runs the knockout ahead of time: the same border-seeded
flood fill with the same predicate, so pink *inside* a sprite (Gogo's paws, a
neon canopy) survives while the backdrop goes. Every delivered PNG has binary
alpha, 0 or 255, matching every sprite in the sibling set.

`art/tools/gen.sh` writes the prompt to `art/prompts.toml` *before* it processes
the image, so a crashed run still leaves the recipe. The whole set can be
re-rolled from that file.

---

## If only five things get done

1. **§1** — a first-time player cannot start. Everything else is decoration
   until this is fixed.
2. **§2** — the CLEARED stamp in green, from the ring asset. Half an hour, and
   it fixes the payoff moment of the entire loop.
3. **§4** — stop drawing difficulty as stars. It is actively misinforming.
4. **§3** — point the map at `map_rust` / `map_go`. The lands become two places.
5. **§7** — size panels to content. It is the change that most makes the game
   stop looking unfinished.

---

# Second review — 2026-09-11, against the 32-shot capture set

A lot has shipped. `title_bg` is the login backdrop (§6 closed), `NEW WALLET`
exists (§1 closed), the custody paragraph is two lines (§1's copy note taken),
difficulty is a segmented bar and no longer a star row (§4 closed), the plate is
no longer cropped (§13 closed), the quest screen has split `RUN` from `SUBMIT`
and `HINT 2` has become `3 HINTS LEFT` (§16 closed), and the category rows carry
emblems and a line of prose. The screen the user called "not fun" now reads as a
place.

**Seen:** the 32 captures timestamped 15:50 in `frontend/shots/`, both
orientations, including the `no-webgl` and portrait variants.
**Read:** `scenes/{lands,map}.ts`, `ui/editor.ts`, `dev/capture.ts`.

**Still not judged, third time of asking.** `dev/capture.ts:67` still says it
plainly: *"This is a rendering of the overlay, not a screengrab of it — the
caret, …"*. The editor in every quest capture is re-drawn text, so **nothing
below reviews the editor's rendered colours, caret, selection or active-line
band.** What is new is that those things now exist in source, so §2.5 reviews
the *palette as written* — that is READ evidence, and it is not the same as
seeing it.

---

## 2.1 Nodes float in open sky on both landscape overworlds — DESIGN (mine, fixed this round)

SEEN `32-map-walk-a.png`: Mei is standing on a gold marker in open blue sky at
the top left, in front of a floating striped awning, with the skyline behind
her. MEASURED: `map_rust`'s top-left 15%×30% region was 81% sky-blue, and
`rust.basic` node 1 at (0.044, 0.146) sampled rgb(65,114,173) — water.

This is §13 of the first review happening again **in my own plate**. I asked for
"land fills the entire frame" in the prompt, looked at the picture, and called
it done. The prompt said it; the picture did not do it; nobody checked the one
thing that mattered, which is whether the authored node coordinates land on
ground.

**A prompt is not a test.** `art/tools/checknodes.py` is now the test: it reads
every `map = { x, y }` out of `content/*/*.toml`, samples the plate around each
one and fails on any node whose neighbourhood has no structure in it.

Hue does not work as the measure — `map_go` is a night plate whose *ground* is
indigo, and a blue-dominance test called a lit platform and a neon stall
"water". **Local variance** does work and is hue-independent: ground has roofs,
kerbs and outlines and measures 20–40; open sky and water measure 0.2–0.9. The
cut is at 4.0, an order of magnitude clear of both sides, calibrated against
crops of every borderline case.

Both landscape plates were re-rolled with an absolute corner-to-corner
constraint. All **120 node placements across 6 packs × 2 orientations now
pass**, and the check is a script anyone can run before shipping a plate.

## 2.2 The quest brief panel clips its own text, mid-glyph — FE

SEEN `43-quest-portrait.png`: the line `input:  3` is sliced horizontally
through its middle by the panel's bottom edge — not hidden, not scrolled away,
cut through the letterforms. SEEN `40-quest-landscape.png`: the brief's third
line ends `Join them in` hard against the right border with the next word gone.

There is a scrollbar, so the overflow is known about; what is wrong is where the
cut falls. A panel that ends mid-glyph reads as a broken renderer, and this is
the panel carrying the thing the player has to do.

**Do:** clip to a whole line — floor the visible height to a multiple of
`font.height` — and give the text a right inset so a glyph never touches the
border. In portrait, the proportions are also backwards: the editor gets ~900px
for fifteen lines while the brief gets ~350px and overflows. The brief is what a
player reads before they can type anything; give it the room in portrait.

## 2.3 The game's name is the lowest-contrast text on its own first screen — FE

SEEN `10-login-landscape.png`. MEASURED: the title glyph rgb(202,236,248)
against the sky behind it is **8.26:1**; against the pink tenement it crosses,
**2.25:1**. It has a glow but no plate and no ink outline, so its legibility
changes across its own length — which is why it reads as patchy rather than
simply dim.

This is the cost of §6 being fixed: the painted backdrop is now real art with
real contrast range, and type that sat fine on a flat procedural sky no longer
does.

**Do:** the 16-bit answer is an ink outline — 2px `Theme.ink`, offset in all
four directions — which is what every SNES title does and what keeps the glow.
If you would rather not outline, I will make a title plate; say which and it is
one asset.

## 2.4 The emblem bands are squashed, not scaled down — FE

SEEN `20-lands-landscape.png`. READ `scenes/lands.ts:398-402`:

```
const k  = bandH / (abox.maxy - abox.miny);   // scale chosen from HEIGHT only
const iw = (abox.maxx - abox.minx) * k;
const bw = Math.min(iw, barW * 0.44);          // width clamped independently
g.drawImage(art, …src…, bx, y + inset, bw, bandH);
```

`bw` is clamped while `bandH` is not, so any band whose proportional width
exceeds 44% of the row is drawn into a narrower box at unchanged height —
compressed, not fitted. MEASURED in the capture: the BASIC emblem displays at
322×145 (2.22:1) where its ink is 384×114 (3.37:1) — **66% of its correct
width**. It is most visible on the tram, which is tall and narrow instead of
long and low.

**Do:** take the scale from both constraints at once —
`k = Math.min(bandH / inkH, (barW * 0.44) / inkW)` — then `bw = inkW * k`,
`bh = inkH * k`, and bottom-align in the row. The comment above this block
describes the right intent; only the arithmetic disagrees with it.

## 2.5 The editor's syntax palette: two collisions and two thin contrasts — FE

READ `ui/editor.ts:49-59`. Contrast computed against the effective quest-panel
background — `paper` at α 0.84 over the night city, ≈ rgb(25,24,63):

| role | token | contrast |
| --- | --- | --- |
| name / property / macro | `cream` | 14.49:1 |
| operator | `panel` | 11.58:1 |
| typeName / class | `coin` | 11.33:1 |
| number / bool / null | `coin` | 11.33:1 |
| function | `cyan` | 10.09:1 |
| keyword | `pink` | 6.64:1 |
| string | `grass` | 5.32:1 |
| **invalid** | `red` | **3.40:1** |
| **comment / meta** | `dim` | **3.16:1** |

Most of it is strong, and choosing the palette from `Theme` rather than from a
stock editor theme was right. Four things to change:

1. **`coin` is both a type and a number.** In `let n: u32 = 32;` the `u32` and
   the `32` render in the same colour. That is the one place in the game where
   precision is the entire point. Move numbers to `Theme.brick` or `Theme.pink`.
2. **`comment` is `Theme.dim` at 3.16:1** — and `dim` is the token that
   everywhere else in this game means *disabled or locked*. The starter code's
   comment (`// your code here`) is the first instruction a player reads, and it
   is set in the colour reserved for things you cannot use.
3. **`invalid` at 3.40:1** makes the error token nearly the least visible thing
   on the screen. Errors should be the most visible.
4. **`operator` is `Theme.panel`** — a *surface* token used as a foreground. It
   happens to work on a dark panel; it stops working the moment a panel is
   light. Use an ink-family token.

## 2.6 An unearned star reads as an earned one at a glance — FE

SEEN `32-map-walk-a.png`. I read the info strip at full-screen scale as three
gold stars on a node with `TRIES 0`, went to write it up as a bug, magnified
the region, and found three *dim* stars — no bug. `scenes/map.ts:1218-1226` is
correct.

The misreading is the finding. Filled-dim and filled-gold share shape, size and
weight and differ only in fill, so at a glance the row says "three stars" in
both states. If three rounds of staring at this palette did not save me, it will
not save a player.

**Do:** draw an unearned star as an **outline** — `Theme.dim` stroke, no fill.
Empty and full then differ in ink, not just in hue, which survives both a glance
and a colour-blind viewer.

## 2.7 `fg_wires` has nothing to hang from on a top-down map — FE + DESIGN

SEEN `32-map-walk-a.png`. READ `scenes/map.ts:1004`, `gfx/mode7.ts:303`.

I built `fg_wires` as a near-parallax layer for a *street* — things that hang
from above, with the lower half empty. The overworld is a top-down diorama, so
"above" is open sky, and the awning corner and the utility pole now float
unattached over the map's top edge. The wires themselves came back dark maroon
rather than black and read purple against blue.

**Do (FE):** clip the overlay to the plate and keep only the wire layer on the
map, or drop it there and save it for a street scene, which is what it is for.
**Do (DESIGN):** if it stays, I will re-roll it as wires and insulators only —
no awning, no pole, no signs — in near-black. Say which and it is one asset.

## 2.8 The character layer is invisible on a phone — FE

READ `scenes/lands.ts:103`:
`const act = hovering?.startsWith("cat:") ? \`mascot_${land}_${hovering.slice(4)}\` : null;`

The mascot action sprites are gated on hover, and hover does not exist on touch.
The half of last round's work that was aimed squarely at "not fun" is therefore
absent on the device where the screen is most likely to be read.

Putting them in the land plate rather than the row was a better idea than the
one I had — it gives the mascot somewhere to live and keeps the row clean. It
just needs a non-hover trigger: the **selected** category, falling back to the
default pose, so a touch user sees the character change as they move through the
list.

## 2.9 Smaller things — FE, all SEEN

* **`that is not there any more`** (`41-quest-run-report-fail.png`) — a toast in
  `Theme.red` that names neither what was missing nor what to do. An error
  should say what happened and how to fix it.
* **The map's top bar puts three kinds of control in one row**
  (`30-map-landscape.png`): `RUST` `GO` are a land toggle, `BASIC` `ADVANCED`
  `HACKER` are a category toggle, and `ALL MAPS` `PLAYGROUND` are destinations —
  seven identical buttons, separated only by a gap. Group them: toggles as
  segmented controls, destinations set apart in weight, not just in spacing.
* **A node labelled `?`** sits among numbered siblings (`30-map-landscape.png`)
  and reads as a missing value rather than as a deliberate state.
* **`CLEAR` is orphaned onto its own row** under `ENTER` / `NEW WALLET` /
  `STORY` (`10-login-landscape.png`). Four buttons wrapping 3+1 looks like a
  layout accident; `CLEAR` is also the least important of the four.
