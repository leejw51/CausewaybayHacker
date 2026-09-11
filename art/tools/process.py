#!/usr/bin/env python3
"""
Turn raw Grok output in art/raw/ into a shippable asset in art/.

Why this exists: CausewaybayGolang knocked the magenta studio backdrop out at
load time (love2d/src/assets.lua) or ahead of time (crates/mkassets). This
repo's loader, frontend/src/engine/assets.ts, does no pixel work — it fetches
a PNG and draws it — so the knockout has to happen here, before the file is
handed over.

The flood fill is a port of `knockout` in love2d/src/assets.lua, predicate and
all: seeded from the border, magenta *and* the lime fallback, four-connected.
Seeded from the border rather than global, so pink inside the sprite (Gogo's
milk tea, a neon sign) survives.

`measureBox` from the same file gives the manifest's `box`, which is what lets
a sprite stand on its feet instead of on the corner of its canvas.

    process.py sprite art/raw/boss_x.png art/boss_x.png 128 128
    process.py bg     art/raw/bg_x.png   art/bg_x.jpg   1152 768
"""
import json
import sys
from collections import deque

from PIL import Image


def is_bg(px, w, h, x, y):
    """assets.lua:isBg — transparent, the magenta screen, or leftover lime."""
    r, g, b, a = px[x, y]
    if a < 31:                                    # a < 0.12
        return True
    r, g, b = r / 255.0, g / 255.0, b / 255.0
    if r > 0.55 and b > 0.30 and g < 0.45 and b < r + 0.2:
        return True                               # magenta / hot pink
    if g > 0.62 and r < 0.50 and b < 0.50:
        return True                               # leftover lime
    return False


def knockout(im):
    """Border-seeded four-connected flood fill, exactly assets.lua's."""
    im = im.convert("RGBA")
    w, h = im.size
    px = im.load()
    seen = bytearray(w * h)
    q = deque()

    def push(x, y):
        if x < 0 or y < 0 or x >= w or y >= h:
            return
        k = y * w + x
        if seen[k] or not is_bg(px, w, h, x, y):
            return
        seen[k] = 1
        q.append((x, y))

    for x in range(w):
        push(x, 0)
        push(x, h - 1)
    for y in range(h):
        push(0, y)
        push(w - 1, y)
    while q:
        x, y = q.popleft()
        px[x, y] = (0, 0, 0, 0)
        push(x + 1, y)
        push(x - 1, y)
        push(x, y + 1)
        push(x, y - 1)
    return im


def ink_bounds(im, thresh=31):
    """assets.lua:measureBox — the opaque bounds, or None when nothing is."""
    w, h = im.size
    a = im.getchannel("A")
    bb = a.point(lambda v: 255 if v > thresh else 0).getbbox()
    return bb  # (minx, miny, maxx+1, maxy+1) or None


def make_sprite(src, dst, tw, th, pad=0.055, anchor="feet"):
    im = knockout(Image.open(src))
    bb = ink_bounds(im)
    if bb is None:
        raise SystemExit(f"{src}: the knockout removed everything — re-roll it")
    im = im.crop(bb)

    # Room to breathe inside the cell, so a sprite is not flush to its edge.
    inner_w = max(1, int(round(tw * (1 - pad * 2))))
    inner_h = max(1, int(round(th * (1 - pad * 2))))
    k = min(inner_w / im.width, inner_h / im.height)
    nw, nh = max(1, int(round(im.width * k))), max(1, int(round(im.height * k)))
    # Area-average the colour (a nearest-neighbour reduction of a 1024px
    # render is noise), then snap the alpha back to 0/255. The siblings'
    # sprites are all binary alpha and the engine scales by an integer factor:
    # a soft edge becomes mud.
    im = im.resize((nw, nh), Image.LANCZOS)
    r, g, b, a = im.split()
    a = a.point(lambda v: 255 if v >= 128 else 0)
    im = Image.merge("RGBA", (r, g, b, a))

    out = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
    ox = (tw - nw) // 2
    oy = th - nh - int(round(th * pad)) if anchor == "feet" else (th - nh) // 2
    out.paste(im, (ox, max(0, oy)))
    out.save(dst)
    return out


def box_of(im):
    bb = ink_bounds(im)
    if bb is None:
        return None
    minx, miny, maxx, maxy = bb[0], bb[1], bb[2] - 1, bb[3] - 1
    return {
        "cx": round((minx + maxx) / 2.0, 2),
        "feet": float(maxy + 1),
        "h": float(maxy - miny + 1),
        "minx": minx, "miny": miny, "maxx": maxx, "maxy": maxy,
    }


def make_bg(src, dst, tw, th):
    im = Image.open(src).convert("RGB")
    # Cover, then centre-crop: a background stretched to a new aspect looks
    # broken rather than stylised, and the ground line has to stay level.
    k = max(tw / im.width, th / im.height)
    nw, nh = int(round(im.width * k)), int(round(im.height * k))
    im = im.resize((nw, nh), Image.LANCZOS)
    left, top = (nw - tw) // 2, (nh - th) // 2
    im = im.crop((left, top, left + tw, top + th))
    im.save(dst, "JPEG", quality=90, optimize=True)
    return im


if __name__ == "__main__":
    kind, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    tw, th = int(sys.argv[4]), int(sys.argv[5])
    anchor = sys.argv[6] if len(sys.argv) > 6 else "feet"
    if kind == "sprite":
        im = make_sprite(src, dst, tw, th, anchor=anchor)
        print(json.dumps({"file": dst, "w": tw, "h": th, "box": box_of(im)}))
    else:
        make_bg(src, dst, tw, th)
        print(json.dumps({"file": dst, "w": tw, "h": th}))
