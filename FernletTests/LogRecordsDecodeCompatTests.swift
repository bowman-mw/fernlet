// LogRecordsDecodeCompatTests.swift
// Forward-compatibility of the derived log-record DTOs persisted in the blob (dailyLogs/mealLogs/
// workoutLogs/journalLogs). These are freeze-only (no parked-token side channels): an enum raw
// value only a NEWER build knows resolves to the field default instead of throwing (a throw would
// brick the whole blob decode), and nothing is lost because the tables are rebuilt from the source
// days (`rebuildDerivedTables`).

import Foundation
import Testing
import FernletDomainModel
import LocalPersistence

struct LogRecordsDecodeCompatTests {
    @Test func unknownSleepQualityInDailyLogResolvesToNil() throws {
        let record = try decode(DailyLogRecord.self, """
        {
          "dateKey": "2026-07-10",
          "sleepHours": 7.5,
          "sleepQuality": "refreshing",
          "workoutCompleted": true,
          "proteinGrams": 120,
          "calories": 2100
        }
        """)
        #expect(record.sleepQuality == nil)
        #expect(record.sleepHours == 7.5)
        #expect(record.workoutCompleted)

        let known = try decode(DailyLogRecord.self, """
        {"dateKey": "2026-07-10", "sleepQuality": "good", "workoutCompleted": false,
         "proteinGrams": 0, "calories": 0}
        """)
        #expect(known.sleepQuality == .good)
    }

    @Test func unknownMealTypeInMealLogFreezesToSnack() throws {
        let record = try decode(MealLogRecord.self, """
        {
          "dateKey": "2026-07-10",
          "mealType": "Dessert",
          "description": "Affogato",
          "calories": 180, "protein": 4, "carbs": 20, "fat": 9,
          "dailyCalorieTotal": 1800, "dailyProteinTotal": 90
        }
        """)
        #expect(record.mealType == .snack)
        #expect(record.description == "Affogato")
    }

    @Test func unknownWorkoutTypeInWorkoutLogFreezesToFullBody() throws {
        let record = try decode(WorkoutLogRecord.self, """
        {"dateKey": "2026-07-10", "type": "Mobility", "exercises": "flow", "notes": ""}
        """)
        #expect(record.type == .fullBody)
        #expect(record.exercises == "flow")

        let known = try decode(WorkoutLogRecord.self, """
        {"dateKey": "2026-07-10", "type": "Upper", "exercises": "bench", "rpe": 7, "notes": "n"}
        """)
        #expect(known.type == .upper)
        #expect(known.rpe == 7)
    }

    @Test func unknownFeelingTagInJournalLogFreezesToNeutral() throws {
        let record = try decode(JournalLogRecord.self, """
        {"dateKey": "2026-07-10", "tag": "sparkly", "text": "went outside", "emotions": ["calm"]}
        """)
        #expect(record.tag == .neutral)
        #expect(record.text == "went outside")
        #expect(record.emotions == ["calm"])
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
