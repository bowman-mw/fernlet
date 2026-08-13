// CookingRunState.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// The serializable source of truth for an in-progress cooking session (F5). It lives in the app-group
// container so the interactive Live Activity "Next" button — and the Siri "next step" / "repeat step"
// App Intents — can advance the recipe walker from the Lock Screen / Dynamic Island even when the app
// is suspended or was terminated and the system cold-launches it just to run the intent. The app
// mirrors this state into the group on every in-app transition and reconciles back from it on
// foreground / launch, so the in-app cooking walker and the Live Activity never disagree about which
// step you're on. This is the exact pattern GuidedWorkoutRunState uses for the guided workout.
//
// Dual target membership (like GuidedWorkoutRunState.swift): the WIDGET target references it in the
// App Intents; the APP target reads/writes it (FernletStore) and maps it to/from the RecipeDefinition.
// It is wired into the Fernlet target via the FernletWidgets folder's build-file exception set.
//
// S3 wall: plain Codable/Hashable value types + ActivityKit only — no Private* stores, no
// FernletDomainModel import. The APP target owns the RecipeDefinition⇄run-state mapping (it can import
// both); this shared type stays byte-portable, storing the ordered step list as plain text + optional
// duration. Recipes are NOT sealed content, so a step's text living in the app-group JSON is fine.

import ActivityKit
import Foundation

/// A cooking session in progress, captured as a flat value so it survives process death in the
/// app-group container and can be advanced by an App Intent with no live app state.
///
/// Like GuidedWorkoutRunState carries the full `exercises` array so a cold-launched "Done set" intent
/// can render the next set with no domain plan, this carries the full ordered `steps` list so a
/// cold-launched "Next" intent can render the next step with no RecipeDefinition. `stepCount` and
/// `currentStepText` are therefore derived accessors over that list, not independently stored scalars.
///
/// Persisted as ISO-8601 JSON by ``CookingRunStateStore``; its two writers (the app while
/// foregrounded, the App Intents otherwise) never run concurrently. All transitions are pure
/// `mutating` functions — no clock or file access — and the timer invariant (`timerStartedAt` and
/// `timerEndsAt` set and cleared together, always ordered) is what keeps the widget's
/// `Text(timerInterval:)` from ever seeing an inverting range.
struct CookingRunState: Codable, Hashable {

    /// One cooking step, flattened to byte-portable primitives (mirror of the domain `RecipeStep`,
    /// which the app target maps to/from).
    ///
    /// A positive `durationSeconds` drives the passive per-step timer; `nil` means the step just
    /// shows the Next button.
    struct Step: Codable, Hashable {
        var text: String
        var durationSeconds: Int?

        init(text: String, durationSeconds: Int? = nil) {
            self.text = text
            self.durationSeconds = durationSeconds
        }
    }

    // MARK: Identity + logging anchor

    /// The `RecipeDefinition.id` this run walks — the key the resume card uses to re-open the recipe.
    var recipeID: UUID
    /// The recipe's name (also the Live Activity title).
    var recipeName: String
    /// The day the cook BEGAN. A long session can cross local midnight; a completion log anchors here,
    /// not "today" (mirrors the guided run's `committedDayKey`).
    var startedDayKey: String
    /// When cooking began. Fixed for the life of the run.
    var startedAt: Date

    // MARK: Ordered steps + cursor

    /// The full ordered step list — carried so a cold-launched Next intent can render the next step.
    var steps: [Step]
    /// 0-based index into `steps`.
    var stepIndex: Int

    // MARK: Single per-step timer (v1 — no concurrent named timers)

    /// The FIXED timer window (paired), so the widget renders a non-inverting `Text(timerInterval:)`.
    /// Both are set only while a step timer is running and cleared together otherwise.
    var timerStartedAt: Date?
    var timerEndsAt: Date?

    /// True once the walker has been advanced past the last step (a natural finish). Cooking never
    /// auto-logs a meal (the meal type is the cook's choice, made on the in-app finish screen), so a
    /// finished run simply ends the Live Activity — there is no dedup-sensitive automatic log.
    var finished: Bool

    /// When this run was last written to the app group. Stamped on every persist. Reconcile uses its
    /// age to tell a live run (recently touched) from a run the process merely outlived (untouched for
    /// hours → abandoned), instead of keying off the day — exactly like GuidedWorkoutRunState.
    var updatedAt: Date

    /// A run untouched for longer than this is treated as abandoned and retired on the next reconcile.
    /// Generous: a real session is touched far more often; only a genuinely left-behind run reaches it.
    static let abandonedAfter: TimeInterval = 6 * 60 * 60

    init(
        recipeID: UUID,
        recipeName: String,
        startedDayKey: String,
        startedAt: Date = Date(),
        steps: [Step],
        stepIndex: Int = 0,
        timerStartedAt: Date? = nil,
        timerEndsAt: Date? = nil,
        finished: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.recipeID = recipeID
        self.recipeName = recipeName
        self.startedDayKey = startedDayKey
        self.startedAt = startedAt
        self.steps = steps
        self.stepIndex = stepIndex
        self.timerStartedAt = timerStartedAt
        self.timerEndsAt = timerEndsAt
        self.finished = finished
        self.updatedAt = updatedAt
    }

    // MARK: Derived (the task's named "step count" / "current step text" scalars)

    var stepCount: Int { steps.count }

    var currentStep: Step? {
        steps.indices.contains(stepIndex) ? steps[stepIndex] : nil
    }

    var currentStepText: String { currentStep?.text ?? "" }

    /// 1-based cursor for display ("Step 3 of 8").
    var stepNumber: Int { min(stepIndex + 1, max(stepCount, 1)) }

    var isLastStep: Bool { stepIndex >= steps.count - 1 }

    var isFinished: Bool { finished }

    /// A running timer window is trustworthy only when both ends are present and ordered.
    var hasRunningTimer: Bool {
        guard let start = timerStartedAt, let end = timerEndsAt else { return false }
        return start <= end
    }

    // MARK: Transitions (pure — mirror the in-app walker + the GuidedWorkoutRunState idiom)

    /// Advance to the next step, or finish when already on the last step. Always clears the timer — a
    /// per-step timer never carries across a step boundary.
    mutating func advance() {
        clearTimer()
        if stepIndex < steps.count - 1 {
            stepIndex += 1
        } else {
            finished = true
        }
    }

    /// Step back one step (clamped at 0). Clears the timer. The in-app walker maps a back from step 0
    /// to "return to mise en place", which ends the run entirely — that is the app's call, not this
    /// pure value's, so here a back at 0 is simply a no-op beyond clearing the timer.
    mutating func goBack() {
        clearTimer()
        if stepIndex > 0 {
            stepIndex -= 1
        }
    }

    /// Start (or restart) the current step's passive timer, if it carries a positive duration. Used by
    /// the in-app "Start timer" button and by the "repeat step" intent (which re-fires the timer).
    mutating func startTimer(now: Date) {
        guard let seconds = currentStep?.durationSeconds, seconds > 0 else {
            clearTimer()
            return
        }
        timerStartedAt = now
        timerEndsAt = now.addingTimeInterval(TimeInterval(seconds))
    }

    mutating func clearTimer() {
        timerStartedAt = nil
        timerEndsAt = nil
    }

    // MARK: Live Activity mapping

    /// Snapshot into the Live Activity content. `finished` is never rendered — the activity is ended
    /// the instant a run finishes — so the mapping just carries the current cursor + timer window.
    var contentState: CookingActivityAttributes.ContentState {
        CookingActivityAttributes.ContentState(
            stepText: currentStepText,
            stepNumber: stepNumber,
            stepCount: max(stepCount, 1),
            isLastStep: isLastStep,
            timerStartedAt: timerStartedAt,
            timerEndsAt: timerEndsAt
        )
    }

    /// Named stale-date budgets (mirror GuidedWorkoutRunState.Staleness).
    ///
    /// Generous enough that a real long step never trips them — they exist only to retire an
    /// orphaned activity into a "paused" register instead of a frozen live card.
    enum Staleness {
        static let timerGrace: TimeInterval = 15 * 60
        static let stepCap: TimeInterval = 90 * 60
    }

    /// When this snapshot should be treated as stale (paused / orphaned), given when it is posted.
    func staleDate(postedAt now: Date) -> Date {
        if let end = timerEndsAt, hasRunningTimer {
            return end.addingTimeInterval(Staleness.timerGrace)
        }
        return now.addingTimeInterval(Staleness.stepCap)
    }
}
