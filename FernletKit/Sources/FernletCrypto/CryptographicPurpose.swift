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

    /// How a signed transcript carries this purpose's bytes.
    ///
    /// Fernlet's transcript builders do not agree on one shape, and they must not be forced to:
    /// the byte layouts here are already signed by shipped peers, so the CHECK adapts to the
    /// format rather than the format to the check. Naming the shape per purpose keeps
    /// ``signingBytes(_:)`` an exact positional match — a substring search would accept a purpose
    /// buried in attacker-chosen fields, which is the whole property this guard exists to deny.
    public nonisolated enum TranscriptFraming: Hashable, Sendable {
        /// The transcript begins with the purpose's bytes verbatim, e.g. `domain ‖ nonce ‖ …`.
        case rawPrefix
        /// The purpose is the transcript's first length-prefixed field: an 8-byte big-endian byte
        /// count, then the bytes. This is what `CanonicalByteWriter` (ProximityKit's canonical
        /// signing serializer) emits for every variable-length field, the domain included.
        case lengthPrefixed
        /// A pre-domain-separation format that embeds no purpose at all. Read compatibility only —
        /// never the framing of a new write format.
        case absent
    }

    /// The shape this purpose takes inside a signed transcript. Meaningful only for signature
    /// purposes: a KDF salt, an HKDF `info`, or an AEAD authenticated-data blob never reaches
    /// ``signingBytes(_:)``, so those registry entries keep the default.
    private let framing: TranscriptFraming

    fileprivate init(_ rawValue: String, framing: TranscriptFraming = .rawPrefix) {
        self.rawValue = rawValue
        self.framing = framing
    }

    /// The exact bytes a domain-tagged transcript must begin with under this purpose's framing.
    /// Empty for ``TranscriptFraming/absent``, which every transcript trivially satisfies.
    private var expectedTranscriptPrefix: Data {
        switch framing {
        case .rawPrefix:
            return data
        case .lengthPrefixed:
            let purposeBytes = data
            var prefix = Data()
            // 8-byte big-endian count, shifted out to match `CanonicalByteWriter.appendUInt64`.
            let count = UInt64(purposeBytes.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                prefix.append(UInt8(truncatingIfNeeded: count >> UInt64(shift)))
            }
            prefix.append(purposeBytes)
            return prefix
        case .absent:
            return Data()
        }
    }

    /// Validates that a domain-tagged signature transcript begins with its reviewed purpose.
    /// This returns the unmodified bytes so it can sit directly at the raw signing boundary.
    public func signingBytes(_ bytes: Data) -> Data? {
        guard bytes.starts(with: expectedTranscriptPrefix) else { return nil }
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
    ///
    /// Every `fernlet.canonical.*` spelling below is serialized by `CanonicalByteWriter`, which
    /// length-prefixes its fields — so the domain reaches the signing boundary behind its own
    /// 8-byte count, hence `.lengthPrefixed`. The remaining transcripts concatenate their domain
    /// raw and keep the default. That split is a property of the SHIPPED byte layouts; do not
    /// "unify" it by rewriting a serializer, which would invalidate every signature already in
    /// the field.
    public nonisolated enum Signature {
        public static let identityEnvelopeV2 = CryptographicPurpose("fernlet.canonical.identity-envelope.v2", framing: .lengthPrefixed)
        public static let identityEnvelopeLegacyV1 = CryptographicPurpose("fernlet.canonical.identity-envelope.v1", framing: .absent)
        public static let meshAdmissionTokenV2 = CryptographicPurpose("fernlet.canonical.mesh-admission-token.v2", framing: .lengthPrefixed)
        public static let meshAdmissionTokenLegacyV1 = CryptographicPurpose("fernlet.canonical.mesh-admission-token.v1", framing: .absent)
        public static let activityDescriptorV2 = CryptographicPurpose("fernlet.canonical.activity-descriptor.v2", framing: .lengthPrefixed)
        public static let activityJoinTokenV2 = CryptographicPurpose("fernlet.canonical.activity-join-token.v2", framing: .lengthPrefixed)
        public static let activityRosterSnapshotV2 = CryptographicPurpose("fernlet.canonical.activity-roster-snapshot.v2", framing: .lengthPrefixed)
        public static let moderationReportV2 = CryptographicPurpose("fernlet.canonical.moderation-report.v2", framing: .lengthPrefixed)
        /// Debug-only Network.framework feasibility transcript. This is deliberately distinct
        /// from production mesh admissions so the device spike cannot become a signing oracle
        /// for a future shipping protocol.
        public static let meshProbeChannelIntroductionV1 = CryptographicPurpose("fernlet.mesh.probe.channel-introduction.v1")
        /// The production successor to ``meshProbeChannelIntroductionV1``: the mutually-signed QUIC
        /// channel introduction that authenticates a `NetworkMeshSession` peer (plan §7.2 —
        /// purpose ‖ version ‖ meshID ‖ epochRef ‖ both signing public keys ‖ both nonces ‖
        /// TLS-exporter hash). Distinct from the probe spelling on purpose: the DEBUG spike must
        /// never be able to mint bytes a shipping peer would accept.
        ///
        /// **Written since P2 item 7.** `MeshChannelIntroductionTranscript` is serialized by
        /// `canonicalBytes(for:)` with `CanonicalByteWriter`, like every other production canonical
        /// signature, so the domain reaches the signing boundary behind its own 8-byte count —
        /// hence `.lengthPrefixed`. `CryptographicPurposeBoundaryTests` holds the serializer to that
        /// declaration; changing one without the other is what broke in `91c3956`.
        public static let meshChannelIntroductionV1 = CryptographicPurpose("fernlet.mesh.channel-introduction.v1", framing: .lengthPrefixed)
        /// **Written since P3 item 3.** A leaver's own signature over its ``SignedDepartureRecord``
        /// (plan §8.3, wire token `fernlet.mesh.member-departure.v1`). The spelling is deliberately
        /// IDENTICAL to the record kind's `rawValue` and to the payload type it travels as: record
        /// kind, wire token and crypto domain are ONE vocabulary, so a reader grepping the token
        /// finds every layer that touches those bytes. Serialized by `canonicalBytes(for:)` with
        /// `CanonicalByteWriter`, hence `.lengthPrefixed`.
        public static let meshMemberDepartureV1 = CryptographicPurpose("fernlet.mesh.member-departure.v1", framing: .lengthPrefixed)
        /// **Written since P3 item 3.** The tallier's signature over a completed
        /// ``SignedRemovalRecord`` (plan §8.3/§10.4). The record carries its quorum evidence, so
        /// this signature attests to the tally, and the receiver re-checks the arithmetic against
        /// its own merged roster rather than trusting the tallier.
        public static let meshMemberRemovalV1 = CryptographicPurpose("fernlet.mesh.member-removal.v1", framing: .lengthPrefixed)
        /// **Written since P3 item 3.** A final-pair member's signature over its
        /// ``SignedTerminationRecord`` (plan §8.3). Distinct from the departure domain even though
        /// the record downgrades to a departure at a receiver whose roster is larger: the downgrade
        /// is a DERIVATION over an already-verified termination, never a re-interpretation of the
        /// bytes, so the two signatures must not cross-validate.
        public static let meshTerminatedV1 = CryptographicPurpose("fernlet.mesh.terminated.v1", framing: .lengthPrefixed)
        /// **Written since P3 item 3.** The sender's signature over a
        /// ``MeshInventoryDigestPayload`` — "here is what my ledger holds" (plan §8.3, §10.5). The
        /// digest itself is only a hint, but it is the input to a bounded re-gossip, so it is
        /// signed: an unsigned digest arriving on a relayed path could be forged to spend a peer's
        /// re-gossip budget, and an attributable one cannot.
        public static let meshInventoryDigestV1 = CryptographicPurpose("fernlet.mesh.inventory-digest.v1", framing: .lengthPrefixed)
        /// **Written since P4 item 3.** The sender's signature over a `MeshEpochHeadsPayload` — the
        /// epoch branch head(s) it is on (plan §10.3's union exchange). Signed, and distinct from
        /// the inventory digest's domain, because the heads decide the counter the merge's
        /// successor is minted at: an unsigned or cross-validating head set would let a peer walk a
        /// mesh toward ``MeshEpochBounds/counterCap``, where the only legal answer is to terminate.
        /// Length-prefixed, like every other `CanonicalByteWriter` transcript.
        public static let meshEpochHeadsV1 = CryptographicPurpose("fernlet.mesh.epoch-heads.v1", framing: .lengthPrefixed)
        /// **Written since P4 item 5.** A proposer's signature over a `SignedRemovalProposal` —
        /// "I propose removing this member, and this is my vote" (plan §10.4). Distinct from the
        /// vote domain even though the proposal *is* the proposer's vote: the proposal is the only
        /// object that binds `proposalID → (mesh, target, proposer)`, so a vote's signature must
        /// never validate as one, or a member could re-point somebody else's proposal at a
        /// different target. Length-prefixed, like every other `CanonicalByteWriter` transcript.
        public static let meshRemovalProposalV1 = CryptographicPurpose("fernlet.mesh.removal-proposal.v1", framing: .lengthPrefixed)
        /// **Written since P4 item 5.** A voter's signature over a `SignedRemovalVote` (plan
        /// §10.4). Distinct from the removal record's domain: a vote is *live* state that expires
        /// after five minutes and never reaches a ledger, while `meshMemberRemovalV1` signs the
        /// permanent, quorum-complete record — a signature that satisfied both would let a single
        /// vote be replayed as a completed removal.
        public static let meshRemovalVoteV1 = CryptographicPurpose("fernlet.mesh.removal-vote.v1", framing: .lengthPrefixed)
        /// **Written since P5 item 1.** P5's routed-content manifest signature (plan §11): item
        /// ID, type token, content hash, size, immutable destination set, expiry, and the
        /// per-recipient key wraps. Signed by the ORIGIN only — relays forward the origin's exact
        /// signed object and never re-sign, so this purpose has exactly one signer per manifest.
        /// Same framing reservation as ``meshChannelIntroductionV1``.
        public static let meshRoutedManifestV1 = CryptographicPurpose("fernlet.mesh.routed-manifest.v1", framing: .lengthPrefixed)
        /// **Written since P5 item 2.** P5's routed-content CHUNK signature (plan §11): mesh, item,
        /// origin, the whole item's content hash, `chunkIndex` of `chunkCount`, the chunk's own
        /// payload hash, and the item's expiry. The payload itself is excluded from the transcript
        /// and bound through that hash. Signed by the ORIGIN only — a custodian forwards the exact
        /// signed object and never re-signs.
        ///
        /// Distinct from ``meshRoutedManifestV1`` (`routed-chunk` vs `routed-manifest`, diverging
        /// at `c`/`m`): a chunk describes a slice and a manifest describes who an item is for and
        /// who can open it, so a signature satisfying both would let one stand in for the other.
        /// Distinct from ``FernletCryptoPurpose/Hash/meshRoutedChunkV1``, which tags the bytes that
        /// are hashed rather than the bytes that are signed — the `.hash.` infix in the Hash
        /// spelling is what keeps neither a prefix of the other. Same framing reservation as
        /// ``meshRoutedManifestV1``.
        public static let meshRoutedChunkV1 = CryptographicPurpose("fernlet.mesh.routed-chunk.v1", framing: .lengthPrefixed)
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
        /// TLS-exporter label for the DEBUG Network.framework spike's channel binding — the value
        /// handed to `sec_protocol_metadata_create_secret`, whose SHA-256 the probe's signed
        /// introduction commits to. An exporter label never reaches ``signingBytes(_:)``, so the
        /// framing is immaterial; what matters is that it is a reviewed constant rather than a bare
        /// string literal in the probe, and that it stays distinct from ``meshTLSExporterV1``.
        public static let meshProbeTLSExporterV1 = CryptographicPurpose("fernlet.mesh.probe.tls-exporter.v1")
        /// The production TLS-exporter label for the QUIC mesh channel binding (plan §7.2), the
        /// shipping counterpart to ``meshProbeTLSExporterV1``. Keeping the two apart is what stops a
        /// spike build and a shipping build deriving the same binding secret from the same
        /// connection. **In use since P2 item 7**: `NetworkMeshSession.channelBindingHash(for:)`
        /// hands it to `sec_protocol_metadata_create_secret` and signs the SHA-256 of the result
        /// into ``FernletCryptoPurpose/Signature/meshChannelIntroductionV1``'s transcript.
        public static let meshTLSExporterV1 = CryptographicPurpose("fernlet.mesh.tls-exporter.v1")
        /// **Written since P5 item 1.** P5's per-recipient content-key wrap (plan §11): the
        /// X25519 shared secret between the origin and one destination is run through HKDF under
        /// this purpose to derive the key-wrapping key. Mirrors the ``meshGroupKeyWrapV1`` /
        /// ``FernletCryptoPurpose/AEAD/meshGroupKeyWrapV2`` pair — a derivation purpose plus the
        /// AEAD purpose that authenticates the wrap.
        public static let meshRoutedContentKeyWrapV1 = CryptographicPurpose("fernlet.mesh.routed.content-key.v1")
        /// The sealed `MeshSessionContext` sidecar (P3 item 2, plan §8.1). Handed to
        /// ``ColumnCrypto/init(purpose:)``, so it is BOTH the HKDF `info` that derives the file's
        /// column key from the mesh-session seal key AND — inside the v3 at-rest format — half of
        /// the additional authenticated data, beside this install's ``DeviceBindingID``.
        ///
        /// Its own domain rather than a reuse of ``meshGroupKeyWrapV1``: the group key is
        /// memory-only and dies with the process, while this seals the one durable thing a mesh
        /// session has. Sharing a domain would let a context blob and a key-wrap blob authenticate
        /// under each other's derived key, which is exactly what the registry exists to prevent.
        /// Changing this spelling orphans every sealed context already on disk.
        public static let meshSessionContextV1 = CryptographicPurpose("fernlet.mesh.session-context.v1")
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
        /// **Written since P5 item 1.** Authenticated data for P5's per-recipient content-key
        /// wrap — the sealing half of the pair whose derivation half is
        /// ``FernletCryptoPurpose/KeyDerivation/meshRoutedContentKeyWrapV1``.
        public static let meshRoutedContentKeyWrapV1 = CryptographicPurpose("fernlet.mesh.routed.content-key.wrap.aead.v1")
        /// **Reserved, not yet written.** Authenticated data for a routed item's own content-key
        /// seal (plan §11 — "content encryption is independent of the group key"). Registered
        /// beside the wrap because the two are one review: a wrap purpose with no item purpose
        /// would leave P5 to invent the second spelling alone, which is how copy-paste collisions
        /// enter a registry. **The seal is item 6 / P6's**: item 2 chunks an opaque blob and
        /// deliberately does not seal, because `AES.GCM.seal` mints a random nonce and a sealing
        /// chunker could therefore be neither a pure function of its inputs nor goldened.
        public static let meshRoutedItemV1 = CryptographicPurpose("fernlet.mesh.routed.item.aead.v1")
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
        /// **Written since P3 item 3.** The domain the membership-inventory digest is computed
        /// under (plan §10.5): SHA-256 over this tag followed by the canonical, sorted identities
        /// of every record a ledger holds.
        ///
        /// Its own domain rather than a reuse of
        /// ``FernletCryptoPurpose/Signature/meshInventoryDigestV1``: the signature domain tags the
        /// bytes a peer signs, this one tags the bytes that are hashed INTO those. Sharing one
        /// spelling would let a signed digest message and a raw digest input be the same bytes,
        /// which is precisely the confusion the registry exists to deny. The `.hash.` infix also
        /// keeps neither spelling a prefix of the other.
        public static let meshInventoryDigestV1 = CryptographicPurpose("fernlet.mesh.inventory-digest.hash.v1")
        /// **Written since P5 item 2.** The domain a routed ITEM's content hash is computed under
        /// (plan §11): SHA-256 over this tag, length-prefixed, followed by the complete sealed
        /// blob. It is what `MeshRoutedManifest.contentHash` measures and what a reassembled item
        /// is finally checked against.
        ///
        /// Not the neighbouring spelling twice over. It is not
        /// ``FernletCryptoPurpose/KeyDerivation/meshRoutedContentKeyWrapV1``
        /// (`fernlet.mesh.routed.content-key.v1`), which sits one character away — `routed.content-`
        /// then `key` vs `hash` — and is a KDF input rather than a digest tag; the `.hash.` infix
        /// is what keeps them apart. And it is not ``meshRoutedChunkV1`` below: untagged, a
        /// one-chunk item's item hash and its chunk hash would be the SAME 32 bytes, so a chunk
        /// hash could be replayed as a content hash.
        public static let meshRoutedContentV1 = CryptographicPurpose("fernlet.mesh.routed-content.hash.v1")
        /// **Written since P5 item 2.** The domain ONE chunk's payload hash is computed under
        /// (plan §11): SHA-256 over this tag, length-prefixed, followed by that chunk's slice. It
        /// is the field a chunk's origin signature binds the payload through, since the payload is
        /// excluded from the signed transcript.
        ///
        /// Its own domain rather than a reuse of ``meshRoutedContentV1``: for a one-chunk item the
        /// two digests would otherwise cover identical bytes and be interchangeable. Distinct from
        /// the signature spelling ``FernletCryptoPurpose/Signature/meshRoutedChunkV1``
        /// (`fernlet.mesh.routed-chunk.v1`) by the `.hash.` infix, so neither prefixes the other.
        public static let meshRoutedChunkV1 = CryptographicPurpose("fernlet.mesh.routed-chunk.hash.v1")
        /// **Written since P5 item 2.** The domain a chunk's DERIVED replay-window id is computed
        /// under (plan §11, item 12's dedup key): SHA-256 over this tag, length-prefixed, then the
        /// item id and the chunk index, of which the first 16 bytes are read as a `UUID`.
        ///
        /// Its own domain rather than a reuse of ``meshRoutedChunkV1``: that one hashes payload
        /// BYTES and this one hashes an `(item, index)` pair, so a shared spelling would let a
        /// crafted payload collide with an id. `routed-chunk-id.hash` diverges from
        /// `routed-chunk.hash` at `-` vs `.`, so neither is a prefix of the other.
        public static let meshRoutedChunkIDV1 = CryptographicPurpose("fernlet.mesh.routed-chunk-id.hash.v1")
        public static let recoveryContentKeyV1 = CryptographicPurpose("fernlet.lock.recovery.contentkey.v1")
    }
}
