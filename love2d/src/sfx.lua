-- Chip audio, synthesised rather than shipped.
--
-- Square and noise, a handful of short cues, generated into `SoundData` at
-- load. No audio files: the whole palette is eight cues and a wave table is
-- smaller and more honest than eight wavs of a square wave.
--
-- Muted with F4, and silent when `love.audio` is not there at all (which is
-- the case under `--test`, where the audio module is switched off).

local SFX = { enabled = true, sources = {}, ready = false }

local RATE = 22050

local function square(t, freq, duty)
  local phase = (t * freq) % 1
  return phase < (duty or 0.5) and 1 or -1
end

--- Render one cue into a SoundData.
---
--- `spec` is a list of `{ freq, seconds, wave, gain }` steps; `wave` is
--- "square" (a note) or "noise" (a hit).
local function render(spec)
  local total = 0
  for _, step in ipairs(spec) do total = total + step[2] end
  local frames = math.max(1, math.floor(total * RATE))
  local data = love.sound.newSoundData(frames, RATE, 16, 1)
  local i = 0
  for _, step in ipairs(spec) do
    local freq, seconds, wave, gain = step[1], step[2], step[3] or "square", step[4] or 0.22
    local n = math.floor(seconds * RATE)
    for k = 0, n - 1 do
      if i >= frames then break end
      local t = k / RATE
      -- A short linear decay is the whole envelope; anything more elaborate
      -- stops sounding like a Mega Drive.
      local env = 1 - (k / math.max(1, n))
      local value
      if wave == "noise" then
        value = (love.math.random() * 2 - 1)
      else
        value = square(t, freq, 0.5)
      end
      data:setSample(i, value * env * gain)
      i = i + 1
    end
  end
  return data
end

local CUES = {
  move = { { 660, 0.04 } },
  select = { { 880, 0.05 }, { 1320, 0.06 } },
  back = { { 520, 0.05 }, { 330, 0.06 } },
  type = { { 1400, 0.012, "square", 0.07 } },
  submit = { { 440, 0.06 }, { 660, 0.06 }, { 880, 0.08 } },
  accepted = { { 660, 0.07 }, { 880, 0.07 }, { 1046, 0.09 }, { 1320, 0.18 } },
  rejected = { { 330, 0.10 }, { 262, 0.16 } },
  stamp = { { 180, 0.05, "noise", 0.3 }, { 1046, 0.12 } },
  locked = { { 200, 0.08, "noise", 0.18 } },
  -- A loop closed in the editor: two quick notes going up, a coin picked up.
  coin = { { 988, 0.05 }, { 1319, 0.12 } },
}

function SFX.load()
  if not love.audio or not love.sound then
    SFX.ready = false
    return
  end
  for name, spec in pairs(CUES) do
    local ok, data = pcall(render, spec)
    if ok then
      SFX.sources[name] = love.audio.newSource(data, "static")
    end
  end
  SFX.ready = true
end

function SFX.play(name)
  if not (SFX.ready and SFX.enabled) then return end
  local source = SFX.sources[name]
  if not source then return end
  source:stop()
  source:play()
end

function SFX.toggle()
  SFX.enabled = not SFX.enabled
  return SFX.enabled
end

return SFX
