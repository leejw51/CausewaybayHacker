-- The faces and the paths, checked the way CI's Linux runner will meet them.
--
-- Headless on purpose. Every case here is about a file on disk, a table in
-- `src/assets.lua` or the web's `frontend/src/engine/text.ts`, and none of
-- that needs a window — so it fails in the fast job, not only under Xvfb.
--
--   * **Every face shipped carries its licence**, named in `CREDITS.txt`.
--   * **Every path the client names exists with exactly that case.** macOS
--     opens `assets/fonts/prnumber3.ttf` happily; Ubuntu does not. `io.open`
--     cannot tell the two apart on a Mac, so the check compares against a
--     directory listing, which can.
--   * **The face tables are the web's.** Parsed out of `text.ts`, so a size
--     re-tuned on one side and not the other fails here.
--   * **The interface face is remembered** through the store file, not only
--     through `replay`.
--   * **F8 belongs to the quest screen's log first**, and to the face only
--     where a scene does not take it.

local T = require("tests.framework")

--- The repository root: `CWBH_VECTORS` is `<repo>/tests/vectors` under both
--- `make test` and `make test-headless`; `..` from `love2d/` otherwise.
local function repo_root()
  local vectors = os.getenv("CWBH_VECTORS")
  if vectors and vectors:match("/tests/vectors/?$") then
    return (vectors:gsub("/tests/vectors/?$", ""))
  end
  return ".."
end

local function slurp(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local body = fh:read("*a")
  fh:close()
  return body
end

--- Every file under `dir` (relative to the cwd), by its exact name. A set.
local function listing(dir)
  local set = {}
  local p = io.popen(("find %q -type f 2>/dev/null"):format(dir))
  if not p then return set end
  for line in p:lines() do set[(line:gsub("^%./", ""))] = true end
  p:close()
  return set
end

--- `name: value` pairs from the `{ … }` that follows `const <name>` in a TS
--- source, comments stripped.
local function ts_object(src, name)
  local body = src:match("const " .. name .. "[^=]*=%s*(%b{})")
  if not body then return nil end
  return (body:gsub("//[^\n]*", ""))
end

local function ts_array(src, name)
  local body = src:match("const " .. name .. "%s*=%s*(%b[])")
  if not body then return nil end
  local out = {}
  for item in body:gmatch('"([^"]+)"') do out[#out + 1] = item end
  return out
end

return function()
  local Assets = require("src.assets")
  local root = repo_root()
  local files = listing(".")

  T.section("faces — every one shipped, with its licence")

  T.case("every face file is credited, beside a licence that is in the folder", function()
    local credits = slurp("assets/fonts/CREDITS.txt")
    T.ok(credits ~= nil, "assets/fonts/CREDITS.txt is there")
    if not credits then return end
    local lines = {}
    for line in (credits .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    local faces = 0
    for path in pairs(files) do
      local face = path:match("^assets/fonts/([^/]+%.[ot]tf)$")
      if face then
        faces = faces + 1
        -- Its entry starts a line with its name. The introduction has a
        -- sentence that does too, so every such line is tried, and the
        -- entry is the one with a licence: the first `.txt` from that line
        -- on, a few lines down at most and before a blank one.
        local at, licence
        for i, line in ipairs(lines) do
          if not licence and (line:find(face .. " ", 1, true) == 1 or line == face) then
            at = at or i
            for j = i, math.min(#lines, i + 4) do
              if lines[j]:match("^%s*$") then break end
              licence = lines[j]:match("([%w%-_%.]+%.txt)")
              if licence then break end
            end
          end
        end
        T.ok(at ~= nil, face .. " has a line of its own in CREDITS.txt")
        T.ok(licence ~= nil, face .. " names its licence in CREDITS.txt")
        if licence then
          T.ok(files["assets/fonts/" .. licence],
            ("%s's licence %s is shipped beside it, spelt exactly so"):format(face, licence))
        end
      end
    end
    T.ok(faces >= 15, faces .. " faces in assets/fonts")
  end)

  T.case("every face the client asks for is a file, spelt with its case", function()
    -- `CODE_FILE` is local to `src/assets.lua`, so read the literals rather
    -- than fish for the table: every "assets/…" string in the source.
    local named = 0
    for path in pairs(files) do
      if path:match("^src/.*%.lua$") or path == "main.lua" or path == "conf.lua" then
        local body = slurp(path) or ""
        for ref in body:gmatch('"(assets/[^"]+%.%w+)"') do
          named = named + 1
          T.ok(files[ref], ("%s names %s, which is not on disk with that case"):format(path, ref))
        end
      end
    end
    T.ok(named >= 15, named .. " asset paths named in the source")
    for _, face in ipairs(Assets.UI_FACES) do
      local file = Assets.UI_FACE_SPEC[face].file
      if file then T.ok(files[file], face .. ": " .. file) end
    end
  end)

  T.case("every module required is a file, spelt with its case", function()
    local seen = 0
    for path in pairs(files) do
      if (path:match("^src/.*%.lua$") or path:match("^tests/[^/]*%.lua$")
          or path == "main.lua") then
        local body = slurp(path) or ""
        for mod in body:gmatch('require%s*%(?%s*"([%w_%.]+)"') do
          -- `"src.lang." .. code` is a prefix, not a module.
          if (mod:match("^src%.") or mod:match("^tests%.")) and not mod:match("%.$") then
            seen = seen + 1
            local file = mod:gsub("%.", "/")
            T.ok(files[file .. ".lua"] or files[file .. "/init.lua"],
              ("%s requires %s, and no file has that exact name"):format(path, mod))
          end
        end
      end
    end
    T.ok(seen > 100, seen .. " requires checked")
  end)

  T.case("every painting the manifest names is in art/, spelt with its case", function()
    local manifest = slurp(root .. "/art/manifest.json")
    if not manifest then
      T.skip("art manifest", "no " .. root .. "/art/manifest.json from here")
      return
    end
    local art = listing(root .. "/art")
    local prefix = root .. "/art/"
    local n = 0
    for file in manifest:gmatch('"file"%s*:%s*"([^"]+)"') do
      n = n + 1
      T.ok(art[prefix .. file], "art/" .. file .. " is on disk with that case")
    end
    T.ok(n > 30, n .. " paintings in the manifest")
    -- The bundle the server serves carries the same manifest, and so the
    -- same paintings, as the checkout `make art` synced it from.
    local public = slurp(root .. "/frontend/public/art/manifest.json")
    if public then
      T.ok(public == manifest, "frontend/public/art/manifest.json is art/manifest.json")
      local pub = listing(root .. "/frontend/public/art")
      for file in manifest:gmatch('"file"%s*:%s*"([^"]+)"') do
        T.ok(pub[root .. "/frontend/public/art/" .. file], "frontend/public/art/" .. file)
      end
    end
  end)

  T.section("faces — the web's tables, number for number")

  local text_ts = slurp(root .. "/frontend/src/engine/text.ts")

  T.case("the code faces: order, sizes, names and weights", function()
    if not text_ts then
      T.skip("text.ts", "no frontend checkout beside this one")
      return
    end
    local order = ts_array(text_ts, "CODE_FACES")
    T.ok(order and #order > 0, "CODE_FACES parsed out of text.ts")
    T.same(Assets.CODE_FACES, order or {}, "the cycle order is the web's")

    local scale = ts_object(text_ts, "CODE_FACE_SCALE")
    T.ok(scale ~= nil, "CODE_FACE_SCALE parsed out of text.ts")
    local web = {}
    for face, n in (scale or ""):gmatch("([%w_]+)%s*:%s*([%d%.]+)") do web[face] = tonumber(n) end
    for _, face in ipairs(order or {}) do
      T.eq(Assets.CODE_FACE_SCALE[face], web[face],
        ("CODE_FACE_SCALE.%s: the web says %s"):format(face, tostring(web[face])))
    end

    local names = {}
    for face, name in (ts_object(text_ts, "CODE_FACE_NAME") or ""):gmatch('([%w_]+)%s*:%s*"([^"]*)"') do
      names[face] = name
    end
    local weights = {}
    for face, w in (ts_object(text_ts, "CODE_FACE_WEIGHT") or ""):gmatch('([%w_]+)%s*:%s*"([^"]*)"') do
      weights[face] = w
    end
    for _, face in ipairs(order or {}) do
      T.eq(Assets.CODE_FACE_NAME[face], names[face], face .. "'s name on the button")
      T.eq(Assets.CODE_FACE_WEIGHT[face], weights[face], face .. "'s weight")
    end
  end)

  T.case("the interface faces: order, measured multiples and names", function()
    if not text_ts then
      T.skip("text.ts", "no frontend checkout beside this one")
      return
    end
    local order = ts_array(text_ts, "UI_FACES")
    T.same(Assets.UI_FACES, order or {}, "F8's order is the web's")
    local spec = ts_object(text_ts, "UI_FACE_SPEC") or ""
    local seen = 0
    for face, body in spec:gmatch("([%w_]+)%s*:%s*(%b{})") do
      seen = seen + 1
      local mine = Assets.UI_FACE_SPEC[face]
      T.ok(mine ~= nil, face .. " is an interface face here too")
      if mine then
        T.eq(mine.pixel, tonumber(body:match("pixel%s*:%s*([%d%.]+)")), face .. ".pixel")
        T.eq(mine.body, tonumber(body:match("body%s*:%s*([%d%.]+)")), face .. ".body")
      end
    end
    T.eq(seen, #Assets.UI_FACES, "every web face was compared")
    for face, name in (ts_object(text_ts, "UI_FACE_NAME") or ""):gmatch('([%w_]+)%s*:%s*"([^"]*)"') do
      T.eq(Assets.UI_FACE_NAME[face], name, face .. "'s name in the toast")
    end
  end)

  T.section("faces — the two cycles")

  T.case("each cycle visits every face once and comes back where it started", function()
    local code, ui = Assets.codeFace(), Assets.uiFace()
    for _, cycle in ipairs({
      { list = Assets.CODE_FACES, set = Assets.setCodeFace, step = Assets.cycleCodeFace },
      { list = Assets.UI_FACES, set = Assets.setUiFace, step = Assets.cycleUiFace },
    }) do
      cycle.set(cycle.list[1])
      local seen = {}
      for i = 1, #cycle.list do
        local face = cycle.step()
        T.nope(seen[face], face .. " came round twice before the rest")
        seen[face] = true
        T.eq(face, cycle.list[i % #cycle.list + 1])
      end
    end
    Assets.setCodeFace(code)
    Assets.setUiFace(ui)
    T.eq(Assets.codeFace(), code)
    T.eq(Assets.uiFace(), ui)
  end)

  T.section("faces — the interface face, across a relaunch")

  T.case("uiface.set is written, read back, and does not move the code face", function()
    local Store = require("src.store")
    local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")
    local dir = ("%s/cwbh-faces-%d-%d"):format(base, os.time(), math.random(1, 1e6))
    os.execute(("mkdir -p %q"):format(dir))
    Store.reset()
    Store.open({ dir = dir })
    T.eq(Store.saved_ui_face(), nil, "a fresh store has no opinion")
    Store.set_face("victor")
    Store.set_ui_face("dos")
    Store.set_ui_face("galmuri")
    T.eq(Store.saved_ui_face(), "galmuri", "folded as it is written")
    Store.reset()
    Store.open({ dir = dir })
    T.eq(Store.saved_ui_face(), "galmuri", "the last choice, after a relaunch")
    T.eq(Store.saved_face(), "victor", "and the code face is its own record")
    -- What the file holds is the record the replay reads: kind and face.
    local body = slurp(dir .. "/" .. Store.FILE) or ""
    T.ok(body:find('"uiface.set"', 1, true), "the record is on disk under its own kind")
    Store.reset()
    os.remove(dir .. "/" .. Store.FILE)
    os.execute(("rmdir %q 2>/dev/null"):format(dir))
  end)

  T.section("faces — F8, after the scene")

  T.case("the quest screen keeps F8 for its log; elsewhere F8 is the face", function()
    local App = require("src.app")
    local Quest = require("src.scenes.quest")
    local was = App.mods_override
    App.mods_override = {}
    local cycled = 0
    local function app_with(scene)
      return setmetatable({ scene = scene, back = function() end,
        cycle_ui_face = function() cycled = cycled + 1 end }, { __index = App })
    end

    local quest = setmetatable({}, { __index = Quest })
    App.keypressed(app_with(quest), "f8")
    T.eq(cycled, 0, "the quest screen took F8")
    T.eq(quest.show_log, true, "and opened its log with it")
    App.keypressed(app_with(quest), "f8")
    T.eq(quest.show_log, false, "and closed it again")

    -- A quiz quest has no log; F8 is refused there, and still not passed on.
    local quiz = setmetatable({ quest = { quiz = { choices = {}, answer = 0 } } },
      { __index = Quest })
    App.keypressed(app_with(quiz), "f8")
    T.eq(cycled, 0, "a quiz quest swallows F8 rather than change the face")

    App.keypressed(app_with({ keypressed = function() return false end }), "f8")
    T.eq(cycled, 1, "a scene that does not want F8 lets it through")
    App.keypressed(app_with({}), "f8")
    T.eq(cycled, 2, "and so does a scene with no keys at all")
    App.keypressed(app_with({ keypressed = function() return false end }), "f7")
    T.eq(cycled, 2, "only F8")
    App.mods_override = was
  end)
end
