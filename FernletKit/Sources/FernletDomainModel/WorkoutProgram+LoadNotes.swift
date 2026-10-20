// WorkoutProgram+LoadNotes.swift
// FernletDomainModel
//
// The session-note lines the load pass writes: what changed on a lift and why, the plateau story,
// and the calibration brief. Tone, per the owner: plateaus are normal and a lighter day is training
// too — nothing here ever says "you failed". Plain English like the rest of the planner's copy.

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
            lines.append("New lifts: pick a weight you could lift about 2 more times than asked — Fernlet learns from there.")
        }
        return lines
    }

    /// One lift's change in a sentence, or nil when there is nothing worth saying.
    static func changeLine(_ name: String, plan: LiftPlan) -> String? {
        let weight = plan.prescription.map(\.suggestedText)
        let inParens = weight.map { " (\($0))" } ?? ""
        if plan.recentered, plan.change != .recalibrated {
            return "\(name): the range now centers on the weights you've been choosing."
        }
        switch plan.change {
        case .moreReps: return "\(name): \(plan.reps) reps today, one more than last time."
        case .moreSets: return "\(name): one more set today."
        case .addWeight: return weight.map { "\(name): up to \($0) today." }
        case .backToBottom: return "\(name): back to \(plan.reps) reps — add weight now\(inParens)."
        case .lighter: return "\(name): a little lighter today\(inParens) to get the reps back."
        case .lighterFewerSets: return "\(name): lighter and one set fewer today — a reset, not a step back."
        case .afterBreak: return "\(name): welcome back — a little lighter to start\(inParens)."
        case .recalibrated: return "\(name): starting from a fresh estimate\(inParens)."
        case .holdForPain:
            return "\(name): holding steady after it hurt last time. If it still hurts, try a different exercise or check with a professional."
        case .holdForEquipment: return "\(name): same weight, one more rep — working with the equipment you have."
        case .same, .firstTime: return nil
        }
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
        let rest = pick.slot.role == .main ? "+1 min" : "+30 s"
        switch status.stage {
        case .easierSession:
            let weight = pick.exercise.guidance?.prescription.map { " at about \($0.suggestedText)" } ?? ", lighter than usual"
            lines.append("Today is an easier \(name) session: \(pick.exercise.sets) sets\(weight). An extra rest day instead is fine too — both count as training.")
        case .recover:
            lines.append("\(name) goes first today, with a little more rest between sets (\(rest)).")
        case .supportWork:
            lines.append("A little more rest between \(name) sets (\(rest)).")
        case .afterVariation:
            lines.append("Back to \(name), with a little more rest between sets (\(rest)).")
        case .variation:
            break
        }
        return lines
    }

    /// "Bench press has held steady for 3 weeks. That's normal…"
    static func plateauLead(_ name: String, weeks: Int) -> String {
        let span = weeks >= 2 ? "for \(weeks) weeks" : "for a few sessions"
        return "\(name) has held steady \(span). That's normal — strength comes in steps, and a pause often means your body wants more recovery."
    }

    /// The rest check's lines: said only when sleep or protein ran low, silent with no data.
    static func recoveryLines(_ recovery: RecoverySummary) -> [String] {
        var lines: [String] = []
        if recovery.sleepIsLow, let hours = recovery.averageSleepHours {
            let text = String(format: "%.1f", hours)
            lines.append("Sleep has averaged \(text) hours these past two weeks. More sleep is often the quickest way through.")
        }
        if recovery.proteinIsLow, let ratio = recovery.averageProteinRatio, ratio.isFinite {
            let percent = Int((ratio * 100).rounded())
            lines.append("Protein has run about \(percent)% of your target lately — a little more helps muscles rebuild.")
        }
        return lines
    }

    /// The calibration brief for the session note.
    static func calibrationNote(kind: CalibrationKind, lift: String, sets: [CalibrationSet], unit: LoadUnit) -> String {
        let keySet = sets.first(where: { $0.step != .ramp }) ?? sets.last
        let weight = keySet.map { "\(WorkoutLoadEngine.weightText($0.weight)) \(unit.rawValue)" } ?? ""
        switch kind {
        case .submaximal:
            return "Strength check today: \(lift) builds up over a few lighter sets, then one test set at \(weight) — as many good reps as you can, stopping with 1–2 left. Accessories are a set lighter."
        case .strengthCheck:
            return "Quick strength check today: one \(lift) set at \(weight) for as many good reps as you can, stopping with 1–2 left — edit the reps when you're done. Accessories are a set lighter."
        case .oneRepMax:
            return "Max test today: \(lift) builds up to three single attempts, starting at \(weight). Use a spotter or safety arms, stop if your form breaks, and skip it if you're sore, sick or short on sleep. Miss one and the rest are skipped."
        }
    }

    /// The count-based ladder's line when there is no load history to read (replaces the old
    /// "Week N" note, which counted completions, not weeks).
    static func ladderNote(_ lifting: [SlotPick], style: WorkoutGoalStyle) -> [String] {
        guard let first = lifting.first(where: { $0.completions > 0 && $0.exercise.holdSeconds == nil }),
              let scheme = RepScheme(style.reps(for: first.slot.role)) else { return [] }
        guard scheme.isRange else {
            return ["Same reps as last time — nudge the weight up a little when the last set feels solid."]
        }
        let reps = Int(first.exercise.reps) ?? scheme.low
        if reps == scheme.low {
            return ["Back to \(scheme.low) reps — add weight now, about 2.5–5%."]
        }
        return ["Rep ladder: \(reps) of \(scheme.low)–\(scheme.high) today. One more rep each time; at \(scheme.high), add weight."]
    }
}
