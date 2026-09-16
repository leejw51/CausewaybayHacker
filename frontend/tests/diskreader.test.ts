/**
 * DISK READER: a poster back into a pad, and its claim checked.
 *
 * The chunks path is fed a PNG built here with `withPngText`; the label path
 * is fed the payload text `qrPayload` makes, since decoding pixels needs a
 * canvas and `jsQR`'s own suite covers that. What is asserted is the part
 * that matters: a signature recovers to the address it sits next to, or the
 * verdict says so.
 */
import { describe, expect, it } from "vitest";
import { fromHex, toHex } from "../src/wallet/address";
import { eip191Hash, recoverSigner, signHash } from "../src/wallet/wallet";
import { crc32, qrPayload, withPngText } from "../src/ui/poster";
import { fromChunks, fromLabel, isPng, judge, proveDisk, readDisk } from "../src/ui/diskreader";

const KEY = fromHex("0x4646464646464646464646464646464646464646464646464646464646464646");
const ADDR = "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F";
const SRC = 'fn main() {\n    println!("héllo 🌏");\n}\n';
const SIG = "0x" + toHex(signHash(eip191Hash(SRC), KEY));

function chunk(type: string, data: Uint8Array): Uint8Array {
  const t = new TextEncoder().encode(type);
  const c = new Uint8Array(12 + data.length);
  new DataView(c.buffer).setUint32(0, data.length);
  c.set(t, 4);
  c.set(data, 8);
  const over = new Uint8Array(4 + data.length);
  over.set(t, 0);
  over.set(data, 4);
  new DataView(c.buffer).setUint32(8 + data.length, crc32(over));
  return c;
}
function tinyPng(): Uint8Array {
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  const ihdr = chunk("IHDR", new Uint8Array(13));
  const iend = chunk("IEND", new Uint8Array(0));
  const out = new Uint8Array(8 + ihdr.length + iend.length);
  out.set(sig, 0);
  out.set(ihdr, 8);
  out.set(iend, 8 + ihdr.length);
  return out;
}

describe("recovering the signer", () => {
  it("finds the fixture key's address behind its signature", () => {
    expect(recoverSigner(SRC, SIG)?.eip55).toBe(ADDR);
  });
  it("finds somebody else behind a signature over different text", () => {
    expect(recoverSigner(SRC + " ", SIG)?.eip55).not.toBe(ADDR);
  });
  it("returns null for bytes that are not a signature", () => {
    expect(recoverSigner(SRC, "0x1234")).toBeNull();
    expect(recoverSigner(SRC, "not hex")).toBeNull();
    expect(recoverSigner(SRC, "0x" + "00".repeat(64) + "1d")).toBeNull();
  });
});

describe("the verdict", () => {
  it("is verified when the signature recovers to the named address", () => {
    expect(judge(SRC, ADDR, SIG)).toBe("verified");
    expect(judge(SRC, ADDR.toLowerCase(), SIG)).toBe("verified");
  });
  it("is forged when it recovers to anyone else", () => {
    expect(judge(SRC + "\n", ADDR, SIG)).toBe("forged");
    expect(judge(SRC, "0x0000000000000000000000000000000000000000", SIG)).toBe("forged");
  });
  it("is unsigned with no signature", () => {
    expect(judge(SRC, ADDR, null)).toBe("unsigned");
  });
});

describe("reading the file's chunks", () => {
  it("takes the program, the author and the verdict off our PNG", () => {
    const png = withPngText(tinyPng(), {
      Title: "word tally",
      Source: SRC,
      Lang: "rust",
      Signer: ADDR,
      Signature: SIG,
    });
    const disk = fromChunks(png);
    expect(disk).toMatchObject({
      source: SRC,
      lang: "rust",
      address: ADDR,
      signature: SIG,
      title: "word tally",
      via: "chunks",
      verdict: "verified",
    });
  });
  it("reads an unsigned poster as unsigned", () => {
    const png = withPngText(tinyPng(), { Source: SRC, Signer: ADDR, Lang: "go" });
    expect(fromChunks(png)).toMatchObject({ verdict: "unsigned", lang: "go", signature: null });
  });
  it("has nothing to say about a PNG that is not ours, or a file that is not a PNG", () => {
    expect(fromChunks(tinyPng())).toBeNull();
    expect(fromChunks(new Uint8Array([1, 2, 3]))).toBeNull();
    expect(isPng(tinyPng())).toBe(true);
    expect(isPng(new Uint8Array(20))).toBe(false);
  });
});

describe("reading the label", () => {
  it("takes the program and the verdict off the QR's text", () => {
    const { text } = qrPayload(ADDR, SIG, "rust", SRC);
    expect(fromLabel(text)).toMatchObject({
      source: SRC,
      address: ADDR,
      via: "label",
      verdict: "verified",
    });
  });
  it("calls a doctored program forged", () => {
    const { text } = qrPayload(ADDR, SIG, "rust", SRC.replace("héllo", "hello"));
    expect(fromLabel(text)?.verdict).toBe("forged");
  });
  it("knows when the label holds only a hash", () => {
    const { text, hashed } = qrPayload(ADDR, SIG, "python", "x".repeat(3000));
    expect(hashed).toBe(true);
    expect(fromLabel(text)).toMatchObject({ verdict: "hashed", source: "", lang: "python" });
  });
  it("refuses text that is not a label", () => {
    expect(fromLabel("https://example.com")).toBeNull();
  });
});

describe("readDisk", () => {
  it("prefers the chunks and never asks for pixels when it has them", async () => {
    const png = withPngText(tinyPng(), { Source: SRC, Signer: ADDR, Signature: SIG });
    let asked = false;
    const disk = await readDisk(png, async () => {
      asked = true;
      return null;
    });
    expect(disk?.via).toBe("chunks");
    expect(asked).toBe(false);
  });
  it("falls back to the pixels, and gives up when there are none", async () => {
    expect(await readDisk(new Uint8Array([0xff, 0xd8]), async () => null)).toBeNull();
  });
});

describe("proving a poster before it is saved", () => {
  const png = withPngText(tinyPng(), { Source: SRC, Lang: "rust", Signer: ADDR, Signature: SIG });
  const label = qrPayload(ADDR, SIG, "rust", SRC).text;

  it("passes a poster whose three claims agree", () => {
    expect(proveDisk(png, label, SRC, ADDR, SIG)).toBeNull();
  });
  it("passes an unsigned poster that says so everywhere", () => {
    const upng = withPngText(tinyPng(), { Source: SRC, Lang: "rust", Signer: ADDR });
    expect(proveDisk(upng, qrPayload(ADDR, null, "rust", SRC).text, SRC, ADDR, null)).toBeNull();
  });
  it("names the signature when it does not recover to the address", () => {
    expect(proveDisk(png, label, SRC, "0x0000000000000000000000000000000000000000", SIG)).toBe(
      "signature",
    );
  });
  it("names the chunks when the file does not carry this program", () => {
    const other = withPngText(tinyPng(), { Source: SRC + "//", Signer: ADDR, Signature: SIG });
    expect(proveDisk(other, label, SRC, ADDR, SIG)).toBe("chunks");
    expect(proveDisk(tinyPng(), label, SRC, ADDR, SIG)).toBe("chunks");
  });
  it("names the label when the pixels decode to nothing, or to something else", () => {
    expect(proveDisk(png, null, SRC, ADDR, SIG)).toBe("label");
    expect(proveDisk(png, qrPayload(ADDR, SIG, "rust", SRC + " ").text, SRC, ADDR, SIG)).toBe(
      "label",
    );
    expect(proveDisk(png, "https://example.com", SRC, ADDR, SIG)).toBe("label");
  });
  it("accepts a hashed label only for the program it hashes", () => {
    const long = "y".repeat(3000);
    const lsig = "0x" + toHex(signHash(eip191Hash(long), KEY));
    const lpng = withPngText(tinyPng(), { Source: long, Signer: ADDR, Signature: lsig });
    const llabel = qrPayload(ADDR, lsig, "rust", long).text;
    expect(proveDisk(lpng, llabel, long, ADDR, lsig)).toBeNull();
    expect(proveDisk(lpng, qrPayload(ADDR, lsig, "rust", long + "z").text, long, ADDR, lsig)).toBe(
      "label",
    );
  });
});
