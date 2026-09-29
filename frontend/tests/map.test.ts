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
import { Client } from "../src/net/client";
import { decode, encode } from "../src/net/codec";
import { LANDS, mapLands, nextLand, roadsOf, type Land } from "../src/net/protocol";
import type { Transport, TransportHandlers } from "../src/net/transport";

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

/**
 * TAB and the land chips walk the lands the server reported in `world.lands`
 * (PROTOCOL §4.6), not the client's own list: a client that knows ZIG, talking
 * to a server that does not, asked `world.map` for a ZIG map it could not
 * serve.
 */
describe("the map's land switcher follows world.lands", () => {
  const walk = (lands: readonly Land[], from: Land, steps: number): Land[] => {
    const seen: Land[] = [];
    let at = from;
    for (let i = 0; i < steps; i++) seen.push((at = nextLand(lands, at)));
    return seen;
  };

  it("skips the lands the server lacks, keeps LANDS' order, and wraps", () => {
    // Reported out of order and without ZIG and REMIX.
    const lands = mapLands(["lua", "typescript", "rust", "pytorch", "go", "python", "cpp"]);
    expect(lands).toEqual(["rust", "go", "cpp", "python", "pytorch", "typescript", "lua"]);
    expect(walk(lands, "rust", 7)).toEqual([
      "go",
      "cpp",
      "python",
      "pytorch",
      "typescript",
      "lua",
      "rust",
    ]);
  });

  it("falls back to every land the client knows before world.lands is heard", () => {
    expect(mapLands(null)).toEqual(LANDS);
    expect(walk(mapLands(null), "lua", 2)).toEqual(["remix", "rust"]);
  });

  it("leaves out a land the client has no art or name for", () => {
    expect(mapLands(["kotlin", "go", "rust"])).toEqual(["rust", "go"]);
  });

  it("from a land the server did not report, TAB goes to its first", () => {
    expect(nextLand(mapLands(["rust", "go"]), "zig")).toBe("rust");
    expect(nextLand([], "zig")).toBe("zig");
  });

  it("the land it reaches still has the road, or its last one", () => {
    // `switchTo`'s rule, unchanged: LUA × HACKER → REMIX lands on BASIC.
    const to = nextLand(mapLands(["lua", "remix"]), "lua");
    expect(to).toBe("remix");
    expect(roadsOf(to).includes("hacker")).toBe(false);
    expect(roadsOf(to)[roadsOf(to).length - 1]).toBe("basic");
  });

  it("the client keeps the ids of the last world.lands, and forgets them with the session", async () => {
    let handlers: TransportHandlers | null = null;
    const sent: Array<{ id: string | null; type: string }> = [];
    const storage = new Map<string, string>();
    const client = new Client({
      transport: (h) => {
        handlers = h;
        const t: Transport = {
          send: (text) => {
            const d = decode(text);
            if (d.kind === "ok") sent.push({ id: d.frame.id, type: d.frame.type });
          },
          close: () => h.onClose("test closed"),
        };
        queueMicrotask(() => h.onOpen());
        return t;
      },
      storage: {
        getItem: (k: string) => storage.get(k) ?? null,
        setItem: (k: string, v: string) => void storage.set(k, v),
        removeItem: (k: string) => void storage.delete(k),
      },
      keepalive: false,
    });
    expect(client.lands).toBeNull();
    client.connect();
    await new Promise<void>((r) => queueMicrotask(() => r()));
    client.state = "authed";
    const asked = client.request("world.lands", {});
    const frame = sent.find((f) => f.type === "world.lands")!;
    handlers!.onMessage(
      encode(frame.id, "world.lands.ok", {
        lands: [
          { land: "go", categories: [] },
          { land: "rust", categories: [] },
        ],
      }),
    );
    const res = await asked;
    expect(res.lands.map((l) => l.land)).toEqual(["go", "rust"]);
    expect(client.lands).toEqual(["go", "rust"]);
    expect(mapLands(client.lands)).toEqual(["rust", "go"]);
    client.forgetToken();
    expect(client.lands).toBeNull();
    client.close();
  });
});
