import CryptoKit
import Foundation

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
    enum SealedBackupWiringError: Error { case locked }

    private unowned let host: any SealedBackupContext

    init(host: any SealedBackupContext) {
        self.host = host
    }

    private func makeSealedBackupService() -> SealedBackupService? {
        let identity = IdentityService()
        do { try identity.ensureProvisioned() } catch { return nil }
        return SealedBackupService(cloudDataService: CloudKitDataService(), identityService: identity)
    }

    /// Serializes the plaintext for a sealed-backup payload. Period data requires an unlocked
    /// content key; sensitive notes are the Tier-2 behavioral memories.
    private func sealedBackupPlaintext(for payloadType: SealedBackupPayloadType) throws -> Data {
        switch payloadType {
        case .sensitiveNotes:
            return try JSONEncoder().encode(host.tierTwoMemories)
        case .periodData:
            guard let key = host.sealedBackupContentKey else { throw SealedBackupWiringError.locked }
            let repo = MenstrualNarrativeRepository()
            // Unbounded fetch — `narratives(in:)` would enumerate every calendar day in the range.
            let narratives = try repo.allNarratives(contentKey: key)
            return try JSONEncoder().encode(narratives)
        }
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
            let plaintext = enabled ? try sealedBackupPlaintext(for: payloadType) : Data()
            try await service.reconcile(plaintext, payloadType: payloadType, enabled: enabled)
            FernletAuditLog.log("sealedBackup.reconciled", context: [
                "payload": payloadType.rawValue, "enabled": enabled ? "true" : "false"
            ])
            return true
        } catch {
            FernletAuditLog.log("sealedBackup.reconcileFailed", context: ["payload": payloadType.rawValue])
            return false
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
            guard let plaintext = try await service.restore(payloadType: payloadType) else {
                return false
            }
            let restored = try applyRestoredPayload(plaintext, payloadType: payloadType)
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

    /// Decodes a decrypted sealed-backup payload and writes it into the local stores, returning the
    /// number of records written. Separated from the CloudKit fetch so it is unit-testable without
    /// iCloud. Period data re-seals each narrative with the current device's content key, so it
    /// requires an unlocked key and throws `SealedBackupWiringError.locked` otherwise (retried next
    /// launch after unlock).
    @discardableResult
    func applyRestoredPayload(
        _ plaintext: Data,
        payloadType: SealedBackupPayloadType,
        narrativeRepository: MenstrualNarrativeRepository? = nil
    ) throws -> Int {
        // Constructed here rather than as a default argument: `MenstrualNarrativeRepository` is
        // MainActor-isolated, and default-argument expressions evaluate in a nonisolated context.
        let narrativeRepository = narrativeRepository ?? MenstrualNarrativeRepository()
        switch payloadType {
        case .sensitiveNotes:
            let records = try JSONDecoder().decode([TierTwoMemoryRecord].self, from: plaintext)
            guard records.isEmpty == false else { return 0 }
            host.replaceTierTwoMemories(records)
            return records.count
        case .periodData:
            guard let key = host.sealedBackupContentKey else { throw SealedBackupWiringError.locked }
            let narratives = try JSONDecoder().decode([MenstrualNarrative].self, from: plaintext)
            var restored = 0
            for narrative in narratives {
                do {
                    try narrativeRepository.insert(narrative, contentKey: key)
                    restored += 1
                } catch {
                    FernletAuditLog.log("sealedBackup.restoreNarrativeFailed", context: ["dateKey": narrative.dateKey])
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
