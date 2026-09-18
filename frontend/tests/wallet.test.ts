/**
 * SPEC §9.1 and §9.2, the frontend half.
 *
 * The vectors are copied inline with their provenance rather than read across
 * repositories at test time, so the suite still runs in a checkout that only
 * has this one. Each was checked against `CausewaybayWallet`'s own
 * `testvectors/` — `derivation.json`, `eip55.json`, `eip191.json` — and the
 * two mnemonics are independently well known (the BIP-39 all-zero-entropy
 * phrase, and Anvil's default), so a drift is visible without trusting either
 * generator.
 *
 * If `tests/vectors/` (QA's, shared with the backend) gains the same table,
 * these should be read from there instead.
 */
import { describe, expect, it } from "vitest";
import { fromHex, toEip55, toHex } from "../src/wallet/address";
import {
  addressFromMnemonic,
  addressFromPrivateKeyHex,
  eip191Hash,
  forget,
  isUnlocked,
  keep,
  KEY_SLOT,
  LAST_ADDRESS,
  lastAddress,
  newMnemonic,
  normalizeMnemonic,
  recall,
  signHash,
  signMessage,
  unlock,
  wipe,
  type KeyStore,
} from "../src/wallet/wallet";

const BIP39_CANONICAL =
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const ANVIL = "test test test test test test test test test test test junk";

describe("EIP-55 checksum", () => {
  // The reference addresses from EIP-55 itself. The last two are the ones that
  // matter: their checksummed form is all lowercase, so an inverted `>= 8`
  // comparison passes every mixed-case row and fails only here.
  const vectors: Array<[string, string]> = [
    ["0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed", "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"],
    ["0xfb6916095ca1df60bb79ce92ce3ea74c37c5d359", "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"],
    ["0x52908400098527886e0f7030069857d2e4169ee7", "0x52908400098527886E0F7030069857D2E4169EE7"],
    ["0xde709f2102306220921060314715629080e2fb77", "0xde709f2102306220921060314715629080e2fb77"],
    ["0x27b1fdb04752bbc536007a920d24acb045561c26", "0x27b1fdb04752bbc536007a920d24acb045561c26"],
  ];
  for (const [lower, checksummed] of vectors) {
    it(`checksums ${lower.slice(0, 10)}…`, () => {
      expect(toEip55(lower)).toBe(checksummed);
      // Idempotent: feeding the checksummed form back must not disturb it.
      expect(toEip55(checksummed)).toBe(checksummed);
    });
  }
});

describe("m/44'/60'/0'/0/i, as CausewaybayWallet derives it", () => {
  it("derives account 0 of the BIP-39 canonical phrase", () => {
    const a = addressFromMnemonic(BIP39_CANONICAL);
    expect(a.eip55).toBe("0x9858EfFD232B4033E47d90003D41EC34EcaEda94");
    expect(a.lower).toBe("0x9858effd232b4033e47d90003d41ec34ecaeda94");
  });

  it("derives account 0 of Anvil's default mnemonic", () => {
    expect(addressFromMnemonic(ANVIL).eip55).toBe("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
  });

  it("walks the index, so account 1 is a different account", () => {
    expect(addressFromMnemonic(BIP39_CANONICAL, 1).eip55).toBe(
      "0x6Fac4D18c912343BF86fa7049364Dd4E424Ab9C0",
    );
    expect(addressFromMnemonic(ANVIL, 1).eip55).toBe("0x70997970C51812dc3A010C7d01b50e0d17dc79C8");
  });

  it("takes a BIP-39 passphrase, and it changes the address", () => {
    expect(addressFromMnemonic(BIP39_CANONICAL, 0, "TREZOR").eip55).toBe(
      "0x9c32F71D4DB8Fb9e1A58B0a80dF79935e7256FA6",
    );
  });

  it("accepts a raw private key as the alternative to a phrase (SPEC §3.1)", () => {
    expect(
      addressFromPrivateKeyHex("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
        .eip55,
    ).toBe("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    expect(
      addressFromPrivateKeyHex("0x0000000000000000000000000000000000000000000000000000000000000001")
        .eip55,
    ).toBe("0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf");
  });

  it("normalizes a phrase pasted with ragged whitespace", () => {
    expect(
      normalizeMnemonic(`  test test\ttest test test test\ntest test test test test junk `),
    ).toBe(ANVIL);
    expect(addressFromMnemonic(`  ${ANVIL.replace(/ /g, "  ")}\n`).eip55).toBe(
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    );
  });

  it("refuses a phrase whose checksum is wrong", () => {
    const bad = BIP39_CANONICAL.replace(/about$/, "abandon");
    expect(() => addressFromMnemonic(bad)).toThrow();
  });
});

describe("EIP-191, the shape SPEC §3.2 signs", () => {
  // eth-account's own `personal_sign` output for key 0x4646…46, the EIP-155
  // worked-example key. Copied from CausewaybayWallet testvectors/eip191.json.
  const KEY = "0x4646464646464646464646464646464646464646464646464646464646464646";
  const vectors: Array<{ message: string; hash: string; signature: string }> = [
    {
      message: "",
      hash: "0x5f35dce98ba4fba25530a026ed80b2cecdaa31091ba4958b99b52ea1d068adad",
      signature:
        "0xff65394fc6cc70eee8e5ee1160dfa355a0484ad2988b65d01aee4bf58288958f" +
        "082ce5e2c2d9d49130a2b1e8d01850cc00b0f17637f029570420e5a4a8d724fd1c",
    },
    {
      message: "hello causewaybay",
      hash: "0x6a556127adeed8ba203747f9b2c672d517e8cc78aff0e86d3567f820b361b25e",
      signature:
        "0x266cd28a93c665e11626eb16aecaeccd15999d21fc3f02e8343b815caa083918" +
        "39af4b1b1afb6e2ab7f10ff2106e9261c1a609234b5211b3e5fc8535ebf4d5041c",
    },
    {
      // The one that catches a length prefix counting characters: "héllo 🌏"
      // is 7 characters and 11 UTF-8 bytes.
      message: "héllo 🌏",
      hash: "0xa31126bf136986ada92f562eb02b055d544e2f92f79d0a7d9c0c543fc4590c73",
      signature:
        "0xe4a0e8f905d5655d02344ad288cb0c0c0467e70ac456bd145e069c5028af2b32" +
        "5bbf08afa354dfee5224e0524fdd28acdb5e52454311fad3df8131d51ddef9191b",
    },
  ];

  for (const v of vectors) {
    it(`hashes and signs ${JSON.stringify(v.message).slice(0, 24)}`, () => {
      expect("0x" + toHex(eip191Hash(v.message))).toBe(v.hash);
      // Deterministic RFC-6979 signing, so the hex is comparable byte for byte
      // — including the trailing v, which must be 0x1b or 0x1c and not 0/1.
      expect("0x" + toHex(signHash(eip191Hash(v.message), fromHex(KEY)))).toBe(v.signature);
    });
  }

  it("signs the real §3.2 challenge through the held key, and never exposes it", () => {
    const address = unlock(ANVIL);
    expect(address.eip55).toBe("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const message = [
      "Causewaybay Hacker login",
      `address: ${address.eip55}`,
      "nonce: " + "ab".repeat(32),
      "expires: 2026-09-11T04:14:33Z",
    ].join("\n");
    const sig = signMessage(message);
    expect(sig).toMatch(/^0x[0-9a-f]{130}$/);
    expect([27, 28]).toContain(parseInt(sig.slice(-2), 16));
    // Nothing the wallet module exports hands back key material.
    const surface = JSON.stringify(address);
    expect(surface).not.toContain("junk");
    wipe();
    expect(() => signMessage(message)).toThrow();
  });
});

describe("a phrase the game hands out", () => {
  it("is twelve words from the wordlist, and a different one each time", () => {
    const a = newMnemonic();
    const b = newMnemonic();
    expect(a.split(" ")).toHaveLength(12);
    expect(a).not.toBe(b);
    // If it were not valid BIP-39 the player could not log in with it, and if
    // it were not derivable it would not be an account.
    expect(() => addressFromMnemonic(a)).not.toThrow();
    expect(addressFromMnemonic(a).eip55).not.toBe(addressFromMnemonic(b).eip55);
  });

  it("is a real 128-bit draw, not a stub", () => {
    // Twenty phrases, sixty distinct words at the very least: a generator
    // stuck on one entropy source would fail this immediately.
    const words = new Set<string>();
    for (let i = 0; i < 20; i++) for (const w of newMnemonic().split(" ")) words.add(w);
    expect(words.size).toBeGreaterThan(60);
  });
});

describe("the kept key", () => {
  const ANVIL0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
  const ANVIL0_KEY = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

  function store(): KeyStore & { map: Map<string, string> } {
    const map = new Map<string, string>();
    return {
      map,
      getItem: (k) => map.get(k) ?? null,
      setItem: (k, v) => void map.set(k, v),
      removeItem: (k) => void map.delete(k),
    };
  }
  const hostile: KeyStore = {
    getItem() {
      throw new Error("site data is blocked");
    },
    setItem() {
      throw new Error("site data is blocked");
    },
    removeItem() {
      throw new Error("site data is blocked");
    },
  };

  it("keep writes the private key under the address, and notes the address", () => {
    const st = store();
    unlock(ANVIL);
    keep(st);
    wipe();
    expect(st.map.get(KEY_SLOT(ANVIL0))).toBe(ANVIL0_KEY);
    expect(st.map.get(LAST_ADDRESS)).toBe(ANVIL0.toLowerCase());
    expect(lastAddress(st)).toBe(ANVIL0.toLowerCase());
    // The slot is the lowercase address, whatever case was asked with.
    expect(st.map.has(KEY_SLOT(ANVIL0.toUpperCase()))).toBe(true);
  });

  it("keep with nothing unlocked writes nothing", () => {
    const st = store();
    wipe();
    keep(st);
    expect(st.map.size).toBe(0);
  });

  it("recall unlocks from the slot, and the signature is the account's", () => {
    const st = store();
    unlock(ANVIL);
    keep(st);
    wipe();
    expect(isUnlocked()).toBe(false);
    expect(recall(ANVIL0, st)).toBe(true);
    expect(isUnlocked()).toBe(true);
    const sig = signMessage("hello");
    // The same key the phrase derives to, byte for byte (RFC 6979 is deterministic).
    unlock(ANVIL);
    expect(signMessage("hello")).toBe(sig);
    wipe();
  });

  it("recall is false, and unlocks nothing, when there is no slot for the address", () => {
    const st = store();
    wipe();
    expect(recall(ANVIL0, st)).toBe(false);
    expect(isUnlocked()).toBe(false);
  });

  it("recall drops a slot that is not the address's own key", () => {
    const st = store();
    // Account 1's key filed under account 0's address: a hand-edited store.
    unlock(ANVIL, 1);
    const one = addressFromMnemonic(ANVIL, 1).lower;
    keep(st);
    wipe();
    st.map.set(KEY_SLOT(ANVIL0), st.map.get(KEY_SLOT(one))!);
    expect(recall(ANVIL0, st)).toBe(false);
    expect(isUnlocked()).toBe(false);
    expect(st.map.has(KEY_SLOT(ANVIL0))).toBe(false);
    // Garbage in the slot goes the same way.
    st.map.set(KEY_SLOT(ANVIL0), "not hex");
    expect(recall(ANVIL0, st)).toBe(false);
    expect(st.map.has(KEY_SLOT(ANVIL0))).toBe(false);
  });

  it("forget removes the kept key and the note, and wipes memory", () => {
    const st = store();
    unlock(ANVIL);
    keep(st);
    forget(st);
    expect(st.map.size).toBe(0);
    expect(isUnlocked()).toBe(false);
    expect(() => signMessage("x")).toThrow();
    // With nothing unlocked, the last address noted is what is forgotten.
    unlock(ANVIL);
    keep(st);
    wipe();
    forget(st);
    expect(st.map.size).toBe(0);
  });

  it("a store that throws leaves keep silent, recall false, forget still wiping", () => {
    unlock(ANVIL);
    expect(() => keep(hostile)).not.toThrow();
    expect(() => forget(hostile)).not.toThrow();
    expect(isUnlocked()).toBe(false);
    expect(recall(ANVIL0, hostile)).toBe(false);
    expect(lastAddress(hostile)).toBeNull();
    expect(recall(ANVIL0, null)).toBe(false);
    expect(() => keep(null)).not.toThrow();
  });

  it("two accounts keep two slots, and each recalls its own", () => {
    const st = store();
    unlock(ANVIL, 0);
    keep(st);
    unlock(ANVIL, 1);
    keep(st);
    wipe();
    const one = addressFromMnemonic(ANVIL, 1);
    expect(recall(ANVIL0, st)).toBe(true);
    expect(addressFromPrivateKeyHex("0x" + st.map.get(KEY_SLOT(ANVIL0))!).eip55).toBe(ANVIL0);
    expect(recall(one.eip55, st)).toBe(true);
    expect(addressFromPrivateKeyHex("0x" + st.map.get(KEY_SLOT(one.lower))!).eip55).toBe(one.eip55);
    expect(lastAddress(st)).toBe(one.lower);
    wipe();
  });
});
