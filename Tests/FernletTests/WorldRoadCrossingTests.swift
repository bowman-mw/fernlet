import CoreGraphics
import Foundation
import SwiftUI
import Testing
import WorldMapStore
@testable import Fernlet

/// The major roads (World-Exploration-Spec §2, `ex-roads`): the crossing rule read from the fog history (a lifted
/// cell on a road's line counts it; nothing is stored, so a decoy and a wipe follow), its bounded, cached work, the
/// pieces and the clipped drawing (the W-20 guard), the world view's level rule and widths, and the city card's row.
@MainActor
struct WorldRoadCrossingTests {
    /// I-5 through Portland (the pack's own crossing rule finds it west to east at 45.50°N), and the point where its
    /// line meets 45.50°N with the line's direction there (east, north, in metres per unit).
    static func interstate5(_ atlas: WorldAtlas) throws -> (road: AtlasRoad, point: GeoPoint, along: (Double, Double)) {
        let crossed = atlas.roadsCrossed(from: GeoPoint(45.50, -122.70), to: GeoPoint(45.50, -122.65))
        let road = try #require(crossed.first)
        for index in 0..<road.lineCount {
            let line = road.line(index)
            for (a, b) in zip(line, line.dropFirst()) where (a.latitude - 45.5) * (b.latitude - 45.5) <= 0 && a.latitude != b.latitude {
                let t = (45.5 - a.latitude) / (b.latitude - a.latitude)
                let longitude = a.longitude + (b.longitude - a.longitude) * t
                guard longitude > -122.70, longitude < -122.65 else { continue }
                let east = (b.longitude - a.longitude) * GeoPoint.metresPerDegree * cos(45.5 * .pi / 180)
                let north = (b.latitude - a.latitude) * GeoPoint.metresPerDegree
                let length = max((east * east + north * north).squareRoot(), 1e-9)
                return (road, GeoPoint(45.5, longitude), (east / length, north / length))
            }
        }
        throw RoadTestError.notFound
    }

    enum RoadTestError: Error { case notFound }

    // MARK: The rule

    /// A lifted cell on I-5 in Portland counts it; a cell 200 m off its line (across it) does not; no cells, none.
    @Test func aLiftedCellOnTheLineCountsTheRoad() throws {
        let atlas = try WorldExploreTests.shippedAtlas()
        let i5 = try Self.interstate5(atlas)
        let on = AtlasRoadCrossings(cells: [MercatorHexGrid.cell(containing: i5.point)], atlas: atlas)
        #expect(on.tokens(in: atlas).contains(i5.road.token), "a cell on I-5")
        #expect(i5.road.kind == .highway)
        for side in [-1.0, 1.0] {
            let off = i5.point.offset(east: side * 200 * i5.along.1, north: -side * 200 * i5.along.0)
            let crossings = AtlasRoadCrossings(cells: [MercatorHexGrid.cell(containing: off)], atlas: atlas)
            #expect(!crossings.tokens(in: atlas).contains(i5.road.token), "200 m off I-5 (side \(side))")
        }
        #expect(AtlasRoadCrossings(cells: [], atlas: atlas).isEmpty)
        #expect(AtlasRoadCrossings(cells: [MercatorHexGrid.cell(containing: GeoPoint(23.0, 10.0))], atlas: atlas).isEmpty,
                "the Sahara has no major road")
    }

    /// A walk across Portland (the roads screenshot's) crosses I-5 and I-84: each road once, and two roads (the pack
    /// joins only the straightest pair where a named route branches three ways, so I-84 is no longer part of I-5).
    @Test func aWalkAcrossPortlandCrossesBothInterstates() throws {
        let atlas = try WorldExploreTests.shippedAtlas()
        let crossed = AtlasRoadCrossings(cells: WorldRoadTestScenes.cells, atlas: atlas)
        let i5 = try Self.interstate5(atlas).road
        let i84 = try #require(atlas.roadsCrossed(from: GeoPoint(45.52, -122.62), to: GeoPoint(45.56, -122.62)).first)
        let tokens = crossed.tokens(in: atlas)
        #expect(tokens.contains(i5.token) && tokens.contains(i84.token))
        #expect(i5.token != i84.token, "I-84 is its own road")
        #expect(Set(crossed.roadIndices).count == crossed.roadIndices.count && crossed.roadIndices == crossed.roadIndices.sorted())
    }

    /// Updating with more cells gives what a fresh reading gives; fewer cells (the history wiped, a decoy's own) drop
    /// the roads only they crossed; no cells empty it.
    @Test func updatesFollowTheCells() throws {
        let atlas = try WorldExploreTests.shippedAtlas()
        let walk = WorldRoadTestScenes.cells
        let i5 = try Self.interstate5(atlas)
        let elsewhere = Set(MercatorHexGrid.cells(around: GeoPoint(47.6062, -122.3321), within: 50))
        var kept = AtlasRoadCrossings()
        kept.update(cells: walk, atlas: atlas)
        kept.update(cells: walk.union(elsewhere), atlas: atlas)
        #expect(kept.roadIndices == AtlasRoadCrossings(cells: walk.union(elsewhere), atlas: atlas).roadIndices)
        kept.update(cells: [MercatorHexGrid.cell(containing: i5.point)], atlas: atlas)
        #expect(kept.tokens(in: atlas) == AtlasRoadCrossings(cells: [MercatorHexGrid.cell(containing: i5.point)], atlas: atlas).tokens(in: atlas))
        kept.update(cells: [], atlas: atlas)
        #expect(kept.isEmpty)
    }

    /// Through the fog keeper: a reading on I-5 crosses it; a decoy shows none (its own cells only); leaving the
    /// decoy brings the history back; a wipe empties it. Nothing of the roads is stored anywhere.
    @Test func aDecoyAndAWipeFollowTheFog() throws {
        let atlas = try WorldExploreTests.shippedAtlas()
        let i5 = try Self.interstate5(atlas)
        let defaults = try #require(UserDefaults(suiteName: "WorldRoadCrossingTests.\(UUID().uuidString)"))
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = WorldFogKeeper(vault: vault, defaults: defaults, isProtectedDataAvailable: { true })
        keeper.load()
        #expect(keeper.handle(WorldFix(point: i5.point, accuracy: 10, at: Date(), isPrecise: true)) > 0)
        func crossed() -> Set<String> { AtlasRoadCrossings(cells: keeper.visibleCells, atlas: atlas).tokens(in: atlas) }
        #expect(crossed().contains(i5.road.token))
        keeper.setDecoy(true)
        #expect(crossed().isEmpty, "a decoy shows no crossed road")
        keeper.setDecoy(false)
        #expect(crossed().contains(i5.road.token))
        #expect(keeper.clearAll())
        #expect(crossed().isEmpty, "the wipe takes the crossed roads with the fog")
    }

    /// Bounded: the cap is the fog store's own, the buckets are fixed, and a 9-km walk's 1,200-odd cells are read
    /// quickly.
    @Test func theWorkIsBounded() throws {
        let atlas = try WorldExploreTests.shippedAtlas()
        #expect(AtlasRoadCrossings.maxCells == FogCellStore.maxCells)
        #expect(AtlasRoadCrossings.fineSide == 32)
        let cells = WorldRoadTestScenes.cells
        #expect(cells.count > 1_000)
        let start = Date()
        _ = AtlasRoadCrossings(cells: cells, atlas: atlas)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    /// Home's model works the drawing out off the main actor and empties it with the cells.
    @Test func homesModelFollowsTheCells() async throws {
        let atlas = try WorldExploreTests.shippedAtlas()
        let model = WorldCrossedRoadsModel()
        model.update(cells: WorldRoadTestScenes.cells, atlas: atlas)
        try await Self.wait { model.drawing.roadCount >= 1 }
        #expect(!model.drawing.pieces.isEmpty)
        model.update(cells: [], atlas: atlas)
        try await Self.wait { model.drawing.roadCount == 0 }
        #expect(model.drawing.pieces.isEmpty)
    }

    /// Waits up to a minute for `condition` (the work runs at utility priority beside the other suites).
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1_200 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition())
    }

    // MARK: Drawing

    /// A road's lines are cut into pieces of at most 48 points that share their ends, each with its box.
    @Test func piecesCoverTheLines() throws {
        let atlas = try WorldExploreTests.shippedAtlas()
        let road = try Self.interstate5(atlas).road
        let drawing = WorldRoadDrawing.make(roads: [road], generation: 3)
        #expect(drawing.generation == 3 && drawing.roadCount == 1)
        #expect(drawing.pieces.allSatisfy { $0.xs.count <= WorldRoadDrawing.maxPiecePoints && $0.xs.count >= 2 })
        let points = (0..<road.lineCount).reduce(0) { $0 + road.line($1).count }
        #expect(drawing.pieces.reduce(0) { $0 + $1.xs.count - 1 } == points - road.lineCount, "every segment once")
        for piece in drawing.pieces {
            #expect(piece.xs.allSatisfy { $0 >= piece.minX && $0 <= piece.maxX })
            #expect(piece.ys.allSatisfy { $0 >= piece.minY && $0 <= piece.maxY })
        }
        #expect(WorldRoadDrawing.make(roads: [road], generation: 3) == drawing, "compares by generation")
    }

    /// W-20: a segment far off screen is clipped to the guard's reach, one wholly outside or not finite is dropped,
    /// and the drawn path never leaves that reach however far the road runs.
    @Test func roadsAreClippedToTheLayerGuard() throws {
        let size = CGSize(width: 402, height: 874)
        let limit = WorldLayerGuard.viewMultiple * 874
        let reach = CGRect(origin: .zero, size: size).insetBy(dx: -limit, dy: -limit)
        let clipped = try #require(WorldRoadPainter.clip(CGPoint(x: -1e7, y: 400), CGPoint(x: 1e7, y: 400), to: reach))
        #expect(clipped.0.x == reach.minX && clipped.1.x == reach.maxX && clipped.0.y == 400)
        #expect(WorldRoadPainter.clip(CGPoint(x: -1e7, y: -1e7), CGPoint(x: -9e6, y: -1e7), to: reach) == nil)
        #expect(WorldRoadPainter.clip(CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 10, y: 10), to: reach) == nil)
        let atlas = try WorldExploreTests.shippedAtlas()
        let i5 = try Self.interstate5(atlas)
        let drawing = WorldRoadDrawing.make(roads: [i5.road], generation: 1)
        let viewport = MapViewport.around(i5.point, heightMetres: 300, size: size)
        let projection = WorldRoadPainter.Projection(originX: viewport.minX, originY: viewport.minY,
                                                     scale: Double(size.width) / viewport.width)
        let path = WorldRoadPainter.path(drawing.pieces, size: size, projection: projection)
        #expect(!path.isEmpty)
        #expect(reach.insetBy(dx: -1, dy: -1).contains(path.boundingRect))
    }

    /// The world view draws crossed roads from Country in, wider closer in, a main road half a point thinner from
    /// State; Home's are 5 pt, 4 pt a step out; the style's colours are the mockup's.
    @Test func theWorldViewLevelRuleAndWidths() {
        #expect(!WorldRoadStyle.showsRoads(at: .world))
        #expect(WorldRoadStyle.showsRoads(at: .country) && WorldRoadStyle.showsRoads(at: .state) && WorldRoadStyle.showsRoads(at: .city))
        #expect(WorldRoadStyle.worldWidth(at: .country, kind: .highway) == 2.5)
        #expect(WorldRoadStyle.worldWidth(at: .state, kind: .highway) == 3)
        #expect(WorldRoadStyle.worldWidth(at: .city, kind: .highway) == 3.5)
        #expect(WorldRoadStyle.worldWidth(at: .city, kind: .mainRoad) == 3)
        #expect(WorldRoadStyle.worldWidth(at: .country, kind: .mainRoad) == 2.5)
        #expect(WorldRoadStyle.homeWidth == 5 && WorldRoadStyle.homeZoomedOutWidth == 4 && WorldRoadStyle.edgeExtra == 2.5)
        #expect(WorldRoadStyle.amber == 0xE2A33A && WorldRoadStyle.ink == 0x4A2E1C && WorldRoadStyle.dash == 0xFFE7A8)
        #expect(WorldRoadStyle.dashPattern == [4, 5])
    }

    // MARK: The city card

    /// The card's "Major roads crossed" counts the roads crossed inside the city: the walk across Portland's count is
    /// the roads its cells inside the city's area lie on (at least one: a crossing outside Natural Earth's coarse urban
    /// outline counts for no city); no lifted cells, none; a walk elsewhere counts nothing for Portland.
    @Test func theCityCardCountsRoadsCrossedInTheCity() async throws {
        let atlas = try WorldExploreTests.shippedAtlas()
        let portland = try #require(atlas.city(at: WorldExploreTests.portland))
        let area = WorldCityUncovered.area(of: portland, in: atlas)
        let inside = WorldCityUncovered.insideCells(area, lifted: WorldRoadTestScenes.cells)
        let expected = AtlasRoadCrossings(cells: inside, atlas: atlas).count
        #expect(expected >= 1 && inside.count <= WorldRoadTestScenes.cells.count)
        #expect(WorldCityUncovered.roadsCrossed(in: area, lifted: WorldRoadTestScenes.cells, atlas: atlas) == expected)
        #expect(WorldCityUncovered.roadsCrossed(in: area, lifted: [], atlas: atlas) == 0)
        let seattle = Set(MercatorHexGrid.cells(around: GeoPoint(47.6062, -122.3321), within: 400))
        #expect(WorldCityUncovered.roadsCrossed(in: area, lifted: seattle, atlas: atlas) == 0)
        let cache = WorldCityUncoveredCache()
        let first = await cache.roadsCrossed(in: portland, atlas: atlas, lifted: WorldRoadTestScenes.cells)
        #expect(first == expected)
        #expect(await cache.roadsCrossed(in: portland, atlas: atlas, lifted: WorldRoadTestScenes.cells) == first)
        #expect(WorldExploreCopy.roadsCrossed(4) == 4.formatted() && WorldExploreCopy.roadsCrossed(-1) == 0.formatted())
    }

    /// The card shows the row between Landmarks and Uncovered, and its doc no longer calls roads missing.
    @Test func theCityCardHasTheRow() throws {
        let source = try String(contentsOf: RepoRoot.url.appending(path: "App/Fernlet/World/Home/WorldCityCard.swift"), encoding: .utf8)
        let landmarks = try #require(source.range(of: "FernletKeyValueRow(\"Landmarks\""))
        let roads = try #require(source.range(of: "FernletKeyValueRow(\"Major roads crossed\""))
        let uncovered = try #require(source.range(of: "FernletKeyValueRow(\"Uncovered\""))
        #expect(landmarks.lowerBound < roads.lowerBound && roads.lowerBound < uncovered.lowerBound)
        #expect(!source.contains("no road data"))
    }
}
