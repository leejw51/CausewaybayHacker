/**
 * What the agent says when nobody has asked it anything.
 *
 * None of this touches a model (docs/agent.md §1). Two kinds of sentence:
 *
 *   * **tips** — one line per language about the language, said in idle
 *     time, never the same one twice running;
 *   * **advice** — `advise()` reads the text for the handful of things a
 *     reviewer would circle on sight (`unwrap()` everywhere, an `err` nobody
 *     checked, `using namespace std`, a bare `except:`) and says one sentence
 *     about each. Every finding has a stable `id`, so the controller can say
 *     each once per pad and not nag.
 *
 * Both are pure and `tests/tips.test.ts` pins them. The sentences are English
 * on purpose for now: the catalogue is the agent's own voice, and translating
 * seventy lines of Rust folklore is a job for a translator, not a build.
 */
import type { Land } from "../net/protocol";

export const TIPS: Record<Land, readonly string[]> = {
  rust: [
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
  ],
  go: [
    '`if err != nil { return err }` is the whole error system. Wrap with `fmt.Errorf("…: %w", err)`.',
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
  ],
  cpp: [
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
  ],
  python: [
    "A mutable default argument (`def f(xs=[])`) is shared by every call. Use `None`.",
    "`with open(…) as f:` closes the file for you, even on an exception.",
    "A list comprehension says what you want; a `for` with `append` says how.",
    "`except Exception as e:` — a bare `except:` also catches Ctrl-C.",
    "Dictionaries keep insertion order. `dict.get(k, default)` never raises.",
    "`enumerate(xs)` when you need the index; `zip(a, b)` when you need pairs.",
    'f-strings: `f"{x=}"` prints the name and the value. Debugging in one token.',
    "`is` compares identity, `==` compares value. `is None` is the one place for `is`.",
    "Generators (`yield`) produce one at a time; a million lines cost one line of memory.",
    "Type hints do not check anything at runtime — `mypy` does, and it is worth running.",
    "`sorted(xs, key=…)` returns a new list; `xs.sort()` sorts in place and returns `None`.",
    '`__name__ == "__main__"` is the line between a script and a module.',
  ],
  pytorch: [
    "Shape first. Print `tuple(x.shape)` before you print anything else.",
    "`zero_grad`, `backward`, `step` — in that order. `backward` adds into `.grad`; it never clears it.",
    "`nn.CrossEntropyLoss` takes raw logits. Softmax it yourself and you have softmaxed twice.",
    "`model.eval()` for dropout and batch-norm; `torch.no_grad()` for the graph. You usually want both.",
    "`view` needs contiguous memory, `reshape` does not. After a `transpose`, reach for `reshape`.",
    "`detach()` leaves the graph and shares the memory; `clone()` copies and stays. They are not the same tool.",
    "Keep `loss.item()`, not `loss`. Holding the tensor holds the whole graph behind it.",
    "`keepdim=True` on a reduction, or the axis vanishes and the broadcast lines up against the wrong one.",
    "A trailing underscore is in-place: `add_`, `relu_`. Autograd will notice, one backward pass later.",
    "Mask before the softmax, with `-inf`. Zeroing afterwards leaves a row that sums to less than one.",
    "`torch.manual_seed` fixes one global stream; pass a `torch.Generator` when you want a reproducible one.",
    "The scale in attention is the square root of the *head* dimension, not the model dimension.",
  ],
};

/** The next tip after `last`, never the same one twice running. */
export function nextTip(lang: Land, last: number, roll: number = Math.random()): number {
  const n = TIPS[lang].length;
  if (n <= 1) return 0;
  let i = Math.floor(roll * (n - 1));
  if (i >= last) i++;
  return Math.min(n - 1, Math.max(0, i));
}

export interface Advice {
  /** Stable across edits, so it is said once. */
  id: string;
  text: string;
}

/** How many `unwrap()` are still a scratchpad, not a habit. */
const UNWRAP_LIMIT = 3;

function countOf(re: RegExp, s: string): number {
  let n = 0;
  for (const _ of s.matchAll(re)) n++;
  return n;
}

/** Whether `needle` appears inside a `for`/`while`/`loop` block, roughly. */
function insideLoop(source: string, needle: RegExp): boolean {
  const lines = source.split("\n");
  let depth = 0;
  let loopDepth = -1;
  for (const raw of lines) {
    const line = raw.replace(/\/\/.*$/, "").replace(/#.*$/, "");
    if (loopDepth < 0 && /^\s*(for|while|loop)\b/.test(line)) loopDepth = depth;
    if (loopDepth >= 0 && needle.test(line) && !/^\s*(for|while|loop)\b/.test(line)) return true;
    for (const ch of line) {
      if (ch === "{" || ch === ":") depth++;
      else if (ch === "}") {
        depth--;
        if (loopDepth >= 0 && depth <= loopDepth) loopDepth = -1;
      }
    }
  }
  return false;
}

/**
 * One sentence per thing a reviewer would circle. Heuristics, not a linter:
 * every rule here is cheap, obvious when it fires, and about a habit rather
 * than a compile error (the compiler already says those better).
 */
export function advise(lang: Land, source: string): Advice[] {
  const out: Advice[] = [];
  const say = (id: string, text: string) => out.push({ id, text });
  switch (lang) {
    case "rust": {
      const unwraps = countOf(/\.unwrap\(\)/g, source);
      if (unwraps > UNWRAP_LIMIT) {
        say(
          "rust.unwrap",
          `${unwraps} \`unwrap()\`s. Each is a place the program chooses to crash — a \`?\` or a \`match\` would say what to do instead.`,
        );
      }
      if (insideLoop(source, /\.clone\(\)/)) {
        say(
          "rust.clone-loop",
          "A `clone()` inside a loop is a copy every turn. A `&` borrow may do.",
        );
      }
      if (/&String\b/.test(source)) {
        say(
          "rust.string-ref",
          "`&String` in a signature — `&str` takes the same callers and more.",
        );
      }
      if (/&Vec</.test(source)) {
        say("rust.vec-ref", "`&Vec<T>` in a signature — `&[T]` accepts arrays and slices too.");
      }
      if (countOf(/println!\s*\(\s*"\{:\?\}"/g, source) > 0) {
        say(
          "rust.dbg",
          'A `println!("{:?}")` left in — `dbg!(x)` prints the file and line and the name, and is easier to find later.',
        );
      }
      if (/\.expect\("[^"]{0,3}"\)/.test(source)) {
        say(
          "rust.expect-empty",
          'An `expect("")` with no message is an `unwrap()` that pretends otherwise.',
        );
      }
      break;
    }
    case "go": {
      if (/\b_\s*(:?=)\s*[^\n]*\b\w+\([^)]*\)\s*$/m.test(source) && /err/.test(source)) {
        // Fine; an explicit `_` is a choice.
      }
      const assignedErr = countOf(/\berr\s*:?=/g, source);
      const checkedErr = countOf(/\bif\s+err\s*!=\s*nil/g, source);
      if (assignedErr > 0 && checkedErr < assignedErr) {
        say(
          "go.err-unchecked",
          `\`err\` is assigned ${assignedErr} times and checked ${checkedErr}. The one you skipped is the one that fires.`,
        );
      }
      if (insideLoop(source, /fmt\.Print/)) {
        say(
          "go.print-loop",
          "`fmt.Print` in a loop flushes every turn. Build a `strings.Builder` and print once.",
        );
      }
      if (/\bpanic\(/.test(source) && !/recover\(/.test(source)) {
        say(
          "go.panic",
          "A `panic` with no `recover` ends the program. Return the error unless this truly cannot happen.",
        );
      }
      if (/\+=\s*"[^"]*"|\+=\s*\w+\s*$/m.test(source) && insideLoop(source, /\+=/)) {
        say(
          "go.string-concat",
          "String `+=` in a loop copies the whole string each time — `strings.Builder`.",
        );
      }
      break;
    }
    case "cpp": {
      if (/using\s+namespace\s+std\s*;/.test(source)) {
        say(
          "cpp.using-std",
          "`using namespace std;` — fine in a scratchpad, a trap in a header. `std::` is three characters.",
        );
      }
      if (
        /\bnew\s+\w+(\s*\[|\s*\()/.test(source) &&
        !/unique_ptr|shared_ptr|make_unique|make_shared/.test(source)
      ) {
        say(
          "cpp.raw-new",
          "A bare `new` with no smart pointer in sight. Who calls `delete` on the early return?",
        );
      }
      if (/\b(char|int|double)\s+\w+\s*\[\s*\d+\s*\]/.test(source)) {
        say(
          "cpp.c-array",
          "A fixed C array — `std::array` knows its size and `std::vector` can grow.",
        );
      }
      if (/\bstd::endl\b/.test(source) && insideLoop(source, /std::endl/)) {
        say(
          "cpp.endl-loop",
          "`std::endl` in a loop flushes every line. `'\\n'` is the newline; flush once at the end.",
        );
      }
      if (/\(\s*(const\s+)?std::(string|vector)<?[^)]*>?\s+\w+\s*\)/.test(source)) {
        say(
          "cpp.by-value",
          "A `std::string` or `std::vector` taken by value copies it. `const &` unless you need your own.",
        );
      }
      break;
    }
    case "python": {
      if (/def\s+\w+\([^)]*=\s*(\[\]|\{\})/.test(source)) {
        say(
          "py.mutable-default",
          "A mutable default argument is one object shared by every call. Use `None` and make it inside.",
        );
      }
      if (/except\s*:/.test(source)) {
        say(
          "py.bare-except",
          "A bare `except:` catches Ctrl-C and `SystemExit` too. Name the exception.",
        );
      }
      if (/\brange\(len\(/.test(source)) {
        say(
          "py.range-len",
          "`for i in range(len(xs))` — `enumerate(xs)` gives the index and the item.",
        );
      }
      if (/\bopen\(/.test(source) && !/with\s+open\(/.test(source)) {
        say(
          "py.open-no-with",
          "`open()` without `with` — the file stays open if anything below it raises.",
        );
      }
      if (/==\s*None|None\s*==/.test(source)) {
        say("py.eq-none", "`== None` works by accident; `is None` is the idiom.");
      }
      if (/\bglobal\s+\w+/.test(source)) {
        say("py.global", "A `global` is a value with no owner. Pass it in and return it out.");
      }
      break;
    }
  }
  return out;
}
