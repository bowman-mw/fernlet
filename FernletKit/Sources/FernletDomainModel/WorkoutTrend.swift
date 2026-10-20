// WorkoutTrend.swift
// FernletDomainModel
//
// The plateau detector (the owner's G1 pick, 2026-10-20). It replaces "the latest four sessions vs
// the 112-day best", which the research report found flags lifters who are still improving: one
// session's estimated max moves 3–5 % from day to day, far more than a trained lifter's real weekly
// gain. Instead each lift gets a robust straight line through its clean sessions, in log units (so the
// slope reads as a fraction per week), compared with the person's own expected linear-log curve:
// expected e1RM = start × (1 + b·ln(t/t0)), with b set by training age.
//
// States: progressing, slowing (a soft note), stalled (the response ladder), dipping (a short volume
// cut), and too early to tell. Deterministic and stateless, like the load engine.
//
// Every threshold was tuned in a seeded Monte Carlo before it shipped (the prototype that explored
// them is `Tools/plateau-sim/plateau_sim.py`). `Tests/FernletTests/WorkoutPlateauSimulationTests.swift`
// pins this file's behavior on those histories, and `Tools/plateau-sim/swift_mirror.py` mirrors this
// file line for line so the numbers can be regenerated without a Mac. Over 1,200 synthetic histories of
// 12 weeks (noise 3–5 %, 2–3 sessions a week, a fatigue dip in 30 % of histories, 15 % of sessions
// after a short night), `swift_mirror.py 1200` gives:
//
// | Training age          | Cohort                | Old rule false plateau | New false plateau | New false dip |
// |-----------------------|-----------------------|------------------------|-------------------|---------------|
// | known (step 2)        | beginner              | 99.7 %                 | 1.1 %             | 0.8 %         |
// | known                 | trained               | 100 %                  | 2.3 %             | 0.5 %         |
// | known                 | older long-trained    | 100 %                  | 0 %               | 0 %           |
// | inferred (no answer)  | beginner              | 99.7 %                 | 0.3 %             | 0.8 %         |
// | inferred              | trained               | 100 %                  | 3.3 %             | 1.7 %         |
// | inferred              | older long-trained    | 100 %                  | 3.0 %             | 1.7 %         |
//
// A true stall (slope 0 from week 3–6, 24 weeks) is found in 90 % of beginner histories with a median
// delay of 8.7 weeks when the training age is known (43 %, 9.9 weeks, inferred). A trained lifter's
// stall is barely distinguishable from their expected curve (about 0.1 % a week), so it is found in
// about a quarter to a third of histories, after about 12 weeks — the research's "a credible stalled
// call takes about three months". The old rule found every stall within a week, because it called
// almost everything a stall.

import Foundation

/// What a lift's trend says.
public nonisolated enum TrendState: String, CaseIterable, Sendable {
    /// Above the expected curve, or not clearly below it: nothing to say.
    case progressing
    /// Clearly below the expected curve, or clearly below half the previous window's slope: a soft
    /// note that slowing is the normal curve.
    case slowing
    /// The upper 80 % bound of the slope, times four weeks, is under 1 %, and the slope sits clearly
    /// under the expected curve — on three evaluations in a row.
    case stalled
    /// Two clean sessions in a row more than two typical errors under the line: a short volume cut.
    case dipping
    /// Too few clean sessions, or half or more of the window flagged.
    case tooEarly
}

/// Training age, in tiers that set the trend's window, its noise prior and the expected curve.
public nonisolated enum TrainingTier: String, CaseIterable, Sendable {
    case beginner
    case intermediate
    case advanced

    /// The tier for `weeks` of training: under six months, under two years, or more.
    public static func tier(forWeeks weeks: Double) -> TrainingTier {
        if weeks < WorkoutTrend.intermediateWeeks { return .beginner }
        if weeks < WorkoutTrend.advancedWeeks { return .intermediate }
        return .advanced
    }

    /// Clean sessions the trend window needs before it says anything.
    public var minimumSessions: Int {
        switch self {
        case .beginner: 5
        case .intermediate: 8
        case .advanced: 12
        }
    }

    /// The span the trend window needs, in weeks.
    public var minimumWeeks: Double {
        switch self {
        case .beginner: 1.5
        case .intermediate: 6
        case .advanced: 10
        }
    }

    /// How far back the trend window reads, in weeks.
    public var trendWeeks: Double {
        switch self {
        case .beginner: 4
        case .intermediate: 8
        case .advanced: 12
        }
    }

    /// How far back — and how much span — the stall test needs, in weeks (tuned in simulation).
    public var stallWeeks: Double {
        switch self {
        case .beginner: 8
        case .intermediate: 10
        case .advanced: 12
        }
    }

    /// Session noise assumed until the person's own scatter is known (log units, about a fraction).
    public var noisePrior: Double {
        switch self {
        case .beginner: 0.045
        case .intermediate: 0.035
        case .advanced: 0.03
        }
    }

    /// The expected curve's b before the person's traits adjust it: about 10 % from an untrained
    /// start, about 2.5 % from a trained one.
    public var baseRate: Double {
        switch self {
        case .beginner: 0.10
        case .intermediate, .advanced: 0.025
        }
    }
}

/// How long someone has trained, as of their newest session of the lift.
public nonisolated struct TrainingAge: Equatable, Sendable {
    public var weeks: Double
    /// Read from the lift's history rather than asked (step 2 adds the setup question).
    public var isInferred: Bool

    public init(weeks: Double, isInferred: Bool = false) {
        self.weeks = weeks.isFinite ? max(1, weeks) : 1
        self.isInferred = isInferred
    }

    /// An explicit training age in years.
    public static func years(_ years: Double) -> TrainingAge {
        TrainingAge(weeks: years * 52)
    }

    /// Inferred from the history's length: one week plus the weeks from its first session to its newest.
    public static func inferred(from first: Date, to latest: Date) -> TrainingAge {
        TrainingAge(weeks: 1 + WorkoutTrend.weeks(from: first, to: latest), isInferred: true)
    }

    public var tier: TrainingTier { TrainingTier.tier(forWeeks: weeks) }
}

/// The person's traits that nudge the expected curve, all optional and read on device only.
public nonisolated struct LifterTraits: Equatable, Sendable {
    public var sex: BiologicalSex?
    public var ageYears: Int?
    public var bodyWeightKg: Double?

    public init(sex: BiologicalSex? = nil, ageYears: Int? = nil, bodyWeightKg: Double? = nil) {
        self.sex = sex
        self.ageYears = ageYears
        self.bodyWeightKg = bodyWeightKg.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// Nothing known: the tier's own curve.
    public static let unknown = LifterTraits()
}

/// Everything about the lifter and the lift the trend reads besides the sessions.
public nonisolated struct TrendProfile: Equatable, Sendable {
    /// Explicit when known; nil infers it per lift from the history's length.
    public var trainingAge: TrainingAge?
    public var traits: LifterTraits
    /// Squats, hinges and lunges: a short night costs them more, and "strong" is judged higher.
    public var lowerBody: Bool

    public init(trainingAge: TrainingAge? = nil, traits: LifterTraits = .unknown, lowerBody: Bool = false) {
        self.trainingAge = trainingAge
        self.traits = traits
        self.lowerBody = lowerBody
    }

    /// This profile as of `date`, an earlier session than `newest`: a known training age that much
    /// younger (never under a week); an inferred one is read from the history either way.
    public func asOf(_ date: Date, newest: Date) -> TrendProfile {
        guard let age = trainingAge, !age.isInferred else { return self }
        var earlier = self
        earlier.trainingAge = TrainingAge(weeks: age.weeks - WorkoutTrend.weeks(from: date, to: newest))
        return earlier
    }
}

/// One clean session of a lift as the trend reads it: when, its score (estimated max, or reps for a
/// lift with no load), and its flag.
public nonisolated struct TrendPoint: Equatable, Sendable {
    public var date: Date
    public var score: Double
    public var flag: WorkoutSessionFlag?

    public init(date: Date, score: Double, flag: WorkoutSessionFlag? = nil) {
        self.date = date
        self.score = score
        self.flag = flag
    }
}

/// The trend's verdict on a lift, with the numbers behind it and the flags in its window.
public nonisolated struct TrendReading: Equatable, Sendable {
    public var state: TrendState
    /// The fitted slope, in log units per week (about a fraction per week); nil while too early.
    public var slopePerWeek: Double?
    /// The expected curve's slope over the same window; nil while too early or with an inferred age.
    public var expectedPerWeek: Double?
    /// Sessions in the trend window, and how many of them were flagged, by reason.
    public var windowSessions: Int
    public var flaggedSessions: Int
    public var shortNightSessions: Int
    public var lightDaySessions: Int

    public init(
        state: TrendState = .tooEarly, slopePerWeek: Double? = nil, expectedPerWeek: Double? = nil,
        windowSessions: Int = 0, flaggedSessions: Int = 0, shortNightSessions: Int = 0, lightDaySessions: Int = 0
    ) {
        self.state = state
        self.slopePerWeek = slopePerWeek
        self.expectedPerWeek = expectedPerWeek
        self.windowSessions = windowSessions
        self.flaggedSessions = flaggedSessions
        self.shortNightSessions = shortNightSessions
        self.lightDaySessions = lightDaySessions
    }

    /// Half or more of the window was flagged: there weren't enough typical days to judge.
    public var mostlyFlagged: Bool { windowSessions > 0 && flaggedSessions * 2 >= windowSessions }
}

/// The trend detector: the window, the line, the expected curve and the state.
public nonisolated enum WorkoutTrend {

    // MARK: Tuned numbers (simulation, 2026-10-20)

    /// Training-age tier edges, in weeks: six months, two years.
    public static let intermediateWeeks = 26.0
    public static let advancedWeeks = 104.0
    /// One-sided 80 % bound on the slope (the research's "upper 80 % bound").
    public static let upperBoundZ = 0.8416
    /// How clearly the slope must sit under the expected curve for a stall, in standard errors
    /// (one-sided 95 %; tuned so false plateaus stay at or under 5 % of histories over 12 weeks).
    public static let expectedMarginZ = 1.645
    /// The smallest worthwhile gain: 1 % per four weeks.
    public static let stallGainPerFourWeeks = 0.01
    /// Evaluations in a row the stall test must hold.
    public static let stallPersistence = 3
    /// Clean sessions before the person's own scatter replaces the noise prior…
    public static let personalNoiseAfter = 10
    /// …which it never undercuts by more than this share.
    public static let personalNoiseFloor = 0.75
    /// Dipping: this many typical errors under the line's level.
    public static let dipErrors = 2.0
    /// A flagged session's weight when it falls short of the line.
    public static let flaggedWeight = 0.5
    /// With an inferred training age, the expected slope is the lift's own earlier progress, read
    /// over this many weeks before the stall window from at least this many clean sessions.
    public static let ownProgressWeeks = 4.0
    public static let ownProgressSessions = 6
    /// Steady training for a stall: sessions in the last four weeks, none further apart than this.
    public static let adherenceDays = 28.0
    public static let adherenceSessions = 3
    public static let adherenceGapDays = 14.0
    /// The expected curve: b is raised for women and lighter or weaker lifters, lowered for strong
    /// men, and zero for long-trained lifters over 60 (G9: a steady line is success).
    public static let femaleRateFactor = 1.15
    public static let lighterRateFactor = 1.1
    public static let strongRateFactor = 0.8
    public static let lightBodyWeightKg = 60.0
    public static let olderAdultYears = 60
    /// Estimated max over body weight that counts as strong, and as weaker, by body half.
    public static let strongRatioUpper = 1.25
    public static let strongRatioLower = 1.75
    public static let weakerRatioUpper = 0.6
    public static let weakerRatioLower = 0.9

    static let secondsPerDay = 86_400.0

    /// Fractional weeks from `start` to `end`.
    public static func weeks(from start: Date, to end: Date) -> Double {
        end.timeIntervalSince(start) / (secondsPerDay * 7)
    }

    /// Fractional days from `start` to `end`.
    static func days(from start: Date, to end: Date) -> Double {
        end.timeIntervalSince(start) / secondsPerDay
    }

    // MARK: The reading

    /// The lift's trend after its newest point (oldest first). `levelKg` is its current estimated max
    /// in kilograms, for the strong/weaker adjustment; nil skips it (a lift with no load).
    public static func reading(of points: [TrendPoint], profile: TrendProfile, levelKg: Double? = nil) -> TrendReading {
        let points = Array(points.suffix(WorkoutLoadEngine.maxExposuresPerLift))
        guard let first = points.first, let last = points.last else { return TrendReading() }
        let resolved = resolve(profile, first: first.date, last: last.date, levelKg: levelKg)
        let window = points.filter { days(from: $0.date, to: last.date) <= resolved.tier.trendWeeks * 7 }
        var reading = counts(window)
        guard let start = window.first, enoughData(window, tier: resolved.tier, from: start.date, to: last.date),
              let trend = fitWindow(window, sigma: resolved.tier.noisePrior, shortWeight: flaggedWeight,
                                    lowerBody: resolved.lowerBody) else { return reading }
        let sigma = noise(window, tier: resolved.tier, trend: trend)
        let expected = resolved.inferred ? nil : expectedSlope(resolved, from: start.date, to: last.date)
        reading.slopePerWeek = trend.fit.slope
        reading.expectedPerWeek = expected
        reading.state = state(points, window: window, trend: trend, sigma: sigma, resolved: resolved, expected: expected)
        return reading
    }

    /// The window's session and flag counts, state too early.
    static func counts(_ window: [TrendPoint]) -> TrendReading {
        TrendReading(
            windowSessions: window.count,
            flaggedSessions: window.filter { $0.flag != nil }.count,
            shortNightSessions: window.filter { $0.flag?.sleep != nil }.count,
            lightDaySessions: window.filter { $0.flag?.lightDay == true }.count
        )
    }

    /// Enough clean sessions over enough weeks, and fewer than half flagged.
    static func enoughData(_ window: [TrendPoint], tier: TrainingTier, from start: Date, to end: Date) -> Bool {
        let flagged = window.filter { $0.flag != nil }.count
        guard window.count - flagged >= tier.minimumSessions, weeks(from: start, to: end) >= tier.minimumWeeks else {
            return false
        }
        return flagged * 2 < window.count
    }

    /// Dipping first (the fatigue branch), then the stall test, then slowing; progressing otherwise.
    static func state(
        _ points: [TrendPoint], window: [TrendPoint], trend: WindowFit, sigma: Double, resolved: ResolvedProfile,
        expected: Double?
    ) -> TrendState {
        guard !isDipping(window, sigma: sigma, lowerBody: resolved.lowerBody) else { return .dipping }
        guard !isStalled(points, resolved: resolved) else { return .stalled }
        let upper = trend.fit.slope + upperBoundZ * sigma / trend.fit.sxx.squareRoot()
        if let expected, upper < expected { return .slowing }
        guard let start = window.first,
              let previous = previousSlope(points, before: start.date, tier: resolved.tier, sigma: sigma,
                                           lowerBody: resolved.lowerBody) else { return .progressing }
        return previous > 0 && upper < previous / 2 ? .slowing : .progressing
    }

    // MARK: The stall test

    /// The stall test on this evaluation and the ones before it (``stallPersistence`` in a row).
    static func isStalled(_ points: [TrendPoint], resolved: ResolvedProfile) -> Bool {
        guard points.count > stallPersistence else { return false }
        for back in 0..<stallPersistence {
            guard isStallCandidate(Array(points.prefix(points.count - back)), resolved: resolved) else { return false }
        }
        return true
    }

    /// One evaluation of the stall test on its own longer window: flagged sessions that fell short are
    /// left out, the slope's upper 80 % bound stays under 1 % per four weeks, and the slope sits
    /// clearly under the expected curve (or, with an inferred training age, the lift's own earlier
    /// progress). Needs steady training, and never fires for a curve that expects no gain (G9).
    static func isStallCandidate(_ points: [TrendPoint], resolved: ResolvedProfile) -> Bool {
        guard resolved.rate > 0, let last = points.last, isAdherent(points) else { return false }
        let tier = resolved.tier
        let window = points.filter { days(from: $0.date, to: last.date) <= tier.stallWeeks * 7 }
        let flagged = window.filter { $0.flag != nil }.count
        guard let start = window.first, window.count - flagged >= tier.minimumSessions, flagged * 2 < window.count,
              weeks(from: start.date, to: last.date) >= tier.stallWeeks - 0.5,
              let trend = fitWindow(window, sigma: tier.noisePrior, shortWeight: flaggedWeight, lowerBody: resolved.lowerBody)
        else { return false }
        let sigma = noise(window, tier: tier, trend: trend)
        guard let stall = fitWindow(window, sigma: sigma, shortWeight: 0, lowerBody: resolved.lowerBody) else { return false }
        let error = sigma / stall.fit.sxx.squareRoot()
        let expected: Double?
        if resolved.inferred {
            expected = ownExpectedSlope(points, before: start.date, sigma: sigma, lowerBody: resolved.lowerBody)
        } else {
            expected = expectedSlope(resolved, from: start.date, to: last.date)
        }
        guard let expected else { return false }
        let slope = stall.fit.slope
        return (slope + upperBoundZ * error) * 4 < stallGainPerFourWeeks && slope + expectedMarginZ * error < expected
    }

    /// At least three sessions in the four weeks before the newest, none more than two weeks apart.
    static func isAdherent(_ points: [TrendPoint]) -> Bool {
        guard let last = points.last else { return false }
        let recent = points.filter { days(from: $0.date, to: last.date) <= adherenceDays }
        guard recent.count >= adherenceSessions else { return false }
        for index in recent.indices.dropFirst() {
            guard days(from: recent[index - 1].date, to: recent[index].date) <= adherenceGapDays else { return false }
        }
        return true
    }
}
