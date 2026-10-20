// WorkoutRecoveryGuard.swift
// FernletDomainModel
//
// The 48-hour same-muscle guard (2026-10-20). The split rotation alone would plan the same primary
// muscles hard on consecutive days — Full Body A on Monday, Full Body B on Tuesday. The guard reads the
// logged history (the guided runner's structured results and parsed hand-logged lines, gathered app-side
// into ``WorkoutRecoveryGuard/RecentTraining``) and, when today's split day would hard-train muscles that
// got hard working sets inside the window:
// 1. moves to the next split day that trains none of them — unless the overlap is built into the split's
//    own order (yesterday was the split day right before today's); moving then would push the same day
//    back on every pass through the split, so that day would never come round;
// 2. otherwise keeps the day and takes a set off each lift whose primary muscles overlap, with a plain
//    note saying why.
// Recovery and mobility days, and the warm-up, activation and cool-down, are exempt: only the lifting
// block is hard work. Defaults for the owner's review are the constants below.

import Foundation

/// The 48-hour same-muscle guard: which split day to plan, and which lifts to lighten.
///
/// Pure and deterministic over its inputs. With no recent hard work it changes nothing, so the plan
/// is exactly the rotation's.
public nonisolated enum WorkoutRecoveryGuard {
    /// The rule: at least this many hours between hard sessions for the same primary muscles.
    public static let windowHours = 48

    /// Whether a session logged `daysAgo` calendar days before today falls inside the window.
    ///
    /// Day granularity, so a plan doesn't change during the day: a past day counts while its typical
    /// gap to today — `daysAgo` × 24 h — is under ``windowHours``. With 48 h that is yesterday only:
    /// Monday then Tuesday is guarded, Monday then Wednesday (a full rest day between) is not. Today's
    /// own sessions never count, so logging today's workout doesn't move today's plan.
    public static func countsTowardWindow(daysAgo: Int) -> Bool {
        daysAgo >= 1 && daysAgo * 24 < windowHours
    }

    /// The past days the window reaches: every `daysAgo` in `1...lookbackDays` counts.
    public static var lookbackDays: Int { max(1, (windowHours - 1) / 24) }

    /// Sets a lightened lift gives up.
    public static let setsRemoved = 1
    /// No lightened lift drops below this many sets.
    public static let minimumSets = 1

    /// What the window saw.
    public struct RecentTraining: Equatable, Sendable {
        /// Primary muscles that got hard working sets inside the window.
        public var hardMuscles: Set<MuscleGroup>
        /// The workout names logged on the most recent day inside the window — how the guard tells
        /// whether that day was the split's own previous day.
        public var latestSessionNames: [String]

        public init(hardMuscles: Set<MuscleGroup> = [], latestSessionNames: [String] = []) {
            self.hardMuscles = hardMuscles
            self.latestSessionNames = latestSessionNames
        }

        /// Nothing logged inside the window.
        public static let empty = RecentTraining()
    }

    /// The guard's answer for one day.
    public struct Decision: Equatable, Sendable {
        /// The split day to plan.
        public var dayIndex: Int
        /// The rotation's day, when the guard moved off it; nil when it kept the rotation's day.
        public var movedFrom: Int?
        /// Muscles today's planned day shares with the window's hard work. Lifts working one of
        /// them as a primary muscle are lightened; empty on a moved or untouched day.
        public var overlap: Set<MuscleGroup>

        public init(dayIndex: Int, movedFrom: Int? = nil, overlap: Set<MuscleGroup> = []) {
            self.dayIndex = dayIndex
            self.movedFrom = movedFrom
            self.overlap = overlap
        }
    }

    /// The split day to plan and what to lighten on it, starting from the rotation's `dueIndex`.
    public static func decide(split: TrainingSplit, dueIndex: Int, recent: RecentTraining) -> Decision {
        let count = split.days.count
        guard count > 0 else { return Decision(dayIndex: 0) }
        let due = ((dueIndex % count) + count) % count
        let overlap = hardMuscles(of: split.days[due]).intersection(recent.hardMuscles)
        guard !overlap.isEmpty else { return Decision(dayIndex: due) }
        let previous = (due - 1 + count) % count
        let builtIn = WorkoutProgram.matchedDayIndex(in: split, names: recent.latestSessionNames) == previous
        // The other days in rotation order after the due one (none on a one-day split).
        let others = (0..<count).map { (due + $0) % count }.filter { $0 != due }
        let spared = others.first { hardMuscles(of: split.days[$0]).isDisjoint(with: recent.hardMuscles) }
        if !builtIn, let other = spared {
            return Decision(dayIndex: other, movedFrom: due)
        }
        return Decision(dayIndex: due, overlap: overlap)
    }

    /// The muscles a split day trains hard: the target muscles of the lifting slots in its strength,
    /// full-body and sport sessions. Core slots run in the light activation block and cardio and
    /// mobility sessions are recovery work, so neither counts.
    public static func hardMuscles(of day: WorkoutSplitDay) -> Set<MuscleGroup> {
        var muscles: Set<MuscleGroup> = []
        for session in day.sessions where session.kind == .strength || session.kind == .fullBody || session.kind == .sport {
            for slot in session.slots where slot.role != .core { muscles.formUnion(slot.muscles) }
        }
        return muscles
    }

    /// The primary muscles a logged set of `name` worked hard, or none: only rep-counted strength
    /// lifts the catalog knows count — a stretch, a hold, a jump or an unknown name does not.
    public static func hardMuscles(ofLift name: String) -> Set<MuscleGroup> {
        let exercise = WorkoutExerciseCatalog.exercise(named: name)
            ?? (name.hasSuffix("s") ? WorkoutExerciseCatalog.exercise(named: String(name.dropLast())) : nil)
        guard let exercise, exercise.modality == .strength, exercise.measure == .reps else { return [] }
        return exercise.primaryMuscles.subtracting([.fullBody])
    }

    /// One set fewer, never below ``minimumSets``.
    public static func lightenedSets(_ sets: Int) -> Int {
        max(minimumSets, sets - setsRemoved)
    }

    /// The note for a day the guard moved: "Push today instead of Legs — those muscles worked hard
    /// in the last 48 hours." Plain English, like the planner's other notes.
    static func movedNote(to day: WorkoutSplitDay, from due: WorkoutSplitDay) -> String {
        "\(label(day)) today instead of \(label(due)) — those muscles worked hard in the last \(windowHours) hours."
    }

    /// The note for lightened lifts: "One set fewer on Back squat, Lunge — those muscles worked hard
    /// in the last 48 hours."
    static func lightenedNote(lifts: [String]) -> String {
        "One set fewer on \(lifts.joined(separator: ", ")) — those muscles worked hard in the last \(windowHours) hours."
    }

    /// A day's name in a note: its one session's title ("Legs", "Full Body B"), else the day's own title.
    static func label(_ day: WorkoutSplitDay) -> String {
        day.sessions.count == 1 ? day.sessions[0].title : day.title
    }
}
