/**
 * What the login field accepts, and what it says about what it does not.
 *
 * Reported from an iPad: a phrase pasted in, a dash under it, an empty name
 * box, and no way to tell a mistyped word from a screen that had stopped
 * working. (It was a mistyped word.) Two things follow. The parser forgives
 * what a paste does to text — capitals, line breaks, zero-width characters —
 * because none of those change which phrase it is. And a phrase that is all
 * there and still not a phrase is *explained*: which word, or how many, or
 * that the words are real and the order is not.
 */
import { describe, expect, it } from "vitest";
import {
  addressFromMnemonic,
  normalizeMnemonic,
  phraseProblem,
  privateKeyHexOf,
  unlock,
  wipe,
} from "../src/wallet/wallet";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const PHRASE =
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
/** The all-`abandon` phrase's account 0, from CausewaybayWallet's vectors. */
const ADDR = addressFromMnemonic(PHRASE).eip55;
const KEY = "0x4646464646464646464646464646464646464646464646464646464646464646";
const KEY_ADDR = "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F";

describe("a phrase as pasted", () => {
  it("is the same phrase with capitals, line breaks and double spaces", () => {
    const messy =
      "Abandon abandon abandon\nabandon  abandon abandon\r\nabandon abandon abandon abandon abandon About ";
    expect(normalizeMnemonic(messy)).toBe(PHRASE);
    expect(addressFromMnemonic(messy).eip55).toBe(ADDR);
  });

  it("drops the zero-width characters a chat app leaves in it", () => {
    const zw = PHRASE.replace(/ /g, "​ ﻿");
    expect(normalizeMnemonic(zw)).toBe(PHRASE);
    expect(phraseProblem(zw)).toBeNull();
  });
});

describe("a private key as pasted", () => {
  it("takes 0x, 0X, or no prefix, in either case", () => {
    expect(privateKeyHexOf(KEY)).toBe(KEY);
    expect(privateKeyHexOf(KEY.toUpperCase())).toBe(KEY);
    expect(privateKeyHexOf(KEY.slice(2))).toBe(KEY);
    expect(privateKeyHexOf(" " + KEY + "\n")).toBe(KEY);
  });

  it("survives a paste broken across two lines", () => {
    const broken = KEY.slice(0, 34) + "\n" + KEY.slice(34);
    expect(privateKeyHexOf(broken)).toBe(KEY);
    try {
      expect(unlock(broken).eip55).toBe(KEY_ADDR);
    } finally {
      wipe();
    }
  });

  it("is not a key when it is short, long, or not hex", () => {
    expect(privateKeyHexOf(KEY.slice(0, -2))).toBeNull();
    expect(privateKeyHexOf(KEY + "00")).toBeNull();
    expect(privateKeyHexOf("0x" + "g".repeat(64))).toBeNull();
    expect(privateKeyHexOf(PHRASE)).toBeNull();
  });
});

describe("why a phrase is not a phrase", () => {
  it("names the first word that is not in the list", () => {
    expect(phraseProblem(PHRASE.replace("about", "abuot"))).toEqual({
      kind: "word",
      word: "abuot",
    });
    expect(phraseProblem("Abandon abandon bananas " + PHRASE)).toEqual({
      kind: "word",
      word: "bananas",
    });
  });
  it("counts the words when there are the wrong number of them", () => {
    expect(phraseProblem(PHRASE + " abandon")).toEqual({ kind: "count", count: 13 });
    expect(phraseProblem("abandon abandon abandon")).toEqual({ kind: "count", count: 3 });
  });
  it("says so when every word is real and the phrase still does not check out", () => {
    // Twelve real words in an order that fails the checksum.
    expect(phraseProblem(PHRASE.replace("about", "abandon"))).toEqual({ kind: "checksum" });
  });
  it("has nothing to say about a real phrase", () => {
    expect(phraseProblem(PHRASE)).toBeNull();
    expect(phraseProblem("  " + PHRASE.toUpperCase() + "\n")).toBeNull();
  });
});

describe("the login card", () => {
  const SOURCE = readFileSync(resolve(process.cwd(), "src/scenes/login.ts"), "utf8");
  const body = SOURCE.slice(SOURCE.indexOf("private derivePreview("));
  const fn = body.slice(0, body.indexOf("\n  }\n"));

  it("derives through the forgiving parsers, not its own regex", () => {
    expect(fn).toContain("privateKeyHexOf(text)");
    expect(fn).toContain("phraseProblem(text)");
    expect(fn).not.toMatch(/\/\^0x\[0-9a-fA-F\]\{64\}\$\//);
  });

  it("explains a complete phrase that is not one, and stays quiet while it is being typed", () => {
    for (const k of ["login.notAWord", "login.wordCount", "login.badChecksum"])
      expect(fn).toContain(k);
    // Only once twelve words are there: half a phrase is not a mistake yet.
    expect(fn).toMatch(/words >= 12/);
  });
});
