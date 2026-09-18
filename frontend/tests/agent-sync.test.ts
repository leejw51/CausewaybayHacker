/**
 * Message sync on the client: the fold and the cursor (PROTOCOL §4.9f).
 *
 * What is pinned: a page folds in by `id` and comes out in `timeid` order;
 * a replayed page changes nothing; a newer copy of a held message wins and
 * an older one is ignored; the cursor is the highest `timeid` received,
 * over every message, including ones already held; and the drain loop
 * stops when the server says so or when a page moved nothing.
 */
import { describe, expect, it } from "vitest";
import type { ChatMessage } from "../src/net/protocol";
import { emptyRoom, fold, nextCursor, roomMove, shouldContinue } from "../src/ui/agent/sync";

function msg(id: number, timeid: number, text = `m${id}`): ChatMessage {
  return {
    id,
    timeid,
    snippet_id: "pg_1",
    role: "user",
    kind: "text",
    text,
    photo_url: null,
    provider: null,
    model: null,
    created_at: "2026-09-17T00:00:00Z",
    edited: false,
    deleted: false,
  };
}

function gone(id: number, timeid: number): ChatMessage {
  return { ...msg(id, timeid, ""), deleted: true };
}

describe("the fold", () => {
  it("starts empty at cursor 0, which is the cold-start cursor", () => {
    const r = emptyRoom();
    expect(r.messages).toEqual([]);
    expect(r.cursor).toBe(0);
  });

  it("orders a page by timeid and moves the cursor to the top of it", () => {
    const { room, changed } = fold(emptyRoom(), [msg(3, 300), msg(1, 100), msg(2, 200)]);
    expect(changed).toBe(true);
    expect(room.messages.map((m) => m.id)).toEqual([1, 2, 3]);
    expect(room.cursor).toBe(300);
  });

  it("is idempotent under replay", () => {
    const page = [msg(1, 100), msg(2, 200)];
    const once = fold(emptyRoom(), page).room;
    const twice = fold(once, page);
    expect(twice.changed).toBe(false);
    expect(twice.room.messages).toEqual(once.messages);
    expect(twice.room.cursor).toBe(200);
  });

  it("folds by id: a newer copy replaces, an older one is ignored", () => {
    const held = fold(emptyRoom(), [msg(1, 100, "first"), msg(2, 200, "second")]).room;
    const edited = fold(held, [msg(1, 250, "first, edited")]);
    expect(edited.changed).toBe(true);
    expect(edited.room.messages.map((m) => m.text)).toEqual(["second", "first, edited"]);
    expect(edited.room.messages).toHaveLength(2);
    expect(edited.room.cursor).toBe(250);
    const stale = fold(edited.room, [msg(1, 100, "first")]);
    expect(stale.changed).toBe(false);
    expect(stale.room.messages.map((m) => m.text)).toEqual(["second", "first, edited"]);
  });

  it("retires a held message on its tombstone, and still moves the cursor", () => {
    const held = fold(emptyRoom(), [msg(1, 100), msg(2, 200)]).room;
    const after = fold(held, [gone(1, 300)]);
    expect(after.changed).toBe(true);
    expect(after.room.messages.map((m) => m.id)).toEqual([2]);
    expect(after.room.cursor).toBe(300);
    // A tombstone for something never held changes nothing but the cursor.
    const unknown = fold(after.room, [gone(9, 400)]);
    expect(unknown.changed).toBe(true);
    expect(unknown.room.messages.map((m) => m.id)).toEqual([2]);
    expect(unknown.room.cursor).toBe(400);
    // An old copy arriving after the tombstone does not bring it back: the
    // fold remembers what it retired and at what timeid.
    const zombie = fold(unknown.room, [msg(1, 100)]);
    expect(zombie.changed).toBe(false);
    expect(zombie.room.messages.map((m) => m.id)).toEqual([2]);
    expect(zombie.room.retired).toEqual({ 1: 300, 9: 400 });
    // A message posted anew under a retired id with a later timeid would be
    // a server bug; the fold still takes it, because the number says so.
    const reborn = fold(zombie.room, [msg(1, 500, "again")]);
    expect(reborn.room.messages.map((m) => m.id)).toEqual([2, 1]);
  });

  it("folds an edit as a replacement that keeps its place by id", () => {
    const held = fold(emptyRoom(), [msg(1, 100, "typo"), msg(2, 200)]).room;
    const edited = { ...msg(1, 300, "fixed"), edited: true };
    const { room } = fold(held, [edited]);
    expect(room.messages).toHaveLength(2);
    expect(room.messages.find((m) => m.id === 1)?.text).toBe("fixed");
    expect(room.messages.find((m) => m.id === 1)?.edited).toBe(true);
    expect(room.cursor).toBe(300);
  });

  it("does not touch the room it was given", () => {
    const before = fold(emptyRoom(), [msg(1, 100)]).room;
    const snapshot = JSON.stringify(before);
    fold(before, [msg(2, 200)]);
    expect(JSON.stringify(before)).toBe(snapshot);
  });

  it("advances the cursor over everything received, held or not", () => {
    const held = fold(emptyRoom(), [msg(1, 100)]).room;
    // A page that carries only what is already held still moves the cursor
    // if its timeid is higher — otherwise the same page is asked for again.
    expect(nextCursor(held, [msg(1, 100)])).toBe(100);
    expect(nextCursor(held, [msg(1, 500)])).toBe(500);
    expect(nextCursor(held, [])).toBe(100);
  });

  it("never lets the cursor go backwards", () => {
    const held = fold(emptyRoom(), [msg(5, 500)]).room;
    const older = fold(held, [msg(2, 200)]);
    expect(older.room.cursor).toBe(500);
    expect(older.room.messages.map((m) => m.id)).toEqual([2, 5]);
  });

  it("ties on timeid fall back to id, so the order is total", () => {
    const { room } = fold(emptyRoom(), [msg(9, 100), msg(4, 100), msg(7, 100)]);
    expect(room.messages.map((m) => m.id)).toEqual([4, 7, 9]);
  });
});

describe("the drain loop", () => {
  it("goes on while the server says more and the cursor moved", () => {
    expect(shouldContinue(0, 100, true)).toBe(true);
    expect(shouldContinue(100, 200, true)).toBe(true);
  });

  it("stops when the server says there is no more", () => {
    expect(shouldContinue(0, 100, false)).toBe(false);
  });

  it("stops when a page moved nothing, whatever the server says", () => {
    expect(shouldContinue(100, 100, true)).toBe(false);
    expect(shouldContinue(100, 50, true)).toBe(false);
  });

  it("drains a paged server to the head", () => {
    // A server holding nine messages that pages three at a time.
    const all = Array.from({ length: 9 }, (_, i) => msg(i + 1, (i + 1) * 100));
    const server = (after: number, limit: number) => {
      const rest = all.filter((m) => m.timeid > after);
      return { messages: rest.slice(0, limit), more: rest.length > limit };
    };
    let room = emptyRoom();
    let pages = 0;
    for (;;) {
      const before = room.cursor;
      const page = server(before, 3);
      room = fold(room, page.messages).room;
      pages++;
      if (!shouldContinue(before, room.cursor, page.more)) break;
      if (pages > 10) throw new Error("the loop did not end");
    }
    expect(pages).toBe(3);
    expect(room.messages).toHaveLength(9);
    expect(room.cursor).toBe(900);
  });
});

describe("which pad the room follows", () => {
  it("tells the first save from a different pad, and two unsaved pads apart", () => {
    const unsaved = { key: "1", id: null };
    expect(roomMove(null, unsaved)).toBe("switch");
    expect(roomMove(unsaved, { key: "1", id: null })).toBe("same");
    // The first save landing: the same pad, now with an id.
    expect(roomMove(unsaved, { key: "1", id: "pg_a" })).toBe("arriving");
    expect(roomMove({ key: "1", id: "pg_a" }, { key: "1", id: "pg_a" })).toBe("same");
    // NEW from an unsaved pad: null to null, and it must NOT read as no change.
    expect(roomMove(unsaved, { key: "2", id: null })).toBe("switch");
    // A saved pad opened from an unsaved one: not this room arriving.
    expect(roomMove(unsaved, { key: "2", id: "pg_b" })).toBe("switch");
    // Another pad from the list; the held pad deleted.
    expect(roomMove({ key: "1", id: "pg_a" }, { key: "2", id: "pg_b" })).toBe("switch");
    expect(roomMove({ key: "1", id: "pg_a" }, { key: "2", id: null })).toBe("switch");
  });
});
