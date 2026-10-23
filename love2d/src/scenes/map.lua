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
--
-- ## The look (`docs/love2d-ui.md`)
--
-- The header is a bar of chips: the land as a badge in its colour with its
-- mascot, the other lands as their mascots, the roads as chips with the
-- current one gold, and RESET THIS ROAD as a ghost at the right end. The
-- chips wrap to a second row when the canvas is narrow rather than squeeze;
-- the chrome never moves with F12, so the row can never overprint itself.
-- The node card is a card: the number, the title on one line with an
-- ellipsis (the quest id is gone — it wrapped), a status chip, the stars,
-- the difficulty pips, the attempts, PLAY as the screen's one primary
-- button, and the road's bar. Docked top-right in landscape; a sheet above
-- the footer in portrait, with the map stopping above it so no half-node
-- peeks out from under it.

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Ease = require("src.ease")
local Anim = require("src.anim")
local Juice = require("src.juice")
local Fx = require("src.fx")
local Land = require("src.land")

local Map = {}
Map.__index = Map


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
    hover = nil,    -- what the pointer is over: "back", "reset", "play", a land, a road
    header_h = UI.headerHeight(),
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

  Juice.forget("map:")
  self:refresh()
end

function Map:leave()
  self.app.session:off_all(self.subscriptions)
  self.subscriptions = nil
  -- A question nobody is looking at any more is not a question.
  self.confirm_reset = nil
  self.confirm_rects = nil
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
  -- A land without this road — TAB from LUA × HACKER to REMIX —
  -- lands on the last road it does have.
  local roads = Land.roads(land)
  local has = false
  for _, road in ipairs(roads) do
    if road == category then has = true end
  end
  if not has then category = roads[#roads] end
  if land == self.land and category == self.category then return end
  self:cancel_reset()

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
  self.app:toast(("%s / %s"):format(Land.name(land), I18n.t(Land.category_label(category))))
  self:refresh()
end

--- The lands the switcher offers — the header's chips and TAB — in SPEC
--- §0's order: the ones the server reported in `world.lands` (§4.6, kept by
--- the session from whichever screen asked last), or every land the client
--- knows when it has not heard yet. A land this client knows and the server
--- does not is a `world.map` the server cannot answer.
function Map:lands()
  local session = self.app and self.app.session
  return Land.known(session and session.lands)
end

--- TAB — the other land, **keeping the category**.
---
--- Somebody comparing how Rust and Go do concurrency wants to land on the
--- concurrency map, not at the top of GO BASIC.
function Map:cycle_land()
  local LANDS = self:lands()
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
  local roads = Land.roads(self.land)
  for i, category in ipairs(roads) do
    if category == self.category then
      self:switch(self.land, roads[i % #roads + 1])
      return
    end
  end
  self:switch(self.land, roads[1])
end

function Map:refresh()
  self.error = nil
  -- PROTOCOL §4.7: node titles in the interface's language where a
  -- translation exists; each node carries `text_locale` saying which it got.
  self.asked_lang = I18n.lang
  self.app.session:request("world.map",
    { land = self.land, category = self.category, locale = I18n.lang },
    function(ok, payload, why)
      if not ok then
        self.error = why.player
        return
      end
      self.nodes = payload.nodes or {}
      self.edges = payload.edges or {}
      -- §4.7: how far along this road the player is, counted by the server.
      -- Kept, never recomputed: two clients each counting for themselves is
      -- two arithmetics to keep in step, and the number a player reads
      -- should be the record's. An older server sends none of these, and
      -- then nothing is drawn rather than a figure this screen invented.
      if payload.cleared and payload.total then
        self.tally = {
          cleared = payload.cleared,
          total = payload.total,
          stars = payload.stars or 0,
          stars_total = payload.stars_total or (payload.total * 3),
        }
      else
        self.tally = nil
      end
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
      -- `rust.basic.12.stack-queue` as the first element. Nothing here depends on
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
        self.cursor = Map.next_index(self.nodes) or self.cursor
      end
      self.cursor = math.max(1, math.min(#self.nodes, self.cursor))
      -- She appears where the player left off rather than walking in from
      -- node 1 every time the map is opened.
      self.at = self.cursor
      self.walk = nil
      self.adjacency = nil
      Juice.forget("map:card")
    end)
end

--- Where the suggested route has got to: the first node in pack order the
--- player has not cleared, or nil on a map with nothing left. The cursor
--- falls back to it when the player has never been here, and the hand marks
--- it — one hand, on the node to do next. Pure, so it can be checked
--- headless.
function Map.next_index(nodes)
  for i, node in ipairs(nodes or {}) do
    if node.state ~= "cleared" then return i end
  end
  return nil
end

--- The stamp's tint for a cleared node: nil (the ring as painted) until the
--- node has been re-cleared, cyan after. Pure, so it can be checked headless.
function Map.stamp_color(practised)
  if (tonumber(practised) or 0) > 0 then
    return { Theme.cyan[1], Theme.cyan[2], Theme.cyan[3], 1 }
  end
  return nil
end

--- The road's completion, as a line: the count and the percentage where
--- there is room for them, the percentage alone where there is not, and
--- nothing at all when the server did not say (an older server, or a map
--- that has not loaded). Pure — `measure` is the text measurer — so the
--- choice can be checked headless.
---
--- The percentage is formatted rather than translated: `"%d%%"` has no word
--- in it, and an entry identical to the English in every language is what
--- `tests/test_i18n.lua` counts as an untranslated file.
function Map.tally_label(cleared, total, room, measure)
  cleared, total = tonumber(cleared), tonumber(total)
  if not cleared or not total or total <= 0 then return nil end
  local pct = math.floor((cleared / total) * 100 + 0.5)
  local full = I18n.t("%d/%d CLEARED · %d%%", cleared, total, pct)
  if not measure or measure(full) <= (room or math.huge) then return full end
  local short = ("%d%%"):format(pct)
  if measure(short) <= (room or math.huge) then return short end
  return nil
end

--- Is there a road here to reset?
---
--- Every road, once the map has loaded. It used to want a cleared street
--- first, on the reasoning that a road with no stamps had nothing to take
--- back. RESET takes the drafts and the undo stacks with the stamps now
--- (PROTOCOL §4.7b), and a player who has written half a program on every
--- node of ADVANCED and cleared none of them has a road full of work that no
--- count on this screen can see — `cleared`, `stars` and `attempts` are all
--- zero there, because `attempts` counts submits. The question the button
--- asks is the guard; a reset of a road nobody has touched is `reset: 0`.
---
--- Still nil-guarded: a map that has not answered yet has no road to name in
--- the question. Pure, so the rule is checkable headless.
function Map.reset_offered(tally)
  return tally ~= nil and (tonumber(tally.total) or 0) > 0
end

--- The road, named the way the switch names it.
---
--- Deliberately the same shape as the toast in `Map:switch` — land name,
--- slash, translated category — because the player has just read that
--- sentence, and a confirm panel that names the road differently from the
--- row above it is a panel about some other road.
function Map.road_name(land, category)
  return ("%s / %s"):format(Land.name(land), I18n.t(Land.category_label(category)))
end

--- What the confirm panel asks, with the road named and the cost counted.
---
--- **The order of the two numbers is load-bearing.** Lua's `string.format`
--- has no positional arguments, so every translation of this sentence has to
--- say the cleared count before the total; a translation that reads more
--- naturally the other way around would print "27 of 3" and pass the
--- specifier check in `tests/test_i18n.lua`, which only compares which
--- specifiers appear. `tests/test_lands.lua` pins the order in Korean.
function Map.reset_body(road, cleared, total)
  return I18n.t("%s goes back to untouched — %d of %d streets lose their "
    .. "stamp and stars, and every editor on the road goes back to its "
    .. "starter. Your XP and your mistakes are kept, and clearing "
    .. "them again pays no XP.", road or "?", tonumber(cleared) or 0,
    tonumber(total) or 0)
end

--- The button asks; it does not act.
---
--- The question is a modal (`UI.modal`) drawn by the scene that raised it.
--- The road, the count and the total are copied out **now**, so the
--- sentence on screen keeps naming the road it was opened for even if
--- something else moves underneath.
function Map:ask_reset()
  if self.iris or self.walk then return end
  if not Map.reset_offered(self.tally) then return end
  SFX.play("move")
  UI.modalReset("map:reset")
  self.confirm_reset = {
    road = Map.road_name(self.land, self.category),
    cleared = self.tally.cleared,
    total = self.tally.total,
  }
end

function Map:cancel_reset()
  if not self.confirm_reset then return end
  self.confirm_reset = nil
  self.confirm_rects = nil
end

--- PROTOCOL §4.7b: clear this road's progress, then ask the map again.
---
--- The answer carries the four totals back "so a client redraws without
--- asking again", and they are not used here on purpose. The stamps, the
--- stars, the lit half of every edge and the suggested next node all come
--- out of `world.map`, and patching four numbers locally would leave a screen
--- that agrees with the server about the tally and disagrees about
--- everything under it. One refresh, one source.
function Map:do_reset()
  self:cancel_reset()
  self.app.session:request("world.reset",
    { land = self.land, category = self.category },
    function(ok, _, why)
      if not ok then
        -- Not `self.error`: that line is only drawn where the node card is
        -- not, and after a failed reset the card is still there. The toast
        -- is what this scene says over a map that is still on screen.
        self.app:toast((why and why.player)
          or I18n.t("the reset did not go through"))
        return
      end
      self:refresh()
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
    if payload.practised then node.practised = payload.practised end
    if payload.state == "cleared" then
      self.stamped[payload.quest_id] = 0
      SFX.play("stamp")
      -- A clear pays out on the map: coins from the node that was stamped.
      local x, y = self:node_xy(node)
      Fx.burst(x, y, "coins")
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
---
--- Under the header, which is one row of chips or two (`draw_header`) —
--- measured on the last draw, so the nodes never sit under a row of road
--- chips — and, upright, above the node card's sheet, so no node is ever
--- half under it.
function Map:plate_rect()
  local vw, vh = Layout.vw, Layout.vh
  local top = math.max(UI.headerHeight(), self.header_h or 0)
  local bottom = UI.footerHeight()
  if Layout.isPortrait() then bottom = bottom + self:card_height() end
  return 0, top, vw, math.max(1, vh - top - bottom)
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
  UI.press("map:play", self.play_rect, { sfx = false })
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
  if self.asked_lang and self.asked_lang ~= I18n.lang then
    -- The language changed under an open map; the titles came from the
    -- server in the old one. `refresh` records the language it asks in
    -- before the reply lands, so this is once per change, not per frame.
    self:refresh()
  end
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

--- The plate behind a map, as the names `Assets.pick` tries in order.
---
--- `art/` ships a plate per land — `map_<land>` and `map_<land>_p` for
--- portrait — so the name is built from the land and a fourth land costs
--- two files, not a branch here. The placeholder `map_bg` is the fallback
--- for a checkout where `art/` is not readable, or where a land's plate has
--- not been painted yet.
function Map.plate_names(land, portrait)
  local suffix = portrait and "_p" or ""
  return "map_" .. land .. suffix, "map_bg" .. suffix, "map_bg"
end

--- The land's colour, laid over the plate. A land the theme has no haze for
--- gets Rust's, which is a wrong colour rather than no map.
function Map.haze(land)
  return Theme.haze[land] or Theme.haze.rust
end

--- The scene's key hints, in priority order: the footer keeps the longest
--- prefix that fits.
function Map:hints()
  if self.confirm_reset then return I18n.t("ESC keep my progress   CLICK to reset") end
  -- Any key lands her; SPACE is the one the cap names.
  if self.walk then return { { key = "SPACE", verb = I18n.t("skip") } } end
  -- **Not a listing of TAB and Q.** Those two switch the land and the road,
  -- and both are chips in this screen's own header — the row that exists
  -- precisely so the switch is visible.
  return I18n.t("ENTER play   ARROWS node   T stats   P playground   ESC back")
end

function Map:draw()
  local vw, vh = Layout.vw, Layout.vh
  local px, py, pw, ph = self:plate_rect()

  UI.setColor(Theme.felt)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  Assets.cover(Assets.pick(Map.plate_names(self.land, Layout.isPortrait())),
    px, py, pw, ph)
  love.graphics.setColor(Map.haze(self.land))
  love.graphics.rectangle("fill", px, py, pw, ph)
  love.graphics.setColor(1, 1, 1, 1)

  -- `art/fg_wires` was drawn here for one round and taken out again. It is a
  -- foreground layer for an **elevation** — a street seen from the side — and
  -- every full-screen plate in this client is either a top-down town or a
  -- room. A slung cable over a top-down town is a cable lying in the road: it
  -- crossed six nodes and two streets and read as damage. The asset stays
  -- unused on purpose.

  self:draw_agents()
  self:draw_edges()
  self:draw_nodes()
  self:draw_mei()

  self:draw_header()

  local node = self:node_at(self.cursor)
  self.play_rect = nil
  if node then
    self:draw_node_card(node)
  elseif self.error then
    UI.label(self.error, 0, math.floor(vh / 2), "label", { width = vw, align = "center", color = Theme.redA })
  elseif not self.nodes then
    UI.label(I18n.t("asking the server…"), 0, math.floor(vh / 2), "label",
      { width = vw, align = "center", color = Theme.mute })
  end

  self:draw_iris()
  self:draw_confirm()

  self.app:footer(self:hints())
end

--- The confirm sheet, over the map it is about.
---
--- **Enter does not take the destructive button.** ESC, ENTER and SPACE all
--- land on KEEP MY PROGRESS — a player who reached for the key that has
--- meant "yes, go on" on every other screen in this client keeps their road —
--- and RESET IT is reached by pointing at it, which is a thing nobody does by
--- reflex. KEEP is the lit button for the same reason, and RESET IT wears
--- the danger colour.
function Map:draw_confirm()
  if not self.confirm_reset then return end
  local ask = self.confirm_reset
  local body = Map.reset_body(ask.road, ask.cleared, ask.total)
  local pad = Layout.isPortrait() and Theme.space.lg or Theme.space.xl
  local w = math.min(520, Layout.vw - pad * 2)
  local inner = w - pad * 2
  local body_h = UI.readHeight(body, inner)
  -- The two buttons share a row when their labels fit it, else they stack.
  local keep_label, go_label = I18n.t("KEEP MY PROGRESS"), I18n.t("RESET IT")
  local keep_need, bh = UI.buttonSize(keep_label)
  local go_need = UI.buttonSize(go_label)
  bh = math.max(Theme.control.buttonM, bh)
  local gap = Theme.space.md
  local stacked = keep_need + gap + go_need > inner
  local rows_h = stacked and (bh * 2 + gap) or bh
  local x, y, cw, ch, close, sheet = UI.modal({ id = "map:reset", title = I18n.t("WALK IT AGAIN?"),
    strip = Theme.redA, w = w, h = body_h + Theme.space.lg + rows_h })
  love.graphics.setScissor(x, y, cw, ch)
  UI.read(body, x, y, cw)
  local keep, go
  if stacked then
    keep = { x = x, y = y + ch - rows_h, w = cw, h = bh }
    go = { x = x, y = y + ch - bh, w = cw, h = bh }
  else
    local row = y + ch - bh
    local keep_w = math.max(keep_need, math.floor((cw - gap) / 2))
    keep = { x = x, y = row, w = keep_w, h = bh }
    go = { x = x + keep_w + gap, y = row, w = cw - keep_w - gap, h = bh }
  end
  local px, py = UI.pointer()
  UI.button(keep.x, keep.y, keep.w, keep.h, keep_label,
    UI.inside(go, px, py) and "normal" or "hot", nil, { variant = "secondary", id = "map:keep" })
  UI.button(go.x, go.y, go.w, go.h, go_label,
    UI.inside(go, px, py) and "hot" or "normal", nil, { variant = "danger", id = "map:go" })
  love.graphics.setScissor()
  self.confirm_rects = { keep = keep, go = go, close = close, sheet = sheet }
end

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

--- A mascot inside a `box` square, standing on `bottom`.
local function mascot(name, x, bottom, box, opts)
  if not name then return false end
  local b = Assets.box[name]
  local image = Assets.image(name)
  if not image then return false end
  local iw, ih = image:getDimensions()
  local ink_w = (b and b.w and b.w > 0) and b.w or iw
  local ink_h = (b and b.h and b.h > 0) and b.h or ih
  local height = box
  if ink_w > ink_h then height = box * ink_h / ink_w end
  return Assets.sprite(name, x, bottom, height, opts)
end

--- The header: the land badge, the other lands' mascots, the road chips
--- and RESET THIS ROAD, measured from the type in them and wrapped onto a
--- second (or third) row rather than squeezed.
---
--- The switch has to be **visible**. A keybinding nobody can see is not a
--- feature, and the whole reason for this row is that reaching HACKER used to
--- cost a trip out to two other screens. `CausewaybayGolang` puts "the three
--- big buttons" for its language tracks on its map for the same reason.
---
--- What gives way, in order, when the first row is too narrow: the ‹ BACK
--- ghost (ESC still works), then RESET moves to the row after the roads;
--- the roads wrap into as many rows as they need. Nothing is ever cut to
--- its first three letters, and every chip is a hit target.
function Map:draw_header()
  local vw = Layout.vw
  local g = Layout.gutter()
  local chip_h = Theme.control.chip
  local pitch = chip_h + Theme.space.sm
  local gap = Theme.space.sm
  local room = vw - g * 2
  local band = UI.headerHeight()

  self.land_rects = {}
  self.category_rects = {}
  -- Cleared every frame: a hit rect that outlives the button it belonged to
  -- is a reset that fires from a blank piece of header.
  self.reset_rect = nil
  self.back_rect = nil

  local LANDS = self:lands()
  local ROADS = Land.roads(self.land)
  local offer_reset = Map.reset_offered(self.tally)
  local reset_label = I18n.t("RESET THIS ROAD")
  -- Sized from `UI.buttonSize`: a button never shrinks its label, and on a
  -- wide canvas the label is 24, not 16.
  local reset_w, reset_h = UI.buttonSize(reset_label)
  if not offer_reset then reset_w = 0 end
  local back_label = "‹ " .. I18n.t("BACK")
  local back_w, back_h = UI.buttonSize(back_label)
  back_h = math.max(Theme.control.buttonM, back_h)
  local mascot_box = chip_h - 8

  -- The land badge: the mascot and the name in the land's colour.
  local name = I18n.t(Land.name(self.land))
  local badge_w = Theme.space.md + mascot_box + Theme.space.sm + UI.labelWidth(name, "label") + Theme.space.md
  local lands_w = badge_w
  for _, land in ipairs(LANDS) do
    if land ~= self.land then lands_w = lands_w + gap + chip_h end
  end

  local with_back = back_w + gap + lands_w + (offer_reset and (gap + reset_w) or 0) <= room
  local reset_on_first = offer_reset and (lands_w + gap + reset_w <= room)

  -- The road chips: on the first row after the lands when the whole header
  -- fits one row (a wide canvas), else wrapped into rows of their own.
  local roads_w = -gap
  for _, road in ipairs(ROADS) do
    roads_w = roads_w + math.min(UI.chipWidth(I18n.t(Land.category_label(road))), room) + gap
  end
  local lead_w = (with_back and (back_w + gap) or 0) + lands_w + Theme.space.lg
  local one_row = lead_w + roads_w + (offer_reset and (gap + reset_w) or 0) <= room
  local rows = { {} }
  local x = one_row and lead_w or 0
  for _, road in ipairs(ROADS) do
    local label = I18n.t(Land.category_label(road))
    local w = math.min(UI.chipWidth(label), room)
    if x > (one_row and lead_w or 0) and x + w > room then
      rows[#rows + 1] = {}
      x = 0
    end
    rows[#rows][#rows[#rows] + 1] = { road = road, label = label, w = w, x = x }
    x = x + w + gap
  end
  local reset_row = nil
  if offer_reset and not reset_on_first then
    -- At the end of the last road row when it fits there, else a row of
    -- its own: the button is always on the screen.
    local last = rows[#rows]
    local used = last[#last].x + last[#last].w
    if used + gap + reset_w <= room then
      reset_row = #rows
    else
      rows[#rows + 1] = {}
      reset_row = #rows
    end
  end

  -- The rows are the chips' pitch; a reset button taller than a chip gets
  -- the room it needs on its row.
  pitch = math.max(pitch, reset_h + Theme.space.sm)
  local extra = #rows - (one_row and 1 or 0)
  local h = band + extra * pitch
  self.header_h = h
  UI.card(0, 0, vw, h, { variant = "bar", pad = 0 })
  UI.setColor(Theme.edge, 0.6)
  love.graphics.rectangle("fill", 0, h - 2, vw, 2)
  love.graphics.setColor(1, 1, 1, 1)

  -- Row one: back, the badge, the mascots, reset.
  local y = math.floor((band - chip_h) / 2)
  x = g
  if with_back then
    local bh = back_h
    self.back_rect = { x = x, y = math.floor((band - bh) / 2), w = back_w, h = bh }
    UI.button(self.back_rect.x, self.back_rect.y, back_w, bh, back_label,
      self.hover == "back" and "hot" or "normal", nil, { variant = "ghost", id = "map:back" })
    x = x + back_w + gap
  end
  local tint = Theme.land[self.land] or Theme.gold
  UI.setColor(Theme.shadowOf(tint) == Theme.edge and Theme.darken(tint, 0.45) or Theme.shadowOf(tint))
  UI.rrect("fill", x, y + Theme.chipShadowDy, badge_w, chip_h, Theme.radiusInner)
  UI.setColor(tint)
  UI.rrect("fill", x, y, badge_w, chip_h, Theme.radiusInner)
  UI.stroke(x, y, badge_w, chip_h, Theme.radiusInner, Theme.edge)
  local bob = Anim.bob(self.t, { amount = 1.5, phase = Land.phase(self.land) })
  mascot(Land.mascot(self.land), x + Theme.space.md + mascot_box / 2, y + chip_h - 4 + bob, mascot_box)
  UI.label(name, x + Theme.space.md + mascot_box + Theme.space.sm, y + math.floor((chip_h - UI.lead("label")) / 2),
    "label", { color = Theme.edge, shadow = false })
  self.land_rects[self.land] = { x = x, y = y, w = badge_w, h = chip_h }
  x = x + badge_w + gap
  for _, land in ipairs(LANDS) do
    if land ~= self.land then
      local hot = self.hover == land
      UI.chip(x, y, "", { w = chip_h, hot = hot })
      mascot(Land.mascot(land), x + chip_h / 2, y + chip_h - 4, mascot_box, { alpha = hot and 1 or 0.7 })
      self.land_rects[land] = { x = x, y = y, w = chip_h, h = chip_h }
      x = x + chip_h + gap
    end
  end
  local function reset_at(rx, ry)
    -- Centred on the chip row it shares.
    ry = ry + math.floor((chip_h - reset_h) / 2)
    self.reset_rect = { x = rx, y = ry, w = reset_w, h = reset_h }
    UI.button(rx, ry, reset_w, reset_h, reset_label, self.hover == "reset" and "hot" or "normal", nil,
      { variant = "ghost", id = "map:reset", lift = 1, sway = false })
  end
  if reset_on_first then reset_at(vw - g - reset_w, y) end

  -- The road rows: the first shares the lands' row on a wide canvas.
  for r, row in ipairs(rows) do
    local ry = band + (r - 1 - (one_row and 1 or 0)) * pitch
    if one_row and r == 1 then ry = y end
    for _, c in ipairs(row) do
      local on = c.road == self.category
      UI.chip(g + c.x, ry, c.label, { selected = on, hot = self.hover == c.road, w = c.w })
      self.category_rects[c.road] = { x = g + c.x, y = ry, w = c.w, h = chip_h }
    end
    if reset_row == r then reset_at(vw - g - reset_w, ry) end
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
      UI.setColor(Theme.edge, 0.55)
      love.graphics.line(ax, ay + 2, bx, by + 2)
      UI.setColor(lit and Theme.gold or Theme.withAlpha(Theme.text, 0.45))
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

--- The size a marker is drawn at: a picture, so it grows with the canvas
--- (`uiScale` is still right for art), and never smaller than its number
--- needs — the label is the fixed label role, and the coin is scaled to
--- hold it rather than the other way round.
function Map:marker_size(node)
  local scale = Layout.uiScale()
  local base = (node.kind == "boss" and 44 or 34) * scale
  local label_w = UI.labelWidth(tostring(node.node), "label")
  return math.max(base, label_w / 0.6)
end

function Map:draw_nodes()
  if not self.nodes then return end
  local next_i = Map.next_index(self.nodes)
  local font = UI.font("label")
  for i, node in ipairs(self.nodes) do
    local x, y = self:node_xy(node)
    local selected = i == self.cursor
    local base = self:marker_size(node)
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
      size = size + 4 * Layout.uiScale() * Ease.cosine((self.t * 1.6) % 1)
    end

    -- A shadow grounds it. Without one a bobbing marker looks like it is
    -- sliding rather than lifting.
    UI.setColor(Theme.edge, 0.30)
    love.graphics.ellipse("fill", x, y + size * 0.34, size * 0.30, size * 0.10)
    love.graphics.setColor(1, 1, 1, 1)
    y = y + bob

    local drew = Assets.marker(marker_for(node), x, y, size)
    if not drew then
      -- No art: a coloured disc, so the map still works.
      local r = size * 0.38
      local fill = Theme.gold
      if node.state == "cleared" then fill = Theme.green end
      if node.kind == "boss" then fill = Theme.redA end
      UI.setColor(Theme.edge)
      love.graphics.circle("fill", x, y, r + 3)
      UI.setColor(fill)
      love.graphics.circle("fill", x, y, r)
    end

    -- A cleared node wears the stamp (SPEC §0: stamped CLEARED, for good).
    -- The sprite is a wordless ring by design — `docs/design-review.md` says
    -- the word is printed over it at runtime so it can be translated — and
    -- the word is printed only where the ring is big enough to hold it;
    -- otherwise the number is, so a cleared coin still says which it is.
    local stamped = false
    if node.state == "cleared" then
      -- A practised node wears the stamp in another colour (the ring tinted
      -- cyan) with its count on the rim: a street played again is a
      -- different kind of done, and the map should say so at a glance.
      local tint = Map.stamp_color(node.practised)
      local ring = size * 1.15
      if Assets.marker("stamp_cleared", x, y, ring, { color = tint }) then
        local word = I18n.t("CLEARED")
        local ww = font:getWidth(word)
        if ww <= ring * 0.8 then
          stamped = true
          love.graphics.setFont(font)
          UI.setColor(Theme.text)
          love.graphics.print(word, math.floor(x - ww / 2), math.floor(y - font:getHeight() / 2))
          love.graphics.setColor(1, 1, 1, 1)
        end
      else
        UI.setColor(tint and Theme.cyan or Theme.green)
        love.graphics.circle("line", x, y, size * 0.5)
        love.graphics.setColor(1, 1, 1, 1)
      end
    end

    -- The number, in the label role: fixed, so it cannot outgrow its coin,
    -- and over the stamp, so the stamp cannot hide it.
    if not stamped then
      local label = tostring(node.node)
      love.graphics.setFont(font)
      UI.setColor(Theme.edge)
      love.graphics.print(label, math.floor(x - font:getWidth(label) / 2), math.floor(y - font:getHeight() / 2))
      love.graphics.setColor(1, 1, 1, 1)
    end

    if node.state == "cleared" then
      if (node.practised or 0) > 0 then
        local tag = ("×%d"):format(node.practised)
        local tw = font:getWidth(tag) + Theme.space.sm
        local th = font:getHeight() + 2
        local tx, ty = x + size * 0.22, y + size * 0.26
        UI.setColor(Theme.edge, 0.9)
        UI.rrect("fill", tx, ty, tw, th, Theme.radiusSm)
        UI.setColor(Theme.cyan, 0.9)
        UI.rrect("fill", tx + 1, ty + 1, tw - 2, th - 2, Theme.radiusSm - 1)
        UI.setColor(Theme.edge)
        love.graphics.print(tag, tx + Theme.space.xs, ty + 1)
        love.graphics.setColor(1, 1, 1, 1)
      end
    end

    if i == next_i then
      -- **One hand, on the node the route suggests next.** A hand over every
      -- node still open was a field of hands — the mark that is supposed to
      -- say *here* saying it twenty times over. This is the street to walk
      -- down; every other open node is a plain coin, which is what it is.
      local hs = size * 0.6
      local hb = Anim.bob(self.t, { amount = 2, period = 1.7 })
      -- `Assets.marker` draws centred, and the sprite points at its own
      -- bottom edge: put that edge just over the coin's top.
      Assets.marker("node_hand", x, y - size * 0.40 - hb - hs * 0.5, hs)
    end

    if (node.stars or 0) > 0 then
      local sw = 3 * 10
      UI.stars(x - sw / 2, y + size * 0.5 + 2, node.stars, 7)
    end

    -- The clear stamp lands with a shockwave (docs/art.md §7).
    local age = self.stamped[node.quest_id]
    if age and age < 0.9 then
      local k = Ease.expOut(age / 0.9)
      UI.setColor(Theme.gold, 1 - k)
      love.graphics.setLineWidth(3)
      love.graphics.circle("line", x, y, size * 0.5 + 34 * k)
      love.graphics.setColor(1, 1, 1, 1)
    end

    if selected then
      UI.setColor(Theme.gold)
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
  UI.setColor(Theme.edge, 0.28)
  love.graphics.ellipse("fill", x, y + 2, height * 0.20, height * 0.07)
  love.graphics.setColor(1, 1, 1, 1)

  local frame = moving and (math.floor(self.t * Map.WALK_FPS) + 1) or 1
  if not Assets.frame("walk_mei", frame, x, y + 2, height, { flip = facing < 0 }) then
    -- No strip: the standing portrait, which at least says who is here.
    Assets.sprite("sprite_mei", x, y + 2, height, { flip = facing < 0 })
  end
end

--- `requires` is the suggested route, and saying so is the whole point: it
--- answers "where next" without ever being a refusal. The node to do first,
--- when there is one still open.
function Map:suggested_after(node)
  if not node or node.state == "cleared" or not node.requires or #node.requires == 0 then return nil end
  local after = node.requires[1]
  local blocker = self.by_id[after] and self.nodes[self.by_id[after]]
  if blocker and blocker.state ~= "cleared" then return after end
  return nil
end

--- The node card's height: the sum of its rows at the roles, so the sheet
--- is as tall as what it says and the plate above it knows where to stop.
--- With `node`, the landscape card adds the suggested-route line when the
--- node has one; the portrait sheet never does (it is already the map's
--- third), so the plate's height is the same whichever node is under the
--- cursor.
function Map:card_height(node)
  local portrait = Layout.isPortrait()
  local pad = portrait and Theme.space.lg or Theme.space.xl
  local h = pad + UI.lead("label") + Theme.space.xs + UI.lead("title") + Theme.space.md
  if portrait then
    -- The stars, the pips and the attempts share a line.
    h = h + math.max(Theme.space.xl, UI.lead("label")) + Theme.space.lg
  else
    h = h + Theme.control.chip + Theme.space.md + UI.lead("label") + Theme.space.lg
    if node and self:suggested_after(node) then h = h + UI.lead("label") + Theme.space.sm end
  end
  h = h + Theme.control.buttonL + Theme.space.lg + 8 + pad
  return h
end

--- The node card: where it sits. Docked top-right in landscape; a sheet
--- above the footer upright.
function Map:card_rect(node)
  local vw, vh = Layout.vw, Layout.vh
  local h = self:card_height(node)
  if Layout.isPortrait() then
    local g = Layout.gutter()
    return { x = g, y = vh - UI.footerHeight() - h, w = vw - g * 2, h = h }
  end
  local bx, by, bw = UI.bounded(nil, (self.header_h or UI.headerHeight()) + Theme.space.lg)
  local w = math.min(360, bw)
  return { x = bx + bw - w, y = by, w = w, h = h }
end

function Map:draw_node_card(node)
  local portrait = Layout.isPortrait()
  local r = self:card_rect(node)
  local pad = portrait and Theme.space.lg or Theme.space.xl
  local k = Juice.enter("map:card", { dur = Theme.motion.enter, delay = 0.08 })
  local alpha = math.min(1, k * 1.5)
  local y = r.y + (1 - k) * 24
  UI.card(r.x, y, r.w, r.h, { strip = Theme.land[self.land] or Theme.gold, stripH = Theme.landStripeH,
    alpha = alpha, pad = 0 })
  local x = r.x + pad
  local right = r.x + r.w - pad
  local inner = right - x
  local cy = y + pad

  -- The boss gets its portrait, standing on the card's content rows. It is
  -- the thing the premise is named after and it was drawn exactly like node 5.
  local boss_w = 0
  local boss = node.kind == "boss" and BOSS[self.land .. "." .. self.category] or nil
  if boss and Assets.image(boss) and not portrait then
    boss_w = 88
    Assets.sprite(boss, right - boss_w / 2 + Theme.space.sm, cy + UI.lead("label") + UI.lead("title") + Theme.space.md + Theme.control.chip, 96, { alpha = alpha })
  end

  -- Row one: the number, and the road's tally.
  local number = ("%02d"):format(node.node or 0)
  UI.label(number, x, cy, "label", { color = Theme.mute, alpha = alpha })
  local tally = self.tally and Map.tally_label(self.tally.cleared, self.tally.total,
    inner - boss_w - UI.labelWidth(number, "label") - Theme.space.md,
    function(text) return UI.labelWidth(text, "label") end) or nil
  if tally then
    UI.label(tally, x, cy, "label", { color = Theme.mute, width = inner - boss_w, align = "right", alpha = alpha })
  end
  cy = cy + UI.lead("label") + Theme.space.xs

  -- The title: one line, an ellipsis, never a wrap.
  local practised = node.practised or 0
  local status_w = 0
  local status, status_color
  if node.state == "cleared" and practised > 0 then
    status, status_color = I18n.t("CLEARED · PRACTISED ×%d", practised), Theme.cyan
  elseif node.state == "cleared" then
    status, status_color = I18n.t("CLEARED"), Theme.green
  else
    status, status_color = I18n.t((node.state or "?"):upper()), nil
  end
  if portrait then
    status_w = UI.chipWidth(status) + Theme.space.md
    UI.chip(right - status_w + Theme.space.md, cy + math.floor((UI.lead("title") - Theme.control.chip) / 2), status,
      { color = status_color, selected = status_color == nil, alpha = alpha })
  end
  UI.label(node.title or "", x, cy, "title", { width = inner - boss_w - status_w, ellipsis = true, alpha = alpha })
  cy = cy + UI.lead("title") + Theme.space.md

  if portrait then
    -- The stars, the pips and the attempts, on one line.
    local line_h = math.max(Theme.space.xl, UI.lead("label"))
    UI.stars(x, cy + math.floor((line_h - 24) / 2), node.stars or 0, 24)
    local px = x + 3 * 27 + Theme.space.lg
    UI.pips(px, cy + math.floor((line_h - 12) / 2), node.difficulty or 1, 6)
    local attempts = I18n.t("%d ATTEMPTS", node.attempts or 0)
    UI.label(attempts, px + UI.pipsWidth(6) + Theme.space.lg, cy + math.floor((line_h - UI.lead("label")) / 2), "label",
      { color = Theme.mute, width = right - (px + UI.pipsWidth(6) + Theme.space.lg), align = "right", ellipsis = true, alpha = alpha })
    cy = cy + line_h + Theme.space.lg
  else
    -- The status chip, with the stars at the right.
    UI.chip(x, cy, status, { color = status_color, selected = status_color == nil, alpha = alpha })
    UI.stars(right - boss_w - 3 * 27, cy + math.floor((Theme.control.chip - 24) / 2), node.stars or 0, 24)
    cy = cy + Theme.control.chip + Theme.space.md
    -- The difficulty pips, and the attempts at the right.
    UI.pips(x, cy + math.floor((UI.lead("label") - 12) / 2), node.difficulty or 1, 6)
    local attempts = I18n.t("%d ATTEMPTS", node.attempts or 0)
    UI.label(attempts, x + UI.pipsWidth(6) + Theme.space.lg, cy, "label",
      { color = Theme.mute, width = right - boss_w - (x + UI.pipsWidth(6) + Theme.space.lg), align = "right", ellipsis = true, alpha = alpha })
    cy = cy + UI.lead("label") + Theme.space.lg
    -- Where next, when the route says: on the card, before PLAY.
    local after = self:suggested_after(node)
    if after then
      cy = cy + UI.label(I18n.t("SUGGESTED AFTER %s", after), x, cy - Theme.space.sm, "label",
        { color = Theme.mute, width = inner, ellipsis = true, alpha = alpha })
    end
  end

  -- PLAY: the screen's one primary button, ENTER inside it.
  local play = { x = x, y = cy, w = inner, h = Theme.control.buttonL }
  self.play_rect = play
  UI.button(play.x, play.y, play.w, play.h, I18n.t("PLAY"), self.hover == "play" and "hot" or "normal", nil,
    { variant = "primary", id = "map:play", key = "ENTER", alpha = alpha })
  cy = cy + Theme.control.buttonL + Theme.space.lg

  -- The road's bar: the same fact as the tally, without reading.
  if self.tally then
    UI.bar(x, cy, inner, 8, self.tally.cleared / math.max(1, self.tally.total), Theme.gold)
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

--- The wheel moves the cursor, because on a desktop that is what a wheel is
--- for. Every screen in this client that has a list has one of these now.
--- On the map the list is a path, so the wheel walks it: down goes on, up
--- goes back, and `step` is the same move the arrow keys make.
function Map:wheelmoved(_, dy)
  if self.iris or self.walk then return end
  self:step(0, dy > 0 and -1 or 1)
end

function Map:keypressed(key)
  -- The confirm sheet takes the whole keyboard while it is up. Not politeness:
  -- TAB and Q left live under it would let the player switch land, and then
  -- RESET IT would clear a road the sheet never named.
  if self.confirm_reset then
    if key == "escape" or key == "return" or key == "kpenter" or key == "space" then
      self:cancel_reset()
    end
    return true
  end
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

function Map:mousemoved(x, y)
  local function inside(r)
    return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
  end
  self.hover = nil
  if self.confirm_reset then return end
  if inside(self.back_rect) then self.hover = "back"; return end
  if inside(self.reset_rect) then self.hover = "reset"; return end
  if inside(self.play_rect) then self.hover = "play"; return end
  for land, rect in pairs(self.land_rects or {}) do
    if inside(rect) then self.hover = land; return end
  end
  for category, rect in pairs(self.category_rects or {}) do
    if inside(rect) then self.hover = category; return end
  end
end

function Map:mousepressed(x, y)
  local function inside(r)
    return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
  end
  if self.confirm_reset then
    local rects = self.confirm_rects or {}
    if inside(rects.go) then
      UI.press("map:go", rects.go, { sfx = false })
      self:do_reset()
    else
      -- KEEP, the ×, and anywhere off the sheet. A click that missed is not
      -- a yes.
      if inside(rects.keep) then UI.press("map:keep", rects.keep, { sfx = false }) end
      self:cancel_reset()
    end
    return
  end
  if inside(self.back_rect) then
    UI.press("map:back", self.back_rect, { sfx = false })
    self.app:back()
    return
  end
  if inside(self.reset_rect) then
    UI.press("map:reset", self.reset_rect, { sfx = false })
    self:ask_reset()
    return
  end
  if inside(self.play_rect) then self:open_node(); return end
  for land, rect in pairs(self.land_rects or {}) do
    if inside(rect) then self:switch(land, self.category); return end
  end
  for category, rect in pairs(self.category_rects or {}) do
    if inside(rect) then self:switch(self.land, category); return end
  end
  if not self.nodes then return end
  for i, node in ipairs(self.nodes) do
    local nx, ny = self:node_xy(node)
    local reach = math.max(22, self:marker_size(node) * 0.6)
    if (x - nx) ^ 2 + (y - ny) ^ 2 <= reach * reach then
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
