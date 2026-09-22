-- What the agent says when nobody has asked it anything.
--
-- None of this touches a model (docs/agent.md §1). Two kinds of sentence:
--
--   * **tips** — one line per language about the language, said in idle
--     time, never the same one twice running;
--   * **advice** — `advise()` reads the text for the handful of things a
--     reviewer would circle on sight (`unwrap()` everywhere, an `err` nobody
--     checked, `using namespace std`, a bare `except:`) and says one sentence
--     about each. Every finding has a stable `id`, so the controller can say
--     each once per pad and not nag.
--
-- This is the LÖVE port of `frontend/src/ai/tips.ts`, and the wording is kept
-- identical on purpose: the catalogue is the agent's own voice, and a coder
-- that says one thing in the browser and another on the desktop is two
-- different characters wearing the same face. So every tip, every finding
-- sentence and every `id` here is word-for-word the web's, and the heuristics
-- fire on exactly the same text — this file was diffed against the compiled
-- TypeScript, tip for tip and finding for finding, rather than read across.
-- The sentences are English on purpose for now: translating seventy lines of
-- Rust folklore is a job for a translator, not a build.
--
-- Nothing in this file touches `love.` and it requires nothing: it is pure
-- string work, so the headless suite can run it under plain LuaJIT.

local M = {}

M.TIPS = {
  rust = {
    "`?` is a return in disguise: it hands the error up and gets on with it.",
    "Borrow (`&T`) when you only need to look; take ownership when you need to keep.",
    "`match` must cover every case — the compiler is doing the exhaustiveness for you.",
    "`String` owns; `&str` borrows. Take `&str` in parameters and give `String` back.",
    "`Option` is a checked null: `if let Some(x) = it { … }` and no surprise at runtime.",
    "`clone()` in a loop is a copy per turn. Ask whether a `&` would do.",
    "Iterators are lazy: `.map(…).filter(…)` does nothing until `.collect()` or a `for`.",
    "`impl Trait for Type` is the whole plugin system. No base class, no override.",
    "`Vec<T>` grows on the heap; `[T; N]` is on the stack and its size is in the type.",
    "Shadowing is normal: `let x = x.trim();` is a new `x`, not a mutation.",
    "`#[derive(Debug)]` and `{:?}` are the fastest way to see what a thing is.",
    "Lifetimes describe what is already true; they never make a reference live longer.",
    "`Rc<RefCell<T>>` is shared ownership with borrow checks at runtime. Reach for it last.",
    "`cargo clippy` is the second reviewer. Its lints are in the compiler's own voice.",
    "`Result<T, Box<dyn Error>>` from `main` lets `?` end the program with the message.",
  },
  go = {
    "`if err != nil { return err }` is the whole error system. "
      .. "Wrap with `fmt.Errorf(\"…: %w\", err)`.",
    "A slice is a window on an array: `append` may or may not give you a new one.",
    "Goroutines are cheap; unsynchronised shared memory is not. Share by communicating.",
    "`defer` runs at return, in reverse order. Close the file on the line after you open it.",
    "An interface is satisfied by having the methods. No `implements`, ever.",
    "`range` over a map is in random order on purpose. Sort the keys if it matters.",
    "A nil slice is fine to `range` and `append` to. A nil map is not fine to write to.",
    "`select` with a `default` is a non-blocking receive. Without one it waits.",
    "`context.Context` is the first parameter, and cancelling it is how work stops.",
    "`go vet` and `gofmt` are not optional; the language assumes they ran.",
    "Zero values are useful: an unset `sync.Mutex`, an empty `bytes.Buffer`, all ready.",
    "`strings.Builder` beats `+=` in a loop; the latter copies the whole string each time.",
  },
  cpp = {
    "`std::vector` first. An array with `new[]` is a leak waiting for an early return.",
    "RAII: the destructor is the cleanup. If you wrote `delete`, ask who owns the thing.",
    "`const &` to read a big object; by value for things you would copy anyway.",
    "`auto` for iterators and lambdas; the type is still there, you are just not typing it.",
    "`std::unique_ptr` is free at runtime and says who owns it in the type.",
    "`using namespace std;` in a header pollutes everyone who includes it.",
    "`std::string_view` looks at a string without owning it — mind who does.",
    "Initialise in the constructor's initialiser list, not in its body.",
    "`-Wall -Wextra` on. The warnings are the bugs you have not met yet.",
    "Range `for (const auto& x : xs)` and you cannot get the index wrong.",
    "A `std::map` is sorted; `std::unordered_map` is faster and unsorted. Pick on purpose.",
    "`std::move` does not move anything. It permits the callee to.",
  },
  python = {
    "A mutable default argument (`def f(xs=[])`) is shared by every call. Use `None`.",
    "`with open(…) as f:` closes the file for you, even on an exception.",
    "A list comprehension says what you want; a `for` with `append` says how.",
    "`except Exception as e:` — a bare `except:` also catches Ctrl-C.",
    "Dictionaries keep insertion order. `dict.get(k, default)` never raises.",
    "`enumerate(xs)` when you need the index; `zip(a, b)` when you need pairs.",
    "f-strings: `f\"{x=}\"` prints the name and the value. Debugging in one token.",
    "`is` compares identity, `==` compares value. `is None` is the one place for `is`.",
    "Generators (`yield`) produce one at a time; a million lines cost one line of memory.",
    "Type hints do not check anything at runtime — `mypy` does, and it is worth running.",
    "`sorted(xs, key=…)` returns a new list; `xs.sort()` sorts in place and returns `None`.",
    "`__name__ == \"__main__\"` is the line between a script and a module.",
  },
  pytorch = {
    "Shape first. Print `tuple(x.shape)` before you print anything else.",
    "`zero_grad`, `backward`, `step` — in that order. `backward` adds into `.grad`; it never clears it.",
    "`nn.CrossEntropyLoss` takes raw logits. Softmax it yourself and you have softmaxed twice.",
    "`model.eval()` for dropout and batch-norm; `torch.no_grad()` for the graph. You usually want both.",
    "`view` needs contiguous memory, `reshape` does not. After a `transpose`, reach for `reshape`.",
    "`detach()` leaves the graph and shares the memory; `clone()` copies and stays. Different tools.",
    "Keep `loss.item()`, not `loss`. Holding the tensor holds the whole graph behind it.",
    "`keepdim=True` on a reduction, or the axis vanishes and the broadcast lines up wrong.",
    "A trailing underscore is in-place: `add_`, `relu_`. Autograd notices one backward pass later.",
    "Mask before the softmax, with `-inf`. Zeroing after leaves a row summing to less than one.",
    "`torch.manual_seed` fixes one global stream; pass a `Generator` for a reproducible one.",
    "The scale in attention is the square root of the *head* dimension, not the model dimension.",
  },
}

--- The next tip after `last`, never the same one twice running.
---
--- Indices here are 1-based, because the only thing that ever consumes one is
--- Lua indexing `M.TIPS[lang]`; the web's version is 0-based for the same
--- reason on its side, and the number never crosses the wire, so the two are
--- free to disagree about where counting starts. The arithmetic is otherwise
--- the web's: pick from the `n - 1` tips that are not `last`, then step over
--- `last` if the pick landed on it or past it.
---
--- With no `last` yet — the first tip of a session — any of them will do, so
--- leaving it out says the same thing as "nothing has been said". `roll` is
--- injectable so the tests can pin a choice; left out, it rolls.
function M.next_tip(lang, last, roll)
  local n = #M.TIPS[lang]
  if n <= 1 then
    return 1
  end
  last = last or 0
  roll = roll or math.random()
  local i = math.floor(roll * (n - 1)) + 1
  if i >= last then
    i = i + 1
  end
  return math.min(n, math.max(1, i))
end

--- How many `unwrap()` are still a scratchpad, not a habit.
local UNWRAP_LIMIT = 3

-- ---------------------------------------------------------------------------
-- The bits of JavaScript regex that Lua patterns do not have.
--
-- The web's rules are written as regexes with `\b`, alternation and bounded
-- repeats, none of which exist in Lua patterns. Rather than approximate them
-- — an approximation would make the two clients disagree about the same file,
-- which is the one thing this port must not do — each awkward regex below is
-- rewritten as an explicit scan, and each carries a comment naming the regex
-- it stands in for.
-- ---------------------------------------------------------------------------

--- True when the byte at `i` is one of JavaScript's `\w`. Lua's `%w` has no
--- underscore in it, so every `\w` in the source becomes `[%w_]` here.
local function is_word(s, i)
  if i < 1 or i > #s then
    return false
  end
  return s:sub(i, i):match("[%w_]") ~= nil
end

--- Plain (non-pattern) occurrences of `needle`, counted the way `matchAll`
--- with a `/g` regex counts: left to right, no overlaps.
local function count_plain(s, needle)
  local n, i = 0, 1
  while true do
    local a, b = s:find(needle, i, true)
    if not a then
      return n
    end
    n = n + 1
    i = b + 1
  end
end

--- The same, for a Lua pattern.
local function count_pattern(s, pat)
  local n, i = 0, 1
  while true do
    local a, b = s:find(pat, i)
    if not a then
      return n
    end
    n = n + 1
    i = (b >= a) and (b + 1) or (a + 1)
  end
end

--- `needle` as a plain substring, optionally with a `\b` on either side. The
--- boundary is checked by looking at the neighbouring byte, which is what
--- `\b` means when the match itself starts and ends in word characters.
local function has_token(s, needle, before, after)
  local i = 1
  while true do
    local a, b = s:find(needle, i, true)
    if not a then
      return false
    end
    local ok = true
    if before and is_word(s, a - 1) then
      ok = false
    end
    if after and is_word(s, b + 1) then
      ok = false
    end
    if ok then
      return true
    end
    i = a + 1
  end
end

--- `String.prototype.split("\n")`: every segment, including the empty ones and
--- including whatever trails the last newline.
local function split_lines(s)
  local lines, start = {}, 1
  while true do
    local i = s:find("\n", start, true)
    if not i then
      lines[#lines + 1] = s:sub(start)
      return lines
    end
    lines[#lines + 1] = s:sub(start, i - 1)
    start = i + 1
  end
end

--- `raw.replace(/\/\/.*$/, "").replace(/#.*$/, "")` — everything from the
--- first `//` goes, then everything from the first remaining `#`. One pass of
--- each, exactly as the web does it, so a `#` inside a `//` comment is already
--- gone by the time the second cut looks for it. One deliberate difference: a
--- line ending in a bare CR defeats the web's regex entirely (`.` will not
--- cross a `\r`, so nothing is stripped at all) and does not defeat this. The
--- editor on either side writes `\n`, so the case is out of reach in practice,
--- and doing the plain thing beats copying an accident.
local function strip_comment(line)
  local i = line:find("//", 1, true)
  if i then
    line = line:sub(1, i - 1)
  end
  local j = line:find("#", 1, true)
  if j then
    line = line:sub(1, j - 1)
  end
  return line
end

--- `/^\s*(for|while|loop)\b/` — the identifier that opens the line, if any,
--- is one of the three loop words. Taking the whole identifier and comparing
--- it is how the trailing `\b` gets done: `for(` is a loop, `forever` is not.
local function is_loop_head(line)
  local word = line:match("^%s*([%a_][%w_]*)")
  return word == "for" or word == "while" or word == "loop"
end

--- Whether `needle` appears inside a `for`/`while`/`loop` block, roughly.
---
--- Roughly is the word: a `:` counts as an opening brace so that Python's
--- block syntax gets depth too, which means `std::endl`, `0..3` and `:=` all
--- push the depth up as well. That is the web's behaviour and it is kept —
--- the heuristic only has to be right often enough to be worth saying, and
--- two clients that guess differently would be worse than either guess.
local function inside_loop(source, needle)
  local depth, loop_depth = 0, -1
  for _, raw in ipairs(split_lines(source)) do
    local line = strip_comment(raw)
    local head = is_loop_head(line)
    if loop_depth < 0 and head then
      loop_depth = depth
    end
    if loop_depth >= 0 and line:find(needle, 1, true) and not head then
      return true
    end
    for k = 1, #line do
      local ch = line:sub(k, k)
      if ch == "{" or ch == ":" then
        depth = depth + 1
      elseif ch == "}" then
        depth = depth - 1
        if loop_depth >= 0 and depth <= loop_depth then
          loop_depth = -1
        end
      end
    end
  end
  return false
end

--- `/\.expect\("[^"]{0,3}"\)/` — an `expect` whose message is three characters
--- or fewer. Lua has no bounded repeat, so the four possible lengths are tried
--- by hand; the message may not contain a quote, which is what `[^"]` says.
local function has_short_expect(s)
  local i = 1
  while true do
    local a, b = s:find('.expect("', i, true)
    if not a then
      return false
    end
    for k = 0, 3 do
      local seg = s:sub(b + 1, b + k)
      if #seg == k and not seg:find('"', 1, true) and s:sub(b + k + 1, b + k + 2) == '")' then
        return true
      end
    end
    i = a + 1
  end
end

--- `/\berr\s*:?=/g` — an `err` being assigned or declared. Note that this also
--- counts `err == nil`, because the first `=` of `==` satisfies it; the web
--- counts it too, and a rule about how often `err` is checked would only get
--- stranger if the two clients counted different things.
local function count_err_assigned(s)
  local n, i = 0, 1
  while true do
    local a, b = s:find("err", i, true)
    if not a then
      return n
    end
    if not is_word(s, a - 1) and s:find("^%s*:?=", b + 1) then
      n = n + 1
    end
    i = a + 1
  end
end

--- `/\bif\s+err\s*!=\s*nil/g` — the check itself.
local function count_err_checked(s)
  local n, i = 0, 1
  while true do
    local a, b = s:find("if", i, true)
    if not a then
      return n
    end
    if not is_word(s, a - 1) and s:find("^%s+err%s*!=%s*nil", b + 1) then
      n = n + 1
    end
    i = a + 1
  end
end

--- The second half of `/\+=\s*"[^"]*"|\+=\s*\w+\s*$/m` — a `+=` whose
--- right-hand side is a bare identifier that finishes the line. Lua has no
--- alternation and no multiline `$`, so the tail is walked by hand: skip the
--- whitespace (which, like JavaScript's `\s`, may include newlines), require
--- at least one word character, then require that nothing but blanks stands
--- between there and the end of the line or the end of the text. A CR ends a
--- line here as well as a newline, because that is what JavaScript's `$` under
--- `/m` accepts.
local function has_plus_equals_to_eol(s)
  local i = 1
  while true do
    local a, b = s:find("+=", i, true)
    if not a then
      return false
    end
    local p = b + 1
    while p <= #s and s:sub(p, p):match("%s") do
      p = p + 1
    end
    local q = p
    while is_word(s, q) do
      q = q + 1
    end
    if q > p then
      local r = q
      while r <= #s and s:sub(r, r):match("[ \t\f\v]") do
        r = r + 1
      end
      local ch = s:sub(r, r)
      if r > #s or ch == "\n" or ch == "\r" then
        return true
      end
    end
    i = a + 1
  end
end

--- `/\bnew\s+\w+(\s*\[|\s*\()/` — a `new Thing[` or a `new Thing(`. The
--- alternation is two characters that differ, so a Lua character set does it.
local function has_raw_new(s)
  local i = 1
  while true do
    local a, b = s:find("new", i, true)
    if not a then
      return false
    end
    if not is_word(s, a - 1) and s:find("^%s+[%w_]+%s*[%[%(]", b + 1) then
      return true
    end
    i = a + 1
  end
end

--- `/\b(char|int|double)\s+\w+\s*\[\s*\d+\s*\]/` — a fixed C array. The
--- alternation becomes a loop over the three keywords.
local function has_c_array(s)
  local keywords = { "char", "int", "double" }
  for _, kw in ipairs(keywords) do
    local i = 1
    while true do
      local a, b = s:find(kw, i, true)
      if not a then
        break
      end
      if not is_word(s, a - 1) and s:find("^%s+[%w_]+%s*%[%s*%d+%s*%]", b + 1) then
        return true
      end
      i = a + 1
    end
  end
  return false
end

--- `/\(\s*(const\s+)?std::(string|vector)<?[^)]*>?\s+\w+\s*\)/` — a parameter
--- list holding a `std::string` or `std::vector` by value.
---
--- The `[^)]*` in the middle cannot cross a `)`, so the closing paren of the
--- match is always the first `)` after the type name; everything between the
--- two is the `<…>` and whatever decorates it, and all the regex asks of that
--- stretch is that it end in whitespace, an identifier and optional blanks.
--- The optional `const` is two starting points rather than a `?`, which is
--- what the regex's backtracking amounts to.
---
--- This fires on `const std::string& s` as well, because `& s` ends the same
--- way. The web has the same false positive and it stays: a shared heuristic
--- that is sometimes wrong beats two heuristics that are wrong differently.
local function has_container_by_value(s)
  local i = 1
  while true do
    local a = s:find("(", i, true)
    if not a then
      return false
    end
    local _, head = s:find("^%(%s*", a)
    local starts = { head + 1 }
    local _, after_const = s:find("^const%s+", head + 1)
    if after_const then
      starts[#starts + 1] = after_const + 1
    end
    for _, p in ipairs(starts) do
      local _, t = s:find("^std::string", p)
      if not t then
        _, t = s:find("^std::vector", p)
      end
      if t then
        local close = s:find(")", t + 1, true)
        if close and s:sub(t + 1, close - 1):find("%s+[%w_]+%s*$") then
          return true
        end
      end
    end
    i = a + 1
  end
end

--- `/def\s+\w+\([^)]*=\s*(\[\]|\{\})/` — a mutable default argument. Same
--- trick as above: `[^)]*` pins the region to the text before the first `)`,
--- and the alternation becomes two searches inside it. There is no `\b` on
--- the `def` in the web's regex, so there is none here either.
local function has_mutable_default(s)
  local i = 1
  while true do
    local a = s:find("def", i, true)
    if not a then
      return false
    end
    local _, open = s:find("^def%s+[%w_]+%(", a)
    if open then
      local close = s:find(")", open + 1, true)
      if close then
        local region = s:sub(open + 1, close - 1)
        if region:find("=%s*%[%]") or region:find("=%s*{}") then
          return true
        end
      end
    end
    i = a + 1
  end
end

--- `/\bglobal\s+\w+/` — a `global` statement naming something.
local function has_global(s)
  local i = 1
  while true do
    local a, b = s:find("global", i, true)
    if not a then
      return false
    end
    if not is_word(s, a - 1) and s:find("^%s+[%w_]", b + 1) then
      return true
    end
    i = a + 1
  end
end

--- One sentence per thing a reviewer would circle. Heuristics, not a linter:
--- every rule here is cheap, obvious when it fires, and about a habit rather
--- than a compile error (the compiler already says those better).
---
--- Returns a list of `{ id = …, text = … }` in the order the rules are
--- written, which is the order the web returns them in too, so a controller
--- that shows the first finding shows the same one in both clients.
function M.advise(lang, source)
  local out = {}
  local function say(id, text)
    out[#out + 1] = { id = id, text = text }
  end

  if lang == "rust" then
    local unwraps = count_plain(source, ".unwrap()")
    if unwraps > UNWRAP_LIMIT then
      say(
        "rust.unwrap",
        tostring(unwraps)
          .. " `unwrap()`s. Each is a place the program chooses to crash — "
          .. "a `?` or a `match` would say what to do instead."
      )
    end
    if inside_loop(source, ".clone()") then
      say("rust.clone-loop", "A `clone()` inside a loop is a copy every turn. A `&` borrow may do.")
    end
    -- `/&String\b/`
    if has_token(source, "&String", false, true) then
      say("rust.string-ref", "`&String` in a signature — `&str` takes the same callers and more.")
    end
    if source:find("&Vec<", 1, true) then
      say("rust.vec-ref", "`&Vec<T>` in a signature — `&[T]` accepts arrays and slices too.")
    end
    -- `/println!\s*\(\s*"\{:\?\}"/g`
    if count_pattern(source, 'println!%s*%(%s*"{:%?}"') > 0 then
      say(
        "rust.dbg",
        "A `println!(\"{:?}\")` left in — `dbg!(x)` prints the file and line and "
          .. "the name, and is easier to find later."
      )
    end
    if has_short_expect(source) then
      say(
        "rust.expect-empty",
        "An `expect(\"\")` with no message is an `unwrap()` that pretends otherwise."
      )
    end
  elseif lang == "go" then
    -- The web opens this case with an `if` whose body is a comment and nothing
    -- else — an explicit `_` for a returned error is a choice, so it says so
    -- and says nothing. Ported as the same nothing.
    local assigned_err = count_err_assigned(source)
    local checked_err = count_err_checked(source)
    if assigned_err > 0 and checked_err < assigned_err then
      say(
        "go.err-unchecked",
        "`err` is assigned "
          .. tostring(assigned_err)
          .. " times and checked "
          .. tostring(checked_err)
          .. ". The one you skipped is the one that fires."
      )
    end
    if inside_loop(source, "fmt.Print") then
      say(
        "go.print-loop",
        "`fmt.Print` in a loop flushes every turn. Build a `strings.Builder` and print once."
      )
    end
    -- `/\bpanic\(/` with no `recover(` anywhere.
    if has_token(source, "panic(", true, false) and not source:find("recover(", 1, true) then
      say(
        "go.panic",
        "A `panic` with no `recover` ends the program. "
          .. "Return the error unless this truly cannot happen."
      )
    end
    local concat = source:find('%+=%s*"[^"]*"') ~= nil or has_plus_equals_to_eol(source)
    if concat and inside_loop(source, "+=") then
      say(
        "go.string-concat",
        "String `+=` in a loop copies the whole string each time — `strings.Builder`."
      )
    end
  elseif lang == "pytorch" then
    if source:find("softmax") and source:find("CrossEntropyLoss") then
      say(
        "pytorch.double-softmax",
        "`nn.CrossEntropyLoss` softmaxes internally — feeding it softmaxed values applies it twice."
      )
    end
    if source:find("backward%(%)") and not source:find("zero_grad") then
      say(
        "pytorch.no-zero-grad",
        "`backward()` adds into `.grad`. Without `zero_grad()` the gradients of every step accumulate."
      )
    end
    if source:find("%.grad") and source:find("%-=") and not source:find("no_grad") then
      say(
        "pytorch.update-in-graph",
        "Updating a parameter outside `torch.no_grad()` records the update itself into the graph."
      )
    end
    if source:find("Dropout") and not source:find("%.eval%(%)") then
      say(
        "pytorch.still-training",
        "There is a `Dropout` here and no `model.eval()` — inference would still be dropping units."
      )
    end
  elseif lang == "cpp" then
    if source:find("using%s+namespace%s+std%s*;") then
      say(
        "cpp.using-std",
        "`using namespace std;` — fine in a scratchpad, a trap in a header. "
          .. "`std::` is three characters."
      )
    end
    local smart = source:find("unique_ptr", 1, true)
      or source:find("shared_ptr", 1, true)
      or source:find("make_unique", 1, true)
      or source:find("make_shared", 1, true)
    if has_raw_new(source) and not smart then
      say(
        "cpp.raw-new",
        "A bare `new` with no smart pointer in sight. Who calls `delete` on the early return?"
      )
    end
    if has_c_array(source) then
      say(
        "cpp.c-array",
        "A fixed C array — `std::array` knows its size and `std::vector` can grow."
      )
    end
    -- `/\bstd::endl\b/` and then the same needle inside a loop.
    if has_token(source, "std::endl", true, true) and inside_loop(source, "std::endl") then
      say(
        "cpp.endl-loop",
        "`std::endl` in a loop flushes every line. `'\\n'` is the newline; flush once at the end."
      )
    end
    if has_container_by_value(source) then
      say(
        "cpp.by-value",
        "A `std::string` or `std::vector` taken by value copies it. "
          .. "`const &` unless you need your own."
      )
    end
  elseif lang == "python" then
    if has_mutable_default(source) then
      say(
        "py.mutable-default",
        "A mutable default argument is one object shared by every call. "
          .. "Use `None` and make it inside."
      )
    end
    if source:find("except%s*:") then
      say(
        "py.bare-except",
        "A bare `except:` catches Ctrl-C and `SystemExit` too. Name the exception."
      )
    end
    -- `/\brange\(len\(/`
    if has_token(source, "range(len(", true, false) then
      say(
        "py.range-len",
        "`for i in range(len(xs))` — `enumerate(xs)` gives the index and the item."
      )
    end
    -- `/\bopen\(/` with no `with` in front of any of them.
    if has_token(source, "open(", true, false) and not source:find("with%s+open%(") then
      say(
        "py.open-no-with",
        "`open()` without `with` — the file stays open if anything below it raises."
      )
    end
    if source:find("==%s*None") or source:find("None%s*==") then
      say("py.eq-none", "`== None` works by accident; `is None` is the idiom.")
    end
    if has_global(source) then
      say("py.global", "A `global` is a value with no owner. Pass it in and return it out.")
    end
  end

  return out
end

return M
