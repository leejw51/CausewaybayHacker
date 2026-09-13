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
import {
  EditorState,
  StateEffect,
  StateField,
  type Extension,
  type Range,
} from "@codemirror/state";
import {
  Decoration,
  EditorView,
  ViewPlugin,
  WidgetType,
  keymap,
  lineNumbers,
  highlightActiveLine,
  highlightActiveLineGutter,
  drawSelection,
  rectangularSelection,
  type DecorationSet,
  type ViewUpdate,
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
import { cpp } from "@codemirror/lang-cpp";
import { python } from "@codemirror/lang-python";
import { Theme } from "../engine/theme";
import type { Land } from "../net/protocol";

/** The syntax mode per land: highlighting and indentation, nothing cleverer. */
const MODE: Record<Land, () => Extension> = { rust, go, cpp, python };

/**
 * The file the server compiles for each land (SPEC §5.1), which is what the
 * editor's panel title calls the thing you are typing into.
 */
export const MAIN_FILE: Record<Land, string> = {
  rust: "main.rs",
  go: "main.go",
  cpp: "main.cpp",
  python: "main.py",
};

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

/**
 * ANSWER mode: the reference solution as ghost text, in the editor's own
 * layout.
 *
 * **Inside CodeMirror, not behind it.** A second element under the editor
 * would have to reproduce the gutter width, the line height and the padding
 * exactly, and would drift apart from them at the first type-size change.
 * These are decorations in the document's own flow, so they are aligned by
 * construction: the rest of a line hangs off the end of what you have typed,
 * and the lines you have not reached yet sit under the last one.
 *
 * What you typed that is *not* the answer is marked rather than hidden. The
 * point of the mode is to notice the divergence and fix it.
 */
class GhostText extends WidgetType {
  constructor(
    readonly text: string,
    readonly block: boolean,
  ) {
    super();
  }
  eq(other: GhostText): boolean {
    return other.text === this.text && other.block === this.block;
  }
  toDOM(): HTMLElement {
    const el = document.createElement(this.block ? "div" : "span");
    el.className = "cwb-ghost";
    el.textContent = this.text;
    return el;
  }
  ignoreEvent(): boolean {
    return false;
  }
}

const setAnswer = StateEffect.define<string | null>();

const answerField = StateField.define<string | null>({
  create: () => null,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setAnswer)) return e.value;
    return value;
  },
});

function ghostFor(view: EditorView): DecorationSet {
  const answer = view.state.field(answerField, false) ?? null;
  if (answer === null) return Decoration.none;
  const doc = view.state.doc;
  const want = answer.split("\n");
  const out: Range<Decoration>[] = [];
  const shared = Math.min(doc.lines, want.length);
  for (let i = 1; i <= shared; i++) {
    const line = doc.line(i);
    const target = want[i - 1];
    let k = 0;
    while (k < line.text.length && k < target.length && line.text[k] === target[k]) k++;
    if (k < line.text.length) {
      out.push(Decoration.mark({ class: "cwb-wrong" }).range(line.from + k, line.to));
    }
    if (k < target.length) {
      out.push(
        Decoration.widget({ widget: new GhostText(target.slice(k), false), side: 1 }).range(line.to),
      );
    }
  }
  if (want.length > doc.lines) {
    const rest = want.slice(doc.lines).join("\n");
    out.push(
      Decoration.widget({ widget: new GhostText(rest, true), side: 1, block: true }).range(
        doc.length,
      ),
    );
  }
  return Decoration.set(out, true);
}

const ghost = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = ghostFor(view);
    }
    update(u: ViewUpdate): void {
      const changed = u.transactions.some((tr) => tr.effects.some((e) => e.is(setAnswer)));
      if (u.docChanged || changed || u.viewportChanged) this.decorations = ghostFor(u.view);
    }
  },
  { decorations: (v) => v.decorations },
);

/**
 * How far the typed text still *is* the answer, and whether it has stopped
 * being it.
 *
 * A prefix, deliberately: ANSWER mode is a typing target read from the top,
 * and "the first place the two part company" is the thing a player needs
 * pointed at. Pure, so `tests/editor.test.ts` can hold the rules.
 */
export interface AnswerProgress {
  /** Characters typed that match the answer from the start. */
  matched: number;
  /** Characters typed past that point — the divergence, if any. */
  wrong: number;
  /** Every character of the answer, typed exactly. */
  done: boolean;
  total: number;
}

export function answerProgress(typed: string, answer: string): AnswerProgress {
  let k = 0;
  while (k < typed.length && k < answer.length && typed[k] === answer[k]) k++;
  return { matched: k, wrong: typed.length - k, done: typed === answer, total: answer.length };
}

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

/**
 * The smallest edit that turns `cur` into `next`: common prefix and suffix
 * trimmed off, the difference in the middle.
 *
 * Exported and pure because it is the half of "FORMAT keeps your caret" that
 * is ours — CodeMirror maps a selection through an edit, so the narrower the
 * edit, the less the caret can move. A whole-document replacement is a legal
 * edit that moves every caret; this is the same result with the caret left
 * alone. `null` means the two strings are identical and nothing should be
 * dispatched at all.
 */
export function narrowEdit(
  cur: string,
  next: string,
): { from: number; to: number; insert: string } | null {
  if (cur === next) return null;
  let a = 0;
  while (a < cur.length && a < next.length && cur[a] === next[a]) a++;
  let b = 0;
  while (
    b < cur.length - a &&
    b < next.length - a &&
    cur[cur.length - 1 - b] === next[next.length - 1 - b]
  ) {
    b++;
  }
  return { from: a, to: cur.length - b, insert: next.slice(a, next.length - b) };
}

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
        answerField,
        ghost,
        // A phone's keyboard, told this is code. Without these iOS
        // capitalises the first letter of `fn main`, turns `"hello"` into
        // “hello” and autocorrects `println` — and every one of those is a
        // compile error the player did not type.
        EditorView.contentAttributes.of({
          autocorrect: "off",
          autocapitalize: "off",
          spellcheck: "false",
          autocomplete: "off",
        }),
        MODE[lang](),
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

  /**
   * Replace the whole document while keeping the caret where the person left
   * it — for the formatter.
   *
   * A `setState` would be one line and would dump the cursor to the top and
   * drop the selection, which is infuriating if FORMAT was pressed mid-thought.
   * So the change is narrowed to the span that actually differs — common
   * prefix and suffix trimmed off — and dispatched as an edit. CodeMirror maps
   * the existing selection through an edit, so a caret above or below the
   * reformatted span does not move at all, and one inside it lands at the end
   * of the span rather than at the top of the file.
   */
  replaceAll(next: string): void {
    const edit = narrowEdit(this.view.state.doc.toString(), next);
    if (!edit) return;
    this.view.dispatch({ changes: edit, scrollIntoView: true });
  }

  get source(): string {
    return this.view.state.doc.toString();
  }

  /**
   * Whether the caret is in here.
   *
   * Asked by the quest screen, which has two undo histories to keep apart:
   * CodeMirror's own, per keystroke, and the server's edit stack, per thought.
   * Ctrl+Z reaches a scene even while the editor has the focus — an
   * accelerator has to work mid-typing — so the scene needs to be able to tell
   * that this keystroke was meant for the fine-grained one and leave it alone.
   */
  get focused(): boolean {
    return this.view.hasFocus;
  }

  /**
   * Show (or clear) the answer as ghost text. The buffer is not touched:
   * what the player has typed is theirs, and the answer is a target behind
   * it rather than a replacement for it.
   */
  setAnswer(text: string | null): void {
    this.view.dispatch({ effects: setAnswer.of(text) });
  }

  /** Where the caret is on the page, for an effect thrown at it. */
  caretClient(): [number, number] | null {
    const c = this.view.coordsAtPos(this.view.state.selection.main.head);
    return c ? [c.left, (c.top + c.bottom) / 2] : null;
  }

  focus(): void {
    this.view.focus();
  }

  destroy(): void {
    this.view.destroy();
  }
}
