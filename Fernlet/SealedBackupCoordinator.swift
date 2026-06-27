import ProximityKit
import CryptoKit
import CloudKitSync
import FernletFoundation
import Foundation
import FernletDomainModel
import PrivateHealthStore
import HealthKitGateway

/// The state the sealed-backup flow needs from the app store. Mirrors the
/// `WorkoutSyncContext` host-protocol pattern so `SealedBackupCoordinator` depends
/// on this seam rather than the concrete `FernletStore` (plan §5d). `sealedBackupContentKey`
/// is exposed as a narrow accessor so the store's `journalContentKey` stays private
/// (it migrates to JournalSealingCoordinator in a later phase).
@MainActor
protocol SealedBackupContext: AnyObject {
    var tierTwoMemories: [TierTwoMemoryRecord] { get }
    var sealedBackupContentKey: SymmetricKey? { get }
    var previousJournals: [JournalEntry] { get }
    var memories: [MemoryNote] { get }
    var recentMeals: [Meal] { get }
    func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord])
    func loadAllDaysFromRepository() -> [String: FernletDay]
}

/// Sealed CloudKit backup: reconcile (enable/disable upload) + restore (new-device /
/// fresh-install pull), extracted from `FernletStore` (plan §5d). Owns the
/// `SealedBackupService` / `CloudKitDataService` / `MenstrualNarrativeRepository`
/// dependencies, keeping the CloudKit egress + sealed-narrative store off the
/// store/core path.
@MainActor
final class SealedBackupCoordinator {
    enum SealedBackupWiringError: Error, Equatable {
        /// Period-data sealing/restore attempted while the content key is locked.
        case locked
        /// Restore attempted into a store that already holds user data — refused to avoid clobbering.
        case storeNotEmpty
    }

    /// Narratives per sealed chunk on the period export. Bounds the plaintext/ciphertext held in
    /// memory while sealing to ~this many records regardless of how long the cycle history is.
    static let periodBackupChunkSize = 250

    private unowned let host: any SealedBackupContext

    init(host: any SealedBackupContext) {
        self.host = host
    }

    private func makeSealedBackupService() -> SealedBackupService? {
        let identity = IdentityService()
        do { try identity.ensureProvisioned() } catch { return nil }
        return SealedBackupService(cloudDataService: CloudKitDataService(), identityService: identity)
    }

    /// Serializes the sensitive-notes payload (the Tier-2 behavioral memories). Period data is sealed
    /// separately and in chunks — see `reconcilePeriodBackup` — so it never builds one giant blob.
    private func sensitiveNotesPlaintext() throws -> Data {
        try JSONEncoder().encode(host.tierTwoMemories)
    }

    /// Seals + uploads (or deletes) the encrypted CloudKit backup for a payload. Returns whether it
    /// succeeded; callers should only persist the "on" preference when this returns `true`.
    @discardableResult
    func setSealedBackupEnabled(_ enabled: Bool, payloadType: SealedBackupPayloadType) async -> Bool {
        guard let service = makeSealedBackupService() else {
            FernletAuditLog.log("sealedBackup.notProvisioned", context: ["payload": payloadType.rawValue])
            return false
        }
        do {
            switch (payloadType, enabled) {
            case (.sensitiveNotes, _):
                try await service.reconcile(try sensitiveNotesPlaintext(), payloadType: payloadType, enabled: enabled)
            case (.periodData, true):
                try await reconcilePeriodBackup(using: service)
            case (.periodData, false):
                try await service.reconcile(Data(), payloadType: .periodData, enabled: false)
            }
            FernletAuditLog.log("sealedBackup.reconciled", context: [
                "payload": payloadType.rawValue, "enabled": enabled ? "true" : "false"
            ])
            return true
        } catch {
            FernletAuditLog.log("sealedBackup.reconcileFailed", context: ["payload": payloadType.rawValue])
            return false
        }
    }

    /// Seals + uploads the period backup one bounded chunk at a time. The narrative count is read up
    /// front to size the chunk set, then `reconcileChunked` pages the repository so only one chunk's
    /// worth of plaintext/ciphertext is ever resident — the rest of the (possibly very long) history
    /// stays on disk. Requires an unlocked content key, matching the locked-key guard on restore.
    private func reconcilePeriodBackup(using service: SealedBackupService) async throws {
        guard let key = host.sealedBackupContentKey else { throw SealedBackupWiringError.locked }
        let repository = MenstrualNarrativeRepository()
        let pageSize = Self.periodBackupChunkSize
        let total = try repository.narrativeCount()
        // Always at least one chunk so an empty (but enabled) backup still writes a head record.
        let chunkCount = max(1, (total + pageSize - 1) / pageSize)
        try await service.reconcileChunked(payloadType: .periodData, chunkCount: chunkCount) { index in
            let page = try repository.narratives(offset: index * pageSize, limit: pageSize, contentKey: key)
            return try JSONEncoder().encode(page)
        }
    }

    /// Called once at launch (after the store is ready) to pull any sealed iCloud backups into the
    /// local stores. No-ops unless iCloud sync is on, the payload's backup is enabled, and the local
    /// store is a fresh install. Best-effort and non-fatal: failures are logged and retried next
    /// launch. Gated by `FERNLET_SKIP_SEALED_RESTORE` so UI tests can opt out.
    func restoreSealedBackupsIfNeeded() async {
        guard ProcessInfo.processInfo.environment["FERNLET_SKIP_SEALED_RESTORE"] != "1" else { return }
        let prefs = StoragePreferencesStore.currentPreferences()
        guard prefs.iCloudSyncEnabled else { return }
        if prefs.sealedBackupSensitiveNotesEnabled {
            _ = await restoreSealedBackup(payloadType: .sensitiveNotes)
        }
        if prefs.sealedBackupPeriodEnabled {
            _ = await restoreSealedBackup(payloadType: .periodData)
        }
    }

    /// Fetches, decrypts, and writes a single sealed-backup payload into the local stores. Returns
    /// `true` only when records were actually restored. Returns `false` (without mutating anything)
    /// when the store already holds data (never clobbers), no backup exists, the device identity
    /// can't open the record, the content key is locked (period data), or any decode/transport error
    /// occurs — all of which are safe to retry on a later launch.
    @discardableResult
    func restoreSealedBackup(payloadType: SealedBackupPayloadType) async -> Bool {
        guard isEmptyStoreForRestore(payloadType: payloadType) else {
            FernletAuditLog.log("sealedBackup.restoreSkippedNonEmpty", context: ["payload": payloadType.rawValue])
            return false
        }
        guard let service = makeSealedBackupService() else {
            FernletAuditLog.log("sealedBackup.restoreNotProvisioned", context: ["payload": payloadType.rawValue])
            return false
        }
        do {
            guard let chunks = try await service.restoreChunks(payloadType: payloadType) else {
                return false
            }
            let restored = try applyRestoredChunks(chunks, payloadType: payloadType)
            guard restored > 0 else { return false }
            FernletAuditLog.log("sealedBackup.restored", context: [
                "payload": payloadType.rawValue, "count": String(restored)
            ])
            return true
        } catch {
            FernletAuditLog.log("sealedBackup.restoreFailed", context: ["payload": payloadType.rawValue])
            return false
        }
    }

    /// Decodes a single decrypted sealed-backup payload and writes it into the local stores. Thin
    /// wrapper over `applyRestoredChunks` (a single blob is just a one-element chunk set), kept for the
    /// restore tests and any single-record caller.
    @discardableResult
    func applyRestoredPayload(
        _ plaintext: Data,
        payloadType: SealedBackupPayloadType,
        narrativeRepository: MenstrualNarrativeRepository? = nil
    ) throws -> Int {
        try applyRestoredChunks([plaintext], payloadType: payloadType, narrativeRepository: narrativeRepository)
    }

    /// Decodes the decrypted chunks of a sealed-backup payload and writes them into the local stores,
    /// returning the number of records written. Separated from the CloudKit fetch so it is
    /// unit-testable without iCloud. Sensitive notes is an overwrite payload (chunks are concatenated
    /// then replace the Tier-2 store); period data inserts each narrative incrementally and re-seals it
    /// with the current device's content key, so it requires an unlocked key and throws
    /// `SealedBackupWiringError.locked` otherwise (retried next launch after unlock). Decoding one
    /// chunk at a time keeps the working set bounded even for a long restored history.
    ///
    /// Precondition: the store must be empty for `payloadType` (see `isEmptyStoreForRestore`). This
    /// is enforced here — the lowest write point every caller funnels through (the `applyRestoredPayload`
    /// wrapper and the production `restoreSealedBackup` path alike) — so the no-clobber invariant holds
    /// for every caller (defense in depth) and throws `SealedBackupWiringError.storeNotEmpty` otherwise.
    /// The production caller already gates on this before any network work, so the re-check is cheap
    /// insurance; it also closes the window where the store gains data during `restore`'s `await`.
    @discardableResult
    func applyRestoredChunks(
        _ chunks: [Data],
        payloadType: SealedBackupPayloadType,
        narrativeRepository: MenstrualNarrativeRepository? = nil
    ) throws -> Int {
        // No-clobber guard: refuse to overwrite/insert into a store that already holds user data,
        // regardless of how this method was reached.
        guard isEmptyStoreForRestore(payloadType: payloadType) else {
            FernletAuditLog.log("sealedBackup.applySkippedNonEmpty", context: ["payload": payloadType.rawValue])
            throw SealedBackupWiringError.storeNotEmpty
        }
        // Constructed here rather than as a default argument: `MenstrualNarrativeRepository` is
        // MainActor-isolated, and default-argument expressions evaluate in a nonisolated context.
        let narrativeRepository = narrativeRepository ?? MenstrualNarrativeRepository()
        switch payloadType {
        case .sensitiveNotes:
            var records: [TierTwoMemoryRecord] = []
            for chunk in chunks {
                records.append(contentsOf: try JSONDecoder().decode([TierTwoMemoryRecord].self, from: chunk))
            }
            guard records.isEmpty == false else { return 0 }
            host.replaceTierTwoMemories(records)
            return records.count
        case .periodData:
            guard let key = host.sealedBackupContentKey else { throw SealedBackupWiringError.locked }
            var restored = 0
            for chunk in chunks {
                let narratives = try JSONDecoder().decode([MenstrualNarrative].self, from: chunk)
                for narrative in narratives {
                    do {
                        try narrativeRepository.insert(narrative, contentKey: key)
                        restored += 1
                    } catch {
                        FernletAuditLog.log("sealedBackup.restoreNarrativeFailed", context: ["dateKey": narrative.dateKey])
                    }
                }
            }
            return restored
        }
    }

    /// Whether the local store is empty enough that restoring `payloadType` cannot clobber or
    /// duplicate existing user data. Requires a fresh install for all payloads; sensitive-notes
    /// additionally requires the (overwrite-style) Tier-2 store to be empty.
    private func isEmptyStoreForRestore(payloadType: SealedBackupPayloadType) -> Bool {
        guard isFreshInstallForRestore() else { return false }
        switch payloadType {
        case .sensitiveNotes: return host.tierTwoMemories.isEmpty
        case .periodData: return true
        }
    }

    /// True only when no day carries any logged content and the rolling in-memory caches are empty —
    /// i.e. the user has not yet recorded anything on this device.
    private func isFreshInstallForRestore() -> Bool {
        let anyLoggedDay = host.loadAllDaysFromRepository().values.contains { d in
            !(d.meals.isEmpty && d.workouts.isEmpty && d.plannedWorkouts.isEmpty && d.journals.isEmpty
              && d.sleep == nil && d.hygiene.isEmpty && d.completedPersonalCareTaskIDs.isEmpty
              && d.bottleCount == 0 && d.healthContext == nil)
        }
        return !anyLoggedDay && host.previousJournals.isEmpty && host.memories.isEmpty && host.recentMeals.isEmpty
    }
}
