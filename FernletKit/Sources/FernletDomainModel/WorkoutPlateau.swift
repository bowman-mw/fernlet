// WorkoutPlateau.swift
// FernletDomainModel
//
// What the planner does about a lift's trend (the owner's G1 and G5 picks, 2026-10-20). The trend
// itself is ``WorkoutTrend``: a smoothed slope against the person's own expected curve, which calls a
// stall only after weeks of steady training — the old "latest four vs the 112-day best" test called
// almost every lifter stalled within weeks (see WorkoutTrend.swift for the simulation table).
//
// The ladder, in the research report's order:
// 1. a fair retest — at least three minutes' rest, the lift first in the session;
// 2. a loading change — a short heavier block, or one more weekly session of the lift;
// 3. a variant beside the main lift, which stays at lower volume and is never removed;
// 4. "holding steady" — calm, with options that fit the goal.
// A dip is not a plateau: two clean sessions well under the line get a deload instead (half the
// sets, the load kept). The helper-muscle support step is gone (randomized trials found it did nothing
// for the main lift). Stateless like the load engine: the onset and the stage are re-derived from the
// history every time.

import Foundation

/// Where a stalled lift is on the response ladder, counted in sessions since the stall was called.
///
/// Raw values are FROZEN tokens. Nothing persists a stage today; if anything ever does, decode it
/// through ``resolve(token:parkedToken:)``, which maps the old ladder's tokens to the nearest step.
public nonisolated enum PlateauStage: String, CaseIterable, Sendable {
    /// At least three minutes' rest between sets, and the lift first in the session.
    case fairRetest
    /// A short heavier block (fewer reps, more weight), or one more weekly session of the lift.
    case loadingChange
    /// A variant joins the main lift, which stays at lower volume.
    case variant
    /// Calm: steady is fine, with options that fit the goal.
    case holdingSteady

    /// The old ladder's tokens (2026-10-19), each mapped to the nearest step of this one: its easier
    /// session and its rest-and-order step to the retest, its support block to the loading change, its
    /// variation to the variant, and its return from the variation to holding steady.
    static let legacyTokens: [String: PlateauStage] = [
        "easierSession": .fairRetest,
        "recover": .fairRetest,
        "supportWork": .loadingChange,
        "variation": .variant,
        "afterVariation": .holdingSteady,
    ]

    /// A stage from a stored token, this ladder's or the old one's; nil for a token neither knows.
    public init?(persistedToken token: String) {
        if let stage = PlateauStage(rawValue: token) {
            self = stage
            return
        }
        guard let legacy = Self.legacyTokens[token] else { return nil }
        self = legacy
    }

    /// The tolerant decode (`EnumDecodeCompat`): a known or legacy token resolves, an unknown one
    /// freezes to the retest and parks the token for a newer build.
    public static func resolve(token: String?, parkedToken: String?) -> (value: PlateauStage, parkedToken: String?) {
        EnumDecodeCompat.resolveScalar(token: token, parkedToken: parkedToken, default: .fairRetest,
                                       resolve: { PlateauStage(persistedToken: $0) })
    }
}

/// What the planner should say or do about one lift's trend: a stall on the ladder, a dip, a soft
/// "slowing" note, or "too early to tell" when half the window was flagged. A progressing lift has none.
public nonisolated struct PlateauStatus: Equatable, Sendable {
    /// `.stalled`, `.dipping`, `.slowing`, `.tooEarly`, or weight management's `.eased` — never
    /// `.progressing`.
    public var state: TrendState
    /// The ladder step while stalled; nil otherwise.
    public var stage: PlateauStage?
    /// Sessions of the lift logged since the stall was called (0 on the calling session).
    public var sessionsSinceOnset: Int
    /// Whole weeks since the lift last set a best, for the copy.
    public var weeksHeld: Int
    /// The trend behind it, with the window's flag counts for the context lines.
    public var reading: TrendReading

    public init(state: TrendState, stage: PlateauStage? = nil, sessionsSinceOnset: Int = 0, weeksHeld: Int = 0,
                reading: TrendReading = TrendReading()) {
        self.state = state
        self.stage = stage
        self.sessionsSinceOnset = sessionsSinceOnset
        self.weeksHeld = weeksHeld
        self.reading = reading
    }
}

/// Recent protein, summarized by the app. Context only; step 4 of the round reworks it. The old
/// "sleep under 7 h on average" check is retired: sleep now flags single sessions (``WorkoutSessionFlag``).
public nonisolated struct RecoverySummary: Equatable, Sendable {
    /// Average share of the protein target eaten, over days with meals logged (1.0 = on target).
    public var averageProteinRatio: Double?
    public var proteinDays: Int

    public init(averageProteinRatio: Double? = nil, proteinDays: Int = 0) {
        self.averageProteinRatio = averageProteinRatio
        self.proteinDays = max(0, proteinDays)
    }

    /// Nothing known.
    public static let unknown = RecoverySummary()

    /// Under 80 % of the protein target on average, over at least four days with meals.
    public var proteinIsLow: Bool {
        guard proteinDays >= WorkoutPlateau.proteinMinimumDays, let ratio = averageProteinRatio else { return false }
        return ratio < WorkoutPlateau.proteinLowRatio
    }
}

/// How much of the trend a goal hears (G7, 2026-10-20). Wellness, mental health, recovery and
/// exploring track minutes and sessions, never a plateau; weight management hears only a quiet
/// "strength held" check after a sustained drop; strength and sports prep follow their main lifts.
public nonisolated enum PlateauTracking: Sendable {
    /// No plateau notes and no strength test.
    case off
    /// Only ``WorkoutPlateau/strengthHeldStatus(of:unit:today:profile:)``; no strength test.
    case strengthHeld
    /// The full trend and ladder on main lifts, and the monthly strength test.
    case mainLifts

    /// The tracking a goal gets.
    public static func forGoal(_ goal: GoalType) -> PlateauTracking {
        switch goal {
        case .strength, .sportsPrep: .mainLifts
        case .weightManagement: .strengthHeld
        case .wellness, .mentalHealth, .recovery, .exploring: .off
        }
    }

    /// Whether the monthly strength test (``WorkoutCalibration``) runs for this tracking.
    public var runsStrengthTest: Bool { self == .mainLifts }
}

/// Reads a lift's trend into what the planner does about it.
public nonisolated enum WorkoutPlateau {

    // MARK: Numbers

    /// A lift untouched this long is on a break, not a plateau.
    public static let staleDays = 42
    /// How far back the planner reads a lift's sessions.
    public static let lookbackDays = 112
    /// Overrides in the latest sessions that make it a calibration problem instead.
    public static let overridesThatExplain = 2
    public static let overrideSessions = 4
    /// A new best must beat the old one by this fraction (the "held steady for N weeks" copy).
    public static let improvementThreshold = 0.01
    /// Sessions on each ladder step before the next: the retest, the loading change, the variant.
    public static let retestSessions = 2
    public static let loadingChangeSessions = 6
    public static let variantSessions = 8
    /// The fair retest's rest between sets, at least.
    public static let retestRestSeconds = 180
    /// The heavier block: this many fewer reps than the plan's, never under the floor.
    public static let heavierBlockRepDrop = 2
    public static let heavierBlockMinimumReps = 3
    /// The main lift beside its variant: this many sets fewer, never under the floor.
    public static let variantMainSetDrop = 1
    public static let variantMainMinimumSets = 2
    /// The deload keeps the load; it may sit at most this far under the last working weight.
    public static let deloadMaxDecrease = 0.05
    public static let proteinLowRatio = 0.8
    public static let proteinMinimumDays = 4

    // MARK: Status

    /// The lift's status, or nil when it is progressing, too new, on a break, or explained by
    /// overrides — or dipping with the deload already logged. `exposures` are the lift's sessions,
    /// oldest first; `profile` defaults to an inferred training age with no traits; `levelKg` is the
    /// lift's estimated max in kilograms, when loaded.
    public static func status(
        of exposures: [LiftExposure], unit: LoadUnit, today: Date, profile: TrendProfile? = nil, levelKg: Double? = nil
    ) -> PlateauStatus? {
        // Ramp sets leave before the cap: three warm-ups a session would otherwise crowd out three
        // quarters of the sessions an advanced lifter's 12-week window needs.
        let history = Array(exposures.filter { $0.calibration != .ramp }.suffix(WorkoutLoadEngine.maxExposuresPerLift))
        guard let last = history.last, WorkoutLoadEngine.days(from: last.date, to: today) <= staleDays else {
            return nil
        }
        let overrides = history.suffix(overrideSessions).filter { $0.overrideDirection != nil }.count
        guard overrides < overridesThatExplain else { return nil }
        let points = WorkoutTrend.points(from: history, unit: unit)
        let profile = profile ?? TrendProfile()
        let reading = WorkoutTrend.reading(of: points, profile: profile, levelKg: levelKg)
        let onset = onsetIndex(points, profile: profile, levelKg: levelKg)
        let weeks = weeksSinceBest(points, today: today)
        switch reading.state {
        case .progressing, .eased:
            return nil
        case .dipping:
            // A deload logged since the two low sessions answered them; the next regular session decides.
            guard history.last?.easierSession != true else { return nil }
            return PlateauStatus(state: .dipping, weeksHeld: weeks, reading: reading)
        case .stalled, .slowing, .tooEarly:
            if let onset {
                let since = max(0, points.count - 1 - onset)
                return PlateauStatus(state: .stalled, stage: stage(sessionsSinceOnset: since),
                                     sessionsSinceOnset: since, weeksHeld: weeks, reading: reading)
            }
            guard reading.state == .slowing || reading.mostlyFlagged else { return nil }
            return PlateauStatus(state: reading.state, weeksHeld: weeks, reading: reading)
        }
    }

    /// The point where the current stall was first called, or nil. A stall holds through slowing and
    /// too-early readings (a flagged week can't end it) and clears only when the lift progresses. Each
    /// earlier reading is taken as of its own newest session, so a known training age is that much
    /// younger there (``TrendProfile/asOf(_:newest:)``).
    static func onsetIndex(_ points: [TrendPoint], profile: TrendProfile, levelKg: Double?) -> Int? {
        guard let newest = points.last?.date else { return nil }
        var onset: Int?
        for end in 1...points.count {
            let prefix = Array(points.prefix(end))
            let asOf = profile.asOf(prefix.last?.date ?? newest, newest: newest)
            switch WorkoutTrend.reading(of: prefix, profile: asOf, levelKg: levelKg).state {
            case .stalled: onset = onset ?? end - 1
            case .progressing: onset = nil
            case .slowing, .dipping, .tooEarly, .eased: break
            }
        }
        return onset
    }

    /// Weight management's quiet check (G7): a status only when the lift's line has fallen beyond
    /// noise for weeks (``WorkoutTrend/hasEased(_:profile:)``), else nil — no stall, dip or slowing
    /// note ever. Not while overrides explain the numbers or the lift is on a break.
    public static func strengthHeldStatus(
        of exposures: [LiftExposure], unit: LoadUnit, today: Date, profile: TrendProfile? = nil
    ) -> PlateauStatus? {
        let history = Array(exposures.filter { $0.calibration != .ramp }.suffix(WorkoutLoadEngine.maxExposuresPerLift))
        guard let last = history.last, WorkoutLoadEngine.days(from: last.date, to: today) <= staleDays else {
            return nil
        }
        guard history.suffix(overrideSessions).filter({ $0.overrideDirection != nil }).count < overridesThatExplain else {
            return nil
        }
        let points = WorkoutTrend.points(from: history, unit: unit)
        let profile = profile ?? TrendProfile()
        guard WorkoutTrend.hasEased(points, profile: profile) else { return nil }
        let reading = WorkoutTrend.reading(of: points, profile: profile)
        return PlateauStatus(state: .eased, weeksHeld: weeksSinceBest(points, today: today), reading: reading)
    }

    /// The ladder step `sessionsSinceOnset` sessions after the stall was called. No cycling: after the
    /// variant, the lift is holding steady until it moves again.
    public static func stage(sessionsSinceOnset: Int) -> PlateauStage {
        if sessionsSinceOnset < retestSessions { return .fairRetest }
        if sessionsSinceOnset < retestSessions + loadingChangeSessions { return .loadingChange }
        if sessionsSinceOnset < retestSessions + loadingChangeSessions + variantSessions { return .variant }
        return .holdingSteady
    }

    /// Whole weeks since the lift's best score (at least one), for "has held steady for 3 weeks".
    static func weeksSinceBest(_ points: [TrendPoint], today: Date) -> Int {
        var best: TrendPoint?
        for point in points where point.score > (best?.score ?? 0) * (1 + improvementThreshold) {
            best = point
        }
        guard let best else { return 0 }
        return max(1, WorkoutLoadEngine.days(from: best.date, to: today) / 7)
    }
}
