// Ported from CausewaybayRaiden/typescript/src/engine/tint.ts. The 16-bit register —
// the chip synth and the colour multiply — is that project's, unchanged except
// where noted.
/**
 * Colour multiply for canvas images, cached.
 *
 * LÖVE's `setColor` multiplies the sprite by a colour, keeping its shading;
 * canvas has no equivalent, and the usual `source-in` trick flattens the
 * sprite into a silhouette instead. The three-pass recipe below is the one
 * that actually multiplies: draw, multiply a flat fill over it, then mask the
 * result back to the sprite's own alpha.
 *
 * Tints repeat frame after frame — the same enemy shadow, the same agent
 * colour — so results are cached. Colours are quantised to 4 bits per channel
 * before they become a key, which keeps an animated tint (the infinite loop
 * pulses its green every frame) from filling the cache with near-duplicates.
 */
export type Rgb = readonly [number, number, number];

const LIMIT = 256;

export type Tinter = {
  /** The image drawn in `rgb`; the original when the tint is white. */
  get: (index: number, img: CanvasImageSource, rgb: Rgb) => CanvasImageSource;
  size: () => number;
};

function quantise(v: number): number {
  return Math.max(0, Math.min(15, Math.round(v * 15)));
}

function sizeOf(img: CanvasImageSource): { w: number; h: number } {
  if (img instanceof HTMLImageElement) return { w: img.naturalWidth, h: img.naturalHeight };
  if (img instanceof HTMLCanvasElement) return { w: img.width, h: img.height };
  const any = img as { width?: number; height?: number };
  return { w: any.width ?? 0, h: any.height ?? 0 };
}

export function createTinter(): Tinter {
  const cache = new Map<string, CanvasImageSource>();

  function get(index: number, img: CanvasImageSource, rgb: Rgb): CanvasImageSource {
    const [qr, qg, qb] = [quantise(rgb[0]), quantise(rgb[1]), quantise(rgb[2])];
    if (qr === 15 && qg === 15 && qb === 15) return img;

    const key = `${index}:${qr}:${qg}:${qb}`;
    const hit = cache.get(key);
    if (hit) return hit;

    const { w, h } = sizeOf(img);
    if (w < 1 || h < 1) return img;

    const out = document.createElement("canvas");
    out.width = w;
    out.height = h;
    const ctx = out.getContext("2d");
    if (!ctx) return img;
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(img, 0, 0);
    ctx.globalCompositeOperation = "multiply";
    ctx.fillStyle = `rgb(${(qr / 15) * 255} ${(qg / 15) * 255} ${(qb / 15) * 255})`;
    ctx.fillRect(0, 0, w, h);
    // The multiply pass paints the transparent margin too; mask it back off.
    ctx.globalCompositeOperation = "destination-in";
    ctx.drawImage(img, 0, 0);
    ctx.globalCompositeOperation = "source-over";

    // A plain flush rather than an LRU: this only fills up if something has
    // gone wrong, and rebuilding a few tints costs less than tracking them.
    if (cache.size >= LIMIT) cache.clear();
    cache.set(key, out);
    return out;
  }

  return { get, size: () => cache.size };
}
