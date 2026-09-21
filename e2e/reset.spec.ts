/**
 * RESET, end to end (PROTOCOL §4.7b).
 *
 * The one control in the game that throws work away, so the things worth
 * proving in a real browser against a real server are the ones a unit test
 * cannot see: that it asks first, that saying no changes nothing at all, and
 * that saying yes empties the road the player was looking at and nothing
 * else.
 */
import {
  atScreen,
  clickButton,
  enterRustQuest,
  freshAccount,
  login,
  setSource,
  sourceThatPrints,
  submit,
  test,
  Wire,
} from "./fixtures.js";
import { expect } from "@playwright/test";

/** A program that passes whatever quest the browser happens to have opened. */
async function passing(wire: Wire, quest: string): Promise<string> {
  const got = await wire.ok("quest.get", { quest_id: quest });
  const source = sourceThatPrints(
    (
      got.quest as {
        tests?: { visible?: { stdin?: string; expect?: string }[] };
      }
    ).tests?.visible?.[0],
  );
  if (!source) throw new Error(`no sample case to answer for ${quest}`);
  return source;
}

/** The road's cleared count, straight from the server. */
async function clearedCount(wire: Wire, category = "basic"): Promise<number> {
  const map = await wire.ok("world.map", { land: "rust", category });
  return (map.nodes as Array<{ state: string }>).filter(
    (n) => n.state === "cleared",
  ).length;
}

test("RESET asks first, and a no leaves the road exactly as it was", async ({
  page,
}) => {
  const account = freshAccount();
  const wire = await Wire.as(test.info().project.use.baseURL!, account);
  try {
    await login(page, account);
    const quest = await enterRustQuest(page, wire);
    // Clear it the way a player does, so there is something to reset.
    await setSource(page, await passing(wire, quest));
    await submit(page);
    await atScreen(page, "result");
    await clickButton(page, "map");
    await atScreen(page, "map");
    expect(await clearedCount(wire)).toBe(1);

    // The button only exists once there is something to throw away.
    await clickButton(page, "reset");
    await clickButton(page, "modal:cancel");
    await page.waitForTimeout(500);
    expect(await clearedCount(wire), "a no must change nothing").toBe(1);
  } finally {
    wire.close();
  }
});

test("RESET empties the road it was asked about, and keeps the XP", async ({
  page,
}) => {
  const account = freshAccount();
  const wire = await Wire.as(test.info().project.use.baseURL!, account);
  try {
    await login(page, account);
    const quest = await enterRustQuest(page, wire);
    await setSource(page, await passing(wire, quest));
    await submit(page);
    await atScreen(page, "result");
    await clickButton(page, "map");
    await atScreen(page, "map");

    const before = (await wire.ok("profile.update", {})).user as { xp: number };
    expect(before.xp, "the clear paid something").toBeGreaterThan(0);

    await clickButton(page, "reset");
    await clickButton(page, "modal:confirm");
    await page.waitForTimeout(1500);

    expect(await clearedCount(wire), "the road is untouched again").toBe(0);
    const after = (await wire.ok("profile.update", {})).user as { xp: number };
    expect(after.xp, "XP is history, not progress").toBe(before.xp);

    // Nothing left to reset, so the button takes itself off the bar.
    const gone = await page.evaluate(
      () => window.__cwbCapture?.buttonAt("reset") ?? null,
    );
    expect(gone).toBeNull();
  } finally {
    wire.close();
  }
});
