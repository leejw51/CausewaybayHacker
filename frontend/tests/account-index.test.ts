import { describe, expect, it } from "vitest";
import {
  EVM_PATH,
  MAX_ACCOUNT_INDEX,
  addressFromMnemonic,
  eip191Hash,
  parseAccountIndex,
  signMessage,
  unlock,
  wipe,
} from "../src/wallet/wallet";
import { addressFromPublicKey, fromHex } from "../src/wallet/address";
import { secp256k1 } from "@noble/curves/secp256k1.js";

/**
 * Recover the signer, the way the server does (PROTOCOL §3.2).
 *
 * Written out here rather than imported because the point is to check the
 * client's derivation against something that does **not** share its code path:
 * a test that asked the wallet module who signed would pass even if the index
 * never reached the key.
 */
function signerOf(message: string, signature: string): string {
  const bytes = fromHex(signature);
  const sig = secp256k1.Signature.fromBytes(bytes.slice(0, 64), "compact").addRecoveryBit(
    bytes[64] - 27,
  );
  const pub = sig.recoverPublicKey(eip191Hash(message)).toBytes(false);
  return addressFromPublicKey(pub).eip55;
}

/** BIP-39's published vector phrase, the one the other suites sign in with. */
const PHRASE = "legal winner thank year wave sausage worth useful legal winner thank yellow";

describe("reading an account index out of a text box", () => {
  it("takes the number somebody typed", () => {
    expect(parseAccountIndex("0")).toBe(0);
    expect(parseAccountIndex("7")).toBe(7);
    expect(parseAccountIndex("2147483647")).toBe(MAX_ACCOUNT_INDEX);
  });

  it("reads a box that is not a number yet as account 0, rather than as an error", () => {
    // Every one of these is somebody mid-edit, not somebody making a mistake.
    // A login screen that threw here would be shouting at them for backspacing.
    for (const raw of ["", "   ", "-", "abc", "-1", "-99"]) {
      expect(parseAccountIndex(raw)).toBe(0);
    }
  });

  it("clamps past the end of the path instead of wrapping or overflowing", () => {
    // The last element of the path is a non-hardened child, so 2^31 - 1 is the
    // end. A pasted twenty-digit number must land on the last real account —
    // not become Infinity, and above all not wrap round to a different one.
    expect(parseAccountIndex("99999999999999999999")).toBe(MAX_ACCOUNT_INDEX);
    expect(parseAccountIndex("2147483648")).toBe(MAX_ACCOUNT_INDEX);
    expect(Number.isSafeInteger(parseAccountIndex("1e400"))).toBe(true);
  });

  it("ignores trailing rubbish the way parseInt does, so a stray keystroke still derives", () => {
    expect(parseAccountIndex("12abc")).toBe(12);
    expect(parseAccountIndex(" 3 ")).toBe(3);
  });

  it("puts the index it returns into the path", () => {
    expect(EVM_PATH(parseAccountIndex("11"))).toBe("m/44'/60'/0'/0/11");
  });
});

describe("unlock honours the account index", () => {
  it("holds the key for the account the login screen asked for", () => {
    // The screen previews with `addressFromMnemonic` and signs in with
    // `unlock`. If those two disagreed about the index, the address on the
    // card would not be the account you arrived as — the exact bug the box is
    // there to prevent.
    for (const index of [0, 1, 7, 11]) {
      expect(unlock(PHRASE, index).eip55).toBe(addressFromMnemonic(PHRASE, index).eip55);
    }
    wipe();
  });

  it("signs as the indexed account, so the server sees that address", () => {
    // The whole round trip: derive at an index, sign the kind of challenge
    // §3.2 sends, and recover. The recovered address is what the server
    // authenticates as, so this is the assertion that the index actually
    // reaches the account rather than only the preview text.
    const message = "Causewaybay Hacker login\nnonce: " + "ab".repeat(32);
    const want = unlock(PHRASE, 7);
    expect(signerOf(message, signMessage(message))).toBe(want.eip55);
    // …and account 0 of the same phrase is a different signer, so the
    // assertion above is not passing by accident.
    const zero = unlock(PHRASE, 0);
    expect(signerOf(message, signMessage(message))).toBe(zero.eip55);
    expect(zero.eip55).not.toBe(want.eip55);
    wipe();
  });

  it("gives different accounts different addresses", () => {
    const seen = new Set([0, 1, 2, 7, 11].map((i) => addressFromMnemonic(PHRASE, i).eip55));
    expect(seen.size).toBe(5);
  });

  it("ignores the index for a raw private key, which is already an account", () => {
    const key = "0x" + "11".repeat(32);
    expect(unlock(key, 0).eip55).toBe(unlock(key, 9).eip55);
    wipe();
  });
});
