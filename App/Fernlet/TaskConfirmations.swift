//
//  TaskConfirmations.swift
//  Fernlet
//
//  What VoiceOver hears when one of the declaration's common tasks lands — log a meal, log a mood,
//  complete a workout — and while a guided workout moves from set to rest to set (VoiceOver dry run,
//  2026-10-18; `Docs/Accessibility-Nutrition-Labels.md` §3). The recipe book's "added" line joined
//  the same day, as one of the off-path toasts that run follow-up adopted.
//
//  Before this file every one of those outcomes was silent. A sighted user sees the sheet close, the
//  tile's count roll, the chip fill or the runner's screen change; a VoiceOver user hears the cursor
//  land somewhere and has to go looking for evidence that the thing they did, happened. Apple's
//  criterion for declaring VoiceOver is that every common task can be COMPLETED with it, and a task
//  whose completion cannot be heard has not been shown to complete.
//
//  Two rules from `FernletAnnouncer` hold here too. The copy is `LocalizedStringResource` literals in
//  the APP target, so it extracts into the app's own catalog and resolves against `Bundle.main`. And
//  it announces the EVENT, never a private payload: "Mood logged." — not which mood, which the chip
//  under the cursor already says to the one person holding the phone.
//

import Foundation
import FernletDomainModel
import FernletUI

/// The spoken confirmation for a common task that just landed.
///
/// Each case is one outcome a VoiceOver user could not otherwise hear. Water is deliberately absent:
/// its counters carry an `.accessibilityValue`, which VoiceOver re-reads itself when it changes
/// under the cursor — the mechanism `FernletAnnouncer` reserves for counters — so announcing as well
/// would say the new count twice.
enum TaskConfirmation: Equatable {
    /// A meal sheet, the recipe book, a Food row, the planner, cooking mode's finish, the recipe
    /// editor's "Log & save" or a Home meal chip logged `count` meals, and the Undo toast is up.
    case mealLogged(count: Int)
    /// The toast's Undo removed the `count` meals it had just logged. The Undo button the cursor
    /// was on goes with the toast, so this is the only word that the undo happened.
    case mealUndone(count: Int)
    /// A one-tap mood chip recorded or changed today's check-in.
    case moodLogged
    /// The workout sheet, "Already did this" or a planned row's check logged a workout.
    case workoutLogged
    /// The journal sheet saved an entry.
    case journalSaved
    /// The recipe book's create branch saved a recipe and popped back to the book, whose "added"
    /// line is now up. The recipe could be typed by hand, pasted as Fernlet recipe data, or imported
    /// from a web page. The import screen's own "added" line hands off to this one rather than
    /// speaking too, so each recipe is confirmed once.
    case recipeAdded
    /// "Start Fernlet" finished onboarding and the app opened (A14). The root view swaps with no
    /// focus change of its own, so this is the only word that setup is over.
    case onboardingFinished

    /// The sentence spoken. Event only, never the logged content.
    var sentence: LocalizedStringResource {
        switch self {
        case .mealLogged(let count) where count > 1:
            "\(count) meals logged. Undo is at the bottom of the screen."
        case .mealLogged:
            "Meal logged. Undo is at the bottom of the screen."
        case .mealUndone(let count) where count > 1:
            "\(count) meals removed."
        case .mealUndone:
            "Meal removed."
        case .moodLogged:
            "Mood logged."
        case .workoutLogged:
            "Workout logged."
        case .journalSaved:
            "Journal entry saved."
        case .recipeAdded:
            "Recipe added to your recipe book."
        case .onboardingFinished:
            "Setup finished."
        }
    }

    /// How long a closing sheet holds VoiceOver before a confirmation can be heard.
    ///
    /// When a sheet dismisses, the system moves VoiceOver's cursor back to the presenting screen and
    /// reads what it lands on; an announcement posted inside that transition is liable to be cut off
    /// by it. The sheet animation is about half a second. This is a reasoned figure, NOT a measured
    /// one — the simulator has no VoiceOver to listen with — and the owner's device pass
    /// (`Docs/Handoff/a11y-2026-10-18/voiceover-device-pass.md`) is where it is checked by ear.
    static let sheetSettle: Duration = .milliseconds(700)

    /// Speaks the confirmation at once — for a log made in place, where nothing is closing.
    ///
    /// - Parameter announcer: Test seam; `nil` (production) resolves to ``FernletAnnouncer/system``
    ///   in the body, not as a default value — a default argument is evaluated off the main actor.
    @MainActor
    func announce(using announcer: FernletAnnouncer? = nil) {
        (announcer ?? .system).announce(.success, sentence)
    }

    /// Speaks the confirmation once a closing sheet has settled (``sheetSettle``).
    ///
    /// Call it from an unstructured `Task`, not a view's `.task`: the sheet that logged is the view
    /// being torn down, and a `.task` on it would be cancelled before it spoke. A cancellation is
    /// still honoured — it means the app is going away, and nothing should be said into that.
    ///
    /// - Parameter announcer: Test seam, resolved as in ``announce(using:)``.
    @MainActor
    func announceAfterSheetCloses(using announcer: FernletAnnouncer? = nil) async {
        do {
            try await Task.sleep(for: Self.sheetSettle)
        } catch {
            return
        }
        (announcer ?? .system).announce(.success, sentence)
    }
}

/// What VoiceOver hears after a guided-workout control moves the run.
///
/// The runner's bottom button is the only control on the screen while a set or a rest is live, and
/// what it changes — the set strip, the rest timer, the exercise card — is elsewhere on the screen.
/// Without this a double-tap on "Done set" changed the whole page in silence.
enum GuidedRunAnnouncement {
    /// The kind and sentence for the move from `before` to `after`, or nil when nothing a VoiceOver
    /// user needs to hear changed (a refused transition, a run that went away).
    ///
    /// Exercise names are spoken: they are the plan's own words, already on screen, and nothing
    /// about them is sealed. They are spoken as drawn (`displayedName`, the user's language), never
    /// as the frozen catalog name.
    static func spoken(
        from before: GuidedWorkoutRunState,
        to after: GuidedWorkoutRunState?
    ) -> (kind: FernletAnnouncementKind, sentence: LocalizedStringResource)? {
        guard let after, after != before else { return nil }
        if after.isFinishedNaturally {
            return (.success, "Workout finished and logged.")
        }
        if after.isResting && !before.isResting {
            return (.status, "Set done. Resting.")
        }
        guard after.isWorking, let exercise = after.currentExercise else { return nil }
        let countsSets = exercise.fromCatalog && exercise.sets >= 1
        if after.exerciseIndex != before.exerciseIndex {
            // A cardio segment says its pace, length and round — its name ("Intervals") is the same for
            // every part, so "Next: Intervals." would say nothing. One line per change: the haptic and
            // sound cue are separate channels, and a segment that follows straight on has no lead-in
            // line after it.
            if let segment = exercise.segment {
                return (.status, GuidedSegmentWords.changeLine(segment, seconds: exercise.holdSeconds ?? 0))
            }
            // A warm-up set says which one ("Warm-up set 1 of 3: Back squat."), and the lift after its
            // warm-ups says its working sets begin.
            if let warmUp = GuidedWarmUpWords.changeLine(from: before, to: after) {
                return (.status, warmUp)
            }
            // A one-sided step (a stretch, a balance hold) says its side; a single timed step has no
            // set to count ("Set 1 of 1" for every stretch would be noise).
            switch exercise.sideRaw {
            case "left": return (.status, "Next: \(exercise.displayedName), left side.")
            case "right": return (.status, "Next: \(exercise.displayedName), right side.")
            default: break
            }
            if exercise.holdSeconds != nil && exercise.sets <= 1 {
                return (.status, "Next: \(exercise.displayedName).")
            }
            return countsSets
                ? (.status, "Next exercise: \(exercise.displayedName). Set 1 of \(after.totalSetsForCurrent).")
                : (.status, "Next exercise: \(exercise.displayedName).")
        }
        guard countsSets else { return nil }
        return (.status, "Set \(after.currentSet) of \(after.totalSetsForCurrent).")
    }

    /// Spoken when a rest's timer reaches zero. The rest does not end by itself — the user decides —
    /// so this says the nudge is over, not that anything moved.
    ///
    /// Resolved here for `address`, the user's term of address, rather than handed out as a
    /// resource: "when you're ready" describes the user, Spanish agrees it (*lista*), and
    /// `LocalizationBoundaryTests` part I2 wants a gendered key's literal inside the addressed call
    /// that reads it.
    static func restOver(addressing address: TermOfAddress) -> String {
        AddressedCopy.string("Rest's over. Start your next set when you're ready.", addressing: address)
    }

    /// Spoken when a timed step's "Get into position" lead-in ends and the hold begins — the moment
    /// the hold countdown's caption turns to "Hold" and the haptic cue plays. Without it a VoiceOver
    /// user with haptics off had no signal to start holding.
    static let holdStartedLine: LocalizedStringResource = "Hold now."

    /// The hold-start line for a lead-in that ended at `leadInEnd`, or nil when that moment has
    /// passed — the runner was reopened mid-hold, or the app slept through it — so the line is said
    /// once, at the moment, and never late. Nothing else is spoken at that instant: the step's own
    /// "Next: …" line was said five seconds earlier, when the step began.
    static func holdStarted(leadInEndedAt leadInEnd: Date, now: Date) -> LocalizedStringResource? {
        GuidedRunCuePlan.isOnTime(leadInEnd, now: now) ? holdStartedLine : nil
    }

    /// Spoken after the runner's "+15 s" / "−15 s": what the tap did to the rest, or — at a limit, when
    /// nothing on screen moves — why it did nothing. The timer beside the buttons changes too, but its
    /// spoken value is re-read only when VoiceOver lands on it.
    static func restAdjusted(adding: Bool, moved: Bool) -> LocalizedStringResource {
        switch (adding, moved) {
        case (true, true): return "Added 15 seconds of rest."
        case (false, true): return "Took 15 seconds off the rest."
        case (true, false): return "Your rest is already at its 10-minute limit."
        case (false, false): return "Your rest is nearly over, so there's nothing to take off."
        }
    }
}
