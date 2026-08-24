#!/usr/bin/env python3
"""Reproduces the T2-7 custom-background simulation quoted in FernletTheme.swift.

WHY THIS FILE EXISTS. `FernletThemePalette.inkFamilyCrossover`'s doc comment claims four
failure rates for four ways of picking ink against a user-chosen background. Those numbers
were originally produced by a throwaway script that was never committed, and the 2026-08-22
accessibility review could not reproduce two of them. A number in a doc comment that nobody
can re-derive is a number nobody can trust, so the simulation now lives here: this file is
the SOURCE OF TRUTH and the doc comment quotes what it prints. If the algorithm changes,
re-run this and update the doc — never the other way round.

FIDELITY. Every step below is a line-for-line port of
`FernletKit/Sources/FernletUI/FernletTheme.swift`:

  * `luminance` / `contrast_ratio`  <- `luminance(_:)`, `contrastRatio(_:_:)` and
    `CGFloat.linearizedSRGB` (the WCAG sRGB transfer function, 0.03928 knee included).
  * `box_color`                     <- `boxColor(from:usesDarkSurfaces:)`, including UIKit's
    RGB<->HSB round trip and the same clamps (brightness 0.17/0.97, saturation
    clamp(s*0.70, 0.05, 0.22) dark / clamp(s*0.24, 0.03, 0.10) light).
  * `fit_ink`                       <- `fitInk(_:toLuminance:target:)`, same 12 steps, same
    `0...fitStepCount` inclusive loop, same break-on-first-pass, same `extreme` selection.
  * the seed inks, the targets (7.0 primary / 4.5 secondary) and the crossover constant are
    copied from `FernletThemeDefaults` / `FernletThemePalette`.

The one thing this file CANNOT port is UIKit itself, so the HSB round trip is the standard
sRGB algorithm rather than Apple's binary. `Tests/FernletTests/AdaptiveInkBoundaryTests.swift`
closes that gap from the other side: it re-runs arm D through the real shipping
`FernletThemePalette.fitted(background:)` on the simulator and asserts the same 0 failures,
so the claim that matters is proven against UIKit, not against this port.

RUN:  python3 Scripts/adaptive-ink-simulation.py

RECORDED OUTPUT (2026-08-23) — the doc comment in FernletTheme.swift quotes these verbatim,
and AdaptiveInkBoundaryTests.docCommentQuotesTheSimulationArtifact() pins the two together:

    grid: 8 levels per channel, 512 backgrounds
    A shipping (threshold 0.46, no fit)       : 420/512 = 82.0%  (min ratio 1.118)
    B fit vs the box only (threshold 0.46)    : 420/512 = 82.0%  (min ratio 1.118)
    C fit vs harder surface (threshold 0.46)  : 180/512 = 35.2%  (min ratio 2.077)
    D fit vs harder surface (threshold 0.1791): 0/512 = 0.0%  (min ratio 4.501)
    E arm D under Increase Contrast (10.0/7.0): 0/512 = 0.0%  (min ratio 4.610)
    E-vs-D regressions (Increase Contrast made a background worse): 0

The three numbers the 2026-08-22 review re-derived independently (arms A, C and D) agree with
this run to the printed digit. Arms A/B/C are counterfactuals — that code no longer exists — so
they can only ever be reproduced here; arm D is also re-run against real UIKit by the test.

WHAT CHANGED FROM THE NUMBERS THIS FILE REPLACES. The doc comment used to claim 81.1% / 81.1% /
36.1% / 0%, described the grid as "a 32-step grid (512 backgrounds)" (512 is 8**3, not 32**3),
and gave no artifact. Arms A and C are corrected here to 82.0% and 35.2%; the conclusion —
"the threshold was the half that mattered, and the fit alone fixes nothing" — is unchanged.
"""

import math

# --- constants copied from FernletTheme.swift -------------------------------------------------

OLD_CROSSOVER = 0.46          # the hand-picked threshold this change replaced
NEW_CROSSOVER = 0.1791        # FernletThemePalette.inkFamilyCrossover
PRIMARY_TARGET = 7.0          # FernletThemeDefaults.customBackgroundPrimaryTarget
SECONDARY_TARGET = 4.5        # FernletThemeDefaults.customBackgroundSecondaryTarget
HIGH_PRIMARY_TARGET = 10.0    # FernletThemeDefaults.highContrastCustomPrimaryTarget
HIGH_SECONDARY_TARGET = 7.0   # FernletThemeDefaults.highContrastCustomSecondaryTarget
AA_SMALL_TEXT = 4.5           # the floor every arm is JUDGED against
FIT_STEP_COUNT = 12           # FernletThemePalette.fitStepCount
GRID_LEVELS = 8               # 8 levels per channel -> 8**3 = 512 backgrounds
EXPECTED_SAMPLES = GRID_LEVELS ** 3

# `fitted(background:)`'s four seed inks, dark-surface variant first.
PRIMARY_SEED_ON_DARK = (0.945, 0.929, 0.890)
PRIMARY_SEED_ON_LIGHT = (0.239, 0.180, 0.118)
SECONDARY_SEED_ON_DARK = (0.730, 0.748, 0.760)
SECONDARY_SEED_ON_LIGHT = (0.380, 0.430, 0.470)


# --- WCAG maths (CGFloat.linearizedSRGB + luminance + contrastRatio) --------------------------

def linearized(channel):
    """The sRGB-to-linear transfer function used by the WCAG relative-luminance formula."""
    return channel / 12.92 if channel <= 0.03928 else ((channel + 0.055) / 1.055) ** 2.4


def luminance(rgb):
    """WCAG relative luminance of an sRGB triple."""
    return 0.2126 * linearized(rgb[0]) + 0.7152 * linearized(rgb[1]) + 0.0722 * linearized(rgb[2])


def contrast_ratio(a, b):
    """(lighter + 0.05) / (darker + 0.05), on two relative luminances."""
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)


# --- UIKit's RGB <-> HSB round trip, as used by boxColor(from:usesDarkSurfaces:) ---------------

def rgb_to_hsb(rgb):
    """UIColor.getHue(_:saturation:brightness:alpha:) for an in-gamut sRGB triple."""
    red, green, blue = rgb
    high = max(red, green, blue)
    low = min(red, green, blue)
    delta = high - low
    if delta == 0:
        hue = 0.0
    elif high == red:
        hue = (((green - blue) / delta) % 6.0) / 6.0
    elif high == green:
        hue = (((blue - red) / delta) + 2.0) / 6.0
    else:
        hue = (((red - green) / delta) + 4.0) / 6.0
    saturation = 0.0 if high == 0 else delta / high
    return (hue, saturation, high)


def hsb_to_rgb(hsb):
    """UIColor(hue:saturation:brightness:alpha:) for hue in [0, 1)."""
    hue, saturation, brightness = hsb
    sector = (hue % 1.0) * 6.0
    index = int(math.floor(sector))
    frac = sector - index
    p = brightness * (1.0 - saturation)
    q = brightness * (1.0 - saturation * frac)
    t = brightness * (1.0 - saturation * (1.0 - frac))
    return [
        (brightness, t, p), (q, brightness, p), (p, brightness, t),
        (p, q, brightness), (t, p, brightness), (brightness, p, q),
    ][index % 6]


def box_color(background, uses_dark_surfaces):
    """Port of `boxColor(from:usesDarkSurfaces:)`: pin brightness, clamp saturation, keep hue."""
    hue, saturation, _ = rgb_to_hsb(background)
    brightness = 0.17 if uses_dark_surfaces else 0.97
    if uses_dark_surfaces:
        adjusted = min(max(saturation * 0.70, 0.05), 0.22)
    else:
        adjusted = min(max(saturation * 0.24, 0.03), 0.10)
    return hsb_to_rgb((hue, adjusted, brightness))


# --- the ink fit (port of fitInk(_:toLuminance:target:)) ---------------------------------------

def fit_ink(ink, surface_luminance, target, crossover):
    """Walk `ink` toward black or white in FIT_STEP_COUNT fixed steps until it clears `target`."""
    extreme = 0.0 if surface_luminance >= crossover else 1.0
    best = ink
    for step in range(0, FIT_STEP_COUNT + 1):
        progress = step / FIT_STEP_COUNT
        candidate = tuple(channel + (extreme - channel) * progress for channel in ink)
        best = candidate
        if contrast_ratio(luminance(candidate), surface_luminance) >= target:
            break
    return best


# --- the four arms -----------------------------------------------------------------------------

def palette(background, crossover, fit_mode, targets=(PRIMARY_TARGET, SECONDARY_TARGET)):
    """Return (box, primary_ink, secondary_ink) for one arm.

    `fit_mode` is 'none' (arm A), 'box' (arm B) or 'harder' (arms C, D and E). `targets` is the
    (primary, secondary) pair the fit aims for — the `.unspecified` pair for arms A-D, the
    Increase Contrast pair for arm E.
    """
    background_luminance = luminance(background)
    uses_dark_surfaces = background_luminance < crossover
    primary_seed = PRIMARY_SEED_ON_DARK if uses_dark_surfaces else PRIMARY_SEED_ON_LIGHT
    secondary_seed = SECONDARY_SEED_ON_DARK if uses_dark_surfaces else SECONDARY_SEED_ON_LIGHT
    box = box_color(background, uses_dark_surfaces)
    if fit_mode == "none":
        return (box, primary_seed, secondary_seed)
    if fit_mode == "box":
        # The naive first fit: card copy is the obvious case, so fit the ink to the CARD. This is
        # the arm whose whole point is that it corrects nothing — at the old threshold the box is
        # derived on the same wrong side of the cliff as the ink family, so the ink already clears
        # its target against the box and the loop exits on step 0, leaving the PAGE unreadable.
        surface = luminance(box)
    else:
        box_luminance = luminance(box)
        surface = max(background_luminance, box_luminance) if uses_dark_surfaces \
            else min(background_luminance, box_luminance)
    return (
        box,
        fit_ink(primary_seed, surface, targets[0], crossover),
        fit_ink(secondary_seed, surface, targets[1], crossover),
    )


def worst_ratio(background, crossover, fit_mode, targets=(PRIMARY_TARGET, SECONDARY_TARGET)):
    """The lowest ratio any ink achieves on any surface — both inks x background and box."""
    box, primary, secondary = palette(background, crossover, fit_mode, targets)
    surfaces = (luminance(background), luminance(box))
    return min(
        contrast_ratio(luminance(ink), surface)
        for ink in (primary, secondary)
        for surface in surfaces
    )


def sampled_backgrounds():
    """The pickable colour space on a GRID_LEVELS-per-channel grid, endpoints included."""
    levels = [step / (GRID_LEVELS - 1) for step in range(GRID_LEVELS)]
    return [(red, green, blue) for red in levels for green in levels for blue in levels]


def main():
    backgrounds = sampled_backgrounds()
    assert len(backgrounds) == EXPECTED_SAMPLES, "grid lost samples"
    normal = (PRIMARY_TARGET, SECONDARY_TARGET)
    high = (HIGH_PRIMARY_TARGET, HIGH_SECONDARY_TARGET)
    arms = [
        ("A shipping (threshold 0.46, no fit)       ", OLD_CROSSOVER, "none", normal),
        ("B fit vs the box only (threshold 0.46)    ", OLD_CROSSOVER, "box", normal),
        ("C fit vs harder surface (threshold 0.46)  ", OLD_CROSSOVER, "harder", normal),
        ("D fit vs harder surface (threshold 0.1791)", NEW_CROSSOVER, "harder", normal),
        ("E arm D under Increase Contrast (10.0/7.0)", NEW_CROSSOVER, "harder", high),
    ]
    print(f"grid: {GRID_LEVELS} levels per channel, {len(backgrounds)} backgrounds")
    for label, crossover, fit_mode, targets in arms:
        ratios = [worst_ratio(bg, crossover, fit_mode, targets) for bg in backgrounds]
        failures = sum(1 for ratio in ratios if ratio < AA_SMALL_TEXT)
        share = 100.0 * failures / len(backgrounds)
        print(f"{label}: {failures}/{len(backgrounds)} = {share:.1f}%  (min ratio {min(ratios):.3f})")
    # Arm E must never be WORSE than arm D anywhere: Increase Contrast raises the targets, and a
    # raised target can only make `fit_ink` walk further toward the extreme, never stop earlier.
    regressions = sum(
        1 for bg in backgrounds
        if worst_ratio(bg, NEW_CROSSOVER, "harder", high) < worst_ratio(bg, NEW_CROSSOVER, "harder", normal) - 1e-9
    )
    print(f"E-vs-D regressions (Increase Contrast made a background worse): {regressions}")


if __name__ == "__main__":
    main()
