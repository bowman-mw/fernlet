import FernletUI
import SwiftUI

/// A page turn in progress (World-Passport-Spec §3; owner 2026-10-30: one smooth, short swing rather than the
/// four held pixel steps, which read as a freeze): the page `from` swings away round the spine, uncovering `to`.
nonisolated struct PassportTurn: Equatable, Sendable {
    let from: Int
    let to: Int
    /// Tells one turn from the next, so a turn started during another swings a fresh leaf.
    let id: Int

    /// How long the leaf's half turn round the spine takes, in seconds.
    static let duration = 0.3

    /// Whether it turns on (the leaf lifts toward the reader and over to the left) rather than back.
    var forward: Bool { to > from }
}

/// The book itself (World-Passport-Spec §2): the ribbon hanging behind it, the cover, the page on its paper with
/// the page number at its foot, the cover swinging round the spine on the book's left edge, and what lies on the
/// open cover: the pages turned past page 1 and a turning leaf.
///
/// `page` draws one page's content by number; the stage draws page `shown`, and during a turn the leaf swinging
/// over it. Open, the cover lies flat to the left of the spine (owner 2026-10-30), so the screen's left edge shows
/// it as a cover-coloured bar; from page 2 a parchment page lies on it, a little shorter, as a turned page would.
struct PassportBookStage<Page: View>: View {
    let shown: Int
    let turn: PassportTurn?
    /// The newest stamp's page, or nil (no ribbon before the first stamp).
    let ribbonPage: Int?
    /// The cover's swing: 0 closed over the page, -180 open and lying to the left of the spine.
    let coverAngle: Double
    /// How strongly the pages turned past page 1 show on the open cover (0 while the cover swings).
    let turnedPages: Double
    let onRibbon: (Int) -> Void
    /// Called with a turn's ``PassportTurn/id`` once its leaf has swung away.
    let onTurnDone: (Int) -> Void
    @ViewBuilder let page: (Int) -> Page

    /// Where the page sits on the cover board.
    static var pageInsets: EdgeInsets { EdgeInsets(top: 7, leading: 13, bottom: 14, trailing: 14) }

    var body: some View {
        ZStack {
            PassportCoverBoard()
            pageArea
                .padding(Self.pageInsets)
            PassportCoverFace()
                .accessibilityHidden(coverAngle <= -90)
                .modifier(PassportSwing(angle: coverAngle, perspective: 0.5, shades: false) { PassportCoverBoard() })
                .allowsHitTesting(false)
            onTheOpenCover
                .padding(Self.pageInsets)
        }
        .background(alignment: .bottomTrailing) { ribbon }
    }

    /// The page, under the open cover's layer.
    private var pageArea: some View {
        ZStack {
            PassportPagePaper()
            page(turn.map { $0.forward ? $0.to : $0.from } ?? shown)
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 8,
                                          topTrailingRadius: 8))
    }

    /// What lies on the open cover, over it and over the page: the turned pages (from page 2, a page's paper lying
    /// flat to the left of the spine, where a turning leaf lands) and, during a turn, the leaf. Turning on, the leaf
    /// is the page left and the page arrived at lies under it; turning back, it is the page arrived at, lifting off
    /// the turned pages, and the page left lies under it until it lands.
    private var onTheOpenCover: some View {
        ZStack {
            if shown > 1 {
                PassportPagePaper()
                    .scaleEffect(x: -1, y: 1, anchor: .leading)
                    .opacity(turnedPages)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if let turn {
                PassportTurningLeaf(forward: turn.forward, onDone: { onTurnDone(turn.id) }) {
                    page(turn.forward ? turn.from : turn.to)
                }
                .id(turn.id)
            }
        }
    }

    /// The red ribbon: 18 pt wide, hanging 40 pt below the book, 22 pt in from the right; a 44 pt target.
    @ViewBuilder
    private var ribbon: some View {
        if let ribbonPage {
            Button { onRibbon(ribbonPage) } label: {
                PassportRibbonShape()
                    .fill(PassportBookPalette.ribbon)
                    .overlay(PassportRibbonShape().stroke(WorldPalette.ink, lineWidth: 2))
                    .frame(width: 18, height: 60)
                    .frame(width: 44, height: 60, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 22 - 13)
            .offset(y: 40)
            .accessibilityLabel(Text(PassportBookCopy.newestStamp(page: ribbonPage)))
            .accessibilityInputLabels([Text(PassportBookCopy.newestStampShort)])
            .accessibilityIdentifier("passport.ribbon")
        }
    }
}

/// The turning leaf (World-Passport-Spec §3; owner 2026-10-30): a page swinging round the spine on the book's left
/// edge in one continuous half turn over ``PassportTurn/duration``. Turning on, the page the turn leaves lifts
/// toward the reader and over off the left side (0° to −180°); turning back, the page the turn arrives at comes
/// back the same way and lands flat (−180° to 0°). Past edge-on it shows the page's paper from behind, which lands
/// exactly as the turned pages lie on the open cover. It animates a transform of a page drawn once, so nothing is
/// redrawn while it swings. Decoration.
struct PassportTurningLeaf<Content: View>: View {
    let forward: Bool
    let onDone: () -> Void
    @ViewBuilder let content: Content
    @State private var swung = false

    var body: some View {
        content
            .background(PassportPagePaper())
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 8,
                                              topTrailingRadius: 8))
            .environment(\.passportPageIsLeafCopy, true)
            .modifier(PassportSwing(angle: swung ? (forward ? -180 : 0) : (forward ? 0 : -180), perspective: 0.25,
                                    shades: true) { PassportPagePaper() })
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.easeInOut(duration: PassportTurn.duration)) { swung = true } completion: { onDone() }
            }
    }
}

extension EnvironmentValues {
    /// Whether this page is the copy a turning leaf draws (``PassportTurningLeaf``): decoration, so it takes no part in
    /// the passport's navigation. A page that registered its title and destination again on the leaf made SwiftUI
    /// warn that navigation updated more than once in a frame.
    @Entry var passportPageIsLeafCopy = false
}

/// A leaf of the book (a page, or the cover) at `angle` degrees round the book's left edge: negative lifts its outer
/// edge toward the reader (measured: with the left edge as the hinge, −45° draws the outer edge taller), −180 lies
/// flat to the left of the spine. Its face until it stands edge-on, then `back` (seen from behind, so mirrored by
/// the turn itself), with a shade deepening as it rises when `shades`. Animatable, so the face gives way to the
/// back mid-swing without redrawing either.
struct PassportSwing<Back: View>: ViewModifier, Animatable {
    var angle: Double
    let perspective: Double
    let shades: Bool
    @ViewBuilder let back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        let showsBack = abs(angle) > 90
        content
            .opacity(showsBack ? 0 : 1)
            .overlay { back.opacity(showsBack ? 1 : 0) }
            .overlay { PassportBookPalette.gutter.opacity(shades ? sin(abs(angle) * .pi / 180) : 0) }
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: perspective)
    }
}

/// One page's content inside the book (World-Passport-Spec §2, §4): the page padded on its paper, scrolling inside
/// the book when it is taller (the largest text), with a fade at the foot when it can scroll and the page number
/// centred at the foot in Fraunces italic.
struct PassportPageScroll<Content: View>: View {
    let number: Int
    @ViewBuilder let content: Content
    /// Whether the page is scrolled to its top (a swipe down closes the book only then).
    var onTop: (Bool) -> Void = { _ in }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView(.vertical) {
            content
                // The largest the page's words grow (the mockup's largest-text drawing): past it words break.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .padding(EdgeInsets(top: 12, leading: 23, bottom: 34, trailing: 12))
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y <= $0.contentInsets.top * -1 + 2 } action: { _, top in
            onTop(top)
        }
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                if dynamicTypeSize.isAccessibilitySize {
                    LinearGradient(colors: [PassportBookPalette.paper.opacity(0), PassportBookPalette.paper],
                                   startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.7))
                        .frame(height: 46)
                }
                Text(verbatim: "\(number)")
                    .font(PassportBookType.pageNumber)
                    .foregroundStyle(PassportBookPalette.dim)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .padding(.bottom, 7)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// A page that scrolls and pads itself (page 1), with the book's page number centred at its foot.
struct PassportPageNumber<Content: View>: View {
    let number: Int
    @ViewBuilder let content: Content

    var body: some View {
        content.overlay(alignment: .bottom) {
            Text(verbatim: "\(number)")
                .font(PassportBookType.pageNumber)
                .foregroundStyle(PassportBookPalette.dim)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .padding(.bottom, 7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
