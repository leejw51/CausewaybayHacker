#!/usr/bin/env python3
"""
Recolour one badge into another metal, keeping its silhouette exactly.

BE's badge set says tiers inside a family "differ by colour and number only —
the silhouette is the family". Asking the generator for the same shape in three
metals does not honour that: three rolls give three shapes. Grok returned a
single chevron pointing down in bronze and a *double* chevron pointing up in
silver, which is the failure the rule exists to prevent.

So the tiers are derived instead. The hue of the metal is remapped and the
value structure — bevel, shine, dark outline — is left alone, so bronze, silver
and gold are the same pixels in different colours and cannot drift apart.

    tier.py art/badge_chevron.png art/badge_chevron_silver.png silver
"""
import colorsys
import sys

from PIL import Image

# hue (0-1), saturation multiplier, value multiplier
METALS = {
    "bronze": (0.055, 1.00, 0.82),
    "silver": (0.590, 0.14, 1.04),
    "gold": (0.125, 1.00, 1.00),
}


def retint(src, dst, metal):
    h2, smul, vmul = METALS[metal]
    im = Image.open(src).convert("RGBA")
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 128:
                continue
            hh, ss, vv = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            # Leave the ink outline and anything already neutral alone: they are
            # the drawing, not the metal, and recolouring them loses the edge.
            if ss < 0.18 or vv < 0.22:
                continue
            nr, ng, nb = colorsys.hsv_to_rgb(h2, min(1.0, ss * smul), min(1.0, vv * vmul))
            px[x, y] = (round(nr * 255), round(ng * 255), round(nb * 255), a)
    im.save(dst)
    return im


if __name__ == "__main__":
    retint(sys.argv[1], sys.argv[2], sys.argv[3])
    print(sys.argv[2])
