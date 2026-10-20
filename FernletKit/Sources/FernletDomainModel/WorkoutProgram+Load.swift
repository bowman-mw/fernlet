// WorkoutProgram+Load.swift
// FernletDomainModel
//
// Where the load engine meets the day plan. After the lifting slots are filled, each rep-counted lift
// gets its next prescription from its own history (``WorkoutLoadEngine``), a lift whose trend has
// stalled walks the plateau ladder and a dipping one gets a deload (``WorkoutPlateau``, 2026-10-20),
// and about once a month the main lift becomes a calibration (``WorkoutCalibration``). The session
// note says what changed and why, in plain words. Where the location has its weights set
// (``WorkoutLocation/weights``), every weight here — the prescription, the heavier block, the
// deload's kept load and the calibration's sets — is a load it has.
//
// The note sentences are String Catalog keys in ``WorkoutPlannerCopy`` (2026-10-20, idea 16), composed
// in the device's language when the plan is built; the plan TEXT (exercise names, sets and reps) stays
// the frozen English the history parser reads.

import Foundation

/// Everything the planner needs to prescribe loads: each lift's logged sessions (with their sleep and
/// readiness flags), today, the unit to fall back on, recent protein, and the calibration state. Built
/// by the app from the day history.
public nonisolated struct WorkoutLoadContext: Sendable {
    /// Sessions per lift, keyed by ``WorkoutExerciseCatalog/normalizedName(_:)``, oldest first.
    public var exposures: [String: [LiftExposure]]
    public var today: Date
    public var defaultUnit: LoadUnit
    public var recovery: RecoverySummary
    public var calibration: CalibrationSettings
    /// Warm-up sets before heavy main lifts are on (``WorkoutWarmUpSets/isEnabled(preference:experience:)``,
    /// resolved by the app from the setting and the lifter's level). Off by default here, so a context
    /// built without saying so plans exactly as before.
    public var warmUpSets: Bool
    /// The person's age, sex and body weight, which nudge each lift's expected curve (G9: a
    /// long-trained lifter over 60 expects a steady line). Unknown by default.
    public var traits: LifterTraits

    public init(
        exposures: [String: [LiftExposure]], today: Date, defaultUnit: LoadUnit,
        recovery: RecoverySummary = .unknown, calibration: CalibrationSettings = CalibrationSettings(),
        warmUpSets: Bool = false, traits: LifterTraits = .unknown
    ) {
        self.exposures = exposures
        self.today = today
        self.defaultUnit = defaultUnit
        self.recovery = recovery
        self.calibration = calibration
        self.warmUpSets = warmUpSets
        self.traits = traits
    }

    /// One lift's sessions, oldest first.
    public func history(for name: String) -> [LiftExposure] {
        exposures[WorkoutExerciseCatalog.normalizedName(name)] ?? []
    }

    /// The unit a lift was last logged in, or the fallback.
    func unit(for history: [LiftExposure]) -> LoadUnit {
        history.last(where: { $0.unit != nil })?.unit ?? defaultUnit
    }
}

extension WorkoutProgram {

    /// One lifting pick on its way through the load pass.
    struct LoadedPick {
        var exercise: PrescribedExercise
        var target: ExerciseTarget
        var slot: WorkoutSlotSpec
        var plateau: PlateauStatus?
        /// Set on a variant: the stalled lift it joins (``PlateauStage/variant``).
        var variantOf: String?
        var plan: LiftPlan?
    }

    /// The slot a plateau variant fills beside its lift: frozen like every slot label, drawn through
    /// ``WorkoutSlotNames``, and never one of a template's main slots, so a time budget may trim it.
    static let variantSlotLabel = "Variant"

    /// The lifting block after the load pass, plus what the session note should say about it.
    /// `slots` runs parallel to `steps`: the slot each step fills, which the time budget reads to
    /// keep the main lifts.
    struct LoadPass {
        var steps: [PrescribedExercise]
        var targets: [ExerciseTarget]
        var notes: [String]
        var slots: [WorkoutSlotSpec] = []
    }

    /// Runs the load pass over a session's lifting picks.
    static func applyLoad(
        _ picks: [SlotPick], inputs: SlotInputs, load: WorkoutLoadContext,
        used: inout Set<String>, calibrationOpen: inout Bool
    ) -> LoadPass {
        var loaded = picks.map { pick in
            LoadedPick(exercise: pick.exercise, target: pick.target, slot: pick.slot,
                       plateau: plateauStatus(of: pick.target, load: load))
        }
        addVariant(&loaded, inputs: inputs, used: &used)
        for index in loaded.indices { plan(&loaded[index], inputs: inputs, load: load) }
        applyPlateauLoad(&loaded, inputs: inputs, load: load)
        let plateauNotes = plateauStory(loaded, inputs: inputs) ?? []
        var notes = progressNotes(loaded)
        if calibrationOpen, let calibration = expandCalibration(&loaded, inputs: inputs, load: load) {
            calibrationOpen = false
            notes = [calibration]
        }
        addWarmUpSets(&loaded, inputs: inputs, load: load)
        assignFatigueContext(&loaded)
        return LoadPass(steps: loaded.map(\.exercise), targets: loaded.map(\.target), notes: notes + plateauNotes,
                        slots: loaded.map(\.slot))
    }

    /// Puts warm-up sets in front of each heavy main lift (``WorkoutWarmUpSets``) when the lifter has
    /// them on and today isn't a light day. Runs after the calibration, so a lift the calibration
    /// already ramps into gets no second ramp; each warm-up is a copy of its lift's pick, so it shares
    /// the lift's slot, target and fatigue context.
    static func addWarmUpSets(_ loaded: inout [LoadedPick], inputs: SlotInputs, load: WorkoutLoadContext) {
        guard load.warmUpSets, inputs.intensity != .light else { return }
        var expanded: [LoadedPick] = []
        for pick in loaded {
            for step in WorkoutWarmUpSets.steps(for: pick.exercise, pattern: pick.target.movementPattern) {
                var warmUp = pick
                warmUp.exercise = step
                warmUp.plan = nil
                expanded.append(warmUp)
            }
            expanded.append(pick)
        }
        loaded = expanded
    }

    /// The trend status of a rep-counted lift (``WorkoutPlateau/status(of:unit:today:profile:levelKg:)``),
    /// nil for holds and lifts with no history. The lift's estimated max, in kilograms, lets the
    /// expected curve tell a strong lifter from a newer one.
    static func plateauStatus(of target: ExerciseTarget, load: WorkoutLoadContext) -> PlateauStatus? {
        guard target.measure != .seconds else { return nil }
        let history = load.history(for: target.name)
        guard !history.isEmpty else { return nil }
        let unit = load.unit(for: history)
        let levelKg = WorkoutLoadEngine.estimate(from: history, unit: unit, today: load.today)
            .map { LoadUnit.kg.converted($0.oneRepMax, from: unit) }
        let profile = TrendProfile(traits: load.traits, lowerBody: WorkoutLoadEngine.isLowerBody(target.movementPattern))
        return WorkoutPlateau.status(of: history, unit: unit, today: load.today, profile: profile, levelKg: levelKg)
    }

    /// The gear a lift is loaded with here: its own tool, else the first loadable alternative this
    /// location has; nil for bodyweight and band work.
    static func loadEquipment(for target: ExerciseTarget, at location: WorkoutLocation) -> Equipment? {
        ([target.equipment] + target.alternativeEquipment).first {
            location.has($0) && WorkoutLoadEngine.step(for: $0, unit: .lb) != nil
        }
    }

    /// The loads `location` has for a lift on `guidance`'s gear, in its unit; nil when the location's
    /// weights say nothing about that gear.
    static func loadLadder(for guidance: LoadGuidance, at location: WorkoutLocation) -> LoadLadder? {
        guidance.equipment.flatMap { location.weights.ladder(for: $0, in: guidance.unit) }
    }

    // MARK: Per-lift prescription

    /// Gives one rep-counted lift its next sets, reps and weight range from its own history. A lift
    /// with no history keeps the count-based ladder and gets guidance with no suggested weight, so the
    /// runner asks the lifter to pick one.
    static func plan(_ pick: inout LoadedPick, inputs: SlotInputs, load: WorkoutLoadContext) {
        guard pick.exercise.fromCatalog, pick.exercise.holdSeconds == nil,
              let scheme = RepScheme(inputs.style.reps(for: pick.slot.role)) else { return }
        let history = load.history(for: pick.target.name)
        let equipment = loadEquipment(for: pick.target, at: inputs.location)
        guard !history.isEmpty else {
            pick.exercise.guidance = LoadGuidance(
                targetReps: Int(pick.exercise.reps) ?? scheme.low, equipment: equipment, unit: load.defaultUnit
            )
            return
        }
        let plan = WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
            scheme: scheme, baseSets: inputs.style.adjustedSets(for: pick.slot.role, energy: inputs.intensity),
            exposures: history, equipment: equipment,
            isLowerBody: WorkoutLoadEngine.isLowerBody(pick.target.movementPattern),
            defaultUnit: load.defaultUnit, today: load.today, inventory: inputs.location.weights
        ))
        pick.exercise.sets = plan.sets
        pick.exercise.reps = "\(plan.reps)"
        pick.exercise.guidance = LoadGuidance(
            targetReps: plan.reps, prescription: plan.prescription, equipment: equipment, unit: plan.unit,
            askReasonOnOverride: plan.askReasonOnOverride
        )
        pick.plan = plan
    }

    /// Counts the compound lifts ahead of each pick — the fatigue context a result records.
    static func assignFatigueContext(_ loaded: inout [LoadedPick]) {
        let noncompound: Set<MovementPattern> = [.isolation, .twist, .locomotion]
        var compounds = 0
        var firstSeen: [String: Int] = [:]
        for index in loaded.indices {
            let name = loaded[index].exercise.name
            // A calibration's steps share one lift: every step carries the count from its first.
            if let before = firstSeen[name] {
                loaded[index].exercise.guidance?.compoundsBefore = before
                continue
            }
            loaded[index].exercise.guidance?.compoundsBefore = compounds
            firstSeen[name] = compounds
            if !noncompound.contains(loaded[index].target.movementPattern) { compounds += 1 }
        }
    }

    // MARK: Plateau response

    /// The variant step (``PlateauStage/variant``): the slot's next-best exercise joins the session's
    /// first lift on that step, right after it, at accessory volume. The lift itself stays — one set
    /// fewer (``applyPlateauLoad(_:inputs:load:)``), never removed — and the variant fills a slot of
    /// its own (``variantSlotLabel``), so a time budget may trim it but never the lift.
    static func addVariant(_ loaded: inout [LoadedPick], inputs: SlotInputs, used: inout Set<String>) {
        guard let index = loaded.firstIndex(where: { $0.plateau?.stage == .variant && $0.variantOf == nil }) else {
            return
        }
        let original = loaded[index]
        let slot = WorkoutSlotSpec(label: variantSlotLabel, role: .accessory, movement: original.slot.movement,
                                   plane: original.slot.plane, muscles: original.slot.muscles,
                                   region: original.slot.region)
        guard let variant = bestExercise(
            for: slot, in: inputs.feasible, excluding: used.union([original.target.name]),
            biasTokens: inputs.biasTokens, experience: inputs.profile.experience, location: inputs.location,
            limits: inputs.limits
        ) else { return }
        used.insert(variant.name)
        let exercise = prescribe(variant, role: .accessory, block: .lifting,
                                 completions: inputs.progression[variant.name] ?? 0, inputs: inputs)
        let pick = LoadedPick(exercise: exercise, target: variant, slot: slot, variantOf: original.target.name)
        loaded.insert(pick, at: index + 1)
    }

    /// The load side of the response, by step: the fair retest's rest (at least
    /// ``WorkoutPlateau/retestRestSeconds``), the loading change's heavier block, one set fewer on a
    /// lift beside its variant, and the dip's deload. Then the first lift on its retest moves to the
    /// front of the session.
    static func applyPlateauLoad(_ loaded: inout [LoadedPick], inputs: SlotInputs, load: WorkoutLoadContext) {
        for index in loaded.indices where loaded[index].variantOf == nil {
            guard let status = loaded[index].plateau else { continue }
            if status.state == .dipping {
                deload(&loaded[index], location: inputs.location)
                continue
            }
            switch status.stage {
            case .fairRetest?:
                fairRetest(&loaded[index], goal: inputs.goal)
            case .loadingChange?:
                heavierBlock(&loaded[index], inputs: inputs, load: load)
            case .variant?:
                let name = loaded[index].target.name
                if loaded.contains(where: { $0.variantOf == name }) {
                    let sets = loaded[index].exercise.sets
                    loaded[index].exercise.sets = max(min(sets, WorkoutPlateau.variantMainMinimumSets),
                                                      sets - WorkoutPlateau.variantMainSetDrop)
                }
            case .holdingSteady?, nil:
                break
            }
        }
        guard let first = loaded.firstIndex(where: { $0.plateau?.stage == .fairRetest && $0.plateau?.state == .stalled }),
              first > 0 else { return }
        loaded.insert(loaded.remove(at: first), at: 0)
    }

    /// The fair retest: at least three minutes between sets (more when the goal's own rest is longer).
    static func fairRetest(_ pick: inout LoadedPick, goal: GoalType) {
        let base = pick.exercise.restSecondsOverride ?? WorkoutRestGuidance.restSeconds(
            demand: WorkoutRestGuidance.demand(role: pick.slot.role, movementPattern: pick.target.movementPattern),
            goal: goal
        )
        pick.exercise.restSecondsOverride = WorkoutRestGuidance.clamp(max(base, WorkoutPlateau.retestRestSeconds))
    }

    /// The loading change: a short heavier block — ``WorkoutPlateau/heavierBlockRepDrop`` fewer reps
    /// (never under ``WorkoutPlateau/heavierBlockMinimumReps``) at the weight the estimate gives for
    /// them, on a load the location has. A lift with no load, or no estimate yet, gets one more set
    /// instead.
    static func heavierBlock(_ pick: inout LoadedPick, inputs: SlotInputs, load: WorkoutLoadContext) {
        guard var guidance = pick.exercise.guidance else { return }
        let reps = max(WorkoutPlateau.heavierBlockMinimumReps, guidance.targetReps - WorkoutPlateau.heavierBlockRepDrop)
        let history = load.history(for: pick.target.name)
        guard reps < guidance.targetReps, let current = guidance.prescription,
              let equipment = guidance.equipment, let step = WorkoutLoadEngine.step(for: equipment, unit: current.unit),
              let estimate = WorkoutLoadEngine.estimate(from: history, unit: current.unit, today: load.today) else {
            pick.exercise.sets += 1
            return
        }
        let weight = WorkoutLoadEngine.workingWeight(oneRepMax: estimate.oneRepMax, reps: reps, step: step)
        let ladder = loadLadder(for: guidance, at: inputs.location)
        guidance.targetReps = reps
        guidance.prescription = WorkoutLoadEngine.prescription(
            suggested: max(weight, current.suggested), confidence: current.confidence, step: step,
            unit: current.unit, ladder: ladder
        ) ?? current
        pick.exercise.reps = "\(reps)"
        pick.exercise.guidance = guidance
    }

    /// The dip's deload: half the sets (rounded up) with the load kept — the last working weight, on
    /// the location's nearest load when that is within ``WorkoutPlateau/deloadMaxDecrease`` of it — and
    /// flagged as an easier session, so it never anchors the next one or reads as the trend.
    static func deload(_ pick: inout LoadedPick, location: WorkoutLocation) {
        pick.exercise.sets = max(1, (pick.exercise.sets + 1) / 2)
        guard var guidance = pick.exercise.guidance else { return }
        guidance.easierSession = true
        if let current = guidance.prescription, let kept = pick.plan?.previousWeight, kept > 0 {
            let ladder = loadLadder(for: guidance, at: location)
            let step = guidance.equipment.flatMap { WorkoutLoadEngine.step(for: $0, unit: current.unit) } ?? current.step
            let placed = ladder?.nearest(to: kept) ?? WorkoutLoadEngine.rounded(kept, toStep: step)
            let weight = placed >= kept * (1 - WorkoutPlateau.deloadMaxDecrease) ? placed : current.suggested
            guidance.prescription = WorkoutLoadEngine.prescription(
                suggested: max(step, weight), confidence: current.confidence, step: step, unit: current.unit, ladder: ladder
            ) ?? current
        }
        pick.exercise.guidance = guidance
    }

    // MARK: Calibration

    /// Turns the session's main lift into this month's calibration when one is due, and takes a set
    /// off each accessory. Returns the note, or nil when nothing changed.
    static func expandCalibration(_ loaded: inout [LoadedPick], inputs: SlotInputs, load: WorkoutLoadContext) -> String? {
        guard WorkoutCalibration.isDue(load.calibration, intensity: inputs.intensity, today: load.today),
              let index = loaded.firstIndex(where: {
                  $0.slot.role == .main && $0.exercise.guidance?.isLoadable == true
                      && $0.exercise.guidance?.easierSession != true && $0.variantOf == nil
              }),
              let guidance = loaded[index].exercise.guidance, let equipment = guidance.equipment,
              let step = WorkoutLoadEngine.step(for: equipment, unit: guidance.unit) else { return nil }
        let history = load.history(for: loaded[index].target.name)
        guard WorkoutCalibration.isEligible(history),
              let estimate = WorkoutLoadEngine.estimate(from: history, unit: guidance.unit, today: load.today) else {
            return nil
        }
        let kind = WorkoutCalibration.kind(profile: inputs.profile, confidence: estimate.confidence)
        let ladder = loadLadder(for: guidance, at: inputs.location)
        let sets = WorkoutCalibration.sets(
            kind: kind, oneRepMax: estimate.oneRepMax, todaysSuggested: guidance.prescription?.suggested,
            todaysReps: guidance.targetReps, step: step, ladder: ladder
        )
        guard !sets.isEmpty else { return nil }
        let pick = loaded[index]
        let runnerStep = ladder?.runnerStep(default: step) ?? step
        let steps = sets.map {
            calibrationPick(pick, set: $0, guidance: guidance, step: runnerStep, confidence: estimate.confidence)
        }
        loaded.replaceSubrange(index...index, with: steps)
        for other in loaded.indices where loaded[other].slot.role == .accessory {
            loaded[other].exercise.sets = max(1, loaded[other].exercise.sets - 1)
        }
        return calibrationNote(kind: kind, lift: pick.target.name, sets: sets, unit: guidance.unit)
    }

    /// One calibration set as its own single-set step at a fixed weight.
    static func calibrationPick(
        _ pick: LoadedPick, set: CalibrationSet, guidance: LoadGuidance, step: Double, confidence: EstimateConfidence
    ) -> LoadedPick {
        var copy = pick
        let weight = WeightPrescription(low: set.weight, high: set.weight, suggested: set.weight,
                                        step: step, unit: guidance.unit, confidence: confidence)
        copy.exercise = PrescribedExercise(
            name: pick.exercise.name, sets: 1, reps: "\(set.reps)", role: pick.slot.role, fromCatalog: true,
            restSecondsOverride: set.restSeconds, block: .lifting,
            guidance: LoadGuidance(targetReps: set.reps, prescription: weight, equipment: guidance.equipment,
                                   unit: guidance.unit, calibration: set.step)
        )
        copy.plan = nil
        return copy
    }
}
