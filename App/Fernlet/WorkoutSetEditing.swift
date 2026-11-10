import Foundation
import FernletDomainModel

/// One set row while it is being edited: the reps on a stepper, the weight as typed.
///
/// The weight stays text until save so a half-typed "62," is never rewritten under the person's
/// thumb. It is read the way every Fernlet number field reads (`LocaleTolerantNumber`, so "62,5" and
/// "62.5" agree), with a trailing unit word tolerated ("100 lb"). Blank — or unreadable — repeats the
/// set above (``LoggedSet/filledWeights(_:)``).
struct SetRowDraft: Identifiable, Equatable {
    var id = UUID()
    var reps: Int
    var weight: String

    /// The typed weight, or nil when blank or unreadable.
    var weightValue: Double? { Self.weight(from: weight) }

    /// A typed weight read locale-tolerantly, or nil when blank, unreadable or implausible.
    static func weight(from text: String) -> Double? {
        let number = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .letters)
            .trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty, let value = LocaleTolerantNumber.double(from: number),
              LoggedSet.isPlausible(value) else { return nil }
        return value
    }

    /// A weight as a field shows it: the locale's decimal mark, no grouping, at most two decimals;
    /// empty for no weight.
    static func text(for weight: Double?) -> String {
        guard let weight else { return "" }
        return weight.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

/// One lift's sets while they are being edited: in the Edit sheet (a logged result, or a
/// hand-written line that parses into sets × reps) or in the Log sheet's set-by-set entry.
///
/// Saving goes through ``WorkoutSetEditing``: a result is re-recorded in place
/// (``ExerciseResult/record(_:unit:)``) and its line rewritten; a hand-written line or a new entry
/// becomes a structured record (``ExerciseResult/handLogged(name:sets:unit:equipment:effort:)``)
/// beside its readable line. Always at least one row once it has any; at most
/// ``ExerciseResult/maxSets``.
struct ExerciseSetsDraft: Identifiable, Equatable {
    /// Where the draft came from, which decides how saving writes it back.
    enum Origin: Equatable {
        /// The workout's structured result at this index.
        case result(Int)
        /// A hand-written line, verbatim, that parsed into sets × reps.
        case line(String)
        /// A lift entered set by set in the Log sheet.
        case new
    }

    /// Reps a fresh row starts at.
    static let defaultReps = 8

    var id = UUID()
    var name: String
    var origin: Origin
    var rows: [SetRowDraft]
    var unit: LoadUnit
    var effort: ExerciseEffort?
    var overrideReason: OverrideReason?
    /// The lift had a prescribed range, so "why outside it" applies.
    var hasRange = false
    var equipment: Equipment?
    /// Whether "How did it feel?" applies — not to a calibration ramp-up or a max single, which
    /// the runner never asks about either.
    var asksEffort = true

    /// The rows as the log records them.
    var loggedSets: [LoggedSet] { rows.map { LoggedSet(reps: $0.reps, weight: $0.weightValue) } }

    /// The weight a blank row at `index` repeats — the nearest filled row above it — for its prompt.
    func inheritedWeight(before index: Int) -> Double? {
        guard index > 0, index <= rows.count else { return nil }
        for row in rows[..<index].reversed() {
            if let value = row.weightValue { return value }
        }
        return nil
    }

    /// Adds a row at the last row's reps with a blank weight (which repeats the set above).
    mutating func addSet() {
        guard rows.count < ExerciseResult.maxSets else { return }
        rows.append(SetRowDraft(reps: rows.last?.reps ?? Self.defaultReps, weight: ""))
    }

    /// Adds a copy of the last row, reps and weight.
    mutating func repeatLastSet() {
        guard rows.count < ExerciseResult.maxSets else { return }
        guard let last = rows.last else {
            addSet()
            return
        }
        rows.append(SetRowDraft(reps: last.reps, weight: last.weight))
    }

    /// Removes a row, keeping at least one.
    mutating func removeSet(id: UUID) {
        guard rows.count > 1 else { return }
        rows.removeAll { $0.id == id }
    }

    /// `result` with these sets, and the effort and reason when they changed (an unchanged answer
    /// leaves the stored token alone, so one only a newer build knows survives the edit).
    func applied(to result: ExerciseResult) -> ExerciseResult {
        var updated = result
        updated.record(loggedSets, unit: unit)
        if effort != result.effort { updated.effortToken = effort?.rawValue }
        if overrideReason != result.overrideReason { updated.overrideReasonToken = overrideReason?.rawValue }
        return updated
    }

    /// These sets as a new structured record — a hand-written line corrected, or a set-by-set entry.
    func handLoggedResult() -> ExerciseResult? {
        ExerciseResult.handLogged(name: name, sets: loggedSets, unit: unit, equipment: equipment, effort: effort)
    }
}

extension ExerciseSetsDraft {
    /// A logged result's sets, ready to correct.
    init(result: ExerciseResult, index: Int, defaultUnit: LoadUnit) {
        self.init(
            name: result.name, origin: .result(index),
            rows: result.loggedSets.map { SetRowDraft(reps: $0.reps, weight: SetRowDraft.text(for: $0.weight)) },
            unit: result.unit ?? defaultUnit, effort: result.effort, overrideReason: result.overrideReason,
            hasRange: result.rangeLow != nil && result.rangeHigh != nil, equipment: result.equipment,
            asksEffort: result.calibration != .ramp && result.calibration != .attempt
        )
    }

    /// A hand-written line's sets ("Squat 5x5 @225lb" → five rows of 5 at 225), or nil for a line
    /// that is not sets × a rep count (a hold, a rep range, a note).
    init?(line: String, defaultUnit: LoadUnit) {
        guard let parsed = ExerciseLineParser.parse(line), let reps = parsed.repsCount, reps > 0,
              let sets = parsed.sets, sets > 0,
              !WorkoutExerciseCatalog.normalizedName(parsed.name).isEmpty else { return nil }
        let weight = SetRowDraft.text(for: parsed.weight)
        self.init(
            name: parsed.name, origin: .line(line),
            rows: (0..<min(sets, ExerciseResult.maxSets)).map { _ in SetRowDraft(reps: reps, weight: weight) },
            unit: parsed.weightUnit.flatMap(LoadUnit.init(rawValue:)) ?? defaultUnit,
            equipment: WorkoutExerciseCatalog.exercise(named: parsed.name)?.equipment
        )
    }

    /// A fresh set-by-set entry: one row at the default reps.
    static func blank(name: String, unit: LoadUnit, equipment: Equipment?) -> ExerciseSetsDraft {
        ExerciseSetsDraft(
            name: name, origin: .new, rows: [SetRowDraft(reps: defaultReps, weight: "")], unit: unit,
            equipment: equipment
        )
    }
}

/// The pure rules behind correcting a logged workout's sets: which lifts are editable, and how an
/// edit writes back. Extracted from the Edit sheet so they are unit-testable without SwiftUI.
///
/// Editable: every structured result (a guided lift, or one entered set by set), and on a row the
/// person logged by hand, every other line that parses into sets × reps. A guided row's other lines
/// are its plan, not a record, so they stay as they are; an Apple Health import is never editable.
enum WorkoutSetEditing {

    /// The editable lifts of `workout`, results first in their stored order, then hand-written lines.
    static func drafts(for workout: Workout, defaultUnit: LoadUnit) -> [ExerciseSetsDraft] {
        guard !workout.isHealthImported else { return [] }
        let results = workout.exerciseResults ?? []
        var drafts = results.enumerated().map { ExerciseSetsDraft(result: $1, index: $0, defaultUnit: defaultUnit) }
        guard workout.loggedFromGuidedSession != true else { return drafts }
        let covered = Set(results.map { WorkoutExerciseCatalog.normalizedName($0.name) })
        for line in workout.exerciseLines.prefix(Workout.maxExerciseResults) {
            guard let draft = ExerciseSetsDraft(line: line, defaultUnit: defaultUnit),
                  !covered.contains(WorkoutExerciseCatalog.normalizedName(draft.name)) else { continue }
            drafts.append(draft)
        }
        return drafts
    }

    /// `workout` with every changed draft written back, or unchanged when nothing changed.
    ///
    /// A result is re-recorded in place and its line rewritten from the old ``ExerciseResult/loggedLine``
    /// to the new one; a changed hand-written line becomes a structured record and its line is
    /// rewritten to that record's. Every other line, and every untouched record, stays exactly as it
    /// was — so the readable log and the structured record always say the same thing.
    static func applying(_ drafts: [ExerciseSetsDraft], original: [ExerciseSetsDraft], to workout: Workout) -> Workout {
        guard !workout.isHealthImported else { return workout }
        var updated = workout
        var results = workout.exerciseResults ?? []
        let before = Dictionary(original.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for draft in drafts where before[draft.id] != draft {
            switch draft.origin {
            case .result(let index):
                guard results.indices.contains(index) else { continue }
                let old = results[index]
                let new = draft.applied(to: old)
                guard new != old else { continue }
                updated.replaceExerciseLine(old.loggedLine, with: new.loggedLine)
                results[index] = new
            case .line(let text):
                guard results.count < Workout.maxExerciseResults, let new = draft.handLoggedResult() else { continue }
                updated.replaceExerciseLine(text, with: new.loggedLine)
                results.append(new)
            case .new:
                continue
            }
        }
        updated.exerciseResults = results.isEmpty ? workout.exerciseResults : results
        return updated
    }
}

// MARK: - "Is that weight right?" (w2)

/// The one question a typed set weight raises before it is saved (w2, 2026-11-10): "500 lb? Last
/// time was 50." Never a block — "Keep 500" saves it as typed, "Fix it" goes back to the rows — and
/// never raised twice for the same lift and value (``key``).
struct SetWeightQuestion: Equatable, Identifiable {
    /// What the weight was measured against.
    enum Reference: Equatable {
        /// The lift's weight the last time it was logged.
        case lastTime
        /// The heaviest of this session's other sets of the lift.
        case otherSets
    }

    /// The lift's name as logged.
    var lift: String
    /// The typed weight being asked about, in ``unit``.
    var weight: Double
    /// The weight it stands far above, in ``unit``: last time's, or the next heaviest set's.
    var usual: Double
    var reference: Reference
    var unit: LoadUnit

    /// The lift and the value asked about — what "never twice for the same value" is keyed on.
    var key: String { SetWeightCheck.key(lift: lift, weight: weight) }
    var id: String { key }
}

/// The pure rule behind ``SetWeightQuestion`` (owner, 2026-11-10): ask before saving when a set is
/// more than 1.5 times the session's other sets or last time's weight.
///
/// Only the lift's heaviest set is ever asked about, so one save raises at most one question per
/// lift: it is asked when it is more than ``ratio`` times last time's weight, else when it is more
/// than ``ratio`` times every other set of the lift (the next heaviest set). Exactly 1.5 times asks
/// nothing; a lighter set never does; a lift with one set and no last time has nothing to compare.
/// The engine's side of w2 — which weight the next suggestion builds on — lives in the load engine.
enum SetWeightCheck {
    /// A set this many times the reference, or less, is saved without a question.
    static let ratio = 1.5

    /// The question `weights` raise, or nil.
    ///
    /// - Parameters:
    ///   - lift: The lift's name as logged.
    ///   - weights: Each set's weight as it will be saved, blanks already filled; nil or zero for none.
    ///   - lastTime: The lift's last logged weight in `unit`, or nil when it has none.
    ///   - unit: The unit the weights were typed in.
    ///   - settled: ``key(lift:weight:)`` of every value already asked about or already saved, which
    ///     is never asked about again.
    static func question(
        lift: String, weights: [Double?], lastTime: Double?, unit: LoadUnit, settled: Set<String> = []
    ) -> SetWeightQuestion? {
        let typed = weights.prefix(ExerciseResult.maxSets).compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
        guard let heaviest = typed.max(), !settled.contains(key(lift: lift, weight: heaviest)) else { return nil }
        if let lastTime, lastTime.isFinite, lastTime > 0, isFarAbove(heaviest, lastTime) {
            return SetWeightQuestion(lift: lift, weight: heaviest, usual: lastTime, reference: .lastTime, unit: unit)
        }
        var others = typed
        if let index = others.firstIndex(of: heaviest) { others.remove(at: index) }
        guard let next = others.max(), isFarAbove(heaviest, next) else { return nil }
        return SetWeightQuestion(lift: lift, weight: heaviest, usual: next, reference: .otherSets, unit: unit)
    }

    /// Whether `weight` is more than ``ratio`` times `usual` (a hundredth's tolerance, so a typed
    /// 75 against 50 is not "more than").
    static func isFarAbove(_ weight: Double, _ usual: Double) -> Bool {
        weight > usual * ratio + WorkoutLoadEngine.weightTolerance
    }

    /// One lift's value as the "already asked" sets hold it: the normalized name and the weight to
    /// the hundredth. In memory only, never persisted.
    static func key(lift: String, weight: Double) -> String {
        "\(WorkoutExerciseCatalog.normalizedName(lift))|\(Int((weight * 100).rounded()))"
    }

    /// The keys of every weight in `weights` — what a sheet settles when it opens, so a value that was
    /// already saved is never asked about.
    static func keys(lift: String, weights: [Double?]) -> Set<String> {
        Set(weights.prefix(ExerciseResult.maxSets).compactMap { $0 }.map { key(lift: lift, weight: $0) })
    }

    /// A logged weight read in `unit`: converted when `unitToken` ("lb" / "kg") names the other unit,
    /// as written when it names none. Nil for no weight or one that is not positive.
    static func weight(_ weight: Double?, unitToken: String?, in unit: LoadUnit) -> Double? {
        guard let weight, weight.isFinite, weight > 0 else { return nil }
        guard let from = unitToken.flatMap(LoadUnit.init(rawValue:)) else { return weight }
        return unit.converted(weight, from: from)
    }
}

extension ExerciseSetsDraft {
    /// Each row's weight as it will be saved (a blank repeating the row above), or all nil when no row
    /// carries one.
    var filledWeights: [Double?] {
        LoggedSet.filledWeights(loggedSets) ?? Array(repeating: nil, count: rows.count)
    }

    /// The question this lift's typed weights raise before saving (``SetWeightCheck``), or nil.
    func weightQuestion(lastTime: Double?, settled: Set<String>) -> SetWeightQuestion? {
        SetWeightCheck.question(lift: name, weights: filledWeights, lastTime: lastTime, unit: unit, settled: settled)
    }
}

extension WorkoutSetEditing {
    /// The first question the changed lifts raise before an edit is saved, or nil. A lift whose rows
    /// were not touched is never asked about, and neither is a value the lift already had when the
    /// sheet opened (it was saved once already).
    ///
    /// - Parameter lastTime: The lift's last logged weight in the given unit, by name.
    static func weightQuestion(
        in drafts: [ExerciseSetsDraft], original: [ExerciseSetsDraft], settled: Set<String>,
        lastTime: (String, LoadUnit) -> Double?
    ) -> SetWeightQuestion? {
        let before = Dictionary(original.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for draft in drafts.prefix(Workout.maxExerciseResults) where before[draft.id] != draft {
            let opened = before[draft.id].map { SetWeightCheck.keys(lift: draft.name, weights: $0.filledWeights) } ?? []
            if let asked = draft.weightQuestion(lastTime: lastTime(draft.name, draft.unit), settled: settled.union(opened)) {
                return asked
            }
        }
        return nil
    }
}
