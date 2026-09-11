/**
 * Boot: fonts, art, socket, and the one question worth asking at startup —
 * is there a session already?
 *
 * SPEC §3.3: `auth.resume` trades a stored token for a live connection without
 * the key material being touched again. That is the whole reason the browser
 * can forget the mnemonic on reload and still put the player back on their map.
 */
import type { App, Scene } from "../app";
import { Assets } from "../engine/assets";
import { ensureFonts, printf, remeasure } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { neonPrint, type Ctx } from "../engine/ui";
import { LandsScene } from "./lands";
import { LoginScene } from "./login";

export class BootScene implements Scene {
  readonly name = "boot";
  readonly mood = "title" as const;
  private t = 0;
  private step = "waking up";

  constructor(private readonly app: App) {}

  async enter(): Promise<void> {
    this.step = "loading the art";
    try {
      // Both fonts must be resident before anything is measured, or every
      // panel is sized against the fallback and then jumps when they land.
      await Promise.all([
        document.fonts.load('16px "PressStart2P"'),
        document.fonts.load('16px "VT323"'),
      ]);
      remeasure();
    } catch {
      /* a browser without the Font Loading API still renders, just later */
    }
    try {
      this.app.assets = await Assets.load("art");
      // The title plate is the first thing anybody sees and it is a lazily
      // fetched background, so it is asked for here rather than on the frame
      // the login screen first tries to draw it.
      this.app.assets.prefetch("title_bg", this.app.layout.isPortrait());
    } catch {
      this.app.say("the art did not load — carrying on without it");
    }

    this.step = "reaching the server";
    this.app.client.connect();
    try {
      await this.app.client.waitFor("open");
    } catch {
      this.app.say("no server — check that it is running on :5390");
      return void this.app.go(new LoginScene(this.app), "none");
    }

    const token = this.app.client.token;
    if (token) {
      this.step = "resuming your session";
      try {
        const user = await this.app.client.resume(token);
        this.app.addressLabel = user.address;
        return void this.app.go(new LandsScene(this.app), "forward");
      } catch {
        // A dead token is not an error worth a banner: the login screen is
        // exactly what the player would do about it anyway.
        this.app.client.forgetToken();
      }
    }
    void this.app.go(new LoginScene(this.app), "none");
  }

  update(dt: number): void {
    this.t += dt;
  }

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    const s = layout.uiScale();
    const f = ensureFonts(s);

    // A scanline wash, so the boot screen is not a flat rectangle while the
    // fonts and the socket are still on their way.
    g.fillStyle = css(Theme.navy, 0.5);
    for (let y = ((this.t * 40) % 4) - 4; y < layout.vh; y += 4) g.fillRect(0, y, layout.vw, 1);

    const cy = Math.round(layout.vh * 0.4);
    neonPrint(g, f.title, "CAUSEWAYBAY", cy - f.title.height, layout.vw, Theme.cyan, this.t);
    neonPrint(
      g,
      f.title,
      "HACKER",
      cy + Math.round(f.title.height * 0.2),
      layout.vw,
      [0.95, 0.47, 0.16, 1],
      this.t + 0.6,
    );

    g.fillStyle = css(Theme.coin, 0.6 + 0.4 * Math.sin(this.t * 4));
    printf(
      g,
      f.stationSm,
      this.step.toUpperCase(),
      0,
      Math.round(layout.vh * 0.72),
      layout.vw,
      "center",
    );
  }
}
