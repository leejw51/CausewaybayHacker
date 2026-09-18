/**
 * The context help, against real syntax trees.
 *
 * The catalogue in `ai/help.ts` is keyed by Lezer node names, and the node
 * names are the one thing about this feature that cannot be reasoned out —
 * they differ per grammar and a table written from memory is a table of
 * plausible mistakes. So every case here parses the fixture with the same
 * language mode the editor uses and asks at a real offset, marked `‸`.
 *
 * The second half is the catalogue's own hygiene: ids unique, sentences
 * short enough for the four-line bubble, no dangling markup.
 */
import { describe, expect, it } from "vitest";
import { catalogue, helpAt, inProse } from "../src/ai/help";
import { contextOf } from "./context";
import type { Land } from "../src/net/protocol";

const at = (lang: Land, marked: string) => helpAt(lang, contextOf(lang, marked));

describe("helpAt names the construct the caret is in", () => {
  it("finds a Rust match arm, and the match around it", () => {
    expect(
      at("rust", "fn f(o: Option<i32>) {\n    match o {\n        Some(v) => ‸v,\n    };\n}\n")!.id,
    ).toBe("rust.n.MatchArm");
    expect(at("rust", "fn f(o: Option<i32>) {\n    match o {‸\n    };\n}\n")!.id).toBe(
      "rust.n.MatchExpression",
    );
  });

  it("walks out through a Rust block to the loop that owns it", () => {
    expect(at("rust", "fn f() {\n    for i in 0..3 {\n        ‸\n    }\n}\n")!.id).toBe(
      "rust.n.ForExpression",
    );
  });

  it("finds the Rust `?`, the closure and the lifetime", () => {
    expect(
      at("rust", "fn f(s: &str) -> Result<i32, E> {\n    let n = s.parse()?‸;\n    Ok(n)\n}\n")!.id,
    ).toBe("rust.n.TryExpression");
    expect(at("rust", "fn f() {\n    let c = || { ‸ };\n}\n")!.id).toBe("rust.n.ClosureExpression");
    expect(at("rust", "fn f<'a>(x: &'a str‸) {}\n")!.id).toBe("rust.n.ReferenceType");
  });

  it("finds the Go range clause and the plain loop apart", () => {
    expect(at("go", "package main\nfunc f() {\n\tfor i, v := range ‸xs {\n\t}\n}\n")!.id).toBe(
      "go.n.RangeClause",
    );
    expect(at("go", "package main\nfunc f() {\n\tfor {\n\t\t‸\n\t}\n}\n")!.id).toBe(
      "go.n.ForStatement",
    );
  });

  it("finds Go's defer, go, select and type switch", () => {
    expect(at("go", "package main\nfunc f() {\n\tdefer c.Close()‸\n}\n")!.id).toBe(
      "go.n.DeferStatement",
    );
    expect(at("go", "package main\nfunc f() {\n\tgo w()‸\n}\n")!.id).toBe("go.n.GoStatement");
    expect(
      at("go", "package main\nfunc f() {\n\tselect {\n\tcase v := <-ch:\n\t\t‸\n\t}\n}\n")!.id,
    ).toBe("go.n.SelectBlock");
    expect(
      at("go", "package main\nfunc f(x any) {\n\tswitch v := x.(type)‸ {\n\tcase int:\n\t}\n}\n")!
        .id,
    ).toBe("go.n.TypeSwitchStatement");
  });

  it("tells a C++ range-for from a counting for", () => {
    expect(at("cpp", "int main() {\n  for (const auto& x : xs) {\n    ‸\n  }\n}\n")!.id).toBe(
      "cpp.n.ForRangeLoop",
    );
    expect(at("cpp", "int main() {\n  for (int i = 0; i < n; i++) {\n    ‸\n  }\n}\n")!.id).toBe(
      "cpp.n.ForStatement",
    );
  });

  it("finds a C++ lambda, a catch and a class member", () => {
    expect(at("cpp", "int main() {\n  auto f = [](int a) { ‸ };\n}\n")!.id).toBe(
      "cpp.n.LambdaExpression",
    );
    expect(
      at("cpp", "int main() {\n  try { g(); } catch (const std::exception& e) {‸}\n}\n")!.id,
    ).toBe("cpp.n.CatchClause");
    expect(at("cpp", "class A {\npublic:\n  int x‸;\n};\n")!.id).toBe("cpp.n.FieldDeclaration");
  });

  it("walks out through a Python body to the statement that owns it", () => {
    expect(at("python", "def f(xs):\n    for x in xs:\n        ‸\n")!.id).toBe(
      "python.n.ForStatement",
    );
    expect(at("python", "with open('f') as fh:\n    ‸\n")!.id).toBe("python.n.WithStatement");
    expect(at("python", "try:\n    g()\nexcept ValueError as e:\n    ‸\n")!.id).toBe(
      "python.n.TryStatement",
    );
  });

  it("tells Python's three comprehensions apart", () => {
    expect(at("python", "ys = [x for x in xs if ‸x]\n")!.id).toBe(
      "python.n.ArrayComprehensionExpression",
    );
    expect(at("python", "d = {k: v for k, v in ‸pairs}\n")!.id).toBe(
      "python.n.DictionaryComprehensionExpression",
    );
    expect(at("python", "s = {x for x in ‸xs}\n")!.id).toBe("python.n.SetComprehensionExpression");
  });

  it("finds a Python match clause and a decorator", () => {
    expect(at("python", "match cmd:\n    case 1:\n        ‸\n")!.id).toBe("python.n.MatchClause");
    expect(at("python", "@d‸\ndef f():\n    pass\n")!.id).toBe("python.n.Decorator");
  });
});

describe("helpAt prefers the word the caret is actually on", () => {
  it("says the thing about `unwrap`, not about the let", () => {
    const h = at("rust", "fn f(o: Option<i32>) {\n    let v = o.unwrap‸();\n}\n")!;
    expect(h.id).toBe("rust.w.unwrap");
    expect(h.text).toContain("?");
  });

  it("says the thing about `defer`, `enumerate` and `move`", () => {
    expect(at("go", "package main\nfunc f() {\n\tdefer‸ c.Close()\n}\n")!.id).toBe("go.w.defer");
    expect(at("python", "for i, x in enumerate‸(xs):\n    pass\n")!.id).toBe("python.w.enumerate");
    expect(at("cpp", "int main() { auto b = std::move‸(a); }\n")!.id).toBe("cpp.w.move");
  });

  it("falls back to the construct when the word is not in the catalogue", () => {
    expect(at("python", "def f(xs):\n    for wibble‸ in xs:\n        pass\n")!.id).toBe(
      "python.n.ForStatement",
    );
  });
});

describe("helpAt keeps quiet where it should", () => {
  it("says nothing inside a comment or a string", () => {
    expect(at("rust", "fn f() {\n    // for the ‸record\n}\n")).toBeNull();
    expect(at("go", 'package main\nfunc f() {\n\ts := "defer‸ this"\n}\n')).toBeNull();
    expect(at("python", "s = 'for ‸x'\n")).toBeNull();
    expect(at("cpp", "/* the ‸loop */\nint main() {}\n")).toBeNull();
  });

  it("says nothing on an empty document", () => {
    for (const lang of ["rust", "go", "cpp", "python"] as Land[]) {
      expect(at(lang, "‸")).toBeNull();
    }
  });

  it("inProse is the same answer, for anyone who only needs that half", () => {
    expect(inProse(contextOf("rust", "fn f() {\n    // ‸x\n}\n").path)).toBe(true);
    expect(inProse(contextOf("rust", "fn f() {\n    let ‸x = 1;\n}\n").path)).toBe(false);
  });
});

describe("the catalogue itself", () => {
  const all = catalogue();

  it("has no two entries under one id", () => {
    expect(new Set(all.map((h) => h.id)).size).toBe(all.length);
  });

  it("fits the bubble: nothing over 160 characters", () => {
    // `Coder.say` shows a streamed reply's last 158 characters and a whole
    // one as it is; four lines of the bubble is about this much.
    const long = all.filter((h) => h.text.length > 160);
    expect(long.map((h) => `${h.id} (${h.text.length})`)).toEqual([]);
  });

  it("is a sentence each, with the back-quotes closed", () => {
    for (const h of all) {
      expect(h.text, h.id).toMatch(/[.!?]$/);
      expect((h.text.match(/`/g) ?? []).length % 2, `${h.id}: odd back-quote`).toBe(0);
    }
  });

  it("covers all four lands on both layers", () => {
    for (const lang of ["rust", "go", "cpp", "python"]) {
      expect(all.filter((h) => h.id.startsWith(`${lang}.w.`)).length).toBeGreaterThan(15);
      expect(all.filter((h) => h.id.startsWith(`${lang}.n.`)).length).toBeGreaterThan(15);
    }
  });
});
