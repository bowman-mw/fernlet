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
/// readiness flags), today, the unit to fall back on, recent protein and logged body weight, and the
/// calibration state. Built by the app from the day history.
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
    /// The answer to Workout setup's "How long have you lifted regularly?" (G8); nil when the
    /// context does not say, which keeps every lift on the beginner pace with its age inferred.
    public var experience: ExperienceLevel?
    /// Weeks from each lift's first logged session (reading back two years) to today, by
    /// ``WorkoutExerciseCatalog/normalizedName(_:)``: what refines the answer per lift.
    public var liftWeeks: [String: Double]
    /// The lifting focus (G6): Strength, Size, or Both — the default, which keeps the goal's mix.
    public var focus: WorkoutStrengthFocus
    /// Workout setup's "Use food logs in workout notes" switch (G13), resolved by the app (on unless
    /// switched off). Off by default here, so a context built without saying so mentions no food or
    /// body weight. On, the notes still say nothing until the logs are good enough to read
    /// (``RecoverySummary/loggingIsGood``, ``WorkoutBodyWeightTrend/isFalling(_:today:)``).
    public var foodAware: Bool
    /// The weigh-ins the person logged, oldest first (G13); empty when they don't log their weight,
    /// and then the notes never mention it.
    public var bodyWeights: [BodyWeightSample]
    /// The user's term of address (``BiologicalSex/termOfAddress`` of the effective body profile),
    /// which the session notes that describe the user agree with ("welcome back" and the max test's
    /// "if you're sore" are gendered in Spanish). The notes are composed here, at plan time, and
    /// stored on the logged row, so the term has to travel with the plan's inputs rather than be read
    /// where the note is drawn. The app's builder always passes the profile's; a context built
    /// without saying so (a test fixture) addresses the user as an unanswered profile does,
    /// masculine.
    public var address: TermOfAddress

    public init(
        exposures: [String: [LiftExposure]], today: Date, defaultUnit: LoadUnit,
        recovery: RecoverySummary = .unknown, calibration: CalibrationSettings = CalibrationSettings(),
        warmUpSets: Bool = false, traits: LifterTraits = .unknown, experience: ExperienceLevel? = nil,
        liftWeeks: [String: Double] = [:], focus: WorkoutStrengthFocus = .both, foodAware: Bool = false,
        bodyWeights: [BodyWeightSample] = [], address: TermOfAddress = .masculine
    ) {
        self.exposures = exposures
        self.today = today
        self.defaultUnit = defaultUnit
        self.recovery = recovery
        self.calibration = calibration
        self.warmUpSets = warmUpSets
        self.traits = traits
        self.experience = experience
        self.liftWeeks = liftWeeks
        self.focus = focus
        self.foodAware = foodAware
        self.bodyWeights = bodyWeights
        self.address = address
    }

    /// One lift's training age (G8): the setup answer as a floor — six months for "6 months to 2
    /// years", two years for "more than 2 years" — raised by how long this lift has been logged. An
    /// "under 6 months" answer (also the default nobody changed) keeps the age inferred, so the
    /// trend judges the lift by its own earlier progress rather than by a beginner's curve that a
    /// long-trained lifter would always fall short of. Nil when the context has no answer.
    public func trainingAge(for name: String) -> TrainingAge? {
        guard let experience else { return nil }
        let logged = liftWeeks[WorkoutExerciseCatalog.normalizedName(name)] ?? 0
        switch experience {
        case .beginner: return TrainingAge(weeks: logged, isInferred: true)
        case .intermediate: return TrainingAge(weeks: max(WorkoutTrend.intermediateWeeks, logged))
        case .advanced: return TrainingAge(weeks: max(WorkoutTrend.advancedWeeks, logged))
        }
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
        /// Set when the lift follows the block calendar today (``WorkoutBlocks``).
        var block: BlockWeek?
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
        let tracking = PlateauTracking.forGoal(inputs.goal)
        var loaded = picks.map { pick in
            LoadedPick(exercise: pick.exercise, target: pick.target, slot: pick.slot,
                       plateau: plateauStatus(of: pick.target, role: pick.slot.role, tracking: tracking, load: load))
        }
        addVariant(&loaded, inputs: inputs, used: &used)
        for index in loaded.indices { plan(&loaded[index], inputs: inputs, load: load) }
        applyPlateauLoad(&loaded, inputs: inputs, load: load)
        let plateauNotes = plateauStory(loaded, inputs: inputs) ?? []
        var notes = progressNotes(loaded, addressing: load.address)
        if let week = loaded.lazy.compactMap(\.block).first {
            notes.insert(blockNote(week, energy: inputs.intensity), at: 0)
        }
        if let harder = offerHarderVariations(&loaded, inputs: inputs, used: used) { notes.append(harder) }
        if calibrationOpen {
            var trial = loaded
            if let calibration = expandCalibration(&trial, inputs: inputs, load: load) {
                if calibrationFits(trial, inputs: inputs) {
                    loaded = trial
                    calibrationOpen = false
                    notes = [calibration]
                } else {
                    notes.append(WorkoutPlannerCopy.calibrationMoved)
                }
            }
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

    /// The trend status of a rep-counted lift, as much as the goal hears (G7, ``PlateauTracking``):
    /// none for the gentler goals; weight management's quiet strength-held check
    /// (``WorkoutPlateau/strengthHeldStatus(of:unit:today:profile:)``); and for strength and sports
    /// prep the main lifts' full trend (``WorkoutPlateau/status(of:unit:today:profile:levelKg:)``). Nil
    /// for holds and lifts with no history. The lift's estimated max, in kilograms, lets the expected
    /// curve tell a strong lifter from a newer one.
    static func plateauStatus(
        of target: ExerciseTarget, role: SlotRole, tracking: PlateauTracking, load: WorkoutLoadContext
    ) -> PlateauStatus? {
        guard target.measure != .seconds, tracking != .off else { return nil }
        let history = load.history(for: target.name)
        guard !history.isEmpty else { return nil }
        guard tracking == .mainLifts else {
            let profile = TrendProfile(trainingAge: load.trainingAge(for: target.name), traits: load.traits,
                                       lowerBody: WorkoutLoadEngine.isLowerBody(target.movementPattern))
            return WorkoutPlateau.strengthHeldStatus(of: history, unit: load.unit(for: history), today: load.today,
                                                     profile: profile)
        }
        guard role == .main else { return nil }
        let unit = load.unit(for: history)
        let levelKg = WorkoutLoadEngine.estimate(from: history, unit: unit, today: load.today)
            .map { LoadUnit.kg.converted($0.oneRepMax, from: unit) }
        let profile = TrendProfile(trainingAge: load.trainingAge(for: target.name), traits: load.traits,
                                   lowerBody: WorkoutLoadEngine.isLowerBody(target.movementPattern))
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
    /// runner asks the lifter to pick one. The person's focus shapes the reps and sets (G6,
    /// ``WorkoutStrengthFocus``), and a trained Strength lifter's main lift follows the block
    /// calendar's (``WorkoutBlocks``) instead of the goal's.
    static func plan(_ pick: inout LoadedPick, inputs: SlotInputs, load: WorkoutLoadContext) {
        let role = pick.slot.role
        guard pick.exercise.fromCatalog, pick.exercise.holdSeconds == nil,
              let styleScheme = RepScheme(load.focus.reps(for: role) ?? inputs.style.reps(for: role)) else { return }
        let history = load.history(for: pick.target.name)
        let equipment = loadEquipment(for: pick.target, at: inputs.location)
        let tier = load.trainingAge(for: pick.target.name)?.tier ?? .beginner
        let block = WorkoutBlocks.applies(goal: inputs.goal, focus: load.focus, tier: tier, role: role)
            ? WorkoutBlocks.week(on: load.today) : nil
        let scheme = block.map { RepScheme(low: $0.phase.reps, high: $0.phase.reps) } ?? styleScheme
        let styleSets = inputs.style.adjustedSets(for: role, energy: inputs.intensity)
        let sets = block.map { WorkoutBlocks.sets($0.phase, energy: inputs.intensity) }
            ?? min(max(styleSets, WorkoutStrengthFocus.maxSets), styleSets + load.focus.extraSets(tier))
        pick.block = block
        if block != nil || load.focus != .both {
            pick.exercise.sets = sets
            pick.exercise.reps = "\(scheme.low)"
        }
        guard !history.isEmpty else {
            var first = LoadGuidance(
                targetReps: Int(pick.exercise.reps) ?? scheme.low, equipment: equipment, unit: load.defaultUnit
            )
            first.loads = runnerLoads(for: first, at: inputs.location)
            pick.exercise.guidance = first
            return
        }
        let plan = WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
            scheme: scheme, baseSets: sets, exposures: history, equipment: equipment,
            isLowerBody: WorkoutLoadEngine.isLowerBody(pick.target.movementPattern),
            defaultUnit: load.defaultUnit, today: load.today, inventory: inputs.location.weights, tier: tier
        ))
        pick.exercise.sets = plan.sets
        pick.exercise.reps = "\(plan.reps)"
        var guidance = LoadGuidance(
            targetReps: plan.reps, prescription: plan.prescription, equipment: equipment, unit: plan.unit,
            askReasonOnOverride: plan.askReasonOnOverride
        )
        guidance.loads = runnerLoads(for: guidance, at: inputs.location)
        pick.exercise.guidance = guidance
        pick.plan = plan
    }

    /// The owned loads a guided run steps through for this lift (R6): those around its suggestion,
    /// or around the middle of what the location has when there is no suggestion yet.
    static func runnerLoads(for guidance: LoadGuidance, at location: WorkoutLocation) -> [Double]? {
        guard let ladder = loadLadder(for: guidance, at: location) else { return nil }
        let middle = ladder.loads[ladder.loads.count / 2]
        return ladder.window(around: guidance.prescription?.suggested ?? middle, count: LoadGuidance.maxRunnerLoads)
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

    // MARK: A harder variation (N7)

    /// N7 (2026-10-20): while a lift sits at the heaviest load this location has, the planner offers
    /// a harder variation of it — the plan editor's first swap (``LoadGuidance/harderVariation``) —
    /// and the session note says so once. More reps, then a set, stays the plan.
    static func offerHarderVariations(_ loaded: inout [LoadedPick], inputs: SlotInputs, used: Set<String>) -> String? {
        var note: String?
        for index in loaded.indices where loaded[index].variantOf == nil && atHeaviest(loaded[index].plan) {
            let lift = loaded[index].target
            guard let harder = harderVariation(for: lift, inputs: inputs, excluding: used) else { continue }
            loaded[index].exercise.guidance?.harderVariation = harder.name
            guard note == nil else { continue }
            note = WorkoutPlannerCopy.harderVariation(ExerciseHowToCatalog.displayName(for: harder.name),
                                                      lift: ExerciseHowToCatalog.displayName(for: lift.name))
        }
        return note
    }

    /// Whether the plan holds a lift at the heaviest load the location has (``LoadCap/heaviest(top:)``).
    static func atHeaviest(_ plan: LiftPlan?) -> Bool {
        guard case .heaviest(_)? = plan?.cap else { return false }
        return true
    }

    /// The harder variation offered for `target`: an exercise the planner may suggest here, not in the
    /// session already, doing the same kind of work — the same modality and measure, the same movement
    /// pattern (a squat may step to a split squat or lunge), a shared primary muscle — at a harder
    /// difficulty. The nearest step wins: most shared primaries, then the same pattern, then the
    /// smallest step in difficulty, then the name. Nil when nothing fits.
    static func harderVariation(for target: ExerciseTarget, inputs: SlotInputs, excluding used: Set<String>) -> ExerciseTarget? {
        let candidates = inputs.feasible.filter { candidate in
            candidate.name != target.name && !used.contains(candidate.name)
                && candidate.difficulty > target.difficulty && candidate.modality == target.modality
                && candidate.measure == target.measure
                && isHarderPattern(candidate.movementPattern, from: target.movementPattern)
                && !candidate.primaryMuscles.isDisjoint(with: target.primaryMuscles)
        }
        return candidates.min { harderRank($0, for: target) < harderRank($1, for: target) }
    }

    /// The same pattern, or a squat's step to a single-leg split squat or lunge.
    static func isHarderPattern(_ candidate: MovementPattern, from original: MovementPattern) -> Bool {
        candidate == original || (original == .squat && candidate == .lunge)
    }

    /// The order ``harderVariation(for:inputs:excluding:)`` ranks by, lowest first.
    static func harderRank(_ candidate: ExerciseTarget, for target: ExerciseTarget) -> (Int, Int, Int, String) {
        let shared = candidate.primaryMuscles.intersection(target.primaryMuscles).count
        let pattern = candidate.movementPattern == target.movementPattern ? 0 : 1
        let gap = candidate.difficulty.rawValue - target.difficulty.rawValue
        return (-shared, pattern, gap, candidate.name)
    }

    // MARK: Calibration

    /// Turns the session's main lift into this month's calibration when one is due, and takes a set
    /// off each accessory. Returns the note, or nil when nothing changed.
    static func expandCalibration(_ loaded: inout [LoadedPick], inputs: SlotInputs, load: WorkoutLoadContext) -> String? {
        guard PlateauTracking.forGoal(inputs.goal).runsStrengthTest,
              WorkoutCalibration.isDue(load.calibration, intensity: inputs.intensity, today: load.today),
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
        return calibrationNote(kind: kind, lift: pick.target.name, sets: sets, unit: guidance.unit, addressing: load.address)
    }

    /// The shortest session budget a strength check runs in: its ramp and its long rests need it.
    static let calibrationMinimumMinutes = 30

    /// Whether a session's lifting block with its calibration still fits the day's time budget (N3,
    /// 2026-10-20): a budget of at least ``calibrationMinimumMinutes``, and the block — counting the
    /// rests between the check's single sets, which the session clock leaves out — with room for a
    /// short warm-up. When it doesn't, the strength check waits: it stays due, so it comes on the next
    /// day with more time, rather than squeezing today.
    static func calibrationFits(_ loaded: [LoadedPick], inputs: SlotInputs) -> Bool {
        guard let budget = inputs.options.length.minutes else { return true }
        guard budget >= calibrationMinimumMinutes else { return false }
        let steps = loaded.map(\.exercise)
        let checkRests = steps.filter { $0.guidance?.calibration != nil }.dropLast()
            .reduce(0) { $0 + ($1.restSecondsOverride ?? 0) }
        let seconds = WorkoutSessionTime.seconds(of: steps, goal: inputs.goal) + checkRests
        return seconds + WorkoutSessionBlocks.shortWarmUpSeconds <= budget * 60
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
                                   unit: guidance.unit, calibration: set.step, loads: guidance.loads)
        )
        copy.plan = nil
        return copy
    }
}
