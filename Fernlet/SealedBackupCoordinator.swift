import ProximityKit
import CryptoKit
import CloudKitSync
import FernletFoundation
import Foundation
import FernletDomainModel
import PrivateHealthStore
import PrivateMemoryStore
import HealthKitGateway

/// Per-payload wording for the Privacy & Data surfaces (toggle confirmations, the restore-status
/// banner, the audit log). One definition so the settings screen and the coordinator never drift into
/// calling the same payload two different things.
extension SealedBackupPayloadType {
    /// The noun the user-facing copy uses for this payload ("your **period** backup").
    var displayNoun: String {
        switch self {
        case .sensitiveNotes: return "private notes"
        case .periodData: return "period"
        case .journalNarratives: return "journal"
        case .intimacyLogs: return "intimate log"
        }
    }
}

/// The state the sealed-backup flow needs from the app store. Mirrors the
/// `WorkoutSyncContext` host-protocol pattern so `SealedBackupCoordinator` depends
/// on this seam rather than the concrete `FernletStore` (plan §5d). `sealedBackupContentKey`
/// is exposed as a narrow accessor so the store's `journalContentKey` stays private
/// (it migrates to JournalSealingCoordinator in a later phase).
@MainActor
protocol SealedBackupContext: AnyObject {
    var tierTwoMemories: [TierTwoMemoryRecord] { get }
    var sealedBackupContentKey: SymmetricKey? { get }
    /// Whether cycle tracking is visible. The backup paths must consult this: both reconcile and
    /// restore decrypt period narratives on ambient, launch-time paths that no view drives.
    var isPeriodTrackingVisible: Bool { get }
    /// Whether intimacy tracking is visible. Same contract as ``isPeriodTrackingVisible`` and for the
    /// same reason: the intimacy backup's reconcile pages the whole log store through plaintext and
    /// its restore writes decrypted logs back, both on ambient paths, so the hard gate has to be
    /// consulted on those paths rather than in a view.
    ///
    /// The coordinator works through its own `IntimacyLogStore` (that funnel defaults fail-CLOSED and
    /// is a leaf with no access to settings, so somebody has to supply the gate) — `ContentView` owns
    /// the app's other instance and is unreachable from here, which is why the derived value arrives
    /// through this seam instead.
    var isIntimacyTrackingVisible: Bool { get }
    var previousJournals: [JournalEntry] { get }
    var memories: [MemoryNote] { get }
    var recentMeals: [Meal] { get }
    func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord])
    func loadAllDaysFromRepository() -> [String: FernletDay]
    /// Records whether a sealed PERIOD backup still needs re-uploading under a newly-adopted escrow key
    /// because period tracking is currently hidden (G5). Surfaced non-silently so the user can trigger the
    /// re-upload after un-hiding, instead of the cloud chunk silently staying sealed to the old identity.
    func recordSealedBackupPeriodReuploadDeferred(_ deferred: Bool)
    /// Records the outcome of a sealed-backup restore attempt so the UI can show an honest, retryable
    /// status (WS-4) instead of a silently-swallowed failure.
    func recordSealedBackupRestoreOutcome(_ outcome: SealedBackupRestoreOutcome, payloadType: SealedBackupPayloadType)
    /// Records whether a cross-device escrow-key conflict was detected (WS-3) so the UI can surface a
    /// non-silent choice before anything is overwritten or re-uploaded.
    func recordSealedBackupEscrowConflict(_ inConflict: Bool)
    /// Rebuilds the day-blob journal SKELETONS for freshly restored journal narratives, so restored
    /// entries are actually visible.
    ///
    /// Load-bearing, not cosmetic. The journal UI reads `FernletDay.journals` for the entry list and
    /// hydrates the text by id from the sealed narrative store — the blob holds the skeleton + order,
    /// the sealed store holds the words. On a sync-OFF device reset the blob is gone too, so restoring
    /// narrative rows alone yields entries that exist and decrypt but are rendered by nothing. That
    /// fails precisely the users the sealed backup exists to protect.
    ///
    /// Implementations must merge one `JournalEntry` per narrative id into that narrative's day
    /// (skipping ids the day already has), schedule a snapshot save, and re-run the sealed-journal
    /// refresh so hydration fills the text back in by id.
    func reinstateJournalEntries(from narratives: [JournalNarrative])
}

/// The result of a single sealed-backup restore attempt, rich enough that the UI can show an honest,
/// retryable status instead of a silent boolean (WS-4). `didRestore` preserves the historical Bool
/// contract for callers/tests that only care whether records actually landed.
enum SealedBackupRestoreOutcome: Equatable {
    /// Records were decrypted and written into the local stores.
    case restored(Int)
    /// No sealed backup exists in iCloud for this payload — nothing to do (not a failure).
    case nothingToRestore
    /// The local store already holds user data — never clobbered (not a failure).
    case skippedStoreNotEmpty
    /// The backup-escrow key isn't present yet (iCloud Keychain still syncing) — retryable. NEVER minted
    /// on this path, so this is the honest "not synced yet" state rather than a fabricated identity.
    case deferredKeyNotSynced
    /// The content key is locked (period data) — retryable after the user unlocks.
    case deferredLocked
    /// A transport/decode error, or an incomplete/mixed-generation chunk set — retryable next launch.
    case deferredTransient
    /// The record isn't ours (escrow-identity mismatch) or is corrupt — a distinct, honest message.
    case notRecognized
    /// The backup in iCloud authenticates but is OLDER than one this device already wrote or
    /// restored — a rollback (code review finding 14). Deliberately **terminal, not retryable**:
    /// retrying re-fetches the same substituted record forever, and silently retrying is exactly the
    /// failure mode the rollback defense exists to end. The user is told, and nothing is written.
    case rolledBack

    var didRestore: Bool {
        if case .restored = self { return true }
        return false
    }

    /// Whether this outcome left something the user should see (WS-4 "visible"). The benign outcomes
    /// (restored / nothing-to-restore / skipped-non-empty) do not.
    var needsAttention: Bool {
        switch self {
        case .deferredKeyNotSynced, .deferredLocked, .deferredTransient, .notRecognized, .rolledBack:
            return true
        case .restored, .nothingToRestore, .skippedStoreNotEmpty: return false
        }
    }

    /// Whether re-running restore could plausibly succeed later (WS-4 "retryable"). `notRecognized` is
    /// terminal for the current backup (a different key won't appear by retrying).
    var isRetryable: Bool {
        switch self {
        case .deferredKeyNotSynced, .deferredLocked, .deferredTransient: return true
        // `.rolledBack` sits with `.notRecognized`: retrying re-fetches the identical record, so a
        // Retry affordance would only promise something it can never deliver.
        case .restored, .nothingToRestore, .skippedStoreNotEmpty, .notRecognized, .rolledBack:
            return false
        }
    }
}

/// Sealed CloudKit backup: reconcile (enable/disable upload) + restore (new-device /
/// fresh-install pull), extracted from `FernletStore` (plan §5d). Owns the
/// `SealedBackupService` / `CloudKitDataService` / `MenstrualNarrativeRepository`
/// dependencies, keeping the CloudKit egress + sealed-narrative store off the
/// store/core path.
@MainActor
final class SealedBackupCoordinator {
    /// Local preconditions a sealed-backup operation can fail on, before or without touching CloudKit.
    ///
    /// Thrown by the period seal/restore paths and mapped onto a retryable
    /// ``SealedBackupRestoreOutcome`` by `classifyRestoreFailure`.
    enum SealedBackupWiringError: Error, Equatable {
        /// Period-data sealing/restore attempted while the content key is locked.
        case locked
        /// Restore attempted into a store that already holds user data — refused to avoid clobbering.
        case storeNotEmpty
    }

    /// Records per sealed chunk on every paged export (period, journal, intimacy). Bounds the
    /// plaintext/ciphertext held in memory while sealing to ~this many records regardless of how long
    /// the history is. One size for all three payloads deliberately: journal text is longer per record,
    /// but the number only has to keep a chunk comfortably inside a `CKAsset`, and a single constant is
    /// one thing to reason about instead of three.
    static let periodBackupChunkSize = 250

    private unowned let host: any SealedBackupContext

    init(host: any SealedBackupContext) {
        self.host = host
    }

    /// How the backup-escrow key should be prepared on the identity before a sealed-backup operation.
    /// Splitting these is the heart of the escrow-race fix (WS-1): the open/restore path must NEVER mint
    /// a key, while the seal/enable path may mint one lazily (and stores it `ThisDeviceOnly` first, WS-2).
    private enum EscrowMode {
        /// Disable/delete — no escrow key needed (delete is by record name).
        case none
        /// Seal/enable — adopt a synced/local key, else mint one ThisDeviceOnly (lazy generation).
        case forSealing
        /// Open/restore — adopt an existing key only; absence is surfaced as "not synced yet", never minted.
        case forOpening
    }

    /// How strict the no-clobber gate is for a given restore.
    ///
    /// The launch/auto path requires a genuinely unused device (`.freshInstall`). The un-hide path
    /// cannot use that gate at all: by the time a user un-hides cycle tracking the day blob has long
    /// since synced down, so `isFreshInstallForRestore` is permanently false and the sealed period
    /// backup would be unrestorable forever — defeating the point of having it.
    ///
    /// `.payloadStoreOnly` drops only the WHOLE-DEVICE freshness check and keeps the per-payload store
    /// check, which is the invariant that actually protects period data: restore writes into nothing but
    /// the sealed narrative store, so an empty narrative store means there is no cycle history to clobber
    /// however much unrelated (food / journal / day) data the device holds. It is deliberately not
    /// offered for `.sensitiveNotes`, whose Tier-2 writeback is a whole-store OVERWRITE.
    enum RestoreScope {
        /// Launch/auto restore — whole-device fresh install AND the payload's own store empty.
        case freshInstall
        /// Targeted single-payload restore — only the payload's own store must be empty.
        case payloadStoreOnly
    }

    /// Builds an `IdentityService` with the escrow key prepared per `escrowMode`, or nil if provisioning
    /// failed. For `.forOpening`, `escrowReady` reports whether a usable escrow key is present so the
    /// caller can short-circuit to a retryable "not synced yet" state without any network work.
    private func makeIdentity(escrowMode: EscrowMode) -> (identity: IdentityService, escrowReady: Bool)? {
        let identity = IdentityService()
        do { try identity.ensureProvisioned() } catch { return nil }
        switch escrowMode {
        case .none:
            return (identity, true)
        case .forSealing:
            identity.provisionBackupEscrowKeyForSealing()
            return (identity, true)
        case .forOpening:
            return (identity, identity.loadBackupEscrowKeyForOpen())
        }
    }

    /// How many cycle narratives this device holds, counted without decrypting anything. A count error
    /// fails CLOSED at 0 — callers use this to refuse a destructive empty-store re-upload, so "unknown"
    /// must read as "do not re-upload".
    func periodNarrativeCount() -> Int {
        (try? MenstrualNarrativeRepository().narrativeCount()) ?? 0
    }

    /// How many journal narratives this device holds, counted without decrypting anything. Fails CLOSED
    /// at 0 for the same reason as ``periodNarrativeCount()``: callers use it to refuse a destructive
    /// empty-store re-upload, so "unknown" must read as "do not re-upload".
    func journalNarrativeCount(repository: JournalNarrativeRepository? = nil) -> Int {
        ((try? (repository ?? JournalNarrativeRepository()).narrativeCount())) ?? 0
    }

    /// How many intimacy logs this device holds, counted without decrypting anything. Fails CLOSED at 0,
    /// like the other two counts. Ungated by visibility on purpose — it decrypts nothing, and a hidden
    /// store must never read as "empty" to the re-upload guards.
    func intimacyLogCount(store: IntimacyLogStore? = nil) -> Int {
        ((try? resolvedIntimacyStore(store).backupLogCount())) ?? 0
    }

    /// The gated intimacy funnel this coordinator works through, with its visibility gate wired to the
    /// host.
    ///
    /// Intimacy is reached via ``IntimacyLogStore``, never a raw `IntimacyLogRepository`: the app
    /// target is grep-walled against constructing the repository directly (`SensitiveSurfaceGateTests`)
    /// precisely so no call site can read or write around the hard gate. `IntimacyLogStore` defaults
    /// fail-CLOSED (`isVisible = { false }`), so the gate is wired HERE — on the injected instance too,
    /// not just a fresh one — and a test therefore drives it by flipping the host's visibility rather
    /// than by handing in an ungated store.
    private func resolvedIntimacyStore(_ injected: IntimacyLogStore?) -> IntimacyLogStore {
        let store = injected ?? IntimacyLogStore()
        store.isVisible = { [weak self] in self?.host.isIntimacyTrackingVisible ?? false }
        return store
    }

    /// Whether one of the two PAGED payloads added in Phase 3 may be re-sealed and re-uploaded from
    /// this device's local store right now — the **empty-store-clobber** guard.
    ///
    /// `reconcileChunked` writes a head record even for a count of 0, so an export always REPLACES the
    /// cloud copy. On a device that has not restored yet, the local store is empty for the same reason
    /// the backup exists (the data lives only in iCloud), so re-uploading would destroy exactly what is
    /// being recovered. An empty store therefore means "not restored yet", never "nothing to back up",
    /// and this returns false. Skipping is recoverable (re-upload from a device that still holds the
    /// data, or after this one restores); an empty overwrite is not.
    ///
    /// Intimacy additionally requires visibility: while hidden the reconcile is a silent no-op, so
    /// calling it would log a false "reconciled" while the cloud chunk stayed sealed to the old key.
    ///
    /// - Note: Deliberately scoped to the two new payloads. `.sensitiveNotes` is a whole-store
    ///   overwrite payload with its own semantics, and `.periodData` keeps its pre-existing, subtly
    ///   different guard (it records a re-upload deferral when hidden rather than merely skipping), so
    ///   folding them in here would silently change behavior this phase is not meant to touch.
    func mayReuploadFromLocalStore(
        _ payloadType: SealedBackupPayloadType,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil
    ) -> Bool {
        switch payloadType {
        case .sensitiveNotes, .periodData:
            return true
        case .journalNarratives:
            return journalNarrativeCount(repository: journalRepository) > 0
        case .intimacyLogs:
            return host.isIntimacyTrackingVisible && intimacyLogCount(store: intimacyStore) > 0
        }
    }

    private func makeSealedBackupService(identity: IdentityService) -> SealedBackupService {
        SealedBackupService(cloudDataService: CloudKitDataService(), identityService: identity)
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
        // Enabling SEALS (needs an escrow key — minted lazily here if absent, WS-1); disabling only
        // DELETES the chunk set (no escrow key needed).
        guard let prepared = makeIdentity(escrowMode: enabled ? .forSealing : .none) else {
            FernletAuditLog.log("sealedBackup.notProvisioned", context: ["payload": payloadType.rawValue])
            return false
        }
        let service = makeSealedBackupService(identity: prepared.identity)
        do {
            switch (payloadType, enabled) {
            case (.sensitiveNotes, _):
                try await service.reconcile(try sensitiveNotesPlaintext(), payloadType: payloadType, enabled: enabled)
            case (.periodData, true):
                try await reconcilePeriodBackup(using: service)
            case (.journalNarratives, true):
                try await reconcileJournalBackup(using: service)
            case (.intimacyLogs, true):
                try await reconcileIntimacyBackup(using: service)
            // Disabling any paged payload is the same operation: delete the whole chunk set. It needs
            // no content key and no visibility, which is what keeps "turn it off" available while
            // locked and while the surface is hidden.
            case (.periodData, false), (.journalNarratives, false), (.intimacyLogs, false):
                try await service.reconcile(Data(), payloadType: payloadType, enabled: false)
            }
            FernletAuditLog.log("sealedBackup.reconciled", context: [
                "payload": payloadType.rawValue, "enabled": enabled ? "true" : "false"
            ])
            if payloadType == .periodData {
                // A pending period re-upload deferral (G5) is discharged by ANY successful period
                // reconcile that actually touched the cloud chunk: an enable that really paged the
                // narratives (visible — the hidden path above is a silent no-op, which must NOT clear),
                // or a disable that deleted the backup outright. Cleared here, at the one seam every
                // caller funnels through (the Privacy & Data toggle, the adopt flow, the un-hide
                // trigger, delete-all), rather than per-caller.
                if !enabled || host.isPeriodTrackingVisible {
                    host.recordSealedBackupPeriodReuploadDeferred(false)
                }
            }
            return true
        } catch SealedBackupWiringError.locked where payloadType == .periodData && enabled {
            // The narratives are sealed under the Private tab's content key, which is only live while
            // THAT tab holds the unlock (`FernletLockScope.privateHub`) — and this toggle lives in
            // Settings, which is reached from Home, by which point the hub has re-locked. Refusing
            // here would make "turn on encrypted period backup" a silently-reverting toggle with no
            // path that ever works.
            //
            // So honor the intent and DEFER: the preference sticks, the Privacy & Data banner already
            // surfaces `sealedBackupPeriodReuploadDeferred` as a pending re-upload, and the seal runs
            // the next time the Private tab unlocks (`retryDeferredPeriodReuploadIfNeeded`) or at the
            // next launch (`restoreSealedBackupsIfNeeded`). Success clears the flag through the normal
            // path above. Deliberately NOT extended to the disable case — disabling deletes the cloud
            // chunk set and needs no content key, so it can never land here.
            host.recordSealedBackupPeriodReuploadDeferred(true)
            FernletAuditLog.log("sealedBackup.periodSealDeferredUntilUnlock")
            return true
        } catch {
            FernletAuditLog.log("sealedBackup.reconcileFailed", context: ["payload": payloadType.rawValue])
            return false
        }
    }

    /// Runs a deferred period re-upload once the narratives are reachable again. Called when the
    /// Private tab unlocks (the content key becomes available) and, with the same guards, from the
    /// launch pass. Idempotent and a no-op unless a deferral is actually outstanding.
    ///
    /// The non-empty-store guard matches `restoreSealedBackupsIfNeeded`'s and is load-bearing:
    /// re-sealing pages the LOCAL store and rewrites the whole chunk set, so re-uploading from an
    /// empty one would overwrite the cloud backup with a single empty chunk — destroying the history
    /// the deferral exists to preserve.
    @discardableResult
    func retryDeferredPeriodReuploadIfNeeded() async -> Bool {
        let prefs = StoragePreferencesStore.currentPreferences()
        guard prefs.iCloudSyncEnabled,
              prefs.sealedBackupPeriodEnabled,
              prefs.sealedBackupPeriodReuploadDeferred,
              host.isPeriodTrackingVisible,
              periodNarrativeCount() > 0 else { return false }
        return await setSealedBackupEnabled(true, payloadType: .periodData)
    }

    /// Seals + uploads the period backup one bounded chunk at a time. The narrative count is read up
    /// front to size the chunk set, then `reconcileChunked` pages the repository so only one chunk's
    /// worth of plaintext/ciphertext is ever resident — the rest of the (possibly very long) history
    /// stays on disk. Requires an unlocked content key, matching the locked-key guard on restore.
    private func reconcilePeriodBackup(using service: SealedBackupService) async throws {
        // G5 (reconcile half). Pages the ENTIRE narrative store through plaintext, so it must honor
        // the gate. Deliberately a silent no-op rather than disabling `sealedBackupPeriodEnabled`:
        // turning that pref off DELETES the encrypted backup from iCloud, which would make hiding
        // destructive. The pref and the cloud record are left exactly as they are.
        guard host.isPeriodTrackingVisible else { return }
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

    /// Seals + uploads the journal backup one bounded chunk at a time, mirroring
    /// ``reconcilePeriodBackup(using:)``.
    ///
    /// **No visibility gate**, unlike period and intimacy: journaling has no hide switch — it is a
    /// core surface, always visible — so there is no gate to consult and adding a fake one would only
    /// invent a state nothing can reach.
    ///
    /// Requires an unlocked content key. This is the same `journalContentKey` the journal columns are
    /// sealed under while a lock is configured; a no-lock install seals under the device journal key
    /// instead, which this coordinator deliberately cannot see, so no-lock users cannot enable the
    /// journal backup at all (an honest, documented limit — see `Docs/Verifiability.md` §6.2).
    private func reconcileJournalBackup(using service: SealedBackupService) async throws {
        guard let key = host.sealedBackupContentKey else { throw SealedBackupWiringError.locked }
        let repository = JournalNarrativeRepository()
        let pageSize = Self.periodBackupChunkSize
        let total = try repository.narrativeCount()
        // Always at least one chunk so an empty (but enabled) backup still writes a head record.
        let chunkCount = max(1, (total + pageSize - 1) / pageSize)
        try await service.reconcileChunked(payloadType: .journalNarratives, chunkCount: chunkCount) { index in
            let page = try repository.narratives(offset: index * pageSize, limit: pageSize, contentKey: key)
            return try JSONEncoder().encode(page)
        }
    }

    /// Seals + uploads the intimacy backup one bounded chunk at a time, mirroring
    /// ``reconcilePeriodBackup(using:)`` — including its hidden-surface behavior.
    ///
    /// Pages the ENTIRE log store through plaintext, so it honors the hard visibility gate. While
    /// hidden this is a **silent no-op**, deliberately NOT a pref flip: turning
    /// `sealedBackupIntimacyEnabled` off DELETES the encrypted backup from iCloud, which would make
    /// *hiding* destructive. The pref and the cloud record are left exactly as they are, and hidden
    /// must never be allowed to read as "empty" anywhere downstream.
    private func reconcileIntimacyBackup(using service: SealedBackupService) async throws {
        guard host.isIntimacyTrackingVisible else {
            FernletAuditLog.log("sealedBackup.intimacyReconcileSkippedHidden")
            return
        }
        guard let key = host.sealedBackupContentKey else { throw SealedBackupWiringError.locked }
        let store = resolvedIntimacyStore(nil)
        let pageSize = Self.periodBackupChunkSize
        let total = try store.backupLogCount()
        // Always at least one chunk so an empty (but enabled) backup still writes a head record.
        let chunkCount = max(1, (total + pageSize - 1) / pageSize)
        try await service.reconcileChunked(payloadType: .intimacyLogs, chunkCount: chunkCount) { index in
            // `backupPage` re-checks the gate and THROWS if it flipped mid-export, rather than paging
            // empty — which would replace the cloud backup with nothing.
            let page = try store.backupPage(offset: index * pageSize, limit: pageSize, contentKey: key)
            return try JSONEncoder().encode(page)
        }
    }

    /// Called once at launch (after the store is ready), and again from the user's "Retry" action, to
    /// reconcile the escrow key and pull any sealed iCloud backups into the local stores. No-ops unless
    /// iCloud sync is on. Best-effort and non-fatal: failures are surfaced as a retryable status (WS-4),
    /// audited, and retried next launch. Gated by `FERNLET_SKIP_SEALED_RESTORE` so UI tests can opt out.
    ///
    /// `userInitiated` marks the user's explicit Retry (as opposed to the ambient launch pass) and lets
    /// the period half fall back to the targeted, payload-scoped restore — see below.
    func restoreSealedBackupsIfNeeded(userInitiated: Bool = false) async {
        guard ProcessInfo.processInfo.environment["FERNLET_SKIP_SEALED_RESTORE"] != "1" else { return }
        let prefs = StoragePreferencesStore.currentPreferences()
        guard prefs.iCloudSyncEnabled else { return }
        // Reconcile the escrow key BEFORE restoring so any open() runs under the authoritative key and a
        // cross-device key conflict is surfaced non-silently (WS-3).
        reconcileEscrowKey()
        if prefs.sealedBackupSensitiveNotesEnabled {
            _ = await restoreSealedBackupOutcome(payloadType: .sensitiveNotes)
        }
        // G5 (restore half). This decrypts cycle history off CloudKit and WRITES it into the local
        // narrative store, so a read-side gate alone would miss it. Skipping only defers: the backup
        // stays in iCloud and restores if the user un-hides.
        if prefs.sealedBackupPeriodEnabled && host.isPeriodTrackingVisible {
            let outcome = await restoreSealedBackupOutcome(payloadType: .periodData)
            // The pass above is fresh-install-only, so on a device that is already in use it can ONLY
            // ever answer `.skippedStoreNotEmpty` — including when the sealed narrative store is empty and
            // there really is a cycle history to pull down. That would make the restore banner's "tap
            // Retry" a silent no-op that merely clears the banner. On an explicit user retry, fall back to
            // the targeted, payload-scoped restore so Retry actually retries. (Ambient launches
            // deliberately do NOT take this branch — auto-restore stays conservative.) When the narrative
            // store genuinely holds history the fallback also answers `.skippedStoreNotEmpty`, so the
            // no-clobber behavior is unchanged.
            if userInitiated, outcome == .skippedStoreNotEmpty {
                _ = await restorePeriodBackupTargeted()
            }
        }
        // Journal has no visibility gate (journaling is always visible), so the pref alone decides.
        if prefs.sealedBackupJournalEnabled {
            _ = await restoreSealedBackupOutcome(payloadType: .journalNarratives)
        }
        // Intimacy mirrors the period half's G5 gate: this decrypts intimate notes off CloudKit and
        // WRITES them into the local sealed store, so a read-side gate alone would miss it. Skipping
        // only DEFERS — the backup stays in iCloud and restores if the user un-hides.
        if prefs.sealedBackupIntimacyEnabled && host.isIntimacyTrackingVisible {
            _ = await restoreSealedBackupOutcome(payloadType: .intimacyLogs)
        }
        // RESTORE-BEFORE-REUPLOAD: every payload above is pulled down BEFORE the re-upload
        // follow-through below runs, so a device that has not restored yet can never overwrite a good
        // cloud backup with its own empty store. The `count > 0` guards inside the re-upload paths are
        // the second half of that defense.
        // G5 follow-through: a persisted period re-upload deferral (the escrow adopt ran while period
        // tracking was hidden, or an earlier re-seal failed) is retried here once the narratives are
        // reachable again — so the deferral self-heals across launches instead of waiting for another
        // un-hide. Success clears the persisted flag inside setSealedBackupEnabled.
        //
        // Guarded on a NON-EMPTY narrative store. Re-sealing pages the LOCAL store and rewrites the whole
        // chunk set, so re-uploading from an empty one would overwrite the cloud backup with a single
        // empty chunk — destroying the very history the deferral exists to preserve. The restore half
        // above is fresh-install-only on the ambient path, so an empty store here means "not restored
        // yet", NOT "nothing to back up". The deferral flag stays set, so this self-heals on the launch
        // after the user actually restores (or re-uploads from a device that has the data).
        await retryDeferredPeriodReuploadIfNeeded()
    }

    /// Reconciles the backup-escrow key across iCloud Keychain (WS-3) and records any conflict so the UI
    /// can surface a non-silent choice. Adoption of a synced key and promotion of a local key are
    /// non-destructive and proceed; only a divergent synced-vs-local key is held back for user resolution.
    private func reconcileEscrowKey() {
        let identity = IdentityService()
        do { try identity.ensureProvisioned() } catch {
            FernletAuditLog.log("sealedBackup.escrowReconcileNotProvisioned")
            return
        }
        switch identity.reconcileBackupEscrowKey() {
        case .conflict:
            FernletAuditLog.log("sealedBackup.escrowConflict")
            host.recordSealedBackupEscrowConflict(true)
        case .noEscrow, .usingSynced, .promotedLocal:
            host.recordSealedBackupEscrowConflict(false)
        }
    }

    /// WS-3 user-confirmed conflict resolution: adopt the synced (other-device) escrow key as
    /// authoritative, then re-upload this device's enabled backups under it. The caller (UI) MUST warn
    /// the user first that device-only backups may need re-uploading. Returns whether a synced key was
    /// adopted; the conflict status is cleared on success.
    @discardableResult
    func adoptSyncedEscrowAndReupload() async -> Bool {
        let identity = IdentityService()
        do { try identity.ensureProvisioned() } catch {
            FernletAuditLog.log("sealedBackup.escrowAdoptNotProvisioned")
            return false
        }
        guard identity.adoptSyncedBackupEscrowKey() != nil else {
            FernletAuditLog.log("sealedBackup.escrowAdoptNoSyncedKey")
            return false
        }
        FernletAuditLog.log("sealedBackup.escrowAdopted")
        host.recordSealedBackupEscrowConflict(false)
        // Re-seal + re-upload whatever the user has enabled so the cloud copy matches the adopted key.
        let prefs = StoragePreferencesStore.currentPreferences()
        if prefs.sealedBackupSensitiveNotesEnabled {
            _ = await setSealedBackupEnabled(true, payloadType: .sensitiveNotes)
        }
        if prefs.sealedBackupPeriodEnabled {
            if host.isPeriodTrackingVisible {
                // Success clears the deferral inside setSealedBackupEnabled. A FAILED re-seal leaves the
                // cloud chunk sealed to the key we just replaced, so record it as still-deferred (the
                // banner surfaces it; retried at next launch) instead of silently claiming it done.
                if await !setSealedBackupEnabled(true, payloadType: .periodData) {
                    host.recordSealedBackupPeriodReuploadDeferred(true)
                }
            } else {
                // G5: period is hidden, so reconcilePeriodBackup is a silent no-op. Routing through
                // setSealedBackupEnabled here would log a FALSE "reconciled" while the cloud period chunk
                // stays sealed to the OLD escrow key we just replaced — a later restore of the user's OWN
                // backup then fails terminally with keyAgreementIdentityMismatch. Re-sealing requires
                // paging the (gated) narrative store, which we won't do while hidden. Record the deferral
                // honestly so it's surfaced (re-upload after un-hiding) rather than silently claimed done.
                host.recordSealedBackupPeriodReuploadDeferred(true)
                FernletAuditLog.log("sealedBackup.escrowAdoptPeriodDeferredHidden")
            }
        }
        // EMPTY-STORE CLOBBER guard, the `periodNarrativeCount() > 0` precedent. `reconcileChunked`
        // writes a head record even for count 0, so re-sealing from a store this device has not
        // restored into yet would replace the good cloud backup with a single empty chunk. An empty
        // store here means "not restored yet", NOT "nothing to back up" — the ambient restore above is
        // fresh-install-only. Skipping leaves the cloud chunk sealed to the key we just replaced; that
        // is recoverable (re-upload from a device that has the data, or after this one restores),
        // whereas an empty overwrite is not.
        if prefs.sealedBackupJournalEnabled {
            if mayReuploadFromLocalStore(.journalNarratives) {
                _ = await setSealedBackupEnabled(true, payloadType: .journalNarratives)
            } else {
                FernletAuditLog.log("sealedBackup.escrowAdoptJournalSkippedEmptyStore")
            }
        }
        if prefs.sealedBackupIntimacyEnabled {
            if mayReuploadFromLocalStore(.intimacyLogs) {
                _ = await setSealedBackupEnabled(true, payloadType: .intimacyLogs)
            } else {
                FernletAuditLog.log("sealedBackup.escrowAdoptIntimacySkipped")
            }
        }
        return true
    }

    /// Fetches/decrypts/writes a single sealed-backup payload into the local stores, returning a rich
    /// outcome AND recording it on the host so the UI can show a non-silent, retryable status (WS-4).
    @discardableResult
    func restoreSealedBackupOutcome(payloadType: SealedBackupPayloadType) async -> SealedBackupRestoreOutcome {
        let outcome = await performRestore(payloadType: payloadType)
        host.recordSealedBackupRestoreOutcome(outcome, payloadType: payloadType)
        return outcome
    }

    /// Targeted period-only restore. Driven by the two EXPLICIT user actions that should be able to pull
    /// a sealed cycle history back onto an in-use device: un-hiding cycle tracking, and tapping Retry on
    /// the restore banner. The ambient launch pass deliberately stays fresh-install-only.
    ///
    /// The G5 gate correctly skips the period restore at launch while cycle tracking is hidden, but the
    /// launch path only ever restores into a fresh install — so a user who hides period tracking on one
    /// device and reinstalls on another (iCloud sync on) could never get their sealed cycle history back:
    /// the day blob syncs down first, `performRestore` permanently returns `.skippedStoreNotEmpty`, and
    /// every other period seam (un-hide, escrow-adopt, launch follow-through) RE-UPLOADS rather than
    /// restores. This is the missing compensating restore path.
    ///
    /// Narrower than the launch restore in every way that matters: period payload only, and it still
    /// refuses a non-empty narrative store, so it can add the user's history back but never overwrite
    /// history they already have. The visibility re-check keeps the fail-closed-at-the-decrypt-seam
    /// property — this decrypts cycle narratives and writes them into the sealed store.
    ///
    /// Prefs gating (iCloud sync on, period backup enabled) lives with the caller, matching how
    /// `restoreSealedBackupsIfNeeded` holds the prefs guards and `performRestore` stays pure.
    @discardableResult
    func restorePeriodBackupTargeted(
        narrativeRepository: MenstrualNarrativeRepository? = nil
    ) async -> SealedBackupRestoreOutcome {
        // Fail-closed at the decrypt seam, same as the launch path. For the un-hide caller this is a
        // defensive re-check (it flips visibility first, so this only fires on a re-hide that raced the
        // task); for the Retry caller it is the real gate. Reported as retryable (un-hiding IS the retry)
        // and deliberately NOT recorded as a UI status — there is nothing here for the user to act on.
        // Crucially, `isRetryable` also stops the un-hide caller from re-uploading this device's
        // still-gated (unpageable) narrative store over the cloud backup.
        guard host.isPeriodTrackingVisible else {
            FernletAuditLog.log("sealedBackup.targetedPeriodRestoreSkippedHidden")
            return .deferredTransient
        }
        // An empty narrative store is NOT self-evidently safe to restore into. It means either "never
        // populated" (a genuine reinstall — restore is the point) or "the user deleted their cycle
        // entries" — and `PeriodTrackerStore.deleteEntry` hard-deletes the row WITHOUT reconciling the
        // sealed backup, so the cloud copy is stale by construction. Without this bit, un-hiding — a mere
        // visibility toggle — would silently resurrect deliberately-deleted cycle notes. The whole-device
        // freshness gate used to stand in for this ("has this device diverged from the cloud snapshot?");
        // `.payloadStoreOnly` drops that gate, so the marker has to carry the bit explicitly.
        // Resolved once so the latch check and the restore itself consult the SAME store.
        let repository = narrativeRepository ?? MenstrualNarrativeRepository()
        guard !repository.hasEverStoredNarrative else {
            FernletAuditLog.log("sealedBackup.targetedPeriodRestoreSkippedDeviceDiverged")
            return .skippedStoreNotEmpty
        }
        let outcome = await performRestore(
            payloadType: .periodData,
            scope: .payloadStoreOnly,
            narrativeRepository: repository
        )
        FernletAuditLog.log("sealedBackup.targetedPeriodRestoreAttempted")
        host.recordSealedBackupRestoreOutcome(outcome, payloadType: .periodData)
        return outcome
    }

    /// Bool-returning restore kept for the restore tests and the `FernletStore` wrapper. Does NOT record
    /// a UI status (the launch/retry path uses `restoreSealedBackupOutcome` for that); returns whether
    /// records were actually written.
    @discardableResult
    func restoreSealedBackup(payloadType: SealedBackupPayloadType) async -> Bool {
        await performRestore(payloadType: payloadType).didRestore
    }

    /// The actual restore. Splits every termination into a distinct outcome (WS-4): never marks restore
    /// "done" on a recoverable failure. The escrow key is loaded WITHOUT minting (WS-1) — its absence is
    /// reported as `.deferredKeyNotSynced` (retry), never a fabricated identity.
    private func performRestore(
        payloadType: SealedBackupPayloadType,
        scope: RestoreScope = .freshInstall,
        narrativeRepository: MenstrualNarrativeRepository? = nil,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil
    ) async -> SealedBackupRestoreOutcome {
        FernletAuditLog.log("sealedBackup.restoreAttempt", context: ["payload": payloadType.rawValue])
        // Resolved once and passed to BOTH the pre-network gate and the write, so they consult the same
        // store (an injected repository is how the un-hide tests exercise this without a real device store).
        let narrativeRepository = narrativeRepository ?? MenstrualNarrativeRepository()
        let journalRepository = journalRepository ?? JournalNarrativeRepository()
        let intimacyStore = resolvedIntimacyStore(intimacyStore)
        // Outer no-clobber check: this duplicates the AUTHORITATIVE gate inside applyRestoredChunks (which
        // re-checks under the same store before writing), but is kept deliberately as a pre-NETWORK
        // short-circuit — it skips the CloudKit fetch + decrypt entirely when the local store already holds
        // data. The inner check remains the source of truth against any TOCTOU between here and the write.
        guard isEmptyStoreForRestore(
            payloadType: payloadType,
            narrativeRepository: narrativeRepository,
            journalRepository: journalRepository,
            intimacyStore: intimacyStore,
            scope: scope
        ) else {
            FernletAuditLog.log("sealedBackup.restoreSkippedNonEmpty", context: ["payload": payloadType.rawValue])
            return .skippedStoreNotEmpty
        }
        guard let prepared = makeIdentity(escrowMode: .forOpening) else {
            FernletAuditLog.log("sealedBackup.restoreNotProvisioned", context: ["payload": payloadType.rawValue])
            return .deferredTransient
        }
        // No escrow key present yet → "not synced yet". Short-circuit before any network work; the open
        // path must NEVER mint a key (WS-1), so this is the honest retryable state.
        guard prepared.escrowReady else {
            FernletAuditLog.log("sealedBackup.restoreDeferredKeyNotSynced", context: ["payload": payloadType.rawValue])
            return .deferredKeyNotSynced
        }
        let service = makeSealedBackupService(identity: prepared.identity)
        do {
            guard let chunks = try await service.restoreChunks(payloadType: payloadType) else {
                FernletAuditLog.log("sealedBackup.restoreNothingToRestore", context: ["payload": payloadType.rawValue])
                return .nothingToRestore
            }
            let restored = try applyRestoredChunks(
                chunks,
                payloadType: payloadType,
                narrativeRepository: narrativeRepository,
                journalRepository: journalRepository,
                intimacyStore: intimacyStore,
                scope: scope
            )
            guard restored > 0 else {
                FernletAuditLog.log("sealedBackup.restoreNothingToRestore", context: ["payload": payloadType.rawValue])
                return .nothingToRestore
            }
            FernletAuditLog.log("sealedBackup.restored", context: [
                "payload": payloadType.rawValue, "count": String(restored)
            ])
            return .restored(restored)
        } catch {
            return classifyRestoreFailure(error, payloadType: payloadType)
        }
    }

    /// Maps a restore error to a distinct outcome (WS-4): "not yours/corrupt" (mismatch) vs "not synced
    /// yet" (no key) vs locked vs transient. The default catch is deliberately RETRYABLE — an incomplete
    /// or mixed-generation chunk set (`malformedRecord`) and transport/decode errors are all re-pulled
    /// next launch rather than declared terminal.
    private func classifyRestoreFailure(_ error: Error, payloadType: SealedBackupPayloadType) -> SealedBackupRestoreOutcome {
        switch error {
        case SealedBackupError.keyAgreementIdentityMismatch:
            FernletAuditLog.log("sealedBackup.restoreNotRecognized", context: ["payload": payloadType.rawValue])
            return .notRecognized
        case SealedBackupError.staleGeneration(let found, let lastSeen):
            // Terminal on purpose — see `.rolledBack`. Falling through to the retryable default
            // would re-pull the substituted record on every launch and never tell anyone.
            FernletAuditLog.log("sealedBackup.restoreRolledBack", context: [
                "payload": payloadType.rawValue,
                "found": String(found),
                "lastSeen": String(lastSeen)
            ])
            return .rolledBack
        case IdentityError.notProvisioned:
            FernletAuditLog.log("sealedBackup.restoreDeferredKeyNotSynced", context: ["payload": payloadType.rawValue])
            return .deferredKeyNotSynced
        case SealedBackupWiringError.locked:
            FernletAuditLog.log("sealedBackup.restoreDeferredLocked", context: ["payload": payloadType.rawValue])
            return .deferredLocked
        case SealedBackupWiringError.storeNotEmpty:
            FernletAuditLog.log("sealedBackup.restoreSkippedNonEmpty", context: ["payload": payloadType.rawValue])
            return .skippedStoreNotEmpty
        default:
            FernletAuditLog.log("sealedBackup.restoreFailed", context: ["payload": payloadType.rawValue])
            return .deferredTransient
        }
    }

    /// Decodes a single decrypted sealed-backup payload and writes it into the local stores. Thin
    /// wrapper over `applyRestoredChunks` (a single blob is just a one-element chunk set), kept for the
    /// restore tests and any single-record caller.
    @discardableResult
    func applyRestoredPayload(
        _ plaintext: Data,
        payloadType: SealedBackupPayloadType,
        narrativeRepository: MenstrualNarrativeRepository? = nil,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil,
        scope: RestoreScope = .freshInstall
    ) throws -> Int {
        try applyRestoredChunks(
            [plaintext],
            payloadType: payloadType,
            narrativeRepository: narrativeRepository,
            journalRepository: journalRepository,
            intimacyStore: intimacyStore,
            scope: scope
        )
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
        narrativeRepository: MenstrualNarrativeRepository? = nil,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil,
        scope: RestoreScope = .freshInstall
    ) throws -> Int {
        // A restore whose surrounding Task was cancelled must not write. The concrete race: the un-hide
        // settle Task is suspended in the CloudKit chunk fetch when "delete everything" runs; the funnel
        // cancels that Task (a live writer, like the debounced save and the guided run), and this check —
        // at the single write point every restore funnels through — makes the cancellation actually stop
        // the write instead of racing it. Cheap no-op in any uncancelled context, including the
        // synchronous test callers. (`CancellationError` classifies as `.deferredTransient` upstream.)
        try Task.checkCancellation()
        // Constructed here rather than as a default argument: `MenstrualNarrativeRepository` is
        // MainActor-isolated, and default-argument expressions evaluate in a nonisolated context.
        // Resolved BEFORE the guard so the no-clobber check and the inserts consult the SAME store
        // (the period-data guard now reads this repository's narrative count).
        let narrativeRepository = narrativeRepository ?? MenstrualNarrativeRepository()
        let journalRepository = journalRepository ?? JournalNarrativeRepository()
        let intimacyStore = resolvedIntimacyStore(intimacyStore)
        // No-clobber guard: refuse to overwrite/insert into a store that already holds user data,
        // regardless of how this method was reached.
        guard isEmptyStoreForRestore(
            payloadType: payloadType,
            narrativeRepository: narrativeRepository,
            journalRepository: journalRepository,
            intimacyStore: intimacyStore,
            scope: scope
        ) else {
            FernletAuditLog.log("sealedBackup.applySkippedNonEmpty", context: ["payload": payloadType.rawValue])
            throw SealedBackupWiringError.storeNotEmpty
        }
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
            // Decode every chunk, then write them in ONE all-or-nothing transaction. The former
            // per-record loop swallowed individual insert failures and returned the success count, so a
            // partial restore left the narrative store non-empty — which the no-clobber gate
            // (isEmptyStoreForRestore) then reads as "already restored", permanently skipping retry and
            // silently dropping the un-inserted sealed records. insertAtomically rolls back on any
            // failure, so a failed restore leaves the store empty and is re-pulled next launch. (Restore
            // collects the full history in memory rather than streaming per chunk: the chunking exists to
            // bound the EXPORT seal, and a personal cycle history is small enough that one transaction is
            // the right trade for restore atomicity.)
            var narratives: [MenstrualNarrative] = []
            for chunk in chunks {
                narratives.append(contentsOf: try JSONDecoder().decode([MenstrualNarrative].self, from: chunk))
            }
            try narrativeRepository.insertAtomically(narratives, contentKey: key)
            return narratives.count
        case .journalNarratives:
            guard let key = host.sealedBackupContentKey else { throw SealedBackupWiringError.locked }
            var narratives: [JournalNarrative] = []
            for chunk in chunks {
                narratives.append(contentsOf: try JSONDecoder().decode([JournalNarrative].self, from: chunk))
            }
            try journalRepository.insertAtomically(narratives, contentKey: key)
            // SELF-SUFFICIENCY (journal only). The sealed rows carry the whole entry, but the journal UI
            // renders `FernletDay.journals` skeletons and hydrates the text by id — and on a sync-OFF
            // device reset the day blob is gone too, so rows alone would restore INVISIBLE entries.
            // Rebuild the skeletons from what we just wrote. Runs after the transaction commits, so a
            // rolled-back restore never leaves orphan skeletons pointing at rows that do not exist.
            host.reinstateJournalEntries(from: narratives)
            return narratives.count
        case .intimacyLogs:
            guard let key = host.sealedBackupContentKey else { throw SealedBackupWiringError.locked }
            var logs: [IntimacyLog] = []
            for chunk in chunks {
                logs.append(contentsOf: try JSONDecoder().decode([IntimacyLog].self, from: chunk))
            }
            // Routed through the gated funnel: a restore seals plaintext in, so it must not run
            // behind the visibility gate. Hidden throws (→ `.deferredTransient`, retryable) and the
            // restore self-heals once the user un-hides.
            try intimacyStore.restore(logs, contentKey: key)
            // No skeleton step: `IntimacyLog` is self-contained and the intimacy UI reads
            // `IntimacyLogStore.logs` straight from this store.
            return logs.count
        }
    }

    /// Whether the local store is empty enough that restoring `payloadType` cannot clobber or
    /// duplicate existing user data. At `.freshInstall` scope this requires a fresh install for all
    /// payloads; sensitive-notes additionally requires the (overwrite-style) Tier-2 store to be empty,
    /// and period-data the sealed narrative store to be empty. At `.payloadStoreOnly` scope only the
    /// per-payload store check runs — see `RestoreScope` for why that is still no-clobber for period data.
    private func isEmptyStoreForRestore(
        payloadType: SealedBackupPayloadType,
        narrativeRepository: MenstrualNarrativeRepository,
        journalRepository: JournalNarrativeRepository,
        intimacyStore: IntimacyLogStore,
        scope: RestoreScope
    ) -> Bool {
        if scope == .freshInstall, !isFreshInstallForRestore() { return false }
        switch payloadType {
        case .sensitiveNotes:
            return host.tierTwoMemories.isEmpty
        case .periodData:
            // Menstrual narratives live in the separate PrivateHealthStore and are written independently
            // of the days blob (PeriodTrackerStore.logEvent), so a device can hold sealed cycle history
            // while still looking "fresh" by the day/memory checks above. Restore inserts with no upsert
            // and runs every launch, so gate on the narrative store itself (a cheap count, no
            // decryption) — otherwise a re-restore duplicates that history. A count error fails closed
            // (treated as non-empty → skip), which is safe to retry next launch. NOTE: only the menstrual
            // narrative store is gated/backed up here; intimacy logs (IntimacyLogRepository) are NOT part
            // of the `.periodData` payload, so do not assume this gate covers them.
            //
            // ALSO refuses an empty-but-DIVERGED store: `hasEverStoredNarrative` is the device-local
            // "this install held cycle data at some point" latch, and an empty store behind a set latch
            // means the user deleted their entries — restoring the (stale-by-construction) cloud copy
            // there would resurrect them. Checked HERE, in the one gate every restore path funnels
            // through, so the AMBIENT fresh-install pass honors it too: a completed delete-all makes the
            // device classify as fresh again, and without this bit a backup surviving a failed chunk
            // delete would silently restore the wiped history at the next launch. It also backstops an
            // in-flight restore that resumes after a wipe — `applyRestoredChunks` re-checks this gate
            // before writing. (The targeted path's own latch guard remains as its pre-network
            // short-circuit, mirroring the outer/inner count checks.)
            return (try? narrativeRepository.narrativeCount()) == 0
                && !narrativeRepository.hasEverStoredNarrative
        case .journalNarratives:
            // Same shape and the same two reasons as period, on the journal's own sealed store:
            // a cheap count (no decryption) so a re-restore cannot duplicate the history, AND the
            // one-way divergence latch so an empty-but-DIVERGED store — the user deleted their entries
            // — is never re-populated from the stale-by-construction cloud copy. Deleting a journal
            // entry drops the narrative row without reconciling the backup, exactly like cycle data.
            //
            // A count error fails CLOSED (treated as non-empty → skip), which is safe to retry.
            return (try? journalRepository.narrativeCount()) == 0
                && !journalRepository.hasEverStoredNarrative
        case .intimacyLogs:
            // Same again on the intimacy store. Note this gate is deliberately NOT visibility-aware:
            // it counts rows without decrypting, and the visibility gate lives one level up (the
            // launch pass skips the payload entirely while hidden). Reading a hidden store as "empty"
            // here would be the classic hidden-means-empty bug, so it never reads the gate at all.
            return (try? intimacyStore.backupLogCount()) == 0
                && !intimacyStore.hasEverStoredLog
        }
    }

    /// True only when the device holds genuinely no data — no day carries anything AND the rolling
    /// in-memory caches are empty, i.e. the user has not yet recorded anything on this device.
    ///
    /// This gate is deliberately STRICTER than `FernletDay.hasLoggedContent`: it also treats a day whose
    /// only content is a *bare, metric-less* `healthContext` (a HealthKit sync stamp — `syncedAt` set,
    /// every metric nil) as "has data". `hasLoggedContent` intentionally ignores that stamp (so the coin
    /// economy doesn't award an "active day" for merely opening the app with HealthKit enabled), but the
    /// auto-restore gate must be CONSERVATIVE: any day row at all — including a bare sync stamp — means the
    /// device is already in use, and auto-restore must NOT run over it. A truly-blank device has zero day
    /// rows (or all-nil days with no `healthContext`), so it still classifies as fresh and a legitimate
    /// restore proceeds. Do NOT relax this to `hasLoggedContent`/`hasContent` (that reopened the leak).
    private func isFreshInstallForRestore() -> Bool {
        let anyDayWithData = host.loadAllDaysFromRepository().values.contains {
            $0.hasLoggedContent || $0.healthContext != nil
        }
        return !anyDayWithData && host.previousJournals.isEmpty && host.memories.isEmpty && host.recentMeals.isEmpty
    }
}
