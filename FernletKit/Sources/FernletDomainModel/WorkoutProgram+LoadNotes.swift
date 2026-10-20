// WorkoutProgram+LoadNotes.swift
// FernletDomainModel
//
// The session-note lines the load pass writes: what changed on a lift and why, the trend story (a
// stall on its ladder, a dip, a slowing or too-early note), and the calibration brief. Tone, per the
// owner: plateaus are normal and a lighter day is training too — nothing here ever says "you failed",
// and a short night is said as something that happened alongside, never as the person's fault. The sentences themselves are String Catalog keys in
// ``WorkoutPlannerCopy`` (2026-10-20, idea 16); this file decides which one a lift gets.

import Foundation

extension WorkoutProgram {

    /// Lines per session about ordinary progression, at most this many.
    static let maxProgressLines = 2

    /// What changed on the session's lifts, main lift first — at most two lines, plus one line for
    /// lifts that still need a first weight. A stalled or dipping lift is left to the trend story,
    /// which says what today changes on it. Each lift is named in the device's language
    /// (``WorkoutPlannerCopy/exerciseName(_:)``, N8).
    static func progressNotes(_ loaded: [LoadedPick]) -> [String] {
        var lines: [String] = []
        var needsFirstWeight = false
        for pick in loaded where !isRespondedTo(pick) {
            if let guidance = pick.exercise.guidance, guidance.isLoadable, guidance.prescription == nil {
                needsFirstWeight = true
            }
            let name = WorkoutPlannerCopy.exerciseName(pick.target.name)
            // A block's phase switch rebaselines the lift; the block note says why, once.
            guard lines.count < maxProgressLines, let plan = pick.plan,
                  !(pick.block != nil && plan.change == .recalibrated),
                  let line = changeLine(name, plan: plan) else { continue }
            lines.append(line)
        }
        if needsFirstWeight {
            lines.append(WorkoutPlannerCopy.newLifts)
        }
        return lines
    }

    /// Whether the plateau response changed this lift's plan: a stall on its ladder, or a dip's deload.
    static func isRespondedTo(_ pick: LoadedPick) -> Bool {
        pick.plateau?.state == .stalled || pick.plateau?.state == .dipping
    }

    /// One lift's change in a sentence, or nil when there is nothing worth saying. `name` is the name
    /// the note draws — the caller's display name, never matched against.
    static func changeLine(_ name: String, plan: LiftPlan) -> String? {
        let weight = plan.prescription.map(\.suggestedText)
        if plan.recentered, plan.change != .recalibrated {
            return WorkoutPlannerCopy.recentered(name)
        }
        switch plan.change {
        case .moreReps: return WorkoutPlannerCopy.moreReps(name, reps: plan.reps)
        case .moreSets: return WorkoutPlannerCopy.moreSets(name)
        case .addWeight: return weight.map { WorkoutPlannerCopy.addWeight(name, weight: $0) }
        case .backToBottom: return WorkoutPlannerCopy.backToBottom(name, reps: plan.reps, weight: weight)
        case .lighter: return WorkoutPlannerCopy.lighter(name, weight: weight)
        case .lighterFewerSets: return WorkoutPlannerCopy.lighterFewerSets(name)
        case .afterBreak: return WorkoutPlannerCopy.afterBreak(name, weight: weight)
        case .recalibrated: return WorkoutPlannerCopy.recalibrated(name, weight: weight)
        case .holdForPain: return WorkoutPlannerCopy.holdForPain(name)
        case .holdForEquipment: return WorkoutPlannerCopy.holdForEquipment(name)
        case .repsFirst: return plan.cap.map { repsFirstLine(name, plan: plan, cap: $0) }
        case .setFirst: return plan.cap.map { setFirstLine(name, plan: plan, cap: $0) }
        case .confirming: return WorkoutPlannerCopy.confirming(name)
        case .heldAfterFlag: return WorkoutPlannerCopy.heldAfterFlag(name, shortNight: plan.previousFlag?.sleep != nil)
        case .heldUnfueled: return WorkoutPlannerCopy.heldUnfueled(name)
        case .same, .blockHold, .firstTime: return nil
        }
    }

    /// Why the weight waits, with today's reps: "Dumbbell press: your next dumbbell is 25 lb, so add
    /// reps first — 13 today."
    static func repsFirstLine(_ name: String, plan: LiftPlan, cap: LoadCap) -> String {
        switch cap {
        case .bigStep(let from, let to, let owned):
            let next = loadText(to, plan.unit)
            guard owned else {
                return WorkoutPlannerCopy.repsFirstBigJump(name, next: next, from: loadText(from, plan.unit), reps: plan.reps)
            }
            return WorkoutPlannerCopy.repsFirstNext(name, nextLoad: nextLoadPhrase(next, equipment: plan.equipment),
                                                    reps: plan.reps)
        case .heaviest(let top):
            let heaviest = heaviestPhrase(loadText(top, plan.unit), equipment: plan.equipment)
            return WorkoutPlannerCopy.repsFirstHeaviest(name, heaviest: heaviest, reps: plan.reps)
        }
    }

    /// The extra set: "Dumbbell press: one more set today, then up to 25 lb."
    static func setFirstLine(_ name: String, plan: LiftPlan, cap: LoadCap) -> String {
        switch cap {
        case .bigStep(_, let to, _):
            return WorkoutPlannerCopy.setFirstNext(name, load: loadText(to, plan.unit))
        case .heaviest(let top):
            let heaviest = heaviestPhrase(loadText(top, plan.unit), equipment: plan.equipment)
            return WorkoutPlannerCopy.setFirstHeaviest(name, heaviest: heaviest)
        }
    }

    /// "your next dumbbell is 25 lb", by the gear the lift is loaded with.
    static func nextLoadPhrase(_ load: String, equipment: Equipment?) -> String {
        WorkoutPlannerCopy.nextLoad(load, equipment: equipment)
    }

    /// "25 lb is your heaviest dumbbell", by the gear the lift is loaded with.
    static func heaviestPhrase(_ load: String, equipment: Equipment?) -> String {
        WorkoutPlannerCopy.heaviest(load, equipment: equipment)
    }

    /// "25 lb": a load as the notes print it. The unit is the frozen symbol ("lb", "kg"), which reads
    /// the same in every language the app plans to ship.
    static func loadText(_ weight: Double, _ unit: LoadUnit) -> String {
        "\(WorkoutLoadEngine.weightText(weight)) \(unit.rawValue)"
    }

    /// Context lines a plateau story carries at most, before its plain training option.
    static let maxContextLines = 2

    /// The trend story for one lift of the session: a stalled, dipping or eased lift first, else a
    /// slowing one, else one whose window was mostly flagged. At most ``maxContextLines`` context lines
    /// (what the trend shows, then what happened alongside it: logged body weight, short nights or
    /// light days, logged protein, in that order), then always a plain training option.
    /// Calm by rule: steady is normal, a dip happens, a flag is said as co-occurrence, never as blame,
    /// and for a lifter of 60 or more, holding strength is said to be the progress it is (G9).
    static func plateauStory(_ loaded: [LoadedPick], inputs: SlotInputs) -> [String]? {
        let lifts = loaded.filter { $0.variantOf == nil && $0.exercise.guidance?.warmUp != true }
        let order: [TrendState] = [.stalled, .dipping, .eased, .slowing, .tooEarly]
        var chosen: LoadedPick?
        for state in order where chosen == nil {
            chosen = lifts.first { $0.plateau?.state == state }
        }
        guard let pick = chosen, let status = pick.plateau else { return nil }
        let name = ExerciseHowToCatalog.displayName(for: pick.target.name)
        var context: [String] = []
        if let lead = leadLine(name, status: status) { context.append(lead) }
        if let weight = bodyWeightLine(status, inputs: inputs) { context.append(weight) }
        if let flags = flagContextLine(status.reading) { context.append(flags) }
        if let protein = proteinLine(status, inputs: inputs) { context.append(protein) }
        let older = (inputs.load?.traits.ageYears ?? 0) >= WorkoutTrend.olderAdultYears
        let option = trainingOption(pick, name: name, status: status, loaded: loaded, goal: inputs.goal, older: older)
        return Array(context.prefix(maxContextLines)) + [option]
    }

    /// What the trend shows, as the story's first line; nil when the option line says it all.
    static func leadLine(_ name: String, status: PlateauStatus) -> String? {
        switch status.state {
        case .stalled:
            return status.stage == .holdingSteady ? nil : plateauLead(name, weeks: status.weeksHeld)
        case .dipping:
            return WorkoutPlannerCopy.dipLead(name)
        case .eased:
            return WorkoutPlannerCopy.easedLead(name)
        case .slowing, .tooEarly, .progressing:
            return nil
        }
    }

    /// The sleep or light-day line: how many of the trend window's sessions came after a short night
    /// (or, with none, on a light day). Said as co-occurrence; nil when none were flagged.
    static func flagContextLine(_ reading: TrendReading) -> String? {
        let window = reading.windowSessions
        guard window > 0 else { return nil }
        if reading.shortNightSessions > 0 {
            return WorkoutPlannerCopy.shortNightContext(reading.shortNightSessions, of: window)
        }
        guard reading.lightDaySessions > 0 else { return nil }
        return WorkoutPlannerCopy.lightDayContext(reading.lightDaySessions, of: window)
    }

    /// G13: what logged body weight adds, only with the food-aware switch on and the weight falling
    /// (``WorkoutBodyWeightTrend``): beside a Size lifter's stall, that size usually holds through a
    /// deficit; beside weight management's strength-held check, a gentle check-in. Nil otherwise —
    /// too few weigh-ins say nothing.
    static func bodyWeightLine(_ status: PlateauStatus, inputs: SlotInputs) -> String? {
        guard let load = inputs.load, load.foodAware,
              WorkoutBodyWeightTrend.isFalling(load.bodyWeights, today: load.today) else { return nil }
        switch status.state {
        case .stalled: return load.focus == .size ? WorkoutPlannerCopy.bodyWeightSizeContext : nil
        case .eased: return WorkoutPlannerCopy.bodyWeightCheckIn
        case .dipping, .slowing, .tooEarly, .progressing: return nil
        }
    }

    /// G11: protein under the floor (``RecoverySummary/proteinUnderFloor``), only with the food-aware
    /// switch on, the logging good enough to read, and the trend calling a stall, a dip or a slowing.
    /// Never to weight management, and never a load change.
    static func proteinLine(_ status: PlateauStatus, inputs: SlotInputs) -> String? {
        guard let load = inputs.load, load.foodAware, inputs.goal != .weightManagement,
              load.recovery.proteinUnderFloor else { return nil }
        switch status.state {
        case .stalled, .dipping, .slowing: return WorkoutPlannerCopy.proteinFloor
        case .eased, .tooEarly, .progressing: return nil
        }
    }

    /// The plain training option: what today does about the trend, by its state and ladder step.
    static func trainingOption(
        _ pick: LoadedPick, name: String, status: PlateauStatus, loaded: [LoadedPick], goal: GoalType, older: Bool
    ) -> String {
        let guidance = pick.exercise.guidance
        let weight = guidance?.prescription.map(\.suggestedText)
        switch status.state {
        case .dipping:
            return WorkoutPlannerCopy.deload(name, sets: pick.exercise.sets, weight: weight)
        case .eased:
            return WorkoutPlannerCopy.easedOption
        case .slowing:
            return WorkoutPlannerCopy.slowing(name, older: older)
        case .tooEarly, .progressing:
            return WorkoutPlannerCopy.tooEarly(name)
        case .stalled:
            break
        }
        switch status.stage ?? .holdingSteady {
        case .fairRetest:
            return WorkoutPlannerCopy.fairRetest(name)
        case .loadingChange:
            guard let weight, let reps = guidance?.targetReps, guidance?.equipment != nil else {
                return WorkoutPlannerCopy.extraSet(name)
            }
            return WorkoutPlannerCopy.heavierBlock(name, reps: reps, weight: weight)
        case .variant:
            guard let variant = loaded.first(where: { $0.variantOf == pick.target.name }) else {
                return WorkoutPlannerCopy.holdingSteady(name, goal: goal, older: older)
            }
            return WorkoutPlannerCopy.variantBeside(ExerciseHowToCatalog.displayName(for: variant.target.name), lift: name)
        case .holdingSteady:
            return WorkoutPlannerCopy.holdingSteady(name, goal: goal, older: older)
        }
    }

    /// "Bench press has held steady for 3 weeks. That's normal…"
    static func plateauLead(_ name: String, weeks: Int) -> String {
        WorkoutPlannerCopy.plateauLead(name, weeks: weeks)
    }

    /// The block calendar's line (G2): which phase this is, its week, and what the main lifts do on a
    /// day of this energy.
    static func blockNote(_ week: BlockWeek, energy: WorkoutIntensity) -> String {
        WorkoutPlannerCopy.block(week.phase, week: week.week, of: WorkoutBlocks.phaseWeeks,
                                 sets: WorkoutBlocks.sets(week.phase, energy: energy), reps: week.phase.reps)
    }

    /// The calibration brief for the session note. `lift` is the frozen name; the note draws it in the
    /// device's language (``WorkoutPlannerCopy/exerciseName(_:)``, N8).
    static func calibrationNote(kind: CalibrationKind, lift: String, sets: [CalibrationSet], unit: LoadUnit) -> String {
        let keySet = sets.first(where: { $0.step != .ramp }) ?? sets.last
        let weight = keySet.map { loadText($0.weight, unit) } ?? ""
        return WorkoutPlannerCopy.calibration(kind, lift: WorkoutPlannerCopy.exerciseName(lift), weight: weight)
    }

    /// The count-based ladder's line when there is no load history to read (replaces the old
    /// "Week N" note, which counted completions, not weeks).
    static func ladderNote(_ lifting: [SlotPick], style: WorkoutGoalStyle) -> [String] {
        guard let first = lifting.first(where: { $0.completions > 0 && $0.exercise.holdSeconds == nil }),
              let scheme = RepScheme(style.reps(for: first.slot.role)) else { return [] }
        guard scheme.isRange else {
            return [WorkoutPlannerCopy.sameReps]
        }
        let reps = Int(first.exercise.reps) ?? scheme.low
        if reps == scheme.low {
            return [WorkoutPlannerCopy.ladderBackTo(reps: scheme.low)]
        }
        return [WorkoutPlannerCopy.repLadder(reps: reps, low: scheme.low, high: scheme.high)]
    }
}
