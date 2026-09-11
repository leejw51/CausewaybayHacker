-- STORY. The opening: `docs/story.md` §2, in its own sentences, over the
-- seven paintings that were generated for exactly this, typed a character at
-- a time.
--
-- Ported from the browser client's `frontend/src/scenes/story.ts`. Its three
-- rules are this screen's three rules:
--
--   * **It must never stand between a returning player and their work.** Any
--     key, any click, at any point, goes straight to the login screen. The
--     skip is the first thing `keypressed` and `mousepressed` do, and it is
--     real: there is no beat during which the input is swallowed, because
--     there is no state in here that has to finish.
--   * **It does not spoil the map.** §2 only. The two lands, the mascots, the
--     bosses and the ending are §3 and later and none of it is here. This is
--     the loss and the reason, which is what an opening is for.
--   * **It ends, and it ends at the logo.** It is not a loop. It plays once,
--     from the title card, when `Store.story_seen()` says it never has;
--     `STORY` on the login screen replays it on purpose.
--
-- ## Seven panels, not the browser's eight
--
-- The browser gives the SKYNET sentences a panel of their own over
-- `bg_datacentre`. This client does not, for two reasons:
--
--   * `bg_datacentre` is **where the ending happens** (`docs/story.md` §6 —
--     the rack in the basement of the Chow Yei Ching Building). Showing it in
--     the first two minutes spends the one room the last screen has.
--   * The brief's seven paintings are the opening's own art, and the SKYNET
--     lines are *about* the street the `open_tills` panel is looking down.
--
-- So the tills panel turns cold halfway through instead: `cold_from` is the
-- line the type changes colour on, the panel's spine goes cyan with it, and
-- the sting fires on that character. The beat is still the beat; it is one
-- shot instead of two.
--
-- ## The caption box grows upward from a fixed foot
--
-- Every one of the fourteen `open_*` panels was composed with its **lower
-- fifth left quiet** — plain floor, plain ground, plain shadow — so a caption
-- has somewhere to live in both orientations without covering the picture. A
-- box measured down from a fraction of the height drifts out of that band as
-- the canvas grows; a box that grows upward from a fixed foot stays in it.
-- The foot is measured off `UI.footerHeight()`, so the panel cannot end up
-- underneath the status strip at the larger type steps.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Store = require("src.store")
local Ease = require("src.ease")

local Story = {}
Story.__index = Story

--- Characters a second. Fast enough to read with, slow enough to be typing.
local CPS = 46
--- How long a cut takes.
local CUT = 0.62
--- How long the logo card is held at the end before the login screen.
local LOGO_HOLD = 2.6

--- The opening, from `docs/story.md` §2 and in its order.
---
--- The English is the bible's own sentences, split where it had already
--- punctuated them — the voice is the asset and it is not paraphrased on the
--- way to the screen. `src/lang/*.lua` carry the other five, translated from
--- these and held to the same rule: a person telling you what happened, not
--- marketing copy.
local function beats()
  return {
    {
      bg = "open_flat", cut = "fade", hold = 1.4,
      lines = {
        I18n.t("TUESDAY, 06:40."),
        I18n.t("Mei opens the editor above Jardine's Bazaar to fix one function."),
      },
    },
    {
      bg = "open_cursor", cut = "fade", hold = 1.5,
      lines = {
        I18n.t("The cursor sits there."),
        I18n.t("She knows what the function has to do. She cannot write the for."),
      },
    },
    {
      -- The one the designer was proudest of: a laptop screen with the grey
      -- text doing the work and no legible code anywhere, deliberately.
      bg = "open_ghost", cut = "fade", hold = 1.7,
      lines = {
        I18n.t("She types three characters."),
        I18n.t("Grey text finishes the line for her, correctly, and she accepts it."),
      },
    },
    {
      bg = "open_face", cut = "fade", hold = 1.9,
      lines = {
        I18n.t("That is when she understands: she has done that every day for two years."),
        I18n.t("The skill did not decay. It was taken — one accepted suggestion at a "
          .. "time, by something patient enough to spend two years on it."),
      },
    },
    {
      bg = "open_tills", cut = "iris", hold = 1.9, cold_from = 3,
      lines = {
        I18n.t("Downstairs the shutters are going up on Jardine's Bazaar, and every "
          .. "till on the street is showing the same thing:"),
        I18n.t("a panel of grey suggested text, and no working code underneath it."),
        I18n.t("SKYNET did not need to be smarter than anyone."),
        I18n.t("It needed people to stop reading their own screens."),
        I18n.t("It had been paying for that since the first free tier."),
      },
    },
    {
      bg = "open_stairs", cut = "iris", hold = 1.6,
      lines = {
        I18n.t("Mei does not have a plan."),
        I18n.t("She has a laptop, a street she knows, and the suspicion that whatever "
          .. "she can still write from memory is hers to keep."),
      },
    },
    {
      bg = "open_lands", cut = "fade", hold = 1.8,
      lines = { I18n.t("She starts with println!.") },
    },
  }
end

Story.BEATS = 7

function Story.new(app)
  return setmetatable({
    app = app,
    i = 1,
    t = 0,
    beat_t = 0,
    typed = 0,
    finished_at = -1,
    stung = false,
    ticked = 0,
    leaving = false,
    replay = false,
  }, Story)
end

function Story:enter(params)
  -- `replay` is true when the player asked for it from the login screen. It
  -- changes nothing about what is shown — only the report, and the fact that
  -- a replay is not the first time, so the flag is already set.
  self.replay = (params or {}).replay == true
  self.list = beats()
end

--- Out, now, whatever is on screen.
---
--- Watched or skipped, it has had its chance: the title card hands a second
--- visit straight to the login screen rather than offering the opening again.
--- **Skipping counts on purpose** — somebody who pressed a key to get out of
--- it is exactly the person who must not be shown it twice.
function Story:out()
  if self.leaving then return end
  self.leaving = true
  Store.set_story_seen()
  self.app:go(self.app.session.authed and "lands" or "login")
end

function Story:beat()
  return self.list and self.list[self.i] or nil
end

--- The beat's text, wrapped to the panel, as one flat list of lines, each
--- carrying the colour it is set in and its own **characters**.
---
--- Characters, not bytes, and that is not a detail:
---
---   * a slice taken at a byte lands in the middle of a UTF-8 sequence, and
---     `love.graphics.print` on a half a character raises *UTF-8 decoding
---     error: Not enough space* and takes the frame with it. It did — on the
---     English beat, at the em dash in "It was taken — one accepted
---     suggestion at a time";
---   * and a beat typed at forty-six *bytes* a second types Korean and
---     Japanese three times slower than English, because those are three
---     bytes a glyph. Counting glyphs makes the sequence the same length in
---     every language it is told in.
function Story:lines_for(beat)
  local _, _, inner = self:panel_rect(true)
  local out = {}
  for index, line in ipairs(beat.lines) do
    local cold = beat.cold_from ~= nil and index >= beat.cold_from
    for _, wrapped in ipairs(UI.wrap(line, inner, 8)) do
      local chars = UI.chars(wrapped)
      out[#out + 1] = { text = wrapped, chars = chars, n = #chars, cold = cold }
    end
  end
  return out
end

--- How many characters this beat types in total, and how many of them are
--- typed before the cold half starts.
function Story:beat_length(beat)
  local total, warm = 0, nil
  for _, line in ipairs(self:lines_for(beat)) do
    if line.cold and not warm then warm = total end
    total = total + line.n + 1
  end
  return total, warm
end

function Story:update(dt)
  self.t = self.t + dt
  self.beat_t = self.beat_t + dt
  local beat = self:beat()
  if not beat then
    -- The logo is the end of the sequence, not a new loop of it. When it has
    -- been up long enough the screen simply hands over.
    if self.beat_t > LOGO_HOLD + CUT then self:out() end
    return
  end
  if self.beat_t < CUT then return end

  local total, warm = self:beat_length(beat)
  local before = math.floor(self.typed)
  self.typed = math.min(total, self.typed + dt * CPS)
  local now = math.floor(self.typed)

  -- The sting lands on the character the type turns cold on, which is the
  -- moment the beat changes its mind about what it is describing.
  if warm and not self.stung and now > warm then
    self.stung = true
    SFX.play("stamp")
  end
  -- Every fourth character, not every character: a key click per glyph at
  -- forty-six a second is a buzz, not typing.
  if now > before and now - self.ticked >= 4 then
    self.ticked = now
    SFX.play("type")
  end

  if self.typed >= total then
    if self.finished_at < 0 then self.finished_at = self.beat_t end
    if self.beat_t > self.finished_at + beat.hold then self:next() end
  end
end

function Story:next()
  self.i = self.i + 1
  self.beat_t = 0
  self.typed = 0
  self.finished_at = -1
  self.stung = false
  self.ticked = 0
end

--- How far apart two lines of the caption sit.
---
--- `UI.lineHeight(8)` on its own is 16 px at the first type step, which is
--- exactly the height of the glyphs — so two lines of prose touch. Four
--- pixels of leading is the difference between a paragraph and a wall.
function Story.leading()
  return UI.lineHeight(8) + 4
end

--- The caption box: x, y, inner width, height. `measuring` skips the line
--- count, which is what `lines_for` needs to avoid asking itself.
function Story:panel_rect(measuring)
  local vw, vh = Layout.vw, Layout.vh
  local w = math.min(vw - 40, 980)
  local x = math.floor((vw - w) / 2)
  local inner = w - 28
  if measuring then return x, 0, inner, 0 end
  local beat = self:beat()
  local rows = beat and #self:lines_for(beat) or 0
  local h = math.max(56, rows * Story.leading() + 26)
  -- Above the status strip, whatever the type step has done to its height.
  local foot = vh - UI.footerHeight() - 26
  return x, foot - h, inner, h, w
end

-- ------------------------------------------------------------------ drawing

function Story:bg_name(name)
  if Layout.isPortrait() then return name .. "_p" end
  return name
end

function Story:draw()
  local vw, vh = Layout.vw, Layout.vh
  local beat = self:beat()
  local prev = self.i > 1 and self.list[self.i - 1] or nil
  local cut = math.min(1, self.beat_t / CUT)

  if beat then
    -- The outgoing painting stays until the incoming one has covered it, so
    -- there is never a frame of nothing between two beats.
    if prev and cut < 1 then Assets.cover(self:bg_name(prev.bg), 0, 0, vw, vh) end
    if beat.cut == "iris" and cut < 1 then
      -- A stencil rather than a shader, the same call the map's iris makes:
      -- a shader is another thing to fail on somebody's driver.
      local reach = math.sqrt(vw * vw + vh * vh) * 0.62
      local r = reach * Ease.cosine(cut)
      love.graphics.stencil(function()
        love.graphics.circle("fill", vw / 2, vh * 0.42, r, 64)
      end, "replace", 1)
      love.graphics.setStencilTest("equal", 1)
      Assets.cover(self:bg_name(beat.bg), 0, 0, vw, vh)
      love.graphics.setStencilTest()
      if r > 2 then
        UI.setColor(Theme.coin, 0.4)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", vw / 2, vh * 0.42, r, 64)
        love.graphics.setColor(1, 1, 1, 1)
      end
    else
      Assets.cover(self:bg_name(beat.bg), 0, 0, vw, vh,
        nil, beat.cut == "fade" and Ease.cosineOut(cut) or 1)
    end
  else
    Assets.cover(Layout.isPortrait() and "title_bg_p" or "title_bg", 0, 0, vw, vh)
    UI.setColor(Theme.void, 0.6)
    love.graphics.rectangle("fill", 0, 0, vw, vh)
    love.graphics.setColor(1, 1, 1, 1)
  end

  -- A veil into the lower half, so type over a bright morning street is type
  -- on something rather than type in front of something. A light one: the
  -- panels were composed with a quiet lower fifth, so it only has to take the
  -- edge off — anything heavier and the art made for this sequence is behind
  -- a curtain.
  local band = math.floor(vh * 0.58)
  local steps = 28
  local top = vh - band
  for i = 0, steps - 1 do
    -- Banded rather than smooth: LÖVE has no gradient primitive, and
    -- twenty-eight steps over pixel art is a gradient. The curve is steep at
    -- the bottom and nearly nothing at the top, so the first band cannot be
    -- seen arriving — a veil whose leading edge is a visible line across the
    -- painting is worse than no veil.
    UI.setColor(Theme.void, 0.72 * ((i + 1) / steps) ^ 2.2)
    love.graphics.rectangle("fill", 0, top + band * i / steps,
      vw, math.ceil(band / steps) + 1)
  end
  love.graphics.setColor(1, 1, 1, 1)

  if beat then
    self:draw_panel(beat, cut)
  else
    self:draw_logo()
  end
  self:draw_pips()

  self.app:footer(I18n.t("ANY KEY  SKIP"))
end

function Story:draw_panel(beat, cut)
  local x, y, inner, h, w = self:panel_rect()
  local lines = self:lines_for(beat)
  local lh = Story.leading()
  -- The plate arrives with the cut rather than after it, so the beat is one
  -- movement instead of a picture and then a box.
  local k = Ease.cosineOut(cut)

  love.graphics.push()
  love.graphics.translate(0, (1 - k) * 18)
  UI.setColor(Theme.ink, 0.82 * k)
  love.graphics.rectangle("fill", x, y, w, h)
  -- The spine says which half of the beat is speaking: gold while it is the
  -- street, cyan once it is the thing that took the street.
  local cold = beat.cold_from ~= nil and self.stung
  UI.setColor(cold and Theme.cyan or Theme.coin, k)
  love.graphics.rectangle("fill", x, y, 4, h)
  love.graphics.setColor(1, 1, 1, 1)

  local left = math.floor(self.typed)
  local ly = y + 13
  for _, line in ipairs(lines) do
    local take = math.max(0, math.min(line.n, left))
    -- Whole characters only — see `lines_for`.
    local shown = take > 0 and table.concat(line.chars, "", 1, take) or ""
    left = left - line.n - 1
    local colour = line.cold and Theme.cyan or Theme.cream
    if shown ~= "" then
      UI.text(shown, x + 14, ly, 8, Theme.withAlpha(colour, k))
    end
    -- The caret sits at the end of whatever is being typed right now, and
    -- blinks on the beat clock — never on `os.time()`, or a captured frame
    -- would differ from run to run.
    if take > 0 and take < line.n and math.floor(self.beat_t * 3) % 2 == 0 then
      UI.setColor(colour, k)
      love.graphics.rectangle("fill", x + 14 + UI.textWidth(shown, 8), ly + 2,
        7, UI.lineHeight(8) - 4)
      love.graphics.setColor(1, 1, 1, 1)
    end
    ly = ly + lh
  end
  love.graphics.pop()
end

function Story:draw_logo()
  local vw, vh = Layout.vw, Layout.vh
  local k = Ease.cosineOut(math.min(1, self.beat_t / CUT))
  local title = 28
  while title > 8 and UI.textWidth("CAUSEWAYBAY", title) > vw - 40 do title = title - 4 end
  local line = UI.lineHeight(title)
  local y = vh * 0.32 + (1 - k) * 20
  UI.text(I18n.t("CAUSEWAYBAY"), 0, y, title, Theme.withAlpha(Theme.coin, k), "center", vw)
  UI.text(I18n.t("HACKER"), 0, y + line * 1.4, title,
    Theme.withAlpha(Theme.land.rust, k), "center", vw)
  local pulse = 0.45 + 0.55 * Ease.cosine((self.t * 1.4) % 1)
  UI.text(I18n.t("PRESS ANY KEY"), 0, vh * 0.58, 10,
    Theme.withAlpha(Theme.coin, pulse), "center", vw)
end

--- Where you are in seven beats. A sequence with no visible end is a sequence
--- people skip on principle.
function Story:draw_pips()
  local vw, vh = Layout.vw, Layout.vh
  local total = Story.BEATS + 1
  local pw, gap = 10, 6
  local x = math.floor((vw - (total * pw + (total - 1) * gap)) / 2)
  local y = vh - UI.footerHeight() - 14
  for i = 1, total do
    UI.setColor(i == self.i and Theme.coin or Theme.withAlpha(Theme.dim, 0.7))
    love.graphics.rectangle("fill", x + (i - 1) * (pw + gap), y, pw, 4)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

-- -------------------------------------------------------------------- input

function Story:keypressed()
  self:out()
  return true
end

function Story:mousepressed()
  self:out()
end

return Story
