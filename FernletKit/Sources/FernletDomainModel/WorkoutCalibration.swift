// WorkoutCalibration.swift
// FernletDomainModel
//
// The monthly strength calibration, the owner's spec of 2026-10-19. For people without a coach
// plan, about every four weeks the next regular session's main lift becomes a test, so the estimate
// the load engine prescribes from stays honest. The default test is submaximal — a short ramp, then
// one set at the five-rep weight, stopped with a rep or two left — because repeat-set performance
// predicts training loads better than a single max. When the existing data is already reliable the
// test shrinks to one "strength check" set. A true one-rep max is opt-in, for intermediate and
// advanced lifters only, and is never treated as more authoritative than the submaximal estimate.
//
// Deterministic: the same estimate, profile and day always build the same sets.

import Foundation

/// Whether calibration applies to this person, and when they last did one.
public nonisolated struct CalibrationSettings: Equatable, Sendable {
    /// Coach plans own their own testing: no automatic calibration while coach exchange is on.
    public var hasCoach: Bool
    public var lastCalibration: Date?

    public init(hasCoach: Bool = false, lastCalibration: Date? = nil) {
        self.hasCoach = hasCoach
        self.lastCalibration = lastCalibration
    }
}

/// The three calibration protocols.
public nonisolated enum CalibrationKind: Equatable, Sendable {
    /// Ramp, then one set at the five-rep weight, stopped with one or two reps left.
    case submaximal
    /// The data is reliable already: one test set at today's suggested weight.
    case strengthCheck
    /// The opt-in true max: a longer ramp, then up to three singles.
    case oneRepMax
}

/// One set of a calibration protocol.
public nonisolated struct CalibrationSet: Equatable, Sendable {
    public var step: CalibrationStep
    public var reps: Int
    public var weight: Double
    public var restSeconds: Int

    public init(step: CalibrationStep, reps: Int, weight: Double, restSeconds: Int) {
        self.step = step
        self.reps = reps
        self.weight = weight
        self.restSeconds = restSeconds
    }
}

/// When calibration is due and what it prescribes.
public nonisolated enum WorkoutCalibration {

    // MARK: Approved numbers (owner, 2026-10-19)

    /// Days between calibrations.
    public static let intervalDays = 28
    /// Regular weighted sessions a lift needs before its first calibration.
    public static let minimumSessions = 2
    /// The submaximal test's target reps.
    public static let testReps = 5
    /// The submaximal ramp, as fractions of the test weight.
    static let submaximalRamp: [(fraction: Double, reps: Int)] = [(0.5, 8), (0.7, 4), (0.85, 2)]
    /// The one-rep-max ramp, as fractions of the estimated max.
    static let oneRepMaxRamp: [(fraction: Double, reps: Int)] = [(0.5, 5), (0.7, 3), (0.8, 2), (0.9, 1)]
    /// The three singles, as fractions of the estimated max.
    static let attemptFractions: [Double] = [1.0, 1.025, 1.05]
    public static let rampRestSeconds = 60
    public static let testRestSeconds = 180
    public static let attemptRestSeconds = 240

    /// Due when there is no coach plan, today isn't a light day, and four weeks have passed since the
    /// last calibration (or there has never been one).
    public static func isDue(_ settings: CalibrationSettings, intensity: WorkoutIntensity, today: Date) -> Bool {
        guard !settings.hasCoach, intensity != .light else { return false }
        guard let last = settings.lastCalibration else { return true }
        return WorkoutLoadEngine.days(from: last, to: today) >= intervalDays
    }

    /// A lift can be calibrated once it has two regular weighted sessions to ramp from.
    public static func isEligible(_ exposures: [LiftExposure]) -> Bool {
        exposures.filter { $0.weight != nil && $0.calibration == nil && !$0.easierSession }.count >= minimumSessions
    }

    /// The protocol for this lifter: the opt-in max for trained lifters who asked, a strength check
    /// when the estimate is already trusted, the submaximal test otherwise.
    public static func kind(profile: WorkoutProfile, confidence: EstimateConfidence) -> CalibrationKind {
        if profile.oneRepMaxTesting && profile.experience != .beginner { return .oneRepMax }
        return confidence == .high ? .strengthCheck : .submaximal
    }

    /// The sets of one calibration, on the equipment's steps.
    ///
    /// - Parameters:
    ///   - todaysSuggested: the regular prescription's suggested weight, used by the strength check.
    ///   - todaysReps: the regular prescription's reps, used by the strength check.
    public static func sets(
        kind: CalibrationKind, oneRepMax: Double, todaysSuggested: Double?, todaysReps: Int, step: Double
    ) -> [CalibrationSet] {
        guard oneRepMax > 0, oneRepMax.isFinite, step > 0 else { return [] }
        switch kind {
        case .strengthCheck:
            let weight = todaysSuggested ?? testWeight(oneRepMax: oneRepMax, step: step)
            return [CalibrationSet(step: .test, reps: max(1, todaysReps), weight: weight, restSeconds: testRestSeconds)]
        case .submaximal:
            let test = testWeight(oneRepMax: oneRepMax, step: step)
            let ramp = submaximalRamp.map {
                CalibrationSet(step: .ramp, reps: $0.reps, weight: onStep(test * $0.fraction, step: step),
                               restSeconds: rampRestSeconds)
            }
            return ramp + [CalibrationSet(step: .test, reps: testReps, weight: test, restSeconds: testRestSeconds)]
        case .oneRepMax:
            let ramp = oneRepMaxRamp.map {
                CalibrationSet(step: .ramp, reps: $0.reps, weight: onStep(oneRepMax * $0.fraction, step: step),
                               restSeconds: testRestSeconds)
            }
            let attempts = attemptFractions.map {
                CalibrationSet(step: .attempt, reps: 1, weight: onStep(oneRepMax * $0, step: step),
                               restSeconds: attemptRestSeconds)
            }
            return ramp + attempts
        }
    }

    /// The five-rep weight, stopped with one or two reps left.
    static func testWeight(oneRepMax: Double, step: Double) -> Double {
        let raw = oneRepMax / (1 + (Double(testReps) + WorkoutLoadEngine.testSetRepsInReserve) / 30)
        return onStep(raw, step: step)
    }

    /// `value` on the equipment's steps, never below one step.
    static func onStep(_ value: Double, step: Double) -> Double {
        max(step, WorkoutLoadEngine.rounded(value, toStep: step))
    }
}
