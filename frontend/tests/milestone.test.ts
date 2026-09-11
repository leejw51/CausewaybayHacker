/**
 * `unavailable` is not `internal`, and the difference is the whole screen.
 *
 * PROTOCOL §3.3 spends a paragraph on this: a feature that is real, specified
 * and merely unbuilt answers `unavailable` with `detail.milestone`, and a client
 * that reports it as `internal` "tells the player their machine is broken and
 * invites them to retry something that will never work". Both of FE2's new
 * server-backed screens open on that path today, so the detector is the first
 * thing worth pinning.
 *
 * The second case is the one that will actually catch a regression: `asError`
 * folds a code it does not know to `internal` and keeps the original in
 * `detail.unknown_code`, spreading the rest of `detail` alongside it. A client
 * whose `ERROR_CODES` has not been updated therefore still has everything it
 * needs — and the detector has to find it there too, or the screens quietly go
 * back to saying "the server broke" the next time this file is merged.
 */
import { describe, expect, it } from "vitest";
import { WireError } from "../src/net/client";
import { asError } from "../src/net/codec";
import { unbuilt, unbuiltLine } from "../src/net/milestone";
import { ERROR_CODES, playerText, actionFor } from "../src/net/protocol";

/** Exactly what the live server sent when probed on 2026-09-11. */
const FROM_THE_WIRE = {
  code: "unavailable",
  message: "search (SPEC §8) is not in this build yet",
  detail: { milestone: 2 },
};

describe("the unavailable detector", () => {
  it("finds it when the code survives", () => {
    const e = new WireError(asError(FROM_THE_WIRE));
    expect(e.payload.code).toBe("unavailable");
    const gap = unbuilt(e);
    expect(gap).not.toBeNull();
    expect(gap?.milestone).toBe(2);
    expect(gap?.developerMessage).toBe("search (SPEC §8) is not in this build yet");
  });

  it("finds it when an older client has folded it to internal", () => {
    // What `asError` does with a code it does not know: the fold, plus the
    // original kept where it can be reported — and `detail` spread through.
    const folded = new WireError({
      code: "internal",
      message: FROM_THE_WIRE.message,
      detail: { unknown_code: "unavailable", milestone: 2 },
    });
    const gap = unbuilt(folded);
    expect(gap?.milestone).toBe(2);
  });

  it("says so even when the server did not name a milestone", () => {
    const e = new WireError({ code: "unavailable", message: "not yet", detail: {} });
    expect(unbuilt(e)?.milestone).toBeNull();
    expect(unbuiltLine("THE COACH", unbuilt(e)!)).toBe("THE COACH is still being built");
    expect(unbuiltLine("THE COACH", { milestone: 2, developerMessage: "" })).toBe(
      "THE COACH opens in chapter 2",
    );
  });

  it("is not fooled by a real fault", () => {
    for (const code of ["internal", "not_found", "rate_limited", "busy"] as const) {
      expect(unbuilt(new WireError({ code, message: "", detail: {} }))).toBeNull();
    }
    // A genuine internal error that happens to mention a milestone is still a
    // fault: the code is what decides, never the detail alone.
    expect(
      unbuilt(new WireError({ code: "internal", message: "", detail: { milestone: 2 } })),
    ).toBeNull();
    expect(unbuilt(new Error("not a wire error"))).toBeNull();
    expect(unbuilt(null)).toBeNull();
  });
});

describe("the closed code set now carries it", () => {
  it("has unavailable, and it is not internal", () => {
    expect(ERROR_CODES).toContain("unavailable");
    expect(playerText("unavailable")).not.toBe(playerText("internal"));
    expect(actionFor("unavailable")).toBe("next-chapter");
  });

  it("gives every code its own player-facing line", () => {
    // §3.3: "A client renders its own text from `code`." A code with no line of
    // its own would put the server's developer English on screen.
    for (const code of ERROR_CODES) {
      expect(playerText(code).length).toBeGreaterThan(0);
    }
  });
});
