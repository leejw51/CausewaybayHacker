/**
 * The AGENT panel's plumbing, with no canvas.
 *
 * The panel is drawn from a scene and that is not tested; what is pinned is
 * everything that can be wrong without a frame being painted: the fields it
 * owns and where they go, the verbs the keys fire, the room's cap, the
 * accelerator, and what it refuses to hear while it is closed.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { Panel, type Verbs } from "../src/ui/agent/panel";
import { readKey, readModel, writeKey, writeModel } from "../src/ai/prefs";
import { Layout } from "../src/engine/layout";

function make() {
  const overlay = document.createElement("div");
  document.body.appendChild(overlay);
  const canvas = document.createElement("canvas");
  const app = {
    overlay,
    layout: new Layout(canvas),
    chip: { blip: vi.fn(), fail: vi.fn(), coin: vi.fn(), select: vi.fn() },
  };
  const verbs: Verbs = {
    send: vi.fn(),
    write: vi.fn(),
    review: vi.fn(),
    image: vi.fn(),
    stop: vi.fn(),
    clear: vi.fn(),
    note: vi.fn(),
  };
  // The panel only reads `overlay`, `layout` and `chip` off the app.
  const panel = new Panel(app as never, verbs);
  return { panel, verbs, overlay, app };
}

const fields = (overlay: HTMLElement) =>
  [...overlay.querySelectorAll("input.cwb-agent-field")] as HTMLInputElement[];

beforeEach(() => {
  document.body.innerHTML = "";
  writeKey("openai", "");
  writeModel("openai", "");
});

describe("the panel", () => {
  it("mounts its three fields hidden, and takes them away on leave", () => {
    const { panel, overlay } = make();
    expect(fields(overlay)).toHaveLength(0);
    panel.mount();
    const els = fields(overlay);
    expect(els).toHaveLength(3);
    expect(els.every((el) => el.classList.contains("cwb-hidden"))).toBe(true);
    expect(els.map((el) => el.type)).toEqual(["text", "password", "text"]);
    panel.leave();
    expect(fields(overlay)).toHaveLength(0);
  });

  it("sends on Enter in the message field, and not an empty line", () => {
    const { panel, verbs, overlay } = make();
    panel.mount();
    const [field] = fields(overlay);
    field.value = "   ";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", cancelable: true }));
    expect(verbs.send).not.toHaveBeenCalled();
    field.value = "what does ? do";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", cancelable: true }));
    expect(verbs.send).toHaveBeenCalledWith("what does ? do");
    expect(field.value).toBe("");
  });

  it("saves the key and the model on Enter in the setup fields", () => {
    const { panel, overlay } = make();
    panel.mount();
    // The provider the panel saves for is the one it was last drawn with;
    // the default is anthropic, so point it at openai the way a tab does.
    (panel as unknown as { provider: string }).provider = "openai";
    const [, key, model] = fields(overlay);
    key.value = "  sk-live-1234567890  ";
    model.value = "gpt-4.1-mini";
    key.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", cancelable: true }));
    expect(readKey("openai")).toBe("sk-live-1234567890");
    expect(readModel("openai")).toBe("gpt-4.1-mini");
    expect(panel.status).toMatch(/saved/);
    key.value = "";
    key.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", cancelable: true }));
    expect(readKey("openai")).toBe("");
    expect(panel.status).toMatch(/removed/);
  });

  it("caps the room it draws from and snaps to the tail on a new message", () => {
    const { panel } = make();
    for (let i = 0; i < 520; i++) panel.push({ role: "user", text: `m${i}` });
    expect(panel.items).toHaveLength(500);
    expect(panel.items[0].text).toBe("m20");
    panel.scroll = 40;
    panel.push({ role: "agent", text: "new" });
    expect(panel.scroll).toBe(0);
  });

  it("hears nothing while closed, and the accelerator only while open", () => {
    const { panel, overlay } = make();
    panel.mount();
    const ev = () =>
      new KeyboardEvent("keydown", { key: "A", ctrlKey: true, shiftKey: true, cancelable: true });
    expect(panel.pointer(10, 10, "down")).toBe(false);
    expect(panel.wheel(3, 10, 10)).toBe(false);
    expect(panel.key("a", ev())).toBe(false);
    panel.open = true;
    panel.mode = "setup";
    expect(panel.key("a", ev())).toBe(true);
    expect(panel.mode).toBe("chat");
    // Unrelated keys pass through to the scene.
    expect(panel.key("escape", new KeyboardEvent("keydown", { key: "Escape" }))).toBe(false);
    expect(panel.key("a", new KeyboardEvent("keydown", { key: "a", ctrlKey: true }))).toBe(false);
    void overlay;
  });

  it("knows when the caret is in one of its fields", () => {
    const { panel, overlay } = make();
    panel.mount();
    expect(panel.focused).toBe(false);
    const [field] = fields(overlay);
    field.classList.remove("cwb-hidden");
    field.focus();
    expect(document.activeElement).toBe(field);
    expect(panel.focused).toBe(true);
  });
});
