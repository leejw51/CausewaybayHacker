/**
 * Which old computer the playground is pretending to be.
 *
 * A second axis beside the light/dark paper (`ui/codetheme.ts`), and a
 * playground-only one: the quest screen is where somebody is being tested,
 * and a Guru Meditation over a failed quest would be a joke at their expense.
 * The scratchpad is where breaking things is the point, so the machine gets
 * to have opinions about it.
 *
 * Each machine is four things at once:
 *
 *   * **the paper** — `style.css` keys the editor's colours off
 *     `<html data-computer>`, which only the playground sets;
 *   * **the face** — the three home-computer faces `engine/text.ts` already
 *     ships (PR Number 3, MSX1, Topaz), picked with the machine;
 *   * **the tube** — `gfx/retroscreen.ts`, a three.js pass over the editor in
 *     the spirit of cool-retro-term: scanlines, mask, bloom on the boot
 *     screen, a power-on that opens from a line;
 *   * **the room** — `bg_playground_<machine>`, Grok-drawn.
 *
 * "normal" is the game as it was: no attribute, no tube, the face left alone.
 */
import type { CodeFace } from "../engine/text";

export const COMPUTERS = ["normal", "apple2", "msx", "amiga"] as const;
export type Computer = (typeof COMPUTERS)[number];

export const COMPUTER_KEY = "pg.computer";

/** Its own name on the button, like the code faces. "normal" is translated. */
export const COMPUTER_NAME: Record<Exclude<Computer, "normal">, string> = {
  apple2: "APPLE ][",
  msx: "MSX",
  amiga: "AMIGA",
};

/** The face each machine sets the code in. */
export const COMPUTER_FACE: Record<Exclude<Computer, "normal">, CodeFace> = {
  apple2: "apple2",
  msx: "msx",
  amiga: "amiga",
};

let computer: Computer = "normal";
/** Whether the attribute is on the page: only while the playground is. */
let shown = false;

export function getComputer(): Computer {
  return computer;
}

export function setComputer(next: Computer): void {
  computer = next;
  if (shown) apply();
}

export function nextComputer(): Computer {
  return COMPUTERS[(COMPUTERS.indexOf(computer) + 1) % COMPUTERS.length];
}

/** The playground is open: let the stylesheet see the machine. */
export function showComputer(on: boolean): void {
  shown = on;
  apply();
}

function apply(): void {
  try {
    const root = document.documentElement;
    if (shown && computer !== "normal") root.dataset.computer = computer;
    else delete root.dataset.computer;
  } catch {
    /* no document in a unit test */
  }
}

/**
 * How each tube looks. Colours are 0..1 RGB; the rest are strengths the
 * shader multiplies by, tuned by eye against cool-retro-term's presets
 * ("Apple ][", "IBM VGA 8x16", "Commodore PET" and friends).
 */
export interface Tube {
  /** The screen with nothing on it, and the ink drawn on it. */
  readonly paper: readonly [number, number, number];
  readonly ink: readonly [number, number, number];
  /** Text cells across the boot screen. */
  readonly cols: number;
  /** How dark the gaps between scanlines are, and how far apart (CSS px). */
  readonly scan: number;
  readonly scanPx: number;
  /** Aperture-grille strength: the RGB stripes of a colour tube. */
  readonly mask: number;
  /** Bloom on the boot screen: how much of the blurred copy is added back. */
  readonly bloom: number;
  /** Barrel curvature of the boot screen, and the rounded glass corners. */
  readonly curve: number;
  /** Grain, and the slow bright bar rolling down. */
  readonly noise: number;
  readonly roll: number;
  /** Red/blue fringing on the boot screen, in boot-screen pixels. */
  readonly fringe: number;
}

export const TUBE: Record<Exclude<Computer, "normal">, Tube> = {
  // A green P1 phosphor monochrome monitor: heavy lines, lots of glow, no mask.
  apple2: {
    paper: [0.02, 0.05, 0.03],
    ink: [0.25, 1.0, 0.45],
    cols: 40,
    scan: 0.14,
    scanPx: 3,
    mask: 0,
    bloom: 1.1,
    curve: 0.18,
    noise: 0.06,
    roll: 0.07,
    fringe: 0,
  },
  // A colour television on the RF lead: softer lines, a shadow mask, fringing.
  msx: {
    paper: [84 / 255, 85 / 255, 237 / 255],
    ink: [1, 1, 1],
    cols: 40,
    scan: 0.2,
    scanPx: 3,
    mask: 0.12,
    bloom: 0.55,
    curve: 0.14,
    noise: 0.08,
    roll: 0.05,
    fringe: 0.6,
  },
  // A 1084S: sharp, interlaced PAL, Workbench blue.
  amiga: {
    paper: [0, 85 / 255, 170 / 255],
    ink: [1, 1, 1],
    cols: 64,
    scan: 0.10,
    scanPx: 2,
    mask: 0.04,
    bloom: 0.45,
    curve: 0.1,
    noise: 0.04,
    roll: 0.04,
    fringe: 0.3,
  },
};

/** How a run ended, as each machine would have said so. */
export type Outcome = "compile_error" | "runtime_error" | "timeout" | "output_limit";

export const SAYS: Record<Exclude<Computer, "normal">, Record<Outcome, string[]>> = {
  apple2: {
    compile_error: ["?SYNTAX ERROR"],
    runtime_error: ["?ILLEGAL QUANTITY ERROR"],
    timeout: ["BREAK IN 10"],
    output_limit: ["?OUT OF MEMORY ERROR"],
  },
  msx: {
    compile_error: ["Syntax error in 10"],
    runtime_error: ["Illegal function call in 10"],
    timeout: ["Break in 10"],
    output_limit: ["Out of memory"],
  },
  amiga: {
    compile_error: [
      "Software Failure.    Press left mouse button to continue.",
      "Guru Meditation #00000004.0000AAC0",
    ],
    runtime_error: [
      "Software Failure.    Press left mouse button to continue.",
      "Guru Meditation #00000003.00C0FFEE",
    ],
    timeout: [
      "Software Failure.    Press left mouse button to continue.",
      "Guru Meditation #00000009.0000DEAD",
    ],
    output_limit: [
      "Not enough memory.    Press left mouse button to continue.",
      "Guru Meditation #81000005.0000BEEF",
    ],
  },
};

/** Actual compiler output, retaining machine-specific messages for other failures. */
export function runMessage(
  machine: Exclude<Computer, "normal">,
  run: import("../net/protocol").PlaygroundRun,
): string[] {
  if (run.outcome === "ok") return [];
  if (run.outcome !== "compile_error") return SAYS[machine][run.outcome];
  const message =
    run.stderr.trim() ||
    run.diagnostics
      .map(
        (d) =>
          `${d.kind}${d.code ? " " + d.code : ""}${d.line === null ? "" : ` (${d.line}${d.col === null ? "" : ":" + d.col})`}: ${d.message}`,
      )
      .join("\n");
  return (message || "Compilation failed (no compiler message returned).")
    .replace(/\x1b\[[0-9;]*m/g, "")
    .replace(/\r/g, "")
    .replace(/\t/g, "    ")
    .split("\n");
}
