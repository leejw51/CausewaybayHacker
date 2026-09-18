/**
 * DISK READER: a poster back into a pad, and a claim back into a fact.
 *
 * The other half of `poster.ts`. Somebody hands over a picture — the PNG the
 * playground saved, or the JPEG Instagram made of it, or a photo of a
 * screen — and this recovers what is on it and says whether it is true:
 *
 *   1. **The file's own text**, when there is any. The PNG the playground
 *      writes carries `Source`, `Signer` and `Signature` as `iTXt` chunks
 *      (`poster.ts`, `withPngText`). Lossless and exact, so it is read first.
 *   2. **The label**, otherwise. The record's centre is a QR code with the
 *      same five fields (`qrPayload`); it survives every re-encoding the
 *      chunks do not. Decoded from the pixels with `jsQR`, and inflated
 *      when the poster deflated the program to fit it on.
 *
 * Then the signature is checked: recover the signer from (signature, source)
 * with `recoverSigner` and compare it to the address the picture names. The
 * verdict is one of four words — `verified`, `forged` (a signature that does
 * not recover to the address it sits next to), `unsigned`, or `hashed` (the
 * label held only the program's keccak because the program was too long, and
 * the file had no chunks; the code is on the disc but not in a form this can
 * read). What is *not* done: trusting the picture's own claim. The address
 * printed on it is what the signature is checked *against*, never what it
 * is taken from.
 *
 * Pure apart from `decodeLabel`, which needs pixels; `tests/diskreader.test.ts`
 * feeds the rest a PNG it builds and a payload it forges.
 */
import jsQR from "jsqr";
import { isLand, type Land } from "../net/protocol";
import { recoverSigner } from "../wallet/wallet";
import {
  fromBase64,
  parseQrPayload,
  QR_DEFLATE,
  QR_HASH,
  qrPayload,
  readPngText,
  unpackSource,
} from "./poster";

export type Verdict = "verified" | "forged" | "unsigned" | "hashed";

export interface Disk {
  source: string;
  lang: Land;
  /** The EIP-55 address the picture names as the author. */
  address: string;
  signature: string | null;
  /** The pad's name, when the file remembered one. */
  title: string | null;
  /** Where it came from: the file's chunks or the label's pixels. */
  via: "chunks" | "label";
  verdict: Verdict;
}

const PNG_SIG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/** Whether `bytes` begin the way a PNG does. */
export function isPng(bytes: Uint8Array): boolean {
  return bytes.length > 8 && PNG_SIG.every((b, i) => bytes[i] === b);
}

/** The verdict on a claim: who the signature recovers to, against who the picture names. */
export function judge(source: string, address: string, signature: string | null): Verdict {
  if (signature === null) return "unsigned";
  const who = recoverSigner(source, signature);
  return who && who.lower === address.toLowerCase() ? "verified" : "forged";
}

/**
 * The disk in a PNG's text chunks, or null when the file has none of ours.
 * `Source` and `Signer` are the two it cannot do without; the rest is
 * optional, and a missing `Signature` is an unsigned poster.
 */
export function fromChunks(bytes: Uint8Array): Disk | null {
  if (!isPng(bytes)) return null;
  const t = readPngText(bytes);
  if (typeof t.Source !== "string" || typeof t.Signer !== "string") return null;
  const signature = typeof t.Signature === "string" ? t.Signature : null;
  const lang = isLand(t.Lang) ? t.Lang : "rust";
  return {
    source: t.Source,
    lang,
    address: t.Signer,
    signature,
    title: typeof t.Title === "string" ? t.Title : null,
    via: "chunks",
    verdict: judge(t.Source, t.Signer, signature),
  };
}

/** The disk in a decoded label, or null when the text is not one of ours. */
/** A label's parts, and which of the three things its fifth field is. */
export interface Label {
  address: string;
  signature: string | null;
  lang: Land;
  body: string;
  kind: "source" | "deflate" | "hash";
}

/** The label's text apart, with no inflating: the synchronous half of `fromLabel`. */
export function parseLabel(text: string): Label | null {
  const p = parseQrPayload(text);
  if (!p) return null;
  const lang = isLand(p.lang) ? p.lang : "rust";
  const kind = p.body.startsWith(QR_HASH)
    ? "hash"
    : p.body.startsWith(QR_DEFLATE)
      ? "deflate"
      : "source";
  return { address: p.address, signature: p.signature, lang, body: p.body, kind };
}

/**
 * A label into a disk. Asynchronous for one reason: a deflated program has
 * to be inflated, and the browser's inflater is a stream. A deflated label
 * that will not inflate is not a disk at all — nothing on it can be checked.
 */
export async function fromLabel(text: string): Promise<Disk | null> {
  const l = parseLabel(text);
  if (!l) return null;
  const { address, signature, lang } = l;
  if (l.kind === "hash") {
    // The program is on the disc, not on the label. Nothing to load, but the
    // reader can still say whose it claims to be.
    return { source: "", lang, address, signature, title: null, via: "label", verdict: "hashed" };
  }
  let source = l.body;
  if (l.kind === "deflate") {
    const packed = fromBase64(l.body.slice(QR_DEFLATE.length));
    const inflated = packed ? await unpackSource(packed) : null;
    if (inflated === null) return null;
    source = inflated;
  }
  return {
    source,
    lang,
    address,
    signature,
    title: null,
    via: "label",
    verdict: judge(source, address, signature),
  };
}

/**
 * The label's text out of a picture's pixels, or null when no QR is found.
 * Decoded as bytes and then as UTF-8 — `jsQR`'s own string is Latin-1 for a
 * byte-mode code, and a Korean comment would come back as mojibake.
 */
export function decodeLabel(img: ImageData): string | null {
  const hit = jsQR(img.data, img.width, img.height);
  if (!hit) return null;
  return new TextDecoder().decode(new Uint8Array(hit.binaryData));
}

/**
 * The check a poster passes before it is saved, or the name of the check it
 * failed. Three, in the order they are cheapest: the signature recovers to
 * the address it will be printed next to (`signature`); the PNG's chunks
 * read back as this program by this author (`chunks`); the label decoded
 * from the picture's own pixels says the same (`label`) — unless the label
 * carries a hash, in which case it must be the hash of this program. A
 * poster that fails any of these is not written: a picture that promises a
 * proof and cannot deliver it is worse than none.
 *
 * `labelText` is what the decoder found in the pixels, or null when it
 * found nothing — injected so the check itself needs no canvas. `packed` is
 * the deflated source the poster was drawn with (`PosterInput.packed`), so
 * a deflated label can be checked the way a hashed one is: by making the
 * label this program would have and comparing, rather than inflating.
 */
export function proveDisk(
  png: Uint8Array,
  labelText: string | null,
  source: string,
  address: string,
  signature: string | null,
  packed: Uint8Array | null = null,
): "signature" | "chunks" | "label" | null {
  if (signature !== null && judge(source, address, signature) !== "verified") return "signature";
  const c = fromChunks(png);
  if (!c || c.source !== source || c.address.toLowerCase() !== address.toLowerCase())
    return "chunks";
  if (c.signature !== signature) return "chunks";
  if (labelText === null) return "label";
  const l = parseLabel(labelText);
  if (!l || l.address.toLowerCase() !== address.toLowerCase() || l.signature !== signature)
    return "label";
  if (l.kind === "source") {
    if (l.body !== source) return "label";
  } else if (qrPayload(address, signature, l.lang, source, packed).text !== labelText) {
    return "label";
  }
  return null;
}

/**
 * The label's text out of a picture, trying harder than one pass.
 *
 * `jsQR` binarises once and locates once, and on a 2048px poster it finds
 * the label about one time in two — the finder patterns are large, the
 * vinyl around the label is dark, the ring is cream. So the picture is
 * offered several ways: as it is, scaled to a few widths a scanner would
 * see it at, and cropped to where our label is (the disc's centre, at
 * `poster.ts`'s proportions — a photo of the poster will not line up, and
 * for that the whole-picture passes are there). First hit wins; null when
 * none of them finds a code.
 */
export function decodeLabelFrom(
  src: HTMLCanvasElement | HTMLImageElement | ImageBitmap,
): string | null {
  const w = "naturalWidth" in src ? src.naturalWidth : src.width;
  const h = "naturalHeight" in src ? src.naturalHeight : src.height;
  if (!w || !h) return null;
  const c = document.createElement("canvas");
  const g = c.getContext("2d");
  if (!g) return null;
  const attempt = (sx: number, sy: number, sw: number, sh: number, dw: number, dh: number) => {
    c.width = Math.max(1, Math.round(dw));
    c.height = Math.max(1, Math.round(dh));
    g.imageSmoothingEnabled = true;
    g.drawImage(src, sx, sy, sw, sh, 0, 0, c.width, c.height);
    return decodeLabel(g.getImageData(0, 0, c.width, c.height));
  };
  const scales = [1, 1024 / w, 768 / w, 512 / w].filter((k) => k <= 1 && k * w >= 300);
  for (const k of [...new Set(scales)]) {
    const hit = attempt(0, 0, w, h, w * k, h * k);
    if (hit) return hit;
  }
  // Our own layout: the label is centred at (0.385, 0.505) with radius 0.17.
  const cx = w * 0.385;
  const cy = h * 0.505;
  for (const r of [0.2, 0.24]) {
    const rr = Math.min(w, h) * r;
    for (const k of [1, 0.5]) {
      const hit = attempt(cx - rr, cy - rr, 2 * rr, 2 * rr, 2 * rr * k, 2 * rr * k);
      if (hit) return hit;
    }
  }
  return null;
}

/**
 * Read a picture: the chunks if the file is our PNG and has them, else the
 * label. `label` is how the caller gets the label's text out of the pixels
 * — `labelOf` in the browser, nothing in a test.
 */
export async function readDisk(
  bytes: Uint8Array,
  label: () => Promise<string | null>,
): Promise<Disk | null> {
  const chunked = fromChunks(bytes);
  if (chunked) return chunked;
  const text = await label();
  return text ? await fromLabel(text) : null;
}

/** The label's text out of an image file, or null when the browser cannot decode the picture or finds no code. */
export async function labelOf(blob: Blob): Promise<string | null> {
  const url = URL.createObjectURL(blob);
  try {
    const img = await new Promise<HTMLImageElement | null>((resolve) => {
      const i = new Image();
      i.onload = () => resolve(i);
      i.onerror = () => resolve(null);
      i.src = url;
    });
    return img ? decodeLabelFrom(img) : null;
  } finally {
    URL.revokeObjectURL(url);
  }
}
