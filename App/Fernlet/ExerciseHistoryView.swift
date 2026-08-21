//
//  ExerciseHistoryView.swift
//  Fernlet
//
//  The Move tab's "Exercise history" sub-screen (round 2.1 increment 2): every exercise with logged
//  history, most recently trained first, with the last session, the heaviest load, and how often
//  it's been logged. Factual recall only, per the round 2.1 design constraint — as-logged values
//  and dates, no trends, no grades, no streaks, no praise.
//

import SwiftUI
import FernletFoundation
import FernletUI

/// The Move stack's fixed (parameterless) routes. Day details push a `String` day key and photo
/// details a `ProgressPhotoRecord`; a screen with no parameter of its own gets a case here instead
/// of a sentinel value smuggled through someone else's type.
enum MoveRoute: Hashable {
    /// The per-exercise recall list, ``ExerciseHistoryView``.
    case exerciseHistory
}

/// Display half of the Exercise history screen's "best" line, beside
/// ``lastTimeRecallValues``' "last time" half.
extension TrainerExportBundle.ExerciseHistoryEntry {
    /// The values half of the "Best: 150 lb × 5" line — the heaviest logged load in the unit the
    /// user wrote (bare number when no unit was ever stated), with "× reps" appended when the reps
    /// at that weight parsed to a plain number. `nil` when no line for this exercise ever stated a
    /// weight, so the caller shows nothing rather than inventing a load. Factual only: no
    /// comparison, no trend, no praise (round 2.1 design constraint).
    var bestRecallValues: String? {
        guard let weight = bestWeight else { return nil }
        let number = weight.formatted(.number.precision(.fractionLength(0...1)))
        let unit = weightUnit.map { " \($0)" } ?? ""
        guard let reps = bestWeightReps else { return "\(number)\(unit)" }
        return "\(number)\(unit) × \(reps)"
    }
}

/// One row of the Exercise history screen: an exercise's rollup entry resolved to display-ready
/// VALUE strings.
///
/// Authored copy (the "Last" / "Best" / "Logged" labels) stays in ``ExerciseHistoryRow`` as
/// `LocalizedStringKey` literals; this model carries only the value halves — the name as logged,
/// day keys, and the as-written prescription strings — the same split
/// ``TrainerExportBundle/ExerciseHistoryEntry/lastTimeRecallValues`` established for the row
/// editor's recall line. Rows are built for the whole screen from ONE rollup pass
/// (``FernletStore/exerciseHistoryEntries()``), in the rollup's own most-recently-trained-first
/// order — never re-sorted or recomputed per row.
struct ExerciseHistoryRowModel: Identifiable, Equatable {
    /// The rollup emits one entry per normalized exercise name, so the name identifies the row.
    var id: String { name }
    /// The exercise name as the user logged it — user data, rendered verbatim, never localized.
    let name: String
    /// Day key ("2026-08-08") of the most recent session — the frozen token half; display goes
    /// through ``lastDateText``.
    let lastLoggedDayKey: String
    /// Day key of the first logged session; display goes through ``firstDateText``.
    let firstLoggedDayKey: String
    /// The most recent session's values as logged ("3x8 @ 135 lb"); `nil` when that line carried
    /// neither a prescription nor a load.
    let lastValues: String?
    /// The heaviest logged load and, when parseable, the reps it was lifted for ("150 lb × 5");
    /// `nil` when no line ever stated a weight.
    let bestValues: String?
    /// Days on which the exercise appeared — the rollup's frequency signal, not a set count.
    let sessions: Int

    /// The most recent session's date, formatted for display.
    var lastDateText: String { Self.displayDate(fromDayKey: lastLoggedDayKey) }

    /// The first session's date, formatted for display.
    var firstDateText: String { Self.displayDate(fromDayKey: firstLoggedDayKey) }

    /// Full date with year ("Aug 8, 2026") — a history can span years, and a bare "Aug 8" two
    /// years later is ambiguous. Falls back to the raw day key if it doesn't parse (the
    /// `CoachPlanReviewView` precedent), so a malformed key degrades to its token, never to a
    /// wrong date.
    static func displayDate(fromDayKey key: String) -> String {
        guard let date = FernletDate.date(fromDayKey: key) else { return key }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }
}

extension ExerciseHistoryRowModel {
    /// Resolves one rollup entry to its display values.
    init(entry: TrainerExportBundle.ExerciseHistoryEntry) {
        self.init(
            name: entry.name,
            lastLoggedDayKey: entry.lastLogged,
            firstLoggedDayKey: entry.firstLogged,
            lastValues: entry.lastTimeRecallValues,
            bestValues: entry.bestRecallValues,
            sessions: entry.sessions)
    }

    /// Rows for the whole screen from one already-computed rollup, preserving its order.
    ///
    /// A closure rather than the unapplied `init(entry:)`: the app target is MainActor-by-default,
    /// and passing the isolated initializer as a function value strips its isolation.
    static func rows(from entries: [TrainerExportBundle.ExerciseHistoryEntry]) -> [ExerciseHistoryRowModel] {
        entries.map { ExerciseHistoryRowModel(entry: $0) }
    }
}

/// The Move sub-screen listing every exercise with logged history, most recently trained first —
/// name, last session, heaviest load, and how often it's been logged.
///
/// Pushed from the Move root via ``MoveRoute/exerciseHistory`` and drawn with the pushed-screen
/// chrome ``MoveDayDetailView`` uses (own `ScreenHeader`, parchment background, inline empty nav
/// title). Rows load once per appearance from a single rollup pass
/// (``FernletStore/exerciseHistoryEntries()``) into `@State` — the same snapshot idiom as the Move
/// root's `allDays`, and deliberately not per-row recomputation.
struct ExerciseHistoryView: View {
    var store: FernletStore
    @State private var rows: [ExerciseHistoryRowModel] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(
                    title: "Exercise history",
                    subtitle: "Each exercise as logged, most recent first.",
                    identifier: "screen.exerciseHistory")
                historySection
            }
            .padding(20)
        }
        .background(Color.parchment)
        // The page draws its own ScreenHeader (matching the Move root), so the bar carries only
        // the back button rather than repeating the title directly above the big one.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { rows = ExerciseHistoryRowModel.rows(from: store.exerciseHistoryEntries()) }
    }

    /// The rows, divided — or the quiet factual empty line.
    private var historySection: some View {
        FernletScrollSection {
            if rows.isEmpty {
                EmptyState(text: "No exercises logged yet.")
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    ExerciseHistoryRow(row: row)
                    if index < rows.count - 1 { FernletRowDivider() }
                }
            }
        }
    }
}

/// One exercise's recall row: the name as logged over the last-session, best-load, and frequency
/// lines.
///
/// Value strings arrive pre-resolved from ``ExerciseHistoryRowModel``; only the labels are
/// authored copy here, so they localize while the values never do. Lines with nothing factual to
/// say (no parsed load, a single session's redundant first date) are absent rather than padded.
struct ExerciseHistoryRow: View {
    var row: ExerciseHistoryRowModel

    /// "Last: Aug 8, 2026 · 3x8 @ 135 lb" — just the date when the line carried no values.
    private var lastLine: Text {
        if let values = row.lastValues {
            return Text("Last: \(row.lastDateText) · \(values)")
        }
        return Text("Last: \(row.lastDateText)")
    }

    /// "Logged 12 times · first on Mar 2, 2026". A single session says only "Logged once" — its
    /// first date IS the last line's date, and repeating it adds nothing factual.
    private var frequencyLine: Text {
        if row.sessions == 1 {
            return Text("Logged once")
        }
        return Text("Logged \(row.sessions) times · first on \(row.firstDateText)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.name)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
            lastLine
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            if let best = row.bestValues {
                Text("Best: \(best)")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
            frequencyLine
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
