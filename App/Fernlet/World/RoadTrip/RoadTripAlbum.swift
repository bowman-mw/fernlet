import FernletDomainModel
import Foundation
import PrivateMediaStore

/// One road trip's photos in the Album (owner, 2026-11-10: "Keep the photos", "Yes, in the Album"): every trip photo
/// this iPhone holds for the trip, its own and friends', hidden ones included (hiding is from the map only), newest
/// first, like a "Just you" set.
///
/// Built only from photos that are here (``RoadTripAlbum/sets(from:trips:author:)``), so it always has a cover: the
/// newest photo. Its title is the trip's name while the trip's record is on this iPhone; once Delete map history has
/// taken the record, "Road trip" and the days the photos were taken (``RoadTripAlbum/title(trip:first:last:)``). The
/// photo store keeps no trip name, so nothing of the deleted map history comes back through the Album.
nonisolated struct RoadTripAlbumSet: Identifiable, Equatable, Sendable {
    /// Stable per trip (`roadTrip-<trip id>`), never a photo id.
    let id: String
    /// The trip the photos were taken on.
    let tripID: UUID
    /// The photos' ids on this iPhone, newest first; never empty.
    let photoIDs: [UUID]
    /// The tile's photo: the newest.
    let cover: UUID
    /// When the newest photo was taken: the set's place in the album.
    let date: Date
    /// The section's title: the trip's name, or "Road trip" and the days.
    let title: String
    /// The first names of who took the photos, where they are still known here (the album's search).
    let authors: [String]

    /// Whether the set opens a carousel (more than one photo).
    var isCarousel: Bool { photoIDs.count > 1 }
}

/// The road trips' place in the Album: one set per trip that has photos on this iPhone, its title, and search. Pure,
/// so the tests pin it; the store feeds it the sealed roll and the trips' records (`FernletStore+RoadTripAlbum.swift`).
nonisolated enum RoadTripAlbum {
    /// The sets of `photos`, one per trip, newest first. A trip's record in `trips` names its set and its members; with
    /// no record, `names` (author id → first name: this iPhone's own, and kept friends') says who took a photo.
    static func sets(from photos: [RoadTripPhoto], trips: [RoadTrip], names: [String: String]) -> [RoadTripAlbumSet] {
        let byTrip = Dictionary(grouping: photos.prefix(RoadTripPhotoStore.maxPhotos), by: \.tripID)
        let records = Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        return byTrip.compactMap { tripID, taken in
            tripSet(of: tripID, photos: taken, trip: records[tripID], names: names)
        }
        .sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
    }

    /// One trip's set: its photos newest first under its title, with the names that resolve; nil with no photos.
    private static func tripSet(of tripID: UUID, photos: [RoadTripPhoto], trip: RoadTrip?,
                                names: [String: String]) -> RoadTripAlbumSet? {
        let ordered = photos.sorted { $0.takenAt > $1.takenAt }
        guard let newest = ordered.first, let oldest = ordered.last else { return nil }
        let authorIDs = Set(ordered.map(\.authorID)).sorted()
        let authors = authorIDs.compactMap { id in trip?.members.first { $0.id == id }?.firstName ?? names[id] }
        return RoadTripAlbumSet(id: "roadTrip-\(tripID.uuidString)", tripID: tripID, photoIDs: ordered.map(\.id),
                                cover: newest.id, date: newest.takenAt,
                                title: title(trip: trip, first: oldest.takenAt, last: newest.takenAt), authors: authors)
    }

    /// A set's title: the trip's name while its record is here (its own name, or "Road trip" and the day it started);
    /// once the record is gone, "Road trip" and the days from `first` to `last`, the photos' own capture times.
    static func title(trip: RoadTrip?, first: Date, last: Date) -> String {
        if let trip { return RoadTripCopy.name(of: trip) }
        return AddressedCopy.plain(RoadTripCopy.albumTitle(RoadTripCopy.albumDays(from: first, to: last)))
    }

    /// Whether the album's search shows `set`: always with no query, else when its title or one of its photos' takers
    /// contains it, or "Road trip" (as the person reads it, or in English) does, the way "Just you" is found.
    static func matches(_ query: String, set: RoadTripAlbumSet) -> Bool {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return true }
        let shown = AddressedCopy.plain(RoadTripCopy.title).lowercased()
        return set.title.lowercased().contains(wanted) || set.authors.contains { $0.lowercased().contains(wanted) }
            || shown.contains(wanted) || "road trip".contains(wanted)
    }
}
