/**
 * CodeMirror 6, in a 16-bit box.
 *
 * SPEC §10: pixel art behind, a real editor in front. The editor is not
 * styled to *look* like the canvas — it is made transparent and sat inside a
 * well the canvas drew, so the frame is genuinely the same frame. Only the
 * syntax colours are ours, and they come from `engine/theme.ts` so the code
 * and the panels share a palette.
 *
 * The extension set is deliberately small. History, bracket matching and
 * indentation are what a person needs to write forty lines of Rust; a linter or
 * an autocomplete engine would be a second, wrong, opinion about code the
 * server is the judge of.
 */
import { EditorState, type Extension } from "@codemirror/state";
import {
  EditorView,
  keymap,
  lineNumbers,
  highlightActiveLine,
  highlightActiveLineGutter,
  drawSelection,
  rectangularSelection,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import {
  HighlightStyle,
  bracketMatching,
  indentOnInput,
  syntaxHighlighting,
} from "@codemirror/language";
import { tags as t } from "@lezer/highlight";
import { rust } from "@codemirror/lang-rust";
import { go } from "@codemirror/lang-go";
import { Theme } from "../engine/theme";
import type { Land } from "../net/protocol";

const hex = (c: readonly [number, number, number, number]) =>
  "#" +
  [c[0], c[1], c[2]]
    .map((v) =>
      Math.round(v * 255)
        .toString(16)
        .padStart(2, "0"),
    )
    .join("");

/** Wonder Boy candy applied to a syntax tree: coin, cyan, pink, cream. */
const retro = HighlightStyle.define([
  { tag: t.keyword, color: hex(Theme.pink) },
  { tag: [t.name, t.deleted, t.character, t.propertyName, t.macroName], color: hex(Theme.cream) },
  { tag: [t.function(t.variableName), t.labelName], color: hex(Theme.cyan) },
  { tag: [t.typeName, t.className, t.namespace], color: hex(Theme.coin) },
  { tag: [t.string, t.special(t.string)], color: hex(Theme.grass) },
  { tag: [t.number, t.bool, t.null], color: hex(Theme.coin) },
  { tag: [t.comment, t.meta], color: hex(Theme.dim), fontStyle: "italic" },
  { tag: t.operator, color: hex(Theme.panel) },
  { tag: t.invalid, color: hex(Theme.red) },
]);

const base: Extension = [
  lineNumbers(),
  history(),
  drawSelection(),
  rectangularSelection(),
  indentOnInput(),
  bracketMatching(),
  highlightActiveLine(),
  highlightActiveLineGutter(),
  syntaxHighlighting(retro),
  // `indentWithTab` last so Tab indents rather than leaving the editor. That
  // costs keyboard users their tab-out; Escape-then-Tab still works, which is
  // the accepted trade for a code editor.
  keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
  EditorView.theme({
    "&": { height: "100%", backgroundColor: "transparent" },
    ".cm-content": { caretColor: hex(Theme.cyan) },
    "&.cm-focused": { outline: "none" },
  }),
];

export class Editor {
  readonly dom = document.createElement("div");
  private view: EditorView;

  constructor(lang: Land, doc: string, onChange?: () => void) {
    this.dom.className = "cwb-editor";
    this.view = new EditorView({
      parent: this.dom,
      state: this.stateFor(lang, doc, onChange),
    });
    this.onChange = onChange;
  }

  private onChange?: () => void;

  private stateFor(lang: Land, doc: string, onChange?: () => void): EditorState {
    return EditorState.create({
      doc,
      extensions: [
        base,
        lang === "go" ? go() : rust(),
        EditorView.updateListener.of((u) => {
          if (u.docChanged) onChange?.();
        }),
      ],
    });
  }

  /** Swap language and document together: a new quest is a new state. */
  load(lang: Land, doc: string): void {
    this.view.setState(this.stateFor(lang, doc, this.onChange));
  }

  get source(): string {
    return this.view.state.doc.toString();
  }

  focus(): void {
    this.view.focus();
  }

  destroy(): void {
    this.view.destroy();
  }
}
