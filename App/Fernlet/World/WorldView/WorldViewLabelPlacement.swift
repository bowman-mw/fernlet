import CoreGraphics
import Foundation
import WorldMapStore

/// Where a city marker's label stands (owner, 2026-11-02: a label must not hide the ground the person found): the
/// point its nearest edge touches, in points from the city at the scale where its hex detail starts, and which side
/// of that point it hangs on. The map scales the offset with the zoom, so the label keeps to the same ground.
nonisolated struct WorldViewLabelSpot: Hashable, Sendable {
    /// Which way the label hangs from the point it touches.
    enum Side: Hashable, Sendable {
        case right, upRight, up, upLeft, left, downLeft, down, downRight

        /// The direction out from the city.
        var direction: (x: Double, y: Double) {
            let diagonal = 0.5.squareRoot()
            switch self {
            case .right: return (1, 0)
            case .upRight: return (diagonal, -diagonal)
            case .up: return (0, -1)
            case .upLeft: return (-diagonal, -diagonal)
            case .left: return (-1, 0)
            case .downLeft: return (-diagonal, diagonal)
            case .down: return (0, 1)
            case .downRight: return (diagonal, diagonal)
            }
        }

        /// The sides to try, the likeliest first: a plate beside the city, a skyline standing over it.
        static func preference(skyline: Bool) -> [Side] {
            skyline ? [.up, .upRight, .upLeft, .right, .left, .downRight, .downLeft, .down]
                : [.right, .upRight, .downRight, .up, .down, .left, .upLeft, .downLeft]
        }
    }

    /// The side it hangs on.
    let side: Side
    /// The point it touches, in points from the city.
    let dx: Double, dy: Double

    /// The spot a label takes before a plan is worked out, or past ``WorldViewLabelPlacement/maxPlanned``.
    static func fallback(skyline: Bool) -> WorldViewLabelSpot {
        WorldViewLabelPlacement.spot(side: skyline ? .up : .right, distance: WorldViewLabelPlacement.distances[0])
    }
}

/// One hex detail's city markers with where their labels stand.
nonisolated struct WorldViewMarkerPlan: Sendable {
    /// The markers (``WorldViewCluster``).
    let clusters: [WorldViewCluster]
    /// Where each label stands, by the marker's anchor token.
    let spots: [String: WorldViewLabelSpot]

    /// The plan of every detail. Bounded: `AtlasZoomDetail/all` details, each ``WorldViewLabelPlacement/spots(for:detail:found:flights:)``.
    static func all(pins: [WorldViewCityPin], found: [AtlasZoomDetail: Set<HexCell>],
                    flights: WorldFlightMap) -> [AtlasZoomDetail: WorldViewMarkerPlan] {
        var plans: [AtlasZoomDetail: WorldViewMarkerPlan] = [:]
        for detail in AtlasZoomDetail.all {
            let clusters = WorldViewCluster.clusters(of: pins, scale: detail.pointsPerMercatorUnit)
            let spots = WorldViewLabelPlacement.spots(for: clusters, detail: detail, found: found[detail] ?? [], flights: flights)
            plans[detail] = WorldViewMarkerPlan(clusters: clusters, spots: spots)
        }
        return plans
    }
}

/// Places the city labels (pure, so the tests drive it): the biggest city first, each label takes the nearest spot
/// that covers none of the found hexes, no other label, no city and no airport mark; when every spot covers
/// something, the one that covers least. Worked out once per hex detail, for every marker, so a label never moves
/// as the map pans.
nonisolated enum WorldViewLabelPlacement {
    /// The most markers placed per detail (the biggest; the rest take the fallback spot).
    static let maxPlanned = 300
    /// How far out a label may stand, in points, nearest first.
    static let distances = [10.0, 22, 38, 60, farthest]
    /// The farthest a label stands (the zoom can stretch this by half again before the next hex detail): past it, it
    /// may as well sit on some found ground as leave the screen on a long line.
    static let farthest = 90.0
    /// The distance between two samples of the ground under a label: one per hex at the detail's own scale.
    static let sampleStep = 10.0
    /// A plate's height.
    static let plateHeight = 20.0
    /// A framed skyline's size: the 48 × 40 picture in its chip.
    static let skylineChip = CGSize(width: 56, height: 45)
    /// What a covered thing costs. A label moves one distance out rather than cover one found hex.
    private static let labelCost = 10_000.0, markCost = 2_000.0, foundCost = 100.0, distanceCost = 30.0

    /// The spots of `clusters` at `detail`, by anchor token. Bounded: ``maxPlanned`` markers, eight sides and
    /// ``distances`` per marker, one sample per ``sampleStep`` of each label.
    static func spots(for clusters: [WorldViewCluster], detail: AtlasZoomDetail, found: Set<HexCell>,
                      flights: WorldFlightMap) -> [String: WorldViewLabelSpot] {
        let scale = detail.pointsPerMercatorUnit, skyline = detail.level >= .state, grid = detail.hexGrid
        let planned = clusters.prefix(maxPlanned)
        let cities = planned.map { CGPoint(x: $0.anchor.x * scale, y: $0.anchor.y * scale) }
        let fixed = cities.map { CGRect(x: $0.x - 6, y: $0.y - 6, width: 12, height: 12) }
            + markRects(flights, scale: scale, named: detail.level > .world)
        var taken: [CGRect] = [], spots: [String: WorldViewLabelSpot] = [:]
        let covered: (CGRect) -> Double = { foundHexes(under: $0, grid: grid, scale: scale, found: found) }
        for (cluster, city) in zip(planned, cities) {
            let size = labelSize(cluster, skyline: skyline)
            let reach = CGRect(origin: city, size: .zero).insetBy(dx: -(farthest + size.width), dy: -(farthest + size.height))
            let nearFixed = fixed.filter { $0.intersects(reach) }, nearTaken = taken.filter { $0.intersects(reach) }
            let best = bestSpot(city: city, size: size, skyline: skyline, fixed: nearFixed, taken: nearTaken, covered: covered)
            spots[cluster.anchor.token] = best.spot
            taken.append(best.rect)
        }
        return spots
    }

    /// The spot on `side`, `distance` points out.
    static func spot(side: WorldViewLabelSpot.Side, distance: Double) -> WorldViewLabelSpot {
        WorldViewLabelSpot(side: side, dx: side.direction.x * distance, dy: side.direction.y * distance)
    }

    /// The rectangle a label of `size` fills when it touches `point` on `side`.
    static func rect(side: WorldViewLabelSpot.Side, touching point: CGPoint, size: CGSize) -> CGRect {
        let x: CGFloat, y: CGFloat
        switch side {
        case .right, .upRight, .downRight: x = point.x
        case .left, .upLeft, .downLeft: x = point.x - size.width
        case .up, .down: x = point.x - size.width / 2
        }
        switch side {
        case .down, .downLeft, .downRight: y = point.y
        case .up, .upLeft, .upRight: y = point.y - size.height
        case .left, .right: y = point.y - size.height / 2
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// A label's size near enough for placing it: the plate from its name's length, over a skyline from State in.
    static func labelSize(_ cluster: WorldViewCluster, skyline: Bool) -> CGSize {
        let letters = cluster.anchor.name.count + (cluster.others > 0 ? 3 : 0)
        let plate = Double(min(letters, 40)) * 6.9 + 14
        guard skyline else { return CGSize(width: plate, height: plateHeight) }
        return CGSize(width: max(plate, skylineChip.width), height: skylineChip.height + 2 + plateHeight)
    }

    /// The cheapest spot round `city`. The spots are tried nearest first, likeliest side first, so the first that
    /// covers nothing is the cheapest.
    private static func bestSpot(city: CGPoint, size: CGSize, skyline: Bool, fixed: [CGRect], taken: [CGRect],
                                 covered: (CGRect) -> Double) -> (spot: WorldViewLabelSpot, rect: CGRect) {
        let sides = WorldViewLabelSpot.Side.preference(skyline: skyline)
        var best: (spot: WorldViewLabelSpot, rect: CGRect, cost: Double)?
        for (ring, distance) in distances.enumerated() {
            for (rank, side) in sides.enumerated() {
                let spot = spot(side: side, distance: distance)
                let area = rect(side: side, touching: CGPoint(x: city.x + spot.dx, y: city.y + spot.dy), size: size)
                let hits = Double(taken.count { $0.intersects(area) }) * labelCost + Double(fixed.count { $0.intersects(area) }) * markCost
                let cost = hits + covered(area) * foundCost + Double(ring) * distanceCost + Double(rank)
                if cost < best?.cost ?? .infinity { best = (spot, area, cost) }
                if cost == Double(ring) * distanceCost + Double(rank) { return (spot, area) }
            }
        }
        let fallback = WorldViewLabelSpot.fallback(skyline: skyline)
        return best.map { ($0.spot, $0.rect) }
            ?? (fallback, rect(side: fallback.side, touching: city, size: size))
    }

    /// How many samples under `area` lie on a found hex. Bounded: one sample per ``sampleStep`` of the label.
    private static func foundHexes(under area: CGRect, grid: WorldViewHexGrid, scale: Double, found: Set<HexCell>) -> Double {
        guard !found.isEmpty, scale > 0 else { return 0 }
        var hits = 0, y = Double(area.minY) + sampleStep / 2
        while y < Double(area.maxY) {
            var x = Double(area.minX) + sampleStep / 2
            while x < Double(area.maxX) {
                if found.contains(grid.cell(x: WorldViewCamera.wrap(x / scale), y: y / scale)) { hits += 1 }
                x += sampleStep
            }
            y += sampleStep
        }
        return Double(hits)
    }

    /// What the airport marks fill, at `scale`: a tower and its code beside its foot, a ring and (when `named`) its code.
    private static func markRects(_ flights: WorldFlightMap, scale: Double, named: Bool) -> [CGRect] {
        let plate = { (code: String) in Double(code.count) * 8 + 10 + 3 }
        let towers = flights.found.map { mark -> CGRect in
            CGRect(x: Double(mark.mercator.x) * scale - 11, y: Double(mark.mercator.y) * scale - 20,
                   width: 22 + plate(mark.code), height: 22)
        }
        let rings = flights.rings.map { mark -> CGRect in
            CGRect(x: Double(mark.mercator.x) * scale - 5, y: Double(mark.mercator.y) * scale - 10,
                   width: 10 + (named ? plate(mark.code) : 0), height: 20)
        }
        return towers + rings
    }
}
