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
    /// The travel days of the planner's lookback, as day keys only (World-Airports-Spec §13.4): a session on
    /// one is forgiven. The composition root's per-day yes/no; never a flight, an airport, a time or a place.
    var workoutTravelDayKeys: Set<String> { get }
    /// The moment a put-off strength check may be offered again, nil when none is put off (w4,
    /// `WorkoutCalibrationDeferral`): the plan offers no check before that day.
    var strengthCheckAskAgainFrom: Date? { get }
    /// Today's committed plan, nil when there is none — the other sessions an adjusted or edited
    /// session may not repeat a lift of.
    var currentGuidedWorkoutPlan: WorkoutProgram.DayPlan? { get }
    /// The intensity, "Anything else?" and chosen length today's committed plan was built with, nil
    /// without a plan: the finishing pass after an adjustment or an edit honours today's note (its
    /// today-only easing and its shorter session) exactly as the plan's own build did.
    var committedGuidedPlanInputs: (intensity: WorkoutIntensity, context: String, sessionLength: WorkoutSessionLength?)? { get }
}

/// The model call behind "Adjust with AI", as the service makes it: the payload, the numbered
/// candidates, the session's current lines and the gate, answered with picks or the reason there are
/// none. Production is the walled on-device stage; a test hands in a double, since the Foundation
/// model never runs in the simulator.
typealias WorkoutAdjuster = @MainActor (
    WorkoutAdjustmentPayload, [WorkoutAdjustmentCandidate], [String], FernletAIGate
) async throws -> WorkoutAdjustmentReply

/// Workout split recommendation + day-plan generation + AI day-plan adjustment,
/// extracted from ``FernletStore`` (plan §5d).
///
/// Owns the FoundationModels workout-adjustment dependency, keeping it off the store/core path.
/// Pure given its context inputs; the store keeps thin delegating wrappers so call sites are
/// unchanged. `@MainActor` like its host, which it holds `unowned` — the store owns the service,
/// never the reverse. Generation is deterministic (split rotation by the last logged split day,
/// equipment/injury filtering, logged progression); only ``adjustWorkoutDayPlan(_:request:)``
/// touches AI, and when it changes nothing — an empty request, AI off, a model failure, a reply
/// that asks for nothing new or would leave too few lifts — it says which
/// (``WorkoutAdjustmentOutcome``). An adjusted session and a session edited by hand both leave
/// through the one finishing pass (`WorkoutPlanFinisher`, ``finishContext()``).
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

    /// Who "Adjust with AI" asks. Production is the walled on-device stage; internal-settable ONLY
    /// so a test can hand in a double.
    var adjuster: WorkoutAdjuster = { payload, candidates, currentLines, gate in
        try await FoundationWorkoutAdjustmentModel.adjust(payload, candidates: candidates, currentLines: currentLines, gate: gate)
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
    /// alternates are preferred where they fit (``WorkoutExercisePreferences``). `context` is the
    /// sheet's "Anything else?", read for this plan only (``WorkoutDayNote``): a time phrase in it
    /// may shorten the session only when no `sessionLength` was chosen on the sheet.
    func workoutDayPlan(
        intensity: WorkoutIntensity, context: String, sessionLength: WorkoutSessionLength? = nil
    ) -> WorkoutProgram.DayPlan {
        let history = host.loadDays()
        var options = host.settings.workoutSessionOptions
        if let sessionLength { options.length = sessionLength }
        let split = activeWorkoutSplit(history: history)
        let recentNames = recentWorkoutNamesByDay(history: history)
        let rotation = WorkoutProgram.nextDayIndex(in: split, recentSessionNames: recentNames)
        let load = WorkoutLoadContextBuilder.build(
            days: history, today: host.day, todayKey: host.todayKey, settings: host.settings,
            body: host.effectiveUserProfile, travelDays: host.workoutTravelDayKeys,
            strengthCheckAskAgainFrom: host.strengthCheckAskAgainFrom
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
            preferences: host.settings.workoutExercisePreferences,
            cardioSeed: WorkoutProgram.cardioSessionsLogged(in: split, recentSessionNames: recentNames),
            noteMayShorten: sessionLength == nil
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

    /// The rest-day line when a walk must not be offered (a severe ankle, knee or hip,
    /// `InjuryLimits.barsWalking`): the same optional gentle stretch, seated, and no walk in its words.
    nonisolated static let restDaySeatedLine = "\(WorkoutTimedSessions.seatedGentleHead) - 10 min"

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
    ///
    /// `limits` are the person's limits today: when they rule a walk out, the line offers seated
    /// stretching instead (``restDaySeatedLine``), as the Travel-day reset does.
    nonisolated static func restDayPlan(locationName: String, limits: InjuryLimits = .empty) -> WorkoutProgram.DayPlan {
        let line = limits.barsWalking ? restDaySeatedLine : restDayMovementLine
        let suggestion = WorkoutSuggestion(
            name: "Gentle movement",
            exercises: line,
            notes: WorkoutPlannerCopy.restDayNote
        )
        let session = WorkoutProgram.SessionSuggestion(
            title: "Rest",
            timeLabel: "",
            kind: .mobility,
            exercises: [PrescribedExercise(name: line, sets: 0, reps: "", role: .accessory, fromCatalog: false)],
            suggestion: suggestion
        )
        return WorkoutProgram.DayPlan(
            splitName: TrainingSplit.restDayName, dayTitle: "Rest", sessions: [session], droppedSlots: [],
            locationName: locationName
        )
    }

    // MARK: - The finishing pass, after an adjustment or an edit

    /// What the finishing pass needs to know about today (`WorkoutPlanFinisher.Context`), built from
    /// the same inputs today's plan was: the split and the day the rotation is on, the lifts' history,
    /// the 48-hour window, Workout setup's session options with the length chosen for this plan, and
    /// today's "Anything else?" — so an adjusted or edited session is eased, trimmed and fitted by the
    /// very rules its plan was built with.
    func finishContext() -> WorkoutPlanFinisher.Context {
        let history = host.loadDays()
        let inputs = host.committedGuidedPlanInputs
        var options = host.settings.workoutSessionOptions
        if let length = inputs?.sessionLength { options.length = length }
        let split = activeWorkoutSplit(history: history)
        let rotation = WorkoutProgram.nextDayIndex(in: split, recentSessionNames: recentWorkoutNamesByDay(history: history))
        let load = WorkoutLoadContextBuilder.build(
            days: history, today: host.day, todayKey: host.todayKey, settings: host.settings,
            body: host.effectiveUserProfile, travelDays: host.workoutTravelDayKeys,
            strengthCheckAskAgainFrom: host.strengthCheckAskAgainFrom
        )
        return WorkoutPlanFinisher.context(
            goal: host.settings.selectedGoal, intensity: inputs?.intensity ?? host.committedGuidedIntensity,
            profile: host.settings.workoutProfile, location: host.settings.activeWorkoutLocation,
            note: inputs?.context ?? "", split: split, rotationIndex: rotation, load: load,
            recent: WorkoutRecentTrainingBuilder.build(days: history, todayKey: host.todayKey),
            options: options, noteMayShorten: inputs?.sessionLength == nil
        )
    }

    /// `context` for one session of `plan`: only the plan's first session carries today's "Anything
    /// else?" lines, so only its note is rebuilt with them.
    private func context(
        _ context: WorkoutPlanFinisher.Context, for session: WorkoutProgram.SessionSuggestion, in plan: WorkoutProgram.DayPlan?
    ) -> WorkoutPlanFinisher.Context {
        guard plan?.sessions.first?.id != session.id else { return context }
        var other = context
        other.todaysLines = []
        return other
    }

    /// A session edited in the plan editor (a swap, an added exercise, a typed number), finished: a
    /// timed movement gets its countdown, a lift swapped in or added is eased for a mild area, loaded
    /// from its history and given a set fewer when its muscles are tired, and the note is rebuilt
    /// from what was done — the time budget's line included, which says how long the session now
    /// runs. The rows are the person's: none is dropped, and no number they kept or typed is changed.
    func finishedSession(
        _ edited: WorkoutProgram.SessionSuggestion, previous: WorkoutProgram.SessionSuggestion
    ) -> WorkoutProgram.SessionSuggestion {
        let plan = host.currentGuidedWorkoutPlan
        let others = (plan?.sessions ?? []).filter { $0.id != previous.id }
        return WorkoutPlanFinisher.finish(edited, previous: previous, others: others, origin: .handEdit,
                                          context: context(finishContext(), for: previous, in: plan))
    }

    // MARK: - Adjust with AI

    /// Applies a natural-language adjustment to a generated day plan using on-device Foundation
    /// Models, constrained to the equipment/injury-filtered catalog — and says what happened
    /// (``WorkoutAdjustmentOutcome``): the adjusted plan, or the reason nothing changed.
    ///
    /// Every adjusted session goes through the finishing pass (`WorkoutPlanFinisher`): what the
    /// request rules out ("no barbell") is enforced in code, a lift that loads a mild area is eased,
    /// tired muscles keep their lighter sets, the session is fitted to its time again, holds get a
    /// countdown, the note is rebuilt, and a reply that would leave too few lifts is refused.
    func adjustWorkoutDayPlan(_ plan: WorkoutProgram.DayPlan, request: String) async -> WorkoutAdjustmentOutcome {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return .unchanged(.nothingNeeded) }
        guard host.settings.aiStatus != .off else { return .unchanged(.aiOff) }
        let finish = finishContext()
        var sessions = plan.sessions
        var reasons: [WorkoutAdjustmentOutcome.Reason] = []
        var changed = false
        for index in sessions.indices.prefix(WorkoutAdjustmentOutcome.maximumSessions)
        where WorkoutPlanFinisher.isLifting(sessions[index]) {
            let session = sessions[index]
            let others = sessions.filter { $0.id != session.id }
            switch await adjusted(session, others: others, request: trimmed, context: context(finish, for: session, in: plan)) {
            case .changed(let finished):
                sessions[index] = finished
                changed = true
            case .unchanged(let reason):
                reasons.append(reason)
            }
        }
        guard changed else { return .unchanged(WorkoutAdjustmentOutcome.Reason.strongest(of: reasons)) }
        return .changed(WorkoutProgram.DayPlan(
            splitName: plan.splitName, dayTitle: plan.dayTitle, sessions: sessions,
            droppedSlots: plan.droppedSlots, locationName: plan.locationName, recovery: plan.recovery
        ))
    }

    /// What one session's adjustment came to.
    private enum SessionAdjustment {
        case changed(WorkoutProgram.SessionSuggestion)
        case unchanged(WorkoutAdjustmentOutcome.Reason)
    }

    /// One session's adjustment: the filtered candidates (today's limits, the space's gear, nothing
    /// hidden, nothing the request rules out), the model's reply, and the finishing pass over it.
    private func adjusted(
        _ session: WorkoutProgram.SessionSuggestion, others: [WorkoutProgram.SessionSuggestion], request: String,
        context: WorkoutPlanFinisher.Context
    ) async -> SessionAdjustment {
        let currentNames = session.catalogExerciseNames
        // Hidden exercises ("Don't suggest this") never reach the model's candidate list.
        let candidates = WorkoutAdjustmentCandidateBuilder.candidates(
            currentNames: currentNames, request: request, location: context.location,
            profile: host.settings.workoutProfile, preferences: host.settings.workoutExercisePreferences,
            limits: context.limits
        )
        guard candidates.isEmpty == false else { return .unchanged(.nothingNeeded) }
        let payload = WorkoutAdjustmentPayload(
            request: request, currentExercises: currentNames, candidateCount: candidates.count,
            promptLanguage: AIPromptLanguage.forApp()
        )
        let lines = session.exercises.filter { $0.block == .lifting }.map(\.line)
        do {
            // User-invoked adjustment (the person typed a request and tapped): routes through the
            // store's AI gate at `standard` tier so the sleepy/resting budget + one-call charge apply.
            switch try await adjuster(payload, candidates, lines, host.aiGate) {
            case .aiOff: return .unchanged(.aiOff)
            case .notNow: return .unchanged(.couldNot)
            case .picks(let picks):
                return finished(session, picks: picks, candidates: candidates, others: others, request: request, context: context)
            }
        } catch {
            // Degrade, don't fail: this session keeps its exercises, and the plan pane says so.
            FernletAuditLog.log("workout.adjust.modelFailed", context: [
                "session": session.kind.rawValue,
                "error": String(describing: type(of: error)),
            ])
            return .unchanged(.couldNot)
        }
    }

    /// The model's picks through the finishing pass, as this session's outcome.
    private func finished(
        _ session: WorkoutProgram.SessionSuggestion, picks: [PrescribedExercise], candidates: [WorkoutAdjustmentCandidate],
        others: [WorkoutProgram.SessionSuggestion], request: String, context: WorkoutPlanFinisher.Context
    ) -> SessionAdjustment {
        let outcome = WorkoutPlanFinisher.adjusted(
            session, picks: picks, request: WorkoutAdjustmentRequest.read(request),
            pool: candidates.map(\.exercise), others: others, context: context
        )
        switch outcome {
        case .changed(let finished): return .changed(finished)
        case .unchanged: return .unchanged(.nothingNeeded)
        case .tooFewLifts:
            FernletAuditLog.log("workout.adjust.refusedTooFewLifts", context: ["session": session.kind.rawValue])
            return .unchanged(.tooFewLifts)
        }
    }
}
