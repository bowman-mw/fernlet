// MediaAtRestFormatMigration.swift
// PrivateMediaStore
//
// Phase 2.3 of Docs/Plan-Crypto-Standardization-2026-08-27.md for the `MediaAtRestCrypto`
// surface (Class A), as it stands AFTER Phase 3.
//
// Phase 3 deleted `gcmOpen`'s legacy-read branch (the unprefixed, no-AAD open), and with it this
// migrator's ciphertext conversion arms: a blob with no `FMA2` marker is opened by nothing in
// the app any more, so re-sealing it is not a thing that can be attempted, let alone succeed.
// Those arms are gone. What remains is a real job on a DIFFERENT generation — the pre-sealing
// **plaintext JPEG** photos, which never went near the deleted branch (the read paths inspect
// raw bytes only after a GCM open fails) and are plaintext on disk until something seals them.
// This pass seals them everywhere at once, eagerly, instead of one-at-a-time as the user happens
// to open each photo; and it keeps counting the unopenable unprefixed residue, which is
// classification, not reading.
//
// Division of labor with `OwnPhotoKeyMigrator` (which stays byte-for-byte untouched): the KEY
// migrator converts own files sealed under the pre-split shared key. Disjoint convert sets, one
// launch task, strict order — key pass, then binder, then format pass.
//
// Classification goes through the census's own shared classifier
// (`MediaAtRestFormatCensus.format(ofFileAt:)` / `format(ofHeader:)`), so the counter and the
// converter can never disagree about what a blob is. Convert seals through the surface's
// existing `sealAndWrite` path binding the existing registered per-location purposes
// (`OwnPhotoCorpusLayout.sealPurpose(for:)` / `FriendWallCorpusLayout.sealPurpose(for:)`) —
// zero new purposes, zero new crypto call shapes, and nothing is ever deleted.

import Foundation
import FernletCrypto
import FernletFoundation

/// The persisted "no media blob on this device is in the pre-domain-separation at-rest format"
/// latch (crypto-standardization Phase 2.3).
///
/// ATTESTS, precisely: *on this device, a full sweep of the eight-location media surface found no
/// pre-sealing plaintext image left to seal, and could classify every file it met.* Set only by
/// `FormatMigrator.run` after a clean pass — one that sealed nothing, failed nothing, raced
/// nothing and saw everything. Named non-blocking residues
/// (``MediaAtRestFormatMigrationResult/unopenableUnprefixed``,
/// ``MediaAtRestFormatMigrationResult/refusedPlaintext``) do not weaken the claim: neither is a
/// file this pass could ever act on (§ the result's own docs).
///
/// The claim it USED to make — "no bytes remain that only `gcmOpen`'s legacy-read branch can
/// open" — retired with that branch in Phase 3. Nothing opens unmarked ciphertext now, so the
/// residue count is a census fact rather than a reader dependency, and the latch stopped being
/// evidence for anything's deletion.
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
    /// Legitimate pre-sealing plaintext JPEGs sealed in place by THIS pass (meal corpus, wall
    /// photos, wall thumbnails — the exact locations whose read paths carry an upgrade branch).
    public let convertedPlaintext: Int
    /// A file OPENED but its conversion failed: the seal, the in-memory verify, the atomic
    /// write, or the disk read-back. Blocks the latch; the source bytes are untouched
    /// (verify-before-replace), so the next pass re-examines.
    public let conversionFailures: Int
    /// Files carrying no `FMA2` marker: the retired at-rest ciphertext format, or bytes nothing
    /// recognises. Counted from the header alone and left exactly as found — since Phase 3 no
    /// reader in the app opens unmarked ciphertext, so there is no key to try, nothing to convert,
    /// and nothing a sweep could do for them beyond saying how many there are.
    ///
    /// Does **not** block the latch, for the same reason: the latch's claim is about plaintext
    /// this pass could have sealed, and these are not that. Includes one documented member: a
    /// pre-sealing plaintext non-JPEG image (HEIC/PNG) in the meal corpus lands here, because
    /// seal eligibility must not exceed the shared census sniff (JPEG-magic only) — such a file is
    /// still served and organically re-sealed by `MealPhotoStore.imageData`'s plaintext branch.
    ///
    /// - Important: this bucket means "the header says unmarked". A file whose bytes could not be
    ///   read at all is ``indeterminate``, never this.
    public let unopenableUnprefixed: Int
    /// A parseable plaintext image the pass REFUSED to seal: a plaintext JPEG in a born-sealed
    /// corpus (recipe, progress bytes, either sealed index — where the read paths refuse
    /// unsealed bytes, and sealing it would be the laundering those refusals exist to prevent),
    /// or an out-of-pixel-bounds plaintext anywhere. Does **not** block the latch: the pass is
    /// never going to seal them, so waiting for the count to fall would be waiting forever.
    /// Census class `plaintextJPEG`, never `unprefixed` — the split the residue arithmetic
    /// depends on.
    public let refusedPlaintext: Int
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
    /// that would not enumerate, or a listed entry whose type could not be read. Blocks the
    /// latch — "I could not see the bytes" is never "there is nothing here to seal"; see
    /// `OwnPhotoKeyMigrationResult.indeterminate` for the house statement of why (these are
    /// `.completeFileProtection` files, so a device locking mid-pass must block, never look
    /// clean).
    public let indeterminate: Int
    /// The own root had seal candidates but the own key was unavailable (locked or failing
    /// keychain, on a non-minting probe). Blocks the latch; the skipped candidates are
    /// re-examined next launch.
    public let abortedNoOwnKey: Bool
    /// The wall root had seal candidates but the wall key was unavailable. Blocks the latch.
    /// One shape is persistently keyless and benign-pending rather than a defect: a wall root
    /// holding only pre-sealing plaintext photos on a device whose `friendWall` keychain row was
    /// never minted (the files predate every sealed-era wall access) or did not travel with a
    /// migrated container. The non-minting probe returns nil every launch and this flag holds
    /// the latch open — fail-closed and lossless — until the organic exit: the first wall use,
    /// whose (minting) store provider mints the row and whose `loadIndex()` seals the index,
    /// after which the next pass converts the rest.
    public let abortedNoWallKey: Bool

    /// Whether this pass proves the surface is fully migrated: it sealed nothing (so no plaintext
    /// was left when it started), failed nothing, raced nothing, and could classify everything.
    public var isClean: Bool {
        !abortedNoOwnKey && !abortedNoWallKey
            && convertedPlaintext == 0
            && conversionFailures == 0 && indeterminate == 0
            && skippedConcurrentlyModified == 0
    }

    /// Whether this pass sealed at least one plaintext image — the forward-progress verdict the
    /// shared run loop uses to decide between "confirm with another pass" and "stop, retry next
    /// launch".
    public var madeForwardProgress: Bool { convertedPlaintext > 0 }

    /// Creates a result. Public so tests can build expectations; production values come from
    /// ``MediaAtRestFormatMigrator/performPass()``.
    public init(
        examined: Int = 0,
        alreadyCurrentFormat: Int = 0,
        convertedPlaintext: Int = 0,
        conversionFailures: Int = 0,
        unopenableUnprefixed: Int = 0,
        refusedPlaintext: Int = 0,
        skippedConcurrentlyModified: Int = 0,
        empty: Int = 0,
        indeterminate: Int = 0,
        abortedNoOwnKey: Bool = false,
        abortedNoWallKey: Bool = false
    ) {
        self.examined = examined
        self.alreadyCurrentFormat = alreadyCurrentFormat
        self.convertedPlaintext = convertedPlaintext
        self.conversionFailures = conversionFailures
        self.unopenableUnprefixed = unopenableUnprefixed
        self.refusedPlaintext = refusedPlaintext
        self.skippedConcurrentlyModified = skippedConcurrentlyModified
        self.empty = empty
        self.indeterminate = indeterminate
        self.abortedNoOwnKey = abortedNoOwnKey
        self.abortedNoWallKey = abortedNoWallKey
    }
}

/// Seals every remaining pre-sealing plaintext photo into the current `FMA2` + purpose-AAD
/// format, and counts what is left that nothing can open — the format half of the media
/// migration, beside `OwnPhotoKeyMigrator`'s key half.
///
/// Phase 3 took the ciphertext half of this job away by deleting `gcmOpen`'s legacy-read branch:
/// an unmarked box has no reader left, so it is classified into
/// ``MediaAtRestFormatMigrationResult/unopenableUnprefixed`` and left alone. The plaintext
/// generation is the half that survives, and it is the more urgent one anyway — those bytes are
/// photographs sitting on disk in the clear.
///
/// **Eager, idempotent, crash-safe**, on the `OwnPhotoKeyMigrator` contract: per file the first
/// question is a header-only "is it already current?", so a confirming pass over a converted
/// corpus is a read-only sweep of 4-byte reads; every convert is verified in memory before any
/// byte lands, written through the surface's one atomic fully-protected path (`sealAndWrite`),
/// and read back from disk before it is counted — so a file is always wholly old or wholly
/// new-and-valid, nothing is ever deleted, and any interruption's worst case is "re-examined
/// next pass".
///
/// **The live-store race, and why the manifests are now out of it.** The pass runs off-main while
/// the owning stores are live. The only files it writes are the pre-sealing plaintext photos in
/// the three locations whose read paths already upgrade on access, and photo files are
/// content-immutable per id, so a lost race is byte-equivalent. The two index MANIFESTS — whose
/// stale-write hazard (a wall index rewritten from a stale snapshot lets the next launch's
/// `loadIndex()` orphan-sweep delete a raced-in friend photo's files) is the sharp one — are no
/// longer writable by this pass at all: neither lives inside a plaintext-eligible directory, so
/// `allowsPlaintextConversion` refuses them, and the ciphertext arm that used to rewrite them
/// went with Phase 3's reader. They are still ENUMERATED and classified; they are simply never
/// replaced. The compare-before-write guard that bounded that window went with the arm it
/// guarded, because a guard on a path nothing can take is not a guard.
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
    ///   - latch: The completion latch `run(maxPasses:)` sets.
    public init(
        ownLocations: OwnPhotoSealedLocations,
        wallLocations: OwnPhotoSealedLocations,
        ownKeyProvider: any PrivateMediaKeyProviding,
        wallKeyProvider: any PrivateMediaKeyProviding,
        latch: MediaAtRestFormatMigrationLatch
    ) {
        self.ownLocations = ownLocations
        self.wallLocations = wallLocations
        self.ownKeyProvider = ownKeyProvider
        self.wallKeyProvider = wallKeyProvider
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
            latch: MediaAtRestFormatMigrationLatch(defaults: defaults)
        )
    }

    // MARK: - The pass

    /// Sweeps every location once — classifying each file header-only through the census's shared
    /// classifier and sealing eligible plaintext photos in place, one file fully dispatched before
    /// the next is touched — and tallies what it found.
    ///
    /// Never sets the latch — `run(maxPasses:)` owns that decision — so tests can drive passes
    /// directly and assert idempotence. Key probes are lazy-on-first-candidate and cached per
    /// root, so a sweep with no seal candidates (an empty install, a fully-sealed corpus)
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
            convertedPlaintext: state.convertedPlaintext,
            conversionFailures: state.conversionFailures,
            unopenableUnprefixed: state.unopenableUnprefixed,
            refusedPlaintext: state.refusedPlaintext,
            skippedConcurrentlyModified: state.skippedConcurrentlyModified,
            empty: state.empty,
            indeterminate: state.indeterminate,
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

    /// One enumerated file: where it is and whose root it belongs to.
    private struct Candidate {
        let url: URL
        let root: Root
    }

    /// What one pass has learned so far: the running tallies plus the per-root lazy key probes.
    private struct PassState {
        var examined = 0
        var alreadyCurrentFormat = 0
        var convertedPlaintext = 0
        var conversionFailures = 0
        var unopenableUnprefixed = 0
        var refusedPlaintext = 0
        var skippedConcurrentlyModified = 0
        var empty = 0
        var indeterminate = 0
        var abortedNoOwnKey = false
        var abortedNoWallKey = false
        var ownKey = KeyProbe.unprobed
        var wallKey = KeyProbe.unprobed
    }

    /// One root's key-availability state, probed lazily on that root's FIRST seal candidate and
    /// cached for the pass — so a root with zero candidates never touches the keychain.
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
            // Counted from the header and left alone. Phase 3 deleted the only reader that could
            // ever have opened these bytes, so there is no key to probe and nothing to convert:
            // the pass has no more to say about them than how many there are. Never deleted —
            // unopenable is not the same fact as unwanted.
            state.unopenableUnprefixed += 1
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
        guard keyIsAvailable(for: candidate.root, in: &state) else { return }
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
        switch convert(plaintext: stored, candidate: candidate) {
        case .converted: state.convertedPlaintext += 1
        case .failed: state.conversionFailures += 1
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

    /// Probes (once per pass per root, cached) whether `root`'s key is available, and raises that
    /// root's abort flag on a miss.
    ///
    /// The `abortsOnMiss: false` variant went with Phase 3: its only caller was the own-root
    /// diagnostic wall-key probe, which existed to attribute an unprefixed own file to the
    /// pre-split key — a question no reader asks any more.
    private func keyIsAvailable(for root: Root, in state: inout PassState) -> Bool {
        switch root {
        case .own:
            if state.ownKey == .unprobed {
                state.ownKey = ownKeyProvider.mediaKey() != nil ? .available : .unavailable
            }
            guard state.ownKey == .available else {
                state.abortedNoOwnKey = true
                return false
            }
            return true
        case .wall:
            if state.wallKey == .unprobed {
                state.wallKey = wallKeyProvider.mediaKey() != nil ? .available : .unavailable
            }
            guard state.wallKey == .available else {
                state.abortedNoWallKey = true
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
        ///
        /// No `raced` sibling any more: the only compare-before-write this pass performed guarded
        /// the two index manifests, and Phase 3 took away the arm that could rewrite them. The
        /// header re-read in ``dispatchPlaintext(_:into:)`` still catches a file that changed class
        /// between the scan and the convert, and tallies it `skippedConcurrentlyModified` there.
        case failed
    }

    /// Seals one plaintext file: seal, verify in memory BEFORE any byte lands, atomically write via
    /// the surface's one fully-protected path, and read back from disk before counting. The source
    /// is never deleted, and nothing unverified ever replaces it.
    private func convert(plaintext: Data, candidate: Candidate) -> ConvertOutcome {
        let provider = keyProvider(for: candidate.root)
        let purpose = sealPurpose(for: candidate)
        guard let sealed = provider.gcmSeal(plaintext, purpose: purpose) else { return .failed }
        guard provider.gcmOpen(sealed, purpose: purpose) == plaintext else { return .failed }
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
                scan.candidates.append(Candidate(url: url, root: root))
            }
        }
        for url in locations.files where fileManager.fileExists(atPath: url.path) {
            scan.candidates.append(Candidate(url: url, root: root))
        }
    }

    // MARK: - Audit

    /// One audit line per pass: every tally as a count, plus — when the pass does not prove
    /// completion — the names of the buckets holding the latch closed. Counts only, never file
    /// names of own media beyond what existing reseal logs already record. The residue arithmetic
    /// reads `unopenableUnprefixed` (the unmarked, unopenable residue) and `refusedPlaintext` (the
    /// plaintext this pass will never seal) from this line, which is why both always ride it.
    private func logPass(_ result: MediaAtRestFormatMigrationResult) {
        var context: [String: String] = [
            "examined": String(result.examined),
            "alreadyCurrentFormat": String(result.alreadyCurrentFormat),
            "convertedPlaintext": String(result.convertedPlaintext),
            "conversionFailures": String(result.conversionFailures),
            "unopenableUnprefixed": String(result.unopenableUnprefixed),
            "refusedPlaintext": String(result.refusedPlaintext),
            "skippedConcurrentlyModified": String(result.skippedConcurrentlyModified),
            "empty": String(result.empty),
            "indeterminate": String(result.indeterminate)
        ]
        if !result.isClean {
            context["blocking"] = blockingBucketNames(of: result).joined(separator: ",")
        }
        FernletAuditLog.log("privateMedia.formatMigrationPass", context: context)
    }

    /// The names of every bucket (and abort flag) currently holding the latch closed.
    private func blockingBucketNames(of result: MediaAtRestFormatMigrationResult) -> [String] {
        var names: [String] = []
        if result.convertedPlaintext > 0 { names.append("convertedPlaintext") }
        if result.conversionFailures > 0 { names.append("conversionFailures") }
        if result.skippedConcurrentlyModified > 0 { names.append("skippedConcurrentlyModified") }
        if result.indeterminate > 0 { names.append("indeterminate") }
        if result.abortedNoOwnKey { names.append("abortedNoOwnKey") }
        if result.abortedNoWallKey { names.append("abortedNoWallKey") }
        return names
    }
}
