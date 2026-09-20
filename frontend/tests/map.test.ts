/**
 * The map on a phone: the overworld is the screen.
 *
 * `phoneMapLayout` is font-free — every height comes in already measured —
 * so what the phone report was about is checkable without a canvas: the plate
 * is the widest thing on the screen, the strip sits under it, and nothing
 * runs under the footer. The numbers are the ones a 390×844 iPhone produces
 * (virtual 720×1558 at a ui scale of about 1.48).
 */
import { describe, expect, it } from "vitest";
import { phoneCoinRadius, phoneMapLayout } from "../src/scenes/map";

const PORTRAIT_ART = { w: 768, h: 1152 };
const LANDSCAPE_ART = { w: 1152, h: 768 };

describe("phoneMapLayout", () => {
  const s = 1.48;
  const barBottom = 46 + 12 + 74;
  const stripH = 230;
  const footerH = 44;

  it("gives the plate the whole width less a gutter on an iPhone", () => {
    const { plate } = phoneMapLayout(720, 1558, s, barBottom, stripH, footerH, PORTRAIT_ART);
    expect(plate[2]).toBeGreaterThan(690);
    expect(plate[0]).toBeGreaterThanOrEqual(0);
    expect(plate[0] + plate[2]).toBeLessThanOrEqual(720);
    // The art's own shape, not a crop of it.
    expect(plate[3] / plate[2]).toBeCloseTo(PORTRAIT_ART.h / PORTRAIT_ART.w, 2);
  });

  it("puts the strip directly under the plate and keeps both above the footer", () => {
    const { plate, strip } = phoneMapLayout(720, 1558, s, barBottom, stripH, footerH, PORTRAIT_ART);
    expect(plate[1]).toBeGreaterThanOrEqual(barBottom);
    expect(strip[1]).toBeGreaterThanOrEqual(plate[1] + plate[3]);
    expect(strip[1] - (plate[1] + plate[3])).toBeLessThan(20);
    expect(strip[3]).toBe(stripH);
    expect(strip[1] + strip[3]).toBeLessThanOrEqual(1558 - footerH);
  });

  it("fits by height when the art is taller than the room, and centres it", () => {
    const { plate, strip } = phoneMapLayout(720, 900, s, barBottom, stripH, footerH, PORTRAIT_ART);
    expect(plate[1] + plate[3] + strip[3]).toBeLessThanOrEqual(900 - footerH);
    expect(plate[2]).toBeLessThan(720 - 12);
    expect(plate[0]).toBeGreaterThan(6);
    expect(Math.abs(plate[0] + plate[2] / 2 - 360)).toBeLessThan(1);
  });

  it("sideways, the strip stands beside the plate and the plate takes the height", () => {
    const { plate, strip } = phoneMapLayout(1558, 720, s, barBottom, 300, footerH, LANDSCAPE_ART);
    expect(plate[3] / plate[2]).toBeCloseTo(LANDSCAPE_ART.h / LANDSCAPE_ART.w, 2);
    // Beside, not below: the strip starts to the right of the plate's edge.
    expect(strip[0]).toBeGreaterThanOrEqual(plate[0] + plate[2]);
    expect(strip[0] + strip[2]).toBeLessThanOrEqual(1558);
    // The plate uses most of the height it has.
    expect(plate[3]).toBeGreaterThan((720 - footerH - barBottom) * 0.9);
    expect(plate[1] + plate[3]).toBeLessThanOrEqual(720 - footerH);
    expect(strip[1] + strip[3]).toBeLessThanOrEqual(720 - footerH);
  });

  it("never returns a plate smaller than something you can see", () => {
    const { plate } = phoneMapLayout(320, 300, 1, 200, 200, 40, PORTRAIT_ART);
    expect(plate[2]).toBeGreaterThanOrEqual(40);
    expect(plate[3]).toBeGreaterThanOrEqual(40);
  });
});

describe("phoneCoinRadius", () => {
  it("keeps neighbours at the packs' minimum spacing from overlapping", () => {
    // 0.06 of the plate apart is the closest two nodes may be (verify_pack).
    for (const plateW of [300, 500, 704, 1000]) {
      const r = phoneCoinRadius(plateW, 27);
      // A coin may just touch its closest possible neighbour, never sit on it.
      expect(r * 2).toBeLessThanOrEqual(plateW * 0.06 * 1.4);
    }
  });

  it("never grows past the design radius on a wide plate", () => {
    expect(phoneCoinRadius(4000, 27)).toBe(27);
  });

  it("never shrinks below a readable coin", () => {
    expect(phoneCoinRadius(100, 27)).toBeGreaterThanOrEqual(8);
  });
});
