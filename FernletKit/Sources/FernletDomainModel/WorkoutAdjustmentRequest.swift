// WorkoutAdjustmentRequest.swift
// FernletDomainModel
//
// What an "Adjust with AI" request rules out, read in code before the model sees anything (the owner's
// fix s1, 2026-11-10: "'No barbell' is enforced by the filter, not left to the model"). The request
// used to reach the model as text only, while the candidate ranking gave +30 to every exercise whose
// name shared a word with it — so "no barbell today" pushed "Barbell row" and "Barbell curl" to the top
// of the list the model chose from.
//
// Now the request is read once here. Equipment it rules out ("no barbell", "without dumbbells",
// "dumbbells only", "no equipment") never reaches the candidate list, a reply that names it anyway is
// replaced or left out (``WorkoutAdjustmentRequest/enforced(on:pool:catalog:)``), and the words of a
// ruled-out phrase earn no ranking bonus. The matching words are English and FROZEN, like the injury
// note's (the localization wall): a request in another language rules nothing out here and is left to
// the model, as before.

import Foundation

/// What an adjustment request rules out, and which of its words may favour an exercise by name.
///
/// Pure and deterministic; bounded by ``maxWords``.
public nonisolated struct WorkoutAdjustmentRequest: Equatable, Sendable {
    /// Equipment the request rules out: no exercise on it is offered or kept.
    public var excludedEquipment: Set<Equipment>
    /// The words that may favour an exercise whose name shares one: three letters or more, and none
    /// from a phrase that rules something out.
    public var bonusWords: Set<String>

    /// Creates a request's rules.
    public init(excludedEquipment: Set<Equipment> = [], bonusWords: Set<String> = []) {
        self.excludedEquipment = excludedEquipment
        self.bonusWords = bonusWords
    }

    /// The most words read from one clause of a request.
    public static let maxWords = 60
    /// The most clauses read from a request.
    static let maxClauses = 12
    /// How many words after a ruling-out word belong to its phrase ("no access to a barbell").
    static let span = 4

    /// Words that rule out what follows them.
    static let cues: Set<String> = ["no", "without", "skip", "avoid", "minus", "not", "dont", "don", "lack", "lacking"]

    /// Equipment a person can load: what "only" leaves out when it names one of them.
    static let loadable: Set<Equipment> = [.barbell, .dumbbell, .kettlebell, .machine, .cable, .band]

    /// The equipment each word names.
    static let equipmentWords: [String: Set<Equipment>] = [
        "barbell": [.barbell], "barbells": [.barbell],
        "dumbbell": [.dumbbell], "dumbbells": [.dumbbell], "db": [.dumbbell], "dbs": [.dumbbell],
        "kettlebell": [.kettlebell], "kettlebells": [.kettlebell], "kb": [.kettlebell],
        "machine": [.machine], "machines": [.machine],
        "cable": [.cable], "cables": [.cable],
        "band": [.band], "bands": [.band],
        "bench": [.bench],
        "weights": [.barbell, .dumbbell, .kettlebell],
        "equipment": [.barbell, .dumbbell, .kettlebell, .machine, .cable, .band, .bench],
        "gear": [.barbell, .dumbbell, .kettlebell, .machine, .cable, .band, .bench],
    ]

    /// What `text` rules out. Read clause by clause (a comma or a full stop ends one), so "no
    /// barbell, more dumbbell work" rules out the barbell alone.
    public static func read(_ text: String) -> WorkoutAdjustmentRequest {
        var request = WorkoutAdjustmentRequest()
        let clauses = text.lowercased().split(whereSeparator: { ",.;!?\n".contains($0) }).prefix(maxClauses)
        for clause in clauses {
            let words = clause.split(whereSeparator: { !$0.isLetter }).prefix(maxWords).map(String.init)
            request.read(clause: words)
        }
        return request
    }

    /// Reads one clause's words into the rules.
    mutating func read(clause words: [String]) {
        var ruledOut: Set<Int> = []
        for index in words.indices where Self.cues.contains(words[index]) {
            for at in (index + 1)..<min(words.count, index + 1 + Self.span) {
                ruledOut.insert(at)
                if let named = Self.equipmentWords[words[at]] { excludedEquipment.formUnion(named) }
            }
        }
        for index in words.indices where words[index] == "only" {
            for at in [index - 1, index + 1] where words.indices.contains(at) && !ruledOut.contains(at) {
                if words[at] == "bodyweight" { excludedEquipment.formUnion(Self.loadable) }
                if let named = Self.equipmentWords[words[at]] { excludedEquipment.formUnion(Self.loadable.subtracting(named)) }
            }
        }
        for (index, word) in words.enumerated() where word.count >= 3 && !ruledOut.contains(index) && !Self.cues.contains(word) {
            bonusWords.insert(word)
        }
    }

    /// Whether the request leaves `exercise` in: it is not done on ruled-out equipment, and its name
    /// does not name it ("Barbell curl", whatever tool its row lists first).
    public func allows(_ exercise: ExerciseTarget) -> Bool {
        guard !excludedEquipment.isEmpty else { return true }
        guard !excludedEquipment.contains(exercise.equipment) else { return false }
        let words = exercise.name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return !words.contains { Self.equipmentWords[$0].map { !$0.isDisjoint(with: excludedEquipment) && $0.count == 1 } ?? false }
    }

    /// `picks` with the request enforced: a pick on ruled-out equipment is replaced by the lift from
    /// `pool` that does the most similar work on equipment the request allows
    /// (``replacement(for:in:excluding:)``), keeping the pick's sets, or left out when there is none.
    /// `catalog` is where a pick's name is looked up; a pick it does not know is kept as it is.
    public func enforced(on picks: [PrescribedExercise], pool: [ExerciseTarget], catalog: [ExerciseTarget]) -> [PrescribedExercise] {
        guard !excludedEquipment.isEmpty else { return picks }
        let allowedPool = pool.filter(allows)
        var used = Set(picks.map { WorkoutExerciseCatalog.normalizedName($0.name) })
        var result: [PrescribedExercise] = []
        for pick in picks.prefix(WorkoutPlanFinisher.maximumLifts) {
            guard let target = WorkoutAdjustedLoad.target(named: pick.name, in: catalog), !allows(target) else {
                result.append(pick)
                continue
            }
            guard let swap = Self.replacement(for: target, in: allowedPool, excluding: used) else { continue }
            used.insert(WorkoutExerciseCatalog.normalizedName(swap.name))
            var replaced = pick
            replaced.name = swap.name
            replaced.guidance = nil
            replaced.holdSeconds = nil
            result.append(replaced)
        }
        return result
    }

    /// The lift in `pool` nearest to `target`: strength work on the same movement pattern that shares
    /// a primary muscle, the most shared muscles first, then by name. Nil when nothing does that work.
    static func replacement(for target: ExerciseTarget, in pool: [ExerciseTarget], excluding used: Set<String>) -> ExerciseTarget? {
        let fits = pool.filter { candidate in
            candidate.modality == target.modality && candidate.measure == target.measure
                && candidate.movementPattern == target.movementPattern
                && !candidate.primaryMuscles.isDisjoint(with: target.primaryMuscles)
                && !used.contains(WorkoutExerciseCatalog.normalizedName(candidate.name))
        }
        return fits.min { lhs, rhs in
            let left = lhs.primaryMuscles.intersection(target.primaryMuscles).count
            let right = rhs.primaryMuscles.intersection(target.primaryMuscles).count
            return left != right ? left > right : lhs.name < rhs.name
        }
    }
}
