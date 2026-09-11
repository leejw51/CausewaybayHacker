-- The application half of the protocol: authentication, the session token,
-- and what happens after a reconnect.
--
-- `src/net/client.lua` owns frames and correlation; this owns the parts of
-- PROTOCOL.md that are about *this game* — §3.1's ANONYMOUS→AUTHENTICATED
-- step, §4.2–§4.4's challenge/sign/login, and §6's five reconnection rules.
--
-- The one thing to read carefully is `login`. It is the only place in the
-- client where a secret exists, and it is written so that the secret's
-- lifetime is one call: the phrase goes into the FFI, a signature comes back,
-- and the local reference is dropped before the reply is even sent.

local Store = require("src.store")
local Wallet = require("src.wallet")
local errors = require("src.net.errors")
local json = require("src.json")

local M = {}

local Session = {}
Session.__index = Session

--- `opts`:
---   client    an `src/net/client.lua` instance
---   lib       the loaded FFI library, or nil
---   log       function(level, message)
---   store     durable storage; defaults to `src/store.lua`
---
--- `store` is injected for one reason: `src/store.lua` writes through
--- `love.filesystem`, and the reconnect-and-resume behaviour below is the
--- half of PROTOCOL §6 most worth testing with no window and no server. A
--- table with `load_session`, `save_session` and `clear_session` is the whole
--- interface.
function M.new(opts)
  local store = opts.store or Store
  local self = setmetatable({
    client = opts.client,
    lib = opts.lib,
    store = store,
    log = opts.log or function() end,
    user = nil,
    token = nil,
    authed = false,
    -- A resume is in flight; a second one would race it.
    resuming = false,
    -- Set while the app is on the login screen, so a failed resume does not
    -- bounce a player who is already typing.
    listeners = {},
    last_error = nil,
  }, Session)

  -- SPEC §1.1: the token is stored per server, so which server this session
  -- is for is part of the session's identity, not an afterthought.
  self.server = opts.client.url
  local stored = store.load_session(self.server)
  if stored then
    self.token = stored.token
    self.remembered = { address = stored.address, name = stored.name }
  end

  self.client:on_state(function(state, detail)
    if state == "open" then
      -- §6 rule 3: on connect, resume with the stored token.
      self:try_resume()
    elseif state == "closed" then
      self.authed = false
      self:fire("connection", { state = state, detail = detail })
      -- §1.2: 4001 means the session was revoked; the token is dead and
      -- reconnecting with it would only loop.
      if detail == "close:4001" then
        self:forget_token("the server revoked this session")
      end
    end
    self:fire("state", { state = state, detail = detail })
  end)

  self.client:on("server.bye", function(payload)
    self.log("info", "server.bye: " .. tostring(payload.reason))
    if payload.reason == "revoked" then
      self:forget_token("the server revoked this session")
    end
    self:fire("bye", payload)
  end)

  for _, event in ipairs({ "run.stage", "run.log", "progress.update", "award" }) do
    self.client:on(event, function(payload, env)
      self:fire(event, payload, env)
    end)
  end

  return self
end

-- ------------------------------------------------------------------- events

--- Subscribe. Returns a handle to pass to `off`.
---
--- Scenes come and go — the quest screen is entered once per attempt at a
--- node — so a subscription that could not be cancelled would pile up one
--- dead listener per visit, each still holding the scene it belonged to. The
--- handle is how `Scene:leave` takes its own listeners back off.
function Session:on(name, fn)
  local list = self.listeners[name]
  if not list then list = {}; self.listeners[name] = list end
  list[#list + 1] = fn
  return { name = name, fn = fn }
end

function Session:off(handle)
  if type(handle) ~= "table" then return end
  local list = self.listeners[handle.name]
  if not list then return end
  for i = #list, 1, -1 do
    if list[i] == handle.fn then table.remove(list, i) end
  end
end

--- Drop several at once, for a scene that took a handful.
function Session:off_all(handles)
  for _, handle in ipairs(handles or {}) do self:off(handle) end
end

function Session:fire(name, payload, env)
  -- Iterated over a copy: a listener that unsubscribes during dispatch (a
  -- scene switching in response to an event) must not shift the list out
  -- from under this loop.
  local list = self.listeners[name]
  if not list or #list == 0 then return end
  local snapshot = {}
  for i, fn in ipairs(list) do snapshot[i] = fn end
  for _, fn in ipairs(snapshot) do
    local ok, err = pcall(fn, payload, env)
    if not ok then self.log("error", ("listener %s: %s"):format(name, tostring(err))) end
  end
end

-- --------------------------------------------------------------------- auth

function Session:try_resume()
  if self.authed or self.resuming or not self.token then
    if not self.token then self:fire("need_login", {}) end
    return
  end
  self.resuming = true
  self.client:request("auth.resume", { token = self.token }, function(ok, payload)
    self.resuming = false
    if ok then
      -- §8 point 7: store the token that came *back*, not the one sent.
      self:adopt(payload.token, payload.user)
      self.log("info", "resumed as " .. tostring(self.user and self.user.name))
      self:fire("auth", { user = self.user, resumed = true })
      -- §6 rule 5: "Refetch `world.map` for the screen the player is on. Do
      -- not trust a map cached across a disconnect."
      self:fire("reconnected", { user = self.user })
      return
    end
    local why = errors.classify(payload.code)
    self.log("warn", "auth.resume failed: " .. tostring(payload.code))
    if payload.code == "unauthorized" then
      -- §6 rule 4: drop to the login screen and ask for the key again.
      self:forget_token("the stored session is no longer valid")
    else
      self.last_error = why.player
      self:fire("need_login", { message = why.player })
    end
  end)
end

function Session:adopt(token, user)
  self.token = token
  self.user = user
  self.authed = true
  self.last_error = nil
  -- Persistence is a convenience; the session is live either way. A store
  -- that cannot write (a full disk, a read-only home, a refusal from
  -- `check_no_secrets`) costs the player a re-login next launch and nothing
  -- now, so it is reported and stepped over rather than thrown.
  local ok, why = pcall(self.store.save_session, token, user, self.server or self.client.url)
  if not ok then
    self.log("error", "could not persist the session: " .. tostring(why))
  end
end

function Session:forget_token(why)
  self.token = nil
  self.user = nil
  self.authed = false
  self.store.clear_session(self.server or self.client.url)
  self.last_error = why
  self:fire("need_login", { message = why })
end

--- The whole of §4.2–§4.4, with the secret alive for as little as possible.
---
--- `secret` is a mnemonic or a `0x`-prefixed private key. `cb(ok, message)`.
---
--- Order matters here and is worth spelling out:
---
---   1. derive the address locally, so the challenge can be asked for;
---   2. ask for the challenge — the server hands back a `message`;
---   3. sign **that exact string** (§4.2: "Do not reconstruct it from the
---      parts"), and drop the secret in the same breath;
---   4. send only `{address, signature, name}`.
---
--- At no point is `secret` put in a payload, a log line or a file. The only
--- thing that leaves this function is 65 bytes of signature.
function Session:login(secret, index, name, cb)
  cb = cb or function() end
  if not self.lib then
    cb(false, "the key library is not loaded — " .. Wallet.BUILD_HINT)
    return
  end
  if self.client.state ~= "open" then
    cb(false, "not connected to " .. self.client.url)
    return
  end

  local holder = { secret = secret }

  local account, derive_err = Wallet.derive(self.lib, holder.secret, index or 0)
  if not account then
    Wallet.forget(holder, "secret")
    cb(false, derive_err or "could not derive an address")
    return
  end

  self.client:request("auth.challenge", { address = account.address }, function(ok, payload)
    if not ok then
      Wallet.forget(holder, "secret")
      cb(false, errors.classify(payload.code).player)
      return
    end

    -- The server's string, byte for byte. Nothing here rebuilds it.
    local message = payload.message
    if type(message) ~= "string" or message == "" then
      Wallet.forget(holder, "secret")
      cb(false, "the server's challenge had no message to sign")
      return
    end

    local signed, sign_err = Wallet.sign(self.lib, holder.secret, index or 0, message)
    -- The secret's job is done the instant a signature exists.
    Wallet.forget(holder, "secret")
    secret = nil

    if not signed then
      cb(false, sign_err or "could not sign the challenge")
      return
    end
    if signed.address:lower() ~= account.address:lower() then
      cb(false, "the signature does not match the derived address")
      return
    end

    local login_payload = {
      address = account.address,
      signature = signed.signature,
    }
    if name and name ~= "" then login_payload.name = name end

    self.client:request("auth.login", login_payload, function(ok2, payload2)
      if not ok2 then
        local why = errors.classify(payload2.code)
        self.last_error = why.player
        cb(false, why.player)
        return
      end
      self:adopt(payload2.token, payload2.user)
      self:fire("auth", { user = self.user, resumed = false })
      cb(true, nil)
    end)
  end)
end

--- Point the session at a different server.
---
--- SPEC §1.1: **the token is stored per server.** A token minted by one
--- server means nothing to another, so this does not carry the old one
--- across — it forgets the live session and picks up whatever token is
--- stored for the new address, which may be none. Switching away and back
--- therefore leaves the player signed in to both.
function Session:rebind(url)
  self.server = url
  self.user = nil
  self.authed = false
  self.resuming = false
  self.last_error = nil
  local stored = self.store.load_session(url)
  self.token = stored and stored.token or nil
  self.remembered = stored and { address = stored.address, name = stored.name } or nil
  self:fire("server", { url = url, have_token = self.token ~= nil })
end

--- Sign out: forget the token here and on disk. The server keeps the session
--- alive until it expires, which is fine — nothing on this machine can use it.
function Session:logout()
  self:forget_token(nil)
end

-- ----------------------------------------------------------------- requests

--- A request that carries an error already classified, so no scene has to
--- remember §3.3's table.
---
--- `cb(ok, payload, classified)`.
function Session:request(type_name, payload, cb)
  return self.client:request(type_name, payload, function(ok, reply, env)
    if cb then
      cb(ok, reply, (not ok) and errors.classify(reply.code) or nil, env)
    end
  end)
end

function Session:display_name()
  if self.user and self.user.name then return self.user.name end
  if self.remembered and self.remembered.name then return self.remembered.name end
  return "hacker"
end

function Session:address()
  if self.user then return self.user.address end
  if self.remembered then return self.remembered.address end
  return nil
end

--- A short address for a status line: `0x9858…da94`.
function Session:short_address()
  local a = self:address()
  if not a then return "" end
  if #a < 12 then return a end
  return a:sub(1, 6) .. "…" .. a:sub(-4)
end

M.Session = Session
M.null = json.null

return M
