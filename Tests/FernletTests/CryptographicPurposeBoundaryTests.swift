import Foundation
import FernletCrypto
import FernletDomainModel
import ProximityKit
import Testing

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

        // Still POSITIONAL, not a substring search: a length-prefixed purpose rejects its own raw
        // spelling. Accepting that would let a transcript carry the domain in an attacker-chosen
        // field and still reach the identity key.
        #expect(envelopePurpose.signingBytes(envelopePurpose.data) == nil)
        #expect(reportPurpose.signingBytes(reportPurpose.data) == nil)
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
