import CoreLocation
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The driving trace and the car's thin line (round 7, car and bike detection; owner 2026-10-26, `nf-car`):
/// when a drive is traced in the background, how much fog a reading in a car lifts, and that every reading
/// reaches car detection before the keepers and carries its in-car answer.
@MainActor
struct WorldDriveTraceTests {
    private static let here = GeoPoint(45.5205, -122.6255)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private static let permissions: [WorldLocationPermission] = [.notAsked, .denied, .whileUsing, .always]

    // MARK: When a drive is traced

    /// Only Always, with background mapping on and the `location` background mode declared, and no walk
    /// recording, traces a drive; every other combination leaves the updates as they were.
    @Test func aDriveIsTracedOnlyWithAlwaysAndBackgroundMapping() {
        var traced: [String] = []
        for permission in Self.permissions {
            for mapping in [false, true] {
                for declared in [false, true] {
                    for walking in [false, true] where WorldLocationSource.tracesDrive(
                        permission: permission, backgroundMapping: mapping, declaresBackground: declared, walking: walking) {
                        traced.append("\(permission) \(mapping) \(declared) \(walking)")
                    }
                }
            }
        }
        #expect(traced == ["always true true false"])
    }

    /// The table's rows the owner cares about, one by one.
    @Test func theTraceNeverRunsWithoutAlwaysOrDuringAWalk() {
        #expect(WorldLocationSource.tracesDrive(permission: .always, backgroundMapping: true, declaresBackground: true, walking: false))
        #expect(!WorldLocationSource.tracesDrive(permission: .whileUsing, backgroundMapping: true, declaresBackground: true, walking: false))
        #expect(!WorldLocationSource.tracesDrive(permission: .always, backgroundMapping: false, declaresBackground: true, walking: false))
        #expect(!WorldLocationSource.tracesDrive(permission: .always, backgroundMapping: true, declaresBackground: false, walking: false))
        #expect(!WorldLocationSource.tracesDrive(permission: .always, backgroundMapping: true, declaresBackground: true, walking: true))
    }

    // MARK: When a bike ride is followed (Refinements group 19, ref-ride-line)

    /// A bike ride is followed closely under exactly the drive trace's conditions (Always, background mapping
    /// on, the `location` background mode declared, no walk), for the fitness activity; a drive keeps
    /// automotive navigation.
    @Test func aRideIsFollowedExactlyAsADriveIsTraced() {
        var followed: [String] = []
        for permission in Self.permissions {
            for mapping in [false, true] {
                for declared in [false, true] {
                    for walking in [false, true] {
                        let ride = WorldLocationSource.followsRide(permission: permission, backgroundMapping: mapping,
                                                                   declaresBackground: declared, walking: walking)
                        let drive = WorldLocationSource.tracesDrive(permission: permission, backgroundMapping: mapping,
                                                                    declaresBackground: declared, walking: walking)
                        #expect(ride == drive)
                        if ride { followed.append("\(permission) \(mapping) \(declared) \(walking)") }
                    }
                }
            }
        }
        #expect(followed == ["always true true false"])
        #expect(WorldLocationSource.activityType(for: .ride) == .fitness)
        #expect(WorldLocationSource.activityType(for: .drive) == .automotiveNavigation)
    }

    /// A ride found in delivered readings is not followed without Always (the test host has none), and a
    /// reading on a bike lifts the fog like a walk's: the store's thin line is for a drive alone.
    @Test func aRideWithoutAlwaysIsNotFollowedAndLiftsLikeAWalk() async throws {
        let source = WorldLocationSource()
        let motion = RideMotion()
        source.rides.replaceMotion(with: motion)
        source.rides.usesMotion = true
        for step in 0...6 {
            source.deliver(WorldFix(point: Self.here.offset(east: Double(step) * 50, north: 0), accuracy: 8,
                                    at: Self.now.addingTimeInterval(Double(step) * 10), isPrecise: true, speed: 5))
            await source.rides.motionQuery?.value
        }
        #expect(source.rides.isCycling && !source.rides.isDriving)
        #expect(!source.isFollowingRide && source.trace == nil, "no Always in the test host")

        let (keeper, vault) = try Self.keeper()
        defer { _ = vault.clearAll() }
        let fix = WorldFix(point: Self.here, accuracy: 8, at: Self.now, isPrecise: true, speed: 5)
        let circle = Set(MercatorHexGrid.cells(around: fix.point, within: WorldFogKeeper.liftRadius))
        #expect(keeper.handle(fix, thinLine: source.rides.isDriving) == circle.count, "a ride lifts the walk's clearing")
    }

    // MARK: The thin line

    /// A fog keeper over a fresh vault and its own settings, loaded.
    private static func keeper() throws -> (WorldFogKeeper, WorldMapVault) {
        let defaults = try #require(UserDefaults(suiteName: "WorldDriveTraceTests.\(UUID().uuidString)"))
        let vault = WorldMapVault.ephemeral()
        let keeper = WorldFogKeeper(vault: vault, defaults: defaults, isProtectedDataAvailable: { true })
        keeper.load()
        return (keeper, vault)
    }

    /// In a car a reading lifts the 25 m either side of the road (owner 2026-10-30, option B): more than the
    /// one cell `nf-car` first drew, less than the walk's 50-m circle, which the same reading lifts on foot.
    @Test func aReadingInACarLiftsTheDrivesWidth() throws {
        let (keeper, vault) = try Self.keeper()
        defer { _ = vault.clearAll() }
        let fix = WorldFix(point: Self.here, accuracy: 8, at: Self.now, isPrecise: true, speed: 20)
        let band = Set(MercatorHexGrid.cells(around: Self.here, within: WorldFogKeeper.driveRadius))
        #expect(WorldFogKeeper.driveRadius == 25)
        #expect(keeper.handle(fix, thinLine: true) == band.count && band.count > 1)
        #expect(keeper.visibleCells == band)
        let onFoot = WorldFix(point: Self.here.offset(east: 800, north: 0), accuracy: 8, at: Self.now, isPrecise: true)
        let circle = Set(MercatorHexGrid.cells(around: onFoot.point, within: WorldFogKeeper.liftRadius))
        #expect(circle.count > band.count)
        #expect(keeper.handle(onFoot) == circle.count)
        #expect(keeper.visibleCells == circle.union(band))
    }

    /// A drive's readings 120 m apart (15 m/s, eight seconds) draw one lane with no gaps: every point of the road
    /// is uncovered, and the lane is narrower than the walk's circles along the same road. A background reading is
    /// written at once as before (W-09 B2).
    @Test func aDriveDrawsAJoinedLaneAndSavesInTheBackground() throws {
        let (keeper, vault) = try Self.keeper()
        defer { _ = vault.clearAll() }
        let road = (0..<6).map { step in Self.here.offset(east: Double(step) * 120, north: Double(step) * 40) }
        for point in road {
            keeper.handle(WorldFix(point: point, accuracy: 8, at: Self.now, isPrecise: true, speed: 15),
                          saveNow: true, thinLine: true)
        }
        let along = (0...120).map { road[0].lerp(to: road[5], Double($0) / 120) }
        #expect(along.allSatisfy { keeper.visibleCells.contains(MercatorHexGrid.cell(containing: $0)) }, "a gap in the lane")
        let walked = Set(along.flatMap { MercatorHexGrid.cells(around: $0, within: WorldFogKeeper.liftRadius) })
        #expect(keeper.visibleCells.count < walked.count * 2 / 3)
        let reopened = WorldFogKeeper(vault: vault, isProtectedDataAvailable: { true })
        reopened.load()
        #expect(reopened.visibleCells == keeper.visibleCells, "each background reading was saved at once")
    }

    /// Drive readings 2 km apart (a tunnel), or either side of a stretch on foot, are not joined.
    @Test func farOrInterruptedDriveReadingsAreNotJoined() throws {
        let (keeper, vault) = try Self.keeper()
        defer { _ = vault.clearAll() }
        let car = { (point: GeoPoint) in WorldFix(point: point, accuracy: 8, at: Self.now, isPrecise: true, speed: 20) }
        let far = Self.here.offset(east: 2_000, north: 0)
        keeper.handle(car(Self.here), thinLine: true)
        keeper.handle(car(far), thinLine: true)
        #expect(!keeper.visibleCells.contains(MercatorHexGrid.cell(containing: Self.here.offset(east: 1_000, north: 0))))
        let walkedTo = far.offset(east: 0, north: 300)
        keeper.handle(WorldFix(point: walkedTo, accuracy: 8, at: Self.now, isPrecise: true))
        keeper.handle(car(walkedTo.offset(east: 300, north: 0)), thinLine: true)
        #expect(!keeper.visibleCells.contains(MercatorHexGrid.cell(containing: far.offset(east: 150, north: 150))),
                "the drive after the walk joins nothing from before it")
    }

    // MARK: Delivery

    /// Every reading reaches car detection first, so the one handed on carries its in-car answer: none
    /// without Motion (the stop watch keeps its speed rule), and Motion's answer with it. Nothing traces
    /// without Always.
    @Test func aDeliveredReadingCarriesItsInCarAnswer() {
        let source = WorldLocationSource()
        var handed: [WorldFix] = []
        source.onFix = { fix in handed.append(fix) }
        let fix = WorldFix(point: Self.here, accuracy: 8, at: Self.now, isPrecise: true, speed: 1)
        source.deliver(fix)
        #expect(handed.last?.inCar == nil)
        source.rides.usesMotion = true
        source.deliver(WorldFix(point: Self.here, accuracy: 8, at: Self.now.addingTimeInterval(5), isPrecise: true, speed: 1))
        #expect(handed.count == 2)
        #expect(handed.last?.inCar == source.rides.inCarFlag)
        #expect(handed.last?.inCar == false)
        #expect(source.latest == handed.last)
        #expect(!source.isTracingDrive)
    }

    /// Readings at a car's speed for half a minute, delivered as CoreLocation hands them on, start a drive: the
    /// fog's lane and Home's riding along follow it. Without Always nothing is traced.
    @Test func deliveredReadingsAtCarSpeedStartADrive() {
        let source = WorldLocationSource()
        var changes: [Bool] = []
        let traced = source.rides.onDrivingChanged
        source.rides.onDrivingChanged = { driving in changes.append(driving); traced?(driving) }
        for step in 0..<4 {
            source.deliver(WorldFix(point: Self.here.offset(east: Double(step) * 200, north: 0), accuracy: 8,
                                    at: Self.now.addingTimeInterval(Double(step) * 10), isPrecise: true, speed: 20))
        }
        #expect(source.rides.isDriving)
        #expect(changes == [true])
        #expect(!source.isTracingDrive)
    }

    /// A reading CoreLocation could not place is dropped before car detection or the keepers see it.
    @Test func anInvalidReadingReachesNoOne() {
        let source = WorldLocationSource()
        var handed = 0
        source.onFix = { _ in handed += 1 }
        source.deliver(WorldFix(point: Self.here, accuracy: -1, at: Self.now, isPrecise: true))
        source.deliver(WorldFix(point: Self.here, accuracy: .infinity, at: Self.now, isPrecise: true))
        #expect(handed == 0)
        #expect(source.latest == nil)
    }
}

/// Motion that says cycling from just after the tests' moment on, allowed.
@MainActor
private final class RideMotion: WorldMotionReading {
    let permission: WorldMotionPermission = .allowed

    func requestAccess() async -> Bool { true }

    func samples(from start: Date, to end: Date) async -> [WorldMotionSample] {
        let cycling = WorldMotionSample(kind: .cycling, isConfident: true, at: Date(timeIntervalSince1970: 2_000_000_001))
        return cycling.at > start && cycling.at <= end ? [cycling] : []
    }
}
