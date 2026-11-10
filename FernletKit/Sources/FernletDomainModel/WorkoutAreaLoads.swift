// WorkoutAreaLoads.swift
// FernletDomainModel
//
// The reviewed record of which body areas each bundled exercise loads (2026-11-10).
//
// The muscle tags, movement patterns and spine rule in WorkoutInjury.swift cannot see how an exercise
// is held: a push-up puts the body's weight on the wrists, a pull-up hangs from the shoulders, a
// barbell row bends the lower back under a bar, and none of those is a muscle the row is tagged with.
// So every row of `WorkoutExercises.json` carries an explicit `areaLoads` map, area token → load
// token, judged the way a careful strength coach would (when unsure, the load is recorded):
// - `hard`: the area bears the load unsupported — body weight on the hands, a hang, a heavy bar, a
//   jump. Left out for a mild area and for a severe one.
// - `light`: the area is loaded lightly or with support — a guided machine, a cable, a light
//   dumbbell, a stretch. Kept for a mild area, left out for a severe one.
// - no entry: the exercise does not load the area.
// A sibling `areaLoadNotes` map gives one phrase of reasoning per entry. It is review material (the
// owner's per-area listing is generated from it); the app never decodes or shows it.
//
// The record only ever adds to the older rules, which stay as the floor (``InjuryLimits``). An
// exercise with no record — a person's or a coach's own — gets the older rules alone, never "loads
// nothing". `ExerciseAreaLoadTests` pins that every bundled row has a record, that the record never
// says less than the floor, and what each area keeps.
//
// The tokens are FROZEN catalogue vocabulary (the localization wall): never shown, never translated.

import Foundation
import FernletFoundation

/// How much an exercise loads a body area. FROZEN tokens (the catalogue's `areaLoads` values).
public nonisolated enum AreaLoad: String, Codable, CaseIterable, Sendable {
    /// Loaded lightly or with support: kept for a mild area, left out for a severe one.
    case light
    /// Loaded hard and unsupported: left out for a mild area and for a severe one.
    case hard
}

/// The reviewed record for one bundled exercise: each body area it loads, and how hard.
///
/// An area with no entry is not loaded. An exercise with no record at all is a different thing —
/// it was never reviewed, and ``InjuryLimits`` falls back to the muscle and pattern rules for it.
public nonisolated struct ExerciseAreaLoads: Equatable, Sendable {
    /// The areas the exercise loads. An area that is absent is not loaded.
    public var loads: [BodyArea: AreaLoad]

    public init(_ loads: [BodyArea: AreaLoad] = [:]) {
        self.loads = loads
    }

    /// The record for a catalogue row's `areaLoads` map. An area token this build does not know is
    /// skipped; a load token it does not know on an area it does reads as ``AreaLoad/hard`` — the
    /// safe direction, as an unknown severity reads as severe.
    public init(tokens: [String: String]) {
        var loads: [BodyArea: AreaLoad] = [:]
        for (key, value) in tokens {
            guard let area = BodyArea(rawValue: key) else { continue }
            loads[area] = AreaLoad(rawValue: value) ?? .hard
        }
        self.loads = loads
    }

    /// How hard the exercise loads `area`, or nil when it does not load it.
    public func load(on area: BodyArea) -> AreaLoad? {
        loads[area]
    }
}

extension WorkoutExerciseCatalog {
    /// The reviewed records of the bundled catalogue, keyed by ``normalizedName(_:)``. Computed once;
    /// empty where the hosting bundle carries no catalogue (the extensions), as ``baseExercises`` is.
    static let bundledAreaLoads: [String: ExerciseAreaLoads] = loadAreaLoads()

    /// The reviewed record for `exercise`, or nil when it has none: a person's or a coach's own
    /// exercise, or a bundled row that shipped without one (`ExerciseAreaLoadTests` fails on that).
    ///
    /// Looked up by the frozen name — the exercise's identity — so a copy of a bundled exercise
    /// that was decoded from a saved plan or built by hand resolves to the same record.
    public static func areaLoads(for exercise: ExerciseTarget) -> ExerciseAreaLoads? {
        bundledAreaLoads[normalizedName(exercise.name)]
    }

    /// The part of a catalogue row this file reads. ``ExerciseTarget`` decodes the rest of the same
    /// row and ignores these keys, so its persisted shape (custom exercises, coach plans) is unchanged.
    private struct AreaLoadRow: Decodable {
        let name: String
        let areaLoads: [String: String]?
    }

    /// The name → record table for the catalogue's JSON. A row without an `areaLoads` key has no
    /// record (an empty map is a record: "reviewed, loads nothing").
    static func areaLoadTable(from data: Data) throws -> [String: ExerciseAreaLoads] {
        let rows = try JSONDecoder().decode([AreaLoadRow].self, from: data)
        var table: [String: ExerciseAreaLoads] = [:]
        for row in rows {
            guard let tokens = row.areaLoads else { continue }
            table[normalizedName(row.name)] = ExerciseAreaLoads(tokens: tokens)
        }
        return table
    }

    private static func loadAreaLoads() -> [String: ExerciseAreaLoads] {
        // Absent is legitimate and silent, unreadable is logged — the same contract as the
        // catalogue's own load. Either way the planner falls back to the muscle and pattern rules.
        guard let url = Bundle.main.url(forResource: "WorkoutExercises", withExtension: "json") else {
            return [:]
        }
        do {
            return try areaLoadTable(from: Data(contentsOf: url))
        } catch {
            FernletAuditLog.log("workout.catalog.areaLoads.failed",
                                context: ["error": error.localizedDescription])
            return [:]
        }
    }
}
