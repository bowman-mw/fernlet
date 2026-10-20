// WorkoutLoadEngine.swift
// FernletDomainModel
//
// Load-aware progression, the owner's spec of 2026-10-19. Deterministic and stateless: everything is
// derived from the lift's logged sessions (``LiftExposure``) each time a plan is built, so there is no
// stored estimate to drift out of step with the history.
//
// - The estimate is Epley's one-rep max with the reps left in the tank added back:
//   weight × (1 + (reps + RIR) / 30), from sets of 12 reps or fewer, weighted 3:2:1 over the last
//   three sessions in eight weeks.
// - Confidence sets how wide the prescribed range is: ±10 % low, ±5 % medium, one step at high.
// - The next prescription follows the last result: completed → one more rep (or, at the top of the
//   range, more weight and back to the bottom); tough or a small miss → repeat; a real miss → lighter.
// - Weights land on what the location has (``WorkoutWeightInventory``) when it says, and a step that
//   would raise the load by more than ``WorkoutLoadEngine/lightLoadGuardRatio`` — or a step that
//   doesn't exist there — waits for reps first, then a set (WorkoutLoadEngine+Inventory.swift).
//
// Numbers the owner approved on 2026-10-19 live in the named constants below.

import Foundation

/// How a lift's prescription changes from its last session — what the session note explains.
public nonisolated enum LoadChange: Equatable, Sendable {
    /// Nothing logged yet: the lifter picks the weight.
    case firstTime
    /// Completed: one more rep at the same weight.
    case moreReps
    /// Completed at the top of the range on a lift that takes no load: one more set.
    case moreSets
    /// Completed on a fixed-rep goal: one step heavier.
    case addWeight
    /// Completed at the top of the range: heavier, reps back to the bottom.
    case backToBottom
    /// Tough, or a small miss: the same again.
    case same
    /// A real miss: a little lighter.
    case lighter
    /// A third miss in a row: lighter and one set fewer, for one session.
    case lighterFewerSets
    /// Back after a long gap: a little lighter to start again.
    case afterBreak
    /// A fresh baseline — after a calibration, a goal change, or repeated overrides.
    case recalibrated
    /// The lifter said it hurt: no progression.
    case holdForPain
    /// The lifter's equipment tops out: the same weight, more reps.
    case holdForEquipment
    /// The next load is too big a jump, or there is none here (``LiftPlan/cap``): one more rep at the
    /// same weight first, up to ``WorkoutLoadEngine/equipmentExtraReps`` past the range.
    case repsFirst
    /// Past the range by the extra reps: one more set at the same weight before the jump (or, with
    /// nothing heavier here, instead of it).
    case setFirst
}

/// A rep target or range read from a prescription's reps text ("5", "8-12").
public nonisolated struct RepScheme: Equatable, Sendable {
    public let low: Int
    public let high: Int

    public init(low: Int, high: Int) {
        self.low = max(1, low)
        self.high = max(self.low, high)
    }

    /// Parses "5" or "8-12"; nil for anything else ("40 s", "AMRAP").
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let fixed = Int(trimmed) {
            guard fixed > 0 else { return nil }
            self.init(low: fixed, high: fixed)
            return
        }
        let parts = trimmed.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]), low > 0, high >= low else {
            return nil
        }
        self.init(low: low, high: high)
    }

    public var isRange: Bool { high > low }

    public func contains(_ reps: Int) -> Bool { reps >= low && reps <= high }
}

/// The engine's estimate of a lift's one-rep max and how far to trust it.
public nonisolated struct LoadEstimate: Equatable, Sendable {
    public var oneRepMax: Double
    public var unit: LoadUnit
    public var confidence: EstimateConfidence
    /// The estimate was re-centered on the lifter's own picks (repeated overrides, or a "too heavy" /
    /// "too light" answer) rather than on the whole recent history.
    public var recentered: Bool = false
}

/// What a lift does next session: sets, reps, the weight range, and why it changed.
public nonisolated struct LiftPlan: Equatable, Sendable {
    public var sets: Int
    public var reps: Int
    public var prescription: WeightPrescription?
    public var change: LoadChange
    public var askReasonOnOverride: Bool
    /// The weight the last regular session used, for the note ("up from 135 lb").
    public var previousWeight: Double?
    public var unit: LoadUnit
    /// The range was re-centered on the lifter's own recent picks.
    public var recentered: Bool = false
    /// Why the weight waits for reps (``LoadChange/repsFirst``, ``LoadChange/setFirst``); nil otherwise.
    public var cap: LoadCap? = nil
    /// The gear the lift is loaded with, for the note's noun ("your next dumbbell").
    public var equipment: Equipment? = nil
}

/// The deterministic rules of load-aware progression: estimate, confidence, range, next step.
public nonisolated enum WorkoutLoadEngine {

    // MARK: Approved numbers (owner, 2026-10-19)

    /// Epley is meaningless past about a dozen reps; such sets never feed the estimate.
    public static let epleyMaxReps = 12
    /// Reps left in the tank a prescription aims for.
    public static let targetRepsInReserve = 2.0
    /// Reps in reserve a calibration test set is stopped at ("one or two left").
    public static let testSetRepsInReserve = 1.5
    /// Sessions older than this don't feed the estimate.
    public static let estimateWindowDays = 56
    /// High confidence needs three sessions inside this window…
    public static let highConfidenceWindowDays = 42
    /// …whose estimates agree within this ratio.
    public static let highConfidenceSpread = 1.05
    /// A calibration this recent lifts confidence to at least medium.
    public static let calibrationConfidenceDays = 35
    /// Range half-widths by confidence.
    public static let lowConfidenceHalfWidth = 0.10
    public static let mediumConfidenceHalfWidth = 0.05
    /// The weight step after a completed top-of-range session, as a fraction.
    public static let upperBodyIncrease = 0.025
    public static let lowerBodyIncrease = 0.05
    /// A miss of this many reps or fewer, summed over the sets, repeats the load.
    public static let minorMissReps = 2
    /// Lighter after a real miss, and after the third in a row.
    public static let missDecrease = 0.05
    public static let repeatedMissDecrease = 0.10
    /// Misses in a row that also drop a set.
    public static let missesForFewerSets = 3
    /// A gap longer than this restarts a little lighter.
    public static let breakDays = 28
    public static let afterBreakDecrease = 0.10
    /// Overrides counted over this many recent sessions…
    public static let overrideWindow = 5
    /// …and this many before the next one asks why.
    public static let overridesBeforeAsking = 2
    /// No second ask on a lift inside this window.
    public static let reasonQuietDays = 28
    /// Extra reps an equipment-capped lift may climb past its range.
    public static let equipmentExtraReps = 3
    /// Cap on the sessions read per lift (R3: history is user data).
    public static let maxExposuresPerLift = 64
    /// Weights closer than this are the same weight.
    public static let weightTolerance = 0.01

    // MARK: Units and steps

    /// The smallest sensible change for the gear a lift is loaded with, or nil when it takes no load.
    public static func step(for equipment: Equipment, unit: LoadUnit) -> Double? {
        switch equipment {
        case .barbell, .machine, .cable: unit == .lb ? 5 : 2.5
        case .dumbbell, .kettlebell: unit == .lb ? 5 : 2
        case .bodyweight, .band, .bench, .none, .cardio: nil
        }
    }

    /// Squats, hinges and lunges take the larger step.
    public static func isLowerBody(_ pattern: MovementPattern) -> Bool {
        pattern == .squat || pattern == .hinge || pattern == .lunge
    }

    /// `value` rounded to the nearest multiple of `step`.
    public static func rounded(_ value: Double, toStep step: Double) -> Double {
        guard step > 0, value.isFinite else { return value }
        return (value / step).rounded() * step
    }

    /// A weight as the log and the runner print it: "105", "62.5".
    public static func weightText(_ weight: Double) -> String {
        guard weight.isFinite, abs(weight) < 100_000 else { return "0" }
        let tenths = (weight * 10).rounded()
        if tenths.truncatingRemainder(dividingBy: 10) == 0 { return String(Int(tenths / 10)) }
        return String(format: "%.1f", tenths / 10)
    }

    /// Whole days from `date` to `today` (negative when `date` is later).
    static func days(from date: Date, to today: Date) -> Int {
        Int((today.timeIntervalSince(date) / 86_400).rounded(.down))
    }

    // MARK: Estimate

    /// Epley's one-rep max with reps in reserve added back, or nil outside 1…``epleyMaxReps`` reps.
    public static func epley(weight: Double, reps: Int, repsInReserve: Double) -> Double? {
        guard weight > 0, weight.isFinite, reps >= 1, reps <= epleyMaxReps else { return nil }
        return weight * (1 + (Double(reps) + max(0, repsInReserve)) / 30)
    }

    /// One session's estimated max in `unit`, or nil when it can't say (no weight, a ramp set, the
    /// lighter plateau session, or a set outside Epley's range). A missed set was a set to the limit.
    public static func estimatedMax(of exposure: LiftExposure, in unit: LoadUnit) -> Double? {
        guard let weight = exposure.weight, exposure.calibration != .ramp, !exposure.easierSession else {
            return nil
        }
        let reserve: Double
        if exposure.calibration == .attempt || !exposure.completed {
            reserve = 0
        } else if let effort = exposure.effort {
            reserve = effort.repsInReserve
        } else {
            reserve = exposure.calibration == .test ? testSetRepsInReserve : targetRepsInReserve
        }
        let inUnit = unit.converted(weight, from: exposure.unit ?? unit)
        return epley(weight: inUnit, reps: exposure.bestReps, repsInReserve: reserve)
    }

    /// The current estimate from a lift's sessions (oldest first), or nil with nothing to go on.
    public static func estimate(from exposures: [LiftExposure], unit: LoadUnit, today: Date) -> LoadEstimate? {
        let window = exposures.suffix(maxExposuresPerLift).filter {
            days(from: $0.date, to: today) <= estimateWindowDays && estimatedMax(of: $0, in: unit) != nil
        }
        guard !window.isEmpty else { return nil }
        let basis = estimateBasis(window)
        let values = basis.sessions.suffix(3).compactMap { estimatedMax(of: $0, in: unit) }
        guard !values.isEmpty else { return nil }
        var total = 0.0
        var weights = 0.0
        for (index, value) in values.enumerated() {
            total += value * Double(index + 1)
            weights += Double(index + 1)
        }
        let confidence = basis.recalibrated
            ? EstimateConfidence.low
            : confidenceLevel(of: basis.sessions, values: values, today: today)
        return LoadEstimate(oneRepMax: total / weights, unit: unit, confidence: confidence,
                            recentered: basis.recalibrated)
    }

    /// The sessions the estimate rests on. A "too heavy" / "too light" answer, or two overrides in a
    /// row the same way, recalibrates: only those sessions count, at low confidence.
    static func estimateBasis(_ window: [LiftExposure]) -> (sessions: [LiftExposure], recalibrated: Bool) {
        guard let last = window.last else { return (window, false) }
        if last.overrideReason == .tooHeavy || last.overrideReason == .tooLight {
            return ([last], true)
        }
        guard window.count >= 2 else { return (window, false) }
        let previous = window[window.count - 2]
        if let direction = last.overrideDirection, previous.overrideDirection == direction,
           last.completed, previous.completed {
            return (Array(window.suffix(2)), true)
        }
        return (window, false)
    }

    /// High: three sessions in six weeks agreeing within 5 % and no override in the last two.
    /// Medium: two sessions, or a recent calibration. Low otherwise.
    static func confidenceLevel(of sessions: [LiftExposure], values: [Double], today: Date) -> EstimateConfidence {
        guard !sessions.isEmpty, let low = values.min(), let high = values.max(), low > 0 else { return .low }
        let recent = sessions.filter { days(from: $0.date, to: today) <= highConfidenceWindowDays }
        let noRecentOverride = sessions.suffix(2).allSatisfy { $0.overrideDirection == nil }
        if recent.count >= 3, values.count >= 3, high / low <= highConfidenceSpread, noRecentOverride {
            return .high
        }
        if sessions.count >= 2 { return .medium }
        let calibrated = sessions.contains {
            ($0.calibration == .test || $0.calibration == .attempt)
                && days(from: $0.date, to: today) <= calibrationConfidenceDays
        }
        return calibrated ? .medium : .low
    }

    /// The weight that leaves about two reps in the tank at `reps`, rounded to the step.
    public static func workingWeight(oneRepMax: Double, reps: Int, step: Double) -> Double {
        let raw = oneRepMax / (1 + (Double(max(1, reps)) + targetRepsInReserve) / 30)
        return max(step, rounded(raw, toStep: step))
    }

    /// The range around a suggested weight: ±10 % at low confidence, ±5 % at medium, one step up at
    /// high — always on the equipment's steps and never below one step. With a `ladder` (the
    /// location's weights) every value is a load the location has instead
    /// (``rangeOnLoads(_:suggested:confidence:step:unit:)``).
    public static func prescription(
        suggested: Double, confidence: EstimateConfidence, step: Double, unit: LoadUnit, ladder: LoadLadder? = nil
    ) -> WeightPrescription? {
        guard step > 0, suggested > 0, suggested.isFinite else { return nil }
        if let ladder {
            return rangeOnLoads(ladder, suggested: suggested, confidence: confidence, step: step, unit: unit)
        }
        let center = max(step, rounded(suggested, toStep: step))
        guard confidence != .high else {
            return WeightPrescription(low: center, high: center + step, suggested: center,
                                      step: step, unit: unit, confidence: confidence)
        }
        let half = confidence == .medium ? mediumConfidenceHalfWidth : lowConfidenceHalfWidth
        let floorStep = ((center * (1 - half)) / step + 1e-9).rounded(.down) * step
        let ceilStep = ((center * (1 + half)) / step - 1e-9).rounded(.up) * step
        let low = max(step, min(center - step, floorStep))
        let high = max(center + step, ceilStep)
        return WeightPrescription(low: low, high: high, suggested: center, step: step, unit: unit, confidence: confidence)
    }
}

// MARK: - The next prescription

extension WorkoutLoadEngine {

    /// What one lift's last session says about the next: the inputs ``plan(_:)`` reads.
    public struct LiftInputs: Sendable {
        public var scheme: RepScheme
        public var baseSets: Int
        public var exposures: [LiftExposure]
        public var equipment: Equipment?
        public var isLowerBody: Bool
        public var defaultUnit: LoadUnit
        public var today: Date
        /// The location's weights; nil or empty moves by the equipment's usual steps.
        public var inventory: WorkoutWeightInventory?

        public init(
            scheme: RepScheme, baseSets: Int, exposures: [LiftExposure], equipment: Equipment?,
            isLowerBody: Bool, defaultUnit: LoadUnit, today: Date, inventory: WorkoutWeightInventory? = nil
        ) {
            self.scheme = scheme
            self.baseSets = baseSets
            self.exposures = Array(exposures.suffix(maxExposuresPerLift))
            self.equipment = equipment
            self.isLowerBody = isLowerBody
            self.defaultUnit = defaultUnit
            self.today = today
            self.inventory = inventory
        }
    }

    /// How the weight moves from the anchor session.
    enum WeightMove: Equatable {
        case hold
        case up
        case down(Double)
    }

    /// The decision ``outcome(of:history:scheme:loadable:cap:)`` reaches before any weight math.
    struct Outcome: Equatable {
        var reps: Int
        var setsDelta: Int
        var change: LoadChange
        var move: WeightMove
        /// Set when the weight waits for reps because the next load is too big or missing.
        var cap: LoadCap? = nil
    }

    /// The next session of one lift.
    ///
    /// With weights set at the location (``LiftInputs/inventory``), the last weight is first placed
    /// on what the location can load and every move lands on a load it has (``LoadLadder``). With or
    /// without them, a step up that the light-load guard calls too big — or one that doesn't exist —
    /// becomes reps first, then a set (``loadCap(from:step:lowerBody:ladder:)``).
    public static func plan(_ inputs: LiftInputs) -> LiftPlan {
        let history = inputs.exposures.filter { $0.calibration != .ramp }
        let unit = history.last(where: { $0.unit != nil })?.unit ?? inputs.defaultUnit
        let step = inputs.equipment.flatMap { Self.step(for: $0, unit: unit) }
        let ladder = step == nil ? nil : inputs.equipment.flatMap { inputs.inventory?.ladder(for: $0, in: unit) }
        let estimate = Self.estimate(from: history, unit: unit, today: inputs.today)
        let ask = askReasonOnOverride(history, today: inputs.today)
        guard let anchor = history.last(where: { !$0.easierSession && $0.calibration == nil }) else {
            return firstPlan(inputs, estimate: estimate, step: step, ladder: ladder, unit: unit, ask: ask)
        }
        let base = anchor.weight.map { placed(unit.converted($0, from: anchor.unit ?? unit), on: ladder) }
        let cap = step.flatMap { step in
            base.flatMap { loadCap(from: $0, step: step, lowerBody: inputs.isLowerBody, ladder: ladder) }
        }
        var outcome = anchorOutcome(anchor, history: history, inputs: inputs, loadable: step != nil, cap: cap)
        var weight = base
        if let step, let base {
            weight = movedOnto(base, by: outcome.move, step: step, lowerBody: inputs.isLowerBody, ladder: ladder)
        }
        let ceiling = cap == nil ? inputs.scheme.high : inputs.scheme.high + equipmentExtraReps
        if recalibrationReason(anchor: anchor, history: history, scheme: inputs.scheme, ceiling: ceiling),
           let estimate, let step {
            outcome.reps = inputs.scheme.contains(outcome.reps) ? outcome.reps : inputs.scheme.low
            weight = workingWeight(oneRepMax: estimate.oneRepMax, reps: outcome.reps, step: step)
            outcome.change = .recalibrated
            if outcome.cap != nil { outcome.setsDelta = min(0, outcome.setsDelta) }
            outcome.cap = nil
        }
        let confidence = estimate?.confidence ?? (weight == nil ? .none : .low)
        let prescription = step.flatMap { step in
            weight.flatMap { Self.prescription(suggested: $0, confidence: confidence, step: step, unit: unit, ladder: ladder) }
        }
        return LiftPlan(
            sets: max(1, inputs.baseSets + outcome.setsDelta), reps: outcome.reps, prescription: prescription,
            change: outcome.change, askReasonOnOverride: ask, previousWeight: anchor.weight, unit: unit,
            recentered: estimate?.recentered ?? false, cap: outcome.cap, equipment: inputs.equipment
        )
    }

    /// The anchor's decision: a little lighter after a long break, else what its result says.
    static func anchorOutcome(
        _ anchor: LiftExposure, history: [LiftExposure], inputs: LiftInputs, loadable: Bool, cap: LoadCap?
    ) -> Outcome {
        guard days(from: anchor.date, to: inputs.today) <= breakDays else {
            let reps = inputs.scheme.contains(anchor.targetReps) ? anchor.targetReps : inputs.scheme.low
            return Outcome(reps: reps, setsDelta: 0, change: .afterBreak, move: .down(afterBreakDecrease))
        }
        return outcome(of: anchor, history: history, scheme: inputs.scheme, loadable: loadable, cap: cap)
    }

    /// A lift with no regular session yet: the bottom of the range, and a suggestion only when a
    /// calibration already gave an estimate.
    static func firstPlan(
        _ inputs: LiftInputs, estimate: LoadEstimate?, step: Double?, ladder: LoadLadder?, unit: LoadUnit, ask: Bool
    ) -> LiftPlan {
        let reps = inputs.scheme.low
        var prescription: WeightPrescription?
        if let estimate, let step {
            let weight = workingWeight(oneRepMax: estimate.oneRepMax, reps: reps, step: step)
            prescription = self.prescription(
                suggested: weight, confidence: estimate.confidence, step: step, unit: unit, ladder: ladder
            )
        }
        return LiftPlan(
            sets: max(1, inputs.baseSets), reps: reps, prescription: prescription,
            change: prescription == nil ? .firstTime : .recalibrated, askReasonOnOverride: ask,
            previousWeight: nil, unit: unit, equipment: inputs.equipment
        )
    }

    /// Rebaseline from the estimate when the newest session was a calibration, or the goal's reps
    /// moved out from under the anchor (5s after a block of 8–12s). A lift working through its extra
    /// reps (`ceiling` above the range, while the next load waits) has not moved out from under it.
    static func recalibrationReason(
        anchor: LiftExposure, history: [LiftExposure], scheme: RepScheme, ceiling: Int? = nil
    ) -> Bool {
        guard let newest = history.last else { return false }
        if newest.calibration == .test || newest.calibration == .attempt { return true }
        let top = max(scheme.high, ceiling ?? scheme.high)
        return !(scheme.low...top).contains(anchor.targetReps)
    }

    /// The rep and load decision from the anchor session's result. With a `cap` (the next load is
    /// too big a jump or missing), targets up to ``equipmentExtraReps`` past the range still count,
    /// and a completed session at the top climbs reps, then a set, before the load moves
    /// (``cappedOutcome(target:scheme:cap:anchor:history:)``).
    static func outcome(
        of anchor: LiftExposure, history: [LiftExposure], scheme: RepScheme, loadable: Bool, cap: LoadCap? = nil
    ) -> Outcome {
        let ceiling = cap == nil ? scheme.high : scheme.high + equipmentExtraReps
        let target = (scheme.low...ceiling).contains(anchor.targetReps) ? anchor.targetReps : scheme.low
        if anchor.overrideReason == .pain {
            return Outcome(reps: target, setsDelta: 0, change: .holdForPain, move: .hold)
        }
        guard anchor.completed else {
            let misses = trailingMisses(history)
            if misses >= missesForFewerSets {
                return Outcome(reps: target, setsDelta: -1, change: .lighterFewerSets, move: .down(repeatedMissDecrease))
            }
            if misses >= 2 || anchor.shortfall > minorMissReps {
                return Outcome(reps: target, setsDelta: 0, change: .lighter, move: .down(missDecrease))
            }
            return Outcome(reps: target, setsDelta: 0, change: .same, move: .hold)
        }
        if anchor.effort == .tough { return Outcome(reps: target, setsDelta: 0, change: .same, move: .hold) }
        if anchor.overrideReason == .equipment || !loadable {
            return repsOnlyOutcome(target: target, scheme: scheme, equipmentCapped: anchor.overrideReason == .equipment)
        }
        if let cap, target >= scheme.high {
            return cappedOutcome(target: target, scheme: scheme, cap: cap, anchor: anchor, history: history)
        }
        if scheme.isRange && target < scheme.high {
            return Outcome(reps: target + 1, setsDelta: 0, change: .moreReps, move: .hold)
        }
        return Outcome(reps: scheme.low, setsDelta: 0, change: scheme.isRange ? .backToBottom : .addWeight, move: .up)
    }

    /// Progress on reps (then one extra set) when the load can't move: bodyweight and band work, or a
    /// lifter whose equipment tops out.
    static func repsOnlyOutcome(target: Int, scheme: RepScheme, equipmentCapped: Bool) -> Outcome {
        let ceiling = equipmentCapped ? scheme.high + equipmentExtraReps : scheme.high
        if target < ceiling {
            return Outcome(reps: target + 1, setsDelta: 0,
                           change: equipmentCapped ? .holdForEquipment : .moreReps, move: .hold)
        }
        return Outcome(reps: ceiling, setsDelta: 1,
                       change: equipmentCapped ? .holdForEquipment : .moreSets, move: .hold)
    }

    /// Regular sessions in a row, newest backwards, that missed their target.
    static func trailingMisses(_ history: [LiftExposure]) -> Int {
        var count = 0
        for exposure in history.reversed() where !exposure.easierSession && exposure.calibration == nil {
            guard !exposure.completed else { break }
            count += 1
        }
        return count
    }

    /// `weight` moved one decision's worth, on the equipment's steps.
    static func moved(_ weight: Double, by move: WeightMove, step: Double, lowerBody: Bool) -> Double {
        switch move {
        case .hold:
            return weight
        case .up:
            let fraction = lowerBody ? lowerBodyIncrease : upperBodyIncrease
            return max(weight + step, rounded(weight * (1 + fraction), toStep: step))
        case .down(let fraction):
            return max(step, min(weight - step, rounded(weight * (1 - fraction), toStep: step)))
        }
    }

    /// Two overrides in the lift's last five sessions, and no answer in the last four weeks: the next
    /// pick outside the range asks why.
    public static func askReasonOnOverride(_ history: [LiftExposure], today: Date) -> Bool {
        let overrides = history.suffix(overrideWindow).filter { $0.overrideDirection != nil }.count
        guard overrides >= overridesBeforeAsking else { return false }
        let answeredRecently = history.contains {
            $0.overrideReason != nil && days(from: $0.date, to: today) <= reasonQuietDays
        }
        return !answeredRecently
    }
}
