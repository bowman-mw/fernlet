import CryptoKit
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Road trip mode's core (World-RoadTrip-Spec PR 1, owner-approved 2026-11-10): the trip record and its timed line,
/// sealed in the map's vault; the line's thinning, pieces and bounds; recording only while this iPhone maps, with the
/// phone locked too; and a decoy and every wipe.
@MainActor
struct RoadTripCoreTests {
    private static let here = GeoPoint(45.5205, -122.6255)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// A three-person trip this iPhone is on, started at ``now``, mapped by `mapper` (this iPhone by default).
    static func trip(mapper: String = "me", starter: String = "me", id: UUID = UUID(), name: String? = nil) -> RoadTrip {
        RoadTrip(id: id, name: name, startedAt: now, starterID: starter, selfID: "me",
                 members: [RoadTripMember(id: "me", firstName: "Mike"), RoadTripMember(id: "rae", firstName: "Rae"),
                           RoadTripMember(id: "sam", firstName: "Sam")],
                 mapperID: mapper, mapperOverride: nil, lastCatchUp: now, endedAt: nil, leftAt: nil)
    }

    /// A precise reading `east` metres east of ``here``, `seconds` after ``now``.
    static func fix(east: Double, seconds: Double, accuracy: Double = 8, precise: Bool = true) -> WorldFix {
        WorldFix(point: here.offset(east: east, north: 0), accuracy: accuracy, at: now.addingTimeInterval(seconds), isPrecise: precise)
    }

    /// `count` points `spacing` metres apart, a second apart, from ``now``.
    static func points(_ count: Int, spacing: Double = 30, from start: Double = 0) -> [RoadTripPoint] {
        (0..<count).map { RoadTripPoint(point: here.offset(east: start + Double($0) * spacing, north: 0), at: now.addingTimeInterval(Double($0))) }
    }

    /// A vault whose store key is locked away (as with the phone locked) while the buffer key works.
    static func lockedVault() -> WorldMapVault {
        let buffer = SymmetricKey(size: .bits256)
        let keys = WorldMapKeys(key: { role in
            guard role == .buffer else { throw WorldMapVault.VaultError.keyUnavailable }
            return buffer
        }, removeAll: { true })
        return WorldMapVault(directory: FileManager.default.temporaryDirectory.appendingPathComponent("RoadTrip-\(UUID().uuidString)"),
                             keys: keys)
    }

    /// The road trip files in `vault`.
    static func tripFiles(_ vault: WorldMapVault) throws -> [String] {
        try vault.fileNames(withPrefix: "road-trip", limit: 1_000)
    }

    // MARK: The line's form

    /// A piece round-trips to within its units (1e-5°, whole seconds), and a broken one is refused whole.
    @Test func aPieceRoundTripsAndABrokenOneIsRefused() throws {
        let points = Self.points(40)
        let data = RoadTripLineCodec.encode(points)
        let decoded = try #require(RoadTripLineCodec.decode(data))
        #expect(decoded.count == points.count)
        for (a, b) in zip(decoded, points) {
            #expect(abs(a.point.latitude - b.point.latitude) < 1e-5 && abs(a.point.longitude - b.point.longitude) < 1e-5)
            #expect(a.at == b.at)
        }
        #expect(data.count < points.count * 10, "compact: \(data.count) bytes")
        #expect(RoadTripLineCodec.decode(Data()) == nil)
        #expect(RoadTripLineCodec.decode(Data([2]) + data.dropFirst()) == nil, "another version")
        #expect(RoadTripLineCodec.decode(data + Data([0])) == nil, "bytes left over")
        #expect(RoadTripLineCodec.decode(data.dropLast()) == nil, "cut short")
        var backwards = points
        backwards.swapAt(3, 4)
        #expect(RoadTripLineCodec.decode(RoadTripLineCodec.encode(backwards)) == nil, "time running backwards")
        var tooMany = Data([RoadTripLineCodec.version])
        tooMany.append(contentsOf: [0xF5, 0x03]) // 501 points
        #expect(RoadTripLineCodec.decode(tooMany) == nil)
        #expect(RoadTripLineCodec.unzigzag(RoadTripLineCodec.zigzag(-12_345)) == -12_345)
    }

    /// The line keeps a point only 25 m or more from the last kept one and never one older than it; a point off the
    /// globe or out of time is never kept.
    @Test func theLineIsThinnedTo25Metres() {
        let first = RoadTripPoint(point: Self.here, at: Self.now)
        #expect(RoadTripLine.keeps(first, after: nil))
        #expect(!RoadTripLine.keeps(RoadTripPoint(point: Self.here.offset(east: 24, north: 0), at: Self.now.addingTimeInterval(5)), after: first))
        #expect(RoadTripLine.keeps(RoadTripPoint(point: Self.here.offset(east: 26, north: 0), at: Self.now.addingTimeInterval(5)), after: first))
        #expect(!RoadTripLine.keeps(RoadTripPoint(point: Self.here.offset(east: 90, north: 0), at: Self.now.addingTimeInterval(-1)), after: first))
        #expect(!RoadTripLine.keeps(RoadTripPoint(point: GeoPoint(91, 0), at: Self.now), after: nil))
        #expect(!RoadTripLine.keeps(RoadTripPoint(point: Self.here, at: Date(timeIntervalSince1970: -1)), after: nil))
        #expect(RoadTripLine.maxPoints == 100_000 && RoadTripLine.chunkSize == 500 && RoadTripLine.maxChunks == 200)
    }

    // MARK: The sealed record and line

    /// A trip and its line written by one keeper read back the same in the next, the line in pieces of 500, and its
    /// length reads every piece.
    @Test func aTripAndItsLineRoundTripInPieces() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = RoadTripKeeper(vault: vault)
        keeper.load()
        let trip = Self.trip(name: "To the coast")
        #expect(keeper.start(trip))
        #expect(keeper.appendLine(Self.points(1_200)) == 1_200)
        #expect(try Self.tripFiles(vault).sorted() == ["road-trip-line-\(trip.id.uuidString)-0000.bin",
                                                        "road-trip-line-\(trip.id.uuidString)-0001.bin",
                                                        "road-trip-line-\(trip.id.uuidString)-0002.bin", "road-trips.bin"])
        let later = RoadTripKeeper(vault: vault)
        later.load()
        #expect(later.active == trip)
        #expect(later.pointCount == 1_200)
        #expect(abs(later.lineMetres() - 1_199 * 30) < 20)
        #expect(RoadTripCopy.name(of: trip) == "To the coast")
        // The next point carries on from the open piece.
        later.record(Self.fix(east: 1_200 * 30, seconds: 1_300))
        later.flush()
        let third = RoadTripKeeper(vault: vault)
        third.load()
        #expect(third.pointCount == 1_201)
    }

    /// The book's bounds: at most five people, a short name, one trip on at a time, a hundred trips; a trip that breaks
    /// one is refused, never an eviction.
    @Test func theBookIsBounded() {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = RoadTripKeeper(vault: vault)
        keeper.load()
        var crowded = Self.trip()
        crowded.members += (0..<3).map { RoadTripMember(id: "m\($0)", firstName: "M\($0)") }
        #expect(crowded.members.count == 6 && !crowded.isValid)
        #expect(!keeper.start(crowded))
        #expect(!keeper.start(Self.trip(name: String(repeating: "a", count: RoadTrip.maxNameLength + 1))))
        #expect(!keeper.start(Self.trip(mapper: "stranger")), "the mapper must be on the trip")
        #expect(keeper.start(Self.trip()))
        #expect(!keeper.start(Self.trip()), "one trip on at a time")
        #expect(keeper.end(now: Self.now))
        for _ in 1..<RoadTripBook.maxTrips {
            #expect(keeper.start(Self.trip()))
            #expect(keeper.end(now: Self.now))
        }
        #expect(keeper.book.trips.count == RoadTripBook.maxTrips)
        #expect(!keeper.start(Self.trip()), "the book is full")
        #expect(keeper.book.trips.count == RoadTripBook.maxTrips)
    }

    /// The line stops at 100,000 points: past it a point is refused and counted, and what was kept stays.
    @Test func theLineStopsAtItsBound() {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = RoadTripKeeper(vault: vault)
        keeper.load()
        #expect(keeper.start(Self.trip()))
        #expect(keeper.appendLine(Self.points(RoadTripLine.maxPoints)) == RoadTripLine.maxPoints)
        let past = RoadTripPoint(point: Self.here.offset(east: Double(RoadTripLine.maxPoints) * 30 + 30, north: 0),
                                 at: Self.now.addingTimeInterval(Double(RoadTripLine.maxPoints) + 1))
        #expect(keeper.appendLine([past]) == 0)
        #expect(keeper.refusedCount == 1)
        let later = RoadTripKeeper(vault: vault)
        later.load()
        #expect(later.pointCount == RoadTripLine.maxPoints)
    }

    /// Leaving or ending keeps the record and its line (for the passport's trips) and the trip is no longer on.
    @Test func leavingOrEndingKeepsTheRecordAndItsLine() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = RoadTripKeeper(vault: vault)
        keeper.load()
        let trip = Self.trip()
        #expect(keeper.start(trip))
        #expect(keeper.appendLine(Self.points(10)) == 10)
        #expect(keeper.leave(now: Self.now.addingTimeInterval(60)))
        #expect(keeper.active == nil && keeper.book.trips.first?.leftAt == Self.now.addingTimeInterval(60))
        #expect(try Self.tripFiles(vault).contains("road-trip-line-\(trip.id.uuidString)-0000.bin"))
        #expect(!keeper.leave(now: Self.now), "nothing on to leave")
        #expect(keeper.start(Self.trip()))
        #expect(keeper.end(now: Self.now.addingTimeInterval(120)))
        #expect(keeper.active == nil && keeper.book.trips.count == 2 && keeper.book.trips.last?.endedAt != nil)
    }

    // MARK: Recording

    /// Only the iPhone that maps records, only precise readings within 65 m from the trip's start, thinned.
    @Test func onlyTheMappingPhoneRecordsAcceptedReadings() {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = RoadTripKeeper(vault: vault)
        keeper.record(Self.fix(east: 0, seconds: 1))
        #expect(keeper.pointCount == 0, "no trip")
        #expect(keeper.start(Self.trip(mapper: "rae", starter: "rae")))
        keeper.record(Self.fix(east: 0, seconds: 1))
        #expect(keeper.pointCount == 0 && keeper.isPassenger, "a passenger records nothing")
        _ = keeper.end(now: Self.now)
        #expect(keeper.start(Self.trip()))
        keeper.record(Self.fix(east: 0, seconds: -10))
        keeper.record(Self.fix(east: 0, seconds: 1, precise: false))
        keeper.record(Self.fix(east: 0, seconds: 1, accuracy: 80))
        #expect(keeper.pointCount == 0, "before the start, approximate, or too rough")
        keeper.record(Self.fix(east: 0, seconds: 1))
        keeper.record(Self.fix(east: 10, seconds: 2))
        keeper.record(Self.fix(east: 40, seconds: 3))
        #expect(keeper.pointCount == 2 && keeper.isMapping)
    }

    /// With the phone locked (the store key away), the fog keeper's accepted readings still join the line, written at
    /// once, and the next keeper reads them; the fog itself waits in its buffer.
    @Test func theLineGrowsWithThePhoneLocked() throws {
        let vault = Self.lockedVault()
        defer { _ = vault.clearAll() }
        let setUp = RoadTripKeeper(vault: vault)
        setUp.load()
        #expect(setUp.start(Self.trip()))
        let defaults = try #require(UserDefaults(suiteName: "RoadTripCoreTests-\(UUID().uuidString)"))
        let fog = WorldFogKeeper(vault: vault, defaults: defaults, isProtectedDataAvailable: { false })
        fog.load()
        fog.handle(Self.fix(east: 0, seconds: 1), saveNow: true, thinLine: true)
        fog.handle(Self.fix(east: 30, seconds: 2), saveNow: true, thinLine: true)
        fog.handle(Self.fix(east: 60, seconds: 3, accuracy: 90), saveNow: true, thinLine: true)
        let later = RoadTripKeeper(vault: vault)
        later.load()
        #expect(later.pointCount == 2)
        #expect(fog.visibleCells.isEmpty, "the fog's store stays shut while locked")
    }

    /// A locked launch's early source reads the trip: as the mapper its readings join the line, and the hand-over
    /// writes what waited; as a passenger it is told so before any reading.
    @Test func aLockedLaunchRecordsAndGatesToo() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let setUp = RoadTripKeeper(vault: vault)
        setUp.load()
        #expect(setUp.start(Self.trip()))
        let holder = WorldLockedMappingHolder(isMarked: { true }, vault: { vault })
        let source = try #require(holder.start())
        #expect(!source.isRoadTripPassenger)
        source.deliver(Self.fix(east: 0, seconds: 1))
        #expect(holder.handOver() === source)
        let later = RoadTripKeeper(vault: vault)
        later.load()
        #expect(later.pointCount == 1)
        #expect(later.end(now: Self.now))
        #expect(later.start(Self.trip(mapper: "rae", starter: "rae")))
        let passengerHolder = WorldLockedMappingHolder(isMarked: { true }, vault: { vault })
        let passengerSource = try #require(passengerHolder.start())
        #expect(passengerSource.isRoadTripPassenger)
    }

    // MARK: Decoy and wipes

    /// A decoy shows no trip, records, starts, leaves and ends nothing, and drops the real book from memory; the real
    /// trip is back, unchanged, when it ends.
    @Test func aDecoyShowsNoTripAndRecordsNothing() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = RoadTripKeeper(vault: vault)
        keeper.load()
        let trip = Self.trip()
        #expect(keeper.start(trip))
        var told: [Bool] = []
        keeper.onPassengerChanged = { told.append($0) }
        let before = try Self.tripFiles(vault)
        keeper.setDecoy(true)
        #expect(keeper.active == nil && keeper.book.trips.isEmpty && !keeper.isMapping)
        keeper.record(Self.fix(east: 0, seconds: 1))
        #expect(keeper.appendLine(Self.points(5)) == 0)
        #expect(!keeper.start(Self.trip()) && !keeper.leave(now: Self.now) && !keeper.end(now: Self.now))
        #expect(!keeper.mapFromThisPhone(states: [:]))
        #expect(try Self.tripFiles(vault) == before, "nothing written")
        keeper.setDecoy(false)
        #expect(keeper.active == trip && keeper.pointCount == 0)
        #expect(told.isEmpty, "this iPhone maps either way, so it was never a passenger")
    }

    /// In the store, a decoy shows no trip and no Trip info, and ends the passenger gate; Delete map history in a decoy
    /// touches nothing real, and out of one removes every trip and line with the vault, in memory too.
    @Test func theStoresDecoyAndDeleteMapHistory() throws {
        let store = makeTestStore()
        let keeper = store.worldFog.roadTrip
        keeper.load()
        #expect(keeper.start(Self.trip(mapper: "rae", starter: "rae")))
        #expect(keeper.appendLine(Self.points(3)) == 3)
        #expect(store.worldLocation.isRoadTripPassenger, "the gate is wired")
        #expect(store.roadTripInfo()?.mapperName == "Rae")
        store.duressSessionActive = true
        #expect(store.roadTripInfo() == nil && keeper.active == nil)
        #expect(!store.worldLocation.isRoadTripPassenger, "a decoy has no trip")
        #expect(!store.mapRoadTripFromThisPhone() && !store.leaveRoadTrip() && !store.endRoadTrip())
        #expect(store.deleteWorldMapHistory())
        store.duressSessionActive = false
        #expect(keeper.active != nil && store.worldLocation.isRoadTripPassenger, "a decoy deleted the real trip")
        #expect(store.deleteWorldMapHistory())
        #expect(keeper.active == nil && keeper.book.trips.isEmpty && !store.worldLocation.isRoadTripPassenger)
        #expect(try Self.tripFiles(store.worldMapVault).isEmpty)
        let fresh = RoadTripKeeper(vault: store.worldMapVault)
        fresh.load()
        #expect(fresh.book.trips.isEmpty)
    }

    /// Delete everything (the funnel the silent wipe shares) and the fog keeper's wipe (the recovery lock's) remove the
    /// trips, unsaved points included, and nothing is written back afterwards.
    @Test func everyWipeRemovesTheTrips() throws {
        let store = makeTestStore()
        let keeper = store.worldFog.roadTrip
        keeper.load()
        #expect(keeper.start(Self.trip()))
        keeper.record(Self.fix(east: 0, seconds: 1))
        #expect(keeper.pointCount == 1, "one point, not yet written")
        _ = store.resetAll()
        #expect(keeper.active == nil)
        keeper.flush()
        #expect(try Self.tripFiles(store.worldMapVault).isEmpty)

        #expect(keeper.start(Self.trip()))
        #expect(keeper.appendLine(Self.points(2)) == 2)
        #expect(store.worldFog.clearAll())
        keeper.record(Self.fix(east: 0, seconds: 1))
        keeper.flush()
        #expect(keeper.active == nil && keeper.pointCount == 0)
        #expect(try Self.tripFiles(store.worldMapVault).isEmpty)
    }

    /// A file sealed for another purpose, or damaged, never opens as the book or a piece; it is removed and the map
    /// starts fresh.
    @Test func aWrongOrDamagedFileIsRemoved() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let id = UUID()
        try vault.write(Data("{}".utf8), to: .placeMarks)
        try FileManager.default.copyItem(at: vault.directory.appendingPathComponent("places-marks.bin"),
                                         to: vault.directory.appendingPathComponent(WorldMapVault.File.roadTrips.name))
        try vault.write(RoadTripLineCodec.encode(Self.points(3)), to: .roadTripLine(trip: id, chunk: 0))
        try FileManager.default.copyItem(at: vault.directory.appendingPathComponent(WorldMapVault.File.roadTripLine(trip: id, chunk: 0).name),
                                         to: vault.directory.appendingPathComponent(WorldMapVault.File.roadTripLine(trip: id, chunk: 1).name))
        let store = RoadTripStore(vault: vault)
        #expect(try store.readBook() == .empty)
        #expect(try store.readChunk(1, of: id).isEmpty, "a piece renamed to another never opens")
        #expect(try store.readChunk(0, of: id).count == 3)
        #expect(try store.chunks(of: id) == [0])
        #expect(try !Self.tripFiles(vault).contains(WorldMapVault.File.roadTrips.name))
    }
}
