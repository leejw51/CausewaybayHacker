/**
 * The agent loop, with the model scripted.
 *
 * `ai/session.ts` is the harness: it sends the transcript, runs whatever
 * tools the model asks for on the bench, sends the results back, and stops
 * when the model does — or at the cap, where it takes the tools away and
 * asks for a summary. The provider is mocked so every branch of that can be
 * driven: a plain answer, a tool round, a tool the model spelled wrongly, a
 * runaway loop, a STOP mid-flight, a missing key, and the transcript's trim.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Bench } from "../src/ai/tools";
import type { ChatOpts, Turn } from "../src/ai/providers";
import type { Listener, Mood } from "../src/ai/session";

vi.mock("../src/ai/providers", () => ({
  chat: vi.fn(),
  image: vi.fn(),
  listModels: vi.fn(),
}));

import { chat } from "../src/ai/providers";
import { MAX_ROUNDS, Session } from "../src/ai/session";
import { writeKey, writeModel } from "../src/ai/prefs";

const mocked = vi.mocked(chat);

/** A model that answers from a queue. Each entry may stream text first. */
function script(turns: Array<Turn & { stream?: string }>): ChatOpts[] {
  const seen: ChatOpts[] = [];
  mocked.mockImplementation(async (o) => {
    // The transcript is one array the session keeps appending to; keep the
    // copy this call actually saw.
    seen.push({ ...o, messages: o.messages.map((m) => ({ ...m, content: [...m.content] })) });
    const next = turns.shift();
    if (!next) throw new Error("the script ran out");
    if (next.stream) for (const ch of next.stream) o.onText(ch);
    return { text: next.text, toolUses: next.toolUses, stop: next.stop };
  });
  return seen;
}

function bench(): Bench & { log: string[] } {
  let source = "fn main() {}\n";
  const log: string[] = [];
  return {
    log,
    lang: "rust",
    file: "main.rs",
    read: () => source,
    write: async (s) => {
      log.push(`write:${s}`);
      source = s;
      return { typed: s.length, total: s.length, stopped: false };
    },
    insert: async (s) => {
      log.push(`insert:${s}`);
      source += s;
      return { typed: s.length, total: s.length, stopped: false };
    },
    edit: async (find, replace) => {
      log.push(`edit:${find}>${replace}`);
      const at = source.indexOf(find);
      if (at < 0) return { ok: false, why: "not there" };
      source = source.slice(0, at) + replace + source.slice(at + find.length);
      return { ok: true };
    },
    run: async () => {
      log.push("run");
      return { outcome: "ok", stdout: "42\n", stderr: "", compile_ms: 1, run_ms: 1, exit_code: 0 };
    },
    format: null,
    search: null,
    image: null,
  };
}

function listener() {
  const l = {
    texts: [] as string[],
    tools: [] as string[],
    done: [] as Array<{ name: string; error: boolean }>,
    moods: [] as Mood[],
  };
  const api: Listener = {
    text: (d) => l.texts.push(d),
    tool: (name) => l.tools.push(name),
    toolDone: (name, _text, error) => l.done.push({ name, error }),
    mood: (m) => l.moods.push(m),
  };
  return { l, api };
}

beforeEach(() => {
  mocked.mockReset();
  writeKey("anthropic", "sk-ant-test");
  writeModel("anthropic", "claude-opus-5");
});

afterEach(() => {
  writeKey("anthropic", "");
});

describe("the session", () => {
  it("streams a plain answer and keeps the exchange", async () => {
    const seen = script([{ stream: "Hi there", text: "Hi there", toolUses: [], stop: "end" }]);
    const b = bench();
    const { l, api } = listener();
    const s = new Session(b, api);
    const reply = await s.ask("anthropic", "hello");
    expect(reply).toBe("Hi there");
    expect(l.texts.join("")).toBe("Hi there");
    expect(s.messages).toEqual([
      { role: "user", content: [{ type: "text", text: "hello" }] },
      { role: "assistant", content: [{ type: "text", text: "Hi there" }] },
    ]);
    expect(seen).toHaveLength(1);
    expect(seen[0].provider).toBe("anthropic");
    expect(seen[0].model).toBe("claude-opus-5");
    expect(seen[0].key).toBe("sk-ant-test");
    // The system prompt carries the file, numbered, and the run rule.
    expect(seen[0].system).toContain("1| fn main() {}");
    expect(seen[0].system).toContain("run_code");
    expect(l.moods[0]).toBe("thinking");
    expect(l.moods[l.moods.length - 1]).toBe("idle");
    expect(s.busy).toBe(false);
  });

  it("runs a tool, sends its result back, and goes on", async () => {
    const seen = script([
      {
        text: "Writing it.",
        toolUses: [
          { id: "t1", name: "write_code", input: { source: 'fn main() { println!("42"); }\n' } },
        ],
        stop: "tool",
      },
      {
        text: "",
        toolUses: [{ id: "t2", name: "run_code", input: {} }],
        stop: "tool",
      },
      { text: "Done: it prints 42.", toolUses: [], stop: "end" },
    ]);
    const b = bench();
    const { l, api } = listener();
    const reply = await new Session(b, api).ask("anthropic", "write a program that prints 42");
    expect(reply).toBe("Done: it prints 42.");
    expect(b.log).toEqual(['write:fn main() { println!("42"); }\n', "run"]);
    expect(l.tools).toEqual(["write_code", "run_code"]);
    expect(l.done.map((d) => d.error)).toEqual([false, false]);
    // The second request carried the tool result, under the right id.
    const second = seen[1].messages;
    const last = second[second.length - 1];
    expect(last.role).toBe("user");
    expect(last.content[0]).toMatchObject({
      type: "tool_result",
      tool_use_id: "t1",
      is_error: false,
    });
    // The third request's system prompt shows the *new* file.
    expect(seen[2].system).toContain('println!("42")');
    // And the moods followed the work.
    expect(l.moods).toContain("typing");
    expect(l.moods).toContain("running");
  });

  it("answers a tool that missed with an error result, not a throw", async () => {
    script([
      {
        text: "",
        toolUses: [{ id: "t1", name: "edit_code", input: { find: "nowhere", replace: "x" } }],
        stop: "tool",
      },
      { text: "ok", toolUses: [], stop: "end" },
    ]);
    const { l, api } = listener();
    const s = new Session(bench(), api);
    await s.ask("anthropic", "fix it");
    expect(l.done).toEqual([{ name: "edit_code", error: true }]);
    const result = s.messages[2].content[0];
    expect(result).toMatchObject({ type: "tool_result", is_error: true });
  });

  it("tells the model when its tool call did not parse", async () => {
    script([
      {
        text: "",
        toolUses: [{ id: "t1", name: "write_code", input: { __invalid_json: "{source: " } }],
        stop: "tool",
      },
      { text: "sorry", toolUses: [], stop: "end" },
    ]);
    const b = bench();
    const { api } = listener();
    const s = new Session(b, api);
    await s.ask("anthropic", "go");
    expect(b.log).toEqual([]);
    const result = s.messages[2].content[0] as { content: string; is_error: boolean };
    expect(result.is_error).toBe(true);
    expect(result.content).toMatch(/did not parse/);
  });

  it("takes the tools away at the cap and asks for a summary", async () => {
    const forever: Array<Turn> = [];
    for (let i = 0; i < MAX_ROUNDS; i++) {
      forever.push({
        text: "",
        toolUses: [{ id: `t${i}`, name: "read_code", input: {} }],
        stop: "tool",
      });
    }
    forever.push({ text: "I read it ten times.", toolUses: [], stop: "end" });
    const seen = script(forever);
    const { api } = listener();
    const reply = await new Session(bench(), api).ask("anthropic", "loop");
    expect(reply).toBe("I read it ten times.");
    expect(seen).toHaveLength(MAX_ROUNDS + 1);
    for (let i = 0; i < MAX_ROUNDS; i++) expect(seen[i].tools.length).toBeGreaterThan(0);
    const final = seen[MAX_ROUNDS];
    expect(final.tools).toEqual([]);
    const ask = final.messages[final.messages.length - 1];
    expect(ask.role).toBe("user");
    expect(JSON.stringify(ask.content)).toMatch(/Do not call tools/);
  });

  it("stops when told to, between rounds", async () => {
    let calls = 0;
    mocked.mockImplementation(async (o) => {
      calls++;
      return new Promise((resolve, reject) => {
        o.signal.addEventListener("abort", () => reject(new Error("aborted")));
        setTimeout(
          () =>
            resolve({
              text: "",
              toolUses: [{ id: "x", name: "read_code", input: {} }],
              stop: "tool",
            }),
          5,
        );
      });
    });
    const { api } = listener();
    const s = new Session(bench(), api);
    const p = s.ask("anthropic", "go");
    expect(s.busy).toBe(true);
    s.stop();
    await expect(p).rejects.toThrow(/abort/);
    expect(s.busy).toBe(false);
    expect(calls).toBe(1);
  });

  it("stops during a tool and still answers every tool_use, so the next ask is valid", async () => {
    // Round 1: the model asks for two tools. The first one is slow, and the
    // player presses STOP while it runs. The transcript must still pair the
    // second tool_use with a tool_result, or every later ask is refused.
    const b = bench();
    let release: () => void = () => {};
    b.write = () =>
      new Promise((resolve) => {
        release = () => resolve({ typed: 0, total: 0, stopped: true });
      });
    let calls = 0;
    mocked.mockImplementation(async (o) => {
      calls++;
      if (calls === 1) {
        return {
          text: "",
          toolUses: [
            { id: "w1", name: "write_code", input: { source: "fn main() {}" } },
            { id: "r1", name: "run_code", input: {} },
          ],
          stop: "tool",
        };
      }
      // The follow-up ask: check what it was handed.
      for (let i = 0; i < o.messages.length; i++) {
        const m = o.messages[i];
        for (const p of m.content) {
          if (p.type !== "tool_use") continue;
          const next = o.messages[i + 1];
          expect(next?.role).toBe("user");
          expect(
            next?.content.some((q) => q.type === "tool_result" && q.tool_use_id === p.id),
          ).toBe(true);
        }
      }
      return { text: "fine", toolUses: [], stop: "end" };
    });
    const { api } = listener();
    const s = new Session(b, api);
    const first = s.ask("anthropic", "write it");
    await new Promise((r) => setTimeout(r, 5));
    s.stop();
    release();
    await first;
    expect(s.busy).toBe(false);
    await expect(s.ask("anthropic", "and now?")).resolves.toBe("fine");
    expect(calls).toBe(2);
    const results = s.messages
      .flatMap((m) => m.content)
      .filter((p) => p.type === "tool_result")
      .map((p) => (p as { tool_use_id: string }).tool_use_id);
    expect(results).toEqual(["w1", "r1"]);
  });

  it("answers a tool call the model never finished, so the next ask is valid", async () => {
    // The token cap (or a refusal) can cut a turn off with a tool_use in
    // it. The tool must not run, but the transcript still needs a result
    // under that id or the next ask is refused wholesale.
    const seen = script([
      {
        text: "Let me read",
        toolUses: [{ id: "t1", name: "read_code", input: {} }],
        stop: "max",
      },
      { text: "ok", toolUses: [], stop: "end" },
    ]);
    const b = bench();
    const { l, api } = listener();
    const s = new Session(b, api);
    await expect(s.ask("anthropic", "go")).resolves.toBe("Let me read");
    expect(l.tools).toEqual([]);
    expect(s.busy).toBe(false);
    await expect(s.ask("anthropic", "and?")).resolves.toBe("ok");
    const sent = seen[1].messages;
    const at = sent.findIndex((m) => m.content.some((p) => p.type === "tool_use"));
    expect(at).toBeGreaterThan(0);
    expect(sent[at + 1].role).toBe("user");
    expect(sent[at + 1].content[0]).toMatchObject({
      type: "tool_result",
      tool_use_id: "t1",
      is_error: true,
      content: expect.stringMatching(/cut off/),
    });
  });

  it("stays busy after STOP until the tool it was in comes back", async () => {
    // STOP aborts the loop, but the loop is still awaiting a tool (a run on
    // the server, say). A new ask before that returns would push its text
    // ahead of the old tool_result and corrupt the transcript, so `busy`
    // holds until the ask has unwound.
    const b = bench();
    let release: () => void = () => {};
    b.run = () =>
      new Promise((resolve) => {
        release = () =>
          resolve({
            outcome: "ok",
            stdout: "",
            stderr: "",
            compile_ms: 1,
            run_ms: 1,
            exit_code: 0,
          });
      });
    script([
      { text: "", toolUses: [{ id: "r1", name: "run_code", input: {} }], stop: "tool" },
      { text: "fine", toolUses: [], stop: "end" },
    ]);
    const { api } = listener();
    const s = new Session(b, api);
    const first = s.ask("anthropic", "run it");
    await new Promise((r) => setTimeout(r, 5));
    s.stop();
    expect(s.busy).toBe(true);
    await expect(s.ask("anthropic", "again")).rejects.toThrow(/busy/);
    release();
    await first;
    expect(s.busy).toBe(false);
    await expect(s.ask("anthropic", "again")).resolves.toBe("fine");
    const ids = s.messages
      .flatMap((m) => m.content)
      .filter((p) => p.type === "tool_result")
      .map((p) => (p as { tool_use_id: string }).tool_use_id);
    expect(ids).toEqual(["r1"]);
  });

  it("a CLEAR mid-tool leaves the new transcript empty, not headed by a stray result", async () => {
    const b = bench();
    let release: () => void = () => {};
    b.run = () =>
      new Promise((resolve) => {
        release = () =>
          resolve({
            outcome: "ok",
            stdout: "",
            stderr: "",
            compile_ms: 1,
            run_ms: 1,
            exit_code: 0,
          });
      });
    script([
      { text: "", toolUses: [{ id: "r1", name: "run_code", input: {} }], stop: "tool" },
      { text: "fresh", toolUses: [], stop: "end" },
    ]);
    const { api } = listener();
    const s = new Session(b, api);
    const first = s.ask("anthropic", "run it");
    await new Promise((r) => setTimeout(r, 5));
    s.clear();
    release();
    await first;
    expect(s.messages).toEqual([]);
    await expect(s.ask("anthropic", "hello")).resolves.toBe("fresh");
    expect(s.messages[0]).toEqual({ role: "user", content: [{ type: "text", text: "hello" }] });
    expect(s.messages.flatMap((m) => m.content).some((p) => p.type === "tool_result")).toBe(false);
  });

  it("refuses without a key, and while busy", async () => {
    writeKey("anthropic", "");
    const { api } = listener();
    const s = new Session(bench(), api);
    await expect(s.ask("anthropic", "hi")).rejects.toThrow(/no api key/);
    expect(mocked).not.toHaveBeenCalled();

    writeKey("anthropic", "k");
    mocked.mockImplementation(() => new Promise(() => {}));
    const t = new Session(bench(), api);
    void t.ask("anthropic", "one");
    await expect(t.ask("anthropic", "two")).rejects.toThrow(/busy/);
    t.stop();
  });

  it("keeps the transcript bounded, cutting only between exchanges", async () => {
    mocked.mockImplementation(async () => ({ text: "ok", toolUses: [], stop: "end" }));
    const { api } = listener();
    const s = new Session(bench(), api);
    for (let i = 0; i < 40; i++) await s.ask("anthropic", `q${i}`);
    expect(s.messages.length).toBeLessThanOrEqual(26);
    expect(s.messages[0].role).toBe("user");
    expect(s.messages[0].content[0]).toMatchObject({ type: "text" });
    // The newest exchange is intact at the tail.
    const tail = s.messages[s.messages.length - 1];
    expect(tail).toEqual({ role: "assistant", content: [{ type: "text", text: "ok" }] });
  });

  it("forgets everything on clear", async () => {
    mocked.mockImplementation(async () => ({ text: "ok", toolUses: [], stop: "end" }));
    const { api } = listener();
    const s = new Session(bench(), api);
    await s.ask("anthropic", "hello");
    expect(s.messages).toHaveLength(2);
    s.clear();
    expect(s.messages).toEqual([]);
    expect(s.busy).toBe(false);
  });
});
