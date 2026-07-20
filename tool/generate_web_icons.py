#!/usr/bin/env python3
"""Generate the PWA icons in web/icons/ (plus web/favicon.png).

Dependency-free on purpose — the dev VM has no PIL/numpy/imagemagick. Draws a
white dumbbell on the app's deep-purple brand colour using signed-distance
rounded rectangles, anti-aliased per pixel, and writes the PNGs by hand.

Usage: python3 tool/generate_web_icons.py
"""

import math
import os
import struct
import zlib

BRAND = (0x67, 0x3A, 0xB7)  # Colors.deepPurple, same seed as the Flutter theme
WHITE = (0xFF, 0xFF, 0xFF)


def rounded_rect_sdf(px, py, cx, cy, hw, hh, r):
    """Signed distance from point to a rounded rect centered at (cx, cy)."""
    qx = abs(px - cx) - (hw - r)
    qy = abs(py - cy) - (hh - r)
    ox = max(qx, 0.0)
    oy = max(qy, 0.0)
    return math.hypot(ox, oy) + min(max(qx, qy), 0.0) - r


def coverage(d):
    """SDF -> [0,1] pixel coverage with ~1px anti-aliasing band."""
    return min(1.0, max(0.0, 0.5 - d))


def dumbbell_shapes(size, scale):
    """Rounded rects (cx, cy, hw, hh, r) of a horizontal dumbbell glyph.

    `scale` is the glyph width as a fraction of the canvas; the glyph is
    rotated later by sampling rotated coordinates.
    """
    c = size / 2.0
    u = size * scale  # glyph span in px
    shapes = [
        # bar
        (c, c, u * 0.50, u * 0.045, u * 0.03),
        # inner plates
        (c - u * 0.32, c, u * 0.045, u * 0.21, u * 0.035),
        (c + u * 0.32, c, u * 0.045, u * 0.21, u * 0.035),
        # outer plates
        (c - u * 0.42, c, u * 0.04, u * 0.145, u * 0.03),
        (c + u * 0.42, c, u * 0.04, u * 0.145, u * 0.03),
    ]
    return shapes


def render(size, maskable, favicon=False):
    """Return RGBA bytes for one icon."""
    c = size / 2.0
    # Regular icons get a rounded-corner tile on transparency; maskable icons
    # bleed to the edge and keep the glyph inside the 80% safe zone.
    corner_r = 0.0 if maskable else size * 0.20
    glyph_scale = 0.62 if maskable else 0.78
    if favicon:
        corner_r = size * 0.25
        glyph_scale = 0.86
    shapes = dumbbell_shapes(size, glyph_scale)
    # 45° rotation reads better at tiny sizes than a flat horizontal bar.
    ang = math.radians(-45.0)
    cos_a, sin_a = math.cos(ang), math.sin(ang)

    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            px, py = x + 0.5, y + 0.5
            if maskable:
                bg = 1.0
            else:
                bg = coverage(rounded_rect_sdf(px, py, c, c, c, c, corner_r))
            # rotate sample point around the centre for the glyph
            rx = c + (px - c) * cos_a - (py - c) * sin_a
            ry = c + (px - c) * sin_a + (py - c) * cos_a
            fg = 0.0
            for cx, cy, hw, hh, r in shapes:
                fg = max(fg, coverage(rounded_rect_sdf(rx, ry, cx, cy, hw, hh, r)))
            fg *= bg
            r_ = BRAND[0] * (1 - fg) + WHITE[0] * fg
            g_ = BRAND[1] * (1 - fg) + WHITE[1] * fg
            b_ = BRAND[2] * (1 - fg) + WHITE[2] * fg
            a_ = 255 * bg
            row += bytes((int(r_ + 0.5), int(g_ + 0.5), int(b_ + 0.5), int(a_ + 0.5)))
        rows.append(bytes(row))
    return rows


def write_png(path, size, rows):
    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(png)
    print(f"{path} ({len(png)} bytes)")


def main():
    root = os.path.join(os.path.dirname(__file__), "..", "web")
    targets = [
        (os.path.join(root, "icons", "Icon-192.png"), 192, False, False),
        (os.path.join(root, "icons", "Icon-512.png"), 512, False, False),
        (os.path.join(root, "icons", "Icon-maskable-192.png"), 192, True, False),
        (os.path.join(root, "icons", "Icon-maskable-512.png"), 512, True, False),
        (os.path.join(root, "favicon.png"), 32, False, True),
    ]
    for path, size, maskable, favicon in targets:
        write_png(path, size, render(size, maskable, favicon))


if __name__ == "__main__":
    main()
