-- The tube over the playground's editor, when the playground is an old
-- computer (`src/computer.lua`).
--
-- Ported from the browser client's `gfx/retroscreen.ts`, which is after
-- cool-retro-term (github.com/swordfish90/cool-retro-term): a terminal drawn
-- through a stack of shaders -- bloom, scanlines, a phosphor mask, static, a
-- rolling sync bar, curvature and a bezel.
--
-- The browser has to split that stack in two, because its editor is DOM and a
-- WebGL canvas over it cannot read its pixels. This client draws its own text,
-- so the split is kept for a different reason: **the code is never pushed
-- through the shader.** Bending or blurring the glyphs somebody is reading
-- their own program in is the one thing a pane read for an hour must not do.
-- So, as in the browser:
--
--   * **the glyphs' own glow** is the scene's, a faint second pass of each
--     span in the palette's `glow` (`Playground:draw_code`);
--   * **everything that sits on the glass** is this: one quad exactly over the
--     editor, premultiplied, drawn after the code -- scanline gaps, the
--     aperture grille, a still grain, the rolling bar, a vignette, rounded
--     glass corners and a glare;
--   * **the boot screen** is the one thing drawn *on* the tube rather than
--     over it, so it gets the full treatment: barrel distortion, bloom and
--     colour fringing. It is the machine's own power-on text -- `]` and a
--     beep, MSX BASIC's banner, Workbench's title bar -- painted into a small
--     canvas at the machine's resolution and scaled up with nearest-neighbour,
--     so the pixels are its pixels.
--
-- Switching machines plays the power-on: a bright line opens into the screen,
-- the banner types itself out, and the screen fades into the editor.
-- Switching to "normal" plays the power-off -- the picture collapses to a line
-- and then a dot. A failed RUN puts the machine's own error up over the code
-- for a few seconds; on the Amiga that is a Guru Meditation, with its red box
-- blinking.
--
-- Nothing flickers. cool-retro-term's mains flicker, crawling static and sync
-- jitter were tried in the browser and taken out, and are not put back here.
--
-- **Nothing touches LÖVE until a machine is picked.** The shader and the
-- canvas are made on the first draw that needs them, inside a `pcall`, and a
-- client whose GPU will not compile the shader simply has no tube: the
-- palette and the monitor carry the theme on their own.

local Computer = require("src.computer")
local Assets = require("src.assets")

local Retro = {}
Retro.__index = Retro

--- Seconds for the line to open into a screen, and to collapse back.
Retro.WARM = 0.42
Retro.COOL = 0.5
--- How long the boot screen takes to fade into the editor.
Retro.REVEAL = 0.5
--- How long a run's error stays up.
Retro.ALERT_SECS = 3.2

-- LÖVE 11's dialect: `effect` rather than `main`, `Texel` rather than
-- `texture2D`, and `sc` -- the pixel on the virtual canvas, which is what
-- this client draws everything onto -- rather than `gl_FragCoord`. Texture
-- coordinates run **down** here and up in three.js, so the two formulas that
-- care (the rolling bar and the glare) read `up`, the browser's `vUv`.
local FRAG = [[
extern vec2 uRes;       // the glass, in canvas pixels
extern vec2 uOrigin;    // its top-left corner
extern vec2 uTextRes;   // boot-screen pixels
extern float uTime;
extern float uPower;    // 0 = a dot, 1 = a full picture
extern float uScreen;   // how much of the boot screen covers the editor
extern vec3 uPaper;
extern vec3 uInk;
extern float uScan;
extern float uScanPx;
extern float uMask;
extern float uBloom;
extern float uCurve;
extern float uNoise;
extern float uRoll;
extern float uFringe;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

// "a over b", both premultiplied.
vec4 over(vec4 a, vec4 b) { return a + b * (1.0 - a.a); }

vec3 screen(Image tex, vec2 uv) {
  vec2 px = vec2(uFringe / uTextRes.x, 0.0);
  vec3 c;
  c.r = Texel(tex, uv + px).r;
  c.g = Texel(tex, uv).g;
  c.b = Texel(tex, uv - px).b;
  // Bloom: a cheap blur of thirteen taps, added back. Phosphor that is lit
  // bleeds into the glass round it.
  vec3 b = vec3(0.0);
  vec2 s = 1.5 / uTextRes;
  for (int i = -3; i <= 3; i++) {
    b += Texel(tex, uv + vec2(float(i), 0.0) * s).rgb;
    if (i != 0) b += Texel(tex, uv + vec2(0.0, float(i)) * s).rgb;
  }
  b /= 13.0;
  return c + max(b - uPaper * 0.9, 0.0) * uBloom;
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
  vec2 up = vec2(uv.x, 1.0 - uv.y);
  vec2 cc = uv - 0.5;
  // Barrel: the boot screen bends, the glass corners round off.
  vec2 bent = uv + cc * dot(cc, cc) * uCurve * 1.6;
  float inside = step(0.0, bent.x) * step(bent.x, 1.0) * step(0.0, bent.y) * step(bent.y, 1.0);

  vec4 o = vec4(0.0);

  // -- the boot screen, when it is up -----------------------------------
  if (uScreen > 0.001) {
    vec3 c = inside > 0.5 ? screen(tex, bent) : vec3(0.0);
    o = vec4(c * uScreen, uScreen);
  }

  vec2 p = sc - uOrigin;

  // -- scanlines: the dark gaps between rows of phosphor -----------------
  float line = 0.5 + 0.5 * cos(6.2831853 * p.y / uScanPx);
  o = over(vec4(0.0, 0.0, 0.0, uScan * line * line), o);

  // -- aperture grille: faint R, G, B stripes ----------------------------
  if (uMask > 0.0) {
    float k = mod(floor(p.x), 3.0);
    vec3 m = k < 1.0 ? vec3(1.0, 0.0, 0.0) : (k < 2.0 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0));
    o = over(vec4(m * uMask * 0.35, uMask * 0.35), o);
  }

  // -- grain: still. It does not crawl. --------------------------------
  float n = hash(floor(p));
  o = over(vec4(uInk * n * uNoise * 0.6, n * uNoise * 0.4), o);

  // -- the rolling bar: a soft band of light walking down ----------------
  float bar = fract(uTime * 0.11);
  float d = abs((1.0 - up.y) - bar);
  float band = smoothstep(0.08, 0.0, d) * uRoll;
  o += vec4(uInk * band * 0.5, 0.0);

  // -- vignette and glass ------------------------------------------------
  float v = smoothstep(0.35, 0.95, length(cc * vec2(1.05, 1.15)) * 1.25);
  o = over(vec4(0.0, 0.0, 0.0, v * 0.55), o);
  float glare = smoothstep(0.55, 0.0, length((up - vec2(0.18, 0.86)) * vec2(1.0, 1.8)));
  o += vec4(vec3(glare * 0.05), 0.0);
  // Rounded corners of the tube, in the bezel's black.
  vec2 q = abs(cc) * 2.0;
  float r = 0.06 + uCurve * 0.25;
  vec2 ar = vec2(uRes.x / uRes.y, 1.0);
  float corner = length(max(q * ar - (ar - r), 0.0)) / r;
  o = over(vec4(0.0, 0.0, 0.0, smoothstep(0.92, 1.0, corner)), o);

  // -- power: a line that opens into a picture, and a dot it closes to --
  if (uPower < 0.999) {
    float h = smoothstep(0.0, 0.7, uPower);
    float w = smoothstep(0.0, 0.25, uPower);
    float ay = abs(uv.y - 0.5) * 2.0;
    float ax = abs(uv.x - 0.5) * 2.0;
    float lit = step(ay, max(h, 0.006)) * step(ax, max(w, 0.02));
    float hot = (1.0 - h) * lit;                     // thin = bright
    o = over(vec4(0.0, 0.0, 0.0, 1.0 - lit), o);
    o += vec4(mix(uInk, vec3(1.0), 0.6) * hot * 1.4, hot);
  }

  return clamp(o, 0.0, 1.0);
}
]]

-- The boot screen's character cell, in texels: the 8x8 cells the machines
-- had, at twice the resolution so the glyphs survive the trip.
local CELL = 16

local function blink(t, hz)
  return math.floor(t * (hz or 2)) % 2 == 0
end

--- How much of `s` is typed by `t`, starting at `from`, `cps` a second.
local function typed(s, t, from, cps)
  if t < from then return "" end
  return s:sub(1, math.floor((t - from) * (cps or 14)))
end

local function ink(c, a)
  love.graphics.setColor(c[1], c[2], c[3], a or 1)
end

--- Text on the grid, one cell per character, so the face lands on it.
local function put(grid, col, row, s)
  local font = grid.font
  for i = 1, #s do
    local ch = s:sub(i, i)
    if ch ~= " " then
      love.graphics.print(ch, (col + i - 1) * CELL, row * CELL + grid.dy, 0, grid.sx, grid.sy)
    end
  end
  return font
end

local function box(x, y, w, h)
  love.graphics.rectangle("fill", x, y, w, h)
end

--- Each machine's power-on, as a function of the seconds since it began.
local BOOTS = {
  -- The //e: a beep, "Apple ][" across the top, then BASIC's bracket prompt.
  apple2 = {
    secs = 2.4,
    draw = function(t, grid)
      local tube = Computer.TUBE.apple2
      ink(tube.ink)
      local title = "APPLE ]["
      if t > 0.15 then put(grid, math.floor((grid.cols - #title) / 2), 0, title) end
      if t > 0.6 then
        local cmd = typed("RUN PLAYGROUND", t, 0.75)
        put(grid, 0, grid.rows - 3, "]" .. cmd)
        -- The Apple's cursor is a flashing block.
        if blink(t, 3) then box((1 + #cmd) * CELL, (grid.rows - 3) * CELL, CELL, CELL) end
      end
    end,
  },
  -- MSX BASIC's banner on its blue, and the function-key bar along the bottom.
  msx = {
    secs = 2.6,
    draw = function(t, grid)
      local tube = Computer.TUBE.msx
      ink(tube.ink)
      local lines = {
        "MSX BASIC version 1.0",
        "Copyright 1983 by Microsoft",
        "28815 Bytes free",
        "Ok",
      }
      for i, l in ipairs(lines) do
        if t > 0.2 + (i - 1) * 0.25 then put(grid, 1, i, l) end
      end
      if t > 1.25 then
        local cmd = typed('run "PLAYGROUND"', t, 1.3)
        put(grid, 1, 5, cmd)
        if blink(t, 3) then box((1 + #cmd) * CELL, 5 * CELL, CELL, CELL) end
      end
      local keys = { "color", "auto", "goto", "list", "run" }
      -- SCREEN 0 kept a border round the text; so does this.
      local w = math.floor((grid.cols - 2) / #keys)
      for i, k in ipairs(keys) do
        ink(tube.ink)
        box((1 + (i - 1) * w) * CELL, (grid.rows - 2) * CELL, (w - 1) * CELL, CELL)
        ink(tube.paper)
        put(grid, 1 + (i - 1) * w, grid.rows - 2, k:sub(1, w - 1))
      end
    end,
  },
  -- Workbench 1.3: the white title bar with its free memory, and a CLI.
  amiga = {
    secs = 2.6,
    draw = function(t, grid)
      local white = { 1, 1, 1 }
      local orange = { 1, 0.53, 0 }
      local blue = Computer.TUBE.amiga.paper
      -- Kickstart's white screen first, then Workbench draws over it.
      if t < 0.5 then
        ink(white)
        box(0, 0, grid.cols * CELL, grid.rows * CELL)
        return
      end
      ink(white)
      box(0, 0, grid.cols * CELL, CELL * 1.2)
      ink(blue)
      put(grid, 1, 0, "Workbench release 1.3   451344 free memory")
      -- The depth gadgets, top right.
      box((grid.cols - 4) * CELL, CELL * 0.2, CELL * 1.4, CELL * 0.8)
      ink(orange)
      box((grid.cols - 2) * CELL, CELL * 0.2, CELL * 1.4, CELL * 0.8)
      if t > 0.8 then
        -- The CLI window: a white frame with its own title bar.
        local x, y = CELL * 2, CELL * 2.5
        local w, h = (grid.cols - 4) * CELL, (grid.rows - 4) * CELL
        ink(white)
        box(x, y, w, CELL * 1.1)
        love.graphics.setLineWidth(math.max(1, CELL * 0.25))
        love.graphics.rectangle("line", x, y, w, h)
        ink(blue)
        put(grid, 3, 2.5, "AmigaShell")
        ink(orange)
        box(x + w - CELL * 2, y + CELL * 0.15, CELL * 1.4, CELL * 0.8)
        ink(white)
        local lines = { "1.SYS:> LoadWB", "1.SYS:> cd Work:", "1.Work:> " }
        for i, l in ipairs(lines) do
          if t > 1.0 + (i - 1) * 0.25 then put(grid, 3, 3 + i, l) end
        end
        if t > 1.6 then
          local cmd = typed("playground", t, 1.65)
          put(grid, 3 + #lines[3], 6, cmd)
          if blink(t, 2) then
            ink(orange)
            box((3 + #lines[3] + #cmd) * CELL, 6 * CELL, CELL, CELL)
          end
        end
      end
    end,
  },
}
Retro.BOOTS = BOOTS

function Retro.new()
  return setmetatable({
    machine = nil,
    now = 0,
    -- What the tube is doing, and since when (`now`):
    -- "off" | "cooling" | "warming" | "booting" | "revealing" | "on".
    phase = "off",
    since = 0,
    -- Whether the warm-up goes on into the banner, or straight to the code.
    booting = false,
    -- A run's error, and when it went up.
    alert = nil,
    -- The glass it was last drawn over, for the boot screen's shape.
    rect = nil,
    ok = nil,   -- nil: not tried yet; then whether the shader compiled
  }, Retro)
end

--- Become `next_machine`. `boot` plays the whole power-on -- the banner and
--- all -- which is for the moment the machine is picked; arriving at the
--- screen with one already picked only warms the tube up.
function Retro:power(next_machine, boot)
  if not Computer.TUBE[next_machine] then
    if self.machine and self.phase ~= "off" then self:go("cooling") end
    return
  end
  self.machine = next_machine
  self.alert = nil
  self.booting = boot == true
  self:go("warming")
end

--- Put the machine's own error over the code for a few seconds.
function Retro:say(lines)
  if not lines or not self.machine or self.phase == "off" or self.phase == "cooling" then
    return
  end
  self.alert = { lines = lines, at = self.now }
end

function Retro:go(phase)
  self.phase = phase
  self.since = self.now
end

--- Whether there is anything to draw: a machine, or one still switching off.
function Retro:lit()
  return self.phase ~= "off"
end

function Retro:update(dt)
  self.now = self.now + dt
  local t = self.now - self.since
  local boot = self.machine and BOOTS[self.machine]
  if self.phase == "warming" and t >= Retro.WARM then
    self:go((self.booting and boot) and "booting" or "revealing")
  elseif self.phase == "booting" and boot and t >= boot.secs then
    self:go("revealing")
  elseif self.phase == "revealing" and t >= Retro.REVEAL then
    self:go("on")
  elseif self.phase == "cooling" and t >= Retro.COOL then
    self:go("off")
    self.machine = nil
  end
  if self.alert and self.now - self.alert.at > Retro.ALERT_SECS then self.alert = nil end
end

--- How lit the picture is and how much of the boot screen covers the code,
--- now. Pure, so the suite can walk the phases without a GPU.
function Retro:levels()
  local t = self.now - self.since
  local power, screen = 1, 0
  if self.phase == "warming" then
    power = math.min(1, t / Retro.WARM)
    screen = self.booting and 1 or (1 - power * 0.3)
  elseif self.phase == "booting" then
    screen = 1
  elseif self.phase == "revealing" then
    screen = 1 - math.min(1, t / Retro.REVEAL)
  elseif self.phase == "cooling" then
    power = math.max(0, 1 - t / Retro.COOL)
    screen = 0
  end
  -- An error goes up on the boot screen too, over the code, and fades.
  local age = self.alert and (self.now - self.alert.at) or 0
  if self.alert then
    screen = math.max(screen, math.min(1, (Retro.ALERT_SECS - age) / 0.4, age / 0.08))
  end
  return power, screen, t, age
end

-- ------------------------------------------------------------------ drawing

function Retro:prepare()
  if self.ok ~= nil then return self.ok end
  local made, shader = pcall(function()
    return love.graphics.newShader(FRAG)
  end)
  self.ok = made and shader ~= nil
  if self.ok then
    self.shader = shader
  elseif love and love.filesystem then
    print("retroscreen: no tube (" .. tostring(shader) .. ")")
  end
  return self.ok
end

--- The boot screen (or the error) into the small canvas, at its own size.
function Retro:paint(machine, w, h, t, age)
  local tube = Computer.TUBE[machine]
  local cols = tube.cols
  -- Rows follow the pane's shape, so a cell stays square on the glass.
  local rows = math.max(6, math.floor(cols * h / math.max(1, w) + 0.5))
  local cw, ch = cols * CELL, rows * CELL
  if not (self.canvas and self.canvas:getWidth() == cw and self.canvas:getHeight() == ch) then
    if self.canvas then self.canvas:release() end
    self.canvas = love.graphics.newCanvas(cw, ch)
    self.canvas:setFilter("nearest", "nearest")
  end
  -- The game's own pixel face: an 8x8 dot on the grid, which is what all
  -- three machines drew with. Stretched to fill its cell, as the 40-column
  -- machines stretched their 7-dot characters.
  local font = Assets.font(CELL)
  local adv = math.max(1, font:getWidth("M"))
  local fh = math.max(1, font:getHeight())
  local sy = (CELL * 0.875) / fh
  local grid = {
    cols = cols, rows = rows, font = font,
    sx = CELL / adv, sy = sy, dy = (CELL - fh * sy) / 2,
  }

  local before = love.graphics.getCanvas()
  local sx, sy0, sw, sh = love.graphics.getScissor()
  love.graphics.push("all")
  love.graphics.setScissor()
  love.graphics.setCanvas(self.canvas)
  love.graphics.origin()
  love.graphics.setShader()
  love.graphics.setBlendMode("alpha")
  love.graphics.setFont(font)
  ink(tube.paper)
  love.graphics.rectangle("fill", 0, 0, cw, ch)
  if self.alert then
    self:paint_alert(machine, grid, age)
  elseif self.phase == "booting" then
    BOOTS[machine].draw(t, grid)
  elseif self.phase == "revealing" and self.booting then
    BOOTS[machine].draw(BOOTS[machine].secs, grid)
  end
  love.graphics.pop()
  love.graphics.setCanvas(before)
  if sx then love.graphics.setScissor(sx, sy0, sw, sh) end
end

function Retro:paint_alert(machine, grid, age)
  local lines = self.alert.lines
  local tube = Computer.TUBE[machine]
  if machine == "amiga" then
    -- The Guru: black, a red box that blinks, red text centred in it.
    local red = { 1, 34 / 255, 0 }
    love.graphics.setColor(0, 0, 0, 1)
    box(0, 0, grid.cols * CELL, grid.rows * CELL)
    local top = 1
    local box_h = (#lines + 2) * CELL
    if blink(age, 1.2) then
      ink(red)
      love.graphics.setLineWidth(CELL * 0.75)
      love.graphics.rectangle("line", CELL * 0.6, top * CELL, (grid.cols - 1.2) * CELL, box_h)
    end
    ink(red)
    for i, l in ipairs(lines) do
      put(grid, math.max(1, math.floor((grid.cols - #l) / 2)), top + i, l)
    end
    return
  end
  -- The 8-bits print it under the code they were running and go back to the
  -- prompt: the line, and the cursor.
  ink(tube.ink)
  local row = math.max(1, math.floor(grid.rows / 2) - 1)
  for i, l in ipairs(lines) do put(grid, 0, row + i - 1, l) end
  local prompt = machine == "apple2" and "]" or "Ok"
  put(grid, 0, row + #lines, prompt)
  if blink(age, 3) then
    local apple = machine == "apple2"
    box((apple and 1 or 0) * CELL, (row + #lines + (apple and 0 or 1)) * CELL, CELL, CELL)
  end
end

--- Over `rect` of the virtual canvas, after the code has been drawn.
function Retro:draw(rect)
  if self.phase == "off" or not self.machine or not rect then return end
  if rect.w < 8 or rect.h < 8 then return end
  if not self:prepare() then return end
  local machine = self.machine
  local tube = Computer.TUBE[machine]
  local power, screen, t, age = self:levels()
  -- Painted before the shader is set, so the boot canvas is drawn plainly.
  if screen > 0 or not self.canvas then self:paint(machine, rect.w, rect.h, t, age) end
  local shader = self.shader
  -- One at a time and forgiving: a driver that optimised a uniform away
  -- makes `send` raise, and a tube with one dial missing is still a tube.
  local s = { send = function(_, name, value) pcall(shader.send, shader, name, value) end }
  s:send("uRes", { rect.w, rect.h })
  s:send("uOrigin", { rect.x, rect.y })
  s:send("uTextRes", { self.canvas:getWidth(), self.canvas:getHeight() })
  s:send("uTime", self.now)
  s:send("uPower", power)
  s:send("uScreen", screen)
  s:send("uPaper", tube.paper)
  s:send("uInk", tube.ink)
  s:send("uScan", tube.scan)
  s:send("uScanPx", tube.scan_px)
  s:send("uMask", tube.mask)
  s:send("uBloom", tube.bloom)
  s:send("uCurve", tube.curve)
  s:send("uNoise", tube.noise)
  s:send("uRoll", tube.roll)
  s:send("uFringe", tube.fringe)
  love.graphics.push("all")
  love.graphics.setShader(shader)
  -- The shader writes premultiplied colour, as the browser's does.
  love.graphics.setBlendMode("alpha", "premultiplied")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(self.canvas, rect.x, rect.y, 0,
    rect.w / self.canvas:getWidth(), rect.h / self.canvas:getHeight())
  love.graphics.pop()
end

function Retro:release()
  if self.canvas then self.canvas:release() end
  if self.shader then self.shader:release() end
  self.canvas, self.shader, self.ok = nil, nil, nil
end

return Retro
