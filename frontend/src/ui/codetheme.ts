/**
 * Light or dark paper under the code.
 *
 * One preference, shared by the quest screen and the playground for the same
 * reason the code face is: it is a fact about the person, not about which
 * screen they are on. Dark is the default — it is the game's own night — and
 * light is for a bright room, or for eyes that read dark-on-light better.
 *
 * Only the code pane changes. The rest of the screen is the game, drawn in
 * the game's palette, and a light editor in a dark game is the same thing
 * every IDE with a light theme looks like inside a dark window manager.
 *
 * The editor is a DOM element, so it follows through one attribute on the
 * root that `style.css` keys its colours off; the canvas half is the well the
 * editor sits in, which asks `codeWellFace` for its colour.
 */
import type { RGBA } from "../engine/theme";

export const CODE_THEMES = ["dark", "light"] as const;
export type CodeTheme = (typeof CODE_THEMES)[number];

export const CODE_THEME_KEY = "code.theme";

let theme: CodeTheme = "dark";

export function getCodeTheme(): CodeTheme {
  return theme;
}

export function setCodeTheme(next: CodeTheme): void {
  theme = next;
  try {
    document.documentElement.dataset.codeTheme = next;
  } catch {
    /* no document in a unit test */
  }
}

/** The other one: there are two, and the button flips between them. */
export function nextCodeTheme(): CodeTheme {
  return CODE_THEMES[(CODE_THEMES.indexOf(theme) + 1) % CODE_THEMES.length];
}

/**
 * The face of the well under the code. Dark is the well's own default; light
 * is the cream the light editor is set on, so the four pixels of well round
 * the editor are not a dark rim inside a light page.
 */
export function codeWellFace(): RGBA | undefined {
  return theme === "light" ? [0.988, 0.957, 0.878, 0.98] : undefined;
}
