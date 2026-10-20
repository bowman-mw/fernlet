// WorkoutPlateauSimulationTests.swift
// FernletTests
//
// The seeded Monte Carlo behind the plateau detector (the owner's G1 pick, 2026-10-20). It scores the
// SHIPPING detector (`WorkoutTrend.reading`) and a copy of the rule it replaced on the same synthetic
// histories, and pins what the research report asked of the new one: a false plateau in 5 % of
// histories or fewer over 12 weeks, where the old rule called nearly everyone stalled.
//
// The histories are the prototype's (`Tools/plateau-sim/plateau_sim.py`), drawn from the same
// SplitMix64 stream with the same seeds in the same order: linear-log truth
// e1RM = start × (1 + b·ln(t)), b = 10 % from an untrained start, 2.5 % from a trained one and 0 for a
// long-trained lifter over 60; session noise of 3, 4 or 5 %; 2 or 3 sessions a week with 5 % skipped;
// one fatigue dip of 5–8 % recovering over 1–2 weeks in 30 % of histories; 15 % of sessions after a
// short night (two in a row for 40 % of those), costing a lower-body lift 3 %; and, on request, a
// true stall from week 3–6. `Tools/plateau-sim/swift_mirror.py` mirrors the shipping detector line
// for line and predicts every count below; rerun it after any change to WorkoutTrend.
//
// | Run (histories)                       | Old rule        | New: false plateau | New: false dip |
// |---------------------------------------|-----------------|--------------------|----------------|
// | 12 weeks, training age known (400)    | 399 (99.8 %)    | 4 (1.0 %)          | 2 (0.5 %)      |
// | 12 weeks, training age inferred (400) | 399 (99.8 %)    | 9 (2.3 %)          | 3 (0.8 %)      |
// | older long-trained, b = 0, known (100)| 100 (100 %)     | 0                  | 0              |
// | older long-trained, inferred (100)    | 100 (100 %)     | 4                  | 2              |
//
// True stalls over 24 weeks, training age known: the new rule finds 91 of 100 beginner stalls (median
// delay 8.6 weeks) and 26 of 100 trained ones (median 13.3 weeks: a trained lifter's expected gain is
// about 0.1 % a week, so a stall takes about three months to tell from it). The old rule "found"
// every stall within a week, because it called almost everything a stall.
//
// The asserts allow a little slack around the mirror's counts (a last-bit difference between two
// platforms' log or cos can flip one borderline session); the targets themselves are hard limits.

import Foundation
import Testing
import FernletDomainModel

/// The plateau detector's Monte Carlo: false plateaus, false dips and detection delay, new rule
/// against old, on seeded synthetic histories.
struct WorkoutPlateauSimulationTests {

    // MARK: - The pinned results

    @Test func overTwelveWeeksTheNewRuleCallsFarFewerFalsePlateausThanTheOld() {
        for known in [true, false] {
            let tally = Self.tally(count: 400, weeks: 12, stall: false, known: known)
            let label = known ? "known" : "inferred"
            #expect(tally.oldFalse >= 380, "old rule, \(label): \(tally.oldFalse) of 400")
            #expect(tally.newFalse <= 20, "new rule, \(label): \(tally.newFalse) of 400 — over the 5 % target")
            let mirror = known ? 4 : 9
            #expect(tally.newFalse <= mirror + 3, "new rule, \(label): \(tally.newFalse), the mirror predicts \(mirror)")
            #expect(tally.falseDips <= 16, "false dips, \(label): \(tally.falseDips) of 400 — over 4 %")
        }
    }

    @Test func aSteadyLineInAnOlderLongTrainedLifterIsNeverAStall() {
        let known = Self.tally(count: 100, weeks: 12, stall: false, known: true, cohort: .older)
        #expect(known.newFalse == 0)
        #expect(known.oldFalse >= 95)
        let inferred = Self.tally(count: 100, weeks: 12, stall: false, known: false, cohort: .older)
        #expect(inferred.newFalse <= 7, "inferred: \(inferred.newFalse) of 100, the mirror predicts 4")
    }

    @Test func aTrueBeginnerStallIsFoundWithinAboutTwoMonths() {
        let tally = Self.tally(count: 100, weeks: 24, stall: true, known: true, cohort: .beginner)
        let delays = tally.newDelays
        #expect(delays.count >= 85, "found \(delays.count) of 100, the mirror finds 91")
        let median = Self.median(delays)
        #expect(median >= 6 && median <= 11, "median delay \(median) weeks, the mirror's is 8.6")
        #expect(tally.oldDelays.count >= 99)
    }

    @Test func aTrainedLiftersStallTakesAboutThreeMonthsToTellFromTheirCurve() {
        let tally = Self.tally(count: 100, weeks: 24, stall: true, known: true, cohort: .trained)
        let delays = tally.newDelays
        #expect(delays.count >= 15 && delays.count <= 40, "found \(delays.count) of 100, the mirror finds 26")
        let median = Self.median(delays)
        #expect(median >= 9, "median delay \(median) weeks, the mirror's is 13.3")
    }

    @Test func theStreamIsSplitMix64AndTheHistoriesAreDeterministic() {
        var rng = SplitMix64(seed: 0)
        let first = rng.next()
        #expect(first == 0xE220_A839_7B1D_CDAF)
        let a = Self.history(index: 7, weeks: 12, stall: false, cohort: nil).sessions.map { $0.score }
        let b = Self.history(index: 7, weeks: 12, stall: false, cohort: nil).sessions.map { $0.score }
        let same = a == b
        #expect(same)
        #expect(!a.isEmpty)
    }

    // MARK: - SplitMix64 (the prototype's stream)

    /// SplitMix64 (Steele, Lea & Flood 2014), the prototype's constants; Box–Muller for a normal draw.
    struct SplitMix64 {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in [0, 1) from the top 53 bits.
        mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992.0 }

        /// One standard normal draw (the second Box–Muller value is discarded, as in the prototype).
        mutating func gaussian() -> Double {
            let u1 = max(unit(), 1e-12)
            let u2 = unit()
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
    }

    // MARK: - Synthetic histories

    enum Cohort { case beginner, trained, older }

    struct Session {
        var day: Double
        var score: Double
        var flagged: Bool
        var firm: Bool
        /// The rep-ladder rule's "completed": the old rule's progressed-session gate.
        var completed: Bool
    }

    struct History {
        var cohort: Cohort
        var startWeeks: Double
        var lowerBody: Bool
        var stallWeek: Double?
        /// The fatigue dip: start (weeks), depth, duration (weeks).
        var dip: (start: Double, depth: Double, weeks: Double)?
        var sessions: [Session]
    }

    static let sigmas = [0.03, 0.04, 0.05]
    static let flagRate = 0.15
    static let firmShare = 0.4
    static let sleepPenalty = 0.03
    static let dipShare = 0.3
    static let skipRate = 0.05

    /// One history, drawn exactly as `plateau_sim.make_history` draws it.
    static func history(index: Int, weeks: Int, stall: Bool, cohort fixed: Cohort?) -> History {
        let seed = 0xF3A7_0000 + UInt64(index) * 7919 + (stall ? 104_729 : 0)
        var rng = SplitMix64(seed: seed)
        let cohort = fixed ?? (rng.unit() * 2 < 1 ? .beginner : .trained)
        let (b, startWeeks) = curve(cohort, &rng)
        let sigma = sigmas[Int(rng.unit() * 3) % 3]
        let perWeek = rng.unit() < 0.5 ? 2 : 3
        let lowerBody = rng.unit() < 0.5
        let stallWeek = stall ? 3 + rng.unit() * 3 : nil
        var dip: (start: Double, depth: Double, weeks: Double)?
        if rng.unit() < dipShare {
            let start = 2 + rng.unit() * (Double(weeks) - 4)
            let depth = 0.05 + rng.unit() * 0.03
            dip = (start, depth, 1 + rng.unit())
        }
        var history = History(cohort: cohort, startWeeks: startWeeks, lowerBody: lowerBody, stallWeek: stallWeek,
                              dip: dip, sessions: [])
        history.sessions = sessions(&rng, history: history, weeks: weeks, b: b, sigma: sigma, perWeek: perWeek)
        return history
    }

    /// The cohort's b and its training weeks at the first session.
    static func curve(_ cohort: Cohort, _ rng: inout SplitMix64) -> (b: Double, startWeeks: Double) {
        switch cohort {
        case .beginner: return (0.10, 1 + rng.unit() * 7)
        case .trained: return (0.025, 26 + rng.unit() * 130)
        case .older: return (0, 260 + rng.unit() * 260)
        }
    }

    /// The history's logged sessions, week by week, in the prototype's draw order.
    static func sessions(
        _ rng: inout SplitMix64, history: History, weeks: Int, b: Double, sigma: Double, perWeek: Int
    ) -> [Session] {
        let offsets = perWeek == 2 ? [0, 3] : [0, 2, 4]
        var sessions: [Session] = []
        var required: Double?
        for week in 0..<weeks {
            for offset in offsets {
                guard rng.unit() >= skipRate else { continue }
                let day = Double(week * 7 + offset)
                var value = truth(history, b: b, elapsed: day / 7)
                let flagged = rng.unit() < flagRate
                let firm = flagged && rng.unit() < firmShare
                if flagged && history.lowerBody { value *= 1 - sleepPenalty }
                let score = value * exp(sigma * rng.gaussian())
                let bar = required ?? score * 0.97
                let completed = score >= bar
                required = completed ? bar * 1.025 : bar
                sessions.append(Session(day: day, score: score, flagged: flagged, firm: firm, completed: completed))
            }
        }
        return sessions
    }

    /// The true estimated max `elapsed` weeks in: linear-log, flat from the stall, with the dip.
    static func truth(_ history: History, b: Double, elapsed: Double) -> Double {
        var trained = history.startWeeks + elapsed
        if let stall = history.stallWeek { trained = min(trained, history.startWeeks + stall) }
        var value = 100 * (1 + b * log(max(trained, 1)))
        if let dip = history.dip, dip.start <= elapsed, elapsed <= dip.start + dip.weeks {
            value *= 1 - dip.depth * (1 - (elapsed - dip.start) / dip.weeks)
        }
        return value
    }

    /// Whether `day` is inside the dip, or the week after it (a real dip is not a false one).
    static func inTrueDip(_ history: History, day: Double) -> Bool {
        guard let dip = history.dip else { return false }
        let start = dip.start * 7
        return start <= day && day <= start + dip.weeks * 7 + 7
    }

    // MARK: - The old rule (WorkoutPlateau.isStalled before 2026-10-20)

    /// Latest four sessions against the 112-day best: steady training (three sessions in four weeks,
    /// no gap over 14 days), at most one completed session among the four, and their best no more
    /// than 1 % over the earlier best.
    static func oldRuleStalled(_ sessions: ArraySlice<Session>) -> Bool {
        guard let last = sessions.last else { return false }
        let recent = sessions.filter { last.day - $0.day <= 28 }
        guard recent.count >= 3 else { return false }
        for index in recent.indices.dropFirst() where recent[index].day - recent[index - 1].day > 14 {
            return false
        }
        let evidence = sessions.filter { last.day - $0.day <= 112 }
        guard evidence.count > 4 else { return false }
        let latest = evidence.suffix(4)
        guard latest.filter(\.completed).count <= 1 else { return false }
        let earlierBest = evidence.dropLast(4).map(\.score).max() ?? 0
        let recentBest = latest.map(\.score).max() ?? 0
        return recentBest <= earlierBest * 1.01
    }

    // MARK: - Scoring

    static let origin = Date(timeIntervalSince1970: 1_790_000_000)

    /// The trend points for a history's sessions: a flagged session after one short night or two.
    static func points(_ history: History) -> [TrendPoint] {
        history.sessions.map { session in
            let flag = session.flagged
                ? WorkoutSessionFlag(sleep: session.firm ? .shortNights : .shortNight) : nil
            return TrendPoint(date: origin.addingTimeInterval(session.day * 86_400), score: session.score, flag: flag)
        }
    }

    /// The profile at the history's `day`: the true training age when `known`, else inferred; an
    /// older long-trained lifter says they are 65.
    static func profile(_ history: History, day: Double, known: Bool) -> TrendProfile {
        let traits = history.cohort == .older ? LifterTraits(ageYears: 65) : .unknown
        let age = known ? TrainingAge(weeks: history.startWeeks + day / 7) : nil
        return TrendProfile(trainingAge: age, traits: traits, lowerBody: history.lowerBody)
    }

    struct Outcome {
        var oldFalse = false
        var newFalse = false
        var falseDip = false
        var oldDelay: Double?
        var newDelay: Double?
    }

    /// Every prefix of a history scored by both rules: a stall call before the true stall (or with
    /// none) is false, the first call after it sets the delay, and a dip outside the true one is false.
    static func outcome(of history: History, known: Bool) -> Outcome {
        let points = points(history)
        let onset = history.stallWeek.map { $0 * 7 }
        var outcome = Outcome()
        for end in points.indices {
            let day = history.sessions[end].day
            let state = WorkoutTrend.reading(of: Array(points[...end]), profile: profile(history, day: day, known: known)).state
            let old = oldRuleStalled(history.sessions[...end])
            if let onset, day >= onset {
                if old, outcome.oldDelay == nil { outcome.oldDelay = (day - onset) / 7 }
                if state == .stalled, outcome.newDelay == nil { outcome.newDelay = (day - onset) / 7 }
            } else {
                outcome.oldFalse = outcome.oldFalse || old
                outcome.newFalse = outcome.newFalse || state == .stalled
            }
            if state == .dipping, !inTrueDip(history, day: day) { outcome.falseDip = true }
        }
        return outcome
    }

    struct Tally {
        var oldFalse = 0
        var newFalse = 0
        var falseDips = 0
        var oldDelays: [Double] = []
        var newDelays: [Double] = []
    }

    static func tally(count: Int, weeks: Int, stall: Bool, known: Bool, cohort: Cohort? = nil) -> Tally {
        var tally = Tally()
        for index in 0..<count {
            let result = outcome(of: history(index: index, weeks: weeks, stall: stall, cohort: cohort), known: known)
            tally.oldFalse += result.oldFalse ? 1 : 0
            tally.newFalse += result.newFalse ? 1 : 0
            tally.falseDips += result.falseDip ? 1 : 0
            if let delay = result.oldDelay { tally.oldDelays.append(delay) }
            if let delay = result.newDelay { tally.newDelays.append(delay) }
        }
        return tally
    }

    /// The prototype's median: the upper middle of an even count.
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[sorted.count / 2]
    }
}
