-- A refusal the player can see (SPEC §1.1).
--
--   make -C love2d drive SCRIPT=tests/drive/loginerror.lua
--
-- The login panel is taller than the window it is drawn in — at the default
-- type step the stack runs ~740 tall in a ~540 view — and the row that says
-- why a sign-in was refused is the **last** one. So the screen can answer a
-- player in words that are two hundred pixels below the fold, which is the
-- same as not answering at all.
--
-- This types something that cannot be a wallet, presses ENTER, and asserts
-- the message row is inside the view when the message appears.

local steps = {}
local function add(t) steps[#steps + 1] = t end
local fail = false
local function check(ok, why)
  if ok then return true end
  print("FAIL: " .. why)
  fail = true
  return false
end

add({ orient = "landscape" })
add({ resize = { 1280, 720 } })
add({ until_ = function(app) return app.scene_name == "login" end,
      note = "the login screen", timeout = 20 })
add({ wait = 0.5 })

-- Twelve words that are not a mnemonic: the checksum fails, which is a
-- refusal rather than a connection problem.
add({ text = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo" })
add({ key = "return" })

add({ until_ = function(app) return (app.scene.error or app.scene.status) ~= nil end,
      note = "the screen said something", timeout = 10 })
add({ until_ = function(app)
      local s = app.scene
      print(("message: %s"):format(tostring(s.error or s.status)))
      local row
      for _, r in ipairs(s.last_rows or {}) do if r.message then row = r end end
      -- The draw keeps the rows; ask the panel where the message landed.
      check(row ~= nil, "no message row was drawn")
      if row then
        local top, bottom = row.y - (s.scroll or 0), row.y + row.h - (s.scroll or 0)
        print(("message row at %d..%d of a %d view (scroll %d)")
          :format(top, bottom, s.view and s.view.h or -1, s.scroll or 0))
        check(top >= 0 and bottom <= (s.view and s.view.h or 0),
          "the refusal was drawn outside the panel — the player cannot read it")
      end
      return true
    end, timeout = 5 })
add({ shot = "L1-login-refusal.png" })

add({ until_ = function()
      print("login refusal: " .. (fail and "FAILED" or "0 failures"))
      if fail then error("login refusal drive failed", 0) end
      return true
    end, timeout = 3 })
add({ quit = true })
return steps
