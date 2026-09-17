/**
 * The three providers behind the one door, with the SDKs mocked.
 *
 * What is pinned is the *shape* handed to each SDK — the transcript in its
 * dialect, the tools in its dialect, the key and the base URL — and what
 * comes back through the door: streamed text, tool calls assembled from
 * fragments, and the stop reason. The SDKs themselves are not under test;
 * a wrong field name in a request is, because that is the bug a mocked
 * network cannot see and a real one charges for.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";

// -- openai (and xAI through it) ---------------------------------------------

// `vi.doMock` rather than `vi.mock`: the hoisted form runs before these
// state objects exist, and the module under test only reaches for the SDKs
// through `import()` at call time, so a mock registered after the fact is
// the one it finds.
const openaiState = {
  ctor: [] as unknown[],
  params: [] as unknown[],
  chunks: [] as unknown[],
  images: [] as unknown[],
  imageResult: { data: [{ b64_json: "AAAA" }] } as unknown,
  models: [
    "gpt-4.1",
    "gpt-4o-audio-preview",
    "o3",
    "text-embedding-3-small",
    "gpt-image-1",
    "dall-e-3",
  ],
};

vi.doMock("openai", () => {
  class OpenAI {
    chat = {
      completions: {
        create: async (params: unknown) => {
          openaiState.params.push(params);
          const chunks = openaiState.chunks;
          return {
            async *[Symbol.asyncIterator]() {
              for (const c of chunks) yield c;
            },
          };
        },
      },
    };
    images = {
      generate: async (params: unknown) => {
        openaiState.images.push(params);
        return openaiState.imageResult;
      },
    };
    models = {
      list: () => ({
        async *[Symbol.asyncIterator]() {
          for (const id of openaiState.models) yield { id };
        },
      }),
    };
    constructor(opts: unknown) {
      openaiState.ctor.push(opts);
    }
  }
  return { default: OpenAI };
});

// -- anthropic ---------------------------------------------------------------

const anthropicState = {
  ctor: [] as unknown[],
  params: [] as unknown[],
  textDeltas: [] as string[],
  final: {} as Record<string, unknown>,
  models: ["claude-opus-5", "claude-sonnet-5"],
};

vi.doMock("@anthropic-ai/sdk", () => {
  class Anthropic {
    messages = {
      stream: (params: unknown) => {
        anthropicState.params.push(params);
        const handlers: Record<string, (d: string) => void> = {};
        return {
          on(event: string, fn: (d: string) => void) {
            handlers[event] = fn;
            return this;
          },
          async finalMessage() {
            for (const d of anthropicState.textDeltas) handlers.text?.(d);
            return anthropicState.final;
          },
        };
      },
    };
    models = {
      list: () => ({
        async *[Symbol.asyncIterator]() {
          for (const id of anthropicState.models) yield { id };
        },
      }),
    };
    constructor(opts: unknown) {
      anthropicState.ctor.push(opts);
    }
  }
  return { default: Anthropic };
});

import type { Msg } from "../src/ai/providers";
import { TOOLS } from "../src/ai/tools";

const { chat, image, listModels } = await import("../src/ai/providers");

const transcript: Msg[] = [
  { role: "user", content: [{ type: "text", text: "write it" }] },
  {
    role: "assistant",
    content: [
      { type: "text", text: "On it." },
      { type: "tool_use", id: "call_1", name: "write_code", input: { source: "fn main() {}" } },
    ],
  },
  {
    role: "user",
    content: [
      {
        type: "tool_result",
        tool_use_id: "call_1",
        name: "write_code",
        content: "Typed 12 characters",
        is_error: false,
      },
    ],
  },
];

const tools = TOOLS.filter((t) => t.name === "read_code" || t.name === "write_code");

function opts(provider: "openai" | "grok" | "anthropic", onText = (_: string) => {}) {
  return {
    provider,
    key: "k-test",
    model: "m-test",
    system: "be brief",
    messages: transcript,
    tools,
    signal: new AbortController().signal,
    onText,
  };
}

beforeEach(() => {
  openaiState.ctor = [];
  openaiState.params = [];
  openaiState.chunks = [];
  openaiState.images = [];
  anthropicState.ctor = [];
  anthropicState.params = [];
  anthropicState.textDeltas = [];
  anthropicState.final = { content: [], stop_reason: "end_turn" };
});

describe("openai", () => {
  it("speaks the chat-completions dialect", async () => {
    openaiState.chunks = [
      { choices: [{ delta: { content: "Hel" } }] },
      { choices: [{ delta: { content: "lo" } }] },
      { choices: [{ delta: {}, finish_reason: "stop" }] },
    ];
    const got: string[] = [];
    const turn = await chat(opts("openai", (d) => got.push(d)));
    expect(turn).toEqual({ text: "Hello", toolUses: [], stop: "end" });
    expect(got).toEqual(["Hel", "lo"]);

    expect(openaiState.ctor[0]).toMatchObject({ apiKey: "k-test", dangerouslyAllowBrowser: true });
    expect(openaiState.ctor[0]).not.toHaveProperty("baseURL");
    const p = openaiState.params[0] as {
      model: string;
      stream: boolean;
      messages: Array<Record<string, unknown>>;
      tools: Array<{ type: string; function: { name: string; parameters: unknown } }>;
    };
    expect(p.model).toBe("m-test");
    expect(p.stream).toBe(true);
    expect(p.messages[0]).toEqual({ role: "system", content: "be brief" });
    expect(p.messages[1]).toEqual({ role: "user", content: "write it" });
    expect(p.messages[2]).toEqual({
      role: "assistant",
      content: "On it.",
      tool_calls: [
        {
          id: "call_1",
          type: "function",
          function: { name: "write_code", arguments: '{"source":"fn main() {}"}' },
        },
      ],
    });
    expect(p.messages[3]).toEqual({
      role: "tool",
      tool_call_id: "call_1",
      content: "Typed 12 characters",
    });
    expect(p.tools.map((t) => t.type)).toEqual(["function", "function"]);
    expect(p.tools[1].function.name).toBe("write_code");
    expect(p.tools[1].function.parameters).toEqual(tools[1].input_schema);
  });

  it("assembles tool calls from fragments across two slots", async () => {
    openaiState.chunks = [
      {
        choices: [
          {
            delta: {
              tool_calls: [{ index: 0, id: "c0", function: { name: "read_", arguments: "" } }],
            },
          },
        ],
      },
      {
        choices: [
          { delta: { tool_calls: [{ index: 0, function: { name: "code", arguments: "{}" } }] } },
        ],
      },
      {
        choices: [
          {
            delta: {
              tool_calls: [
                { index: 1, id: "c1", function: { name: "write_code", arguments: '{"sou' } },
              ],
            },
          },
        ],
      },
      {
        choices: [{ delta: { tool_calls: [{ index: 1, function: { arguments: 'rce":"x"}' } }] } }],
      },
      { choices: [{ delta: {}, finish_reason: "tool_calls" }] },
    ];
    const turn = await chat(opts("openai"));
    expect(turn.stop).toBe("tool");
    expect(turn.toolUses).toEqual([
      { id: "c0", name: "read_code", input: {} },
      { id: "c1", name: "write_code", input: { source: "x" } },
    ]);
  });

  it("marks arguments that never became JSON, and a cut-off answer", async () => {
    openaiState.chunks = [
      {
        choices: [
          {
            delta: {
              tool_calls: [
                { index: 0, id: "c0", function: { name: "write_code", arguments: "{oops" } },
              ],
            },
          },
        ],
      },
      { choices: [{ delta: {}, finish_reason: "length" }] },
    ];
    const turn = await chat(opts("openai"));
    expect(turn.stop).toBe("max");
    expect(turn.toolUses[0].input).toEqual({ __invalid_json: "{oops" });
  });

  it("goes to xAI for grok, on the same client", async () => {
    openaiState.chunks = [{ choices: [{ delta: { content: "yo" }, finish_reason: "stop" }] }];
    await chat(opts("grok"));
    expect(openaiState.ctor[0]).toMatchObject({
      baseURL: "https://api.x.ai/v1",
      dangerouslyAllowBrowser: true,
    });
  });

  it("makes a picture, asking each provider in its own words", async () => {
    const ctl = new AbortController();
    const a = await image("openai", "k", "a crab", ctl.signal);
    expect(a).toEqual({ b64: "AAAA", mime: "image/png" });
    expect(openaiState.images[0]).toMatchObject({
      model: "gpt-image-1",
      prompt: "a crab",
      n: 1,
      size: "1024x1024",
    });
    expect(openaiState.images[0]).not.toHaveProperty("response_format");
    await image("grok", "k", "a crab", ctl.signal);
    expect(openaiState.images[1]).toMatchObject({ response_format: "b64_json" });
    expect(openaiState.images[1]).not.toHaveProperty("size");
    await expect(image("anthropic", "k", "a crab", ctl.signal)).rejects.toThrow(
      /cannot make pictures/,
    );
    openaiState.imageResult = { data: [] };
    await expect(image("openai", "k", "a crab", ctl.signal)).rejects.toThrow(/no picture/);
  });

  it("lists only the chat models of openai, and all of xAI's", async () => {
    expect(await listModels("openai", "k")).toEqual(["gpt-4.1", "o3"]);
    expect(await listModels("grok", "k")).toEqual([...openaiState.models].sort());
  });
});

describe("anthropic", () => {
  it("speaks the messages dialect", async () => {
    anthropicState.textDeltas = ["Hel", "lo"];
    anthropicState.final = {
      content: [
        { type: "text", text: "Hello" },
        { type: "tool_use", id: "tu_1", name: "write_code", input: { source: "x" } },
      ],
      stop_reason: "tool_use",
    };
    const got: string[] = [];
    const turn = await chat(opts("anthropic", (d) => got.push(d)));
    expect(got).toEqual(["Hel", "lo"]);
    expect(turn).toEqual({
      text: "Hello",
      toolUses: [{ id: "tu_1", name: "write_code", input: { source: "x" } }],
      stop: "tool",
    });
    expect(anthropicState.ctor[0]).toMatchObject({
      apiKey: "k-test",
      dangerouslyAllowBrowser: true,
    });
    const p = anthropicState.params[0] as {
      model: string;
      max_tokens: number;
      system: string;
      messages: Array<{ role: string; content: unknown[] }>;
      tools: Array<{ name: string; input_schema: unknown }>;
    };
    expect(p.model).toBe("m-test");
    expect(p.system).toBe("be brief");
    expect(p.max_tokens).toBeGreaterThanOrEqual(8000);
    expect(p.messages[0]).toEqual({ role: "user", content: [{ type: "text", text: "write it" }] });
    expect(p.messages[1]).toEqual({
      role: "assistant",
      content: [
        { type: "text", text: "On it." },
        { type: "tool_use", id: "call_1", name: "write_code", input: { source: "fn main() {}" } },
      ],
    });
    expect(p.messages[2]).toEqual({
      role: "user",
      content: [
        {
          type: "tool_result",
          tool_use_id: "call_1",
          content: "Typed 12 characters",
          is_error: false,
        },
      ],
    });
    expect(p.tools.map((t) => t.name)).toEqual(["read_code", "write_code"]);
    expect(p.tools[1].input_schema).toEqual(tools[1].input_schema);
  });

  it("maps every stop reason", async () => {
    for (const [reason, stop] of [
      ["end_turn", "end"],
      ["max_tokens", "max"],
      ["refusal", "refusal"],
      ["tool_use", "end"], // tool_use with no tool blocks is nothing to run
    ] as const) {
      anthropicState.final = { content: [{ type: "text", text: "t" }], stop_reason: reason };
      expect((await chat(opts("anthropic"))).stop).toBe(stop);
    }
  });

  it("never sends an empty text block", async () => {
    anthropicState.final = { content: [], stop_reason: "end_turn" };
    await chat({
      ...opts("anthropic"),
      messages: [{ role: "user", content: [{ type: "text", text: "" }] }],
    });
    const p = anthropicState.params[0] as { messages: Array<{ content: Array<{ text: string }> }> };
    expect(p.messages[0].content[0].text).toBe(" ");
  });

  it("lists its models", async () => {
    expect(await listModels("anthropic", "k")).toEqual(["claude-opus-5", "claude-sonnet-5"]);
  });
});

describe("the door", () => {
  it("is shut without a key", async () => {
    await expect(chat({ ...opts("openai"), key: "" })).rejects.toThrow(/no api key/);
    expect(openaiState.ctor).toHaveLength(0);
  });
});
