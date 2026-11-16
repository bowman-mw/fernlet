//
//  PrivateMemoryBackupTests.swift
//  FernletTests
//
//  Private memories (G9-3, owner call M6 = A: "include private memories in the encrypted backup now")
//  in Fernlet's Sealed iCloud backup. They ride on the head of the JOURNAL's v2 set
//  (`SealedBackupV2Envelope.privateMemories`, `JournalBackupAdapter`), under the journal's switch, so
//  these drive the journal backup end to end through the coordinator over the in-memory cloud — one
//  `JournalBackupDevice` per iPhone, each with its own `PrivateMemoryVault` over an in-memory sealed
//  store (`FakeSealedBackupHost.privateMemories`) — plus the frozen shape and the rule that a section a
//  build cannot read is SKIPPED, never a failed restore.
//

import CloudKit
import CloudKitSync
import CryptoKit
import FernletDomainModel
import Foundation
import PrivateMemoryStore
import PrivateStoreCore
import Testing
@testable import Fernlet

/// The journal head as a build from before G9-3 decodes it: only the keys it knows.
private struct PrePrivateMemoryEnvelope: Decodable {
    let v: Int
    let writer: String
    let set: String
    let total: Int?
    let records: [JournalNarrative]
}

@MainActor
@Suite(.serialized)
struct PrivateMemoryBackupTests {
    static let early = Date(timeIntervalSince1970: 1_800_000_000)
    static let late = Date(timeIntervalSince1970: 1_800_086_400)
    static let sister = MemoryNote(category: "family", text: "Talked with my sister for an hour", sourceDate: early)
    static let walk = MemoryNote(category: "calm", text: "The river walk helped", sourceDate: late, userEdited: true)

    /// An old iPhone (resolved, journal backup on) that writes one entry, keeps `memories` private, then
    /// turns the journal backup on.
    static func writeOldBackup(_ cloud: FakeSealedBackupCloud, memories: [MemoryNote]? = nil) async throws {
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        try old.write(JournalBackupDevice.entry("a quiet day", day: 1))
        for memory in memories ?? [Self.sister, Self.walk] {
            try old.host.privateMemories.keep(memory, key: old.key, isDecoy: false)
        }
        #expect(await old.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
    }

    /// The journal head plaintext in `cloud`.
    static func cloudHeadPlaintext(_ cloud: FakeSealedBackupCloud) async throws -> Data? {
        let reader = try PeriodBackupDevice.reader(cloud)
        guard let head = try await reader.fetchHeadRecord(payloadType: .journalNarratives) else { return nil }
        return try reader.open(head)
    }

    /// The private memories the journal head in `cloud` carries, or nil.
    static func cloudPrivateMemories(_ cloud: FakeSealedBackupCloud) async throws -> SealedBackupPrivateMemories? {
        guard let plaintext = try await cloudHeadPlaintext(cloud) else { return nil }
        return try SealedBackupV2Format.privateMemories(of: plaintext)
    }

    /// Writes a journal head sealed with the shared escrow key whose JSON object `edit` has changed.
    static func writeHandMadeHead(_ cloud: FakeSealedBackupCloud, _ edit: (inout [String: Any]) -> Void) async throws -> String {
        let writer = try PeriodBackupDevice.reader(cloud)
        let tag = PeriodBackupDevice.tag("newer")
        let envelope = SealedBackupV2Envelope(writer: tag, set: tag, total: 1, records: [JournalBackupDevice.entry("from a newer Fernlet", day: 1)])
        var object = try #require(try JSONSerialization.jsonObject(with: try SealedBackupV2Format.encode(envelope)) as? [String: Any])
        edit(&object)
        let plaintext = try JSONSerialization.data(withJSONObject: object)
        let head = try writer.sealChunk(plaintext, payloadType: .journalNarratives, chunkIndex: 0, chunkCount: 1,
                                        generation: 3, keySalt: SealedBackupService.mintKeySalt())
        try await writer.save(head, setTag: tag)
        return tag
    }

    // MARK: - Export and restore

    /// Export -> restore into a fresh iPhone: the private memories ride the journal set's head, sealed
    /// (no word, category or id reaches CloudKit in the clear), and the new iPhone's restore seals them
    /// into its own private store under its own key.
    @Test func privateMemoriesRideTheJournalSetSealedAndComeBackOnANewPhone() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let carried = try #require(try await Self.cloudPrivateMemories(cloud))
        #expect(carried.memories == [Self.sister, Self.walk], "every private memory, oldest first, edited flag kept")
        for bytes in try SealedBackupBodyTallyTests.cloudBytes(cloud) {
            for plain in ["sister", "privateMemories", Self.sister.id.uuidString, "family"] {
                #expect(bytes.range(of: Data(plain.utf8)) == nil, "\(plain) reached CloudKit in the clear")
            }
        }

        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .restored(1))
        #expect(phone.host.privateMemories.memories(key: phone.key, isDecoy: false) == [Self.sister, Self.walk])
        #expect(try PrivateMemoryRepository(controller: phone.host.privateMemoriesController).rowCount() == 2, "sealed on the iPhone")
    }

    /// The restore is a MERGE: a memory only the backup has is added, a memory this iPhone already holds
    /// is kept as it is, one only this iPhone has is never removed — and the follow-through export
    /// publishes the union.
    @Test func theRestoreAddsAbsentMemoriesKeepsLocalOnesAndDeletesNothing() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        var localSister = Self.sister
        localSister.text = "Edited here"
        let localOnly = MemoryNote(category: "note", text: "Only on this phone", sourceDate: Self.late.addingTimeInterval(60))
        try phone.host.privateMemories.keep(localSister, key: phone.key, isDecoy: false)
        try phone.host.privateMemories.keep(localOnly, key: phone.key, isDecoy: false)

        await phone.coordinator.settleV2Backup(.journalNarratives)
        let merged = phone.host.privateMemories.memories(key: phone.key, isDecoy: false)
        #expect(merged.map(\.text) == ["Edited here", "The river walk helped", "Only on this phone"])
        let published = try #require(try await Self.cloudPrivateMemories(cloud))
        #expect(published.memories.map(\.id) == merged.map(\.id), "the union is published")
    }

    /// A decoy session exports nothing real and restores nothing: the journal's duress gate stops both,
    /// and the funnel itself refuses to hand out or merge a private memory.
    @Test func aDecoyExportsNothingAndRestoresNothing() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        try old.write(JournalBackupDevice.entry("a quiet day", day: 1))
        try old.host.privateMemories.keep(Self.sister, key: old.key, isDecoy: false)
        old.host.duressSessionActive = true
        #expect(throws: PrivateMemoryVaultError.decoy) { try old.host.sealedBackupPrivateMemories(hubKey: old.key) }
        #expect(await old.engine.perform(.journalNarratives, trigger: .enable, phases: .export).gateFailure == .duress)
        old.host.duressSessionActive = false

        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        phone.host.duressSessionActive = true
        #expect(throws: PrivateMemoryVaultError.decoy) {
            try phone.host.restoreSealedBackupPrivateMemories([Self.sister], hubKey: phone.key)
        }
        #expect(try PrivateMemoryRepository(controller: phone.host.privateMemoriesController).rowCount() == 0)
    }

    /// Private memories that can't be read right now fail the export with nothing written — never a head
    /// without them over the one in iCloud; once they read, the export carries them.
    @Test func memoriesThatCantBeReadFailTheExportRatherThanDropThem() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        try old.write(JournalBackupDevice.entry("a quiet day", day: 1))
        try old.host.privateMemories.keep(Self.sister, key: old.key, isDecoy: false)
        old.host.privateMemoriesUnreadable = true
        #expect(await old.engine.perform(.journalNarratives, trigger: .enable, phases: .export).exportStatus == .failed)
        #expect(JournalBackupDevice.journalNames(cloud).isEmpty, "nothing written")
        old.host.privateMemoriesUnreadable = false
        #expect(await old.engine.perform(.journalNarratives, trigger: .enable, phases: .export).exportStatus == .upToDate)
        #expect(try await Self.cloudPrivateMemories(cloud)?.memories == [Self.sister])
    }

    // MARK: - Builds that came before, and builds that come after

    /// A build from before G9-3 decodes only the keys it knows, so a head carrying `"privateMemories"`
    /// still reads — the header for E2 and the records for its restore.
    @Test func anOlderBuildIgnoresThePrivateMemoriesKey() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let plaintext = try #require(try await Self.cloudHeadPlaintext(cloud))
        #expect(String(decoding: plaintext, as: UTF8.self).contains("\"privateMemories\""))
        let older = try JSONDecoder().decode(PrePrivateMemoryEnvelope.self, from: plaintext)
        #expect(older.v == 2)
        #expect(older.records.map(\.text) == ["a quiet day"])
        #expect(try SealedBackupV2Format.header(of: plaintext).total == 1)
    }

    /// The current reader SKIPS a head section it does not know (a newer Fernlet's): the journal still
    /// restores, and nothing about the unknown key fails it.
    @Test func thisBuildSkipsAnUnknownHeadSectionAndStillRestores() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        _ = try await Self.writeHandMadeHead(cloud) { object in
            object["somethingNewer"] = ["v": 7, "items": [["anything": true]]] as [String: Any]
        }
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .restored(1))
        #expect(phone.storedIDs.count == 1)
    }

    /// A private-memory section in a shape a newer Fernlet wrote is SKIPPED, never a failed restore: the
    /// journal entry restores, no private memory is merged, and this iPhone's own private memories stay.
    @Test func aNewerPrivateMemoryShapeIsSkippedAndTheJournalStillRestores() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        _ = try await Self.writeHandMadeHead(cloud) { object in
            object["privateMemories"] = ["v": 2, "notes": [["sealed": "differently"]]] as [String: Any]
        }
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        try phone.host.privateMemories.keep(Self.walk, key: phone.key, isDecoy: false)
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .restored(1), "the restore did not fail")
        #expect(phone.storedIDs.count == 1, "the journal entry came back")
        #expect(phone.host.privateMemories.memories(key: phone.key, isDecoy: false) == [Self.walk], "nothing merged, nothing lost")
    }

    /// A head without private memories (an older build's, or an iPhone with none) restores the journal
    /// and leaves this iPhone's private memories; the follow-through export then carries them.
    @Test func aHeadWithoutPrivateMemoriesLeavesTheLocalOnesAndTheExportAddsThem() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud, memories: [])
        #expect(try await Self.cloudPrivateMemories(cloud) == nil, "no private memory, no key on the head")
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        try phone.host.privateMemories.keep(Self.walk, key: phone.key, isDecoy: false)
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .restored(1))
        #expect(try await Self.cloudPrivateMemories(cloud)?.memories == [Self.walk])
    }

    // MARK: - The frozen shape

    /// The head's `"privateMemories"` value is a frozen shape: `{"v":1,"memories":[…]}`, each memory under
    /// exactly `MemoryNote`'s frozen keys (`userEdited` only when true) — renaming one would orphan every
    /// backed-up private memory. A newer `v` decodes as a skipped section, never an error.
    @Test func thePrivateMemoriesShapeIsFrozen() throws {
        let value = SealedBackupPrivateMemories(memories: [Self.walk, Self.sister])
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(Set(object.keys) == ["v", "memories"])
        #expect(object["v"] as? Int == 1)
        let memories = try #require(object["memories"] as? [[String: Any]])
        #expect(memories.map { $0["text"] as? String } == [Self.sister.text, Self.walk.text], "oldest first")
        #expect(Set(memories[0].keys) == ["id", "category", "text", "sourceDate"])
        #expect(Set(memories[1].keys) == ["id", "category", "text", "sourceDate", "userEdited"])
        #expect(try JSONDecoder().decode(SealedBackupPrivateMemories.self, from: JSONEncoder().encode(value)) == value)

        let newer = try JSONDecoder().decode(SealedBackupPrivateMemories.self, from: Data(#"{"v":2,"whatever":[1]}"#.utf8))
        #expect(newer.newerVersion == 2)
        #expect(newer.memories.isEmpty)

        let tag = SealedBackupWriterTag.tag(forBinding: Data("w".utf8))
        let head = try SealedBackupV2Format.encode(SealedBackupV2Envelope<JournalNarrative>(
            writer: tag, set: tag, total: 0, records: [], privateMemories: value
        ))
        let headObject = try #require(try JSONSerialization.jsonObject(with: head) as? [String: Any])
        #expect(Set(headObject.keys) == ["v", "writer", "set", "total", "records", "privateMemories"])
    }

    // MARK: - The mutation hook

    /// Keeping a memory private, forgetting one and deleting them all each mark the journal's upload
    /// owed (the journal head carries them); a refused move owes nothing.
    @Test func privateMemoryChangesMarkTheJournalBackupOwed() {
        let store = makeTestStore()
        let key = SymmetricKey(size: .bits256)
        store.privateMemoryVault = PrivateMemoryVault(controller: PrivatePersistenceController(inMemory: true))
        store.memories = [Self.sister, Self.walk]
        let before = store.sealedBackupMutationEpoch(.journalNarratives)
        #expect(!store.keepMemoryPrivate(Self.sister), "Private closed: refused")
        #expect(store.sealedBackupMutationEpoch(.journalNarratives) == before, "nothing moved, nothing owed")
        store.hubContentKeyProvider = { key }
        #expect(store.keepMemoryPrivate(Self.sister))
        #expect(store.sealedBackupMutationEpoch(.journalNarratives) == before + 1)
        #expect(store.forgetPrivateMemories(ids: [Self.sister.id]) == 1)
        #expect(store.sealedBackupMutationEpoch(.journalNarratives) == before + 2)
        #expect(store.isSealedBackupReuploadOwed(.journalNarratives))
    }
}
