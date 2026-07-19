// WorkoutLiveActivityController.swift
// Fernlet (app target only — requests / updates / ends the workout Live Activity).
//
// A thin @MainActor wrapper over ActivityKit for the guided-workout rest timer. The activity's
// lifetime equals a GuidedWorkoutSheet's lifetime: `start` on the first working set, `update` on each
// set/exercise transition, `end` on natural finish, abandon, or sheet dismissal. The rest COUNTDOWN
// ticks natively in the widget via `Text(timerInterval:)`, so there is NO time-based update path and
// NO push/APNs — only discrete transitions call `update`.
//
// Degrades to in-app-only SILENTLY when Live Activities are disabled (no alert, no log spam — the
// in-app sheet is the full experience). One active workout activity at a time.

import ActivityKit
import Foundation
import FernletDomainModel

@MainActor
final class WorkoutLiveActivityController {
    private var activity: Activity<WorkoutActivityAttributes>?

    /// Begin a Live Activity for a workout. No-op (in-app-only) when the user hasn't enabled Live
    /// Activities. Ends any activity already live — this controller's own and any stray from a prior
    /// run — so only one workout activity is ever on screen.
    func start(title: String, state: WorkoutActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endAllActive()

        let attributes = WorkoutActivityAttributes(workoutTitle: title)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
        } catch {
            // Silent degrade: the in-app sheet remains the experience.
            activity = nil
        }
    }

    /// Push a fresh snapshot on a set/exercise transition. No-op if nothing is live.
    func update(state: WorkoutActivityAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// End the activity with a brief final state and dismiss the Lock Screen card immediately, so no
    /// stale workout card lingers. No-op if nothing is live (safe to call twice / from onDisappear).
    func end(final: WorkoutActivityAttributes.ContentState) {
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(
                ActivityContent(state: final, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
    }

    private func endAllActive() {
        activity = nil
        for stale in Activity<WorkoutActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Launch reconciliation for the killed-app case: the runner's state is @State inside a sheet and
    /// cannot survive relaunch, so any activity still on screen is orphaned — end them all. Called
    /// once from the launch preparation seam.
    static func endStaleActivities() {
        for stale in Activity<WorkoutActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

// MARK: - Pure mapping: runner → Live Activity content

extension WorkoutActivityAttributes.ContentState {
    /// Snapshot the runner's public state into the Live Activity content. Pure and total (no clock, no
    /// side effects), so the mapping is unit-testable. The four-case runner phase collapses to the
    /// two-case activity phase: only `.resting` shows the countdown; every other phase renders as
    /// `.working` (the activity is never on screen in `.ready`, and `.done` is followed immediately by
    /// an `end`, so its rendered phase is moot). `totalSets` uses the runner's `max(1, …)` clamp so a
    /// cardio line (`sets == 0`) reads as one step, not zero.
    init(runner: WorkoutSessionRunner) {
        self.init(
            exerciseName: runner.currentExercise?.name ?? "",
            setNumber: runner.currentSet,
            totalSets: runner.totalSetsForCurrent,
            reps: runner.currentExercise?.reps ?? "",
            phase: runner.phase == .resting ? .resting : .working,
            restStartedAt: runner.restStartedAt,
            restEndsAt: runner.restEndsAt,
            exerciseIndex: runner.exerciseIndex,
            totalExercises: runner.totalExercises
        )
    }
}
