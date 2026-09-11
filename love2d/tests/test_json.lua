-- The JSON cases PROTOCOL.md actually needs.
--
-- Every one of these is a shape that crosses the wire in this game, not a
-- generic JSON exercise. A library that turns `{}` into `[]` breaks `payload`
-- on every single frame (§2), and a library that folds `null` into absent
-- breaks `id` on every server event (§2.2).

local T = require("tests.framework")
local json = require("src.json")

return function()
  T.section("json — the shapes PROTOCOL.md carries")

  T.case("an empty payload stays an object", function()
    T.eq(json.encode({}), "{}")
    T.eq(json.encode({ v = 1, id = "c-1", type = "ping", payload = {} }),
      '{"id":"c-1","payload":{},"type":"ping","v":1}')
  end)

  T.case("an empty array stays an array through a round trip", function()
    local decoded = json.decode('{"nodes":[],"edges":[]}')
    T.eq(json.encode(decoded), '{"edges":[],"nodes":[]}')
    -- And an object beside it is still an object.
    T.eq(json.encode(json.decode('{"a":{},"b":[]}')), '{"a":{},"b":[]}')
  end)

  T.case("a constructed empty array encodes as []", function()
    T.eq(json.encode({ requires = json.array({}) }), '{"requires":[]}')
  end)

  T.case("null is distinguishable from absent", function()
    local env = json.decode('{"v":1,"id":null,"type":"run.log","payload":{}}')
    T.eq(env.id, json.null, "`id: null` must not become nil")
    T.ne(env.id, nil)
    T.eq(env.missing, nil, "an absent key is nil")
    -- §5.3's `time_limit_s: null` means untimed; §5.4's `exit_code: null`
    -- means the process never exited normally. Both are values.
    local q = json.decode('{"time_limit_s":null,"starter":"fn main(){}"}')
    T.eq(q.time_limit_s, json.null)
    T.eq(json.encode(q), '{"starter":"fn main(){}","time_limit_s":null}')
  end)

  T.case("source and run.log survive newlines, tabs and backslashes", function()
    -- Every `source` field and every `run.log` chunk is exactly this.
    local source = 'fn main() {\n\tlet s = "a\\nb";\n\tprintln!("{}", s);\n}\n'
    local wire = json.encode({ source = source })
    T.ok(not wire:find("\n", 1, true), "a raw newline must not appear in the JSON text")
    T.eq(json.decode(wire).source, source)

    local chunk = 'error[E0382]: borrow of moved value: `s`\n  --> src\\main.rs:4:20\n'
    T.eq(json.decode(json.encode({ chunk = chunk })).chunk, chunk)

    -- A carriage return and a tab, which rustc emits in its ASCII art.
    local weird = "a\r\n\tb\1c"
    T.eq(json.decode(json.encode({ s = weird })).s, weird)
    T.ok(json.encode({ s = weird }):find("\\u0001", 1, true), "control bytes escape as \\u")
  end)

  T.case("UTF-8 goes through as bytes, and \\u escapes come back as UTF-8", function()
    local name = "銅鑼灣 ferris 🦀"
    T.eq(json.decode(json.encode({ name = name })).name, name)
    -- A server that escapes instead: the surrogate pair must rejoin.
    T.eq(json.decode('"\\ud83e\\udd80"'), "🦀")
    T.eq(json.decode('"\\u9280"'), "銀")
  end)

  T.case("nested objects keep their shape", function()
    local text = '{"attempt":{"cases":[{"name":"greets","passed":true,"visible":true}],'
      .. '"mistakes":[],"exit_code":null,"stars":2}}'
    local v = json.decode(text)
    T.eq(v.attempt.cases[1].name, "greets")
    T.eq(v.attempt.cases[1].passed, true)
    T.eq(#v.attempt.mistakes, 0)
    T.eq(v.attempt.exit_code, json.null)
    T.eq(json.encode(v), '{"attempt":{"cases":[{"name":"greets","passed":true,"visible":true}],'
      .. '"exit_code":null,"mistakes":[],"stars":2}}')
  end)

  T.case("integers do not become floats", function()
    -- `node`, `difficulty`, `stars`, `seq` and `elapsed_ms` are all integers.
    T.eq(json.encode({ seq = 3 }), '{"seq":3}')
    T.eq(json.encode({ elapsed_ms = 812 }), '{"elapsed_ms":812}')
    T.eq(json.encode({ accuracy = 0.42 }), '{"accuracy":0.42}')
  end)

  T.case("a 256 KiB source round trips", function()
    -- §4.9 caps `source` at 256 KiB; the encoder must not choke below it.
    local big = string.rep('let x = "line\\n";\n', 12000)
    local decoded = json.decode(json.encode({ source = big }))
    T.eq(#decoded.source, #big)
    T.eq(decoded.source, big)
  end)

  T.case("malformed input is an error, not a guess", function()
    T.eq(json.try_decode("{"), nil)
    T.eq(json.try_decode('{"a":1,}'), nil)
    T.eq(json.try_decode('{"a":1} trailing'), nil)
    T.eq(json.try_decode("'single'"), nil)
    local v, err = json.try_decode("nope")
    T.eq(v, nil)
    T.ok(type(err) == "string" and #err > 0)
  end)

  T.case("a self-referential table is refused rather than looping forever", function()
    local t = {}
    t.self = t
    T.raises(function() json.encode(t) end, "itself")
  end)
end
