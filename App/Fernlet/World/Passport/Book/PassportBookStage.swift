import FernletUI
import SwiftUI

/// A page turn in progress (World-Passport-Spec §3): from one page to another, at one of its four pixel steps
/// (0 the page as it was, 1 the corner lifts, 2 the page turns, 3 the next page).
nonisolated struct PassportTurn: Equatable, Sendable {
    let from: Int
    let to: Int
    var step: Int

    /// Whether it turns on (the leaf lifts from the outer edge) rather than back.
    var forward: Bool { to > from }
    /// The page under the leaf at this step.
    var shown: Int { step >= 2 ? to : from }
}

/// The book itself (World-Passport-Spec §2): the ribbon hanging behind it, the cover, the page on its paper with
/// the page number at its foot, the turning leaf over it, and the cover's face while the book opens or closes.
///
/// `page` draws one page's content by number; the stage draws page `shown` (or both halves of a turn).
struct PassportBookStage<Page: View>: View {
    let shown: Int
    let turn: PassportTurn?
    /// The newest stamp's page, or nil (no ribbon before the first stamp).
    let ribbonPage: Int?
    /// The cover's swing: 0 closed over the page, -180 open (hidden past -90).
    let coverAngle: Double
    let onRibbon: (Int) -> Void
    @ViewBuilder let page: (Int) -> Page

    var body: some View {
        ZStack {
            PassportCoverBoard()
            pageArea
                .padding(EdgeInsets(top: 7, leading: 13, bottom: 14, trailing: 14))
            if coverAngle > -90 {
                PassportCoverFace()
                    .rotation3DEffect(.degrees(coverAngle), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.5)
            }
        }
        .background(alignment: .bottomTrailing) { ribbon }
    }

    /// The page, the halves of a turn and the leaf.
    private var pageArea: some View {
        ZStack {
            PassportPagePaper()
            page(turn?.shown ?? shown)
            if let turn, turn.step == 2 {
                page(turn.from)
                    .background(PassportBookPalette.paper)
                    .mask(alignment: turn.forward ? .leading : .trailing) {
                        GeometryReader { proxy in
                            Rectangle().frame(width: proxy.size.width * 0.5)
                                .frame(maxWidth: .infinity, alignment: turn.forward ? .leading : .trailing)
                        }
                    }
            }
            if let turn, turn.step == 1 || turn.step == 2 {
                PassportCurlLeaf(step: turn.step).scaleEffect(x: turn.forward ? 1 : -1)
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 8,
                                          topTrailingRadius: 8))
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

/// The turning leaf in pixel steps (the mockup's `curl`): at step 1 the outer corner lifts (a triangle of the
/// leaf's back), at step 2 the leaf stands halfway, its back narrowing toward the gutter. Drawn for a forward turn;
/// mirrored for a turn back. Decoration.
struct PassportCurlLeaf: View {
    let step: Int

    var body: some View {
        Canvas { context, size in
            let points: [CGPoint] = step == 1
                ? [CGPoint(x: 1, y: 0.7), CGPoint(x: 1, y: 1), CGPoint(x: 0.56, y: 1)]
                : [CGPoint(x: 0.5, y: 0), CGPoint(x: 0.22, y: 0.06), CGPoint(x: 0.22, y: 0.95), CGPoint(x: 0.5, y: 1)]
            var path = Path()
            path.addLines(points.map { CGPoint(x: Self.pixel($0.x * size.width), y: Self.pixel($0.y * size.height)) })
            path.closeSubpath()
            context.fill(path, with: .color(PassportBookPalette.paper2))
            context.stroke(path, with: .color(WorldPalette.ink), lineWidth: 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Snaps a coordinate to the 3 pt pixel grid.
    private static func pixel(_ value: CGFloat) -> CGFloat {
        (value / 3).rounded() * 3
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
