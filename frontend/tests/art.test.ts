/**
 * The art, as bytes on disk — the one test that looks at pixels.
 *
 * ## Why this and not a screenshot
 *
 * A full-frame baseline of this game cannot work, and it is worth writing down
 * why so nobody spends another afternoon finding out. The city behind every
 * screen is a continuously animated layer driven by time accumulated since the
 * page loaded, and the number of real frames before a capture varies by tens
 * of milliseconds of network. Two captures of the identical screen, taken on
 * two loads, were measured differing in **16% of their pixels** with the
 * backdrop on and **20%** with WebGL disabled and the flat path drawing
 * instead. A tolerance wide enough to absorb that would be wide enough to
 * absorb anything worth catching, and a baseline that flaps is worse than no
 * baseline: it trains people to run `--update-snapshots` without looking.
 *
 * What *is* deterministic is the art itself. Every bug this file exists for is
 * a property of a file rather than of a frame:
 *
 *   * the four lands shipped showing the **same crab** in different hues,
 *     because the placeholders were one sprite recoloured four ways;
 *   * a sprite can lose its alpha channel in processing and arrive as a
 *     magenta rectangle, which is what `process.py`'s knockout exists to
 *     prevent and what would ship silently if it ever stopped working;
 *   * the manifest and the directory can drift, and the only thing that
 *     currently notices is `make -C love2d love-file` at packaging time —
 *     far too late, and not run by anyone writing a scene.
 *
 * None of that needs a browser, so this runs in the ordinary suite.
 */
import { describe, expect, it } from "vitest";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

/**
 * The repository root, from wherever vitest was started.
 *
 * `import.meta.url` is not a file URL under vitest's transform, so the usual
 * trick does not work here; the runner's cwd is `frontend/`, which the config
 * fixes, so one level up is the checkout.
 */
const ROOT = resolve(process.cwd(), "..");
const ART = join(ROOT, "art");
const MANIFEST = JSON.parse(readFileSync(join(ART, "manifest.json"), "utf8")) as {
  art: Array<{ name: string; file: string; w: number; h: number; box?: Record<string, number> }>;
};

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

interface Png {
  width: number;
  height: number;
  /** PNG colour type: 6 is RGBA, 2 is RGB with no alpha at all. */
  colourType: number;
  sha: string;
  bytes: number;
}

/**
 * Enough of a PNG to answer the questions above, without a decoder.
 *
 * The header is fixed-layout: the 8-byte signature, then the IHDR chunk whose
 * payload starts at byte 16 with width and height as big-endian u32 and the
 * colour type at byte 25.
 */
function readPng(file: string): Png {
  const b = readFileSync(join(ART, file));
  if (!b.subarray(0, 8).equals(PNG_MAGIC)) throw new Error(`${file} is not a PNG`);
  return {
    width: b.readUInt32BE(16),
    height: b.readUInt32BE(20),
    colourType: b[25],
    sha: createHash("sha256").update(b).digest("hex"),
    bytes: b.length,
  };
}

const LAND_MASCOTS = [
  "sprite_ferris",
  "sprite_gogo",
  "sprite_cpp",
  "sprite_python",
  "sprite_pytorch",
  "sprite_typescript",
];
const BOSSES = [
  "boss_autocomplete",
  "boss_deadlock",
  "boss_whiteboard",
  "boss_nullptr",
  "boss_race",
  "boss_segfault",
  "boss_dangling",
  "boss_linker",
  "boss_none",
  "boss_gil",
  "boss_recursion",
];
const CATEGORIES = ["basic", "advanced", "hacker"];
const LANDS = ["rust", "go", "cpp", "python", "pytorch", "typescript"];

/** Manifest entries by name, which is how every scene looks art up. */
const byName = new Map(MANIFEST.art.map((a) => [a.name, a]));

describe("the manifest and the directory agree", () => {
  it("has an entry for every land's mascot, boss, emblem and map plate", () => {
    const wanted = [
      ...LAND_MASCOTS,
      ...BOSSES,
      ...LANDS.flatMap((l) => [`map_${l}`, `map_${l}_p`]),
      ...LANDS.flatMap((l) => CATEGORIES.flatMap((c) => [`mascot_${l}_${c}`, `emblem_${l}_${c}`])),
    ];
    const missing = wanted.filter((n) => !byName.has(n));
    expect(missing).toEqual([]);
  });

  it("points every entry at a file that exists", () => {
    // The failure this catches is a manifest edited without the art landing,
    // which draws nothing and logs nothing — a blank where a sprite was.
    const missing = MANIFEST.art.filter((a) => !existsSync(join(ART, a.file))).map((a) => a.name);
    expect(missing).toEqual([]);
  });

  it("records the size the file actually is", () => {
    // A wrong `w`/`h` puts a sprite on screen at the wrong scale, and `box`
    // is measured against it, so the feet land in the wrong place too.
    const wrong: string[] = [];
    for (const a of MANIFEST.art) {
      if (!a.file.endsWith(".png")) continue;
      const png = readPng(a.file);
      if (png.width !== a.w || png.height !== a.h) {
        wrong.push(`${a.name}: manifest ${a.w}x${a.h}, file ${png.width}x${png.height}`);
      }
    }
    expect(wrong).toEqual([]);
  });
});

describe("every sprite kept its transparency", () => {
  const sprites = [...LAND_MASCOTS, ...BOSSES].filter((n) => byName.has(n));

  it("is RGBA, not flat RGB", () => {
    // `art/tools/process.py` knocks the magenta backdrop out to alpha. If that
    // ever silently stops, the sprite arrives as a solid magenta rectangle and
    // the first anyone knows is a screenshot. Colour type 6 is RGBA; 2 is RGB
    // with no alpha channel at all, which is the shape of that failure.
    const flat = sprites.filter((n) => readPng(byName.get(n)!.file).colourType !== 6);
    expect(flat).toEqual([]);
  });

  it("is small enough to have been through the pipeline", () => {
    // A 1024x1024 raw generation copied into `art/` by mistake is ~200 KB and
    // a processed 128x128 sprite is ~20 KB. This is the cheap tripwire for
    // "somebody shipped the raw file".
    for (const n of sprites) {
      const png = readPng(byName.get(n)!.file);
      expect(png.width, n).toBeLessThanOrEqual(256);
      expect(png.height, n).toBeLessThanOrEqual(256);
    }
  });
});

describe("no two things that should look different are the same file", () => {
  it("gives each land its own mascot", () => {
    // The bug: the lands shipped the same crab, hue-shifted. One distinct
    // file per land is the property that was false and is now true, and it
    // has to keep being true every time a land is added.
    const shas = LAND_MASCOTS.map((n) => readPng(byName.get(n)!.file).sha);
    expect(new Set(shas).size).toBe(LAND_MASCOTS.length);
  });

  it("gives each boss its own portrait", () => {
    const present = BOSSES.filter((n) => byName.has(n));
    const shas = present.map((n) => readPng(byName.get(n)!.file).sha);
    expect(new Set(shas).size).toBe(present.length);
  });

  it("gives each land and road its own category mascot", () => {
    const names = LANDS.flatMap((l) => CATEGORIES.map((c) => `mascot_${l}_${c}`)).filter((n) =>
      byName.has(n),
    );
    const shas = names.map((n) => readPng(byName.get(n)!.file).sha);
    expect(new Set(shas).size).toBe(names.length);
  });

  it("gives each land and road its own emblem band", () => {
    const names = LANDS.flatMap((l) => CATEGORIES.map((c) => `emblem_${l}_${c}`)).filter((n) =>
      byName.has(n),
    );
    const shas = names.map((n) => readPng(byName.get(n)!.file).sha);
    expect(new Set(shas).size).toBe(names.length);
  });
});

describe("the map plates", () => {
  it("gives every land a landscape and a portrait plate", () => {
    for (const land of LANDS) {
      expect(byName.has(`map_${land}`), `map_${land}`).toBe(true);
      expect(byName.has(`map_${land}_p`), `map_${land}_p`).toBe(true);
    }
  });

  it("keeps each orientation in the shape that orientation needs", () => {
    // A portrait plate that is wider than it is tall is a landscape plate
    // filed under the wrong name, and the map would letterbox it.
    for (const land of LANDS) {
      const wide = byName.get(`map_${land}`)!;
      const tall = byName.get(`map_${land}_p`)!;
      expect(wide.w, `map_${land}`).toBeGreaterThan(wide.h);
      expect(tall.h, `map_${land}_p`).toBeGreaterThan(tall.w);
    }
  });
});

describe("every generated asset can be made again", () => {
  it("records a prompt for each land's mascot, boss and category art", () => {
    // An asset nobody can regenerate is a liability: the set can never be
    // re-rolled for a visual change, and a lost file is lost for good. The
    // recipes live in `art/prompts.toml`, which `art/tools/gen.sh` appends to
    // before it generates, precisely so a crashed run still leaves the recipe.
    const toml = readFileSync(join(ART, "prompts.toml"), "utf8");
    const named = new Set([...toml.matchAll(/^name = "([^"]+)"$/gm)].map((m) => m[1]));
    const wanted = [
      "sprite_cpp",
      "sprite_python",
      "boss_segfault",
      "boss_dangling",
      "boss_linker",
      "boss_none",
      "boss_gil",
      "boss_recursion",
      ...["cpp", "python"].flatMap((l) =>
        CATEGORIES.flatMap((c) => [`mascot_${l}_${c}`, `emblem_${l}_${c}`]),
      ),
    ];
    expect(wanted.filter((n) => !named.has(n))).toEqual([]);
  });
});
