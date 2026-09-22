# Coverage — can a cleared player pass a live screen?

The bar the user set:

> if user clear all courses, can pass any hackerrank.com live coding interview

This file is the honest answer. It was written by reading the six packs as an
interviewer rather than as their author, listing what a screen could ask that
a cleared player would still not recognise, and then closing what was worth
closing. **The residual list in §5 is the important part of this document.**

State of the content when this audit was written: **278 quests** across four
lands. It is **608 across five** now — the four roads are 27/27/33–34/34 per
land, and PYTORCH LAND joined with 122 of its own (`docs/story.md` §3). The
paragraph below is the audit's own snapshot and is kept as it was written;
§5's residual list is what this document is for.

At the time of the audit: **278 quests** across four lands. `basic` is 18 in Rust
and Go and 19 in C++ and Python, `advanced` is 17 everywhere, `hacker` is 34
everywhere. The two extra `basic` quests are the hash table (`cpp`) and the
dict comprehension (`python`), which the other two lands cover inside existing
quests. Every reference solution compiles and runs against every case through
the real toolchain; every starter is proven to fail.

---

## 1. What was missing, and why it mattered

The audit looked for four things, in this order: problem **shapes** rather
than algorithms, **complexity that is actually enforced**, the **non-algorithmic
half** of an interview, and **language questions that are not algorithm
questions**.

### 1.1 Complexity was never enforced — the worst finding

Before this round, **no quest in the repository rejected a correct-but-slow
answer.** Every hidden case was ten elements or fewer. The briefs said things
like "the nested loop is the wrong answer here"; nothing in the tests agreed.
A player could clear all 116 with `O(n²)` thinking throughout and never learn
otherwise, which is precisely the thing a screen fails people for.

The obstacle was real: `stdin` lives literally in the TOML, and a 200000-element
array is about a megabyte of unreadable content pack.

**The fix is a seeded generator.** `stdin` is `n seed`; the brief specifies an
exact LCG; the program builds its own array. 200000 elements cost twelve bytes
of pack. Measured on this machine with the two programs that ship in the quest:

| | n = 200000 |
| --- | --- |
| merge-sort inversion count, `O(n log n)` | **0.02 s** |
| double loop, `O(n²)` | **> 5 s — killed by the runner** |

That is a 250× margin against a 5 s limit, not a coin flip. `24.inversions` in
both languages now ships the naive answer **as its starter**, and the starter
is rejected for being slow — the only quest in the repository where that is
literally true.

The same quest carries a second trap for free: the answer for `n = 200000` is
`9990744366`, which does not fit in an `i32`/`int32`.

### 1.2 Problem shapes that did not exist

| shape | status before | now |
| --- | --- | --- |
| `T` test cases, each independent | **absent** — the single most common competitive-screen wrapper, and zero quests used it | `25.test-cases`, whose starter is exactly the per-case-state-leak bug |
| input packed across lines, count that counts *commands* not tokens | absent | `27.commands` — ragged lines, blank lines, `ADD` as one command of two tokens |
| floating-point answer with a tolerance | absent; `match: "float:1e-6"` was in SPEC §5.2 and **unused by all 116 quests** | `26.statistics` — mean, population SD, even-length median |
| build a structure, answer many queries | thin (trie, LRU only) | unchanged; judged adequate |
| naive answer correct but too slow, and the test catches it | absent | `24.inversions` |

### 1.3 The non-algorithmic half

What actually fails candidates is rarely the algorithm.

* **Empty and single-element cases** — already good. Almost every quest had a
  one-element or empty hidden case before this round.
* **Integer overflow** — was **absent**: every quest already used `i64`, so the
  trap never appeared. Now in `24.inversions`, where the right answer overflows
  32 bits.
* **Reading the statement** — now explicit in `26.statistics`: *population*
  standard deviation, not sample. The difference between `/n` and `/(n-1)` is
  the whole submission and the brief says so.
* **Off-by-one at a boundary** — covered (binary search, sliding window, spiral
  bounds, even-length median).
* **Returning the right thing when there is no answer** — covered (`-1`,
  `NONE`, `ABSENT`, `CYCLE`, `-`).
* **Sorting stability** — now exercised by `34.stable-sort`, whose hidden
  cases are sized (`n = 60`, `n = 200`) to actually separate a stable sort from
  an unstable one. See §4.

### 1.4 Language questions that are not algorithm questions

Checked against what is actually asked in Rust and Go screens.

**Rust** — `&str` vs `String` ✅, `Option`/`Result` combinators ✅, lifetimes ✅,
`Rc<RefCell<T>>` ✅, `Send`/`Sync` ✅, static vs dynamic dispatch ✅, interior
mutability ✅, custom errors and `?` conversion ✅, `Drop` order ✅, atomics vs
`Mutex` ✅, modules and visibility ✅, writing the executor behind `async` ✅.
**Missing: `Fn` / `FnMut` / `FnOnce`** — planned last round and never written.
Now `rust.advanced.16.closure-kinds`, whose starter fails to compile with E0525
because a closure that gives its `String` away is `FnOnce` and nothing more.

**Go** — pointer vs value receivers ✅, struct embedding and promotion ✅,
interfaces and type switches ✅, error wrapping and `errors.Is` ✅, `defer`/
`panic`/`recover` ✅, nil maps and zero values ✅, channel axioms ✅, `context` ✅,
`RWMutex` ✅, happens-before ✅, generics and constraints ✅, JSON struct tags ✅.
**Missing: the three classic gotchas** — slice aliasing after `append`, a typed
nil inside an interface, and `defer` argument evaluation. Now
`go.advanced.16.gotchas`, which asks for all three in one program.

### 1.5 Volume

24 `hacker` quests per language covered roughly 19 recognisable archetypes;
28 covered about 23. **34 per language now covers about 29 archetypes**, and
34 quests is inside the 30–34 band this section called honest. The six that closed the gap are
`29.dijkstra`, `30.range-queries`, `31.palindrome`, `32.modular`,
`33.grid-paths` and `34.stable-sort`, at nodes 28–33 in both languages.

---

## 2. What was added

Ten quests, each closing a named gap above.

| quest | gap closed |
| --- | --- |
| `rust.hacker.24.inversions`, `go.hacker.24.inversions` | complexity actually enforced; 64-bit overflow |
| `rust.hacker.25.test-cases`, `go.hacker.25.test-cases` | the `T` test-case shape; per-case state leaks |
| `rust.hacker.26.statistics`, `go.hacker.26.statistics` | float output with tolerance; read-the-statement; median boundary |
| `rust.hacker.27.commands`, `go.hacker.27.commands` | ragged input; a count that counts commands, not tokens; defensive empty-state handling |
| `rust.advanced.16.closure-kinds` | `Fn` / `FnMut` / `FnOnce` |
| `go.advanced.16.gotchas` | slice aliasing, typed nil, `defer` argument evaluation |

Both `hacker` bosses moved to node 28 and both `advanced` bosses to node 17.
Ids changed accordingly; slugs did not. See `docs/decisions.md`.

---

## 3. The clock

`time_limit_s` is now server-enforced and displayed (PROTOCOL §4.8b), so the
numbers were re-reviewed against one question: *could a competent coder who
knows this topic finish in this?*

| band | means | examples |
| --- | --- | --- |
| **600 s** | one idea, one pass, under thirty lines of real work | two-sum, bits |
| **900 s** | one idea plus a twist or an exact output format | sliding window, intervals, monotonic stack, tree walks, BST, subsets, anagrams, test-cases, statistics |
| **1200 s** | two ideas, fiddly boundaries, or a structure to build | grid BFS, binary search on the answer, coins, heap merge, word search, topo sort, union-find, LIS, edit distance, knapsack, Kadane, prefix sums, matrix, rotated search, commands |
| **1500 s** | build a structure *and* answer queries, or the fast answer is mandatory | trie, inversions |
| **1800 s** | boss | LRU |

Ten limits moved. Raised: both `matrix` quests and `go.rotated` to 1200 (two
algorithms, and the spiral and pivot boundaries are where people lose the
time); `rust.linked-list` to 1200 (`Option<Box<Node>>` reversal is genuinely
fiddly in a way the Go version is not — the same problem is not the same
length in both languages); `rust.binary-search` to 1200 (you have to invent the
predicate before you can search on it); both `trie` quests to 1500. Lowered:
both `bits` quests to 600 and `go.anagrams` to 900, which were padded.

---

## 4. What the tests do and do not prove

Stated plainly, because the rule in this repository is *do not promise a
constraint no test enforces*:

* **Five quests now have a hidden case that rejects a correct answer for being
  too slow**, each with the measured numbers in its own brief:
  `24.inversions` (merge sort vs the double loop), `29.dijkstra` (heap vs
  linear-scan min), `30.range-queries` (Fenwick vs the per-query loop),
  `31.palindrome` (quadratic accepted, naive cubic rejected — and Manacher explicitly
  *not* demanded), and `32.modular` (one factorial table vs a modular inverse
  per query). `33.grid-paths` rejects route enumeration, which is a
  mathematical statement rather than a timing one.
* **One caveat on `31.palindrome`, because it is the limit of what timing can
  enforce.** The one-letter case rejects check-*every*-substring. Add a single
  line skipping any substring no longer than the best found so far and that
  same cubic loop passes both big cases, because on this input the pruning
  collapses it to `O(n²)`. A timed case rejects a *program*, not a complexity
  class. This is the one enforcement in the pack where that gap is narrow
  enough to reach by accident, and the brief now says so.
* Every other quest's hidden cases are small, and every brief that discusses
  complexity now says the cases are small and what the real constraint would
  be. `19.knapsack` is the one other quest whose test punishes a *wrong
  strategy* (greedy) rather than a slow one, and its brief points at the case
  that catches it.
* All 278 quests use `harness = "stdio"`. `cargo` and `gotest` (SPEC §5.2) are
  still unused, which is why the two `testing` quests teach the table shape
  rather than running under `#[test]` / `go test`. A harness for both is being
  built separately; when it lands, §5 item 1 becomes writable.

---

## 5. What a cleared player still could not do

The honest residual, revised after the second pass. Six items from the first
version are now closed — Dijkstra, range queries with updates, palindromes,
modular counting, grid DP with obstacles, and sorting stability all shipped as
`hacker` nodes 28–33 in both languages.

What remains:

1. **Write a test that runs.** The `testing` quests teach the table, not the
   harness, because the runner only does `stdio`. *A separate agent is building
   the `cargo` and `gotest` harnesses; once they land this becomes writable
   content and is the first thing to write.*
2. **Segment trees with range *update*.** `30.range-queries` ships a Fenwick
   tree, which is point-update / range-query. Range-update-range-query, and
   lazy propagation, are still absent — and a segment tree is the more
   commonly *named* structure of the two.
3. **String algorithms beyond palindromes and grouping.** No KMP, no Z-function,
   no rolling hash. `31.palindrome` explicitly tells the player that Manacher
   exists and that the tests do not demand it, which is honest but is not the
   same as having taught it.
4. **Minimum spanning tree.** Union-find is in the packs and Dijkstra is now in
   the packs; Kruskal is the two of them put together and is one of the most
   commonly asked graph questions after shortest path.
5. **Bit-mask DP.** `20.bits` is bit *manipulation*; subset DP over a mask is a
   different thing and is absent.
6. **Geometry.** No coordinate geometry of any kind.
7. **Interactive and multi-file problems.** Out of scope for the runner.
8. **Talking.** A live screen is half explanation and nothing here rehearses
   producing it out loud.

**The four that would close the most now, in order:** a test that actually
runs (blocked on the harness); Kruskal, which is cheap because both halves are
already in the packs; a segment tree with lazy propagation; and KMP. That is
34 → 38 per language, and the returns are visibly diminishing — the first item
is worth more than the other three together.

---

## 5b. Where the same quest is not the same quest

For PM2, and for anyone tempted to mirror a Rust pack into Go or back. These
are the places where the two languages make the *same problem* a different
piece of work, found by writing both halves. Symmetry is not the goal;
teaching the thing the language actually makes hard is.

| quest | the asymmetry | what was done about it |
| --- | --- | --- |
| `linked-list` | `Option<Box<Node>>` reversal needs `.take()` and a borrow dance; `*Node` reversal is four lines | Rust **1200 s**, Go **900 s**. Same problem, different clock. |
| `28.lru` (boss) | Go has `container/list`, a real doubly linked list, so the textbook O(1) answer is writable. Rust without `unsafe` or `Rc<RefCell<_>>` cannot, honestly | Two genuinely different quests. Rust's brief admits its O(cap) eviction scan and says saying so out loud is worth more than pretending; Go's builds the real thing. |
| `24.inversions` | Rust needs `wrapping_mul`/`wrapping_add` and would panic in debug; Go's `uint64` wraps silently | Rust's brief teaches wrapping arithmetic as a named thing. Go's cannot, and says so instead. |
| `29.dijkstra` | Rust: `BinaryHeap` is a **max**-heap, so `Reverse` is a concept you must know. Go: `container/heap` needs five methods with mixed value/pointer receivers | Same 1500 s — the difficulty is equal but is in a different place. Each brief names its own obstacle rather than the other's. |
| `30.range-queries` | `i & i.wrapping_neg()` in Rust, because unary minus is not defined on `usize`; plain `i & -i` in Go on `int` | A real Rust papercut. Called out in the Rust hints; the Go hint just says `i & -i`. |
| `34.stable-sort` | **The defaults differ.** Rust's plain `.sort()`/`sort_by_key` is stable, so reaching for the obvious thing gives stability free. Go's `sort.Slice` is *not* stable, and it is the obvious thing | The quest matters **more in Go**, and Go's brief leans harder on it. Both ship the "make the comparator total" answer as the one to reach for by default. |
| `modular`, `grid-paths`, `palindrome` | no meaningful asymmetry | deliberately near-mirrors. |

## 6. So — can a cleared player pass a live screen?

**Most of one, and now most of the hard half too.**

They would recognise the shape of the session, read the statement properly,
handle the empty and single-element cases, reach for the right structure on
roughly nine questions in ten, and — after five quests whose hidden cases kill
a correct-but-slow answer — know in their hands and not just in a brief that
the right algorithm is part of the answer and not a bonus.

They would still be caught out by "now add tests", by a lazy segment tree, and
by a question that wants KMP by name. None of those is a coin flip in a screen;
all three are recoverable in a conversation. The first is the one to fix.

§5 is the list to close, and until it is closed this document should not claim
otherwise.
