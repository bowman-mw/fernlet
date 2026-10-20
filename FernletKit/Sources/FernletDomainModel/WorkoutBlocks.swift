// WorkoutBlocks.swift
// FernletDomainModel
//
// Planned blocks for trained Strength lifters (the owner's G2 pick, 2026-10-20). A lifter past their
// first six months on a lift gains slowly enough that "a little more each session" stops working;
// the research report's answer is planned blocks — a volume phase (more work at a moderate weight)
// then a heavier phase (fewer reps at more weight) — with the plateau detector as the backup. Each
// phase lasts ``WorkoutBlocks/phaseWeeks`` weeks and the two alternate, so a cycle is eight weeks.
//
// The phases change the main lifts' rep scheme only (6 reps, then 3), so the load engine rebaselines
// each lift from its estimate at the switch (``WorkoutLoadEngine/recalibrationReason(anchor:history:scheme:ceiling:)``)
// and the trend reads both phases as one line: the two targets sit within three reps of each other,
// so the trend never restarts at a switch (``WorkoutTrend/schemeShiftReps``).
//
// The calendar counts from one fixed Monday, so every device and every lift agrees on the phase, and
// nothing about a block is stored.

import Foundation

/// A planned block's phase (G2).
public nonisolated enum BlockPhase: String, CaseIterable, Sendable {
    /// More work at a moderate weight.
    case volume
    /// Fewer reps at more weight.
    case heavier

    /// The main lifts' reps in this phase.
    public var reps: Int {
        switch self {
        case .volume: 6
        case .heavier: 3
        }
    }

    /// The main lifts' sets in this phase, before the day's energy adjusts them.
    public var sets: Int {
        switch self {
        case .volume: 4
        case .heavier: 5
        }
    }
}

/// Where today sits in the block calendar: the phase, and the week of it (1 … ``WorkoutBlocks/phaseWeeks``).
public nonisolated struct BlockWeek: Equatable, Sendable {
    public var phase: BlockPhase
    public var week: Int

    public init(phase: BlockPhase, week: Int) {
        self.phase = phase
        self.week = min(max(1, week), WorkoutBlocks.phaseWeeks)
    }
}

/// The block calendar and who it applies to.
public nonisolated enum WorkoutBlocks {

    /// Weeks in each phase (the research's 4–8-week blocks, at their short end: a cycle of both
    /// phases is eight weeks).
    public static let phaseWeeks = 4

    /// Monday 5 January 2026, 00:00 UTC: every lifter's block calendar counts from here.
    public static let epoch = Date(timeIntervalSince1970: 1_767_571_200)

    /// The phase and week on `date`. A date before the calendar starts reads as its first week.
    public static func week(on date: Date) -> BlockWeek {
        let interval = date.timeIntervalSince(epoch) / 86_400
        let days = interval.isFinite ? max(0, Int(interval.rounded(.down))) : 0
        let phaseDays = phaseWeeks * 7
        let phase: BlockPhase = (days / phaseDays).isMultiple(of: 2) ? .volume : .heavier
        return BlockWeek(phase: phase, week: (days % phaseDays) / 7 + 1)
    }

    /// Whether a lift follows the block calendar: a main lift, for someone whose goal is Strength,
    /// past their first six months on that lift.
    public static func applies(goal: GoalType, tier: TrainingTier, role: SlotRole) -> Bool {
        guard goal == .strength, role == .main else { return false }
        return tier != .beginner
    }

    /// The phase's sets after the day's energy: a light day one fewer, a hard day one more, never
    /// under two (``WorkoutGoalStyle/adjustedSets(for:energy:)``'s rule).
    public static func sets(_ phase: BlockPhase, energy: WorkoutIntensity) -> Int {
        let delta = energy == .light ? -1 : (energy == .hard ? 1 : 0)
        return max(2, phase.sets + delta)
    }
}
