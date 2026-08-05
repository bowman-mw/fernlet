import CoreData
import Foundation

/// Shared keyless row-deletion plumbing for the sealed repositories — the one copy of the
/// fetch → guard → delete → save → prune sequence their `deleteAll()` methods previously
/// each repeated inline.
///
/// The sealed layer-3 repositories (`JournalNarrativeRepository`, `WorryNarrativeRepository`,
/// `IntimacyLogRepository`, `MenstrualNarrativeRepository`) all delete rows WITHOUT decrypting
/// them, so deletion stays available while the app is locked or the feature is hidden. Each
/// bulk delete must also clear the persistent-history transaction log (rethrowing, not
/// best-effort — a delete's promise includes removing the ciphertext from the log), which is
/// why the prune is part of this sequence rather than left to callers.
///
/// Deliberately NOT used by `PrivatePersistenceController.purgeEncryptedEntities()`: the
/// destructive lock-reset wipe batches all four entities under a SINGLE save so the wipe is
/// atomic across entities — per-entity adoption of this helper would permit a partial wipe.
///
/// A caseless enum used purely as a namespace.
public enum PrivateRowPlumbing {
    /// Fetches the matching rows, deletes them, saves, and prunes the persistent history —
    /// all inside the context's `performAndWait`.
    ///
    /// When nothing matches, this is a complete no-op: no save, no prune, and the return
    /// value is `false`. When rows were deleted, `true` is returned only after the save AND
    /// the (rethrowing) history prune both succeeded — callers that latch on "something was
    /// actually removed" (see `MenstrualNarrativeRepository.deleteAll()`) key off exactly
    /// that.
    ///
    /// - Parameters:
    ///   - entityName: The sealed Core Data entity to delete from.
    ///   - predicate: Optional row filter; `nil` (the default) matches every row.
    ///   - fetchLimit: Cap on how many rows are fetched/deleted; `0` (the default) means
    ///     unlimited.
    ///   - context: The sealed store's managed-object context.
    /// - Returns: `true` iff at least one row was deleted (and the save + prune succeeded).
    /// - Throws: Fetch, save, or history-prune errors, rethrown to the caller.
    @discardableResult
    public static func deleteRows(
        entityName: String,
        predicate: NSPredicate? = nil,
        fetchLimit: Int = 0,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            request.predicate = predicate
            if fetchLimit > 0 { request.fetchLimit = fetchLimit }
            let rows = try context.fetch(request)
            guard !rows.isEmpty else { return false }
            rows.forEach(context.delete)
            try context.save()
            try PrivatePersistentHistoryPruner.prune(context: context)
            return true
        }
    }
}
