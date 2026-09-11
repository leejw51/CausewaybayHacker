-- The LuaJIT binding to `libcwbh_ffi` — the only place this client touches a
-- key.
--
-- The idiom is CausewaybayWallet's `luacli/causewaybay/ffi.lua`: a named
-- search rather than a bare library name, an ABI check before any other call,
-- and exactly one place that takes ownership of a returned `char *` and frees
-- it. Read that file beside this one; the reasoning for the search order is
-- written out there and applies here unchanged.
--
-- What is different: this is **not** that library. `cwbh_` is a different
-- prefix and ABI 1 is a different contract, so a stale
-- `libcausewaybay_ffi.dylib` on the machine cannot answer for it.
--
-- ## The rule this file exists to keep
--
-- SPEC §3.1 and PROTOCOL §4.3: the mnemonic and the private key never cross
-- the websocket, are never logged and are never written to disk. So:
--
--   * the phrase goes in one direction only, into `cwbh_execute`;
--   * nothing that comes back is key material — the ABI has no operation that
--     returns one, and `describe()` says so in `never_returns`;
--   * `M.forget()` drops the Lua-side copy the login screen was holding, and
--     the login scene calls it the moment a signature exists.
--
-- There is no `love.` in this file: a `root` is passed in (the game passes
-- `love.filesystem.getSource()`), so the headless suite can load the same
-- library from a checkout.

local json = require("src.json")

local M = {}

--- The ABI this binding was written against. A library reporting anything
--- else is refused rather than guessed at.
M.ABI_VERSION = 1

-- Kept byte-identical to love2d/ffi/include/cwbh.h.
M.CDEF = [[
int   cwbh_abi_version(void);
char *cwbh_version(void);
char *cwbh_describe(void);
char *cwbh_execute(const char *request_json);
void  cwbh_string_free(char *s);
]]

M.BUILD_HINT = "run `make -C love2d ffi`"

local ffi_ok, ffi = pcall(require, "ffi")
local cdef_done = false

function M.library_name(os_name)
  os_name = os_name or (ffi_ok and ffi.os) or "OSX"
  if os_name == "Windows" then return "cwbh_ffi.dll" end
  if os_name == "OSX" then return "libcwbh_ffi.dylib" end
  return "libcwbh_ffi.so"
end

--- Collapse `a/b/../c` textually. Not `realpath`: it exists so the "could not
--- find it" message names directories a person can read.
function M.normalize(path)
  local absolute = path:sub(1, 1) == "/"
  local parts = {}
  for segment in path:gmatch("[^/]+") do
    if segment == ".." and #parts > 0 and parts[#parts] ~= ".." then
      parts[#parts] = nil
    elseif segment ~= "." then
      parts[#parts + 1] = segment
    end
  end
  return (absolute and "/" or "") .. table.concat(parts, "/")
end

local function system_library_dirs(os_name)
  if os_name == "Windows" then return {} end
  if os_name == "OSX" then return { "/usr/local/lib", "/opt/homebrew/lib" } end
  return { "/usr/local/lib", "/usr/lib" }
end

--- Where to look, in order. A pure function, so a test can ask what the order
--- *is* without the environment it happens to run in changing the answer.
---
--- Never a bare name: `dlopen` on macOS and `LoadLibrary` on Windows both
--- search the working directory for a name with no slash in it, and this
--- library is handed a mnemonic on every login.
function M.search_paths(root, override, os_name)
  os_name = os_name or (ffi_ok and ffi.os) or "OSX"
  local name = M.library_name(os_name)
  local paths = {}
  if override and override ~= "" then paths[#paths + 1] = override end
  -- A packaged copy sits beside the game, so a bundle that was moved still
  -- finds its own library and not a stale build.
  paths[#paths + 1] = M.normalize(root .. "/" .. name)
  paths[#paths + 1] = M.normalize(root .. "/ffi/target/release/" .. name)
  paths[#paths + 1] = M.normalize(root .. "/ffi/target/debug/" .. name)
  paths[#paths + 1] = M.normalize(root .. "/../ffi/target/release/" .. name)
  paths[#paths + 1] = M.normalize(root .. "/../ffi/target/debug/" .. name)
  for _, dir in ipairs(system_library_dirs(os_name)) do
    paths[#paths + 1] = dir .. "/" .. name
  end
  return paths
end

local loaded = nil
local load_error = nil

--- The directory holding this module, used when no `root` is given.
local function module_root()
  local source = debug.getinfo(1, "S").source
  local path = source:match("^@(.*)/[^/]*$")
  if not path then return "." end
  return M.normalize(path .. "/..")
end

--- Load the library once. Returns the FFI namespace, or `nil, message`.
---
--- The message lists everywhere it looked, because a missing library is by
--- far the most likely thing to go wrong here and the login screen renders
--- this string verbatim.
function M.load(root, explicit)
  if loaded and not explicit then return loaded end
  if not ffi_ok then
    load_error = "this Lua has no `ffi` module. The LÖVE client needs LuaJIT,"
      .. " which LÖVE 11.5 ships with."
    return nil, load_error
  end
  if not cdef_done then
    local ok, err = pcall(ffi.cdef, M.CDEF)
    if not ok then
      load_error = "could not declare the C ABI: " .. tostring(err)
      return nil, load_error
    end
    cdef_done = true
  end

  local paths = explicit and { explicit }
    or M.search_paths(root or module_root(), os.getenv("CWBH_FFI_LIB"))
  local tried = {}
  for _, path in ipairs(paths) do
    local ok, lib = pcall(ffi.load, path)
    if ok then
      local reported = lib.cwbh_abi_version()
      if reported ~= M.ABI_VERSION then
        load_error = ("%s speaks ABI %d, this binding expects %d — rebuild both with `%s`")
          :format(path, tonumber(reported), M.ABI_VERSION, M.BUILD_HINT)
        return nil, load_error
      end
      if not explicit then
        loaded = lib
        load_error = nil
      end
      return lib
    end
    tried[#tried + 1] = "  " .. path
  end

  load_error = ("cannot find %s.\n%s, or set CWBH_FFI_LIB.\nLooked in:\n%s")
    :format(M.library_name(), M.BUILD_HINT, table.concat(tried, "\n"))
  return nil, load_error
end

--- The last load failure, for a screen that wants to explain itself.
function M.last_error()
  return load_error
end

function M.available()
  return loaded ~= nil
end

--- Take ownership of a `char *` and free it. The copy happens before the
--- free, and this is the only place either happens.
local function take(lib, pointer)
  if pointer == nil then return nil end
  local text = ffi.string(pointer)
  lib.cwbh_string_free(pointer)
  return text
end

--- Run one request. Returns the decoded envelope, or nil, message.
function M.execute(lib, request)
  if not lib then return nil, load_error or "the key library is not loaded" end
  local text = take(lib, lib.cwbh_execute(json.encode(request)))
  if not text then return nil, "the library returned nothing" end
  local value, err = json.try_decode(text)
  if not value then return nil, "the library returned malformed JSON: " .. tostring(err) end
  if value.ok == false then return nil, value.error or "the library refused the request" end
  return value
end

function M.describe(lib)
  return M.execute(lib, { op = "describe" })
end

--- Is this a well-formed mnemonic? Cheap, and the login screen calls it on
--- every keystroke so it can stop saying "checking" before the user is done.
function M.validate(lib, phrase)
  local out, err = M.execute(lib, { op = "validate", mnemonic = phrase })
  if not out then return false, err end
  return out.valid == true, out.reason
end

--- SPEC §3.1: derive the account at `m/44'/60'/0'/0/index`.
---
--- `secret` is either a mnemonic or a `0x`-prefixed private key; which one is
--- decided here by shape, so no caller has to.
function M.derive(lib, secret, index)
  local req = { op = "derive", index = index or 0 }
  if M.looks_like_private_key(secret) then
    req.private_key = secret
  else
    req.mnemonic = secret
  end
  return M.execute(lib, req)
end

--- PROTOCOL §4.3: sign the EIP-191 digest of `message`.
---
--- `message` is the server's string **verbatim**. Nothing here rebuilds it
--- from its parts; §4.2 is explicit that a client which does will disagree
--- with the server about a space and fail every login.
function M.sign(lib, secret, index, message)
  local req = { op = "sign", index = index or 0, message = message }
  if M.looks_like_private_key(secret) then
    req.private_key = secret
  else
    req.mnemonic = secret
  end
  return M.execute(lib, req)
end

--- The digest on its own, for a test that wants to bisect a bad signature.
function M.eip191(lib, message)
  return M.execute(lib, { op = "eip191", message = message })
end

--- SPEC §3.1: "A raw private key (`0x` + 64 hex) is accepted as an
--- alternative to a mnemonic."
---
--- Lua patterns have no `{n}` repetition, so the length is checked directly
--- rather than with a repetition count that silently never matches.
function M.looks_like_private_key(text)
  if type(text) ~= "string" then return false end
  local trimmed = (text:gsub("%s", ""))
  local body = trimmed:match("^0[xX](.*)$") or trimmed
  return #body == 64 and body:match("^%x+$") ~= nil
end

--- Drop a Lua-side copy of a secret.
---
--- Lua strings are interned and immutable, so this cannot scrub the bytes the
--- way `Zeroizing` does on the Rust side — what it can do is make sure the
--- login screen stops holding a reference the moment the signature exists,
--- which is the difference between a secret that lives for one frame and one
--- that lives until the process exits.
function M.forget(holder, field)
  if type(holder) == "table" and field then
    holder[field] = nil
  end
  collectgarbage("step")
end

return M
