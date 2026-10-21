import Foundation
import AIContext
import AIProviders
import FernletFoundation
import FernletDomainModel
import HealthKitGateway

/// Read-side context the workout planner needs from the app store.
///
/// Mirrors the `WorkoutSyncContext` host-protocol pattern so ``WorkoutPlanningService`` depends on
/// this seam rather than the concrete ``FernletStore`` (plan §5d). `@MainActor` and class-bound so
/// the service can hold its host `unowned`; ``FernletStore`` is the production conformer.
@MainActor
protocol WorkoutPlanningContext: AnyObject {
    var settings: FernletSettings { get }
    /// The body profile in effect on this device (typed, with this device's Health import laid over
    /// it), for the load pass's expected strength curve.
    var effectiveUserProfile: UserNutritionProfile { get }
    var day: FernletDay { get }
    var todayKey: String { get }
    func loadDays() -> [String: FernletDay]
    /// Routes the on-device workout-adjustment model call through the provider ladder (capability cap
    /// + device-local quota + audit). Rebuilt per read so a mid-session AI-toggle is reflected.
    var aiGate: FernletAIGate { get }
    /// The intensity today's committed guided plan was built with, nil when none is committed today —
    /// an adjusted session gets its warm-up ramp back only when it isn't a light day.
    var committedGuidedIntensity: WorkoutIntensity? { get }
}

/// Workout split recommendation + day-plan generation + AI day-plan adjustment,
/// extracted from ``FernletStore`` (plan §5d).
///
/// Owns the FoundationModels workout-adjustment dependency, keeping it off the store/core path.
/// Pure given its context inputs; the store keeps thin delegating wrappers so call sites are
/// unchanged. `@MainActor` like its host, which it holds `unowned` — the store owns the service,
/// never the reverse. Generation is deterministic (split rotation by the last logged split day,
/// equipment/injury filtering, logged progression); only ``adjustWorkoutDayPlan(_:request:)``
/// touches AI, and it degrades to the unchanged plan on an empty request, AI-off, or any model
/// failure.
@MainActor
final class WorkoutPlanningService {
    /// The read-side seam into app state — `unowned` because the host (``FernletStore``) owns this
    /// service for its whole lifetime.
    private unowned let host: any WorkoutPlanningContext

    /// - Parameter host: The context provider (in production, ``FernletStore``); held `unowned`
    ///   because the host owns this service.
    init(host: any WorkoutPlanningContext) {
        self.host = host
    }

    /// How consistently the user has trained over the last 4 weeks — a recommendation input.
    func workoutConsistency() -> WorkoutConsistency {
        workoutConsistency(history: host.loadDays())
    }

    /// ``workoutConsistency()`` over an already-loaded history, so one plan build loads it once.
    private func workoutConsistency(history: [String: FernletDay]) -> WorkoutConsistency {
        let calendar = Calendar.current
        let today = Date()
        var daysWithWorkout = 0
        for offset in 0..<28 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = FernletDate.dayKey(for: date)
            let dayRecord = (key == host.todayKey) ? host.day : history[key]
            if let dayRecord, dayRecord.workouts.isEmpty == false { daysWithWorkout += 1 }
        }
        let perWeek = Double(daysWithWorkout) / 4.0
        if perWeek >= 3.5 { return .high }
        if perWeek >= 1.5 { return .medium }
        return .low
    }

    /// Splits ranked for this user (goal + activity level + consistency + preferred days).
    func recommendedSplits() -> [TrainingSplit] {
        recommendedSplits(history: host.loadDays())
    }

    private func recommendedSplits(history: [String: FernletDay]) -> [TrainingSplit] {
        WorkoutSplitRecommender.ranked(
            goal: host.settings.selectedGoal,
            experience: host.settings.workoutProfile.experience,
            consistency: workoutConsistency(history: history),
            activity: host.settings.userProfile.activityLevel,
            preferredDays: host.settings.workoutProfile.trainingDaysPerWeek
        )
    }

    /// The user's chosen split, or the top recommendation when on auto.
    func activeWorkoutSplit() -> TrainingSplit {
        activeWorkoutSplit(history: host.loadDays())
    }

    private func activeWorkoutSplit(history: [String: FernletDay]) -> TrainingSplit {
        if let id = host.settings.workoutProfile.selectedSplitID,
           let chosen = WorkoutSplitCatalog.all.first(where: { $0.id == id }) {
            return chosen
        }
        return recommendedSplits(history: history).first ?? WorkoutSplitCatalog.fallback
    }

    /// Builds today's session(s) from the active split: the day after the last split day the user
    /// logged (``WorkoutProgram/nextDayIndex(in:recentSessionNames:)``), so every session comes
    /// round in turn whichever weekdays they train. Equipment + injuries are applied
    /// deterministically by the engine; sets, reps and weight ranges follow each lift's logged
    /// sessions (``WorkoutLoadContextBuilder``), with plateau handling and the monthly calibration.
    /// The 48-hour guard reads the same history (``WorkoutRecentTrainingBuilder``): it moves to a
    /// split day that spares muscles worked hard yesterday, or lightens the lifts that would repeat
    /// them. Each session is shaped by Workout setup's session options — the warm-up and cool-down
    /// switches and the time budget it is fitted into — with `sessionLength`, when given, standing in
    /// for the setup's length for this plan only. Hidden exercises are never suggested and saved
    /// alternates are preferred where they fit (``WorkoutExercisePreferences``).
    func workoutDayPlan(
        intensity: WorkoutIntensity, context: String, sessionLength: WorkoutSessionLength? = nil
    ) -> WorkoutProgram.DayPlan {
        let history = host.loadDays()
        var options = host.settings.workoutSessionOptions
        if let sessionLength { options.length = sessionLength }
        let split = activeWorkoutSplit(history: history)
        let rotation = WorkoutProgram.nextDayIndex(
            in: split, recentSessionNames: recentWorkoutNamesByDay(history: history)
        )
        let load = WorkoutLoadContextBuilder.build(
            days: history, today: host.day, todayKey: host.todayKey, settings: host.settings,
            body: host.effectiveUserProfile
        )
        return WorkoutProgram.dayPlan(
            goal: host.settings.selectedGoal,
            intensity: intensity,
            profile: host.settings.workoutProfile,
            location: host.settings.activeWorkoutLocation,
            context: context,
            split: split,
            rotationIndex: rotation,
            progression: host.settings.workoutProgression,
            load: load,
            recent: WorkoutRecentTrainingBuilder.build(days: history, todayKey: host.todayKey),
            options: options,
            preferences: host.settings.workoutExercisePreferences
        )
    }

    /// Logged workout names per past day, most recent first, over the rotation lookback — days
    /// before today only, so today's plan does not move once its own session is logged.
    private func recentWorkoutNamesByDay(history: [String: FernletDay]) -> [[String]] {
        let calendar = Calendar.current
        let today = Date()
        var days: [[String]] = []
        for offset in 1...WorkoutProgram.rotationLookbackDays {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            guard let record = history[FernletDate.dayKey(for: date)], !record.workouts.isEmpty else { continue }
            days.append(record.workouts.map(\.name))
        }
        return days
    }

    /// The descriptor line of the rest-day plan. A `" - N min"` tail, because a mobility session's
    /// logged duration is parsed from its descriptor (`WorkoutProgram.descriptorMinutes(in:)`).
    nonisolated static let restDayMovementLine = "Gentle stretching or an easy walk - 10 min"

    /// The plan for a day whose readiness is `"needs rest"` (spec §6a: marking today unwell forces
    /// it): no split session, no sets, nothing to guide — one gentle movement line, framed as
    /// optional.
    ///
    /// A single `.mobility` session whose only exercise is a non-catalog descriptor (`sets == 0`), so
    /// `GuidedWorkoutAvailability.isGuidable` is false: the Move root card settles on its "easy
    /// movement" state instead of offering "Start today's workout", and "Already did this — log it"
    /// still logs it (at light intensity) if the user did move. The names and the movement line are
    /// frozen English, like every generated plan's (a logged row is saved under the name, and the line
    /// is parsed for its minutes); screens draw them through `WorkoutSessionNames`,
    /// `WorkoutProgram.DayPlan.displayedSplitName` and `WorkoutPlanLine`. The note is localized.
    nonisolated static func restDayPlan(locationName: String) -> WorkoutProgram.DayPlan {
        let suggestion = WorkoutSuggestion(
            name: "Gentle movement",
            exercises: restDayMovementLine,
            notes: WorkoutPlannerCopy.restDayNote
        )
        let session = WorkoutProgram.SessionSuggestion(
            title: "Rest",
            timeLabel: "",
            kind: .mobility,
            exercises: [PrescribedExercise(name: restDayMovementLine, sets: 0, reps: "", role: .accessory, fromCatalog: false)],
            suggestion: suggestion
        )
        return WorkoutProgram.DayPlan(
            splitName: TrainingSplit.restDayName, dayTitle: "Rest", sessions: [session], droppedSlots: [],
            locationName: locationName
        )
    }

    /// Applies a natural-language adjustment to a generated day plan using on-device Foundation
    /// Models, constrained to the equipment/injury-filtered catalog. Returns the plan unchanged when
    /// AI is off/unavailable or the request is empty.
    ///
    /// An adjusted session's lifting block is loaded again (``WorkoutAdjustedLoad``): suggested
    /// weights from each lift's history, the fatigue context, and the warm-up ramp before the first
    /// heavy main lift. The time budget is not applied again.
    func adjustWorkoutDayPlan(_ plan: WorkoutProgram.DayPlan, request: String) async -> WorkoutProgram.DayPlan {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, host.settings.aiStatus != .off else { return plan }
        let location = host.settings.activeWorkoutLocation
        let profile = host.settings.workoutProfile
        let load = WorkoutLoadContextBuilder.build(
            days: host.loadDays(), today: host.day, todayKey: host.todayKey, settings: host.settings
        )
        let intensity = host.committedGuidedIntensity
        // Hidden exercises ("Don't suggest this") never reach the model's candidate list.
        let preferences = host.settings.workoutExercisePreferences
        // User-invoked adjustment (the person typed a request and tapped): routes through the store's
        // AI gate at `standard` tier so the sleepy/resting budget + one-call-per-dispatch charge apply.
        let gate = host.aiGate

        var sessions = plan.sessions
        for index in sessions.indices {
            let session = sessions[index]
            guard session.kind == .strength || session.kind == .fullBody || session.kind == .sport else { continue }
            let currentNames = session.catalogExerciseNames
            let candidates = WorkoutAdjustmentCandidateBuilder.candidates(
                currentNames: currentNames, request: trimmed, location: location, profile: profile,
                preferences: preferences
            )
            guard candidates.isEmpty == false else { continue }
            let payload = WorkoutAdjustmentPayload(request: trimmed, currentExercises: currentNames, candidateCount: candidates.count)
            do {
                if let adjusted = try await FoundationWorkoutAdjustmentModel.adjust(
                    payload, candidates: candidates,
                    currentLines: session.exercises.filter { $0.block == .lifting }.map(\.line), gate: gate
                ) {
                    sessions[index] = WorkoutAdjustedLoad.reload(
                        WorkoutProgram.applyAdjustment(to: session, exercises: adjusted), original: session,
                        location: location, load: load, intensity: intensity
                    )
                }
            } catch {
                // Degrade, don't fail: this session keeps its generated exercises. Named so a plan
                // that "adjusted" into nothing leaves a trace instead of a silent no-op.
                FernletAuditLog.log("workout.adjust.modelFailed", context: [
                    "session": session.kind.rawValue,
                    "error": String(describing: type(of: error)),
                ])
            }
        }
        return WorkoutProgram.DayPlan(
            splitName: plan.splitName, dayTitle: plan.dayTitle, sessions: sessions,
            droppedSlots: plan.droppedSlots, locationName: plan.locationName, recovery: plan.recovery
        )
    }
}
