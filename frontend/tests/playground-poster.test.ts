/**
 * POSTER and DISK READER, as wired into the playground.
 *
 * The scene needs a canvas, an `App`, a socket and CodeMirror, none of which
 * would make these truer; what is asserted is the wiring the first poster
 * anybody made was missing — that a tab with no key is *asked* for one
 * rather than handed an unsigned poster, that a key for the wrong account
 * is wiped again at once, and that the picture is proved before it is saved.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const SOURCE = readFileSync(resolve(process.cwd(), "src/scenes/playground.ts"), "utf8");

/** The body of one method, from its signature to the first `\n  }`. */
function method(name: string): string {
  const at2 = [`  private ${name}(`, `  private async ${name}(`, `\n  ${name}(`]
    .map((sig) => SOURCE.indexOf(sig))
    .find((i) => i >= 0);
  expect(at2, `${name} exists`).toBeGreaterThan(0);
  const body = SOURCE.slice(at2!);
  return body.slice(0, body.indexOf("\n  }\n") + 4);
}

describe("POSTER", () => {
  it("asks for the key instead of making an unsigned poster", () => {
    const poster = method("poster");
    expect(poster).toContain("if (!isUnlocked())");
    expect(poster).toContain("this.startStamp();");
    // Once past that gate the signature is never null.
    expect(poster).toContain("signMessage(source)");
    expect(poster).not.toContain("isUnlocked() ? signMessage");
    expect(SOURCE).not.toContain("pg.posterUnsigned");
  });

  it("prints English on the picture whatever the screen is in", () => {
    const poster = method("poster");
    // Every word handed to the renderer comes from the English catalogue.
    const words = poster.slice(poster.indexOf("words: {"), poster.indexOf("assets:"));
    expect(words).not.toMatch(/[^n]t\(/);
    expect(words.match(/tEn\(/g)?.length).toBeGreaterThanOrEqual(8);
    expect(poster).toContain("EN_OUTCOME[r.outcome]");
    expect(poster).toContain('tEn("pg.timings"');
    expect(SOURCE).toContain("const EN_OUTCOME");
  });

  it("signs the source and only the source", () => {
    const poster = method("poster");
    expect(poster).toMatch(/signMessage\(source\)/);
    expect(poster).not.toMatch(/signMessage\(JSON|signMessage\(`/);
  });

  it("proves the disk before saving, and stops when it fails", () => {
    const poster = method("poster");
    const prove = poster.indexOf("proveDisk(");
    const save = poster.indexOf("savePoster(");
    expect(prove).toBeGreaterThan(0);
    expect(save).toBeGreaterThan(prove);
    const between = poster.slice(prove, save);
    expect(between).toContain('t("pg.posterCheckFailed"');
    expect(between).toMatch(/if \(failed\) \{[\s\S]*return;/);
  });

  it("writes the PNG with its proof and a JPEG beside it", () => {
    const poster = method("poster");
    for (const k of [
      "Source: source",
      "Lang: this.held.lang",
      "Signer: address",
      "meta.Signature = signature",
    ]) {
      expect(poster).toContain(k);
    }
    expect(poster).toContain('type: "image/png"');
    expect(poster).toContain('type: "image/jpeg"');
  });
});

describe("a finger can open them", () => {
  it("fires POSTER and READER on the pointerup, where a touch has its activation", () => {
    // A finger's `pointerdown` grants no user activation; only its `pointerup`
    // does. The picker, the share sheet and a download are all refused
    // without one — the whole of "does not work on an iPad".
    const pointer = method("pointer");
    const up = pointer.indexOf('if (phase === "up")');
    const down = pointer.indexOf('if (phase !== "down") return;');
    expect(up).toBeGreaterThan(0);
    expect(down).toBeGreaterThan(up);
    const onUp = pointer.slice(up, down);
    expect(onUp).toContain("this.poster()");
    expect(onUp).toContain("this.diskEl.click()");
    const onDown = pointer.slice(down);
    expect(onDown).not.toContain("this.poster()");
    expect(onDown).not.toContain("this.diskEl.click()");
    // And only if the finger came up on the same button it went down on.
    expect(onUp).toMatch(/\.id === armed/);
  });

  it("hands the poster to the share sheet on anything touched, not only a phone", () => {
    const poster = method("poster");
    expect(poster).toContain("this.app.layout.touch,");
    expect(poster).not.toContain("isPhone()");
  });
});

describe("the key field", () => {
  it("derives at the account index login used, and only accepts the signed-in account", () => {
    const stamp = method("stampWith");
    expect(stamp).toContain("readNumberPref(INDEX_PREF");
    expect(stamp).toContain("unlock(typed, index)");
    expect(stamp).toContain("who.lower !== me.toLowerCase()");
    // A stranger's key is wiped before anything else happens.
    const mismatch = stamp.slice(stamp.indexOf("who.lower !== me.toLowerCase()"));
    expect(mismatch.indexOf("wipe();")).toBeGreaterThan(0);
    expect(mismatch.indexOf("wipe();")).toBeLessThan(mismatch.indexOf("return;"));
  });

  it("is masked, never autocompleted, and emptied on every exit", () => {
    expect(SOURCE).toMatch(/key\.type = "password";/);
    expect(SOURCE).toMatch(/key\.autocomplete = "off";/);
    const stop = method("stopStamp");
    expect(stop).toContain('this.keyEl.value = "";');
    // Blur cancels: nothing typed into a key field sits on screen unattended.
    expect(SOURCE).toMatch(/key\.addEventListener\("blur"[\s\S]{0,300}this\.stopStamp\(\)/);
    // And leaving the screen puts it away too.
    const leave = SOURCE.slice(SOURCE.indexOf("  leave(): void {"));
    expect(leave.slice(0, leave.indexOf("\n  }\n"))).toContain("this.stopStamp();");
  });
});

describe("DISK READER", () => {
  it("opens the program as a new pad and never over the open one", () => {
    const read = method("readDisk");
    expect(read.indexOf("this.fresh();")).toBeGreaterThan(0);
    expect(read.indexOf("this.fresh();")).toBeLessThan(
      read.indexOf("this.held.source = disk.source;"),
    );
  });

  it("says the verdict, and refuses a label that holds only a hash", () => {
    const read = method("readDisk");
    for (const k of [
      "pg.diskVerified",
      "pg.diskForged",
      "pg.diskUnsigned",
      "pg.diskHashed",
      "pg.diskNone",
    ]) {
      expect(read).toContain(k);
    }
    const hashed = read.slice(read.indexOf('disk.verdict === "hashed"'));
    expect(hashed.indexOf("return;")).toBeLessThan(hashed.indexOf("this.fresh();"));
  });

  it("is a button on both the bench and CODE, beside POSTER", () => {
    expect(SOURCE.match(/id: "poster"/g)?.length).toBe(2);
    expect(SOURCE.match(/id: "reader"/g)?.length).toBe(2);
  });
});
