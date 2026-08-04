import Foundation

// MARK: - Abstract period-scoring signal vocabulary
//
// These are the abstract types the scoring engine consumes. The raw→abstract conversion
// (e.g. `PeriodPhaseSignal(_:CyclePhase)`) stays UP in the `PeriodContextBridge` module,
// where the raw cycle types are visible; these signal types carry no dates, counts, or
// confidence — only coarse enums.

/// Coarse strength of an abstract suggestion. Never a quantity.
///
/// The deliberately tiny vocabulary (`none`/`suggested`) is the point: the scoring engine can be
/// told "soften here" without ever learning a date, a count, or a confidence value from the sealed
/// cycle store. `ScoringWeights.adjustedForPeriod(_:)` and the hydration-relief branch of
/// ``FernletScoring/FernletScoring``'s `computeBreakdown` both treat `.none` as the identity.
public enum PeriodSignalStrength: String, Equatable, Sendable {
    case none, suggested
}

/// Abstract menstrual-cycle phase — the *exported* mirror of the sealed `CyclePhase`.
///
/// Kept distinct from `CyclePhase` (PrivateHealthStore) so raw cycle types stay behind the S3
/// boundary: this module never imports the sealed store, and the raw→abstract initializer lives as
/// an extension up in `PeriodContextBridge`, where `CyclePhase` is visible. Scoring only ever sees a
/// phase inside a ``PeriodScoringAdjustment``, and there only as an audit label.
public enum PeriodPhaseSignal: String, Equatable, Sendable {
    case menstrual, follicular, ovulatory, luteal, unknown

    /// The label persisted on `DailyHealthScore.periodPhase`. `.unknown` persists `nil` so an unresolved
    /// or wiped cycle leaves no residue in the score record.
    public var persistedLabel: String? { self == .unknown ? nil : rawValue }
}

/// Pre-gated, abstract directive handed to the scoring engine. Carries the resolved phase (for the audit
/// label only) plus two coarse strengths — never a date, count, or confidence value. `.none` is the
/// identity: with it, scoring is byte-identical to the period-unaware result.
///
/// This is the ONLY sanctioned scoring egress for cycle data. `PeriodContextBridge` builds it —
/// already gated on the user's period-feature settings, so scoring never re-checks them — and the
/// store's injected `periodAdjustment` closure hands it to ``FernletScoring/FernletScoring``'s
/// `computeBreakdown`, where ``leniency`` shifts a small slice of the workout weight toward
/// restorative sleep/hydration and ``hydrationRelief`` softens the bottle target. A pure `Sendable`
/// value with no reference to any sealed type; only ``phase``'s `persistedLabel` ever reaches a
/// persisted record.
public struct PeriodScoringAdjustment: Equatable, Sendable {
    /// The resolved abstract phase — used only for the persisted audit label, never for arithmetic.
    public var phase: PeriodPhaseSignal
    /// When `.suggested`, the day's hydration bottle target is softened (×0.85).
    public var hydrationRelief: PeriodSignalStrength
    /// When `.suggested`, 30% of the workout weight shifts toward restorative sleep/hydration.
    public var leniency: PeriodSignalStrength

    public init(phase: PeriodPhaseSignal, hydrationRelief: PeriodSignalStrength, leniency: PeriodSignalStrength) {
        self.phase = phase
        self.hydrationRelief = hydrationRelief
        self.leniency = leniency
    }

    /// The identity adjustment: unknown phase, no relief, no leniency — scoring is unchanged.
    public static let none = PeriodScoringAdjustment(phase: .unknown, hydrationRelief: .none, leniency: .none)

    /// True when either strength is `.suggested` — i.e. the adjustment actually changes the score.
    public var softensScoring: Bool { hydrationRelief == .suggested || leniency == .suggested }
}
