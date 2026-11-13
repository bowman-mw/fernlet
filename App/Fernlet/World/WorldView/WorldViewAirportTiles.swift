import CoreGraphics
import Foundation
import WorldMapStore

/// One runway on Your world: its ends in Mercator units (`x` in `0..<1`), as the camera places them.
nonisolated struct WorldViewRunway: Equatable, Sendable {
    let startX: Double, startY: Double
    let endX: Double, endY: Double
}

/// The found airports on Your world (owner, 2026-11-02): each one's grounds as blue hexes, whichever hexes the zoom
/// is drawing, and from City in its real runways on them. Home draws the same grounds as translucent fog; here they
/// are drawn only, never written into the fog, so they count towards nothing and go when the airport leaves the
/// passport. Pure, so the tests drive it with made-up airports.
nonisolated enum WorldViewAirportTiles {
    /// The most hexes one airport's box is scanned for. Past it (a ring crossing 180°) the airport keeps the one hex
    /// under its point.
    static let maxScannedHexes = 20_000
    /// The most airports read (``WorldFlightArcs/maxMarks``, as many as draw a tower).
    static let maxAirports = WorldFlightArcs.maxMarks

    /// The hexes of `grid` that `airports` fill. Bounded: ``maxAirports`` airports, ``maxScannedHexes`` hexes each.
    static func cells(of airports: [WorldAirport], in grid: WorldViewHexGrid) -> Set<HexCell> {
        var cells = Set<HexCell>()
        for airport in airports.prefix(maxAirports) { cells.formUnion(self.cells(of: airport, in: grid)) }
        return cells
    }

    /// The hexes of `grid` whose centre is on `airport`'s grounds, and always the hex under its point, so a small
    /// airport still shows far out.
    static func cells(of airport: WorldAirport, in grid: WorldViewHexGrid) -> [HexCell] {
        let unit = WebMercator.unit(airport.point)
        let own = WorldViewCamera.canonical((unit.x, unit.y), in: grid)
        let across = 3.0.squareRoot() * grid.radius, rowHeight = 1.5 * grid.radius
        guard grid.radius > 0, grid.radius.isFinite else { return [own] }
        let box = box(of: airport)
        let firstRow = Int((box.minY / rowHeight).rounded(.down)), lastRow = Int((box.maxY / rowHeight).rounded(.up))
        let columns = (box.maxX - box.minX) / across + 2
        guard lastRow >= firstRow, Double(lastRow - firstRow + 1) * columns <= Double(maxScannedHexes) else { return [own] }
        var cells = [own]
        // Bounded: at most maxScannedHexes hexes, by the guard above.
        for r in firstRow...lastRow {
            let shift = Double(r) / 2
            let firstQ = Int((box.minX / across - shift).rounded(.down)), lastQ = Int((box.maxX / across - shift).rounded(.up))
            for q in firstQ...max(firstQ, lastQ) {
                let x = across * (Double(q) + shift), y = rowHeight * Double(r)
                guard airport.contains(WebMercator.geo(x: WorldViewCamera.wrap(x), y: y)) else { continue }
                cells.append(WorldViewCamera.canonical((x, y), in: grid))
            }
        }
        return cells
    }

    /// `airports`' runways. Bounded: ``maxAirports`` airports, `WorldAirports/maxRunways` runways each.
    static func runways(of airports: [WorldAirport]) -> [WorldViewRunway] {
        airports.prefix(maxAirports).flatMap { airport in
            airport.runways.prefix(WorldAirports.maxRunways).map { runway in
                let start = WebMercator.unit(runway.start), end = WebMercator.unit(runway.end)
                return WorldViewRunway(startX: WorldViewCamera.wrap(start.x), startY: start.y,
                                       endX: WorldViewCamera.wrap(end.x), endY: end.y)
            }
        }
    }

    /// The box round `airport`'s grounds, in Mercator units.
    private static func box(of airport: WorldAirport) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let middle = WebMercator.unit(airport.point)
        switch airport.grounds {
        case .circle(let metres):
            let radius = metres * WebMercator.unitsPerMetre(at: airport.point.latitude)
            return (middle.x - radius, middle.x + radius, middle.y - radius, middle.y + radius)
        case .runways(let ring), .outline(let ring):
            let units = ring.prefix(WorldAirports.maxRingPoints).map { WebMercator.unit($0) }
            let xs = units.map(\.x), ys = units.map(\.y)
            return (xs.min() ?? middle.x, xs.max() ?? middle.x, ys.min() ?? middle.y, ys.max() ?? middle.y)
        }
    }
}
