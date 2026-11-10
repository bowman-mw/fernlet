// WorkoutAssistedLifts.swift
// FernletDomainModel
//
// Assisted machines (w3, 2026-11-10). On an assisted pull-up or assisted dip machine the number on the
// stack is HELP: the machine lifts that much of the person, so a bigger number is an easier set. The
// load engine read it as load and progressed backwards — a good session added help under "add weight
// now", two misses took help away under "a little lighter".
//
// This file is the one place that says which lifts are assisted. Everything else asks
// ``contains(_:)`` once, where a session or a plan is built, and carries the answer as a flag
// (``LiftExposure/assisted``, ``WorkoutLoadEngine/LiftInputs/assisted``, ``LiftPlan/assisted``): no
// other file tests a name.
//
// What the flag turns round:
// - the step — a completed top-of-range session takes a little help away, never adds it
//   (``WorkoutLoadEngine/helpMoved(_:by:step:ladder:)``);
// - the miss back-off — two misses in a row give a little help back;
// - the cap — the least help the machine gives is the end of the road, where reps, one more set and
//   then the unassisted lift take over (``LoadCap/leastHelp(bottom:)``);
// - the words — "less help" and "more help", never "add weight" or "lighter";
// - the estimate — the help number is no one-rep max, so the engine keeps none for these lifts (no
//   strength check, no heavier block, no warm-up ramp: half the help is a harder set, not a warm-up);
// - the trend — a session scores on the load actually moved, body weight less the help
//   (``effectiveLoad(help:unit:bodyWeightKg:)``), so less help reads as stronger and a stall or a dip
//   is called the right way up.

import Foundation

/// Which lifts are done on an assisted machine, where the weight is help, and how their sessions
/// score.
public nonisolated enum WorkoutAssistedLifts {

    /// The assisted lifts, by ``WorkoutExerciseCatalog/normalizedName(_:)``. FROZEN tokens: they match
    /// the catalogue's own frozen names (`WorkoutExercises.json`), which logged rows are saved under.
    /// Both are `machine` rows. A band-assisted pull-up is not here: a band has no number to step, so
    /// it progresses on reps like any unloaded lift. `WorkoutAssistedLiftTests` holds this list to the
    /// catalogue: every name must be a machine row, and every machine row named "Assisted …" must be
    /// listed.
    public static let names: Set<String> = ["assisted pull-up", "assisted dip"]

    /// Whether `name` (any spelling the catalogue's normalization accepts) is an assisted lift.
    public static func contains(_ name: String) -> Bool {
        names.contains(WorkoutExerciseCatalog.normalizedName(name))
    }

    /// The body weight the trend assumes when the person's is not known, in kilograms. Only the
    /// direction and rough size of a change depend on it, never a prescription.
    public static let referenceBodyWeightKg = 75.0
    /// The least a session's moved load is read as, in kilograms: help at or above body weight still
    /// scores, just above nothing, so the score stays positive for the trend's logarithm.
    public static let minimumEffectiveLoadKg = 2.5

    /// The load actually moved on an assisted machine, in `unit`: body weight less the help, never
    /// under ``minimumEffectiveLoadKg``. `help` is in `unit`; `bodyWeightKg` nil (or not a plausible
    /// weight) reads as ``referenceBodyWeightKg``.
    public static func effectiveLoad(help: Double, unit: LoadUnit, bodyWeightKg: Double?) -> Double {
        let known = bodyWeightKg.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? referenceBodyWeightKg
        let body = unit.converted(known, from: .kg)
        let floor = unit.converted(minimumEffectiveLoadKg, from: .kg)
        guard help.isFinite else { return floor }
        return max(floor, body - max(0, help))
    }
}
