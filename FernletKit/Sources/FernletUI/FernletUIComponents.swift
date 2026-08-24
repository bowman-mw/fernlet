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
    static let parchment = Color(UIColor { @Sendable trait in
        FernletThemePalette.current(for: trait.userInterfaceStyle).background
    })
    static let cream = Color(UIColor { @Sendable trait in
        FernletThemePalette.current(for: trait.userInterfaceStyle).box
    })
    static let bark = Color(UIColor { @Sendable trait in
        FernletThemePalette.current(for: trait.userInterfaceStyle).primaryText
    })
    static let slate = Color(UIColor { @Sendable trait in
        FernletThemePalette.current(for: trait.userInterfaceStyle).secondaryText
    })
    static let moss = Color(
        light: Color(red: 0.369, green: 0.518, blue: 0.302),
        dark:  Color(red: 0.498, green: 0.690, blue: 0.412)
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
    static let mossFill = Color(
        light: Color(red: 0.310, green: 0.455, blue: 0.267),
        dark:  Color(red: 0.498, green: 0.690, blue: 0.412)
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
}

public extension Color {
    /// Resolves to `light` in light mode, `dark` in dark mode.
    ///
    /// Both sides are bridged to `UIColor` up front rather than inside the provider: the provider runs on
    /// whatever thread resolves the trait collection, and the SwiftUI `UIColor(Color)` bridge is not safe to
    /// call there. Callers pass fixed literal colors, so resolving once is equivalent — and cheaper.
    init(light: Color, dark: Color) {
        let lightUI = UIColor(light)
        let darkUI = UIColor(dark)
        self.init(UIColor { @Sendable trait in
            trait.userInterfaceStyle == .dark ? darkUI : lightUI
        })
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
                    Label("Done", systemImage: "checkmark.circle.fill")
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
        self.alert("Discard your changes?", isPresented: isPresented) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard", role: .destructive, action: onDiscard)
        } message: {
            Text("Anything you've typed here won't be saved.")
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
    ///   - title: Phrase it as a question, e.g. "Delete 12 shared pictures?".
    ///   - message: Name the exact data affected and whether anything survives.
    ///   - confirmLabel: The destructive button, e.g. "Delete all 12".
    func confirmDestructive(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String,
        confirmLabel: String,
        cancelLabel: String = "Cancel",
        onConfirm: @escaping () -> Void
    ) -> some View {
        self.alert(title, isPresented: isPresented) {
            Button(cancelLabel, role: .cancel) {}
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
            Button("Cancel", action: action)
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
                .buttonStyle(.plain)
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
    var content: Content

    /// The localizing initializer — the one all ~114 sheet call sites use.
    ///
    /// The literal is harvested into the calling target's string catalog and looked up in
    /// `Bundle.main`; that is the app bundle, and every entry sheet lives in the app target. A
    /// package caller must pre-resolve with `String(localized:bundle:.module)` and use
    /// ``init(verbatim:content:)``, since a key harvested into a package bundle is invisible to
    /// `Bundle.main` and would render as untranslated English with no error anywhere.
    public init(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.label = Text(label)
        self.content = content()
    }

    /// The non-localizing initializer, for a caption that is already final — a persisted grouping
    /// token used as a heading, a name the user typed, or a package caller's own resolved string.
    ///
    /// The `verbatim:` label is what keeps this from being chosen by accident; see
    /// ``SectionLabel/init(verbatim:)`` for why a same-label `String` overload would quietly
    /// capture every literal in the app.
    public init(verbatim label: String, @ViewBuilder content: () -> Content) {
        self.label = Text(verbatim: label)
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .tracking(0.8)
                // Uppercasing moved off the string and into the environment so it runs *after* the
                // catalog lookup, on the translated caption rather than on the English key — the
                // only order that gets German ß → SS and accented French capitals right. See
                // ``SectionLabel`` for the same note; these two are the app's one caption treatment.
                .textCase(.uppercase)
            content
        }
    }
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
/// ``ActionPillButtonStyle``, which meets the 44pt target these 34pt chips do not.
public struct ChipButtonStyle: ButtonStyle {
    var selected: Bool
    var destructive: Bool

    public init(selected: Bool, destructive: Bool = false) {
        self.selected = selected
        self.destructive = destructive
    }

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let ink: Color = destructive ? .terracottaInk : (selected ? .parchment : .bark)
        let fill: Color = destructive
            ? Color.terracotta.opacity(0.10)
            : (selected ? Color.bark : Color.cream)
        let stroke: Color = destructive
            ? Color.terracottaInk.opacity(0.35)
            : Color.bark.opacity(selected ? 0 : 0.12)
        return configuration.label
            .font(.fernlet(.label))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(ink)
            .background(fill, in: shape)
            .overlay(shape.stroke(stroke, lineWidth: 1))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .accessibilityAddTraits(selected ? .isSelected : [])
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
/// an option — those stay ``ChipButtonStyle``. The distinction is the point: chips are 34pt tall,
/// which is under the 44pt minimum target, so the Friends/Activities surfaces that dressed their
/// primary actions as chips were shipping undersized buttons. The label wraps rather than
/// truncating, and the pill grows to fit at accessibility sizes.
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
            case .primary:     return .clear
            case .secondary:   return Color.bark.opacity(0.14)
            case .destructive: return Color.terracottaInk.opacity(isEnabled ? 0.35 : 0.18)
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
    var placeholder: String
    var minHeight: CGFloat

    public init(text: Binding<String>, placeholder: String, minHeight: CGFloat = 120) {
        self._text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
    }

    // TextEditor (UITextView) has intrinsic insets: 5pt horizontal (lineFragmentPadding)
    // and 8pt top (textContainerInset). External padding of (9h, 6v) makes the text
    // land at 9+5=14pt horizontal and 6+8=14pt vertical — matching .padding(14) on
    // the placeholder so cursor and placeholder text are perfectly aligned.
    public var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate.opacity(0.45))
                    .padding(14)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .textContentType(.none)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
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
    var placeholder: String
    var lineLimit: ClosedRange<Int>
    var submitLabel: SubmitLabel
    var onSubmit: (() -> Void)?

    /// - Parameters:
    ///   - lineLimit: How far the field may grow before it scrolls; 1…4 by default.
    ///   - onSubmit: Runs when Return is pressed. Guard it with the sheet's own validity check —
    ///     Return must never save a form the Save pill would refuse.
    public init(
        text: Binding<String>,
        placeholder: String,
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
    /// - Important: the `"Save"` default is a literal *inside this package*, so it is harvested into
    ///   FernletUI's bundle, not the app's — and `Bundle.main` never consults a package bundle. The
    ///   ~6 sheets that omit `label:` therefore translate only if the app's own catalog happens to
    ///   carry a `"Save"` entry. It does, because several sheets pass `label: "Save"` explicitly and
    ///   that harvests the key from the app target; the entry must not be pruned from
    ///   `App/Fernlet/Localizable.xcstrings` on the grounds that "nothing references it", because
    ///   this default silently does.
    public init(label: LocalizedStringKey = "Save", disabled: Bool = false, action: @escaping () -> Void) {
        self.label = Text(label)
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
            Text("\(balance)")
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
        .accessibilityLabel("\(balance) coins")
    }
}
