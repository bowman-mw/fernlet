import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Bike rides on Where you've been's timeline (Refinements group 19, `ref-ride-timeline`, owner-approved
/// 2026-10-29): the additive `ride` kind, kept 30 days and deleted like a walk (its line goes, the workout
/// stays), the keeper's capture and Undo, the row's words and VoiceOver, and the stored logs skipping a stop
/// of a kind this build doesn't know instead of failing whole.
@MainActor
struct WorldRideTimelineTests {
    private static let park = GeoPoint(45.5213, -122.6253)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// A day with a visit, a ride (with its workout) and a walk, the ride between them.
    private static func dayLog(rideWorkout: UUID) -> (log: PlaceLog, ride: PlaceStop) {
        let oak = PlaceRecord(label: "Oak Park", point: park, visits: 1)
        let ride = PlaceStop(kind: .ride, at: now.addingTimeInterval(-2 * 3_600), metres: 4_200, workoutID: rideWorkout)
        let stops = [PlaceStop(kind: .visit, at: now.addingTimeInterval(-3 * 3_600), placeID: oak.id), ride,
                     PlaceStop(kind: .walk, at: now.addingTimeInterval(-3_600), metres: 900, workoutID: UUID())]
        return (PlaceLog(places: [oak], stops: stops), ride)
    }

    // MARK: The kind

    /// The ride kind's raw value is frozen as "ride", and a ride is an outing like a walk or a run.
    @Test func theRideKindIsFrozenAndAnOuting() throws {
        #expect(PlaceStop.Kind.ride.rawValue == "ride")
        #expect(PlaceStop(kind: .ride, at: Self.now).isOuting)
        #expect(PlaceStop(kind: .walk, at: Self.now).isOuting && PlaceStop(kind: .run, at: Self.now).isOuting)
        #expect(!PlaceStop(kind: .visit, at: Self.now).isOuting && !PlaceStop(kind: .leftHome, at: Self.now).isOuting)
        let data = try JSONEncoder().encode(PlaceStop(kind: .ride, at: Self.now, metres: nil, workoutID: UUID()))
        let read = try JSONDecoder().decode(PlaceStop.self, from: data)
        #expect(read.kind == .ride && read.metres == nil)
    }

    /// Delete a day takes the ride with it and names its workout so its line goes; Delete this stop on a
    /// ride does the same and leaves the places' counts alone; rides don't count toward out and about.
    @Test func aRideIsDeletedLikeAWalk() throws {
        let workout = UUID()
        let sample = Self.dayLog(rideWorkout: workout)
        let day = Calendar.current.startOfDay(for: sample.ride.at)
        let dayGone = sample.log.deletingDay(day)
        #expect(dayGone.workoutIDs.contains(workout))
        #expect(!dayGone.log.stops.contains { $0.kind == .ride })
        let stopGone = sample.log.deletingStop(sample.ride.id)
        #expect(stopGone.workoutIDs == [workout] && stopGone.removedPlaces.isEmpty)
        #expect(stopGone.log.places == sample.log.places)
        #expect(stopGone.log.stops.map(\.kind) == [.visit, .walk])
        #expect(sample.log.outAndAbout(on: day) == nil)
        let undone = sample.log.deletingOuting(workoutID: workout)
        #expect(undone.stops.map(\.kind) == [.visit, .walk], "the ride's Undo takes only its stop")
    }

    /// A ride is kept 30 days, like every stop on the timeline.
    @Test func aRideIsKeptThirtyDays() {
        let old = PlaceStop(kind: .ride, at: Self.now.addingTimeInterval(-31 * 86_400), metres: 3_000, workoutID: UUID())
        let recent = PlaceStop(kind: .ride, at: Self.now.addingTimeInterval(-29 * 86_400), metres: 3_000, workoutID: UUID())
        let pruned = PlaceLog(places: [], stops: [old, recent]).pruned(now: Self.now)
        #expect(pruned.stops == [recent])
    }

    // MARK: The keeper

    /// The keeper puts a ride on the timeline with or without its distance (a walk or run still needs one),
    /// takes it off again by its workout, and does neither in a decoy.
    @Test func theKeeperRecordsAndRemovesARide() throws {
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: SilentLookup(), remembersPlaces: { true },
                                       remembersEatingOut: { false })
        let measured = UUID(), unmeasured = UUID()
        #expect(keeper.recordOuting(.ride, at: Self.now, metres: 4_200, workoutID: measured))
        #expect(keeper.recordOuting(.ride, at: Self.now.addingTimeInterval(60), metres: nil, workoutID: unmeasured))
        #expect(!keeper.recordOuting(.walk, at: Self.now, metres: nil, workoutID: UUID()), "a walk needs its length")
        #expect(!keeper.recordOuting(.visit, at: Self.now, metres: 10, workoutID: UUID()))
        let pending = try keeper.store.deviceState().pending
        #expect(pending.map(\.kind) == [.ride, .ride])
        #expect(pending.map(\.metres) == [4_200, nil])
        #expect(keeper.removeOuting(workoutID: measured))
        #expect(try keeper.store.deviceState().pending.map(\.workoutID) == [unmeasured])
        #expect(!keeper.removeOuting(workoutID: UUID()), "nothing to remove")

        keeper.setDecoy(true)
        #expect(!keeper.recordOuting(.ride, at: Self.now, metres: 1_000, workoutID: UUID()))
        #expect(!keeper.removeOuting(workoutID: unmeasured))
        keeper.setDecoy(false)
        #expect(try keeper.store.deviceState().pending.count == 1, "a decoy changed nothing")
    }

    // MARK: Reading stored logs

    /// A stored log or device side holding a stop of a kind this build doesn't know (and an entry that is no
    /// stop at all) reads with that entry skipped; every other stop, place and part stays.
    @Test func anUnknownKindIsSkippedNotFatal() throws {
        let sample = Self.dayLog(rideWorkout: UUID())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        var log = try #require(try JSONSerialization.jsonObject(with: encoder.encode(sample.log)) as? [String: Any])
        var stops = try #require(log["stops"] as? [[String: Any]])
        stops[1]["kind"] = "teleport"
        log["stops"] = stops + [["kind": 42]]
        let read = try decoder.decode(PlaceLog.self, from: JSONSerialization.data(withJSONObject: log))
        #expect(read.stops.map(\.kind) == [.visit, .walk])
        #expect(read.places == sample.log.places && read.schemaVersion == PlaceLog.currentSchema)

        let device = PlaceDeviceState(known: [], pending: sample.log.stops, newPlaces: sample.log.places)
        var side = try #require(try JSONSerialization.jsonObject(with: encoder.encode(device)) as? [String: Any])
        var pending = try #require(side["pending"] as? [[String: Any]])
        pending[0]["kind"] = "hovercraft"
        side["pending"] = pending
        let readSide = try decoder.decode(PlaceDeviceState.self, from: JSONSerialization.data(withJSONObject: side))
        #expect(readSide.pending.map(\.kind) == [.ride, .walk])
        #expect(readSide.newPlaces == device.newPlaces && !readSide.needsMigration)
    }

    /// A first-format device side (no schema version, no homes or places to eat) still reads, now one stop
    /// at a time.
    @Test func aFirstFormatDeviceSideStillReads() throws {
        let json = #"{"known":[],"newPlaces":[],"pending":[{"id":"6C000000-0000-0000-0000-000000000001","kind":"walk","at":2000000000,"metres":900}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let side = try decoder.decode(PlaceDeviceState.self, from: Data(json.utf8))
        #expect(side.needsMigration && side.pending.map(\.kind) == [.walk] && side.homes == nil && side.restaurants == nil)
    }

    // MARK: The row

    /// "A bike ride", then "4.2 km · 18 min" in the person's units; minutes only for a ride with no
    /// distance; the distance alone when its workout is gone; VoiceOver in words, like the other rows.
    @Test func theRowReadsDistanceAndMinutes() {
        let ride = PlaceStop(kind: .ride, at: Self.now, metres: 4_200, workoutID: UUID())
        #expect(WorldPlacesCopy.stopTitle(ride, place: nil, name: nil) == "A bike ride")
        let distance = WorldWalkCopy.distance(4_200)
        let minutes = WorldPlacesCopy.rideMinutes(18, width: .abbreviated)
        #expect(WorldPlacesCopy.stopDetail(ride, name: nil, minutes: 18) == "\(distance) · \(minutes)")
        #expect(WorldPlacesCopy.rideDetail(metres: nil, minutes: 18) == minutes)
        #expect(WorldPlacesCopy.rideDetail(metres: 4_200, minutes: nil) == distance)
        #expect(WorldPlacesCopy.rideDetail(metres: nil, minutes: nil).isEmpty)
        let spoken = WorldPlacesCopy.spokenRide(at: Self.now, title: "A bike ride", metres: 4_200, minutes: 18)
        #expect(spoken.hasPrefix("\(Self.now.formatted(.dateTime.hour().minute())), A bike ride, "))
        #expect(spoken.hasSuffix(WorldPlacesCopy.rideMinutes(18, width: .wide)))
        #expect(WorldPlacesCopy.spokenRide(at: Self.now, title: "A bike ride", metres: nil, minutes: nil)
                == "\(Self.now.formatted(.dateTime.hour().minute())), A bike ride")
        #expect(WorldPlacesDeleteCopy.stopMessage(ride, place: nil, name: "A bike ride", homes: .empty)
                == "Its line leaves the day's sketch. The ride stays in Move.")
    }
}

/// A place lookup that never answers.
@MainActor
private final class SilentLookup: WorldPlaceLooking {
    func nearbyPlaces(around point: GeoPoint) async -> [NearbyPlace]? { nil }

    func placeName(for placeID: String) async -> WorldPlaceName? { nil }

    func forgetNames() {}
}
