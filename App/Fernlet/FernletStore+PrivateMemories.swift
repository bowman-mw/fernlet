import CloudKitSync
import CryptoKit
import FernletDomainModel
import FernletFoundation
import Foundation

/// Private memories (G9-3, owner call M6 = A): "Keep private" moves a Core memory out of the synced
/// memory rows into the Private tab's sealed store, where it never syncs, never shows on Home or the
/// photo wall and never reaches an AI prompt (every one of those reads `memories`, which no longer holds
/// it). The Core memory page counts them while Private is closed ("N private memories — unlock to see")
/// and lists them only while it is open. Forget by filters and Delete all memories reach them then too,
/// "Delete everything" always does, and a decoy (duress) session sees none of them, the same way the
/// other sealed screens hide.
///
/// They ride the head of the journal's Sealed backup set (`SealedBackupPrivateMemories`), under the
/// journal's switch, so every change here marks the journal's upload owed.
///
/// Every call goes to the one sealed funnel, ``privateMemoryVault``.
extension FernletStore {
    /// The key private memories open under: the Private tab's content key, or nil while Private is
    /// closed and in a decoy. Reads ``lockState`` so a view redraws when the lock opens or closes.
    var privateMemoryKey: SymmetricKey? {
        _ = lockState
        guard !duressSessionActive else { return nil }
        return hubContentKeyProvider?()
    }

    /// Whether Private is open here, so private memories can be listed, kept, forgotten and deleted.
    var isPrivateMemoryOpen: Bool { privateMemoryKey != nil }

    /// How many private memories this iPhone holds — keyless, so the page can say how many wait behind
    /// the lock. 0 in a decoy.
    var privateMemoryCount: Int {
        privateMemoryVault.count(isDecoy: duressSessionActive)
    }

    /// The private memories, oldest first — only while Private is open; empty otherwise and in a decoy.
    var privateMemories: [MemoryNote] {
        privateMemoryVault.memories(key: privateMemoryKey, isDecoy: duressSessionActive)
    }

    /// "Keep private": seals the memory (as it is stored now, with any edit already saved) into the
    /// private store FIRST, and only once that write has landed removes it from Core — whose next save
    /// soft-deletes its row, so the tombstone syncs and no other device brings it back. A sealed write
    /// that did not land leaves the Core copy exactly where it was. Audit-logged without content.
    ///
    /// - Returns: Whether the memory is now private (false: Private closed, a decoy, an unknown id, or
    ///   the sealed write failed).
    @discardableResult
    func keepMemoryPrivate(_ memory: MemoryNote) -> Bool {
        guard let current = memories.first(where: { $0.id == memory.id }) else { return false }
        do {
            try privateMemoryVault.keep(current, key: privateMemoryKey, isDecoy: duressSessionActive)
        } catch {
            FernletAuditLog.log("memory.keepPrivate.refused", context: ["reason": "\(error)"])
            return false
        }
        deleteMemory(current)
        markSealedBackupDirty(.journalNarratives)
        FernletAuditLog.log("memory.keptPrivate")
        return true
    }

    /// Forgets the private memories among `ids` — only while Private is open (0 otherwise).
    ///
    /// - Returns: How many private memories were forgotten.
    @discardableResult
    func forgetPrivateMemories(ids: Set<UUID>) -> Int {
        guard isPrivateMemoryOpen, !ids.isEmpty else { return 0 }
        let forgotten = privateMemoryVault.forget(ids: ids, isDecoy: duressSessionActive)
        if forgotten > 0 {
            markSealedBackupDirty(.journalNarratives)
            FernletAuditLog.log("memory.forgetPrivate", context: ["count": "\(forgotten)"])
        }
        return forgotten
    }

    /// Deletes every private memory — only while Private is open (0 otherwise), as part of "Delete all
    /// memories".
    ///
    /// - Returns: How many private memories were deleted.
    @discardableResult
    func deleteAllPrivateMemories() -> Int {
        guard isPrivateMemoryOpen else { return 0 }
        let count = privateMemoryCount
        guard count > 0 else { return 0 }
        guard privateMemoryVault.deleteAll() else { return 0 }
        markSealedBackupDirty(.journalNarratives)
        FernletAuditLog.log("memory.deleteAllPrivate", context: ["count": "\(count)"])
        return count
    }

    /// Drops every private memory without a key — ungated, for "Delete everything" (``resetAll()``).
    ///
    /// - Returns: Whether the delete succeeded.
    func deleteAllPrivateMemoriesForWipe() -> Bool {
        privateMemoryVault.deleteAll()
    }

    /// Every private memory the journal's Sealed backup carries on its head, oldest first; throws in a
    /// decoy and while they can't be read right now (never an empty list in their place).
    func sealedBackupPrivateMemories(hubKey: SymmetricKey) throws -> [MemoryNote] {
        try privateMemoryVault.backupExport(key: hubKey, isDecoy: duressSessionActive)
    }

    /// Merges the private memories a journal restore carried (absent ones added, this iPhone's kept,
    /// never a delete); throws in a decoy and when they were not saved.
    func restoreSealedBackupPrivateMemories(_ memories: [MemoryNote], hubKey: SymmetricKey) throws {
        try privateMemoryVault.mergeRestored(memories, key: hubKey, isDecoy: duressSessionActive)
    }
}
