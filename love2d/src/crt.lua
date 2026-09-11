-- The scanline overlay.
--
-- Ported from `CausewaybayGolang/love2d/src/crt.lua`; the only change is that
-- it can be switched off, because a scanline every other row over a code
-- editor is the difference between 16-bit and unreadable.

local Layout = require("src.layout")
local Theme = require("src.theme")

local CRT = { t = 0, enabled = true }

function CRT.update(dt)
  CRT.t = CRT.t + dt
end

function CRT.toggle()
  CRT.enabled = not CRT.enabled
  return CRT.enabled
end

--- `strength` scales the whole effect; the quest screen passes a small number
--- so the editor stays legible.
function CRT.draw(strength)
  if not CRT.enabled then return end
  strength = strength or 1
  local w, h = Layout.vw, Layout.vh
  love.graphics.setColor(0, 0, 0, 0.10 * strength)
  for y = 0, h - 1, 2 do
    love.graphics.rectangle("fill", 0, y, w, 1)
  end
  local ry = math.floor((CRT.t * 36) % (h + 10)) - 4
  love.graphics.setColor(Theme.withAlpha(Theme.coin, 0.04 * strength))
  love.graphics.rectangle("fill", 0, ry, w, 6)
  love.graphics.setColor(1, 1, 1, 1)
end

return CRT
