-- The poster's arithmetic, headless: pouring a program into a disc, fitting
-- a column, the label's payload, the file name, the mascot, the tokens, and
-- the reader's verdicts with a stand-in for the library's `recover`.
--
-- The drawing needs a window and `libcwbh_ffi`; what is asserted is
-- everything the drawing is told, the same properties `frontend/tests/
-- poster.test.ts` pins for the browser — the two clients make the same
-- picture from the same rules.

local T = require("tests.framework")
local Poster = require("src.poster")
local Reader = require("src.diskreader")

--- A monospace face where every cell is half the size: 10px type is 5 wide.
local function cell_w(px)
  return px / 2
end

return function()
  T.section("poster — fitting a column")

  T.case("takes the largest size at which every line fits", function()
    local fit = Poster.fit_mono({ "abcd", "ef" }, 100, 100, cell_w, 40, 8)
    T.eq(fit.px, 40)
    T.eq(#fit.rows, 2)
    T.eq(fit.rows[1].text, "abcd")
    T.eq(fit.hidden, 0)
  end)

  T.case("wraps a long line by column, and counts what it could not show", function()
    local fit = Poster.fit_mono({ "abcdefghij" }, 25, 200, cell_w, 10, 10)
    T.eq(fit.rows[1].text, "abcde")
    T.eq(fit.rows[2].text, "fghij")
    T.eq(fit.rows[2].col, 5)
    local lines = {}
    for i = 1, 20 do
      lines[i] = "line " .. i
    end
    local tight = Poster.fit_mono(lines, 200, 44, cell_w, 10, 10, 1.1)
    T.eq(#tight.rows, 4)
    T.eq(tight.rows[4].line, 0)
    T.eq(tight.rows[4].text, "… 17 more lines")
    T.eq(tight.hidden, 17)
  end)

  T.case("elides by character, so a cut never splits a UTF-8 sequence", function()
    local function bytes(t)
      return #t
    end
    local cut = Poster.elide("a · b · c · d", 9, bytes)
    T.ok(cut:sub(-3) == "…", "ends in the ellipsis")
    -- Every byte sequence in the result is a whole character.
    local rebuilt = {}
    for ch in cut:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      rebuilt[#rebuilt + 1] = ch
    end
    T.eq(table.concat(rebuilt), cut)
    T.eq(Poster.elide("short", 100, bytes), "short")
  end)

  T.section("poster — pouring a program into the disc")

  T.case("cuts every row to the chord, left of the label only", function()
    local slots = Poster.disc_slots(100, 40, 1, 10, 1)
    T.ok(#slots > 0)
    for _, s in ipairs(slots) do
      local far = math.max(math.abs(s.y), math.abs(s.y + 10))
      local hw = math.sqrt(100 * 100 - far * far)
      T.near(s.x, -hw, 1e-6)
      T.ok(s.x < 0, "every run starts left of centre")
      if s.y < 40 and s.y + 10 > -40 then
        T.ok(s.x + s.cap <= 0, "a row through the label stops before it")
      end
    end
    T.near(slots[1].y, -(slots[#slots].y + 10), 1e-6, "centred vertically")
  end)

  T.case("pours whole lines, moving a long one down to a groove that holds it", function()
    local slots = { { x = 0, y = 0, cap = 4 }, { x = 0, y = 10, cap = 8 }, { x = 0, y = 20, cap = 12 } }
    local alone = Poster.pour({ "use std::io;" }, slots)
    T.eq(alone[1].y, 20)
    T.eq(alone[1].text, "use std::io;")
    T.eq(Poster.pour({ "use std::io;", "fn main()" }, slots), nil, "no groove left for the second")
    local fits = Poster.pour({ "ab", "fn main()" }, slots)
    T.eq(fits[1].y, 0)
    T.eq(fits[2].y, 20)
    -- Only a line longer than every groove is wrapped, and then by column.
    local wrapped = Poster.pour({ "abcdefghijklmnop" }, slots)
    T.eq(wrapped[1].text, "abcd")
    T.eq(wrapped[2].col, 4)
    -- An empty line takes a groove of its own.
    local shaped = Poster.pour({ "a", "", "b" }, slots)
    T.eq(shaped[2].text, "")
  end)

  T.case("fit_disc shrinks the type rather than break a line, until the floor", function()
    local lines = { "fn main() {", '    println!("hello from {city}");', "}" }
    local fit = Poster.fit_disc(lines, 50, 0, cell_w, 10, 4)
    for _, g in ipairs(fit.grooves) do
      T.eq(g.col, 0, "no line broken")
    end
    T.ok(fit.px < 10)
    T.eq(fit.hidden, 0)
    local many = {}
    for i = 1, 200 do
      many[i] = "line number " .. i
    end
    local floor = Poster.fit_disc(many, 60, 0, cell_w, 20, 10)
    T.eq(floor.px, 10)
    T.ok(floor.hidden > 0)
    local last = floor.grooves[#floor.grooves]
    T.eq(last.line, 0)
    T.ok(last.text:sub(1, 3) == "…", "the last groove says what is missing")
  end)

  T.section("poster — the label")

  local ADDR = "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F"
  local SIG = "0x" .. ("ab"):rep(65)
  local function never_dense()
    return false
  end
  local function always_dense()
    return true
  end
  local function fake_keccak(s)
    return ("%064x"):format(#s)
  end

  T.case("carries the source, the address and the signature, and comes back apart", function()
    local src = 'fn main() {\n    println!("héllo");\n}\n'
    local text, hashed = Poster.payload(ADDR, SIG, "rust", src, never_dense, fake_keccak)
    T.eq(hashed, false)
    local back = Poster.parse_payload(text)
    T.eq(back.address, ADDR)
    T.eq(back.signature, SIG)
    T.eq(back.lang, "rust")
    T.eq(back.body, src)
    T.eq(Poster.parse_payload(Poster.payload(ADDR, nil, "go", "x", never_dense, fake_keccak)).signature, nil)
  end)

  T.case("hashes a program whose label would be too dense, and says so", function()
    local text, hashed = Poster.payload(ADDR, SIG, "python", "x", always_dense, fake_keccak)
    T.eq(hashed, true)
    T.eq(Poster.parse_payload(text).body, "keccak256:" .. fake_keccak("x"))
  end)

  T.case("refuses a payload that is not one of ours", function()
    T.eq(Poster.parse_payload("hello\nworld\n\n\n"), nil)
    T.eq(Poster.parse_payload("CWBH1\nonly"), nil)
  end)

  T.section("poster — the rest of the picture")

  T.case("names the file after the pad and the minute, safely", function()
    local at = os.time({ year = 2026, month = 9, day = 16, hour = 9, min = 7, sec = 0, isdst = false })
    local stamp = os.date("!%Y%m%d-%H%M", at)
    T.eq(Poster.file_name("My Pad / v2!", at), "cwbhacker-my-pad-v2-" .. stamp .. ".png")
    T.eq(Poster.file_name("   ", at), "cwbhacker-pad-" .. stamp .. ".png")
  end)

  T.case("the mascot takes the pose the run earned", function()
    T.eq(Poster.mascot_for("rust", { ok = true }), "mascot_rust_hacker")
    T.eq(Poster.mascot_for("go", { ok = false, compile_error = true }), "mascot_go_basic")
    T.eq(Poster.mascot_for("cpp", { ok = false, compile_error = false }), "mascot_cpp_advanced")
    T.eq(Poster.mascot_for("python", nil), "mascot_python_advanced")
    local run = Poster.run_of({ outcome = "compile_error", compile_ms = 12, run_ms = 0 }, {})
    T.eq(run.outcome, "IT DID NOT COMPILE")
    T.eq(run.compile_error, true)
    T.eq(Poster.run_of(nil), nil)
  end)

  T.case("colours the code from a small grammar", function()
    local toks = Poster.tokens('fn main() { let x = 42; println!("hi"); } // done', "rust", false)
    local function tone_of(word)
      for _, t in ipairs(toks) do
        if t.text:find(word, 1, true) then
          return t.tone
        end
      end
    end
    T.eq(tone_of("fn"), "keyword")
    T.eq(tone_of("42"), "number")
    T.eq(tone_of('"hi"'), "string")
    T.eq(tone_of("// done"), "comment")
    T.eq(tone_of("println"), "call")
    local _, open = Poster.tokens("/* starts", "cpp", false)
    T.eq(open, true, "a block comment carries to the next line")
    local py = Poster.tokens("def f(): return None", "python", false)
    T.eq(py[1].tone, "keyword")
  end)

  T.section("disk reader — the verdict")

  local function recover(message, signature)
    -- The stand-in: the fixture signature over exactly `SRC` is ADDR's.
    if signature == SIG and message == "fn main() {}\n" then
      return ADDR
    end
    return "0x0000000000000000000000000000000000000000"
  end
  local SRC = "fn main() {}\n"

  T.case("is verified, forged or unsigned", function()
    T.eq(Reader.judge(SRC, ADDR, SIG, recover), "verified")
    T.eq(Reader.judge(SRC, ADDR:lower(), SIG, recover), "verified")
    T.eq(Reader.judge(SRC .. " ", ADDR, SIG, recover), "forged")
    T.eq(Reader.judge(SRC, ADDR, nil, recover), "unsigned")
  end)

  T.case("reads the chunks, the label, and knows a hashed label", function()
    local d =
      Reader.from_chunks({ Source = SRC, Signer = ADDR, Signature = SIG, Lang = "rust", Title = "t" }, recover)
    T.eq(d.verdict, "verified")
    T.eq(d.title, "t")
    T.eq(d.via, "chunks")
    T.eq(Reader.from_chunks({ Source = SRC }, recover), nil)
    local l = Reader.from_label(Poster.payload(ADDR, SIG, "rust", SRC, never_dense, fake_keccak), recover)
    T.eq(l.verdict, "verified")
    T.eq(l.via, "label")
    local h = Reader.from_label(Poster.payload(ADDR, SIG, "rust", SRC, always_dense, fake_keccak), recover)
    T.eq(h.verdict, "hashed")
    T.eq(h.source, "")
    T.eq(Reader.from_label("https://example.com", recover), nil)
    T.eq(Reader.from_read({ chunks = {}, label = nil }, recover), nil)
  end)

  T.case("knows a deflated label, through the inflater, and refuses one it cannot inflate", function()
    -- What the web poster writes once the plain text is too dense: the
    -- source raw-deflated, base64, behind `deflate:`. The inflater is the
    -- library's; here it is a table lookup, so the rule is what is tested.
    local packed = "eJxLTEoGAAJNASc="
    local inflate = function(b64) return b64 == packed and SRC or nil end
    local text = ("CWBH1\n%s\n%s\nrust\ndeflate:%s"):format(ADDR, SIG, packed)
    local d = Reader.from_label(text, recover, inflate)
    T.ok(d, "a deflated label is a disk")
    T.eq(d.source, SRC)
    T.eq(d.verdict, "verified")
    T.eq(d.via, "label")
    -- Through `from_read`, the way the playground takes it.
    T.eq(Reader.from_read({ chunks = {}, label = text }, recover, inflate).verdict, "verified")
    -- No inflater, or a body that will not inflate: not a disk — never
    -- "forged", which is what taking the base64 for the program would say.
    T.eq(Reader.from_label(text, recover, nil), nil)
    T.eq(Reader.from_label(text:gsub(packed, "AAAA"), recover, inflate), nil)
  end)

  T.case("names a pad from a file the way the poster named the file", function()
    T.eq(Reader.name_from_file("/x/y/cwbhacker-scratch-2026-09-16-20260916-1055.jpg"), "scratch-2026-09-16")
    T.eq(Reader.name_from_file("photo.png"), "photo")
  end)

  T.case("proves a poster before it is saved, or names the check it failed", function()
    local read = { chunks = { Source = SRC, Signer = ADDR, Signature = SIG, Lang = "rust" } }
    local label = Poster.payload(ADDR, SIG, "rust", SRC, never_dense, fake_keccak)
    T.eq(Reader.prove(read, label, SRC, ADDR, SIG, recover, label), nil)
    T.eq(
      Reader.prove(read, label, SRC, "0x0000000000000000000000000000000000000000", SIG, recover, label),
      "signature"
    )
    T.eq(Reader.prove({ chunks = {} }, label, SRC, ADDR, SIG, recover, label), "chunks")
    T.eq(Reader.prove(read, nil, SRC, ADDR, SIG, recover, label), "label")
    T.eq(Reader.prove(read, "something else", SRC, ADDR, SIG, recover, label), "label")
  end)
end
