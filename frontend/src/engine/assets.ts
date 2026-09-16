// Ported from CausewaybayGolang/typescript/src/engine/assets.ts (which in turn
// carries it over from that project's love2d Lua). Kept close to the original
// so a fix made there can still be read across; Causewaybay Hacker changes are
// marked where they occur.
/**
 * The art, and when it arrives.
 *
 * `crates/mkassets` has already done everything `love2d/src/assets.lua` does
 * at launch — keying the magenta studio backdrop out, cropping each character
 * to its ink and packing it into a 32x48 cell — so there is nothing to process
 * here. What is left is a scheduling problem the desktop build does not have:
 * the sixteen backgrounds are four megabytes and only one of them is on screen
 * at a time.
 *
 * So the sprites, which are a few kilobytes all together, are loaded up front
 * and the backgrounds are fetched the first time a street asks for one. A
 * background that has not arrived yet simply is not drawn, and `world.ts`
 * falls back to a flat sky for that frame; nothing waits.
 */

interface Entry {
  name: string;
  file: string;
  w: number;
  h: number;
  box?: Box;
  /** A strip: several frames of one animation in a single image. */
  frames?: number;
  fw?: number;
  fh?: number;
  /**
   * One box per frame, and note the plural — a strip carries `boxes` and a
   * single sprite carries `box`. Reading `box` on `walk_mei` returns undefined
   * and puts the character's feet at the bottom of her transparent margin.
   */
  boxes?: Box[];
}

/** What a caller needs to blit one frame out of a strip. */
export interface Strip {
  frames: number;
  fw: number;
  fh: number;
  boxes: Box[];
}

/**
 * One entry of `art/palette.json`: a strip whose frames differ only in hue.
 *
 * It is a separate file from the manifest on purpose. The manifest is the art
 * *contract* — names, sizes, the ink box — and this is a **measurement taken
 * out of** the delivered PNGs: the tube colour, the darker face under it and
 * the hue in degrees, for every frame. Keeping them apart means the numbers can
 * be re-measured when a sprite is redrawn without anything having to agree
 * about a schema, and it means a client that cannot find the file still draws
 * the art, just without the cycle.
 */
export interface Palette {
  frames: number;
  fw: number;
  fh: number;
  hues: Array<{
    i: number;
    tube: [number, number, number];
    face: [number, number, number];
    hue_deg: number;
  }>;
}

export interface Box {
  /** The middle of the ink, and the row its feet stand on. */
  cx: number;
  feet: number;
  h: number;
  /** The opaque bounds, for anything that stretches the ink rather than the
   *  transparent margin around it (the ribbon behind a CLEAR banner). */
  minx: number;
  miny: number;
  maxx: number;
  maxy: number;
}

export class Assets {
  private readonly images = new Map<string, HTMLImageElement>();
  private readonly entries = new Map<string, Entry>();
  private readonly pending = new Set<string>();
  readonly box = new Map<string, Box>();
  /** Measured hue tables, by asset name. Empty when `palette.json` is absent. */
  readonly palettes = new Map<string, Palette>();

  private constructor(private readonly base: string) {}

  /**
   * Read the manifest and load every sprite. Backgrounds are left for later;
   * `picture` starts one the first time it is asked for.
   */
  static async load(base = "art"): Promise<Assets> {
    const a = new Assets(base);
    const res = await fetch(`${base}/manifest.json`);
    if (!res.ok) throw new Error(`art manifest: ${res.status} ${res.statusText}`);
    const manifest = (await res.json()) as { art: Entry[] };
    const eager: Promise<unknown>[] = [];
    for (const e of manifest.art) {
      a.entries.set(e.name, e);
      if (e.box) a.box.set(e.name, e.box);
      // The .jpg files are the backgrounds; the .png files are the sprites.
      if (e.file.endsWith(".png")) eager.push(a.fetch(e));
    }
    // Optional, and deliberately not fatal: a build served without
    // `palette.json` draws every sprite exactly as before, and only the neon
    // stops cycling.
    eager.push(
      (async () => {
        try {
          const res2 = await fetch(`${base}/palette.json`);
          if (!res2.ok) return;
          const raw = (await res2.json()) as Record<string, Palette>;
          for (const [name, entry] of Object.entries(raw)) {
            if (entry && Array.isArray(entry.hues)) a.palettes.set(name, entry);
          }
        } catch {
          /* no palette: the art still draws */
        }
      })(),
    );
    await Promise.all(eager);
    return a;
  }

  private fetch(e: Entry): Promise<HTMLImageElement | null> {
    return new Promise((resolve) => {
      const img = new Image();
      img.decoding = "async";
      img.onload = () => {
        this.images.set(e.name, img);
        this.pending.delete(e.name);
        resolve(img);
      };
      // A missing file is not fatal: the renderer draws its fallback and the
      // game stays playable, which is also what makes a partial deploy visible
      // rather than a blank screen.
      img.onerror = () => {
        this.pending.delete(e.name);
        resolve(null);
      };
      img.src = `${this.base}/${e.file}`;
    });
  }

  /**
   * One image by name, or null when it is not here yet. `portrait` prefers the
   * `_p` variant of a background that has one.
   */
  picture(name: string, portrait = false): HTMLImageElement | null {
    if (portrait) {
      const p = this.picture(`${name}_p`);
      if (p) return p;
    }
    const hit = this.images.get(name);
    if (hit) return hit;
    const entry = this.entries.get(name);
    if (entry && !this.pending.has(name)) {
      this.pending.add(name);
      void this.fetch(entry);
    }
    return null;
  }

  /**
   * The frame grid of a strip, or null if this asset is not one.
   *
   * The cells are a fixed grid — `art/tools/strip.py` normalises each figure
   * into its own cell rather than cropping to its ink — so a frame is
   * `fw`-wide at `i * fw` and every frame's feet are on the same row. That is
   * what stops a four-frame walk from bobbing, and it is the reason to align
   * on the cell and not on per-frame bounds.
   */
  strip(name: string): Strip | null {
    const e = this.entries.get(name);
    if (!e || !e.frames || !e.fw || !e.fh) return null;
    return { frames: e.frames, fw: e.fw, fh: e.fh, boxes: e.boxes ?? [] };
  }

  /**
   * One image by name, **once it is here**.
   *
   * `picture` is for a frame: it answers with what has arrived and starts the
   * rest. A render that happens once and is saved to a file — the poster —
   * cannot draw a background that lands a frame later, so it waits for it.
   * Null for a name the manifest does not have, or a file that failed.
   */
  async image(name: string): Promise<HTMLImageElement | null> {
    const hit = this.images.get(name);
    if (hit) return hit;
    const e = this.entries.get(name);
    if (!e) return null;
    return this.fetch(e);
  }

  /** Ask for a background ahead of time, so it is there when the street opens. */
  prefetch(name: string, portrait = false): void {
    this.picture(name, portrait);
  }

  has(name: string): boolean {
    return this.images.has(name);
  }

  /**
   * The authored pixel size of an asset, from the manifest rather than from a
   * loaded image.
   *
   * Backgrounds arrive late, so a layout that measured `naturalWidth` would be
   * computed against nothing on the first frames and then reflow when the JPEG
   * lands — which on the overworld means every node jumping to a new place the
   * moment the picture appears. The manifest knows the size before the bytes
   * do.
   */
  size(name: string, portrait = false): { w: number; h: number } | null {
    const e = (portrait ? this.entries.get(`${name}_p`) : null) ?? this.entries.get(name);
    return e ? { w: e.w, h: e.h } : null;
  }
}
