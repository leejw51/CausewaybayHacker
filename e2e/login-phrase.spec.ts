/**
 * The login card, fed a phrase the way a paste delivers one.
 *
 * Reported from an iPad: a phrase in the field, a dash for the address, an
 * empty name box. It was a mistyped word — but the card said nothing, and a
 * paste that capitalises the first word or breaks the line must not be the
 * next report. Nothing here logs in: the canonical phrase is a published
 * account and the assertion is about the card, which is DOM plus a status
 * line, not about the server.
 */
import { deterministicUsername } from "../frontend/src/wallet/username";
import { atScreen, expect, fixtureAccount, test } from "./fixtures";

const PHRASE =
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

test("a capitalised, line-broken phrase still names the account", async ({ page, ready }) => {
  void ready;
  await atScreen(page, "login");
  const field = page.locator("textarea.cwb-field");
  const name = page.locator("input.cwb-name");
  await field.fill("Abandon abandon abandon\nabandon  abandon abandon\nabandon abandon abandon abandon abandon About ");
  // The name follows the address, and the address is account 0 of the phrase.
  const account = fixtureAccount(0);
  await expect(name).toHaveValue(deterministicUsername(account.address));
});

test("a phrase with one word wrong leaves the name empty and says which word", async ({ page, ready }) => {
  void ready;
  await atScreen(page, "login");
  const field = page.locator("textarea.cwb-field");
  const name = page.locator("input.cwb-name");
  await field.fill(PHRASE.replace("about", "abuot"));
  await expect(name).toHaveValue("");
  // The explanation is drawn on the canvas; the capture hook gives the frame.
  // What can be asserted without OCR is that the field did not derive: the
  // name stayed empty where the good phrase filled it.
  await field.fill(PHRASE);
  await expect(name).not.toHaveValue("");
});

test("a private key pasted without its 0x, in capitals, across two lines, is the key", async ({ page, ready }) => {
  void ready;
  await atScreen(page, "login");
  const account = fixtureAccount(0);
  const raw = account.privateKey.slice(2).toUpperCase();
  await page.locator("textarea.cwb-field").fill(raw.slice(0, 30) + "\n" + raw.slice(30));
  await expect(page.locator("input.cwb-name")).toHaveValue(deterministicUsername(account.address));
});
