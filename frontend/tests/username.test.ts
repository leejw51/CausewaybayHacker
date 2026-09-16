import { describe, expect, it } from "vitest";
import { ADJECTIVES, NOUNS, deterministicUsername } from "../src/wallet/username";

/**
 * The same four vectors `backend/core/src/username.rs` carries, and for the
 * same reason: the login box shows a name before there is an account to ask
 * about, so if these two implementations drift the box promises a name the
 * server then disagrees with. Two of the four are the wallets the other tests
 * here already sign in as.
 */
const VECTORS: ReadonlyArray<readonly [string, string]> = [
  ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", "OmegaMustang0198"],
  ["0x70997970C51812dc3A010C7d01b50e0d17dc79C8", "AmberLion9030"],
  ["0x9858effd232b4033e47d90003d41ec34ecaeda94", "AmberEnchanter2784"],
  ["0x7e5f4552091a69125d5dfcb7b8c2659029395bdf", "AmberRunner7074"],
];

describe("deterministic usernames", () => {
  it("carries the reference word lists, at the reference lengths", () => {
    // The lengths are the modulus, so they are part of the contract.
    expect(ADJECTIVES.length).toBe(152);
    expect(NOUNS.length).toBe(156);
  });

  it("agrees with the server and with the reference implementation", () => {
    for (const [address, want] of VECTORS) {
      expect(deterministicUsername(address)).toBe(want);
    }
  });

  it("does not let the casing of the address change the name", () => {
    expect(deterministicUsername("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266")).toBe(
      deterministicUsername("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
    );
  });

  it("always produces a name the server's 48-character column will take", () => {
    for (let i = 0; i < 256; i++) {
      const name = deterministicUsername("0x" + i.toString(16).padStart(40, "0"));
      expect(name.length).toBeLessThanOrEqual(48);
      expect(name).toMatch(/^[A-Za-z]+[0-9]{4}$/);
    }
  });
});
