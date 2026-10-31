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
    /// The major roads the lifted fog has crossed, drawn whole in amber (World-Exploration-Spec §2, `ex-roads`):
    /// under the fog, so they show only where the map is uncovered, and under the saved lines.
    var roads: WorldRoadDrawing = .none
    /// Whether the roads draw over the fog instead (the city view, `ex-city-view`: "crossed roads show on top"),
    /// with the saved lines drawn again over them so a walk stays readable.
    var roadsOverFog = false

    /// How wide a saved line draws, in points: the mockups' `--m-trail` line, the same for a walk's and a
    /// ride's (owner 2026-10-29, Refinements group 19).
    static let trailWidth: CGFloat = 5
}

/// Fernlet's own ground layer over whichever base map is underneath: the crossed major roads and the trails, the
/// nature fog with its lifted cells (``NatureFogLayer``: ground hexes, grass, flowers, boulders and trees, approved
/// 2026-10-26), and dotted traces. The roads draw in this layer's own Canvas, never inside the fog's tiles; in the
/// city view a sibling Canvas over the fog draws them (and the trails again) on top.
///
/// Everything is placed from the reported `MapViewport` and the global `MercatorHexGrid`; nothing
/// here knows the base map is Apple's. It never takes touches, so pans and pinches reach the map, and
/// it is decoration to VoiceOver (design page, "It still reads as a list").
struct WorldGroundLayer: View {
    let viewport: MapViewport
    let ground: WorldGround
    let darkStyle: Bool
    /// Fernlet's camera request, so the fog draws a glide's end before the map gets there.
    var camera: WorldCamera?
    /// The land under the fog (World-Exploration-Spec §1: the sea, desert, mountains, roofs, the seasons…), from
    /// the bundled atlas; nil, or no atlas, draws today's nature fog everywhere.
    var terrain: NatureFogTerrain? = nil
    /// Whether the map is the front page; behind, the fog gives back its off-screen tiles.
    var isFrontmost = true
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                if !ground.roadsOverFog { drawRoads(in: &context, size: size) }
                drawTrails(in: &context, size: size)
            }
            NatureFogLayer(scene: NatureFogScene(viewport: viewport,
                                                 clearing: NatureFogClearing(lifted: ground.lifted, uncovered: ground.uncovered),
                                                 palette: NatureFogPalette(dark: darkStyle, highContrast: contrast == .increased),
                                                 motion: NatureFogMotion(reduceMotion: reduceMotion), camera: camera, terrain: terrain,
                                                 isFrontmost: isFrontmost))
            if ground.roadsOverFog, ground.roads.roadCount > 0 {
                Canvas { context, size in
                    drawRoads(in: &context, size: size)
                    drawTrails(in: &context, size: size)
                }
            }
            traces
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The saved lines, solid green.
    private func drawTrails(in context: inout GraphicsContext, size: CGSize) {
        let trailColor = darkStyle ? WorldPalette.nightTrail : WorldPalette.trail
        for trail in ground.trails {
            context.stroke(path(for: trail, size: size), with: .color(trailColor),
                           style: StrokeStyle(lineWidth: WorldGround.trailWidth, lineCap: .square, lineJoin: .miter))
        }
    }

    /// The crossed roads, 5 pt at Home's zoom and 4 pt zoomed out a step; nothing for a viewport out of
    /// proportion with the view (the W-20 guard).
    private func drawRoads(in context: inout GraphicsContext, size: CGSize) {
        guard ground.roads.roadCount > 0, WorldLayerGuard.accepts(viewport, in: size) else { return }
        let width = WorldExploreSelection.isZoomedOut(viewport) ? WorldRoadStyle.homeZoomedOutWidth : WorldRoadStyle.homeWidth
        let projection = WorldRoadPainter.Projection(originX: viewport.minX, originY: viewport.minY,
                                                     scale: Double(size.width) / viewport.width)
        WorldRoadPainter.draw(ground.roads, in: &context, size: size, projection: projection) { _ in width }
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
