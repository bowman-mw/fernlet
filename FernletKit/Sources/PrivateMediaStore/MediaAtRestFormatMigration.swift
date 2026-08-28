// MediaAtRestFormatMigration.swift
// PrivateMediaStore
//
// Phase 2.3 of Docs/Plan-Crypto-Standardization-2026-08-27.md for the `MediaAtRestCrypto`
// surface (Class A): the scan → convert → latch format migrator that drives the census's
// `unprefixedLegacyOrUnrecognized` count toward zero so Phase 3 can delete the legacy-read
// branch at `MediaAtRestCrypto.swift`'s `gcmOpen` (the unprefixed, no-AAD open).
//
// Division of labor with `OwnPhotoKeyMigrator` (which stays byte-for-byte untouched): the KEY
// migrator converts files that fail own-key open (friend-key own files, opened via the legacy
// key and re-sealed — its re-seal now emits FMA2, so every file it converts is simultaneously
// format-migrated). THIS migrator converts only what the key migrator cannot see: own-corpus
// files that already open under the own key but are unprefixed (every own write between the
// 2026-08-11 key split and the 2026-08-26 domain separation, including that window's key-
// migration re-seals), the whole friend-wall root (whose key never changed, so the key pass
// never sweeps it), and the legitimate pre-sealing plaintext JPEG generations exactly where the
// read paths' upgrade branches exist. Disjoint convert sets, one launch task, strict order —
// key pass, then binder, then format pass — so the two sweeps compose instead of fighting.
//
// Classification goes through the census's own shared classifier
// (`MediaAtRestFormatCensus.format(ofFileAt:)` / `format(ofHeader:)`), so the counter and the
// converter can never disagree about what a blob is. Convert re-seals through the surface's
// existing `sealAndWrite` path binding the existing registered per-location purposes
// (`OwnPhotoCorpusLayout.sealPurpose(for:)` / `FriendWallCorpusLayout.sealPurpose(for:)`) —
// zero new purposes, zero new crypto call shapes, and nothing is ever deleted.

import Foundation
import FernletCrypto
import FernletFoundation

/// The persisted "no media blob on this device is in the pre-domain-separation at-rest format"
/// latch (crypto-standardization Phase 2.3).
///
/// ATTESTS, precisely: *on this device, a full sweep of the eight-location media surface proved
/// no bytes remain that only `gcmOpen`'s legacy-read branch can open.* Set only by
/// `FormatMigrator.run` after a clean pass — one that converted nothing, failed nothing,
/// deferred nothing, and could classify everything. Named non-blocking residues
/// (``MediaAtRestFormatMigrationResult/unopenableUnprefixed``,
/// ``MediaAtRestFormatMigrationResult/refusedPlaintext``) do not weaken the claim: their bytes
/// were read and proven unreachable through the legacy branch (§ the result's own docs).
///
/// DOES NOT ATTEST the Phase-3 gate — that gate reads the census on a real upgraded device at
/// gate time, beside this latch and this migrator's audited residue, never this bit alone.
///
/// Device-local (`UserDefaults`, never synced): the claim is about THIS device's bytes. Absent
/// reads false — the fail-closed direction. **Kept across "Delete everything"** (wipe wall:
/// `Docs/PrivacyWipeCoverage.md` + `PersistedSurfaceWipeBoundaryTests`, same commit as this
/// key): the wipe empties the own corpora, the surviving friend wall was proven all-current (or
/// named residue) before the latch could set, and every post-wipe writer emits the current
/// format — so the claim stays true of everything the wipe leaves behind, and clearing it would
/// only force a pointless re-scan. One bit recording a format fact, never content.
///
/// **Invalidation rule** (mirroring `OwnPhotoMigrationLatch.reset`): no shipped in-app write
/// re-introduces the legacy format, so no production reset seam is wired — but any future
/// feature that lands media bytes on disk VERBATIM from another device or era must call
/// ``reset()`` in the same change. One known platform exposure is accepted on the same terms it
/// already shipped with for `OwnPhotoMigrationLatch`: iOS container restores are progressive,
/// so a pass that runs mid-restore can latch before the remaining legacy files finish landing.
/// The compensating control is the census-vs-latch cross-check on a real device — a latch-true
/// device whose census shows unprefixed counts beyond the named residues is that scenario's
/// signature, and the documented remediation is calling ``reset()`` to force a re-scan.
///
/// Concurrency: value type over `UserDefaults` (itself thread-safe), confined like its migrator
/// to whatever isolation domain built it.
public struct MediaAtRestFormatMigrationLatch: FormatMigrationLatching {
    /// The `UserDefaults` key holding the latch. A `static let` literal so the wipe wall's
    /// discovery scan finds it (the `OwnPhotoMigrationLatch` shape, byte for byte).
    public static let defaultsKey = "com.fernlet.private-media.mediaAtRestFormatMigrationComplete"

    private let defaults: UserDefaults

    /// Creates a latch over `defaults`; tests inject an isolated suite so they never touch the
    /// device's real completion state.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a full clean pass has proven no media blob remains in the legacy at-rest format.
    /// Absent (never set) reads as false — the fail-closed direction.
    public var isComplete: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    /// Records completion. Called ONLY from `FormatMigrator.run(maxPasses:)` after a clean pass;
    /// never from a UI path, and never speculatively.
    public func markComplete() {
        defaults.set(true, forKey: Self.defaultsKey)
    }

    /// Clears the latch, forcing a re-scan on the next run. For tests and for documented future
    /// invalidators only — any change that lands media bytes on disk verbatim from another
    /// device or era, and the progressive-restore remediation named in the type doc.
    public func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

/// One ``MediaAtRestFormatMigrator`` pass's tally — and, through ``isClean``, the sole authority
/// on whether the completion latch may be set.
///
/// Conforms to `FormatMigrationPassResult`: ``isClean`` and ``madeForwardProgress`` are the two
/// verdicts the shared `FormatMigrator.run(maxPasses:)` loop reads; the buckets below are this
/// migration's own diagnostic breakdown. ``examined`` counts dispatched files (listed entries
/// whose type could not be read included); it can exceed the bucket sum in exactly one state —
/// a root abort, whose skipped convert candidates are deliberately un-bucketed because the
/// abort flag itself is the blocker and the next launch re-examines them.
public struct MediaAtRestFormatMigrationResult: Sendable, Equatable, FormatMigrationPassResult {
    /// Files the pass dispatched: every enumerated candidate, plus each listed directory entry
    /// whose type could not be read (tallied ``indeterminate``). Excludes unlistable directories,
    /// which hide an unknown COUNT and are therefore only ``indeterminate``, never "examined".
    public let examined: Int
    /// Carries the current `FMA2` marker — untouched, header read only. Deliberately unverified:
    /// the scan is marker-bytes-only by contract, and a corrupt FMA2 box already resolves to nil
    /// in every read path (there is no purpose-rebinding pass).
    public let alreadyCurrentFormat: Int
    /// Legacy sealed boxes opened under their root's key and re-sealed in the current format by
    /// THIS pass, read-back verified. Non-zero means the corpus was not clean when the pass
    /// started, so the latch waits for a following pass to confirm zero.
    public let converted: Int
    /// Legitimate pre-sealing plaintext JPEGs sealed in place by THIS pass (meal corpus, wall
    /// photos, wall thumbnails — the exact locations whose read paths carry an upgrade branch).
    public let convertedPlaintext: Int
    /// A file OPENED but its conversion failed: the seal, the in-memory verify, the atomic
    /// write, or the disk read-back. Blocks the latch; the source bytes are untouched
    /// (verify-before-replace), so the next pass re-examines.
    public let conversionFailures: Int
    /// Census-unprefixed bytes that were fully READ and open under NEITHER key (own root: both
    /// keys probed; wall root: the wall key). Does **not** block the latch, and the argument is
    /// deliberately the latch's precise claim and no more: the bytes were read, every key the
    /// legacy branch could ever pair them with was tried, and nothing opens them — so deleting
    /// the legacy-read branch cannot change what any reader gets. Includes one documented
    /// limitation: a pre-sealing plaintext non-JPEG image (HEIC/PNG) in the meal corpus lands
    /// here, because convert eligibility must not exceed the shared census sniff (JPEG-magic
    /// only) — such a file is still served and organically re-sealed by
    /// `MealPhotoStore.imageData`'s plaintext branch, which never touches `gcmOpen`'s legacy
    /// branch, so Phase 3 is invisible to it. A named expected residue for the Phase-3 gate.
    ///
    /// - Important: this bucket means "we READ the bytes and no key opens them". A file whose
    ///   bytes could not be read at all is ``indeterminate``, never this.
    public let unopenableUnprefixed: Int
    /// A parseable plaintext image the pass REFUSED to seal: a plaintext JPEG in a born-sealed
    /// corpus (recipe, progress bytes, either sealed index — where the read paths refuse
    /// unsealed bytes, and converting would be the laundering those refusals exist to prevent),
    /// or an out-of-pixel-bounds plaintext anywhere. Does **not** block the latch: these bytes
    /// never reach `gcmOpen`'s legacy branch — the plaintext read branches inspect raw bytes
    /// only after GCM-open fails — so the branch delete is invisible to them. Census class
    /// `plaintextJPEG`, never `unprefixed`: the split the Phase-3 gate arithmetic relies on.
    public let refusedPlaintext: Int
    /// An own-root file the WALL key opens while the own-key migration latch is set — a state
    /// the key latch claims cannot exist, checked rather than assumed because that proof has a
    /// real hole (the key pass silently drops a listed entry whose `isRegularFile` resource
    /// value reads nil). BLOCKS the latch loudly: such a file still needs the dual-open path
    /// Phase 3 would delete. Never converted here — probing is read-only, and converting a
    /// friend-key file stays the key migrator's job; the file itself recovers organically via
    /// `MealPhotoStore.imageData`'s dual-open on access.
    public let legacyKeySealedOwnFile: Int
    /// A file whose bytes changed between this pass's reads — the convert-time full read no
    /// longer matching the scanned header class, or (for the two mutable index manifests) the
    /// pre-write re-read no longer matching the convert-time read. The file is left untouched
    /// (never clobbered with a stale snapshot) and BLOCKS this pass; by the next pass the
    /// store's own current-format rewrite has usually made it ``alreadyCurrentFormat``.
    public let skippedConcurrentlyModified: Int
    /// Zero-byte files: nothing to convert, and nothing the Phase-3 branch delete can cost.
    /// Non-blocking.
    public let empty: Int
    /// Could not be classified: bytes unreadable (header or full read), an existing directory
    /// that would not enumerate, a listed entry whose type could not be read, or an own-root
    /// open-failure that could not be attributed while the wall key was unavailable. Blocks the
    /// latch — "I could not see the bytes" is never "there are no legacy bytes"; see
    /// `OwnPhotoKeyMigrationResult.indeterminate` for the house statement of why (these are
    /// `.completeFileProtection` files, so a device locking mid-pass must block, never look
    /// clean).
    public let indeterminate: Int
    /// Own-root convert candidates skipped because `OwnPhotoMigrationLatch` is not yet set. An
    /// unprefixed own file with the key latch unset might be a healthy friend-key file
    /// mid-key-migration — the key migrator's file, not this one's — so the pass defers rather
    /// than duplicate it. Blocks the latch; costs at most one launch, since in the healthy case
    /// the key latch sets moments earlier in the same launch task.
    public let deferredOwnKeyMigrationIncomplete: Int
    /// The own root had convert candidates but the own key was unavailable (locked or failing
    /// keychain, on a non-minting probe). Blocks the latch; the skipped candidates are
    /// re-examined next launch.
    public let abortedNoOwnKey: Bool
    /// The wall root had convert candidates but the wall key was unavailable. Blocks the latch.
    /// One shape is persistently keyless and benign-pending rather than a defect: a wall root
    /// holding only pre-sealing plaintext photos on a device whose `friendWall` keychain row was
    /// never minted (the files predate every sealed-era wall access) or did not travel with a
    /// migrated container. The non-minting probe returns nil every launch and this flag holds
    /// the latch open — fail-closed and lossless — until the organic exit: the first wall use,
    /// whose (minting) store provider mints the row and whose `loadIndex()` seals the index,
    /// after which the next pass converts the rest.
    public let abortedNoWallKey: Bool

    /// Whether this pass proves the surface is fully migrated: it converted nothing (so nothing
    /// was left in the legacy format when it started), failed nothing, deferred nothing, raced
    /// nothing, met nothing that should not exist, and could classify everything.
    public var isClean: Bool {
        !abortedNoOwnKey && !abortedNoWallKey
            && deferredOwnKeyMigrationIncomplete == 0
            && converted == 0 && convertedPlaintext == 0
            && conversionFailures == 0 && indeterminate == 0
            && legacyKeySealedOwnFile == 0 && skippedConcurrentlyModified == 0
    }

    /// Whether this pass converted at least one blob — the forward-progress verdict the shared
    /// run loop uses to decide between "confirm with another pass" and "stop, retry next launch".
    public var madeForwardProgress: Bool { converted + convertedPlaintext > 0 }

    /// Creates a result. Public so tests can build expectations; production values come from
    /// ``MediaAtRestFormatMigrator/performPass()``.
    public init(
        examined: Int = 0,
        alreadyCurrentFormat: Int = 0,
        converted: Int = 0,
        convertedPlaintext: Int = 0,
        conversionFailures: Int = 0,
        unopenableUnprefixed: Int = 0,
        refusedPlaintext: Int = 0,
        legacyKeySealedOwnFile: Int = 0,
        skippedConcurrentlyModified: Int = 0,
        empty: Int = 0,
        indeterminate: Int = 0,
        deferredOwnKeyMigrationIncomplete: Int = 0,
        abortedNoOwnKey: Bool = false,
        abortedNoWallKey: Bool = false
    ) {
        self.examined = examined
        self.alreadyCurrentFormat = alreadyCurrentFormat
        self.converted = converted
        self.convertedPlaintext = convertedPlaintext
        self.conversionFailures = conversionFailures
        self.unopenableUnprefixed = unopenableUnprefixed
        self.refusedPlaintext = refusedPlaintext
        self.legacyKeySealedOwnFile = legacyKeySealedOwnFile
        self.skippedConcurrentlyModified = skippedConcurrentlyModified
        self.empty = empty
        self.indeterminate = indeterminate
        self.deferredOwnKeyMigrationIncomplete = deferredOwnKeyMigrationIncomplete
        self.abortedNoOwnKey = abortedNoOwnKey
        self.abortedNoWallKey = abortedNoWallKey
    }
}

/// Re-seals every remaining pre-domain-separation media blob into the current `FMA2` +
/// purpose-AAD format — the format half of the media migration, beside `OwnPhotoKeyMigrator`'s
/// key half.
///
/// **Eager, idempotent, crash-safe**, on the `OwnPhotoKeyMigrator` contract: per file the first
/// question is a header-only "is it already current?", so a confirming pass over a converted
/// corpus is a read-only sweep of 4-byte reads; every convert is verified in memory before any
/// byte lands, written through the surface's one atomic fully-protected path (`sealAndWrite`),
/// and read back from disk before it is counted — so a file is always wholly old or wholly
/// new-and-valid, nothing is ever deleted, and any interruption's worst case is "re-examined
/// next pass".
///
/// **The residual live-store race, accepted with its stakes stated.** The pass runs off-main
/// while the owning stores are live. Photo files are content-immutable per id, so a lost race
/// is byte-equivalent — no guard. The two index files are file MANIFESTS and different: a stale
/// wall-index write could, at the next launch's `loadIndex()` normalization, sweep a raced-in
/// friend photo's files (permanent loss, no mesh rehydration hook), and a stale progress-index
/// write strands its record's sealed bytes unreferenced. Three things bound that window to
/// near-zero: exposure requires an index still legacy-format at the converting launch (every
/// keyed wall load since domain separation already rewrote its index current-format); each
/// file's classify→convert gap is one file's work, never the sweep's (per-file interleaving);
/// and the two manifests get a compare-before-write guard — re-read immediately before the
/// write, proceed only on byte-equality, else `skippedConcurrentlyModified` — shrinking the
/// deletion-amplified window to one syscall gap. That residual gap is accepted: only an
/// exclusive-access scheme could close it, and that machinery is not warranted for a
/// one-launch, one-syscall window over indexes that are usually already current-format.
///
/// Concurrency: a nonisolated struct holding two non-`Sendable` key providers, so an instance
/// is confined to whatever isolation domain built it. The app builds one INSIDE its off-main
/// launch task (``standard(documentsDirectory:proximitySupportDirectory:defaults:)``), after
/// the key pass, exactly like the key migrator.
public struct MediaAtRestFormatMigrator: FormatMigrator {
    /// R2: the named maximum number of sweep passes the shared `run(maxPasses:)` funds — one to
    /// convert, one to confirm the surface is now clean (the canonical bound).
    public static let maxMigrationPasses = 2

    /// The completion latch the shared `FormatMigrator.run(maxPasses:)` loop sets after a clean
    /// pass (a protocol requirement, which is why it is not `private`).
    public let latch: MediaAtRestFormatMigrationLatch

    private let ownLocations: OwnPhotoSealedLocations
    private let wallLocations: OwnPhotoSealedLocations
    private let ownKeyProvider: any PrivateMediaKeyProviding
    private let wallKeyProvider: any PrivateMediaKeyProviding
    private let ownKeyMigrationLatch: OwnPhotoMigrationLatch

    /// Creates a migrator over explicit location sets and key providers (the test seam).
    ///
    /// - Parameters:
    ///   - ownLocations: The own-photo corpora (meal, recipe, progress bytes, progress index);
    ///     missing paths are skipped.
    ///   - wallLocations: The friend wall's RESEALABLE locations
    ///     (`FriendWallCorpusLayout.resealableLocations(in:)` — the plaintext index deliberately
    ///     not among them).
    ///   - ownKeyProvider: Vends the own-photos key. Non-minting in production: a format sweep
    ///     must never be the reason a key row is created.
    ///   - wallKeyProvider: Vends the friend-wall key. Non-minting in production, same reason.
    ///   - ownKeyMigrationLatch: `OwnPhotoKeyMigrator`'s completion latch — read (never written)
    ///     to defer own-root unprefixed candidates the key migrator may still own.
    ///   - latch: The completion latch `run(maxPasses:)` sets.
    public init(
        ownLocations: OwnPhotoSealedLocations,
        wallLocations: OwnPhotoSealedLocations,
        ownKeyProvider: any PrivateMediaKeyProviding,
        wallKeyProvider: any PrivateMediaKeyProviding,
        ownKeyMigrationLatch: OwnPhotoMigrationLatch,
        latch: MediaAtRestFormatMigrationLatch
    ) {
        self.ownLocations = ownLocations
        self.wallLocations = wallLocations
        self.ownKeyProvider = ownKeyProvider
        self.wallKeyProvider = wallKeyProvider
        self.ownKeyMigrationLatch = ownKeyMigrationLatch
        self.latch = latch
    }

    /// The production migrator over both media roots — the same two roots the census aggregator
    /// reads, so migrator and census sweep identical paths by construction.
    ///
    /// Builds its OWN key providers rather than borrowing the stores' — providers are not
    /// `Sendable`, and this is called from inside a background launch task. BOTH are non-minting
    /// (`mintsIfAbsent: false`): a missing key aborts the affected root's conversions
    /// fail-closed rather than minting a row that would open nothing.
    public static func standard(
        documentsDirectory: URL,
        proximitySupportDirectory: URL,
        defaults: UserDefaults = .standard
    ) -> MediaAtRestFormatMigrator {
        MediaAtRestFormatMigrator(
            ownLocations: OwnPhotoCorpusLayout.sealedLocations(in: documentsDirectory),
            wallLocations: FriendWallCorpusLayout.resealableLocations(in: proximitySupportDirectory),
            ownKeyProvider: KeychainPrivateMediaKeyProvider(role: .ownPhotos, mintsIfAbsent: false),
            wallKeyProvider: KeychainPrivateMediaKeyProvider(role: .friendWall, mintsIfAbsent: false),
            ownKeyMigrationLatch: OwnPhotoKeyMigrator.latch(defaults: defaults),
            latch: MediaAtRestFormatMigrationLatch(defaults: defaults)
        )
    }

    // MARK: - The pass

    /// Sweeps every location once — classifying each file header-only through the census's shared
    /// classifier and converting eligible legacy blobs in place, one file fully dispatched before
    /// the next is touched — and tallies what it found.
    ///
    /// Never sets the latch — `run(maxPasses:)` owns that decision — so tests can drive passes
    /// directly and assert idempotence. Key probes are lazy-on-first-candidate and cached per
    /// root, so a sweep with no convert candidates (an empty install, a fully-converted corpus)
    /// never touches the keychain at all — the key-migrator precedent, subsumed rather than
    /// special-cased. R7: not `@discardableResult` — the tally carries the pass's failure
    /// information.
    ///
    /// - Returns: the pass tally; one `privateMedia.formatMigrationPass` audit line records it
    ///   (counts only — never media file names).
    public func performPass() -> MediaAtRestFormatMigrationResult {
        let scan = scanCandidates()
        var state = PassState()
        // A directory that exists but could not be listed hides an unknown number of files, and
        // a listed entry whose type could not be read is a file the sweep can say nothing about:
        // both are indeterminate — never silently "nothing to do". Only the per-entry case
        // counts as examined (a hidden COUNT is not a countable file).
        state.indeterminate = scan.unlistableDirectories + scan.unreadableListingEntries
        state.examined = scan.unreadableListingEntries
        // R2: bounded by the finite directory listings (the corpora are photo-count-capped;
        // the meal corpus is the uncapped-but-small one the key migrator already sweeps
        // uncapped every launch).
        for candidate in scan.candidates {
            state.examined += 1
            dispatch(candidate, into: &state)
        }
        let result = MediaAtRestFormatMigrationResult(
            examined: state.examined,
            alreadyCurrentFormat: state.alreadyCurrentFormat,
            converted: state.converted,
            convertedPlaintext: state.convertedPlaintext,
            conversionFailures: state.conversionFailures,
            unopenableUnprefixed: state.unopenableUnprefixed,
            refusedPlaintext: state.refusedPlaintext,
            legacyKeySealedOwnFile: state.legacyKeySealedOwnFile,
            skippedConcurrentlyModified: state.skippedConcurrentlyModified,
            empty: state.empty,
            indeterminate: state.indeterminate,
            deferredOwnKeyMigrationIncomplete: state.deferredOwnKeyMigrationIncomplete,
            abortedNoOwnKey: state.abortedNoOwnKey,
            abortedNoWallKey: state.abortedNoWallKey
        )
        logPass(result)
        return result
    }

    // MARK: - Dispatch

    /// Which of the two media roots a candidate file belongs to — the axis that picks its key
    /// provider, its purpose mapping, and its abort flag.
    private enum Root {
        case own
        case wall
    }

    /// One enumerated file: where it is, whose root it belongs to, and whether it is one of the
    /// two mutable index MANIFESTS (which get the compare-before-write guard).
    private struct Candidate {
        let url: URL
        let root: Root
        let isIndexFile: Bool
    }

    /// What one pass has learned so far: the running tallies plus the per-root lazy key probes.
    private struct PassState {
        var examined = 0
        var alreadyCurrentFormat = 0
        var converted = 0
        var convertedPlaintext = 0
        var conversionFailures = 0
        var unopenableUnprefixed = 0
        var refusedPlaintext = 0
        var legacyKeySealedOwnFile = 0
        var skippedConcurrentlyModified = 0
        var empty = 0
        var indeterminate = 0
        var deferredOwnKeyMigrationIncomplete = 0
        var abortedNoOwnKey = false
        var abortedNoWallKey = false
        var ownKey = KeyProbe.unprobed
        var wallKey = KeyProbe.unprobed
    }

    /// One root's key-availability state, probed lazily on that root's FIRST convert candidate
    /// and cached for the pass — so a root with zero candidates never touches the keychain.
    private enum KeyProbe {
        case unprobed
        case available
        case unavailable
    }

    /// Fully dispatches ONE file: header-only classification through the shared census
    /// classifier, then immediate action — so the classify→convert gap for any file is its own
    /// convert, never the rest of the sweep.
    private func dispatch(_ candidate: Candidate, into state: inout PassState) {
        switch MediaAtRestFormatCensus.format(ofFileAt: candidate.url) {
        case .v2Marked:
            state.alreadyCurrentFormat += 1
        case .empty:
            state.empty += 1
        case .indeterminate:
            state.indeterminate += 1
        case .plaintextJPEG:
            dispatchPlaintext(candidate, into: &state)
        case .unprefixedLegacyOrUnrecognized:
            switch candidate.root {
            case .own: dispatchUnprefixedOwn(candidate, into: &state)
            case .wall: dispatchUnprefixedWall(candidate, into: &state)
            }
        }
    }

    /// A plaintext JPEG: sealed in place where a legitimate pre-sealing plaintext generation
    /// exists and the read path carries an upgrade branch (meal corpus, wall photos, wall
    /// thumbnails); refused everywhere else — the born-sealed corpora's read paths refuse
    /// unsealed bytes, and converting there would be the laundering those refusals prevent.
    private func dispatchPlaintext(_ candidate: Candidate, into state: inout PassState) {
        guard allowsPlaintextConversion(candidate) else {
            state.refusedPlaintext += 1
            return
        }
        guard keyIsAvailable(for: candidate.root, in: &state, abortsOnMiss: true) else { return }
        guard let stored = try? Data(contentsOf: candidate.url) else {
            state.indeterminate += 1
            return
        }
        guard MediaAtRestFormatCensus.format(ofHeader: stored) == .plaintextJPEG else {
            state.skippedConcurrentlyModified += 1
            return
        }
        // The exact predicate the read paths' upgrade-on-access branches require. Out-of-bounds
        // plaintext is refused, not converted — sealing it would launder bytes the read path
        // itself would drop.
        guard PrivateMediaStore.isWithinSafePixelBounds(stored) else {
            state.refusedPlaintext += 1
            return
        }
        switch convert(plaintext: stored, stored: stored, candidate: candidate) {
        case .converted: state.convertedPlaintext += 1
        case .failed: state.conversionFailures += 1
        case .raced: state.skippedConcurrentlyModified += 1
        }
    }

    /// An unprefixed own-root file — the middle state the key migrator structurally cannot see
    /// (own-key-but-legacy-format opens through the legacy branch and is counted `alreadyOwnKey`
    /// there), converted here iff the own key actually opens it.
    private func dispatchUnprefixedOwn(_ candidate: Candidate, into state: inout PassState) {
        // Latch precedence: with the key latch unset this may be a healthy friend-key file the
        // key migrator has simply not reached — converting it here would need the legacy key
        // and would duplicate that pass. Defer (blocking) instead; costs at most one launch.
        guard ownKeyMigrationLatch.isComplete else {
            state.deferredOwnKeyMigrationIncomplete += 1
            return
        }
        guard keyIsAvailable(for: .own, in: &state, abortsOnMiss: true) else { return }
        guard let stored = try? Data(contentsOf: candidate.url) else {
            state.indeterminate += 1
            return
        }
        guard MediaAtRestFormatCensus.format(ofHeader: stored) == .unprefixedLegacyOrUnrecognized else {
            state.skippedConcurrentlyModified += 1
            return
        }
        let purpose = OwnPhotoCorpusLayout.sealPurpose(for: candidate.url)
        if let plaintext = ownKeyProvider.gcmOpen(stored, purpose: purpose) {
            switch convert(plaintext: plaintext, stored: stored, candidate: candidate) {
            case .converted: state.converted += 1
            case .failed: state.conversionFailures += 1
            case .raced: state.skippedConcurrentlyModified += 1
            }
            return
        }
        // The own key does not open it. Probe the wall key before concluding anything — the
        // house model (`OwnPhotoKeyMigration`'s legacy-key posture): a verdict reached with a
        // key unavailable is no verdict. This probe is DIAGNOSTIC — it never sets
        // `abortedNoWallKey` (that flag belongs to wall-root candidates) and never converts
        // (a friend-key file is the key migrator's job, and its recovery path is the read
        // side's dual-open).
        guard keyIsAvailable(for: .wall, in: &state, abortsOnMiss: false) else {
            state.indeterminate += 1
            return
        }
        if wallKeyProvider.gcmOpen(stored, purpose: purpose) != nil {
            state.legacyKeySealedOwnFile += 1
        } else {
            state.unopenableUnprefixed += 1
        }
    }

    /// An unprefixed wall-root file: converted iff the wall key opens it, under the wall's
    /// per-location purpose.
    private func dispatchUnprefixedWall(_ candidate: Candidate, into state: inout PassState) {
        guard keyIsAvailable(for: .wall, in: &state, abortsOnMiss: true) else { return }
        guard let stored = try? Data(contentsOf: candidate.url) else {
            state.indeterminate += 1
            return
        }
        guard MediaAtRestFormatCensus.format(ofHeader: stored) == .unprefixedLegacyOrUnrecognized else {
            state.skippedConcurrentlyModified += 1
            return
        }
        let purpose = FriendWallCorpusLayout.sealPurpose(for: candidate.url)
        guard let plaintext = wallKeyProvider.gcmOpen(stored, purpose: purpose) else {
            state.unopenableUnprefixed += 1
            return
        }
        switch convert(plaintext: plaintext, stored: stored, candidate: candidate) {
        case .converted: state.converted += 1
        case .failed: state.conversionFailures += 1
        case .raced: state.skippedConcurrentlyModified += 1
        }
    }

    /// Whether plaintext at this candidate's location may be sealed in place — a POSITIVE path
    /// match on the three locations with a legitimate pre-sealing plaintext generation, never a
    /// default branch. Deliberate: `OwnPhotoCorpusLayout.sealPurpose(for:)` *defaults* unknown
    /// paths to the meal purpose, and an eligibility rule inheriting that default would silently
    /// extend plaintext-laundering to any mis-rooted sweep.
    private func allowsPlaintextConversion(_ candidate: Candidate) -> Bool {
        switch candidate.root {
        case .own:
            return candidate.url.pathComponents.contains(OwnPhotoCorpusLayout.mealPhotosDirectoryName)
        case .wall:
            return candidate.url.pathComponents.contains(FriendWallCorpusLayout.photosDirectoryName)
                || candidate.url.pathComponents.contains(FriendWallCorpusLayout.thumbnailsDirectoryName)
        }
    }

    /// Probes (once per pass per root, cached) whether `root`'s key is available.
    ///
    /// `abortsOnMiss` distinguishes a root's OWN convert candidate — whose missing key sets that
    /// root's abort flag — from the own-root diagnostic wall-key probe, whose miss makes only
    /// that one file indeterminate.
    private func keyIsAvailable(for root: Root, in state: inout PassState, abortsOnMiss: Bool) -> Bool {
        switch root {
        case .own:
            if state.ownKey == .unprobed {
                state.ownKey = ownKeyProvider.mediaKey() != nil ? .available : .unavailable
            }
            guard state.ownKey == .available else {
                if abortsOnMiss { state.abortedNoOwnKey = true }
                return false
            }
            return true
        case .wall:
            if state.wallKey == .unprobed {
                state.wallKey = wallKeyProvider.mediaKey() != nil ? .available : .unavailable
            }
            guard state.wallKey == .available else {
                if abortsOnMiss { state.abortedNoWallKey = true }
                return false
            }
            return true
        }
    }

    // MARK: - Convert

    /// How one file's conversion ended.
    private enum ConvertOutcome {
        /// Sealed, atomically written, and read back from disk successfully.
        case converted
        /// The seal, in-memory verify, write, or disk read-back failed; the file is wholly old
        /// (or, past the atomic write, wholly new-and-valid — atomic replace has no third state).
        case failed
        /// The index-file guard found the on-disk bytes changed since the convert-time read; the
        /// store's newer bytes were left untouched.
        case raced
    }

    /// Converts one opened file: seal, verify in memory BEFORE any byte lands, guard the two
    /// mutable index manifests against a concurrent store save, atomically write via the
    /// surface's one fully-protected path, and read back from disk before counting. The source
    /// is never deleted, and nothing unverified ever replaces it.
    private func convert(plaintext: Data, stored: Data, candidate: Candidate) -> ConvertOutcome {
        let provider = keyProvider(for: candidate.root)
        let purpose = sealPurpose(for: candidate)
        guard let sealed = provider.gcmSeal(plaintext, purpose: purpose) else { return .failed }
        guard provider.gcmOpen(sealed, purpose: purpose) == plaintext else { return .failed }
        if candidate.isIndexFile {
            // The compare-before-write guard (the two mutable manifests only): a store may have
            // committed a newer index since the convert-time read, and landing this stale
            // snapshot over it would — for the wall — let the next launch's normalization
            // orphan-sweep delete a raced-in friend photo's files. Byte-inequality (or a failed
            // re-read) skips the file untouched; it is re-examined next pass. This does not
            // close the TOCTOU — it shrinks the window to one syscall gap (see the type doc).
            guard let recheck = try? Data(contentsOf: candidate.url), recheck == stored else {
                return .raced
            }
        }
        guard provider.sealAndWrite(plaintext, to: candidate.url, purpose: purpose) else {
            return .failed
        }
        guard let readBack = try? Data(contentsOf: candidate.url),
              provider.gcmOpen(readBack, purpose: purpose) == plaintext else {
            return .failed
        }
        return .converted
    }

    /// The key provider for one root.
    private func keyProvider(for root: Root) -> any PrivateMediaKeyProviding {
        switch root {
        case .own: return ownKeyProvider
        case .wall: return wallKeyProvider
        }
    }

    /// The AEAD purpose a candidate re-seals under — each root's own layout mapping, the same
    /// one its stores and (for the own root) the key migrator bind.
    private func sealPurpose(for candidate: Candidate) -> CryptographicPurpose {
        switch candidate.root {
        case .own: return OwnPhotoCorpusLayout.sealPurpose(for: candidate.url)
        case .wall: return FriendWallCorpusLayout.sealPurpose(for: candidate.url)
        }
    }

    // MARK: - Enumeration

    /// One sweep's enumeration output: the files to dispatch, plus the two blind-spot counts
    /// that block the latch without being dispatchable files.
    private struct Scan {
        var candidates: [Candidate] = []
        var unlistableDirectories = 0
        var unreadableListingEntries = 0
    }

    /// Enumerates both roots with exactly the census/key-migrator enumeration: non-recursive,
    /// hidden files skipped, named files included only when they exist, missing paths skipped as
    /// honest zeros. Sorted by path so a pass's work order — and therefore its tallies over an
    /// unchanged corpus — is deterministic.
    private func scanCandidates() -> Scan {
        var scan = Scan()
        appendCandidates(from: ownLocations, root: .own, into: &scan)
        appendCandidates(from: wallLocations, root: .wall, into: &scan)
        return scan
    }

    /// Enumerates one location set. A listed entry whose `isRegularFile` resource value reads
    /// nil is COUNTED (unreadable, blocks) rather than silently dropped — the census's
    /// `format(ofListedEntry:isRegularFile:)` rule, and the exact silent-drop hole through which
    /// a friend-key own file could slip past the key latch's proof; a positive `false` (a
    /// subdirectory, a fifo, a symlink) was never a media blob and is skipped.
    private func appendCandidates(from locations: OwnPhotoSealedLocations, root: Root, into scan: inout Scan) {
        let fileManager = FileManager.default
        // R2: both loops iterate finite location arrays; the inner loop a finite listing.
        for directory in locations.directories {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else {
                scan.unlistableDirectories += 1
                continue
            }
            for url in contents.sorted(by: { $0.path < $1.path }) {
                let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
                guard isRegularFile != false else { continue }
                guard isRegularFile == true else {
                    scan.unreadableListingEntries += 1
                    continue
                }
                scan.candidates.append(Candidate(url: url, root: root, isIndexFile: false))
            }
        }
        for url in locations.files where fileManager.fileExists(atPath: url.path) {
            scan.candidates.append(Candidate(url: url, root: root, isIndexFile: true))
        }
    }

    // MARK: - Audit

    /// One audit line per pass: every tally as a count, plus — when the pass does not prove
    /// completion — the names of the buckets holding the latch closed. Counts only, never file
    /// names of own media beyond what existing reseal logs already record. §8's gate arithmetic
    /// reads `unopenableUnprefixed` (the census-unprefixed residue) and `refusedPlaintext` (the
    /// census-plaintext non-residue) from this line, which is why both always ride it.
    private func logPass(_ result: MediaAtRestFormatMigrationResult) {
        var context: [String: String] = [
            "examined": String(result.examined),
            "alreadyCurrentFormat": String(result.alreadyCurrentFormat),
            "converted": String(result.converted),
            "convertedPlaintext": String(result.convertedPlaintext),
            "conversionFailures": String(result.conversionFailures),
            "unopenableUnprefixed": String(result.unopenableUnprefixed),
            "refusedPlaintext": String(result.refusedPlaintext),
            "legacyKeySealedOwnFile": String(result.legacyKeySealedOwnFile),
            "skippedConcurrentlyModified": String(result.skippedConcurrentlyModified),
            "empty": String(result.empty),
            "indeterminate": String(result.indeterminate),
            "deferredOwnKeyMigrationIncomplete": String(result.deferredOwnKeyMigrationIncomplete)
        ]
        if !result.isClean {
            context["blocking"] = blockingBucketNames(of: result).joined(separator: ",")
        }
        FernletAuditLog.log("privateMedia.formatMigrationPass", context: context)
    }

    /// The names of every bucket (and abort flag) currently holding the latch closed.
    private func blockingBucketNames(of result: MediaAtRestFormatMigrationResult) -> [String] {
        var names: [String] = []
        if result.converted > 0 { names.append("converted") }
        if result.convertedPlaintext > 0 { names.append("convertedPlaintext") }
        if result.conversionFailures > 0 { names.append("conversionFailures") }
        if result.legacyKeySealedOwnFile > 0 { names.append("legacyKeySealedOwnFile") }
        if result.skippedConcurrentlyModified > 0 { names.append("skippedConcurrentlyModified") }
        if result.indeterminate > 0 { names.append("indeterminate") }
        if result.deferredOwnKeyMigrationIncomplete > 0 { names.append("deferredOwnKeyMigrationIncomplete") }
        if result.abortedNoOwnKey { names.append("abortedNoOwnKey") }
        if result.abortedNoWallKey { names.append("abortedNoWallKey") }
        return names
    }
}
