import ProximityKit
import CloudKitSync
import FernletFoundation
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
}

/// The opt-in own-photo escrow backup: policy, gating and ordering around
/// ``SealedPhotoBackupService`` (which is mechanism only).
///
/// What this type owns, and why each piece exists:
/// - **One user-facing switch, three corpora.** The preference is a single
///   `sealedBackupOwnPhotosEnabled`; meal / recipe / progress are internal record namespaces
///   (``SealedPhotoCorpus``), not three consent questions. They are all "your own photos".
/// - **Per-corpus no-clobber gate.** Own-photo ownership is scattered (`Meal.photoID`, the recipe
///   id, the progress index), so "is this device empty?" cannot be a whole-device check — it is a
///   per-corpus FILE-PRESENCE check (`isEmptyForRestore()` on each store), the same shape as the
///   sealed narratives' `isEmptyStoreForRestore`.
/// - **Restore before re-upload, always.** A device that has not restored yet is empty for exactly
///   the reason the backup exists, so uploading from it would replace the cloud copy with an empty
///   manifest. An empty corpus therefore NEVER uploads; it only ever restores.
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
        let ids: () -> [UUID]
        let plaintext: (UUID) -> Data?
        let write: (UUID, Data) -> Bool
        let isEmpty: () -> Bool
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

    private func legacyKeyProvider() -> KeychainPrivateMediaKeyProvider {
        KeychainPrivateMediaKeyProvider(role: .friendWall, mintsIfAbsent: false)
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
            legacyKeyProvider: legacyKeyProvider()
        )
    }

    private func progressStore() -> ProgressPhotoStore {
        ProgressPhotoStore(
            directory: OwnPhotoCorpusLayout.progressPhotosDirectory(in: documentsDirectory),
            keyProvider: ownKeyProvider(),
            legacyKeyProvider: legacyKeyProvider()
        )
    }

    private func access(for corpus: SealedPhotoCorpus) -> CorpusAccess {
        switch corpus {
        case .meal, .recipe:
            let store = mealStore(recipe: corpus == .recipe)
            return CorpusAccess(
                ids: { store.storedPhotoIDs() },
                plaintext: { store.imageData(for: $0) },
                write: { store.restoreSealedPhoto($1, forID: $0) },
                isEmpty: { store.isEmptyForRestore() },
                carriesSidecar: false,
                sidecar: { nil },
                restoreSidecar: { _ in true }
            )
        case .progress:
            let store = progressStore()
            return CorpusAccess(
                // Driven from the INDEX, not the directory: the index is the user-visible timeline,
                // and a byte file it does not name is an orphan nothing would render after a restore.
                ids: { store.records().map(\.id) },
                plaintext: { store.imageData(for: $0) },
                write: { store.restoreSealedPhoto($1, forID: $0) },
                isEmpty: { store.isEmptyForRestore() },
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
    /// holds). Disabling tears every corpus down — the destructive half, which is why the UI puts a
    /// WS-5 confirmation in front of it.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            guard makeIdentity(escrowMode: .forSealing) != nil else {
                FernletAuditLog.log("sealedPhoto.notProvisioned")
                return false
            }
            // Enabling is a FULL pass: every photo's bytes are read and hashed, so the first upload
            // is complete rather than id-set-shaped. It also runs with iCloud SYNC off, matching
            // `SealedBackupCoordinator.setSealedBackupEnabled` — a sealed backup is a separate opt-in
            // from day-blob sync, and refusing here would make the toggle silently do nothing for a
            // user who deliberately keeps sync off. (The AMBIENT pass still requires sync, also
            // matching that precedent.)
            await synchronize(preferenceOverride: true, fullVerification: true, requiringSync: false)
            return true
        }
        return await tearDownForDeleteAll()
    }

    /// The launch/adopt seam: restore anything this device is missing, then upload anything the
    /// cloud is missing. A no-op unless the own-photo backup is on — and, on the AMBIENT path, unless
    /// iCloud sync is on too (`requiringSync`), matching how `restoreSealedBackupsIfNeeded` gates the
    /// chunked route.
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
        fullVerification: Bool = false,
        requiringSync: Bool = true
    ) async {
        guard ProcessInfo.processInfo.environment["FERNLET_SKIP_SEALED_RESTORE"] != "1" else { return }
        let prefs = StoragePreferencesStore.currentPreferences()
        guard !requiringSync || prefs.iCloudSyncEnabled else { return }
        guard preferenceOverride || prefs.sealedBackupOwnPhotosEnabled else { return }

        var restoredTotal = 0
        var attention: SealedBackupRestoreOutcome?
        for corpus in SealedPhotoCorpus.allCases {
            let outcome = await synchronize(corpus: corpus, fullVerification: fullVerification)
            if case .restored(let count) = outcome { restoredTotal += count }
            // First corpus that needs the user's attention speaks for the pass — one switch, one
            // status line. The audit log keeps the per-corpus detail.
            if outcome.needsAttention, attention == nil { attention = outcome }
        }
        host.recordOwnPhotoBackupOutcome(
            attention ?? (restoredTotal > 0 ? .restored(restoredTotal) : .nothingToRestore)
        )
    }

    /// One corpus: restore into it if (and only if) it is empty, then upload from it if (and only
    /// if) it is not.
    ///
    /// The two guards are the same invariant seen from both sides — an empty corpus is "not restored
    /// yet", never "nothing to back up" — and they are re-evaluated around the restore, so a corpus
    /// that just filled up gets uploaded and one that stayed empty is left alone.
    private func synchronize(
        corpus: SealedPhotoCorpus,
        fullVerification: Bool
    ) async -> SealedBackupRestoreOutcome {
        let access = access(for: corpus)
        var outcome = SealedBackupRestoreOutcome.nothingToRestore
        if access.isEmpty() {
            outcome = await restore(corpus: corpus, access: access)
            switch outcome {
            case .notRecognized, .rolledBack, .deferredKeyNotSynced, .deferredTransient, .deferredLocked:
                // Nothing was written and nothing here is fixable by uploading; leaving the cloud
                // copy alone is the whole point of a terminal/retryable restore failure.
                return outcome
            case .restored, .nothingToRestore, .skippedStoreNotEmpty:
                break
            }
        }
        // NEVER upload from an empty corpus: `reconcile` writes a manifest even for an empty id set,
        // so an export from a device that has not restored yet would replace the committed set with
        // nothing. Skipping is recoverable (upload from a device that still holds the photos, or
        // after this one restores); an empty overwrite is not.
        guard !access.isEmpty() else { return outcome }
        await reconcile(corpus: corpus, access: access, fullVerification: fullVerification)
        return outcome
    }

    private func restore(corpus: SealedPhotoCorpus, access: CorpusAccess) async -> SealedBackupRestoreOutcome {
        guard let prepared = makeIdentity(escrowMode: .forOpening) else {
            FernletAuditLog.log("sealedPhoto.restoreNotProvisioned", context: ["corpus": corpus.rawValue])
            return .deferredTransient
        }
        // The open path must never MINT an escrow key (WS-1): absence is the honest "iCloud Keychain
        // has not synced yet", retried next launch.
        guard prepared.escrowReady else {
            FernletAuditLog.log("sealedPhoto.restoreDeferredKeyNotSynced", context: ["corpus": corpus.rawValue])
            return .deferredKeyNotSynced
        }
        let service = makeService(identity: prepared.identity)
        do {
            guard let summary = try await service.restore(corpus: corpus, write: access.write) else {
                return .nothingToRestore
            }
            // The sidecar lands AFTER the bytes: an index that named photos not yet on disk would
            // render a timeline of missing pictures. It comes from the summary — i.e. from the very
            // manifest whose generation was just checked — not from a second fetch that could be
            // served an older-but-authentic index. `restoreIndexPayload` re-checks emptiness at the
            // write point, so a raced local capture is never overwritten.
            if access.carriesSidecar, let sidecar = summary.sidecar, !access.restoreSidecar(sidecar) {
                FernletAuditLog.log("sealedPhoto.restoreSidecarRefused", context: ["corpus": corpus.rawValue])
            }
            guard summary.failed.isEmpty else {
                FernletAuditLog.log("sealedPhoto.restorePartial", context: [
                    "corpus": corpus.rawValue,
                    "restored": String(summary.restored),
                    "failed": String(summary.failed.count)
                ])
                // Some photos landed and some did not. Retryable rather than "restored": the missing
                // bodies may appear once the rest of the account syncs, and saying "restored" would
                // hide a partial recovery of exactly the data this route exists to protect.
                return .deferredTransient
            }
            return summary.restored > 0 ? .restored(summary.restored) : .nothingToRestore
        } catch {
            return classify(error, corpus: corpus)
        }
    }

    private func reconcile(
        corpus: SealedPhotoCorpus,
        access: CorpusAccess,
        fullVerification: Bool
    ) async {
        guard let prepared = makeIdentity(escrowMode: .forSealing) else {
            FernletAuditLog.log("sealedPhoto.reconcileNotProvisioned", context: ["corpus": corpus.rawValue])
            return
        }
        var sidecar: Data?
        if access.carriesSidecar {
            guard let payload = access.sidecar() else {
                // A present-but-unreadable index. Uploading the bodies without it would restore an
                // invisible timeline, and uploading an EMPTY index would destroy the dates and
                // captions in the cloud copy. Skip the corpus and retry next launch.
                FernletAuditLog.log("sealedPhoto.reconcileSkippedUnreadableIndex", context: ["corpus": corpus.rawValue])
                return
            }
            sidecar = payload
        }
        let service = makeService(identity: prepared.identity)
        let ledger = OwnPhotoUploadLedger(defaults: defaults)
        let localIDs = access.ids()
        do {
            try await service.reconcile(
                corpus: corpus,
                ids: localIDs,
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
            ledger.recordUploaded(localIDs, for: corpus)
        } catch {
            FernletAuditLog.log("sealedPhoto.reconcileFailed", context: ["corpus": corpus.rawValue])
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
    @discardableResult
    func tearDownForDeleteAll() async -> Bool {
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
        return allCleared
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
