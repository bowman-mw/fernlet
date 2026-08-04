//
//  LogRecords.swift
//  Fernlet
//
//  Derived-table DTO records persisted alongside the LocalFernletDatabase.
//

import Foundation
import FernletDomainModel

/// One derived-table row summarizing a whole day: sleep, a workout-completed flag, and macro +
/// micronutrient totals.
///
/// Built by `LocalFernletDatabase.rebuildDerivedTables(todayKey:recentDays:)` — one row per day
/// in the recent window — and persisted in the ``LocalFernletDatabase`` blob for the AI-context
/// and trend surfaces to read without re-deriving from raw days. Rows are disposable: every save
/// rebuilds them from the source `FernletDay`s, which is why the tolerant `init(from:)` may
/// freeze an unknown `sleepQuality` token to nil instead of failing the whole blob decode.
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

    /// Builds the row from a stored day. Note `weight`, `location`, and `notes` are left nil —
    /// they exist only as decodable legacy fields.
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
        // Value-tolerant: a quality token only a newer build knows resolves to nil instead of
        // throwing (a throw here bricks the whole blob decode into read-only recovery). No
        // parked-token side channel — this derived table is rebuilt from the source days
        // (`rebuildDerivedTables`), so a frozen value costs nothing. The key itself stays optional,
        // matching the historical `decodeIfPresent`.
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

/// One derived-table row per logged meal, carrying the meal's macros plus the day's running
/// totals for context.
///
/// Built by `LocalFernletDatabase.rebuildDerivedTables(todayKey:recentDays:)` (clamped by
/// ``FernletLimits/maxMealsPerDay`` and ``FernletLimits/maxMealLogs``) and persisted in the
/// ``LocalFernletDatabase`` blob. Disposable and rebuilt on every save; its decoder freezes an
/// unknown `mealType` token to `.snack` while keeping the key itself required, so a genuinely
/// truncated blob still surfaces as a decode failure.
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
        // Value-tolerant freeze (no park): derived table, rebuilt from the source days — see
        // DailyLogRecord.sleepQuality. The KEY stays required (historically strict `decode`):
        // a missing key is corruption/truncation and must keep surfacing as a decode failure.
        mealType = MealType(rawValue: try container.decode(String.self, forKey: .mealType)) ?? .snack
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

/// One derived-table row per logged workout: type, exercise text, RPE, and notes.
///
/// Built by `LocalFernletDatabase.rebuildDerivedTables(todayKey:recentDays:)` (clamped by
/// ``FernletLimits/maxWorkoutsPerDay`` and ``FernletLimits/maxWorkoutLogs``) and persisted in the
/// ``LocalFernletDatabase`` blob. Disposable and rebuilt on every save; its decoder freezes an
/// unknown `type` token to `.fullBody` while keeping the key required (missing key = corruption).
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
        // Value-tolerant freeze (no park): derived table, rebuilt from the source days — see
        // DailyLogRecord.sleepQuality. The KEY stays required (historically synthesized-strict):
        // a missing key is corruption/truncation and must keep surfacing as a decode failure.
        type = WorkoutType(rawValue: try container.decode(String.self, forKey: .type)) ?? .fullBody
        exercises = try container.decode(String.self, forKey: .exercises)
        rpe = try container.decodeIfPresent(Double.self, forKey: .rpe)
        notes = try container.decode(String.self, forKey: .notes)
    }
}

/// One derived-table row per journal entry: feeling tag, entry text, and emotion keys.
///
/// Built by `LocalFernletDatabase.rebuildDerivedTables(todayKey:recentDays:)` (clamped by
/// ``FernletLimits/maxJournalsPerDay``, ``FernletLimits/maxJournalLogs``, and
/// ``FernletLimits/maxEmotionKeys``) and persisted in the ``LocalFernletDatabase`` blob. The
/// `text` comes from days that passed the sanitizing snapshot seam, so sealed-journal bodies
/// arrive already blanked and never reach this table. Disposable and rebuilt on every save; its
/// decoder freezes an unknown `tag` token to `.neutral`, key still required.
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
        // Value-tolerant freeze (no park): derived table, rebuilt from the source days — see
        // DailyLogRecord.sleepQuality. The KEY stays required (historically synthesized-strict):
        // a missing key is corruption/truncation and must keep surfacing as a decode failure.
        tag = FeelingTag(rawValue: try container.decode(String.self, forKey: .tag)) ?? .neutral
        text = try container.decode(String.self, forKey: .text)
        emotions = try container.decode([String].self, forKey: .emotions)
    }
}

/// One computed behavioral signal (for example `moodTrend` → "improving") with its window bounds
/// and data provenance.
///
/// Produced in sets of seven by ``DerivedSignalFactory`` and held in store state — unlike the
/// log-record tables, these are NOT persisted in the ``LocalFernletDatabase`` blob; they are
/// recomputed on demand by `DerivedSignalsService`/`DerivedSignalsRebuilder` (in `StoreCore`).
/// `sourceFields` names the day fields that fed the computation (provenance the UI can surface),
/// and `nutrientGaps` carries the structured gap list for the micronutrient signals. The
/// tolerant decoder defaults `id`, `computedAt`, and `nutrientGaps` so older encodings decode.
public struct DerivedSignalRecord: Identifiable, Codable, Equatable {
    public var id = UUID()
    /// Stable signal identifier (`moodTrend`, `energyTrend`, `eatingPattern`, `progressionTrend`,
    /// `intensityReadiness`, `micronutrientGaps7Day`, `micronutrientGaps14Day`).
    public var signalName: String
    /// Short lowercase phrase surfaced directly in UI and AI context ("needs gentleness",
    /// "ready for hard", "2 possible gaps").
    public var value: String
    public var computedAt = Date()
    /// First day key of the window the signal was computed over.
    public var windowStart: String
    /// Last day key of the window the signal was computed over.
    public var windowEnd: String
    /// The day fields that fed the computation — provenance the transparency UI can show.
    public var sourceFields: [String]
    /// Structured micronutrient gap details; empty for the non-nutrient signals.
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
