/**
 * The offline completion: the templates, the buffer, and what happens when
 * TAB arrives.
 *
 * Two halves, tested apart. `completeAt` is pure and gets fixtures with a
 * real parse behind them (`contextOf`, shared with the help test, for the
 * same reason: the node names are the part nobody can reason out). The
 * editor half is a live `Editor` in happy-dom, because the thing worth
 * proving there is the *ordering* — TAB takes the suggestion when there is
 * one and still indents when there is not, which is a fact about the keymap
 * and not about either function.
 */
import { describe, expect, it } from "vitest";
import { completeAt, templates } from "../src/ai/complete";
import { INDENT } from "../src/ui/editor";
import type { Land } from "../src/net/protocol";
import { contextOf } from "./context";

/** The whole line as it would read once the suggestion is taken. */
function taken(lang: Land, marked: string): string {
  const ctx = contextOf(lang, marked);
  const s = completeAt(lang, ctx);
  return s === null ? "" : ctx.before + s.text;
}

const idAt = (lang: Land, marked: string) => completeAt(lang, contextOf(lang, marked))?.id ?? null;

describe("completeAt offers the language's own shapes", () => {
  it("finishes a Go range loop from two letters", () => {
    expect(taken("go", "package main\nfunc f() {\n\tfo‸\n}\n")).toBe(
      "\tfor i, v := range xs {\n\t\t\n\t}",
    );
  });

  it("gives each land its own `for`", () => {
    expect(taken("rust", "fn f() {\n    fo‸\n}\n")).toContain("for x in xs {");
    expect(taken("cpp", "int main() {\n  fo‸\n}\n")).toContain("for (const auto& x : xs)");
    expect(taken("python", "def f(xs):\n    fo‸\n")).toBe("    for x in xs:\n        ");
  });

  it("indents the tail to the caret's own line, in the land's own unit", () => {
    const s = completeAt(
      "rust",
      contextOf("rust", "fn f() {\n    if a {\n        fo‸\n    }\n}\n"),
    )!;
    // Every line after the first is written at the caret's indent, and the
    // body one unit further in. Eight spaces in, in Rust, is two units.
    expect(s.text).toContain("\n" + " ".repeat(8) + INDENT.rust);
    expect(s.text.endsWith("\n" + " ".repeat(8) + "}")).toBe(true);
  });

  it("puts the caret at the first decision, not at the end", () => {
    const s = completeAt("go", contextOf("go", "package main\nfunc f() {\n\tfo‸\n}\n"))!;
    expect(s.text.slice(s.caret, s.caret + 2)).toBe("xs");
  });

  it("brings the catch with the try and the case with the switch", () => {
    expect(taken("cpp", "int main() {\n  tr‸\n}\n")).toContain("catch (const std::exception& e)");
    expect(taken("go", "package main\nfunc f() {\n\tsw‸\n}\n")).toContain("default:");
    expect(taken("python", "def f():\n    tr‸\n")).toContain("except ValueError as e:");
  });

  it("knows Go's `if` is about the error", () => {
    expect(taken("go", "package main\nfunc f() error {\n\tif‸\n}\n")).toContain("if err != nil {");
  });
});

describe("completeAt offers a statement only where a statement goes", () => {
  it("refuses a block template in the middle of an expression", () => {
    // `let x = for …` is not a thing anybody wanted.
    expect(idAt("rust", "fn f() {\n    let x = fo‸\n}\n")).not.toBe("rust.for");
    expect(idAt("python", "y = wh‸\n")).not.toBe("py.while");
  });

  it("still offers an expression template mid-line", () => {
    expect(taken("python", "ys = [x for i, x in enum‸]\n")).toContain("enumerate(xs)");
  });
});

describe("completeAt finishes names this file already uses", () => {
  it("prefers the name written most often", () => {
    const src = "def f():\n    total_count = 0\n    total_count += 1\n    totals = 2\n    tot‸\n";
    expect(taken("python", src)).toBe("    total_count");
  });

  it("does not offer the word back to itself", () => {
    expect(
      completeAt("python", contextOf("python", "def f():\n    value = 1\n    value‸\n")),
    ).toBeNull();
  });

  it("ignores names too short to be worth finishing", () => {
    expect(
      completeAt("go", contextOf("go", "package main\nfunc f() {\n\tabcd := 1\n\tab‸\n}\n")),
    ).not.toBeNull();
    expect(
      completeAt(
        "go",
        contextOf("go", "package main\nfunc f() {\n\tabc := 1\n\tzz := 2\n\tab‸\n}\n"),
      ),
    ).toBeNull();
  });
});

describe("completeAt keeps quiet where it should", () => {
  it("says nothing on one letter", () => {
    expect(completeAt("rust", contextOf("rust", "fn f() {\n    f‸\n}\n"))).toBeNull();
  });

  it("says nothing inside a comment or a string", () => {
    expect(completeAt("rust", contextOf("rust", "fn f() {\n    // fo‸\n}\n"))).toBeNull();
    expect(completeAt("python", contextOf("python", "s = 'fo‸'\n"))).toBeNull();
  });

  it("says nothing when the caret is not at the end of a word", () => {
    expect(completeAt("go", contextOf("go", "package main\nfunc f() {\n\tfor ‸\n}\n"))).toBeNull();
  });
});

describe("the template table itself", () => {
  const all = templates();

  it("has no two templates under one id", () => {
    expect(new Set(all.map((t) => t.id)).size).toBe(all.length);
  });

  it("starts every template with the word that triggers it", () => {
    // Otherwise the insert — the template minus what was typed — would be a
    // splice of two different words.
    for (const t of all) expect(t.lines[0].replace("$", ""), t.id).toMatch(new RegExp("^" + t.key));
  });

  it("marks the caret at most once", () => {
    for (const t of all) {
      expect(t.lines.join("").split("$").length - 1, t.id).toBeLessThanOrEqual(1);
    }
  });

  it("can be reached by typing its own key", () => {
    // The gates are subtle enough — a statement wants the start of a line,
    // an `in` wants a construct around it, the prefix wants two letters —
    // that a template can sit in the table and never be offered. This is
    // the whole table, typed.
    const around: Record<string, [Land, string]> = {
      // The `#` is typed already, which is why this one is not a statement.
      "cpp.include": ["cpp", "#inc\u2038\nint main() {}\n"],
    };
    const body: Record<Land, (line: string) => string> = {
      rust: (l) => `fn f() {\n    ${l}\n}\n`,
      go: (l) => `package main\nfunc f() {\n\t${l}\n}\n`,
      cpp: (l) => `int main() {\n  ${l}\n}\n`,
      python: (l) => `def f():\n    ${l}\n`,
    };
    for (const t of all) {
      const marked = around[t.id]
        ? around[t.id][1]
        : body[t.lang](t.stmt ? `${t.key}\u2038` : `x = ${t.key}\u2038`);
      expect(idAt(around[t.id]?.[0] ?? t.lang, marked), t.id).toBe(t.id);
    }
  });

  it("covers all four lands", () => {
    for (const lang of ["rust", "go", "cpp", "python"] as Land[]) {
      expect(all.filter((t) => t.lang === lang).length).toBeGreaterThan(9);
    }
  });
});

describe("the editor takes the suggestion, and TAB still indents without one", () => {
  it("puts the text in at the caret and leaves the caret at the marker", async () => {
    const { Editor } = await import("../src/ui/editor");
    const ed = new Editor("go", "package main\n\nfunc f() {\n\tfo\n}\n");
    try {
      ed.seek(ed.source.indexOf("fo") + 2);
      const s = completeAt("go", ed.contextAt()!)!;
      ed.suggest({ text: s.text, caret: s.caret });
      expect(ed.suggestion).not.toBeNull();
      expect(tab(ed)).toBe(true);
      expect(ed.source).toContain("for i, v := range xs {");
      expect(ed.source).toContain("\n\t}\n");
      // The caret landed on the collection, which is the thing to replace.
      expect(ed.source.slice(ed.caretPos, ed.caretPos + 2)).toBe("xs");
      expect(ed.suggestion).toBeNull();
    } finally {
      ed.destroy();
    }
  });

  it("indents as usual when nothing is being offered", async () => {
    const { Editor } = await import("../src/ui/editor");
    const ed = new Editor("rust", "fn main() {\n\n}\n");
    try {
      ed.seek(ed.source.indexOf("{") + 2);
      expect(ed.suggestion).toBeNull();
      tab(ed);
      expect(ed.source).toBe("fn main() {\n" + INDENT.rust + "\n}\n");
    } finally {
      ed.destroy();
    }
  });

  it("drops the offer the moment anything else is typed", async () => {
    const { Editor } = await import("../src/ui/editor");
    const ed = new Editor("python", "def f(xs):\n    fo\n");
    try {
      ed.seek(ed.source.length - 1);
      ed.suggest({ text: "r x in xs:", caret: 10 });
      expect(ed.suggestion).not.toBeNull();
      ed.typeAt("o");
      expect(ed.suggestion).toBeNull();
    } finally {
      ed.destroy();
    }
  });

  it("refuses to draw over a drill's own ghost", async () => {
    const { Editor } = await import("../src/ui/editor");
    const ed = new Editor("rust", "fn main() {}\n");
    try {
      ed.setAnswer({ text: "fn main() {}\n", blanks: [] });
      ed.suggest({ text: "xyz", caret: 3 });
      expect(ed.suggestion).toBeNull();
    } finally {
      ed.destroy();
    }
  });
});

/** TAB at the editor's content, as a person's finger would deliver it. */
function tab(ed: { dom: HTMLElement }): boolean {
  const content = ed.dom.querySelector(".cm-content") as HTMLElement;
  const ev = new KeyboardEvent("keydown", {
    key: "Tab",
    code: "Tab",
    bubbles: true,
    cancelable: true,
  });
  content.dispatchEvent(ev);
  return ev.defaultPrevented;
}
