/**
 * What a `playground.updated` from another of this user's connections
 * (PROTOCOL §4.22) means for the pad on this screen.
 *
 *   * `ignore`: a different pad, or none held. The list may want refreshing;
 *     the editor does not.
 *   * `apply`: this pad, and nothing unsaved here — take the saved text.
 *   * `ask`: this pad, but there is unsaved typing here. Leave the buffer
 *     alone and ask which to keep — the other device's save, or this text
 *     saved over it. Replacing text under somebody's fingers without asking
 *     is the one thing this must never do, and neither is quietly letting
 *     the next autosave from here throw the other device's work away.
 */
export function remoteSaveAction(
  heldId: string | null,
  snippetId: string,
  dirty: boolean,
): "ignore" | "apply" | "ask" {
  if (heldId === null || heldId !== snippetId) return "ignore";
  return dirty ? "ask" : "apply";
}
