-- RFC 6455: the handshake and the frame codec.
--
-- Everything here runs with no socket, no server and no window.

local T = require("tests.framework")
local ws = require("src.net.ws")
local sha1 = require("src.net.sha1")
local base64 = require("src.net.base64")
local bitops = require("src.net.bitops")

-- A deterministic rng in the shape `love.math.random(lo, hi)` has.
local function fixed_rand(seed)
  local state = seed or 1
  return function(lo, hi)
    state = (state * 1103515245 + 12345) % 2147483648
    return lo + (math.floor(state / 65536) % (hi - lo + 1))
  end
end

return function()
  T.section("sha1 / base64 — the handshake primitives")

  T.case("sha1 matches the published vectors", function()
    T.eq(sha1.hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    T.eq(sha1.hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
    T.eq(sha1.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
      "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    -- Multi-block, and a length that lands exactly on the padding boundary.
    T.eq(sha1.hex(string.rep("a", 55)), "c1c8bbdc22796e28c0e15163d20899b65621d65a")
    T.eq(sha1.hex(string.rep("a", 56)), "c2db330f6083854c99d4b5bfb6e8f29f201be699")
    T.eq(sha1.hex(string.rep("a", 57)), "f08f24908d682555111be7ff6f004e78283d989a")
    T.eq(sha1.hex(string.rep("a", 64)), "0098ba824b5c16427bd7a1122a5a442a25ec644d")
    T.eq(sha1.hex(string.rep("a", 119)), "ee971065aaa017e0632a8ca6c77bb3bf8b1dfc56")
    T.eq(sha1.hex(string.rep("a", 120)), "f34c1488385346a55709ba056ddd08280dd4c6d6")
    T.eq(sha1.hex(string.rep("a", 1000000)), "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
  end)

  T.case("base64 round trips, including every padding length", function()
    for _, pair in ipairs({
      { "", "" }, { "f", "Zg==" }, { "fo", "Zm8=" }, { "foo", "Zm9v" },
      { "foob", "Zm9vYg==" }, { "fooba", "Zm9vYmE=" }, { "foobar", "Zm9vYmFy" },
    }) do
      T.eq(base64.encode(pair[1]), pair[2])
      T.eq(base64.decode(pair[2]), pair[1])
    end
    -- Every byte value, which is what a 16-byte random key is.
    local all = {}
    for i = 0, 255 do all[i + 1] = string.char(i) end
    all = table.concat(all)
    T.eq(base64.decode(base64.encode(all)), all)
  end)

  T.section("ws — the handshake")

  T.case("Sec-WebSocket-Accept matches RFC 6455 §1.3's own example", function()
    T.eq(ws.accept_for("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  end)

  T.case("the key is 16 random bytes, base64'd", function()
    local key = ws.new_key(fixed_rand(7))
    T.eq(#key, 24, "16 bytes is 24 base64 characters")
    T.eq(#base64.decode(key), 16)
    T.ne(ws.new_key(fixed_rand(7)), ws.new_key(fixed_rand(9)))
  end)

  T.case("the request is a conformant HTTP upgrade", function()
    local req = ws.handshake_request("127.0.0.1", 5390, "/ws", "dGhlIHNhbXBsZSBub25jZQ==")
    T.ok(req:find("^GET /ws HTTP/1%.1\r\n"))
    T.ok(req:find("\r\nHost: 127%.0%.0%.1:5390\r\n"))
    T.ok(req:find("\r\nUpgrade: websocket\r\n"))
    T.ok(req:find("\r\nConnection: Upgrade\r\n"))
    T.ok(req:find("\r\nSec%-WebSocket%-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"))
    T.ok(req:find("\r\nSec%-WebSocket%-Version: 13\r\n"))
    T.ok(req:find("\r\n\r\n$"))
    -- PROTOCOL §1: compression is not negotiated, so it is not offered.
    T.nope(req:find("permessage%-deflate"))
    T.nope(req:find("Sec%-WebSocket%-Protocol"))
  end)

  T.case("the response head is parsed, and the body after it is kept", function()
    local key = "dGhlIHNhbXBsZSBub25jZQ=="
    local head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
      .. "Connection: Upgrade\r\nSec-WebSocket-Accept: " .. ws.accept_for(key) .. "\r\n\r\n"
    -- A server may pack the first frames into the same TCP segment.
    local first = ws.encode(ws.TEXT, "hello", "abcd")
    local status, headers, rest = ws.parse_handshake_response(head .. first)
    T.eq(status.code, 101)
    T.eq(headers["upgrade"], "websocket")
    T.eq(rest, first, "bytes after the blank line are not thrown away")
    T.eq(ws.check_handshake(status, headers, key), true)
  end)

  T.case("an incomplete head asks for more rather than failing", function()
    local status, why = ws.parse_handshake_response("HTTP/1.1 101 Switch")
    T.eq(status, nil)
    T.eq(why, "incomplete")
  end)

  T.case("a wrong accept, a wrong code and a surprise extension are all refused", function()
    local key = "dGhlIHNhbXBsZSBub25jZQ=="
    local function check(hdrs, code)
      return ws.check_handshake({ code = code or 101, line = "" }, hdrs, key)
    end
    local good = {
      upgrade = "websocket",
      connection = "Upgrade",
      ["sec-websocket-accept"] = ws.accept_for(key),
    }
    T.eq(check(good), true)
    local bad = {}
    for k, v in pairs(good) do bad[k] = v end
    bad["sec-websocket-accept"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAA="
    T.eq(check(bad), nil, "a wrong Sec-WebSocket-Accept must fail the handshake")
    T.eq(check(good, 200), nil, "200 is not 101")
    local ext = {}
    for k, v in pairs(good) do ext[k] = v end
    ext["sec-websocket-extensions"] = "permessage-deflate"
    T.eq(check(ext), nil, "an extension this client did not offer is refused")
  end)

  T.section("ws — framing")

  T.case("every client frame is masked, always", function()
    local frame = ws.encode(ws.TEXT, "hello", "\1\2\3\4")
    local b1 = frame:byte(2)
    T.ok(bitops.band(b1, 0x80) ~= 0, "the MASK bit must be set on a client frame")
    -- The payload on the wire is not the plaintext.
    T.nope(frame:find("hello", 1, true), "a masked payload must not appear in the clear")
    -- And there is no unmasked path: `encode` demands a 4-byte key.
    T.eq(ws.encode(ws.TEXT, "hello", "abc"), nil)
  end)

  T.case("mask is its own inverse", function()
    local key = "\xDE\xAD\xBE\xEF"
    local payload = string.rep("borrow of moved value: `s`\n", 100)
    T.eq(ws.mask(ws.mask(payload, key), key), payload)
    T.eq(ws.mask(ws.mask("", key), key), "")
    -- Across the 4096-byte chunking boundary inside `mask`.
    local big = string.rep("x", 4097)
    T.eq(ws.mask(ws.mask(big, key), key), big)
  end)

  T.case("all three length encodings, at their exact boundaries", function()
    local key = "\1\2\3\4"
    local function roundtrip(n)
      local payload = string.rep("a", n)
      local frame = ws.encode(ws.TEXT, payload, key)
      local got, next_offset = ws.decode(frame, 1)
      T.ok(got ~= nil, ("a %d-byte frame must decode"):format(n))
      if got then
        T.eq(got.payload, payload, ("payload of %d bytes"):format(n))
        T.eq(got.opcode, ws.TEXT)
        T.eq(got.masked, true)
        T.eq(next_offset, #frame + 1, "decode consumes exactly the frame")
      end
      return frame
    end
    -- 7-bit
    T.eq(roundtrip(0):byte(2), 0x80 + 0)
    T.eq(roundtrip(125):byte(2), 0x80 + 125)
    -- 16-bit begins at 126
    T.eq(roundtrip(126):byte(2), 0x80 + 126)
    local f65535 = roundtrip(65535)
    T.eq(f65535:byte(2), 0x80 + 126)
    T.eq(f65535:byte(3) * 256 + f65535:byte(4), 65535)
    -- 64-bit begins at 65536
    local f65536 = roundtrip(65536)
    T.eq(f65536:byte(2), 0x80 + 127)
    T.eq(f65536:byte(3), 0)
    T.eq(f65536:byte(9) * 256 + f65536:byte(10), 65536 % 65536 + 1 * 0, "high bytes are zero")
    T.eq(f65536:byte(8) * 65536 + f65536:byte(9) * 256 + f65536:byte(10), 65536)
  end)

  T.case("an incomplete frame asks for more bytes", function()
    local frame = ws.encode(ws.TEXT, string.rep("a", 300), "\1\2\3\4")
    for _, cut in ipairs({ 1, 2, 3, 4, 7, 8, 100, #frame - 1 }) do
      local got, why = ws.decode(frame:sub(1, cut), 1)
      T.eq(got, nil, ("%d bytes is not a whole frame"):format(cut))
      T.eq(why, "incomplete")
    end
    T.ok(ws.decode(frame, 1) ~= nil)
  end)

  T.case("control frames obey their limits", function()
    T.eq(ws.encode(ws.PING, string.rep("x", 126), "\1\2\3\4"), nil, "a ping payload is 125 max")
    T.eq(ws.encode(ws.PING, "x", "\1\2\3\4", false), nil, "a control frame cannot be fragmented")
    local pong = ws.encode(ws.PONG, "abc", "\1\2\3\4")
    local got = ws.decode(pong, 1)
    T.eq(got.opcode, ws.PONG)
    T.eq(got.payload, "abc")
    T.eq(got.fin, true)
  end)

  T.case("a reserved bit and an unknown opcode are protocol errors", function()
    -- rsv1 set, which is what a permessage-deflate frame looks like.
    local bad = string.char(0xC1, 0x03) .. "abc"
    local got, why, code = ws.decode(bad, 1)
    T.eq(got, nil)
    T.ok(why:find("reserved"))
    T.eq(code, 1002)

    local unknown = string.char(0x83, 0x03) .. "abc"
    local g2, w2, c2 = ws.decode(unknown, 1)
    T.eq(g2, nil)
    T.ok(w2:find("opcode"))
    T.eq(c2, 1002)
  end)

  T.case("a frame over 4 MiB is refused with 1009", function()
    -- A 64-bit length of 8 MiB, unmasked, as a server would send it.
    local header = string.char(0x81, 127, 0, 0, 0, 0, 0, 0x80, 0, 0)
    local got, why, code = ws.decode(header, 1)
    T.eq(got, nil)
    T.ok(why:find("4 MiB"))
    T.eq(code, 1009)
  end)

  T.case("close payloads carry a code and a reason", function()
    local payload = ws.close_payload(1009, "too big")
    local code, reason = ws.parse_close(payload)
    T.eq(code, 1009)
    T.eq(reason, "too big")
    -- §1.2's codes, and an empty close.
    for _, c in ipairs({ 1000, 1001, 1003, 1009, 4001 }) do
      T.eq(select(1, ws.parse_close(ws.close_payload(c, ""))), c)
    end
    T.eq(select(1, ws.parse_close("")), 1005, "an empty close is 'no status received'")
  end)

  T.section("ws.Conn — reassembly")

  local function server_frame(opcode, payload, fin)
    -- A server frame is unmasked (RFC 6455 §5.1).
    if fin == nil then fin = true end
    local b0 = opcode + (fin and 0x80 or 0)
    local n = #payload
    if n <= 125 then
      return string.char(b0, n) .. payload
    elseif n <= 0xFFFF then
      return string.char(b0, 126, math.floor(n / 256), n % 256) .. payload
    end
    local out = {}
    local v = n
    for i = 8, 1, -1 do out[i] = string.char(v % 256); v = math.floor(v / 256) end
    return string.char(b0, 127) .. table.concat(out) .. payload
  end

  T.case("a whole message arrives however the bytes are split", function()
    local text = '{"v":1,"id":null,"type":"run.log","payload":{}}'
    local bytes = server_frame(ws.TEXT, text)
    -- One byte at a time is the worst case a TCP stack can hand a client.
    local conn = ws.Conn.new()
    local got = nil
    for i = 1, #bytes do
      conn:feed(bytes:sub(i, i))
      got = got or conn:next()
    end
    T.ok(got ~= nil)
    T.eq(got.kind, "text")
    T.eq(got.payload, text)
  end)

  T.case("continuation frames reassemble, with a ping interleaved", function()
    local conn = ws.Conn.new()
    conn:feed(server_frame(ws.TEXT, "error[E0382]: ", false))
    T.eq(conn:next(), nil, "a fragment on its own is not a message")
    conn:feed(server_frame(ws.PING, "keepalive"))
    local ping = conn:next()
    T.eq(ping.kind, "ping", "a control frame may interleave a fragmented message")
    T.eq(ping.payload, "keepalive")
    conn:feed(server_frame(ws.CONTINUATION, "borrow of ", false))
    T.eq(conn:next(), nil)
    conn:feed(server_frame(ws.CONTINUATION, "moved value", true))
    local msg = conn:next()
    T.eq(msg.kind, "text")
    T.eq(msg.payload, "error[E0382]: borrow of moved value")
  end)

  T.case("several messages in one read all come out", function()
    local conn = ws.Conn.new()
    conn:feed(server_frame(ws.TEXT, "one") .. server_frame(ws.TEXT, "two")
      .. server_frame(ws.PING, "") .. server_frame(ws.TEXT, "three"))
    T.eq(conn:next().payload, "one")
    T.eq(conn:next().payload, "two")
    T.eq(conn:next().kind, "ping")
    T.eq(conn:next().payload, "three")
    T.eq(conn:next(), nil)
  end)

  T.case("a stray continuation and an interrupted message are protocol errors", function()
    local conn = ws.Conn.new()
    conn:feed(server_frame(ws.CONTINUATION, "orphan"))
    local msg, why, code = conn:next()
    T.eq(msg, nil)
    T.ok(why:find("continuation"))
    T.eq(code, 1002)

    local c2 = ws.Conn.new()
    c2:feed(server_frame(ws.TEXT, "start", false))
    c2:next()
    c2:feed(server_frame(ws.TEXT, "interrupt"))
    local m2, w2 = c2:next()
    T.eq(m2, nil)
    T.ok(w2:find("before the previous one finished"))
  end)

  T.case("a close frame ends the stream", function()
    local conn = ws.Conn.new()
    conn:feed(server_frame(ws.CLOSE, ws.close_payload(1001, "going away")))
    local msg = conn:next()
    T.eq(msg.kind, "close")
    T.eq(msg.code, 1001)
    T.eq(msg.reason, "going away")
    T.eq(conn.closed, true)
  end)

  T.case("a client frame this codec makes decodes with this codec", function()
    -- Loopback: encode masked, decode, unmask. A server does exactly this.
    local conn = ws.Conn.new({ rand = fixed_rand(3) })
    local frame = conn:encode(ws.TEXT, '{"v":1,"id":"c-1","type":"ping","payload":{}}')
    local got = ws.decode(frame, 1)
    T.eq(got.masked, true)
    T.eq(got.payload, '{"v":1,"id":"c-1","type":"ping","payload":{}}')
    -- Two frames from the same connection use different mask keys.
    local a = conn:encode(ws.TEXT, "same")
    local bfr = conn:encode(ws.TEXT, "same")
    T.ne(a, bfr, "each frame gets a fresh mask key")
  end)

  T.case("a 256 KiB run.log chunk survives the 64-bit path", function()
    local payload = string.rep("compiler output line\n", 13000)
    T.ok(#payload > 65536)
    local conn = ws.Conn.new()
    conn:feed(server_frame(ws.TEXT, payload))
    local msg = conn:next()
    T.eq(#msg.payload, #payload)
    T.eq(msg.payload, payload)
  end)
end
