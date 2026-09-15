/**
 * The clipboard, and the three ways it says no.
 *
 * A quest screen is a place where people want to move text: the brief into a
 * notebook, their own code into a scratch file, a compiler error into a search
 * box. None of that is possible with a canvas — canvas text is pixels, there is
 * nothing to select — so the buttons are the *only* way, and a button that
 * silently fails is worse here than anywhere else in the game.
 *
 * So this never throws and never returns `void`. Every call comes back with a
 * verdict the caller is expected to put on screen:
 *
 *   - `ok`        — it happened. Say so. A copy that works and shows nothing
 *                   is indistinguishable from one that did not.
 *   - `denied`    — the browser refused the permission, or the document was
 *                   not focused when we asked. The player can fix this and
 *                   deserves to be told which of the two it was.
 *   - `empty`     — there was nothing to copy, or nothing on the clipboard.
 *   - `unsupported` — no async clipboard here at all (an insecure origin is
 *                   the usual reason: `navigator.clipboard` is gated on a
 *                   secure context, and `http://` on a LAN address is not one).
 *
 * `readText` is separately gated in every browser that implements it — writing
 * is a gesture, reading is a permission — so PASTE fails in places COPY works
 * and the two are reported apart.
 */

import { t } from "../i18n";

export type ClipResult =
  { ok: true; text: string } | { ok: false; why: "denied" | "empty" | "unsupported" | "failed" };

/** True when the page is allowed to have an async clipboard at all. */
function api(): Clipboard | null {
  try {
    return typeof navigator !== "undefined" && navigator.clipboard ? navigator.clipboard : null;
  } catch {
    return null;
  }
}

/**
 * Why a rejection happened, as far as a `DOMException` will admit.
 *
 * `NotAllowedError` is both "the user said no" and "the document was not
 * focused"; the message is the only thing that separates them and it is not
 * standardised, so the two are folded together and the wording on screen names
 * both possibilities rather than guessing.
 */
function reason(e: unknown): "denied" | "failed" {
  const name = e instanceof DOMException ? e.name : "";
  return name === "NotAllowedError" || name === "SecurityError" ? "denied" : "failed";
}

/**
 * The old way: a textarea nobody sees, selected, and `execCommand("copy")`.
 *
 * Deprecated, synchronous, and the only thing that works where the async
 * clipboard is not allowed to exist — which is every page served over plain
 * `http://`. That is not an edge case here: the whole point of this game
 * having a server on a tailnet is playing it from a phone at
 * `http://100.93.166.76:5390`, and on that page `navigator.clipboard` is
 * undefined, so COPY told people their browser had no clipboard and did
 * nothing. It does have one. It just will not hand it over asynchronously.
 *
 * The element is positioned off-screen rather than hidden: `display:none` and
 * `visibility:hidden` are not selectable, so neither is copyable. Focus is put
 * back where it was, because this runs while somebody is typing in the editor.
 */
function copyByExec(text: string): boolean {
  if (typeof document === "undefined" || !document.body) return false;
  const was = document.activeElement as HTMLElement | null;
  const el = document.createElement("textarea");
  el.value = text;
  el.setAttribute("readonly", "");
  el.style.cssText = "position:fixed;top:-1000px;left:-1000px;opacity:0;";
  document.body.appendChild(el);
  let ok = false;
  try {
    el.select();
    el.setSelectionRange(0, text.length);
    ok = document.execCommand("copy");
  } catch {
    ok = false;
  }
  el.remove();
  // Restoring the caret matters more than it looks: without it a copy from
  // CODE leaves the editor blurred and the next keystroke goes nowhere.
  try {
    was?.focus?.();
  } catch {
    /* the element went away while we held it */
  }
  return ok;
}

export async function copyText(text: string): Promise<ClipResult> {
  if (!text) return { ok: false, why: "empty" };
  const clip = api();
  if (clip?.writeText) {
    try {
      await clip.writeText(text);
      return { ok: true, text };
    } catch (e) {
      // Fall through: a refusal from the async API is not proof the old one
      // will be refused too, and trying costs nothing.
      if (copyByExec(text)) return { ok: true, text };
      return { ok: false, why: reason(e) };
    }
  }
  return copyByExec(text) ? { ok: true, text } : { ok: false, why: "unsupported" };
}

export async function readText(): Promise<ClipResult> {
  const clip = api();
  if (!clip?.readText) return { ok: false, why: "unsupported" };
  try {
    const text = await clip.readText();
    if (!text) return { ok: false, why: "empty" };
    return { ok: true, text };
  } catch (e) {
    return { ok: false, why: reason(e) };
  }
}

/**
 * What to tell the player, from a result and the name of the thing.
 *
 * Kept here rather than at each call site so that five buttons cannot end up
 * with five different wordings for the same refusal — and so the strings are
 * in one place when they are translated.
 */
export function clipMessage(
  what: string,
  res: ClipResult,
  verb: "copy" | "paste",
): { text: string; notice: boolean } {
  if (res.ok) {
    return verb === "copy"
      ? { text: t("clip.copied", { what }), notice: true }
      : { text: t("clip.pasted"), notice: true };
  }
  switch (res.why) {
    case "empty":
      return verb === "copy"
        ? { text: t("clip.nothingToCopy", { what }), notice: true }
        : { text: t("clip.emptyClipboard"), notice: true };
    case "denied":
      return {
        text: verb === "copy" ? t("clip.copyDenied") : t("clip.pasteDenied"),
        notice: false,
      };
    case "unsupported":
      // Writing has a fallback; **reading has none** — `execCommand("paste")`
      // is refused by every browser, on purpose. So on a page where this
      // happens the honest thing is to name the key that does work, since the
      // editor is a real text field and the browser will paste into it.
      return {
        text: verb === "copy" ? t("clip.unsupported") : t("clip.pasteByKey"),
        notice: false,
      };
    default:
      return { text: t("clip.silent"), notice: false };
  }
}
