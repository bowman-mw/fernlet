//
//  FernletSnapshot.swift
//  FernletPersistence
//
//  The persisted aggregate: one self-contained value type that the repositories
//  serialize to/from storage and that `FernletStore.apply` reads back into app
//  state. Extracted out of the app target's `LocalFernletRepository.swift` into
//  the nonisolated `FernletPersistence` module (SPM carve-up, plan §6).
//
//  The Codable shape (keys + decode-if-present defaults) is intentionally
//  byte-identical to the original so persisted JSON round-trips unchanged.
//

import Foundation
import FernletDomainModel

public struct FernletSnapshot: Codable {
    public var todayKey: String
    public var day: FernletDay
    public var settings: FernletSettings
    public var recentMeals: [Meal]
    public var previousJournals: [JournalEntry]
    public var memories: [MemoryNote]
    public var goals: [FitnessGoal]
    public var workshop: WorkshopData
    public var foodItems: [FoodItem] = []
    public var recipes: [RecipeDefinition] = []
    public var dailyScores: [DailyHealthScore] = []
    public var retryQueue: [AIAnalysisRetryRecord] = []
    public var connectionSessionLogs: [ConnectionSessionLog] = []
    public var trustedProximityPeers: [ProximityTrustedPeerRecord] = []
    public var trainerAuditEvents: [TrainerAuditEvent] = []

    public init(
        todayKey: String,
        day: FernletDay,
        settings: FernletSettings,
        recentMeals: [Meal],
        previousJournals: [JournalEntry],
        memories: [MemoryNote],
        goals: [FitnessGoal],
        workshop: WorkshopData,
        foodItems: [FoodItem] = [],
        recipes: [RecipeDefinition] = [],
        dailyScores: [DailyHealthScore] = [],
        retryQueue: [AIAnalysisRetryRecord] = [],
        connectionSessionLogs: [ConnectionSessionLog] = [],
        trustedProximityPeers: [ProximityTrustedPeerRecord] = [],
        trainerAuditEvents: [TrainerAuditEvent] = []
    ) {
        self.todayKey = todayKey
        self.day = day
        self.settings = settings
        self.recentMeals = recentMeals
        self.previousJournals = previousJournals
        self.memories = memories
        self.goals = goals
        self.workshop = workshop
        self.foodItems = foodItems
        self.recipes = recipes
        self.dailyScores = dailyScores
        self.retryQueue = retryQueue
        self.connectionSessionLogs = connectionSessionLogs
        self.trustedProximityPeers = trustedProximityPeers
        self.trainerAuditEvents = trainerAuditEvents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        todayKey = try container.decode(String.self, forKey: .todayKey)
        day = try container.decode(FernletDay.self, forKey: .day)
        settings = try container.decode(FernletSettings.self, forKey: .settings)
        recentMeals = try container.decode([Meal].self, forKey: .recentMeals)
        previousJournals = try container.decode([JournalEntry].self, forKey: .previousJournals)
        memories = try container.decode([MemoryNote].self, forKey: .memories)
        goals = try container.decode([FitnessGoal].self, forKey: .goals)
        workshop = try container.decode(WorkshopData.self, forKey: .workshop)
        foodItems = try container.decodeIfPresent([FoodItem].self, forKey: .foodItems) ?? []
        recipes = try container.decodeIfPresent([RecipeDefinition].self, forKey: .recipes) ?? []
        dailyScores = try container.decodeIfPresent([DailyHealthScore].self, forKey: .dailyScores) ?? []
        retryQueue = try container.decodeIfPresent([AIAnalysisRetryRecord].self, forKey: .retryQueue) ?? []
        connectionSessionLogs = try container.decodeIfPresent([ConnectionSessionLog].self, forKey: .connectionSessionLogs) ?? []
        trustedProximityPeers = try container.decodeIfPresent([ProximityTrustedPeerRecord].self, forKey: .trustedProximityPeers) ?? []
        trainerAuditEvents = try container.decodeIfPresent([TrainerAuditEvent].self, forKey: .trainerAuditEvents) ?? []
    }
}

// MARK: - Storage sanitization (privacy wall)

private extension FernletDay {
    /// The shared per-day storage strip: blanks sealed-journal text and nils sensitive health fields
    /// (cycle/intimate). Factored out so `SanitizedSnapshot` (today's day) and `SanitizedDay` (a past
    /// day) apply byte-identical privacy-wall behavior and cannot drift.
    func stripped(sealedJournalIDs: Set<UUID>) -> FernletDay {
        var stripped = self
        stripped.journals = journals.map { $0.strippedIfSealed(in: sealedJournalIDs) }
        if var context = stripped.healthContext {
            context.cycle = nil
            context.intimate = nil
            stripped.healthContext = context
        }
        return stripped
    }
}

/// A `FernletSnapshot` that has passed the storage privacy strip. The repository write boundary
/// (`FernletRepository.saveSnapshot`) requires THIS type rather than a raw `FernletSnapshot`, so an
/// un-stripped snapshot can never reach the (potentially iCloud-synced) blob by accident. The only way
/// to mint one is `sanitizing(_:sealedJournalIDs:)` (or `FernletSnapshot.forStorage`), both of which
/// apply the strip — the data-side analogue of the compiler import-wall.
public struct SanitizedSnapshot {
    public let snapshot: FernletSnapshot
    private init(_ snapshot: FernletSnapshot) { self.snapshot = snapshot }

    /// Applies the storage strip and wraps the result: blanks sealed-journal text (today + previous
    /// journals), nils sensitive health fields (cycle/intimate), and strips cycle-derived `periodPhase`
    /// from daily scores. `sealedJournalIDs` is the set of sealed journal entry ids (sealing state lives
    /// in the app, passed in as pure data).
    public static func sanitizing(_ snapshot: FernletSnapshot, sealedJournalIDs: Set<UUID>) -> SanitizedSnapshot {
        var stripped = snapshot
        stripped.day = snapshot.day.stripped(sealedJournalIDs: sealedJournalIDs)
        stripped.previousJournals = snapshot.previousJournals.map { $0.strippedIfSealed(in: sealedJournalIDs) }
        stripped.dailyScores = FernletSnapshot.storedDailyScores(snapshot.dailyScores)
        return SanitizedSnapshot(stripped)
    }

    /// The already-stripped today `day`, re-wrapped as a `SanitizedDay` so a per-row day write can reuse
    /// the same sanitize barrier as the blob write WITHOUT re-stripping (the snapshot's `day` was stripped
    /// when this `SanitizedSnapshot` was minted). Lets `saveSnapshot` mint a `DayRecordUpsert` through the
    /// `SanitizedDay` boundary instead of handing a raw `FernletDay` to the synced row store.
    public var sanitizedDay: SanitizedDay { SanitizedDay.presanitized(snapshot.day) }

    /// TEST-ONLY: wraps a snapshot WITHOUT stripping, for tests that verify raw repository serialization
    /// fidelity. Deliberately `internal` so it is reachable only via `@testable import FernletPersistence`
    /// and is invisible to production code in other modules (which see only the public `sanitizing` mint).
    static func uncheckedSanitizedForTesting(_ snapshot: FernletSnapshot) -> SanitizedSnapshot {
        SanitizedSnapshot(snapshot)
    }
}

/// A `FernletDay` that has passed the past-day storage strip — required by `FernletRepository.updateDay`
/// so a raw past-day write cannot leak sealed-journal text or sensitive health fields into the synced
/// blob. The only way to mint one is `sanitizing(_:sealedJournalIDs:)`.
public struct SanitizedDay {
    public let day: FernletDay
    private init(_ day: FernletDay) { self.day = day }

    /// Blanks sealed-journal text and nils sensitive health fields (cycle/intimate) on a single day.
    /// Hardens the former journal-text-only past-day strip to also drop cycle/intimate, matching
    /// `SanitizedSnapshot`.
    public static func sanitizing(_ day: FernletDay, sealedJournalIDs: Set<UUID>) -> SanitizedDay {
        SanitizedDay(day.stripped(sealedJournalIDs: sealedJournalIDs))
    }

    /// Wraps a day that has ALREADY been stripped upstream (e.g. `SanitizedSnapshot.snapshot.day`, which
    /// was stripped when its snapshot was minted). Applies no further strip — use ONLY when the day
    /// provably came out of an existing sanitize mint, so a per-row write can reuse the barrier without
    /// re-stripping. Never call this on a raw, app-sourced day.
    static func presanitized(_ day: FernletDay) -> SanitizedDay {
        SanitizedDay(day)
    }

    /// TEST-ONLY: wraps a day WITHOUT stripping (see `SanitizedSnapshot.uncheckedSanitizedForTesting`).
    /// `internal` — reachable only via `@testable import FernletPersistence`, never from production.
    static func uncheckedSanitizedForTesting(_ day: FernletDay) -> SanitizedDay {
        SanitizedDay(day)
    }
}

public extension FernletSnapshot {
    /// Builds a snapshot from its components and returns it already sanitized for cloud storage/sync —
    /// the convenience used by the app's snapshot producer. Equivalent to constructing a `FernletSnapshot`
    /// and calling `SanitizedSnapshot.sanitizing(_:sealedJournalIDs:)`.
    static func forStorage(
        todayKey: String, day: FernletDay, settings: FernletSettings, recentMeals: [Meal],
        previousJournals: [JournalEntry], memories: [MemoryNote], goals: [FitnessGoal],
        workshop: WorkshopData, foodItems: [FoodItem], recipes: [RecipeDefinition],
        dailyScores: [DailyHealthScore], retryQueue: [AIAnalysisRetryRecord],
        connectionSessionLogs: [ConnectionSessionLog], trustedProximityPeers: [ProximityTrustedPeerRecord],
        trainerAuditEvents: [TrainerAuditEvent], sealedJournalIDs: Set<UUID>
    ) -> SanitizedSnapshot {
        let raw = FernletSnapshot(
            todayKey: todayKey, day: day, settings: settings, recentMeals: recentMeals,
            previousJournals: previousJournals, memories: memories, goals: goals,
            workshop: workshop, foodItems: foodItems, recipes: recipes,
            dailyScores: dailyScores, retryQueue: retryQueue,
            connectionSessionLogs: connectionSessionLogs, trustedProximityPeers: trustedProximityPeers,
            trainerAuditEvents: trainerAuditEvents
        )
        return SanitizedSnapshot.sanitizing(raw, sealedJournalIDs: sealedJournalIDs)
    }

    /// Strips `DailyHealthScore.periodPhase` (cycle-derived) from every score. Pure.
    static func storedDailyScores(_ scores: [DailyHealthScore]) -> [DailyHealthScore] {
        scores.map { score in
            guard score.periodPhase != nil else { return score }
            var s = score; s.periodPhase = nil; return s
        }
    }
}
