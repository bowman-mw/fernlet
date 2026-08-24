import SwiftUI

#if canImport(UIKit)
import UIKit
import FernletDomainModel

// Everything in this file is resolved from inside `UIColor` dynamic-provider closures, which UIKit
// invokes on whatever thread is resolving the trait collection — including SwiftUI's off-main view-graph
// render thread on device. Under the target's `defaultIsolation(MainActor.self)` these would otherwise be
// MainActor-isolated, and the Swift 6 executor check traps (SIGTRAP) the moment a color resolves off the
// main thread. The computation is pure and thread-safe, so it is explicitly `nonisolated`.

/// Canonical hex strings and `UserDefaults` keys for the app's light/dark background theme.
///
/// A caseless namespace enum shared by ``FernletThemePalette`` (which reads the custom-background
/// keys during color resolution) and the app's appearance settings (which write them). Explicitly
/// `nonisolated` so its statics are readable from the `@Sendable` `UIColor` dynamic-provider
/// closures described in the note above.
nonisolated public enum FernletThemeDefaults {
    public static let lightBackgroundHex = "#F5EFDF"
    public static let darkBackgroundHex = "#1C1E1B"
    public static let lightBoxHex = "#FBF7EE"
    public static let darkBoxHex = "#282A26"
    public static let customLightBackgroundKey = "fernletCustomLightBackgroundHex"
    public static let customDarkBackgroundKey = "fernletCustomDarkBackgroundHex"

    /// The owner-approved Increase Contrast twin of the light `slate` secondary ink.
    ///
    /// From the redesign spec's AX-twin note (*"AX twins run Increase Contrast: slate → #45535E,
    /// card edges 30%, filled moss → #38562C"*,
    /// `Docs/design-refs/ux-review-2026-08-16/design-spec-2026-08-21.md`). Recomputed from the raw
    /// channel bytes for this change: **6.90:1 on parchment, 7.41:1 on cream**, against the
    /// default light `slate`'s 4.78:1 / 5.13:1. Dark mode has no approved twin and needs none —
    /// dark `slate` already measures 5.93:1 on the dark box and 6.87:1 on the dark background.
    public static let highContrastLightSecondaryHex = "#45535E"

    /// The WCAG floor a *custom* background's primary ink is fitted to. AAA rather than AA: the
    /// primary ink is the one carrying body copy on a surface the user picked without any
    /// contrast guidance, and fitting to 7:1 leaves visible headroom under
    /// `fitInk(_:toLuminance:target:)`'s step quantization.
    static let customBackgroundPrimaryTarget: CGFloat = 7.0

    /// The WCAG floor a *custom* background's secondary ink is fitted to — AA for small text. It
    /// is deliberately lower than ``customBackgroundPrimaryTarget`` so the two inks keep a visible
    /// hierarchy instead of collapsing onto the same value.
    static let customBackgroundSecondaryTarget: CGFloat = 4.5

    /// The primary-ink floor a custom background is fitted to **under Increase Contrast**.
    ///
    /// Chosen against what `defaultPalette(background:isDarkMode:contrast:)`
    /// actually delivers at `.high`, because parity with the stock palette is the whole claim: the
    /// default light primary measures **11.39:1 on parchment / 12.23:1 on cream**. 10.0 sits just
    /// under that — close enough that a custom background is not a second-class surface for the
    /// users who asked for more contrast, low enough that
    /// `fitInk(_:toLuminance:target:)` still returns a *tinted* ink on 202 of the 512 sampled
    /// backgrounds instead of saturating every one of them to pure black or pure white.
    /// Where 10.0 is unreachable the fit degrades to the extreme, which is the right answer here.
    static let highContrastCustomPrimaryTarget: CGFloat = 10.0

    /// The secondary-ink floor a custom background is fitted to **under Increase Contrast**.
    ///
    /// Exact parity with the approved default: ``highContrastLightSecondaryHex`` measures
    /// **6.90:1 on parchment / 7.41:1 on cream**, so 7.0 clears its worse surface and is also the
    /// WCAG AAA floor for small text. Still strictly below
    /// ``highContrastCustomPrimaryTarget`` for the same reason
    /// ``customBackgroundSecondaryTarget`` is below ``customBackgroundPrimaryTarget`` — two inks
    /// that fit to the same number stop being a hierarchy.
    static let highContrastCustomSecondaryTarget: CGFloat = 7.0
}

// MARK: - The Increase Contrast inversion constraint (2026-08-22 review, finding #23)
//
// Increase Contrast is not monotone across this palette, and one pairing inverts under it.
// `Color.moss` DEEPENS at `.high` (#5E844D -> the approved #46683A), which is right for the ~179
// sites that ink moss TEXT on parchment and right for the ~10 that draw a LIGHT ink on a solid moss
// fill — white goes 4.30:1 -> 6.36:1 and `parchmentInk` 3.74:1 -> 5.54:1. But a DARK ink on that
// same solid fill moves the other way, because deepening the fill closes the gap instead of opening
// it: `bark` on solid `moss` measures **3.04:1 today and 2.06:1 under Increase Contrast**, and
// `bark` on `mossFill` 2.44:1 -> 1.58:1. A user who switched Increase Contrast ON to read better
// would read that pairing WORSE.
//
// THE INVARIANT: no shipping site may draw `bark`, `slate`, `primaryText` or `secondaryText` on a
// solid (non-`.opacity`) `moss`/`mossFill` fill. The sanctioned inks for those fills are `onMoss`
// and `parchmentInk`, both of which improve at `.high`. The tree satisfies this today — the
// inversion is a latent hazard, not a live defect, which is exactly when it is cheap to fence.
//
// The constraint is ENFORCED, not merely written here: `AdaptiveInkBoundaryTests` scans every
// modifier chain in the four shipping roots for the forbidden pairing, and pins the two ratios above
// so that a future twin which no longer inverts fails the test and invites the rule to be revisited.
// It lives in that suite rather than beside the tokens because the `moss`/`mossFill` definitions are
// in `FernletUIComponents.swift`, and a constraint that is only a comment is the one that regresses.

// `nonisolated` on the type, not just on `current(_:)`: a provider closure reads the returned
// `primaryText`/`background`/… too, and those stored properties would otherwise stay MainActor-isolated and
// be rejected from the `@Sendable` closures that call them.

/// The resolved four-color surface palette — background, box, primary ink, secondary ink — for one
/// interface style.
///
/// This is the engine behind the adaptive `Color.parchment` / `.cream` / `.bark` / `.slate` tokens
/// in `FernletUIComponents.swift`: each of those tokens calls ``current(for:contrast:)`` from inside a
/// `UIColor` dynamic-provider closure every time UIKit resolves a trait collection. Resolution
/// honors a user-chosen custom background hex stored under the ``FernletThemeDefaults`` keys in
/// `UserDefaults.standard`; a non-default background derives a matching box surface via HSB
/// adjustment, picks light-or-dark ink by relative luminance (dark surfaces below
/// ``inkFamilyCrossover``, 0.1791 — **not** the 0.46 this comment used to name, which was the T2-7
/// defect itself), and then *fits* that ink to the harder of the two surfaces, so any custom
/// background stays legible.
///
/// Concurrency: the whole type is `nonisolated` (see the note above) because provider closures run
/// on whatever thread resolves the traits — including SwiftUI's off-main render thread on device —
/// and the computation is pure and thread-safe. Failure mode: an unparseable stored hex falls back
/// to the built-in default hex, then to `.systemBackground`.
nonisolated public struct FernletThemePalette {
    /// The screen background color (parchment/midnight by default; user-customizable).
    public let background: UIColor
    /// The raised card/box surface color, derived one step off the background.
    public let box: UIColor
    /// The primary ink color — "bark" in the token vocabulary.
    public let primaryText: UIColor
    /// The secondary, muted ink color — "slate" in the token vocabulary.
    public let secondaryText: UIColor

    /// Resolves the palette for an interface style, honoring any custom background in
    /// `UserDefaults.standard`.
    ///
    /// - Parameters:
    ///   - interfaceStyle: The trait collection's current style; `.dark` selects the dark defaults
    ///     and the dark custom-background key.
    ///   - contrast: The trait collection's `accessibilityContrast`. `.high` (SwiftUI's
    ///     `colorSchemeContrast == .increased`) selects the approved high-contrast secondary ink
    ///     in light mode. Defaults to `.unspecified` so every existing call site — and every test
    ///     that pins the default palette — keeps its exact previous behavior.
    /// - Returns: A fully derived palette; never fails (malformed stored hex falls back to defaults).
    public static func current(
        for interfaceStyle: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast = .unspecified
    ) -> FernletThemePalette {
        current(for: interfaceStyle, contrast: contrast, defaults: .standard)
    }

    /// The body of ``current(for:contrast:)`` with its defaults store injected.
    ///
    /// A seam, not a feature. `current` reads `UserDefaults.standard`, which is process-global disk
    /// state shared by every suite running in parallel, so a test that set a custom background hex
    /// to exercise the custom branch would bleed into whatever else was running — a known flake
    /// family in this repo. `AdaptiveInkBoundaryTests` drives this overload with a private suite
    /// instead, which is the only way the *custom-background* half of the contrast axis can be
    /// asserted at all. Internal on purpose: the app has exactly one defaults store.
    ///
    /// - Parameters:
    ///   - interfaceStyle: The trait collection's current style.
    ///   - contrast: The trait collection's `accessibilityContrast`, forwarded to **both** branches.
    ///     Forwarding it to only one was the §4.2 defect: an Increase Contrast user on a custom
    ///     background silently got the 4.5-target inks while the default background gave 6.90:1.
    ///   - defaults: Where the custom-background hex is read from.
    static func current(
        for interfaceStyle: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast,
        defaults: UserDefaults
    ) -> FernletThemePalette {
        let isDarkMode = interfaceStyle == .dark
        let key = isDarkMode ? FernletThemeDefaults.customDarkBackgroundKey : FernletThemeDefaults.customLightBackgroundKey
        let defaultHex = isDarkMode ? FernletThemeDefaults.darkBackgroundHex : FernletThemeDefaults.lightBackgroundHex
        let selectedHex = defaults.string(forKey: key) ?? defaultHex
        let background = UIColor(hex: selectedHex) ?? UIColor(hex: defaultHex) ?? .systemBackground

        let isDefault = selectedHex.caseInsensitiveCompare(defaultHex) == .orderedSame
        if isDefault {
            return defaultPalette(background: background, isDarkMode: isDarkMode, contrast: contrast)
        }
        return fitted(background: background, contrast: contrast)
    }

    /// The stock light/dark palette used when the stored background equals the built-in default.
    ///
    /// The light `secondaryText` ("slate") is deliberately darker than it looks like it should be:
    /// it inks every 12pt section eyebrow, subtitle and sheet Cancel in the app, and the previous
    /// value measured 3.05:1 on parchment — under the 4.5:1 floor for small text. It now clears
    /// 4.8:1 on parchment and 5.1:1 on cream. Dark mode was already fine (5.9–6.9:1) and is unchanged.
    ///
    /// Under Increase Contrast the light secondary ink swaps to the approved
    /// ``FernletThemeDefaults/highContrastLightSecondaryHex`` (6.90:1 / 7.41:1). Only the light
    /// secondary moves: light `primaryText` is already 11.4:1, and neither dark ink has an approved
    /// twin or needs one. Every other branch is byte-identical to the default palette, which is the
    /// invariant that keeps this capability free of visual risk at default settings.
    private static func defaultPalette(
        background: UIColor,
        isDarkMode: Bool,
        contrast: UIAccessibilityContrast
    ) -> FernletThemePalette {
        let lightSecondary: UIColor = contrast == .high
            ? (UIColor(hex: FernletThemeDefaults.highContrastLightSecondaryHex)
               ?? UIColor(red: 0.360, green: 0.420, blue: 0.470, alpha: 1))
            : UIColor(red: 0.360, green: 0.420, blue: 0.470, alpha: 1)
        return FernletThemePalette(
            background: background,
            box: UIColor(hex: isDarkMode ? FernletThemeDefaults.darkBoxHex : FernletThemeDefaults.lightBoxHex) ?? .systemBackground,
            primaryText: isDarkMode
                ? UIColor(red: 0.945, green: 0.929, blue: 0.890, alpha: 1)
                : UIColor(red: 0.239, green: 0.180, blue: 0.118, alpha: 1),
            secondaryText: isDarkMode
                ? UIColor(red: 0.620, green: 0.655, blue: 0.682, alpha: 1)
                : lightSecondary
        )
    }

    /// The palette for a user-chosen custom background, with both inks **fitted** to it.
    ///
    /// The guardrail behind T2-7. Before this, the ink pair was picked by one binary luminance
    /// threshold (dark surfaces below 0.46) and then used unchanged, so 62% of the pickable colour
    /// space made the app unreadable: a mid-grey `#B3B3B3` (luminance 0.451) fell on the dark-ink
    /// side and drew primary ink at 1.79:1 and secondary at 1.13:1 — including on the Reset button
    /// that would undo it. The secondary ink failed on *both* sides of the cliff.
    ///
    /// The threshold still picks the ink *family* (so a light background keeps dark ink and the
    /// app's character survives); `fitInk(_:toLuminance:target:)` then walks that ink toward black
    /// or white until it clears its WCAG floor. There is no combination of background and target
    /// that leaves the loop running: the step count is fixed and the last step is pure black or
    /// pure white, whose ratio against any background is the maximum available.
    ///
    /// Public so the appearance settings can show the user the ratio their pick will actually
    /// produce *before* they keep it, without duplicating the fitting maths at the call site
    /// (T2-7's live "Contrast" line). Callers that want the palette in force should use
    /// ``current(for:contrast:)``; this one answers "what would happen if the background were X".
    ///
    /// - Parameters:
    ///   - background: The candidate background.
    ///   - contrast: The contrast axis the palette is being fitted for. `.high` raises **both**
    ///     targets — primary 7.0 → `highContrastCustomPrimaryTarget`,
    ///     secondary 4.5 → `highContrastCustomSecondaryTarget` — so an
    ///     Increase Contrast user on a custom background gets the same treatment the default
    ///     background already gave them. It defaults to `.unspecified` so the existing
    ///     `fitted(background:)` spelling keeps compiling and keeps its exact previous behaviour;
    ///     that is the signature `SettingsSheet`'s live "Contrast" preview calls.
    /// - Returns: A palette whose worst-anywhere ratio clears 4.5:1 for every background on the
    ///   sampled grid, at either contrast setting (`Scripts/adaptive-ink-simulation.py` arms D
    ///   and E, 0/512 each).
    public static func fitted(
        background: UIColor,
        contrast: UIAccessibilityContrast = .unspecified
    ) -> FernletThemePalette {
        let isHighContrast = contrast == .high
        let primaryTarget = isHighContrast
            ? FernletThemeDefaults.highContrastCustomPrimaryTarget
            : FernletThemeDefaults.customBackgroundPrimaryTarget
        let secondaryTarget = isHighContrast
            ? FernletThemeDefaults.highContrastCustomSecondaryTarget
            : FernletThemeDefaults.customBackgroundSecondaryTarget
        let backgroundLuminance = background.relativeLuminance
        let usesDarkSurfaces = backgroundLuminance < inkFamilyCrossover
        let primarySeed = usesDarkSurfaces
            ? UIColor(red: 0.945, green: 0.929, blue: 0.890, alpha: 1)
            : UIColor(red: 0.239, green: 0.180, blue: 0.118, alpha: 1)
        let secondarySeed = usesDarkSurfaces
            ? UIColor(red: 0.730, green: 0.748, blue: 0.760, alpha: 1)
            : UIColor(red: 0.380, green: 0.430, blue: 0.470, alpha: 1)
        let box = boxColor(from: background, usesDarkSurfaces: usesDarkSurfaces)
        // Fit against the HARDER of the two surfaces, not against either one alone. Text is drawn
        // on both — body copy inside a `FernletCard` (the box) and headers, eyebrows and empty
        // states directly on the page (the background) — and `boxColor` pins the box's brightness
        // to a fixed 0.97/0.17, so the two can sit far apart. Fitting against the box alone leaves
        // the page unreadable and vice versa; the harder surface is the one closer in luminance to
        // the ink, which is the *higher* luminance when the ink is light and the *lower* when dark.
        let hardest = usesDarkSurfaces
            ? max(backgroundLuminance, box.relativeLuminance)
            : min(backgroundLuminance, box.relativeLuminance)
        return FernletThemePalette(
            background: background,
            box: box,
            primaryText: fitInk(primarySeed, toLuminance: hardest, target: primaryTarget),
            secondaryText: fitInk(secondarySeed, toLuminance: hardest, target: secondaryTarget)
        )
    }

    /// The background luminance at which the ink family flips from dark to light.
    ///
    /// **Derived, not chosen**, and it replaces a hand-picked `0.46` that was the single largest
    /// cause of T2-7. Black ink on a surface of luminance *L* measures `(L + 0.05) / 0.05`; white
    /// ink measures `1.05 / (L + 0.05)`. They are equal at `√(1.05 × 0.05) − 0.05 ≈ 0.1791`, and
    /// on either side of that point one family is strictly better than the other — so `0.46` was
    /// handing light ink to every background between 0.179 and 0.46, where dark ink wins outright.
    /// At L = 0.46 that is 2.06:1 (white) against 10.20:1 (black).
    ///
    /// This is the half that made the difference. The evidence is
    /// `Scripts/adaptive-ink-simulation.py` — a runnable port of this file's `boxColor`, `fitInk`
    /// and WCAG maths — and **the numbers below are that script's output, not a recollection of
    /// it**. It samples the pickable colour space on a grid of **8 levels per channel, endpoints
    /// included (8³ = 512 backgrounds)**, and asks of each whether *both* inks clear 4.5:1 against
    /// *both* surfaces:
    ///
    /// | arm | threshold | ink fitted against | fails |
    /// | --- | --- | --- | --- |
    /// | A — what shipped before | 0.46 | nothing | **420/512 = 82.0%** |
    /// | B — fit added naively | 0.46 | the box | **420/512 = 82.0%** |
    /// | C — fit against the harder surface | 0.46 | harder of box/background | **180/512 = 35.2%** |
    /// | D — what ships now | 0.1791 | harder of box/background | **0/512 = 0.0%** |
    /// | E — D under Increase Contrast | 0.1791 | harder, raised targets | **0/512 = 0.0%** |
    ///
    /// Arm B is the one worth reading twice: adding the ink fit *without* moving the threshold
    /// corrects nothing at all, because at 0.46 the box is derived on the same wrong side of the
    /// cliff as the ink family, so the ink already clears its target against the box and the fit
    /// exits on step 0 — leaving the page exactly as unreadable as before. The threshold was the
    /// half that mattered; the fit only became worth having once it was fitting against the right
    /// surface. `Tests/FernletTests/AdaptiveInkBoundaryTests.swift` re-runs arm D through this
    /// very code against real UIKit and pins these numbers to the script, so neither the doc nor
    /// the artifact can drift alone.
    ///
    /// *(These replace an earlier 81.1% / 81.1% / 36.1% / 0% that had no committed artifact and
    /// described the grid with a per-channel step count that does not factor into 512. Arms A
    /// and C re-derive as above; the conclusion is unchanged.)*
    ///
    /// **This is a deliberate visual change for one group of existing users**: anyone whose custom
    /// background sits between 0.179 and 0.46 sees their card surface flip from near-black to
    /// near-white and their ink flip from light to dark. That is the fix, not a side effect — those
    /// are exactly the users who currently have primary ink at 1.79:1 on every screen.
    public static let inkFamilyCrossover: CGFloat = 0.1791

    /// Walks `ink` toward black or white in a **fixed** number of steps until it clears `target`
    /// against `surface`, returning the first candidate that does (or the darkest/lightest one
    /// tried, when the surface makes the target unreachable).
    ///
    /// - Power of 10 rule 2: the loop is bounded by `fitStepCount` with no early-exit condition
    ///   that could fail to be met — `while ratio < target` would spin forever on a surface where
    ///   the target is unreachable, which is exactly the mid-grey case this exists for.
    /// - Concurrency: this runs inside the `@Sendable` `UIColor` dynamic providers, on whatever
    ///   thread resolves the trait collection — including SwiftUI's off-main render thread. It is
    ///   therefore pure (no `UserDefaults`, no caching, no shared state) and allocation-light: all
    ///   candidate arithmetic happens on `CGFloat` triples and **exactly one** `UIColor` is
    ///   allocated, on return.
    ///
    /// - Parameters:
    ///   - ink: The seed ink — already chosen for the surface's light/dark family.
    ///   - surfaceLuminance: The relative luminance of the HARDEST surface the ink will be drawn
    ///     on. A luminance rather than a `UIColor` because the caller has already decided which of
    ///     the background and the box is harder, and passing the colour would invite this function
    ///     to re-decide it differently.
    ///   - target: The WCAG contrast ratio to clear.
    /// - Returns: A fitted opaque ink. Returns `ink` unchanged when it already clears `target`,
    ///   which is the common case and costs one luminance computation.
    private static func fitInk(_ ink: UIColor, toLuminance surfaceLuminance: CGFloat, target: CGFloat) -> UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard ink.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return ink }
        // Darken against a light surface, lighten against a dark one — never cross the family. The
        // same crossover the caller used to pick the family, so the two decisions cannot disagree.
        let extreme: CGFloat = surfaceLuminance >= inkFamilyCrossover ? 0 : 1
        var best = (red, green, blue)
        for step in 0...fitStepCount {
            let t = CGFloat(step) / CGFloat(fitStepCount)
            let candidate = (
                red + (extreme - red) * t,
                green + (extreme - green) * t,
                blue + (extreme - blue) * t
            )
            best = candidate
            if contrastRatio(luminance(candidate), surfaceLuminance) >= target { break }
        }
        return UIColor(red: best.0, green: best.1, blue: best.2, alpha: 1)
    }

    /// How many interpolation steps `fitInk(_:toLuminance:target:)` may take. Twelve gives ~8% steps
    /// toward the extreme — fine enough that the fitted ink is never visibly over-corrected, small
    /// enough that the worst case is 13 luminance computations inside a colour resolution.
    private static let fitStepCount = 12

    /// WCAG relative luminance of a raw sRGB triple — the allocation-free half of
    /// `UIColor.relativeLuminance`, so `fitInk(_:toLuminance:target:)` can evaluate candidates without
    /// materializing a `UIColor` for each one.
    private static func luminance(_ rgb: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        0.2126 * rgb.0.linearizedSRGB + 0.7152 * rgb.1.linearizedSRGB + 0.0722 * rgb.2.linearizedSRGB
    }

    /// The WCAG contrast ratio between two relative luminances: `(lighter + 0.05) / (darker + 0.05)`.
    static func contrastRatio(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Derives the card/box surface from a custom background by clamping its saturation and pinning
    /// brightness (0.17 dark / 0.97 light); falls back to fixed neutrals when the background has no
    /// HSB representation.
    private static func boxColor(from background: UIColor, usesDarkSurfaces: Bool) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1
        guard background.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return usesDarkSurfaces ? UIColor(white: 0.157, alpha: 1) : UIColor(red: 0.984, green: 0.969, blue: 0.933, alpha: 1)
        }

        let adjustedBrightness: CGFloat = usesDarkSurfaces ? 0.17 : 0.97
        let adjustedSaturation = usesDarkSurfaces
            ? min(max(saturation * 0.70, 0.05), 0.22)
            : min(max(saturation * 0.24, 0.03), 0.10)
        return UIColor(hue: hue, saturation: adjustedSaturation, brightness: adjustedBrightness, alpha: alpha)
    }
}

public extension UIColor {
    /// WCAG relative luminance (0 = black, 1 = white) of the color's sRGB components.
    ///
    /// Used by ``FernletThemePalette`` to decide whether a custom background needs light or dark
    /// ink. Returns 1 (treated as light) when the color has no RGB representation.
    nonisolated var relativeLuminance: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 1 }
        return 0.2126 * red.linearizedSRGB + 0.7152 * green.linearizedSRGB + 0.0722 * blue.linearizedSRGB
    }

    /// The WCAG contrast ratio between this colour and `other`, from 1 (identical) to 21
    /// (black on white).
    ///
    /// The sibling of ``relativeLuminance``, added for T2-7 so the appearance settings can show the
    /// user what their custom background actually measures *while they are picking it* — the one
    /// moment the number can still change their mind. Both colours are treated as opaque; compose
    /// any alpha over its backdrop before calling.
    ///
    /// Reference points for reading the result: **4.5** is the WCAG AA floor for small text, **3.0**
    /// the floor for large text and for non-text UI components, **7.0** is AAA.
    nonisolated func contrastRatio(to other: UIColor) -> CGFloat {
        FernletThemePalette.contrastRatio(relativeLuminance, other.relativeLuminance)
    }

    /// Parses a 6-hex `RRGGBB` string (any surrounding non-alphanumerics, e.g. a leading `#`, are
    /// trimmed) into its 0–255 channel bytes. Returns `nil` for any malformed input. The single source
    /// of truth for hex→RGB used by both `UIColor(hex:)` and the item-texture pixel renderer.
    nonisolated static func rgbBytes(fromHex hex: String) -> (UInt8, UInt8, UInt8)? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    /// Creates an opaque color from a 6-hex `RRGGBB` string via `rgbBytes(fromHex:)`; fails on
    /// malformed input.
    nonisolated convenience init?(hex: String) {
        guard let rgb = UIColor.rgbBytes(fromHex: hex) else { return nil }
        self.init(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
    }

    /// The color re-encoded as an uppercase `#RRGGBB` string (channels truncated to 0–255), or
    /// `nil` when the color has no RGB representation. The inverse of `init(hex:)`, used when
    /// persisting a custom theme background.
    nonisolated var hexString: String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}

private extension CGFloat {
    /// The sRGB-to-linear transfer function used by the WCAG relative-luminance formula.
    nonisolated var linearizedSRGB: CGFloat {
        self <= 0.03928 ? self / 12.92 : pow((self + 0.055) / 1.055, 2.4)
    }
}
#endif
