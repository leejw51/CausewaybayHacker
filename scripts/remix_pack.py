#!/usr/bin/env python3
"""Write REMIX LAND's packs: content/remix/verybasic.toml and basic.toml.

REMIX LAND is one program three times. Every concept is a *trio* of nodes —
Go, then Rust, then Python, always in that order — and the three are the
same program with the same tests, so a player who has just typed the Go
line types the Rust line next and the Python line after that, and the three
grammars for one idea sit side by side in the fingers. Where a language has
no such construct (a lifetime in Go, a comprehension in Rust, ownership in
Python) the trio keeps the same shape and the brief says what stands in.

The two roads are the same programs with different holes:

  * BASIC      the grammar drill: the brief shows the exact lines, the
               starter has a hole of one to four lines with an `ANSWER:`
               comment at it, the player types the idiom (SPEC §12).
  * VERY BASIC the quiz: one of those lines, four choices, one right — and
               two of the wrong ones are the *other two languages'* line,
               because that is the mistake this land exists to cure.

One source of truth: each trio below carries the three finished programs
and names its hole; the starters, the quiz starters and the quiz choices
are derived, so the two packs cannot drift apart. Run it from the checkout:

    python3 scripts/remix_pack.py
    python3 tests/content/verify_pack.py content/remix/verybasic.toml content/remix/basic.toml

verify_pack's remix rule (`remix_trios`) then checks what this script
promises: threes, in order, same cases, same difficulty, same title.
"""
import math
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
OUT = REPO / "content" / "remix"

LANGS = ("go", "rust", "python")
LANG_NAME = {"go": "GO", "rust": "RUST", "python": "PYTHON"}
COMMENT = {"go": "//", "rust": "//", "python": "#"}
SPEAKER = {
    "go": "Gogo orders it in Go.",
    "rust": "Ferris orders it in Rust.",
    "python": "The python orders it in Python.",
}

# The land's setting (docs/story.md §3): the yuenyeung café on Sugar Street,
# where the three mascots share one table and every dish is ordered three
# ways. Yuenyeung is coffee and tea in one cup, which is the whole land.


class Trio:
    """One concept, three programs.

    slug        the id's tail: `remix.basic.NN.<slug>-<lang>`
    title       shared title; the pack adds ` — GO` / ` — RUST` / ` — PYTHON`
    difficulty  1..5, shared
    story       one line, shared; the pack adds each speaker's sentence
    lead        the brief's opening paragraph, shared: what the idea is
    concepts    {lang: [slugs]} from docs/concepts.md
    cases       [(name, stdin, expect, visible)], shared
    example     the (input, output) shown in the brief; must be a visible case
    langs       {lang: Program}
    """

    def __init__(self, slug, title, difficulty, story, lead, concepts, cases, langs):
        self.slug, self.title, self.difficulty = slug, title, difficulty
        self.story, self.lead, self.concepts = story, lead, concepts
        self.cases, self.langs = cases, langs


class Program:
    """One language's half of a trio.

    explain      the brief's second paragraph: this language's construct
    solution     the finished program
    hole         the consecutive solution lines the BASIC starter takes out
                 (exact, with their indentation); one to four
    fill         the `FILL:` comment's text
    placeholder  lines the BASIC starter puts where the hole was, so it
                 still compiles and runs — and fails; may be empty
    quiz         the one hole line VERY BASIC asks about
    wrong        three lines that are not it; two are the other languages'
    quiz_placeholder  what VERY BASIC's starter has where the line was,
                 when its plain absence would not fail the tests
    hints        two or three, BASIC's; VERY BASIC uses the first two
    ask          VERY BASIC's paragraph in place of `explain`, for a
                 construct whose explanation cannot help quoting the line:
                 the quiz must not give its answer away (verify_pack)
    """

    def __init__(self, explain, solution, hole, fill, placeholder, quiz, wrong, hints, ask=None, quiz_placeholder=()):
        self.explain, self.solution = explain, solution.strip("\n") + "\n"
        self.hole, self.fill, self.placeholder = hole, fill, placeholder
        self.quiz, self.wrong, self.hints, self.ask = quiz, wrong, hints, ask
        # Where the quiz starter's line was: nothing, usually, and the program
        # fails to build or run without it. A line whose absence changes
        # nothing the tests can see (Python's `with lock:` — the block still
        # runs, only unlocked, and the GIL usually hides it) gets a stand-in
        # that fails for certain.
        self.quiz_placeholder = list(quiz_placeholder)
        assert 1 <= len(hole) <= 4, hole
        assert quiz in hole, (quiz, hole)
        assert len(wrong) == 3, wrong
        assert 2 <= len(hints) <= 3
        if quiz.strip() in explain:
            assert ask and quiz.strip() not in ask, f"explain quotes the quiz line; give an ask: {quiz.strip()}"


# ---------------------------------------------------------------- helpers
def toml_lit(s):
    """A TOML literal string. Code holds backslashes; SPEC §12 says '''."""
    assert "'''" not in s, "a ''' inside code would end the literal"
    return "'''\n" + s.rstrip("\n") + "\n'''"


def toml_str(s):
    """A one-line basic string, escaped."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def toml_list(items):
    return "[" + ", ".join(toml_str(i) for i in items) + "]"


def indent_of(line):
    return line[: len(line) - len(line.lstrip())]


def find_block(lines, hole):
    """Where the hole's lines sit in the solution, as a contiguous run."""
    n = len(hole)
    for i in range(len(lines) - n + 1):
        if lines[i : i + n] == hole:
            return i
    raise SystemExit(f"hole not found in solution:\n" + "\n".join(hole))


def basic_starter(lang, prog):
    lines = prog.solution.rstrip("\n").split("\n")
    at = find_block(lines, prog.hole)
    ind = indent_of(prog.hole[0])
    c = COMMENT[lang]
    block = [f"{ind}{c} FILL: {prog.fill}"]
    block += [f"{ind}{c} ANSWER: {h.strip()}" for h in prog.hole]
    block += prog.placeholder
    return "\n".join(lines[:at] + block + lines[at + len(prog.hole) :]) + "\n"


def quiz_pair(lang, prog):
    """VERY BASIC's (starter, solution): the FILL comment above the one line
    in the solution, and the line gone from the starter."""
    lines = prog.solution.rstrip("\n").split("\n")
    at = lines.index(prog.quiz)
    ind = indent_of(prog.quiz)
    c = COMMENT[lang]
    fill = f"{ind}{c} FILL: {prog.fill}"
    solution = lines[:at] + [fill, prog.quiz] + lines[at + 1 :]
    starter = lines[:at] + [fill] + prog.quiz_placeholder + lines[at + 1 :]
    return "\n".join(starter) + "\n", "\n".join(solution) + "\n"


def map_points(n):
    """A serpentine over the plate: an odd number of rows, so the walk that
    starts at the top-left corner ends at the bottom-right one — where both
    plates put the big café the boss sits outside — with a zig on every node
    so every node is a turn (verify_pack wants at least n/2), nothing under
    0.06 apart, and the last row spread across the full width however few
    nodes it has."""
    rows = 7
    per = max(2, math.ceil(n / rows))
    pts = []
    for i in range(n):
        row, col = divmod(i, per)
        in_row = min(per, n - row * per)
        if row % 2:
            col = in_row - 1 - col
        x = 0.05 + 0.90 * col / (in_row - 1) if in_row > 1 else 0.95
        y = 0.09 + 0.82 * row / (rows - 1)
        zig = 0.03 if (i % 2 == 0) else -0.03
        y += zig
        pts.append((round(x, 3), round(min(max(y, 0.04), 0.96), 3)))
    return pts


# ---------------------------------------------------------------- the trios
TRIOS = []


def trio(*a, **k):
    TRIOS.append(Trio(*a, **k))


# ---------------------------------------------------------------- 1 numbers
trio(
    "numbers",
    "INTEGER AND FLOAT",
    1,
    "Table one. Two numbers on the order slip, and the bill has to be split: "
    "how many each, what is left over, and the exact share to the cent.",
    "An integer and a float are different types, and dividing two integers "
    "gives an integer: the quotient, rounded toward zero, with the remainder "
    "left for `%`. To get the exact share you convert first and divide after. "
    "The program reads `a` and `b`, prints their sum, then the quotient and "
    "remainder on one line, then `a / b` as a float with two decimals.",
    {
        "go": ["types", "io"],
        "rust": ["types", "io"],
        "python": ["types", "io"],
    },
    [
        ("seven-two", "7 2\n", "9\n3 1\n3.50\n", True),
        ("exact", "9 3\n", "12\n3 0\n3.00\n", False),
        ("small", "1 4\n", "5\n0 1\n0.25\n", False),
        ("big", "1000000007 13\n", "1000000020\n76923077 6\n76923077.46\n", False),
    ],
    {
        "go": Program(
            "In Go `/` on two `int64` values is integer division and `%` the "
            "remainder. `float64(a)` is the conversion — a function-shaped cast "
            "— and only once both sides are `float64` does `/` divide exactly. "
            "`%.2f` in `Printf` prints two decimals.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	var a, b int64
	fmt.Fscan(reader, &a, &b)

	fmt.Println(a + b)
	q := a / b
	r := a % b
	f := float64(a) / float64(b)
	fmt.Println(q, r)
	fmt.Printf("%.2f\n", f)
}
""",
            ["\tq := a / b", "\tr := a % b", "\tf := float64(a) / float64(b)"],
            "quotient, remainder, and the exact share as a float64",
            ["\tq, r, f := int64(0), int64(0), 0.0"],
            "\tf := float64(a) / float64(b)",
            ["f := a / b", "let f = a as f64 / b as f64;", "f = a / b"],
            [
                "q := a / b then r := a % b — both stay int64; f := float64(a) / float64(b) converts before dividing.",
                "float64(a) / b does not compile: Go never mixes int64 and float64 in one expression.",
                "Converting the quotient afterwards — float64(a / b) — gives 3.00, not 3.50; the rounding has already happened.",
            ],
        ),
        "rust": Program(
            "In Rust `/` on two `i64` values is integer division and `%` the "
            "remainder. `a as f64` is the conversion, and it binds tighter than "
            "`/`, so `a as f64 / b as f64` divides two floats. `{:.2}` in "
            "`println!` prints two decimals.",
            """
use std::io::Read;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let nums: Vec<i64> = input.split_whitespace().map(|t| t.parse().unwrap()).collect();
    let (a, b) = (nums[0], nums[1]);

    println!("{}", a + b);
    let q = a / b;
    let r = a % b;
    let f = a as f64 / b as f64;
    println!("{} {}", q, r);
    println!("{:.2}", f);
}
""",
            ["    let q = a / b;", "    let r = a % b;", "    let f = a as f64 / b as f64;"],
            "quotient, remainder, and the exact share as an f64",
            ["    let (q, r, f) = (0i64, 0i64, 0.0f64);"],
            "    let f = a as f64 / b as f64;",
            ["let f = a / b;", "f := float64(a) / float64(b)", "f = a / b"],
            [
                "let q = a / b; then let r = a % b; — both i64; let f = a as f64 / b as f64; converts before dividing.",
                "a as f64 / b does not compile: an f64 cannot be divided by an i64.",
                "(a / b) as f64 gives 3.00, not 3.50; the integer division already rounded.",
            ],
        ),
        "python": Program(
            "In Python `/` always gives a float, even for two ints, so the "
            "exact share needs no conversion at all. The integer quotient is "
            "the *other* operator, `//`, and `%` is the remainder. "
            "`f\"{f:.2f}\"` prints two decimals.",
            """
import sys


def main():
    a, b = (int(t) for t in sys.stdin.read().split())

    print(a + b)
    q = a // b
    r = a % b
    f = a / b
    print(q, r)
    print(f"{f:.2f}")


main()
""",
            ["    q = a // b", "    r = a % b", "    f = a / b"],
            "quotient, remainder, and the exact share as a float",
            ["    q, r, f = 0, 0, 0.0"],
            "    f = a / b",
            ["f = a // b", "let f = a as f64 / b as f64;", "f := float64(a) / float64(b)"],
            [
                "q = a // b then r = a % b for the integers; f = a / b is already a float.",
                "float(a) / b works too, and is what a Go or Rust hand types; in Python it is not needed.",
                "Mind the sign: -7 // 2 is -4 in Python (floor), where Go and Rust give -3 (toward zero). Same operator name, different rounding — the tests here stay positive.",
            ],
        ),
    },
)


# ---------------------------------------------------------------- 2 strings
trio(
    "strings",
    "THE STRING",
    1,
    "The order slip is one line of names with commas between them, and the "
    "kitchen wants them shouted, separated, and counted by the letter.",
    "A string is split into pieces on a separator, the pieces are joined "
    "back with another, and a whole string is upper-cased in one call. "
    "Length is the trap: a name with an accent is more bytes than "
    "characters, and only one of the two is what a person would count. The "
    "program reads one line of comma-separated names, prints how many, "
    "the names upper-cased and joined with ` | `, and the character count "
    "of the line.",
    {
        "go": ["strings", "slices"],
        "rust": ["strings", "slices"],
        "python": ["strings", "slices"],
    },
    [
        ("three", "Mei,Bo,Alex\n", "3\nMEI | BO | ALEX\n11\n", True),
        ("accent", "Zoë,Ng\n", "2\nZOË | NG\n6\n", False),
        ("solo", "Solo\n", "1\nSOLO\n4\n", False),
    ],
    {
        "go": Program(
            "In Go the `strings` package does the work: `strings.Split` gives a "
            "`[]string`, `strings.Join` takes one back, `strings.ToUpper` "
            "returns a new string. `len(s)` is bytes; the character count is "
            "`utf8.RuneCountInString(s)`, because a Go string is bytes and a "
            "rune is what it decodes to.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"unicode/utf8"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	line, _ := reader.ReadString('\n')
	line = strings.TrimSpace(line)

	names := strings.Split(line, ",")
	joined := strings.ToUpper(strings.Join(names, " | "))
	chars := utf8.RuneCountInString(line)
	fmt.Println(len(names))
	fmt.Println(joined)
	fmt.Println(chars)
}
""",
            ["\tnames := strings.Split(line, \",\")", "\tjoined := strings.ToUpper(strings.Join(names, \" | \"))", "\tchars := utf8.RuneCountInString(line)"],
            "split on the comma, join upper-cased with \" | \", count the characters",
            ["\tnames, joined, chars := []string{line}, strings.ToUpper(line), utf8.RuneCountInString(\"\")"],
            "\tchars := utf8.RuneCountInString(line)",
            ["chars := len(line)", "let chars = line.chars().count();", "chars = len(line)"],
            [
                "strings.Split(line, \",\") then strings.ToUpper(strings.Join(names, \" | \")); the count is utf8.RuneCountInString(line).",
                "len(line) is bytes: Zoë is four of them and three characters, and the hidden case knows.",
                "Split and Join both take the separator last; ToUpper takes the whole string and hands a new one back.",
            ],
        ),
        "rust": Program(
            "In Rust `split(',')` is an iterator, so it is `collect`ed into a "
            "`Vec<&str>`; `join(\" | \")` on the vec makes a `String`, and "
            "`to_uppercase()` makes another. `len()` is bytes; the character "
            "count is `chars().count()`, because a `&str` is UTF-8 bytes and "
            "`chars()` decodes them.",
            r"""
use std::io::Read;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let line = input.trim();

    let names: Vec<&str> = line.split(',').collect();
    let joined = names.join(" | ").to_uppercase();
    let chars = line.chars().count();
    println!("{}", names.len());
    println!("{}", joined);
    println!("{}", chars);
}
""",
            ["    let names: Vec<&str> = line.split(',').collect();", "    let joined = names.join(\" | \").to_uppercase();", "    let chars = line.chars().count();"],
            "split on the comma, join upper-cased with \" | \", count the characters",
            ["    let (names, joined, chars): (Vec<&str>, String, usize) = (Vec::new(), String::new(), 0);"],
            "    let chars = line.chars().count();",
            ["let chars = line.len();", "chars := utf8.RuneCountInString(line)", "chars = len(line)"],
            [
                "let names: Vec<&str> = line.split(',').collect(); then names.join(\" | \").to_uppercase(); the count is line.chars().count().",
                "line.len() is bytes: Zoë is four of them and three characters, and the hidden case knows.",
                "split gives an iterator and does nothing until collected; the Vec<&str> annotation tells collect what to build.",
            ],
        ),
        "python": Program(
            "In Python the methods are on the string: `line.split(\",\")` gives "
            "a list, `\" | \".join(names)` is called on the *separator*, and "
            "`.upper()` returns a new string. `len(s)` counts characters, not "
            "bytes, because a Python `str` is already decoded — the byte "
            "count would be `len(s.encode())`.",
            r"""
import sys


def main():
    line = sys.stdin.read().strip()

    names = line.split(",")
    joined = " | ".join(names).upper()
    chars = len(line)
    print(len(names))
    print(joined)
    print(chars)


main()
""",
            ["    names = line.split(\",\")", "    joined = \" | \".join(names).upper()", "    chars = len(line)"],
            "split on the comma, join upper-cased with \" | \", count the characters",
            ["    names, joined, chars = [], \"\", 0"],
            "    chars = len(line)",
            ["chars = len(line.encode())", "let chars = line.chars().count();", "chars := utf8.RuneCountInString(line)"],
            [
                "names = line.split(\",\") then \" | \".join(names).upper(); the count is len(line).",
                "len(line.encode()) is bytes: Zoë is four of them and three characters, and the hidden case knows.",
                "join is a method of the separator, not of the list: \" | \".join(names), never names.join(\" | \").",
            ],
        ),
    },
)

# ---------------------------------------------------------------- 3 loops
trio(
    "loops",
    "THE LOOP",
    1,
    "A regular counts how many times the kitchen halves or triples an "
    "order before it comes down to one, and how big it got on the way.",
    "A loop runs while a condition holds, a branch picks one of two "
    "arms, and a counter goes up by one each time round. The program reads "
    "`n` and walks it: even, halve it; odd, triple it and add one; stop at "
    "1. It prints the number of steps and the largest value seen.",
    {
        "go": ["control-flow", "bindings"],
        "rust": ["control-flow", "bindings"],
        "python": ["control-flow", "bindings"],
    },
    [
        ("six", "6\n", "8\n16\n", True),
        ("one", "1\n", "0\n1\n", False),
        ("twenty-seven", "27\n", "111\n9232\n", False),
    ],
    {
        "go": Program(
            "Go has one loop keyword. `for cond { }` is its while loop, and "
            "`steps++` is the increment statement — a statement, not an "
            "expression, so it cannot sit inside a larger one.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	var n int64
	fmt.Fscan(reader, &n)

	steps := 0
	peak := n
	for n != 1 {
		steps++
		if n%2 == 0 {
			n /= 2
		} else {
			n = 3*n + 1
		}
		if n > peak {
			peak = n
		}
	}
	fmt.Println(steps)
	fmt.Println(peak)
}
""",
            ["\tfor n != 1 {", "\t\tsteps++"],
            "loop until n is 1, counting each step",
            ["\tfor n != n {"],
            "\tfor n != 1 {",
            ["for n == 1 {", "while n != 1 {", "while n != 1:"],
            [
                "for n != 1 { — Go's while — then steps++ as the first line inside.",
                "There is no while in Go; for with one condition is it.",
                "steps++ is a statement on its own line; fmt.Println(steps++) does not compile.",
            ],
        ),
        "rust": Program(
            "Rust spells it `while cond { }`, and the increment is `steps += 1;` "
            "— there is no `++`. The `if` inside is an expression too, which "
            "is why `n = if n % 2 == 0 { n / 2 } else { 3 * n + 1 };` would "
            "also work.",
            r"""
use std::io::Read;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let mut n: i64 = input.trim().parse().unwrap();

    let mut steps = 0;
    let mut peak = n;
    while n != 1 {
        steps += 1;
        if n % 2 == 0 {
            n /= 2;
        } else {
            n = 3 * n + 1;
        }
        if n > peak {
            peak = n;
        }
    }
    println!("{}", steps);
    println!("{}", peak);
}
""",
            ["    while n != 1 {", "        steps += 1;"],
            "loop until n is 1, counting each step",
            ["    while n != n {"],
            "    while n != 1 {",
            ["while n == 1 {", "for n != 1 {", "while n != 1:"],
            [
                "while n != 1 { then steps += 1; as the first line inside.",
                "steps++ is not Rust; += 1 is.",
                "n, steps and peak are all mut, because all three change.",
            ],
        ),
        "python": Program(
            "Python spells it `while cond:` with a colon and an indented "
            "body, and the increment is `steps += 1` — no `++`. The `if` / "
            "`else` inside take colons too; there are no braces anywhere.",
            r"""
import sys


def main():
    n = int(sys.stdin.read().strip())

    steps = 0
    peak = n
    while n != 1:
        steps += 1
        if n % 2 == 0:
            n //= 2
        else:
            n = 3 * n + 1
        if n > peak:
            peak = n
    print(steps)
    print(peak)


main()
""",
            ["    while n != 1:", "        steps += 1"],
            "loop until n is 1, counting each step",
            ["    while n != n:"],
            "    while n != 1:",
            ["while n == 1:", "for n != 1 {", "while n != 1 {"],
            [
                "while n != 1: then steps += 1 indented under it.",
                "A colon ends the while line; braces are a syntax error.",
                "n //= 2 keeps n an int; n /= 2 would make it a float and the loop would never reach exactly 1.",
            ],
        ),
    },
)

# ---------------------------------------------------------------- 4 closures
trio(
    "closures",
    "THE CLOSURE",
    2,
    "Every order gets a ticket number. The counter that hands them out "
    "lives inside the function that made it, and nobody else can touch it.",
    "A closure is a function that captures a variable from the scope it was "
    "made in and keeps it alive after that scope has returned. `counter()` "
    "makes one: each call to the closure it returns hands out the next "
    "number. The program reads words, numbers them from 1, then prints the "
    "number the closure would hand out next.",
    {
        "go": ["closures", "functions"],
        "rust": ["closures", "functions"],
        "python": ["closures", "functions"],
    },
    [
        ("three", "tea coffee milk\n", "1 tea\n2 coffee\n3 milk\n4\n", True),
        ("one", "bun\n", "1 bun\n2\n", False),
        ("five", "a b c d e\n", "1 a\n2 b\n3 c\n4 d\n5 e\n6\n", False),
    ],
    {
        "go": Program(
            "In Go a function literal `func() int { ... }` captures `n` by "
            "reference, so `n++` inside it changes the `n` outside, and "
            "`counter` returns the literal as a value of type `func() int`.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

func counter() func() int {
	n := 0
	return func() int {
		n++
		return n
	}
}

func main() {
	reader := bufio.NewReader(os.Stdin)
	line, _ := reader.ReadString('\n')
	words := strings.Fields(line)

	next := counter()
	for _, w := range words {
		fmt.Println(next(), w)
	}
	fmt.Println(next())
}
""",
            ["\treturn func() int {", "\t\tn++", "\t\treturn n", "\t}"],
            "return a closure that bumps n and hands it back",
            ["\treturn func() int { return n }"],
            "\treturn func() int {",
            ["return func() {", "move || {", "nonlocal n"],
            [
                "return func() int { n++; return n } across four lines — the literal captures n.",
                "The return type of counter is func() int, so the literal must say int too.",
                "n := 0 is outside the literal: inside it would reset on every call.",
            ],
        ),
        "rust": Program(
            "In Rust the closure is `|| { ... }`, and `move` makes it take "
            "`n` with it — without `move` it would borrow a local that is "
            "about to go out of scope. It mutates its capture, so the return "
            "type is `impl FnMut() -> i64`, and the caller binds it `mut`.",
            r"""
use std::io::Read;

fn counter() -> impl FnMut() -> i64 {
    let mut n = 0;
    move || {
        n += 1;
        n
    }
}

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let words: Vec<&str> = input.split_whitespace().collect();

    let mut next = counter();
    for w in &words {
        println!("{} {}", next(), w);
    }
    println!("{}", next());
}
""",
            ["    move || {", "        n += 1;", "        n", "    }"],
            "a move closure that bumps n and hands it back",
            ["    move || 0"],
            "    move || {",
            ["|| {", "return func() int {", "nonlocal n"],
            [
                "move || { n += 1; n } across four lines — move takes n into the closure.",
                "Without move the closure borrows n, and returning it is E0373: n does not live long enough.",
                "The closure changes n, so it is FnMut, and next must be let mut next.",
            ],
        ),
        "python": Program(
            "In Python the closure is an inner `def`. Reading `n` from the "
            "outer scope is free, but assigning to it makes a new local "
            "unless the inner function says `nonlocal n` first — that one "
            "word is the capture.",
            r"""
import sys


def counter():
    n = 0

    def next_id():
        nonlocal n
        n += 1
        return n

    return next_id


def main():
    words = sys.stdin.read().split()

    next_id = counter()
    for w in words:
        print(next_id(), w)
    print(next_id())


main()
""",
            ["    def next_id():", "        nonlocal n", "        n += 1", "        return n"],
            "an inner function that bumps the outer n and hands it back",
            ["    def next_id():", "        return 0"],
            "        nonlocal n",
            ["global n", "move || {", "return func() int {"],
            [
                "def next_id(): with nonlocal n, n += 1, return n under it — then counter returns next_id.",
                "Without nonlocal, n += 1 is UnboundLocalError: the assignment made a new local n before it was read.",
                "global n would look for a module-level n, which does not exist.",
            ],
            ask="In Python the closure is an inner `def`. Reading `n` from the outer "
            "scope is free, but assigning to it makes a new local — unless the "
            "inner function first declares, in one keyword, that `n` belongs to "
            "the enclosing scope. Which line is that declaration?",
        ),
    },
)

# ---------------------------------------------------------------- 5 structs
trio(
    "structs",
    "THE STRUCT",
    1,
    "Each line of the bill is a name, a price and a quantity, and the "
    "thing that knows how to total a line is the line itself.",
    "A struct groups named fields into one value, and a method is a "
    "function attached to that type with the value in hand as `self` / a "
    "receiver. The program reads lines of `name price qty`, and for each "
    "prints the name and the line total, then the grand total.",
    {
        "go": ["structs", "functions"],
        "rust": ["structs", "functions"],
        "python": ["structs", "functions"],
    },
    [
        ("two", "tea 12 3\nbun 8 2\n", "tea 36\nbun 16\n52\n", True),
        ("one", "milk 5 1\n", "milk 5\n5\n", False),
        ("three", "a 1 1\nb 2 2\nc 3 3\n", "a 1\nb 4\nc 9\n14\n", False),
    ],
    {
        "go": Program(
            "In Go a method is a function with a receiver before its name: "
            "`func (it Item) Total() int64`. The receiver is a copy of the "
            "struct; `(it *Item)` would be a pointer. Exported fields and "
            "methods start with a capital letter.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

type Item struct {
	Name  string
	Price int64
	Qty   int64
}

func (it Item) Total() int64 {
	return it.Price * it.Qty
}

func main() {
	reader := bufio.NewReader(os.Stdin)
	var items []Item
	for {
		line, err := reader.ReadString('\n')
		f := strings.Fields(line)
		if len(f) == 3 {
			var price, qty int64
			fmt.Sscan(f[1], &price)
			fmt.Sscan(f[2], &qty)
			items = append(items, Item{Name: f[0], Price: price, Qty: qty})
		}
		if err != nil {
			break
		}
	}

	var sum int64
	for _, it := range items {
		fmt.Println(it.Name, it.Total())
		sum += it.Total()
	}
	fmt.Println(sum)
}
""",
            ["func (it Item) Total() int64 {", "\treturn it.Price * it.Qty", "}"],
            "a Total method on Item: price times quantity",
            ["func (it Item) Total() int64 {", "\treturn 0", "}"],
            "func (it Item) Total() int64 {",
            ["func Total(it Item) int64 {", "fn total(&self) -> i64 {", "def total(self):"],
            [
                "func (it Item) Total() int64 { return it.Price * it.Qty } — the receiver goes in its own parentheses before the name.",
                "func Total(it Item) is a plain function; it.Total() would not find it.",
                "Item{Name: f[0], Price: price, Qty: qty} is how the struct is built, field by field.",
            ],
        ),
        "rust": Program(
            "In Rust methods live in an `impl Item { }` block, and `&self` "
            "says the method borrows the struct rather than taking it. "
            "`self.price * self.qty` is the body; the last expression is the "
            "return value, so there is no `return` and no semicolon.",
            r"""
use std::io::Read;

struct Item {
    name: String,
    price: i64,
    qty: i64,
}

impl Item {
    fn total(&self) -> i64 {
        self.price * self.qty
    }
}

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let mut items = Vec::new();
    for line in input.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() == 3 {
            items.push(Item {
                name: f[0].to_string(),
                price: f[1].parse().unwrap(),
                qty: f[2].parse().unwrap(),
            });
        }
    }

    let mut sum = 0;
    for it in &items {
        println!("{} {}", it.name, it.total());
        sum += it.total();
    }
    println!("{}", sum);
}
""",
            ["impl Item {", "    fn total(&self) -> i64 {", "        self.price * self.qty", "    }"],
            "an impl block with a total method: price times quantity",
            ["impl Item {", "    fn total(&self) -> i64 {", "        0", "    }"],
            "    fn total(&self) -> i64 {",
            ["fn total(self) -> i64 {", "func (it Item) Total() int64 {", "def total(self):"],
            [
                "impl Item { fn total(&self) -> i64 { self.price * self.qty } } — &self borrows, and the body is one expression.",
                "fn total(self) takes the Item by value, and calling it through &items is E0507: cannot move out of a borrow.",
                "Item { name: f[0].to_string(), price: .., qty: .. } builds the struct; &str must become String for the owned field.",
            ],
        ),
        "python": Program(
            "In Python a class holds the fields set in `__init__` and the "
            "methods under it; every method takes `self` first, explicitly, "
            "and `self.price * self.qty` reads the fields through it.",
            r"""
import sys


class Item:
    def __init__(self, name, price, qty):
        self.name = name
        self.price = price
        self.qty = qty

    def total(self):
        return self.price * self.qty


def main():
    items = []
    for line in sys.stdin.read().splitlines():
        f = line.split()
        if len(f) == 3:
            items.append(Item(f[0], int(f[1]), int(f[2])))

    total = 0
    for it in items:
        print(it.name, it.total())
        total += it.total()
    print(total)


main()
""",
            ["    def total(self):", "        return self.price * self.qty"],
            "a total method: price times quantity",
            ["    def total(self):", "        return 0"],
            "    def total(self):",
            ["def total():", "fn total(&self) -> i64 {", "func (it Item) Total() int64 {"],
            [
                "def total(self): with return self.price * self.qty under it — self is written, never implied.",
                "def total(): without self is TypeError at the call: it.total() passes the item as the first argument.",
                "Item(f[0], int(f[1]), int(f[2])) calls __init__; the fields are whatever __init__ assigned to self.",
            ],
        ),
    },
)

# ---------------------------------------------------------------- 6 enums
trio(
    "enums",
    "THE ENUM",
    2,
    "The light over the pass is red, green or yellow, and the wait in "
    "seconds depends on which — a closed set of cases, and a branch over "
    "every one of them.",
    "An enum is a type with a fixed set of named values, and a match over "
    "one names each case and picks a result for it. The program reads "
    "light names, turns each into the enum, and prints the name with the "
    "seconds to wait: red 30, green 25, yellow 5.",
    {
        "go": ["enums", "pattern-matching"],
        "rust": ["enums", "pattern-matching"],
        "python": ["enums", "pattern-matching"],
    },
    [
        ("four", "red green yellow green\n", "red 30\ngreen 25\nyellow 5\ngreen 25\n", True),
        ("one", "yellow\n", "yellow 5\n", False),
        ("reds", "red red\n", "red 30\nred 30\n", False),
    ],
    {
        "go": Program(
            "Go has no enum keyword: a named integer type and a `const` block "
            "with `iota` make one — `Red`, `Green`, `Yellow` are 0, 1, 2. The "
            "branch is a `switch` with one `case` per value; there is no "
            "fall-through, and `default` catches the rest.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

type Light int

const (
	Red Light = iota
	Green
	Yellow
)

func parse(s string) Light {
	switch s {
	case "red":
		return Red
	case "green":
		return Green
	}
	return Yellow
}

func seconds(l Light) int {
	switch l {
	case Red:
		return 30
	case Green:
		return 25
	default:
		return 5
	}
}

func main() {
	reader := bufio.NewReader(os.Stdin)
	line, _ := reader.ReadString('\n')

	for _, w := range strings.Fields(line) {
		fmt.Println(w, seconds(parse(w)))
	}
}
""",
            ["\tcase Red:", "\t\treturn 30", "\tcase Green:", "\t\treturn 25"],
            "the red and green cases of the switch",
            [],
            "\tcase Red:",
            ["case \"red\":", "Light::Red => 30,", "case Light.RED:"],
            [
                "case Red: return 30, then case Green: return 25 — one case per constant, no break needed.",
                "case \"red\" compares a Light with a string, which does not compile; the switch is over the enum, not the word.",
                "iota starts at 0 in a const block and counts up one line at a time.",
            ],
        ),
        "rust": Program(
            "Rust has `enum Light { Red, Green, Yellow }`, and `match` over it "
            "must name every variant: `Light::Red => 30,` is one arm, an "
            "expression each, and leaving one out is a compile error, which "
            "is the point.",
            r"""
use std::io::Read;

enum Light {
    Red,
    Green,
    Yellow,
}

fn parse(s: &str) -> Light {
    match s {
        "red" => Light::Red,
        "green" => Light::Green,
        _ => Light::Yellow,
    }
}

fn seconds(l: Light) -> i64 {
    match l {
        Light::Red => 30,
        Light::Green => 25,
        Light::Yellow => 5,
    }
}

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();

    for w in input.split_whitespace() {
        println!("{} {}", w, seconds(parse(w)));
    }
}
""",
            ["        Light::Red => 30,", "        Light::Green => 25,", "        Light::Yellow => 5,"],
            "one arm per variant",
            ["        _ => 0,"],
            "        Light::Red => 30,",
            ["Light::Red => 25,", "case Red:", "case Light.RED:"],
            [
                "Light::Red => 30, Light::Green => 25, Light::Yellow => 5 — three arms, a comma after each.",
                "Miss a variant and rustc says E0004: non-exhaustive patterns. It is checking for you.",
                "The variant is written with its type: Light::Red, never bare Red, unless you use Light::*.",
            ],
            ask="Rust has `enum Light { Red, Green, Yellow }`, and `match` over it "
            "must name every variant: one arm each, the variant written with its "
            "type on the left of `=>` and the result on the right, a comma after. "
            "Which line is the arm that gives red its thirty seconds?",
        ),
        "python": Program(
            "Python's `enum.Enum` gives `Light.RED`, `Light.GREEN`, "
            "`Light.YELLOW`, and `match l:` with `case Light.RED:` picks one. "
            "The dotted name matters: a bare `case RED:` is a capture pattern "
            "that matches anything and binds it, which is a syntax error "
            "when a later case can never be reached.",
            r"""
import sys
from enum import Enum


class Light(Enum):
    RED = 0
    GREEN = 1
    YELLOW = 2


def parse(s):
    if s == "red":
        return Light.RED
    if s == "green":
        return Light.GREEN
    return Light.YELLOW


def seconds(l):
    match l:
        case Light.RED:
            return 30
        case Light.GREEN:
            return 25
        case _:
            return 5


def main():
    for w in sys.stdin.read().split():
        print(w, seconds(parse(w)))


main()
""",
            ["        case Light.RED:", "            return 30", "        case Light.GREEN:", "            return 25"],
            "the red and green cases of the match",
            [],
            "        case Light.RED:",
            ["case Light.GREEN:", "case Red:", "Light::Red => 30,"],
            [
                "case Light.RED: return 30, then case Light.GREEN: return 25 — dotted, so they are value patterns.",
                "case Red: binds the name Red to anything, and Python refuses it: the cases after it are unreachable.",
                "case _: is the default arm, and match needs no break.",
            ],
            ask="Python's `enum.Enum` gives `Light.RED`, `Light.GREEN` and "
            "`Light.YELLOW`, and `match l:` picks one with a `case` per value. "
            "The dotted name matters: a bare name after `case` is a capture "
            "pattern that matches anything, and Python refuses it because the "
            "cases after it could never run. Which line is the red case?",
        ),
    },
)

# ---------------------------------------------------------------- 7 errors
trio(
    "errors",
    "THE ERROR",
    2,
    "Some of the numbers on the slip are not numbers. The till adds the "
    "ones that are and calls out the ones that are not, and does not fall "
    "over.",
    "Parsing can fail, and each language hands the failure back "
    "differently: as a second return value, as a `Result`, or as an "
    "exception. The program reads tokens, adds up the ones that parse as "
    "integers, prints `bad: <token>` for each that does not, and then the "
    "total.",
    {
        "go": ["error-handling", "control-flow"],
        "rust": ["error-handling", "pattern-matching"],
        "python": ["error-handling", "control-flow"],
    },
    [
        ("mixed", "12 x 30 4y 8\n", "bad: x\nbad: 4y\n50\n", True),
        ("clean", "1 2 3\n", "6\n", False),
        ("all-bad", "a b\n", "bad: a\nbad: b\n0\n", False),
    ],
    {
        "go": Program(
            "In Go `strconv.ParseInt` returns the value *and* an `error`, and "
            "the check is the idiom of the whole language: `if err != nil { "
            "... continue }`. Nothing is thrown; the error is a value you "
            "look at, right after the call.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	line, _ := reader.ReadString('\n')

	var total int64
	for _, t := range strings.Fields(line) {
		v, err := strconv.ParseInt(t, 10, 64)
		if err != nil {
			fmt.Println("bad:", t)
			continue
		}
		total += v
	}
	fmt.Println(total)
}
""",
            ["\t\tv, err := strconv.ParseInt(t, 10, 64)", "\t\tif err != nil {", "\t\t\tfmt.Println(\"bad:\", t)", "\t\t\tcontinue"],
            "parse t; on error say so and skip it",
            ["\t\tv, err := strconv.ParseInt(t[:0], 10, 64)", "\t\tif err != nil {"],
            "\t\tif err != nil {",
            ["if err == nil {", "let Ok(v) = t.parse::<i64>() else {", "except ValueError:"],
            [
                "v, err := strconv.ParseInt(t, 10, 64) then if err != nil { fmt.Println(\"bad:\", t); continue }.",
                "The 10 is the base and the 64 the bit size; v is an int64.",
                "err == nil is the success case; the branch that skips is the other one.",
            ],
            ask="In Go `strconv.ParseInt` returns the value *and* an `error`, and "
            "the check right after the call is the idiom of the whole language: "
            "compare the error with `nil`, and on the wrong side of that "
            "comparison say so and skip. Nothing is thrown. Which line is the "
            "check?",
        ),
        "rust": Program(
            "In Rust `t.parse::<i64>()` returns a `Result`, and `let Ok(v) = "
            "... else { ... };` takes the value out or runs the `else` — "
            "which must leave (`continue`, `return`, `break`). A `match` "
            "with `Ok` and `Err` arms is the longer spelling of the same "
            "thing.",
            r"""
use std::io::Read;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();

    let mut total: i64 = 0;
    for t in input.split_whitespace() {
        let Ok(v) = t.parse::<i64>() else {
            println!("bad: {}", t);
            continue;
        };
        total += v;
    }
    println!("{}", total);
}
""",
            ["        let Ok(v) = t.parse::<i64>() else {", "            println!(\"bad: {}\", t);", "            continue;", "        };"],
            "parse t; on Err say so and skip it",
            ["        let v = 0i64;"],
            "        let Ok(v) = t.parse::<i64>() else {",
            ["let Err(v) = t.parse::<i64>() else {", "if err != nil {", "except ValueError:"],
            [
                "let Ok(v) = t.parse::<i64>() else { println!(\"bad: {}\", t); continue; }; — note the semicolon after the else block.",
                "The else of a let-else must diverge: continue, break or return. Falling through is E0308.",
                "parse::<i64> is the turbofish: it tells parse what to make, since v is not annotated.",
            ],
        ),
        "python": Program(
            "In Python `int(t)` raises `ValueError` on a bad token, and "
            "`try:` / `except ValueError:` catches exactly that one — the "
            "add goes in the `try`, the message in the `except`, and the "
            "loop simply goes round again.",
            r"""
import sys


def main():
    total = 0
    for t in sys.stdin.read().split():
        try:
            total += int(t)
        except ValueError:
            print("bad:", t)
    print(total)


main()
""",
            ["        try:", "            total += int(t)", "        except ValueError:", "            print(\"bad:\", t)"],
            "add int(t); on ValueError say so",
            ["        total += 0"],
            "        except ValueError:",
            ["except TypeError:", "if err != nil {", "let Ok(v) = t.parse::<i64>() else {"],
            [
                "try: total += int(t) then except ValueError: print(\"bad:\", t) — four lines, two colons.",
                "except TypeError: does not catch it; int(\"x\") raises ValueError, and the wrong class lets it through.",
                "A bare except: would catch everything, including the KeyboardInterrupt; name the class.",
            ],
            ask="In Python `int(t)` raises `ValueError` on a bad token, and a "
            "`try:` block with a clause naming exactly that class catches it — "
            "the add goes in the `try`, the message under the clause, and the "
            "loop simply goes round again. Which line is the clause?",
        ),
    },
)



# ---------------------------------------------------------------- 8 list
trio(
    "list",
    "THE LIST",
    1,
    "The queue at the counter: one more joins at the back, the front is "
    "served, and the manager wants to see who is second and third.",
    "A growable sequence: push on the end, take off the front, index the "
    "last, and cut a sub-range out. The program reads numbers into a "
    "list, appends 100, removes the first, then prints the last element, "
    "the elements at positions 1 and 2, and the length.",
    {
        "go": ["slices", "iteration"],
        "rust": ["slices", "iteration"],
        "python": ["slices", "iteration"],
    },
    [
        ("four", "5 6 7 8\n", "100\n7 8\n4\n", True),
        ("three", "1 2 3\n", "100\n3 100\n3\n", False),
        ("five", "9 8 7 6 5\n", "100\n7 6\n5\n", False),
    ],
    {
        "go": Program(
            "In Go the list is a slice. `append` returns the grown slice and "
            "must be assigned back; `nums[1:]` drops the front by re-slicing; "
            "`nums[len(nums)-1]` is the last — there are no negative indexes "
            "— and `nums[1:3]` is a sub-slice that shares the array.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	var nums []int64
	for {
		var x int64
		if _, err := fmt.Fscan(reader, &x); err != nil {
			break
		}
		nums = append(nums, x)
	}

	nums = append(nums, 100)
	nums = nums[1:]
	last := nums[len(nums)-1]
	mid := nums[1:3]
	fmt.Println(last)
	for _, x := range mid {
		fmt.Print(x, " ")
	}
	fmt.Println()
	fmt.Println(len(nums))
}
""",
            ["\tnums = append(nums, 100)", "\tnums = nums[1:]", "\tlast := nums[len(nums)-1]", "\tmid := nums[1:3]"],
            "append 100, drop the front, take the last, slice positions 1 and 2",
            ["\tlast, mid := int64(0), nums[:0]"],
            "\tnums = append(nums, 100)",
            ["append(nums, 100)", "nums.push(100);", "nums.append(100)"],
            [
                "nums = append(nums, 100); nums = nums[1:]; last := nums[len(nums)-1]; mid := nums[1:3].",
                "append(nums, 100) on its own does not compile: the result is unused, and the slice it returns is the grown one.",
                "nums[1:3] is positions 1 and 2 — the end is exclusive, as everywhere in this land.",
            ],
        ),
        "rust": Program(
            "In Rust the list is a `Vec`. `push` grows it in place, `remove(0)` "
            "takes the front, `nums[nums.len() - 1]` is the last (or "
            "`*nums.last().unwrap()`), and `&nums[1..3]` is a slice borrowed "
            "from it — a `&[i64]`, not a copy.",
            r"""
use std::io::Read;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let mut nums: Vec<i64> = input.split_whitespace().map(|t| t.parse().unwrap()).collect();

    nums.push(100);
    nums.remove(0);
    let last = nums[nums.len() - 1];
    let mid = &nums[1..3];
    println!("{}", last);
    for x in mid {
        print!("{} ", x);
    }
    println!();
    println!("{}", nums.len());
}
""",
            ["    nums.push(100);", "    nums.remove(0);", "    let last = nums[nums.len() - 1];", "    let mid = &nums[1..3];"],
            "push 100, remove the front, take the last, slice positions 1 and 2",
            ["    let (last, mid) = (0i64, &nums[..0]);"],
            "    nums.push(100);",
            ["nums.append(100);", "nums = append(nums, 100)", "nums.push_back(100);"],
            [
                "nums.push(100); nums.remove(0); let last = nums[nums.len() - 1]; let mid = &nums[1..3];",
                "append in Rust takes another Vec and moves its elements over; a single value is push.",
                "&nums[1..3] borrows; without the & it is E0277, because a slice has no size to move.",
            ],
        ),
        "python": Program(
            "In Python the list is `list`. `append` grows it, `pop(0)` takes "
            "the front, `nums[-1]` is the last — negative indexes count from "
            "the end — and `nums[1:3]` is a new list holding positions 1 and "
            "2.",
            r"""
import sys


def main():
    nums = [int(t) for t in sys.stdin.read().split()]

    nums.append(100)
    nums.pop(0)
    last = nums[-1]
    mid = nums[1:3]
    print(last)
    print(*mid)
    print(len(nums))


main()
""",
            ["    nums.append(100)", "    nums.pop(0)", "    last = nums[-1]", "    mid = nums[1:3]"],
            "append 100, pop the front, take the last, slice positions 1 and 2",
            ["    last, mid = 0, nums[:0]"],
            "    nums.append(100)",
            ["nums += 100", "nums.push(100);", "nums = append(nums, 100)"],
            [
                "nums.append(100); nums.pop(0); last = nums[-1]; mid = nums[1:3].",
                "nums += 100 is TypeError: += on a list wants another iterable, and 100 is not one.",
                "nums[1:3] copies; changing mid afterwards would leave nums alone, unlike Go's shared array.",
            ],
        ),
    },
)

# ---------------------------------------------------------------- 9 map
trio(
    "map",
    "THE MAP",
    1,
    "The tally board by the till: every order bumps its dish's count, and "
    "the board says the count as it happens.",
    "A map goes from a key to a value, and the whole trick is what happens "
    "on a key that is not there yet. The program reads words; for each, "
    "it bumps that word's count and prints the word with its count so far, "
    "then prints how many distinct words there were.",
    {
        "go": ["collections", "strings"],
        "rust": ["collections", "strings"],
        "python": ["collections", "strings"],
    },
    [
        ("five", "tea bun tea milk tea\n", "tea 1\nbun 1\ntea 2\nmilk 1\ntea 3\n3\n", True),
        ("one", "bun\n", "bun 1\n1\n", False),
        ("repeat", "a a a\n", "a 1\na 2\na 3\n1\n", False),
    ],
    {
        "go": Program(
            "In Go a missing key reads as the zero value, so `counts[w]++` "
            "works on the first sight of `w`: it reads 0, adds one, stores 1. "
            "`counts[w]` reads it back, and `len(counts)` is the number of "
            "keys.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	line, _ := reader.ReadString('\n')

	counts := map[string]int{}
	for _, w := range strings.Fields(line) {
		counts[w]++
		fmt.Println(w, counts[w])
	}
	fmt.Println(len(counts))
}
""",
            ["\t\tcounts[w]++", "\t\tfmt.Println(w, counts[w])"],
            "bump the word's count and print it",
            ["\t\tfmt.Println(w, 0)"],
            "\t\tcounts[w]++",
            ["counts[w] = 1", "*counts.entry(w.to_string()).or_insert(0) += 1;", "counts[w] = counts.get(w, 0) + 1"],
            [
                "counts[w]++ then fmt.Println(w, counts[w]) — a missing key is 0, so the increment just works.",
                "map[string]int{} is an empty map ready to write; a nil map (var counts map[string]int) panics on the first write.",
                "counts[w] = 1 never gets past one.",
            ],
            ask="In Go a missing key reads as the zero value, so the bump needs no "
            "check: read, add one, store — in Go's shortest spelling of one "
            "more. `counts[w]` reads it back, and `len(counts)` is the number "
            "of keys. Which line bumps the count?",
        ),
        "rust": Program(
            "In Rust a missing key is a question, and the entry API is the "
            "answer: `counts.entry(key).or_insert(0)` gives a `&mut` to the "
            "value, inserting 0 first if it must, and `*... += 1` writes "
            "through it. The key is a `String`, so `w.to_string()`; "
            "`counts[w]` reads it back.",
            r"""
use std::collections::HashMap;
use std::io::Read;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();

    let mut counts: HashMap<String, i64> = HashMap::new();
    for w in input.split_whitespace() {
        *counts.entry(w.to_string()).or_insert(0) += 1;
        println!("{} {}", w, counts[w]);
    }
    println!("{}", counts.len());
}
""",
            ["        *counts.entry(w.to_string()).or_insert(0) += 1;", "        println!(\"{} {}\", w, counts[w]);"],
            "bump the word's count through the entry API and print it",
            ["        println!(\"{} {}\", w, 0);"],
            "        *counts.entry(w.to_string()).or_insert(0) += 1;",
            ["counts[w] += 1;", "counts[w]++", "counts[w] = counts.get(w, 0) + 1"],
            [
                "*counts.entry(w.to_string()).or_insert(0) += 1; then println!(\"{} {}\", w, counts[w]);",
                "counts[w] += 1 is E0594: a HashMap can be indexed to read, never to write.",
                "The * dereferences the &mut i64 that or_insert hands back; without it there is nothing to add to.",
            ],
        ),
        "python": Program(
            "In Python a missing key is `KeyError` on read, so the bump asks "
            "`counts.get(w, 0)`, which returns the default instead, and "
            "stores one more. (`collections.Counter` and `defaultdict(int)` "
            "hide this line; this is what they hide.)",
            r"""
import sys


def main():
    counts = {}
    for w in sys.stdin.read().split():
        counts[w] = counts.get(w, 0) + 1
        print(w, counts[w])
    print(len(counts))


main()
""",
            ["        counts[w] = counts.get(w, 0) + 1", "        print(w, counts[w])"],
            "bump the word's count and print it",
            ["        print(w, 0)"],
            "        counts[w] = counts.get(w, 0) + 1",
            ["counts[w] += 1", "counts[w]++", "*counts.entry(w.to_string()).or_insert(0) += 1;"],
            [
                "counts[w] = counts.get(w, 0) + 1 then print(w, counts[w]).",
                "counts[w] += 1 is KeyError the first time w is seen: += reads before it writes.",
                "get takes the default as its second argument; counts.get(w) alone gives None, and None + 1 is TypeError.",
            ],
        ),
    },
)

# ---------------------------------------------------------------- 10 comprehension
trio(
    "comprehension",
    "THE COMPREHENSION",
    2,
    "Of the numbers on the slip, only the even ones are the kitchen's, "
    "and the kitchen wants each one squared, in one breath.",
    "Build a new list from an old one by keeping some elements and "
    "transforming each: a filter and a map in one expression. Python "
    "calls it a comprehension and has a syntax for it; Rust has an "
    "iterator chain that says the same thing; Go says it with a loop. "
    "The program reads numbers, makes the list of squares of the even "
    "ones, prints it, and prints its sum.",
    {
        "go": ["slices", "iteration"],
        "rust": ["iteration", "closures"],
        "python": ["comprehensions", "iteration"],
    },
    [
        ("six", "1 2 3 4 5 6\n", "4 16 36\n56\n", True),
        ("odd", "1 3 5\n", "\n0\n", False),
        ("even", "2 4\n", "4 16\n20\n", False),
    ],
    {
        "go": Program(
            "Go has no comprehension. The loop *is* the comprehension: "
            "`for _, x := range nums`, an `if` for the filter, and `append` "
            "for the map — four lines where Python has one, and every one "
            "of them plain.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	var nums []int64
	for {
		var x int64
		if _, err := fmt.Fscan(reader, &x); err != nil {
			break
		}
		nums = append(nums, x)
	}

	squares := []int64{}
	for _, x := range nums {
		if x%2 == 0 {
			squares = append(squares, x*x)
		}
	}
	var sum int64
	for _, s := range squares {
		fmt.Print(s, " ")
		sum += s
	}
	fmt.Println()
	fmt.Println(sum)
}
""",
            ["\tfor _, x := range nums {", "\t\tif x%2 == 0 {", "\t\t\tsquares = append(squares, x*x)", "\t\t}"],
            "the loop: keep the even ones, append each squared",
            ["\tfor range nums {"],
            "\t\t\tsquares = append(squares, x*x)",
            ["squares = append(squares, x)", "squares.append(x * x)", "squares.push(x * x);"],
            [
                "for _, x := range nums { if x%2 == 0 { squares = append(squares, x*x) } } — the filter is the if, the map is the append.",
                "squares := []int64{} starts empty and non-nil; append grows it.",
                "There is no map or filter in the standard library for slices on purpose; the loop is the idiom.",
            ],
        ),
        "rust": Program(
            "Rust's comprehension is an iterator chain: `.iter()` walks, "
            "`.filter(|x| ...)` keeps, `.map(|x| ...)` transforms, and "
            "`.collect()` builds the `Vec` — lazily, nothing runs until the "
            "`collect`. The closures see `&i64`, hence the `*x`.",
            r"""
use std::io::Read;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let nums: Vec<i64> = input.split_whitespace().map(|t| t.parse().unwrap()).collect();

    let squares: Vec<i64> = nums.iter().filter(|x| *x % 2 == 0).map(|x| x * x).collect();
    let mut sum = 0;
    for s in &squares {
        print!("{} ", s);
        sum += s;
    }
    println!();
    println!("{}", sum);
}
""",
            ["    let squares: Vec<i64> = nums.iter().filter(|x| *x % 2 == 0).map(|x| x * x).collect();"],
            "filter the even ones, map each to its square, collect",
            ["    let squares: Vec<i64> = Vec::new();"],
            "    let squares: Vec<i64> = nums.iter().filter(|x| *x % 2 == 0).map(|x| x * x).collect();",
            ["let squares: Vec<i64> = nums.iter().filter(|x| *x % 2 == 0).map(|x| x + x).collect();", "squares = [x * x for x in nums if x % 2 == 0]", "squares = append(squares, x*x)"],
            [
                "let squares: Vec<i64> = nums.iter().filter(|x| *x % 2 == 0).map(|x| x * x).collect();",
                "filter's closure gets a reference to a reference — &&i64 — which is why it is *x % 2 and not x % 2.",
                "collect needs to know what to build: the Vec<i64> annotation on the let is what tells it.",
            ],
        ),
        "python": Program(
            "Python's list comprehension is one expression: `[x * x for x "
            "in nums if x % 2 == 0]` — the map first, then the loop, then "
            "the filter, all inside the brackets. It reads like the sentence "
            "\"x squared, for each x in nums, if x is even\".",
            r"""
import sys


def main():
    nums = [int(t) for t in sys.stdin.read().split()]

    squares = [x * x for x in nums if x % 2 == 0]
    print(*squares)
    print(sum(squares))


main()
""",
            ["    squares = [x * x for x in nums if x % 2 == 0]"],
            "squares of the even ones, in one comprehension",
            ["    squares = []"],
            "    squares = [x * x for x in nums if x % 2 == 0]",
            ["squares = [x * x for x in nums if x % 2 == 1]", "let squares: Vec<i64> = nums.iter().filter(|x| *x % 2 == 0).map(|x| x * x).collect();", "squares = append(squares, x*x)"],
            [
                "squares = [x * x for x in nums if x % 2 == 0] — expression, for, if, in that order.",
                "The if at the end filters; an if before the for would be a conditional expression and need an else.",
                "print(*squares) unpacks the list into separate arguments, so the numbers come out space-separated.",
            ],
        ),
    },
)

# ---------------------------------------------------------------- 11 sorting
trio(
    "sorting",
    "THE SORT",
    2,
    "The leaderboard over the till: highest score first, and on a tie the "
    "name that comes first in the alphabet.",
    "Sorting by more than one key: the primary key descending, the tie "
    "broken by a secondary key ascending. The program reads `name score` "
    "lines and prints them sorted by score, highest first, then by name.",
    {
        "go": ["sorting", "closures", "structs"],
        "rust": ["sorting", "closures", "structs"],
        "python": ["sorting", "closures", "structs"],
    },
    [
        ("tie", "mei 90\nbo 85\nalex 90\n", "alex 90\nmei 90\nbo 85\n", True),
        ("one", "solo 1\n", "solo 1\n", False),
        ("all-tied", "c 5\na 5\nb 5\n", "a 5\nb 5\nc 5\n", False),
    ],
    {
        "go": Program(
            "In Go `slices.SortFunc` takes a comparison returning an int: "
            "negative, zero or positive. `cmp.Compare(b.Score, a.Score)` with "
            "the arguments swapped sorts descending, and `cmp.Or` falls "
            "through to the name comparison when the first is zero.",
            r"""
package main

import (
	"bufio"
	"cmp"
	"fmt"
	"os"
	"slices"
	"strings"
)

type Person struct {
	Name  string
	Score int64
}

func main() {
	reader := bufio.NewReader(os.Stdin)
	var people []Person
	for {
		line, err := reader.ReadString('\n')
		f := strings.Fields(line)
		if len(f) == 2 {
			var score int64
			fmt.Sscan(f[1], &score)
			people = append(people, Person{Name: f[0], Score: score})
		}
		if err != nil {
			break
		}
	}

	slices.SortFunc(people, func(a, b Person) int {
		return cmp.Or(cmp.Compare(b.Score, a.Score), cmp.Compare(a.Name, b.Name))
	})
	for _, p := range people {
		fmt.Println(p.Name, p.Score)
	}
}
""",
            ["\tslices.SortFunc(people, func(a, b Person) int {", "\t\treturn cmp.Or(cmp.Compare(b.Score, a.Score), cmp.Compare(a.Name, b.Name))", "\t})"],
            "sort by score descending, then name ascending",
            ["\tslices.SortFunc(people, func(a, b Person) int {", "\t\treturn cmp.Compare(a.Name, b.Name)", "\t})"],
            "\tslices.SortFunc(people, func(a, b Person) int {",
            ["slices.SortFunc(people, func(a, b Person) bool {", "people.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.name.cmp(&b.name)));", "people.sort(key=lambda p: (-p.score, p.name))"],
            [
                "slices.SortFunc(people, func(a, b Person) int { return cmp.Or(cmp.Compare(b.Score, a.Score), cmp.Compare(a.Name, b.Name)) }).",
                "The comparison returns an int, not a bool: that is the difference from the older sort.Slice.",
                "b before a in the first Compare is what makes it descending.",
            ],
        ),
        "rust": Program(
            "In Rust `sort_by` takes a closure returning an `Ordering`. "
            "`b.score.cmp(&a.score)` with the sides swapped is descending, and "
            "`.then_with(|| a.name.cmp(&b.name))` is the tie-break, run only "
            "when the first is `Equal`.",
            r"""
use std::io::Read;

struct Person {
    name: String,
    score: i64,
}

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let mut people = Vec::new();
    for line in input.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() == 2 {
            people.push(Person {
                name: f[0].to_string(),
                score: f[1].parse().unwrap(),
            });
        }
    }

    people.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.name.cmp(&b.name)));
    for p in &people {
        println!("{} {}", p.name, p.score);
    }
}
""",
            ["    people.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.name.cmp(&b.name)));"],
            "sort by score descending, then name ascending",
            ["    people.sort_by(|a, b| a.name.cmp(&b.name));"],
            "    people.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.name.cmp(&b.name)));",
            ["people.sort_by(|a, b| a.score.cmp(&b.score).then_with(|| a.name.cmp(&b.name)));", "slices.SortFunc(people, func(a, b Person) int {", "people.sort(key=lambda p: (-p.score, p.name))"],
            [
                "people.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.name.cmp(&b.name)));",
                "cmp takes a reference: b.score.cmp(&a.score), with the &.",
                "sort_by_key(|p| (std::cmp::Reverse(p.score), p.name.clone())) says the same thing with a key instead of a comparator.",
            ],
        ),
        "python": Program(
            "In Python `sort` takes a `key` function, and a tuple key sorts "
            "by its parts in order: `(-p.score, p.name)` — the negation makes "
            "the score descending, and the name breaks the tie ascending. "
            "No comparator; the key says it all.",
            r"""
import sys


class Person:
    def __init__(self, name, score):
        self.name = name
        self.score = score


def main():
    people = []
    for line in sys.stdin.read().splitlines():
        f = line.split()
        if len(f) == 2:
            people.append(Person(f[0], int(f[1])))

    people.sort(key=lambda p: (-p.score, p.name))
    for p in people:
        print(p.name, p.score)


main()
""",
            ["    people.sort(key=lambda p: (-p.score, p.name))"],
            "sort by score descending, then name ascending",
            ["    people.sort(key=lambda p: p.name)"],
            "    people.sort(key=lambda p: (-p.score, p.name))",
            ["people.sort(key=lambda p: (p.score, p.name))", "slices.SortFunc(people, func(a, b Person) int {", "people.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.name.cmp(&b.name)));"],
            [
                "people.sort(key=lambda p: (-p.score, p.name)) — a tuple key, descending by negation.",
                "reverse=True would flip the name too; negating only the score is what keeps the names ascending.",
                "sort sorts in place and returns None; sorted(people, key=...) is the copy.",
            ],
        ),
    },
)

# ---------------------------------------------------------------- 12 tree
trio(
    "tree",
    "THE TREE",
    3,
    "The order numbers go into a tree as they arrive, smaller to the left, "
    "larger to the right, and reading it in order reads them sorted.",
    "A binary search tree: every node has a value, a left child with "
    "smaller values and a right child with larger. Insert walks down and "
    "puts a new node where it finds nothing; an in-order walk prints "
    "sorted. The program reads numbers, inserts each, prints the in-order "
    "walk, and prints the height.",
    {
        "go": ["trees", "recursion", "structs"],
        "rust": ["trees", "recursion", "smart-pointers"],
        "python": ["trees", "recursion", "structs"],
    },
    [
        ("five", "5 3 8 1 4\n", "1 3 4 5 8\n3\n", True),
        ("chain", "1 2 3\n", "1 2 3\n3\n", False),
        ("one", "7\n", "7\n1\n", False),
    ],
    {
        "go": Program(
            "In Go a child is a `*Node`, and an empty child is `nil`. The base "
            "case of `insert` is the nil check: `if n == nil { return "
            "&Node{Val: v} }` — a new node, taken by address. Every other "
            "step recurses and reattaches.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
)

type Node struct {
	Val         int64
	Left, Right *Node
}

func insert(n *Node, v int64) *Node {
	if n == nil {
		return &Node{Val: v}
	}
	if v < n.Val {
		n.Left = insert(n.Left, v)
	} else {
		n.Right = insert(n.Right, v)
	}
	return n
}

func inorder(n *Node) {
	if n == nil {
		return
	}
	inorder(n.Left)
	fmt.Print(n.Val, " ")
	inorder(n.Right)
}

func height(n *Node) int {
	if n == nil {
		return 0
	}
	return 1 + max(height(n.Left), height(n.Right))
}

func main() {
	reader := bufio.NewReader(os.Stdin)
	var root *Node
	for {
		var x int64
		if _, err := fmt.Fscan(reader, &x); err != nil {
			break
		}
		root = insert(root, x)
	}

	inorder(root)
	fmt.Println()
	fmt.Println(height(root))
}
""",
            ["\tif n == nil {", "\t\treturn &Node{Val: v}", "\t}"],
            "the base case: an empty spot becomes a new node",
            ["\tif n == nil {", "\t\treturn nil", "\t}"],
            "\t\treturn &Node{Val: v}",
            ["return Node{Val: v}", "None => Some(Box::new(Node { val: v, left: None, right: None })),", "return Node(v)"],
            [
                "if n == nil { return &Node{Val: v} } — the & takes the address of the new struct.",
                "return Node{Val: v} is a value where a *Node is wanted, and does not compile.",
                "root starts as a nil *Node; the first insert returns the first node and root takes it.",
            ],
            ask="In Go a child is a `*Node`, and an empty child is `nil`. The base "
            "case of `insert` is the nil check: build a new node with `v` in it "
            "and return its address — a pointer, not a value. Which line returns "
            "the new node?",
        ),
        "rust": Program(
            "In Rust a child is `Option<Box<Node>>`: `None` for empty, a heap "
            "box for a node. `insert` takes the option and gives it back: the "
            "`None` arm builds `Some(Box::new(Node { val: v, left: None, "
            "right: None }))`, and the `Some(mut node)` arm recurses into "
            "one side and returns the node.",
            r"""
use std::io::Read;

struct Node {
    val: i64,
    left: Option<Box<Node>>,
    right: Option<Box<Node>>,
}

fn insert(n: Option<Box<Node>>, v: i64) -> Option<Box<Node>> {
    match n {
        None => Some(Box::new(Node { val: v, left: None, right: None })),
        Some(mut node) => {
            if v < node.val {
                node.left = insert(node.left.take(), v);
            } else {
                node.right = insert(node.right.take(), v);
            }
            Some(node)
        }
    }
}

fn inorder(n: &Option<Box<Node>>) {
    if let Some(node) = n {
        inorder(&node.left);
        print!("{} ", node.val);
        inorder(&node.right);
    }
}

fn height(n: &Option<Box<Node>>) -> i64 {
    match n {
        None => 0,
        Some(node) => 1 + height(&node.left).max(height(&node.right)),
    }
}

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let mut root: Option<Box<Node>> = None;
    for t in input.split_whitespace() {
        root = insert(root, t.parse().unwrap());
    }

    inorder(&root);
    println!();
    println!("{}", height(&root));
}
""",
            ["        None => Some(Box::new(Node { val: v, left: None, right: None })),"],
            "the base case: an empty spot becomes a boxed node",
            ["        None => None,"],
            "        None => Some(Box::new(Node { val: v, left: None, right: None })),",
            ["None => Box::new(Node { val: v, left: None, right: None }),", "return &Node{Val: v}", "return Node(v)"],
            [
                "None => Some(Box::new(Node { val: v, left: None, right: None })), — the Box puts it on the heap, the Some wraps it.",
                "Box::new alone is a Box<Node> where an Option<Box<Node>> is wanted: E0308.",
                "node.left.take() moves the child out and leaves None, so insert can own it and hand it back.",
            ],
        ),
        "python": Program(
            "In Python a child is either a `Node` or `None`. The base case of "
            "`insert` is `if n is None: return Node(v)` — build one and hand "
            "it back; every other step recurses into one side and returns "
            "`n`. No pointers, no boxes: every name is already a reference.",
            r"""
import sys


class Node:
    def __init__(self, val):
        self.val = val
        self.left = None
        self.right = None


def insert(n, v):
    if n is None:
        return Node(v)
    if v < n.val:
        n.left = insert(n.left, v)
    else:
        n.right = insert(n.right, v)
    return n


def inorder(n):
    if n is None:
        return
    inorder(n.left)
    print(n.val, end=" ")
    inorder(n.right)


def height(n):
    if n is None:
        return 0
    return 1 + max(height(n.left), height(n.right))


def main():
    root = None
    for t in sys.stdin.read().split():
        root = insert(root, int(t))

    inorder(root)
    print()
    print(height(root))


main()
""",
            ["    if n is None:", "        return Node(v)"],
            "the base case: an empty spot becomes a new node",
            ["    if n is None:", "        return None"],
            "        return Node(v)",
            ["return Node(v, None, None)", "return &Node{Val: v}", "None => Some(Box::new(Node { val: v, left: None, right: None })),"],
            [
                "if n is None: return Node(v) — the constructor takes the value, and the children start as None.",
                "Node(v, None, None) is TypeError: __init__ takes one argument after self.",
                "is None, not == None: identity, and it is what every Python reviewer will ask for.",
            ],
            ask="In Python a child is either a `Node` or `None`. The base case of "
            "`insert` is `if n is None:` — build one node holding `v` and hand "
            "it back; every other step recurses into one side and returns `n`. "
            "Which line builds the node?",
        ),
    },
)

# ---------------------------------------------------------------- 13 interface
trio(
    "interface",
    "THE INTERFACE",
    2,
    "Round tables and square tables, and the floor plan only asks each "
    "one for its area.",
    "One name for a behaviour that several types provide, so the caller "
    "can hold any of them and ask for the same thing. Go calls it an "
    "interface and types satisfy it by having the methods; Rust calls it a "
    "trait and types implement it by saying so; Python calls it duck "
    "typing and, when it wants to check, a `Protocol`. The program reads "
    "`circle r` and `rect w h` lines, sums their areas, and prints the "
    "total to two decimals and the count of shapes.",
    {
        "go": ["interfaces", "structs", "dispatch"],
        "rust": ["traits", "structs", "dispatch"],
        "python": ["duck-typing", "structs", "dispatch"],
    },
    [
        ("three", "circle 1\nrect 2 3\ncircle 0.5\n", "9.93\n3\n", True),
        ("rects", "rect 1 1\nrect 2 2\n", "5.00\n2\n", False),
        ("one", "circle 2\n", "12.57\n1\n", False),
    ],
    {
        "go": Program(
            "In Go `type Shape interface { Area() float64 }` names the "
            "method set, and nothing else is needed: `Circle` and `Rect` "
            "satisfy it just by having an `Area() float64` method. A "
            "`[]Shape` then holds either, and `s.Area()` dispatches at run "
            "time.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"math"
	"os"
	"strings"
)

type Shape interface {
	Area() float64
}

type Circle struct{ R float64 }

type Rect struct{ W, H float64 }

func (c Circle) Area() float64 { return math.Pi * c.R * c.R }

func (r Rect) Area() float64 { return r.W * r.H }

func main() {
	reader := bufio.NewReader(os.Stdin)
	var shapes []Shape
	for {
		line, err := reader.ReadString('\n')
		f := strings.Fields(line)
		if len(f) == 2 && f[0] == "circle" {
			var r float64
			fmt.Sscan(f[1], &r)
			shapes = append(shapes, Circle{R: r})
		} else if len(f) == 3 && f[0] == "rect" {
			var w, h float64
			fmt.Sscan(f[1], &w)
			fmt.Sscan(f[2], &h)
			shapes = append(shapes, Rect{W: w, H: h})
		}
		if err != nil {
			break
		}
	}

	total := 0.0
	for _, s := range shapes {
		total += s.Area()
	}
	fmt.Printf("%.2f\n", total)
	fmt.Println(len(shapes))
}
""",
            ["type Shape interface {", "\tArea() float64", "}"],
            "the interface: one method, Area, returning float64",
            [],
            "type Shape interface {",
            ["type Shape struct {", "trait Shape {", "class Shape(Protocol):"],
            [
                "type Shape interface { Area() float64 } — the method set, and nothing more.",
                "No implements keyword anywhere: Circle satisfies Shape the moment it has the method.",
                "type Shape struct { Area() float64 } is not a struct field and does not parse.",
            ],
            ask="In Go an interface names a method set, and nothing else is needed: "
            "`Circle` and `Rect` satisfy it just by having an `Area() float64` "
            "method, and a `[]Shape` holds either. Which line opens the "
            "declaration of `Shape`?",
        ),
        "rust": Program(
            "In Rust `trait Shape { fn area(&self) -> f64; }` declares the "
            "behaviour, and each type says `impl Shape for Circle { ... }` "
            "explicitly. A `Vec<Box<dyn Shape>>` holds either behind a "
            "pointer, and `s.area()` dispatches through the vtable.",
            r"""
use std::io::Read;

trait Shape {
    fn area(&self) -> f64;
}

struct Circle {
    r: f64,
}

struct Rect {
    w: f64,
    h: f64,
}

impl Shape for Circle {
    fn area(&self) -> f64 {
        std::f64::consts::PI * self.r * self.r
    }
}

impl Shape for Rect {
    fn area(&self) -> f64 {
        self.w * self.h
    }
}

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let mut shapes: Vec<Box<dyn Shape>> = Vec::new();
    for line in input.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() == 2 && f[0] == "circle" {
            shapes.push(Box::new(Circle { r: f[1].parse().unwrap() }));
        } else if f.len() == 3 && f[0] == "rect" {
            shapes.push(Box::new(Rect { w: f[1].parse().unwrap(), h: f[2].parse().unwrap() }));
        }
    }

    let total: f64 = shapes.iter().map(|s| s.area()).sum();
    println!("{:.2}", total);
    println!("{}", shapes.len());
}
""",
            ["trait Shape {", "    fn area(&self) -> f64;", "}"],
            "the trait: one required method, area, returning f64",
            [],
            "trait Shape {",
            ["impl Shape {", "type Shape interface {", "class Shape(Protocol):"],
            [
                "trait Shape { fn area(&self) -> f64; } — a signature with a semicolon, no body.",
                "impl Shape for Circle is the explicit half: Rust never guesses that a type fits.",
                "dyn Shape is the trait as a runtime type; Box<dyn Shape> is how it goes in a Vec.",
            ],
            ask="In Rust the behaviour is declared once, with `fn area(&self) -> f64;` "
            "as its one required method, and each type says `impl Shape for "
            "Circle { ... }` explicitly. `Box<dyn Shape>` holds either. Which "
            "line opens the declaration?",
        ),
        "python": Program(
            "In Python nothing has to be declared: any object with an "
            "`area()` method will do, and that is duck typing. To *check* "
            "it, `typing.Protocol` names the method, and `@runtime_checkable` "
            "lets `isinstance(s, Shape)` ask at run time — which the program "
            "does before adding each area.",
            r"""
import math
import sys
from typing import Protocol, runtime_checkable


@runtime_checkable
class Shape(Protocol):
    def area(self) -> float: ...


class Circle:
    def __init__(self, r):
        self.r = r

    def area(self):
        return math.pi * self.r * self.r


class Rect:
    def __init__(self, w, h):
        self.w = w
        self.h = h

    def area(self):
        return self.w * self.h


def main():
    shapes = []
    for line in sys.stdin.read().splitlines():
        f = line.split()
        if len(f) == 2 and f[0] == "circle":
            shapes.append(Circle(float(f[1])))
        elif len(f) == 3 and f[0] == "rect":
            shapes.append(Rect(float(f[1]), float(f[2])))

    total = 0.0
    for s in shapes:
        if isinstance(s, Shape):
            total += s.area()
    print(f"{total:.2f}")
    print(len(shapes))


main()
""",
            ["@runtime_checkable", "class Shape(Protocol):", "    def area(self) -> float: ..."],
            "the protocol: one method, area, checkable at run time",
            [],
            "class Shape(Protocol):",
            ["class Shape:", "type Shape interface {", "trait Shape {"],
            [
                "@runtime_checkable above class Shape(Protocol): with def area(self) -> float: ... under it.",
                "class Shape: with no Protocol is a plain class nobody inherits from, and isinstance says no to every shape.",
                "The ... is the body: a Protocol method declares the name and the signature, not the work.",
            ],
        ),
    },
)



# ---------------------------------------------------------------- 14 generics
trio(
    "generics",
    "THE GENERIC",
    2,
    "One `largest` for the numbers on the bill and the same `largest` for "
    "the names on the reservation list. Written once.",
    "A function over a type parameter: written once, used with integers "
    "and with strings, on the condition that the type can be compared. "
    "The program reads a line of numbers and a line of words, and prints "
    "the largest of each through one `largest` function.",
    {
        "go": ["generics", "functions"],
        "rust": ["generics", "traits"],
        "python": ["generics", "functions"],
    },
    [
        ("both", "3 9 4\nbun tea milk\n", "9\ntea\n", True),
        ("one-each", "7\nzed\n", "7\nzed\n", False),
        ("negatives", "-5 -2 -9\nb a\n", "-2\nb\n", False),
    ],
    {
        "go": Program(
            "In Go the type parameter goes in square brackets with its "
            "constraint: `func largest[T cmp.Ordered](xs []T) T`. `cmp.Ordered` "
            "is the constraint that allows `<` and `>`; `any` would not. The "
            "call `largest(nums)` infers `T` from the argument.",
            r"""
package main

import (
	"bufio"
	"cmp"
	"fmt"
	"os"
	"strconv"
	"strings"
)

func largest[T cmp.Ordered](xs []T) T {
	best := xs[0]
	for _, x := range xs[1:] {
		if x > best {
			best = x
		}
	}
	return best
}

func main() {
	reader := bufio.NewReader(os.Stdin)
	first, _ := reader.ReadString('\n')
	second, _ := reader.ReadString('\n')
	var nums []int64
	for _, t := range strings.Fields(first) {
		v, _ := strconv.ParseInt(t, 10, 64)
		nums = append(nums, v)
	}
	words := strings.Fields(second)

	fmt.Println(largest(nums))
	fmt.Println(largest(words))
}
""",
            ["func largest[T cmp.Ordered](xs []T) T {"],
            "a generic largest over any ordered T",
            ["func largest[T any](xs []T) T {"],
            "func largest[T cmp.Ordered](xs []T) T {",
            ["func largest[T any](xs []T) T {", "fn largest<T: PartialOrd + Copy>(xs: &[T]) -> T {", "def largest[T](xs: list[T]) -> T:"],
            [
                "func largest[T cmp.Ordered](xs []T) T { — the brackets hold the type parameter and its constraint.",
                "With [T any] the body's x > best does not compile: any promises nothing about >.",
                "cmp.Ordered covers the integers, the floats and string; a struct would need its own constraint.",
            ],
        ),
        "rust": Program(
            "In Rust the type parameter goes in angle brackets with its bound: "
            "`fn largest<T: PartialOrd + Copy>(xs: &[T]) -> T`. `PartialOrd` "
            "allows `>`, `Copy` allows `best = x` to copy out of the slice, and "
            "both are traits — a bound is a trait. `largest(&nums)` infers `T`.",
            r"""
use std::io::Read;

fn largest<T: PartialOrd + Copy>(xs: &[T]) -> T {
    let mut best = xs[0];
    for &x in &xs[1..] {
        if x > best {
            best = x;
        }
    }
    best
}

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let mut lines = input.lines();
    let nums: Vec<i64> = lines.next().unwrap_or("").split_whitespace().map(|t| t.parse().unwrap()).collect();
    let words: Vec<&str> = lines.next().unwrap_or("").split_whitespace().collect();

    println!("{}", largest(&nums));
    println!("{}", largest(&words));
}
""",
            ["fn largest<T: PartialOrd + Copy>(xs: &[T]) -> T {"],
            "a generic largest over any T that can be compared and copied",
            ["fn largest<T: Copy>(xs: &[T]) -> T {"],
            "fn largest<T: PartialOrd + Copy>(xs: &[T]) -> T {",
            ["fn largest<T>(xs: &[T]) -> T {", "func largest[T cmp.Ordered](xs []T) T {", "def largest[T](xs: list[T]) -> T:"],
            [
                "fn largest<T: PartialOrd + Copy>(xs: &[T]) -> T { — two bounds joined with +.",
                "Without PartialOrd the > is E0369; without Copy the best = x is E0507. Each bound buys one line of the body.",
                "&str is Copy (it is a pointer and a length), which is why the words work without cloning.",
            ],
        ),
        "python": Program(
            "In Python the type parameter is an annotation: `def largest[T]"
            "(xs: list[T]) -> T:` says one `T` throughout, and a checker "
            "would hold it to that. At run time it is duck typing — `>` "
            "works or it raises — so the signature is documentation the "
            "tools can read, not a gate.",
            r"""
import sys


def largest[T](xs: list[T]) -> T:
    best = xs[0]
    for x in xs[1:]:
        if x > best:
            best = x
    return best


def main():
    lines = sys.stdin.read().splitlines()
    nums = [int(t) for t in lines[0].split()]
    words = lines[1].split()

    print(largest(nums))
    print(largest(words))


main()
""",
            ["def largest[T](xs: list[T]) -> T:"],
            "a generic largest over any T",
            [],
            "def largest[T](xs: list[T]) -> T:",
            ["def largest[T](xs: list[T]) -> T", "func largest[T cmp.Ordered](xs []T) T {", "fn largest<T: PartialOrd + Copy>(xs: &[T]) -> T {"],
            [
                "def largest[T](xs: list[T]) -> T: — the [T] after the name declares it (Python 3.12+).",
                "The line ends in a colon, like every def; without it the body is a syntax error.",
                "Older code spells it T = TypeVar(\"T\") above and def largest(xs: list[T]) -> T: below; same meaning.",
            ],
            ask="In Python the type parameter is part of the `def` line: a name in "
            "square brackets right after the function's name declares it, and "
            "the parameter and return annotations then use it. At run time it "
            "is duck typing; the signature is what a checker reads. Which line is "
            "the signature?",
        ),
    },
)

# ---------------------------------------------------------------- 15 ownership
trio(
    "ownership",
    "OWNERSHIP",
    2,
    "The order list goes to the till to be totalled and comes back; then "
    "it goes to the kitchen for good. Who has it afterwards is the whole "
    "question.",
    "A value handed to a function is either lent — the caller keeps it — "
    "or given away. Rust makes the difference a rule the compiler checks: "
    "`&orders` lends, `orders` moves, and a moved name is gone. Go and "
    "Python have no such rule, and the same two calls look alike; the "
    "brief for each says what really changes hands. The program totals "
    "the orders through a borrowing `total`, then hands them to `take`, "
    "which counts them and keeps them.",
    {
        "go": ["slices", "functions", "mutability"],
        "rust": ["ownership", "borrowing", "functions"],
        "python": ["functions", "mutability", "slices"],
    },
    [
        ("three", "12 30 8\n", "50\n3\n", True),
        ("one", "7\n", "7\n1\n", False),
        ("five", "1 2 3 4 5\n", "15\n5\n", False),
    ],
    {
        "go": Program(
            "In Go a slice is passed by value, but the value is a small "
            "header — pointer, length, capacity — so `total(orders)` and "
            "`take(orders)` both see the same array, and `orders` is still "
            "usable after either. `take` zeroes what it is given, and the "
            "caller would see that too. There is no move.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
)

func total(orders []int64) int64 {
	var sum int64
	for _, x := range orders {
		sum += x
	}
	return sum
}

func take(orders []int64) int {
	n := len(orders)
	for i := range orders {
		orders[i] = 0
	}
	return n
}

func main() {
	reader := bufio.NewReader(os.Stdin)
	var orders []int64
	for {
		var x int64
		if _, err := fmt.Fscan(reader, &x); err != nil {
			break
		}
		orders = append(orders, x)
	}

	sum := total(orders)
	n := take(orders)
	fmt.Println(sum)
	fmt.Println(n)
}
""",
            ["\tsum := total(orders)", "\tn := take(orders)"],
            "total the orders, then hand them to take",
            ["\tsum, n := int64(0), 0"],
            "\tsum := total(orders)",
            ["sum := total(&orders)", "let sum = total(&orders);", "sum_ = total(orders)"],
            [
                "sum := total(orders) then n := take(orders) — the same slice, twice, no & anywhere.",
                "&orders is a *[]int64, and total takes a []int64: a type error. Slices already share.",
                "After take, orders is still a name you can use — and every element is now 0.",
            ],
        ),
        "rust": Program(
            "In Rust `total(&orders)` lends: `&Vec<i64>` coerces to the "
            "`&[i64]` the function wants, and `orders` is still the caller's "
            "afterwards. `take(orders)` moves the `Vec` into `take`, which "
            "drops it on return, and using `orders` after that line is "
            "E0382. The order of the two calls is the program.",
            r"""
use std::io::Read;

fn total(orders: &[i64]) -> i64 {
    orders.iter().sum()
}

fn take(orders: Vec<i64>) -> usize {
    orders.len()
}

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let orders: Vec<i64> = input.split_whitespace().map(|t| t.parse().unwrap()).collect();

    let sum = total(&orders);
    let n = take(orders);
    println!("{}", sum);
    println!("{}", n);
}
""",
            ["    let sum = total(&orders);", "    let n = take(orders);"],
            "borrow the orders for total, then move them into take",
            ["    let (sum, n) = (0i64, orders.len() - orders.len());"],
            "    let sum = total(&orders);",
            ["let sum = total(orders);", "sum := total(orders)", "sum_ = total(orders)"],
            [
                "let sum = total(&orders); then let n = take(orders); — lend first, give away second.",
                "total(orders) without the & moves the Vec into total, and the take on the next line is E0382: use of moved value.",
                "Swap the two lines and the borrow comes after the move, which is the same error from the other side.",
            ],
        ),
        "python": Program(
            "In Python every name is a reference, and a call passes the "
            "reference: `total(orders)` and `take(orders)` both receive the "
            "very same list object. `take` clears it, and afterwards "
            "`orders` in `main` is empty too — not moved, not copied, "
            "shared. `orders[:]` or `list(orders)` would have been the copy.",
            r"""
import sys


def total(orders):
    return sum(orders)


def take(orders):
    n = len(orders)
    orders.clear()
    return n


def main():
    orders = [int(t) for t in sys.stdin.read().split()]

    sum_ = total(orders)
    n = take(orders)
    print(sum_)
    print(n)


main()
""",
            ["    sum_ = total(orders)", "    n = take(orders)"],
            "total the orders, then hand them to take",
            ["    sum_, n = 0, 0"],
            "    sum_ = total(orders)",
            ["sum_ = total(&orders)", "sum := total(orders)", "let sum = total(&orders);"],
            [
                "sum_ = total(orders) then n = take(orders) — the same object both times.",
                "There is no & in Python; a name is already a reference, and & is a syntax error here.",
                "After take, print(orders) would show []: clear emptied the one list everybody holds.",
            ],
        ),
    },
)

# ---------------------------------------------------------------- 16 lifetimes
trio(
    "lifetimes",
    "THE LIFETIME",
    3,
    "Two dish names on every slip, and the pass calls out the longer one. "
    "The name it calls out is one of the two it was handed — never a "
    "copy.",
    "A function that returns one of its two string arguments returns a "
    "reference into the caller's data. Rust asks how long that reference "
    "is good for, and the answer is written in the signature as a "
    "lifetime `'a`; Go and Python have a garbage collector and never ask, "
    "so the same function has no such mark. The program reads lines of "
    "two words and prints the longer of each pair, the first on a tie.",
    {
        "go": ["functions", "strings"],
        "rust": ["lifetimes", "borrowing", "functions"],
        "python": ["functions", "strings"],
    },
    [
        ("two", "tea coffee\nmilk bun\n", "coffee\nmilk\n", True),
        ("tie", "bun tea\n", "bun\n", False),
        ("three", "a bb\nccc dd\ne f\n", "bb\nccc\ne\n", False),
    ],
    {
        "go": Program(
            "In Go `func longest(a, b string) string` returns one of its "
            "arguments and nobody has to say for how long: a string is "
            "immutable and the collector keeps it as long as anything can "
            "reach it. Two parameters of one type share the type name.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

func longest(a, b string) string {
	if len(a) >= len(b) {
		return a
	}
	return b
}

func main() {
	reader := bufio.NewReader(os.Stdin)
	for {
		line, err := reader.ReadString('\n')
		f := strings.Fields(line)
		if len(f) == 2 {
			fmt.Println(longest(f[0], f[1]))
		}
		if err != nil {
			break
		}
	}
}
""",
            ["func longest(a, b string) string {", "\tif len(a) >= len(b) {", "\t\treturn a", "\t}"],
            "longest: the longer of a and b, a on a tie",
            ["func longest(a, b string) string {", "\tif false {", "\t\treturn a", "\t}"],
            "func longest(a, b string) string {",
            ["func longest(a, b string) {", "fn longest<'a>(a: &'a str, b: &'a str) -> &'a str {", "def longest(a: str, b: str) -> str:"],
            [
                "func longest(a, b string) string { if len(a) >= len(b) { return a }; return b }.",
                "func longest(a, b string) with no return type cannot return a; the result type is part of the signature.",
                ">= rather than > is what gives the first word the tie.",
            ],
        ),
        "rust": Program(
            "In Rust `fn longest<'a>(a: &'a str, b: &'a str) -> &'a str` says "
            "the returned reference lives as long as the shorter of the two "
            "inputs — the `'a` on all three ties them together. Leave it out "
            "and rustc says E0106: it cannot tell whether the result borrows "
            "from `a` or `b`, so it will not guess.",
            r"""
use std::io::Read;

fn longest<'a>(a: &'a str, b: &'a str) -> &'a str {
    if a.len() >= b.len() { a } else { b }
}

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    for line in input.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() == 2 {
            println!("{}", longest(f[0], f[1]));
        }
    }
}
""",
            ["fn longest<'a>(a: &'a str, b: &'a str) -> &'a str {", "    if a.len() >= b.len() { a } else { b }"],
            "longest, with the lifetime that ties the result to both inputs",
            ["fn longest(a: &str, b: &str) -> &str {", "    if a.len() >= b.len() { a } else { b }"],
            "fn longest<'a>(a: &'a str, b: &'a str) -> &'a str {",
            ["fn longest(a: &str, b: &str) -> &str {", "func longest(a, b string) string {", "def longest(a: str, b: str) -> str:"],
            [
                "fn longest<'a>(a: &'a str, b: &'a str) -> &'a str { — declare 'a after the name, then use it on all three references.",
                "fn longest(a: &str, b: &str) -> &str is E0106, missing lifetime specifier: two inputs, and the result could come from either.",
                "With one reference parameter rustc would fill the lifetime in itself (elision); it is the second input that makes you say it.",
            ],
        ),
        "python": Program(
            "In Python `def longest(a: str, b: str) -> str:` returns one of "
            "its arguments, and the object lives as long as any name refers "
            "to it — the caller's `f[0]` and the returned value are the same "
            "string. The annotations are for readers and checkers; the "
            "runtime does not look at them.",
            r"""
import sys


def longest(a: str, b: str) -> str:
    return a if len(a) >= len(b) else b


def main():
    for line in sys.stdin.read().splitlines():
        f = line.split()
        if len(f) == 2:
            print(longest(f[0], f[1]))


main()
""",
            ["def longest(a: str, b: str) -> str:", "    return a if len(a) >= len(b) else b"],
            "longest: the longer of a and b, a on a tie",
            ["def longest(a: str, b: str) -> str:", "    return b"],
            "def longest(a: str, b: str) -> str:",
            ["def longest(a: &str, b: &str) -> &str:", "func longest(a, b string) string {", "fn longest<'a>(a: &'a str, b: &'a str) -> &'a str {"],
            [
                "def longest(a: str, b: str) -> str: with return a if len(a) >= len(b) else b under it.",
                "a: &str is a syntax error in Python; there is no & and no lifetime, because the collector does that job.",
                "The conditional expression puts the value first: a if cond else b, not cond ? a : b.",
            ],
            ask="In Python the function returns one of its arguments, and the object "
            "lives as long as any name refers to it — no lifetime, no `&`. The "
            "signature annotates both parameters and the result as `str`, and "
            "ends in a colon like every `def`. Which line is it?",
        ),
    },
)

# ---------------------------------------------------------------- 17 threads
trio(
    "threads",
    "THE THREAD",
    3,
    "The bill is long, so it is torn into three strips and three "
    "regulars add a strip each at the same time; the total is the three "
    "sums put together.",
    "Start several threads, give each a piece of the work, wait for all "
    "of them, and combine what they found. The program reads numbers, "
    "cuts them into three chunks, sums each chunk on its own thread, "
    "prints the three sums in chunk order and then the total.",
    {
        "go": ["concurrency", "closures"],
        "rust": ["concurrency", "closures"],
        "python": ["concurrency", "closures"],
    },
    [
        ("seven", "1 2 3 4 5 6 7\n", "6 15 7\n28\n", True),
        ("two", "10 20\n", "10 20\n30\n", False),
        ("nine", "1 1 1 1 1 1 1 1 1\n", "3 3 3\n9\n", False),
    ],
    {
        "go": Program(
            "In Go `go func(...) { ... }(args)` starts a goroutine, and a "
            "`sync.WaitGroup` counts them: `wg.Add(1)` before each start, "
            "`defer wg.Done()` first thing inside, `wg.Wait()` after the "
            "loop. The chunk and its index are passed as arguments so each "
            "goroutine has its own.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
	"sync"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	var nums []int64
	for {
		var x int64
		if _, err := fmt.Fscan(reader, &x); err != nil {
			break
		}
		nums = append(nums, x)
	}
	size := (len(nums) + 2) / 3
	var chunks [][]int64
	for i := 0; i < len(nums); i += size {
		end := min(i+size, len(nums))
		chunks = append(chunks, nums[i:end])
	}

	sums := make([]int64, len(chunks))
	var wg sync.WaitGroup
	for i, chunk := range chunks {
		wg.Add(1)
		go func(i int, chunk []int64) {
			defer wg.Done()
			for _, x := range chunk {
				sums[i] += x
			}
		}(i, chunk)
	}
	wg.Wait()

	var total int64
	for _, s := range sums {
		fmt.Print(s, " ")
		total += s
	}
	fmt.Println()
	fmt.Println(total)
}
""",
            ["\t\tgo func(i int, chunk []int64) {", "\t\t\tdefer wg.Done()"],
            "start it as a goroutine, and have it check out on the way out",
            ["\t\tfunc(i int, chunk []int64) {"],
            "\t\tgo func(i int, chunk []int64) {",
            ["go func() {", "handles.push(thread::spawn(move || chunk.iter().sum::<i64>()));", "threads = [threading.Thread(target=work, args=(i, c)) for i, c in enumerate(chunks)]"],
            [
                "go func(i int, chunk []int64) { defer wg.Done(); ... }(i, chunk) — the go in front is what makes it a goroutine; without it the literal just runs, and without the Done the Wait never returns.",
                "go func() { with no parameters does not match the (i, chunk) at the end: too many arguments.",
                "Add before the go, Done inside it, Wait after the loop — in any other order the count is wrong.",
            ],
        ),
        "rust": Program(
            "In Rust `thread::spawn(move || ...)` starts a thread and returns "
            "a `JoinHandle`; `move` gives the closure its own copy of the "
            "chunk (a `Vec`, so the thread owns it), and `h.join().unwrap()` "
            "waits and hands back what the closure returned — the sum, here, "
            "so no shared state at all.",
            r"""
use std::io::Read;
use std::thread;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let nums: Vec<i64> = input.split_whitespace().map(|t| t.parse().unwrap()).collect();
    let size = (nums.len() + 2) / 3;

    let mut handles = Vec::new();
    for chunk in nums.chunks(size) {
        let chunk = chunk.to_vec();
        handles.push(thread::spawn(move || chunk.iter().sum::<i64>()));
    }
    let mut total = 0;
    for h in handles {
        let s = h.join().unwrap();
        print!("{} ", s);
        total += s;
    }
    println!();
    println!("{}", total);
}
""",
            ["        let chunk = chunk.to_vec();", "        handles.push(thread::spawn(move || chunk.iter().sum::<i64>()));"],
            "own the chunk, then spawn a thread that sums it",
            ["        handles.push(thread::spawn(move || chunk.len() as i64 * 0));"],
            "        handles.push(thread::spawn(move || chunk.iter().sum::<i64>()));",
            ["handles.push(thread::spawn(|| chunk.iter().sum::<i64>()));", "go func(i int, chunk []int64) {", "threads = [threading.Thread(target=work, args=(i, c)) for i, c in enumerate(chunks)]"],
            [
                "let chunk = chunk.to_vec(); then handles.push(thread::spawn(move || chunk.iter().sum::<i64>()));",
                "Without move the closure borrows chunk, and a thread may outlive main's loop: E0373.",
                "join returns whatever the closure returned, wrapped in a Result; unwrap it and it is the sum.",
            ],
        ),
        "python": Program(
            "In Python `threading.Thread(target=work, args=(i, c))` makes a "
            "thread — `args` is a tuple, hence the comma in `(i,)` for one "
            "argument — `t.start()` runs it and `t.join()` waits. The GIL "
            "means the three add in turns, but the shape is the same.",
            r"""
import sys
import threading


def main():
    nums = [int(t) for t in sys.stdin.read().split()]
    size = (len(nums) + 2) // 3
    chunks = [nums[i:i + size] for i in range(0, len(nums), size)]
    sums = [0] * len(chunks)

    def work(i, chunk):
        sums[i] = sum(chunk)

    threads = [threading.Thread(target=work, args=(i, c)) for i, c in enumerate(chunks)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    print(*sums)
    print(sum(sums))


main()
""",
            ["    threads = [threading.Thread(target=work, args=(i, c)) for i, c in enumerate(chunks)]", "    for t in threads:", "        t.start()"],
            "one Thread per chunk, then start them all",
            ["    threads = []"],
            "    threads = [threading.Thread(target=work, args=(i, c)) for i, c in enumerate(chunks)]",
            ["threads = [threading.Thread(target=work, args=(i)) for i, c in enumerate(chunks)]", "go func(i int, chunk []int64) {", "handles.push(thread::spawn(move || chunk.iter().sum::<i64>()));"],
            [
                "threads = [threading.Thread(target=work, args=(i, c)) for i, c in enumerate(chunks)] then start each.",
                "args=(i) is just i in parentheses, not a tuple; Thread wants a tuple, and (i,) is how one element is spelled.",
                "target=work, not target=work(i, c): the second calls work now, on this thread, and hands Thread its return value.",
            ],
        ),
    },
)

# ---------------------------------------------------------------- 18 mutex
trio(
    "mutex",
    "THE MUTEX",
    3,
    "One tally on the wall and every regular adding to it a thousand "
    "times over; the chalk has to change hands cleanly or the number is "
    "wrong.",
    "Several threads adding to one number is a data race unless the "
    "number is locked around each add. A mutex is the lock: take it, "
    "change the value, release it. The program reads numbers, starts one "
    "thread per number, each adding its number to a shared counter a "
    "thousand times under the lock, and prints the counter at the end.",
    {
        "go": ["shared-state", "concurrency"],
        "rust": ["shared-state", "concurrency", "interior-mutability"],
        "python": ["shared-state", "concurrency"],
    },
    [
        ("three", "1 2 3\n", "6000\n", True),
        ("one", "5\n", "5000\n", False),
        ("four", "1 1 1 1\n", "4000\n", False),
    ],
    {
        "go": Program(
            "In Go a `sync.Mutex` is a value with `Lock` and `Unlock`, and "
            "the counter is an ordinary variable that every goroutine can "
            "see. The discipline is yours: `mu.Lock()`, the add, "
            "`mu.Unlock()`, and nothing stops you forgetting — except "
            "`go test -race`.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
	"sync"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	var nums []int64
	for {
		var x int64
		if _, err := fmt.Fscan(reader, &x); err != nil {
			break
		}
		nums = append(nums, x)
	}

	var mu sync.Mutex
	var counter int64
	var wg sync.WaitGroup
	for _, x := range nums {
		wg.Add(1)
		go func(x int64) {
			defer wg.Done()
			for i := 0; i < 1000; i++ {
				mu.Lock()
				counter += x
				mu.Unlock()
			}
		}(x)
	}
	wg.Wait()
	fmt.Println(counter)
}
""",
            ["\t\t\t\tmu.Lock()", "\t\t\t\tcounter += x", "\t\t\t\tmu.Unlock()"],
            "lock, add, unlock",
            ["\t\t\t\tmu.Lock()", "\t\t\t\tmu.Unlock()"],
            "\t\t\t\tmu.Lock()",
            ["mu.lock()", "*counter.lock().unwrap() += x;", "with lock:"],
            [
                "mu.Lock() then counter += x then mu.Unlock() — three lines, the add in the middle.",
                "Go is case-sensitive and the method is Lock; mu.lock() is undefined.",
                "Without the lock the answer is usually wrong and sometimes right, which is worse than always wrong.",
            ],
            ask="In Go a `sync.Mutex` is a value with two methods, one to take the lock "
            "and one to release it, and the counter is an ordinary variable. The "
            "discipline is yours: take, add, release. Method names in Go start "
            "with a capital when they are exported, and these are. Which line "
            "takes the lock?",
        ),
        "rust": Program(
            "In Rust the counter *is* the lock: `Arc<Mutex<i64>>`, shared by "
            "`Arc::clone` and opened by `.lock().unwrap()`, which returns a "
            "guard that dereferences to the number and unlocks when it is "
            "dropped at the end of the statement. `*guard += x` writes "
            "through it; there is no way to reach the number without the "
            "lock.",
            r"""
use std::io::Read;
use std::sync::{Arc, Mutex};
use std::thread;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let nums: Vec<i64> = input.split_whitespace().map(|t| t.parse().unwrap()).collect();

    let counter = Arc::new(Mutex::new(0i64));
    let mut handles = Vec::new();
    for &x in &nums {
        let counter = Arc::clone(&counter);
        handles.push(thread::spawn(move || {
            for _ in 0..1000 {
                *counter.lock().unwrap() += x;
            }
        }));
    }
    for h in handles {
        h.join().unwrap();
    }
    println!("{}", *counter.lock().unwrap());
}
""",
            ["        let counter = Arc::clone(&counter);", "        handles.push(thread::spawn(move || {", "            for _ in 0..1000 {", "                *counter.lock().unwrap() += x;"],
            "this thread's own handle, the spawn, and the locked add inside",
            ["        handles.push(thread::spawn(move || {", "            for _ in 0..1000 {", "                let _ = x;"],
            "                *counter.lock().unwrap() += x;",
            ["counter.lock().unwrap() += x;", "counter += x", "with lock:"],
            [
                "let counter = Arc::clone(&counter); before the spawn, then *counter.lock().unwrap() += x; inside the loop.",
                "counter.lock().unwrap() += x without the * is E0368: the guard is not a number, it derefs to one.",
                "Every thread needs its own Arc; without the clone the first move takes the only one and the second iteration is E0382.",
            ],
        ),
        "python": Program(
            "In Python `threading.Lock()` is the mutex and `with lock:` "
            "takes and releases it around the block — a context manager, so "
            "the release cannot be forgotten. `nonlocal counter` lets the "
            "worker assign to the outer counter. The GIL does not make "
            "`+=` atomic, so the lock is real.",
            r"""
import sys
import threading


def main():
    nums = [int(t) for t in sys.stdin.read().split()]

    lock = threading.Lock()
    counter = 0

    def work(x):
        nonlocal counter
        for _ in range(1000):
            with lock:
                counter += x

    threads = [threading.Thread(target=work, args=(x,)) for x in nums]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    print(counter)


main()
""",
            ["            with lock:", "                counter += x"],
            "add under the lock",
            ["            with lock:", "                pass"],
            "            with lock:",
            ["with lock():", "mu.Lock()", "*counter.lock().unwrap() += x;"],
            [
                "with lock: then counter += x indented under it.",
                "lock() calls the Lock object, which is not callable: TypeError. with lock: is enough.",
                "lock.acquire() and lock.release() are the long form; with does both and the release even on an exception.",
            ],
            quiz_placeholder=["            if False:  # no lock yet"],
            ask="In Python `threading.Lock()` is the mutex, and a context manager "
            "takes and releases it around an indented block — the object itself "
            "after the keyword, not a call to it, and a colon at the end. Which "
            "line opens that block?",
        ),
    },
)

# ---------------------------------------------------------------- 19 producer / consumers (boss)
trio(
    "channel",
    "PRODUCER, MANY CONSUMERS",
    3,
    "THE YUENYEUNG. One hatch between the kitchen and the pass, three "
    "runners taking whatever comes through it, and the hatch has to be "
    "closed when the kitchen is done or the runners wait forever.",
    "One producer puts work on a channel, several consumers take from "
    "it, each keeps its own tally, and when the producer closes the "
    "channel the consumers finish and the tallies are added up. The "
    "close is the whole difficulty: the consumers cannot know the work is "
    "over unless the producer says so. The program reads numbers, sends "
    "each through one channel to three consumers, and prints the grand "
    "total and how many items were consumed.",
    {
        "go": ["channels", "concurrency"],
        "rust": ["channels", "concurrency", "shared-state"],
        "python": ["channels", "concurrency"],
    },
    [
        ("ten", "1 2 3 4 5 6 7 8 9 10\n", "55\n10\n", True),
        ("one", "42\n", "42\n1\n", False),
        ("twenty", "1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2\n", "30\n20\n", False),
    ],
    {
        "go": Program(
            "In Go `ch <- x` sends, `for x := range ch` receives until the "
            "channel is closed, and `close(ch)` is what ends those loops. "
            "Three goroutines range over the same channel, so each item goes "
            "to exactly one of them; the producer sends every number and "
            "then closes.",
            r"""
package main

import (
	"bufio"
	"fmt"
	"os"
	"sync"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	var nums []int64
	for {
		var x int64
		if _, err := fmt.Fscan(reader, &x); err != nil {
			break
		}
		nums = append(nums, x)
	}

	ch := make(chan int64)
	var wg sync.WaitGroup
	tallies := make([]int64, 3)
	counts := make([]int64, 3)
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for x := range ch {
				tallies[i] += x
				counts[i]++
			}
		}(i)
	}
	for _, x := range nums {
		ch <- x
	}
	close(ch)
	wg.Wait()

	var total, count int64
	for i := range tallies {
		total += tallies[i]
		count += counts[i]
	}
	fmt.Println(total)
	fmt.Println(count)
}
""",
            ["\tfor _, x := range nums {", "\t\tch <- x", "\t}", "\tclose(ch)"],
            "send every number, then close the channel",
            ["\tfor range nums {", "\t}", "\tclose(ch)"],
            "\tclose(ch)",
            ["ch.close()", "drop(tx);", "q.put(None)"],
            [
                "for _, x := range nums { ch <- x } then close(ch) — the close is what lets the three range loops end.",
                "A channel has no close method; close is a built-in function, like len.",
                "Forget the close and every consumer blocks on range forever: fatal error: all goroutines are asleep - deadlock!",
            ],
            ask="In Go `ch <- x` sends and `for x := range ch` receives until the "
            "channel is closed — and closing is a built-in function, not a method, "
            "called once by the producer when it has sent everything. Which line "
            "closes the channel?",
        ),
        "rust": Program(
            "In Rust `mpsc::channel()` gives a `Sender` and one `Receiver`; "
            "three consumers share the receiver through `Arc<Mutex<Receiver>>`, "
            "each locking it to `recv()`. `tx.send(x)` sends, and `drop(tx)` "
            "is the close: once every sender is gone, `recv` returns `Err` "
            "and the consumers break out and return their tallies.",
            r"""
use std::io::Read;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let nums: Vec<i64> = input.split_whitespace().map(|t| t.parse().unwrap()).collect();

    let (tx, rx) = mpsc::channel::<i64>();
    let rx = Arc::new(Mutex::new(rx));
    let mut consumers = Vec::new();
    for _ in 0..3 {
        let rx = Arc::clone(&rx);
        consumers.push(thread::spawn(move || {
            let (mut tally, mut count) = (0i64, 0i64);
            loop {
                let next = rx.lock().unwrap().recv();
                match next {
                    Ok(x) => {
                        tally += x;
                        count += 1;
                    }
                    Err(_) => break,
                }
            }
            (tally, count)
        }));
    }
    for x in nums {
        tx.send(x).unwrap();
    }
    drop(tx);

    let (mut total, mut count) = (0i64, 0i64);
    for h in consumers {
        let (t, c) = h.join().unwrap();
        total += t;
        count += c;
    }
    println!("{}", total);
    println!("{}", count);
}
""",
            ["    for x in nums {", "        tx.send(x).unwrap();", "    }", "    drop(tx);"],
            "send every number, then drop the sender to close the channel",
            ["    drop(tx);"],
            "    drop(tx);",
            ["tx.close();", "close(ch)", "q.put(None)"],
            [
                "for x in nums { tx.send(x).unwrap(); } then drop(tx); — dropping the last Sender is the close.",
                "There is no close method on a Sender; the channel closes when every Sender has been dropped.",
                "Keep tx alive and recv never returns Err: three consumers wait forever, and join never returns.",
            ],
        ),
        "python": Program(
            "In Python `queue.Queue` is the channel: `q.put(x)` sends and "
            "`q.get()` blocks until there is something. A `Queue` has no "
            "close, so the producer sends a sentinel — `None`, once per "
            "consumer — and each consumer breaks when it gets one. That is "
            "the close, spelled by hand.",
            r"""
import queue
import sys
import threading


def main():
    nums = [int(t) for t in sys.stdin.read().split()]

    q = queue.Queue()
    tallies = [0] * 3
    counts = [0] * 3

    def consume(i):
        while True:
            x = q.get()
            if x is None:
                break
            tallies[i] += x
            counts[i] += 1

    threads = [threading.Thread(target=consume, args=(i,)) for i in range(3)]
    for t in threads:
        t.start()
    for x in nums:
        q.put(x)
    for _ in threads:
        q.put(None)
    for t in threads:
        t.join()

    print(sum(tallies))
    print(sum(counts))


main()
""",
            ["    for x in nums:", "        q.put(x)", "    for _ in threads:", "        q.put(None)"],
            "send every number, then one None per consumer",
            ["    for _ in threads:", "        q.put(None)"],
            "        q.put(None)",
            ["q.close()", "close(ch)", "drop(tx);"],
            [
                "for x in nums: q.put(x) then for _ in threads: q.put(None) — one sentinel per consumer.",
                "queue.Queue has no close; q.close() is AttributeError. The None is the close.",
                "One None is not enough: the first consumer to take it stops, and the other two wait forever.",
            ],
        ),
    },
)



# ---------------------------------------------------------------- emit
HEADER_BASIC = """\
# REMIX LAND — BASIC. The yuenyeung café on Sugar Street: one table, three
# regulars, and every dish ordered three ways. One program three times —
# Go, then Rust, then Python, always in that order — so the three grammars
# for one idea sit side by side: integers and floats, strings, loops and
# branches, functions and closures, structs, enums and match, errors, the
# list, the map, a comprehension, sorting, a tree, an interface / a trait /
# duck typing, generics, ownership, a lifetime, threads, a mutex, and one
# producer with many consumers at the boss. Where a language has no such
# construct the trio keeps its shape and the brief says what stands in.
#
# The grammar drill: each brief shows the exact lines, the starter is the
# whole program with a hole of one to four lines and an `ANSWER:` comment
# at it, the player types the idiom. Untimed. verify_pack refuses a basic
# solution that adds more than four lines over its starter, and its
# `remix_trios` rule refuses a trio whose three programs differ in cases,
# difficulty or title.
#
# GENERATED by scripts/remix_pack.py — edit the trio there, not here, so the
# quiz road stays the same program.
#
# Story bible: docs/story.md. Concept vocabulary: docs/concepts.md.
# Format: SPEC §12. Every solution and starter in this file is run by
# tests/content/verify_pack.py and by CI (SPEC §9.4, §9.5).

pack = "remix.basic"
land = "remix"
category = "basic"
version = 1
"""

HEADER_VERYBASIC = """\
# REMIX LAND — VERY BASIC. The same trios as BASIC, asked as a question
# first: one line, four choices, one right — and two of the wrong ones are
# the same line in the other two languages, because writing Python in a Go
# file is the mistake this land exists to cure. Pick the line, then type it.
# Go, then Rust, then Python, one trio per concept, the yuenyeung café on
# Sugar Street.
#
# verify_pack swaps each wrong choice into the solution and refuses the
# quest if it passes, so the quiz has one right answer per language.
#
# GENERATED by scripts/remix_pack.py — edit the trio there, not here.
#
# Story bible: docs/story.md. Concept vocabulary: docs/concepts.md.
# Format: SPEC §12. Every solution and starter in this file is run by
# tests/content/verify_pack.py and by CI (SPEC §9.4, §9.5).

pack = "remix.verybasic"
land = "remix"
category = "verybasic"
version = 1
"""


def quest_toml(category, node, prev_id, trio, lang, prog, point, boss):
    qid = f"remix.{category}.{node:02d}.{trio.slug}-{lang}"
    kind = "boss" if boss else "quest"
    if category == "basic":
        starter, solution = basic_starter(lang, prog), prog.solution
        shown = "\n".join(h.strip() for h in prog.hole)
        ask = (
            f"Type the {'line' if len(prog.hole) == 1 else 'lines'} above where the "
            f"`{COMMENT[lang]} FILL` comment is."
        )
        brief = f"{trio.lead}\n\n{prog.explain}\n\n```\n{shown}\n```\n\n{ask}"
        hints = prog.hints
    else:
        starter, solution = quiz_pair(lang, prog)
        brief = (
            f"{trio.lead}\n\n{prog.ask or prog.explain}\n\nPick the line that does it, "
            f"then type it where the `{COMMENT[lang]} FILL` comment is."
        )
        hints = prog.hints[:2]
    example_in, example_out = next(
        (stdin, expect) for (_, stdin, expect, vis) in trio.cases if vis
    )
    ex_in = example_in.rstrip("\n").split("\n")
    ex_out = example_out.rstrip("\n").split("\n")
    example = "```\ninput:  " + "\n        ".join(ex_in) + "\noutput: " + "\n        ".join(ex_out) + "\n```"
    brief += "\n\n" + example + "\n"
    for h in hints:
        assert "\n" not in h
    out = [
        f"# ---------------------------------------------------------------- {node:02d}",
        "[[quest]]",
        f'id          = "{qid}"',
        f"node        = {node}",
        f"lang        = \"{lang}\"",
        f'title       = "{trio.title} — {LANG_NAME[lang]}"',
        f"difficulty  = {trio.difficulty}",
        f"story       = {toml_str(trio.story + ' ' + SPEAKER[lang])}",
        f"concepts    = {toml_list(trio.concepts[lang])}",
        f"requires    = {toml_list([prev_id] if prev_id else [])}",
        f'map          = {{ x = {point[0]}, y = {point[1]}, kind = "{kind}" }}',
        f"brief       = {toml_lit(brief)}",
        f"starter     = {toml_lit(starter)}",
        f"solution    = {toml_lit(solution)}",
        "hints = [",
    ]
    out += [f"  {toml_str(h)}," for h in hints]
    out.append("]")
    if category == "verybasic":
        choices = [prog.quiz.strip()] + list(prog.wrong)
        # The right answer's slot varies with the node, so a pattern is not
        # an answer; the two other languages' lines are always among them.
        k = node % 4
        choices = choices[-k:] + choices[:-k] if k else choices
        answer = choices.index(prog.quiz.strip())
        out += ["", "[quest.quiz]", "choices = [" + ", ".join(toml_str(c) for c in choices) + "]", f"answer  = {answer}"]
    out += [
        "",
        "[quest.tests]",
        'harness    = "stdio"',
        "timeout_ms = 5000",
        "compile_timeout_ms = 60000",
        "max_stdout_bytes = 262144",
        'match      = "trim"',
        "cases = [",
    ]
    for name, stdin, expect, vis in trio.cases:
        out.append(
            f"  {{ name = {toml_str(name)}, stdin = {toml_str(stdin)}, "
            f"expect = {toml_str(expect)}, visible = {'true' if vis else 'false'} }},"
        )
    out.append("]")
    return qid, "\n".join(out) + "\n"


def write_pack(category, header):
    n = len(TRIOS) * 3
    points = map_points(n)
    parts = [header]
    prev = None
    node = 0
    for t in TRIOS:
        for lang in LANGS:
            node += 1
            boss = node == n
            qid, text = quest_toml(category, node, prev, t, lang, t.langs[lang], points[node - 1], boss)
            parts.append(text)
            prev = qid
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{category}.toml").write_text("\n".join(parts))
    print(f"{category}: {n} quests -> {OUT / (category + '.toml')}")


def main():
    for t in TRIOS:
        assert set(t.langs) == set(LANGS), t.slug
        assert re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", t.slug), t.slug
        assert any(v for (_, _, _, v) in t.cases), t.slug
        for lang, prog in t.langs.items():
            for i in range(len(prog.hole) - 1):
                pass
    write_pack("verybasic", HEADER_VERYBASIC)
    write_pack("basic", HEADER_BASIC)


if __name__ == "__main__":
    sys.exit(main())
