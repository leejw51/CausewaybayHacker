-- The code screens' effects layer: typing, as a game.
--
-- The browser client's `ui/codefx.ts`, for LÖVE. It listens to the editor
-- (`Editor.on_event`, `src/editor.lua` "events"), turns `(line, col)` into
-- pixels through the pane that drew the code, picks a plan from
-- `src/fxplan.lua`, and paints it over the pane. What happens when:
--
--   * the pointer moves — a thin thread of light behind it, the caret's
--     colour, whiter the faster it goes;
--   * the caret moves — its rectangle smears from where it was to where it
--     is and shrinks back, a white thread down its middle, an L across
--     lines; and a *jump* (PageDown, a far click) drops grains on the way;
--   * a character is typed — sparks in its syntax colour;
--   * ENTER — a puff of dust along the new line;
--   * a character is erased — it breaks into brick, per character, in its
--     own colour, so a deleted line crumbles left to right;
--   * the caret rests by a bracket whose partner lit up — a runner between;
--   * a loop is closed — gold stars run a loop round the block, the well
--     gives a gold kick, and the coin plays.
--
-- **Over the pane, never in it.** `codepane.lua`'s rule that the editor pane
-- itself never animates stands: the text, the caret and the bracket outlines
-- are drawn steady by the scene, and this is a separate pass drawn after
-- them, the way the browser's layer is a separate canvas. Nothing here takes
-- a pointer event.
--
-- A particle's position is a function of its age (`fxplan.at`), so nothing
-- is integrated between frames; `update` advances a clock and drops the
-- dead. The brick and dust shapes are the Grok-drawn strips when the art has
-- loaded (`art/fx_bricks.png`, `art/fx_dust.png`), tinted to the token's hue
-- by a small shader that keeps the art's light and dark; without the art, or
-- without shaders, they are squares in the same colours.

local Assets = require("src.assets")
local Plan = require("src.fxplan")
local Editor = require("src.editor")
local E = require("src.ease")
local SFX = require("src.sfx")
local Theme = require("src.theme")

local M = {}

local Fx = {}
Fx.__index = Fx
M.Fx = Fx

--- The highlighter's kinds (`Theme.code`) as the spark each throws, plus the
--- one the highlighter does not have.
local function tone_colour(tone)
  if tone == "bracket" then
    return Theme.cyan
  end
  return Theme.code[tone] or Theme.cream
end
M.tone_colour = tone_colour

--- Pixels of pointer travel between one ember and the next; the most embers
--- one move may leave: a flick is a flick, not a wall.
M.TRAIL_STEP = 5
M.TRAIL_MAX = 10
--- The longest gap that still counts towards the caret's speed. A click after
--- a minute's thought is a fast move to where it clicked, not a slow one.
M.MOVE_GAP = 0.25
--- The most smears alive at once.
local SMEARS = 6
--- How many ghosts a trailing particle drags, and how far apart in time.
local GHOSTS = 6
local GHOST_DT = 0.018
--- Seconds the well's kick lasts.
local KICK = 0.6
--- The most particles alive at once; the oldest give way.
local CAP = 3000

function M.new()
  return setmetatable({
    t = 0,
    live = {},
    rings = {},
    -- Caret smears (`fxplan.smear_for`), each with the clock reading it
    -- was thrown at.
    smears = {},
    editor = nil,
    pane = nil,
    -- Where the caret was last seen — `{ line, col, x, y }`, the pixel pair
    -- held inside the pane's box — and when it last moved.
    last_caret = nil,
    moved_at = -1,
    -- The bracket pair last reported, so a caret resting by one runs once.
    last_pair = nil,
    -- The pointer's last position and when it was there; banked travel.
    last_x = nil,
    last_y = nil,
    last_at = 0,
    carry = 0,
    kick_at = -1e9,
    brick = nil,
    dust = nil,
    shader = nil,
    art_checked = false,
  }, Fx)
end

--- Listen to this editor, and measure through this pane.
function Fx:attach(editor, pane)
  if self.editor then
    self.editor.on_event = nil
  end
  self.editor, self.pane = editor, pane
  editor.on_event = function(ev)
    self:on(ev)
  end
  self.last_pair = nil
  -- A new document: the caret's first place in it is not a move from the
  -- old one.
  self.last_caret = nil
end

function Fx:detach()
  if self.editor then
    self.editor.on_event = nil
  end
  self.editor, self.pane = nil, nil
end

--- Throw a plan.
function Fx:play(plan)
  for _, p in ipairs(plan.particles) do
    p.born = self.t + (p.delay or 0)
    self.live[#self.live + 1] = p
  end
  for _, r in ipairs(plan.rings) do
    r.born = self.t + (r.delay or 0)
    self.rings[#self.rings + 1] = r
  end
  if #self.live > CAP then
    local drop = #self.live - CAP
    for _ = 1, drop do
      table.remove(self.live, 1)
    end
  end
end

--- A burst at a point, `n` strong, all in one colour — the quest screen's
--- ANSWER-mode sparks, which `src/sparks.lua` used to draw.
---
--- `scale` shrinks it to the size of the text it happens on. `Plan.burst` is
--- the street-cleared firework and its shockwave is 90 and 150 pixels wide
--- whatever `n` is, which over a line of code is a flash that hides the very
--- character it is pointing at. A keystroke is not a level ending.
function Fx:burst(x, y, n, color, scale)
  local plan = Plan.burst(x, y, n)
  scale = scale or 1
  for _, p in ipairs(plan.particles) do
    if color then p.color = color end
    if scale ~= 1 then
      p.dx = p.dx * scale
      p.dy = p.dy * scale
      p.gravity = p.gravity * scale
      p.size = p.size * math.max(0.5, scale)
      p.life = p.life * 0.7
    end
  end
  for _, r in ipairs(plan.rings) do
    if color then r.color = color end
    r.radius = r.radius * scale
  end
  self:play(plan)
end

--- A word the drill finished for the player, lighting up where it landed.
function Fx:fill(x0, y0, x1, y1, cell, color)
  self:play(Plan.fill(x0, y0, x1, y1, cell, color))
end

--- The caret moved: its smear, drawn as a stroked path that shortens from
--- the tail.
function Fx:smear(s)
  s.born = self.t
  self.smears[#self.smears + 1] = s
  if #self.smears > SMEARS then
    table.remove(self.smears, 1)
  end
end

function Fx:clear()
  self.live, self.rings, self.smears = {}, {}, {}
  self.last_caret = nil
end

-- ------------------------------------------------------------------- events

--- One character's box, or nil when its line is off screen.
local function cell_of(self, line, col)
  if not self.pane then
    return nil
  end
  return self.pane:cell(line, col)
end

--- The character cell size the pane last drew with: `{ w, h }`.
local function cell_size(self)
  local g = self.pane and self.pane.geom
  if not g then
    return { 8, 16 }
  end
  return { math.max(4, g.font:getWidth("M")), math.max(6, g.line_h) }
end

local function centre(self, line, col)
  local x, y, w, h = cell_of(self, line, col)
  if not x then
    return nil
  end
  return { x + w / 2, y + h / 2 }
end

function Fx:on(ev)
  if not self.pane then
    return
  end
  local cell = cell_size(self)
  if ev.kind == "type" then
    local x, y = cell_of(self, ev.line, ev.col)
    if not x then
      return
    end
    self:play(Plan.key(x, y + cell[2] / 2, cell, tone_colour(ev.tone), #ev.text))
  elseif ev.kind == "enter" then
    local x, y = cell_of(self, ev.line, ev.col)
    if not x then
      return
    end
    self:play(Plan.dust(x, y, cell))
  elseif ev.kind == "erase" then
    local cells = self:erase_cells(ev, cell)
    if #cells > 0 then
      self:play(Plan.rubble(cells, cell))
    end
  elseif ev.kind == "loop" then
    local open = centre(self, ev.open[1], ev.open[2])
    local close = centre(self, ev.close[1], ev.close[2])
    if not (open and close) then
      return
    end
    self:play(Plan.loop(open, close, cell))
    self.kick_at = self.t
    SFX.play("coin")
  end
end

--- One cell per non-blank byte of what was erased, laid out the way the text
--- was: along the line from where it started, and each further line from
--- its own column one. Read against the pane's geometry, so a line that has
--- scrolled off gets no cells.
function Fx:erase_cells(ev, cell)
  local g = self.pane.geom
  local cells = {}
  if not g then
    return cells
  end
  local editor = self.editor
  -- The head of the first line is what is still there before `col`.
  local head = (editor.lines[ev.line] or ""):sub(1, ev.col - 1)
  local row = ev.line - editor.scroll
  local prefix = head
  local i = 1
  while i <= #ev.text and #cells < Plan.RUBBLE_MAX do
    local ch = ev.text:sub(i, i)
    if ch == "\n" then
      row = row + 1
      prefix = ""
    else
      if row >= 1 and row <= g.rows and not ch:match("%s") then
        cells[#cells + 1] = {
          x = g.x0 + g.gutter + g.font:getWidth(prefix),
          y = g.y0 + (row - 1) * g.line_h,
          color = tone_colour(ev.tones and ev.tones[i] or "text"),
        }
      end
      prefix = prefix .. ch
    end
    i = i + 1
  end
  return cells
end

--- The pointer moved to `(x, y)`, in virtual pixels.
---
--- Distance-paced rather than event-paced: travel is banked and an ember is
--- spent every `TRAIL_STEP` pixels, placed along the segment, so the trail
--- is a thread at any event rate and never a wall on a flick.
function Fx:pointer(x, y)
  local t = self.t
  local lx, ly = self.last_x, self.last_y
  self.last_x, self.last_y = x, y
  if not lx or t - self.last_at > 0.25 then
    self.last_at = t
    self.carry = 0
    return
  end
  local dt = math.max(1 / 240, t - self.last_at)
  self.last_at = t
  local dx, dy = x - lx, y - ly
  local dist = math.sqrt(dx * dx + dy * dy)
  if dist < 0.5 then
    return
  end
  self.carry = self.carry + dist
  local n = math.min(M.TRAIL_MAX, math.floor(self.carry / M.TRAIL_STEP))
  if n == 0 then
    return
  end
  self.carry = self.carry - n * M.TRAIL_STEP
  local vx, vy = dx / dt, dy / dt
  for i = 1, n do
    local u = i / n
    self:play(Plan.pointer(lx + dx * u, ly + dy * u, vx, vy))
  end
end

-- ---------------------------------------------------------------- the caret

--- The top-left of the caret's cell, held inside the pane's visible box: a
--- PageDown scrolls, and the caret's old place may now be above the top of
--- it, so a caret that came from off the screen comes from its edge.
local function caret_px(self, cell)
  local ed, g = self.editor, self.pane.geom
  local line = ed.lines[ed.line] or ""
  local x = g.x0 + g.gutter + g.font:getWidth(line:sub(1, ed.col - 1))
  local y = g.y0 + (ed.line - ed.scroll - 1) * g.line_h
  local r = g.rect
  local left, top = g.x0 + g.gutter, g.y0
  local right, bottom = r.x + r.w - cell[1], g.y0 + g.rows * g.line_h - cell[2]
  x = math.min(math.max(x, left), math.max(left, right))
  y = math.min(math.max(y, top), math.max(top, bottom))
  return x, y
end

--- The smear from where the caret was to where it is, hotter the faster it
--- went; the corner's wink if it bent; and, only on a jump, the grains.
function Fx:moved(from, to, cell)
  local t = self.t
  local gap = self.moved_at < 0 and M.MOVE_GAP
    or math.min(M.MOVE_GAP, math.max(0.04, t - self.moved_at))
  self.moved_at = t
  local dist = math.sqrt((to[1] - from[1]) ^ 2 + (to[2] - from[2]) ^ 2)
  local smear = Plan.smear_for(from, to, cell, dist / gap)
  self:smear(smear)
  self:play(Plan.corner(smear))
  if Plan.is_jump(from, to, cell) then
    self:play(Plan.jump(smear))
  end
end

--- Read the caret once a frame, and report a move as the pane sees it: by
--- key, click, typing or a jump. The editor model has no pixels, so this is
--- measured here rather than emitted there.
local function watch_caret(self)
  local ed, pane = self.editor, self.pane
  if not (ed and pane and pane.geom) then
    return
  end
  local cell = cell_size(self)
  local x, y = caret_px(self, cell)
  local was = self.last_caret
  self.last_caret = { line = ed.line, col = ed.col, x = x, y = y }
  if not was or (was.line == ed.line and was.col == ed.col) then
    return
  end
  if math.abs(was.x - x) < 0.5 and math.abs(was.y - y) < 0.5 then
    return
  end
  self:moved({ was.x, was.y }, { x, y }, cell)
end

-- ------------------------------------------------------------------- frames

function Fx:update(dt)
  self.t = self.t + dt
  for i = #self.live, 1, -1 do
    local p = self.live[i]
    if self.t - p.born > p.life + GHOSTS * GHOST_DT then
      table.remove(self.live, i)
    end
  end
  for i = #self.rings, 1, -1 do
    local r = self.rings[i]
    if self.t - r.born > r.life then
      table.remove(self.rings, i)
    end
  end
  for i = #self.smears, 1, -1 do
    if self.t - self.smears[i].born > self.smears[i].life then
      table.remove(self.smears, i)
    end
  end
  watch_caret(self)
  -- The bracket pair the caret is beside, reported once per pair.
  if self.editor and self.pane then
    local here = self.editor:bracket_at_caret()
    local key = nil
    if here and here.partner then
      local a, b = here, here.partner
      if (b.line < a.line) or (b.line == a.line and b.col < a.col) then
        a, b = b, a
      end
      key = Editor.bracket_key(a.line, a.col) .. "/" .. Editor.bracket_key(b.line, b.col)
      if key ~= self.last_pair then
        local ca = centre(self, a.line, a.col)
        local cb = centre(self, b.line, b.col)
        if ca and cb then
          self:play(Plan.link(ca, cb, cell_size(self)))
        end
      end
    end
    self.last_pair = key
  end
end

-- ------------------------------------------------------------------ drawing

--- A shader that keeps the art's light and dark and takes the tint's hue, so
--- brick drawn in orange breaks green where a string was.
local TINT = [[
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 t = Texel(tex, uv);
    float lum = dot(t.rgb, vec3(0.3, 0.59, 0.11));
    return vec4(color.rgb * lum * 2.1, t.a * color.a);
  }
]]

--- Find the strips and build the shader, once, the first time we draw.
local function ready_art(self)
  if self.art_checked then
    return
  end
  self.art_checked = true
  for _, which in ipairs({ { "brick", "fx_bricks" }, { "dust", "fx_dust" } }) do
    local image, strip = Assets.image(which[2]), Assets.strip[which[2]]
    if image and strip then
      local quads = {}
      local iw, ih = image:getDimensions()
      for i = 1, strip.frames do
        quads[i] = love.graphics.newQuad((i - 1) * strip.fw, 0, strip.fw, strip.fh, iw, ih)
      end
      self[which[1]] = { image = image, quads = quads, frames = strip.frames, fw = strip.fw, fh = strip.fh }
    end
  end
  if love.graphics.newShader then
    local ok, shader = pcall(love.graphics.newShader, TINT)
    if ok then
      self.shader = shader
    end
  end
end

local function set(color, alpha)
  love.graphics.setColor(color[1], color[2], color[3], (color[4] or 1) * alpha)
end

--- A four-point star, `r` across, turned by `rot`.
local function star(x, y, r, rot)
  local pts = {}
  for i = 0, 7 do
    local ang = rot + i * math.pi / 4
    local d = (i % 2 == 0) and r or r * 0.35
    pts[#pts + 1] = x + math.cos(ang) * d
    pts[#pts + 1] = y + math.sin(ang) * d
  end
  love.graphics.polygon("fill", pts)
end

--- One particle at one moment. `ghost` is 0 for the particle itself and
--- 1..GHOSTS for the fainter copies behind a trailing one.
local function draw_particle(self, p, age, ghost)
  local x, y, t = Plan.at(p, age)
  if not x then
    return
  end
  local back = 1 - ghost / (GHOSTS + 1)
  local alpha = Plan.alpha(p, t) * (ghost > 0 and back * back * 0.5 or 1)
  if alpha <= 0.01 then
    return
  end
  local shape = p.shape
  local size = p.size * (0.55 + 0.45 * (1 - math.max(0, (t - 0.55) / 0.45)))
  if ghost > 0 then
    size = size * (0.25 + 0.75 * back)
  end

  if shape == 0 or shape == 6 then
    if shape == 6 then
      size = p.size * (1 - 0.6 * t) * (0.3 + 0.7 * back)
    end
    -- A soft disc: a faint wide halo, a firmer middle, a small hot core. Three
    -- flat circles stand in for the shader's falloff; drawn additively, so
    -- a ghost tail reads as light and not as a stack of coins.
    -- The pointer's ember is a lone disc with no burst around it, so it is
    -- drawn a little stronger than a spark that has forty neighbours.
    local k = shape == 6 and 1.7 or 1
    love.graphics.setBlendMode("add")
    set(p.color, alpha * 0.14 * k)
    love.graphics.circle("fill", x, y, size / 2, 12)
    set(p.color, alpha * 0.3 * k)
    love.graphics.circle("fill", x, y, size / 3.2, 10)
    set(Theme.cream, alpha * 0.35 * k)
    love.graphics.circle("fill", x, y, size / 7, 8)
    love.graphics.setBlendMode("alpha")
  elseif shape == 7 then
    -- A grain: a flat streak, never taller than a fraction of the line.
    love.graphics.setBlendMode("add")
    set(p.color, alpha * 0.9)
    love.graphics.rectangle("fill", x - size / 2, y - size * 0.1, size, math.max(1, size * 0.2))
    love.graphics.setBlendMode("alpha")
  elseif shape == 1 then
    -- A star stays gold: drawn over, not added, so twelve of them on one
    -- path are twelve gold stars and not one white smear.
    set(p.color, alpha * 0.95)
    star(x, y, size / 2, p.seed * 6.2832 + age * (1.5 + p.seed * 2))
    set(Theme.cream, alpha * 0.5)
    love.graphics.circle("fill", x, y, size / 8, 6)
  elseif shape == 4 then
    local rot = p.seed * 6.2832 + age * (4 + p.seed * 8) * (p.seed > 0.5 and 1 or -1)
    local art = self.brick
    if art then
      local frame = math.min(art.frames, math.floor(p.seed * art.frames) + 1)
      local s = size / art.fh
      if self.shader then
        love.graphics.setShader(self.shader)
      end
      set(p.color, alpha)
      love.graphics.draw(art.image, art.quads[frame], x, y, rot, s, s, art.fw / 2, art.fh / 2)
      if self.shader then
        love.graphics.setShader()
      end
    else
      set(p.color, alpha)
      love.graphics.push()
      love.graphics.translate(x, y)
      love.graphics.rotate(rot)
      love.graphics.rectangle("fill", -size / 2, -size / 2, size, size)
      love.graphics.pop()
    end
  elseif shape == 5 then
    local art = self.dust
    local grow = p.size * (0.6 + 0.8 * t)
    if art then
      local frame = math.min(art.frames, math.floor(t * art.frames) + 1)
      local s = grow / art.fh
      love.graphics.setColor(
        1 - (1 - p.color[1]) * 0.25,
        1 - (1 - p.color[2]) * 0.25,
        1 - (1 - p.color[3]) * 0.25,
        alpha * 0.85
      )
      love.graphics.draw(
        art.image,
        art.quads[frame],
        x,
        y,
        0,
        p.seed > 0.5 and -s or s,
        s,
        art.fw / 2,
        art.fh / 2
      )
    else
      set(p.color, alpha * 0.7)
      love.graphics.circle("fill", x, y, grow / 2, 10)
    end
  else
    -- Paper: a scrap spinning in the plane and flipping through it.
    local rot = p.seed * 6.2832 + age * (3 + p.seed * 6) * (p.seed > 0.5 and 1 or -1)
    local flip = math.abs(math.sin(age * (5 + p.seed * 4) + p.seed * 6.2832))
    set(p.color, alpha)
    love.graphics.push()
    love.graphics.translate(x, y)
    love.graphics.rotate(rot)
    love.graphics.rectangle(
      "fill",
      -size * 0.46,
      -size * 0.22 * math.max(0.1, flip),
      size * 0.92,
      size * 0.44 * math.max(0.1, flip)
    )
    love.graphics.pop()
  end
end

--- The points of `smear.path` between `from` and `to` (0..1 along it, by
--- distance), the corner included when it lies between them.
local function piece(smear, from, to)
  local pts = {}
  local x, y = Plan.path_point(smear.path, from)
  pts[#pts + 1], pts[#pts + 1] = x, y
  if #smear.path == 3 then
    local a, c, b = smear.path[1], smear.path[2], smear.path[3]
    local first = math.sqrt((c[1] - a[1]) ^ 2 + (c[2] - a[2]) ^ 2)
    local corner = first / (first + math.sqrt((b[1] - c[1]) ^ 2 + (b[2] - c[2]) ^ 2))
    if corner > from and corner < to then
      pts[#pts + 1], pts[#pts + 1] = c[1], c[2]
    end
  end
  x, y = Plan.path_point(smear.path, to)
  pts[#pts + 1], pts[#pts + 1] = x, y
  -- LÖVE drops a repeated vertex and then refuses a one-vertex line, so a
  -- piece that has shrunk to a point is no piece.
  local out = { pts[1], pts[2] }
  for i = 3, #pts, 2 do
    if math.abs(pts[i] - out[#out - 1]) > 0.01 or math.abs(pts[i + 1] - out[#out]) > 0.01 then
      out[#out + 1], out[#out + 1] = pts[i], pts[i + 1]
    end
  end
  return #out >= 4 and out or nil
end

--- One smear at one moment: the head across almost at once, the tail on a
--- slow start, width and alpha dying together; one colour, and a thin white
--- thread down its middle that burns as hot as the caret went.
local function draw_smear(self, smear)
  local k = (self.t - smear.born) / smear.life
  if k < 0 or k >= 1 then
    return
  end
  local head = E.expOut(math.min(1, k / 0.45))
  local tail = k * k * (3 - 2 * k)
  if head <= tail then
    return
  end
  local pts = piece(smear, tail, head)
  if not pts then
    return
  end
  local fade = 1 - k * k
  love.graphics.setBlendMode("add")
  love.graphics.setLineStyle("rough")
  love.graphics.setLineJoin("miter")
  set(smear.color, 0.45 * fade)
  love.graphics.setLineWidth(math.max(1, smear.width * (1 - 0.8 * k * k)))
  love.graphics.line(pts)
  set(Theme.cream, smear.core * 0.8 * fade)
  love.graphics.setLineWidth(math.max(1, smear.width * 0.12))
  love.graphics.line(pts)
  love.graphics.setLineWidth(1)
  love.graphics.setBlendMode("alpha")
end

function Fx:draw()
  if #self.live == 0 and #self.rings == 0 and #self.smears == 0 and self.t - self.kick_at > KICK then
    return
  end
  ready_art(self)
  for _, smear in ipairs(self.smears) do
    draw_smear(self, smear)
  end
  for _, r in ipairs(self.rings) do
    local age = self.t - r.born
    if age >= 0 and age < r.life then
      local k = age / r.life
      local radius = math.max(1, r.radius * E.expOut(k))
      if r.glow then
        -- A glow is a falloff, not a disc: three faint circles nested, so
        -- the middle is brightest and the edge is barely there.
        love.graphics.setBlendMode("add")
        local a = (1 - k) * (1 - k)
        set(r.color, a * 0.07)
        love.graphics.circle("fill", r.x, r.y, radius, 24)
        set(r.color, a * 0.1)
        love.graphics.circle("fill", r.x, r.y, radius * 0.66, 20)
        set(r.color, a * 0.14)
        love.graphics.circle("fill", r.x, r.y, radius * 0.33, 16)
        love.graphics.setBlendMode("alpha")
      else
        -- The shockwave: a thin line that thins further as it goes, and
        -- fades — a wave passing, not a hoop.
        set(r.color, (1 - k * k) * 0.7)
        love.graphics.setLineWidth(math.max(1, r.radius * 0.025 * (1 - k)))
        love.graphics.circle("line", r.x, r.y, radius, 40)
        love.graphics.setLineWidth(1)
      end
    end
  end
  for _, p in ipairs(self.live) do
    local age = self.t - p.born
    if p.trail then
      for ghost = GHOSTS, 1, -1 do
        draw_particle(self, p, age - ghost * GHOST_DT, ghost)
      end
    end
    draw_particle(self, p, age, 0)
  end
  -- The kick: the well's edge flares gold and settles, on the house curve.
  local g = self.pane and self.pane.geom
  local kick = self.t - self.kick_at
  if g and kick < KICK then
    local u = E.expOut(kick / KICK)
    local grow = 6 * math.sin(math.pi * math.min(1, kick / KICK))
    local r = g.rect
    love.graphics.setBlendMode("add")
    set(Theme.coin, (1 - u) * 0.8)
    love.graphics.setLineWidth(3)
    love.graphics.rectangle("line", r.x - grow, r.y - grow, r.w + grow * 2, r.h + grow * 2)
    love.graphics.setLineWidth(1)
    love.graphics.setBlendMode("alpha")
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return M
