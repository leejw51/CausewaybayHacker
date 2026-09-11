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
  `ownership` is Rust-only. `slices`, `error-handling`, `concurrency` are not.

---

## 1. The vocabulary

### Grammar (23)

| slug | what it is | rust | go |
| --- | --- | --- | --- |
| `io` | stdin in, stdout out, formatting | `println!`, `io::stdin` | `fmt`, `bufio` |
| `bindings` | declaring, assigning, shadowing, constants, scope | `let`, `const`, shadowing | `var`, `:=`, `const` |
| `imports` | bringing names in; what a module/package is | `use`, `mod` | `package`, `import` |
| `types` | scalars, inference, conversion, casts | `as`, `i64`/`usize` | typed constants, conversions |
| `control-flow` | `if`, loops, `break`/`continue`, multi-way branch | `loop`/`while`/`for`, `match` | `for`, `switch` |
| `functions` | parameters, returns, receivers, `defer` | `fn`, methods | funcs, methods, `defer` |
| `closures` | capturing the environment; functions as values | `|x| …`, `move` | `func() {}` literals |
| `slices` | contiguous sequences, indexing, sub-slicing, growth | `Vec`, `&[T]` | `[]T`, `append`, cap |
| `collections` | keyed containers and sets | `HashMap`, `HashSet` | `map[K]V` |
| `strings` | bytes vs characters, building, splitting, parsing | `String`, `&str`, `chars()` | `string`, runes, `strings.Builder` |
| `structs` | product types, fields, methods, construction | `struct`, `impl` | `struct`, receivers |
| `enums` | sum types and the closed set of cases | `enum` | `iota` sets, tagged structs |
| `pattern-matching` | destructuring and exhaustive branching | `match`, `if let` | type switch, comma-ok |
| `error-handling` | failure as a value, propagation, absence | `Result`, `Option`, `?` | `error`, `%w`, `errors.Is` |
| `iteration` | walking a sequence without an index | iterators, `map`/`filter`/`fold` | `range` |
| `traits` | Rust's named behaviour, implemented explicitly | `trait`, `impl … for` | — |
| `interfaces` | Go's structural behaviour, satisfied implicitly | — | `interface`, type assertion |
| `generics` | code over a type parameter with a bound | `<T: Bound>` | `[T any]`, constraints |
| `dispatch` | choosing the implementation now or at run time | generics vs `dyn Trait` | generics vs `interface` |
| `panics` | crashing on purpose, and catching it | `panic!`, `unwrap`/`expect` | `panic`, `recover`, `defer` |
| `zero-values` | what an uninitialised value is, and absence | `Default`, `Option::None` | zero values; nil map, slice, interface |
| `testing` | proving it yourself before the interviewer does | `#[test]`, `assert_eq!` | `testing`, table-driven tests |
| `serialization` | a value in and out of a wire format | — (no deps offline) | `encoding/json`, struct tags |

### Memory and aliasing — Rust only (6)

| slug | what it is |
| --- | --- |
| `ownership` | one owner; move, copy, drop |
| `borrowing` | `&` and `&mut`, and the rule that they do not overlap |
| `lifetimes` | how long a reference is good for, and saying so |
| `mutability` | `mut`, and where interior mutability comes in |
| `smart-pointers` | `Box`, `Rc`, `Arc` — owning something indirectly |
| `interior-mutability` | `Cell`, `RefCell`, `Mutex`: mutating through a `&`, and who checks |

### Concurrency (8)

| slug | what it is | rust | go |
| --- | --- | --- | --- |
| `concurrency` | spawning and joining units of work | `thread::spawn`, `join` | `go`, `sync.WaitGroup` |
| `channels` | handing values between them | `mpsc` | `chan`, `select` |
| `shared-state` | one value, many holders, locked | `Arc<Mutex<_>>`, `RwLock` | `sync.Mutex`, `atomic` |
| `cancellation` | stopping work that is no longer wanted | drop the sender, flags | `context`, done channels |
| `data-races` | unsynchronized concurrent access, and detecting it | (the compiler refuses) | `go test -race` |
| `deadlock` | everyone waiting, nobody moving | lock order, `MutexGuard` scope | `all goroutines are asleep` |
| `async` | work that yields the thread instead of blocking it | `async`/`await`, `Future`, the executor | — goroutines *are* the answer |
| `thread-safety` | what makes a type safe to share, and who says so | `Send` / `Sync` | the memory model, happens-before |

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

**58 slugs.** That is the whole list. Nothing else is valid in a pack, and two
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
| `borrow-after-move` | `ownership`, `borrowing`, `closures`, `smart-pointers` |
| `borrow-conflict` | `borrowing`, `mutability`, `shared-state`, `interior-mutability` |
| `lifetime` | `lifetimes`, `borrowing`, `structs`, `traits` |
| `type-mismatch` | `types`, `generics`, `error-handling`, `pattern-matching`, `enums`, `serialization` |
| `unknown-name` | `bindings`, `imports`, `functions` |
| `missing-trait` | `traits`, `generics`, `iteration`, `dispatch`, `interfaces` |
| `unused` | `bindings`, `imports`, `testing` |
| `mutability` | `mutability`, `borrowing`, `slices` |
| `nil-deref` | `error-handling`, `zero-values`, `interfaces`, `structs` |
| `index-range` | `slices`, `iteration`, `two-pointers`, `matrix`, `collections` |
| `data-race` | `data-races`, `shared-state`, `concurrency`, `thread-safety` |
| `deadlock` | `deadlock`, `channels`, `shared-state`, `cancellation`, `async` |
| `unhandled-error` | `error-handling`, `pattern-matching`, `panics`, `testing` |
| `syntax` | `bindings`, `control-flow`, `functions` |
| `wrong-answer` | `complexity`, `iteration`, `strings`, `io`, `recursion`, `trees`, `linked-lists`, `backtracking`, `tries`, `matrix`, `bit-manipulation`, `math` |
| `timeout` | `complexity`, `hashing`, `binary-search`, `two-pointers`, `dynamic-programming`, `heaps`, `greedy`, `prefix-sums`, `disjoint-set`, `graphs`, `sorting`, `intervals`, `stacks-queues` |
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

As of the six packs in `content/`, every kind in the table above reaches
quests, and every one of the 58 slugs is used by a quest *and* named by a kind.
`other` is the only row at zero, and that is by design — it has no concepts.

`data-race` and `deadlock` are carried by `rust/advanced.toml` and
`go/advanced.toml` and by nothing before them; `complexity`, `hashing`,
`two-pointers`, `binary-search`, `graphs`, `intervals`, `stacks-queues` and
`dynamic-programming` only by the two `hacker` packs.
