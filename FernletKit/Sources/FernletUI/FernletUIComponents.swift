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
}

/// The standard screen title block: a display-serif title with an italic slate subtitle.
///
/// Used at the top of the major tab screens and hub pages so page headers share one type
/// treatment. `subtitleFirst` places the subtitle above the title (the "eyebrow" layout); the
/// optional `identifier` gives UX appearance tests a stable anchor for the whole header.
public struct ScreenHeader: View {
    var title: String
    var subtitle: String
    var subtitleFirst: Bool
    /// Optional stable accessibility identifier so UX appearance tests can anchor a
    /// screen's header (e.g. "screen.home"). Empty when unset — a no-op for users.
    var identifier: String?

    public init(title: String, subtitle: String, subtitleFirst: Bool = false, identifier: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleFirst = subtitleFirst
        self.identifier = identifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if subtitleFirst { subtitleView }
            Text(title)
                .font(.fernlet(.display))
                .foregroundStyle(Color.bark)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            if !subtitleFirst { subtitleView }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier ?? "")
    }

    private var subtitleView: some View {
        Text(subtitle)
            .font(.fernlet(.bodySmall))
            .italic()
            .foregroundStyle(Color.slate)
            .lineLimit(2)
            .minimumScaleFactor(0.82)
    }
}

/// A rounded cream pill button for a screen header's trailing action — icon, text, or both.
///
/// Sits alongside ``ScreenHeader`` on tab screens for actions like opening settings or starting an
/// entry flow. At least one of `title` / `systemImage` must be provided (asserted in the
/// initializer); the 58pt minimum height keeps it comfortably tappable.
public struct HeaderActionButton: View {
    var title: String?
    var systemImage: String?
    var action: () -> Void

    public init(title: String? = nil, systemImage: String? = nil, action: @escaping () -> Void) {
        assert(title != nil || systemImage != nil, "header action needs title or image")
        self.title = title
        self.systemImage = systemImage
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
                    Text(title)
                        .font(.fernlet(.label))
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
        .accessibilityLabel(title ?? systemImage ?? "Action")
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
                .foregroundStyle(Color.slate.opacity(0.58))
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

    func sheetTextInput() -> some View {
        self
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
    /// dirty (dismiss directly when clean). Keeps the wording consistent across every workout/food sheet.
    func discardConfirmation(isPresented: Binding<Bool>, onDiscard: @escaping () -> Void) -> some View {
        self.confirmationDialog("Discard your changes?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Discard", role: .destructive, action: onDiscard)
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Anything you've typed here won't be saved.")
        }
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

/// A labeled form row for entry sheets: an uppercase small-label caption above arbitrary content.
///
/// The standard building block of the food/workout/journal entry sheets — it pairs a
/// design-system `labelSmall` caption with any input control so field labeling stays uniform
/// across every sheet.
public struct SheetField<Content: View>: View {
    var label: String
    var content: Content

    public init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .tracking(0.8)
            content
        }
    }
}

/// A pill "chip" button style that inverts to a filled bark background when selected.
///
/// Applied to the tag/option chips inside entry sheets (often laid out with ``FlowLayout``). Pass
/// `selected:` so the style can render the chosen state; unselected chips stay cream with a faint
/// bark outline.
public struct ChipButtonStyle: ButtonStyle {
    var selected: Bool

    public init(selected: Bool) {
        self.selected = selected
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fernlet(.label))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Color.parchment : Color.bark)
            .background(
                selected ? Color.bark : Color.cream,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.bark.opacity(selected ? 0 : 0.12), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1.0)
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

/// A horizontal section switcher: a row of pill buttons where the selected section is highlighted
/// on a cream capsule.
///
/// Generic over any `Hashable` section type; hub-style screens use it to flip between sub-pages
/// (with a spring animation on selection change) without the visual weight of a system segmented
/// control.
public struct HubSectionPicker<Section: Hashable>: View {
    var sections: [Section]
    @Binding var selection: Section
    var label: (Section) -> String

    public init(sections: [Section], selection: Binding<Section>, label: @escaping (Section) -> String) {
        self.sections = sections
        self._selection = selection
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(sections.indices, id: \.self) { index in
                let section = sections[index]
                let isSelected = selection == section
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        selection = section
                    }
                } label: {
                    Text(label(section))
                        .font(.fernlet(.label))
                        .foregroundStyle(isSelected ? Color.bark : Color.slate)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            isSelected ? Color.cream : Color.clear,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isSelected)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.parchment)
    }
}

public extension View {
    func fernletTabBarCompaction(_ isCompact: Binding<Bool>, resetToken: Binding<Int>) -> some View {
        modifier(FernletTabBarCompactionModifier(isCompact: isCompact, resetToken: resetToken))
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
public struct SheetSaveBar: View {
    var label: String
    var disabled: Bool
    var action: () -> Void

    public init(label: String = "Save", disabled: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.disabled = disabled
        self.action = action
    }

    public var body: some View {
        HStack {
            Spacer()
            Button(label, action: action)
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(disabled ? Color.moss.opacity(0.4) : Color.moss, in: RoundedRectangle(cornerRadius: 16))
                .disabled(disabled)
        }
        .padding(20)
        .background(Color.parchment)
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
                        .easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 1.2),
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
        .onAppear { animate = true }
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
