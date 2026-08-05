//
//  FeelingTagMoodScale.swift
//  Fernlet
//
//  Shared FeelingTag → mood-score scale for the deterministic derived engines.
//

import FernletDomainModel

/// The single `FeelingTag` → mood-score table shared by the deterministic derived engines,
/// replacing the two previously duplicated private copies.
extension FeelingTag {
    /// Fixed 0.2–1.0 mood scale shared by `DerivedSignalFactory` and `TierTwoMemoryEngine`.
    var moodScore: Double {
        switch self {
        case .bright: 1
        case .good: 0.85
        case .neutral: 0.65
        case .quiet: 0.55
        case .tired: 0.35
        case .hard: 0.2
        }
    }
}
