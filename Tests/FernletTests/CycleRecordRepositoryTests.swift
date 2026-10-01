// CycleRecordRepositoryTests.swift
// FernletTests
//
// The sealed `CycleRecord` store (period-data design 2026-09-30, §5.2, §6.1, §6.2): the entity's
// exact shape (I4), the post-decrypt id check (I27), the round trip under the right key and the
// refusal under any other, the tolerant decode, the store bound, the total order of the pager, the
// keyless deletes, every class of the one upsert write path, the edit, and the gated funnel.
//
// Every test runs on its own in-memory store. `@MainActor` wherever a binding override is used: the
// override is task-local, and the view context's `performAndWait` runs inline only on the main actor.

import CoreData
import CryptoKit
import Foundation
import Testing
@testable import FernletCrypto
import FernletFoundation
import PrivateHealthStore
import PrivateStoreCore

@Suite(.serialized)
struct CycleRecordRepositoryTests {
    private static let early = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let late = Date(timeIntervalSinceReferenceDate: 800_086_400)

    private func makeController() -> PrivatePersistenceController { PrivatePersistenceController(inMemory: true) }
    private func makeKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    private func record(id: UUID = UUID(), flow: PeriodFlowLevel? = .medium, note: String? = "note",
                        at date: Date = Self.early) -> CycleRecord {
        CycleRecord(
            id: id, dayKey: FernletDate.dayKey(for: date), loggedAt: date,
            clinical: CycleClinicalFields(flowLevel: flow, updatedAt: date),
            narrative: CycleNarrativeFields(note: note, symptomFlags: [.cramps], customSymptomScales: ["ache": 2], updatedAt: date),
            origin: .logged, createdAt: date, updatedAt: date
        )
    }

    /// Every stored row's raw columns, for tests that tamper with them.
    private func rows(in controller: PrivatePersistenceController) throws -> [NSManagedObject] {
        let context = controller.container.viewContext
        return try context.performAndWait {
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "CycleRecord"))
        }
    }

    // MARK: - I4: the entity's shape

    /// EXACTLY `id`, `schemaVersion`, `payloadCiphertext` — no date, day key, timestamp or HealthKit
    /// id beside the ciphertext — and no uniqueness constraint (the property-object-trump merge
    /// policy would turn a conflict into a silent overwrite).
    @Test func theEntityHoldsOnlyAnIDAVersionAndOneCiphertext() throws {
        let model = makeController().container.managedObjectModel
        let entity = try #require(model.entitiesByName["CycleRecord"])
        #expect(Set(entity.attributesByName.keys) == ["id", "schemaVersion", "payloadCiphertext"])
        #expect(entity.relationshipsByName.isEmpty)
        #expect(entity.uniquenessConstraints.isEmpty)
        #expect(entity.attributesByName["payloadCiphertext"]?.allowsExternalBinaryDataStorage == false)
        #expect(entity.attributesByName["id"]?.attributeType == .UUIDAttributeType)
        #expect(entity.indexes.contains { $0.elements.contains { $0.property?.name == "id" } }, "fetch-by-id is the write path; it must be indexed")
    }

    // MARK: - Round trip, keys, id check

    @Test func aRecordRoundTripsUnderItsKeyAndIsDeadUnderAnyOther() throws {
        let repo = CycleRecordRepository(controller: makeController())
        let key = makeKey()
        let original = record()
        try repo.insert(original, contentKey: key)

        let page = try repo.records(offset: 0, limit: 10, contentKey: key)
        #expect(page.records == [original])
        #expect(page.isFullyOpen)

        let foreign = try repo.records(offset: 0, limit: 10, contentKey: makeKey())
        #expect(foreign.records.isEmpty)
        #expect(foreign.deadIDs == [original.id])
        #expect(try repo.records(offset: 0, limit: 10, contentKey: nil) == CycleRecordPage(), "no key reads nothing")
    }

    /// I27: `ColumnCrypto`'s AAD does not bind the row id, so a blob copied onto another row OPENS.
    /// The repository refuses it after the decrypt, and the pre-pass counts it.
    @MainActor
    @Test func aBlobMovedOntoAnotherRowIsDead() throws {
        let controller = makeController()
        let repo = CycleRecordRepository(controller: controller)
        let key = makeKey()
        let victim = record(note: "victim")
        let donor = record(note: "donor")
        try repo.insert(victim, contentKey: key)
        try repo.insert(donor, contentKey: key)
        let context = controller.container.viewContext
        try context.performAndWait {
            let all = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "CycleRecord"))
            let victimRow = try #require(all.first { $0.value(forKey: "id") as? UUID == victim.id })
            let donorRow = try #require(all.first { $0.value(forKey: "id") as? UUID == donor.id })
            victimRow.setValue(donorRow.value(forKey: "payloadCiphertext"), forKey: "payloadCiphertext")
            try context.save()
        }
        let page = try repo.records(ids: [victim.id, donor.id], contentKey: key)
        #expect(page.records == [donor])
        #expect(page.deadIDs == [victim.id])

        let store = CycleRecordStore(repository: repo)
        store.attachVisibilityGate { true }
        let prePass = try store.backupPrePass(contentKey: key)
        #expect(prePass.deadIDs == [victim.id])
        #expect(!prePass.isExportable, "an export over a moved blob must refuse")
    }

    /// A binding read that did not answer decides nothing: undecided, never dead — and a write over
    /// an undecided row throws with nothing saved.
    @MainActor
    @Test func anUnansweredBindingReadIsUndecidedAndBlocksAnOverwrite() throws {
        let repo = CycleRecordRepository(controller: makeController())
        let key = makeKey()
        let stored = record()
        try repo.insert(stored, contentKey: key)
        let page = try DeviceBindingID.$testOverride.withValue(.readError) {
            try repo.records(offset: 0, limit: 10, contentKey: key)
        }
        #expect(page.transientCount == 1)
        #expect(page.deadIDs.isEmpty)
        #expect(throws: CycleRecordRepositoryError.undecidedRows(count: 1)) {
            try DeviceBindingID.$testOverride.withValue(.readError) {
                try repo.upsertMerged([record(id: stored.id, note: "incoming")], retiringNarrativeIDs: [], contentKey: key)
            }
        }
        #expect(try repo.records(offset: 0, limit: 10, contentKey: key).records == [stored])
    }

    /// A row a NEWER build wrote (its plaintext schema column above this build's) is undecided —
    /// never dead, so nothing here overwrites it.
    @Test func aNewerBuildsRowIsUndecidedNotDead() throws {
        let controller = makeController()
        let repo = CycleRecordRepository(controller: controller)
        let key = makeKey()
        let stored = record()
        try repo.insert(stored, contentKey: key)
        let context = controller.container.viewContext
        try context.performAndWait {
            try rows(in: controller).forEach { $0.setValue(Int16(3), forKey: "schemaVersion") }
            try context.save()
        }
        let page = try repo.records(offset: 0, limit: 10, contentKey: key)
        #expect(page.transientCount == 1 && page.deadIDs.isEmpty && page.records.isEmpty)
        #expect(throws: CycleRecordRepositoryError.undecidedRows(count: 1)) {
            try repo.upsertMerged([record(id: stored.id)], retiringNarrativeIDs: [], contentKey: key)
        }
    }

    // MARK: - Tolerant decode and the frozen shape

    @Test func decodingIsTolerantPerToken() throws {
        let json = """
        {"v":2,"id":"0A0A0A0A-1B1B-4C4C-8D8D-2E2E2E2E2E2E","dayKey":"2026-09-01","loggedAt":800000000,
         "origin":"fromTheFuture","createdAt":800000000,"updatedAt":800000000,
         "clinical":{"flowLevel":"torrential","isCycleStart":true,"basalBodyTemperature":98.1,
                     "temperatureUnit":"kelvin","cervicalMucusQuality":"eggWhite","updatedAt":800000000},
         "narrative":{"note":"kept","symptomFlags":["cramps","newSymptom"],"customSymptomScales":{"a":1},"updatedAt":800000000}}
        """
        let decoded = try CycleRecord(frozenJSON: Data(json.utf8))
        #expect(decoded.origin == .importedLegacy, "an unknown origin is the least specific claim")
        #expect(decoded.clinical?.flowLevel == nil, "an unknown flow token is nil, not a failure")
        #expect(decoded.clinical?.isCycleStart == true)
        #expect(decoded.clinical?.basalBodyTemperature == nil, "a temperature whose unit is unknown is dropped with it")
        #expect(decoded.clinical?.cervicalMucusQuality == .eggWhite)
        #expect(decoded.narrative?.symptomFlags == [.cramps], "an unknown symptom is dropped, the rest kept")
        #expect(decoded.narrative?.note == "kept")
    }

    @Test func aNewerSchemaThrowsItsOwnErrorAndAMalformedOneIsCorrupt() throws {
        let base = try String(data: record().frozenJSON(), encoding: .utf8) ?? ""
        #expect(throws: CycleRecordDecodingError.unsupportedSchemaVersion(found: 3)) {
            try CycleRecord(frozenJSON: Data(base.replacingOccurrences(of: "\"v\":2", with: "\"v\":3").utf8))
        }
        #expect(throws: DecodingError.self) {
            try CycleRecord(frozenJSON: Data(base.replacingOccurrences(of: "\"v\":2", with: "\"v\":1").utf8))
        }
        let original = record()
        #expect(try CycleRecord(frozenJSON: original.frozenJSON()) == original, "the frozen JSON round-trips exactly")
    }

    // MARK: - Bound, order, keyless reads

    /// R3: past `maxStoredRecords` an insert throws, and nothing is written. The table is filled with
    /// raw rows (sealing 20 000 records would only test the sealer's speed).
    @Test func theStoreIsBoundedAndRefusesPastTheBound() throws {
        let controller = makeController()
        let repo = CycleRecordRepository(controller: controller)
        let context = controller.container.viewContext
        try context.performAndWait {
            for _ in 0..<CycleRecordRepository.maxStoredRecords {
                let row = NSEntityDescription.insertNewObject(forEntityName: "CycleRecord", into: context)
                row.setValue(UUID(), forKey: "id")
                row.setValue(Int16(2), forKey: "schemaVersion")
                row.setValue(Data([0x03, 0x00]), forKey: "payloadCiphertext")
            }
            try context.save()
        }
        #expect(throws: CycleRecordRepositoryError.storeFull(limit: CycleRecordRepository.maxStoredRecords)) {
            try repo.insert(record(), contentKey: makeKey())
        }
        #expect(try repo.recordCount() == CycleRecordRepository.maxStoredRecords)
    }

    /// The pager is a total order by id: every row exactly once across pages, and `allIDs` is the
    /// same order, keyless.
    @Test func pagesCoverEveryRowExactlyOnceInIDOrder() throws {
        let repo = CycleRecordRepository(controller: makeController())
        let key = makeKey()
        let stored = (0..<7).map { index in record(at: Self.early.addingTimeInterval(Double(index))) }
        for item in stored { try repo.insert(item, contentKey: key) }
        var seen: [UUID] = []
        for offset in stride(from: 0, to: 7, by: 3) {
            seen += try repo.records(offset: offset, limit: 3, contentKey: key).records.map(\.id)
        }
        #expect(seen.count == 7 && Set(seen) == Set(stored.map(\.id)))
        #expect(try repo.allIDs() == seen, "the keyless snapshot is the pager's order")
        #expect(try repo.recordCount() == 7)
        #expect(try repo.allRecords(contentKey: key).records.map(\.id) == seen)
    }

    @Test func deletesAreKeylessAndExact() throws {
        let repo = CycleRecordRepository(controller: makeController())
        let key = makeKey()
        let keep = record(), drop = record()
        try repo.insert(keep, contentKey: key)
        try repo.insert(drop, contentKey: key)
        #expect(try repo.delete(ids: [drop.id, UUID()]) == 1)
        #expect(try repo.allIDs() == [keep.id])
        #expect(try repo.deleteAll())
        #expect(try repo.recordCount() == 0)
        #expect(try !repo.deleteAll(), "an empty table reports nothing removed")
    }

    // MARK: - The one write path

    /// Absent → inserted; present and openable → merged (and re-sealed only when it changed); every
    /// stored row dead → replaced; nothing new → unchanged; the named narratives retire in the SAME
    /// save.
    @Test func upsertInsertsMergesReplacesAndRetiresInOneSave() throws {
        let controller = makeController()
        let repo = CycleRecordRepository(controller: controller)
        let key = makeKey()
        let narratives = MenstrualNarrativeRepository(controller: controller, defaults: UserDefaults(suiteName: "fernlet.tests.cycleRecord.\(UUID().uuidString)") ?? .standard)
        let legacy = MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-09-01", note: "old")
        try narratives.insert(legacy, contentKey: key)

        let present = record(flow: .light, note: nil)
        let dead = record(note: "sealed under a lost key")
        try repo.insert(present, contentKey: key)
        try repo.insert(dead, contentKey: makeKey())
        var laterNarrative = present
        laterNarrative.clinical = nil
        laterNarrative.narrative = CycleNarrativeFields(note: "added later", symptomFlags: [], customSymptomScales: [:], updatedAt: Self.late)
        let fresh = record()
        let replacement = record(id: dead.id, note: "openable copy")

        let result = try repo.upsertMerged([fresh, laterNarrative, replacement], retiringNarrativeIDs: [legacy.id], contentKey: key)
        #expect(result.inserted == 1 && result.merged == 1 && result.replaced == 1 && result.retiredNarratives == 1)
        let byID = Dictionary(uniqueKeysWithValues: try repo.allRecords(contentKey: key).records.map { ($0.id, $0) })
        #expect(byID[present.id]?.clinical?.flowLevel == .light, "the known clinical block was kept")
        #expect(byID[present.id]?.narrative?.note == "added later", "the newer narrative block won")
        #expect(byID[dead.id]?.narrative?.note == "openable copy")
        #expect(byID[fresh.id] == fresh)
        #expect(try narratives.narrativeCount() == 0)

        let again = try repo.upsertMerged([fresh, laterNarrative, replacement], retiringNarrativeIDs: [], contentKey: key)
        #expect(again.unchanged == 3 && !again.changedAnything, "running the same batch twice changes nothing")
    }

    /// A failed seal rolls the WHOLE batch back: no half-built row, and the named narratives stay.
    @MainActor
    @Test func aRefusedSealWritesNothing() throws {
        let controller = makeController()
        let repo = CycleRecordRepository(controller: controller)
        let key = makeKey()
        let narratives = MenstrualNarrativeRepository(controller: controller, defaults: UserDefaults(suiteName: "fernlet.tests.cycleRecord.\(UUID().uuidString)") ?? .standard)
        let legacy = MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-09-01", note: "old")
        try narratives.insert(legacy, contentKey: key)
        #expect(throws: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
            try DeviceBindingID.$testOverride.withValue(.unavailable) {
                try repo.upsertMerged([record(), record()], retiringNarrativeIDs: [legacy.id], contentKey: key)
            }
        }
        #expect(try repo.recordCount() == 0)
        #expect(try narratives.narrativeCount() == 1)
        #expect(throws: FernletLockError.locked) { try repo.upsertMerged([record()], retiringNarrativeIDs: [], contentKey: nil) }
    }

    /// Stray duplicate rows of one id (a no-constraint table can hold them) collapse on the next write.
    @Test func duplicateRowsOfOneIDCollapseOnTheNextWrite() throws {
        let controller = makeController()
        let repo = CycleRecordRepository(controller: controller)
        let key = makeKey()
        let original = record(note: "first copy")
        try repo.insert(original, contentKey: key)
        let context = controller.container.viewContext
        try context.performAndWait {
            let source = try #require(try rows(in: controller).first)
            let twin = NSEntityDescription.insertNewObject(forEntityName: "CycleRecord", into: context)
            for key in ["id", "schemaVersion", "payloadCiphertext"] { twin.setValue(source.value(forKey: key), forKey: key) }
            try context.save()
        }
        #expect(try repo.recordCount() == 2)
        #expect(try repo.allRecords(contentKey: key).records == [original], "readers reduce by id")
        _ = try repo.upsertMerged([original], retiringNarrativeIDs: [], contentKey: key)
        #expect(try repo.recordCount() == 1)
    }

    @Test func anInsertRefusesAnExistingIDAndAnEmptyRecord() throws {
        let repo = CycleRecordRepository(controller: makeController())
        let key = makeKey()
        let stored = record()
        try repo.insert(stored, contentKey: key)
        #expect(throws: CycleRecordRepositoryError.recordExists(stored.id)) { try repo.insert(stored, contentKey: key) }
        let empty = record(flow: nil, note: nil)
        var nothing = empty
        nothing.narrative = CycleNarrativeFields(note: nil, symptomFlags: [], customSymptomScales: [:], updatedAt: Self.early)
        #expect(throws: CycleRecordRepositoryError.recordNotStorable(nothing.id)) { try repo.insert(nothing, contentKey: key) }
    }

    // MARK: - The edit

    /// An edit replaces in place: `createdAt` and `origin` kept, `updatedAt` stamped, and only the
    /// block whose content changed gets the new clock.
    @Test func anEditReplacesInPlaceAndRestampsOnlyTheChangedBlock() throws {
        let repo = CycleRecordRepository(controller: makeController())
        let key = makeKey()
        var stored = record()
        stored.origin = .importedLegacy
        try repo.insert(stored, contentKey: key)
        var edit = stored
        edit.origin = .logged
        edit.createdAt = Self.late
        edit.clinical?.flowLevel = .heavy
        try repo.update(edit, contentKey: key, now: Self.late)

        let after = try #require(try repo.records(ids: [stored.id], contentKey: key).records.first)
        #expect(after.clinical?.flowLevel == .heavy)
        #expect(after.clinical?.updatedAt == Self.late)
        #expect(after.narrative?.updatedAt == Self.early, "the untouched narrative keeps its clock")
        #expect(after.createdAt == Self.early && after.origin == .importedLegacy && after.updatedAt == Self.late)
        #expect(throws: CycleRecordRepositoryError.recordNotFound(UUID(uuidString: "00000000-0000-4000-8000-000000000000") ?? UUID())) {
            try repo.update(record(id: UUID(uuidString: "00000000-0000-4000-8000-000000000000") ?? UUID()), contentKey: key)
        }
    }

    /// Review round 2, N-1: an edit that gives an UNKNOWN clinical block fields brings the edit's
    /// origin (`logged`) — the block is the user's own entry, not one built from Fernlet's Apple
    /// Health samples — while an edit that leaves the block unknown keeps the stored origin.
    @Test func anEditThatFillsAnUnknownClinicalBlockTakesTheEditsOrigin() throws {
        let repo = CycleRecordRepository(controller: makeController())
        let key = makeKey()
        var stored = record()
        stored.clinical = nil
        stored.origin = .importedLegacy
        try repo.insert(stored, contentKey: key)

        var noteOnly = stored
        noteOnly.origin = .logged
        noteOnly.narrative?.note = "edited note"
        try repo.update(noteOnly, contentKey: key, now: Self.late)
        #expect(try repo.records(ids: [stored.id], contentKey: key).records.first?.origin == .importedLegacy)

        var withFlow = noteOnly
        withFlow.clinical = CycleClinicalFields(flowLevel: .light, updatedAt: Self.late)
        try repo.update(withFlow, contentKey: key, now: Self.late)
        let after = try #require(try repo.records(ids: [stored.id], contentKey: key).records.first)
        #expect(after.clinical?.flowLevel == .light)
        #expect(after.origin == .logged)
    }

    // MARK: - The gated funnel (§6.2)

    /// Hidden ⇒ inert at the seam: the display read is empty and every write, upsert, pre-pass,
    /// chunk and restore throws — while counts, ids and deletes still work (I10's storage half).
    @MainActor
    @Test func theFunnelIsInertWhileHiddenButStillCountsAndDeletes() throws {
        let repo = CycleRecordRepository(controller: makeController())
        let key = makeKey()
        let stored = record()
        try repo.insert(stored, contentKey: key)
        let store = CycleRecordStore(repository: repo)  // unwired: fail-closed
        #expect(try store.allRecords(contentKey: key) == CycleRecordPage())
        #expect(throws: PeriodTrackingHiddenError.self) { try store.insert(record(), contentKey: key) }
        #expect(throws: PeriodTrackingHiddenError.self) { try store.update(stored, contentKey: key) }
        #expect(throws: PeriodTrackingHiddenError.self) { try store.upsertMerged([stored], retiringNarrativeIDs: [], contentKey: key) }
        #expect(throws: PeriodTrackingHiddenError.self) { try store.backupPrePass(contentKey: key) }
        #expect(throws: PeriodTrackingHiddenError.self) { try store.backupChunk(ids: [stored.id], contentKey: key) }
        #expect(throws: PeriodTrackingHiddenError.self) { try store.restoreMerging([stored], contentKey: key) }
        #expect(try store.recordCount() == 1)
        #expect(try store.allIDs() == [stored.id])
        #expect(try store.delete(ids: [stored.id]) == 1)
        try store.deleteAll()
        #expect(store.mutationCounter == 1, "only the delete that removed a row moved the counter")
    }

    /// Visible but keyless ⇒ the whole backup seam THROWS `.locked`, never an empty answer. An empty
    /// chunk is a legitimate result (every id in it was deleted mid-export), so a keyless chunk that
    /// answered empty would be indistinguishable from it, and an export whose key went (the hub closed
    /// between the pre-pass and a chunk) would write a short set over the cloud copy (I16, I29).
    @MainActor
    @Test func aVisibleFunnelWithoutAKeyRefusesTheWholeBackupSeam() throws {
        let repo = CycleRecordRepository(controller: makeController())
        let stored = record()
        try repo.insert(stored, contentKey: makeKey())
        let store = CycleRecordStore(repository: repo)
        store.attachVisibilityGate { true }
        #expect(throws: FernletLockError.locked) { try store.backupPrePass(contentKey: nil) }
        #expect(throws: FernletLockError.locked) { try store.backupChunk(ids: [stored.id], contentKey: nil) }
        #expect(throws: FernletLockError.locked) { try store.backupChunk(ids: [], contentKey: nil) }
        #expect(throws: FernletLockError.locked) { try store.restoreMerging([record()], contentKey: nil) }
        #expect(try store.recordCount() == 1 && store.mutationCounter == 0, "a refused call wrote nothing")
    }

    /// The mutation hook fires after every call that changed something, and only then.
    @MainActor
    @Test func theMutationHookFiresOnlyWhenSomethingChanged() throws {
        let store = CycleRecordStore(repository: CycleRecordRepository(controller: makeController()))
        store.attachVisibilityGate { true }
        let hook = MutationTally()
        store.attachMutationHook { hook.count += 1 }
        let key = makeKey()
        let first = record()
        try store.insert(first, contentKey: key)
        _ = try store.upsertMerged([first], retiringNarrativeIDs: [], contentKey: key)
        #expect(hook.count == 1, "an upsert that changed nothing is not a mutation")
        _ = try store.restoreMerging([record()], contentKey: key)
        try store.deleteAll()
        #expect(hook.count == 3 && store.mutationCounter == 3)
        let prePass = try store.backupPrePass(contentKey: key)
        #expect(prePass.snapshotIDs.isEmpty && prePass.isExportable && prePass.mutationCounter == 3)
    }

    // MARK: - The sealed store's shared lists

    /// The reset purge and the passcode setup's prior-data count both walk `sealedEntityNames`, so a
    /// cycle record is purged by the reset and counted before a fresh key is minted.
    @Test func theResetPurgeAndThePriorDataCountIncludeCycleRecords() throws {
        let controller = makeController()
        let repo = CycleRecordRepository(controller: controller)
        try repo.insert(record(), contentKey: makeKey())
        #expect(PrivatePersistenceController.sealedEntityNames.contains("CycleRecord"))
        #expect(try controller.sealedRowCount() == 1)
        try controller.purgeEncryptedEntities()
        #expect(try repo.recordCount() == 0)
    }
}

/// Counts mutation-hook calls (a reference, so the hook's closure can bump it).
@MainActor
private final class MutationTally {
    var count = 0
}
