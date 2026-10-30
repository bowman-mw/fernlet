import FernletDomainModel
import FernletFoundation
import Foundation
import WorldMapStore

/// Car and bike detection's side of the store (round 7; `b1-home-car`, `b1-home-bike`): the map's
/// ``WorldRideKeeper`` (`worldLocation.rides`) wired to the fog, the location source and the workout log.
///
/// - **Bike rides log as exercise** (``logWorldBikeRide(_:defaults:)``): an outdoor cycling activity with its
///   minutes and, when the readings gave one, its distance, exactly as a hand-logged ride reaches Move, the
///   silly stats and Health. Only while "Log my bike rides" is on; a decoy logs nothing, shows no note and
///   leaves the motion history's checkpoint where it was.
/// - **The checkpoint** (``WorldMapPreferences/bikeRidesCheckedThrough(in:)``): turning the switch on starts
///   it at that moment, each logged ride moves it to the ride's end, and a catch-up moves it to now, so a
///   ride is logged once and never one from before the switch was on.
/// - **Catch-up** (``catchUpWorldBikeRides(now:defaults:)``): the rides the motion history holds from while
///   the app was closed, at most ``bikeRideCatchUpLimit`` back.
/// - **The ride's line and timeline stop** (Refinements group 19, `ref-ride-line`, `ref-ride-timeline`): a
///   logged ride joins Where you've been's timeline at its start, and its line is kept with its workout when
///   "Save new routes" is on, exactly as a walk's; a ride the catch-up found has no line. A decoy keeps
///   neither (it logs nothing).
/// - **Undo** removes the workout, its line and its timeline stop (``undoWorldBikeRide(_:)``); with Private
///   locked, a stop it already folded leaves at its next fold.
/// - **Car rides never log as exercise.**
extension FernletStore {
    /// How far back a catch-up looks through the motion history (iOS keeps a week).
    static let bikeRideCatchUpLimit: TimeInterval = 72 * 60 * 60
    /// The most rides one catch-up logs (a bound; three days hold far fewer).
    static let maxCaughtUpRides = 64

    /// Wires the ride keeper's callbacks to the store and reads Motion only when allowed: "Log my bike
    /// rides" on, Motion & Fitness allowed, no decoy. Safe to call more than once (each front edge does).
    func wireWorldRides() {
        let rides = worldLocation.rides
        rides.onBikeRide = { [weak self] ride in self?.logWorldBikeRide(ride) }
        rides.usesMotion = worldRidesReadMotion()
    }

    /// Whether the ride keeper may read Motion now.
    func worldRidesReadMotion(defaults: UserDefaults = .standard) -> Bool {
        guard WorldMapPreferences.logsBikeRides(in: defaults), !duressSessionActive else { return false }
        return worldLocation.rides.motion.permission == .allowed
    }

    /// Logs a finished bike ride as an outdoor cycling workout, puts it on Home's note and moves the
    /// checkpoint to its end; nil when nothing was logged ("Log my bike rides" off, a decoy, or a ride that
    /// ended before the checkpoint).
    @discardableResult
    func logWorldBikeRide(_ ride: WorldBikeRide, defaults: UserDefaults = .standard) -> WorldLoggedRide? {
        guard WorldMapPreferences.logsBikeRides(in: defaults), !duressSessionActive else { return nil }
        let checked = WorldMapPreferences.bikeRidesCheckedThrough(in: defaults)
        guard checked.map({ ride.ended > $0 }) ?? true else { return nil }
        let workout = Self.bikeRideWorkout(ride)
        let dayKey = FernletDate.dayKey(for: ride.ended)
        addWorkout(workout, date: dayKey)
        worldPlaces.recordOuting(.ride, at: ride.started, metres: ride.metres, workoutID: workout.id)
        keepWorldRideLine(ride, for: workout.id, defaults: defaults)
        let logged = WorldLoggedRide(id: workout.id, dayKey: dayKey, metres: ride.metres, minutes: ride.minutes, isKept: true)
        worldLocation.rides.loggedRide = logged
        WorldMapPreferences.setBikeRidesCheckedThrough(ride.ended, in: defaults)
        // The outcome's shape only (never a time, a place or a distance), for the device pass.
        FernletAuditLog.log("worldMap.rides.bikeLogged", context: ["distance": ride.metres == nil ? "unknown" : "known"])
        return logged
    }

    /// Turns "Log my bike rides" on (asking for Motion & Fitness) or off; whether it is on afterwards. On only
    /// when Motion is allowed; turning it on starts the motion history's check from `now`, so no ride from
    /// before is logged. Off forgets the checkpoint and stops reading Motion.
    func setWorldBikeRides(_ on: Bool, now: Date = Date(), defaults: UserDefaults = .standard) async -> Bool {
        let rides = worldLocation.rides
        guard on else {
            WorldMapPreferences.setLogsBikeRides(false, in: defaults)
            WorldMapPreferences.setBikeRidesCheckedThrough(nil, in: defaults)
            rides.usesMotion = false
            return false
        }
        let allowed = await rides.motion.requestAccess()
        WorldMapPreferences.setLogsBikeRides(allowed, in: defaults)
        guard allowed else {
            rides.usesMotion = false
            return false
        }
        WorldMapPreferences.setBikeRidesCheckedThrough(now, in: defaults)
        rides.usesMotion = worldRidesReadMotion(defaults: defaults)
        return true
    }

    /// Looks through the motion history since the last check (at most ``bikeRideCatchUpLimit`` back) for
    /// bike rides the map didn't see (the app was closed) and logs each one that started after the
    /// checkpoint; the note shows the newest. The checkpoint then moves to `now`, or to just before a ride
    /// still going, so that ride is found once it ends. Nothing while the switch is off, Motion isn't
    /// allowed, a decoy is open or a ride is on live; the app's front edge calls it.
    func catchUpWorldBikeRides(now: Date = Date(), defaults: UserDefaults = .standard) async {
        let rides = worldLocation.rides
        guard worldRidesReadMotion(defaults: defaults), !rides.isCycling else { return }
        guard let checked = WorldMapPreferences.bikeRidesCheckedThrough(in: defaults), checked < now else {
            WorldMapPreferences.setBikeRidesCheckedThrough(now, in: defaults)
            return
        }
        let samples = await rides.motion.samples(from: max(checked, now.addingTimeInterval(-Self.bikeRideCatchUpLimit)), to: now)
        // The switch, the decoy or a live ride may have changed while the history was read.
        guard worldRidesReadMotion(defaults: defaults), !rides.isCycling,
              WorldMapPreferences.bikeRidesCheckedThrough(in: defaults) == checked else { return }
        let found = WorldRideWatch.rides(in: samples, until: now).filter { $0.started > checked }
        for ride in found.prefix(Self.maxCaughtUpRides) {
            logWorldBikeRide(ride, defaults: defaults)
        }
        let open = WorldRideWatch.openRideStart(in: samples, until: now).map { $0.addingTimeInterval(-1) }
        WorldMapPreferences.setBikeRidesCheckedThrough(max(checked, min(now, open ?? now)), in: defaults)
    }

    /// Keeps a logged ride's line with its workout, exactly as a finished walk's
    /// (`finishWorldWalk(at:defaults:)`): only with "Save new routes" on, no decoy, and at least two points
    /// (a ride the catch-up found has none). A line that can't be sealed now is simply not kept.
    private func keepWorldRideLine(_ ride: WorldBikeRide, for workoutID: UUID, defaults: UserDefaults) {
        guard WorldMapPreferences.saveNewRoutes(in: defaults), !duressSessionActive, ride.points.count >= 2 else { return }
        do {
            try worldRoutes.save(ride.points, for: workoutID)
        } catch {
            FernletAuditLog.log("worldMap.route.saveFailed")
        }
    }

    /// The bike-ride note's Undo: the ride's workout goes, its saved line with it (`removeWorkout(id:date:)`),
    /// and its stop on Where you've been's timeline: the waiting one, or, with Private open, the one already
    /// folded in. Whether the workout was removed.
    @discardableResult
    func undoWorldBikeRide(_ ride: WorldLoggedRide) -> Bool {
        guard ride.isKept else { return false }
        let removed = removeWorkout(id: ride.id, date: ride.dayKey)
        worldPlaces.removeOuting(workoutID: ride.id)
        removeFoldedWorldRide(workoutID: ride.id)
        return removed
    }

    /// Takes a ride's stop off the folded timeline when Private is open (its hub key is at hand); while it is
    /// locked, queues the removal for Private's next fold (owner 2026-10-29). Nothing in a decoy.
    private func removeFoldedWorldRide(workoutID: UUID) {
        guard !duressSessionActive else { return }
        guard let key = hubContentKeyProvider?() else {
            worldPlaces.queueOutingRemoval(workoutID: workoutID)
            return
        }
        do {
            let log = try worldPlaces.store.log(hubKey: key)
            let next = log.deletingOuting(workoutID: workoutID)
            if next != log { try worldPlaces.store.saveLog(next, hubKey: key) }
        } catch {
            worldPlaces.queueOutingRemoval(workoutID: workoutID)
            FernletAuditLog.log("worldMap.places.undoRideDeferred")
        }
    }

    /// How long the bike ride on the timeline (`stop`) lasted, in minutes, from its cycling workout (looked
    /// up by id on the day it started, then the next, for a ride past midnight); nil when the workout is gone
    /// or has no duration, or for any other stop.
    func worldRideMinutes(for stop: PlaceStop) -> Int? {
        guard stop.kind == .ride, let id = stop.workoutID, !duressSessionActive else { return nil }
        let days = [stop.at, stop.at.addingTimeInterval(24 * 60 * 60)]
        for day in days {
            let workout = loadDay(for: FernletDate.dayKey(for: day)).workouts.first { $0.id == id }
            if let workout { return workout.duration }
        }
        return nil
    }

    /// A finished bike ride as Move logs one: a moderate outdoor cycling activity under the activity's frozen
    /// default name (drawn in the person's language), with its minutes and, when known, its distance in miles,
    /// ending when it ended.
    static func bikeRideWorkout(_ ride: WorldBikeRide) -> Workout {
        let activity = WorkoutActivityType.cycling
        return Workout(name: activity.defaultName, type: .cardio, mode: .activity, activityType: activity, exercises: "",
                       rpe: nil, notes: "", duration: ride.minutes, distanceMiles: ride.metres.map { $0 / 1_609.344 },
                       intensity: .moderate, completedAt: ride.ended, loggedAt: ride.ended)
    }
}
