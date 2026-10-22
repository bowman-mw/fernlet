// WorkoutPlanLine.swift
// FernletDomainModel
//
// The planner's own plan-text lines, drawn in the user's language (2026-10-20, idea 16).
//
// A session's plan text is what its logged row records (`Workout.exercises`), and it is a format, not
// prose: the history parser reads its lift lines, `WorkoutProgram.descriptorMinutes(in:)` reads a
// cardio descriptor's " - 20 min" back as the logged duration, the time budget caps that number in
// place, and the trainer export and the AI adjuster pass the lines on as written. So the lines stay
// the frozen English the planner has always written — the warm-up and cool-down summaries
// (``WorkoutSessionBlocks/planText(for:)``), the conditioning descriptors (``WorkoutSessions``,
// ``WorkoutGoalStyle``) and the fallback circuit — and a screen draws each through ``displayed(_:)``.

import Foundation

/// The draw-time mapping from a frozen plan-text line to the line a screen shows.
public nonisolated enum WorkoutPlanLine {

    /// The line to draw: the localized form of a descriptor the planner writes, with its minutes kept,
    /// or `line` unchanged — a lift line ("Bench press - 3 x 8"), a typed line, anything else.
    public static func displayed(_ line: String) -> String {
        if let fixed = fixedLine(line) { return fixed }
        if let machine = WorkoutCardioMachines.machine(in: line), let drawn = machineLine(line, machine: machine) {
            return drawn
        }
        guard let range = line.range(of: " - ") else { return line }
        let head = String(line[..<range.lowerBound])
        let tail = line[range.upperBound...]
        guard tail.hasSuffix(" min"), let minutes = Int(tail.dropLast(4)), minutes > 0 else { return line }
        if head.hasSuffix(sportSuffix) {
            let sport = String(head.dropLast(sportSuffix.count))
            guard !sport.isEmpty else { return line }
            return String(localized: "workoutPlanLine.sportDrills", defaultValue: "\(sport) drills / conditioning - \(minutes) min",
                          bundle: .module,
                          comment: "A line of a workout plan: drills for the person's sport. Arguments: the sport as they typed it, then minutes.")
        }
        return timedLine(head, minutes: minutes) ?? line
    }

    /// A cardio line naming a machine (``WorkoutCardioMachines``), with the machine's name in the user's
    /// language: "Rowing machine - 20 min", "… - 20 min easy" or "… - 8 × 1 min hard / 1 min easy". Nil
    /// for any other clause — a typed "Rowing machine - 20 min 5 km" is drawn as written.
    static func machineLine(_ line: String, machine: String) -> String? {
        guard let range = line.range(of: " - ") else { return nil }
        let clause = String(line[range.upperBound...])
        let name = ExerciseHowToCatalog.displayName(for: machine)
        if clause == "8 × 1 min hard / 1 min easy" {
            return String(localized: "workoutPlanLine.machineIntervals", defaultValue: "\(name) - 8 × 1 min hard / 1 min easy",
                          bundle: .module,
                          comment: "A line of a workout plan: eight rounds of one hard minute and one easy minute on a cardio machine. The argument is the machine, e.g. Rowing machine.")
        }
        let easy = WorkoutCardioMachines.isEasy(clause: clause)
        let minutesText = easy ? String(clause.dropLast(WorkoutCardioMachines.easyMark.count + 1)) : clause
        guard minutesText.hasSuffix(" min"), let minutes = Int(minutesText.dropLast(4)), minutes > 0 else { return nil }
        if easy {
            return String(localized: "workoutPlanLine.machineEasy", defaultValue: "\(name) - \(minutes) min, easy", bundle: .module,
                          comment: "A line of a workout plan: an easy session on a cardio machine. Arguments: the machine (e.g. Stationary bike), then minutes.")
        }
        return String(localized: "workoutPlanLine.machine", defaultValue: "\(name) - \(minutes) min", bundle: .module,
                      comment: "A line of a workout plan: a session on a cardio machine. Arguments: the machine (e.g. Rowing machine), then minutes.")
    }

    /// The tail of the sport-prep conditioning line ("Basketball drills / conditioning - 15 min").
    static let sportSuffix = " drills / conditioning"

    /// The descriptors that name no minutes.
    static func fixedLine(_ line: String) -> String? {
        switch line {
        case "Intervals - 8 × 1 min hard / 1 min easy":
            String(localized: "workoutPlanLine.intervals", defaultValue: "Intervals - 8 × 1 min hard / 1 min easy", bundle: .module,
                   comment: "A line of a workout plan: eight rounds of one hard minute and one easy minute")
        case "Full-body bodyweight circuit - 3 rounds":
            String(localized: "workoutPlanLine.bodyweightCircuit", defaultValue: "Full-body bodyweight circuit - 3 rounds", bundle: .module,
                   comment: "A line of a workout plan: a circuit of bodyweight exercises, three times through")
        default: nil
        }
    }

    /// A descriptor that names its minutes, by its frozen head.
    static func timedLine(_ head: String, minutes: Int) -> String? {
        switch head {
        case "Warm-up stretch flow": String(localized: "workoutPlanLine.warmUpFlow", defaultValue: "Warm-up stretch flow - \(minutes) min", bundle: .module, comment: "A line of a workout plan: the warm-up stretches. The argument is minutes.")
        case "Cool-down stretches": String(localized: "workoutPlanLine.coolDown", defaultValue: "Cool-down stretches - \(minutes) min", bundle: .module, comment: "A line of a workout plan: the cool-down stretches. The argument is minutes.")
        case "Easy cardio": String(localized: "workoutPlanLine.easyCardio", defaultValue: "Easy cardio - \(minutes) min", bundle: .module, comment: "A line of a workout plan: gentle cardio. The argument is minutes.")
        case "Steady cardio": String(localized: "workoutPlanLine.steadyCardio", defaultValue: "Steady cardio - \(minutes) min", bundle: .module, comment: "A line of a workout plan: cardio at an even pace. The argument is minutes.")
        case "Mobility flow": String(localized: "workoutPlanLine.mobilityFlow", defaultValue: "Mobility flow - \(minutes) min", bundle: .module, comment: "A line of a workout plan: a mobility routine. The argument is minutes.")
        case "Conditioning intervals": String(localized: "workoutPlanLine.conditioningIntervals", defaultValue: "Conditioning intervals - \(minutes) min", bundle: .module, comment: "A line of a workout plan: interval conditioning. The argument is minutes.")
        case "Easy walk": String(localized: "workoutPlanLine.easyWalk", defaultValue: "Easy walk - \(minutes) min", bundle: .module, comment: "A line of a workout plan: an easy walk. The argument is minutes.")
        case "Gentle mobility + walk": String(localized: "workoutPlanLine.gentleMobilityWalk", defaultValue: "Gentle mobility + walk - \(minutes) min", bundle: .module, comment: "A line of a workout plan: gentle mobility work and a walk. The argument is minutes.")
        case "Optional cardio": String(localized: "workoutPlanLine.optionalCardio", defaultValue: "Optional cardio - \(minutes) min", bundle: .module, comment: "A line of a workout plan: cardio if the person wants it. The argument is minutes.")
        case "Gentle stretching or an easy walk": String(localized: "workoutPlanLine.restDayMovement", defaultValue: "Gentle stretching or an easy walk - \(minutes) min", bundle: .module, comment: "A line of a workout plan on a day the person marked themselves unwell. The argument is minutes.")
        default: nil
        }
    }
}
