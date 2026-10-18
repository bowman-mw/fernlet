// TaskConfirmationTests.swift
// FernletTests
//
// Pins what VoiceOver is told when a common task lands (``TaskConfirmation``) and as a guided
// workout moves (``GuidedRunAnnouncement``) — the VoiceOver dry run's fixes, 2026-10-18, and the
// recipe book's "added" line from that round's off-path follow-up.
//
// Same reason as `FernletAnnouncerTests`: the accessibility system never reports what it spoke, so
// "is this outcome still announced, and with the right kind?" is only answerable through the
// announcer's injected closure. The guided half is pure — (before, after) in, sentence out — so
// each transition the runner can make is checked without a view, a store or a clock.

import Foundation
import Testing
import FernletUI
@testable import Fernlet

/// Records what an announcer was asked to speak, in order.
@MainActor
private final class SpokenLog {
    var spoken: [FernletAnnouncement] = []

    var announcer: FernletAnnouncer {
        FernletAnnouncer { [self] in spoken.append($0) }
    }
}

@MainActor
@Suite struct TaskConfirmationTests {

    // MARK: Task confirmations

    /// An in-place log (the mood chip) is spoken at once, as a success.
    @Test func inPlaceConfirmationIsSpokenAtOnceAsSuccess() {
        let log = SpokenLog()
        TaskConfirmation.moodLogged.announce(using: log.announcer)

        #expect(log.spoken == [FernletAnnouncement(
            kind: .success, message: String(localized: TaskConfirmation.moodLogged.sentence))])
    }

    /// A sheet's log waits for the sheet to close, then speaks exactly once.
    @Test func sheetConfirmationSpeaksOnceAfterTheSettle() async {
        let log = SpokenLog()
        let clock = ContinuousClock()
        let start = clock.now
        await TaskConfirmation.workoutLogged.announceAfterSheetCloses(using: log.announcer)

        #expect(clock.now - start >= TaskConfirmation.sheetSettle)
        #expect(log.spoken.map(\.kind) == [.success])
        #expect(log.spoken.map(\.message) == [String(localized: TaskConfirmation.workoutLogged.sentence)])
    }

    /// A cancelled wait means the app is going away: nothing is said into that.
    @Test func cancelledSheetConfirmationStaysSilent() async {
        let log = SpokenLog()
        let announcer = log.announcer
        let speaking = Task { @MainActor in
            await TaskConfirmation.journalSaved.announceAfterSheetCloses(using: announcer)
        }
        speaking.cancel()
        await speaking.value

        #expect(log.spoken.isEmpty)
    }

    /// One meal and several read differently, and the plural carries its count; both say where Undo is.
    @Test func mealSentencesCountAndPointAtUndo() {
        let one = String(localized: TaskConfirmation.mealLogged(count: 1).sentence)
        let three = String(localized: TaskConfirmation.mealLogged(count: 3).sentence)

        #expect(one != three)
        #expect(three.contains("3"))
        #expect(one.contains("Undo") && three.contains("Undo"))
        #expect(String(localized: TaskConfirmation.mealUndone(count: 2).sentence).contains("2"))
    }

    /// A recipe landing back on the book is spoken once, as a success, after the pop settles. The
    /// sentence is the event: the case carries no name, so a recipe's name can never reach it.
    /// The book's "added" line shows the name, for the one person holding the phone.
    @Test func recipeAddedSpeaksTheEventOnceAfterThePop() async {
        let log = SpokenLog()
        await TaskConfirmation.recipeAdded.announceAfterSheetCloses(using: log.announcer)

        #expect(log.spoken == [FernletAnnouncement(
            kind: .success, message: String(localized: TaskConfirmation.recipeAdded.sentence))])
    }

    /// Every confirmation is a non-empty sentence — an empty one is silently dropped by the announcer.
    @Test func everyConfirmationSaysSomething() {
        let all: [TaskConfirmation] = [
            .mealLogged(count: 1), .mealLogged(count: 2), .mealUndone(count: 1), .mealUndone(count: 2),
            .moodLogged, .workoutLogged, .journalSaved, .recipeAdded
        ]
        for confirmation in all {
            #expect(!String(localized: confirmation.sentence).isEmpty, "\(confirmation)")
        }
    }

    // MARK: Guided run transitions

    /// Two catalog exercises of two sets each, with a rest between sets, starting on set 1.
    private func run() -> GuidedWorkoutRunState {
        let exercises = ["Squat", "Row"].map {
            GuidedWorkoutRunState.Exercise(name: $0, sets: 2, reps: "8", roleRaw: "main",
                                           fromCatalog: true, restSeconds: 60)
        }
        return GuidedWorkoutRunState(
            sessionID: UUID(), committedDayKey: "2026-10-18", intensityRaw: "Moderate",
            title: "Test", suggestionExercisesText: "", suggestionNotes: "", sessionKindRaw: "strength",
            exercises: exercises
        )
    }

    private func words(_ spoken: (kind: FernletAnnouncementKind, sentence: LocalizedStringResource)?) -> String? {
        spoken.map { String(localized: $0.sentence) }
    }

    /// Done set with sets left → a rest begins, and that is what is said.
    @Test func doneSetIntoRestSaysResting() {
        let before = run()
        var after = before
        after.markSetDone(now: Date())

        let spoken = GuidedRunAnnouncement.spoken(from: before, to: after)
        #expect(spoken?.kind == .status)
        #expect(words(spoken) == String(localized: "Set done. Resting."))
    }

    /// Skip rest → back to work on the next set of the same exercise, named by its number.
    @Test func skipRestNamesTheNextSet() {
        var before = run()
        before.markSetDone(now: Date())
        var after = before
        after.skipRest()

        let sentence = words(GuidedRunAnnouncement.spoken(from: before, to: after))
        #expect(sentence?.contains("2") == true)
        #expect(sentence?.contains("Row") == false)
    }

    /// The last set of an exercise goes straight to the next exercise, which is named.
    @Test func lastSetNamesTheNextExercise() {
        var before = run()
        before.markSetDone(now: Date())
        before.skipRest()
        var after = before
        after.markSetDone(now: Date())

        #expect(after.exerciseIndex == 1)
        #expect(words(GuidedRunAnnouncement.spoken(from: before, to: after))?.contains("Row") == true)
    }

    /// The natural finish is a success; an abandon says nothing (nothing was logged).
    @Test func finishIsSuccessAndAbandonIsSilent() {
        var before = run()
        before.exerciseIndex = 1
        before.currentSet = 2
        var finished = before
        finished.markSetDone(now: Date())
        var abandoned = before
        abandoned.end()

        #expect(finished.isFinishedNaturally)
        #expect(GuidedRunAnnouncement.spoken(from: before, to: finished)?.kind == .success)
        #expect(GuidedRunAnnouncement.spoken(from: before, to: abandoned) == nil)
    }

    /// A refused transition (nothing changed) or a run that went away is silent.
    @Test func noChangeIsSilent() {
        let before = run()
        #expect(GuidedRunAnnouncement.spoken(from: before, to: before) == nil)
        #expect(GuidedRunAnnouncement.spoken(from: before, to: nil) == nil)
    }

    /// A descriptor line (cardio walked as one step) is named without a set count it does not have.
    @Test func descriptorExerciseIsNamedWithoutSets() {
        var before = run()
        before.exercises[1] = GuidedWorkoutRunState.Exercise(
            name: "Easy walk", sets: 0, reps: "", roleRaw: "accessory", fromCatalog: false, restSeconds: 0)
        before.markSetDone(now: Date())
        before.skipRest()
        var after = before
        after.markSetDone(now: Date())

        let sentence = words(GuidedRunAnnouncement.spoken(from: before, to: after))
        #expect(sentence?.contains("Easy walk") == true)
        #expect(sentence?.contains("Set") == false)
    }
}
