import Foundation

// MARK: - Abstract period-scoring signal vocabulary
//
// These are the abstract types the scoring engine consumes. The raw→abstract conversion
// (e.g. `PeriodPhaseSignal(_:CyclePhase)`) stays UP in the app layer (PeriodContextBridge),
// where the raw cycle types are visible; these signal types carry no dates, counts, or
// confidence — only coarse enums.

/// Coarse strength of an abstract suggestion. Never a quantity.
public enum PeriodSignalStrength: String, Equatable, Sendable {
    case none, suggested
}

/// Abstract menstrual-cycle phase. Mirrors `CyclePhase` but is the *exported* type, kept distinct so raw
/// cycle types stay behind the boundary. The raw→abstract initializer lives as an extension up in the app
/// layer (PeriodContextBridge), where `CyclePhase` is visible.
public enum PeriodPhaseSignal: String, Equatable, Sendable {
    case menstrual, follicular, ovulatory, luteal, unknown

    /// The label persisted on `DailyHealthScore.periodPhase`. `.unknown` persists `nil` so an unresolved
    /// or wiped cycle leaves no residue in the score record.
    public var persistedLabel: String? { self == .unknown ? nil : rawValue }
}

/// Pre-gated, abstract directive handed to the scoring engine. Carries the resolved phase (for the audit
/// label only) plus two coarse strengths — never a date, count, or confidence value. `.none` is the
/// identity: with it, scoring is byte-identical to the period-unaware result.
public struct PeriodScoringAdjustment: Equatable, Sendable {
    public var phase: PeriodPhaseSignal
    public var hydrationRelief: PeriodSignalStrength
    public var leniency: PeriodSignalStrength

    public init(phase: PeriodPhaseSignal, hydrationRelief: PeriodSignalStrength, leniency: PeriodSignalStrength) {
        self.phase = phase
        self.hydrationRelief = hydrationRelief
        self.leniency = leniency
    }

    public static let none = PeriodScoringAdjustment(phase: .unknown, hydrationRelief: .none, leniency: .none)

    public var softensScoring: Bool { hydrationRelief == .suggested || leniency == .suggested }
}
