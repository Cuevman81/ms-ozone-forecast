#!/usr/bin/env python3
"""Render the site favicon from the vector mark in favicon.svg.

The SVG is the source of truth and is what modern browsers load. This script
only exists to produce the raster fallbacks that cannot be expressed as SVG:

    favicon.ico          16 / 32 / 48 px, for older browsers and the implicit
                         GET /favicon.ico every browser makes
    apple-touch-icon.png 180 px, for iOS "add to home screen"

Both are committed, so this only needs to be re-run if the mark changes.

    python3 tools/make_favicon.py        # needs Pillow

Keep the geometry below in sync with favicon.svg by hand -- it is a dozen
numbers, and adding an SVG rasteriser as a dependency to avoid that would cost
more than it saves.
"""
import os
from PIL import Image, ImageDraw

BG     = "#222d32"   # --sidebar-bg
CURVE  = "#3c8dbc"   # --primary
PEAK   = "#f39c12"   # --warning, i.e. the AQI orange

VB     = 64          # SVG viewBox is 0 0 64 64
SS     = 16          # supersample factor
S      = VB * SS

RADIUS = 13
STROKE = 7
DOT_R  = 7
APEX   = (32, 19)

# The diurnal ozone curve: up fast in the morning, peak, then a slower decay.
BEZIERS = [
    ((7, 49), (17, 49), (22, 19), (32, 19)),
    ((32, 19), (42, 19), (47, 38), (57, 35)),
]

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def bezier(p0, p1, p2, p3, steps=140):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        x = u**3 * p0[0] + 3 * u**2 * t * p1[0] + 3 * u * t**2 * p2[0] + t**3 * p3[0]
        y = u**3 * p0[1] + 3 * u**2 * t * p1[1] + 3 * u * t**2 * p2[1] + t**3 * p3[1]
        pts.append((x * SS, y * SS))
    return pts


def render():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=RADIUS * SS, fill=BG)

    pts = []
    for b in BEZIERS:
        seg = bezier(*b)
        pts.extend(seg[1:] if pts else seg)
    d.line(pts, fill=CURVE, width=STROKE * SS, joint="curve")

    # PIL has no round line caps, so cap the ends by hand.
    r = STROKE * SS / 2
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=CURVE)

    ax, ay = APEX[0] * SS, APEX[1] * SS
    dr = DOT_R * SS
    d.ellipse([ax - dr, ay - dr, ax + dr, ay + dr], fill=PEAK)
    return img


def main():
    master = render()
    ico = os.path.join(HERE, "favicon.ico")
    master.resize((48, 48), Image.LANCZOS).save(
        ico, format="ICO", sizes=[(16, 16), (32, 32), (48, 48)]
    )
    png = os.path.join(HERE, "apple-touch-icon.png")
    # iOS ignores transparency and squares the corners itself, so flatten onto
    # the mark's own background rather than leaving the corners transparent.
    flat = Image.new("RGBA", master.size, BG)
    flat.alpha_composite(master)
    flat.convert("RGB").resize((180, 180), Image.LANCZOS).save(png, format="PNG")
    # The Shiny app serves its own copies out of shiny-app/www/. Mirror them
    # here so the two front ends cannot drift apart.
    www = os.path.join(HERE, "shiny-app", "www")
    os.makedirs(www, exist_ok=True)
    written = [ico, png]
    for name in ("favicon.svg", "favicon.ico", "apple-touch-icon.png"):
        dst = os.path.join(www, name)
        with open(os.path.join(HERE, name), "rb") as f:
            data = f.read()
        with open(dst, "wb") as f:
            f.write(data)
        written.append(dst)

    for p in written:
        print("wrote", os.path.relpath(p, HERE), os.path.getsize(p), "bytes")


if __name__ == "__main__":
    main()
