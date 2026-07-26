#!/usr/bin/env python3
"""Generate the Android/Wear launcher icon source PNGs in assets/icon/.

Dependency-free (the dev VM has no PIL/imagemagick) — reuses the same
white-dumbbell-on-deep-purple brand glyph and hand-rolled PNG encoder as
`generate_web_icons.py`, so the launcher icon matches the PWA and favicon.

Emits two 1024x1024 sources consumed by flutter_launcher_icons:
  * ic_launcher.png            legacy/square: glyph on a rounded brand tile.
  * ic_launcher_foreground.png adaptive foreground: white glyph on transparent,
                               kept inside the adaptive/Wear-circular safe zone.
The adaptive background is a flat colour (#673AB7), configured in pubspec.

Usage: python3 tool/generate_launcher_icons.py
"""

import math
import os

from generate_web_icons import (
    BRAND,
    WHITE,
    coverage,
    dumbbell_shapes,
    render,
    rounded_rect_sdf,
    write_png,
)

# Adaptive/circular masks crop hard: Android keeps the inner ~66%, Wear masks a
# circle. Keep the glyph a touch tighter than the web maskable (0.62) so no plate
# clips. 0.60 -> furthest glyph point ~0.30*size from centre, inside the ~0.33
# safe radius.
FOREGROUND_GLYPH_SCALE = 0.60


def render_foreground(size, glyph_scale=FOREGROUND_GLYPH_SCALE):
    """RGBA rows: white dumbbell glyph on a fully transparent canvas."""
    c = size / 2.0
    shapes = dumbbell_shapes(size, glyph_scale)
    ang = math.radians(-45.0)  # same 45° tilt as the web/favicon glyph
    cos_a, sin_a = math.cos(ang), math.sin(ang)

    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            px, py = x + 0.5, y + 0.5
            rx = c + (px - c) * cos_a - (py - c) * sin_a
            ry = c + (px - c) * sin_a + (py - c) * cos_a
            fg = 0.0
            for cx, cy, hw, hh, r in shapes:
                fg = max(fg, coverage(rounded_rect_sdf(rx, ry, cx, cy, hw, hh, r)))
            row += bytes((WHITE[0], WHITE[1], WHITE[2], int(255 * fg + 0.5)))
        rows.append(bytes(row))
    return rows


def main():
    out = os.path.join(os.path.dirname(__file__), "..", "assets", "icon")
    os.makedirs(out, exist_ok=True)
    size = 1024
    # Legacy/square source: rounded brand tile + glyph (render's non-maskable
    # path is exactly that).
    write_png(os.path.join(out, "ic_launcher.png"), size, render(size, maskable=False))
    # Adaptive foreground: transparent, white glyph in the safe zone.
    write_png(
        os.path.join(out, "ic_launcher_foreground.png"),
        size,
        render_foreground(size),
    )


if __name__ == "__main__":
    main()
