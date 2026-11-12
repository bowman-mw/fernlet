import FernletFoundation
import FernletSocial
import Foundation
import PrivateMediaStore
import WorldMapStore

/// The trip roll as Home's camera shows it (`rt-photos`): the trip it shoots for and the photos this person can
/// still take on it ("Road trip · 26 of 30"); `left` is nil while the roll can't be read (the camera is off then,
/// never the solo roll instead).
nonisolated struct RoadTripCameraFilm: Equatable, Sendable {
    /// The trip on now.
    let tripID: UUID
    /// Photos left of ``limit``; nil when the roll can't be read right now.
    let left: Int?
    /// The most one person takes on one trip.
    let limit: Int
}

/// One trip photo as the photo viewer shows it (`rt-map`): its caption ("Road trip to the coast · Nov 10 · Rae"), what
/// VoiceOver says ("Photo from the road trip to the coast, by Rae"), and where it stands with the map, so the viewer
/// offers "Hide from the map" only while it is on the map and "Show on the map" only while it is hidden with a place
/// (a photo opened from the Album may have no place, or be hidden).
nonisolated struct RoadTripPhotoDetail: Equatable, Identifiable, Sendable {
    /// The photo's id on this iPhone.
    let id: UUID
    /// The caption under it.
    let caption: String
    /// Its VoiceOver label.
    let spoken: String
    /// Whether it has a place on the map (none yet, or gone with Delete map history, when not).
    let hasPlace: Bool
    /// Whether it was hidden from the map.
    let isHidden: Bool

    /// Whether it sits on the map: shown, with a place.
    var isOnMap: Bool { hasPlace && !isHidden }
}

/// Road trip photos, the store's side (World-RoadTrip-Spec PR 3, owner-approved 2026-11-10: `rt-photos`, straight
/// onto the map; `rt-map`): the trip roll on Home's camera, places from the trip's road, photos swapped at catch-ups,
/// the prints on the map with their caption, and "Hide from the map". The roll is ``roadTripPhotos``
/// (``RoadTripPhotoRoll``: the sealed `RoadTripPhotos/` corpus and `road-trip-photo-places.bin` in the map's vault).
///
/// - **The roll:** with a trip on and no hangout, the camera shoots onto it (``takeRoadTripPhoto(_:fix:now:)``), up to
///   30 a person a trip, each sealed with its capture time.
/// - **Places from the road** (``resolveRoadTripPhotoPlaces(in:)``, ``RoadTripPhotoPlacing``): the trip's line at the
///   capture time; known at once when this iPhone maps (its own fresh reading), else when the road arrives: as this
///   iPhone's line grows (Home coming to the front) or at the next catch-up. Anywhere on the trip's road.
/// - **Swapped at catch-ups** (``sendRoadTripPhotos(of:to:held:now:)``, ``receiveRoadTripPhoto(_:from:now:)``): only
///   this iPhone's own photos go, only to a member who was there when each was taken, only those they lack; a
///   friend's photo is kept with them as its author, within this iPhone's own presence, re-encoded, once.
/// - **On the map** (``roadTripPhotoMarkers(near:)``): every shown trip photo with a place, friends' included (the
///   spec's trip-only exception to "never a friend's photo on the map"), grouped within 40 m like solo photos.
/// - **Decoy:** nothing is taken (no trip is on), sent, received, placed or shown; the roll reads and writes nothing.
/// - **Wipes:** ``purgeRoadTripPhotosForDeleteAll()`` (Delete everything's leg 4f) removes the corpus; the places go
///   with the map's vault (`worldFog.clearAll()`), so Delete map history and the recovery lock take them too.
extension FernletStore {
    /// THIS store's road trip photo corpus: `RoadTripPhotos/` under its own proximity root (per instance, as the
    /// solo corpus is, so a test store that wipes never reaches another store's photos).
    nonisolated var roadTripPhotoDirectory: URL {
        RoadTripPhotoStore.directory(in: proximitySupportRoot)
    }

    // MARK: The trip roll (`rt-photos`)

    /// The trip roll the camera shoots onto now: the trip on now and the photos left of this person's 30; nil with
    /// no trip on, and in a decoy (the camera is the solo one then).
    func roadTripCameraFilm() -> RoadTripCameraFilm? {
        guard !duressSessionActive, let trip = worldFog.roadTrip.active else { return nil }
        let used = roadTripPhotos.index()?.count(trip: trip.id, author: trip.selfID)
        return RoadTripCameraFilm(tripID: trip.id, left: used.map { max(0, RoadTripPhotoRules.perMember - $0) },
                                  limit: RoadTripPhotoRules.perMember)
    }

    /// A shot on the trip roll at `now`: normalized (downscaled, re-encoded, its metadata left behind) and sealed with
    /// its capture time, then placed at once from `fix` when this iPhone maps and the reading is fresh, else from
    /// the line when the road comes. Nothing with no trip on or in a decoy.
    func takeRoadTripPhoto(_ captured: Data, fix: WorldFix?, now: Date = Date()) -> SoloShotOutcome {
        guard !duressSessionActive, let trip = worldFog.roadTrip.active,
              let bytes = SoloCameraRoll.normalized(captured) else { return .notKept }
        let id = UUID()
        let photo = RoadTripPhoto(id: id, tripID: trip.id, authorID: trip.selfID, sourceID: id, takenAt: now)
        switch roadTripPhotos.add(photo, bytes: bytes) {
        case .added:
            if trip.isMapping, let point = RoadTripPhotoPlacing.placeNow(fix: fix, takenAt: now) {
                if roadTripPhotos.setPlaces([id: point]) == 0 { FernletAuditLog.log("worldMap.roadTripPhoto.placeUnsaved") }
            } else {
                resolveRoadTripPhotoPlaces(in: trip)
            }
            return .kept
        case .authorFull:
            return .noFilmLeft
        case .duplicate, .full, .unsafeImage, .notPersisted, .deferred:
            return .notKept
        }
    }

    // MARK: Places from the road

    /// Places the photos of `trip` that have no place yet from its line on this iPhone (``RoadTripPhotoPlacing``), in
    /// one write. How many were placed; none in a decoy or while the line can't be read.
    @discardableResult
    func resolveRoadTripPhotoPlaces(in trip: RoadTrip) -> Int {
        guard !duressSessionActive, let index = roadTripPhotos.index() else { return 0 }
        let placed = roadTripPhotos.allPlaces()
        let waiting = index.photos(of: trip.id).filter { placed[$0.id] == nil }
        guard !waiting.isEmpty,
              let line = worldFog.roadTrip.linePoints(of: trip, after: .distantPast, through: .distantFuture) else { return 0 }
        var found: [UUID: GeoPoint] = [:]
        // R2: bounded by one trip's photos.
        for photo in waiting.prefix(RoadTripPhotoRules.perTrip) {
            if let point = RoadTripPhotoPlacing.place(at: photo.takenAt, on: line) { found[photo.id] = point }
        }
        return roadTripPhotos.setPlaces(found)
    }

    /// Home's map coming to the front: the trip on now's photos with no place are looked for on its line again,
    /// once the line has grown since the last look.
    func resolveActiveRoadTripPhotoPlaces() {
        let keeper = worldFog.roadTrip
        guard !duressSessionActive, let trip = keeper.active, roadTripPhotos.placesTriedAtLineCount != keeper.pointCount else { return }
        roadTripPhotos.placesTriedAtLineCount = keeper.pointCount
        resolveRoadTripPhotoPlaces(in: trip)
    }

    // MARK: Swapped at catch-ups

    /// The ids (on `member`'s phone) of their photos of `trip` this iPhone holds, for a catch-up to them, so they
    /// send only the rest; nil for none (or while the roll can't be read).
    func roadTripHeldPhotos(of trip: RoadTrip, from member: String) -> [UUID]? {
        guard !duressSessionActive, let index = roadTripPhotos.index() else { return nil }
        let held = Array(index.sourceIDs(trip: trip.id, author: member).prefix(RoadTripPhotoRules.perMember))
        return held.isEmpty ? nil : held
    }

    /// After a catch-up with `fingerprint`'s member at `now` (whose `held` names what of this iPhone's they hold):
    /// this iPhone's photos of `trip` they are owed (``RoadTripPhotoRules/owed(_:to:in:held:now:)``) go to them in
    /// pieces, and Home's note waits for the send. How many photos were queued; none in a decoy.
    @discardableResult
    func sendRoadTripPhotos(of trip: RoadTrip, to fingerprint: String, held: [UUID], now: Date = Date()) -> Int {
        guard !duressSessionActive, let index = roadTripPhotos.index() else { return 0 }
        let owed = RoadTripPhotoRules.owed(index.photos(of: trip.id), to: RoadTripMembers.id(fingerprint), in: trip,
                                           held: Set(held.prefix(RoadTripPhotoRules.perMember)), now: now)
        guard !owed.isEmpty else { return 0 }
        let outgoing = owed.map { RoadTripOutgoingPhoto(tripID: trip.id, photoID: $0.id, takenAt: $0.takenAt) }
        let mesh = roadTripMesh, roll = roadTripPhotos
        mesh.beginSending()
        return meshFeatures.roadTrip.sendPhotos(outgoing, to: fingerprint, bytes: { [weak roll] in roll?.imageData(for: $0) },
                                                done: { [weak mesh] in mesh?.endSending() })
    }

    /// A friend's trip photo, whole and checked by the exchange: kept when they are on a trip this iPhone shares with
    /// them and it was taken within this iPhone's own presence (``RoadTripPhotoRules/accepts(takenAt:in:now:)``),
    /// with them as its author, re-encoded, once and within the roll's bounds; then placed from this iPhone's line.
    /// Whether it was kept; never in a decoy.
    @discardableResult
    func receiveRoadTripPhoto(_ photo: RoadTripReceivedPhoto, from fingerprint: String, now: Date = Date()) -> Bool {
        guard !duressSessionActive else { return false }
        let member = RoadTripMembers.id(fingerprint)
        guard let trip = worldFog.roadTrip.trip(sharedWith: member, id: photo.tripID),
              RoadTripPhotoRules.accepts(takenAt: photo.takenAt, in: trip, now: now),
              let bytes = RoadTripPhotoRules.normalized(photo.bytes) else {
            FernletAuditLog.log("worldMap.roadTripPhoto.refused")
            return false
        }
        let entry = RoadTripPhoto(tripID: trip.id, authorID: member, sourceID: photo.photoID, takenAt: photo.takenAt)
        guard case .added = roadTripPhotos.add(entry, bytes: bytes) else {
            FernletAuditLog.log("worldMap.roadTripPhoto.notKept")
            return false
        }
        resolveRoadTripPhotoPlaces(in: trip)
        roadTripMesh.notePhotoActivity()
        return true
    }

    // MARK: On the map (`rt-map`)

    /// The trip photos on the map: every shown trip photo with a place, this iPhone's and friends', newest first,
    /// grouped within 40 m like solo photos (``WorldPhotoPlace``), nearest `fix` first. None in a decoy.
    func roadTripPhotoMarkers(near fix: WorldFix? = nil) -> [WorldPhotoPlace] {
        guard !duressSessionActive, let index = roadTripPhotos.index() else { return [] }
        let places = roadTripPhotos.allPlaces()
        guard !places.isEmpty else { return [] }
        let shown = index.photos.filter { $0.isShown && places[$0.id] != nil }.sorted { $0.takenAt > $1.takenAt }
        return WorldPhotoPlace.grouped(ids: shown.map(\.id), places: places, near: fix?.point)
    }

    /// What the photo viewer shows for each of `ids` still here, in their order: the caption and the VoiceOver label,
    /// from the trip the photo was taken on (or, once its record is gone, from who took it as this iPhone still knows
    /// them, ``roadTripPhotoAuthor(_:in:)``), and whether it is on the map. A print on the map passes only the shown
    /// photos; the Album (`includingHidden`) every one, since hiding is from the map only. None in a decoy.
    func roadTripPhotoDetails(_ ids: [UUID], includingHidden: Bool = false) -> [RoadTripPhotoDetail] {
        guard !duressSessionActive, let index = roadTripPhotos.index() else { return [] }
        worldFog.roadTrip.load()
        let trips = worldFog.roadTrip.book.trips
        let places = roadTripPhotos.allPlaces()
        let byID = Dictionary(index.photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.prefix(RoadTripPhotoStore.maxPhotos).compactMap { id in
            guard let photo = byID[id], includingHidden || photo.isShown else { return nil }
            let trip = trips.last { $0.id == photo.tripID }
            let author = roadTripPhotoAuthor(photo.authorID, in: trip)
            return RoadTripPhotoDetail(id: id, caption: RoadTripCopy.photoCaption(trip: trip, takenAt: photo.takenAt, author: author),
                                       spoken: RoadTripCopy.photoSpoken(trip: trip, author: author),
                                       hasPlace: places[id] != nil, isHidden: !photo.isShown)
        }
    }

    /// A trip photo's bytes for the viewer; nil in a decoy.
    func roadTripPhotoImage(_ id: UUID) -> Data? {
        duressSessionActive ? nil : roadTripPhotos.imageData(for: id)
    }

    /// "Hide from the map": any trip photo, a friend's or this iPhone's, leaves the map (it stays on this iPhone, and
    /// is not sent at a catch-up any more). Whether it went; nothing in a decoy.
    func hideRoadTripPhoto(_ id: UUID) -> Bool {
        guard !duressSessionActive else { return false }
        return roadTripPhotos.hide(id)
    }

    /// "Show on the map" (owner 2026-11-12, "Yes, add it"): a hidden trip photo goes back on the map where it was
    /// taken, and this iPhone's own goes to friends at a catch-up again. Whether it is shown; nothing in a decoy.
    func showRoadTripPhoto(_ id: UUID) -> Bool {
        guard !duressSessionActive else { return false }
        return roadTripPhotos.show(id)
    }

    /// The trip's photos on this iPhone, this person's and friends' (Trip info's "6 photos", the catch-up note).
    func roadTripPhotoCount(of tripID: UUID) -> Int {
        guard !duressSessionActive else { return 0 }
        return roadTripPhotos.index()?.photos(of: tripID).count ?? 0
    }

    // MARK: Wipes

    /// Delete everything's road trip photo leg (4f, inside `deletePhotoCorpora`): the whole sealed corpus — every
    /// photo, thumbnail and hidden flag — keyless; the places go with the map's vault. Whether the corpus is gone.
    func purgeRoadTripPhotosForDeleteAll() -> Bool {
        roadTripPhotos.purgeForDeleteAll()
    }
}
