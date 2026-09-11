-- PROTOCOL §8 point 8: "It buffers `run.log` chunks rather than assuming
-- line boundaries, and notices a `seq` gap."
--
-- Both halves are asserted here, and the chunks are split in the nastiest
-- places a real server can split them: mid-line, mid-word, and mid-UTF-8
-- code point.

local T = require("tests.framework")
local runlog = require("src.net.runlog")

local function chunk(stream, seq, text, attempt)
  return { attempt_id = attempt or "att_91c", stream = stream, seq = seq, chunk = text }
end

return function()
  T.section("run.log — buffering and seq gaps (§8.8)")

  T.case("chunks that split mid-line reassemble", function()
    local log = runlog.new("att_91c")
    log:add(chunk("compile", 0, "error[E0382]: borr"))
    log:add(chunk("compile", 1, "ow of moved value: `s`\n  --> src/ma"))
    log:add(chunk("compile", 2, "in.rs:4:20\n"))
    T.eq(log:text("compile"),
      "error[E0382]: borrow of moved value: `s`\n  --> src/main.rs:4:20\n")
    local lines, tail = log:lines("compile")
    T.eq(#lines, 2)
    T.eq(lines[1], "error[E0382]: borrow of moved value: `s`")
    T.eq(lines[2], "  --> src/main.rs:4:20")
    T.eq(tail, "")
  end)

  T.case("a chunk split mid-UTF-8 is joined by byte, not by character", function()
    -- "銅鑼灣" is three 3-byte code points; the split lands inside the second.
    local whole = "note: 銅鑼灣\n"
    local cut = 9 -- inside the second character's bytes
    local log = runlog.new("att_91c")
    log:add(chunk("stderr", 0, whole:sub(1, cut)))
    log:add(chunk("stderr", 1, whole:sub(cut + 1)))
    T.eq(log:text("stderr"), whole)
  end)

  T.case("a line with no trailing newline is a tail, not a line", function()
    local log = runlog.new("att_91c")
    log:add(chunk("stdout", 0, "hello, causewaybay"))
    local lines, tail = log:lines("stdout")
    T.eq(#lines, 0, "an unterminated line is not yet a line")
    T.eq(tail, "hello, causewaybay")
    log:add(chunk("stdout", 1, "\n"))
    local lines2, tail2 = log:lines("stdout")
    T.eq(#lines2, 1)
    T.eq(lines2[1], "hello, causewaybay")
    T.eq(tail2, "")
  end)

  T.case("out-of-order chunks are placed, not appended", function()
    local log = runlog.new("att_91c")
    log:add(chunk("compile", 2, "three\n"))
    log:add(chunk("compile", 0, "one\n"))
    T.eq(log:text("compile"), "one\n", "only the contiguous prefix is shown")
    T.nope(log:complete(), "seq 1 is still missing")
    log:add(chunk("compile", 1, "two\n"))
    T.eq(log:text("compile"), "one\ntwo\nthree\n")
    T.ok(log:complete())
  end)

  T.case("a gap is noticed and named", function()
    local log = runlog.new("att_91c")
    log:add(chunk("compile", 0, "a"))
    log:add(chunk("compile", 1, "b"))
    log:add(chunk("compile", 3, "d"))   -- 2 never arrives
    log:add(chunk("stdout", 0, "fine"))
    T.nope(log:complete())
    local gaps = log:gaps()
    T.ok(gaps ~= nil)
    T.same(gaps.compile, { 2 })
    T.eq(gaps.stdout, nil, "a stream with no hole is not reported")
    T.eq(log:gap_report(), "compile: missing seq 2")
    T.eq(log:text("compile"), "ab", "the text stops at the hole")
  end)

  T.case("seq counts per stream, so two streams at seq 0 are not a conflict", function()
    local log = runlog.new("att_91c")
    log:add(chunk("compile", 0, "compiling\n"))
    log:add(chunk("stdout", 0, "hello\n"))
    log:add(chunk("stderr", 0, "warn\n"))
    T.ok(log:complete())
    T.eq(log:text("compile"), "compiling\n")
    T.eq(log:text("stdout"), "hello\n")
    T.eq(log:text("stderr"), "warn\n")
  end)

  T.case("a duplicate chunk is counted, not applied twice", function()
    local log = runlog.new("att_91c")
    log:add(chunk("stdout", 0, "once\n"))
    log:add(chunk("stdout", 0, "once\n"))
    T.eq(log:text("stdout"), "once\n")
    T.eq(log.streams.stdout.duplicates, 1)
  end)

  T.case("a chunk for another attempt is refused", function()
    local log = runlog.new("att_91c")
    local ok, why = log:add(chunk("stdout", 0, "not mine", "att_other"))
    T.eq(ok, false)
    T.ok(why:find("att_other"))
    T.eq(log:text("stdout"), "")
  end)

  T.case("malformed payloads are refused rather than crashing the frame", function()
    local log = runlog.new("att_91c")
    T.eq(select(1, log:add(nil)), false)
    T.eq(select(1, log:add({ stream = "stdout", seq = 0 })), false)
    T.eq(select(1, log:add({ stream = "stdout", seq = -1, chunk = "x" })), false)
    T.eq(select(1, log:add({ stream = "stdout", seq = 1.5, chunk = "x" })), false)
    T.eq(select(1, log:add({ seq = 0, chunk = "x" })), false)
  end)

  T.case("the §4.18 truncation marker is recognised", function()
    local log = runlog.new("att_91c")
    log:add(chunk("stdout", 0, string.rep("x", 100)))
    T.nope(log.truncated)
    log:add(chunk("stdout", 1, "\n…output truncated\n"))
    T.ok(log.truncated, "the client must be able to render this as a note, not as output")
  end)
end
