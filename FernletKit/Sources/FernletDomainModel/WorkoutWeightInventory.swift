// WorkoutWeightInventory.swift
// FernletDomainModel
//
// "Weights I have" (2026-10-20, idea 10 of the comparison report). The load engine moved weights by
// fixed steps — 5 lb, or 2 kg on dumbbells — and assumed every step existed, so a 15 lb dumbbell press
// went to 20 lb (a 33 % jump) and a home gym could be told to lift a dumbbell it doesn't own. JEFIT
// drew exactly these complaints and shipped editable available weights in September 2026. Here each
// location can say which dumbbell pairs, kettlebells, bar and plates it has; the engine then prescribes
// only loads that exist (``LoadLadder``) and adds reps before a jump that is too big or missing
// (``WorkoutLoadEngine/loadCap(from:step:lowerBody:ladder:)``).
//
// Synced at the TOP LEVEL of the settings blob (`workoutLocationWeights`, location id → inventory), not
// inside ``WorkoutLocation``'s own encoding: every build since generic key parking keeps an unknown
// top-level key through a re-save, while an older build re-saving a location drops any nested key it
// does not know — the injury picker's reason for the same choice. Decoded tolerantly from raw JSON:
// an unexpected value is skipped, a key this build does not know is parked and written back, and an
// entry whose unit this build cannot read is kept verbatim on the location.

import Foundation

/// The weights a location has: dumbbell pairs, kettlebells, and a bar with plate pairs.
///
/// Every list is held sorted, deduplicated and bounded; the mutating API keeps it that way, so the
/// engine can read the values without checking them again. All values are in ``unit``. An empty
/// inventory — the default — means "not set": the engine then moves by the equipment's usual steps,
/// with only the light-load guard added.
public nonisolated struct WorkoutWeightInventory: Equatable, Sendable {
    /// Most dumbbell pairs kept: a full rack in 2.5 steps to 100 is 39.
    public static let maxDumbbells = 40
    /// Most kettlebells kept.
    public static let maxKettlebells = 24
    /// Most plate pairs kept (the barbell totals are subset sums of these).
    public static let maxPlatePairs = 24
    /// The heaviest single dumbbell, kettlebell, bar or plate accepted, in either unit. Anything
    /// heavier is not a piece of gym equipment and is skipped.
    public static let maxLoad = 1_000.0
    /// Most unknown keys parked from one synced entry (R3).
    public static let maxParkedKeys = 16
    /// Most raw values a decode walks in one list before giving up on the rest (R2).
    static let maxDecodedValues = 200

    /// The unit every value here is in — the user's unit when the inventory was first filled.
    public var unit: LoadUnit
    /// Dumbbell pairs owned, by the weight of one dumbbell, lightest first.
    public private(set) var dumbbells: [Double] = []
    /// Kettlebells owned, lightest first.
    public private(set) var kettlebells: [Double] = []
    /// The bar's own weight; nil when no barbell weights are set here.
    public private(set) var barWeight: Double?
    /// Plate pairs owned, one entry per pair (two pairs of 45s are `[45, 45]`), lightest first.
    public internal(set) var platePairs: [Double] = []
    /// Keys a newer build wrote into this entry that this one does not know, written back verbatim.
    public var parkedUnknownKeys: [String: JSONValue] = [:]

    public init(unit: LoadUnit = .lb) {
        self.unit = unit
    }

    /// Nothing is set: no dumbbells, kettlebells or bar.
    public var isEmpty: Bool { dumbbells.isEmpty && kettlebells.isEmpty && barWeight == nil }

    // MARK: Editing

    /// Replaces the dumbbell pairs (a preset, or Clear with `[]`).
    public mutating func setDumbbells(_ weights: [Double]) {
        dumbbells = Self.sanitized(weights, limit: Self.maxDumbbells)
    }

    /// Adds one dumbbell pair. Returns false — and changes nothing — for a weight that is not a
    /// plausible dumbbell or when the list is full; adding one already owned succeeds unchanged.
    @discardableResult
    public mutating func addDumbbell(_ weight: Double) -> Bool {
        guard let value = Self.cleaned(weight) else { return false }
        guard !Self.contains(dumbbells, value) else { return true }
        guard dumbbells.count < Self.maxDumbbells else { return false }
        dumbbells = Self.sanitized(dumbbells + [value], limit: Self.maxDumbbells)
        return true
    }

    /// Removes one dumbbell pair.
    public mutating func removeDumbbell(_ weight: Double) {
        dumbbells.removeAll { abs($0 - weight) < Self.sameLoad }
    }

    /// Replaces the kettlebells (Clear with `[]`).
    public mutating func setKettlebells(_ weights: [Double]) {
        kettlebells = Self.sanitized(weights, limit: Self.maxKettlebells)
    }

    /// Adds one kettlebell; same rules as ``addDumbbell(_:)``.
    @discardableResult
    public mutating func addKettlebell(_ weight: Double) -> Bool {
        guard let value = Self.cleaned(weight) else { return false }
        guard !Self.contains(kettlebells, value) else { return true }
        guard kettlebells.count < Self.maxKettlebells else { return false }
        kettlebells = Self.sanitized(kettlebells + [value], limit: Self.maxKettlebells)
        return true
    }

    /// Removes one kettlebell.
    public mutating func removeKettlebell(_ weight: Double) {
        kettlebells.removeAll { abs($0 - weight) < Self.sameLoad }
    }

    /// Whether a kettlebell of `weight` is owned.
    public func ownsKettlebell(_ weight: Double) -> Bool { Self.contains(kettlebells, weight) }

    /// Sets the bar's weight, which turns the barbell weights on. An implausible weight changes nothing.
    public mutating func setBar(_ weight: Double) {
        guard let value = Self.cleaned(weight) else { return }
        barWeight = value
    }

    /// Clears the bar and every plate pair.
    public mutating func clearBarbell() {
        barWeight = nil
        platePairs = []
    }

    /// How many pairs of `plate` are owned.
    public func pairs(of plate: Double) -> Int {
        platePairs.filter { abs($0 - plate) < Self.sameLoad }.count
    }

    /// Sets how many pairs of `plate` are owned. Plates need a bar, so the first plate on an
    /// inventory without one also sets the standard bar for its unit.
    public mutating func setPairs(_ count: Int, of plate: Double) {
        guard let value = Self.cleaned(plate) else { return }
        let others = platePairs.filter { abs($0 - value) >= Self.sameLoad }
        let room = max(0, Self.maxPlatePairs - others.count)
        let added = Array(repeating: value, count: min(max(0, count), room))
        platePairs = (others + added).sorted()
        if barWeight == nil, !added.isEmpty { barWeight = WorkoutWeightPresets.standardBar(unit) }
    }

    // MARK: What the location can load

    /// Every barbell load the bar and plates make, lightest first (the bar alone, then each total of
    /// a subset of the plate pairs, one plate of each pair per side). Empty when no bar is set.
    public var barbellTotals: [Double] {
        guard let barWeight else { return [] }
        var sideSums: Set<Int> = [0]
        for plate in platePairs.prefix(Self.maxPlatePairs) {
            let side = Int((plate * 100).rounded())
            guard side > 0 else { continue }
            for sum in sideSums.sorted() where sideSums.count < LoadLadder.maxLoads {
                sideSums.insert(sum + side)
            }
        }
        return sideSums.sorted().map { barWeight + 2 * Double($0) / 100 }
    }

    /// The loads this location can put on a lift of `equipment`, in `unit`; nil when the inventory
    /// says nothing about that equipment (machines, cables, bodyweight, or an empty list).
    public func ladder(for equipment: Equipment, in unit: LoadUnit) -> LoadLadder? {
        let values: [Double]
        switch equipment {
        case .dumbbell: values = dumbbells
        case .kettlebell: values = kettlebells
        case .barbell: values = barbellTotals
        case .machine, .cable, .bodyweight, .band, .bench, .none, .cardio: return nil
        }
        return LoadLadder(values.map { unit.converted($0, from: self.unit) })
    }

    // MARK: Sanitizing

    /// Values closer than this are one weight.
    static let sameLoad = 0.005

    /// `value` rounded to hundredths, or nil when it is not a plausible load.
    static func cleaned(_ value: Double) -> Double? {
        guard value.isFinite, value > 0, value <= maxLoad else { return nil }
        return (value * 100).rounded() / 100
    }

    static func contains(_ values: [Double], _ value: Double) -> Bool {
        values.contains { abs($0 - value) < sameLoad }
    }

    /// Plausible values, rounded, deduplicated, lightest first, at most `limit`.
    static func sanitized(_ values: [Double], limit: Int) -> [Double] {
        var kept: [Double] = []
        for raw in values.prefix(maxDecodedValues) {
            guard let value = cleaned(raw), !contains(kept, value) else { continue }
            kept.append(value)
        }
        return Array(kept.sorted().prefix(limit))
    }
}

// MARK: - Presets and standard sizes

/// The dumbbell presets the editor offers, and the standard kettlebell, bar and plate sizes, in the
/// user's unit. Values only: the editor draws the labels from its own catalog.
public nonisolated enum WorkoutWeightPresets {

    /// A ready-made dumbbell list.
    public enum Dumbbells: String, CaseIterable, Sendable {
        /// A fixed home set: five pairs, 5–25 lb (2–10 kg).
        case homeSet
        /// An adjustable pair in small steps: 5–52.5 lb by 2.5 (2–24 kg by 1).
        case adjustable
        /// A full rack: 5–100 lb by 5 (2.5–50 kg by 2.5).
        case fullRack

        /// The pairs this preset owns, in `unit`.
        public func weights(in unit: LoadUnit) -> [Double] {
            switch (self, unit) {
            case (.homeSet, .lb): WorkoutWeightPresets.series(from: 5, through: 25, by: 5)
            case (.homeSet, .kg): WorkoutWeightPresets.series(from: 2, through: 10, by: 2)
            case (.adjustable, .lb): WorkoutWeightPresets.series(from: 5, through: 52.5, by: 2.5)
            case (.adjustable, .kg): WorkoutWeightPresets.series(from: 2, through: 24, by: 1)
            case (.fullRack, .lb): WorkoutWeightPresets.series(from: 5, through: 100, by: 5)
            case (.fullRack, .kg): WorkoutWeightPresets.series(from: 2.5, through: 50, by: 2.5)
            }
        }
    }

    /// Kettlebell sizes the editor offers as chips (competition sizes in kg; common US sizes in lb).
    public static func kettlebells(_ unit: LoadUnit) -> [Double] {
        switch unit {
        case .lb: [10, 15, 20, 25, 30, 35, 40, 45, 50, 53, 60, 70]
        case .kg: [4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32]
        }
    }

    /// Bar weights the editor offers: an Olympic bar, a women's Olympic bar, a technique bar.
    public static func bars(_ unit: LoadUnit) -> [Double] {
        switch unit {
        case .lb: [45, 35, 15]
        case .kg: [20, 15, 10]
        }
    }

    /// The bar a first plate assumes.
    public static func standardBar(_ unit: LoadUnit) -> Double {
        unit == .lb ? 45 : 20
    }

    /// Plate sizes the editor offers, heaviest first.
    public static func plates(_ unit: LoadUnit) -> [Double] {
        switch unit {
        case .lb: [45, 35, 25, 10, 5, 2.5]
        case .kg: [25, 20, 15, 10, 5, 2.5, 1.25]
        }
    }

    /// Most pairs of one plate size the editor's stepper allows.
    public static let maxPairsPerPlate = 6

    /// `first`, `first + step`, … up to `last` (at most 64 values).
    static func series(from first: Double, through last: Double, by step: Double) -> [Double] {
        guard step > 0, last >= first else { return [] }
        let count = min(64, Int(((last - first) / step).rounded(.down)) + 1)
        return (0..<count).map { first + Double($0) * step }
    }
}

// MARK: - The loads a lift can actually use

/// The loads a location can put on one kind of lift, lightest first, in one unit — what the engine
/// snaps its suggestions and ranges onto when the location has weights set.
public nonisolated struct LoadLadder: Equatable, Sendable {
    /// Most distinct loads kept (barbell totals are capped here as they are generated).
    public static let maxLoads = 512

    /// Distinct, positive, ascending.
    public let loads: [Double]

    /// Nil when nothing plausible is left of `values`.
    public init?(_ values: [Double]) {
        var kept: [Double] = []
        for value in values.prefix(Self.maxLoads) where value.isFinite && value > 0 {
            guard !kept.contains(where: { abs($0 - value) < WorkoutLoadEngine.weightTolerance }) else { continue }
            kept.append(value)
        }
        guard !kept.isEmpty else { return nil }
        loads = kept.sorted()
    }

    public var lightest: Double { loads.first ?? 0 }
    public var heaviest: Double { loads.last ?? 0 }

    /// The load nearest `weight`; a tie goes to the lighter one.
    public func nearest(to weight: Double) -> Double {
        closest(to: weight, among: loads) ?? lightest
    }

    /// Loads strictly heavier than `weight`, lightest first.
    public func heavier(than weight: Double) -> [Double] {
        loads.filter { $0 > weight + WorkoutLoadEngine.weightTolerance }
    }

    /// Loads strictly lighter than `weight`, lightest first.
    public func lighter(than weight: Double) -> [Double] {
        loads.filter { $0 < weight - WorkoutLoadEngine.weightTolerance }
    }

    /// The candidate nearest `target`, a tie going to the lighter; nil with no candidates.
    public func closest(to target: Double, among candidates: [Double]) -> Double? {
        var best: Double?
        for candidate in candidates {
            guard let current = best else { best = candidate; continue }
            let gap = abs(candidate - target)
            let bestGap = abs(current - target)
            if gap < bestGap - 1e-9 || (abs(gap - bestGap) <= 1e-9 && candidate < current) { best = candidate }
        }
        return best
    }

    /// The step the runner's −/+ moves by on these loads: their common step (5 on a 5–25 set, 2.5 on
    /// an adjustable pair, 4 on 8/12/16 kg bells) when it is at least half the equipment's usual
    /// `step`, else the usual step — an irregular set (18, 26, 35 lb) has no useful common step.
    public func runnerStep(default step: Double) -> Double {
        let hundredths = loads.map { Int(($0 * 100).rounded()) }
        var divisor = hundredths.first ?? 0
        for value in hundredths.dropFirst() { divisor = Self.gcd(divisor, value) }
        let common = Double(divisor) / 100
        return common > 0 && common >= step / 2 ? common : step
    }

    /// Euclid's greatest common divisor, bounded (R2): numbers this size settle in far fewer rounds.
    static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        for _ in 0..<128 where y != 0 {
            (x, y) = (y, x % y)
        }
        return x
    }
}
