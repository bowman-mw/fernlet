import FernletUI
import SwiftUI

/// The plate that names the map's state, under the status plate (the design kit's `.ntc`: paper in a
/// 3-pt ink frame, a small pixel sprite, a bold line and a line under it): first day, loading, offline
/// and approximate location (`b1-home-first`, `b1-home-loading`, `b1-home-offline`, `b1-home-approx`).
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
            // The line keeps the room; a long "Use precise" wraps onto two lines instead of
            // squeezing it into a narrow column (Spanish and the doubled-length check).
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            if kind == .approximate { usePrecise }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorldPalette.ink, lineWidth: 3))
        .background {
            RoundedRectangle(cornerRadius: 9).fill(WorldPalette.ink.opacity(0.35)).offset(y: 3)
        }
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
        case .offline, .approximate: WorldSprites.pin
        case .loading: WorldSprites.photo
        case .firstDay: WorldSprites.leaf
        }
    }

    private var title: LocalizedStringResource {
        switch kind {
        case .offline: WorldNoticeCopy.offline
        case .approximate: WorldNoticeCopy.approximate
        case .loading: WorldNoticeCopy.loading
        case .firstDay: WorldNoticeCopy.firstDay
        }
    }

    private var detail: LocalizedStringResource? {
        switch kind {
        case .offline: WorldNoticeCopy.offlineDetail
        case .approximate: WorldNoticeCopy.approximateDetail
        case .loading: nil
        case .firstDay: WorldNoticeCopy.firstDayDetail
        }
    }

    /// A stable identifier per notice (a frozen token).
    static func identifier(_ kind: WorldMapNoticeKind) -> String {
        switch kind {
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

/// The notice plate's type (DM Sans): the line 15 pt bold, the line under it 13 pt.
nonisolated enum WorldNoticeType {
    static let title = Font.custom(FernletFontName.dmSansMedium, size: 15, relativeTo: .subheadline).weight(.bold)
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
    static let firstDayDetail = LocalizedStringResource("worldNotice.firstDay.detail", defaultValue: "It uncovers as you go, on this iPhone only.",
                                                        comment: "World Home notice under 'Your map starts here'")
}
