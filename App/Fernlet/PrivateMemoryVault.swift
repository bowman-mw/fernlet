import CryptoKit
import FernletDomainModel
import FernletFoundation
import Foundation
import Observation
import PrivateMemoryStore
import PrivateStoreCore

/// Why a private-memory call did not do what was asked. Never shown as text: the UI picks its own copy.
enum PrivateMemoryVaultError: Error, Equatable {
    /// A decoy (duress) session: nothing was read or written.
    case decoy
    /// Private is closed: there is no content key to seal or open with.
    case locked
    /// A stored row could not be decided this attempt; nothing was written, and a retry may succeed.
    case undecidedRows
    /// The store already holds the most private memories it keeps.
    case storeFull
    /// The sealed store refused the read or the write (not loaded, mid-rebuild, a failed save).
    case storeError
}

/// The app's `@MainActor` funnel for private memories — the Core memories a person chose to "Keep
/// private" (G9-3, owner call M6 = A). Every read and write of a `PrivateMemory` row goes through here;
/// views reach it through the `FernletStore` extension in `FernletStore+PrivateMemories.swift`.
///
/// **Key.** The Private tab's content key (the journal's), passed per call. Without it the keyed reads
/// answer empty and the keyed writes throw ``PrivateMemoryVaultError/locked``; the count and the deletes
/// are keyless.
///
/// **Decoy.** Every gated call takes `isDecoy` (the store passes `duressSessionActive`): in a decoy the
/// count is 0, reads answer empty and writes and deletes are refused before any row is touched, the
/// same way the other sealed screens hide. ``deleteAll()`` is UNGATED and keyless — a wipe must work in
/// every state.
///
/// **Observation.** ``changeToken`` moves after every change this funnel makes, and every read
/// registers a dependency on it, so the Core memory page redraws when a memory is kept private or
/// forgotten. The decrypted list is cached in memory only, tagged with the token and the keyless row
/// count, so a wipe underneath it is never shown from the cache.
@MainActor
@Observable
final class PrivateMemoryVault {
    /// Moves by one after every change this funnel makes. Reads register on it.
    private(set) var changeToken = 0

    /// The decrypted memories of the last read, tagged with what they were read at. Not tagged with the
    /// key: the only thing that changes the key under stored rows is "Reset app lock", which purges them
    /// (the row count moves), and without a key nothing is read at all.
    private struct Cache {
        let token: Int
        let rowCount: Int
        let memories: [MemoryNote]
    }

    @ObservationIgnored private let repository: any PrivateMemoryStoring
    @ObservationIgnored private var cache: Cache?

    /// Creates the funnel over `repository` (defaults to one on the shared sealed store).
    init(repository: any PrivateMemoryStoring = PrivateMemoryRepository()) {
        self.repository = repository
    }

    /// Creates the funnel over a repository on `controller`'s store (`nil`: the shared one).
    convenience init(controller: PrivatePersistenceController?) {
        self.init(repository: PrivateMemoryRepository(controller: controller))
    }

    // MARK: - Reads (gated)

    /// How many private memories this iPhone holds — keyless; 0 in a decoy or when the store could not
    /// be counted (named in the audit log).
    func count(isDecoy: Bool) -> Int {
        access(keyPath: \.changeToken)
        guard !isDecoy else { return 0 }
        do {
            return try repository.rowCount()
        } catch {
            FernletAuditLog.log("privateMemory.countFailed")
            return 0
        }
    }

    /// Every private memory that opens under `key`, oldest first — empty in a decoy, without a key, or
    /// when the store could not be read.
    func memories(key: SymmetricKey?, isDecoy: Bool) -> [MemoryNote] {
        access(keyPath: \.changeToken)
        guard !isDecoy, let key else { return [] }
        let rowCount = (try? repository.rowCount()) ?? -1
        if let cache, cache.token == changeToken, cache.rowCount == rowCount {
            return cache.memories
        }
        do {
            let memories = try repository.memories(key: key).memories
            cache = Cache(token: changeToken, rowCount: rowCount, memories: memories)
            return memories
        } catch {
            FernletAuditLog.log("privateMemory.readFailed")
            return []
        }
    }

    // MARK: - Writes (gated)

    /// Seals `memory` into the private store. Throws (nothing written) in a decoy, without a key, or
    /// when the sealed write did not land — the caller then keeps the Core copy.
    func keep(_ memory: MemoryNote, key: SymmetricKey?, isDecoy: Bool) throws {
        guard !isDecoy else { throw PrivateMemoryVaultError.decoy }
        guard let key else { throw PrivateMemoryVaultError.locked }
        do {
            try repository.save(memory, key: key)
        } catch let error as PrivateMemoryRepositoryError {
            throw Self.vaultError(for: error)
        } catch {
            throw PrivateMemoryVaultError.storeError
        }
        noteChange()
    }

    /// Forgets the private memories with these ids (keyless). Refused in a decoy.
    ///
    /// - Returns: How many were forgotten (0 in a decoy or when the delete failed, which is logged).
    func forget(ids: Set<UUID>, isDecoy: Bool) -> Int {
        guard !isDecoy, !ids.isEmpty else { return 0 }
        do {
            let removed = try repository.delete(ids: Array(ids))
            if removed > 0 { noteChange() }
            return removed
        } catch {
            FernletAuditLog.log("privateMemory.forgetFailed")
            return 0
        }
    }

    /// Drops every private memory without decrypting — UNGATED, for "Delete all memories" after unlock
    /// and for the wipes.
    ///
    /// - Returns: Whether the delete succeeded (an empty store counts as success).
    func deleteAll() -> Bool {
        do {
            if try repository.deleteAll() { noteChange() }
            return true
        } catch {
            FernletAuditLog.log("privateMemory.deleteAllFailed")
            return false
        }
    }

    // MARK: - Sealed backup (gated)

    /// Every private memory for the journal's Sealed backup head, oldest first. Throws — never an empty
    /// list in its place — in a decoy, and when a row could not be decided or the store could not be
    /// read, so the export fails rather than write a head without them. Rows that can never open again
    /// are left out (they can't be backed up by anyone).
    func backupExport(key: SymmetricKey, isDecoy: Bool) throws -> [MemoryNote] {
        guard !isDecoy else { throw PrivateMemoryVaultError.decoy }
        let page: PrivateMemoryPage
        do {
            page = try repository.memories(key: key)
        } catch {
            throw PrivateMemoryVaultError.storeError
        }
        guard page.transientCount == 0 else { throw PrivateMemoryVaultError.undecidedRows }
        return page.memories
    }

    /// Merges memories a journal restore carried (absent ones added, this iPhone's kept, never a
    /// delete). Throws in a decoy and when they were not saved, so the restore stays unresolved.
    ///
    /// - Returns: How many rows changed.
    @discardableResult
    func mergeRestored(_ memories: [MemoryNote], key: SymmetricKey, isDecoy: Bool) throws -> Int {
        guard !isDecoy else { throw PrivateMemoryVaultError.decoy }
        let changed: Int
        do {
            changed = try repository.mergeRestored(memories, key: key)
        } catch let error as PrivateMemoryRepositoryError {
            throw Self.vaultError(for: error)
        } catch {
            throw PrivateMemoryVaultError.storeError
        }
        if changed > 0 { noteChange() }
        return changed
    }

    // MARK: - Private

    /// Moves the token and drops the cache.
    private func noteChange() {
        cache = nil
        changeToken &+= 1
    }

    /// The funnel's error for a repository refusal.
    private static func vaultError(for error: PrivateMemoryRepositoryError) -> PrivateMemoryVaultError {
        switch error {
        case .storeFull: return .storeFull
        case .undecidedRows: return .undecidedRows
        }
    }
}
