/**
 * Login: the only screen that touches key material, and the only one that has
 * to be careful about it.
 *
 * What happens here, in order (SPEC §3.1–§3.2):
 *
 *   1. the player types or pastes a mnemonic or a `0x` private key;
 *   2. `wallet.unlock` derives `m/44'/60'/0'/0/0` locally and keeps the key in
 *      a module variable this scene never sees;
 *   3. `auth.challenge` with the address gets back the exact string to sign;
 *   4. that string — **the server's, verbatim, not one rebuilt from the
 *      §3.2 template** — is signed and sent as `auth.login`.
 *
 * Step 4 is the one that bites: a client that reconstructs the message passes
 * against a mock that formats it the same way and fails against a real server
 * over one space. So the text is never parsed, only signed.
 *
 * The field itself is a DOM textarea, because twelve words arrive by paste and
 * a canvas cannot take a paste. It is `autocomplete="off"`, never read except
 * on submit, and cleared the moment the derivation succeeds.
 */
import type { App, Scene } from "../app";
import { ensureFonts, printf, wrap } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { fill, neonPrint, well, type Ctx, type Rect } from "../engine/ui";
import { Buttons, footer, header, RUST, titledPanel } from "../ui/chrome";
import { seconds, Tween } from "../engine/motion";
import { Overlay } from "../ui/overlay";
import { WireError } from "../net/client";
import { playerText } from "../net/protocol";
import {
  addressFromMnemonic,
  addressFromPrivateKeyHex,
  current,
  signMessage,
  unlock,
} from "../wallet/wallet";
import { LandsScene } from "./lands";

export class LoginScene implements Scene {
  readonly name = "login";
  readonly mood = "title" as const;
  private readonly field: HTMLTextAreaElement;
  private readonly overlay: Overlay;
  private readonly buttons = new Buttons();
  private fieldRect: Rect = [0, 0, 0, 0];
  private preview = "";
  private status = "";
  private busy = false;
  private t = 0;
  private readonly leftIn = new Tween(seconds("panel"));
  private readonly rightIn = new Tween(seconds("panel"), seconds("stagger"));

  constructor(private readonly app: App) {
    const el = document.createElement("textarea");
    el.className = "cwb-field";
    el.spellcheck = false;
    el.autocapitalize = "off";
    el.autocomplete = "off";
    el.setAttribute("autocorrect", "off");
    el.placeholder = "twelve words, or 0x + 64 hex";
    // The preview is derived on every keystroke so the player sees the address
    // they are about to become before committing to it. It never leaves here.
    el.addEventListener("input", () => this.derivePreview());
    this.field = el;
    this.overlay = new Overlay(app.overlay, app.layout, el);
  }

  enter(): void {
    // After a logout there is nothing held, which is the point — the field is
    // empty, the preview is empty, and the previous wallet is not on screen.
    const held = current();
    if (held) this.preview = held.eip55;
    if (this.app.loggedOutNotice) {
      this.status = this.app.loggedOutNotice;
      this.app.loggedOutNotice = "";
    }
    queueMicrotask(() => this.field.focus());
  }

  leave(): void {
    // Whatever is in the box is key material. It does not outlive the screen.
    this.field.value = "";
    this.overlay.destroy();
  }

  private derivePreview(): void {
    const text = this.field.value.trim();
    this.status = "";
    if (!text) {
      this.preview = "";
      return;
    }
    try {
      this.preview = /^0x[0-9a-fA-F]{64}$/.test(text)
        ? addressFromPrivateKeyHex(text).eip55
        : addressFromMnemonic(text).eip55;
    } catch {
      // Half a phrase is not an error worth shouting about; it is just not an
      // address yet.
      this.preview = "";
    }
  }

  private async submit(): Promise<void> {
    if (this.busy) return;
    const text = this.field.value.trim();
    if (!text) {
      this.status = "type a seed phrase first";
      return;
    }
    this.busy = true;
    this.status = "deriving";
    try {
      const address = unlock(text);
      // The textarea is emptied before a single byte goes near the socket.
      this.field.value = "";
      this.preview = address.eip55;

      this.status = "asking for a challenge";
      const challenge = await this.app.client.challenge(address.eip55);

      this.status = "signing";
      const signature = signMessage(challenge.message);

      this.status = "logging in";
      const user = await this.app.client.login(address.eip55, signature);
      this.app.addressLabel = user.address;
      this.app.chip.start();
      await this.app.go(new LandsScene(this.app), "forward");
    } catch (e) {
      // §3.3: the server's `message` is for a developer. The player gets our
      // wording, keyed off the code; the server's line goes to the console
      // where a developer can actually find it.
      if (e instanceof WireError) {
        console.warn("auth failed:", e.payload.code, e.payload.message, e.payload.detail);
        this.status = playerText(e.payload.code);
        // §3.3's table: a spent or expired nonce is retryable as-is, and
        // saying "log in again" about it would be a lie.
        if (e.action === "rechallenge") this.status += " — press ENTER";
      } else {
        this.status = e instanceof Error ? e.message : "that did not work";
      }
      this.app.chip.fail();
    } finally {
      this.busy = false;
    }
  }

  pointer(x: number, y: number, phase: "down" | "move" | "up"): void {
    if (phase === "move") {
      this.buttons.hovered = this.buttons.hit(x, y)?.id ?? null;
      return;
    }
    if (phase !== "down") return;
    const hit = this.buttons.hit(x, y);
    if (!hit) return;
    this.app.chip.select();
    if (hit.id === "enter") void this.submit();
    if (hit.id === "clear") {
      this.field.value = "";
      this.preview = "";
      this.field.focus();
    }
  }

  /**
   * Enter submits — from the canvas, or from the field held with Ctrl/Cmd,
   * which is the only kind of keystroke `App` forwards out of the overlay. A
   * bare Enter inside the field still inserts a newline, and that is deliberate:
   * a phrase pasted across two lines should not fire a login halfway through.
   */
  key(name: string, ev: KeyboardEvent): void {
    if (name === "return" || name === "kpenter") {
      ev.preventDefault();
      void this.submit();
    }
  }

  update(dt: number): void {
    this.t += dt;
    this.leftIn.update(dt);
    this.rightIn.update(dt);
  }

  resized(): void {
    /* the overlay is repositioned every frame from the current layout */
  }

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    // With the city behind, the flat title art is redundant — it is only
    // drawn where WebGL could not start, so the screen is never bare.
    if (!this.app.backdrop) {
      const bg = this.app.assets?.picture("title_bg", layout.isPortrait());
      if (bg) {
        g.globalAlpha = 0.45;
        g.drawImage(bg, 0, 0, layout.vw, layout.vh);
        g.globalAlpha = 1;
        fill(g, Theme.void, 0, 0, layout.vw, layout.vh, 0.35);
      }
    }

    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    header(g, this.app, "LOGIN");
    this.buttons.reset();

    // One centred column, not two boxes edge to edge. The skyline is the
    // thing this screen is about — a wallet address is not a welcome — so the
    // furniture is kept narrow and the city is left room above and below it.
    const colW = Math.min(layout.vw - Math.round(32 * s), Math.round(560 * s));
    const colX = Math.round((layout.vw - colW) / 2);
    const top = Math.round(38 * s);
    const bottom = layout.vh - Math.round(26 * s);

    // The title, set over the harbour rather than inside a box.
    const titleY = top + Math.round((layout.isPortrait() ? 74 : 42) * s);
    const rise = (1 - this.leftIn.out) * Math.round(24 * s);
    g.save();
    g.globalAlpha = Math.min(1, this.leftIn.raw * 2);
    neonPrint(g, fonts.title, "CAUSEWAYBAY", titleY - rise, layout.vw, Theme.cyan, this.t);
    neonPrint(
      g,
      fonts.title,
      "HACKER",
      titleY + Math.round(fonts.title.height * 1.05) - rise,
      layout.vw,
      RUST,
      this.t + 0.6,
    );
    g.restore();

    const cardY = titleY + Math.round(fonts.title.height * 2.5);
    const cardH = Math.round((layout.isPortrait() ? 250 : 214) * s);
    const drop = (1 - this.rightIn.out) * Math.round(46 * s);
    g.save();
    g.globalAlpha = Math.min(1, this.rightIn.raw * 2.2);
    g.translate(0, drop);

    const card = titledPanel(g, [colX, cardY, colW, cardH], "SEED PHRASE OR PRIVATE KEY", RUST);
    const fieldH = Math.max(fonts.small.height * 3, Math.round(cardH * 0.34));
    well(g, card[0], card[1], card[2], fieldH);
    this.fieldRect = [card[0] + 4, card[1] + 4, card[2] - 8, fieldH - 8];
    // The textarea is a DOM element and knows nothing about the canvas
    // transform, so it waits for the card to land rather than hanging in the
    // air while the panel drops underneath it.
    if (this.rightIn.finished) this.overlay.place(this.fieldRect, fonts.small.size);
    else this.overlay.hide();

    let y = card[1] + fieldH + Math.round(8 * s);
    g.fillStyle = css(Theme.cyan);
    printf(g, fonts.stationSm, "YOU WILL BE", card[0], y, card[2], "left");
    y += fonts.stationSm.height + Math.round(4 * s);
    g.fillStyle = css(this.preview ? Theme.coin : Theme.dim);
    printf(g, fonts.small, this.preview || "—", card[0], y, card[2], "left");
    y += fonts.small.height + Math.round(8 * s);

    this.buttons.row(
      fonts.button,
      [card[0], y, card[2], card[3]],
      [
        { id: "enter", label: this.busy ? "…" : "ENTER", dim: this.busy },
        { id: "clear", label: "CLEAR" },
      ],
      layout.minTouchH(),
    );
    this.buttons.draw(g, fonts.button);
    g.restore();

    if (this.status) {
      g.fillStyle = css(this.busy ? Theme.cyan : Theme.red);
      printf(g, fonts.small, this.status, colX, cardY + cardH + Math.round(6 * s), colW, "center");
    }

    // Supporting copy, not a second panel: it is read once, and giving it
    // chrome of its own would make it compete with the thing you have to do.
    const noteY = cardY + cardH + Math.round(30 * s);
    if (noteY < bottom - fonts.small.height * 3) {
      // A scrim, because the city behind is busy exactly where this sits and
      // supporting copy that has to be fought for is not supporting anything.
      const lines = wrap(
        fonts.small,
        "Your phrase becomes a key here, in this tab, on m/44'/60'/0'/0/0 — the path" +
          " CausewaybayWallet uses, so one phrase is one you in both. It is never sent:" +
          " the server asks you to sign a line of text and works out who you are from the" +
          " signature. Only the session token is kept.",
        colW,
      ).length;
      fill(
        g,
        Theme.void,
        colX - Math.round(12 * s),
        noteY - Math.round(10 * s),
        colW + Math.round(24 * s),
        lines * fonts.small.height + Math.round(20 * s),
        0.78,
      );
      g.globalAlpha = 0.86;
      g.fillStyle = css(Theme.cream);
      printf(
        g,
        fonts.small,
        "Your phrase becomes a key here, in this tab, on m/44'/60'/0'/0/0 — the path" +
          " CausewaybayWallet uses, so one phrase is one you in both. It is never sent:" +
          " the server asks you to sign a line of text and works out who you are from the" +
          " signature. Only the session token is kept.",
        colX,
        noteY,
        colW,
        "center",
      );
      g.globalAlpha = 1;
    }

    footer(g, layout, "ENTER  LOG IN      F1  ORIENTATION      CTRL+ENTER  SUBMIT");
  }
}
