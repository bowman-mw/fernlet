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
    ///
    /// Localized (review A4 follow-up F4). Every consumer splices this into the `%@` slot of an
    /// app-target sentence that DOES localize, so an English noun here shipped a half-translated
    /// sentence — the failure is invisible in English and unfixable by a translator, who never sees
    /// the word at all. Lower-case because every call site reads mid-sentence ("the encrypted
    /// period backup"); the enum's own `rawValue` stays the frozen persisted/CloudKit token.
    var displayNoun: String {
        switch self {
        case .sensitiveNotes:
            // Retired payload: no toggle or restore banner names it any more, but the exhaustive
            // switch keeps a noun, and the catalog key stays rather than churning a translation.
            return String(localized: "sealedBackup.noun.sensitiveNotes", defaultValue: "private notes",
                          comment: "Mid-sentence noun for the sealed backup of the user's private notes, e.g. 'the encrypted private notes backup'.")
        case .periodData:
            return String(localized: "sealedBackup.noun.periodData", defaultValue: "period",
                          comment: "Mid-sentence noun for the sealed backup of cycle data, e.g. 'the encrypted period backup'.")
        case .journalNarratives:
            return String(localized: "sealedBackup.noun.journalNarratives", defaultValue: "journal",
                          comment: "Mid-sentence noun for the sealed backup of journal entries.")
        case .intimacyLogs:
            return String(localized: "sealedBackup.noun.intimacyLogs", defaultValue: "intimate log",
                          comment: "Mid-sentence noun for the sealed backup of intimate-activity logs.")
        }
    }
}

/// The state the sealed-backup flow needs from the app store. Mirrors the
/// `WorkoutSyncContext` host-protocol pattern so `SealedBackupCoordinator` depends
/// on this seam rather than the concrete `FernletStore` (plan §5d). `sealedBackupContentKey`
/// is the Private tab's content key (period-data design 2026-09-30, §9.10) — the one key every
/// sealed payload is written under, in both passcode modes and on every Private section.
///
/// Deliberately exposes NOTHING of the Tier-2 behavioral memories (owner decision 2026-09-23): the
/// retired sensitive-notes payload was the only reader and writer, and with the seam gone the
/// coordinator cannot even name the records a future payload might otherwise re-export.
@MainActor
protocol SealedBackupContext: AnyObject {
    /// The Private tab's content key, or nil while the tab is closed.
    var sealedBackupContentKey: SymmetricKey? { get }
    /// Whether AMBIENT restores (the launch pass, the Private tab's settle, an un-hide) must skip
    /// every payload because an app-lock reset is waiting for the device owner (design §5.3, Q14).
    /// The user's explicit restores still run.
    var sealedBackupRestoreAwaitsOwner: Bool { get }
    /// Whether a re-upload of `payloadType` must wait for the device owner: an app-lock reset is
    /// waiting and that payload's pre-reset iCloud copy is still there to keep (its backup was on at the
    /// reset and has not been deleted since). A payload with no such copy re-uploads as usual (review
    /// N-1) — holding it would keep the user's new entries out of the backup with nothing to protect.
    func sealedBackupKeepsPreResetCopy(of payloadType: SealedBackupPayloadType) -> Bool
    /// Records that `payloadType`'s iCloud chunk set was just deleted (a disable reconcile that landed:
    /// the user's switch, or "delete everything"), so the owner hold has no pre-reset copy of it left to
    /// keep. Called only after a delete that succeeded; a failed one leaves the copy protected.
    func recordSealedBackupCloudCopyDeleted(_ payloadType: SealedBackupPayloadType)
    /// Records that `payloadType`'s restore landed for good (`.restored`, or `.nothingToRestore`: the
    /// set was merged or there is none), so the owner hold has no pre-reset copy of it left to keep
    /// from a re-upload. Called by the coordinator after every such restore outcome.
    func recordSealedBackupPreResetCopySettled(_ payloadType: SealedBackupPayloadType)
    /// Releases the AMBIENT-restore half of an app-lock reset's owner hold — the device owner asked for
    /// the restore in Privacy & Data, behind its fresh device-owner check (design §5.3, Q14). The
    /// per-payload re-upload half stays until each payload's restore has landed.
    func releaseSealedBackupRestoreHold()
    /// The period backup's device-local bookkeeping: the restore marker and the compare-and-swap
    /// record (period-data design 2026-09-30, §5.3, §9.10).
    var periodBackupLedger: PeriodBackupLedger { get }
    /// How many cycle-record mutations this process has seen — moved by
    /// ``markPeriodBackupDirtyIfEnabled()``. The period export compares it before and after, so the
    /// re-upload flag clears only when nothing changed underneath (§9.10, I29).
    var periodBackupMutationCount: Int { get }
    /// The cycle-record funnels' mutation hook (§9.10 "Dirty re-export", R2-F3): counts the mutation
    /// and, while the period backup is on, records the period re-upload as owed — never touching the
    /// backup's enabled switch.
    func markPeriodBackupDirtyIfEnabled()
    /// Records what the period export has to tell Privacy & Data (§10.6).
    func recordPeriodBackupExportState(_ state: PeriodBackupExportState)
    /// Whether cycle tracking is visible. The backup paths must consult this: both reconcile and
    /// restore decrypt cycle records on ambient, launch-time paths that no view drives.
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
    func loadAllDaysFromRepository() -> [String: FernletDay]
    /// Records whether a sealed backup of `payloadType` still owes an upload — the surface was hidden
    /// when the escrow key was adopted (G5), the content key was locked when the user turned the backup
    /// on, or the local store was still empty because this device has not restored yet.
    ///
    /// Per-payload rather than period-only since Phase 3: journal and intimacy are sealed under the very
    /// same `.privateHub` content key, so they hit the identical "enabled from Settings while the hub is
    /// re-locked" state, and a skip nobody records is a skip nobody ever retries. Surfaced non-silently
    /// so the user sees the pending upload instead of the cloud chunk quietly staying sealed to a key
    /// this device no longer holds. `.sensitiveNotes` is retired and never seals, so it can never
    /// owe a re-upload; implementations ignore it.
    func recordSealedBackupReuploadDeferred(_ deferred: Bool, payloadType: SealedBackupPayloadType)
    /// Records that the retirement sweep DELETED a retired payload's surviving iCloud copy, so the
    /// persisted "a copy may still exist" marker — `StoragePreferences.sealedBackupSensitiveNotesEnabled`
    /// for the one retired payload, `.sensitiveNotes` — can be cleared and later launches make no
    /// CloudKit call for it. Called only after a delete that actually landed: a failed one leaves the
    /// marker set, which is how the next pass, and "delete everything", still find the copy.
    func recordRetiredSealedBackupDeleted(_ payloadType: SealedBackupPayloadType)
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
/// `SealedBackupService` / `CloudKitDataService` dependencies and the sealed stores' backup seams,
/// keeping the CloudKit egress off the store/core path.
///
/// **The period backup is v2** (period-data design 2026-09-30, §9.10): whole sealed `CycleRecord`s;
/// restored by an id-keyed MERGE while this install's restore is unresolved
/// (``restorePeriodBackup(initiatedByUser:)``); exported only behind restore-first (E1), the
/// compare-and-swap against the set in iCloud (E2), a full decrypt pre-pass (E3) and a live Private
/// tab key (E4); marked owed by every cycle-record mutation and re-exported at the next Cycle settle
/// (``settlePeriodBackup()``). The journal and intimacy backups keep the v1 model: an empty-store-only
/// restore and a re-upload on enable, retry, adopt and un-hide.
@MainActor
final class SealedBackupCoordinator {
    /// Local preconditions a sealed-backup operation can fail on, before or without touching CloudKit.
    ///
    /// Thrown by the period seal/restore paths and mapped onto a retryable
    /// ``SealedBackupRestoreOutcome`` by `classifyRestoreFailure`.
    enum SealedBackupWiringError: Error, Equatable {
        /// Period-data sealing/restore attempted while the content key is locked.
        ///
        /// Also raised by the journal/intimacy EXPORT when the store holds rows that the current
        /// content key cannot open: those rows exist but this key cannot page them, which is
        /// operationally the same state as "no usable key" — and, crucially, must not be exported as an
        /// empty chunk set over a good cloud backup.
        case locked
        /// Restore attempted into a store that already holds user data — refused to avoid clobbering.
        case storeNotEmpty
        /// Export refused because the local store holds nothing this device could seal — either a
        /// first-ever enable with no entries yet, or (the dangerous case) a device that has not
        /// restored yet. `reconcileChunked` writes a head record even for a count of 0, so exporting
        /// here would REPLACE the cloud copy with a single empty chunk. Recorded as a per-payload
        /// deferral and retried once the store has something to seal.
        case emptyLocalStore
        /// Export refused because the payload's surface is hidden, so its store cannot be paged
        /// (the gated funnel throws rather than paging empty). Recorded as a per-payload deferral and
        /// discharged on un-hide — never a pref flip, which would DELETE the cloud backup and make
        /// hiding destructive.
        case surfaceHidden
        /// The PERIOD export waits for this install's period restore to resolve (period-data design
        /// 2026-09-30, §9.10 E1): a fresh install must never write over the cloud copy before pulling
        /// it. A deferral; the next Cycle settle restores first, then exports.
        case periodRestorePending
        /// The PERIOD export refused because the set in iCloud is not one this install wrote or merged
        /// (§9.10 E2, Q9) — another iPhone's, or this one's before a reset. A deferral, named in
        /// Privacy & Data, which offers "Restore it here" and "Replace it with this iPhone's history".
        case periodHeldByAnotherDevice
        /// The PERIOD export's pre-pass found records that can never open here (§9.10 E3). Nothing is
        /// written; named in Privacy & Data.
        case periodEntriesUnopenable
        /// The PERIOD export could not decide a record (the install binding did not answer) or this
        /// install's writer tag. Retried at the next Cycle settle; nothing is written.
        case periodExportUndecided
    }

    /// Records per sealed chunk on every paged export (period, journal, intimacy). Bounds the
    /// plaintext/ciphertext held in memory while sealing to ~this many records regardless of how long
    /// the history is. One size for all three payloads deliberately: journal text is longer per record,
    /// but the number only has to keep a chunk comfortably inside a `CKAsset`, and a single constant is
    /// one thing to reason about instead of three.
    static let periodBackupChunkSize = 250

    private unowned let host: any SealedBackupContext

    /// Builds the identity the sealed records are sealed/opened under. Injectable ONLY so tests can
    /// point it at a throwaway keychain service instead of the device's real one; production leaves it
    /// nil and gets `IdentityService()`.
    private let identityFactory: (() -> IdentityService)?

    /// Builds the CloudKit-backed sealing service. Injectable ONLY so tests can drive the real
    /// `SealedBackupService` over a mock record database and assert what the EXPORT half actually
    /// writes — the half that decides what reaches iCloud, and therefore the half the empty-store
    /// clobber guard has to be proven on. Production leaves it nil.
    private let serviceFactory: ((IdentityService) -> SealedBackupService)?

    /// Reads the storage preferences (sync, the per-payload switches, the deferral flags). Injectable
    /// ONLY so tests can drive the deferred re-upload and the escrow adopt with chosen switches instead
    /// of the device's real preferences keychain; production leaves it nil and reads
    /// `StoragePreferencesStore.currentPreferences()`.
    private let preferencesProvider: (() -> StoragePreferences)?

    /// The cycle-record funnel the period backup pages and merges into. Injectable ONLY so tests can
    /// point it at an isolated sealed store; production leaves it nil and builds one on the shared
    /// store per call (the intimacy pattern). Either way the coordinator installs the host's
    /// visibility gate and mutation hook on it (`resolvedPeriodRecordStore`).
    private let periodRecordStore: CycleRecordStore?

    /// This install's period-backup writer tag. Injectable ONLY so tests can play two iPhones over one
    /// in-memory cloud; production leaves it nil and reads ``PeriodBackupWriterTag/current()``.
    private let writerTagProvider: (() -> String?)?

    init(
        host: any SealedBackupContext,
        identityFactory: (() -> IdentityService)? = nil,
        serviceFactory: ((IdentityService) -> SealedBackupService)? = nil,
        preferencesProvider: (() -> StoragePreferences)? = nil,
        periodRecordStore: CycleRecordStore? = nil,
        writerTagProvider: (() -> String?)? = nil
    ) {
        self.host = host
        self.identityFactory = identityFactory
        self.serviceFactory = serviceFactory
        self.preferencesProvider = preferencesProvider
        self.periodRecordStore = periodRecordStore
        self.writerTagProvider = writerTagProvider
    }

    /// The storage preferences as they are right now.
    private func currentPreferences() -> StoragePreferences {
        preferencesProvider?() ?? StoragePreferencesStore.currentPreferences()
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
    /// The launch/auto path requires a genuinely unused device (`.freshInstall`). The targeted paths
    /// (the Private settle, an un-hide, the user's Retry) cannot use that gate at all: by then the day
    /// blob has long since synced down, so `isFreshInstallForRestore` is permanently false and the
    /// journal or intimacy backup would be unrestorable forever — defeating the point of having it.
    ///
    /// `.payloadStoreOnly` drops only the WHOLE-DEVICE freshness check and keeps the per-payload store
    /// check, which is the invariant that actually protects the payload: a restore writes into nothing
    /// but that payload's sealed store, so an empty (and never-diverged) store means there is nothing
    /// to clobber however much unrelated data the device holds. The period backup's v2 merge restore
    /// uses neither scope, and the retired `.sensitiveNotes` payload is restored under NEITHER (see
    /// ``retireSensitiveNotesBackupIfNeeded(backupMayExist:)``).
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
        let identity = identityFactory?() ?? IdentityService()
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

    /// How many journal narratives this device holds, counted without decrypting anything. A count
    /// error fails CLOSED at 0 — "unknown" must never read as "something to back up".
    ///
    /// A row count is what the export SIZES its chunk set from — it is deliberately NOT the re-upload
    /// guard, because a count cannot see whether the current content key can actually open those rows
    /// (see ``mayReuploadFromLocalStore(_:journalRepository:intimacyStore:)``).
    func journalNarrativeCount(repository: JournalNarrativeRepository? = nil) -> Int {
        ((try? (repository ?? JournalNarrativeRepository()).narrativeCount())) ?? 0
    }

    /// How many intimacy logs this device holds, counted without decrypting anything. Fails CLOSED at 0,
    /// like the other two counts, and sizes the export's chunk set. Ungated by visibility on purpose —
    /// it decrypts nothing, and a hidden store must never read as "empty" anywhere downstream.
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
        store.attachVisibilityGate { [weak self] in self?.host.isIntimacyTrackingVisible ?? false }
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
    /// It proves **exportability**, not row existence: it opens ONE row under the key the export would
    /// page with. A row count alone would be a false guarantee, because the pagers `compactMap` away
    /// every row they cannot decrypt — so a store full of rows sealed under a key this device no longer
    /// holds counts as "has data" and then exports as nothing. Journal is where that is real rather
    /// than theoretical: entries written before a lock was configured are sealed under the DEVICE
    /// journal key, and only the recent window is re-keyed when a lock is set up, so a lock-configured
    /// device can genuinely hold journal rows this content key cannot open. A nil content key therefore
    /// also answers false (nothing is exportable while locked), which routes the caller into the
    /// per-payload deferral rather than into a destructive empty write.
    ///
    /// Intimacy additionally requires visibility: while hidden the reconcile is a silent no-op, so
    /// calling it would log a false "reconciled" while the cloud chunk stayed sealed to the old key —
    /// and the gated pager throws rather than paging empty, which this check must not provoke.
    ///
    /// Fails CLOSED on any throw: "unknown" reads as "do not re-upload".
    ///
    /// - Note: Deliberately scoped to the two new payloads. `.periodData` keeps its pre-existing,
    ///   subtly different guard (it records a re-upload deferral when hidden rather than merely
    ///   skipping), so folding it in here would silently change behavior this phase is not meant to
    ///   touch. The retired `.sensitiveNotes` answers false: nothing may ever be re-uploaded for it.
    func mayReuploadFromLocalStore(
        _ payloadType: SealedBackupPayloadType,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil
    ) -> Bool {
        switch payloadType {
        case .sensitiveNotes:
            return false
        case .periodData:
            return true
        case .journalNarratives:
            guard let key = host.sealedBackupContentKey else { return false }
            let repository = journalRepository ?? JournalNarrativeRepository()
            return ((try? repository.narratives(offset: 0, limit: 1, contentKey: key))?.isEmpty == false)
        case .intimacyLogs:
            guard host.isIntimacyTrackingVisible, let key = host.sealedBackupContentKey else { return false }
            let store = resolvedIntimacyStore(intimacyStore)
            return ((try? store.backupPage(offset: 0, limit: 1, contentKey: key))?.isEmpty == false)
        }
    }

    private func makeSealedBackupService(identity: IdentityService) -> SealedBackupService {
        serviceFactory?(identity)
            ?? SealedBackupService(cloudDataService: CloudKitDataService(), identityService: identity)
    }

    /// Seals + uploads (or deletes) the encrypted CloudKit backup for a payload. Returns whether it
    /// succeeded; callers should only persist the "on" preference when this returns `true`.
    ///
    /// An enable that cannot seal RIGHT NOW — locked content key, hidden surface, or a local store this
    /// device has not restored into yet — is a **deferral, not a failure**: it returns `true` (so the
    /// preference sticks and the intent is honored), records a per-payload re-upload deferral the
    /// Privacy & Data banner surfaces, and is retried at the next `.privateHub` unlock / un-hide /
    /// launch. Returning false there would make every one of these toggles a silently-reverting switch
    /// with no path that ever works, because they all live in Settings — reached from Home, where the
    /// hub is always re-locked.
    ///
    /// The injected repository/store are for tests only: they let the EXPORT half be driven against an
    /// isolated sealed store, which is the half that decides what actually reaches iCloud.
    ///
    /// - Note: deliberately NOT `@discardableResult` (Power-of-10 R7): this is a success/failure
    ///   signal, and every caller has to decide what a `false` means for it.
    func setSealedBackupEnabled(
        _ enabled: Bool,
        payloadType: SealedBackupPayloadType,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil
    ) async -> Bool {
        // The RETIRED payload is never sealed again (owner decision 2026-09-23: the Tier-2 memories it
        // carried stay on the device). Refused BEFORE `makeIdentity(.forSealing)`, which could mint an
        // escrow key for an upload that must not happen. Disabling it still runs below: that is the
        // delete, and "delete everything" depends on it.
        guard !(enabled && payloadType == .sensitiveNotes) else {
            FernletAuditLog.log("sealedBackup.retiredPayloadEnableRefused", context: ["payload": payloadType.rawValue])
            return false
        }
        // Enabling SEALS (needs an escrow key — minted lazily here if absent, WS-1); disabling only
        // DELETES the chunk set (no escrow key needed).
        guard let prepared = makeIdentity(escrowMode: enabled ? .forSealing : .none) else {
            FernletAuditLog.log("sealedBackup.notProvisioned", context: ["payload": payloadType.rawValue])
            return false
        }
        let service = makeSealedBackupService(identity: prepared.identity)
        // Whether a period export left nothing owed: false when a cycle record changed while it ran
        // (§9.10, I29), so the re-upload flag stays set and the next Cycle settle exports again.
        var periodExportClean = true
        do {
            switch (payloadType, enabled) {
            case (.periodData, true):
                periodExportClean = try await reconcilePeriodBackup(using: service)
            case (.journalNarratives, true):
                try await reconcileJournalBackup(using: service, repository: journalRepository)
            case (.intimacyLogs, true):
                try await reconcileIntimacyBackup(using: service, store: intimacyStore)
            // Disabling any payload is the same operation: delete the whole chunk set. It needs no
            // content key and no visibility, which is what keeps "turn it off" available while locked
            // and while the surface is hidden. The retired `.sensitiveNotes` can only ever arrive here
            // as that delete — its enable was refused at the top.
            case (.sensitiveNotes, _), (.periodData, false), (.journalNarratives, false), (.intimacyLogs, false):
                try await service.reconcile(Data(), payloadType: payloadType, enabled: false)
            }
            FernletAuditLog.log("sealedBackup.reconciled", context: [
                "payload": payloadType.rawValue, "enabled": enabled ? "true" : "false"
            ])
            // A pending re-upload deferral is discharged by ANY successful reconcile of that payload
            // that actually touched the cloud chunk: an enable that really paged the store, or a
            // disable that deleted the backup outright. Cleared here, at the one seam every caller
            // funnels through (the Privacy & Data toggle, the adopt flow, the un-hide trigger,
            // delete-all), rather than per-caller.
            //
            // The visibility term is the exception that makes it honest: a HIDDEN period reconcile is a
            // silent no-op, so it must NOT clear an obligation it did not discharge. (The hidden
            // intimacy enable throws `.surfaceHidden` rather than returning silently, so it never
            // reaches here at all.)
            // The period export adds one more term: a cycle record that changed while it ran is not
            // in the set it wrote, so the re-upload stays owed (§9.10 "Dirty re-export").
            if !enabled || payloadType != .periodData || (host.isPeriodTrackingVisible && periodExportClean) {
                host.recordSealedBackupReuploadDeferred(false, payloadType: payloadType)
            }
            // The chunk set is gone, so an app-lock reset's owner hold has no pre-reset copy of this
            // payload left to keep, and the uploads it held may run again (review N-1).
            if !enabled { host.recordSealedBackupCloudCopyDeleted(payloadType) }
            // Nothing is held against another iPhone's set once this payload's set is deleted.
            if !enabled, payloadType == .periodData { host.recordPeriodBackupExportState(.clear) }
            return true
        } catch let wiring as SealedBackupWiringError where enabled && wiring != .storeNotEmpty {
            // The paged payloads are all sealed under the Private tab's content key, which is only live
            // while THAT tab holds the unlock (`FernletLockScope.privateHub`) — and these toggles live
            // in Settings, which is reached from Home, by which point the hub has re-locked. Refusing
            // here would make "turn on encrypted <payload> backup" a silently-reverting toggle with no
            // path that ever works. The same is true of the other two refusals the export can raise:
            // a store whose rows this key cannot open (`.locked`), and a store that is empty because
            // this device has not restored yet (`.emptyLocalStore`, where exporting would REPLACE the
            // cloud copy with an empty chunk set).
            //
            // So honor the intent and DEFER: the preference sticks, the Privacy & Data banner surfaces
            // the pending re-upload, and the seal runs at the next `.privateHub` unlock, the next
            // un-hide, or the next launch — each of which re-checks `mayReuploadFromLocalStore`, so a
            // deferral never discharges into a destructive empty write. Success clears the flag through
            // the normal path above. Deliberately NOT extended to the disable case — disabling deletes
            // the cloud chunk set and needs neither content key nor visibility, so it can never land
            // here.
            host.recordSealedBackupReuploadDeferred(true, payloadType: payloadType)
            FernletAuditLog.log("sealedBackup.sealDeferred", context: [
                "payload": payloadType.rawValue,
                "reason": String(describing: wiring)
            ])
            return true
        } catch {
            FernletAuditLog.log("sealedBackup.reconcileFailed", context: ["payload": payloadType.rawValue])
            return false
        }
    }

    /// Runs a deferred re-upload of `payloadType` once its store is reachable and exportable again.
    /// Called when the Private tab unlocks (the content key becomes available), when intimacy is
    /// un-hidden, and — with the same guards — from the launch pass. Idempotent and a no-op unless a
    /// deferral is actually outstanding.
    ///
    /// The non-empty/exportable-store guard is load-bearing: re-sealing pages the LOCAL store and
    /// rewrites the whole chunk set, so re-uploading from an empty one would overwrite the cloud backup
    /// with a single empty chunk — destroying the history the deferral exists to preserve. When the
    /// guard skips, the deferral flag is deliberately LEFT SET so it self-heals on the launch after a
    /// real restore.
    /// - Note: returns `Void` rather than a discardable `Bool` (Power-of-10 R7). The old Bool
    ///   conflated "nothing was outstanding" with "the re-upload ran and FAILED", and every caller
    ///   dropped it; the recovery for a real failure lives inside `setSealedBackupEnabled` (the
    ///   deferral flag stays set and `sealedBackup.reconcileFailed` is audited), so there is nothing
    ///   for a caller to decide.
    func retryDeferredReuploadIfNeeded(
        payloadType: SealedBackupPayloadType,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil
    ) async {
        let prefs = currentPreferences()
        guard prefs.iCloudSyncEnabled else { return }
        switch payloadType {
        case .sensitiveNotes:
            // RETIRED: never re-uploaded, so there is no deferral to discharge.
            return
        case .periodData:
            // The v2 export guards itself (E1–E4, `reconcilePeriodBackup`); this only skips the
            // identity and network work where it could never run: no Private tab key, or hidden.
            guard prefs.sealedBackupPeriodEnabled,
                  prefs.sealedBackupPeriodReuploadDeferred,
                  host.isPeriodTrackingVisible,
                  host.sealedBackupContentKey != nil else { return }
        case .journalNarratives:
            guard prefs.sealedBackupJournalEnabled,
                  prefs.sealedBackupJournalReuploadDeferred,
                  mayReuploadFromLocalStore(.journalNarratives, journalRepository: journalRepository) else { return }
        case .intimacyLogs:
            guard prefs.sealedBackupIntimacyEnabled,
                  prefs.sealedBackupIntimacyReuploadDeferred,
                  mayReuploadFromLocalStore(.intimacyLogs, intimacyStore: intimacyStore) else { return }
        }
        // After an app-lock reset the cloud copy is the owner's pre-reset history, and the local store
        // holds only what was written since. Re-sealing now would REPLACE that history with the
        // post-reset store, so every re-upload that reaches here — the Private tab's settle, the launch
        // follow-through, the intimacy un-hide, and the Retry pass's follow-through alike — waits for
        // the hold to be released. The deferral flag stays set, so it runs once it is (design §5.3).
        // Only while that copy is still there: a payload that was off at the reset, or whose backup has
        // been deleted since, has nothing to keep and uploads as usual (review N-1).
        guard !reuploadHeldForOwner(payloadType, site: "deferredRetry") else { return }
        if await !setSealedBackupEnabled(
            true,
            payloadType: payloadType,
            journalRepository: journalRepository,
            intimacyStore: intimacyStore
        ) {
            // The deferral flag is left set by the failing path, so the next launch/unlock retries it;
            // name the failed discharge so the audit trail does not imply it was cleared.
            FernletAuditLog.log("sealedBackup.deferredReuploadRetryFailed", context: [
                "payload": payloadType.rawValue
            ])
        }
    }

    /// The period-specific spelling of ``retryDeferredReuploadIfNeeded(payloadType:journalRepository:intimacyStore:)``,
    /// kept because the lock-state observer and the `FernletStore` wrapper name it directly.
    func retryDeferredPeriodReuploadIfNeeded() async {
        await retryDeferredReuploadIfNeeded(payloadType: .periodData)
    }

    /// The retirement sweep for the `.sensitiveNotes` payload (owner decision 2026-09-23: "Tier 2
    /// sensitive notes shouldn't be backed up to iCloud at all"). That payload sealed exactly the
    /// Tier-2 behavioral memories. It is never sealed or restored again; a copy an earlier build
    /// uploaded is deleted HERE — the whole chunk set, by record name, so the sweep needs no escrow key
    /// and provisions nothing.
    ///
    /// Quiet and idempotent by design: no banner and no prompt, only the audit trail. A copy that is
    /// already gone is a successful no-op. A failed delete (offline, signed out) tells the host
    /// nothing, so the persisted marker stays set and the next pass retries — as does "delete
    /// everything", which reads the same marker. Only a delete that landed reaches
    /// `SealedBackupContext.recordRetiredSealedBackupDeleted(_:)`, whose clearing of the marker is what
    /// stops later launches from calling CloudKit for it at all.
    ///
    /// - Parameter backupMayExist: the persisted marker,
    ///   `StoragePreferences.sealedBackupSensitiveNotesEnabled` — since the retirement it means "this
    ///   install uploaded one and has not yet confirmed its delete". Passed in rather than read live so
    ///   the sweep is unit-testable without the device's real preferences keychain.
    func retireSensitiveNotesBackupIfNeeded(backupMayExist: Bool) async {
        guard backupMayExist else { return }
        // No `makeIdentity`: `ensureProvisioned()` can mint a device identity, and a delete by record
        // name needs no key at all.
        let service = makeSealedBackupService(identity: identityFactory?() ?? IdentityService())
        let payload = SealedBackupPayloadType.sensitiveNotes
        do {
            try await service.reconcile(Data(), payloadType: payload, enabled: false)
        } catch {
            FernletAuditLog.log("sealedBackup.retiredPayloadDeleteFailed", context: ["payload": payload.rawValue])
            return
        }
        FernletAuditLog.log("sealedBackup.retiredPayloadDeleted", context: ["payload": payload.rawValue])
        host.recordRetiredSealedBackupDeleted(payload)
    }

    /// The period backup's v2 export (period-data design 2026-09-30, §9.10): whole sealed
    /// ``CycleRecord``s, in v2 chunks, over the one account-wide period slot — written only when every
    /// guard holds, in this order:
    /// - **G5** visible. Hidden is a silent no-op (`setSealedBackupEnabled` then leaves the deferral
    ///   flag alone; hiding is never destructive).
    /// - **E4** the Private tab's key is live at the start of the pass (`.locked` otherwise).
    /// - **E1** this install's period restore is resolved (``PeriodBackupLedger/isRestoreResolved``):
    ///   a fresh install never writes over the cloud copy before pulling it.
    /// - **E2** the set in iCloud, if any, is the one this install last wrote or merged (or, once, a v1
    ///   set at this device's own generation) — the compare-and-swap (`periodExportFloor`).
    /// - **E3** a full pre-pass decrypts every record once BEFORE the first write; any dead record
    ///   refuses (named), any undecided one defers. The chunks are then built from the pre-pass's id
    ///   snapshot, so a page can never shift under a concurrent edit.
    /// The set is minted above the cloud head's generation, its head carries this install's writer
    /// tag, and the pair is recorded as accepted after the write.
    ///
    /// - Returns: Whether the export was CLEAN — no cycle record changed while it ran. False keeps the
    ///   re-upload owed (I29). Also false for the hidden no-op.
    private func reconcilePeriodBackup(using service: SealedBackupService) async throws -> Bool {
        guard host.isPeriodTrackingVisible else { return false }
        guard let key = host.sealedBackupContentKey else { throw SealedBackupWiringError.locked }
        guard host.periodBackupLedger.isRestoreResolved else {
            FernletAuditLog.log("sealedBackup.periodExportWaitsForRestore")
            throw SealedBackupWiringError.periodRestorePending
        }
        let floor = try await periodExportFloor(using: service)
        let mutationsBefore = host.periodBackupMutationCount
        let plan = try periodExportPlan(contentKey: key)
        let generation = try await service.reconcileChunked(
            payloadType: .periodData,
            chunkCount: plan.chunkCount,
            generationFloor: floor,
            chunk: plan.chunk
        )
        host.periodBackupLedger.recordAcceptedHead(PeriodBackupHead(writer: plan.writer, generation: generation))
        host.recordPeriodBackupExportState(.clear)
        let clean = host.periodBackupMutationCount == mutationsBefore
        FernletAuditLog.log("sealedBackup.periodExported", context: [
            "records": String(plan.snapshotCount), "clean": clean ? "true" : "false"
        ])
        return clean
    }

    /// E2, the compare-and-swap (§9.10, R2-F4): reads ONLY the cloud head and allows the export when
    /// there is none, when its `(writer, generation)` is ``PeriodBackupLedger/acceptedHead``, or —
    /// the one-time seed for this update — when it is a v1 set at exactly this device's own
    /// high-water generation (this device's own last write). Anything else is another set: refused as
    /// `.periodHeldByAnotherDevice`, named for Privacy & Data, nothing written. A head that will not
    /// open refuses with its restore-status classification (today's needs-attention copy).
    ///
    /// - Returns: The head's generation (the floor the new set is minted above), or 0 with no head.
    private func periodExportFloor(using service: SealedBackupService) async throws -> Int64 {
        let fetched: (plaintext: Data, generation: Int64)?
        let head: PeriodBackupHead?
        do {
            fetched = try await service.fetchHead(payloadType: .periodData)
            head = try fetched.map { try PeriodBackupFormat.head(ofChunk: $0.plaintext, generation: $0.generation) }
        } catch let error where error is SealedBackupError || error is PeriodBackupFormatError || error is DecodingError {
            recordRestoreOutcome(classifyRestoreFailure(error, payloadType: .periodData), payloadType: .periodData)
            throw error
        }
        guard let head else { return 0 }
        let isOwnV1Write = head.writer == PeriodBackupHead.v1Writer
            && head.generation == service.lastSeenGeneration(for: .periodData)
        guard head == host.periodBackupLedger.acceptedHead || isOwnV1Write else {
            host.recordPeriodBackupExportState(.heldByAnotherDevice(head))
            FernletAuditLog.log("sealedBackup.periodExportHeldByAnotherDevice")
            throw SealedBackupWiringError.periodHeldByAnotherDevice
        }
        return head.generation
    }

    /// What one v2 export writes, fixed by the E3 pre-pass before the first chunk is sealed.
    private struct PeriodExportPlan {
        /// This install's writer tag, stamped on the head.
        let writer: String
        /// How many ids the pre-pass snapshot holds (the head's `total`).
        let snapshotCount: Int
        /// How many chunks the set has (at least one: an empty store still writes its head).
        let chunkCount: Int
        /// Seals chunk `index`'s plaintext (called by `reconcileChunked`, suffix chunks first).
        let chunk: (Int) throws -> Data
    }

    /// E3 (§9.10, R2-F12): the keyless id snapshot and ONE decrypt of every record before any write.
    /// A dead record refuses the export (named in Privacy & Data); an undecided one, or no writer tag,
    /// defers it. Each chunk is then fetched by its slice of the snapshot — a record deleted
    /// mid-export is simply absent from its chunk, one added mid-export waits for the next export
    /// (its mutation re-marked the backup owed) — and a chunk whose rows stop opening mid-export
    /// throws before the head is written.
    private func periodExportPlan(contentKey key: SymmetricKey) throws -> PeriodExportPlan {
        let store = resolvedPeriodRecordStore()
        let prePass = try store.backupPrePass(contentKey: key)
        guard prePass.deadIDs.isEmpty else {
            host.recordPeriodBackupExportState(.unopenableEntries(prePass.deadIDs.count))
            FernletAuditLog.log("sealedBackup.periodExportRefusedUnopenable", context: ["dead": String(prePass.deadIDs.count)])
            throw SealedBackupWiringError.periodEntriesUnopenable
        }
        guard prePass.transientCount == 0, let writer = writerTagProvider?() ?? PeriodBackupWriterTag.current() else {
            FernletAuditLog.log("sealedBackup.periodExportUndecided")
            throw SealedBackupWiringError.periodExportUndecided
        }
        let ids = prePass.snapshotIDs
        let size = Self.periodBackupChunkSize
        let total = ids.count
        return PeriodExportPlan(
            writer: writer,
            snapshotCount: total,
            chunkCount: max(1, (total + size - 1) / size),
            chunk: { index in
                let slice = Array(ids[min(index * size, total)..<min((index + 1) * size, total)])
                let page = try store.backupChunk(ids: slice, contentKey: key)
                guard page.isFullyOpen else { throw SealedBackupWiringError.periodExportUndecided }
                return try PeriodBackupFormat.encodeChunk(index: index, records: page.records, writer: writer, total: total)
            }
        )
    }

    /// The gated cycle-record funnel the period backup works through — injected (tests) or a fresh
    /// one on the shared store — with the host's visibility gate and mutation hook installed, so the
    /// restore's merge marks the backup owed like every other write (§6.2, §9.10).
    private func resolvedPeriodRecordStore(_ injected: CycleRecordStore? = nil) -> CycleRecordStore {
        let store = injected ?? periodRecordStore ?? CycleRecordStore()
        store.attachVisibilityGate { [weak self] in self?.host.isPeriodTrackingVisible ?? false }
        store.attachMutationHook { [weak self] in self?.host.markPeriodBackupDirtyIfEnabled() }
        return store
    }

    /// Seals + uploads the journal backup one bounded chunk at a time (the v1 export shape the period
    /// backup used before v2: page the store, refuse an empty or unopenable one).
    ///
    /// **No visibility gate**, unlike period and intimacy: journaling has no hide switch — it is a
    /// core surface, always visible — so there is no gate to consult and adding a fake one would only
    /// invent a state nothing can reach.
    ///
    /// Requires an unlocked content key. This is the same `journalContentKey` the journal columns are
    /// sealed under while a lock is configured; a no-lock install seals under the device journal key
    /// instead, which this coordinator deliberately cannot see, so no-lock users cannot enable the
    /// journal backup at all (an honest, documented limit — see `Docs/Verifiability.md` §6.2).
    ///
    /// A lock-CONFIGURED device can still hold journal rows this key cannot open: entries written
    /// before the lock existed were sealed under the device journal key, and only the recent window is
    /// re-keyed when the lock is configured. Those rows are counted by `narrativeCount()` but dropped
    /// by the pager, so the export refuses outright (`.locked`) rather than shipping a chunk set that
    /// silently omits them — and audits any residual shortfall it does export.
    private func reconcileJournalBackup(
        using service: SealedBackupService,
        repository: JournalNarrativeRepository? = nil
    ) async throws {
        guard let key = host.sealedBackupContentKey else { throw SealedBackupWiringError.locked }
        let repository = repository ?? JournalNarrativeRepository()
        let pageSize = Self.periodBackupChunkSize
        let total = try repository.narrativeCount()
        // EMPTY-STORE CLOBBER guard, at the seam so no caller can bypass it. `reconcileChunked` writes
        // a head record even for a count of 0, so an export from a store this device has not restored
        // into yet REPLACES the good cloud copy with a single empty chunk. Probing one row also proves
        // the rows are OPENABLE under this key — a count alone does not, because the pager skips rows
        // it cannot decrypt, so a device-key-sealed history would size a chunk set it then fills with
        // nothing. Both refusals are deferrals: the caller keeps the preference on and retries.
        //
        // Deliberately NOT conditioned on whether a cloud chunk set already exists: an empty local
        // store cannot tell "first-ever enable, nothing to back up" from "not restored yet", and asking
        // the transport would only distinguish them when the cloud copy is already there — which is
        // exactly the case where writing is unrecoverable. So the empty store ALWAYS skips. The cost is
        // that a genuinely empty journal defers until the user writes something (a pending banner line,
        // then a normal upload); the alternative cost is a destroyed backup.
        if try repository.narratives(offset: 0, limit: 1, contentKey: key).isEmpty {
            guard total == 0 else {
                FernletAuditLog.log("sealedBackup.journalExportRefusedUnopenableRows", context: [
                    "counted": String(total)
                ])
                throw SealedBackupWiringError.locked
            }
            FernletAuditLog.log("sealedBackup.journalExportDeferredEmptyStore")
            throw SealedBackupWiringError.emptyLocalStore
        }
        // Always at least one chunk so an empty (but enabled) backup still writes a head record.
        let chunkCount = max(1, (total + pageSize - 1) / pageSize)
        var exported = 0
        try await service.reconcileChunked(payloadType: .journalNarratives, chunkCount: chunkCount) { index in
            let page = try repository.narratives(offset: index * pageSize, limit: pageSize, contentKey: key)
            exported += page.count
            return try JSONEncoder().encode(page)
        }
        // The chunk set was sized from a count that never decrypts, so a row the key cannot open is
        // paged away silently. Say so on the audit trail rather than letting a partial backup read as a
        // clean `sealedBackup.reconciled`.
        if exported < total {
            FernletAuditLog.log("sealedBackup.journalPartialExport", context: [
                "counted": String(total), "exported": String(exported)
            ])
        }
    }

    /// Seals + uploads the intimacy backup one bounded chunk at a time, in the journal export's shape,
    /// with the hard visibility gate the period backup also honors.
    ///
    /// Pages the ENTIRE log store through plaintext, so it honors the hard visibility gate. While
    /// hidden it uploads NOTHING and deliberately does not flip the pref: turning
    /// `sealedBackupIntimacyEnabled` off DELETES the encrypted backup from iCloud, which would make
    /// *hiding* destructive. The pref and the cloud record are left exactly as they are, and hidden
    /// must never be allowed to read as "empty" anywhere downstream.
    ///
    /// Unlike period's silent hidden no-op it raises `.surfaceHidden`, so the caller records a
    /// re-upload deferral instead of logging a "reconciled" that never happened — the obligation is
    /// then discharged by the un-hide settle.
    private func reconcileIntimacyBackup(
        using service: SealedBackupService,
        store: IntimacyLogStore? = nil
    ) async throws {
        guard host.isIntimacyTrackingVisible else {
            FernletAuditLog.log("sealedBackup.intimacyReconcileSkippedHidden")
            throw SealedBackupWiringError.surfaceHidden
        }
        guard let key = host.sealedBackupContentKey else { throw SealedBackupWiringError.locked }
        let store = resolvedIntimacyStore(store)
        let pageSize = Self.periodBackupChunkSize
        let total = try store.backupLogCount()
        // Same two-part refusal as the journal export, and for the same reason: a head record is
        // written even for a count of 0, so exporting an empty or unopenable store would replace the
        // cloud copy with nothing. Only corruption can make an intimacy row unopenable (these rows only
        // ever carry one key), but the invariant holds uniformly rather than per-payload.
        if try store.backupPage(offset: 0, limit: 1, contentKey: key).isEmpty {
            guard total == 0 else {
                FernletAuditLog.log("sealedBackup.intimacyExportRefusedUnopenableRows", context: [
                    "counted": String(total)
                ])
                throw SealedBackupWiringError.locked
            }
            FernletAuditLog.log("sealedBackup.intimacyExportDeferredEmptyStore")
            throw SealedBackupWiringError.emptyLocalStore
        }
        // Always at least one chunk so an empty (but enabled) backup still writes a head record.
        let chunkCount = max(1, (total + pageSize - 1) / pageSize)
        var exported = 0
        try await service.reconcileChunked(payloadType: .intimacyLogs, chunkCount: chunkCount) { index in
            // `backupPage` re-checks the gate and THROWS if it flipped mid-export, rather than paging
            // empty — which would replace the cloud backup with nothing.
            let page = try store.backupPage(offset: index * pageSize, limit: pageSize, contentKey: key)
            exported += page.count
            return try JSONEncoder().encode(page)
        }
        if exported < total {
            FernletAuditLog.log("sealedBackup.intimacyPartialExport", context: [
                "counted": String(total), "exported": String(exported)
            ])
        }
    }

    /// Called once at launch (after the store is ready), and again from the user's "Retry" action, to
    /// reconcile the escrow key and pull any sealed iCloud backups into the local stores. Apart from
    /// the retired payload's deletion sweep, no-ops unless iCloud sync is on. Best-effort and
    /// non-fatal: failures are surfaced as a retryable status (WS-4), audited, and retried next
    /// launch. Gated by `FERNLET_SKIP_SEALED_RESTORE` so UI tests can opt out — DEBUG-only, so it
    /// cannot be triggered in a shipping binary.
    ///
    /// `userInitiated` marks the user's explicit Retry (as opposed to the ambient launch pass) and lets
    /// every paged payload fall back to its targeted, payload-scoped restore — see below.
    func restoreSealedBackupsIfNeeded(userInitiated: Bool = false) async {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["FERNLET_SKIP_SEALED_RESTORE"] != "1" else { return }
        #endif
        let prefs = currentPreferences()
        // The retired sensitive-notes copy is deleted FIRST and deliberately NOT gated on iCloud sync:
        // a sealed backup was never a sync feature (its switch sat beside the sync switch, and the
        // own-photo route makes the same call), so a user who has since turned sync off may still
        // have a copy up there. It only ever deletes.
        await retireSensitiveNotesBackupIfNeeded(backupMayExist: prefs.sealedBackupSensitiveNotesEnabled)
        guard prefs.iCloudSyncEnabled else { return }
        // Reconcile the escrow key BEFORE restoring so any open() runs under the authoritative key and a
        // cross-device key conflict is surfaced non-silently (WS-3).
        reconcileEscrowKey()
        // PIN the whole-device freshness verdict for the whole pass, BEFORE any arm writes.
        //
        // The arms are not independent: the journal arm's `reinstateJournalEntries` writes day
        // SKELETONS through to the day repository, and a day carrying journals satisfies
        // `hasLoggedContent` — so re-deriving the verdict per payload would let the journal restore's
        // own writeback classify the device as "already in use" microseconds later and turn the
        // intimacy arm into a silent, terminal `.skippedStoreNotEmpty`. Reordering the arms would only
        // move the poison onto whichever payload is added last. The per-payload store-empty +
        // divergence-latch checks stay LIVE and unconditional below; they are the real no-clobber
        // invariant, and pinning this verdict weakens none of them.
        let deviceWasFresh = isFreshInstallForRestore()
        // An app-lock reset is waiting for the device owner (design §5.3, Q14): the AMBIENT pass
        // restores nothing. The user's own Retry still does. The re-upload follow-through below is
        // held too, on every pass, for each payload whose pre-reset cloud copy is still there
        // (`retryDeferredReuploadIfNeeded`): the local stores hold only what was written since the
        // reset, and exporting them would replace that copy.
        let heldForOwner = !userInitiated && host.sealedBackupRestoreAwaitsOwner
        if heldForOwner { FernletAuditLog.log("sealedBackup.restoreHeldForOwner", context: ["site": "launch"]) }
        // No sensitive-notes arm: that payload is retired and never restored (the sweep above deletes
        // it). Each arm below records its own outcome on the host inside the call — that recording IS
        // the user-visible signal and the Retry affordance — so the pass fires and forgets.
        // The period arm is the v2 merge restore (period-data design 2026-09-30, §9.10): no freshness
        // gate (a merge never clobbers), gated instead by the resolved marker, the owner hold, G5 and
        // the live Private tab key — so at launch, with Private closed, it waits for the Cycle settle
        // without any network work and without raising a banner.
        if prefs.sealedBackupPeriodEnabled && host.isPeriodTrackingVisible {
            _ = await restorePeriodBackup(initiatedByUser: userInitiated)
        }
        // Journal has no visibility gate (journaling is always visible), so the pref alone decides.
        // A targeted fallback on an explicit Retry: without it, an in-use device can only
        // ever answer `.skippedStoreNotEmpty`, which is neither `needsAttention` nor `isRetryable`, so
        // the journal backup would be permanently unrestorable with no user-visible signal.
        if !heldForOwner, prefs.sealedBackupJournalEnabled {
            let outcome = await restoreSealedBackupOutcome(
                payloadType: .journalNarratives, freshInstallOverride: deviceWasFresh
            )
            if userInitiated, outcome == .skippedStoreNotEmpty {
                // Outcome recorded on the host by the call; the banner reads it from there.
                _ = await restoreJournalBackupTargeted(initiatedByUser: true)
            }
        }
        // Intimacy mirrors the period half's G5 gate: this decrypts intimate notes off CloudKit and
        // WRITES them into the local sealed store, so a read-side gate alone would miss it. Skipping
        // only DEFERS — the backup stays in iCloud and restores if the user un-hides (the un-hide
        // settle in `FernletStore.setIntimacyTrackingVisible` is what makes that true).
        if !heldForOwner, prefs.sealedBackupIntimacyEnabled && host.isIntimacyTrackingVisible {
            let outcome = await restoreSealedBackupOutcome(
                payloadType: .intimacyLogs, freshInstallOverride: deviceWasFresh
            )
            if userInitiated, outcome == .skippedStoreNotEmpty {
                // Outcome recorded on the host by the call; the banner reads it from there.
                _ = await restoreIntimacyBackupTargeted(initiatedByUser: true)
            }
        }
        // RESTORE-BEFORE-REUPLOAD: every payload above is pulled down BEFORE the re-upload
        // follow-through below runs, so a device that has not restored yet can never overwrite a good
        // cloud backup with its own empty store. For period that order is structural, not just
        // sequential: the v2 export refuses until this install's restore has resolved (E1).
        await retryDeferredReuploadIfNeeded(payloadType: .periodData)
        // The same follow-through for the two Phase-3 payloads, whose deferrals are recorded by the
        // locked/hidden/empty-store enable and by the escrow adopt. Each re-checks
        // `mayReuploadFromLocalStore`, so a not-yet-restored store leaves the flag set rather than
        // exporting an empty chunk set over the cloud copy.
        await retryDeferredReuploadIfNeeded(payloadType: .journalNarratives)
        await retryDeferredReuploadIfNeeded(payloadType: .intimacyLogs)
    }

    /// Reconciles the backup-escrow key across iCloud Keychain (WS-3) and records any conflict so the UI
    /// can surface a non-silent choice. Adoption of a synced key and promotion of a local key are
    /// non-destructive and proceed; only a divergent synced-vs-local key is held back for user resolution.
    private func reconcileEscrowKey() {
        let identity = identityFactory?() ?? IdentityService()
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
    ///
    /// - Note: deliberately NOT `@discardableResult` (Power-of-10 R7). A `false` means the conflict
    ///   banner the user just acted on is still there, and only the caller can say so.
    ///
    /// After an app-lock reset (``SealedBackupContext/sealedBackupKeepsPreResetCopy(of:)``) the key is
    /// still adopted, but no payload whose pre-reset copy the hold keeps is re-sealed: the local stores
    /// hold only what was written since the reset, and re-sealing them would replace the owner's
    /// pre-reset history in iCloud. Each such payload records a deferral instead, discharged once the
    /// hold is released (review C-U2-R1); the others re-seal as usual (review N-1).
    ///
    /// The injected journal repository and intimacy store are for tests only, as for
    /// ``setSealedBackupEnabled(_:payloadType:journalRepository:intimacyStore:)``.
    func adoptSyncedEscrowAndReupload(
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil
    ) async -> Bool {
        let identity = identityFactory?() ?? IdentityService()
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
        let remaining = deferReuploadsHeldForOwner(currentPreferences())
        await reuploadAfterEscrowAdopt(remaining, journalRepository: journalRepository, intimacyStore: intimacyStore)
        return true
    }

    /// The escrow adopt's re-uploads that an app-lock reset holds for the device owner: every enabled
    /// payload whose pre-reset iCloud copy the hold keeps records a deferral (surfaced by Privacy &
    /// Data, discharged once the hold is released) instead of being re-sealed now with the post-reset
    /// store. Returns `prefs` with those payloads switched off: what the adopt may re-seal now.
    private func deferReuploadsHeldForOwner(_ prefs: StoragePreferences) -> StoragePreferences {
        var remaining = prefs
        if prefs.sealedBackupPeriodEnabled, reuploadHeldForOwner(.periodData, site: "escrowAdopt") {
            host.recordSealedBackupReuploadDeferred(true, payloadType: .periodData)
            remaining.sealedBackupPeriodEnabled = false
        }
        if prefs.sealedBackupJournalEnabled, reuploadHeldForOwner(.journalNarratives, site: "escrowAdopt") {
            host.recordSealedBackupReuploadDeferred(true, payloadType: .journalNarratives)
            remaining.sealedBackupJournalEnabled = false
        }
        if prefs.sealedBackupIntimacyEnabled, reuploadHeldForOwner(.intimacyLogs, site: "escrowAdopt") {
            host.recordSealedBackupReuploadDeferred(true, payloadType: .intimacyLogs)
            remaining.sealedBackupIntimacyEnabled = false
        }
        return remaining
    }

    /// Re-seals + re-uploads whatever the user has enabled so the cloud copy matches the key the escrow
    /// adopt just switched to. Never the retired `.sensitiveNotes`: it is not re-sealed under any key,
    /// and a surviving copy is deleted by the launch pass's retirement sweep, which needs no key at all.
    private func reuploadAfterEscrowAdopt(
        _ prefs: StoragePreferences,
        journalRepository: JournalNarrativeRepository?,
        intimacyStore: IntimacyLogStore?
    ) async {
        if prefs.sealedBackupPeriodEnabled {
            if host.isPeriodTrackingVisible {
                // Success clears the deferral inside setSealedBackupEnabled. A FAILED re-seal leaves the
                // cloud chunk sealed to the key we just replaced, so record it as still-deferred (the
                // banner surfaces it; retried at next launch) instead of silently claiming it done.
                if await !setSealedBackupEnabled(true, payloadType: .periodData) {
                    host.recordSealedBackupReuploadDeferred(true, payloadType: .periodData)
                }
            } else {
                // G5: period is hidden, so reconcilePeriodBackup is a silent no-op. Routing through
                // setSealedBackupEnabled here would log a FALSE "reconciled" while the cloud period chunk
                // stays sealed to the OLD escrow key we just replaced — a later restore of the user's OWN
                // backup then fails terminally with keyAgreementIdentityMismatch. Re-sealing requires
                // paging the (gated) cycle records, which we won't do while hidden. Record the deferral
                // honestly so it's surfaced (re-upload after un-hiding) rather than silently claimed done.
                host.recordSealedBackupReuploadDeferred(true, payloadType: .periodData)
                FernletAuditLog.log("sealedBackup.escrowAdoptPeriodDeferredHidden")
            }
        }
        // EMPTY-STORE CLOBBER guard, the journal/intimacy exports' own. `reconcileChunked`
        // writes a head record even for count 0, so re-sealing from a store this device has not
        // restored into yet would replace the good cloud backup with a single empty chunk. An empty
        // store here means "not restored yet", NOT "nothing to back up" — the ambient restore above is
        // fresh-install-only. Skipping leaves the cloud chunk sealed to the key we just replaced; that
        // is recoverable (re-upload from a device that has the data, or after this one restores),
        // whereas an empty overwrite is not.
        //
        // "Recoverable" is only true if something REMEMBERS the skip, so each one records a persisted
        // per-payload deferral (surfaced by the Privacy & Data banner, retried at the next launch /
        // unlock / un-hide) rather than an audit line nothing reads. Without it the surviving cloud
        // chunks stay sealed to the escrow key this adopt just replaced, and a later restore fails
        // TERMINALLY with `keyAgreementIdentityMismatch` → `.notRecognized`.
        if prefs.sealedBackupJournalEnabled {
            if mayReuploadFromLocalStore(.journalNarratives, journalRepository: journalRepository) {
                // Mirror the period branch above: a FAILED re-seal leaves the cloud chunk sealed to
                // the key we just replaced, so record the deferral instead of dropping the failure —
                // the banner surfaces it and the launch/unlock retry discharges it.
                if await !setSealedBackupEnabled(
                    true, payloadType: .journalNarratives, journalRepository: journalRepository
                ) {
                    host.recordSealedBackupReuploadDeferred(true, payloadType: .journalNarratives)
                }
            } else {
                host.recordSealedBackupReuploadDeferred(true, payloadType: .journalNarratives)
                FernletAuditLog.log("sealedBackup.escrowAdoptJournalSkippedEmptyStore")
            }
        }
        if prefs.sealedBackupIntimacyEnabled {
            if mayReuploadFromLocalStore(.intimacyLogs, intimacyStore: intimacyStore) {
                // Same as the journal branch: a failed re-seal is recorded as still-deferred rather
                // than silently claimed done.
                if await !setSealedBackupEnabled(true, payloadType: .intimacyLogs, intimacyStore: intimacyStore) {
                    host.recordSealedBackupReuploadDeferred(true, payloadType: .intimacyLogs)
                }
            } else {
                host.recordSealedBackupReuploadDeferred(true, payloadType: .intimacyLogs)
                FernletAuditLog.log("sealedBackup.escrowAdoptIntimacySkipped", context: [
                    // The two skips are different states and the log has to say which: hidden is
                    // discharged by an un-hide, an empty store by a restore.
                    "reason": host.isIntimacyTrackingVisible ? "emptyStore" : "hidden"
                ])
            }
        }
    }

    /// Fetches/decrypts/writes a single sealed-backup payload into the local stores, returning a rich
    /// outcome AND recording it on the host so the UI can show a non-silent, retryable status (WS-4).
    ///
    /// `freshInstallOverride` pins the whole-device freshness verdict the launch pass computed before
    /// any arm ran; `nil` (the default) evaluates it live, which is what a standalone caller wants.
    func restoreSealedBackupOutcome(
        payloadType: SealedBackupPayloadType,
        freshInstallOverride: Bool? = nil
    ) async -> SealedBackupRestoreOutcome {
        let outcome = await performRestore(payloadType: payloadType, freshInstallOverride: freshInstallOverride)
        recordRestoreOutcome(outcome, payloadType: payloadType)
        return outcome
    }

    /// The period restore (period-data design 2026-09-30, §9.10): an id-keyed MERGE of the cloud set
    /// into the sealed cycle records — inserts ids absent here, completes present ones by the record
    /// merge rule, replaces dead ones, never deletes an openable local record and never overwrites a
    /// newer block. Both set shapes restore (v1 narratives, v2 records).
    ///
    /// Runs while this install's restore is unresolved (``PeriodBackupLedger/isRestoreResolved``) —
    /// which is what stops a stale cloud copy from resurrecting entries deleted here — and only with
    /// the Private tab's key live, period tracking visible and (for an ambient caller) no app-lock
    /// reset waiting for the device owner. Every refusal is answered before any network work and
    /// recorded as no status: the next Cycle settle IS the retry. A restore that lands for good
    /// (`.restored`, `.nothingToRestore`) resolves the marker and records the set as accepted;
    /// `.notRecognized` and `.rolledBack` stay unresolved with their needs-attention status.
    ///
    /// - Parameter initiatedByUser: The user's own Retry — never held for the device owner (Privacy &
    ///   Data, where it lives, is behind a fresh device-owner check). It does NOT reopen a resolved
    ///   restore: that is ``restorePeriodBackupHere()``, behind its confirmation.
    func restorePeriodBackup(initiatedByUser: Bool = false) async -> SealedBackupRestoreOutcome {
        if heldForOwner(site: "period", initiatedByUser: initiatedByUser) { return .deferredTransient }
        // Fail closed at the decrypt seam: this decrypts cycle history off CloudKit and seals it in.
        guard host.isPeriodTrackingVisible else {
            FernletAuditLog.log("sealedBackup.periodRestoreSkippedHidden")
            return .deferredTransient
        }
        guard host.sealedBackupContentKey != nil else {
            FernletAuditLog.log("sealedBackup.periodRestoreWaitsForPrivate")
            return .deferredLocked
        }
        guard !host.periodBackupLedger.isRestoreResolved else { return .skippedStoreNotEmpty }
        let outcome = await performPeriodRestore()
        recordRestoreOutcome(outcome, payloadType: .periodData)
        return outcome
    }

    /// The Cycle section's settle (and the un-hide settle) for the period backup, in its one order:
    /// restore, then export (§9.10). A no-op without the Private tab's key or while hidden. With
    /// nothing to restore from on this install (iCloud sync off, or the period backup off) the restore
    /// is marked resolved instead — there is no cloud copy this install could ever pull ambiently, and
    /// turning the backup on later meets the compare-and-swap rather than a stale restore.
    func settlePeriodBackup() async {
        guard host.sealedBackupContentKey != nil, host.isPeriodTrackingVisible else { return }
        let prefs = currentPreferences()
        guard prefs.iCloudSyncEnabled, prefs.sealedBackupPeriodEnabled else {
            if !host.periodBackupLedger.isRestoreResolved {
                host.periodBackupLedger.markRestoreResolved()
                FernletAuditLog.log("sealedBackup.periodRestoreResolvedNothingToRestoreFrom")
            }
            return
        }
        _ = await restorePeriodBackup()
        await retryDeferredReuploadIfNeeded(payloadType: .periodData)
    }

    /// Privacy & Data's "Restore it here" (§9.10, §10.6), behind its confirmation that entries deleted
    /// on this iPhone since that backup may come back: reopens this install's period restore, so the
    /// next Cycle settle (or this call, when the Private tab is open) merges the cloud set in — after
    /// which the compare-and-swap accepts that set and this iPhone backs up over it again.
    func restorePeriodBackupHere() async {
        host.periodBackupLedger.reopenRestore()
        host.recordPeriodBackupExportState(.clear)
        FernletAuditLog.log("sealedBackup.periodRestoreReopenedByUser")
        await settlePeriodBackup()
    }

    /// Privacy & Data's "Replace it with this iPhone's history" (§9.10, §10.6), behind its
    /// confirmation: accepts exactly the set the export refused, `head`, as the one this install may
    /// replace, and records the upload as owed — so the next Cycle settle (or this call, when the
    /// Private tab is open) exports over it, still behind E1, E3, E4 and the generation floor. If the
    /// other iPhone has written a NEWER set since, the compare-and-swap refuses again and asks again:
    /// the user agreed to replace the set they were shown, not one they never saw.
    ///
    /// - Parameter head: The set named in ``PeriodBackupExportState/heldByAnotherDevice(_:)``.
    func replacePeriodBackupWithThisIPhone(_ head: PeriodBackupHead) async {
        host.periodBackupLedger.recordAcceptedHead(head)
        host.recordPeriodBackupExportState(.clear)
        host.recordSealedBackupReuploadDeferred(true, payloadType: .periodData)
        FernletAuditLog.log("sealedBackup.periodReplaceChosenByUser")
        await settlePeriodBackup()
    }

    /// Privacy & Data's "Restore" after an app-lock reset (design §5.3, Q14), behind the screen's fresh
    /// device-owner check: releases the ambient-restore hold, so each payload's restore runs at its
    /// next Private settle (the period one now, when the Private tab is open). Each payload's
    /// re-uploads stay held until its own restore has landed, so a pre-reset copy is never replaced
    /// before it was pulled back (``SealedBackupContext/recordSealedBackupPreResetCopySettled(_:)``).
    func releaseRestoreHoldForOwner() async {
        host.releaseSealedBackupRestoreHold()
        FernletAuditLog.log("sealedBackup.restoreHoldReleasedByOwner")
        await settlePeriodBackup()
    }

    /// The network half of the period restore: fetch and open the whole set (all-or-nothing, rollback
    /// checked), merge it in, and on a set that merged — changed or not — record it as the accepted
    /// head and resolve the marker. `.nothingToRestore` with no set resolves too (there is nothing to
    /// pull). Never mints an escrow key (WS-1).
    private func performPeriodRestore() async -> SealedBackupRestoreOutcome {
        // Fail closed BEFORE the network decrypt, whoever the caller: hidden or keyless, nothing of the
        // cycle history is fetched or opened (the merge's own gate would only refuse the write).
        guard host.isPeriodTrackingVisible else { return .deferredTransient }
        guard host.sealedBackupContentKey != nil else { return .deferredLocked }
        FernletAuditLog.log("sealedBackup.restoreAttempt", context: ["payload": SealedBackupPayloadType.periodData.rawValue])
        guard let prepared = makeIdentity(escrowMode: .forOpening) else { return .deferredTransient }
        guard prepared.escrowReady else { return .deferredKeyNotSynced }
        let service = makeSealedBackupService(identity: prepared.identity)
        do {
            guard let set = try await service.restoreChunkSet(payloadType: .periodData), let first = set.chunks.first else {
                host.periodBackupLedger.markRestoreResolved()
                return .nothingToRestore
            }
            let head = try PeriodBackupFormat.head(ofChunk: first, generation: set.generation)
            let changed = try applyRestoredChunks(set.chunks, payloadType: .periodData)
            host.periodBackupLedger.recordAcceptedHead(head)
            host.periodBackupLedger.markRestoreResolved()
            FernletAuditLog.log("sealedBackup.periodRestoreMerged", context: ["changed": String(changed)])
            return changed > 0 ? .restored(changed) : .nothingToRestore
        } catch {
            return classifyRestoreFailure(error, payloadType: .periodData)
        }
    }

    /// Records a restore outcome on the host (the Privacy & Data status) — and, when the outcome means
    /// the cloud set was pulled or does not exist, tells the owner hold that this payload has no
    /// pre-reset copy left to keep from a re-upload.
    private func recordRestoreOutcome(_ outcome: SealedBackupRestoreOutcome, payloadType: SealedBackupPayloadType) {
        host.recordSealedBackupRestoreOutcome(outcome, payloadType: payloadType)
        if outcome.didRestore || outcome == .nothingToRestore {
            host.recordSealedBackupPreResetCopySettled(payloadType)
        }
    }

    /// Targeted journal-only restore — the compensating path for the fresh-install-only launch pass.
    ///
    /// Without it the journal backup is unrestorable the moment the day blob syncs down (which, with
    /// iCloud sync on, is within minutes of the first launch): `isFreshInstallForRestore` is then
    /// permanently false, so the launch arm can only answer `.skippedStoreNotEmpty` — an outcome that is
    /// neither `needsAttention` nor `isRetryable`, i.e. silent AND terminal. Driven by the explicit user
    /// actions: tapping Retry on the restore banner, and the `.privateHub` unlock (the one moment the
    /// content key that decrypts the restored rows is actually live).
    ///
    /// `.payloadStoreOnly` drops ONLY the whole-device freshness gate. The per-payload store-empty check
    /// and the one-way divergence latch below still run, and they are what make it no-clobber: a user
    /// who DELETED their journal is never re-populated from the stale-by-construction cloud copy.
    ///
    /// `initiatedByUser` marks the user's Retry: the Private tab's settle is ambient and is held for the
    /// device owner after a reset (``heldForOwner(site:initiatedByUser:)``).
    func restoreJournalBackupTargeted(
        journalRepository: JournalNarrativeRepository? = nil,
        initiatedByUser: Bool = false
    ) async -> SealedBackupRestoreOutcome {
        if heldForOwner(site: "journal", initiatedByUser: initiatedByUser) { return .deferredTransient }
        // Resolved once so the latch check and the write consult the SAME store.
        let repository = journalRepository ?? JournalNarrativeRepository()
        guard !repository.hasEverStoredNarrative else {
            FernletAuditLog.log("sealedBackup.targetedJournalRestoreSkippedDeviceDiverged")
            return .skippedStoreNotEmpty
        }
        let outcome = await performRestore(
            payloadType: .journalNarratives,
            scope: .payloadStoreOnly,
            journalRepository: repository
        )
        FernletAuditLog.log("sealedBackup.targetedJournalRestoreAttempted")
        recordRestoreOutcome(outcome, payloadType: .journalNarratives)
        return outcome
    }

    /// Targeted intimacy-only restore — the compensating path for the fresh-install-only launch pass,
    /// and the thing that makes the launch arm's "hidden only DEFERS, it restores when you un-hide"
    /// comment true. Driven by the un-hide settle, the `.privateHub` unlock, and the Retry button.
    ///
    /// Fail-closed at the decrypt seam first: while hidden this writes nothing and reports
    /// `.deferredTransient` (retryable — un-hiding IS the retry), which also stops a caller from
    /// treating a gated, unpageable store as restored and re-uploading over the cloud copy. Then the
    /// one-way divergence latch, so logs the user deliberately DELETED are never resurrected.
    ///
    /// `initiatedByUser` as for ``restoreJournalBackupTargeted(journalRepository:initiatedByUser:)``.
    func restoreIntimacyBackupTargeted(
        intimacyStore: IntimacyLogStore? = nil,
        initiatedByUser: Bool = false
    ) async -> SealedBackupRestoreOutcome {
        if heldForOwner(site: "intimacy", initiatedByUser: initiatedByUser) { return .deferredTransient }
        guard host.isIntimacyTrackingVisible else {
            FernletAuditLog.log("sealedBackup.targetedIntimacyRestoreSkippedHidden")
            return .deferredTransient
        }
        let store = resolvedIntimacyStore(intimacyStore)
        guard !store.hasEverStoredLog else {
            FernletAuditLog.log("sealedBackup.targetedIntimacyRestoreSkippedDeviceDiverged")
            return .skippedStoreNotEmpty
        }
        let outcome = await performRestore(
            payloadType: .intimacyLogs,
            scope: .payloadStoreOnly,
            intimacyStore: store
        )
        FernletAuditLog.log("sealedBackup.targetedIntimacyRestoreAttempted")
        recordRestoreOutcome(outcome, payloadType: .intimacyLogs)
        return outcome
    }

    /// Whether an AMBIENT targeted restore must stand down because an app-lock reset is waiting for
    /// the device owner (design §5.3, Q14). Answered as `.deferredTransient` by the callers — NOT
    /// recorded as a status (there is nothing to retry from a banner), and retryable.
    ///
    /// The hold alone does not keep the cloud copy intact: a caller that re-uploads after the restore
    /// would replace the pre-reset history with the post-reset store. The un-hide settles stop on the
    /// retryable outcome; every other re-upload — the Private tab's settle, the launch follow-through
    /// and the escrow adopt — is held by ``reuploadHeldForOwner(_:site:)`` (review C-U2-R1) for each
    /// payload whose pre-reset copy is still there (review N-1).
    private func heldForOwner(site: String, initiatedByUser: Bool) -> Bool {
        guard !initiatedByUser, host.sealedBackupRestoreAwaitsOwner else { return false }
        FernletAuditLog.log("sealedBackup.restoreHeldForOwner", context: ["site": site])
        return true
    }

    /// Whether a re-upload of `payloadType` must wait because an app-lock reset is waiting for the
    /// device owner and that payload's pre-reset cloud copy is still there: exporting now would replace
    /// it with whatever was written since the reset. Held uniformly — ambient or not — until the hold
    /// is released; the caller leaves (or records) the per-payload deferral so the re-upload runs
    /// afterwards. A payload that was off at the reset, or whose backup was deleted since, is not held
    /// (review N-1): there is no pre-reset copy of it to keep.
    private func reuploadHeldForOwner(_ payloadType: SealedBackupPayloadType, site: String) -> Bool {
        guard host.sealedBackupKeepsPreResetCopy(of: payloadType) else { return false }
        FernletAuditLog.log("sealedBackup.reuploadHeldForOwner", context: [
            "payload": payloadType.rawValue, "site": site
        ])
        return true
    }

    /// Bool-returning restore kept for the restore tests and the `FernletStore` wrapper. Does NOT record
    /// a UI status (the launch/retry path uses `restoreSealedBackupOutcome` for that); returns whether
    /// records were actually written.
    ///
    /// - Note: deliberately NOT `@discardableResult` (Power-of-10 R7). This wrapper records nothing
    ///   on the host, so the return value is the ONLY place its outcome exists.
    func restoreSealedBackup(payloadType: SealedBackupPayloadType) async -> Bool {
        await performRestore(payloadType: payloadType).didRestore
    }

    /// The actual restore. Splits every termination into a distinct outcome (WS-4): never marks restore
    /// "done" on a recoverable failure. The escrow key is loaded WITHOUT minting (WS-1) — its absence is
    /// reported as `.deferredKeyNotSynced` (retry), never a fabricated identity.
    private func performRestore(
        payloadType: SealedBackupPayloadType,
        scope: RestoreScope = .freshInstall,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil,
        freshInstallOverride: Bool? = nil
    ) async -> SealedBackupRestoreOutcome {
        // The RETIRED payload is never restored (owner decision 2026-09-23): answered before any
        // store, identity or network work. Benign by design — there is nothing for the user to act on.
        guard payloadType != .sensitiveNotes else {
            FernletAuditLog.log("sealedBackup.restoreSkippedRetiredPayload", context: ["payload": payloadType.rawValue])
            return .nothingToRestore
        }
        // Period is the v2 merge restore: no store-empty or freshness gate applies (a merge never
        // clobbers). Its ambient gates (resolved marker, owner hold) live in `restorePeriodBackup`.
        guard payloadType != .periodData else { return await performPeriodRestore() }
        FernletAuditLog.log("sealedBackup.restoreAttempt", context: ["payload": payloadType.rawValue])
        // Resolved once and passed to BOTH the pre-network gate and the write, so they consult the same
        // store (an injected repository is how the un-hide tests exercise this without a real device store).
        let journalRepository = journalRepository ?? JournalNarrativeRepository()
        let intimacyStore = resolvedIntimacyStore(intimacyStore)
        // Outer no-clobber check: this duplicates the AUTHORITATIVE gate inside applyRestoredChunks (which
        // re-checks under the same store before writing), but is kept deliberately as a pre-NETWORK
        // short-circuit — it skips the CloudKit fetch + decrypt entirely when the local store already holds
        // data. The inner check remains the source of truth against any TOCTOU between here and the write.
        guard isEmptyStoreForRestore(
            payloadType: payloadType,
            journalRepository: journalRepository,
            intimacyStore: intimacyStore,
            scope: scope,
            freshInstallOverride: freshInstallOverride
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
                journalRepository: journalRepository,
                intimacyStore: intimacyStore,
                scope: scope,
                // The inner authoritative gate must re-check against the SAME verdict this call was
                // made under, or it would re-derive a freshness value the pass deliberately pinned.
                freshInstallOverride: freshInstallOverride
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
        case SealedBackupWiringError.locked, FernletLockError.locked:
            // The second spelling is the cycle-record funnel's: its restore merge throws it when it is
            // handed no key, exactly as the other payloads' write points throw the first.
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
        cycleRecordStore: CycleRecordStore? = nil,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil,
        scope: RestoreScope = .freshInstall,
        freshInstallOverride: Bool? = nil
    ) throws -> Int {
        try applyRestoredChunks(
            [plaintext],
            payloadType: payloadType,
            cycleRecordStore: cycleRecordStore,
            journalRepository: journalRepository,
            intimacyStore: intimacyStore,
            scope: scope,
            freshInstallOverride: freshInstallOverride
        )
    }

    /// Decodes the decrypted chunks of a sealed-backup payload and writes them into the local stores,
    /// returning the number of records written. Separated from the CloudKit fetch so it is
    /// unit-testable without iCloud. The retired sensitive-notes payload writes NOTHING and returns 0
    /// before any store is touched. Every live payload re-seals under the Private tab's key, so it
    /// requires that key and throws `SealedBackupWiringError.locked` otherwise.
    ///
    /// **Period** (v2, period-data design 2026-09-30, §9.10) is an id-keyed MERGE into the sealed cycle
    /// records through the gated funnel's `restoreMerging` — one atomic save, which inserts absent
    /// ids, completes present ones, replaces dead ones, and never deletes or regresses an openable
    /// record — so it has no store-empty precondition: it returns how many records it inserted,
    /// merged or replaced (0 when the cloud set added nothing). Both chunk shapes decode (v1
    /// narratives, v2 records; ``PeriodBackupFormat``). Hidden throws (retryable).
    ///
    /// **Journal and intimacy** keep the no-clobber precondition: the store must be empty for
    /// `payloadType` (see `isEmptyStoreForRestore`). This is enforced here — the lowest write point
    /// every caller funnels through — so the invariant holds for every caller (defense in depth) and
    /// throws `SealedBackupWiringError.storeNotEmpty` otherwise; it also closes the window where the
    /// store gains data during `restore`'s `await`.
    @discardableResult
    func applyRestoredChunks(
        _ chunks: [Data],
        payloadType: SealedBackupPayloadType,
        cycleRecordStore: CycleRecordStore? = nil,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil,
        scope: RestoreScope = .freshInstall,
        freshInstallOverride: Bool? = nil
    ) throws -> Int {
        // A restore whose surrounding Task was cancelled must not write. The concrete race: the un-hide
        // settle Task is suspended in the CloudKit chunk fetch when "delete everything" runs; the funnel
        // cancels that Task (a live writer, like the debounced save and the guided run), and this check —
        // at the single write point every restore funnels through — makes the cancellation actually stop
        // the write instead of racing it. Cheap no-op in any uncancelled context, including the
        // synchronous test callers. (`CancellationError` classifies as `.deferredTransient` upstream.)
        try Task.checkCancellation()
        // The RETIRED payload's plaintext is never decoded, let alone written back — this is the one
        // write point every restore path funnels through, so the refusal here covers them all.
        guard payloadType != .sensitiveNotes else {
            FernletAuditLog.log("sealedBackup.applySkippedRetiredPayload", context: ["payload": payloadType.rawValue])
            return 0
        }
        // The period merge never clobbers, so it has no store-empty gate (see the doc comment).
        guard payloadType != .periodData else {
            return try applyRestoredPeriodChunks(chunks, store: resolvedPeriodRecordStore(cycleRecordStore))
        }
        // Constructed here rather than as default arguments: both are MainActor-isolated, and
        // default-argument expressions evaluate in a nonisolated context. Resolved BEFORE the guard so
        // the no-clobber check and the inserts consult the SAME store.
        let journalRepository = journalRepository ?? JournalNarrativeRepository()
        let intimacyStore = resolvedIntimacyStore(intimacyStore)
        // No-clobber guard: refuse to overwrite/insert into a store that already holds user data,
        // regardless of how this method was reached.
        guard isEmptyStoreForRestore(
            payloadType: payloadType,
            journalRepository: journalRepository,
            intimacyStore: intimacyStore,
            scope: scope,
            freshInstallOverride: freshInstallOverride
        ) else {
            FernletAuditLog.log("sealedBackup.applySkippedNonEmpty", context: ["payload": payloadType.rawValue])
            throw SealedBackupWiringError.storeNotEmpty
        }
        switch payloadType {
        case .sensitiveNotes, .periodData:
            // Unreachable — both answered above, before the no-clobber gate. Kept for exhaustiveness.
            return 0
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
            //
            // NOTE (pass-level freshness): this arm deliberately WRITES DAY ROWS, and a day carrying
            // journals satisfies `FernletDay.hasLoggedContent` — so from here on the device no longer
            // looks like a fresh install. That is precisely why `restoreSealedBackupsIfNeeded` pins the
            // whole-device freshness verdict once, before any arm runs, and threads it through as
            // `freshInstallOverride`: without the pin, this write would silently and permanently
            // sabotage the gate of every payload restored after journal.
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

    /// The period half of ``applyRestoredChunks(_:payloadType:cycleRecordStore:journalRepository:intimacyStore:scope:freshInstallOverride:)``:
    /// decodes every chunk (v1 or v2) and merges the whole set in ONE `restoreMerging` save — all or
    /// nothing, so a failed restore leaves the records exactly as they were and is retried at the next
    /// settle. (The whole set is held in memory: the chunking bounds the EXPORT seal, and one personal
    /// cycle history is small enough that one transaction is the right trade for atomicity; the funnel
    /// bounds a batch at `CycleRecordRepository.maxStoredRecords`.)
    ///
    /// - Returns: How many records the merge inserted, merged or replaced.
    private func applyRestoredPeriodChunks(_ chunks: [Data], store: CycleRecordStore) throws -> Int {
        guard let key = host.sealedBackupContentKey else { throw SealedBackupWiringError.locked }
        var records: [CycleRecord] = []
        for chunk in chunks {  // R2: bounded by the restored set (≤ SealedBackupService.maxRestoreChunkCount).
            records.append(contentsOf: try PeriodBackupFormat.records(fromChunk: chunk))
        }
        let result = try store.restoreMerging(records, contentKey: key)
        return result.inserted + result.merged + result.replaced
    }

    /// Whether the local store is empty enough that restoring `payloadType` cannot clobber or
    /// duplicate existing user data — the journal and intimacy gate. At `.freshInstall` scope this
    /// requires a fresh install AND the payload's own store empty and never diverged; at
    /// `.payloadStoreOnly` scope only the per-payload store check runs. The retired sensitive-notes
    /// payload is never restorable at all. Period data never reaches this gate: its v2 restore is a
    /// merge that cannot clobber, gated instead by its resolved marker (period-data design
    /// 2026-09-30, §9.10); it answers false here, fail closed, should a caller ever ask.
    ///
    /// `freshInstallOverride` is the launch pass's pinned whole-device verdict, computed once BEFORE any
    /// arm ran. It exists because the arms are not independent: the journal arm writes day skeletons
    /// (`host.reinstateJournalEntries`) that make the device look "in use" to every arm evaluated after
    /// it. `nil` re-derives the verdict live, which is right for standalone callers.
    private func isEmptyStoreForRestore(
        payloadType: SealedBackupPayloadType,
        journalRepository: JournalNarrativeRepository,
        intimacyStore: IntimacyLogStore,
        scope: RestoreScope,
        freshInstallOverride: Bool? = nil
    ) -> Bool {
        if scope == .freshInstall, !(freshInstallOverride ?? isFreshInstallForRestore()) { return false }
        switch payloadType {
        case .sensitiveNotes, .periodData:
            // Retired, or never gated here (see above). Fails closed.
            return false
        case .journalNarratives:
            // A cheap count (no decryption) so a re-restore cannot duplicate the history, AND the
            // one-way divergence latch so an empty-but-DIVERGED store — the user deleted their entries
            // — is never re-populated from the stale-by-construction cloud copy. Deleting a journal
            // entry drops the narrative row without reconciling the backup.
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
