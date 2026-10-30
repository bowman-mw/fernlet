import FernletUI
import SwiftUI
import WorldMapStore

/// The week's new corner on Home (World-Exploration-Spec §5, option 1, `ex-nudge-home`): a dashed gold hex over the
/// corner's fog cell with a pixel question mark, as the mockup's `ring()` draws it (fill `#FFF1C9` at 62 %, a
/// 3.2-pt `#B07A12` stroke dashed 5 on 3 off, the mark `#7A5210`), at least 21 pt to a corner so it reads at any
/// zoom. It is a button: VoiceOver reads "A new corner, 300 metres north-east" (the distance and compass point
/// from home), and a tap pans the map to it (the map glides, or jumps under Reduce Motion: the base map's rule).
/// Nothing moves on its own, so Reduce Motion has nothing else to hold still.
struct WorldCornerHexView: View {
    /// Points from the hex's centre to a corner.
    let radius: CGFloat
    /// What VoiceOver reads.
    let spoken: String
    let onTap: () -> Void

    /// The smallest corner-to-centre size drawn (the mockup's 21 pt).
    static let minimumRadius: CGFloat = 21

    var body: some View {
        Button(action: onTap) {
            ZStack {
                WorldCornerHexShape().fill(Self.fill)
                WorldCornerHexShape()
                    .stroke(Self.stroke, style: StrokeStyle(lineWidth: 3.2, lineJoin: .round, dash: [5, 3]))
                WorldCornerMark()
            }
            .frame(width: radius * 2 * 0.866, height: radius * 2)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityInputLabels([Text(WorldCornerCopy.inputLabel)])
        .accessibilityIdentifier("world.corner")
    }

    /// The hex's pale gold fill.
    static let fill = Color(red: 1, green: 241 / 255, blue: 201 / 255).opacity(0.62)
    /// The dashed gold edge.
    static let stroke = Color(red: 176 / 255, green: 122 / 255, blue: 18 / 255)
}

/// A pointy-top hexagon filling its rect's height (the fog grid's cells are pointy-top).
struct WorldCornerHexShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.height / 2
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return Path { path in
            for index in 0..<6 {
                let angle = (60 * Double(index) - 90) * .pi / 180
                let point = CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }
}

/// The question mark in the hex, in pixels (the app carries no pixel font): 5 × 7 at 2.4 pt a pixel.
struct WorldCornerMark: View {
    /// The mark's rows (`k` inked).
    static let rows = [".kkk.", "k...k", "....k", "...k.", "..k..", ".....", "..k.."]
    /// Points per pixel.
    static let pixel: CGFloat = 2.4
    /// The mark's ink.
    static let ink = Color(red: 122 / 255, green: 82 / 255, blue: 16 / 255)

    var body: some View {
        Canvas { context, _ in
            for (row, line) in Self.rows.enumerated() {
                for (column, character) in line.enumerated() where character == "k" {
                    let rect = CGRect(x: CGFloat(column) * Self.pixel, y: CGFloat(row) * Self.pixel,
                                      width: Self.pixel, height: Self.pixel)
                    context.fill(Path(rect), with: .color(Self.ink))
                }
            }
        }
        .frame(width: 5 * Self.pixel, height: 7 * Self.pixel)
        .accessibilityHidden(true)
    }
}

/// Where the week's corner stands on the map, placed from the viewport: drawn only while the corner is in view.
struct WorldCornerLayer: View {
    let cell: HexCell
    let home: GeoPoint
    let viewport: MapViewport
    let size: CGSize
    let onTap: () -> Void

    var body: some View {
        let centre = MercatorHexGrid.centreGeo(of: cell)
        let point = viewport.screenPoint(for: centre, in: size)
        if viewport.isUsable, CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40).contains(point) {
            WorldCornerHexView(radius: radius, spoken: WorldCornerCopy.spoken(FogCornerNudge.bearingAndDistance(from: home, to: cell)),
                               onTap: onTap)
                .position(point)
        }
    }

    /// The cell's corner-to-centre size on screen, at least ``WorldCornerHexView/minimumRadius``.
    private var radius: CGFloat {
        guard viewport.isUsable else { return WorldCornerHexView.minimumRadius }
        let real = CGFloat(MercatorHexGrid.radius / viewport.height) * size.height
        return max(real.isFinite ? real : 0, WorldCornerHexView.minimumRadius)
    }
}

/// The words of the week's new corner (spec §5).
nonisolated enum WorldCornerCopy {
    /// Sprout's bubble, once a week: the mockup's "There's a new corner just past the park. Fancy a look?" without
    /// the park (Fernlet knows no park names near home; question for the owner).
    static let bubble = LocalizedStringResource("worldCorner.bubble", defaultValue: "There's a new corner nearby. Fancy a look?",
                                                comment: "World Home: Sprout's speech once a week, pointing at a patch of fog near home the person hasn't walked yet")

    /// Voice Control's short name for the hex.
    static let inputLabel = LocalizedStringResource("worldCorner.inputLabel", defaultValue: "New corner",
                                                    comment: "World Home, Voice Control: the short name of the dashed hex marking this week's new corner")

    /// VoiceOver: "A new corner, 300 metres north-east" (the button trait adds "button"). The distance rounds to
    /// 50 m (10 m under 100 m).
    static func spoken(_ bearing: FogCornerBearing) -> String {
        let metres = rounded(bearing.metres)
        let direction = String(localized: compass(bearing.compass))
        return String(localized: "worldCorner.spoken", defaultValue: "A new corner, \(metres) metres \(direction)",
                      comment: "World Home, VoiceOver: the dashed hex of this week's new corner; how far from home in metres and towards which compass point (north-east)")
    }

    /// `metres` rounded for speech.
    static func rounded(_ metres: Double) -> Int {
        guard metres.isFinite, metres > 0 else { return 0 }
        let step = metres < 100 ? 10.0 : 50.0
        return Int((metres / step).rounded() * step)
    }

    /// The compass point's words after the distance ("north-east").
    static func compass(_ point: CompassPoint) -> LocalizedStringResource {
        switch point {
        case .n: LocalizedStringResource("worldCorner.compass.n", defaultValue: "north", comment: "World Home, VoiceOver: a compass point after a distance (300 metres north)")
        case .ne: LocalizedStringResource("worldCorner.compass.ne", defaultValue: "north-east", comment: "World Home, VoiceOver: a compass point after a distance (300 metres north-east)")
        case .e: LocalizedStringResource("worldCorner.compass.e", defaultValue: "east", comment: "World Home, VoiceOver: a compass point after a distance (300 metres east)")
        case .se: LocalizedStringResource("worldCorner.compass.se", defaultValue: "south-east", comment: "World Home, VoiceOver: a compass point after a distance (300 metres south-east)")
        case .s: LocalizedStringResource("worldCorner.compass.s", defaultValue: "south", comment: "World Home, VoiceOver: a compass point after a distance (300 metres south)")
        case .sw: LocalizedStringResource("worldCorner.compass.sw", defaultValue: "south-west", comment: "World Home, VoiceOver: a compass point after a distance (300 metres south-west)")
        case .w: LocalizedStringResource("worldCorner.compass.w", defaultValue: "west", comment: "World Home, VoiceOver: a compass point after a distance (300 metres west)")
        case .nw: LocalizedStringResource("worldCorner.compass.nw", defaultValue: "north-west", comment: "World Home, VoiceOver: a compass point after a distance (300 metres north-west)")
        }
    }
}
