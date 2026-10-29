import FernletUI
import SwiftUI

/// The plate that names the map's state, under the status plate (the design kit's `.ntc`: paper in a
/// 3-pt ink frame, a small pixel sprite, a bold line and a line under it): first day, loading, offline,
/// approximate location and riding along (`b1-home-first`, `b1-home-loading`, `b1-home-offline`,
/// `b1-home-approx`, `b1-home-car`).
///
/// It is a status: announced once when it appears (loading only after two seconds), then left in the
/// reading order after the status plate.
struct WorldMapNotice: View {
    let kind: WorldMapNoticeKind
    /// "Use precise" on the approximate plate.
    var onUsePrecise: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // The plate hugs a one-line notice (the design's max-content width) and wraps at 360 pt.
        ViewThatFits(in: .horizontal) {
            plate.fixedSize()
            plate.frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 380 : 360)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("world.notice.\(Self.identifier(kind))")
    }

    /// The framed plate.
    private var plate: some View {
        HStack(alignment: .center, spacing: 10) {
            WorldSpriteView(sprite: sprite, scale: 2)
            if kind == .approximate {
                WorldNoticeLineLayout {
                    lines
                    usePrecise
                }
            } else {
                lines
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorldPalette.ink, lineWidth: 3))
        .background {
            RoundedRectangle(cornerRadius: 9).fill(WorldPalette.ink.opacity(0.35)).offset(y: 3)
        }
    }

    /// The bold line and the line under it, read as one.
    private var lines: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(WorldNoticeType.title)
            if let detail {
                Text(detail)
                    .font(WorldNoticeType.detail)
            }
        }
        .foregroundStyle(WorldPalette.bark)
        .fernletWrappingText()
        .accessibilityElement(children: .combine)
    }

    /// "Use precise": the wooden button on the approximate plate.
    private var usePrecise: some View {
        Button(action: onUsePrecise) {
            Text(WorldNoticeCopy.usePrecise)
                .font(FernletFramedFont.buttonSmall)
                .foregroundStyle(WorldPalette.bark)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .frame(minWidth: 44, minHeight: 44)
                .background(WorldPalette.wood, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(WorldPalette.ink, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(WorldNoticeCopy.usePreciseHint))
        .accessibilityIdentifier("world.notice.usePrecise")
    }

    private var sprite: WorldSprite {
        switch kind {
        case .offline, .approximate, .ridingAlong: WorldSprites.pin
        case .loading: WorldSprites.photo
        case .firstDay: WorldSprites.leaf
        }
    }

    private var title: LocalizedStringResource {
        switch kind {
        case .ridingAlong: WorldNoticeCopy.ridingAlong
        case .offline: WorldNoticeCopy.offline
        case .approximate: WorldNoticeCopy.approximate
        case .loading: WorldNoticeCopy.loading
        case .firstDay: WorldNoticeCopy.firstDay
        }
    }

    private var detail: LocalizedStringResource? {
        switch kind {
        case .ridingAlong: WorldNoticeCopy.ridingAlongDetail
        case .offline: WorldNoticeCopy.offlineDetail
        case .approximate: WorldNoticeCopy.approximateDetail
        case .loading: nil
        case .firstDay: WorldNoticeCopy.firstDayDetail
        }
    }

    /// A stable identifier per notice (a frozen token).
    static func identifier(_ kind: WorldMapNoticeKind) -> String {
        switch kind {
        case .ridingAlong: "ridingAlong"
        case .offline: "offline"
        case .approximate: "approximate"
        case .loading: "loading"
        case .firstDay: "firstDay"
        }
    }

    /// What VoiceOver hears when the plate appears.
    static func announcement(_ kind: WorldMapNoticeKind) -> String {
        let notice = WorldMapNotice(kind: kind)
        let title = String(localized: notice.title)
        guard let detail = notice.detail else { return title }
        return "\(title). \(String(localized: detail))"
    }
}

/// The approximate plate's lines and its "Use precise": side by side while the button takes at most
/// two fifths of the plate (the approved draft), else the button under the lines, so a long label
/// (Spanish, the doubled-length check) never squeezes either into a narrow column. Exactly two
/// subviews: the lines, then the button.
struct WorldNoticeLineLayout: Layout {
    /// The gap between the lines and the button.
    static let spacing: CGFloat = 10
    /// The most of the plate's width the button may take beside the lines.
    static let sideShare: CGFloat = 0.4

    /// The two frames, and whether the button sits beside the lines.
    private struct Frames {
        let lines: CGRect
        let button: CGRect
        let sideBySide: Bool
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let frames = Self.frames(width: proposal.width, subviews: subviews)
        return CGSize(width: max(frames.lines.maxX, frames.button.maxX), height: max(frames.lines.maxY, frames.button.maxY))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let frames = Self.frames(width: bounds.width, subviews: subviews)
        // Beside the lines the button keeps to the plate's right edge, as the approved plate draws it.
        let buttonX = frames.sideBySide ? bounds.maxX - frames.button.width : bounds.minX + frames.button.minX
        subviews[0].place(at: CGPoint(x: bounds.minX + frames.lines.minX, y: bounds.minY + frames.lines.minY),
                          proposal: ProposedViewSize(frames.lines.size))
        subviews[1].place(at: CGPoint(x: buttonX, y: bounds.minY + frames.button.minY),
                          proposal: ProposedViewSize(frames.button.size))
    }

    /// Where the lines and the button go in `width` (nil or unbounded: each at its ideal size, side by side).
    private static func frames(width: CGFloat?, subviews: Subviews) -> Frames {
        let button = subviews[1].sizeThatFits(.unspecified)
        let ideal = subviews[0].sizeThatFits(.unspecified)
        let wanted = ideal.width + spacing + button.width
        let total = width.map { $0.isFinite ? $0 : wanted } ?? wanted
        if button.width <= total * sideShare {
            let lines = subviews[0].sizeThatFits(ProposedViewSize(width: max(0, total - button.width - spacing), height: nil))
            let height = max(lines.height, button.height)
            return Frames(lines: CGRect(x: 0, y: (height - lines.height) / 2, width: lines.width, height: lines.height),
                          button: CGRect(x: lines.width + spacing, y: (height - button.height) / 2,
                                         width: button.width, height: button.height),
                          sideBySide: true)
        }
        let lines = subviews[0].sizeThatFits(ProposedViewSize(width: total, height: nil))
        let buttonWidth = min(button.width, total)
        let buttonHeight = subviews[1].sizeThatFits(ProposedViewSize(width: buttonWidth, height: nil)).height
        return Frames(lines: CGRect(origin: .zero, size: lines),
                      button: CGRect(x: 0, y: lines.height + spacing, width: buttonWidth, height: buttonHeight),
                      sideBySide: false)
    }
}

/// The notice plate's type (DM Sans): the line 15 pt bold, the line under it 13 pt.
nonisolated enum WorldNoticeType {
    static let title = Font.custom(FernletFontName.dmSansBold, size: 15, relativeTo: .subheadline)
    static let detail = Font.custom(FernletFontName.dmSans, size: 13, relativeTo: .footnote)
}

/// The notice plates' words (from the approved Batch 1 pages).
nonisolated enum WorldNoticeCopy {
    static let offline = LocalizedStringResource("worldNotice.offline", defaultValue: "Offline",
                                                 comment: "World Home notice: no signal, so the map's tiles are missing")
    static let offlineDetail = LocalizedStringResource("worldNotice.offline.detail", defaultValue: "Walks still record. The map returns with signal.",
                                                       comment: "World Home notice under 'Offline'")
    static let approximate = LocalizedStringResource("worldNotice.approximate", defaultValue: "Approximate location",
                                                     comment: "World Home notice: the person allowed approximate location only")
    static let approximateDetail = LocalizedStringResource("worldNotice.approximate.detail",
                                                           defaultValue: "The companion stands in your area, not on your street.",
                                                           comment: "World Home notice under 'Approximate location'")
    static let usePrecise = LocalizedStringResource("worldNotice.usePrecise", defaultValue: "Use precise",
                                                    comment: "World Home approximate-location notice: the button that leads to turning on precise location")
    static let usePreciseHint = LocalizedStringResource("worldNotice.usePrecise.hint", defaultValue: "Opens Fernlet's settings, where Precise Location is.",
                                                        comment: "World Home approximate-location notice, VoiceOver: what Use precise does")
    static let loading = LocalizedStringResource("worldNotice.loading", defaultValue: "Loading the map…",
                                                 comment: "World Home notice while Apple's map tiles load")
    static let firstDay = LocalizedStringResource("worldNotice.firstDay", defaultValue: "Your map starts here",
                                                  comment: "World Home notice on the first days, before the first walk")
    static let ridingAlong = LocalizedStringResource("worldNotice.ridingAlong", defaultValue: "Riding along",
                                                     comment: "World Home notice while Fernlet sees the person driving or riding in a car or bus")
    static let ridingAlongDetail = LocalizedStringResource("worldNotice.ridingAlong.detail",
                                                           defaultValue: "Quick starts and banners pause until you're on foot.",
                                                           comment: "World Home notice under 'Riding along': the blue button and banners wait until the person is walking again")
    static let firstDayDetail = LocalizedStringResource("worldNotice.firstDay.detail", defaultValue: "It uncovers as you go, on this iPhone only.",
                                                        comment: "World Home notice under 'Your map starts here'")
}
