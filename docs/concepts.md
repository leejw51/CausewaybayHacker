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

### Grammar (18)

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

### Memory and aliasing — Rust only (5)

| slug | what it is |
| --- | --- |
| `ownership` | one owner; move, copy, drop |
| `borrowing` | `&` and `&mut`, and the rule that they do not overlap |
| `lifetimes` | how long a reference is good for, and saying so |
| `mutability` | `mut`, and where interior mutability comes in |
| `smart-pointers` | `Box`, `Rc`, `Arc`, `RefCell` — owning something indirectly |

### Concurrency (6)

| slug | what it is | rust | go |
| --- | --- | --- | --- |
| `concurrency` | spawning and joining units of work | `thread::spawn`, `join` | `go`, `sync.WaitGroup` |
| `channels` | handing values between them | `mpsc` | `chan`, `select` |
| `shared-state` | one value, many holders, locked | `Arc<Mutex<_>>`, `RwLock` | `sync.Mutex`, `atomic` |
| `cancellation` | stopping work that is no longer wanted | drop the sender, flags | `context`, done channels |
| `data-races` | unsynchronized concurrent access, and detecting it | (the compiler refuses) | `go test -race` |
| `deadlock` | everyone waiting, nobody moving | lock order, `MutexGuard` scope | `all goroutines are asleep` |

### Algorithms — the `hacker` road (10)

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
| `recursion` | a function that calls itself, and its base case |
| `complexity` | what the time limit is actually asking for |

**39 slugs.** That is the whole list. Nothing else is valid in a pack.

---

## 2. Mistake kind → concepts

This is the join SPEC §7.3 `weakness` runs: take the user's top
`mistake_stats.kind`, look it up here, pull every quest whose `concepts`
overlap the row. Order within a row is priority — the first concept is the
one that most directly teaches the mistake.

| §7.1 kind | concepts |
| --- | --- |
| `borrow-after-move` | `ownership`, `borrowing`, `closures`, `smart-pointers` |
| `borrow-conflict` | `borrowing`, `mutability`, `shared-state` |
| `lifetime` | `lifetimes`, `borrowing`, `structs`, `traits` |
| `type-mismatch` | `types`, `generics`, `error-handling`, `pattern-matching` |
| `unknown-name` | `bindings`, `imports`, `functions` |
| `missing-trait` | `traits`, `generics`, `iteration` |
| `unused` | `bindings`, `imports` |
| `mutability` | `mutability`, `borrowing`, `slices` |
| `nil-deref` | `error-handling`, `interfaces`, `structs` |
| `index-range` | `slices`, `iteration`, `two-pointers` |
| `data-race` | `data-races`, `shared-state`, `concurrency` |
| `deadlock` | `deadlock`, `channels`, `shared-state` |
| `unhandled-error` | `error-handling`, `pattern-matching` |
| `syntax` | `bindings`, `control-flow`, `functions` |
| `wrong-answer` | `complexity`, `iteration`, `strings`, `io` |
| `timeout` | `complexity`, `hashing`, `binary-search`, `two-pointers` |
| `other` | — fall back to the concepts of the quest the mistake happened on |

`other` deliberately has no row. An unrecognized compiler code (SPEC §7.1)
carries no information about *which* idea the player is missing, so the drill
uses the quest it happened on instead of guessing.

### Coverage

A kind whose concepts reach **zero** shipped quests produces an empty drill,
which reads to the player as the AI mode being broken. The verifier
(`tools/verify_pack.py` in the scratch tree, run per pack) prints a coverage
line per kind. The rule: a kind may be at zero only while the pack that would
cover it is unwritten, and that is a tracked gap, not an accepted state.

`data-race` and `deadlock` are covered by `go/advanced.toml` and
`rust/advanced.toml` and by nothing before them.
