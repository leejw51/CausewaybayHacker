#!/usr/bin/env python3
"""
Cut a row of figures out of one Grok image and pack them into a sprite strip.

Grok will not reliably lay four frames on an even grid, so nothing here assumes
one. The magenta is knocked out, the remaining ink is split into connected
components, the `n` largest are taken left to right, and each is scaled to a
common height and centred in its own cell. Uneven spacing in the source
therefore costs nothing.

A walk cycle also has to keep its feet on one line or the character bobs, so
every frame is bottom-aligned on the same row rather than centred vertically.

    strip.py art/raw/walk_mei.png art/walk_mei.png 4 64 96
"""
import json
import os
import sys
from collections import deque

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from process import backdrop_ref, defringe, drop_trapped_backdrop, ink_bounds, knockout


def components(im, min_px=400):
    w, h = im.size
    a = im.getchannel("A").load()
    seen = bytearray(w * h)
    out = []
    for y in range(h):
        for x in range(w):
            if seen[y * w + x] or a[x, y] < 128:
                continue
            q = deque([(x, y)])
            seen[y * w + x] = 1
            minx = maxx = x
            miny = maxy = y
            n = 0
            while q:
                cx, cy = q.popleft()
                n += 1
                minx, maxx = min(minx, cx), max(maxx, cx)
                miny, maxy = min(miny, cy), max(maxy, cy)
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = cx + dx, cy + dy
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx] and a[nx, ny] >= 128:
                        seen[ny * w + nx] = 1
                        q.append((nx, ny))
            if n >= min_px:
                out.append((n, (minx, miny, maxx + 1, maxy + 1)))
    return out


def build_grid(src, dst, n, cw, ch, pad=0.06):
    """
    Cut a strip by even columns instead of by connected components.

    `build` takes the n largest ink blobs, which is right for a walk cycle
    where every frame is one figure. It is wrong for a progression whose last
    frame has fallen into two pieces: a shackle that has finally snapped is two
    blobs, so the component split would hand back seven frames for six stages
    and put half a shackle in its own cell.

    Here the image is divided into n equal columns and each column is cropped
    to its own ink, which survives a frame being any number of pieces.
    """
    im = defringe(drop_trapped_backdrop(knockout(Image.open(src)), ref=backdrop_ref(Image.open(src))))
    w, h = im.size
    step = w // n
    crops = []
    for i in range(n):
        col = im.crop((i * step, 0, (i + 1) * step if i < n - 1 else w, h))
        bb = ink_bounds(col)
        if bb is None:
            raise SystemExit(f"{src}: column {i + 1} of {n} is empty — re-roll it")
        crops.append(col.crop(bb))

    inner_w = int(round(cw * (1 - pad * 2)))
    inner_h = int(round(ch * (1 - pad * 2)))
    k = min(inner_h / max(c.height for c in crops), inner_w / max(c.width for c in crops))

    sheet = Image.new("RGBA", (cw * n, ch), (0, 0, 0, 0))
    boxes = []
    for i, c in enumerate(crops):
        nw, nh = max(1, round(c.width * k)), max(1, round(c.height * k))
        f = c.resize((nw, nh), Image.LANCZOS)
        r, g, b, a = f.split()
        f = Image.merge("RGBA", (r, g, b, a.point(lambda v: 255 if v >= 128 else 0)))
        ox = i * cw + (cw - nw) // 2
        oy = (ch - nh) // 2
        sheet.paste(f, (ox, oy))
        bb = ink_bounds(f)
        boxes.append({
            "cx": round(ox + (bb[0] + bb[2] - 1) / 2.0, 2),
            "feet": float(oy + bb[3]), "h": float(bb[3] - bb[1]),
            "minx": ox + bb[0], "miny": oy + bb[1],
            "maxx": ox + bb[2] - 1, "maxy": oy + bb[3] - 1,
        })
    sheet.save(dst)
    return {"file": dst, "w": cw * n, "h": ch, "frames": n, "fw": cw, "fh": ch, "boxes": boxes}


def build(src, dst, n, cw, ch, pad=0.06):
    im = defringe(drop_trapped_backdrop(knockout(Image.open(src))))
    comps = components(im)
    comps.sort(key=lambda c: -c[0])
    comps = comps[:n]
    if len(comps) < n:
        raise SystemExit(f"{src}: found {len(comps)} figures, wanted {n} — re-roll it")
    comps.sort(key=lambda c: c[1][0])          # left to right

    crops = [im.crop(b) for _, b in comps]
    # One scale for the whole strip, off the tallest frame, so the character is
    # the same size in every cell. Scaling each frame to fit its own cell would
    # make a taller pose smaller, which is the opposite of what a cycle needs.
    inner_h = int(round(ch * (1 - pad * 2)))
    inner_w = int(round(cw * (1 - pad * 2)))
    k = min(inner_h / max(c.height for c in crops), inner_w / max(c.width for c in crops))

    sheet = Image.new("RGBA", (cw * n, ch), (0, 0, 0, 0))
    boxes = []
    for i, c in enumerate(crops):
        nw, nh = max(1, round(c.width * k)), max(1, round(c.height * k))
        f = c.resize((nw, nh), Image.LANCZOS)
        r, g, b, a = f.split()
        f = Image.merge("RGBA", (r, g, b, a.point(lambda v: 255 if v >= 128 else 0)))
        ox = i * cw + (cw - nw) // 2
        oy = ch - nh - int(round(ch * pad))          # feet on one line
        sheet.paste(f, (ox, oy))
        bb = ink_bounds(f)
        boxes.append({
            "cx": round(ox + (bb[0] + bb[2] - 1) / 2.0, 2),
            "feet": float(oy + bb[3]),
            "h": float(bb[3] - bb[1]),
            "minx": ox + bb[0], "miny": oy + bb[1],
            "maxx": ox + bb[2] - 1, "maxy": oy + bb[3] - 1,
        })
    sheet.save(dst)
    return {"file": dst, "w": cw * n, "h": ch, "frames": n, "fw": cw, "fh": ch, "boxes": boxes}


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--grid"]
    fn = build_grid if "--grid" in sys.argv else build
    src, dst, n, cw, ch = args[0], args[1], int(args[2]), int(args[3]), int(args[4])
    print(json.dumps(fn(src, dst, n, cw, ch), indent=1))
