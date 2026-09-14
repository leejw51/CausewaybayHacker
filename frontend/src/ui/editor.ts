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
  Prec,
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
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
  insertNewline,
} from "@codemirror/commands";
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
    // An empty ghost is not a ghost: it is the marker for a divergence that
    // has no width of its own — a stray blank line past the end.
    el.className = this.text === "" ? "cwb-wrong cwb-wrong-empty" : "cwb-ghost";
    el.textContent = this.text;
    return el;
  }
  ignoreEvent(): boolean {
    return false;
  }
}

/** A hole in the answer, as `[from, to)` character offsets. */
export interface Blank {
  from: number;
  to: number;
}

/** What the editor is aiming at: the answer, and the holes cut in it. */
export interface Target {
  text: string;
  /** Empty in plain ANSWER; the gaps to be typed in BLANKS. */
  blanks: Blank[];
}

const setAnswer = StateEffect.define<Target | null>();

const answerField = StateField.define<Target | null>({
  create: () => null,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setAnswer)) return e.value;
    return value;
  },
});

/**
 * The holes, chosen once per target.
 *
 * **Words, not characters.** A gap in the middle of `println` is a typing
 * exercise; a gap where `println` was is a memory one, and memory is what
 * this mode is for. Roughly a third of the identifiers and numbers, taken
 * by a seeded generator so the same quest gives the same drill for as long
 * as it is open — a set that reshuffled under the player every keystroke
 * would be unplayable.
 *
 * The rest of the program stays on screen. That is the whole point of the
 * mode: you read the shape and remember the pieces.
 */
export function answerBlanks(answer: string, seed = 1): Blank[] {
  const words: Blank[] = [];
  const re = /[A-Za-z_][A-Za-z0-9_]*|[0-9]+/g;
  for (let m = re.exec(answer); m !== null; m = re.exec(answer)) {
    words.push({ from: m.index, to: m.index + m[0].length });
  }
  if (words.length === 0) return [];
  let r = (seed >>> 0) || 1;
  const next = (): number => {
    r = (Math.imul(r, 1664525) + 1013904223) >>> 0;
    return r / 4294967296;
  };
  const out = words.filter(() => next() < 0.34);
  // Never a drill with nothing in it: a short answer whose every word the
  // generator happened to skip would be ANSWER with extra steps.
  if (out.length === 0) out.push(words[Math.floor(words.length / 2)]);
  return out;
}

/**
 * The holes for "type only the answer": everything the quest did *not* give
 * you.
 *
 * A quest ships a starter — the imports, the `func main`, the scaffold — and
 * the answer is that with a solution written into it. Typing the scaffold
 * back out teaches nobody anything, so this cuts the holes at exactly the
 * lines the answer has and the starter does not: the scaffold types itself
 * and the player writes the part that is the actual work.
 *
 * Line-based, by longest common subsequence, so a solution in two places —
 * an import up here, a loop down there — leaves the untouched middle alone
 * instead of swallowing it in one span. A hole starts after a line's
 * indentation, which the mode fills on its own.
 */
export function solutionBlanks(answer: string, starter: string): Blank[] {
  const a = answer.split("\n");
  const b = (starter ?? "").split("\n");
  // LCS over lines. The texts are a screenful, so the table is cheap and the
  // result is the thing that matters: which answer lines are *new*.
  const table: number[][] = Array.from({ length: a.length + 1 }, () =>
    new Array<number>(b.length + 1).fill(0),
  );
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      table[i][j] =
        a[i] === b[j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1]);
    }
  }
  const shared = new Array<boolean>(a.length).fill(false);
  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) {
      shared[i] = true;
      i++;
      j++;
    } else if (table[i + 1][j] >= table[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  // A quest whose answer is its starter *minus* a line — a "delete the bug"
  // quest — shares every line it has, and would leave the player nothing to
  // type at all. There is no scaffold to skip there, so the honest reading is
  // that the whole thing is theirs.
  if (!shared.some((s, k) => !s && a[k].trim() !== "")) shared.fill(false);

  const out: Blank[] = [];
  let at = 0;
  for (let k = 0; k < a.length; k++) {
    const line = a[k];
    if (!shared[k]) {
      const indent = (/^[ \t]*/.exec(line)?.[0] ?? "").length;
      // A line that is only whitespace has nothing to type.
      if (indent < line.length) out.push({ from: at + indent, to: at + line.length });
    }
    at += line.length + 1;
  }
  return out;
}

/** True while `at` is inside a hole — the part that is the player's to type. */
function blankAt(blanks: Blank[], at: number): Blank | undefined {
  return blanks.find((b) => at >= b.from && at < b.to);
}

/**
 * What the editor should fill in for the player right now.
 *
 * In BLANKS the answer is on the screen except for its holes, so everything
 * between one hole and the next is typed *for* you the moment you arrive at
 * it. What comes back is the run from the caret to the start of the next
 * hole — or `null` when the caret is inside a hole (yours to type), when the
 * buffer has stopped being the answer (fix it first), or when there is
 * nothing left.
 */
export function blanksFill(typed: string, target: Target): string | null {
  const { text, blanks } = target;
  if (blanks.length === 0) return null;
  const { matched } = answerProgress(typed, text);
  if (typed.length !== matched) return null;
  if (blankAt(blanks, matched)) return null;
  const next = blanks.find((b) => b.from >= matched);
  const upto = next ? next.from : text.length;
  return upto > matched ? text.slice(matched, upto) : null;
}

/**
 * The answer as the *ghost* should show it: holes masked.
 *
 * Drawing the real text inside a hole would hand the player the very word
 * the drill is asking them for. The mask keeps the line's shape — and its
 * width — so the program on screen still reads as the program.
 */
export function maskBlanks(target: Target): string {
  const { text, blanks } = target;
  if (blanks.length === 0) return text;
  let out = "";
  let at = 0;
  for (const b of blanks) {
    out += text.slice(at, b.from) + "_".repeat(b.to - b.from);
    at = b.to;
  }
  return out + text.slice(at);
}

function ghostFor(view: EditorView): DecorationSet {
  const target = view.state.field(answerField, false) ?? null;
  if (target === null) return Decoration.none;
  const doc = view.state.doc;
  // Two readings of the same answer: what is drawn (holes masked) and what
  // is compared against (the answer itself). Comparing against the mask
  // would call a correctly typed word a divergence.
  const want = target.text.split("\n");
  const shown = maskBlanks(target).split("\n");
  const out: Range<Decoration>[] = [];
  const last = doc.lines;
  for (let i = 1; i <= last; i++) {
    const line = doc.line(i);
    const line_target = i <= want.length ? want[i - 1] : null;
    if (line_target === null) {
      // Typed past the end of the answer: all of this line is the divergence.
      if (line.text.length > 0) {
        out.push(Decoration.mark({ class: "cwb-wrong" }).range(line.from, line.to));
      } else {
        // **An empty line is a divergence with no width.** A mark over it is
        // a zero-length range, which draws nothing — so the count said FIX
        // THE RED with no red anywhere on screen. A stray blank line is the
        // commonest way to be past the end of an answer, so it gets a mark
        // of its own.
        out.push(
          Decoration.widget({ widget: new GhostText("", false), side: 1 }).range(line.to),
        );
      }
      continue;
    }
    let k = 0;
    while (k < line.text.length && k < line_target.length && line.text[k] === line_target[k]) k++;
    if (k < line.text.length) {
      out.push(Decoration.mark({ class: "cwb-wrong" }).range(line.from + k, line.to));
    }
    // **One widget per line, and the tail merged into the last of them.**
    // The lines past the end of the document used to be a block widget of
    // their own, which on an empty document — which is exactly what ANSWER
    // opens on now that it clears the starter — lands at the same position
    // as this line's inline one. Two widgets at one position is a range set
    // CodeMirror will not take, the plugin that built it is dropped, and the
    // ghost silently does not appear at all.
    let rest = (shown[i - 1] ?? line_target).slice(k);
    if (i === last && want.length > last) rest += "\n" + shown.slice(last).join("\n");
    if (rest.length > 0) {
      out.push(Decoration.widget({ widget: new GhostText(rest, false), side: 1 }).range(line.to));
    }
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

/**
 * One line of the answer, for the button that asks for one.
 *
 * **A line at a time, on a press.** It was a TAB binding and that was wrong:
 * TAB is the editor's key, a person writing code reaches for it to indent,
 * and a mode that quietly took it made the editor feel broken. A button asks
 * for exactly as much as it says and takes nothing away from typing.
 *
 * The rest of the line you are on, or — standing at a line's end — the
 * newline and the next line's indentation, because typing eight spaces from
 * memory teaches nobody anything.
 *
 * `null` when there is nothing to give: the answer is typed, or the buffer
 * has stopped being the answer. Completing past a divergence would bury the
 * mistake under correct text.
 */
export function answerCompletion(typed: string, answer: string): string | null {
  const { matched } = answerProgress(typed, answer);
  if (typed.length !== matched) return null;
  const rest = answer.slice(matched);
  if (rest.length === 0) return null;
  if (rest.startsWith("\n")) {
    const next = rest.slice(1);
    const indent = /^[ \t]*/.exec(next)?.[0] ?? "";
    return "\n" + indent;
  }
  const nl = rest.indexOf("\n");
  return nl === -1 ? rest : rest.slice(0, nl);
}

/**
 * The answer's own indentation at the start of a line, to be filled in.
 *
 * **Indentation is never the exercise, and it cannot be typed anyway.** A Go
 * answer is tab-indented (gofmt), a Rust one is four spaces (rustfmt), and
 * the editor's auto-indent guesses one of them for every language — so on a
 * Go quest the space bar could never match the answer's tab, the line stayed
 * red, and there was no key that would fix it. That was reported, and it was
 * unfinishable.
 *
 * So the mode fills the run of spaces and tabs that starts a line, exactly as
 * the answer has it, and the player types the code.
 */
export function answerIndent(typed: string, answer: string): string | null {
  const { matched } = answerProgress(typed, answer);
  if (typed.length !== matched) return null;
  if (matched > 0 && answer[matched - 1] !== "\n") return null;
  const run = /^[ \t]+/.exec(answer.slice(matched))?.[0] ?? "";
  return run.length > 0 ? run : null;
}

export function answerProgress(typed: string, answer: string): AnswerProgress {
  let k = 0;
  while (k < typed.length && k < answer.length && typed[k] === answer[k]) k++;
  return { matched: k, wrong: typed.length - k, done: typed === answer, total: answer.length };
}

/**
 * ENTER, while the mode is on: a plain newline.
 *
 * The editor's own `insertNewlineAndIndent` guesses an indent — spaces, at
 * its own width — and against an answer indented any other way that guess is
 * a divergence the player did not type and cannot remove by typing. The mode
 * puts the answer's own indentation in a moment later (`answerIndent`), so
 * the editor must not put its guess in first.
 */
const answerEnter: Extension = Prec.highest(
  keymap.of([
    {
      key: "Enter",
      run: (view) => {
        if ((view.state.field(answerField, false) ?? null) === null) return false;
        return insertNewline(view);
      },
    },
  ]),
);

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
        answerEnter,
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
  setAnswer(target: Target | null): void {
    this.view.dispatch({ effects: setAnswer.of(target) });
  }

  /**
   * Put text in at the end and leave the caret after it.
   *
   * BLANKS uses it to type the parts that are not the drill: the answer
   * arrives around the holes as the player reaches them.
   */
  appendAtEnd(text: string): void {
    const at = this.view.state.doc.length;
    this.view.dispatch({
      changes: { from: at, insert: text },
      selection: { anchor: at + text.length },
      scrollIntoView: true,
    });
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
