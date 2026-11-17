import Foundation
import WorldMapStore

/// DEBUG screenshots of worn paths and frequent roads (`FERNLET_UI_TEST_WORLD_HOME=worn`): around the person, a
/// footpath at each level (well worn, worn, trodden, abandoned), and a road, a railway and a ferry wake at each level,
/// with their ground drawn clear. Display only: nothing is written, and release builds never ask (`UITestSupport.worldHomeScenes` is empty).
enum WornWaysTestScenes {
    /// Whether the scene shows (asked for, and not a decoy).
    static func isOn(decoy: Bool) -> Bool { UITestSupport.worldHomeScenes.contains("worn") && !decoy }

    /// The scene's footpaths: four straight lines through `here`, east, north, west and south, walked so each ends
    /// at a different level on `today`.
    static func paths(around here: GeoPoint) -> [(line: [GeoPoint], passes: Int, daysAgo: Int)] {
        [(line([here, here.offset(east: 140, north: 10), here.offset(east: 260, north: 90)]), 16, 0),
         (line([here, here.offset(east: -20, north: 150), here.offset(east: 40, north: 260)]), 6, 0),
         (line([here, here.offset(east: -150, north: -20), here.offset(east: -240, north: 60)]), 2, 0),
         (line([here, here.offset(east: 30, north: -150), here.offset(east: -40, north: -250)]), 3, 75)]
    }

    /// The scene's roads: four runs of cells south of the person, one per level; then the same four of railway north
    /// of the person, and four of ferry wake farther north.
    static func roads(around here: GeoPoint, today: UInt16) -> [WornWayKey: WornTally] {
        var ways: [WornWayKey: WornTally] = [:]
        let levels: [(count: UInt16, daysAgo: UInt16)] = [(4, 100), (4, 0), (12, 0), (40, 0)]
        let rows: [(kind: WornWayKind, north: Double)] = [(.road, -320), (.rail, 330), (.ferry, 450)]
        // Bounded: three rows of four ways of 300 m.
        for row in rows {
            for (index, level) in levels.enumerated() {
                let start = here.offset(east: -330 + Double(index) * 220, north: row.north)
                for cell in WornFootpaths.cells(along: line([start, start.offset(east: 180, north: -60)])) {
                    ways[WornWayKey(cell: cell, kind: row.kind)] = WornTally(count: level.count, lastDay: today &- level.daysAgo)
                }
            }
        }
        return ways
    }

    /// The scene's drawing on `today`, and the cells it draws clear.
    static func scene(around here: GeoPoint, today: UInt16) -> (drawing: WornWaysDrawing, cleared: Set<HexCell>) {
        var index = WornFootpathIndex()
        var routes: [(id: UUID, day: UInt16, line: [GeoPoint])] = []
        // Bounded: four paths of at most sixteen passes.
        for path in paths(around: here) {
            for pass in 0..<path.passes {
                routes.append((UUID(), today &- UInt16(path.daysAgo + path.passes - pass), path.line))
            }
        }
        for route in routes.sorted(by: { $0.day < $1.day }) { index.add(route.id, day: route.day, line: route.line) }
        let ways = roads(around: here, today: today)
        let drawing = WornWaysBuilder.make(index: index, ways: ways, today: today, trails: [], trailStamp: -2, generation: 1)
        let cleared = Set(index.tallies.keys).union(ways.keys.map(\.cell))
        return (drawing, Set(cleared.flatMap { [$0] + MercatorHexGrid.neighbours(of: $0) }))
    }

    /// `corners` filled in every 5 m.
    static func line(_ corners: [GeoPoint]) -> [GeoPoint] {
        var points: [GeoPoint] = []
        // Bounded: the corners, at most 200 points a leg.
        for (from, to) in zip(corners, corners.dropFirst()) {
            let steps = min(max(1, Int(from.distance(to: to) / 5)), 200)
            for step in 0..<steps { points.append(from.lerp(to: to, Double(step) / Double(steps))) }
        }
        return points + corners.suffix(1)
    }
}
