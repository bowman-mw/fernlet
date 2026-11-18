import Foundation
import QuartzCore
import Synchronization
import Testing
import WorldMapStore
@testable import Fernlet

/// Location power while the map is open (owner's picks F + A, 2026-11-17; the investigation is in the gitignored
/// Docs/Handoff location-power report): the camera follows a car at 30 frames a second, the fog's cell sets are published
/// only when they change, a drive saves at most once a minute, a reading reads the audio route at most every 10 s, and the
/// map widget's beat restarts on ~100 m squares.
@MainActor
struct LocationPowerTests {
    /// Away from a widget square's edge (45520.2, −122625.3 in thousandths of a degree).
    nonisolated static let start = GeoPoint(45.5202, -122.6253)
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_792_800_000)

    /// A precise drive reading `seconds` after ``t0``, `metres` east of ``start``, at 25 m/s.
    static func drive(_ seconds: Double, east metres: Double) -> WorldFix {
        WorldFix(point: start.offset(east: metres, north: 0), accuracy: 8, at: t0.addingTimeInterval(seconds),
                 isPrecise: true, speed: 25, course: 90)
    }

    static func freshDefaults() -> UserDefaults {
        let name = "location-power-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: A, the follow's frame rate

    @Test func carPaceIsFasterThanACarsSpeedByTheReadingsOwnSpeed() {
        #expect(WorldFollowGlide.isCarPace(25))
        #expect(WorldFollowGlide.isCarPace(WorldRideWatch.carSpeed + 0.1))
        #expect(!WorldFollowGlide.isCarPace(WorldRideWatch.carSpeed), "exactly a car's speed is not over it")
        #expect(!WorldFollowGlide.isCarPace(1.4), "a walk")
        #expect(!WorldFollowGlide.isCarPace(nil), "unknown speed never is")
        #expect(!WorldFollowGlide.isCarPace(.infinity))
    }

    @Test func theCameraFollowsACarAtThirtyFramesAndAWalkAtUpToSixty() {
        let car = WorldFollowGlide.frameRate(carPace: true)
        #expect(car.minimum == 30 && car.maximum == 30 && car.preferred == 30)
        let foot = WorldFollowGlide.frameRate(carPace: false)
        #expect(foot.minimum == 30 && foot.maximum == 60 && foot.preferred == 60, "walking keeps today's rate")
    }

    @Test func theGlideKnowsItsLastReadingsPace() {
        let glide = WorldFollowGlide()
        #expect(!glide.isCarPace, "nothing tracked yet")
        glide.track(Self.drive(0, east: 0), smooth: true, now: 0)
        #expect(glide.isCarPace)
        var walk = Self.drive(1, east: 2)
        walk.speed = 1.4
        glide.track(walk, smooth: true, now: 1)
        #expect(!glide.isCarPace)
    }

    // MARK: F, saves and publishing

    @Test func aDriveSavesAtMostOnceAMinuteAndAWalkAtFortyCells() {
        let every = WorldFogKeeper.saveEvery
        #expect(!WorldFogKeeper.savesNow(unsaved: every - 1, driving: false, at: Self.t0, lastDriveSave: nil))
        #expect(WorldFogKeeper.savesNow(unsaved: every, driving: false, at: Self.t0, lastDriveSave: Self.t0), "on foot: at forty")
        #expect(WorldFogKeeper.savesNow(unsaved: every, driving: true, at: Self.t0, lastDriveSave: nil), "a drive's first")
        let soon = Self.t0.addingTimeInterval(WorldFogKeeper.driveSaveGap - 1)
        #expect(!WorldFogKeeper.savesNow(unsaved: 500, driving: true, at: soon, lastDriveSave: Self.t0), "within the minute")
        let later = Self.t0.addingTimeInterval(WorldFogKeeper.driveSaveGap)
        #expect(WorldFogKeeper.savesNow(unsaved: every, driving: true, at: later, lastDriveSave: Self.t0))
        #expect(!WorldFogKeeper.savesNow(unsaved: every - 1, driving: true, at: later, lastDriveSave: Self.t0))
        let earlier = Self.t0.addingTimeInterval(-5)
        #expect(WorldFogKeeper.savesNow(unsaved: every, driving: true, at: earlier, lastDriveSave: Self.t0), "a clock change")
    }

    /// A drive's cells reach the disk at its first save, then wait a minute while the map shows them at once; a reading a
    /// minute on writes them all, and a flush (the app leaving the front) writes at once whatever the minute says.
    @Test func aDrivesCellsWaitAMinuteForTheDiskButShowAtOnce() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = WorldFogKeeper(vault: vault, defaults: Self.freshDefaults(), isProtectedDataAvailable: { true })
        keeper.load()
        var second = 0.0
        while try Self.onDisk(vault) == 0, second < 30 {
            keeper.handle(Self.drive(second, east: second * 25), thinLine: true)
            second += 1
        }
        #expect(second < 30, "the drive's first save comes within its first stretch")
        let firstSave = try Self.onDisk(vault)
        for _ in 0..<30 {
            keeper.handle(Self.drive(second, east: second * 25), thinLine: true)
            second += 1
        }
        #expect(keeper.visibleCells.count > firstSave, "the map shows the new cells at once")
        #expect(try Self.onDisk(vault) == firstSave, "the disk waits for the minute")
        let aMinuteOn = second + WorldFogKeeper.driveSaveGap
        keeper.handle(Self.drive(aMinuteOn, east: second * 25 + 25), thinLine: true)
        #expect(try Self.onDisk(vault) == keeper.visibleCells.count, "a minute on, everything is written")
        keeper.handle(Self.drive(aMinuteOn + 1, east: second * 25 + 50), thinLine: true)
        keeper.flush()
        #expect(try Self.onDisk(vault) == keeper.visibleCells.count, "leaving the front writes at once")
    }

    static func onDisk(_ vault: WorldMapVault) throws -> Int {
        let store = FogCellStore(vault: vault)
        try store.load()
        return store.cells.count
    }

    /// The same reading again lifts nothing new, so the map's cell sets are not published again (each publish re-runs
    /// Home's body); a reading that lifts something still publishes.
    @Test func aReadingThatLiftsNothingPublishesNothing() {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = WorldFogKeeper(vault: vault, defaults: Self.freshDefaults(), isProtectedDataAvailable: { true })
        keeper.load()
        var walk = Self.drive(0, east: 0)
        walk.speed = 1.2
        #expect(keeper.handle(walk) > 0)
        #expect(!Self.publishes(keeper) { keeper.handle(walk) }, "nothing new, nothing published")
        var further = Self.drive(10, east: 200)
        further.speed = 1.2
        #expect(Self.publishes(keeper) { keeper.handle(further) }, "new cells publish")
    }

    /// Whether `action` changes the keeper's published cell sets, as Observation sees it.
    static func publishes(_ keeper: WorldFogKeeper, _ action: () -> Void) -> Bool {
        let changed = Mutex(false)
        withObservationTracking {
            _ = keeper.visibleCells
            _ = keeper.drivenCells
        } onChange: {
            changed.withLock { $0 = true }
        }
        action()
        return changed.withLock { $0 }
    }

    // MARK: F, the route read and the widget's beat

    @Test func aReadingReadsTheRouteAtMostEveryTenSeconds() {
        let gap = WorldLocationSource.routeReadGap
        #expect(gap == 10)
        #expect(WorldLocationSource.readsRoute(at: Self.t0, lastRead: nil), "the first reading reads it")
        #expect(!WorldLocationSource.readsRoute(at: Self.t0.addingTimeInterval(gap - 1), lastRead: Self.t0))
        #expect(WorldLocationSource.readsRoute(at: Self.t0.addingTimeInterval(gap), lastRead: Self.t0))
        #expect(WorldLocationSource.readsRoute(at: Self.t0.addingTimeInterval(-1), lastRead: Self.t0), "a clock change")
    }

    /// The beat's square is about 100 m, and its widest span stays under the writer's 200 m move, so a move far enough for
    /// a new picture always lands in a new square (at the equator, where a square is widest, and in Portland).
    @Test func theWidgetsSquareIsUnderItsMoveDistance() {
        let side = 111_320.0 / WorldWidgetMapRefresh.squaresPerDegree
        #expect((side * 2.squareRoot()) < WorldWidgetMapSchedule.moveMetres)
        let here = WorldWidgetMapRefresh.square(of: Self.start)
        #expect(WorldWidgetMapRefresh.square(of: Self.start.offset(east: 20, north: 10)) == here, "a car length stays")
        for degrees in stride(from: 0.0, to: 360, by: 15) {
            let radians = degrees * .pi / 180
            let away = Self.start.offset(east: 200 * sin(radians), north: 200 * cos(radians))
            #expect(WorldWidgetMapRefresh.square(of: away) != here, "200 m away at \(degrees)°")
        }
        #expect(WorldWidgetMapRefresh.square(of: nil) == 0)
    }
}
