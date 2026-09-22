/**
 * The other thing people mean by "copilot": the rest of the line, in grey,
 * before you have typed it. With no model behind it.
 *
 * Two sources, both of them already in the tab:
 *
 *   1. **templates** — the shapes each language is made of, keyed by the
 *      word being typed and, where it matters, by the construct the caret
 *      is in. `for` in Go is `for i, v := range xs {}`; `for` in Python is
 *      `for x in xs:`; `try` in C++ brings its `catch` with it. This is the
 *      "find the grammar automatically" part: the enclosing node comes from
 *      the same Lezer tree `help.ts` reads.
 *   2. **the buffer** — identifiers already written in this file, by
 *      prefix. A name you used forty lines up is the one you are reaching
 *      for now, and it is the completion no dictionary could have had.
 *
 * What it is not: it does not know your types, your crates or your intent.
 * It is a good typist with a copy of the grammar, not a model, and it works
 * on a plane with no key in the box (docs/agent.md §1). The suggestion is
 * only ever *offered* — TAB takes it, ESC dismisses it, any other key makes
 * it go away — and it only exists while the coder is on the screen, which
 * is the one opinion about your code the player opted into.
 *
 * Pure. `tests/complete.test.ts` holds it.
 */
import type { Land } from "../net/protocol";
import { INDENT } from "../ui/editor";
import { inProse, type CodeContext } from "./help";

export interface Suggestion {
  /** Stable, for the test that every template is reachable. */
  id: string;
  /** Exactly the characters to put in at the caret. */
  text: string;
  /** Where the caret goes inside `text`, once it is in. */
  caret: number;
}

interface Template {
  id: string;
  /** The word it starts with; a prefix of it is enough to offer it. */
  key: string;
  /**
   * Lines. A leading `\t` is one indent level, expanded per land. `$` is
   * where the caret lands; at most one, and the end of the text if none.
   */
  lines: readonly string[];
  /**
   * A statement: only offered when the caret is at the start of a line,
   * because `let x = for …` is not a thing anybody wanted.
   */
  stmt?: boolean;
  /** Only inside one of these nodes. */
  in?: readonly string[];
}

/**
 * Shortest sensible skeleton, not the cleverest one.
 *
 * A suggestion you have to read and edit is worse than no suggestion, so
 * each of these is the shape with the fewest decisions baked in — the loop
 * variable is `x`, the collection is `xs`, the error is handled the way the
 * language handles errors — and the caret is put where the first real
 * decision is.
 */
const TEMPLATES: Record<Land, readonly Template[]> = {
  rust: [
    { id: "rust.for", key: "for", stmt: true, lines: ["for x in $xs {", "\t", "}"] },
    { id: "rust.while", key: "while", stmt: true, lines: ["while $cond {", "\t", "}"] },
    { id: "rust.loop", key: "loop", stmt: true, lines: ["loop {", "\t$break;", "}"] },
    { id: "rust.if", key: "if", stmt: true, lines: ["if $cond {", "\t", "}"] },
    { id: "rust.match", key: "match", stmt: true, lines: ["match $x {", "\t_ => {}", "}"] },
    { id: "rust.fn", key: "fn", stmt: true, lines: ["fn $name() {", "\t", "}"] },
    { id: "rust.pub", key: "pub", stmt: true, lines: ["pub fn $name() {", "\t", "}"] },
    { id: "rust.struct", key: "struct", stmt: true, lines: ["struct $Name {", "\t", "}"] },
    { id: "rust.enum", key: "enum", stmt: true, lines: ["enum $Name {", "\t", "}"] },
    { id: "rust.trait", key: "trait", stmt: true, lines: ["trait $Name {", "\t", "}"] },
    { id: "rust.impl", key: "impl", stmt: true, lines: ["impl $Type {", "\t", "}"] },
    { id: "rust.let", key: "let", stmt: true, lines: ["let $x = ;"] },
    { id: "rust.use", key: "use", stmt: true, lines: ["use std::collections::HashMap;$"] },
    { id: "rust.println", key: "println", stmt: true, lines: ['println!("{}", $);'] },
    { id: "rust.vec", key: "Vec", lines: ["Vec::new()$"] },
    { id: "rust.hashmap", key: "HashMap", lines: ["HashMap::new()$"] },
  ],
  go: [
    { id: "go.for", key: "for", stmt: true, lines: ["for i, v := range $xs {", "\t", "}"] },
    { id: "go.if", key: "if", stmt: true, lines: ["if err != nil {", "\treturn err$", "}"] },
    {
      id: "go.func",
      key: "func",
      stmt: true,
      lines: ["func $name() error {", "\t", "\treturn nil", "}"],
    },
    { id: "go.type", key: "type", stmt: true, lines: ["type $Name struct {", "\t", "}"] },
    {
      id: "go.switch",
      key: "switch",
      stmt: true,
      lines: ["switch $x {", "case 1:", "\t", "default:", "\t", "}"],
    },
    {
      id: "go.select",
      key: "select",
      stmt: true,
      lines: ["select {", "case v := <-$ch:", "\t", "}"],
    },
    { id: "go.go", key: "go", stmt: true, lines: ["go func() {", "\t$", "}()"] },
    { id: "go.defer", key: "defer", stmt: true, lines: ["defer $f.Close()"] },
    { id: "go.var", key: "var", stmt: true, lines: ["var $x int"] },
    { id: "go.printf", key: "fmt", stmt: true, lines: ['fmt.Printf("%v\\n", $)'] },
    { id: "go.make", key: "make", lines: ["make([]$T, 0)"] },
  ],
  cpp: [
    {
      id: "cpp.for",
      key: "for",
      stmt: true,
      lines: ["for (const auto& x : $xs) {", "\t", "}"],
    },
    { id: "cpp.while", key: "while", stmt: true, lines: ["while ($cond) {", "\t", "}"] },
    { id: "cpp.if", key: "if", stmt: true, lines: ["if ($cond) {", "\t", "}"] },
    {
      id: "cpp.switch",
      key: "switch",
      stmt: true,
      lines: ["switch ($x) {", "case 1:", "\tbreak;", "default:", "\tbreak;", "}"],
    },
    {
      id: "cpp.try",
      key: "try",
      stmt: true,
      lines: ["try {", "\t$", "} catch (const std::exception& e) {", "\t", "}"],
    },
    {
      id: "cpp.class",
      key: "class",
      stmt: true,
      lines: ["class $Name {", "public:", "\t", "};"],
    },
    { id: "cpp.struct", key: "struct", stmt: true, lines: ["struct $Name {", "\t", "};"] },
    { id: "cpp.namespace", key: "namespace", stmt: true, lines: ["namespace $name {", "", "}"] },
    { id: "cpp.template", key: "template", stmt: true, lines: ["template <typename $T>"] },
    {
      id: "cpp.main",
      key: "int",
      stmt: true,
      lines: ["int main() {", "\t$", "\treturn 0;", "}"],
    },
    // Not `stmt`: the `#` is already typed, so the caret is never at the
    // start of the line. The directive it is inside says the same thing
    // more precisely anyway.
    { id: "cpp.include", key: "include", in: ["PreprocDirective"], lines: ["include <$vector>"] },
    { id: "cpp.cout", key: "std", stmt: true, lines: ["std::cout << $ << '\\n';"] },
    { id: "cpp.auto", key: "auto", stmt: true, lines: ["auto $x = ;"] },
  ],
  python: [
    { id: "py.for", key: "for", stmt: true, lines: ["for x in $xs:", "\t"] },
    { id: "py.while", key: "while", stmt: true, lines: ["while $cond:", "\t"] },
    { id: "py.if", key: "if", stmt: true, lines: ["if $cond:", "\t"] },
    { id: "py.def", key: "def", stmt: true, lines: ["def $name():", "\t"] },
    {
      id: "py.class",
      key: "class",
      stmt: true,
      lines: ["class $Name:", "\tdef __init__(self):", "\t\t"],
    },
    {
      id: "py.try",
      key: "try",
      stmt: true,
      lines: ["try:", "\t$", "except ValueError as e:", "\traise"],
    },
    { id: "py.with", key: "with", stmt: true, lines: ["with open($path) as f:", "\t"] },
    { id: "py.match", key: "match", stmt: true, lines: ["match $x:", "\tcase _:", "\t\tpass"] },
    { id: "py.async", key: "async", stmt: true, lines: ["async def $name():", "\t"] },
    { id: "py.import", key: "import", stmt: true, lines: ["import $sys"] },
    { id: "py.from", key: "from", stmt: true, lines: ["from $typing import Iterable"] },
    { id: "py.print", key: "print", stmt: true, lines: ["print($)"] },
    { id: "py.lambda", key: "lambda", lines: ["lambda x: $"] },
    { id: "py.enumerate", key: "enumerate", lines: ["enumerate($xs)"] },
    { id: "py.range", key: "range", lines: ["range($n)"] },
  ],
  // PyTorch Land keeps Python's grammar skeletons and adds the ones that are
  // the actual writing: the loop body in the order it has to be in, a Module
  // with `super().__init__()` already there, and the two blocks people forget
  // to open. Every key is the word the first line starts with — the insert is
  // the template minus what was typed — and no key is a prefix of another.
  pytorch: [
    { id: "pt.for", key: "for", stmt: true, lines: ["for x in $xs:", "\t"] },
    { id: "pt.while", key: "while", stmt: true, lines: ["while $cond:", "\t"] },
    { id: "pt.if", key: "if", stmt: true, lines: ["if $cond:", "\t"] },
    { id: "pt.def", key: "def", stmt: true, lines: ["def $name():", "\t"] },
    { id: "pt.import", key: "import", stmt: true, lines: ["import torch$"] },
    {
      id: "pt.class",
      key: "class",
      stmt: true,
      lines: [
        "class $Net(nn.Module):",
        "\tdef __init__(self):",
        "\t\tsuper().__init__()",
        "\t\t",
        "",
        "\tdef forward(self, x):",
        "\t\treturn x",
      ],
    },
    // The three lines in the one order that works, because the order is the
    // thing a first training loop gets wrong.
    {
      id: "pt.opt",
      key: "opt",
      stmt: true,
      lines: ["opt.zero_grad()", "loss.backward()", "opt.step()$"],
    },
    { id: "pt.nograd", key: "with", stmt: true, lines: ["with torch.no_grad():", "\t$"] },
    { id: "pt.eval", key: "model", stmt: true, lines: ["model.eval()$"] },
    { id: "pt.linear", key: "nn", lines: ["nn.Linear($in_features, out_features)"] },
    { id: "pt.tensor", key: "torch", lines: ["torch.tensor($data)"] },
    { id: "pt.shape", key: "tuple", lines: ["tuple($x.shape)"] },
  ],
};

/** Shortest prefix worth guessing from. One letter matches everything. */
const MIN_PREFIX = 2;

/** Identifiers so short or so common that finishing them helps nobody. */
const MIN_WORD = 4;

/**
 * The template's text, indented to the caret's own line, with the caret
 * marker taken out and its offset kept.
 */
function render(tpl: Template, lang: Land, indent: string): { text: string; caret: number } {
  const unit = INDENT[lang];
  const body = tpl.lines
    .map((l) => l.replace(/^\t+/, (m) => unit.repeat(m.length)))
    .join("\n" + indent);
  const at = body.indexOf("$");
  return at < 0 ? { text: body, caret: body.length } : { text: body.replace("$", ""), caret: at };
}

/** Every identifier in the file, by how often it is written. */
function words(source: string): Map<string, number> {
  const seen = new Map<string, number>();
  for (const m of source.matchAll(/[A-Za-z_][A-Za-z0-9_]*/g)) {
    seen.set(m[0], (seen.get(m[0]) ?? 0) + 1);
  }
  return seen;
}

/**
 * What to offer at the caret, or nothing.
 *
 * Nothing is the common answer and the right one: mid-word is the only
 * place a suggestion is welcome, and even there only when the file or the
 * grammar has something specific to say.
 */
export function completeAt(lang: Land, ctx: CodeContext): Suggestion | null {
  if (inProse(ctx.path)) return null;
  const word = ctx.word;
  if (word.length < MIN_PREFIX) return null;
  // Only ever *ahead* of the caret: the word has to be the thing being
  // typed, not one the caret wandered back into.
  if (!ctx.before.endsWith(word)) return null;
  const head = ctx.before.slice(0, ctx.before.length - word.length);
  const atLineStart = /^\s*$/.test(head);
  const indent = /^\s*/.exec(ctx.before)![0];

  const here = new Set(ctx.path);
  const fits = (tpl: Template) =>
    tpl.key.startsWith(word) &&
    (!tpl.stmt || atLineStart) &&
    (!tpl.in || tpl.in.some((n) => here.has(n)));
  // The most specific template wins, then the shortest key: `for` beats
  // `forEach` on `fo`, because the shorter word is the one being finished.
  const found = TEMPLATES[lang]
    .filter(fits)
    .sort((a, b) => (b.in ? 1 : 0) - (a.in ? 1 : 0) || a.key.length - b.key.length)[0];
  if (found) {
    const { text, caret } = render(found, lang, indent);
    if (text.startsWith(word)) {
      return {
        id: found.id,
        text: text.slice(word.length),
        caret: Math.max(0, caret - word.length),
      };
    }
  }

  // Nothing in the grammar: finish a name this file already uses. The one
  // being typed is in the count too, so it has to beat one occurrence.
  let best: string | null = null;
  let bestScore = 0;
  for (const [w, n] of words(ctx.source)) {
    if (w === word || !w.startsWith(word) || w.length < MIN_WORD) continue;
    const score = n * 100 - w.length;
    if (score > bestScore) {
      best = w;
      bestScore = score;
    }
  }
  if (!best) return null;
  const rest = best.slice(word.length);
  return { id: `${lang}.buffer`, text: rest, caret: rest.length };
}

/** Every template, for the test that keeps them well-formed. */
export function templates(): ReadonlyArray<Template & { lang: Land }> {
  return (Object.keys(TEMPLATES) as Land[]).flatMap((lang) =>
    TEMPLATES[lang].map((t) => ({ ...t, lang })),
  );
}
