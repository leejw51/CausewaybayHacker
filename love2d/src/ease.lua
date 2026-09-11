-- Cosine and exponential easing. t is 0..1.
--
-- Ported from `CausewaybayGolang/love2d/src/ease.lua`. Added here: the
-- `expo*` names and `E.apply`, because the map's walk is authored against an
-- exponential ease-in-out and a curve that lives in a scene is a curve the
-- other client cannot be compared against.
--
-- Why expo rather than cubic, for a figure crossing a map: it is almost
-- still, then very fast, then almost still. That reads as *deliberate* — she
-- gathers herself, covers the ground, and arrives — where a cubic reads as
-- merely smooth. The cost is that it needs more time to be legible at all,
-- and less time than you would guess once the distance is large, because the
-- fast middle does most of the work.
local E = {}

function E.clamp(t, a, b)
  if t < a then
    return a
  end
  if t > b then
    return b
  end
  return t
end

function E.cosine(t)
  t = E.clamp(t, 0, 1)
  return (1 - math.cos(t * math.pi)) * 0.5
end

function E.cosineIn(t)
  t = E.clamp(t, 0, 1)
  return 1 - math.cos(t * math.pi * 0.5)
end

function E.cosineOut(t)
  t = E.clamp(t, 0, 1)
  return math.sin(t * math.pi * 0.5)
end

function E.expIn(t)
  t = E.clamp(t, 0, 1)
  if t == 0 then
    return 0
  end
  return math.pow(2, 10 * (t - 1))
end

function E.expOut(t)
  t = E.clamp(t, 0, 1)
  if t >= 1 then
    return 1
  end
  return 1 - math.pow(2, -10 * t)
end

function E.expInOut(t)
  t = E.clamp(t, 0, 1)
  if t == 0 then
    return 0
  end
  if t == 1 then
    return 1
  end
  if t < 0.5 then
    return 0.5 * math.pow(2, 20 * t - 10)
  end
  return 1 - 0.5 * math.pow(2, -20 * t + 10)
end

-- The `expo` spelling, matching CSS and every tweening library written since;
-- `expIn`/`expOut`/`expInOut` above are the sibling's names for the same
-- curves and stay so a ported file keeps working.
E.expoIn = E.expIn
E.expoOut = E.expOut
E.expoInOut = E.expInOut

--- Look a curve up by name, so a caller can be configured rather than edited.
function E.apply(name, t)
  local fn = E[name]
  if type(fn) ~= "function" then fn = E.expInOut end
  return fn(t)
end

function E.lerp(a, b, t)
  return a + (b - a) * t
end

-- Frame-rate independent exponential smoothing.
function E.smooth(current, target, dt, speed)
  local k = 1 - math.exp(-speed * dt)
  return current + (target - current) * k
end

return E
