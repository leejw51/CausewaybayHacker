/**
 * The key, and the only two things anyone is allowed to ask it for.
 *
 * SPEC §3.1: the mnemonic and the private key never leave the browser — not
 * over the websocket, not into a log, not into `localStorage`. The way that is
 * enforced here is structural rather than by discipline: the secret lives in a
 * module-local variable, no export returns it, and nothing a scene can reach
 * holds a reference to it. A scene gets an `Address` and can ask for a
 * signature; that is the whole surface.
 *
 * The derivation is `CausewaybayWallet`'s EVM account 0, verbatim
 * (`rustcli/core/src/bip32.rs` + `bip39.rs`): BIP-39 seed, BIP-32 over
 * secp256k1, `m/44'/60'/0'/0/i`, keccak256 of the uncompressed public key
 * without its `0x04` lead, last twenty bytes, EIP-55 for display. A drift here
 * reads to a user as losing their account, so it is pinned by the vectors in
 * `tests/wallet.test.ts`.
 */
import { HDKey } from "@scure/bip32";
import { generateMnemonic, mnemonicToSeedSync, validateMnemonic } from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";
import { secp256k1 } from "@noble/curves/secp256k1.js";
import { keccak_256 } from "@noble/hashes/sha3.js";
import { addressFromPublicKey, fromHex, toHex, type Address } from "./address";

/** `CausewaybayWallet`'s EVM path. The `i` is the account index. */
export const EVM_PATH = (index = 0) => `m/44'/60'/0'/0/${index}`;

/**
 * The largest account index the path's last element can hold. It is a
 * non-hardened child, so it runs to 2^31 - 1.
 */
export const MAX_ACCOUNT_INDEX = 2147483647;

/**
 * Read an account index out of whatever is in a text box.
 *
 * Lives here rather than in the login screen because it is the other half of
 * `EVM_PATH`: the number this returns is the number that goes into the path,
 * and its edge cases are all the ways a text box fails to be a number. Every
 * one of them resolves to **an index**, never to a throw — a person midway
 * through clearing the box to type a new number is not making an error, and a
 * login screen that reported one would be shouting at them for backspacing.
 *
 * Empty, blank, or not a number at all is account 0, which is the account
 * somebody who never thought about this is asking for. Anything past the end
 * of the path is clamped rather than wrapped, so a pasted twenty-digit number
 * derives the last real account instead of silently becoming `Infinity` — or,
 * worse, wrapping round to a different one.
 */
export function parseAccountIndex(raw: string): number {
  const n = Number.parseInt(raw.trim(), 10);
  if (!Number.isFinite(n) || n < 0) return 0;
  return Math.min(n, MAX_ACCOUNT_INDEX);
}

/**
 * Derive without keeping anything. Used by the tests and by the login screen's
 * "this is the address you are about to log in as" preview.
 */
export function addressFromMnemonic(phrase: string, index = 0, passphrase = ""): Address {
  return addressFromPrivateKeyBytes(privateKeyFromMnemonic(phrase, index, passphrase));
}

export function addressFromPrivateKeyHex(hex: string): Address {
  const key = fromHex(hex);
  if (key.length !== 32) throw new Error("a private key is 32 bytes");
  return addressFromPrivateKeyBytes(key);
}

function addressFromPrivateKeyBytes(key: Uint8Array): Address {
  return addressFromPublicKey(secp256k1.getPublicKey(key, false));
}

/** The seed → path → scalar half of the diagram in SPEC §3.1. */
function privateKeyFromMnemonic(phrase: string, index: number, passphrase: string): Uint8Array {
  const normalized = normalizeMnemonic(phrase);
  if (!validateMnemonic(normalized, wordlist)) throw new Error("that is not a valid seed phrase");
  const seed = mnemonicToSeedSync(normalized, passphrase);
  const node = HDKey.fromMasterSeed(seed).derive(EVM_PATH(index));
  if (!node.privateKey) throw new Error("derivation produced no private key");
  return node.privateKey;
}

/**
 * BIP-39 normalizes with NFKD and single spaces. A phrase pasted out of a
 * password manager routinely arrives with a newline or a double space in it,
 * and refusing that is a support question rather than a security property.
 */
export function normalizeMnemonic(phrase: string): string {
  return (
    phrase
      .normalize("NFKD")
      // Zero-width joiners and byte-order marks ride along with text copied
      // out of chat apps and notes; they are not part of any word.
      .replace(/[\u200b-\u200d\ufeff]/g, "")
      // The English list is lowercase. A phrase pasted out of a note that
      // capitalised its first word is the same phrase.
      .toLowerCase()
      .trim()
      .split(/\s+/u)
      .join(" ")
  );
}

/**
 * Why a phrase is not a phrase, as one sentence's worth of fact, or null
 * when it is one. `word` is the first word that is not in the list; `count`
 * is a word count that no phrase has; `checksum` is twelve (or more) real
 * words in an order that does not check out — one is wrong or misplaced.
 *
 * For the login card, which used to answer a wrong phrase with a dash and
 * nothing else — and a person who had one word wrong could not tell that
 * from a screen that had stopped working.
 */
export function phraseProblem(
  phrase: string,
): { kind: "word"; word: string } | { kind: "count"; count: number } | { kind: "checksum" } | null {
  const words = normalizeMnemonic(phrase)
    .split(" ")
    .filter((w) => w !== "");
  const bad = words.find((w) => !wordlist.includes(w));
  if (bad !== undefined) return { kind: "word", word: bad };
  if (![12, 15, 18, 21, 24].includes(words.length)) return { kind: "count", count: words.length };
  if (!validateMnemonic(words.join(" "), wordlist)) return { kind: "checksum" };
  return null;
}

/**
 * A private key as typed: `0x` or `0X` or no prefix, any case, with the
 * whitespace a paste across two lines leaves in it. Null when it is not one.
 */
export function privateKeyHexOf(text: string): string | null {
  const flat = text.replace(/[\s\u200b-\u200d\ufeff]/g, "");
  const m = /^(?:0[xX])?([0-9a-fA-F]{64})$/.exec(flat);
  return m ? "0x" + m[1].toLowerCase() : null;
}

/**
 * Twelve new words, from the browser's CSPRNG.
 *
 * The game had no way to make one of these, which meant a player who had never
 * run `CausewaybayWallet` had nothing to type into the only field on the only
 * screen they could reach. A seed phrase is the account (SPEC §3), so handing
 * one out *is* the sign-up.
 *
 * 128 bits, which is what twelve words carries; `@scure/bip39` draws it from
 * `crypto.getRandomValues` and nothing here reseeds or post-processes it. The
 * caller is expected to show it to exactly one person and then forget it — it
 * is never logged, never stored, and it does not go near the socket.
 */
export function newMnemonic(): string {
  return generateMnemonic(wordlist, 128);
}

// ---------------------------------------------------------------------------
// The held key. Nothing below returns it.
// ---------------------------------------------------------------------------

let secret: Uint8Array | null = null;
let held: Address | null = null;

/** Take a mnemonic or a `0x`-prefixed private key and hold the result. */
export function unlock(input: string, index = 0, passphrase = ""): Address {
  const hex = privateKeyHexOf(input);
  const key = hex ? fromHex(hex) : privateKeyFromMnemonic(input, index, passphrase);
  const address = addressFromPublicKey(secp256k1.getPublicKey(key, false));
  wipe();
  secret = key;
  held = address;
  return address;
}

/** The address currently unlocked, or null. Safe to hand to a scene. */
export function current(): Address | null {
  return held;
}

export function isUnlocked(): boolean {
  return secret !== null;
}

/**
 * Forget the key. Called on logout, and on every `unlock` so a second login
 * does not leave the first key lying in the heap any longer than it must.
 */
export function wipe(): void {
  if (secret) secret.fill(0);
  secret = null;
  held = null;
}

/**
 * EIP-191 `personal_sign`: keccak256 over
 * `"\x19Ethereum Signed Message:\n" + <byte length> + message`.
 *
 * The length is the message's **UTF-8 byte** count, not its character count.
 * An ASCII-only test suite never notices the difference; a Korean display name
 * in the message would, at the point where the server fails to recover the
 * address. Hence the emoji vector in the tests.
 */
export function eip191Hash(message: string): Uint8Array {
  const body = new TextEncoder().encode(message);
  const prefix = new TextEncoder().encode(`\x19Ethereum Signed Message:\n${body.length}`);
  const buf = new Uint8Array(prefix.length + body.length);
  buf.set(prefix, 0);
  buf.set(body, prefix.length);
  return keccak_256(buf);
}

/**
 * Sign the server's challenge. `0x` + 130 hex: `r || s || v`, with **v in
 * {27, 28}** — the Ethereum convention, not noble's 0/1 recovery bit. SPEC
 * §3.2 says "65-byte r||s||v" without pinning which, so this follows
 * `CausewaybayWallet`'s `testvectors/eip191.json`, whose signatures end in
 * `1b`/`1c`; see `docs/decisions.md`.
 *
 * `prehash: false` because the digest is already keccak — noble would
 * otherwise sha256 it, and the server would recover a stranger's address.
 */
export function signMessage(message: string): string {
  if (!secret) throw new Error("no key is unlocked");
  const hash = eip191Hash(message);
  return "0x" + toHex(signHash(hash, secret));
}

/**
 * Who signed `message` — the address behind an EIP-191 signature — or null
 * when the bytes are not a signature at all.
 *
 * The other half of `signMessage`, and the only verification the client
 * does: the poster's DISK READER hands it what a picture claims (source,
 * signature, address) and asks whether the claim holds. No key is needed and
 * none is touched, which is why it lives here beside the signer rather than
 * in the reader — the two encodings (`v` as 27/28, keccak over the prefixed
 * UTF-8 bytes) have to agree byte for byte, and one file is where they do.
 */
export function recoverSigner(message: string, signature: string): Address | null {
  let sig: Uint8Array;
  try {
    sig = fromHex(signature);
  } catch {
    return null;
  }
  if (sig.length !== 65) return null;
  const v = sig[64] >= 27 ? sig[64] - 27 : sig[64];
  if (v !== 0 && v !== 1) return null;
  try {
    const pub = secp256k1.Signature.fromBytes(sig.subarray(0, 64), "compact")
      .addRecoveryBit(v)
      .recoverPublicKey(eip191Hash(message))
      .toBytes(false);
    return addressFromPublicKey(pub);
  } catch {
    return null;
  }
}

/** Exported for the tests, which sign with a fixture key rather than unlocking. */
export function signHash(hash: Uint8Array, key: Uint8Array): Uint8Array {
  const recovered = secp256k1.sign(hash, key, { prehash: false, lowS: true, format: "recovered" });
  // noble's `recovered` format is `v || r || s` with v as the raw 0/1 bit.
  // Ethereum wants `r || s || v+27`, so the byte moves and gains 27.
  const out = new Uint8Array(65);
  out.set(recovered.subarray(1), 0);
  out[64] = recovered[0] + 27;
  return out;
}
