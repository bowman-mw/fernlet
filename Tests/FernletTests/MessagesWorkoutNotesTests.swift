//
//  MessagesWorkoutNotesTests.swift
//  FernletTests
//
//  Tracker §2.6 (2026-10-18), the owner's pick "2a". A planned workout's free-text notes ride inside
//  its Messages card (`ExchangeWorkoutPlanBuilder` copies them into the session), yet the composer
//  showed only "date · 1 workout", so a sender could not tell their notes were going along (the
//  2026-09-23 review: "workout notes not previewed"). The composer's row and preview now say "Notes
//  included"; the card face keeps the date and the count, and never shows the note text.
//

import Foundation
import Testing
import FernletDomainModel
import FernletExchange

/// Pins when a workout card counts as carrying notes, that the card's metadata never holds the note
/// text, and that the iMessage app's composer says "Notes included" while its card face does not.
struct MessagesWorkoutNotesTests {

    private static let sentinel = "knee still sore, go easy on lunges"

    private static func entry(notes: String, exercises: String = "") throws -> FernletMessagesWorkoutCatalogEntry {
        let workout = PlannedWorkout(name: "Leg day", split: .lower, source: .user, exercises: exercises,
                                     notes: notes, duration: 40)
        let packet = try WorkoutPlanExchangePacket(plan: ExchangeWorkoutPlanBuilder.oneDayPlan(from: workout,
                                                                                                 dayKey: "2026-10-18"))
        return try FernletMessagesWorkoutCatalogEntry(dayKey: "2026-10-18", packet: packet)
    }

    /// A workout's notes make the card carry notes, whether or not it lists exercises; a workout
    /// without notes does not. Derived, so the packet's wire and hash are what they were.
    @Test func aWorkoutWithNotesCarriesThemAndOneWithoutDoesNot() throws {
        #expect(try Self.entry(notes: Self.sentinel).packet.includesNotes)
        #expect(try Self.entry(notes: Self.sentinel, exercises: "Squat 3x8").packet.includesNotes)
        #expect(try !Self.entry(notes: "").packet.includesNotes)
        #expect(try !Self.entry(notes: "", exercises: "Squat 3x8").packet.includesNotes)

        let packet = try Self.entry(notes: Self.sentinel).packet
        let encoded = String(decoding: try packet.encodedData(), as: UTF8.self)
        #expect(!encoded.contains("includesNotes"), "the flag must stay derived, never on the wire")
        #expect(try WorkoutPlanExchangePacket.decode(packet.encodedData()) == packet)
    }

    /// The card's face is drawn from its metadata (title, sender, count, day), which never holds the
    /// note text, even when the notes travel in the packet.
    @Test func theCardsMetadataNeverHoldsTheNoteText() throws {
        let entry = try Self.entry(notes: Self.sentinel)
        let card = String(decoding: try JSONEncoder().encode(entry.card), as: UTF8.self)
        #expect(!card.contains(Self.sentinel))
        #expect(entry.card.title == "Leg day")
        #expect(entry.card.workoutCount == 1)
        #expect(entry.card.scheduledStartDayKey == "2026-10-18")
    }

    /// The composer's workout row and preview read the notes-aware line; the card face's subcaption
    /// reads the date and the count alone. A source pin: the view controller lives in the iMessage
    /// app, which this bundle does not link, and swapping either call compiles clean.
    @Test func theComposerSaysNotesIncludedAndTheCardFaceDoesNot() throws {
        let source = try RepoRoot.source("App/FernletMessagesExtension/FernletMessagesViewController.swift")
        #expect(source.contains("subtitle: workoutComposerSummary(for: entry)"),
                "the workout row no longer says when notes travel with the card")
        #expect(source.contains("return workoutComposerSummary(for: entry)"),
                "the workout preview no longer says when notes travel with the card")
        #expect(source.contains("guard entry.packet.includesNotes else { return summary }"))
        #expect(source.contains("layout.subcaption = workoutSummary(for: entry)"),
                "the card face must keep the date and the count alone")
        #expect(source.contains("\"\\(entry.dayKey) · \\(FernletMessagesCopy.workoutCount(entry.packet.plan.sessionCount))\""),
                "the card face's line is the date and the count, nothing else")
        let copy = try RepoRoot.source("App/FernletMessagesExtension/FernletMessagesCopy.swift")
        #expect(copy.contains("\"messages.workout.subtitleWithNotes\""))
    }
}
