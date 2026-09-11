/**
 * The panel a screen shows when it has no rows — and the reason there is one.
 *
 * Three of this game's screens can legitimately have nothing to draw, for three
 * different reasons: the endpoint is specified and not built yet (§3.3's
 * `unavailable`), the player has not done anything the feature reads from, or
 * the question they asked genuinely has no answer. Every one of those is a
 * sentence worth reading, and none of them is an empty list.
 *
 * So the empty state is a *composed* thing — a headline, a paragraph and the
 * one button that does something about it — rather than a grey line of text
 * where rows would have been. An empty panel says the screen is broken; a panel
 * that says what is missing and what fills it says the screen is working and
 * you are early.
 */
import type { App } from "../app";
import { ensureFonts, printf, wrap } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { fill, type Ctx, type Rect } from "../engine/ui";

export type NoticeTone = "unbuilt" | "empty" | "fault";

export interface Notice {
  head: string;
  body: string;
  tone: NoticeTone;
}

const RULE: Record<NoticeTone, readonly [number, number, number, number]> = {
  // Gold: the city is still being built and that is a promise, not a fault.
  unbuilt: Theme.coin,
  // Cyan: nothing is wrong, there is simply nothing here yet.
  empty: Theme.cyan,
  // Red is reserved for something that actually broke.
  fault: Theme.red,
};

/**
 * Draw a notice centred in `rect` and return the y the caller may carry on at.
 *
 * It paints a band down the left edge in the tone's colour rather than tinting
 * the text: the three tones have to be told apart at a glance and by somebody
 * who cannot tell gold from cyan, so the band also changes what the headline
 * *says* — no colour carries meaning on its own anywhere in this game.
 */
export function drawNotice(g: Ctx, app: App, rect: Rect, n: Notice): number {
  const s = app.layout.uiScale();
  const fonts = ensureFonts(s);
  const [x, y, w, h] = rect;
  const pad = Math.round(14 * s);
  const inner = w - pad * 2 - Math.round(6 * s);
  const headLines = wrap(fonts.station, n.head, inner).length;
  const bodyLines = wrap(fonts.small, n.body, inner).length;
  const boxH = Math.min(
    h,
    pad * 2 +
      headLines * fonts.station.height +
      Math.round(10 * s) +
      bodyLines * fonts.small.height,
  );
  // Centred in what is left of the panel rather than pinned to the top: the
  // notice *is* the content when it is on screen, and content that hugs the
  // top of an otherwise empty box reads as the first row of a list that failed
  // to load.
  const by = y + Math.max(0, Math.round((h - boxH) / 2));
  fill(g, Theme.ink, x, by, w, boxH, 0.5);
  fill(g, RULE[n.tone], x, by, Math.round(4 * s), boxH);
  g.fillStyle = css(RULE[n.tone]);
  printf(g, fonts.station, n.head, x + pad, by + pad, inner, "left");
  g.fillStyle = css(Theme.cream, 0.85);
  printf(
    g,
    fonts.small,
    n.body,
    x + pad,
    by + pad + headLines * fonts.station.height + Math.round(10 * s),
    inner,
    "left",
  );
  return by + boxH;
}
