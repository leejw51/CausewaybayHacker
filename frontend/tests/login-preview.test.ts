import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { deterministicUsername } from "../src/wallet/username";

/**
 * The address on the login card and the name under it have to move together.
 *
 * They did not, and the bug was reported from the outside: pressing NEW WALLET
 * showed a fresh wallet with an empty name box. The cause was six separate
 * assignments to `this.preview` scattered through the scene, three of which
 * forgot the name — NEW WALLET, CLEAR and DISCARD. `mint()` was the worst of
 * them, because `derivePreview` deliberately bails while a minted phrase is up,
 * so the one screen that hands somebody a brand-new account was the one screen
 * that could not name it.
 *
 * The fix was to make `setPreview` the only way, and the fix only stays fixed
 * if nothing new writes the field directly. That is what this checks. It reads
 * the source rather than running the scene because the scene needs a canvas, an
 * App and three DOM overlays to exist at all, and none of that would make the
 * assertion any truer.
 */
// Resolved from the project root: vitest serves test files over a non-file
// URL, so `import.meta.url` is not a path here.
const SOURCE = readFileSync(resolve(process.cwd(), "src/scenes/login.ts"), "utf8");

describe("the login card's address and name", () => {
  it("is only ever assigned through setPreview", () => {
    const assignments = [...SOURCE.matchAll(/this\.preview\s*=/g)];
    // Exactly one: the line inside `setPreview` itself.
    expect(assignments).toHaveLength(1);
    const setter = SOURCE.slice(SOURCE.indexOf("private setPreview("));
    expect(setter.slice(0, 200)).toContain("this.preview = address");
  });

  it("has setPreview call refreshName, which is the whole point of it", () => {
    const body = SOURCE.slice(SOURCE.indexOf("private setPreview("));
    const end = body.indexOf("\n  }");
    expect(body.slice(0, end)).toContain("this.refreshName()");
  });

  it("refreshes the name from the address, and leaves a typed name alone", () => {
    const body = SOURCE.slice(SOURCE.indexOf("private refreshName("));
    const end = body.indexOf("\n  }");
    const fn = body.slice(0, end);
    // The guard that makes a typed name the player's own.
    expect(fn).toContain("this.nameTouched");
    // …and that the name comes from the address, not from the phrase: the
    // same wallet reached by phrase, by private key or at another index is one
    // account and has to arrive at one name.
    expect(fn).toContain("deterministicUsername(this.preview)");
  });

  it("names the wallet NEW WALLET just made", () => {
    // The reported bug, as an assertion about the code path that had it:
    // `mint` must go through the setter rather than assigning the preview.
    const body = SOURCE.slice(SOURCE.indexOf("private mint("));
    const fn = body.slice(0, body.indexOf("\n  }"));
    expect(fn).toContain("this.setPreview(addressFromMnemonic(");
  });

  it("derives a name for an address the way the server will", () => {
    // Belt and braces on the one pure thing in the chain, so a failure here
    // separates "the wiring broke" from "the algorithm drifted".
    expect(deterministicUsername("0x9858effd232b4033e47d90003d41ec34ecaeda94")).toBe(
      "AmberEnchanter2784",
    );
  });
});
