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
    /// Whether every Sealed backup restore must wait because an app-lock reset is waiting for the
    /// device owner (design §5.3, Q14) — whoever asks, Retry and "Restore it here" included
    /// (design 2026-09-30, R1-BR-15); only the owner-checked "Restore Sealed backup" releases it.
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
    /// Whether intimacy tracking is visible (`!duress`, the 16+ age gate and the setting). Same
    /// contract as ``isPeriodTrackingVisible`` and for the same reason: the intimacy backup's export
    /// decrypts the whole log store and its restore writes decrypted logs back, both on ambient paths,
    /// so the hard gate has to be consulted at the decrypt seam rather than in a view.
    ///
    /// The coordinator installs it on the app's one `IntimacyLogStore` when that funnel is handed over
    /// (``SealedBackupCoordinator/attachIntimacyLogStore(_:)``) — the funnel defaults fail-CLOSED and is
    /// a leaf with no access to settings, so somebody has to supply the gate.
    var isIntimacyTrackingVisible: Bool { get }
    /// The ids of the journal entries some day still references — every persisted day's journals, the
    /// in-memory today's and `previousJournals` (design 2026-09-30, §7.1). The journal backup's
    /// snapshot is the sealed ids among these, so an ORPHAN sealed row (no skeleton anywhere: a delete
    /// whose row delete failed, an entry another iPhone deleted with sync on) is never exported and can
    /// never come back through a restore. Keyless; decrypts nothing.
    ///
    /// NIL when the day store's read cannot be trusted to be complete (read-only recovery, a failed
    /// fetch, a day that would not decode — `FernletRepository.loadAllDaysIfComplete()`): every sealed
    /// entry on an unread day would read as an orphan, and the export would publish a truncated set
    /// over the full one exactly when the day store is broken. The snapshot then fails (nothing
    /// written, the upload still owed) — fail closed, review B3 fix round 1.
    var sealedBackupJournalReferencedIDs: Set<UUID>? { get }
    /// Records whether a sealed backup of `payloadType` still owes an upload — the dirty flag every
    /// sealed-store change sets (``markSealedBackupDirty(_:)``), set too when the backup is turned on
    /// or the escrow key adopted, and cleared only by a verified commit (design 2026-09-30, §4.4).
    ///
    /// Per payload: period, journal and intimacy are sealed under the very same `.privateHub` content
    /// key, so each is exported at the next Private visit, and a skip nobody records is a skip nobody
    /// ever retries. Surfaced non-silently (the catch-up line) so the user sees the pending upload.
    /// `.sensitiveNotes` is retired and never seals, so it can never owe a re-upload; implementations
    /// ignore it.
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
    /// Rebuilds the day-blob journal SKELETONS for restored journal entries, so they are actually
    /// visible (design 2026-09-30, §7.4).
    ///
    /// Load-bearing, not cosmetic. The journal UI reads `FernletDay.journals` for the entry list and
    /// hydrates the text by id from the sealed narrative store — the blob holds the skeleton + order,
    /// the sealed store holds the words. On a sync-OFF device reset the blob is gone too, so restoring
    /// narrative rows alone yields entries that exist and decrypt but are rendered by nothing. That
    /// fails precisely the users the sealed backup exists to protect.
    ///
    /// Implementations must add one `JournalEntry` per skeleton to that skeleton's day — only for ids
    /// the day lacks, never editing an existing one, and writing NO day that lacks none (the merge
    /// names unchanged entries too; review B3 fix round 1) — schedule a snapshot save, and re-run the
    /// sealed-journal refresh so hydration fills the text back in by id.
    ///
    /// - Returns: False when any day write failed: the restore then stays unresolved, and the next
    ///   session's idempotent merge re-adds the missing skeletons (R1-BR-6).
    func reinstateJournalEntries(from skeletons: [JournalNarrativeSkeleton]) -> Bool
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
    /// The backup in iCloud authenticates, but a newer Fernlet wrote it: its envelope, or a record in
    /// it (a feeling tag this build does not know, say), is a shape this build cannot read (review B3
    /// fix round 1). Terminal for THIS build — retrying reads the same set the same way, so it is not
    /// retried automatically in this process (a relaunch, which an update is, tries again) — and never
    /// a damaged backup: an update reads it. The user is told to update Fernlet.
    case needsNewerFernlet

    var didRestore: Bool {
        if case .restored = self { return true }
        return false
    }

    /// Whether this outcome left something the user should see (WS-4 "visible"). The benign outcomes
    /// (restored / nothing-to-restore / skipped-non-empty) do not.
    var needsAttention: Bool {
        switch self {
        case .deferredKeyNotSynced, .deferredLocked, .deferredTransient, .notRecognized, .rolledBack, .needsNewerFernlet:
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
        // `.needsNewerFernlet` too: only an update reads the set, and an update relaunches.
        case .restored, .nothingToRestore, .skippedStoreNotEmpty, .notRecognized, .rolledBack, .needsNewerFernlet:
            return false
        }
    }
}


/// Sealed CloudKit backup: reconcile (enable/disable upload) + restore (new-device /
/// fresh-install pull), extracted from `FernletStore` (plan §5d). Owns the
/// `SealedBackupService` / `CloudKitDataService` dependencies and the sealed stores' backup seams,
/// keeping the CloudKit egress off the store/core path.
///
/// **Every live payload — period, intimate logs and journal — runs on the Sealed backup v2 engine**
/// (journal and intimacy Sealed backup v2 design 2026-09-30, §3–§8, building on the period design's
/// §9.10): ``engine``, owned here and so by `FernletStore`, runs every pass on one serial worker
/// behind its gates — an id-keyed MERGE restore while this install's restore is unresolved, then an
/// export behind E1 (restore first), E2 (writer-first compare-and-swap against the set in iCloud), E3
/// (every chunk decrypted and sealed in memory before the first save) and the commit (set-scoped
/// suffix chunks, then the head, then a verify). The entry points below are façades over it: the
/// period adapter works through its cycle-record funnel, the intimacy adapter through the app's ONE
/// intimacy funnel (``attachIntimacyLogStore(_:)``) and the journal adapter through the sealed journal
/// store (``JournalBackupAdapter``: hub or device key, the referenced-ids snapshot, the fork merge and
/// the day skeletons). The retired `sensitiveNotes` payload is never sealed or restored; a surviving
/// copy is only ever deleted.
@MainActor
final class SealedBackupCoordinator {
    /// A local precondition a sealed-backup write failed on, before or without touching CloudKit.
    enum SealedBackupWiringError: Error, Equatable {
        /// A restore write was attempted while the Private tab's content key is locked. Mapped onto
        /// the retryable `.deferredLocked` restore outcome.
        case locked
    }

    private unowned let host: any SealedBackupContext

    /// Builds the identity the sealed records are sealed/opened under. Injectable ONLY so tests can
    /// point it at a throwaway keychain service instead of the device's real one; production leaves it
    /// nil and gets `IdentityService()`.
    private let identityFactory: (() -> IdentityService)?

    /// Builds the CloudKit-backed sealing service. Injectable ONLY so tests can drive the real
    /// `SealedBackupService` over a mock record database and assert what the EXPORT half actually
    /// writes. Production leaves it nil.
    private let serviceFactory: ((IdentityService) -> SealedBackupService)?

    /// Reads the storage preferences (sync, the per-payload switches, the deferral flags). Injectable
    /// ONLY so tests can drive the engine with chosen switches instead of the app's in-memory
    /// preferences; production leaves it nil and reads ``SealedBackupContext/sealedBackupPreferences``.
    private let preferencesProvider: (() -> StoragePreferences)?

    /// The cycle-record funnel the period backup pages and merges into. Injectable ONLY so tests can
    /// point it at an isolated sealed store; production leaves it nil and builds one on the shared
    /// store. Either way the coordinator installs the host's visibility gate and mutation hook on it
    /// (`resolvedPeriodRecordStore`).
    private let periodRecordStore: CycleRecordStore?

    /// The app's ONE gated intimacy funnel the intimate-log backup works through (design 2026-09-30,
    /// §4.4, §8): `ContentView`'s instance, handed over at launch wiring through
    /// ``attachIntimacyLogStore(_:)`` (tests pass one to the initializer). Nil until then — the
    /// intimacy adapter then answers "no store", so every intimacy pass stops at its gates before any
    /// network work. The coordinator never builds an instance of its own: a second, unhooked funnel
    /// could write logs the backup never hears about.
    private var intimacyLogStore: IntimacyLogStore?

    /// The sealed journal store the journal backup snapshots, reads and merges into (design
    /// 2026-09-30, §7) — `FernletStore`'s own repository (tests: an isolated one), or nil for the
    /// shared on-device store. Every user write to it goes through `JournalSealingCoordinator`, whose
    /// hook marks the journal upload owed (§4.4).
    private let injectedJournalRepository: JournalNarrativeRepository?

    /// ``injectedJournalRepository``, or the shared on-device store — resolved on first use, so a
    /// coordinator whose journal backup never runs (it is off, or a test drives another payload) never
    /// opens the shared sealed store.
    private lazy var journalRepository: JournalNarrativeRepository = injectedJournalRepository ?? JournalNarrativeRepository()

    /// The keychain service holding the journal DEVICE key the journal backup reads without minting
    /// (§7.2). Injectable ONLY for tests; production is `KeychainItem.journalService`.
    private let journalDeviceKeyService: String

    /// This install's writer tag. Injectable ONLY so tests can play two iPhones over one in-memory
    /// cloud; production leaves it nil and reads ``SealedBackupWriterTag/current()``.
    private let writerTagProvider: (() -> String?)?

    /// The engine's clock (spacing and backoff). Injectable ONLY for the spacing tests.
    private let clock: (() -> Date)?

    /// The engine's background-task assertion. Injectable ONLY so tests need no UIKit app state.
    private let backgroundTasks: (any SealedBackupBackgroundTaskAsserting)?

    /// The Sealed backup v2 engine every period, intimacy and journal pass runs on (design
    /// 2026-09-30, §4.2). Built on first use over the three adapters; one per coordinator, so one per
    /// `FernletStore`.
    private(set) lazy var engine: SealedBackupV2Engine = makeEngine()

    init(
        host: any SealedBackupContext,
        identityFactory: (() -> IdentityService)? = nil,
        serviceFactory: ((IdentityService) -> SealedBackupService)? = nil,
        preferencesProvider: (() -> StoragePreferences)? = nil,
        periodRecordStore: CycleRecordStore? = nil,
        intimacyLogStore: IntimacyLogStore? = nil,
        journalRepository: JournalNarrativeRepository? = nil,
        journalDeviceKeyService: String? = nil,
        writerTagProvider: (() -> String?)? = nil,
        clock: (() -> Date)? = nil,
        backgroundTasks: (any SealedBackupBackgroundTaskAsserting)? = nil
    ) {
        self.host = host
        self.identityFactory = identityFactory
        self.serviceFactory = serviceFactory
        self.preferencesProvider = preferencesProvider
        self.periodRecordStore = periodRecordStore
        self.injectedJournalRepository = journalRepository
        self.journalDeviceKeyService = journalDeviceKeyService ?? KeychainItem.journalService
        self.writerTagProvider = writerTagProvider
        self.clock = clock
        self.backgroundTasks = backgroundTasks
        if let intimacyLogStore { attachIntimacyLogStore(intimacyLogStore) }
    }

    /// Hands the coordinator the app's ONE intimacy funnel (design 2026-09-30, §4.4): installs the
    /// host's derived visibility gate (`!duress`, the 16+ age gate, the setting) and the mutation hook
    /// that marks the intimate-log upload owed after every write any surface makes, then keeps it for
    /// the intimacy adapter. Called by the launch wiring before the bookkeeping is seeded and before
    /// any settle; a second call replaces the first.
    ///
    /// - Parameter store: `ContentView`'s intimacy funnel (a test's isolated one).
    func attachIntimacyLogStore(_ store: IntimacyLogStore) {
        intimacyLogStore = wired(store)
    }

    /// `store` with the host's derived intimacy visibility gate and the intimate-log mutation hook
    /// installed — the wiring every intimacy funnel the backup touches carries.
    private func wired(_ store: IntimacyLogStore) -> IntimacyLogStore {
        store.attachVisibilityGate { [weak self] in self?.host.isIntimacyTrackingVisible ?? false }
        store.attachMutationHook { [weak self] in self?.host.markSealedBackupDirty(.intimacyLogs) }
        return store
    }

    /// Whether the attached intimacy funnel's divergence latch is set — the one-time seed of the
    /// intimate-log restore marker (§4.3). Nil while no funnel is attached: then nothing may be seeded,
    /// or a later restore would merge a stale cloud copy back in behind the user's deletes.
    var intimacyDivergenceLatch: Bool? { intimacyLogStore?.hasEverStoredLog }

    /// Whether the sealed journal store's divergence latch is set (backfilled from its keyless row
    /// count) — the one-time seed of the journal restore marker (§4.3): an install that already held
    /// or deleted journal entries seeds it resolved and never merges a stale copy back.
    var journalDivergenceLatch: Bool { journalRepository.hasEverStoredNarrative }

    /// Builds the engine over the period, intimacy and journal adapters, with this coordinator's
    /// factories.
    private func makeEngine() -> SealedBackupV2Engine {
        let injectedJournal = injectedJournalRepository
        let adapters: [SealedBackupPayloadType: any SealedBackupV2Adapter] = [
            .periodData: CycleRecordBackupAdapter(store: resolvedPeriodRecordStore()),
            .intimacyLogs: IntimacyBackupAdapter(storeProvider: { [weak self] in self?.intimacyLogStore }),
            .journalNarratives: makeJournalAdapter { injectedJournal ?? JournalNarrativeRepository() }
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

    /// The journal adapter over the repository `repository` answers (design 2026-09-30, §7): its seam
    /// is `!duress`, its snapshot the ids the host's days reference, its device key read without
    /// minting from ``journalDeviceKeyService``, its skeletons rebuilt by the host. Fail closed when the
    /// coordinator is gone (the seam shut, the referenced ids unknown, no skeleton written).
    private func makeJournalAdapter(_ repository: @escaping @MainActor () -> JournalNarrativeRepository) -> JournalBackupAdapter {
        let service = journalDeviceKeyService
        return JournalBackupAdapter(
            repository: repository,
            isOpen: { [weak self] in self.map { !$0.host.duressSessionActive } ?? false },
            referencedIDs: { [weak self] in self?.host.sealedBackupJournalReferencedIDs },
            deviceKey: { SealedDeviceKeyRead.read(.deviceJournalKey, service: service) },
            reinstate: { [weak self] skeletons in self?.host.reinstateJournalEntries(from: skeletons) ?? false }
        )
    }

    /// The storage preferences as they are right now.
    private func currentPreferences() -> StoragePreferences {
        preferencesProvider?() ?? host.sealedBackupPreferences
    }

    private func makeSealedBackupService(identity: IdentityService) -> SealedBackupService {
        serviceFactory?(identity)
            ?? SealedBackupService(cloudDataService: CloudKitDataService(), identityService: identity)
    }

    /// Turns a payload's sealed backup on (an export owed and, with the Private tab open, run now) or
    /// off (the cloud copy deleted). Returns whether it succeeded; callers persist the switch only on
    /// `true`.
    ///
    /// Every live payload runs on the v2 engine (``engine``): turning one on marks its upload owed and
    /// runs an export pass now if the Private tab is open (else the next hub settle does) — behind E1,
    /// so a new iPhone pulls its backup before anything is written over it; turning it off first STOPS
    /// the engine — any pass still uploading stops before its next save — and only then deletes, so no
    /// set is ever written after the delete (review finding on 8f808232). With `deletingAnySlot` false
    /// (the user's own switch) a slot this install observed as another iPhone's is KEPT (design
    /// 2026-09-30 §9, R2-F3): it is not this iPhone's backup.
    ///
    /// The retired `.sensitiveNotes` is never enabled; disabling it is the delete "delete everything"
    /// depends on.
    ///
    /// - Note: deliberately NOT `@discardableResult` (Power-of-10 R7): this is a success/failure
    ///   signal, and every caller has to decide what a `false` means for it.
    func setSealedBackupEnabled(
        _ enabled: Bool,
        payloadType: SealedBackupPayloadType,
        deletingAnySlot: Bool = true
    ) async -> Bool {
        // The RETIRED payload is never sealed again (owner decision 2026-09-23: the Tier-2 memories it
        // carried stay on the device). Disabling it still runs below: that is the delete, and "delete
        // everything" depends on it.
        guard SealedBackupBookkeeping.v2Payloads.contains(payloadType) else {
            guard !enabled else {
                FernletAuditLog.log("sealedBackup.retiredPayloadEnableRefused", context: ["payload": payloadType.rawValue])
                return false
            }
            return await deleteRetiredBackup(payloadType)
        }
        return enabled
            ? await enableV2Backup(payloadType)
            : await disableV2Backup(payloadType, deletingAnySlot: deletingAnySlot)
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

    /// The retired payload's delete — its whole chunk set by record name. It needs no content key,
    /// no escrow key and no visibility, which is what keeps it available while locked and hidden.
    private func deleteRetiredBackup(_ payload: SealedBackupPayloadType) async -> Bool {
        let service = makeSealedBackupService(identity: identityFactory?() ?? IdentityService())
        do {
            try await service.reconcile(Data(), payloadType: payload, enabled: false)
        } catch {
            FernletAuditLog.log("sealedBackup.reconcileFailed", context: ["payload": payload.rawValue])
            return false
        }
        FernletAuditLog.log("sealedBackup.reconciled", context: ["payload": payload.rawValue, "enabled": "false"])
        host.recordSealedBackupCloudCopyDeleted(payload)
        return true
    }

    /// Discharges an owed upload of `payloadType`: an export pass on the engine — ambient, so it
    /// honours the owner hold and E1, and a no-op while the Private tab is closed (the next hub settle
    /// runs it). Called by Privacy & Data's Retry follow-through. The retired `.sensitiveNotes` never
    /// owes one.
    ///
    /// - Note: returns `Void` (Power-of-10 R7): the owed upload stays recorded on a failure, and the
    ///   next hub settle retries it, so there is nothing for a caller to decide.
    func retryDeferredReuploadIfNeeded(payloadType: SealedBackupPayloadType) async {
        guard currentPreferences().iCloudSyncEnabled, SealedBackupBookkeeping.v2Payloads.contains(payloadType) else { return }
        let report = await engine.perform(payloadType, trigger: .retry, phases: .export)
        if report.exportStatus == .failed {
            FernletAuditLog.log("sealedBackup.deferredReuploadRetryFailed", context: ["payload": payloadType.rawValue])
        }
    }

    /// The period-specific spelling of ``retryDeferredReuploadIfNeeded(payloadType:)``, kept because
    /// the `FernletStore` wrapper names it directly.
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
        // No identity provisioning: `ensureProvisioned()` can mint a device identity, and a delete by
        // record name needs no key at all.
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

    /// Called once at launch (after the store is ready), and again from the user's "Retry" action.
    /// Deletes a surviving copy of the retired payload, then — with iCloud sync on — reconciles the
    /// escrow key, so a cross-device key conflict is surfaced non-silently before anything is opened
    /// (WS-3). Gated by `FERNLET_SKIP_SEALED_RESTORE` so UI tests can opt out — DEBUG-only, so it
    /// cannot be triggered in a shipping binary.
    ///
    /// No payload restores here: nothing can be opened with the Private tab closed, so the ambient
    /// launch pass never touches a payload (design 2026-09-30, §4.5), and every restore runs on the
    /// engine at the next hub settle. The user's Retry (`userInitiated`) asks the engine for an
    /// AMBIENT pass of each payload — the owner hold, E1 and every gate honoured (intimacy's
    /// visibility and the 16+ gate, no duress for any) — a no-op while Private is closed (R1-BR-15).
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
        reconcileEscrowKey()
        if host.sealedBackupRestoreAwaitsOwner {
            FernletAuditLog.log("sealedBackup.restoreHeldForOwner", context: ["site": "launch"])
        }
        guard userInitiated else { return }
        for payload in SealedBackupBookkeeping.v2Payloads {  // R2: the v2 payloads (three).
            let report = await engine.perform(payload, trigger: .retry, phases: .both)
            FernletAuditLog.log("sealedBackup.v2.retryPass", context: [
                "payload": payload.rawValue, "ran": report.gateFailure == nil ? "true" : "false"
            ])
        }
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
    /// authoritative, then owe a re-upload of every enabled backup under it. The caller (UI) MUST warn
    /// the user first that device-only backups may need re-uploading. Returns whether a synced key was
    /// adopted; the conflict status is cleared on success.
    ///
    /// The adopt marks every enabled payload's upload owed and nothing more (design 2026-09-30 §4.5):
    /// the next hub settle exports through E2, which treats a head this install sealed under the key the
    /// adopt replaced as its own (its signing key, §5.5) — and the owner hold, a hidden surface and E1
    /// all still apply there, so none of them needs a branch here.
    ///
    /// - Note: deliberately NOT `@discardableResult` (Power-of-10 R7). A `false` means the conflict
    ///   banner the user just acted on is still there, and only the caller can say so.
    func adoptSyncedEscrowAndReupload() async -> Bool {
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
        let prefs = currentPreferences()
        for payload in SealedBackupBookkeeping.v2Payloads where prefs.isSealedBackupEnabled(for: payload) {
            host.markSealedBackupDirty(payload)
        }
        return true
    }

    /// One payload's restore as a rich outcome (WS-4) — an engine pass of the restore phase, which
    /// records what really ran on the host itself; the retired `.sensitiveNotes` answers — and records
    /// — the benign `.nothingToRestore` before any store, identity or network work (it is never
    /// restored).
    func restoreSealedBackupOutcome(payloadType: SealedBackupPayloadType) async -> SealedBackupRestoreOutcome {
        guard SealedBackupBookkeeping.v2Payloads.contains(payloadType) else {
            FernletAuditLog.log("sealedBackup.restoreSkippedRetiredPayload", context: ["payload": payloadType.rawValue])
            host.recordSealedBackupRestoreOutcome(.nothingToRestore, payloadType: payloadType)
            return .nothingToRestore
        }
        return await restoreV2Backup(payloadType)
    }

    /// One payload's restore on its own (design 2026-09-30, §4.2 R): an engine pass of the restore
    /// phase only — an id-keyed MERGE of the cloud set that inserts ids absent here, completes or links
    /// present ones (journal: adds a different text beside the local one), replaces dead ones and never
    /// deletes an openable record. Both set shapes restore (a v1 bare array, a v2 envelope).
    ///
    /// Runs while this install's restore is unresolved — which is what stops a stale cloud copy from
    /// resurrecting entries deleted here — behind every gate (sync and the backup on, the surface
    /// visible — for intimacy the 16+ gate and its setting, for every payload no duress —, the Private
    /// tab's key live, the store attached) and never while an app-lock reset's owner hold waits, whoever
    /// asks (R1-BR-15: the Retry included). A refusal at a gate is answered without network work and
    /// recorded as no status; a resolved install answers `.skippedStoreNotEmpty`. A restore that lands
    /// (`.restored`, `.nothingToRestore`) resolves the marker and records the set as accepted.
    ///
    /// - Parameters:
    ///   - payload: A v2 payload.
    ///   - initiatedByUser: The user's own Retry — an ambient trigger like any other (§4.5).
    func restoreV2Backup(_ payload: SealedBackupPayloadType, initiatedByUser: Bool = false) async -> SealedBackupRestoreOutcome {
        let report = await engine.perform(payload, trigger: initiatedByUser ? .retry : .hubSettle, phases: .restore)
        if let outcome = report.restoreOutcome { return outcome }
        return report.gateFailure.map(SealedBackupV2Engine.outcome(forGate:)) ?? .deferredTransient
    }

    /// The period restore on its own — ``restoreV2Backup(_:initiatedByUser:)`` for `.periodData`.
    ///
    /// - Parameter initiatedByUser: The user's own Retry — an ambient trigger like any other (§4.5).
    func restorePeriodBackup(initiatedByUser: Bool = false) async -> SealedBackupRestoreOutcome {
        await restoreV2Backup(.periodData, initiatedByUser: initiatedByUser)
    }

    /// The intimate-log restore on its own — ``restoreV2Backup(_:initiatedByUser:)`` for
    /// `.intimacyLogs` (design 2026-09-30, §8). Hidden (the setting, under 16, a duress session)
    /// answers `.deferredTransient` with nothing fetched, decrypted or written.
    ///
    /// - Parameter initiatedByUser: The user's own Retry — an ambient trigger like any other (§4.5).
    func restoreIntimacyBackup(initiatedByUser: Bool = false) async -> SealedBackupRestoreOutcome {
        await restoreV2Backup(.intimacyLogs, initiatedByUser: initiatedByUser)
    }

    /// The journal restore on its own — ``restoreV2Backup(_:initiatedByUser:)`` for
    /// `.journalNarratives` (design 2026-09-30, §7): a merge into whatever the store holds (entries
    /// under the device key that survived an erase-and-restore included), then the day skeletons. A
    /// duress session answers `.deferredTransient` with nothing fetched, decrypted or written.
    ///
    /// - Parameter initiatedByUser: The user's own Retry — an ambient trigger like any other (§4.5).
    func restoreJournalBackup(initiatedByUser: Bool = false) async -> SealedBackupRestoreOutcome {
        await restoreV2Backup(.journalNarratives, initiatedByUser: initiatedByUser)
    }

    /// The hub settle for one v2 payload (and the un-hide settle), in its one order: restore while
    /// unresolved, then export (design 2026-09-30, §4.2) — a pending explicit intent ("Restore it
    /// here", "Replace", …) taking the ambient request's place. A no-op without the Private tab's key,
    /// while hidden, or with iCloud sync or the backup off — and it never marks the restore resolved
    /// because there is nothing to restore from (§4.8 item 13): that is only ever decided by a restore
    /// that ran.
    ///
    /// - Parameter payload: A v2 payload.
    func settleV2Backup(_ payload: SealedBackupPayloadType) async {
        let report = await engine.perform(payload, trigger: .hubSettle, phases: .both)
        if report.exportStatus == .failed {
            FernletAuditLog.log("sealedBackup.v2.settleExportFailed", context: ["payload": payload.rawValue])
        }
    }

    /// The period backup's settle — ``settleV2Backup(_:)`` for `.periodData`.
    func settlePeriodBackup() async {
        await settleV2Backup(.periodData)
    }

    /// Privacy & Data's "Restore it here" (period design §10.6; design 2026-09-30 §4.6), behind its
    /// confirmation that entries deleted on this iPhone since that backup may come back: an explicit
    /// intent carried out now when the Private tab is open, else at the next hub settle — a merge of
    /// exactly `stamp`, the set the row named, accepted even below this iPhone's rollback floor
    /// (counters are per device and "Delete everything" zeroes them, review U5-backup-v2-C-U5-2), after
    /// which the export follows and this iPhone takes the slot. It never touches this install's restore
    /// marker (R1-BR-4): one that cannot land returns to the held state with both choices. Still held
    /// for the device owner after an app-lock reset (R1-BR-15).
    ///
    /// - Parameters:
    ///   - payload: A v2 payload.
    ///   - stamp: The set the row named.
    func restoreBackupHere(_ payload: SealedBackupPayloadType, _ stamp: SealedBackupHeadStamp) async {
        let intent = SealedBackupTrigger.restoreHere(stamp, ignoringRollback: true)
        engine.recordIntent(intent, for: payload)
        FernletAuditLog.log("sealedBackup.v2.restoreHereChosenByUser", context: ["payload": payload.rawValue])
        _ = await engine.perform(payload, trigger: intent, phases: .both)
    }

    /// The period spelling of ``restoreBackupHere(_:_:)``.
    ///
    /// - Parameter stamp: The set named in ``PeriodBackupExportState/heldByAnotherDevice(_:)``.
    func restorePeriodBackupHere(_ stamp: SealedBackupHeadStamp) async {
        await restoreBackupHere(.periodData, stamp)
    }

    /// Privacy & Data's "Replace it with this iPhone's …" (period design §10.6), behind its destructive
    /// confirmation: an explicit intent that exports with E1 waived and E2 passing for exactly `stamp`
    /// — if the other iPhone has written another set since, the export is held again and asks again:
    /// the user agreed to replace the set they were shown, not one they never saw.
    ///
    /// - Parameters:
    ///   - payload: A v2 payload.
    ///   - stamp: The set the row named.
    func replaceBackupWithThisIPhone(_ payload: SealedBackupPayloadType, _ stamp: SealedBackupHeadStamp) async {
        let intent = SealedBackupTrigger.replace(stamp)
        engine.recordIntent(intent, for: payload)
        host.markSealedBackupDirty(payload)
        FernletAuditLog.log("sealedBackup.v2.replaceChosenByUser", context: ["payload": payload.rawValue])
        _ = await engine.perform(payload, trigger: intent, phases: .export)
    }

    /// The period spelling of ``replaceBackupWithThisIPhone(_:_:)``.
    ///
    /// - Parameter stamp: The set named in the export state.
    func replacePeriodBackupWithThisIPhone(_ stamp: SealedBackupHeadStamp) async {
        await replaceBackupWithThisIPhone(.periodData, stamp)
    }

    /// Privacy & Data's "Start a new backup" for a set this iPhone cannot open (sealed to another backup
    /// key, damaged, or its key not here; §4.6, §5.6): an explicit intent that exports with E1 and E2
    /// waived, minting an escrow key if none is here, and writes over the unopenable set — never over a
    /// set that opens (review B1-D-B1-R3).
    ///
    /// - Parameter payload: A v2 payload.
    func startNewBackup(_ payload: SealedBackupPayloadType) async {
        engine.recordIntent(.startNew, for: payload)
        host.markSealedBackupDirty(payload)
        FernletAuditLog.log("sealedBackup.v2.startNewChosenByUser", context: ["payload": payload.rawValue])
        _ = await engine.perform(payload, trigger: .startNew, phases: .export)
    }

    /// The period spelling of ``startNewBackup(_:)``.
    func startNewPeriodBackup() async {
        await startNewBackup(.periodData)
    }

    /// Privacy & Data's "Remove them" for the entries a paused backup named (§4.6, R2-F12): an explicit
    /// intent that, at the next pass with the Private tab open, re-classifies exactly the shown ids
    /// under every key this iPhone holds, deletes only those still dead, and exports. Nothing is
    /// decrypted or deleted from here.
    ///
    /// - Parameters:
    ///   - payload: A v2 payload.
    ///   - ids: The ids the paused row named.
    func removeUnopenableEntries(_ payload: SealedBackupPayloadType, ids: [UUID]) async {
        let intent = SealedBackupTrigger.remove(ids)
        engine.recordIntent(intent, for: payload)
        FernletAuditLog.log("sealedBackup.v2.removeUnopenableChosenByUser", context: [
            "payload": payload.rawValue, "count": String(ids.count)
        ])
        _ = await engine.perform(payload, trigger: intent, phases: .both)
    }

    /// Privacy & Data's "Restore" after an app-lock reset (design §5.3, Q14; 2026-09-30 §4.6), behind
    /// the screen's fresh device-owner check: releases the ambient-restore hold ON THE TAP — safe,
    /// because the reset left every restore unresolved, so E1 still blocks every export until its merge
    /// has run — then asks the engine for every payload's restore. Each payload's re-uploads stay held
    /// until its own restore has landed (``SealedBackupContext/recordSealedBackupPreResetCopySettled(_:)``).
    /// While the hold still keeps a payload's pre-reset copy, that payload's restore is reopened too:
    /// the owner asked for that copy back, and a marker resolved in the meantime must not stand between
    /// them (review U5-backup-v2-L-U5-R2). One action covers every kind (Q-B2).
    func releaseRestoreHoldForOwner() async {
        host.releaseSealedBackupRestoreHold()
        for payload in SealedBackupBookkeeping.v2Payloads where host.sealedBackupKeepsPreResetCopy(of: payload) {
            host.sealedBackupBookkeeping.reopenRestore(payload)
        }
        FernletAuditLog.log("sealedBackup.restoreHoldReleasedByOwner")
        for payload in SealedBackupBookkeeping.v2Payloads {  // R2: the v2 payloads (three).
            _ = await engine.perform(payload, trigger: .ownerRelease, phases: .both)
        }
    }

    /// Bool-returning restore kept for the restore tests and the `FernletStore` wrapper; returns
    /// whether records were actually written.
    ///
    /// - Note: deliberately NOT `@discardableResult` (Power-of-10 R7): the return value is the only
    ///   place a caller learns whether anything came back.
    func restoreSealedBackup(payloadType: SealedBackupPayloadType) async -> Bool {
        await restoreSealedBackupOutcome(payloadType: payloadType).didRestore
    }

    /// Decodes a single decrypted sealed-backup payload and merges it into the local stores. Thin
    /// wrapper over `applyRestoredChunks` (a single blob is just a one-element chunk set), kept for the
    /// restore tests and any single-record caller.
    @discardableResult
    func applyRestoredPayload(
        _ plaintext: Data,
        payloadType: SealedBackupPayloadType,
        cycleRecordStore: CycleRecordStore? = nil,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil
    ) throws -> Int {
        try applyRestoredChunks(
            [plaintext],
            payloadType: payloadType,
            cycleRecordStore: cycleRecordStore,
            journalRepository: journalRepository,
            intimacyStore: intimacyStore
        )
    }

    /// Decodes the decrypted chunks of a sealed-backup payload and MERGES them into the local stores,
    /// returning how many records the merge inserted, merged, replaced or forked (0 when the set added
    /// nothing). Separated from the CloudKit fetch so it is unit-testable without iCloud; the engine's
    /// own restore verifies the set first (§5.3), and this direct path is for the decode-and-merge
    /// tests. The retired sensitive-notes payload writes NOTHING and returns 0 before any store is
    /// touched. Every live payload re-seals under the Private tab's key, so it requires that key and
    /// throws `SealedBackupWiringError.locked` otherwise.
    ///
    /// Every payload is an id-keyed MERGE through its adapter — one atomic save that inserts absent
    /// ids and never deletes or overwrites an openable record — so none has a store-empty
    /// precondition: period completes present records, intimacy fills a missing Health link, and the
    /// journal adds a different text beside the local entry, then rebuilds the day skeletons. Both
    /// chunk shapes decode (a v1 bare array, a v2 ``SealedBackupV2Envelope``). A hidden surface or a
    /// duress session throws (retryable). The intimacy merge goes through `intimacyStore` (wired with
    /// the host's gate and hook) or, with none, the attached app funnel; with neither it throws the
    /// hidden error (fail closed). The journal merge goes through `journalRepository`, or this
    /// coordinator's.
    @discardableResult
    func applyRestoredChunks(
        _ chunks: [Data],
        payloadType: SealedBackupPayloadType,
        cycleRecordStore: CycleRecordStore? = nil,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil
    ) throws -> Int {
        // A restore whose surrounding Task was cancelled must not write — "delete everything" cancels
        // the writers it can reach, and this check at the single direct write point makes that stop the
        // write instead of racing it. Cheap no-op in any uncancelled context, including the synchronous
        // test callers. (`CancellationError` classifies as `.deferredTransient` upstream.)
        try Task.checkCancellation()
        switch payloadType {
        case .sensitiveNotes:
            // The RETIRED payload's plaintext is never decoded, let alone written back.
            FernletAuditLog.log("sealedBackup.applySkippedRetiredPayload", context: ["payload": payloadType.rawValue])
            return 0
        case .periodData:
            return try applyRestoredV2Chunks(chunks, adapter: CycleRecordBackupAdapter(store: resolvedPeriodRecordStore(cycleRecordStore)))
        case .intimacyLogs:
            let store = intimacyStore.map(wired) ?? intimacyLogStore
            return try applyRestoredV2Chunks(chunks, adapter: IntimacyBackupAdapter(storeProvider: { store }))
        case .journalNarratives:
            let repository = journalRepository ?? self.journalRepository
            return try applyRestoredV2Chunks(chunks, adapter: makeJournalAdapter { repository })
        }
    }

    /// The merge half of ``applyRestoredChunks(_:payloadType:cycleRecordStore:journalRepository:intimacyStore:)``:
    /// decodes every chunk (a v1 bare array or a v2 envelope), merges the whole set in ONE
    /// `restoreMerging` save through `adapter` — all or nothing, so a failed restore leaves the store
    /// exactly as it was — then runs the adapter's follow-up (the journal's day skeletons; a failed
    /// one is audited, and the engine's own restore keeps itself unresolved over it).
    ///
    /// - Returns: How many records the merge inserted, merged, replaced or forked.
    private func applyRestoredV2Chunks<A: SealedBackupV2Adapter>(_ chunks: [Data], adapter: A) throws -> Int {
        guard let key = host.sealedBackupContentKey else { throw SealedBackupWiringError.locked }
        var records: [A.Record] = []
        for chunk in chunks {  // R2: bounded by the restored set (≤ SealedBackupService.maxRestoreChunkCount).
            if SealedBackupV2Format.isV1(chunk) {
                records.append(contentsOf: try adapter.decodeV1Chunk(chunk))
            } else {
                records.append(contentsOf: try JSONDecoder().decode(SealedBackupV2Envelope<A.Record>.self, from: chunk).records)
            }
        }
        let merged = try adapter.restoreMerging(records, hubKey: key)
        if !adapter.didRestore(merged) {
            FernletAuditLog.log("sealedBackup.applyFollowUpFailed", context: ["payload": adapter.payload.rawValue])
        }
        return merged.changedCount
    }
}
