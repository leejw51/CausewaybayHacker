/**
 * What the agent needs to remember about *you*: which provider, which key,
 * which model, and whether it may review on its own.
 *
 * All of it is `localStorage` through `ui/prefs.ts`, under `cwbhacker.ai.*`,
 * so a key pasted once is there next session and next week. That is a
 * deliberate departure from the wallet rule (SPEC §3.1, "the key never leaves
 * the tab"): a provider key is a spending limit, not an identity, it is meant
 * to be revoked from a dashboard, and asking for it on every visit is how
 * people end up pasting it into the chat instead. It never goes to *our*
 * server — the only place it is ever sent is the provider that issued it
 * (docs/agent.md §1).
 */
import { readEnumPref, readPref, writePref } from "../ui/prefs";

export const PROVIDERS = ["anthropic", "openai", "grok", "openrouter", "ollama"] as const;
export type Provider = (typeof PROVIDERS)[number];

/** Where Ollama listens unless told otherwise. */
export const OLLAMA_DEFAULT_HOST = "http://localhost:11434";

/**
 * Whether the provider wants a key at all. Ollama is a program on your own
 * machine: what goes in its field is the host it listens on, and empty
 * means the default.
 */
export function needsKey(p: Provider): boolean {
  return p !== "ollama";
}

/** Ollama's host: what was typed, or the default. */
export function ollamaHost(): string {
  const raw = readKey("ollama").replace(/\/+$/, "");
  return raw || OLLAMA_DEFAULT_HOST;
}

/** The model each provider starts on. Editable; FETCH MODELS lists the rest. */
export const DEFAULT_MODEL: Record<Provider, string> = {
  anthropic: "claude-opus-5",
  openai: "gpt-4.1",
  grok: "grok-4",
  // OpenRouter names models as vendor/model; this one is on every plan.
  openrouter: "openai/gpt-4.1",
  // A coding model small enough to run on a laptop. `ollama pull` it first.
  ollama: "qwen2.5-coder:7b",
};

/** The image model, where there is one. Anthropic, OpenRouter and Ollama have none. */
export const IMAGE_MODEL: Record<Provider, string | null> = {
  anthropic: null,
  openai: "gpt-image-1",
  // The model `art/tools/grok_image.sh` draws this game's own art with.
  grok: "grok-imagine-image",
  openrouter: null,
  ollama: null,
};

export const PROVIDER_NAME: Record<Provider, string> = {
  anthropic: "ANTHROPIC",
  openai: "OPENAI",
  grok: "GROK",
  openrouter: "OPENROUTER",
  ollama: "OLLAMA",
};

/** The companion sprite that flies beside the coder for each provider. */
export const PROVIDER_BOT: Record<Provider, string> = {
  anthropic: "agent_bot_anthropic",
  openai: "agent_bot_openai",
  grok: "agent_bot_grok",
  // Both speak OpenAI's dialect; both fly the green bot.
  openrouter: "agent_bot_openai",
  ollama: "agent_bot_openai",
};

const PROVIDER_KEY = "ai.provider";
const AUTO_KEY = "ai.auto";
const SHOWN_KEY = "ai.shown";
const keyKey = (p: Provider) => `ai.key.${p}`;
const modelKey = (p: Provider) => `ai.model.${p}`;

export function readProvider(): Provider {
  return readEnumPref(PROVIDER_KEY, PROVIDERS, "anthropic");
}

export function writeProvider(p: Provider): void {
  writePref(PROVIDER_KEY, p);
}

export function readKey(p: Provider): string {
  return (readPref(keyKey(p)) ?? "").trim();
}

export function writeKey(p: Provider, key: string): void {
  writePref(keyKey(p), key.trim());
}

export function readModel(p: Provider): string {
  return (readPref(modelKey(p)) ?? "").trim() || DEFAULT_MODEL[p];
}

export function writeModel(p: Provider, model: string): void {
  writePref(modelKey(p), model.trim());
}

/** Whether the agent may spend a call on its own (docs/agent.md §1). */
export function readAuto(): boolean {
  return readPref(AUTO_KEY) === "1";
}

export function writeAuto(on: boolean): void {
  writePref(AUTO_KEY, on ? "1" : "0");
}

/**
 * Whether the coder is on the screen at all: the sprite, its tips, its
 * effects. Off, the panel still opens and the verbs still work — it is the
 * character that is put away, not the help. On by default.
 */
export function readShown(): boolean {
  return readPref(SHOWN_KEY) !== "0";
}

export function writeShown(on: boolean): void {
  writePref(SHOWN_KEY, on ? "1" : "0");
}

/** A key's shape for the setup line: the first and last few characters. */
export function maskKey(key: string): string {
  if (!key) return "";
  if (key.length <= 10) return "•".repeat(key.length);
  return `${key.slice(0, 6)}…${key.slice(-4)}`;
}
