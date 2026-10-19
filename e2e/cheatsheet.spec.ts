/**
 * CHEATSHEET, end to end: four lines, one right, and the pick is the answer.
 *
 * The road is simpler than VERY BASIC on purpose — nothing is typed. So this
 * walks it the way a player does: open the first node of RUST × CHEATSHEET,
 * press a wrong choice and stay on the quest with the miss on the record,
 * press the right one and land on the verdict screen with the node cleared.
 * The choices come from the wire (`quest.quiz`); nothing is compiled.
 */
import {
  atScreen,
  clickButton,
  freshAccount,
  login,
  openSelectedNode,
  pickCategory,
  pickLand,
  test,
  Wire,
} from "./fixtures.js";
import { expect } from "@playwright/test";

// Both sheet roads: BASIC is the core grammar, ADVANCED the patterns, and
// the pick is the submission on each — the same judge, the same record.
for (const road of ["cheatsheet", "cheatsheet_advanced"] as const) {
test(`${road}: a wrong pick stays on the quest, the right one clears it`, async ({
  page,
}) => {
  const account = freshAccount();
  const wire = await Wire.as(test.info().project.use.baseURL!, account);
  try {
    await login(page, account);
    await pickLand(page, "rust");
    await pickCategory(page, road);
    await openSelectedNode(page);
    // A fresh account's map opens on node 1. A cheatsheet quest has no
    // starter to recognise it by, so it is read off the map instead.
    const first = (await wire.mapOf("rust", road)).sort(
      (a, b) => a.node - b.node,
    )[0];
    const id = first.quest_id;
    expect(id.startsWith(`rust.${road}.`), id).toBe(true);

    const quest = (await wire.ok("quest.get", { quest_id: id }))
      .quest as Record<string, unknown>;
    const quiz = quest.quiz as { choices: string[]; answer: number };
    expect(quiz.choices).toHaveLength(4);

    // A wrong pick: recorded, and the screen stays where it is.
    const wrong = (quiz.answer + 1) % 4;
    await clickButton(page, `choice:${wrong}`);
    await expect
      .poll(async () => (await wire.history()).length, {
        message: "the wrong pick reached the server as a submission",
      })
      .toBe(1);
    expect((await wire.history())[0].verdict).toBe("wrong_answer");
    await atScreen(page, "quest");

    // The right one: the verdict screen, and the node is cleared.
    await clickButton(page, `choice:${quiz.answer}`);
    await atScreen(page, "result");
    const history = await wire.history();
    expect(history.length).toBe(2);
    expect(history.some((a) => a.verdict === "accepted")).toBe(true);
    const after = (await wire.ok("quest.get", { quest_id: id }))
      .quest as Record<string, unknown>;
    expect(after.state).toBe("cleared");
  } finally {
    wire.close();
  }
});
}
