import FernletDomainModel
import SwiftUI

/// Back to Sprout (`ref-recenter`, approved 2026-10-26): shown on Home only while the map isn't following
/// the companion, just above the blue button. A 52-pt cream square (60 pt at the accessibility sizes) in a
/// 3-pt ink frame with 10-pt corners and the blue button's drop shadow; inside, the person's own pixel
/// companion small (the map sprite at 1.3 pt a pixel) within four moss-ink corner ticks. A tap glides the
/// map back to the companion and follows again (Reduce Motion jumps: the base map's own rule); the button
/// goes once following.
///
/// VoiceOver and Voice Control: "Back to <companion's name>".
struct WorldRecenterButton: View {
    var store: FernletStore
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The square's side: 52 pt, 60 at the accessibility sizes.
    private var side: CGFloat { dynamicTypeSize.isAccessibilitySize ? 60 : 52 }

    var body: some View {
        let label = WorldRecenterCopy.label(name: WorldRecenterCopy.companionName(store))
        Button(action: action) {
            ZStack {
                WorldRecenterTicks()
                    .stroke(WorldRecenterButton.ticks, style: StrokeStyle(lineWidth: 3, lineCap: .square))
                    .padding(9)
                WorldCompanionSprite(now: WorldCompanionLook.current(store: store, at: Date()), isActive: false, pixelScale: 1.3)
            }
            .frame(width: side, height: side)
            .background(WorldRecenterButton.fill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 3))
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.sRGB, red: 20 / 255, green: 40 / 255, blue: 50 / 255, opacity: 0.4)).offset(y: 3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityInputLabels([Text(verbatim: label)])
        .accessibilityIdentifier("world.recenter")
    }

    /// Cream in light, the approved dark fill (#3A332B) in dark.
    static let fill = WorldPalette.adaptive(light: 0xFFF1CF, dark: 0x3A332B)
    /// Moss ink in light, the approved light moss (#CFE3B8) in dark.
    static let ticks = WorldPalette.adaptive(light: 0x46683A, dark: 0xCFE3B8)
}

/// The four corner ticks round the small companion: 9-pt arms at each corner of the rect.
struct WorldRecenterTicks: Shape {
    /// Each tick's arm, in points.
    var arm: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1), (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1), (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (corner, east, south) in corners {
            path.move(to: CGPoint(x: corner.x + east * arm, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + south * arm))
        }
        return path
    }
}

/// Back to Sprout's words (`ref-recenter`, `ref-recenter-auto`).
enum WorldRecenterCopy {
    /// The button's name, for VoiceOver and Voice Control: "Back to Sprout".
    static func label(name: String) -> String {
        String(localized: "worldRecenter.label", defaultValue: "Back to \(name)",
               comment: "World Home, the button that brings the map back to the companion; the companion's name")
    }

    /// Said once, politely, when the map follows the companion again by itself.
    static func followingAgain(name: String) -> String {
        String(localized: "worldRecenter.followingAgain", defaultValue: "Following \(name) again",
               comment: "World Home, VoiceOver: the map follows the companion again by itself; the companion's name")
    }

    /// The companion's name as Home says it (``FernletStore/worldCompanionName``).
    static func companionName(_ store: FernletStore) -> String {
        store.worldCompanionName
    }
}
