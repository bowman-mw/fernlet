#!/usr/bin/env python3
"""Renders the Messages extension's iMessage App Icon set from the Home Screen app icon.

WHY THIS FILE EXISTS. An iMessage app must ship an "iMessage App Icon" set: twelve slots, nine
of them roughly 4:3, and App Store Connect refuses the upload without it. The first set
(2026-09-23) was a placeholder, the square app icon scaled with `sips` and padded out to each
canvas. The owner approved purpose-made art on 2026-09-24 and chose the Home Screen icon's own
fern sprig, re-framed for the wider canvas. This script makes the set, so the art can be
re-derived instead of being twelve PNGs nobody knows how to remake. THIS FILE IS THE SOURCE OF
TRUTH for the set. If the Home Screen icon changes, re-run it. Never hand-edit the PNGs.

SOURCE. `App/Fernlet/Assets.xcassets/AppIcon.appiconset/fernlet-icon-1024.png`, the only art
there is. Its background is a soft cream radial gradient, measured on 2026-09-24 (BACKGROUND_*
below). The fit's RMS residual, about 0.8 of 255, is the PNG's own dither, so the model is exact
to the noise. The sprig is flat ink in three colours (INKS). Each pixel is un-composited
against the modelled background: alpha is taken from whichever ink explains the pixel best,
then colour = (pixel - (1 - alpha) * background) / alpha. The result is a clean, premultiplied
sprig layer with no cream fringe, which is then laid on a background generated for each canvas.

THE 4:3 LAYOUT. Three rules. `layout()` computes the result; nothing is placed by eye.

  * Angle. The Home Screen icon runs its stem corner to corner along the square's diagonal
    (about 47 degrees). So the 4:3 icon runs it along the 4:3 diagonal, a clockwise turn of
    45 - atan(3/4) = 8.13 degrees. It keeps the same relation to its canvas, not the same
    compass angle.
  * Size and position. On iOS 26.5 the Messages "+" menu draws this icon at 36 x 27 pt inside a
    superellipse, |2x/W - 1|^n + |2y/H - 1|^n <= 1 with n = 2.30. That was measured from a
    simulator screenshot on 2026-09-24 (MASK_EXPONENT); Apple's own items there are circles.
    The mask cuts the corners hard, and the corners are exactly where a diagonal sprig ends.
    So the sprig is scaled to the largest size whose convex hull keeps CLEARANCE of the canvas
    height clear of that mask. It is centred where the clearance binds evenly. The padded
    placeholder's tip leaf touched the mask.
  * The square Settings slots (29 x 29 pt) are the Home Screen icon itself, downscaled.

Every 4:3-ish slot is laid out from the exact-4:3 layout, scaled by the canvas height and
centred. The wider slots (148x110, 134x100, 81x60 and 54x40, up to 1.35:1) just show a
little more background; nothing is stretched.

OUTPUT. Every file named in the set's Contents.json, at its exact pixel size: `size` x `scale`.
8-bit RGB PNGs with no alpha channel, which App Store Connect requires of an App Store icon.
They carry no colour profile, like the source.

RUN:   python3 Scripts/render-imessage-icon.py              # rewrite the set in place
       python3 Scripts/render-imessage-icon.py --out DIR    # write the twelve PNGs to DIR instead
NEEDS: Pillow and NumPy (python3 -m pip install pillow numpy). Only this script needs them.

RECORDED OUTPUT (2026-09-24, Pillow 11.3.0, NumPy 2.0.2). The committed PNGs are this run's bytes,
and a re-run reproduces them exactly. The owner approved this set from a contact sheet of real
simulator captures, with the padded placeholder and an 18-degree variant beside it:

    layout: rotate 8.130 deg, scale 0.7564, centre offset (-31.0, 21.8) px @ 1024x768
"""

import argparse
import json
import math
import os
import sys

try:
    import numpy as np
    from PIL import Image
except ImportError as missing:
    sys.exit(f"render-imessage-icon: {missing}. Install with: python3 -m pip install pillow numpy")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_ICON = os.path.join(REPO, "App/Fernlet/Assets.xcassets/AppIcon.appiconset/fernlet-icon-1024.png")
ICON_SET = os.path.join(REPO, "App/FernletMessagesExtension/Assets.xcassets/iMessage App Icon.stickersiconset")

# --- measured from the source icon (2026-09-24) ------------------------------------------------

SOURCE_SIDE = 1024
# Background: c0 + k2*r^2 + k4*r^4 per channel, with r measured from (0.5, BACKGROUND_CENTRE_Y) in
# units of the canvas side (for a non-square canvas: sqrt(W*H), so the corners keep their tone).
BACKGROUND_C0 = (247.210, 242.490, 231.814)
BACKGROUND_K2 = (-13.779, -18.757, -32.769)
BACKGROUND_K4 = (11.656, 16.481, 28.647)
BACKGROUND_CENTRE_Y = 0.425
# The sprig's three flat inks: dark leaf, light leaf, stem.
INKS = ((91, 122, 82), (138, 172, 125), (62, 47, 31))
ALPHA_FLOOR = 0.02  # below this the "sprig" is background dither, not ink

# --- the layout ---------------------------------------------------------------------------------

REFERENCE_W, REFERENCE_H = 1024, 768      # the exact-4:3 canvas the layout is solved on
MASK_EXPONENT = 2.30                       # Messages "+" menu superellipse, iOS 26.5 simulator
CLEARANCE = 0.06                           # of the canvas height, between sprig hull and mask
ROTATION_DEG = 45.0 - math.degrees(math.atan2(REFERENCE_H, REFERENCE_W))
SUPERSAMPLE_TARGET = 3.0                   # render the sprig magnified >= 3x, then downsample
SCALE_SEARCH_STEPS = 40                    # bisection steps for the largest fitting scale
OFFSET_REFINE_ROUNDS = 12                  # coarse-to-fine rounds for the centring search
OFFSET_GRID = 9                            # grid points per axis in each round


def background(width, height, side):
    """The cream radial background for a width x height canvas, as float RGB (H, W, 3)."""
    ys, xs = np.mgrid[0:height, 0:width]
    r2 = ((xs + 0.5 - width / 2) / side) ** 2 + ((ys + 0.5 - BACKGROUND_CENTRE_Y * height) / side) ** 2
    r2 = r2[..., None]
    return np.array(BACKGROUND_C0) + np.array(BACKGROUND_K2) * r2 + np.array(BACKGROUND_K4) * r2 ** 2


def sprig_layer():
    """Lifts the sprig off the source icon: premultiplied float RGBA (H, W, 4), alpha in 0...255."""
    src = np.asarray(Image.open(SOURCE_ICON).convert("RGB")).astype(np.float64)
    if src.shape[:2] != (SOURCE_SIDE, SOURCE_SIDE):
        sys.exit(f"render-imessage-icon: expected a {SOURCE_SIDE}px square source, got {src.shape[1]}x{src.shape[0]}")
    bg = background(SOURCE_SIDE, SOURCE_SIDE, float(SOURCE_SIDE))
    best_alpha = np.zeros(src.shape[:2])
    best_residual = np.full(src.shape[:2], np.inf)
    for ink in INKS:
        towards = np.array(ink, dtype=np.float64) - bg
        alpha = np.clip(((src - bg) * towards).sum(-1) / (towards * towards).sum(-1), 0.0, 1.0)
        residual = np.linalg.norm(src - (alpha[..., None] * towards + bg), axis=-1)
        better = residual < best_residual
        best_alpha = np.where(better, alpha, best_alpha)
        best_residual = np.where(better, residual, best_residual)
    best_alpha[best_alpha < ALPHA_FLOOR] = 0.0
    premultiplied = np.clip(src - (1.0 - best_alpha[..., None]) * bg, 0.0, 255.0)
    return np.dstack([premultiplied, best_alpha * 255.0])


def convex_hull(points):
    """Andrew's monotone chain over (x, y) tuples; returns the hull as an (N, 2) array."""
    ordered = sorted(set(points))

    def turn(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower, upper = [], []
    for p in ordered:
        while len(lower) >= 2 and turn(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(ordered):
        while len(upper) >= 2 and turn(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return np.array(lower[:-1] + upper[:-1], dtype=np.float64)


def sprig_hull(layer):
    """Convex hull of every pixel the sprig covers at least half of, in source pixels."""
    ys, xs = np.nonzero(layer[..., 3] > 127.5)
    corners = [(x + dx, y + dy) for x, y in zip(xs.tolist(), ys.tolist()) for dx in (0, 1) for dy in (0, 1)]
    return convex_hull(corners)


def rotated(points, degrees):
    """Rotates (N, 2) points about the source centre; positive is clockwise on screen (y down)."""
    t = math.radians(degrees)
    c, s = math.cos(t), math.sin(t)
    p = points - SOURCE_SIDE / 2
    return np.stack([c * p[:, 0] - s * p[:, 1], s * p[:, 0] + c * p[:, 1]], axis=1)


def worst_mask_radius(hull, scale, offset):
    """Largest superellipse 'radius' of the placed hull; <= 1 means it keeps its clearance."""
    margin = CLEARANCE * REFERENCE_H
    a, b = REFERENCE_W / 2 - margin, REFERENCE_H / 2 - margin
    x = hull[:, 0] * scale + offset[0]
    y = hull[:, 1] * scale + offset[1]
    return float((np.abs(x / a) ** MASK_EXPONENT + np.abs(y / b) ** MASK_EXPONENT).max())


def best_offset(hull, scale):
    """Coarse-to-fine grid search for the centre offset that minimises the worst radius."""
    centre = (0.0, 0.0)
    span = 0.25 * REFERENCE_H
    for _ in range(OFFSET_REFINE_ROUNDS):
        candidates = [
            (centre[0] + dx, centre[1] + dy)
            for dx in np.linspace(-span, span, OFFSET_GRID)
            for dy in np.linspace(-span, span, OFFSET_GRID)
        ]
        centre = min(candidates, key=lambda o: worst_mask_radius(hull, scale, o))
        span /= 3.0
    return centre


def layout(layer):
    """Solves the exact-4:3 layout: (rotation degrees, scale, centre offset in reference px)."""
    hull = rotated(sprig_hull(layer), ROTATION_DEG)
    low, high = 0.1, 2.0
    for _ in range(SCALE_SEARCH_STEPS):
        mid = (low + high) / 2
        if worst_mask_radius(hull, mid, best_offset(hull, mid)) <= 1.0:
            low = mid
        else:
            high = mid
    return ROTATION_DEG, low, best_offset(hull, low)


def render_wide(layer, width, height, plan):
    """One 4:3-ish slot: the laid-out sprig over a background generated for this canvas."""
    degrees, scale, offset = plan
    unit = height / REFERENCE_H
    supersample = max(1, math.ceil(SUPERSAMPLE_TARGET / (scale * unit)))
    big_w, big_h = width * supersample, height * supersample
    k = scale * unit * supersample
    t = math.radians(degrees)
    c, s = math.cos(t), math.sin(t)
    cx = big_w / 2 + offset[0] * unit * supersample
    cy = big_h / 2 + offset[1] * unit * supersample
    # PIL's affine maps OUTPUT pixels back to SOURCE pixels: the inverse rotation, scaled by 1/k.
    a, b, d, e = c / k, s / k, -s / k, c / k
    coefficients = (a, b, SOURCE_SIDE / 2 - (a * cx + b * cy), d, e, SOURCE_SIDE / 2 - (d * cx + e * cy))
    channels = []
    for i in range(4):
        plane = Image.fromarray(layer[..., i].astype(np.float32))
        plane = plane.transform((big_w, big_h), Image.AFFINE, coefficients, resample=Image.BICUBIC)
        channels.append(np.asarray(plane.resize((width, height), Image.BOX)))
    sprig = np.dstack(channels)
    alpha = np.clip(sprig[..., 3] / 255.0, 0.0, 1.0)[..., None]
    colour = np.clip(sprig[..., :3], 0.0, None) + (1.0 - alpha) * background(width, height, math.sqrt(width * height))
    return Image.fromarray(np.clip(np.rint(colour), 0, 255).astype(np.uint8))


def render_square(side):
    """One square Settings slot: the Home Screen icon itself, downscaled."""
    return Image.open(SOURCE_ICON).convert("RGB").resize((side, side), Image.LANCZOS)


def slots():
    """(filename, pixel width, pixel height) for every image the set's Contents.json names."""
    with open(os.path.join(ICON_SET, "Contents.json"), encoding="utf-8") as handle:
        images = json.load(handle)["images"]
    result = []
    for image in images:
        points_w, points_h = (float(v) for v in image["size"].split("x"))
        factor = float(image["scale"].rstrip("x"))
        result.append((image["filename"], round(points_w * factor), round(points_h * factor)))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", help="write the PNGs here instead of into the icon set")
    out_dir = parser.parse_args().out or ICON_SET
    os.makedirs(out_dir, exist_ok=True)
    layer = sprig_layer()
    plan = layout(layer)
    print(f"layout: rotate {plan[0]:.3f} deg, scale {plan[1]:.4f}, "
          f"centre offset ({plan[2][0]:.1f}, {plan[2][1]:.1f}) px @ {REFERENCE_W}x{REFERENCE_H}")
    for filename, width, height in slots():
        image = render_square(width) if width == height else render_wide(layer, width, height, plan)
        image.save(os.path.join(out_dir, filename), format="PNG", optimize=True)
        print(f"  {filename}: {width}x{height}")


if __name__ == "__main__":
    main()
