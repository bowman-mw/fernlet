import Foundation
import Testing
import FernletDomainModel
import WorldMapStore
@testable import Fernlet

/// The World map's saved walk lines (World app plan step 5b): the codec, the sealed store, the walk
/// recorder, and a finished walk becoming a logged workout with (or without) its line.
@MainActor
struct WorldRouteTests {
    /// A wiggly 1.2 km walk east of Laurelhurst Park: a point every 2 m, drifting 0.4 m north and south.
    private static func walkPoints() -> [RoutePoint] {
        let origin = GeoPoint(45.5205, -122.6255)
        return (0..<600).map { index in
            RoutePoint(origin.offset(east: Double(index) * 2, north: index.isMultiple(of: 2) ? 0.4 : -0.4), altitude: 40)
        }
    }

    /// The codec thins a nearly straight line to its ends, keeps every point within its tolerance and
    /// quantisation, and refuses bytes that are not its format.
    @Test func theCodecThinsAndRoundTripsWithinTolerance() throws {
        let points = Self.walkPoints()
        let decoded = try #require(WorldRouteCodec.decode(WorldRouteCodec.encode(points)))
        #expect(decoded.count < 10, "a nearly straight line keeps only a few points, got \(decoded.count)")
        #expect(try #require(decoded.first).point.distance(to: points[0].point) < 1.5)
        #expect(try #require(decoded.last).point.distance(to: try #require(points.last).point) < 1.5)
        #expect(decoded.allSatisfy { abs(($0.altitude ?? 0) - 40) <= 0.25 })
        // The raw path's ±0.4 m zigzag adds about 92 m of jitter; the thinned line is the walk itself.
        #expect(abs(WorldRouteCodec.length(of: decoded) - 1_198) < 5)
        #expect(WorldRouteCodec.decode(Data([9, 0])) == nil, "another version")
        #expect(WorldRouteCodec.decode(Data([1, 0, 0x80])) == nil, "cut off mid-number")
        #expect(WorldRouteCodec.decode(Data()) == nil)
    }

    /// A bend keeps its corner.
    @Test func aBendKeepsItsCorner() throws {
        let origin = GeoPoint(45.5205, -122.6255)
        let points = (0...100).map { RoutePoint(origin.offset(east: Double($0) * 2, north: 0)) }
            + (1...100).map { RoutePoint(origin.offset(east: 200, north: Double($0) * 2)) }
        let decoded = try #require(WorldRouteCodec.decode(WorldRouteCodec.encode(points)))
        #expect(decoded.contains { $0.point.distance(to: origin.offset(east: 200, north: 0)) < 2 })
    }

    /// Lines are sealed per workout and bound to its id: saved, read back, listed, deleted, and a file
    /// renamed to another workout's name does not open.
    @Test func theStoreSealsEachLineToItsWorkout() throws {
        let vault = WorldMapVault.ephemeral()
        let store = WorldRouteStore(vault: vault)
        let first = UUID(), second = UUID()
        #expect(try store.save(Self.walkPoints(), for: first))
        #expect(try store.route(for: first)?.isEmpty == false)
        #expect(try store.workoutIDs() == [first])
        let from = vault.directory.appendingPathComponent("route-\(first.uuidString).bin")
        let to = vault.directory.appendingPathComponent("route-\(second.uuidString).bin")
        try FileManager.default.copyItem(at: from, to: to)
        #expect(try store.route(for: second) == nil, "a line moved to another workout's name opened")
        #expect(store.delete(for: first))
        #expect(try store.route(for: first) == nil)
        #expect(try store.save([], for: first) == false, "an empty line is not kept")
        #expect(vault.clearAll())
    }

    /// The fog's own files still open after the vault learned per-file context (empty for them).
    @Test func theFogStillOpensWithAnEmptyContext() throws {
        let vault = WorldMapVault.ephemeral()
        try vault.write(Data("cells".utf8), to: .fog)
        #expect(try vault.read(.fog) == Data("cells".utf8))
        #expect(WorldMapVault.File.fog.context.isEmpty)
        #expect(try vault.fileNames(withPrefix: "fog", limit: 10) == ["fog.bin"])
    }

    /// The recorder keeps only precise, accurate readings, at least 3 m apart, and only while a walk runs.
    @Test func theRecorderKeepsOnlyGoodReadings() throws {
        let recorder = WorldWalkRecorder()
        let origin = GeoPoint(45.5205, -122.6255), start = Date(timeIntervalSince1970: 2_000_000_000)
        func fix(_ east: Double, accuracy: Double = 5, precise: Bool = true) -> WorldFix {
            WorldFix(point: origin.offset(east: east, north: 0), accuracy: accuracy, at: start, isPrecise: precise)
        }
        recorder.record(fix(0))
        #expect(recorder.points.isEmpty, "a reading before the walk started was kept")
        recorder.start(at: start)
        recorder.record(fix(0))
        recorder.record(fix(1))
        recorder.record(fix(10, accuracy: 60))
        recorder.record(fix(10, precise: false))
        recorder.record(fix(10))
        #expect(recorder.points.count == 2)
        let walk = try #require(recorder.finish(at: start.addingTimeInterval(14 * 60 + 40)))
        #expect(walk.minutes == 15)
        #expect(abs(walk.metres - 10) < 0.5)
        #expect(!recorder.isRecording && recorder.finish(at: start) == nil)
    }

    /// A finished walk is logged as a walking activity with its minutes and miles, and its line is kept
    /// under the workout's id; deleting the workout deletes the line.
    @Test func aFinishedWalkLogsAWorkoutAndKeepsItsLine() throws {
        let (store, defaults) = try Self.store()
        let start = middayToday()
        store.startWorldWalk(at: start)
        for east in stride(from: 0.0, through: 400, by: 5) {
            store.worldWalk.record(WorldFix(point: GeoPoint(45.5205, -122.6255).offset(east: east, north: 0),
                                            accuracy: 5, at: start, isPrecise: true))
        }
        let workout = try #require(store.finishWorldWalk(at: start.addingTimeInterval(6 * 60), defaults: defaults))
        #expect(workout.activityType == .walking && workout.mode == .activity && workout.duration == 6)
        #expect(abs((workout.distanceMiles ?? 0) - 400 / 1_609.344) < 0.01)
        #expect(store.day.workouts.contains { $0.id == workout.id })
        #expect(store.worldRoute(for: workout.id)?.isEmpty == false)
        #expect(store.removeWorkout(id: workout.id, date: store.todayKey))
        #expect(try store.worldRoutes.route(for: workout.id) == nil, "the line outlived its workout")
    }

    /// "Save new routes" off, or a decoy open: the walk is still logged, and no line is kept.
    @Test func noLineIsKeptWithSaveOffOrInADecoy() throws {
        let (store, defaults) = try Self.store()
        WorldMapPreferences.setSaveNewRoutes(false, in: defaults)
        #expect(try Self.walk(store, defaults: defaults).map { try store.worldRoutes.route(for: $0.id) } == .some(nil))
        WorldMapPreferences.setSaveNewRoutes(true, in: defaults)
        store.duressSessionActive = true
        let decoyWalk = try #require(try Self.walk(store, defaults: defaults))
        store.duressSessionActive = false
        #expect(try store.worldRoutes.route(for: decoyWalk.id) == nil, "a decoy walk left a line behind")
    }

    /// A walk recording when a decoy opens is dropped.
    @Test func aDecoyOpeningMidWalkDropsTheWalk() throws {
        let (store, _) = try Self.store()
        store.startWorldWalk()
        #expect(store.worldWalk.isRecording)
        store.duressSessionActive = true
        #expect(!store.worldWalk.isRecording)
        store.duressSessionActive = false
    }

    /// "Save new routes" defaults on, and the delete funnel clears it with the other map settings.
    @Test func saveNewRoutesDefaultsOnAndIsCleared() throws {
        let defaults = try #require(UserDefaults(suiteName: "WorldRouteTests.\(UUID().uuidString)"))
        #expect(WorldMapPreferences.saveNewRoutes(in: defaults))
        WorldMapPreferences.setSaveNewRoutes(false, in: defaults)
        #expect(!WorldMapPreferences.saveNewRoutes(in: defaults))
        WorldMapPreferences.clearAll(in: defaults)
        #expect(WorldMapPreferences.saveNewRoutes(in: defaults))
    }

    /// A store on an ephemeral vault, and an isolated defaults suite.
    private static func store() throws -> (FernletStore, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "WorldRouteTests.\(UUID().uuidString)"))
        return (makeTestStore(), defaults)
    }

    /// A short walk, recorded and finished.
    private static func walk(_ store: FernletStore, defaults: UserDefaults) throws -> Workout? {
        let start = middayToday()
        store.startWorldWalk(at: start)
        for east in stride(from: 0.0, through: 100, by: 5) {
            store.worldWalk.record(WorldFix(point: GeoPoint(45.5205, -122.6255).offset(east: east, north: 0),
                                            accuracy: 5, at: start, isPrecise: true))
        }
        return store.finishWorldWalk(at: start.addingTimeInterval(120), defaults: defaults)
    }
}
