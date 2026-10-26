import Foundation
import FernletDomainModel
import FernletFoundation
import WorldMapStore

/// Workout spaces on the World map (World build, branch `world-ui`; World app plan step 6a): where each
/// of the person's spaces is, so the blue button can offer "Today's plan at Riverside Gym" when they're
/// there (step 6b).
///
/// - **Asked once** (the approved pin question, step 6b, in workout-space setup): "Remember where your
///   workout spaces are?" The answer is device-only (``WorldMapPreferences/rememberSpaces(in:)``);
///   until it is yes, nothing here reads a location or pins anything.
/// - **Pinned at its first guided workout there:** a guided run that starts with a space of the person's
///   own active, with a precise reading under 50 m from the last five minutes, pins that space where
///   they stand (``WorldSpacePinRules``). A space already pinned keeps its pin.
/// - **Matched on the phone** within 100 m (``SpacePinStore/matchRadius``).
/// - **Deleting a space deletes its pin**; a decoy sees no pins and pins nothing; the wipes clear them
///   with the rest of the map's vault.
extension FernletStore {
    /// The guided-run hook: pins the active space when the person said yes. Touches location only then.
    func pinWorkoutSpaceAtGuidedStart(at date: Date = Date(), defaults: UserDefaults = .standard) {
        guard WorldMapPreferences.rememberSpaces(in: defaults) == true else { return }
        pinActiveWorkoutSpace(from: worldLocation.latest, at: date, defaults: defaults)
    }

    /// Pins the active workout space at `fix` when every rule allows it. Whether a pin was set.
    @discardableResult
    func pinActiveWorkoutSpace(from fix: WorldFix?, at date: Date, defaults: UserDefaults = .standard) -> Bool {
        guard WorldMapPreferences.rememberSpaces(in: defaults) == true, !duressSessionActive,
              let id = settings.activeWorkoutLocationID, settings.workoutLocations.contains(where: { $0.id == id }),
              let fix, WorldSpacePinRules.isGoodEnough(fix, at: date) else { return false }
        do {
            guard try worldSpacePins.pin(for: id) == nil else { return false }
            return try worldSpacePins.setPin(fix.point, for: id)
        } catch {
            FernletAuditLog.log("worldMap.pin.saveFailed")
            return false
        }
    }

    /// The pin of space `id`, or nil when it has none, it cannot be read now, or a decoy is open.
    func worldSpacePin(for id: UUID) -> GeoPoint? {
        guard !duressSessionActive else { return nil }
        do {
            return try worldSpacePins.pin(for: id)
        } catch {
            return nil
        }
    }

    /// The person's space whose pin is within 100 m of `point`, or nil (always nil in a decoy).
    func worldSpace(at point: GeoPoint) -> WorkoutLocation? {
        guard !duressSessionActive else { return nil }
        do {
            guard let id = try worldSpacePins.space(at: point) else { return nil }
            return settings.workoutLocations.first { $0.id == id }
        } catch {
            return nil
        }
    }

    /// Forgets the pin of a deleted space.
    func forgetWorkoutSpacePin(_ id: UUID) {
        do {
            try worldSpacePins.remove(for: id)
        } catch {
            FernletAuditLog.log("worldMap.pin.removeFailed")
        }
    }
}

/// When a reading may pin a workout space (World app plan step 6a): precise, within 50 m, and taken in
/// the last five minutes, so a space is never pinned from an approximate area or a stale reading.
nonisolated enum WorldSpacePinRules {
    /// The worst accuracy a pinning reading may have, in metres.
    static let maxAccuracy = 50.0
    /// The oldest a pinning reading may be.
    static let maxAge: TimeInterval = 5 * 60

    /// Whether `fix` may pin a space at `date`.
    static func isGoodEnough(_ fix: WorldFix, at date: Date) -> Bool {
        let age = date.timeIntervalSince(fix.at)
        return fix.isPrecise && fix.accuracy <= maxAccuracy && age >= -60 && age <= maxAge
    }
}
