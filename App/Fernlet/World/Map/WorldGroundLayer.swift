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
    /// Saved lines (routes, trails), drawn solid.
    var trails: [[GeoPoint]] = []
    /// Lines in progress or from this session, drawn as dotted footsteps.
    var traces: [[GeoPoint]] = []
}

/// Fernlet's own ground layer over whichever base map is underneath: trails, the hex fog with its
/// lifted cells, and dotted traces.
///
/// Everything is placed from the reported `MapViewport` and the global `MercatorHexGrid`; nothing
/// here knows the base map is Apple's. It never takes touches, so pans and pinches reach the map, and
/// it is decoration to VoiceOver (design page, "It still reads as a list").
struct WorldGroundLayer: View {
    let viewport: MapViewport
    let ground: WorldGround
    let darkStyle: Bool

    var body: some View {
        Canvas { context, size in
            let trailColor = darkStyle ? WorldPalette.nightTrail : WorldPalette.trail
            for trail in ground.trails {
                context.stroke(path(for: trail, size: size), with: .color(trailColor),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            WorldFogPainter(viewport: viewport, lifted: ground.lifted, darkStyle: darkStyle).paint(&context, size: size)
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

/// Paints the fog: every visible cell not yet lifted.
///
/// Cells on the frontier (next to a lifted one) are lighter, so the edge of what you've uncovered
/// reads at a glance; a hairline marks each fogged hex, and every third diagonal is a shade darker so
/// the grid reads as tiles rather than a flat sheet.
struct WorldFogPainter {
    let viewport: MapViewport
    let lifted: Set<HexCell>
    let darkStyle: Bool

    /// The smallest a cell may draw, in points; below it the fog is skipped (zoomed too far out).
    static let minimumCellPoints = 2.0

    /// Fills the fog's three tones and strokes its edges into `context`.
    func paint(_ context: inout GraphicsContext, size: CGSize) {
        let perUnit = viewport.pointsPerUnit(in: size)
        let cellPoints = MercatorHexGrid.radius * perUnit
        guard cellPoints >= Self.minimumCellPoints else { return }
        // Half a point of overlap closes the antialiased seams, so the map never peeks between cells.
        let grow = (cellPoints + 0.5) / cellPoints
        let corners = MercatorHexGrid.cornerOffsets.map { CGSize(width: $0.x * perUnit * grow, height: $0.y * perUnit * grow) }
        var deep = Path(), shade = Path(), frontier = Path()
        for cell in MercatorHexGrid.cells(in: viewport) where !lifted.contains(cell) {
            let centre = MercatorHexGrid.centre(of: cell)
            let point = viewport.screenPoint(x: centre.x, y: centre.y, in: size)
            let hex = Path { shape in
                shape.addLines(corners.map { CGPoint(x: point.x + $0.width, y: point.y + $0.height) })
                shape.closeSubpath()
            }
            if MercatorHexGrid.neighbours(of: cell).contains(where: lifted.contains) {
                frontier.addPath(hex)
            } else if (cell.q - cell.r) % 3 == 0 {
                shade.addPath(hex)
            } else {
                deep.addPath(hex)
            }
        }
        fill(&context, deep: deep, shade: shade, frontier: frontier)
    }

    /// The three fog tones and the hairline edges.
    private func fill(_ context: inout GraphicsContext, deep: Path, shade: Path, frontier: Path) {
        let fog = darkStyle ? WorldPalette.nightFog : WorldPalette.fog
        let fogShade = darkStyle ? WorldPalette.nightFogShade : WorldPalette.fogShade
        context.fill(deep, with: .color(fog.opacity(0.97)))
        context.fill(shade, with: .color(fogShade.opacity(0.97)))
        context.fill(frontier, with: .color(fog.opacity(0.72)))
        var edges = deep
        edges.addPath(shade)
        context.stroke(edges, with: .color((darkStyle ? Color.black : WorldPalette.fogEdge).opacity(0.55)), lineWidth: 0.75)
    }
}
