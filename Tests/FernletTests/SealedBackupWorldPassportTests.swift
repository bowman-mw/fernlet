//
//  SealedBackupWorldPassportTests.swift
//  FernletTests
//
//  The World passport in Fernlet's Sealed iCloud backup (round 7; owner 2026-10-29: "so a new phone gets
//  it back", and the passport backup should "have its own switch"). The passport is a payload of its own
//  (`.worldPassport`, `PassportBackupAdapter`) behind `sealedBackupPassportEnabled`, so these drive it
//  end to end through the coordinator over the in-memory cloud — one `JournalBackupDevice` per iPhone
//  (its coordinator runs every payload), each with its own `WorldAtlasKeeper` over an ephemeral vault
//  (`FakeSealedBackupHost.worldPassport`) — and pin that the journal's set no longer carries it.
//

import CloudKit
import CloudKitSync
import FernletFoundation
import Foundation
import PrivateMemoryStore
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

    /// iCloud sync and the passport's own switch on (the journal's off), its upload owed.
    nonisolated static let passportOn = StoragePreferences(
        iCloudSyncEnabled: true, sealedBackupPassportEnabled: true, sealedBackupPassportReuploadDeferred: true
    )
    /// iCloud sync and both switches on.
    nonisolated static let bothOn = StoragePreferences(
        iCloudSyncEnabled: true, sealedBackupJournalEnabled: true, sealedBackupPassportEnabled: true
    )

    /// A passport of `visits`, recorded in order.
    nonisolated static func book(_ visits: [(AtlasVisit, Date)]) -> PassportBook {
        var book = PassportBook()
        for (visit, date) in visits { _ = book.record(visit, at: date) }
        return book
    }

    /// The old iPhone's passport: the United States, then the test sea.
    nonisolated static let oldPassport = book([(us, t1), (sea, t2)])

    /// An old iPhone (its passport restore resolved, the passport backup on) that writes `passport` to
    /// `cloud`.
    static func writeOldBackup(_ cloud: FakeSealedBackupCloud, passport: PassportBook = oldPassport) async throws {
        let old = JournalBackupDevice(cloud: cloud, writer: "old", preferences: passportOn)
        defer { old.host.tearDownWorldPassport() }
        old.host.sealedBackupBookkeeping.markRestoreResolved(.worldPassport)
        try old.host.worldPassport.restore(passport)
        #expect(await old.coordinator.setSealedBackupEnabled(true, payloadType: .worldPassport))
    }

    /// The passport the passport set in `cloud` carries, or nil when there is no set.
    static func cloudPassport(_ cloud: FakeSealedBackupCloud) async throws -> PassportBook? {
        let reader = try PeriodBackupDevice.reader(cloud)
        guard let head = try await reader.fetchHeadRecord(payloadType: .worldPassport) else { return nil }
        let plaintext = try reader.open(head)
        let set = try SealedBackupV2Format.header(of: plaintext).set
        let suffix = try await reader.fetchSuffixRecords(payloadType: .worldPassport, chunkCount: head.chunkCount, setTag: set)
        let plaintexts = [plaintext] + (try suffix.map { try reader.open($0) })
        let records = try plaintexts.flatMap {
            try JSONDecoder().decode(SealedBackupV2Envelope<PassportBackupRecord>.self, from: $0).records
        }
        return try PassportBackupAdapter.book(of: records)
    }

    /// The writer of the passport set's head in `cloud`.
    static func cloudWriter(_ cloud: FakeSealedBackupCloud) async throws -> String? {
        let reader = try PeriodBackupDevice.reader(cloud)
        guard let head = try await reader.fetchHeadRecord(payloadType: .worldPassport) else { return nil }
        return try SealedBackupV2Format.header(of: try reader.open(head)).writer
    }

    /// The passport record names in `cloud`.
    static func passportNames(_ cloud: FakeSealedBackupCloud) -> [String] {
        cloud.sealedRecords.map(\.recordID.recordName).filter { $0.contains(SealedBackupPayloadType.worldPassport.rawValue) }
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

    /// Seals `envelope` as the only chunk of a `payload` set written by `tag` at generation 3.
    static func plant(_ envelope: Data, payload: SealedBackupPayloadType, tag: String, in cloud: FakeSealedBackupCloud) async throws {
        let writer = try PeriodBackupDevice.reader(cloud)
        let head = try writer.sealChunk(envelope, payloadType: payload, chunkIndex: 0, chunkCount: 1,
                                        generation: 3, keySalt: SealedBackupService.mintKeySalt())
        try await writer.save(head, setTag: tag)
    }

    // MARK: - The round trip

    /// Export -> restore into a fresh iPhone: the passport is its own sealed set (no token and no record
    /// key reaches CloudKit in the clear), and a new iPhone's restore merges it into its passport and
    /// saves it in its own sealed vault.
    @Test func thePassportIsItsOwnSealedSetAndComesBackOnANewPhone() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        #expect(try await Self.cloudPassport(cloud) == Self.oldPassport)
        let stored = try Self.cloudBytes(cloud)
        #expect(!stored.isEmpty)
        for bytes in stored {
            #expect(bytes.range(of: Data(Self.seaToken.utf8)) == nil, "a passport token reached CloudKit in the clear")
            #expect(bytes.range(of: Data(#""token""#.utf8)) == nil, "a passport record reached CloudKit in the clear")
        }

        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", preferences: Self.passportOn)
        defer { phone.host.tearDownWorldPassport() }
        await phone.coordinator.settleV2Backup(.worldPassport)
        #expect(phone.host.recordedOutcomes[.worldPassport] == .restored(Self.oldPassport.discoveries.count))
        #expect(phone.host.worldPassport.book == Self.oldPassport)
        let reopened = PassportStore(vault: phone.host.worldPassportVault)
        try reopened.load()
        #expect(reopened.book == Self.oldPassport, "the merge was saved, sealed on the iPhone")
        #expect(phone.host.recordedOutcomes[.journalNarratives] == nil, "the journal's backup was not asked")
    }

    /// The merge is by token, the earliest date kept and nothing local removed; the follow-through export
    /// publishes the union under this iPhone's writer.
    @Test func theMergeKeepsTheEarliestDateAndEveryLocalEntry() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", preferences: Self.passportOn)
        defer { phone.host.tearDownWorldPassport() }
        try phone.host.worldPassport.restore(Self.book([(Self.us, Self.t2), (Self.france, Self.t1)]))

        await phone.coordinator.settleV2Backup(.worldPassport)
        let merged = phone.host.worldPassport.book
        #expect(merged.firstVisit(.country, token: "US") == Self.t1, "the backup's earlier date")
        #expect(merged.firstVisit(.terrain, token: "temperateForest") == Self.t1)
        #expect(merged.firstVisit(.country, token: "FR") == Self.t1, "a local entry is never removed")
        #expect(merged.firstVisit(.sea, token: Self.seaToken) == Self.t2, "an entry only in the backup is added")
        #expect(try await Self.cloudPassport(cloud) == merged, "the union is published")
        #expect(try await Self.cloudWriter(cloud) == phone.writer)
    }

    /// An empty passport exports an empty set; restoring it adds nothing, keeps this iPhone's passport
    /// as it is, and the follow-through export then carries this iPhone's.
    @Test func anEmptyPassportRestoresNothingAndTheExportAddsTheLocalOne() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud, passport: PassportBook())
        #expect(try await Self.cloudPassport(cloud) == PassportBook(), "an empty set is written")
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", preferences: Self.passportOn)
        defer { phone.host.tearDownWorldPassport() }
        let local = Self.book([(Self.france, Self.t1)])
        try phone.host.worldPassport.restore(local)

        await phone.coordinator.settleV2Backup(.worldPassport)
        #expect(phone.host.recordedOutcomes[.worldPassport] == .nothingToRestore)
        #expect(phone.host.worldPassport.book == local)
        #expect(try await Self.cloudPassport(cloud) == local)
    }

    /// Every trip comes back on a new iPhone (owner 2026-10-29, "Stamp each trip"): the set holds a record per
    /// trip, the latest with the country's clock, and the restored passport has the same trips and clock.
    @Test func everyTripComesBackOnANewPhone() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let week = 8 * 86_400.0
        let travelled = Self.book([(Self.us, Self.t1), (Self.france, Self.t2), (Self.us, Self.t2.addingTimeInterval(week)),
                                   (Self.us, Self.t2.addingTimeInterval(week + 3_600))])
        #expect(travelled.trips(inCountry: "US").count == 2)
        try await Self.writeOldBackup(cloud, passport: travelled)
        #expect(try await Self.cloudPassport(cloud) == travelled)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", preferences: Self.passportOn)
        defer { phone.host.tearDownWorldPassport() }
        await phone.coordinator.settleV2Backup(.worldPassport)
        #expect(phone.host.worldPassport.book == travelled)
        #expect(phone.host.worldPassport.book.lastSeen(inCountry: "US") == Self.t2.addingTimeInterval(week + 3_600))
        #expect(phone.host.worldPassport.book.count(of: .country) == 2, "the counts count each country once")
    }

    // MARK: - What it never does

    /// A decoy session exports nothing real and restores nothing: the passport's duress gate stops both
    /// before any read or decrypt, and nothing is written to the vault.
    @Test func aDecoyExportsNothingAndRestoresNothing() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = JournalBackupDevice(cloud: cloud, writer: "old", preferences: Self.passportOn)
        defer { old.host.tearDownWorldPassport() }
        old.host.sealedBackupBookkeeping.markRestoreResolved(.worldPassport)
        try old.host.worldPassport.restore(Self.oldPassport)
        old.host.markSealedBackupDirty(.worldPassport)
        old.host.duressSessionActive = true
        old.host.worldPassport.setDecoy(true)
        let report = await old.engine.perform(.worldPassport, trigger: .enable, phases: .export)
        #expect(report.gateFailure == .duress)
        #expect(Self.passportNames(cloud).isEmpty, "a decoy exports nothing")
        old.host.duressSessionActive = false
        old.host.worldPassport.setDecoy(false)
        #expect(await old.engine.perform(.worldPassport, trigger: .enable, phases: .export).exportStatus == .upToDate)

        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", preferences: Self.passportOn)
        defer { phone.host.tearDownWorldPassport() }
        phone.host.duressSessionActive = true
        phone.host.worldPassport.setDecoy(true)
        await phone.coordinator.settleV2Backup(.worldPassport)
        phone.host.duressSessionActive = false
        phone.host.worldPassport.setDecoy(false)
        #expect(phone.host.worldPassport.book.isEmpty, "a decoy restores nothing")
        #expect(try phone.host.worldPassportVault.read(.passport) == nil)
        #expect(try await Self.cloudWriter(cloud) == old.writer, "and writes nothing")
    }

    /// A passport that can't be read right now (the phone locked) fails the export with nothing
    /// written, never an empty set over the one in iCloud; once it can be read, the export carries it.
    @Test func aPassportThatCantBeReadFailsTheExportRatherThanWriteItEmpty() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = JournalBackupDevice(cloud: cloud, writer: "old", preferences: Self.passportOn)
        defer { old.host.tearDownWorldPassport() }
        old.host.sealedBackupBookkeeping.markRestoreResolved(.worldPassport)
        try old.host.worldPassport.restore(Self.oldPassport)
        old.host.markSealedBackupDirty(.worldPassport)
        old.host.passportUnreadable = true
        let report = await old.engine.perform(.worldPassport, trigger: .enable, phases: .export)
        #expect(report.exportStatus == .failed)
        #expect(Self.passportNames(cloud).isEmpty, "nothing written")
        #expect(old.host.isSealedBackupReuploadOwed(.worldPassport), "the upload is still owed")
        old.host.passportUnreadable = false
        #expect(await old.engine.perform(.worldPassport, trigger: .enable, phases: .export).exportStatus == .upToDate)
        #expect(try await Self.cloudPassport(cloud) == Self.oldPassport)
    }

    /// A passport set a newer Fernlet wrote (a kind this build does not know) is never dropped or written
    /// over: the restore names it as needing a newer Fernlet, and nothing of it is merged.
    @Test func aNewerPassportNeedsANewerFernletAndMergesNothing() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let tag = PeriodBackupDevice.tag("newer")
        let records = [
            PassportBackupRecord(id: UUID(), kind: "country", token: "US", date: Self.t1),
            PassportBackupRecord(id: UUID(), kind: "galaxy", token: "milkyWay", date: Self.t1)
        ]
        let envelope = SealedBackupV2Envelope(writer: tag, set: tag, total: records.count, records: records)
        try await Self.plant(try SealedBackupV2Format.encode(envelope), payload: .worldPassport, tag: tag, in: cloud)

        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", preferences: Self.passportOn)
        defer { phone.host.tearDownWorldPassport() }
        await phone.coordinator.settleV2Backup(.worldPassport)
        #expect(phone.host.recordedOutcomes[.worldPassport] == .needsNewerFernlet)
        #expect(phone.host.worldPassport.book.isEmpty, "no passport entry merged")
        #expect(try await Self.cloudWriter(cloud) == tag, "and nothing written over it")
    }

    // MARK: - The owner hold

    /// The app-lock reset's owner hold covers the passport: no restore merges it until the owner's own
    /// release, which then does.
    @Test func theOwnerHoldHoldsThePassportRestoreUntilTheRelease() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", preferences: Self.passportOn)
        defer { phone.host.tearDownWorldPassport() }
        phone.host.sealedBackupRestoreAwaitsOwner = true

        #expect(await phone.coordinator.restoreV2Backup(.worldPassport) == .deferredTransient)
        #expect(phone.host.worldPassport.book.isEmpty, "a held restore merges no passport")
        await phone.coordinator.releaseRestoreHoldForOwner()
        #expect(phone.host.worldPassport.book == Self.oldPassport, "the owner's release merges it")
    }

    /// The owner hold's export half: while it keeps the passport's pre-reset copy, this iPhone's passport
    /// is not written over it.
    @Test func theOwnerHoldKeepsThePreResetPassportInICloud() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", preferences: Self.passportOn)
        defer { phone.host.tearDownWorldPassport() }
        phone.host.sealedBackupBookkeeping.markRestoreResolved(.worldPassport)
        phone.host.restoreHold.hold(keepingCopiesFrom: Self.passportOn)
        try phone.host.worldPassport.restore(Self.book([(Self.france, Self.t1)]))
        phone.host.markSealedBackupDirty(.worldPassport)

        await phone.coordinator.retryDeferredReuploadIfNeeded(payloadType: .worldPassport)
        #expect(phone.host.v2Status[.worldPassport] == .heldForOwner)
        #expect(try await Self.cloudPassport(cloud) == Self.oldPassport)
    }

    // MARK: - Its own switch

    /// The passport's OWN switch gates it: with it off nothing is restored or exported, whatever the
    /// journal's says; once it is on, the restore merges the passport.
    @Test func itsOwnSwitchGatesThePassport() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let journalOnly = StoragePreferences(iCloudSyncEnabled: true, sealedBackupJournalEnabled: true)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", preferences: journalOnly)
        defer { phone.host.tearDownWorldPassport() }
        try phone.host.worldPassport.restore(Self.book([(Self.france, Self.t1)]))

        let report = await phone.engine.perform(.worldPassport, trigger: .enable, phases: .both)
        #expect(report.gateFailure == .backupOff)
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.worldPassport.book.discoveries(of: .sea) == 0, "the journal's switch restores no passport")
        #expect(try await Self.cloudPassport(cloud) == Self.oldPassport, "nothing exported with its switch off")

        phone.preferences = Self.passportOn
        await phone.coordinator.settleV2Backup(.worldPassport)
        #expect(phone.host.worldPassport.book.firstVisit(.sea, token: Self.seaToken) == Self.t2)
    }

    /// The journal's export carries no passport: its envelopes hold exactly the frozen journal keys, and
    /// no passport set is written by the journal's switch.
    @Test func theJournalExportCarriesNoPassport() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        defer { old.host.tearDownWorldPassport() }
        try old.write(JournalBackupDevice.entry("a day out", day: 1))
        try old.host.worldPassport.restore(Self.oldPassport)
        #expect(await old.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))

        let reader = try PeriodBackupDevice.reader(cloud)
        let head = try #require(try await reader.fetchHeadRecord(payloadType: .journalNarratives))
        let object = try #require(try JSONSerialization.jsonObject(with: try reader.open(head)) as? [String: Any])
        #expect(Set(object.keys) == ["v", "writer", "set", "total", "records"], "no passport key on the journal's head")
        #expect(Self.passportNames(cloud).isEmpty, "the journal's switch writes no passport set")
    }

    // MARK: - Earlier backups

    /// A journal head an earlier build of this round wrote WITH the old `"passport"` key, and one
    /// without it, both restore the journal cleanly: the key is ignored (nothing merged into the
    /// passport from it), and with no passport set in iCloud the passport's own restore finds nothing.
    @Test(arguments: [true, false])
    func journalHeadsWithOrWithoutTheOldPassportKeyRestoreCleanly(_ withOldKey: Bool) async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let tag = PeriodBackupDevice.tag("earlier")
        let entry = JournalBackupDevice.entry("from an earlier build", day: 1)
        let envelope = SealedBackupV2Envelope(writer: tag, set: tag, total: 1, records: [entry])
        var object = try #require(
            try JSONSerialization.jsonObject(with: try SealedBackupV2Format.encode(envelope)) as? [String: Any]
        )
        if withOldKey { object["passport"] = try Self.oldPassport.encoded().base64EncodedString() }
        try await Self.plant(try JSONSerialization.data(withJSONObject: object), payload: .journalNarratives, tag: tag, in: cloud)

        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", preferences: Self.bothOn)
        defer { phone.host.tearDownWorldPassport() }
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .restored(1))
        #expect(phone.storedIDs == [entry.id])
        #expect(phone.host.worldPassport.book.isEmpty, "the old head key is never merged")
        await phone.coordinator.settleV2Backup(.worldPassport)
        #expect(phone.host.recordedOutcomes[.worldPassport] == .nothingToRestore, "no passport set: nothing to restore")
        #expect(phone.host.worldPassport.book.isEmpty)
    }
}
