/**
 * The coin slot.
 *
 * Every cabinet in the era rested on a title card and waited. It did not start
 * a cutscene at you the moment the power came on, and it did not need to: the
 * card said what the game was called and told you, in two words, what to do
 * about it. This is that card.
 *
 * Three things it is built to, in the order they matter:
 *
 *   - **It waits.** The opening (`scenes/story.ts`) is two minutes of somebody
 *     else's typing, and before this screen existed it played *at* a cold boot
 *     whether anybody was there or not. Now it is asked for.
 *   - **"PRESS SPACE", and it means any key.** The words are what a 16-bit game
 *     says; the behaviour is what a person expects. Any key, any click, any
 *     tap, and there is a real button under the words so a phone has something
 *     to hit and an automated run has an id (`start`) to press.
 *   - **It does not stand between a returning player and their work.** Somebody
 *     who has already watched the opening goes straight to the login screen —
 *     the flag is remembered — and somebody with a live session never reaches
 *     this screen at all, because `boot.ts` resumes them past it.
 *
 * ## The idle hand-over, which is a deliberate compromise
 *
 * Left completely alone the screen gives up after `IDLE_OUT` seconds and hands
 * over to the login screen. That is not what a cabinet does — a cabinet plays
 * its attract loop — and the reason it is not is worth writing down rather than
 * discovering later:
 *
 *   * A screen that waits for ever cannot be driven by anything that does not
 *     know to press a key, and `e2e/fixtures.ts` boots the game and polls for
 *     the login screen. A title card with no exit is a suite that hangs.
 *   * Going to the *story* on idle instead would work, and is more faithful,
 *     but it costs the e2e budget: a cold boot reaches login in about 42 s
 *     through the opening, against a 90 s poll. Idle → story → login would be
 *     nearer 60 s and the margin is the only thing keeping that green on a
 *     loaded machine.
 *
 * So the compromise is: nobody is watching, so the cabinet does not perform —
 * it puts the login screen up, where a returning player's hands already are.
 * `STORY` on the login screen plays the opening on purpose, as it always did.
 */
import type { App, Scene } from "../app";
import { ensureFonts, printf } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { btnBox, clipped, fill, neonPrint, type Ctx, type Rect } from "../engine/ui";
import { Buttons, footer, RUST } from "../ui/chrome";
import { seconds, Tween } from "../engine/motion";
import { readPref, writePref } from "../ui/prefs";
import { LOCALES, locale, setLocale, t } from "../i18n";
import { LoginScene } from "./login";
import { StoryScene } from "./story";

/** Remembered across sessions: has this browser watched the opening? */
const SEEN_KEY = "story.seen";

export function storySeen(): boolean {
  return readPref(SEEN_KEY) === "1";
}

/**
 * Mark the opening as watched.
 *
 * Called when the story *ends* and when it is *skipped*, because both mean the
 * same thing to the player: they have had their chance at it and should not be
 * offered it again unasked. A replay from the login screen deliberately does
 * not clear the flag.
 */
export function markStorySeen(): void {
  writePref(SEEN_KEY, "1");
}

/** How long the card waits before deciding nobody is there. See the header. */
const IDLE_OUT = 15;

export class TitleScene implements Scene {
  readonly name = "title";
  readonly mood = "title" as const;

  /**
   * Two lists: the coin slot, and the language row.
   *
   * `start` is in its own because it is **drawn by hand** — the word is the
   * screen on this one card and a gold-rimmed 16-bit button around it would
   * make it furniture. `Buttons.draw` would paint a `pixBtn` straight over the
   * plate, so the list that holds it is never handed to it. Both are returned
   * from `controls()`, so an automated run still sees every control.
   */
  private readonly buttons = new Buttons();
  private readonly langs = new Buttons();
  private t = 0;
  private idle = 0;
  private leaving = false;
  private readonly logoIn = new Tween(seconds("scene"));

  constructor(private readonly app: App) {}

  enter(): void {
    this.app.chip.music("title");
    // The plate is a lazily fetched background and this is the first frame
    // anybody sees, so it is asked for here rather than on the frame that
    // first tries to draw it.
    this.app.assets?.prefetch("title_bg", this.app.layout.isPortrait());
  }

  leave(): void {
    this.app.chip.music("stop");
  }

  /**
   * Go.
   *
   * The opening if it has never been watched in this browser, the login screen
   * if it has. Guarded so a key and a click in the same frame cannot start two
   * scene changes.
   *
   * @param idle true when nothing was pressed and the card simply timed out,
   * which always means the login screen — see the header.
   */
  private start(idle = false): void {
    if (this.leaving) return;
    this.leaving = true;
    this.app.chip.select();
    const next =
      idle || storySeen() ? new LoginScene(this.app) : (new StoryScene(this.app) as Scene);
    void this.app.go(next, "forward");
  }

  key(): void {
    this.start();
  }

  controls(): Buttons[] {
    return [this.buttons, this.langs];
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): void {
    if (phase === "move") {
      this.buttons.hovered = this.buttons.hit(x, y)?.id ?? null;
      this.langs.hovered = this.langs.hit(x, y)?.id ?? null;
      return;
    }
    // Anywhere, not only on the button. The button exists so that a thumb and
    // an automated run have something specific to aim at, not to make the rest
    // of the screen dead.
    if (phase !== "down") return;
    const hit = this.langs.hit(x, y);
    if (hit) {
      // Changing language must not also start the game. It is the one control
      // on this screen that is not "go", and a press that did both would make
      // the choice impossible to make deliberately.
      this.idle = 0;
      this.app.chip.select();
      void setLocale(hit.id.slice(5) as ReturnType<typeof locale>);
      return;
    }
    this.start();
  }

  update(dt: number): void {
    this.t += dt;
    this.idle += dt;
    this.logoIn.update(dt);
    if (this.idle > IDLE_OUT) this.start(true);
  }

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    this.buttons.reset();
    this.langs.reset();

    // The establishing shot, exactly as the login screen frames it: the painted
    // plate wins outright on this screen and the generated skyline is dimmed to
    // nothing by `Mood.title`.
    const plate = this.app.assets?.picture("title_bg", layout.isPortrait());
    if (plate) {
      const scale = Math.max(layout.vw / plate.naturalWidth, layout.vh / plate.naturalHeight);
      const aw = plate.naturalWidth * scale;
      const ah = plate.naturalHeight * scale;
      clipped(g, 0, 0, layout.vw, layout.vh, () =>
        g.drawImage(plate, (layout.vw - aw) / 2, (layout.vh - ah) / 2, aw, ah),
      );
      const grad = g.createLinearGradient(0, layout.vh * 0.3, 0, layout.vh);
      grad.addColorStop(0, "rgba(20,28,72,0)");
      grad.addColorStop(1, "rgba(20,28,72,0.94)");
      g.fillStyle = grad;
      g.fillRect(0, 0, layout.vw, layout.vh);
    }

    const k = this.logoIn.out;
    const cy = Math.round(layout.vh * (layout.isPortrait() ? 0.34 : 0.36));
    g.save();
    g.globalAlpha = Math.min(1, this.logoIn.raw * 2);
    g.translate(0, (1 - k) * Math.round(22 * s));
    neonPrint(
      g,
      fonts.title,
      "CAUSEWAYBAY",
      cy - fonts.title.height,
      layout.vw,
      Theme.cyan,
      this.t,
    );
    neonPrint(
      g,
      fonts.title,
      "HACKER",
      cy + Math.round(fonts.title.height * 0.2),
      layout.vw,
      RUST,
      this.t + 0.6,
    );
    g.restore();

    // PRESS SPACE — the words a 16-bit game uses. The line under it is where
    // the screen admits that it means any of them.
    const promptY = Math.round(layout.vh * (layout.isPortrait() ? 0.63 : 0.66));
    const label = t("title.press");
    const bw = Math.min(layout.vw - Math.round(40 * s), Math.round(380 * s));
    const bh = Math.max(layout.minTouchH(), fonts.station.height + Math.round(26 * s));
    const bx = Math.round((layout.vw - bw) / 2);
    const rect: Rect = [bx, promptY, bw, bh];
    const hot = this.buttons.hovered === "start";
    // Its own plate rather than a `pixBtn`: this is the one control on the one
    // screen where the word *is* the screen, and a gold-rimmed 16-bit button
    // around it would make it furniture.
    const blink = 0.55 + 0.45 * Math.sin(this.t * 3.4);
    fill(g, Theme.ink, bx, promptY, bw, bh, hot ? 0.92 : 0.72);
    fill(g, Theme.coin, bx, promptY, bw, Math.round(2 * s), hot ? 1 : blink);
    fill(
      g,
      Theme.coin,
      bx,
      promptY + bh - Math.round(2 * s),
      bw,
      Math.round(2 * s),
      hot ? 1 : blink,
    );
    g.fillStyle = css(Theme.cream, hot ? 1 : 0.55 + 0.45 * blink);
    printf(
      g,
      fonts.station,
      label,
      bx,
      promptY + Math.round((bh - fonts.station.height) / 2),
      bw,
      "center",
    );
    this.buttons.add({ id: "start", rect, label });

    // The six languages, spelled in themselves, under the coin slot.
    //
    // F7 cycles from anywhere and is advertised in the footer, but a key
    // binding is not an answer for somebody who has just opened the game and
    // cannot read the screen it is on. A row of names in their own scripts is
    // legible to exactly the person who needs it, and it is on the first
    // screen rather than behind a settings menu that does not exist.
    const lang = LOCALES.map((l) => ({
      id: `lang:${l.id}`,
      label: l.label,
      // The one you are in is **lit**, not dimmed. `dim` is the right answer on
      // the aux strip, where the labels are big; here they are set in the
      // smallest face in the game and dim ink on a dim face at eight pixels is
      // a button with nothing legible in it — which is what a Korean player
      // saw looking for the language they were already in.
      lit: l.id === locale(),
    }));
    // Centred, and measured rather than guessed: six names in six scripts are
    // six different widths, and a row laid out from a fixed left margin sits
    // against the edge of the screen with the whole right half empty.
    const gap = Math.round(fonts.stationSm.size * 0.5);
    let total = -gap;
    for (const l of lang) {
      total += btnBox(fonts.stationSm, [l.label], 0, fonts.stationSm.size * 2)[0] + gap;
    }
    const margin = Math.round(layout.vw * 0.04);
    const rowW = Math.min(layout.vw - margin * 2, total);
    const langY = promptY + bh + Math.round(46 * s);
    this.langs.row(
      fonts.stationSm,
      [Math.round((layout.vw - rowW) / 2), langY, rowW, bh],
      lang,
      layout.minTouchH(),
    );
    this.langs.draw(g, fonts.stationSm);

    g.fillStyle = css(Theme.dim);
    printf(
      g,
      fonts.small,
      layout.touch ? t("title.tap") : t("title.anyKey"),
      0,
      promptY + bh + Math.round(10 * s),
      layout.vw,
      "center",
    );

    footer(g, layout, t("title.footer"));
  }

  resized(): void {
    /* everything on this screen is laid out from the live layout every frame */
  }
}
