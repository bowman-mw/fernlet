import CryptoKit
import FernletDomainModel
import FernletFoundation
import PrivateMediaStore
import Foundation
import UIKit
import WorldMapStore

/// "Where you've been" and the solo photos' places (World build step 5c; `b2-where-been`, owner's option A
/// and Q24, 2026-10-24): the store's side of ``WorldPlacesKeeper`` and `PhotoPlaceStore`.
///
/// - **Capture** happens on the map: readings while Fernlet is open (``noteWorldPlace(from:)``), iOS's
///   low-power visits with background mapping on, and the walks and runs it records.
/// - **Private reads it under the hub key** (``worldPlaceLog(now:)`` and the deletes), the key the
///   journal's entries are sealed under, from ``hubContentKeyProvider``. No key (Private closed) or a
///   decoy: nothing is read, and the page shows nothing. A kept place's name is asked for again by its
///   reference while the page is open (``worldPlaceName(for:)``) and held in memory only.
/// - **Solo photos** keep where they were taken only at an everyday place or inside a park, beach or
///   campground (``keepSoloPhotoPlace(for:fix:now:)``, owner, round 5); deleting a photo deletes its
///   place; only shown photos sit on the map (``worldPhotoMarkers(visibleAt:near:)``).
extension FernletStore {
    // MARK: Capture

    /// A reading from the map's location source: while Fernlet is open and in front (the map's own
    /// updates, a panel or sheet over the map or not; not a walk, not a background reading), it may note a
    /// visit once the person has stopped (W-13). Nothing in a decoy.
    func noteWorldPlace(from fix: WorldFix) {
        guard worldPlaceNotingAllowed else { return }
        let keeper = worldPlaces
        Task { await keeper.handleForeground(fix) }
    }

    /// Whether a reading may note a place now: the map's own updates, the app active, no decoy.
    var worldPlaceNotingAllowed: Bool {
        !duressSessionActive && worldLocation.isFollowingMap && UIApplication.shared.applicationState == .active
    }

    /// A reading for the fog: lifted, and saved at once when it arrived while the app isn't active (W-09 B2).
    /// While driving the drive's lane lifts, 25 m either side of the road and joined (round 7, `nf-car`; owner 2026-10-30).
    func liftWorldFog(_ fix: WorldFix) {
        worldFog.handle(fix, saveNow: UIApplication.shared.applicationState != .active,
                        thinLine: worldLocation.rides.isDriving)
    }

    /// Arms background mapping when the person turned it on and Always is allowed, or turns it off.
    func applyWorldBackgroundMapping() {
        let on = WorldMapPreferences.alwaysLowPower()
        worldLocation.setLowPowerAlways(on && worldLocation.permission == .always)
    }

    /// At launch, once the store is ready (W-09 B1): with background mapping's switch on, builds the map's
    /// location source and arms it, so a visit or a significant move iOS launches the app for is heard
    /// without Home ever drawing. With the switch off nothing is built (CoreLocation waits for the map).
    func armWorldBackgroundMappingAtLaunch() {
        guard WorldMapPreferences.alwaysLowPower() else { return }
        wireWorldRides()
        applyWorldBackgroundMapping()
    }

    /// The map's location while Fernlet is open (W-09 (i)), from the app's own edges (the launch screen
    /// lifting, the app back in front), so it runs even when Home isn't drawn (a launch straight into a
    /// panel). A no-op without permission or when already running. Each edge also looks for bike rides the
    /// motion history holds from while the app was closed (round 7).
    func startWorldMapLocation() {
        wireWorldRides()
        Task { await catchUpWorldBikeRides() }
        worldFog.load()
        worldLocation.startForeground()
    }

    /// The app went to the background: the map's own updates stop (a walk and background mapping keep
    /// theirs) and the lifted cells are written. Home does the same when it sees the edge; this is the
    /// app's own, for when Home isn't drawn.
    func worldAppDidEnterBackground() {
        worldLocation.stopForeground()
        worldFog.flush()
    }

    // MARK: Settings → Home map

    /// How many walk and run lines are stored on this iPhone (none shown in a decoy).
    var worldStoredRouteCount: Int {
        guard !duressSessionActive else { return 0 }
        do {
            return try worldRoutes.workoutIDs().count
        } catch {
            return 0
        }
    }

    /// How many workout spaces have a pin (none shown in a decoy).
    var worldPinnedSpaceCount: Int {
        guard !duressSessionActive else { return 0 }
        do {
            return try worldSpacePins.all().count
        } catch {
            return 0
        }
    }

    /// "Delete all stored routes": every walk and run line; the workouts stay. Nothing real in a decoy.
    func deleteAllWorldRoutes() -> Bool {
        guard !duressSessionActive else { return true }
        do {
            return try worldRoutes.deleteAll()
        } catch {
            FernletAuditLog.log("worldMap.routes.deleteAllFailed")
            return false
        }
    }

    /// "Forget workout-space locations": every space's pin; the spaces stay. Nothing real in a decoy.
    func forgetAllWorkoutSpacePins() -> Bool {
        guard !duressSessionActive else { return true }
        return worldSpacePins.removeAll()
    }

    /// "Delete map history": the fog, the lines, Where you've been, the pins and the photos' places, with
    /// the vault's keys (the same reach as the wipes'). Nothing real in a decoy.
    func deleteWorldMapHistory() -> Bool {
        guard !duressSessionActive else { return true }
        worldPlaces.forget()
        return worldFog.clearAll()
    }

    // MARK: Private's page, under the hub key

    /// The Private tab's hub key now, or nil (Private closed, or a decoy).
    private var worldPlacesKey: SymmetricKey? {
        guard !duressSessionActive else { return nil }
        return hubContentKeyProvider?()
    }

    /// Where you've been, with everything captured since the last look folded in under the hub key; nil
    /// while Private is closed, in a decoy, or when it can't be read right now.
    func worldPlaceLog(now: Date = Date()) -> PlaceLog? {
        // DEBUG scene `where` (`ref-home-where`): a day with Home left and got back, display only.
        if WorldPlacesTestScenes.scenes.contains("where"), !duressSessionActive, let home = worldHomes.homes.first {
            return WorldPlacesTestScenes.log(home: home.id, now: now)
        }
        guard let key = worldPlacesKey else { return nil }
        do {
            return try worldPlaces.store.fold(hubKey: key, now: now)
        } catch {
            FernletAuditLog.log("worldMap.places.readDeferred")
            return nil
        }
    }

    /// "Delete a day": the day's stops (visits off their places' counts) and the saved lines of its walks
    /// and runs. Whether it went.
    func deleteWorldPlaceDay(_ day: Date, now: Date = Date()) -> Bool {
        guard let key = worldPlacesKey else { return false }
        do {
            let workouts = try worldPlaces.store.deleteDay(day, hubKey: key, now: now)
            for id in workouts { worldRoutes.delete(for: id) }
            return true
        } catch {
            FernletAuditLog.log("worldMap.places.deleteDayFailed")
            return false
        }
    }

    /// "Delete all of it": the timeline, Places you return to, what waits on the device side, and the
    /// saved lines of the walks and runs on the timeline. Whether it all went.
    func deleteAllWorldPlaces(now: Date = Date()) -> Bool {
        guard !duressSessionActive else { return false }
        if let log = worldPlaceLog(now: now) {
            for id in log.stops.compactMap(\.workoutID) { worldRoutes.delete(for: id) }
        }
        worldPlaces.forget()
        // Round 7: the "Not here" spots and the places remembered go with Where you've been.
        let marksGone = worldPlaces.removeMarks()
        let deleted = worldPlaces.store.deleteAll() && marksGone
        // The homes and hotel stay (removed in Settings › Home map); the map reads them again.
        worldPlaces.reloadDeviceSide()
        return deleted
    }

    /// The name and kind of `place` as Apple Maps gives them again by its reference, held in memory only;
    /// nil with no reference, no answer (offline), Private closed or a decoy. The DEBUG scene `namesOffline`
    /// answers nil, as offline.
    func worldPlaceName(for place: PlaceRecord) async -> WorldPlaceName? {
        guard worldPlacesKey != nil, !UITestSupport.worldHomeScenes.contains("namesOffline") else { return nil }
        let keeper = worldPlaces
        let name = await keeper.name(of: place)
        return duressSessionActive ? nil : name
    }

    /// Gives place `id` the person's own name, shown from then on in place of the one asked for by its
    /// reference; a place they eat out at (the same place) takes the name on the map too (round 6).
    func renameWorldPlace(_ id: UUID, to name: String, now: Date = Date()) -> PlaceLog? {
        guard let key = worldPlacesKey else { return nil }
        do {
            let log = try worldPlaces.store.rename(id, to: name, hubKey: key, now: now)
            let reference = log.places.first { $0.id == id }?.placeID
            worldPlaces.reloadDeviceSide()
            if let eating = worldPlaces.eatingPlaces.first(where: { $0.id == id || ($0.placeID == reference && reference != nil) }) {
                worldPlaces.renameEatingPlace(eating.id, to: name)
            }
            // Round 7: a remembered restaurant's or gym's icon takes the name too.
            worldPlaces.renameKeptPlace(id, to: name)
            return log
        } catch {
            FernletAuditLog.log("worldMap.places.renameFailed")
            return nil
        }
    }

    // MARK: Solo photos' places

    /// Keeps where solo photo `id` was taken, from `fix`, only at one of the everyday places a visit is kept
    /// at or inside a park, beach or campground (``PlaceClassifier/photoMayKeepPlace(_:)``; owner, round 5).
    /// Anywhere else, or when the place can't be checked (offline), it keeps none, and the photo stays in
    /// Just you, off the map. Only a fresh, precise reading counts; nothing in a decoy. Whether a place was
    /// kept. Only the point is kept, never the lookup's answer.
    @discardableResult
    func keepSoloPhotoPlace(for id: UUID, fix: WorldFix?, now: Date = Date()) async -> Bool {
        guard !duressSessionActive, let fix, WorldPhotoPlaceRules.isGoodEnough(fix, at: now) else { return false }
        let nearby = await worldPlaceLookup.nearbyPlaces(around: fix.point)
        guard !duressSessionActive, PlaceClassifier.photoMayKeepPlace(nearby) else { return false }
        do {
            return try worldPhotoPlaces.setPlace(fix.point, for: id)
        } catch {
            FernletAuditLog.log("worldMap.photoPlace.saveFailed")
            return false
        }
    }

    /// Forgets the places of the solo photos in `ids` (a photo deleted).
    func forgetSoloPhotoPlaces(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        do {
            try worldPhotoPlaces.remove(ids)
        } catch {
            FernletAuditLog.log("worldMap.photoPlace.removeFailed")
        }
    }

    /// The solo photos that show at `now` and have a place, as the map's markers: one per place (photos
    /// within 40 m of each other share one), nearest first when `fix` is known. None in a decoy.
    func worldPhotoMarkers(visibleAt now: Date = Date(), near fix: WorldFix? = nil) -> [WorldPhotoPlace] {
        guard !duressSessionActive else { return [] }
        let places: [UUID: GeoPoint]
        do {
            places = try worldPhotoPlaces.all()
        } catch {
            return []
        }
        guard !places.isEmpty else { return [] }
        let shown = soloCameraRoll().photos(visibleAt: now).filter { places[$0.id] != nil }
        return WorldPhotoPlace.grouped(shown, places: places, near: fix?.point)
    }

    /// The name a solo photo's place goes by on its card: the workout space pinned within 100 m of it, or
    /// nil (a place's own name stays sealed in Private). None in a decoy.
    func soloPhotoPlaceName(for id: UUID) -> String? {
        guard !duressSessionActive else { return nil }
        do {
            guard let point = try worldPhotoPlaces.place(for: id) else { return nil }
            return worldSpace(at: point)?.displayedName
        } catch {
            return nil
        }
    }
}

/// When a reading may place a solo photo: precise, within 50 m, and taken in the last two minutes, so a
/// photo never gets a place from an approximate area or from somewhere the person has left.
nonisolated enum WorldPhotoPlaceRules {
    /// The worst accuracy a placing reading may have, in metres.
    static let maxAccuracy = 50.0
    /// The oldest a placing reading may be.
    static let maxAge: TimeInterval = 2 * 60

    /// Whether `fix` may place a photo taken at `date`.
    static func isGoodEnough(_ fix: WorldFix, at date: Date) -> Bool {
        fix.isPrecise && fix.accuracy <= maxAccuracy && fix.point.isValid && abs(date.timeIntervalSince(fix.at)) <= maxAge
    }
}

/// Solo photos on the map (`b1-markers`' photo print): the photos taken at one place, newest first, at that
/// place. Only photos that have shown (after the companion slept), never a friend's.
nonisolated struct WorldPhotoPlace: Equatable, Identifiable, Sendable {
    /// How near photos must be to share one marker, in metres.
    static let groupRadius = 40.0

    /// The newest photo's id.
    let id: UUID
    let point: GeoPoint
    /// The photos taken here, newest first.
    let photoIDs: [UUID]

    /// `photos` (shown, newest first) grouped by place: each joins the first group within ``groupRadius``.
    /// Nearest `here` first, when known.
    static func grouped(_ photos: [SoloCameraPhoto], places: [UUID: GeoPoint], near here: GeoPoint?) -> [WorldPhotoPlace] {
        var groups: [WorldPhotoPlace] = []
        for photo in photos {
            guard let point = places[photo.id] else { continue }
            if let index = groups.firstIndex(where: { $0.point.distance(to: point) <= groupRadius }) {
                groups[index] = WorldPhotoPlace(id: groups[index].id, point: groups[index].point,
                                                photoIDs: groups[index].photoIDs + [photo.id])
            } else {
                groups.append(WorldPhotoPlace(id: photo.id, point: point, photoIDs: [photo.id]))
            }
        }
        guard let here else { return groups }
        return groups.sorted { here.distance(to: $0.point) < here.distance(to: $1.point) }
    }
}
