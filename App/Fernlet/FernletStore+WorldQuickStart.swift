import Foundation
import FernletConnections
import FernletDomainModel
import FernletFoundation
import FernletSocial
import ProximityKit
import WorldMapStore

/// The blue quick-start button's reading of the store, and what its choices do (World build, branch
/// `world-ui`; World app plan step 6b; designs `b1-qs-*` and `b3-qs-*`). The rules themselves are
/// ``WorldQuickStart``'s, on plain values.
///
/// Everything here is read on this iPhone: the space match is the person's own pins within 100 m (the
/// map's markers, ``worldSpaceMarkers(near:)``, matched by ``WorldMapMarker/space(near:in:)``), the plan
/// is today's, the session is the one running. Nothing is asked for and nothing leaves the phone; there
/// are no badges, buzzes or notifications on arrival.
extension FernletStore {
    /// What the blue button sees now. `spaceID` is the person's space they stand at (or whose marker they
    /// tapped), nil for none; `includingPlans` also builds today's plan preview (for the gentle stretch),
    /// which the card needs and the button's icon does not.
    func worldQuickStartContext(spaceID: UUID?, includingPlans: Bool) -> WorldQuickStartContext {
        var context = WorldQuickStartContext()
        context.canWalk = worldWalkIsAvailable
        context.isDecoy = duressSessionActive
        context.isResting = needsRestToday || isSick(on: todayKey)
        if let spaceID, !duressSessionActive, let location = settings.workoutLocations.first(where: { $0.id == spaceID }) {
            context.space = Self.quickStartSpace(location)
        }
        context.plannedSession = todaysPlannedGuidedSession?.displayedName
        context.session = quickStartSession
        context.activity = quickStartActivity
        // Take a trip (World-Airports-Spec §7): the airport's card, and the trip row (`FernletStore+WorldTrip`).
        context.airportName = worldQuickStartAirportName
        context.tripOption = worldQuickStartTripOption
        context.soloCameraAvailable = WorldDisposableCamera.soloIsAvailable
        context.canMeetFriends = worldCanMeetFriends
        context.nearbyFriends = worldNearbyFriends.map(\.firstName)
        if includingPlans, context.isResting {
            context.hasGentleStretch = todaysGentleStretch(committing: false) != nil
        }
        return context
    }

    /// Whether friends in person are offered on Home at all (`b4-mem-blue-*`): never in a decoy, below
    /// the minimum age, or while Delete everything runs — the proximity radios' own hard stops
    /// (`ProximityRunPolicy.isHardStop`), so the blue button never offers what the radios refuse.
    var worldCanMeetFriends: Bool {
        !duressSessionActive && !deleteAllInProgress && !ProximityRunPolicy.belowMinimumAge(ageAssurance.record)
    }

    /// Whether Walk together can be offered: location already allowed (nothing on Home asks), and a
    /// walk that can be precise. Until the temporary-accuracy purpose ships (plan step 5c), a walk with
    /// approximate location would draw no line and count no distance, so it is not offered.
    var worldWalkIsAvailable: Bool {
        let location = worldLocation
        guard location.permission == .whileUsing || location.permission == .always else { return false }
        return location.isPrecise || WorldLocationSource.declares("NSLocationTemporaryUsageDescriptionDictionary")
    }

    /// The most recent saved line that starts within 100 m of `point`, among the walks and runs of the
    /// last ``worldSavedLineDays`` days (at most ``worldSavedLineWalksPerDay`` a day), with how many walks
    /// (or runs, for a run's line) started there. A run's line makes a saved run route (`b1-qs-run`), a
    /// walk's a trail (`b1-qs-trail`). Read on this iPhone only; nil in a decoy, and nil when none starts here.
    func worldSavedLine(startingNear point: GeoPoint, now: Date = Date()) -> WorldSavedLine? {
        guard !duressSessionActive, point.isValid else { return nil }
        var latest: WorldSavedLine?
        var counts: [WorldWalkRecorder.Kind: Int] = [:]
        for offset in 0..<Self.worldSavedLineDays {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { continue }
            let key = FernletDate.dayKey(for: date)
            let recent = (key == todayKey ? day : loadDay(for: key)).workouts
                .filter { Self.savedLineKind(of: $0) != nil }
                .sorted { $0.completedAt > $1.completedAt }
                .prefix(Self.worldSavedLineWalksPerDay)
            for outing in recent {
                guard let kind = Self.savedLineKind(of: outing), let line = worldRoute(for: outing.id), let start = line.first,
                      start.point.distance(to: point) <= SpacePinStore.matchRadius else { continue }
                counts[kind, default: 0] += 1
                if latest == nil {
                    latest = WorldSavedLine(workoutID: outing.id, points: line.map(\.point), metres: WorldRouteCodec.length(of: line),
                                            walks: 0, kind: kind)
                }
            }
        }
        return latest.map { WorldSavedLine(workoutID: $0.workoutID, points: $0.points, metres: $0.metres,
                                           walks: counts[$0.kind, default: 0], kind: $0.kind) }
    }

    /// Whether `workout`'s saved line is a walk's (walking, hiking) or a run's, or neither.
    static func savedLineKind(of workout: Workout) -> WorldWalkRecorder.Kind? {
        switch workout.activityType {
        case .walking, .hiking: .walk
        case .running: .run
        default: nil
        }
    }

    /// How many days back the saved-line search reads.
    static let worldSavedLineDays = 30
    /// How many walks a day it reads, newest first.
    static let worldSavedLineWalksPerDay = 5

    /// A space as the card draws it.
    static func quickStartSpace(_ location: WorkoutLocation) -> WorldQuickStartContext.Space {
        WorldQuickStartContext.Space(id: location.id, name: location.displayedName,
                                     equipment: WorkoutLocationSetupView.equipmentSummary(location),
                                     itemCount: location.ownedEquipment.count)
    }

    /// Today's approved plan's next guided session, when there is one to start.
    var todaysPlannedGuidedSession: WorkoutProgram.SessionSuggestion? {
        guard isTodaysGuidedPlanApproved, let plan = currentGuidedWorkoutPlan else { return nil }
        return GuidedWorkoutAvailability.firstGuidable(in: plan, excluding: guidedCompletedSessionIDs,
                                                       loggedGuidedWorkoutNames: loggedGuidedWorkoutNamesToday)
    }

    /// Today's rest plan's gentle stretch while it is still to do. `committing` commits today's plan
    /// first (starting it needs the committed session's id), as Move's Suggest sheet does.
    func todaysGentleStretch(committing: Bool) -> WorkoutProgram.SessionSuggestion? {
        let intensity = recommendedWorkoutIntensity() ?? .moderate
        let plan = committing ? commitTodaysGuidedWorkoutPlan(intensity: intensity)
                              : previewTodaysGuidedWorkoutPlan(intensity: intensity)
        return GuidedWorkoutAvailability.optionalStretch(in: plan, excluding: guidedCompletedSessionIDs,
                                                         loggedGuidedWorkoutNames: loggedGuidedWorkoutNamesToday)
    }

    /// The friend session running now: the others' first names and the film left.
    private var quickStartSession: WorldQuickStartContext.Session? {
        let mesh = meshNetworkManager
        guard mesh.isInSession, !duressSessionActive else { return nil }
        let names = mesh.sessionParticipants.filter { !$0.isLocal }.prefix(Self.quickStartMaxNames).map {
            PeerNameDisplay.firstName($0.displayName, fingerprint: $0.fingerprint, placeholder: .met, in: .fernlet)
        }
        return WorldQuickStartContext.Session(names: Array(names), shotsLeft: meshFeatures.photos.filmRemaining)
    }

    /// The most names the card's heading lists.
    static let quickStartMaxNames = 3

    /// What is under way: a walk recording, or a guided workout working or resting.
    private var quickStartActivity: WorldQuickStartContext.Activity {
        if worldLocation.isWalking { return worldWalk.kind == .run ? .running : .walking }
        if let run = guidedRunState, run.isWorking || run.isResting {
            return .workout(title: WorkoutSessionNames.drawn(run.title))
        }
        return .none
    }

    /// Today's plan at `spaceID`: makes the space the active one and returns the session to guide,
    /// committing today's plan first, as Move's "Start today's workout" does. Nil when nothing is left
    /// to guide.
    func startTodaysPlan(at spaceID: UUID) -> WorkoutProgram.SessionSuggestion? {
        if settings.activeWorkoutLocationID != spaceID { setActiveWorkoutLocation(spaceID) }
        let plan = commitTodaysGuidedWorkoutPlan(intensity: recommendedWorkoutIntensity() ?? .moderate)
        return GuidedWorkoutAvailability.firstGuidable(in: plan, excluding: guidedCompletedSessionIDs,
                                                       loggedGuidedWorkoutNames: loggedGuidedWorkoutNamesToday)
    }

    /// Whether other sessions of today's plan still need doing after `session` (the runner's done copy
    /// names what was logged then), checked as Move's runner presenter checks it.
    func worldGuidedSessionsRemain(after session: WorkoutProgram.SessionSuggestion) -> Bool {
        guard !isPlannedRun(session), let plan = currentGuidedWorkoutPlan else { return false }
        return plan.sessions.contains {
            $0.id != session.id && !GuidedWorkoutAvailability.isAlreadyLogged(
                $0, completed: guidedCompletedSessionIDs, loggedGuidedWorkoutNames: loggedGuidedWorkoutNamesToday)
        }
    }

    /// Prepares Move's "Suggest today's workout" for `spaceID`: that space becomes the active one, so
    /// the suggestion is built from its equipment.
    func prepareSuggestion(at spaceID: UUID) {
        if settings.activeWorkoutLocationID != spaceID { setActiveWorkoutLocation(spaceID) }
    }

    /// Ends the walk from the walk bar's End, for its toast (`b1-home-walk`): logs it as a walking
    /// workout and keeps its line when allowed (``finishWorldWalk(at:defaults:)``), and saves the fog it
    /// lifted. **A decoy's walk leaves nothing behind**: no workout, no line, no fog; its toast reads the
    /// same, so nothing hints at a decoy. Nil when no walk was recording.
    func endWorldWalk(at date: Date = Date(), defaults: UserDefaults = .standard) -> WorldLoggedWalk? {
        if duressSessionActive {
            worldLocation.stopWalk()
            guard let walk = worldWalk.finish(at: date) else { return nil }
            return WorldLoggedWalk(id: UUID(), dayKey: todayKey, metres: walk.metres, minutes: walk.minutes, isKept: false,
                                   kind: walk.kind)
        }
        guard let workout = finishWorldWalk(at: date, defaults: defaults) else { return nil }
        // What it was logged as: Walk or run together's pace decides only as it ends.
        let kind: WorldWalkRecorder.Kind = workout.activityType == .running ? .run : .walk
        worldFog.flush()
        return WorldLoggedWalk(id: workout.id, dayKey: FernletDate.dayKey(for: workout.completedAt),
                               metres: (workout.distanceMiles ?? 0) * 1_609.344, minutes: workout.duration ?? 1, isKept: true,
                               kind: kind)
    }

    /// The walk toast's Undo: removes the logged walk (and its line with it). Whether it went.
    func undoWorldWalk(_ walk: WorldLoggedWalk) -> Bool {
        guard walk.isKept else { return false }
        return removeWorkout(id: walk.id, date: walk.dayKey)
    }
}
