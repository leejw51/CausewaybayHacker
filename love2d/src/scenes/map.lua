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
local Land = require("src.land")

local Map = {}
Map.__index = Map

-- The lands and the three categories, in SPEC §0's order. TAB walks the
-- lands in this order and wraps.
local LANDS = Land.ORDER
local CATEGORIES = Land.CATEGORIES

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
--- There is no reusable confirm in this client — `src/scenes/login.lua` is a
--- screen of its own and `src/scenes/quest.lua` arms with a second press —
--- so this is a panel drawn by the scene that raised it. The road, the count
--- and the total are copied out **now**, so the sentence on screen keeps
--- naming the road it was opened for even if something else moves underneath.
function Map:ask_reset()
  if self.iris or self.walk then return end
  if not Map.reset_offered(self.tally) then return end
  SFX.play("move")
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

function Map:draw()
  local vw, vh = Layout.vw, Layout.vh
  local px, py, pw, ph = self:plate_rect()

  Assets.cover(Assets.pick(Map.plate_names(self.land, Layout.isPortrait())),
    px, py, pw, ph)
  love.graphics.setColor(Map.haze(self.land))
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
  self:draw_confirm()

  if self.confirm_reset then
    self.app:footer(I18n.t("ESC keep my progress   CLICK to reset"))
    return
  end

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

--- The confirm panel, over the map it is about.
---
--- **Enter does not take the destructive button.** ESC, ENTER and SPACE all
--- land on KEEP MY PROGRESS — a player who reached for the key that has
--- meant "yes, go on" on every other screen in this client keeps their road —
--- and RESET IT is reached by pointing at it, which is a thing nobody does by
--- reflex. KEEP is the lit button for the same reason.
function Map:draw_confirm()
  if not self.confirm_reset then return end
  local vw, vh = Layout.vw, Layout.vh
  local ask = self.confirm_reset

  -- The map goes dim rather than away: the road being talked about is the
  -- one behind the panel, and a player deciding wants to see it.
  UI.setColor(Theme.void, 0.82)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)

  local title_size, body_size, button_size = 12, 8, 9
  local w = math.min(vw - 32, 460)
  local pad = 16
  local body = Map.reset_body(ask.road, ask.cleared, ask.total)
  local lines = UI.wrap(body, w - pad * 2, body_size)
  local step = UI.lineHeight(body_size) + 2
  local title_h = UI.lineHeight(title_size)
  local bh = math.max(32, UI.lineHeight(button_size) + 14)
  local h = pad + title_h + 10 + #lines * step + 14 + bh + pad
  local x = math.floor((vw - w) / 2)
  local y = math.floor((vh - h) / 2)

  UI.panel(x, y, w, h, { tint = Theme.red })
  UI.text(I18n.t("WALK IT AGAIN?"), x, y + pad, title_size, Theme.coin, "center", w)
  UI.paragraph(body, x + pad, y + pad + title_h + 10, w - pad * 2, body_size,
    Theme.cream)

  local gap = 10
  local keep_w = math.floor((w - pad * 2 - gap) / 2)
  local row = y + h - pad - bh
  local keep = { x = x + pad, y = row, w = keep_w, h = bh }
  local go = { x = keep.x + keep_w + gap, y = row,
    w = w - pad * 2 - keep_w - gap, h = bh }
  UI.button(keep.x, keep.y, keep.w, keep.h, I18n.t("KEEP MY PROGRESS"),
    "hot", button_size)
  UI.button(go.x, go.y, go.w, go.h, I18n.t("RESET IT"), nil, button_size)
  self.confirm_rects = { keep = keep, go = go }
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

--- The header: two land buttons, three category tabs, the count.
---
--- The switch has to be **visible**. A keybinding nobody can see is not a
--- feature, and the whole reason for this row is that reaching HACKER used to
--- cost a trip out to two other screens. `CausewaybayGolang` puts "the three
--- big buttons" for its language tracks on its map for the same reason; these
--- are the same idea with this game's two lands and three categories.
---
--- RESET THIS ROAD sits at the right end, apart from the switches and only
--- when there is something to undo. It is measured into the row's budget
--- like everything else here, so the tabs shrink around it rather than run
--- underneath it.
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
  -- Cleared every frame: a hit rect that outlives the button it belonged to
  -- is a reset that fires from a blank piece of header.
  self.reset_rect = nil
  self.header_h = h

  -- What the row needs if nothing is squeezed, and what it actually has.
  local mascot = bh - 10
  local land_w = 0
  for _, land in ipairs(LANDS) do
    land_w = math.max(land_w, mascot + 8 + UI.textWidth(I18n.t(Land.name(land)), land_size) + 10)
  end
  local cat_w = 0
  for _, category in ipairs(CATEGORIES) do
    cat_w = math.max(cat_w, UI.textWidth(I18n.t(Land.category_label(category)), cat_size) + 16)
  end
  local tab_tag = UI.textWidth("TAB", tag_size) + 8
  local q_tag = UI.textWidth("Q", tag_size) + 8
  local reset_label = I18n.t("RESET THIS ROAD")
  local offer_reset = Map.reset_offered(self.tally)
  local reset_w = offer_reset and (UI.textWidth(reset_label, cat_size) + 16) or 0
  local reset_gap = offer_reset and 12 or 0
  local wanted = 10 + #LANDS * (land_w + 6) + tab_tag
    + #CATEGORIES * (cat_w + 4) + q_tag + reset_gap + reset_w + 10
  -- Too narrow for all of it — a portrait canvas in a language with wide
  -- glyphs — so the two key tags go first and then everything shrinks
  -- proportionally. Shrinking is the last resort, not the first.
  local show_tags = wanted <= vw
  if not show_tags then
    wanted = wanted - tab_tag - q_tag
    tab_tag, q_tag = 0, 0
  end
  -- Then the type steps down, land and category together, before any
  -- width is squeezed: squeezing first gave the four land names most of
  -- the row and left the category tabs to shrink to nothing.
  while wanted > vw and land_size > 5 do
    land_size = land_size - 1
    cat_size = math.max(4, cat_size - 1)
    label_h = UI.lineHeight(land_size)
    land_w = 0
    for _, land in ipairs(LANDS) do
      land_w = math.max(land_w, mascot + 8 + UI.textWidth(I18n.t(Land.name(land)), land_size) + 10)
    end
    cat_w = 0
    for _, category in ipairs(CATEGORIES) do
      cat_w = math.max(cat_w, UI.textWidth(I18n.t(Land.category_label(category)), cat_size) + 16)
    end
    if offer_reset then reset_w = UI.textWidth(reset_label, cat_size) + 16 end
    wanted = 10 + #LANDS * (land_w + 6) + tab_tag + #CATEGORIES * (cat_w + 4)
      + q_tag + reset_gap + reset_w + 10
  end
  if wanted > vw then
    local squeeze = (vw - 20 - #LANDS * 6 - #CATEGORIES * 4 - reset_gap)
      / math.max(1, #LANDS * land_w + #CATEGORIES * cat_w + reset_w)
    land_w = math.floor(land_w * squeeze)
    cat_w = math.floor(cat_w * squeeze)
    reset_w = math.floor(reset_w * squeeze)
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
    Assets.sprite(Land.mascot(land), x + 4 + mascot / 2, by + bh - 4, mascot,
      { alpha = on and 1 or 0.45 })
    -- At the size that fits the button, before the scissor cuts: `RU` and
    -- `C+` were what the largest type step left of the land names.
    local name = I18n.t(Land.name(land))
    local fit = UI.fitSize(name, land_w - mascot - 12, land_size, 3)
    love.graphics.setScissor(x, by, land_w, bh)
    UI.text(name, x + mascot + 6, by + (bh - UI.lineHeight(fit)) / 2, fit,
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
    local label = I18n.t(Land.category_label(category))
    local fit = UI.fitSize(label, cat_w - 8, cat_size, 3)
    love.graphics.setScissor(x, cy, cat_w, ch)
    UI.text(label, x + (cat_w - UI.textWidth(label, fit)) / 2,
      cy + (ch - UI.lineHeight(fit)) / 2, fit,
      on and Theme.ink or Theme.withAlpha(Theme.cream, 0.6))
    love.graphics.setScissor()
    self.category_rects[category] = { x = x, y = cy, w = cat_w, h = ch }
    x = x + cat_w + 4
  end
  if show_tags then
    UI.text("Q", x + 2, cy, tag_size, Theme.withAlpha(Theme.cream, 0.4))
    x = x + q_tag
  end

  -- RESET THIS ROAD, at the far right and only where the server's count says
  -- there is something to take away. Right-aligned rather than next in the
  -- flow so that a destructive button never ends up shoulder to shoulder
  -- with the tab the player was aiming for.
  if offer_reset and reset_w > 12 then
    local rw = math.min(reset_w, vw - 10 - x)
    if rw > 12 then
      local rx = vw - 10 - rw
      local rh = math.max(28, UI.lineHeight(cat_size) + 12)
      local ry = (h - rh) / 2
      UI.button(rx, ry, rw, rh, reset_label, nil, cat_size)
      self.reset_rect = { x = rx, y = ry, w = rw, h = rh }
    end
  end

  -- The count used to be a walk over `self.nodes` here. It is the server's
  -- now (`world.map`), and it is drawn on the node card with its bar rather
  -- than twice on one screen — see `draw_node_card`.
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
  local next_i = Map.next_index(self.nodes)
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
      -- A practised node wears the stamp in another colour (the ring tinted
      -- cyan) with its count on the rim: a street played again is a
      -- different kind of done, and the map should say so at a glance.
      local tint = Map.stamp_color(node.practised)
      if Assets.marker("stamp_cleared", x, y, size * 1.15, { color = tint }) then
        local w = UI.textWidth("CLEARED", 6)
        UI.text(I18n.t("CLEARED"), x - w / 2, y - 3, 6, Theme.cream)
      else
        UI.setColor(tint and Theme.cyan or Theme.admit)
        love.graphics.circle("line", x, y, size * 0.5)
        love.graphics.setColor(1, 1, 1, 1)
      end
      if (node.practised or 0) > 0 then
        local tag = ("×%d"):format(node.practised)
        local tw = UI.textWidth(tag, 6) + 4
        UI.setColor(Theme.ink, 0.9)
        love.graphics.rectangle("fill", x + size * 0.22, y + size * 0.26, tw, UI.lineHeight(6) + 2)
        UI.setColor(Theme.cyan, 0.9)
        love.graphics.rectangle("fill", x + size * 0.22 + 1, y + size * 0.26 + 1, tw - 2, UI.lineHeight(6))
        love.graphics.setColor(1, 1, 1, 1)
        UI.text(tag, x + size * 0.22 + 2, y + size * 0.26 + 1, 6, Theme.ink)
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
  -- The road's progress rides on the title's row, right-aligned, and the
  -- title wraps around whatever width it took. Half the row at most: a
  -- title is content and this is chrome.
  local tally = self.tally
    and Map.tally_label(self.tally.cleared, self.tally.total, title_w * 0.5,
      function(text) return UI.textWidth(text, 7) end)
    or nil
  local tally_w = tally and (UI.textWidth(tally, 7) + 10) or 0
  title_w = title_w - tally_w
  local title = ("%02d  %s"):format(node.node, node.title or "")
  local title_lines = math.max(1, #UI.wrap(title, title_w, 11))
  local id_lines = math.max(1, #UI.wrap(node.quest_id or "", title_w, 7))
  -- The two rows under the id each hold a left thing and a right thing —
  -- the state and the stars, the difficulty and the attempts. When the
  -- pair would touch, the right thing takes a row of its own: `OPEN` was
  -- printed through `STARS` and `DIFFICULTY` through `0 ATTEMPTS` at the
  -- largest type step.
  local star = math.max(10, math.floor(UI.lineHeight(7) * 0.8))
  local pip = math.max(6, math.floor(star * 0.6))
  local state_w = UI.textWidth(I18n.t((node.state or "?"):upper()), 9)
  local stars_w = UI.textWidth(I18n.t("STARS") .. " ", 7) + 3 * (star + 3)
  local split3 = state_w + stars_w + 16 > title_w
  local diff_w = UI.textWidth(I18n.t("DIFFICULTY") .. " ", 7) + UI.pipsWidth(pip)
  local attempts = I18n.t("%d ATTEMPTS", node.attempts or 0)
  local split4 = diff_w + UI.textWidth(attempts, 8) + 16 > title_w
  local row3_h = state_h + (split3 and (meta_h + 4) or 0)
  local row4_h = math.max(meta_h, UI.lineHeight(8)) + (split4 and (UI.lineHeight(8) + 4) or 0)
  local h = 10 + title_lines * title_h + 2 + id_lines * id_h + 6 + row3_h + 6
    + row4_h + 6 + id_h + 8
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
  local r3b = split3 and (r3 + state_h + 4) or r3
  local r4 = r3 + row3_h + 6
  local r4b = split4 and (r4 + math.max(meta_h, UI.lineHeight(8)) + 4) or r4
  UI.text(title, x + 12, r1, 11, color, "left", title_w)
  if tally then
    local tx = x + 12 + title_w + 10
    UI.text(tally, tx, r1, 7, Theme.withAlpha(color, 0.85), "left", tally_w)
    -- The same fact without reading: a two-pixel bar under the words.
    local bw = UI.textWidth(tally, 7)
    local by = r1 + UI.lineHeight(7) + 2
    UI.setColor(Theme.dim, 0.5)
    love.graphics.rectangle("fill", tx, by, bw, 2)
    UI.setColor(Theme.admit)
    love.graphics.rectangle("fill", tx, by,
      math.floor(bw * self.tally.cleared / math.max(1, self.tally.total)), 2)
    love.graphics.setColor(1, 1, 1, 1)
  end
  UI.text(node.quest_id or "", x + 12, r2, 7, Theme.withAlpha(color, 0.6),
    "left", title_w)

  local practised = node.practised or 0
  local state_color = ({ open = Theme.coin, cleared = Theme.admit })[node.state]
    or Theme.cream
  if node.state == "cleared" and practised > 0 then state_color = Theme.cyan end
  UI.text(node.state == "cleared" and practised > 0
    and I18n.t("CLEARED · PRACTISED ×%d", practised)
    or I18n.t((node.state or "?"):upper()), x + 12, r3, 9, state_color)
  -- Difficulty is a segmented bar; stars are stars. Two scales, two shapes,
  -- and a row of text between them (design review §4).
  local dl = I18n.t("DIFFICULTY") .. " "
  UI.text(dl, x + 12, r4, 7, Theme.withAlpha(color, 0.6))
  UI.pips(x + 12 + UI.textWidth(dl, 7), r4, node.difficulty or 1, pip)
  local ax = split4 and (x + 12) or (x + w - 12 - boss_w - UI.textWidth(attempts, 8))
  UI.text(attempts, ax, r4b, 8, Theme.withAlpha(color, 0.7))
  local sl = I18n.t("STARS") .. " "
  local stx = split3 and (x + 12 + UI.textWidth(sl, 7)) or (x + w - 12 - boss_w - 3 * (star + 3))
  UI.text(sl, stx - UI.textWidth(sl, 7), r3b, 7, Theme.withAlpha(color, 0.6))
  UI.stars(stx, r3b, node.stars or 0, star)

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

--- The wheel moves the cursor, because on a desktop that is what a wheel is
--- for. Every screen in this client that has a list has one of these now.
--- On the map the list is a path, so the wheel walks it: down goes on, up
--- goes back, and `step` is the same move the arrow keys make.
function Map:wheelmoved(_, dy)
  if self.iris or self.walk then return end
  self:step(0, dy > 0 and -1 or 1)
end

function Map:keypressed(key)
  -- The confirm panel takes the whole keyboard while it is up. Not politeness:
  -- TAB and Q left live under it would let the player switch land, and then
  -- RESET IT would clear a road the panel never named.
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

function Map:mousepressed(x, y)
  local function inside(r)
    return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
  end
  if self.confirm_reset then
    local rects = self.confirm_rects or {}
    if inside(rects.go) then
      self:do_reset()
    else
      -- KEEP, and anywhere off the panel. A click that missed is not a yes.
      self:cancel_reset()
    end
    return
  end
  if inside(self.reset_rect) then self:ask_reset(); return end
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
