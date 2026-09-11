#!/usr/bin/env python3
"""
Does every node in every pack land on ground?

SPEC §12 puts node x/y as fractions of the map image, so a plate with a large
sky or water region guarantees nodes floating in it — the exact bug
docs/design-review.md §13 found in the sibling plate, and the exact bug that
came back in `map_rust` because "land fills the frame" was asked for in a
prompt and then never verified against the coordinates that have to sit on it.

A prompt is not a test. This is the test.

    art/tools/checknodes.py            # every pack, both orientations
"""
import glob
import os
import re
import sys

from PIL import Image, ImageStat

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
ART = os.path.join(ROOT, "art")
# How far around the node to look: the marker is drawn at roughly this
# fraction of the plate, so a node is "on water" only if its whole footprint is.
R = 0.018


def flatness(im, nx, ny, r=0.022):
    """
    How featureless is the plate around this node?

    Hue does not work as a test. `map_go` is a night plate whose *ground* is
    indigo, so a blue-dominance check called a lit platform and a neon stall
    "water". What actually separates ground from void is structure: ground has
    roofs, kerbs and outlines and therefore high local variance, while sky and
    open water are flat. This is hue-independent, so one test covers a sunlit
    plate and a night one.

    Returns the mean per-channel standard deviation of the neighbourhood.
    """
    w, h = im.size
    x0 = max(0, int((nx - r) * w))
    x1 = min(w, int((nx + r) * w) + 1)
    y0 = max(0, int((ny - r) * h))
    y1 = min(h, int((ny + r) * h) + 1)
    tile = im.crop((x0, y0, max(x0 + 1, x1), max(y0 + 1, y1)))
    return sum(ImageStat.Stat(tile).stddev) / 3.0


# Below this the neighbourhood has no edges in it at all — no roof, no kerb,
# no outline — which on these plates means open sky or open water. Calibrated
# by eye against crops: genuinely dead regions measure 0.2-0.9, a dim corner
# that still has trees and a roof measures 5.3, lit ground runs 20-40. The cut
# is at 4, an order of magnitude clear of both sides.
FLAT = 4.0


def nodes(path):
    out = []
    for m in re.finditer(r'map\s*=\s*\{\s*x\s*=\s*([\d.]+)\s*,\s*y\s*=\s*([\d.]+)', open(path).read()):
        out.append((float(m.group(1)), float(m.group(2))))
    return out


def check(plate, pts, label):
    im = Image.open(plate).convert("RGB")
    bad = []
    for i, (nx, ny) in enumerate(pts, 1):
        f = flatness(im, nx, ny)
        if f < FLAT:
            bad.append((i, nx, ny, round(f, 1)))
    mark = "FAIL" if bad else "ok"
    print(f"  {label:34} {len(pts):3} nodes  {mark}"
          + (f"  floating: {[f'{i}@({x},{y}) flat={f}' for i, x, y, f in bad]}" if bad else ""))
    return bad


if __name__ == "__main__":
    fails = 0
    for pack in sorted(glob.glob(os.path.join(ROOT, "content", "*", "*.toml"))):
        land = os.path.basename(os.path.dirname(pack))
        cat = os.path.splitext(os.path.basename(pack))[0]
        pts = nodes(pack)
        if not pts:
            continue
        for suffix, tag in (("", "landscape"), ("_p", "portrait")):
            plate = os.path.join(ART, f"map_{land}{suffix}.jpg")
            if os.path.exists(plate):
                fails += len(check(plate, pts, f"{land}.{cat} on map_{land}{suffix} ({tag})"))
    print("\n" + ("every node is on ground" if not fails else f"{fails} nodes floating — re-roll the plate"))
    sys.exit(1 if fails else 0)
