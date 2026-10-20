// WorkoutSetLog.swift
// FernletDomainModel
//
// Set-by-set records after the fact (comparison report idea 6): correcting a logged lift's reps and
// weights in the Edit sheet, and entering a lift set by set in the Log sheet. Both write the same
// ``ExerciseResult`` a guided run writes, plus its readable line, so the load engine, the history,
// the exports and the trainer export all read one record. Load-aware progression re-derives every
// prescription from this history, so a corrected set changes what comes next.

import Foundation

/// One set as the log records it: the reps done and, for a loaded lift, the weight.
public nonisolated struct LoggedSet: Equatable, Sendable {
    /// The most reps one logged set may carry.
    public static let maxReps = 100

    public var reps: Int
    /// The weight in the lift's unit; nil for an unloaded set, or one entered blank (which repeats
    /// the set before it — see ``filledWeights(_:)``).
    public var weight: Double?

    public init(reps: Int, weight: Double?) {
        self.reps = reps
        self.weight = weight
    }

    /// Each set's weight with the blanks filled in, or nil when no set carries one.
    ///
    /// A blank repeats the set before it ("same as above", how people log), and a blank before the
    /// first weight takes that first weight. So a lift is either loaded on every set or on none —
    /// which is what ``ExerciseResult/setWeights`` needs to line up with the reps.
    public static func filledWeights(_ sets: [LoggedSet]) -> [Double]? {
        let valid: [Double?] = sets.map { set in set.weight.flatMap { Self.isPlausible($0) ? $0 : nil } }
        guard let first = valid.compactMap({ $0 }).first else { return nil }
        var last = first
        var filled: [Double] = []
        for weight in valid {
            if let weight { last = weight }
            filled.append(last)
        }
        return filled
    }

    /// A weight a set can carry: finite, not negative, at most ``ExerciseResult/maxWeight``.
    public static func isPlausible(_ weight: Double) -> Bool {
        weight.isFinite && weight >= 0 && weight <= ExerciseResult.maxWeight
    }

    /// This set with its reps held to 0…``maxReps``.
    var clamped: LoggedSet {
        LoggedSet(reps: min(max(0, reps), Self.maxReps), weight: weight)
    }
}

extension ExerciseResult {

    /// Every set as logged: its reps, with the weight it was lifted at (nil for an unloaded lift).
    public var loggedSets: [LoggedSet] {
        let weights = alignedSetWeights
        return repsPerSet.enumerated().map { index, reps in
            LoggedSet(reps: reps, weight: weights.map { $0[index] } ?? workingWeight)
        }
    }

    /// Records what the sets actually were — a correction in the Edit sheet, or a set-by-set entry.
    ///
    /// The prescription (sets, target, range, suggestion) is history and stays as it was; what
    /// changes is the record of what was lifted. The working weight becomes the heaviest set's,
    /// ``setWeights`` is kept only when the sets differed, and ``actualReps`` only when the reps
    /// left the prescription — so recording the sets as prescribed reads as "completed as
    /// prescribed" again. A blank weight repeats the set before it. An empty list changes nothing.
    ///
    /// - Parameter unit: The unit the weights were entered in; ignored when no set has a weight.
    public mutating func record(_ sets: [LoggedSet], unit: LoadUnit?) {
        let capped = Array(sets.prefix(Self.maxSets)).map(\.clamped)
        guard !capped.isEmpty else { return }
        let reps = capped.map(\.reps)
        let weights = LoggedSet.filledWeights(capped)
        let top = weights?.max()
        selectedWeight = top
        if top != nil, let unit { unitToken = unit.rawValue }
        if let weights, let top, weights.contains(where: { top - $0 > WorkoutLoadEngine.weightTolerance }) {
            setWeights = weights
        } else {
            setWeights = nil
        }
        let asPrescribed = Array(repeating: targetReps, count: min(prescribedSets, Self.maxSets))
        actualReps = reps == asPrescribed ? nil : reps
    }

    /// A lift logged set by set with no prescription — the Log sheet's set-by-set entry, recorded in
    /// the same shape a guided run records, so the engine reads it the same way.
    ///
    /// The target is the best reps among the sets at the working weight (what the lifter was going
    /// for), so a shorter last set reads as a small miss, exactly as it would after a guided run.
    /// Returns nil for a blank name or no sets.
    public static func handLogged(
        name: String, sets: [LoggedSet], unit: LoadUnit?, equipment: Equipment? = nil,
        effort: ExerciseEffort? = nil
    ) -> ExerciseResult? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = Array(sets.prefix(maxSets)).map(\.clamped)
        guard !trimmed.isEmpty, !capped.isEmpty else { return nil }
        let weights = LoggedSet.filledWeights(capped)
        let top = weights?.max()
        let working = capped.indices.filter { index in
            guard let top, let weights else { return true }
            return weights[index] >= top - WorkoutLoadEngine.weightTolerance
        }
        let target = max(1, working.map { capped[$0].reps }.max() ?? 1)
        var result = ExerciseResult(
            name: trimmed, prescribedSets: capped.count, targetReps: target,
            unit: top == nil ? nil : unit, equipment: equipment, effort: effort
        )
        result.record(capped, unit: unit)
        return result
    }
}

extension Workout {

    /// Rewrites one line of ``exercises`` — the first whose trimmed text is `oldLine` — to `newLine`,
    /// leaving every other line exactly as it was; appends `newLine` when no line matches.
    ///
    /// How a corrected ``ExerciseResult`` keeps the readable log in step with its record: the old
    /// line is the result's ``ExerciseResult/loggedLine`` before the edit (or the hand-written line a
    /// set-by-set correction replaces).
    public mutating func replaceExerciseLine(_ oldLine: String, with newLine: String) {
        let target = oldLine.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = exercises.components(separatedBy: "\n")
        if !target.isEmpty,
           let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == target }) {
            lines[index] = newLine
        } else if exercises.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines = [newLine]
        } else {
            lines.append(newLine)
        }
        exercises = lines.joined(separator: "\n")
    }
}
