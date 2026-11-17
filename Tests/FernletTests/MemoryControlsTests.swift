import Testing
import CoreData
import Foundation
import CloudKitSync
import DiaryStore
import FernletDomainModel
import FernletFoundation
import FernletPersistence
import LocalPersistence
@testable import Fernlet

/// G9-3 memory controls (Docs/G9-Data-Integrity-Recovery-Plan-2026-11-15.md, Part 3): `userEdited`
/// against the 300 cap, the "Let Fernlet remember" switch stopping both writers, "Forget patterns" and
/// its synced, newest-wins learn-from date, and "Delete all memories".
@MainActor
@Suite(.serialized)
struct MemoryControlsTests {
    private static let entry = "Went for a long walk by the river after work and felt proud of getting outside."

    private func makeStore() -> (store: FernletStore, repository: CoreDataFernletRepository) {
        let (store, repository, _) = makeTestStoreWithRepositories()
        store.activateSealedJournals(contentKey: .journalTestKey)
        return (store, repository)
    }

    private func plantTierTwoRecord(in store: TierTwoMemoryStore) throws {
        let record = TierTwoMemoryRecord(category: "consistency_profile", text: "Most days are logged.",
                                         state: "steady")
        try RowPayloadCoders.makeEncoder().encode([record]).write(to: store.fileURL, options: .atomic)
    }

    // MARK: - userEdited and the cap

    @Test func theCapDropsUneditedMemoriesFirst() {
        let editedOldest = MemoryNote(category: "note", text: "Mine", userEdited: true)
        let plain = (0..<3).map { MemoryNote(category: "note", text: "Plain \($0)") }
        let capped = MemoryNote.capped([editedOldest] + plain, to: 2)
        #expect(capped.map(\.text) == ["Mine", "Plain 2"])
    }

    @Test func theCapDropsEditedMemoriesOnlyWhenNothingElseIsLeft() {
        let edited = (0..<3).map { MemoryNote(category: "note", text: "Edited \($0)", userEdited: true) }
        #expect(MemoryNote.capped(edited, to: 2).map(\.text) == ["Edited 1", "Edited 2"])
        #expect(MemoryNote.capped(edited, to: 5).count == 3)
    }

    @Test func aNewJournalMemoryAtTheCapKeepsTheEditedOldest() {
        let (store, _) = makeStore()
        let editedOldest = MemoryNote(category: "note", text: "Keep me", userEdited: true)
        store.memories = [editedOldest] + (0..<(MemoryNote.maxStored - 1)).map { MemoryNote(category: "note", text: "n\($0)") }

        store.addJournal(text: Self.entry, tag: .good)

        #expect(store.memories.count == MemoryNote.maxStored)
        #expect(store.memories.first?.id == editedOldest.id)
        #expect(!store.memories.contains { $0.text == "n0" })
    }

    @Test func editingAMemoryMarksItUserEdited() {
        let (store, _) = makeStore()
        let note = MemoryNote(category: "note", text: "Before")
        store.memories = [note]
        store.updateMemory(note, category: "note", text: "After")
        #expect(store.memories.first?.userEdited == true)
    }

    @Test func userEditedRoundTripsAndIsAbsentWhenFalse() throws {
        let plain = try RowPayloadCoders.makeEncoder().encode(MemoryNote(category: "note", text: "x"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("userEdited"))
        let edited = MemoryNote(category: "note", text: "x", userEdited: true)
        let decoded = try RowPayloadCoders.makeDecoder().decode(MemoryNote.self,
                                                               from: RowPayloadCoders.makeEncoder().encode(edited))
        #expect(decoded.userEdited)
    }

    // MARK: - "Let Fernlet remember"

    @Test func switchedOffAJournalEntryLeavesNoMemory() {
        let (store, _) = makeStore()
        store.setMemoryExtraction(enabled: false, deleteExisting: false)

        store.addJournal(text: Self.entry, tag: .bright)

        #expect(store.memories.isEmpty)
        #expect(store.settings.memoryExtractionEnabled == false)
    }

    @Test func turnOffAndDeleteClearsMemoriesWhileKeepKeepsThem() {
        let (store, _) = makeStore()
        store.memories = [MemoryNote(category: "note", text: "One")]
        store.setMemoryExtraction(enabled: false, deleteExisting: false)
        #expect(store.memories.count == 1)

        store.setMemoryExtraction(enabled: true, deleteExisting: false)
        store.setMemoryExtraction(enabled: false, deleteExisting: true)
        #expect(store.memories.isEmpty)
    }

    @Test func switchedOffPatternsAreDeletedAndNotRebuilt() throws {
        let (store, repository) = makeStore()
        try plantTierTwoRecord(in: repository.tierTwoMemoryStore)

        store.setMemoryExtraction(enabled: false, deleteExisting: false)
        #expect(!FileManager.default.fileExists(atPath: repository.tierTwoMemoryStore.fileURL.path))

        store.flushPendingSnapshotSave()
        #expect(repository.loadTierTwoMemories().isEmpty)
    }

    @Test func theSettingIsSyncedAndAbsentFromTheBlobWhileOn() throws {
        let plain = try RowPayloadCoders.makeEncoder().encode(FernletSettings())
        let json = String(decoding: plain, as: UTF8.self)
        #expect(!json.contains("memoryExtractionEnabled") && !json.contains("tierTwoLearnFrom"))
        var off = FernletSettings()
        off.memoryExtractionEnabled = false
        off.tierTwoLearnFrom = "2026-11-15"
        let decoded = try RowPayloadCoders.makeDecoder().decode(FernletSettings.self,
                                                               from: RowPayloadCoders.makeEncoder().encode(off))
        #expect(decoded.memoryExtractionEnabled == false)
        #expect(decoded.tierTwoLearnFrom == "2026-11-15")
    }

    @Test func aMalformedLearnFromIsDropped() throws {
        let data = Data(#"{"tierTwoLearnFrom":"zzzz-not-a-day"}"#.utf8)
        #expect(try JSONDecoder().decode(FernletSettings.self, from: data).tierTwoLearnFrom == nil)
    }

    // MARK: - "Forget patterns" and the learn-from date

    @Test func forgetPatternsSetsTodayAndPurges() throws {
        let (store, repository) = makeStore()
        try plantTierTwoRecord(in: repository.tierTwoMemoryStore)

        store.forgetPatterns()

        #expect(store.settings.tierTwoLearnFrom == store.todayKey)
        #expect(!FileManager.default.fileExists(atPath: repository.tierTwoMemoryStore.fileURL.path))
        store.flushPendingSnapshotSave()
        repository.invalidateCache()
        #expect(repository.loadSnapshot(todayKey: store.todayKey).settings.tierTwoLearnFrom == store.todayKey)
    }

    @Test func theLearnFromDateFiltersDaysAndDropsOlderRecords() {
        let learning = TierTwoLearning(enabled: true, learnFrom: "2026-11-10")
        let days = ["2026-11-08", "2026-11-10", "2026-11-12"].map { ($0, FernletDay(date: $0)) }
        #expect(learning.learnableDays(days).map(\.0) == ["2026-11-10", "2026-11-12"])
        var old = TierTwoMemoryRecord(category: "c", text: "t")
        old.extractedDate = FernletDate.date(fromDayKey: "2026-11-01") ?? .distantPast
        var fresh = TierTwoMemoryRecord(category: "c", text: "t")
        fresh.extractedDate = FernletDate.date(fromDayKey: "2026-11-11") ?? .distantPast
        #expect(learning.learnableRecords([old, fresh]).map(\.id) == [fresh.id])
    }

    @Test func newestLearnFromWins() {
        #expect(DiaryStore.newerLearnFrom("2026-11-01", "2026-11-15") == "2026-11-15")
        #expect(DiaryStore.newerLearnFrom("2026-11-15", nil) == "2026-11-15")
        #expect(DiaryStore.newerLearnFrom(nil, "2026-11-02") == "2026-11-02")
        #expect(DiaryStore.newerLearnFrom(nil, nil) == nil)
    }

    @Test func aNewerRemoteLearnFromPurgesThisDevicesPatterns() async throws {
        let (store, repository) = makeStore()
        try plantTierTwoRecord(in: repository.tierTwoMemoryStore)
        let remoteKey = store.todayKey
        // This phone's own pending save lands first, as it would before the remote change arrived.
        store.flushPendingSnapshotSave()

        try writeRemoteSettings(over: repository, todayKey: store.todayKey) { $0.tierTwoLearnFrom = remoteKey }
        repository.invalidateCache()

        try await waitUntil { store.settings.tierTwoLearnFrom == remoteKey }
        #expect(!FileManager.default.fileExists(atPath: repository.tierTwoMemoryStore.fileURL.path))
    }

    @Test func aStaleRemoteBlobCannotMoveTheLearnFromDateBack() async throws {
        let (store, repository) = makeStore()
        store.forgetPatterns()
        store.flushPendingSnapshotSave()

        try writeRemoteSettings(over: repository, todayKey: store.todayKey) {
            $0.tierTwoLearnFrom = nil
            $0.bottleOz = 31   // a marker that the remote blob was applied
        }
        repository.invalidateCache()

        try await waitUntil { store.settings.bottleOz == 31 }
        #expect(store.settings.tierTwoLearnFrom == store.todayKey)
    }

    // MARK: - Delete all and forget by ids

    @Test func deleteAllMemoriesTombstonesEveryRow() throws {
        let (store, repository) = makeStore()
        store.memories = [MemoryNote(category: "note", text: "A"), MemoryNote(category: "note", text: "B")]
        store.flushPendingSnapshotSave()

        #expect(store.deleteAllMemories() == 2)
        store.flushPendingSnapshotSave()

        #expect(store.memories.isEmpty)
        #expect(MemoryRecordRepository(controller: repository.persistenceController).load().isEmpty)
        repository.invalidateCache()
        #expect(repository.loadSnapshot(todayKey: store.todayKey).memories.isEmpty)
    }

    @Test func forgetMemoriesRemovesOnlyTheListedIDs() {
        let (store, _) = makeStore()
        let doomed = MemoryNote(category: "note", text: "Doomed")
        let kept = MemoryNote(category: "note", text: "Kept")
        store.memories = [doomed, kept]
        #expect(store.forgetMemories(ids: [doomed.id]) == 1)
        #expect(store.memories.map(\.id) == [kept.id])
        #expect(store.forgetMemories(ids: []) == 0)
    }

    // MARK: - Helpers

    /// Another device's save: a second repository over the same store writes the blob with `edit`
    /// applied to the settings it reads.
    private func writeRemoteSettings(over repository: CoreDataFernletRepository, todayKey: String,
                                     _ edit: (inout FernletSettings) -> Void) throws {
        let other = CoreDataFernletRepository(
            controller: repository.persistenceController,
            legacyRepository: LocalFernletRepository(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("MemoryControls-\(UUID().uuidString)").appendingPathExtension("json"))
        )
        var snapshot = other.loadSnapshot(todayKey: todayKey)
        edit(&snapshot.settings)
        #expect(other.saveSnapshot(snapshot))
    }

    /// Polls (bounded: about 5 s) until `condition` holds — the store's remote reload is debounced.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(condition(), "the remote change never reached the store")
    }
}
