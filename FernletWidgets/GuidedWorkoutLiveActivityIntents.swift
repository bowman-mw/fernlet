// GuidedWorkoutLiveActivityIntents.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// The interactive Live Activity buttons for the guided workout: "Done set" (which starts the rest
// countdown) and "Skip rest". A `LiveActivityIntent` runs in the APP's process — the widget renders
// the button, but the system executes `perform()` in the app (resuming or cold-launching it in the
// background as needed). So these advance the shared app-group GuidedWorkoutRunState and push it onto
// the activity directly, with NO dependency on any live in-app state: read the run from the group,
// apply the pure transition, write it back, and update/end the activity. The app reconciles that same
// file on its next foreground (FernletStore.reconcileGuidedRunFromAppGroup) to keep the in-app guided
// sheet in step and to log a finish that happened entirely from the Lock Screen.

import ActivityKit
import AppIntents

/// "Done set" — completes the current set (starting the rest countdown, advancing the exercise, or
/// finishing the workout, exactly like the in-app button).
struct GuidedWorkoutMarkSetDoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Done set"
    static let description = IntentDescription("Marks the current set done and starts your rest timer.")
    // Advance in the background — no need to bring the app forward for a set/rest transition.
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await GuidedWorkoutIntentRunner.markSetDone()
        return .result()
    }
}

/// "Skip rest" — ends the rest early and resumes the next set.
struct GuidedWorkoutSkipRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip rest"
    static let description = IntentDescription("Ends the current rest early and moves to your next set.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await GuidedWorkoutIntentRunner.skipRest()
        return .result()
    }
}

/// Shared transition applier for the two intents. Reads → mutates → writes the app-group run state,
/// then reflects it onto the activity. Guarded on the expected phase so a double-tap or a tap that
/// races the app's own transition is a harmless no-op.
enum GuidedWorkoutIntentRunner {
    static func markSetDone() async {
        let store = GuidedWorkoutRunStateStore()
        guard var state = store.read(), state.phase == .working else { return }
        state.markSetDone(now: Date())
        await apply(state, store: store)
    }

    static func skipRest() async {
        let store = GuidedWorkoutRunStateStore()
        guard var state = store.read(), state.phase == .resting else { return }
        state.skipRest()
        await apply(state, store: store)
    }

    private static func apply(_ state: GuidedWorkoutRunState, store: GuidedWorkoutRunStateStore) async {
        // Persist first so a foreground reconcile that races the activity update still sees the new
        // state (and, on a finish, logs it). The file is kept even when `.done` — the app clears it
        // once it has logged the finished workout.
        store.write(state)
        await GuidedWorkoutActivityBridge.sync(to: state)
    }
}
