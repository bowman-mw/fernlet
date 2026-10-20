// BarbellPlates.swift
// FernletDomainModel
//
// The plate calculator (2026-10-20, idea 12 of the comparison report). Hevy's free plate calculator
// answers the question every barbell lift asks before its first set: which plates go on each side.
// Fernlet already prescribes the weight; this says how to load it, on a standard bar and the standard
// plates in the lift's own unit, and says plainly when a weight can't be made ("Closest: 135 lb").
// Warm-up sets (``WorkoutWarmUpSets``) round to the same loadable weights, so every warm-up a barbell
// lift prescribes is one the plates can make.
//
// Pure and deterministic: whole hundredths of a pound or kilogram throughout, so 2.5 and 1.25 plates
// never drift in floating point.

import Foundation

/// A bar and the plate sizes that go on it, in one unit.
///
/// ``standard(_:)`` is a commercial gym: a 45 lb (20 kg) bar and as many of each standard plate as a
/// load needs. It is the seam for a location's own weights too — a set built from the bar and the plate
/// sizes a location lists goes through the same calculator (the location's plate counts would need a
/// subset search, which this set does not model: it assumes enough of each size).
///
/// Sizes are held heaviest first, deduplicated and positive. The calculator expects every size to be a
/// whole multiple of the smallest — true of both standard sets and of any real plate set — so a load is
/// makeable exactly when its per-side weight is a multiple of the smallest plate.
public nonisolated struct BarbellPlateSet: Equatable, Sendable {
    /// Most plate sizes a set keeps (R3: a set built from user data is bounded where it enters).
    public static let maxSizes = 12

    /// The unit the bar and every plate are in.
    public let unit: LoadUnit
    /// The bar's own weight; never negative.
    public let bar: Double
    /// Plate sizes, heaviest first.
    public let plates: [Double]

    /// A set from a bar and plate sizes; a bar or a size that is not a plausible weight is dropped.
    public init(unit: LoadUnit, bar: Double, plates: [Double]) {
        self.unit = unit
        self.bar = bar.isFinite && bar > 0 && bar <= ExerciseResult.maxWeight ? bar : 0
        var sizes: [Double] = []
        for size in plates.prefix(Self.maxSizes * 2) where size.isFinite && size > 0 && size <= ExerciseResult.maxWeight {
            guard !sizes.contains(where: { abs($0 - size) < PlateCalculator.tolerance }) else { continue }
            sizes.append(size)
        }
        self.plates = Array(sizes.sorted(by: >).prefix(Self.maxSizes))
    }

    /// The standard bar and plates: 45 lb with 45, 35, 25, 10, 5 and 2.5 lb plates, or 20 kg with 25,
    /// 20, 15, 10, 5, 2.5 and 1.25 kg plates.
    public static func standard(_ unit: LoadUnit) -> BarbellPlateSet {
        switch unit {
        case .lb: BarbellPlateSet(unit: .lb, bar: 45, plates: [45, 35, 25, 10, 5, 2.5])
        case .kg: BarbellPlateSet(unit: .kg, bar: 20, plates: [25, 20, 15, 10, 5, 2.5, 1.25])
        }
    }

    /// The smallest plate — per-side loads move in steps of it — or nil for a bar with no plates.
    public var smallestPlate: Double? { plates.last }
}

/// The plates for one barbell load: what goes on each side, and whether it makes the weight asked for.
public nonisolated struct PlateLoadout: Equatable, Sendable {
    /// The unit of the bar, the plates and both weights.
    public let unit: LoadUnit
    /// The bar's own weight.
    public let bar: Double
    /// One side's plates, heaviest first; empty for just the bar.
    public let perSide: [Double]
    /// The weight asked for.
    public let requested: Double

    public init(unit: LoadUnit, bar: Double, perSide: [Double], requested: Double) {
        self.unit = unit
        self.bar = bar
        self.perSide = perSide
        self.requested = requested
    }

    /// The load these plates make: the bar and both sides.
    public var total: Double { bar + 2 * perSide.reduce(0, +) }

    /// The plates make exactly the weight asked for.
    public var isExact: Bool { abs(total - requested) < PlateCalculator.tolerance }

    /// No plates: the bar alone.
    public var isJustTheBar: Bool { perSide.isEmpty }
}

/// Which plates go on each side of a bar for a weight: greedy, heaviest plate first, which on a plate
/// set whose sizes are multiples of the smallest is exact whenever the weight is makeable at all.
public nonisolated enum PlateCalculator {
    /// Weights closer than this are the same weight.
    static let tolerance = 0.001
    /// Most plates one side may carry (R2/R3: a corrupt weight can never build an unbounded list).
    public static let maxPlatesPerSide = 60

    /// The plates for `weight` on `plates`: exact when the weight can be made, otherwise the closest
    /// load that can (a tie goes to the lighter), and the bar alone for anything at or under the bar.
    public static func loadout(for weight: Double, on plates: BarbellPlateSet) -> PlateLoadout {
        let requested = weight.isFinite ? max(0, min(weight, ExerciseResult.maxWeight)) : 0
        let sideHundredths = closestSideHundredths(for: requested, on: plates)
        return PlateLoadout(unit: plates.unit, bar: plates.bar,
                            perSide: greedySide(sideHundredths, on: plates), requested: requested)
    }

    /// The closest load `plates` can make to `weight` — the weight itself when it is makeable.
    public static func closestLoadable(_ weight: Double, on plates: BarbellPlateSet) -> Double {
        loadout(for: weight, on: plates).total
    }

    /// Whether `weight` can be made exactly on `plates`.
    public static func isLoadable(_ weight: Double, on plates: BarbellPlateSet) -> Bool {
        loadout(for: weight, on: plates).isExact
    }

    // MARK: Hundredths

    /// A weight in whole hundredths of its unit.
    static func hundredths(_ value: Double) -> Int {
        Int((value * 100).rounded())
    }

    /// One side's load, in hundredths, for the closest makeable total: the per-side weight rounded to
    /// the smallest plate, half-way rounding down to the lighter load, never below nothing.
    static func closestSideHundredths(for weight: Double, on plates: BarbellPlateSet) -> Int {
        guard let smallest = plates.smallestPlate else { return 0 }
        let doubledSide = hundredths(weight) - hundredths(plates.bar)
        let stepTotal = 2 * hundredths(smallest)
        guard doubledSide > 0, stepTotal > 0 else { return 0 }
        var steps = doubledSide / stepTotal
        if 2 * (doubledSide % stepTotal) > stepTotal { steps += 1 }
        return steps * hundredths(smallest)
    }

    /// One side's plates for `sideHundredths`, heaviest first, at most ``maxPlatesPerSide``.
    static func greedySide(_ sideHundredths: Int, on plates: BarbellPlateSet) -> [Double] {
        var remaining = max(0, sideHundredths)
        var side: [Double] = []
        for plate in plates.plates {
            let size = hundredths(plate)
            guard size > 0, remaining > 0 else { continue }
            let count = min(remaining / size, maxPlatesPerSide - side.count)
            guard count > 0 else { continue }
            side += Array(repeating: plate, count: count)
            remaining -= count * size
        }
        return side
    }
}
