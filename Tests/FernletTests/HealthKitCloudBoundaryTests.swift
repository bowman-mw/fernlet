import Foundation
import Testing
import CloudKitSync
import FernletFoundation
import FernletDomainModel
@testable import FernletPersistence
@testable import Fernlet

/// "HealthKit information shouldn't be stored in iCloud" (owner decision 2026-09-23; App Review
/// 5.1.3(ii)) — the sanitize boundary, the device-local residue that keeps this device working, and
/// the store paths between them.
///
/// Three layers, each pinned separately:
/// - **Classification.** Every stored field of the health-bearing types is listed below with its
///   verdict (HealthKit / user-authored / mixed). A field added to any of them fails
///   ``everyStoredFieldOfTheHealthBearingTypesIsClassified()`` until someone decides which it is; a
///   field added to a HealthKit sub-struct also fails ``theSentinelFixtureFillsEveryHealthKitField()``
///   until the fixture sets it — which is what makes the sentinel strip checks cover it.
/// - **The boundary.** `SanitizedDay` / `SanitizedSnapshot` output, JSON-encoded exactly as a synced
///   row or blob would be, carries no HealthKit value, and keeps what the user typed.
/// - **This device.** The residue the strip removes comes back on read, today's across a relaunch and
///   a past day's into its score, and never reaches a row or a device that did not read it.
@MainActor
@Suite
struct HealthKitCloudBoundaryTests {

    // MARK: - Classification

    /// `FernletDay` fields the user authors (they sync unchanged).
    private static let userAuthoredDayFields: Set<String> = [
        "date", "meals", "plannedWorkouts", "journals", "bottleCount", "hygiene", "unknownHygieneTokens",
        "completedPersonalCareTaskIDs", "plannedRecipeIDs", "plannedMeals"
    ]
    /// `FernletDay` fields that mix the two: `sleep` (hours may be HealthKit's), `workouts` (Apple
    /// Health imports are HealthKit's; Fernlet logs, authored ones included, are the user's).
    private static let mixedDayFields: Set<String> = ["sleep", "workouts"]
    /// `FernletDay` fields that are HealthKit's through and through (dropped whole).
    private static let healthKitDayFields: Set<String> = ["healthContext"]

    /// `HealthDailyContext` — every field READ from HealthKit (plus the device-local sleep marker);
    /// the whole context is dropped, so a new field is stripped automatically, but it must be
    /// consciously added here (and to the sentinel fixture).
    private static let healthContextFields: Set<String> = [
        "syncedAt", "activity", "body", "cycle", "mindfulness", "intimate", "healthKitSleepLogHours"
    ]

    /// `DailyHealthScore`: the two raw HealthKit contexts and the cycle label are stripped before
    /// storage; the rest is the app's own computation and bookkeeping and syncs (the composite
    /// score/components are an app index, not HealthKit data — see the round report).
    private static let strippedScoreFields: Set<String> = ["healthActivityContext", "healthBodyContext", "periodPhase"]
    private static let keptScoreFields: Set<String> = [
        "id", "dateKey", "score", "companionState", "unknownCompanionStateToken", "daySummaryText",
        "computedAt", "componentScores", "weightVector", "sicknessOverride"
    ]

    /// `SleepLog`: `hours` is HealthKit's when it equals the context's marker/body reading.
    private static let sleepLogFields: Set<String> = ["hours", "quality", "unknownQualityToken", "note", "loggedAt"]

    @Test func everyStoredFieldOfTheHealthBearingTypesIsClassified() {
        #expect(Self.labels(of: FernletDay(date: "2026-01-01"))
                == Self.userAuthoredDayFields.union(Self.mixedDayFields).union(Self.healthKitDayFields))
        #expect(Self.labels(of: HealthDailyContext()) == Self.healthContextFields)
        #expect(Self.labels(of: DailyHealthScore(dateKey: "d", score: 0, companionState: .okay, computedAt: .now))
                == Self.strippedScoreFields.union(Self.keptScoreFields))
        #expect(Self.labels(of: SleepLog(quality: .ok, note: "")) == Self.sleepLogFields)
        #expect(Self.labels(of: DeviceHealthResidue(context: nil, importedWorkouts: [])) == ["context", "importedWorkouts"])
    }

    /// The sentinel fixture must set EVERY optional field of every HealthKit sub-struct — so a field
    /// added later (a respiratory rate, a wrist temperature) is either set here, and therefore checked
    /// by the strip tests below, or fails this cell.
    @Test func theSentinelFixtureFillsEveryHealthKitField() {
        let context = Self.sentinelContext()
        #expect(Self.nilChildren(of: context).isEmpty)
        for group in [context.activity as Any, context.body as Any, context.body?.sleepStages as Any,
                      context.cycle as Any, context.mindfulness as Any, context.intimate as Any] {
            #expect(Self.nilChildren(of: Self.unwrapped(group)).isEmpty, "unset field in \(group)")
        }
    }

    // MARK: - The boundary

    @Test func aSanitizedDayCarriesNoHealthKitValue() throws {
        let stripped = SanitizedDay.sanitizing(Self.sentinelDay(), sealedJournalIDs: []).day
        let json = try Self.encodedString(stripped)
        #expect(!json.contains("healthContext"))
        for sentinel in Self.sentinelStrings {
            #expect(!json.contains(sentinel), "HealthKit value \(sentinel) reached the synced day payload")
        }
        #expect(stripped.healthContext == nil)
        #expect(stripped.sleep?.hours == nil)
        #expect(!stripped.workouts.contains { $0.id == Self.importedWorkoutID })
        #expect(!stripped.carriesHealthKitValues)
    }

    @Test func aSanitizedSnapshotCarriesNoHealthKitValueInTheDayOrTheScores() throws {
        var score = DailyHealthScore(dateKey: "2026-09-20", score: 0.7, companionState: .okay, computedAt: .now)
        score.healthActivityContext = Self.sentinelContext().activity
        score.healthBodyContext = Self.sentinelContext().body
        score.periodPhase = "luteal"
        let snapshot = FernletSnapshot(
            todayKey: "2026-09-20", day: Self.sentinelDay(), settings: FernletSettings(), recentMeals: [],
            previousJournals: [], memories: [], goals: [], workshop: WorkshopData(), dailyScores: [score]
        )
        let stored = SanitizedSnapshot.sanitizing(snapshot, sealedJournalIDs: []).snapshot
        let json = try Self.encodedString(stored)
        for sentinel in Self.sentinelStrings {
            #expect(!json.contains(sentinel), "HealthKit value \(sentinel) reached the synced blob")
        }
        #expect(stored.dailyScores.allSatisfy {
            $0.healthActivityContext == nil && $0.healthBodyContext == nil && $0.periodPhase == nil
        })
        #expect(stored.dailyScores.first?.score == 0.7)    // the app's own index survives
    }

    @Test func userAuthoredValuesSurviveTheStrip() {
        let authored = Workout(name: "Fernlet Run", type: .cardio, exercises: "run", rpe: 6, notes: "mine",
                               duration: 30, healthKitUUID: UUID(), healthKitAuthored: true, intensity: .moderate)
        let logged = Workout(name: "Push", type: .upper, exercises: "bench", rpe: 7, notes: "", duration: 40,
                             intensity: .hard)
        var day = Self.sentinelDay()
        day.sleep = SleepLog(hours: 8.5, quality: .good, note: "woke once")   // typed, ≠ HealthKit's 6.3
        day.workouts = [authored, logged] + day.workouts
        let stripped = SanitizedDay.sanitizing(day, sealedJournalIDs: []).day
        #expect(stripped.sleep?.hours == 8.5)
        #expect(stripped.sleep?.quality == .good)
        #expect(stripped.sleep?.note == "woke once")
        #expect(stripped.workouts.map(\.id) == [authored.id, logged.id])
        #expect(stripped.bottleCount == day.bottleCount)
        #expect(stripped.hygiene == day.hygiene)
    }

    /// HealthKit's hours with the user's own rating on the log: the hours go, the rating stays. A log
    /// left holding only the defaults HealthKit sync fills in is dropped whole (it would plant a
    /// rating the user never gave on every other device).
    @Test func healthKitSleepHoursLeaveTheUsersRatingBehind() {
        var rated = Self.sentinelDay()
        rated.sleep = SleepLog(hours: Self.sleepHours, quality: .great, note: "")
        #expect(SanitizedDay.sanitizing(rated, sealedJournalIDs: []).day.sleep == SleepLog(
            hours: nil, quality: .great, note: "", loggedAt: rated.sleep?.loggedAt ?? .now))

        var shell = Self.sentinelDay()
        shell.sleep = SleepLog(hours: Self.sleepHours, quality: .ok, note: "")
        #expect(SanitizedDay.sanitizing(shell, sealedJournalIDs: []).day.sleep == nil)
    }

    /// After 18:00 a refresh reads tonight's window (no sleep yet) and `merge` replaces `body` with
    /// one whose `sleepHours` is nil — while the log still holds last night's HealthKit hours. The
    /// marker is what still recognizes them.
    @Test func healthKitSleepHoursAreRecognizedAfterTheEveningWindowSwitch() {
        var day = FernletDay(date: "2026-09-20", sleep: SleepLog(hours: 7.4, quality: .ok, note: "restless"))
        day.healthContext = HealthDailyContext(body: HealthBodyContext(sleepHours: nil, restingHeartRateBPM: 52),
                                               healthKitSleepLogHours: 7.4)
        let stripped = SanitizedDay.sanitizing(day, sealedJournalIDs: []).day
        #expect(stripped.sleep?.hours == nil)
        #expect(stripped.sleep?.note == "restless")
    }

    @Test func theOverlayRestoresExactlyWhatTheStripRemoved() throws {
        let day = Self.sentinelDay()
        let residue = try #require(day.healthKitResidue)
        let restored = day.strippingHealthKitValues().overlayingHealthKitResidue(residue)
        var expectedContext = Self.sentinelContext()
        expectedContext.cycle = nil        // never carried, even device-locally
        expectedContext.intimate = nil
        #expect(restored.healthContext == expectedContext)
        #expect(restored.sleep?.hours == Self.sleepHours)
        #expect(Set(restored.workouts.map(\.id)) == Set(day.workouts.map(\.id)))
        // Idempotent, and the strip of a restored day is the strip of the original.
        #expect(restored.overlayingHealthKitResidue(residue).workouts.count == restored.workouts.count)
        #expect(try Self.encodedString(restored.strippingHealthKitValues())
                == Self.encodedString(day.strippingHealthKitValues()))
    }

    // MARK: - This device

    /// Today's readings survive a relaunch on THIS device (same cache), never reach the row, and do
    /// not appear on a device that did not read them (same synced rows, its own empty cache).
    @Test func todaysReadingsSurviveARelaunchOnThisDeviceOnly() throws {
        let date = try Self.date("2026-09-20")
        let cache = InMemoryDeviceHealthResidueStore()
        let first = makeTestStoreWithRepositories(date: date, deviceHealthResidueStore: cache)
        first.store.addBottle()   // user content, so today's row exists
        first.store.updateHealthContext(Self.ingestedContext())
        #expect(first.store.flushPendingSnapshotSave())

        let row = try #require(first.repository.loadAllDays()["2026-09-20"])
        #expect(row.healthContext == nil)
        #expect(row.sleep == nil)          // HealthKit created that log; nothing of it syncs
        #expect(row.bottleCount == 1)

        let relaunched = makeStoreSharingStores(date: date, repository: first.repository,
                                                narratives: first.narratives, deviceHealthResidueStore: cache)
        #expect(relaunched.day.healthContext?.activity?.steps == 12_000)
        #expect(relaunched.day.sleep?.hours == 7.2)
        #expect(relaunched.score == first.store.score)

        let otherDevice = makeStoreSharingStores(date: date, repository: first.repository, narratives: first.narratives)
        #expect(otherDevice.day.healthContext == nil)
        #expect(otherDevice.day.sleep == nil)
        #expect(otherDevice.day.bottleCount == 1)
    }

    /// A past day's score on this device still uses its HealthKit readings, read back from the cache.
    @Test func aPastDayScoresWithItsDeviceLocalReadings() throws {
        let cache = InMemoryDeviceHealthResidueStore()
        let first = makeTestStoreWithRepositories(date: try Self.date("2026-09-19"), deviceHealthResidueStore: cache)
        first.store.addBottle()
        first.store.updateHealthContext(Self.ingestedContext())
        #expect(first.store.flushPendingSnapshotSave())
        let originalScore = first.store.score(for: first.store.day)

        let nextDay = makeStoreSharingStores(date: try Self.date("2026-09-20"), repository: first.repository,
                                             narratives: first.narratives, deviceHealthResidueStore: cache)
        let past = nextDay.loadDay(for: "2026-09-19")
        #expect(past.healthContext?.body?.restingHeartRateBPM == 51)
        #expect(nextDay.score(for: past) == originalScore)
        // …and the readings matter: without them the same day scores differently.
        #expect(nextDay.score(for: past.strippingHealthKitValues()) != originalScore)
        #expect(nextDay.loadDays()["2026-09-19"]?.healthContext != nil)
    }

    /// Re-submitting HealthKit's prefilled hours with a new rating from the past-day editor keeps the
    /// hours HealthKit's: off the row, back on read.
    @Test func aPastDayEditKeepsHealthKitSleepOutOfTheRow() throws {
        let cache = InMemoryDeviceHealthResidueStore()
        let first = makeTestStoreWithRepositories(date: try Self.date("2026-09-19"), deviceHealthResidueStore: cache)
        first.store.addBottle()
        first.store.updateHealthContext(Self.ingestedContext())
        #expect(first.store.flushPendingSnapshotSave())
        let nextDay = makeStoreSharingStores(date: try Self.date("2026-09-20"), repository: first.repository,
                                             narratives: first.narratives, deviceHealthResidueStore: cache)

        nextDay.setSleep(hours: 7.2, quality: .great, note: "", date: "2026-09-19")

        let row = try #require(first.repository.loadAllDays()["2026-09-19"])
        #expect(row.sleep?.hours == nil)
        #expect(row.sleep?.quality == .great)
        #expect(row.healthContext == nil)
        #expect(nextDay.loadDay(for: "2026-09-19").sleep?.hours == 7.2)
        #expect(nextDay.loadDay(for: "2026-09-19").sleep?.quality == .great)
    }

    /// An Apple Health import stays on this device — today's and a past day's — and a Health-side
    /// deletion removes it from the cache as well.
    @Test func importedWorkoutsStayOnThisDevice() throws {
        let date = try Self.date("2026-09-20")
        let cache = InMemoryDeviceHealthResidueStore()
        let first = makeTestStoreWithRepositories(date: date, deviceHealthResidueStore: cache)
        let today = Self.importedWorkout(id: UUID())
        let yesterday = Self.importedWorkout(id: UUID())
        first.store.addBottle()
        first.store.upsertWorkout(today, date: "2026-09-20")
        first.store.upsertWorkout(yesterday, date: "2026-09-19")
        #expect(first.store.flushPendingSnapshotSave())

        let rows = first.repository.loadAllDays()
        #expect(rows["2026-09-20"]?.workouts.isEmpty == true)
        #expect(rows["2026-09-19"] == nil)    // an import-only day writes no row at all
        let relaunched = makeStoreSharingStores(date: date, repository: first.repository,
                                                narratives: first.narratives, deviceHealthResidueStore: cache)
        #expect(relaunched.day.workouts.map(\.id) == [today.id])
        #expect(relaunched.loadDay(for: "2026-09-19").workouts.map(\.id) == [yesterday.id])
        #expect(relaunched.workoutExists(healthKitUUID: try #require(yesterday.healthKitUUID)))

        relaunched.removeWorkoutByHealthKitUUID(try #require(today.healthKitUUID))
        #expect(cache.residue(for: "2026-09-20")?.importedWorkouts.isEmpty ?? true)
    }

    @Test func resetAllEmptiesTheDeviceCache() throws {
        let cache = InMemoryDeviceHealthResidueStore()
        let store = makeTestStore(date: try Self.date("2026-09-20"), deviceHealthResidueStore: cache)
        store.updateHealthContext(Self.ingestedContext())
        #expect(cache.residue(for: "2026-09-20") != nil)
        // A test store has no stress service or Worry Box wired, so `resetAll` names those two; the
        // cache must not be among what it names.
        #expect(!store.resetAll().contains("your cached Apple Health readings"))
        #expect(cache.allResidues().isEmpty)
        #expect(store.day.healthContext == nil)
    }

    /// Ingestion marks HealthKit's hours, and the mark outlives the evening refresh that replaces
    /// `body` with an empty sleep reading — so the strip still recognizes them at 23:00.
    @Test func ingestionMarksHealthKitSleepHoursThroughTheEveningRefresh() throws {
        let store = makeTestStore(date: try Self.date("2026-09-20"))
        store.updateHealthContext(Self.ingestedContext())
        #expect(store.day.healthContext?.healthKitSleepLogHours == 7.2)
        store.updateHealthContext(HealthDailyContext(body: HealthBodyContext(sleepHours: nil, restingHeartRateBPM: 49)))
        #expect(store.day.healthContext?.body?.sleepHours == nil)
        #expect(store.day.sleep?.hours == 7.2)
        #expect(SanitizedDay.sanitizing(store.day, sealedJournalIDs: []).day.sleep == nil)
    }

    /// The one-time launch scrub rewrites a row an older build synced, keeping its readings here —
    /// and runs once.
    @Test func theLegacyScrubStripsOldRowsAndKeepsTheirReadingsHere() throws {
        let cache = InMemoryDeviceHealthResidueStore()
        let built = makeTestStoreWithRepositories(date: try Self.date("2026-09-20"), deviceHealthResidueStore: cache)
        var legacy = Self.sentinelDay()
        legacy.date = "2026-09-18"
        legacy.bottleCount = 2
        #expect(DayRecordRepository(controller: built.repository.persistenceController)
            .upsert([DayRecordUpsert(day: legacy, updatedAt: .now)]))

        built.store.scrubLegacySyncedHealthKitValuesIfNeeded(captureEnabled: true)

        let row = try #require(DayRecordRepository(controller: built.repository.persistenceController).loadAll()["2026-09-18"])
        #expect(!row.carriesHealthKitValues)
        #expect(row.bottleCount == 2)
        #expect(cache.residue(for: "2026-09-18")?.context?.activity?.steps == Self.steps)
        #expect(cache.legacySyncedRowsScrubbed)
        #expect(built.store.loadDay(for: "2026-09-18").healthContext?.activity?.steps == Self.steps)
    }

    @Test func theLegacyScrubKeepsNothingWhileHealthKitIsOff() throws {
        let cache = InMemoryDeviceHealthResidueStore()
        let built = makeTestStoreWithRepositories(date: try Self.date("2026-09-20"), deviceHealthResidueStore: cache)
        var legacy = Self.sentinelDay()
        legacy.date = "2026-09-18"
        legacy.bottleCount = 2
        #expect(DayRecordRepository(controller: built.repository.persistenceController)
            .upsert([DayRecordUpsert(day: legacy, updatedAt: .now)]))

        built.store.scrubLegacySyncedHealthKitValuesIfNeeded(captureEnabled: false)

        #expect(cache.allResidues().isEmpty)
        #expect(built.store.loadDay(for: "2026-09-18").healthContext == nil)
    }

    // MARK: - Fixtures

    private static let steps = 91_357
    private static let sleepHours = 6.3
    private static let importedWorkoutID = UUID(uuidString: "0000A11C-0000-4000-8000-00000000BEEF") ?? UUID()
    /// Every number in the sentinel fixture, spelled as JSONEncoder spells it. Exact binary
    /// fractions, so the spelling is stable.
    private static let sentinelStrings = ["91357", "8137.25", "713.5", "43.25", "188.75", "97.25", "213.75",
                                          "111.25", "17.75", "422.25", "33.75", "Sentinel Import Walk"]

    private static func sentinelContext() -> HealthDailyContext {
        HealthDailyContext(
            syncedAt: Date(timeIntervalSince1970: 1_790_000_000),
            activity: HealthActivitySummary(steps: steps, activeEnergyKilocalories: 8137.25, exerciseMinutes: 713.5),
            body: HealthBodyContext(
                sleepHours: sleepHours, restingHeartRateBPM: 43.25, heartRateVariabilityMS: 188.75,
                sleepStages: SleepStagesData(deepMinutes: 97.25, coreMinutes: 213.75, remMinutes: 111.25,
                                             awakeMinutes: 17.75, totalAsleepMinutes: 422.25)
            ),
            cycle: HealthCycleContext(menstrualFlowEventCount: 7, latestCycleEventAt: Date(timeIntervalSince1970: 1_790_000_500)),
            mindfulness: HealthMindfulnessContext(mindfulSessionMinutes: 33.75),
            intimate: HealthIntimateContext(eventCount: 5),
            healthKitSleepLogHours: sleepHours
        )
    }

    private static func sentinelDay() -> FernletDay {
        FernletDay(
            date: "2026-09-20",
            workouts: [importedWorkout(id: importedWorkoutID)],
            sleep: SleepLog(hours: sleepHours, quality: .ok, note: ""),
            bottleCount: 3,
            hygiene: [.shower],
            healthContext: sentinelContext()
        )
    }

    private static func importedWorkout(id: UUID) -> Workout {
        Workout(id: id, name: "Sentinel Import Walk", type: .cardio, mode: .activity, exercises: "", rpe: nil,
                notes: "", duration: 42, distanceMiles: 2.5, activeEnergyKcal: 188, healthKitUUID: UUID(),
                intensity: .light)
    }

    /// What `loadDailyHealthContext` hands the store at launch: activity + body with a night's sleep.
    private static func ingestedContext() -> HealthDailyContext {
        HealthDailyContext(
            activity: HealthActivitySummary(steps: 12_000, activeEnergyKilocalories: 520, exerciseMinutes: 35),
            body: HealthBodyContext(sleepHours: 7.2, restingHeartRateBPM: 51, heartRateVariabilityMS: 61)
        )
    }

    private static func date(_ key: String) throws -> Date {
        try #require(FernletDate.date(fromDayKey: key))
    }

    private static func encodedString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func labels(of value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    /// Labels of the optional children of `value` that are nil.
    private static func nilChildren(of value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap { child in
            let mirror = Mirror(reflecting: child.value)
            return mirror.displayStyle == .optional && mirror.children.isEmpty ? child.label : nil
        }
    }

    /// The value inside an optional (or the value itself).
    private static func unwrapped(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional, let first = mirror.children.first else { return value }
        return first.value
    }
}
