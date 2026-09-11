-- The display settings that survive a restart, and the rule that decides an
-- orientation when the player has not.
--
-- Headless: `Layout`'s module body touches no `love`, and everything asserted
-- here is either a pure function or a round trip through an injected
-- `Layout.storage`. The viewport arithmetic needs a graphics context and
-- lives in `tests/test_layout.lua`.
--
-- ## The bug this file exists to prevent
--
-- The browser client got vertical/horizontal wrong in a tall window, and the
-- shape of that bug is: a mode that was *inferred* once gets written to
-- storage, read back as though the player had *chosen* it, and then defended
-- forever — so a landscape inferred on a wide monitor survives into a window
-- shaped like a portrait and never re-evaluates.
--
-- The fix is one persisted boolean. A restored pin is as strong as a pressed
-- one; a restored inference is not a pin at all. These cases assert both
-- halves and the migration case in between.

local T = require("tests.framework")
local Layout = require("src.layout")

--- A `Layout.storage` that lives in a table.
local function memory_storage(seed)
  local held = seed
  return {
    save = function(record) held = record end,
    load = function() return held end,
    peek = function() return held end,
    set = function(record) held = record end,
  }
end

--- Save the current state and read it back into a fresh one, the way a
--- restart does.
local function round_trip(storage)
  local saved_mode, saved_pinned, saved_fullscreen =
    Layout.mode, Layout.pinned, Layout.fullscreen
  Layout.save()
  -- Whatever the next launch starts from, before `load` runs.
  Layout.mode, Layout.pinned, Layout.fullscreen = "landscape", false, false
  Layout.load()
  return {
    mode = Layout.mode, pinned = Layout.pinned, fullscreen = Layout.fullscreen,
    was = { mode = saved_mode, pinned = saved_pinned, fullscreen = saved_fullscreen },
    record = storage.peek(),
  }
end

return function()
  T.section("display — the orientation rule (pure)")

  T.case("orientationFor reads the window, not the mode", function()
    T.eq(Layout.orientationFor(1280, 720), "landscape")
    T.eq(Layout.orientationFor(720, 1280), "portrait")
    T.eq(Layout.orientationFor(1920, 1080), "landscape")
    T.eq(Layout.orientationFor(1080, 1920), "portrait")
    -- The dead zone around square, so dragging a border does not thrash.
    T.eq(Layout.orientationFor(800, 800), "landscape")
    T.eq(Layout.orientationFor(800, 839), "landscape")
    T.eq(Layout.orientationFor(800, 841), "portrait")
    -- Degenerate inputs answer rather than raise: this runs on every resize,
    -- and a minimised window reports 0x0 on some platforms.
    T.eq(Layout.orientationFor(0, 500), "landscape")
    T.eq(Layout.orientationFor(nil, nil), "landscape")
  end)

  T.section("display — fullscreen type")

  T.case("desktop by default, exclusive only on request", function()
    local saved = Layout.fullscreenPref
    Layout.fullscreenPref = nil
    -- The default matters: `exclusive` changes the display mode, and a game
    -- that exits badly while in it leaves the desktop rearranged.
    T.eq(Layout.fullscreenType(), "desktop")
    for _, want in ipairs({ "exclusive", "EXCLUSIVE", "Exclusive" }) do
      Layout.fullscreenPref = want
      T.eq(Layout.fullscreenType(), "exclusive")
    end
    for _, junk in ipairs({ "", "yes", "true", "windowed", "1" }) do
      Layout.fullscreenPref = junk
      T.eq(Layout.fullscreenType(), "desktop", ("%q falls back"):format(junk))
    end
    Layout.fullscreenPref = saved
  end)

  T.section("display — what survives a restart")

  T.case("fullscreen is remembered", function()
    local storage = memory_storage()
    Layout.storage = storage
    Layout.mode, Layout.pinned, Layout.fullscreen = "landscape", false, true
    local after = round_trip(storage)
    T.eq(after.fullscreen, true, "a player who quit in fullscreen comes back to it")
    T.eq(after.record.fullscreen, true)

    Layout.fullscreen = false
    local off = round_trip(storage)
    T.eq(off.fullscreen, false)
  end)

  T.case("a PINNED orientation comes back as a pin", function()
    local storage = memory_storage()
    Layout.storage = storage
    Layout.mode, Layout.pinned, Layout.fullscreen = "portrait", true, false
    local after = round_trip(storage)
    T.eq(after.mode, "portrait")
    T.eq(after.pinned, true, "the player asked for this and is still asking")
    T.eq(after.record.pinned, true, "and the flag is actually on disk")
  end)

  T.case("an INFERRED orientation does not come back as a pin", function()
    -- This is the browser's bug, in one case. The mode was never chosen — it
    -- was derived from a wide window — so the next launch must derive it
    -- again rather than treating last week's window shape as an instruction.
    local storage = memory_storage()
    Layout.storage = storage
    Layout.mode, Layout.pinned, Layout.fullscreen = "landscape", false, false
    local after = round_trip(storage)
    T.eq(after.mode, "landscape", "the last shape is still a reasonable starting guess")
    T.eq(after.pinned, false, "but it is a guess, and it will be re-derived")
    T.eq(after.record.pinned, false)
  end)

  T.case("a record written before `pinned` existed reads as not pinned", function()
    -- The safe side of the migration: an unpinned mode is re-derived from
    -- the window, and a wrongly-pinned one never is. Guessing "pinned" for
    -- an old record would hand every existing install the bug permanently.
    local storage = memory_storage({ mode = "portrait", fullscreen = true })
    Layout.storage = storage
    Layout.mode, Layout.pinned, Layout.fullscreen = "landscape", true, false
    Layout.load()
    T.eq(Layout.mode, "portrait", "the old mode is still honoured as a starting point")
    T.eq(Layout.pinned, false, "but not as a pin")
    T.eq(Layout.fullscreen, true)
  end)

  T.case("junk in storage is ignored rather than believed", function()
    local storage = memory_storage({ mode = "sideways", pinned = "yes", fullscreen = "on" })
    Layout.storage = storage
    Layout.mode, Layout.pinned, Layout.fullscreen = "landscape", false, false
    Layout.load()
    T.eq(Layout.mode, "landscape", "an unknown mode does not become the mode")
    T.eq(Layout.pinned, false, "`pinned` is a boolean or it is false")
    T.eq(Layout.fullscreen, false)

    Layout.storage = memory_storage("not a table")
    T.eq(Layout.load(), false)
    Layout.storage = memory_storage(nil)
    T.eq(Layout.load(), false)
  end)

  T.case("with no storage at all, save and load are quiet no-ops", function()
    Layout.storage = nil
    Layout.save()
    T.eq(Layout.load(), false)
  end)

  T.section("display — setOrientation pins, inference does not")

  T.case("naming an orientation pins it; the viewport inferring one does not", function()
    local storage = memory_storage()
    Layout.storage = storage
    Layout.pinned = false
    Layout.mode = "landscape"

    -- What `updateViewport` does when the window changes shape.
    Layout.setOrientation("portrait", false)
    T.eq(Layout.mode, "portrait")
    T.eq(Layout.pinned, false, "an inference is not a choice")

    -- What F1 does.
    Layout.setOrientation("landscape", true)
    T.eq(Layout.mode, "landscape")
    T.eq(Layout.pinned, true)
    T.eq(storage.peek().pinned, true, "and it is saved immediately, not at exit")

    -- Re-pinning the mode it is already in still counts as a pin: pressing
    -- F1 for the orientation you can already see is still you insisting.
    Layout.pinned = false
    Layout.setOrientation("landscape", true)
    T.eq(Layout.pinned, true)
  end)

  T.case("the footer label distinguishes a pin from an inference", function()
    Layout.storage = memory_storage()
    Layout.pinned, Layout.mode = false, "landscape"
    T.eq(Layout.orientationLabel(), "auto")
    Layout.pinned, Layout.mode = true, "portrait"
    T.eq(Layout.orientationLabel(), "portrait")
    Layout.pinned, Layout.mode = true, "landscape"
    T.eq(Layout.orientationLabel(), "landscape")
  end)

  -- Leave the module as the rest of the suite expects to find it.
  Layout.storage = nil
  Layout.pinned = false
  Layout.fullscreen = false
  Layout.mode = "landscape"
end
