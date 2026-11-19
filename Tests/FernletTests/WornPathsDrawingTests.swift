import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Worn paths and frequent roads, the drawing lane (Docs/World-Frequent-Paths-Exploration-2026-11-15.md §3, §8): the
/// pieces each level draws from given tallies, the saved trail giving way where a worn path runs, the "Show worn paths"
/// switch, Your world's long roads only, and the map widget carrying them with a stamp that moves when they change.
@MainActor
struct WornPathsDrawingTests {
    nonisolated private static let here = GeoPoint(45.5205, -122.6255)
    nonisolated private static let today: UInt16 = 2_000

    /// A straight line `metres` east of `start`, a point every 2.5 m (as a saved line is thinned).
    nonisolated static func line(from start: GeoPoint = here, east metres: Double, north: Double = 0) -> [GeoPoint] {
        let steps = Int(max(abs(metres), abs(north)) / 2.5)
        return (0...steps).map { start.offset(east: metres * Double($0) / Double(steps), north: north * Double($0) / Double(steps)) }
    }

    /// An index of `line` walked `passes` times on one day, `daysAgo` days before ``today`` (one day, so the levels
    /// here don't lean on how a tally climbs across days; ``aTallyClimbsAcrossDays()`` covers that).
    nonisolated static func index(_ line: [GeoPoint], passes: Int, daysAgo: UInt16 = 0) -> WornFootpathIndex {
        var index = WornFootpathIndex()
        for _ in 0..<passes {
            index.add(UUID(), day: today - daysAgo, line: line)
        }
        return index
    }

    /// The road counter of the cells along `line` at `count` trips, the last `daysAgo` days ago.
    nonisolated static func roads(_ line: [GeoPoint], count: UInt16, daysAgo: UInt16 = 0) -> [WornWayKey: WornTally] {
        var ways: [WornWayKey: WornTally] = [:]
        for cell in WornFootpaths.cells(along: line) {
            ways[WornWayKey(cell: cell, kind: .road)] = WornTally(count: count, lastDay: today - daysAgo)
        }
        return ways
    }

    /// The drawing of `index` and `ways` on ``today``.
    nonisolated static func drawing(_ index: WornFootpathIndex = WornFootpathIndex(), ways: [WornWayKey: WornTally] = [:],
                                    trails: [[GeoPoint]] = []) -> WornWaysDrawing {
        WornWaysBuilder.make(index: index, ways: ways, today: today, trails: trails, trailStamp: 7, generation: 1)
    }

    // MARK: Pieces by level

    /// A footpath shows from its second trip, darkens at 5 and 15, and fades a level a month to abandoned; one trip
    /// draws nothing. Every piece is the person's own line, joined into a few strokes, not one per cell.
    @Test func footpathsDrawTheirLevelFromTheTallies() {
        let walk = Self.line(east: 300)
        #expect(Self.drawing(Self.index(walk, passes: 1)).footpaths.isEmpty, "one walk wears nothing")
        for (passes, level) in [(2, WornLevel.one), (5, .two), (15, .three)] {
            let pieces = Self.drawing(Self.index(walk, passes: passes)).footpaths
            #expect(!pieces.isEmpty)
            #expect(pieces.allSatisfy { $0.level == level }, "\(passes) passes")
            #expect(pieces.count <= 4, "joined into strokes, not one per cell: \(pieces.count)")
        }
        let faded = Self.drawing(Self.index(walk, passes: 5, daysAgo: 31)).footpaths
        #expect(faded.allSatisfy { $0.level == .one }, "a month idle drops one level")
        let abandoned = Self.drawing(Self.index(walk, passes: 2, daysAgo: 61)).footpaths
        #expect(!abandoned.isEmpty && abandoned.allSatisfy { $0.level == .abandoned }, "faded below 1: abandoned, kept")
        // The pieces lie on the walk: every point within a few metres of the line's latitude.
        let y = WebMercator.unit(Self.here).y, metre = WebMercator.unitsPerMetre(at: Self.here.latitude)
        let points = Self.drawing(Self.index(walk, passes: 2)).footpaths.flatMap(\.line.ys)
        #expect(points.allSatisfy { abs($0 - y) < 2 * metre })
    }

    /// A road shows from its third drive, brightens at 10 and 30, drawn along the smoothed spine of its cells (close
    /// to the drive, not a staircase of hex centres), and fades to abandoned; a lone cell draws nothing.
    @Test func roadsDrawTheirLevelAlongTheDrive() throws {
        let drive = Self.line(east: 400)
        #expect(Self.drawing(ways: Self.roads(drive, count: 2)).roads.isEmpty, "two drives: nothing")
        for (count, level) in [(UInt16(3), WornLevel.one), (10, .two), (30, .three)] {
            let roads = Self.drawing(ways: Self.roads(drive, count: count)).roads
            #expect(!roads.isEmpty)
            #expect(roads.allSatisfy { $0.level == level }, "\(count) drives")
        }
        #expect(Self.drawing(ways: Self.roads(drive, count: 3, daysAgo: 95)).roads.allSatisfy { $0.level == .abandoned })
        let piece = try #require(Self.drawing(ways: Self.roads(drive, count: 30)).roads.first)
        let y = WebMercator.unit(Self.here).y, metre = WebMercator.unitsPerMetre(at: Self.here.latitude)
        #expect(piece.line.ys.allSatisfy { abs($0 - y) < 12 * metre }, "every point within 12 m of the drive")
        let lone = [WornWayKey(cell: MercatorHexGrid.cell(containing: Self.here), kind: .road): WornTally(count: 40, lastDay: Self.today)]
        #expect(Self.drawing(ways: lone).roads.isEmpty)
        let rail = Dictionary(uniqueKeysWithValues: Self.roads(drive, count: 30).map { (WornWayKey(cell: $0.key.cell, kind: .rail), $0.value) })
        #expect(Self.drawing(ways: rail).roads.isEmpty, "a railway is not a road")
    }

    /// Two neighbouring roads at different levels meet at the lower one, and each level is one joined line.
    @Test func roadLinesJoinPerLevel() {
        let east = Self.roads(Self.line(east: 300), count: 30)
        let north = Self.roads(Self.line(from: Self.here.offset(east: 300, north: 0), east: 0, north: 300), count: 3)
        let ways = east.merging(north) { first, _ in first }
        let lines = WornWaysSmoothing.smoothedLines(WornWaysSmoothing.pooledLevels(ways, kind: .road, today: Self.today))
        #expect(Set(lines.map(\.level)) == [.one, .three])
        #expect(lines.count <= 6, "joined, not one per joint: \(lines.count)")
    }

    // MARK: Trails

    /// Where the saved green trail runs on a worn footpath it is cut out, so the map shows one line; the rest of it
    /// stays, and with nothing worn it is untouched. Home falls back to its own trails until a cut of them arrives.
    @Test func trailsGiveWayToWornPaths() {
        let worn = Self.line(east: 200)
        let trail = Self.line(east: 600)
        let drawing = Self.drawing(Self.index(worn, passes: 3), trails: [trail])
        let kept = drawing.trails.flatMap { $0 }
        #expect(!kept.isEmpty, "the stretch past the worn path stays")
        let wornCells = Set(WornFootpaths.cells(along: worn))
        #expect(drawing.trails.allSatisfy { run in
            zip(run, run.dropFirst()).allSatisfy { !wornCells.contains(MercatorHexGrid.cell(containing: $0.lerp(to: $1, 0.5))) }
        })
        #expect(kept.allSatisfy { Self.here.distance(to: $0) > 150 }, "nothing left over the first 200 m but its edge")
        #expect(Self.drawing(Self.index(worn, passes: 1), trails: [trail]).trails == [trail], "one walk wears nothing to cut")
        #expect(drawing.trails(for: [trail], stamp: 7) == drawing.trails)
        #expect(drawing.trails(for: [trail], stamp: 8) == [trail], "a stale cut is never drawn")
    }

    // MARK: The switch

    /// "Show worn paths" is on by default and cleared with the other map settings; off, the request shows nothing,
    /// and the model draws nothing and hands the trails back whole.
    @Test func theSwitchDefaultsOnAndOffDrawsNothing() async throws {
        let defaults = try #require(UserDefaults(suiteName: "WornPathsDrawingTests.\(UUID().uuidString)"))
        #expect(WorldMapPreferences.showWornPaths(in: defaults))
        WorldMapPreferences.setShowWornPaths(false, in: defaults)
        #expect(!WorldMapPreferences.showWornPaths(in: defaults))
        let store = makeTestStore()
        let trail = Self.line(east: 100)
        let request = store.wornWaysRequest(trails: [trail], trailStamp: 3, defaults: defaults)
        #expect(!request.shows && request.routeIDs.isEmpty && request.roads.isEmpty)
        let model = WornWaysModel()
        model.update(request, store: store)
        let drawn = try await Self.settle(model, past: 0)
        #expect(drawn.isEmpty)
        #expect(drawn.trails(for: [trail], stamp: 3) == [trail])
        #expect(store.worldWidgetMapContent(in: MapViewport.around(Self.here, heightMetres: 420, size: WorldWidgetMap.pictureSize),
                                            worn: drawn).worn.isEmpty)
        WorldMapPreferences.clearAll(in: defaults)
        #expect(WorldMapPreferences.showWornPaths(in: defaults))
        #expect(store.wornWaysRequest(trails: [], trailStamp: 0, defaults: defaults).shows)
        store.duressSessionActive = true
        #expect(!store.wornWaysRequest(trails: [], trailStamp: 0, defaults: defaults).shows, "a decoy shows none")
        store.duressSessionActive = false
    }

    /// End to end: two saved walks on one line, dated by their workouts, wear a footpath the model draws; with "Save
    /// new routes" off there are no lines to wear one.
    @Test func savedWalksWearAPath() async throws {
        let defaults = try #require(UserDefaults(suiteName: "WornPathsDrawingTests.\(UUID().uuidString)"))
        let store = makeTestStore()
        let first = try #require(Self.walk(store, defaults: defaults))
        let second = try #require(Self.walk(store, defaults: defaults))
        let days = store.wornRouteDays(for: [first.id, second.id])
        #expect(days[first.id] == WornDay.number(for: first.completedAt))
        #expect(store.wornRouteDays(for: [UUID()]).isEmpty, "a line with no workout is left out")
        let request = store.wornWaysRequest(trails: [], trailStamp: 0, defaults: defaults)
        #expect(request.routeIDs == [first.id, second.id])
        let model = WornWaysModel()
        model.update(request, store: store)
        let drawn = try await Self.settle(model, past: 0)
        #expect(!drawn.footpaths.isEmpty && drawn.footpaths.allSatisfy { $0.level == .one })
        WorldMapPreferences.setSaveNewRoutes(false, in: defaults)
        #expect(store.wornWaysRequest(trails: [], trailStamp: 0, defaults: defaults).routeIDs.isEmpty)
        model.update(store.wornWaysRequest(trails: [], trailStamp: 0, defaults: defaults), store: store)
        #expect(try await Self.settle(model, past: drawn.generation).footpaths.isEmpty)
    }

    // MARK: Your world

    /// Your world draws only frequent roads (level 1 or more) in runs of 2 km or longer; short runs, abandoned roads
    /// and footpaths never reach it.
    @Test func yourWorldDrawsLongRoadRunsOnly() {
        let long = Self.roads(Self.line(east: 2_600), count: 5)
        let short = Self.roads(Self.line(from: Self.here.offset(east: 0, north: 2_000), east: 900), count: 40)
        let faded = Self.roads(Self.line(from: Self.here.offset(east: 0, north: -2_000), east: 2_600), count: 5, daysAgo: 70)
        let drawing = WornWaysBuilder.yourWorldRoads(long.merging(short) { $1 }.merging(faded) { $1 }, today: Self.today, generation: 1)
        #expect(drawing.roadCount == 1, "only the long, current run")
        #expect(!drawing.pieces.isEmpty)
        let north = WebMercator.unit(Self.here.offset(east: 0, north: 500)).y, south = WebMercator.unit(Self.here.offset(east: 0, north: -500)).y
        #expect(drawing.pieces.allSatisfy { $0.minY > north && $0.maxY < south }, "only the long run's own cells")
        #expect(WornWaysBuilder.yourWorldRoads(short, today: Self.today, generation: 1).pieces.isEmpty)
    }

    // MARK: The widget

    /// The widget's picture carries the worn ways in its viewport (none outside it), and its stamp moves when they
    /// change level, not when the same ways are worked out again.
    @Test func theWidgetCarriesWornWaysAndItsStampMoves() {
        let store = makeTestStore()
        let viewport = MapViewport.around(Self.here, heightMetres: 420, size: WorldWidgetMap.pictureSize)
        let walk = Self.line(east: 150), drive = Self.line(from: Self.here.offset(east: 0, north: -80), east: 150)
        let worn = Self.drawing(Self.index(walk, passes: 5), ways: Self.roads(drive, count: 12))
        let content = store.worldWidgetMapContent(in: viewport, worn: worn)
        #expect(content.worn.contains { $0.isRoad && $0.level == .two })
        #expect(content.worn.contains { !$0.isRoad && $0.level == .two })
        #expect(content.worn.count <= WorldWidgetMapContent.maxWornLines)
        let elsewhere = MapViewport.around(Self.here.offset(east: 6_000, north: 0), heightMetres: 420, size: WorldWidgetMap.pictureSize)
        #expect(store.worldWidgetMapContent(in: elsewhere, worn: worn).worn.isEmpty)
        let bare = store.worldWidgetMapStamp()
        let stamped = store.worldWidgetMapStamp(worn: worn)
        #expect(stamped != bare)
        let again = WornWaysBuilder.make(index: Self.index(walk, passes: 5), ways: Self.roads(drive, count: 12), today: Self.today,
                                         trails: [], trailStamp: 0, generation: 9)
        #expect(store.worldWidgetMapStamp(worn: again) == stamped, "the same ways, worked out again: the same stamp")
        let worse = Self.drawing(Self.index(walk, passes: 15), ways: Self.roads(drive, count: 12))
        #expect(store.worldWidgetMapStamp(worn: worse) != stamped, "a path one level up moves it")
        store.duressSessionActive = true
        #expect(store.worldWidgetMapContent(in: viewport, worn: worn) == .empty)
        store.duressSessionActive = false
    }

    /// Known issue in the shared contract (`WornTally.pass`, lane-owned): a trip on a new day settles the count to its
    /// level's lowest even when nothing faded, so daily walks stick at 3 (level 1) and never reach 5 or 15. This test
    /// records it and fails once the contract is fixed, so it can drop `withKnownIssue`.
    @Test func aTallyClimbsAcrossDays() {
        var tally = WornTally.first(on: 100)
        for day in UInt16(101)...UInt16(115) { tally.pass(on: day, thresholds: .footpath) }
        #expect(tally.count == 16)
        #expect(tally.level(today: 115, thresholds: .footpath) == .three)
    }

    // MARK: Bounds and cost

    /// A long history stays bounded and quick: 400 lines of 5 km fold in and draw within the caps (the time is
    /// printed for the record; the gate is a Release run on the phone).
    @Test func aLongHistoryStaysBounded() {
        let started = ContinuousClock.now
        var index = WornFootpathIndex()
        for route in 0..<400 {
            let start = Self.here.offset(east: Double(route % 20) * 40, north: Double(route / 20) * 40)
            index.add(UUID(), day: Self.today - 400 + UInt16(route), line: Self.line(from: start, east: 2_500, north: 2_500))
        }
        let folded = ContinuousClock.now
        let drawing = WornWaysBuilder.make(index: index, ways: [:], today: Self.today, trails: [], trailStamp: 0, generation: 1)
        let built = ContinuousClock.now
        print("worn ways timing: fold 400 × 5 km lines \(folded - started), draw \(built - folded), "
              + "\(index.fragments.count) cells kept, \(drawing.footpaths.count) pieces")
        #expect(index.fragments.count <= WornFootpathIndex.maxCells)
        #expect(drawing.footpaths.count <= WornWaysDrawing.maxPieces)
        #expect(index.fragments.values.allSatisfy { $0.offsets.count <= WornFootpathIndex.maxFragmentPoints * 2 })
    }

    // MARK: Helpers

    /// The model's drawing once one newer than `generation` has landed (at most two seconds).
    private static func settle(_ model: WornWaysModel, past generation: Int) async throws -> WornWaysDrawing {
        for _ in 0..<200 where model.drawing.generation <= generation {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.drawing.generation > generation, "the model never landed a drawing")
        return model.drawing
    }

    /// A 300 m walk east from ``here``, recorded and finished at midday today.
    private static func walk(_ store: FernletStore, defaults: UserDefaults) -> Workout? {
        let start = middayToday()
        store.startWorldWalk(at: start)
        for east in stride(from: 0.0, through: 300, by: 2.5) {
            store.worldWalk.record(WorldFix(point: here.offset(east: east, north: 0), accuracy: 5, at: start, isPrecise: true))
        }
        return store.finishWorldWalk(at: start.addingTimeInterval(240), defaults: defaults)
    }
}
