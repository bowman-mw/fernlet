//
//  SealedPhotoRecord.swift
//  CloudKitSync
//
//  The OWN-PHOTO escrow route's transport DTOs (security-hardening Phase 5, step 5b): one
//  opaque encrypted record per photo id, plus a sealed manifest record that is written LAST
//  as the set's commit marker. Like `SealedBackupRecord` these carry only ciphertext + crypto
//  metadata — never plaintext, never a sealed-store type — so they live in the walled sync
//  module beside the service that serializes them. The sealing/opening (`SealedPhotoCrypto`)
//  and the reconcile/restore policy stay app-side with the on-device identity service.
//
//  Deliberately a SEPARATE namespace from `SealedBackupPayloadType`, not a new case on it:
//  "delete everything" and the Privacy & Data toggles both iterate
//  `SealedBackupPayloadType.allCases` and would route photos through the chunked-blob path,
//  which rewrites the whole set on every change (the exact property the per-photo scheme exists
//  to avoid).
//

import Foundation

/// Which of the user's OWN photo corpora a sealed photo record belongs to.
///
/// The raw value keys the deterministic CloudKit record name (`sealed-photo.<corpus>.<slot>`) and
/// is bound into the GCM additional-authenticated-data, so a record cannot be replayed into another
/// corpus. Friend-wall photos are deliberately absent: the wall is other people's media, it survives
/// "delete everything" by design, and it is not part of the own-photo escrow route.
///
/// - Important: These raw values are **at-rest format**. Renaming one orphans every record already
///   in users' CloudKit databases *and* breaks the AAD of anything still fetched, so they must never
///   change once shipped.
public enum SealedPhotoCorpus: String, Codable, CaseIterable, Sendable {
    /// Meal photos (`Meal.photoID` → sealed `<uuid>.jpg` under `MealPhotos/`).
    case meal
    /// Recipe photos, keyed by recipe id (`RecipePhotos/`).
    case recipe
    /// Gym progress (body) photos plus their sealed timeline index (`ProgressPhotos/`). The index
    /// travels as the manifest's ``SealedPhotoManifest/sidecar`` — bytes without dates and captions
    /// would restore as an invisible timeline.
    case progress
}

/// Which record within a corpus: one photo, or the corpus manifest.
///
/// The slot's ``recordNameSuffix`` is BOTH the CloudKit record-name suffix and the value bound into
/// the GCM AAD, so the name a record answers to and the name it was sealed under are the same
/// string — a record moved to another name fails to open rather than opening in the wrong slot.
///
/// The two spellings cannot collide: a photo slot is a `UUID.uuidString`, and `"manifest"` does not
/// parse as a UUID (which is also how ``init(recordNameSuffix:)`` routes them apart).
public enum SealedPhotoSlot: Equatable, Hashable, Sendable {
    /// One photo, named by the id its owning store keys it under.
    case photo(UUID)
    /// The corpus manifest — the id set + per-id content hash, written last as the commit marker.
    case manifest

    /// The record-name suffix (and AAD binding) for this slot.
    public static let manifestSuffix = "manifest"

    /// This slot's record-name suffix: the photo's `uuidString`, or ``manifestSuffix``.
    public var recordNameSuffix: String {
        switch self {
        case .photo(let id): return id.uuidString
        case .manifest: return Self.manifestSuffix
        }
    }

    /// The photo id, or nil for the manifest slot.
    public var photoID: UUID? {
        if case .photo(let id) = self { return id }
        return nil
    }

    /// Parses a record-name suffix back into a slot; nil for anything that is neither the manifest
    /// sentinel nor a well-formed UUID (an unrecognized record is ignored, never guessed at).
    public init?(recordNameSuffix suffix: String) {
        if suffix == Self.manifestSuffix {
            self = .manifest
            return
        }
        guard let id = UUID(uuidString: suffix) else { return nil }
        self = .photo(id)
    }
}

/// The sealed plaintext of a corpus manifest: which photo ids the backup contains, what each one's
/// bytes hash to, and (for the progress corpus) the sealed timeline index.
///
/// **This is the commit marker and the anti-rollback anchor.** A record that is not listed here is
/// an ignored orphan; an id listed here whose record is missing or unopenable fails THAT photo, not
/// the set. The per-id content hash is what makes per-photo rollback detectable at all: the manifest
/// itself is generation-checked against `SealedBackupGenerationStore`'s high-water mark, so an
/// attacker who substitutes an older-but-validly-sealed body for one id is caught by the hash the
/// authenticated manifest names.
public struct SealedPhotoManifest: Codable, Equatable, Sendable {
    /// One photo's entry in the manifest.
    public struct Entry: Codable, Equatable, Sendable {
        /// The digest generation an entry proven to carry the current, domain-separated pre-image
        /// is stamped with (`SealedPhotoBackupService.contentHash`'s v2 purpose-bound digest).
        ///
        /// `nonisolated` (this module declares `defaultIsolation(MainActor.self)`) because the
        /// format-migration verdict types read it from nonisolated contexts: Phase 2.1's
        /// `SealedPhotoBackupMigrationPassResult.isClean` witnesses a `FormatMigrationPassResult`
        /// requirement, which the nonisolated protocol makes nonisolated too. An immutable `Int`
        /// on a `Sendable` value type has no isolation to lose.
        public nonisolated static let currentHashVersion = 2
        /// The digest generation ``hashVersion`` defaults to on decode: the legacy bare-SHA256
        /// pre-image, or an entry whose pre-image simply has not been proven yet. `nonisolated`
        /// for the same reason as its pair above — the two are read together.
        public nonisolated static let legacyHashVersion = 1

        /// The photo id — also its record-name slot.
        public let id: UUID
        /// SHA-256 of the sealed PLAINTEXT (the normalized JPEG), so a restore can prove the body
        /// it opened is the body this generation committed.
        public let contentHash: Data
        /// Which pre-image generation produced ``contentHash`` — the format marker this surface
        /// never had (crypto-standardization plan Phase 1), added because the digest itself is
        /// unversioned and telling the legacy pre-image from the current one otherwise requires
        /// the plaintext.
        ///
        /// `2` means the digest is PROVEN to be the domain-separated v2 pre-image — stamped only
        /// by a pass that computed (or recomputed and matched) the digest from plaintext it read.
        /// `1` means legacy **or unproven**: the field was absent on decode, so the entry predates
        /// the marker and its digest may be either pre-image. That default is the fail-closed
        /// direction — an undercount of proven-v2, never an overcount of clean — which is what
        /// lets `SealedPhotoManifest/minimumEntryHashVersion >= 2` stand as a zero-legacy proof.
        /// A carried-forward entry KEEPS its recorded version; only a pass that read the plaintext
        /// may upgrade it.
        public let hashVersion: Int

        /// Creates an entry pairing a photo id with the hash of its plaintext bytes and the digest
        /// generation that produced it. `hashVersion` is deliberately not defaulted: every
        /// construction site must say whether it PROVED the pre-image or is carrying a recorded
        /// claim forward.
        public init(id: UUID, contentHash: Data, hashVersion: Int) {
            self.id = id
            self.contentHash = contentHash
            self.hashVersion = hashVersion
        }

        /// Declared (not synthesized) so the at-rest JSON key names are pinned in source.
        private enum CodingKeys: String, CodingKey {
            case id
            case contentHash
            case hashVersion
        }

        /// Decodes an entry, defaulting a missing `hashVersion` to ``legacyHashVersion`` — every
        /// manifest entry written before the marker existed decodes as legacy/unproven, so old
        /// manifests keep decoding and their entries are never silently promoted.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            contentHash = try container.decode(Data.self, forKey: .contentHash)
            hashVersion = try container.decodeIfPresent(Int.self, forKey: .hashVersion)
                ?? Self.legacyHashVersion
        }
    }

    /// Which corpus this manifest describes. Also bound into the record's AAD; the app re-checks
    /// the decoded value against the corpus it asked for, so a mismatch fails closed.
    public var corpus: SealedPhotoCorpus
    /// The committed id set, with each id's content hash.
    public var entries: [Entry]
    /// Corpus-level sidecar plaintext, sealed inside the manifest rather than as its own record.
    ///
    /// Today this is the progress corpus's sealed timeline index (`ProgressPhotoRecord` entries:
    /// dates + captions). It rides in the manifest because it is small, because it must land
    /// atomically with the id set it describes, and because it inherits the manifest's
    /// authentication and generation anchor for free. Nil for corpora whose ownership lives
    /// elsewhere (meal photos in `Meal.photoID`, recipe photos in the recipe row).
    public var sidecar: Data?

    /// Creates a manifest for `corpus`.
    public init(corpus: SealedPhotoCorpus, entries: [Entry], sidecar: Data? = nil) {
        self.corpus = corpus
        self.entries = entries
        self.sidecar = sidecar
    }

    /// The lowest ``Entry/hashVersion`` among ``entries`` — the per-corpus zero-legacy proof
    /// (crypto-standardization plan Phase 1): `>= 2` means no entry in this manifest carries (or
    /// might carry) the legacy bare-SHA256 digest, fleet-wide, because the manifest is the sole
    /// authority on membership and every device's reconcile re-encodes it wholesale.
    ///
    /// Deliberately COMPUTED, never stored: `entries` is mutable, so a stored copy could drift
    /// from the entries it summarizes, and the AEAD-sealed JSON needs no second spelling of a fact
    /// the entries already carry — re-deriving at every read (including at write time, from the
    /// entries actually committed) is what makes the proof self-propagating. An empty manifest
    /// reads as ``Entry/currentHashVersion``: no entries, vacuously no legacy digest.
    public var minimumEntryHashVersion: Int {
        entries.map(\.hashVersion).min() ?? Entry.currentHashVersion
    }
}

/// Opaque encrypted envelope for one own-photo record (a photo body, or the corpus manifest) as
/// stored in CloudKit.
///
/// Carries only ciphertext plus crypto metadata — the same shape and the same fail-closed decode
/// rules as ``SealedBackupRecord``, minus the chunk fields (this scheme has no chunk sets: one
/// record per photo id is what makes an incremental add possible). Ciphertext always travels as a
/// `CKAsset`, for the photo bodies obviously and for the manifest deliberately: a manifest with
/// thousands of UUID + hash entries would otherwise run into CloudKit's ~1 MB inline-field limit.
///
/// Born at record format **2** (the per-generation salted escrow derivation). There is no v1
/// spelling of this record type — the route shipped after the salted derivation did — so, unlike
/// `SealedBackupRecord`, a missing/short salt is a malformed record rather than a legacy shape.
public struct SealedPhotoRecord: Equatable {
    /// Which own-photo corpus this record belongs to (bound into the AAD).
    public var corpus: SealedPhotoCorpus
    /// Which record within the corpus (bound into the AAD, and the record's own name suffix).
    public var slot: SealedPhotoSlot
    /// The owner's signing public key, carried as provenance and bound into the AAD.
    public var signingPublicKey: Data
    /// The owner's backup-ESCROW public key (X25519) — the device-stable identity tag that lets a
    /// restore say "this backup is mine" before attempting decryption. Same role, and same field
    /// name, as on ``SealedBackupRecord``.
    public var keyAgreementPublicKey: Data
    public var nonce: Data
    public var ciphertext: Data
    public var tag: Data
    public var updatedAt: Date
    /// Monotonic per-corpus write counter, minted from `SealedBackupGenerationStore` under a
    /// photo-namespaced key and bound into the AAD.
    ///
    /// A photo record keeps the generation of the write that created it — incremental adds do NOT
    /// rewrite untouched records — so per-record generations legitimately differ. The MANIFEST's
    /// generation is the one the rollback high-water check is made against, and the manifest's
    /// per-id content hashes are what extend that protection to the individual bodies.
    public var generation: Int64
    /// At-rest record format. Always `2` (salted escrow derivation) for this record type.
    public var formatVersion: Int
    /// The 32 random bytes mixed into the escrow HKDF for this write. Plaintext CloudKit field, like
    /// the nonce, and deliberately not bound into the AAD — a tampered salt already derives the
    /// wrong key and fails AES-GCM.
    public var keySalt: Data

    public init(
        corpus: SealedPhotoCorpus,
        slot: SealedPhotoSlot,
        signingPublicKey: Data,
        keyAgreementPublicKey: Data,
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        updatedAt: Date,
        generation: Int64,
        formatVersion: Int = 2,
        keySalt: Data
    ) {
        self.corpus = corpus
        self.slot = slot
        self.signingPublicKey = signingPublicKey
        self.keyAgreementPublicKey = keyAgreementPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.updatedAt = updatedAt
        self.generation = generation
        self.formatVersion = formatVersion
        self.keySalt = keySalt
    }
}
