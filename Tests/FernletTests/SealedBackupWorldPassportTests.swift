//
//  SealedBackupWorldPassportTests.swift
//  FernletTests
//
//  The World passport in Fernlet's Sealed iCloud backup (round 7; owner 2026-10-29: "so a new phone gets
//  it back"). The passport rides on the head of the JOURNAL's v2 set (`SealedBackupV2Envelope.passport`,
//  `JournalBackupAdapter`), so these drive the journal backup end to end through the coordinator over the
//  in-memory cloud — one `JournalBackupDevice` per iPhone, each with its own `WorldAtlasKeeper` over an
//  ephemeral vault (`FakeSealedBackupHost.worldPassport`).
//

import CloudKit
import CloudKitSync
import FernletFoundation
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct SealedBackupWorldPassportTests {
    nonisolated static let t1 = Date(timeIntervalSince1970: 1_792_800_000)
    nonisolated static let t2 = Date(timeIntervalSince1970: 1_792_886_400)

    /// A sea's token no ciphertext would hold by chance.
    nonisolated static let seaToken = "Q7777777"
    nonisolated static let us = AtlasVisit(countryCode: "US", continent: .northAmerica, terrain: .temperateForest)
    nonisolated static let france = AtlasVisit(countryCode: "FR", continent: .europe, terrain: .temperateForest)
    nonisolated static let sea = AtlasVisit(
        sea: AtlasSea(token: seaToken, parentOcean: .atlantic, names: AtlasCityNames(english: "Test Sea")), terrain: .water
    )

    /// A passport of `visits`, recorded in order.
    nonisolated static func book(_ visits: [(AtlasVisit, Date)]) -> PassportBook {
        var book = PassportBook()
        for (visit, date) in visits { _ = book.record(visit, at: date) }
        return book
    }

    /// The old iPhone's passport: the United States, then the test sea.
    nonisolated static let oldPassport = book([(us, t1), (sea, t2)])

    /// An old iPhone (resolved, journal backup on) that writes one entry and `passport` to `cloud`.
    static func writeOldBackup(_ cloud: FakeSealedBackupCloud, passport: PassportBook = oldPassport) async throws {
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        defer { old.host.tearDownWorldPassport() }
        try old.write(JournalBackupDevice.entry("a day out", day: 1))
        try old.host.worldPassport.restore(passport)
        #expect(await old.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
    }

    /// The passport the journal head in `cloud` carries, or nil.
    static func cloudPassport(_ cloud: FakeSealedBackupCloud) async throws -> PassportBook? {
        let reader = try PeriodBackupDevice.reader(cloud)
        guard let head = try await reader.fetchHeadRecord(payloadType: .journalNarratives) else { return nil }
        guard let bytes = try SealedBackupV2Format.passport(of: try reader.open(head)) else { return nil }
        return try PassportBook(data: bytes)
    }

    /// Every byte CloudKit holds for the sealed backups: each record's ciphertext asset and its string and
    /// data fields.
    static func cloudBytes(_ cloud: FakeSealedBackupCloud) throws -> [Data] {
        var all: [Data] = []
        for record in cloud.sealedRecords {
            for key in record.allKeys() {
                if let asset = record[key] as? CKAsset, let url = asset.fileURL {
                    all.append(try Data(contentsOf: url))
                } else if let text = record[key] as? String {
                    all.append(Data(text.utf8))
                } else if let data = record[key] as? Data {
                    all.append(data)
                }
            }
        }
        return all
    }

    // MARK: - The round trip

    /// Export -> restore into a fresh iPhone: the passport rides the journal set's head, sealed (no token
    /// and no field name reaches CloudKit in the clear), and a new iPhone's restore merges it into its
    /// passport and saves it in its own sealed vault.
    @Test func thePassportRidesTheJournalSetSealedAndComesBackOnANewPhone() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        #expect(try await Self.cloudPassport(cloud) == Self.oldPassport)
        let stored = try Self.cloudBytes(cloud)
        #expect(!stored.isEmpty)
        for bytes in stored {
            #expect(bytes.range(of: Data(Self.seaToken.utf8)) == nil, "a passport token reached CloudKit in the clear")
            #expect(bytes.range(of: Data("passport".utf8)) == nil, "the passport field reached CloudKit in the clear")
        }

        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        defer { phone.host.tearDownWorldPassport() }
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .restored(1))
        #expect(phone.host.worldPassport.book == Self.oldPassport)
        let reopened = PassportStore(vault: phone.host.worldPassportVault)
        try reopened.load()
        #expect(reopened.book == Self.oldPassport, "the merge was saved, sealed on the iPhone")
    }

    /// The merge is by token, the earliest date kept and nothing local removed; the follow-through export
    /// publishes the union under this iPhone's writer.
    @Test func theMergeKeepsTheEarliestDateAndEveryLocalEntry() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        defer { phone.host.tearDownWorldPassport() }
        try phone.host.worldPassport.restore(Self.book([(Self.us, Self.t2), (Self.france, Self.t1)]))

        await phone.coordinator.settleV2Backup(.journalNarratives)
        let merged = phone.host.worldPassport.book
        #expect(merged.firstVisit(.country, token: "US") == Self.t1, "the backup's earlier date")
        #expect(merged.firstVisit(.terrain, token: "temperateForest") == Self.t1)
        #expect(merged.firstVisit(.country, token: "FR") == Self.t1, "a local entry is never removed")
        #expect(merged.firstVisit(.sea, token: Self.seaToken) == Self.t2, "an entry only in the backup is added")
        #expect(try await Self.cloudPassport(cloud) == merged, "the union is published")
        #expect(try await JournalBackupDevice.cloudHead(cloud)?.writer == phone.writer)
    }

    /// An empty passport is left off the head; a head without one (an earlier build's, or an empty
    /// passport's) restores the journal and leaves this iPhone's passport as it is, and the follow-through
    /// export then carries it.
    @Test func aHeadWithoutAPassportLeavesTheLocalOneAndTheExportAddsIt() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud, passport: PassportBook())
        #expect(try await Self.cloudPassport(cloud) == nil, "an empty passport is not written")
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        defer { phone.host.tearDownWorldPassport() }
        let local = Self.book([(Self.france, Self.t1)])
        try phone.host.worldPassport.restore(local)

        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .restored(1))
        #expect(phone.host.worldPassport.book == local)
        #expect(try await Self.cloudPassport(cloud) == local)
    }

    // MARK: - What it never does

    /// A decoy session exports nothing real and restores nothing: the journal's duress gate stops both
    /// before any decrypt, and nothing is written to the vault.
    @Test func aDecoyExportsNothingAndRestoresNothing() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        defer { old.host.tearDownWorldPassport() }
        try old.write(JournalBackupDevice.entry("a day out", day: 1))
        try old.host.worldPassport.restore(Self.oldPassport)
        old.host.duressSessionActive = true
        old.host.worldPassport.setDecoy(true)
        let report = await old.engine.perform(.journalNarratives, trigger: .enable, phases: .export)
        #expect(report.gateFailure == .duress)
        #expect(JournalBackupDevice.journalNames(cloud).isEmpty, "a decoy exports nothing")
        old.host.duressSessionActive = false
        old.host.worldPassport.setDecoy(false)
        #expect(await old.engine.perform(.journalNarratives, trigger: .enable, phases: .export).exportStatus == .upToDate)

        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        defer { phone.host.tearDownWorldPassport() }
        phone.host.duressSessionActive = true
        phone.host.worldPassport.setDecoy(true)
        await phone.coordinator.settleV2Backup(.journalNarratives)
        phone.host.duressSessionActive = false
        phone.host.worldPassport.setDecoy(false)
        #expect(phone.host.worldPassport.book.isEmpty, "a decoy restores nothing")
        #expect(try phone.host.worldPassportVault.read(.passport) == nil)
        #expect(try await JournalBackupDevice.cloudHead(cloud)?.writer == old.writer, "and writes nothing")
    }

    /// A passport that can't be handed out (here the keeper's own decoy refusal, as a locked phone's
    /// would be) fails the export with nothing written, never a head without the passport over the one in
    /// iCloud; once it can be read, the export carries it.
    @Test func aPassportThatCantBeReadFailsTheExportRatherThanDropIt() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        defer { old.host.tearDownWorldPassport() }
        try old.write(JournalBackupDevice.entry("a day out", day: 1))
        try old.host.worldPassport.restore(Self.oldPassport)
        old.host.worldPassport.setDecoy(true)
        let report = await old.engine.perform(.journalNarratives, trigger: .enable, phases: .export)
        #expect(report.exportStatus == .failed)
        #expect(JournalBackupDevice.journalNames(cloud).isEmpty, "nothing written")
        old.host.worldPassport.setDecoy(false)
        #expect(await old.engine.perform(.journalNarratives, trigger: .enable, phases: .export).exportStatus == .upToDate)
        #expect(try await Self.cloudPassport(cloud) == Self.oldPassport)
    }

    /// The app-lock reset's owner hold covers the passport: no restore merges it until the owner's own
    /// release, which then does.
    @Test func theOwnerHoldHoldsThePassportRestoreUntilTheRelease() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        defer { phone.host.tearDownWorldPassport() }
        phone.host.sealedBackupRestoreAwaitsOwner = true

        #expect(await phone.coordinator.restoreJournalBackup() == .deferredTransient)
        #expect(phone.host.worldPassport.book.isEmpty, "a held restore merges no passport")
        await phone.coordinator.releaseRestoreHoldForOwner()
        #expect(phone.host.worldPassport.book == Self.oldPassport, "the owner's release merges it")
    }

    /// The owner hold's export half: while it keeps the journal's pre-reset copy, this iPhone's passport is
    /// not written over it.
    @Test func theOwnerHoldKeepsThePreResetPassportInICloud() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        defer { phone.host.tearDownWorldPassport() }
        phone.host.restoreHold.hold(keepingCopiesFrom: JournalBackupDevice.backupOn)
        try phone.host.worldPassport.restore(Self.book([(Self.france, Self.t1)]))
        phone.host.markSealedBackupDirty(.journalNarratives)

        await phone.coordinator.retryDeferredReuploadIfNeeded(payloadType: .journalNarratives)
        #expect(phone.host.v2Status[.journalNarratives] == .heldForOwner)
        #expect(try await Self.cloudPassport(cloud) == Self.oldPassport)
    }

    /// The journal's backup switch gates the passport (it has none of its own): with it off nothing is
    /// restored or exported; once it is on, the restore merges the passport.
    @Test func theJournalSwitchGatesThePassport() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let off = StoragePreferences(iCloudSyncEnabled: true, sealedBackupJournalEnabled: false)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", preferences: off)
        defer { phone.host.tearDownWorldPassport() }
        try phone.host.worldPassport.restore(Self.book([(Self.france, Self.t1)]))

        let report = await phone.engine.perform(.journalNarratives, trigger: .enable, phases: .both)
        #expect(report.gateFailure == .backupOff)
        #expect(phone.host.worldPassport.book.discoveries(of: .sea) == 0, "nothing restored with the switch off")
        #expect(try await Self.cloudPassport(cloud) == Self.oldPassport, "nothing exported with the switch off")

        phone.preferences = JournalBackupDevice.backupOn
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.worldPassport.book.firstVisit(.sea, token: Self.seaToken) == Self.t2)
    }

    /// A passport a newer Fernlet wrote (a version this build does not read) is never dropped or written
    /// over: the restore names the set as needing a newer Fernlet, and nothing of it — journal or
    /// passport — is merged.
    @Test func aNewerPassportNeedsANewerFernletAndMergesNothing() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let writer = try PeriodBackupDevice.reader(cloud)
        let tag = PeriodBackupDevice.tag("newer")
        let envelope = SealedBackupV2Envelope(
            writer: tag, set: tag, total: 1, records: [JournalBackupDevice.entry("from a newer Fernlet", day: 1)],
            passport: Data(#"{"version":2}"#.utf8)
        )
        let head = try writer.sealChunk(try SealedBackupV2Format.encode(envelope), payloadType: .journalNarratives,
                                        chunkIndex: 0, chunkCount: 1, generation: 3, keySalt: SealedBackupService.mintKeySalt())
        try await writer.save(head, setTag: tag)

        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        defer { phone.host.tearDownWorldPassport() }
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .needsNewerFernlet)
        #expect(phone.storedIDs.isEmpty, "no journal entry merged")
        #expect(phone.host.worldPassport.book.isEmpty, "no passport merged")
        #expect(try await JournalBackupDevice.cloudHead(cloud)?.writer == tag, "and nothing written over it")
    }
}
