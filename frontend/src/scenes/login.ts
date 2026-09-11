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
import { ensureFonts, printf } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { fill, well, type Ctx, type Rect } from "../engine/ui";
import { Buttons, footer, frame, header, RUST, titledPanel } from "../ui/chrome";
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
  private readonly field: HTMLTextAreaElement;
  private readonly overlay: Overlay;
  private readonly buttons = new Buttons();
  private fieldRect: Rect = [0, 0, 0, 0];
  private preview = "";
  private status = "";
  private busy = false;
  private t = 0;

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
    const held = current();
    if (held) this.preview = held.eip55;
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
      await this.app.go(new LandsScene(this.app));
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
  }

  resized(): void {
    /* the overlay is repositioned every frame from the current layout */
  }

  draw(g: Ctx): void {
    const { layout } = this.app;
    this.app.clear(g, Theme.void);
    const bg = this.app.assets?.picture("title_bg", layout.isPortrait());
    if (bg) {
      g.globalAlpha = 0.45;
      g.drawImage(bg, 0, 0, layout.vw, layout.vh);
      g.globalAlpha = 1;
      fill(g, Theme.void, 0, 0, layout.vw, layout.vh, 0.35);
    }

    header(g, layout, "LOGIN", this.app.client.state.toUpperCase());
    const f = frame(layout, layout.isPortrait() ? 0.55 : 0.52);
    const s = f.scale;
    const fonts = ensureFonts(s);

    // Left: the field. Right: what the key material is for, and what it is not.
    const left = titledPanel(g, f.left, "SEED PHRASE OR PRIVATE KEY", RUST);
    const lineH = fonts.small.height;
    const fieldH = Math.max(lineH * 3, Math.round(f.left[3] * 0.34));
    well(g, left[0], left[1], left[2], fieldH);
    this.fieldRect = [left[0] + 4, left[1] + 4, left[2] - 8, fieldH - 8];
    this.overlay.place(this.fieldRect, fonts.small.size);

    let y = left[1] + fieldH + Math.round(8 * s);
    g.fillStyle = css(Theme.cyan);
    printf(g, fonts.stationSm, "YOU WILL BE", left[0], y, left[2], "left");
    y += fonts.stationSm.height + Math.round(4 * s);
    g.fillStyle = css(this.preview ? Theme.coin : Theme.dim);
    printf(g, fonts.small, this.preview || "—", left[0], y, left[2], "left");
    y += fonts.small.height + Math.round(10 * s);

    this.buttons.reset();
    this.buttons.row(
      fonts.button,
      [left[0], y, left[2], left[3]],
      [
        { id: "enter", label: this.busy ? "…" : "ENTER", dim: this.busy },
        { id: "clear", label: "CLEAR" },
      ],
      layout.minTouchH(),
    );
    this.buttons.draw(g, fonts.button);

    if (this.status) {
      g.fillStyle = css(this.busy ? Theme.cyan : Theme.red);
      printf(
        g,
        fonts.small,
        this.status,
        left[0],
        left[1] + left[3] - fonts.small.height,
        left[2],
        "left",
      );
    }

    const right = titledPanel(g, f.right, "WHAT HAPPENS TO IT", Theme.cyan);
    g.fillStyle = css(Theme.cream);
    printf(
      g,
      fonts.small,
      // Written as paragraphs, not as pre-broken lines: the panel is a
      // different width in portrait and `printf` wraps to whatever it gets.
      [
        "Your phrase is turned into a key here, in this tab, on m/44'/60'/0'/0/0 — the" +
          " same path CausewaybayWallet uses, so the same phrase is the same you in both.",
        "",
        "It is never sent. The server asks you to sign a line of text and works out who" +
          " you are from the signature. Only the session token is kept, and only so a" +
          " reload does not ask you again.",
        "",
        "Nothing in the game lives in this browser. Close it, come back, the map is" +
          " where you left it.",
      ].join("\n"),
      right[0],
      right[1],
      right[2],
      "left",
    );

    footer(g, layout, "ENTER  LOG IN      F1  ORIENTATION      CTRL+ENTER  SUBMIT");
  }
}
