import CoreData
import Foundation
import FernletDomainModel
import FernletFoundation

/// A dedicated non-CloudKit persistent store for sealed (ChaChaPoly-encrypted) entities.
/// Sensitive narrative records live here and are never mirrored to iCloud.
///
/// This is the shared Core Data substrate on the protected side of the S3 privacy wall: the
/// sealed repositories in `PrivateHealthStore` (`MenstrualNarrativeRepository`,
/// `IntimacyLogRepository`) and `PrivateMemoryStore` (`JournalNarrativeRepository`,
/// `WorryNarrativeRepository`) all read and write through its ``container``, and
/// `FernletLockService` calls ``purgeEncryptedEntities()`` during its destructive reset. The
/// walled `AIProviders` and `CloudKitSync` modules have no dependency edge to this module, so no
/// sealed entity is even nameable there.
///
/// Store posture:
/// - Never synced: `cloudKitContainerOptions` is intentionally never set, so the `FernletPrivate`
///   store cannot be mirrored to iCloud.
/// - `FileProtection.complete` on the store file; iOS-backup exclusion follows the user's
///   `localBackupExcludedFromiOSBackup` preference (via the shared `BackupExclusion` helper) so
///   one toggle consistently covers both the synced and sealed stores.
/// - Persistent-history tracking is on; sealed writers pair their saves with
///   ``PrivatePersistentHistoryPruner`` so edited rows do not leave prior ciphertext recoverable
///   from the history tables.
/// - Deletion is a TWO-step contract: ``purgeEncryptedEntities()`` (or the repositories' keyless
///   `deleteAll()`) drops the rows, then ``rebuildStore()`` destroys and re-creates the store file
///   so the `-wal`/freelist residue those rows leave behind goes with it. Both halves are keyless,
///   so a wipe works while the app is locked.
/// - The model is built programmatically (`makeManagedObjectModel()`): plain `NSManagedObject`
///   entities whose text content lives only in `*Ciphertext` binary columns; ids, day keys, and
///   timestamps are plaintext by accepted risk (NEW-4). The column sealing itself happens in the
///   layer-3 repositories under the lock's content key — this module never touches that key.
///
/// Concurrency: this module is nonisolated; ``shared`` is `nonisolated(unsafe)` because
/// `NSPersistentContainer` is not `Sendable` (matching its prior app-target behavior). Failure
/// mode: a store that fails to load logs the error and sets ``didFailToLoad`` instead of
/// crashing.
public final class PrivatePersistenceController {
    /// The process-wide controller for the on-disk sealed store; `nonisolated(unsafe)` because
    /// the container is not `Sendable`.
    nonisolated(unsafe) public static let shared = PrivatePersistenceController()

    /// An in-memory (`/dev/null`-backed) controller for SwiftUI previews and tests.
    @MainActor
    public static let preview = PrivatePersistenceController(inMemory: true)

    /// The local-only container hosting the four sealed entities (`MenstrualNarrative`,
    /// `JournalNarrative`, `IntimacyLog`, `WorryNarrative`).
    public let container: NSPersistentContainer
    /// `true` when the persistent store failed to load; the error is logged and the controller
    /// left running (against an empty container) rather than crashing.
    ///
    /// Lock-guarded, not a plain stored `var`: this is the one piece of mutable state on a
    /// process-wide `nonisolated(unsafe)` object that is written OUTSIDE the
    /// `viewContext.performAndWait` discipline the rest of the type relies on (the
    /// `loadPersistentStores` completion runs on Core Data's own queue, while the app reads this
    /// from the main actor). ``stateLock`` is what makes the R9 allowlist invariant true.
    public var didFailToLoad: Bool {
        stateLock.withLock { storedDidFailToLoad }
    }

    /// Serializes every read and write of ``storedDidFailToLoad``.
    private let stateLock = NSLock()
    /// Backing storage for ``didFailToLoad``; touched only under ``stateLock``.
    private var storedDidFailToLoad = false
    private let inMemory: Bool

    /// The one writer of ``didFailToLoad``, so every mutation goes through ``stateLock``.
    private func setDidFailToLoad(_ value: Bool) {
        stateLock.withLock { storedDidFailToLoad = value }
    }

    /// Creates the stack and loads the `FernletPrivate` store with complete file protection,
    /// history tracking, lightweight migration, and — for on-disk stores — the user's
    /// backup-exclusion preference applied.
    ///
    /// - Parameters:
    ///   - inMemory: When `true`, backs the store with `/dev/null` for previews and tests. Wins
    ///     over `storeURL` when both are supplied.
    ///   - storeURL: An explicit on-disk location for the `.sqlite` file, overriding the default
    ///     Application Support path. The test seam for the ON-DISK behaviours an in-memory store
    ///     cannot express — chiefly ``rebuildStore()``, whose whole contract is about the sqlite
    ///     file, its `-wal`/`-shm` sidecars, and the `_SUPPORT` blob directory really being
    ///     destroyed and re-created. Production always passes `nil`.
    public init(inMemory: Bool = false, storeURL: URL? = nil) {
        self.inMemory = inMemory
        container = NSPersistentContainer(
            name: "FernletPrivate",
            managedObjectModel: Self.makeManagedObjectModel()
        )
        let storeDesc = container.persistentStoreDescriptions.first ?? NSPersistentStoreDescription()
        storeDesc.setOption(FileProtectionType.complete as NSString, forKey: NSPersistentStoreFileProtectionKey)
        storeDesc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        storeDesc.shouldMigrateStoreAutomatically = true
        storeDesc.shouldInferMappingModelAutomatically = true
        // cloudKitContainerOptions is intentionally never set — this store is always local-only.
        storeDesc.cloudKitContainerOptions = nil
        if inMemory {
            storeDesc.url = URL(fileURLWithPath: "/dev/null")
        } else if let storeURL {
            storeDesc.url = storeURL
        }
        container.persistentStoreDescriptions = [storeDesc]

        container.loadPersistentStores { [self] storeDescription, error in
            if let error {
                print("[Fernlet] PrivatePersistenceController store failed to load: \(error)")
                self.setDidFailToLoad(true)
                return
            }
            // Honor the localBackupExcludedFromiOSBackup preference (default: NOT excluded) for the
            // sealed store too, so one toggle consistently covers BOTH stores. The sealed columns use
            // allowsExternalBinaryDataStorage, so the `_SUPPORT` external-blob dir is included. Reuses
            // the shared BackupExclusion helper so the sealed/synced exclusion paths cannot drift.
            Self.applyBackupExclusion(
                storeURL: storeDescription.url,
                inMemory: inMemory,
                excluded: StoragePreferencesStore.currentPreferences().localBackupExcludedFromiOSBackup
            )
        }
        // Behaviour-identical to `NSMergeByPropertyObjectTrumpMergePolicy`; the typed
        // initializer avoids referencing the non-concurrency-safe CoreData global in this
        // nonisolated module.
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    /// Re-applies the sealed store's iOS-backup exclusion to the live store at runtime — e.g. when the
    /// user toggles `localBackupExcludedFromiOSBackup`. Without this the sealed store's exclusion would
    /// lag the synced store's until the next launch (the synced store reloads on the toggle; this store
    /// is local-only and never reloads). First-session `-wal`/`-shm`/`_SUPPORT` sidecars that do not yet
    /// exist self-heal on the next launch's idempotent re-apply.
    public func applyBackupExclusion(excluded: Bool) {
        Self.applyBackupExclusion(
            storeURL: container.persistentStoreDescriptions.first?.url,
            inMemory: inMemory,
            excluded: excluded
        )
    }

    /// Excludes (or re-includes) the sealed store file, its `-wal`/`-shm` sidecars, and the
    /// `_SUPPORT` external-binary directory from the iOS backup via the shared `BackupExclusion`
    /// helper. No-op for in-memory stores.
    private static func applyBackupExclusion(storeURL: URL?, inMemory: Bool, excluded: Bool) {
        guard !inMemory, let storeURL else { return }
        BackupExclusion.apply(storeURL: storeURL, excluded: excluded, includeSupportDir: true)
    }

    /// Deletes every row of all four sealed entities, saves, and prunes the persistent history.
    ///
    /// The first destructive step of the lock reset and delete-all-data flows, and deliberately
    /// **keyless** — no `contentKey`, no decrypt — so it works while the app is locked or a
    /// sensitive surface is hidden (deleting data must never require the ability to read it).
    ///
    /// - Important: Row-delete alone is **not** an erasure. SQLite marks the pages free and the
    ///   prune clears the history shadow tables, but neither checkpoints the WAL nor vacuums the
    ///   freelist, so the prior ciphertext can linger in `-wal` frames and freed pages until those
    ///   pages are reused. That residue is class-key-protected (`FileProtection.complete`) and
    ///   key-bound (ChaChaPoly under the lock's content key, on a store that never leaves the
    ///   device) — but it is residue. Callers must follow this with ``rebuildStore()``, which
    ///   physically removes the file the residue lives in; only destroying the content key
    ///   (`FernletLockService.reset()`, and the duress WIPE built on it) is an *instant* honest
    ///   erase of the logical content. The old doc here claimed the rows were "unrecoverable
    ///   afterward — content key owned (and scrubbed) by `FernletLockService`", which conflated
    ///   the reset path (key destroyed) with the delete-everything path, where the lock keychain
    ///   is a documented survivor and the key is only scrubbed from memory.
    public func purgeEncryptedEntities() throws {
        let context = container.viewContext
        try context.performAndWait {
            for entityName in ["MenstrualNarrative", "JournalNarrative", "IntimacyLog", "WorryNarrative"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                try context.fetch(request).forEach(context.delete)
            }
            if context.hasChanges {
                try context.saveSealed()
            }
            try PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

    // MARK: - Crypto-erasure baseline

    /// Errors thrown by ``rebuildStore()``, ``reloadStoreIfNeeded()``, and the sealed save guard.
    public enum RebuildError: Error, CustomStringConvertible {
        /// The store description carries no URL, so there is no file to destroy or re-add. Only
        /// reachable if the container was mutated after `init`.
        case noStoreURL
        /// The store could not be detached from the coordinator, so the destroy/re-add was skipped.
        /// The app still HAS a usable sealed store — the residue pass is what did not happen.
        case storeStillAttached
        /// A save was attempted against a coordinator with no persistent stores (a rebuild whose
        /// re-add failed and has not healed yet). Thrown INSTEAD of letting Core Data raise its
        /// uncatchable `NSInternalInconsistencyException`, so the sealed repositories' existing
        /// `do`/`catch` can roll back and report rather than the app aborting.
        case storeUnavailable

        public var description: String {
            switch self {
            case .noStoreURL:
                return "The sealed store has no file URL — nothing to destroy or re-create."
            case .storeStillAttached:
                return "The sealed store could not be detached from the coordinator; its file was left intact."
            case .storeUnavailable:
                return "The sealed store is not loaded — a previous rebuild could not re-create it."
            }
        }
    }

    /// Whether the coordinator currently has the sealed store attached.
    ///
    /// `false` only in the narrow window between a ``rebuildStore()`` whose re-add failed (device
    /// auto-locked mid-wipe under `FileProtection.complete`, disk full) and the
    /// ``reloadStoreIfNeeded()`` that heals it. Every sealed write throws while it is `false`.
    public var isStoreLoaded: Bool {
        !container.persistentStoreCoordinator.persistentStores.isEmpty
    }

    /// Destroys the sealed store file and re-creates it empty — the physical half of Fernlet's
    /// crypto-erasure baseline ("Option B", Docs/Plan-Security-Hardening-OpusTrack-2026-08-10.md §6).
    ///
    /// ``purgeEncryptedEntities()`` (and the repositories' keyless `deleteAll()`) remove the ROWS,
    /// but leave the pages they lived on in the `-wal` frames and the freelist until SQLite reuses
    /// them. This removes the file those pages are in: the store is torn off the coordinator,
    /// `destroyPersistentStore(at:ofType:options:)` takes the sqlite plus its `-wal`/`-shm`
    /// sidecars, the `.FernletPrivate_SUPPORT` external-binary directory (where the sealed
    /// `allowsExternalBinaryDataStorage` columns spill blobs over ~100 KB) is deleted outright, and
    /// then an empty store is re-added under the same description — same `FileProtection.complete`,
    /// same history tracking, with the user's backup-exclusion preference re-applied to the new
    /// files.
    ///
    /// - Important: This is **keyless by absolute invariant**. It never calls `contentKey()`,
    ///   never decrypts a column and never re-wraps a key, because every deletion path in Fernlet
    ///   must run while the app is locked and a sensitive surface is hidden. (That is also why the
    ///   rejected alternative — re-minting the content key after the purge — is not the baseline:
    ///   re-wrapping needs the passcode-derived key, which a locked wipe does not have.) Do not
    ///   introduce a decrypt here.
    ///
    /// - Important: Honest limits. This removes the *logical* residue. It cannot promise the
    ///   underlying flash blocks are gone — APFS copy-on-write and wear-levelling may keep them
    ///   until they are overwritten — though those blocks stay under the
    ///   `FileProtection.complete` class key, which is evicted while the device is locked. Only
    ///   destroying the content key is an *instant* honest erase of the logical content: the
    ///   `FernletLockService.reset()` path (and the duress WIPE that reuses this seam) destroys the
    ///   keychain rows AND rebuilds, so it is fully honest; the "delete everything" funnel keeps
    ///   the app-lock key by design, so its honest claim is "no live ciphertext, and the residue is
    ///   class-key-protected and key-bound" — never "crypto-erased".
    ///
    /// Live contexts survive the swap: `container.viewContext` is reset (dropping registered
    /// objects and any unsaved changes) before the store is removed, and the context object itself
    /// is unchanged — so the long-lived repositories that captured it keep working against the
    /// fresh, empty store. In-memory (`/dev/null`) controllers skip the file work and simply
    /// re-add, which is already an empty store.
    ///
    /// No-storeless-app invariant. The three steps fail independently and none of them may leave
    /// the process holding a coordinator with zero stores: a failed detach skips the destroy and
    /// re-add entirely (the old store is still usable), a failed destroy still re-adds, and a
    /// failed re-add retries once, sets ``didFailToLoad``, logs, and is healed by
    /// ``reloadStoreIfNeeded()`` on the next foreground. Sealed saves attempted inside that window
    /// throw ``RebuildError/storeUnavailable`` via `saveSealed()` rather than tripping Core Data's
    /// uncatchable "no persistent stores" exception.
    ///
    /// - Throws: ``RebuildError/noStoreURL``, ``RebuildError/storeStillAttached`` (or the
    ///   underlying `remove` error), the `destroyPersistentStore` error, or the re-add error. A
    ///   throw is the caller's nothing-silent signal that the sealed store could not be rebuilt;
    ///   the rows deleted before it are still gone either way, which is why row-delete runs first.
    ///   A throw does **not** mean the app is now storeless: the detach failure path leaves the old
    ///   store attached, and the re-add failure path retries once, sets ``didFailToLoad``, and is
    ///   healed by the next ``reloadStoreIfNeeded()`` (the app calls it on every foreground).
    public func rebuildStore() throws {
        let coordinator = container.persistentStoreCoordinator
        guard let description = container.persistentStoreDescriptions.first,
              let storeURL = description.url else {
            throw RebuildError.noStoreURL
        }

        // Drop every live managed object first: after the store is removed they would be faults
        // pointing at a store that no longer exists.
        let context = container.viewContext
        context.performAndWait { context.reset() }

        // Capture-continue-report applies to the WHOLE detach → destroy → re-add sequence, not just
        // the destroy: `remove` is the step that can actually leave the app storeless, so it may not
        // bail out mid-way either.
        var removeFailure: (any Error)?
        for store in coordinator.persistentStores {
            do {
                try coordinator.remove(store)
            } catch {
                removeFailure = error
            }
        }
        // If the store did NOT come off, the app still has a working sealed store. Destroying the
        // file out from under a live store is strictly worse than skipping the residue pass, so
        // skip it and report — the rows the caller deleted first are still gone.
        guard coordinator.persistentStores.isEmpty else {
            setDidFailToLoad(false)
            print("[Fernlet] PrivatePersistenceController could not detach the sealed store; rebuild skipped: \(String(describing: removeFailure))")
            throw removeFailure ?? RebuildError.storeStillAttached
        }

        // The destroy failure is CAPTURED, not thrown from here: the store is already off the
        // coordinator, so bailing now would leave the app with no sealed store at all until the
        // next launch. Re-add first, report second.
        var destroyFailure: (any Error)?
        if !inMemory {
            do {
                try coordinator.destroyPersistentStore(at: storeURL, ofType: description.type, options: description.options)
                // Belt and braces, on the success path only: `destroyPersistentStore` is documented
                // to remove the store, but has been seen to leave a zero-byte sqlite (or a sidecar)
                // behind. Best-effort and audit-logged — see ``removeSidecars(of:)``. (Skipped when
                // the destroy FAILED: hand-deleting the file there would quietly succeed at the
                // rebuild while still reporting failure.)
                removeSidecars(of: storeURL)
                // The external-blob directory is NOT covered by `destroyPersistentStore` — sealed
                // columns over ~100 KB (a long journal entry, a big symptom payload) live in there
                // as standalone ciphertext files that would otherwise outlive the store that named
                // them. NOT best-effort, unlike the sidecars above: nothing else removes this
                // directory and nothing overwrites it, so a silent failure here means live sealed
                // blobs survived the wipe that claimed to take them.
                let supportDirectory = BackupExclusion.supportDirectory(for: storeURL)
                if FileManager.default.fileExists(atPath: supportDirectory.path) {
                    try FileManager.default.removeItem(at: supportDirectory)
                }
            } catch {
                destroyFailure = error
            }
        }

        do {
            try addStore(at: storeURL, description: description)
        } catch {
            // One retry: the dominant failure is a transient `FileProtection.complete` class-key
            // eviction (the device auto-locked mid-wipe) or a momentarily busy sqlite, and a
            // storeless coordinator is a whole-session outage — every sealed write throws and the
            // journal plaintext that could not be sealed stays in the synced days blob.
            do {
                try addStore(at: storeURL, description: description)
            } catch let retryError {
                print("[Fernlet] PrivatePersistenceController failed to re-add the sealed store after rebuild: \(retryError)")
                setDidFailToLoad(true)
                // The destroy failure, if there was one, is the root cause worth surfacing.
                throw destroyFailure ?? retryError
            }
        }
        setDidFailToLoad(false)
        Self.applyBackupExclusion(
            storeURL: storeURL,
            inMemory: inMemory,
            excluded: StoragePreferencesStore.currentPreferences().localBackupExcludedFromiOSBackup
        )
        // Nothing-silent: the store is usable again, but the old file — and the residue in it —
        // could not be destroyed, and the caller promised the user otherwise.
        if let destroyFailure { throw destroyFailure }
    }

    /// Best-effort removal of the sqlite file and its `-wal`/`-shm` sidecars after a successful
    /// `destroyPersistentStore` (which has been seen to leave a zero-byte file behind).
    private func removeSidecars(of storeURL: URL) {
        let fileManager = FileManager.default
        for path in [storeURL.path, storeURL.path + "-wal", storeURL.path + "-shm"] {
            guard fileManager.fileExists(atPath: path) else { continue }
            do {
                try fileManager.removeItem(atPath: path)
            } catch {
                // Recovery: continue with the rebuild. A sidecar the fresh store overwrites must not
                // fail an otherwise-complete wipe — but the failure is now named, not discarded.
                FernletAuditLog.log(
                    "sealedStore.sidecarRemoveFailed",
                    context: ["path": (path as NSString).lastPathComponent, "error": "\(error)"]
                )
            }
        }
    }

    /// Adds the sealed store at `storeURL` under `description`'s type/configuration/options, with
    /// lightweight migration enabled. The one add path shared by ``rebuildStore()`` (and its retry)
    /// and ``reloadStoreIfNeeded()``, so the file protection and migration options cannot drift
    /// between them. Keyless, like everything else on the rebuild path.
    private func addStore(at storeURL: URL, description: NSPersistentStoreDescription) throws {
        var options: [String: Any] = description.options
        options[NSMigratePersistentStoresAutomaticallyOption] = true
        options[NSInferMappingModelAutomaticallyOption] = true
        _ = try container.persistentStoreCoordinator.addPersistentStore(
            ofType: description.type,
            configurationName: description.configuration,
            at: storeURL,
            options: options
        )
    }

    /// Re-attaches the sealed store when a previous ``rebuildStore()`` left the coordinator empty —
    /// the self-heal for the one state in which every sealed write fails.
    ///
    /// A no-op (returning immediately) when a store is already attached, so it is safe to call on
    /// every foreground, which is exactly where the app calls it: the dominant way to lose the store
    /// is the device auto-locking mid-wipe, and writing anything again requires unlocking the
    /// device, which foregrounds the app. Without it, a failed re-add persists for the whole process
    /// — and a sealed journal write that throws deliberately leaves its PLAINTEXT in the days blob
    /// (`JournalSealingCoordinator`), which mirrors to iCloud when sync is on.
    ///
    /// Keyless by the same absolute invariant as ``rebuildStore()``: no `contentKey()`, no decrypt.
    ///
    /// - Throws: ``RebuildError/noStoreURL`` or the `addPersistentStore` error, so a caller that
    ///   wants to report the failure can. ``didFailToLoad`` is left `true` on failure.
    public func reloadStoreIfNeeded() throws {
        guard !isStoreLoaded else { return }
        guard let description = container.persistentStoreDescriptions.first,
              let storeURL = description.url else {
            throw RebuildError.noStoreURL
        }
        do {
            try addStore(at: storeURL, description: description)
        } catch {
            print("[Fernlet] PrivatePersistenceController could not reload the sealed store: \(error)")
            setDidFailToLoad(true)
            throw error
        }
        setDidFailToLoad(false)
        Self.applyBackupExclusion(
            storeURL: storeURL,
            inMemory: inMemory,
            excluded: StoragePreferencesStore.currentPreferences().localBackupExcludedFromiOSBackup
        )
    }

    // MARK: - Model

    /// Builds the programmatic managed-object model containing the four sealed entities.
    static func makeManagedObjectModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.entities = [makeMenstrualNarrativeEntity(), makeJournalNarrativeEntity(), makeIntimacyLogEntity(), makeWorryNarrativeEntity()]
        return model
    }

    /// The sealed period-narrative entity: plaintext id / HealthKit UUID / day key plus
    /// ciphertext note, symptom-flag, and symptom-scale columns, indexed by `dateKey`.
    static func makeMenstrualNarrativeEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "MenstrualNarrative"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            CoreDataModelBuilding.makeAttribute("id", type: .UUIDAttributeType),
            CoreDataModelBuilding.makeAttribute("hkExternalUUID", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("dateKey", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("noteCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            CoreDataModelBuilding.makeAttribute("symptomFlagsCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            CoreDataModelBuilding.makeAttribute("customSymptomScalesCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            CoreDataModelBuilding.makeAttribute("createdAt", type: .dateAttributeType),
            CoreDataModelBuilding.makeAttribute("updatedAt", type: .dateAttributeType)
        ]
        if let dateKeyProp = entity.propertiesByName["dateKey"] {
            entity.indexes = [NSFetchIndexDescription(name: "byDateKey", elements: [
                NSFetchIndexElementDescription(property: dateKeyProp, collationType: .binary)
            ])]
        }
        return entity
    }

    /// The sealed journal entity: plaintext id / day key / tag / dates plus ciphertext text and
    /// emotions columns, indexed by `dayKey`.
    static func makeJournalNarrativeEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "JournalNarrative"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        // id, dayKey, tag, entryDate, createdAt, updatedAt are stored plaintext (accepted risk, NEW-4).
        // This store is local-only (never iCloud-synced), so exposure is limited to local forensic
        // analysis ("which days have entries"). All text content lives in sealed ciphertext columns.
        entity.properties = [
            CoreDataModelBuilding.makeAttribute("id", type: .UUIDAttributeType),
            CoreDataModelBuilding.makeAttribute("dayKey", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("tag", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("entryDate", type: .dateAttributeType),
            CoreDataModelBuilding.makeAttribute("textCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            CoreDataModelBuilding.makeAttribute("emotionsCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            CoreDataModelBuilding.makeAttribute("createdAt", type: .dateAttributeType),
            CoreDataModelBuilding.makeAttribute("updatedAt", type: .dateAttributeType)
        ]
        if let dayKeyProp = entity.propertiesByName["dayKey"] {
            entity.indexes = [NSFetchIndexDescription(name: "byDayKey", elements: [
                NSFetchIndexElementDescription(property: dayKeyProp, collationType: .binary)
            ])]
        }
        return entity
    }

    /// The sealed intimacy-log entity: plaintext id / day key / event date / HealthKit UUID plus
    /// a ciphertext note column, indexed by `dayKey`.
    static func makeIntimacyLogEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "IntimacyLog"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        // Dates are plaintext so the calendar can be indexed. Free-form details are always sealed.
        entity.properties = [
            CoreDataModelBuilding.makeAttribute("id", type: .UUIDAttributeType),
            CoreDataModelBuilding.makeAttribute("dayKey", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("eventDate", type: .dateAttributeType),
            CoreDataModelBuilding.makeAttribute("noteCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            CoreDataModelBuilding.makeAttribute("healthKitExternalUUID", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("createdAt", type: .dateAttributeType),
            CoreDataModelBuilding.makeAttribute("updatedAt", type: .dateAttributeType)
        ]
        if let dayKeyProp = entity.propertiesByName["dayKey"] {
            entity.indexes = [NSFetchIndexDescription(name: "intimacyByDayKey", elements: [
                NSFetchIndexElementDescription(property: dayKeyProp, collationType: .binary)
            ])]
        }
        return entity
    }

    /// The sealed, device-only Worry Box entity: plaintext id / createdAt plus a single
    /// ciphertext text column.
    static func makeWorryNarrativeEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "WorryNarrative"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        // Worry Box notes are deliberately DEVICE-ONLY: sealed in this local store, never mirrored into
        // FernletDay/the synced blob, and deliberately NOT part of any SealedBackup payload — "let it go"
        // data shouldn't follow you across devices. Model kept minimal: plaintext id/createdAt for
        // ordering + deletion, all text in the sealed ciphertext column (same NEW-4 posture as journals).
        entity.properties = [
            CoreDataModelBuilding.makeAttribute("id", type: .UUIDAttributeType),
            CoreDataModelBuilding.makeAttribute("createdAt", type: .dateAttributeType),
            CoreDataModelBuilding.makeAttribute("textCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true)
        ]
        return entity
    }
}

/// Helpers that clear the sealed store's persistent-history transactions after sealed writes.
///
/// History tracking is enabled on the `FernletPrivate` store, so every save leaves a copy of the
/// changed rows — including prior ciphertext — in the history shadow tables. The sealed
/// repositories in `PrivateHealthStore` and `PrivateMemoryStore` call ``saveAndPrune(_:)`` (or
/// ``prune(context:before:)`` after their own do/catch saves) so edits and deletes do not linger
/// as recoverable transactions, and ``PrivatePersistenceController/purgeEncryptedEntities()``
/// prunes after a full wipe. A caseless enum used purely as a namespace.
public enum PrivatePersistentHistoryPruner {
    /// Deletes ALL persistent-history transactions store-wide (across the journal/menstrual/intimacy
    /// entities), not just the caller's. It only clears the history shadow tables — it does NOT
    /// checkpoint the WAL or vacuum freed pages, so prior ciphertext can linger in `-wal` frames or
    /// the freelist until those pages are reused. That residue is ChaChaPoly ciphertext under a
    /// ThisDeviceOnly key on a local-only `FileProtection.complete` store — never plaintext, never
    /// cloud-synced — so it is class-key-protected and key-bound, but it is still residue: pruning
    /// is write-hygiene, not erasure. The only thing that removes it is
    /// ``PrivatePersistenceController/rebuildStore()``, which destroys the file it lives in (and,
    /// on the paths that also destroy the content key, `FernletLockService.reset()`, which makes
    /// the residue instantly meaningless as well).
    public static func prune(context: NSManagedObjectContext, before date: Date = Date()) throws {
        let request = NSPersistentHistoryChangeRequest.deleteHistory(before: date)
        try context.execute(request)
    }

    /// Best-effort prune: a failure must not undo the write that just succeeded, so it is caught and
    /// audit-logged rather than thrown. The superseded ciphertext then stays in the history shadow
    /// tables until the next successful prune or a
    /// ``PrivatePersistenceController/rebuildStore()``.
    ///
    /// The ONE spelling of "best-effort prune" — every sealed repository routes its post-write prune
    /// through here so a prune failure can never again be invisible.
    ///
    /// - Parameters:
    ///   - context: The sealed store's managed-object context.
    ///   - site: Call-site label recorded in the audit line; defaults to the calling function.
    public static func pruneBestEffort(context: NSManagedObjectContext, site: StaticString = #function) {
        do {
            try prune(context: context)
        } catch {
            FernletAuditLog.log(
                "sealedStore.historyPruneFailed",
                context: ["site": "\(site)", "error": "\(error)"]
            )
        }
    }

    /// Saves the context, then best-effort prunes the persistent history so a re-sealed (edited) row
    /// leaves no prior ciphertext in the transaction log. A prune failure must not undo the write that
    /// succeeded, so it goes through ``pruneBestEffort(context:site:)``. Use this at the simple
    /// sealed-write sites where the save is unconditional; sites that need rollback-on-failure must
    /// keep `save()` inside their own do/catch.
    public static func saveAndPrune(_ context: NSManagedObjectContext) throws {
        try context.saveSealed()
        pruneBestEffort(context: context, site: "saveAndPrune")
    }
}

// MARK: - Fail-soft sealed save

extension NSManagedObjectContext {
    /// `save()` with a fail-soft guard for the one state Core Data punishes with an uncatchable
    /// crash: a coordinator holding zero persistent stores.
    ///
    /// `NSManagedObjectContext.save()` against a storeless coordinator raises the Objective-C
    /// `NSInternalInconsistencyException` ("This NSPersistentStoreCoordinator has no persistent
    /// stores… It cannot perform a save operation"), which is not a Swift error — no `do`/`catch`
    /// in the sealed repositories can catch it, so it is a SIGABRT. That state is reachable, if
    /// narrowly: a `PrivatePersistenceController.rebuildStore()` whose re-add failed (the device
    /// auto-locked mid-wipe and `FileProtection.complete` blocked the re-create) leaves it until
    /// `reloadStoreIfNeeded()` heals on the next foreground. This turns it into
    /// ``PrivatePersistenceController/RebuildError/storeUnavailable``, which the repositories'
    /// existing `catch` already rolls back and rethrows.
    ///
    /// Every sealed write goes through here. Keyless, like the rest of the sealed plumbing.
    ///
    /// - Throws: ``PrivatePersistenceController/RebuildError/storeUnavailable`` when no store is
    ///   attached, otherwise whatever `save()` throws.
    public func saveSealed() throws {
        guard persistentStoreCoordinator?.persistentStores.isEmpty == false else {
            throw PrivatePersistenceController.RebuildError.storeUnavailable
        }
        try save()
    }
}
