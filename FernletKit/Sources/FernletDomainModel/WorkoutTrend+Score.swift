// WorkoutTrend+Score.swift
// FernletDomainModel
//
// One session's score for the trend (G1, the research report's step 1): the estimated max from the
// session's top one or two qualifying sets, averaged — averaging two sets cuts the noise by about a
// third. A set qualifies when its reps plus reps in reserve stay at 12 or fewer (10 or fewer
// preferred: the equations drift above that) and it was not stopped with four or more in reserve. A
// true single (one rep, nothing left) is its own max — Epley would inflate it 3.3 %. A lift with no
// load scores the average reps of its two best sets instead.
//
// The trend restarts when the rep scheme moves (a goal change from 8–12 to 5s shifts every estimate
// with no change in strength) and after a break of four weeks or more.

import Foundation

extension WorkoutTrend {

    /// Reps plus reps in reserve at most this for a preferred set…
    public static let preferredEffortReps = 10.0
    /// …and at most this for any set.
    public static let maximumEffortReps = 12.0
    /// A set stopped with this many reps in reserve or more says too little about the max.
    public static let excludedRepsInReserve = 4.0
    /// The best sets averaged into the score.
    public static let topSets = 2
    /// A lift done after this many compound lifts in its session is too tired to count.
    public static let fatiguingCompounds = 2
    /// A chosen weight this far outside the prescribed range still counts as "from the range".
    public static let rangeTolerance = 0.05
    /// A rep target this far from the segment's usual one restarts the trend.
    public static let schemeShiftReps = 3
    /// A gap this long between sessions restarts the trend.
    public static let restartGapDays = 28.0

    /// The lift's trend points, oldest first: its scored sessions since the rep scheme last moved and
    /// since its last long break, all of one kind (loaded, or reps only, as the newest session is).
    public static func points(from exposures: [LiftExposure], unit: LoadUnit) -> [TrendPoint] {
        let evidence = exposures.suffix(WorkoutLoadEngine.maxExposuresPerLift).filter(isEvidence)
        guard let latest = evidence.last else { return [] }
        let loaded = latest.weight != nil
        let segment = currentSegment(evidence.filter { ($0.weight != nil) == loaded }, loaded: loaded)
        return segment.compactMap { exposure in
            sessionScore(of: exposure, in: unit).map { TrendPoint(date: exposure.date, score: $0, flag: exposure.flag) }
        }
    }

    /// A session that can say something about the lift's strength: a working session (not a ramp set
    /// or a deload), not one that hurt, not buried behind two other compound lifts, and lifted from
    /// its prescribed range.
    public static func isEvidence(_ exposure: LiftExposure) -> Bool {
        guard exposure.calibration != .ramp, !exposure.easierSession, exposure.overrideReason != .pain,
              exposure.compoundsBefore < fatiguingCompounds else { return false }
        guard let weight = exposure.weight, let low = exposure.rangeLow, let high = exposure.rangeHigh else {
            return true
        }
        return weight >= low * (1 - rangeTolerance) && weight <= high * (1 + rangeTolerance)
    }

    /// The sessions since the rep scheme last moved and since the last gap of ``restartGapDays`` or
    /// more. A calibration set never moves the scheme; a lift with no load climbs its reps on
    /// purpose, so only its breaks restart it.
    static func currentSegment(_ exposures: [LiftExposure], loaded: Bool) -> [LiftExposure] {
        var segment: [LiftExposure] = []
        var targets: [Int] = []
        for exposure in exposures {
            if let previous = segment.last, days(from: previous.date, to: exposure.date) >= restartGapDays {
                segment = []
                targets = []
            }
            let calibrating = exposure.calibration == .test || exposure.calibration == .attempt
            if loaded, !calibrating, let usual = medianTarget(targets), abs(exposure.targetReps - usual) > schemeShiftReps {
                segment = []
                targets = []
            }
            segment.append(exposure)
            if !calibrating { targets.append(exposure.targetReps) }
        }
        return segment
    }

    /// The middle rep target (the lower middle of an even count), or nil with none.
    static func medianTarget(_ targets: [Int]) -> Int? {
        guard !targets.isEmpty else { return nil }
        let sorted = targets.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    /// One session's score in `unit`: the average estimated max of its top ``topSets`` qualifying sets
    /// (reps for a lift with no load), or nil when no set qualifies.
    public static func sessionScore(of exposure: LiftExposure, in unit: LoadUnit) -> Double? {
        guard isEvidence(exposure) else { return nil }
        guard exposure.weight != nil else {
            let reps = exposure.repsPerSet.filter { $0 > 0 }.sorted(by: >).prefix(topSets)
            guard !reps.isEmpty else { return nil }
            return Double(reps.reduce(0, +)) / Double(reps.count)
        }
        let estimates = setEstimates(of: exposure, in: unit)
        let preferred = estimates.filter { $0.effortReps <= preferredEffortReps }
        let pool = (preferred.isEmpty ? estimates : preferred).map { $0.estimate }.sorted(by: >).prefix(topSets)
        guard !pool.isEmpty else { return nil }
        return pool.reduce(0, +) / Double(pool.count)
    }

    /// Each qualifying set's estimated max in `unit`, with its reps plus reps in reserve.
    static func setEstimates(of exposure: LiftExposure, in unit: LoadUnit) -> [(estimate: Double, effortReps: Double)] {
        guard let working = exposure.weight else { return [] }
        let weights = exposure.setWeights ?? Array(repeating: working, count: exposure.repsPerSet.count)
        var estimates: [(estimate: Double, effortReps: Double)] = []
        for (reps, setWeight) in zip(exposure.repsPerSet, weights) {
            let weight = unit.converted(setWeight, from: exposure.unit ?? unit)
            let reserve = repsInReserve(reps: reps, of: exposure)
            let effortReps = Double(reps) + reserve
            guard reps >= 1, weight > 0, weight.isFinite, reserve < excludedRepsInReserve,
                  effortReps <= maximumEffortReps else { continue }
            let estimate = effortReps <= 1 ? weight : weight * (1 + effortReps / 30)
            estimates.append((estimate, effortReps))
        }
        return estimates
    }

    /// A set's reps in reserve: none on a max attempt or a set that fell short of its target (it went
    /// to the limit); otherwise the effort tap's, else the test set's or the prescription's own.
    static func repsInReserve(reps: Int, of exposure: LiftExposure) -> Double {
        guard exposure.calibration != .attempt, reps >= exposure.targetReps else { return 0 }
        if let effort = exposure.effort { return effort.repsInReserve }
        return exposure.calibration == .test ? WorkoutLoadEngine.testSetRepsInReserve : WorkoutLoadEngine.targetRepsInReserve
    }
}
