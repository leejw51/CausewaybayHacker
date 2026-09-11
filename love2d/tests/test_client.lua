-- PROTOCOL.md §8, the conformance checklist, point by point.
--
-- Each case names the point it covers. Ten of the twelve are checkable here,
-- with no server and no window; the two that are not (9's real backoff wall
-- clock is driven by a fake clock, and 5's "never, ever" is also asserted in
-- the Rust suite) are covered as closely as a local test can.

local T = require("tests.framework")
local fake = require("tests.fake")
local netclient = require("src.net.client")
local errors = require("src.net.errors")
local json = require("src.json")
local ws = require("src.net.ws")

--- Build a client wired to a fresh fake, already open.
local function connected(opts)
  opts = opts or {}
  local clock = fake.clock()
  local server = fake.new(opts.fake)
  local c = netclient.new({
    url = opts.url or "ws://127.0.0.1:5390/ws",
    transport = function() return server end,
    now = clock.now,
    rand = fake.rand(opts.seed or 11),
    log = opts.log or function() end,
    auto_reconnect = opts.auto_reconnect,
    app_ping_s = opts.app_ping_s,
  })
  c:connect()
  c:update()
  return c, server, clock
end

return function()
  T.section("client — §8.1: every frame is v/id/type/payload")

  T.case("outgoing frames have exactly the four keys, payload an object", function()
    local c, server = connected()
    T.eq(c.state, "open")
    c:request("world.map", { land = "rust", category = "basic" })
    c:request("ping", nil) -- a nil payload must become {}
    c:update()
    T.eq(#server.envelopes, 2)
    for _, env in ipairs(server.envelopes) do
      local n = 0
      for _ in pairs(env) do n = n + 1 end
      T.eq(n, 4, "an envelope has exactly four keys")
      T.eq(env.v, 1)
      T.eq(type(env.id), "string")
      T.eq(type(env.type), "string")
      T.eq(type(env.payload), "table")
    end
    T.eq(server.envelopes[1].type, "world.map")
    T.eq(server.envelopes[2].payload and next(server.envelopes[2].payload), nil,
      "a missing payload is sent as {}")
    -- And it is `{}` on the wire, not `[]`.
    T.ok(server.frames[2].payload:find('"payload":{}', 1, true))
  end)

  T.case("ids are unique and follow the c-N convention", function()
    local c, server = connected()
    local seen = {}
    for _ = 1, 20 do c:request("ping", {}) end
    c:update()
    for _, env in ipairs(server.envelopes) do
      T.ok(env.id:match("^c%-%d+$") ~= nil, "id looks like c-N")
      T.eq(seen[env.id], nil, "an id is never reused while in flight")
      seen[env.id] = true
    end
  end)

  T.case("every client frame is masked — RFC 6455 §5.1", function()
    local c, server = connected()
    c:request("ping", {})
    c:update()
    T.ok(#server.frames > 0)
    for _, frame in ipairs(server.frames) do
      T.eq(frame.masked, true, "an unmasked client frame is dropped by a real server")
    end
    T.nope(server.unmasked_seen)
  end)

  T.section("client — §8.2: replies matched by id, out of order")

  T.case("a later request answered first still reaches its own callback", function()
    local c, server = connected()
    local order = {}
    local submit_id = c:request("quest.submit", { quest_id = "q", lang = "rust", source = "x" },
      function(ok, payload)
        order[#order + 1] = "submit:" .. tostring(ok) .. ":" .. tostring(payload.attempt and payload.attempt.id)
      end)
    local ping_id = c:request("ping", {}, function(ok, payload)
      order[#order + 1] = "ping:" .. tostring(ok) .. ":" .. tostring(payload.t)
    end)
    c:update()
    T.ne(submit_id, ping_id)

    -- §2.2: "a `ping` sent after it will come back first".
    server:reply(ping_id, "ping.ok", { t = "2026-09-11T04:12:33Z" })
    c:update()
    T.same(order, { "ping:true:2026-09-11T04:12:33Z" })

    server:reply(submit_id, "quest.submit.ok", { attempt = { id = "att_91c" } })
    c:update()
    T.eq(#order, 2)
    T.eq(order[2], "submit:true:att_91c")
    T.eq(c:inflight(), 0)
  end)

  T.case("a reply with an id nobody is waiting for is ignored, loudly", function()
    local logged = {}
    local c, server = connected({ log = function(level, msg) logged[#logged + 1] = level .. ":" .. msg end })
    server:reply("c-999", "ping.ok", { t = "now" })
    c:update()
    T.eq(c.state, "open", "an unexpected id does not close the connection")
    local found = false
    for _, line in ipairs(logged) do
      if line:find("c%-999") then found = true end
    end
    T.ok(found, "it is logged rather than swallowed")
  end)

  T.case("a reply of the wrong type still answers the request", function()
    local c, server = connected()
    local got
    local id = c:request("quest.get", { quest_id = "q" }, function(ok, payload)
      got = { ok = ok, code = payload.code }
    end)
    c:update()
    server:reply(id, "world.map.ok", {})
    c:update()
    T.eq(got.ok, false, "a scene must not hang waiting for a reply that came back wrong")
    T.eq(got.code, "internal")
  end)

  T.section("client — §8.3: unknown types are ignored")

  T.case("an unknown server event neither errors nor closes", function()
    local c, server = connected()
    server:event("weather.update", { rain = true })
    server:event("award", { kind = "badge", id = "first-clear" })
    c:update()
    T.eq(c.state, "open")
    T.eq(c.unknown_types["weather.update"], 1)
    T.eq(c.unknown_types["award"], 1, "an event with no handler is simply ignored")
    T.eq(server.client_closed_with, nil, "no close frame was sent")

    -- With a handler registered, the same event is delivered.
    local seen
    c:on("award", function(p) seen = p.id end)
    server:event("award", { kind = "badge", id = "first-clear" })
    c:update()
    T.eq(seen, "first-clear")
  end)

  T.case("a frame that is not a §2 envelope is dropped, not fatal", function()
    local c, server = connected()
    server:raw(ws.TEXT, "this is not json at all")
    server:raw(ws.TEXT, '{"v":1,"type":"ping.ok"}')          -- no payload
    server:raw(ws.TEXT, '{"v":1,"id":null,"type":"x","payload":{},"extra":1}')
    server:raw(ws.TEXT, '{"v":9,"id":null,"type":"x","payload":{}}')
    c:update()
    T.eq(c.state, "open")
    -- And a good frame right after them still works.
    local seen
    c:on("progress.update", function(p) seen = p.quest_id end)
    server:event("progress.update", { quest_id = "rust.basic.01.hello" })
    c:update()
    T.eq(seen, "rust.basic.01.hello")
  end)

  T.section("client — §8.4: every error code, unknown ones as internal")

  T.case("the §3.3 set is complete and closed", function()
    for _, code in ipairs({
      "proto_version", "bad_request", "unauthorized", "auth_expired",
      "auth_nonce_used", "auth_bad_signature", "not_found", "locked",
      "rate_limited", "busy", "internal",
    }) do
      local c = errors.classify(code)
      T.eq(c.known, true, code .. " must be handled")
      T.ok(type(c.player) == "string" and #c.player > 0)
      T.ok(type(c.action) == "string" and #c.action > 0)
    end
    local n = 0
    for _ in pairs(errors.CODES) do n = n + 1 end
    T.eq(n, 11, "§3.3 lists exactly eleven codes")
  end)

  T.case("an unknown code is treated as internal, with the original kept", function()
    local c = errors.classify("not_authorized") -- the mock server's known fault
    T.eq(c.known, false)
    T.eq(c.action, errors.CODES.internal.action)
    T.eq(c.player, errors.CODES.internal.player)
    T.eq(c.code, "not_authorized", "the original code survives for the log")
  end)

  T.case("an .err reply reaches the callback with the §3.3 payload", function()
    local c, server = connected()
    local got
    local id = c:request("quest.get", { quest_id = "rust.basic.04.slices" }, function(ok, payload)
      got = { ok = ok, payload = payload }
    end)
    c:update()
    server:reply_err(id, "quest.get", "locked", "rust.basic.04.slices is locked",
      { requires = { "rust.basic.03.shadowing" } })
    c:update()
    T.eq(got.ok, false)
    T.ok(errors.is_error_payload(got.payload), "the payload is exactly {code,message,detail}")
    T.eq(errors.classify(got.payload.code).action, "show")
    T.eq(got.payload.detail.requires[1], "rust.basic.03.shadowing")
  end)

  T.section("client — §8.5: no key material, ever")

  T.case("nothing the client sends contains a mnemonic or a private key", function()
    local c, server = connected()
    -- The whole login sequence, as the login scene drives it.
    c:request("auth.challenge", { address = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94" })
    c:request("auth.login", {
      address = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94",
      signature = "0x" .. string.rep("ab", 65),
      name = "ferris",
    })
    c:request("auth.resume", { token = "kR3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" })
    c:update()
    local wire = ""
    for _, frame in ipairs(server.frames) do wire = wire .. frame.payload end
    for _, forbidden in ipairs({
      "mnemonic", "private_key", "privateKey", "seed", "passphrase",
      "abandon abandon", "0x1ab42cc412b618bdea3a599e3c9bae199ebf030895b039e9db1e30dafb12b727",
    }) do
      T.nope(wire:find(forbidden, 1, true), forbidden .. " must never cross the wire")
    end
    -- And the client has no API that would put one there.
    T.eq(netclient.Client.send_key, nil)
  end)

  T.section("client — §8.10: one quest.submit in flight")

  T.case("a second submit is refused locally with busy", function()
    local c, server = connected()
    local first_id = c:request("quest.submit", { quest_id = "q", lang = "rust", source = "a" },
      function() end)
    T.ok(first_id ~= nil)
    local second, why = c:request("quest.submit", { quest_id = "q", lang = "rust", source = "b" },
      function(ok, payload)
        T.eq(ok, false)
        T.eq(payload.code, "busy")
      end)
    T.eq(second, nil)
    T.eq(why, "busy")
    c:update()
    T.eq(#server:sent("quest.submit"), 1, "the second submit never left the client")

    -- Once the first is answered, another is allowed.
    server:reply(first_id, "quest.submit.ok", { attempt = { id = "att_1" } })
    c:update()
    T.ok(c:request("quest.submit", { quest_id = "q", lang = "rust", source = "c" }) ~= nil)
  end)

  T.case("everything else pipelines freely", function()
    local c, server = connected()
    for _ = 1, 5 do c:request("quest.get", { quest_id = "q" }) end
    c:update()
    T.eq(#server:sent("quest.get"), 5, "§3.2: every other request may be pipelined")
  end)

  T.case("a dropped connection releases the submit slot", function()
    local c, server = connected({ auto_reconnect = false })
    local answered
    c:request("quest.submit", { quest_id = "q", lang = "rust", source = "a" },
      function(ok, payload) answered = payload.code end)
    c:update()
    server:drop()
    c:update()
    T.eq(c.state, "closed")
    T.eq(answered, "internal", "an in-flight request is answered rather than left hanging")
    T.eq(c.submit_inflight, false)
  end)

  T.section("client — §8.11: server.bye then close, and close with no bye")

  T.case("server.bye followed by a close frame is survived", function()
    local c, server = connected({ auto_reconnect = false })
    local reason
    c:on("server.bye", function(p) reason = p.reason end)
    server:event("server.bye", { reason = "shutdown" })
    server:close_frame(1001, "going away")
    c:update()
    T.eq(reason, "shutdown")
    T.eq(c.state, "closed")
    T.eq(server.client_closed_with, 1001, "the client echoes the close code")
  end)

  T.case("a bare TCP drop with no close frame is survived", function()
    local c, server = connected({ auto_reconnect = false })
    server:drop()
    c:update()
    T.eq(c.state, "closed")
  end)

  T.case("close 4001 is reported so the app can go back to login", function()
    local c, server = connected({ auto_reconnect = false })
    local detail
    c:on_state(function(state, d) if state == "closed" then detail = d end end)
    server:close_frame(4001, "session revoked")
    c:update()
    T.eq(detail, "close:4001")
  end)

  T.section("client — §8.9: reconnect with backoff")

  T.case("a server that stays down is retried 0.5, 1, 2, 4, 8, 8, 8", function()
    local clock = fake.clock()
    local c = netclient.new({
      url = "ws://127.0.0.1:5390/ws",
      -- The server is not running: every connect is refused, which is the
      -- case that actually exercises the ladder.
      transport = function() return fake.new({ connect_fails = true }) end,
      now = clock.now,
      rand = fake.rand(5),
    })
    local delays = {}
    local before = clock.now()
    c:connect()
    T.eq(c.state, "closed")
    for _ = 1, 7 do
      T.ok(c.retry_at ~= nil, "a retry is always scheduled")
      delays[#delays + 1] = c.retry_at - before
      before = c.retry_at
      clock.set(c.retry_at)
      c:update()
    end

    local base = { 0.5, 1, 2, 4, 8, 8, 8 }
    for i, want in ipairs(base) do
      -- PROTOCOL §6: ±20% jitter around each step. "Do not hammer."
      T.ok(delays[i] >= want * 0.79 and delays[i] <= want * 1.21,
        ("attempt %d waited %.2fs, expected %.1fs ±20%%"):format(i, delays[i], want))
    end
    -- Not every wait is identical, or it is not jittered at all.
    T.ne(delays[5], delays[6])
    T.ne(delays[6], delays[7])
  end)

  T.case("after a drop the client comes back on its own", function()
    local clock = fake.clock()
    local servers = {}
    local c = netclient.new({
      url = "ws://127.0.0.1:5390/ws",
      transport = function()
        local s = fake.new(); servers[#servers + 1] = s; return s
      end,
      now = clock.now,
      rand = fake.rand(5),
    })
    c:connect(); c:update()
    T.eq(c.state, "open")
    for _ = 1, 3 do
      servers[#servers]:drop()
      c:update()
      T.eq(c.state, "closed")
      T.ok(c.retry_at ~= nil)
      clock.set(c.retry_at)
      c:update()
      T.eq(c.state, "open", "the client came back in one frame")
    end
    T.eq(#servers, 4, "a fresh socket each time")
  end)

  T.case("a successful handshake resets the backoff", function()
    local clock = fake.clock()
    local servers = {}
    local c = netclient.new({
      url = "ws://127.0.0.1:5390/ws",
      transport = function()
        local s = fake.new(); servers[#servers + 1] = s; return s
      end,
      now = clock.now,
      rand = fake.rand(2),
    })
    c:connect(); c:update()
    for _ = 1, 3 do
      servers[#servers]:drop(); c:update()
      clock.advance(20); c:update()
    end
    T.eq(c.state, "open")
    T.eq(c.attempt, 0, "the counter resets once the connection is up")
  end)

  T.case("a rejected handshake is a failure, not an open connection", function()
    local c = select(1, connected({ fake = { reject_handshake = true }, auto_reconnect = false }))
    c:update()
    T.ne(c.state, "open")
  end)

  T.case("a wrong Sec-WebSocket-Accept is refused", function()
    local c = select(1, connected({ fake = { bad_accept = true }, auto_reconnect = false }))
    c:update()
    T.ne(c.state, "open", "this is not a websocket server and the client must say so")
  end)

  T.section("client — §8.12: keepalive")

  T.case("the server's websocket pings are answered with pongs", function()
    local c, server = connected()
    server:ping("are you there")
    c:update()
    T.eq(#server.pongs, 1)
    T.eq(server.pongs[1], "are you there", "a pong echoes the ping's payload")
    T.eq(c.pongs_sent, 1)
  end)

  T.case("the application-level ping goes out every 20 s as well", function()
    local c, server, clock = connected()
    T.eq(#server:sent("ping"), 0)
    clock.advance(19)
    c:update()
    T.eq(#server:sent("ping"), 0, "not yet")
    clock.advance(2)
    c:update()
    T.eq(#server:sent("ping"), 1, "§1.1: every 20 seconds")
    clock.advance(20)
    c:update()
    T.eq(#server:sent("ping"), 2)
    -- And it is a normal correlated request, so §4.1's round-trip timer works.
    local last = server:sent("ping")[2]
    T.eq(type(last.id), "string")
    T.eq(last.type, "ping")
  end)

  T.section("client — events and streaming")

  T.case("run.stage and run.log arrive as id:null events", function()
    local c, server = connected()
    local stages, chunks = {}, {}
    c:on("run.stage", function(p) stages[#stages + 1] = p.stage end)
    c:on("run.log", function(p) chunks[#chunks + 1] = p.chunk end)
    local id = c:request("quest.submit", { quest_id = "q", lang = "rust", source = "x" })
    c:update()
    server:event("run.stage", { attempt_id = "att_1", stage = "queued", queued = 0, elapsed_ms = 1 })
    server:event("run.log", { attempt_id = "att_1", stream = "compile", chunk = "err", seq = 0 })
    server:event("run.stage", { attempt_id = "att_1", stage = "compiling", elapsed_ms = 12 })
    server:reply(id, "quest.submit.ok", { attempt = { id = "att_1", verdict = "accepted" } })
    -- §4.17/§4.18: an event may arrive *after* the reply it relates to.
    server:event("run.log", { attempt_id = "att_1", stream = "stdout", chunk = "late", seq = 0 })
    c:update()
    T.same(stages, { "queued", "compiling" })
    T.same(chunks, { "err", "late" })
  end)

  T.case("a request sent while closed is answered locally, not queued", function()
    local c = netclient.new({
      url = "ws://127.0.0.1:5390/ws",
      transport = function() return fake.new() end,
      now = fake.clock().now,
      rand = fake.rand(1),
    })
    local got
    local id, why = c:request("ping", {}, function(ok, payload) got = payload.code end)
    T.eq(id, nil)
    T.eq(why, "not connected")
    T.eq(got, "internal")
  end)

  T.case("the url is parsed, and wss is refused rather than downgraded", function()
    local u = netclient.parse_url("ws://127.0.0.1:5390/ws")
    T.eq(u.host, "127.0.0.1")
    T.eq(u.port, 5390)
    T.eq(u.path, "/ws")
    T.eq(netclient.parse_url("ws://localhost/ws").port, 80)
    T.eq(netclient.parse_url("ws://localhost").path, "/")
    T.eq(netclient.parse_url("wss://example.com/ws"), nil)
    T.eq(netclient.parse_url("127.0.0.1:5390"), nil)
  end)

  T.case("the envelope validator is exactly §2's rule", function()
    T.eq(netclient.is_envelope({ v = 1, id = json.null, type = "x", payload = {} }), true)
    T.eq(netclient.is_envelope({ v = 1, id = "c-1", type = "x", payload = {} }), true)
    T.eq(netclient.is_envelope({ v = 1, id = "c-1", type = "x", payload = {}, extra = 1 }), false)
    T.eq(netclient.is_envelope({ v = 1, id = "c-1", type = "x" }), false)
    T.eq(netclient.is_envelope({ v = 2, id = "c-1", type = "x", payload = {} }), false)
    T.eq(netclient.is_envelope({ v = 1, id = 7, type = "x", payload = {} }), false)
    T.eq(netclient.is_envelope({ v = 1, id = "c-1", type = "x", payload = "no" }), false)
  end)

  T.section("client — src/net and src/json hold no `love`")

  T.case("the codec layer never touches love", function()
    -- Structural, and the reason the whole suite above can run headless. The
    -- Makefile asserts the same thing with grep; this asserts it from inside.
    local files = {
      "src/json.lua", "src/net/ws.lua", "src/net/client.lua", "src/net/sha1.lua",
      "src/net/base64.lua", "src/net/bitops.lua", "src/net/runlog.lua",
      "src/net/errors.lua", "src/net/socket.lua", "src/wallet.lua",
    }
    for _, path in ipairs(files) do
      T.no_love(path)
    end
  end)
end
