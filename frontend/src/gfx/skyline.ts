/**
 * Causeway Bay, drawn one pixel at a time into three canvases.
 *
 * The parallax bands are generated rather than shipped as art, for three
 * reasons that all matter here: they tile seamlessly at any width, they can be
 * re-tinted per land without a second set of files, and they stay crisp
 * because nothing is ever resampled — the texture is used at `NearestFilter`
 * and the pixels are the pixels.
 *
 * What is being drawn is specific, not "a city": the harbour towers behind,
 * the mid-rise blocks with their lit grid of windows, and in front the thing
 * that actually says Causeway Bay — vertical signage stacked down a building's
 * face, and the tram wire strung across the street.
 */

/** One band's generated art, plus how tall it should sit on screen. */
export interface Band {
  canvas: HTMLCanvasElement;
  /** Fraction of the screen height the band occupies. */
  height: number;
  /** Where the band's bottom sits, 0 at the screen bottom, 1 at the top. */
  base: number;
}

type Rng = () => number;

/**
 * A seeded generator, so the skyline is the same on every run. A city that
 * reshuffled itself on reload would make every screenshot a different city and
 * every visual regression unprovable.
 */
function rng(seed: number): Rng {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 0x100000000;
  };
}

function surface(w: number, h: number): [HTMLCanvasElement, CanvasRenderingContext2D] {
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  const g = c.getContext("2d");
  if (!g) throw new Error("no 2d context for the skyline");
  g.imageSmoothingEnabled = false;
  return [c, g];
}

/** The far harbour: flat silhouettes, a few windows, nothing sharp. */
export function farBand(): Band {
  const W = 512;
  const H = 128;
  const [canvas, g] = surface(W, H);
  const r = rng(0x1f3c);
  g.clearRect(0, 0, W, H);

  let x = 0;
  while (x < W) {
    const w = 10 + Math.floor(r() * 26);
    const h = 26 + Math.floor(r() * 74);
    const y = H - h;
    g.fillStyle = "#1b2450";
    g.fillRect(x, y, w, h);
    // A single lighter face on one side gives the block a direction without
    // costing a second colour.
    g.fillStyle = "#232e63";
    g.fillRect(x, y, Math.max(2, w >> 2), h);
    // Sparse windows: the far towers read as distance partly because so few
    // of their lights are resolvable.
    g.fillStyle = "#3a4a96";
    for (let i = 0; i < (w * h) / 220; i++) {
      const wx = x + 3 + Math.floor(r() * Math.max(1, w - 6));
      const wy = y + 4 + Math.floor(r() * Math.max(1, h - 8));
      g.fillRect(wx, wy, 1, 1);
    }
    // A mast on the tallest ones.
    if (h > 84 && r() < 0.5) {
      g.fillStyle = "#1b2450";
      g.fillRect(x + (w >> 1), y - 8, 1, 8);
      g.fillStyle = "#d82800";
      g.fillRect(x + (w >> 1), y - 9, 1, 1);
    }
    x += w + (r() < 0.3 ? 2 : 0);
  }
  return { canvas, height: 0.45, base: 0.34 };
}

/** The mid blocks: a proper grid of lit windows, warm against the navy. */
export function midBand(): Band {
  const W = 512;
  const H = 160;
  const [canvas, g] = surface(W, H);
  const r = rng(0x51a7);
  g.clearRect(0, 0, W, H);

  let x = 0;
  while (x < W) {
    const w = 22 + Math.floor(r() * 34);
    const h = 48 + Math.floor(r() * 96);
    const y = H - h;
    g.fillStyle = "#141c48";
    g.fillRect(x, y, w, h);
    g.fillStyle = "#1d2a63";
    g.fillRect(x + 1, y + 1, w - 2, h - 1);
    // The window grid is what makes a block read as inhabited. Four pixels on,
    // three off, and roughly a third of them lit.
    for (let wy = y + 4; wy < H - 3; wy += 7) {
      for (let wx = x + 3; wx < x + w - 3; wx += 7) {
        const lit = r();
        if (lit < 0.34) g.fillStyle = "#f8d030";
        else if (lit < 0.44) g.fillStyle = "#fcecc8";
        else if (lit < 0.5) g.fillStyle = "#50d8f8";
        else continue;
        g.fillRect(wx, wy, 4, 3);
      }
    }
    // A parapet line, so the rooftops are not all the same flat edge.
    g.fillStyle = "#0e1436";
    g.fillRect(x, y, w, 2);
    x += w + 1;
  }
  return { canvas, height: 0.62, base: 0.12 };
}

/**
 * The near layer, and the one that names the place: vertical signage hung off
 * the building faces, and the tram wire in front of everything.
 */
export function nearBand(): Band {
  const W = 512;
  const H = 200;
  const [canvas, g] = surface(W, H);
  const r = rng(0x9d21);
  g.clearRect(0, 0, W, H);

  const NEON = ["#f27828", "#50d8f8", "#f878a8", "#f8d030", "#00a844"];

  let x = 0;
  while (x < W) {
    const w = 40 + Math.floor(r() * 46);
    const h = 70 + Math.floor(r() * 110);
    const y = H - h;
    g.fillStyle = "#05081a";
    g.fillRect(x, y, w, h);
    g.fillStyle = "#0c1130";
    g.fillRect(x + 2, y + 2, w - 4, h - 2);

    // Windows, dimmer than the mid band: these are close enough to be in
    // shadow, and a bright near layer would fight the UI in front of it.
    for (let wy = y + 8; wy < H - 6; wy += 11) {
      for (let wx = x + 6; wx < x + w - 8; wx += 12) {
        if (r() < 0.28) {
          g.fillStyle = "#26306a";
          g.fillRect(wx, wy, 6, 5);
        }
      }
    }

    // The signs. Stacked blocks down one edge of the face, the way a
    // mahjong parlour or a herbal tea shop hangs its name over the street.
    if (w > 46 && r() < 0.8) {
      const col = NEON[Math.floor(r() * NEON.length)];
      const sx = r() < 0.5 ? x + 4 : x + w - 16;
      let sy = y + 10 + Math.floor(r() * 20);
      const blocks = 2 + Math.floor(r() * 4);
      for (let i = 0; i < blocks && sy < H - 20; i++) {
        const bh = 9 + Math.floor(r() * 5);
        g.fillStyle = "#05081a";
        g.fillRect(sx - 1, sy - 1, 14, bh + 2);
        g.fillStyle = col;
        g.fillRect(sx, sy, 12, bh);
        // A darker core turns a solid block into a lit outline, which is what
        // a neon sign actually looks like from across a street.
        g.fillStyle = "#05081a";
        g.fillRect(sx + 3, sy + 3, 6, Math.max(1, bh - 6));
        sy += bh + 4;
      }
      // The bracket holding it to the wall.
      g.fillStyle = "#281810";
      g.fillRect(sx + 5, y + 6, 2, 6);
    }
    x += w;
  }

  // The tram wire, last, in front of everything: two lines and the poles that
  // carry them. It is the single most Hong Kong thing in the picture.
  g.fillStyle = "#0a0d1f";
  g.fillRect(0, 26, W, 1);
  g.fillRect(0, 33, W, 1);
  for (let px = 12; px < W; px += 96) {
    g.fillRect(px, 20, 2, 40);
    g.fillRect(px - 4, 20, 10, 2);
  }

  return { canvas, height: 1.0, base: -0.5 };
}

/** A soft radial disc, for the additive glow the fanfare throws. */
export function glowTexture(): HTMLCanvasElement {
  const S = 128;
  const [canvas, g] = surface(S, S);
  const grad = g.createRadialGradient(S / 2, S / 2, 0, S / 2, S / 2, S / 2);
  grad.addColorStop(0, "rgba(255,255,255,1)");
  grad.addColorStop(0.35, "rgba(255,255,255,0.45)");
  grad.addColorStop(1, "rgba(255,255,255,0)");
  g.fillStyle = grad;
  g.fillRect(0, 0, S, S);
  return canvas;
}
