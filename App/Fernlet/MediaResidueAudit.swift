// MediaResidueAudit.swift
// Fernlet
//
// The media gate's residue audit: it names each swept location by corpus LABEL — never by path —
// and does the plan's residue arithmetic over the census table PLUS a live migrator pass result.
//
// WHAT THIS DELIBERATELY DOES NOT DO, and why the rule was withdrawn. An earlier shape classified an
// unprefixed byte in any born-sealed corpus as blocking, on the grounds that
// `allowsLegacyPlaintextUpgrade` is true only for the meal store. That flag governs PLAINTEXT, not
// unprefixed CIPHERTEXT, and the migrator's own Phase-3 argument contradicts the rule:
// `unopenableUnprefixed` is deliberately absent from `MediaAtRestFormatMigrationResult.isClean`, its
// doc states the claim that makes it non-blocking — "the bytes were read, every key the legacy branch
// could ever pair them with was tried, and nothing opens them" — and `dispatchUnprefixedWall` routes
// an unopenable WALL byte straight into it. So MeshPhotos/, MeshPhotoThumbnails/ and
// MeshPhotoCache.sealed can each hold unprefixed bytes on a cleanly latched device, and the rule
// would have rendered BLOCKED on a device the migrator itself considers Phase-3-safe, permanently,
// with no remediation — because a latched device runs no further pass.
//
// The same doc block settles the other named residue the other way: a pre-sealing plaintext non-JPEG
// in the meal corpus "lands here … A named expected residue for the Phase-3 gate". So
// `unopenableUnprefixed` already IS the plan's residue evidence, positively produced by a pass rather
// than sniffed by a second classifier — which is why there is no image-magic sub-classifier here and
// why this type does no file I/O of its own.
//
// DEBUG-ONLY for the reason stated at CryptoFormatCensus.swift:15-21.

#if DEBUG

import Foundation
import PrivateMediaStore

// MARK: - Corpus labels

/// The eight locations `MediaAtRestFormatCensus` sweeps, named by CORPUS rather than by path.
///
/// The readout is designed to be copied off the device, and a raw container URL is an install
/// identifier. Own-photo corpora are flat `<uuid>.jpg` files whose names ARE join keys into
/// `Meal.photoID`, recipe ids and progress-photo ids; the wall's names key rows in a sealed index
/// carrying sender names and fingerprints. So the audit carries a label or nothing.
nonisolated enum MediaCorpusLabel: String, Sendable, CaseIterable {
    /// `MealPhotos/` — the one corpus with a legitimate pre-sealing plaintext generation.
    case mealPhotos
    /// `RecipePhotos/` — born sealed.
    case recipePhotos
    /// `ProgressPhotos/Photos/` — born sealed.
    case progressPhotos
    /// `ProgressPhotos/index.bin` — the sealed progress timeline index.
    case progressIndex
    /// `MeshPhotos/` — full-size friend-wall photos.
    case wallPhotos
    /// `MeshPhotoThumbnails/` — friend-wall thumbnails.
    case wallThumbnails
    /// `MeshPhotoCache.sealed` — the sealed wall metadata index.
    case wallIndexSealed
    /// `MeshPhotoCache.json` — the pre-sealing PLAINTEXT wall index. Residue B: swept by the census,
    /// deliberately excluded from `FriendWallCorpusLayout.resealableLocations`, so the migrator never
    /// enumerates it and it can never appear in the pass's `unopenableUnprefixed` bucket.
    case wallIndexLegacyPlaintext

    /// The label as the row prints it.
    var displayName: String {
        switch self {
        case .mealPhotos: return "Meal photos"
        case .recipePhotos: return "Recipe photos"
        case .progressPhotos: return "Progress photos"
        case .progressIndex: return "Progress index"
        case .wallPhotos: return "Wall photos"
        case .wallThumbnails: return "Wall thumbnails"
        case .wallIndexSealed: return "Wall index (sealed)"
        case .wallIndexLegacyPlaintext: return "Wall index (plaintext, legacy)"
        }
    }

    /// Whether this location is one of the two wall photo corpora whose plaintext JPEGs are residue
    /// C's signature — an `abortedNoWallKey` wall root.
    var isWallPhotoCorpus: Bool { self == .wallPhotos || self == .wallThumbnails }

    /// Names the location at `url` by comparing it against the eight expected URLs the two corpus
    /// layouts build. Returns nil for anything it cannot name — a location the census swept that
    /// this vocabulary does not cover.
    ///
    /// Never interpolates an untrusted path component into display text: the comparison is against
    /// URLs this function built itself.
    static func label(
        for url: URL,
        ownPhotoDocumentsDirectory: URL,
        friendWallSupportDirectory: URL
    ) -> MediaCorpusLabel? {
        let expected = expectedURLs(
            ownPhotoDocumentsDirectory: ownPhotoDocumentsDirectory,
            friendWallSupportDirectory: friendWallSupportDirectory
        )
        let standardized = url.standardizedFileURL
        // R2: bounded by the eight expected locations.
        return expected.first { $0.url == standardized }?.label
    }

    /// The eight expected locations, in the order `MediaAtRestFormatCensus.run()` sweeps them.
    static func expectedURLs(
        ownPhotoDocumentsDirectory: URL,
        friendWallSupportDirectory: URL
    ) -> [(label: MediaCorpusLabel, url: URL)] {
        let own = OwnPhotoCorpusLayout.sealedLocations(in: ownPhotoDocumentsDirectory)
        let wall = FriendWallCorpusLayout.sealedLocations(in: friendWallSupportDirectory)
        let ordered: [MediaCorpusLabel] = [
            .mealPhotos, .recipePhotos, .progressPhotos, .progressIndex,
            .wallPhotos, .wallThumbnails, .wallIndexSealed, .wallIndexLegacyPlaintext
        ]
        let urls = own.directories + own.files + wall.directories + wall.files
        guard urls.count == ordered.count else { return [] }
        return zip(ordered, urls).map { ($0, $1.standardizedFileURL) }
    }
}

// MARK: - Per-location verdict

/// What one swept location's unprefixed bytes are, in the four-case vocabulary the residue rule
/// needs — plus the case for a location this audit could not name.
///
/// ``unopenableCandidate`` is the case that keeps the withdrawn born-sealed rule from coming back:
/// an unprefixed byte in a born-sealed location is a CANDIDATE for the migrator's non-blocking
/// argument, and the row says exactly that rather than guessing in either direction. It is
/// subtracted from ``MediaResidueAudit/unaccountedUnprefixed`` only when a live pass witness
/// confirms the count — never on inference.
nonisolated enum ResidueVerdict: Sendable, Equatable {
    /// No unprefixed bytes here.
    case clean
    /// Unprefixed bytes the plan already names as an expected residue for this location.
    case namedResidue(String)
    /// Unprefixed bytes that a live pass may account for through `unopenableUnprefixed`.
    case unopenableCandidate(String)
    /// Unprefixed bytes a live pass looked at and did NOT account for.
    case blocking(String)
    /// A location this vocabulary cannot name — reported rather than silently folded in.
    case unnamedLocation

    /// The verdict as the row prints it.
    var displayName: String {
        switch self {
        case .clean: return "clean"
        case let .namedResidue(reason): return "named residue — \(reason)"
        case let .unopenableCandidate(reason): return "unopenable candidate — \(reason)"
        case let .blocking(reason): return "BLOCKING — \(reason)"
        case .unnamedLocation: return "UNNAMED LOCATION — this audit's vocabulary does not cover it"
        }
    }
}

/// One swept location's row in the audit.
nonisolated struct MediaLocationAudit: Sendable, Equatable {
    /// The corpus this location holds, or nil when the audit could not name it.
    let label: MediaCorpusLabel?
    /// Whether the location is a flat directory of media files or one named file.
    let kind: MediaAtRestFormatLocationCensus.Kind
    /// Whether the path was actually THERE — the fact an all-zero tally cannot carry.
    let existed: Bool
    /// What the sweep found.
    let tally: MediaAtRestFormatTally
    /// What this location's unprefixed bytes are.
    let residueVerdict: ResidueVerdict

    /// Creates a location row.
    init(
        label: MediaCorpusLabel?,
        kind: MediaAtRestFormatLocationCensus.Kind,
        existed: Bool,
        tally: MediaAtRestFormatTally,
        residueVerdict: ResidueVerdict
    ) {
        self.label = label
        self.kind = kind
        self.existed = existed
        self.tally = tally
        self.residueVerdict = residueVerdict
    }

    /// The row as the readout prints it. Label, existence, the five class counts, the verdict — no
    /// file name and no path.
    var printedLine: String {
        "\(label?.displayName ?? "unnamed") (\(kind.rawValue), existed \(existed)):"
            + " unprefixed \(tally.unprefixedLegacyOrUnrecognized) · plaintextJPEG \(tally.plaintextJPEG)"
            + " · v2 \(tally.v2Marked) · empty \(tally.empty) · indeterminate \(tally.indeterminate)"
            + " · unlistableDirectories \(tally.unlistableDirectories) · truncated \(tally.truncated)"
            + " — \(residueVerdict.displayName)"
    }
}

// MARK: - The audit

/// The media gate's residue audit: a pure fold over values already in hand.
///
/// **No file I/O of its own, no directory enumeration, no second sweep.** The only sweeps it folds
/// are the census's (which the local scan already took) and the migrator pass's (which the readout's
/// media control funds), and the two are taken in one detached job, in a fixed order, so both terms
/// of the subtraction describe one filesystem state.
///
/// **No media file NAME and no filesystem path is retained anywhere in this type.** See
/// ``MediaCorpusLabel``.
///
/// The arithmetic, printed rather than left to the reader:
/// ```
/// census unprefixed (whole device)                                    = U
/// − undrained MeshPhotoCache.json (residue B)                         = J
/// − pass unopenableUnprefixed (residue A + born-sealed unopenables)   = K
/// = unaccounted                                                        = U − J − K
/// ```
/// ``unaccountedUnprefixed`` is `nil` — not zero, not a guess — whenever there is no pass witness,
/// and the gate row then renders `.notTaken`. That is the fail-loud direction.
///
/// Residue B cannot be double-counted: `MeshPhotoCache.json` is swept as its own named `.file`
/// location and is deliberately excluded from `FriendWallCorpusLayout.resealableLocations(in:)`, so
/// the migrator never enumerates it and it can never appear in K.
///
/// Residue C is a reported SHAPE, never a subtraction: a plaintext JPEG is census class
/// `plaintextJPEG`, never `unprefixed` — "the split the Phase-3 gate arithmetic relies on" — so it
/// contributes zero to the subtraction. See ``keylessWallSignature``.
nonisolated struct MediaResidueAudit: Sendable, Equatable {
    /// One row per swept location, in sweep order.
    let locations: [MediaLocationAudit]
    /// U — the census's whole-device unprefixed count.
    let censusUnprefixedTotal: Int
    /// J — residue B, the undrained plaintext wall index's unprefixed count.
    let meshPhotoCacheUnprefixed: Int
    /// K — the live pass's `unopenableUnprefixed`, or nil when no pass was observed.
    let passUnopenableUnprefixed: Int?
    /// U − J − K, or nil when K is absent. **Never a computed zero without a witness.**
    let unaccountedUnprefixed: Int?
    /// Whether the census sweep could not see everything it swept.
    let hasBlindSpots: Bool
    /// Files whose bytes could not be read at all.
    let indeterminate: Int
    /// Directories that exist and would not enumerate — each hiding an unknown COUNT.
    let unlistableDirectories: Int
    /// Whether a per-directory cap stopped the sweep.
    let truncated: Bool
    /// Whether NONE of the eight locations exists — a separate trap from the three blind spots.
    let allLocationsAbsent: Bool
    /// Residue C's shape: a wall photo corpus holding plaintext JPEGs while the media latch is open.
    let keylessWallSignature: Bool
    /// The census sweep's `examined` total.
    let censusExaminedTotal: Int
    /// The migrator pass's `examined` total, or nil when no pass was observed.
    let passExaminedTotal: Int?

    /// Creates an audit. Public memberwise so a test can state an expectation directly.
    init(
        locations: [MediaLocationAudit],
        censusUnprefixedTotal: Int,
        meshPhotoCacheUnprefixed: Int,
        passUnopenableUnprefixed: Int?,
        unaccountedUnprefixed: Int?,
        hasBlindSpots: Bool,
        indeterminate: Int,
        unlistableDirectories: Int,
        truncated: Bool,
        allLocationsAbsent: Bool,
        keylessWallSignature: Bool,
        censusExaminedTotal: Int,
        passExaminedTotal: Int?
    ) {
        self.locations = locations
        self.censusUnprefixedTotal = censusUnprefixedTotal
        self.meshPhotoCacheUnprefixed = meshPhotoCacheUnprefixed
        self.passUnopenableUnprefixed = passUnopenableUnprefixed
        self.unaccountedUnprefixed = unaccountedUnprefixed
        self.hasBlindSpots = hasBlindSpots
        self.indeterminate = indeterminate
        self.unlistableDirectories = unlistableDirectories
        self.truncated = truncated
        self.allLocationsAbsent = allLocationsAbsent
        self.keylessWallSignature = keylessWallSignature
        self.censusExaminedTotal = censusExaminedTotal
        self.passExaminedTotal = passExaminedTotal
    }

    /// Folds a census report plus an optional pass witness into the audit.
    ///
    /// R2: bounded by the census report's location array, which the census itself bounds at the eight
    /// locations the two corpus layouts name.
    static func take(
        report: MediaAtRestFormatCensusReport,
        ownPhotoDocumentsDirectory: URL,
        friendWallSupportDirectory: URL,
        latches: Phase3LatchReadings,
        witness: MediaPassWitness?
    ) -> MediaResidueAudit {
        let labelled = labelledLocations(
            report: report,
            ownPhotoDocumentsDirectory: ownPhotoDocumentsDirectory,
            friendWallSupportDirectory: friendWallSupportDirectory,
            witness: witness
        )
        let total = report.total
        let residueB = labelled
            .filter { $0.label == .wallIndexLegacyPlaintext }
            .reduce(0) { $0 + $1.tally.unprefixedLegacyOrUnrecognized }
        let residueK = witness?.result.unopenableUnprefixed
        return MediaResidueAudit(
            locations: labelled,
            censusUnprefixedTotal: total.unprefixedLegacyOrUnrecognized,
            meshPhotoCacheUnprefixed: residueB,
            passUnopenableUnprefixed: residueK,
            unaccountedUnprefixed: residueK.map { total.unprefixedLegacyOrUnrecognized - residueB - $0 },
            hasBlindSpots: total.hasBlindSpots,
            indeterminate: total.indeterminate,
            unlistableDirectories: total.unlistableDirectories,
            truncated: total.truncated,
            allLocationsAbsent: report.allLocationsAbsent,
            keylessWallSignature: keylessWallSignature(labelled, latches: latches),
            censusExaminedTotal: total.examined,
            passExaminedTotal: witness?.result.examined
        )
    }

    private static func labelledLocations(
        report: MediaAtRestFormatCensusReport,
        ownPhotoDocumentsDirectory: URL,
        friendWallSupportDirectory: URL,
        witness: MediaPassWitness?
    ) -> [MediaLocationAudit] {
        // R2: bounded by the census's own location array.
        report.locations.map { location in
            let label = MediaCorpusLabel.label(
                for: location.url,
                ownPhotoDocumentsDirectory: ownPhotoDocumentsDirectory,
                friendWallSupportDirectory: friendWallSupportDirectory
            )
            return MediaLocationAudit(
                label: label,
                kind: location.kind,
                existed: location.existed,
                tally: location.tally,
                residueVerdict: verdict(label: label, tally: location.tally, witness: witness)
            )
        }
    }

    /// The per-location rule, with the born-sealed-is-blocking rule deliberately absent.
    ///
    /// A location only reads `.blocking` when a LIVE pass looked and accounted for nothing — never on
    /// inference from where the bytes happen to live.
    private static func verdict(
        label: MediaCorpusLabel?,
        tally: MediaAtRestFormatTally,
        witness: MediaPassWitness?
    ) -> ResidueVerdict {
        guard let label else { return .unnamedLocation }
        let unprefixed = tally.unprefixedLegacyOrUnrecognized
        guard unprefixed > 0 else { return .clean }
        guard label != .wallIndexLegacyPlaintext else {
            return .namedResidue("residue B: the undrained pre-sealing plaintext wall index. The"
                + " migrator deliberately never enumerates it, so it is subtracted exactly once and"
                + " can never appear in the pass's unopenableUnprefixed bucket.")
        }
        guard let witness, witness.result.unopenableUnprefixed == 0 else {
            return .unopenableCandidate("\(unprefixed) unprefixed bytes here are candidates for the"
                + " migrator's unopenableUnprefixed bucket — confirmed only against a live pass, never"
                + " inferred from the corpus they sit in.")
        }
        return .blocking("\(unprefixed) unprefixed bytes here, and the live pass at"
            + " \(witness.stamp.printed) accounted for none of them through unopenableUnprefixed.")
    }

    /// Residue C's signature: a wall photo corpus holding plaintext JPEGs while the media latch is
    /// open. On a latched device it cannot be present, because `abortedNoWallKey` blocks `isClean`.
    private static func keylessWallSignature(
        _ locations: [MediaLocationAudit],
        latches: Phase3LatchReadings
    ) -> Bool {
        guard !latches.mediaAtRest else { return false }
        // R2: bounded by the eight swept locations.
        return locations.contains { $0.label?.isWallPhotoCorpus == true && $0.tally.plaintextJPEG > 0 }
    }

    /// The eight location rows as the readout prints them.
    var printedLocationLines: [String] {
        // R2: bounded by the eight swept locations.
        locations.map(\.printedLine)
    }

    /// The subtraction, one term per line, so the reader is never asked to do it themselves.
    var printedArithmeticLines: [String] {
        [
            "(b) census unprefixed (whole device)                       U = \(censusUnprefixedTotal)",
            "    − undrained MeshPhotoCache.json (residue B)            J = \(meshPhotoCacheUnprefixed)",
            "    − pass unopenableUnprefixed (residue A + born-sealed)  K = "
                + (passUnopenableUnprefixed.map(String.init) ?? "— (no pass observed this process)"),
            "    = unaccounted                                     U−J−K = "
                + (unaccountedUnprefixed.map(String.init) ?? "— (no K term, so no number)"),
            "    examined: census \(censusExaminedTotal) · pass "
                + (passExaminedTotal.map(String.init) ?? "—")
        ]
    }

    /// The two-sweep hygiene caveat, or nil when the two sweeps agree (or only one ran).
    ///
    /// A structural difference is expected and named: the migrator excludes `MeshPhotoCache.json`
    /// from its resealable locations, so on a device that still has one the two totals differ by that
    /// file's count. Anything else means the two sweeps saw different filesystem states.
    var examinedDisagreementCaveat: String? {
        guard let passExaminedTotal, passExaminedTotal != censusExaminedTotal else { return nil }
        return "The census sweep examined \(censusExaminedTotal) files and the migrator pass examined"
            + " \(passExaminedTotal). The migrator deliberately excludes MeshPhotoCache.json from its"
            + " resealable locations, so a difference of exactly that file's count is expected;"
            + " anything else means the two sweeps saw different filesystem states — retake."
    }
}

#endif
