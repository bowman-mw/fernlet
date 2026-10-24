import Foundation
import FernletDomainModel
import FernletFoundation
import WorldMapStore

/// Walks and runs on the World map (World build, branch `world-ui`; World app plan step 5b, runs since step 5c). The
/// quick start's Walk together (step 6b) and a saved run route again start and end one; this is everything between.
///
/// - **Start:** the recorder starts, and location keeps running for the walk (``WorldLocationSource``'s
///   walk mode: precise for this walk only, and in the background while it records).
/// - **End:** the walk is logged as a walking activity through ``addWorkout(_:)``, so it reaches Move,
///   the silly stats and Health exactly as a hand-logged walk does, with only its duration and distance.
///   When "Save new routes" is on (``WorldMapPreferences``) and no decoy is open, its line is sealed on
///   this iPhone under the workout's id (``WorldRouteStore``). The fog has already lifted along it, reading
///   by reading.
/// - **Delete:** removing the workout removes its line (`removeWorkout(id:date:)`).
///
/// A decoy session can walk, and the walk is logged as the decoy logs anything, but no line is kept and
/// no line is read (``worldRoute(for:)``).
extension FernletStore {
    /// Starts recording a walk (or, from a saved run route, a run) at `date`; a no-op while one is already
    /// running.
    func startWorldWalk(at date: Date = Date(), kind: WorldWalkRecorder.Kind = .walk) {
        guard !worldWalk.isRecording else { return }
        worldWalk.start(at: date, kind: kind)
        worldLocation.startWalk()
    }

    /// Ends the walk at `date`: logs it as a walking (or running) workout, puts it on Where you've been's
    /// timeline, and keeps its line when allowed. The logged workout, or nil when no walk was running.
    @discardableResult
    func finishWorldWalk(at date: Date = Date(), defaults: UserDefaults = .standard) -> Workout? {
        worldLocation.stopWalk()
        guard let walk = worldWalk.finish(at: date) else { return nil }
        let workout = Self.walkWorkout(walk)
        addWorkout(workout, date: FernletDate.dayKey(for: walk.ended))
        worldPlaces.recordOuting(walk.kind == .run ? .run : .walk, at: walk.started, metres: walk.metres, workoutID: workout.id)
        guard WorldMapPreferences.saveNewRoutes(in: defaults), !duressSessionActive, walk.points.count >= 2 else {
            return workout
        }
        do {
            try worldRoutes.save(walk.points, for: workout.id)
        } catch {
            // The workout is logged either way; a line that could not be sealed (the phone locked at the
            // wrong moment) is simply not kept.
            FernletAuditLog.log("worldMap.route.saveFailed")
        }
        return workout
    }

    /// The saved line of workout `id`, or nil when it has none, it cannot be read now, or a decoy is open.
    func worldRoute(for id: UUID) -> [RoutePoint]? {
        guard !duressSessionActive else { return nil }
        do {
            return try worldRoutes.route(for: id)
        } catch {
            return nil
        }
    }

    /// A finished walk as Move logs a walk: a light walking activity under the activity's frozen default
    /// name (drawn in the person's language), with its minutes and its distance in miles, ending when it
    /// ended.
    static func walkWorkout(_ walk: WorldWalkRecorder.Walk) -> Workout {
        let activity: WorkoutActivityType = walk.kind == .run ? .running : .walking
        return Workout(name: activity.defaultName, type: .cardio, mode: .activity, activityType: activity,
                       exercises: "", rpe: nil, notes: "", duration: walk.minutes, distanceMiles: walk.metres / 1_609.344,
                       intensity: walk.kind == .run ? .moderate : .light, completedAt: walk.ended, loggedAt: walk.ended)
    }
}
