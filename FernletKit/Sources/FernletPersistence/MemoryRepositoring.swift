// MemoryRepositoring.swift
// FernletPersistence
//
// G9-3 (owner call M1 = A): Core memories leave the aggregate blob for their own per-row synced store,
// with the same soft delete as custom items, so a forget on one phone cannot be undone by another
// phone writing the whole blob back. The Core Data + iCloud conformer is `MemoryRecordRepository`
// (in `CloudKitSync`); `CoreDataFernletRepository` is its only caller.

import Foundation
import FernletDomainModel

/// The persistence contract for Core memories' per-row synced store (G9-3).
///
/// Upsert-only like ``CustomItemRepositoring``: ``upsert(_:)`` touches only the rows it is handed and
/// ``delete(ids:)`` soft-deletes only the listed ids, writing a tombstone that keeps the delete for
/// good (another phone's stale write of the same id is hidden and healed on read, and skipped on
/// upsert). ``adoptMissing(_:)`` is the blob-to-row copy: it writes only memories that have neither a
/// row nor a tombstone, so it never overwrites a memory another phone edited, nor revives a forgotten
/// one. ``deleteAll()`` is the "delete everything" wipe and takes the tombstones too. `@MainActor`,
/// like its sibling per-row contracts.
@MainActor
public protocol MemoryRepositoring {
    /// Every live memory, ordered by `sourceDate` (oldest first).
    func load() -> [MemoryNote]
    /// Inserts or replaces each memory by id; tombstoned ids are skipped. Other rows are untouched.
    func upsert(_ memories: [MemoryNote]) -> Bool
    /// Writes the memories that have no row and no tombstone yet; every other one is left as it is.
    func adoptMissing(_ memories: [MemoryNote]) -> Bool
    /// Soft-deletes the listed ids (a tombstone each); other rows are untouched.
    func delete(ids: [UUID]) -> Bool
    /// Removes every row, tombstones included (only for a full reset).
    func deleteAll() -> Bool
}
