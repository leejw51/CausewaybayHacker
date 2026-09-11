-- MAP. The Super Mario World overworld, from `world.map` (PROTOCOL §4.7).
--
-- Everything drawn here is the server's: the node positions are `x`/`y` in
-- 0..1 of the map image (SPEC §12), the paths are the `edges` array — given
-- explicitly "so a client never has to infer the overworld's shape" — and
-- `state` is `locked` / `open` / `cleared` as the server computed it. This
-- screen has no opinion about which node should light up next.
--
-- `progress.update` (§4.19) patches the map in place, including the nodes it
-- unlocked, which is what keeps two windows in step without a refetch. A
-- reconnect refetches anyway (§6 rule 5), because a missed event is exactly
-- what a drop causes.

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
      self.by_id = {}
      for i, node in ipairs(self.nodes) do
        self.by_id[node.quest_id] = i
      end
      -- Land on the first node the player can actually play.
      for i, node in ipairs(self.nodes) do
        if node.state == "open" then self.cursor = i; break end
      end
      self.cursor = math.max(1, math.min(#self.nodes, self.cursor))
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
  for _, id in ipairs(payload.unlocked or {}) do
    local i = self.by_id[id]
    if i and self.nodes[i].state == "locked" then
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

function Map:open_node()
  local node = self:node_at(self.cursor)
  if not node then return end
  if node.state == "locked" then
    SFX.play("locked")
    -- §3.3's `locked` names the blocker; the map already knows it.
    local blocker = (node.requires or {})[1]
    self.app:toast(blocker and ("locked — clear " .. blocker) or "locked")
    return
  end
  SFX.play("select")
  self.app.quest_id = node.quest_id
  self.app:go("quest", { quest_id = node.quest_id, land = self.land, category = self.category })
end

function Map:update(dt)
  self.t = self.t + dt
  for id, age in pairs(self.stamped) do
    self.stamped[id] = age + dt
  end
end

-- ------------------------------------------------------------------ drawing

function Map:draw()
  local vw, vh = Layout.vw, Layout.vh
  local px, py, pw, ph = self:plate_rect()

  Assets.cover(Layout.isPortrait() and "map_bg_p" or "map_bg", px, py, pw, ph)
  local haze = Theme.haze[self.land] or Theme.haze.rust
  love.graphics.setColor(haze)
  love.graphics.rectangle("fill", px, py, pw, ph)
  love.graphics.setColor(1, 1, 1, 1)

  self:draw_edges()
  self:draw_nodes()

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

  self.app:footer("ARROWS node   ENTER play   S search   T stats   A ai   ESC back")
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
      -- A path beyond a locked node is drawn dim (docs/art.md §6).
      local lit = na.state == "cleared" and nb.state ~= "locked"
      UI.setColor(Theme.ink, 0.55)
      love.graphics.line(ax, ay + 2, bx, by + 2)
      UI.setColor(lit and Theme.coin or Theme.withAlpha(Theme.dim, 0.8))
      love.graphics.line(ax, ay, bx, by)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function Map:draw_nodes()
  if not self.nodes then return end
  for i, node in ipairs(self.nodes) do
    local x, y = self:node_xy(node)
    local selected = i == self.cursor
    local r = node.kind == "boss" and 17 or 13
    if selected then
      r = r + 2 + 2 * Ease.cosine((self.t * 1.6) % 1)
    end

    local fill = Theme.dim
    if node.state == "open" then fill = Theme.panel end
    if node.state == "cleared" then fill = Theme.admit end
    if node.kind == "boss" then fill = node.state == "locked" and Theme.dim or Theme.brick end
    if node.kind == "gate" then fill = node.state == "locked" and Theme.dim or Theme.wood end

    UI.setColor(Theme.ink)
    love.graphics.circle("fill", x, y, r + 3)
    UI.setColor(fill)
    love.graphics.circle("fill", x, y, r)

    UI.text(tostring(node.node), x - 8, y - 5, 9,
      node.state == "locked" and Theme.withAlpha(Theme.cream, 0.6) or Theme.ink)

    if (node.stars or 0) > 0 then
      UI.stars(x - 15, y + r + 3, node.stars, 7)
    end

    -- The clear stamp lands with a shockwave (docs/art.md §7).
    local age = self.stamped[node.quest_id]
    if age and age < 0.9 then
      local k = Ease.expOut(age / 0.9)
      UI.setColor(Theme.coin, 1 - k)
      love.graphics.setLineWidth(3)
      love.graphics.circle("line", x, y, r + 30 * k)
      love.graphics.setColor(1, 1, 1, 1)
    end

    if selected then
      UI.setColor(Theme.coin)
      love.graphics.setLineWidth(2)
      love.graphics.circle("line", x, y, r + 6)
      love.graphics.setColor(1, 1, 1, 1)
    end
  end
end

function Map:draw_node_card(node)
  local vw, vh = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  local w = portrait and (vw - 24) or math.min(440, vw - 40)
  local h = 92
  local x = portrait and 12 or (vw - w - 16)
  local y = vh - h - 30

  UI.panel(x, y, w, h, {
    fill = Theme.withAlpha(Theme.navy, 0.94),
    tint = Theme.land[self.land],
  })
  local color = node.state == "locked" and Theme.dim or Theme.cream
  UI.text(("%02d  %s"):format(node.node, node.title or ""), x + 12, y + 10, 11, color)
  UI.text(node.quest_id or "", x + 12, y + 28, 7, Theme.withAlpha(color, 0.6))

  local state_color = ({
    locked = Theme.dim, open = Theme.coin, cleared = Theme.admit,
  })[node.state] or Theme.cream
  UI.text((node.state or "?"):upper(), x + 12, y + 44, 9, state_color)
  UI.text(("DIFFICULTY %d"):format(node.difficulty or 1), x + 12, y + 60, 8,
    Theme.withAlpha(color, 0.7))
  UI.text(("%d ATTEMPTS"):format(node.attempts or 0),
    x + w - 12 - UI.textWidth(("%d ATTEMPTS"):format(node.attempts or 0), 8), y + 60, 8,
    Theme.withAlpha(color, 0.7))
  UI.stars(x + w - 12 - 3 * 13, y + 42, node.stars or 0, 10)

  if node.state == "locked" and node.requires and #node.requires > 0 then
    UI.text("needs " .. node.requires[1], x + 12, y + h - 14, 7, Theme.red)
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
  end
end

function Map:keypressed(key)
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
      if self.cursor == i then
        self:open_node()
      else
        self.cursor = i
        SFX.play("move")
      end
      return
    end
  end
end

return Map
