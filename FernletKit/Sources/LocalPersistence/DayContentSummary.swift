// DayContentSummary.swift
// LocalPersistence
//
// A tiny precomputed roll-up of day content (counts only — no day payloads) carried in the aggregate
// FernletDatabaseRecord blob. Once the per-row day split retires the blob's `days` cache (Stage B), this
// is what lets iCloud "existing data" detection stay a single-record read: another device reads the
// blob's summary instead of fetching and decoding thousands of per-row DayRecord CKRecords to count them.
//
// The summary reflects the same bounded recent window the derived tables use (it is recomputed from that
// window on each save), so it matches the counts detection reported before the blob's days were cleared.

import Foundation
import FernletDomainModel

public nonisolated struct DayContentSummary: Codable, Equatable, Sendable {
    public var mealCount: Int
    public var journalCount: Int
    public var workoutCount: Int
    public var hygieneCount: Int
    public var hydrationCount: Int
    public var sleepCount: Int

    public init(
        mealCount: Int = 0,
        journalCount: Int = 0,
        workoutCount: Int = 0,
        hygieneCount: Int = 0,
        hydrationCount: Int = 0,
        sleepCount: Int = 0
    ) {
        self.mealCount = mealCount
        self.journalCount = journalCount
        self.workoutCount = workoutCount
        self.hygieneCount = hygieneCount
        self.hydrationCount = hydrationCount
        self.sleepCount = sleepCount
    }

    public init(days: [FernletDay]) {
        var meals = 0, journals = 0, workouts = 0, hygiene = 0, hydration = 0, sleep = 0
        for day in days {
            meals += day.meals.count
            journals += day.journals.count
            workouts += day.workouts.count
            hygiene += day.hygiene.count
            hydration += day.bottleCount > 0 ? 1 : 0
            sleep += day.sleep == nil ? 0 : 1
        }
        self.init(
            mealCount: meals,
            journalCount: journals,
            workoutCount: workouts,
            hygieneCount: hygiene,
            hydrationCount: hydration,
            sleepCount: sleep
        )
    }

    public static let empty = DayContentSummary()

    public var hasAny: Bool {
        mealCount + journalCount + workoutCount + hygieneCount + hydrationCount + sleepCount > 0
    }
}
