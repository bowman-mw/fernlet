// WorkoutBodyWeightTrendTests.swift
// FernletTests
//
// The body-weight trend the plateau story may mention (G13, 2026-10-20): `WorkoutBodyWeightTrend`.
// The seeded simulation below draws the weigh-ins `Tools/plateau-sim/body_weight_sim.py` draws —
// the same SplitMix64 stream (`WorkoutPlateauSimulationTests.SplitMix64`), seeds and order: ln(weight)
// = ln(80 kg) + r·t with r a weekly change of 0, −0.25 %, −0.5 %, −1 % or +0.25 %; day-to-day water
// noise of 0.6, 0.8 or 1.0 %, AR(1) with ρ = 0.5 in half the histories; weigh-ins 7, 3 or 2 days a
// week with 10 % skipped — and scores the shipping rule on them, read on every weigh-in from day 14.
//
// | History (count)               | Called falling | Median day |
// |-------------------------------|----------------|------------|
// | steady, 8 weeks (400)         | 13 (3.25 %)    | -          |
// | gaining 0.25 %/wk, 8 wk (200) | 1 (0.5 %)      | -          |
// | slow -0.25 %/wk, 6 wk (200)   | 45 (22.5 %)    | 23         |
// | deficit -0.5 %/wk, 6 wk (200) | 136 (68 %)     | 25         |
// | fast -1 %/wk, 6 wk (200)      | 192 (96 %)     | 21         |
//
// The asserts allow a little slack around the script's counts (a last-bit difference between two
// platforms' log or exp can flip a borderline reading); the 5 % false-call target is a hard limit.

import Foundation
import Testing
import FernletDomainModel

/// G13's body-weight trend: the rule's edges, and its seeded Monte Carlo.
struct WorkoutBodyWeightTrendTests {

    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    static func day(_ offset: Int) -> Date { base.addingTimeInterval(Double(offset) * 86_400) }

    /// A weigh-in on each of `days` days ending the day before `today`, from 80 kg, changing `weekly`
    /// (a fraction) a week, with `bump` added to the weigh-in `bumpBack` days before today.
    static func series(today: Int, days: Int = 28, weekly: Double, bump: Double = 0, bumpBack: Int = 0) -> [BodyWeightSample] {
        (1...days).reversed().map { back in
            let kilograms = 80 * pow(1 + weekly, Double(days - back) / 7) + (back == bumpBack ? bump : 0)
            return BodyWeightSample(date: day(today - back), kilograms: kilograms)
        }
    }

    // MARK: - The rule

    @Test func aSteadyFallOfOnePercentAWeekIsFalling() throws {
        let weights = Self.series(today: 60, weekly: -0.01)
        #expect(WorkoutBodyWeightTrend.isFalling(weights, today: Self.day(60)))
        let reading = try #require(WorkoutBodyWeightTrend.weeklyChange(weights, asOf: Self.day(59)))
        #expect(abs(reading.change - log(0.99)) < 0.0001)
    }

    @Test func aSlowDriftASingleLowMorningOrTooFewWeighInsSayNothing() {
        // A quarter of a percent a week is under the half-percent the rule asks for.
        #expect(!WorkoutBodyWeightTrend.isFalling(Self.series(today: 60, weekly: -0.0025), today: Self.day(60)))
        // One light morning on a steady weight is water, not a fall.
        let water = Self.series(today: 60, weekly: 0, bump: -2, bumpBack: 1)
        #expect(!WorkoutBodyWeightTrend.isFalling(water, today: Self.day(60)))
        // Five weigh-ins, or ten days of them, aren't enough to read.
        let five = Array(Self.series(today: 60, weekly: -0.01).suffix(5))
        #expect(!WorkoutBodyWeightTrend.isFalling(five, today: Self.day(60)))
        let tenDays = Self.series(today: 60, days: 10, weekly: -0.02)
        #expect(!WorkoutBodyWeightTrend.isFalling(tenDays, today: Self.day(60)))
        #expect(!WorkoutBodyWeightTrend.isFalling([], today: Self.day(60)))
        // The newest weigh-in more than a week old: the trend is stale.
        #expect(!WorkoutBodyWeightTrend.isFalling(Self.series(today: 50, weekly: -0.01), today: Self.day(60)))
    }

    @Test func aGainingWeightIsNeverFalling() {
        #expect(!WorkoutBodyWeightTrend.isFalling(Self.series(today: 60, weekly: 0.01), today: Self.day(60)))
    }

    // MARK: - The seeded simulation

    @Test func aSteadyWeightIsRarelyCalledFallingOverEightWeeks() {
        let steady = Self.tally(count: 400, days: 56, scenario: .steady)
        #expect(steady.found <= 20, "steady: \(steady.found) of 400 — over the 5 % target")
        #expect(steady.found <= 16, "steady: \(steady.found) of 400, the script's 13")
        let gaining = Self.tally(count: 200, days: 56, scenario: .gaining)
        #expect(gaining.found <= 4, "gaining: \(gaining.found) of 200, the script's 1")
    }

    @Test func aRealDeficitIsFoundWithinWeeks() {
        let deficit = Self.tally(count: 200, days: 42, scenario: .deficit)
        #expect(deficit.found >= 126 && deficit.found <= 146, "0.5 %/wk: \(deficit.found) of 200, the script's 136")
        #expect(deficit.median >= 22 && deficit.median <= 28, "median day \(deficit.median), the script's 25")
        let fast = Self.tally(count: 200, days: 42, scenario: .fast)
        #expect(fast.found >= 185, "1 %/wk: \(fast.found) of 200, the script's 192")
        #expect(fast.median >= 18 && fast.median <= 24, "median day \(fast.median), the script's 21")
        let slow = Self.tally(count: 200, days: 42, scenario: .slow)
        #expect(slow.found >= 35 && slow.found <= 55, "0.25 %/wk: \(slow.found) of 200, the script's 45")
    }

    // MARK: - The synthetic weigh-ins (body_weight_sim.make_weigh_ins)

    enum Scenario: Int {
        case steady, slow, deficit, fast, gaining

        var weekly: Double {
            switch self {
            case .steady: 0
            case .slow: -0.0025
            case .deficit: -0.005
            case .fast: -0.01
            case .gaining: 0.0025
            }
        }
    }

    static let frequencies = [7, 3, 2]
    static let dayPatterns: [Int: Set<Int>] = [7: [0, 1, 2, 3, 4, 5, 6], 3: [0, 2, 4], 2: [0, 3]]
    static let sigmas = [0.006, 0.008, 0.010]

    /// One history's weigh-ins as (day, kg), oldest first, drawn exactly as the script draws them.
    static func weighIns(index: Int, days: Int, scenario: Scenario) -> [(day: Int, kilograms: Double)] {
        var rng = WorkoutPlateauSimulationTests.SplitMix64(
            seed: 0xB0D7_0000 + UInt64(index) * 7919 + UInt64(scenario.rawValue) * 104_729)
        let frequency = frequencies[Int(rng.unit() * 3) % 3]
        let sigma = sigmas[Int(rng.unit() * 3) % 3]
        let rho = rng.unit() < 0.5 ? 0.5 : 0.0
        let innovation = sigma * (1.0 - rho * rho).squareRoot()
        var noise = rng.gaussian() * sigma
        let daily = log(1.0 + scenario.weekly) / 7.0
        let pattern = dayPatterns[frequency] ?? []
        var out: [(day: Int, kilograms: Double)] = []
        for day in 0..<days {
            if day > 0 { noise = rho * noise + innovation * rng.gaussian() }
            let skip = rng.unit() < 0.1
            guard pattern.contains(day % 7), !skip else { continue }
            out.append((day, 80.0 * exp(daily * Double(day) + noise)))
        }
        return out
    }

    /// The first weigh-in day, from day 14, on which the shipping rule calls the weight falling.
    static func firstCall(_ weighIns: [(day: Int, kilograms: Double)]) -> Int? {
        var seen: [BodyWeightSample] = []
        for weighIn in weighIns {
            seen.append(BodyWeightSample(date: day(weighIn.day), kilograms: weighIn.kilograms))
            if weighIn.day >= 14, WorkoutBodyWeightTrend.isFalling(seen, today: day(weighIn.day)) {
                return weighIn.day
            }
        }
        return nil
    }

    /// How many of `count` histories are ever called falling, and the median day of the first call.
    static func tally(count: Int, days: Int, scenario: Scenario) -> (found: Int, median: Double) {
        let calls = (0..<count).compactMap { firstCall(weighIns(index: $0, days: days, scenario: scenario)) }.sorted()
        guard !calls.isEmpty else { return (0, 0) }
        let middle = calls.count / 2
        let median = calls.count.isMultiple(of: 2) ? Double(calls[middle - 1] + calls[middle]) / 2 : Double(calls[middle])
        return (calls.count, median)
    }
}
