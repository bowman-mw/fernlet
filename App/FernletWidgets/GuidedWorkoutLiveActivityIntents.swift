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
//
// A11y #15 — every path SPEAKS. Both intents are also App Shortcut phrases (FernletShortcuts), so
// they are driven by voice as often as by a button, and a `LiveActivityIntent` that returns a bare
// `.result()` makes Siri play the success chime for a tap that did nothing: no run on disk, the
// wrong phase, or an app-group write that failed. Every `perform()` here returns
// `IntentResult & ProvidesDialog` and says which of those happened, mirroring `LogWaterIntent`.
//
// Localization of those dialogs: `IntentDialog` is `ExpressibleByStringInterpolation` with the
// `localization_key` semantics, so a LITERAL at the `return` is harvested into the string catalog
// exactly like `LogWaterIntent`'s lines — never assign display text to a `String` first. Neither
// target here is an SPM module, so `bundle: .module` does not apply and the default `.main` is
// right: `perform()` always runs in the APP's process (the system resumes or cold-launches Fernlet
// to run a LiveActivityIntent), so `Bundle.main` is the app bundle and these keys resolve out of
// App/Fernlet/Localizable.xcstrings. Because this file also compiles into the widget extension,
// Scripts/sync-string-catalogs.sh harvests the same keys into App/FernletWidgets/Localizable.xcstrings
// too — identical English in both, the same as the existing "Done set" / "Skip rest" titles.

import ActivityKit
import AppIntents

/// "Done set" — completes the current set (starting the rest countdown, advancing the exercise, or
/// finishing the workout, exactly like the in-app button).
///
/// Rendered by the Lock Screen card and Dynamic Island while working; the system runs `perform()` in
/// the app's process via ``GuidedWorkoutIntentRunner``.
///
/// Returns `ProvidesDialog` so a Siri "Done set in Fernlet" that landed on no run — or on a rest —
/// is *said*, not chimed at (a11y #15).
struct GuidedWorkoutMarkSetDoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Done set"
    static let description = IntentDescription("Marks the current set done and starts your rest timer.")
    // Advance in the background — no need to bring the app forward for a set/rest transition.
    static let supportedModes: IntentModes = [.background]

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await GuidedWorkoutIntentRunner.markSetDone()
        return .result(dialog: GuidedWorkoutIntentRunner.markSetDoneDialog(for: outcome))
    }
}

/// "Skip rest" — ends the rest early and resumes the next set.
///
/// Rendered by the Lock Screen card and Dynamic Island while resting; the system runs `perform()` in
/// the app's process via ``GuidedWorkoutIntentRunner``.
///
/// Returns `ProvidesDialog` for the same reason as ``GuidedWorkoutMarkSetDoneIntent``: "skip rest"
/// spoken while no rest is running must say so rather than succeed silently (a11y #15).
struct GuidedWorkoutSkipRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip rest"
    static let description = IntentDescription("Ends the current rest early and moves to your next set.")
    static let supportedModes: IntentModes = [.background]

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await GuidedWorkoutIntentRunner.skipRest()
        return .result(dialog: GuidedWorkoutIntentRunner.skipRestDialog(for: outcome))
    }
}

/// Shared transition applier for the two guided-workout intents.
///
/// Reads → mutates → writes the app-group run state via ``GuidedWorkoutRunStateStore``, then
/// reflects the result onto the activity through ``GuidedWorkoutActivityBridge``. Guarded on the
/// expected phase so a double-tap or a tap that races the app's own transition changes nothing.
///
/// Every entry point returns an ``Outcome`` rather than `Void`: a Lock Screen button can afford to
/// swallow a no-op (the card the user is looking at simply does not move), but the same intents
/// answer Siri phrases, where a silent no-op is indistinguishable from success. The caller turns the
/// outcome into the spoken line.
enum GuidedWorkoutIntentRunner {

    /// What one intent invocation actually did.
    ///
    /// The three failure cases are deliberately distinct rather than a single `false`: each has a
    /// different thing to tell the user (nothing to advance / advance the *other* control / try
    /// again), and collapsing them is how the bare-`.result()` version came to report a no-op as a
    /// success in the first place.
    enum Outcome: Hashable {
        /// The transition applied and was persisted. The payload is the phase the run landed in, so
        /// the dialog can say whether a rest started, the next set is up, or the workout is over.
        case applied(GuidedWorkoutRunState.Phase)
        /// No guided run is in the app group at all — nothing was ever started, or it has already
        /// been logged and cleared.
        case noRunInProgress
        /// A run exists but is in another phase: a double-tap, a tap that raced the app's own
        /// transition, or a phrase spoken at the wrong moment ("skip rest" mid-set).
        case wrongPhase
        /// The transition was computed but the app-group write did not land, so nothing advanced.
        case notSaved
    }

    /// Complete the current set (rest / next exercise / finish, per the pure transition) and reflect
    /// the result onto the activity. Guarded on `.working`; any other phase reports `.wrongPhase`.
    static func markSetDone() async -> Outcome {
        let store = GuidedWorkoutRunStateStore()
        guard var state = store.read() else { return .noRunInProgress }
        guard state.phase == .working else { return .wrongPhase }
        state.markSetDone(now: Date())
        return await apply(state, store: store)
    }

    /// End the rest early and resume the next set, then reflect the result onto the activity.
    /// Guarded on `.resting`; any other phase reports `.wrongPhase`.
    static func skipRest() async -> Outcome {
        let store = GuidedWorkoutRunStateStore()
        guard var state = store.read() else { return .noRunInProgress }
        guard state.phase == .resting else { return .wrongPhase }
        state.skipRest()
        return await apply(state, store: store)
    }

    /// The spoken result of a "Done set".
    ///
    /// Literals, not `String`s: `IntentDialog`'s string-literal initializer carries the
    /// `localization_key` semantics, so these are harvested into the string catalog. Assigning one
    /// to a `String` first would freeze it in English with a clean build.
    ///
    /// `nonisolated` because both targets build with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
    /// which would otherwise put this on the main actor — and `LiveActivityIntent.perform()` is
    /// nonisolated, so the call site is a hard Swift 6 error. The function is pure (a `switch` over
    /// a value, returning a fresh `IntentDialog`), so there is nothing for the isolation to protect.
    /// Same reasoning as `FernletTheme.swift`'s `nonisolated` palette maths.
    nonisolated static func markSetDoneDialog(for outcome: Outcome) -> IntentDialog {
        switch outcome {
        case .applied(.resting): return "Set done. Resting now."
        case .applied(.working): return "Set done. Your next exercise is up."
        case .applied(.done): return "That was the last set — your workout is finished."
        case .noRunInProgress: return "No workout is running, so there's no set to finish."
        case .wrongPhase: return "You're resting right now, so there's no set to finish yet."
        case .notSaved: return "Couldn't update your workout just now — please try again in a moment."
        }
    }

    /// The spoken result of a "Skip rest". `skipRest()` never leaves the run resting, so the two
    /// `.applied` phases that can follow it share a line. `nonisolated` for the reason spelled out
    /// on ``markSetDoneDialog(for:)``.
    nonisolated static func skipRestDialog(for outcome: Outcome) -> IntentDialog {
        switch outcome {
        case .applied(.working), .applied(.resting): return "Rest skipped. Your next set is up."
        case .applied(.done): return "Rest skipped — your workout is finished."
        case .noRunInProgress: return "No workout is running, so there's no rest to skip."
        case .wrongPhase: return "You're not resting right now, so there's nothing to skip."
        case .notSaved: return "Couldn't update your workout just now — please try again in a moment."
        }
    }

    private static func apply(_ state: GuidedWorkoutRunState,
                              store: GuidedWorkoutRunStateStore) async -> Outcome {
        // Persist first so a foreground reconcile that races the activity update still sees the new
        // state (and, on a finish, logs it). The file is kept even when `.done` — the app clears it
        // once it has logged the finished workout.
        // R7: the file IS the shared truth (the app's reconcile logs the finish from it). If the
        // write did not land, do not advance the activity past the state that is genuinely on disk —
        // the store has already logged the failure, and the next tap retries from the real state.
        // The caller now hears about it too, instead of being told the tap worked.
        guard store.write(state) else { return .notSaved }
        await GuidedWorkoutActivityBridge.sync(to: state)
        return .applied(state.phase)
    }
}
