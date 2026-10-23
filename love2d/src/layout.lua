-- The virtual canvas.
--
-- **Ported from `CausewaybayGolang/love2d/src/layout.lua`**, which is itself
-- the Lua half of `CausewaybayGolang/typescript/src/engine/layout.ts`. SPEC
-- §10 says to take it as it stands, and this does: the authored sizes, the
-- integer scale above 2×, the `MAX_STRETCH = 1.5` growth along the long axis
-- instead of letterboxing, and `uiScale()` are unchanged arithmetic.
--
-- What is different from the original:
--
--   * the sibling's `Persist`, `I18n` and `SFX` dependencies are gone. This
--     game has one language on screen and its settings live on the server
--     (PROTOCOL §4.5's `settings`), so the save/load hooks are *injected*
--     (`Layout.storage`) rather than reached for. That also lets the layout
--     tests run without a save directory.
--   * `Layout.init` takes a preferred mode, so a `settings.orientation` that
--     came back from `auth.resume` wins over the display shape.
--
-- The requirement this file exists to satisfy: **both orientations are
-- first-class on every screen** (SPEC §10), not just the map. Every scene
-- draws into `Layout.vw × Layout.vh` and asks `Layout.isPortrait()`; nothing
-- hard-codes 1280 or 720.

local Theme = require("src.theme")

local Layout = {
  mode = "landscape",
  --- True only when the *player* chose this orientation — F1, or CWBH_ORIENT.
  --- False means the mode was inferred from the window's shape and should be
  --- inferred again the next time that shape changes. See `orientationFor`.
  pinned = false,
  fullscreen = false,
  --- The type-size step, an index into `FONT_STEPS`. See `DEFAULT_FONT`
  --- for why it starts on the second rung.
  font = 2,
  --- Overrides CWBH_FULLSCREEN when set. "desktop" | "exclusive".
  fullscreenPref = nil,
  pendingWindow = false,
  vw = Theme.landW,
  vh = Theme.landH,
  scale = 1,
  ox = 0,
  oy = 0,
  canvas = nil,
  -- { save = function(record), load = function() -> record }
  storage = nil,
  on_change = nil,
}

-- Extra virtual pixels allowed past the design size so fullscreen does not
-- sit in a tiny letterbox.
local MAX_STRETCH = 1.5

-- How far under the design size a window is shown at 1× — with less canvas
-- — before the canvas is shrunk to fit instead. See `updateViewport`.
local SHRINK_FLOOR = 0.7

--- How much bigger every authored type size is than it used to be.
---
--- **The measured reason, not a preference.** The ladder this client was
--- drawn with is 7, 8, 9 and 10 px — 55 labels at 7 and 36 at 8 — against a
--- 1280×720 or 720×1280 design. On the 1080×1920 the bug report came from,
--- `Layout.scale` is 1 and `MAX_STRETCH` spends every extra pixel on a bigger
--- canvas rather than bigger furniture, so a 10 px label is **0.52 % of the
--- frame's height**, where the same label on a laptop window is 1.39 %. The
--- canvas grew; the type did not.
---
--- Doubling the ladder puts roughly 65 characters across a portrait frame
--- instead of 135, and — because `Assets.snap8` then rounds to the 8-pixel
--- grid both faces are drawn on — it lands the ladder on 16 / 24 / 32 / 48,
--- which are sizes Press Start 2P and Unifont are actually drawn at. The old
--- 7/9/10/11/13 were not, so every one of them was being resampled: the type
--- was soft *and* small, and the softness made it read smaller still.
Layout.TEXT_BASE = 2

--- The type-size steps, as multipliers on the authored code size.
---
--- **Four steps and a cycle, not a slider.** A slider in a pixel-art header
--- is the wrong instrument: it has no legible current value, no keyboard
--- equivalent, and eleven positions nobody wants. Four named steps have one
--- state each, say which one they are in, and the whole control is one
--- button that a player can hit without aiming.
---
--- **One step under the authored size, two over it.** 1.0 is the authored
--- ladder doubled (`TEXT_BASE`) and is the default; 0.75 is for a player who
--- wants more on the screen still; 1.5 and 2.0 are for big type. What was
--- 2.5 went: it was the step that printed `PICK A LAND` wider than a portrait
--- canvas, and nobody needs a fifth of the screen per word.
---
--- **No arbitrary fractions.** Every size in this client is rounded onto an
--- 8-pixel grid, so a step of 1.25 and a step of 1.55 both land a 16 px
--- label on 24 px and the control would have two positions that did
--- nothing. 0.75 is the one quarter-step, and it earns its place on the
--- grid: an authored 10 goes 20 → 15 → **16** px (24 at 1.0), 7 goes to 8,
--- 14 to 24 (32 at 1.0). An authored 8 stays on 16, which is the floor a
--- label is still readable at.
---
--- `src/store.lua` (`DISPLAY_V`) maps the index a store wrote under the old
--- `{ 1.0, 1.5, 2.0, 2.5 }` onto this one by multiplier.
Layout.FONT_STEPS = { 0.75, 1.0, 1.5, 2.0 }

--- The step a fresh install opens on.
---
--- **1, again.** It was 2, because portrait at step 1 was reported as too
--- small: on a 1080×1920 panel the canvas is half again as big as the design
--- and a 24 px label was a sliver of it. Step 2 fixed that by making the type
--- half again as big *everywhere*, and on the window most people play in — a
--- laptop, 1280×720 — that put a 10-px-authored label at 32 px, the land
--- picker's nine columns on top of each other, and a quest that showed three
--- of its four answers. The next report was "the font is too large, taking
--- too much space", and that was right too.
---
--- What the first report needed was type that grows with a **tall** canvas,
--- not type that is bigger on every canvas, and `Layout.growth` is that now.
--- So the default, 1.0, is 24 px for an authored 10 in every landscape
--- window — a laptop's 1280×720 and a 1920×1080 fullscreen alike — and 32
--- on the 1080×1920 the first report came from. It is index 2 because 0.75
--- sits under it; F12 cycles 0.75 → 1.0 → 1.5 → 2.0.
Layout.DEFAULT_FONT = 2

local FULLSCREEN_TYPES = { desktop = true, exclusive = true }

--- `desktop` or `exclusive`.
---
--- **`desktop` by default, deliberately.** `exclusive` changes the display
--- mode, and a player who ends up in it at the wrong resolution — or whose
--- game exits badly while in it — is left with a rearranged desktop. The
--- override exists for anyone who wants the real thing, and matches the
--- sibling's `GOSET_FULLSCREEN` (`CausewaybayGolang/love2d/src/layout.lua`).
function Layout.fullscreenType()
  local want = tostring(Layout.fullscreenPref or os.getenv("CWBH_FULLSCREEN") or ""):lower()
  if FULLSCREEN_TYPES[want] then return want end
  return "desktop"
end

--- Which orientation a window of `w x h` wants, when the player has not
--- pinned one.
---
--- A pure function, so the rule can be asserted without a window. Square-ish
--- windows keep landscape: the authored 1280x720 layout is the one every
--- screen was drawn against, and flipping to portrait at 1.01:1 would make a
--- slow drag of a window border thrash the whole UI.
function Layout.orientationFor(w, h)
  if not w or not h or w < 1 or h < 1 then return "landscape" end
  return (h > w * 1.05) and "portrait" or "landscape"
end

local function highdpi()
  return true
end

--- Vsync, as `conf.lua` chose it.
---
--- `applyWindow` re-creates the window on every orientation and fullscreen
--- change, and a hard-coded `vsync = 1` here would put it back on halfway
--- through a drive script — which is exactly the stall `conf.lua` turns it
--- off to avoid.
local function vsync()
  if os.getenv("CWBH_TEST") == "1" then return 0 end
  if (os.getenv("CWBH_DRIVE") or "") ~= "" then return 0 end
  return 1
end

local function windowedFlags()
  return {
    fullscreen = false,
    fullscreentype = "desktop",
    -- Resizable **even when this is used for a fullscreen window**. SDL only
    -- puts a resizable window into a native macOS fullscreen Space; a
    -- fixed-size one falls back to legacy fullscreen at
    -- CGShieldingWindowLevel, which paints over the Shift-Command-5 capture
    -- UI and hides it. (`CausewaybayRaiden/love2d/src/display.lua`.)
    resizable = true,
    vsync = vsync(),
    msaa = 0,
    minwidth = 640,
    minheight = 400,
    centered = true,
    highdpi = highdpi(),
  }
end

local function fitWindow(wantW, wantH)
  local dw, dh = love.window.getDesktopDimensions()
  local maxW = math.max(640, dw - 80)
  local maxH = math.max(400, dh - 100)
  local w, h = wantW, wantH
  local s = math.min(1, maxW / w, maxH / h)
  w = math.max(560, math.floor(w * s))
  h = math.max(400, math.floor(h * s))
  return w, h
end

function Layout.applyWindow()
  -- A window change while a canvas is bound throws that canvas away
  -- mid-draw, so unbind first. `Layout.flush` normally keeps this off the
  -- draw path entirely.
  if love.graphics.getCanvas() then
    love.graphics.setCanvas()
  end
  if Layout.fullscreen then
    local want = Layout.fullscreenType()
    local _, _, cur = love.window.getMode()
    if not (cur.fullscreen and cur.fullscreentype == want) then
      if love.window.isOpen() then
        -- `setFullscreen`, not `setMode`. Two reasons, both from
        -- `CausewaybayRaiden/love2d/src/display.lua`:
        --
        --   * `setMode` can recreate the window, which on macOS drops it out
        --     of its native fullscreen Space and back to legacy fullscreen;
        --   * `setFullscreen` keeps the window and its flags, so the Space
        --     — and the player's other windows — stay where they were.
        love.window.setFullscreen(true, want)
      else
        local dw, dh = love.window.getDesktopDimensions()
        local flags = windowedFlags()
        flags.fullscreen = true
        flags.fullscreentype = want
        love.window.setMode(dw, dh, flags)
      end
    end
  else
    local w, h
    if Layout.mode == "portrait" then
      w, h = fitWindow(Theme.portW, Theme.portH)
    else
      w, h = fitWindow(Theme.landW, Theme.landH)
    end
    local cw, ch, cur = love.window.getMode()
    if cur.fullscreen then
      -- Leaving fullscreen the same way it was entered, so the Space closes
      -- rather than the window being replaced underneath it.
      love.window.setFullscreen(false)
      cw, ch = love.window.getMode()
    end
    if math.abs(cw - w) > 8 or math.abs(ch - h) > 8 then
      love.window.setMode(w, h, windowedFlags())
    end
  end
  -- `love.resize` is not guaranteed to fire after `setMode`/`setFullscreen`
  -- (Raiden's `display.lua` says the same), so the viewport is re-measured
  -- here rather than waited for. `Layout.begin` re-measures every frame too,
  -- which covers the frames drawn during the macOS fullscreen animation.
  Layout.updateViewport()
end

--- Window changes are deferred to the top of the next frame: `love.window
--- .setMode` while a canvas is bound throws the canvas away mid-draw.
function Layout.flush()
  if not Layout.pendingWindow then return end
  Layout.pendingWindow = false
  Layout.applyWindow()
end

function Layout.save()
  if Layout.storage and Layout.storage.save then
    Layout.storage.save({
      mode = Layout.mode,
      -- **Persisted, and this is the point.** Without it, a mode restored
      -- from disk is indistinguishable from one the player pressed, and the
      -- client can never re-evaluate the orientation again for the life of
      -- the install. See `Layout.load`.
      pinned = Layout.pinned,
      fullscreen = Layout.fullscreen,
      -- On the same record as the other two, because they are one setting —
      -- "how this window is set up". Two records would be two ways for them
      -- to disagree, and a migration would have to carry both.
      font = Layout.font,
    })
  end
end

function Layout.load()
  if not (Layout.storage and Layout.storage.load) then return false end
  local rec = Layout.storage.load()
  if type(rec) ~= "table" then return false end
  local applied = false
  if rec.mode == "portrait" or rec.mode == "landscape" then
    Layout.mode = rec.mode
    applied = true
  end
  -- A restored *pin* is as strong as a pressed one — that is what a pin
  -- means. A restored *inference* is not a pin at all, and must be inferred
  -- again from whatever shape the window has this time.
  --
  -- Treating the two the same is the bug the browser client hit: a landscape
  -- that was merely inferred once, saved, and then restored as though the
  -- player had insisted on it, surviving into a window shaped like a
  -- portrait and never re-evaluating. A record written before this field
  -- existed has no `pinned`, and is read as "not pinned" — the safe side,
  -- because an unpinned mode is re-derived and a wrongly-pinned one is not.
  Layout.pinned = rec.pinned == true
  if type(rec.fullscreen) == "boolean" then
    Layout.fullscreen = rec.fullscreen
    applied = true
  end
  -- Somebody who prefers big type wants it every launch, not once. An
  -- out-of-range step from a newer client falls back to the default rather
  -- than indexing off the end of the table.
  local step = tonumber(rec.font)
  if step and Layout.FONT_STEPS[math.floor(step)] then
    Layout.font = math.floor(step)
    applied = true
  end
  return applied
end

--- F / F11. Returns the new state, for the caller's toast.
---
--- The transition touches nothing but this module: no scene is rebuilt, no
--- buffer is reloaded, no request is re-sent. A toggle that lost the source
--- a player had half-written would be worse than having no toggle.
function Layout.toggleFullscreen()
  Layout.setFullscreen(not Layout.fullscreen)
  return Layout.fullscreen
end

function Layout.setFullscreen(on)
  on = on and true or false
  if Layout.fullscreen == on then return end
  Layout.fullscreen = on
  Layout.pendingWindow = true
  Layout.save()
end

--- F1 cycles: landscape (pinned) -> portrait (pinned) -> automatic.
---
--- Three states rather than two, because "automatic" has to be reachable.
--- Once a player has pressed F1 even once, a two-way toggle leaves them
--- pinned forever with no way back to the behaviour they started with — and
--- in fullscreen, where the window's shape is the display's and not theirs,
--- automatic is usually the right answer.
---
--- Returns a short label for the caller's toast.
function Layout.cycleOrientation()
  if not Layout.pinned then
    Layout.setOrientation("landscape", true)
    return "landscape"
  end
  if Layout.mode == "landscape" then
    Layout.setOrientation("portrait", true)
    return "portrait"
  end
  Layout.unpinOrientation()
  return "automatic"
end

--- The type-size cycle: step 1 → 2 → 3 → 4 → 1. Returns the new step.
---
--- **It moves the code face, not the chrome.** The screen this exists for is
--- the editor: a forty-line interview answer on a laptop panel is where
--- bigger type pays, and it is the one surface in this client a player reads
--- for an hour at a time. Scaling every label with it would reflow eleven
--- screens that were authored against a fixed grid — the node card, the
--- award shelf, the stats table — to help the one screen that is not made of
--- labels. So this is a code-size control and the report says so.
---
--- Nothing here touches the window: no `pendingWindow`, no scene rebuild, no
--- request. The next draw measures rows from the new line height and the
--- editor's own `ensure_visible` keeps the caret on screen.
function Layout.cycleFont()
  Layout.setFont(Layout.font % #Layout.FONT_STEPS + 1)
  return Layout.font
end

function Layout.setFont(step)
  step = math.floor(tonumber(step) or 1)
  if not Layout.FONT_STEPS[step] then return end
  Layout.font = step
  Layout.save()
end

--- The multiplier for the current step.
function Layout.fontScale()
  return Layout.FONT_STEPS[Layout.font] or 1
end

--- "2/4", for the button that has to say which state it is in.
function Layout.fontLabel()
  return ("%d/%d"):format(Layout.font, #Layout.FONT_STEPS)
end

--- The size to draw **code** at: the authored size times the player's step.
---
--- **One function, called by both editors and by everything that prints a
--- program's output.** `src/scenes/quest.lua` and `src/scenes/playground.lua`
--- each derived this expression themselves, which is how the two panes would
--- have drifted the first time one of them was tuned.
---
--- `growth()` is in here, and that is not the old `uiScale()` mistake come
--- back: that one *drew* a pixel face at 1.5, which resamples every glyph.
--- This asks for a bigger size, and `Assets.snap8` rounds what comes out
--- onto the 8-pixel grid, so the face is still drawn at 16, 24, 32 or 48.
function Layout.codeSize(base)
  return math.max(8, math.floor((base or 18) * Layout.fontScale() * Layout.growth()))
end

--- The largest code size at or below the player's step that still leaves
--- `rows` lines in a pane `height` tall.
---
--- **A type step is a preference; one line of code is not a code pane.** At
--- step 4 the line height is 45 px, and a landscape window 562 tall has, after
--- its header, footer, control strip and output pane, room for exactly one of
--- them — which `math.max(1, …)` then presents as a working editor showing a
--- single line. This is `UI.fitSize` for code: the same rule that shrinks a
--- label until it fits its button, applied to the one box where the text
--- cannot be allowed to win.
---
--- It only ever shrinks, and never below `floor`, so a window too small for
--- even that is left saying so rather than quietly drawing nothing.
function Layout.codeSizeFor(base, height, rows, floor_px)
  local want = Layout.codeSize(base)
  local least = floor_px or 12
  rows = rows or 3
  if not height or height <= 0 then return want end
  local size = want
  while size > least do
    -- The rasteriser's line height is what decides this, not the nominal
    -- size: the two differ by the face's own leading.
    local lh = require("src.assets").mono(size):getHeight()
    if math.floor(height / lh) >= rows then break end
    size = size - 1
  end
  return math.max(least, size)
end

--- The size to draw **interface** type at.
---
--- The authored size, doubled (`TEXT_BASE`) and taken through the player's
--- step. Everything in `src/ui.lua` goes through this — `text`, `textWidth`,
--- `wrap` and `button` — because a paragraph measured at one size and drawn
--- at another wraps wrong in a way nothing notices until a sentence is cut in
--- half.
---
--- And `growth()`, for the same reason as `codeSize`: the canvas stretches,
--- so a bigger window shows more, but a canvas bigger than the design in
--- *both* directions also gets type to match, rather than the same amount of
--- it drawn smaller. In landscape `growth()` is 1 and this is just the
--- authored size, doubled, times the step.
function Layout.ui(size)
  return math.max(8, math.floor((size or 10) * Layout.TEXT_BASE * Layout.fontScale() * Layout.growth()))
end

--- How much bigger than the design the canvas is, **as a factor on type**.
---
--- In portrait, `uiScale()`: 1 on anything up to the design size, and up to
--- `MAX_STRETCH` on a canvas that really is bigger in both directions, like
--- the 1080×1920 portrait panel `DEFAULT_FONT` was once raised for.
---
--- A fraction here is safe for the reason a fraction in the *draw* is not:
--- what comes out of `Layout.ui` and `codeSize` is a size to ask a face
--- for, and `Assets.snap8` rounds it onto the 8-pixel grid before any glyph
--- is rasterised. The face is drawn at a size it has; it is never scaled.
---
--- **Landscape is always 1.** The web multiplies by `uiScale` in both
--- orientations, and this did too, for one round: on a 1920×1080 fullscreen
--- `uiScale` is 1.5, so an authored 10 was 30 → 32 px — the old step 2's
--- type reached by another road — and the report came straight back: "ui
--- fonts seems too large". A wider landscape canvas is for *more* of the
--- screen, the map and the code and the output, not for bigger furniture
--- round the same amount. A capped growth (say 1.15, still snapping a 10 to
--- 24) was considered and is not worth having: it moves a few sizes on the
--- 8-pixel grid and none of them in a way anybody asked for.
---
--- Portrait keeps it, because a portrait canvas half again as tall as the
--- design is exactly the 1080×1920 case `DEFAULT_FONT` describes, where a
--- 24 px label was a sliver of the frame.
function Layout.growth()
  if Layout.mode ~= "portrait" then return 1 end
  return Layout.uiScale()
end

--- The old two-way toggle, kept because the drive scripts and the tests ask
--- for a specific orientation by name rather than by counting presses.
function Layout.toggleOrientation()
  Layout.setOrientation(Layout.mode == "landscape" and "portrait" or "landscape", true)
end

--- `pin` defaults to true: anything that names an orientation is a choice.
--- `updateViewport` passes false when it is only inferring one.
function Layout.setOrientation(mode, pin)
  if mode ~= "portrait" and mode ~= "landscape" then return end
  if pin ~= false then Layout.pinned = true end
  if Layout.mode == mode then
    Layout.save()
    return
  end
  Layout.mode = mode
  Layout.pendingWindow = true
  Layout.save()
  if Layout.on_change then Layout.on_change(mode) end
end

--- Hand the orientation back to the window's shape.
function Layout.unpinOrientation()
  Layout.pinned = false
  Layout.save()
  -- Re-derive immediately rather than waiting for the next resize, so the
  -- press has a visible effect.
  local want = Layout.orientationFor(love.graphics.getDimensions())
  if want ~= Layout.mode then
    Layout.mode = want
    Layout.pendingWindow = true
    if Layout.on_change then Layout.on_change(want) end
  end
  Layout.updateViewport()
end

--- A one-word description of the orientation state, for the footer.
function Layout.orientationLabel()
  if not Layout.pinned then return "auto" end
  return Layout.mode
end

local function baseSize()
  if Layout.mode == "portrait" then
    return Theme.portW, Theme.portH
  end
  return Theme.landW, Theme.landH
end

Layout.baseSize = baseSize

function Layout.ensureCanvas()
  local w, h = math.max(1, math.floor(Layout.vw)), math.max(1, math.floor(Layout.vh))
  if not (Layout.canvas and Layout.canvas:getWidth() == w and Layout.canvas:getHeight() == h) then
    if Layout.canvas then
      Layout.canvas:release()
    end
    Layout.canvas = love.graphics.newCanvas(w, h)
  end
  -- Nearest at an integer scale, which is what keeps the pixels pixels.
  -- Under `SHRINK_FLOOR` the scale is a fraction, and nearest then throws
  -- rows away; linear blurs them instead, which is the lesser loss. Set on
  -- every pass, not only on a new canvas: the scale can change under a
  -- canvas that stays the same size.
  local filter = Layout.scale >= 1 and "nearest" or "linear"
  Layout.canvas:setFilter(filter, filter)
end

function Layout.updateViewport()
  local ww, wh = love.graphics.getDimensions()
  if ww < 1 then ww = Theme.landW end
  if wh < 1 then wh = Theme.landH end

  -- Not pinned? The window's shape decides, every time it changes — which
  -- includes the fullscreen transition, where the shape stops being one this
  -- program chose.
  if not Layout.pinned then
    local want = Layout.orientationFor(ww, wh)
    if want ~= Layout.mode then
      Layout.mode = want
      if Layout.on_change then Layout.on_change(want) end
    end
  end

  local bw, bh = baseSize()
  local s = math.min(ww / bw, wh / bh)
  if s >= 2 then
    Layout.scale = math.floor(s)
  elseif s >= SHRINK_FLOOR then
    -- Fill the window: grow the virtual canvas along the longer axis instead
    -- of letterboxing (a landscape layout on a portrait screen, a tall
    -- window) — and, **a little under 1×, show less rather than shrink.**
    --
    -- A landscape window on a 1080×1920 panel is 1000 wide against a 1280
    -- design, `s` is 0.84, and the canvas used to be drawn at 0.84 through a
    -- nearest filter: every fifth column and row of it dropped, which on a
    -- one-pixel Unifont stem is a stroke gone. Korean read as broken type.
    -- At 1× the same window shows a 1000-wide canvas instead, and every
    -- scene already lays itself out from `vw` and `vh`.
    Layout.scale = 1
  else
    Layout.scale = math.max(0.35, s)
  end
  Layout.vw = math.min(math.floor(ww / Layout.scale), math.floor(bw * MAX_STRETCH))
  Layout.vh = math.min(math.floor(wh / Layout.scale), math.floor(bh * MAX_STRETCH))
  Layout.ox = math.floor((ww - Layout.vw * Layout.scale) / 2)
  Layout.oy = math.floor((wh - Layout.vh * Layout.scale) / 2)
  Layout.ensureCanvas()
end

--- **Do not draw type at this.** It is the honest answer to "how much bigger
--- than the authored design is this canvas", which the measurement in
--- `docs/decisions.md` is expressed in — but it is a *fraction* (1.5 at
--- 1080×1920), and drawing a pixel face scaled by a fraction is the whole of
--- the bug this client was once reported for: the glyphs are resampled, so
--- the type reads soft, and soft reads as smaller still.
---
--- Type goes through `Layout.ui` and `Layout.codeSize`, which *ask* for a
--- size this much bigger (`Layout.growth`) and let `Assets.snap8` round it
--- onto the 8-pixel grid both faces are drawn on, so every size asked for is
--- a size the face actually has.
---
--- It is still right for **art**. `src/scenes/map.lua` scales its node
--- markers and Mei by it, because a drawn picture resamples cleanly and a
--- marker on a canvas half again as tall should be half again as big. The
--- rule is about glyphs, not about everything.
function Layout.uiScale()
  local bw, bh = baseSize()
  return math.max(1, math.min(Layout.vw / bw, Layout.vh / bh))
end

function Layout.init(preferred)
  local dw, dh = love.window.getDesktopDimensions()
  -- First run: infer from the display, and do **not** call it a pin. A
  -- rotated monitor should open the game in portrait; a player who then
  -- moves it to a landscape screen should get landscape back, not a
  -- decision this program made once and then defended forever.
  Layout.mode = Layout.orientationFor(dw, dh)
  Layout.pinned = false

  Layout.load()

  -- `CWBH_ORIENT` is somebody asking, in as many words, so it pins.
  if preferred == "portrait" or preferred == "landscape" then
    Layout.mode = preferred
    Layout.pinned = true
  end

  Layout.updateViewport()
  Layout.applyWindow()
end

function Layout.begin()
  Layout.updateViewport()
  -- `stencil = true` so a scene can mask: the map's iris (`src/scenes/map.lua`)
  -- draws everything *outside* a shrinking circle, and a canvas bound without
  -- a stencil buffer raises the moment it tries. Costs a depth/stencil
  -- attachment on one canvas and nothing else.
  love.graphics.setCanvas({ Layout.canvas, stencil = true })
  love.graphics.clear(Theme.void)
end

function Layout.finish()
  love.graphics.setCanvas()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.clear(0, 0, 0, 1)
  local dw = Layout.vw * Layout.scale
  local dh = Layout.vh * Layout.scale
  love.graphics.draw(Layout.canvas, Layout.ox, Layout.oy, 0, Layout.scale, Layout.scale)
  love.graphics.setColor(Theme.coin[1], Theme.coin[2], Theme.coin[3], 0.45)
  love.graphics.setLineWidth(1)
  love.graphics.rectangle("line", Layout.ox - 1, Layout.oy - 1, dw + 2, dh + 2)
  love.graphics.setColor(1, 1, 1, 1)
end

function Layout.toVirtual(sx, sy)
  local vx = (sx - Layout.ox) / Layout.scale
  local vy = (sy - Layout.oy) / Layout.scale
  if vx < 0 or vy < 0 or vx >= Layout.vw or vy >= Layout.vh then
    return nil, nil
  end
  return vx, vy
end

function Layout.hit(x, y, w, h)
  local vx, vy = Layout.toVirtual(love.mouse.getPosition())
  if not vx then return false end
  return vx >= x and vy >= y and vx < x + w and vy < y + h
end

function Layout.isPortrait()
  return Layout.mode == "portrait"
end

--- A padded rectangle covering the whole virtual canvas — the one every
--- scene builds its layout from, so nothing has to know which orientation it
--- is in to place a panel.
function Layout.safe(pad)
  pad = pad or 16
  return pad, pad, Layout.vw - pad * 2, Layout.vh - pad * 2
end

--- The widest a screen lays its content out at. Past this the canvas is
--- wider than the design (a 1920 fullscreen is a 1920 canvas), and a card
--- stretched to 1900 px hugs the top-left of a sea of felt; bounded, the
--- content keeps its authored proportions and sits in the middle.
Layout.MAX_CONTENT_W = Theme.maxContentW

--- The screen gutter: 24 in landscape, 16 upright (the spec's §1.3).
function Layout.gutter()
  return Layout.mode == "portrait" and Theme.space.lg or Theme.space.xl
end

--- A content rect no wider than `maxw` (default `MAX_CONTENT_W`), centred
--- across the canvas, inset by the gutter, and — unless `top`/`bottom` say
--- otherwise — running from the header band to the footer band. Returns
--- `x, y, w, h`.
function Layout.bounded(maxw, top, bottom)
  local g = Layout.gutter()
  local w = math.min(maxw or Layout.MAX_CONTENT_W, Layout.vw - g * 2)
  local x = math.floor((Layout.vw - w) / 2)
  local y = top or g
  local b = bottom or (Layout.vh - g)
  return x, y, w, math.max(0, b - y)
end

return Layout
