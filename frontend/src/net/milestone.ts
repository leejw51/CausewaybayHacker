/**
 * "Real, specified, and not built yet" — told apart from "the server broke".
 *
 * PROTOCOL §3.3 is explicit that `unavailable` is **not** `internal`: a
 * feature that exists on paper and not yet in the build answers `unavailable`
 * with `detail.milestone`, and a client that reported it as a fault "tells the
 * player their machine is broken and invites them to retry something that will
 * never work". Today that is the whole of `search.query` and all three `ai.*`
 * calls, so every screen FE2 owns opens on this path and turns real the day the
 * endpoint does.
 *
 * The detector is deliberately tolerant in two directions, because the thing it
 * is detecting travels through a coercion:
 *
 *   - `code === "unavailable"`, which is what `net/codec.ts` produces once
 *     `unavailable` is in `ERROR_CODES`;
 *   - `detail.unknown_code === "unavailable"`, which is what `asError` produces
 *     on a client whose `ERROR_CODES` does not have it yet — it folds the code
 *     to `internal` and keeps what the server actually said, and it *spreads*
 *     `detail`, so `milestone` survives the fold.
 *
 * Both are checked so that this keeps working whichever of the two the shipped
 * `protocol.ts` happens to be. The alternative is a screen that silently
 * regresses to "the server broke — try again" after a merge, which is the exact
 * failure §3.3 was written to prevent.
 */
import { WireError } from "./client";

export interface Unbuilt {
  /** `detail.milestone`, when the server said which one. */
  milestone: number | null;
  /** The server's own one-line English, for the console and nowhere else. */
  developerMessage: string;
}

/** `null` when `e` is anything other than a "not built yet" answer. */
export function unbuilt(e: unknown): Unbuilt | null {
  if (!(e instanceof WireError)) return null;
  const { code, detail, message } = e.payload;
  const folded = detail.unknown_code;
  if (code !== "unavailable" && folded !== "unavailable") return null;
  const m = detail.milestone;
  return {
    milestone: typeof m === "number" && Number.isFinite(m) ? m : null,
    developerMessage: message,
  };
}

/**
 * What the player is told, in the story's voice.
 *
 * `feature` is a noun phrase this screen supplies — "the search index", "the
 * coach" — because §3.3 puts the player-facing words on the client's side of
 * the wire and the server's `message` is for a log.
 */
export function unbuiltLine(feature: string, u: Unbuilt): string {
  return u.milestone === null
    ? `${feature} is still being built`
    : `${feature} opens in chapter ${u.milestone}`;
}
