import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { questSteps } from "../src/scenes/quest";
import { CAT_ICON } from "../src/scenes/lands";
import { CATEGORIES } from "../src/net/protocol";
import { en } from "../src/i18n/en";
import { ko } from "../src/i18n/ko";
import { ja } from "../src/i18n/ja";
import { zh } from "../src/i18n/zh";
import { yue } from "../src/i18n/yue";
import { cs } from "../src/i18n/cs";

/**
 * The whole-game redesign: the quest's step tracker, the level tiles' Grok
 * icons and the art they need, the words every locale must carry, and the
 * LÖVE client staying gone.
 */
const ROOT = resolve(__dirname, "../..");
const manifest = JSON.parse(readFileSync(resolve(ROOT, "art/manifest.json"), "utf8")) as {
  art: Array<{ name: string }>;
};
const inManifest = new Set(manifest.art.map((a) => a.name));

describe("the quest's step tracker", () => {
  it("is BRIEF, PICK, WRITE, SUBMIT on a quest with a quiz, and starts on PICK", () => {
    expect(questSteps(true, false, false, false)).toEqual({
      steps: ["brief", "pick", "write", "submit"],
      at: 1,
    });
  });

  it("moves to WRITE once the right line is picked, and to SUBMIT while a run is out", () => {
    expect(questSteps(true, false, true, false).at).toBe(2);
    expect(questSteps(true, false, true, true).at).toBe(3);
  });

  it("has no WRITE on a cheatsheet, where the pick is the answer", () => {
    expect(questSteps(true, true, false, false)).toEqual({
      steps: ["brief", "pick", "submit"],
      at: 1,
    });
  });

  it("has no PICK on a quest without a quiz", () => {
    expect(questSteps(false, false, false, false)).toEqual({
      steps: ["brief", "write", "submit"],
      at: 1,
    });
  });
});

describe("the level tiles' icons", () => {
  it("name an icon for every category, and every icon is in the art", () => {
    for (const c of CATEGORIES) {
      const icon = CAT_ICON[c];
      expect(icon, `no icon for ${c}`).toBeTruthy();
      expect(inManifest.has(icon!), `${icon} is not in art/manifest.json`).toBe(true);
      expect(existsSync(resolve(ROOT, `art/${icon}.png`)), `art/${icon}.png`).toBe(true);
    }
  });
});

describe("the redesign's new art", () => {
  const NEW = [
    "ui_badge",
    "cat_cheatsheet",
    "cat_verybasic",
    "cat_basic",
    "cat_advanced",
    "cat_hacker",
    "cat_frameworks",
    "step_brief",
    "step_pick",
    "step_write",
    "step_submit",
    "stat_xp",
    "stat_mistake",
    "bg_victory",
  ];
  it("is in the manifest, on disk, and has its prompt recorded", () => {
    const prompts = readFileSync(resolve(ROOT, "art/prompts.toml"), "utf8");
    for (const name of NEW) {
      expect(inManifest.has(name), `${name} in manifest`).toBe(true);
      const ext = name.startsWith("bg_") ? "jpg" : "png";
      expect(existsSync(resolve(ROOT, `art/${name}.${ext}`)), `art/${name}.${ext}`).toBe(true);
      expect(prompts.includes(`name = "${name}"`), `${name} prompt`).toBe(true);
    }
  });
});

describe("the redesign's words", () => {
  const KEYS = [
    "title.tagline",
    "quest.stepBrief",
    "quest.stepPick",
    "quest.stepWrite",
    "quest.stepSubmit",
  ] as const;
  it("are in every locale", () => {
    for (const [name, cat] of Object.entries({ en, ko, ja, zh, yue, cs })) {
      for (const k of KEYS) {
        const v = (cat as Record<string, string>)[k];
        expect(v, `${name} ${k}`).toBeTruthy();
      }
    }
  });
});

describe("the LÖVE client", () => {
  it("is gone, and nothing builds, tests or ships it", () => {
    expect(existsSync(resolve(ROOT, "love2d"))).toBe(false);
    for (const f of ["Makefile", ".github/workflows/ci.yml", ".github/workflows/release.yml"]) {
      const text = readFileSync(resolve(ROOT, f), "utf8");
      expect(text.includes("love2d"), `${f} mentions love2d`).toBe(false);
    }
  });
});
