import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Worn paths and frequent roads (Docs/World-Frequent-Paths-Exploration-2026-11-15.md §8): the fading tally, the
/// footpath tallies from saved lines, the long road runs for Your world, the sealed per-cell counter, and the fog
/// keeper counting each drive trip's centre line once when the trip ends (never a walk, a decoy or a road friends
/// handed over).
@MainActor
struct WornWaysTests {
    private static let here = GeoPoint(45.5205, -122.6255)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// A precise reading at `point`, `minutes` after ``now``.
    private static func fix(_ point: GeoPoint, minutes: Double = 0) -> WorldFix {
        WorldFix(point: point, accuracy: 8, at: now.addingTimeInterval(minutes * 60), isPrecise: true)
    }

    /// Ground with no water, rail or roads: every ride is a road.
    private struct BareGround: WornTransitGeography {
        func isWater(_ point: GeoPoint) -> Bool { false }
        func isNearMajorRoad(_ point: GeoPoint, within metres: Double) -> Bool { false }
        func isNearRail(_ point: GeoPoint, within metres: Double) -> Bool { false }
        func isNearFerryRoute(_ point: GeoPoint, within metres: Double) -> Bool { false }
    }

    /// A fog keeper over `vault`, its own settings (background mapping on, so rides count: F13 1A), bare ground, and a
    /// lock the test turns.
    private static func keeper(_ vault: WorldMapVault, unlocked: WornLockFlag? = nil,
                               defaults: UserDefaults? = nil) throws -> WorldFogKeeper {
        let unlocked = unlocked ?? WornLockFlag(true)
        let fresh = try #require(UserDefaults(suiteName: "WornWaysTests.\(UUID().uuidString)"))
        let defaults = defaults ?? fresh
        defaults.set(true, forKey: WorldMapPreferences.Key.alwaysLowPower)
        let keeper = WorldFogKeeper(vault: vault, defaults: defaults, isProtectedDataAvailable: { unlocked.isOn })
        keeper.transitGeography = BareGround()
        keeper.load()
        return keeper
    }

    /// A straight road east from ``here``: readings every 100 m.
    private static let road = (0...8).map { here.offset(east: Double($0) * 100, north: 0) }

    /// The centre-line cells a drive along ``road`` counts.
    private static var roadCentre: Set<HexCell> {
        var cells = Set<HexCell>()
        var from: GeoPoint?
        for point in road {
            cells.formUnion(WorldFogKeeper.centreLine(from: from, to: point))
            from = point
        }
        return cells
    }

    /// Drives ``road`` (out, and back when `andBack`), starting `minutes` after ``now``: 800 m in 72 s each way, over
    /// the 60 s and 500 m a kept ride needs (F13 2B).
    private static func drive(_ keeper: WorldFogKeeper, minutes: Double = 0, andBack: Bool = false) {
        let readings = andBack ? road + road.reversed() : road
        for (index, point) in readings.enumerated() {
            keeper.handle(fix(point, minutes: minutes + Double(index) * 0.15), thinLine: true)
        }
    }

    /// Ends the trip with a walk `minutes` after ``now`` and waits for its ride to be sorted and kept.
    private static func walk(_ keeper: WorldFogKeeper, minutes: Double) async {
        keeper.handle(fix(here.offset(east: 3_000, north: 0), minutes: minutes))
        await keeper.settleTrips()
    }

    // MARK: The tally

    /// Roads reach levels 1, 2 and 3 at 3, 10 and 30 trips, and fade one level for every 30 idle days.
    @Test func theTallyClimbsAndFades() {
        let road = WornThresholds.road
        #expect(WornTally(count: 2, lastDay: 100).level(today: 100, thresholds: road) == nil)
        #expect(WornTally(count: 3, lastDay: 100).level(today: 100, thresholds: road) == .one)
        #expect(WornTally(count: 10, lastDay: 100).level(today: 100, thresholds: road) == .two)
        #expect(WornTally(count: 30, lastDay: 100).level(today: 100, thresholds: road) == .three)
        let worn = WornTally(count: 30, lastDay: 100)
        #expect(worn.level(today: 129, thresholds: road) == .three)
        #expect(worn.level(today: 130, thresholds: road) == .two)
        #expect(worn.level(today: 160, thresholds: road) == .one)
        #expect(worn.level(today: 190, thresholds: road) == .abandoned)
        #expect(worn.level(today: 5_000, thresholds: road) == .abandoned, "abandoned never disappears")
    }

    /// A trip back on an abandoned way brings it to exactly level 1; on a faded level-3 way it settles to level 2's
    /// lowest count plus the trip; a count below level 1 starts again after a full idle fade period.
    @Test func aTripOnAFadedWaySettlesItsCount() {
        let road = WornThresholds.road
        var abandoned = WornTally(count: 30, lastDay: 100)
        abandoned.pass(on: 190, thresholds: road)
        #expect(abandoned.count == 3 && abandoned.lastDay == 190 && abandoned.level(today: 190, thresholds: road) == .one)
        var faded = WornTally(count: 30, lastDay: 100)
        faded.pass(on: 130, thresholds: road)
        #expect(faded.count == 11 && faded.level(today: 130, thresholds: road) == .two)
        var young = WornTally(count: 2, lastDay: 100)
        young.pass(on: 129, thresholds: road)
        #expect(young.count == 3, "inside the fade period the count keeps climbing")
        var idle = WornTally(count: 2, lastDay: 100)
        idle.pass(on: 130, thresholds: road)
        #expect(idle.count == 1, "a sub-level-1 count resets after 30 idle days")
        var older = WornTally(count: 5, lastDay: 100)
        older.pass(on: 50, thresholds: road)
        #expect(older.count == 6 && older.lastDay == 100, "an older trip only adds")
    }

    // MARK: Footpaths

    /// Footpaths reach levels at 2, 5 and 15 lines; one line counts a cell once; lines replay oldest first.
    @Test func footpathsCountEachLineOnceInDateOrder() {
        let line = [Self.here, Self.here.offset(east: 60, north: 0)]
        let cell = MercatorHexGrid.cell(containing: Self.here)
        func level(after lines: Int) -> WornLevel? {
            let routes = (0..<lines).map { _ in (day: UInt16(100), line: line) }
            return WornFootpaths.tallies(routes: routes)[cell]?.level(today: 100, thresholds: .footpath)
        }
        #expect(level(after: 1) == nil && level(after: 2) == .one && level(after: 4) == .one)
        #expect(level(after: 5) == .two && level(after: 14) == .two && level(after: 15) == .three)
        let there = Self.here.offset(east: 200, north: 0)
        let backAndForth = WornFootpaths.tallies(routes: [(day: 100, line: [Self.here, there, Self.here, there])])
        #expect(backAndForth[cell]?.count == 1, "one line counts a cell once")
        // Oldest first: days 100 and 101 reach level 1, then 99 idle days leave it abandoned, so day 200 brings it
        // back to exactly level 1. Out of order, day 200 would come first and the others would only add.
        let replayed = WornFootpaths.tallies(routes: [(day: 200, line: line), (day: 100, line: line), (day: 101, line: line)])
        #expect(replayed[cell] == WornTally(count: 2, lastDay: 200))
    }

    // MARK: Your world runs

    /// A 2.5 km straight run is long enough, a 1 km one is not, and two runs apart stay two.
    @Test func longRunsKeepOnlyLongRoads() {
        let long = WornFootpaths.cells(along: [Self.here, Self.here.offset(east: 2_500, north: 0)])
        let short = WornFootpaths.cells(along: [Self.here, Self.here.offset(east: 1_000, north: 0)])
        #expect(WornWayRuns.longRuns(long).count == 1 && WornWayRuns.longRuns(long).first == long)
        #expect(WornWayRuns.longRuns(short).isEmpty)
        let apart = WornFootpaths.cells(along: [Self.here.offset(east: 0, north: 1_000), Self.here.offset(east: 2_500, north: 1_000)])
        let runs = WornWayRuns.longRuns(long.union(apart))
        #expect(runs.count == 2 && Set(runs) == [long, apart])
    }

    // MARK: The store

    /// The codec round-trips every kind and refuses a wrong version, a cut-off file, an unknown kind and too many.
    @Test func theCodecRoundTripsAndRefusesBadBytes() {
        let tallies: [WornWayKey: WornTally] = [
            WornWayKey(cell: HexCell(q: 1, r: -2), kind: .road): WornTally(count: 3, lastDay: 4_000),
            WornWayKey(cell: HexCell(q: 1, r: -2), kind: .rail): WornTally(count: 1, lastDay: 4_001),
            WornWayKey(cell: HexCell(q: -900_000, r: 700_000), kind: .ferry): WornTally(count: .max, lastDay: .max),
        ]
        let data = WornWayCodec.encode(tallies)
        #expect(data.count == 5 + 3 * 13)
        #expect(WornWayCodec.decode(data, limit: 10) == tallies)
        #expect(WornWayCodec.encode([:]).count == 5 && WornWayCodec.decode(WornWayCodec.encode([:]), limit: 0) == [:])
        #expect(WornWayCodec.decode(Data([9]) + data.dropFirst(), limit: 10) == nil, "an unknown version is refused")
        #expect(WornWayCodec.decode(data.dropLast(), limit: 10) == nil, "a cut-off file is refused")
        #expect(WornWayCodec.decode(data + Data([0]), limit: 10) == nil, "trailing bytes are refused")
        var unknownKind = data
        unknownKind[unknownKind.startIndex + 5 + 8] = 9
        #expect(WornWayCodec.decode(unknownKind, limit: 10) == nil, "an unknown kind is refused")
        #expect(WornWayCodec.decode(data, limit: 2) == nil, "more than the limit is refused")
        let pending = [(WornWayKey(cell: HexCell(q: 3, r: 3), kind: .road), UInt16(7))]
        let decoded = WornWayCodec.decodePending(WornWayCodec.encodePending(pending), limit: 5)
        #expect(decoded?.count == 1 && decoded?.first?.0 == pending[0].0 && decoded?.first?.1 == 7)
    }

    /// The store counts, saves and reopens; a file that can't be opened is removed and counting starts again.
    @Test func theStoreSavesAndDropsADamagedFile() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let store = WornWayStore(vault: vault)
        #expect(store.record([HexCell(q: 1, r: 1)], kind: .road, on: 10) == 0, "nothing before load")
        try store.load()
        let cells = (0..<4).map { HexCell(q: $0, r: 0) }
        #expect(store.record(cells + cells, kind: .road, on: 10) == 4, "a cell named twice counts once")
        store.record(cells.prefix(2), kind: .road, on: 11)
        try store.save()
        let reopened = WornWayStore(vault: vault)
        try reopened.load()
        #expect(reopened.tallies == store.tallies)
        #expect(reopened.tallies[WornWayKey(cell: cells[0], kind: .road)] == WornTally(count: 2, lastDay: 11))
        try Data("not a map".utf8).write(to: vault.directory.appendingPathComponent(WorldMapVault.File.wornWays.name))
        let damaged = WornWayStore(vault: vault)
        try damaged.load()
        #expect(damaged.tallies.isEmpty && damaged.isLoaded)
        #expect(try vault.read(.wornWays) == nil, "unopenable bytes are removed, not kept as noise")
    }

    /// The locked-phone buffer keeps a (cell, kind, day) once, hands it over oldest day first and empties.
    @Test func thePendingBufferDedupesAndTakes() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let store = WornWayStore(vault: vault)
        let a = HexCell(q: 1, r: 1), b = HexCell(q: 2, r: 1)
        try store.appendPending([a, b], kind: .road, on: 20)
        try store.appendPending([a, a], kind: .road, on: 20)
        try store.appendPending([a], kind: .road, on: 19)
        let taken = try store.pending()
        #expect(taken.count == 3, "the same cell, kind and day waits once")
        #expect(taken.map(\.1) == [19, 20, 20], "oldest day first")
        #expect(try store.pending().count == 3, "reading the buffer leaves it until it is cleared")
        #expect(store.clearPending())
        #expect(try store.pending().isEmpty)
        #expect(try vault.read(.pendingWornWays) == nil)
    }

    /// Past the caps new ways and buffered passes are refused and counted, never evicting what is there.
    @Test func theStoreRefusesPastItsCaps() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let store = WornWayStore(vault: vault)
        try store.load()
        let full = (0..<FogCellStore.maxCells).map { HexCell(q: $0 % 1_000, r: $0 / 1_000) }
        #expect(store.record(full, kind: .road, on: 1) == FogCellStore.maxCells)
        #expect(store.record([HexCell(q: -5, r: -5)], kind: .road, on: 1) == 0 && store.refusedCount == 1)
        #expect(store.record([full[0]], kind: .road, on: 2) == 1, "a way already counted still counts")
        let pendingFull = (0..<FogCellStore.maxPendingCells).map { HexCell(q: $0, r: 0) }
        try store.appendPending(pendingFull, kind: .road, on: 3)
        try store.appendPending([HexCell(q: -1, r: -1)], kind: .road, on: 3)
        #expect(store.refusedCount == 2)
        #expect(try store.pending().count == FogCellStore.maxPendingCells)
    }

    // MARK: The fog keeper

    /// A drive counts the cells under its centre line once per trip, even driven out and back; the map sees them
    /// when the trip ends, and a second trip (after a walk or ten quiet minutes) counts them again.
    @Test func aDriveCountsItsCentreOncePerTrip() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault)
        Self.drive(keeper, andBack: true)
        let centre = Self.roadCentre
        #expect(centre.count > 20)
        await Self.walk(keeper, minutes: 5)
        #expect(Set(keeper.wornWays.keys) == Set(centre.map { WornWayKey(cell: $0, kind: .road) }))
        #expect(keeper.wornWays.values.allSatisfy { $0.count == 1 }, "out and back is one trip")
        let lane = Set(WorldFogKeeper.lane(from: Self.road[0], to: Self.road[1]))
        #expect(!lane.subtracting(centre).isEmpty, "only the centre line counts, not the lane")
        Self.drive(keeper, minutes: 10)
        #expect(keeper.wornWays.values.allSatisfy { $0.count == 1 }, "a trip over known road shows nothing until it ends")
        Self.drive(keeper, minutes: 30)
        await keeper.settleTrips()
        keeper.flush()
        #expect(keeper.wornWays.values.allSatisfy { $0.count == 2 }, "ten quiet minutes end a trip; the next counts at its end")
        await Self.walk(keeper, minutes: 35)
        #expect(keeper.wornWays.values.allSatisfy { $0.count == 3 }, "a walk and ten quiet minutes each end a trip")
        let reopened = try Self.keeper(vault)
        #expect(reopened.wornWays == keeper.wornWays, "the counter is saved")
    }

    /// Walking, a decoy and a road friends handed over count nothing.
    @Test func walksDecoysAndReceivedRoadsCountNothing() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault)
        for point in Self.road { keeper.handle(Self.fix(point)) }
        keeper.flush()
        #expect(keeper.wornWays.isEmpty, "a walk counts nothing")
        _ = keeper.liftReceivedRoad(Self.road)
        keeper.flush()
        #expect(keeper.wornWays.isEmpty, "a friend's road is not this person's trip")
        keeper.setDecoy(true)
        Self.drive(keeper)
        await Self.walk(keeper, minutes: 5)
        keeper.flush()
        #expect(keeper.wornWays.isEmpty)
        keeper.setDecoy(false)
        keeper.flush()
        #expect(keeper.wornWays.isEmpty, "the decoy's drive was never counted")
    }

    /// With "Uncover the map as you go" off, a drive counts nothing.
    @Test func uncoverOffCountsNothing() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let defaults = try #require(UserDefaults(suiteName: "WornWaysTests.\(UUID().uuidString)"))
        defaults.set(false, forKey: WorldMapPreferences.Key.uncoverAsYouGo)
        let keeper = try Self.keeper(vault, defaults: defaults)
        Self.drive(keeper)
        await Self.walk(keeper, minutes: 5)
        keeper.flush()
        #expect(keeper.wornWays.isEmpty)
    }

    /// With background mapping off, a drive lifts its lane but counts and keeps nothing; turning it off mid-ride drops
    /// the ride and its checkpoint (F13 1A, owner 2026-11-19).
    @Test func backgroundMappingOffCountsNothing() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let defaults = try #require(UserDefaults(suiteName: "WornWaysTests.\(UUID().uuidString)"))
        let keeper = try Self.keeper(vault, defaults: defaults)
        defaults.set(false, forKey: WorldMapPreferences.Key.alwaysLowPower)
        Self.drive(keeper, andBack: true)
        #expect(!keeper.visibleCells.isEmpty, "the fog still lifts")
        await Self.walk(keeper, minutes: 5)
        keeper.flush()
        #expect(keeper.wornWays.isEmpty && keeper.wornTrips.isEmpty)
        defaults.set(true, forKey: WorldMapPreferences.Key.alwaysLowPower)
        for (index, east) in stride(from: 0.0, through: 6_000, by: 50).enumerated() {
            keeper.handle(Self.fix(Self.here.offset(east: east, north: 500), minutes: 10 + Double(index) / 30), thinLine: true)
        }
        #expect(try vault.read(.wornTripRide) != nil, "a long ride is checkpointed")
        defaults.set(false, forKey: WorldMapPreferences.Key.alwaysLowPower)
        keeper.handle(Self.fix(Self.here.offset(east: 6_050, north: 500), minutes: 15), thinLine: true)
        #expect(try vault.read(.wornTripRide) == nil, "turning mapping off drops the ride in progress")
        defaults.set(true, forKey: WorldMapPreferences.Key.alwaysLowPower)
        await Self.walk(keeper, minutes: 16)
        #expect(keeper.wornWays.isEmpty && keeper.wornTrips.isEmpty)
    }

    /// A drive with the phone locked waits in the counter's buffer and counts at the unlock.
    @Test func aLockedDriveCountsAtTheUnlock() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let lock = WornLockFlag(true)
        let keeper = try Self.keeper(vault, unlocked: lock)
        lock.isOn = false
        Self.drive(keeper, andBack: true)
        await Self.walk(keeper, minutes: 5)
        #expect(keeper.wornWays.isEmpty)
        lock.isOn = true
        keeper.load()
        #expect(Set(keeper.wornWays.keys) == Set(Self.roadCentre.map { WornWayKey(cell: $0, kind: .road) }))
        #expect(keeper.wornWays.values.allSatisfy { $0.count == 1 })
    }

    /// The wipe forgets the counter and its file.
    @Test func clearAllEmptiesTheCounter() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault)
        Self.drive(keeper)
        await Self.walk(keeper, minutes: 5)
        #expect(!keeper.wornWays.isEmpty)
        _ = keeper.clearAll()
        #expect(keeper.wornWays.isEmpty)
        #expect(try vault.read(.wornWays) == nil)
        let reopened = try Self.keeper(vault)
        #expect(reopened.wornWays.isEmpty)
    }
}

/// Whether the test's phone is unlocked, which the test turns.
@MainActor
private final class WornLockFlag {
    var isOn: Bool
    init(_ isOn: Bool) { self.isOn = isOn }
}
