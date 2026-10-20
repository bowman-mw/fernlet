// WorkoutExercisePreferences.swift
// FernletDomainModel
//
// Exercise preferences (2026-10-20, idea 15 of the comparison report). Hevy has "Don't Recommend
// Again" and swaps with four alternatives; Shred keeps saved alternates. Fernlet had neither: the only
// way to keep an exercise out of a plan was to remove it by hand every day. These are the two standing
// preferences the planner reads — exercises it never suggests, and saved alternates it prefers — and
// the swap options the plan editor offers.

import Foundation

/// The user's standing exercise preferences: exercises the planner never suggests ("Don't suggest
/// this") and saved alternates it prefers ("Always use this instead").
///
/// Both hold FROZEN exercise names (``ExerciseTarget/name``) — never a drawn display name — and match
/// through ``WorkoutExerciseCatalog/normalizedName(_:)``, so "Bench Press" and "bench press" are one
/// exercise. The planner (``WorkoutProgram/dayPlan(goal:intensity:profile:location:context:split:rotationIndex:progression:load:recent:options:preferences:catalog:)``)
/// leaves a hidden exercise out of every block and swaps in a saved alternate only when the
/// alternate passes everything the original did; the AI adjuster never sees a hidden exercise.
///
/// Synced at the TOP LEVEL of ``FernletSettings`` (`workoutHiddenExercises`,
/// `workoutExerciseAlternates`), where an older build's generic key parking keeps them through a
/// re-save; each key is written only when it holds something, so a blob without preferences keeps
/// its old shape. Decoded tolerantly (``hiddenNames(from:)``, ``alternates(from:)``): a value of an
/// unexpected shape, a non-string entry or an over-long name is skipped rather than thrown on, and
/// both lists are bounded (``maxHidden``, ``maxAlternates``).
///
/// An alternate is one hop: with A → B and B → C saved, a slot that would pick A gets B, never C.
public nonisolated struct WorkoutExercisePreferences: Equatable, Sendable {
    /// Bound on the hidden list — more than the bundled catalog plus a full custom list would need
    /// in practice, and the decode cap for a corrupt or hostile blob.
    public static let maxHidden = 600
    /// Bound on saved alternates.
    public static let maxAlternates = 200
    /// A stored name longer than this is not an exercise name (the custom-exercise and coach-plan
    /// limit), so it is skipped.
    public static let maxNameCharacters = 80
    /// Bound on the raw entries a decode walks before giving up on the rest (R2).
    static let maxDecodedEntries = 2_000

    /// Exercises the planner never suggests, as stored (frozen names), oldest first.
    public private(set) var hidden: [String]
    /// Saved alternates: the original's frozen name → the frozen name used instead.
    public private(set) var alternates: [String: String]

    public init(hidden: [String] = [], alternates: [String: String] = [:]) {
        self.hidden = Self.sanitizedHidden(hidden)
        self.alternates = Self.sanitizedAlternates(alternates)
    }

    /// No hidden exercises and no saved alternates.
    public var isEmpty: Bool { hidden.isEmpty && alternates.isEmpty }

    /// The hidden names as comparison keys — what a filter over many exercises reads, once.
    public var hiddenKeys: Set<String> {
        Set(hidden.map(WorkoutExerciseCatalog.normalizedName))
    }

    /// The saved alternates keyed by the original's comparison key, valued by the alternate as stored.
    public var alternateKeys: [String: String] {
        Dictionary(alternates.map { (WorkoutExerciseCatalog.normalizedName($0.key), $0.value) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Whether the planner leaves `name` out.
    public func isHidden(_ name: String) -> Bool {
        hiddenKeys.contains(WorkoutExerciseCatalog.normalizedName(name))
    }

    /// The saved alternate for `name`, as stored; nil when none is saved.
    public func alternate(for name: String) -> String? {
        alternateKeys[WorkoutExerciseCatalog.normalizedName(name)]
    }

    // MARK: - Editing

    /// Adds `name` to the hidden list. Returns false — and changes nothing — for an empty or over-long
    /// name, or when the list is full; hiding an exercise that is already hidden succeeds unchanged.
    @discardableResult
    public mutating func hide(_ name: String) -> Bool {
        guard let stored = Self.storedName(name) else { return false }
        guard !isHidden(stored) else { return true }
        guard hidden.count < Self.maxHidden else { return false }
        hidden.append(stored)
        return true
    }

    /// Takes `name` off the hidden list ("Show again").
    public mutating func showAgain(_ name: String) {
        let key = WorkoutExerciseCatalog.normalizedName(name)
        guard !key.isEmpty else { return }
        hidden.removeAll { WorkoutExerciseCatalog.normalizedName($0) == key }
    }

    /// Saves `alternate` as the exercise to use whenever `original` would be picked, replacing any
    /// alternate saved for it. Pairing an exercise with itself removes its pairing instead. Returns
    /// false — and changes nothing — for an empty or over-long name, or when the list is full.
    @discardableResult
    public mutating func setAlternate(_ alternate: String, for original: String) -> Bool {
        guard let from = Self.storedName(original), let to = Self.storedName(alternate) else { return false }
        guard WorkoutExerciseCatalog.normalizedName(from) != WorkoutExerciseCatalog.normalizedName(to) else {
            removeAlternate(for: from)
            return true
        }
        let isNew = self.alternate(for: from) == nil
        guard !isNew || alternates.count < Self.maxAlternates else { return false }
        removeAlternate(for: from)
        alternates[from] = to
        return true
    }

    /// Forgets the alternate saved for `original`.
    public mutating func removeAlternate(for original: String) {
        let key = WorkoutExerciseCatalog.normalizedName(original)
        guard !key.isEmpty else { return }
        for stored in alternates.keys.sorted() where WorkoutExerciseCatalog.normalizedName(stored) == key {
            alternates[stored] = nil
        }
    }

    /// Follows a renamed exercise (a custom exercise edited in the form): its hidden entry and every
    /// pairing that names it, on either side, now name `new`.
    public mutating func renameExercise(from old: String, to new: String) {
        let oldKey = WorkoutExerciseCatalog.normalizedName(old)
        guard let stored = Self.storedName(new), !oldKey.isEmpty else { return }
        let wasHidden = isHidden(old)
        showAgain(old)
        if wasHidden { hide(stored) }
        var renamed: [String: String] = [:]
        for (from, to) in alternates {
            let newFrom = WorkoutExerciseCatalog.normalizedName(from) == oldKey ? stored : from
            let newTo = WorkoutExerciseCatalog.normalizedName(to) == oldKey ? stored : to
            renamed[newFrom] = newTo
        }
        alternates = Self.sanitizedAlternates(renamed)
    }

    /// Drops every mention of `name` — its hidden entry and each pairing it is part of — for an
    /// exercise that no longer exists (a deleted custom exercise).
    public mutating func forgetExercise(named name: String) {
        let key = WorkoutExerciseCatalog.normalizedName(name)
        guard !key.isEmpty else { return }
        showAgain(name)
        alternates = alternates.filter {
            WorkoutExerciseCatalog.normalizedName($0.key) != key && WorkoutExerciseCatalog.normalizedName($0.value) != key
        }
    }

    // MARK: - Tolerant decoding

    /// The hidden list from its synced value: the strings of a JSON array, trimmed, deduped and
    /// bounded. Anything else — no key, another shape, a non-string entry, an over-long name — is
    /// skipped, never thrown on, so a newer build's richer entries cannot fail this build's decode.
    public static func hiddenNames(from value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        let names: [String] = items.prefix(maxDecodedEntries).compactMap { item in
            guard case .string(let name) = item else { return nil }
            return name
        }
        return sanitizedHidden(names)
    }

    /// The saved alternates from their synced value: the string-to-string pairs of a JSON object,
    /// bounded, with self-pairs and over-long names skipped. Any other shape decodes as none.
    public static func alternates(from value: JSONValue?) -> [String: String] {
        guard case .object(let entries)? = value else { return [:] }
        var pairs: [String: String] = [:]
        for key in entries.keys.sorted().prefix(maxDecodedEntries) {
            guard case .string(let alternate)? = entries[key] else { continue }
            pairs[key] = alternate
        }
        return sanitizedAlternates(pairs)
    }

    /// `raw` trimmed, or nil when it is empty or longer than ``maxNameCharacters``.
    public static func storedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxNameCharacters else { return nil }
        return trimmed
    }

    /// Names trimmed, deduped by comparison key (first spelling wins) and capped at ``maxHidden``.
    static func sanitizedHidden(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var kept: [String] = []
        for raw in names.prefix(maxDecodedEntries) {
            guard kept.count < maxHidden else { break }
            guard let name = storedName(raw), seen.insert(WorkoutExerciseCatalog.normalizedName(name)).inserted else {
                continue
            }
            kept.append(name)
        }
        return kept
    }

    /// Pairs trimmed, with self-pairs and duplicate originals dropped (first in key order wins) and
    /// capped at ``maxAlternates``.
    static func sanitizedAlternates(_ pairs: [String: String]) -> [String: String] {
        var seen: Set<String> = []
        var kept: [String: String] = [:]
        for raw in pairs.keys.sorted().prefix(maxDecodedEntries) {
            guard kept.count < maxAlternates else { break }
            guard let from = storedName(raw), let to = storedName(pairs[raw] ?? "") else { continue }
            let key = WorkoutExerciseCatalog.normalizedName(from)
            guard key != WorkoutExerciseCatalog.normalizedName(to), seen.insert(key).inserted else { continue }
            kept[from] = to
        }
        return kept
    }
}

/// The exercises the plan editor offers when a lift is swapped — Hevy-style, up to four that can
/// really stand in for it.
///
/// A stand-in does the same kind of work: the same modality and movement pattern, a compatible plane
/// (either side `nil` matches) and at least one shared primary muscle. Candidates come in already
/// filtered for the location's equipment, the injury limits and the hidden list (the editor passes
/// the planner's own feasible pool), so a swap never offers something the planner would not.
/// Ranked by muscle fit, then by closeness of difficulty, then by name. Pure and deterministic.
public nonisolated enum WorkoutExerciseSwapOptions {
    /// How many options the editor shows.
    public static let defaultLimit = 4

    /// Up to `limit` stand-ins for `original` from `candidates`, leaving out `original` itself and any
    /// name in `excluding` (the session's other exercises).
    public static func options(
        for original: ExerciseTarget,
        in candidates: [ExerciseTarget],
        excluding names: Set<String> = [],
        limit: Int = defaultLimit
    ) -> [ExerciseTarget] {
        guard limit > 0 else { return [] }
        let excluded = Set(names.map(WorkoutExerciseCatalog.normalizedName))
            .union([WorkoutExerciseCatalog.normalizedName(original.name)])
        let ranked = candidates
            .filter { !excluded.contains(WorkoutExerciseCatalog.normalizedName($0.name)) && canStandIn($0, for: original) }
            .map { (exercise: $0, score: score($0, for: original)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.exercise.name < rhs.exercise.name
            }
        return ranked.prefix(limit).map { $0.exercise }
    }

    /// Whether `candidate` does the same kind of work as `original` (see the type's note).
    public static func canStandIn(_ candidate: ExerciseTarget, for original: ExerciseTarget) -> Bool {
        guard candidate.modality == original.modality, candidate.movementPattern == original.movementPattern else {
            return false
        }
        if let own = candidate.plane, let theirs = original.plane, own != theirs { return false }
        return !candidate.primaryMuscles.isDisjoint(with: original.primaryMuscles)
    }

    /// Muscle fit (shared primaries count most, extra primaries cost a little) minus the difficulty gap.
    static func score(_ candidate: ExerciseTarget, for original: ExerciseTarget) -> Int {
        let shared = candidate.primaryMuscles.intersection(original.primaryMuscles).count * 40
        let secondary = candidate.secondaryMuscles.intersection(original.secondaryMuscles).count * 8
        let offTarget = candidate.primaryMuscles.subtracting(original.primaryMuscles).count * 8
        let gap = abs(candidate.difficulty.rawValue - original.difficulty.rawValue) * 10
        return shared + secondary - offTarget - gap
    }
}
