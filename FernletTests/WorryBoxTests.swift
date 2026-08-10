//
//  WorryBoxTests.swift
//  FernletTests
//
//  Batch B Worry Box: sealed round-trip through WorryNarrativeRepository (ciphertext at
//  rest, key-gated reads), deletion, the device-key → user-key migration, inclusion in
//  purgeEncryptedEntities, and the WorryBoxService lock-lifecycle behavior.
//

import CoreData
import CryptoKit
import Foundation
import Testing
import FernletFoundation
import FernletLock
import PrivateStoreCore
import PrivateMemoryStore
@testable import Fernlet

struct WorryBoxRepositoryTests {

    private func makeRepository() -> (controller: PrivatePersistenceController, repository: WorryNarrativeRepository) {
        let controller = PrivatePersistenceController(inMemory: true)
        return (controller, WorryNarrativeRepository(controller: controller))
    }

    private func rawWorryObjects(in controller: PrivatePersistenceController) throws -> [NSManagedObject] {
        let context = controller.container.viewContext
        return try context.performAndWait {
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorryNarrative"))
        }
    }

    // MARK: - Seal / round-trip

    @Test func sealRoundTripReturnsPlaintext() throws {
        let (_, repository) = makeRepository()
        let key = SymmetricKey(size: .bits256)
        let worry = WorryNarrative(text: "What if the presentation goes badly tomorrow")

        try repository.insert(worry, contentKey: key)
        let loaded = try repository.worries(contentKey: key)

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == worry.id)
        #expect(loaded.first?.text == worry.text)
    }

    @Test func storedCiphertextDoesNotContainPlaintext() throws {
        let (controller, repository) = makeRepository()
        let key = SymmetricKey(size: .bits256)
        let secret = "very-identifiable-worry-text-9241"
        try repository.insert(WorryNarrative(text: secret), contentKey: key)

        let objects = try rawWorryObjects(in: controller)
        #expect(objects.count == 1)
        let ciphertext = objects.first?.value(forKey: "textCiphertext") as? Data
        #expect(ciphertext != nil)
        if let ciphertext {
            #expect(!ciphertext.isEmpty)
            #expect(ciphertext.range(of: Data(secret.utf8)) == nil, "worry text must be sealed, never plaintext at rest")
        }
    }

    @Test func insertWithoutKeyThrowsLocked() {
        let (_, repository) = makeRepository()
        #expect(throws: FernletLockError.self) {
            try repository.insert(WorryNarrative(text: "held"), contentKey: nil)
        }
    }

    @Test func readWithoutKeyReturnsEmpty() throws {
        let (_, repository) = makeRepository()
        let key = SymmetricKey(size: .bits256)
        try repository.insert(WorryNarrative(text: "held"), contentKey: key)

        #expect(try repository.worries(contentKey: nil).isEmpty)
    }

    @Test func readWithWrongKeySkipsUndecryptableRows() throws {
        let (_, repository) = makeRepository()
        try repository.insert(WorryNarrative(text: "held"), contentKey: SymmetricKey(size: .bits256))

        let loaded = try repository.worries(contentKey: SymmetricKey(size: .bits256))
        #expect(loaded.isEmpty)
    }

    @Test func worriesListNewestFirst() throws {
        let (_, repository) = makeRepository()
        let key = SymmetricKey(size: .bits256)
        let older = WorryNarrative(createdAt: Date(timeIntervalSinceNow: -3600), text: "older")
        let newer = WorryNarrative(createdAt: Date(), text: "newer")
        try repository.insert(older, contentKey: key)
        try repository.insert(newer, contentKey: key)

        let loaded = try repository.worries(contentKey: key)
        #expect(loaded.map(\.text) == ["newer", "older"])
    }

    // MARK: - Release (delete)

    @Test func deleteRemovesRow() throws {
        let (controller, repository) = makeRepository()
        let key = SymmetricKey(size: .bits256)
        let worry = WorryNarrative(text: "released")
        try repository.insert(worry, contentKey: key)

        try repository.delete(id: worry.id)

        #expect(try repository.worries(contentKey: key).isEmpty)
        #expect(try rawWorryObjects(in: controller).isEmpty)
    }

    // MARK: - Device-key → user-key migration

    @Test func reencryptAllMigratesOldKeyRows() throws {
        let (_, repository) = makeRepository()
        let deviceKey = SymmetricKey(size: .bits256)
        let userKey = SymmetricKey(size: .bits256)
        try repository.insert(WorryNarrative(text: "written while locked"), contentKey: deviceKey)
        // A row already under the user key must survive the migration untouched.
        try repository.insert(WorryNarrative(text: "already migrated"), contentKey: userKey)

        try repository.reencryptAll(from: deviceKey, to: userKey)

        let underUserKey = try repository.worries(contentKey: userKey)
        #expect(Set(underUserKey.map(\.text)) == ["written while locked", "already migrated"])
        #expect(try repository.worries(contentKey: deviceKey).isEmpty)
    }

    // MARK: - Purge ("delete all private data" must include worries)

    @Test func purgeEncryptedEntitiesIncludesWorryNarrative() throws {
        let (controller, repository) = makeRepository()
        let key = SymmetricKey(size: .bits256)
        try repository.insert(WorryNarrative(text: "to be purged"), contentKey: key)
        #expect(try rawWorryObjects(in: controller).count == 1)

        try controller.purgeEncryptedEntities()

        #expect(try rawWorryObjects(in: controller).isEmpty, "purgeEncryptedEntities must cover the WorryNarrative entity")
    }

    @Test func privateModelContainsWorryEntityWithSealedColumnOnly() {
        let model = PrivatePersistenceController(inMemory: true).container.managedObjectModel
        let entity = model.entitiesByName["WorryNarrative"]
        #expect(entity != nil)
        // Plaintext columns stay minimal by design: id + createdAt; text only as ciphertext.
        let propertyNames = Set(entity?.propertiesByName.keys.map { $0 } ?? [])
        #expect(propertyNames == ["id", "createdAt", "textCiphertext"])
    }
}

@MainActor
struct WorryBoxServiceTests {

    private func makeService() -> (service: WorryBoxService, repository: WorryNarrativeRepository) {
        let repository = WorryNarrativeRepository(controller: PrivatePersistenceController(inMemory: true))
        // Ephemeral, per-test UserDefaults so the device-local lifetime count never leaks across tests
        // (or the shared `.standard` domain).
        let defaults = UserDefaults(suiteName: "worry-tests-\(UUID().uuidString)")!
        return (WorryBoxService(repository: repository, defaults: defaults), repository)
    }

    @Test func noLockModeWritesAndReadsWithDeviceKey() throws {
        let (service, _) = makeService()
        service.updateActivation(lockState: .notConfigured, contentKey: nil)

        try service.addWorry("  a small worry  ")

        #expect(service.worries.map(\.text) == ["a small worry"])
        service.reload()
        #expect(service.worries.map(\.text) == ["a small worry"])
    }

    @Test func lockedModeHidesWorriesButStillAcceptsWrites() throws {
        let (service, _) = makeService()
        service.updateActivation(lockState: .notConfigured, contentKey: nil)
        try service.addWorry("kept before locking")

        service.updateActivation(lockState: .locked(cooldownDeadline: nil), contentKey: nil)
        #expect(service.worries.isEmpty, "locked mode must not hold plaintext worries in memory")

        // Writing from First Aid while locked still lands sealed (device-key fallback)...
        try service.addWorry("written while locked")
        #expect(service.worries.isEmpty)

        // ...and both become readable again in no-lock mode (same device key).
        service.updateActivation(lockState: .notConfigured, contentKey: nil)
        #expect(Set(service.worries.map(\.text)) == ["kept before locking", "written while locked"])
    }

    @Test func unlockMigratesDeviceKeyWorriesToUserKey() throws {
        let (service, repository) = makeService()
        service.updateActivation(lockState: .notConfigured, contentKey: nil)
        try service.addWorry("from before the lock existed")

        let userKey = SymmetricKey(size: .bits256)
        service.updateActivation(lockState: .unlocked(scope: .privateHub), contentKey: userKey)

        #expect(service.worries.map(\.text) == ["from before the lock existed"])
        // The row is genuinely under the user key now (direct repository read).
        #expect(try repository.worries(contentKey: userKey).map(\.text) == ["from before the lock existed"])
    }

    @Test func releaseDeletesAndUpdatesList() throws {
        let (service, _) = makeService()
        service.updateActivation(lockState: .notConfigured, contentKey: nil)
        try service.addWorry("let this one go")
        let id = try #require(service.worries.first?.id)

        service.release(id)

        #expect(service.worries.isEmpty)
        service.reload()
        #expect(service.worries.isEmpty)
    }

    @Test func emptyWorryIsIgnored() throws {
        let (service, _) = makeService()
        service.updateActivation(lockState: .notConfigured, contentKey: nil)

        try service.addWorry("   \n ")

        #expect(service.worries.isEmpty)
        #expect(service.lifetimeLetGoCount == 0, "an ignored empty worry doesn't count as a letting-go")
    }

    @Test func letGoCountGrowsAtWriteNotAtRelease() throws {
        // Finding #23: the "let it go" gesture (addWorry, First Aid's primary flow) is what counts —
        // once per worry, keyed to the write — so a later hub "Release" of the same worry doesn't
        // double-count it. And the count is DEVICE-LOCAL (never the synced milestone ledger, #6).
        let (service, _) = makeService()
        service.updateActivation(lockState: .notConfigured, contentKey: nil)

        try service.addWorry("one")
        try service.addWorry("two")
        #expect(service.lifetimeLetGoCount == 2)

        let id = try #require(service.worries.first?.id)
        service.release(id)
        #expect(service.lifetimeLetGoCount == 2, "releasing a kept worry is not a new letting-go")
    }

    @Test func releaseAllPurgesWorriesAndZeroesCount() throws {
        // Finding #4: "Reset everything" must purge the sealed worry rows AND the device-local count —
        // even while locked (rows are dropped by id, not decrypted).
        let (service, _) = makeService()
        service.updateActivation(lockState: .notConfigured, contentKey: nil)
        try service.addWorry("kept a")
        try service.addWorry("kept b")
        #expect(service.lifetimeLetGoCount == 2)

        service.releaseAll()

        #expect(service.worries.isEmpty)
        #expect(service.lifetimeLetGoCount == 0)
        // The sealed rows are physically gone: a fresh read under the still-active device key (no-lock
        // mode) finds nothing.
        service.reload()
        #expect(service.worries.isEmpty)
    }
}
