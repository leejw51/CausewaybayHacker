/**
 * The poster: one square PNG of a pad, signed by the wallet, saved to disk.
 *
 * For showing off. The code you wrote, what it printed, who wrote it — as one
 * picture somebody can put on Instagram, and that anybody with the picture can
 * check: the address on it signed the source on it.
 *
 * **The source code is the record.** The square is an LP sleeve; on it lies a
 * vinyl disc, and the program is printed *inside the disc*, line after line,
 * each line as long as the groove at that height allows and flowing around
 * the centre label. The label is a QR code. The output is SIDE B, a column
 * beside the disc with the language's mascot standing on it. The credits —
 * name, address, the signature in full — are the liner notes along the
 * bottom, under a wax seal. Nothing about that is necessary and all of it is
 * the point: a screenshot of a text editor is not something anyone shares.
 *
 * **Readable three ways.** A person reads the code off the disc. OCR reads
 * it too: the code, the address and the signature are set in JetBrains Mono,
 * not the pixel faces the rest of the game wears — VT323's `0` and `O` are
 * one shape and that is the difference between a signature and a picture of
 * one — in one column, left-aligned, so the rows beside the label are set to
 * its left only and nothing is read out of order. And a machine reads the
 * label: the QR carries the source, the address and the signature, in
 * that order, so a phone pointed at the picture — the picture Instagram
 * re-encoded, stripped and shrank — can recover the program and check who
 * signed it. When the source as written would make the label too dense to
 * scan off a phone (`QR_MAX_MODULES`; about 650 bytes), it goes on the label
 * **deflated** — code compresses two- to threefold, which carries a program
 * of 1.5–2 KB — and only past that does the label carry its keccak-256
 * instead and say so; the source is then on the disc and in the file's own
 * text chunks, and the hash ties the two.
 *
 * **The signature is EIP-191 `personal_sign` over the source, and only the
 * source.** Not over a JSON envelope, not over the output, not over the name.
 * The message is the thing printed on the poster in full, so verifying it
 * needs nothing that is not in the picture: recover the signer from
 * (signature, source) and compare it to the address. It is the scheme
 * `CausewaybayWallet` uses for its EVM (Cronos) accounts and the one this
 * client already logs in with — `wallet.ts` pins the vectors. The output is
 * *not* signed: it came from the server, not from the wallet's owner, and a
 * signature over it would claim something the key cannot know.
 *
 * The same proof also goes into the PNG as `iTXt` chunks (`Source`,
 * `Signer`, `Signature`), for a reader that has the file rather than a photo
 * of it. Instagram strips them; the QR is what survives Instagram.
 *
 * Everything that is arithmetic — pouring a program into a disc, fitting a
 * column, tokenising, the QR payload, the chunk bytes — is exported and
 * pure, and `tests/poster.test.ts` runs it. The drawing needs a canvas and
 * is not.
 */
import { rustLanguage } from "@codemirror/lang-rust";
import { goLanguage } from "@codemirror/lang-go";
import { cppLanguage } from "@codemirror/lang-cpp";
import { pythonLanguage } from "@codemirror/lang-python";
import type { LRLanguage } from "@codemirror/language";
import { keccak_256 } from "@noble/hashes/sha3.js";
import qrcode from "qrcode-generator";
import type { Land } from "../net/protocol";
import type { Assets } from "../engine/assets";
import { fontAt, type Font } from "../engine/text";
import { css, Theme, type RGBA } from "../engine/theme";
import { fill } from "../engine/ui";
import { toHex } from "../wallet/address";
import { landColour } from "./chrome";
import { toneOfNode, type Tone } from "./editor";

/**
 * The side of the square, by default. 1024: what Instagram shows a square at
 * (1080), and what a phone camera pointed at a screen has to read the label
 * from. `makePoster` goes to `POSTER_SIZE_LARGE` only when 1024 is not
 * enough — the program did not fit at the smallest readable type, or the QR
 * came out finer than a scanner likes — because the bigger file is otherwise
 * the same picture with four times the bytes.
 */
export const POSTER_SIZE = 1024;
export const POSTER_SIZE_LARGE = 2048;

/**
 * The smallest type the code is set in, in **real pixels** whatever the
 * canvas size — 12px is where OCR stops agreeing with the person. It is the
 * one length on the poster that does not scale with the square: that is how
 * the 2048 poster holds twice the program, rather than the same program
 * twice as big.
 */
export const CODE_MIN_PX = 12;
/** The same floor for the output column. */
export const OUT_MIN_PX = 10;
/**
 * The fewest pixels per QR module before `makePoster` reaches for 2048.
 * Two: measured with `jsQR`, a 1024 poster whose label is two pixels a
 * module still reads after Instagram's 1080 JPEG, and one pixel does not.
 */
export const QR_MIN_CELL = 2;

/** What ran, as the poster prints it. Null when nothing has been run. */
export interface PosterRun {
  /** `IT RAN`, `IT DID NOT COMPILE`, … — already translated. */
  outcome: string;
  /** Whether that is the good one; the colour it is printed in. */
  ok: boolean;
  /** Whether the compiler stopped it: which pose the mascot takes. */
  compileError: boolean;
  /** `12 ms compile · 3 ms run · exit 0`, translated. Empty when none. */
  timings: string;
  lines: Array<{ stream: string; text: string }>;
}

/** The words on the picture that are not the player's own. */
export interface PosterWords {
  /** `SIDE A` / `SIDE B` — the two halves of a record. */
  sideA: string;
  sideB: string;
  /** Over the output panel when nothing has been run. */
  nothingRun: string;
  /** `… {n} more lines`, with the number already in it. */
  more: (n: number) => string;
  /** `WRITTEN & SIGNED BY`, over the credits. */
  by: string;
  /** Over a seal that could not be applied. */
  unsigned: string;
  /** How the signature was made, for whoever wants to check it. */
  how: string;
  /** Under the label when the QR holds a hash rather than the program. */
  hashed: string;
}

export interface PosterInput {
  lang: Land;
  /**
   * `source`, deflated (`packSource`), for the label when the plain text is
   * too dense; null when the browser cannot deflate. `makePoster` fills it,
   * once, because the drawing is synchronous and the deflate is not.
   */
  packed?: Uint8Array | null;
  /** The pad's name, as shown on screen. */
  name: string;
  /** `main.rs`, `main.go`, … */
  file: string;
  source: string;
  run: PosterRun | null;
  user: { name: string; address: string };
  /** `0x` + 130 hex, or null when no key was unlocked to sign with. */
  signature: string | null;
  at: Date;
  words: PosterWords;
  assets: Assets | null;
}

// -- fitting text into a box (pure) ------------------------------------------

/** One row of a fitted block: which source line it came from, and its text. */
export interface Row {
  /** 0-based line of the original text; -1 for the `… n more lines` row. */
  line: number;
  /** Column of the original line this row starts at (0 for the first wrap). */
  col: number;
  text: string;
}

export interface Fit {
  px: number;
  charW: number;
  lineH: number;
  rows: Row[];
  /** Original lines that did not make it onto the picture. */
  hidden: number;
}

/** Tabs are four columns: what every one of the four compilers assumes. */
export function expandTabs(s: string): string {
  return s.replace(/\t/g, "    ");
}

/**
 * The largest type at which `lines` fit in a `w` by `h` box, wrapping long
 * lines by column, and — when even the smallest does not fit — the rows that
 * do, ending in a row that says how many did not.
 *
 * `charW(px)` is the advance of one cell at that size, injected so the tests
 * can run without a canvas (and so the caller measures in the face it will
 * draw with). Sizes are tried from `maxPx` down in steps of two: a monospace
 * face at 2048px is many sizes apart from "fits" to "does not", and a binary
 * search over a non-monotone measure (the wrap count) is not worth its risk.
 *
 * The `more` row takes one row's space out of the budget only when it is
 * needed — a program that fits exactly is not told one line is missing.
 */
export function fitMono(
  lines: readonly string[],
  w: number,
  h: number,
  charW: (px: number) => number,
  maxPx: number,
  minPx: number,
  leading = 1.1,
  more: (n: number) => string = (n) => `… ${n} more lines`,
): Fit {
  const layout = (px: number, cap: number | null): { rows: Row[]; hidden: number } => {
    const cw = charW(px);
    const cols = Math.max(1, Math.floor(w / cw));
    const rows: Row[] = [];
    for (let i = 0; i < lines.length; i++) {
      const s = lines[i];
      if (s === "") {
        rows.push({ line: i, col: 0, text: "" });
      } else {
        for (let c = 0; c < s.length; c += cols) {
          rows.push({ line: i, col: c, text: s.slice(c, c + cols) });
        }
      }
      if (cap !== null && rows.length > cap) {
        // Over budget: keep `cap - 1` rows and spend the last on the count.
        const kept = rows.slice(0, Math.max(0, cap - 1));
        const lastLine = kept.length ? kept[kept.length - 1].line : -1;
        const hidden = lines.length - (lastLine + 1);
        kept.push({ line: -1, col: 0, text: more(hidden) });
        return { rows: kept, hidden };
      }
    }
    return { rows, hidden: 0 };
  };
  let px = Math.max(minPx, maxPx);
  for (; px > minPx; px -= 2) {
    const lineH = Math.round(px * leading);
    const fits = Math.floor(h / lineH);
    const { rows } = layout(px, null);
    if (rows.length <= fits) {
      return { px, charW: charW(px), lineH, rows, hidden: 0 };
    }
  }
  px = minPx;
  const lineH = Math.round(px * leading);
  const fits = Math.max(1, Math.floor(h / lineH));
  const { rows, hidden } = layout(px, fits);
  return { px, charW: charW(px), lineH, rows, hidden };
}

// -- pouring text into a disc (pure) -----------------------------------------

/** One run of text on the disc, in disc coordinates (origin at the centre). */
export interface Groove extends Row {
  /** Left edge and top of the run, relative to the disc's centre. */
  x: number;
  y: number;
  /** How many cells the run may hold; `text.length` is how many it does. */
  cap: number;
}

export interface DiscFit {
  px: number;
  charW: number;
  lineH: number;
  grooves: Groove[];
  hidden: number;
}

/**
 * The places text can go on a disc of radius `r` with a label of radius
 * `hole` in the middle: for every row of `lineH`, the chord of the disc at
 * that height, cut short where the row meets the label — so a row through
 * the middle is a short run to the label's left, and a row near the rim is a
 * short run too. Runs that could hold fewer than `minCells` are left empty:
 * a groove of two characters is decoration.
 *
 * Rows are laid so the set is centred on the disc vertically.
 */
export function discSlots(
  r: number,
  hole: number,
  charW: number,
  lineH: number,
  minCells: number,
): Array<Omit<Groove, "line" | "col" | "text">> {
  const rows = Math.floor((2 * r) / lineH);
  const top = -(rows * lineH) / 2;
  const out: Array<Omit<Groove, "line" | "col" | "text">> = [];
  for (let i = 0; i < rows; i++) {
    const y0 = top + i * lineH;
    const y1 = y0 + lineH;
    // The chord is narrowest at whichever edge of the row is further from the
    // centre; the whole row has to fit inside it.
    const far = Math.max(Math.abs(y0), Math.abs(y1));
    if (far >= r) continue;
    const hw = Math.sqrt(r * r - far * far);
    // The label is widest at whichever edge is *nearer* the centre. A row
    // that crosses it is set to its **left only**: the right-hand piece would
    // be the next line of the program on the same row, which a person can
    // follow and OCR cannot — it reads a row as a line and joins the two.
    const near = y0 <= 0 && y1 >= 0 ? 0 : Math.min(Math.abs(y0), Math.abs(y1));
    const b = near < hole ? -Math.sqrt(hole * hole - near * near) : hw;
    const cap = Math.floor((b + hw) / charW);
    if (cap < minCells) continue;
    // Start at the curve, so the left edge is as straight as the disc allows.
    out.push({ x: -hw, y: y0, cap });
  }
  return out;
}

/**
 * Pour `lines` into the slots in reading order, top to bottom, **one line
 * per groove, whole**. A line that is too long for the groove in front of it
 * moves down to the first groove that can take it, and the grooves it passed
 * stay empty — so the program's lines are never broken in the middle of an
 * identifier, which is what a person and OCR both need (a `HashMap` split
 * into `co` and `llections` is not the program). Only a line longer than the
 * widest groove there is gets wrapped by column, as the last resort. An
 * empty line takes a groove of its own, so the shape of the program
 * survives. `null` when they do not all fit.
 */
export function pour(
  lines: readonly string[],
  slots: ReadonlyArray<Omit<Groove, "line" | "col" | "text">>,
): Groove[] | null {
  const widest = slots.reduce((m, s) => Math.max(m, s.cap), 0);
  const out: Groove[] = [];
  let s = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.length <= widest) {
      while (s < slots.length && slots[s].cap < line.length) s++;
      if (s >= slots.length) return null;
      out.push({ ...slots[s++], line: i, col: 0, text: line });
      continue;
    }
    let col = 0;
    do {
      if (s >= slots.length) return null;
      const slot = slots[s++];
      out.push({ ...slot, line: i, col, text: line.slice(col, col + slot.cap) });
      col += slot.cap;
    } while (col < line.length);
  }
  return out;
}

/**
 * The largest type at which the program fits on the disc, or — at the
 * smallest — as much of it as does, with the last slot saying how many
 * lines are missing. Same shape as `fitMono`, for the same reasons.
 */
export function fitDisc(
  lines: readonly string[],
  r: number,
  hole: number,
  charW: (px: number) => number,
  maxPx: number,
  minPx: number,
  leading = 1.1,
  minCells = 6,
  more: (n: number) => string = (n) => `… ${n} more lines`,
): DiscFit {
  for (let px = Math.max(minPx, maxPx); px > minPx; px -= 2) {
    const lineH = Math.round(px * leading);
    const cw = charW(px);
    const grooves = pour(lines, discSlots(r, hole, cw, lineH, minCells));
    // Whole lines only, while there is a smaller size to try: a size at which
    // `println!("hello from {city}")` fits only as `hello fr` / `om {city}` is
    // not a size at which the program fits.
    if (grooves && !grooves.some((g) => g.col > 0)) {
      return { px, charW: cw, lineH, grooves, hidden: 0 };
    }
  }
  const px = minPx;
  const lineH = Math.round(px * leading);
  const cw = charW(px);
  const slots = discSlots(r, hole, cw, lineH, minCells);
  const whole = pour(lines, slots);
  if (whole) return { px, charW: cw, lineH, grooves: whole, hidden: 0 };
  // Keep every slot but the last for the program, and find how many whole
  // lines that is; the last slot says what is missing.
  const budget = slots.slice(0, -1);
  let n = 0;
  for (; n < lines.length; n++) {
    if (!pour(lines.slice(0, n + 1), budget)) break;
  }
  const grooves = pour(lines.slice(0, n), budget) ?? [];
  const hidden = lines.length - n;
  const last = slots[slots.length - 1];
  grooves.push({ ...last, line: -1, col: 0, text: more(hidden).slice(0, last.cap) });
  return { px, charW: cw, lineH, grooves, hidden };
}

// -- tokenising (pure) ---------------------------------------------------------

const PARSER: Record<Land, LRLanguage> = {
  rust: rustLanguage,
  go: goLanguage,
  cpp: cppLanguage,
  python: pythonLanguage,
};

/**
 * One tone per character of `source`, from the same grammar the editor
 * highlights with. A character no leaf claims is an operator if it is
 * punctuation and plain otherwise — `toneOf`'s tie-break, applied to a whole
 * program at once.
 */
export function tones(source: string, lang: Land): Tone[] {
  const out: Tone[] = new Array<Tone>(source.length);
  for (let i = 0; i < source.length; i++) {
    const ch = source[i];
    out[i] = "{}[]()".includes(ch)
      ? "bracket"
      : /\s/.test(ch)
        ? "plain"
        : /[A-Za-z0-9_]/.test(ch)
          ? "name"
          : "operator";
  }
  const tree = PARSER[lang].parser.parse(source);
  tree.iterate({
    enter(node) {
      // Leaves only: an inner node's name (`FunctionItem`, `Block`) says what
      // its children are *of*, not what they are.
      if (node.node.firstChild) return;
      const tone = toneOfNode(node.name, node.node.parent?.name ?? "");
      if (!tone) return;
      for (let i = node.from; i < node.to && i < out.length; i++) {
        if (out[i] !== "bracket") out[i] = tone;
      }
    },
  });
  return out;
}

/** The editor's palette (`editor.ts` `retro`), by tone. */
const TONE_COL: Record<Tone, RGBA> = {
  keyword: Theme.pink,
  name: Theme.cream,
  call: Theme.cyan,
  type: Theme.coin,
  string: Theme.grass,
  number: Theme.coin,
  // Lighter than the editor's comment grey: on the vinyl, `Theme.dim` is
  // a 3:1 contrast and OCR starts guessing at the doc comments.
  comment: [0.68, 0.64, 0.6, 1],
  operator: Theme.panel,
  bracket: Theme.cream,
  plain: Theme.cream,
};

// -- the label's payload (pure) --------------------------------------------------

/**
 * The densest label allowed: 105 modules a side (version 23). Denser than
 * that and the label — a quarter of the picture's width — is under 2.5px a
 * module once Instagram has shown the poster at 1080, and phones stop
 * reading it. A program whose payload would need more goes on deflated;
 * one that is still too dense deflated is hashed instead. About 650 bytes
 * of source is the first line, and 1.5–2 KB the second.
 */
export const QR_MAX_MODULES = 105;

/** The first line of the payload: which format this is. */
export const QR_MAGIC = "CWBH1";

/**
 * What the QR says, as text:
 *
 *     CWBH1
 *     <EIP-55 address>
 *     <0x signature, or ->
 *     <lang>
 *     <source>            — or, when the source is too long:
 *     deflate:<base64>    — the source, raw-deflated; or, when even that is:
 *     keccak256:<hex>
 *
 * Five lines, split on the first four newlines; the source keeps its own.
 * A verifier recovers the signer from EIP-191 over the source — the fifth
 * field as it is, or inflated, or the program the hash was taken of — and
 * compares it to the second line. The signature is over the plain source in
 * every case: the deflate is the label's business, not the wallet's.
 *
 * `packed` is the deflated source, made by `packSource` beforehand (the
 * deflate is asynchronous, this is not); null or absent means the label may
 * only be plain or a hash.
 */
export function qrPayload(
  address: string,
  signature: string | null,
  lang: Land,
  source: string,
  packed: Uint8Array | null = null,
): { text: string; hashed: boolean } {
  const wrap = (body: string) => `${QR_MAGIC}\n${address}\n${signature ?? "-"}\n${lang}\n${body}`;
  const whole = wrap(source);
  // Sized by encoding it: the module count is what a scanner sees, and a
  // byte count would have to guess at it.
  if (qrModulesCount(whole) <= QR_MAX_MODULES) return { text: whole, hashed: false };
  if (packed) {
    const deflated = wrap(`${QR_DEFLATE}${toBase64(packed)}`);
    if (qrModulesCount(deflated) <= QR_MAX_MODULES) return { text: deflated, hashed: false };
  }
  return {
    text: wrap(`${QR_HASH}${toHex(keccak_256(new TextEncoder().encode(source)))}`),
    hashed: true,
  };
}

/** The two body prefixes that mean "not the source as written". */
export const QR_DEFLATE = "deflate:";
export const QR_HASH = "keccak256:";

/**
 * The source, raw-deflated, for the label. Null where the browser has no
 * `CompressionStream` (Safari before 16.4), in which case the label is
 * plain or hashed as it always was. Raw deflate, no zlib header: the
 * two bytes are two modules, and there is nothing in them a reader needs.
 */
export async function packSource(source: string): Promise<Uint8Array | null> {
  if (typeof CompressionStream !== "function") return null;
  const bytes = new TextEncoder().encode(source);
  const packed = await new Response(
    new Blob([bytes as BlobPart]).stream().pipeThrough(new CompressionStream("deflate-raw")),
  ).arrayBuffer();
  return new Uint8Array(packed);
}

/** `packSource` undone. Null for bytes that are not a deflate stream, or where the browser cannot inflate. */
export async function unpackSource(packed: Uint8Array): Promise<string | null> {
  if (typeof DecompressionStream !== "function") return null;
  try {
    const bytes = await new Response(
      new Blob([packed as BlobPart]).stream().pipeThrough(new DecompressionStream("deflate-raw")),
    ).arrayBuffer();
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

export function toBase64(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

/** Base64 back to bytes, or null when the text is not base64. */
export function fromBase64(text: string): Uint8Array | null {
  try {
    const bin = atob(text);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

/** How many modules a side the QR for `text` needs, or Infinity when no QR can hold it. */
export function qrModulesCount(text: string): number {
  try {
    qrcode.stringToBytes = qrcode.stringToBytesFuncs["UTF-8"];
    const qr = qrcode(0, "M");
    qr.addData(text, "Byte");
    qr.make();
    return qr.getModuleCount();
  } catch {
    return Infinity;
  }
}

/** The payload back into its parts, for a verifier (and the tests). */
export function parseQrPayload(
  text: string,
): { address: string; signature: string | null; lang: string; body: string } | null {
  const parts = text.split("\n");
  if (parts.length < 5 || parts[0] !== QR_MAGIC) return null;
  return {
    address: parts[1],
    signature: parts[2] === "-" ? null : parts[2],
    lang: parts[3],
    body: parts.slice(4).join("\n"),
  };
}

/** The QR's modules, as a square boolean grid. */
export function qrModules(text: string): boolean[][] {
  // Bytes, not UTF-16 code units: a Korean comment in the source is three
  // bytes a character and the default would encode it wrong.
  qrcode.stringToBytes = qrcode.stringToBytesFuncs["UTF-8"];
  const qr = qrcode(0, "M");
  qr.addData(text, "Byte");
  qr.make();
  const n = qr.getModuleCount();
  const grid: boolean[][] = [];
  for (let r = 0; r < n; r++) {
    const row: boolean[] = [];
    for (let c = 0; c < n; c++) row.push(qr.isDark(r, c));
    grid.push(row);
  }
  return grid;
}

// -- PNG text chunks (pure) ----------------------------------------------------

let crcTable: Uint32Array | null = null;

/** CRC-32 as PNG specifies it (ISO 3309, reflected, `0xEDB88320`). */
export function crc32(bytes: Uint8Array): number {
  if (!crcTable) {
    crcTable = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c >>> 0;
    }
  }
  let c = 0xffffffff;
  for (const b of bytes) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

const PNG_SIG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/** One `iTXt` chunk: UTF-8 text, uncompressed, no language tag. */
export function itxtChunk(keyword: string, text: string): Uint8Array {
  const enc = new TextEncoder();
  // The keyword is Latin-1, 1..79 bytes; ours are ASCII words.
  const key = enc.encode(keyword.slice(0, 79));
  const body = enc.encode(text);
  // keyword \0 compression-flag compression-method language-tag \0 translated-keyword \0 text
  const data = new Uint8Array(key.length + 5 + body.length);
  data.set(key, 0);
  // Five zero bytes: the terminator, no compression, method 0, and two
  // empty strings with their terminators.
  data.set(body, key.length + 5);
  const type = enc.encode("iTXt");
  const chunk = new Uint8Array(4 + 4 + data.length + 4);
  const view = new DataView(chunk.buffer);
  view.setUint32(0, data.length);
  chunk.set(type, 4);
  chunk.set(data, 8);
  const crcOver = new Uint8Array(4 + data.length);
  crcOver.set(type, 0);
  crcOver.set(data, 4);
  view.setUint32(8 + data.length, crc32(crcOver));
  return chunk;
}

/**
 * The PNG with text chunks added before `IEND`. Throws on bytes that are not
 * a PNG rather than returning them unchanged, because a caller that asked for
 * a signed file and got back an unsigned one would not know.
 */
export function withPngText(png: Uint8Array, entries: Record<string, string>): Uint8Array {
  for (let i = 0; i < 8; i++) if (png[i] !== PNG_SIG[i]) throw new Error("not a PNG");
  // Walk the chunks to find IEND: it is always last, but its offset is not
  // "length - 12" if something has already appended trailing bytes.
  let at = 8;
  let iend = -1;
  while (at + 8 <= png.length) {
    const len = new DataView(png.buffer, png.byteOffset + at, 4).getUint32(0);
    const type = String.fromCharCode(png[at + 4], png[at + 5], png[at + 6], png[at + 7]);
    if (type === "IEND") {
      iend = at;
      break;
    }
    at += 12 + len;
  }
  if (iend < 0) throw new Error("PNG has no IEND");
  const chunks = Object.entries(entries).map(([k, v]) => itxtChunk(k, v));
  const extra = chunks.reduce((n, c) => n + c.length, 0);
  const out = new Uint8Array(png.length + extra);
  out.set(png.subarray(0, iend), 0);
  let o = iend;
  for (const c of chunks) {
    out.set(c, o);
    o += c.length;
  }
  out.set(png.subarray(iend), o);
  return out;
}

/** Every `iTXt` keyword→text pair in a PNG: the reader's half of `withPngText`. */
export function readPngText(png: Uint8Array): Record<string, string> {
  const out: Record<string, string> = {};
  const dec = new TextDecoder();
  let at = 8;
  while (at + 8 <= png.length) {
    const len = new DataView(png.buffer, png.byteOffset + at, 4).getUint32(0);
    const type = String.fromCharCode(png[at + 4], png[at + 5], png[at + 6], png[at + 7]);
    if (type === "iTXt") {
      const data = png.subarray(at + 8, at + 8 + len);
      const k = data.indexOf(0);
      // keyword \0 flag method lang \0 translated \0 text
      let o = k + 3;
      o = data.indexOf(0, o) + 1;
      o = data.indexOf(0, o) + 1;
      out[dec.decode(data.subarray(0, k))] = dec.decode(data.subarray(o));
    }
    if (type === "IEND") break;
    at += 12 + len;
  }
  return out;
}

/** `cwbhacker-<pad>-<yyyymmdd-hhmm>.png`, with the pad name made safe. */
export function posterFileName(name: string, at: Date): string {
  const safe =
    name
      .toLowerCase()
      .replace(/[^a-z0-9぀-ヿ㐀-鿿가-힯]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 32) || "pad";
  const p = (n: number) => String(n).padStart(2, "0");
  const stamp = `${at.getUTCFullYear()}${p(at.getUTCMonth() + 1)}${p(at.getUTCDate())}-${p(
    at.getUTCHours(),
  )}${p(at.getUTCMinutes())}`;
  return `cwbhacker-${safe}-${stamp}.png`;
}

/**
 * Which mascot stands on the output: the language's, in the pose the run
 * earned. A program that ran is HACKER's mascot mid-triumph; one that did not
 * compile is BASIC's, back at the grammar; anything else — a runtime error,
 * a timeout, nothing run yet — is ADVANCED's, still working on it.
 */
export function mascotFor(lang: Land, run: PosterRun | null): string {
  const road =
    run === null ? "advanced" : run.ok ? "hacker" : run.compileError ? "basic" : "advanced";
  return `mascot_${lang}_${road}`;
}

// -- drawing -------------------------------------------------------------------

type G = CanvasRenderingContext2D;

/** `fontAt` with the size rounded to whole pixels, and cached per render. */
class Faces {
  private readonly cache = new Map<string, Font>();
  at(px: number, family: "pixel" | "body" | "mono"): Font {
    const key = `${Math.round(px)}${family}`;
    let f = this.cache.get(key);
    if (!f) {
      f = fontAt(Math.round(px), family);
      this.cache.set(key, f);
    }
    return f;
  }
}

function measure(g: G, f: Font, text: string): number {
  g.font = f.css;
  return g.measureText(text).width;
}

/** One line, left-aligned at (x, y) with the top of the line box at y. */
function text(g: G, f: Font, s: string, x: number, y: number, col: RGBA, alpha = 1): void {
  g.font = f.css;
  g.textBaseline = "top";
  g.textAlign = "left";
  g.fillStyle = css(col, alpha);
  g.fillText(s, x, y);
}

/** A line whose type is shrunk until it fits `w`, then elided if it still does not. */
function fitLine(
  g: G,
  faces: Faces,
  family: "pixel" | "body" | "mono",
  s: string,
  w: number,
  maxPx: number,
  minPx: number,
): { f: Font; s: string } {
  let px = maxPx;
  let f = faces.at(px, family);
  while (px > minPx && measure(g, f, s) > w) {
    px -= 2;
    f = faces.at(px, family);
  }
  if (measure(g, f, s) > w) {
    let cut = s;
    while (cut.length > 1 && measure(g, f, cut + "…") > w) cut = cut.slice(0, -1);
    s = cut + "…";
  }
  return { f, s };
}

/** Pixel-font text along an arc of radius `r` centred on (cx, cy). */
function arcText(
  g: G,
  f: Font,
  s: string,
  cx: number,
  cy: number,
  r: number,
  centreAngle: number,
  col: RGBA,
  inward = false,
): void {
  g.font = f.css;
  g.textBaseline = "middle";
  g.textAlign = "center";
  g.fillStyle = css(col);
  const chars = [...s];
  const widths = chars.map((ch) => g.measureText(ch).width);
  const total = widths.reduce((a, b) => a + b, 0);
  const dir = inward ? -1 : 1;
  const per = 1 / r;
  let a = centreAngle - (total / 2) * per * dir;
  chars.forEach((ch, i) => {
    const half = (widths[i] / 2) * per * dir;
    a += half;
    g.save();
    g.translate(cx + Math.cos(a) * r, cy + Math.sin(a) * r);
    g.rotate(a + (inward ? -Math.PI / 2 : Math.PI / 2));
    g.fillText(ch, 0, 0);
    g.restore();
    a += half;
  });
}

/**
 * A sprite with its feet at `bottom`. Crisp — an integer multiple of its own
 * pixels, no smoothing — unless the caller passes a fractional scale, which
 * is for the one asset (the seal) that has to fit a band it was not drawn for.
 */
function sprite(
  g: G,
  img: HTMLImageElement,
  cx: number,
  bottom: number,
  scale: number,
  box: { feet: number; cx: number } | undefined,
): void {
  g.save();
  g.imageSmoothingEnabled = !Number.isInteger(scale);
  const w = img.naturalWidth * scale;
  const h = img.naturalHeight * scale;
  const feet = (box?.feet ?? img.naturalHeight) * scale;
  const mid = (box?.cx ?? img.naturalWidth / 2) * scale;
  g.drawImage(img, Math.round(cx - mid), Math.round(bottom - feet), w, h);
  g.restore();
}

/**
 * The record, without its label. Near-black vinyl, grooves as concentric
 * rings that alternate a shade, two stepped sheen wedges (bands, not a
 * gradient — the rest of the game has no gradients either), a rim.
 */
function vinyl(g: G, cx: number, cy: number, r: number, hole: number): void {
  // Shadow, off to the lower left: the record is lying on the sleeve.
  g.fillStyle = css(Theme.ink, 0.6);
  g.beginPath();
  g.arc(cx - r * 0.015, cy + r * 0.025, r, 0, Math.PI * 2);
  g.fill();
  g.fillStyle = "#0b0a12";
  g.beginPath();
  g.arc(cx, cy, r, 0, Math.PI * 2);
  g.fill();
  g.lineWidth = 2;
  for (let rr = hole + 8; rr < r - 8; rr += 4) {
    const band = Math.floor((rr - hole) / 44) % 5 === 0;
    g.strokeStyle = band ? "rgba(255,255,255,0.085)" : "rgba(255,255,255,0.035)";
    g.beginPath();
    g.arc(cx, cy, rr, 0, Math.PI * 2);
    g.stroke();
  }
  for (const base of [-0.95, Math.PI - 0.95]) {
    for (let i = 0; i < 3; i++) {
      const spread = 0.4 - i * 0.11;
      g.fillStyle = `rgba(255,255,255,${0.03 + i * 0.025})`;
      g.beginPath();
      g.moveTo(cx, cy);
      g.arc(cx, cy, r - 6, base - spread, base + spread);
      g.closePath();
      g.fill();
    }
  }
  g.lineWidth = 6;
  g.strokeStyle = "rgba(255,255,255,0.16)";
  g.beginPath();
  g.arc(cx, cy, r - 3, 0, Math.PI * 2);
  g.stroke();
}

/**
 * The label: cream ring, land face, the QR in a quiet square, two arcs of
 * type. Returns the QR's pixels per module — what decides whether the poster
 * has to be made bigger.
 */
function label(
  g: G,
  faces: Faces,
  cx: number,
  cy: number,
  r: number,
  land: RGBA,
  grid: boolean[][],
  top: string,
  bottom: string,
  u: number,
): number {
  g.strokeStyle = "rgba(0,0,0,0.7)";
  g.lineWidth = 6;
  g.beginPath();
  g.arc(cx, cy, r + 5, 0, Math.PI * 2);
  g.stroke();
  g.fillStyle = css(Theme.cream);
  g.beginPath();
  g.arc(cx, cy, r, 0, Math.PI * 2);
  g.fill();
  g.fillStyle = css(land);
  g.beginPath();
  g.arc(cx, cy, r - 8 * u, 0, Math.PI * 2);
  g.fill();
  // The QR, at a whole number of pixels per module so every module is the
  // same size — a scanner's first assumption — inside the four-module quiet
  // zone the specification asks for. Two looked tidier and cost `jsQR` one
  // poster in two.
  const n = grid.length;
  const side = r * 1.5;
  const cell = Math.max(1, Math.floor(side / (n + 8)));
  const qs = cell * (n + 8);
  const qx = Math.round(cx - qs / 2);
  const qy = Math.round(cy - qs / 2);
  g.fillStyle = "#ffffff";
  g.fillRect(qx, qy, qs, qs);
  g.fillStyle = "#000000";
  for (let rr = 0; rr < n; rr++) {
    for (let c = 0; c < n; c++) {
      if (grid[rr][c]) g.fillRect(qx + (c + 4) * cell, qy + (rr + 4) * cell, cell, cell);
    }
  }
  const f = faces.at(8 * u, "pixel");
  arcText(g, f, top, cx, cy, r - 13 * u, -Math.PI / 2, Theme.ink);
  arcText(g, f, bottom, cx, cy, r - 13 * u, Math.PI / 2, Theme.ink, true);
  return cell;
}

/** The sleeve's printed edge and its worn corners. */
function sleeveFrame(g: G, S: number, land: RGBA): void {
  const t = Math.round(S * 0.012);
  g.lineWidth = t;
  g.strokeStyle = css(Theme.ink, 0.9);
  g.strokeRect(t / 2, t / 2, S - t, S - t);
  g.lineWidth = Math.round(t * 0.55);
  g.strokeStyle = css(land);
  g.strokeRect(t * 1.5, t * 1.5, S - t * 3, S - t * 3);
  g.fillStyle = css(Theme.ink, 0.85);
  const c = Math.round(S * 0.03);
  for (const [x, y, sx, sy] of [
    [0, 0, 1, 1],
    [S, 0, -1, 1],
    [0, S, 1, -1],
    [S, S, -1, -1],
  ] as const) {
    g.beginPath();
    g.moveTo(x, y);
    g.lineTo(x + c * sx, y);
    g.lineTo(x, y + c * sy);
    g.closePath();
    g.fill();
  }
}

/** Wait for the two faces; a poster drawn in Times because the fonts were late is not the poster. */
async function fontsReady(): Promise<void> {
  try {
    await Promise.all([
      document.fonts.load('16px "PressStart2P"'),
      document.fonts.load('16px "VT323"'),
      document.fonts.load('16px "JetBrainsMonoCode"'),
    ]);
  } catch {
    /* no FontFaceSet: whatever the canvas has */
  }
}

/** A drawn poster, and the two facts `makePoster` decides its size by. */
export interface Rendered {
  canvas: HTMLCanvasElement;
  /** Lines of the program that did not fit on the disc. */
  hidden: number;
  /** Pixels per QR module on the label. */
  qrCell: number;
}

/**
 * Draw the poster at `S` pixels a side. `posterBytes` turns it into a file.
 *
 * Every length but the code floor is a fraction of `S`, so the picture is
 * the same at any size; the floor is what makes a bigger one hold more.
 */
export async function renderPoster(p: PosterInput, S = POSTER_SIZE): Promise<Rendered> {
  await fontsReady();
  const mascotName = mascotFor(p.lang, p.run);
  const [bg, seal, mascotImg] = await Promise.all([
    p.assets?.image("bg_poster") ?? null,
    p.assets?.image("poster_seal") ?? null,
    p.assets?.image(mascotName) ?? null,
  ]);
  const canvas = document.createElement("canvas");
  canvas.width = S;
  canvas.height = S;
  const g = canvas.getContext("2d");
  if (!g) throw new Error("no 2d context");
  const faces = new Faces();
  const land = landColour(p.lang);
  const u = S / 1024;

  // -- the sleeve: the street, under a scrim so print reads over it --------
  fill(g, Theme.void, 0, 0, S, S);
  if (bg) g.drawImage(bg, 0, 0, S, S);
  fill(g, Theme.void, 0, 0, S, S, 0.55);

  // -- geometry ------------------------------------------------------------
  const m = Math.round(S * 0.045);
  const titleTop = m;
  const titleH = Math.round(S * 0.085);
  const discR = Math.round(S * 0.335);
  const discCx = Math.round(S * 0.385);
  const discCy = Math.round(S * 0.505);
  const holeR = Math.round(S * 0.17);
  const sideX = Math.round(S * 0.755);
  const sideW = S - m - sideX;
  const creditsTop = Math.round(S * 0.855);
  const creditsBottom = S - Math.round(S * 0.03);

  // -- title band ----------------------------------------------------------
  const brand = "CAUSEWAYBAY HACKER";
  const brandF = faces.at(13 * u, "pixel");
  text(g, brandF, brand, m, titleTop, Theme.cream);
  const smallF = faces.at(10 * u, "pixel");
  const stereo = `STEREO · 33⅓ RPM · ${p.lang.toUpperCase()} LAND`;
  text(g, smallF, stereo, m, titleTop + brandF.height + 6 * u, land);
  // A catalogue number, the way a label prints one in the corner: the first
  // four hex digits of the address, so two players' posters differ.
  const cat = `CWB·${p.user.address.slice(2, 6).toUpperCase()}`;
  text(g, smallF, cat, S - m - measure(g, smallF, cat), titleTop + 2 * u, Theme.cream, 0.75);
  const nameTop = titleTop + brandF.height + smallF.height + 18 * u;
  const nameH = titleTop + titleH - nameTop + 10 * u;
  const nm = fitLine(g, faces, "pixel", p.name.toUpperCase(), S - m * 2, 44 * u, 18 * u);
  text(g, nm.f, nm.s, m, nameTop + Math.max(0, (nameH - nm.f.height) / 2), Theme.coin);

  // -- the disc, and the program on it ------------------------------------
  vinyl(g, discCx, discCy, discR, holeR);
  const srcLines = expandTabs(p.source.replace(/\r\n?/g, "\n").replace(/\n$/, "")).split("\n");
  const cellW = (px: number) => measure(g, faces.at(px, "mono"), "M");
  const dfit = fitDisc(
    srcLines,
    discR - 16 * u,
    holeR + 14 * u,
    cellW,
    Math.round(24 * u),
    // Real pixels, not `u`: see `CODE_MIN_PX`. A longer program loses its
    // tail to `… n more lines` here; `makePoster` then tries the big square,
    // and the QR and the file's text chunks carry the whole of it regardless.
    CODE_MIN_PX,
    1.2,
    6,
    p.words.more,
  );
  const codeF = faces.at(dfit.px, "mono");
  const joined = srcLines.join("\n");
  const toneOfChar = tones(joined, p.lang);
  const starts: number[] = [];
  let acc = 0;
  for (const l of srcLines) {
    starts.push(acc);
    acc += l.length + 1;
  }
  const sideLabel = faces.at(11 * u, "pixel");
  text(
    g,
    sideLabel,
    `${p.words.sideA}  ·  ${p.file}`,
    m,
    discCy - discR - sideLabel.height - 8 * u,
    Theme.cream,
  );
  for (const gr of dfit.grooves) {
    const x = discCx + gr.x;
    const y = discCy + gr.y;
    if (gr.line === -1) {
      text(g, codeF, gr.text, x, y, Theme.dim);
      continue;
    }
    // Runs of one tone, positioned by column: the face is monospace.
    const base = starts[gr.line] + gr.col;
    let runStart = 0;
    for (let i = 1; i <= gr.text.length; i++) {
      const same = i < gr.text.length && toneOfChar[base + i] === toneOfChar[base + runStart];
      if (same) continue;
      const tone = toneOfChar[base + runStart] ?? "plain";
      text(g, codeF, gr.text.slice(runStart, i), x + runStart * dfit.charW, y, TONE_COL[tone]);
      runStart = i;
    }
  }
  const payload = qrPayload(p.user.address, p.signature, p.lang, p.source, p.packed ?? null);
  const qrCell = label(
    g,
    faces,
    discCx,
    discCy,
    holeR,
    land,
    qrModules(payload.text),
    brand,
    payload.hashed ? p.words.hashed : `${p.file} · ${p.signature ? "SIGNED" : p.words.unsigned}`,
    u,
  );

  // -- SIDE B: the output, with the mascot on top of it -------------------
  const outTop = Math.round(S * 0.4);
  const outBottom = discCy + discR;
  fill(g, Theme.ink, sideX, outTop, sideW, outBottom - outTop, 0.92);
  fill(g, p.run ? (p.run.ok ? Theme.admit : Theme.red) : Theme.dim, sideX, outTop, sideW, 5 * u);
  const pad = Math.round(9 * u);
  if (mascotImg) {
    const box = p.assets?.box.get(mascotName);
    const scale = Math.max(
      1,
      Math.floor((outTop - titleTop - titleH - 30 * u) / mascotImg.naturalHeight),
    );
    // Shadow on the panel's top edge, then the figure standing on it.
    g.fillStyle = css(Theme.ink, 0.5);
    g.beginPath();
    g.ellipse(sideX + sideW / 2, outTop + 2 * u, sideW * 0.32, 5 * u, 0, 0, Math.PI * 2);
    g.fill();
    sprite(g, mascotImg, sideX + sideW / 2, outTop + 3 * u, scale, box);
  }
  const outF0 = faces.at(11 * u, "pixel");
  text(g, sideLabel, p.words.sideB, sideX + pad, outTop + 5 * u + pad, Theme.cream);
  let oy = outTop + 5 * u + pad + sideLabel.height + 6 * u;
  if (p.run) {
    const head = fitLine(g, faces, "pixel", p.run.outcome, sideW - pad * 2, 11 * u, 7 * u);
    text(g, head.f, head.s, sideX + pad, oy, p.run.ok ? Theme.admit : Theme.red);
    oy += head.f.height + 4 * u;
    if (p.run.timings) {
      const tf = faces.at(11 * u, "mono");
      const tm = fitLine(g, faces, "mono", p.run.timings, sideW - pad * 2, 11 * u, 8 * u);
      text(g, tm.f, tm.s, sideX + pad, oy, Theme.dim);
      oy += tf.height + 6 * u;
    }
    fill(g, Theme.dim, sideX + pad, oy, sideW - pad * 2, 2 * u, 0.5);
    oy += 8 * u;
    const outLines = p.run.lines.map((l) => expandTabs(l.text));
    const ofit = fitMono(
      outLines,
      sideW - pad * 2,
      outBottom - pad - oy,
      cellW,
      Math.round(16 * u),
      OUT_MIN_PX,
      1.2,
      p.words.more,
    );
    const of = faces.at(ofit.px, "mono");
    for (const row of ofit.rows) {
      const stream = row.line >= 0 ? p.run.lines[row.line].stream : "";
      const col = row.line === -1 ? Theme.dim : stream === "stderr" ? Theme.pink : Theme.cream;
      text(g, of, row.text, sideX + pad, oy, col);
      oy += ofit.lineH;
    }
  } else {
    const nr = fitMono([p.words.nothingRun], sideW - pad * 2, 200 * u, cellW, 13 * u, 10 * u, 1.2);
    const nf = faces.at(nr.px, "mono");
    for (const row of nr.rows) {
      text(g, nf, row.text, sideX + pad, oy, Theme.dim);
      oy += nr.lineH;
    }
    void outF0;
  }

  // -- credits: the seal, the name, the address, the signature ------------
  const credH = creditsBottom - creditsTop;
  fill(g, Theme.cream, m, creditsTop, S - m * 2, credH, 0.94);
  fill(g, land, m, creditsTop, S - m * 2, 4 * u);
  let cx = m + pad;
  if (seal) {
    const sealScale = (credH - 10 * u) / seal.naturalHeight;
    const sealW = seal.naturalWidth * sealScale;
    g.save();
    if (!p.signature) g.globalAlpha = 0.28;
    sprite(
      g,
      seal,
      cx + sealW / 2,
      creditsTop + credH / 2 + (seal.naturalHeight * sealScale) / 2,
      sealScale,
      {
        feet: seal.naturalHeight,
        cx: seal.naturalWidth / 2,
      },
    );
    g.restore();
    if (!p.signature) {
      const uf = faces.at(10 * u, "pixel");
      g.save();
      g.translate(cx + sealW / 2, creditsTop + credH / 2);
      g.rotate(-0.28);
      g.font = uf.css;
      g.textAlign = "center";
      g.textBaseline = "middle";
      g.fillStyle = css(Theme.red);
      g.fillText(p.words.unsigned, 0, 0);
      g.restore();
    }
    cx += sealW + pad * 1.5;
  }
  const credW = S - m - pad - cx;
  const byF = faces.at(7 * u, "pixel");
  let cy = creditsTop + 4 * u + 6 * u;
  text(g, byF, p.words.by, cx, cy, Theme.wood);
  cy += byF.height + 2 * u;
  const who = fitLine(g, faces, "pixel", p.user.name.toUpperCase(), credW, 18 * u, 11 * u);
  text(g, who.f, who.s, cx, cy, Theme.ink);
  cy += who.f.height + 3 * u;
  const addrF = faces.at(15 * u, "mono");
  text(g, addrF, p.user.address, cx, cy, Theme.navy);
  cy += addrF.height + 1 * u;
  const sigF = faces.at(12 * u, "mono");
  if (p.signature) {
    // 132 characters in two rows of 66: both fit the column at this size and
    // a row boundary in the middle of `r` and `s` is as good as any other.
    text(g, sigF, p.signature.slice(0, 66), cx, cy, Theme.ink, 0.85);
    cy += sigF.height;
    text(g, sigF, p.signature.slice(66), cx, cy, Theme.ink, 0.85);
    cy += sigF.height + 3 * u;
  } else {
    text(g, sigF, "—", cx, cy, Theme.dim);
    cy += sigF.height * 2 + 2 * u;
  }
  const when = `${p.at.toISOString().slice(0, 16).replace("T", " ")} UTC`;
  const how = fitLine(g, faces, "pixel", `${p.words.how}  ·  ${when}`, credW, 7 * u, 6 * u);
  text(g, how.f, how.s, cx, Math.min(cy, creditsBottom - pad - how.f.height), Theme.wood);

  sleeveFrame(g, S, land);
  return { canvas, hidden: dfit.hidden, qrCell };
}

/**
 * The poster at the size it needs: 1024 unless that could not hold the
 * program at readable type or gave the label fewer than `QR_MIN_CELL` pixels
 * a module, in which case 2048. The small one is tried first because it is
 * the right answer for nearly every pad and a quarter of the bytes.
 */
export async function makePoster(p: PosterInput): Promise<Rendered & { size: number }> {
  // Deflated once, here, for both sizes: the label is the same on either.
  if (p.packed === undefined) p = { ...p, packed: await packSource(p.source) };
  const small = await renderPoster(p, POSTER_SIZE);
  if (small.hidden === 0 && small.qrCell >= QR_MIN_CELL) return { ...small, size: POSTER_SIZE };
  const large = await renderPoster(p, POSTER_SIZE_LARGE);
  return { ...large, size: POSTER_SIZE_LARGE };
}

// -- saving ----------------------------------------------------------------------

/** One file to write: its bytes, its name, its type. */
export interface PosterFile {
  bytes: Uint8Array;
  name: string;
  type: "image/png" | "image/jpeg";
}

/** The PNG bytes, with the proof written into the file. */
export async function posterBytes(
  canvas: HTMLCanvasElement,
  meta: Record<string, string>,
): Promise<Uint8Array> {
  const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/png"));
  if (!blob) throw new Error("the canvas gave no PNG");
  return withPngText(new Uint8Array(await blob.arrayBuffer()), meta);
}

/**
 * The same picture as a JPEG, for the places that want one (a phone's
 * gallery, a chat). It has no text chunks — the label is its proof.
 */
export async function posterJpeg(canvas: HTMLCanvasElement, quality = 0.92): Promise<Uint8Array> {
  const blob = await new Promise<Blob | null>((resolve) =>
    canvas.toBlob(resolve, "image/jpeg", quality),
  );
  if (!blob) throw new Error("the canvas gave no JPEG");
  return new Uint8Array(await blob.arrayBuffer());
}

/**
 * Put the file where the person is: on anything touched — a phone, and an
 * iPad just as much — into the share sheet (which is where Instagram is,
 * and where "Save Image" is; iPadOS has no downloads folder anybody looks
 * in); anywhere else, into the downloads folder. Says which it did, because
 * the two are different sentences on screen. Since 2026-09-18 the list is
 * one PNG; the shape stays a list because the share sheet takes one.
 *
 * Both need the browser's user activation, and the caller has to have kept
 * it: a poster is drawn, encoded and proved between the tap and this call,
 * and the activation a tap grants lasts about five seconds. The scene fires
 * POSTER on the `pointerup`, which is the event a finger's activation comes
 * from.
 */
export async function savePoster(
  files: readonly PosterFile[],
  touch: boolean,
): Promise<"shared" | "saved"> {
  const blobs = files.map((f) => new File([f.bytes as BlobPart], f.name, { type: f.type }));
  if (touch && typeof navigator.share === "function") {
    try {
      if (navigator.canShare?.({ files: blobs })) {
        await navigator.share({ files: blobs });
        return "shared";
      }
    } catch (e) {
      // A dismissed sheet is a choice, not a failure; anything else falls
      // through to the download, which works everywhere.
      if ((e as { name?: string }).name === "AbortError") return "shared";
    }
  }
  for (const file of blobs) {
    const url = URL.createObjectURL(file);
    const a = document.createElement("a");
    a.href = url;
    a.download = file.name;
    a.rel = "noopener";
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
  }
  return "saved";
}
