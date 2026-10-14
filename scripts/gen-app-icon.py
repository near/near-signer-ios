#!/usr/bin/env python3
"""Draws the app icon (light and dark appearance) as 1024x1024 PNGs: the NEAR symbol on a shield.

The same images go into the AppMark image set, which the app shows on its lock and privacy screens.

Standard library only: a small anti-aliased polygon rasterizer instead of an SVG renderer.
"""

import math
import re
import struct
import zlib
from pathlib import Path

ASSETS = Path(__file__).resolve().parent.parent / "iOS/NearSigner/Assets.xcassets"
OUT = ASSETS / "AppIcon.appiconset"
MARK = ASSETS / "AppMark.imageset"
W = H = 1024
SUBSAMPLES = 8  # vertical samples per pixel row; horizontal coverage is exact

# The NEAR symbol, from the logo in the header of https://near.org (viewBox 0 0 16 16).
NEAR_SYMBOL = (
    "M13.9017 0.646973C13.3462 0.646973 12.8304 0.929357 12.5394 1.39357L9.40403 5.95741C9.30186 6.10784 "
    "9.34331 6.31059 9.49675 6.41075C9.6211 6.49202 9.78561 6.48196 9.89889 6.38645L12.9851 3.76201C13.0364 "
    "3.71677 13.1154 3.72137 13.1616 3.77165C13.1825 3.79469 13.1937 3.82444 13.1937 3.85502V12.0719C13.1937 "
    "12.1397 13.1377 12.1942 13.0684 12.1942C13.0312 12.1942 12.9962 12.1783 12.9727 12.1502L3.6435 "
    "1.20169C3.33966 0.850174 2.89352 0.647392 2.42388 0.646973H2.09782C1.21536 0.646973 0.5 1.34833 0.5 "
    "2.2135V13.7863C0.5 14.6515 1.21536 15.3528 2.09782 15.3528C2.65336 15.3528 3.16915 15.0704 3.46017 "
    "14.6062L6.59558 10.0424C6.69769 9.89194 6.65624 9.68919 6.50279 9.58903C6.37845 9.50776 6.21394 9.51782 "
    "6.10071 9.61334L3.01446 12.2378C2.96318 12.283 2.88412 12.2784 2.83797 12.2281C2.81703 12.2051 2.80592 "
    "12.1753 2.80634 12.1447V3.92583C2.80634 3.85796 2.86232 3.80349 2.93155 3.80349C2.96831 3.80349 3.00377 "
    "3.81941 3.02728 3.84748L12.3552 14.7981C12.659 15.1496 13.1052 15.3524 13.5749 15.3528H13.9009C14.7833 "
    "15.3532 15.4992 14.6523 15.5 13.7871V2.2135C15.5 1.34833 14.7842 0.646973 13.9017 0.646973Z"
)

VARIANTS = {
    # name: (background top, background bottom, shield, symbol)
    "AppIcon.png": ((14, 30, 44), (0, 150, 110), (245, 250, 248), (14, 30, 44)),
    "AppIcon-Dark.png": ((16, 18, 20), (8, 44, 36), (52, 199, 150), (16, 18, 20)),
}


# MARK: - Geometry


def svg_path_polygons(d, scale, dx, dy):
    """Flattens an SVG path (M, L, H, V, C, Z; absolute or relative) into closed polygons."""
    tokens = re.findall(r"[MLHVCZmlhvcz]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?", d)
    polygons, current = [], []
    x = y = start_x = start_y = 0.0
    command = None
    i = 0

    def number():
        nonlocal i
        value = float(tokens[i])
        i += 1
        return value

    while i < len(tokens):
        if tokens[i].isalpha():
            command = tokens[i]
            i += 1
        relative = command.islower()
        op = command.upper()
        if op == "Z":
            if current:
                polygons.append(current)
            current = []
            x, y = start_x, start_y
            continue
        if op == "M":
            nx, ny = number(), number()
            x, y = (x + nx, y + ny) if relative else (nx, ny)
            start_x, start_y = x, y
            if current:
                polygons.append(current)
            current = [(x, y)]
            command = "l" if relative else "L"  # further pairs are line-tos
        elif op == "L":
            nx, ny = number(), number()
            x, y = (x + nx, y + ny) if relative else (nx, ny)
            current.append((x, y))
        elif op == "H":
            nx = number()
            x = x + nx if relative else nx
            current.append((x, y))
        elif op == "V":
            ny = number()
            y = y + ny if relative else ny
            current.append((x, y))
        elif op == "C":
            values = [number() for _ in range(6)]
            if relative:
                values = [v + (x if k % 2 == 0 else y) for k, v in enumerate(values)]
            x1, y1, x2, y2, x3, y3 = values
            steps = 24
            for step in range(1, steps + 1):
                t = step / steps
                u = 1 - t
                px = u**3 * x + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t**3 * x3
                py = u**3 * y + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t**3 * y3
                current.append((px, py))
            x, y = x3, y3
    if current:
        polygons.append(current)
    return [[(px * scale + dx, py * scale + dy) for px, py in polygon] for polygon in polygons]


def shield_polygon():
    """Straight sides down to y=560, a curved taper to a point at y=860, rounded top corners."""
    cx, top, radius = W / 2, 210, 70

    def half(y):
        if y < top + radius:
            return 300 - (radius - math.sqrt(max(0.0, radius**2 - (top + radius - y) ** 2)))
        if y < 560:
            return 300
        return 300 * math.cos((y - 560) / 300 * math.pi / 2) ** 0.8

    ys = [top + k * 0.5 for k in range(2 * (860 - top) + 1)]
    right = [(cx + half(y), y) for y in ys]
    left = [(cx - half(y), y) for y in reversed(ys)]
    return [right + left]


# MARK: - Rasterizer


def coverage(polygons):
    """Per-pixel coverage (0...1) of polygons under the nonzero fill rule."""
    edges_by_row = [[] for _ in range(H)]
    for polygon in polygons:
        for (x0, y0), (x1, y1) in zip(polygon, polygon[1:] + polygon[:1]):
            if y0 == y1:
                continue
            winding = 1 if y1 > y0 else -1
            low, high = min(y0, y1), max(y0, y1)
            edge = (x0, y0, (x1 - x0) / (y1 - y0), low, high, winding)
            for row in range(max(0, int(low)), min(H, int(high) + 1)):
                edges_by_row[row].append(edge)

    result = []
    for row in range(H):
        full = [0.0] * (W + 1)  # difference array for fully covered pixels
        partial = [0.0] * (W + 1)
        edges = edges_by_row[row]
        for sample in range(SUBSAMPLES if edges else 0):
            sy = row + (sample + 0.5) / SUBSAMPLES
            crossings = sorted(
                (x0 + (sy - y0) * slope, winding) for x0, y0, slope, low, high, winding in edges if low <= sy < high
            )
            wind = 0
            for x, winding in crossings:
                before = wind
                wind += winding
                if before == 0 and wind != 0:
                    span_start = x
                elif before != 0 and wind == 0:
                    a, b = max(0.0, span_start), min(float(W), x)
                    if b <= a:
                        continue
                    ia, ib = int(a), int(b)
                    if ia == ib:
                        partial[ia] += b - a
                    else:
                        partial[ia] += ia + 1 - a
                        full[ia + 1] += 1
                        full[ib] -= 1
                        partial[ib] += b - ib
        values, running = [], 0.0
        for column in range(W):
            running += full[column]
            values.append(min(1.0, (running + partial[column]) / SUBSAMPLES))
        result.append(values)
    return result


# MARK: - Output


def blend(base, color, alpha):
    return tuple(base[i] + (color[i] - base[i]) * alpha for i in range(3))


def png(rows):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
        + chunk(b"IEND", b"")
    )


def main():
    shield = coverage(shield_polygon())
    # The symbol spans 15 x 14.7 units; 22 px per unit, centered in the upper part of the shield.
    scale = 22.0
    symbol = coverage(svg_path_polygons(NEAR_SYMBOL, scale, W / 2 - 8 * scale, 495 - 8 * scale))
    for name, (top, bottom, shield_color, symbol_color) in VARIANTS.items():
        rows = []
        for y in range(H):
            background = tuple(top[i] + (bottom[i] - top[i]) * y / (H - 1) for i in range(3))
            row = bytearray([0])
            for x in range(W):
                color = blend(background, shield_color, shield[y][x])
                color = blend(color, symbol_color, symbol[y][x])
                row += bytes(int(round(c)) for c in color)
            rows.append(bytes(row))
        data = png(rows)
        (OUT / name).write_bytes(data)
        (MARK / name.replace("AppIcon", "AppMark")).write_bytes(data)
        print(OUT / name)


if __name__ == "__main__":
    main()
