import Foundation

/// A person's five heart-rate training zones, from their age and — when Apple Health has one — their
/// resting heart rate, and the zone each guided cardio pace aims for (comparison report idea 9, roadmap
/// step 4b, 2026-10-20).
///
/// **Maximum heart rate: the person's own, else Tanaka.** A maximum they know (Workout setup's "My max
/// heart rate": from a lab test, or a hard effort they measured) wins when it lies in
/// ``ownMaximumRange``; anything outside is ignored. Otherwise `208 − 0.7 × age` (Tanaka, Monahan &
/// Seals, *J Am Coll Cardiol* 2001: a meta-analysis of 351 studies and 18,712 people, checked in a lab
/// study of 514). It tracks measured maxima better than the older `220 − age`, which under-reads after
/// about 40. Age is clamped to ``ageRange`` first; a formula is a population estimate — one person's
/// true maximum can sit 10–20 beats either side of it — which is why the person may give their own,
/// every target is a range to aim for, and the talk test is always the fallback.
///
/// **Zones: heart-rate reserve (Karvonen) when there is a resting heart rate,** `rest + p × (max −
/// rest)` (Karvonen, Kentala & Mustala 1957): the same percentage asks a heart with a lower resting
/// rate for a little more, which is what a fitter person needs. **Percent of maximum otherwise,** `p ×
/// max`. Both read the same five bands (``zoneFractions``: 50–60, 60–70, 70–80, 80–90 and 90–100 %).
/// A resting rate outside ``restingHeartRateRange``, or one leaving less than ``minimumReserve`` below
/// the maximum, is not trusted and the zones fall back to percent of maximum.
///
/// **Targets** are constants: an easy or steady part aims for zone 2 (``easyZone``, ``steadyZone``),
/// an interval's hard part for zone 4 (``hardZone``). Boundaries are whole beats per minute, rounded;
/// neighbouring zones share their boundary.
///
/// Gentle by design: a zone is somewhere to aim, never a limit — the runner says "a little high", never
/// a warning, and this is not medical advice (a heart-rate-lowering medicine reads low on any formula;
/// the talk test still holds). Pure, deterministic and `Sendable`; the HealthKit reads live in the app.
public nonisolated struct HeartRateZones: Equatable, Sendable {

    /// How the zones were computed.
    public enum Method: String, Equatable, Sendable {
        /// Karvonen: a share of the heart-rate reserve above the resting rate.
        case heartRateReserve
        /// A share of the maximum heart rate (no trusted resting rate).
        case percentOfMaximum
    }

    /// The six band edges of the five zones, as shares of the reserve (Karvonen) or of the maximum.
    public static let zoneFractions: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    /// How many zones there are.
    public static let zoneCount = 5
    /// The ages the Tanaka formula is read over; an age outside is clamped to it.
    public static let ageRange: ClosedRange<Int> = 13...100
    /// The resting heart rates trusted for Karvonen, in beats per minute.
    public static let restingHeartRateRange: ClosedRange<Double> = 30...110
    /// The least heart-rate reserve (maximum minus resting) Karvonen is used with, in beats per minute.
    public static let minimumReserve: Double = 20
    /// The maximum heart rates taken as the person's own, in beats per minute. Wide enough for any
    /// measured adult maximum, narrow enough that a typo ("1800", "18") is ignored rather than trusted.
    public static let ownMaximumRange: ClosedRange<Int> = 120...220
    /// The live readings taken as real heart rates, in beats per minute; anything else is sensor noise.
    public static let plausibleBPM: ClosedRange<Int> = 25...250

    /// The zone an easy part (an interval's recovery, an easy walk) aims for.
    public static let easyZone = 2
    /// The zone a steady-state part aims for.
    public static let steadyZone = 2
    /// The zone an interval's hard part aims for.
    public static let hardZone = 4

    /// The maximum heart rate, in beats per minute: the person's own when they gave one, else Tanaka's.
    public let maximumHeartRate: Double
    /// Whether ``maximumHeartRate`` is the person's own number rather than Tanaka's estimate.
    public let isOwnMaximum: Bool
    /// The resting heart rate the zones were built on, or nil when they are percent of maximum.
    public let restingHeartRate: Double?

    /// How the zones were computed: Karvonen when a trusted resting rate was given.
    public var method: Method { restingHeartRate == nil ? .percentOfMaximum : .heartRateReserve }

    /// Zones for a person of `age`, on their own maximum and their resting heart rate when each is
    /// given and trusted.
    ///
    /// - Parameters:
    ///   - age: Years; clamped to ``ageRange``. Unused when `ownMaximum` is trusted.
    ///   - restingHeartRate: Apple Health's latest resting heart rate in beats per minute, or nil.
    ///   - ownMaximum: The person's own maximum heart rate ("My max heart rate"), or nil. Used in place
    ///     of Tanaka's estimate when it lies in ``ownMaximumRange``; ignored otherwise.
    public init(age: Int, restingHeartRate: Double? = nil, ownMaximum: Int? = nil) {
        let own = ownMaximum.flatMap { Self.ownMaximumRange.contains($0) ? Double($0) : nil }
        let maximum = own ?? Self.tanakaMaximum(age: age)
        maximumHeartRate = maximum
        isOwnMaximum = own != nil
        self.restingHeartRate = Self.trustedResting(restingHeartRate, maximum: maximum)
    }

    /// Tanaka's maximum heart rate for `age` (clamped to ``ageRange``): `208 − 0.7 × age`.
    public static func tanakaMaximum(age: Int) -> Double {
        let clamped = min(max(age, ageRange.lowerBound), ageRange.upperBound)
        return 208 - 0.7 * Double(clamped)
    }

    /// The whole-bpm range of zone `number` (1–5), or nil for a number outside 1–5.
    public func range(zone number: Int) -> ClosedRange<Int>? {
        guard (1...Self.zoneCount).contains(number),
              Self.zoneFractions.indices.contains(number) else { return nil }
        let low = beats(at: Self.zoneFractions[number - 1])
        let high = beats(at: Self.zoneFractions[number])
        return min(low, high)...max(low, high)
    }

    /// The zone `pace` aims for: zone 2 for easy and steady, zone 4 for hard.
    public static func targetZone(for pace: CardioPace) -> Int {
        switch pace {
        case .easy: easyZone
        case .steady: steadyZone
        case .hard: hardZone
        }
    }

    /// The whole-bpm range `pace` aims for.
    public func target(for pace: CardioPace) -> ClosedRange<Int>? {
        range(zone: Self.targetZone(for: pace))
    }

    /// The heart rate at `fraction` of the reserve (Karvonen) or of the maximum, rounded to whole beats.
    private func beats(at fraction: Double) -> Int {
        guard let restingHeartRate else { return Int((fraction * maximumHeartRate).rounded()) }
        let reserve = maximumHeartRate - restingHeartRate
        return Int((restingHeartRate + fraction * reserve).rounded())
    }

    /// `resting` when it is a believable resting rate that leaves room below `maximum`, else nil.
    private static func trustedResting(_ resting: Double?, maximum: Double) -> Double? {
        guard let resting, resting.isFinite, restingHeartRateRange.contains(resting),
              maximum - resting >= minimumReserve else { return nil }
        return resting
    }
}
