// WorkoutPlanFinisher+Session.swift
// FernletDomainModel
//
// The second half of the finishing pass for an edited session (WorkoutPlanFinisher.swift): once the
// lifts stand as a planner's picks would, give each new or changed one its weight, put the warm-up ramp
// where the planner would, count the fatigue context again when the order changed, run the pass's two
// trims, and rebuild the note from what was done.

import Foundation

extension WorkoutPlanFinisher {

    /// `lifts` — the edited session's working lifts, from ``lifts(of:previous:others:origin:context:)``
    /// — loaded, ramped, trimmed, fitted and noted. Comes back as `previous` itself when every step is
    /// the step it was.
    static func finished(
        _ lifts: [Lift], edited: WorkoutProgram.SessionSuggestion, previous: WorkoutProgram.SessionSuggestion,
        origin: Origin, context: Context
    ) -> WorkoutProgram.SessionSuggestion {
        guard !lifts.isEmpty else { return previous }
        let before = standingLifts(previous)
        let weighted = lifts.map { loaded($0, before: before, context: context) }
        var block = ramped(weighted, previous: previous, context: context)
        let was = WorkoutWarmUpSets.removingWarmUpSets(from: previous.exercises.filter { $0.block == .lifting })
        if weighted.map(\.step.name) != was.map(\.name) { block = recounted(block) }
        let settled = settle(
            draft(block, edited: edited, before: before, origin: origin, context: context),
            goal: context.goal, recentHard: context.recentHard, budgetMinutes: context.budgetMinutes
        )
        let exercises = settled.blocks.exercises
        guard exercises != previous.exercises else { return previous }
        var result = edited
        result.exercises = exercises
        let note = parts(after: settled, previous: previous, origin: origin, context: context)
        result.noteParts = note
        result.suggestion = WorkoutSuggestion(
            id: previous.suggestion.id, name: previous.suggestion.name,
            exercises: WorkoutSessionBlocks.planText(for: exercises), notes: WorkoutNotePart.text(of: note)
        )
        return result
    }

    /// A lift with its weight: a lift that carries guidance for the reps it has keeps it; a rep-counted
    /// catalog lift with none — a new one, or one whose reps changed — is prescribed from its own
    /// history on the space's weights, for the person's training age (``WorkoutPlanRun``'s engine
    /// guidance), with the loads the runner's picker opens on. Without a load context nothing is
    /// touched.
    static func loaded(_ lift: Lift, before: [String: PrescribedExercise], context: Context) -> Lift {
        guard let load = context.load, let target = lift.target, lift.step.fromCatalog,
              lift.step.holdSeconds == nil else { return lift }
        var step = lift.step
        guard step.guidance?.calibration == nil else { return lift }
        if let kept = before[WorkoutExerciseCatalog.normalizedName(step.name)], kept.reps != step.reps { step.guidance = nil }
        guard step.guidance == nil else { return Lift(step: step, target: target) }
        var guidance = WorkoutPlanRun.engineGuidance(for: target, reps: step.reps, sets: step.sets,
                                                     location: context.location, load: load,
                                                     inventory: context.location.weights)
        if let prescribed = guidance { guidance?.loads = WorkoutProgram.runnerLoads(for: prescribed, at: context.location) }
        step.guidance = guidance
        return Lift(step: step, target: target)
    }

    /// The lifting block with its warm-up sets, as the planner places them: none unless warm-up sets
    /// are on and the day isn't light (``WorkoutAdjustedLoad/rampsToday(load:intensity:original:)``).
    /// A lift that is the step it was keeps the ramp it had. With none kept, the session's first heavy
    /// main lift gets one — never an assisted lift, where a fraction of the weight is less help, not a
    /// warm-up. Without a load context the ramps simply follow their lifts.
    static func ramped(_ lifts: [Lift], previous: WorkoutProgram.SessionSuggestion, context: Context) -> [Lift] {
        let was = previous.exercises.filter { $0.block == .lifting }
        guard let load = context.load else {
            let steps = WorkoutWarmUpSets.reattach(lifts.map(\.step), from: was)
            let targets = Dictionary(lifts.map { ($0.step.name, $0.target) }, uniquingKeysWith: { first, _ in first })
            return steps.map { Lift(step: $0, target: targets[$0.name] ?? nil) }
        }
        guard WorkoutAdjustedLoad.rampsToday(load: load, intensity: context.intensity, original: previous) else { return lifts }
        let unchanged = Set(lifts.map(\.step).filter { was.contains($0) }.map(\.name))
        var ramps: [String: [PrescribedExercise]] = [:]
        for step in was where WorkoutWarmUpSets.isWarmUpSet(step) && unchanged.contains(step.name) {
            ramps[step.name, default: []].append(step)
        }
        let steps = lifts.map(\.step)
        let patterns = lifts.map { $0.target?.movementPattern }
        if ramps.isEmpty, let index = WorkoutWarmUpSets.firstHeavyMainLift(in: steps, patterns: patterns),
           let pattern = patterns[index], !WorkoutAssistedLifts.contains(steps[index].name) {
            let ladder = steps[index].guidance.flatMap { WorkoutProgram.loadLadder(for: $0, at: context.location) }
            ramps[steps[index].name] = WorkoutWarmUpSets.steps(for: steps[index], pattern: pattern, ladder: ladder)
        }
        var block: [Lift] = []
        for lift in lifts {
            let ramp = ramps.removeValue(forKey: lift.step.name) ?? []
            block += ramp.map { Lift(step: $0, target: lift.target) }
            block.append(lift)
        }
        return block
    }

    /// The block with the compound lifts ahead of each step counted again — the fatigue context a
    /// result records — for a block whose lifts or order changed.
    static func recounted(_ block: [Lift]) -> [Lift] {
        let counts = WorkoutProgram.compoundCounts(names: block.map(\.step.name),
                                                   patterns: block.map { $0.target?.movementPattern })
        var result = block
        for index in result.indices where index < counts.count {
            result[index].step.guidance?.compoundsBefore = counts[index]
        }
        return result
    }

    /// The edited session as the pass's draft: its blocks around the finished lifting block, and what
    /// the trims must respect. After an adjustment a lift the session already had is held to the sets
    /// it stood at, and a lift that is a main lift — or an eased one the session already had, which
    /// may be standing in a main slot — is never dropped. After a hand edit every row is the person's:
    /// none is dropped or cut, and a lift that was already there is not trimmed again.
    static func draft(
        _ block: [Lift], edited: WorkoutProgram.SessionSuggestion, before: [String: PrescribedExercise],
        origin: Origin, context: Context
    ) -> Draft {
        let steps = block.map(\.step)
        let mainLift = block.map { lift -> Bool in
            if origin == .handEdit || lift.step.role == .main { return true }
            guard let target = lift.target else { return false }
            return before[WorkoutExerciseCatalog.normalizedName(lift.step.name)] != nil && context.limits.eases(target)
        }
        let blocks = WorkoutSessionBudget.Blocks(
            warmUp: edited.exercises.filter { $0.block == .warmUp },
            activation: edited.exercises.filter { $0.block == .activation },
            lifting: steps, mainLift: mainLift,
            cardio: edited.exercises.filter { $0.block == .cardio },
            coolDown: edited.exercises.filter { $0.block == .coolDown }
        )
        var draft = Draft(blocks: blocks, targets: block.map(\.target))
        switch origin {
        case .adjustment:
            draft.settledSets = before.mapValues(\.sets)
        case .handEdit:
            draft.held = Set(before.keys)
            draft.liftingIsFixed = true
        }
        return draft
    }

    // MARK: - The note, from what was done

    /// The session's note parts after a pass. The parts it had are kept where they are still true: a
    /// line about lifts goes when one of them no longer stands as it did; the 48-hour line names the
    /// lifts still lightened and those this pass lightened; the budget line is this pass's own when it
    /// trimmed or the session runs over, and goes when a lift was added (it may name what is back);
    /// an adjustment adds its line once. A session with no parts (read back from today's plan file)
    /// gets its note rebuilt from nothing (``scratchParts(_:)``).
    static func parts(
        after settled: Settled, previous: WorkoutProgram.SessionSuggestion, origin: Origin, context: Context
    ) -> [WorkoutNotePart] {
        var parts = previous.noteParts ?? scratchParts(context)
        let before = standingLifts(previous)
        var now: [String: PrescribedExercise] = [:]
        for step in settled.blocks.lifting where !WorkoutWarmUpSets.isWarmUpSet(step) && step.guidance?.calibration == nil {
            let key = WorkoutExerciseCatalog.normalizedName(step.name)
            if now[key] == nil { now[key] = step }
        }
        let stands: (String) -> Bool = { name in
            let key = WorkoutExerciseCatalog.normalizedName(name)
            guard let old = before[key], let new = now[key] else { return false }
            return old.sets == new.sets && old.reps == new.reps
        }
        parts.removeAll { $0.kind == .lifts && !$0.lifts.allSatisfy(stands) }
        let earlier = (parts.first { $0.kind == .recovery }?.lifts ?? []).filter { name in
            let key = WorkoutExerciseCatalog.normalizedName(name)
            guard let old = before[key], let new = now[key] else { return false }
            return new.sets <= old.sets
        }
        replace(.recovery, in: &parts, with: recoveryPart(earlier + settled.lightened.filter { !earlier.contains($0) }))
        if let budget = settled.budget, !budget.trims.isEmpty || !budget.fits {
            replace(.budget, in: &parts, with: WorkoutNotePart(.budget, budget.note ?? ""))
        } else if now.keys.contains(where: { before[$0] == nil }) {
            replace(.budget, in: &parts, with: WorkoutNotePart(.budget, ""))
        }
        if origin == .adjustment, !parts.contains(where: { $0.kind == .adjusted }) {
            parts.append(WorkoutNotePart(.adjusted, WorkoutPlannerCopy.adjustedToNote))
        }
        return parts
    }

    /// Puts `part` where the first part of `kind` is, or at the end when there is none.
    static func replace(_ kind: WorkoutNotePart.Kind, in parts: inout [WorkoutNotePart], with part: WorkoutNotePart) {
        if let index = parts.firstIndex(where: { $0.kind == kind }) {
            parts[index] = part
        } else {
            parts.append(part)
        }
    }

    /// The parts of a note rebuilt from nothing: the space, the budget's and the 48-hour guard's
    /// slots, the line about saved limits when there are any, and what today's "Anything else?"
    /// applied.
    static func scratchParts(_ context: Context) -> [WorkoutNotePart] {
        var parts = [
            WorkoutNotePart(.session, context.location.displayedName),
            WorkoutNotePart(.budget, ""), WorkoutNotePart(.recovery, ""),
        ]
        if context.savedLimitsApply, !context.limits.isEmpty {
            parts.append(WorkoutNotePart(.session, WorkoutPlannerCopy.workedAroundLimits))
        }
        parts += context.todaysLines.map { WorkoutNotePart(.session, $0) }
        return parts
    }
}
