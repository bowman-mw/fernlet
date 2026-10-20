// WorkoutPlanRun.swift
// FernletDomainModel
//
// Comparison report idea 17 (2026-10-20): a planned workout — one the person planned ahead in the plan
// sheet, or one a coach's plan put on the calendar through the coach exchange — runs in the guided
// runner, as written. The app reads each line with its line parser and hands the pieces here; this
// file decides what each line becomes: sets × reps, a timed hold, a timed cardio or mobility line (left
// as a descriptor for `WorkoutTimedSessions.expand(_:feasible:)` to time when the run starts), or a
// plain "mark done" step that shows the line itself.
//
// Nothing is filtered or dropped: a coach's plan passed its review at import, and the person's own
// lines run as entered. The load engine only fills in what the line left out — a weight for a catalog
// lift whose line named none. A weight the line names is preselected as written.

import Foundation

/// Turns a planned workout's lines into guided-runner steps, run as written.
public nonisolated enum WorkoutPlanRun {

    /// The most lines a plan may have and still be guided. A longer plan is logged, not guided, so a
    /// run never leaves one of its lines out.
    public static let maximumLines = 60

    /// One plan line as the app's line parser read it ("Bench press - 3 x 8 @ 135 lb").
    public struct ParsedLine: Equatable, Sendable {
        /// The exercise as the line names it.
        public var name: String
        /// Sets as written, at least one.
        public var sets: Int
        /// The reps as written ("8", "8-12"); for a hold, the hold's text ("30 s").
        public var reps: String
        /// Seconds each set is held, for a timed line ("Plank - 3 x 30 s"); nil for a counted one.
        public var holdSeconds: Int?
        /// The weight the line names, if it names one.
        public var weight: Double?
        /// The weight's unit, when the line says it.
        public var unit: LoadUnit?

        /// Creates a parsed line.
        public init(name: String, sets: Int, reps: String, holdSeconds: Int? = nil, weight: Double? = nil, unit: LoadUnit? = nil) {
            self.name = name
            self.sets = sets
            self.reps = reps
            self.holdSeconds = holdSeconds
            self.weight = weight
            self.unit = unit
        }
    }

    /// One runner step built from a plan line, and what the runner shows beside it.
    public struct Step: Equatable {
        /// The step itself.
        public var exercise: PrescribedExercise
        /// The plan line it was built from, exactly as written (trimmed).
        public var line: String
        /// ``line`` when it says more than the step shows on its own — a coach's cue ("(RPE 7)", "each
        /// side"), or simply another spelling. Nil when the step reproduces it, and for a step that is
        /// the line itself (one marked done, or a timed line).
        public var writtenLine: String?
        /// The line named its own weight: the runner preselects it as written, with no range around it.
        public var weightAsWritten: Bool

        /// Creates a step.
        public init(exercise: PrescribedExercise, line: String, writtenLine: String? = nil, weightAsWritten: Bool = false) {
            self.exercise = exercise
            self.line = line
            self.writtenLine = writtenLine
            self.weightAsWritten = weightAsWritten
        }
    }

    // MARK: One line

    /// The step for one plan line.
    ///
    /// - A line the runner can time (``WorkoutTimedSessions/classify(_:)``: steady or interval cardio, a
    ///   mobility flow, gentle stretching) stays a descriptor, so the run's start expands it as it does
    ///   for the app's own sessions. It is checked first: "Intervals - 8 × 1 min hard / 1 min easy" also
    ///   looks like 8 sets of 1 rep to a line parser.
    /// - A parsed line becomes its sets × reps (or its timed hold), under the catalog's own name when the
    ///   catalog knows the exercise. A catalog lift gets load guidance: the weight as written when the
    ///   line names one, else the load engine's suggestion from the lift's own history.
    /// - Anything else becomes a "mark done" step whose name is the line itself.
    ///
    /// `catalog` defaults to every exercise the app knows (the bundled catalog and the person's own).
    public static func step(
        for text: String, parsed: ParsedLine?, location: WorkoutLocation, load: WorkoutLoadContext,
        catalog: [ExerciseTarget]? = nil
    ) -> Step {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkoutTimedSessions.classify(line) == nil, let parsed, parsed.sets >= 1 else {
            return Step(exercise: markDone(line), line: line)
        }
        let rows = catalog ?? WorkoutExerciseCatalog.allExercises
        let key = WorkoutExerciseCatalog.normalizedName(parsed.name)
        let target = rows.first { WorkoutExerciseCatalog.normalizedName($0.name) == key }
        return counted(line, parsed: parsed, target: target, location: location, load: load)
    }

    /// A line the runner walks as one step that is simply marked done: no sets, nothing counted.
    static func markDone(_ line: String) -> PrescribedExercise {
        PrescribedExercise(name: line, sets: 0, reps: "", role: .accessory, fromCatalog: false)
    }

    /// A parsed line's sets × reps (or hold), with its load guidance and its written line.
    ///
    /// `fromCatalog` is the runner's "counted step" flag (set strip, Set and Reps pills, rest between
    /// sets), so every parsed line carries it, a coach's own exercise name included.
    static func counted(
        _ line: String, parsed: ParsedLine, target: ExerciseTarget?, location: WorkoutLocation, load: WorkoutLoadContext
    ) -> Step {
        let sets = min(max(1, parsed.sets), ExerciseResult.maxSets)
        let hold = parsed.holdSeconds.flatMap { $0 > 0 ? $0 : nil }
        var exercise = PrescribedExercise(
            name: target?.name ?? parsed.name, sets: sets,
            reps: hold.map { PrescribedExercise.holdText(seconds: $0) } ?? parsed.reps,
            role: role(for: target), fromCatalog: true, holdSeconds: hold
        )
        var asWritten = false
        if hold == nil {
            if let weight = parsed.weight, weight > 0, weight <= ExerciseResult.maxWeight {
                exercise.guidance = writtenGuidance(weight: weight, unit: parsed.unit, reps: parsed.reps,
                                                    target: target, location: location, load: load)
                asWritten = true
            } else if let target {
                exercise.guidance = engineGuidance(for: target, reps: parsed.reps, sets: sets, location: location, load: load)
            }
        }
        return Step(exercise: exercise, line: line, writtenLine: writtenLine(line, parsed: parsed), weightAsWritten: asWritten)
    }

    /// A plan line's role, which sets its rest (``WorkoutRestGuidance``): trunk work is core, a squat or
    /// a hinge is a main lift, everything else an accessory — the rule the in-app editor uses for an
    /// exercise added by hand, since a written plan names no slot.
    static func role(for target: ExerciseTarget?) -> SlotRole {
        guard let target else { return .accessory }
        if target.bodyRegion == .core { return .core }
        if target.movementPattern == .squat || target.movementPattern == .hinge { return .main }
        return .accessory
    }

    // MARK: Load

    /// The weight a line names, preselected as written: one fixed weight (no range, no confidence), on
    /// the lift's own equipment step, or a barbell's when the lift's gear takes no plates (a weighted
    /// pull-up) or the catalog does not know it. A line with no unit takes the lift's last logged unit,
    /// else the person's default.
    static func writtenGuidance(
        weight: Double, unit: LoadUnit?, reps: String, target: ExerciseTarget?, location: WorkoutLocation,
        load: WorkoutLoadContext
    ) -> LoadGuidance {
        let equipment = target.flatMap { WorkoutProgram.loadEquipment(for: $0, at: location) }
        let history = target.map { load.history(for: $0.name) } ?? []
        let weighed = unit ?? load.unit(for: history)
        let step = equipment.flatMap { WorkoutLoadEngine.step(for: $0, unit: weighed) }
            ?? WorkoutLoadEngine.step(for: .barbell, unit: weighed) ?? 5
        let fixed = WeightPrescription(
            low: weight, high: weight, suggested: weight, step: step, unit: weighed, confidence: EstimateConfidence.none
        )
        return LoadGuidance(targetReps: RepScheme(reps)?.low ?? 1, prescription: fixed, equipment: equipment, unit: weighed)
    }

    /// The load engine's guidance for a catalog lift whose line named no weight — the same engine the
    /// app's own sessions use, reading the lift's history, but for the sets and reps as written: only the
    /// weight (and, for a written range like "8-12", where in it to aim) comes from the engine. Nil for a
    /// timed exercise, a cardio or stretch row, and reps the engine cannot read ("AMRAP"). `inventory`
    /// snaps the weight onto loads the location has (the re-run after "Adjust with AI" passes the
    /// location's weights; a planned line's run passes none, as before).
    static func engineGuidance(
        for target: ExerciseTarget, reps: String, sets: Int, location: WorkoutLocation, load: WorkoutLoadContext,
        inventory: WorkoutWeightInventory? = nil
    ) -> LoadGuidance? {
        guard target.measure != .seconds, target.modality == .strength || target.modality == .power,
              let scheme = RepScheme(reps) else { return nil }
        let equipment = WorkoutProgram.loadEquipment(for: target, at: location)
        let history = load.history(for: target.name)
        guard !history.isEmpty else {
            return LoadGuidance(targetReps: scheme.low, equipment: equipment, unit: load.defaultUnit)
        }
        let plan = WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
            scheme: scheme, baseSets: sets, exposures: history, equipment: equipment,
            isLowerBody: WorkoutLoadEngine.isLowerBody(target.movementPattern),
            defaultUnit: load.defaultUnit, today: load.today, inventory: inventory
        ))
        return LoadGuidance(
            targetReps: plan.reps, prescription: plan.prescription, equipment: equipment, unit: plan.unit,
            askReasonOnOverride: plan.askReasonOnOverride
        )
    }

    // MARK: The line as written

    /// `line` when it says more than its step shows — a cue, a different spelling — else nil.
    ///
    /// Compared without case, spaces or separators against the forms a step reads as ("Bench press - 3 x
    /// 8 @ 135 lb", "Plank - 45 s"), so "Squat 5x5 @225lb" and "Squat - 5 x 5 @ 225 lb" are one line,
    /// while "Bench press - 3 x 8 (RPE 7)" keeps its cue on screen.
    static func writtenLine(_ line: String, parsed: ParsedLine) -> String? {
        let load = parsed.weight.map { weight in
            " @ \(WorkoutLoadEngine.weightText(weight))" + (parsed.unit.map { " \($0.rawValue)" } ?? "")
        } ?? ""
        var forms = ["\(parsed.name) - \(parsed.sets) x \(parsed.reps)\(load)"]
        if parsed.sets == 1 { forms.append("\(parsed.name) - \(parsed.reps)\(load)") }
        let written = comparable(line)
        return forms.contains { comparable($0) == written } ? nil : line
    }

    /// A line reduced for comparison: lowercased, "×" as "x", "lbs"/"kgs" as "lb"/"kg", and no spaces or
    /// separators.
    static func comparable(_ text: String) -> String {
        let dropped: Set<Character> = ["-", "–", "—", ":", ","]
        let squeezed = String(text.lowercased().filter { !$0.isWhitespace && !dropped.contains($0) })
        return squeezed
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "lbs", with: "lb")
            .replacingOccurrences(of: "kgs", with: "kg")
    }
}
