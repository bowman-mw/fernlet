//
//  SheetChrome.swift
//  FernletUI
//
//  The canonical three-slot sheet chrome and the destructive token from the 2026-08-21
//  redesign (design canvas artboards 2a/2b). One rule for every sheet: Cancel top-left
//  when a draft can be lost, Done top-right to dismiss or commit in place, Save
//  bottom-right (``SheetSaveBar``) only when a draft is being committed. The
//  bottom-right moss "Done" pill is retired everywhere.
//

import SwiftUI

/// The pinned header of every Fernlet sheet: an optional Cancel/Done control row above a
/// left-aligned serif title block (2026-08-21 template, artboard 2a).
///
/// Three slots, one rule, all sheets: **Cancel top-left** when a draft can be lost, **Done
/// top-right** to dismiss or commit in place, **Save bottom-right** (``SheetSaveBar``) only when
/// a draft is being committed. A read-only sheet passes `onDone` alone — Done is the whole exit.
/// A single-control adjustment sheet (Water) passes both — Done commits, Cancel reverts. A draft
/// sheet passes `onCancel` alone and keeps its ``SheetSaveBar`` (or adopts the header through
/// `fernletDraftGuard(isDirty:title:subtitle:onDismiss:)`, which wires Cancel to the discard
/// prompt).
///
/// The title is Fraunces SemiBold 28 (``FernletTextRole/displayMedium``) with an optional
/// one-line Instrument Serif italic subtitle — never two lines, and the first thing to go at
/// accessibility text sizes (the template's AX rule). The 36pt ``ScreenHeader`` treatment belongs
/// to tab roots and pushed pages only, never to a sheet.
///
/// Place it as the first child of the sheet's outer `VStack`, above the scroll surface: content
/// scrolls, the header does not. The `accessory` slot replaces Cancel in the leading position for
/// sheets that lead with information instead (the Customize sheet's coin balance) — a balance is
/// information, not an action, so it never takes the trailing slot that dismisses the sheet.
///
/// Localization: the localizing initializers harvest title/subtitle literals into the calling
/// target's string catalog (every sheet lives in the app target). The "Cancel"/"Done" control
/// labels are package literals resolved against `Bundle.main` — the app catalog carries both keys
/// (the ``SheetCancelBar`` / `keyboardDoneToolbar()` precedent; do not prune them). The
/// `sheet.cancel` / `sheet.done` accessibility identifiers are test tokens and stay English.
public struct SheetHeader<Accessory: View>: View {
    /// Resolved at init so the body never branches on which initializer built it.
    var title: Text
    var subtitle: Text?
    /// Reverts/dismisses without committing. Nil hides the leading Cancel slot.
    var onCancel: (() -> Void)?
    /// Dismisses a read-only sheet, or commits an in-place edit. Nil hides the trailing slot.
    var onDone: (() -> Void)?
    /// Fades and disables Done while a commit would be invalid — opacity, never a color change.
    var doneDisabled: Bool
    /// Leading informational content shown when there is no Cancel (e.g. a coin balance).
    var accessory: Accessory
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The full-slot initializer. Prefer the `Accessory == EmptyView` conveniences below unless
    /// the sheet genuinely leads with information.
    public init(
        title: Text,
        subtitle: Text? = nil,
        onCancel: (() -> Void)? = nil,
        onDone: (() -> Void)? = nil,
        doneDisabled: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onCancel = onCancel
        self.onDone = onDone
        self.doneDisabled = doneDisabled
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasControlRow { controlRow }
            title
                .font(.fernlet(.displayMedium))
                .foregroundStyle(Color.bark)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle, !dynamicTypeSize.isAccessibilitySize {
                subtitle
                    .font(.fernlet(.bodySmall))
                    .italic()
                    .foregroundStyle(Color.slate)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.parchment)
    }

    /// Whether anything occupies the control row — an empty row would just push the title down.
    private var hasControlRow: Bool {
        onCancel != nil || onDone != nil || Accessory.self != EmptyView.self
    }

    /// Cancel (or the accessory) leading, Done trailing; both controls hold a 44pt target while
    /// drawing at text size.
    private var controlRow: some View {
        HStack(alignment: .center, spacing: 12) {
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .font(.custom(FernletFontName.dmSansMedium, size: 16, relativeTo: .body))
                    .foregroundStyle(Color.slate)
                    .buttonStyle(.plain)
                    .fernletTapTarget()
                    .accessibilityIdentifier("sheet.cancel")
            } else {
                accessory
            }
            Spacer(minLength: 0)
            if let onDone {
                Button("Done", action: onDone)
                    .font(.custom(FernletFontName.dmSansMedium, size: 16, relativeTo: .body))
                    .foregroundStyle(Color.moss.opacity(doneDisabled ? 0.45 : 1))
                    .buttonStyle(.plain)
                    .disabled(doneDisabled)
                    .fernletTapTarget()
                    .accessibilityIdentifier("sheet.done")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

public extension SheetHeader where Accessory == EmptyView {
    /// The localizing initializer — the common case where both halves are authored copy.
    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        onCancel: (() -> Void)? = nil,
        onDone: (() -> Void)? = nil,
        doneDisabled: Bool = false
    ) {
        self.init(
            title: Text(title),
            subtitle: subtitle.map { Text($0) },
            onCancel: onCancel,
            onDone: onDone,
            doneDisabled: doneDisabled
        ) { EmptyView() }
    }

    /// The `Text`-taking initializer, for a title or subtitle that is runtime data (a recipe
    /// name) or package-resolved copy. `Text` is not expressible by a string literal, so this
    /// overload can never steal a call site that meant to localize.
    init(
        title: Text,
        subtitle: Text? = nil,
        onCancel: (() -> Void)? = nil,
        onDone: (() -> Void)? = nil,
        doneDisabled: Bool = false
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            onCancel: onCancel,
            onDone: onDone,
            doneDisabled: doneDisabled
        ) { EmptyView() }
    }
}

// MARK: - Destructive token (artboard 2b)

/// The one full-width destructive control style: terracotta ink and glyph on a terracotta-tinted
/// card (XCUT-21).
///
/// One style replaces five ad-hoc treatments. Terracotta, not system red, so it survives dark
/// mode; ``Color/terracottaInk`` on a 12% terracotta fill measures 6.0:1 in light mode. The
/// disabled state drops the fill to 6% and the ink to taupe — **opacity, never a red error**.
///
/// ```swift
/// Button { confirmDelete = true } label: {
///     Label("Delete recipe", systemImage: "trash")
/// }
/// .buttonStyle(DestructiveCardButtonStyle())
/// ```
///
/// Division of labor across the destructive vocabulary: chips that destroy (Block, End activity)
/// take ``ChipButtonStyle`` with `destructive: true`; full-width actions take this style; **solid
/// terracotta is reserved for the confirm button inside a confirmation alert** — the one place a
/// destructive action should be the loudest thing on screen, and the one place the keep-it button
/// is guaranteed to render beside it. Never present a solid-terracotta button outside an alert.
///
/// At accessibility sizes the glyph holds its size while the label grows and wraps, so a
/// destructive control is still identifiable when the text is too big to scan (2b·AX3).
public struct DestructiveCardButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Card(configuration: configuration)
    }

    /// Nested so the style can read `isEnabled` — a `ButtonStyle` itself has no environment.
    private struct Card: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            return configuration.label
                .labelStyle(FixedGlyphLabelStyle())
                .multilineTextAlignment(.center)
                .foregroundStyle(isEnabled ? Color.terracottaInk : Color.softTaupe)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.terracotta.opacity(isEnabled ? 0.12 : 0.06), in: shape)
                .contentShape(shape)
                .opacity(configuration.isPressed ? 0.78 : 1.0)
        }
    }
}

/// Keeps a destructive control's glyph at a fixed size while its title scales with Dynamic Type
/// (2b·AX3: "the glyph holds while the label grows").
///
/// Private to the token: ordinary labels should scale whole. The fixed 17pt semibold glyph
/// renders in a ~26pt box beside the design-system label face.
private struct FixedGlyphLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .font(.system(size: 17, weight: .semibold))
            configuration.title
                .font(.fernlet(.label))
        }
    }
}
