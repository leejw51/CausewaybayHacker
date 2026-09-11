-- MAP. The Super Mario World overworld, from `world.map` (PROTOCOL §4.7).
--
-- Everything drawn here is the server's: the node positions are `x`/`y` in
-- 0..1 of the map image (SPEC §12), the paths are the `edges` array — given
-- explicitly "so a client never has to infer the overworld's shape" — and
-- `state` is `open` or `cleared` as the server computed it. This screen has
-- no opinion about which node should light up next.
--
-- `progress.update` (§4.19) patches the map in place, which keeps two windows
-- in step without a refetch. A reconnect refetches anyway (§6 rule 5),
-- because a missed event is exactly what a drop causes.
--
-- ## Nothing is locked
--
-- §4.7, amended: every node is playable and `MapNode.state` is `open` or
-- `cleared`. `requires` and `edges` stay and still draw the route — the packs
-- are written in a deliberate order and "where next" is a real question — but
-- it is **advice, not a gate**. So no padlock and nothing greyed out:
-- `art/node_locked.png` is retired from this screen, because a padlock on a
-- node the player can walk into is a lie that costs them the quest they came
-- for. A node further along the route is drawn as what it is — one they have
-- not done yet.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Ease = require("src.ease")
local Anim = require("src.anim")

local Map = {}
Map.__index = Map

-- The two lands and the three categories, in SPEC §0's order.
local LANDS = { "rust", "go" }
local CATEGORIES = { "basic", "advanced", "hacker" }
local MASCOT = { rust = "sprite_ferris", go = "sprite_gogo" }

--- Where the player was, per map, keyed `land.category`.
---
--- Module-level rather than per-scene, because the scene is rebuilt every
--- time the map is entered and "come back to where I was" has to survive
--- that. The same idea as `CausewaybayGolang`'s `Game.trackQuest`, which
--- remembers the quest last visited in each language track.
--- Seeded from the store on first use, so "where was I" survives a restart
--- and not just a scene rebuild.
Map.last_node = nil

local function remembered()
  if not Map.last_node then
    Map.last_node = require("src.store").map_cursors()
  end
  return Map.last_node
end

function Map.new(app)
  return setmetatable({
    app = app,
    nodes = nil,
    edges = {},
    by_id = {},
    cursor = 1,
    error = nil,
    t = 0,
    stamped = {},   -- quest_id -> seconds since the stamp landed
    -- Mei, standing on a node or walking between two.
    at = nil,       -- the node index she is standing on
    walk = nil,     -- { from, to, elapsed, duration, path }
    picked_at = 0,  -- when the cursor last landed, for the node pulse
    -- The iris out of the selected node into the quest screen: the most
    -- "game" thing available for the least work, because it says the two
    -- screens are the same place in a way a cut never can.
    iris = nil,     -- { started, x, y, quest_id }
  }, Map)
end

function Map:enter(params)
  self.land = params.land or self.app.land or "rust"
  self.category = params.category or self.app.category or "basic"
  self.app.land, self.app.category = self.land, self.category

  self.subscriptions = {
    self.app.session:on("progress.update", function(payload)
      self:apply_progress(payload)
    end),
  }

  self:refresh()
end

function Map:leave()
  self.app.session:off_all(self.subscriptions)
  self.subscriptions = nil
end

function Map:key()
  return self.land .. "." .. self.category
end

--- Switch to another map without leaving the screen.
---
--- `world.map` is one cheap call, so looking costs nothing and is entirely
--- reversible — which is the point. Before the gates came off, reaching
--- HACKER was ESC → lands → land → category; the gate is gone but that
--- friction would have stayed.
---
--- **A cut, not a walk.** Mei is standing on a node of the map being left;
--- on the next map she is somewhere else entirely, and animating a figure
--- between two different overworlds would be nonsense. The walk is for moving
--- *within* a map. `CausewaybayGolang`'s `Game:setQuest` does the same thing
--- — it nils `mapHeroX/Y` and clears `mapWalking` on a track change.
function Map:switch(land, category)
  land = land or self.land
  category = category or self.category
  if land == self.land and category == self.category then return end

  -- Remember where the player was on the map being left.
  local here = self:node_at(self.cursor)
  if here then
    remembered()[self:key()] = here.quest_id
    require("src.store").set_map_cursor(self:key(), here.quest_id)
  end

  self.land, self.category = land, category
  self.app.land, self.app.category = land, category

  -- The cut.
  self.walk = nil
  self.at = nil
  self.nodes = nil
  self.by_id = {}
  self.edges = {}
  self.adjacency = nil
  self.stamped = {}
  self.switched_at = self.t

  SFX.play("select")
  self.app:toast(("%s / %s"):format(land:upper(), category:upper()))
  self:refresh()
end

--- TAB — the other land, **keeping the category**.
---
--- Somebody comparing how Rust and Go do concurrency wants to land on the
--- concurrency map, not at the top of GO BASIC.
function Map:cycle_land()
  for i, land in ipairs(LANDS) do
    if land == self.land then
      self:switch(LANDS[i % #LANDS + 1], self.category)
      return
    end
  end
  self:switch(LANDS[1], self.category)
end

--- Q — the next category of this land, wrapping. One action, not two.
function Map:cycle_category()
  for i, category in ipairs(CATEGORIES) do
    if category == self.category then
      self:switch(self.land, CATEGORIES[i % #CATEGORIES + 1])
      return
    end
  end
  self:switch(self.land, CATEGORIES[1])
end

function Map:refresh()
  self.error = nil
  self.app.session:request("world.map", { land = self.land, category = self.category },
    function(ok, payload, why)
      if not ok then
        self.error = why.player
        return
      end
      self.nodes = payload.nodes or {}
      self.edges = payload.edges or {}
      -- §5.2: `state` is `open` or `cleared`, never `locked`. A server that
      -- has not shipped §4.7 yet still sends `locked`, and this screen must
      -- not draw the word on a node the player can walk straight into —
      -- a label that contradicts the behaviour teaches them to distrust both.
      -- Folded to `open` here, once, so nothing downstream has to know.
      -- The server is still the authority on the *quest*: `quest.get` may
      -- answer `locked` and the quest screen shows exactly that.
      for _, node in ipairs(self.nodes) do
        if node.state == "locked" then node.state = "open" end
      end
      -- §4.7 says `nodes` arrives "ordered by node", and this sorts anyway.
      -- Observed on the live server: `world.map` for rust/basic returned
      -- `rust.basic.12.traits` as the first element. Nothing here depends on
      -- array order for correctness — positions come from `x`/`y`, paths from
      -- `edges`, labels from `node.node` — but "the first node the player can
      -- play" is a walk over this list, and out of order it starts the cursor
      -- somewhere arbitrary. One sort makes the screen right whatever arrives.
      table.sort(self.nodes, function(a, b)
        return (a.node or 0) < (b.node or 0)
      end)
      self.by_id = {}
      for i, node in ipairs(self.nodes) do
        self.by_id[node.quest_id] = i
      end
      -- Where was I? The node this map was left on, if the player has been
      -- here before; otherwise the earliest one not yet cleared, which is
      -- where the suggested route has got to.
      self.cursor = 1
      local was = remembered()[self:key()]
      local found = was and self.by_id[was]
      if found then
        self.cursor = found
      else
        for i, node in ipairs(self.nodes) do
          if node.state ~= "cleared" then self.cursor = i; break end
        end
      end
      self.cursor = math.max(1, math.min(#self.nodes, self.cursor))
      -- She appears where the player left off rather than walking in from
      -- node 1 every time the map is opened.
      self.at = self.cursor
      self.walk = nil
      self.adjacency = nil
    end)
end

--- §4.19: patch the map rather than refetching it.
function Map:apply_progress(payload)
  if not self.nodes then return end
  local index = self.by_id[payload.quest_id]
  if index then
    local node = self.nodes[index]
    if payload.state then node.state = payload.state end
    if payload.stars then node.stars = payload.stars end
    if payload.state == "cleared" then
      self.stamped[payload.quest_id] = 0
      SFX.play("stamp")
    end
  end
  -- §4.19 may still carry `unlocked`; with nothing locked it is a no-op, but
  -- a client that ignored a field the server sent would be guessing.
  for _, id in ipairs(payload.unlocked or {}) do
    local i = self.by_id[id]
    if i and self.nodes[i].state ~= "cleared" then
      self.nodes[i].state = "open"
    end
  end
end

function Map:node_at(index)
  return self.nodes and self.nodes[index] or nil
end

--- Where a node sits on screen. The plate is drawn `cover`-style, so the
--- 0..1 coordinates map onto the *drawn* rectangle, not the window.
function Map:plate_rect()
  local vw, vh = Layout.vw, Layout.vh
  local top, bottom = 56, 46
  return 0, top, vw, vh - top - bottom
end

function Map:node_xy(node)
  local px, py, pw, ph = self:plate_rect()
  local inset = 28
  return px + inset + (node.x or 0.5) * (pw - inset * 2),
    py + inset + (node.y or 0.5) * (ph - inset * 2)
end

--- Open the node under the cursor. Nothing refuses; §4.7.
---
--- If Mei is still walking, this **skips to the end** instead — a player who
--- has picked a node wants the quest, not the animation, and a second press
--- must never be a press they have to repeat.
function Map:open_node()
  if self:skip_walk() then
    SFX.play("move")
    return
  end
  local node = self:node_at(self.cursor)
  if not node then return end
  if self.iris then return end
  SFX.play("select")
  -- The iris closes on the node, then the quest screen opens. `update` does
  -- the handover, so a player who presses again lands immediately (see
  -- `keypressed`) rather than waiting out an animation they did not ask for.
  local x, y = self:node_xy(node)
  self.iris = { started = Anim.now(), x = x, y = y, quest_id = node.quest_id }
end

--- Go now, wherever the iris had got to.
function Map:enter_quest()
  local target = self.iris and self.iris.quest_id or
    (self:node_at(self.cursor) or {}).quest_id
  if not target then return end
  self.iris = nil
  self.app.quest_id = target
  self.app:go("quest", { quest_id = target, land = self.land, category = self.category })
end

-- How long the walk takes.
--
-- Expo is almost still, then very fast, then almost still — so it needs room
-- to read as deliberate rather than as a stutter, and *less* room than you
-- would guess once the distance is large, because the fast middle does most
-- of the work. Hence a floor, a ceiling, and a square root in between rather
-- than a straight proportion.
--
-- The ceiling is the important number. Every node is reachable now (§4.7), so
-- a jump can be node 1 to node 24, and nobody wants a second and a half of
-- walking to reach the quest they asked for. Past that distance the view
-- carries it and the legs simply keep moving.
Map.WALK_MIN_S = 0.34
Map.WALK_MAX_S = 0.85
Map.WALK_REF_PX = 260          -- the distance WALK_MAX_S is tuned for
Map.WALK_FPS = 7               -- see the note in `draw_mei`
-- Short. An iris is punctuation, not an event; long enough to read as a
-- camera and short enough that nobody waits for it.
Map.IRIS_S = 0.26

--- Declared with a dot rather than a colon: it uses nothing from `self`, and
--- the headless test calls it without building a Map.
function Map.walk_duration(_, distance)
  local k = math.min(1, math.sqrt(math.max(0, distance or 0) / Map.WALK_REF_PX))
  return Map.WALK_MIN_S + (Map.WALK_MAX_S - Map.WALK_MIN_S) * k
end

--- Send Mei from wherever she is to node `index`.
---
--- The route is the `edges` the map already draws, walked with a breadth-first
--- search, so she follows the street rather than cutting across the harbour.
--- When there is no route — and with nothing locked a player may well jump to
--- an unconnected node — she goes straight there, which is honest: there is no
--- path to show.
function Map:walk_to(index)
  if not self.nodes or not self.nodes[index] then return end
  if not self.at then self.at = index; return end
  if self.at == index then return end

  local path = self:route(self.at, index)
  local distance = 0
  local px, py = self:node_xy(self.nodes[path[1]])
  for i = 2, #path do
    local qx, qy = self:node_xy(self.nodes[path[i]])
    distance = distance + math.sqrt((qx - px) ^ 2 + (qy - py) ^ 2)
    px, py = qx, qy
  end

  self.walk = {
    path = path,
    elapsed = 0,
    duration = self:walk_duration(distance),
    facing = 1,
  }
  self.at = index
end

--- The node indices from `a` to `b` along `edges`, inclusive.
function Map:route(a, b)
  if not self.adjacency then
    self.adjacency = {}
    for _, edge in ipairs(self.edges) do
      local i, j = self.by_id[edge[1]], self.by_id[edge[2]]
      if i and j then
        self.adjacency[i] = self.adjacency[i] or {}
        self.adjacency[j] = self.adjacency[j] or {}
        table.insert(self.adjacency[i], j)
        table.insert(self.adjacency[j], i)
      end
    end
  end

  local previous, queue, head = { [a] = a }, { a }, 1
  while head <= #queue do
    local here = queue[head]; head = head + 1
    if here == b then break end
    for _, next_index in ipairs(self.adjacency[here] or {}) do
      if not previous[next_index] then
        previous[next_index] = here
        queue[#queue + 1] = next_index
      end
    end
  end

  if not previous[b] then return { a, b } end   -- no route: a straight line
  local path, here = {}, b
  while here ~= a do
    table.insert(path, 1, here)
    here = previous[here]
  end
  table.insert(path, 1, a)
  return path
end

--- Where Mei is right now, and which way she is facing.
function Map:mei_position()
  if not self.nodes then return nil end
  if not self.walk then
    local node = self.nodes[self.at]
    if not node then return nil end
    local x, y = self:node_xy(node)
    return x, y, 1, false
  end

  local w = self.walk
  -- **The curve.** One expo ease over the whole route, not per segment: the
  -- walk should accelerate once and arrive once, however many nodes it
  -- crosses.
  local eased = Ease.expInOut(math.min(1, w.elapsed / w.duration))
  local segments = #w.path - 1
  local travelled = eased * segments
  local segment = math.min(segments, math.floor(travelled) + 1)
  local within = travelled - (segment - 1)

  local ax, ay = self:node_xy(self.nodes[w.path[segment]])
  local bx, by = self:node_xy(self.nodes[w.path[segment + 1]])
  local x = ax + (bx - ax) * within
  local y = ay + (by - ay) * within
  return x, y, (bx >= ax) and 1 or -1, true
end

function Map:skip_walk()
  if not self.walk then return false end
  self.walk = nil
  return true
end

function Map:update(dt)
  self.t = self.t + dt
  for id, age in pairs(self.stamped) do
    self.stamped[id] = age + dt
  end
  if self.walk then
    self.walk.elapsed = self.walk.elapsed + dt
    if self.walk.elapsed >= self.walk.duration then
      self.walk = nil
    end
  end
  if self.iris and Anim.iris_done(Anim.now() - self.iris.started, Map.IRIS_S) then
    self:enter_quest()
  end
end

-- ------------------------------------------------------------------ drawing

function Map:draw()
  local vw, vh = Layout.vw, Layout.vh
  local px, py, pw, ph = self:plate_rect()

  -- `art/` ships a plate per land (`map_rust`, `map_go`, plus portrait
  -- variants). The placeholder `map_bg` is the fallback for a checkout where
  -- `art/` is not readable.
  local suffix = Layout.isPortrait() and "_p" or ""
  Assets.cover(
    Assets.pick("map_" .. self.land .. suffix, "map_bg" .. suffix, "map_bg"),
    px, py, pw, ph)
  local haze = Theme.haze[self.land] or Theme.haze.rust
  love.graphics.setColor(haze)
  love.graphics.rectangle("fill", px, py, pw, ph)
  love.graphics.setColor(1, 1, 1, 1)

  -- `art/fg_wires` was drawn here for one round and taken out again. It is a
  -- foreground layer for an **elevation** — a street seen from the side — and
  -- every full-screen plate in this client is either a top-down town or a
  -- room. A slung cable over a top-down town is a cable lying in the road: it
  -- crossed six nodes and two streets and read as damage. The two elevation
  -- plates that would suit it, `title_bg` and `bg_street`, already have their
  -- catenary painted in. The asset stays unused on purpose.

  self:draw_agents()
  self:draw_edges()
  self:draw_nodes()
  self:draw_mei()

  self:draw_header()

  local node = self:node_at(self.cursor)
  if node then
    self:draw_node_card(node)
  elseif self.error then
    UI.text(self.error, 0, vh / 2, 10, Theme.red, "center", vw)
  elseif not self.nodes then
    UI.text(I18n.t("asking the server…"), 0, vh / 2, 10,
      Theme.withAlpha(Theme.cream, 0.7), "center", vw)
  end

  self:draw_iris()

  self.app:footer(I18n.t(self.walk
    and "ANY KEY skip"
    -- **Not a second listing of TAB and Q.** Those two switch the land and
    -- the category, and both are buttons in this screen's own header a couple
    -- of centimetres above — the row that exists precisely so the switch is
    -- visible. Repeating them here made the longest hint in the client, the
    -- only one still clipping in Korean at the readable type ladder, and it
    -- bought nothing the header does not already say.
    or "ARROWS node   ENTER play   P playground   T stats   ESC back"))
end

--- The header: two land buttons, three category tabs, the count.
---
--- The switch has to be **visible**. A keybinding nobody can see is not a
--- feature, and the whole reason for this row is that reaching HACKER used to
--- cost a trip out to two other screens. `CausewaybayGolang` puts "the three
--- big buttons" for its language tracks on its map for the same reason; these
--- are the same idea with this game's two lands and three categories.
--- The iris: everything outside a shrinking circle goes to ink.
---
--- Drawn with a stencil rather than a shader, because a shader is another
--- thing to fail on somebody's driver and this needs to work everywhere.
--- The circle closes on the node that was pressed, so the quest screen opens
--- out of the place on the map the player was looking at.
function Map:draw_iris()
  if not self.iris then return end
  local fraction = Anim.iris(Anim.now() - self.iris.started, Map.IRIS_S)
  if not fraction then return end
  local vw, vh = Layout.vw, Layout.vh
  -- Big enough at fraction 1 to clear the corners from anywhere on screen.
  local full = math.sqrt(vw * vw + vh * vh)
  local radius = math.max(0, fraction * full)

  love.graphics.stencil(function()
    love.graphics.circle("fill", self.iris.x, self.iris.y, radius, 64)
  end, "replace", 1)
  love.graphics.setStencilTest("equal", 0)
  UI.setColor(Theme.void, 1)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setStencilTest()
  love.graphics.setColor(1, 1, 1, 1)
end

function Map:draw_header()
  local vw = Layout.vw
  -- **Every number in this row is measured from the type in it.** It was
  -- authored against a 10 px land label and an 8 px category tab in a 56 px
  -- band; at twice that ladder the two land buttons overlapped each other and
  -- the three category tabs ran off the end of the row.
  local land_size, cat_size, tag_size = 10, 8, 7
  local label_h = UI.lineHeight(land_size)
  local bh = math.max(38, label_h + 18)
  local h = bh + 18
  UI.setColor(Theme.ink, 0.88)
  love.graphics.rectangle("fill", 0, 0, vw, h)
  love.graphics.setColor(1, 1, 1, 1)

  self.land_rects = {}
  self.category_rects = {}
  self.header_h = h

  -- What the row needs if nothing is squeezed, and what it actually has.
  local mascot = bh - 10
  local land_w = 0
  for _, land in ipairs(LANDS) do
    land_w = math.max(land_w, mascot + 8 + UI.textWidth(I18n.t(land:upper()), land_size) + 10)
  end
  local cat_w = 0
  for _, category in ipairs(CATEGORIES) do
    cat_w = math.max(cat_w, UI.textWidth(I18n.t(category:upper()), cat_size) + 16)
  end
  local tab_tag = UI.textWidth("TAB", tag_size) + 8
  local q_tag = UI.textWidth("Q", tag_size) + 8
  local wanted = 10 + #LANDS * (land_w + 6) + tab_tag
    + #CATEGORIES * (cat_w + 4) + q_tag + 10
  -- Too narrow for all of it — a portrait canvas in a language with wide
  -- glyphs — so the two key tags go first and then everything shrinks
  -- proportionally. Shrinking is the last resort, not the first.
  local show_tags = wanted <= vw
  if not show_tags then
    wanted = wanted - tab_tag - q_tag
    tab_tag, q_tag = 0, 0
  end
  if wanted > vw then
    local squeeze = (vw - 20 - #LANDS * 6 - #CATEGORIES * 4)
      / math.max(1, #LANDS * land_w + #CATEGORIES * cat_w)
    land_w = math.floor(land_w * squeeze)
    cat_w = math.floor(cat_w * squeeze)
  end

  local x = 10
  local by = (h - bh) / 2
  for _, land in ipairs(LANDS) do
    local on = land == self.land
    local tint = Theme.land[land] or Theme.coin
    UI.setColor(on and tint or Theme.withAlpha(Theme.dim, 0.45))
    love.graphics.rectangle("fill", x, by, land_w, bh)
    love.graphics.setLineWidth(2)
    UI.setColor(on and Theme.cream or Theme.withAlpha(Theme.cream, 0.3))
    love.graphics.rectangle("line", x + 1, by + 1, land_w - 2, bh - 2)
    love.graphics.setColor(1, 1, 1, 1)
    Assets.sprite(MASCOT[land], x + 4 + mascot / 2, by + bh - 4, mascot,
      { alpha = on and 1 or 0.45 })
    love.graphics.setScissor(x, by, land_w, bh)
    UI.text(I18n.t(land:upper()), x + mascot + 6, by + (bh - label_h) / 2, land_size,
      on and Theme.ink or Theme.withAlpha(Theme.cream, 0.55))
    love.graphics.setScissor()
    self.land_rects[land] = { x = x, y = by, w = land_w, h = bh }
    x = x + land_w + 6
  end

  if show_tags then
    UI.text(I18n.t("TAB"), x, by, tag_size, Theme.withAlpha(Theme.cream, 0.4))
    x = x + tab_tag
  end

  local ch = math.max(28, UI.lineHeight(cat_size) + 12)
  local cy = (h - ch) / 2
  for _, category in ipairs(CATEGORIES) do
    local on = category == self.category
    UI.setColor(on and Theme.panel or Theme.withAlpha(Theme.dim, 0.4))
    love.graphics.rectangle("fill", x, cy, cat_w, ch)
    love.graphics.setLineWidth(2)
    UI.setColor(on and Theme.coin or Theme.withAlpha(Theme.cream, 0.25))
    love.graphics.rectangle("line", x + 1, cy + 1, cat_w - 2, ch - 2)
    love.graphics.setColor(1, 1, 1, 1)
    local label = I18n.t(category:upper())
    love.graphics.setScissor(x, cy, cat_w, ch)
    UI.text(label, x + (cat_w - UI.textWidth(label, cat_size)) / 2,
      cy + (ch - UI.lineHeight(cat_size)) / 2, cat_size,
      on and Theme.ink or Theme.withAlpha(Theme.cream, 0.6))
    love.graphics.setScissor()
    self.category_rects[category] = { x = x, y = cy, w = cat_w, h = ch }
    x = x + cat_w + 4
  end
  if show_tags then
    UI.text("Q", x + 2, cy, tag_size, Theme.withAlpha(Theme.cream, 0.4))
    x = x + q_tag
  end

  local cleared, total = 0, 0
  for _, node in ipairs(self.nodes or {}) do
    total = total + 1
    if node.state == "cleared" then cleared = cleared + 1 end
  end
  local progress = I18n.t("%d / %d CLEARED", cleared, total)
  local pw = UI.textWidth(progress, land_size)
  if vw - 10 - pw > x + 16 then
    UI.text(progress, vw - 10 - pw, (h - label_h) / 2, land_size, Theme.cream)
  end
end

function Map:draw_edges()
  if not self.nodes then return end
  love.graphics.setLineWidth(5)
  for _, edge in ipairs(self.edges) do
    local a = self.by_id[edge[1]]
    local b = self.by_id[edge[2]]
    if a and b then
      local na, nb = self.nodes[a], self.nodes[b]
      local ax, ay = self:node_xy(na)
      local bx, by = self:node_xy(nb)
      -- The route, lit as far as the player has got. Not a gate: the dim
      -- half is "you have not been here yet", not "you may not go".
      local lit = na.state == "cleared"
      UI.setColor(Theme.ink, 0.55)
      love.graphics.line(ax, ay + 2, bx, by + 2)
      UI.setColor(lit and Theme.coin or Theme.withAlpha(Theme.cream, 0.45))
      love.graphics.line(ax, ay, bx, by)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

--- Which marker a node wears.
---
--- Two states, not three. `node_locked` — the padlock — is deliberately not
--- reachable from here (§4.7: every node is playable).
---
--- `node_boss` is a different silhouette rather than a recoloured circle
--- (`docs/design-review.md` §11), so the boss the premise is named after does
--- not read like node 5. `gate` has no marker because no content pack
--- contains one; it falls back to the quest marker.
--- The boss at the end of each map, by land and category (docs/art.md §4.2).
--- Drawn on the node card when the cursor is on a boss node, so the thing the
--- premise is named after is a face and not a number.
local BOSS = {
  ["rust.basic"] = "boss_autocomplete",
  ["rust.advanced"] = "boss_deadlock",
  ["rust.hacker"] = "boss_whiteboard",
  ["go.basic"] = "boss_nullptr",
  ["go.advanced"] = "boss_race",
  ["go.hacker"] = "boss_clock",
}

local function marker_for(node)
  if node.kind == "boss" then return "node_boss" end
  return "node_quest"
end

function Map:draw_nodes()
  if not self.nodes then return end
  -- **Art**, not type. A node marker is a picture, and a picture on a canvas
  -- half again as tall should be half again as big — that is the one thing
  -- `uiScale` is still right for. Type went the other way this round: see
  -- `Layout.uiScale`'s note for why a pixel face may not be multiplied by 1.5.
  local scale = Layout.uiScale()
  for i, node in ipairs(self.nodes) do
    local x, y = self:node_xy(node)
    local selected = i == self.cursor
    local base = (node.kind == "boss" and 44 or 34) * scale
    -- Every node breathes, a little, on its own phase; the selected one
    -- breathes harder. A board of perfectly still markers is the same
    -- "this is a menu" signal as a perfectly still mascot.
    local bob = Anim.bob(self.t, {
      amount = selected and 3 or 1.2,
      period = selected and 1.1 or 2.4,
      phase = (i % 7) / 7,
    })
    local size = base
    if selected then
      size = size + 4 * scale * Ease.cosine((self.t * 1.6) % 1)
    end

    -- A shadow grounds it. Without one a bobbing marker looks like it is
    -- sliding rather than lifting.
    UI.setColor(Theme.ink, 0.30)
    love.graphics.ellipse("fill", x, y + size * 0.34, size * 0.30, size * 0.10)
    love.graphics.setColor(1, 1, 1, 1)
    y = y + bob

    local drew = Assets.marker(marker_for(node), x, y, size)
    if not drew then
      -- No art: the old coloured disc, so the map still works.
      local r = size * 0.38
      local fill = Theme.panel
      if node.state == "cleared" then fill = Theme.admit end
      if node.kind == "boss" then fill = Theme.brick end
      UI.setColor(Theme.ink)
      love.graphics.circle("fill", x, y, r + 3)
      UI.setColor(fill)
      love.graphics.circle("fill", x, y, r)
    end

    local label = tostring(node.node)
    local nw = UI.textWidth(label, 9)
    UI.text(label, x - nw / 2, y - 5, 9, Theme.ink)

    -- A cleared node wears the stamp (SPEC §0: stamped CLEARED, for good).
    -- The sprite is a wordless ring by design — `docs/design-review.md` says
    -- the word is printed over it at runtime so it can be translated.
    if node.state == "cleared" then
      if Assets.marker("stamp_cleared", x, y, size * 1.15) then
        local w = UI.textWidth("CLEARED", 6)
        UI.text(I18n.t("CLEARED"), x - w / 2, y - 3, 6, Theme.cream)
      else
        UI.setColor(Theme.admit)
        love.graphics.circle("line", x, y, size * 0.5)
        love.graphics.setColor(1, 1, 1, 1)
      end
    end

    if (node.stars or 0) > 0 then
      local sw = 3 * 10
      UI.stars(x - sw / 2, y + size * 0.5 + 2, node.stars, 7)
    end

    -- The clear stamp lands with a shockwave (docs/art.md §7).
    local age = self.stamped[node.quest_id]
    if age and age < 0.9 then
      local k = Ease.expOut(age / 0.9)
      UI.setColor(Theme.coin, 1 - k)
      love.graphics.setLineWidth(3)
      love.graphics.circle("line", x, y, size * 0.5 + 34 * k)
      love.graphics.setColor(1, 1, 1, 1)
    end

    if selected then
      UI.setColor(Theme.coin)
      love.graphics.setLineWidth(2)
      love.graphics.circle("line", x, y, size * 0.62)
      love.graphics.setColor(1, 1, 1, 1)
    end
  end
end

--- Skynet's agents — the things that finished your sentences — drifting over
--- the overworld. Ambient only: they are not entities, they take no input and
--- they are behind everything. `docs/art.md` §4.2 calls them the ambient
--- antagonists, and without them the Skynet framing exists only in the story
--- text nobody re-reads.
function Map:draw_agents()
  if not Assets.image("agent_skynet") then return end
  local px, py, pw, ph = self:plate_rect()
  for i = 1, 3 do
    local phase = (self.t * 0.035 + i * 0.37) % 1
    local x = px + 30 + phase * (pw - 60)
    local y = py + 60 + math.sin(self.t * 0.5 + i * 2.1) * 26 + (i - 2) * ph * 0.22
    Assets.marker("agent_skynet", x, y, 46 + i * 5, { alpha = 0.20 })
  end
end

--- Mei, standing on a node or walking between two.
---
--- The strip is `art/walk_mei.png`: four 64x96 cells with a `boxes` array
--- (plural) in the manifest, one per frame — `box` on that entry is nil and
--- reading it would silently place her by the corner of her cell.
---
--- **On the frame rate.** DESIGN flagged that frames 2 and 4 are both
--- "passing" poses and are not identical, so a slow cycle can read as a
--- slight limp. Watched in a real window: at 4 fps it does, visibly; by about
--- 7 the eye stops resolving the two passing frames as different poses and it
--- reads as a walk. 7 is what is here. The cycle also only runs while she is
--- moving — a standing figure cycling on the spot is worse than either.
function Map:draw_mei()
  local x, y, facing, moving = self:mei_position()
  if not x then return end
  -- Art again: Mei is a sprite, so she grows with the canvas.
  local height = 46 * Layout.uiScale()

  -- A soft shadow so she sits on the plate rather than floating over it.
  UI.setColor(Theme.ink, 0.28)
  love.graphics.ellipse("fill", x, y + 2, height * 0.20, height * 0.07)
  love.graphics.setColor(1, 1, 1, 1)

  local frame = moving and (math.floor(self.t * Map.WALK_FPS) + 1) or 1
  if not Assets.frame("walk_mei", frame, x, y + 2, height, { flip = facing < 0 }) then
    -- No strip: the standing portrait, which at least says who is here.
    Assets.sprite("sprite_mei", x, y + 2, height, { flip = facing < 0 })
  end
end

function Map:draw_node_card(node)
  local vw, vh = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  local w = portrait and (vw - 24) or math.min(460, vw - 40)
  -- Tall enough for the last row. The difficulty bar and the "needs …" line
  -- were both added after this number was first picked, and the blocker — the
  -- one thing a locked node has to tell you — was the line that fell off.
  -- Measured from its four rows of type rather than fixed at 112: the title,
  -- the id, the state, and the difficulty/stars row, plus a last line for the
  -- suggested route.
  local title_h, id_h = UI.lineHeight(11), UI.lineHeight(7)
  local state_h, meta_h = UI.lineHeight(9), UI.lineHeight(7)
  -- The boss portrait's width is needed before the height, because the
  -- title wraps around it — and the title's line count decides the height.
  local boss_w = 0
  if node.kind == "boss" then
    local boss = BOSS[self.land .. "." .. self.category]
    if boss and Assets.image(boss) then boss_w = 78 end
  end
  -- The card's own width, minus the boss portrait when there is one. A quest
  -- title is content and can be any length, so this is the one line on the
  -- screen that must be given a width rather than trusted to be short — and
  -- the card has to be as tall as the lines that width makes of it, or the
  -- second line of the title is printed through the id (portrait, step 4).
  local title_w = w - 24 - boss_w
  local title = ("%02d  %s"):format(node.node, node.title or "")
  local title_lines = math.max(1, #UI.wrap(title, title_w, 11))
  local id_lines = math.max(1, #UI.wrap(node.quest_id or "", title_w, 7))
  local h = 10 + title_lines * title_h + 2 + id_lines * id_h + 6 + state_h + 6
    + math.max(meta_h, UI.lineHeight(8)) + 6 + id_h + 8
  local x = portrait and 12 or (vw - w - 16)
  local y = vh - h - UI.footerHeight() - 10

  UI.panel(x, y, w, h, {
    fill = Theme.withAlpha(Theme.navy, 0.94),
    tint = Theme.land[self.land],
  })
  -- The boss gets its portrait, standing on the card's baseline. It is the
  -- thing the premise is named after and it was drawn exactly like node 5.
  if boss_w > 0 then
    Assets.sprite(BOSS[self.land .. "." .. self.category], x + w - boss_w / 2 - 6, y + h - 8, h - 24)
  end
  local color = Theme.cream
  local r1 = y + 10
  local r2 = r1 + title_lines * title_h + 2
  local r3 = r2 + id_lines * id_h + 6
  local r4 = r3 + state_h + 6
  UI.text(title, x + 12, r1, 11, color, "left", title_w)
  UI.text(node.quest_id or "", x + 12, r2, 7, Theme.withAlpha(color, 0.6),
    "left", title_w)

  local state_color = ({ open = Theme.coin, cleared = Theme.admit })[node.state]
    or Theme.cream
  UI.text(I18n.t((node.state or "?"):upper()), x + 12, r3, 9, state_color)
  -- Difficulty is a segmented bar; stars are stars. Two scales, two shapes,
  -- and a row of text between them (design review §4).
  local star = math.max(10, math.floor(UI.lineHeight(7) * 0.8))
  local pip = math.max(6, math.floor(star * 0.6))
  local dl = I18n.t("DIFFICULTY") .. " "
  UI.text(dl, x + 12, r4, 7, Theme.withAlpha(color, 0.6))
  UI.pips(x + 12 + UI.textWidth(dl, 7), r4, node.difficulty or 1, pip)
  local attempts = I18n.t("%d ATTEMPTS", node.attempts or 0)
  UI.text(attempts, x + w - 12 - boss_w - UI.textWidth(attempts, 8), r4, 8,
    Theme.withAlpha(color, 0.7))
  local sl = I18n.t("STARS") .. " "
  UI.text(sl, x + w - 12 - boss_w - 3 * (star + 3) - UI.textWidth(sl, 7), r3, 7,
    Theme.withAlpha(color, 0.6))
  UI.stars(x + w - 12 - boss_w - 3 * (star + 3), r3, node.stars or 0, star)

  -- `requires` is the suggested route, and saying so is the whole point: it
  -- answers "where next" without ever being a refusal.
  if node.state ~= "cleared" and node.requires and #node.requires > 0 then
    local after = node.requires[1]
    local blocker = self.by_id[after] and self.nodes[self.by_id[after]]
    if blocker and blocker.state ~= "cleared" then
      UI.text(I18n.t("SUGGESTED AFTER %s", after), x + 12, y + h - 8 - id_h, 7,
        Theme.withAlpha(Theme.cyan, 0.8))
    end
  end
end

-- -------------------------------------------------------------------- input

--- Arrow keys move to the nearest node in that direction, which on a winding
--- overworld is what a player means — a list index would jump across the map.
function Map:step(dx, dy)
  local from = self:node_at(self.cursor)
  if not from then return end
  local fx, fy = self:node_xy(from)
  local best, best_score = nil, nil
  for i, node in ipairs(self.nodes) do
    if i ~= self.cursor then
      local x, y = self:node_xy(node)
      local vx, vy = x - fx, y - fy
      local along = vx * dx + vy * dy
      if along > 0 then
        local across = math.abs(vx * dy - vy * dx)
        local score = along + across * 2.5
        if not best_score or score < best_score then
          best, best_score = i, score
        end
      end
    end
  end
  if best then
    self.cursor = best
    self.picked_at = Anim.now()
    SFX.play("move")
    self:walk_to(best)
  end
end

function Map:keypressed(key)
  -- **Any key lands her immediately.** Not just the one that started it: a
  -- player reaching for the next thing has already decided, and an animation
  -- that eats that keystroke is a toll.
  -- An iris in flight: any key lands now rather than waiting it out.
  if self.iris then
    self:enter_quest()
    return true
  end
  if self.walk and key ~= "escape" then
    self:skip_walk()
    if key == "return" or key == "kpenter" or key == "space" then return true end
  end
  if key == "left" then self:step(-1, 0); return true end
  if key == "right" then self:step(1, 0); return true end
  if key == "up" then self:step(0, -1); return true end
  if key == "down" then self:step(0, 1); return true end
  if key == "return" or key == "kpenter" or key == "space" then self:open_node(); return true end
  if key == "tab" then self:cycle_land(); return true end
  if key == "q" then self:cycle_category(); return true end
  if key == "r" then self:refresh(); return true end
  if key == "s" then self.app:go("search"); return true end
  if key == "t" then self.app:go("stats"); return true end
  if key == "a" then self.app:go("ai"); return true end
  if key == "p" then self.app:go("playground"); return true end
  return false
end

function Map:mousepressed(x, y)
  local function inside(r)
    return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
  end
  for land, rect in pairs(self.land_rects or {}) do
    if inside(rect) then self:switch(land, self.category); return end
  end
  for category, rect in pairs(self.category_rects or {}) do
    if inside(rect) then self:switch(self.land, category); return end
  end
  if not self.nodes then return end
  for i, node in ipairs(self.nodes) do
    local nx, ny = self:node_xy(node)
    if (x - nx) ^ 2 + (y - ny) ^ 2 <= 22 * 22 then
      if self.walk then
        self:skip_walk()
        return
      end
      if self.cursor == i then
        self:open_node()
      else
        self.cursor = i
        SFX.play("move")
        self:walk_to(i)
      end
      return
    end
  end
end

return Map
