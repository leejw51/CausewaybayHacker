/**
 * Folding a room's messages by cursor, with no network in it.
 *
 * The server hands out two int64s per message (PROTOCOL §4.9f): `id` names
 * it, `timeid` orders it and is what "after N" means. A client keeps the
 * messages it has and the highest `timeid` it has seen, asks for what came
 * after, and folds the page in: **by `id`** — a message seen twice replaces
 * the copy held rather than appearing twice — and in `timeid` order. The
 * cursor advances over every message received, even ones the fold ignores,
 * or a page that starts with something unwanted would be asked for for ever
 * (PocketSkynet's rule, and its bug).
 *
 * Pure, so `tests/agent-sync.test.ts` can pin it.
 */
import type { ChatMessage } from "../../net/protocol";

export interface Room {
  messages: ChatMessage[];
  /** The highest `timeid` folded so far; 0 with nothing. */
  cursor: number;
  /**
   * Tombstones folded, by id, with the `timeid` each carried — so a copy of
   * a deleted message that arrives afterwards (a page out of order, a
   * replay) cannot bring it back.
   */
  retired: Record<number, number>;
}

export function emptyRoom(): Room {
  return { messages: [], cursor: 0, retired: {} };
}

/**
 * Fold one page into the room. Returns the room (a new object; the input is
 * not touched) and whether anything actually changed.
 */
export function fold(room: Room, page: readonly ChatMessage[]): { room: Room; changed: boolean } {
  if (page.length === 0) return { room, changed: false };
  const byId = new Map<number, ChatMessage>();
  for (const m of room.messages) byId.set(m.id, m);
  const retired = { ...room.retired };
  let changed = false;
  let cursor = room.cursor;
  for (const m of page) {
    if (m.timeid > cursor) cursor = m.timeid;
    if (m.deleted) {
      // A tombstone retires the copy and is remembered, so nothing older
      // than it can bring the message back.
      if (byId.delete(m.id)) changed = true;
      if (!(m.id in retired) || retired[m.id] < m.timeid) retired[m.id] = m.timeid;
      continue;
    }
    if (m.id in retired && retired[m.id] >= m.timeid) continue;
    const held = byId.get(m.id);
    // Last writer by timeid wins; an older copy of what is held is noise.
    if (!held || m.timeid >= held.timeid) {
      if (!held || held.timeid !== m.timeid || held.text !== m.text) changed = true;
      byId.set(m.id, m);
    }
  }
  if (cursor !== room.cursor) changed = true;
  const messages = [...byId.values()].sort((a, b) => a.timeid - b.timeid || a.id - b.id);
  return { room: { messages, cursor, retired }, changed };
}

/** The cursor to send next: the room's, never lower than what a page carried. */
export function nextCursor(room: Room, page: readonly ChatMessage[]): number {
  let c = room.cursor;
  for (const m of page) if (m.timeid > c) c = m.timeid;
  return c;
}

/**
 * Whether a drain loop should ask again: the server said `more`, and the
 * cursor actually moved — a page that moved nothing would be asked for again
 * for ever.
 */
export function shouldContinue(before: number, after: number, more: boolean): boolean {
  return more && after > before;
}
