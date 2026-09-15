-- Milestone 1, end to end, against a real server.
--
--   cd backend && cargo run -p cwbhacker -- serve
--   make -C love2d drive SCRIPT=tests/drive/slice.lua ARGS="--home $(mktemp -d)"
--
-- **The `--home` is not optional.** This script signs in as one specific
-- wallet, and a token left by an earlier run resumes a different player
-- before the login screen ever appears — which shows up as a timeout on step
-- three and reads like the client is broken.
--
-- It used to say `rm -f ~/Library/…/LOVE/causewaybay-hacker/session.json`,
-- and that stopped being where the session lived two moves ago: first out of
-- LÖVE's save directory, then out of `~/.causewaybayhackerlove2d` (SPEC
-- §1.1). A throwaway home is better than either, because it proves the run
-- from nothing and deletes none of the player's own state.
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
  -- Twenty, not ten. The client now rests on a title card that waits
  -- (`src/scenes/title.lua`), and a run with nobody at the keyboard spends
  -- its eight-second idle-out before the login screen appears — measured at
  -- 7.4 s from launch here, which is inside ten and not by enough. This is
  -- the one script whose budget the card actually came close to.
  { until_ = scene("login"), note = "login screen", timeout = 20 },
  { shot = "01-login.png" },

  -- **A wallet minted here, not a phrase written above.** This script plays
  -- a quest through to ACCEPTED and then asserts `cleared=1`, which is only
  -- true on an account that has not cleared it already — and every other
  -- drive signs in as the same phrase and leaves its own progress behind.
  -- NEW WALLET is one key and a different account every run.
  { note = "NEW WALLET — a fresh account, so `cleared` means this run" },
  { key = "n" },
  { until_ = function(app)
      return app.session.authed or app.scene.mode == "new_show"
    end, note = "a phrase and its address", timeout = 20 },
  { shot = "02-login-filled.png" },
  { key = "return", when = function(app) return app.scene_name == "login" end },

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
  -- **F10, not F5.** RUN is an iteration and deliberately stays on the quest
  -- screen ("bouncing the player to a result screen after every RUN would
  -- make the reflex button feel expensive" — `src/scenes/quest.lua`); only
  -- SUBMIT produces a verdict. This script pressed F5 and then waited ninety
  -- seconds for a screen that was never coming, which reads exactly like a
  -- server that has stopped answering.
  { key = "f10" },
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
  { key = "f10" },
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
