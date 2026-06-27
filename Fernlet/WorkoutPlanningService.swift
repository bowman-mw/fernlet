import Foundation
import AIContext
import AIProviders
import FernletFoundation
import FernletDomainModel
import HealthKitGateway

/// Read-side context the workout planner needs from the app store. Mirrors the
/// `WorkoutSyncContext` host-protocol pattern so `WorkoutPlanningService` depends on
/// this seam rather than the concrete `FernletStore` (plan §5d).
@MainActor
protocol WorkoutPlanningContext: AnyObject {
    var settings: FernletSettings { get }
    var day: FernletDay { get }
    var todayKey: String { get }
    func loadDays() -> [String: FernletDay]
}

/// Workout split recommendation + day-plan generation + AI day-plan adjustment,
/// extracted from `FernletStore` (plan §5d). Owns the FoundationModels workout
/// adjustment dependency, keeping it off the store/core path. Pure given its
/// context inputs; the store keeps thin delegating wrappers so call sites are
/// unchanged.
@MainActor
final class WorkoutPlanningService {
    private unowned let host: any WorkoutPlanningContext

    init(host: any WorkoutPlanningContext) {
        self.host = host
    }

    /// How consistently the user has trained over the last 4 weeks — a recommendation input.
    func workoutConsistency() -> WorkoutConsistency {
        let history = host.loadDays()
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
        WorkoutSplitRecommender.ranked(
            goal: host.settings.selectedGoal,
            experience: host.settings.workoutProfile.experience,
            consistency: workoutConsistency(),
            activity: host.settings.userProfile.activityLevel,
            preferredDays: host.settings.workoutProfile.trainingDaysPerWeek
        )
    }

    /// The user's chosen split, or the top recommendation when on auto.
    func activeWorkoutSplit() -> TrainingSplit {
        if let id = host.settings.workoutProfile.selectedSplitID,
           let chosen = WorkoutSplitCatalog.all.first(where: { $0.id == id }) {
            return chosen
        }
        return recommendedSplits().first ?? WorkoutSplitCatalog.fallback
    }

    /// Builds today's session(s) from the active split, rotating by weekday so the program is
    /// consistent week to week. Equipment + injuries are applied deterministically by the engine,
    /// and reps/sets reflect logged progression.
    func workoutDayPlan(intensity: WorkoutIntensity, context: String) -> WorkoutProgram.DayPlan {
        let rotation = Calendar.current.component(.weekday, from: Date())
        return WorkoutProgram.dayPlan(
            goal: host.settings.selectedGoal,
            intensity: intensity,
            profile: host.settings.workoutProfile,
            location: host.settings.activeWorkoutLocation,
            context: context,
            split: activeWorkoutSplit(),
            rotationIndex: rotation,
            progression: host.settings.workoutProgression
        )
    }

    /// Applies a natural-language adjustment to a generated day plan using on-device Foundation
    /// Models, constrained to the equipment/injury-filtered catalog. Returns the plan unchanged when
    /// AI is off/unavailable or the request is empty.
    func adjustWorkoutDayPlan(_ plan: WorkoutProgram.DayPlan, request: String) async -> WorkoutProgram.DayPlan {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, host.settings.aiStatus != .off else { return plan }
        let location = host.settings.activeWorkoutLocation
        let profile = host.settings.workoutProfile

        var sessions = plan.sessions
        for index in sessions.indices {
            let session = sessions[index]
            guard session.kind == .strength || session.kind == .fullBody || session.kind == .sport else { continue }
            let currentNames = session.catalogExerciseNames
            let candidates = WorkoutAdjustmentCandidateBuilder.candidates(
                currentNames: currentNames, request: trimmed, location: location, profile: profile
            )
            guard candidates.isEmpty == false else { continue }
            let payload = WorkoutAdjustmentPayload(request: trimmed, currentExercises: currentNames, candidateCount: candidates.count)
            do {
                if let adjusted = try await FoundationWorkoutAdjustmentModel.adjust(
                    payload, candidates: candidates, currentLines: session.exercises.map(\.line)
                ) {
                    sessions[index] = WorkoutProgram.applyAdjustment(to: session, exercises: adjusted)
                }
            } catch {}
        }
        return WorkoutProgram.DayPlan(
            splitName: plan.splitName, dayTitle: plan.dayTitle, sessions: sessions,
            droppedSlots: plan.droppedSlots, locationName: plan.locationName
        )
    }
}
