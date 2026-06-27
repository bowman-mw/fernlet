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

public extension FernletSnapshot {
    /// The ONLY sanctioned way to build a snapshot destined for cloud storage/sync.
    /// Strips sealed-journal text + sensitive health fields (cycle/intimacy/periodPhase)
    /// so they never reach the synced blob. `sealedJournalIDs` is the set of sealed
    /// journal entry ids (the sealing state lives in the app, passed in as pure data).
    static func forStorage(
        todayKey: String, day: FernletDay, settings: FernletSettings, recentMeals: [Meal],
        previousJournals: [JournalEntry], memories: [MemoryNote], goals: [FitnessGoal],
        workshop: WorkshopData, foodItems: [FoodItem], recipes: [RecipeDefinition],
        dailyScores: [DailyHealthScore], retryQueue: [AIAnalysisRetryRecord],
        connectionSessionLogs: [ConnectionSessionLog], trustedProximityPeers: [ProximityTrustedPeerRecord],
        trainerAuditEvents: [TrainerAuditEvent], sealedJournalIDs: Set<UUID>
    ) -> FernletSnapshot {
        func stripJournal(_ entry: JournalEntry) -> JournalEntry {
            guard sealedJournalIDs.contains(entry.id) else { return entry }
            return JournalEntry(id: entry.id, text: "", tag: entry.tag, date: entry.date, emotions: [])
        }
        var strippedDay = day
        strippedDay.journals = day.journals.map(stripJournal)
        if var context = strippedDay.healthContext {
            context.cycle = nil
            context.intimate = nil
            strippedDay.healthContext = context
        }
        return FernletSnapshot(
            todayKey: todayKey, day: strippedDay, settings: settings, recentMeals: recentMeals,
            previousJournals: previousJournals.map(stripJournal), memories: memories, goals: goals,
            workshop: workshop, foodItems: foodItems, recipes: recipes,
            dailyScores: storedDailyScores(dailyScores), retryQueue: retryQueue,
            connectionSessionLogs: connectionSessionLogs, trustedProximityPeers: trustedProximityPeers,
            trainerAuditEvents: trainerAuditEvents
        )
    }

    /// Strips `DailyHealthScore.periodPhase` (cycle-derived) from every score. Pure.
    static func storedDailyScores(_ scores: [DailyHealthScore]) -> [DailyHealthScore] {
        scores.map { score in
            guard score.periodPhase != nil else { return score }
            var s = score; s.periodPhase = nil; return s
        }
    }
}
