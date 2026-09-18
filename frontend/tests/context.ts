/**
 * The caret, parsed: what `ui/editor.ts#contextAt` would hand `ai/help.ts`
 * and `ai/complete.ts`, built from a fixture with the caret marked.
 *
 * Shared by both tests, and it parses for real — the node names are the one
 * part of either catalogue nobody can reason out, so nothing here may be a
 * hand-written idea of what the tree looks like.
 */
import { expect } from "vitest";
import { EditorState, type Extension } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { rust } from "@codemirror/lang-rust";
import { go } from "@codemirror/lang-go";
import { cpp } from "@codemirror/lang-cpp";
import { python } from "@codemirror/lang-python";
import type { CodeContext } from "../src/ai/help";
import type { Land } from "../src/net/protocol";

/** The caret in a fixture. Not a character any of the four grammars uses. */
const MARK = "‸";

const MODE: Record<Land, () => Extension> = { rust, go, cpp, python };

/** The context the editor would build, from a fixture with the caret at `‸`. */
export function contextOf(lang: Land, marked: string): CodeContext {
  const pos = marked.indexOf(MARK);
  expect(pos, `no caret in ${marked}`).toBeGreaterThanOrEqual(0);
  const doc = marked.replace(MARK, "");
  const state = EditorState.create({ doc, extensions: [MODE[lang]()] });
  const line = state.doc.lineAt(pos);
  const before = line.text.slice(0, pos - line.from);
  const path: string[] = [];
  const tree = ensureSyntaxTree(state, pos, 5000)!;
  let node = tree.resolveInner(pos, -1) as ReturnType<typeof tree.resolveInner> | null;
  while (node) {
    path.push(node.name);
    node = node.parent;
  }
  return {
    pos,
    path,
    word: /[A-Za-z_][A-Za-z0-9_]*$/.exec(before)?.[0] ?? "",
    before,
    source: doc,
  };
}
