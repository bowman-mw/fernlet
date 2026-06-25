import Foundation
import HealthKit
import Observation

// MARK: - Abstract egress vocabulary
//
// These are the ONLY types that may cross out of the period module to scoring / companion / food / move.
// Per spec §4 and the period-intimacy plan §5.2, the bridge must never export dates, counts, raw HealthKit
// samples, symptom details, predicted dates, or inference confidence — only these coarse enums. The raw
// types (CycleDayEntry, MenstrualNarrative, CyclePrediction) are visible *to* the bridge; the bridge never
// re-exposes them.

/// Coarse strength of an abstract suggestion. Never a quantity.
enum PeriodSignalStrength: String, Equatable {
    case none, suggested
}

/// Abstract menstrual-cycle phase. Mirrors `CyclePhase` but is the *exported* type, kept distinct so raw
/// cycle types stay behind the boundary.
enum PeriodPhaseSignal: String, Equatable {
    case menstrual, follicular, ovulatory, luteal, unknown

    init(_ phase: CyclePhase) {
        switch phase {
        case .menstrual: self = .menstrual
        case .follicular: self = .follicular
        case .ovulatory: self = .ovulatory
        case .luteal: self = .luteal
        case .unknown: self = .unknown
        }
    }

    /// The label persisted on `DailyHealthScore.periodPhase`. `.unknown` persists `nil` so an unresolved
    /// or wiped cycle leaves no residue in the score record.
    var persistedLabel: String? { self == .unknown ? nil : rawValue }
}

/// Coarse position within the current cycle. No "days until" / "started N days ago" — just a band.
enum PeriodPhaseBand: String, Equatable {
    case menstruating, early, mid, late, unknown
}

/// Abstract nutrition hint — a kind plus a coarse strength, never a value. `.noData` when the cycle is
/// unknown or the sealed narratives that gauge symptom severity are unreadable (locked).
enum PeriodNutritionSignal: Equatable {
    case iron(PeriodSignalStrength)
    case complexCarbs(PeriodSignalStrength)
    case omega3(PeriodSignalStrength)
    case noData
}

/// Abstract exercise hint. `.noData` under the same conditions as `PeriodNutritionSignal`.
enum PeriodExerciseSignal: Equatable {
    case gentleness(PeriodSignalStrength)
    case strengthFriendly(PeriodSignalStrength)
    case noData
}

/// Pre-gated, abstract directive handed to the scoring engine. Carries the resolved phase (for the audit
/// label only) plus two coarse strengths — never a date, count, or confidence value. `.none` is the
/// identity: with it, scoring is byte-identical to the period-unaware result.
struct PeriodScoringAdjustment: Equatable {
    var phase: PeriodPhaseSignal
    var hydrationRelief: PeriodSignalStrength
    var leniency: PeriodSignalStrength

    static let none = PeriodScoringAdjustment(phase: .unknown, hydrationRelief: .none, leniency: .none)

    var softensScoring: Bool { hydrationRelief == .suggested || leniency == .suggested }
}

/// Non-sensitive per-day wellbeing component scores supplied *into* the period module by `FernletStore` so
/// the trend engine can correlate them against cycle phase. This flows inward only — the corresponding
/// outward flow is the abstract `PeriodHealthTrend`, never these raw values.
struct PeriodWellbeingSample: Equatable {
    var sleep: Double?
    var mood: Double?
    var exercise: Double?
    var nutrition: Double?
}

/// The read-only seam the scoring engine consults. `FernletStore` holds one of these (defaulting to nil →
/// no period awareness) and never sees the concrete bridge or any raw cycle type.
@MainActor
protocol PeriodScoringContextProviding: AnyObject {
    func scoringAdjustment(forDayKey dayKey: String) -> PeriodScoringAdjustment
}

/// The minimal live read surface the bridge needs from the period store. Keeping it a protocol decouples
/// the bridge from `PeriodTrackerStore`'s Core Data / HealthKit dependencies (and lets tests drive it with
/// a trivial fake, with no Core Data).
@MainActor
protocol PeriodContextSource: AnyObject {
    var entries: [CycleDayEntry] { get }
    var prediction: CyclePrediction? { get }
}

extension PeriodTrackerStore: PeriodContextSource {}

// MARK: - Phase resolution (pure calendar math)

/// Resolves a cycle phase for a given day from observed flow plus calendar-math prediction. Today the app
/// only ever observes `.menstrual`/`.unknown`; this fills in follicular/ovulatory/luteal using the standard
/// "luteal phase ≈ 14 days, ovulation ≈ cycleLength − 14" model anchored on detected period starts. Pure
/// and deterministic — no persistence, no AI.
enum CyclePhaseResolver {
    private static let menstrualWindow = 5
    private static let lutealLength = 14

    static func phase(
        on date: Date,
        entries: [CycleDayEntry],
        prediction: CyclePrediction?,
        calendar: Calendar = .current
    ) -> CyclePhase {
        // 1) An observed flow day always wins (highest precedence).
        if hasObservedFlow(on: date, entries: entries, calendar: calendar) { return .menstrual }
        // 2) Without a prediction we can't derive the non-bleeding phases (the 3-cycle floor).
        guard let prediction else { return .unknown }

        let starts = CyclePredictionEngine.detectedPeriodStarts(from: entries, calendar: calendar)
        let day = calendar.startOfDay(for: date)
        guard let lastStart = starts
            .map({ calendar.startOfDay(for: $0) })
            .filter({ $0 <= day })
            .max()
        else { return .unknown }

        let cycleDay = calendar.dateComponents([.day], from: lastStart, to: day).day ?? 0
        let length = max(16, prediction.predictedCycleLength)
        let buffer = max(2, prediction.variationDays)
        // Stale: more than a full (over-due) cycle past the anchor with no new start → can't place it.
        guard cycleDay >= 0, cycleDay <= length + buffer else { return .unknown }

        let ovulation = max(menstrualWindow + 2, length - lutealLength)
        if cycleDay < menstrualWindow { return .menstrual }
        if cycleDay < ovulation - 1 { return .follicular }
        if cycleDay <= ovulation + 1 { return .ovulatory }
        return .luteal
    }

    static func band(for phase: CyclePhase) -> PeriodPhaseBand {
        switch phase {
        case .menstrual: .menstruating
        case .follicular: .early
        case .ovulatory: .mid
        case .luteal: .late
        case .unknown: .unknown
        }
    }

    private static func hasObservedFlow(on date: Date, entries: [CycleDayEntry], calendar: Calendar) -> Bool {
        let key = FernletDate.dayKey(for: date)
        guard let entry = entries.first(where: { $0.dateKey == key }) else { return false }
        return entry.menstrualFlowSamples.contains { sample in
            guard let flow = HKCategoryValueVaginalBleeding(rawValue: sample.value) else { return false }
            return flow != .none
        }
    }
}

// MARK: - Bridge

/// The single read-only path from private cycle data to scoring / companion / food / move suggestions.
/// Recomputes every signal on demand from the live `PeriodTrackerStore` (no independent caching), so
/// deleting period data immediately makes outputs return `.unknown`/`.noData` — the "deliberate
/// forgetfulness" the spec requires.
///
/// Degradation:
/// - **< 3 cycles or locked** (`prediction == nil`): only observed flow can place the user, so phase is
///   `.menstrual`/`.unknown`, band follows, and nutrition/exercise are `.noData`. No scoring softening.
/// - **Unlocked, ≥ 3 cycles**: full phase/band + phase-appropriate nutrition/exercise hints, and scoring
///   softening on phases the per-phase trends mark as historically harder (medium/high confidence only).
@MainActor
@Observable
final class PeriodContextBridge: PeriodScoringContextProviding {
    /// Phase-aware behaviour (non-bleeding phases, signals, softening) only turns on after this many
    /// *completed* cycles, per spec §4 / plan §3.5. `CyclePrediction.cyclesObserved` counts period starts,
    /// so a completed cycle is `cyclesObserved - 1`.
    private static let minimumCompletedCycles = 3

    @ObservationIgnored private weak var source: (any PeriodContextSource)?
    @ObservationIgnored private let calendar: Calendar
    private var unlocked = false
    private(set) var trends: [PeriodHealthTrend] = []

    init(source: any PeriodContextSource, calendar: Calendar = .current) {
        self.source = source
        self.calendar = calendar
    }

    /// The prediction, but only once enough *completed* cycles exist to drive phase-aware behaviour.
    /// Below the threshold this is nil, so the bridge degrades to observed-flow-only (the 3-cycle gate).
    private var activePrediction: CyclePrediction? {
        guard let prediction = source?.prediction,
              prediction.cyclesObserved - 1 >= Self.minimumCompletedCycles else { return nil }
        return prediction
    }

    /// Recompute per-phase trends from current entries + the wellbeing scores supplied by `FernletStore`.
    /// Cheap and idempotent; call after period data, lock state, or daily scores change. Not persisted.
    func refresh(unlocked: Bool, wellbeingByDay: [String: PeriodWellbeingSample]) {
        self.unlocked = unlocked
        guard let source, let prediction = activePrediction else {
            trends = []
            return
        }
        let observations = buildObservations(
            entries: source.entries,
            prediction: prediction,
            wellbeingByDay: wellbeingByDay
        )
        trends = PeriodPhaseTrendEngine.trends(from: observations, completedCycles: prediction.cyclesObserved - 1)
    }

    // MARK: Abstract egress

    func currentPhaseSignal() -> PeriodPhaseSignal { PeriodPhaseSignal(resolvedPhase(on: Date())) }

    func currentPhaseBand() -> PeriodPhaseBand { CyclePhaseResolver.band(for: resolvedPhase(on: Date())) }

    func nutritionSignal() -> PeriodNutritionSignal {
        // Nutrition strength depends on user-marked symptom severity, which is sealed — `.noData` if locked.
        guard unlocked else { return .noData }
        switch resolvedPhase(on: Date()) {
        case .menstrual: return .iron(.suggested)
        case .luteal: return .complexCarbs(.suggested)
        case .follicular, .ovulatory: return .omega3(.suggested)
        case .unknown: return .noData
        }
    }

    func exerciseSignal() -> PeriodExerciseSignal {
        guard unlocked else { return .noData }
        switch resolvedPhase(on: Date()) {
        case .menstrual, .luteal: return .gentleness(.suggested)
        case .follicular, .ovulatory: return .strengthFriendly(.suggested)
        case .unknown: return .noData
        }
    }

    /// The current per-phase trends, exposed for an in-app (already-unlocked) trends surface. Abstract only.
    var currentTrends: [PeriodHealthTrend] { trends }

    // MARK: Scoring egress

    func scoringAdjustment(forDayKey dayKey: String) -> PeriodScoringAdjustment {
        guard let source, let prediction = activePrediction,
              let date = FernletDate.date(fromDayKey: dayKey) else { return .none }
        let phase = CyclePhaseResolver.phase(on: date, entries: source.entries, prediction: prediction, calendar: calendar)
        guard phase != .unknown else { return .none }
        // The phase label is always carried (for the audit field); softening is gated to historically
        // harder phases at medium/high confidence.
        let strength: PeriodSignalStrength = isHistoricallyHard(phase) ? .suggested : .none
        return PeriodScoringAdjustment(
            phase: PeriodPhaseSignal(phase),
            hydrationRelief: strength,
            leniency: strength
        )
    }

    // MARK: Internals

    private func resolvedPhase(on date: Date) -> CyclePhase {
        guard let source else { return .unknown }
        // `activePrediction` is nil when locked or below the 3-completed-cycle gate; the resolver then
        // places the user only from observed flow (.menstrual / .unknown).
        return CyclePhaseResolver.phase(on: date, entries: source.entries, prediction: activePrediction, calendar: calendar)
    }

    /// A phase is "historically hard" for this user when a medium/high-confidence trend shows worse sleep,
    /// worse mood, or higher symptom load in that phase versus the user's own baseline.
    private func isHistoricallyHard(_ phase: CyclePhase) -> Bool {
        trends.contains { trend in
            trend.phase == phase
                && trend.direction == .worse
                && trend.confidence >= .medium
                && (trend.metric == .sleep || trend.metric == .mood || trend.metric == .symptomLoad)
        }
    }

    private func buildObservations(
        entries: [CycleDayEntry],
        prediction: CyclePrediction,
        wellbeingByDay: [String: PeriodWellbeingSample]
    ) -> [PeriodPhaseTrendEngine.DayObservation] {
        entries.compactMap { entry in
            let phase = CyclePhaseResolver.phase(on: entry.date, entries: entries, prediction: prediction, calendar: calendar)
            guard phase != .unknown else { return nil }
            let wellbeing = wellbeingByDay[entry.dateKey]
            let symptomLoad = entry.narrative.map { Double($0.symptomFlags.count) / Double(PeriodSymptom.allCases.count) }
            guard wellbeing != nil || symptomLoad != nil else { return nil }
            return PeriodPhaseTrendEngine.DayObservation(
                phase: phase,
                sleep: wellbeing?.sleep,
                mood: wellbeing?.mood,
                exercise: wellbeing?.exercise,
                nutrition: wellbeing?.nutrition,
                symptomLoad: symptomLoad
            )
        }
    }
}
