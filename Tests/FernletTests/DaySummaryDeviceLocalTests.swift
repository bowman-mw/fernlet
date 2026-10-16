import Foundation
import Testing
import CloudKitSync
import DiaryStore
import FernletFoundation
import FernletDomainModel
import FernletPersistence
@testable import Fernlet

/// Day summaries stay on the device that wrote them (owner decision 2026-10-15; the spec excludes
/// `DaySummaryText` from sync): the persisted score history — the local blob and the iCloud-mirrored
/// one — never carries a summary, this device keeps its own in the device-local store across a
/// relaunch, another device (or a restore) writes its own, and "Delete everything" clears them.
///
/// Every store here is in-memory or lives in its own temporary directory — never
/// `FileDeviceDaySummaryStore.production`, which is the simulator's real Application Support file.
@MainActor
@Suite
struct DaySummaryDeviceLocalTests {
    /// A summary no other fixture writes, so finding it in encoded output can only mean a leak.
    private static let sentinel = "Sentinel summary: a gentle day of oats and a long walk."
    private static let pastKey = "2026-10-13"

    // MARK: - The persisted copy

    @Test func theStoredScoreHistoryCarriesNoSummary() throws {
        let score = DailyHealthScore(dateKey: Self.pastKey, score: 0.6, companionState: .okay,
                                     daySummaryText: Self.sentinel, computedAt: .now)
        #expect(FernletSnapshot.storedDailyScores([score]).allSatisfy { $0.daySummaryText == nil })
        let snapshot = FernletSnapshot(
            todayKey: "2026-10-14", day: FernletDay(date: "2026-10-14"), settings: FernletSettings(),
            recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData(),
            dailyScores: [score]
        )
        let stored = SanitizedSnapshot.sanitizing(snapshot, sealedJournalIDs: []).snapshot
        #expect(!(try Self.encodedString(stored)).contains(Self.sentinel))
        #expect(stored.dailyScores.first?.score == 0.6)     // the row itself still syncs
    }

    @Test func aStoredSummaryNeverReachesThePersistedBlob() throws {
        let cache = InMemoryDeviceDaySummaryStore()
        let built = makeTestStoreWithRepositories(date: try Self.date("2026-10-14"), deviceDaySummaryStore: cache)
        built.store.storeDaySummary(Self.sentinel, for: Self.pastKey)
        #expect(built.store.flushPendingSnapshotSave())

        let blob = built.repository.loadSnapshot(todayKey: "2026-10-14")
        #expect(blob.dailyScores.contains { $0.dateKey == Self.pastKey })
        #expect(blob.dailyScores.allSatisfy { $0.daySummaryText == nil })
        #expect(!(try Self.encodedString(blob)).contains(Self.sentinel))
        #expect(cache.allSummaries()?[Self.pastKey] == Self.sentinel)
        #expect(Self.summary(in: built.store, for: Self.pastKey) == Self.sentinel)
    }

    // MARK: - This device

    /// The summary survives a relaunch on THIS device (same store) and is absent on a device that
    /// did not write it (same synced rows, its own empty store) — which the launch backfill fills.
    @Test func theSummarySurvivesARelaunchOnThisDeviceOnly() throws {
        let date = try Self.date("2026-10-14")
        let cache = InMemoryDeviceDaySummaryStore()
        let first = makeTestStoreWithRepositories(date: date, deviceDaySummaryStore: cache)
        first.store.storeDaySummary(Self.sentinel, for: Self.pastKey)
        #expect(first.store.flushPendingSnapshotSave())

        let relaunched = makeStoreSharingStores(date: date, repository: first.repository,
                                                narratives: first.narratives, deviceDaySummaryStore: cache)
        #expect(Self.summary(in: relaunched, for: Self.pastKey) == Self.sentinel)
        #expect(relaunched.dailyHealthScore(for: Self.pastKey, day: relaunched.loadDay(for: Self.pastKey))
            .daySummaryText == Self.sentinel)

        let otherDevice = makeStoreSharingStores(date: date, repository: first.repository, narratives: first.narratives)
        #expect(otherDevice.dailyScores.contains { $0.dateKey == Self.pastKey })
        #expect(Self.summary(in: otherDevice, for: Self.pastKey) == nil)
    }

    /// A day's content change invalidates the summary here AND in the device store, so a relaunch
    /// cannot bring the stale one back.
    @Test func invalidationRemovesTheDeviceCopy() throws {
        let date = try Self.date("2026-10-14")
        let cache = InMemoryDeviceDaySummaryStore()
        let first = makeTestStoreWithRepositories(date: date, deviceDaySummaryStore: cache)
        first.store.storeDaySummary(Self.sentinel, for: Self.pastKey)
        first.store.invalidateDaySummary(for: Self.pastKey)
        #expect(cache.allSummaries()?[Self.pastKey] == nil)
        #expect(first.store.flushPendingSnapshotSave())

        let relaunched = makeStoreSharingStores(date: date, repository: first.repository,
                                                narratives: first.narratives, deviceDaySummaryStore: cache)
        #expect(Self.summary(in: relaunched, for: Self.pastKey) == nil)
    }

    /// A remote reload installs the synced score history, which carries no summaries; this device's
    /// come back from its store.
    @Test func aRemoteApplyKeepsThisDevicesSummaries() throws {
        let cache = InMemoryDeviceDaySummaryStore()
        let built = makeTestStoreWithRepositories(date: try Self.date("2026-10-14"), deviceDaySummaryStore: cache)
        built.store.storeDaySummary(Self.sentinel, for: Self.pastKey)
        #expect(built.store.flushPendingSnapshotSave())

        built.store.diary.applyDiarySlice(built.repository.loadSnapshot(todayKey: "2026-10-14"))
        #expect(Self.summary(in: built.store, for: Self.pastKey) == Self.sentinel)
    }

    /// The first attach on a device keeps the summaries an older build left in the persisted rows —
    /// once — and the next save rewrites the blob without them.
    @Test func theFirstAttachKeepsALegacyBlobsSummariesAndRewritesTheBlob() throws {
        let date = try Self.date("2026-10-14")
        let first = makeTestStoreWithRepositories(date: date)
        var legacy = first.repository.loadSnapshot(todayKey: "2026-10-14")
        legacy.dailyScores = [DailyHealthScore(dateKey: Self.pastKey, score: 0.7, companionState: .okay,
                                               daySummaryText: Self.sentinel, computedAt: .now)]
        #expect(first.repository.saveSnapshot(legacy))    // raw: what a build before 2026-10-15 wrote

        let cache = InMemoryDeviceDaySummaryStore()
        let upgraded = makeStoreSharingStores(date: date, repository: first.repository,
                                              narratives: first.narratives, deviceDaySummaryStore: cache)
        #expect(cache.allSummaries()?[Self.pastKey] == Self.sentinel)
        #expect(cache.legacySummariesCaptured)
        #expect(Self.summary(in: upgraded, for: Self.pastKey) == Self.sentinel)
        #expect(upgraded.flushPendingSnapshotSave())
        #expect(first.repository.loadSnapshot(todayKey: "2026-10-14").dailyScores.allSatisfy { $0.daySummaryText == nil })
    }

    /// Once the capture has run, a summary that still arrives in the synced rows (another device on
    /// an older build) is not adopted: this device shows only what it wrote.
    @Test func afterTheCaptureASyncedSummaryIsNotAdopted() throws {
        let date = try Self.date("2026-10-14")
        let cache = InMemoryDeviceDaySummaryStore()
        #expect(cache.markLegacySummariesCaptured())
        let first = makeTestStoreWithRepositories(date: date)
        var synced = first.repository.loadSnapshot(todayKey: "2026-10-14")
        synced.dailyScores = [DailyHealthScore(dateKey: Self.pastKey, score: 0.7, companionState: .okay,
                                               daySummaryText: Self.sentinel, computedAt: .now)]
        #expect(first.repository.saveSnapshot(synced))

        let store = makeStoreSharingStores(date: date, repository: first.repository,
                                           narratives: first.narratives, deviceDaySummaryStore: cache)
        #expect(Self.summary(in: store, for: Self.pastKey) == nil)
        #expect(cache.allSummaries()?.isEmpty == true)
    }

    // MARK: - Delete everything

    @Test func deleteEverythingClearsTheSummaries() async throws {
        let cache = InMemoryDeviceDaySummaryStore()
        let store = makeTestStore(date: try Self.date("2026-10-14"), deviceDaySummaryStore: cache)
        store.storeDaySummary(Self.sentinel, for: Self.pastKey)
        #expect(cache.markLegacySummariesCaptured())
        #expect(cache.allSummaries()?.isEmpty == false)

        let outcome = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(!outcome.incompleteStores.contains("your day summaries"))
        #expect(cache.allSummaries()?.isEmpty == true)
        #expect(!cache.legacySummariesCaptured)
        #expect(store.dailyScores.isEmpty)
    }

    // MARK: - The file store

    @Test func theFileStoreSurvivesANewInstanceAndClearsWhole() throws {
        let directory = Self.uniqueDirectory()
        let first = FileDeviceDaySummaryStore(directory: directory)
        #expect(first.record(Self.sentinel, for: Self.pastKey))
        #expect(first.markLegacySummariesCaptured())
        let second = FileDeviceDaySummaryStore(directory: directory)
        #expect(second.allSummaries()?[Self.pastKey] == Self.sentinel)
        #expect(second.legacySummariesCaptured)

        #expect(second.clearAll())
        let file = directory.appendingPathComponent(FileDeviceDaySummaryStore.fileName)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(second.allSummaries()?.isEmpty == true)
        #expect(!second.legacySummariesCaptured)
        #expect(FileDeviceDaySummaryStore(directory: directory).allSummaries()?.isEmpty == true)
    }

    @Test func theFileStoreDirectoryIsExcludedFromDeviceBackup() throws {
        let directory = Self.uniqueDirectory()
        #expect(FileDeviceDaySummaryStore(directory: directory).record(Self.sentinel, for: Self.pastKey))
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// Bounded on write and on decode: the day count, each summary's length, and no empty entries.
    @Test func theFileStoreIsBoundedOnWriteAndDecode() throws {
        let directory = Self.uniqueDirectory()
        let store = FileDeviceDaySummaryStore(directory: directory)
        let start = try #require(FernletDate.date(fromDayKey: "2025-01-01"))
        let keys = (0...FileDeviceDaySummaryStore.maxDays).compactMap { offset in
            Calendar(identifier: .gregorian).date(byAdding: .day, value: offset, to: start).map(FernletDate.dayKey(for:))
        }
        for key in keys {
            #expect(store.record("A day.", for: key))
        }
        #expect(store.allSummaries()?.count == FileDeviceDaySummaryStore.maxDays)
        #expect(store.allSummaries()?["2025-01-01"] == nil)            // the oldest day went
        #expect(store.record(String(repeating: "a", count: 1_000), for: Self.pastKey))
        #expect(store.allSummaries()?[Self.pastKey]?.count == DiaryStore.maxDaySummaryCharacters)
        #expect(store.record("   ", for: Self.pastKey))
        #expect(store.allSummaries()?[Self.pastKey] == nil)
        #expect(!store.record(Self.sentinel, for: ""))

        let handEdited = Self.uniqueDirectory()
        try FileManager.default.createDirectory(at: handEdited, withIntermediateDirectories: true)
        let raw = ["days": [Self.pastKey: String(repeating: "b", count: 900), "2026-10-12": ""]]
        try JSONEncoder().encode(raw).write(to: handEdited.appendingPathComponent(FileDeviceDaySummaryStore.fileName))
        let decoded = FileDeviceDaySummaryStore(directory: handEdited).allSummaries()
        #expect(decoded?[Self.pastKey]?.count == DiaryStore.maxDaySummaryCharacters)
        #expect(decoded?["2026-10-12"] == nil)
    }

    @Test func anUndecodableFileIsReplacedNotTrusted() throws {
        let directory = Self.uniqueDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a summary store".utf8).write(to: directory.appendingPathComponent(FileDeviceDaySummaryStore.fileName))
        let store = FileDeviceDaySummaryStore(directory: directory)
        #expect(store.allSummaries()?.isEmpty == true)
        #expect(store.record(Self.sentinel, for: Self.pastKey))
        #expect(FileDeviceDaySummaryStore(directory: directory).allSummaries()?[Self.pastKey] == Self.sentinel)
    }

    // MARK: - Fixtures

    private static func summary(in store: FernletStore, for dateKey: String) -> String? {
        store.dailyScores.first { $0.dateKey == dateKey }?.daySummaryText
    }

    private static func date(_ key: String) throws -> Date {
        try #require(FernletDate.date(fromDayKey: key))
    }

    private static func encodedString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func uniqueDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet-day-summaries-\(UUID().uuidString)", isDirectory: true)
    }
}
