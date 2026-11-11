import FernletConnections
import FernletDomainModel
@testable import FernletSocial
import Foundation
@testable import ProximityKit
@testable import PrivateMediaStore
import Testing
import UIKit
import WorldMapStore
@testable import Fernlet

/// Road trip photos in the Album (owner, 2026-11-10: "Keep the photos" — Delete map history keeps them — and "Yes, in
/// the Album", one section per trip): one set per trip holding every photo held, this iPhone's and friends', hidden
/// ones included; slotted among the hangouts and "Just you" sets by date; titled by the trip's name while its record
/// is here and by "Road trip" and the photos' days once Delete map history has taken it, with "by Rae" where the
/// kept friends still name the taker; the viewer without "Hide from the map" for a photo with no place; and a decoy
/// showing none.
@Suite(.serialized) @MainActor
struct RoadTripAlbumTests {
    let store = makeTestStore()
    /// Noon, local time, on a day well after the real clock: a half hour stays on one day in any time zone, and the
    /// map's own load never ends these trips.
    nonisolated static let start: Date = Calendar.current.date(from: DateComponents(year: 2033, month: 5, day: 17, hour: 12))
        ?? Date(timeIntervalSince1970: 2_000_000_000)
    private static let here = GeoPoint(45.5205, -122.6255)

    /// `minutes` after the start.
    static func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// A precise, fresh reading at `minutes`, so this iPhone's photo is placed at once.
    static func fix(_ minutes: Double) -> WorldFix {
        WorldFix(point: here.offset(east: minutes * 5, north: 0), accuracy: 8, at: at(minutes), isPrecise: true)
    }

    /// A trip this store is on and maps: this iPhone (as `selfID`, "Mike") and Rae (as `rae`), named `name`.
    static func trip(selfID: String = "me", rae: String = "rae", name: String? = nil) -> RoadTrip {
        RoadTrip(id: UUID(), name: name, startedAt: start, starterID: selfID, selfID: selfID,
                 members: [RoadTripMember(id: selfID, firstName: "Mike"), RoadTripMember(id: rae, firstName: "Rae")],
                 mapperID: selfID, mapperOverride: nil, lastCatchUp: start, endedAt: nil, leftAt: nil)
    }

    /// A photo of `trip` by `author` at `minutes`.
    static func photo(_ trip: UUID, by author: String, at minutes: Double, hidden: Bool = false) -> RoadTripPhoto {
        RoadTripPhoto(tripID: trip, authorID: author, sourceID: UUID(), takenAt: at(minutes), isHidden: hidden ? true : nil)
    }

    // MARK: One set per trip

    /// Each trip with photos is one set, newest first, holding every photo of it (a hidden one too), its newest the
    /// cover; the sets come newest first by their newest photo; a trip's record names its set and its takers.
    @Test func eachTripIsOneSetHoldingEveryPhoto() throws {
        let coast = Self.trip(name: "Road trip to the coast")
        let other = UUID()
        let first = Self.photo(coast.id, by: "me", at: 1)
        let hidden = Self.photo(coast.id, by: "rae", at: 2, hidden: true)
        let last = Self.photo(coast.id, by: "me", at: 3)
        let lone = Self.photo(other, by: "zoe", at: 60)
        let sets = RoadTripAlbum.sets(from: [first, lone, hidden, last], trips: [coast], names: ["zoe": "Zoe"])
        #expect(sets.map(\.tripID) == [other, coast.id], "one per trip, newest first")
        let set = try #require(sets.last)
        #expect(set.photoIDs == [last.id, hidden.id, first.id], "every photo, the hidden one included, newest first")
        #expect(set.cover == last.id && set.date == Self.at(3) && set.isCarousel && set.id == "roadTrip-\(coast.id.uuidString)")
        #expect(set.title == "Road trip to the coast" && set.authors == ["Mike", "Rae"])
        #expect(sets[0].authors == ["Zoe"] && !sets[0].isCarousel)
        #expect(sets[0].title == "Road trip · \(Self.at(60).formatted(.dateTime.month(.abbreviated).day()))", "no record here")
        var unnamed = coast
        unnamed.name = nil
        #expect(RoadTripAlbum.title(trip: unnamed, first: Self.at(1), last: Self.at(3)) == RoadTripCopy.name(of: unnamed),
                "a trip given no name is titled as Trip info names it")
        #expect(RoadTripAlbum.sets(from: [], trips: [coast], names: [:]).isEmpty, "a trip with no photos has no set")
    }

    /// The trips' sets slot in among the hangouts and the "Just you" sets by their newest photo, the album newest
    /// first; of the same moment the "Just you" set comes first.
    @Test func tripSetsSlotInAmongTheOtherEntriesByDate() throws {
        let tripA = try #require(RoadTripAlbum.sets(from: [Self.photo(UUID(), by: "me", at: 100)], trips: [], names: [:]).first)
        let tripB = try #require(RoadTripAlbum.sets(from: [Self.photo(UUID(), by: "me", at: 10)], trips: [], names: [:]).first)
        let solo = try #require(SoloPhotoSet(dayKey: "2033-05-17", photos: [SoloCameraPhoto(takenAt: Self.at(10), revealsAt: Self.at(20))]))
        let posts = [Post(date: Self.at(50)), Post(date: Self.at(5))]
        let entries = SoloAlbum.merged(posts: posts, date: \.date, sets: [solo], trips: [tripA, tripB])
        #expect(entries.map(\.id) == [tripA.id, "post-\(posts[0].id.uuidString)", solo.id, tripB.id, "post-\(posts[1].id.uuidString)"])
        #expect(SoloAlbum.merged(posts: [Post](), date: \.date, sets: [], trips: [tripA, tripB]).map(\.id) == [tripA.id, tripB.id])
        #expect(SoloAlbum.merged(posts: posts, date: \.date, sets: [solo]).map(\.id).count == 3, "no trips: as before")
    }

    /// A stand-in hangout post: an id and when it happened.
    private struct Post: Identifiable {
        let id = UUID()
        let date: Date
    }

    /// On a test store, two trips are two sets, and a photo hidden from the map stays in its trip's set.
    @Test func theStoreShowsEveryTripAndTheHiddenPhotos() throws {
        let keeper = store.worldFog.roadTrip
        keeper.load()
        let first = Self.trip(name: "Out")
        #expect(keeper.start(first))
        #expect(store.takeRoadTripPhoto(try RoadTripPhotoTests.jpeg(), fix: Self.fix(1), now: Self.at(1)) == .kept)
        #expect(store.takeRoadTripPhoto(try RoadTripPhotoTests.jpeg(.systemPink), fix: Self.fix(2), now: Self.at(2)) == .kept)
        #expect(keeper.leave(now: Self.at(3)))
        let second = Self.trip(name: "Back")
        #expect(keeper.start(second))
        #expect(store.takeRoadTripPhoto(try RoadTripPhotoTests.jpeg(), fix: Self.fix(4), now: Self.at(4)) == .kept)
        let hiddenID = try #require(store.roadTripPhotos.index()?.photos(of: first.id).first?.id)
        #expect(store.hideRoadTripPhoto(hiddenID))
        let sets = store.roadTripAlbumSets()
        #expect(sets.map(\.title) == ["Back", "Out"] && sets.map(\.photoIDs.count) == [1, 2], "one per trip")
        #expect(sets.last?.photoIDs.contains(hiddenID) == true, "hiding is from the map only")
        #expect(!store.roadTripPhotoMarkers().flatMap(\.photoIDs).contains(hiddenID))
        #expect(store.roadTripPhotoThumbnail(hiddenID) != nil)
        #expect(store.roadTripPhotoDetails([hiddenID]).isEmpty, "a print's viewer never shows it")
        #expect(store.roadTripPhotoDetails([hiddenID], includingHidden: true).map(\.id) == [hiddenID], "the Album's does")
    }

    // MARK: The title, and Delete map history

    /// While the trip's record is here its set is titled by the trip's name and each photo says who took it from the
    /// record; after Delete map history the photos are still in the Album, titled "Road trip" and their days, with
    /// "by Rae" from the kept friends list and this iPhone's own name on its own photos; and a photo with no place
    /// left offers no "Hide from the map".
    @Test func theTitleFollowsTheTripThenItsPhotosAfterDeleteMapHistory() throws {
        let selfID = store.roadTripSelfID
        try #require(!selfID.isEmpty, "the mesh identity is provisioned")
        store.settings.proximityDisplayName = "Mike Bowman"
        let rae = RoadTripMeshTests.friend("Rae Lin", key: 41, in: store)
        let keeper = store.worldFog.roadTrip
        keeper.load()
        let trip = Self.trip(selfID: selfID, rae: RoadTripMembers.id(rae.fingerprint), name: "Road trip to the coast")
        #expect(keeper.start(trip))
        #expect(store.takeRoadTripPhoto(try RoadTripPhotoTests.jpeg(), fix: Self.fix(1), now: Self.at(1)) == .kept)
        let raes = RoadTripReceivedPhoto(tripID: trip.id, photoID: UUID(), takenAt: Self.at(26 * 60),
                                         bytes: try RoadTripPhotoTests.jpeg(.systemOrange))
        #expect(store.receiveRoadTripPhoto(raes, from: rae.fingerprint, now: Self.at(27 * 60)))
        let before = try #require(store.roadTripAlbumSets().first)
        #expect(before.title == "Road trip to the coast" && before.photoIDs.count == 2)
        let raeID = try #require(before.photoIDs.first), mineID = try #require(before.photoIDs.last)
        let details = store.roadTripPhotoDetails(before.photoIDs, includingHidden: true)
        #expect(details.first?.spoken == "Photo from Road trip to the coast, by Rae")
        #expect(details.last.map(RoadTripPhotoViewer.offersHide) == true, "placed at once from this iPhone's reading")
        #expect(details.first.map(RoadTripPhotoViewer.offersHide) == false, "no road yet to place Rae's: no Hide")

        #expect(store.deleteWorldMapHistory())
        #expect(keeper.book.trips.isEmpty && store.roadTripPhotoMarkers().isEmpty, "the trip and the prints are gone")
        let after = try #require(store.roadTripAlbumSets().first)
        #expect(after.photoIDs == [raeID, mineID], "the photos are still in the Album")
        let days = RoadTripCopy.albumDays(from: Self.at(1), to: Self.at(26 * 60))
        #expect(days.contains("–") || days.contains("-"), "two days: a range, \(days)")
        #expect(after.title == "Road trip · \(days)" && after.title == AddressedCopy.plain(RoadTripCopy.albumTitle(days)))
        #expect(Set(after.authors) == ["Rae", "Mike"] && RoadTripAlbum.matches("rae", set: after))
        let kept = store.roadTripPhotoDetails(after.photoIDs, includingHidden: true)
        #expect(kept.map(\.spoken) == ["Photo from the road trip, by Rae", "Photo from the road trip, by Mike"])
        #expect(kept.first?.caption.hasSuffix("· Rae") == true && kept.last?.caption.hasSuffix("· Mike") == true)
        #expect(kept.allSatisfy { !RoadTripPhotoViewer.offersHide($0) }, "no place on the map any more: no Hide")
    }

    /// The fallback's days: one day alone, or the range when the photos span more than one.
    @Test func theFallbackTitleNamesThePhotosDays() {
        let day = Self.at(1).formatted(.dateTime.month(.abbreviated).day())
        #expect(RoadTripCopy.albumDays(from: Self.at(1), to: Self.at(30)) == day, "the same day")
        #expect(RoadTripCopy.albumDays(from: Self.at(1), to: Self.at(1)) == day)
        #expect(RoadTripCopy.albumDays(from: Self.at(1), to: Self.at(3 * 24 * 60)) != day)
        #expect(AddressedCopy.plain(RoadTripCopy.albumSpoken("Road trip to the coast", photos: "6 photos"))
                == "Road trip to the coast, carousel, 6 photos")
        #expect(AddressedCopy.plain(RoadTripCopy.albumTitle("Nov 10 – 12")) == "Road trip · Nov 10 – 12")
    }

    /// A kept friend who was removed or blocked no longer names a photo; an unknown taker is left unnamed.
    @Test func onlyAKeptFriendNamesThePhotoOnceTheTripIsGone() {
        let rae = RoadTripMeshTests.friend("Rae", key: 43, in: store)
        let raeID = RoadTripMembers.id(rae.fingerprint)
        #expect(store.roadTripPhotoAuthor(raeID, in: nil) == "Rae")
        #expect(store.roadTripPhotoAuthor("stranger", in: nil) == nil)
        #expect(store.roadTripPhotoAuthor("", in: nil) == nil)
        #expect(store.roadTripPhotoAuthor(raeID, in: Self.trip(rae: raeID)) == "Rae", "the record first")
        store.proximityTrustVault.revoke(signingPublicKey: rae.signingPublicKey)
        #expect(store.roadTripPhotoAuthor(raeID, in: nil) == nil, "removed: not named")
    }

    // MARK: The decoy

    /// A decoy shows no trip set, no thumbnail and no photo; the real sets are back after it.
    @Test func aDecoyShowsNone() throws {
        let keeper = store.worldFog.roadTrip
        keeper.load()
        #expect(keeper.start(Self.trip(name: "Out")))
        #expect(store.takeRoadTripPhoto(try RoadTripPhotoTests.jpeg(), fix: Self.fix(1), now: Self.at(1)) == .kept)
        let set = try #require(store.roadTripAlbumSets().first)
        store.duressSessionActive = true
        #expect(store.roadTripAlbumSets().isEmpty)
        #expect(store.roadTripPhotoThumbnail(set.cover) == nil)
        #expect(store.roadTripPhotoDetails(set.photoIDs, includingHidden: true).isEmpty)
        store.duressSessionActive = false
        #expect(store.roadTripAlbumSets() == [set], "nothing of the real album changed")
    }

    // MARK: The page

    /// The Album page draws each trip as one Button with its spoken label and short Voice Control names, keeps a
    /// decoy's read empty through the store, and adds no action of its own: the trip viewer is the only way in.
    @Test func thePageDrawsEachTripAsOneButton() throws {
        let page = try RepoRoot.source("App/Fernlet/ConnectView.swift")
        let tile = try #require(page.range(of: "private func roadTripTile(_ photoSet: RoadTripAlbumSet) -> some View {"))
        let body = String(page[tile.upperBound...].prefix(700))
        for piece in ["Button {", "RoadTripSetTile(", ".accessibilityLabel(RoadTripSetTile.accessibilityLabel(for: photoSet))",
                      ".accessibilityInputLabels(RoadTripSetTile.inputLabels)"] {
            #expect(body.contains(piece), "the tile lacks \(piece)")
        }
        #expect(page.contains(".modifier(RoadTripAlbumHost(store: store, sets: $roadTripSets, openSet: $openRoadTripSet))"))
        let views = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/World/RoadTrip/RoadTripAlbumViews.swift"))
        for action in ["delete", "Delete", "ShareLink", "FriendPhotoLibrarySaver", "toggleFavorite"] {
            #expect(!views.contains(action), "the trip set adds \(action)")
        }
        #expect(views.contains("origin: .album(title: opened.title)"), "opens in the trip photo viewer")
    }
}
