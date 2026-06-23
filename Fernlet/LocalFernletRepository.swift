//
//  LocalFernletRepository.swift
//  Fernlet
//
//  Created by Coding Assistant on 5/16/26.
//

import Foundation

protocol FernletRepository {
    func loadSnapshot(todayKey: String) -> FernletSnapshot
    @discardableResult func saveSnapshot(_ snapshot: FernletSnapshot) -> Bool
    @discardableResult func updateDay(_ day: FernletDay, for dateKey: String, todayKey: String) -> Bool
    func storageDescription() -> String
    func loadAllDays() -> [String: FernletDay]
    func loadTierTwoMemories() -> [TierTwoMemoryRecord]
    func loadDay(for dateKey: String, todayKey: String) -> FernletDay
}

extension FernletRepository {
    func loadDay(for dateKey: String, todayKey: String) -> FernletDay {
        loadSnapshot(todayKey: dateKey).day
    }
}

struct FernletSnapshot: Codable {
    var todayKey: String
    var day: FernletDay
    var settings: FernletSettings
    var recentMeals: [Meal]
    var previousJournals: [JournalEntry]
    var memories: [MemoryNote]
    var goals: [FitnessGoal]
    var workshop: WorkshopData
    var foodItems: [FoodItem] = []
    var recipes: [RecipeDefinition] = []
    var dailyScores: [DailyHealthScore] = []
    var retryQueue: [AIAnalysisRetryRecord] = []
    var connectionSessionLogs: [ConnectionSessionLog] = []
    var trustedProximityPeers: [ProximityTrustedPeerRecord] = []
    var trainerAuditEvents: [TrainerAuditEvent] = []

    init(
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

    init(from decoder: Decoder) throws {
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

struct LocalFernletDatabase: Codable, @unchecked Sendable {
    var schemaVersion = 1
    var updatedAt = Date()
    var days: [String: FernletDay] = [:]
    var settings = FernletSettings()
    var recentMeals: [Meal] = []
    var previousJournals: [JournalEntry] = []
    var memories: [MemoryNote] = []
    var goals: [FitnessGoal] = []
    var workshop = WorkshopData()
    var dailyLogs: [DailyLogRecord] = []
    var mealLogs: [MealLogRecord] = []
    var workoutLogs: [WorkoutLogRecord] = []
    var journalLogs: [JournalLogRecord] = []
    var retryQueue: [AIAnalysisRetryRecord] = []
    var tierTwoMemories: [TierTwoMemoryRecord] = []
    var foodItems: [FoodItem] = []
    var recipes: [RecipeDefinition] = []
    var dailyScores: [DailyHealthScore] = []
    var connectionSessionLogs: [ConnectionSessionLog] = []
    var trustedProximityPeers: [ProximityTrustedPeerRecord] = []
    var trainerAuditEvents: [TrainerAuditEvent] = []

    init() {}

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        days = try container.decodeIfPresent([String: FernletDay].self, forKey: .days) ?? [:]
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

struct LocalFernletRepository: FernletRepository {
    private final class State {
        var persistenceBlockedByDecodeFailure = false
        var pendingLegacyCleanup = false
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let state = State()

    init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        assert(!resolvedURL.path.isEmpty, "repository path must not be empty")
        self.fileURL = resolvedURL
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    func loadSnapshot(todayKey: String) -> FernletSnapshot {
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

    @discardableResult func saveSnapshot(_ snapshot: FernletSnapshot) -> Bool {
        assert(!snapshot.todayKey.isEmpty, "snapshot key required")
        var database = loadDatabase(todayKey: snapshot.todayKey)
        database.apply(snapshot)
        database.rebuildDerivedTables(todayKey: snapshot.todayKey)
        return saveDatabase(database)
    }

    @discardableResult func updateDay(_ day: FernletDay, for dateKey: String, todayKey: String) -> Bool {
        assert(!dateKey.isEmpty, "date key required")
        assert(!todayKey.isEmpty, "today key required")
        assert(day.date == dateKey, "day date mismatch")
        var database = loadDatabase(todayKey: todayKey)
        database.days[dateKey] = day
        database.rebuildDerivedTables(todayKey: todayKey)
        return saveDatabase(database)
    }

    func databaseFileURL() -> URL {
        assert(fileURL.pathExtension == "json", "database must be json")
        return fileURL
    }

    func storageDescription() -> String {
        fileURL.lastPathComponent
    }

    func loadAllDays() -> [String: FernletDay] {
        loadDatabase(todayKey: FernletDate.dayKey(for: .now)).days
    }

    func loadTierTwoMemories() -> [TierTwoMemoryRecord] {
        loadDatabase(todayKey: FernletDate.dayKey(for: .now)).tierTwoMemories
    }

    func loadDatabaseForMigration(todayKey: String) -> LocalFernletDatabase {
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

    static func defaultFileURL() -> URL {
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
    mutating func apply(_ snapshot: FernletSnapshot) {
        assert(!snapshot.todayKey.isEmpty, "snapshot key required")
        assert(snapshot.day.date == snapshot.todayKey, "snapshot day mismatch")
        days[snapshot.todayKey] = snapshot.day
        if days.count > FernletLimits.maxStoredDays {
            let oldest = days.keys.sorted().prefix(days.count - FernletLimits.maxStoredDays)
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

    mutating func rebuildDerivedTables(todayKey: String) {
        assert(!todayKey.isEmpty, "today key required")
        let orderedDays = Self.sortedDayPairs(days)
        dailyLogs = Self.makeDailyLogs(from: orderedDays)
        mealLogs = Self.makeMealLogs(from: orderedDays)
        workoutLogs = Self.makeWorkoutLogs(from: orderedDays)
        journalLogs = Self.makeJournalLogs(from: orderedDays)
        tierTwoMemories = TierTwoMemoryEngine.updateInferences(existing: tierTwoMemories, from: orderedDays, goals: goals)
    }

    private static func sortedDayPairs(_ days: [String: FernletDay]) -> [(String, FernletDay)] {
        assert(days.count <= FernletLimits.maxStoredDays, "too many stored days")
        return days.sorted { first, second in first.key < second.key }
    }

    private static func makeDailyLogs(from days: [(String, FernletDay)]) -> [DailyLogRecord] {
        return days.suffix(FernletLimits.maxStoredDays).map { key, day in
            DailyLogRecord(dateKey: key, day: day)
        }
    }

    private static func makeMealLogs(from days: [(String, FernletDay)]) -> [MealLogRecord] {
        let nested = days.suffix(FernletLimits.maxStoredDays).map { key, day in
            day.meals.prefix(FernletLimits.maxMealsPerDay).map { meal in
                MealLogRecord(dateKey: key, meal: meal, totals: MacroTotals(meals: day.meals))
            }
        }
        return Array(nested.joined().prefix(FernletLimits.maxMealLogs))
    }

    private static func makeWorkoutLogs(from days: [(String, FernletDay)]) -> [WorkoutLogRecord] {
        let nested = days.suffix(FernletLimits.maxStoredDays).map { key, day in
            day.workouts.prefix(FernletLimits.maxWorkoutsPerDay).map { workout in
                WorkoutLogRecord(dateKey: key, workout: workout)
            }
        }
        return Array(nested.joined().prefix(FernletLimits.maxWorkoutLogs))
    }

    private static func makeJournalLogs(from days: [(String, FernletDay)]) -> [JournalLogRecord] {
        let nested = days.suffix(FernletLimits.maxStoredDays).map { key, day in
            day.journals.prefix(FernletLimits.maxJournalsPerDay).map { journal in
                JournalLogRecord(dateKey: key, journal: journal)
            }
        }
        return Array(nested.joined().prefix(FernletLimits.maxJournalLogs))
    }

}

struct DailyLogRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var dateKey: String
    var weight: Double?
    var sleepHours: Double?
    var sleepQuality: SleepQuality?
    var workoutCompleted: Bool
    var proteinGrams: Int
    var calories: Int
    var micronutrients: Micronutrients
    var location: String?
    var notes: String?

    init(dateKey: String, day: FernletDay) {
        assert(!dateKey.isEmpty, "date key required")
        let totals = MacroTotals(meals: day.meals)
        self.dateKey = dateKey
        self.sleepHours = day.sleep?.hours
        self.sleepQuality = day.sleep?.quality
        self.workoutCompleted = !day.workouts.isEmpty
        self.proteinGrams = totals.protein
        self.calories = totals.calories
        self.micronutrients = Micronutrients.totals(for: day.meals)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        dateKey = try container.decode(String.self, forKey: .dateKey)
        weight = try container.decodeIfPresent(Double.self, forKey: .weight)
        sleepHours = try container.decodeIfPresent(Double.self, forKey: .sleepHours)
        sleepQuality = try container.decodeIfPresent(SleepQuality.self, forKey: .sleepQuality)
        workoutCompleted = try container.decode(Bool.self, forKey: .workoutCompleted)
        proteinGrams = try container.decode(Int.self, forKey: .proteinGrams)
        calories = try container.decode(Int.self, forKey: .calories)
        micronutrients = try container.decodeIfPresent(Micronutrients.self, forKey: .micronutrients) ?? Micronutrients()
        location = try container.decodeIfPresent(String.self, forKey: .location)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

struct MealLogRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var dateKey: String
    var mealType: MealType
    var description: String
    var calories: Int
    var protein: Int
    var carbs: Int
    var fat: Int
    var micronutrients: Micronutrients
    var source: String
    var dailyCalorieTotal: Int
    var dailyProteinTotal: Int

    init(dateKey: String, meal: Meal, totals: MacroTotals) {
        assert(!dateKey.isEmpty, "date key required")
        assert(meal.calories >= 0, "meal calories invalid")
        self.dateKey = dateKey
        self.mealType = meal.mealType
        self.description = meal.name
        self.calories = meal.calories
        self.protein = meal.macros.protein
        self.carbs = meal.macros.carbs
        self.fat = meal.macros.fat
        self.micronutrients = meal.micronutrientSnapshot
        self.source = meal.source
        self.dailyCalorieTotal = totals.calories
        self.dailyProteinTotal = totals.protein
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        dateKey = try container.decode(String.self, forKey: .dateKey)
        mealType = try container.decode(MealType.self, forKey: .mealType)
        description = try container.decode(String.self, forKey: .description)
        calories = try container.decode(Int.self, forKey: .calories)
        protein = try container.decode(Int.self, forKey: .protein)
        carbs = try container.decode(Int.self, forKey: .carbs)
        fat = try container.decode(Int.self, forKey: .fat)
        micronutrients = try container.decodeIfPresent(Micronutrients.self, forKey: .micronutrients) ?? Micronutrients()
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? MealLogSource.manual
        dailyCalorieTotal = try container.decode(Int.self, forKey: .dailyCalorieTotal)
        dailyProteinTotal = try container.decode(Int.self, forKey: .dailyProteinTotal)
    }
}

struct WorkoutLogRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var dateKey: String
    var type: WorkoutType
    var exercises: String
    var rpe: Double?
    var notes: String

    init(dateKey: String, workout: Workout) {
        assert(!dateKey.isEmpty, "date key required")
        assert(workout.duration == nil || workout.duration! >= 0, "duration invalid")
        self.dateKey = dateKey
        self.type = workout.type
        self.exercises = workout.exercises
        self.rpe = workout.rpe
        self.notes = workout.notes
    }
}

struct JournalLogRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var dateKey: String
    var tag: FeelingTag
    var text: String
    var emotions: [String]

    init(dateKey: String, journal: JournalEntry) {
        assert(!dateKey.isEmpty, "date key required")
        assert(journal.text.count <= FernletLimits.maxJournalCharacters, "journal too long")
        self.dateKey = dateKey
        self.tag = journal.tag
        self.text = journal.text
        self.emotions = Array(journal.emotions.prefix(FernletLimits.maxEmotionKeys))
    }
}

struct DerivedSignalRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var signalName: String
    var value: String
    var computedAt = Date()
    var windowStart: String
    var windowEnd: String
    var sourceFields: [String]
    var nutrientGaps: [NutrientGap]

    init(
        id: UUID = UUID(),
        signalName: String,
        value: String,
        computedAt: Date = Date(),
        windowStart: String,
        windowEnd: String,
        sourceFields: [String],
        nutrientGaps: [NutrientGap] = []
    ) {
        self.id = id
        self.signalName = signalName
        self.value = value
        self.computedAt = computedAt
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.sourceFields = sourceFields
        self.nutrientGaps = nutrientGaps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        signalName = try container.decode(String.self, forKey: .signalName)
        value = try container.decode(String.self, forKey: .value)
        computedAt = try container.decodeIfPresent(Date.self, forKey: .computedAt) ?? Date()
        windowStart = try container.decode(String.self, forKey: .windowStart)
        windowEnd = try container.decode(String.self, forKey: .windowEnd)
        sourceFields = try container.decode([String].self, forKey: .sourceFields)
        nutrientGaps = try container.decodeIfPresent([NutrientGap].self, forKey: .nutrientGaps) ?? []
    }
}

struct AIAnalysisRetryRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var payloadType: String
    var sourceId: UUID
    var createdAt = Date()
    var lastAttemptAt: Date?
    var attemptCount = 0
    var note: String
}

struct TierTwoMemoryRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var category: String
    var text: String
    var state: String = ""             // key behavioral verdict; change triggers a new record
    var evidence: String = ""
    var confidence: String = "medium"  // "low", "medium", "high"
    var extractedDate = Date()
    var active = true
    var dataWindowDays: Int = 14

    init(
        category: String,
        text: String,
        state: String = "",
        evidence: String = "",
        confidence: String = "medium",
        dataWindowDays: Int = 14
    ) {
        self.category = category
        self.text = text
        self.state = state
        self.evidence = evidence
        self.confidence = confidence
        self.dataWindowDays = dataWindowDays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        category = try container.decode(String.self, forKey: .category)
        text = try container.decode(String.self, forKey: .text)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        confidence = try container.decodeIfPresent(String.self, forKey: .confidence) ?? "medium"
        extractedDate = try container.decodeIfPresent(Date.self, forKey: .extractedDate) ?? Date()
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
        dataWindowDays = try container.decodeIfPresent(Int.self, forKey: .dataWindowDays) ?? 14
    }
}

enum FernletLimits {
    static let maxStoredDays = 370
    static let maxMealsPerDay = 20
    static let maxWorkoutsPerDay = 12
    static let maxJournalsPerDay = 12
    static let maxMealLogs = 7_400
    static let maxWorkoutLogs = 4_440
    static let maxJournalLogs = 4_440
    static let maxJournalCharacters = 800
    static let maxEmotionKeys = 8
    static let signalWindowDays = 14
}

extension MacroTotals {
    init(meals: [Meal]) {
        assert(meals.count <= FernletLimits.maxMealsPerDay, "too many meals")
        let limited = meals.prefix(FernletLimits.maxMealsPerDay)
        self.protein = limited.reduce(0) { $0 + $1.macros.protein }
        self.carbs = limited.reduce(0) { $0 + $1.macros.carbs }
        self.fat = limited.reduce(0) { $0 + $1.macros.fat }
    }
}

enum DerivedSignalFactory {
    static func makeSignals(from days: [(String, FernletDay)], todayKey: String) -> [DerivedSignalRecord] {
        assert(!todayKey.isEmpty, "today key required")
        assert(days.count <= FernletLimits.signalWindowDays, "too many signal days")
        guard let first = days.first?.0, let last = days.last?.0 else { return [] }
        return [
            moodTrend(from: days, start: first, end: last),
            energyTrend(from: days, start: first, end: last),
            eatingPattern(from: days, start: first, end: last),
            progressionTrend(from: days, start: first, end: last),
            intensityReadiness(from: days, start: first, end: last),
            micronutrientTrend(from: days, start: first, end: last, windowDays: 7),
            micronutrientTrend(from: days, start: first, end: last, windowDays: 14)
        ]
    }

    private static func moodTrend(from days: [(String, FernletDay)], start: String, end: String) -> DerivedSignalRecord {
        assert(!start.isEmpty, "start required")
        assert(!end.isEmpty, "end required")
        let scores = dailyMoodScores(from: days)
        let value: String
        if scores.count < 2 {
            value = "insufficient data"
        } else if scores.suffix(3).contains(where: { $0 <= 0.4 }) {
            value = "needs gentleness"
        } else {
            value = trendValue(scores: scores, rising: "improving", falling: "declining", steady: "steady")
        }
        return DerivedSignalRecord(signalName: "moodTrend", value: value, windowStart: start, windowEnd: end, sourceFields: ["journals.tag"])
    }

    private static func energyTrend(from days: [(String, FernletDay)], start: String, end: String) -> DerivedSignalRecord {
        assert(days.count <= FernletLimits.signalWindowDays, "too many days")
        assert(!end.isEmpty, "end required")
        let scores = dailyEnergyScores(from: days)
        let recentAverage = average(Array(scores.suffix(min(3, scores.count))))
        let value: String
        if scores.count < 2 {
            value = "insufficient data"
        } else if recentAverage < 0.48 {
            value = "low"
        } else {
            value = trendValue(scores: scores, rising: "rising", falling: "dipping", steady: "steady")
        }
        return DerivedSignalRecord(signalName: "energyTrend", value: value, windowStart: start, windowEnd: end, sourceFields: ["sleep.hours", "sleep.quality", "journals.tag", "workouts.intensity"])
    }

    private static func eatingPattern(from days: [(String, FernletDay)], start: String, end: String) -> DerivedSignalRecord {
        assert(days.count <= FernletLimits.signalWindowDays, "too many days")
        assert(!start.isEmpty, "start required")
        let loggedDays = days.filter { $0.1.meals.isEmpty == false }
        let value: String
        if loggedDays.count < 2 {
            value = "insufficient data"
        } else {
            let mealCounts = loggedDays.map { min($0.1.meals.count, FernletLimits.maxMealsPerDay) }
            let averageMeals = average(mealCounts.map(Double.init))
            let skippedRecentDays = days.suffix(min(3, days.count)).filter { $0.1.meals.isEmpty }.count
            let proteinDays = loggedDays.filter { MacroTotals(meals: $0.1.meals).protein >= 70 }.count
            if skippedRecentDays >= 2 || averageMeals < 1.5 {
                value = "light"
            } else if proteinDays >= max(2, Int(ceil(Double(loggedDays.count) * 0.6))) {
                value = "protein-forward"
            } else if (mealCounts.max() ?? 0) - (mealCounts.min() ?? 0) >= 3 {
                value = "inconsistent"
            } else {
                value = "consistent"
            }
        }
        return DerivedSignalRecord(signalName: "eatingPattern", value: value, windowStart: start, windowEnd: end, sourceFields: ["meals.count", "meals.macros", "meals.calorieSnapshot"])
    }

    private static func intensityReadiness(from days: [(String, FernletDay)], start: String, end: String) -> DerivedSignalRecord {
        assert(days.count <= FernletLimits.signalWindowDays, "too many days")
        assert(!end.isEmpty, "end required")
        let recentDays = Array(days.suffix(min(3, days.count)))
        let recentLoad = recentDays.map { dailyTrainingLoad($0.1) }.reduce(0, +)
        let recentEnergy = average(dailyEnergyScores(from: recentDays))
        let recentMeals = recentDays.reduce(0) { $0 + min($1.1.meals.count, FernletLimits.maxMealsPerDay) }
        let recentHardCount = recentDays.reduce(0) { count, day in
            count + day.1.workouts.prefix(FernletLimits.maxWorkoutsPerDay).filter { $0.intensity == .hard }.count
        }
        let value: String
        if recentDays.isEmpty || (recentLoad == 0 && recentEnergy == 0 && recentMeals == 0) {
            value = "insufficient data"
        } else if recentEnergy < 0.45 || recentHardCount >= 2 || recentLoad >= 260 {
            value = "ready for light"
        } else if recentEnergy >= 0.72 && recentHardCount == 0 && recentMeals >= recentDays.count * 2 {
            value = "ready for hard"
        } else {
            value = "ready for moderate"
        }
        return DerivedSignalRecord(signalName: "intensityReadiness", value: value, windowStart: start, windowEnd: end, sourceFields: ["workouts.intensity", "workouts.duration", "workouts.rpe", "sleep", "journals.tag", "meals.count"])
    }

    private static func progressionTrend(from days: [(String, FernletDay)], start: String, end: String) -> DerivedSignalRecord {
        assert(days.count <= FernletLimits.signalWindowDays, "too many days")
        let midpoint = days.count / 2
        let older = days.prefix(midpoint)
        let newer = days.suffix(days.count - midpoint)
        let olderLoad = older.map { dailyTrainingLoad($0.1) }.reduce(0, +)
        let newerLoad = newer.map { dailyTrainingLoad($0.1) }.reduce(0, +)
        let workoutDays = days.filter { $0.1.workouts.isEmpty == false }.count
        let value: String
        if workoutDays < 2 {
            value = "insufficient data"
        } else if Double(newerLoad) >= Double(max(olderLoad, 1)) * 1.20 {
            value = "building"
        } else if Double(newerLoad) <= Double(max(olderLoad, 1)) * 0.70 {
            value = "deloading"
        } else {
            value = "steady"
        }
        return DerivedSignalRecord(signalName: "progressionTrend", value: value, windowStart: start, windowEnd: end, sourceFields: ["workouts.duration", "workouts.intensity", "workouts.rpe"])
    }

    private static func micronutrientTrend(from days: [(String, FernletDay)], start: String, end: String, windowDays: Int) -> DerivedSignalRecord {
        assert(windowDays == 7 || windowDays == 14, "unsupported nutrient window")
        let gaps = MicronutrientGapAnalyzer.gaps(from: days, windowDays: windowDays)
        let gapCount = gaps.filter { $0.status == .gap }.count
        let coveredCount = gaps.filter { $0.status == .covered }.count
        let value: String
        if gapCount > 0 {
            value = "\(gapCount) possible gap\(gapCount == 1 ? "" : "s")"
        } else if coveredCount > 0 {
            value = "\(coveredCount) covered"
        } else {
            value = "insufficient data"
        }
        return DerivedSignalRecord(
            signalName: "micronutrientGaps\(windowDays)Day",
            value: value,
            windowStart: start,
            windowEnd: end,
            sourceFields: ["meals.micronutrientSnapshot"],
            nutrientGaps: gaps
        )
    }

    private static func dailyMoodScores(from days: [(String, FernletDay)]) -> [Double] {
        days.compactMap { _, day in
            let scores = day.journals.prefix(FernletLimits.maxJournalsPerDay).map { moodScore($0.tag) }
            guard scores.isEmpty == false else { return nil }
            return average(scores)
        }
    }

    private static func dailyEnergyScores(from days: [(String, FernletDay)]) -> [Double] {
        days.compactMap { _, day in
            var components: [Double] = []
            if let sleep = day.sleep {
                components.append(sleepEnergyScore(sleep))
            }
            let journalScores = day.journals.prefix(FernletLimits.maxJournalsPerDay).map { moodScore($0.tag) }
            if journalScores.isEmpty == false {
                components.append(average(journalScores))
            }
            let workoutLoad = dailyTrainingLoad(day)
            if workoutLoad > 0 {
                components.append(max(0.25, 1 - Double(workoutLoad) / 260))
            }
            guard components.isEmpty == false else { return nil }
            return average(components)
        }
    }

    private static func trendValue(scores: [Double], rising: String, falling: String, steady: String) -> String {
        let midpoint = scores.count / 2
        let older = Array(scores.prefix(midpoint))
        let newer = Array(scores.suffix(scores.count - midpoint))
        guard older.isEmpty == false, newer.isEmpty == false else { return steady }
        let delta = average(newer) - average(older)
        if delta >= 0.12 { return rising }
        if delta <= -0.12 { return falling }
        return steady
    }

    private static func moodScore(_ tag: FeelingTag) -> Double {
        switch tag {
        case .bright: 1
        case .good: 0.85
        case .neutral: 0.65
        case .quiet: 0.55
        case .tired: 0.35
        case .hard: 0.2
        }
    }

    private static func sleepEnergyScore(_ sleep: SleepLog) -> Double {
        let qualityScore: Double
        switch sleep.quality {
        case .great: qualityScore = 1
        case .good: qualityScore = 0.82
        case .ok: qualityScore = 0.6
        case .poor: qualityScore = 0.3
        }
        guard let hours = sleep.hours else { return qualityScore }
        let hourScore = min(max(hours / 8, 0), 1)
        return hourScore * 0.6 + qualityScore * 0.4
    }

    private static func dailyTrainingLoad(_ day: FernletDay) -> Int {
        day.workouts.prefix(FernletLimits.maxWorkoutsPerDay).reduce(0) { total, workout in
            let minutes = max(workout.duration ?? 30, 0)
            let intensityMultiplier: Double
            switch workout.intensity {
            case .light: intensityMultiplier = 0.75
            case .moderate: intensityMultiplier = 1
            case .hard: intensityMultiplier = 1.35
            }
            let rpeMultiplier = workout.rpe.map { min(max($0, 1), 10) / 7 } ?? 1
            return total + Int((Double(minutes) * intensityMultiplier * rpeMultiplier).rounded())
        }
    }

    private static func average(_ values: [Double]) -> Double {
        guard values.isEmpty == false else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - Tier Two Memory Engine

enum TierTwoMemoryEngine {

    // Each category stores at most 5 records; total is capped at 20.
    // With 4 categories × 5 = 20, the per-category cap IS the global cap.
    private static let maxPerCategory = 5
    private static let maxTotal = 20

    // Compares the new 14-day window against existing records.
    // Only appends when the behavioral state for a category has actually changed.
    static func updateInferences(
        existing: [TierTwoMemoryRecord],
        from days: [(String, FernletDay)],
        goals: [FitnessGoal]
    ) -> [TierTwoMemoryRecord] {
        let window = Array(days.suffix(14))
        guard window.count >= 3 else { return prune(existing) }

        var updated = existing

        let candidates = [
            goalBehaviorGap(window: window, goals: goals),
            consistencyProfile(window: window),
            journalAvoidancePattern(window: window),
            workoutMoodCorrelation(window: window)
        ].compactMap { $0 }

        for new in candidates {
            let lastActive = updated
                .filter { $0.category == new.category && $0.active }
                .sorted { $0.extractedDate < $1.extractedDate }
                .last
            if let prev = lastActive {
                if prev.state == new.state { continue }  // same verdict, skip
                if let idx = updated.firstIndex(where: { $0.id == prev.id }) {
                    updated[idx].active = false
                }
            }
            updated.append(new)
        }

        return prune(updated)
    }

    // Keeps the most recent maxPerCategory records per category.
    // If still over maxTotal, drops oldest inactive records first.
    private static func prune(_ records: [TierTwoMemoryRecord]) -> [TierTwoMemoryRecord] {
        let categories = Array(Set(records.map { $0.category })).sorted()
        var result: [TierTwoMemoryRecord] = []
        for category in categories {
            let byDate = records
                .filter { $0.category == category }
                .sorted { $0.extractedDate < $1.extractedDate }
            result.append(contentsOf: byDate.suffix(maxPerCategory))
        }
        guard result.count > maxTotal else { return result }
        let active = result.filter { $0.active }.sorted { $0.extractedDate > $1.extractedDate }
        let inactive = result.filter { !$0.active }.sorted { $0.extractedDate > $1.extractedDate }
        return Array((active + inactive).prefix(maxTotal))
    }

    // MARK: Goal-Behavior Gap

    private static func goalBehaviorGap(
        window: [(String, FernletDay)],
        goals: [FitnessGoal]
    ) -> TierTwoMemoryRecord? {
        guard let primary = goals.first else { return nil }
        let n = window.count
        let workoutDays = window.filter { !$0.1.workouts.isEmpty }.count
        let mealDays = window.filter { !$0.1.meals.isEmpty }.count
        let journalDays = window.filter { !$0.1.journals.isEmpty }.count
        let workoutRate = Double(workoutDays) / Double(n)
        let mealRate = Double(mealDays) / Double(n)
        let journalRate = Double(journalDays) / Double(n)

        let text: String
        let state: String
        let evidence: String
        let confidence: String

        switch primary.type {
        case .strength:
            evidence = "\(workoutDays)/\(n) days with workouts"
            if workoutRate < 0.2 {
                state = "misaligned"; confidence = "high"
                text = "Has stated strength goals but rarely exercises in the data window; likely lacks follow-through or is in a low-motivation period."
            } else if workoutRate < 0.45 {
                state = "partial"; confidence = "medium"
                text = "Exercises occasionally but inconsistently relative to stated strength goals; partial adherence."
            } else {
                state = "aligned"; confidence = "high"
                text = "Workout behavior aligns with stated strength goals; demonstrates consistent follow-through."
            }

        case .weightManagement:
            evidence = "\(mealDays)/\(n) meal days, \(workoutDays)/\(n) workout days"
            if mealRate < 0.3 {
                state = "misaligned"; confidence = "high"
                text = "States weight management goals but rarely logs meals; tends to avoid tracking when not on plan."
            } else if workoutRate < 0.2 {
                state = "dietary_only"; confidence = "medium"
                text = "Tracks food reasonably often but seldom exercises; weight management approach is primarily dietary."
            } else {
                state = "aligned"; confidence = "high"
                text = "Actively tracking both food and exercise consistent with weight management goals."
            }

        case .mentalHealth:
            evidence = "\(journalDays)/\(n) days with journal entries"
            if journalRate < 0.25 {
                state = "misaligned"; confidence = "medium"
                text = "Has mental health goals but journals infrequently; reflective self-care behaviors are inconsistent with stated intent."
            } else {
                state = "aligned"; confidence = "medium"
                text = "Journals regularly, consistent with a mental health focus; self-reflection appears to be a real practice."
            }

        case .recovery:
            let sleepDays = window.filter { $0.1.sleep != nil }.count
            evidence = "\(sleepDays)/\(n) sleep logged, \(workoutDays)/\(n) workout days"
            let sleepRate = Double(sleepDays) / Double(n)
            if sleepRate < 0.3 && workoutRate > 0.5 {
                state = "misaligned"; confidence = "medium"
                text = "Trains frequently but rarely logs sleep or rest; recovery behaviors do not match stated recovery goals."
            } else if sleepRate >= 0.4 {
                state = "aligned"; confidence = "medium"
                text = "Sleep and recovery tracking consistent with recovery-focused goals."
            } else {
                state = "partial"; confidence = "low"
                text = "Recovery goal stated but few behaviors in the data consistently support it."
            }

        case .wellness, .exploring:
            evidence = "\(mealDays)/\(n) meal days, \(workoutDays)/\(n) workout days"
            if mealRate < 0.2 && workoutRate < 0.2 {
                state = "passive_wellness"; confidence = "high"
                text = "General wellness goal stated but almost no tracking across any domain; app engagement is minimal."
            } else {
                state = "partial"; confidence = "low"
                text = "Wellness-oriented user with intermittent engagement; no structured pattern is apparent."
            }
        }

        return TierTwoMemoryRecord(
            category: "goal_behavior_gap",
            text: text,
            state: state,
            evidence: evidence,
            confidence: confidence,
            dataWindowDays: n
        )
    }

    // MARK: Consistency Profile

    private static func consistencyProfile(window: [(String, FernletDay)]) -> TierTwoMemoryRecord? {
        let n = window.count
        let activeDays = window.filter { _, day in
            !day.meals.isEmpty || !day.workouts.isEmpty || !day.journals.isEmpty || day.sleep != nil
        }.count
        let rate = Double(activeDays) / Double(n)

        let text: String
        let state: String
        let confidence: String

        if rate >= 0.75 {
            state = "consistent"; confidence = "high"
            text = "Logs consistently across most days; self-monitoring appears to be a genuine habit rather than reactive behavior."
        } else if rate >= 0.45 {
            state = "intermittent"; confidence = "medium"
            text = "Logs intermittently — tends to engage when motivated or on good days; gaps likely reflect disengagement or avoidance."
        } else if rate >= 0.2 {
            state = "sporadic"; confidence = "medium"
            text = "Rarely logs data; engagement pattern suggests the app is used sporadically, likely only when already on track."
        } else {
            state = "minimal"; confidence = "high"
            text = "Minimal logging across the window; stated goals are not backed by sustained day-to-day engagement."
        }

        return TierTwoMemoryRecord(
            category: "consistency_profile",
            text: text,
            state: state,
            evidence: "\(activeDays)/\(n) days with any logged data",
            confidence: confidence,
            dataWindowDays: n
        )
    }

    // MARK: Journal Avoidance Pattern

    private static func journalAvoidancePattern(window: [(String, FernletDay)]) -> TierTwoMemoryRecord? {
        let avoidanceKeywords = [
            "couldn't", "too tired", "forgot", "maybe tomorrow", "didn't have time",
            "was going to", "supposed to", "meant to", "next week", "eventually",
            "need to start", "should have", "ran out of time", "not today",
            "kept meaning", "will try", "hoping to", "plan to start"
        ]
        let allJournals = window.flatMap { $0.1.journals }
        guard allJournals.count >= 2 else { return nil }

        let avoidanceCount = allJournals.filter { journal in
            let lower = journal.text.lowercased()
            return avoidanceKeywords.contains { lower.contains($0) }
        }.count

        let rate = Double(avoidanceCount) / Double(allJournals.count)
        guard rate >= 0.3 || avoidanceCount >= 3 else { return nil }

        let text: String
        let state: String
        let confidence: String

        if rate >= 0.6 {
            state = "high_avoidance"; confidence = "high"
            text = "Journal entries frequently contain excuse and avoidance language rather than reflection; may use journaling to rationalize rather than confront behavior patterns."
        } else {
            state = "moderate_avoidance"; confidence = "medium"
            text = "Journal entries occasionally show avoidance patterns — citing tiredness, forgetting, or planning to act later; gap between stated intentions and follow-through is visible in writing."
        }

        return TierTwoMemoryRecord(
            category: "journal_avoidance_pattern",
            text: text,
            state: state,
            evidence: "\(avoidanceCount)/\(allJournals.count) journal entries contain avoidance language",
            confidence: confidence,
            dataWindowDays: window.count
        )
    }

    // MARK: Workout-Mood Correlation

    private static func workoutMoodCorrelation(window: [(String, FernletDay)]) -> TierTwoMemoryRecord? {
        let workoutWithMood = window.filter { !$0.1.workouts.isEmpty && !$0.1.journals.isEmpty }
        let restWithMood = window.filter { $0.1.workouts.isEmpty && !$0.1.journals.isEmpty }
        guard workoutWithMood.count >= 2, restWithMood.count >= 2 else { return nil }

        func avgMood(_ pairs: [(String, FernletDay)]) -> Double {
            let scores = pairs.flatMap { $0.1.journals }.map { moodScore($0.tag) }
            guard !scores.isEmpty else { return 0 }
            return scores.reduce(0, +) / Double(scores.count)
        }

        let workoutMood = avgMood(workoutWithMood)
        let restMood = avgMood(restWithMood)
        let delta = workoutMood - restMood

        let text: String
        let state: String
        let confidence: String

        if delta >= 0.2 {
            state = "mood_boost"; confidence = "high"
            text = "Mood is noticeably better on workout days; exercise appears to positively affect emotional state — may respond well to reminders framed around mood benefit."
        } else if delta <= -0.15 {
            state = "mood_drain"; confidence = "medium"
            text = "Mood tends to be lower on workout days; may push through exercise when already depleted, or training sessions coincide with higher-stress periods."
        } else {
            state = "neutral"; confidence = "medium"
            text = "No clear mood difference between workout and rest days; exercise motivation is likely goal-driven rather than mood-driven."
        }

        let evidenceStr = String(
            format: "workout-day mood %.2f vs rest-day %.2f (delta %.2f, n=%d/%d)",
            workoutMood, restMood, delta, workoutWithMood.count, restWithMood.count
        )
        return TierTwoMemoryRecord(
            category: "workout_mood_correlation",
            text: text,
            state: state,
            evidence: evidenceStr,
            confidence: confidence,
            dataWindowDays: window.count
        )
    }

    private static func moodScore(_ tag: FeelingTag) -> Double {
        switch tag {
        case .bright: return 1
        case .good: return 0.85
        case .neutral: return 0.65
        case .quiet: return 0.55
        case .tired: return 0.35
        case .hard: return 0.2
        }
    }
}
