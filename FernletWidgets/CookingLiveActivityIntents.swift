// CookingLiveActivityIntents.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// The interactive Live Activity "Next" button for cooking mode, plus the Siri / Shortcuts voice path
// for messy-hands cooking ("next step" / "repeat step"). A `LiveActivityIntent` runs in the APP's
// process — the widget renders the button, but the system executes `perform()` in the app (resuming or
// cold-launching it in the background as needed). So these advance the shared app-group CookingRunState
// and push it onto the activity directly, with NO dependency on any live in-app state: read the run
// from the group, apply the pure transition, write it back, and update/end the activity. The app
// reconciles that same file on its next foreground (FernletStore.reconcileCookingRunFromAppGroup) to
// keep the in-app cooking walker in step.
//
// A `LiveActivityIntent` is also an `AppIntent`, so these same two types are surfaced to Siri /
// Spotlight with natural phrasing via FernletShortcuts (the a75e839 App Intents pattern) — one type,
// two invocation surfaces (the Lock Screen button and the voice phrase).

import ActivityKit
import AppIntents
import Foundation

extension Notification.Name {
    /// Posted in the APP's process the instant a cooking App Intent (Live Activity "Next" / Siri "next
    /// step" / "repeat step") writes the advanced run to the app group. `LiveActivityIntent.perform`
    /// runs in-process but mutates only the file + activity — nothing tells `FernletStore`, so the in-app
    /// walker would only catch up on the next scenePhase `.active` reconcile, and an in-app "Next" landing
    /// before that reconcile writes stale in-memory state over the file, discarding the intent's advance.
    /// The store observes this to reconcile IMMEDIATELY after the write, closing that window. Harmless in
    /// the widget process (no observer there).
    static let cookingRunAdvancedByIntent = Notification.Name("MBO.Fernlet.cookingRunAdvancedByIntent")
}

/// "Next" — advances to the next step, or finishes the cook when already on the last step. The exact
/// pattern the guided workout uses for "Done set": mutate the shared app-group state, reflect it onto
/// the activity. Invoked by the Live Activity button and by "Hey Siri, next step in Fernlet".
struct NextCookingStepIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Next cooking step"
    static let description = IntentDescription("Moves to the next step of the recipe you're cooking.")
    // Advance in the background — no need to bring the app forward for a step transition.
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await CookingIntentRunner.advance()
        return .result()
    }
}

/// "Repeat step" — restarts the current step's passive timer (the voice equivalent of tapping the
/// in-app "Reset timer" and starting it again) so a cook whose hands are busy can re-fire the countdown
/// without touching the phone. It never changes which step you're on. A step with no timer is a no-op.
struct RepeatCookingStepIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Repeat cooking step"
    static let description = IntentDescription("Restarts the timer on the current cooking step.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await CookingIntentRunner.repeatStep()
        return .result()
    }
}

/// Shared transition applier for the two intents. Reads → mutates → writes the app-group run state,
/// then reflects it onto the activity. Guarded so a tap that races the app's own transition — or one
/// that lands after the cook finished — is a harmless no-op.
enum CookingIntentRunner {
    static func advance() async {
        let store = CookingRunStateStore()
        guard var state = store.read(), !state.isFinished else { return }
        state.advance()
        await apply(state, store: store)
    }

    static func repeatStep() async {
        let store = CookingRunStateStore()
        guard var state = store.read(), !state.isFinished else { return }
        state.startTimer(now: Date())
        await apply(state, store: store)
    }

    private static func apply(_ state: CookingRunState, store: CookingRunStateStore) async {
        // Persist first so a foreground reconcile that races the activity update still sees the new
        // state. On a finish the file is kept (marked `finished`) so the app's reconcile can retire it
        // and end any lingering activity; the app clears it once it has.
        store.write(state)
        // Signal the app (same process) to reconcile its in-memory walker NOW that the file is durable,
        // rather than waiting for the next scenePhase round-trip — see `.cookingRunAdvancedByIntent`.
        NotificationCenter.default.post(name: .cookingRunAdvancedByIntent, object: nil)
        await CookingActivityBridge.sync(to: state)
    }
}
