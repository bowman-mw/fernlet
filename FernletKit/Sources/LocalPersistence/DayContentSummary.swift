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

/// A precomputed, counts-only roll-up of day content carried inside the aggregate
/// ``LocalFernletDatabase`` blob.
///
/// Exists so iCloud "existing data" detection can stay a single-record read once the per-row day
/// split retires the blob's `days` cache (Stage B): another device reads the blob's summary
/// instead of fetching and decoding thousands of per-row `DayRecord` CKRecords just to count
/// them. The Core Data path (`CoreDataFernletRepository`, `CloudKitDataService`) recomputes it
/// from the same bounded recent-day window the derived tables use on each save; the
/// local/no-iCloud path leaves it at ``empty`` because it performs no cloud detection. It carries
/// counts only — never day payloads — so it is safe in the synced blob. Note the counting rules
/// differ by field: meals, journals, workouts, and hygiene count individual entries, while
/// hydration and sleep count *days* that logged any (at most 1 per day).
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

    /// Recomputes the roll-up from a window of days using the shared counting rules
    /// (per-entry for meals/journals/workouts/hygiene; per-day for hydration and sleep).
    ///
    /// Both writers — `CoreDataFernletRepository` on save and `CloudKitDataService` during
    /// detection reconciliation — use this same initializer, so the counts they compare are
    /// consistent by construction.
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

    /// The all-zero summary — the state of a fresh database and of the local/no-iCloud path,
    /// which never populates the roll-up.
    public static let empty = DayContentSummary()

    /// Whether any content at all was counted — the single bit iCloud "existing data"
    /// detection actually needs from the blob.
    public var hasAny: Bool {
        mealCount + journalCount + workoutCount + hygieneCount + hydrationCount + sleepCount > 0
    }
}
