/**
 * The interface and code faces a player can pick (F8, the map's FONT chip, and
 * the code-face button).
 *
 * What matters about them is what stands *behind* each one: DOS VGA has no
 * `č`, Comic Mono has no Hangul, and a face at the front of a stack with the
 * game's own two behind it is a face that can be picked in any language
 * without a single glyph going missing.
 */
import { existsSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  CODE_FACES,
  CODE_FACE_NAME,
  CODE_FACE_SCALE,
  faceFiles,
  fontStacks,
  restoreUiFace,
  setCodeFace,
  UI_FACES,
  UI_FACE_NAME,
} from "../src/engine/text";

const PUBLIC = join(__dirname, "..", "public");

afterEach(() => {
  restoreUiFace("game");
  setCodeFace("game");
});

describe("interface faces", () => {
  it("the game pair is the default and leads with Press Start 2P and VT323", () => {
    const { pixel, body } = fontStacks();
    expect(pixel.startsWith('"PressStart2P"')).toBe(true);
    expect(body.startsWith('"VT323"')).toBe(true);
  });

  it("every other face goes in front, with both game faces still behind it", () => {
    for (const face of UI_FACES.filter((f) => f !== "game")) {
      restoreUiFace(face);
      const { pixel, body } = fontStacks();
      for (const stack of [pixel, body]) {
        expect(stack.startsWith('"PressStart2P"') || stack.startsWith('"VT323"'), face).toBe(false);
        expect(stack, face).toContain('"PressStart2P"');
        expect(stack, face).toContain('"VT323"');
      }
    }
  });

  it("the code button's VT323 stays VT323 whatever the interface is", () => {
    restoreUiFace("comic");
    expect(fontStacks().code.startsWith('"VT323"')).toBe(true);
  });

  it("every face has a name for the chip", () => {
    for (const face of UI_FACES) expect(UI_FACE_NAME[face]).toMatch(/^[A-Z0-9 ]+$/);
  });
});

describe("code faces", () => {
  it("every face has a name and a size", () => {
    for (const face of CODE_FACES) {
      expect(CODE_FACE_NAME[face]).toMatch(/^[A-Z0-9 ]+$/);
      expect(CODE_FACE_SCALE[face]).toBeGreaterThan(0.5);
      expect(CODE_FACE_SCALE[face]).toBeLessThanOrEqual(1);
    }
  });

  it("each downloadable code face leads its stack, with VT323 behind it", () => {
    for (const face of CODE_FACES.filter((f) => !["game", "iosevka", "jetbrains"].includes(f))) {
      setCodeFace(face);
      const { code } = fontStacks();
      expect(code.startsWith('"VT323"'), face).toBe(false);
      expect(code, face).toContain('"VT323"');
    }
  });
});

describe("the files", () => {
  it("every downloadable face is shipped, with its licence", () => {
    for (const file of faceFiles()) {
      expect(existsSync(join(PUBLIC, file)), file).toBe(true);
    }
    for (const lic of [
      "OldschoolPC-CC-BY-SA-4.0.txt",
      "neodgm-OFL.txt",
      "Galmuri-OFL.txt",
      "ComicMono-MIT.txt",
      "CREDITS.txt",
    ]) {
      expect(existsSync(join(PUBLIC, "fonts", lic)), lic).toBe(true);
    }
  });
});
