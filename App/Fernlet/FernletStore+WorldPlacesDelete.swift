import FernletFoundation
import Foundation
import WorldMapStore

/// Deleting one place, or one stop, in Where you've been (W-14, Refinements group 18, owner-approved
/// 2026-10-26): the store's side of `ref-del-confirm` and `ref-del-stop`, beside "Delete a day".
///
/// - **Under the hub key**, as every read and delete of the log is: what waits on the device is folded in
///   first, then the log is sealed again without the place or the stop.
/// - **It doesn't come back.** A place that goes (deleted, or its last visit deleted) is forgotten on the
///   device side too (``PlaceDeviceState/forgettingPlaces(_:)``): no longer matched, nothing of it waiting,
///   its place to eat gone with its map icon (`ref-places-map`), and a place remembered with "Remember
///   this place" loses its kept mark and icon (``WorldPlaceMarks/forgetting(_:)``). The meals and photos stay.
/// - **A walk's or run's stop** takes its saved line with it; the workout stays in Move.
/// - **Homes and hotels** are never deleted here (Settings › Home map): a leave or a return goes alone.
/// - **A decoy**, which never has the hub key, deletes nothing real.
extension FernletStore {
    /// Deletes place `id` and every visit to it, on any day; the other places keep their counts. The log
    /// after it, or nil when it couldn't be done (Private closed, a decoy, the files unreadable now).
    func deleteWorldPlace(_ id: UUID, now: Date = Date()) -> PlaceLog? {
        applyWorldPlaceDeletion(now: now) { $0.deletingPlace(id) }
    }

    /// Deletes stop `id` from the timeline: a visit comes off its place's count (a place left with none
    /// goes), a walk's or run's saved line goes. The log after it, or nil when it couldn't be done.
    func deleteWorldPlaceStop(_ id: UUID, now: Date = Date()) -> PlaceLog? {
        applyWorldPlaceDeletion(now: now) { $0.deletingStop(id) }
    }

    /// Folds, applies `deletion` to the log and seals the result; then forgets the places it removed on
    /// the device side and deletes the saved lines it names. Nil, with nothing changed, in a decoy or
    /// without the hub key; nil when a file can't be read or written now (logged, never thrown).
    private func applyWorldPlaceDeletion(now: Date,
                                         _ deletion: (PlaceLog) -> (log: PlaceLog, workoutIDs: [UUID], removedPlaces: Set<UUID>)) -> PlaceLog? {
        guard !duressSessionActive, let key = hubContentKeyProvider?() else { return nil }
        do {
            let current = try worldPlaces.store.fold(hubKey: key, now: now)
            let result = deletion(current)
            guard result.log != current else { return current }
            try worldPlaces.store.saveLog(result.log, hubKey: key)
            let removed = current.places.filter { result.removedPlaces.contains($0.id) }
            try worldPlaces.store.updateDeviceState { $0.forgettingPlaces(removed) }
            for workout in result.workoutIDs { worldRoutes.delete(for: workout) }
            // A place remembered with "Remember this place" loses its kept mark and icon too (round 7).
            worldPlaces.forgetKeptPlaces(result.removedPlaces)
            // The map's places to eat as they are now, so a deleted place's icon goes at once.
            worldPlaces.reloadDeviceSide()
            return result.log
        } catch {
            FernletAuditLog.log("worldMap.places.deleteOneFailed")
            return nil
        }
    }
}
