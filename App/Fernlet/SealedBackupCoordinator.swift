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
    /// The Sealed backup v2 per-payload bookkeeping: the restore markers, the accepted heads and the
    /// observed foreign heads (design 2026-09-30, §4.3).
    var sealedBackupBookkeeping: SealedBackupBookkeeping { get }
    /// How many mutations of `payload`'s sealed store this process has seen — the ONE "did it move"
    /// witness every store instance moves through ``markSealedBackupDirty(_:)`` (§4.4, R2-F8). An
    /// export clears the owed upload only when it did not move while the export ran.
    func sealedBackupMutationEpoch(_ payload: SealedBackupPayloadType) -> Int
    /// Every sealed-store mutation hook (§4.4): moves the payload's mutation epoch and — unless
    /// "Delete everything" is running (R2-F10) — records its upload as owed. No keychain read, never
    /// the enabled switch (R2-F14).
    func markSealedBackupDirty(_ payload: SealedBackupPayloadType)
    /// Whether `payload`'s upload is owed right now (its persisted re-upload flag).
    func isSealedBackupReuploadOwed(_ payload: SealedBackupPayloadType) -> Bool
    /// Records the v2 engine's status for `payload` (nil drops it) — what Privacy & Data reads.
    func recordSealedBackupV2Status(_ status: SealedBackupV2Status?, payloadType: SealedBackupPayloadType)
    /// The Sealed backup work epoch — moved by "Delete everything"'s first leg and the app-lock reset
    /// funnel. A v2 pass captures it at its start and stops at its next gate once it moved (§4.7).
    var sealedBackupWorkEpoch: Int { get }
    /// Whether "Delete everything" is running: the engine drops new work and every gate fails.
    var deleteAllInProgress: Bool { get }
    /// Whether a duress session is active: no pass decrypts or writes for any payload (§4.7).
    var duressSessionActive: Bool { get }
    /// Whether a cross-device escrow-key conflict awaits the user's choice (§5.5's
    /// `keyAgreementIdentityMismatch` row defers to its banner then).
    var sealedBackupEscrowConflict: Bool { get }
    /// The storage preferences as the app holds them in memory (the gates read sync and the backup
    /// switches from here, never the keychain, §4.2 G4).
    var sealedBackupPreferences: StoragePreferences { get }
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
/// **The period backup runs on the Sealed backup v2 engine** (journal and intimacy Sealed backup v2
/// design 2026-09-30, §3–§5, building on the period design's §9.10): ``engine``, owned here and so by
/// `FernletStore`, runs every period pass on one serial worker behind its gates — an id-keyed MERGE
/// restore while this install's restore is unresolved, then an export behind E1 (restore first), E2
/// (writer-first compare-and-swap against the set in iCloud), E3 (every chunk decrypted and sealed in
/// memory before the first save) and the commit (set-scoped suffix chunks, then the head, then a
/// verify). The period entry points below are façades over it. The journal and intimacy backups keep
/// the v1 model until their own units: an empty-store-only restore and a re-upload on enable, retry,
/// adopt and un-hide.
@MainActor
final class SealedBackupCoordinator {
    /// Local preconditions a sealed-backup operation can fail on, before or without touching CloudKit.
    ///
    /// Thrown by the journal/intimacy seal/restore paths and mapped onto a retryable
    /// ``SealedBackupRestoreOutcome`` by `classifyRestoreFailure`.
    enum SealedBackupWiringError: Error, Equatable {
        /// Sealing/restore attempted while the content key is locked.
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
    }

    /// Records per sealed chunk on every paged v1 export (journal, intimacy) — the v2 engine's
    /// ``SealedBackupV2Engine/chunkSize`` too. Bounds the plaintext and ciphertext held in memory
    /// while sealing to ~this many records regardless of how long the history is. One size for every
    /// payload deliberately: journal text is longer per record, but the number only has to keep a chunk
    /// comfortably inside a `CKAsset`, and a single constant is one thing to reason about instead of
    /// three.
    static let periodBackupChunkSize = SealedBackupV2Engine.chunkSize

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
    /// of the app's in-memory preferences; production leaves it nil and reads
    /// ``SealedBackupContext/sealedBackupPreferences``.
    private let preferencesProvider: (() -> StoragePreferences)?

    /// The cycle-record funnel the period backup pages and merges into. Injectable ONLY so tests can
    /// point it at an isolated sealed store; production leaves it nil and builds one on the shared
    /// store. Either way the coordinator installs the host's visibility gate and mutation hook on it
    /// (`resolvedPeriodRecordStore`).
    private let periodRecordStore: CycleRecordStore?

    /// This install's writer tag. Injectable ONLY so tests can play two iPhones over one in-memory
    /// cloud; production leaves it nil and reads ``SealedBackupWriterTag/current()``.
    private let writerTagProvider: (() -> String?)?

    /// The engine's clock (spacing and backoff). Injectable ONLY for the spacing tests.
    private let clock: (() -> Date)?

    /// The engine's background-task assertion. Injectable ONLY so tests need no UIKit app state.
    private let backgroundTasks: (any SealedBackupBackgroundTaskAsserting)?

    /// The Sealed backup v2 engine every period pass runs on (design 2026-09-30, §4.2). Built on first
    /// use over the period adapter; one per coordinator, so one per `FernletStore`.
    private(set) lazy var engine: SealedBackupV2Engine = makeEngine()

    init(
        host: any SealedBackupContext,
        identityFactory: (() -> IdentityService)? = nil,
        serviceFactory: ((IdentityService) -> SealedBackupService)? = nil,
        preferencesProvider: (() -> StoragePreferences)? = nil,
        periodRecordStore: CycleRecordStore? = nil,
        writerTagProvider: (() -> String?)? = nil,
        clock: (() -> Date)? = nil,
        backgroundTasks: (any SealedBackupBackgroundTaskAsserting)? = nil
    ) {
        self.host = host
        self.identityFactory = identityFactory
        self.serviceFactory = serviceFactory
        self.preferencesProvider = preferencesProvider
        self.periodRecordStore = periodRecordStore
        self.writerTagProvider = writerTagProvider
        self.clock = clock
        self.backgroundTasks = backgroundTasks
    }

    /// Builds the engine over the period adapter, with this coordinator's factories.
    private func makeEngine() -> SealedBackupV2Engine {
        let adapters: [SealedBackupPayloadType: any SealedBackupV2Adapter] = [
            .periodData: CycleRecordBackupAdapter(store: resolvedPeriodRecordStore())
        ]
        return SealedBackupV2Engine(
            host: host,
            adapters: adapters,
            identityFactory: { [identityFactory] in identityFactory?() ?? IdentityService() },
            serviceFactory: { [serviceFactory] identity in
                serviceFactory?(identity)
                    ?? SealedBackupService(cloudDataService: CloudKitDataService(), identityService: identity)
            },
            preferences: { [weak self] in self?.currentPreferences() ?? StoragePreferences() },
            writerTag: { [writerTagProvider] in writerTagProvider?() ?? SealedBackupWriterTag.current() },
            now: clock ?? Date.init,
            backgroundTasks: backgroundTasks ?? SealedBackupUIKitBackgroundTasks()
        )
    }

    /// The storage preferences as they are right now.
    private func currentPreferences() -> StoragePreferences {
        preferencesProvider?() ?? host.sealedBackupPreferences
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
    /// The period backup runs on the v2 engine (``engine``): turning it on marks its upload owed and
    /// runs an export pass now if the Private tab is open (else the next hub settle does); turning it
    /// off first STOPS the engine — any pass still uploading stops before its next save — and only
    /// then deletes, so no set is ever written after the delete (review finding on 8f808232). With
    /// `deletingAnySlot` false (the user's own switch) a period slot this install observed as another
    /// iPhone's is KEPT (design 2026-09-30 §9, R2-F3): it is not this iPhone's backup.
    ///
    /// The injected repository/store are for tests only: they let the EXPORT half be driven against an
    /// isolated sealed store, which is the half that decides what actually reaches iCloud.
    ///
    /// - Note: deliberately NOT `@discardableResult` (Power-of-10 R7): this is a success/failure
    ///   signal, and every caller has to decide what a `false` means for it.
    func setSealedBackupEnabled(
        _ enabled: Bool,
        payloadType: SealedBackupPayloadType,
        deletingAnySlot: Bool = true,
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
        if SealedBackupBookkeeping.v2Payloads.contains(payloadType) {
            return enabled
                ? await enableV2Backup(payloadType)
                : await disableV2Backup(payloadType, deletingAnySlot: deletingAnySlot)
        }
        return await setV1BackupEnabled(enabled, payloadType: payloadType, journalRepository: journalRepository, intimacyStore: intimacyStore)
    }

    /// Turning a v2 payload's backup on: the upload is owed, and an export runs now when the Private
    /// tab is open (behind every gate, E1 first). Every outcome but a stop keeps the switch on and
    /// returns true — a deferral, a held slot, even a failed upload (`.failed`: the upload stays owed
    /// and the next hub settle retries it, which Privacy & Data says) — so the switch never snaps back
    /// over something the engine retries anyway. Only a pass a wipe or a turn-off stopped returns false.
    private func enableV2Backup(_ payload: SealedBackupPayloadType) async -> Bool {
        engine.endDisabling(payload, keepOff: false)
        host.markSealedBackupDirty(payload)
        let report = await engine.perform(payload, trigger: .enable, phases: .export)
        FernletAuditLog.log("sealedBackup.reconciled", context: ["payload": payload.rawValue, "enabled": "true"])
        return !report.stopped
    }

    /// Turning a v2 payload's backup off (§9): the engine stops first (``SealedBackupV2Engine/beginDisabling(_:)``
    /// awaits any running pass), then the set is deleted — unless this install observed the slot as
    /// another iPhone's and the user's own switch asked (`deletingAnySlot` false), when the cloud copy
    /// is kept. Either way the owed upload clears; a delete that landed also clears the accepted and
    /// observed heads and tells the owner hold nothing pre-reset is left. A failed delete keeps the
    /// switch on (the caller's) and lets the engine run again.
    private func disableV2Backup(_ payload: SealedBackupPayloadType, deletingAnySlot: Bool) async -> Bool {
        await engine.beginDisabling(payload)
        let keepsForeignSlot = !deletingAnySlot
            && host.sealedBackupBookkeeping.observedHead(payload, installTag: writerTagProvider?() ?? SealedBackupWriterTag.current()) != nil
        if keepsForeignSlot {
            FernletAuditLog.log("sealedBackup.v2.turnedOffKeepingAnotherIPhonesSlot", context: ["payload": payload.rawValue])
        } else {
            let service = makeSealedBackupService(identity: identityFactory?() ?? IdentityService())
            do {
                try await service.reconcile(Data(), payloadType: payload, enabled: false)
            } catch {
                engine.endDisabling(payload, keepOff: false)
                FernletAuditLog.log("sealedBackup.reconcileFailed", context: ["payload": payload.rawValue])
                return false
            }
            host.sealedBackupBookkeeping.clearAcceptedHead(payload)
            host.sealedBackupBookkeeping.clearObservedHead(payload)
            host.recordSealedBackupCloudCopyDeleted(payload)
        }
        engine.endDisabling(payload, keepOff: true)
        host.recordSealedBackupReuploadDeferred(false, payloadType: payload)
        FernletAuditLog.log("sealedBackup.reconciled", context: ["payload": payload.rawValue, "enabled": "false"])
        return true
    }

    /// The v1 payloads' reconcile (journal, intimacy, and the retired notes' delete).
    private func setV1BackupEnabled(
        _ enabled: Bool,
        payloadType: SealedBackupPayloadType,
        journalRepository: JournalNarrativeRepository?,
        intimacyStore: IntimacyLogStore?
    ) async -> Bool {
        // Enabling SEALS (needs an escrow key — minted lazily here if absent, WS-1); disabling only
        // DELETES the chunk set (no escrow key needed).
        guard let prepared = makeIdentity(escrowMode: enabled ? .forSealing : .none) else {
            FernletAuditLog.log("sealedBackup.notProvisioned", context: ["payload": payloadType.rawValue])
            return false
        }
        let service = makeSealedBackupService(identity: prepared.identity)
        do {
            switch (payloadType, enabled) {
            case (.journalNarratives, true):
                try await reconcileJournalBackup(using: service, repository: journalRepository)
            case (.intimacyLogs, true):
                try await reconcileIntimacyBackup(using: service, store: intimacyStore)
            // Disabling any payload is the same operation: delete the whole chunk set. It needs no
            // content key and no visibility, which is what keeps "turn it off" available while locked
            // and while the surface is hidden. The retired `.sensitiveNotes` can only ever arrive here
            // as that delete — its enable was refused at the top. Period is v2 and never arrives here.
            case (.sensitiveNotes, _), (.periodData, _), (.journalNarratives, false), (.intimacyLogs, false):
                try await service.reconcile(Data(), payloadType: payloadType, enabled: false)
            }
            FernletAuditLog.log("sealedBackup.reconciled", context: [
                "payload": payloadType.rawValue, "enabled": enabled ? "true" : "false"
            ])
            // A pending re-upload deferral is discharged by ANY successful reconcile of that payload
            // that actually touched the cloud chunk: an enable that really paged the store, or a
            // disable that deleted the backup outright. (The hidden intimacy enable throws
            // `.surfaceHidden` rather than returning silently, so it never reaches here at all.)
            host.recordSealedBackupReuploadDeferred(false, payloadType: payloadType)
            // The chunk set is gone, so an app-lock reset's owner hold has no pre-reset copy of this
            // payload left to keep, and the uploads it held may run again (review N-1).
            if !enabled { host.recordSealedBackupCloudCopyDeleted(payloadType) }
            return true
        } catch let wiring as SealedBackupWiringError where enabled && wiring != .storeNotEmpty {
            // The paged payloads are all sealed under the Private tab's content key, which is only live
            // while THAT tab holds the unlock — and these toggles live in Settings, reached from Home,
            // by which point the hub has re-locked. So honor the intent and DEFER: the preference
            // sticks, the Privacy & Data banner surfaces the pending re-upload, and the seal runs at the
            // next `.privateHub` unlock, un-hide, or launch — each of which re-checks
            // `mayReuploadFromLocalStore`, so a deferral never discharges into a destructive empty
            // write. Deliberately NOT extended to the disable case — disabling deletes the cloud chunk
            // set and needs neither content key nor visibility, so it can never land here.
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
    /// The non-empty/exportable-store guard is load-bearing for the v1 payloads: re-sealing pages the
    /// LOCAL store and rewrites the whole chunk set, so re-uploading from an empty one would overwrite
    /// the cloud backup with a single empty chunk — destroying the history the deferral exists to
    /// preserve. When the guard skips, the deferral flag is deliberately LEFT SET so it self-heals on
    /// the launch after a real restore. The period backup is v2: its retry is an export pass on the
    /// engine (ambient — it honours the owner hold and E1, and is a no-op with the Private tab closed).
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
            let report = await engine.perform(.periodData, trigger: .retry, phases: .export)
            if report.exportStatus == .failed {
                FernletAuditLog.log("sealedBackup.deferredReuploadRetryFailed", context: ["payload": payloadType.rawValue])
            }
            return
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
    /// kept because the `FernletStore` wrapper names it directly.
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

    /// The gated cycle-record funnel the period backup works through — injected (tests) or a fresh
    /// one on the shared store — with the host's visibility gate and mutation hook installed, so the
    /// restore's merge marks the backup owed like every other write (§6.2; design 2026-09-30 §4.4).
    private func resolvedPeriodRecordStore(_ injected: CycleRecordStore? = nil) -> CycleRecordStore {
        let store = injected ?? periodRecordStore ?? CycleRecordStore()
        store.attachVisibilityGate { [weak self] in self?.host.isPeriodTrackingVisible ?? false }
        store.attachMutationHook { [weak self] in self?.host.markSealedBackupDirty(.periodData) }
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
        // The v2 payloads (period) are not on the launch pass at all: nothing can run with the
        // Private tab closed, so the ambient launch pass never touches them, and the user's Retry asks
        // the engine for an ambient pass (the owner hold and E1 honoured; a no-op while Private is
        // closed — the next hub settle runs it). Design 2026-09-30 §4.5.
        if userInitiated {
            let report = await engine.perform(.periodData, trigger: .retry, phases: .both)
            FernletAuditLog.log("sealedBackup.v2.retryPass", context: [
                "payload": SealedBackupPayloadType.periodData.rawValue, "ran": report.gateFailure == nil ? "true" : "false"
            ])
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
        // cloud backup with its own empty store. The follow-through for the two Phase-3 payloads,
        // whose deferrals are recorded by the locked/hidden/empty-store enable and by the escrow
        // adopt (period is v2: its pass above restores and exports in one order). Each re-checks
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
        // The v2 payloads (period): the adopt marks the upload owed and nothing more (design
        // 2026-09-30 §4.5). The next hub settle exports through E2, which treats a head this install
        // sealed under the key the adopt replaced as its own (its signing key, §5.5) — and the owner
        // hold, a hidden surface and E1 all still apply there, so none of them needs a branch here.
        for payload in SealedBackupBookkeeping.v2Payloads where prefs.isSealedBackupEnabled(for: payload) {
            host.markSealedBackupDirty(payload)
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
        // The v2 engine records what really ran itself; a pass stopped at a gate records nothing.
        if !SealedBackupBookkeeping.v2Payloads.contains(payloadType) { recordRestoreOutcome(outcome, payloadType: payloadType) }
        return outcome
    }

    /// The period restore on its own (design 2026-09-30, §4.2 R): an engine pass of the restore phase
    /// only — an id-keyed MERGE of the cloud set that inserts ids absent here, completes present ones,
    /// replaces dead ones, never deletes an openable record and never overwrites a newer block. Both
    /// set shapes restore (v1 narratives, v2 records).
    ///
    /// Runs while this install's restore is unresolved — which is what stops a stale cloud copy from
    /// resurrecting entries deleted here — behind every gate (sync and the backup on, period tracking
    /// visible, no duress, the Private tab's key live, the store attached) and never while an app-lock
    /// reset's owner hold waits, whoever asks (R1-BR-15: the Retry included). A refusal at a gate is
    /// answered without network work and recorded as no status; a resolved install answers
    /// `.skippedStoreNotEmpty`. A restore that lands (`.restored`, `.nothingToRestore`) resolves the
    /// marker and records the set as accepted.
    ///
    /// - Parameter initiatedByUser: The user's own Retry — an ambient trigger like any other (§4.5).
    func restorePeriodBackup(initiatedByUser: Bool = false) async -> SealedBackupRestoreOutcome {
        let report = await engine.perform(.periodData, trigger: initiatedByUser ? .retry : .hubSettle, phases: .restore)
        if let outcome = report.restoreOutcome { return outcome }
        return report.gateFailure.map(SealedBackupV2Engine.outcome(forGate:)) ?? .deferredTransient
    }

    /// The hub settle for the period backup (and the un-hide settle), in its one order: restore while
    /// unresolved, then export (design 2026-09-30, §4.2) — a pending explicit intent ("Restore it
    /// here", "Replace", …) taking the ambient request's place. A no-op without the Private tab's key,
    /// while hidden, or with iCloud sync or the backup off — and it never marks the restore resolved
    /// because there is nothing to restore from (§4.8 item 13): that is only ever decided by a restore
    /// that ran.
    func settlePeriodBackup() async {
        let report = await engine.perform(.periodData, trigger: .hubSettle, phases: .both)
        if report.exportStatus == .failed {
            FernletAuditLog.log("sealedBackup.v2.settleExportFailed", context: ["payload": SealedBackupPayloadType.periodData.rawValue])
        }
    }

    /// Privacy & Data's "Restore it here" (period design §10.6), behind its confirmation that entries
    /// deleted on this iPhone since that backup may come back: an explicit intent (§4.6) carried out
    /// now when the Private tab is open, else at the next hub settle — a merge of exactly `stamp`, the
    /// set the export named, accepted even below this iPhone's rollback floor (counters are per device
    /// and "Delete everything" zeroes them, review U5-backup-v2-C-U5-2), after which the export
    /// follows and this iPhone takes the slot. It never touches this install's restore marker
    /// (R1-BR-4): one that cannot land returns to the held state with both choices. Still held for the
    /// device owner after an app-lock reset (R1-BR-15).
    ///
    /// - Parameter stamp: The set named in ``PeriodBackupExportState/heldByAnotherDevice(_:)``.
    func restorePeriodBackupHere(_ stamp: SealedBackupHeadStamp) async {
        let intent = SealedBackupTrigger.restoreHere(stamp, ignoringRollback: true)
        engine.recordIntent(intent, for: .periodData)
        FernletAuditLog.log("sealedBackup.periodRestoreHereChosenByUser")
        _ = await engine.perform(.periodData, trigger: intent, phases: .both)
    }

    /// Privacy & Data's "Replace it with this iPhone's history" (period design §10.6), behind its
    /// destructive confirmation: an explicit intent that exports with E1 waived and E2 passing for
    /// exactly `stamp` — if the other iPhone has written another set since, the export is held again
    /// and asks again: the user agreed to replace the set they were shown, not one they never saw.
    ///
    /// - Parameter stamp: The set named in the export state.
    func replacePeriodBackupWithThisIPhone(_ stamp: SealedBackupHeadStamp) async {
        let intent = SealedBackupTrigger.replace(stamp)
        engine.recordIntent(intent, for: .periodData)
        host.markSealedBackupDirty(.periodData)
        FernletAuditLog.log("sealedBackup.periodReplaceChosenByUser")
        _ = await engine.perform(.periodData, trigger: intent, phases: .export)
    }

    /// Privacy & Data's "Start a new backup" for a period set this iPhone cannot open (sealed to another
    /// backup key, or damaged; §4.6, §5.6): an explicit intent that exports with E1 and E2 waived,
    /// minting an escrow key if none is here, and writes over the unopenable set.
    func startNewPeriodBackup() async {
        engine.recordIntent(.startNew, for: .periodData)
        host.markSealedBackupDirty(.periodData)
        FernletAuditLog.log("sealedBackup.periodStartNewChosenByUser")
        _ = await engine.perform(.periodData, trigger: .startNew, phases: .export)
    }

    /// Privacy & Data's "Restore" after an app-lock reset (design §5.3, Q14; 2026-09-30 §4.6), behind
    /// the screen's fresh device-owner check: releases the ambient-restore hold ON THE TAP — safe,
    /// because the reset left the restore unresolved, so E1 still blocks every export until the merge
    /// has run — then asks the engine for the restore. Each payload's re-uploads stay held until its
    /// own restore has landed (``SealedBackupContext/recordSealedBackupPreResetCopySettled(_:)``).
    /// While the hold still keeps the period backup's pre-reset copy, this install's period restore is
    /// reopened too: the owner asked for that copy back, and a marker resolved in the meantime must not
    /// stand between them (review U5-backup-v2-L-U5-R2).
    func releaseRestoreHoldForOwner() async {
        host.releaseSealedBackupRestoreHold()
        if host.sealedBackupKeepsPreResetCopy(of: .periodData) {
            host.sealedBackupBookkeeping.reopenRestore(.periodData)
        }
        FernletAuditLog.log("sealedBackup.restoreHoldReleasedByOwner")
        _ = await engine.perform(.periodData, trigger: .ownerRelease, phases: .both)
    }

    /// The payloads whose pre-reset iCloud copy the owner released for restore but whose restore can
    /// never land on this iPhone: the journal and intimacy restores write only into an empty,
    /// never-diverged store, and this one already holds entries written since the reset (review
    /// U5-backup-v2-C-U5-5 / L-U5-R5). Their re-uploads stay held — nothing replaces the copy
    /// silently — until the user chooses ``replacePreResetCopyWithThisIPhone(_:)`` or turns that
    /// backup off. Never period: its restore is a merge. Empty while the hold still waits for the
    /// owner (the restore has not been asked for). Keyless counts only; decrypts nothing.
    ///
    /// The injected repository and store are for tests only.
    func preResetCopiesBlockedByNewerEntries(
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil
    ) -> Set<SealedBackupPayloadType> {
        guard !host.sealedBackupRestoreAwaitsOwner else { return [] }
        let journal = journalRepository ?? JournalNarrativeRepository()
        let intimacy = resolvedIntimacyStore(intimacyStore)
        let candidates: [SealedBackupPayloadType] = [.journalNarratives, .intimacyLogs]
        return Set(candidates.filter { payload in
            host.sealedBackupKeepsPreResetCopy(of: payload)
                && !isEmptyStoreForRestore(
                    payloadType: payload, journalRepository: journal, intimacyStore: intimacy, scope: .payloadStoreOnly
                )
        })
    }

    /// Privacy & Data's explicit "Replace it with this iPhone's entries" for a payload in
    /// ``preResetCopiesBlockedByNewerEntries(journalRepository:intimacyStore:)``, behind its
    /// destructive confirmation: the owner hold stops keeping that payload's pre-reset copy, and the
    /// re-upload is recorded as owed, so the next Private settle backs this iPhone's entries up over
    /// it. Journal and intimacy only — a period restore is a merge and is never blocked this way.
    ///
    /// - Parameter payload: The journal or intimacy payload the user chose to replace.
    func replacePreResetCopyWithThisIPhone(_ payload: SealedBackupPayloadType) {
        guard payload == .journalNarratives || payload == .intimacyLogs else { return }
        host.recordSealedBackupPreResetCopySettled(payload)
        host.recordSealedBackupReuploadDeferred(true, payloadType: payload)
        FernletAuditLog.log("sealedBackup.preResetCopyReplaceChosenByUser", context: ["payload": payload.rawValue])
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
        // Period is the v2 merge restore on the engine: no store-empty or freshness gate applies (a
        // merge never clobbers); its gates, the resolved marker and the owner hold are the engine's.
        guard payloadType != .periodData else { return await restorePeriodBackup() }
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
    /// **Period** (v2) is an id-keyed MERGE into the sealed cycle records through the gated funnel's
    /// `restoreMerging` — one atomic save, which inserts absent ids, completes present ones, replaces
    /// dead ones, and never deletes or regresses an openable record — so it has no store-empty
    /// precondition: it returns how many records it inserted, merged or replaced (0 when the cloud set
    /// added nothing). Both chunk shapes decode (a v1 `[MenstrualNarrative]` array, a v2
    /// ``SealedBackupV2Envelope``). Hidden throws (retryable). The engine's own restore verifies the
    /// set first (§5.3); this direct path is for the decode-and-merge tests.
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
        let adapter = CycleRecordBackupAdapter(store: store)
        var records: [CycleRecord] = []
        for chunk in chunks {  // R2: bounded by the restored set (≤ SealedBackupService.maxRestoreChunkCount).
            if SealedBackupV2Format.isV1(chunk) {
                records.append(contentsOf: try adapter.decodeV1Chunk(chunk))
            } else {
                records.append(contentsOf: try JSONDecoder().decode(SealedBackupV2Envelope<CycleRecord>.self, from: chunk).records)
            }
        }
        return try adapter.restoreMerging(records, hubKey: key).changedCount
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
