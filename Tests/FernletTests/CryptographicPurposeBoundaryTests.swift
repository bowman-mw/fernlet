import Foundation
import FernletCrypto
import FernletDomainModel
import Testing
@testable import ProximityKit

/// Grep-wall for purpose separation at the raw CryptoKit boundary. It deliberately scans source,
/// rather than testing a few hand-picked code paths, so a newly-added primitive call cannot rely on
/// a reviewer remembering this policy.
///
/// The roots, the primitive markers and the context window live in ``CryptographicWallScan``, shared
/// with ``CryptographicEscapeHatchCensusTests`` so the pinned escape-hatch count cannot describe a
/// different set of bytes than the wall enforces over.
struct CryptographicPurposeBoundaryTests {

    @Test func rawCryptographicCallsNameAPurpose() throws {
        for sourceURL in try CryptographicWallScan.sourceFiles() {
            let lines = try String(contentsOf: sourceURL, encoding: .utf8)
                .components(separatedBy: .newlines)
            let path = CryptographicWallScan.repoRelativePath(sourceURL)
            for index in lines.indices where CryptographicWallScan.isPrimitiveCall(lines[index]) {
                let context = CryptographicWallScan.context(around: index, in: lines)
                #expect(
                    hasPurpose(context),
                    "Raw crypto call without a purpose at \(path):\(index + 1)"
                )
            }
        }
    }

    // MARK: - Declared framing vs. the real transcript builders

    /// The grep-wall above proves a purpose is NAMED wherever a primitive is called. This proves the
    /// named purpose actually MATCHES the bytes its serializer produces — the pairing that broke in
    /// 91c3956, where `CanonicalByteWriter` writes the domain as a length-prefixed FIELD but the
    /// registry declared a raw prefix. Every canonical signature then threw `.invalidKeyData` at the
    /// signing boundary and every canonical verify returned false, which reached the suite as ~200
    /// unexplained failures rather than one named cause.
    ///
    /// The envelope and the moderation row are two independent `canonicalBytes(for:)` overloads; the
    /// remaining `fernlet.canonical.*` types share that same writer and their own round-trip suites.
    @Test func canonicalSerializerTranscriptsMatchTheirDeclaredFraming() {
        let envelopePurpose = FernletCryptoPurpose.Signature.identityEnvelopeV2
        let envelope = FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: Data(repeating: 1, count: 32),
            senderKeyAgreementPublicKey: Data(repeating: 2, count: 32),
            senderDisplayName: "Framing Probe",
            recipientFingerprint: nil,
            payloadType: .inspectorEcho,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Framing Probe"),
            payload: Data("probe".utf8),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            signature: Data()
        )
        #expect(
            envelopePurpose.signingBytes(canonicalBytes(for: envelope)) != nil,
            "canonicalBytes(for: envelope) must satisfy identityEnvelopeV2's declared framing"
        )

        let reportPurpose = FernletCryptoPurpose.Signature.moderationReportV2
        let entry = ModerationLedgerEntry(
            id: "framing-probe",
            kind: .report,
            reporterSigningPublicKey: Data(repeating: 3, count: 32),
            subjectSigningPublicKey: Data(repeating: 4, count: 32),
            itemID: UUID(),
            contentHash: Data(repeating: 5, count: 32),
            reasonToken: "other",
            reporterSeq: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(
            reportPurpose.signingBytes(canonicalBytes(for: entry)) != nil,
            "canonicalBytes(for: entry) must satisfy moderationReportV2's declared framing"
        )

        // The QUIC mesh channel introduction (network migration P2, plan §7.2). Registered as
        // `.lengthPrefixed` before anything signed under it; this is the serializer arriving and
        // being held to that declaration in the same change, which is the pairing 91c3956 broke.
        let introductionPurpose = FernletCryptoPurpose.Signature.meshChannelIntroductionV1
        let transcript = MeshChannelIntroductionTranscript(
            protocolVersion: MeshChannelIntroductionFormat.protocolVersion,
            meshID: UUID(),
            epochRef: "7",
            initiatorSigningPublicKey: Data(repeating: 6, count: 32),
            responderSigningPublicKey: Data(repeating: 7, count: 32),
            initiatorNonce: Data(repeating: 8, count: 16),
            responderNonce: Data(repeating: 9, count: 16),
            channelBindingHash: Data(repeating: 10, count: 32)
        )
        #expect(
            introductionPurpose.signingBytes(canonicalBytes(for: transcript)) != nil,
            "canonicalBytes(for: transcript) must satisfy meshChannelIntroductionV1's declared framing"
        )

        // The membership events (network migration P3 item 3, plan §8.3). Four purposes, four
        // serializers, registered and held to their declaration in the SAME change — the pairing
        // 91c3956 broke. Each record's own signature is excluded from its bytes, so the fixtures
        // below carry a placeholder one.
        assertMembershipFramingHolds()

        // The routed-content manifest (network migration P5 item 1, plan §11). Registered
        // `.lengthPrefixed` in P0 before anything signed under it; this is the serializer arriving
        // and being held to that declaration in the same change — the 91c3956 pairing.
        assertRoutedFramingHolds()

        // The routed CHUNK (network migration P5 item 2, plan §11). Its purpose, its serializer,
        // its golden and this case land in the same change — the 91c3956 pairing again.
        assertRoutedChunkFramingHolds()
        assertCustodyReceiptFramingHolds()

        // Still POSITIONAL, not a substring search: a length-prefixed purpose rejects its own raw
        // spelling. Accepting that would let a transcript carry the domain in an attacker-chosen
        // field and still reach the identity key.
        #expect(envelopePurpose.signingBytes(envelopePurpose.data) == nil)
        #expect(reportPurpose.signingBytes(reportPurpose.data) == nil)
        #expect(introductionPurpose.signingBytes(introductionPurpose.data) == nil)
    }

    /// The seven membership-event transcripts against their declared `.lengthPrefixed` framing, and
    /// against each OTHER's — a departure that satisfied the termination purpose would mean a
    /// member removing itself and a member ending the mesh for everyone shared a signature.
    ///
    /// Split out of ``canonicalSerializerTranscriptsMatchTheirDeclaredFraming()`` so neither
    /// function grows past the 60-line rule; both halves run in the same test.
    private func assertMembershipFramingHolds() {
        let departure = canonicalBytes(for: MeshMembershipEventFixtures.departure())
        let removal = canonicalBytes(for: MeshMembershipEventFixtures.removal())
        let termination = canonicalBytes(for: MeshMembershipEventFixtures.termination())
        let inventory = canonicalBytes(for: MeshMembershipEventFixtures.inventoryPayload())
        let epochHeads = canonicalBytes(for: MeshMembershipEventFixtures.epochHeadsPayload())
        let proposal = canonicalBytes(for: MeshMembershipEventFixtures.removalProposal())
        let vote = canonicalBytes(for: MeshMembershipEventFixtures.removalVote())

        let departurePurpose = FernletCryptoPurpose.Signature.meshMemberDepartureV1
        let removalPurpose = FernletCryptoPurpose.Signature.meshMemberRemovalV1
        let terminationPurpose = FernletCryptoPurpose.Signature.meshTerminatedV1
        let inventoryPurpose = FernletCryptoPurpose.Signature.meshInventoryDigestV1
        let epochHeadsPurpose = FernletCryptoPurpose.Signature.meshEpochHeadsV1
        let proposalPurpose = FernletCryptoPurpose.Signature.meshRemovalProposalV1
        let votePurpose = FernletCryptoPurpose.Signature.meshRemovalVoteV1

        #expect(departurePurpose.signingBytes(departure) != nil)
        #expect(removalPurpose.signingBytes(removal) != nil)
        #expect(terminationPurpose.signingBytes(termination) != nil)
        #expect(inventoryPurpose.signingBytes(inventory) != nil)
        #expect(epochHeadsPurpose.signingBytes(epochHeads) != nil)
        #expect(proposalPurpose.signingBytes(proposal) != nil)
        #expect(votePurpose.signingBytes(vote) != nil)

        #expect(departurePurpose.signingBytes(termination) == nil)
        #expect(terminationPurpose.signingBytes(departure) == nil)
        #expect(removalPurpose.signingBytes(inventory) == nil)
        #expect(inventoryPurpose.signingBytes(removal) == nil)
        // The pair P4 item 3 adds: the digest and the head set travel the same reconnect, so a
        // signature that satisfied both domains would let a peer's "what I hold" be replayed as
        // "what epoch I am on" — which is the input to the counter a merge mints at.
        #expect(inventoryPurpose.signingBytes(epochHeads) == nil)
        #expect(epochHeadsPurpose.signingBytes(inventory) == nil)
        // The pair P4 item 5 adds: a proposal and a vote are the same field shape with the author
        // in the same position, so ONLY the domain keeps them apart — and neither may satisfy the
        // completed removal's domain, or one live vote could be replayed as a finished quorum.
        #expect(proposalPurpose.signingBytes(vote) == nil)
        #expect(votePurpose.signingBytes(proposal) == nil)
        #expect(removalPurpose.signingBytes(vote) == nil)
        #expect(votePurpose.signingBytes(removal) == nil)

        #expect(departurePurpose.signingBytes(departurePurpose.data) == nil)
        #expect(inventoryPurpose.signingBytes(inventoryPurpose.data) == nil)
        #expect(epochHeadsPurpose.signingBytes(epochHeadsPurpose.data) == nil)
    }

    /// The routed manifest against its declared `.lengthPrefixed` framing and against the
    /// membership frames it travels beside: a manifest that satisfied the inventory digest's
    /// purpose would let "what I am sending" be replayed as "what I hold", and one that satisfied
    /// the departure's would let content stand in for a member leaving.
    private func assertRoutedFramingHolds() {
        let manifestPurpose = FernletCryptoPurpose.Signature.meshRoutedManifestV1
        let inventoryPurpose = FernletCryptoPurpose.Signature.meshInventoryDigestV1
        let epochHeadsPurpose = FernletCryptoPurpose.Signature.meshEpochHeadsV1
        let departurePurpose = FernletCryptoPurpose.Signature.meshMemberDepartureV1
        let manifest = canonicalBytes(for: MeshRoutedManifestFixtures.manifest())
        let inventory = canonicalBytes(for: MeshMembershipEventFixtures.inventoryPayload())
        let epochHeads = canonicalBytes(for: MeshMembershipEventFixtures.epochHeadsPayload())
        let departure = canonicalBytes(for: MeshMembershipEventFixtures.departure())
        #expect(manifestPurpose.signingBytes(manifest) != nil)                 // declared == emitted
        #expect(inventoryPurpose.signingBytes(manifest) == nil)                // cross-domain, both ways
        #expect(manifestPurpose.signingBytes(inventory) == nil)
        #expect(epochHeadsPurpose.signingBytes(manifest) == nil)
        #expect(manifestPurpose.signingBytes(epochHeads) == nil)
        #expect(departurePurpose.signingBytes(manifest) == nil)
        #expect(manifestPurpose.signingBytes(departure) == nil)
        #expect(manifestPurpose.signingBytes(manifestPurpose.data) == nil)     // positional: rejects its own raw spelling
    }

    /// The routed chunk against its declared `.lengthPrefixed` framing and against the manifest it
    /// travels beside for every routed item: a chunk that satisfied the manifest's purpose would
    /// let "these bytes are part of it" be replayed as "this is who the item is for and who can
    /// open it", which is a destination set and a key-wrap list swapped under an authentic-looking
    /// transfer. The fixture is the same one the golden pins, so the framing case and the golden
    /// cannot drift apart.
    private func assertRoutedChunkFramingHolds() {
        let chunkPurpose = FernletCryptoPurpose.Signature.meshRoutedChunkV1
        let manifestPurpose = FernletCryptoPurpose.Signature.meshRoutedManifestV1
        let inventoryPurpose = FernletCryptoPurpose.Signature.meshInventoryDigestV1
        let chunk = canonicalBytes(for: MeshChunkFixtures.chunk())
        let manifest = canonicalBytes(for: MeshRoutedManifestFixtures.manifest())
        #expect(chunkPurpose.signingBytes(chunk) != nil)                 // declared == emitted
        #expect(manifestPurpose.signingBytes(chunk) == nil)              // cross-domain, both ways
        #expect(chunkPurpose.signingBytes(manifest) == nil)
        #expect(inventoryPurpose.signingBytes(chunk) == nil)             // and against the digest
        #expect(chunkPurpose.signingBytes(chunkPurpose.data) == nil)     // positional: its own raw spelling
    }

    /// The custody receipt against its declared `.lengthPrefixed` framing, and against BOTH routed
    /// domains — the receipt travels the same transfer as the manifest and the chunk it is about, so
    /// a signature satisfying two of the three would let "I am holding it" stand in for "this is who
    /// it is for" or "these bytes are part of it", under the wrong key.
    ///
    /// Split out of ``canonicalSerializerTranscriptsMatchTheirDeclaredFraming()`` so neither function
    /// grows past the 60-line rule; both halves run in the same test. Purposes are declared
    /// function-local because sibling helpers cannot see each other's `let`s.
    private func assertCustodyReceiptFramingHolds() {
        let receiptPurpose = FernletCryptoPurpose.Signature.meshCustodyReceiptV1
        let manifestPurpose = FernletCryptoPurpose.Signature.meshRoutedManifestV1
        let chunkPurpose = FernletCryptoPurpose.Signature.meshRoutedChunkV1
        let receipt = canonicalBytes(for: MeshCustodyReceiptFixtures.receipt())
        let manifest = canonicalBytes(for: MeshRoutedManifestFixtures.manifest())
        let chunk = canonicalBytes(for: MeshChunkFixtures.chunk())
        #expect(receiptPurpose.signingBytes(receipt) != nil)          // declared == emitted
        #expect(manifestPurpose.signingBytes(receipt) == nil)         // cross-domain, both ways
        #expect(receiptPurpose.signingBytes(manifest) == nil)
        #expect(chunkPurpose.signingBytes(receipt) == nil)
        #expect(receiptPurpose.signingBytes(chunk) == nil)
        #expect(receiptPurpose.signingBytes(receiptPurpose.data) == nil)  // positional self-rejection
    }

    /// The raw-prefix family: transcripts that concatenate their domain directly. Rejecting a
    /// one-byte-shifted transcript is what stops the check degrading into "contains the domain".
    @Test func rawPrefixTranscriptsMatchTheirDeclaredFraming() {
        let purpose = FernletCryptoPurpose.Signature.proximityQRResponseV1
        let message = ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: Data(repeating: 6, count: 32),
            challengeNonce: Data(repeating: 7, count: 16),
            qrNonce: Data(repeating: 8, count: 16)
        )
        #expect(purpose.signingBytes(message) != nil)
        #expect(purpose.signingBytes(Data([0x00]) + message) == nil)
    }

    /// Legacy read-only purposes embed no domain at all, so they must accept the untagged bytes
    /// their pre-separation formats actually carry — otherwise old peers stop verifying.
    @Test func legacyPurposesAcceptUntaggedTranscripts() {
        let legacy = FernletCryptoPurpose.Signature.identityEnvelopeLegacyV1
        #expect(legacy.signingBytes(Data("{\"schemaVersion\":1}".utf8)) != nil)
        #expect(FernletCryptoPurpose.Signature.meshAdmissionTokenLegacyV1.signingBytes(Data()) != nil)
    }

    private func hasPurpose(_ context: String) -> Bool {
        context.contains("FernletCryptoPurpose")
            || context.contains("CryptographicPurpose")
            || context.contains("purpose")
            || context.contains("authenticated")
            || context.contains("cryptographic-domain:")
    }
}
