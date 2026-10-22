// WorkoutCardioMachines.swift
// FernletDomainModel
//
// The cardio machine a planned cardio session names (2026-10-21, the owner's call on the Gym Visual
// shortlist: the planner schedules the location's machine instead of a generic line).

import Foundation

/// The step from the planner's generic cardio line to a machine the location has.
///
/// A cardio session used to be one generic line ("Easy cardio - 20 min") whatever the location held.
/// Where the location has a cardio machine the person may use (``WorkoutSafetyFilter`` already put it
/// in the plan's feasible pool, so its gear is owned, the person's injuries allow it, and "Don't
/// suggest" was respected), the line now names it by its frozen catalog name: "Rowing machine - 20 min
/// easy". The plan then says what to get on, the runner's step IS that exercise (a segment is named by
/// its line's label, so the how-to sheet and the localized name come with it), and Apple Health files
/// the session as rowing rather than mixed cardio. With no machine — a park, a home without one, or
/// none the person's injuries allow — the generic line stays. Machines rotate by the split's rotation
/// index, so a gym with a bike and a rower alternates them from one cardio day to the next.
///
/// The lines are plan TEXT and stay frozen English: ``WorkoutProgram/descriptorMinutes(in:)`` still
/// reads " - 20 min", ``WorkoutTimedSessions/classify(_:)`` times them (the trailing "easy" keeps an
/// easy session's pace), and ``WorkoutPlanLine/displayed(_:)`` draws them in the user's language. The
/// planner names the machine after the time budget has capped the minutes, so the cap's rewrite never
/// drops the "easy" mark.
public nonisolated enum WorkoutCardioMachines {

    /// What a generic cardio line asks of the machine.
    enum Effort: Sendable {
        case easy, steady, intervals
    }

    /// The word an easy session's machine line ends with ("Stationary bike - 20 min easy").
    static let easyMark = "easy"

    /// The generic interval line, which names no minutes.
    static let intervalsLine = "Intervals - 8 × 1 min hard / 1 min easy"

    /// Every machine a line can name, by its frozen catalog name.
    public static let machineNames: Set<String> = [
        "Stationary bike", "Recumbent bike", "Elliptical", "Rowing machine", "Stair climber", "Treadmill walk",
    ]

    /// The machines each effort prefers, best first: the low-impact bike and elliptical for easy work,
    /// the whole-body rower for steady and interval work. A treadmill walk stays a choice for easy and
    /// steady work; a treadmill run is never named, for its impact. The recumbent bike is never named
    /// either: a location owns an "Exercise bike" without saying which kind, so the plan names the
    /// upright one and the swap sheet offers the recumbent.
    static func preference(for effort: Effort) -> [String] {
        switch effort {
        case .easy:
            ["Stationary bike", "Elliptical", "Rowing machine", "Treadmill walk", "Stair climber"]
        case .steady:
            ["Rowing machine", "Elliptical", "Stationary bike", "Stair climber", "Treadmill walk"]
        case .intervals:
            ["Rowing machine", "Stationary bike", "Elliptical", "Stair climber"]
        }
    }

    /// The effort a generic line the planner writes asks for, or nil for every other line (a walk,
    /// sport drills, a typed line, a line already naming a machine).
    static func effort(of line: String) -> Effort? {
        if line == intervalsLine { return .intervals }
        guard let range = line.range(of: " - ") else { return nil }
        switch line[..<range.lowerBound] {
        case "Easy cardio": return .easy
        case "Steady cardio": return .steady
        default: return nil
        }
    }

    /// `line` naming one of the machines in `feasible`, chosen by `seed` among those its effort
    /// prefers, or `line` unchanged when it is not a generic cardio line or no machine fits.
    public static func named(_ line: String, feasible: [ExerciseTarget], seed: Int) -> String {
        guard let effort = effort(of: line), let range = line.range(of: " - ") else { return line }
        let available = Set(feasible.map(\.name))
        let machines = preference(for: effort).filter(available.contains)
        guard !machines.isEmpty else { return line }
        let machine = machines[((seed % machines.count) + machines.count) % machines.count]
        let clause = line[range.upperBound...]
        switch effort {
        case .easy: return "\(machine) - \(clause) \(easyMark)"
        case .steady, .intervals: return "\(machine) - \(clause)"
        }
    }

    /// The machine a plan line names ("Rowing machine - 20 min" → "Rowing machine"), or nil.
    public static func machine(in line: String) -> String? {
        guard let range = line.range(of: " - ") else { return nil }
        let head = String(line[..<range.lowerBound])
        return machineNames.contains(head) ? head : nil
    }

    /// Whether a machine line's clause ends with the easy mark ("20 min easy").
    static func isEasy(clause: String) -> Bool {
        clause.lowercased().hasSuffix(" \(easyMark)")
    }

    /// The activity a session on `machine` files as in Apple Health, or nil for a name that is not
    /// one of the machines.
    static func activityType(forMachine machine: String) -> WorkoutActivityType? {
        switch machine {
        case "Stationary bike", "Recumbent bike": .indoorCycling
        case "Rowing machine": .rowing
        case "Elliptical": .elliptical
        case "Stair climber": .stairClimbing
        case "Treadmill walk": .walking
        default: nil
        }
    }
}
