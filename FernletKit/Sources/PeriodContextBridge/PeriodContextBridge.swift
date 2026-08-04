import Foundation
import FernletFoundation
import HealthKit
import Observation
import FernletDomainModel
import FernletScoring
import PrivateHealthStore

// MARK: - Abstract egress vocabulary
//
// These are the ONLY types that may cross out of the period module to scoring / companion / food / move.
// Per spec §4 and the period-intimacy plan §5.2, the bridge must never export dates, counts, raw HealthKit
// samples, symptom details, predicted dates, or inference confidence — only these coarse enums. The raw
// types (CycleDayEntry, MenstrualNarrative, CyclePrediction) are visible *to* the bridge; the bridge never
// re-exposes them.

// `PeriodSignalStrength`, `PeriodPhaseSignal`, and `PeriodScoringAdjustment` now live in `FernletScoring`
// (the scoring layer consumes them). Only the raw→abstract conversion stays here, where `CyclePhase` (a
// raw cycle type that must not cross down into scoring) is visible.
nonisolated extension PeriodPhaseSignal {
    /// Converts the raw sealed `CyclePhase` into the abstract exported signal, case for case.
    ///
    /// This initializer lives here rather than in `FernletScoring` (where `PeriodPhaseSignal` is
    /// declared) because `CyclePhase` (PrivateHealthStore) must never be nameable below the bridge.
    public init(_ phase: CyclePhase) {
        switch phase {
        case .menstrual: self = .menstrual
        case .follicular: self = .follicular
        case .ovulatory: self = .ovulatory
        case .luteal: self = .luteal
        case .unknown: self = .unknown
        }
    }
}

/// Coarse position within the current cycle. No "days until" / "started N days ago" — just a band.
///
/// Part of the abstract egress vocabulary: companion/food/move surfaces consume this instead of a
/// raw `CyclePhase`, so no date arithmetic can be reconstructed downstream. Produced by
/// ``CyclePhaseResolver/band(for:)`` and read via ``PeriodContextBridge/currentPhaseBand()``.
public nonisolated enum PeriodPhaseBand: String, Equatable {
    case menstruating, early, mid, late, unknown
}

/// Abstract nutrition hint — a kind plus a coarse strength, never a value.
///
/// `.noData` when the cycle is unknown or the sealed narratives that gauge symptom severity are
/// unreadable (locked). Emitted by ``PeriodContextBridge/nutritionSignal()`` for the food surface;
/// the strength is a `PeriodSignalStrength` (FernletScoring), so no quantity ever crosses out.
public nonisolated enum PeriodNutritionSignal: Equatable {
    case iron(PeriodSignalStrength)
    case complexCarbs(PeriodSignalStrength)
    case omega3(PeriodSignalStrength)
    case noData
}

/// Abstract exercise hint — gentleness versus strength-friendliness, never a prescription.
///
/// `.noData` under the same conditions as ``PeriodNutritionSignal`` (locked, or the phase is
/// unresolved). Emitted by ``PeriodContextBridge/exerciseSignal()`` for the movement surface.
public nonisolated enum PeriodExerciseSignal: Equatable {
    case gentleness(PeriodSignalStrength)
    case strengthFriendly(PeriodSignalStrength)
    case noData
}

/// Non-sensitive per-day wellbeing component scores supplied *into* the period module by `FernletStore`.
///
/// ``PeriodPhaseTrendEngine`` correlates these against cycle phase. This flows inward only — the
/// corresponding outward flow is the abstract ``PeriodHealthTrend``, never these raw values. Every
/// field is an optional 0–1 component score; a missing metric simply drops that day from the
/// metric's sample rather than counting as zero.
public nonisolated struct PeriodWellbeingSample: Equatable {
    public var sleep: Double?
    public var mood: Double?
    public var exercise: Double?
    public var nutrition: Double?

    public init(sleep: Double? = nil, mood: Double? = nil, exercise: Double? = nil, nutrition: Double? = nil) {
        self.sleep = sleep
        self.mood = mood
        self.exercise = exercise
        self.nutrition = nutrition
    }
}

/// The read-only seam the scoring engine consults for period-aware adjustments.
///
/// `FernletStore` holds one of these (defaulting to nil → no period awareness) and never sees the
/// concrete bridge or any raw cycle type; `ContentView` wires the concrete ``PeriodContextBridge``
/// via `attachPeriodScoringContext`. The store's `periodAdjustment(for:)` applies the user's opt-in
/// setting *before* consulting this seam, so a conformer only ever answers for an opted-in user —
/// the 3-cycle and confidence gates are the conformer's own job. `@MainActor`: called synchronously
/// from the main-actor scoring path.
@MainActor
public protocol PeriodScoringContextProviding: AnyObject {
    /// The abstract scoring adjustment for the day identified by the canonical `"yyyy-MM-dd"` key,
    /// or `.none` (the identity) when the day's phase cannot be resolved.
    func scoringAdjustment(forDayKey dayKey: String) -> PeriodScoringAdjustment
}

/// The minimal live read surface the bridge needs from the period store.
///
/// Keeping it a protocol decouples the bridge from `PeriodTrackerStore`'s Core Data / HealthKit
/// dependencies (and lets tests drive it with a trivial fake, with no Core Data). The bridge holds
/// it `weak` and re-reads both properties live on every query, so a deletion in the source shows up
/// on the very next read.
@MainActor
public protocol PeriodContextSource: AnyObject {
    /// The current cycle log, one entry per logged day. A raw sealed type — visible *to* the bridge,
    /// never re-exported by it.
    var entries: [CycleDayEntry] { get }
    /// The current calendar-math prediction, or nil while locked or below the store's own
    /// observation floor. Nil disables every non-observed phase downstream.
    var prediction: CyclePrediction? { get }
}

/// `PeriodTrackerStore` is the production conformer; the bridge only ever sees it through the seam.
extension PeriodTrackerStore: PeriodContextSource {}

// MARK: - Phase resolution (pure calendar math)

/// Resolves a cycle phase for a given day from observed flow plus calendar-math prediction.
///
/// Today the app only ever observes `.menstrual`/`.unknown`; this fills in
/// follicular/ovulatory/luteal using the standard "luteal phase ≈ 14 days, ovulation ≈
/// cycleLength − 14" model anchored on detected period starts. Pure and deterministic — no
/// persistence, no AI. Precedence is fixed: an observed bleeding day always wins; calendar math
/// places non-bleeding days only while a prediction exists and the day sits within one (buffered)
/// cycle of the last detected start — anything else is `.unknown`. A namespace enum: all members
/// are static, and both ``PeriodContextBridge`` and its trend building call through here so every
/// consumer sees identical phase decisions.
public nonisolated enum CyclePhaseResolver {
    /// Assumed bleeding-window length in days for calendar-math placement (an observed flow day
    /// overrides this regardless of cycle day).
    private static let menstrualWindow = 5
    /// Assumed luteal-phase length in days — the "ovulation ≈ cycleLength − 14" half of the model.
    private static let lutealLength = 14

    /// Resolves the cycle phase for `date` — observed flow first, calendar math second.
    ///
    /// - Parameter date: Day to resolve, compared at the start-of-day granularity of `calendar`.
    /// - Parameter entries: Observed cycle log entries used to detect bleeding days and period starts.
    /// - Parameter prediction: Optional calendar-math prediction that supplies the cycle length context.
    /// - Parameter calendar: Calendar used for day bucketing and date arithmetic.
    /// - Parameter periodStarts: the detected period starts for `entries`, if the caller already has them
    ///   memoized. When `nil` they are recomputed from `entries` — passing them in is a pure performance
    ///   optimization and never changes the result (they must equal `detectedPeriodStarts(from: entries)`).
    ///   The observed-flow check (step 1) always reads `entries` live, so a memoized `periodStarts` can only
    ///   ever affect the calendar-math phases, never the "is today a bleeding day" decision.
    /// - Returns: The resolved phase, or `.unknown` when neither observed flow nor an in-window
    ///   prediction can place the day.
    public static func phase(
        on date: Date,
        entries: [CycleDayEntry],
        prediction: CyclePrediction?,
        calendar: Calendar = .current,
        periodStarts: [Date]? = nil
    ) -> CyclePhase {
        // 1) An observed flow day always wins (highest precedence).
        if hasObservedFlow(on: date, entries: entries, calendar: calendar) { return .menstrual }
        // 2) Without a prediction we can't derive the non-bleeding phases (the 3-cycle floor).
        guard let prediction else { return .unknown }

        let starts = periodStarts ?? CyclePredictionEngine.detectedPeriodStarts(from: entries, calendar: calendar)
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

    /// Collapses a raw phase to its coarse egress band (menstrual → `.menstruating`,
    /// follicular → `.early`, ovulatory → `.mid`, luteal → `.late`).
    public static func band(for phase: CyclePhase) -> PeriodPhaseBand {
        switch phase {
        case .menstrual: .menstruating
        case .follicular: .early
        case .ovulatory: .mid
        case .luteal: .late
        case .unknown: .unknown
        }
    }

    /// True when the entry for `date`'s day key carries any HealthKit bleeding sample above `.none`.
    /// Buckets the day via `FernletDate.dayKey`, matching how entries themselves are keyed.
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
///
/// Recomputes every signal on demand from the live `PeriodTrackerStore`, so deleting period data
/// immediately makes outputs return `.unknown`/`.noData` — the "deliberate forgetfulness" the spec requires.
/// This is the layer-4 "sanctioned egress" of the S3 wall: raw cycle types (`CycleDayEntry`,
/// `CyclePrediction`, `CyclePhase`) flow *in* through the ``PeriodContextSource`` seam and only the
/// abstract vocabulary (`PeriodScoringAdjustment`, ``PeriodPhaseBand``, ``PeriodNutritionSignal``,
/// ``PeriodExerciseSignal``, ``PeriodHealthTrend``) flows out. `ContentView` constructs it over the
/// period store and hands it to `FernletStore` as an `any` ``PeriodScoringContextProviding``; nothing
/// downstream ever holds the concrete type. `@MainActor` `@Observable`; holds `source` weakly;
/// persists nothing.
///
/// The one memo is `cachedPeriodStarts` (the detected period starts): scoring reads `score` ~12×/render and
/// each read would otherwise re-group up to 240 days of flow entries via `detectPeriods`. It is recomputed
/// lazily from `source.entries` and invalidated in `refresh()` — the same lifecycle that already rebuilds
/// `trends` on every mutation (launch / lock-change / delete / log-edit). The observed-flow check stays live
/// (it never consults the cache), so a wiped entry still resolves to `.unknown` on the very next read.
/// - Important: `refresh(unlocked:wellbeingByDay:)` is the ONLY invalidation point — every source
///   mutation and every lock-state change must be followed by a `refresh` call, or `scoringAdjustment`
///   keeps using memoized period starts and stale trends.
///
/// Degradation:
/// - **Locked** (source `prediction == nil` and `unlocked == false`): only observed flow can place the
///   user, so phase is `.menstrual`/`.unknown`, band follows, nutrition/exercise are `.noData`, and
///   there is no scoring softening.
///   (This is intentionally stricter than period-intimacy-plan §5.3, which would have non-bleeding phases
///   resolve while locked from HK alone; see that section's note. The lock is a "forget the cycle" gate.)
/// - **Unlocked, < 3 completed cycles** (`activePrediction == nil`): phase still degrades to
///   `.menstrual`/`.unknown` (observed flow only) and there is no scoring softening, but on an observed
///   bleeding day ``nutritionSignal()``/``exerciseSignal()`` DO emit the menstrual-phase hints — the
///   3-cycle gate withholds calendar-math inference, not direct observation.
/// - **Unlocked, ≥ 3 cycles**: full phase/band + phase-appropriate nutrition/exercise hints, and scoring
///   softening on phases the per-phase trends mark as historically harder (medium/high confidence only).
@MainActor
@Observable
public final class PeriodContextBridge: PeriodScoringContextProviding {
    /// Phase-aware behaviour (non-bleeding phases, signals, softening) only turns on after this many
    /// *completed* cycles, per spec §4 / plan §3.5. `CyclePrediction.cyclesObserved` counts period starts,
    /// so a completed cycle is `cyclesObserved - 1`.
    private static let minimumCompletedCycles = 3

    /// The live period store, held weakly through the ``PeriodContextSource`` seam. When it
    /// deallocates, every output degrades to `.unknown`/`.noData`/`.none`.
    @ObservationIgnored private weak var source: (any PeriodContextSource)?
    /// Calendar for all day bucketing and cycle-day arithmetic (`.current` in the app; injectable
    /// for deterministic tests).
    @ObservationIgnored private let calendar: Calendar
    /// The lock state last pushed via ``refresh(unlocked:wellbeingByDay:)``. Fail-closed default:
    /// `false` until the app says otherwise, which keeps the symptom-severity-dependent
    /// nutrition/exercise signals at `.noData`.
    private var unlocked = false
    /// Per-phase trends computed by the last ``refresh(unlocked:wellbeingByDay:)``. Empty while
    /// locked or below the 3-completed-cycle gate; observed (not `@ObservationIgnored`) so the
    /// trends UI re-renders when they change.
    private(set) var trends: [PeriodHealthTrend] = []

    /// Memoized detected period starts for the current `source.entries`. Recomputed lazily and cleared in
    /// `refresh()`; see the type doc. `@ObservationIgnored` because it is a pure derived cache — mutating it
    /// during a read must not churn the view graph.
    @ObservationIgnored private var cachedPeriodStarts: [Date]?

    /// Creates a bridge over `source`. The source is held weakly; the caller (in the app,
    /// `ContentView`) owns both and is responsible for driving ``refresh(unlocked:wellbeingByDay:)``.
    /// - Parameters:
    ///   - source: The live period store, seen only through the seam.
    ///   - calendar: Calendar for day bucketing and cycle arithmetic; defaults to `.current`.
    public init(source: any PeriodContextSource, calendar: Calendar = .current) {
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
    public func refresh(unlocked: Bool, wellbeingByDay: [String: PeriodWellbeingSample]) {
        self.unlocked = unlocked
        // Authoritative invalidation point: entries / lock / prediction just changed, so the memoized starts
        // must be rebuilt from the now-current entries before any phase or trend is recomputed.
        cachedPeriodStarts = nil
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

    /// Today's abstract phase signal — resolved live from the source and converted, never cached.
    public func currentPhaseSignal() -> PeriodPhaseSignal { PeriodPhaseSignal(resolvedPhase(on: Date())) }

    /// Today's coarse cycle band for companion/UI copy; same live resolution as ``currentPhaseSignal()``.
    public func currentPhaseBand() -> PeriodPhaseBand { CyclePhaseResolver.band(for: resolvedPhase(on: Date())) }

    /// Today's abstract nutrition hint for the food surface.
    /// - Returns: A phase-appropriate kind at `.suggested` strength, or `.noData` when locked or the
    ///   phase is unresolved.
    public func nutritionSignal() -> PeriodNutritionSignal {
        // Nutrition strength depends on user-marked symptom severity, which is sealed — `.noData` if locked.
        guard unlocked else { return .noData }
        switch resolvedPhase(on: Date()) {
        case .menstrual: return .iron(.suggested)
        case .luteal: return .complexCarbs(.suggested)
        case .follicular, .ovulatory: return .omega3(.suggested)
        case .unknown: return .noData
        }
    }

    /// Today's abstract exercise hint for the movement surface — gentleness in menstrual/luteal,
    /// strength-friendly in follicular/ovulatory.
    /// - Returns: `.noData` when locked or the phase is unresolved, mirroring ``nutritionSignal()``.
    public func exerciseSignal() -> PeriodExerciseSignal {
        guard unlocked else { return .noData }
        switch resolvedPhase(on: Date()) {
        case .menstrual, .luteal: return .gentleness(.suggested)
        case .follicular, .ovulatory: return .strengthFriendly(.suggested)
        case .unknown: return .noData
        }
    }

    /// The current per-phase trends, exposed for an in-app (already-unlocked) trends surface. Abstract only.
    public var currentTrends: [PeriodHealthTrend] { trends }

    // MARK: Scoring egress

    /// The abstract scoring adjustment for a day — the ``PeriodScoringContextProviding`` conformance.
    ///
    /// Resolves the day's phase from live entries plus the gated prediction, then softens only when
    /// the per-phase trends mark that phase historically harder at medium/high confidence. The phase
    /// label is always carried (for the persisted audit field) even when no softening applies.
    /// - Parameter dayKey: Canonical `"yyyy-MM-dd"` day key.
    /// - Returns: `.none` (the identity) when the source is gone, the 3-cycle gate is unmet, the key
    ///   doesn't parse, or the phase resolves `.unknown`.
    public func scoringAdjustment(forDayKey dayKey: String) -> PeriodScoringAdjustment {
        guard let source, let prediction = activePrediction,
              let date = FernletDate.date(fromDayKey: dayKey) else { return .none }
        let phase = CyclePhaseResolver.phase(
            on: date, entries: source.entries, prediction: prediction,
            calendar: calendar, periodStarts: periodStarts(for: source.entries)
        )
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

    /// Resolves `date`'s raw phase from the live source, honoring the 3-cycle/lock gate: with no
    /// active prediction the resolver can only report `.menstrual` (observed flow) or `.unknown`.
    private func resolvedPhase(on date: Date) -> CyclePhase {
        guard let source else { return .unknown }
        // `activePrediction` is nil when locked or below the 3-completed-cycle gate; the resolver then
        // places the user only from observed flow (.menstrual / .unknown) — no starts needed, so the memo
        // stays untouched in the degraded state.
        guard let prediction = activePrediction else {
            return CyclePhaseResolver.phase(on: date, entries: source.entries, prediction: nil, calendar: calendar)
        }
        return CyclePhaseResolver.phase(
            on: date, entries: source.entries, prediction: prediction,
            calendar: calendar, periodStarts: periodStarts(for: source.entries)
        )
    }

    /// Detected period starts for `entries`, memoized so the ~12 score reads per render don't each re-group
    /// up to 240 days of flow. The cache is cleared in `refresh()` (the single mutation lifecycle), so the
    /// `entries` passed here are always the post-mutation set — never a stale snapshot.
    private func periodStarts(for entries: [CycleDayEntry]) -> [Date] {
        if let cachedPeriodStarts { return cachedPeriodStarts }
        let starts = CyclePredictionEngine.detectedPeriodStarts(from: entries, calendar: calendar)
        cachedPeriodStarts = starts
        return starts
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

    /// Joins each logged cycle day with its wellbeing scores and sealed symptom load into the trend
    /// engine's per-day observations, dropping unknown-phase days and days carrying no signal at all.
    /// Symptom load is the fraction of `PeriodSymptom` cases flagged in the day's (decrypted) narrative.
    private func buildObservations(
        entries: [CycleDayEntry],
        prediction: CyclePrediction,
        wellbeingByDay: [String: PeriodWellbeingSample]
    ) -> [PeriodPhaseTrendEngine.DayObservation] {
        let starts = periodStarts(for: entries)
        return entries.compactMap { entry in
            let phase = CyclePhaseResolver.phase(
                on: entry.date, entries: entries, prediction: prediction,
                calendar: calendar, periodStarts: starts
            )
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
