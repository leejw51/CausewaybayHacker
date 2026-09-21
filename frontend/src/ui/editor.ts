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
 *
 * Which leaves one hole, and `suggest` is it. The editor still has no opinion
 * of its own — it renders a suggestion somebody else computed and takes TAB
 * for it, and the only somebody is the coder (`ui/agent/coder.ts`), which is
 * off until the player turns it on. An opinion you asked for is not a second
 * opinion; and `contextAt` is the same deal in the other direction — the
 * parse tree is already here for the colours, so anything that wants to know
 * what the caret is standing in can ask, and decide elsewhere.
 */
import {
  Compartment,
  EditorState,
  Prec,
  StateEffect,
  StateField,
  Transaction,
  type Extension,
  type Range,
} from "@codemirror/state";
import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
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
  redo,
  redoDepth,
  undo,
  undoDepth,
} from "@codemirror/commands";
import {
  HighlightStyle,
  bracketMatching,
  ensureSyntaxTree,
  indentOnInput,
  indentUnit,
  matchBrackets,
  syntaxHighlighting,
  syntaxTree,
} from "@codemirror/language";
import { tags as t } from "@lezer/highlight";
import { rust } from "@codemirror/lang-rust";
import { go } from "@codemirror/lang-go";
import { cpp } from "@codemirror/lang-cpp";
import { python } from "@codemirror/lang-python";
import { RUBBLE_MAX } from "../engine/burst";
import { Theme } from "../engine/theme";
import type { Land } from "../net/protocol";
import type { CodeContext } from "../ai/help";

/** The syntax mode per land: highlighting and indentation, nothing cleverer. */
const MODE: Record<Land, () => Extension> = { rust, go, cpp, python };

/**
 * The file the server compiles for each land (SPEC §5.1), which is what the
 * editor's panel title calls the thing you are typing into.
 */
/**
 * How big the player likes code, as a multiple of the screen's own size.
 *
 * One preference, not one per screen: "how big I like my code" is a fact
 * about the person, and a quest screen and a scratchpad that disagreed about
 * it would be two settings to keep in step by hand.
 */
export const CODE_FONT_KEY = "quest.font";
/** Which face code is drawn in. Beside the size, and shared the same way. */
export const CODE_FACE_KEY = "quest.face";
export const CODE_FONT_MIN = 0.7;
export const CODE_FONT_MAX = 2.4;

/**
 * What one level of indentation is, per land: what each land's formatter
 * would write, so a block the editor indents on ENTER is a block FORMAT
 * leaves alone. CodeMirror's default is two spaces, which in a 16-bit
 * monospace face barely reads as an indent at all — people were reaching for
 * Tab after every ENTER to get the indentation they expected.
 */
export const INDENT: Record<Land, string> = {
  rust: "    ",
  go: "\t",
  cpp: "    ",
  python: "    ",
};

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

/**
 * Brackets that close themselves — `{` puts a `}` after the caret, ENTER
 * between the two opens the block on its own indented line — behind a
 * compartment, because the ANSWER drill compares the buffer to the answer
 * character by character from the top, and a `}` the editor typed for you
 * is a divergence you did not make. `setAnswer` turns them off with the
 * drill and back on after it.
 */
const autoClose = new Compartment();

/**
 * The lock the Rust coder holds while it types (`ui/agent/coder.ts`). Its
 * text goes in at the live caret, one character at a time, so a click or a
 * keystroke in the middle of a write would move the caret and scatter the
 * rest of the program. Locked, the content DOM stops being editable —
 * which is `EditorView.editable`, not `EditorState.readOnly`, because the
 * coder's own dispatches must keep landing — and, since a mouse click
 * moves the caret whether or not the DOM is editable, every transaction a
 * person started is dropped on the floor. The coder's are tagged `*.agent`
 * and go through; the screen's own programmatic ones carry no event.
 */
const lock = new Compartment();
const LOCKED: Extension = [
  EditorView.editable.of(false),
  EditorState.transactionFilter.of((tr) => {
    const ev = tr.annotation(Transaction.userEvent);
    return ev !== undefined && !/\.agent$/.test(ev) ? [] : tr;
  }),
];

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
  let r = seed >>> 0 || 1;
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
        out.push(Decoration.widget({ widget: new GhostText("", false), side: 1 }).range(line.to));
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

/**
 * The coder's suggestion: grey text at the caret that TAB turns real.
 *
 * Computed nowhere near here (`ai/complete.ts`, from the grammar and from
 * the words already in the file) and pushed in by whoever is offering it.
 * The editor's part is three rules and no cleverness:
 *
 *   * **it dies on contact.** Any edit, any selection move, anything that is
 *     not the accept itself clears the field. A ghost that survived the next
 *     keystroke would be a suggestion about a line that no longer exists.
 *   * **TAB only takes it when there is one.** `indentWithTab` is in the
 *     keymap and TAB has to keep indenting; the handler returns false when
 *     there is nothing to accept, and the ordinary binding runs. ESC the
 *     same way, so ESC still reaches the scene.
 *   * **never over a drill.** ANSWER and BLANKS already draw ghost text —
 *     that is the exercise. Two ghosts on one line is nobody's idea of help,
 *     so a suggestion is refused outright while a target is set.
 */
export interface Suggest {
  text: string;
  /** Where the caret lands inside `text` once it is in. */
  caret: number;
}

class HintText extends WidgetType {
  constructor(readonly text: string) {
    super();
  }
  eq(other: HintText): boolean {
    return other.text === this.text;
  }
  toDOM(): HTMLElement {
    const el = document.createElement("span");
    el.className = "cwb-hint";
    el.textContent = this.text;
    return el;
  }
  ignoreEvent(): boolean {
    return false;
  }
}

const setSuggest = StateEffect.define<Suggest | null>();

const suggestField = StateField.define<Suggest | null>({
  create: () => null,
  update(value, tr) {
    let next = value;
    // The document moved or the caret did: whatever was offered was about
    // the old one. Effects in the same transaction win, which is what lets
    // the accept clear the field in the transaction that inserts the text.
    if (tr.docChanged || tr.selection) next = null;
    for (const e of tr.effects) if (e.is(setSuggest)) next = e.value;
    return next;
  },
});

/** Draws it, at the caret, and only when the field has something in it. */
const hint = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = hintFor(view.state);
    }
    update(u: ViewUpdate): void {
      const touched = u.transactions.some((tr) => tr.effects.some((e) => e.is(setSuggest)));
      if (u.docChanged || u.selectionSet || touched) this.decorations = hintFor(u.state);
    }
  },
  { decorations: (v) => v.decorations },
);

function hintFor(state: EditorState): DecorationSet {
  const s = state.field(suggestField, false) ?? null;
  if (s === null || s.text === "") return Decoration.none;
  const at = state.selection.main.head;
  return Decoration.set([Decoration.widget({ widget: new HintText(s.text), side: 1 }).range(at)]);
}

/** Put the suggestion in. Answers false when there was nothing to put in. */
function acceptSuggest(view: EditorView): boolean {
  const s = view.state.field(suggestField, false) ?? null;
  if (s === null || s.text === "") return false;
  const at = view.state.selection.main.head;
  view.dispatch({
    changes: { from: at, insert: s.text },
    selection: { anchor: at + Math.min(s.caret, s.text.length) },
    scrollIntoView: true,
    effects: setSuggest.of(null),
    // The same event the coder's own typing carries, for the same reason
    // (see "the agent's hands" below): `indentOnInput` must not re-indent
    // the `}` a multi-line template already indented itself.
    userEvent: "input.agent",
  });
  return true;
}

const suggestKeys: Extension = Prec.highest(
  keymap.of([
    { key: "Tab", run: acceptSuggest },
    {
      key: "Escape",
      run: (view) => {
        if ((view.state.field(suggestField, false) ?? null) === null) return false;
        view.dispatch({ effects: setSuggest.of(null) });
        return true;
      },
    },
  ]),
);

// ---------------------------------------------------------------------------
// What typing *does*, as events for the effects layer.
//
// The editor is the game's controller on the code screens, and a controller
// that only reports "the document changed" is a controller with one button.
// So every user-driven transaction is read for what it was — a character
// typed, one erased, ENTER pressed, a loop closed, a bracket matched — and
// handed out with the screen position it happened at, in client pixels, so
// `ui/codefx.ts` can put something there. Everything here is pure over the
// editor's state except the final measurement, and `tests/codefx.test.ts`
// holds the rules.
// ---------------------------------------------------------------------------

/**
 * What a character *is*, for the colour of the spark it throws — the same
 * families the syntax highlighter paints, so the effect is the code's own
 * colour leaving the caret.
 */
export type Tone =
  | "keyword"
  | "name"
  | "call"
  | "type"
  | "string"
  | "number"
  | "comment"
  | "operator"
  | "bracket"
  | "plain";

/** Client-pixel coordinates: `[x, y]`. */
export type Pt = readonly [number, number];

export type EditEvent =
  /** Text arrived at the caret. `at` is the caret after it, top of the line. */
  | { kind: "type"; at: Pt; text: string; tone: Tone; cell: Pt }
  /**
   * Text was removed. `at` is the top-left of where it started, `column`
   * how far into its line that was (so a second line of it starts `column`
   * cells left of `at`), and `tones` one per character of `text`, up to
   * `RUBBLE_MAX` of them.
   */
  | { kind: "erase"; at: Pt; text: string; tones: Tone[]; column: number; cell: Pt }
  /** ENTER. `at` is the caret on the new line. */
  | { kind: "enter"; at: Pt; cell: Pt }
  /** A loop was finished: `open` is its keyword's centre, `close` its end. */
  | { kind: "loop"; open: Pt; close: Pt; cell: Pt }
  /** The caret sits by a bracket whose partner lit up; both centres. */
  | { kind: "bracket"; a: Pt; b: Pt; cell: Pt }
  /**
   * The caret went from one cell to another — by key, click, typing or a
   * jump. Both are the top-left of the caret's cell, held inside the
   * editor's visible box, so a caret that came from off the screen comes
   * from its edge.
   */
  | { kind: "move"; from: Pt; to: Pt; cell: Pt };

/**
 * The syntax-tree node names that are loops, per language. Read off the
 * Lezer grammars the editor already ships; a C++ `do … while` closes on its
 * `;` rather than its brace, which is why the closer set below has one.
 */
const LOOPS: Record<Land, ReadonlySet<string>> = {
  rust: new Set(["ForExpression", "WhileExpression", "LoopExpression"]),
  go: new Set(["ForStatement"]),
  cpp: new Set(["ForStatement", "WhileStatement", "DoStatement", "ForRangeLoop"]),
  python: new Set(["ForStatement", "WhileStatement"]),
};

/**
 * What a syntax-tree node is, by its name — the half of `toneOf` that does
 * not need a caret. Null where the tree has no opinion and the character
 * itself has to say (an operator, a space, a name the grammar left plain).
 *
 * Shared with the poster, which colours a whole program from its tree rather
 * than one keystroke, so the code on the picture is the code in the editor.
 */
export function toneOfNode(name: string, parent: string): Tone | null {
  if (/Comment/.test(name)) return "comment";
  if (/String|Char|Rune|Format/.test(name)) return "string";
  if (/Integer|Float|Number|Boolean|None|True|False|Escape/.test(name)) return "number";
  if (/Type|Primitive|Class|Namespace|Lifetime/.test(name)) return "type";
  if (/Identifier|VariableName|DefName|FieldName|Macro|PropertyName/.test(name)) {
    return /Call|Macro/.test(parent) ? "call" : "name";
  }
  // A keyword's node is named after itself: `for`, `fn`, `return`.
  if (/^[a-z_]+$/.test(name) && name.length > 1) return "keyword";
  return null;
}

/**
 * The tone of the character ending at `pos` — the one just typed, or the
 * last one deleted — read from the syntax tree where it has an opinion and
 * from the character itself where it does not.
 *
 * The tree first, because `f` on its own is a name and `f` at the end of
 * `if` is a keyword, and only the parser knows which. The tree may be behind
 * the document by a keystroke (it parses on idle), in which case the node
 * under the caret is a best guess and the character class breaks the tie.
 */
export function toneOf(state: EditorState, pos: number, ch: string): Tone {
  if (ch !== "" && "{}[]()".includes(ch)) return "bracket";
  const node = syntaxTree(state).resolveInner(Math.max(0, pos), -1);
  const byTree = toneOfNode(node.name, node.parent?.name ?? "");
  if (byTree) return byTree;
  if (/[0-9]/.test(ch)) return "number";
  if (/["'`]/.test(ch)) return "string";
  if (/[A-Za-z_]/.test(ch)) return "name";
  if (/\s/.test(ch) || ch === "") return "plain";
  return "operator";
}

/**
 * Whether inserting `text` at `from` finished a loop, and which one.
 *
 * In the brace languages a loop is done when its closing `}` (or, for a C++
 * `do … while`, its `;`) is typed: the node that ends exactly there is
 * looked up and walked outward to the first loop. In Python there is no
 * closing character — a loop is done when its body has something in it — so
 * ENTER at the end of the *first* body line is the moment, and only that
 * line, or every line of a long body would be a celebration.
 *
 * `null` when nothing was finished. The tree is parsed up to the caret if it
 * is behind, within a small budget; a parse that cannot make it in time is a
 * missed effect, not a stall.
 */
export function loopClosedBy(
  state: EditorState,
  lang: Land,
  from: number,
  text: string,
): { from: number; to: number } | null {
  if (text.length === 0) return null;
  const loops = LOOPS[lang];
  if (lang === "python") {
    if (text[0] !== "\n") return null;
    // ENTER at the end of a line, not one splitting a line in two: what
    // follows the inserted text must be a line break or the end.
    const after = from + text.length;
    if (after < state.doc.length && state.doc.sliceString(after, after + 1) !== "\n") return null;
    const tree = ensureSyntaxTree(state, from, 30);
    if (!tree) return null;
    let node: import("@lezer/common").SyntaxNode | null = tree.resolveInner(from, -1);
    while (node && !loops.has(node.name)) node = node.parent;
    if (!node) return null;
    const body = node.getChild("Body");
    if (!body) return null;
    let first = body.firstChild;
    while (first && !/^[A-Z]/.test(first.name)) first = first.nextSibling;
    if (!first || from < first.from || from > first.to) return null;
    return { from: node.from, to: from };
  }
  const last = text[text.length - 1];
  if (last !== "}" && !(last === ";" && lang === "cpp")) return null;
  const pos = from + text.length;
  const tree = ensureSyntaxTree(state, pos, 30);
  if (!tree) return null;
  let node: import("@lezer/common").SyntaxNode | null = tree.resolveInner(pos, -1);
  // The character has to *be* the closer, as the parser reads it. A `}` typed
  // inside an unfinished string — `"{i}` on the way to `"{i}"` — is a
  // character of the string, and everything unfinished above it ends at the
  // caret too, so without this the loop around it would count as closed. A
  // `;` has no node of its own in the C++ grammar, so there the innermost
  // node is the `do` statement it finishes.
  if (!node || (node.name !== last && !loops.has(node.name))) return null;
  while (node && node.to === pos) {
    if (loops.has(node.name)) {
      // And the loop has to be whole: a body with a parse error in it is
      // not finished, whatever brace was just typed.
      return hasError(node) ? null : { from: node.from, to: pos };
    }
    node = node.parent;
  }
  return null;
}

/** Whether any node inside `node` is a parse error. */
function hasError(node: import("@lezer/common").SyntaxNode): boolean {
  const c = node.cursor();
  do {
    if (c.type.isError) return true;
  } while (c.next() && c.to <= node.to && c.from >= node.from);
  return false;
}

/**
 * The bracket pair the caret is beside, as `[open, close]` offsets, or
 * `null`.
 *
 * The same four looks `bracketMatching` takes, in the same order — a closer
 * just before the caret, an opener just before it, an opener just after, a
 * closer just after — so what lights up here is exactly what the highlighter
 * lit up. `matchBrackets` is directional: `-1` only ever reads a closing
 * bracket and `1` only an opening one, which is why one call is not enough.
 */
export function bracketPairAt(state: EditorState, head: number): [number, number] | null {
  const m =
    matchBrackets(state, head, -1) ??
    (head > 0 ? matchBrackets(state, head - 1, 1) : null) ??
    matchBrackets(state, head, 1) ??
    (head < state.doc.length ? matchBrackets(state, head + 1, -1) : null);
  if (!m || !m.matched || !m.end) return null;
  return m.start.from < m.end.from ? [m.start.from, m.end.from] : [m.end.from, m.start.from];
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
  keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...historyKeymap, indentWithTab]),
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
  private lang: Land;
  /**
   * Where the effects go. Set by the screen that owns the editor; nothing is
   * measured while it is null, so an editor nobody is decorating pays
   * nothing for the option.
   */
  events: ((e: EditEvent) => void) | null = null;
  /** The bracket pair last reported, so a caret resting by one reports once. */
  private lastPair: string | null = null;
  /** Where the caret was last measured, for the smear from there to here. */
  private lastCaret: Pt | null = null;
  /** Whether the editor had focus when it was locked, to hand back after. */
  private refocus = false;

  constructor(lang: Land, doc: string, onChange?: () => void) {
    this.dom.className = "cwb-editor";
    this.lang = lang;
    this.view = new EditorView({
      parent: this.dom,
      state: this.stateFor(lang, doc, onChange),
    });
    this.onChange = onChange;
  }

  private onChange?: () => void;

  /**
   * Read one update for the events above, and measure them on the next
   * layout pass.
   *
   * Only transactions with a user event are read: the formatter's
   * `replaceAll`, a quest's `load` and BLANKS' `appendAtEnd` change the
   * document too, and a wall of bricks every time FORMAT is pressed would
   * teach people not to press it. The positions are resolved in a
   * `requestMeasure` read rather than here, because a layout read inside an
   * update listener forces the browser to lay the whole editor out
   * synchronously, once per keystroke.
   */
  private harvest(u: ViewUpdate): void {
    if (!this.events) return;
    type Job = (view: EditorView, cell: Pt) => EditEvent | null;
    const jobs: Job[] = [];
    // The read runs a frame later, and the document may have moved on by
    // then — `indentOnInput` dedents the `}` you just typed in a transaction
    // of its own, and a position past the new end throws. A keystroke's
    // position is clamped rather than mapped: the effect is at the caret
    // either way, and the caret is where the document now ends.
    const coords = (view: EditorView, pos: number) => {
      try {
        return view.coordsAtPos(Math.min(pos, view.state.doc.length));
      } catch {
        return null;
      }
    };
    const topLeft = (view: EditorView, pos: number): Pt | null => {
      const c = coords(view, pos);
      return c ? [c.left, c.top] : null;
    };
    const centre = (view: EditorView, pos: number, cell: Pt): Pt | null => {
      const c = coords(view, pos);
      return c ? [c.left + cell[0] / 2, (c.top + c.bottom) / 2] : null;
    };
    // A cell held inside the editor's visible box: a PageDown scrolls, and
    // the caret's old place may now be above the top of it.
    const inside = (view: EditorView, p: Pt, cell: Pt): Pt => {
      const box = view.scrollDOM.getBoundingClientRect();
      return [
        Math.min(Math.max(p[0], box.left), Math.max(box.left, box.right - cell[0])),
        Math.min(Math.max(p[1], box.top), Math.max(box.top, box.bottom - cell[1])),
      ];
    };
    const lang = this.lang;
    for (const tr of u.transactions) {
      if (!tr.docChanged || tr.annotation(Transaction.userEvent) === undefined) continue;
      tr.changes.iterChanges((fromA, toA, fromB, toB, inserted) => {
        const text = inserted.toString();
        if (toA > fromA) {
          const gone = tr.startState.doc.sliceString(fromA, toA);
          // Whitespace swapped for text is a re-indent — `}` typed on an
          // indented line is pulled back to its block by `indentOnInput` —
          // and nothing was broken there. Whitespace simply deleted still
          // was.
          const reindent = text.length > 0 && gone.trim() === "";
          if (!reindent) {
            // A tone per character, so a deleted line crumbles in its own
            // colours. Read from the tree the text was in, not the one it
            // has gone from.
            const tones: Tone[] = [];
            const limit = Math.min(gone.length, RUBBLE_MAX);
            for (let i = 0; i < limit; i++) {
              tones.push(
                gone[i].trim() === "" ? "plain" : toneOf(tr.startState, fromA + i + 1, gone[i]),
              );
            }
            const column = fromB - tr.state.doc.lineAt(fromB).from;
            jobs.push((view, cell) => {
              const at = topLeft(view, fromB);
              return at ? { kind: "erase", at, text: gone, tones, column, cell } : null;
            });
          }
        }
        if (text.length === 0) return;
        if (text[0] === "\n" && text.trim() === "") {
          jobs.push((view, cell) => {
            const at = topLeft(view, toB);
            return at ? { kind: "enter", at, cell } : null;
          });
        } else {
          const tone = toneOf(tr.state, toB, text[text.length - 1]);
          jobs.push((view, cell) => {
            const at = topLeft(view, toB);
            return at ? { kind: "type", at, text, tone, cell } : null;
          });
        }
        const loop = loopClosedBy(tr.state, lang, fromB, text);
        if (loop) {
          jobs.push((view, cell) => {
            const open = centre(view, loop.from, cell);
            const close = centre(view, Math.max(loop.from, loop.to - 1), cell);
            return open && close ? { kind: "loop", open, close, cell } : null;
          });
        }
      });
    }
    if (u.selectionSet || u.docChanged) {
      const pair = bracketPairAt(u.state, u.state.selection.main.head);
      const key = pair ? `${pair[0]}:${pair[1]}` : null;
      if (key !== this.lastPair) {
        this.lastPair = key;
        if (pair) {
          jobs.push((view, cell) => {
            const a = centre(view, pair[0], cell);
            const b = centre(view, pair[1], cell);
            return a && b ? { kind: "bracket", a, b, cell } : null;
          });
        }
      }
    }
    if (u.selectionSet || u.docChanged) {
      const head = u.state.selection.main.head;
      if (head !== u.startState.selection.main.head || u.docChanged) {
        jobs.push((view, cell) => {
          const from = this.lastCaret;
          const raw = topLeft(view, head);
          const to = raw ? inside(view, raw, cell) : null;
          this.lastCaret = to;
          if (!from || !to) return null;
          if (Math.abs(from[0] - to[0]) < 0.5 && Math.abs(from[1] - to[1]) < 0.5) return null;
          return { kind: "move", from, to, cell };
        });
      }
    }
    if (jobs.length === 0) return;
    u.view.requestMeasure({
      read: (view) => {
        const cell: Pt = [view.defaultCharacterWidth, view.defaultLineHeight];
        for (const job of jobs) {
          const e = job(view, cell);
          if (e) this.events?.(e);
        }
      },
    });
  }

  private stateFor(lang: Land, doc: string, onChange?: () => void): EditorState {
    return EditorState.create({
      doc,
      extensions: [
        base,
        indentUnit.of(INDENT[lang]),
        autoClose.of(closeBrackets()),
        lock.of([]),
        answerField,
        answerEnter,
        ghost,
        suggestField,
        hint,
        suggestKeys,
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
          this.harvest(u);
        }),
      ],
    });
  }

  /** Swap language and document together: a new quest is a new state. */
  load(lang: Land, doc: string): void {
    this.lang = lang;
    this.lastPair = null;
    // A new document: the caret's first place in it is not a move from the
    // old one.
    this.lastCaret = null;
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
   * CodeMirror's own history, per keystroke, as buttons.
   *
   * This is the fine-grained one — the same steps Ctrl+Z takes — and it lives
   * in the tab and nowhere else. The quest screen's UNDO/REDO are a different
   * thing: the server's stack, one entry per pause in typing, kept across
   * devices. The playground has no server stack and wants none; the pad
   * itself is saved, and what is undone here is the last few keystrokes.
   */
  get canUndo(): boolean {
    return undoDepth(this.view.state) > 0;
  }

  get canRedo(): boolean {
    return redoDepth(this.view.state) > 0;
  }

  /** One step back. Returns whether there was one. */
  undo(): boolean {
    return undo(this.view);
  }

  /** One step forward. Returns whether there was one. */
  redo(): boolean {
    return redo(this.view);
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
    this.view.dispatch({
      effects: [
        setAnswer.of(target),
        autoClose.reconfigure(target === null ? closeBrackets() : []),
      ],
    });
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

  /** Where the caret is in the document, for anything watching it rest. */
  get caretPos(): number {
    return this.view.state.selection.main.head;
  }

  /**
   * What the caret is standing in, for anybody who wants to say something
   * about it (`ai/help.ts`, `ai/complete.ts`).
   *
   * The parse tree is already here — the syntax colours are made of it — so
   * this costs a `resolveInner` and a walk up the parents. `ensureSyntaxTree`
   * with the same small budget `loopClosedBy` uses: a tree that cannot be
   * finished in time means no help this tick, not a stall while typing.
   */
  contextAt(): CodeContext | null {
    const state = this.view.state;
    const sel = state.selection.main;
    if (!sel.empty) return null;
    const pos = sel.head;
    const line = state.doc.lineAt(pos);
    const before = line.text.slice(0, pos - line.from);
    const word = /[A-Za-z_][A-Za-z0-9_]*$/.exec(before)?.[0] ?? "";
    const path: string[] = [];
    const tree = ensureSyntaxTree(state, pos, 30);
    if (tree) {
      let node: import("@lezer/common").SyntaxNode | null = tree.resolveInner(pos, -1);
      while (node) {
        path.push(node.name);
        node = node.parent;
      }
    }
    return { pos, path, word, before, source: state.doc.toString() };
  }

  /**
   * Offer (or withdraw) the grey text at the caret. Refused while a drill's
   * answer is on screen, which is its own ghost and has the floor.
   */
  suggest(s: Suggest | null): void {
    const now = this.view.state.field(suggestField, false) ?? null;
    const want =
      s !== null && (this.view.state.field(answerField, false) ?? null) === null ? s : null;
    if (now === want) return;
    if (now && want && now.text === want.text && now.caret === want.caret) return;
    this.view.dispatch({ effects: setSuggest.of(want) });
  }

  /** What is being offered at the caret, if anything. */
  get suggestion(): Suggest | null {
    return this.view.state.field(suggestField, false) ?? null;
  }

  /** Where the caret is on the page, for an effect thrown at it. */
  caretClient(): [number, number] | null {
    const c = this.view.coordsAtPos(this.view.state.selection.main.head);
    return c ? [c.left, (c.top + c.bottom) / 2] : null;
  }

  /** One character's cell on the page, for anything that sits beside the caret. */
  cellClient(): [number, number] {
    return [this.view.defaultCharacterWidth, this.view.defaultLineHeight];
  }

  // -- the agent's hands --------------------------------------------------
  //
  // The Rust coder (`ui/agent/coder.ts`) types into the editor one character
  // at a time. Its edits carry a user event of their own, `input.agent`:
  // *defined*, so `harvest` throws the sparks a keystroke gets and the
  // typing reads as typing; *not* `input.type`, so `indentOnInput` does not
  // re-indent a `}` the agent has already indented itself, which would put
  // its braces in the wrong column twice over.

  /** Whether the coder holds the editor: see `lock`. */
  get locked(): boolean {
    return !this.view.state.facet(EditorView.editable);
  }

  /**
   * Hold the editor against the person while the coder types, or give it
   * back. Programmatic dispatches — the coder's typing, a FORMAT — still
   * land; what the person does with the keyboard or the mouse does not.
   */
  setLocked(on: boolean): void {
    if (on === this.locked) return;
    // A content DOM that stops being editable loses the focus it had; give
    // it back with the lock, so the person is where they were.
    if (on) this.refocus = this.view.hasFocus;
    this.view.dispatch({ effects: lock.reconfigure(on ? LOCKED : []) });
    if (!on && this.refocus) {
      this.refocus = false;
      this.view.focus();
    }
  }

  /** Type `text` at the caret and leave the caret after it. */
  typeAt(text: string): void {
    const head = this.view.state.selection.main.head;
    this.view.dispatch({
      changes: { from: head, insert: text },
      selection: { anchor: head + text.length },
      scrollIntoView: true,
      userEvent: "input.agent",
    });
  }

  /** Empty the document, silently: what follows is the typing, not this. */
  clearAll(): void {
    const len = this.view.state.doc.length;
    if (len === 0) return;
    this.view.dispatch({ changes: { from: 0, to: len }, selection: { anchor: 0 } });
  }

  /**
   * Put the caret at `from` with `to - from` characters selected and
   * removed, for an edit that is then typed in over the gap. Answers false
   * when the span is not in the document.
   */
  cut(from: number, to: number): boolean {
    const len = this.view.state.doc.length;
    if (from < 0 || to > len || from > to) return false;
    this.view.dispatch({
      changes: { from, to },
      selection: { anchor: from },
      scrollIntoView: true,
      userEvent: "delete.agent",
    });
    return true;
  }

  /**
   * Put whole lines in **above** the line the caret is on, indented like it,
   * and leave the caret on the same text it was on.
   *
   * For the coder's answer-as-a-comment (`ai/notes.ts`): the person asked
   * about the line they were looking at, so the answer belongs directly above
   * it and their caret should not move relative to their code. One dispatch,
   * so one CTRL+Z takes the whole block back out again — which is the only
   * promise worth making about text that appeared in somebody's file without
   * them typing it.
   */
  noteAbove(lines: string[]): void {
    if (lines.length === 0) return;
    const state = this.view.state;
    const head = state.selection.main.head;
    // A caret at the very top usually means nobody has put it anywhere: the
    // question was typed into the chat field and the editor has never been
    // clicked. An answer about the program then belongs after the program,
    // not wedged above its first line — which on every land is `package
    // main` or `use`, the one place a remark reads as a mistake.
    if (head === 0 && state.doc.length > 0) {
      const tail = state.doc.toString().endsWith("\n") ? "" : "\n";
      this.appendAtEnd(tail + lines.join("\n") + "\n");
      return;
    }
    const line = state.doc.lineAt(head);
    const indent = /^[ \t]*/.exec(line.text)?.[0] ?? "";
    const insert = lines.map((l) => indent + l).join("\n") + "\n";
    this.view.dispatch({
      changes: { from: line.from, insert },
      selection: { anchor: head + insert.length },
      scrollIntoView: true,
      userEvent: "input.agent",
    });
  }

  /** Put the caret at `pos`, scrolled into view. */
  seek(pos: number): void {
    const p = Math.max(0, Math.min(this.view.state.doc.length, pos));
    this.view.dispatch({ selection: { anchor: p }, scrollIntoView: true });
  }

  focus(): void {
    this.view.focus();
  }

  destroy(): void {
    this.view.destroy();
  }
}
