/**
 * What a `playground.updated` from another of this user's connections
 * (PROTOCOL §4.22) means for the pad on this screen.
 *
 *   * `ignore`: a different pad, or none held. The list may want refreshing;
 *     the editor does not.
 *   * `apply`: this pad, and nothing unsaved here — take the saved text.
 *   * `notify`: this pad, but there is unsaved typing here. Say so and leave
 *     the buffer alone: the other device saved first, this one saves next,
 *     and the last save wins. Replacing text under somebody's fingers is the
 *     one thing this must never do.
 */
export function remoteSaveAction(
  heldId: string | null,
  snippetId: string,
  dirty: boolean,
): "ignore" | "apply" | "notify" {
  if (heldId === null || heldId !== snippetId) return "ignore";
  return dirty ? "notify" : "apply";
}
