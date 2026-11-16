//
//  TierTwoLearning.swift
//  LocalPersistence
//
//  G9-3 memory controls: what the Tier-2 engine may learn from.
//

import Foundation
import FernletFoundation
import FernletDomainModel

/// What a Tier-2 refresh may learn from (G9-3, owner calls M2 = A and M3 = A), read from the synced
/// settings: whether "Let Fernlet remember" is on, and the first day patterns may come from.
///
/// ``TierTwoMemoryStore/refresh(from:goals:travel:learning:)`` applies it: switched off, the refresh
/// deletes the store instead of writing (patterns are not worked out at all); with a learn-from day,
/// only days on or after it reach the engine (travel days too), and a record first seen before that
/// day is dropped, so "Forget patterns" cannot be undone by the next save rebuilding from history.
/// A plain value, nonisolated and `Sendable`, so the app's refresher can carry it across.
public nonisolated struct TierTwoLearning: Equatable, Sendable {
    /// Whether patterns may be worked out at all ("Let Fernlet remember").
    public var enabled: Bool
    /// The first `yyyy-MM-dd` day patterns may learn from; nil learns from every day.
    public var learnFrom: String?

    /// Learn from everything: the default for callers that predate G9-3.
    public static let everything = TierTwoLearning(enabled: true, learnFrom: nil)

    /// A learning value from its two parts.
    public init(enabled: Bool, learnFrom: String?) {
        self.enabled = enabled
        self.learnFrom = learnFrom
    }

    /// The learning the synced settings ask for.
    public init(settings: FernletSettings) {
        self.init(enabled: settings.memoryExtractionEnabled, learnFrom: settings.tierTwoLearnFrom)
    }

    /// `days` (oldest first) without the days before ``learnFrom``.
    public func learnableDays(_ days: [(String, FernletDay)]) -> [(String, FernletDay)] {
        guard let learnFrom else { return days }
        return days.filter { $0.0 >= learnFrom }
    }

    /// `travel` without the travel days before ``learnFrom``.
    public func learnableTravel(_ travel: TierTwoTravel) -> TierTwoTravel {
        guard let learnFrom else { return travel }
        return TierTwoTravel(days: travel.days.filter { $0.key >= learnFrom }, namesCities: travel.namesCities)
    }

    /// `records` without the ones first seen on a day before ``learnFrom``.
    public func learnableRecords(_ records: [TierTwoMemoryRecord]) -> [TierTwoMemoryRecord] {
        guard let learnFrom else { return records }
        return records.filter { FernletDate.dayKey(for: $0.extractedDate) >= learnFrom }
    }
}
