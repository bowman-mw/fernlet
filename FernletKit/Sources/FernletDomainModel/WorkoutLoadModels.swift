// WorkoutLoadModels.swift
// FernletDomainModel
//
// The value types behind load-aware progression (the owner's 2026-10-19 spec): the guided runner
// prescribes a weight range, the lifter picks a weight, finishing untouched logs it as done, an edit
// records what actually happened, and the next prescription follows the result. These types carry
// that record (``ExerciseResult``, persisted on ``Workout``), the engine's view of one past session of
// a lift (``LiftExposure``), and what the engine prescribes (``WeightPrescription``, ``LoadGuidance``).
// The rules themselves live in ``WorkoutLoadEngine``, ``WorkoutPlateau`` and ``WorkoutCalibration``.

import Foundation

// MARK: - Tokens

/// The unit a load is logged and prescribed in. FROZEN tokens: they persist on ``ExerciseResult``
/// rows and cross into the app-group run state as raw strings.
public nonisolated enum LoadUnit: String, Codable, CaseIterable, Sendable {
    case lb
    case kg

    /// Pounds in one kilogram, for comparing sessions of one lift logged in both units.
    public static let poundsPerKilogram = 2.20462

    /// `value`, given in `unit`, expressed in this unit.
    public func converted(_ value: Double, from unit: LoadUnit) -> Double {
        guard unit != self else { return value }
        return self == .lb ? value * Self.poundsPerKilogram : value / Self.poundsPerKilogram
    }
}

/// How a lift felt — the optional one-tap answer after its last set. No answer reads as `.good`.
/// FROZEN tokens (persisted on ``ExerciseResult``, carried by the run state).
public nonisolated enum ExerciseEffort: String, Codable, CaseIterable, Sendable {
    case easy
    case good
    case tough

    /// Reps the lifter likely had left in the tank — what the max estimate adds back.
    public var repsInReserve: Double {
        switch self {
        case .easy: 3
        case .good: 2
        case .tough: 0
        }
    }
}

/// Why a lifter chose a weight outside the prescribed range, asked once after repeated overrides.
/// FROZEN tokens.
public nonisolated enum OverrideReason: String, Codable, CaseIterable, Sendable {
    case tooHeavy
    case tooLight
    case equipment
    case pain
    case preference
    case other
}

/// How much the engine trusts its estimate of a lift — it sets the width of the prescribed range.
/// FROZEN tokens.
public nonisolated enum EstimateConfidence: String, Codable, CaseIterable, Comparable, Sendable {
    case none
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .none: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    public static func < (lhs: EstimateConfidence, rhs: EstimateConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// The part a set plays in a calibration session. FROZEN tokens.
///
/// A ramp set is light warm-up work and never feeds the estimate; a test set is the submaximal
/// "as many good reps as you can, stopping with one or two left" set; an attempt is a true
/// one-rep-max single, offered only to lifters who opted in.
public nonisolated enum CalibrationStep: String, Codable, CaseIterable, Sendable {
    case ramp
    case test
    case attempt
}

/// Which way a chosen weight left the prescribed range.
public nonisolated enum OverrideDirection: Sendable {
    case heavier
    case lighter
}

// MARK: - The persisted record

/// What happened to one lift in a logged session: what Fernlet prescribed (for a guided lift), the
/// weight the lifter picked, and what they actually did when it differed.
///
/// Written by the guided runner, by the Log sheet's set-by-set entry, and by a later correction in the
/// Edit sheet (``record(_:unit:)``). Persisted on ``Workout/exerciseResults`` (an additive optional
/// field: absent on every row written before it existed). Enum-valued fields are stored as raw-string
/// tokens and read through typed accessors, so a token only a newer build knows reads as nil here
/// instead of failing the decode of the whole day. `actualReps == nil` means "completed as
/// prescribed" — the implicit log; `setWeights == nil` means every set was lifted at
/// ``selectedWeight``.
///
/// Forward compatible both ways: a key a NEWER build adds is parked verbatim in
/// ``parkedUnknownKeys`` and written back on encode, so this build never drops it on a re-save; and
/// every fact this build adds (the per-set weights) is also in ``loggedLine``, so an OLDER build that
/// drops the field loses only the structure, never the record.
public nonisolated struct ExerciseResult: Codable, Equatable, Sendable {
    /// Upper bound on the per-set reps a decoded row may carry (R3: the field arrives from synced
    /// storage, so its size is capped where it enters).
    public static let maxSets = 20
    /// Unknown keys a decoded result parks at most (R3). Past it the extra keys are left behind
    /// rather than failing the decode of the whole day; no build adds anywhere near this many.
    public static let maxParkedKeys = 32
    /// The heaviest a logged set may be, in either unit. Above it a stored weight list is corrupt and
    /// reads as absent.
    public static let maxWeight = 5_000.0

    public var name: String
    public var prescribedSets: Int
    public var targetReps: Int
    public var rangeLow: Double?
    public var rangeHigh: Double?
    public var suggestedWeight: Double?
    /// The working weight: the one the lifter picked, or after a correction the heaviest set's.
    public var selectedWeight: Double?
    public var unitToken: String?
    public var equipmentToken: String?
    /// Reps per set when the lifter edited them; nil when the lift was completed as prescribed.
    public var actualReps: [Int]?
    public var effortToken: String?
    public var overrideReasonToken: String?
    public var confidenceToken: String?
    public var calibrationToken: String?
    /// True for the lighter session a plateau response prescribes — never the anchor for what comes next.
    public var easierSession: Bool?
    /// Compound lifts done before this one in the session — the fatigue context plateau checks read.
    public var compoundsBefore: Int
    /// Each set's weight when the sets were not all lifted at ``selectedWeight`` (a lighter last
    /// set, a corrected set), aligned with ``repsPerSet``; nil when every set used it. Additive
    /// optional, encoded only when set, so every other result stays byte-identical.
    public var setWeights: [Double]?
    /// Keys a newer build wrote that this one does not know, kept verbatim and re-emitted on encode
    /// (the `FernletSettings.parkedUnknownKeys` pattern). Never read for meaning.
    public var parkedUnknownKeys: [String: JSONValue] = [:]

    public init(
        name: String, prescribedSets: Int, targetReps: Int, rangeLow: Double? = nil, rangeHigh: Double? = nil,
        suggestedWeight: Double? = nil, selectedWeight: Double? = nil, unit: LoadUnit? = nil,
        equipment: Equipment? = nil, actualReps: [Int]? = nil, effort: ExerciseEffort? = nil,
        overrideReason: OverrideReason? = nil, confidence: EstimateConfidence? = nil,
        calibration: CalibrationStep? = nil, easierSession: Bool? = nil, compoundsBefore: Int = 0,
        setWeights: [Double]? = nil
    ) {
        self.name = name
        self.prescribedSets = prescribedSets
        self.targetReps = targetReps
        self.rangeLow = rangeLow
        self.rangeHigh = rangeHigh
        self.suggestedWeight = suggestedWeight
        self.selectedWeight = selectedWeight
        self.unitToken = unit?.rawValue
        self.equipmentToken = equipment?.rawValue
        self.actualReps = actualReps
        self.effortToken = effort?.rawValue
        self.overrideReasonToken = overrideReason?.rawValue
        self.confidenceToken = confidence?.rawValue
        self.calibrationToken = calibration?.rawValue
        self.easierSession = easierSession
        self.compoundsBefore = compoundsBefore
        self.setWeights = Self.validWeights(setWeights)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant even of a missing name: ``Workout`` drops nameless results rather than failing the day.
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prescribedSets = max(0, try c.decodeIfPresent(Int.self, forKey: .prescribedSets) ?? 0)
        targetReps = max(0, try c.decodeIfPresent(Int.self, forKey: .targetReps) ?? 0)
        rangeLow = try c.decodeIfPresent(Double.self, forKey: .rangeLow)
        rangeHigh = try c.decodeIfPresent(Double.self, forKey: .rangeHigh)
        suggestedWeight = try c.decodeIfPresent(Double.self, forKey: .suggestedWeight)
        selectedWeight = try c.decodeIfPresent(Double.self, forKey: .selectedWeight)
        unitToken = try c.decodeIfPresent(String.self, forKey: .unitToken)
        equipmentToken = try c.decodeIfPresent(String.self, forKey: .equipmentToken)
        actualReps = try c.decodeIfPresent([Int].self, forKey: .actualReps).map { Array($0.prefix(Self.maxSets)) }
        effortToken = try c.decodeIfPresent(String.self, forKey: .effortToken)
        overrideReasonToken = try c.decodeIfPresent(String.self, forKey: .overrideReasonToken)
        confidenceToken = try c.decodeIfPresent(String.self, forKey: .confidenceToken)
        calibrationToken = try c.decodeIfPresent(String.self, forKey: .calibrationToken)
        easierSession = try c.decodeIfPresent(Bool.self, forKey: .easierSession)
        compoundsBefore = max(0, try c.decodeIfPresent(Int.self, forKey: .compoundsBefore) ?? 0)
        setWeights = Self.validWeights(try c.decodeIfPresent([Double].self, forKey: .setWeights))
        parkedUnknownKeys = try Self.parkedKeys(from: decoder)
    }

    /// Writes the same shape the compiler synthesized before (optionals only when set, in declaration
    /// order), then the per-set weights when present, then every parked key back at the top level.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(prescribedSets, forKey: .prescribedSets)
        try c.encode(targetReps, forKey: .targetReps)
        try c.encodeIfPresent(rangeLow, forKey: .rangeLow)
        try c.encodeIfPresent(rangeHigh, forKey: .rangeHigh)
        try c.encodeIfPresent(suggestedWeight, forKey: .suggestedWeight)
        try c.encodeIfPresent(selectedWeight, forKey: .selectedWeight)
        try c.encodeIfPresent(unitToken, forKey: .unitToken)
        try c.encodeIfPresent(equipmentToken, forKey: .equipmentToken)
        try c.encodeIfPresent(actualReps, forKey: .actualReps)
        try c.encodeIfPresent(effortToken, forKey: .effortToken)
        try c.encodeIfPresent(overrideReasonToken, forKey: .overrideReasonToken)
        try c.encodeIfPresent(confidenceToken, forKey: .confidenceToken)
        try c.encodeIfPresent(calibrationToken, forKey: .calibrationToken)
        try c.encodeIfPresent(easierSession, forKey: .easierSession)
        try c.encode(compoundsBefore, forKey: .compoundsBefore)
        try c.encodeIfPresent(setWeights, forKey: .setWeights)
        // No second container when nothing is parked, so every result written so far keeps its shape.
        guard !parkedUnknownKeys.isEmpty else { return }
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        var parked = encoder.container(keyedBy: ResultParkedKey.self)
        for (key, value) in parkedUnknownKeys.sorted(by: { $0.key < $1.key }) where !known.contains(key) {
            try parked.encode(value, forKey: ResultParkedKey(stringValue: key))
        }
    }

    /// The persisted keys. Renaming a case is a data-format break; `parkedUnknownKeys` has no key of
    /// its own (its entries are written back at the top level), which is also what keeps a known key
    /// from ever being parked.
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, prescribedSets, targetReps, rangeLow, rangeHigh, suggestedWeight, selectedWeight
        case unitToken, equipmentToken, actualReps, effortToken, overrideReasonToken, confidenceToken
        case calibrationToken, easierSession, compoundsBefore, setWeights
    }

    /// Every top-level key this build does not know, with its raw value — at most ``maxParkedKeys``,
    /// taken in key order so the same input always parks the same keys.
    private static func parkedKeys(from decoder: Decoder) throws -> [String: JSONValue] {
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: ResultParkedKey.self)
        let unknown = container.allKeys.filter { !known.contains($0.stringValue) }
            .sorted { $0.stringValue < $1.stringValue }
            .prefix(maxParkedKeys)
        var parked: [String: JSONValue] = [:]
        for key in unknown {
            parked[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return parked
    }

    /// A stored weight list, capped at ``maxSets``, or nil when it is empty or any value is not a
    /// plausible weight (negative, not finite, above ``maxWeight``).
    static func validWeights(_ weights: [Double]?) -> [Double]? {
        guard let weights, !weights.isEmpty else { return nil }
        let capped = Array(weights.prefix(maxSets))
        guard capped.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= maxWeight }) else { return nil }
        return capped
    }

    public var unit: LoadUnit? { unitToken.flatMap(LoadUnit.init(rawValue:)) }
    public var equipment: Equipment? { equipmentToken.flatMap(Equipment.init(rawValue:)) }
    public var effort: ExerciseEffort? { effortToken.flatMap(ExerciseEffort.init(rawValue:)) }
    public var overrideReason: OverrideReason? { overrideReasonToken.flatMap(OverrideReason.init(rawValue:)) }
    public var confidence: EstimateConfidence? { confidenceToken.flatMap(EstimateConfidence.init(rawValue:)) }
    public var calibration: CalibrationStep? { calibrationToken.flatMap(CalibrationStep.init(rawValue:)) }

    /// True when the lifter edited what they did; false for the implicit "completed as prescribed".
    public var wasEdited: Bool { actualReps != nil || setWeights != nil }

    /// The reps of every set: the edited values, or the target repeated for each prescribed set.
    public var repsPerSet: [Int] {
        actualReps ?? Array(repeating: targetReps, count: min(prescribedSets, Self.maxSets))
    }

    /// The per-set weights when they line up with ``repsPerSet`` set for set; nil when every set was
    /// at the working weight (or the stored list no longer matches the sets, which reads the same).
    public var alignedSetWeights: [Double]? {
        guard let setWeights, setWeights.count == repsPerSet.count else { return nil }
        return setWeights
    }

    /// The session's working weight: the heaviest set's when the sets differed, else
    /// ``selectedWeight``. What the load engine anchors the next prescription on.
    public var workingWeight: Double? {
        alignedSetWeights?.max() ?? selectedWeight
    }

    /// The line this result is logged as — `ExerciseLineParser` reads it back: "Bench press - 3 x 8 @
    /// 105 lb", with "(did 8, 8, 6)" when the reps differed, "(did 8 @ 100, 8 @ 100, 6 @ 95)" when the
    /// weights did too, and a calibration tag when it was one. The parser drops parentheticals before
    /// it reads the load, so the line's load stays the working weight.
    public var loggedLine: String {
        var line = "\(name) - \(prescribedSets) x \(targetReps)"
        if let workingWeight, let unit {
            line += " @ \(WorkoutLoadEngine.weightText(workingWeight)) \(unit.rawValue)"
        }
        if let weights = alignedSetWeights, unit != nil {
            let sets = zip(repsPerSet, weights).map { "\($0.0) @ \(WorkoutLoadEngine.weightText($0.1))" }
            line += " (did \(sets.joined(separator: ", ")))"
        } else if let actualReps, actualReps != Array(repeating: targetReps, count: prescribedSets) {
            line += " (did \(actualReps.map(String.init).joined(separator: ", ")))"
        }
        if let calibration { line += " (\(Self.calibrationTag(calibration)))" }
        return line
    }

    /// The plain-text tag a calibration line carries in the log.
    static func calibrationTag(_ step: CalibrationStep) -> String {
        switch step {
        case .ramp: "ramp-up"
        case .test: "test set"
        case .attempt: "max attempt"
        }
    }
}

/// A `CodingKey` that admits any string — how ``ExerciseResult`` finds the keys a newer build added
/// and writes them back by name. Non-failable `init(stringValue:)` satisfies the failable requirement,
/// so the encode site needs no unwrap.
private nonisolated struct ResultParkedKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

// MARK: - The engine's inputs and outputs

/// One past session of one lift, as the engine reads it: from a structured ``ExerciseResult`` (a
/// guided run, or the Log sheet's set-by-set entry) or from a hand-logged line ("Squat 5x5 @225lb"),
/// oldest-first per lift.
///
/// When the sets were not all lifted at one weight (``setWeights``), `weight` is the heaviest set's
/// and the session is judged at that weight: only the sets lifted at it count toward the best reps
/// and the shortfall, and a set done lighter keeps the session from counting as completed — so a
/// dropped last set repeats the load rather than progressing it.
public nonisolated struct LiftExposure: Equatable, Sendable {
    public var date: Date
    public var weight: Double?
    public var unit: LoadUnit?
    public var targetReps: Int
    public var repsPerSet: [Int]
    public var effort: ExerciseEffort?
    public var rangeLow: Double?
    public var rangeHigh: Double?
    public var overrideReason: OverrideReason?
    public var calibration: CalibrationStep?
    public var easierSession: Bool
    public var compoundsBefore: Int
    /// True for a structured result (guided, or entered set by set); false for a hand-logged line,
    /// whose target is simply what was written down (so it always reads as completed).
    public var structured: Bool
    /// Each set's weight when the sets differed, aligned with ``repsPerSet``; nil when every set was
    /// lifted at ``weight``. A list that does not line up with the sets is dropped at init.
    public var setWeights: [Double]?

    public init(
        date: Date, weight: Double?, unit: LoadUnit?, targetReps: Int, repsPerSet: [Int],
        effort: ExerciseEffort? = nil, rangeLow: Double? = nil, rangeHigh: Double? = nil,
        overrideReason: OverrideReason? = nil, calibration: CalibrationStep? = nil,
        easierSession: Bool = false, compoundsBefore: Int = 0, structured: Bool = false,
        setWeights: [Double]? = nil
    ) {
        self.date = date
        self.weight = weight
        self.unit = unit
        self.targetReps = targetReps
        self.repsPerSet = Array(repsPerSet.prefix(ExerciseResult.maxSets))
        self.effort = effort
        self.rangeLow = rangeLow
        self.rangeHigh = rangeHigh
        self.overrideReason = overrideReason
        self.calibration = calibration
        self.easierSession = easierSession
        self.compoundsBefore = compoundsBefore
        self.structured = structured
        let aligned = setWeights.map { Array($0.prefix(ExerciseResult.maxSets)) }
        self.setWeights = aligned?.count == self.repsPerSet.count ? aligned : nil
    }

    /// A structured result, dated by the day it was logged. Its working weight (the heaviest set's
    /// when the sets differed) is the session's weight.
    public init(date: Date, result: ExerciseResult) {
        self.init(
            date: date, weight: result.workingWeight, unit: result.unit, targetReps: result.targetReps,
            repsPerSet: result.repsPerSet, effort: result.effort, rangeLow: result.rangeLow,
            rangeHigh: result.rangeHigh, overrideReason: result.overrideReason, calibration: result.calibration,
            easierSession: result.easierSession == true, compoundsBefore: result.compoundsBefore,
            structured: true, setWeights: result.alignedSetWeights
        )
    }

    /// The reps of the sets lifted at the session's weight: every set, unless some were lighter.
    public var workingSetReps: [Int] {
        guard let setWeights, let weight else { return repsPerSet }
        let lowest = weight - WorkoutLoadEngine.weightTolerance
        return zip(repsPerSet, setWeights).filter { $0.1 >= lowest }.map { $0.0 }
    }

    /// Sets done lighter than the session's weight — a dropped set, which is never a completion.
    public var lighterSets: Int { repsPerSet.count - workingSetReps.count }

    /// The most reps any set at the session's weight reached.
    public var bestReps: Int { workingSetReps.max() ?? 0 }

    /// Reps short of the target, summed over the sets at the session's weight.
    public var shortfall: Int {
        workingSetReps.reduce(0) { $0 + max(0, targetReps - $1) }
    }

    /// Every set reached its target, all at the session's weight.
    public var completed: Bool { !workingSetReps.isEmpty && shortfall == 0 && lighterSets == 0 }

    /// Which way the chosen weight left the prescribed range, or nil when it stayed inside (or the
    /// session had no range — a hand log never counts as an override).
    public var overrideDirection: OverrideDirection? {
        guard let weight, let rangeLow, let rangeHigh else { return nil }
        if weight < rangeLow - WorkoutLoadEngine.weightTolerance { return .lighter }
        if weight > rangeHigh + WorkoutLoadEngine.weightTolerance { return .heavier }
        return nil
    }
}

/// A prescribed weight range and the weight Fernlet suggests inside it.
public nonisolated struct WeightPrescription: Equatable, Sendable {
    public var low: Double
    public var high: Double
    public var suggested: Double
    /// The equipment's smallest sensible change (5 lb on a bar, 2 kg on dumbbells).
    public var step: Double
    public var unit: LoadUnit
    public var confidence: EstimateConfidence

    public init(low: Double, high: Double, suggested: Double, step: Double, unit: LoadUnit, confidence: EstimateConfidence) {
        self.low = low
        self.high = high
        self.suggested = suggested
        self.step = step
        self.unit = unit
        self.confidence = confidence
    }

    /// Whether `weight` sits inside the range.
    public func contains(_ weight: Double) -> Bool {
        weight >= low - WorkoutLoadEngine.weightTolerance && weight <= high + WorkoutLoadEngine.weightTolerance
    }

    /// "95–110 lb", or "100 lb" when the range is a single weight.
    public var rangeText: String {
        let unitText = unit.rawValue
        guard high - low > WorkoutLoadEngine.weightTolerance else {
            return "\(WorkoutLoadEngine.weightText(suggested)) \(unitText)"
        }
        return "\(WorkoutLoadEngine.weightText(low))–\(WorkoutLoadEngine.weightText(high)) \(unitText)"
    }

    /// "100 lb".
    public var suggestedText: String { "\(WorkoutLoadEngine.weightText(suggested)) \(unit.rawValue)" }
}

/// What the planner attaches to a rep-counted lift so the guided runner can prescribe its weight and
/// record what happened. Present on every rep-counted lifting pick; `prescription` is nil when the lift
/// takes no load or Fernlet has nothing to go on yet (the runner then asks the lifter to pick).
public nonisolated struct LoadGuidance: Equatable, Sendable {
    public var targetReps: Int
    public var prescription: WeightPrescription?
    /// The gear the lift is loaded with; nil for bodyweight and band work (progressed on reps).
    public var equipment: Equipment?
    public var unit: LoadUnit
    /// True when this lift has been overridden repeatedly: one more pick outside the range asks why.
    public var askReasonOnOverride: Bool
    public var calibration: CalibrationStep?
    public var easierSession: Bool
    public var compoundsBefore: Int
    /// True on a warm-up set the planner put before a heavy main lift (``WorkoutWarmUpSets``) — a
    /// `.ramp` step like a calibration's, told apart so a time budget can cut the ramp to one set and
    /// the plan editor can hide it. Plan-only: the run and the log know it as a ramp set.
    public var warmUp: Bool

    public init(
        targetReps: Int, prescription: WeightPrescription? = nil, equipment: Equipment? = nil,
        unit: LoadUnit = .lb, askReasonOnOverride: Bool = false, calibration: CalibrationStep? = nil,
        easierSession: Bool = false, compoundsBefore: Int = 0, warmUp: Bool = false
    ) {
        self.targetReps = targetReps
        self.prescription = prescription
        self.equipment = equipment
        self.unit = unit
        self.askReasonOnOverride = askReasonOnOverride
        self.calibration = calibration
        self.easierSession = easierSession
        self.compoundsBefore = compoundsBefore
        self.warmUp = warmUp
    }

    /// The lift takes a load (the runner shows a weight picker even with no suggestion yet).
    public var isLoadable: Bool { equipment != nil }
}
