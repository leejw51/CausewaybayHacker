-- PROTOCOL §6's reconnection rules, and §8 points 7 and 9.
--
-- The half of the client that is hardest to demonstrate against a live
-- server, because it needs the connection to die at a moment of the test's
-- choosing. Over a fake transport that is one method call, so it is done
-- here rather than by unplugging anything.
--
-- §6's five rules, and where each is checked:
--
--   1. keep only the token in durable storage    — `store.lua` + the case
--                                                  below that greps what was
--                                                  written
--   2. reconnect with backoff                    — tests/test_client.lua
--   3. on connect, `auth.resume` with the token  — here
--   4. on `unauthorized`, back to the login screen — here
--   5. refetch the map for the screen the player is on — here, via the
--      `reconnected` event the map scene subscribes to

local T = require("tests.framework")
local fake = require("tests.fake")
local netclient = require("src.net.client")
local Session = require("src.session")
local json = require("src.json")

--- A `src/store.lua` that lives in a table, so none of this needs LÖVE.
local function memory_store()
  local held = nil
  return {
    written = {},
    load_session = function() return held end,
    save_session = function(token, user, server)
      held = { token = token, address = user and user.address, name = user and user.name,
               server = server }
      return true
    end,
    clear_session = function() held = nil end,
    peek = function() return held end,
  }
end

--- A session over a fake transport, connected and ready.
local function harness(opts)
  opts = opts or {}
  local clock = fake.clock()
  local servers = {}
  local store = opts.store or memory_store()
  if opts.token then
    store.save_session(opts.token, { address = "0x9858Ef", name = "mei" },
      "ws://127.0.0.1:5390/ws")
  end
  local client = netclient.new({
    url = "ws://127.0.0.1:5390/ws",
    transport = function()
      local s = fake.new(opts.fake)
      servers[#servers + 1] = s
      return s
    end,
    now = clock.now,
    rand = fake.rand(13),
    log = function() end,
  })
  local session = Session.new({ client = client, lib = nil, store = store,
    log = function() end })
  return {
    client = client, session = session, store = store,
    servers = servers, clock = clock,
    server = function() return servers[#servers] end,
  }
end

return function()
  T.section("session — §6.3: resume with the stored token on every connect")

  T.case("a stored token is spent on auth.resume the moment the socket opens", function()
    local h = harness({ token = "stored-token-aaaaaaaaaaaaaaaaaaaaaaaaaaa" })
    h.client:connect()
    h.client:update()
    local sent = h.server():sent("auth.resume")
    T.eq(#sent, 1, "exactly one auth.resume")
    T.eq(sent[1].payload.token, "stored-token-aaaaaaaaaaaaaaaaaaaaaaaaaaa")
    T.eq(h.session.authed, false, "not authenticated until the server says so")
  end)

  T.case("with no token, the client asks for a login rather than guessing", function()
    local h = harness()
    local asked = false
    h.session:on("need_login", function() asked = true end)
    h.client:connect()
    h.client:update()
    T.eq(#h.server():sent("auth.resume"), 0)
    T.ok(asked)
  end)

  T.section("session — §8.7: store the token that came back")

  T.case("the rotated token replaces the one that was sent", function()
    local h = harness({ token = "old-token" })
    h.client:connect(); h.client:update()
    local id = h.server():sent("auth.resume")[1].id
    -- §4.4: "The returned token may differ from the one sent — the server
    -- rotates on use. Store the returned one."
    h.server():reply(id, "auth.resume.ok", {
      token = "rotated-token",
      user = { address = "0x9858Ef", name = "mei", settings = {}, level = 1, xp = 0 },
    })
    h.client:update()
    T.eq(h.session.authed, true)
    T.eq(h.session.token, "rotated-token")
    T.eq(h.store.peek().token, "rotated-token", "and the rotated one is what went to disk")
    T.eq(h.session.user.name, "mei")
  end)

  T.case("only the token and a public identity are persisted", function()
    local h = harness({ token = "old-token" })
    h.client:connect(); h.client:update()
    h.server():reply(h.server():sent("auth.resume")[1].id, "auth.resume.ok", {
      token = "rotated-token",
      user = { address = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94", name = "mei" },
    })
    h.client:update()
    local record = h.store.peek()
    -- §6 rule 1 says "the token (and only the token)". The address and the
    -- display name are kept beside it deliberately: both are public by
    -- construction — the address is on the wire in both directions (§2.4) —
    -- and without them the login screen cannot say who it is resuming as.
    -- Nothing else is, and `src/store.lua` refuses a record that looks like
    -- key material.
    local keys = {}
    for k in pairs(record) do keys[#keys + 1] = k end
    table.sort(keys)
    T.same(keys, { "address", "name", "server", "token" })
    local text = json.encode(record)
    for _, forbidden in ipairs({ "mnemonic", "private", "seed", "abandon" }) do
      T.nope(text:find(forbidden, 1, true))
    end
  end)

  T.case("the secret detector knows a mnemonic from a session token", function()
    -- The regression that hung a login: `auth.resume` hands back a base64url
    -- token, and roughly one in several has twelve runs of letters and no `-`
    -- or `_`. The first version of this check called that a mnemonic,
    -- refused to store it, and raised — through the reply handler, so the
    -- login spinner never stopped. The detector now describes the actual
    -- thing: space-separated alphabetic words, twelve or more.
    local Store = require("src.store")
    local mnemonic =
      "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    T.eq(Store.looks_like_a_mnemonic(mnemonic), true)
    T.eq(Store.looks_like_a_mnemonic(
      "legal winner thank year wave sausage worth useful legal winner thank yellow"), true)

    for _, token in ipairs({
      "4cibqBtjjk-62gP823-B_pPSBlf1KUQbx2hN4Hd-8eI",
      "kR3aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkLmN",   -- no punctuation at all
      "aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcdefg",
      "0x9858EfFD232B4033E47d90003D41EC34EcaEda94",
      "ws://127.0.0.1:5390/ws",
      "hacker-9858Ef",
      "",
    }) do
      T.eq(Store.looks_like_a_mnemonic(token), false,
        ("%q must not read as a mnemonic"):format(token))
    end

    -- The record the client actually persists passes, and a record carrying
    -- a phrase does not.
    T.eq(Store.check_no_secrets({
      token = "kR3aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkLmN",
      address = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94",
      name = "mei",
      server = "ws://127.0.0.1:5390/ws",
    }), true)
    T.eq(Store.check_no_secrets({ token = "t", note = mnemonic }), nil)
    T.eq(Store.check_no_secrets({ mnemonic = "x" }), nil)
    T.eq(Store.check_no_secrets({ settings = { private_key = "0x00" } }), nil)
  end)

  T.case("a store that refuses to write does not take the session down", function()
    local refusing = {
      load_session = function() return nil end,
      clear_session = function() end,
      save_session = function() error("the disk is full", 0) end,
    }
    local h = harness({ store = refusing })
    h.client:connect(); h.client:update()
    -- No stored token, so this one logs in the long way round: fake the
    -- adopt directly, which is what the reply handler does.
    h.session:adopt("t1", { address = "0x9858Ef", name = "mei" })
    T.eq(h.session.authed, true, "the session is live even though nothing was written")
    T.eq(h.session.token, "t1")
  end)

  T.section("session — §8.9 / §6.5: a mid-session drop resumes and refetches")

  T.case("the map scene is told to refetch after a reconnect", function()
    local h = harness({ token = "t0" })
    local reconnects, auths = 0, 0
    h.session:on("reconnected", function() reconnects = reconnects + 1 end)
    h.session:on("auth", function(p) auths = auths + 1; T.eq(p.resumed, true) end)

    h.client:connect(); h.client:update()
    h.server():reply(h.server():sent("auth.resume")[1].id, "auth.resume.ok",
      { token = "t1", user = { address = "0x9858Ef", name = "mei" } })
    h.client:update()
    T.eq(h.session.authed, true)
    T.eq(reconnects, 1, "the first resume is a reconnect too — refetch then as well")

    -- The player is sitting on the map and the laptop sleeps.
    h.server():drop()
    h.client:update()
    T.eq(h.client.state, "closed")
    T.eq(h.session.authed, false, "the session is not authenticated over a dead socket")

    h.clock.set(h.client.retry_at)
    h.client:update()
    T.eq(h.client.state, "open", "reconnected")
    local resumes = h.server():sent("auth.resume")
    T.eq(#resumes, 1, "one resume on the new connection")
    T.eq(resumes[1].payload.token, "t1", "with the rotated token, not the original")

    h.server():reply(resumes[1].id, "auth.resume.ok",
      { token = "t2", user = { address = "0x9858Ef", name = "mei" } })
    h.client:update()
    T.eq(h.session.authed, true)
    T.eq(h.session.token, "t2")
    T.eq(h.store.peek().token, "t2")
    -- §6 rule 5: this is the event `src/scenes/map.lua` and `App:load` hang
    -- the refetch off. Without it the map keeps a version of the world that
    -- may have missed a `progress.update`.
    T.eq(reconnects, 2, "the scene is told to refetch after the reconnect")
    T.eq(auths, 2)
  end)

  T.case("three drops in a row each resume once", function()
    local h = harness({ token = "t0" })
    h.client:connect(); h.client:update()
    local token = "t0"
    for i = 1, 4 do
      local resumes = h.server():sent("auth.resume")
      T.eq(#resumes, 1, ("connection %d sends exactly one resume"):format(i))
      T.eq(resumes[1].payload.token, token)
      token = "t" .. i
      h.server():reply(resumes[1].id, "auth.resume.ok",
        { token = token, user = { address = "0x9858Ef", name = "mei" } })
      h.client:update()
      T.eq(h.session.token, token)
      if i < 4 then
        h.server():drop()
        h.client:update()
        h.clock.set(h.client.retry_at)
        h.client:update()
      end
    end
  end)

  T.section("session — §6.4: unauthorized drops to the login screen")

  T.case("an expired token is forgotten, not retried forever", function()
    local h = harness({ token = "expired" })
    local asked
    h.session:on("need_login", function(p) asked = p end)
    h.client:connect(); h.client:update()
    h.server():reply_err(h.server():sent("auth.resume")[1].id, "auth.resume",
      "unauthorized", "unknown token", {})
    h.client:update()
    T.eq(h.session.authed, false)
    T.eq(h.session.token, nil, "the dead token is dropped")
    T.eq(h.store.peek(), nil, "and removed from storage, so a restart does not retry it")
    T.ok(asked ~= nil, "the app is told to show the login screen")

    -- And the next connection does not send a resume at all.
    h.server():drop()
    h.client:update()
    h.clock.set(h.client.retry_at)
    h.client:update()
    T.eq(#h.server():sent("auth.resume"), 0)
  end)

  T.case("a non-auth error keeps the token and says why", function()
    local h = harness({ token = "good" })
    local message
    h.session:on("need_login", function(p) message = p.message end)
    h.client:connect(); h.client:update()
    h.server():reply_err(h.server():sent("auth.resume")[1].id, "auth.resume",
      "internal", "the database is on fire", { trace_id = "abc" })
    h.client:update()
    T.eq(h.session.token, "good", "a server fault is not a reason to forget a good token")
    T.ok(type(message) == "string" and #message > 0)
  end)

  T.section("session — §1.2 close 4001, and §4.21 server.bye")

  T.case("close 4001 revokes the session locally", function()
    local h = harness({ token = "t0" })
    h.client:connect(); h.client:update()
    h.server():reply(h.server():sent("auth.resume")[1].id, "auth.resume.ok",
      { token = "t1", user = { address = "0x9858Ef", name = "mei" } })
    h.client:update()
    T.eq(h.session.authed, true)

    h.server():close_frame(4001, "session revoked")
    h.client:update()
    T.eq(h.session.token, nil, "§1.2: re-authenticate from scratch")
    T.eq(h.store.peek(), nil)
  end)

  T.case("server.bye reason=revoked also clears the token", function()
    local h = harness({ token = "t0" })
    h.client:connect(); h.client:update()
    h.server():reply(h.server():sent("auth.resume")[1].id, "auth.resume.ok",
      { token = "t1", user = { address = "0x9858Ef", name = "mei" } })
    h.client:update()
    h.server():event("server.bye", { reason = "revoked" })
    h.client:update()
    T.eq(h.session.token, nil)
  end)

  T.case("server.bye reason=shutdown keeps the token and reconnects", function()
    local h = harness({ token = "t0" })
    h.client:connect(); h.client:update()
    h.server():reply(h.server():sent("auth.resume")[1].id, "auth.resume.ok",
      { token = "t1", user = { address = "0x9858Ef", name = "mei" } })
    h.client:update()
    h.server():event("server.bye", { reason = "shutdown" })
    h.server():close_frame(1001, "going away")
    h.client:update()
    T.eq(h.session.token, "t1", "a restart is not a revocation")
    T.ok(h.client.retry_at ~= nil, "and the client is already coming back")
    h.clock.set(h.client.retry_at)
    h.client:update()
    T.eq(h.client.state, "open")
    T.eq(h.server():sent("auth.resume")[1].payload.token, "t1")
  end)

  T.section("session — §8.5 once more, through the whole login path")

  T.case("login refuses politely when there is no key library", function()
    local h = harness()
    h.client:connect(); h.client:update()
    local ok, message
    h.session:login("abandon abandon abandon", 0, "mei", function(o, m) ok, message = o, m end)
    T.eq(ok, false)
    T.ok(message:find("make %-C love2d ffi") ~= nil,
      "the message names the command, because that is what a player can act on")
    -- And nothing went out on the wire.
    T.eq(#h.server():sent("auth.challenge"), 0)
    T.eq(#h.server():sent("auth.login"), 0)
  end)

  T.section("session — the key stays for the run, and only for its own account")
  T.case("the signer is handed out while it is the account signed in, and dropped when it is not", function()
    local h = harness({ token = "t0" })
    h.session.user = { address = "0xABC0" }
    T.eq(h.session:signer(), nil, "a session resumed from its token has no key")
    h.session.held_key = { secret = "abandon abandon abandon", index = 0, address = "0xabc0" }
    T.ok(h.session:signer() ~= nil, "same account, case aside: the key is offered")
    T.eq(h.session:signer().index, 0)
    h.session.user = { address = "0xDEF0" }
    T.eq(h.session:signer(), nil, "another account is signed in now: a stale key is worse than none")
    T.eq(h.session.held_key, nil, "and it was dropped, not just hidden")
  end)
  T.case("logout forgets the key with the token", function()
    local h = harness({ token = "t0" })
    h.session.user = { address = "0xABC0" }
    h.session.held_key = { secret = "abandon abandon abandon", index = 0, address = "0xABC0" }
    h.session:logout()
    T.eq(h.session.held_key, nil)
    T.eq(h.session.token, nil)
  end)
end
