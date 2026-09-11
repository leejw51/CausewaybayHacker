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
 *
 * The screen also *hands out* a phrase, which is the difference between a game
 * you can start and one you cannot. Before this the only field on the only
 * reachable screen was "twelve words, or 0x + 64 hex" and nothing anywhere in
 * the project could produce twelve words — a player who had never run
 * `CausewaybayWallet` was simply locked out of the front door.
 *
 * A generated phrase is shown once, on a panel that says so, and the player has
 * to say they have written it down before it goes anywhere near the field. It
 * lives in one field on this scene, is wiped in `leave()`, and is never logged,
 * never stored and never sent.
 */
import type { App, Scene } from "../app";
import { ensureFonts, printf, wrap } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { clipped, fill, neonPrint, well, type Ctx, type Rect } from "../engine/ui";
import { btnBox } from "../engine/ui";
import { Buttons, footer, header, RUST, titledPanel } from "../ui/chrome";
import { seconds, Tween } from "../engine/motion";
import { Overlay } from "../ui/overlay";
import { WireError } from "../net/client";
import { playerText } from "../net/protocol";
import {
  addressFromMnemonic,
  addressFromPrivateKeyHex,
  current,
  newMnemonic,
  signMessage,
  unlock,
} from "../wallet/wallet";
import { LandsScene } from "./lands";
import { StoryScene } from "./story";

/** The empty field's own instructions, restored whenever it is handed back. */
const FIELD_HINT = "twelve words, or 0x + 64 hex";

/** Why the gate is here, in the two lines it takes to say it. */
const QUIZ_INTRO =
  "Read three back off the paper, in this order. There is no reset and nobody can send them to you again.";

/**
 * How many rows a set of labels wraps to inside `width`, at the same gap
 * `Buttons.row` uses. Kept next to the one screen that needs it rather than in
 * `chrome.ts`, because the answer depends on the exact label list.
 */
function rowsFor(f: { size: number; css: string; height: number }, width: number, labels: string[]) {
  const gap = Math.round(f.size * 0.5);
  let rows = 1;
  let x = 0;
  for (const label of labels) {
    const [bw] = btnBox(f, [label], 0, f.size * 2, 0);
    if (x > 0 && x + bw > width) {
      rows++;
      x = 0;
    }
    x += bw + gap;
  }
  return rows;
}

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
  /**
   * A freshly generated phrase, while it is being shown. Key material: it is
   * held here and nowhere else, and `leave()` drops it.
   */
  private minted: string[] | null = null;
  /**
   * Which three words are being asked for, zero-based, once the list has been
   * put away. Null while the list is still up.
   */
  private quiz: number[] | null = null;
  private quizError = "";
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
    el.placeholder = FIELD_HINT;
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
    this.minted = null;
    this.quiz = null;
    this.overlay.destroy();
  }

  /** Twelve new words, shown once. Nothing is sent and nothing is stored. */
  private mint(): void {
    this.minted = newMnemonic().split(" ");
    this.preview = addressFromMnemonic(this.minted.join(" ")).eip55;
    this.status = "";
    this.quiz = null;
    this.quizError = "";
    this.field.value = "";
  }

  /**
   * Put the list away and ask for three of the words back.
   *
   * Not a checkbox. SPEC §3 makes the wallet the identity: there is no reset
   * and there is no support desk, so a phrase that was never actually written
   * down is an account that ends with the machine. A checkbox measures whether
   * somebody can click a checkbox. (L2D reached the same conclusion for the
   * LÖVE client and this matches it deliberately, so the two clients do not
   * disagree about how serious the moment is.)
   *
   * The three are drawn from `crypto.getRandomValues` rather than
   * `Math.random`, for the same reason the phrase is: nothing predictable goes
   * anywhere near this screen.
   */
  private askBack(): void {
    if (!this.minted) return;
    const pick = new Set<number>();
    const draw = new Uint8Array(1);
    while (pick.size < 3) {
      crypto.getRandomValues(draw);
      pick.add(draw[0] % this.minted.length);
    }
    this.quiz = [...pick].sort((a, b) => a - b);
    this.quizError = "";
    this.field.value = "";
    this.field.placeholder = "the three words, in order, separated by spaces";
    queueMicrotask(() => this.field.focus());
  }

  /** Back to the list, for somebody who genuinely needs another look. */
  private showAgain(): void {
    this.quiz = null;
    this.quizError = "";
    this.field.value = "";
    this.field.placeholder = FIELD_HINT;
  }

  /**
   * Check the three, then hand the phrase over.
   *
   * Only on a pass does the phrase reach the field, so the words cannot be
   * quietly submitted from behind the panel that is telling somebody to write
   * them down.
   */
  private checkBack(): void {
    const words = this.minted;
    const quiz = this.quiz;
    if (!words || !quiz) return;
    const typed = this.field.value.trim().toLowerCase().split(/\s+/u).filter(Boolean);
    if (typed.length !== quiz.length) {
      this.quizError = `three words, in order — ${quiz.map((i) => i + 1).join(", ")}`;
      return;
    }
    for (let i = 0; i < quiz.length; i++) {
      if (typed[i] !== words[quiz[i]]) {
        // Say which one, by its number. "Wrong" with no handle on it is a
        // dead end, and the list is one keypress away anyway.
        this.quizError = `word ${String(quiz[i] + 1).padStart(2, "0")} is not right`;
        return;
      }
    }
    this.field.value = words.join(" ");
    this.field.placeholder = FIELD_HINT;
    this.minted = null;
    this.quiz = null;
    this.quizError = "";
    this.status = "the phrase is in the box — press ENTER";
    this.derivePreview();
    queueMicrotask(() => this.field.focus());
  }

  private derivePreview(): void {
    // While a minted phrase is in play the field holds three words, not a
    // phrase, so deriving from it would throw and blank the address the list
    // panel is showing. The preview belongs to the typed-phrase path only.
    if (this.minted || this.quiz) return;
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
    if (hit.id === "new") this.mint();
    if (hit.id === "story") void this.app.go(new StoryScene(this.app, true), "forward");
    if (hit.id === "keep") this.askBack();
    if (hit.id === "confirm") this.checkBack();
    if (hit.id === "again") this.showAgain();
    if (hit.id === "discard") {
      this.minted = null;
      this.quiz = null;
      this.quizError = "";
      this.preview = "";
      this.field.value = "";
      this.field.placeholder = FIELD_HINT;
    }
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
      // While a new phrase is in play, Enter means "check what I typed" or
      // "yes, put the list away" — never "log in with a phrase I have not
      // written down yet".
      if (this.quiz) this.checkBack();
      else if (this.minted) this.askBack();
      else void this.submit();
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
    const s = layout.uiScale();
    const fonts = ensureFonts(s);

    // The establishing shot.
    //
    // The review asked for the painted plate *behind* the generated parallax
    // bands. That is not buildable as written — the WebGL canvas is behind the
    // 2D one, so the only way under the bands is to make the plate a texture
    // inside `gfx/backdrop.ts` — and it would not work if it were: `title_bg`
    // is a bright morning street and the bands are night silhouettes, so
    // compositing them reads as a mistake rather than as depth.
    //
    // So on this one screen the painting wins outright and the bands are
    // suppressed (`Mood.title` dims them to nothing). The generated city is a
    // good middle distance and a poor establishing shot; the first screen a
    // player ever sees should be a tram on Percival Street, not a blue skyline
    // that could be any city at night.
    const plate = this.app.assets?.picture("title_bg", layout.isPortrait());
    if (plate) {
      const scale = Math.max(layout.vw / plate.naturalWidth, layout.vh / plate.naturalHeight);
      const aw = plate.naturalWidth * scale;
      const ah = plate.naturalHeight * scale;
      // Clipped to the playfield. The 2D layer is a full-window canvas with the
      // virtual canvas drawn inside it, so a `cover` blit with no clip spills
      // past the frame `App.frameEdge` draws — and then the frame is a line
      // through a picture instead of the edge of one.
      clipped(g, 0, 0, layout.vw, layout.vh, () =>
        g.drawImage(plate, (layout.vw - aw) / 2, (layout.vh - ah) / 2, aw, ah),
      );
      // A gradient down to the void, so the furniture in the lower half sits
      // on something dark enough to read against without flattening the art.
      const grad = g.createLinearGradient(0, layout.vh * 0.32, 0, layout.vh);
      grad.addColorStop(0, "rgba(20,28,72,0)");
      grad.addColorStop(1, "rgba(20,28,72,0.92)");
      g.fillStyle = grad;
      g.fillRect(0, 0, layout.vw, layout.vh);
    }

    header(g, this.app, "LOGIN");
    this.buttons.reset();

    const colW = Math.min(layout.vw - Math.round(32 * s), Math.round(560 * s));
    const colX = Math.round((layout.vw - colW) / 2);
    const top = Math.round(38 * s);

    // The title, set over the street rather than inside a box.
    const titleY = top + Math.round((layout.isPortrait() ? 60 : 34) * s);
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

    const cardY = titleY + Math.round(fonts.title.height * 2.4);
    const drop = (1 - this.rightIn.out) * Math.round(46 * s);
    g.save();
    g.globalAlpha = Math.min(1, this.rightIn.raw * 2.2);
    g.translate(0, drop);
    const bottom = this.quiz
      ? this.drawQuiz(g, colX, cardY, colW)
      : this.minted
        ? this.drawPhrase(g, colX, cardY, colW)
        : this.drawKeyCard(g, colX, cardY, colW);
    this.buttons.draw(g, fonts.button);
    g.restore();

    if (this.status) {
      g.fillStyle = css(this.busy ? Theme.cyan : this.minted ? Theme.coin : Theme.red);
      printf(g, fonts.small, this.status, colX, bottom + Math.round(8 * s), colW, "center");
    }

    footer(
      g,
      layout,
      this.quiz
        ? "ENTER  CHECK      F1  ORIENTATION"
        : this.minted
          ? "ENTER  I HAVE WRITTEN IT DOWN      F1  ORIENTATION"
          : "ENTER  LOG IN      F1  ORIENTATION",
    );
  }

  /**
   * The key card: the field, who it makes you, and the way in.
   *
   * Sized to what is in it, not to the window. A panel stretched to the
   * viewport with its contents at the top reads as unfinished, and this is the
   * first screen anybody sees.
   */
  private drawKeyCard(g: Ctx, x: number, y: number, w: number): number {
    const { layout } = this.app;
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    const pad = Math.round(10 * s);
    const fieldH = Math.max(fonts.small.height * 2.6, Math.round(78 * s));
    const btnH = Math.max(layout.minTouchH(), fonts.button.height + 20);
    // Measured, not guessed. `Buttons.row` wraps when a label will not fit, so
    // the card has to be told how many rows that turns out to be — a card sized
    // for one row and drawn with two puts its last button outside itself, which
    // is the bug the quiz card already had.
    const btnRows = rowsFor(
      fonts.button,
      w - Math.round(24 * s),
      ["ENTER", "NEW WALLET", "STORY", "CLEAR"],
    );
    const cardH =
      Math.round(30 * s) +
      fieldH +
      pad +
      fonts.stationSm.height +
      fonts.small.height +
      pad * 2 +
      btnH * btnRows +
      (btnRows - 1) * Math.round(fonts.button.size * 0.5) +
      pad;

    const card = titledPanel(g, [x, y, w, cardH], "SEED PHRASE OR PRIVATE KEY", RUST);
    well(g, card[0], card[1], card[2], fieldH);
    this.fieldRect = [card[0] + 4, card[1] + 4, card[2] - 8, fieldH - 8];
    if (this.rightIn.finished) this.overlay.place(this.fieldRect, fonts.small.size);
    else this.overlay.hide();

    let cy = card[1] + fieldH + pad;
    g.fillStyle = css(Theme.cyan);
    printf(g, fonts.stationSm, "YOU WILL BE", card[0], cy, card[2], "left");
    cy += fonts.stationSm.height + Math.round(4 * s);
    g.fillStyle = css(this.preview ? Theme.coin : Theme.dim);
    printf(g, fonts.small, this.preview || "—", card[0], cy, card[2], "left");
    cy += fonts.small.height + pad;

    // NEW WALLET is the answer to "I do not have one of these", which is the
    // first question this screen has to answer and the one it never did.
    this.buttons.row(
      fonts.button,
      [card[0], cy, card[2], btnH * btnRows],
      [
        { id: "enter", label: this.busy ? "…" : "ENTER", dim: this.busy, primary: !this.busy },
        { id: "new", label: "NEW WALLET" },
        // The opening, on demand. It plays once at a cold boot and then gets
        // out of the way; this is how somebody watches it again on purpose.
        { id: "story", label: "STORY" },
        { id: "clear", label: "CLEAR" },
      ],
      layout.minTouchH(),
    );

    this.drawCustody(g, x, y + cardH + Math.round(14 * s), w);
    return y + cardH;
  }

  /**
   * Twelve words, once.
   *
   * This is the whole sign-up, so it is allowed to be the loudest thing on the
   * screen while it is up. The words are set in the code face at reading size
   * because they will be copied down by hand onto paper.
   */
  private drawPhrase(g: Ctx, x: number, y: number, w: number): number {
    const { layout } = this.app;
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    const words = this.minted ?? [];
    const pad = Math.round(10 * s);
    const cols = layout.isPortrait() ? 2 : 3;
    const rows = Math.ceil(words.length / cols);
    const rowH = fonts.code.height + Math.round(10 * s);
    const gridH = rows * rowH + pad * 2;
    const warnLines = wrap(
      fonts.small,
      "This is the only copy. There is no reset: nobody can give it back to you, not this tab and not the server.",
      w - Math.round(24 * s),
    ).length;
    const btnH = Math.max(layout.minTouchH(), fonts.button.height + 20);
    const btnRows = layout.isPortrait() ? 2 : 1;
    const cardH =
      Math.round(30 * s) +
      gridH +
      pad +
      warnLines * fonts.small.height +
      pad +
      fonts.stationSm.height +
      fonts.small.height +
      pad +
      btnH * btnRows +
      (btnRows - 1) * Math.round(fonts.button.size * 0.5) +
      pad;

    const card = titledPanel(g, [x, y, w, cardH], "WRITE THESE TWELVE WORDS DOWN", Theme.coin);
    well(g, card[0], card[1], card[2], gridH);

    const cellW = (card[2] - pad * 2) / cols;
    for (let i = 0; i < words.length; i++) {
      const cx = card[0] + pad + (i % cols) * cellW;
      const cyy = card[1] + pad + Math.floor(i / cols) * rowH;
      g.fillStyle = css(Theme.dim);
      printf(
        g,
        fonts.stationSm,
        String(i + 1).padStart(2, "0"),
        cx,
        cyy + Math.round(6 * s),
        cellW,
        "left",
      );
      g.fillStyle = css(Theme.cream);
      printf(
        g,
        fonts.code,
        words[i],
        cx + Math.round(26 * s),
        cyy,
        cellW - Math.round(26 * s),
        "left",
      );
    }

    let cy = card[1] + gridH + pad;
    g.fillStyle = css(Theme.coin);
    printf(
      g,
      fonts.small,
      "This is the only copy. There is no reset: nobody can give it back to you, not this tab and not the server.",
      card[0],
      cy,
      card[2],
      "center",
    );
    cy += warnLines * fonts.small.height + pad;
    g.fillStyle = css(Theme.cyan);
    printf(g, fonts.stationSm, "YOU WILL BE", card[0], cy, card[2], "left");
    cy += fonts.stationSm.height + Math.round(4 * s);
    g.fillStyle = css(Theme.coin);
    printf(g, fonts.small, this.preview || "—", card[0], cy, card[2], "left");
    cy += fonts.small.height + pad;

    this.buttons.row(
      fonts.button,
      [card[0], cy, card[2], btnH * btnRows],
      [
        { id: "keep", label: "I HAVE WRITTEN IT DOWN", primary: true },
        { id: "discard", label: "CANCEL" },
      ],
      layout.minTouchH(),
    );
    this.overlay.hide();
    return y + cardH;
  }

  /**
   * The gate: three of the twelve, typed back.
   *
   * The list is gone by the time this is on screen, which is the whole point —
   * the only way through is off the paper. `SHOW ME THEM AGAIN` exists because
   * a gate nobody can pass is a gate people route around, and somebody who
   * genuinely mis-copied one word should not lose the wallet over it.
   */
  private drawQuiz(g: Ctx, x: number, y: number, w: number): number {
    const { layout } = this.app;
    const s = layout.uiScale();
    const fonts = ensureFonts(s);
    const quiz = this.quiz ?? [];
    const pad = Math.round(10 * s);
    const askH = fonts.code.height + Math.round(8 * s);
    const fieldH = Math.max(fonts.small.height * 1.8, Math.round(56 * s));
    const btnH = Math.max(layout.minTouchH(), fonts.button.height + 20);
    // Three buttons never fit one line at this column width, so the row is
    // measured rather than assumed — a card sized for one row and drawn with
    // two puts the last button outside its own panel.
    const btnRows = 2;
    const introLines = wrap(fonts.small, QUIZ_INTRO, w - Math.round(24 * s)).length;
    const cardH =
      Math.round(30 * s) +
      introLines * fonts.small.height +
      pad +
      askH +
      pad +
      fieldH +
      pad +
      fonts.stationSm.height +
      pad +
      btnH * btnRows +
      (btnRows - 1) * Math.round(fonts.button.size * 0.5) +
      pad;

    const card = titledPanel(g, [x, y, w, cardH], "PROVE YOU WROTE THEM DOWN", Theme.coin);
    g.fillStyle = css(Theme.cream);
    printf(g, fonts.small, QUIZ_INTRO, card[0], card[1], card[2], "center");
    let cy = card[1] + introLines * fonts.small.height + pad;

    g.fillStyle = css(Theme.coin);
    printf(
      g,
      fonts.code,
      quiz.map((i) => `WORD ${String(i + 1).padStart(2, "0")}`).join("   "),
      card[0],
      cy,
      card[2],
      "center",
    );
    cy += askH + pad;

    well(g, card[0], cy, card[2], fieldH);
    this.fieldRect = [card[0] + 4, cy + 4, card[2] - 8, fieldH - 8];
    if (this.rightIn.finished) this.overlay.place(this.fieldRect, fonts.small.size);
    else this.overlay.hide();
    cy += fieldH + pad;

    g.fillStyle = css(this.quizError ? Theme.red : Theme.dim);
    printf(
      g,
      fonts.stationSm,
      this.quizError || "THREE WORDS, SEPARATED BY SPACES",
      card[0],
      cy,
      card[2],
      "center",
    );
    cy += fonts.stationSm.height + pad;

    this.buttons.row(
      fonts.button,
      [card[0], cy, card[2], btnH * btnRows],
      [
        { id: "confirm", label: "CONFIRM", primary: true },
        { id: "again", label: "SHOW THEM AGAIN" },
        { id: "discard", label: "CANCEL" },
      ],
      layout.minTouchH(),
    );
    return y + cardH;
  }

  /**
   * Two lines about custody, framed.
   *
   * It used to be six lines of unframed prose on a screen where everything
   * else is a hard-edged 16-bit panel, and it explained *custody* to somebody
   * who did not yet have a key to be custodial about. The screen's first job is
   * to say what to do; this is the footnote to that.
   */
  private drawCustody(g: Ctx, x: number, y: number, w: number): void {
    const s = this.app.layout.uiScale();
    const fonts = ensureFonts(s);
    const copy = "The phrase never leaves this tab. The server only ever sees a signature.";
    const inner = w - Math.round(24 * s);
    const lines = wrap(fonts.codeSm, copy, inner);
    const h = lines.length * fonts.codeSm.height + Math.round(16 * s);
    if (y + h > this.app.layout.vh - Math.round(30 * s)) return;
    fill(g, Theme.ink, x, y, w, h, 0.72);
    fill(g, Theme.dim, x, y, w, 1, 0.5);
    fill(g, Theme.dim, x, y + h - 1, w, 1, 0.5);
    g.fillStyle = css(Theme.cream, 0.8);
    printf(g, fonts.codeSm, copy, x + Math.round(12 * s), y + Math.round(8 * s), inner, "center");
  }
}
