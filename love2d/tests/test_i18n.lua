-- The six languages, and the two ways a translation breaks a screen.
--
-- Headless: `src/i18n.lua` and every file under `src/lang/` are LÖVE-free, so
-- the whole catalogue can be checked without a window. What *cannot* be
-- checked here is whether the fonts can draw it — that needs a graphics
-- context and lives in `tests/test_fonts.lua`.

local T = require("tests.framework")
local I18n = require("src.i18n")

--- `%s`, `%d`, `%02d` … in the order they appear.
local function specifiers(text)
  local out = {}
  for spec in tostring(text):gmatch("%%[-+ #0]*%d*%.?%d*[diouxXeEfgGqscaA%%]") do
    if spec ~= "%%" then out[#out + 1] = spec end
  end
  return table.concat(out, " ")
end

return function()
  T.section("i18n — the six languages SPEC §1.1 asks for")

  T.case("every language is declared, named in itself, and has a code", function()
    T.same(I18n.LANGS, { "en", "ko", "yue", "zh", "ja", "cs" })
    for _, code in ipairs(I18n.LANGS) do
      T.ok(I18n.NAMES[code] ~= nil and I18n.NAMES[code] ~= "",
        code .. " names itself")
      T.ok(I18n.CODES[code] ~= nil, code .. " has a short form for the button")
      T.ok(#I18n.CODES[code] <= 3, code .. "'s short form fits a footer chip")
    end
    -- A language named in somebody else's language is a language nobody can
    -- find, so these are the endonyms and not "Korean" and "Japanese".
    T.eq(I18n.NAMES.ko, "한국어")
    T.eq(I18n.NAMES.ja, "日本語")
    T.eq(I18n.NAMES.cs, "Čeština")
  end)

  T.case("Cantonese is held apart from Chinese, in its own script", function()
    -- They share a script and are not the same language. Written Cantonese
    -- uses characters Standard Written Chinese does not, and a Cantonese
    -- reader spots the substitution in one line.
    local yue, zh = I18n.TR.yue, I18n.TR.zh
    T.ok(yue ~= nil and zh ~= nil, "both files exist")
    local corpus = table.concat((function()
      local out = {}
      for _, v in pairs(yue) do out[#out + 1] = v end
      return out
    end)(), "")
    local found = 0
    for _, ch in ipairs({ "嘅", "咗", "喺", "冇", "唔" }) do
      if corpus:find(ch, 1, true) then found = found + 1 end
    end
    T.ok(found >= 3,
      "written Cantonese uses its own characters, found " .. found .. " of 5")
    -- And they do not simply agree everywhere, which is what a relabelled
    -- copy of one file would look like.
    local differ = 0
    for english, text in pairs(yue) do
      if zh[english] and zh[english] ~= text then differ = differ + 1 end
    end
    T.ok(differ > 20, "the two differ in " .. differ .. " strings")
  end)

  T.section("i18n — a translation cannot take a frame down")

  T.case("every translation keeps the English's format specifiers", function()
    -- `("%d / %d CLEARED"):format(a, b)` against a translation that lost one
    -- `%d` raises inside a draw call. `I18n.t` catches it and falls back, but
    -- a screen that silently reverts to English is a bug that ships; this is
    -- where it is supposed to be caught.
    for _, lang in ipairs(I18n.LANGS) do
      local tr = I18n.TR[lang]
      if tr then
        for english, text in pairs(tr) do
          T.eq(specifiers(text), specifiers(english),
            ("%s: %q has the wrong specifiers for %q"):format(lang, text, english))
        end
      end
    end
  end)

  T.case("no translation is blank, and none is left as the English", function()
    for _, lang in ipairs(I18n.LANGS) do
      local tr = I18n.TR[lang]
      if tr then
        local same = 0
        for english, text in pairs(tr) do
          T.ok(type(text) == "string" and text:match("%S") ~= nil,
            ("%s: %q is blank"):format(lang, english))
          if text == english then same = same + 1 end
        end
        -- A handful legitimately match — `HACKER` is the section's own name
        -- in every language — but a file that matched throughout would be a
        -- copy of the English with a different filename.
        T.ok(same < 6, lang .. " has " .. same .. " untranslated entries")
      end
    end
  end)

  T.case("every language covers the same strings", function()
    -- A missing string falls back to English by design, which is what makes a
    -- half-finished language usable. It is still worth knowing.
    local keys = I18n.keys()
    T.ok(#keys > 60, "the catalogue is " .. #keys .. " strings")
    for _, lang in ipairs(I18n.LANGS) do
      if lang ~= "en" then
        local tr = I18n.TR[lang] or {}
        local missing = {}
        for _, english in ipairs(keys) do
          if tr[english] == nil then missing[#missing + 1] = english end
        end
        T.eq(#missing, 0,
          lang .. " is missing " .. #missing .. ": " .. table.concat(missing, " | "))
      end
    end
  end)

  T.case("every English string the interface asks for has a translation", function()
    -- **The regression guard for the gap this round actually had.** The first
    -- pass wrapped every `I18n.t("…")` that a grep could see and stopped
    -- there, which left about half the prose behind: strings built with `..`
    -- across three lines, strings built with `:format` before being drawn,
    -- and module-level text tables that are populated at load time and
    -- translated (or not) at the use site. None of those look like a call to
    -- a grep, and 6,000 assertions had nothing to say about any of them.
    --
    -- So this reads the sources instead of trusting the call sites: every
    -- string literal that reaches `I18n.t` in `src/`, against every language.
    local keys = {}

    --- Every string literal that reaches `I18n.t`, including the ones spelled
    --- across several lines.
    ---
    --- Written as a walk rather than a pattern on purpose. A Lua pattern
    --- cannot cross a newline with `[^\n]`, and the multi-line form —
    ---
    ---     I18n.t("a sentence longer than one line "
    ---       .. "continued on the next")
    ---
    --- — is exactly the form this case exists to catch. A pattern that stops
    --- at the first newline finds 127 of the 140 keys and passes anyway,
    --- which is the same shape of hole as the bug it is guarding.
    local function scan(path)
      local f = io.open(path, "r")
      if not f then return end
      local src = f:read("*a")
      f:close()
      local at = 1
      while true do
        local s_, e_ = src:find("I18n.t(", at, true)
        if not s_ then break end
        at = e_ + 1
        local i, parts = e_ + 1, {}
        while true do
          i = src:find("%S", i)
          if not i or src:sub(i, i) ~= '"' then break end
          local j = i + 1
          local buf = {}
          while j <= #src do
            local c = src:sub(j, j)
            if c == "\\" then buf[#buf + 1] = src:sub(j, j + 1); j = j + 2
            elseif c == '"' then break
            else buf[#buf + 1] = c; j = j + 1 end
          end
          parts[#parts + 1] = table.concat(buf)
          i = j + 1
          -- A `..` here means the sentence continues, on this line or the
          -- next; anything else ends the first argument.
          local k = src:find("%S", i)
          if k and src:sub(k, k + 1) == ".." then i = k + 2 else break end
        end
        if #parts > 0 then
          keys[(table.concat(parts):gsub("\\n", "\n"))] = true
        end
      end
    end
    for _, name in ipairs({
      "app", "ui", "layout",
      "scenes/boot", "scenes/login", "scenes/lands", "scenes/categories",
      "scenes/map", "scenes/quest", "scenes/result", "scenes/stats",
      "scenes/ai", "scenes/search", "scenes/playground",
    }) do
      scan("src/" .. name .. ".lua")
    end

    local n = 0
    for _ in pairs(keys) do n = n + 1 end
    -- A floor high enough that losing the multi-line form fails here. The
    -- pattern this replaced found 127; the walk finds 140.
    T.ok(n >= 138, "found " .. n .. " translatable strings in the sources")

    -- Proper nouns and key names, English on purpose. A name is not a word.
    local english_on_purpose = {
      ["CAUSEWAYBAY"] = true, ["HACKER"] = true, ["TAB"] = true,
      ["RUST"] = true, ["GO"] = true,
    }
    for _, lang in ipairs(I18n.LANGS) do
      if lang ~= "en" then
        local tr = I18n.TR[lang]
        T.ok(tr ~= nil, lang .. " has a table")
        local missing = {}
        for key in pairs(keys) do
          if not english_on_purpose[key] and not (tr and tr[key]) then
            missing[#missing + 1] = key
          end
        end
        table.sort(missing)
        T.eq(#missing, 0, lang .. " is missing: "
          .. table.concat(missing, " | "):sub(1, 300))
      end
    end
  end)

  T.section("i18n — the lookup itself")

  T.case("an untranslated string comes back as the English, not as a key", function()
    local was = I18n.lang
    I18n.set("ko")
    T.eq(I18n.t("PICK A LAND"), "땅을 고르세요")
    T.eq(I18n.t("a string nobody has translated"), "a string nobody has translated",
      "the key IS the English, which is what makes a partial screen readable")
    T.eq(I18n.t("%d / %d CLEARED", 1, 18), "1 / 18 클리어")
    I18n.set("en")
    T.eq(I18n.t("PICK A LAND"), "PICK A LAND")
    T.eq(I18n.t(nil), "")
    I18n.set(was)
  end)

  T.case("a bad language name changes nothing", function()
    local was = I18n.lang
    I18n.set("en")
    I18n.set("klingon")
    T.eq(I18n.lang, "en")
    I18n.set(was)
  end)

  T.case("the cycle visits every language and comes back", function()
    local was = I18n.lang
    I18n.set("en")
    local seen = {}
    for _ = 1, #I18n.LANGS do seen[#seen + 1] = I18n.cycle() end
    T.same(seen, { "ko", "yue", "zh", "ja", "cs", "en" })
    I18n.set(was)
  end)

  T.case("key names survive translation", function()
    -- `TAB`, `ENTER`, `ESC`, `F5` and `CTRL-S` are printed on the keyboard in
    -- front of the player. A translation that renamed them would be telling
    -- somebody to press a key that does not exist.
    for _, lang in ipairs(I18n.LANGS) do
      local tr = I18n.TR[lang]
      if tr then
        for english, text in pairs(tr) do
          for _, key in ipairs({ "ENTER", "ESC", "TAB", "CTRL%-S", "CTRL%-N",
                                 "F2", "F5", "F6", "F7", "F8", "F10", "%$EDITOR" }) do
            if english:find(key) then
              T.ok(text:find(key) ~= nil,
                ("%s: %q dropped the key name %s"):format(lang, text, key))
            end
          end
        end
      end
    end
  end)

  T.case("the module never touches love", function()
    T.no_love("src/i18n.lua")
    for _, code in ipairs({ "ko", "yue", "zh", "ja", "cs" }) do
      T.no_love("src/lang/" .. code .. ".lua")
    end
  end)
end
