import Foundation
import FernletCrypto

// Phase 0 of `Docs/Plan-Crypto-Standardization-2026-08-27.md` for the media at-rest surface:
// **count the sealed media blobs on this device by FORMAT, without opening any of them.**
//
// The plan's §3 states the missing precondition plainly — nobody can count legacy blobs, and
// nothing may be deleted until that number is known and observed to reach zero. This file is that
// number for `MediaAtRestCrypto.swift`'s two generations: the current `FMA2`-marked boxes and the
// unprefixed boxes the pre-domain-separation build wrote (which
// ``PrivateMediaKeyProviding/gcmOpen(_:purpose:)`` still reads via its `legacy-read` branch).
//
// Three properties make this safe to run anywhere, including on a tester's device at launch:
//
// - **It never decrypts.** No key provider is involved anywhere in this file — the census is
//   constructible and runnable with *zero* cryptographic material, so it can never be the reason a
//   key is minted, unlocked, or touched. A blob's class comes from cleartext bytes the format puts
//   at offset 0 on purpose.
// - **It never reads more than the first four bytes of a file.** The corpora reach thousands of
//   files of hundreds of KB each; `FileHandle.read(upToCount:)` keeps a full census in the noise
//   whatever the corpus weighs.
// - **It never writes.** No file is created, rewritten, moved, or deleted; no `UserDefaults` key is
//   read or written. A census pass leaves the disk byte-identical (pinned by
//   `MediaAtRestFormatCensusTests`).
//
// - Important: a count is a count, not a proof. See ``MediaAtRestFormatTally/hasBlindSpots`` — the
//   fail-closed flag that says this pass could not see everything, and therefore that a
//   `unprefixedLegacyOrUnrecognized == 0` reading is not yet the zero Phase 3 is gated on.

// MARK: - What a blob's first bytes say

/// The at-rest FORMAT of one media file, decided from its first four bytes and nothing else.
///
/// This is a census vocabulary, not a read path. No case here claims a file *opens*: the census
/// holds no key and never tries. ``v2Marked`` means "carries the current marker", not "authenticates";
/// a truncated or corrupt `FMA2` box counts as ``v2Marked`` because that is exactly what the reader
/// would take it for.
public enum MediaAtRestFormatClass: String, Sendable, Equatable, CaseIterable {
    /// Begins with the four-byte `FMA2` marker (``MediaAtRestFormat/v2Marker``) — the current
    /// format, which every shipping writer emits. This is the bucket a completed migration drives
    /// everything else into.
    case v2Marked

    /// Begins with the JPEG marker bytes `FF D8 FF`: a **pre-sealing plaintext photo**.
    ///
    /// A legitimate generation, not corruption — the original meal corpus was written in the clear
    /// before sealing existed, and `MealPhotoStore` still recognises those bytes on read (behind
    /// `allowsLegacyPlaintextUpgrade` plus the pixel-bounds check) and re-seals them in place. It
    /// gets its own bucket because it is the one non-ciphertext generation on this surface, and
    /// lumping it in with unopenable ciphertext would hide a file whose plaintext IS on disk.
    case plaintextJPEG

    /// Non-empty and neither of the above: the pre-domain-separation format, whose boxes begin
    /// directly with the 12-byte GCM nonce — **or** bytes nothing recognises.
    ///
    /// The two cannot be told apart without a key, and the honest name says so. This is precisely
    /// the set the reader itself would hand to its `legacy-read` branch, so the bucket answers the
    /// question the plan asks ("how many blobs still take the legacy path?") even though it cannot
    /// answer "how many of those legacy blobs are healthy". A random nonce collides with `FMA2`
    /// with probability 2⁻³², and such a blob would be counted ``v2Marked`` and then fail to open —
    /// the fail-closed direction, and the same one the reader takes.
    case unprefixedLegacyOrUnrecognized

    /// A zero-byte file. Holds no generation and nothing a migration could convert, but it is on
    /// disk and therefore counted rather than skipped.
    case empty

    /// The bytes could not be READ at all — the open or the read failed.
    ///
    /// A different fact from every case above, and the difference is load-bearing. Media files are
    /// written `.completeFileProtection` (`MediaAtRestCrypto.sealAndWrite`), so a device that locks
    /// mid-census fails every read; scoring those as "no legacy blobs found" would let a pass that
    /// saw nothing look identical to a fully-migrated corpus and license the deletion of the legacy
    /// reader. "I could not see the bytes" is never "there are no legacy bytes". This is the same
    /// distinction `OwnPhotoKeyMigrationResult.indeterminate` exists for — read its doc comment for
    /// the house statement of why.
    case indeterminate
}

// MARK: - Tallies

/// The per-location (and, folded, whole-device) count of media blobs by format.
///
/// Every stored count is a number of FILES, one per ``MediaAtRestFormatClass`` case, plus two facts
/// about the sweep itself (``unlistableDirectories``, ``truncated``) that say where the census could
/// not see. Keeping those two out of the file buckets is deliberate: an unlistable directory hides
/// an *unknown* number of files, so folding it into ``indeterminate`` as "1" would quietly
/// understate the unknown.
public struct MediaAtRestFormatTally: Sendable, Equatable {
    /// Files carrying the current `FMA2` marker.
    public let v2Marked: Int
    /// Pre-sealing plaintext JPEGs (the meal corpus's legitimate legacy generation).
    public let plaintextJPEG: Int
    /// Unprefixed non-empty files: legacy sealed boxes, or bytes nothing recognises.
    public let unprefixedLegacyOrUnrecognized: Int
    /// Zero-byte files.
    public let empty: Int
    /// Files whose bytes could not be read at all (a locked container, an I/O error).
    public let indeterminate: Int
    /// Directories that EXIST but could not be enumerated. Each one hides an unknown number of
    /// files, which is why it is counted separately from ``indeterminate`` rather than as one of
    /// them. A directory that is simply absent is **not** counted here — nothing is hidden by a
    /// path that does not exist, so a fresh install reads as an honest zero. That absence is still
    /// reported, one level up, by ``MediaAtRestFormatLocationCensus/existed``.
    public let unlistableDirectories: Int
    /// Whether the per-directory file cap (``MediaAtRestFormatCensus/defaultMaxFilesPerDirectory``)
    /// stopped the sweep with files left unexamined. A capped sweep's counts are lower bounds.
    public let truncated: Bool

    /// Files this tally reached a verdict about: the sum of the five ``MediaAtRestFormatClass``
    /// buckets. Computed rather than stored so it cannot drift from the buckets it summarises.
    /// Excludes ``unlistableDirectories`` (which are directories, not files).
    public var examined: Int {
        v2Marked + plaintextJPEG + unprefixedLegacyOrUnrecognized + empty + indeterminate
    }

    /// Whether this pass could not see everything it swept — the fail-closed signal.
    ///
    /// Phase 3 of the plan deletes the legacy reader only once a surface's legacy count is observed
    /// to be zero on real devices. A zero from a pass with blind spots is not that observation: it
    /// may mean "no legacy blobs", or it may mean "the device was locked". Gate on
    /// `!hasBlindSpots && unprefixedLegacyOrUnrecognized == 0`, never on the count alone. This is
    /// the census's analogue of `OwnPhotoKeyMigrationResult.isClean`.
    public var hasBlindSpots: Bool {
        indeterminate > 0 || unlistableDirectories > 0 || truncated
    }

    /// The all-zero tally — a location that exists and holds nothing, or one that is absent.
    public static let zero = MediaAtRestFormatTally()

    /// Creates a tally. Public so a caller (or a test) can state an expectation directly; the
    /// census builds its own from what it saw on disk.
    public init(
        v2Marked: Int = 0,
        plaintextJPEG: Int = 0,
        unprefixedLegacyOrUnrecognized: Int = 0,
        empty: Int = 0,
        indeterminate: Int = 0,
        unlistableDirectories: Int = 0,
        truncated: Bool = false
    ) {
        self.v2Marked = v2Marked
        self.plaintextJPEG = plaintextJPEG
        self.unprefixedLegacyOrUnrecognized = unprefixedLegacyOrUnrecognized
        self.empty = empty
        self.indeterminate = indeterminate
        self.unlistableDirectories = unlistableDirectories
        self.truncated = truncated
    }

    /// Builds a tally from a classified-file histogram (the census's internal path).
    init(counts: [MediaAtRestFormatClass: Int], unlistableDirectories: Int = 0, truncated: Bool = false) {
        self.init(
            v2Marked: counts[.v2Marked] ?? 0,
            plaintextJPEG: counts[.plaintextJPEG] ?? 0,
            unprefixedLegacyOrUnrecognized: counts[.unprefixedLegacyOrUnrecognized] ?? 0,
            empty: counts[.empty] ?? 0,
            indeterminate: counts[.indeterminate] ?? 0,
            unlistableDirectories: unlistableDirectories,
            truncated: truncated
        )
    }

    /// The count for one format class — for a diagnostic row that renders
    /// ``MediaAtRestFormatClass/allCases`` without restating the field list.
    public func count(of formatClass: MediaAtRestFormatClass) -> Int {
        switch formatClass {
        case .v2Marked: return v2Marked
        case .plaintextJPEG: return plaintextJPEG
        case .unprefixedLegacyOrUnrecognized: return unprefixedLegacyOrUnrecognized
        case .empty: return empty
        case .indeterminate: return indeterminate
        }
    }

    /// Folds another tally into this one. `truncated` is a disjunction: one capped location makes
    /// the aggregate a lower bound.
    public func adding(_ other: MediaAtRestFormatTally) -> MediaAtRestFormatTally {
        MediaAtRestFormatTally(
            v2Marked: v2Marked + other.v2Marked,
            plaintextJPEG: plaintextJPEG + other.plaintextJPEG,
            unprefixedLegacyOrUnrecognized: unprefixedLegacyOrUnrecognized + other.unprefixedLegacyOrUnrecognized,
            empty: empty + other.empty,
            indeterminate: indeterminate + other.indeterminate,
            unlistableDirectories: unlistableDirectories + other.unlistableDirectories,
            truncated: truncated || other.truncated
        )
    }
}

/// One physical location's census entry: which path was swept, whether it was a directory of media
/// files or a single named file, and what was found there.
///
/// Per-location rather than one grand total because the surface is seven sealed locations across
/// two roots with different key custody — meal, recipe and progress photos plus the progress index
/// under Documents; wall photos, thumbnails and the sealed wall index under the proximity support
/// directory — plus the wall's pre-sealing plaintext index, swept as an eighth. A migration lands
/// one corpus at a time, so "how many legacy blobs are left" is only actionable per corpus.
public struct MediaAtRestFormatLocationCensus: Sendable, Equatable {
    /// Whether the swept path is a flat directory of media files or one individually-named file.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// A flat directory of `<uuid>.jpg` media files, enumerated non-recursively.
        case directory
        /// A single named file (a sealed index).
        case file
    }

    /// The swept path.
    public let url: URL
    /// What kind of location it is.
    public let kind: Kind
    /// Whether the path was actually THERE when the sweep reached it.
    ///
    /// The fact an all-zero ``tally`` cannot carry on its own. "This corpus exists and holds no
    /// legacy blobs" and "this corpus is not on this device" are the same five zeros, and they mean
    /// opposite things to a migration gate: the first is evidence, the second is the absence of a
    /// corpus to have evidence about. A whole sweep whose locations are ALL absent is the shape a
    /// census pointed at the wrong roots takes — see
    /// ``MediaAtRestFormatCensusReport/allLocationsAbsent`` — and it must not read as swept-clean.
    ///
    /// Still not a ``MediaAtRestFormatTally/hasBlindSpots``, and deliberately so: a path that does
    /// not exist hides nothing, so a fresh install's per-location zeros stay honest zeros.
    public let existed: Bool
    /// What the sweep found. All-zero for a path that does not exist — read it beside ``existed``,
    /// never alone.
    public let tally: MediaAtRestFormatTally

    /// Creates an entry. Public so tests can state expectations directly.
    ///
    /// `existed` has no default on purpose: a caller stating an expectation has to say which of the
    /// two all-zero meanings it means.
    public init(url: URL, kind: Kind, existed: Bool, tally: MediaAtRestFormatTally) {
        self.url = url
        self.kind = kind
        self.existed = existed
        self.tally = tally
    }
}

/// The result of one census pass: every location swept, in the order it was swept, plus the fold.
public struct MediaAtRestFormatCensusReport: Sendable, Equatable {
    /// Per-location entries, in sweep order (each location set's directories, then its files).
    /// Locations are **not** de-duplicated: a caller that passes overlapping location sets gets an
    /// entry per sweep, and ``tally(for:)`` sums them.
    public let locations: [MediaAtRestFormatLocationCensus]

    /// Creates a report. Public so tests can state expectations directly.
    public init(locations: [MediaAtRestFormatLocationCensus]) {
        self.locations = locations
    }

    /// The whole-pass fold across every location — the single number the plan's Phase 0 asks for,
    /// carrying its own ``MediaAtRestFormatTally/hasBlindSpots`` caveat.
    public var total: MediaAtRestFormatTally {
        locations.reduce(MediaAtRestFormatTally.zero) { $0.adding($1.tally) }
    }

    /// How many swept locations were not on disk at all (see
    /// ``MediaAtRestFormatLocationCensus/existed``). Normal and expected on most devices — the
    /// friend wall has no directories until a first photo arrives — so it is reported as context
    /// beside the numbers, not as a fault.
    public var absentLocationCount: Int {
        locations.filter { !$0.existed }.count
    }

    /// Whether EVERY swept location was absent — the reading a diagnostic must not present as a
    /// clean sweep.
    ///
    /// One absent corpus is a device that has not used that feature. All of them absent is a
    /// different claim: on a device that has been running the app, it is the signature of a census
    /// pointed at roots the store is not actually using (the two media roots are per-`FernletStore`
    /// instance state, not process constants). The numbers are still zeros, and they are still
    /// honest; what they are not is evidence that anything was swept.
    ///
    /// `false` for an empty report — a pass that swept no locations makes no claim either way.
    public var allLocationsAbsent: Bool {
        !locations.isEmpty && locations.allSatisfy { !$0.existed }
    }

    /// The tally for one swept path, or nil when no entry names it.
    ///
    /// Paths are compared `standardizedFileURL`-wise so a caller need not reproduce the exact
    /// trailing-slash spelling the layout helpers used.
    public func tally(for url: URL) -> MediaAtRestFormatTally? {
        let target = url.standardizedFileURL
        let matches = locations.filter { $0.url.standardizedFileURL == target }
        guard !matches.isEmpty else { return nil }
        return matches.reduce(MediaAtRestFormatTally.zero) { $0.adding($1.tally) }
    }
}

// MARK: - The friend wall's on-disk layout

/// The on-disk layout of the FRIEND-WALL media corpus, in ONE place — the counterpart to
/// ``OwnPhotoCorpusLayout`` for the other root.
///
/// The own-photo corpora already have a layout type because three owners must agree on their names.
/// The wall never grew one: `PrivateMediaStore` derives its two directories from the `indexURL` its
/// single caller passes, and both the directory names and the sealed-index extension are `private`
/// to that type. Nothing outside it could name the wall's files — which is exactly what a census of
/// the wall needs to do — so this is that name, and from here on it is the single source of truth
/// for anything sweeping the wall from outside the store.
///
/// - Important: because the store's own literals are private, this is a **restatement, not a
///   reference**, and it must agree with them by review:
///   - `PrivateMediaStore.swift:82-87` — `MeshPhotos/` and `MeshPhotoThumbnails/` are created as
///     siblings of the index, and the sealed index is the index path with its extension replaced by
///     `sealed`.
///   - `MeshNetworkManager.swift:376-386` — the one production caller passes
///     `<proximitySupportDirectory>/MeshPhotoCache.json` as that index path, which makes the sealed
///     index `MeshPhotoCache.sealed` in the same directory.
///   A name that drifts on either side does not fail a build; it makes a wall census report a
///   confident zero for a corpus that is plainly full of photos. That is the first thing to check
///   if it ever does.
///
/// Concurrency: `nonisolated` namespace of pure path arithmetic; no state.
public enum FriendWallCorpusLayout {
    /// Full-size peer photos (`<uuid>.jpg`, sealed).
    public static let photosDirectoryName = "MeshPhotos"
    /// Peer photo thumbnails (`<uuid>.jpg`, sealed).
    public static let thumbnailsDirectoryName = "MeshPhotoThumbnails"
    /// The sealed metadata index — sender names, fingerprints and times, under the same seal as the
    /// bytes it describes.
    public static let sealedIndexFileName = "MeshPhotoCache.sealed"
    /// The pre-sealing PLAINTEXT index, which `PrivateMediaStore.loadIndex()` reads once, rewrites
    /// sealed, and only then deletes. Swept like everything else rather than special-cased: whether
    /// a given device still has one is a fact the census should report, and the byte rule already
    /// has an honest bucket for it (JSON begins with neither the marker nor the JPEG bytes, so it
    /// lands in ``MediaAtRestFormatClass/unprefixedLegacyOrUnrecognized`` — "unrecognised", which
    /// for an unsealed file is precisely right).
    public static let legacyPlaintextIndexFileName = "MeshPhotoCache.json"

    /// Every on-disk location the friend wall seals under the friend-wall media key, for a wall
    /// rooted at `supportDirectory` (the app's per-host proximity support directory).
    ///
    /// Reuses ``OwnPhotoSealedLocations`` — the name says "own photo", but the type is a plain
    /// "flat directories plus named files" location set with no own-photo semantics in it, and one
    /// shape means the census sweeps both roots with one code path.
    public static func sealedLocations(in supportDirectory: URL) -> OwnPhotoSealedLocations {
        OwnPhotoSealedLocations(
            directories: [
                supportDirectory.appendingPathComponent(photosDirectoryName, isDirectory: true),
                supportDirectory.appendingPathComponent(thumbnailsDirectoryName, isDirectory: true)
            ],
            files: [
                supportDirectory.appendingPathComponent(sealedIndexFileName),
                supportDirectory.appendingPathComponent(legacyPlaintextIndexFileName)
            ]
        )
    }

    /// The subset of ``sealedLocations(in:)`` a FORMAT migrator may rewrite: the two photo
    /// directories plus the sealed index.
    ///
    /// The pre-sealing PLAINTEXT index (``legacyPlaintextIndexFileName``) is **deliberately
    /// excluded**, and the exclusion is load-bearing rather than an omission. Its migration
    /// already exists, shipped, and correctly ordered: `PrivateMediaStore.loadIndex()` reads it
    /// once, rewrites `MeshPhotoCache.sealed`, and deletes the plaintext original only after the
    /// sealed file exists. A format migrator that sealed it independently would race that flow
    /// and would have to replicate its decode + cap + orphan-sweep semantics (`save(_:)` deletes
    /// files — machinery a never-delete migrator must not invoke). And excluding it is *safe*:
    /// the file is read via `Data` + `JSONDecoder`, never through `gcmOpen`, so deleting the
    /// legacy-read branch cannot strand it. The census keeps sweeping it (its
    /// ``sealedLocations(in:)`` row) so the residue stays visible until a wall load retires it.
    public static func resealableLocations(in supportDirectory: URL) -> OwnPhotoSealedLocations {
        OwnPhotoSealedLocations(
            directories: [
                supportDirectory.appendingPathComponent(photosDirectoryName, isDirectory: true),
                supportDirectory.appendingPathComponent(thumbnailsDirectoryName, isDirectory: true)
            ],
            files: [supportDirectory.appendingPathComponent(sealedIndexFileName)]
        )
    }

    /// The AEAD purpose a wall file at `url` is sealed under, derived from this fixed, app-owned
    /// layout — the wall analogue of ``OwnPhotoCorpusLayout/sealPurpose(for:)``, and living here
    /// for the same reason: it IS layout knowledge, and anything opening wall bytes outside their
    /// owning store must agree with `PrivateMediaStore`'s own per-location purposes.
    ///
    /// Fixed layout arithmetic only: the sealed index is matched by its one frozen file name and
    /// the thumbnail directory by its one frozen component — untrusted file names never select or
    /// construct a purpose.
    public static func sealPurpose(for url: URL) -> CryptographicPurpose {
        if url.lastPathComponent == sealedIndexFileName {
            return FernletCryptoPurpose.AEAD.privateFriendPhotoIndexV2
        }
        if url.pathComponents.contains(thumbnailsDirectoryName) {
            return FernletCryptoPurpose.AEAD.privateFriendPhotoThumbnailV2
        }
        return FernletCryptoPurpose.AEAD.privateFriendPhotoImageV2
    }
}

// MARK: - The census

/// The read-only, key-free format census over one or more media location sets.
///
/// Build it with explicit locations — either the two app roots (``init(ownPhotoDocumentsDirectory:friendWallSupportDirectory:maxFilesPerDirectory:)``)
/// or arbitrary location sets (``init(locationSets:maxFilesPerDirectory:)``) — and call ``run()``.
/// Nothing about it touches the keychain, so a DEBUG diagnostic row can call it while the app is
/// locked and get an honest answer (a large ``MediaAtRestFormatTally/indeterminate``) rather than a
/// prompt or a crash.
///
/// Concurrency: a `nonisolated` value type over `FileManager` and `FileHandle`; `Sendable`, so it
/// can be built on the main actor and run off it.
public struct MediaAtRestFormatCensus: Sendable {
    /// R2/R3: the named per-directory bound on files **examined**. Generous by design — the corpus
    /// caps are 1000 wall photos + 1000 thumbnails and 2000 progress photos, while the meal corpus
    /// is uncapped (a heavy user sits in the hundreds to low thousands) — so a real device is not
    /// expected to reach it. It exists so a directory that has somehow grown pathological cannot
    /// turn a diagnostic into an unbounded sweep, and hitting it is REPORTED
    /// (``MediaAtRestFormatTally/truncated``) rather than silently absorbed.
    ///
    /// - Important: it bounds the CLASSIFICATION work — the opens, the header reads, the byte
    ///   comparisons — and not the listing. `contentsOfDirectory` materialises the whole directory
    ///   first, and the sweep then sorts that array so a truncated pass examines a deterministic
    ///   prefix rather than whatever order the filesystem handed back. Peak cost for a pathological
    ///   directory is therefore one array of URLs (cheap, and bounded by the directory itself)
    ///   plus at most this many four-byte reads. Enumerating lazily would trade that array for a
    ///   non-deterministic truncation, which is the worse bargain for a migration gate.
    public static let defaultMaxFilesPerDirectory = 10_000

    /// The JPEG marker bytes a pre-sealing plaintext photo begins with (SOI + the first byte of the
    /// next marker). Three bytes is the standard sniff and is enough to separate a photo from a
    /// sealed box.
    private static let jpegMagic = Data([0xFF, 0xD8, 0xFF] as [UInt8])

    /// How many bytes of a file the census is ever allowed to read: enough for the longest of the
    /// two signatures it compares, and not one byte more. Photo bytes are never in memory here.
    private static var headerByteCount: Int {
        max(MediaAtRestFormat.v2MarkerByteCount, jpegMagic.count)
    }

    private let locationSets: [OwnPhotoSealedLocations]
    private let maxFilesPerDirectory: Int

    /// Creates a census over explicit location sets.
    ///
    /// - Parameters:
    ///   - locationSets: One or more location sets to sweep, in order. Missing paths are skipped
    ///     (and report zeros with ``MediaAtRestFormatLocationCensus/existed`` `false`, so a caller
    ///     can tell them from swept-empty ones), exactly as `OwnPhotoKeyMigrator.candidateFiles()`
    ///     skips them.
    ///   - maxFilesPerDirectory: Per-directory bound on files examined; values below 1 are clamped
    ///     to 1 rather than silently censusing nothing.
    public init(
        locationSets: [OwnPhotoSealedLocations],
        maxFilesPerDirectory: Int = MediaAtRestFormatCensus.defaultMaxFilesPerDirectory
    ) {
        self.locationSets = locationSets
        // R7: validate at entry. A zero or negative cap would examine no files and report a
        // confident, wrong zero — the one answer this type must never give.
        self.maxFilesPerDirectory = max(1, maxFilesPerDirectory)
    }

    /// Creates the production census over both media roots: the user's own photos under the app's
    /// documents directory, and the friend wall under the proximity support directory.
    ///
    /// The two are separate roots with separate key custody, and neither contains the other — which
    /// is why both are parameters rather than one derived from the other.
    public init(
        ownPhotoDocumentsDirectory: URL,
        friendWallSupportDirectory: URL,
        maxFilesPerDirectory: Int = MediaAtRestFormatCensus.defaultMaxFilesPerDirectory
    ) {
        self.init(
            locationSets: [
                OwnPhotoCorpusLayout.sealedLocations(in: ownPhotoDocumentsDirectory),
                FriendWallCorpusLayout.sealedLocations(in: friendWallSupportDirectory)
            ],
            maxFilesPerDirectory: maxFilesPerDirectory
        )
    }

    /// Sweeps every configured location once and reports what it found.
    ///
    /// R7: deliberately not `@discardableResult` — the report IS the point, and a caller that
    /// ignores it did no work.
    public func run() -> MediaAtRestFormatCensusReport {
        var locations: [MediaAtRestFormatLocationCensus] = []
        // R2: both loops iterate finite, caller-supplied arrays; the per-directory bound on files
        // EXAMINED lives in `tally(ofFilesIn:)`.
        for locationSet in locationSets {
            for directory in locationSet.directories {
                locations.append(census(ofDirectory: directory))
            }
            for file in locationSet.files {
                locations.append(census(ofFile: file))
            }
        }
        return MediaAtRestFormatCensusReport(locations: locations)
    }

    /// The format of the file at `url`, from at most its first four bytes.
    ///
    /// Pure and side-effect-free: it opens the file read-only, reads the header, closes it, and
    /// never decrypts, rewrites, or retains anything. Exposed because it is the census's atom and a
    /// caller inspecting one specific blob (a diagnostic, a future migrator's per-file check)
    /// should not have to re-derive the byte rule.
    public static func format(ofFileAt url: URL) -> MediaAtRestFormatClass {
        guard let head = firstBytes(of: url) else { return .indeterminate }
        return format(ofHeader: head)
    }

    /// The byte rule of ``format(ofFileAt:)`` over bytes the caller has ALREADY read — the head of
    /// a file, or the whole file.
    ///
    /// This is the share-the-classifier seam: `MediaAtRestFormatMigrator` re-checks a file's class
    /// over its convert-time full read through this exact function, so the migrator and the census
    /// cannot disagree about what a blob is by construction. `starts(with:)` inspects only the
    /// leading bytes, so passing a whole file is equivalent to passing its head. Never `nil`-able:
    /// "could not read the bytes" is the CALLER's fact (``format(ofFileAt:)`` maps it to
    /// ``MediaAtRestFormatClass/indeterminate``); bytes in hand always classify.
    public static func format(ofHeader bytes: Data) -> MediaAtRestFormatClass {
        if bytes.isEmpty { return .empty }
        if bytes.starts(with: MediaAtRestFormat.v2Marker) { return .v2Marked }
        if bytes.starts(with: jpegMagic) { return .plaintextJPEG }
        return .unprefixedLegacyOrUnrecognized
    }

    // MARK: - Sweeping one location

    /// Censuses one flat directory of media files.
    ///
    /// Three outcomes, and the difference between the last two is the whole fail-closed story: a
    /// path that does not exist (or is not a directory) is an honest all-zero, marked
    /// ``MediaAtRestFormatLocationCensus/existed`` `false` so it cannot be mistaken for a swept-empty
    /// corpus; a directory that exists but will not enumerate hides an unknown number of files and
    /// is counted as one ``MediaAtRestFormatTally/unlistableDirectories``; anything else is a
    /// per-file tally.
    private func census(ofDirectory directory: URL) -> MediaAtRestFormatLocationCensus {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return MediaAtRestFormatLocationCensus(url: directory, kind: .directory, existed: false, tally: .zero)
        }
        // Non-recursive, hidden files skipped — the same enumeration
        // `OwnPhotoKeyMigrator.candidateFiles()` performs, because these are the same flat
        // id-to-file corpora and the two passes must agree on what "every file" means.
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return MediaAtRestFormatLocationCensus(
                url: directory,
                kind: .directory,
                existed: true,
                tally: MediaAtRestFormatTally(unlistableDirectories: 1)
            )
        }
        return MediaAtRestFormatLocationCensus(
            url: directory,
            kind: .directory,
            existed: true,
            tally: tally(ofFilesIn: contents)
        )
    }

    /// The bucket ONE listed directory entry belongs in, from what the filesystem said about its
    /// type — or `nil` for an entry that was never a media blob and is skipped.
    ///
    /// The three-way split is the point, and `isRegularFile` is deliberately an `Optional<Bool>` so
    /// the caller cannot collapse it to two:
    /// - `true` — a regular file. Classified by its bytes (``format(ofFileAt:)``).
    /// - `false` — POSITIVELY not a regular file: a subdirectory, a socket, a fifo, a symlink
    ///   (including a dangling one, which `URLResourceValues` reports cleanly as `false` rather
    ///   than failing). Nothing a media writer ever produced, so it is skipped and does not consume
    ///   the per-directory budget.
    /// - `nil` — the type could not be READ. The entry is listed, so something is there, and its
    ///   nature is unknown; dropping it would delete a file from every bucket including
    ///   ``MediaAtRestFormatTally/examined``, which is a silent subtraction from the corpus the
    ///   Phase 3 gate is counting. It is examined as ``MediaAtRestFormatClass/indeterminate``, the
    ///   same fail-closed direction an unreadable file's bytes take.
    ///
    /// Public because it is the seam the failure case is testable at: `contentsOfDirectory(at:
    /// includingPropertiesForKeys:)` PREFETCHES the requested keys onto the URLs it returns, so a
    /// per-entry resource-value failure is not deterministically constructible from outside this
    /// type (see `MediaAtRestFormatCensusTests`).
    public static func format(ofListedEntry url: URL, isRegularFile: Bool?) -> MediaAtRestFormatClass? {
        guard isRegularFile != false else { return nil }
        guard isRegularFile == true else { return .indeterminate }
        return format(ofFileAt: url)
    }

    /// Classifies up to ``maxFilesPerDirectory`` entries from one directory listing.
    ///
    /// Sorted by path first so that WHICH files a truncated sweep examined is deterministic — a
    /// census whose numbers moved between passes over an unchanged corpus would be useless as a
    /// migration gate.
    private func tally(ofFilesIn contents: [URL]) -> MediaAtRestFormatTally {
        var counts: [MediaAtRestFormatClass: Int] = [:]
        var examined = 0
        var truncated = false
        // R2: bounded twice over — a finite listing, and the named per-directory cap on the files
        // this loop EXAMINES (the listing itself is already materialised; see the cap's own doc).
        for url in contents.sorted(by: { $0.path < $1.path }) {
            let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
            guard let formatClass = Self.format(ofListedEntry: url, isRegularFile: isRegularFile) else { continue }
            guard examined < maxFilesPerDirectory else {
                truncated = true
                break
            }
            examined += 1
            counts[formatClass, default: 0] += 1
        }
        return MediaAtRestFormatTally(counts: counts, truncated: truncated)
    }

    /// Censuses one individually-named file (a sealed index). An absent file is an honest all-zero,
    /// never an ``MediaAtRestFormatClass/indeterminate`` — nothing is hidden by a path that is not
    /// there — and it says which of the two it was through
    /// ``MediaAtRestFormatLocationCensus/existed``.
    private func census(ofFile file: URL) -> MediaAtRestFormatLocationCensus {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return MediaAtRestFormatLocationCensus(url: file, kind: .file, existed: false, tally: .zero)
        }
        return MediaAtRestFormatLocationCensus(
            url: file,
            kind: .file,
            existed: true,
            tally: MediaAtRestFormatTally(counts: [Self.format(ofFileAt: file): 1])
        )
    }

    /// Reads at most ``headerByteCount`` bytes from the head of `url`, or nil when the file could
    /// not be opened, read, or cleanly closed.
    ///
    /// Returns an EMPTY `Data` for a zero-byte file (`read(upToCount:)` answers nil at EOF), which
    /// the caller turns into ``MediaAtRestFormatClass/empty`` — distinct from the nil this returns
    /// for "could not see the bytes at all".
    ///
    /// A failure to CLOSE after a successful read also scores nil, and therefore indeterminate.
    /// Conservative on purpose: the census would rather report a blind spot it does not have than
    /// hand a migration gate a class it did not obtain cleanly, and a filesystem that cannot close
    /// a read-only descriptor is not one whose listing should be trusted either.
    private static func firstBytes(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        do {
            let head = try handle.read(upToCount: headerByteCount)
            try handle.close()
            return head ?? Data()
        } catch {
            // Named, not swallowed (R7): both failure modes mean the same thing to the caller —
            // this file's format is unknown — and the handle closes on deallocation, so the
            // descriptor does not leak on the way out.
            return nil
        }
    }
}
