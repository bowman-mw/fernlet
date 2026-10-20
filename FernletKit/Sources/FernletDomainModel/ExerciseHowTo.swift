// ExerciseHowTo.swift
// FernletDomainModel — the bundled how-to text for every catalog exercise, and the one lookup that
// draws an exercise's FROZEN catalog name in the user's language.
//
// The text itself lives in the six `ExerciseHowTo+<Family>.swift` files beside this one, one computed
// property per exercise, each string a `String(localized:bundle: .module)` key under
// `exercise.<keyStem>.` in this module's Localizable.xcstrings.

import Foundation

/// How to do one catalog exercise: its display name, three to five short cues, one common mistake
/// and one easier version, all localized.
///
/// Keyed by ``name``, the FROZEN catalog name (``ExerciseTarget/name``), which is never translated:
/// plans, logs, history, progression keys, exports, AI prompts and the coach-plan wire all carry it.
/// ``displayName`` is the only half a screen draws. In English the two are the same text today; a
/// translation changes only ``displayName``. Every string resolves against this module's catalog
/// under `exercise.<keyStem>.` (`.name`, `.cue1`…`.cue5`, `.mistake`, `.easier`), where
/// ``keyStem`` is ``name`` in lower camel case ("Farmer's carry" → `farmersCarry`).
///
/// Stretches and timed holds also say where the stretch or effort is felt and how to breathe. The one
/// safety line ("stop if you feel sharp pain") belongs to the sheet that shows this, not to each
/// entry. Display only: nothing persists, exports, prompts with or matches against these strings.
public nonisolated struct ExerciseHowTo: Equatable, Sendable {
    /// The frozen catalog name this entry belongs to. Never localized.
    public let name: String
    /// The stem of every catalog key this entry resolves (`exercise.<keyStem>.cue1`).
    public let keyStem: String
    /// The name a screen draws for the exercise, in the user's language.
    public let displayName: String
    /// Three to five short setup and execution cues, in the order they happen.
    public let cues: [String]
    /// The one common mistake to watch for.
    public let mistake: String
    /// One easier version (for a stretch, a gentler one).
    public let easier: String
}

/// The bundled how-to entries, keyed by frozen catalog name, and the display-name lookup.
///
/// The ONE place a frozen exercise name becomes the name a screen draws (``displayName(for:)``): the
/// plan card, the guided runner and its spoken transitions, the editor, exercise history, the
/// pickers, and the Live Activity (through the name the app bakes into the run state). The engine,
/// logs, history keys, exports, AI prompts and wire formats keep the frozen name, so a translated
/// display name can never re-identify an exercise or orphan its progression.
///
/// Matching is EXACT on the frozen spelling, like `StoredWorkoutName`: a name the user typed
/// differently ("bench press") is the user's own text and draws as typed, and a custom exercise
/// draws its own name. The table resolves once per process, on first use; the process restarts when
/// the device language changes, so it never holds a stale language.
public nonisolated enum ExerciseHowToCatalog {
    /// The fewest cues an entry carries.
    public static let minCues = 3
    /// The most cues an entry carries.
    public static let maxCues = 5

    /// Every entry, in the bundled catalog's order within each family.
    public static var allEntries: [ExerciseHowTo] {
        pushEntries + pullEntries + legEntries + coreEntries + conditioningEntries + stretchEntries
    }

    /// The entries by frozen name, resolved once. A duplicate name keeps its first entry (a test pins
    /// that there is none) rather than trapping.
    private static let entriesByName: [String: ExerciseHowTo] = Dictionary(
        allEntries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    /// The how-to entry for the exercise stored as `name`, or nil when the catalog has none (a custom
    /// exercise, a cardio descriptor line, a name typed another way).
    public static func entry(for name: String) -> ExerciseHowTo? {
        guard !name.isEmpty else { return nil }
        return entriesByName[name]
    }

    /// The name a screen draws for an exercise stored as `name`: its localized display name when
    /// `name` is a bundled catalog name, else `name` unchanged. Display only — never persist, export,
    /// prompt with or match against what this returns.
    public static func displayName(for name: String) -> String {
        entriesByName[name]?.displayName ?? name
    }
}

extension ExerciseTarget {
    /// The name a screen draws for this exercise (``ExerciseHowToCatalog/displayName(for:)``). Display
    /// only: matching, storage and prompts keep ``name``.
    public var displayName: String { ExerciseHowToCatalog.displayName(for: name) }
}

extension PrescribedExercise {
    /// The name a screen draws for this step (``ExerciseHowToCatalog/displayName(for:)``). Display
    /// only: the plan text, the log and the progression keys keep ``name``.
    public var displayName: String { ExerciseHowToCatalog.displayName(for: name) }

    /// ``line`` with the step's ``displayName`` in place of its frozen name, for screens only. ``line``
    /// is the plan text the logged row stores and the history parser reads back, so it keeps the
    /// frozen name; this is never stored.
    public var displayLine: String { planLine(naming: displayName) }
}
