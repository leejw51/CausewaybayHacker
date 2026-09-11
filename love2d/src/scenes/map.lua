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
local SFX = require("src.sfx")
local Ease = require("src.ease")

local Map = {}
Map.__index = Map

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
      -- Every node is playable now, so "where was I" is the only useful
      -- question: the earliest one not yet cleared, which is where the
      -- suggested route has got to.
      self.cursor = 1
      for i, node in ipairs(self.nodes) do
        if node.state ~= "cleared" then self.cursor = i; break end
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
  SFX.play("select")
  self.app.quest_id = node.quest_id
  self.app:go("quest", { quest_id = node.quest_id, land = self.land, category = self.category })
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

  self:draw_agents()
  self:draw_edges()
  self:draw_nodes()
  self:draw_mei()

  -- The header band.
  local tint = Theme.land[self.land] or Theme.coin
  UI.setColor(Theme.ink, 0.85)
  love.graphics.rectangle("fill", 0, 0, vw, 56)
  love.graphics.setColor(1, 1, 1, 1)
  local s = Layout.uiScale()
  UI.text(("%s / %s"):format(self.land:upper(), self.category:upper()),
    12, 12, math.floor(13 * s), tint)

  local cleared, total = 0, 0
  for _, node in ipairs(self.nodes or {}) do
    total = total + 1
    if node.state == "cleared" then cleared = cleared + 1 end
  end
  local progress = ("%d / %d CLEARED"):format(cleared, total)
  UI.text(progress, vw - 12 - UI.textWidth(progress, 10), 14, 10, Theme.cream)

  local node = self:node_at(self.cursor)
  if node then
    self:draw_node_card(node)
  elseif self.error then
    UI.text(self.error, 0, vh / 2, 10, Theme.red, "center", vw)
  elseif not self.nodes then
    UI.text("asking the server…", 0, vh / 2, 10,
      Theme.withAlpha(Theme.cream, 0.7), "center", vw)
  end

  self.app:footer(self.walk
    and "ANY KEY skip"
    or "ARROWS node   ENTER play   S search   T stats   A ai   ESC back")
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
  local scale = Layout.uiScale()
  for i, node in ipairs(self.nodes) do
    local x, y = self:node_xy(node)
    local selected = i == self.cursor
    local base = (node.kind == "boss" and 44 or 34) * scale
    local size = base
    if selected then
      size = size + 4 * scale * Ease.cosine((self.t * 1.6) % 1)
    end

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
        UI.text("CLEARED", x - w / 2, y - 3, 6, Theme.cream)
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
  local scale = Layout.uiScale()
  local height = 46 * scale

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
  local h = 112
  local x = portrait and 12 or (vw - w - 16)
  local y = vh - h - 30

  UI.panel(x, y, w, h, {
    fill = Theme.withAlpha(Theme.navy, 0.94),
    tint = Theme.land[self.land],
  })
  -- The boss gets its portrait, standing on the card's baseline. It is the
  -- thing the premise is named after and it was drawn exactly like node 5.
  local boss_w = 0
  if node.kind == "boss" then
    local boss = BOSS[self.land .. "." .. self.category]
    if boss and Assets.image(boss) then
      boss_w = 78
      Assets.sprite(boss, x + w - boss_w / 2 - 6, y + h - 8, h - 24)
    end
  end
  local color = Theme.cream
  UI.text(("%02d  %s"):format(node.node, node.title or ""), x + 12, y + 10, 11, color)
  UI.text(node.quest_id or "", x + 12, y + 28, 7, Theme.withAlpha(color, 0.6))

  local state_color = ({ open = Theme.coin, cleared = Theme.admit })[node.state]
    or Theme.cream
  UI.text((node.state or "?"):upper(), x + 12, y + 44, 9, state_color)
  -- Difficulty is a segmented bar; stars are stars. Two scales, two shapes,
  -- and a row of text between them (design review §4).
  UI.text("DIFFICULTY", x + 12, y + 62, 7, Theme.withAlpha(color, 0.6))
  UI.pips(x + 12 + UI.textWidth("DIFFICULTY ", 7), y + 60, node.difficulty or 1, 5)
  local attempts = ("%d ATTEMPTS"):format(node.attempts or 0)
  UI.text(attempts, x + w - 12 - boss_w - UI.textWidth(attempts, 8), y + 62, 8,
    Theme.withAlpha(color, 0.7))
  UI.text("STARS", x + w - 12 - boss_w - 3 * 13 - UI.textWidth("STARS ", 7), y + 46, 7,
    Theme.withAlpha(color, 0.6))
  UI.stars(x + w - 12 - boss_w - 3 * 13, y + 44, node.stars or 0, 10)

  -- `requires` is the suggested route, and saying so is the whole point: it
  -- answers "where next" without ever being a refusal.
  if node.state ~= "cleared" and node.requires and #node.requires > 0 then
    local after = node.requires[1]
    local blocker = self.by_id[after] and self.nodes[self.by_id[after]]
    if blocker and blocker.state ~= "cleared" then
      UI.text("SUGGESTED AFTER " .. after, x + 12, y + h - 16, 7,
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
    SFX.play("move")
    self:walk_to(best)
  end
end

function Map:keypressed(key)
  -- **Any key lands her immediately.** Not just the one that started it: a
  -- player reaching for the next thing has already decided, and an animation
  -- that eats that keystroke is a toll.
  if self.walk and key ~= "escape" then
    self:skip_walk()
    if key == "return" or key == "kpenter" or key == "space" then return true end
  end
  if key == "left" then self:step(-1, 0); return true end
  if key == "right" then self:step(1, 0); return true end
  if key == "up" then self:step(0, -1); return true end
  if key == "down" then self:step(0, 1); return true end
  if key == "return" or key == "kpenter" or key == "space" then self:open_node(); return true end
  if key == "r" then self:refresh(); return true end
  if key == "s" then self.app:go("search"); return true end
  if key == "t" then self.app:go("stats"); return true end
  if key == "a" then self.app:go("ai"); return true end
  return false
end

function Map:mousepressed(x, y)
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
