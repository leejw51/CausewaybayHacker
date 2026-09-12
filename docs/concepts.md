# Concepts — the controlled vocabulary

`quests.concepts` is not a tag cloud. SPEC §7.3 `weakness` joins a user's
`mistake_stats.kind` to quests **through this list**, so a slug that is not in
this file reaches nothing, and a free-form tag silently breaks a drill.

Rules:

* Lowercase, hyphenated, singular where it reads naturally.
* A quest carries **2–4** concepts. More than four means the quest teaches
  nothing in particular.
* Adding a slug is a change to this file *and* a line in `docs/decisions.md`.
  Never invent one inside a pack.
* A slug is shared between lands only where the idea is genuinely the same.
  `ownership` is Rust's and C++'s (`unique_ptr` makes it literal), and so are
  `mutability` (`const`) and `smart-pointers`. `traits` and `interfaces` are
  Rust's and Go's alone; C++ and Python say `generics`, `dispatch` and
  `duck-typing` instead. `slices`, `error-handling`, `concurrency` are
  everyone's. `—` in a land's column means the slug is not used there.

---

## 1. The vocabulary

### Grammar (27)

| slug | what it is | rust | go | cpp | python |
| --- | --- | --- | --- | --- | --- |
| `io` | stdin in, stdout out, formatting | `println!`, `io::stdin` | `fmt`, `bufio` | `std::cin`, `std::cout`, `getline` | `input()`, `print`, `sys.stdin` |
| `bindings` | declaring, assigning, shadowing, constants, scope | `let`, `const`, shadowing | `var`, `:=`, `const` | `int x`, `auto`, `const`, `constexpr` | names, rebinding, `global`/`nonlocal` |
| `imports` | bringing names in; what a module/package is | `use`, `mod` | `package`, `import` | `#include`, namespaces | `import`, `from … import` |
| `types` | scalars, inference, conversion, casts | `as`, `i64`/`usize` | typed constants, conversions | `static_cast`, `int64_t`/`size_t`, promotion | `int`/`float`/`str`, `int(s)`, dynamic |
| `control-flow` | `if`, loops, `break`/`continue`, multi-way branch | `loop`/`while`/`for`, `match` | `for`, `switch` | `for`, `while`, `switch` | `for … in`, `while`, `match` |
| `functions` | parameters, returns, receivers, `defer` | `fn`, methods | funcs, methods, `defer` | functions, overloads, default arguments | `def`, keyword args, `*args`/`**kwargs` |
| `closures` | capturing the environment; functions as values | `|x| …`, `move` | `func() {}` literals | lambdas, `[&]` vs `[=]` | `lambda`, nested `def` |
| `slices` | contiguous sequences, indexing, sub-slicing, growth | `Vec`, `&[T]` | `[]T`, `append`, cap | `std::vector`, `std::span`, arrays | `list`, `a[i:j]`, negative indexes |
| `collections` | keyed containers and sets | `HashMap`, `HashSet` | `map[K]V` | `std::map`, `unordered_map`, `std::set` | `dict`, `set`, `collections` |
| `strings` | bytes vs characters, building, splitting, parsing | `String`, `&str`, `chars()` | `string`, runes, `strings.Builder` | `std::string`, `string_view`, `stringstream` | `str`, `split`, f-strings, `bytes` |
| `structs` | product types, fields, methods, construction | `struct`, `impl` | `struct`, receivers | `struct`, `class`, constructors | `class`, `__init__`, `dataclass` |
| `enums` | sum types and the closed set of cases | `enum` | `iota` sets, tagged structs | `enum class`, `std::variant` | `enum.Enum` |
| `pattern-matching` | destructuring and exhaustive branching | `match`, `if let` | type switch, comma-ok | `std::visit`, structured bindings | `match`/`case`, unpacking |
| `error-handling` | failure as a value, propagation, absence | `Result`, `Option`, `?` | `error`, `%w`, `errors.Is` | exceptions, `std::optional`, `std::expected` | `try`/`except`, `raise`, `None` |
| `iteration` | walking a sequence without an index | iterators, `map`/`filter`/`fold` | `range` | range-`for`, iterators, `<algorithm>` | `for`, `enumerate`, `zip` |
| `traits` | Rust's named behaviour, implemented explicitly | `trait`, `impl … for` | — | — | — |
| `interfaces` | Go's structural behaviour, satisfied implicitly | — | `interface`, type assertion | — | — |
| `generics` | code over a type parameter with a bound | `<T: Bound>` | `[T any]`, constraints | templates, concepts | `TypeVar`, a `def` over any type |
| `dispatch` | choosing the implementation now or at run time | generics vs `dyn Trait` | generics vs `interface` | templates vs `virtual` | `singledispatch`, method lookup |
| `panics` | crashing on purpose, and catching it | `panic!`, `unwrap`/`expect` | `panic`, `recover`, `defer` | `assert`, `std::terminate`, `abort` | `assert`, an uncaught exception |
| `zero-values` | what an uninitialised value is, and absence | `Default`, `Option::None` | zero values; nil map, slice, interface | uninitialised is garbage; `{}`, `std::optional` | `None`, empty containers are falsy |
| `testing` | proving it yourself before the interviewer does | `#[test]`, `assert_eq!` | `testing`, table-driven tests | `assert`, a checking `main` | `assert`, `unittest` |
| `serialization` | a value in and out of a wire format | — (no deps offline) | `encoding/json`, struct tags | — (no deps offline) | `json` |
| `comprehensions` | building a container from an expression in one line | — | — | — | list/dict/set comprehensions, generator expressions |
| `generators` | a sequence produced lazily, one item on demand | — | — | — | `yield`, `itertools` |
| `decorators` | functions wrapping functions | — | — | — | `@property`, `functools.wraps` |
| `duck-typing` | it works if it quacks; checked when it runs | — | — | — | `Protocol`, `__dunder__` methods, `isinstance` |

### Memory and aliasing — Rust and C++ (10)

| slug | what it is | lands |
| --- | --- | --- |
| `ownership` | one owner; move, copy, drop | rust, cpp (`unique_ptr`) |
| `borrowing` | `&` and `&mut`, and the rule that they do not overlap | rust |
| `lifetimes` | how long a reference is good for, and saying so | rust |
| `mutability` | `mut`, and where interior mutability comes in; `const` and where it stops | rust, cpp |
| `smart-pointers` | `Box`, `Rc`, `Arc`; `unique_ptr`, `shared_ptr` — owning something indirectly | rust, cpp |
| `interior-mutability` | `Cell`, `RefCell`, `Mutex`: mutating through a `&`, and who checks | rust |
| `pointers` | raw pointers, references, `nullptr`, arrays that decay | cpp |
| `raii` | destructors on scope exit; `unique_ptr`, `lock_guard`, `fstream` | cpp |
| `move-semantics` | rvalues, `std::move`, what a moved-from object is | cpp |
| `undefined-behaviour` | the compiler assumed it could not happen; signed overflow, dangling, OOB | cpp |

### Concurrency (8)

| slug | what it is | rust | go | cpp | python |
| --- | --- | --- | --- | --- | --- |
| `concurrency` | spawning and joining units of work | `thread::spawn`, `join` | `go`, `sync.WaitGroup` | `std::thread`, `std::jthread`, `join` | `threading`, `concurrent.futures` |
| `channels` | handing values between them | `mpsc` | `chan`, `select` | a queue under a `condition_variable` | `queue.Queue` |
| `shared-state` | one value, many holders, locked | `Arc<Mutex<_>>`, `RwLock` | `sync.Mutex`, `atomic` | `std::mutex`, `lock_guard`, `std::atomic` | `threading.Lock`, the GIL |
| `cancellation` | stopping work that is no longer wanted | drop the sender, flags | `context`, done channels | `std::stop_token`, flags | `Event`, timeouts |
| `data-races` | unsynchronized concurrent access, and detecting it | (the compiler refuses) | `go test -race` | undefined behaviour; `-fsanitize=thread` | the GIL hides most; `+=` is still not atomic |
| `deadlock` | everyone waiting, nobody moving | lock order, `MutexGuard` scope | `all goroutines are asleep` | lock order, `std::scoped_lock` | lock order, `RLock` |
| `async` | work that yields the thread instead of blocking it | `async`/`await`, `Future`, the executor | — goroutines *are* the answer | coroutines, `co_await` | `asyncio`, `async`/`await` |
| `thread-safety` | what makes a type safe to share, and who says so | `Send` / `Sync` | the memory model, happens-before | `const` means thread-safe; the memory model | the GIL, and what it does not promise |

### Algorithms — the `hacker` road (21)

| slug | what it is |
| --- | --- |
| `hashing` | a map as the thing that turns O(n²) into O(n) |
| `two-pointers` | two indices walking one sequence; sliding windows |
| `binary-search` | halving a sorted space, and searching on the answer |
| `sorting` | ordering, comparators, and sorting as a preprocessing step |
| `stacks-queues` | LIFO/FIFO, monotonic stacks, ring buffers |
| `graphs` | adjacency, BFS, DFS, grids as graphs |
| `intervals` | ranges: merging, overlapping, sweeping |
| `dynamic-programming` | reusing sub-answers instead of recomputing them |
| `complexity` | what the time limit is actually asking for |
| `recursion` | a function that calls itself, and its base case |
| `linked-lists` | nodes that point at nodes: reversal, cycles, the runner |
| `trees` | binary trees, traversal order, and what makes one a BST |
| `tries` | a tree keyed by prefix |
| `heaps` | the smallest thing cheaply, over and over |
| `backtracking` | try it, recurse, undo it |
| `disjoint-set` | union-find: which things ended up in the same group |
| `bit-manipulation` | a number read as a row of flags |
| `matrix` | a grid as a value: rotate it, spiral it, mark it in place |
| `math` | gcd, primes, bases, and where an `i64` stops |
| `prefix-sums` | one running total that answers every range question |
| `greedy` | the locally best choice, and whether it is globally best |

**66 slugs.** That is the whole list. Nothing else is valid in a pack, and two
rules keep the list honest, both of them checked mechanically rather than by
good intentions:

1. **Every slug is carried by at least one shipped quest.** A slug that reaches
   nothing is the same bug as a free-form tag, one step earlier.
2. **Every slug appears in at least one row of §2 below.** A slug no mistake
   kind names is unreachable *from the drill*, which is the only consumer this
   vocabulary has.

---

## 2. Mistake kind → concepts

This is the join SPEC §7.3 `weakness` runs: take the user's top
`mistake_stats.kind`, look it up here, pull every quest whose `concepts`
overlap the row. Order within a row is priority — the first concept is the
one that most directly teaches the mistake.

| §7.1 kind | concepts |
| --- | --- |
| `borrow-after-move` | `ownership`, `borrowing`, `closures`, `smart-pointers`, `move-semantics`, `raii` |
| `borrow-conflict` | `borrowing`, `mutability`, `shared-state`, `interior-mutability` |
| `lifetime` | `lifetimes`, `borrowing`, `structs`, `traits`, `raii`, `pointers` |
| `type-mismatch` | `types`, `generics`, `error-handling`, `pattern-matching`, `enums`, `serialization`, `duck-typing` |
| `unknown-name` | `bindings`, `imports`, `functions`, `decorators` |
| `missing-trait` | `traits`, `generics`, `iteration`, `dispatch`, `interfaces`, `duck-typing` |
| `unused` | `bindings`, `imports`, `testing` |
| `mutability` | `mutability`, `borrowing`, `slices` |
| `nil-deref` | `error-handling`, `zero-values`, `interfaces`, `structs`, `pointers`, `undefined-behaviour` |
| `index-range` | `slices`, `iteration`, `two-pointers`, `matrix`, `collections`, `undefined-behaviour` |
| `data-race` | `data-races`, `shared-state`, `concurrency`, `thread-safety` |
| `deadlock` | `deadlock`, `channels`, `shared-state`, `cancellation`, `async` |
| `unhandled-error` | `error-handling`, `pattern-matching`, `panics`, `testing` |
| `syntax` | `bindings`, `control-flow`, `functions` |
| `wrong-answer` | `complexity`, `iteration`, `strings`, `io`, `recursion`, `trees`, `linked-lists`, `backtracking`, `tries`, `matrix`, `bit-manipulation`, `math`, `comprehensions`, `generators` |
| `timeout` | `complexity`, `hashing`, `binary-search`, `two-pointers`, `dynamic-programming`, `heaps`, `greedy`, `prefix-sums`, `disjoint-set`, `graphs`, `sorting`, `intervals`, `stacks-queues`, `generators` |
| `other` | — fall back to the concepts of the quest the mistake happened on |

The last two rows are long on purpose, and they split the algorithm half of the
vocabulary along the line the two verdicts actually mean. `wrong-answer` is
*you got the shape wrong* — the structures and the recursion. `timeout` is
*you got the cost wrong* — the structures whose whole job is to make something
cheaper. A player who keeps timing out should be handed heaps and prefix sums,
not more tree traversals.

`other` deliberately has no row. An unrecognized compiler code (SPEC §7.1)
carries no information about *which* idea the player is missing, so the drill
uses the quest it happened on instead of guessing.

### Coverage

A kind whose concepts reach **zero** shipped quests produces an empty drill,
which reads to the player as the AI mode being broken. This is a CI assertion,
not a habit: the content check that runs every reference solution
(SPEC §9.4/§9.5, QA-owned) should print a coverage line per kind and fail on a
zero. A kind may be at zero only while the pack that would cover it is
unwritten, and that is a tracked gap, not an accepted state.

As of the twelve packs in `content/`, every kind in the table above reaches
quests, and every one of the 66 slugs is used by a quest *and* named by a kind.
`other` is the only row at zero, and that is by design — it has no concepts.
The eight slugs added with the C++ and Python lands are each carried by a
quest in the land that owns them, which is the rule for adding one.

`data-race` and `deadlock` are carried by the four `advanced` packs and by
nothing before them; `complexity`, `hashing`, `two-pointers`, `binary-search`,
`graphs`, `intervals`, `stacks-queues` and `dynamic-programming` only by the
four `hacker` packs.
