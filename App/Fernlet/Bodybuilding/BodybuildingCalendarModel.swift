//
//  BodybuildingCalendarModel.swift
//  Fernlet
//
//  The Day calendar's view-free half (World round 7, piece C; spec Docs/Handoff/World-Bodybuilding-Spec.md
//  §2–§4, §8–§10): one load of the visible days, the inputs each day gets from its owners (the sealed
//  tallies, Health's weight, the care score), and the month grid's rows. The views draw a snapshot; the
//  tests read these directly.
//

import FernletDomainModel
import Foundation

/// One load of the Day calendar: the month grid's rows, this week's keys, every visible day and the
/// weights read for them. Built by ``FernletStore/bodybuildingCalendarSnapshot(weights:)``.
nonisolated struct BodybuildingCalendarSnapshot: Equatable, Sendable {
    /// The month holding today.
    var layout: BodybuildingMonthLayout
    /// The grid's rows of seven (nil is a blank), with next week appended when it is marked or suggested.
    var gridRows: [[String?]]
    /// Monday to Sunday of the week holding today.
    var weekKeys: [String]
    /// Every visible day by key.
    var days: [String: BodybuildingDay]
    /// The weights read for the visible days, in kilograms by day key.
    var weights: [String: Double]
    /// The Monday key of the week Fernlet suggests as a deload, while the suggestion stands.
    var suggestedWeek: String?
    /// Today's key when the snapshot was built.
    var todayKey: String

    /// Nothing loaded yet.
    static let empty = BodybuildingCalendarSnapshot(
        layout: BodybuildingMonthLayout(firstDayKey: "", leadingBlanks: 0, dayKeys: [], trailingBlanks: 0),
        gridRows: [], weekKeys: [], days: [:], weights: [:], suggestedWeek: nil, todayKey: "")

    /// Whether the deload card shows: only while Fernlet suggests a week.
    var showsSuggestionCard: Bool { suggestedWeek != nil }

    /// This week's days, in order (a key with no built day is skipped).
    var weekDays: [BodybuildingDay] { weekKeys.compactMap { days[$0] } }

    /// The month's weights up to today, oldest first: the line under the grid.
    var monthWeights: [(key: String, kilograms: Double)] {
        layout.dayKeys.filter { $0 <= todayKey }.compactMap { key in weights[key].map { (key: key, kilograms: $0) } }
    }
}

/// What each visible day gets from the owners that are not its day record.
nonisolated enum BodybuildingCalendarInputs {
    /// Whether a day shows the free-meal F: a tag counts only while its meal is still logged that day
    /// (the lazy rule: a tag whose meal was deleted does not show, and nothing rewrites the sealed row).
    static func hasLiveFreeMeal(taggedMealIDs: [UUID], loggedMealIDs: Set<UUID>) -> Bool {
        taggedMealIDs.contains { loggedMealIDs.contains($0) }
    }

    /// The inputs for `key`: its bathroom count (nil when none), its live free-meal tag, its weight and
    /// its care score.
    static func inputs(
        for key: String,
        bathroomVisits: [String: Int],
        freeMealTags: [String: [UUID]],
        records: [String: FernletDay],
        weights: [String: Double],
        careScores: [String: Int]
    ) -> BodybuildingDayInputs {
        let visits = bathroomVisits[key] ?? 0
        let logged = Set(records[key]?.meals.map(\.id) ?? [])
        return BodybuildingDayInputs(
            bathroomVisits: visits > 0 ? visits : nil,
            freeMeal: hasLiveFreeMeal(taggedMealIDs: freeMealTags[key] ?? [], loggedMealIDs: logged),
            weightKilograms: weights[key],
            careScore: careScores[key])
    }

    /// A day's care score as a whole percent: the scorer's 0…1 value scaled (a value already above 1 is
    /// read as a percent), clamped to 0…100; nil when it is not a number.
    static func carePercent(_ score: Double) -> Int? {
        guard score.isFinite else { return nil }
        let percent = score <= 1 ? score * 100 : score
        return Int(min(max(percent, 0), 100).rounded())
    }
}

/// The month grid's rows and the keys a snapshot loads.
nonisolated enum BodybuildingCalendarGrid {
    /// The month's rows, with `extraWeek` (next week's seven keys, Monday first, or empty) drawn in:
    /// its days fill the blanks of a row that already holds part of it, or it is a row of its own after
    /// the month when it starts after the month's last day. Bounded by the layout's rows plus one.
    static func rows(layout: BodybuildingMonthLayout, extraWeek: [String]) -> [[String?]] {
        var rows = layout.rows
        guard extraWeek.count == 7, let lastDay = layout.dayKeys.last else { return rows }
        let extra = Set(extraWeek)
        var placed = false
        for index in rows.indices where rows[index].contains(where: { cell in cell.map { extra.contains($0) } ?? false }) {
            rows[index] = zip(rows[index], extraWeek).map { cell, key -> String? in cell ?? key }
            placed = true
        }
        if !placed, let first = extraWeek.first, first > lastDay {
            rows.append(extraWeek.map { Optional($0) })
        }
        return rows
    }

    /// Every key the grid and the week list show, sorted and unique.
    static func visibleKeys(rows: [[String?]], weekKeys: [String]) -> [String] {
        Array(Set(rows.flatMap { $0.compactMap { $0 } } + weekKeys)).sorted()
    }
}
