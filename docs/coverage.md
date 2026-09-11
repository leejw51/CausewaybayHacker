# Coverage — can a cleared player pass a live screen?

The bar the user set:

> if user clear all courses, can pass any hackerrank.com live coding interview

This file is the honest answer. It was written by reading the six packs as an
interviewer rather than as their author, listing what a screen could ask that
a cleared player would still not recognise, and then closing what was worth
closing. **The residual list in §5 is the important part of this document.**

State of the content: **126 quests** — 18 + 18 `basic`, 17 + 17 `advanced`,
28 + 28 `hacker`. Every reference solution compiles and runs against every
case through the real toolchain; every starter is proven to fail.

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
* **Sorting stability** — still not exercised. See §5.

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

24 `hacker` quests per language covered roughly 19 recognisable archetypes.
**28 covers about 23.** For a random screen question to land on something
recognisable most of the time, the honest number is **30–34** per language —
see §5 for the six that would get there.

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

* **`24.inversions` is the only quest whose hidden case rejects a correct
  answer for being too slow.** Its brief says so, with the measured numbers.
* Every other quest's hidden cases are small, and every brief that discusses
  complexity now says the cases are small and what the real constraint would
  be. `19.knapsack` is the one other quest whose test punishes a *wrong
  strategy* (greedy) rather than a slow one, and its brief points at the case
  that catches it.
* All 126 quests use `harness = "stdio"`. `cargo` and `gotest` (SPEC §5.2) are
  still unused, which is why the two `testing` quests teach the table shape
  rather than running under `#[test]` / `go test`.

---

## 5. What a cleared player still could not do

The honest residual. None of this is covered by the 126.

1. **Write a test that runs.** The `testing` quests teach the table, not the
   harness, because the runner only does `stdio`. A screen that says "add unit
   tests" is not something this content has prepared anyone for. *Fixable only
   by BE wiring `cargo` / `gotest`.*
2. **Segment trees, Fenwick trees, and range-update queries.** `24.inversions`
   names the Fenwick alternative in a hint and never asks for one. A
   "q range-sum queries with point updates" problem would be unfamiliar.
3. **Dijkstra and weighted graphs.** Graph coverage is BFS, DFS, topological
   sort and union-find. Every edge in every quest has weight one. Shortest path
   with weights, and anything needing a priority queue keyed on distance, is
   absent.
4. **String algorithms beyond grouping and DP.** No palindromes (expand-around-
   centre or Manacher), no KMP/Z-function, no rolling hash. "Longest
   palindromic substring" is a top-twenty screen question and would land on
   nothing.
5. **Sorting stability, and custom comparators with a multi-key tie-break under
   a stability requirement.** Ties are broken explicitly everywhere in this
   content, which dodges the question rather than teaching it.
6. **Bit-mask DP and combinatorics.** `20.bits` is bit *manipulation*. Subset
   DP over a mask, and counting problems needing modular arithmetic —
   `nCr mod p`, modular inverse — are absent, and "answer modulo 1e9+7" is a
   phrase this content has never shown anyone.
7. **Matrix/geometry beyond rotate and spiral.** No 2D DP over a grid with
   obstacles, no interval scheduling with weights, no coordinate geometry.
8. **Interactive and multi-file problems.** Out of scope for the runner, and
   worth saying rather than leaving implied.
9. **Talking.** A live screen is half explanation. Nothing here rehearses
   saying why you chose the structure you chose. The `brief`s model the
   reasoning; the quest never asks the player to produce it.

**The six quests that would close the most, in order:** Dijkstra;
range queries with a Fenwick or segment tree; longest palindromic substring;
a modular-arithmetic counting problem; grid DP with obstacles; and a
stability-sensitive multi-key sort. That is the 28 → 34 the honest answer in
§1.5 asks for.

---

## 6. So — can a cleared player pass a live screen?

**Most of one, and not any of one.**

They would recognise the shape of the session, read the statement properly,
handle the empty and single-element cases, reach for the right structure on
about four questions in five, and — after `24.inversions` — know in their hands
and not just in a brief that the correct slow answer is a rejection.

They would be caught out by a weighted shortest path, by a palindrome
question, by anything that says *modulo 1e9+7*, and by "now add tests".

§5 is the list to close, and until it is closed this document should not claim
otherwise.
