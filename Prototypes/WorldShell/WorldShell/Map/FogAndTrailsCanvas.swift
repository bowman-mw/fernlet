import SwiftUI

/// Fernlet's own ground layers over whichever base map is underneath: saved trails, the hex fog
/// with its lifted cells, and the dotted traces of this session's walks.
///
/// Everything is placed from the reported ``MapViewport`` and plain ``GeoPoint``s; nothing here
/// knows the base map is Apple's. It never takes touches, so pans and pinches reach the map.
struct FogAndTrailsCanvas: View {
    let viewport: MapViewport
    let lifted: Set<HexCell>
    let trails: [[GeoPoint]]
    let traces: [[GeoPoint]]
    let darkStyle: Bool

    var body: some View {
        Canvas { context, size in
            let trailColor = darkStyle ? FernColors.rgb(0x8DBB78) : FernColors.trail
            for trail in trails {
                context.stroke(path(for: trail, size: size), with: .color(trailColor),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            drawFog(&context, size: size)
            // This session's walks: dotted footsteps in ink on a cream underlay, so they read even
            // where they follow a saved trail.
            for trace in traces {
                let line = path(for: trace, size: size)
                context.stroke(line, with: .color(FernColors.gameCream.opacity(0.9)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                context.stroke(line, with: .color(darkStyle ? FernColors.gameCream : FernColors.ink),
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

    /// The fog: every visible cell not yet lifted. Cells on the frontier (next to a lifted one) are
    /// lighter, so the edge of what you've uncovered reads at a glance; a hairline marks each hex.
    private func drawFog(_ context: inout GraphicsContext, size: CGSize) {
        let grid = WorldFixtures.grid
        let ppm = viewport.pointsPerMetre(at: viewport.center.latitude, in: size)
        guard ppm > 0.005 else { return }
        // Half a point of overlap closes the antialiased seams, so the map never peeks between cells.
        let grow = (grid.radius * ppm + 0.5) / max(grid.radius * ppm, 0.001)
        let corners = grid.cornerOffsets.map { CGSize(width: $0.east * ppm * grow, height: -$0.north * ppm * grow) }
        var deep = Path(), shade = Path(), frontier = Path()
        for cell in visibleCells(grid: grid, size: size) where !lifted.contains(cell) {
            let centre = viewport.screenPoint(for: grid.centre(of: cell), in: size)
            let hex = Path { shape in
                shape.addLines(corners.map { CGPoint(x: centre.x + $0.width, y: centre.y + $0.height) })
                shape.closeSubpath()
            }
            if grid.neighbours(of: cell).contains(where: lifted.contains) {
                frontier.addPath(hex)
            } else if (cell.q - cell.r) % 3 == 0 {
                shade.addPath(hex)
            } else {
                deep.addPath(hex)
            }
        }
        let fog = darkStyle ? FernColors.rgb(0x353A4E) : FernColors.fog
        let fogShade = darkStyle ? FernColors.rgb(0x30354A) : FernColors.rgb(0xE6DDC8)
        context.fill(deep, with: .color(fog.opacity(0.97)))
        context.fill(shade, with: .color(fogShade.opacity(0.97)))
        context.fill(frontier, with: .color(fog.opacity(0.72)))
        var edges = deep
        edges.addPath(shade)
        context.stroke(edges, with: .color((darkStyle ? Color.black : FernColors.fogEdge).opacity(0.55)), lineWidth: 0.75)
    }

    /// The cells that can touch the screen, padded by one ring (at most 12,000).
    private func visibleCells(grid: HexGrid, size: CGSize) -> [HexCell] {
        let corner1 = viewport.geo(at: .zero, in: size).metres(from: grid.origin)
        let corner2 = viewport.geo(at: CGPoint(x: size.width, y: size.height), in: size).metres(from: grid.origin)
        let pad = grid.radius * 2
        let rowHeight = grid.radius * 1.5, columnWidth = grid.radius * 3.0.squareRoot()
        let rMin = Int(((min(corner1.north, corner2.north) - pad) / rowHeight).rounded(.down))
        let rMax = Int(((max(corner1.north, corner2.north) + pad) / rowHeight).rounded(.up))
        let eastMin = min(corner1.east, corner2.east) - pad, eastMax = max(corner1.east, corner2.east) + pad
        guard rMax >= rMin, rMax - rMin < 400 else { return [] }
        var cells: [HexCell] = []
        for r in rMin...rMax {
            let qMin = Int((eastMin / columnWidth - Double(r) / 2).rounded(.down))
            let qMax = Int((eastMax / columnWidth - Double(r) / 2).rounded(.up))
            guard qMax >= qMin, qMax - qMin < 400 else { continue }
            for q in qMin...qMax { cells.append(HexCell(q: q, r: r)) }
            if cells.count > 12_000 { break }
        }
        return cells
    }
}
