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
import { crc32, packSource, qrPayload, withPngText } from "../src/ui/poster";
import {
  fromChunks,
  fromLabel,
  isPng,
  judge,
  parseLabel,
  proveDisk,
  readDisk,
} from "../src/ui/diskreader";

const KEY = fromHex("0x4646464646464646464646464646464646464646464646464646464646464646");
const ADDR = "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F";
const SRC = 'fn main() {\n    println!("héllo 🌏");\n}\n';

/**
 * The program off the poster this was built for: 628 bytes, four modules
 * over the cap as plain text, and the reason a JPEG of it had nothing to
 * open. Deflated it is well under.
 */
const LONG_SRC = [
  "use std::sync::mpsc::channel;",
  "use std::sync::Arc;",
  "use std::sync::Mutex;",
  "use std::thread;",
  "fn main() {",
  '    println!("hello, causewaybay");',
  "    let result = Arc::new(Mutex::new(Vec::<i32>::new()));",
  "    let result2 = result.clone();",
  "    let (tx, rx) = channel::<i32>();",
  "    let producer = thread::spawn(move || {",
  "        for i in 1..11 {",
  "            tx.send(i).unwrap();",
  "        }",
  "    });",
  "    let consumer = thread::spawn(move || {",
  "        for r in rx {",
  "            result2.lock().unwrap().push(r);",
  "        }",
  "    });",
  "    producer.join().unwrap();",
  "    consumer.join().unwrap();",
  '    println!("result {:?}", result.lock().unwrap());',
  "}",
  "",
].join("\n");
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
  it("takes the program and the verdict off the QR's text", async () => {
    const { text } = qrPayload(ADDR, SIG, "rust", SRC);
    expect(await fromLabel(text)).toMatchObject({
      source: SRC,
      address: ADDR,
      via: "label",
      verdict: "verified",
    });
  });
  it("calls a doctored program forged", async () => {
    const { text } = qrPayload(ADDR, SIG, "rust", SRC.replace("héllo", "hello"));
    expect((await fromLabel(text))?.verdict).toBe("forged");
  });
  it("knows when the label holds only a hash", async () => {
    const { text, hashed } = qrPayload(ADDR, SIG, "python", "x".repeat(3000));
    expect(hashed).toBe(true);
    expect(await fromLabel(text)).toMatchObject({ verdict: "hashed", source: "", lang: "python" });
  });
  it("inflates a deflated label back to the program, and judges that", async () => {
    // Long enough that the plain text is over the cap, real enough to
    // compress: this is the shape of program the label used to hash.
    const long = LONG_SRC;
    const lsig = "0x" + toHex(signHash(eip191Hash(long), KEY));
    const { text, hashed } = qrPayload(ADDR, lsig, "rust", long, await packSource(long));
    expect(hashed).toBe(false);
    expect(parseLabel(text)?.kind).toBe("deflate");
    expect(await fromLabel(text)).toMatchObject({
      source: long,
      verdict: "verified",
      lang: "rust",
    });
    // The same label with another address named on it: the signature does
    // not recover to it, and inflating did nothing to hide that.
    const other = text.replace(ADDR, "0x0000000000000000000000000000000000000000");
    expect((await fromLabel(other))?.verdict).toBe("forged");
  });
  it("is no disk at all when the deflated body will not inflate", async () => {
    expect(await fromLabel(`CWBH1\n${ADDR}\n${SIG}\nrust\ndeflate:not base64!`)).toBeNull();
    expect(await fromLabel(`CWBH1\n${ADDR}\n${SIG}\nrust\ndeflate:AAAA`)).toBeNull();
  });
  it("refuses text that is not a label", async () => {
    expect(await fromLabel("https://example.com")).toBeNull();
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
  it("accepts a deflated label only for the program it deflates", async () => {
    const long = LONG_SRC;
    const lsig = "0x" + toHex(signHash(eip191Hash(long), KEY));
    const lpng = withPngText(tinyPng(), { Source: long, Signer: ADDR, Signature: lsig });
    const packed = await packSource(long);
    const llabel = qrPayload(ADDR, lsig, "rust", long, packed).text;
    expect(parseLabel(llabel)?.kind).toBe("deflate");
    expect(proveDisk(lpng, llabel, long, ADDR, lsig, packed)).toBeNull();
    const otherLabel = qrPayload(ADDR, lsig, "rust", long + "z", await packSource(long + "z")).text;
    expect(proveDisk(lpng, otherLabel, long, ADDR, lsig, packed)).toBe("label");
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
