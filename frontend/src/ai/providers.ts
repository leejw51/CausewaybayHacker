/**
 * Three providers behind one door.
 *
 * `chat()` takes a neutral transcript and the tool catalogue, streams the
 * text back as it arrives, and answers with the turn: what was said, which
 * tools were asked for, and why it stopped. `image()` makes a picture where
 * the provider can. `listModels()` is what SETUP's FETCH MODELS presses.
 *
 * The SDKs (`@anthropic-ai/sdk`, `openai`; xAI speaks OpenAI's dialect and
 * is the same client with another base URL) are imported on demand, the way
 * `ui/poster.ts` loads its parsers: nobody pays for them until the AGENT
 * panel is opened. Both are told `dangerouslyAllowBrowser` on purpose — the
 * key is the person's own, kept in their own browser, and the whole design is
 * that it goes to the provider and nowhere else (docs/agent.md §1).
 */
import type Anthropic from "@anthropic-ai/sdk";
import type OpenAI from "openai";
import type { Provider } from "./prefs";
import { IMAGE_MODEL } from "./prefs";
import type { ToolDef } from "./tools";

export type Part =
  | { type: "text"; text: string }
  | { type: "tool_use"; id: string; name: string; input: Record<string, unknown> }
  | { type: "tool_result"; tool_use_id: string; name: string; content: string; is_error: boolean };

export interface Msg {
  role: "user" | "assistant";
  content: Part[];
}

export interface ToolUse {
  id: string;
  name: string;
  input: Record<string, unknown>;
}

export type Stop = "end" | "tool" | "max" | "refusal";

export interface Turn {
  text: string;
  toolUses: ToolUse[];
  stop: Stop;
}

export interface ChatOpts {
  provider: Provider;
  key: string;
  model: string;
  system: string;
  messages: Msg[];
  tools: ToolDef[];
  signal: AbortSignal;
  /** Every piece of the reply's prose, as it lands. */
  onText: (delta: string) => void;
}

/** Room for a whole program in one tool call, and a long explanation. */
const MAX_TOKENS = 16000;

export async function chat(o: ChatOpts): Promise<Turn> {
  if (!o.key) throw new Error("no api key");
  return o.provider === "anthropic" ? anthropicChat(o) : openaiChat(o);
}

/** A picture, as bytes the chatroom can keep. */
export async function image(
  provider: Provider,
  key: string,
  prompt: string,
  signal: AbortSignal,
): Promise<{ b64: string; mime: string }> {
  const model = IMAGE_MODEL[provider];
  if (!model) throw new Error(`${provider} cannot make pictures`);
  const client = await openaiClient(provider, key);
  const res = await client.images.generate(
    {
      model,
      prompt,
      n: 1,
      // gpt-image-1 always answers base64; xAI has to be asked.
      ...(provider === "grok" ? { response_format: "b64_json" as const } : {}),
      ...(provider === "openai" ? { size: "1024x1024" as const } : {}),
    },
    { signal },
  );
  const first = res.data?.[0] as { b64_json?: string; mime_type?: string } | undefined;
  const b64 = first?.b64_json;
  if (!b64) throw new Error("the provider sent no picture");
  // xAI says what it drew (`mime_type`, usually a JPEG); OpenAI's gpt-image-1
  // is a PNG and says nothing.
  const mime = first?.mime_type && /^image\//.test(first.mime_type) ? first.mime_type : "image/png";
  return { b64, mime };
}

export async function listModels(provider: Provider, key: string): Promise<string[]> {
  if (provider === "anthropic") {
    const client = await anthropicClient(key);
    const out: string[] = [];
    for await (const m of client.models.list()) out.push(m.id);
    return out.sort();
  }
  const client = await openaiClient(provider, key);
  const out: string[] = [];
  for await (const m of client.models.list()) out.push(m.id);
  // OpenAI's list is everything they have ever shipped; only the chat
  // models are any use here. xAI's is short enough to show whole.
  return (
    provider === "openai"
      ? out.filter(
          (id) =>
            /^(gpt-|o\d)/.test(id) &&
            !/(audio|realtime|tts|transcribe|image|embedding|moderation|search|instruct)/.test(id),
        )
      : out
  ).sort();
}

// -- anthropic ---------------------------------------------------------------

async function anthropicClient(key: string) {
  const { default: Anthropic } = await import("@anthropic-ai/sdk");
  return new Anthropic({ apiKey: key, dangerouslyAllowBrowser: true });
}

async function anthropicChat(o: ChatOpts): Promise<Turn> {
  const client = await anthropicClient(o.key);
  const messages: Anthropic.MessageParam[] = o.messages.map((m) => ({
    role: m.role,
    content: m.content.map((p) => {
      if (p.type === "text") return { type: "text" as const, text: p.text || " " };
      if (p.type === "tool_use")
        return { type: "tool_use" as const, id: p.id, name: p.name, input: p.input };
      return {
        type: "tool_result" as const,
        tool_use_id: p.tool_use_id,
        content: p.content,
        is_error: p.is_error,
      };
    }),
  }));
  const stream = client.messages.stream(
    {
      model: o.model,
      max_tokens: MAX_TOKENS,
      system: o.system,
      messages,
      tools: o.tools.map((t) => ({
        name: t.name,
        description: t.description,
        input_schema: t.input_schema,
      })),
    },
    { signal: o.signal },
  );
  stream.on("text", (delta) => o.onText(delta));
  const message = await stream.finalMessage();
  const text = message.content
    .filter((b): b is Extract<typeof b, { type: "text" }> => b.type === "text")
    .map((b) => b.text)
    .join("");
  const toolUses: ToolUse[] = message.content
    .filter((b): b is Extract<typeof b, { type: "tool_use" }> => b.type === "tool_use")
    .map((b) => ({ id: b.id, name: b.name, input: (b.input ?? {}) as Record<string, unknown> }));
  const stop: Stop =
    message.stop_reason === "refusal"
      ? "refusal"
      : message.stop_reason === "max_tokens"
        ? "max"
        : message.stop_reason === "tool_use" && toolUses.length > 0
          ? "tool"
          : "end";
  return { text, toolUses, stop };
}

// -- openai and xai ----------------------------------------------------------

const XAI_URL = "https://api.x.ai/v1";

async function openaiClient(provider: Provider, key: string) {
  const { default: OpenAI } = await import("openai");
  return new OpenAI({
    apiKey: key,
    dangerouslyAllowBrowser: true,
    ...(provider === "grok" ? { baseURL: XAI_URL } : {}),
  });
}

async function openaiChat(o: ChatOpts): Promise<Turn> {
  const client = await openaiClient(o.provider, o.key);
  const messages: OpenAI.ChatCompletionMessageParam[] = [{ role: "system", content: o.system }];
  for (const m of o.messages) {
    if (m.role === "assistant") {
      const text = m.content
        .filter((p): p is Extract<Part, { type: "text" }> => p.type === "text")
        .map((p) => p.text)
        .join("");
      const calls = m.content
        .filter((p): p is Extract<Part, { type: "tool_use" }> => p.type === "tool_use")
        .map((p) => ({
          id: p.id,
          type: "function" as const,
          function: { name: p.name, arguments: JSON.stringify(p.input) },
        }));
      messages.push({
        role: "assistant",
        content: text || null,
        ...(calls.length ? { tool_calls: calls } : {}),
      });
      continue;
    }
    for (const p of m.content) {
      if (p.type === "text") messages.push({ role: "user", content: p.text });
      else if (p.type === "tool_result")
        messages.push({ role: "tool", tool_call_id: p.tool_use_id, content: p.content });
    }
  }
  const stream = await client.chat.completions.create(
    {
      model: o.model,
      stream: true,
      messages,
      ...(o.tools.length
        ? {
            tools: o.tools.map((t) => ({
              type: "function" as const,
              function: {
                name: t.name,
                description: t.description,
                parameters: t.input_schema,
              },
            })),
          }
        : {}),
    },
    { signal: o.signal },
  );
  let text = "";
  const calls = new Map<number, { id: string; name: string; args: string }>();
  let finish: string | null = null;
  for await (const chunk of stream) {
    const choice = chunk.choices?.[0];
    if (!choice) continue;
    const d = choice.delta;
    if (d?.content) {
      text += d.content;
      o.onText(d.content);
    }
    for (const tc of d?.tool_calls ?? []) {
      const slot = calls.get(tc.index) ?? { id: "", name: "", args: "" };
      if (tc.id) slot.id = tc.id;
      if (tc.function?.name) slot.name += tc.function.name;
      if (tc.function?.arguments) slot.args += tc.function.arguments;
      calls.set(tc.index, slot);
    }
    if (choice.finish_reason) finish = choice.finish_reason;
  }
  const toolUses: ToolUse[] = [];
  for (const [, c] of [...calls.entries()].sort((a, b) => a[0] - b[0])) {
    let input: Record<string, unknown> = {};
    try {
      input = c.args ? (JSON.parse(c.args) as Record<string, unknown>) : {};
    } catch {
      input = { __invalid_json: c.args };
    }
    toolUses.push({ id: c.id || `call_${toolUses.length}`, name: c.name, input });
  }
  const stop: Stop =
    finish === "content_filter"
      ? "refusal"
      : finish === "length"
        ? "max"
        : toolUses.length > 0
          ? "tool"
          : "end";
  return { text, toolUses, stop };
}
