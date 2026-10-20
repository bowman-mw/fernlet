// WorkoutProgram+Load.swift
// FernletDomainModel
//
// Where the load engine meets the day plan. After the lifting slots are filled, each rep-counted lift
// gets its next prescription from its own history (``WorkoutLoadEngine``), a stalled lift gets the
// owner's gentle plateau response (``WorkoutPlateau``), and about once a month the main lift becomes a
// calibration (``WorkoutCalibration``). The session note says what changed and why, in plain words.
// Where the location has its weights set (``WorkoutLocation/weights``), every weight here — the
// prescription, the easier session's lighter load and the calibration's sets — is a load it has.
//
// The note sentences are String Catalog keys in ``WorkoutPlannerCopy`` (2026-10-20, idea 16), composed
// in the device's language when the plan is built; the plan TEXT (exercise names, sets and reps) stays
// the frozen English the history parser reads.

import Foundation

/// Everything the planner needs to prescribe loads: each lift's logged sessions, today, the unit to
/// fall back on, recent recovery, and the calibration state. Built by the app from the day history.
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

    public init(
        exposures: [String: [LiftExposure]], today: Date, defaultUnit: LoadUnit,
        recovery: RecoverySummary = .unknown, calibration: CalibrationSettings = CalibrationSettings(),
        warmUpSets: Bool = false
    ) {
        self.exposures = exposures
        self.today = today
        self.defaultUnit = defaultUnit
        self.recovery = recovery
        self.calibration = calibration
        self.warmUpSets = warmUpSets
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
        /// Set on a variation: the stalled lift it stands in for.
        var standsInFor: String?
        var plan: LiftPlan?
    }

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
        var plateauNotes: [String] = []
        substituteVariations(&loaded, inputs: inputs, used: &used, notes: &plateauNotes)
        swapInSupportWork(&loaded, inputs: inputs, used: &used, notes: &plateauNotes)
        for index in loaded.indices { plan(&loaded[index], inputs: inputs, load: load) }
        applyPlateauLoad(&loaded, inputs: inputs)
        if let story = plateauStory(loaded, recovery: load.recovery) { plateauNotes.insert(contentsOf: story, at: 0) }
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

    /// Puts warm-up sets in front of the session's first heavy main lift (``WorkoutWarmUpSets``) when
    /// the lifter has them on and today isn't a light day — that lift only, and none when it doesn't
    /// qualify. Runs after the calibration, so a lift the calibration already ramps into gets no second
    /// ramp; the sets land on the location's own loads when its weights are set. Each warm-up is a copy
    /// of its lift's pick, so it shares the lift's slot, target and fatigue context.
    static func addWarmUpSets(_ loaded: inout [LoadedPick], inputs: SlotInputs, load: WorkoutLoadContext) {
        guard load.warmUpSets, inputs.intensity != .light,
              let index = WorkoutWarmUpSets.firstHeavyMainLift(
                  in: loaded.map(\.exercise), patterns: loaded.map { Optional($0.target.movementPattern) }
              ) else { return }
        let pick = loaded[index]
        let ladder = pick.exercise.guidance.flatMap { loadLadder(for: $0, at: inputs.location) }
        let steps = WorkoutWarmUpSets.steps(for: pick.exercise, pattern: pick.target.movementPattern, ladder: ladder)
        let warmUps = steps.map { step in
            var warmUp = pick
            warmUp.exercise = step
            warmUp.plan = nil
            return warmUp
        }
        loaded.insert(contentsOf: warmUps, at: index)
    }

    /// The plateau status of a rep-counted lift, nil for holds and lifts with no history.
    static func plateauStatus(of target: ExerciseTarget, load: WorkoutLoadContext) -> PlateauStatus? {
        guard target.measure != .seconds else { return nil }
        let history = load.history(for: target.name)
        guard !history.isEmpty else { return nil }
        return WorkoutPlateau.status(of: history, unit: load.unit(for: history), today: load.today)
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
        let counts = compoundCounts(names: loaded.map(\.exercise.name),
                                    patterns: loaded.map { Optional($0.target.movementPattern) })
        for index in loaded.indices where index < counts.count {
            loaded[index].exercise.guidance?.compoundsBefore = counts[index]
        }
    }

    /// The compound lifts ahead of each step, in order. `patterns` runs parallel to `names`; a step
    /// with no known pattern is not counted. Steps of one name share one lift (a calibration's steps,
    /// a lift's warm-up sets): every one carries the count from its first. Shared with the re-run
    /// after "Adjust with AI" (``WorkoutAdjustedLoad``).
    static func compoundCounts(names: [String], patterns: [MovementPattern?]) -> [Int] {
        let noncompound: Set<MovementPattern> = [.isolation, .twist, .locomotion]
        var compounds = 0
        var firstSeen: [String: Int] = [:]
        var counts: [Int] = []
        for (index, name) in names.enumerated() {
            if let before = firstSeen[name] {
                counts.append(before)
                continue
            }
            counts.append(compounds)
            firstSeen[name] = compounds
            if index < patterns.count, let pattern = patterns[index], !noncompound.contains(pattern) { compounds += 1 }
        }
        return counts
    }

    // MARK: Plateau response

    /// A stalled lift past its support block gets its slot's next-best exercise for four weeks.
    static func substituteVariations(
        _ loaded: inout [LoadedPick], inputs: SlotInputs, used: inout Set<String>, notes: inout [String]
    ) {
        for index in loaded.indices where loaded[index].plateau?.stage == .variation {
            let original = loaded[index].target
            guard let stand = bestExercise(
                for: loaded[index].slot, in: inputs.feasible, excluding: used.union([original.name]),
                biasTokens: inputs.biasTokens, experience: inputs.profile.experience, location: inputs.location,
                limits: inputs.limits
            ) else { continue }
            used.insert(stand.name)
            loaded[index].exercise = prescribe(stand, role: loaded[index].slot.role, block: .lifting,
                                               completions: inputs.progression[stand.name] ?? 0, inputs: inputs)
            loaded[index].target = stand
            loaded[index].standsInFor = original.name
            notes.append(WorkoutPlannerCopy.standsIn(stand.name, for: original.name))
        }
    }

    /// During the support block, one accessory slot becomes work for the stalled lift's helper
    /// muscles: the last accessory that isn't already helping it (an existing triceps slot stays on a
    /// stalled bench day), filled for the first helper muscle the session doesn't train at all.
    static func swapInSupportWork(
        _ loaded: inout [LoadedPick], inputs: SlotInputs, used: inout Set<String>, notes: inout [String]
    ) {
        guard let stalled = loaded.first(where: { $0.plateau?.stage == .supportWork && $0.standsInFor == nil }) else { return }
        let helpers = WorkoutPlateau.helperMuscles(for: stalled.target)
        guard let slotIndex = loaded.lastIndex(where: {
            $0.slot.role == .accessory && $0.target.name != stalled.target.name && $0.standsInFor == nil
                && $0.target.primaryMuscles.isDisjoint(with: helpers)
        }) else { return }
        let worked = loaded.reduce(into: Set<MuscleGroup>()) { $0.formUnion($1.target.primaryMuscles) }
        for muscle in helpers where !worked.contains(muscle) {
            let slot = WorkoutSlotSpec(label: "Support", role: .accessory, muscles: [muscle])
            guard let support = bestExercise(
                for: slot, in: inputs.feasible, excluding: used, biasTokens: inputs.biasTokens,
                experience: inputs.profile.experience, location: inputs.location, limits: inputs.limits
            ) else { continue }
            used.insert(support.name)
            loaded[slotIndex].exercise = prescribe(support, role: .accessory, block: .lifting,
                                                   completions: inputs.progression[support.name] ?? 0, inputs: inputs)
            loaded[slotIndex].target = support
            loaded[slotIndex].slot = slot
            loaded[slotIndex].plateau = nil
            notes.append(WorkoutPlannerCopy.supportSwap(support.name, helping: stalled.target.name))
            return
        }
    }

    /// The load side of the response: longer rest on every stalled lift, the easier session (half
    /// the sets, about 10 % lighter), and the first stalled lift of the session moved to the front.
    static func applyPlateauLoad(_ loaded: inout [LoadedPick], inputs: SlotInputs) {
        for index in loaded.indices {
            guard let status = loaded[index].plateau, loaded[index].standsInFor == nil else { continue }
            let role = loaded[index].slot.role
            let base = WorkoutRestGuidance.restSeconds(
                demand: WorkoutRestGuidance.demand(role: role, movementPattern: loaded[index].target.movementPattern),
                goal: inputs.goal
            )
            let extra = role == .main ? WorkoutPlateau.extraRestMainSeconds : WorkoutPlateau.extraRestAccessorySeconds
            loaded[index].exercise.restSecondsOverride = WorkoutRestGuidance.clamp(base + extra)
            if status.stage == .easierSession { makeEasier(&loaded[index], location: inputs.location) }
        }
        let front: Set<PlateauStage> = [.easierSession, .recover]
        guard let first = loaded.firstIndex(where: { $0.plateau.map { front.contains($0.stage) } ?? false }),
              first > 0 else { return }
        loaded.insert(loaded.remove(at: first), at: 0)
    }

    /// Half the sets (rounded up) and about 10 % lighter — on a load the location has, when its
    /// weights are set — flagged so it never anchors the next session.
    static func makeEasier(_ pick: inout LoadedPick, location: WorkoutLocation) {
        pick.exercise.sets = max(1, (pick.exercise.sets + 1) / 2)
        guard var guidance = pick.exercise.guidance else { return }
        guidance.easierSession = true
        if let current = guidance.prescription {
            let ladder = loadLadder(for: guidance, at: location)
            let step = guidance.equipment.flatMap { WorkoutLoadEngine.step(for: $0, unit: current.unit) } ?? current.step
            let lighter = WorkoutLoadEngine.movedOnto(
                current.suggested, by: .down(WorkoutPlateau.easierLoadDecrease), step: step, lowerBody: false, ladder: ladder
            )
            guidance.prescription = WorkoutLoadEngine.prescription(
                suggested: lighter, confidence: current.confidence, step: step, unit: current.unit, ladder: ladder
            )
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
                      && $0.plateau?.stage != .easierSession && $0.standsInFor == nil
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
