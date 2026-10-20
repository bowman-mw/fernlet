// WorkoutProgram+LoadNotes.swift
// FernletDomainModel
//
// The session-note lines the load pass writes: what changed on a lift and why, the plateau story,
// and the calibration brief. Tone, per the owner: plateaus are normal and a lighter day is training
// too — nothing here ever says "you failed". The sentences themselves are String Catalog keys in
// ``WorkoutPlannerCopy`` (2026-10-20, idea 16); this file decides which one a lift gets.

import Foundation

extension WorkoutProgram {

    /// Lines per session about ordinary progression, at most this many.
    static let maxProgressLines = 2

    /// What changed on the session's lifts, main lift first — at most two lines, plus one line for
    /// lifts that still need a first weight. Stalled lifts are left to the plateau story.
    static func progressNotes(_ loaded: [LoadedPick]) -> [String] {
        var lines: [String] = []
        var needsFirstWeight = false
        for pick in loaded where pick.plateau == nil {
            if let guidance = pick.exercise.guidance, guidance.isLoadable, guidance.prescription == nil {
                needsFirstWeight = true
            }
            guard lines.count < maxProgressLines, let plan = pick.plan,
                  let line = changeLine(pick.target.name, plan: plan) else { continue }
            lines.append(line)
        }
        if needsFirstWeight {
            lines.append(WorkoutPlannerCopy.newLifts)
        }
        return lines
    }

    /// One lift's change in a sentence, or nil when there is nothing worth saying.
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
        case .same, .firstTime: return nil
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

    /// The plateau story for the session's first stalled lift: that it's normal, the rest check
    /// (sleep and protein, only when they ran low), then what today does about it.
    static func plateauStory(_ loaded: [LoadedPick], recovery: RecoverySummary) -> [String]? {
        guard let pick = loaded.first(where: { $0.plateau != nil }), let status = pick.plateau else { return nil }
        let name = pick.standsInFor ?? pick.target.name
        var lines: [String] = []
        if status.stage != .supportWork { lines.append(plateauLead(name, weeks: status.weeksHeld)) }
        if status.stage == .easierSession || status.stage == .recover {
            lines += recoveryLines(recovery)
        }
        let rest = WorkoutPlannerCopy.extraRest(mainLift: pick.slot.role == .main)
        switch status.stage {
        case .easierSession:
            let weight = pick.exercise.guidance?.prescription.map(\.suggestedText)
            lines.append(WorkoutPlannerCopy.easierSession(name, sets: pick.exercise.sets, weight: weight))
        case .recover:
            lines.append(WorkoutPlannerCopy.recoverFirst(name, rest: rest))
        case .supportWork:
            lines.append(WorkoutPlannerCopy.supportRest(name, rest: rest))
        case .afterVariation:
            lines.append(WorkoutPlannerCopy.afterVariation(name, rest: rest))
        case .variation:
            break
        }
        return lines
    }

    /// "Bench press has held steady for 3 weeks. That's normal…"
    static func plateauLead(_ name: String, weeks: Int) -> String {
        WorkoutPlannerCopy.plateauLead(name, weeks: weeks)
    }

    /// The rest check's lines: said only when sleep or protein ran low, silent with no data. The hours
    /// carry one decimal in the device's own number format ("6.5", "6,5").
    static func recoveryLines(_ recovery: RecoverySummary) -> [String] {
        var lines: [String] = []
        if recovery.sleepIsLow, let hours = recovery.averageSleepHours, hours.isFinite {
            let text = hours.formatted(.number.precision(.fractionLength(1)).grouping(.never))
            lines.append(WorkoutPlannerCopy.sleepLow(hours: text))
        }
        if recovery.proteinIsLow, let ratio = recovery.averageProteinRatio, ratio.isFinite {
            let percent = Int((ratio * 100).rounded())
            lines.append(WorkoutPlannerCopy.proteinLow(percent: percent))
        }
        return lines
    }

    /// The calibration brief for the session note.
    static func calibrationNote(kind: CalibrationKind, lift: String, sets: [CalibrationSet], unit: LoadUnit) -> String {
        let keySet = sets.first(where: { $0.step != .ramp }) ?? sets.last
        let weight = keySet.map { loadText($0.weight, unit) } ?? ""
        return WorkoutPlannerCopy.calibration(kind, lift: lift, weight: weight)
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
