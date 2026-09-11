-- Milestone 1, end to end, against a real server.
--
--   cd backend && cargo run -p cwbhacker -- serve
--   rm -f ~/Library/Application\ Support/LOVE/causewaybay-hacker/session.json
--   make -C love2d drive SCRIPT=tests/drive/slice.lua
--
-- The stored session is cleared first on purpose: this script signs in as one
-- specific wallet, and a token left by an earlier run would resume a
-- different player before the login screen ever appeared.
--
-- PLAN.md's slice, one step per line:
--
--   login with a mnemonic → RUST land → BASIC category → the map
--   → node 1 → the editor → submit a wrong answer → watch run.log stream in
--   → read the verdict and the mistake → submit the real answer
--   → CLEARED → back on the map, stamped → the same map in portrait
--
-- The mnemonic is BIP-39's second published English test vector, which is
-- public, is in `tests/vectors/addresses.json`, and derives
-- 0x58A57ed9d8d624cBD12e2C467D34787555bB1b25 on m/44'/60'/0'/0/0. Nothing
-- secret is ever typed into a drive script.
--
-- A *fresh* wallet on purpose: the slice has to show a node going from `open`
-- to `cleared`, and an account that has already cleared node 1 would start
-- the player on node 2 and prove nothing.

local MNEMONIC = "legal winner thank year wave sausage worth useful "
  .. "legal winner thank yellow"

local function scene(name)
  return function(app) return app.scene_name == name end
end

local function ctrl(key)
  return { key = key, mods = { ctrl = true } }
end

return {
  { orient = "landscape" },
  { wait = 0.6 },
  { until_ = scene("login"), note = "login screen", timeout = 10 },
  { shot = "01-login.png" },

  { note = "typing the mnemonic — derived locally, never sent" },
  { text = MNEMONIC },
  { key = "tab" },
  { text = "mei" },
  { wait = 0.2 },
  { shot = "02-login-filled.png" },
  { key = "return" },

  { until_ = scene("lands"), note = "auth.challenge + sign + auth.login", timeout = 20 },
  { wait = 0.8 },
  { shot = "03-lands.png" },

  { key = "return" },
  { until_ = scene("categories"), note = "RUST land", timeout = 10 },
  { wait = 0.6 },
  { shot = "04-categories.png" },

  { key = "return" },
  { until_ = scene("map"), note = "BASIC category", timeout = 10 },
  { until_ = function(app) return app.scene.nodes and #app.scene.nodes > 0 end,
    note = "world.map arrived", timeout = 10 },
  { wait = 0.5 },
  { shot = "05-map.png" },

  { until_ = function(app)
      -- Node 1 on a wallet that has played before is `cleared`, not `open`;
      -- either is playable and either is a fine place to start the slice.
      local n = app.scene.nodes and app.scene.nodes[app.scene.cursor]
      if n then
        print(("slice: starting on node %d (%s), state=%s"):format(
          n.node or -1, tostring(n.quest_id), tostring(n.state)))
      end
      return n ~= nil and n.state ~= "locked"
    end, note = "the cursor is on a playable node", timeout = 10 },
  { key = "return" },
  { until_ = scene("quest"), note = "node 1", timeout = 10 },
  { until_ = function(app) return app.scene.quest ~= nil end,
    note = "quest.get arrived", timeout = 10 },
  { wait = 0.4 },
  { shot = "06-quest.png" },

  { note = "a wrong answer first — the mistakes are the point (SPEC §7)" },
  ctrl("a"),
  { text = 'fn main() {\n    println!("hello, world")\n}\n' },
  { wait = 0.3 },
  { shot = "07-quest-typed.png" },
  { key = "f5" },
  { wait = 0.9 },
  { shot = "08-running.png" },

  { until_ = scene("result"), note = "the verdict came back", timeout = 90 },
  { wait = 0.8 },
  { shot = "09-result-failed.png" },

  { key = "return" },
  { until_ = function(app) return app.scene_name == "quest" and app.scene.quest end,
    note = "back in the editor", timeout = 15 },
  { wait = 0.4 },

  { note = "now the answer the quest actually wants" },
  ctrl("a"),
  { text = 'fn main() {\n    println!("hello, causewaybay");\n}\n' },
  { wait = 0.3 },
  { key = "f5" },
  { until_ = scene("result"), note = "judged", timeout = 90 },
  { until_ = function(app)
      return app.scene.attempt and app.scene.attempt.verdict == "accepted"
    end, note = "ACCEPTED, and cleared=" , timeout = 5 },
  { wait = 1.0 },
  { shot = "10-result-accepted.png" },

  { key = "escape" },
  { until_ = function(app) return app.scene_name == "map" and app.scene.nodes end,
    note = "back on the map", timeout = 15 },
  { wait = 1.2 },
  { shot = "11-map-cleared.png" },

  { note = "the same screen, portrait — SPEC §10" },
  { orient = "portrait" },
  { resize = { 720, 1000 } },
  { wait = 1.0 },
  { shot = "12-map-portrait.png" },

  { key = "t" },
  { until_ = scene("stats"), note = "stats.mistakes", timeout = 10 },
  { wait = 1.2 },
  { shot = "13-stats-portrait.png" },
  { orient = "landscape" },
  { resize = { 1280, 720 } },
  { wait = 0.8 },
  { shot = "14-stats.png" },

  { key = "escape" },
  { wait = 0.6 },
  { key = "s" },
  { until_ = scene("search"), note = "the milestone-2 stub", timeout = 10 },
  { wait = 1.0 },
  { shot = "15-search-stub.png" },

  { wait = 0.5 },
  { quit = true },
}
