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
 * It is also **masked**, from the first keystroke and not only afterwards.
 * Twelve words legible across a cafe is the one moment this screen can cost
 * somebody everything they have, and a phrase that is only hidden once it has
 * been typed was never hidden at all. `REVEAL` lifts it, because a mistyped
 * word is the normal reason somebody cannot get in and they have to be able to
 * look; the button says which state it is in rather than relying on the dots.
 *
 * The **new-wallet panel is deliberately the opposite**. Those twelve words are
 * drawn on the canvas, in the code face, at reading size, unmasked, because the
 * entire purpose of that panel is that they get copied onto paper. Masking it
 * would be security theatre that breaks the one thing it is for.
 *
 * The screen also *hands out* a phrase, which is the difference between a game
 * you can start and one you cannot. Before this the only field on the only
 * reachable screen was "twelve words, or 0x + 64 hex" and nothing anywhere in
 * the project could produce twelve words — a player who had never run
 * `CausewaybayWallet` was simply locked out of the front door.
 *
 * A generated phrase is shown once, on a panel that says so, and
 * `I HAVE WRITTEN IT DOWN` signs in with it — it does not go back to the form
 * and it does not ask for three of the words back. There *was* a gate here: the
 * player had to type three of the twelve before the phrase would be accepted.
 * It is gone at the user's instruction, and what that costs is worth stating
 * once: somebody who clicks past the words without writing them down now loses
 * the account with nothing to catch them. The warning on the panel is the whole
 * of the protection, which is why the warning stays exactly as written.
 *
 * The phrase lives in one field on this scene, is dropped the instant it has
 * been used, is wiped in `leave()`, and is never logged, never stored and never
 * sent.
 */
import type { App, Scene } from "../app";
import { cjkFloor, ensureFonts, fontAt, printf, width, wrap, type Font } from "../engine/text";
import { css, Theme } from "../engine/theme";
import { clipped, fill, neonPrint, well, type Ctx, type Rect } from "../engine/ui";
import { btnBox, pixBtn } from "../engine/ui";
import { Buttons, footer, header, RUST, titledPanel } from "../ui/chrome";
import { seconds, Tween } from "../engine/motion";
import { Overlay } from "../ui/overlay";
import { readNumberPref, writePref } from "../ui/prefs";
import { deterministicUsername } from "../wallet/username";
import { WireError } from "../net/client";
import { playerText } from "../net/protocol";
import {
  MAX_ACCOUNT_INDEX,
  addressFromMnemonic,
  addressFromPrivateKeyHex,
  current,
  keep,
  newMnemonic,
  parseAccountIndex,
  phraseProblem,
  privateKeyHexOf,
  signMessage,
  unlock,
} from "../wallet/wallet";
import { LandsScene } from "./lands";
import { LOCALES, locale, nextLocale, onLocale, setLocale, t } from "../i18n";
import { StoryScene } from "./story";

/**
 * The wallet module refused the text. Its own message is an English sentence
 * for a developer ("that is not a valid seed phrase", "a private key is 32
 * bytes"); this class is how `report` tells that failure apart from a socket
 * that dropped, so the player gets our wording for it.
 */
class BadInputError extends Error {}

/** The empty field's own instructions, restored whenever it is handed back. */
const FIELD_HINT = (): string => t("login.fieldHint");

/**
 * The button face, stepped down until `label` fits a box `limit` wide.
 *
 * Press Start 2P has no narrow cut, so the only way a long label fits a
 * narrow card is smaller type. Down in steps of two pixels and never below
 * two thirds of the size it started at, nor below `floor` (the CJK floor
 * `ensureFonts` applies, which `fontAt` does not) — past that it is small
 * print on the one button that signs somebody up, and the width clamp takes
 * over.
 */
function fitButtonFont(f: Font, label: string, limit: number, floor: number): Font {
  let out = f;
  const least = Math.max(Math.round(f.size * 0.66), floor);
  for (let px = f.size; px >= least; px -= 2) {
    out = px === f.size ? f : fontAt(px, "pixel");
    if (btnBox(out, [label], 0, out.size * 2, 0)[0] <= limit) break;
  }
  return out;
}

/**
 * How many rows a set of labels wraps to inside `width`, at the same gap
 * `Buttons.row` uses. Kept next to the one screen that needs it rather than in
 * `chrome.ts`, because the answer depends on the exact label list.
 */
function rowsFor(f: Font, width: number, labels: string[]) {
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

/** The active language, named in itself, for the button that cycles it. */
function localeInfoLabel(): string {
  return LOCALES.find((l) => l.id === locale())?.label ?? "ENGLISH";
}

/** What `users.name` takes before it truncates (`backend/core/src/users.rs`). */
const NAME_MAX = 48;
/** Shared with the playground, whose POSTER unlocks the same account to stamp with. */
export const INDEX_PREF = "cwbhacker.wallet.index";

export class LoginScene implements Scene {
  readonly name = "login";
  readonly mood = "title" as const;
  private readonly field: HTMLTextAreaElement;
  private readonly overlay: Overlay;
  /**
   * The account index, `i` in `m/44'/60'/0'/0/i`.
   *
   * One phrase is many accounts, and the game could only ever reach the first
   * of them. Everything under this screen already took the index — the web
   * wallet's `EVM_PATH(index)`, the LÖVE client's `derive` op — so the whole
   * of the gap was that nothing asked.
   *
   * A typed field rather than a button that counts: somebody restoring an
   * account they made in another wallet knows the number and it is not
   * necessarily small, and pressing a chip thirty-seven times is not an
   * interface.
   */
  private readonly indexField: HTMLInputElement;
  private readonly indexOverlay: Overlay;
  private indexRect: Rect = [0, 0, 0, 0];
  /**
   * The name this account will be known by.
   *
   * The wallet is the account (SPEC §3) and this is not a second credential —
   * it is the thing you read to check you arrived as the right one of your
   * wallets. Forty-two characters of hex cannot do that job, and
   * `AdjectiveNoun####` can.
   *
   * Filled in from the address, so there is never an empty box asking somebody
   * to invent a name before they have seen their wallet — and refilled every
   * time the address underneath changes, right up until somebody types in it.
   * After that it is theirs and nothing rewrites it.
   */
  private readonly nameField: HTMLInputElement;
  private readonly nameOverlay: Overlay;
  private nameRect: Rect = [0, 0, 0, 0];
  private nameTouched = false;
  private readonly buttons = new Buttons();
  private fieldRect: Rect = [0, 0, 0, 0];
  private preview = "";
  private status = "";
  private busy = false;
  /**
   * Whether the player has asked to see what they typed. Never remembered:
   * a preference that outlived the screen would mean the next person to open
   * the game gets an unmasked seed field, which is the whole defect back
   * again with a setting in front of it.
   */
  private revealed = false;
  /**
   * A freshly generated phrase, while it is being shown. Key material: it is
   * held here and nowhere else, and `leave()` drops it.
   */
  private minted: string[] | null = null;
  /**
   * True while the sign-in for a minted phrase is parked waiting for the
   * socket. The phrase stays on screen the whole time — see `signIn`.
   */
  private waiting = false;
  private stopWait: ((ok: boolean) => void) | null = null;
  private t = 0;
  private readonly leftIn = new Tween(seconds("panel"));
  private readonly rightIn = new Tween(seconds("panel"), seconds("stagger"));

  private offLocale?: () => void;

  constructor(private readonly app: App) {
    const el = document.createElement("textarea");
    el.className = "cwb-field";
    el.spellcheck = false;
    el.autocapitalize = "off";
    el.autocomplete = "off";
    el.setAttribute("autocorrect", "off");
    // Masked before it can hold anything, so there is no frame in which a
    // pasted phrase is legible.
    el.classList.add("cwb-masked");
    el.placeholder = FIELD_HINT();
    // The field is DOM, so its hint is a cached string and does not follow the
    // language the way everything drawn on the canvas does. Three places change
    // the language — this screen's button, F7 from anywhere, the title card —
    // and re-setting it at each of them would leave the fourth one wrong.
    this.offLocale = onLocale(() => {
      el.placeholder = FIELD_HINT();
    });
    // The preview is derived on every keystroke so the player sees the address
    // they are about to become before committing to it. It never leaves here.
    el.addEventListener("input", () => this.derivePreview());
    this.field = el;
    this.overlay = new Overlay(app.overlay, app.layout, el);

    // Built *after* the phrase box, so the browser's own tab order runs
    // phrase -> account without either element having to claim a tabindex.
    const idx = document.createElement("input");
    idx.className = "cwb-field cwb-index";
    idx.type = "text";
    // `inputmode` rather than `type=number`: the spinner is unusable at this
    // size, and a number input hands back "" for anything it dislikes, which
    // would silently mean account 0.
    idx.inputMode = "numeric";
    idx.autocomplete = "off";
    idx.spellcheck = false;
    idx.value = String(readNumberPref(INDEX_PREF, 0, 0, MAX_ACCOUNT_INDEX));
    idx.addEventListener("input", () => {
      // Digits only, in the field itself, so what is on screen is what will
      // be derived from. A caret at the end is right for a number people
      // mostly retype rather than edit in the middle.
      const cleaned = idx.value.replace(/[^0-9]/g, "").slice(0, 10);
      if (cleaned !== idx.value) idx.value = cleaned;
      this.derivePreview();
    });
    // Remembered, like the language and the orientation: coming back to the
    // game on the account you left it on is the only behaviour that is not a
    // surprise. It is an index, not a secret — the phrase it indexes into is
    // what this screen is careful with.
    idx.addEventListener("change", () => writePref(INDEX_PREF, String(this.walletIndex())));
    // **Bare Enter submits here**, unlike in the phrase box. The reason the
    // phrase box does not is that twelve words arrive by paste, sometimes
    // across two lines, and Enter halfway through a paste would fire a login
    // on half a phrase. A one-line number has no such problem, and a field
    // you cannot leave by pressing Enter is a field people press Enter in
    // twice and then look for the button.
    idx.addEventListener("keydown", (e) => {
      if (e.key !== "Enter") return;
      e.preventDefault();
      writePref(INDEX_PREF, String(this.walletIndex()));
      if (this.minted) this.takeMinted();
      else void this.submit();
    });
    this.indexField = idx;
    this.indexOverlay = new Overlay(app.overlay, app.layout, idx);

    const nm = document.createElement("input");
    nm.className = "cwb-field cwb-name";
    nm.type = "text";
    nm.autocomplete = "off";
    nm.spellcheck = false;
    // The server takes 48 characters and truncates past that, so the box
    // refuses the 49th rather than letting somebody type a name the row will
    // quietly cut in half.
    nm.maxLength = NAME_MAX;
    nm.addEventListener("input", () => {
      // Typed in once and it is theirs: no later address change overwrites it.
      this.nameTouched = true;
    });
    this.nameField = nm;
    this.nameOverlay = new Overlay(app.overlay, app.layout, nm);
  }

  /**
   * Put the derived name in the box, unless somebody has made it their own.
   *
   * Called from `derivePreview`, so the name tracks the address rather than
   * the phrase: changing the account index is exactly the case where the box
   * must follow, because that is a different wallet and therefore a different
   * player.
   */
  private refreshName(): void {
    if (this.nameTouched) return;
    this.nameField.value = this.preview ? deterministicUsername(this.preview) : "";
  }

  /**
   * Show an address, and let the name follow it.
   *
   * Every path that changes the address goes through here. It was six
   * assignments to `this.preview` scattered across the scene, three of which
   * forgot the name — NEW WALLET showed a fresh wallet with an empty name box,
   * and CLEAR and DISCARD left the previous wallet's name sitting under an
   * address that was gone. Two things that must move together are one method,
   * or they are a bug waiting for whichever caller is written next.
   */
  private setPreview(address: string): void {
    this.preview = address;
    this.refreshName();
  }

  /** What to seed the account with, or nothing to let the server decide. */
  private chosenName(): string | undefined {
    const name = this.nameField.value.trim().slice(0, NAME_MAX);
    return name ? name : undefined;
  }

  /**
   * What is in the account box, as a number the derivation will accept.
   *
   * Empty reads as 0 rather than as an error: the box starts full and a
   * person clearing it to type a new number should not be told off mid-edit.
   */
  private walletIndex(): number {
    return parseAccountIndex(this.indexField.value);
  }

  enter(): void {
    // After a logout there is nothing held, which is the point — the field is
    // empty, the preview is empty, and the previous wallet is not on screen.
    const held = current();
    if (held) this.setPreview(held.eip55);
    if (this.app.loggedOutNotice) {
      this.status = this.app.loggedOutNotice;
      this.app.loggedOutNotice = "";
    }
    queueMicrotask(() => this.field.focus());
    // The account box survives a logout — it is a preference, not key
    // material — so the address under it is worked out on arrival rather than
    // at the first keystroke. Only when nothing is held: `derivePreview` reads
    // the *field*, which is empty here, and calling it unconditionally wiped
    // the held wallet's address off the card the moment the screen opened.
    if (!held) this.derivePreview();
  }

  leave(): void {
    // Whatever is in the box is key material. It does not outlive the screen.
    this.field.value = "";
    this.revealed = false;
    this.field.classList.add("cwb-masked");
    this.minted = null;
    this.stopWait?.(false);
    this.offLocale?.();
    this.offLocale = undefined;
    this.overlay.destroy();
    this.indexOverlay.destroy();
    this.nameOverlay.destroy();
    // A name typed for one wallet is not the name for the next one somebody
    // signs in with, and this screen is where they would arrive.
    this.nameTouched = false;
  }

  /** Twelve new words, shown once. Nothing is sent and nothing is stored. */
  private mint(): void {
    if (this.busy) return;
    this.minted = newMnemonic().split(" ");
    // The name for the wallet it just made. `derivePreview` bails while a
    // minted phrase is up — the preview belongs to *it*, not to the field —
    // so without this the one screen that hands somebody a brand-new account
    // was the one screen that did not name it.
    this.setPreview(addressFromMnemonic(this.minted.join(" ")).eip55);
    this.status = "";
    this.field.value = "";
  }

  /**
   * `I HAVE WRITTEN IT DOWN`: sign in with the phrase that is on screen, and
   * go. No confirmation step, no return to the form.
   *
   * A double press is safe because `signIn` sets `busy` synchronously, before
   * its first await — the second press a frame later finds it already set and
   * returns. One challenge, one login, one account.
   *
   * The words are deliberately *not* cleared here. They used to be, and that
   * made a dropped socket the worst thing this screen can do: the only copy of
   * the phrase went out of existence to serve an error message. They are held
   * until the login succeeds (at which point the screen is gone) or the player
   * presses CANCEL (at which point losing them is their decision).
   */
  private takeMinted(): void {
    if (this.busy) return;
    const words = this.minted;
    if (!words) return;
    void this.signIn(words.join(" "), true);
  }

  /**
   * Resolve once the socket can carry a login, or `false` if the player gave
   * up. The client reconnects on its own with §6.2 backoff, so all this does
   * is wait for it and say so.
   */
  private reachable(): Promise<boolean> {
    const client = this.app.client;
    if (client.state === "open" || client.state === "authed") return Promise.resolve(true);
    this.waiting = true;
    this.status = t("login.waitingServer");
    return new Promise<boolean>((resolve) => {
      let off: (() => void) | null = null;
      const done = (ok: boolean) => {
        off?.();
        this.stopWait = null;
        this.waiting = false;
        resolve(ok);
      };
      off = client.onState((next) => {
        if (next === "open" || next === "authed") done(true);
      });
      this.stopWait = done;
    });
  }

  /** A failure that waiting could fix, as opposed to one the player must. */
  private static transient(e: unknown): boolean {
    if (!(e instanceof WireError)) return false;
    if (e.payload.code !== "internal") return false;
    const d = e.payload.detail as { disconnected?: boolean } | undefined;
    return d?.disconnected === true || /not connected|timed out/.test(e.payload.message);
  }

  private derivePreview(): void {
    // While a minted phrase is on screen the preview belongs to *it*, and a
    // stray keystroke in the field must not blank the address the panel is
    // showing. The preview belongs to the typed-phrase path only.
    if (this.minted) return;
    const text = this.field.value.trim();
    this.status = "";
    if (!text) {
      this.setPreview("");
      return;
    }
    // A raw private key **is** the account: there is no path to walk and the
    // box does not apply to it. Said on the label rather than by silently
    // deriving something the number had no part in.
    const hex = privateKeyHexOf(text);
    if (hex) {
      this.setPreview(addressFromPrivateKeyHex(hex).eip55);
      return;
    }
    const problem = phraseProblem(text);
    if (!problem) {
      this.setPreview(addressFromMnemonic(text, this.walletIndex()).eip55);
      return;
    }
    this.setPreview("");
    // Half a phrase is not an error worth shouting about — but a phrase that
    // is *all there* and still not an address is, quietly: the card used to
    // show a dash for a wrong phrase and a dash for a broken screen, and a
    // person with one word wrong could not tell which they had.
    const words = text.split(/\s+/u).length;
    if (problem.kind === "word" && words >= 12) {
      this.status = t("login.notAWord", { word: problem.word });
    } else if (problem.kind === "count" && words >= 12) {
      this.status = t("login.wordCount", { n: problem.count });
    } else if (problem.kind === "checksum") {
      this.status = t("login.badChecksum");
    }
  }

  private async submit(): Promise<void> {
    if (this.busy) return;
    const text = this.field.value.trim();
    if (!text) {
      this.status = t("login.needPhrase");
      return;
    }
    // Checked here, before anything is derived. `unlock` refuses a bad phrase
    // with an English sentence meant for a developer, and this is the one
    // localized screen a person who cannot read English is guaranteed to see.
    const problem = LoginScene.inputProblem(text);
    if (problem) {
      this.status = problem;
      this.app.chip.fail();
      return;
    }
    await this.signIn(text);
  }

  /**
   * Why the text in the field cannot be signed in with, in the player's
   * language — or `null` when it can. The same three complaints the preview
   * makes as somebody types, plus the one it cannot: hex that is not a key.
   */
  private static inputProblem(text: string): string | null {
    const flat = text.replace(/\s/gu, "");
    // Anything that reads as hex is on the key path: a `0x` prefix, or a run
    // of hex digits too long to be a seed word. A malformed key must not fall
    // through to the phrase check and be told "0x12ab is not a seed word".
    const hexish = /^0x/iu.test(flat) || (/^[0-9a-f]+$/iu.test(flat) && flat.length >= 40);
    if (hexish) return privateKeyHexOf(text) ? null : t("login.badInput");
    const problem = phraseProblem(text);
    if (!problem) return null;
    if (problem.kind === "word") return t("login.notAWord", { word: problem.word });
    if (problem.kind === "count") return t("login.wordCount", { n: problem.count });
    return t("login.badChecksum");
  }

  /**
   * Derive, sign the server's challenge, and go. One path, whether the phrase
   * was typed into the field or handed out by this screen a second ago.
   */
  private async signIn(text: string, minted = false): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      // Up to five goes for a phrase this screen handed out, each one parked
      // on `reachable` until the socket is back. A typed phrase gets one go:
      // it still exists on paper or in a password manager, and the player is
      // in front of a form they can press ENTER on again.
      for (let attempt = 0; attempt < (minted ? 5 : 1); attempt++) {
        if (minted && !(await this.reachable())) return;
        try {
          await this.attempt(text, minted);
          return;
        } catch (e) {
          this.report(e);
          if (!minted || !LoginScene.transient(e)) return;
        }
      }
      this.status = t("login.stillUnreachable");
    } finally {
      this.busy = false;
    }
  }

  /**
   * One go: derive, sign the challenge, log in, leave.
   *
   * A phrase this screen minted a moment ago signs in at index 0, whatever the
   * account box says: the address on the panel was derived at 0, and the box
   * is a preference kept from some *other* wallet. Signing in at index 3 with
   * a card that promised the index-0 address is a wallet nobody wrote down.
   */
  private async attempt(text: string, minted = false): Promise<void> {
    // A live session on this socket cannot become a different one (§3.1), and
    // the server says so in a code the player should never have to read. Trade
    // it for a fresh anonymous connection first — that is what "log in as
    // somebody else" means at the wire level.
    if (this.app.client.state === "authed") {
      this.status = t("login.closingOld");
      await this.app.client.restart();
    }
    this.status = t("login.deriving");
    const address = LoginScene.derive(text, minted ? 0 : this.walletIndex());
    // The textarea is emptied before a single byte goes near the socket.
    this.field.value = "";
    // Through `setPreview` like every other path, even though the name box is
    // about to be read and the screen is about to leave: the rule is only a
    // rule if it has no exceptions, and the test below enforces exactly that.
    this.setPreview(address.eip55);

    this.status = t("login.challenging");
    const challenge = await this.app.client.challenge(address.eip55);

    this.status = t("login.signing");
    const signature = signMessage(challenge.message);

    this.status = t("login.loggingIn");
    // §4.3 takes an optional name and only ever uses it as a **default**: an
    // account that already exists keeps the name it has, so typing here is
    // how a new wallet is named and not a way to rename an old one. Renaming
    // is `profile.update`, from inside the game.
    const user = await this.app.client.login(address.eip55, signature, this.chosenName());
    this.app.addressLabel = user.address;
    // Kept in this browser's localStorage, under this address, now that the
    // server has accepted it: the next tab, reload or poster signs with it
    // and nobody pastes the phrase twice. Never for a phrase that failed.
    keep();
    // §1.3: the client keeps nothing durable of its own. Where this player is
    // comes back with the login, from whichever client they used last — the
    // browser and the LÖVE desktop client share one server and therefore one
    // place.
    this.app.restorePlace(this.app.client.position);
    // Past the point of no return for the phrase, and the screen is leaving.
    this.minted = null;
    this.app.chip.start();
    await this.app.go(new LandsScene(this.app), "forward");
  }

  /** `unlock`, with its refusal marked as the player's input rather than ours. */
  private static derive(text: string, index: number): ReturnType<typeof unlock> {
    try {
      return unlock(text, index);
    } catch (e) {
      throw new BadInputError(e instanceof Error ? e.message : String(e));
    }
  }

  /**
   * §3.3: the server's `message` is for a developer. The player gets our
   * wording, keyed off the code; the server's line goes to the console where a
   * developer can actually find it. The same rule for our own modules: the
   * wallet's and the client's sentences are English and go to the console too.
   */
  private report(e: unknown): void {
    if (e instanceof WireError) {
      console.warn("auth failed:", e.payload.code, e.payload.message, e.payload.detail);
      this.status = LoginScene.transient(e) ? t("login.unreachable") : playerText(e.payload.code);
      // §3.3's table: a spent or expired nonce is retryable as-is, and saying
      // "log in again" about it would be a lie.
      if (e.action === "rechallenge") this.status += t("login.pressEnter");
    } else if (e instanceof BadInputError) {
      console.warn("auth failed:", e.message);
      this.status = t("login.badInput");
    } else {
      console.warn("auth failed:", e);
      this.status = t("login.failed");
    }
    this.app.chip.fail();
  }

  /**
   * Show or hide what is in the field.
   *
   * The caret goes back where it was: `classList` does not move a selection,
   * but focus does, and somebody who pressed REVEAL mid-phrase to check a word
   * wants to carry on typing rather than hunt for their place.
   */
  private toggleReveal(): void {
    this.revealed = !this.revealed;
    this.field.classList.toggle("cwb-masked", !this.revealed);
    const at = this.field.selectionStart;
    this.field.focus();
    try {
      this.field.setSelectionRange(at, this.field.selectionEnd);
    } catch {
      /* a field that will not take a range still takes the focus */
    }
  }

  controls(): Buttons[] {
    return [this.buttons];
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
    if (hit.id === "keep") this.takeMinted();
    if (hit.id === "discard") {
      // The one place the phrase is allowed to disappear: because they said so.
      this.stopWait?.(false);
      this.minted = null;
      this.setPreview("");
      this.field.value = "";
      this.field.placeholder = FIELD_HINT();
    }
    if (hit.id === "clear") {
      this.field.value = "";
      this.setPreview("");
      this.field.focus();
    }
    if (hit.id === "reveal") this.toggleReveal();
    if (hit.id === "lang") {
      const next = nextLocale();
      void setLocale(next);
      this.status = "";
    }
    if (hit.id === "fullscreen") {
      void this.app.toggleFullscreen().then((on) => {
        this.app.say(on ? t("app.fullscreenOn") : t("app.fullscreenOff"));
      });
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
      if (this.minted) this.takeMinted();
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

    header(g, this.app, t("login.title"));
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
    const bottom = this.minted
      ? this.drawPhrase(g, colX, cardY, colW)
      : this.drawKeyCard(g, colX, cardY, colW);
    this.buttons.draw(g, fonts.button);
    g.restore();

    if (this.status) {
      g.fillStyle = css(this.busy ? Theme.cyan : this.minted ? Theme.coin : Theme.red);
      printf(g, fonts.small, this.status, colX, bottom + Math.round(8 * s), colW, "center");
    }

    footer(g, layout, this.minted ? t("login.footerMinted") : t("login.footer"));
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
    // leaves its last button outside its own panel.
    // Measured at the width the row is laid out in — the panel's inner
    // width, `titledPanel`'s 6 + 8 each side — not a guess at it: the two
    // disagreed by a few pixels, and with seven buttons that was a fourth
    // row the card was not sized for.
    const btnRows = rowsFor(fonts.button, w - 28, [
      t("login.enter"),
      t("login.newWallet"),
      t("login.story"),
      this.revealed ? t("login.hide") : t("login.reveal"),
      t("login.clear"),
      localeInfoLabel(),
      this.app.isFullscreen() ? t("login.windowed") : t("login.fullscreen"),
    ]);
    // The frame's own overhead is `titledPanel`'s: 8 above the title bar,
    // the bar, 8 under it, 6 + 8 at the bottom. It was a flat 30, which is
    // short by most of the bar, and the last button row stood on the rim.
    const frameH = 8 + fonts.stationSm.height + Math.round(fonts.stationSm.size * 0.9) + 8 + 14;
    // The account row: a label on the left, a box on the right, on one line
    // between the phrase and the address it produces — which is the order the
    // three are read in.
    const idxH = Math.max(layout.minTouchH(), fonts.small.height + Math.round(14 * s));
    const cardH =
      frameH +
      fieldH +
      pad +
      idxH +
      pad +
      idxH +
      pad +
      fonts.stationSm.height +
      Math.round(4 * s) +
      fonts.small.height +
      pad +
      btnH * btnRows +
      (btnRows - 1) * Math.round(fonts.button.size * 0.5) +
      pad;

    const card = titledPanel(g, [x, y, w, cardH], t("login.cardTitle"), RUST);
    well(g, card[0], card[1], card[2], fieldH);
    this.fieldRect = [card[0] + 4, card[1] + 4, card[2] - 8, fieldH - 8];
    if (this.rightIn.finished) this.overlay.place(this.fieldRect, fonts.small.size);
    else this.overlay.hide();

    let cy = card[1] + fieldH + pad;

    // **The account, beside the phrase that indexes into it.**
    // Dimmed when the box above holds a raw private key, because that is the
    // one input this number has nothing to do with: a key is an account
    // already and there is no path left to walk.
    const raw = /^0x[0-9a-fA-F]{64}$/.test(this.field.value.trim());
    const idxW = Math.min(Math.round(140 * s), Math.round(card[2] * 0.4));
    g.fillStyle = css(raw ? Theme.dim : Theme.cyan);
    printf(
      g,
      fonts.stationSm,
      raw ? t("login.accountRaw") : t("login.account"),
      card[0],
      cy + Math.round((idxH - fonts.stationSm.height) / 2),
      card[2] - idxW - Math.round(8 * s),
      "left",
    );
    well(g, card[0] + card[2] - idxW, cy, idxW, idxH, [0.06, 0.05, 0.14, 0.98]);
    this.indexRect = [card[0] + card[2] - idxW + 4, cy + 3, idxW - 8, idxH - 6];
    if (this.rightIn.finished && !raw) this.indexOverlay.place(this.indexRect, fonts.small.size);
    else this.indexOverlay.hide();
    cy += idxH + pad;

    // **The name, under the number that decides it.** Read top to bottom the
    // card is now phrase, account, name, address — the order in which one
    // thing produces the next.
    g.fillStyle = css(Theme.cyan);
    // Measured against its own label rather than sharing the index box's
    // width. The two boxes hold different things: an account index is one or
    // two digits and a name is `MythicOrca1234`, and a name in a box sized for
    // a number is a name you cannot read the end of — which on this screen is
    // the end that tells two of your wallets apart.
    const nameLabel = t("login.username");
    const nameW = Math.max(idxW, card[2] - width(fonts.stationSm, nameLabel) - Math.round(16 * s));
    printf(
      g,
      fonts.stationSm,
      nameLabel,
      card[0],
      cy + Math.round((idxH - fonts.stationSm.height) / 2),
      card[2] - nameW - Math.round(8 * s),
      "left",
    );
    well(g, card[0] + card[2] - nameW, cy, nameW, idxH, [0.06, 0.05, 0.14, 0.98]);
    this.nameRect = [card[0] + card[2] - nameW + 4, cy + 3, nameW - 8, idxH - 6];
    if (this.rightIn.finished) this.nameOverlay.place(this.nameRect, fonts.small.size);
    else this.nameOverlay.hide();
    cy += idxH + pad;

    g.fillStyle = css(Theme.cyan);
    printf(g, fonts.stationSm, t("login.youWillBe"), card[0], cy, card[2], "left");
    // Said on the right of the same line, so the state of the field is
    // readable without typing into it to find out.
    g.fillStyle = css(this.revealed ? Theme.red : Theme.dim);
    printf(
      g,
      fonts.stationSm,
      this.revealed ? t("login.phraseVisible") : t("login.phraseHidden"),
      card[0],
      cy,
      card[2],
      "right",
    );
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
        {
          id: "enter",
          label: this.busy ? "…" : t("login.enter"),
          dim: this.busy,
          primary: !this.busy,
        },
        { id: "new", label: t("login.newWallet") },
        // The opening, on demand. It plays once at a cold boot and then gets
        // out of the way; this is how somebody watches it again on purpose.
        { id: "story", label: t("login.story") },
        // The words are dots by default. This is the way back to them, and it
        // says which state it is about to put the field in.
        { id: "reveal", label: this.revealed ? t("login.hide") : t("login.reveal") },
        { id: "clear", label: t("login.clear") },
        // The language, named in itself. The title card has the full row; by
        // the time somebody is on the login screen they have usually already
        // chosen, so this cycles rather than taking six buttons' worth of a
        // card that is sized to its contents.
        { id: "lang", label: localeInfoLabel() },
        // Fullscreen, beside the language for the same reason: it is a
        // display choice, and the login card is where the display choices
        // live. It says the state it is about to put the window in.
        {
          id: "fullscreen",
          label: this.app.isFullscreen() ? t("login.windowed") : t("login.fullscreen"),
        },
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
    const warn = t("login.mintWarning");
    const warnLines = wrap(fonts.small, warn, w - Math.round(24 * s)).length;
    const btnH = Math.max(layout.minTouchH(), fonts.button.height + 20);
    // The panel's inner width, `titledPanel`'s 6 + 8 each side.
    const innerW = w - 28;
    const keepLabel = this.waiting ? t("login.mintWaiting") : this.busy ? "…" : t("login.mintKeep");
    const cancelLabel = t("login.mintCancel");
    // I HAVE WRITTEN IT DOWN is wider than the card at the button size, in
    // both orientations, and a button wider than its panel ran out over the
    // right border. The type steps down until the box fits — this one label,
    // painted by hand below, because `Buttons.draw` sets every button in one
    // face — and the width is clamped to the panel whatever the label does.
    const keepFont = fitButtonFont(fonts.button, keepLabel, innerW, Math.round(cjkFloor() * s));
    const keepW = Math.min(innerW, btnBox(keepFont, [keepLabel], 0, keepFont.size * 2, 0)[0]);
    const [cancelW] = btnBox(fonts.button, [cancelLabel], 0, fonts.button.size * 2, 0);
    const btnGap = Math.round(fonts.button.size * 0.5);
    // Measured, not "one in landscape, two in portrait": I HAVE WRITTEN IT
    // DOWN and CANCEL wrap in a landscape card too, and the assumed single
    // row put CANCEL on the rim.
    const btnRows = keepW + btnGap + cancelW <= innerW ? 1 : 2;
    const frameH = 8 + fonts.stationSm.height + Math.round(fonts.stationSm.size * 0.9) + 8 + 14;
    const cardH =
      frameH +
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

    const card = titledPanel(g, [x, y, w, cardH], t("login.mintTitle"), Theme.coin);
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
    printf(g, fonts.small, warn, card[0], cy, card[2], "center");
    cy += warnLines * fonts.small.height + pad;
    g.fillStyle = css(Theme.cyan);
    printf(g, fonts.stationSm, t("login.youWillBe"), card[0], cy, card[2], "left");
    cy += fonts.stationSm.height + Math.round(4 * s);
    g.fillStyle = css(Theme.coin);
    printf(g, fonts.small, this.preview || "—", card[0], cy, card[2], "left");
    cy += fonts.small.height + pad;

    // The same geometry `Buttons.row` would lay out, done by hand because the
    // first button is set in its own face.
    const keep = this.buttons.add({
      id: "keep",
      rect: [card[0], cy, keepW, btnH],
      label: keepLabel,
      dim: this.busy,
      primary: !this.busy,
      painted: true,
    });
    pixBtn(g, keepFont, keep.rect[0], keep.rect[1], keep.rect[2], keep.rect[3], keepLabel, {
      hover: this.buttons.hovered === "keep",
      dim: this.busy,
      lit: !this.busy,
    });
    // Live while we wait, and only while we wait: giving up has to be
    // possible, and it is the only thing that throws the words away.
    this.buttons.add({
      id: "discard",
      rect:
        btnRows === 1
          ? [card[0] + keepW + btnGap, cy, cancelW, btnH]
          : [card[0], cy + btnH + btnGap, cancelW, btnH],
      label: cancelLabel,
      dim: this.busy && !this.waiting,
    });
    this.overlay.hide();
    this.indexOverlay.hide();
    this.nameOverlay.hide();
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
    const copy = t("login.custody");
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
