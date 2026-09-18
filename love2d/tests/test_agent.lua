-- The Rust coder, everything that does not need a window.
--
-- The browser's suite for the same code is `frontend/tests/agent*.test.ts`,
-- and where a number is asserted twice — the typing floor, the flight's
-- shape, the fold's cursor — it is asserted to the same value in both. That is
-- the only way "the same agent in two clients" stays true as either moves.
--
-- Nothing here touches the network. The provider stack is driven against a
-- loopback HTTP server through the real key library, which is the honest way
-- to test a streamed reply: the bytes really do arrive in pieces, and they
-- really do get split in places nobody chose.

local T = require("tests.framework")

local Prefs = require("src.agent.prefs")
local Typist = require("src.agent.typist")
local Tools = require("src.agent.tools")
local SSE = require("src.agent.sse")
local SpriteM = require("src.agent.sprite")
local Sync = require("src.agent.sync")
local Tips = require("src.agent.tips")
local SessionM = require("src.agent.session")
local Providers = require("src.agent.providers")
local json = require("src.json")

local BOX = { 0, 0, 640, 360 }

local function sprite()
  return SpriteM.new(48, function() return false end)
end

local function fly(s, seconds, box)
  for _ = 1, math.floor(seconds * 60) do
    s:update(1 / 60, box or BOX, 8)
  end
end

return function()
  T.section("the coder — what it remembers")

  T.case("keys, models and switches round-trip through a file of their own", function()
    local dir = os.getenv("TMPDIR") or "/tmp"
    dir = dir .. "/cwbh-agent-" .. tostring(os.time()) .. tostring(math.random(10000))
    os.execute("mkdir -p '" .. dir .. "'")
    Prefs.reset()
    Prefs.open({ dir = dir })
    T.eq(Prefs.provider(), "anthropic", "the browser's default, and this one's")
    Prefs.set_provider("grok")
    Prefs.set_key("grok", "  xai-secret  ")
    Prefs.set_model("grok", "grok-4-fast")
    Prefs.set_auto(true)
    Prefs.set_shown(false)
    T.eq(Prefs.key("grok"), "xai-secret", "trimmed on the way in")

    -- A second open of the same directory is a second launch.
    Prefs.reset()
    Prefs.open({ dir = dir })
    T.eq(Prefs.provider(), "grok")
    T.eq(Prefs.key("grok"), "xai-secret")
    T.eq(Prefs.model("grok"), "grok-4-fast")
    T.eq(Prefs.auto(), true)
    T.eq(Prefs.shown(), false)
    T.eq(Prefs.key("openai"), "", "one provider's key is not another's")
    os.execute("rm -rf '" .. dir .. "'")
    Prefs.reset()
    Prefs.open({ dir = false })
  end)

  T.case("falls back to the default model, and knows who needs a key", function()
    Prefs.reset()
    Prefs.open({ dir = false })
    T.eq(Prefs.model("anthropic"), "claude-opus-5")
    T.eq(Prefs.model("ollama"), "qwen2.5-coder:7b")
    T.eq(Prefs.needs_key("ollama"), false, "Ollama is a program on your own machine")
    T.eq(Prefs.needs_key("openai"), true)
    T.eq(Prefs.ollama_host(), Prefs.OLLAMA_DEFAULT_HOST)
    Prefs.set_key("ollama", "http://192.168.1.9:11434/")
    T.eq(Prefs.ollama_host(), "http://192.168.1.9:11434", "the trailing slash is not part of it")
  end)

  T.case("masks a key for a screen somebody might be streaming", function()
    T.eq(Prefs.mask(""), "")
    T.eq(Prefs.mask("sk-1234567890abcdef"), "sk-123…cdef")
    T.ok(not Prefs.mask("sk-1234567890abcdef"):find("7890"), "the middle is gone")
  end)

  T.section("the coder — typing like a person")

  T.case("never types faster than the floor", function()
    for _, delay in ipairs(Typist.schedule("fn main() {\n    println!(\"hi\");\n}\n")) do
      T.ok(delay >= Typist.FLOOR_MS, "a delay of " .. delay .. " is under the floor")
    end
  end)

  T.case("breathes at a newline and after a closing brace", function()
    -- The browser asserts this on the same string at the same two places
    -- (`frontend/tests/agent.test.ts`); the indices differ by one because
    -- Lua counts from one.
    local delays = Typist.schedule("a\nb}c")
    T.ok(delays[3] >= Typist.NEWLINE_MS, "the character after a newline waits")
    T.ok(delays[5] >= Typist.BASE_MS * 0.7 + 100, "and the one after a closing brace")
  end)

  T.case("rushes through indentation rather than typing four spaces", function()
    local delays = Typist.schedule("x\n    y")
    T.eq(delays[4], Typist.FLOOR_MS)
    T.eq(delays[5], Typist.FLOOR_MS)
  end)

  T.case("is bounded for a long file, and is the same every time", function()
    -- Bounded, but floored: the cap scales every delay down and then the
    -- floor puts each one back up to 18 ms, so a very long file lands at
    -- roughly a floor per character rather than at the cap. That is the
    -- browser's arithmetic too, and this is the browser's assertion.
    local long = string.rep("let x = 1;\n", 1500)
    local total = 0
    for _, delay in ipairs(Typist.schedule(long)) do total = total + delay end
    T.ok(total <= Typist.MAX_TOTAL_MS + Typist.FLOOR_MS * #long,
      "a long file is typed faster, not never")
    T.ok(total > Typist.MAX_TOTAL_MS * 0.5, "and not pasted either")
    local a = Typist.schedule("hello, world")
    local b = Typist.schedule("hello, world")
    for i = 1, #a do T.eq(a[i], b[i], "the jitter is a hash, not a die") end
  end)

  T.case("types on a clock, one character at a time, and can be stopped", function()
    local typist = Typist.new()
    local out = {}
    local finished = nil
    typist:run("abcdef", { type = function(ch) out[#out + 1] = ch end }, nil,
      function(done) finished = done end)
    T.eq(typist:busy(), true)
    -- A tenth of a second is worth a character or two at this pace, never six.
    typist:update(0.1)
    T.ok(#out >= 1 and #out < 6, "typed " .. #out .. " in 100 ms")
    typist:stop()
    T.eq(finished, false, "a stop says so")
    T.eq(typist:busy(), false)
    local before = #out
    typist:update(10)
    T.eq(#out, before, "a stopped typist types nothing more")
  end)

  T.section("the coder — what the model may do")

  T.case("offers only what the bench can honour", function()
    local names = {}
    for _, tool in ipairs(Tools.tools_for({ run = nil, format = nil, search = nil, image = nil })) do
      names[tool.name] = true
    end
    T.ok(names.read_code and names.write_code, "reading and writing are always there")
    T.ok(not names.run_code, "a screen that cannot run does not offer to")
    T.ok(not names.make_image, "and a provider that cannot draw does not offer to")
    local all = Tools.tools_for({
      run = function() end, format = function() end,
      search = function() end, image = function() end,
    })
    T.eq(#all, #Tools.TOOLS, "everything, when the bench can do everything")
  end)

  T.case("numbers the lines the way a reviewer reads them", function()
    T.eq(Tools.numbered("a\nb"), "1| a\n2| b")
    local wide = Tools.numbered(string.rep("x\n", 10))
    T.eq(wide:match("^[^\n]*"), " 1| x", "the gutter is as wide as the last line number")
  end)

  T.case("answers an edit that misses with a sentence, not an error", function()
    local bench = {
      lang = "rust", file = "main.rs",
      read = function() return "fn main() {}" end,
      edit = function() return { ok = false, why = "That text is not in the file." } end,
    }
    local text, failed = Tools.run_tool(bench, "edit_code", { find = "nope", replace = "x" })
    T.eq(failed, true)
    T.ok(text:find("not in the file"), "the model can read the reason and try again")
    local empty, blank = Tools.run_tool(bench, "edit_code", { find = "", replace = "x" })
    T.eq(blank, true)
    T.ok(empty:find("empty"))
  end)

  T.case("reports a run the way a compiler does", function()
    local bench = {
      lang = "rust", file = "main.rs",
      read = function() return "" end,
      run = function()
        return { outcome = "compile_error", stdout = "", stderr = "E0382: use of moved value",
          compile_ms = 120, run_ms = 0, exit_code = 1 }
      end,
    }
    local text = Tools.run_tool(bench, "run_code", {})
    T.ok(text:find("outcome: compile_error"), "the outcome first")
    T.ok(text:find("E0382"), "and the compiler's own words")
  end)

  T.section("the coder — the event stream")

  T.case("reassembles events from bytes split anywhere", function()
    local stream = SSE.new()
    local out = {}
    -- One event, fed a character at a time: nothing may come out early.
    local text = "data: {\"a\":1}\n\ndata: [DONE]\n\n"
    for i = 1, #text do
      for _, event in ipairs(stream:feed(text:sub(i, i))) do out[#out + 1] = event end
    end
    T.eq(#out, 2)
    T.eq(out[1].data, "{\"a\":1}")
    T.eq(out[2].data, "[DONE]")
  end)

  T.case("keeps an event's name, and drops what carries nothing", function()
    local stream = SSE.new()
    local events = stream:feed(": keep-alive\n\nevent: content_block_delta\ndata: {\"x\":1}\n\n")
    T.eq(#events, 1, "a comment is not an event")
    T.eq(events[1].event, "content_block_delta")
    T.eq(events[1].data, "{\"x\":1}")
  end)

  T.case("joins the data lines of one event, and survives CRLF", function()
    local stream = SSE.new()
    local events = stream:feed("data: one\r\ndata: two\r\n\r\n")
    T.eq(#events, 1)
    T.eq(events[1].data, "one\ntwo")
  end)

  T.section("the coder — how it flies")

  T.case("stays inside its box, and actually moves", function()
    local s = sprite()
    local path = 0
    fly(s, 2)
    for _ = 1, 300 do
      local x0, y0 = s.x, s.y
      s:update(1 / 60, BOX, 8)
      path = path + math.sqrt((s.x - x0) ^ 2 + (s.y - y0) ^ 2)
      T.ok(s.x >= BOX[1] and s.x <= BOX[1] + BOX[3], "inside across")
      T.ok(s.y >= BOX[2] and s.y <= BOX[2] + BOX[4], "inside down")
    end
    T.ok(path > 40, "it wanders rather than sitting")
  end)

  T.case("wanders slowly enough to be caught", function()
    local s = sprite()
    fly(s, 2)
    local top = 0
    for _ = 1, 60 * 12 do
      s:update(1 / 60, BOX, 8)
      top = math.max(top, s:speed())
    end
    T.ok(top > 10, "but it does move: " .. math.floor(top))
    T.ok(top < 120, "peak idle speed was " .. math.floor(top))
  end)

  T.case("slows right down while the pointer is moving", function()
    local function mean(calm)
      local s = sprite()
      s:calm(calm)
      fly(s, 3)
      local sum = 0
      for _ = 1, 60 * 8 do
        s:update(1 / 60, BOX, 8)
        sum = sum + s:speed()
      end
      return sum / (60 * 8)
    end
    local free, calm = mean(false), mean(true)
    T.ok(calm < free * 0.4, ("calm %.1f against free %.1f"):format(calm, free))
  end)

  T.case("goes to the caret on a peek and comes back", function()
    local s = sprite()
    s.caret = { 150, 200 }
    T.eq(s:peek(), true)
    T.eq(s.state, "peek")
    fly(s, 1)
    T.ok(s.x > 150, "beside the caret, to its right")
    T.ok(math.abs(s.y - 200) < 48)
    fly(s, 2)
    T.eq(s.state, "wander", "a peek is a visit, not a move")
  end)

  T.case("flies slow-fast-slow, not at one speed", function()
    local s = sprite()
    s.caret = { 600, 340 }
    fly(s, 1)
    s.caret = { 20, 20 }
    s:peek()
    local speeds = {}
    for _ = 1, 60 do
      s:update(1 / 60, BOX, 8)
      speeds[#speeds + 1] = s:speed()
    end
    local peak, at = 0, 0
    for i, v in ipairs(speeds) do
      if v > peak then peak, at = v, i end
    end
    T.ok(speeds[1] < peak * 0.5, "it leaves slowly")
    T.ok(at > 3 and at < 58, "and is fastest in the middle, at frame " .. at)
  end)

  T.case("holds still when touched, braking on a curve, and roams when let go", function()
    local s = sprite()
    fly(s, 2)
    local px, py = s.x, s.y
    T.eq(s:hold(true, BOX), true)
    T.eq(s:holding(), true)
    local last, eased = math.huge, true
    for _ = 1, 60 do
      s:update(1 / 60, BOX, 8)
      if s:speed() > last + 1 then eased = false end
      last = s:speed()
    end
    T.ok(eased, "it slows rather than stopping dead")
    T.ok(s:speed() < 2, "and it has stopped")
    T.ok(math.sqrt((s.x - px) ^ 2 + (s.y - py) ^ 2) < 40, "near where it was touched")
    local hx, hy = s.x, s.y
    fly(s, 20)
    T.ok(math.abs(s.x - hx) < 0.5, "and it stays for as long as it takes to read")
    T.eq(s:hold(true, BOX), true, "touching it again changes nothing")
    s:hold(false)
    T.eq(s.state, "wander")
    fly(s, 2)
    T.ok(math.sqrt((s.x - hx) ^ 2 + (s.y - hy) ^ 2) > 10, "let go, it flies off")
  end)

  T.case("will not hold while it is working", function()
    local s = sprite()
    s.caret = { 100, 100 }
    s:typing(true)
    T.eq(s:hold(true, BOX), false, "one at work is not interrupted")
    s:typing(false)
    T.eq(s:hold(true, BOX), true)
    s:thinking(true)
    T.eq(s:holding(), false, "and work takes it back")
  end)

  T.case("arrives huge and shrinks to size on an ease-out", function()
    local s = sprite()
    s:enter()
    T.eq(s:entering(), true)
    T.ok(s.scale > 2.5, "it arrives at " .. s.scale)
    local drops, last = {}, s.scale
    for _ = 1, 120 do
      s:update(1 / 60, BOX, 8)
      drops[#drops + 1] = last - s.scale
      last = s.scale
    end
    T.eq(s:entering(), false)
    T.ok(math.abs(s.scale - 1) < 0.1, "and settles at its own size")
    T.ok(drops[1] > drops[10], "the first frames shrink fastest")
    T.ok(drops[10] > drops[40], "and the last barely move")
  end)

  T.case("zooms in and rocks while typing, and leaves a ribbon behind it", function()
    local s = sprite()
    s.caret = { 150, 200 }
    fly(s, 2)
    T.ok(math.abs(s.scale - 1) < 0.1, "at rest it is its own size")
    s:typing(true)
    fly(s, 1)
    T.ok(s.scale > 1.1, "typing, it leans in")
    local rocked = false
    for _ = 1, 30 do
      s:update(1 / 60, BOX, 8)
      if math.abs(s:angle()) > 0.03 then rocked = true end
    end
    T.ok(rocked, "and rocks over the keys")
    T.ok(#s.wake > 0, "a flight leaves ribbon")
    s:hold(true, BOX)
    fly(s, 3)
    T.eq(#s.wake, 0, "which ages away once it stops")
  end)

  T.case("barrel-rolls exactly once round and comes back level", function()
    local s = sprite()
    fly(s, 1)
    s:roll()
    T.eq(s:rolling_now(), true)
    local turned, last = 0, s:angle()
    for _ = 1, 120 do
      if not s:rolling_now() then break end
      s:update(1 / 60, BOX, 8)
      local d = math.abs(s:angle() - last)
      if d < math.pi then turned = turned + d end
      last = s:angle()
    end
    T.eq(s:rolling_now(), false)
    T.ok(turned > math.pi * 1.5, "it went round")
    fly(s, 1.5)
    T.ok(math.abs(s:angle()) < 0.4, "and is level again")
  end)

  T.case("sits still in the corner when motion is turned down", function()
    local s = SpriteM.new(48, function() return true end)
    fly(s, 3)
    local rest = s:rest_point(BOX)
    T.ok(math.abs(s.x - rest[1]) < 1, "in the corner")
    T.ok(math.abs(s.y - rest[2]) < 1)
    T.eq(s:bob(), 0)
    s:typing(true)
    s:kick()
    s:roll()
    s:enter()
    fly(s, 0.5)
    T.eq(s.scale, 1, "nothing zooms")
    T.eq(s:angle(), 0, "nothing tilts")
    T.eq(#s.trail, 0, "and nothing smears")
  end)

  T.section("the coder — the page follows what it writes")

  T.case("the page follows the writing without ever leaving empty rows", function()
    local Editor = require("src.editor")
    local rows = 12
    local function write(n)
      local e = Editor.new({})
      e:set_text("")
      local worst_blank, worst_below = 0, 0
      for i = 1, n do
        for _, ch in ipairs({ ("fn f%d() {}"):format(i), "\n" }) do
          for k = 1, #ch do e:insert(ch:sub(k, k), true) end
        end
        e:ensure_visible(rows)
        -- Rows of the pane with no line in them, while lines are hidden above.
        if e.scroll > 0 then
          worst_blank = math.max(worst_blank, (e.scroll + rows) - e:line_count())
        end
        worst_below = math.max(worst_below, e.line - (e.scroll + rows))
      end
      return e, worst_blank, worst_below
    end

    -- A program that fits the pane does not move the pane at all.
    local short = write(8)
    T.eq(short.scroll, 0, "a program shorter than the pane scrolled anyway")

    -- A long one follows to the end, and never shows an empty row while it
    -- is hiding a line: a page that scrolls while there is still room on it
    -- reads as a page that scrolls for no reason, which is what a margin of
    -- daylight under the caret looked like when it was tried.
    local long, blank, below = write(40)
    T.eq(blank, 0, ("left %d empty rows while lines were hidden above"):format(blank))
    T.ok(below <= 1, ("the caret was %d lines under the pane"):format(below))
    T.eq(long.scroll, long:line_count() - rows, "the last line is the last row")
    T.ok(long.line > long.scroll and long.line <= long.scroll + rows,
      "the line being written is on the screen")
  end)

  T.section("the coder — the room")

  T.case("folds a page by id, oldest first", function()
    local room = Sync.empty_room()
    room = Sync.fold(room, {
      { id = 2, timeid = 200, text = "second", role = "agent" },
      { id = 1, timeid = 100, text = "first", role = "user" },
    })
    T.eq(#room.messages, 2)
    T.eq(room.messages[1].text, "first", "sorted by timeid, whatever order they arrived in")
    T.eq(room.cursor, 200, "the cursor is the newest timeid seen")
    -- The same page again changes nothing: a replayed page is harmless.
    local again = Sync.fold(room, { { id = 1, timeid = 100, text = "first", role = "user" } })
    T.eq(#again.messages, 2)
  end)

  T.case("the room tells the first save from a different pad, and two unsaved pads apart", function()
    local unsaved = { key = 1, id = nil }
    T.eq(Sync.room_move(nil, unsaved), "switch")
    T.eq(Sync.room_move(unsaved, { key = 1, id = nil }), "same")
    T.eq(Sync.room_move(unsaved, { key = 1, id = "pg_a" }), "arriving", "the first save landing")
    T.eq(Sync.room_move({ key = 1, id = "pg_a" }, { key = 1, id = "pg_a" }), "same")
    -- NEW from an unsaved pad: nil to nil, and it must NOT read as no change.
    T.eq(Sync.room_move(unsaved, { key = 2, id = nil }), "switch")
    -- A saved pad opened from an unsaved one is not this room arriving.
    T.eq(Sync.room_move(unsaved, { key = 2, id = "pg_b" }), "switch")
    T.eq(Sync.room_move({ key = 1, id = "pg_a" }, { key = 2, id = "pg_b" }), "switch")
    T.eq(Sync.room_move({ key = 1, id = "pg_a" }, { key = 2, id = nil }), "switch", "the held pad deleted")
  end)

  T.case("an edit replaces in place and a tombstone does not come back", function()
    local room = Sync.fold(Sync.empty_room(), {
      { id = 1, timeid = 100, text = "before", role = "user" },
    })
    room = Sync.fold(room, { { id = 1, timeid = 300, text = "after", role = "user", edited = true } })
    T.eq(#room.messages, 1, "an edit is the same row, not a new one")
    T.eq(room.messages[1].text, "after")
    room = Sync.fold(room, { { id = 1, timeid = 400, text = "after", role = "user", deleted = true } })
    T.eq(#room.messages, 0, "a tombstone takes the line away")
    -- A client that had the old copy sends it again; it must stay gone.
    room = Sync.fold(room, { { id = 1, timeid = 100, text = "before", role = "user" } })
    T.eq(#room.messages, 0, "and a stale copy cannot resurrect it")
    T.eq(room.cursor, 400)
  end)

  T.section("the coder — the standing orders")

  T.case("puts the file, the language and the rules in the system prompt", function()
    local bench = {
      lang = "rust", file = "main.rs",
      read = function() return "fn main() {}" end,
      run = function() end,
    }
    local prompt = SessionM.system_prompt(bench, true)
    T.ok(prompt:find("Rust coder", 1, true), "it knows who it is")
    T.ok(prompt:find("ONE source file", 1, true), "and that there is one file")
    T.ok(prompt:find("main.rs", 1, true), "which is named")
    T.ok(prompt:find("1| fn main() {}", 1, true), "with its text, numbered")
    T.ok(prompt:find("run_code", 1, true), "and told to run what it wrote")
    local mute = SessionM.system_prompt({ lang = "go", file = "main.go",
      read = function() return "" end }, false)
    T.ok(mute:find("cannot run code", 1, true), "a screen that cannot run says so")
    T.ok(mute:find("The person is learning Go", 1, true))
  end)

  T.case("the tool catalogue is the browser's, word for word", function()
    -- The descriptions are the model's instructions. If these drift, the two
    -- clients stop being the same character, so the wording is pinned here.
    local by_name = {}
    for _, tool in ipairs(Tools.TOOLS) do by_name[tool.name] = tool end
    T.ok(by_name.write_code.description:find("one character at a time", 1, true))
    T.ok(by_name.edit_code.description:find("exactly once", 1, true))
    T.ok(by_name.make_image.description:find("Only when the person asks", 1, true))
    T.eq(SessionM.MAX_ROUNDS, 10, "ten rounds, then a last turn with no tools")
  end)

  T.section("the coder — a whole conversation")

  T.case("asks, runs the tool it was given, and answers", function()
    -- The provider stack against a real socket: an OpenAI-dialect server on
    -- loopback that asks for `write_code` and then says what it did. Nothing
    -- is mocked but the model itself.
    local Wallet = require("src.wallet")
    local lib = Wallet.load()
    if not lib then
      T.skip("the key library is not built — run `make -C love2d ffi`")
      return
    end
    local socket_ok, socket = pcall(require, "socket")
    if not socket_ok then
      T.skip("LuaSocket is missing")
      return
    end

    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = server:getsockname()
    server:settimeout(0)

    local function frame(delta, finish)
      return "data: " .. json.encode({
        choices = { { index = 0, delta = delta, finish_reason = finish or json.null } },
      }) .. "\n\n"
    end
    local args = json.encode({ source = "fn main() {\n    println!(\"hi\");\n}\n" })
    -- Two replies, in order: the tool call, then the sentence about it.
    local replies = {
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
        .. frame({ role = "assistant", content = "" })
        .. frame({ tool_calls = { { index = 0, id = "call_1", type = "function",
             ["function"] = { name = "write_code", arguments = args:sub(1, 20) } } } })
        .. frame({ tool_calls = { { index = 0,
             ["function"] = { arguments = args:sub(21) } } } })
        .. frame({}, "tool_calls") .. "data: [DONE]\n\n",
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
        .. frame({ role = "assistant", content = "Wrote it " })
        .. frame({ content = "and it compiles." })
        .. frame({}, "stop") .. "data: [DONE]\n\n",
    }
    local served = 0
    local function serve()
      local client = server:accept()
      if not client then return end
      client:settimeout(0.5)
      -- Read the head and the body, then answer and hang up.
      local head, length = {}, 0
      while true do
        local line = client:receive("*l")
        if not line or line == "" then break end
        head[#head + 1] = line
        local n = line:lower():match("^content%-length:%s*(%d+)")
        if n then length = tonumber(n) end
      end
      if length > 0 then client:receive(length) end
      served = served + 1
      client:send(replies[math.min(served, #replies)])
      client:close()
    end

    Prefs.reset()
    Prefs.open({ dir = false })
    Prefs.set_provider("ollama")
    Prefs.set_key("ollama", "http://127.0.0.1:" .. port)

    local source = "fn main() {}\n"
    local wrote = nil
    local bench = {
      lang = "rust", file = "main.rs",
      read = function() return source end,
      write = function(text)
        wrote = text
        source = text
        return { typed = #text, total = #text, stopped = false }
      end,
      insert = function(text) return { typed = #text, total = #text, stopped = false } end,
      edit = function() return { ok = true } end,
    }
    local moods, tools = {}, {}
    local listener = {
      text = function() end,
      tool = function(name) tools[#tools + 1] = name end,
      tool_done = function() end,
      mood = function(m) moods[#moods + 1] = m end,
    }
    local session = SessionM.new(bench, listener, Wallet, lib)
    local reply, failure, done = nil, nil, false
    session:ask("ollama", "write the program", function(text, err)
      reply, failure, done = text, err, true
    end)
    for _ = 1, 2000 do
      if done then break end
      serve()
      session:update()
      socket.sleep(0.005)
    end
    server:close()
    Prefs.reset()
    Prefs.open({ dir = false })

    T.eq(failure, nil, "the conversation finished: " .. tostring(failure))
    T.eq(tools[1], "write_code", "the model asked for the tool it was offered")
    T.ok(wrote and wrote:find("println!", 1, true), "and the bench got the program")
    T.eq(reply, "Wrote it and it compiles.", "then it said what it did")
    T.eq(moods[#moods], "idle", "and went back to idle")
  end)

  T.case("speaks Anthropic's own dialect, not only OpenAI's", function()
    -- The default provider, and the one wire in this client with no SDK
    -- behind it and a shape all of its own: content blocks that arrive
    -- open-then-filled, tool arguments in fragments, and the reason it
    -- stopped in a `message_delta` rather than on the choice. Untested, it is
    -- a guess; so this is the same loopback server with Anthropic's events in
    -- it, and the JSON is deliberately split down the middle of a fragment.
    local Wallet = require("src.wallet")
    local lib = Wallet.load()
    if not lib then
      T.skip("the key library is not built — run `make -C love2d ffi`")
      return
    end
    local socket_ok, socket = pcall(require, "socket")
    if not socket_ok then
      T.skip("LuaSocket is missing")
      return
    end
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = server:getsockname()
    server:settimeout(0)

    local function event(name, value)
      return ("event: %s\ndata: %s\n\n"):format(name, json.encode(value))
    end
    local args = json.encode({ source = "fn main() {}\n", note = "a hello" })
    local reply = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
      .. event("message_start", { type = "message_start", message = { id = "msg_1" } })
      .. event("content_block_start", { type = "content_block_start", index = 0,
           content_block = { type = "text", text = "" } })
      .. event("content_block_delta", { type = "content_block_delta", index = 0,
           delta = { type = "text_delta", text = "Writing it." } })
      .. event("content_block_start", { type = "content_block_start", index = 1,
           content_block = { type = "tool_use", id = "toolu_1", name = "write_code" } })
      .. event("content_block_delta", { type = "content_block_delta", index = 1,
           delta = { type = "input_json_delta", partial_json = args:sub(1, 17) } })
      .. event("content_block_delta", { type = "content_block_delta", index = 1,
           delta = { type = "input_json_delta", partial_json = args:sub(18) } })
      .. event("message_delta", { type = "message_delta",
           delta = { stop_reason = "tool_use" } })
      .. event("message_stop", { type = "message_stop" })

    local seen_head = nil
    local function serve()
      local client = server:accept()
      if not client then return end
      client:settimeout(0.5)
      local head, length = {}, 0
      while true do
        local line = client:receive("*l")
        if not line or line == "" then break end
        head[#head + 1] = line
        local n = line:lower():match("^content%-length:%s*(%d+)")
        if n then length = tonumber(n) end
      end
      if length > 0 then client:receive(length) end
      seen_head = table.concat(head, "\n")
      client:send(reply)
      client:close()
    end

    -- The provider's URL is Anthropic's own, so the call is pointed at the
    -- loopback server by name: everything else about the request is the real
    -- one, headers included.
    local was = Providers.ANTHROPIC_URL
    Providers.ANTHROPIC_URL = "http://127.0.0.1:" .. port .. "/v1"
    local text, turn, err = {}, nil, nil
    local co = coroutine.create(function()
      turn, err = Providers.anthropic_chat({
        wallet = Wallet, lib = lib, provider = "anthropic",
        key = "sk-ant-test", model = "claude-opus-5",
        system = "you are the Rust coder",
        messages = { { role = "user", content = { { type = "text", text = "write it" } } } },
        tools = { { name = "write_code", description = "write the whole program",
          properties = { source = { type = "string", description = "the program" } },
          required = { "source" } } },
        on_text = function(delta) text[#text + 1] = delta end,
      })
    end)
    for _ = 1, 2000 do
      if coroutine.status(co) == "dead" then break end
      serve()
      local ok, e = coroutine.resume(co)
      if not ok then
        Providers.ANTHROPIC_URL = was
        error(e, 0)
      end
      socket.sleep(0.005)
    end
    server:close()
    Providers.ANTHROPIC_URL = was

    T.eq(err, nil, "the turn failed: " .. tostring(err))
    T.ok(turn ~= nil, "no turn came back")
    if not turn then return end
    T.eq(table.concat(text), "Writing it.", "the prose streamed as it arrived")
    T.eq(turn.text, "Writing it.")
    T.eq(turn.stop, "tool", "a tool_use stop, read off the message_delta")
    T.eq(#turn.tool_uses, 1)
    T.eq(turn.tool_uses[1].name, "write_code")
    T.eq(turn.tool_uses[1].id, "toolu_1")
    T.eq(turn.tool_uses[1].input.source, "fn main() {}\n",
      "the argument fragments were joined back into one object")
    T.eq(turn.tool_uses[1].input.note, "a hello")
    -- The headers are the contract: the key goes in `x-api-key`, never in an
    -- `authorization`, and the version is the one this client was written to.
    T.ok(seen_head:lower():find("x%-api%-key: sk%-ant%-test"), "the key went in its own header")
    T.ok(seen_head:lower():find("anthropic%-version: " .. Providers.ANTHROPIC_VERSION),
      "the API version was stated")
    T.ok(not seen_head:lower():find("authorization:"), "and not as a bearer token")
  end)

  T.section("the coder — what it says for free")

  T.case("has a catalogue for every land, and never repeats a tip", function()
    for _, lang in ipairs({ "rust", "go", "cpp", "python" }) do
      T.ok(#(Tips.TIPS[lang] or {}) >= 8, lang .. " has " .. #(Tips.TIPS[lang] or {}) .. " tips")
    end
    local last = 1
    for _ = 1, 40 do
      local nextOne = Tips.next_tip("rust", last)
      T.ok(nextOne ~= last, "a tip is never the one just given")
      last = nextOne
    end
  end)

  T.case("reads the habits a reviewer would circle", function()
    local rust = table.concat({
      "fn main() {",
      "    let a = v.unwrap();",
      "    let b = v.unwrap();",
      "    let c = v.unwrap();",
      "    let d = v.unwrap();",
      "    for i in 0..3 {",
      "        let e = s.clone();",
      "    }",
      "}",
    }, "\n")
    local ids = {}
    for _, finding in ipairs(Tips.advise("rust", rust)) do ids[finding.id] = finding.text end
    T.ok(ids["rust.unwrap"], "four unwraps is a habit, not a scratchpad")
    T.ok(ids["rust.clone-loop"], "and a clone in a loop is a copy per turn")
    T.eq(#Tips.advise("rust", "fn main() {\n    println!(\"hi\");\n}\n"), 0,
      "a clean program is left alone")
    local go = Tips.advise("go", "func main() {\n\tv, err := f()\n\t_ = v\n}\n")
    T.ok(#go > 0 and go[1].id == "go.err-unchecked", "an unchecked err in Go")
  end)
end
