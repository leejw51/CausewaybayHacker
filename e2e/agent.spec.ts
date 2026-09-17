/**
 * The Rust coder, driven the way a person drives it.
 *
 * Two halves. The first needs no key and runs everywhere: the land select
 * offers CODE PLAYGROUND as a tile, the AGENT panel opens with its tabs and
 * verbs, a message with no key set goes nowhere but SETUP, and CLOSE puts it
 * away. The second needs `GROK_API_KEY` in the environment and is skipped
 * without it: a real ask is answered, the room is a messenger — the message
 * is picked, edited, deleted — a picture is made and posted, and every step
 * is checked **on the wire**, through a second session as the same wallet,
 * against what the server says the room holds (PROTOCOL §4.9f).
 */
import { expect, type Page } from "@playwright/test";
import {
  atScreen,
  clickButton,
  freshAccount,
  login,
  sceneNow,
  test,
  Wire,
} from "./fixtures";

const SERVER = process.env.E2E_BASE_URL ?? "http://127.0.0.1:5390";
const GROK = process.env.GROK_API_KEY;

test.describe.configure({ mode: "serial" });

async function buttons(
  page: Page,
): Promise<Array<{ id: string; label: string; dim: boolean }>> {
  return page.evaluate(() =>
    window
      .__cwbCapture!.buttons()
      .map((b) => ({ id: b.id, label: b.label, dim: b.dim })),
  );
}

async function ids(page: Page): Promise<string[]> {
  return (await buttons(page)).map((b) => b.id);
}

/** The server-backed messages on screen, as `msg:<id>` button ids, in order. */
async function messages(page: Page): Promise<string[]> {
  return (await ids(page)).filter((i) => i.startsWith("msg:"));
}

async function atPlayground(page: Page): Promise<void> {
  await expect
    .poll(async () => sceneNow(page), { timeout: 30_000 })
    .toBe("playground");
  await page.evaluate(() => {
    window.__cwbCapture?.settle();
    window.__cwbCapture?.resume();
  });
}

/** The coder's field: the first of the panel's three inputs. */
function field(page: Page) {
  return page.locator("input.cwb-agent-field").first();
}

/** Until STOP goes dim again: the coder has finished its rounds. */
async function untilIdle(page: Page): Promise<void> {
  await page.waitForTimeout(3000);
  await expect
    .poll(
      async () =>
        (await buttons(page)).find((b) => b.id === "stop")?.dim ?? true,
      {
        timeout: 120_000,
        message: "the coder is still busy",
      },
    )
    .toBe(true);
}

/** Pick a message: a tap on one picks it, a tap on the picked one lets go. */
async function pick(page: Page, id: string): Promise<void> {
  await clickButton(page, id);
  if (!(await ids(page)).includes("deletemsg")) await clickButton(page, id);
  expect(await ids(page)).toContain("deletemsg");
}

test("CODE PLAYGROUND is a tile, and the coder's panel is on the code page", async ({
  page,
}) => {
  await login(page, freshAccount());
  const tile = (await buttons(page)).find((b) => b.id === "playground");
  expect(tile, "the land select offers the playground").toBeTruthy();
  expect(tile!.label.toUpperCase()).toContain("PLAYGROUND");

  await clickButton(page, "playground");
  await atPlayground(page);
  expect(await ids(page)).toContain("agent");

  await clickButton(page, "agent");
  await expect.poll(async () => ids(page)).toContain("send");
  const all = await ids(page);
  for (const id of [
    "prov:anthropic",
    "prov:openai",
    "prov:grok",
    "setup",
    "close",
    "write",
    "review",
    "stop",
    "clearroom",
  ]) {
    expect(all, id).toContain(id);
  }
  // A fresh pad has no room yet, so there is no IMAGE to post a picture into.
  expect(all).not.toContain("image");

  // Without a key, a message goes nowhere but SETUP.
  await field(page).click();
  await page.keyboard.type("hello?");
  await page.keyboard.press("Enter");
  await expect
    .poll(async () => ids(page), { timeout: 10_000 })
    .toContain("savekey");
  expect(await ids(page)).toContain("fetch");
  expect(await messages(page)).toEqual([]);

  await clickButton(page, "close");
  await expect.poll(async () => ids(page)).not.toContain("send");
  await expect.poll(async () => ids(page)).toContain("unfocus");
});

test("with a key the coder answers, and the room is a messenger that syncs", async ({
  page,
}) => {
  test.skip(!GROK, "needs GROK_API_KEY in the environment");
  const account = freshAccount();
  await login(page, account);
  // The key the way SETUP would keep it: in this browser, under cwbhacker.ai.*.
  await page.evaluate((k) => {
    localStorage.setItem("cwbhacker.ai.key.grok", k);
    localStorage.setItem("cwbhacker.ai.provider", "grok");
  }, GROK!);
  await clickButton(page, "playground");
  await atPlayground(page);
  await clickButton(page, "agent");
  await expect.poll(async () => ids(page)).toContain("send");

  // One real ask. The reply is the model's; what is asserted is the room.
  await field(page).click();
  await page.keyboard.type("Reply with exactly the word: pong");
  await page.keyboard.press("Enter");
  await untilIdle(page);
  await expect
    .poll(async () => (await messages(page)).length, { timeout: 10_000 })
    .toBeGreaterThanOrEqual(2);
  const [mine, theirs] = await messages(page);

  // The wire's view: a room under a pad that now exists, with both messages.
  const wire = await Wire.as(SERVER, account);
  const pads = (await wire.ok("playground.list", {})) as {
    snippets: Array<{ id: string }>;
  };
  expect(pads.snippets.length, "the ask made the pad exist").toBe(1);
  const pad = pads.snippets[0].id;
  const room = (await wire.ok("playground.chat.list", { id: pad })) as {
    messages: Array<{
      id: number;
      timeid: number;
      role: string;
      text: string;
      edited: boolean;
      deleted: boolean;
    }>;
  };
  expect(room.messages.map((m) => `msg:${m.id}`)).toEqual([mine, theirs]);
  expect(room.messages[0]).toMatchObject({
    role: "user",
    text: "Reply with exactly the word: pong",
    edited: false,
  });
  expect(room.messages[1].role).toBe("agent");
  expect(room.messages[1].timeid).toBeGreaterThan(room.messages[0].timeid);
  const cursor = room.messages[1].timeid;

  // Edit the message that was sent: same id, new words, later timeid.
  await pick(page, mine);
  await clickButton(page, "editmsg");
  await expect
    .poll(async () => field(page).inputValue())
    .toBe("Reply with exactly the word: pong");
  await field(page).fill("Reply with exactly the word: pong (edited)");
  await field(page).press("Enter");
  // An edit moves the message's timeid, and the list is in timeid order, so
  // the message is found by id, not by where it was.
  const mineId = Number(mine.slice(4));
  await expect
    .poll(
      async () => {
        const r = (await wire.ok("playground.chat.list", {
          id: pad,
        })) as typeof room;
        return r.messages.find((m) => m.id === mineId)?.text;
      },
      { timeout: 10_000 },
    )
    .toBe("Reply with exactly the word: pong (edited)");
  const edited = (await wire.ok("playground.chat.sync", { after: cursor })) as {
    messages: Array<{ id: number; edited: boolean; deleted: boolean }>;
  };
  expect(
    edited.messages.map((m) => [`msg:${m.id}`, m.edited, m.deleted]),
  ).toEqual([[mine, true, false]]);

  // Delete the reply: a tombstone on the wire, gone from the screen.
  await pick(page, theirs);
  await clickButton(page, "deletemsg");
  await expect
    .poll(async () => messages(page), { timeout: 10_000 })
    .toEqual([mine]);
  const after = (await wire.ok("playground.chat.sync", {
    after: cursor,
  })) as typeof edited;
  expect(
    after.messages.map((m) => [`msg:${m.id}`, m.edited, m.deleted]),
  ).toEqual([
    [mine, true, false],
    [theirs, false, true],
  ]);
  const fresh = (await wire.ok("playground.chat.list", {
    id: pad,
  })) as typeof room;
  expect(
    fresh.messages.map((m) => `msg:${m.id}`),
    "a room read from the start hides the tombstone",
  ).toEqual([mine]);

  // A picture, made by the model and posted to the room.
  await field(page).click();
  await page.keyboard.type(
    "a small orange crab holding a cup of milk tea, 16-bit pixel art",
  );
  await clickButton(page, "image");
  await untilIdle(page);
  await expect
    .poll(
      async () => {
        const r = (await wire.ok("playground.chat.list", { id: pad })) as {
          messages: Array<{ kind: string; photo_url: string | null }>;
        };
        return r.messages.filter((m) => m.kind === "image" && m.photo_url)
          .length;
      },
      { timeout: 30_000, message: "a photo was posted" },
    )
    .toBeGreaterThanOrEqual(1);
  const withPhoto = (await wire.ok("playground.chat.list", { id: pad })) as {
    messages: Array<{ kind: string; photo_url: string | null }>;
  };
  const photo = withPhoto.messages.find((m) => m.kind === "image")!;
  const res = await page.request.get(
    new URL(photo.photo_url!, SERVER).toString(),
  );
  expect(res.status(), "the photo route serves the owner's token").toBe(200);
  expect(res.headers()["content-type"]).toMatch(/^image\//);
  expect((await res.body()).length).toBeGreaterThan(1000);

  // Leave and come back: the room is read again from the server. Only the
  // rows in the well are buttons, and a photo is tall, so what is asserted
  // is the tail: the newest message is on screen, the tombstone is not, and
  // the wire holds exactly the four that survived.
  await clickButton(page, "close");
  await page.keyboard.press("Escape");
  await atScreen(page, "lands");
  await clickButton(page, "playground");
  await atPlayground(page);
  await clickButton(page, "agent");
  const survived = (await wire.ok("playground.chat.list", { id: pad })) as {
    messages: Array<{ id: number; kind: string }>;
  };
  // The edited ask, the IMAGE ask as sent, the photo, and the note about it.
  expect(survived.messages.map((m) => m.kind)).toEqual([
    "text",
    "text",
    "image",
    "text",
  ]);
  expect(survived.messages.map((m) => `msg:${m.id}`)).toContain(mine);
  expect(survived.messages.map((m) => `msg:${m.id}`)).not.toContain(theirs);
  const newest = `msg:${survived.messages[survived.messages.length - 1].id}`;
  await expect
    .poll(async () => messages(page), { timeout: 10_000 })
    .toContain(newest);
  expect(await messages(page)).not.toContain(theirs);
  wire.close();
});
