// PrivateStoreModelMigrationTests.swift
// FernletTests
//
// Invariant I22 of the period-data design (2026-09-30, §5.2): the sealed store's model is VERSIONED.
// V1 — the four-entity model every shipped build wrote — is frozen and pinned by its checksum, V2 is
// V1 plus `CycleRecord`, and a V1 store ON DISK opens under the production controller with every row
// intact, carried forward by the staged migration the production store description carries.

import CoreData
import CryptoKit
import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
@testable import PrivateStoreCore
import PrivateHealthStore
import PrivateMemoryStore

@Suite(.serialized)
struct PrivateStoreModelMigrationTests {
    /// V1's checksum, pinned. V1 is the shape shipped builds left on disk and the SOURCE of the only
    /// migration stage: if this moves, stores in the field no longer match the stage and the sealed
    /// store fails to load. Never edit V1; add a version.
    ///
    /// Proven equal to the shipped model on 2026-09-30: the four entity builders at `dbc2c9b2` (the
    /// commit before V1 was split out), compiled standalone, produce exactly this checksum.
    static let versionOneChecksum = "qMOCsQE/z+wmjE/PnTwOjUll0oj0ln2JIKPTE87bFiE="

    /// A scratch directory for an on-disk store, UUID-named per the shared-disk-root discipline.
    private static func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet-model-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Detaches every store so the file is closed before another controller opens it.
    private static func close(_ controller: PrivatePersistenceController) throws {
        let coordinator = controller.container.persistentStoreCoordinator
        for store in coordinator.persistentStores { try coordinator.remove(store) }
    }

    @Test func theVersionOneModelIsFrozen() {
        let v1 = PrivatePersistenceController.makeManagedObjectModelV1()
        #expect(v1.versionChecksum == Self.versionOneChecksum, "V1 moved — actual \(v1.versionChecksum)")
        #expect(Set(v1.entitiesByName.keys) == ["MenstrualNarrative", "JournalNarrative", "IntimacyLog", "WorryNarrative"])
    }

    /// Tagging V1 with its version identifier cannot have moved it: identifiers do not enter the
    /// checksum or the entity hashes, so the tagged V1 still names exactly the untagged model every
    /// shipped build created its store with.
    @Test func theVersionIdentifierDoesNotEnterTheChecksum() {
        let tagged = PrivatePersistenceController.makeManagedObjectModelV1()
        let bare = PrivatePersistenceController.makeManagedObjectModelV1()
        bare.versionIdentifiers = []
        #expect(tagged.versionIdentifiers.contains("FernletPrivate.v1"))
        #expect(tagged.versionChecksum == bare.versionChecksum)
        #expect(tagged.entityVersionHashesByName == bare.entityVersionHashesByName)
    }

    @Test func versionTwoIsVersionOnePlusCycleRecordAndNothingElse() {
        let v1 = PrivatePersistenceController.makeManagedObjectModelV1()
        let v2 = PrivatePersistenceController.makeManagedObjectModel()
        #expect(Set(v2.entitiesByName.keys) == Set(v1.entitiesByName.keys).union(["CycleRecord"]))
        for (name, hash) in v1.entityVersionHashesByName {
            #expect(v2.entityVersionHashesByName[name] == hash, "\(name) changed shape between V1 and V2")
        }
        #expect(v2.versionIdentifiers.contains("FernletPrivate.v2"))
        #expect(v2.versionChecksum != v1.versionChecksum)
        // The controller hosts V2 — the model every new store is created at.
        let hosted = PrivatePersistenceController(inMemory: true).container.managedObjectModel
        #expect(hosted.versionChecksum == v2.versionChecksum)
    }

    /// The production description carries the staged migration (so a rebuild or reload re-adds under
    /// it too); a fixture model supplied through the test seam does not.
    @Test func onlyTheProductionModelCarriesTheStagedMigration() {
        let production = PrivatePersistenceController(inMemory: true)
        let option = production.container.persistentStoreDescriptions.first?.options[NSPersistentStoreStagedMigrationManagerOptionKey]
        #expect(option is NSStagedMigrationManager)
        let fixture = PrivatePersistenceController(inMemory: true, model: PrivatePersistenceController.makeManagedObjectModelV1())
        #expect(fixture.container.persistentStoreDescriptions.first?.options[NSPersistentStoreStagedMigrationManagerOptionKey] == nil)
    }

    /// I22's load-bearing half: a store written under V1 — exactly what every shipped build left on
    /// disk — opens under the production controller with no load failure, every row intact and
    /// readable, and the new entity usable; and it opens again afterwards with nothing to migrate.
    @Test func aVersionOneStoreOnDiskOpensUnderVersionTwoWithEveryRowIntact() throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("FernletPrivate.sqlite")
        let key = SymmetricKey(size: .bits256)
        let latches = UserDefaults(suiteName: "fernlet.tests.modelMigration.\(UUID().uuidString)") ?? .standard
        let narrative = MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-09-01", note: "shipped note")
        let log = IntimacyLog(eventDate: Date(timeIntervalSinceReferenceDate: 800_000_000), note: "shipped log")

        // Exactly what a shipped build created its store with: the V1 entities, no version identifier.
        let shipped = PrivatePersistenceController.makeManagedObjectModelV1()
        shipped.versionIdentifiers = []
        let old = PrivatePersistenceController(storeURL: storeURL, model: shipped)
        #expect(!old.didFailToLoad)
        try MenstrualNarrativeRepository(controller: old, defaults: latches).insert(narrative, contentKey: key)
        try IntimacyLogRepository(controller: old, defaults: latches).insert(log, contentKey: key)
        try JournalNarrativeRepository(controller: old, defaults: latches).insert(
            JournalNarrative(id: UUID(), dayKey: "2026-09-01", tag: .quiet, entryDate: Date(), text: "shipped journal", emotions: [], createdAt: Date(), updatedAt: Date()),
            contentKey: key
        )
        try WorryNarrativeRepository(controller: old).insert(WorryNarrative(text: "shipped worry"), contentKey: key)
        try Self.close(old)

        let migrated = PrivatePersistenceController(storeURL: storeURL)
        #expect(!migrated.didFailToLoad, "the production controller could not open a V1 store")
        #expect(try migrated.sealedRowCount() == 4, "rows were lost in the migration")
        let reopenedNarrative = try MenstrualNarrativeRepository(controller: migrated, defaults: latches)
            .narrative(forHKUUID: narrative.hkExternalUUID, contentKey: key)
        #expect(reopenedNarrative?.note == "shipped note")
        #expect(try IntimacyLogRepository(controller: migrated, defaults: latches).logs(contentKey: key).map(\.note) == ["shipped log"])
        #expect(try WorryNarrativeRepository(controller: migrated).worries(contentKey: key).map(\.text) == ["shipped worry"])
        let records = CycleRecordRepository(controller: migrated)
        let record = CycleRecord(event: UserLoggedCycleEvent(date: Date(), flowLevel: .light), now: Date())
        try records.insert(record, contentKey: key)
        #expect(try records.records(ids: [record.id], contentKey: key).records == [record])
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: storeURL)
        #expect(PrivatePersistenceController.makeManagedObjectModel().isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata),
                "the store on disk is not at V2 after the migration")
        try Self.close(migrated)

        let again = PrivatePersistenceController(storeURL: storeURL)
        #expect(!again.didFailToLoad)
        #expect(try again.sealedRowCount() == 5)
        try Self.close(again)
    }

    /// The DOWNGRADE, characterised (review L-U3-R2): an earlier build — V1 model, no version
    /// identifier, automatic inferred migration and no staged manager, exactly what every shipped build
    /// opens its store with — reading a store a V2 build wrote. Core Data finds V2 in the store's own
    /// model cache, infers "drop entity `CycleRecord`" and migrates the file DOWN: the earlier build
    /// loads (so its sealed journal, intimacy and worry reads keep working) with every V1 row intact,
    /// and every cycle record is gone — a later upgrade finds an empty table. Downgrading a phone below
    /// V2 is therefore unsupported once cycle records exist; this pins the behaviour the residual risk
    /// and `makeManagedObjectModel()`'s doc state, so a change in it is noticed.
    @Test func anEarlierBuildOpeningAVersionTwoStoreLoadsButDropsEveryCycleRecord() throws {
        let directory = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("FernletPrivate.sqlite")
        let key = SymmetricKey(size: .bits256)
        let latches = UserDefaults(suiteName: "fernlet.tests.modelMigration.\(UUID().uuidString)") ?? .standard
        let narrative = MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-09-01", note: "kept note")

        let current = PrivatePersistenceController(storeURL: storeURL)
        #expect(!current.didFailToLoad)
        try MenstrualNarrativeRepository(controller: current, defaults: latches).insert(narrative, contentKey: key)
        try CycleRecordRepository(controller: current).insert(
            CycleRecord(event: UserLoggedCycleEvent(date: Date(), flowLevel: .light), now: Date()), contentKey: key
        )
        #expect(try current.sealedRowCount() == 2)
        try Self.close(current)

        let shipped = PrivatePersistenceController.makeManagedObjectModelV1()
        shipped.versionIdentifiers = []
        let earlier = PrivatePersistenceController(storeURL: storeURL, model: shipped)
        #expect(!earlier.didFailToLoad, "an earlier build can no longer load a V2 store — the residual risk changed")
        #expect(try MenstrualNarrativeRepository(controller: earlier, defaults: latches)
            .narrative(forHKUUID: narrative.hkExternalUUID, contentKey: key)?.note == "kept note")
        let downgraded = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: storeURL)
        #expect(shipped.isConfiguration(withName: nil, compatibleWithStoreMetadata: downgraded),
                "the earlier build did not migrate the file down to V1")
        try Self.close(earlier)

        let upgradedAgain = PrivatePersistenceController(storeURL: storeURL)
        #expect(!upgradedAgain.didFailToLoad)
        #expect(try CycleRecordRepository(controller: upgradedAgain).recordCount() == 0,
                "the cycle records survived a downgrade — the residual risk changed")
        #expect(try upgradedAgain.sealedRowCount() == 1)
        try Self.close(upgradedAgain)
    }
}
