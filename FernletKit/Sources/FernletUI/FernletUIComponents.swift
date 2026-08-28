//
//  FernletUIComponents.swift
//  FernletUI
//
//  The shared SwiftUI design system: adaptive color tokens and the reusable
//  screen/sheet primitives. Carved out of the app target (SPM carve-up §14
//  remaining item 2). App-navigation enums (`FernletTab`, `FernletSheet`) are
//  deliberately NOT here — they are app concerns and live in
//  `Fernlet/FernletNavigation.swift`.
//

import SwiftUI

public extension Color {
    // The `@Sendable` on each dynamic provider is load-bearing, not decoration: without it the closure
    // inherits this module's `defaultIsolation(MainActor.self)`, and UIKit resolving the color on
    // SwiftUI's off-main render thread trips the Swift 6 executor check and traps. See FernletTheme.swift.
    // Each provider now forwards `trait.accessibilityContrast` as well as the interface style — the
    // review's §4.2 observation was that the traits already carried it and the palette threw it
    // away. `.unspecified`/`.normal` resolve exactly as before; only `.high` branches.
    static let parchment = Color(UIColor { @Sendable trait in
        FernletThemePalette.current(for: trait.userInterfaceStyle, contrast: trait.accessibilityContrast).background
    })
    static let cream = Color(UIColor { @Sendable trait in
        FernletThemePalette.current(for: trait.userInterfaceStyle, contrast: trait.accessibilityContrast).box
    })
    static let bark = Color(UIColor { @Sendable trait in
        FernletThemePalette.current(for: trait.userInterfaceStyle, contrast: trait.accessibilityContrast).primaryText
    })
    static let slate = Color(UIColor { @Sendable trait in
        FernletThemePalette.current(for: trait.userInterfaceStyle, contrast: trait.accessibilityContrast).secondaryText
    })
    /// The moss tint/accent. Under Increase Contrast the light value deepens to the
    /// already-approved ``mossInk`` hex `#46683A` — **5.54:1 on parchment / 5.95:1 on cream**,
    /// against plain `moss`'s 3.74:1 / 4.02:1 — which lifts the app's most-used accent (179
    /// foreground sites) from "large text and UI only" to AA small text for the users who asked
    /// for more contrast. The ~10 sites that use `moss` as a solid *fill* improve too rather than
    /// regressing: white ink on `#46683A` measures 6.36:1 (it was 4.29:1 on plain `moss`) and
    /// ``parchmentInk`` measures 5.54:1. Dark mode is unchanged — dark `moss` is already 6.65:1 on
    /// the dark background and 5.74:1 on the dark box.
    static let moss = Color(
        light: Color(red: 0.369, green: 0.518, blue: 0.302),
        dark:  Color(red: 0.498, green: 0.690, blue: 0.412),
        lightHC: Color(red: 0.275, green: 0.408, blue: 0.227),
        darkHC:  Color(red: 0.498, green: 0.690, blue: 0.412)
    )
    static let fern = Color(
        light: Color(red: 0.447, green: 0.639, blue: 0.392),
        dark:  Color(red: 0.561, green: 0.753, blue: 0.467)
    )
    static let goldenrod = Color(
        light: Color(red: 0.824, green: 0.592, blue: 0.231),
        dark:  Color(red: 0.878, green: 0.663, blue: 0.329)
    )
    static let softTaupe = Color(
        light: Color(red: 0.721, green: 0.658, blue: 0.572),
        dark:  Color(red: 0.639, green: 0.588, blue: 0.506)
    )
    static let dustyRose = Color(
        light: Color(red: 0.714, green: 0.439, blue: 0.451),
        dark:  Color(red: 0.847, green: 0.549, blue: 0.561)
    )
    static let terracotta = Color(
        light: Color(red: 0.724, green: 0.329, blue: 0.239),
        dark:  Color(red: 0.839, green: 0.459, blue: 0.345)
    )
    static let sun = Color(
        light: Color(red: 0.922, green: 0.710, blue: 0.318),
        dark:  Color(red: 0.949, green: 0.761, blue: 0.408)
    )
    /// Fixed parchment-cream ink (#F5EFE0) for text/icons sitting on filled-moss backgrounds, where
    /// the adaptive `parchment` would flip too dark in dark mode. Non-adaptive by design — the moss
    /// fill it sits on is itself a fixed deep green in both appearances.
    static let parchmentInk = Color(red: 0.961, green: 0.937, blue: 0.878)

    // MARK: Contrast-safe pairs for filled buttons
    //
    // A filled accent button needs BOTH halves of a pair: the `*Fill` background and its matching
    // `on*` ink. White ink is only safe on the light-mode fills — dark-mode `moss`/`terracotta`
    // lighten enough that white falls to 2.5:1 / 3.2:1 — so the ink tokens flip to `midnight` in
    // dark mode (6.5:1 on dark moss, 5.1:1 on dark terracotta). Never hand-roll
    // `.foregroundStyle(.white)` on a moss or terracotta fill.

    /// Ink for text/icons on a ``mossFill`` button: white in light mode (5.4:1), `midnight` in dark.
    static let onMoss = Color(light: .white, dark: .midnight)

    /// The filled-button moss. Light mode deepens to #4F7444 so white ink clears 5.4:1 (plain `moss`
    /// gives only 4.29:1); dark mode keeps `moss` itself, paired with ``onMoss``'s midnight ink.
    /// `moss` stays the tint/accent color — this token is for *filled* button backgrounds.
    ///
    /// Increase Contrast uses the owner-approved `#38562C` (*"AX twins run Increase Contrast:
    /// slate → #45535E, card edges 30%, filled moss → #38562C"*, the 2026-08-21 design spec).
    /// Recomputed here: white ink on it measures **8.28:1**, and the fill itself measures 7.22:1
    /// against parchment / 7.75:1 against cream, so the button's *edge* clears the 3:1 non-text
    /// floor with room to spare as well. ``onMoss`` needs no twin — white only gets better as the
    /// fill deepens. Dark mode is unchanged (dark moss with midnight ink is already 6.5:1).
    static let mossFill = Color(
        light: Color(red: 0.310, green: 0.455, blue: 0.267),
        dark:  Color(red: 0.498, green: 0.690, blue: 0.412),
        lightHC: Color(red: 0.220, green: 0.337, blue: 0.173),
        darkHC:  Color(red: 0.498, green: 0.690, blue: 0.412)
    )

    /// Ink for text/icons on a filled `terracotta` (destructive) button: white in light mode (4.8:1),
    /// `midnight` in dark mode where terracotta lightens and white would fall to 3.2:1.
    static let onTerracotta = Color(light: .white, dark: .midnight)

    /// Ink for text/icons on a filled `goldenrod` button. Unlike moss and terracotta, goldenrod is a
    /// light warm amber in *both* appearances, so the ink never flips: white on it measures ~2.2:1,
    /// while this fixed `midnight` clears 6:1 on the light fill and more on the dark one.
    static let onGoldenrod = Color.midnight

    /// Accessible ink for destructive *text* — a red label drawn on parchment/cream rather than on a
    /// terracotta fill. Light mode deepens to #9E4028 (5.4:1 on a tinted chip); dark mode keeps
    /// `terracotta`, which already clears 4.5:1 on the dark box.
    static let terracottaInk = Color(
        light: Color(red: 0.620, green: 0.251, blue: 0.157),
        dark:  Color(red: 0.839, green: 0.459, blue: 0.345)
    )

    /// Accessible ink for text drawn in the moss family — presence/equipped labels, gift counts —
    /// on parchment/cream, mirroring ``terracottaInk``. Plain `moss` is a fill/glyph accent at
    /// 3.74:1/4.02:1 on light surfaces, which clears the 3:1 non-text floor but fails 4.5:1 text;
    /// this token is for the *text* uses only. Light mode is the owner-approved `#46683A`
    /// (`Docs/design-refs/ux-review-2026-08-16/design-spec-2026-08-21.md`), measured **5.54:1 on
    /// parchment / 5.95:1 on cream**. Dark mode is unchanged from `moss`'s existing dark accent
    /// (already 6.65:1 / 5.74:1 on the dark surfaces, so no dark-mode fix was needed).
    static let mossInk = Color(
        light: Color(red: 0.275, green: 0.408, blue: 0.227),
        dark:  Color(red: 0.498, green: 0.690, blue: 0.412)
    )

    /// Accessible ink for text drawn in the goldenrod family — the app's "something is
    /// misconfigured" copy (presence/heart/purge warnings) — on parchment/cream, mirroring
    /// ``terracottaInk``. Plain `goldenrod` is the worst text contrast in the codebase at
    /// 2.22:1/2.39:1 on light surfaces — it fails even the 3:1 non-text floor. Light mode is
    /// `#8C5D18`, measured **4.95:1 on parchment / 5.32:1 on cream**. Dark mode is unchanged from
    /// `goldenrod`'s existing dark accent (already 7.97:1 / 6.88:1 on the dark surfaces).
    static let goldenrodInk = Color(
        light: Color(red: 0.549, green: 0.365, blue: 0.094),
        dark:  Color(red: 0.878, green: 0.663, blue: 0.329)
    )

    // MARK: Increase Contrast — the tokens that deliberately have NO high-contrast twin
    //
    // Recording the refusals, because "goldenrod has no HC branch" reads like an oversight and is
    // not one. Only `slate`, `moss` and `mossFill` branch on `colorSchemeContrast`; every other
    // token resolves identically at `.increased`. Three reasons, in descending order of force:
    //
    // 1. `goldenrod` CANNOT be deepened — it would break its own ink pair. `onGoldenrod` is a fixed
    //    `midnight`, because goldenrod is a light warm amber in BOTH appearances; midnight on the
    //    current fill measures 6.43:1, and midnight on `goldenrodInk`'s #8C5D18 measures **2.89:1**.
    //    Deepening the fill under Increase Contrast would hand the users who asked for MORE contrast
    //    a button whose label they can no longer read. The correct fix for goldenrod was the one
    //    already shipped: `goldenrodInk` at the ~25 sites where goldenrod inked TEXT. The fill stays.
    //
    // 2. `terracotta`, `fern`, `sun`, `dustyRose`, `softTaupe` have no owner-approved twin. The
    //    2026-08-21 design spec names exactly two AX-twin hexes (slate and filled moss) and this
    //    change ships exactly those two plus a reuse of the already-approved `mossInk`. Inventing a
    //    hex here is a design decision wearing an accessibility costume; every value in this file
    //    carries a measured ratio and a sign-off, and that is the property worth keeping.
    //
    // 3. A MUTED ink that also clears AA is arithmetically impossible in this palette, at any
    //    contrast setting. The ~30 `.foregroundStyle(Color.slate.opacity(0.4…0.7))` sites cannot be
    //    rescued by a token: light `slate` at FULL strength is 4.78:1 on parchment, so any alpha
    //    below 1 is under the 4.5:1 floor by construction (0.7 → 2.74:1, 0.5 → 1.98:1). Increase
    //    Contrast improves them — slate resolves to #45535E, so 0.7 alpha rises to 3.42:1 and clears
    //    the 3:1 non-text floor — but 0.8 alpha still only reaches 4.28:1. **De-emphasize by SIZE and
    //    WEIGHT, not by alpha.** A `.labelSmall` at full-strength slate reads as secondary and is
    //    legible; the same text at 60% is neither.
}

public extension Color {
    /// Resolves to `light` in light mode, `dark` in dark mode.
    ///
    /// Both sides are bridged to `UIColor` up front rather than inside the provider: the provider runs on
    /// whatever thread resolves the trait collection, and the SwiftUI `UIColor(Color)` bridge is not safe to
    /// call there. Callers pass fixed literal colors, so resolving once is equivalent — and cheaper.
    init(light: Color, dark: Color) {
        self.init(light: light, dark: dark, lightHC: light, darkHC: dark)
    }

    /// Resolves on **two** axes: interface style *and* Increase Contrast.
    ///
    /// The seam behind the review's §4.2. The four dynamic providers already receive
    /// `trait.accessibilityContrast` and were throwing it away, so widening the existing
    /// ``init(light:dark:)`` — which every accent token already routes through — turns Increase
    /// Contrast on across the whole palette with **zero call-site churn**: a token gains a
    /// high-contrast twin by naming one, and every one of its call sites inherits it.
    ///
    /// `trait.accessibilityContrast == .high` is UIKit's spelling of SwiftUI's
    /// `colorSchemeContrast == .increased`. Only that value branches: `.normal` and `.unspecified`
    /// both resolve to the default pair, so **nothing changes at default settings** — which is the
    /// property that makes this safe to land across 179 `moss` sites at once.
    ///
    /// All four sides are bridged to `UIColor` up front, for the reason ``init(light:dark:)``
    /// gives: the provider runs on whatever thread resolves the trait collection, including
    /// SwiftUI's off-main render thread, where the `UIColor(Color)` bridge is not safe to call.
    ///
    /// - Parameters:
    ///   - light: Light mode at normal contrast.
    ///   - dark: Dark mode at normal contrast.
    ///   - lightHC: Light mode under Increase Contrast. Pass `light` when the token has no
    ///     approved twin — every hex here needs a measured ratio and a design sign-off.
    ///   - darkHC: Dark mode under Increase Contrast. Dark mode is the palette's strong side (all
    ///     nine accents already clear 4.5:1 on both dark surfaces), so this is usually `dark`.
    init(light: Color, dark: Color, lightHC: Color, darkHC: Color) {
        let lightUI = UIColor(light)
        let darkUI = UIColor(dark)
        let lightHCUI = UIColor(lightHC)
        let darkHCUI = UIColor(darkHC)
        self.init(UIColor { @Sendable trait in
            let isDark = trait.userInterfaceStyle == .dark
            guard trait.accessibilityContrast == .high else { return isDark ? darkUI : lightUI }
            return isDark ? darkHCUI : lightHCUI
        })
    }
}

public extension Color {
    /// The alpha a `bark` hairline needs to clear the **3:1 WCAG non-text floor** as a component
    /// boundary — the floor that applies to the edge of a card, chip, pill or bar.
    ///
    /// Measured, not guessed, and the review flagged the guess: `bark.opacity(0.35)` had been
    /// asserted at 3.1:1 and actually measures **1.97:1 on parchment / 1.99:1 on cream**. Walking
    /// the alpha: 0.40 → 2.23:1, 0.45 → 2.52:1, 0.50 → 2.85:1, **0.55 → 3.24:1 on cream and 3.16:1
    /// on parchment**. So 0.55 is the first step that clears the floor against *both* adjacent
    /// surfaces, which is the requirement for an edge (it separates the card from the page as much
    /// as from its own fill). Dark mode at the same alpha measures 4.84:1 against the dark box.
    ///
    /// A soft edge of this family sits at 1.15–1.25:1 and is effectively invisible to a low-vision
    /// user. Such edges are *deliberately* soft at default settings; this is what one becomes when
    /// the user asks for more contrast.
    ///
    /// **What actually adopts this, stated because the number is small and an earlier draft of this
    /// comment implied otherwise.** ``barkEdge(_:normal:)`` and ``terracottaEdge(_:normal:)`` have
    /// **five call sites in two files** — `FernletPrimitives.swift`'s ``FernletCard`` border, and
    /// `ChipButtonStyle` / `PillButtonStyle` in this file (unselected chip at 0.12, secondary pill
    /// at 0.14, destructive chip and pill at terracotta 0.35). Against that, the tree contains
    /// **187** code-only `bark.opacity(…)` occurrences, the bulk of them at 0.08 and 0.10, and none
    /// of those respond to Increase Contrast. So this helper covers the shared *components* an edge
    /// is drawn by, not "the app's edges": a hand-rolled overlay in a feature view still ships its
    /// literal alpha.
    ///
    /// That is a deliberate stopping point rather than an oversight — a blanket sweep of 187 sites
    /// is a visual change to every screen and belongs in a design pass, not in a helper's doc
    /// comment. It is recorded here so the next reader does not mistake five adoptions for
    /// coverage, and it is the same caveat `Docs/Accessibility-Nutrition-Labels.md` carries for the
    /// Sufficient Contrast row.
    static let fernletHighContrastEdgeAlpha: Double = 0.55

    /// A `bark` component hairline that thickens to ``fernletHighContrastEdgeAlpha`` under
    /// Increase Contrast and is otherwise exactly the `normal` alpha the design already ships.
    ///
    /// One helper rather than a `colorSchemeContrast` ternary at each boundary, so the measurement
    /// above lives in one place and a new component inherits it by construction.
    ///
    /// - Parameters:
    ///   - contrast: The view's `\.colorSchemeContrast`. A `ButtonStyle` has no environment of its
    ///     own — read it in the style's nested content view (see ``ChipButtonStyle``'s `Chip`).
    ///   - normal: The alpha at default contrast. Unchanged behaviour is the whole point.
    static func barkEdge(_ contrast: ColorSchemeContrast, normal: Double) -> Color {
        Color.bark.opacity(contrast == .increased ? fernletHighContrastEdgeAlpha : normal)
    }

    /// The destructive sibling of ``barkEdge(_:normal:)``, for the tinted-terracotta boundary.
    ///
    /// `terracottaInk` is a much lighter ink than `bark`, so it needs more alpha for the same
    /// floor: 0.35 → 1.73:1, 0.55 → 2.48:1, **0.70 → 3.33:1 on cream**. 0.70 is therefore the
    /// Increase Contrast value; the shipping 0.35 is unchanged at default settings.
    static func terracottaEdge(_ contrast: ColorSchemeContrast, normal: Double) -> Color {
        Color.terracottaInk.opacity(contrast == .increased ? 0.70 : normal)
    }
}

public extension View {
    /// Tags a screen or sheet root with a stable, queryable accessibility identifier for
    /// UX appearance tests, while keeping every descendant element individually
    /// accessible (`.contain`). Shipping accessibility identifiers is harmless for users.
    func uxScreenAnchor(_ identifier: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }

    /// Grows a control's hit area to the 44×44pt minimum without changing how it draws.
    ///
    /// Apply to the `Button` itself — the frame becomes the layout box and `contentShape` makes all
    /// of it tappable, while the glyph stays its drawn size, centered. The glyph-only buttons across
    /// the app (calendar chevrons, remove-ingredient X, move-widget arrows) sit at 24–34pt without
    /// it. Prefer ``fernletIconButton(_:minWidth:minHeight:)``, which also supplies the VoiceOver
    /// label such a button always needs.
    func fernletTapTarget(minWidth: CGFloat = 44, minHeight: CGFloat = 44) -> some View {
        frame(minWidth: minWidth, minHeight: minHeight)
            .contentShape(Rectangle())
    }

    /// The two things every icon-only button owes the user: a 44pt tap target and a VoiceOver label.
    ///
    /// ```swift
    /// Button { previousMonth() } label: { Image(systemName: "chevron.left") }
    ///     .fernletIconButton("Previous month")
    /// ```
    ///
    /// Without a label VoiceOver reads the SF Symbol name — "chevron.left", "person.2" — or nothing
    /// at all. Name the *action* ("Remove tomato", "Hide widget"), not the glyph.
    ///
    /// The label is a `LocalizedStringKey`, so the literal at the call site is harvested into the
    /// calling target's string catalog — including the interpolated ones, which extract as format
    /// strings ("Remove %@") and therefore stay translatable even though the noun is runtime data.
    /// The argument's *static type* is what picks SwiftUI's `accessibilityLabel(_: LocalizedStringKey)`
    /// overload here: `LocalizedStringKey` is neither `Text` nor `StringProtocol`, so the `Text` and
    /// generic-string overloads are not even applicable and there is nothing for the type checker to
    /// prefer wrongly. Use ``fernletIconButton(verbatim:minWidth:minHeight:)`` for a label that is
    /// already resolved.
    func fernletIconButton(
        _ accessibilityLabel: LocalizedStringKey,
        minWidth: CGFloat = 44,
        minHeight: CGFloat = 44
    ) -> some View {
        fernletTapTarget(minWidth: minWidth, minHeight: minHeight)
            .accessibilityLabel(accessibilityLabel)
    }

    /// The non-localizing form of ``fernletIconButton(_:minWidth:minHeight:)``, for a VoiceOver
    /// label that is already final — one assembled from user data, or one a package caller resolved
    /// itself with `String(localized:bundle:.module)`.
    ///
    /// It wraps the string in `Text(verbatim:)` before handing it over, which pins SwiftUI's
    /// `accessibilityLabel(_: Text)` overload; passing the bare `String` would land on the
    /// `StringProtocol` overload, which is also non-localizing but says so less clearly. As with
    /// ``SectionLabel/init(verbatim:)``, the distinct `verbatim:` label exists so this cannot be
    /// chosen by accident: a same-label `String` overload would capture every plain literal.
    func fernletIconButton(
        verbatim accessibilityLabel: String,
        minWidth: CGFloat = 44,
        minHeight: CGFloat = 44
    ) -> some View {
        fernletTapTarget(minWidth: minWidth, minHeight: minHeight)
            .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }
}

/// The standard screen title block: a display-serif title with an italic slate subtitle.
///
/// Used at the top of the major tab screens and hub pages so page headers share one type
/// treatment. `subtitleFirst` places the subtitle above the title (the "eyebrow" layout); the
/// optional `identifier` gives UX appearance tests a stable anchor for the whole header.
///
/// Titles **wrap** (two lines by default) rather than shrink-and-truncate: at accessibility sizes a
/// one-line header used to read "Protect private spa…", and a header that swallows the page's name
/// is worse than a header that takes a second line. Pass `titleLineLimit: 3` where the title is
/// user-supplied and long (a recipe name, say); the subtitle takes up to three lines.
public struct ScreenHeader: View {
    var title: Text
    var subtitle: Text
    var subtitleFirst: Bool
    /// Optional stable accessibility identifier so UX appearance tests can anchor a
    /// screen's header (e.g. "screen.home"). An identifier is a test *token*, never display text,
    /// so it stays a plain `String` and stays English forever. Empty when unset — a no-op for users.
    var identifier: String?
    /// How many lines the title may wrap to before truncating. Two by default.
    var titleLineLimit: Int

    /// The localizing initializer, for the common case where both halves are authored copy.
    ///
    /// Both literals are harvested into the calling target's string catalog and looked up in
    /// `Bundle.main`, which is the app bundle and therefore the right one for every app-target
    /// caller. Where only *one* half is authored copy — a user's recipe name over a fixed strapline,
    /// say — use the `Text`-taking initializer below and decide each half separately; there is
    /// deliberately no mixed `LocalizedStringKey`/`String` overload, because one would silently
    /// swallow a literal on the other side.
    public init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        subtitleFirst: Bool = false,
        identifier: String? = nil,
        titleLineLimit: Int = 2
    ) {
        self.init(
            title: Text(title),
            subtitle: Text(subtitle),
            subtitleFirst: subtitleFirst,
            identifier: identifier,
            titleLineLimit: titleLineLimit
        )
    }

    /// The `Text`-taking initializer: each half is localized, or not, by whoever builds it.
    ///
    /// This is the escape hatch for headers whose title is user or peer data — a recipe name, a
    /// formatted date — where `Text(verbatim:)` is the *correct* answer and translating would be a
    /// bug, and for package callers who resolved their own copy with `String(localized:bundle:.module)`.
    /// `Text` is not expressible by a string literal, so this overload can never steal a call site
    /// that meant to localize.
    public init(
        title: Text,
        subtitle: Text,
        subtitleFirst: Bool = false,
        identifier: String? = nil,
        titleLineLimit: Int = 2
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleFirst = subtitleFirst
        self.identifier = identifier
        self.titleLineLimit = titleLineLimit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if subtitleFirst { subtitleView }
            title
                .font(.fernlet(.display))
                .foregroundStyle(Color.bark)
                .lineLimit(titleLineLimit)
                .fixedSize(horizontal: false, vertical: true)
            if !subtitleFirst { subtitleView }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        // Must follow `.combine`, not precede it: a trait added to the pre-combine `VStack` is
        // discarded when SwiftUI flattens the children into one accessibility element. This is the
        // screen/pushed-page title, the top of the Headings rotor for the page — h1.
        .accessibilityAddTraits(.isHeader)
        .accessibilityHeading(.h1)
        .accessibilityIdentifier(identifier ?? "")
    }

    private var subtitleView: some View {
        subtitle
            .font(.fernlet(.bodySmall))
            .italic()
            .foregroundStyle(Color.slate)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A rounded cream pill button for a screen header's trailing action — icon, text, or both.
///
/// Sits alongside ``ScreenHeader`` on tab screens for actions like opening settings or starting an
/// entry flow. At least one of `title` / `systemImage` must be provided (asserted in the
/// initializer); the 58pt minimum height keeps it comfortably tappable.
///
/// - Important: an **icon-only** button must pass `accessibilityLabel:` — without it VoiceOver falls
///   back to the raw SF Symbol name and announces "plus" or "person.2". Title-bearing buttons are
///   already announced by their title, so the label is only needed there to say something different
///   from what is drawn. The title never wraps: the pill grows instead, so accessibility sizes can't
///   break a word in half ("Shar/e").
public struct HeaderActionButton: View {
    /// The drawn pill title, already resolved. Nil for an icon-only button — the layout branches on
    /// that, which is why it stays optional rather than collapsing to an empty `Text`.
    var title: Text?
    var systemImage: String?
    /// VoiceOver label; overrides the drawn title. Required in practice for icon-only buttons.
    var axLabel: Text?
    var action: () -> Void

    /// Both text parameters are `LocalizedStringKey`, so a literal at the call site is harvested
    /// into the calling target's string catalog and resolved against `Bundle.main` — the app bundle,
    /// and every one of today's call sites is in the app target.
    ///
    /// `systemImage` stays a `String` because an SF Symbol name is a token: translating
    /// "gearshape" would not find a symbol. There is no verbatim overload here because no caller
    /// needs one — every title and label on this control is authored copy, not user data — and each
    /// overload added is one more chance for a literal to pick the non-localizing branch.
    public init(
        title: LocalizedStringKey? = nil,
        systemImage: String? = nil,
        accessibilityLabel: LocalizedStringKey? = nil,
        action: @escaping () -> Void
    ) {
        assert(title != nil || systemImage != nil, "header action needs title or image")
        self.title = title.map { Text($0) }
        self.systemImage = systemImage
        self.axLabel = accessibilityLabel.map { Text($0) }
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                }
                if let title {
                    title
                        .font(.fernlet(.label))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(Color.bark)
            .frame(minWidth: title == nil ? 58 : 72, minHeight: 58)
            .padding(.horizontal, title == nil ? 0 : 10)
            .background(Color.cream.opacity(0.9), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.bark.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(resolvedAccessibilityLabel)
    }

    /// The VoiceOver label, resolved through the same precedence the old `??` chain expressed:
    /// an explicit label, else the drawn title, else — as a last resort — the SF Symbol name.
    ///
    /// The chain had to become a computed `Text` because its links no longer share a type: the
    /// first two are localized `Text`s and the symbol name is a token that must never be
    /// translated. The symbol fallback is a diagnostic, not a design: a button that reaches it is
    /// announcing "gearshape", which is the bug the `accessibilityLabel:` parameter exists to
    /// prevent, so it is left untranslated on purpose rather than dressed up as real copy.
    private var resolvedAccessibilityLabel: Text {
        if let axLabel { return axLabel }
        if let title { return title }
        return Text(verbatim: systemImage ?? "Action")
    }
}

/// A small tilted polaroid-style tile: a photo (or flat color swatch) over a handwritten-style
/// caption on a cream frame.
///
/// Used by the friend photo wall and meal-photo surfaces to render snapshots as scattered keepsake
/// prints. When `imageData` decodes to a `UIImage` it fills the frame; otherwise the `color`
/// placeholder shows. `rotation` is in degrees, giving each tile its hand-placed tilt.
public struct PolaroidTile: View {
    var color: Color
    var caption: String
    var rotation: Double
    var imageData: Data?
    var imageWidth: CGFloat
    var imageHeight: CGFloat

    public init(
        color: Color,
        caption: String,
        rotation: Double,
        imageData: Data? = nil,
        imageWidth: CGFloat = 98,
        imageHeight: CGFloat = 86
    ) {
        self.color = color
        self.caption = caption
        self.rotation = rotation
        self.imageData = imageData
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    public var body: some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: imageWidth, height: imageHeight)
                .overlay {
                    if let imageData, let image = UIImage(data: imageData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            // T2-10. Smart Invert inverts every pixel it is not told to leave
                            // alone, which turns a photograph into a negative — the single case
                            // where the accommodation destroys the content it is meant to help
                            // read. The cream frame and caption around it still invert, which is
                            // the point: the chrome adapts, the photo does not.
                            .accessibilityIgnoresInvertColors()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(caption)
                .font(.fernlet(.bubble))
                // Full-strength slate, not 58%: the faded caption measured 1.9:1 on the cream frame.
                .foregroundStyle(Color.slate)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.top, 7)
        .padding(.bottom, 14)
        .background(Color.cream.opacity(0.82), in: RoundedRectangle(cornerRadius: 4))
        .shadow(color: Color.bark.opacity(0.08), radius: 12, x: 0, y: 6)
        .rotationEffect(.degrees(rotation))
    }
}

public extension View {
    func fernletSheetStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
            .tint(Color.moss)
    }

    func fernletWrappingText() -> some View {
        self
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The standard cream text-field card used by every entry sheet.
    ///
    /// Carries the design-system font as well as the chrome: without it a `TextField` renders its
    /// value and placeholder in system SF, next to serif placeholders in the same sheet. Pass
    /// `font: .fernlet(.label)` for numeric fields (the tabular DM Sans reads better for digits);
    /// the parameter defaults to `nil` and resolves inside the body, because a `@MainActor`
    /// expression can never be a default argument in this module.
    func sheetTextInput(font: Font? = nil) -> some View {
        self
            .font(font ?? .fernlet(.body))
            .textInputAutocapitalization(.sentences)
            .autocorrectionDisabled(false)
            .textContentType(.none)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }

    /// A keyboard accessory toolbar carrying a single moss "Done" (checkmark) button that dismisses the
    /// keyboard globally. Attach at a *sheet root* so every text/number field inside gets a Done: the
    /// numeric pads otherwise have no return key and float over the save bar. Resigning first responder
    /// app-wide (rather than a per-field `FocusState`) is what lets one modifier cover a whole sheet.
    func keyboardDoneToolbar() -> some View {
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                    )
                } label: {
                    // `FernletUICopy` (a resolved String), not a literal: a LocalizedStringKey
                    // written inside this package resolves against Bundle.main and never sees this
                    // module's catalog. See FernletUICopy's header.
                    Label(FernletUICopy.done, systemImage: "checkmark.circle.fill")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.moss)
                }
            }
        }
    }

    /// Standard "discard your unsaved changes?" dialog for entry sheets. Pair with
    /// `.interactiveDismissDisabled(isDirty)` and a Cancel affordance that flips `isPresented` on when
    /// dirty (dismiss directly when clean), or adopt ``SwiftUI/View/fernletDraftGuard(isDirty:showsCancelBar:onDismiss:)``
    /// which wires all three together. Keeps the wording consistent across every workout/food sheet.
    ///
    /// - Important: this is an `alert`, deliberately, and destructive confirmations elsewhere should
    ///   follow it. On iOS 26 a `.confirmationDialog` renders as a popover that **suppresses the
    ///   `.cancel`-role button**, so the user saw a lone red "Discard" and no visible way back; the
    ///   popover also anchors to the view root rather than the control that raised it. An `alert`
    ///   always renders both buttons, anchored to the screen.
    func discardConfirmation(isPresented: Binding<Bool>, onDiscard: @escaping () -> Void) -> some View {
        self.alert(FernletUICopy.Discard.title, isPresented: isPresented) {
            Button(FernletUICopy.Discard.keepEditing, role: .cancel) {}
            Button(FernletUICopy.Discard.discard, role: .destructive, action: onDiscard)
        } message: {
            Text(verbatim: FernletUICopy.Discard.message)
        }
    }

    /// A confirmation for an irreversible action, phrased so the user knows exactly what is lost.
    ///
    /// The package-side counterpart of the app target's `DestructiveConfirmation` type: use *that*
    /// inside `Fernlet/` (it carries the audit trail and the two-destructive-outcome case), and this
    /// one from package-resident UI (`ProximityKit`, `FernletLockUI`, `FernletUI`) which cannot see
    /// app-target types. Same rule as ``discardConfirmation(isPresented:onDiscard:)``: an `alert`, so
    /// iOS 26 cannot hide the Cancel button, and the mutation runs *only* from `onConfirm`.
    ///
    /// - Parameters:
    /// Every string parameter here is **already resolved** — this helper is called from package
    /// modules, whose literals must go through their own `bundle: .module` lookup before they get
    /// here (a `LocalizedStringKey` would carry no bundle and land back in `Bundle.main`). That is
    /// also why `cancelLabel` defaults to `nil` and resolves in the body from ``FernletUICopy``
    /// rather than to the word "Cancel": a default literal written here is the §4.0 trap.
    ///
    /// - Parameters:
    ///   - title: Phrase it as a question, e.g. "Delete 12 shared pictures?". Already localized.
    ///   - message: Name the exact data affected and whether anything survives. Already localized.
    ///   - confirmLabel: The destructive button, e.g. "Delete all 12". Already localized.
    ///   - cancelLabel: Overrides the shared "Cancel"; already localized when passed.
    func confirmDestructive(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String,
        confirmLabel: String,
        cancelLabel: String? = nil,
        onConfirm: @escaping () -> Void
    ) -> some View {
        self.alert(title, isPresented: isPresented) {
            Button(cancelLabel ?? FernletUICopy.cancel, role: .cancel) {}
            Button(confirmLabel, role: .destructive, action: onConfirm)
        } message: {
            Text(message)
        }
    }

    /// The whole "dirty entry sheet" contract in one line: block swipe-to-dismiss while there are
    /// unsaved changes, render the leading ``SheetCancelBar`` that swipe-dismiss would otherwise be,
    /// and raise ``discardConfirmation(isPresented:onDiscard:)`` when Cancel is tapped with a dirty
    /// draft. A clean draft dismisses immediately — no dialog for a sheet with nothing to lose.
    ///
    /// ```swift
    /// .fernletDraftGuard(isDirty: draft != original) { dismiss() }
    /// ```
    ///
    /// - Parameters:
    ///   - isDirty: Whether the sheet holds unsaved edits.
    ///   - showsCancelBar: Pass `false` when the sheet already draws its own Cancel — two bars would
    ///     also mean two views carrying the `sheet.cancel` identifier, which breaks the UI tests.
    ///     Drive the prompt yourself with `discardConfirmation` in that case.
    ///   - onDismiss: Closes the sheet. Runs on Cancel-when-clean and on Discard.
    func fernletDraftGuard(
        isDirty: Bool,
        showsCancelBar: Bool = true,
        onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(FernletDraftGuardModifier(isDirty: isDirty, showsCancelBar: showsCancelBar, onDismiss: onDismiss))
    }

    /// The draft-guard contract with the canonical ``SheetHeader`` instead of the bare cancel bar
    /// (2026-08-21 template, artboard 2a): the pinned header carries Cancel top-left and the
    /// sheet's serif title, Cancel raises the discard prompt while dirty, and swipe-dismiss stays
    /// blocked while there are unsaved edits. For draft sheets that commit via ``SheetSaveBar`` —
    /// a sheet that also commits in place passes its own header with `onDone` and drives
    /// `interactiveDismissDisabled` itself.
    ///
    /// The title/subtitle literals are harvested into the calling target's string catalog — every
    /// sheet lives in the app target, so `Bundle.main` is the right lookup.
    func fernletDraftGuard(
        isDirty: Bool,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        onDone: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(FernletDraftGuardModifier(
            isDirty: isDirty,
            title: Text(title),
            subtitle: subtitle.map { Text($0) },
            onDone: onDone,
            onDismiss: onDismiss
        ))
    }

    /// The `Text`-taking form of the header-bearing draft guard, for a sheet whose title is
    /// runtime data (an edited recipe's name). `Text` is not expressible by a string literal, so
    /// this overload can never steal a call site that meant to localize.
    func fernletDraftGuard(
        isDirty: Bool,
        title: Text,
        subtitle: Text? = nil,
        onDone: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(FernletDraftGuardModifier(
            isDirty: isDirty,
            title: title,
            subtitle: subtitle,
            onDone: onDone,
            onDismiss: onDismiss
        ))
    }
}

/// Implements ``SwiftUI/View/fernletDraftGuard(isDirty:showsCancelBar:onDismiss:)`` — see there.
///
/// Owns the discard-prompt flag itself so call sites don't each declare a `@State showDiscardConfirm`;
/// the cancel bar is installed as a top safe-area inset so it stays pinned above the sheet's own
/// scrolling content.
public struct FernletDraftGuardModifier: ViewModifier {
    let isDirty: Bool
    let showsCancelBar: Bool
    let onDismiss: () -> Void
    /// When set, the top inset renders the full ``SheetHeader`` (Cancel + title/subtitle) instead
    /// of the bare ``SheetCancelBar`` — the 2026-08-21 template's pinned header (artboard 2a).
    let title: Text?
    let subtitle: Text?
    /// Optional trailing Done for a draft sheet's dismiss-only state; nil hides the slot.
    var onDone: (() -> Void)?
    @State private var askingToDiscard = false

    public init(isDirty: Bool, showsCancelBar: Bool = true, onDismiss: @escaping () -> Void) {
        self.isDirty = isDirty
        self.showsCancelBar = showsCancelBar
        self.onDismiss = onDismiss
        self.title = nil
        self.subtitle = nil
        self.onDone = nil
    }

    /// The header-bearing form: the guard owns the sheet's pinned ``SheetHeader`` so Cancel and
    /// the discard prompt stay wired together and `sheet.cancel` renders exactly once. `onDone`
    /// fills the trailing slot for the state where a draft sheet becomes dismiss-only (a logged
    /// meal whose photo failed): the covering rule says that exit belongs top-right, never in a
    /// bottom moss pill.
    public init(
        isDirty: Bool,
        title: Text,
        subtitle: Text? = nil,
        onDone: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.isDirty = isDirty
        self.showsCancelBar = true
        self.onDismiss = onDismiss
        self.title = title
        self.subtitle = subtitle
        self.onDone = onDone
    }

    public func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(isDirty)
            .safeAreaInset(edge: .top, spacing: 0) { topInset }
            .discardConfirmation(isPresented: $askingToDiscard, onDiscard: onDismiss)
    }

    /// The pinned chrome: full header when a title was given, the legacy cancel bar otherwise.
    @ViewBuilder
    private var topInset: some View {
        if let title {
            SheetHeader(title: title, subtitle: subtitle, onCancel: cancelTapped, onDone: onDone)
        } else if showsCancelBar {
            SheetCancelBar(action: cancelTapped)
                .background(Color.parchment)
        }
    }

    private func cancelTapped() {
        if isDirty { askingToDiscard = true } else { onDismiss() }
    }
}

/// A slim top bar carrying a single leading "Cancel" button, for entry sheets that block
/// interactive (swipe) dismiss while dirty and therefore need an explicit escape hatch.
///
/// The `action` decides whether to dismiss directly or raise a discard confirmation (typically via
/// the `discardConfirmation(isPresented:onDiscard:)` modifier). Exposes the stable `sheet.cancel`
/// accessibility identifier for UI tests.
public struct SheetCancelBar: View {
    let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        HStack {
            Button(FernletUICopy.cancel, action: action)
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
                .buttonStyle(.plain)
                // T2-19: Escape leaves the sheet, matching ``SheetHeader``'s Cancel. Only one of
                // the two bars is ever mounted (see `fernletDraftGuard(showsCancelBar:)`), so the
                // shortcut has exactly one claimant per sheet.
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("sheet.cancel")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }
}

// MARK: - Sheet Layout Components

/// A left-to-right wrapping layout that flows subviews onto a new row when the current row runs
/// out of width.
///
/// A SwiftUI `Layout` conformance used by the chip/tag pickers in entry sheets (feelings, textures,
/// activity and option chips — usually styled with ``ChipButtonStyle``) where a fixed grid would
/// waste space. Each row is as tall as its tallest subview; `spacing` separates both items and rows.
public struct FlowLayout: Layout {
    var spacing: CGFloat

    public init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    /// Simulates the row-wrapping pass to report the total size needed at the proposed width.
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    /// Places each subview at its ideal size, wrapping to a new row when the next item would
    /// overflow `bounds`.
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A row of peer controls that becomes a column at accessibility text sizes.
///
/// The fix for side-by-side button pairs, which do not reflow: at AX sizes "Meal planner" /
/// "Shopping list" broke to "planne/r" and "Shopp/ing list" at different heights, and a word split
/// inside a button reads as a broken screen rather than as large text. Stacking is the honest
/// answer — two full-width buttons, each legible.
///
/// ```swift
/// AdaptiveStack {
///     Button("Meal planner") { … }.buttonStyle(ActionPillButtonStyle(.secondary))
///     Button("Shopping list") { … }.buttonStyle(ActionPillButtonStyle(.secondary))
/// }
/// ```
///
/// For a *variable-length* set of items (chips, legends, tags) reach for ``FlowLayout`` instead:
/// this switches wholesale on the text size, while FlowLayout wraps on measured width.
public struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat
    var horizontalAlignment: HorizontalAlignment
    var verticalAlignment: VerticalAlignment
    var content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        spacing: CGFloat = 10,
        horizontalAlignment: HorizontalAlignment = .center,
        verticalAlignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.content = content()
    }

    public var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: horizontalAlignment, spacing: spacing) { content }
        } else {
            HStack(alignment: verticalAlignment, spacing: spacing) { content }
        }
    }
}

/// A labeled form row for entry sheets: an uppercase small-label caption above arbitrary content.
///
/// The standard building block of the food/workout/journal entry sheets — it pairs a
/// design-system `labelSmall` caption with any input control so field labeling stays uniform
/// across every sheet.
public struct SheetField<Content: View>: View {
    /// Resolved at init so the body never has to know which initializer it came through.
    var label: Text
    /// Whether the caption is the accessibility NAME of the content — see ``init(_:namesControl:content:)``.
    var namesControl: Bool
    var content: Content
    /// Scopes the caption↔control pairing to this row. One namespace per `SheetField` instance, so
    /// two fields in the same sheet can never pair across each other.
    @Namespace private var pairing

    /// The localizing initializer — the one all ~114 sheet call sites use.
    ///
    /// The literal is harvested into the calling target's string catalog and looked up in
    /// `Bundle.main`; that is the app bundle, and every entry sheet lives in the app target. A
    /// package caller must pre-resolve with `String(localized:bundle:.module)` and use
    /// ``init(verbatim:namesControl:content:)``, since a key harvested into a package bundle is
    /// invisible to `Bundle.main` and would render as untranslated English with no error anywhere.
    ///
    /// - Parameter namesControl: Opt in to making the caption the accessibility *name* of the
    ///   content (review T2-16). **Only pass `true` when the content is exactly ONE focusable
    ///   control** — a lone `TextField`, `Stepper`, `Picker`, `DatePicker` or `Toggle`. It is an
    ///   opt-in, never the default, because most `SheetField`s wrap a `FlowLayout` of chips or a
    ///   `ForEach`, and pairing there stamps the caption onto every chip in the row
    ///   (`WorkoutSetupView`'s Experience and Areas-to-work-around fields are the worked examples).
    ///   With it off the behaviour is exactly what it has always been: caption and content are
    ///   separate elements.
    public init(
        _ label: LocalizedStringKey,
        namesControl: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.label = Text(label)
        self.namesControl = namesControl
        self.content = content()
    }

    /// The non-localizing initializer, for a caption that is already final — a persisted grouping
    /// token used as a heading, a name the user typed, or a package caller's own resolved string.
    ///
    /// The `verbatim:` label is what keeps this from being chosen by accident; see
    /// ``SectionLabel/init(verbatim:)`` for why a same-label `String` overload would quietly
    /// capture every literal in the app.
    ///
    /// - Parameter namesControl: See ``init(_:namesControl:content:)`` — single control only.
    public init(
        verbatim label: String,
        namesControl: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.label = Text(verbatim: label)
        self.namesControl = namesControl
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if namesControl {
                // Both halves of the pair, or neither: VoiceOver reads the caption as the
                // control's name and Voice Control can say it, instead of the control announcing
                // as a bare "text field" with the caption stranded as a separate, untargetable
                // element. A lone `.content` half with no `.label` partner would be a change with
                // no benefit, which is why the opt-out branch attaches nothing at all.
                caption.accessibilityLabeledPair(role: .label, id: Self.pairID, in: pairing)
                content.accessibilityLabeledPair(role: .content, id: Self.pairID, in: pairing)
            } else {
                caption
                content
            }
        }
    }

    /// The uppercase slate caption, before either half of the pairing is attached.
    private var caption: some View {
        label
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
            .tracking(0.8)
            // Uppercasing moved off the string and into the environment so it runs *after* the
            // catalog lookup, on the translated caption rather than on the English key — the
            // only order that gets German ß → SS and accented French capitals right. See
            // ``SectionLabel`` for the same note; these two are the app's one caption treatment.
            .textCase(.uppercase)
    }

    /// The single pair id inside one row's namespace. A row has exactly one caption and (when
    /// opted in) one control, so the id never has to vary — the *namespace* is what separates rows.
    private static var pairID: Int { 0 }
}

/// A pill "chip" button style that inverts to a filled bark background when selected.
///
/// Applied to the tag/option chips inside entry sheets (often laid out with ``FlowLayout``). Pass
/// `selected:` so the style can render *and announce* the chosen state — the `.isSelected` trait is
/// added here, which is why VoiceOver can tell "Breakfast" from "Breakfast, selected" at every chip
/// site in the app. Unselected chips stay cream with a faint bark outline.
///
/// `destructive: true` renders the terracotta variant for a chip that destroys something (the
/// button's `role` alone is invisible to a custom style). It is a *selection* style: a real
/// call-to-action ("Ask to join", "End activity", "Delete all") belongs in
/// ``ActionPillButtonStyle``.
///
/// T1-9 (CHIP 44PT GROWTH, 2026-08-23): the drawn capsule cannot reach 44pt from inside
/// `makeBody` without a visible density change — 14pt label + 8pt vertical padding is a ~34pt
/// box — so the owner accepted growing the *layout* box to 44pt via `.frame(minHeight:)` while
/// leaving the capsule's drawn size alone. Call-site rows spread by roughly the same ~10pt this
/// costs; that spread is the accepted consequence, not a bug to chase.
public struct ChipButtonStyle: ButtonStyle {
    var selected: Bool
    var destructive: Bool

    public init(selected: Bool, destructive: Bool = false) {
        self.selected = selected
        self.destructive = destructive
    }

    public func makeBody(configuration: Configuration) -> some View {
        Chip(selected: selected, destructive: destructive, configuration: configuration)
    }

    /// Nested so the style can read `isEnabled` — a `ButtonStyle` itself has no environment, the
    /// same reason ``ActionPillButtonStyle``'s `Pill` is nested (`:912`). Carried finding NEW-1:
    /// the caveat-saved sheets freeze with `.disabled(...)` on their chip rows, and without this
    /// read every chip inside one kept rendering at full contrast — inert but indistinguishable
    /// from a live one.
    private struct Chip: View {
        let selected: Bool
        let destructive: Bool
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        /// §4.2: a `ButtonStyle` cannot read the environment, which is exactly why this nested view
        /// exists — so the Increase Contrast branch lands here rather than needing a new type. An
        /// unselected chip's 0.12 bark edge measures 1.19:1, so a low-vision user sees a floating
        /// word with no button boundary at all until this raises it.
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            let ink: Color = destructive ? .terracottaInk : (selected ? .parchment : .bark)
            let fill: Color = destructive
                ? Color.terracotta.opacity(0.10)
                : (selected ? Color.bark : Color.cream)
            let stroke: Color = destructive
                ? Color.terracottaEdge(contrast, normal: 0.35)
                : (selected ? Color.clear : Color.barkEdge(contrast, normal: 0.12))
            return configuration.label
                .font(.fernlet(.label))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(ink)
                .background(fill, in: shape)
                .overlay(shape.stroke(stroke, lineWidth: 1))
                // T1-9: the frame grows the tappable LAYOUT box to 44pt high in this view's own
                // coordinate space; the capsule above stays its drawn ~34pt size, centered inside
                // it. `contentShape` is a plain `Rectangle` sized to that grown frame (not `shape`,
                // which would leave the invisible margin untappable). This style guarantees height,
                // not width; an ancestor transform can also change the window-space measurement.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1.0) : 0.4)
                .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// Which role an ``ActionPillButtonStyle`` plays — it picks the fill/ink pair, not the size.
public enum FernletActionPillKind {
    /// The screen's affirmative action: filled ``Color/mossFill`` with ``Color/onMoss`` ink.
    case primary
    /// A secondary action beside a primary one: cream with a bark hairline.
    case secondary
    /// Deletes or ends something: the 2026-08-21 destructive token — ``Color/terracottaInk`` ink on
    /// a 10% terracotta fill with a 35% edge (artboard 2b), NOT solid terracotta. Solid terracotta
    /// is reserved for the confirm button inside a confirmation alert, the one place the keep-it
    /// button is guaranteed to render beside it. Always pair with a confirmation — see
    /// ``SwiftUI/View/confirmDestructive(_:isPresented:message:confirmLabel:cancelLabel:onConfirm:)``.
    case destructive
}

/// The style for a real call-to-action button: a 44pt-tall pill in one of three roles.
///
/// ```swift
/// Button("Ask to join") { … }.buttonStyle(ActionPillButtonStyle(.primary))
/// ```
///
/// Use it wherever a tap *does* something (join, connect, end, leave, delete) rather than selecting
/// an option — those stay ``ChipButtonStyle``. The distinction is the point: a chip's drawn
/// capsule is ~34pt tall (its hit target is separately grown to 44pt, see ``ChipButtonStyle``'s
/// T1-9 note), which is why the Friends/Activities primary actions were migrated from compact chips
/// to full-height action pills. The label wraps rather than truncating, and the pill grows to fit at
/// accessibility sizes.
///
/// Disabled state fades the *fill* only and switches to a legible ink (bark on primary, taupe on
/// the destructive tint): fading white ink along with the fill is what made the disabled Save pill
/// unreadable (1.8:1), and a user who can't read a disabled button can't tell what completing the
/// form would do. Disabled destructive stays an opacity drop, never a red error (artboard 2b).
public struct ActionPillButtonStyle: ButtonStyle {
    var kind: FernletActionPillKind

    public init(_ kind: FernletActionPillKind = .primary) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        Pill(kind: kind, configuration: configuration)
    }

    /// Nested so the style can read `isEnabled` — a `ButtonStyle` itself has no environment.
    private struct Pill: View {
        let kind: FernletActionPillKind
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        /// §4.2, same reason as ``ChipButtonStyle``'s `Chip`: the style itself has no environment.
        /// A `.secondary` pill's only boundary is a 0.14 bark hairline at 1.23:1.
        @Environment(\.colorSchemeContrast) private var contrast

        private var fill: Color {
            switch kind {
            case .primary:     return Color.mossFill.opacity(isEnabled ? 1 : 0.55)
            case .secondary:   return Color.cream
            // 2026-08-21 destructive token: tinted card, never solid — disabled drops the
            // fill to 6%, an opacity change rather than a color change (artboard 2b).
            case .destructive: return Color.terracotta.opacity(isEnabled ? 0.10 : 0.06)
            }
        }

        private var ink: Color {
            switch kind {
            case .primary:     return isEnabled ? .onMoss : .bark
            case .secondary:   return .bark
            case .destructive: return isEnabled ? .terracottaInk : .softTaupe
            }
        }

        private var stroke: Color {
            switch kind {
            // The primary pill needs no edge: `mossFill` is 4.67:1 against parchment already, and
            // 7.22:1 under Increase Contrast — the fill IS the boundary.
            case .primary:     return .clear
            case .secondary:   return Color.barkEdge(contrast, normal: 0.14)
            case .destructive: return Color.terracottaEdge(contrast, normal: isEnabled ? 0.35 : 0.18)
            }
        }

        var body: some View {
            let shape = Capsule(style: .continuous)
            return configuration.label
                .font(.fernlet(.label))
                .multilineTextAlignment(.center)
                .foregroundStyle(ink)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minHeight: 44)
                .background(fill, in: shape)
                .overlay(shape.stroke(stroke, lineWidth: 1))
                .contentShape(shape)
                .opacity(configuration.isPressed ? 0.78 : 1.0)
        }
    }
}

/// A multi-line text editor on a cream card with a perfectly aligned placeholder.
///
/// Used for free-text fields in entry sheets (journal notes, worry box, recipe notes). The
/// external padding deliberately compensates for `TextEditor`'s intrinsic UITextView insets so the
/// cursor lands exactly where the placeholder text sits (see the inline note on `body`).
public struct SheetTextEditor: View {
    @Binding var text: String
    /// Resolved at init so the body never has to know which initializer it came through — the same
    /// shape as ``SheetField``/``SectionLabel``.
    var placeholder: Text
    var minHeight: CGFloat

    /// The localizing initializer. The literal is harvested into the calling target's string
    /// catalog and looked up in `Bundle.main` — correct for the app-target sheets that own every
    /// call site. A package caller resolves with `String(localized:bundle:.module)` and uses
    /// ``init(text:verbatimPlaceholder:minHeight:)``.
    ///
    /// The `String` parameter this replaced never localized at all: an unwrapped `String` binds
    /// `Text.init(_: some StringProtocol)`, the *verbatim* overload, so every placeholder in the
    /// app was frozen English and none of them were even harvested (review T2-1).
    public init(text: Binding<String>, placeholder: LocalizedStringKey, minHeight: CGFloat = 120) {
        self._text = text
        self.placeholder = Text(placeholder)
        self.minHeight = minHeight
    }

    /// The non-localizing initializer, for a placeholder that is already final.
    public init(text: Binding<String>, verbatimPlaceholder: String, minHeight: CGFloat = 120) {
        self._text = text
        self.placeholder = Text(verbatim: verbatimPlaceholder)
        self.minHeight = minHeight
    }

    // TextEditor (UITextView) has intrinsic insets: 5pt horizontal (lineFragmentPadding)
    // and 8pt top (textContainerInset). External padding of (9h, 6v) makes the text
    // land at 9+5=14pt horizontal and 6+8=14pt vertical — matching .padding(14) on
    // the placeholder so cursor and placeholder text are perfectly aligned.
    public var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                placeholder
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate.opacity(0.45))
                    .padding(14)
                    .allowsHitTesting(false)
                    // The drawn placeholder is not the control's name — it vanishes the moment
                    // anything is typed. It is hidden here and re-attached to the editor below, so
                    // the field keeps a name for its whole life instead of only while empty.
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .textContentType(.none)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                // T2-16: a `TextEditor` announces as an unnamed text field. Naming it from the
                // placeholder is the only copy this component has, and it is the same words a
                // sighted user reads before typing.
                .accessibilityLabel(placeholder)
        }
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}

/// A short free-text field on the same cream card as ``SheetTextEditor``, that grows with the text
/// and whose Return key **submits** instead of inserting a newline.
///
/// The right control for a one-or-two-line entry (a meal description, a title): a `TextEditor` there
/// turns the natural "type, Return" rhythm into a stray line break and forces a reach for the Save
/// pill. Reach for ``SheetTextEditor`` when the field is genuinely a paragraph (journal, notes),
/// where Return should make a new line.
///
/// ```swift
/// SheetGrowingTextField(text: $description, placeholder: "2 eggs and toast") {
///     if canSave { save() }
/// }
/// ```
public struct SheetGrowingTextField: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey
    var lineLimit: ClosedRange<Int>
    var submitLabel: SubmitLabel
    var onSubmit: (() -> Void)?

    /// - Parameters:
    ///   - placeholder: Harvested into the *calling* target's catalog and looked up in
    ///     `Bundle.main`, which is correct for the app-target sheets that own every call site. It
    ///     was a plain `String` until review T2-1: `TextField(_ title: some StringProtocol, …)` is
    ///     the verbatim overload, so no placeholder in the app was ever localized *or* harvested.
    ///   - lineLimit: How far the field may grow before it scrolls; 1…4 by default.
    ///   - onSubmit: Runs when Return is pressed. Guard it with the sheet's own validity check —
    ///     Return must never save a form the Save pill would refuse.
    public init(
        text: Binding<String>,
        placeholder: LocalizedStringKey,
        lineLimit: ClosedRange<Int> = 1...4,
        submitLabel: SubmitLabel = .done,
        onSubmit: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.lineLimit = lineLimit
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
    }

    public var body: some View {
        // `TextField(_ titleKey:…)` uses the title as BOTH the drawn placeholder and the
        // accessibility label, so this control names itself; only ``SheetTextEditor`` (whose
        // `TextEditor` takes no title at all) needs the label attached by hand.
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(lineLimit)
            .submitLabel(submitLabel)
            .onSubmit { onSubmit?() }
            .sheetTextInput()
    }
}

/// A horizontal section switcher: a row of pill buttons where the selected section is highlighted
/// on a cream capsule.
///
/// Generic over any `Hashable` section type; hub-style screens use it to flip between sub-pages
/// (with a spring animation on selection change) without the visual weight of a system segmented
/// control.
///
/// The row scrolls horizontally rather than compressing: as a fixed `HStack` it wrapped labels
/// mid-word at accessibility sizes ("Journ/al", "Worry/Box"). Each pill keeps its label on one line,
/// carries the `.isSelected` trait so VoiceOver announces which section is showing, and takes a 44pt
/// tap target (the visible capsule stays its original height — the extra target is transparent).
/// Selection motion is skipped under Reduce Motion.
public struct HubSectionPicker<Section: Hashable>: View {
    var sections: [Section]
    @Binding var selection: Section
    var label: (Section) -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(sections: [Section], selection: Binding<Section>, label: @escaping (Section) -> String) {
        self.sections = sections
        self._selection = selection
        self.label = label
    }

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8)
    }

    public var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(sections.indices, id: \.self) { index in
                    let section = sections[index]
                    let isSelected = selection == section
                    Button {
                        withAnimation(selectionAnimation) {
                            selection = section
                        }
                    } label: {
                        Text(label(section))
                            .font(.fernlet(.label))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(isSelected ? Color.bark : Color.slate)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? Color.cream : Color.clear,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                            )
                            .animation(selectionAnimation, value: isSelected)
                            // Transparent margin that lifts the tap target to 44pt without
                            // fattening the capsule the user sees.
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.parchment)
    }
}

public extension View {
    func fernletTabBarCompaction(_ isCompact: Binding<Bool>, resetToken: Binding<Int>) -> some View {
        modifier(FernletTabBarCompactionModifier(isCompact: isCompact, resetToken: resetToken))
    }

    /// Ends a tab page's scroll content clear of the floating tab bar.
    ///
    /// Apply to the page's root scroll **content** (the outer stack inside the `ScrollView`), after
    /// its own padding. The floating bar rides a `safeAreaInset` applied OUTSIDE the tab container,
    /// which positions the bar correctly but never reaches the pages' scroll views as a content
    /// inset — so without this, every tab's scroll range ends at the physical screen bottom and the
    /// last card sits permanently behind the bar (the "can't scroll all the way down" defect).
    /// Padding the *content* — rather than insetting the scroll view — keeps the floating-bar look:
    /// content still paints beneath the bar mid-scroll, and only the resting end clears it.
    func fernletTabBarBottomClearance() -> some View {
        modifier(FernletTabBarBottomClearanceModifier())
    }
}

/// Keeps the scroll-content reservation for the floating tab bar stable while the bar animates.
///
/// A compact/expand transition reports every intermediate height through SwiftUI's geometry
/// callback. Publishing those intermediate values as bottom padding makes every tab relayout while
/// the bar is moving, which reads as navigation jitter. The first expanded measurement is the
/// largest one; retaining that maximum keeps the last card clear in both modes without feeding the
/// animation back into the scroll views. The caller independently publishes zero while the camera
/// hides the bar, so a temporary zero must not erase the cached reservation.
public enum FernletTabBarClearance {
    /// Returns the largest valid bar height observed in this view lifetime.
    ///
    /// Geometry is framework-produced rather than user input, but rejecting non-finite values keeps
    /// a malformed measurement from becoming padding on every tab page for the rest of the session.
    public static func stableHeight(current: CGFloat, measured: CGFloat) -> CGFloat {
        guard measured.isFinite, measured >= 0 else { return validHeight(current) }
        guard current.isFinite, current >= 0 else { return measured }
        return max(current, measured)
    }

    private static func validHeight(_ height: CGFloat) -> CGFloat {
        height.isFinite && height >= 0 ? height : 0
    }
}

/// Publishes the floating tab bar's stable on-screen height (its whole `safeAreaInset` block)
/// from the tab container down to the pages. Zero when no bar is showing (the camera session).
private struct FernletTabBarClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    /// The floating tab bar's stable height plus breathing room, set by the tab container and
    /// consumed by ``SwiftUI/View/fernletTabBarBottomClearance()`` on each page's scroll content.
    var fernletTabBarClearance: CGFloat {
        get { self[FernletTabBarClearanceKey.self] }
        set { self[FernletTabBarClearanceKey.self] = newValue }
    }
}

/// Implements ``SwiftUI/View/fernletTabBarBottomClearance()`` — see there. A separate modifier so
/// the environment read lives here rather than in every page.
public struct FernletTabBarBottomClearanceModifier: ViewModifier {
    @Environment(\.fernletTabBarClearance) private var clearance

    public init() {}

    public func body(content: Content) -> some View {
        content.padding(.bottom, clearance)
    }
}

/// Drives the app's compacting tab bar from a page's scroll position, with hysteresis so the bar
/// never oscillates.
///
/// Installed on each scrollable tab page via `fernletTabBarCompaction(_:resetToken:)`; the tab
/// container (the app's `ContentView`) owns the shared `isCompact` state and a per-tab
/// `resetToken`. The modifier observes scroll geometry and flips `isCompact` per the
/// ``shouldCompact(isCompact:distanceScrolledPastTop:)`` dead band: compaction begins only after
/// 48pt of real downward travel and releases only once settled back under 8pt.
///
/// - Important: Measuring `contentOffset.y - contentInsets.top` — not `containerSize` — is
///   load-bearing: the compacting bar animates the bottom safe-area inset, so any inset-dependent
///   metric would feed the animation back into its own trigger (and re-fire neighbor pages).
///   Incrementing `resetToken` scrolls the page back to the top and expands the bar; the page also
///   expands the bar on disappear so the next page starts expanded.
public struct FernletTabBarCompactionModifier: ViewModifier {
    /// Whether the tab bar is currently compacted; owned by the tab container and shared across pages.
    @Binding var isCompact: Bool
    /// Incremented by the tab container to scroll this page to the top and re-expand the bar.
    @Binding var resetToken: Int
    @State private var scrollPosition = ScrollPosition(edge: .top)

    public init(isCompact: Binding<Bool>, resetToken: Binding<Int>) {
        self._isCompact = isCompact
        self._resetToken = resetToken
    }

    public func body(content: Content) -> some View {
        content
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                // Signed distance scrolled past the top edge. Unlike `containerSize`, this is
                // invariant to the animated BOTTOM safe-area inset that the compacting tab bar
                // itself contributes — which is what breaks the compact⇄expand feedback loop
                // (and stops neighbor pages from re-firing when an inset animation runs).
                geometry.contentOffset.y - geometry.contentInsets.top
            } action: { _, distanceScrolledPastTop in
                let shouldCompact = Self.shouldCompact(
                    isCompact: isCompact,
                    distanceScrolledPastTop: distanceScrolledPastTop
                )
                guard isCompact != shouldCompact else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    isCompact = shouldCompact
                }
            }
            .onChange(of: resetToken) { _, _ in
                scrollPosition.scrollTo(edge: .top)
                isCompact = false
            }
            .onDisappear {
                isCompact = false
            }
    }

    /// Pure compaction decision with hysteresis, extracted for testability.
    ///
    /// `distanceScrolledPastTop` is `contentOffset.y - contentInsets.top`. Enter compaction only
    /// after 48pt of real downward travel; leave only once settled back under 8pt. The 8…48 dead
    /// band means a value dwelling anywhere in the old oscillation range cannot flip states, and
    /// requiring 48pt of travel means an unscrollable screen can never trigger compaction.
    public static func shouldCompact(isCompact: Bool, distanceScrolledPastTop: CGFloat) -> Bool {
        isCompact ? (distanceScrolledPastTop > 8) : (distanceScrolledPastTop > 48)
    }
}

/// The trailing moss "Save" pill pinned at the bottom of entry sheets.
///
/// Rendered on a parchment strip so it reads as a fixed footer beneath the sheet's scrolling
/// content; `disabled` fades the fill and blocks the action while the form is incomplete.
///
/// Draws ``Color/onMoss`` on ``Color/mossFill`` rather than white on `moss`: white on the old fill
/// measured 4.29:1 in light mode and 2.53:1 in dark, so the primary button of every entry sheet was
/// the least legible text on it. The disabled state fades only the fill and switches to bark ink —
/// a disabled Save the user cannot read tells them nothing about what finishing the form will do.
public struct SheetSaveBar: View {
    /// Resolved at init so the body does not branch on how the caller supplied the word.
    var label: Text
    var disabled: Bool
    var action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The localizing initializer. A literal at the call site is harvested into the calling target's
    /// string catalog and looked up in `Bundle.main` — the app bundle, where all ~41 call sites are.
    ///
    /// Omitting `label:` falls back to ``FernletUICopy/save``, this module's own catalog entry.
    /// The default is `nil` rather than the word itself because a `LocalizedStringKey` default
    /// written here would be a literal *inside the package*, harvested into FernletUI's bundle and
    /// then looked up in `Bundle.main`, which never consults it — the §4.0 trap. The old default
    /// translated only because several sheets happened to pass `label: "Save"` explicitly and so
    /// harvested the same key into the app's catalog; that coincidence is now unnecessary.
    public init(label: LocalizedStringKey? = nil, disabled: Bool = false, action: @escaping () -> Void) {
        self.label = label.map { Text($0) } ?? Text(verbatim: FernletUICopy.save)
        self.disabled = disabled
        self.action = action
    }

    /// The non-localizing initializer, for a save word that is already final — one a package caller
    /// resolved with `String(localized:bundle:.module)`, or one chosen at runtime from a domain
    /// type's display property.
    ///
    /// As everywhere else in this file, the distinct `verbatim:` label is the safeguard: a
    /// same-label `String` overload would win overload resolution for every plain literal and turn
    /// the whole component back into untranslatable English without a single warning.
    public init(verbatim label: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.label = Text(verbatim: label)
        self.disabled = disabled
        self.action = action
    }

    public var body: some View {
        // 2a·AX3: the commit stays bottom-right until its label would wrap, then goes full
        // width — at accessibility sizes the grown label wins the whole strip.
        let fullWidth = dynamicTypeSize.isAccessibilitySize
        return HStack {
            if !fullWidth { Spacer() }
            Button(action: action) { label }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .multilineTextAlignment(.center)
                .foregroundStyle(disabled ? Color.bark : Color.onMoss)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 52)
                .background(
                    Color.mossFill.opacity(disabled ? 0.55 : 1),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                // The pill is 52pt tall and draws as one target, but `.buttonStyle(.plain)` leaves
                // the hit region on the LABEL — so the commit button every sheet in the app ends
                // with was reporting a sub-44pt target while looking twice that size. Handing the
                // drawn shape back fixes it everywhere at once: this is the single component behind
                // the `Hit area is too small — “Save”` / `“Continue”` entries that were frozen on
                // eight screens in `UXScreenProbe.auditBaselines`. Purely a hit-testing change —
                // `contentShape` does not affect how anything draws.
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .disabled(disabled)
        }
        .padding(20)
        .background(Color.parchment)
        // The template's hairline above the commit bar (2026-08-21, artboard 2a): the bar reads
        // as a fixed footer beneath the one scroll surface rather than part of it.
        .overlay(alignment: .top) {
            Rectangle().fill(Color.bark.opacity(0.08)).frame(height: 1)
        }
    }
}

// MARK: - Searching pulse

/// A soft, tinted pulsing icon for "searching for nearby peers" states — a calmer, on-brand
/// stand-in for the system `ProgressView`.
///
/// Two expanding rings behind a filled disc with an icon. Ported from the shop's private
/// `SearchingPulse`; parameterized (tint / size / icon) so the friend-shop, connect, and
/// recipe-share surfaces can share one component. Hidden from accessibility — it is purely
/// decorative.
public struct SearchingPulse: View {
    var tint: Color
    /// Outer frame edge; the ring and inner disc scale from it (defaults reproduce the shop's 80pt look).
    var size: CGFloat
    var systemImage: String
    @State private var animate = false
    /// Under Reduce Motion the rings hold still — a forever-repeating expansion is exactly the kind of
    /// continuous motion the setting exists to stop.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tint: Color = .moss, size: CGFloat = 80, systemImage: String = "bag") {
        self.tint = tint
        self.size = size
        self.systemImage = systemImage
    }

    public var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(tint.opacity(0.4), lineWidth: 2)
                    .frame(width: size, height: size)
                    .scaleEffect(animate ? 1.8 : 0.8)
                    .opacity(animate ? 0 : 0.5)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 1.2),
                        value: animate
                    )
            }
            Circle()
                .fill(tint.opacity(0.14))
                .frame(width: size * 0.55, height: size * 0.55)
                .overlay(
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.25))
                        .foregroundStyle(tint)
                )
        }
        .frame(width: size, height: size)
        .onAppear { animate = !reduceMotion }
        .accessibilityHidden(true)
    }
}

// MARK: - Pressed-metal keepsake medallion

/// A circular "pressed metal" keepsake medallion with a radial-gradient face and struck-coin
/// highlight/shadow rings.
///
/// Purely decorative — reads as a memento, not a currency token (that is ``CoinGlyph``). Shared by
/// the Milestones keepsake shelf and the Home milestones doorway card; every ring, blur, and icon
/// size scales from `diameter` so the same component works at shelf and card sizes.
public struct PressedMedallion: View {
    let icon: String
    let tint: Color
    var diameter: CGFloat

    public init(icon: String, tint: Color, diameter: CGFloat = 88) {
        self.icon = icon
        self.tint = tint
        self.diameter = diameter
    }

    public var body: some View {
        ZStack {
            // Metal face: light catch top-left, deepening to a darker rim.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.55), tint.opacity(0.85), tint],
                        center: UnitPoint(x: 0.38, y: 0.32),
                        startRadius: 2,
                        endRadius: diameter * 0.72
                    )
                )
            // Top highlight — the "pressed" catch of light.
            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: diameter * 0.045)
                .blur(radius: diameter * 0.03)
                .mask(
                    Circle().fill(
                        LinearGradient(
                            colors: [.white, .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                )
            // Bottom inset shadow — the struck-coin depth.
            Circle()
                .stroke(Color.black.opacity(0.22), lineWidth: diameter * 0.06)
                .blur(radius: diameter * 0.04)
                .mask(
                    Circle().fill(
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    )
                )
            // Thin inner ring.
            Circle()
                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1.5)
                .padding(diameter * 0.09)
            // Engraved icon.
            Image(systemName: icon)
                .font(.system(size: diameter * 0.38, weight: .regular))
                .foregroundStyle(Color.bark.opacity(0.72))
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: tint.opacity(0.32), radius: 9, x: 0, y: 7)
    }
}

// MARK: - Coin glyph

private extension Color {
    // Coin highlight (the light catch on the pressed-gold coin).
    static let coinHighlight = Color(
        light: Color(red: 0.965, green: 0.839, blue: 0.537),
        dark:  Color(red: 0.965, green: 0.839, blue: 0.537)
    )
}

/// The small pressed-gold coin glyph used wherever the coin currency appears.
///
/// A radial gold gradient with a soft inner highlight; the "coin" mark is a gentle leaf. The
/// `muted` variant renders the not-yet-earned state. Border and shadow scale with `diameter` so
/// the tiny 11–14pt shop coins don't carry a proportionally heavy outline (see the inline note).
/// Used by the coins-summary cards, the shop, and ``CoinBalancePill``.
public struct CoinGlyph: View {
    var diameter: CGFloat
    var muted: Bool

    public init(diameter: CGFloat = 46, muted: Bool = false) {
        self.diameter = diameter
        self.muted = muted
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: muted
                            ? [Color.coinHighlight.opacity(0.7), Color.goldenrod.opacity(0.6), Color.goldenrod.opacity(0.7)]
                            : [Color.coinHighlight, Color.sun, Color.goldenrod],
                        center: UnitPoint(x: 0.38, y: 0.32),
                        startRadius: 1,
                        endRadius: diameter * 0.7
                    )
                )
                .overlay(
                    // Border and shadow scale with diameter (1pt / r5 / y3 at the 46pt reference)
                    // so the tiny 11-14pt shop coins don't carry a proportionally heavy outline/halo.
                    Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: max(0.5, diameter / 46))
                )
                .shadow(
                    color: Color.goldenrod.opacity(muted ? 0.2 : 0.4),
                    radius: diameter * (5 / 46), x: 0, y: diameter * (3 / 46)
                )
            Image(systemName: "leaf.fill")
                .font(.system(size: diameter * 0.4, weight: .semibold))
                .foregroundStyle(Color.bark.opacity(muted ? 0.4 : 0.55))
        }
        .frame(width: diameter, height: diameter)
        .opacity(muted ? 0.85 : 1)
    }
}

/// Coin wallet — a compact cream pill carrying the live spendable coin balance.
///
/// Echoes the shop's coin chips (via a small ``CoinGlyph``) so every coin surface reads in one
/// currency, and animates balance changes with a numeric content transition. Shared by the friend
/// shop's toolbar and the Wardrobe header (the always-reachable balance surface now that the shop
/// is a post-session window).
public struct CoinBalancePill: View {
    var balance: Int

    public init(balance: Int) {
        self.balance = balance
    }

    public var body: some View {
        HStack(spacing: 6) {
            CoinGlyph(diameter: 14)
            // `verbatim:` with a locale-formatted number: the pill draws a bare numeral, so there
            // is no sentence to translate — but there IS a grouping separator and a numeral system
            // to get right, which `Text("\(balance)")` (a "%lld" catalog key) would not.
            Text(verbatim: balance.formatted(.number))
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous).fill(Color.cream)
        )
        .overlay(Capsule(style: .continuous).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        .fernletSmallShadow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: FernletUICopy.coinBalance(balance)))
    }
}
