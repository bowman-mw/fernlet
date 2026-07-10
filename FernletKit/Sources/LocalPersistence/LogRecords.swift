//
//  LogRecords.swift
//  Fernlet
//
//  Derived-table DTO records persisted alongside the LocalFernletDatabase.
//

import Foundation
import FernletDomainModel

public struct DailyLogRecord: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var dateKey: String
    public var weight: Double?
    public var sleepHours: Double?
    public var sleepQuality: SleepQuality?
    public var workoutCompleted: Bool
    public var proteinGrams: Int
    public var calories: Int
    public var micronutrients: Micronutrients
    public var location: String?
    public var notes: String?

    public init(dateKey: String, day: FernletDay) {
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        dateKey = try container.decode(String.self, forKey: .dateKey)
        weight = try container.decodeIfPresent(Double.self, forKey: .weight)
        sleepHours = try container.decodeIfPresent(Double.self, forKey: .sleepHours)
        // Tolerant: a quality token only a newer build knows resolves to nil instead of throwing
        // (a throw here bricks the whole blob decode into read-only recovery). No parked-token side
        // channel — this derived table is rebuilt from the source days (`rebuildDerivedTables`),
        // so a frozen value costs nothing.
        sleepQuality = try container.decodeIfPresent(String.self, forKey: .sleepQuality)
            .flatMap(SleepQuality.init(rawValue:))
        workoutCompleted = try container.decode(Bool.self, forKey: .workoutCompleted)
        proteinGrams = try container.decode(Int.self, forKey: .proteinGrams)
        calories = try container.decode(Int.self, forKey: .calories)
        micronutrients = try container.decodeIfPresent(Micronutrients.self, forKey: .micronutrients) ?? Micronutrients()
        location = try container.decodeIfPresent(String.self, forKey: .location)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

public struct MealLogRecord: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var dateKey: String
    public var mealType: MealType
    public var description: String
    public var calories: Int
    public var protein: Int
    public var carbs: Int
    public var fat: Int
    public var micronutrients: Micronutrients
    public var source: String
    public var dailyCalorieTotal: Int
    public var dailyProteinTotal: Int

    public init(dateKey: String, meal: Meal, totals: MacroTotals) {
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        dateKey = try container.decode(String.self, forKey: .dateKey)
        // Tolerant freeze (no park): derived table, rebuilt from the source days — see
        // DailyLogRecord.sleepQuality.
        mealType = try container.decodeIfPresent(String.self, forKey: .mealType)
            .flatMap(MealType.init(rawValue:)) ?? .snack
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

public struct WorkoutLogRecord: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var dateKey: String
    public var type: WorkoutType
    public var exercises: String
    public var rpe: Double?
    public var notes: String

    public init(dateKey: String, workout: Workout) {
        assert(!dateKey.isEmpty, "date key required")
        assert(workout.duration == nil || workout.duration! >= 0, "duration invalid")
        self.dateKey = dateKey
        self.type = workout.type
        self.exercises = workout.exercises
        self.rpe = workout.rpe
        self.notes = workout.notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        dateKey = try container.decode(String.self, forKey: .dateKey)
        // Tolerant freeze (no park): derived table, rebuilt from the source days — see
        // DailyLogRecord.sleepQuality.
        type = try container.decodeIfPresent(String.self, forKey: .type)
            .flatMap(WorkoutType.init(rawValue:)) ?? .fullBody
        exercises = try container.decode(String.self, forKey: .exercises)
        rpe = try container.decodeIfPresent(Double.self, forKey: .rpe)
        notes = try container.decode(String.self, forKey: .notes)
    }
}

public struct JournalLogRecord: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var dateKey: String
    public var tag: FeelingTag
    public var text: String
    public var emotions: [String]

    public init(dateKey: String, journal: JournalEntry) {
        assert(!dateKey.isEmpty, "date key required")
        assert(journal.text.count <= FernletLimits.maxJournalCharacters, "journal too long")
        self.dateKey = dateKey
        self.tag = journal.tag
        self.text = journal.text
        self.emotions = Array(journal.emotions.prefix(FernletLimits.maxEmotionKeys))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        dateKey = try container.decode(String.self, forKey: .dateKey)
        // Tolerant freeze (no park): derived table, rebuilt from the source days — see
        // DailyLogRecord.sleepQuality.
        tag = try container.decodeIfPresent(String.self, forKey: .tag)
            .flatMap(FeelingTag.init(rawValue:)) ?? .neutral
        text = try container.decode(String.self, forKey: .text)
        emotions = try container.decode([String].self, forKey: .emotions)
    }
}

public struct DerivedSignalRecord: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var signalName: String
    public var value: String
    public var computedAt = Date()
    public var windowStart: String
    public var windowEnd: String
    public var sourceFields: [String]
    public var nutrientGaps: [NutrientGap]

    public init(
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

    public init(from decoder: Decoder) throws {
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

// AIAnalysisRetryRecord and TierTwoMemoryRecord were carved DOWN into the FernletDomainModel module
// (FernletKit/Sources/FernletDomainModel/) so the persistence layer can reference them without an
// upward edge. See AIAnalysisRetryRecord.swift / TierTwoMemoryRecord.swift there.
