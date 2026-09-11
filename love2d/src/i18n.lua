-- The interface's own words, in six languages.
--
-- **Ported from `CausewaybayGolang/love2d/src/i18n.lua`**, which had already
-- solved this for the same six (plus Spanish) on the same engine. What is
-- taken is the shape that matters: translations are **keyed by the English
-- string**, so a call site reads as the sentence it draws and a language that
-- has not been written yet falls back to English rather than to a key name.
--
--     UI.text(I18n.t("PICK A LAND"), …)
--
-- What is different from the sibling: it keeps its first three languages in
-- one inline table and the later ones in `src/lang/<code>.lua`. Ours are all
-- in `src/lang/<code>.lua`, because there was no first three — every language
-- here arrived at once, and one mechanism is easier to keep honest than two.
--
-- ## What is translated, and what is not
--
-- **The interface only.** The 138 quests are content, owned elsewhere, and a
-- quest brief is a specification of a program — mistranslating one would make
-- a test fail for a reason the player cannot see. So a Korean player gets a
-- Korean interface around an English quest, which is what a Korean
-- programmer's editor looks like anyway.
--
-- A quest title, a quest id and a compiler message are **code identifiers**
-- and are drawn as such — in the code face, next to the id — rather than as
-- prose that somebody forgot to translate. See `docs/decisions.md`.
--
-- ## Technical terms stay in English, deliberately
--
-- `borrow checker`, `ownership`, `lifetime`, `goroutine`, `channel`, `trait`,
-- `mutex`. An English technical term inside a Korean sentence is what Korean
-- programmers actually write; an invented calque is not, and would be worse
-- than leaving the whole sentence in English. Where a translation was a guess
-- rather than a term in use it is marked `UNREVIEWED` in the language file and
-- listed in the report.
--
-- ## Cantonese is not Chinese
--
-- `yue` is Hong Kong written Cantonese — 嘅, 咗, 喺, 冇 — in traditional
-- characters, and `zh` is Standard Written Chinese in simplified. They share a
-- script and are not the same language; a Cantonese speaker reading Standard
-- Written Chinese labelled 粵語 notices in one line. The sibling made the same
-- split independently, which is the best evidence available that it is right.
--
-- LÖVE-free, like `src/store.lua` and `src/editor.lua`: `make check-layering`
-- asserts it, and the completeness cases run headless.

local I18n = { lang = "en" }

--- The order the switch cycles in. English first because it is the source.
I18n.LANGS = { "en", "ko", "yue", "zh", "ja", "cs" }

--- What each language calls itself. A language named in somebody else's
--- language is a language nobody can find.
I18n.NAMES = {
  en = "EN",
  ko = "한국어",
  yue = "粵語",
  zh = "简体中文",
  ja = "日本語",
  cs = "Čeština",
}

--- The two-or-three letter form, for places too narrow for the real name.
---
--- The footer's language button is one of them: `한국어` is three
--- double-width cells where `KO` is two single ones, and the button sits in a
--- strip that already clips its hint on a 720-wide canvas.
I18n.CODES = {
  en = "EN", ko = "KO", yue = "YUE", zh = "ZH", ja = "JA", cs = "CS",
}

--- The by-English tables, loaded once. A language with no file is English.
local TR = {}
for _, code in ipairs(I18n.LANGS) do
  if code ~= "en" then
    local ok, table_ = pcall(require, "src.lang." .. code)
    if ok and type(table_) == "table" then TR[code] = table_ end
  end
end
I18n.TR = TR

--- Translate one English string. Extra arguments are `string.format`ed in.
---
--- A missing translation returns the English, which is the whole reason the
--- key is the English: a half-translated screen reads as a screen, not as a
--- screen with `lands.title.pick` written on it.
function I18n.t(english, ...)
  if type(english) ~= "string" then return "" end
  local tr = TR[I18n.lang]
  local out = (tr and tr[english]) or english
  if select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, out, ...)
    if ok then return formatted end
    -- A translation whose `%s` count does not match the English would
    -- otherwise raise inside a draw call and take the frame with it. The
    -- English is always right, because it is the string the call site wrote.
    local fallback_ok, fallback = pcall(string.format, english, ...)
    return fallback_ok and fallback or english
  end
  return out
end

--- True when this language is written in a script the Latin faces cannot
--- draw, so a layout can give it room rather than discover it needs some.
function I18n.is_cjk(lang)
  lang = lang or I18n.lang
  return lang == "ko" or lang == "yue" or lang == "zh" or lang == "ja"
end

function I18n.set(lang)
  if I18n.NAMES[lang] then I18n.lang = lang end
  return I18n.lang
end

function I18n.name(lang)
  return I18n.NAMES[lang or I18n.lang] or "EN"
end

function I18n.code(lang)
  return I18n.CODES[lang or I18n.lang] or "EN"
end

--- Next language, wrapping. The switch is a cycle for the same reason the
--- orientation one is: six states and one button.
function I18n.cycle()
  for i, code in ipairs(I18n.LANGS) do
    if code == I18n.lang then
      return I18n.set(I18n.LANGS[i % #I18n.LANGS + 1])
    end
  end
  return I18n.set("en")
end

--- Every English string any language file has a translation for — the corpus
--- the completeness and font-coverage cases run over.
function I18n.keys()
  local seen, out = {}, {}
  for _, tr in pairs(TR) do
    for english in pairs(tr) do
      if not seen[english] then
        seen[english] = true
        out[#out + 1] = english
      end
    end
  end
  table.sort(out)
  return out
end

return I18n
