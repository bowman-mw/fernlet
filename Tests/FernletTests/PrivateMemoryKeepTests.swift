//
//  PrivateMemoryKeepTests.swift
//  FernletTests
//
//  "Keep private" (G9-3, owner call M6 = A) through the real store: the sealed copy is written FIRST and
//  the Core copy goes only once it landed (its row then soft-deleted, so the tombstone syncs); a sealed
//  write that fails leaves the Core copy; private memories are counted while Private is closed, listed
//  only while it is open, hidden in a decoy, and reached by forget and Delete all only after unlock.
//

import CoreData
import CryptoKit
import Foundation
import Testing
@testable import CloudKitSync
import FernletDomainModel
import PrivateMemoryStore
import PrivateStoreCore
@testable import Fernlet

/// A private store whose sealed write always fails (and that otherwise holds nothing).
private final class FailingPrivateMemoryStore: PrivateMemoryStoring {
    struct WriteFailed: Error {}
    func rowCount() throws -> Int { 0 }
    func memories(key: SymmetricKey?) throws -> PrivateMemoryPage { PrivateMemoryPage() }
    func save(_ memory: MemoryNote, key: SymmetricKey?) throws { throw WriteFailed() }
    func mergeRestored(_ incoming: [MemoryNote], key: SymmetricKey?) throws -> Int { throw WriteFailed() }
    func delete(ids: [UUID]) throws -> Int { 0 }
    func deleteAll() throws -> Bool { false }
}

@MainActor
@Suite(.serialized)
struct PrivateMemoryKeepTests {
    private let key = SymmetricKey(size: .bits256)

    private func makeStore(open: Bool = true) -> (store: FernletStore, repository: CoreDataFernletRepository, controller: PrivatePersistenceController) {
        let (store, repository, _) = makeTestStoreWithRepositories()
        store.activateSealedJournals(contentKey: .journalTestKey)
        let controller = PrivatePersistenceController(inMemory: true)
        store.privateMemoryVault = PrivateMemoryVault(controller: controller)
        let key = self.key
        if open { store.hubContentKeyProvider = { key } }
        return (store, repository, controller)
    }

    private func memoryRowIDs(_ repository: CoreDataFernletRepository) throws -> [String] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "MemoryRecord")
        return try repository.persistenceController.container.viewContext.fetch(request).compactMap { $0.value(forKey: "idString") as? String }
    }

    @Test func keepPrivateSealsFirstThenSoftDeletesTheCoreRow() throws {
        let (store, repository, controller) = makeStore()
        let secret = MemoryNote(category: "family", text: "About my sister")
        let other = MemoryNote(category: "note", text: "Stays in Core")
        store.memories = [secret, other]
        store.flushPendingSnapshotSave()

        #expect(store.keepMemoryPrivate(secret))
        store.flushPendingSnapshotSave()

        #expect(store.memories.map(\.id) == [other.id], "gone from Core, so from Home, the photo wall and AI")
        #expect(store.privateMemories.map(\.text) == ["About my sister"])
        #expect(try PrivateMemoryRepository(controller: controller).rowCount() == 1)
        #expect(MemoryRecordRepository(controller: repository.persistenceController).load().map(\.id) == [other.id])
        #expect(try memoryRowIDs(repository).contains(RowTombstones.tombstoneIDString(for: secret.id)), "the tombstone syncs")
    }

    /// The sealed write failing is the whole point of the order: the Core copy stays exactly where it was.
    @Test func aFailedSealedWriteKeepsTheCoreCopy() {
        let (store, _, _) = makeStore()
        store.privateMemoryVault = PrivateMemoryVault(repository: FailingPrivateMemoryStore())
        let secret = MemoryNote(category: "family", text: "About my sister")
        store.memories = [secret]
        #expect(!store.keepMemoryPrivate(secret))
        #expect(store.memories == [secret])
    }

    /// Private closed (or never opened): nothing moves, and nothing is listed, only counted.
    @Test func withPrivateClosedNothingMovesAndTheyAreOnlyCounted() throws {
        let (store, _, controller) = makeStore(open: false)
        let secret = MemoryNote(category: "family", text: "About my sister")
        store.memories = [secret]
        #expect(!store.keepMemoryPrivate(secret))
        #expect(store.memories == [secret])
        try PrivateMemoryRepository(controller: controller).save(MemoryNote(category: "note", text: "Already private"), key: key)
        store.privateMemoryVault = PrivateMemoryVault(controller: controller)
        #expect(store.privateMemoryCount == 1, "the page can say one waits behind the lock")
        #expect(store.privateMemories.isEmpty, "but lists none")
        #expect(!store.isPrivateMemoryOpen)
    }

    /// An edit the editor saved is what goes into Private.
    @Test func theStoredEditIsWhatBecomesPrivate() {
        let (store, _, _) = makeStore()
        let memory = MemoryNote(category: "note", text: "Before")
        store.memories = [memory]
        store.updateMemory(memory, category: "note", text: "After")
        #expect(store.keepMemoryPrivate(memory))
        #expect(store.privateMemories.first?.text == "After")
        #expect(store.privateMemories.first?.userEdited == true)
    }

    /// Forget by filters and Delete all reach the private memories once Private is open — never while it
    /// is closed.
    @Test func forgetAndDeleteAllReachPrivateOnlyAfterUnlock() {
        let (store, _, _) = makeStore()
        let a = MemoryNote(category: "note", text: "Private A")
        let b = MemoryNote(category: "note", text: "Private B")
        let core = MemoryNote(category: "note", text: "Core")
        store.memories = [a, b, core]
        #expect(store.keepMemoryPrivate(a))
        #expect(store.keepMemoryPrivate(b))

        store.hubContentKeyProvider = { nil }
        #expect(store.forgetMemories(ids: [a.id]) == 0, "locked: the private one is out of reach")
        #expect(store.deleteAllMemories() == 1, "locked: only Core goes")
        #expect(store.privateMemoryCount == 2)

        let key = self.key
        store.hubContentKeyProvider = { key }
        #expect(store.forgetMemories(ids: [a.id]) == 1)
        #expect(store.privateMemories.map(\.id) == [b.id])
        #expect(store.deleteAllMemories() == 1)
        #expect(store.privateMemoryCount == 0)
    }

    /// The forget filter is pure: run over the decrypted private memories after unlock, it matches them
    /// like Core ones and deletes nothing on its own.
    @Test func theForgetFilterMatchesPrivateMemoriesAfterUnlock() {
        let (store, _, _) = makeStore()
        let secret = MemoryNote(category: "family", text: "About my sister")
        store.memories = [secret]
        #expect(store.keepMemoryPrivate(secret))
        let matches = MemoryForgetFilter(words: "sister").matches(in: store.memories + store.privateMemories)
        #expect(matches.map(\.id) == [secret.id])
        #expect(store.privateMemoryCount == 1, "matching deleted nothing")
    }

    /// A decoy (duress) session hides them the way the other sealed screens hide: no count, no list, no
    /// move, no forget — and they are all still there once it ends.
    @Test func aDecoyHidesThemAndTouchesNothing() {
        let (store, _, _) = makeStore()
        let secret = MemoryNote(category: "family", text: "About my sister")
        let core = MemoryNote(category: "note", text: "Core")
        store.memories = [secret, core]
        #expect(store.keepMemoryPrivate(secret))

        store.duressSessionActive = true
        #expect(store.privateMemoryCount == 0)
        #expect(store.privateMemories.isEmpty)
        #expect(!store.isPrivateMemoryOpen)
        #expect(!store.keepMemoryPrivate(core))
        #expect(store.forgetPrivateMemories(ids: [secret.id]) == 0)
        #expect(store.deleteAllPrivateMemories() == 0)

        store.duressSessionActive = false
        #expect(store.privateMemories.map(\.id) == [secret.id])
    }
}
