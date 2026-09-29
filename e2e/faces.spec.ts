/**
 * The interface face: F8 from any screen, and the FONT chip on the map. It is
 * one preference for every screen, it survives a reload, and the fields laid
 * over the canvas follow it.
 */
import { expect } from "@playwright/test";
import {
  clickButton,
  freshAccount,
  login,
  pickCategory,
  pickLand,
  test,
} from "./fixtures";

const pref = (page: import("@playwright/test").Page, key: string) =>
  page.evaluate((k) => localStorage.getItem(`cwbhacker.${k}`), key);

test("F8 and the map's FONT chip change the interface face, for good", async ({
  page,
}) => {
  await login(page, freshAccount());
  await page.keyboard.press("F8");
  await expect.poll(async () => pref(page, "ui.face")).toBe("dos");

  await pickLand(page, "rust");
  await pickCategory(page, "basic");
  const chip = async () =>
    page.evaluate(
      () =>
        window.__cwbCapture!.buttons().find((b) => b.id === "uiface")?.label ??
        "",
    );
  expect(await chip()).toContain("DOS");
  await clickButton(page, "uiface");
  await expect.poll(async () => pref(page, "ui.face")).toBe("dunggeunmo");
  await expect.poll(chip).toContain("DUNGGEUNMO");

  // The DOM fields are set in it too, through `--cwb-body`.
  const bodyFace = () =>
    page.evaluate(() =>
      getComputedStyle(document.body)
        .fontFamily.split(",")[0]
        .replace(/"/g, ""),
    );
  expect(await bodyFace()).toBe("NeoDunggeunmo");

  // And it is still the face after a reload.
  await page.reload();
  await expect
    .poll(async () =>
      page.evaluate(() => typeof window.__cwbCapture?.buttons === "function"),
    )
    .toBe(true);
  await expect.poll(bodyFace).toBe("NeoDunggeunmo");
});
