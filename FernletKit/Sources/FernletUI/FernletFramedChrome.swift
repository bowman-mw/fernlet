//
//  FernletFramedChrome.swift
//  FernletUI
//
//  The World build's chrome in the one design language (World Review Batches 1 and 3, approved
//  2026-10-23/24): pages on dotted parchment, sheets on paper with a wooden grabber, and focused flows
//  (the runner, cooking mode, breathing, the camera, onboarding) full screen with a ✕ top right.
//  Each piece reads `fernletFramedLook` and falls back to today's look when it is unset.
//

import SwiftUI

// MARK: - Icons

/// The one-colour icons the framed primitives draw (✕, the back arrow, chevrons, plus, check, search,
/// lock). The World build draws them as pixel art through the renderer it installs
/// (``EnvironmentValues/fernletIconRenderer``), so its sprites stay in one place and take the ink token
/// in dark mode; without a renderer each falls back to its SF Symbol.
nonisolated public enum FernletFramedIcon: Sendable, CaseIterable {
    case close, back, chevron, chevronDown, plus, check, search, lock

    /// The SF Symbol drawn when no renderer is installed.
    public var systemName: String {
        switch self {
        case .close: "xmark"
        case .back: "chevron.left"
        case .chevron: "chevron.right"
        case .chevronDown: "chevron.down"
        case .plus: "plus"
        case .check: "checkmark"
        case .search: "magnifyingglass"
        case .lock: "lock.fill"
        }
    }
}

/// Draws a ``FernletFramedIcon`` at a whole-number pixel scale, optionally in one tint (white on an
/// accent fill). The app installs one at its root; this module never draws the pixel art itself.
public struct FernletIconRenderer: Sendable {
    /// Draws `icon` at `scale` points per sprite pixel, in `tint` when one is given (else the icon's own
    /// ink, which follows dark mode).
    public let render: @MainActor @Sendable (FernletFramedIcon, CGFloat, Color?) -> AnyView

    public init(_ render: @escaping @MainActor @Sendable (FernletFramedIcon, CGFloat, Color?) -> AnyView) {
        self.render = render
    }
}

public extension EnvironmentValues {
    /// Draws the framed primitives' icons; nil falls back to SF Symbols.
    @Entry var fernletIconRenderer: FernletIconRenderer? = nil
    /// The title plate a pushed page hands its title and Back to (a World panel's plate); nil outside
    /// one. ``SwiftUI/View/fernletSheet()`` and ``FernletFocusedFlow`` clear it for what they present.
    @Entry var fernletPlateNavigation: FernletPlateNavigation? = nil
}

/// One framed icon, decorative to VoiceOver (its control carries the name). Pixel icons step up one
/// whole scale at accessibility text sizes, as the approved largest-text designs draw them.
public struct FernletIcon: View {
    let icon: FernletFramedIcon
    var scale: CGFloat
    var tint: Color?
    @Environment(\.fernletIconRenderer) private var renderer
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - scale: Points per sprite pixel at standard sizes (2 inside controls, 3 on the plate).
    ///   - tint: One colour for every pixel; nil keeps the icon's ink.
    public init(_ icon: FernletFramedIcon, scale: CGFloat = 2, tint: Color? = nil) {
        self.icon = icon
        self.scale = scale
        self.tint = tint
    }

    public var body: some View {
        let step = scale + (dynamicTypeSize.isAccessibilitySize ? 1 : 0)
        Group {
            if let renderer {
                renderer.render(icon, step, tint)
            } else {
                Image(systemName: icon.systemName)
                    .font(.system(size: 6 * step, weight: .bold))
                    .foregroundStyle(tint ?? look?.text ?? Color.bark)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Pages

/// A page in the one design language: parchment with a faint dot grid every 14 pt (`.pnl`, `.sbg3`,
/// `.focus3`). Plain parchment without the look.
public struct FernletDottedPage: View {
    @Environment(\.fernletFramedLook) private var look

    public init() {}

    public var body: some View {
        let page = look?.page ?? Color.parchment
        let dot = look?.pageDot ?? Color.clear
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(page))
            let step: CGFloat = 14
            var dots = Path()
            let columns = min(Int(size.width / step) + 1, 200), rows = min(Int(size.height / step) + 1, 200)
            for row in 0..<rows {
                for column in 0..<columns {
                    dots.addEllipse(in: CGRect(x: CGFloat(column) * step + 6, y: CGFloat(row) * step + 6, width: 2.4, height: 2.4))
                }
            }
            context.fill(dots, with: .color(dot))
        }
        .accessibilityHidden(true)
    }
}

public extension View {
    /// The page's background: dotted parchment edge to edge under the look, plain parchment without it.
    /// Use it in place of `.background(Color.parchment)` on a panel's page, so the dots show.
    func fernletPageBackground() -> some View {
        background { FernletDottedPage().ignoresSafeArea() }
    }
}

// MARK: - Sheets

/// The sheet's wooden grabber (`.sht3 .grab`): 54 × 10, wood in a 2-pt ink frame with a light top edge.
/// Decorative: the system grabber it replaces is hidden, and the sheet still drags and dismisses as
/// before (VoiceOver's escape and Cancel leave it).
public struct FernletSheetGrabber: View {
    @Environment(\.fernletFramedLook) private var look

    public init() {}

    public var body: some View {
        if let look {
            let shape = RoundedRectangle(cornerRadius: 4)
            shape.fill(look.wood)
                .overlay(alignment: .top) { look.woodHigh.frame(height: 2).padding(.top, 2) }
                .clipShape(shape)
                .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
                .frame(width: 54, height: 10)
                .accessibilityHidden(true)
        }
    }
}

/// A sheet's paper (`.sht3`): the look's paper, used as the presentation background under
/// ``FernletSheetPaper/cornerRadius``-pt corners. (Its 3-pt ink edge is drawn with the grabber by
/// ``SwiftUI/View/fernletSheet()``: a presentation background's top is not the sheet's visible top.)
public struct FernletSheetPaper: View {
    let look: FernletFramedLook

    /// The sheet's corner radius in the kit (`border-radius: 20px 20px 0 0`).
    public static let cornerRadius: CGFloat = 20

    public init(look: FernletFramedLook) {
        self.look = look
    }

    public var body: some View {
        look.paper.accessibilityHidden(true)
    }
}

/// The top of a framed sheet (`.sht3`): the 3-pt ink edge along the sheet's rounded top, and the wooden
/// grabber 9 pt below it. ``SwiftUI/View/fernletSheet()`` pins it above the sheet's content.
struct FernletSheetTopBand: View {
    let look: FernletFramedLook

    var body: some View {
        FernletSheetGrabber()
            .frame(maxWidth: .infinity)
            .padding(.top, 9)
            .padding(.bottom, 2)
            .background(look.paper)
            .overlay(alignment: .top) {
                // Stroked on the sheet's own outline, so half the 6-pt stroke falls outside the sheet's
                // clip and the 3-pt ink edge follows its corners exactly.
                SheetTopEdge(radius: FernletSheetPaper.cornerRadius)
                    .stroke(look.ink, lineWidth: 6)
                    .frame(height: FernletSheetPaper.cornerRadius + 4)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}

/// The top of a sheet's outline: down the left corner, across, and down the right corner.
nonisolated private struct SheetTopEdge: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                    startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        return path
    }
}

/// The presentation half of the sheet chrome: under the look, paper with the ink edge, 20-pt corners
/// and no system grabber (``FernletSheetGrabber`` replaces it). Without the look it leaves the
/// presentation alone, or shows the system grabber when `fallbackIndicator` asks for it.
struct FernletSheetPresentationChrome: ViewModifier {
    var fallbackIndicator: Visibility?
    @Environment(\.fernletFramedLook) private var look

    func body(content: Content) -> some View {
        if let look {
            content
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(FernletSheetPaper.cornerRadius)
                .presentationBackground { FernletSheetPaper(look: look) }
        } else if let fallbackIndicator {
            content.presentationDragIndicator(fallbackIndicator)
        } else {
            content
        }
    }
}

/// Implements ``SwiftUI/View/fernletSheet()``.
struct FernletSheetModifier: ViewModifier {
    @Environment(\.fernletFramedLook) private var look

    func body(content: Content) -> some View {
        // A stack, not a safe-area inset: a NavigationStack whose bar is hidden lays its pages out from
        // the top of its own frame and ignores an inset above it, so the band must sit above that frame.
        VStack(spacing: 0) {
            if let look { FernletSheetTopBand(look: look) }
            content
                // A sheet is its own surface: no panel plate above it, no plate title to defer to.
                .environment(\.fernletPlateNavigation, nil)
                .environment(\.fernletTitleOnPlate, false)
                .environment(\.fernletPageTitleOnPlate, false)
                // A presented sheet does not inherit the presenter's toggle and Form styles, so the
                // framed switch and Form are set again here (each falls back to today's look without one).
                .toggleStyle(FernletFramedToggleStyle())
                .formStyle(FernletFormStyle())
                .frame(maxHeight: .infinity)
        }
        .presentationDetents([.large])
        .modifier(FernletSheetPresentationChrome(fallbackIndicator: .visible))
    }
}

public extension View {
    /// The sheet frame (`b1-frame-sheet`, draft 3; every sheet full height per Batch 3). Apply once, at
    /// the root of a sheet's content, in place of its `presentationDetents` / `presentationDragIndicator`
    /// lines:
    ///
    /// ```swift
    /// .sheet(isPresented: $logging) { MealEntrySheet(…).fernletSheet() }
    /// ```
    ///
    /// Full height always. Under the look: paper with the 3-pt ink top edge, 20-pt corners, and the
    /// wooden grabber in place of the system one (``SheetHeader`` below it draws Cancel, the title and
    /// Done). Without it: full height with the system grabber, as most sheets drew it. It also clears the
    /// panel plate for everything inside, so a sheet's own pushed pages keep their own navigation bar.
    ///
    /// The presenter's own presentation modifiers win over anything inside the sheet, so a sheet still
    /// carrying `.presentationDragIndicator(.visible)` or a `.medium` detent keeps them: replace those
    /// lines with this one.
    func fernletSheet() -> some View {
        modifier(FernletSheetModifier())
    }

    /// The sheet frame for a sheet built on a `NavigationStack` (Cancel and Done toolbar items, a
    /// navigation title). Apply to the stack's ROOT page, in place of its `.navigationTitle` and its
    /// `cancellationAction` / `confirmationAction` items:
    ///
    /// ```swift
    /// NavigationStack { form.fernletSheetToolbar(title: "Plan goals", onCancel: cancel, onDone: save) }
    ///     .fernletSheet()
    /// ```
    ///
    /// Under the look the root page's bar is hidden and ``SheetHeader`` is pinned at the top instead
    /// (grabber, Cancel top left, the title inside the sheet, Done top right); pages pushed inside the
    /// sheet keep the system bar, whose Back names this title. Without the look it is today's bar: the
    /// inline title with Cancel and Done as toolbar items.
    func fernletSheetToolbar(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil,
                             onCancel: (() -> Void)? = nil, onDone: (() -> Void)? = nil,
                             doneDisabled: Bool = false) -> some View {
        modifier(FernletSheetToolbarModifier(title: Text(title), subtitle: subtitle.map { Text($0) },
                                             onCancel: onCancel, onDone: onDone, doneDisabled: doneDisabled))
    }

    /// ``fernletSheetToolbar(title:subtitle:onCancel:onDone:doneDisabled:)`` for a title that is runtime
    /// data (a recipe's name). `Text` is not a literal, so this never steals a localizing call site.
    func fernletSheetToolbar(title: Text, subtitle: Text? = nil, onCancel: (() -> Void)? = nil,
                             onDone: (() -> Void)? = nil, doneDisabled: Bool = false) -> some View {
        modifier(FernletSheetToolbarModifier(title: title, subtitle: subtitle, onCancel: onCancel,
                                             onDone: onDone, doneDisabled: doneDisabled))
    }
}

/// Implements ``SwiftUI/View/fernletSheetToolbar(title:subtitle:onCancel:onDone:doneDisabled:)``.
struct FernletSheetToolbarModifier: ViewModifier {
    let title: Text
    let subtitle: Text?
    let onCancel: (() -> Void)?
    let onDone: (() -> Void)?
    let doneDisabled: Bool
    @Environment(\.fernletFramedLook) private var look

    func body(content: Content) -> some View {
        if look != nil {
            content
                .navigationTitle(title)
                .toolbar(.hidden, for: .navigationBar)
                .environment(\.fernletPlateNavigation, nil)
                .safeAreaInset(edge: .top, spacing: 0) {
                    SheetHeader(title: title, subtitle: subtitle, onCancel: onCancel, onDone: onDone,
                                doneDisabled: doneDisabled)
                }
        } else {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarItems }
        }
    }

    /// Today's toolbar: Cancel and Done where iOS puts them.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if let onCancel {
            ToolbarItem(placement: .cancellationAction) {
                Button(FernletUICopy.cancel, action: onCancel).accessibilityIdentifier("sheet.cancel")
            }
        }
        if let onDone {
            ToolbarItem(placement: .confirmationAction) {
                Button(FernletUICopy.done, action: onDone)
                    .disabled(doneDisabled)
                    .accessibilityIdentifier("sheet.done")
            }
        }
    }
}

/// A sheet's footer with more than one button (`.sft`): the buttons right-aligned 10 pt apart on the
/// sheet's paper, stacked full width at accessibility sizes. A sheet whose footer is one Save keeps
/// ``SheetSaveBar``.
public struct FernletSheetFooter<Content: View>: View {
    let content: Content
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            if !stacked { Spacer(minLength: 0) }
            content
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(look?.paper ?? Color.parchment)
    }
}

// MARK: - Focused flows

/// The framed ✕ that leaves a focused flow (`.focus3 .ftop`): 44 pt, raised paper in a 2-pt ink
/// frame, named "Close" for VoiceOver and Voice Control. Escape on a hardware keyboard presses it.
public struct FernletCloseButton: View {
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            if let look {
                let shape = RoundedRectangle(cornerRadius: 9)
                FernletIcon(.close, scale: 2)
                    .frame(width: 44, height: 44)
                    .background(look.raised, in: shape)
                    .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
            } else {
                FernletIcon(.close).frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel(Text(verbatim: FernletUICopy.close))
        .accessibilityInputLabels([Text(verbatim: FernletUICopy.close)])
        .accessibilityIdentifier("focus.close")
    }
}

/// A focused flow (`.focus3`, World Review Batch 3): a full-screen cover (the guided runner, cooking
/// mode, breathing, the camera, onboarding) with no grabber, on dotted parchment, its title top left
/// and a ✕ top right, the content, then a bottom button row.
///
/// ```swift
/// .fullScreenCover(isPresented: $cooking) {
///     FernletFocusedFlow("Overnight oats", onClose: { cooking = false }) {
///         steps
///     } footer: {
///         Button("Log this meal") { … }.buttonStyle(ActionPillButtonStyle(.primary))
///     }
/// }
/// ```
///
/// The footer's buttons stack full width, 10 pt apart (`.fbot`); pass `closeLabel` for a flow that
/// closes with a word ("End") instead of the ✕. VoiceOver's escape closes it too.
public struct FernletFocusedFlow<Content: View, Footer: View>: View {
    var title: Text?
    var subtitle: Text?
    var closeLabel: Text?
    let onClose: () -> Void
    let content: Content
    let footer: Footer

    /// The full initializer, for a title that is runtime data or absent (the camera has none).
    public init(title: Text?, subtitle: Text? = nil, closeLabel: Text? = nil, onClose: @escaping () -> Void,
                @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.subtitle = subtitle
        self.closeLabel = closeLabel
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
    }

    /// The localizing initializer: the literals are harvested into the calling target's catalog.
    public init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, onClose: @escaping () -> Void,
                @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(title: Text(title), subtitle: subtitle.map { Text($0) }, onClose: onClose,
                  content: content, footer: footer)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FocusedFlowHeader(title: title, subtitle: subtitle, closeLabel: closeLabel, onClose: onClose)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if Footer.self != EmptyView.self {
                VStack(spacing: 10) { footer }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .background { FernletDottedPage().ignoresSafeArea() }
        .environment(\.fernletPlateNavigation, nil)
        .environment(\.fernletTitleOnPlate, false)
        .environment(\.fernletPageTitleOnPlate, false)
        .accessibilityAction(.escape) { onClose() }
    }
}

public extension FernletFocusedFlow where Footer == EmptyView {
    /// A focused flow with no bottom row, its title runtime data or absent.
    init(title: Text?, subtitle: Text? = nil, closeLabel: Text? = nil, onClose: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, closeLabel: closeLabel, onClose: onClose,
                  content: content, footer: { EmptyView() })
    }

    /// A focused flow with no bottom row and an authored title.
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, onClose: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.init(title: Text(title), subtitle: subtitle.map { Text($0) }, onClose: onClose,
                  content: content, footer: { EmptyView() })
    }
}

/// A focused flow's top row (`.ftop`): the title (Fraunces 21) and its line, then ✕ or a close word.
private struct FocusedFlowHeader: View {
    let title: Text?
    let subtitle: Text?
    let closeLabel: Text?
    let onClose: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    title
                        .font(FernletFramedFont.flowTitle)
                        .foregroundStyle(look?.text ?? Color.bark)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                if let subtitle {
                    subtitle
                        .font(FernletFramedFont.note)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let closeLabel {
                Button(action: onClose) { closeLabel }
                    .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("focus.close")
            } else {
                FernletCloseButton(action: onClose)
            }
        }
        .frame(minHeight: 44)
    }
}
