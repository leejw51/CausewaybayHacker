/**
 * The monitor the code sits in, when the playground is an old computer
 * (`ui/computer.ts`).
 *
 * The editor's well becomes a piece of plastic: a casing in the machine's
 * colour, bevelled light at the top and dark at the bottom, a sloped bezel
 * down to the glass, and a chin with a nameplate, a power LED and whatever
 * else that monitor had on its front — vents on the Amiga's 1084, the two
 * knobs of the television an MSX was plugged into. The tube itself, with its
 * scanlines and rounded glass, is `gfx/retroscreen.ts` over the editor.
 *
 * Drawn in virtual pixels on the game canvas; returns the glass, which is
 * where the editor goes.
 */
import { roundRect, type Ctx, type Rect } from "../engine/ui";
import type { Computer } from "./computer";
import { COMPUTER_NAME, TUBE } from "./computer";

type Machine = Exclude<Computer, "normal">;

interface Casing {
  /** The plastic, its lit top edge, its shadowed bottom edge. */
  readonly body: string;
  readonly light: string;
  readonly dark: string;
  /** The slope from the casing down to the glass. */
  readonly bezel: string;
  /** The nameplate's ink, and the LED when it is on. */
  readonly plate: string;
  readonly led: string;
}

const CASING: Record<Machine, Casing> = {
  // The Monitor II: Apple beige, a green LED.
  apple2: {
    body: "#d6cba6",
    light: "#efe7cb",
    dark: "#9c916e",
    bezel: "#4a4434",
    plate: "#5b5340",
    led: "#4dff6a",
  },
  // A black portable colour television.
  msx: {
    body: "#232328",
    light: "#4a4a54",
    dark: "#0c0c10",
    bezel: "#111114",
    plate: "#c8c8d8",
    led: "#ff3a2a",
  },
  // A 1084S: cream, with a green power light.
  amiga: {
    body: "#e4dfcd",
    light: "#fbf8ec",
    dark: "#a8a290",
    bezel: "#56524a",
    plate: "#3c3a34",
    led: "#58e858",
  },
};

/** How thick the casing is round a screen of this size, in virtual pixels. */
export function monitorFrame(rect: Rect): { side: number; chin: number } {
  const side = Math.max(8, Math.round(Math.min(rect[2], rect[3]) * 0.035));
  return { side, chin: Math.round(side * 2.2) };
}

/**
 * Draw the monitor filling `rect` and return the glass inside it.
 *
 * @param t the scene clock, for the LED's flicker while a program runs
 * @param busy whether the drive light should be going
 */
export function drawMonitor(g: Ctx, rect: Rect, machine: Machine, t: number, busy: boolean): Rect {
  const [x, y, w, h] = rect;
  const c = CASING[machine];
  const { side, chin } = monitorFrame(rect);
  const r = Math.round(side * 0.9);
  g.save();
  // A shadow on the desk under it.
  g.fillStyle = "rgba(0,0,0,0.45)";
  roundRect(g, x + 3, y + 5, w, h, r);
  g.fill();
  // The casing, bevelled: light edge, dark edge, then the body.
  g.fillStyle = c.dark;
  roundRect(g, x, y, w, h, r);
  g.fill();
  g.fillStyle = c.light;
  roundRect(g, x, y, w - 2, h - 3, r);
  g.fill();
  g.fillStyle = c.body;
  roundRect(g, x + 2, y + 2, w - 4, h - 5, r - 1);
  g.fill();
  // The bezel sloping down to the glass: a frame of its own colour, lit
  // along the bottom where it faces up into the light.
  const gx = x + side;
  const gy = y + side;
  const gw = w - side * 2;
  const gh = h - side - chin;
  const lip = Math.max(3, Math.round(side * 0.45));
  g.fillStyle = c.light;
  roundRect(g, gx - lip, gy - lip + 1, gw + lip * 2, gh + lip * 2, r);
  g.fill();
  g.fillStyle = c.bezel;
  roundRect(g, gx - lip, gy - lip, gw + lip * 2, gh + lip * 2 - 1, r);
  g.fill();
  // The glass, in the tube's own dark.
  const [pr, pg, pb] = TUBE[machine].paper;
  g.fillStyle = `rgb(${Math.round(pr * 90)},${Math.round(pg * 90)},${Math.round(pb * 90)})`;
  roundRect(g, gx, gy, gw, gh, Math.round(r * 0.8));
  g.fill();

  // The chin.
  const cy = y + h - chin;
  const mid = cy + chin * 0.5;
  const plateH = Math.max(6, Math.round(chin * 0.34));
  g.font = `${plateH}px "PressStart2P", monospace`;
  g.textBaseline = "middle";
  g.fillStyle = c.plate;
  g.fillText(COMPUTER_NAME[machine], gx, mid + 1);
  // The power LED, steady; it flickers like a drive light while a run is on.
  const ledR = Math.max(2, Math.round(chin * 0.12));
  const lx = x + w - side - ledR * 2;
  const on = !busy || Math.sin(t * 40) * Math.sin(t * 13) > -0.2;
  g.fillStyle = "rgba(0,0,0,0.5)";
  g.beginPath();
  g.arc(lx, mid, ledR + 1, 0, Math.PI * 2);
  g.fill();
  g.fillStyle = on ? c.led : "#302a20";
  g.beginPath();
  g.arc(lx, mid, ledR, 0, Math.PI * 2);
  g.fill();
  if (on) {
    g.fillStyle = c.led;
    g.globalAlpha = 0.25;
    g.beginPath();
    g.arc(lx, mid, ledR * 3, 0, Math.PI * 2);
    g.fill();
    g.globalAlpha = 1;
  }
  if (machine === "msx") {
    // The television's two knobs, channel and volume.
    const kr = Math.max(3, Math.round(chin * 0.26));
    for (const k of [0, 1]) {
      const kx = lx - ledR * 4 - kr - k * (kr * 2.8);
      g.fillStyle = c.dark;
      g.beginPath();
      g.arc(kx, mid + 1, kr, 0, Math.PI * 2);
      g.fill();
      g.fillStyle = c.light;
      g.beginPath();
      g.arc(kx, mid, kr - 1, 0, Math.PI * 2);
      g.fill();
      g.fillStyle = c.dark;
      g.fillRect(kx - 1, mid - kr + 1, 2, kr);
    }
  } else {
    // Vents: a row of slots to the left of the light.
    const slotW = Math.max(2, Math.round(side * 0.25));
    const slotH = Math.round(chin * 0.4);
    const n = machine === "amiga" ? 10 : 6;
    for (let i = 0; i < n; i++) {
      const sx = lx - ledR * 4 - (i + 1) * slotW * 2;
      g.fillStyle = c.dark;
      g.fillRect(sx, mid - slotH / 2, slotW, slotH);
    }
  }
  g.restore();
  return [gx, gy, gw, gh];
}
