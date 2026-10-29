import CryptoKit
import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// W-14 (Refinements group 18, owner-approved 2026-10-26): deleting one place, or one stop, in Where
/// you've been, without Delete a day's reach. The log's rules, the device side forgetting a deleted place
/// (and its map icon), the store's glue under the hub key and in a decoy, and the alert, menu, dialog and
/// VoiceOver models the screens draw from.
@MainActor
struct WorldPlacesDeleteTests {
    private static let park = GeoPoint(45.5213, -122.6253)
    private static let burgerPoint = park.offset(east: 900, north: 0)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// A log with Oak Park (3 visits over two days), Burger Barn (1 visit), a walk, and a leave and a return
    /// at home.
    private static func sampleLog(home: UUID = UUID(), walkWorkout: UUID = UUID()) -> (log: PlaceLog, oak: PlaceRecord, burger: PlaceRecord) {
        let oak = PlaceRecord(label: "Oak Park", placeID: "I-oak", point: park, visits: 3)
        let burger = PlaceRecord(placeID: "I-burger", point: burgerPoint, visits: 1)
        let stops = [
            PlaceStop(kind: .visit, at: now.addingTimeInterval(-86_400), placeID: oak.id),
            PlaceStop(kind: .leftHome, at: now.addingTimeInterval(-3 * 3_600), placeID: home),
            PlaceStop(kind: .visit, at: now.addingTimeInterval(-2.5 * 3_600), placeID: burger.id),
            PlaceStop(kind: .walk, at: now.addingTimeInterval(-2 * 3_600), metres: 1_200, workoutID: walkWorkout),
            PlaceStop(kind: .visit, at: now.addingTimeInterval(-1.5 * 3_600), placeID: oak.id),
            PlaceStop(kind: .visit, at: now.addingTimeInterval(-0.5 * 3_600), placeID: oak.id),
            PlaceStop(kind: .cameHome, at: now, placeID: home),
        ]
        return (PlaceLog(places: [oak, burger], stops: stops), oak, burger)
    }

    // MARK: The log

    /// Deleting a place removes its record and every visit to it on any day; every other place keeps its
    /// count, and the walk, the leave and the return stay. An unknown place changes nothing.
    @Test func deletingAPlaceRemovesItsRecordAndEveryStop() {
        let sample = Self.sampleLog()
        let result = sample.log.deletingPlace(sample.oak.id)
        #expect(result.log.places.map(\.id) == [sample.burger.id])
        #expect(result.log.places.first?.visits == 1, "Burger Barn keeps its visit")
        #expect(!result.log.stops.contains { $0.placeID == sample.oak.id }, "both days' visits went")
        #expect(result.log.stops.map(\.kind) == [.leftHome, .visit, .walk, .cameHome])
        #expect(result.workoutIDs.isEmpty, "no saved line goes with a place")
        #expect(result.removedPlaces == [sample.oak.id])
        let unknown = sample.log.deletingPlace(UUID())
        #expect(unknown.log == sample.log && unknown.removedPlaces.isEmpty)
    }

    /// Deleting a visit stop takes 1 off its place; a place left at 0 is gone from Places you return to and
    /// named for the device side to forget.
    @Test func deletingAVisitStopTakesOneOffItsPlace() throws {
        let sample = Self.sampleLog()
        let oakStop = try #require(sample.log.stops.first { $0.placeID == sample.oak.id })
        let fewer = sample.log.deletingStop(oakStop.id)
        #expect(fewer.log.places.first { $0.id == sample.oak.id }?.visits == 2)
        #expect(fewer.log.stops.count == sample.log.stops.count - 1 && fewer.removedPlaces.isEmpty)
        #expect(fewer.log.returnedTo.map(\.id) == [sample.oak.id, sample.burger.id])

        let burgerStop = try #require(sample.log.stops.first { $0.placeID == sample.burger.id })
        let gone = sample.log.deletingStop(burgerStop.id)
        #expect(!gone.log.returnedTo.contains { $0.id == sample.burger.id })
        #expect(!gone.log.places.contains { $0.id == sample.burger.id })
        #expect(gone.removedPlaces == [sample.burger.id])
        #expect(gone.log.places.first { $0.id == sample.oak.id }?.visits == 3, "Oak Park keeps its count")
        #expect(sample.log.deletingStop(UUID()).log == sample.log, "an unknown stop changes nothing")
    }

    /// A walk or run stop's delete names its workout, so the saved line goes; nothing else changes.
    @Test func deletingAWalkStopNamesItsLine() throws {
        let workout = UUID()
        let sample = Self.sampleLog(walkWorkout: workout)
        let walk = try #require(sample.log.stops.first { $0.kind == .walk })
        let result = sample.log.deletingStop(walk.id)
        #expect(result.workoutIDs == [workout])
        #expect(result.log.places == sample.log.places && result.removedPlaces.isEmpty)
    }

    /// A home's leave or return goes alone: no place is removed, so the device side's homes are untouched.
    @Test func deletingAHomeStopLeavesTheHomes() throws {
        let home = HomePlace(kind: .home, label: "Home", point: Self.park.offset(east: 0, north: 2_000))
        let sample = Self.sampleLog(home: home.id)
        let leave = try #require(sample.log.stops.first { $0.kind == .leftHome })
        let result = sample.log.deletingStop(leave.id)
        #expect(result.removedPlaces.isEmpty && result.workoutIDs.isEmpty)
        #expect(result.log.places == sample.log.places)
        let device = PlaceDeviceState.empty.withHomes(HomeBook.empty.savingHome(home))
        #expect(device.forgettingPlaces([]) == device)
    }

    /// The device side forgets a deleted place for matching and waiting, and its place to eat by id or by
    /// Apple's reference (its map icon); another place to eat and the homes stay.
    @Test func theDeviceSideForgetsADeletedPlaceAndItsIcon() {
        let burger = PlaceRecord(placeID: "I-burger", point: Self.burgerPoint)
        let oak = PlaceRecord(placeID: "I-oak", point: Self.park)
        let book = HomeBook.empty.savingHome(HomePlace(kind: .home, label: "Home", point: Self.park.offset(east: 0, north: 2_000)))
        let device = PlaceDeviceState.empty.withHomes(book)
            .learning(burger, at: Self.now).learning(oak, at: Self.now)
            .notingMeal(EatingMeal(id: UUID(), name: "Fries"), at: UUID(), placeID: "I-burger", point: Self.burgerPoint)
            .notingMeal(EatingMeal(id: UUID(), name: "Ramen"), at: UUID(), placeID: "I-hoshi", point: Self.park.offset(east: 300, north: 0))
        let next = device.forgettingPlaces([burger])
        #expect(next.known.map(\.id) == [oak.id])
        #expect(next.newPlaces.map(\.id) == [oak.id])
        #expect(!next.pending.contains { $0.placeID == burger.id })
        #expect(next.eatingPlaces.map(\.placeID) == ["I-hoshi"], "the bowl at the same reference went")
        #expect(next.homes == book)
    }

    // MARK: The store

    /// Through the store, under the hub key: deleting a place takes its record and stops, forgets it on the
    /// device side with its map icon, and it doesn't come back at the next fold. A decoy deletes nothing.
    @Test func theStoreDeletesAPlaceForGoodAndADecoyDeletesNothing() throws {
        let store = makeTestStore()
        let key = SymmetricKey(size: .bits256)
        let burger = PlaceRecord(placeID: "I-burger", point: Self.burgerPoint)
        let oak = PlaceRecord(placeID: "I-oak", point: Self.park)
        let device = PlaceDeviceState.empty
            .learning(burger, at: Self.now.addingTimeInterval(-3_600))
            .learning(oak, at: Self.now.addingTimeInterval(-7_200))
            .recordingVisit(to: oak.id, at: Self.now.addingTimeInterval(-26 * 3_600))
            .notingMeal(EatingMeal(id: UUID(), name: "Fries"), at: burger.id, placeID: "I-burger", point: Self.burgerPoint)
        try store.worldPlaces.store.saveDeviceState(device)
        #expect(store.deleteWorldPlace(burger.id, now: Self.now) == nil, "Private closed: nothing deleted")
        store.hubContentKeyProvider = { key }
        #expect(store.worldPlaceLog(now: Self.now)?.places.count == 2)

        store.duressSessionActive = true
        #expect(store.deleteWorldPlace(burger.id, now: Self.now) == nil, "a decoy deletes nothing")
        #expect(store.deleteWorldPlaceStop(UUID(), now: Self.now) == nil)
        store.duressSessionActive = false
        #expect(store.worldPlaceLog(now: Self.now)?.places.count == 2, "the real places are all there")

        let after = try #require(store.deleteWorldPlace(burger.id, now: Self.now))
        #expect(after.places.map(\.id) == [oak.id] && after.places.first?.visits == 2)
        #expect(!after.stops.contains { $0.placeID == burger.id })
        let side = try store.worldPlaces.store.deviceState()
        #expect(side.known.map(\.id) == [oak.id] && side.eatingPlaces.isEmpty)
        #expect(store.worldPlaces.eatingPlaces.isEmpty, "the map's icon went at once")
        #expect(store.worldPlaceLog(now: Self.now.addingTimeInterval(60)) == after, "it doesn't come back")
    }

    /// A walk stop's delete removes its saved line and keeps the walk in Move; a home's leave goes alone and
    /// the homes stay.
    @Test func theStoreDeletesAWalksLineAndLeavesTheHomes() throws {
        let store = makeTestStore()
        let key = SymmetricKey(size: .bits256)
        store.hubContentKeyProvider = { key }
        let start = Date()
        store.startWorldWalk(at: start)
        for east in stride(from: 0.0, through: 300, by: 5) {
            store.worldWalk.record(WorldFix(point: Self.park.offset(east: east, north: 0), accuracy: 5, at: start, isPrecise: true))
        }
        let defaults = try #require(UserDefaults(suiteName: "WorldPlacesDeleteTests.\(UUID().uuidString)"))
        let workout = try #require(store.finishWorldWalk(at: start.addingTimeInterval(300), defaults: defaults))
        let walk = try #require(store.worldPlaceLog()?.stops.first { $0.workoutID == workout.id })
        #expect(store.worldRoute(for: workout.id) != nil, "the walk kept its line")
        let after = try #require(store.deleteWorldPlaceStop(walk.id))
        #expect(after.stops.isEmpty)
        #expect(store.worldRoute(for: workout.id) == nil, "the saved line went")
        #expect(store.day.workouts.contains { $0.id == workout.id }, "the walk stays in Move")

        let home = HomePlace(kind: .home, label: "Home", point: Self.park)
        let book = HomeBook.empty.savingHome(home)
        try store.worldPlaces.store.saveDeviceState(try store.worldPlaces.store.deviceState().withHomes(book))
        try store.worldPlaces.store.saveDeviceState(try store.worldPlaces.store.deviceState().appending(PlaceStop(kind: .leftHome, at: Date(), placeID: home.id)))
        let leave = try #require(store.worldPlaceLog()?.stops.first { $0.kind == .leftHome })
        #expect(store.deleteWorldPlaceStop(leave.id)?.stops.isEmpty == true)
        #expect(try store.worldPlaces.store.deviceState().homes == book, "the home stays")
        #expect(store.worldHomes == book)
    }

    // MARK: What the screens draw

    /// The rename alert offers Delete this place after Open in Apple Maps (only with a reference) and before
    /// Cancel; the long-press menu and VoiceOver include it on every row, and VoiceOver also offers Rename.
    @Test func everyPlaceRowOffersDeleteThisPlace() {
        let referenced = PlaceRecord(placeID: "I-burger", point: Self.burgerPoint, visits: 1)
        let own = PlaceRecord(label: "Our bench", point: Self.park, visits: 2)
        #expect(WorldPlaceRenameButton.order(for: referenced) == [.save, .makeHome, .openInMaps, .delete, .cancel])
        #expect(WorldPlaceRenameButton.order(for: own) == [.save, .makeHome, .delete, .cancel])
        #expect(WorldPlaceRowAction.menu(for: referenced) == [.openInMaps, .delete])
        #expect(WorldPlaceRowAction.menu(for: own) == [.delete], "a row without a reference gets a menu too")
        #expect(WorldPlaceRowAction.spoken(for: referenced) == [.rename, .openInMaps, .delete])
        #expect(WorldPlaceRowAction.spoken(for: own) == [.rename, .delete])
        #expect(String(localized: WorldPlaceRowAction.delete.title) == "Delete this place")
        #expect(String(localized: WorldPlaceRowAction.rename.title) == "Rename")
        #expect(WorldPlaceRowAction.delete.isDestructive && WorldPlaceRowAction.delete.symbol == "trash")
        #expect(!WorldPlaceRowAction.openInMaps.isDestructive)
        #expect(WorldPlacesDeleteCopy.deletePlaceTitle("Burger Barn") == "Delete Burger Barn?")
        #expect(WorldPlacesDeleteCopy.deletePlaceMessage(visits: 4)
                == "It leaves Places you return to with its 4 visits, and its stops leave the last 30 days. Anything you logged there stays.")
        #expect(String(localized: WorldPlacesDeleteCopy.confirmDelete) == "Delete")
    }

    /// Every timeline stop has Delete this stop, titled "<name> · <time>", with what its delete does: the
    /// last visit leaves Places you return to, other visits stay, a walk's line goes, and a home or a hotel
    /// stays.
    @Test func everyTimelineStopHasDeleteThisStop() {
        let home = HomePlace(kind: .home, label: "Home", point: Self.park)
        let hotel = HomePlace(kind: .hotel, label: "The Ace", point: Self.burgerPoint)
        let book = HomeBook(homes: [home], hotel: hotel, pastHotels: [], presence: .unknown)
        let burger = PlaceRecord(placeID: "I-burger", point: Self.burgerPoint, visits: 1)
        let oak = PlaceRecord(label: "Oak Park", point: Self.park, visits: 3)
        #expect(String(localized: WorldPlacesDeleteCopy.deleteStop) == "Delete this stop")
        #expect(WorldPlacesDeleteCopy.stopTitle("Burger Barn", at: Self.now)
                == "Burger Barn · \(Self.now.formatted(.dateTime.hour().minute()))")
        let message = { (stop: PlaceStop, place: PlaceRecord?, name: String) in
            WorldPlacesDeleteCopy.stopMessage(stop, place: place, name: name, homes: book)
        }
        #expect(message(PlaceStop(kind: .visit, at: Self.now, placeID: burger.id), burger, "Burger Barn")
                == "Takes 1 visit off Burger Barn. It has no other visits, so it leaves Places you return to too.")
        #expect(message(PlaceStop(kind: .visit, at: Self.now, placeID: oak.id), oak, "Oak Park") == "Takes 1 visit off Oak Park; 2 stay.")
        #expect(message(PlaceStop(kind: .walk, at: Self.now, metres: 900), nil, "A walk")
                == "Its line leaves the day's sketch. The workout stays in Move.")
        #expect(message(PlaceStop(kind: .leftHome, at: Self.now, placeID: home.id), nil, "Home")
                == "Only this stop goes. Your home stays: change or remove it in Settings › Home map.")
        #expect(message(PlaceStop(kind: .cameHome, at: Self.now, placeID: hotel.id), nil, "The Ace")
                == "Only this stop goes. Your hotel stays: change or remove it in Settings › Home map.")
        #expect(message(PlaceStop(kind: .visit, at: Self.now, placeID: UUID()), nil, "A place") == nil, "a place already gone")
    }
}
