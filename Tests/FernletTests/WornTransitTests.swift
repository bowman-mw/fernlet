import CryptoKit
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Ferry and train paths (Docs/World-Transit-Paths-Exploration-2026-11-15.md §2, §3, §9): the classifier over a fake
/// ground, the kept trips' store (codec, pieces, locked writes, the cap), and the fog keeper keeping each ride at its
/// end, changing and forgetting one, asking at most once a day, the wipe and the decoy.
@MainActor
struct WornTransitTests {
    private nonisolated static let here = GeoPoint(45.5205, -122.6255)
    private nonisolated static let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// A ground made of straight east–west lines at fixed offsets north of ``here``, and water east of ``here`` in
    /// `waterEast`.
    private nonisolated struct FakeGround: WornTransitGeography {
        let origin = GeoPoint(45.5205, -122.6255)
        var waterEast: ClosedRange<Double>?
        var roadNorth: [Double] = []
        var railNorth: [Double] = []
        var ferryRouteNorth: [Double] = []

        private func offset(_ point: GeoPoint) -> (east: Double, north: Double) { point.metres(from: origin) }

        func isWater(_ point: GeoPoint) -> Bool { waterEast?.contains(offset(point).east) ?? false }
        func isNearMajorRoad(_ point: GeoPoint, within metres: Double) -> Bool { near(roadNorth, point, metres) }
        func isNearRail(_ point: GeoPoint, within metres: Double) -> Bool { near(railNorth, point, metres) }
        func isNearFerryRoute(_ point: GeoPoint, within metres: Double) -> Bool { near(ferryRouteNorth, point, metres) }

        private func near(_ lines: [Double], _ point: GeoPoint, _ metres: Double) -> Bool {
            let north = offset(point).north
            return lines.contains { abs($0 - north) <= metres }
        }
    }

    /// Samples every `step` metres east from `from` to `to` (metres east of ``here``) along `north`, at `speed` m/s,
    /// starting at `start`; `stopEvery` metres a 30 s stop.
    private static func ride(from: Double, to: Double, north: Double = 0, speed: Double, step: Double = 50,
                             start: Date = now, inCar: Bool? = nil, stopEvery: Double? = nil) -> [WornRideSample] {
        var samples: [WornRideSample] = []
        var at = start
        var east = from
        var sinceStop = 0.0
        while east <= to {
            let point = here.offset(east: east, north: north)
            samples.append(WornRideSample(point: point, at: at, speed: speed, inCar: inCar))
            if let stopEvery, sinceStop >= stopEvery {
                at = at.addingTimeInterval(30)
                samples.append(WornRideSample(point: point, at: at, speed: 0, inCar: inCar))
                sinceStop = 0
            }
            east += step
            sinceStop += step
            at = at.addingTimeInterval(step / speed)
        }
        return samples
    }

    /// Joins rides so each starts where the last ended in time.
    private static func joined(_ parts: [[WornRideSample]]) -> [WornRideSample] {
        var all: [WornRideSample] = []
        for part in parts {
            let shift = (all.last?.at.timeIntervalSince(part.first?.at ?? now) ?? 0) + (all.isEmpty ? 0 : 5)
            all += part.map { WornRideSample(point: $0.point, at: $0.at.addingTimeInterval(shift), speed: $0.speed, inCar: $0.inCar) }
        }
        return all
    }

    private static let noLearned: (HexCell) -> Bool = { _ in false }

    // MARK: Ferry

    /// A 4 km crossing at 30 km/h near a bundled route is a sure ferry, split from the drive either side; without the
    /// route or docking it is unsure; a car on board is still a ferry.
    @Test func aFerryOverWaterIsSureNearARoute() {
        let ground = FakeGround(waterEast: 500...4_500, roadNorth: [], ferryRouteNorth: [300])
        let trip = Self.joined([Self.ride(from: -2_000, to: 450, speed: 15),
                                Self.ride(from: 500, to: 4_500, speed: 8.3, step: 40),
                                Self.ride(from: 4_550, to: 7_000, speed: 15)])
        #expect(WornRideClassifier.classify(trip, geography: ground, learnedRail: Self.noLearned) == WornRideVerdict(kind: .ferry, confidence: .sure))
        let segments = WornRideClassifier.segments(trip, geography: ground, learnedRail: Self.noLearned)
        #expect(segments.map(\.verdict.kind) == [.road, .ferry, .road])
        #expect(segments.first?.range.lowerBound == 0 && segments.last?.range.upperBound == trip.count)
        let noRoute = FakeGround(waterEast: 500...4_500)
        #expect(WornRideClassifier.classify(trip, geography: noRoute, learnedRail: Self.noLearned) == WornRideVerdict(kind: .ferry, confidence: .unsure))
        let docking = Self.joined([Self.ride(from: 500, to: 500, speed: 1), Self.ride(from: 550, to: 4_400, speed: 8.3),
                                   Self.ride(from: 4_450, to: 4_450, speed: 1)])
        #expect(WornRideClassifier.classify(docking, geography: noRoute, learnedRail: Self.noLearned).confidence == .sure,
                "slow at both ends is docking")
        let carOnBoard = Self.ride(from: 500, to: 4_500, speed: 8.3, inCar: true)
        #expect(WornRideClassifier.classify(carOnBoard, geography: ground, learnedRail: Self.noLearned).kind == .ferry)
    }

    /// A 1.5 km bridge at 80 km/h along a major road is a road.
    @Test func aBridgeAlongARoadIsARoad() {
        let ground = FakeGround(waterEast: 0...1_500, roadNorth: [0])
        let bridge = Self.ride(from: -1_000, to: 2_500, speed: 22.2)
        #expect(WornRideClassifier.classify(bridge, geography: ground, learnedRail: Self.noLearned) == .road)
        let slowJam = Self.ride(from: -1_000, to: 2_500, speed: 6)
        #expect(WornRideClassifier.classify(slowJam, geography: ground, learnedRail: Self.noLearned) == .road,
                "a jam on a bridge is still on the road's line")
    }

    /// A 500 m crossing is too short for a ferry.
    @Test func aShortCrossingIsARoad() {
        let ground = FakeGround(waterEast: 0...500)
        let crossing = Self.ride(from: -1_000, to: 1_500, speed: 8)
        #expect(WornRideClassifier.classify(crossing, geography: ground, learnedRail: Self.noLearned) == .road)
    }

    // MARK: Train

    /// A ride along rail with no car is rail (F13 3B): unsure on the rail line alone, sure with 130 km/h for minutes as
    /// well, or on the person's own learned line unless a major road runs beside it the whole way.
    @Test func aTrainAlongRailIsRail() {
        let unsure = WornRideVerdict(kind: .rail, confidence: .unsure), sure = WornRideVerdict(kind: .rail, confidence: .sure)
        let ground = FakeGround(roadNorth: [200], railNorth: [0])
        let train = Self.ride(from: 0, to: 20_000, speed: 25, inCar: false, stopEvery: 6_000)
        #expect(WornRideClassifier.classify(train, geography: ground, learnedRail: Self.noLearned) == unsure)
        let learned = Set(WornFootpaths.cells(along: train.map(\.point)))
        #expect(WornRideClassifier.classify(train, geography: ground, learnedRail: { learned.contains($0) }) == unsure,
                "a learned line beside a road the whole way asks (light rail in a motorway median)")
        let farRoad = FakeGround(roadNorth: [2_000], railNorth: [0])
        #expect(WornRideClassifier.classify(train, geography: farRoad, learnedRail: { learned.contains($0) }) == sure)
        #expect(WornRideClassifier.classify(train, geography: FakeGround(roadNorth: [2_000]), learnedRail: { learned.contains($0) })
                == sure, "the person's own line, away from roads, with no rail layer")
        let fast = Self.ride(from: 0, to: 20_000, speed: 45)
        #expect(WornRideClassifier.classify(fast, geography: ground, learnedRail: Self.noLearned) == sure)
        #expect(WornRideClassifier.classify(fast, geography: FakeGround(roadNorth: [2_000]), learnedRail: Self.noLearned) == unsure,
                "speed alone asks")
        #expect(WornRideClassifier.classify(train, geography: FakeGround(roadNorth: [200]), learnedRail: Self.noLearned) == .road)
        #expect(WornRideClassifier.fastSpeed == 36, "the owner kept 130 km/h")
    }

    /// Rail plus long-spaced stops far from any road no longer makes a sure train, and learned rail plus mapped rail are
    /// one sign, not two (F13 3B).
    @Test func supportingSignsAndLearnedRailDoNotMakeItSure() {
        let ground = FakeGround(roadNorth: [200], railNorth: [0])
        let quiet = FakeGround(railNorth: [0])
        let train = Self.ride(from: 0, to: 20_000, speed: 25, inCar: false, stopEvery: 6_000)
        #expect(WornRideClassifier.classify(train, geography: quiet, learnedRail: Self.noLearned).confidence == .unsure)
        let learned = Set(WornFootpaths.cells(along: train.map(\.point)))
        #expect(WornRideClassifier.classify(train, geography: ground, learnedRail: { learned.contains($0) }).confidence == .unsure)
    }

    /// A kept ride needs 60 s and 500 m (F13 2B).
    @Test func aRideNeedsAMinuteAndHalfAKilometre() {
        #expect(WornRideClassifier.isLongEnough(Self.ride(from: 0, to: 600, speed: 8)))
        #expect(!WornRideClassifier.isLongEnough(Self.ride(from: 0, to: 450, speed: 3)), "under 500 m")
        #expect(!WornRideClassifier.isLongEnough(Self.ride(from: 0, to: 1_000, speed: 25)), "under a minute")
        #expect(!WornRideClassifier.isLongEnough([]))
    }

    /// Learned rail needs Train-marked rides on two different days; unmarked rail never teaches.
    @Test func learnedRailNeedsTwoTrainDays() {
        let line = (0...40).map { Self.here.offset(east: Double($0) * 50, north: 0) }
        func train(day: UInt16, marked: Bool = true, north: Double = 0) -> WornTrip {
            WornTrip(kind: .rail, confirmed: true, markedTrain: marked, day: day, start: Self.now, end: Self.now,
                     line: line.map { $0.offset(east: 0, north: north) })
        }
        #expect(WornRideClassifier.learnedRailCells(from: [train(day: 1), train(day: 1)]).isEmpty, "one day")
        #expect(WornRideClassifier.learnedRailCells(from: [train(day: 1), train(day: 2, marked: false)]).isEmpty, "Not sure")
        let learned = WornRideClassifier.learnedRailCells(from: [train(day: 1), train(day: 2, north: 12)])
        #expect(learned.contains(MercatorHexGrid.cell(containing: line[20])), "two days, a few metres apart")
        #expect(WornRideClassifier.learnedDays == 2)
    }

    /// A bus beside rail stopping every 400 m, with no car connected, is unsure at most.
    @Test func aBusBesideRailIsUnsureAtMost() {
        let ground = FakeGround(roadNorth: [0], railNorth: [80])
        let bus = Self.ride(from: 0, to: 8_000, speed: 10, inCar: false, stopEvery: 400)
        let learned = Set(WornFootpaths.cells(along: bus.map(\.point)))
        let verdict = WornRideClassifier.classify(bus, geography: ground, learnedRail: { learned.contains($0) })
        #expect(verdict.kind == .road || verdict.confidence == .unsure, "even on learned rail, bus stops cap it")
        let unlearned = WornRideClassifier.classify(bus, geography: ground, learnedRail: Self.noLearned)
        #expect(unlearned.kind == .road || unlearned.confidence == .unsure)
    }

    /// A car connected all along is a road, however much it looks like a train.
    @Test func aConnectedCarIsARoad() {
        let ground = FakeGround(railNorth: [0])
        let car = Self.ride(from: 0, to: 20_000, speed: 40, inCar: true)
        let learned = Set(WornFootpaths.cells(along: car.map(\.point)))
        #expect(WornRideClassifier.classify(car, geography: ground, learnedRail: { learned.contains($0) }) == .road)
    }

    /// More samples than the bound are thinned evenly, keeping the last.
    @Test func longRidesAreThinned() {
        let long = Self.ride(from: 0, to: 500_000, speed: 30, step: 20)
        let thinned = WornRideClassifier.thin(long)
        #expect(long.count > WornRideClassifier.maxSamples && thinned.count <= WornRideClassifier.maxSamples)
        #expect(thinned.first == long.first && thinned.last == long.last)
    }

    // MARK: The trip store

    /// A small line on 1/100,000-degree steps.
    private static func line(_ count: Int, east: Double = 0) -> [GeoPoint] {
        (0..<count).map { index in
            let point = here.offset(east: east + Double(index) * 30, north: Double(index % 3) * 10)
            return GeoPoint((point.latitude * 100_000).rounded() / 100_000, (point.longitude * 100_000).rounded() / 100_000)
        }
    }

    private static func trip(_ kind: WornWayKind = .rail, minutes: Double = 0, points: Int = 20) -> WornTrip {
        WornTrip(kind: kind, confirmed: false, day: WornDay.number(for: now), start: now.addingTimeInterval(minutes * 60),
                 end: now.addingTimeInterval(minutes * 60 + 600), line: line(points))
    }

    /// The codec round-trips every field, keeps a commute small, skips lines for summaries and refuses bad bytes.
    @Test func theTripCodecRoundTrips() throws {
        let trips: [(trip: WornTrip, unsure: Bool)] = [
            (WornTrip(kind: .ferry, confirmed: true, day: 4_000, start: Self.now, end: Self.now.addingTimeInterval(1_800),
                      line: Self.line(800)), true),
            (WornTrip(kind: .road, confirmed: false, day: 4_001, start: Self.now, end: Self.now, line: []), false),
        ]
        let data = WornTripCodec.encode(trips)
        #expect(data.count < 5 * 1_024, "an 800-point line takes a few KB")
        let decoded = try #require(WornTripCodec.decode(data, limit: 10))
        #expect(decoded.count == 2)
        for (index, (trip, unsure)) in decoded.enumerated() {
            let original = trips[index]
            #expect(trip.id == original.trip.id && trip.kind == original.trip.kind && trip.confirmed == original.trip.confirmed)
            #expect(trip.day == original.trip.day && trip.start == original.trip.start && trip.end == original.trip.end)
            #expect(unsure == original.unsure && trip.line.count == original.trip.line.count)
            for (a, b) in zip(trip.line, original.trip.line) {
                #expect(abs(a.latitude - b.latitude) < 1e-9 && abs(a.longitude - b.longitude) < 1e-9)
            }
        }
        let summaries = try #require(WornTripCodec.decodeSummaries(data, chunk: 7, limit: 10))
        #expect(summaries.map(\.id) == trips.map(\.trip.id) && summaries.allSatisfy { $0.chunk == 7 })
        #expect(WornTripCodec.decode(data.dropLast(), limit: 10) == nil, "a cut-off file is refused")
        #expect(WornTripCodec.decode(data, limit: 1) == nil, "more than the limit is refused")
        #expect(WornTripCodec.decode(Data([9]) + data.dropFirst(), limit: 10) == nil, "an unknown version is refused")
    }

    /// Version 2 keeps the Train mark; version 1 files still read; each version refuses flag bits it doesn't know.
    @Test func theTripCodecReadsVersionOne() throws {
        let marked = WornTrip(kind: .rail, confirmed: true, markedTrain: true, day: 4_000, start: Self.now, end: Self.now,
                              line: Self.line(5))
        let plain = WornTrip(kind: .rail, confirmed: true, day: 4_000, start: Self.now, end: Self.now, line: Self.line(5))
        let data = WornTripCodec.encode([(marked, false)])
        let decoded = try #require(WornTripCodec.decode(data, limit: 1))
        #expect(data.first == 2 && decoded.first?.trip.markedTrain == true)
        #expect(WornTripCodec.decodeSummaries(data, chunk: 0, limit: 1)?.first?.markedTrain == true)
        var versionOne = WornTripCodec.encode([(plain, true)])
        versionOne[versionOne.startIndex] = 1
        let old = try #require(WornTripCodec.decode(versionOne, limit: 1))
        #expect(old.first.map { $0.trip.confirmed && !$0.trip.markedTrain && $0.unsure } == true)
        var markedOne = data
        markedOne[markedOne.startIndex] = 1
        #expect(WornTripCodec.decode(markedOne, limit: 1) == nil, "bit 2 is unknown in version 1")
        var unknownBit = data
        unknownBit[unknownBit.startIndex + 5 + 17] |= 8
        #expect(WornTripCodec.decode(unknownBit, limit: 1) == nil, "bit 3 is unknown in version 2")
    }

    /// The checkpoint keeps whether the ride watch saw a drive; a version 1 checkpoint reads as one that did; the queue
    /// round-trips its rides.
    @Test func theCheckpointAndQueueRoundTrip() throws {
        let samples = [WornRideSample(point: Self.here, at: Self.now, speed: 12.5, inCar: true),
                       WornRideSample(point: Self.here.offset(east: 30, north: 0), at: Self.now.addingTimeInterval(2), speed: nil, inCar: nil)]
        let offDrive = WornRideCheckpoint(samples: samples, sawDrive: false)
        let data = WornRideCheckpointCodec.encode(offDrive)
        #expect(WornRideCheckpointCodec.decode(data, limit: 5) == offDrive)
        var versionOne = Data([1])
        versionOne.append(data.dropFirst(2))
        #expect(WornRideCheckpointCodec.decode(versionOne, limit: 5) == WornRideCheckpoint(samples: samples, sawDrive: true))
        #expect(WornRideCheckpointCodec.decode(data, limit: 1) == nil, "more than the limit is refused")
        let rides = [offDrive, WornRideCheckpoint(samples: samples.reversed(), sawDrive: true)]
        #expect(WornRideQueueCodec.decode(WornRideQueueCodec.encode(rides), limit: 5) == rides)
        #expect(WornRideQueueCodec.decode(WornRideQueueCodec.encode(rides).dropLast(), limit: 5) == nil)
    }

    /// Trips go in pieces of 200; a reopened store has them all; an emptied slot fills first; a delete and an update
    /// stick; the cell index finds the trips through a cell.
    @Test func theStoreKeepsTripsInPieces() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let store = WornTripStore(vault: vault)
        try store.load()
        let trips = (0..<450).map { Self.trip(minutes: Double($0)) }
        for trip in trips { #expect(try store.append(trip, unsure: false)) }
        let pieces = try vault.fileNames(withPrefix: WorldMapVault.File.wornTripsPrefix, limit: 100)
        #expect(pieces.count == 3)
        let reopened = WornTripStore(vault: vault)
        try reopened.load()
        #expect(reopened.summaries.count == 450 && reopened.summaries.first?.id == trips.last?.id, "newest first")
        try reopened.delete(trips[3].id)
        try reopened.update(trips[4].id, kind: .ferry, confirmed: true)
        let late = Self.trip(minutes: 10_000)
        try reopened.append(late, unsure: true)
        #expect(reopened.summaries.first { $0.id == late.id }?.chunk == 0, "the emptied slot in piece 0 fills first")
        let again = WornTripStore(vault: vault)
        try again.load()
        #expect(again.summaries.count == 450 && !again.summaries.contains { $0.id == trips[3].id })
        #expect(again.summaries.first { $0.id == trips[4].id }.map { $0.kind == .ferry && $0.confirmed } == true)
        #expect(again.summaries.first?.unsure == true)
        let cell = MercatorHexGrid.cell(containing: Self.line(20)[5])
        #expect(try again.trips(through: cell).count == 450)
        #expect(try again.trips(through: MercatorHexGrid.cell(containing: Self.here.offset(east: 50_000, north: 0))).isEmpty)
    }

    /// With the store key unreadable (the phone locked) trips still write and read under the buffer key.
    @Test func aLockedPhoneWritesThroughTheBufferKey() throws {
        let buffer = SymmetricKey(size: .bits256)
        let keys = WorldMapKeys(key: { role in
            guard role == .buffer else { throw WorldMapVault.VaultError.keyUnavailable }
            return buffer
        }, removeAll: { true })
        let vault = WorldMapVault(directory: FileManager.default.temporaryDirectory.appendingPathComponent("WornTrips-\(UUID().uuidString)"),
                                  keys: keys)
        defer { _ = vault.clearAll() }
        #expect(throws: WorldMapVault.VaultError.keyUnavailable) { try vault.write(Data([1]), to: .wornWays) }
        let store = WornTripStore(vault: vault)
        try store.load()
        let trip = Self.trip()
        #expect(try store.append(trip, unsure: true))
        try store.recordAsked(day: 9, trip: trip.id)
        let reopened = WornTripStore(vault: vault)
        try reopened.load()
        #expect(reopened.summaries.map(\.id) == [trip.id] && reopened.lastAskedDay == 9 && reopened.askedTripID == trip.id)
        #expect(WorldMapVault.File.wornTrips(chunk: 0).role == .buffer && WorldMapVault.File.wornTripRide.role == .buffer)
    }

    /// Past the cap a trip is refused and counted, never evicting one.
    @Test func theStoreRefusesPastItsCap() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let store = WornTripStore(vault: vault, limit: 3)
        try store.load()
        let trips = (0..<3).map { Self.trip(minutes: Double($0)) }
        for trip in trips { #expect(try store.append(trip, unsure: false)) }
        #expect(try store.append(Self.trip(minutes: 9), unsure: false) == false)
        #expect(store.refusedCount == 1 && Set(store.summaries.map(\.id)) == Set(trips.map(\.id)))
        #expect(WornTripStore.maxTrips == 100_000 && WornTripStore.maxChunks * WornTripStore.tripsPerChunk == WornTripStore.maxTrips)
    }

    // MARK: The fog keeper

    /// A keeper over `vault` whose clock reads `clock`, loaded.
    private static func keeper(_ vault: WorldMapVault, ground: FakeGround?, clock: Date = now) throws -> WorldFogKeeper {
        let defaults = try #require(UserDefaults(suiteName: "WornTransitTests.\(UUID().uuidString)"))
        defaults.set(true, forKey: WorldMapPreferences.Key.alwaysLowPower)
        let keeper = WorldFogKeeper(vault: vault, defaults: defaults, isProtectedDataAvailable: { true })
        keeper.now = { clock }
        keeper.transitGeography = ground
        keeper.load()
        return keeper
    }

    /// Rides a train east along ``here``'s rail line for `metres` at 25 m/s, starting `minutes` after ``now``, then
    /// walks (the ride ends). `onDrive` is what the ride watch said.
    private static func rideTrain(_ keeper: WorldFogKeeper, minutes: Double = 0, metres: Double = 10_000,
                                  onDrive: Bool = true) async {
        let start = now.addingTimeInterval(minutes * 60)
        for (index, east) in stride(from: 0.0, through: metres, by: 50).enumerated() {
            keeper.handle(WorldFix(point: here.offset(east: east, north: 0), accuracy: 8, at: start.addingTimeInterval(Double(index) * 2),
                                   isPrecise: true, speed: 25), thinLine: onDrive)
        }
        keeper.handle(WorldFix(point: here.offset(east: metres + 50, north: 0), accuracy: 8,
                               at: start.addingTimeInterval(metres / 25 + 60), isPrecise: true))
        await keeper.settleTrips()
    }

    private static let railGround = FakeGround(roadNorth: [300], railNorth: [0])

    /// A ride's end keeps one trip and counts its cells once under its kind; changing it moves the passes, forgetting
    /// it takes them out.
    @Test func aTripEndKeepsItAndChangesMoveThePasses() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, ground: Self.railGround)
        await Self.rideTrain(keeper)
        let trip = try #require(keeper.wornTrips.first)
        #expect(keeper.wornTrips.count == 1 && trip.kind == .rail && trip.unsure && !trip.confirmed)
        let line = try #require(keeper.trips(through: MercatorHexGrid.cell(containing: Self.here.offset(east: 5_000, north: 0))).first)
        #expect(line.id == trip.id)
        let cells = WornFootpaths.cells(along: line.line)
        #expect(Set(keeper.wornWays.keys) == Set(cells.map { WornWayKey(cell: $0, kind: .rail) }))
        #expect(keeper.wornWays.values.allSatisfy { $0.count == 1 })
        keeper.changeTrip(trip.id, to: .road)
        #expect(Set(keeper.wornWays.keys) == Set(cells.map { WornWayKey(cell: $0, kind: .road) }))
        #expect(keeper.wornTrips.first.map { $0.kind == .road && $0.confirmed } == true)
        keeper.forgetTrip(trip.id)
        #expect(keeper.wornWays.isEmpty && keeper.wornTrips.isEmpty)
        let reopened = try Self.keeper(vault, ground: Self.railGround)
        #expect(reopened.wornWays.isEmpty && reopened.wornTrips.isEmpty)
    }

    /// Without geography a ride waits unsorted and is sorted when the ground arrives (F13 4B); "Forget this path" takes
    /// the trips of that kind through a cell.
    @Test func noGeographyWaitsAndAPathCanBeForgotten() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, ground: nil)
        await Self.rideTrain(keeper)
        await Self.rideTrain(keeper, minutes: 60)
        #expect(keeper.wornTrips.isEmpty && keeper.wornWays.isEmpty)
        #expect(try vault.read(.wornTripQueue) != nil)
        keeper.transitGeography = FakeGround()
        await keeper.settleTrips()
        #expect(try vault.read(.wornTripQueue) == nil, "the queue empties once sorted")
        #expect(keeper.wornTrips.count == 2 && keeper.wornTrips.allSatisfy { $0.kind == .road && !$0.unsure })
        #expect(keeper.transitQuestion == nil)
        let cell = MercatorHexGrid.cell(containing: Self.here.offset(east: 5_000, north: 0))
        #expect(keeper.wornWays[WornWayKey(cell: cell, kind: .road)]?.count == 2)
        keeper.forgetPath(through: cell, kind: .road)
        #expect(keeper.wornTrips.isEmpty && keeper.wornWays.isEmpty)
    }

    /// Home asks about the newest unsure ride at most once a day; an answer clears it and is kept.
    @Test func theQuestionComesOnceADay() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, ground: Self.railGround)
        await Self.rideTrain(keeper)
        let first = try #require(keeper.transitQuestion)
        keeper.answerTransitQuestion(nil)
        #expect(keeper.transitQuestion == nil)
        #expect(keeper.wornTrips.first { $0.id == first.id }.map { $0.confirmed && $0.kind == .rail } == true, "Not sure keeps the guess")
        await Self.rideTrain(keeper, minutes: 60)
        #expect(keeper.transitQuestion == nil, "one question a day")
        let tomorrow = Self.now.addingTimeInterval(86_400)
        keeper.now = { tomorrow }
        keeper.load()
        let second = try #require(keeper.transitQuestion)
        #expect(second.id != first.id)
        keeper.answerTransitQuestion(.ferry)
        #expect(keeper.transitQuestion == nil)
        #expect(keeper.wornTrips.first { $0.id == second.id }.map { $0.confirmed && $0.kind == .ferry } == true)
        let reopened = try Self.keeper(vault, ground: Self.railGround, clock: tomorrow)
        #expect(reopened.transitQuestion == nil, "the day's question was asked; it isn't asked again")
    }

    /// The wipe forgets the trips, the question, the ride and their files.
    @Test func clearAllEmptiesTheTrips() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, ground: Self.railGround)
        await Self.rideTrain(keeper)
        #expect(!keeper.wornTrips.isEmpty && keeper.transitQuestion != nil)
        _ = keeper.clearAll()
        #expect(keeper.wornTrips.isEmpty && keeper.transitQuestion == nil && keeper.wornWays.isEmpty)
        #expect(try vault.fileNames(withPrefix: "worn-trip", limit: 10).isEmpty)
        let reopened = try Self.keeper(vault, ground: Self.railGround)
        #expect(reopened.wornTrips.isEmpty && reopened.trips(through: MercatorHexGrid.cell(containing: Self.here)).isEmpty)
    }

    /// A decoy keeps no ride and shows no trip or question.
    @Test func aDecoyKeepsNothing() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, ground: Self.railGround)
        keeper.setDecoy(true)
        await Self.rideTrain(keeper)
        #expect(keeper.wornTrips.isEmpty && keeper.transitQuestion == nil && keeper.wornWays.isEmpty)
        #expect(keeper.trips(through: MercatorHexGrid.cell(containing: Self.here.offset(east: 5_000, north: 0))).isEmpty)
        keeper.setDecoy(false)
        #expect(keeper.wornTrips.isEmpty && keeper.tripStore.summaries.isEmpty)
        #expect(try vault.read(.wornTripRide) == nil)
    }

    /// A ride longer than the checkpoint interval is written; a launch after the trip gap keeps it as ended.
    @Test func aCheckpointedRideIsKeptAfterARelaunch() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, ground: FakeGround())
        for (index, east) in stride(from: 0.0, through: 6_000, by: 50).enumerated() {
            keeper.handle(WorldFix(point: Self.here.offset(east: east, north: 0), accuracy: 8,
                                   at: Self.now.addingTimeInterval(Double(index) * 2), isPrecise: true, speed: 25), thinLine: true)
        }
        #expect(try vault.read(.wornTripRide) != nil)
        #expect(keeper.wornTrips.isEmpty)
        let relaunched = try Self.keeper(vault, ground: FakeGround(), clock: Self.now.addingTimeInterval(3_600))
        await relaunched.settleTrips()
        #expect(relaunched.wornTrips.count == 1 && relaunched.wornTrips.first?.kind == .road)
        #expect(!relaunched.wornWays.isEmpty)
        #expect(try vault.read(.wornTripRide) == nil, "the kept ride's checkpoint goes")
    }

    // MARK: F13 (owner 2026-11-19)

    /// A ride under a minute or half a kilometre is not kept; a ride the ride watch never called a drive keeps only its
    /// rail and ferry stretches (F13 2B).
    @Test func smallAndOffDriveRidesKeepLess() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, ground: Self.railGround)
        await Self.rideTrain(keeper, metres: 400)
        #expect(keeper.wornTrips.isEmpty && keeper.wornWays.isEmpty, "a 16 s burst")
        await Self.rideTrain(keeper, minutes: 30, onDrive: false)
        #expect(keeper.wornTrips.map(\.kind) == [.rail], "off a drive, a train along rail is kept")
        keeper.transitGeography = FakeGround()
        await Self.rideTrain(keeper, minutes: 60, onDrive: false)
        #expect(keeper.wornTrips.count == 1, "off a drive, a road stretch is not")
    }

    /// A ride a cycling workout overlaps is not kept, and one a late workout overlaps goes at the next load, unless the
    /// person confirmed it (F13 2B, the owner's idea).
    @Test func aCyclingWorkoutDropsTheRide() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, ground: Self.railGround)
        let bike = DateInterval(start: Self.now, duration: 600)
        keeper.cyclingWorkouts = { $0.intersects(bike) ? [bike] : [] }
        await Self.rideTrain(keeper)
        #expect(keeper.wornTrips.isEmpty && keeper.wornWays.isEmpty)
        keeper.cyclingWorkouts = { _ in [] }
        await Self.rideTrain(keeper, minutes: 60)
        await Self.rideTrain(keeper, minutes: 120)
        let confirmed = try #require(keeper.wornTrips.first)
        keeper.changeTrip(confirmed.id, to: .rail)
        let late = DateInterval(start: Self.now.addingTimeInterval(3_500), duration: 7_500)
        keeper.cyclingWorkouts = { $0.intersects(late) ? [late] : [] }
        keeper.load()
        #expect(keeper.wornTrips.map(\.id) == [confirmed.id], "the unconfirmed ride goes; the answered one stays")
    }

    /// Only Train answers on two different days teach a line; "Not sure" never does; a learned ride away from roads is
    /// then sure, and beside a road the whole way still asks (F13 3B).
    @Test func trainAnswersOnTwoDaysTeachALine() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let ground = FakeGround(roadNorth: [2_000], railNorth: [0])
        let keeper = try Self.keeper(vault, ground: ground)
        func rideAndAnswer(_ minutes: Double, train: Bool) async throws -> WornTripSummary {
            await Self.rideTrain(keeper, minutes: minutes)
            let trip = try #require(keeper.wornTrips.first)
            if train { keeper.changeTrip(trip.id, to: .rail) } else { try keeper.tripStore.update(trip.id, kind: .rail, confirmed: true) }
            return trip
        }
        #expect(try await rideAndAnswer(0, train: false).unsure)
        #expect(try await rideAndAnswer(1_440, train: false).unsure, "Not sure on day 1 taught nothing")
        #expect(try await rideAndAnswer(2_880, train: true).unsure)
        #expect(try await rideAndAnswer(2_940, train: true).unsure, "two answers the same day are one day")
        #expect(try await rideAndAnswer(4_320, train: true).unsure)
        await Self.rideTrain(keeper, minutes: 4_380)
        #expect(keeper.wornTrips.first.map { $0.kind == .rail && !$0.unsure } == true, "two days: the person's own line")
        keeper.transitGeography = FakeGround(roadNorth: [100], railNorth: [0])
        await Self.rideTrain(keeper, minutes: 4_440)
        #expect(keeper.wornTrips.first?.unsure == true, "beside a major road the whole way it still asks")
    }

    /// A full queue keeps a ride as a road, as before (F13 4B's bound).
    @Test func aFullQueueKeepsARoad() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, ground: nil)
        for index in 0...WornRideQueueCodec.maxRides { await Self.rideTrain(keeper, minutes: Double(index) * 20, metres: 2_000) }
        #expect(keeper.wornTrips.map(\.kind) == [.road])
        let queued = try #require(try vault.read(.wornTripQueue))
        #expect(WornRideQueueCodec.decode(queued, limit: WornRideClassifier.maxSamples)?.count == WornRideQueueCodec.maxRides)
    }
}
