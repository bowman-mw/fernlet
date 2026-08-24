// AdaptiveInkBoundaryTests.swift
// FernletTests
//
// Regression coverage for the adaptive-colour subsystem — the accessibility review's §4.2 (the
// Increase Contrast axis) and T2-7 (custom backgrounds) — which shipped with none at all.
//
// WHY THIS SUITE EXISTS. `FernletThemePalette` is the only code in the app whose OUTPUT is a
// number that a human is supposed to be able to check: every ink it returns carries a claimed WCAG
// ratio, and those claims live in doc comments. Doc comments do not run. The review found the
// predictable consequences — a simulation quoted to one decimal place whose intermediate numbers
// nobody could reproduce, a grid described as "32-step" that was 8-step, a `contrast:` argument
// forwarded to one of two branches, and four DocC links to a symbol that does not exist. None of
// those is visible in a screenshot, none breaks the build, and all four were introduced by people
// being careful. That combination is the definition of something that needs a wall.
//
// FOUR KINDS OF ASSERTION, deliberately mixed, because each one covers the others' blind spot:
//
//   1. BEHAVIOURAL, over a sampled grid — the fitted palette really is run, through real UIKit, for
//      all 512 backgrounds, and its ratios are measured rather than asserted from a table.
//   2. CONSTANT PINS — the derived crossover is re-derived from `sqrt(1.05 * 0.05) - 0.05` here, so
//      a hand-edited literal goes red, and the approved AX hex is compared byte-for-byte.
//   3. ARTIFACT-VS-DOC — `Scripts/adaptive-ink-simulation.py` is the simulation, and its constants
//      and printed numbers are pinned to the shipping constants and to the doc comment that quotes
//      them. Neither the doc nor the artifact can drift alone. (Same anti-drift contract
//      `PowerOfTenBoundaryTests` holds between its port and `Scripts/power-of-10-scan.py`.)
//   4. A GREP WALL — the one constraint that is about call SITES rather than about the palette:
//      Increase Contrast is not monotone, and dark ink on a solid moss fill gets WORSE under it.
//
// WHAT THIS SUITE CANNOT SEE. It measures the tokens, not the screens. A ratio that passes here
// still fails on screen if the text is drawn at 40% alpha, over a photo, on a gradient, or on a
// surface that is not `background`/`box` — `FernletUIComponents.swift`'s closing note is explicit
// that the ~30 `slate.opacity(…)` sites cannot be rescued by any token. Nor does it know anything
// about the DARK-mode custom-background branch beyond the same fitted arithmetic. Those stay with
// the runtime audit in `UXScreenProbe` and with human review.

import Foundation
import Testing

#if canImport(UIKit)
import SwiftUI
import UIKit
@testable import FernletUI

/// Boundary suite for `FernletThemePalette`'s two axes — custom background (T2-7) and Increase
/// Contrast (§4.2) — plus the artifact/doc contract behind the crossover's quoted simulation.
///
/// Guarded by `canImport(UIKit)` for the same reason `FernletTheme.swift` is: the whole palette is
/// a `UIColor` computation and does not exist off UIKit. The suite runs on the iOS Simulator.
///
/// `UserDefaults` discipline: `FernletThemePalette.current(for:contrast:)` reads
/// `UserDefaults.standard`, which is process-global disk state shared with every suite running in
/// parallel — a known flake family in this repo. Nothing here writes it. The custom-background
/// branch is driven through the internal `current(for:contrast:defaults:)` seam with a private
/// suite that is torn down in a `defer`.
@Suite struct AdaptiveInkBoundaryTests {

    // MARK: - The sampled grid (must match Scripts/adaptive-ink-simulation.py)

    /// Levels per channel. 8 levels x 3 channels = 512 backgrounds — the grid the crossover's doc
    /// comment quotes, and the number the doc used to describe (wrongly) as "32-step".
    static let gridLevels = 8

    /// The sample count the grid must produce. A floor AND a ceiling: a grid that silently shrank
    /// would let every ratio assertion below pass over almost nothing.
    static let expectedSampleCount = 512

    /// WCAG AA for small text — the floor every fitted palette is judged against.
    static let aaSmallText: CGFloat = 4.5

    /// The pickable colour space on a ``gridLevels``-per-channel grid, endpoints included.
    ///
    /// Bounded by three fixed `gridLevels` loops (Power of 10 rule 2) and allocation-bounded at
    /// `gridLevels³` colours.
    static func sampledBackgrounds() -> [UIColor] {
        var colors: [UIColor] = []
        colors.reserveCapacity(gridLevels * gridLevels * gridLevels)
        let step = CGFloat(gridLevels - 1)
        for red in 0..<gridLevels {
            for green in 0..<gridLevels {
                for blue in 0..<gridLevels {
                    colors.append(UIColor(red: CGFloat(red) / step,
                                          green: CGFloat(green) / step,
                                          blue: CGFloat(blue) / step,
                                          alpha: 1))
                }
            }
        }
        return colors
    }

    /// The lowest ratio any ink in `palette` achieves on any surface of `palette` — both inks
    /// against both the background and the box.
    ///
    /// This is the quantity that matters and the one a single-surface check misses: body copy sits
    /// inside a `FernletCard` (the box) while headers, eyebrows and empty states sit directly on
    /// the page (the background), and `boxColor` pins the box's brightness to a fixed 0.97/0.17, so
    /// the two surfaces can be far apart.
    static func worstRatio(_ palette: FernletThemePalette) -> CGFloat {
        var worst = CGFloat.greatestFiniteMagnitude
        for ink in [palette.primaryText, palette.secondaryText] {
            for surface in [palette.background, palette.box] {
                worst = min(worst, ink.contrastRatio(to: surface))
            }
        }
        return worst
    }

    /// Whether two colours agree on every sRGB channel to within `tolerance`.
    ///
    /// Used instead of `hexString` equality wherever the claim is "these are the same colour":
    /// `hexString` truncates rather than rounds, so a channel that lands on 68.9999 would compare
    /// unequal to one that lands on 69.0 for reasons that have nothing to do with the palette.
    static func componentsMatch(_ lhs: UIColor, _ rhs: UIColor, tolerance: CGFloat) -> Bool {
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        guard lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
              rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra) else { return false }
        return abs(lr - rr) <= tolerance && abs(lg - rg) <= tolerance && abs(lb - rb) <= tolerance
    }

    /// A private `UserDefaults` suite plus its name, so the caller can tear it down.
    ///
    /// Never `UserDefaults.standard`: see the suite's note. The name carries a UUID so two tests
    /// running in parallel cannot share one.
    static func privateDefaults() throws -> (defaults: UserDefaults, name: String) {
        let name = "fernlet.tests.adaptiveInk.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }
}

// MARK: - The derived crossover

extension AdaptiveInkBoundaryTests {

    /// The 0.1791 crossover is the DERIVED break-even between black and white ink, re-derived here.
    ///
    /// Black ink on a surface of luminance L measures `(L + 0.05) / 0.05`; white ink measures
    /// `1.05 / (L + 0.05)`. They are equal at `sqrt(1.05 * 0.05) - 0.05`. Re-deriving it in the
    /// test rather than copying the literal is the whole point: the old value was a hand-picked
    /// 0.46, and a hand-edit back toward anything like it fails here, in arithmetic, rather than
    /// being noticed by a user whose background sits in the gap.
    @Test func crossoverIsTheDerivedBreakEvenNotAHandPickedNumber() throws {
        let derived = (1.05 * 0.05).squareRoot() - 0.05
        #expect(
            abs(FernletThemePalette.inkFamilyCrossover - derived) < 0.0001,
            """
            inkFamilyCrossover is \(FernletThemePalette.inkFamilyCrossover) but the black/white \
            break-even is \(derived). This constant is DERIVED, not chosen — if it needs to move, \
            the derivation has to move with it.
            """
        )
        #expect(FernletThemePalette.inkFamilyCrossover == 0.1791, "the shipping literal must stay 0.1791")

        // At the break-even the two families tie exactly; on either side one strictly wins.
        let blackAtCrossover = FernletThemePalette.contrastRatio(0, derived)
        let whiteAtCrossover = FernletThemePalette.contrastRatio(1, derived)
        #expect(abs(blackAtCrossover - whiteAtCrossover) < 1e-9, "the crossover must be a tie, not a preference")
        #expect(blackAtCrossover > Self.aaSmallText, "even the worst background must be able to reach AA")

        // The value the old threshold handed out, kept as the negative case: at L = 0.46 white ink
        // measures ~2.06:1 while black measures ~10.20:1, which is the T2-7 defect in one line.
        #expect(FernletThemePalette.contrastRatio(1, 0.46) < 2.1)
        #expect(FernletThemePalette.contrastRatio(0, 0.46) > 10.0)

        let source = try RepoRoot.source("FernletKit/Sources/FernletUI/FernletTheme.swift")
        #expect(source.contains("inkFamilyCrossover: CGFloat = 0.1791"), "the literal moved or was renamed")
        #expect(!source.contains("CGFloat = 0.46"), "0.46 must not come back as any threshold")
    }
}

// MARK: - The fitted palette, measured over the whole sampled grid

extension AdaptiveInkBoundaryTests {

    /// **The T2-7 claim itself**: every background on the sampled grid produces a palette whose
    /// worst ratio — either ink, either surface — clears 4.5:1.
    ///
    /// Run through the real shipping `fitted(background:)` and real UIKit, so it also covers the
    /// HSB round trip inside `boxColor` that the Python artifact can only approximate. This is the
    /// arm D of `Scripts/adaptive-ink-simulation.py`, and the failure count must be the same 0.
    @Test func everySampledBackgroundClearsAaOnBothSurfaces() {
        let backgrounds = Self.sampledBackgrounds()
        #expect(backgrounds.count == Self.expectedSampleCount, "the grid lost samples — nothing below was measured")

        var failures: [String] = []
        var minimum = CGFloat.greatestFiniteMagnitude
        for background in backgrounds {
            let ratio = Self.worstRatio(FernletThemePalette.fitted(background: background))
            minimum = min(minimum, ratio)
            guard ratio < Self.aaSmallText else { continue }
            failures.append("\(background.hexString ?? "??") -> \(String(format: "%.3f", ratio)):1")
        }

        #expect(
            failures.isEmpty,
            """
            \(failures.count)/\(backgrounds.count) sampled backgrounds fall below 4.5:1 — the \
            simulation quoted in inkFamilyCrossover's doc comment says 0. Worst offenders:
            \(failures.prefix(12).joined(separator: "\n"))
            """
        )
        #expect(minimum >= Self.aaSmallText)
        // A sanity ceiling: 21:1 is black on white, so a "minimum" at that value would mean the
        // measurement never actually looked at a fitted ink.
        #expect(minimum < 21, "the worst-case ratio should be near the floor, not at the theoretical maximum")
    }

    /// The fit never runs away: it is bounded, and its output is an opaque colour in gamut.
    ///
    /// Cheap, but it is the property Power of 10 rule 2 is about — `fitInk` walks a FIXED number of
    /// steps precisely because `while ratio < target` would spin forever on a surface where the
    /// target is unreachable, and the mid-grey case this whole subsystem exists for is exactly such
    /// a surface (at L = 0.4508 the best a dark ink can do is 10.02:1, so a 12:1 target never ends).
    @Test func fittedInksStayOpaqueAndInGamut() {
        for background in Self.sampledBackgrounds() {
            let palette = FernletThemePalette.fitted(background: background)
            for ink in [palette.primaryText, palette.secondaryText, palette.box] {
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                let readable = ink.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                #expect(readable, "a fitted ink must have an sRGB representation")
                #expect(alpha == 1, "a fitted ink must be opaque — alpha would compose over the surface")
                #expect(red >= 0 && red <= 1 && green >= 0 && green <= 1 && blue >= 0 && blue <= 1)
            }
        }
    }
}

// MARK: - §4.2: the contrast axis reaches the custom-background branch

extension AdaptiveInkBoundaryTests {

    /// The raised Increase Contrast targets are the ones documented, and they are a real raise.
    @Test func increaseContrastTargetsAreRaisedAndKeepTheInkHierarchy() {
        #expect(FernletThemeDefaults.highContrastCustomPrimaryTarget == 10.0)
        #expect(FernletThemeDefaults.highContrastCustomSecondaryTarget == 7.0)
        #expect(FernletThemeDefaults.customBackgroundPrimaryTarget == 7.0)
        #expect(FernletThemeDefaults.customBackgroundSecondaryTarget == 4.5)
        #expect(FernletThemeDefaults.highContrastCustomPrimaryTarget > FernletThemeDefaults.customBackgroundPrimaryTarget)
        #expect(FernletThemeDefaults.highContrastCustomSecondaryTarget > FernletThemeDefaults.customBackgroundSecondaryTarget)
        // The hierarchy invariant: two inks fitted to the same number stop being a hierarchy.
        #expect(FernletThemeDefaults.highContrastCustomSecondaryTarget < FernletThemeDefaults.highContrastCustomPrimaryTarget)
    }

    /// **The §4.2 fix, measured**: `.high` must never make a custom background worse, must improve
    /// the large majority of them, and must still clear 4.5:1 everywhere.
    ///
    /// "Never worse" is the assertion worth having. Increase Contrast raising a target can only
    /// make `fitInk` walk FURTHER toward the extreme, never stop earlier — so a single regression
    /// here means the two targets, the family choice and the harder-surface choice have fallen out
    /// of agreement, which is precisely the class of bug this file's `moss` rule also guards.
    @Test func increaseContrastImprovesCustomBackgroundsAndNeverRegressesOne() {
        var improved = 0
        var regressions: [String] = []
        var minimumHigh = CGFloat.greatestFiniteMagnitude
        for background in Self.sampledBackgrounds() {
            let normal = Self.worstRatio(FernletThemePalette.fitted(background: background, contrast: .unspecified))
            let high = Self.worstRatio(FernletThemePalette.fitted(background: background, contrast: .high))
            minimumHigh = min(minimumHigh, high)
            if high > normal + 1e-9 { improved += 1 }
            guard high < normal - 1e-9 else { continue }
            regressions.append("\(background.hexString ?? "??") \(normal) -> \(high)")
        }

        #expect(
            regressions.isEmpty,
            """
            Increase Contrast made \(regressions.count) background(s) WORSE. A raised target can \
            only walk the ink further toward black/white, so this means the targets and the \
            family/surface choice disagree:
            \(regressions.prefix(8).joined(separator: "\n"))
            """
        )
        #expect(improved > 300, "only \(improved)/512 backgrounds improved — is `contrast:` reaching the fit at all?")
        #expect(minimumHigh >= Self.aaSmallText, "the raised targets must not drop any background below AA")
    }

    /// **Finding #8**: `current(for:contrast:)` on a CUSTOM background honours `.high`.
    ///
    /// The defect was one dropped argument: `current` forwarded `contrast` to `defaultPalette` and
    /// then called `fitted(background:)` with none, so an Increase Contrast user who had picked
    /// their own background silently got the 4.5-target inks while the stock background gave them
    /// 6.90:1. Driven through the internal defaults seam so nothing touches `UserDefaults.standard`.
    ///
    /// `#B3B3B3` is not an arbitrary pick — it is T2-7's own worked example, the mid-grey whose
    /// luminance (0.451) sat just under the old 0.46 threshold and drew primary ink at 1.79:1.
    @Test func currentHonoursIncreaseContrastOnACustomBackground() throws {
        let (defaults, name) = try Self.privateDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("#B3B3B3", forKey: FernletThemeDefaults.customLightBackgroundKey)

        let normal = FernletThemePalette.current(for: .light, contrast: .unspecified, defaults: defaults)
        let high = FernletThemePalette.current(for: .light, contrast: .high, defaults: defaults)

        #expect(
            !Self.componentsMatch(high.secondaryText, normal.secondaryText, tolerance: 1e-6),
            "the secondary ink is identical at .high — `contrast:` is not reaching `fitted`"
        )
        #expect(!Self.componentsMatch(high.primaryText, normal.primaryText, tolerance: 1e-6))
        #expect(
            Self.worstRatio(high) > Self.worstRatio(normal),
            "worst ratio \(Self.worstRatio(normal)) -> \(Self.worstRatio(high)); .high must buy contrast"
        )
        #expect(Self.worstRatio(high) >= FernletThemeDefaults.highContrastCustomSecondaryTarget - 0.01)
        // Both settings must still be legible — the fix raises the floor, it does not trade it.
        #expect(Self.worstRatio(normal) >= Self.aaSmallText)
        // The background itself is untouched by the contrast axis: only the inks move.
        #expect(Self.componentsMatch(high.background, normal.background, tolerance: 1e-9))
    }

    /// The DEFAULT-background branch still hands back the approved AX twin, byte-for-byte.
    ///
    /// Two claims in one, because they are the same claim from both sides: the frozen hex string is
    /// exactly the owner-approved `#45535E` from the 2026-08-21 design spec, and the palette really
    /// resolves to it rather than to something near it. The measured ratios are pinned too — those
    /// are the numbers the doc comment quotes, and an unpinned quoted ratio is how §4.2's
    /// reproducibility problem started.
    @Test func highContrastSecondaryIsTheApprovedHexByteForByte() throws {
        #expect(FernletThemeDefaults.highContrastLightSecondaryHex == "#45535E")

        let approved = try #require(UIColor(hex: FernletThemeDefaults.highContrastLightSecondaryHex))
        let (defaults, name) = try Self.privateDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let high = FernletThemePalette.current(for: .light, contrast: .high, defaults: defaults)
        #expect(Self.componentsMatch(high.secondaryText, approved, tolerance: 1e-6),
                "the .high light secondary is \(high.secondaryText.hexString ?? "??"), not #45535E")

        let normal = FernletThemePalette.current(for: .light, contrast: .unspecified, defaults: defaults)
        #expect(!Self.componentsMatch(normal.secondaryText, approved, tolerance: 1e-3),
                "the DEFAULT secondary must not silently become the AX twin — that is a visual change for everyone")

        let parchment = try #require(UIColor(hex: FernletThemeDefaults.lightBackgroundHex))
        let cream = try #require(UIColor(hex: FernletThemeDefaults.lightBoxHex))
        #expect(abs(approved.contrastRatio(to: parchment) - 6.90) < 0.01,
                "measured \(approved.contrastRatio(to: parchment)) on parchment; the doc claims 6.90:1")
        #expect(abs(approved.contrastRatio(to: cream) - 7.41) < 0.01,
                "measured \(approved.contrastRatio(to: cream)) on cream; the doc claims 7.41:1")
        // The AX twin exists because the default light secondary was under 4.5:1 on parchment; it
        // must stay strictly better than what it replaced.
        #expect(approved.contrastRatio(to: parchment) > normal.secondaryText.contrastRatio(to: parchment))

        // Dark mode has no approved twin and needs none — it must therefore be UNCHANGED at .high.
        let darkNormal = FernletThemePalette.current(for: .dark, contrast: .unspecified, defaults: defaults)
        let darkHigh = FernletThemePalette.current(for: .dark, contrast: .high, defaults: defaults)
        #expect(Self.componentsMatch(darkNormal.secondaryText, darkHigh.secondaryText, tolerance: 1e-9))
        #expect(Self.componentsMatch(darkNormal.primaryText, darkHigh.primaryText, tolerance: 1e-9))
    }
}

// MARK: - Finding #6: the simulation is an artifact, and the doc quotes it

extension AdaptiveInkBoundaryTests {

    /// Repo-relative path of the committed simulation.
    static let simulationPath = "Scripts/adaptive-ink-simulation.py"

    /// Repo-relative path of the file whose doc comment quotes it.
    static let themePath = "FernletKit/Sources/FernletUI/FernletTheme.swift"

    /// The value of a top-level `NAME = <number>` assignment in the Python artifact.
    ///
    /// A five-line parser rather than a regex, and deliberately strict: it anchors on the exact
    /// `"\(name) = "` prefix at the start of a line, so a mention of the constant in prose or in a
    /// call cannot be mistaken for its definition. Returns `nil` when the constant is gone, which
    /// the callers treat as a failure rather than as "unchanged".
    static func pythonConstant(_ name: String, in source: String) -> Double? {
        for line in source.components(separatedBy: .newlines) where line.hasPrefix("\(name) = ") {
            let tail = line.dropFirst("\(name) = ".count)
            let digits = tail.prefix { $0.isNumber || $0 == "." || $0 == "-" }
            return Double(digits)
        }
        return nil
    }

    /// The artifact exists and its constants are the SHIPPING constants.
    ///
    /// This is the half that makes the artifact worth having. A simulation that has drifted from
    /// the code it claims to simulate is worse than no simulation, because it still prints numbers.
    @Test func simulationArtifactUsesTheShippingConstants() throws {
        let script = try RepoRoot.source(Self.simulationPath)
        let pins: [(String, CGFloat)] = [
            ("NEW_CROSSOVER", FernletThemePalette.inkFamilyCrossover),
            ("PRIMARY_TARGET", FernletThemeDefaults.customBackgroundPrimaryTarget),
            ("SECONDARY_TARGET", FernletThemeDefaults.customBackgroundSecondaryTarget),
            ("HIGH_PRIMARY_TARGET", FernletThemeDefaults.highContrastCustomPrimaryTarget),
            ("HIGH_SECONDARY_TARGET", FernletThemeDefaults.highContrastCustomSecondaryTarget)
        ]
        for (name, shipping) in pins {
            let value = try #require(Self.pythonConstant(name, in: script),
                                     "\(name) is gone from \(Self.simulationPath) — the artifact no longer models this")
            #expect(abs(CGFloat(value) - shipping) < 1e-9,
                    "\(name) is \(value) in the artifact but \(shipping) in the app")
        }
        // The grid and the step count are structural rather than a threshold, so they get their own
        // pins: a 4-level grid would still print percentages, just meaningless ones.
        #expect(Self.pythonConstant("GRID_LEVELS", in: script) == Double(Self.gridLevels))
        #expect(Self.pythonConstant("FIT_STEP_COUNT", in: script) == 12,
                "fitStepCount is 12 in FernletTheme.swift; the artifact must walk the same steps")
        #expect(Self.pythonConstant("OLD_CROSSOVER", in: script) == 0.46,
                "the counterfactual arms need the threshold that actually shipped before")
    }

    /// The doc comment quotes the artifact's numbers — all of them, and none of the old ones.
    ///
    /// The review's finding was not "the numbers are wrong" but "the numbers cannot be checked":
    /// 81.1% / 81.1% / 36.1% / 0% came from an uncommitted script and re-derived as 82.0% / 82.0% /
    /// 35.2% / 0.0%. Pinning the strings in both directions is what stops that recurring — a
    /// re-run that changes an arm now fails here until the doc is updated with it.
    @Test func docCommentQuotesTheSimulationArtifact() throws {
        let script = try RepoRoot.source(Self.simulationPath)
        let theme = try RepoRoot.source(Self.themePath)

        let printed = ["420/512 = 82.0%", "180/512 = 35.2%", "0/512 = 0.0%"]
        for line in printed {
            #expect(script.contains(line), "\(Self.simulationPath) no longer records \"\(line)\" — re-run it")
            #expect(theme.contains(line), "the crossover doc comment does not quote \"\(line)\"")
        }
        #expect(theme.contains("Scripts/adaptive-ink-simulation.py"),
                "the doc comment must name the artifact, or the numbers are unverifiable again")

        // The self-contradiction the review caught: 512 is 8**3, so the grid is 8-step, not 32-step.
        #expect(!theme.contains("32-step"), "512 backgrounds is an 8-level-per-channel grid, not a 32-step one")
        #expect(theme.contains("8³ = 512"), "the doc must say which grid produced the numbers")

        // The superseded figures may appear only in the sentence that retires them.
        for stale in ["81.1%", "36.1%"] {
            #expect(theme.contains(stale) == theme.contains("These replace an earlier"),
                    "\(stale) is quoted as a live result again")
        }
    }

    /// **Finding #21**: no doc comment links `fitInk(_:to:target:)`, which is not a symbol.
    ///
    /// The real symbol is `fitInk(_:toLuminance:target:)` and it is `private`, so it cannot be a
    /// DocC link target from a public doc comment at all — four links pointed at a name that never
    /// existed. They are plain code spans now. Cheap to assert, and a rename that recreates the
    /// mismatch is exactly the kind of thing nobody re-reads a doc comment to catch.
    @Test func docCommentsNeverLinkAPrivateOrMissingSymbol() throws {
        let theme = try RepoRoot.source(Self.themePath)
        for privateSymbol in ["``fitInk", "``defaultPalette", "``fitStepCount", "``boxColor", "``luminance("] {
            #expect(!theme.contains(privateSymbol),
                    "\(privateSymbol) names a private symbol — a DocC link to it cannot resolve")
        }
        #expect(!theme.contains("fitInk(_:to:target:)"), "that overload does not exist under any visibility")
        #expect(!theme.contains("``current(for:)``"), "the no-contrast overload does not exist either")
        #expect(theme.contains("`fitInk(_:toLuminance:target:)`"), "the real signature should still be referenced")
    }
}

// MARK: - Finding #23: Increase Contrast is not monotone (the moss inversion)

extension AdaptiveInkBoundaryTests {

    /// A `Color.moss` / `Color.mossFill` used as a SOLID fill, in the forms the codebase writes.
    ///
    /// The trailing character matters and is why these are literal fragments rather than a bare
    /// `contains("Color.moss")`: it excludes `Color.mossInk` (a text token, never a fill) and it
    /// excludes `Color.moss.opacity(…)` (a tint wash, where the inversion does not apply because
    /// the surface underneath is still parchment). `Color.moss ` catches the ternary form
    /// `isOn ? Color.moss : Color.cream`, which is how roughly half the fills in the tree are written.
    static let solidMossFillTokens = [
        "Color.moss)", "Color.moss,", "Color.moss ",
        "Color.mossFill)", "Color.mossFill,", "Color.mossFill "
    ]

    /// Ink tokens that get WORSE on a deepening moss fill.
    static let darkInkTokens = ["Color.bark", "Color.slate", ".primaryText", ".secondaryText"]

    /// The inks sanctioned for a moss fill; both improve at `.high`. A chain that names one has
    /// thought about the pairing, so it is accepted even when it also names a dark ink — that is
    /// the correct `isOn ? Color.onMoss : Color.bark` shape, and the tree ships one.
    static let sanctionedMossInkTokens = ["onMoss", "parchmentInk"]

    /// Floor on solid-moss-fill chains found (58 at the time of writing). Without it, "no
    /// violations" and "the chain finder stopped finding chains" are the same green.
    static let minimumMossFillChains = 25

    /// Every maximal run of consecutive code lines that begin with `.` — one SwiftUI modifier chain.
    ///
    /// Scoping to the chain rather than to a line window is what makes the rule usable: a moss dot
    /// beside dark text (a `Circle().fill(Color.moss)` next to a `Text(…).foregroundStyle(.bark)`)
    /// is two chains and is not this defect. A six-line window flagged three such pairs, all false.
    /// Bounded: `index` only ever advances.
    static func modifierChains(_ lines: [AccessibilityBoundaryTests.SourceLine]) -> [[AccessibilityBoundaryTests.SourceLine]] {
        var chains: [[AccessibilityBoundaryTests.SourceLine]] = []
        var index = 0
        while index < lines.count {
            guard lines[index].code.trimmingCharacters(in: .whitespaces).hasPrefix(".") else {
                index += 1
                continue
            }
            var end = index
            while end < lines.count, lines[end].code.trimmingCharacters(in: .whitespaces).hasPrefix(".") {
                end += 1
            }
            chains.append(Array(lines[index..<end]))
            index = end
        }
        return chains
    }

    /// One chain's verdict: `(isASolidMossFill, drawsDarkInkOnIt)`.
    static func mossChainVerdict(_ chain: [AccessibilityBoundaryTests.SourceLine]) -> (fills: Bool, violates: Bool) {
        let fills = chain.contains { line in
            let isFill = line.code.contains(".background(") || line.code.contains(".fill(")
            return isFill && solidMossFillTokens.contains { line.code.contains($0) }
        }
        guard fills else { return (false, false) }
        let joined = chain.map(\.code).joined(separator: " ")
        guard !sanctionedMossInkTokens.contains(where: { joined.contains($0) }) else { return (true, false) }
        let darkInk = chain.contains { line in
            line.code.contains(".foregroundStyle(") && darkInkTokens.contains { line.code.contains($0) }
        }
        return (true, darkInk)
    }

    /// The inversion this rule exists for is REAL — pinned so that a future moss twin which no
    /// longer inverts fails here and invites the rule to be revisited rather than left as folklore.
    ///
    /// The literals are the shipping `moss` values from `FernletUIComponents.swift` (which this
    /// change may not edit), and they are pinned back to that file by text so the two cannot drift.
    @Test func deepeningMossInvertsForDarkInkAndImprovesForLightInk() throws {
        let moss = UIColor(red: 0.369, green: 0.518, blue: 0.302, alpha: 1)
        let mossHigh = UIColor(red: 0.275, green: 0.408, blue: 0.227, alpha: 1)
        let bark = UIColor(red: 0.239, green: 0.180, blue: 0.118, alpha: 1)
        let parchmentInk = UIColor(red: 0.961, green: 0.937, blue: 0.878, alpha: 1)

        // Dark ink on a solid moss fill gets WORSE for the user who asked for more contrast.
        #expect(abs(bark.contrastRatio(to: moss) - 3.04) < 0.01)
        #expect(abs(bark.contrastRatio(to: mossHigh) - 2.06) < 0.01)
        #expect(bark.contrastRatio(to: mossHigh) < bark.contrastRatio(to: moss))

        // The sanctioned inks move the right way, which is why the rule names a REPLACEMENT rather
        // than forbidding the moss twin outright.
        #expect(UIColor.white.contrastRatio(to: mossHigh) > UIColor.white.contrastRatio(to: moss))
        #expect(parchmentInk.contrastRatio(to: mossHigh) > parchmentInk.contrastRatio(to: moss))
        #expect(UIColor.white.contrastRatio(to: mossHigh) > Self.aaSmallText)

        let components = try RepoRoot.source("FernletKit/Sources/FernletUI/FernletUIComponents.swift")
        #expect(components.contains("light: Color(red: 0.369, green: 0.518, blue: 0.302)"),
                "the moss light literal moved — re-measure the inversion before trusting this rule")
        #expect(components.contains("lightHC: Color(red: 0.275, green: 0.408, blue: 0.227)"),
                "the moss Increase Contrast twin moved — re-measure the inversion")
    }

    /// **The wall**: no shipping site draws dark ink on a solid moss fill.
    ///
    /// No such site exists today, which is exactly when fencing is cheap — the inversion is a
    /// latent hazard, and the constraint that is only a comment is the one that regresses. The
    /// ceiling is honest: this sees one modifier chain at a time, so a fill applied in a
    /// `ViewModifier`, a background pushed down through a container, an ink set by `.tint` on an
    /// ancestor, or a `.background(` whose arguments wrap onto their own lines (which ends the
    /// chain at the opening paren) is invisible to it. It is a canary on the common shape, not a
    /// proof — which is why `deepeningMossInvertsForDarkInkAndImprovesForLightInk()` pins the
    /// arithmetic separately.
    @Test func noShippingSiteDrawsDarkInkOnASolidMossFill() throws {
        var violations: [String] = []
        var fillChains = 0
        var filesScanned = 0

        for path in AccessibilityBoundaryTests.shippingFiles() {
            let source = try String(contentsOf: RepoRoot.url(path), encoding: .utf8)
            filesScanned += 1
            for chain in Self.modifierChains(AccessibilityBoundaryTests.sourceLines(source)) {
                let verdict = Self.mossChainVerdict(chain)
                if verdict.fills { fillChains += 1 }
                guard verdict.violates, let first = chain.first else { continue }
                violations.append("\(path):\(first.number): \(chain.map(\.raw).joined(separator: " ").trimmingCharacters(in: .whitespaces))")
            }
        }

        #expect(filesScanned >= 300, "scanned only \(filesScanned) files — a shipping root stopped resolving")
        #expect(
            fillChains >= Self.minimumMossFillChains,
            """
            Found only \(fillChains) solid moss fills (floor \(Self.minimumMossFillChains)). The \
            chain finder has stopped finding them, so a green result below means nothing.
            """
        )
        #expect(
            violations.isEmpty,
            """
            \(violations.count) site(s) draw dark ink on a solid moss fill. Under Increase Contrast \
            the fill deepens and that pairing gets WORSE (bark on moss: 3.04:1 -> 2.06:1). Use \
            Color.onMoss or Color.parchmentInk, both of which improve at .high:
            \(violations.prefix(8).joined(separator: "\n"))
            """
        )
    }

    /// Non-vacuity: the rule fires on the shape it forbids and stays silent on the four shapes it
    /// must tolerate. Without this half, deleting the rule's body would leave the wall green.
    @Test func mossFillRuleFiresOnlyOnTheForbiddenPairing() {
        func verdict(_ snippet: String) -> (fills: Bool, violates: Bool) {
            let chains = Self.modifierChains(AccessibilityBoundaryTests.sourceLines(snippet))
            let results = chains.map(Self.mossChainVerdict)
            return (results.contains { $0.fills }, results.contains { $0.violates })
        }

        let planted = """
        Text("Together")
            .foregroundStyle(Color.bark)
            .padding(8)
            .background(Color.moss, in: Capsule())
        """
        #expect(verdict(planted).violates, "the forbidden pairing must fire")

        let sanctioned = """
        Text("Together")
            .foregroundStyle(Color.onMoss)
            .background(Color.moss, in: Capsule())
        """
        #expect(verdict(sanctioned).fills)
        #expect(!verdict(sanctioned).violates, "onMoss is the sanctioned ink for this fill")

        // The real shipping shape that a line-window rule flagged falsely: the ink is ternaried
        // against the fill, so the moss branch really does get onMoss.
        let ternaried = """
        Image(systemName: "bolt.fill")
            .foregroundStyle(isOn ? Color.onMoss : Color.bark)
            .background(isOn ? Color.moss : Color.cream, in: RoundedRectangle(cornerRadius: 12))
        """
        #expect(!verdict(ternaried).violates, "a fill and ink ternaried together have been thought about")

        // A moss DOT beside dark text — two chains, not one view. Three sites in the tree.
        let neighbours = """
        Circle()
            .fill(Color.moss)
            .frame(width: 10, height: 10)
        Text("Duress code set")
            .foregroundStyle(Color.bark)
        """
        #expect(verdict(neighbours).fills)
        #expect(!verdict(neighbours).violates, "a fill and an ink in different chains are different views")

        // A tint wash is not a solid fill: the ink still sits on parchment showing through.
        let wash = """
        Text("Nearby")
            .foregroundStyle(Color.bark)
            .background(Color.moss.opacity(0.14), in: Capsule())
        """
        #expect(!verdict(wash).fills, "an opacity wash is not a solid moss surface")

        // `mossInk` is a TEXT token and must never be mistaken for a fill.
        let inkToken = """
        Text("Equipped")
            .foregroundStyle(Color.mossInk)
            .background(Color.cream, in: Capsule())
        """
        #expect(!verdict(inkToken).fills)
    }
}

// MARK: - Finding #26: the AccentColor asset duplicates the mossInk token

extension AdaptiveInkBoundaryTests {

    /// Repo-relative path of the asset catalog entry that duplicates `Color.mossInk`.
    static let accentColorPath = "App/Fernlet/Assets.xcassets/AccentColor.colorset/Contents.json"

    /// The `(red, green, blue)` of one `colors` entry in an asset catalog colorset, for the given
    /// appearance — `nil` for the universal (light) entry, `"dark"` for the luminosity twin.
    ///
    /// Hand-decoded from `JSONSerialization` rather than through `Codable`: the components are
    /// STRINGS in the catalog format ("0.275", not 0.275), and a `Codable` model would have to
    /// mirror the whole shape to reach three numbers. Returns `nil` on any mismatch, and every
    /// caller treats `nil` as a failure rather than as "unchanged".
    static func colorsetComponents(_ json: Any, appearance: String?) -> (CGFloat, CGFloat, CGFloat)? {
        guard let root = json as? [String: Any], let colors = root["colors"] as? [[String: Any]] else { return nil }
        for entry in colors {
            let appearances = entry["appearances"] as? [[String: Any]] ?? []
            let value = appearances.compactMap { $0["value"] as? String }.first
            guard value == appearance,
                  let color = entry["color"] as? [String: Any],
                  let components = color["components"] as? [String: String],
                  let red = Double(components["red"] ?? ""),
                  let green = Double(components["green"] ?? ""),
                  let blue = Double(components["blue"] ?? "") else { continue }
            return (CGFloat(red), CGFloat(green), CGFloat(blue))
        }
        return nil
    }

    /// **Finding #26**: the app's `AccentColor` asset carries `mossInk`'s literals with no link
    /// back to the token, so editing the token leaves the system accent — tab tint, switches,
    /// pickers, the share sheet — on the old colour with a clean build and no visible symptom.
    ///
    /// The asserted direction matters: the TOKEN is the source of truth and the asset must follow.
    /// If they ever disagree, the fix is to re-export the asset, never to relax this test.
    /// `@MainActor` for the same reason `AdaptiveColorIsolationTests` is: this is the one test here
    /// that crosses the SwiftUI→UIKit bridge (`UIColor(Color.mossInk)`), and that bridge is not
    /// safe to call off the main thread — the note at the top of `FernletUIComponents.swift` says
    /// so, and a device-only SIGTRAP is how the codebase learned it.
    @MainActor
    @Test func accentColorAssetMatchesTheMossInkToken() throws {
        let data = try Data(contentsOf: RepoRoot.url(Self.accentColorPath))
        let json = try JSONSerialization.jsonObject(with: data)

        let bridged = UIColor(Color.mossInk)
        let expectations: [(String, String?, UIUserInterfaceStyle)] = [
            ("light (universal)", nil, .light),
            ("dark (luminosity)", "dark", .dark)
        ]
        for (label, appearance, style) in expectations {
            let asset = try #require(Self.colorsetComponents(json, appearance: appearance),
                                     "\(Self.accentColorPath) has no \(label) entry in the shape this test can read")
            let token = bridged.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            let expected = UIColor(red: asset.0, green: asset.1, blue: asset.2, alpha: 1)
            #expect(
                Self.componentsMatch(token, expected, tolerance: 0.002),
                """
                AccentColor's \(label) entry is \(asset) but Color.mossInk resolves to \
                \(token.hexString ?? "??"). The asset duplicates the token's literals with no \
                linkage — re-export \(Self.accentColorPath) from the token, not the other way round.
                """
            )
        }
    }
}
#endif
