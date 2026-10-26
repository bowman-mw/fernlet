import SwiftUI
import WorldMapStore

/// What the ground layer draws: the lifted fog cells and the lines on the ground, all in plain
/// coordinates.
///
/// A decoy session hands this an empty history (World app plan, step 5a): the layer cannot tell, and
/// never needs to.
struct WorldGround: Equatable {
    /// Cells the fog has lifted from.
    var lifted: Set<HexCell> = []
    /// Cells drawn clear around the person's homes, hotel and kept places (round 6): never written into the
    /// fog, so they fog again when the place goes.
    var uncovered: Set<HexCell> = []
    /// Saved lines (routes, trails), drawn solid.
    var trails: [[GeoPoint]] = []
    /// Lines in progress or from this session, drawn as dotted footsteps.
    var traces: [[GeoPoint]] = []
}

/// Fernlet's own ground layer over whichever base map is underneath: trails, the nature fog with its
/// lifted cells (``NatureFogLayer``: ground hexes, grass, flowers, ponds, boulders and trees, approved
/// 2026-10-26), and dotted traces.
///
/// Everything is placed from the reported `MapViewport` and the global `MercatorHexGrid`; nothing
/// here knows the base map is Apple's. It never takes touches, so pans and pinches reach the map, and
/// it is decoration to VoiceOver (design page, "It still reads as a list").
struct WorldGroundLayer: View {
    let viewport: MapViewport
    let ground: WorldGround
    let darkStyle: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let trailColor = darkStyle ? WorldPalette.nightTrail : WorldPalette.trail
                for trail in ground.trails {
                    context.stroke(path(for: trail, size: size), with: .color(trailColor),
                                   style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
            NatureFogLayer(scene: NatureFogScene(viewport: viewport,
                                                 clearing: NatureFogClearing(lifted: ground.lifted, uncovered: ground.uncovered),
                                                 palette: NatureFogPalette(dark: darkStyle, highContrast: contrast == .increased),
                                                 motion: NatureFogMotion(reduceMotion: reduceMotion)))
            traces
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The dotted footsteps of lines in progress, over the fog.
    private var traces: some View {
        Canvas { context, size in
            for trace in ground.traces {
                let line = path(for: trace, size: size)
                context.stroke(line, with: .color(WorldPalette.gameCream.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                context.stroke(line, with: .color(darkStyle ? WorldPalette.gameCream : WorldPalette.ink),
                               style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round, dash: [0.5, 6]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A line through `points` in screen space.
    private func path(for points: [GeoPoint], size: CGSize) -> Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let screen = viewport.screenPoint(for: point, in: size)
            if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
        }
        return path
    }
}
