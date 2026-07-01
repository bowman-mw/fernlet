//
//  LocalFernletRepository.swift
//  Fernlet
//
//  Created by Coding Assistant on 5/16/26.
//

import Foundation
import FernletFoundation
import FernletDomainModel
import FernletScoring
import FernletPersistence

public struct LocalFernletDatabase: Codable, @unchecked Sendable {
    public var schemaVersion = 1
    public var updatedAt = Date()
    public var days: [String: FernletDay] = [:]
    /// Per-store guard for the blob→per-row `DayRecord` migration (Core Data path). Lives in the store
    /// (not the keychain) so it shares the store's lifecycle: a data reset re-arms it, and any later
    /// build still lazily backfills rows from the blob until this is true — which is what makes retiring
    /// the blob's `days` safe.
    public var daysMigratedToRows = false
    /// Precomputed counts of day content, kept so iCloud "existing data" detection stays a single-record
    /// read once the Core Data path clears the blob's `days` cache (Stage B). Empty until populated; the
    /// local/no-iCloud path leaves it empty (it has no cloud detection).
    public var dayContentSummary = DayContentSummary()
    public var settings = FernletSettings()
    public var recentMeals: [Meal] = []
    public var previousJournals: [JournalEntry] = []
    public var memories: [MemoryNote] = []
    public var goals: [FitnessGoal] = []
    public var workshop = WorkshopData()
    public var dailyLogs: [DailyLogRecord] = []
    public var mealLogs: [MealLogRecord] = []
    public var workoutLogs: [WorkoutLogRecord] = []
    public var journalLogs: [JournalLogRecord] = []
    public var retryQueue: [AIAnalysisRetryRecord] = []
    public var tierTwoMemories: [TierTwoMemoryRecord] = []
    public var foodItems: [FoodItem] = []
    public var recipes: [RecipeDefinition] = []
    public var dailyScores: [DailyHealthScore] = []
    public var connectionSessionLogs: [ConnectionSessionLog] = []
    public var trustedProximityPeers: [ProximityTrustedPeerRecord] = []
    public var trainerAuditEvents: [TrainerAuditEvent] = []

    public init() {}

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        days = try container.decodeIfPresent([String: FernletDay].self, forKey: .days) ?? [:]
        daysMigratedToRows = try container.decodeIfPresent(Bool.self, forKey: .daysMigratedToRows) ?? false
        dayContentSummary = try container.decodeIfPresent(DayContentSummary.self, forKey: .dayContentSummary) ?? DayContentSummary()
        settings = try container.decodeIfPresent(FernletSettings.self, forKey: .settings) ?? FernletSettings()
        recentMeals = try container.decodeIfPresent([Meal].self, forKey: .recentMeals) ?? []
        previousJournals = try container.decodeIfPresent([JournalEntry].self, forKey: .previousJournals) ?? []
        memories = try container.decodeIfPresent([MemoryNote].self, forKey: .memories) ?? []
        goals = try container.decodeIfPresent([FitnessGoal].self, forKey: .goals) ?? []
        workshop = try container.decodeIfPresent(WorkshopData.self, forKey: .workshop) ?? WorkshopData()
        dailyLogs = try container.decodeIfPresent([DailyLogRecord].self, forKey: .dailyLogs) ?? []
        mealLogs = try container.decodeIfPresent([MealLogRecord].self, forKey: .mealLogs) ?? []
        workoutLogs = try container.decodeIfPresent([WorkoutLogRecord].self, forKey: .workoutLogs) ?? []
        journalLogs = try container.decodeIfPresent([JournalLogRecord].self, forKey: .journalLogs) ?? []
        retryQueue = try container.decodeIfPresent([AIAnalysisRetryRecord].self, forKey: .retryQueue) ?? []
        tierTwoMemories = try container.decodeIfPresent([TierTwoMemoryRecord].self, forKey: .tierTwoMemories) ?? []
        foodItems = try container.decodeIfPresent([FoodItem].self, forKey: .foodItems) ?? []
        recipes = try container.decodeIfPresent([RecipeDefinition].self, forKey: .recipes) ?? []
        dailyScores = try container.decodeIfPresent([DailyHealthScore].self, forKey: .dailyScores) ?? []
        connectionSessionLogs = try container.decodeIfPresent([ConnectionSessionLog].self, forKey: .connectionSessionLogs) ?? []
        trustedProximityPeers = try container.decodeIfPresent([ProximityTrustedPeerRecord].self, forKey: .trustedProximityPeers) ?? []
        trainerAuditEvents = try container.decodeIfPresent([TrainerAuditEvent].self, forKey: .trainerAuditEvents) ?? []
    }
}

public struct LocalFernletRepository: FernletRepository {
    private final class State {
        var persistenceBlockedByDecodeFailure = false
        var pendingLegacyCleanup = false
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let state = State()

    public init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        assert(!resolvedURL.path.isEmpty, "repository path must not be empty")
        self.fileURL = resolvedURL
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    public func loadSnapshot(todayKey: String) -> FernletSnapshot {
        assert(!todayKey.isEmpty, "today key required")
        let database = loadDatabase(todayKey: todayKey)
        let day = database.days[todayKey] ?? FernletDay(date: todayKey)
        return FernletSnapshot(
            todayKey: todayKey,
            day: day,
            settings: database.settings,
            recentMeals: database.recentMeals,
            previousJournals: database.previousJournals,
            memories: database.memories,
            goals: database.goals,
            workshop: database.workshop,
            foodItems: database.foodItems,
            recipes: database.recipes,
            dailyScores: database.dailyScores,
            retryQueue: database.retryQueue,
            connectionSessionLogs: database.connectionSessionLogs,
            trustedProximityPeers: database.trustedProximityPeers,
            trainerAuditEvents: database.trainerAuditEvents
        )
    }

    @discardableResult public func saveSnapshot(_ sanitized: SanitizedSnapshot) -> Bool {
        let snapshot = sanitized.snapshot
        assert(!snapshot.todayKey.isEmpty, "snapshot key required")
        var database = loadDatabase(todayKey: snapshot.todayKey)
        database.apply(snapshot)
        database.rebuildDerivedTables(todayKey: snapshot.todayKey)
        return saveDatabase(database)
    }

    @discardableResult public func updateDay(_ sanitized: SanitizedDay, for dateKey: String, todayKey: String) -> Bool {
        let day = sanitized.day
        assert(!dateKey.isEmpty, "date key required")
        assert(!todayKey.isEmpty, "today key required")
        assert(day.date == dateKey, "day date mismatch")
        var database = loadDatabase(todayKey: todayKey)
        database.days[dateKey] = day
        database.rebuildDerivedTables(todayKey: todayKey)
        return saveDatabase(database)
    }

    public func databaseFileURL() -> URL {
        assert(fileURL.pathExtension == "json", "database must be json")
        return fileURL
    }

    public func storageDescription() -> String {
        fileURL.lastPathComponent
    }

    public func loadAllDays() -> [String: FernletDay] {
        loadDatabase(todayKey: FernletDate.dayKey(for: .now)).days
    }

    public func loadTierTwoMemories() -> [TierTwoMemoryRecord] {
        loadDatabase(todayKey: FernletDate.dayKey(for: .now)).tierTwoMemories
    }

    @discardableResult public func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) -> Bool {
        var database = loadDatabase(todayKey: FernletDate.dayKey(for: .now))
        database.tierTwoMemories = records
        database.updatedAt = Date()
        return saveDatabase(database)
    }

    public func loadDatabaseForMigration(todayKey: String) -> LocalFernletDatabase {
        loadDatabase(todayKey: todayKey)
    }

    private func loadDatabase(todayKey: String) -> LocalFernletDatabase {
        assert(!todayKey.isEmpty, "today key required")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return migratedDatabase(todayKey: todayKey)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            print("[Fernlet] Local database could not be read; entering read-only recovery mode.")
            markPersistenceBlockedByDecodeFailure()
            return migratedDatabase(todayKey: todayKey)
        }
        return decodeDatabase(data, todayKey: todayKey)
    }

    private func decodeDatabase(_ data: Data, todayKey: String) -> LocalFernletDatabase {
        assert(!data.isEmpty, "database data required")
        assert(!todayKey.isEmpty, "today key required")
        if let database = try? decoder.decode(LocalFernletDatabase.self, from: data) {
            state.persistenceBlockedByDecodeFailure = false
            return database
        }
        print("[Fernlet] Local database decode failed; entering read-only recovery mode.")
        markPersistenceBlockedByDecodeFailure()
        return migratedDatabase(todayKey: todayKey)
    }

    private func markPersistenceBlockedByDecodeFailure() {
        state.persistenceBlockedByDecodeFailure = true
    }

    private func saveDatabase(_ database: LocalFernletDatabase) -> Bool {
        assert(database.schemaVersion >= 1, "schema version invalid")
        guard !state.persistenceBlockedByDecodeFailure else {
            print("[Fernlet] Refusing to save after local database decode failed.")
            return false
        }
        guard ensureDirectoryExists() else { return false }
        guard let data = try? encoder.encode(database) else {
            assertionFailure("database encode failed")
            return false
        }
        guard write(data) else { return false }
        if state.pendingLegacyCleanup {
            state.pendingLegacyCleanup = false
            Self.clearLegacyUserDefaultsIfPresent()
        }
        return true
    }

    private func ensureDirectoryExists() -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        assert(!directory.path.isEmpty, "directory path required")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            assertionFailure("database directory create failed")
            return false
        }
    }

    private func write(_ data: Data) -> Bool {
        assert(!data.isEmpty, "write data required")
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            assertionFailure("database write failed")
            return false
        }
    }

    private func migratedDatabase(todayKey: String) -> LocalFernletDatabase {
        assert(!todayKey.isEmpty, "today key required")
        var database = LocalFernletDatabase()
        database.days[todayKey] = Self.loadLegacy(FernletDay.self, key: LegacyKeys.day(todayKey)) ?? FernletDay(date: todayKey)
        database.settings = Self.loadLegacy(FernletSettings.self, key: LegacyKeys.settings) ?? FernletSettings()
        database.recentMeals = Self.loadLegacy([Meal].self, key: LegacyKeys.recentMeals) ?? []
        database.previousJournals = Self.loadLegacy([JournalEntry].self, key: LegacyKeys.previousJournals) ?? []
        database.memories = Self.loadLegacy([MemoryNote].self, key: LegacyKeys.memories) ?? []
        database.goals = Self.loadLegacy([FitnessGoal].self, key: LegacyKeys.goals) ?? []
        database.workshop = Self.loadLegacy(WorkshopData.self, key: LegacyKeys.workshop) ?? WorkshopData()
        database.rebuildDerivedTables(todayKey: todayKey)
        state.pendingLegacyCleanup = true
        return database
    }

    private static func clearLegacyUserDefaultsIfPresent() {
        let knownKeys = [
            LegacyKeys.settings,
            LegacyKeys.recentMeals,
            LegacyKeys.previousJournals,
            LegacyKeys.memories,
            LegacyKeys.goals,
            LegacyKeys.workshop
        ]
        guard knownKeys.contains(where: { UserDefaults.standard.data(forKey: $0) != nil }) else { return }
        knownKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("fernlet-day-") }
            .forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    private static func loadLegacy<T: Decodable>(_ type: T.Type, key: String) -> T? {
        assert(!key.isEmpty, "legacy key required")
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        assert(!data.isEmpty, "legacy data should not be empty")
        return try? JSONDecoder().decode(type, from: data)
    }

    public static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        assert(directory != nil, "application support unavailable")
        return (directory ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Fernlet", isDirectory: true)
            .appendingPathComponent("FernletDatabase.json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        assert(encoder.outputFormatting.contains(.prettyPrinted), "encoder formatting invalid")
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        assert(String(describing: decoder.dateDecodingStrategy).contains("iso8601"), "decoder date strategy invalid")
        return decoder
    }

    private enum LegacyKeys {
        static let settings = "fernlet-settings"
        static let recentMeals = "fernlet-recent-meals"
        static let previousJournals = "fernlet-previous-journals"
        static let memories = "fernlet-memories"
        static let goals = "fernlet-goals"
        static let workshop = "fernlet-workshop"

        static func day(_ key: String) -> String {
            assert(!key.isEmpty, "legacy day key required")
            return "fernlet-day-\(key)"
        }
    }
}

extension LocalFernletDatabase {
    /// Applies today's day + the aggregate slices. `maxStoredDays` bounds the blob's own `days` window:
    /// the Core Data path passes a small bound (its `days` is just a recent cache — the per-row `DayRecord`
    /// store is the uncapped source of truth), while the local/no-iCloud path passes nil so its single
    /// file holds the full, now-uncapped history.
    public mutating func apply(_ snapshot: FernletSnapshot, maxStoredDays: Int? = nil) {
        assert(!snapshot.todayKey.isEmpty, "snapshot key required")
        assert(snapshot.day.date == snapshot.todayKey, "snapshot day mismatch")
        days[snapshot.todayKey] = snapshot.day
        if let maxStoredDays, days.count > maxStoredDays {
            let oldest = days.keys.sorted().prefix(days.count - maxStoredDays)
            oldest.forEach { days.removeValue(forKey: $0) }
        }
        settings = snapshot.settings
        recentMeals = snapshot.recentMeals
        previousJournals = snapshot.previousJournals
        memories = snapshot.memories
        goals = snapshot.goals
        workshop = snapshot.workshop
        foodItems = snapshot.foodItems
        recipes = snapshot.recipes
        dailyScores = snapshot.dailyScores
        retryQueue = snapshot.retryQueue
        connectionSessionLogs = snapshot.connectionSessionLogs
        trustedProximityPeers = snapshot.trustedProximityPeers
        trainerAuditEvents = snapshot.trainerAuditEvents
        updatedAt = Date()
    }

    /// Rebuilds the derived log tables + Tier-2 memories. `recentDays` (oldest-first) lets a per-row store
    /// inject a bounded window of days instead of paying a whole-history scan of `self.days`; when omitted
    /// it falls back to the blob's own `days` (the local/no-iCloud path).
    public mutating func rebuildDerivedTables(todayKey: String, recentDays: [(String, FernletDay)]? = nil) {
        assert(!todayKey.isEmpty, "today key required")
        let orderedDays = recentDays ?? Self.sortedDayPairs(days)
        dailyLogs = Self.makeDailyLogs(from: orderedDays)
        mealLogs = Self.makeMealLogs(from: orderedDays)
        workoutLogs = Self.makeWorkoutLogs(from: orderedDays)
        journalLogs = Self.makeJournalLogs(from: orderedDays)
        tierTwoMemories = TierTwoMemoryEngine.updateInferences(existing: tierTwoMemories, from: orderedDays, goals: goals)
    }

    private static func sortedDayPairs(_ days: [String: FernletDay]) -> [(String, FernletDay)] {
        // No upper-bound assertion: day storage is uncapped now (per-row rows for iCloud, a single
        // uncapped file for local-only). The log builders below still bound their output by
        // `derivedLogWindowDays`, so the derived tables stay sized regardless of history depth.
        days.sorted { first, second in first.key < second.key }
    }

    private static func makeDailyLogs(from days: [(String, FernletDay)]) -> [DailyLogRecord] {
        return days.suffix(FernletLimits.derivedLogWindowDays).map { key, day in
            DailyLogRecord(dateKey: key, day: day)
        }
    }

    private static func makeMealLogs(from days: [(String, FernletDay)]) -> [MealLogRecord] {
        let nested = days.suffix(FernletLimits.derivedLogWindowDays).map { key, day in
            day.meals.prefix(FernletLimits.maxMealsPerDay).map { meal in
                MealLogRecord(dateKey: key, meal: meal, totals: MacroTotals(meals: day.meals))
            }
        }
        return Array(nested.joined().prefix(FernletLimits.maxMealLogs))
    }

    private static func makeWorkoutLogs(from days: [(String, FernletDay)]) -> [WorkoutLogRecord] {
        let nested = days.suffix(FernletLimits.derivedLogWindowDays).map { key, day in
            day.workouts.prefix(FernletLimits.maxWorkoutsPerDay).map { workout in
                WorkoutLogRecord(dateKey: key, workout: workout)
            }
        }
        return Array(nested.joined().prefix(FernletLimits.maxWorkoutLogs))
    }

    private static func makeJournalLogs(from days: [(String, FernletDay)]) -> [JournalLogRecord] {
        let nested = days.suffix(FernletLimits.derivedLogWindowDays).map { key, day in
            day.journals.prefix(FernletLimits.maxJournalsPerDay).map { journal in
                JournalLogRecord(dateKey: key, journal: journal)
            }
        }
        return Array(nested.joined().prefix(FernletLimits.maxJournalLogs))
    }

}

public enum FernletLimits {
    public static let maxStoredDays = 370
    /// How much day history the derived log tables (daily/meal/workout/journal) retain. Decoupled from
    /// day *storage* (which is per-row and uncapped) — it bounds only the recomputable log tables and the
    /// "year-ago" lookbacks, so derived rebuilds read a fixed recent window instead of the whole history.
    public static let derivedLogWindowDays = 370
    public static let maxMealsPerDay = 20
    public static let maxWorkoutsPerDay = 12
    public static let maxJournalsPerDay = 12
    public static let maxMealLogs = 7_400
    public static let maxWorkoutLogs = 4_440
    public static let maxJournalLogs = 4_440
    public static let maxJournalCharacters = 800
    public static let maxEmotionKeys = 8
    public static let signalWindowDays = 14
}

extension MacroTotals {
    public init(meals: [Meal]) {
        assert(meals.count <= FernletLimits.maxMealsPerDay, "too many meals")
        let limited = meals.prefix(FernletLimits.maxMealsPerDay)
        self.init(
            protein: limited.reduce(0) { $0 + $1.macros.protein },
            carbs: limited.reduce(0) { $0 + $1.macros.carbs },
            fat: limited.reduce(0) { $0 + $1.macros.fat }
        )
    }
}
