//
//  PrivateMemoryRepositoryTests.swift
//  FernletTests
//
//  The sealed private-memory repository (G9-3, owner call M6 = A): one `ColumnCrypto` blob per memory
//  under `fernlet.private-memory.v1`, keyed by the memory's own id; keyless count, forget and wipe;
//  reads that skip what does not open; the restore's merge that never deletes.
//

import CoreData
import CryptoKit
import FernletCrypto
import FernletDomainModel
import FernletFoundation
import Foundation
import PrivateMemoryStore
import PrivateStoreCore
import Testing

@Suite(.serialized)
struct PrivateMemoryRepositoryTests {
    static let early = Date(timeIntervalSince1970: 1_800_000_000)
    static let late = Date(timeIntervalSince1970: 1_800_086_400)

    private func makeRepository() -> (PrivateMemoryRepository, PrivatePersistenceController) {
        let controller = PrivatePersistenceController(inMemory: true)
        return (PrivateMemoryRepository(controller: controller), controller)
    }

    private func rawRows(_ controller: PrivatePersistenceController) throws -> [NSManagedObject] {
        let context = controller.container.viewContext
        return try context.performAndWait {
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "PrivateMemory"))
        }
    }

    @Test func aSavedMemoryRoundTripsUnderTheKeyOldestFirst() throws {
        let (repository, _) = makeRepository()
        let key = SymmetricKey(size: .bits256)
        let later = MemoryNote(category: "calm", text: "Later", sourceDate: Self.late, userEdited: true)
        let earlier = MemoryNote(category: "family", text: "Earlier", sourceDate: Self.early)
        try repository.save(later, key: key)
        try repository.save(earlier, key: key)
        let page = try repository.memories(key: key)
        #expect(page.memories == [earlier, later])
        #expect(page.deadCount == 0 && page.transientCount == 0)
        #expect(try repository.rowCount() == 2)
    }

    /// The only plaintext beside the blob is the memory's own id: no word, category or date column.
    @Test func nothingButTheIDIsPlaintext() throws {
        let (repository, controller) = makeRepository()
        let memory = MemoryNote(category: "family", text: "Talked with my sister", sourceDate: Self.early)
        try repository.save(memory, key: SymmetricKey(size: .bits256))
        let row = try #require(try rawRows(controller).first)
        #expect(Set(row.entity.attributesByName.keys) == ["id", "schemaVersion", "payloadCiphertext"])
        #expect(row.value(forKey: "id") as? UUID == memory.id)
        let blob = try #require(row.value(forKey: "payloadCiphertext") as? Data)
        for plain in ["sister", "family"] {
            #expect(blob.range(of: Data(plain.utf8)) == nil, "\(plain) is in the clear")
        }
    }

    /// Saving the same id again re-seals its one row in place.
    @Test func savingAnIDAgainReplacesItsRow() throws {
        let (repository, _) = makeRepository()
        let key = SymmetricKey(size: .bits256)
        var memory = MemoryNote(category: "note", text: "First", sourceDate: Self.early)
        try repository.save(memory, key: key)
        memory.text = "Second"
        try repository.save(memory, key: key)
        #expect(try repository.rowCount() == 1)
        #expect(try repository.memories(key: key).memories.map(\.text) == ["Second"])
    }

    /// Fail closed: no key, no write and an empty read; the wrong key opens nothing (counted dead).
    @Test func withoutTheRightKeyNothingIsWrittenOrRead() throws {
        let (repository, _) = makeRepository()
        let memory = MemoryNote(category: "note", text: "Sealed", sourceDate: Self.early)
        #expect(throws: FernletLockError.locked) { try repository.save(memory, key: nil) }
        #expect(try repository.rowCount() == 0)
        try repository.save(memory, key: SymmetricKey(size: .bits256))
        #expect(try repository.memories(key: nil) == PrivateMemoryPage())
        let wrong = try repository.memories(key: SymmetricKey(size: .bits256))
        #expect(wrong.memories.isEmpty)
        #expect(wrong.deadCount == 1)
    }

    /// Another sealed purpose's key derivation never opens a private memory: the blob is bound to
    /// `fernlet.private-memory.v1`.
    @Test func theBlobOpensOnlyUnderItsOwnPurpose() throws {
        let (repository, controller) = makeRepository()
        let key = SymmetricKey(size: .bits256)
        try repository.save(MemoryNote(category: "note", text: "Mine", sourceDate: Self.early), key: key)
        let blob = try #require(try rawRows(controller).first?.value(forKey: "payloadCiphertext") as? Data)
        let journal = ColumnCrypto(purpose: FernletCryptoPurpose.KeyDerivation.journalNarrativeLegacyV1)
        #expect(throws: (any Error).self) { let _: MemoryNote? = try journal.open(blob, contentKey: key) }
        let own = ColumnCrypto(purpose: FernletCryptoPurpose.KeyDerivation.privateMemoryV1)
        let opened: MemoryNote? = try own.open(blob, contentKey: key)
        #expect(opened?.text == "Mine")
        #expect(FernletCryptoPurpose.KeyDerivation.privateMemoryV1.rawValue == "fernlet.private-memory.v1")
    }

    /// A row a newer build wrote is undecided, never dead — and a merge over it writes nothing.
    @Test func aNewerBuildsRowIsUndecidedAndBlocksAMerge() throws {
        let (repository, controller) = makeRepository()
        let key = SymmetricKey(size: .bits256)
        let memory = MemoryNote(category: "note", text: "Newer", sourceDate: Self.early)
        try repository.save(memory, key: key)
        let context = controller.container.viewContext
        try context.performAndWait {
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "PrivateMemory")).first?.setValue(Int16(9), forKey: "schemaVersion")
            try context.save()
        }
        #expect(try repository.memories(key: key).transientCount == 1)
        #expect(throws: PrivateMemoryRepositoryError.undecidedRows(count: 1)) {
            try repository.mergeRestored([memory], key: key)
        }
    }

    /// Forget and wipe are KEYLESS: ids go without the key, and everything goes without it.
    @Test func forgetAndWipeNeedNoKey() throws {
        let (repository, _) = makeRepository()
        let key = SymmetricKey(size: .bits256)
        let one = MemoryNote(category: "note", text: "One", sourceDate: Self.early)
        let two = MemoryNote(category: "note", text: "Two", sourceDate: Self.late)
        try repository.save(one, key: key)
        try repository.save(two, key: key)
        #expect(try repository.delete(ids: [one.id, UUID()]) == 1)
        #expect(try repository.memories(key: key).memories == [two])
        #expect(try repository.delete(ids: []) == 0)
        #expect(try repository.deleteAll())
        #expect(try repository.rowCount() == 0)
        #expect(try repository.deleteAll() == false, "an empty store: nothing removed")
    }

    /// The restore merge: absent ids inserted, a row that opens kept as it is, a dead row replaced,
    /// nothing deleted, and the same merge again changes nothing.
    @Test func theMergeAddsAbsentKeepsLocalReplacesDeadAndIsIdempotent() throws {
        let (repository, controller) = makeRepository()
        let key = SymmetricKey(size: .bits256)
        let local = MemoryNote(category: "note", text: "Local words", sourceDate: Self.early)
        let dead = MemoryNote(category: "note", text: "Dead here", sourceDate: Self.early.addingTimeInterval(10))
        let localOnly = MemoryNote(category: "note", text: "Only local", sourceDate: Self.late)
        try repository.save(local, key: key)
        try repository.save(localOnly, key: key)
        // A row of `dead`'s id sealed under a key this iPhone no longer holds.
        try PrivateMemoryRepository(context: controller.container.viewContext).save(dead, key: SymmetricKey(size: .bits256))
        var incomingLocal = local
        incomingLocal.text = "Backup words"
        let absent = MemoryNote(category: "calm", text: "From the backup", sourceDate: Self.late.addingTimeInterval(5))

        #expect(try repository.mergeRestored([incomingLocal, dead, absent], key: key) == 2)
        let texts = try repository.memories(key: key).memories.map(\.text)
        #expect(texts == ["Local words", "Dead here", "Only local", "From the backup"])
        #expect(try repository.rowCount() == 4)
        #expect(try repository.mergeRestored([incomingLocal, dead, absent], key: key) == 0, "idempotent")
        #expect(throws: FernletLockError.locked) { try repository.mergeRestored([absent], key: nil) }
    }

    /// The private store is a sealed entity: counted by the keyless prior-data check, purged by the
    /// app-lock reset, and censused.
    @Test func theEntityIsSealedPurgedAndCensused() throws {
        let (repository, controller) = makeRepository()
        try repository.save(MemoryNote(category: "note", text: "Sealed", sourceDate: Self.early), key: SymmetricKey(size: .bits256))
        #expect(PrivatePersistenceController.sealedEntityNames.contains("PrivateMemory"))
        #expect(try controller.sealedRowCount() == 1)
        try controller.purgeEncryptedEntities()
        #expect(try repository.rowCount() == 0)
        #expect(SealedColumnFormatCensus.censusedColumns.contains(SealedColumnIdentifier(entityName: "PrivateMemory", attributeName: "payloadCiphertext")))
    }
}
