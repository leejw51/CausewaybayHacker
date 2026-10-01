/**
 * What the model may do, and the bench it does it on.
 *
 * The catalogue is one list of JSON-schema tools (docs/agent.md §3); each
 * provider adapter renders it into its own shape. Every tool runs **in the
 * browser**: the model asks, the `Bench` — implemented by the screen that
 * owns the editor — does it, and the result goes back as text. Nothing here
 * is a server call except through the bench's own websocket.
 *
 * One file per entry, always, so there is no path in any of these: "the
 * code" is the editor's text and that is the whole project.
 */
import type { Lang } from "../net/protocol";
import { commentLines } from "./notes";

export interface ToolDef {
  name: string;
  description: string;
  input_schema: {
    type: "object";
    properties: Record<string, { type: string; description: string; enum?: string[] }>;
    required: string[];
  };
}

export interface RunReport {
  outcome: string;
  stdout: string;
  stderr: string;
  compile_ms: number;
  run_ms: number;
  exit_code: number | null;
}

/**
 * What the person has been asked to do, on a screen that asks anything.
 *
 * The playground has none of this — a pad is whatever the person wants it to
 * be — so it is null there. On a quest it is the difference between an agent
 * that can only read the file and one that can answer "why is this wrong?",
 * which is the only question anybody actually has on a graded screen.
 *
 * A plain shape, deliberately: `ai/` does not import the wire's `Quest`, the
 * scene builds this out of one, and the LÖVE client builds the same table out
 * of its own (docs/agent.md §8 — the prompt is pinned in both suites, so what
 * feeds it has to be a shape both can make).
 */
export interface TaskBrief {
  title: string;
  /** The exercise, in the language the screen is showing it in. */
  brief: string;
  story?: string;
  /** The cases the person can see. The hidden ones are a count, never data. */
  tests: Array<{ stdin: string; expect: string }>;
  hiddenCount: number;
  cleared: boolean;
  /**
   * The reference answer — present only when the server sent one, which it
   * does only for a quest this player has already cleared (PROTOCOL §4.8).
   * There is no path here for an unsolved quest's answer, because the client
   * never has it.
   */
  solution?: string;
  /** What the last RUN said, when there has been one this visit. */
  lastRun?: {
    verdict: string;
    passed: number;
    total: number;
    stderr: string;
    /** The visible cases that did not pass, with what came out. */
    failing: Array<{ stdin: string; expect: string; got: string }>;
  };
}

/**
 * The screen's side of the bargain. `write` and `insert` are slow on purpose
 * — they resolve once the typist has finished (or was stopped) — so the
 * model's next turn is not asked for while the program is still appearing.
 */
export interface Bench {
  lang: Lang;
  file: string;
  /** The editor's text right now. */
  read(): string;
  /** Replace the whole program, typed. Resolves to how much went in. */
  write(source: string): Promise<{ typed: number; total: number; stopped: boolean }>;
  /** Type at the caret. */
  insert(text: string): Promise<{ typed: number; total: number; stopped: boolean }>;
  /** Replace one exact span (typed in). Null when `find` is not in the text exactly once. */
  edit(find: string, replace: string): Promise<{ ok: boolean; why?: string }>;
  /** RUN, as the button does. Null when this screen cannot run (a quest). */
  run: ((stdin?: string) => Promise<RunReport>) | null;
  /** The formatter, if the screen has one. */
  format: (() => Promise<{ changed: boolean; problem?: string }>) | null;
  /** The chatroom search (playground only). */
  search: ((q: string) => Promise<string>) | null;
  /** Make a picture and post it in the room (playground, openai/grok only). */
  image: ((prompt: string) => Promise<string>) | null;
  /**
   * The exercise this screen is set to, or null on one that sets none. Read
   * on every ask rather than once at mount, so the last run in it is the last
   * run and not the one the panel opened on.
   */
  task?: (() => TaskBrief | null) | null;
  /**
   * **A tutor, who does what was asked.** On a graded screen the agent also
   * gets `comment_code`, and its orders say: asked to explain, it explains
   * in comments and leaves the program alone; asked to fix or to solve, it
   * fixes or solves. Which one is the person's call, not the screen's.
   */
  tutor?: boolean;
  /**
   * Put `text` above line `line` (1-based; one past the last line appends)
   * as comment lines in the file's language, indented like that line. The
   * comment tool builds the comment itself from plain text, so there is no
   * input it can be given that lands as code. Required when `tutor` is set.
   */
  comment?: ((line: number, text: string) => Promise<{ ok: boolean; why?: string }>) | null;
  /**
   * A model turn is starting: the line numbers it uses are the file's as of
   * now. See `LineShift`.
   */
  newTurn?: () => void;
}

/**
 * The model's line numbers, read against the file it was looking at.
 *
 * One turn can ask for several comments, every one numbered against the file
 * as it was when the turn began — and each comment put in pushes the lines
 * under it down. Taken literally, the second of three notes about lines 15,
 * 16 and 17 landed *inside* the first, between its head and its wrapped
 * tail, and the three came out interleaved. So the insertions of the turn so
 * far are kept, and a line is moved down past every one put in above it —
 * or at it, so a second note about the same line goes under the first and
 * the two read in the order they were written.
 *
 * Only comments are tracked; anything else that changes the file in the
 * turn makes the old numbering unknowable, and `reset` is called for it.
 */
export class LineShift {
  private ins: Array<[number, number]> = [];

  map(line: number): number {
    let out = line;
    for (const [at, n] of this.ins) if (at <= line) out += n;
    return out;
  }

  /** `n` lines went in above the model's `line`. */
  add(line: number, n: number): void {
    this.ins.push([line, n]);
  }

  reset(): void {
    this.ins = [];
  }
}

/**
 * Where an explanation goes and what is typed there: `text` as comment lines
 * (`ai/notes.ts`'s, with the coder's `AI:` mark), above `line` and indented
 * like it. Pure, so the one guarantee that matters — nothing typed is code —
 * is a unit test and not a hope.
 *
 * Null when the line is out of range or there is nothing to say.
 */
export function commentInsert(
  lang: Lang,
  source: string,
  line: number,
  text: string,
): { at: number; text: string } | null {
  const lines = source.split("\n");
  if (!Number.isInteger(line) || line < 1 || line > lines.length + 1) return null;
  // Indented like the line it explains — or, past the end, like the last.
  const ref = lines[Math.min(line, lines.length) - 1] ?? "";
  const indent = /^[ \t]*/.exec(ref)?.[0] ?? "";
  const body = commentLines(text, lang);
  if (body.length === 0) return null;
  const typed = body.map((l) => indent + l).join("\n");
  if (line > lines.length) {
    // After the last line: a newline first, unless the file already ends in one.
    const lead = source === "" || source.endsWith("\n") ? "" : "\n";
    return { at: source.length, text: `${lead}${typed}\n` };
  }
  let at = 0;
  for (let i = 0; i < line - 1; i++) at += lines[i].length + 1;
  return { at, text: `${typed}\n` };
}

export const TOOLS: ToolDef[] = [
  {
    name: "read_code",
    description:
      "Read the whole program as it is in the editor right now, with 1-based line numbers. Call this before editing if the text may have changed since you last saw it.",
    input_schema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "edit_code",
    description:
      "Replace one exact span of the program. `find` must appear exactly once in the current text (copy it verbatim, including indentation); it is replaced by `replace`. Use this for a small change — a line, a function — rather than rewriting the file.",
    input_schema: {
      type: "object",
      properties: {
        find: {
          type: "string",
          description: "The exact text to replace; must occur exactly once.",
        },
        replace: { type: "string", description: "What to put in its place." },
        note: {
          type: "string",
          description:
            "One short sentence, for the person watching, saying what this does. Optional.",
        },
      },
      required: ["find", "replace"],
    },
  },
  {
    name: "write_code",
    description:
      "Replace the whole program with `source`. Use this for a new program or a rewrite; for a small change prefer edit_code. The text is typed into the editor one character at a time while the person watches, so keep it to what is needed.",
    input_schema: {
      type: "object",
      properties: {
        source: { type: "string", description: "The complete new program." },
        note: {
          type: "string",
          description:
            "One short sentence, for the person watching, saying what this does. Optional.",
        },
      },
      required: ["source"],
    },
  },
  {
    name: "insert_code",
    description: "Type `text` at the caret, where the person's cursor is.",
    input_schema: {
      type: "object",
      properties: { text: { type: "string", description: "The text to type at the caret." } },
      required: ["text"],
    },
  },
  {
    name: "comment_code",
    description:
      "Explain by writing a comment into the program, above one line. Give plain text — no comment markers; the game writes it as comment lines in the file's language, indented like that line. It never changes the program. Number lines as the file was when this turn began; several comments in one turn are placed for you.",
    input_schema: {
      type: "object",
      properties: {
        line: {
          type: "integer",
          description:
            "The 1-based line the explanation is about; the comment goes just above it. One past the last line appends at the end.",
        },
        text: {
          type: "string",
          description:
            "The explanation, in the person's language. Short lines; several lines are fine.",
        },
      },
      required: ["line", "text"],
    },
  },
  {
    name: "run_code",
    description:
      "Compile and run the program as the RUN button does, and get back the outcome, stdout and stderr (the compiler's own errors on a failed build). After writing code, run it and fix what the compiler says before answering.",
    input_schema: {
      type: "object",
      properties: {
        stdin: {
          type: "string",
          description: "What the program reads on standard input. Optional.",
        },
        note: {
          type: "string",
          description:
            "One short sentence, for the person watching, saying what this does. Optional.",
        },
      },
      required: [],
    },
  },
  {
    name: "format_code",
    description:
      "Run the language's own formatter (rustfmt, gofmt, clang-format, black, prettier, zig fmt, stylua) over the program in place.",
    input_schema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "search_notes",
    description:
      "Search this person's own notes: every message and photo prompt in the chatrooms of all their scratchpads, by keyword and by meaning. Use it when they refer to something they wrote before.",
    input_schema: {
      type: "object",
      properties: { q: { type: "string", description: "What to look for." } },
      required: ["q"],
    },
  },
  {
    name: "make_image",
    description:
      "Generate a picture from a prompt and post it in this scratchpad's chatroom. Only when the person asks for a picture.",
    input_schema: {
      type: "object",
      properties: { prompt: { type: "string", description: "What the picture shows." } },
      required: ["prompt"],
    },
  },
];

/** The tools this bench can actually honour. */
export function toolsFor(bench: Bench): ToolDef[] {
  return TOOLS.filter((t) => {
    if (t.name === "comment_code") return bench.tutor === true && !!bench.comment;
    if (t.name === "run_code") return bench.run !== null;
    if (t.name === "format_code") return bench.format !== null;
    if (t.name === "search_notes") return bench.search !== null;
    if (t.name === "make_image") return bench.image !== null;
    return true;
  });
}

/** The program with line numbers, the way a reviewer reads it. */
export function numbered(source: string): string {
  const lines = source.split("\n");
  const w = String(lines.length).length;
  return lines.map((l, i) => `${String(i + 1).padStart(w, " ")}| ${l}`).join("\n");
}

/** How much of a run's output the model gets to read. */
const OUTPUT_CAP = 6000;

function cap(s: string): string {
  return s.length > OUTPUT_CAP
    ? `${s.slice(0, OUTPUT_CAP)}\n…[${s.length - OUTPUT_CAP} more chars]`
    : s;
}

/**
 * Run one tool call. Every outcome is a string for the model, and a refusal
 * is a sentence rather than a throw: the model can read "that span is not
 * in the file" and try again, and cannot read an exception.
 */
export async function runTool(
  bench: Bench,
  name: string,
  input: Record<string, unknown>,
): Promise<{ text: string; error: boolean }> {
  const str = (k: string): string => (typeof input[k] === "string" ? (input[k] as string) : "");
  try {
    switch (name) {
      case "read_code":
        return { text: `${bench.file}:\n${numbered(bench.read())}`, error: false };
      case "comment_code": {
        if (!bench.comment) return { text: "This screen cannot take comments.", error: true };
        const line = Number(input.line);
        const text = str("text");
        if (!text.trim()) return { text: "`text` is empty.", error: true };
        const res = await bench.comment(line, text);
        return res.ok
          ? { text: `Commented above line ${line}. The program itself is unchanged.`, error: false }
          : { text: res.why ?? "That line is not in the file.", error: true };
      }
      case "edit_code": {
        const find = str("find");
        if (!find) return { text: "`find` is empty.", error: true };
        const res = await bench.edit(find, str("replace"));
        return res.ok
          ? { text: "Edited.", error: false }
          : { text: res.why ?? "That span is not in the file exactly once.", error: true };
      }
      case "write_code": {
        const source = str("source");
        if (!source.trim()) return { text: "`source` is empty.", error: true };
        const r = await bench.write(source);
        return r.stopped
          ? {
              text: `Stopped by the person after ${r.typed} of ${r.total} characters.`,
              error: true,
            }
          : { text: `Typed ${r.total} characters; the file is now the new program.`, error: false };
      }
      case "insert_code": {
        const text = str("text");
        if (!text) return { text: "`text` is empty.", error: true };
        const r = await bench.insert(text);
        return r.stopped
          ? {
              text: `Stopped by the person after ${r.typed} of ${r.total} characters.`,
              error: true,
            }
          : { text: `Typed ${r.total} characters at the caret.`, error: false };
      }
      case "run_code": {
        if (!bench.run) return { text: "This screen cannot run code.", error: true };
        const r = await bench.run(str("stdin") || undefined);
        const lines = [
          `outcome: ${r.outcome}`,
          `compile ${r.compile_ms} ms · run ${r.run_ms} ms${r.exit_code === null ? "" : ` · exit ${r.exit_code}`}`,
        ];
        if (r.stdout.trim()) lines.push(`stdout:\n${cap(r.stdout)}`);
        if (r.stderr.trim()) lines.push(`stderr:\n${cap(r.stderr)}`);
        return { text: lines.join("\n"), error: false };
      }
      case "format_code": {
        if (!bench.format)
          return { text: "There is no formatter for this language here.", error: true };
        const r = await bench.format();
        if (r.problem)
          return { text: `The formatter could not parse it: ${r.problem}`, error: true };
        return { text: r.changed ? "Formatted." : "Already tidy.", error: false };
      }
      case "search_notes": {
        if (!bench.search)
          return { text: "There are no notes to search on this screen.", error: true };
        return { text: await bench.search(str("q")), error: false };
      }
      case "make_image": {
        if (!bench.image) return { text: "This provider cannot make pictures.", error: true };
        return { text: await bench.image(str("prompt")), error: false };
      }
      default:
        return { text: `Unknown tool ${name}.`, error: true };
    }
  } catch (e) {
    return { text: `${name} failed: ${e instanceof Error ? e.message : String(e)}`, error: true };
  }
}
