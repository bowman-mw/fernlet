import Foundation
import SwiftUI
import Testing
import UIKit
import WorldMapStore
@testable import Fernlet

/// Smooth and pooled worn ways (owner 2026-11-19: "they're wavy ... they are discontinuous"; picked option A): a
/// synthetic frequent road in Portland, 2 km at 20° east of north with one right-angle turn, driven ten times (and
/// five) with GPS noise, counted exactly as the app counts a drive. The road drawn by ``WornWaysBuilder`` must lie
/// close to the true road, cover it end to end, and be one chain with no braid. The renders (the app's own
/// ``WornWaysPainter``) go to the test's temporary folder, or to `$FERNLET_WORN_RENDER_DIR` when it is set (pass it as
/// `TEST_RUNNER_FERNLET_WORN_RENDER_DIR` to xcodebuild); "before" is the drawing until 2026-11-19, kept here
/// (``legacyPieces(_:)``) only to render and measure beside it. A last test bounds the build time on a large history.
@MainActor
struct WornPathsSmoothingTests {
    nonisolated static let today: UInt16 = 2_000

    /// Where the renders go.
    nonisolated static var outputFolder: URL {
        if let folder = ProcessInfo.processInfo.environment["FERNLET_WORN_RENDER_DIR"], !folder.isEmpty {
            return URL(fileURLWithPath: folder)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("worn-smooth")
    }

    // MARK: Scene

    /// A seeded generator (SplitMix64), so every run is the same.
    nonisolated struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// A normal sample (Box–Muller).
        mutating func gaussian() -> Double {
            let u = Double.random(in: Double.ulpOfOne..<1, using: &self), v = Double.random(in: 0..<1, using: &self)
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    /// A road: its corners in metres east and north of `origin`.
    nonisolated struct Road {
        let origin: GeoPoint
        let corners: [(east: Double, north: Double)]

        /// A road `first` metres on `bearing` (degrees from north), then `second` metres after a 90° right turn.
        init(origin: GeoPoint, bearing: Double, first: Double, second: Double) {
            self.origin = origin
            let a = bearing * .pi / 180, b = (bearing + 90) * .pi / 180
            let corner = (east: first * sin(a), north: first * cos(a))
            corners = [(0, 0), corner, (corner.east + second * sin(b), corner.north + second * cos(b))]
        }

        var length: Double { zip(corners, corners.dropFirst()).reduce(0) { $0 + hypot($1.1.east - $1.0.east, $1.1.north - $1.0.north) } }

        /// The point `s` metres along, and the way the road runs there (a unit vector).
        func at(_ s: Double) -> (east: Double, north: Double, dirE: Double, dirN: Double) {
            var left = s
            for (index, (a, b)) in zip(corners, corners.dropFirst()).enumerated() {
                let length = hypot(b.east - a.east, b.north - a.north)
                let dirE = (b.east - a.east) / length, dirN = (b.north - a.north) / length
                if left <= length || index == corners.count - 2 { return (a.east + dirE * left, a.north + dirN * left, dirE, dirN) }
                left -= length
            }
            return (0, 0, 0, 1)
        }

        /// The true road as places.
        var line: [GeoPoint] { corners.map { origin.offset(east: $0.east, north: $0.north) } }

        /// One drive: a reading every 25 m from a random start, in a lane 0–4 m right of the centre line, with
        /// σ 6 m of GPS noise across the road.
        func drive(_ random: inout Seeded) -> [GeoPoint] {
            let lane = Double.random(in: 0...4, using: &random)
            var points: [GeoPoint] = []
            for s in stride(from: Double.random(in: 0..<25, using: &random), through: length, by: 25) {
                let p = at(s), across = lane + 6 * random.gaussian()
                points.append(origin.offset(east: p.east + p.dirN * across, north: p.north - p.dirE * across))
            }
            return points
        }
    }

    /// The owner's screenshot's area: a road 1.2 km at 20° east of north, then 0.8 km after a right turn.
    nonisolated static let road = Road(origin: GeoPoint(45.4655, -122.6505), bearing: 20, first: 1_200, second: 800)

    /// `count` drives of ``road``, one a day up to ``today``.
    nonisolated static func drives(_ count: Int, seed: UInt64 = 7) -> [(day: UInt16, line: [GeoPoint])] {
        var random = Seeded(state: seed)
        return (0..<count).map { (today - UInt16(count - $0), road.drive(&random)) }
    }

    /// The road counter of `drives`, counted as the app counts a ride (each drive's cells once, oldest first).
    nonisolated static func ways(_ drives: [(day: UInt16, line: [GeoPoint])]) -> [WornWayKey: WornTally] {
        var ways: [WornWayKey: WornTally] = [:]
        for drive in drives.sorted(by: { $0.day < $1.day }) {
            for cell in WornFootpaths.cells(along: drive.line) {
                let key = WornWayKey(cell: cell, kind: .road)
                if var tally = ways[key] {
                    tally.pass(on: drive.day, thresholds: .road)
                    ways[key] = tally
                } else {
                    ways[key] = .first(on: drive.day)
                }
            }
        }
        return ways
    }

    /// The drawing of `drives` on ``today``.
    nonisolated static func drawing(_ drives: [(day: UInt16, line: [GeoPoint])]) -> WornWaysDrawing {
        WornWaysBuilder.make(index: WornFootpathIndex(), ways: ways(drives), today: today, trails: [], trailStamp: 0, generation: 1)
    }

    /// The road drawing until 2026-11-19, for the "before" renders and measures only: hex centre to hex centre
    /// along the raw counter's spine, joined per level.
    nonisolated static func legacyPieces(_ ways: [WornWayKey: WornTally]) -> [WornPiece] {
        let levels = WornWaysBuilder.wayLevels(ways, kind: .road, today: today)
        var next: [HexCell: [HexCell]] = [:]
        for joint in WornWaysBuilder.spine(levels) {
            next[joint.a, default: []].append(joint.b)
            next[joint.b, default: []].append(joint.a)
        }
        var used = Set<WornWaysBuilder.Edge>()
        func extend(_ from: HexCell, level: WornLevel) -> [HexCell] {
            var cells: [HexCell] = [], tip = from
            for _ in 0..<levels.count {
                guard let mine = levels[tip], let step = next[tip]?.first(where: { candidate in
                    levels[candidate].map { min(mine, $0) == level } == true && !used.contains(WornWaysBuilder.Edge(tip, candidate))
                }) else { break }
                used.insert(WornWaysBuilder.Edge(tip, step))
                cells.append(step)
                tip = step
            }
            return cells
        }
        var pieces: [WornPiece] = []
        for cell in next.keys.sorted(by: { (next[$0]?.count ?? 0, $0) < (next[$1]?.count ?? 0, $1) }) {
            for other in next[cell] ?? [] {
                guard let mine = levels[cell], let theirs = levels[other], used.insert(WornWaysBuilder.Edge(cell, other)).inserted else { continue }
                let level = min(mine, theirs)
                let forward = extend(other, level: level), backward = extend(cell, level: level)
                let cells = backward.reversed() + [cell, other] + forward
                pieces += WornWaysBuilder.chunks(cells.map { MercatorHexGrid.centre(of: $0) }, level: level)
            }
        }
        return pieces
    }

    // MARK: Measures

    /// How far `point` (Mercator) is from the true road, in metres.
    nonisolated static func offRoad(_ point: (x: Double, y: Double)) -> Double {
        let m = WebMercator.geo(x: point.x, y: point.y).metres(from: road.origin)
        return zip(road.corners, road.corners.dropFirst()).map { a, b in
            let dx = b.east - a.east, dy = b.north - a.north
            let t = max(0, min(1, ((m.east - a.east) * dx + (m.north - a.north) * dy) / (dx * dx + dy * dy)))
            return hypot(m.east - (a.east + t * dx), m.north - (a.north + t * dy))
        }.min() ?? 0
    }

    /// The RMS distance of `pieces`' points from the true road, in metres, and the metres of true road (its start and
    /// end included) with no drawn line within `reach` metres (by default a hex cell's radius, 17.5 m, rounded up: the
    /// counter can't place a road closer than its cells, and drives cut a right-angle corner by about that much).
    nonisolated static func measures(_ pieces: [WornPiece], reach: Double = 20) -> (rms: Double, uncovered: Double) {
        var squares = 0.0, points = 0
        var drawn: [(x: Double, y: Double)] = []
        for piece in pieces {
            let xs = piece.line.xs, ys = piece.line.ys
            for index in xs.indices {
                let off = offRoad((xs[index], ys[index]))
                squares += off * off
                points += 1
                drawn.append((xs[index], ys[index]))
                guard index > 0 else { continue }
                // Long segments filled in, so the cover check sees them.
                let a = WebMercator.geo(x: xs[index - 1], y: ys[index - 1]), b = WebMercator.geo(x: xs[index], y: ys[index])
                let steps = Int(a.distance(to: b) / 5)
                for step in stride(from: 1, to: steps, by: 1) {
                    let t = Double(step) / Double(steps)
                    drawn.append((xs[index - 1] + (xs[index] - xs[index - 1]) * t, ys[index - 1] + (ys[index] - ys[index - 1]) * t))
                }
            }
        }
        let perMetre = WebMercator.unitsPerMetre(at: road.origin.latitude)
        var uncovered = 0.0
        for s in stride(from: 0.0, through: road.length, by: 5) {
            let p = road.at(s), here = WebMercator.unit(road.origin.offset(east: p.east, north: p.north))
            if !drawn.contains(where: { hypot($0.x - here.x, $0.y - here.y) < reach * perMetre }) { uncovered += 5 }
        }
        return (points > 0 ? (squares / Double(points)).squareRoot() : .infinity, uncovered)
    }

    // MARK: The road

    /// Ten drives (and five): the road lies within 7 m RMS of the true road at ten and closer than the hex staircase
    /// did, leaves under 60 m of its 2 km uncovered (the start included; ``measures(_:reach:)``), and is one chain of
    /// lines meeting end to end, one line per level run, no braid.
    @Test(arguments: [10, 5])
    func aNoisyRoadDrawsSmoothAndWhole(drives count: Int) throws {
        let drives = Self.drives(count)
        let ways = Self.ways(drives)
        let lines = WornWaysSmoothing.smoothedLines(WornWaysSmoothing.pooledLevels(ways, kind: .road, today: Self.today),
                                                    weights: WornWaysSmoothing.weights(ways, kind: .road))
        let (rms, uncovered) = Self.measures(Self.drawing(drives).roads)
        let before = Self.measures(Self.legacyPieces(ways))
        let strict = Self.measures(Self.drawing(drives).roads, reach: 15).uncovered
        print("WORN-SMOOTH \(count) drives: rms \(rms) m (before \(before.rms)), uncovered \(uncovered) m within 20 m " +
              "(before \(before.uncovered); within 15 m \(strict)), lines \(lines.count)")
        if count == 10 { #expect(rms < 7, "rms off road \(rms) m") }
        #expect(rms < before.rms, "closer than the hex staircase")
        #expect(uncovered < 60, "uncovered \(uncovered) m of 2,000")
        #expect(Set(lines.map(\.chain)).count == 1, "one chain, no braid: \(lines.count) lines")
        for (a, b) in zip(lines, lines.dropFirst()) {
            let end = try #require(a.points.last), start = try #require(b.points.first)
            #expect(end == start, "each level run starts where the last ended")
            #expect(a.level != b.level, "one line per level run")
        }
    }

    /// A side street that leaves the road stays however short (pruning takes only branches running alongside): a
    /// 120 m street off the middle of a well-driven road still draws to its end.
    @Test func aShortSideStreetStays() {
        var ways: [WornWayKey: WornTally] = [:]
        let main = WornPathsDrawingTests.line(from: Self.road.origin, east: 800)
        let side = WornPathsDrawingTests.line(from: Self.road.origin.offset(east: 400, north: 0), east: 0, north: 120)
        for cell in WornFootpaths.cells(along: main).union(WornFootpaths.cells(along: side)) {
            ways[WornWayKey(cell: cell, kind: .road)] = WornTally(count: 12, lastDay: Self.today)
        }
        let lines = WornWaysSmoothing.smoothedLines(WornWaysSmoothing.pooledLevels(ways, kind: .road, today: Self.today))
        let reach = WebMercator.unit(Self.road.origin.offset(east: 400, north: 90)).y
        #expect(lines.contains { line in line.points.contains { $0.y < reach } }, "the side street reaches 90 m north")
    }

    // MARK: Renders

    /// Renders the drawing before and after at 10 and 5 drives, about 1.5 km across a 390 pt view at @3x, and the
    /// corner at Home's own zoom (about 500 m across).
    @Test func rendersBeforeAndAfter() throws {
        try FileManager.default.createDirectory(at: Self.outputFolder, withIntermediateDirectories: true)
        let size = CGSize(width: 390, height: 844)
        let geo = Self.road.line
        let centre = GeoPoint((geo.map(\.latitude).min()! + geo.map(\.latitude).max()!) / 2,
                              (geo.map(\.longitude).min()! + geo.map(\.longitude).max()!) / 2)
        let tall = Double(size.height / size.width)
        let views = [("", MapViewport.around(centre, heightMetres: 1_500 * tall, size: size)),
                     ("-close", MapViewport.around(geo[1].offset(east: -60, north: -250), heightMetres: 500 * tall, size: size))]
        for count in [10, 5] {
            let drives = Self.drives(count)
            let before = WornWaysDrawing(generation: 1, footpaths: [], roads: Self.legacyPieces(Self.ways(drives)), trails: [],
                                         trailStamp: 0, contentHash: 0)
            for (name, drawing, title) in [("before", before, "Before"), ("after", Self.drawing(drives), "After")] {
                for (suffix, viewport) in views {
                    let file = "\(name)\(count == 10 ? "" : "-5")\(suffix).png"
                    let data = try #require(render(drawing, viewport: viewport, size: size, title: "\(title) · \(count) drives"))
                    try data.write(to: Self.outputFolder.appendingPathComponent(file))
                }
            }
        }
        print("WORN-SMOOTH renders in \(Self.outputFolder.path)")
    }

    /// `drawing` painted by the app's own ``WornWaysPainter`` over a pale ground with the true road faint underneath.
    private func render(_ drawing: WornWaysDrawing, viewport: MapViewport, size: CGSize, title: String) -> Data? {
        let truth = Self.road.line.map { WebMercator.unit($0) }.map { viewport.screenPoint(x: $0.x, y: $0.y, in: size) }
        let renderer = ImageRenderer(content: Canvas { context, canvasSize in
            context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(Color(red: 0.95, green: 0.94, blue: 0.90)))
            var road = Path()
            road.addLines(truth)
            context.stroke(road, with: .color(Color(white: 0.55).opacity(0.7)), style: StrokeStyle(lineWidth: 0.6))
            WornWaysPainter.draw(drawing, in: &context, size: canvasSize, viewport: viewport, dark: false, highContrast: false)
            context.draw(Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.black),
                         at: CGPoint(x: 16, y: 70), anchor: .leading)
        }.frame(width: size.width, height: size.height))
        renderer.scale = 3
        return renderer.uiImage?.pngData()
    }

    // MARK: Timing

    /// The build stays cheap on a large history: 2,000 drives over 20 roads (100 each, over a year) worked out by
    /// ``WornWaysBuilder/make(index:ways:today:trails:trailStamp:generation:)`` in under a second even in a Debug
    /// build (best of three).
    @Test func aLargeHistoryBuildsQuickly() {
        var random = Seeded(state: 99)
        var drives: [(day: UInt16, line: [GeoPoint])] = []
        for index in 0..<20 {
            let origin = Self.road.origin.offset(east: Double(index % 5) * 3_000, north: Double(index / 5) * 3_000)
            let road = Road(origin: origin, bearing: Double.random(in: 0..<360, using: &random), first: 1_200, second: 800)
            for _ in 0..<100 { drives.append((Self.today - UInt16.random(in: 0..<365, using: &random), road.drive(&random))) }
        }
        let ways = Self.ways(drives)
        let clock = ContinuousClock()
        var fastest = Duration.seconds(60)
        var pieces = 0
        for _ in 0..<3 {
            var drawing = WornWaysDrawing.none
            let time = clock.measure {
                drawing = WornWaysBuilder.make(index: WornFootpathIndex(), ways: ways, today: Self.today, trails: [], trailStamp: 0, generation: 1)
            }
            fastest = min(fastest, time)
            pieces = drawing.roads.count
        }
        print("WORN-SMOOTH 2,000 drives over 20 roads (\(ways.count) cells): make in \(fastest), \(pieces) road pieces")
        #expect(pieces > 0)
        #expect(fastest < .seconds(1), "make took \(fastest)")
    }
}
