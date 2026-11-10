import CryptoKit
@testable import FernletSocial
import Foundation
@testable import PrivateMediaStore
import Testing
import UIKit
import WorldMapStore
@testable import Fernlet

/// Road trip photos (World-RoadTrip-Spec PR 3, owner-approved 2026-11-10: `rt-photos` straight onto the map, `rt-map`)
/// on a test store and as pure rules: a photo's place is the trip's line at its capture time (interpolated, none
/// across a long gap the car moved in, a stop's spot when it stood still); the sealed trip roll is bounded per person
/// and per trip and keeps one copy of each photo; a member is sent only this iPhone's own photos they were there for
/// and lack; a friend's photo is kept only within this iPhone's presence; trip photos, friends' included, are the only
/// friends' photos on the map, as their own prints; Hide from the map; the camera's trip film; and a decoy and the
/// wipe.
@Suite(.serialized) @MainActor
struct RoadTripPhotoTests {
    let store = makeTestStore()
    private static let start = Date(timeIntervalSince1970: 2_000_000_000)
    private static let here = GeoPoint(45.5205, -122.6255)

    /// `minutes` after the start.
    static func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// A small real JPEG.
    static func jpeg(_ color: UIColor = .systemTeal) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        return try #require(image.jpegData(compressionQuality: 0.8))
    }

    /// A road east of ``here``: a point every 300 m and 10 s, `count` points from the start.
    static func road(_ count: Int) -> [RoadTripPoint] {
        (0..<count).map { RoadTripPoint(point: here.offset(east: Double($0) * 300, north: 0), at: start.addingTimeInterval(Double($0) * 10)) }
    }

    /// The trip with Rae (and Sam, when `sam`) that this store starts, mapping.
    func startTrip(sam: Bool = false) throws -> RoadTrip {
        let keeper = store.worldFog.roadTrip
        keeper.load()
        var trip = RoadTripMeshTests.trip(with: "rae")
        if sam {
            trip.members.append(RoadTripMember(id: "sam", firstName: "Sam"))
            trip.atStart = ["me", "rae"]
        }
        try #require(keeper.start(trip))
        return trip
    }

    /// A photo from `member` of `trip` taken at `takenAt`.
    static func received(_ trip: RoadTrip, at takenAt: Date, id: UUID = UUID()) throws -> RoadTripReceivedPhoto {
        RoadTripReceivedPhoto(tripID: trip.id, photoID: id, takenAt: takenAt, bytes: try jpeg(.systemOrange))
    }

    // MARK: Places from the road

    /// Between two points the place is in proportion to the time; at a point, that point; off the line's ends, none.
    @Test func aPlaceIsTheLineAtTheCaptureTime() throws {
        let line = Self.road(10)
        let middle = try #require(RoadTripPhotoPlacing.place(at: Self.start.addingTimeInterval(15), on: line))
        #expect(abs(middle.distance(to: Self.here.offset(east: 450, north: 0))) < 2, "halfway between the 2nd and 3rd")
        #expect(RoadTripPhotoPlacing.place(at: Self.start.addingTimeInterval(30), on: line) == line[3].point)
        #expect(RoadTripPhotoPlacing.place(at: Self.start.addingTimeInterval(-1), on: line) == nil, "before the line")
        #expect(RoadTripPhotoPlacing.place(at: Self.start.addingTimeInterval(91), on: line) == nil, "after it: waits for the road")
        #expect(RoadTripPhotoPlacing.place(at: Self.start, on: []) == nil)
    }

    /// Across a gap over five minutes the car's place is not known, unless it stood still (within 100 m): then the
    /// photo is placed at the stop.
    @Test func aLongGapPlacesNothingUnlessTheCarStoodStill() {
        let before = RoadTripPoint(point: Self.here, at: Self.at(0))
        let movedOn = RoadTripPoint(point: Self.here.offset(east: 2_000, north: 0), at: Self.at(6))
        let stood = RoadTripPoint(point: Self.here.offset(east: 30, north: 0), at: Self.at(25))
        #expect(RoadTripPhotoPlacing.place(at: Self.at(3), on: [before, movedOn]) == nil, "a six-minute gap, 2 km apart")
        #expect(RoadTripPhotoPlacing.place(at: Self.at(12), on: [before, stood]) == Self.here, "a stop: placed there")
        let justInside = RoadTripPoint(point: Self.here.offset(east: 2_000, north: 0), at: Self.at(5))
        #expect(RoadTripPhotoPlacing.place(at: Self.at(2.5), on: [before, justInside]) != nil, "five minutes is not too long")
    }

    /// At once only from a precise, close, fresh reading.
    @Test func placingAtOnceNeedsAFreshPreciseReading() {
        let fix = WorldFix(point: Self.here, accuracy: 10, at: Self.at(1), isPrecise: true)
        #expect(RoadTripPhotoPlacing.placeNow(fix: fix, takenAt: Self.at(1.5)) == Self.here)
        #expect(RoadTripPhotoPlacing.placeNow(fix: fix, takenAt: Self.at(4)) == nil, "too old")
        #expect(RoadTripPhotoPlacing.placeNow(fix: WorldFix(point: Self.here, accuracy: 80, at: Self.at(1), isPrecise: true),
                                              takenAt: Self.at(1)) == nil, "too rough")
        #expect(RoadTripPhotoPlacing.placeNow(fix: nil, takenAt: Self.at(1)) == nil)
    }

    // MARK: The sealed roll

    /// The roll keeps 30 a person a trip and a bound per trip, one copy of each author's photo, a hidden flag, and
    /// nothing after its purge.
    @Test func theRollIsBoundedAndKeepsOneCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RoadTripPhotoTests-\(UUID().uuidString)")
        defer { _ = RoadTripPhotoStore(directory: directory).purgeAll() }
        let roll = RoadTripPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider(key: SymmetricKey(size: .bits256)))
        let trip = UUID(), bytes = try Self.jpeg()
        let first = RoadTripPhoto(tripID: trip, authorID: "rae", sourceID: UUID(), takenAt: Self.at(1))
        guard case .added = roll.add(first, imageData: bytes, perAuthor: 2, perTrip: 3) else { throw CancellationError() }
        let again = RoadTripPhoto(tripID: trip, authorID: "rae", sourceID: first.sourceID, takenAt: Self.at(1))
        #expect(roll.add(again, imageData: bytes, perAuthor: 2, perTrip: 3) == .duplicate, "the same photo lands once")
        let second = RoadTripPhoto(tripID: trip, authorID: "rae", sourceID: UUID(), takenAt: Self.at(2))
        guard case .added = roll.add(second, imageData: bytes, perAuthor: 2, perTrip: 3) else { throw CancellationError() }
        let third = RoadTripPhoto(tripID: trip, authorID: "rae", sourceID: UUID(), takenAt: Self.at(3))
        #expect(roll.add(third, imageData: bytes, perAuthor: 2, perTrip: 3) == .authorFull)
        let mine = RoadTripPhoto(tripID: trip, authorID: "me", sourceID: UUID(), takenAt: Self.at(3))
        guard case .added = roll.add(mine, imageData: bytes, perAuthor: 2, perTrip: 3) else { throw CancellationError() }
        let sams = RoadTripPhoto(tripID: trip, authorID: "sam", sourceID: UUID(), takenAt: Self.at(4))
        #expect(roll.add(sams, imageData: bytes, perAuthor: 2, perTrip: 3) == .full, "the trip is full")
        #expect(roll.add(RoadTripPhoto(tripID: trip, authorID: "", sourceID: UUID(), takenAt: Self.at(4)), imageData: bytes,
                         perAuthor: 2, perTrip: 3) == .unsafeImage, "an entry out of bounds")
        #expect(roll.setHidden(first.id, true) && roll.imageData(for: first.id) != nil)
        guard case .loaded(let index) = roll.load() else { throw CancellationError() }
        #expect(index.photos.map(\.id) == [first.id, second.id, mine.id] && index.photos[0].isHidden == true)
        #expect(index.sourceIDs(trip: trip, author: "rae") == [first.sourceID, second.sourceID])
        #expect(roll.delete([second.id]) && roll.imageData(for: second.id) == nil)
        #expect(roll.purgeAll() && !FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: Who gets what

    /// A member is sent only this iPhone's own shown photos, taken from their first presence on, that they lack; a
    /// member who joined at a catch-up gets none from before it; nobody else gets any.
    @Test func photosOwedFollowProofOfPresence() throws {
        var trip = RoadTripMeshTests.trip(with: "rae")
        trip.members.append(RoadTripMember(id: "sam", firstName: "Sam"))
        trip.atStart = ["me", "rae"]
        trip.ledger = ["me": [Self.at(30)], "sam": [Self.at(30)]]
        let early = RoadTripPhoto(tripID: trip.id, authorID: "me", sourceID: UUID(), takenAt: Self.at(10))
        let late = RoadTripPhoto(tripID: trip.id, authorID: "me", sourceID: UUID(), takenAt: Self.at(40))
        let hidden = RoadTripPhoto(tripID: trip.id, authorID: "me", sourceID: UUID(), takenAt: Self.at(41), isHidden: true)
        let raes = RoadTripPhoto(tripID: trip.id, authorID: "rae", sourceID: UUID(), takenAt: Self.at(42))
        let other = RoadTripPhoto(tripID: UUID(), authorID: "me", sourceID: UUID(), takenAt: Self.at(43))
        let photos = [early, late, hidden, raes, other]
        let toRae = RoadTripPhotoRules.owed(photos, to: "rae", in: trip, held: [], now: Self.at(60))
        #expect(toRae.map(\.id) == [early.id, late.id], "own, shown, this trip's; Rae's own photo is never sent back")
        #expect(RoadTripPhotoRules.owed(photos, to: "rae", in: trip, held: [early.sourceID], now: Self.at(60)).map(\.id) == [late.id])
        #expect(RoadTripPhotoRules.owed(photos, to: "sam", in: trip, held: [], now: Self.at(60)).map(\.id) == [late.id],
                "Sam was there from the catch-up at minute 30")
        #expect(RoadTripPhotoRules.owed(photos, to: "rae", in: trip, held: [], now: Self.at(20)).map(\.id) == [early.id], "none from later")
        #expect(RoadTripPhotoRules.owed(photos, to: "me", in: trip, held: [], now: Self.at(60)).isEmpty)
        #expect(RoadTripPhotoRules.owed(photos, to: "zoe", in: trip, held: [], now: Self.at(60)).isEmpty)
    }

    /// A friend's photo is kept only from a member of a trip this iPhone is on, taken within its own presence, once,
    /// with them as its author; Sam's photo of Rae's trip is never Rae's to hand over (the author is the sender).
    @Test func aFriendsPhotoIsKeptOnlyWithinPresence() throws {
        let trip = try startTrip()
        let photo = try Self.received(trip, at: Self.at(5))
        #expect(store.receiveRoadTripPhoto(photo, from: "RAE", now: Self.at(10)))
        #expect(!store.receiveRoadTripPhoto(photo, from: "rae", now: Self.at(10)), "the same photo lands once")
        #expect(!store.receiveRoadTripPhoto(try Self.received(trip, at: Self.at(5)), from: "sam", now: Self.at(10)), "not on the trip")
        #expect(!store.receiveRoadTripPhoto(try Self.received(trip, at: Self.at(-5)), from: "rae", now: Self.at(10)), "before the start")
        #expect(!store.receiveRoadTripPhoto(try Self.received(trip, at: Self.at(30)), from: "rae", now: Self.at(10)), "after now")
        let kept = try #require(store.roadTripPhotos.index()?.photos(of: trip.id))
        #expect(kept.count == 1 && kept[0].authorID == "rae" && kept[0].sourceID == photo.photoID && kept[0].id != photo.photoID)
        #expect(store.roadTripHeldPhotos(of: trip, from: "rae") == [photo.photoID], "the next catch-up tells Rae")
        #expect(store.roadTripHeldPhotos(of: trip, from: "me") == nil, "a catch-up never tells one friend another's")
        #expect(store.roadTripCatchUp(for: "rae", tripID: nil, isReply: false, now: Self.at(10))?.heldPhotos == [photo.photoID])
        #expect(store.roadTripPhotoCount(of: trip.id) == 1)
    }

    // MARK: On the map

    /// This iPhone's photo is placed at once from the mapping phone's reading, a friend's from the line; both sit on
    /// the map as trip prints (friends' included: the trip-only exception), and the solo photos' places and prints
    /// are untouched (no friend's photo ever reaches them).
    @Test func tripPhotosAreTheOnlyFriendsPhotosOnTheMap() throws {
        let trip = try startTrip()
        let keeper = store.worldFog.roadTrip
        #expect(keeper.appendLine(Self.road(30)) == 30)
        let fix = WorldFix(point: Self.here.offset(east: 9_000, north: 0), accuracy: 8, at: Self.at(5), isPrecise: true)
        #expect(store.takeRoadTripPhoto(try Self.jpeg(), fix: fix, now: Self.at(5)) == .kept)
        #expect(store.receiveRoadTripPhoto(try Self.received(trip, at: Self.start.addingTimeInterval(45)), from: "rae", now: Self.at(10)))
        let places = store.roadTripPhotos.allPlaces()
        #expect(places.count == 2, "both placed")
        let markers = store.roadTripPhotoMarkers()
        #expect(markers.flatMap(\.photoIDs).count == 2 && markers.count == 2, "4.5 km apart: two prints")
        let raes = try #require(store.roadTripPhotos.index()?.photos.first { $0.authorID == "rae" })
        #expect(abs((places[raes.id] ?? Self.here).distance(to: Self.here.offset(east: 1_350, north: 0))) < 2, "on the road at 45 s")
        #expect(try store.worldPhotoPlaces.all().isEmpty, "the solo photos' places are never written for a trip photo")
        #expect(store.worldPhotoMarkers().isEmpty, "no solo print holds a trip photo")
        // Hangout and wall photos can't reach a print: only the trip roll's own places file feeds them.
        let sources = try ["App/Fernlet/FernletStore.swift", "App/Fernlet/World/RoadTrip/RoadTripPhotoRoll.swift",
                           "App/Fernlet/FernletStore+RoadTripPhotos.swift"].map { try RepoRoot.source($0) }
        #expect(sources[0].components(separatedBy: ".roadTripPhotoPlaces").count == 2, "named once, for the trip roll")
        #expect(!sources[2].contains("meshFeatures.photos") && !sources[1].contains("MeshSessionPhotos"))
    }

    /// Photos within 40 m share one print, newest first; a hidden photo leaves the map and the viewer, and this
    /// iPhone's hidden photo is no longer sent.
    @Test func hideTakesAPhotoOffTheMap() throws {
        let trip = try startTrip()
        let fix = { (minutes: Double) in WorldFix(point: Self.here.offset(east: minutes * 5, north: 0), accuracy: 8,
                                                  at: Self.at(minutes), isPrecise: true) }
        #expect(store.takeRoadTripPhoto(try Self.jpeg(), fix: fix(1), now: Self.at(1)) == .kept)
        #expect(store.takeRoadTripPhoto(try Self.jpeg(.systemPink), fix: fix(2), now: Self.at(2)) == .kept)
        let markers = store.roadTripPhotoMarkers()
        let print = try #require(markers.first)
        #expect(markers.count == 1 && print.photoIDs.count == 2, "5 m apart: one print")
        let details = store.roadTripPhotoDetails(print.photoIDs)
        #expect(details.count == 2 && details[0].caption.contains("Mike") && details[0].spoken.contains("Mike"))
        #expect(store.hideRoadTripPhoto(print.photoIDs[0]))
        #expect(store.roadTripPhotoMarkers().first?.photoIDs == [print.photoIDs[1]])
        #expect(store.roadTripPhotoDetails(print.photoIDs).map(\.id) == [print.photoIDs[1]])
        let all = try #require(store.roadTripPhotos.index()?.photos(of: trip.id))
        #expect(RoadTripPhotoRules.owed(all, to: "rae", in: trip, held: [], now: Self.at(5)).map(\.id) == [print.photoIDs[1]])
    }

    /// The caption is the trip's name, the day and who took it; an unnamed trip is "Road trip"; VoiceOver says who.
    @Test func theCaptionNamesTheTripTheDayAndWho() {
        var trip = RoadTripMeshTests.trip(with: "rae")
        trip.name = "Road trip to the coast"
        let day = Self.start.formatted(.dateTime.month(.abbreviated).day())
        #expect(RoadTripCopy.photoCaption(trip: trip, takenAt: Self.start, author: "Rae") == "Road trip to the coast · \(day) · Rae")
        #expect(RoadTripCopy.photoSpoken(trip: trip, author: "Rae") == "Photo from Road trip to the coast, by Rae")
        trip.name = nil
        #expect(RoadTripCopy.photoCaption(trip: trip, takenAt: Self.start, author: "Rae") == "Road trip · \(day) · Rae")
        #expect(RoadTripCopy.photoSpoken(trip: trip, author: "Rae") == "Photo from the road trip, by Rae")
    }

    // MARK: The camera

    /// With a trip on, the camera's film is the trip roll's: 30 a person, counting down; past it, no film. No trip,
    /// no trip film.
    @Test func theCameraShootsOntoTheTripRoll() throws {
        store.worldFog.roadTrip.load()
        #expect(store.roadTripCameraFilm() == nil)
        let trip = try startTrip()
        #expect(store.roadTripCameraFilm() == RoadTripCameraFilm(tripID: trip.id, left: 30, limit: 30))
        let bytes = try Self.jpeg()
        // R2: bounded by one roll.
        for minute in 0..<RoadTripPhotoRules.perMember {
            #expect(store.takeRoadTripPhoto(bytes, fix: nil, now: Self.at(Double(minute))) == .kept)
        }
        #expect(store.roadTripCameraFilm()?.left == 0)
        #expect(store.takeRoadTripPhoto(bytes, fix: nil, now: Self.at(40)) == .noFilmLeft)
        #expect(store.roadTripPhotoMarkers().isEmpty, "no line and no reading: no place yet")
        #expect(store.takeRoadTripPhoto(Data("not a photo".utf8), fix: nil, now: Self.at(41)) == .notKept)
    }

    // MARK: The catch-up note

    /// A catch-up's note waits for the swap's photos to settle, then counts the trip's photos on this iPhone.
    @Test func theCatchUpNoteCountsThePhotos() throws {
        let trip = try startTrip()
        store.receiveRoadTripCatchUp(RoadTripMeshTests.catchUp(for: trip.id, points: []), from: "rae", now: Self.at(5))
        #expect(store.roadTripMesh.isSettling && store.roadTripMesh.caughtUp == nil)
        #expect(store.receiveRoadTripPhoto(try Self.received(trip, at: Self.at(4)), from: "rae", now: Self.at(5)))
        store.roadTripMesh.beginSending()
        store.roadTripMesh.endSending()
        store.roadTripMesh.settleNow()
        #expect(store.roadTripMesh.caughtUp?.photos == 1)
        #expect(RoadTripCopy.caughtUpLine(try #require(store.roadTripMesh.caughtUp)).contains("1"))
    }

    // MARK: Decoy and wipe

    /// A decoy takes, sends, receives, places and shows none, and the real roll is back after it.
    @Test func theDecoyTakesSendsReceivesAndShowsNothing() throws {
        let trip = try startTrip()
        let fix = WorldFix(point: Self.here, accuracy: 8, at: Self.at(1), isPrecise: true)
        #expect(store.takeRoadTripPhoto(try Self.jpeg(), fix: fix, now: Self.at(1)) == .kept)
        #expect(store.receiveRoadTripPhoto(try Self.received(trip, at: Self.at(1)), from: "rae", now: Self.at(2)))
        store.duressSessionActive = true
        #expect(store.roadTripCameraFilm() == nil, "the camera is the solo one in a decoy")
        #expect(store.takeRoadTripPhoto(try Self.jpeg(), fix: fix, now: Self.at(3)) == .notKept)
        #expect(!store.receiveRoadTripPhoto(try Self.received(trip, at: Self.at(3)), from: "rae", now: Self.at(4)))
        #expect(store.roadTripPhotoMarkers().isEmpty && store.roadTripPhotoCount(of: trip.id) == 0)
        #expect(store.roadTripHeldPhotos(of: trip, from: "rae") == nil)
        #expect(store.sendRoadTripPhotos(of: trip, to: "rae", held: [], now: Self.at(4)) == 0)
        let anyID = UUID()
        #expect(!store.hideRoadTripPhoto(anyID) && store.roadTripPhotoImage(anyID) == nil && store.roadTripPhotoDetails([anyID]).isEmpty)
        store.duressSessionActive = false
        #expect(store.roadTripPhotoCount(of: trip.id) == 2, "nothing of the decoy's reached the real roll")
        #expect(store.roadTripPhotoMarkers().count == 1)
    }

    /// Delete everything's leg removes the whole roll (hidden flags too); the map's vault takes the places with it.
    @Test func theWipeRemovesTheRollAndItsPlaces() throws {
        let trip = try startTrip()
        let fix = WorldFix(point: Self.here, accuracy: 8, at: Self.at(1), isPrecise: true)
        #expect(store.takeRoadTripPhoto(try Self.jpeg(), fix: fix, now: Self.at(1)) == .kept)
        let id = try #require(store.roadTripPhotos.index()?.photos.first?.id)
        #expect(store.hideRoadTripPhoto(id))
        #expect(store.purgeRoadTripPhotosForDeleteAll())
        #expect(!FileManager.default.fileExists(atPath: store.roadTripPhotoDirectory.path))
        #expect(store.roadTripPhotos.index()?.photos.isEmpty == true && store.roadTripPhotoCount(of: trip.id) == 0)
        #expect(!store.roadTripPhotos.allPlaces().isEmpty, "the places are map history")
        #expect(store.worldFog.clearAll())
        #expect(store.roadTripPhotos.allPlaces().isEmpty, "gone with the vault")
    }
}
