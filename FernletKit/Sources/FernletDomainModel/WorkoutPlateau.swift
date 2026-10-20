// WorkoutPlateau.swift
// FernletDomainModel
//
// Plateau detection and the gentle response, the owner's spec of 2026-10-19. A plateau is not "the
// same weight appeared for three weeks": it is a lift Fernlet cannot progress despite steady training.
// So the check reads demonstrated performance (estimated max, or reps for a lift with no load), the
// prescription it came from, effort, where the lift sat in the session, how often it was trained, and
// whether overrides explain the numbers instead. Stateless like the load engine: the onset and the
// response stage are re-derived from the history every time.
//
// The response follows the owner's order — rest and recovery first, then load and volume, then
// support work for the helper muscles, and only then a different exercise — and a new best clears it
// at any point. The copy says plateaus are normal; it never says "you failed".

import Foundation

/// Where a lift is in its plateau response, counted in sessions since the plateau was suspected.
public nonisolated enum PlateauStage: Hashable, Sendable {
    /// The first response session: half the sets, about 10 % lighter — or an extra rest day.
    case easierSession
    /// The second: the usual load, a minute more rest, and the lift moves to the front.
    case recover
    /// Sessions three to six: one accessory slot becomes support work for the helper muscles.
    case supportWork
    /// Still stuck: a variation stands in for the lift for four weeks.
    case variation
    /// Back on the lift after the variation, with the longer rest kept.
    case afterVariation
}

/// A suspected plateau on one lift.
public nonisolated struct PlateauStatus: Equatable, Sendable {
    public var stage: PlateauStage
    /// Sessions of the lift logged since the plateau was suspected.
    public var sessionsSinceOnset: Int
    /// Whole weeks since the lift last set a best, for the copy.
    public var weeksHeld: Int
}

/// Recent sleep and protein, summarized by the app for the plateau's recovery check.
public nonisolated struct RecoverySummary: Equatable, Sendable {
    public var averageSleepHours: Double?
    public var sleepNights: Int
    /// Average share of the protein target eaten, over days with meals logged (1.0 = on target).
    public var averageProteinRatio: Double?
    public var proteinDays: Int

    public init(averageSleepHours: Double? = nil, sleepNights: Int = 0, averageProteinRatio: Double? = nil, proteinDays: Int = 0) {
        self.averageSleepHours = averageSleepHours
        self.sleepNights = max(0, sleepNights)
        self.averageProteinRatio = averageProteinRatio
        self.proteinDays = max(0, proteinDays)
    }

    /// Nothing known: the recovery check stays quiet.
    public static let unknown = RecoverySummary()

    /// Under seven hours on average, over at least three logged nights.
    public var sleepIsLow: Bool {
        guard sleepNights >= WorkoutPlateau.sleepMinimumNights, let hours = averageSleepHours else { return false }
        return hours < WorkoutPlateau.sleepLowHours
    }

    /// Under 80 % of the protein target on average, over at least four days with meals.
    public var proteinIsLow: Bool {
        guard proteinDays >= WorkoutPlateau.proteinMinimumDays, let ratio = averageProteinRatio else { return false }
        return ratio < WorkoutPlateau.proteinLowRatio
    }
}

/// Detects a stalled lift and says where its response stands.
public nonisolated enum WorkoutPlateau {

    // MARK: Approved numbers (owner, 2026-10-19)

    /// Adherence: at least this many sessions of the lift in the four weeks before the latest…
    public static let minimumRecentSessions = 3
    public static let recentWindowDays = 28
    /// …with no gap longer than this between them.
    public static let maximumGapDays = 14
    /// The latest sessions that must fail to beat the earlier best…
    public static let stalledSessions = 4
    /// …by more than this fraction.
    public static let improvementThreshold = 0.01
    /// How far back the earlier best may come from.
    public static let lookbackDays = 112
    /// A lift untouched this long is on a break, not a plateau.
    public static let staleDays = 42
    /// Overrides in the latest sessions that make it a calibration problem instead.
    public static let overridesThatExplain = 2
    /// A lift done after this many compound lifts in its session is too tired to count.
    public static let fatiguingCompounds = 2
    /// A chosen weight this far outside the range still counts as "from the range".
    public static let rangeTolerance = 0.05
    /// Structured sessions that completed and progressed allowed among the stalled ones.
    public static let progressedSessionsAllowed = 1
    /// How long a variation stands in.
    public static let variationDays = 28
    /// Response sessions per cycle: one easier, one recover, four support, then the variation.
    static let cycleLength = 7

    public static let sleepLowHours = 7.0
    public static let sleepMinimumNights = 3
    public static let proteinLowRatio = 0.8
    public static let proteinMinimumDays = 4
    /// Extra rest between sets on a stalled lift, by its role.
    public static let extraRestMainSeconds = 60
    public static let extraRestAccessorySeconds = 30
    /// The easier session: this much lighter, and half the sets.
    public static let easierLoadDecrease = 0.10

    // MARK: Detection

    /// The lift's plateau, or nil when it is progressing, too new, on a break, or explained by
    /// overrides. `exposures` are the lift's sessions, oldest first.
    public static func status(of exposures: [LiftExposure], unit: LoadUnit, today: Date) -> PlateauStatus? {
        let history = Array(exposures.suffix(WorkoutLoadEngine.maxExposuresPerLift).filter { $0.calibration != .ramp })
        guard let last = history.last, WorkoutLoadEngine.days(from: last.date, to: today) <= staleDays else {
            return nil
        }
        var onset: Int?
        let first = stalledSessions + 1
        guard history.count >= first else { return nil }
        for end in first...history.count {
            if isStalled(Array(history.prefix(end)), unit: unit) {
                onset = onset ?? (end - 1)
            } else {
                onset = nil
            }
        }
        guard let onset else { return nil }
        let since = history.count - 1 - onset
        return PlateauStatus(
            stage: stage(sessionsSinceOnset: since, lastSession: last.date, today: today),
            sessionsSinceOnset: since,
            weeksHeld: weeksSinceBest(history, unit: unit, today: today)
        )
    }

    /// The response stage for `sessionsSinceOnset`, cycling if a whole response passes with no new best.
    public static func stage(sessionsSinceOnset: Int, lastSession: Date, today: Date) -> PlateauStage {
        switch sessionsSinceOnset % cycleLength {
        case 0: return .easierSession
        case 1: return .recover
        case 2...5: return .supportWork
        default:
            let inVariation = WorkoutLoadEngine.days(from: lastSession, to: today) < variationDays
            return inVariation ? .variation : .afterVariation
        }
    }

    /// Whether the sessions up to the newest one show a stall, judged as of the newest session.
    static func isStalled(_ sessions: [LiftExposure], unit: LoadUnit) -> Bool {
        guard let last = sessions.last, isAdherent(sessions, asOf: last.date) else { return false }
        let overrides = sessions.suffix(stalledSessions).filter { $0.overrideDirection != nil }.count
        guard overrides < overridesThatExplain else { return false }
        let weighted = sessions.last(where: isEvidence)?.weight != nil
        let evidence = sessions.filter {
            isEvidence($0) && WorkoutLoadEngine.days(from: $0.date, to: last.date) <= lookbackDays
                && metric($0, weighted: weighted, unit: unit) != nil
        }
        guard evidence.count > stalledSessions else { return false }
        let recent = evidence.suffix(stalledSessions)
        let progressed = recent.filter { $0.structured && $0.completed && $0.effort != .tough }.count
        guard progressed <= progressedSessionsAllowed else { return false }
        let earlierBest = evidence.dropLast(stalledSessions).compactMap { metric($0, weighted: weighted, unit: unit) }.max()
        let recentBest = recent.compactMap { metric($0, weighted: weighted, unit: unit) }.max()
        guard let earlierBest, let recentBest, recentBest <= earlierBest * (1 + improvementThreshold) else {
            return false
        }
        guard weighted else { return true }
        let confidence = WorkoutLoadEngine.estimate(from: sessions, unit: unit, today: last.date)?.confidence ?? .none
        return confidence >= .medium
    }

    /// Steady recent training: enough sessions in the four weeks before `date`, none far apart.
    static func isAdherent(_ sessions: [LiftExposure], asOf date: Date) -> Bool {
        let recent = sessions.filter { WorkoutLoadEngine.days(from: $0.date, to: date) <= recentWindowDays }
        guard recent.count >= minimumRecentSessions else { return false }
        for index in recent.indices.dropFirst() {
            let gap = WorkoutLoadEngine.days(from: recent[index - 1].date, to: recent[index].date)
            guard gap <= maximumGapDays else { return false }
        }
        return true
    }

    /// A session that can count as "no progress": a real working session, from the range, not marked
    /// easy, not buried behind two other compound lifts, and not one that hurt.
    static func isEvidence(_ exposure: LiftExposure) -> Bool {
        guard exposure.calibration != .ramp, !exposure.easierSession, exposure.effort != .easy,
              exposure.compoundsBefore < fatiguingCompounds, exposure.overrideReason != .pain else {
            return false
        }
        guard let weight = exposure.weight, let low = exposure.rangeLow, let high = exposure.rangeHigh else {
            return true
        }
        return weight >= low * (1 - rangeTolerance) && weight <= high * (1 + rangeTolerance)
    }

    /// Demonstrated performance: the estimated max for a loaded lift, the best set's reps otherwise.
    static func metric(_ exposure: LiftExposure, weighted: Bool, unit: LoadUnit) -> Double? {
        guard weighted else { return exposure.weight == nil ? Double(exposure.bestReps) : nil }
        return WorkoutLoadEngine.estimatedMax(of: exposure, in: unit)
    }

    /// Whole weeks since the lift's best performance, for "has held steady for 3 weeks".
    static func weeksSinceBest(_ history: [LiftExposure], unit: LoadUnit, today: Date) -> Int {
        let weighted = history.last(where: isEvidence)?.weight != nil
        var best: (value: Double, date: Date)?
        for exposure in history {
            guard let value = metric(exposure, weighted: weighted, unit: unit) else { continue }
            if value > (best?.value ?? 0) * (1 + improvementThreshold) { best = (value, exposure.date) }
        }
        guard let best else { return 0 }
        return max(1, WorkoutLoadEngine.days(from: best.date, to: today) / 7)
    }

    // MARK: Support work

    /// The muscles that help a lift, most useful first: the owner's curated list for the big
    /// patterns, then the lift's own secondary muscles.
    ///
    /// Bench → triceps, upper back, rear delts; overhead press → triceps, side delts, upper back;
    /// squat → glutes, hamstrings, core, upper back; deadlift → glutes, hamstrings, grip, lats;
    /// rows and pull-ups → biceps, rear delts, grip.
    public static func helperMuscles(for lift: ExerciseTarget) -> [MuscleGroup] {
        var helpers = curatedHelpers(for: lift)
        let secondary = MuscleGroup.allCases.filter {
            lift.secondaryMuscles.contains($0) && !lift.primaryMuscles.contains($0) && $0 != .fullBody
        }
        for muscle in secondary where !helpers.contains(muscle) { helpers.append(muscle) }
        return helpers
    }

    /// The owner's helper list for a lift's pattern, empty for patterns it doesn't name.
    static func curatedHelpers(for lift: ExerciseTarget) -> [MuscleGroup] {
        let shoulders: Set<MuscleGroup> = [.frontDelts, .sideDelts]
        switch lift.movementPattern {
        case .push where lift.primaryMuscles.contains(.chest): return [.triceps, .upperBack, .rearDelts]
        case .push where !lift.primaryMuscles.isDisjoint(with: shoulders): return [.triceps, .sideDelts, .upperBack]
        case .squat: return [.glutes, .hamstrings, .abs, .upperBack]
        case .hinge: return [.glutes, .hamstrings, .forearms, .lats]
        case .pull: return [.biceps, .rearDelts, .forearms]
        default: return []
        }
    }
}
