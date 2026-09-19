import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { resyncSteps, snippetDiffers } from "../src/scenes/playground";

/**
 * The playground keeps a local mirror of the pad you have open, so text that
 * never reached the server survives a reload. It used to live under one key for
 * the whole origin — and once two tabs could be signed in as two accounts, one
 * account's unsaved draft was restored into the other's playground.
 *
 * It carried `id` with it, a snippet id belonging to somebody else, which the
 * next autosave then tried to save into. The server scopes snippets by address
 * and refuses, so nothing was corrupted; it showed the wrong text and then
 * failed.
 *
 * Driving the real scene would need a canvas, an `App`, a websocket and a
 * CodeMirror instance, none of which would make these any truer: what is being
 * asserted is that the key has the account in it and that nothing reads or
 * writes the mirror without one.
 */
const SOURCE = readFileSync(resolve(process.cwd(), "src/scenes/playground.ts"), "utf8");

describe("the playground's local mirror", () => {
  it("is keyed by the account, not by the origin", () => {
    // A template, so the address is part of the key rather than a prefix
    // somebody could forget to add at one of the seven call sites.
    expect(SOURCE).toMatch(/const LOCAL_KEY = \(address: string\) =>/);
    expect(SOURCE).toContain("address.toLowerCase()");
  });

  it("never touches storage without an account to key it by", () => {
    // Both directions: an unowned draft cannot be written anywhere sensible,
    // and cannot be handed back to anyone safely.
    for (const fn of ["private writeLocal(", "private restoreLocal("]) {
      const body = SOURCE.slice(SOURCE.indexOf(fn));
      const end = body.indexOf("\n  }");
      expect(body.slice(0, end)).toContain("if (!key) return;");
    }
  });

  it("reaches storage only through the keyed helper", () => {
    // The bug was one bare key used everywhere. A raw call with a string
    // literal, in either store, is the same mistake coming back.
    const direct = [...SOURCE.matchAll(/(local|session)Storage\.(get|set)Item\(\s*["'`]/g)];
    expect(direct).toHaveLength(0);
  });

  it("keeps the draft in the tab, beside the session that owns it", () => {
    // `sessionStorage`, so a tab practising as another identity cannot see it,
    // and so it still survives the reload the mirror exists for.
    const write = SOURCE.slice(SOURCE.indexOf("private writeLocal("));
    expect(write.slice(0, write.indexOf("\n  }"))).toContain("sessionStorage.setItem(key,");
    const read = SOURCE.slice(SOURCE.indexOf("private restoreLocal("));
    expect(read.slice(0, read.indexOf("\n  }"))).toContain("sessionStorage.getItem(key)");
  });

  it("uses localStorage for one thing only: deleting the old shared key", () => {
    const calls = [...SOURCE.matchAll(/localStorage\.(\w+)\(/g)].map((m) => m[1]);
    expect(calls).toEqual(["removeItem"]);
  });

  it("drops the old shared key rather than guessing whose draft it was", () => {
    const body = SOURCE.slice(SOURCE.indexOf("private restoreLocal("));
    expect(body.slice(0, body.indexOf("\n  }"))).toContain(
      "localStorage.removeItem(LEGACY_LOCAL_KEY)",
    );
  });
});

/**
 * PROTOCOL §6.5: a `playground.updated` or `chat.updated` sent while the
 * socket was down is not replayed. The screen has to ask again on reconnect —
 * and it did not: there was no `onState` watcher in the file at all, so a pad
 * saved on the tablet during a laptop's outage stayed stale until a reload.
 */
describe("what a reconnect asks for again", () => {
  it("re-lists the pads for a pad that was never saved, and nothing else", () => {
    // Nothing on the server could have changed under an unsaved pad, and a
    // room only exists once the pad does.
    expect(resyncSteps(null)).toEqual(["list"]);
  });

  it("re-reads the list, the open pad and its room for a saved one", () => {
    expect(resyncSteps("snip_1")).toEqual(["list", "pad", "room"]);
  });

  it("watches the connection from enter, in the list leave drains", () => {
    const enter = SOURCE.slice(SOURCE.indexOf("async enter(): Promise<void> {"));
    const regs = enter.slice(0, enter.indexOf('addEventListener("blur"'));
    expect(regs).toContain("this.offs.push(");
    expect(regs).toContain("this.app.client.onState(");
    expect([...SOURCE.matchAll(/onState\(/g)]).toHaveLength(1);
  });

  it("only asks after the socket has actually been away", () => {
    // The first `authed` after arriving has missed nothing; re-listing the
    // room on it would throw away what was said before the pad was saved.
    const enter = SOURCE.slice(SOURCE.indexOf("async enter(): Promise<void> {"));
    const handler = enter.slice(
      enter.indexOf("onState("),
      enter.indexOf('addEventListener("blur"'),
    );
    expect(handler).toContain("this.dropped = true");
    expect(handler).toContain("if (!this.dropped) return;");
  });

  it("hands the re-read pad to the same path a live update takes", () => {
    // `remoteSaved` is what decides apply-or-notify from `dirty`; a second
    // copy of that decision here would be the one that drifts.
    const body = SOURCE.slice(SOURCE.indexOf("private async resync("));
    const fn = body.slice(0, body.indexOf("\n  }"));
    expect(fn).toContain("this.remoteSaved(res.snippet)");
    expect(fn).not.toContain("this.load(");
  });
});

/**
 * The one decision in the resync that a source assertion cannot catch: what
 * "changed elsewhere" is measured against. Against the editor, a reconnect
 * with unsaved typing chimed and said "updated on another device" about the
 * player's own edits; against the saved baseline it says nothing.
 */
describe("whether the server's copy of the pad changed elsewhere", () => {
  const saved = { source: "fn main() {}", lang: "rust" as const, name: "SCRATCH", stdin: "" };

  it("is quiet when the server holds exactly what was last saved", () => {
    expect(snippetDiffers({ ...saved, stdin: undefined }, saved)).toBe(false);
    expect(snippetDiffers({ ...saved }, saved)).toBe(false);
  });

  it("notices a change to any of the four things a save carries", () => {
    expect(snippetDiffers({ ...saved, source: "fn main() { }" }, saved)).toBe(true);
    expect(snippetDiffers({ ...saved, lang: "go" }, saved)).toBe(true);
    expect(snippetDiffers({ ...saved, name: "SIEVE" }, saved)).toBe(true);
    expect(snippetDiffers({ ...saved, stdin: "3\n" }, saved)).toBe(true);
  });
});
