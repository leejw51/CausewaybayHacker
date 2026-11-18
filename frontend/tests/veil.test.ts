import { describe, expect, it } from "vitest";
import { veiled } from "../src/ui/scorepop";

/**
 * CONSOLE's veil must always lift. On the iPad home screen it came up black
 * and stayed: something it waited on never answered.
 */
describe("veiled", () => {
  it("lifts the veil even when the change never finishes", async () => {
    const host = document.createElement("div");
    document.body.appendChild(host);
    const t0 = Date.now();
    await veiled(host, () => new Promise(() => {}), 50);
    expect(host.querySelector(".cwb-veil")).toBeNull();
    // The change's own limit plus the bounded fades and frames, not for ever.
    expect(Date.now() - t0).toBeLessThan(3000);
    host.remove();
  });

  it("lifts it when the change throws, and runs the next one", async () => {
    const host = document.createElement("div");
    document.body.appendChild(host);
    await veiled(host, () => Promise.reject(new Error("no font")), 50).catch(() => {});
    expect(host.querySelector(".cwb-veil")).toBeNull();
    let ran = false;
    await veiled(
      host,
      () => {
        ran = true;
      },
      50,
    );
    expect(ran).toBe(true);
    expect(host.querySelector(".cwb-veil")).toBeNull();
    host.remove();
  });
});
