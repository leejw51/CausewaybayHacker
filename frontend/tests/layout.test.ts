/**
 * The virtual canvas, at several window shapes and in both orientations.
 *
 * The trap this suite is built to avoid: in a headless DOM every element
 * reports `clientWidth === 0`, and `Layout.measure` clamps that to 1 — so every
 * "window shape" would silently be the same 1x1 case and every assertion would
 * pass without measuring anything. So each case defines the geometry
 * explicitly and asserts on concrete numbers, including one that proves the
 * canvas *grew* along the long axis instead of letterboxing.
 */
import { beforeEach, describe, expect, it } from "vitest";
import { Layout } from "../src/engine/layout";
import { Theme } from "../src/engine/theme";

function windowOf(w: number, h: number, dpr: number): void {
  Object.defineProperty(window, "innerWidth", { value: w, configurable: true });
  Object.defineProperty(window, "innerHeight", { value: h, configurable: true });
  Object.defineProperty(window, "devicePixelRatio", { value: dpr, configurable: true });
}

function canvasOf(w: number, h: number): HTMLCanvasElement {
  const c = document.createElement("canvas");
  Object.defineProperty(c, "clientWidth", { value: w, configurable: true });
  Object.defineProperty(c, "clientHeight", { value: h, configurable: true });
  c.getBoundingClientRect = () =>
    ({ left: 0, top: 0, right: w, bottom: h, width: w, height: h, x: 0, y: 0 }) as DOMRect;
  return c;
}

/** A window and a canvas that fill it, with the orientation chosen by hand. */
function pinned(mode: "landscape" | "portrait", w: number, h: number, dpr = 1): Layout {
  windowOf(w, h, dpr);
  const layout = new Layout(canvasOf(w, h));
  layout.pin(mode);
  layout.measure();
  return layout;
}

/** A window and a canvas that fill it, measured once. */
function measured(w: number, h: number, dpr = 1, touch = false): Layout {
  windowOf(w, h, dpr);
  const layout = new Layout(canvasOf(w, h), touch);
  layout.measure();
  return layout;
}

beforeEach(() => windowOf(1280, 720, 1));

describe("the virtual canvas", () => {
  it("is exactly the design size in a design-sized window", () => {
    const l = measured(1280, 720);
    expect(l.mode).toBe("landscape");
    expect([l.vw, l.vh]).toEqual([Theme.landW, Theme.landH]);
    expect(l.scale).toBe(1);
    expect([l.ox, l.oy]).toEqual([0, 0]);
    // The backing store is the window in device pixels, not the design size.
    expect([l.dw, l.dh]).toEqual([1280, 720]);
  });

  it("turns portrait when the window is taller than it is wide", () => {
    const l = measured(720, 1280);
    expect(l.mode).toBe("portrait");
    expect([l.vw, l.vh]).toEqual([Theme.portW, Theme.portH]);
  });

  it("grows along the long axis rather than letterboxing", () => {
    // A landscape layout in a tall window. Pinned, because an unpinned layout
    // would simply turn portrait — which is the other half of the same rule,
    // and is covered below.
    const l = pinned("landscape", 1280, 1400);
    expect(l.vw).toBe(Theme.landW);
    expect(l.vh).toBeGreaterThan(Theme.landH);
    expect(l.vh).toBe(Math.floor(Theme.landH * 1.5)); // the cap, 1080
    // Past the cap it does letterbox, and the bars are centred.
    expect(l.oy).toBe(Math.floor((1400 - 1080) / 2));
    expect(l.ox).toBe(0);
  });

  it("turns a tall window portrait and grows that sideways instead", () => {
    // The same 1280x1400 window, unpinned: it is taller than it is wide, so the
    // portrait design is the one that fits, and the growth is across.
    const l = measured(1280, 1400);
    expect(l.mode).toBe("portrait");
    expect(l.vw).toBe(Math.floor(Theme.portW * 1.5)); // 1080
    expect(l.vh).toBe(1400);
    expect(l.ox).toBe(Math.floor((1280 - 1080) / 2));
    expect(l.oy).toBe(0);
  });

  it("grows sideways in a very wide window, to the same 1.5x cap", () => {
    const l = measured(2400, 720);
    expect(l.vh).toBe(Theme.landH);
    expect(l.vw).toBe(Math.floor(Theme.landW * 1.5)); // 1920
    expect(l.ox).toBe(Math.floor((2400 - 1920) / 2));
  });

  it("grows the portrait canvas downwards too, so portrait is not a special case", () => {
    const l = measured(720, 1600);
    expect(l.mode).toBe("portrait");
    expect(l.vw).toBe(Theme.portW);
    expect(l.vh).toBeGreaterThan(Theme.portH);
  });

  it("snaps to an integer scale once two design canvases fit", () => {
    const l = measured(2560, 1440);
    expect(l.scale).toBe(2);
    expect([l.vw, l.vh]).toEqual([1280, 720]);
    expect([l.ox, l.oy]).toEqual([0, 0]);
  });

  it("caps the device pixel ratio at 2", () => {
    // A phone at dpr 3 would otherwise render nine times the pixels for a
    // difference nobody can see on pixel art.
    const l = measured(390, 844, 3, true);
    expect(l.dw).toBe(780);
    expect(l.dh).toBe(1688);
  });

  it("boosts type on a squeezed touch screen and leaves a desktop alone", () => {
    const phone = measured(390, 844, 3, true);
    expect(phone.mode).toBe("portrait");
    expect(phone.cssScale).toBeLessThan(0.8);
    expect(phone.touchBoost()).toBeGreaterThan(1);
    expect(phone.touchBoost()).toBeLessThanOrEqual(1.5);
    expect(phone.minTouchH()).toBeGreaterThan(0);

    const desktop = measured(640, 360, 1, false);
    expect(desktop.touchBoost()).toBe(1);
    expect(desktop.minTouchH()).toBe(0);
  });

  it("keeps a pinned orientation when the window disagrees", () => {
    windowOf(1280, 720, 1);
    const l = new Layout(canvasOf(1280, 720));
    l.measure();
    expect(l.isPortrait()).toBe(false);
    // No shape given: the choice is about the window it is made in.
    l.pin("portrait");
    l.measure();
    // The window is landscape; the player said portrait *here*, so portrait.
    expect(l.isPortrait()).toBe(true);
    expect(l.vw).toBeLessThanOrEqual(Math.floor(Theme.portW * 1.5));
    // F1 cycles landscape, portrait, automatic. Portrait is pinned, so the
    // next press is the way out — back to following the window, which here is
    // landscape — and the one after that starts the cycle again.
    expect(l.cycleOrientation()).toBe("auto");
    expect(l.isPortrait()).toBe(false);
    expect(l.cycleOrientation()).toBe("landscape");
    expect(l.isPortrait()).toBe(false);
    expect(l.cycleOrientation()).toBe("portrait");
    expect(l.isPortrait()).toBe(true);
  });

  it("cycles from automatic into a choice and back out of it", () => {
    windowOf(1080, 1730, 1);
    const l = new Layout(canvasOf(1080, 1730));
    l.measure();
    expect(l.mode).toBe("portrait");
    expect(l.cycleOrientation()).toBe("landscape");
    expect(l.mode).toBe("landscape");
    expect(l.cycleOrientation()).toBe("portrait");
    expect(l.cycleOrientation()).toBe("auto");
    expect(l.mode).toBe("portrait");
    expect(l.ox).toBe(0);
    expect(l.oy).toBe(0);
  });

  it("suspends a choice made in a window that is no longer on screen", () => {
    // The reported bug: F1 pressed once in a wide window, saved, and then
    // every later session in every window was landscape — including a browser
    // 1080 wide and 1730 tall, where the landscape layout is a band across the
    // top with 47% of the window left over.
    windowOf(1080, 1730, 1);
    const c = canvasOf(1080, 1730);
    const l = new Layout(c);
    l.pin("landscape", [1600, 900]);
    l.measure();
    expect(l.mode).toBe("portrait");
    // And the whole window is used: no bands at all.
    expect(l.ox).toBe(0);
    expect(l.oy).toBe(0);

    // Put the window back into the shape the choice was made in and it applies
    // again — suspended, not thrown away.
    windowOf(1600, 900, 1);
    Object.defineProperty(c, "clientWidth", { value: 1600, configurable: true });
    Object.defineProperty(c, "clientHeight", { value: 900, configurable: true });
    l.measure();
    expect(l.mode).toBe("landscape");
  });

  it("drops a preference that does not say which window it was made in", () => {
    // What an older build saved: a bare "landscape" with no shape. It is a
    // preference, not an instruction, and a window this decisive overrules it.
    windowOf(1080, 1730, 1);
    const l = new Layout(canvasOf(1080, 1730));
    l.pin("landscape", null);
    l.measure();
    expect(l.mode).toBe("portrait");
  });

  it("leaves a choice alone in a window that is not decisively either shape", () => {
    windowOf(1000, 1000, 1);
    const c = canvasOf(1000, 1000);
    const l = new Layout(c);
    l.pin("portrait", null);
    l.measure();
    // A square window is not an argument, so nothing overrules the choice.
    expect(l.mode).toBe("portrait");
  });

  it("follows the window until the player pins one", () => {
    windowOf(1280, 720, 1);
    const c = canvasOf(1280, 720);
    const l = new Layout(c);
    l.measure();
    expect(l.mode).toBe("landscape");
    // Rotate the phone: same canvas, new shape.
    Object.defineProperty(c, "clientWidth", { value: 720, configurable: true });
    Object.defineProperty(c, "clientHeight", { value: 1280, configurable: true });
    l.measure();
    expect(l.mode).toBe("portrait");
  });

  it("maps a pointer into virtual coordinates and back", () => {
    const l = measured(2400, 720);
    const inside = l.toVirtual(1200, 360);
    expect(inside).not.toBeNull();
    const [vx, vy] = inside!;
    const [cx, cy] = l.toClient(vx, vy);
    expect(cx).toBeCloseTo(1200, 5);
    expect(cy).toBeCloseTo(360, 5);
  });

  it("returns null for a pointer on the letterbox, not a clamped point", () => {
    const l = pinned("landscape", 1280, 1400);
    // The top 160 device pixels are bar, not game.
    expect(l.toVirtual(640, 10)).toBeNull();
    expect(l.toVirtual(640, 700)).not.toBeNull();
  });

  it("reports a change exactly once for one new shape", () => {
    windowOf(1280, 720, 1);
    const c = canvasOf(1280, 720);
    const l = new Layout(c);
    expect(l.measure()).toBe(true); // the first measurement always moves
    expect(l.measure()).toBe(false);
    Object.defineProperty(c, "clientWidth", { value: 1000, configurable: true });
    expect(l.measure()).toBe(true);
    expect(l.measure()).toBe(false);
  });

  it("scales type with the canvas, in both orientations", () => {
    // At the design size, and at an integer multiple of it, type is 1:1 —
    // doubling the scale already doubles every pixel, so boosting the font too
    // would draw a 1280-wide layout at half the content.
    expect(measured(1280, 720).uiScale()).toBeCloseTo(1, 5);
    expect(measured(2560, 1440).uiScale()).toBeCloseTo(1, 5);
    expect(measured(720, 1280).uiScale()).toBeCloseTo(1, 5);
    // Growth on one axis alone does not boost type: the scale is the *smaller*
    // of the two ratios, so a canvas that is only taller gets more room rather
    // than bigger letters.
    const taller = pinned("landscape", 1280, 1400);
    expect(taller.vh).toBeGreaterThan(Theme.landH);
    expect(taller.uiScale()).toBeCloseTo(1, 5);

    // A canvas that grew on both axes is genuinely a bigger playfield, and the
    // type grows with it rather than leaving empty panels.
    const grown = pinned("landscape", 2400, 1400);
    expect(grown.vw).toBe(Math.floor(Theme.landW * 1.5));
    expect(grown.vh).toBe(Math.floor(Theme.landH * 1.5));
    expect(grown.uiScale()).toBeCloseTo(1.5, 5);
  });
});
