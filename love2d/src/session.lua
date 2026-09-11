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
function M.new(opts)
  local self = setmetatable({
    client = opts.client,
    lib = opts.lib,
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

  local stored = Store.load_session()
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

function Session:on(name, fn)
  local list = self.listeners[name]
  if not list then list = {}; self.listeners[name] = list end
  list[#list + 1] = fn
end

function Session:fire(name, payload, env)
  for _, fn in ipairs(self.listeners[name] or {}) do
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
  Store.save_session(token, user, self.client.url)
end

function Session:forget_token(why)
  self.token = nil
  self.user = nil
  self.authed = false
  Store.clear_session()
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
