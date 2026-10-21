// CoachPlanNoteStamp.swift
// FernletDomainModel
//
// The two provenance lines the coach-plan importer writes into a planned workout's notes (2026-10-20,
// Spanish round step 2), FROZEN English, plus the exact-shape matcher that recognises them and their
// draw-time localized forms.
//
// A stamp is stored text: it is the last line of `PlannedWorkout.notes`, synced, exported to a coach
// and into the exchange file, carried onto the logged row when the plan is run, and read back by the
// importer itself, which strips the previous stamp before writing a new one. So it is written in
// English on every device, and a screen draws it through `displayedNotes(_:)`. The strip used to be
// `hasPrefix("Changed by ") || hasPrefix("Day ")`, which also dropped any line of the user's own that
// began "Day " ("Day off, knees sore"); it now matches the two stamp shapes exactly.

import Foundation

/// The coach-plan importer's provenance stamps: the frozen writers, the exact-shape matcher, and the
/// localized forms screens draw.
///
/// Never put a ``displayed(_:)`` result back into a note: the writers here are the only spellings a
/// stored note may carry, and ``isStamp(_:)`` only recognises them. Pinned by
/// `LocalizationBoundaryTests.frozenCoachPlanNoteStamps`.
public nonisolated enum CoachPlanNoteStamp {
    /// The author a stamp names when the plan carries no coach name.
    public static let unnamedAuthor = "an assistant"

    /// The line an imported session's notes end with: `Day 2 of "Block A", imported from Sam.`
    public static func imported(dayIndex: Int, planTitle: String, author: String) -> String {
        "Day \(dayIndex) of \"\(planTitle)\", imported from \(author)."
    }

    /// The line a coach-edited row's notes end with: `Changed by Sam from "Block A".`
    public static func changed(author: String, planTitle: String) -> String {
        "Changed by \(author) from \"\(planTitle)\"."
    }

    /// The author to stamp for a plan whose `coachDisplayName` is `name`.
    public static func author(named name: String) -> String {
        name.isEmpty ? unnamedAuthor : name
    }

    /// Whether `line` is exactly one of the two stamp shapes the writers above produce.
    public static func isStamp(_ line: String) -> Bool {
        importedParts(line) != nil || changedParts(line) != nil
    }

    /// `notes` with every stamp line drawn in the user's language and every other line unchanged.
    /// Display only.
    public static func displayedNotes(_ notes: String) -> String {
        guard notes.contains("imported from ") || notes.contains("Changed by ") else { return notes }
        return notes
            .components(separatedBy: "\n")
            .map { displayed($0) ?? $0 }
            .joined(separator: "\n")
    }

    /// The localized form of one stamp line, or nil when `line` is not a stamp.
    public static func displayed(_ line: String) -> String? {
        if let parts = importedParts(line) {
            return importedDisplay(day: parts.day, title: parts.title, author: parts.author)
        }
        if let parts = changedParts(line) {
            return changedDisplay(title: parts.title, author: parts.author)
        }
        return nil
    }

    /// The day number, plan title and author of an imported stamp, or nil for any other line.
    static func importedParts(_ line: String) -> (day: Int, title: String, author: String)? {
        guard let match = line.wholeMatch(of: /Day ([0-9]{1,4}) of "(.*)", imported from (.+)\./),
              let day = Int(match.output.1) else { return nil }
        return (day, String(match.output.2), String(match.output.3))
    }

    /// The author and plan title of a changed stamp, or nil for any other line.
    static func changedParts(_ line: String) -> (author: String, title: String)? {
        guard let match = line.wholeMatch(of: /Changed by (.+?) from "(.*)"\./) else { return nil }
        return (String(match.output.1), String(match.output.2))
    }

    /// An imported stamp, localized.
    private static func importedDisplay(day: Int, title: String, author: String) -> String {
        guard author != unnamedAuthor else {
            return String(localized: "coachPlan.stamp.importedUnnamed", defaultValue: "Day \(day) of \"\(title)\", imported from an assistant.",
                          bundle: .module, comment: "Note line on a workout that came from a pasted AI plan. Arguments: the plan's day number, then the plan's title.")
        }
        return String(localized: "coachPlan.stamp.imported", defaultValue: "Day \(day) of \"\(title)\", imported from \(author).",
                      bundle: .module, comment: "Note line on a workout that came from a pasted plan. Arguments: the plan's day number, the plan's title, then who wrote it.")
    }

    /// A changed stamp, localized.
    private static func changedDisplay(title: String, author: String) -> String {
        guard author != unnamedAuthor else {
            return String(localized: "coachPlan.stamp.changedUnnamed", defaultValue: "Changed by an assistant from \"\(title)\".",
                          bundle: .module, comment: "Note line on a planned workout a pasted AI plan changed. Argument: the plan's title.")
        }
        return String(localized: "coachPlan.stamp.changed", defaultValue: "Changed by \(author) from \"\(title)\".",
                      bundle: .module, comment: "Note line on a planned workout a pasted plan changed. Arguments: who wrote the plan, then the plan's title.")
    }
}
