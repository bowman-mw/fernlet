import FernletUI
import SwiftUI

/// The small wood tab under the status plate's left edge, "Today ›" ("Hoy ›"), like a tab on a folder
/// (World Review Refinements `ref-plate`, `ref-plate-dark`, `ref-plate-ax`, `ref-plate-es`, approved by
/// the owner on 2026-10-24), so it is clear that the plate opens Today. It is part of the plate's button,
/// so tapping it opens Today too.
///
/// Hidden from VoiceOver and Voice Control: the plate already says "Opens Today". Wood with the plate's
/// bark text in light mode and the App colors wood with its cream text in dark mode, in a 3-pt ink frame
/// open at the top. DM Sans bold 13.5 pt, 17 pt at the accessibility text sizes.
struct WorldTodayTab: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.worldAppColors) private var appColors

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
        HStack(spacing: 5) {
            Text(Self.title)
                .font(Self.font(accessibilitySize: dynamicTypeSize.isAccessibilitySize))
                // The plate's own steps (13.5, then 17 at the accessibility sizes), as the approved
                // designs draw it on the map, rather than growing in between.
                .dynamicTypeSize(...DynamicTypeSize.large)
                .foregroundStyle(appColors.wood.tones.label)
                .lineLimit(1)
                .fixedSize()
            WorldSpriteView(sprite: WorldSprites.chevR, scale: 2, tint: appColors.wood.tones.label)
        }
        .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
        .background(appColors.wood.tones.wood, in: shape)
        .overlay { WorldTodayTabFrame().stroke(WorldPalette.ink, lineWidth: 3) }
        .background { shape.fill(Color(.sRGB, red: 74 / 255, green: 46 / 255, blue: 28 / 255, opacity: 0.3)).offset(y: 3) }
        .accessibilityHidden(true)
    }

    /// "Today", as the tab says it.
    static let title = LocalizedStringResource("worldStatus.todayTab", defaultValue: "Today",
                                               comment: "World Home: the small wood tab under the status plate that shows tapping it opens Today (Spanish: Hoy)")

    /// The tab's type: 13.5 pt, or 17 at the accessibility sizes (the approved largest-text design).
    static func font(accessibilitySize: Bool) -> Font {
        .custom(FernletFontName.dmSansMedium, size: pointSize(accessibilitySize: accessibilitySize), relativeTo: .caption).weight(.bold)
    }

    /// The tab's text size in points.
    static func pointSize(accessibilitySize: Bool) -> CGFloat {
        accessibilitySize ? 17 : 13.5
    }
}

/// The tab's frame: both sides and the rounded bottom, open at the top where it meets the plate.
struct WorldTodayTabFrame: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: 1.5, dy: 0)
        let radius: CGFloat = 6.5
        var path = Path()
        path.move(to: CGPoint(x: inset.minX, y: inset.minY))
        path.addLine(to: CGPoint(x: inset.minX, y: inset.maxY - 1.5 - radius))
        path.addQuadCurve(to: CGPoint(x: inset.minX + radius, y: inset.maxY - 1.5),
                          control: CGPoint(x: inset.minX, y: inset.maxY - 1.5))
        path.addLine(to: CGPoint(x: inset.maxX - radius, y: inset.maxY - 1.5))
        path.addQuadCurve(to: CGPoint(x: inset.maxX, y: inset.maxY - 1.5 - radius),
                          control: CGPoint(x: inset.maxX, y: inset.maxY - 1.5))
        path.addLine(to: CGPoint(x: inset.maxX, y: inset.minY))
        return path
    }
}
