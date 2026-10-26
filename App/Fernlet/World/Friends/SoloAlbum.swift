import Foundation
import Observation
import FernletFoundation
import PrivateMediaStore

/// One "Just you" set: a local day's solo photos once they show (`b4-mem-solo-revealed`, approved
/// 2026-10-24), newest first, like a hangout's set in the Friends album.
///
/// Built only from a non-empty day (``init(dayKey:photos:)`` is failable), so it always has a cover:
/// the day's favorite when one is chosen, else the newest photo.
struct SoloPhotoSet: Identifiable, Equatable {
    /// Stable per local day (`solo-yyyy-MM-dd`), never a photo id: the set survives a delete.
    let id: String
    /// The local day the set is (`FernletDate.dayKey(for:)` of each photo's `takenAt`).
    let dayKey: String
    /// The day's shown photos, newest first; never empty.
    let photos: [SoloCameraPhoto]
    /// The tile's photo: the favorite, else the newest.
    let cover: SoloCameraPhoto
    /// When the set's newest photo was taken: its place in the album.
    let date: Date

    /// A set of `photos` (any order) for `dayKey`; nil when there are none.
    init?(dayKey: String, photos: [SoloCameraPhoto]) {
        let ordered = photos.sorted { $0.takenAt > $1.takenAt }
        guard let newest = ordered.first else { return nil }
        self.id = "solo-\(dayKey)"
        self.dayKey = dayKey
        self.photos = ordered
        self.cover = ordered.first { $0.isFavorite == true } ?? newest
        self.date = newest.takenAt
    }

    /// Whether the set opens a carousel (more than one photo).
    var isCarousel: Bool { photos.count > 1 }

    /// The photo ids, in order.
    var photoIDs: [UUID] { photos.map(\.id) }
}

/// One tile of the Friends album: a hangout's post, or a "Just you" set.
enum FriendsAlbumEntry<Post: Identifiable>: Identifiable where Post.ID == UUID {
    case post(Post)
    case solo(SoloPhotoSet)

    /// Unique across both kinds.
    var id: String {
        switch self {
        case .post(let post): return "post-\(post.id.uuidString)"
        case .solo(let photoSet): return photoSet.id
        }
    }
}

/// The solo photos' place in the Friends album (`b4-mem-solo-*`, approved 2026-10-24): grouping a
/// day's shots into a set, merging the sets into the album newest first, and search. Pure (main
/// actor, like the album that calls it), so the tests pin it.
enum SoloAlbum {
    /// The sets of `photos` (the shown ones), newest day first.
    static func sets(from photos: [SoloCameraPhoto]) -> [SoloPhotoSet] {
        let byDay = Dictionary(grouping: photos) { FernletDate.dayKey(for: $0.takenAt) }
        return byDay.compactMap { SoloPhotoSet(dayKey: $0.key, photos: $0.value) }
            .sorted { $0.date > $1.date }
    }

    /// The album's tiles: `posts` in their own order, with each set slotted in before the first post
    /// older than it (`date`), so the album stays newest first.
    ///
    /// - Parameters:
    ///   - posts: The hangouts' posts, newest first.
    ///   - date: When a post happened.
    ///   - sets: The "Just you" sets, newest first.
    static func merged<Post: Identifiable>(posts: [Post], date: (Post) -> Date,
                                           sets: [SoloPhotoSet]) -> [FriendsAlbumEntry<Post>] where Post.ID == UUID {
        var entries: [FriendsAlbumEntry<Post>] = []
        var next = 0
        // R2: bounded by the posts; each set is placed once.
        for post in posts {
            let postDate = date(post)
            let due = sets[next...].prefix { $0.date >= postDate }
            entries.append(contentsOf: due.map { FriendsAlbumEntry.solo($0) })
            next += due.count
            entries.append(.post(post))
        }
        entries.append(contentsOf: sets[next...].map { FriendsAlbumEntry.solo($0) })
        return entries
    }

    /// Whether the album's search shows the solo sets: always with no query, else when "Just you"
    /// (as the person reads it, or in English) contains it — the way a session is found by its name.
    static func matches(_ query: String) -> Bool {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return true }
        let shown = String(localized: "Just you", comment: "The name of a set of photos taken with the camera on your own").lowercased()
        return shown.contains(wanted) || "just you".contains(wanted)
    }
}

/// What the Friends album shows of the solo camera (`b4-mem-solo-waiting`, `-revealed`, `-open`):
/// the "Just you" sets, the count still held until tonight, and when the next one shows.
///
/// Fed a ``SoloCameraRoll`` by the page (``refresh(roll:now:)``); a nil roll — the duress decoy —
/// shows none of it, and so does a decoy roll. Bytes come through the same roll, which hands them out
/// only for the photos it just showed.
@Observable
final class SoloAlbumModel {
    /// The shown sets, newest first.
    private(set) var sets: [SoloPhotoSet] = []
    /// Photos taken and still held until the companion sleeps (the "Tonight · 3 photos" tile).
    private(set) var heldCount = 0
    /// When the next held photo shows; nil when none is held.
    private(set) var nextRevealAt: Date?
    @ObservationIgnored private var roll: SoloCameraRoll?
    /// Only these photos, when set: the photos taken at one place, opened from its marker on the map
    /// (World build step 5c).
    @ObservationIgnored private let only: Set<UUID>?
    /// The name a photo's place goes by on its card ("Thursday 23 October · Oak Park"), or nil.
    @ObservationIgnored var placeName: (UUID) -> String? = { _ in nil }
    /// The store a photo with no place is put on the map through (round 6, `ref-tag-photo`), set by the
    /// page that shows the album; nil leaves the card saying nothing about places.
    @ObservationIgnored weak var placesStore: FernletStore?
    /// The photo being put on the map, while its sheet is up.
    var placing: SoloCameraPhoto?
    /// Goes up when a photo is put on the map, so its card drops "No place, to be careful".
    private(set) var placesRevision = 0

    /// Marks that a photo got a place (its card reads again).
    func placed() {
        placesRevision &+= 1
    }

    /// A model over every solo photo, or over `only` those photos.
    init(only: Set<UUID>? = nil) {
        self.only = only
    }

    /// Whether there is nothing of the solo camera to show at all.
    var isEmpty: Bool { sets.isEmpty && heldCount == 0 }

    /// Reads the roll afresh: the sets that show at `now` (marking newly due photos shown), and what
    /// is still held. Nil, or a decoy roll, shows nothing.
    func refresh(roll: SoloCameraRoll?, now: Date = .now) {
        self.roll = roll
        guard let roll, !roll.isDecoy else {
            sets = []
            heldCount = 0
            nextRevealAt = nil
            return
        }
        let shown = roll.photos(visibleAt: now)
        sets = SoloAlbum.sets(from: only.map { ids in shown.filter { ids.contains($0.id) } } ?? shown)
        let held = roll.heldPhotos(at: now)
        heldCount = held.count
        nextRevealAt = held.map(\.revealsAt).min()
    }

    /// The set with this id, if it still shows.
    func set(withID id: String) -> SoloPhotoSet? {
        sets.first { $0.id == id }
    }

    /// A shown photo's thumbnail.
    func thumbnailData(for id: UUID) -> Data? {
        roll?.thumbnailData(for: id)
    }

    /// A shown photo's full-size bytes.
    func imageData(for id: UUID) -> Data? {
        roll?.imageData(for: id)
    }

    /// Deletes a photo from the sealed corpus (its film is not given back), then reads again.
    ///
    /// - Returns: whether it is gone.
    func delete(_ id: UUID, now: Date = .now) -> Bool {
        guard let roll else { return false }
        let gone = roll.delete(id)
        refresh(roll: roll, now: now)
        return gone
    }

    /// Makes `id` its set's favorite (its cover), or clears it when it already is; then reads again.
    ///
    /// - Returns: whether the choice was kept.
    func toggleFavorite(_ id: UUID, in photoSet: SoloPhotoSet, now: Date = .now) -> Bool {
        guard let roll else { return false }
        let isFavorite = photoSet.photos.first { $0.id == id }?.isFavorite == true
        let kept = roll.setFavorite(isFavorite ? nil : id, among: Set(photoSet.photoIDs))
        refresh(roll: roll, now: now)
        return kept
    }
}
