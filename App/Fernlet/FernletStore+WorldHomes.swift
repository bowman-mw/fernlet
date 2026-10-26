import FernletDomainModel
import FernletFoundation
import Foundation
import WorldMapStore

/// Round 6's places on the store (owner-approved 2026-10-25): the person's homes and hotel (`ref-home-*`,
/// `ref-hotel`), a place they add themselves (`ref-tag-*`), and the map's greeting. All of it lives in the
/// places file's device side (``WorldPlacesKeeper``), sealed on this iPhone; a decoy reads and writes none
/// of it, every wipe and an app-lock reset delete it.
extension FernletStore {
    // MARK: Homes and hotels

    /// The companion's name as the approved copy says "Sprout": the person's choice, or "Fernlet".
    var worldCompanionName: String {
        let chosen = settings.companionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.isEmpty ? "Fernlet" : chosen
    }

    /// The homes and hotel as last read (none in a decoy; DEBUG scenes `homes` and `hotel` stand one in where
    /// the person stands, display only).
    var worldHomes: HomeBook {
        guard !duressSessionActive else { return .empty }
        let scenes = WorldPlacesTestScenes.scenes
        if !scenes.isDisjoint(with: ["homes", "hotel", "where"]) {
            return WorldPlacesTestScenes.homes(at: worldLocation.latest?.point ?? WorldPlacesTestScenes.laurelhurst,
                                               home: !scenes.isDisjoint(with: ["homes", "where"]), hotel: scenes.contains("hotel"))
        }
        return worldPlaces.homes
    }

    /// Reads the homes, hotel and places to eat again (the map or Settings coming to the front).
    func reloadWorldHomes() {
        guard !duressSessionActive else { return }
        worldPlaces.reloadDeviceSide()
    }

    /// Saves `home` (new, moved or renamed), replacing `replacing` when two homes are kept. Nothing real in
    /// a decoy. Whether it was saved.
    @discardableResult
    func saveWorldHome(_ home: HomePlace, replacing: UUID? = nil) -> Bool {
        guard !duressSessionActive else { return true }
        return worldPlaces.saveHome(home, replacing: replacing)
    }

    /// Checks in at `hotel` (or moves or renames the current one). Nothing real in a decoy.
    @discardableResult
    func checkInWorldHotel(_ hotel: HomePlace) -> Bool {
        guard !duressSessionActive else { return true }
        return worldPlaces.checkIn(hotel)
    }

    /// Ends the hotel stay (the hotel is remembered for a welcome back). Nothing real in a decoy.
    @discardableResult
    func checkOutWorldHotel() -> Bool {
        guard !duressSessionActive else { return true }
        return worldPlaces.checkOut()
    }

    /// Removes the home or hotel `id`: its circle fogs again except where the person has been. Nothing real
    /// in a decoy.
    @discardableResult
    func removeWorldHome(_ id: UUID) -> Bool {
        guard !duressSessionActive else { return true }
        return worldPlaces.removeHome(id)
    }

    /// Sprout's greeting waiting for the map while the person is still there, once (`ref-home-arrive`,
    /// `ref-hotel`), in words. Nil in a decoy or with none waiting.
    func takeWorldHomeGreeting() -> String? {
        guard !duressSessionActive, let taken = worldPlaces.takeGreeting() else { return nil }
        return WorldHomeMapCopy.greeting(taken.greeting, place: taken.place)
    }

    // MARK: A place the person adds (ref-tag-*)

    /// The spot the last lookup refused while the person is still there (`ref-tag-home`), or nil: none, they
    /// moved on, it is old, a walk is recording, or a decoy.
    func worldRefusedSpot(near fix: WorldFix?, now: Date = Date()) -> GeoPoint? {
        if WorldPlacesTestScenes.scenes.contains("refused"), !duressSessionActive, let fix { return fix.point }
        guard !duressSessionActive, !worldLocation.isWalking, let spot = worldPlaces.refusedSpot, let fix,
              spot.point.distance(to: fix.point) <= WorldPlacesKeeper.refusedSpotReach,
              now.timeIntervalSince(spot.at) <= WorldPlacesKeeper.refusedSpotLife else { return nil }
        return spot.point
    }

    /// Remembers the place the person named at `point` (`ref-tag-name`): it joins their places, with a visit
    /// now. Nothing in a decoy. Whether it was kept.
    @discardableResult
    func rememberWorldPlace(named name: String, at point: GeoPoint, now: Date = Date()) -> Bool {
        guard !duressSessionActive else { return true }
        return worldPlaces.remember(name, at: point, date: now)
    }

    /// Puts solo photo `id`, which kept no place, on the map at `point`, where the person says they took it
    /// (`ref-tag-photo`); a name, when given, also makes the spot one of their places, with a visit when the
    /// photo was taken (`takenAt`). Nothing in a decoy. Whether the photo got its place.
    @discardableResult
    func putSoloPhotoOnMap(_ id: UUID, at point: GeoPoint, named name: String, takenAt: Date) -> Bool {
        guard !duressSessionActive, point.isValid else { return false }
        do {
            guard try worldPhotoPlaces.setPlace(point, for: id) else { return false }
        } catch {
            FernletAuditLog.log("worldMap.photoPlace.saveFailed")
            return false
        }
        if PlaceRecord.validLabel(name) != nil { worldPlaces.remember(name, at: point, date: takenAt) }
        return true
    }

    /// Whether solo photo `id` has a place on the map (none read in a decoy).
    func soloPhotoHasPlace(_ id: UUID) -> Bool {
        guard !duressSessionActive else { return false }
        do {
            return try worldPhotoPlaces.place(for: id) != nil
        } catch {
            return false
        }
    }

    // MARK: The app-lock reset

    /// The app-lock reset's reach, at once (its screens say "This also deletes the places you've been."):
    /// Where you've been, its device side, the homes and hotel and the places to eat, with what is held in
    /// memory. The log could no longer open under the new hub key anyway; this also takes the device side
    /// at once, so the map draws no home after the reset. Never in a decoy.
    func deleteWorldPlacesForLockReset() {
        guard !duressSessionActive else { return }
        worldPlaces.forget()
        if !worldPlaces.store.deleteEverything() { FernletAuditLog.log("worldMap.places.resetDeleteFailed") }
    }
}
