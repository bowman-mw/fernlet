//
//  SealedBackupBodyTallyTests.swift
//  FernletTests
//
//  The body tallies (bathroom visits, free-meal tags; World bodybuilding spec §7, owner's answer 2:
//  "inside the sealed iCloud backup") in Fernlet's Sealed iCloud backup — round 7 piece B2. They ride
//  on the head of the JOURNAL's v2 set (`SealedBackupV2Envelope.bodyTally`, `JournalBackupAdapter`),
//  so these drive the journal backup end to end through the coordinator over the in-memory cloud —
//  one `JournalBackupDevice` per iPhone, each with its own `BodyTallyStore` over an in-memory sealed
//  store and a scoped journal device key (`FakeSealedBackupHost.bodyTallies`) — plus the merge rule,
//  the funnel's gates and the store's mutation hook.
//

import CloudKit
import CloudKitSync
import CryptoKit
import Foundation
import PrivateHealthStore
import PrivateStoreCore
import Testing
@testable import Fernlet

/// The journal head as a build from before piece B2 decodes it: only the keys it knows.
private struct PreBodyTallyEnvelope: Decodable {
    let v: Int
    let writer: String
    let set: String
    let total: Int?
    let records: [JournalNarrative]
}

@MainActor
@Suite(.serialized)
struct SealedBackupBodyTallyTests {
    static let dayA = "2026-10-27"
    static let dayB = "2026-10-28"
    static let dayC = "2026-10-29"
    static let mealOne = UUID()
    static let mealTwo = UUID()

    /// An old iPhone (resolved, journal backup on) that writes one entry and its tallies — two visits
    /// and a free meal on day A, one visit on day B — then turns the journal backup on.
    static func writeOldBackup(_ cloud: FakeSealedBackupCloud, withTallies: Bool = true) async throws {
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        defer { old.host.tearDownBodyTallies() }
        try old.write(JournalBackupDevice.entry("leg day", day: 1))
        if withTallies {
            #expect(old.host.bodyTallies.setBathroomVisits(2, on: dayA, isDecoy: false) == .saved)
            #expect(old.host.bodyTallies.setFreeMeal(true, mealID: mealOne, on: dayA, isDecoy: false) == .saved)
            #expect(old.host.bodyTallies.addBathroomVisit(on: dayB, isDecoy: false) == .saved)
        }
        #expect(await old.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
    }

    /// The tallies the journal head in `cloud` carries, or nil.
    static func cloudTallies(_ cloud: FakeSealedBackupCloud) async throws -> SealedBackupBodyTallies? {
        let reader = try PeriodBackupDevice.reader(cloud)
        guard let head = try await reader.fetchHeadRecord(payloadType: .journalNarratives) else { return nil }
        return try SealedBackupV2Format.bodyTallies(of: try reader.open(head))
    }

    /// The journal head plaintext in `cloud`.
    static func cloudHeadPlaintext(_ cloud: FakeSealedBackupCloud) async throws -> Data? {
        let reader = try PeriodBackupDevice.reader(cloud)
        guard let head = try await reader.fetchHeadRecord(payloadType: .journalNarratives) else { return nil }
        return try reader.open(head)
    }

    /// Every byte CloudKit holds for the sealed backups: each record's ciphertext asset and its string
    /// and data fields.
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

    /// The day's tally on `device`, or nil.
    static func tally(_ device: JournalBackupDevice, _ day: String) -> BodyDayTally? {
        device.host.bodyTallies.tally(on: day, isDecoy: false)
    }

    // MARK: - Export and restore

    /// Export -> restore into a fresh iPhone: the tallies ride the journal set's head, sealed (no day
    /// key, field name or meal id reaches CloudKit in the clear), and the new iPhone's restore merges
    /// them into its own sealed store under its own journal device key.
    @Test func theTalliesRideTheJournalSetSealedAndComeBackOnANewPhone() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let carried = try #require(try await Self.cloudTallies(cloud))
        #expect(carried.days.map(\.dayKey) == [Self.dayA, Self.dayB], "every tally, in day order")
        let stored = try Self.cloudBytes(cloud)
        #expect(!stored.isEmpty)
        for bytes in stored {
            for plain in [Self.dayA, "bodyTally", "bathroomVisits", Self.mealOne.uuidString] {
                #expect(bytes.range(of: Data(plain.utf8)) == nil, "\(plain) reached CloudKit in the clear")
            }
        }

        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        defer { phone.host.tearDownBodyTallies() }
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .restored(1))
        #expect(Self.tally(phone, Self.dayA)?.bathroomVisits == 2)
        #expect(Self.tally(phone, Self.dayA)?.freeMealIDs == [Self.mealOne])
        #expect(Self.tally(phone, Self.dayB)?.bathroomVisits == 1)
        #expect(try BodyTallyRepository(controller: phone.host.bodyTalliesController).rowCount() == 2, "sealed on the iPhone")
    }

    /// The restore is a MERGE: per day the higher bathroom count and the union of the free-meal tags;
    /// a day only this iPhone has is kept, a day only the backup has is added, and nothing is deleted.
    /// The follow-through export publishes the union under this iPhone's writer.
    @Test func theRestoreMergesHigherCountsAndTheUnionOfTagsAndDeletesNothing() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        defer { phone.host.tearDownBodyTallies() }
        let local = phone.host.bodyTallies
        #expect(local.setBathroomVisits(1, on: Self.dayA, isDecoy: false) == .saved)
        #expect(local.setFreeMeal(true, mealID: Self.mealTwo, on: Self.dayA, isDecoy: false) == .saved)
        #expect(local.setBathroomVisits(4, on: Self.dayB, isDecoy: false) == .saved)
        #expect(local.addBathroomVisit(on: Self.dayC, isDecoy: false) == .saved)

        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(Self.tally(phone, Self.dayA)?.bathroomVisits == 2, "the backup's higher count")
        #expect(Self.tally(phone, Self.dayA)?.freeMealIDs == [Self.mealTwo, Self.mealOne], "the union, local tags first")
        #expect(Self.tally(phone, Self.dayB)?.bathroomVisits == 4, "this iPhone's higher count is kept")
        #expect(Self.tally(phone, Self.dayC)?.bathroomVisits == 1, "a local-only day is never removed")
        let published = try #require(try await Self.cloudTallies(cloud))
        #expect(published.days.map(\.dayKey) == [Self.dayA, Self.dayB, Self.dayC], "the union is published")
        #expect(published.days.map(\.bathroomVisits) == [2, 4, 1])
        #expect(try await JournalBackupDevice.cloudHead(cloud)?.writer == phone.writer)
    }

    /// Idempotent: the same restore merged again changes nothing — no row re-sealed, no count added
    /// up — at the funnel and through a second restore of the same set.
    @Test func mergingTheSameTalliesAgainChangesNothing() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let carried = try #require(try await Self.cloudTallies(cloud))
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        defer { phone.host.tearDownBodyTallies() }
        let store = phone.host.bodyTallies
        #expect(try store.mergeRestoredTallies(carried.days, isDecoy: false) == 2)
        let token = store.changeToken
        let before = store.allTallies(isDecoy: false)
        #expect(try store.mergeRestoredTallies(carried.days, isDecoy: false) == 0)
        #expect(try store.mergeRestoredTallies(carried.days + carried.days, isDecoy: false) == 0, "copies of a day fold")
        #expect(store.allTallies(isDecoy: false) == before)
        #expect(store.changeToken == token, "nothing changed, nothing redraws")

        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(store.allTallies(isDecoy: false) == before, "the engine's restore merges nothing new")
        #expect(try BodyTallyRepository(controller: phone.host.bodyTalliesController).rowCount() == 2)
    }

    // MARK: - Builds that came before

    /// A build from before piece B2 decodes only the keys it knows, so a head carrying `"bodyTally"`
    /// still reads — the header for E2 and the records for its restore.
    @Test func anOlderBuildIgnoresTheBodyTallyKey() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud)
        let plaintext = try #require(try await Self.cloudHeadPlaintext(cloud))
        #expect(String(decoding: plaintext, as: UTF8.self).contains("\"bodyTally\""))
        let older = try JSONDecoder().decode(PreBodyTallyEnvelope.self, from: plaintext)
        #expect(older.v == 2)
        #expect(older.records.map(\.text) == ["leg day"])
        #expect(try SealedBackupV2Format.header(of: plaintext).total == 1)
    }

    /// A head without tallies (an older build's, or an iPhone with none) restores the journal and
    /// leaves this iPhone's tallies as they are; the follow-through export then carries them.
    @Test func aHeadWithoutTalliesLeavesTheLocalOnesAndTheExportAddsThem() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeOldBackup(cloud, withTallies: false)
        #expect(try await Self.cloudTallies(cloud) == nil, "no tally, no key on the head")
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        defer { phone.host.tearDownBodyTallies() }
        #expect(phone.host.bodyTallies.setBathroomVisits(3, on: Self.dayC, isDecoy: false) == .saved)

        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .restored(1))
        #expect(Self.tally(phone, Self.dayC)?.bathroomVisits == 3)
        #expect(try await Self.cloudTallies(cloud)?.days.map(\.dayKey) == [Self.dayC])
    }

    /// Tallies a newer Fernlet wrote (a shape this build does not read) are never dropped or written
    /// over: the restore names the set as needing a newer Fernlet and merges nothing.
    @Test func aNewerTallyShapeNeedsANewerFernletAndMergesNothing() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let writer = try PeriodBackupDevice.reader(cloud)
        let tag = PeriodBackupDevice.tag("newer")
        let envelope = SealedBackupV2Envelope(writer: tag, set: tag, total: 1, records: [JournalBackupDevice.entry("from a newer Fernlet", day: 1)])
        var object = try #require(try JSONSerialization.jsonObject(with: try SealedBackupV2Format.encode(envelope)) as? [String: Any])
        object["bodyTally"] = ["v": 2, "days": [] as [Any]]
        let plaintext = try JSONSerialization.data(withJSONObject: object)
        let head = try writer.sealChunk(plaintext, payloadType: .journalNarratives, chunkIndex: 0, chunkCount: 1,
                                        generation: 3, keySalt: SealedBackupService.mintKeySalt())
        try await writer.save(head, setTag: tag)

        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        defer { phone.host.tearDownBodyTallies() }
        #expect(phone.host.bodyTallies.addBathroomVisit(on: Self.dayC, isDecoy: false) == .saved)
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .needsNewerFernlet)
        #expect(phone.storedIDs.isEmpty, "no journal entry merged")
        #expect(phone.host.bodyTallies.allTallies(isDecoy: false).keys.sorted() == [Self.dayC], "no tally merged")
        #expect(try await JournalBackupDevice.cloudHead(cloud)?.writer == tag, "and nothing written over it")
    }

    // MARK: - What it never does

    /// A decoy session exports nothing real and restores nothing: the journal's duress gate stops both
    /// before any decrypt, and the funnel itself refuses to hand out or merge a tally.
    @Test func aDecoyExportsNothingAndRestoresNothing() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        defer { old.host.tearDownBodyTallies() }
        try old.write(JournalBackupDevice.entry("leg day", day: 1))
        #expect(old.host.bodyTallies.setBathroomVisits(2, on: Self.dayA, isDecoy: false) == .saved)
        old.host.duressSessionActive = true
        #expect(throws: BodyTallyBackupError.decoy) { try old.host.sealedBackupBodyTallies() }
        let report = await old.engine.perform(.journalNarratives, trigger: .enable, phases: .export)
        #expect(report.gateFailure == .duress)
        #expect(JournalBackupDevice.journalNames(cloud).isEmpty, "a decoy exports nothing")
        old.host.duressSessionActive = false
        #expect(await old.engine.perform(.journalNarratives, trigger: .enable, phases: .export).exportStatus == .upToDate)

        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        defer { phone.host.tearDownBodyTallies() }
        phone.host.duressSessionActive = true
        #expect(throws: BodyTallyBackupError.decoy) {
            try phone.host.restoreSealedBackupBodyTallies([BodyDayTally(dayKey: Self.dayA, bathroomVisits: 2)])
        }
        await phone.coordinator.settleV2Backup(.journalNarratives)
        phone.host.duressSessionActive = false
        #expect(phone.host.bodyTallies.allTallies(isDecoy: false).isEmpty, "a decoy restores nothing")
        #expect(try BodyTallyRepository(controller: phone.host.bodyTalliesController).rowCount() == 0)
        #expect(try await JournalBackupDevice.cloudHead(cloud)?.writer == old.writer, "and writes nothing")
    }

    /// Tallies that can't be read right now (the keychain not answering) fail the export with nothing
    /// written — never a head without them over the one in iCloud; once they read, the export carries
    /// them.
    @Test func talliesThatCantBeReadFailTheExportRatherThanDropThem() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        defer { old.host.tearDownBodyTallies() }
        try old.write(JournalBackupDevice.entry("leg day", day: 1))
        #expect(old.host.bodyTallies.setBathroomVisits(2, on: Self.dayA, isDecoy: false) == .saved)
        old.host.bodyTalliesUnreadable = true
        #expect(await old.engine.perform(.journalNarratives, trigger: .enable, phases: .export).exportStatus == .failed)
        #expect(JournalBackupDevice.journalNames(cloud).isEmpty, "nothing written")
        old.host.bodyTalliesUnreadable = false
        #expect(await old.engine.perform(.journalNarratives, trigger: .enable, phases: .export).exportStatus == .upToDate)
        #expect(try await Self.cloudTallies(cloud)?.days.map(\.bathroomVisits) == [2])
    }

    // MARK: - The merge rule and the hook

    /// The head's `"bodyTally"` value is a frozen shape: `{"v":1,"days":[…]}`, each day under exactly
    /// the four frozen `BodyDayTally` keys — renaming one would orphan every backed-up tally.
    @Test func theBodyTallyShapeIsFrozen() throws {
        let value = SealedBackupBodyTallies(days: [
            BodyDayTally(dayKey: Self.dayB, bathroomVisits: 1, updatedAt: Date(timeIntervalSince1970: 1_800_000_000)),
            BodyDayTally(dayKey: Self.dayA, bathroomVisits: 2, freeMealIDs: [Self.mealOne], updatedAt: Date(timeIntervalSince1970: 1_800_000_060))
        ])
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(Set(object.keys) == ["v", "days"])
        #expect(object["v"] as? Int == 1)
        let days = try #require(object["days"] as? [[String: Any]])
        #expect(days.map { $0["dayKey"] as? String } == [Self.dayA, Self.dayB], "in day order")
        #expect(days.allSatisfy { Set($0.keys) == ["dayKey", "bathroomVisits", "freeMealIDs", "updatedAt"] })
        #expect(try JSONDecoder().decode(SealedBackupBodyTallies.self, from: JSONEncoder().encode(value)) == value)
    }

    /// The per-day rule: the higher count, the union of the tags (capped at 20), the later stamp; the
    /// same content whichever side merges, idempotent, and another day's tally is never folded in.
    @Test func theMergeRuleIsHigherCountUnionOfTagsCapped() {
        let early = Date(timeIntervalSince1970: 1_800_000_000)
        let late = early.addingTimeInterval(60)
        let one = BodyDayTally(dayKey: Self.dayA, bathroomVisits: 5, freeMealIDs: [Self.mealOne], updatedAt: early)
        let two = BodyDayTally(dayKey: Self.dayA, bathroomVisits: 3, freeMealIDs: [Self.mealTwo, Self.mealOne], updatedAt: late)
        let merged = one.merged(with: two)
        #expect(merged.bathroomVisits == 5)
        #expect(merged.freeMealIDs == [Self.mealOne, Self.mealTwo])
        #expect(merged.updatedAt == late)
        #expect(Set(two.merged(with: one).freeMealIDs) == Set(merged.freeMealIDs))
        #expect(two.merged(with: one).bathroomVisits == merged.bathroomVisits)
        #expect(merged.merged(with: merged).hasSameContent(as: merged))
        #expect(one.merged(with: BodyDayTally(dayKey: Self.dayB, bathroomVisits: 9)) == one)
        let many = BodyDayTally(dayKey: Self.dayA, freeMealIDs: (0..<15).map { _ in UUID() })
        let more = BodyDayTally(dayKey: Self.dayA, freeMealIDs: (0..<15).map { _ in UUID() })
        let capped = many.merged(with: more)
        #expect(capped.freeMealIDs.count == BodyDayTally.maxFreeMeals)
        #expect(Array(capped.freeMealIDs.prefix(15)) == many.freeMealIDs, "this copy's tags are never the ones dropped")
    }

    /// The mutation hook: a tally write that LANDED marks the journal's upload owed (the journal head
    /// carries the tallies); one that changed nothing, hit a limit, was dropped in a decoy or failed
    /// owes nothing.
    @Test func aLandedTallyWriteMarksTheJournalBackupOwed() {
        let store = makeTestStore()
        let before = store.sealedBackupMutationEpoch(.journalNarratives)
        let periodBefore = store.sealedBackupMutationEpoch(.periodData)
        for result: BodyTallyWriteResult in [.unchanged, .atLimit, .droppedInDecoy, .failed(.storeError)] {
            #expect(store.noteBodyTallyWrite(result) == result)
        }
        #expect(store.sealedBackupMutationEpoch(.journalNarratives) == before, "nothing landed, nothing owed")
        #expect(store.noteBodyTallyWrite(.saved) == .saved)
        #expect(store.sealedBackupMutationEpoch(.journalNarratives) == before + 1)
        #expect(store.isSealedBackupReuploadOwed(.journalNarratives))
        #expect(store.sealedBackupMutationEpoch(.periodData) == periodBefore, "only the journal's set carries them")
    }
}
