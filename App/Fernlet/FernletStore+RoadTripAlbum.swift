import FernletConnections
import FernletDomainModel
import Foundation
import PrivateMediaStore
import ProximityKit

/// Road trip photos in the Album, the store's side (owner, 2026-11-10: "Keep the photos" — Delete map history keeps
/// them — and "Yes, in the Album", one section per trip), so the photos can always be seen, even after the trip's
/// record is gone.
///
/// - **One set per trip** (``roadTripAlbumSets()``, ``RoadTripAlbum``): every trip photo this iPhone holds, its own and
///   friends', hidden ones included (hiding is from the map only).
/// - **Titles:** the trip's name while its record is here; after Delete map history, "Road trip" and the days the
///   photos were taken. The photo store keeps no trip name, so nothing deleted with map history comes back here.
/// - **Who took it** (``roadTripPhotoAuthor(_:in:)``): the trip's member while the record is here; after it, this
///   iPhone's own name for its own photos, and a kept friend's first name where the friends list still holds them.
/// - **Decoy:** none of it, as with the solo album.
extension FernletStore {
    /// The Album's road trip sets, newest first: one per trip with photos on this iPhone, every photo held (hidden ones
    /// too). None in a decoy, and none while the roll can't be read right now.
    func roadTripAlbumSets() -> [RoadTripAlbumSet] {
        guard !duressSessionActive, let index = roadTripPhotos.index(), !index.photos.isEmpty else { return [] }
        worldFog.roadTrip.load()
        let authorIDs = Set(index.photos.map(\.authorID))
        let names = Dictionary(authorIDs.compactMap { id in roadTripPhotoAuthor(id, in: nil).map { (id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        return RoadTripAlbum.sets(from: index.photos, trips: worldFog.roadTrip.book.trips, names: names)
    }

    /// A trip photo's thumbnail for its Album tile; nil in a decoy.
    func roadTripPhotoThumbnail(_ id: UUID) -> Data? {
        duressSessionActive ? nil : roadTripPhotos.thumbnailData(for: id)
    }

    /// The first name of who took a trip photo: the trip's member while `trip`'s record is here; else this iPhone's own
    /// name for its own photos, or a kept friend's (not removed, not blocked) whose member id it is; nil when none.
    func roadTripPhotoAuthor(_ authorID: String, in trip: RoadTrip?) -> String? {
        guard !authorID.isEmpty else { return nil }
        if let member = trip?.members.first(where: { $0.id == authorID }) { return member.firstName }
        if authorID == roadTripSelfID {
            return RoadTripWire.firstName(PeerNameDisplay.firstName(resolvedProximityDisplayName, fingerprint: authorID,
                                                                    placeholder: .met, in: .fernlet))
        }
        guard let friend = trustedProximityPeers.first(where: {
            RoadTripMembers.id($0.fingerprint) == authorID && $0.revokedAt == nil && $0.blockedAt == nil
        }) else { return nil }
        return RoadTripWire.firstName(PeerNameDisplay.firstName(friend.displayName, fingerprint: friend.fingerprint,
                                                                placeholder: .met, in: .fernlet))
    }
}
