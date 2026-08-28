import ProximityKit
import CloudKitSync
import FernletFoundation
import FernletCrypto
import Foundation
import PrivateMediaStore

/// The state the own-photo escrow route needs from the app store — kept as a seam (the
/// `SealedBackupContext` pattern) so the coordinator depends on this, not on the concrete
/// `FernletStore`.
@MainActor
protocol OwnPhotoBackupContext: AnyObject {
    /// Records the outcome of an own-photo backup pass so the Privacy & Data banner can show an
    /// honest, retryable status (WS-4) instead of a silently-swallowed failure.
    func recordOwnPhotoBackupOutcome(_ outcome: SealedBackupRestoreOutcome)

    /// Records whether the UPLOAD half of the last pass failed.
    ///
    /// Separate from ``recordOwnPhotoBackupOutcome(_:)`` because `SealedBackupRestoreOutcome` is
    /// restore vocabulary — its copy says "couldn't restore your backup", which is the wrong
    /// sentence for "none of your photos reached iCloud". Without this the harmful case is
    /// completely silent: a device that HAS photos never enters the restore branch at all, so a pass
    /// in which every CloudKit save failed publishes `.nothingToRestore`, whose `needsAttention` is
    /// false, and the banner renders nothing for the life of the install.
    func recordOwnPhotoBackupUploadFailed(_ failed: Bool)

    /// Records how many photos the last FULL-verification pass could not read — the third
    /// upload-side status, distinct from ``recordOwnPhotoBackupUploadFailed(_:)`` because the
    /// manifest still COMMITTED: the pass succeeded for everything it could see, but these photos
    /// may be missing from the backup or stale in it, and reporting the pass as clean would hide
    /// exactly the gap a verification pass exists to find. Zero clears the state. Called only for
    /// full passes — an ambient pass reads almost nothing, so it has no verdict to record.
    func recordOwnPhotoBackupVerifiedUnreadable(_ count: Int)
}

/// The opt-in own-photo escrow backup: policy, gating and ordering around
/// ``SealedPhotoBackupService`` (which is mechanism only).
///
/// What this type owns, and why each piece exists:
/// - **One user-facing switch, three corpora.** The preference is a single
///   `sealedBackupOwnPhotosEnabled`; meal / recipe / progress are internal record namespaces
///   (``SealedPhotoCorpus``), not three consent questions. They are all "your own photos".
/// - **Per-corpus no-clobber gate, in two halves.** Own-photo ownership is scattered
///   (`Meal.photoID`, the recipe id, the progress index), so "is this device empty?" cannot be a
///   whole-device check — it is a per-corpus check, the same shape as the sealed narratives'
///   `isEmptyStoreForRestore`. File presence (`isEmptyForRestore()`) is the first half; **openable**
///   presence (`holdsOnlyUnopenableFiles()`) is the second, and it is what makes the route work in
///   the scenario it exists for. Once the own-photos key is device-bound, a device-backup restore
///   onto a NEW phone brings the sealed photo FILES back but not the key, so every one of them is
///   permanently unopenable; a presence-only gate reads that as "this corpus is in use" and declines
///   the very restore the user paid iCloud quota for. So a corpus that holds nothing this install
///   can open is restored INTO, exactly like an empty one. The stranded files are never deleted to
///   achieve that — "unopenable" also covers truncated files and the meal corpus's legitimate
///   pre-sealing plaintext, which the read path still returns; the restore simply writes the
///   corpus's real photos back over their own ids.
/// - **Repair after a partial restore.** Per-photo failures are isolated by design, but the first
///   successful write makes the corpus non-empty — so without a repair path the ids that failed
///   could never be fetched again on any launch or Retry, while their sealed bodies sat intact in
///   iCloud. ``OwnPhotoRestoreRepairLedger`` remembers exactly those ids and the next pass
///   re-fetches *them* (bypassing the emptiness gate, which is now correctly false), until the set
///   is empty.
/// - **Restore before re-upload, always.** A device that has not restored yet is empty for exactly
///   the reason the backup exists, so uploading from it would replace the cloud copy with an empty
///   manifest. An empty corpus therefore never uploads — with one deliberate exception, which is the
///   other half of the same question: a corpus this device HAS uploaded to and has since emptied is
///   empty because the user deleted their photos, so it neither restores (that would write every
///   deleted photo back as an unreferenced orphan) nor stays silent (that would leave the delete
///   forever unpropagated). It prunes exactly its own ids. ``OwnPhotoUploadLedger/hasUploaded(for:)``
///   is what tells the two apart.
/// - **Prune scope.** Own photos are device-local files that no sync carries between devices, so an
///   id in the cloud that this device does not have is as likely to be the user's other phone's as
///   a deletion. ``OwnPhotoUploadLedger`` records what THIS device uploaded, and only those ids may
///   be removed; everything else is carried forward (see `SealedPhotoBackupService.reconcile`).
/// - **Teardown for "delete everything"**, run before the local wipe (see
///   ``tearDownForDeleteAll()``).
///
/// Builds its own `MealPhotoStore`/`ProgressPhotoStore` instances over the shared
/// ``OwnPhotoCorpusLayout`` paths rather than borrowing `FernletStore`'s: the stores are value types
/// over a directory and their key providers read the same keychain rows, so this is the same data —
/// and it keeps a non-`Sendable` provider from being shared across owners (the precedent
/// `OwnPhotoKeyMigrator` set).
///
/// Main-actor isolated, like every collaborator it touches.
@MainActor
final class OwnPhotoBackupCoordinator {
    private unowned let host: any OwnPhotoBackupContext
    private let documentsDirectory: URL
    /// Builds the identity photo records are sealed/opened under. Injectable ONLY so tests can point
    /// it at a throwaway keychain service; production leaves it nil and gets `IdentityService()`.
    private let identityFactory: (() -> IdentityService)?
    /// Builds the CloudKit transport. Injectable ONLY so tests can drive the real service over a
    /// mock record database — the half that decides what actually reaches iCloud.
    private let cloudFactory: (() -> CloudKitDataService)?
    /// Backs the photo-namespaced rollback high-water marks; tests inject an isolated suite.
    private let defaults: UserDefaults
    /// In-memory teardown counter, incremented as the FIRST statement of ``tearDownForDeleteAll()``.
    /// `synchronizeFullyVerified` snapshots it before its migration run and its pass closure
    /// re-checks it per funded pass, so a delete-all that lands between funded passes turns every
    /// remaining pass into a no-op instead of re-uploading — and re-latching over — a backup the
    /// user just destroyed (the delete-all-writers resurrection family). Session state only: a
    /// crash mid-run leaves nothing latched, which is the safe direction.
    private var teardownEpoch = 0
    /// Whether a coordinator pass is currently in flight. `synchronizeFullyVerified` refuses to
    /// overlap it: the reconcile's open-before/write-after shape is a last-writer-wins race
    /// between devices, and the same device must never race itself (the Retry button already
    /// disables in flight — this is the same rule below the UI, covering the launch-ambient pass).
    private var passInFlight = false
    /// The §C4 session verdict of the LAST `synchronizeFullyVerified` run: it completed blocked
    /// with nothing wrong on THIS device — every corpus committed and examined, nothing unreadable,
    /// nothing left to heal — and only a carried-forward foreign legacy entry (an observed manifest
    /// minimum of 1) holding the latch open. `FernletStore` re-reads it into the Privacy & Data
    /// copy, because Retry structurally cannot clear that state and offering it anyway would be a
    /// treadmill. Cleared by any other wrapper outcome and by teardown; never persisted — one tap
    /// re-derives it.
    private(set) var lastFullPassBlockedOnlyByOtherDevices = false

    init(
        host: any OwnPhotoBackupContext,
        documentsDirectory: URL,
        identityFactory: (() -> IdentityService)? = nil,
        cloudFactory: (() -> CloudKitDataService)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.host = host
        self.documentsDirectory = documentsDirectory
        self.identityFactory = identityFactory
        self.cloudFactory = cloudFactory
        self.defaults = defaults
    }

    // MARK: - Corpus access

    /// Everything the route needs from one corpus's local store, resolved per call so a store is
    /// never held across an `await` (each is a cheap value type over a directory).
    ///
    /// `sidecar` is nil for a corpus with no index AND for a progress corpus whose index is present
    /// but unreadable — the caller treats nil as "do not upload this corpus", because uploading a
    /// timeline-less set of body photos would restore as invisible bytes, and uploading an EMPTY
    /// index over a good one would destroy the dates and captions.
    private struct CorpusAccess {
        /// The corpus's local id set, or **nil when the store could not enumerate it** (a directory
        /// that exists but cannot be listed). Nil is a distinct fact from empty: an unknown number
        /// of files is not the same as none, and a reconcile fed `[]` by an unlistable directory
        /// would carry everything forward unread — and, with a non-empty prunable set, prune this
        /// device's own committed entries while their files sit intact on disk. The caller maps
        /// nil to an indeterminate (skipped, uncommitted) corpus.
        let ids: () -> [UUID]?
        let plaintext: (UUID) -> Data?
        let write: (UUID, Data) -> Bool
        let isEmpty: () -> Bool
        /// Whether the corpus holds files but nothing this install can open — the second half of
        /// the no-clobber gate. See `MealPhotoStore.holdsOnlyUnopenableFiles()`.
        let holdsOnlyUnopenableFiles: () -> Bool
        let carriesSidecar: Bool
        let sidecar: () -> Data?
        let restoreSidecar: (Data) -> Bool
    }

    /// The own-photos key plus the pre-split key as the read-path dual-open fallback — the same
    /// wiring `FernletStore` gives its own stores, so a file the eager migration has not re-sealed
    /// yet is still readable (and therefore still backup-able) rather than silently skipped.
    private func ownKeyProvider() -> KeychainPrivateMediaKeyProvider {
        KeychainPrivateMediaKeyProvider(role: .ownPhotos)
    }

    /// Nil once the own-photos row is device-bound (step 5c), matching `FernletStore` exactly — the
    /// two wirings must agree, or a backup pass would read photos through a seam the app itself has
    /// dropped. Asked of the keychain rather than a persisted flag, for the reason spelled out on
    /// `OwnPhotoKeyBinder.isOwnPhotoKeyDeviceBound()`.
    private func legacyKeyProvider() -> KeychainPrivateMediaKeyProvider? {
        guard !OwnPhotoKeyBinder.isOwnPhotoKeyDeviceBound() else { return nil }
        return KeychainPrivateMediaKeyProvider(role: .friendWall, mintsIfAbsent: false)
    }

    private func mealStore(recipe: Bool) -> MealPhotoStore {
        MealPhotoStore(
            directory: recipe
                ? OwnPhotoCorpusLayout.recipePhotosDirectory(in: documentsDirectory)
                : OwnPhotoCorpusLayout.mealPhotosDirectory(in: documentsDirectory),
            keyProvider: ownKeyProvider(),
            // Recipe photos were born sealed; meal photos have a genuine pre-sealing plaintext
            // generation. Mirrors `FernletStore`'s construction exactly.
            allowsLegacyPlaintextUpgrade: !recipe,
            legacyKeyProvider: legacyKeyProvider(),
            purpose: recipe
                ? FernletCryptoPurpose.AEAD.recipePhotoV2
                : FernletCryptoPurpose.AEAD.mealPhotoV2
        )
    }

    private func progressStore() -> ProgressPhotoStore {
        ProgressPhotoStore(
            directory: OwnPhotoCorpusLayout.progressPhotosDirectory(in: documentsDirectory),
            keyProvider: ownKeyProvider(),
            legacyKeyProvider: legacyKeyProvider()
        )
    }

    /// `MealPhotoStore.storedPhotoIDs()` maps an unlistable directory to `[]`, which
    /// `isEmptyForRestore()` deliberately reads as NON-empty — so without this probe the reconcile
    /// would run over an empty id view of a corpus that holds files. Re-probes the same way
    /// `isEmptyForRestore` does: directory absent → `[]` (honestly empty); present but unlistable
    /// → nil (the fail-closed enumeration-failure signal `CorpusAccess.ids` carries).
    private static func listableStoredIDs(of store: MealPhotoStore, directory: URL) -> [UUID]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        guard (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) != nil else {
            return nil
        }
        return store.storedPhotoIDs()
    }

    private func access(for corpus: SealedPhotoCorpus) -> CorpusAccess {
        switch corpus {
        case .meal, .recipe:
            let store = mealStore(recipe: corpus == .recipe)
            let directory = corpus == .recipe
                ? OwnPhotoCorpusLayout.recipePhotosDirectory(in: documentsDirectory)
                : OwnPhotoCorpusLayout.mealPhotosDirectory(in: documentsDirectory)
            return CorpusAccess(
                ids: { Self.listableStoredIDs(of: store, directory: directory) },
                plaintext: { store.imageData(for: $0) },
                write: { store.restoreSealedPhoto($1, forID: $0) },
                isEmpty: { store.isEmptyForRestore() },
                holdsOnlyUnopenableFiles: { store.holdsOnlyUnopenableFiles() },
                carriesSidecar: false,
                sidecar: { nil },
                restoreSidecar: { _ in true }
            )
        case .progress:
            let store = progressStore()
            return CorpusAccess(
                // Driven from the INDEX, not the directory: the index is the user-visible timeline,
                // and a byte file it does not name is an orphan nothing would render after a restore.
                // Never nil — this corpus's enumeration failure is an unreadable index, which the
                // sidecar check below already turns into a blocking skip.
                ids: { store.records().map(\.id) },
                plaintext: { store.imageData(for: $0) },
                write: { store.restoreSealedPhoto($1, forID: $0) },
                isEmpty: { store.isEmptyForRestore() },
                holdsOnlyUnopenableFiles: { store.holdsOnlyUnopenableFiles() },
                carriesSidecar: true,
                sidecar: { store.backupIndexPayload() },
                restoreSidecar: { store.restoreIndexPayload($0) }
            )
        }
    }

    // MARK: - Identity + service

    /// How the escrow key should be prepared, mirroring `SealedBackupCoordinator.EscrowMode`: the
    /// open/restore path must NEVER mint a key (WS-1), the seal path may mint one lazily, and a
    /// delete needs none at all (records are addressed by name).
    private enum EscrowMode {
        case none
        case forSealing
        case forOpening
    }

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

    private func makeCloudService() -> CloudKitDataService {
        cloudFactory?() ?? CloudKitDataService()
    }

    private func makeService(identity: IdentityService) -> SealedPhotoBackupService {
        SealedPhotoBackupService(
            cloudDataService: makeCloudService(),
            identityService: identity,
            generationStore: SealedBackupGenerationStore(defaults: defaults)
        )
    }

    // MARK: - Enable / disable

    /// Turns the own-photo escrow backup on or off. Returns whether the operation succeeded; the
    /// caller should only persist the preference when it did.
    ///
    /// Enabling runs the full ``synchronize()`` pass (restore first, then upload what this device
    /// holds) and reports **false when that pass could not commit the user's photos** — offline,
    /// signed out of iCloud, over quota, or a record type not yet in the Production schema. That
    /// matters far beyond a tidy return value: `FernletStore.setOwnPhotoBackupEnabled` treats a
    /// `true` as proof of a cross-device route and IRREVERSIBLY device-binds the own-photos key on
    /// the strength of it. Returning `true` after an upload that reached nothing would take away the
    /// device-backup route without having built the replacement — the one outcome this whole phase
    /// exists to avoid. It also matches the sibling `SealedBackupCoordinator.setSealedBackupEnabled`,
    /// which likewise refuses on a failed reconcile so the preference never persists.
    ///
    /// Disabling tears every corpus down — the destructive half, which is why the UI puts a WS-5
    /// confirmation in front of it.
    ///
    /// - Note: deliberately NOT `@discardableResult` (Power-of-10 R7). This is the one Bool the
    ///   route cannot afford to have ignored — a `true` is what irreversibly device-binds the key.
    func setEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            guard makeIdentity(escrowMode: .forSealing) != nil else {
                FernletAuditLog.log("sealedPhoto.notProvisioned")
                return false
            }
            // Enabling is a FULL pass: every photo's bytes are read and hashed, so the first upload
            // is complete rather than id-set-shaped. Routed through the Phase 2.1 migration
            // wrapper, whose merge semantics keep this contract exactly the pre-2.1 single-pass
            // bar: "some pass this run committed with no upload failure" passes the enable, and a
            // transient CONFIRMING-pass failure never vetoes a committed healing pass (which would
            // snap the toggle off over a committed backup).
            let pass = await synchronizeFullyVerified(preferenceOverride: true)
            return !pass.uploadFailed
        }
        return await tearDownForDeleteAll()
    }

    /// What one whole pass did, across all three corpora — enough for the caller to decide whether
    /// the route is real, and for the host to say so without inventing restore vocabulary for an
    /// upload problem.
    struct PassResult {
        /// At least one corpus's upload leg failed outright (nothing committed for it).
        var uploadFailed = false
        /// Every corpus that holds photos committed a manifest this pass. True for a device with no
        /// own photos at all — there is nothing to commit and nothing that could be stranded.
        var routeCommitted = true
        /// How many photos a FULL-verification pass could not read across all corpora, or nil when
        /// this pass did not verify (the ambient launch pass reads almost nothing, so it has no
        /// verdict — recording its near-zero count would overwrite the last full pass's real one).
        /// Non-zero means the pass committed but is NOT clean: those photos may be missing from
        /// the backup or stale in it, and only a pass that reads every byte can say which.
        var verifiedUnreadable: Int?
        /// The Phase 2.1 per-corpus format verdicts, or nil when this pass has none: populated
        /// ONLY by full-verification passes (the `verifiedUnreadable` precedent — an ambient pass
        /// reads almost nothing, so it has no verdict), and nil for a pass that never ran at all
        /// (preference off / DEBUG skip / teardown-epoch guard).
        var corpusVerdicts: [SealedPhotoCorpusFormatVerdict]?
    }

    /// The launch/adopt seam: restore anything this device is missing, then upload anything the
    /// cloud is missing. A no-op unless the own-photo backup is on.
    ///
    /// **Deliberately NOT gated on `iCloudSyncEnabled`.** The enable pass never was (a sealed backup
    /// is a separate opt-in from day-blob sync, and refusing would make the toggle silently do
    /// nothing for a user who keeps sync off), and gating only the AMBIENT pass produced a trap: a
    /// sync-off user got exactly one upload attempt, ever, with no retry from launch and none from
    /// the banner's Retry — while the key was device-bound on the strength of it. One explicit
    /// opt-in governs one route; that is the whole consent story for these records.
    ///
    /// `preferenceOverride` lets the enable flow run the pass in the same turn it decides to switch
    /// on, before the preference has been persisted.
    ///
    /// `fullVerification` distinguishes the two upload shapes, and the difference is a launch-cost
    /// decision, not a detail: a FULL pass reads and hashes every photo (correct, but on a large
    /// library that is hundreds of megabytes of decrypt on the main actor), while the ambient launch
    /// pass compares ID SETS only and reads bytes exclusively for ids the cloud does not have. Full
    /// runs on enable and on the user's explicit Retry; launch is incremental. The honest cost is in
    /// `SealedPhotoBackupService.reconcile`: a photo replaced in place under the same id waits for
    /// the next full pass.
    func synchronize(
        preferenceOverride: Bool = false,
        fullVerification: Bool = false
    ) async -> PassResult {
        var pass = PassResult()
        // DEBUG-only (this guard fronts the UPLOAD path as well as the restore), so it cannot be
        // triggered in a shipping binary.
        #if DEBUG
        guard ProcessInfo.processInfo.environment["FERNLET_SKIP_SEALED_RESTORE"] != "1" else { return pass }
        #endif
        let prefs = StoragePreferencesStore.currentPreferences()
        guard preferenceOverride || prefs.sealedBackupOwnPhotosEnabled else { return pass }

        // Marks a coordinator pass as in flight for `synchronizeFullyVerified`'s guard — the
        // migration wrapper must never overlap the launch-ambient pass in the manifest's
        // last-writer-wins race. Owned only when this call set it, so the wrapper's own funded
        // passes (which run under ITS flag) do not clear it mid-run.
        let ownsInFlightFlag = !passInFlight
        if ownsInFlightFlag { passInFlight = true }
        defer { if ownsInFlightFlag { passInFlight = false } }

        if fullVerification { pass.verifiedUnreadable = 0 }
        var restoredTotal = 0
        var attention: SealedBackupRestoreOutcome?
        var verdicts: [SealedPhotoCorpusFormatVerdict] = []
        for corpus in SealedPhotoCorpus.allCases {
            let result = await synchronize(corpus: corpus, fullVerification: fullVerification)
            if case .restored(let count) = result.outcome { restoredTotal += count }
            // First corpus that needs the user's attention speaks for the pass — one switch, one
            // status line. The audit log keeps the per-corpus detail.
            if result.outcome.needsAttention, attention == nil { attention = result.outcome }
            if result.uploadFailed { pass.uploadFailed = true }
            if !result.committed { pass.routeCommitted = false }
            if fullVerification { pass.verifiedUnreadable = (pass.verifiedUnreadable ?? 0) + result.unreadable }
            // Only a full pass has format evidence worth a verdict; an ambient pass reads almost
            // nothing, and a verdict built from it would score "never looked" as an answer.
            if fullVerification {
                verdicts.append(SealedPhotoCorpusFormatVerdict(
                    corpus: corpus,
                    committed: result.committed,
                    examined: result.examined,
                    observedMinima: result.observedMinima,
                    unreadable: result.unreadable,
                    healedEntries: result.healedEntries
                ))
            }
        }
        if fullVerification { pass.corpusVerdicts = verdicts }
        host.recordOwnPhotoBackupOutcome(
            attention ?? (restoredTotal > 0 ? .restored(restoredTotal) : .nothingToRestore)
        )
        host.recordOwnPhotoBackupUploadFailed(pass.uploadFailed)
        // Only a full pass carries a verification verdict; an ambient pass leaves the last full
        // pass's count standing rather than overwriting it with a count of bytes it never read.
        if let verifiedUnreadable = pass.verifiedUnreadable {
            host.recordOwnPhotoBackupVerifiedUnreadable(verifiedUnreadable)
        }
        // The proof the binding gate consults. Written on every pass so a route that later stops
        // committing (quota, revoked account) stops satisfying the gate for a device that has not
        // bound yet — binding is one-way, so the gate has to be right BEFORE it fires, not after.
        OwnPhotoEscrowCommitLedger(defaults: defaults).record(committed: pass.routeCommitted)
        return pass
    }

    /// The user-visible full pass, routed through the Phase 2.1 format-migration loop while its
    /// latch is open. Latch complete → one plain full pass (the latch never eats the user's
    /// verification). Latch open → the same tap funds up to
    /// `SealedPhotoBackupFormatMigrator.maxMigrationPasses` full passes: one that heals, one that
    /// confirms the heal by read-back and latches.
    ///
    /// MERGE SEMANTICS (explicit — never "last pass wins"): the confirming pass exists only for
    /// the latch policy, so its transient failure must never un-prove a healing pass that
    /// committed. The returned `PassResult` is the LAST pass with `!uploadFailed && routeCommitted`
    /// when one exists, else the last pass — so the enable decision reflects "some pass this run
    /// committed with no upload failure", while a run in which every pass failed still reports the
    /// failure. Because every underlying `synchronize` writes host state + the commit ledger per
    /// pass, this wrapper RE-RECORDS after the loop from the merged view: the commit ledger from
    /// "did ANY pass commit" (a confirming-pass blip must not unsatisfy the binding gate a
    /// committed heal just satisfied — within one run; across runs the ledger stays per-pass
    /// re-derived as its doc demands), and the host's upload-failed / verified-unreadable facts
    /// from the effective pass — the banner never asserts "your photos may not be in iCloud" about
    /// photos a pass this run committed. A confirming-pass failure maps only to "latch blocked
    /// (indeterminate)", never to an upload-failure verdict.
    ///
    /// Invoked from `setEnabled(true)` (with `preferenceOverride: true`) and from
    /// `FernletStore.restoreSealedBackupsIfNeeded(userInitiated: true)`. Never from launch-ambient
    /// code — owner decision D3: no silent whole-library decrypt.
    func synchronizeFullyVerified(preferenceOverride: Bool = false) async -> PassResult {
        // One pass-run at a time per coordinator (see `passInFlight`): a refused call is a no-op,
        // never a queued one — the tap that is already running covers it.
        guard !passInFlight else {
            FernletAuditLog.log("sealedPhoto.hashMigration.refusedPassInFlight")
            return PassResult()
        }
        passInFlight = true
        defer { passInFlight = false }
        let latch = SealedPhotoBackupMigrationLatch(defaults: defaults)
        guard !latch.isComplete else {
            // The migration has done its part on this device; the user's tap still buys the real
            // full-verification pass it always did (pinned: the latch never eats the verification).
            lastFullPassBlockedOnlyByOtherDevices = false
            let pass = await synchronize(preferenceOverride: preferenceOverride, fullVerification: true)
            #if DEBUG
            retainDebugFullPass(pass)
            #endif
            return pass
        }
        let epoch = teardownEpoch
        let migrator = SealedPhotoBackupFormatMigrator(latch: latch) {
            // The between-pass teardown guard: a delete-all that landed since this run started
            // turns every remaining funded pass into a no-op (nil verdicts → never clean, no
            // progress) instead of re-uploading the backup the user just destroyed.
            guard self.teardownEpoch == epoch else { return PassResult() }
            return await self.synchronize(preferenceOverride: preferenceOverride, fullVerification: true)
        }
        let complete = await migrator.run()
        guard teardownEpoch == epoch else {
            // Teardown moved under the run. Reset covers the narrow interleave between a clean
            // pass's return and `markComplete`; the merge re-records below are SKIPPED so
            // teardown's own `committed: false` record stands.
            latch.reset()
            lastFullPassBlockedOnlyByOtherDevices = false
            return PassResult()
        }
        let passes = migrator.underlyingPasses
        // The latch guard above means the loop ran at least one pass.
        assert(!passes.isEmpty, "the latch-open branch always funds at least one pass")
        // Only passes that actually RAN (a full pass always carries verdicts) are evidence. A
        // no-op shape (preference off / DEBUG skip) carries `PassResult()`'s defaults —
        // `routeCommitted == true` among them — so letting it into the merge would re-record a
        // committed route off a pass that did nothing, and the binding gate consults that ledger.
        let ranPasses = passes.filter { $0.corpusVerdicts != nil }
        let effective = ranPasses.last(where: { !$0.uploadFailed && $0.routeCommitted })
            ?? ranPasses.last
            ?? passes.last
            ?? PassResult()
        let lastTally = SealedPhotoBackupMigrationPassResult(pass: passes.last ?? PassResult())
        logMigrationRunOutcome(complete: complete, lastTally: lastTally, passCount: passes.count)
        lastFullPassBlockedOnlyByOtherDevices = !complete && isBlockedOnlyByForeignEntries(lastTally)
        // The merge re-records (see MERGE SEMANTICS above). Skipped entirely when nothing ran —
        // a no-op records nothing, exactly as a lone no-op `synchronize` records nothing.
        if !ranPasses.isEmpty {
            OwnPhotoEscrowCommitLedger(defaults: defaults).record(
                committed: ranPasses.contains { $0.routeCommitted }
            )
            host.recordOwnPhotoBackupUploadFailed(effective.uploadFailed)
            host.recordOwnPhotoBackupVerifiedUnreadable(effective.verifiedUnreadable ?? 0)
        }
        #if DEBUG
        retainDebugFullPass(effective)
        #endif
        return effective
    }

    #if DEBUG
    /// The last full-verification pass's per-corpus format verdicts, retained for the Phase 3 gate
    /// readout. Nothing shipping reads it.
    ///
    /// Taken from the RETURNED `PassResult.corpusVerdicts` — set inside
    /// `synchronize(preferenceOverride:fullVerification:)`, which BOTH legs of
    /// ``synchronizeFullyVerified(preferenceOverride:)`` reach — and deliberately NOT from
    /// `lastTally.verdicts`, which the latch guard returns before ever reaching. On a LATCHED device
    /// (the very device the Phase 3 sitting is taken from) the latter site never runs, so it would
    /// have left this permanently nil exactly where the corroboration is wanted.
    private(set) var lastFullPassVerdicts: [SealedPhotoCorpusFormatVerdict]?
    /// When the last full-verification pass returned. `synchronizeFullyVerified` refuses to overlap
    /// itself and a refused call is a SILENT no-op, so without this the readout cannot tell "pass
    /// running" from "pass refused" from "no pass this process".
    private(set) var lastFullPassCompletedAt: Date?
    /// Read-only mirror of the private in-flight flag, for the readout's disable rule.
    var debugPassInFlight: Bool { passInFlight }

    /// Retains a finished full pass's DEBUG evidence.
    private func retainDebugFullPass(_ pass: PassResult) {
        lastFullPassVerdicts = pass.corpusVerdicts
        lastFullPassCompletedAt = Date()
    }
    #endif

    /// Whether a blocked tally has the §C4 "nothing wrong on this device" shape: committed and
    /// examined everywhere, nothing unreadable, nothing left to heal, no failed leg — and at least
    /// one observed manifest minimum still legacy, i.e. a carried-forward entry only its owning
    /// device can heal. That state must not render as an endlessly-retryable pending check.
    private func isBlockedOnlyByForeignEntries(_ tally: SealedPhotoBackupMigrationPassResult) -> Bool {
        guard let verdicts = tally.verdicts, !tally.uploadFailed, tally.routeCommitted else { return false }
        let thisDeviceClean = verdicts.allSatisfy {
            $0.committed && $0.examined && $0.unreadable == 0 && $0.healedEntries == 0
        }
        let sawForeignLegacy = verdicts.contains { verdict in
            verdict.observedMinima.contains { $0 < SealedPhotoManifest.Entry.currentHashVersion }
        }
        return thisDeviceClean && sawForeignLegacy
    }

    /// Audit-trail line for one wrapper run (nothing-silent): `latched` on success, else `blocked`
    /// with the reason buckets a diagnosing reader needs — how many photos were unreadable, how
    /// many corpora were never examined or never committed, whether any observed manifest minimum
    /// is still legacy, and whether the last pass made forward progress.
    private func logMigrationRunOutcome(
        complete: Bool,
        lastTally: SealedPhotoBackupMigrationPassResult,
        passCount: Int
    ) {
        guard !complete else {
            FernletAuditLog.log("sealedPhoto.hashMigration.latched", context: [
                "passes": String(passCount)
            ])
            return
        }
        let verdicts = lastTally.verdicts ?? []
        FernletAuditLog.log("sealedPhoto.hashMigration.blocked", context: [
            "passes": String(passCount),
            "unreadable": String(verdicts.reduce(0) { $0 + $1.unreadable }),
            "notExamined": String(verdicts.filter { !$0.examined }.count),
            "indeterminateCorpora": String(verdicts.filter { !$0.committed }.count),
            "minimumBelowTarget": String(verdicts.filter { verdict in
                verdict.observedMinima.contains { $0 < SealedPhotoManifest.Entry.currentHashVersion }
            }.count),
            "noProgress": String(!lastTally.madeForwardProgress)
        ])
    }

    /// What one corpus's pass did.
    private struct CorpusResult {
        var outcome: SealedBackupRestoreOutcome = .nothingToRestore
        /// The upload leg threw (or was skipped on an unreadable index): nothing was committed.
        var uploadFailed = false
        /// This corpus has a committed cloud copy of what it holds — true when the upload committed,
        /// and vacuously true when the corpus holds nothing to commit.
        var committed = true
        /// Photos the upload leg could not read (`SealedPhotoUploadSummary.unreadable`): the
        /// manifest still committed, but this device could not vouch for these — their existing
        /// cloud entries were kept, and any without one never entered the backup at all.
        var unreadable = 0
        /// A leg of this pass reached a manifest read and got an answer — the restore leg's
        /// `service.restore` (nil = proof no manifest exists) or the reconcile's `openManifest`.
        /// False = never looked, which blocks the migration latch (`SealedPhotoCorpusFormatVerdict`).
        var examined = false
        /// Every `minimumEntryHashVersion` either leg observed for this corpus, in observation
        /// order (restore open, reconcile open, reconcile commit).
        var observedMinima: [Int] = []
        /// Entries whose recorded hash version rose 1 → 2 this pass
        /// (`SealedPhotoUploadSummary.healedEntries`).
        var healedEntries = 0
    }

    /// One corpus: restore into it when it needs restoring, then upload from it when it has
    /// something to say.
    ///
    /// "Needs restoring" is three cases, not one:
    /// 1. the corpus is EMPTY **and this device has never uploaded to it** — an empty corpus is
    ///    "not restored yet" only for a device that has not participated. A device whose upload
    ///    ledger exists and is now empty is empty for the opposite reason: the user deleted their
    ///    photos. Restoring there would write every deleted photo back to disk as an unreferenced
    ///    orphan — invisible, undeletable, and re-uploaded forever (see
    ///    ``OwnPhotoUploadLedger/hasUploaded(for:)``);
    /// 2. the corpus holds files but nothing this install can OPEN — the device-backup-onto-a-new-
    ///    phone case, where a presence-only gate would decline the restore the route exists for;
    /// 3. a previous restore left ids behind (``OwnPhotoRestoreRepairLedger``) — those ids are
    ///    re-fetched even though the corpus is now emphatically non-empty, because the restore
    ///    itself is what made it non-empty.
    ///
    /// The upload guard is the same invariant seen from the other side. A corpus that is empty and
    /// has nothing to prune is left alone: `reconcile` writes a manifest even for an empty id set,
    /// so exporting from a device that has not restored yet would replace the committed set with
    /// nothing. But an empty corpus with a NON-empty upload ledger has exactly one thing to say —
    /// "the ids I put there are gone" — and saying it is how a delete reaches the backup at all.
    private func synchronize(
        corpus: SealedPhotoCorpus,
        fullVerification: Bool
    ) async -> CorpusResult {
        let access = access(for: corpus)
        var result = CorpusResult()
        let uploadLedger = OwnPhotoUploadLedger(defaults: defaults)
        let repairIDs = OwnPhotoRestoreRepairLedger(defaults: defaults).pendingIDs(for: corpus)
        let needsFullRestore = access.isEmpty()
            ? !uploadLedger.hasUploaded(for: corpus)
            : access.holdsOnlyUnopenableFiles()
        if needsFullRestore || !repairIDs.isEmpty {
            let restored = await restore(
                corpus: corpus,
                access: access,
                limitedTo: needsFullRestore ? nil : repairIDs
            )
            result.outcome = restored.outcome
            // The restore leg is the only honest source of "no committed manifest exists" — a nil
            // `service.restore` return — so its examined/observed facts feed the format verdict
            // even when the outcome below stops the corpus.
            if restored.examined { result.examined = true }
            observeManifestMinimum(restored.observedMinimum, corpus: corpus, into: &result)
            switch result.outcome {
            case .notRecognized, .rolledBack, .deferredKeyNotSynced, .deferredTransient, .deferredLocked:
                // Nothing here is fixable by uploading, and a corpus we could not fully restore must
                // not have its (possibly larger) cloud set rewritten from this device's partial one.
                // Leaving the cloud copy alone is the whole point of a retryable restore failure.
                result.committed = false
                return result
            case .restored, .nothingToRestore, .skippedStoreNotEmpty:
                break
            }
        }
        // Never upload from an empty corpus that has nothing to prune: `reconcile` writes a manifest
        // even for an empty id set, so an export from a device that has not restored yet would
        // replace the committed set with nothing. Skipping is recoverable (upload from a device that
        // still holds the photos, or after this one restores); an empty overwrite is not. Nothing to
        // commit is not a failure.
        //
        // An empty corpus WITH prunable ids is the deletion case and must run: those are ids this
        // device itself put in the manifest and has since deleted locally, and the reconcile's
        // union still carries every other device's entry forward untouched. Once pruned the ledger
        // holds an empty (but present) list, so this runs exactly once per emptying on AMBIENT
        // passes.
        //
        // On FULL-verification passes an emptied-after-upload corpus (present-but-empty ledger) IS
        // admitted: its `ids = []` / empty-prunable reconcile is provably inert — `sealChangedPhotos`
        // over nothing returns nothing, the carry-forward preserves every committed entry verbatim,
        // and the commit re-propagates the marker — and running it is what keeps the corpus's
        // manifest EXAMINED, so the migration latch can set or block on the truth instead of
        // treadmilling on a corpus this device stopped looking at forever.
        guard !access.isEmpty() || !uploadLedger.uploadedIDs(for: corpus).isEmpty
            || (fullVerification && uploadLedger.hasUploaded(for: corpus)) else { return result }
        // The enumeration-failure signal (nil = the directory exists but cannot be listed): skip
        // the reconcile rather than feed it an empty id view — which would carry everything
        // forward unread AND, with a non-empty prunable set, prune this device's own committed
        // entries while their files sit intact-but-unlistable on disk. Indeterminate, like
        // `reconcileSkippedUnreadableIndex`: uncommitted, unexamined, retried next pass.
        guard let localIDs = access.ids() else {
            FernletAuditLog.log("sealedPhoto.reconcileSkippedUnlistableCorpus", context: ["corpus": corpus.rawValue])
            result.uploadFailed = true
            result.committed = false
            return result
        }
        let upload = await reconcile(
            corpus: corpus,
            ids: localIDs,
            access: access,
            fullVerification: fullVerification
        )
        result.uploadFailed = !upload.committed
        result.committed = upload.committed
        if let summary = upload.summary {
            // A returned summary means the reconcile opened the manifest slot and committed —
            // the reconcile leg's half of the manifest observation.
            result.unreadable = summary.unreadable
            result.healedEntries = summary.healedEntries
            result.examined = true
            observeManifestMinimum(summary.openedManifestMinimumHashVersion, corpus: corpus, into: &result)
            observeManifestMinimum(summary.committedManifestMinimumHashVersion, corpus: corpus, into: &result)
        }
        return result
    }

    /// Threads one manifest-minimum observation into the corpus result AND runs the Phase 2.1
    /// latch invalidation: any pass — ambient included — that observes a manifest whose minimum is
    /// still the legacy value has just seen a foreign (or pre-marker) write the latch's proof did
    /// not cover, so the latch resets. Unconditional reset (a no-op while the latch is closed,
    /// which is every pass of the migrator's own healing run); the audit line fires only when a
    /// set latch was actually invalidated, so the trail never claims an invalidation that did not
    /// happen. Nil (no manifest observed at this point) records nothing.
    private func observeManifestMinimum(
        _ minimum: Int?,
        corpus: SealedPhotoCorpus,
        into result: inout CorpusResult
    ) {
        guard let minimum else { return }
        result.observedMinima.append(minimum)
        guard minimum == SealedPhotoManifest.Entry.legacyHashVersion else { return }
        let latch = SealedPhotoBackupMigrationLatch(defaults: defaults)
        if latch.isComplete {
            FernletAuditLog.log("sealedPhoto.hashMigration.invalidatedByForeignWrite", context: [
                "corpus": corpus.rawValue,
                "minimum": String(minimum)
            ])
        }
        latch.reset()
    }

    /// Pulls a corpus down from the escrow backup.
    ///
    /// Returns the outcome plus the leg's Phase 2.1 manifest observation: whether the manifest
    /// slot was actually reached (`service.restore` returning nil is the one honest source of "no
    /// committed manifest exists"), and the opened manifest's minimum when there was one. A leg
    /// that failed before the manifest read reports `examined: false` — absence of evidence,
    /// which the migration latch treats as blocking.
    ///
    /// - Parameter limitedTo: When non-nil, only these manifest ids are fetched — the REPAIR pass
    ///   for photos a previous restore could not land. Nil restores the whole committed set.
    private func restore(
        corpus: SealedPhotoCorpus,
        access: CorpusAccess,
        limitedTo: Set<UUID>? = nil
    ) async -> (outcome: SealedBackupRestoreOutcome, examined: Bool, observedMinimum: Int?) {
        guard let prepared = makeIdentity(escrowMode: .forOpening) else {
            FernletAuditLog.log("sealedPhoto.restoreNotProvisioned", context: ["corpus": corpus.rawValue])
            return (.deferredTransient, examined: false, observedMinimum: nil)
        }
        // The open path must never MINT an escrow key (WS-1): absence is the honest "iCloud Keychain
        // has not synced yet", retried next launch.
        guard prepared.escrowReady else {
            FernletAuditLog.log("sealedPhoto.restoreDeferredKeyNotSynced", context: ["corpus": corpus.rawValue])
            return (.deferredKeyNotSynced, examined: false, observedMinimum: nil)
        }
        let service = makeService(identity: prepared.identity)
        let repairLedger = OwnPhotoRestoreRepairLedger(defaults: defaults)
        do {
            guard let summary = try await service.restore(
                corpus: corpus,
                limitedTo: limitedTo,
                write: access.write
            ) else {
                // No manifest at all: nothing was ever committed, so there is nothing left owed.
                // Examined with no minimum — the vacuous evidence the migration latch accepts.
                repairLedger.clear(corpus)
                return (.nothingToRestore, examined: true, observedMinimum: nil)
            }
            let observedMinimum = summary.manifestMinimumEntryHashVersion
            // The sidecar lands AFTER the bytes, and ONLY once some bytes have landed. An index that
            // named photos not yet on disk would render a timeline of missing pictures — and, worse,
            // writing it is what makes the progress corpus permanently "not empty", so a pass where
            // NO body arrived would poison the emptiness gate and lock the corpus out of the very
            // restore it still needs. It comes from the summary — i.e. from the very manifest whose
            // generation was just checked — not from a second fetch that could be served an
            // older-but-authentic index. `restoreIndexPayload` re-checks emptiness at the write
            // point, so a raced local capture is never overwritten (and a repair pass finding the
            // index already correct is refused there, harmlessly).
            if access.carriesSidecar, summary.restored > 0, let sidecar = summary.sidecar,
               !access.restoreSidecar(sidecar) {
                FernletAuditLog.log("sealedPhoto.restoreSidecarRefused", context: ["corpus": corpus.rawValue])
            }
            guard summary.failed.isEmpty else {
                FernletAuditLog.log("sealedPhoto.restorePartial", context: [
                    "corpus": corpus.rawValue,
                    "restored": String(summary.restored),
                    "failed": String(summary.failed.count)
                ])
                // Remember exactly which ids are still owed. Without this the first successful write
                // makes the corpus non-empty, the emptiness gate closes, and those bodies can never
                // be fetched again on any launch or Retry — permanently unrecoverable while sitting
                // intact in the user's own iCloud.
                repairLedger.record(Set(summary.failed), for: corpus)
                // Some photos landed and some did not. Retryable rather than "restored": the missing
                // bodies may appear once the rest of the account syncs, and saying "restored" would
                // hide a partial recovery of exactly the data this route exists to protect.
                return (.deferredTransient, examined: true, observedMinimum: observedMinimum)
            }
            repairLedger.clear(corpus)
            return (
                summary.restored > 0 ? .restored(summary.restored) : .nothingToRestore,
                examined: true,
                observedMinimum: observedMinimum
            )
        } catch {
            // A throw may have happened before OR after the manifest read (a stale-generation
            // rejection opens it first), and the summary that would say which never came back —
            // so this leg conservatively reports "never examined", which blocks rather than
            // vouches.
            return (classify(error, corpus: corpus), examined: false, observedMinimum: nil)
        }
    }

    /// Uploads what this device holds and commits the manifest. Returns whether the commit
    /// succeeded — the caller turns a `false` into a visible, retryable status AND withholds the
    /// irreversible key binding, because an uncommitted route is not a route — plus the whole
    /// upload summary, so a committed-but-not-clean pass (unreadable photos, whose cloud entries
    /// were kept or never made) and the Phase 2.1 bookkeeping (healed entries, both manifest
    /// minima) stop being silently discarded. A nil summary means the reconcile never committed
    /// (skipped or thrown), so nothing about the manifest was proven.
    ///
    /// - Parameter ids: The corpus's local id set, resolved by the caller — which is also where
    ///   an unlistable directory (nil ids) is turned into an indeterminate skip before this runs.
    private func reconcile(
        corpus: SealedPhotoCorpus,
        ids: [UUID],
        access: CorpusAccess,
        fullVerification: Bool
    ) async -> (committed: Bool, summary: SealedPhotoUploadSummary?) {
        guard let prepared = makeIdentity(escrowMode: .forSealing) else {
            FernletAuditLog.log("sealedPhoto.reconcileNotProvisioned", context: ["corpus": corpus.rawValue])
            return (committed: false, summary: nil)
        }
        var sidecar: Data?
        if access.carriesSidecar {
            guard let payload = access.sidecar() else {
                // A present-but-unreadable index. Uploading the bodies without it would restore an
                // invisible timeline, and uploading an EMPTY index would destroy the dates and
                // captions in the cloud copy. Skip the corpus and retry next launch.
                FernletAuditLog.log("sealedPhoto.reconcileSkippedUnreadableIndex", context: ["corpus": corpus.rawValue])
                return (committed: false, summary: nil)
            }
            sidecar = payload
        }
        let service = makeService(identity: prepared.identity)
        let ledger = OwnPhotoUploadLedger(defaults: defaults)
        do {
            let summary = try await service.reconcile(
                corpus: corpus,
                ids: ids,
                sidecar: sidecar,
                verifyingContentHashes: fullVerification,
                // Prune scope: only ids this device uploaded before. Anything else in the manifest
                // belongs to the user's other phone (own photos never sync device-to-device), and
                // dropping it would delete their photos from their own backup.
                prunableIDs: ledger.uploadedIDs(for: corpus),
                photo: { access.plaintext($0) }
            )
            // Recorded only after the manifest commit succeeded: a ledger written ahead of a failed
            // upload would claim ownership of ids that never reached the cloud.
            ledger.recordUploaded(ids, for: corpus)
            return (committed: true, summary: summary)
        } catch {
            FernletAuditLog.log("sealedPhoto.reconcileFailed", context: ["corpus": corpus.rawValue])
            return (committed: false, summary: nil)
        }
    }

    /// Maps a restore failure onto the shared outcome vocabulary, matching
    /// `SealedBackupCoordinator.classifyRestoreFailure` so the banner reads the same for both routes.
    private func classify(_ error: Error, corpus: SealedPhotoCorpus) -> SealedBackupRestoreOutcome {
        switch error {
        case SealedBackupError.keyAgreementIdentityMismatch:
            FernletAuditLog.log("sealedPhoto.restoreNotRecognized", context: ["corpus": corpus.rawValue])
            return .notRecognized
        case SealedBackupError.staleGeneration(let found, let lastSeen):
            FernletAuditLog.log("sealedPhoto.restoreRolledBack", context: [
                "corpus": corpus.rawValue, "found": String(found), "lastSeen": String(lastSeen)
            ])
            return .rolledBack
        case IdentityError.notProvisioned:
            return .deferredKeyNotSynced
        default:
            FernletAuditLog.log("sealedPhoto.restoreFailed", context: ["corpus": corpus.rawValue])
            return .deferredTransient
        }
    }

    // MARK: - Teardown

    /// Deletes every own-photo escrow record — all three corpora, bodies and manifests — and reports
    /// whether every corpus cleared.
    ///
    /// Used by both the "turn it off" ceremony and the "delete everything" funnel, where it must run
    /// BEFORE the local wipe: the records are addressed by corpus name (not by anything the local
    /// stores hold), but the enable PREFERENCE is what tells the funnel there is anything to delete,
    /// and the preference reset comes later in the same funnel.
    ///
    /// Needs no escrow key — deletion is by record name — so it works while the app is locked, like
    /// every other leg of the wipe.
    ///
    /// - Note: deliberately NOT `@discardableResult` (Power-of-10 R7): "every corpus cleared" is a
    ///   success/failure signal the delete-all dialog reports to the user verbatim.
    func tearDownForDeleteAll() async -> Bool {
        // FIRST, before any await: invalidate every funded migration pass still in flight (see
        // `teardownEpoch`) — a heal that lands after this line must not re-upload, or re-latch
        // over, the backup this call is deleting. The session verdict goes with it: a "blocked by
        // your other device" line about a route that no longer exists is not a status.
        teardownEpoch += 1
        lastFullPassBlockedOnlyByOtherDevices = false
        #if DEBUG
        // The retained verdicts describe manifests this call is deleting; they go with them, on the
        // same teardown-epoch rule their sibling above already follows.
        lastFullPassVerdicts = nil
        lastFullPassCompletedAt = nil
        #endif
        let cloud = makeCloudService()
        var allCleared = true
        for corpus in SealedPhotoCorpus.allCases {
            do {
                try await cloud.deleteSealedPhotoCorpus(corpus)
            } catch {
                allCleared = false
                FernletAuditLog.log("sealedPhoto.teardownFailed", context: ["corpus": corpus.rawValue])
            }
        }
        // The rollback high-water marks die with the records they describe: keeping them would make
        // the user's own next backup (which mints generation 1 again) look like a rollback attack.
        var generationStore = SealedBackupGenerationStore(defaults: defaults)
        generationStore.resetPhotoNamespace()
        // ...and so does the upload ledger: with the manifest gone there is nothing left for this
        // device to claim ownership of, and a stale claim would scope a future prune wrongly.
        OwnPhotoUploadLedger(defaults: defaults).reset()
        // ...and the restore-repair ledger: ids owed by a backup that no longer exists can never be
        // fetched, and keeping them would make every later pass report a permanent partial restore.
        OwnPhotoRestoreRepairLedger(defaults: defaults).reset()
        // ...and the commit proof. The route is gone, so it no longer evidences anything. (This
        // does not un-bind an already-bound key — that is one-way by design — it only stops a
        // torn-down route from satisfying the gate for a device that has not bound yet.)
        OwnPhotoEscrowCommitLedger(defaults: defaults).record(committed: false)
        // ...and the hash-version migration latch: the manifests it makes a claim about die with
        // this call, so keeping it would carry a proof about destroyed objects onto a future
        // re-enable's brand-new lineage. (The deliberate mirror-image of
        // `ownPhotoKeyMigrationComplete`'s kept row, whose subject — the re-sealed local files —
        // survives the wipe. Docs/PrivacyWipeCoverage.md + PersistedSurfaceWipeBoundaryTests.)
        SealedPhotoBackupMigrationLatch(defaults: defaults).reset()
        return allCleared
    }
}

/// The device-local record of which photo ids a restore has attempted and **failed** to land, per
/// corpus — the input to the next pass's repair restore.
///
/// **Why it has to exist.** The escrow restore is gated on the corpus being empty (or holding
/// nothing this install can open), and the restore itself is what makes the corpus non-empty. Since
/// per-photo failures are isolated by design — a fetch that drops out after photo 400 of 500 leaves
/// 100 ids unrestored — the gate closes behind a partial restore and those 100 bodies can never be
/// fetched again on any launch or Retry, even though they sit intact in the user's iCloud and are
/// carried forward in the manifest indefinitely. The only remedy the UI would otherwise offer is
/// destructive (turning the backup off deletes the cloud records). This ledger is the non-destructive
/// remedy: the ids are remembered, and the next pass re-fetches exactly them.
///
/// Cleared when a restore completes with nothing failed, and torn down with the route itself. Losing
/// it (reinstall, wipe) fails SAFE — a reinstalled device has an empty corpus, so the ordinary
/// full restore covers everything.
///
/// Device-local and never synced, holding photo IDs only — never bytes, never captions.
///
/// Concurrency: a nonisolated value type over `UserDefaults` (itself thread-safe); callers are
/// main-actor confined.
struct OwnPhotoRestoreRepairLedger {
    private let defaults: UserDefaults

    /// Creates a ledger over `defaults`; tests inject an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The ids a previous restore left owed for `corpus`, or empty when it completed.
    func pendingIDs(for corpus: SealedPhotoCorpus) -> Set<UUID> {
        let raw = defaults.stringArray(forKey: Self.key(for: corpus)) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    /// Records the ids a restore could not land, replacing the previous set — the pass that just ran
    /// attempted exactly the ids it was asked for, so its failures ARE the outstanding set.
    func record(_ ids: Set<UUID>, for corpus: SealedPhotoCorpus) {
        guard !ids.isEmpty else { return clear(corpus) }
        defaults.set(ids.map(\.uuidString), forKey: Self.key(for: corpus))
    }

    /// Clears the outstanding set for `corpus` — a restore that failed nothing owes nothing.
    func clear(_ corpus: SealedPhotoCorpus) {
        defaults.removeObject(forKey: Self.key(for: corpus))
    }

    /// Clears every corpus's outstanding set (route teardown).
    func reset() {
        for corpus in SealedPhotoCorpus.allCases { clear(corpus) }
    }

    private static func key(for corpus: SealedPhotoCorpus) -> String {
        "fernlet.sealedPhoto.restoreRepairIDs.\(corpus.rawValue)"
    }
}

/// The device-local proof that the own-photo escrow route has actually **committed** — i.e. the last
/// pass wrote a manifest for every corpus that holds photos, with no upload failure.
///
/// **Why a preference is not enough.** `OwnPhotoKeyBinder`'s second gate half asks whether the user
/// has a way to get these photos onto a replacement phone, and the answer irreversibly device-binds
/// the own-photos key. A preference records intent, not arrival: a user who flips the switch while
/// offline, signed out of iCloud, over quota, or against a CloudKit schema that does not yet carry
/// the record type has a toggle that reads ON and zero bytes in iCloud. Binding on that takes away
/// the device-backup route without having built the replacement, one-way, with nothing in the UI to
/// say so. So the gate consults this instead, and the launch path does too — the launch path is
/// where a bare preference would otherwise bind on its word alone on every subsequent boot.
///
/// One bit, device-local, never synced (it is a fact about THIS device's uploads), and re-derived by
/// every pass rather than latched: a route that stops committing stops satisfying the gate for a
/// device that has not bound yet. It never un-binds anything.
///
/// Concurrency: a nonisolated value type over `UserDefaults` (itself thread-safe).
struct OwnPhotoEscrowCommitLedger {
    /// The `UserDefaults` key holding the proof.
    static let defaultsKey = "fernlet.sealedPhoto.routeCommitted"

    private let defaults: UserDefaults

    /// Creates a ledger over `defaults`; tests inject an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the route has a committed cloud copy of this device's photos. Absent reads as false —
    /// the fail-closed direction, so silence never binds.
    var isCommitted: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    /// Records a pass's verdict.
    func record(committed: Bool) {
        defaults.set(committed, forKey: Self.defaultsKey)
    }
}

/// The device-local record of which photo ids THIS device has uploaded, per corpus — the input to
/// the upload path's prune scope.
///
/// **Why it has to exist.** Own photos are device-local files that no sync carries between devices,
/// so an id in the cloud manifest that this device does not have is at least as likely to be the
/// user's other phone's photo as a deletion. Without this ledger the upload would have to choose
/// between destroying the other device's photos (prune everything unknown) and never removing a
/// deleted photo (prune nothing). With it, the rule is exactly right: this device may remove what it
/// put there, and nothing else.
///
/// Device-local and never synced, by construction — the same per-device ledger pattern as
/// `SealedBackupGenerationStore` and `WorkoutTombstoneStore`. It holds photo IDs, never bytes and
/// never captions. Losing it (reinstall, wipe) fails SAFE: the device simply stops pruning until it
/// has uploaded again, so the worst case is a photo lingering in the user's own encrypted backup —
/// and "delete everything" tears the whole route down regardless.
///
/// Concurrency: a nonisolated value type over `UserDefaults` (itself thread-safe); callers are
/// main-actor confined.
struct OwnPhotoUploadLedger {
    private let defaults: UserDefaults

    /// Creates a ledger over `defaults`; tests inject an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The ids this device uploaded on its last successful pass for `corpus`.
    func uploadedIDs(for corpus: SealedPhotoCorpus) -> Set<UUID> {
        let raw = defaults.stringArray(forKey: Self.key(for: corpus)) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    /// Whether this device has ever committed an upload for `corpus` — **presence** of the record,
    /// not its contents, which is why this is not `!uploadedIDs.isEmpty`.
    ///
    /// It is the difference between the two reasons a corpus can be empty, and the route behaves
    /// oppositely for them. Never uploaded ⇒ empty because this device has not restored yet, so
    /// restore into it. Uploaded before, and now empty ⇒ the user DELETED their photos, so restoring
    /// would write every one of them back to disk as an orphan that nothing references, renders
    /// nowhere, and cannot be removed through any UI — "delete my food photos" silently undoing
    /// itself on relaunch. A pass that has pruned down to nothing writes an EMPTY id list here
    /// rather than removing the record, so this stays true and the corpus is never resurrected.
    func hasUploaded(for corpus: SealedPhotoCorpus) -> Bool {
        defaults.object(forKey: Self.key(for: corpus)) != nil
    }

    /// Records the ids this device has just committed for `corpus`, replacing the previous set.
    func recordUploaded(_ ids: [UUID], for corpus: SealedPhotoCorpus) {
        defaults.set(ids.map(\.uuidString), forKey: Self.key(for: corpus))
    }

    /// Clears every corpus's record — wired into the route's teardown, so a torn-down backup does not
    /// leave this device believing it still owns ids in a manifest that no longer exists.
    func reset() {
        for corpus in SealedPhotoCorpus.allCases {
            defaults.removeObject(forKey: Self.key(for: corpus))
        }
    }

    private static func key(for corpus: SealedPhotoCorpus) -> String {
        "fernlet.sealedPhoto.uploadedIDs.\(corpus.rawValue)"
    }
}
