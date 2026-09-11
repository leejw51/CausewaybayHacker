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




def strong_px(c):
    """The studio magenta itself, as a bare colour test."""
    r, g, b = c[0], c[1], c[2]
    return r > 170 and b > 120 and g < r - 60 and g < b - 20


def backdrop_ref(im):
    """
    The studio backdrop's own colour, sampled from the raw border.

    It has to be read before `knockout` runs: knockout sets the border to
    transparent black, so sampling afterwards finds nothing and the exact-colour
    test below silently never fires. That was a real bug — it is why
    `badge_shackle` shipped a magenta blob on the first pass.
    """
    im = im.convert("RGB")
    w, h = im.size
    px = im.load()
    edge = [px[x, 0] for x in range(0, w, 7)] + [px[x, h - 1] for x in range(0, w, 7)]
    edge += [px[0, y] for y in range(0, h, 7)] + [px[w - 1, y] for y in range(0, h, 7)]
    edge = [c for c in edge if strong_px(c)]
    if not edge:
        return None
    n = len(edge)
    return (sum(c[0] for c in edge) / n, sum(c[1] for c in edge) / n, sum(c[2] for c in edge) / n)


def drop_trapped_backdrop(im, ref=None, max_share=0.10, exact=22.0):
    """
    Remove magenta the border-seeded flood fill could not reach.

    `knockout` is seeded from the edges, which is what protects pink *inside* a
    sprite. The cost is that backdrop the silhouette encloses — the gap between
    a whiteboard's legs and its board, the slot in a turnstile, the space under
    a raised arm — stays magenta, and at the 32-64px the map actually draws
    these at, a magenta pocket reads as a rendering fault.

    Flatness does not separate the two cases: fx_ribbon's painted cloth came
    back *flatter* (stdev 5.3) than the trapped pockets (8.6-13.4), because a
    trapped pocket has the sprite's own edge bleeding into it. Size does
    separate them, and it is the honest reason too — a hole in a silhouette is
    small, a sprite whose body is pink is not. Measured on this set the gap is
    the gap is wide: trapped pockets measured 0.2%-3.8% of the ink across this
    set, fx_ribbon's cloth is 33%. The cut is at 10% — above every pocket seen,
    and still a 3x margin under the one region that is genuinely art.

    Size alone has now been beaten twice, though — `boss_deadlock` at 3.8% when
    the cut was 3%, and `badge_shackle` at 10.8% when it was 10% — so there is
    a second, sharper test beside it. A trapped pocket is backdrop, so it is
    *literally the backdrop's colour*; art that merely happens to be pinkish is
    not. Measured: the shackle's pocket sat at distance 0.0 from the plate's
    own backdrop, while fx_ribbon's painted cloth is 38 away. Anything within
    `exact` of the backdrop colour goes regardless of how large it is, which
    catches a flat unshaded pocket that outgrew the size rule.
    """
    w, h = im.size
    px = im.load()

    def strong(x, y):
        r, g, b, a = px[x, y]
        # Tighter than is_bg on purpose: only the studio magenta itself, so an
        # ordinary pink is never even a candidate.
        return a > 127 and r > 170 and b > 120 and g < r - 60 and g < b - 20

    ink = sum(1 for y in range(h) for x in range(w) if px[x, y][3] > 127)
    if ink == 0:
        return im
    limit = ink * max_share
    seen = bytearray(w * h)
    for y in range(h):
        for x in range(w):
            if seen[y * w + x] or not strong(x, y):
                continue
            q, cells, touches = deque([(x, y)]), [], False
            seen[y * w + x] = 1
            while q:
                cx, cy = q.popleft()
                cells.append((cx, cy))
                if cx == 0 or cy == 0 or cx == w - 1 or cy == h - 1:
                    touches = True
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = cx + dx, cy + dy
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx] and strong(nx, ny):
                        seen[ny * w + nx] = 1
                        q.append((nx, ny))
            if touches:
                continue
            if len(cells) > limit:
                # Too big for the size rule — but if it is the backdrop's exact
                # colour it is backdrop anyway.
                if ref is None:
                    continue
                mid = cells[len(cells) // 2]
                c = px[mid[0], mid[1]]
                if sum((a - b) ** 2 for a, b in zip(c[:3], ref)) ** 0.5 > exact:
                    continue
            for cx, cy in cells:
                px[cx, cy] = (0, 0, 0, 0)
    return im


def defringe(im, passes=3):
    """
    Strip the magenta halo off the silhouette.

    The flood fill above is exact — it only clears pixels that really are the
    backdrop. But Grok renders at ~1024 and the studio magenta blends into the
    sprite's outline over a pixel or two, and those blended pixels fail the
    predicate (too little red, too much green) and survive. Downscaled they
    average into a pink rim round everything.

    So: any pixel that is *leaning* magenta AND touches transparency is
    backdrop bleed, and goes. Interior pink — Gogo's paws, a neon sign — never
    touches transparency, so it is never eaten. Two or three passes is the
    whole halo; more would start biting into the outline.
    """
    w, h = im.size
    px = im.load()
    for _ in range(passes):
        doomed = []
        for y in range(h):
            for x in range(w):
                r, g, b, a = px[x, y]
                if a < 128:
                    continue
                # Looser than is_bg: catches half-blended backdrop.
                if not (r > 110 and b > 60 and g < r - 25 and g < b + 40):
                    continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if nx < 0 or ny < 0 or nx >= w or ny >= h or px[nx, ny][3] < 128:
                        doomed.append((x, y))
                        break
        if not doomed:
            break
        for x, y in doomed:
            px[x, y] = (0, 0, 0, 0)
    return im


def ink_bounds(im, thresh=31):
    """assets.lua:measureBox — the opaque bounds, or None when nothing is."""
    w, h = im.size
    a = im.getchannel("A")
    bb = a.point(lambda v: 255 if v > thresh else 0).getbbox()
    return bb  # (minx, miny, maxx+1, maxy+1) or None


def make_sprite(src, dst, tw, th, pad=0.055, anchor="feet"):
    src_im = Image.open(src)
    # Sampled before knockout, which clears the border it would be read from.
    ref = backdrop_ref(src_im)
    im = defringe(drop_trapped_backdrop(knockout(src_im), ref=ref))
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
