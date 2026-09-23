-- The poster: one square PNG of a pad, signed by the wallet, saved to disk.
--
-- The LÖVE half of `frontend/src/ui/poster.ts`, and the same picture: an LP
-- sleeve with the program printed inside the vinyl, one whole line per
-- groove; a QR label in the centre carrying the source, the address and an
-- EIP-191 signature over the source alone; SIDE B the output with the land's
-- mascot on it; the credits under a wax seal. English on the picture whatever
-- the screen is in. Read `poster.ts`'s header for the why; this file keeps to
-- the how, and where the two differ it says so.
--
-- What differs:
--
--   * The arithmetic that cannot honestly be Lua — the QR, recovering a
--     signer, the PNG's text chunks, the JPEG — is in `libcwbh_ffi` (ABI 6,
--     `ffi/src/disk.rs`), reached through `src/wallet.lua`. Nothing in it
--     touches a key.
--   * LÖVE cannot write outside its save directory, so the PNG goes through
--     `io.open` to `<home>/posters/`, and the proof is written into it by the
--     library afterwards (`png_text`), in place.
--   * The colouring is a small tokenizer here rather than the editor's
--     grammar: keywords, strings, comments, numbers — enough for the picture.
--
-- Everything that is arithmetic — pouring a program into a disc, fitting a
-- column, the payload, the file name, the mascot — is pure and
-- `tests/test_poster.lua` runs it headless. `render` and `write` need a
-- window and the library.

local Poster = {}

Poster.SIZE = 1024
Poster.SIZE_LARGE = 2048
--- The smallest type the code is set in, in real pixels whatever the square:
--- where OCR stops agreeing with the person. The one length that does not
--- scale, which is how the 2048 poster holds twice the program.
Poster.CODE_MIN_PX = 12
Poster.OUT_MIN_PX = 10
--- The fewest pixels a QR module may have before `make` reaches for 2048.
Poster.QR_MIN_CELL = 2
--- The densest label allowed (modules a side); denser is hashed instead.
Poster.QR_MAX_MODULES = 105
Poster.MAGIC = "CWBH1"

-- ------------------------------------------------------------- pure: text

--- Tabs are four columns: what every one of the four compilers assumes.
function Poster.expand_tabs(s)
  return (s:gsub("\t", "    "))
end

--- `text` cut to one line of `limit` pixels, with an ellipsis where it was cut.
function Poster.elide(text, limit, width_of)
  if width_of(text) <= limit then
    return text
  end
  -- Whole characters, not bytes: a "·" cut in half is not UTF-8, and LÖVE's
  -- font refuses to measure it.
  local chars = {}
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    chars[#chars + 1] = ch
  end
  local n = #chars
  while n > 1 and width_of(table.concat(chars, "", 1, n) .. "…") > limit do
    n = n - 1
  end
  return table.concat(chars, "", 1, n) .. "…"
end

--- The lines of `source`, normalised: CRLF to LF, tabs expanded, one
--- trailing newline dropped.
function Poster.lines_of(source)
  local s = Poster.expand_tabs(source:gsub("\r\n?", "\n"):gsub("\n$", ""))
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  return out
end

--- Wrap `lines` by column into rows that fit a `w` × `h` box at the largest
--- type between `max_px` and `min_px`; at the floor, as many rows as fit and
--- a last row saying how many lines did not. `char_w(px)` is the cell width.
function Poster.fit_mono(lines, w, h, char_w, max_px, min_px, leading, more)
  leading = leading or 1.1
  more = more or function(n)
    return ("… %d more lines"):format(n)
  end
  local function layout(px, cap)
    local cw = char_w(px)
    local cols = math.max(1, math.floor(w / cw))
    local rows = {}
    for i, s in ipairs(lines) do
      if s == "" then
        rows[#rows + 1] = { line = i, col = 0, text = "" }
      else
        for c = 0, #s - 1, cols do
          rows[#rows + 1] = { line = i, col = c, text = s:sub(c + 1, c + cols) }
        end
      end
      if cap and #rows > cap then
        local kept = {}
        for k = 1, math.max(0, cap - 1) do
          kept[k] = rows[k]
        end
        local last = #kept > 0 and kept[#kept].line or 0
        local hidden = #lines - last
        kept[#kept + 1] = { line = 0, col = 0, text = more(hidden) }
        return kept, hidden
      end
    end
    return rows, 0
  end
  local px = math.max(min_px, max_px)
  while px > min_px do
    local line_h = math.floor(px * leading + 0.5)
    local fits = math.floor(h / line_h)
    local rows = layout(px, nil)
    if #rows <= fits then
      return { px = px, char_w = char_w(px), line_h = line_h, rows = rows, hidden = 0 }
    end
    px = px - 2
  end
  px = min_px
  local line_h = math.floor(px * leading + 0.5)
  local fits = math.max(1, math.floor(h / line_h))
  local rows, hidden = layout(px, fits)
  return { px = px, char_w = char_w(px), line_h = line_h, rows = rows, hidden = hidden }
end

-- ------------------------------------------------------------- pure: disc

--- Where text can go on a disc of radius `r` with a label of radius `hole`:
--- for every row of `line_h`, the chord of the disc at that height, cut
--- short where it meets the label — **left only**, so OCR reads one column.
--- Runs that could hold fewer than `min_cells` are left out.
function Poster.disc_slots(r, hole, char_w, line_h, min_cells)
  local rows = math.floor((2 * r) / line_h)
  local top = -(rows * line_h) / 2
  local out = {}
  for i = 0, rows - 1 do
    local y0 = top + i * line_h
    local y1 = y0 + line_h
    local far = math.max(math.abs(y0), math.abs(y1))
    if far < r then
      local hw = math.sqrt(r * r - far * far)
      local near = (y0 <= 0 and y1 >= 0) and 0 or math.min(math.abs(y0), math.abs(y1))
      local b = near < hole and -math.sqrt(hole * hole - near * near) or hw
      local cap = math.floor((b + hw) / char_w)
      if cap >= min_cells then
        out[#out + 1] = { x = -hw, y = y0, cap = cap }
      end
    end
  end
  return out
end

--- Pour `lines` into the slots top to bottom, one line per groove, whole. A
--- line too long for the groove in front of it moves down to one that holds
--- it, and the grooves it passed stay empty; only a line longer than the
--- widest groove is wrapped by column. An empty line takes a groove. Nil
--- when they do not all fit.
function Poster.pour(lines, slots)
  local widest = 0
  for _, s in ipairs(slots) do
    widest = math.max(widest, s.cap)
  end
  local out, at = {}, 1
  for i, line in ipairs(lines) do
    if #line <= widest then
      while at <= #slots and slots[at].cap < #line do
        at = at + 1
      end
      if at > #slots then
        return nil
      end
      local s = slots[at]
      at = at + 1
      out[#out + 1] = { x = s.x, y = s.y, cap = s.cap, line = i, col = 0, text = line }
    else
      local col = 0
      repeat
        if at > #slots then
          return nil
        end
        local s = slots[at]
        at = at + 1
        out[#out + 1] = {
          x = s.x,
          y = s.y,
          cap = s.cap,
          line = i,
          col = col,
          text = line:sub(col + 1, col + s.cap),
        }
        col = col + s.cap
      until col >= #line
    end
  end
  return out
end

local function any_wrapped(grooves)
  for _, g in ipairs(grooves) do
    if g.col > 0 then
      return true
    end
  end
  return false
end

--- The largest type at which the program fits on the disc with every line
--- whole; at the floor, as much of it as fits and a last groove saying how
--- many lines are missing.
function Poster.fit_disc(lines, r, hole, char_w, max_px, min_px, leading, min_cells, more)
  leading = leading or 1.1
  min_cells = min_cells or 6
  more = more or function(n)
    return ("… %d more lines"):format(n)
  end
  local px = math.max(min_px, max_px)
  while px > min_px do
    local line_h = math.floor(px * leading + 0.5)
    local cw = char_w(px)
    local grooves = Poster.pour(lines, Poster.disc_slots(r, hole, cw, line_h, min_cells))
    if grooves and not any_wrapped(grooves) then
      return { px = px, char_w = cw, line_h = line_h, grooves = grooves, hidden = 0 }
    end
    px = px - 2
  end
  px = min_px
  local line_h = math.floor(px * leading + 0.5)
  local cw = char_w(px)
  local slots = Poster.disc_slots(r, hole, cw, line_h, min_cells)
  local whole = Poster.pour(lines, slots)
  if whole then
    return { px = px, char_w = cw, line_h = line_h, grooves = whole, hidden = 0 }
  end
  local budget = {}
  for i = 1, #slots - 1 do
    budget[i] = slots[i]
  end
  local n = 0
  while n < #lines do
    local head = {}
    for i = 1, n + 1 do
      head[i] = lines[i]
    end
    if not Poster.pour(head, budget) then
      break
    end
    n = n + 1
  end
  local head = {}
  for i = 1, n do
    head[i] = lines[i]
  end
  local grooves = Poster.pour(head, budget) or {}
  local hidden = #lines - n
  local last = slots[#slots]
  if last then
    grooves[#grooves + 1] =
      { x = last.x, y = last.y, cap = last.cap, line = 0, col = 0, text = more(hidden):sub(1, last.cap) }
  end
  return { px = px, char_w = cw, line_h = line_h, grooves = grooves, hidden = hidden }
end

-- ------------------------------------------------------- pure: the label

--- The label's text, as `poster.ts`'s `qrPayload`: five newline-separated
--- fields, the source verbatim — or, when `too_dense(text)` says a QR of it
--- would be denser than a phone reads, its keccak. `keccak_hex(source)` is
--- the library's, injected so this stays pure.
function Poster.payload(address, signature, lang, source, too_dense, keccak_hex)
  local function wrap(body)
    return table.concat({ Poster.MAGIC, address, signature or "-", lang, body }, "\n")
  end
  local whole = wrap(source)
  if not too_dense(whole) then
    return whole, false
  end
  return wrap("keccak256:" .. keccak_hex(source)), true
end

--- The payload back into its parts, or nil when it is not one of ours.
function Poster.parse_payload(text)
  local parts = {}
  for part in (text .. "\n"):gmatch("(.-)\n") do
    parts[#parts + 1] = part
  end
  if #parts < 5 or parts[1] ~= Poster.MAGIC then
    return nil
  end
  local body = {}
  for i = 5, #parts do
    body[#body + 1] = parts[i]
  end
  return {
    address = parts[2],
    signature = parts[3] ~= "-" and parts[3] or nil,
    lang = parts[4],
    body = table.concat(body, "\n"),
  }
end

--- `cwbhacker-<pad>-<yyyymmdd-hhmm>.png`, with the pad name made safe.
function Poster.file_name(name, at)
  local safe = name:lower():gsub("[^%w\128-\255]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if safe == "" then
    safe = "pad"
  end
  safe = safe:sub(1, 32)
  return ("cwbhacker-%s-%s.png"):format(safe, os.date("!%Y%m%d-%H%M", at))
end

--- Which mascot stands on the output: the land's, in the pose the run
--- earned — HACKER's when it ran, BASIC's when it did not compile,
--- ADVANCED's otherwise (or when nothing has run).
function Poster.mascot_for(lang, run)
  local road = "advanced"
  if run and run.ok then
    road = "hacker"
  elseif run and run.compile_error then
    road = "basic"
  end
  return ("mascot_%s_%s"):format(lang, road)
end

--- The pose, from the run's outcome word as the server sends it.
function Poster.run_of(result, log_lines)
  if not result then
    return nil
  end
  local words = {
    ok = "IT RAN",
    compile_error = "IT DID NOT COMPILE",
    runtime_error = "IT STOPPED",
    timeout = "IT RAN OUT OF TIME",
    output_limit = "IT PRINTED TOO MUCH",
  }
  local exit = result.exit_code ~= nil and (" · exit %s"):format(tostring(result.exit_code)) or ""
  return {
    outcome = words[result.outcome] or tostring(result.outcome),
    ok = result.outcome == "ok",
    compile_error = result.outcome == "compile_error",
    timings = ("%s ms compile · %s ms run%s"):format(
      tostring(result.compile_ms or 0),
      tostring(result.run_ms or 0),
      exit
    ),
    lines = log_lines or {},
  }
end

-- --------------------------------------------------------- pure: colours

local KEYWORDS = {
  rust = "as break const continue crate else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while async await dyn",
  go = "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil",
  cpp = "alignas alignof and asm auto bool break case catch char class const constexpr continue default delete do double else enum explicit export extern false float for friend goto if inline int long mutable namespace new noexcept nullptr operator private protected public register return short signed sizeof static struct switch template this throw true try typedef typename union unsigned using virtual void volatile while include",
  python = "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield print",
  pytorch = "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield print torch nn tensor shape dtype grad backward forward parameters zero_grad step no_grad eval train softmax relu Linear Module Sequential Embedding LayerNorm Conv2d Dropout Adam SGD",
  typescript = "let const var function return if else for while do of in new class interface type enum extends implements readonly private public protected static abstract async await import from export as keyof typeof instanceof satisfies declare namespace switch case default break continue try catch finally throw this super yield delete void true false null undefined number string boolean bigint never unknown any",
}
local KW = {}
for lang, list in pairs(KEYWORDS) do
  KW[lang] = {}
  for w in list:gmatch("%S+") do
    KW[lang][w] = true
  end
end

--- Runs of one tone for a line: `{ { text, tone }, … }`. `in_block` is
--- carried between lines for a `/* … */` or `"""` that spans them; the
--- second return is the state after this line.
function Poster.tokens(line, lang, in_block)
  local out = {}
  local i, n = 1, #line
  local comment_line = (lang == "python") and "#" or "//"
  local function push(text, tone)
    if text == "" then
      return
    end
    local last = out[#out]
    if last and last.tone == tone then
      last.text = last.text .. text
    else
      out[#out + 1] = { text = text, tone = tone }
    end
  end
  while i <= n do
    if in_block then
      local close = (lang == "python") and '"""' or "*/"
      local at = line:find(close, i, true)
      if at then
        push(line:sub(i, at + #close - 1), "comment")
        i = at + #close
        in_block = false
      else
        push(line:sub(i), "comment")
        i = n + 1
      end
    else
      local c = line:sub(i, i)
      if line:sub(i, i + #comment_line - 1) == comment_line then
        push(line:sub(i), "comment")
        i = n + 1
      elseif lang ~= "python" and line:sub(i, i + 1) == "/*" then
        in_block = true
        push("/*", "comment")
        i = i + 2
      elseif lang == "python" and line:sub(i, i + 2) == '"""' then
        in_block = true
        push('"""', "comment")
        i = i + 3
      elseif c == '"' or c == "'" or (c == "`" and (lang == "go" or lang == "typescript")) then
        local j = i + 1
        while j <= n and line:sub(j, j) ~= c do
          if line:sub(j, j) == "\\" then
            j = j + 1
          end
          j = j + 1
        end
        push(line:sub(i, math.min(j, n)), "string")
        i = j + 1
      elseif c:match("[%a_]") then
        local word = line:match("^[%w_]+", i)
        local tone = KW[lang][word] and "keyword" or "name"
        if lang == "rust" and line:sub(i + #word, i + #word) == "!" then
          tone = "call"
        end
        if line:sub(i + #word, i + #word) == "(" and tone == "name" then
          tone = "call"
        end
        if word:match("^%u") and tone == "name" then
          tone = "type"
        end
        push(word, tone)
        i = i + #word
      elseif c:match("%d") then
        local num = line:match("^[%w_.]+", i)
        push(num, "number")
        i = i + #num
      elseif c:match("[%(%)%[%]{}]") then
        push(c, "bracket")
        i = i + 1
      elseif c:match("%s") then
        push(c, "plain")
        i = i + 1
      else
        push(c, "operator")
        i = i + 1
      end
    end
  end
  return out, in_block
end

-- ------------------------------------------------------------- the picture

local Theme = require("src.theme")

local TONE = {
  keyword = Theme.pink,
  name = Theme.cream,
  call = Theme.cyan,
  type = Theme.coin,
  string = Theme.grass,
  number = Theme.coin,
  comment = { 0.68, 0.64, 0.6, 1 },
  operator = Theme.panel,
  bracket = Theme.cream,
  plain = Theme.cream,
}
local VINYL = { 11 / 255, 10 / 255, 18 / 255, 1 }

local fonts = {}
local function font(px, family)
  px = math.max(4, math.floor(px + 0.5))
  local key = family .. px
  if not fonts[key] then
    local file = family == "pixel" and "assets/fonts/PressStart2P-Regular.ttf"
      or "assets/fonts/JetBrainsMono-Code.ttf"
    local ok, f = pcall(love.graphics.newFont, file, px)
    fonts[key] = ok and f or love.graphics.newFont(px)
  end
  return fonts[key]
end

local function color(c, alpha)
  love.graphics.setColor(c[1], c[2], c[3], alpha or c[4] or 1)
end

local function text(f, s, x, y, c, alpha)
  love.graphics.setFont(f)
  color(c, alpha)
  love.graphics.print(s, math.floor(x), math.floor(y))
end

--- Type shrunk until `s` fits `w`, then elided.
local function fit_line(family, s, w, max_px, min_px)
  local px = max_px
  local f = font(px, family)
  while px > min_px and f:getWidth(s) > w do
    px = px - 2
    f = font(px, family)
  end
  if f:getWidth(s) > w then
    s = Poster.elide(s, w, function(t)
      return f:getWidth(t)
    end)
  end
  return f, s
end

--- Pixel-font text along an arc of radius `r` centred on (cx, cy).
local function arc_text(f, s, cx, cy, r, centre, c, inward)
  love.graphics.setFont(f)
  color(c)
  local chars = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    chars[#chars + 1] = ch
  end
  local total = 0
  for _, ch in ipairs(chars) do
    total = total + f:getWidth(ch)
  end
  local dir = inward and -1 or 1
  local a = centre - (total / 2) / r * dir
  for _, ch in ipairs(chars) do
    local half = (f:getWidth(ch) / 2) / r * dir
    a = a + half
    love.graphics.push()
    love.graphics.translate(cx + math.cos(a) * r, cy + math.sin(a) * r)
    love.graphics.rotate(a + (inward and -math.pi / 2 or math.pi / 2))
    love.graphics.print(ch, -f:getWidth(ch) / 2, -f:getHeight() / 2)
    love.graphics.pop()
    a = a + half
  end
end

local function circle(mode, cx, cy, r)
  love.graphics.circle(mode, cx, cy, r, 96)
end

--- The record, without its label.
local function vinyl(cx, cy, r, hole)
  color(Theme.ink, 0.6)
  circle("fill", cx - r * 0.015, cy + r * 0.025, r)
  color(VINYL)
  circle("fill", cx, cy, r)
  love.graphics.setLineWidth(2)
  local rr = hole + 8
  while rr < r - 8 do
    local band = math.floor((rr - hole) / 44) % 5 == 0
    love.graphics.setColor(1, 1, 1, band and 0.085 or 0.035)
    circle("line", cx, cy, rr)
    rr = rr + 4
  end
  for _, base in ipairs({ -0.95, math.pi - 0.95 }) do
    for i = 0, 2 do
      local spread = 0.4 - i * 0.11
      love.graphics.setColor(1, 1, 1, 0.03 + i * 0.025)
      love.graphics.arc("fill", cx, cy, r - 6, base - spread, base + spread, 24)
    end
  end
  love.graphics.setLineWidth(6)
  love.graphics.setColor(1, 1, 1, 0.16)
  circle("line", cx, cy, r - 3)
end

--- The label: cream ring, land face, the QR in a quiet square, two arcs of
--- type. Returns the QR's pixels per module.
local function label(cx, cy, r, land, rows, top, bottom, u)
  love.graphics.setLineWidth(6)
  love.graphics.setColor(0, 0, 0, 0.7)
  circle("line", cx, cy, r + 5)
  color(Theme.cream)
  circle("fill", cx, cy, r)
  color(land)
  circle("fill", cx, cy, r - 8 * u)
  local n = #rows
  local side = r * 1.5
  local cell = math.max(1, math.floor(side / (n + 8)))
  local qs = cell * (n + 8)
  local qx = math.floor(cx - qs / 2)
  local qy = math.floor(cy - qs / 2)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", qx, qy, qs, qs)
  love.graphics.setColor(0, 0, 0, 1)
  for rI, row in ipairs(rows) do
    for c = 1, n do
      if row:sub(c, c) == "1" then
        love.graphics.rectangle("fill", qx + (c + 3) * cell, qy + (rI + 3) * cell, cell, cell)
      end
    end
  end
  local f = font(8 * u, "pixel")
  arc_text(f, top, cx, cy, r - 13 * u, -math.pi / 2, Theme.ink)
  arc_text(f, bottom, cx, cy, r - 13 * u, math.pi / 2, Theme.ink, true)
  return cell
end

local function sleeve_frame(S, land)
  local t = math.floor(S * 0.012 + 0.5)
  love.graphics.setLineWidth(t)
  color(Theme.ink, 0.9)
  love.graphics.rectangle("line", t / 2, t / 2, S - t, S - t)
  love.graphics.setLineWidth(math.floor(t * 0.55 + 0.5))
  color(land)
  love.graphics.rectangle("line", t * 1.5, t * 1.5, S - t * 3, S - t * 3)
  color(Theme.ink, 0.85)
  local c = math.floor(S * 0.03 + 0.5)
  for _, k in ipairs({ { 0, 0, 1, 1 }, { S, 0, -1, 1 }, { 0, S, 1, -1 }, { S, S, -1, -1 } }) do
    love.graphics.polygon("fill", k[1], k[2], k[1] + c * k[3], k[2], k[1], k[2] + c * k[4])
  end
end

--- Draw the poster at `S` pixels a side into a canvas. `input`:
---   lang, name, file, source, run (`Poster.run_of`), user = { name, address },
---   signature (or nil), at (epoch seconds), qr = function(text) -> rows,
---   too_dense = function(text) -> bool, keccak_hex = function(source) -> hex,
---   hashed_words.
--- Returns `{ canvas, hidden, qr_cell, size }`.
function Poster.render(input, S)
  S = S or Poster.SIZE
  local Assets = require("src.assets")
  local u = S / 1024
  local land = Theme.land[input.lang] or Theme.land.rust
  local canvas = love.graphics.newCanvas(S, S)
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.origin()
  love.graphics.clear(Theme.void[1], Theme.void[2], Theme.void[3], 1)

  -- The sleeve: the street, under a scrim so print reads over it.
  local bg = Assets.image("bg_poster")
  if bg then
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(bg, 0, 0, 0, S / bg:getWidth(), S / bg:getHeight())
  end
  color(Theme.void, 0.55)
  love.graphics.rectangle("fill", 0, 0, S, S)

  local m = math.floor(S * 0.045 + 0.5)
  local title_top, title_h = m, math.floor(S * 0.085 + 0.5)
  local disc_r = math.floor(S * 0.335 + 0.5)
  local disc_cx = math.floor(S * 0.385 + 0.5)
  local disc_cy = math.floor(S * 0.505 + 0.5)
  local hole_r = math.floor(S * 0.17 + 0.5)
  local side_x = math.floor(S * 0.755 + 0.5)
  local side_w = S - m - side_x
  local credits_top = math.floor(S * 0.855 + 0.5)
  local credits_bottom = S - math.floor(S * 0.03 + 0.5)

  -- Title band.
  local brand = "CAUSEWAYBAY HACKER"
  local brand_f = font(13 * u, "pixel")
  text(brand_f, brand, m, title_top, Theme.cream)
  local small_f = font(10 * u, "pixel")
  text(
    small_f,
    ("STEREO · 33 1/3 RPM · %s LAND"):format(input.lang:upper()),
    m,
    title_top + brand_f:getHeight() + 6 * u,
    land
  )
  local cat = "CWB·" .. input.user.address:sub(3, 6):upper()
  text(small_f, cat, S - m - small_f:getWidth(cat), title_top + 2 * u, Theme.cream, 0.75)
  local name_top = title_top + brand_f:getHeight() + small_f:getHeight() + 18 * u
  local name_h = title_top + title_h - name_top + 10 * u
  local nf, ns = fit_line("pixel", input.name:upper(), S - m * 2, 44 * u, 18 * u)
  text(nf, ns, m, name_top + math.max(0, (name_h - nf:getHeight()) / 2), Theme.coin)

  -- The disc, and the program on it.
  vinyl(disc_cx, disc_cy, disc_r, hole_r)
  local lines = Poster.lines_of(input.source)
  local function cell_w(px)
    return font(px, "mono"):getWidth("M")
  end
  local fit = Poster.fit_disc(
    lines,
    disc_r - 16 * u,
    hole_r + 14 * u,
    cell_w,
    math.floor(24 * u + 0.5),
    Poster.CODE_MIN_PX,
    1.2,
    6
  )
  local code_f = font(fit.px, "mono")
  local side_f = font(11 * u, "pixel")
  text(side_f, ("SIDE A  ·  %s"):format(input.file), m, disc_cy - disc_r - side_f:getHeight() - 8 * u, Theme.cream)
  -- Tones per line, carried through block comments.
  local toned, block = {}, false
  for i, line in ipairs(lines) do
    toned[i], block = Poster.tokens(line, input.lang, block)
  end
  for _, g in ipairs(fit.grooves) do
    local x, y = disc_cx + g.x, disc_cy + g.y
    if g.line == 0 then
      text(code_f, g.text, x, y, Theme.dim)
    else
      -- Runs of one tone, positioned by column: the face is monospace.
      local at = 0
      for _, run in ipairs(toned[g.line]) do
        local from, to = at, at + #run.text
        local s0, s1 = math.max(from, g.col), math.min(to, g.col + #g.text)
        if s1 > s0 then
          text(
            code_f,
            run.text:sub(s0 - from + 1, s1 - from),
            x + (s0 - g.col) * fit.char_w,
            y,
            TONE[run.tone] or Theme.cream
          )
        end
        at = to
      end
    end
  end
  local payload, hashed =
    Poster.payload(input.user.address, input.signature, input.lang, input.source, input.too_dense, input.keccak_hex)
  local qr_cell = label(
    disc_cx,
    disc_cy,
    hole_r,
    land,
    input.qr(payload),
    brand,
    hashed and (input.hashed_words or "LABEL HOLDS THE HASH · CODE IS ON THE DISC")
      or ("%s · %s"):format(input.file, input.signature and "SIGNED" or "UNSIGNED"),
    u
  )

  -- SIDE B: the output, with the mascot on top of it.
  local out_top = math.floor(S * 0.4 + 0.5)
  local out_bottom = disc_cy + disc_r
  color(Theme.ink, 0.92)
  love.graphics.rectangle("fill", side_x, out_top, side_w, out_bottom - out_top)
  local run = input.run
  color(run and (run.ok and Theme.admit or Theme.red) or Theme.dim)
  love.graphics.rectangle("fill", side_x, out_top, side_w, 5 * u)
  local pad = math.floor(9 * u + 0.5)
  local mascot = Poster.mascot_for(input.lang, run)
  if Assets.image(mascot) then
    color(Theme.ink, 0.5)
    love.graphics.ellipse("fill", side_x + side_w / 2, out_top + 2 * u, side_w * 0.32, 5 * u)
    love.graphics.setColor(1, 1, 1, 1)
    local img = Assets.image(mascot)
    local scale = math.max(1, math.floor((out_top - title_top - title_h - 30 * u) / img:getHeight()))
    local box = Assets.box[mascot]
    local feet = (box and box.feet or img:getHeight()) * scale
    local mid = (box and box.cx or img:getWidth() / 2) * scale
    img:setFilter("nearest", "nearest")
    love.graphics.draw(
      img,
      math.floor(side_x + side_w / 2 - mid),
      math.floor(out_top + 3 * u - feet),
      0,
      scale,
      scale
    )
  end
  text(side_f, "SIDE B", side_x + pad, out_top + 5 * u + pad, Theme.cream)
  local oy = out_top + 5 * u + pad + side_f:getHeight() + 6 * u
  if run then
    local hf, hs = fit_line("pixel", run.outcome, side_w - pad * 2, 11 * u, 7 * u)
    text(hf, hs, side_x + pad, oy, run.ok and Theme.admit or Theme.red)
    oy = oy + hf:getHeight() + 4 * u
    local tf, ts = fit_line("mono", run.timings, side_w - pad * 2, 11 * u, 8 * u)
    text(tf, ts, side_x + pad, oy, Theme.dim)
    oy = oy + tf:getHeight() + 6 * u
    color(Theme.dim, 0.5)
    love.graphics.rectangle("fill", side_x + pad, oy, side_w - pad * 2, 2 * u)
    oy = oy + 8 * u
    local out_lines = {}
    for i, l in ipairs(run.lines) do
      out_lines[i] = Poster.expand_tabs(l.text or "")
    end
    local ofit = Poster.fit_mono(
      out_lines,
      side_w - pad * 2,
      out_bottom - pad - oy,
      cell_w,
      math.floor(16 * u + 0.5),
      Poster.OUT_MIN_PX,
      1.2
    )
    local of = font(ofit.px, "mono")
    for _, row in ipairs(ofit.rows) do
      local stream = row.line > 0 and run.lines[row.line].stream or ""
      local c = row.line == 0 and Theme.dim or (stream == "stderr" and Theme.pink or Theme.cream)
      text(of, row.text, side_x + pad, oy, c)
      oy = oy + ofit.line_h
    end
  else
    local nr = Poster.fit_mono(
      { "nothing has been run yet" },
      side_w - pad * 2,
      200 * u,
      cell_w,
      13 * u,
      Poster.OUT_MIN_PX,
      1.2
    )
    local nfnt = font(nr.px, "mono")
    for _, row in ipairs(nr.rows) do
      text(nfnt, row.text, side_x + pad, oy, Theme.dim)
      oy = oy + nr.line_h
    end
  end

  -- Credits: the seal, the name, the address, the signature.
  local cred_h = credits_bottom - credits_top
  color(Theme.cream, 0.94)
  love.graphics.rectangle("fill", m, credits_top, S - m * 2, cred_h)
  color(land)
  love.graphics.rectangle("fill", m, credits_top, S - m * 2, 4 * u)
  local cx = m + pad
  local seal = Assets.image("poster_seal")
  if seal then
    local sc = (cred_h - 10 * u) / seal:getHeight()
    love.graphics.setColor(1, 1, 1, input.signature and 1 or 0.28)
    seal:setFilter("linear", "linear")
    love.graphics.draw(seal, cx, credits_top + 5 * u, 0, sc, sc)
    if not input.signature then
      local uf = font(10 * u, "pixel")
      love.graphics.push()
      love.graphics.translate(cx + seal:getWidth() * sc / 2, credits_top + cred_h / 2)
      love.graphics.rotate(-0.28)
      love.graphics.setFont(uf)
      color(Theme.red)
      love.graphics.print("UNSIGNED", -uf:getWidth("UNSIGNED") / 2, -uf:getHeight() / 2)
      love.graphics.pop()
    end
    cx = cx + seal:getWidth() * sc + pad * 1.5
  end
  local cred_w = S - m - pad - cx
  local by_f = font(7 * u, "pixel")
  local cy = credits_top + 4 * u + 6 * u
  text(by_f, "WRITTEN & SIGNED BY", cx, cy, Theme.wood)
  cy = cy + by_f:getHeight() + 2 * u
  local wf, ws = fit_line("pixel", input.user.name:upper(), cred_w, 18 * u, 11 * u)
  text(wf, ws, cx, cy, Theme.ink)
  cy = cy + wf:getHeight() + 3 * u
  local addr_f = font(15 * u, "mono")
  text(addr_f, input.user.address, cx, cy, Theme.navy)
  cy = cy + addr_f:getHeight() + 1 * u
  local sig_f = font(12 * u, "mono")
  if input.signature then
    text(sig_f, input.signature:sub(1, 66), cx, cy, Theme.ink, 0.85)
    cy = cy + sig_f:getHeight()
    text(sig_f, input.signature:sub(67), cx, cy, Theme.ink, 0.85)
    cy = cy + sig_f:getHeight() + 3 * u
  else
    text(sig_f, "—", cx, cy, Theme.dim)
    cy = cy + sig_f:getHeight() * 2 + 2 * u
  end
  local when = os.date("!%Y-%m-%d %H:%M UTC", input.at)
  local hf2, hs2 =
    fit_line("pixel", "EIP-191 personal_sign over the source · Cronos EVM  ·  " .. when, cred_w, 7 * u, 6 * u)
  text(hf2, hs2, cx, math.min(cy, credits_bottom - pad - hf2:getHeight()), Theme.wood)

  sleeve_frame(S, land)
  love.graphics.pop()
  return { canvas = canvas, hidden = fit.hidden, qr_cell = qr_cell, size = S, hashed = hashed, payload = payload }
end

--- The poster at the size it needs: 1024 unless that could not hold the
--- program at readable type or gave the label too few pixels a module.
function Poster.make(input)
  local small = Poster.render(input, Poster.SIZE)
  if small.hidden == 0 and small.qr_cell >= Poster.QR_MIN_CELL then
    return small
  end
  small.canvas:release()
  return Poster.render(input, Poster.SIZE_LARGE)
end

--- Write the canvas as a PNG at `path` through `io.open` — LÖVE's own
--- filesystem cannot reach a directory the player will find.
function Poster.write_png(canvas, path)
  local data = canvas:newImageData():encode("png")
  local fh, err = io.open(path, "wb")
  if not fh then
    return nil, err
  end
  fh:write(data:getString())
  fh:close()
  return path
end

return Poster
