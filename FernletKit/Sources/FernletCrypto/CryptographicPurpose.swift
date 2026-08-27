import Foundation

/// A stable cryptographic domain identifier.
///
/// A purpose is cryptographic format data, never display text. Its spelling is immutable once it
/// reaches a signed transcript, a KDF, an authenticated-data layout, or a persisted digest. The
/// initializer is intentionally unavailable outside this file: production call sites select a
/// reviewed constant from ``FernletCryptoPurpose`` rather than supplying a string (especially not
/// one assembled from peer or user input).
public nonisolated struct CryptographicPurpose: Hashable, Sendable {
    /// The protocol-format spelling. Exposed for diagnostics and format documentation only.
    public let rawValue: String

    /// UTF-8 bytes used by CryptoKit APIs. Purpose strings are ASCII protocol tokens, so UTF-8 is
    /// a stable one-byte-per-character representation.
    public var data: Data { Data(rawValue.utf8) }

    /// Whether a signed transcript is required to start with this purpose's bytes. Legacy formats
    /// that predate an embedded domain keep `false` solely for read compatibility.
    private let requiresEmbeddedPrefix: Bool

    fileprivate init(_ rawValue: String, requiresEmbeddedPrefix: Bool = true) {
        self.rawValue = rawValue
        self.requiresEmbeddedPrefix = requiresEmbeddedPrefix
    }

    /// Validates that a domain-tagged signature transcript begins with its reviewed purpose.
    /// This returns the unmodified bytes so it can sit directly at the raw signing boundary.
    public func signingBytes(_ bytes: Data) -> Data? {
        guard !requiresEmbeddedPrefix || bytes.starts(with: data) else { return nil }
        return bytes
    }
}

/// The single registry of Fernlet's cryptographic protocol purposes.
///
/// Keep existing spellings exactly: changing one changes a key, a digest, or the bytes an
/// existing signature verifies. A new spelling therefore needs an explicit versioned write format
/// and a legacy read path at its consumer.
public nonisolated enum FernletCryptoPurpose {
    /// Domains embedded in Ed25519 signature transcripts.
    public nonisolated enum Signature {
        public static let identityEnvelopeV2 = CryptographicPurpose("fernlet.canonical.identity-envelope.v2")
        public static let identityEnvelopeLegacyV1 = CryptographicPurpose("fernlet.canonical.identity-envelope.v1", requiresEmbeddedPrefix: false)
        public static let meshAdmissionTokenV2 = CryptographicPurpose("fernlet.canonical.mesh-admission-token.v2")
        public static let meshAdmissionTokenLegacyV1 = CryptographicPurpose("fernlet.canonical.mesh-admission-token.v1", requiresEmbeddedPrefix: false)
        public static let activityDescriptorV2 = CryptographicPurpose("fernlet.canonical.activity-descriptor.v2")
        public static let activityJoinTokenV2 = CryptographicPurpose("fernlet.canonical.activity-join-token.v2")
        public static let activityRosterSnapshotV2 = CryptographicPurpose("fernlet.canonical.activity-roster-snapshot.v2")
        public static let moderationReportV2 = CryptographicPurpose("fernlet.canonical.moderation-report.v2")
        /// Debug-only Network.framework feasibility transcript. This is deliberately distinct
        /// from production mesh admissions so the device spike cannot become a signing oracle
        /// for a future shipping protocol.
        public static let meshProbeChannelIntroductionV1 = CryptographicPurpose("fernlet.mesh.probe.channel-introduction.v1")
        public static let proximityQRIdentityV1 = CryptographicPurpose("fernlet.verify.qr.v1")
        public static let proximityQRResponseV1 = CryptographicPurpose("fernlet.verify.response.v1")
        public static let duressRecoveryRequestV1 = CryptographicPurpose("fernlet.duress.recovery.request.v1")
        public static let duressRecoveryReplyV1 = CryptographicPurpose("fernlet.duress.recovery.reply.v1")
    }

    /// HKDF or otherwise named key-derivation purposes. The legacy spellings stay present because
    /// they are input to already-persisted derivations.
    public nonisolated enum KeyDerivation {
        public static let sealedBackupLegacyV1 = CryptographicPurpose("com.fernlet.sealed-backup")
        public static let sealedBackupV2 = CryptographicPurpose("com.fernlet.sealed-backup.v2")
        public static let proximityTransportV1 = CryptographicPurpose("fernlet.proximity.v1")
        public static let heartDropPairV1 = CryptographicPurpose("fernlet.heartdrop.v1")
        public static let presencePairV1 = CryptographicPurpose("fernlet.presence.tag.v1")
        public static let meshGroupKeyWrapV1 = CryptographicPurpose("fernlet.mesh.groupkey.v1")
        public static let heartDropOuterSealV1 = CryptographicPurpose("fernlet.heartdrop.seal.v1")
        /// Scrypt has no `info` argument. This constant names its sole consumer; the v2 wrapping
        /// AEAD below authenticates the same purpose beside the derived key.
        public static let lockScryptWrappingV1 = CryptographicPurpose("fernlet.lock.scrypt.wrapping.v1")
        public static let journalNarrativeLegacyV1 = CryptographicPurpose("journal-narrative")
        public static let worryNarrativeLegacyV1 = CryptographicPurpose("worry-box")
        public static let menstrualNarrativeLegacyV1 = CryptographicPurpose("menstrual-narrative")
        public static let intimacyLogLegacyV1 = CryptographicPurpose("intimacy-log")
    }

    /// Domains embedded in HMAC messages.
    public nonisolated enum HMAC {
        public static let heartDropDayTagV1 = CryptographicPurpose("fernlet.heartdrop.day.v1")
        public static let presenceEpochTagV1 = CryptographicPurpose("fernlet.presence.epoch.v1")
    }

    /// Additional-authenticated-data domains for symmetric encryption formats.
    public nonisolated enum AEAD {
        public static let sealedBackupV2 = CryptographicPurpose("fernlet.sealed-backup.aad.v2")
        public static let sealedPhotoBackupV3 = CryptographicPurpose("fernlet.sealed-photo.aad.v3")
        public static let proximityTransportV2 = CryptographicPurpose("fernlet.proximity.transport.aead.v2")
        public static let meshGroupKeyWrapV2 = CryptographicPurpose("fernlet.mesh.groupkey.wrap.aead.v2")
        public static let meshGroupPhotoV2 = CryptographicPurpose("fernlet.mesh.group-photo.aead.v2")
        public static let meshEncryptedMetadataV2 = CryptographicPurpose("fernlet.mesh.encrypted-metadata.aead.v2")
        public static let heartDropSidecarV2 = CryptographicPurpose("fernlet.heartdrop.sidecar.aead.v2")
        public static let pendingNarrativeBufferV2 = CryptographicPurpose("fernlet.pending-narrative-buffer.aead.v2")
        public static let lockContentKeyWrapV2 = CryptographicPurpose("fernlet.lock.content-key-wrap.aead.v2")
        public static let columnDeviceBoundV3 = CryptographicPurpose("fernlet.private-column.device-bound.aead.v3")
        public static let privateFriendPhotoImageV2 = CryptographicPurpose("fernlet.private-media.friend-photo.image.aead.v2")
        public static let privateFriendPhotoThumbnailV2 = CryptographicPurpose("fernlet.private-media.friend-photo.thumbnail.aead.v2")
        public static let privateFriendPhotoIndexV2 = CryptographicPurpose("fernlet.private-media.friend-photo.index.aead.v2")
        public static let mealPhotoV2 = CryptographicPurpose("fernlet.private-media.meal-photo.aead.v2")
        public static let recipePhotoV2 = CryptographicPurpose("fernlet.private-media.recipe-photo.aead.v2")
        public static let progressPhotoV2 = CryptographicPurpose("fernlet.private-media.progress-photo.aead.v2")
        public static let progressPhotoIndexV2 = CryptographicPurpose("fernlet.private-media.progress-photo.index.aead.v2")
    }

    /// Inputs to persisted security digests.
    public nonisolated enum Hash {
        public static let sealedPhotoContentV2 = CryptographicPurpose("fernlet.sealed-photo.content-hash.v2")
        public static let lockVerifierV2 = CryptographicPurpose("fernlet.lock.verifier.v2")
        public static let recoveryContentKeyV1 = CryptographicPurpose("fernlet.lock.recovery.contentkey.v1")
    }
}
