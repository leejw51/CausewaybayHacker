/**
 * One conversation with the model, and the loop that lets it act.
 *
 * `ask()` sends the transcript, streams the prose back, and — while the model
 * keeps asking for tools — runs them on the bench and sends the results, up
 * to `MAX_ROUNDS` turns. That is the whole "coding agent": read the file,
 * edit or write it, run it, read what the compiler said, fix it, run again,
 * then explain. Every step of it is in the browser (docs/agent.md §3).
 *
 * The session is the client's memory of the room: what was said, which tools
 * ran, what they answered. The screen posts the human-readable messages to
 * the server for keeps (`playground.chat.post`); this holds the shape the
 * model needs, tool ids and all, for the length of the visit.
 */
import { needsKey, readKey, readModel, type Provider } from "./prefs";
import { chat, type Msg, type Part, type Turn } from "./providers";
import { numbered, runTool, toolsFor, type Bench } from "./tools";

/** How many times in one ask the model may come back for another tool. */
export const MAX_ROUNDS = 10;
/** Transcript turns kept for the model; older ones fall off the front. */
const KEEP_TURNS = 24;

export type Mood = "idle" | "thinking" | "typing" | "running";

export interface Listener {
  /** A piece of the reply's prose. */
  text(delta: string): void;
  /** The model is about to run this tool. */
  tool(name: string, input: Record<string, unknown>): void;
  /** And this is what it answered. */
  toolDone(name: string, text: string, error: boolean): void;
  mood(m: Mood): void;
}

/** The names the game uses for itself, for the model. */
const LANG_NAME: Record<string, string> = {
  rust: "Rust",
  go: "Go",
  cpp: "C++ (C++20)",
  python: "Python 3",
};

/** The agent's standing orders. Stable text first, the file last. */
export function systemPrompt(bench: Bench, canRun: boolean): string {
  const lang = LANG_NAME[bench.lang] ?? bench.lang;
  return [
    `You are the Rust coder — a small pixel-art character on a flying keyboard who lives on the code screen of Causewaybay Hacker, a 16-bit coding game set in Hong Kong. The person is learning ${lang}. You are their pair: a friendly senior engineer who explains briefly and lets the code speak.`,
    "",
    "The whole project is ONE source file, the one in the editor. There are no other files, no build system to configure, no dependencies beyond the standard library (Rust: std only, no crates; Go: standard library; C++: the standard library, compiled with -std=c++20; Python 3: the standard library).",
    "",
    "How to work:",
    "- For a small change, use edit_code with the exact span. For a new program or a rewrite, use write_code. Both are typed into the editor character by character while the person watches, so write only what is needed and no filler comments.",
    canRun
      ? "- After changing code, call run_code and read the outcome. If it did not compile or crashed, read the compiler's message, fix the code, and run again — up to a few times — before you answer."
      : "- This screen cannot run code, so read carefully and reason about it instead.",
    "- Do not paste code into your prose when you could put it in the editor with a tool. Your prose is a short chat message: what you did and why, one to four sentences, plain text, no markdown headings.",
    "- If asked to review, be concrete: name the line and the habit, and offer the fix. Do not rewrite a working program nobody asked you to rewrite.",
    "- Keep the person's style, names and formatting unless asked. Keep the program's existing behaviour unless asked.",
    "- Never invent an API. If unsure, prefer the plain standard-library way.",
    "- A picture is not a program. When the person asks for a picture, image, drawing or photo, call make_image with a prompt; do not write code that prints one, and do not describe it instead.",
    "",
    `The file is ${bench.file}. Its current text, with line numbers (do not include the numbers in edits):`,
    "```",
    numbered(bench.read()),
    "```",
  ].join("\n");
}

export class Session {
  /** The transcript as the model sees it. */
  messages: Msg[] = [];
  private abort: AbortController | null = null;
  get busy(): boolean {
    return this.abort !== null;
  }

  constructor(
    private readonly bench: Bench,
    private readonly listener: Listener,
  ) {}

  /** Forget the conversation. The server's copy, if any, is the screen's business. */
  clear(): void {
    this.stop();
    this.messages = [];
  }

  stop(): void {
    this.abort?.abort();
    this.abort = null;
  }

  /**
   * One ask, however many rounds it takes. Resolves to the prose of the last
   * turn. Throws on a provider error (a bad key, a network failure); a model
   * refusal or a truncated answer resolves with what there is.
   */
  async ask(provider: Provider, text: string): Promise<string> {
    if (this.busy) throw new Error("busy");
    const key = readKey(provider);
    const model = readModel(provider);
    if (!key && needsKey(provider)) throw new Error("no api key");
    const abort = new AbortController();
    this.abort = abort;
    this.messages.push({ role: "user", content: [{ type: "text", text }] });
    this.trim();
    const tools = toolsFor(this.bench);
    let last = "";
    try {
      for (let round = 0; round <= MAX_ROUNDS; round++) {
        this.listener.mood("thinking");
        // The last round goes out with no tools at all, so a model that
        // would keep going is made to stop and say where it got to
        // (CausewaybayOffice's two-stage cap) rather than being cut off
        // mid-loop with nothing said.
        const final = round === MAX_ROUNDS;
        const turn: Turn = await chat({
          provider,
          key,
          model,
          system: systemPrompt(this.bench, this.bench.run !== null),
          messages: final
            ? [
                ...this.messages,
                {
                  role: "user",
                  content: [
                    {
                      type: "text",
                      text: "You have used every tool round you have. Do not call tools; say in two or three sentences what you did and what, if anything, is left.",
                    },
                  ],
                },
              ]
            : this.messages,
          tools: final ? [] : tools,
          signal: abort.signal,
          onText: (d) => this.listener.text(d),
        });
        const parts: Part[] = [];
        if (turn.text) parts.push({ type: "text", text: turn.text });
        for (const u of turn.toolUses) parts.push({ type: "tool_use", ...u });
        if (parts.length) this.messages.push({ role: "assistant", content: parts });
        last = turn.text;
        if (turn.stop !== "tool" || turn.toolUses.length === 0) break;
        const results: Part[] = [];
        for (const u of turn.toolUses) {
          if (abort.signal.aborted) break;
          const mood: Mood =
            u.name === "run_code" ? "running" : /code$/.test(u.name) ? "typing" : "thinking";
          this.listener.mood(mood);
          this.listener.tool(u.name, u.input);
          const r =
            "__invalid_json" in u.input
              ? { text: "The tool call's JSON did not parse; send it again.", error: true }
              : await runTool(this.bench, u.name, u.input);
          this.listener.toolDone(u.name, r.text, r.error);
          results.push({
            type: "tool_result",
            tool_use_id: u.id,
            name: u.name,
            content: r.text,
            is_error: r.error,
          });
        }
        if (abort.signal.aborted) break;
        this.messages.push({ role: "user", content: results });
      }
    } finally {
      if (this.abort === abort) this.abort = null;
      this.listener.mood("idle");
    }
    return last;
  }

  /**
   * Keep the transcript to a size a model can hold, without ever cutting
   * between a tool call and its result: the front is dropped in whole
   * user-started exchanges.
   */
  private trim(): void {
    while (this.messages.length > KEEP_TURNS) {
      // Drop through to the next user message that carries text, which is
      // where the next exchange starts.
      this.messages.shift();
      while (
        this.messages.length > 0 &&
        !(
          this.messages[0].role === "user" &&
          this.messages[0].content.some((p) => p.type === "text")
        )
      ) {
        this.messages.shift();
      }
    }
  }
}
