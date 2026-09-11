/**
 * Addresses: keccak, EIP-55, and the two spellings a wallet address has.
 *
 * SPEC §3.4 is emphatic that the lowercase form is the identity and the
 * checksummed form is decoration, because on a case-insensitive filesystem two
 * spellings of one wallet would share a directory while owning two database
 * rows. Everything here therefore returns the pair, never one of them alone.
 */
import { keccak_256 } from "@noble/hashes/sha3.js";

export interface Address {
  /** The identity: lowercase `0x` + 40 hex. This is what goes on the wire. */
  lower: string;
  /** EIP-55 mixed case, for display only. */
  eip55: string;
}

export function toHex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

export function fromHex(hex: string): Uint8Array {
  const s = hex.startsWith("0x") || hex.startsWith("0X") ? hex.slice(2) : hex;
  if (s.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(s)) throw new Error("not hex");
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.slice(i * 2, i * 2 + 2), 16);
  return out;
}

/**
 * EIP-55: hash the *lowercase hex digits* (not the bytes, not the `0x`) and
 * upper-case a letter wherever the matching nibble is >= 8. Getting the
 * direction of that comparison wrong still produces a plausible-looking
 * address, which is why the all-lowercase reference vectors are in the tests.
 */
export function toEip55(address: string): string {
  const lower = address.toLowerCase().replace(/^0x/, "");
  if (!/^[0-9a-f]{40}$/.test(lower)) throw new Error("not a 20-byte address");
  const hash = toHex(keccak_256(new TextEncoder().encode(lower)));
  let out = "0x";
  for (let i = 0; i < 40; i++) {
    const c = lower[i];
    out += parseInt(hash[i], 16) >= 8 ? c.toUpperCase() : c;
  }
  return out;
}

/** An uncompressed secp256k1 public key (65 bytes, `0x04` lead) as an address. */
export function addressFromPublicKey(pubUncompressed: Uint8Array): Address {
  if (pubUncompressed.length !== 65 || pubUncompressed[0] !== 0x04) {
    throw new Error("expected a 65-byte uncompressed public key");
  }
  const hash = keccak_256(pubUncompressed.subarray(1));
  const lower = "0x" + toHex(hash.subarray(12));
  return { lower, eip55: toEip55(lower) };
}

export function normalizeAddress(address: string): Address {
  const lower = address.toLowerCase();
  if (!/^0x[0-9a-f]{40}$/.test(lower)) throw new Error("not an address");
  return { lower, eip55: toEip55(lower) };
}
