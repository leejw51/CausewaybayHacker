/**
 * The poster's arithmetic: pouring a program into a disc, fitting a column,
 * colouring from the grammar, the label's payload, the PNG text chunks, and
 * the proof the whole thing rests on — that the signature printed on it is
 * EIP-191 over the source and nothing else, so anyone with the picture can
 * recover the signer.
 *
 * Nothing here draws. The drawing needs a canvas and fonts; what is asserted
 * is everything the drawing is *told*.
 */
import { describe, expect, it } from "vitest";
import { secp256k1 } from "@noble/curves/secp256k1.js";
import { keccak_256 } from "@noble/hashes/sha3.js";
import { fromHex, toEip55, toHex } from "../src/wallet/address";
import { eip191Hash, signHash } from "../src/wallet/wallet";
import {
  QR_MAX_MODULES,
  crc32,
  discSlots,
  expandTabs,
  fitDisc,
  fitMono,
  fromBase64,
  itxtChunk,
  mascotFor,
  packSource,
  parseQrPayload,
  posterFileName,
  pour,
  qrModules,
  qrModulesCount,
  qrPayload,
  readPngText,
  tones,
  unpackSource,
  withPngText,
} from "../src/ui/poster";

/** A monospace face where every cell is half the size: 10px type is 5px wide. */
const cellW = (px: number) => px / 2;

describe("fitting a column", () => {
  it("takes the largest size at which every line fits", () => {
    const fit = fitMono(["abcd", "ef"], 100, 100, cellW, 40, 8);
    // 40px: cells 20 wide, 5 per row, line 44 tall — two rows need 88 ≤ 100.
    expect(fit.px).toBe(40);
    expect(fit.rows.map((r) => r.text)).toEqual(["abcd", "ef"]);
    expect(fit.hidden).toBe(0);
  });

  it("wraps a long line by column rather than dropping it", () => {
    const fit = fitMono(["abcdefghij"], 25, 200, cellW, 10, 10);
    // 5 cells per row at 10px.
    expect(fit.rows.map((r) => r.text)).toEqual(["abcde", "fghij"]);
    expect(fit.rows.map((r) => r.col)).toEqual([0, 5]);
  });

  it("says how many lines it could not show, in the last row", () => {
    const lines = Array.from({ length: 20 }, (_, i) => `line ${i}`);
    const fit = fitMono(lines, 200, 44, cellW, 10, 10, 1.1);
    // 11px rows in 44px: four rows, three of them program, one the count.
    expect(fit.rows).toHaveLength(4);
    expect(fit.rows[3].line).toBe(-1);
    expect(fit.rows[3].text).toBe("… 17 more lines");
    expect(fit.hidden).toBe(17);
  });

  it("keeps an empty line as a row, so the program keeps its shape", () => {
    const fit = fitMono(["a", "", "b"], 100, 100, cellW, 10, 10);
    expect(fit.rows.map((r) => r.text)).toEqual(["a", "", "b"]);
  });

  it("expands a tab to four columns", () => {
    expect(expandTabs("\tx\t")).toBe("    x    ");
  });
});

describe("pouring a program into the disc", () => {
  it("cuts every row to the chord of the disc at that height", () => {
    const slots = discSlots(100, 0, 1, 10, 1);
    for (const s of slots) {
      const far = Math.max(Math.abs(s.y), Math.abs(s.y + 10));
      const hw = Math.sqrt(100 * 100 - far * far);
      expect(s.x).toBeCloseTo(-hw, 6);
      expect(s.cap).toBeLessThanOrEqual(2 * hw);
      expect(s.cap).toBeGreaterThan(2 * hw - 1);
    }
    // Symmetric about the centre: the row set is centred vertically.
    const top = slots[0];
    const bottom = slots[slots.length - 1];
    expect(top.y).toBeCloseTo(-(bottom.y + 10), 6);
  });

  it("stops a row at the label, on the left only, so OCR reads one column", () => {
    const slots = discSlots(100, 40, 1, 10, 1);
    const middle = slots.filter((s) => s.y < 40 && s.y + 10 > -40);
    expect(middle.length).toBeGreaterThan(0);
    for (const s of middle) {
      // The run starts at the disc's left edge and ends before the label.
      expect(s.x).toBeLessThan(-40);
      expect(s.x + s.cap).toBeLessThanOrEqual(
        -Math.sqrt(40 * 40 - Math.min(s.y * s.y, (s.y + 10) ** 2)) + 1e-6 || 0,
      );
    }
    // No slot starts to the right of the centre: nothing is set beside the label.
    expect(slots.every((s) => s.x < 0)).toBe(true);
  });

  it("leaves out a groove too short to be worth reading", () => {
    const slots = discSlots(100, 0, 10, 10, 6);
    expect(slots.every((s) => s.cap >= 6)).toBe(true);
  });

  it("pours in reading order and wraps a line into the next groove", () => {
    const slots = [
      { x: 0, y: 0, cap: 3 },
      { x: 0, y: 10, cap: 3 },
      { x: 0, y: 20, cap: 3 },
    ];
    const got = pour(["abcd", "e"], slots);
    expect(got?.map((g) => [g.line, g.col, g.text])).toEqual([
      [0, 0, "abc"],
      [0, 3, "d"],
      [1, 0, "e"],
    ]);
  });

  it("moves a line down to a groove wide enough rather than breaking it", () => {
    // Grooves widen towards the middle of the disc; a line that does not fit
    // the narrow one at the top waits for one that holds it whole, and the
    // narrow one stays empty. Nothing is wrapped while any groove could
    // take the line intact.
    const slots = [
      { x: 0, y: 0, cap: 4 },
      { x: 0, y: 10, cap: 8 },
      { x: 0, y: 20, cap: 12 },
    ];
    const alone = pour(["use std::io;"], slots);
    expect(alone?.map((g) => [g.y, g.col, g.text])).toEqual([[20, 0, "use std::io;"]]);
    // A second line finds no groove after the one the first took.
    expect(pour(["use std::io;", "fn main()"], slots)).toBeNull();
    const fits = pour(["ab", "fn main()"], slots);
    expect(fits?.map((g) => [g.y, g.text])).toEqual([
      [0, "ab"],
      [20, "fn main()"],
    ]);
  });

  it("gives an empty line a groove of its own", () => {
    const slots = [
      { x: 0, y: 0, cap: 3 },
      { x: 0, y: 10, cap: 3 },
      { x: 0, y: 20, cap: 3 },
    ];
    expect(pour(["a", "", "b"], slots)?.map((g) => g.text)).toEqual(["a", "", "b"]);
  });

  it("says when the program does not fit", () => {
    expect(pour(["abcdefg"], [{ x: 0, y: 0, cap: 3 }])).toBeNull();
  });

  it("fitDisc takes the largest size that holds the whole program", () => {
    const lines = ["fn main() {", '    println!("hi");', "}"];
    const big = fitDisc(lines, 300, 0, cellW, 40, 10);
    expect(big.hidden).toBe(0);
    expect(
      big.grooves
        .filter((g) => g.line >= 0)
        .map((g) => g.text)
        .join(""),
    ).toBe(lines.join(""));
    const small = fitDisc(lines, 60, 0, cellW, 40, 10);
    expect(small.px).toBeLessThan(big.px);
  });

  it("fitDisc shrinks the type rather than break a line, until the floor", () => {
    // A 34-cell line on a disc 100 wide: at 10px (5px cells, 20 per row at
    // the widest) it can only be wrapped; at 4px (2px cells, 50 per row) it
    // fits whole. The larger size is refused for the break.
    const lines = ["fn main() {", '    println!("hello from {city}");', "}"];
    const fit = fitDisc(lines, 50, 0, cellW, 10, 4);
    expect(fit.grooves.every((g) => g.col === 0)).toBe(true);
    expect(fit.px).toBeLessThan(10);
    // At the floor a line longer than any groove is wrapped rather than lost.
    const floor = fitDisc(["x".repeat(80)], 50, 0, cellW, 4, 4);
    expect(floor.grooves.some((g) => g.col > 0)).toBe(true);
    expect(floor.grooves.map((g) => g.text).join("")).toBe("x".repeat(80));
  });

  it("fitDisc at the floor keeps as much as fits and counts the rest", () => {
    const lines = Array.from({ length: 200 }, (_, i) => `line number ${i}`);
    const fit = fitDisc(lines, 60, 0, cellW, 20, 10);
    expect(fit.px).toBe(10);
    expect(fit.hidden).toBeGreaterThan(0);
    const last = fit.grooves[fit.grooves.length - 1];
    expect(last.line).toBe(-1);
    expect(last.text.startsWith("…")).toBe(true);
    const shown = fit.grooves.filter((g) => g.line >= 0);
    expect(shown.length + fit.hidden).toBeGreaterThanOrEqual(lines.length - 0);
    // Whole lines only: what is shown is a prefix of the program.
    const lastShown = Math.max(...shown.map((g) => g.line));
    expect(lastShown + 1 + fit.hidden).toBe(lines.length);
  });
});

describe("colouring from the grammar", () => {
  it("colours Rust the way the editor does", () => {
    const src = 'fn main() { let x = 42; println!("hi"); } // done';
    const t = tones(src, "rust");
    expect(t.length).toBe(src.length);
    expect(t[src.indexOf("fn")]).toBe("keyword");
    expect(t[src.indexOf("let")]).toBe("keyword");
    expect(t[src.indexOf("42")]).toBe("number");
    expect(t[src.indexOf('"hi"') + 1]).toBe("string");
    expect(t[src.indexOf("// done") + 3]).toBe("comment");
    expect(t[src.indexOf("{")]).toBe("bracket");
    expect(t[src.indexOf("x =")]).toBe("name");
  });

  it("knows the other three lands", () => {
    expect(tones("x = 1", "python")[0]).toBe("name");
    expect(tones("x = 1", "python")[4]).toBe("number");
    expect(tones("package main", "go")[0]).toBe("keyword");
    expect(tones("int main() { return 0; }", "cpp")[0]).toBe("type");
  });
});

describe("the label", () => {
  const addr = "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F";
  const sig = "0x" + "ab".repeat(65);

  it("carries the source, the address and the signature, and comes back apart", () => {
    const src = 'fn main() {\n    println!("héllo 🌏");\n}\n';
    const { text, hashed } = qrPayload(addr, sig, "rust", src);
    expect(hashed).toBe(false);
    const back = parseQrPayload(text);
    expect(back).toEqual({ address: addr, signature: sig, lang: "rust", body: src });
  });

  it("writes `-` for no signature and reads it back as null", () => {
    const back = parseQrPayload(qrPayload(addr, null, "go", "x").text);
    expect(back?.signature).toBeNull();
  });

  it("hashes a program whose label would be too dense to scan, and says so", () => {
    const src = "x".repeat(3000);
    const { text, hashed } = qrPayload(addr, sig, "python", src);
    expect(hashed).toBe(true);
    const back = parseQrPayload(text);
    expect(back?.body).toBe("keccak256:" + toHex(keccak_256(new TextEncoder().encode(src))));
    expect(qrModulesCount(text)).toBeLessThanOrEqual(QR_MAX_MODULES);
  });

  it("keeps the program on the label while the label stays scannable", () => {
    const { text, hashed } = qrPayload(addr, sig, "rust", "a".repeat(500));
    expect(hashed).toBe(false);
    expect(qrModulesCount(text)).toBeLessThanOrEqual(QR_MAX_MODULES);
    // The line is drawn in modules, so in bytes, not characters — each of
    // these is three bytes.
    expect(qrPayload(addr, sig, "rust", "가".repeat(300)).hashed).toBe(true);
    expect(qrPayload(addr, sig, "rust", "a".repeat(300)).hashed).toBe(false);
  });

  it("deflates a program the plain label cannot hold, before it hashes it", async () => {
    // Real code, not a run of one letter: a run compresses to nothing and
    // would prove the wrong thing. 30 lines of Rust — past the plain cap.
    const src = "fn f(x: i32) -> i32 {\n    let y = x * 2 + 1;\n    y\n}\n".repeat(16);
    expect(qrPayload(addr, sig, "rust", src).hashed).toBe(true);
    const packed = await packSource(src);
    expect(packed).not.toBeNull();
    const { text, hashed } = qrPayload(addr, sig, "rust", src, packed);
    expect(hashed).toBe(false);
    expect(text).toContain("\ndeflate:");
    expect(qrModulesCount(text)).toBeLessThanOrEqual(QR_MAX_MODULES);
    // And back: the base64 is the deflate, and the deflate is the source.
    const body = parseQrPayload(text)!.body.slice("deflate:".length);
    expect(await unpackSource(fromBase64(body)!)).toBe(src);
  });

  it("still hashes what will not fit even deflated", async () => {
    const src = Array.from({ length: 400 }, (_, i) => `let v${i} = ${i * 7919};`).join("\n");
    const { hashed } = qrPayload(addr, sig, "rust", src, await packSource(src));
    expect(hashed).toBe(true);
  });

  it("goes plain when plain fits, deflated or not", async () => {
    const src = "fn main() {}\n";
    expect(qrPayload(addr, sig, "rust", src, await packSource(src)).text).toContain("\n" + src);
  });

  it("refuses a payload that is not one of ours", () => {
    expect(parseQrPayload("hello\nworld\n\n\n")).toBeNull();
    expect(parseQrPayload("CWBH1\nonly")).toBeNull();
  });

  it("encodes to a square grid that grows with the program", () => {
    const small = qrModules(qrPayload(addr, sig, "rust", "fn main() {}").text);
    expect(small.length).toBeGreaterThan(20);
    expect(small.every((row) => row.length === small.length)).toBe(true);
    const large = qrModules(qrPayload(addr, sig, "rust", "// ".repeat(150)).text);
    expect(large.length).toBeGreaterThan(small.length);
    // Nothing we make is denser than the cap: a hashed label is small.
    const max = qrModules(qrPayload(addr, sig, "rust", "가".repeat(700)).text);
    expect(max.length).toBeLessThanOrEqual(QR_MAX_MODULES);
  });
});

describe("the proof", () => {
  it("is a signature over the source alone, recoverable to the address", () => {
    // The wallet's fixture key (CausewaybayWallet testvectors/eip191.json).
    const key = fromHex("0x4646464646464646464646464646464646464646464646464646464646464646");
    const source = 'fn main() {\n    println!("hello, causewaybay");\n}\n';
    const sig = signHash(eip191Hash(source), key);
    expect(sig).toHaveLength(65);
    // Recover: r||s||v with v in {27, 28}; the message is the source, nothing added.
    const recovered = secp256k1.Signature.fromBytes(sig.subarray(0, 64), "compact")
      .addRecoveryBit(sig[64] - 27)
      .recoverPublicKey(eip191Hash(source))
      .toBytes(false);
    const addr = "0x" + toHex(keccak_256(recovered.subarray(1)).subarray(12));
    expect(toEip55(addr)).toBe("0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F");
    // And the label carries exactly that message, so a verifier has it.
    const back = parseQrPayload(qrPayload(toEip55(addr), "0x" + toHex(sig), "rust", source).text);
    expect(back?.body).toBe(source);
  });
});

describe("the file", () => {
  it("names the file after the pad and the minute, safely", () => {
    const at = new Date(Date.UTC(2026, 8, 16, 9, 7));
    expect(posterFileName("My Pad / v2!", at)).toBe("cwbhacker-my-pad-v2-20260916-0907.png");
    expect(posterFileName("   ", at)).toBe("cwbhacker-pad-20260916-0907.png");
    expect(posterFileName("스크래치", at)).toBe("cwbhacker-스크래치-20260916-0907.png");
  });

  it("computes PNG's CRC-32", () => {
    // The IEND chunk's CRC, a constant every PNG ends with.
    expect(crc32(new TextEncoder().encode("IEND"))).toBe(0xae426082);
    expect(crc32(new Uint8Array(0))).toBe(0);
  });

  /** The smallest PNG: signature, IHDR, IEND — enough for the chunk walker. */
  function tinyPng(): Uint8Array {
    const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    const ihdrData = new Uint8Array(13);
    const ihdr = chunk("IHDR", ihdrData);
    const iend = chunk("IEND", new Uint8Array(0));
    const out = new Uint8Array(8 + ihdr.length + iend.length);
    out.set(sig, 0);
    out.set(ihdr, 8);
    out.set(iend, 8 + ihdr.length);
    return out;
  }
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

  it("writes the proof into the PNG as iTXt, before IEND, and reads it back", () => {
    const src = 'print("héllo 🌏")\n';
    const out = withPngText(tinyPng(), { Source: src, Signer: "0xabc", Signature: "0xdef" });
    expect(readPngText(out)).toEqual({ Source: src, Signer: "0xabc", Signature: "0xdef" });
    // IEND is still last, and the file is still a PNG.
    const tail = String.fromCharCode(...out.subarray(out.length - 8, out.length - 4));
    expect(tail).toBe("IEND");
    expect(out.subarray(0, 8)).toEqual(tinyPng().subarray(0, 8));
  });

  it("builds an iTXt chunk to the specification", () => {
    const c = itxtChunk("Source", "x");
    const len = new DataView(c.buffer).getUint32(0);
    expect(String.fromCharCode(...c.subarray(4, 8))).toBe("iTXt");
    // "Source" \0 0 0 "" \0 "" \0 "x" = 6 + 1 + 1 + 1 + 1 + 1 + 1
    expect(len).toBe(12);
    expect(c).toHaveLength(12 + 12);
    const over = c.subarray(4, 8 + len);
    expect(new DataView(c.buffer).getUint32(8 + len)).toBe(crc32(over));
  });

  it("refuses bytes that are not a PNG", () => {
    expect(() => withPngText(new Uint8Array(20), { a: "b" })).toThrow(/not a PNG/);
  });
});

describe("the mascot", () => {
  const run = (outcome: "ok" | "compile_error" | "timeout") => ({
    outcome,
    ok: outcome === "ok",
    compileError: outcome === "compile_error",
    timings: "",
    lines: [],
  });
  it("takes the pose the run earned", () => {
    expect(mascotFor("rust", run("ok"))).toBe("mascot_rust_hacker");
    expect(mascotFor("go", run("compile_error"))).toBe("mascot_go_basic");
    expect(mascotFor("cpp", run("timeout"))).toBe("mascot_cpp_advanced");
    expect(mascotFor("python", null)).toBe("mascot_python_advanced");
  });
});
