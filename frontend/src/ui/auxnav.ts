/**
 * The strip that joins SEARCH, STATS and AI MODE to each other and to the maps.
 *
 * SPEC §10 lists these three as screens "reachable from the map", and F4/F5/F6
 * in `app.ts` is how they are reached from anywhere. This is the other half:
 * once you are on one of them there has to be a way to the other two and a way
 * out, drawn the same on all three, or each screen becomes a place you can only
 * leave with a function key you had to be told about.
 *
 * It is one module rather than three copies for the reason the map's own
 * switcher is one function: the row that says where else you can go is the part
 * a player learns once, and three hand-rolled versions of it drift in label,
 * order and position until they stop reading as the same control.
 */
import type { App } from "../app";
import type { Font } from "../engine/text";
import { rowsIn, type Ctx, type Rect } from "../engine/ui";
import { Buttons } from "./chrome";
import { t } from "../i18n";

export type AuxScreen = "search" | "stats" | "ai";

/** In the order they are drawn, which is the order they are learned in. */
const ROW = (): ReadonlyArray<{ id: string; label: string; screen: AuxScreen | null }> => [
  { id: "aux:search", label: t("aux.search"), screen: "search" },
  { id: "aux:stats", label: t("aux.stats"), screen: "stats" },
  { id: "aux:ai", label: t("aux.ai"), screen: "ai" },
  // Last, and named for a place rather than a direction: "BACK" from a screen
  // you reached with a function key from an unknown other screen is a promise
  // nothing here can keep.
  { id: "aux:maps", label: t("aux.allMaps"), screen: null },
];

/**
 * The key hint every one of the three screens ends its footer with.
 *
 * A function rather than a constant now the words can change: a module-level
 * string is baked at import time and would stay in whatever language the game
 * started in for the rest of the session.
 */
export const AUX_HINT = (): string => t("aux.hint");

/**
 * The three screens as another screen's button strip can carry them — the same
 * ids and the same words, without ALL MAPS, which every screen that would use
 * this already has its own way to.
 *
 * It is exported rather than retyped so that the map's strip and this row
 * cannot come to disagree about what the three things are called. `openAux`
 * takes these ids unchanged, which is the point: a caller adds the row and
 * forwards the id, and there is no second table of names anywhere.
 */
export const AUX_BAR = (): ReadonlyArray<{ id: string; label: string }> =>
  ROW()
    .filter((item) => item.screen !== null)
    .map((item) => ({ id: item.id, label: item.label }));

/**
 * Lay the row out inside `rect` and return how tall it came out.
 *
 * The button for the screen you are already on is `dim`, which in `Buttons` is
 * "shown but out of reach" — so it is drawn, it says where you are, and it
 * cannot be clicked to re-enter the screen you are looking at.
 */
export function auxRow(btns: Buttons, f: Font, rect: Rect, here: AuxScreen, minH = 0): number {
  btns.reset();
  btns.row(
    f,
    rect,
    ROW().map((item) => ({ id: item.id, label: item.label, dim: item.screen === here })),
    minH,
  );
  return auxHeight(f, rect[2], minH);
}

/** How tall `auxRow` will draw in `width`, before it is drawn. */
export function auxHeight(f: Font, width: number, minH = 0): number {
  const labels = ROW().map((item) => item.label);
  const rows = rowsIn(f, labels, width, minH);
  const one = Math.max(minH, f.height + 20);
  const gap = Math.round(f.size * 0.5);
  return rows * one + (rows - 1) * gap;
}

export function drawAux(g: Ctx, btns: Buttons, f: Font): void {
  btns.draw(g, f);
}

/**
 * Act on an id from the row. `false` means it was not one of ours.
 *
 * The scenes are imported on demand. A static import would make the three
 * screens import each other in a ring through this module, and the one that
 * happened to be loaded first would see the others as `undefined` at class
 * definition time.
 */
export async function openAux(app: App, id: string): Promise<boolean> {
  switch (id) {
    case "aux:search": {
      const { SearchScene } = await import("../scenes/search");
      await app.go(new SearchScene(app), "forward");
      return true;
    }
    case "aux:stats": {
      const { StatsScene } = await import("../scenes/stats");
      await app.go(new StatsScene(app), "forward");
      return true;
    }
    case "aux:ai": {
      const { AiScene } = await import("../scenes/ai");
      await app.go(new AiScene(app), "forward");
      return true;
    }
    case "aux:maps": {
      const { LandsScene } = await import("../scenes/lands");
      await app.go(new LandsScene(app), "back");
      return true;
    }
    default:
      return false;
  }
}
