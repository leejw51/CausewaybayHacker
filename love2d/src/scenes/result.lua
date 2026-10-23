-- RESULT. One `Attempt` (§5.4), rendered.
--
-- Every number on this screen is the server's. The verdict, the star count,
-- whether `cleared` is true — none of it is recomputed here, and `cleared`
-- means "did this submission just clear the node", not "is the node cleared"
-- (§5.4), so a re-solve says ALREADY CLEARED rather than stamping twice.
--
-- The mistakes list is the point of the whole game (SPEC §7): the compiler's
-- own error identity, kept, so `stats.mistakes` has something to count.
--
-- ## The screen (docs/love2d-ui.md, the spec's §3.7)
--
-- One content-sized card, centred in the bounded width and in the height:
-- the verdict in the display role (on the ribbon art for a win), the quest's
-- title, three stars that pop in one by one, the XP counting up with the
-- level bar filling after it, one line of figures, the line that was picked
-- in a code well, and NEXT / RETRY / MAP as primary / secondary / ghost. A
-- failed verdict wears a red rule and opens WHAT WENT WRONG and the failing
-- case in place. The attempt id and the rest of the cases are behind
-- DETAILS. Confetti rains from the card's top edge on a clear.
--
-- Every entrance is `Juice` keyed state, forgotten on `enter`, so it does
-- not depend on a wall-clock delta that a fullscreen round trip or a frozen
-- animation clock can leave behind (the QA run saw the old banner stuck off
-- the top once).

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local Anim = require("src.anim")
local Clock = require("src.clock")
local Juice = require("src.juice")
local Fx = require("src.fx")
local SFX = require("src.sfx")

local Result = {}
Result.__index = Result

local VERDICT_LABEL = {
  accepted = "ACCEPTED",
  wrong_answer = "WRONG ANSWER",
  compile_error = "COMPILE ERROR",
  runtime_error = "RUNTIME ERROR",
  timeout = "TIMEOUT",
  output_limit = "OUTPUT LIMIT",
  internal_error = "INTERNAL ERROR",
}

--- When each star pops, seconds after the card lands, and the gap between.
Result.STAR_AT = 0.3
Result.STAR_GAP = 0.14

function Result.new(app)
  return setmetatable({ app = app, t = 0, scroll = 0, details = false, header_h = 0,
    buttons = {}, star_heard = {} }, Result)
end

function Result:enter(params)
  self.attempt = params.attempt or self.app.last_attempt
  -- §4.9 / §5.1b: the grant, the total, the level, and whether it is new.
  self.xp = params.xp
  self.quest = params.quest
  self.log = params.log
  self.source = params.source
  self.t = 0
  self.scroll = 0
  self.details = false
  self.hover = nil
  self.started = Anim.now()
  -- The clear's light: planned on the frame the card lands, so the fanfare
  -- never plays before the thing it celebrates arrives.
  self.fx_at = nil
  self.star_heard = {}
  self.next_id = nil
  -- No toast on the verdict: the CLEARED award used to land on the buttons.
  UI.clearToasts()
  Juice.forget("result:")
  Juice.counter("result:xp", 0)
  self:find_next()
end

--- Which node comes after this one, so NEXT has somewhere to go.
---
--- Asked of the server rather than remembered from the map: `world.map` is
--- what the map screen itself draws from, and the node after this one is a
--- fact about the pack, not about which screen the player came through. The
--- next node by number; the last node of a map has no NEXT and the button
--- says so by not being there.
function Result:find_next()
  local id = self.attempt and self.attempt.quest_id or self.app.quest_id
  local land, category = self.app.land, self.app.category
  if not id or not land or not category or not self.app.session then return end
  self.app.session:request("world.map",
    { land = land, category = category, locale = I18n.lang },
    function(ok, payload)
      if not ok or not payload or not payload.nodes then return end
      local nodes = {}
      for _, node in ipairs(payload.nodes) do nodes[#nodes + 1] = node end
      table.sort(nodes, function(a, b) return (a.node or 0) < (b.node or 0) end)
      for i, node in ipairs(nodes) do
        if node.quest_id == id then
          self.next_id = nodes[i + 1] and nodes[i + 1].quest_id or nil
          return
        end
      end
    end)
end

--- The three ways off this screen, in order, each with its key and its
--- variant — NEXT / MAP / RETRY as primary / secondary / ghost after an
--- acceptance with somewhere to go (the next quest is the forward action);
--- RETRY / MAP / NEXT otherwise. NEXT is absent on the last node.
---
--- Pure, so a test can hold the rule without a window.
function Result.button_specs(accepted, has_next)
  local out = {}
  local next_ = { id = "next", label = "NEXT", key = "N" }
  local retry = { id = "retry", label = "RETRY", key = "ENTER" }
  local map = { id = "map", label = "MAP", key = "ESC", variant = "secondary" }
  if accepted and has_next then
    next_.variant, retry.variant = "primary", "ghost"
    out[1], out[2], out[3] = next_, map, retry
  else
    retry.variant, next_.variant = "primary", "ghost"
    out[1], out[2] = retry, map
    if has_next then out[3] = next_ end
  end
  return out
end

--- Kept for callers: the specs above, as rows of one.
function Result:button_rows(width, accepted)
  local rows = {}
  for _, b in ipairs(Result.button_specs(accepted, self.next_id ~= nil)) do
    rows[#rows + 1] = { b }
  end
  return rows
end

--- RETRY: the same quest again.
function Result:retry()
  self.app:go("quest", { quest_id = self.attempt and self.attempt.quest_id or self.app.quest_id })
end

--- NEXT: the node after this one, straight into its card.
function Result:next_quest()
  if not self.next_id then return end
  self.app:go("quest", { quest_id = self.next_id })
end

--- Seconds since this verdict arrived.
function Result:age()
  return Anim.now() - (self.started or Anim.now())
end

function Result:update(dt)
  self.t = self.t + dt
end

--- A gold star, drawn, for a checkout without `fx_star`.
local function star(cx, cy, r, colour, alpha)
  UI.setColor(colour, alpha)
  love.graphics.polygon("fill", cx, cy - r, cx + r / 2.6, cy - r / 3, cx + r, cy - r / 3,
    cx + r / 2.2, cy + r / 5, cx + r / 1.6, cy + r, cx, cy + r / 2,
    cx - r / 1.6, cy + r, cx - r / 2.2, cy + r / 5, cx - r, cy - r / 3, cx - r / 2.6, cy - r / 3)
  love.graphics.setColor(1, 1, 1, 1)
end

--- The source as rows for the well: the picked line, or the first lines
--- of a program. Nil when there is nothing short enough to show.
local function source_rows(source, font, inner)
  if type(source) ~= "string" or source:match("^%s*$") then return nil end
  local Quiz = require("src.quiz")
  local measure = function(s) return font:getWidth(s) end
  local rows = Quiz.code_wrap(source, inner, measure)
  if #rows > 6 then
    local cut = {}
    for i = 1, 5 do cut[i] = rows[i] end
    cut[6] = "⋮"
    rows = cut
  end
  return rows
end

--- The whole card, measured and drawn in one pass per block kind, so the
--- draw and the hit test read one arrangement.
function Result:draw()
  local vw, vh = Layout.vw, Layout.vh
  -- The quest's own plate, dimmed (docs/art.md §5), so the result reads as
  -- the same place rather than a new screen.
  local land = (self.quest and self.quest.land) or self.app.land or "rust"
  Assets.cover(require("src.scenes.quest").backdrop(land,
    (self.quest and self.quest.category) or self.app.category), 0, 0, vw, vh)
  local portrait = Layout.isPortrait()
  UI.setColor(Theme.felt, portrait and 0.84 or 0.78)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local pad = portrait and Theme.space.lg or Theme.space.xl
  local bx, by, bw, bh = UI.bounded(nil, Theme.space.lg, vh - UI.footerHeight() - Theme.space.lg)
  local a = self.attempt
  self.buttons = {}
  if not a then
    local w = math.min(480, bw)
    local x = bx + math.floor((bw - w) / 2)
    local cx, cy, cw = UI.card(x, by + math.floor(bh / 2) - 40, w, pad * 2 + UI.lead("label"), { pad = pad })
    UI.label(I18n.t("no attempt"), cx, cy, "label", { width = cw, align = "center", color = Theme.mute })
    self.app:footer({ { key = "ESC", verb = I18n.t("map") } })
    return
  end

  local accepted = a.verdict == "accepted"
  -- A run should never reach this screen — `src/scenes/quest.lua` keeps them
  -- in place — but if one ever did, it must not be dressed as a verdict.
  local is_run = a.mode == "run"
  local colour = is_run and Theme.blue or (accepted and Theme.green or Theme.redA)
  local word = is_run and "SAMPLE RUN" or (VERDICT_LABEL[a.verdict] or tostring(a.verdict):upper())
  local gained = (self.xp and self.xp.gained) or 0
  local show_stars = accepted and not is_run
  local code_font = Assets.mono(Layout.codeSize(Theme.type.code))
  local code_lh = code_font:getHeight()

  -- The card's width and its blocks, measured.
  local w = math.min(portrait and bw or 640, bw)
  local x = bx + math.floor((bw - w) / 2)
  local cw = w - pad * 2
  local inner_well = cw - Theme.space.sm * 2 - 6
  local blocks = {}
  local function add(kind, h, extra)
    local b = extra or {}
    b.kind, b.h = kind, h
    blocks[#blocks + 1] = b
  end
  add("verdict", UI.lead("display") + (show_stars and Theme.space.sm or 0))
  if self.quest and self.quest.title then add("title", UI.lead("title")) end
  if show_stars then add("stars", 56) end
  if gained > 0 then
    add("xp", UI.lead("display") + Theme.space.sm + 8 + Theme.space.xs + UI.lead("label"))
  elseif accepted and not is_run then
    add("note", UI.readHeight(I18n.t("already cleared — stars keep the best run"), cw))
  end
  add("figures", UI.lead("label") * (Clock.verdict_note(a) and 2 or 1))
  local rows = source_rows(self.source, code_font, inner_well)
  if rows then add("well", #rows * code_lh + Theme.space.sm * 2, { rows = rows }) end
  if not accepted and not is_run then
    if a.mistakes and #a.mistakes > 0 then
      local h = UI.lead("label") + Theme.space.xs
      for _, m in ipairs(a.mistakes) do
        h = h + UI.lead("label") + UI.readHeight(m.message or "", cw, 4) + Theme.space.sm
      end
      add("mistakes", h)
    end
    for _, case in ipairs(a.cases or {}) do
      if case.visible and not case.passed then
        local want = Assets.mono(Layout.codeSize(Theme.type.code))
        local lines = 2 + select(2, tostring(case.expect or ""):gsub("\n", "")) + select(2, tostring(case.got or ""):gsub("\n", ""))
        add("case", UI.lead("label") + Theme.space.xs + math.min(8, lines) * want:getHeight() + Theme.space.sm * 2, { case = case })
        break
      end
    end
  end
  -- DETAILS: the attempt id, every case and the stderr, folded behind a
  -- ghost button sized by the kit (a wide canvas sets it in a bigger face).
  local details_w, details_h = UI.buttonSize(I18n.t("DETAILS"), { h = UI.lead("label") + Theme.space.sm, key = "D" })
  local detail_h = details_h
  if self.details then
    detail_h = detail_h + Theme.space.xs + UI.lead("label")
    for _ in ipairs(a.cases or {}) do detail_h = detail_h + UI.lead("label") end
    if a.stderr and a.stderr ~= "" then
      local n = select(2, (a.stderr .. "\n"):gsub("\n", ""))
      detail_h = detail_h + Theme.space.sm + math.min(12, n) * code_lh + Theme.space.sm * 2
    end
  end
  add("details", detail_h)

  local specs = Result.button_specs(accepted, self.next_id ~= nil)
  local buttons_h = portrait and (Theme.control.buttonL + Theme.rowGap + Theme.control.buttonM) or Theme.control.buttonL
  local content = 0
  for i, b in ipairs(blocks) do content = content + b.h + (i > 1 and Theme.space.lg or 0) end
  local total = content + Theme.space.xl + buttons_h
  local card_h = math.min(total + pad * 2, bh)
  local y = by + math.floor(math.max(0, bh - card_h) / 2)

  -- The card arrives from 24 below with a little overshoot.
  local k = Juice.enter("result:card", { dur = 0.3, ease = "outBack" })
  local alpha = math.min(1, k * 1.5)
  y = y + math.floor((1 - k) * 24)
  local cx, cy = UI.card(x, y, w, card_h, { strip = colour, pad = pad, alpha = alpha })
  self.card = { x = x, y = y, w = w, h = card_h }

  -- The scrolling part: everything above the buttons.
  local room = card_h - pad * 2 - Theme.space.xl - buttons_h
  local overflow = math.max(0, content - room)
  self.scroll = math.max(0, math.min(self.scroll, overflow))
  self.overflow = overflow
  love.graphics.setScissor(x, cy - 2, w, room + 4)
  local ly = cy - self.scroll
  local landed = Juice.entered("result:card")
  for i, b in ipairs(blocks) do
    if i > 1 then ly = ly + Theme.space.lg end
    if b.kind == "verdict" then
      -- A win gets `art/fx_ribbon` behind its word, straddling the card's
      -- top edge; a failure does not — a ribbon round WRONG ANSWER would be
      -- celebrating it. The ribbon is cut to the word.
      local ribbon = show_stars and Assets.image("fx_ribbon")
      local tw = UI.labelWidth(word, "display")
      if ribbon then
        local box = Assets.box.fx_ribbon or { minx = 0, maxx = ribbon:getWidth() - 1 }
        local ink_w = box.maxx - box.minx + 1
        local ink_h = box.miny and (box.maxy - box.miny + 1) or ribbon:getHeight()
        local rw = math.min(w + 32, tw / 0.6 + 48)
        local sx = rw / ink_w
        local sy = math.min(sx, (UI.lead("display") + 28) / ink_h)
        local oy = box.miny and (box.miny + box.maxy + 1) / 2 or ribbon:getHeight() / 2
        love.graphics.setColor(1, 1, 1, alpha)
        love.graphics.draw(ribbon, x + w / 2, ly + UI.lead("display") / 2, 0, sx, sy,
          (box.minx + box.maxx + 1) / 2, oy)
        love.graphics.setColor(1, 1, 1, 1)
      end
      UI.label(word, cx, ly, "display", { width = cw, align = "center", ellipsis = true,
        color = ribbon and Theme.edge or colour, alpha = alpha, shadow = not ribbon })
    elseif b.kind == "title" then
      UI.label(self.quest.title, cx, ly, "title", { width = cw, align = "center", ellipsis = true, alpha = alpha })
    elseif b.kind == "stars" then
      -- Three, popping in one by one once the card has landed, each with a
      -- rising note; the ones not earned stay small and grey.
      local size = 48
      local gap = Theme.space.lg
      local sx0 = cx + math.floor((cw - (3 * size + 2 * gap)) / 2) + size / 2
      for s = 1, 3 do
        local earned = s <= (a.stars or 0)
        local ks = landed and Juice.enter("result:star" .. s,
          { delay = Result.STAR_AT + (s - 1) * Result.STAR_GAP, dur = 0.22, ease = "outBack" }) or 0
        if earned and ks > 0 and not self.star_heard[s] then
          self.star_heard[s] = true
          SFX.play("coin")
          Fx.burst(sx0 + (s - 1) * (size + gap), ly + size / 2 + 4, "stars", { n = 0.5 })
        end
        local scale = earned and ks or 0.6
        local sa = earned and ks or 0.25
        local px, py = sx0 + (s - 1) * (size + gap), ly + size / 2 + 4
        if scale > 0.01 and not Assets.marker("fx_star", px, py, size * scale, { alpha = sa * alpha }) then
          star(px, py, size * scale / 2, Theme.gold, sa * alpha)
        end
      end
    elseif b.kind == "xp" then
      -- "+50 XP" counts up after the stars; the level bar fills after it.
      local ready = landed and (not show_stars or Juice.entered("result:star3"))
      local shown, moving = Juice.counter("result:xp", ready and gained or 0, { dur = Theme.motion.count })
      local label = (a.cleared or not accepted) and I18n.t("+%d XP", shown) or I18n.t("PRACTICE +%d XP", shown)
      local pop = 1 + 0.08 * (moving and 1 or 0)
      love.graphics.push()
      love.graphics.translate(cx + cw / 2, ly + UI.lead("display") / 2)
      love.graphics.scale(pop, pop)
      love.graphics.translate(-(cx + cw / 2), -(ly + UI.lead("display") / 2))
      UI.label(label, cx, ly, "display", { width = cw, align = "center", color = Theme.gold, alpha = alpha * (ready and 1 or 0.35) })
      love.graphics.pop()
      local bar_y = ly + UI.lead("display") + Theme.space.sm
      local user = self.app.session and self.app.session.user
      local frac = (ready and not moving) and require("src.app").xp_fraction(user) or 0
      local fill = Juice.follow("result:bar", frac, { speed = 6 })
      local bar_w = math.min(240, cw)
      UI.bar(cx + math.floor((cw - bar_w) / 2), bar_y, bar_w, 8, fill, Theme.gold)
      local lv = I18n.t("LV %d", (self.xp and self.xp.level) or (user and user.level) or 1)
      if self.xp and self.xp.level_up then lv = I18n.t("LEVEL %d", self.xp.level or 1) end
      UI.label(lv, cx, bar_y + 8 + Theme.space.xs, "label",
        { width = cw, align = "center", color = (self.xp and self.xp.level_up) and Theme.pink or Theme.mute, alpha = alpha })
    elseif b.kind == "note" then
      UI.read(I18n.t("already cleared — stars keep the best run"), cx, ly, cw, { color = Theme.mute, align = "center" })
    elseif b.kind == "figures" then
      UI.label(I18n.t("TESTS %d / %d · COMPILE %dms · RUN %dms", a.tests_passed or 0, a.tests_total or 0,
        a.compile_ms or 0, a.run_ms or 0), cx, ly, "label", { width = cw, align = "center", color = Theme.mute, ellipsis = true, alpha = alpha })
      local timing = Clock.verdict_note(a)
      if timing then
        UI.label(timing, cx, ly + UI.lead("label"), "label",
          { width = cw, align = "center", color = a.within_limit and Theme.green or Theme.gold, ellipsis = true, alpha = alpha })
      end
    elseif b.kind == "well" then
      UI.card(cx, ly, cw, b.h, { variant = "well", pad = 0, alpha = alpha })
      love.graphics.setFont(code_font)
      local ty = ly + Theme.space.sm
      for _, line in ipairs(b.rows) do
        UI.setColor(line == "⋮" and Theme.mute or Theme.text, 0.92 * alpha)
        love.graphics.print(line, cx + Theme.space.sm + 6, ty)
        ty = ty + code_lh
      end
      love.graphics.setColor(1, 1, 1, 1)
    elseif b.kind == "mistakes" then
      local my = ly
      my = my + UI.label(I18n.t("WHAT WENT WRONG"), cx, my, "label", { color = Theme.redA, caps = true }) + Theme.space.xs
      for _, m in ipairs(a.mistakes) do
        local head = ("%s%s%s"):format(m.kind or "", m.code and (" [" .. m.code .. "]") or "",
          m.line and ("  · line " .. tostring(m.line)) or "")
        my = my + UI.label(head, cx, my, "label", { width = cw, ellipsis = true, color = Theme.text })
        my = my + UI.read(m.message or "", cx, my, cw, { maxLines = 4, color = Theme.text }) + Theme.space.sm
      end
    elseif b.kind == "case" then
      local case = b.case
      local my = ly
      my = my + UI.label(("FAIL  %s"):format(tostring(case.name or "")), cx, my, "label", { color = Theme.redA, width = cw, ellipsis = true }) + Theme.space.xs
      local lines = {}
      for _, pair in ipairs({ { "want", case.expect }, { "got ", case.got } }) do
        for line in (tostring(pair[2] or "") .. "\n"):gmatch("(.-)\n") do
          lines[#lines + 1] = { pair[1], line }
        end
      end
      local wh = math.min(8, #lines) * code_lh + Theme.space.sm * 2
      UI.card(cx, my, cw, wh, { variant = "well", pad = 0 })
      love.graphics.setFont(code_font)
      local ty = my + Theme.space.sm
      for i = 1, math.min(8, #lines) do
        UI.setColor(lines[i][1] == "want" and Theme.green or Theme.redA, 0.9)
        love.graphics.print(lines[i][1], cx + Theme.space.sm + 6, ty)
        UI.setColor(Theme.text, 0.92)
        love.graphics.print(lines[i][2], cx + Theme.space.sm + 6 + code_font:getWidth("want  "), ty)
        ty = ty + code_lh
      end
      love.graphics.setColor(1, 1, 1, 1)
    elseif b.kind == "details" then
      -- The fold: a ghost button with the id and the cases behind it.
      local dw, dh = details_w, details_h
      local r = { x = cx + math.floor((cw - dw) / 2), y = ly, w = dw, h = dh }
      UI.button(r.x, r.y, r.w, r.h, I18n.t("DETAILS"), self.hover == "details" and "hot" or "normal", nil,
        { variant = "ghost", id = "result:details", key = "D", lift = 0, alpha = alpha })
      self.buttons[#self.buttons + 1] = { id = "details", x = r.x, y = r.y, w = r.w, h = r.h,
        act = function() self.details = not self.details end }
      if self.details then
        local dy = ly + dh + Theme.space.xs
        dy = dy + UI.label(tostring(a.id or ""), cx, dy, "label", { width = cw, ellipsis = true, color = Theme.mute })
        for _, case in ipairs(a.cases or {}) do
          dy = dy + UI.label(("%s  %s%s"):format(case.passed and "PASS" or "FAIL", tostring(case.name or ""),
            case.visible and "" or "  (hidden)"), cx, dy, "label",
            { width = cw, ellipsis = true, color = case.passed and Theme.green or Theme.redA })
        end
        if a.stderr and a.stderr ~= "" then
          dy = dy + Theme.space.sm
          local n = math.min(12, select(2, (a.stderr .. "\n"):gsub("\n", "")))
          UI.card(cx, dy, cw, n * code_lh + Theme.space.sm * 2, { variant = "well", pad = 0 })
          love.graphics.setFont(code_font)
          UI.setColor(Theme.text, 0.85)
          local ty = dy + Theme.space.sm
          local shown = 0
          for line in (a.stderr .. "\n"):gmatch("(.-)\n") do
            if shown >= n then break end
            love.graphics.print(UI.ellipsizeWith(line, inner_well, code_font), cx + Theme.space.sm + 6, ty)
            ty = ty + code_lh
            shown = shown + 1
          end
          love.graphics.setColor(1, 1, 1, 1)
        end
      end
    end
    ly = ly + b.h
  end
  love.graphics.setScissor()
  if overflow > 0 then
    if self.scroll > 0 then UI.scrollFade(cx, cy, cw, Theme.card, "top") end
    if self.scroll < overflow then UI.scrollFade(cx, cy + room - Theme.space.xl, cw, Theme.card, "bottom") end
    UI.scrollbar(x + w - pad / 2 - 3, cy, room, room / content, self.scroll / overflow)
  end

  -- The buttons, pinned under the scrolling part: centred in landscape;
  -- upright NEXT (or RETRY) takes the width and the other two share a row.
  local byy = cy + room + Theme.space.xl
  local function draw_button(spec, rx, ry, rw, rh)
    local state = self.hover == spec.id and "hot" or "normal"
    UI.button(rx, ry, rw, rh, I18n.t(spec.label), state, nil,
      { variant = spec.variant, id = "result:" .. spec.id, key = spec.key, alpha = alpha })
    self.buttons[#self.buttons + 1] = { id = spec.id, x = rx, y = ry, w = rw, h = rh,
      act = function() self:act(spec.id) end }
  end
  if portrait then
    draw_button(specs[1], cx, byy, cw, Theme.control.buttonL)
    local n = #specs - 1
    if n > 0 then
      local bw2 = math.floor((cw - Theme.rowGap * (n - 1)) / n)
      for i = 2, #specs do
        draw_button(specs[i], cx + (i - 2) * (bw2 + Theme.rowGap), byy + Theme.control.buttonL + Theme.rowGap, bw2, Theme.control.buttonM)
      end
    end
  else
    local widths, total_w = {}, 0
    for i, spec in ipairs(specs) do
      local need_w = UI.buttonSize(I18n.t(spec.label), { h = Theme.control.buttonL, key = spec.key })
      widths[i] = math.max(spec.variant == "primary" and 160 or 120, need_w)
      total_w = total_w + widths[i] + (i > 1 and Theme.rowGap or 0)
    end
    local scale = total_w > cw and cw / total_w or 1
    local rx = cx + math.floor((cw - total_w * scale) / 2)
    for i, spec in ipairs(specs) do
      local bw2 = math.floor(widths[i] * scale)
      draw_button(spec, rx, byy, bw2, Theme.control.buttonL)
      rx = rx + bw2 + Theme.rowGap
    end
  end

  -- The confetti, once, from the card's top edge on a clear.
  if not self.fx_at and landed and show_stars and (a.cleared or gained > 0) then
    self.fx_at = self:age()
    Fx.burst(x + w / 2, y, "confetti", { n = 2, area = { w, 2 } })
    SFX.play("accepted")
  end

  local hints = {}
  for _, spec in ipairs(specs) do
    hints[#hints + 1] = { key = spec.key, verb = I18n.t(spec.id) }
  end
  self.app:footer(hints)
end

--- A button, by id.
function Result:act(id)
  for _, b in ipairs(self.buttons or {}) do
    if b.id == id then UI.press("result:" .. id, b, { sfx = false }) end
  end
  if id == "next" then self:next_quest()
  elseif id == "retry" then self:retry()
  elseif id == "map" then self.app:back()
  elseif id == "details" then self.details = not self.details end
end

function Result:keypressed(key)
  -- ENTER takes the lit button, as the web does: NEXT after an acceptance
  -- with somewhere to go, RETRY otherwise.
  if key == "return" or key == "kpenter" then
    if self.attempt and self.attempt.verdict == "accepted" and self.next_id then
      self:act("next")
    else
      self:act("retry")
    end
    return true
  end
  if key == "n" then self:act("next"); return true end
  if key == "m" then self:act("map"); return true end
  if key == "d" then self:act("details"); return true end
  if key == "up" then self.scroll = math.max(0, self.scroll - 30); return true end
  if key == "down" then self.scroll = self.scroll + 30; return true end
  if key == "pageup" then self.scroll = math.max(0, self.scroll - 200); return true end
  if key == "pagedown" then self.scroll = self.scroll + 200; return true end
  return false
end

function Result:mousemoved(x, y)
  self.hover = nil
  for _, b in ipairs(self.buttons or {}) do
    if UI.inside(b, x, y) then self.hover = b.id end
  end
end

function Result:mousepressed(x, y)
  for _, b in ipairs(self.buttons or {}) do
    if UI.inside(b, x, y) then
      b.act()
      return
    end
  end
end

function Result:wheelmoved(_, dy)
  self.scroll = math.max(0, self.scroll - dy * 30)
end

return Result
