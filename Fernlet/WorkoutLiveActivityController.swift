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
                content: ActivityContent(state: state, staleDate: state.staleDate(postedAt: Date()))
            )
        } catch {
            // Silent degrade: the in-app sheet remains the experience.
            activity = nil
        }
    }

    /// Push a fresh snapshot on a set/exercise transition. No-op if nothing is live. A real `staleDate`
    /// rides along so a jetsammed/force-quit process can't leave a frozen card on the Lock Screen for
    /// hours — the widget dims to a gentle "paused" state once the snapshot goes stale.
    func update(state: WorkoutActivityAttributes.ContentState) {
        guard let activity else { return }
        let content = ActivityContent(state: state, staleDate: state.staleDate(postedAt: Date()))
        Task { await activity.update(content) }
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

    /// Named stale-date budgets. These are deliberately generous: a legitimate long rest or long set
    /// never trips them. They exist only to retire an *orphaned* activity (the process was jetsammed
    /// while the user watched the Lock Screen countdown, or force-quit) instead of leaving a frozen
    /// card on screen until the system's multi-hour auto-end.
    enum Staleness {
        /// While RESTING, stay fresh until this long PAST the rest deadline. Over-resting is a designed
        /// state, so we don't mark stale the instant the timer hits 0:00 — ten minutes sits well beyond
        /// any real between-set rest, so only a dead process ever reaches it.
        static let restGrace: TimeInterval = 10 * 60
        /// While WORKING, stay fresh for at most this long from when the snapshot was posted. A real set
        /// runs a few minutes; thirty is long enough never to clip a genuine set, short enough that a
        /// dead process stops haunting the Lock Screen within the half hour.
        static let workingCap: TimeInterval = 30 * 60
    }

    /// When this snapshot should be treated as stale (paused/orphaned), given when it is being posted.
    /// Pure and total, so it is unit-testable without a clock. Resting → the rest deadline plus a
    /// grace; working (or a resting snapshot that is somehow missing its window) → the posting time
    /// plus a generous single-step cap.
    func staleDate(postedAt now: Date) -> Date {
        if phase == .resting, let end = restEndsAt {
            return end.addingTimeInterval(Staleness.restGrace)
        }
        return now.addingTimeInterval(Staleness.workingCap)
    }
}
