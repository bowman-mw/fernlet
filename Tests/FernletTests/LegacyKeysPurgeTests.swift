//
//  LegacyKeysPurgeTests.swift
//  FernletTests
//
//  "Delete everything" must reach the pre-database `LegacyKeys` UserDefaults corpus, not only the
//  JSON database file — and the next launch must not put it back.
//

import Foundation
import Testing
import FernletDomainModel
import FernletPersistence
import LocalPersistence

/// The pre-database `LegacyKeys` corpus must die with "delete everything", and stay dead.
///
/// The defect these exist to prevent: the seven legacy families (`fernlet-settings`,
/// `fernlet-recent-meals`, `fernlet-previous-journals`, `fernlet-memories`, `fernlet-goals`,
/// `fernlet-workshop`, and the interpolated `fernlet-day-<yyyy-MM-dd>` rows) hold `[JournalEntry]`
/// and `[MemoryNote]` as UNSEALED JSON in the preferences plist, and
/// `LocalFernletRepository.purgeAllPersistedData()` removed only the database file. Because an
/// absent file is indistinguishable from a first launch, the very next load ran the legacy
/// migration and re-hydrated the store from those keys — so the wipe both left journal plaintext on
/// the device AND put the data back at relaunch (re-uploading it, with sync on).
///
/// Isolation: these keys live in a defaults DOMAIN, not a path, so every test stands up its own
/// throwaway suite and removes it in a `defer`. Seeding — or asserting a wipe on — `.standard`
/// would read and destroy the same keys as every concurrently running suite, and the developer's
/// own simulator install.
struct LegacyKeysPurgeTests {

    /// The six fixed families, spelled out rather than imported. The production enum is `private`,
    /// and a test that shared its constants could not catch a rename — which would strand an old
    /// install's plaintext in the plist permanently, unreadable and undeletable.
    private static let fixedLegacyKeys = [
        "fernlet-settings",
        "fernlet-recent-meals",
        "fernlet-previous-journals",
        "fernlet-memories",
        "fernlet-goals",
        "fernlet-workshop"
    ]
    private static let todayKey = "2026-07-03"
    /// A second day row. The migration reads exactly ONE day key (today's), so this one is
    /// reachable only by the prefix sweep — it is what separates "clears the day family" from
    /// "happens to clear the day the test asks for".
    private static let pastDayKey = "2026-07-02"
    private static let dayKeyPrefix = "fernlet-day-"

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "legacy-keys-purge-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-keys-purge-\(UUID().uuidString).json")
    }

    /// A repository over its own throwaway file and the given legacy domain. The backup-exclusion
    /// preference is pinned rather than read live, so these tests never reach the real preferences
    /// keychain.
    private func makeRepository(fileURL: URL, legacyDefaults: UserDefaults) -> LocalFernletRepository {
        LocalFernletRepository(
            fileURL: fileURL,
            backupExclusionPreference: { false },
            legacyDefaults: legacyDefaults
        )
    }

    /// One logged meal in the shape the pre-database builds wrote.
    private static func legacyMeal() -> Meal {
        Meal(
            name: "oatmeal",
            mealType: .breakfast,
            macros: Macros(protein: 12, carbs: 54, fat: 6),
            quality: .ok,
            confidence: "medium",
            note: "",
            source: MealLogSource.manual
        )
    }

    /// Writes the corpus a pre-database install left behind: unsealed journal + memory JSON, the
    /// aggregate slices, today's day row, and a past day row.
    private func seedLegacyCorpus(in defaults: UserDefaults) throws {
        let encoder = JSONEncoder()
        let journal = JournalEntry(text: "the plaintext that must not survive", tag: .neutral)
        let goal = FitnessGoal(type: .wellness, goal: "feel steadier", timeframe: "8 weeks", metric: "mood")
        let journalsData = try encoder.encode([journal])
        let memoriesData = try encoder.encode([MemoryNote(category: "neutral", text: "a remembered thing")])
        let goalsData = try encoder.encode([goal])
        let mealsData = try encoder.encode([Self.legacyMeal()])
        let settingsData = try encoder.encode(FernletSettings())
        let workshopData = try encoder.encode(WorkshopData())
        let todayData = try encoder.encode(FernletDay(date: Self.todayKey, journals: [journal], bottleCount: 7))
        let pastData = try encoder.encode(FernletDay(date: Self.pastDayKey, bottleCount: 3))
        defaults.set(journalsData, forKey: "fernlet-previous-journals")
        defaults.set(memoriesData, forKey: "fernlet-memories")
        defaults.set(goalsData, forKey: "fernlet-goals")
        defaults.set(mealsData, forKey: "fernlet-recent-meals")
        defaults.set(settingsData, forKey: "fernlet-settings")
        defaults.set(workshopData, forKey: "fernlet-workshop")
        defaults.set(todayData, forKey: "\(Self.dayKeyPrefix)\(Self.todayKey)")
        defaults.set(pastData, forKey: "\(Self.dayKeyPrefix)\(Self.pastDayKey)")
    }

    /// The counter-test, and the reason the emptiness assertions below are not vacuous: the corpus
    /// really does seed a first database, so an empty result after a purge is the purge's doing and
    /// not a seed that never landed.
    @Test func theCorpusStillSeedsAFirstDatabaseWhenNothingWasWiped() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        try seedLegacyCorpus(in: defaults)

        let snapshot = makeRepository(fileURL: temporaryDatabaseURL(), legacyDefaults: defaults)
            .loadSnapshot(todayKey: Self.todayKey)

        #expect(snapshot.previousJournals.count == 1, "the legacy migration no longer reads the corpus")
        #expect(snapshot.memories.count == 1)
        #expect(snapshot.goals.count == 1)
        #expect(snapshot.recentMeals.count == 1)
        #expect(snapshot.day.bottleCount == 7)
    }

    /// The headline regression: every family, including the interpolated day rows, is gone from the
    /// plist after a purge.
    @Test func purgingClearsEveryLegacyKeyFamily() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        try seedLegacyCorpus(in: defaults)
        let repository = makeRepository(fileURL: temporaryDatabaseURL(), legacyDefaults: defaults)
        // Precondition: the corpus is really there, so the purge has something to remove.
        #expect(defaults.data(forKey: "fernlet-memories") != nil, "precondition: the seed did not land")

        #expect(repository.purgeAllPersistedData(), "purge returned false")

        for key in Self.fixedLegacyKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) survived the purge")
        }
        #expect(
            defaults.object(forKey: "\(Self.dayKeyPrefix)\(Self.todayKey)") == nil,
            "today's legacy day row survived the purge"
        )
        #expect(
            defaults.object(forKey: "\(Self.dayKeyPrefix)\(Self.pastDayKey)") == nil,
            "a past legacy day row survived the purge — the interpolated family is not being swept"
        )
    }

    /// The resurrection half, and the one the user actually experiences: a second repository over
    /// the same (now absent) file is a relaunch, and an absent file routes straight through the
    /// legacy migration the defect rode in on.
    @Test func theWipedCorpusDoesNotComeBackOnTheNextLaunch() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        try seedLegacyCorpus(in: defaults)
        let fileURL = temporaryDatabaseURL()

        #expect(makeRepository(fileURL: fileURL, legacyDefaults: defaults).purgeAllPersistedData())

        let relaunched = makeRepository(fileURL: fileURL, legacyDefaults: defaults)
        let snapshot = relaunched.loadSnapshot(todayKey: Self.todayKey)
        #expect(snapshot.previousJournals.isEmpty, "journal plaintext came back through the legacy migration")
        #expect(snapshot.memories.isEmpty, "memories came back through the legacy migration")
        #expect(snapshot.goals.isEmpty, "goals came back through the legacy migration")
        #expect(snapshot.recentMeals.isEmpty, "recent meals came back through the legacy migration")
        #expect(snapshot.day.journals.isEmpty, "the legacy day row's journal text came back")
        #expect(snapshot.day.bottleCount == 0, "the legacy day row came back")
        // The migration must still yield a usable empty database rather than failing the read.
        #expect(snapshot.day.date == Self.todayKey, "the post-wipe load did not produce a fresh day")
        #expect(relaunched.loadAllDays()[Self.pastDayKey] == nil, "a past legacy day row came back")
    }

    /// The hole in the pre-fix cleanup's presence guard: it tested only the six fixed keys and
    /// returned early when none were set, so an install whose surviving legacy data was day rows
    /// alone kept them — and kept resurrecting today's day on every launch.
    @Test func aDayOnlyCorpusIsStillCleared() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let dayKey = "\(Self.dayKeyPrefix)\(Self.todayKey)"
        let dayData = try JSONEncoder().encode(FernletDay(date: Self.todayKey, bottleCount: 9))
        defaults.set(dayData, forKey: dayKey)
        let repository = makeRepository(fileURL: temporaryDatabaseURL(), legacyDefaults: defaults)

        #expect(repository.purgeAllPersistedData())

        #expect(defaults.object(forKey: dayKey) == nil, "a day-only legacy corpus was skipped by the cleanup's presence guard")
        #expect(repository.loadSnapshot(todayKey: Self.todayKey).day.bottleCount == 0)
    }

    /// The sweep is prefix-bounded, not "empty the domain": a wipe that cleared everything in sight
    /// would take defaults keys other owners are responsible for (several survive this funnel by
    /// design), and the `fernlet-day-` prefix must match on its delimiter rather than on the
    /// `fernlet-day` stem.
    @Test func thePurgeLeavesUnrelatedDefaultsKeysAlone() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        try seedLegacyCorpus(in: defaults)
        defaults.set("kept", forKey: "fernlet-unrelated-preference")
        // Shares the `fernlet-day` stem but not the trailing delimiter, so it is NOT a day row.
        defaults.set("kept", forKey: "fernlet-daydream")

        #expect(makeRepository(fileURL: temporaryDatabaseURL(), legacyDefaults: defaults).purgeAllPersistedData())

        #expect(defaults.string(forKey: "fernlet-unrelated-preference") == "kept", "the purge emptied the whole defaults domain")
        #expect(defaults.string(forKey: "fernlet-daydream") == "kept", "the day-row sweep matched on the stem instead of the delimiter")
    }

    /// A purge with a real database file present must clear BOTH stores and leave the repository
    /// usable — the user keeps using the app afterwards, and the next save must not be refused.
    ///
    /// The corpus is seeded AFTER the save on purpose. A save through this repository runs the
    /// post-migration cleanup itself, so seeding first would leave the purge nothing to prove; and
    /// file-plus-corpus is the shipping configuration anyway — production runs
    /// `CoreDataFernletRepository`, which reads this repository only as its migration source and
    /// never saves through it, so both the JSON file and the plist keys sit there untouched.
    @Test func purgingClearsTheFileAndTheCorpusTogether() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let fileURL = temporaryDatabaseURL()
        let repository = makeRepository(fileURL: fileURL, legacyDefaults: defaults)
        let snapshot = FernletSnapshot(
            todayKey: Self.todayKey,
            day: FernletDay(date: Self.todayKey, bottleCount: 5),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
        #expect(repository.saveSnapshot(SanitizedSnapshot.sanitizing(snapshot, sealedJournalIDs: [])), "save failed")
        #expect(FileManager.default.fileExists(atPath: fileURL.path), "precondition: the save did not land")
        try seedLegacyCorpus(in: defaults)

        #expect(repository.purgeAllPersistedData())

        #expect(!FileManager.default.fileExists(atPath: fileURL.path), "the purge left the database file behind")
        #expect(defaults.object(forKey: "fernlet-previous-journals") == nil, "the corpus survived a purge that had a file to remove")
        #expect(defaults.object(forKey: "\(Self.dayKeyPrefix)\(Self.pastDayKey)") == nil, "a legacy day row survived a purge that had a file to remove")
        #expect(repository.saveSnapshot(SanitizedSnapshot.sanitizing(snapshot, sealedJournalIDs: [])), "the repository refuses saves after a purge")
        #expect(repository.loadSnapshot(todayKey: Self.todayKey).day.bottleCount == 5)
    }
}
