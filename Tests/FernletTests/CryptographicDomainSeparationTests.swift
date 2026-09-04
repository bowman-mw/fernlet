import CryptoKit
import Foundation
import Testing
@testable import FernletCrypto

/// The CONTRACT domain separation exists to provide, tested as a property of the whole registry.
///
/// **Why this suite exists.** `91c3956` rewrote every cryptographic call site in the app to name a
/// typed purpose, and shipped with four test files touched — about 46 lines. What those tests prove
/// is that each format still round-trips: seal with purpose P, open with purpose P, get the
/// plaintext back. That is worth having and it is NOT the property the change was made for. A
/// round-trip passes identically whether the purpose is bound into the key and the authenticated
/// data or ignored entirely, because both sides use the same one. The failure domain separation
/// prevents is the CROSS-domain one — a ciphertext, tag or derived key from one context being
/// accepted in another — and no same-purpose round-trip can see it.
///
/// So every test here is a NEGATIVE: it does the thing that must not work, and requires it to fail.
/// If someone drops `info:` from an HKDF call, stops passing `authenticating:` to an AEAD seal, or
/// gives two registry entries the same spelling, the round-trip suites all stay green and these go
/// red.
///
/// **Coverage is all-pairs, not sampled.** 54 purposes over five families; a hand-picked pair or
/// two would prove the primitive works, which nobody doubts. What is actually at risk is one entry
/// — the new one, the copy-pasted one — and only a total sweep sees it. The pair counts are small
/// enough that this costs milliseconds.
///
/// **The inventory is checked against the source, not trusted.** `FernletCryptoPurpose` is nested
/// enums of `static let`, which no Swift reflection enumerates, so allDomains is written out by
/// hand — and a hand-written list silently stops covering the thing it lists.
/// theInventoryCoversEveryDeclaredPurpose() reads
/// `FernletKit/Sources/FernletCrypto/CryptographicPurpose.swift` off disk and requires the two to
/// agree, so a purpose added without a line here fails loudly instead of quietly going untested.
///
/// **What this does NOT cover**, kept honest here rather than implied by the file name:
/// - Whether each CALL SITE passes the purpose its format actually needs. That is
///   `CryptographicPurposeBoundaryTests.rawCryptographicCallsNameAPurpose()` (a purpose is named)
///   plus that suite's framing tests (the named purpose matches the serializer's bytes). This suite
///   proves the registry's values are usable for separation; that one proves they are used.
/// - Whether a purpose is the RIGHT one — journal copy sealed under the worry purpose separates
///   perfectly from everything and is still wrong. Review catches that; no test can.
struct CryptographicDomainSeparationTests {

    /// One registry entry, with the source spelling of its path for failure messages.
    struct Domain: Sendable {
        let name: String
        let purpose: CryptographicPurpose

        init(_ name: String, _ purpose: CryptographicPurpose) {
            self.name = name
            self.purpose = purpose
        }
    }

    /// Every purpose in the registry. Pinned against the source by
    /// theInventoryCoversEveryDeclaredPurpose() — add a line here when you add one there.
    static let allDomains: [Domain] = [
        // Signature
        Domain("Signature.identityEnvelopeV2", FernletCryptoPurpose.Signature.identityEnvelopeV2),
        Domain("Signature.identityEnvelopeLegacyV1", FernletCryptoPurpose.Signature.identityEnvelopeLegacyV1),
        Domain("Signature.meshAdmissionTokenV2", FernletCryptoPurpose.Signature.meshAdmissionTokenV2),
        Domain("Signature.meshAdmissionTokenLegacyV1", FernletCryptoPurpose.Signature.meshAdmissionTokenLegacyV1),
        Domain("Signature.activityDescriptorV2", FernletCryptoPurpose.Signature.activityDescriptorV2),
        Domain("Signature.activityJoinTokenV2", FernletCryptoPurpose.Signature.activityJoinTokenV2),
        Domain("Signature.activityRosterSnapshotV2", FernletCryptoPurpose.Signature.activityRosterSnapshotV2),
        Domain("Signature.moderationReportV2", FernletCryptoPurpose.Signature.moderationReportV2),
        Domain("Signature.meshProbeChannelIntroductionV1", FernletCryptoPurpose.Signature.meshProbeChannelIntroductionV1),
        Domain("Signature.meshChannelIntroductionV1", FernletCryptoPurpose.Signature.meshChannelIntroductionV1),
        Domain("Signature.meshRoutedManifestV1", FernletCryptoPurpose.Signature.meshRoutedManifestV1),
        Domain("Signature.meshRoutedChunkV1", FernletCryptoPurpose.Signature.meshRoutedChunkV1),
        Domain("Signature.meshCustodyReceiptV1", FernletCryptoPurpose.Signature.meshCustodyReceiptV1),
        Domain("Signature.meshRecipientReceiptV1", FernletCryptoPurpose.Signature.meshRecipientReceiptV1),
        Domain("Signature.meshRoutedInventoryDigestV1", FernletCryptoPurpose.Signature.meshRoutedInventoryDigestV1),
        Domain("Signature.meshRoutedDrainAnswerV1", FernletCryptoPurpose.Signature.meshRoutedDrainAnswerV1),
        Domain("Signature.meshMemberDepartureV1", FernletCryptoPurpose.Signature.meshMemberDepartureV1),
        Domain("Signature.meshMemberRemovalV1", FernletCryptoPurpose.Signature.meshMemberRemovalV1),
        Domain("Signature.meshTerminatedV1", FernletCryptoPurpose.Signature.meshTerminatedV1),
        Domain("Signature.meshInventoryDigestV1", FernletCryptoPurpose.Signature.meshInventoryDigestV1),
        Domain("Signature.meshEpochHeadsV1", FernletCryptoPurpose.Signature.meshEpochHeadsV1),
        Domain("Signature.meshRemovalProposalV1", FernletCryptoPurpose.Signature.meshRemovalProposalV1),
        Domain("Signature.meshRemovalVoteV1", FernletCryptoPurpose.Signature.meshRemovalVoteV1),
        Domain("Signature.proximityQRIdentityV1", FernletCryptoPurpose.Signature.proximityQRIdentityV1),
        Domain("Signature.proximityQRResponseV1", FernletCryptoPurpose.Signature.proximityQRResponseV1),
        Domain("Signature.duressRecoveryRequestV1", FernletCryptoPurpose.Signature.duressRecoveryRequestV1),
        Domain("Signature.duressRecoveryReplyV1", FernletCryptoPurpose.Signature.duressRecoveryReplyV1),
        // KeyDerivation
        Domain("KeyDerivation.sealedBackupLegacyV1", FernletCryptoPurpose.KeyDerivation.sealedBackupLegacyV1),
        Domain("KeyDerivation.sealedBackupV2", FernletCryptoPurpose.KeyDerivation.sealedBackupV2),
        Domain("KeyDerivation.proximityTransportV1", FernletCryptoPurpose.KeyDerivation.proximityTransportV1),
        Domain("KeyDerivation.heartDropPairV1", FernletCryptoPurpose.KeyDerivation.heartDropPairV1),
        Domain("KeyDerivation.presencePairV1", FernletCryptoPurpose.KeyDerivation.presencePairV1),
        Domain("KeyDerivation.meshGroupKeyWrapV1", FernletCryptoPurpose.KeyDerivation.meshGroupKeyWrapV1),
        Domain("KeyDerivation.meshProbeTLSExporterV1", FernletCryptoPurpose.KeyDerivation.meshProbeTLSExporterV1),
        Domain("KeyDerivation.meshTLSExporterV1", FernletCryptoPurpose.KeyDerivation.meshTLSExporterV1),
        Domain("KeyDerivation.meshRoutedContentKeyWrapV1", FernletCryptoPurpose.KeyDerivation.meshRoutedContentKeyWrapV1),
        Domain("KeyDerivation.meshSessionContextV1", FernletCryptoPurpose.KeyDerivation.meshSessionContextV1),
        Domain("KeyDerivation.meshRoutedStoreV1", FernletCryptoPurpose.KeyDerivation.meshRoutedStoreV1),
        Domain("KeyDerivation.heartDropOuterSealV1", FernletCryptoPurpose.KeyDerivation.heartDropOuterSealV1),
        Domain("KeyDerivation.lockScryptWrappingV1", FernletCryptoPurpose.KeyDerivation.lockScryptWrappingV1),
        Domain("KeyDerivation.journalNarrativeLegacyV1", FernletCryptoPurpose.KeyDerivation.journalNarrativeLegacyV1),
        Domain("KeyDerivation.worryNarrativeLegacyV1", FernletCryptoPurpose.KeyDerivation.worryNarrativeLegacyV1),
        Domain("KeyDerivation.menstrualNarrativeLegacyV1", FernletCryptoPurpose.KeyDerivation.menstrualNarrativeLegacyV1),
        Domain("KeyDerivation.intimacyLogLegacyV1", FernletCryptoPurpose.KeyDerivation.intimacyLogLegacyV1),
        // HMAC
        Domain("HMAC.heartDropDayTagV1", FernletCryptoPurpose.HMAC.heartDropDayTagV1),
        Domain("HMAC.presenceEpochTagV1", FernletCryptoPurpose.HMAC.presenceEpochTagV1),
        // AEAD
        Domain("AEAD.sealedBackupV2", FernletCryptoPurpose.AEAD.sealedBackupV2),
        Domain("AEAD.sealedPhotoBackupV3", FernletCryptoPurpose.AEAD.sealedPhotoBackupV3),
        Domain("AEAD.proximityTransportV2", FernletCryptoPurpose.AEAD.proximityTransportV2),
        Domain("AEAD.meshGroupKeyWrapV2", FernletCryptoPurpose.AEAD.meshGroupKeyWrapV2),
        Domain("AEAD.meshGroupPhotoV2", FernletCryptoPurpose.AEAD.meshGroupPhotoV2),
        Domain("AEAD.meshEncryptedMetadataV2", FernletCryptoPurpose.AEAD.meshEncryptedMetadataV2),
        Domain("AEAD.meshRoutedContentKeyWrapV1", FernletCryptoPurpose.AEAD.meshRoutedContentKeyWrapV1),
        Domain("AEAD.meshRoutedItemV1", FernletCryptoPurpose.AEAD.meshRoutedItemV1),
        Domain("AEAD.heartDropSidecarV2", FernletCryptoPurpose.AEAD.heartDropSidecarV2),
        Domain("AEAD.pendingNarrativeBufferV2", FernletCryptoPurpose.AEAD.pendingNarrativeBufferV2),
        Domain("AEAD.lockContentKeyWrapV2", FernletCryptoPurpose.AEAD.lockContentKeyWrapV2),
        Domain("AEAD.columnDeviceBoundV3", FernletCryptoPurpose.AEAD.columnDeviceBoundV3),
        Domain("AEAD.privateFriendPhotoImageV2", FernletCryptoPurpose.AEAD.privateFriendPhotoImageV2),
        Domain("AEAD.privateFriendPhotoThumbnailV2", FernletCryptoPurpose.AEAD.privateFriendPhotoThumbnailV2),
        Domain("AEAD.privateFriendPhotoIndexV2", FernletCryptoPurpose.AEAD.privateFriendPhotoIndexV2),
        Domain("AEAD.mealPhotoV2", FernletCryptoPurpose.AEAD.mealPhotoV2),
        Domain("AEAD.recipePhotoV2", FernletCryptoPurpose.AEAD.recipePhotoV2),
        Domain("AEAD.progressPhotoV2", FernletCryptoPurpose.AEAD.progressPhotoV2),
        Domain("AEAD.progressPhotoIndexV2", FernletCryptoPurpose.AEAD.progressPhotoIndexV2),
        // Hash
        Domain("Hash.sealedPhotoContentV2", FernletCryptoPurpose.Hash.sealedPhotoContentV2),
        Domain("Hash.lockVerifierV2", FernletCryptoPurpose.Hash.lockVerifierV2),
        Domain("Hash.meshInventoryDigestV1", FernletCryptoPurpose.Hash.meshInventoryDigestV1),
        Domain("Hash.meshRoutedContentV1", FernletCryptoPurpose.Hash.meshRoutedContentV1),
        Domain("Hash.meshRoutedChunkV1", FernletCryptoPurpose.Hash.meshRoutedChunkV1),
        Domain("Hash.meshRoutedChunkIDV1", FernletCryptoPurpose.Hash.meshRoutedChunkIDV1),
        Domain("Hash.meshCustodyReceiptIDV1", FernletCryptoPurpose.Hash.meshCustodyReceiptIDV1),
        Domain("Hash.meshRecipientReceiptIDV1", FernletCryptoPurpose.Hash.meshRecipientReceiptIDV1),
        Domain("Hash.recoveryContentKeyV1", FernletCryptoPurpose.Hash.recoveryContentKeyV1),
    ]

    /// Fixed, non-secret material. Deterministic on purpose: a failure here must reproduce.
    static let contentKey = SymmetricKey(data: Data(repeating: 0x2A, count: 32))
    static let plaintext = Data("domain-separation probe".utf8)

    // MARK: - The precondition: distinct spellings

    /// No two registry entries share a `rawValue`.
    ///
    /// This is the precondition every other test in this file rests on, and the likeliest way to
    /// lose separation in practice: a new entry added by copying the line above it and editing the
    /// Swift name but not the string. The two domains then derive the SAME key and authenticate the
    /// SAME bytes, one context's ciphertext opens in the other, and every round-trip test still
    /// passes — there is no error anywhere, just two contexts quietly sharing a domain.
    @Test func everyPurposeSpellingIsUnique() {
        var seen: [String: String] = [:]
        var collisions: [String] = []
        for domain in Self.allDomains {
            if let first = seen[domain.purpose.rawValue] {
                collisions.append("\(first) and \(domain.name) both spell \"\(domain.purpose.rawValue)\"")
            }
            seen[domain.purpose.rawValue] = domain.name
        }
        #expect(
            collisions.isEmpty,
            """
            \(collisions.count) pair(s) of cryptographic purposes share a spelling, so they are the
            SAME domain and separate from each other not at all. Nothing else fails when this is
            true — both round-trip, both verify, and one context's ciphertext opens in the other:
            \(collisions.sorted().joined(separator: "\n"))
            """
        )
    }

    /// The hand-written inventory covers every purpose the source declares.
    ///
    /// House rule (S3BoundaryTests): discover the input from disk and carry a hard floor, so a
    /// moved file fails loudly rather than passing over zero declarations.
    @Test func theInventoryCoversEveryDeclaredPurpose() throws {
        let source = try RepoRoot.source("FernletKit/Sources/FernletCrypto/CryptographicPurpose.swift")
        let declared = Self.declaredRawValues(in: source)

        #expect(
            declared.count >= Self.minimumDeclaredPurposes,
            """
            Found only \(declared.count) purpose declarations in CryptographicPurpose.swift (floor
            \(Self.minimumDeclaredPurposes)) — the file moved, or the declaration shape changed and
            this scan is now reading nothing. Every test in this suite would pass vacuously.
            """
        )

        let inventoried = Set(Self.allDomains.map(\.purpose.rawValue))
        let untested = declared.subtracting(inventoried)
        #expect(
            untested.isEmpty,
            """
            \(untested.count) purpose(s) are declared in the registry but missing from
            `allDomains`, so NOTHING in this suite tests them — not their uniqueness, not their key
            separation, not their AAD separation. Add a `Domain(…)` line for each:
            \(untested.sorted().joined(separator: "\n"))
            """
        )

        let stale = inventoried.subtracting(declared)
        #expect(
            stale.isEmpty,
            """
            \(stale.count) inventoried purpose(s) no longer appear in the registry source. If one
            was renamed, its at-rest format changed with it — confirm the migration exists, then
            update this list:
            \(stale.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Floor for the source scan (54 declarations at the time of writing).
    static let minimumDeclaredPurposes = 40

    /// Every `CryptographicPurpose("…")` spelling declared in `source`.
    static func declaredRawValues(in source: String) -> Set<String> {
        var found: Set<String> = []
        for line in source.components(separatedBy: "\n") {
            guard let head = line.range(of: "CryptographicPurpose(\"") else { continue }
            let rest = line[head.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { continue }
            found.insert(String(rest[..<close]))
        }
        return found
    }

    /// Fixture: the declaration scanner reads the shapes the registry is written in, and does not
    /// count the type's own definition or its documentation.
    @Test func theDeclarationScannerReadsTheRegistryShapes() {
        #expect(Self.declaredRawValues(in: """
            public static let sealedBackupV2 = CryptographicPurpose("com.fernlet.sealed-backup.v2")
            """) == ["com.fernlet.sealed-backup.v2"])
        #expect(Self.declaredRawValues(in: """
            public static let identityEnvelopeV2 = CryptographicPurpose("fernlet.canonical.identity-envelope.v2", framing: .lengthPrefixed)
            """) == ["fernlet.canonical.identity-envelope.v2"], "a framing argument must not hide the spelling")
        #expect(Self.declaredRawValues(in: """
            public nonisolated struct CryptographicPurpose: Hashable, Sendable {
                fileprivate init(_ rawValue: String, framing: TranscriptFraming = .rawPrefix) {
            """).isEmpty, "the type's own definition declares no purpose")
    }

    // MARK: - Key derivation: a purpose that does not reach the KDF separates nothing

    /// Every pair of purposes derives a DIFFERENT key from the same content key.
    ///
    /// This is the property `ColumnCrypto.deriveColumnKey` sells: one unlocked content key, four
    /// sealed columns, and journal ciphertext that cannot be opened with the worry column's key.
    /// It holds only while the purpose actually reaches HKDF's `info`. Drop that argument and every
    /// column derives the same key — every round-trip still passes, and every column becomes
    /// readable from every other.
    @Test func everyPurposePairDerivesADistinctKey() {
        var derived: [Data: String] = [:]
        var collisions: [String] = []
        for domain in Self.allDomains {
            let key = ColumnCrypto.deriveColumnKey(
                contentKey: Self.contentKey, purpose: domain.purpose, outputByteCount: 32
            )
            let bytes = key.withUnsafeBytes { Data($0) }
            if let first = derived[bytes] {
                collisions.append("\(first) and \(domain.name) derive the same 32-byte key")
            }
            derived[bytes] = domain.name
        }
        #expect(
            collisions.isEmpty,
            """
            \(collisions.count) purpose pair(s) derive an IDENTICAL key from the same content key, so
            either their spellings collided or the purpose stopped reaching HKDF's `info` argument.
            Every same-purpose round-trip in the suite passes either way:
            \(collisions.sorted().joined(separator: "\n"))
            """
        )
    }

    /// A column sealed under one purpose does not open under another — the end-to-end form, through
    /// the real `ColumnCrypto` seal/open path rather than the KDF alone.
    ///
    /// The four legacy narrative purposes are the live case: journal, worry, menstrual and intimacy
    /// columns share ONE content key and are separated by nothing else.
    @Test func aColumnSealedUnderOnePurposeDoesNotOpenUnderAnother() throws {
        let purposes = [
            ("journal", FernletCryptoPurpose.KeyDerivation.journalNarrativeLegacyV1),
            ("worry", FernletCryptoPurpose.KeyDerivation.worryNarrativeLegacyV1),
            ("menstrual", FernletCryptoPurpose.KeyDerivation.menstrualNarrativeLegacyV1),
            ("intimacy", FernletCryptoPurpose.KeyDerivation.intimacyLogLegacyV1),
        ]
        for (sealerName, sealerPurpose) in purposes {
            let sealed = try ColumnCrypto(purpose: sealerPurpose)
                .sealString("a private sentence", contentKey: Self.contentKey)

            // Sanity: the matching purpose DOES open it, so a failure below is separation and not a
            // broken fixture.
            #expect(
                try ColumnCrypto(purpose: sealerPurpose)
                    .openString(sealed, contentKey: Self.contentKey) == "a private sentence",
                "\(sealerName) must open its own column, or this test proves nothing"
            )

            for (openerName, openerPurpose) in purposes where openerName != sealerName {
                #expect(throws: (any Error).self) {
                    _ = try ColumnCrypto(purpose: openerPurpose)
                        .openString(sealed, contentKey: Self.contentKey)
                }
            }
        }
    }

    // MARK: - AEAD: the authenticated-data binding, held independent of the key

    /// A ciphertext authenticated under one purpose does not open under another, with the KEY HELD
    /// CONSTANT.
    ///
    /// Holding the key fixed is the whole design of this test. Most AEAD call sites in the tree bind
    /// the purpose twice — once through the derived key, once through the AAD — and if the key is
    /// allowed to vary, the open fails for the KEY's reason and the AAD binding is never exercised
    /// at all. A test that let both move would pass with `authenticating:` deleted from every seal
    /// in the codebase. This one fails the moment the AAD stops carrying the domain, which is what
    /// `ColumnCrypto`'s v3 format, the mesh group-photo blobs, the heart-drop sidecar and the lock's
    /// content-key wrap all rely on.
    @Test func aCiphertextDoesNotOpenUnderAForeignAuthenticatedDomain() throws {
        let key = SymmetricKey(size: .bits256)
        for sealer in Self.allDomains {
            let sealed = try ChaChaPoly.seal(
                Self.plaintext, using: key, authenticating: sealer.purpose.data
            )

            #expect(
                try ChaChaPoly.open(sealed, using: key, authenticating: sealer.purpose.data) == Self.plaintext,
                "\(sealer.name) must open under its own AAD, or this test proves nothing"
            )

            for opener in Self.allDomains where opener.purpose.rawValue != sealer.purpose.rawValue {
                #expect(throws: (any Error).self) {
                    _ = try ChaChaPoly.open(sealed, using: key, authenticating: opener.purpose.data)
                }
            }
        }
    }

    /// The same property for AES-GCM, the other AEAD in the tree.
    @Test func aesGCMAlsoRejectsAForeignAuthenticatedDomain() throws {
        let key = SymmetricKey(size: .bits256)
        let sealer = FernletCryptoPurpose.AEAD.sealedPhotoBackupV3
        let sealed = try AES.GCM.seal(Self.plaintext, using: key, authenticating: sealer.data)
        #expect(try AES.GCM.open(sealed, using: key, authenticating: sealer.data) == Self.plaintext)
        for opener in Self.allDomains where opener.purpose.rawValue != sealer.rawValue {
            #expect(throws: (any Error).self) {
                _ = try AES.GCM.open(sealed, using: key, authenticating: opener.purpose.data)
            }
        }
    }

    /// The purpose is bound into the PRODUCTION v3 seal's authenticated data, held apart from the
    /// key it also derives.
    ///
    /// This is the one test here that drives the real `ColumnCrypto.sealString` rather than
    /// CryptoKit directly, and it exists because the two obvious tests both miss the target:
    ///
    /// * A cross-purpose `openString` (which ``aColumnSealedUnderOnePurposeDoesNotOpenUnderAnother``
    ///   does) fails because the derived KEY differs. It would pass just as green with
    ///   `authenticating:` deleted from the v3 seal entirely — the AAD binding is never reached.
    /// * A CryptoKit-only AAD test (``aCiphertextDoesNotOpenUnderAForeignAuthenticatedDomain``)
    ///   proves the registry's values work as AAD, but seals its own ciphertext, so it says nothing
    ///   about whether production passes them.
    ///
    /// So this seals through production, then derives the sealing purpose's OWN column key by hand
    /// and attempts the open with that correct key and a FOREIGN purpose in the AAD. The key is
    /// right, the binding is right, the nonce and tag are right; the only wrong byte is the domain.
    /// It must still fail — and it only can if the seal really wrote `purpose.data + binding`
    /// rather than `binding` alone (which is exactly what the v2 format did, and what a revert to
    /// v2 would silently reinstate).
    ///
    /// The binding is pinned through `DeviceBindingID`'s `@TaskLocal` seam so the test does not
    /// depend on whether the simulator keychain happens to hold an install row. Before Phase 3
    /// that pin also guarded against a *vacuous pass*: with no binding the writer fell back to the
    /// LEGACY no-AAD format and this test proved nothing about AAD at all. The writer now refuses
    /// instead, so the un-pinned failure would be loud rather than silent — the pin stays because
    /// a test that only passes when the keychain cooperates is not a pin.
    @Test func theProductionSealBindsThePurposeIntoTheAuthenticatedData() throws {
        let binding = Data(repeating: 0xC3, count: 16)
        let sealer = FernletCryptoPurpose.KeyDerivation.journalNarrativeLegacyV1
        let foreign = FernletCryptoPurpose.KeyDerivation.worryNarrativeLegacyV1

        let blob = try DeviceBindingID.$testOverride.withValue(.identifier(binding)) {
            try ColumnCrypto(purpose: sealer).sealString("a private sentence", contentKey: Self.contentKey)
        }
        #expect(
            blob.first == ColumnCrypto.deviceBoundFormatVersionV3,
            "the seal fell back to a format with no authenticated data — the rest of this test would prove nothing"
        )

        let key = ColumnCrypto.deriveColumnKey(
            contentKey: Self.contentKey, purpose: sealer, outputByteCount: 32
        )
        let box = try ChaChaPoly.SealedBox(combined: blob.dropFirst())

        // Correct key, correct binding, CORRECT domain: opens. Establishes that the only variable
        // below is the domain.
        #expect(
            try ChaChaPoly.open(box, using: key, authenticating: sealer.data + binding) == Data("a private sentence".utf8)
        )

        // Correct key, correct binding, FOREIGN domain: must not open.
        #expect(throws: (any Error).self) {
            _ = try ChaChaPoly.open(box, using: key, authenticating: foreign.data + binding)
        }

        // And the v2 shape — binding alone, no domain — must not open either. This is the specific
        // regression: a revert to `authenticating: binding` makes THIS succeed.
        #expect(throws: (any Error).self) {
            _ = try ChaChaPoly.open(box, using: key, authenticating: binding)
        }
    }

    // MARK: - HMAC and hashing

    /// Every purpose produces a distinct HMAC tag over identical data under an identical key.
    ///
    /// The heart-drop day tag and the presence epoch tag are both HMACs over time-derived values
    /// under a shared pair key. Sharing a domain would make one replayable as the other.
    @Test func everyPurposeProducesADistinctHMACTag() {
        let key = SymmetricKey(data: Data(repeating: 0x5C, count: 32))
        var tags: [Data: String] = [:]
        var collisions: [String] = []
        for domain in Self.allDomains {
            let tag = Data(HMAC<SHA256>.authenticationCode(for: domain.purpose.data + Self.plaintext, using: key))
            if let first = tags[tag] { collisions.append("\(first) and \(domain.name) produce the same tag") }
            tags[tag] = domain.name
        }
        #expect(collisions.isEmpty, "HMAC domains collided:\n\(collisions.sorted().joined(separator: "\n"))")
    }

    /// Every purpose produces a distinct digest over identical content.
    ///
    /// The sealed-photo content hash and the lock verifier are both persisted digests: a shared
    /// domain would let one be presented as the other.
    @Test func everyPurposeProducesADistinctDigest() {
        var digests: [Data: String] = [:]
        var collisions: [String] = []
        for domain in Self.allDomains {
            let digest = Data(SHA256.hash(data: domain.purpose.data + Self.plaintext))
            if let first = digests[digest] { collisions.append("\(first) and \(domain.name) hash identically") }
            digests[digest] = domain.name
        }
        #expect(collisions.isEmpty, "hash domains collided:\n\(collisions.sorted().joined(separator: "\n"))")
    }

    // MARK: - Signature transcripts, across purposes

    /// A domain-tagged transcript built for one purpose is rejected by every other.
    ///
    /// `CryptographicPurposeBoundaryTests` proves each purpose ACCEPTS the bytes its own serializer
    /// produces — the framing half, and the half that broke in `91c3956`. This is the other
    /// direction: that accepting is DISCRIMINATING. Without it, `signingBytes` returning its input
    /// unconditionally would satisfy every framing test in the repo.
    @Test func aTaggedTranscriptIsRejectedByEveryForeignPurpose() {
        let tagged = Self.taggedSignaturePurposes
        #expect(tagged.count >= 10, "the tagged-signature family shrank — did a purpose lose its framing?")
        for sealer in tagged {
            guard let transcript = Self.acceptedTranscript(for: sealer.purpose) else {
                Issue.record("\(sealer.name) accepts neither of the two shipped framings — a third one appeared, and this test no longer covers it")
                continue
            }
            for opener in tagged where opener.purpose.rawValue != sealer.purpose.rawValue {
                #expect(
                    opener.purpose.signingBytes(transcript) == nil,
                    "\(opener.name) accepted a transcript domain-tagged for \(sealer.name)"
                )
            }
        }
    }

    /// The transcript `purpose` accepts, built by construction rather than read from the type.
    ///
    /// `CryptographicPurpose.framing` is `private`, and `@testable` grants `internal`, not `private`
    /// — so the test cannot ask which shape a purpose wants. It does not need to: exactly two
    /// framings are shipped (`.rawPrefix` and `.lengthPrefixed`), so trying both and requiring one
    /// to be accepted proves the same thing without reaching into the type. If a third framing is
    /// ever added, this returns nil and the caller records that rather than passing quietly.
    static func acceptedTranscript(for purpose: CryptographicPurpose) -> Data? {
        let raw = purpose.data + plaintext
        if purpose.signingBytes(raw) != nil { return raw }
        let lengthPrefixed = bigEndianCount(purpose.data.count) + purpose.data + plaintext
        if purpose.signingBytes(lengthPrefixed) != nil { return lengthPrefixed }
        return nil
    }

    /// An 8-byte big-endian count, matching what `CanonicalByteWriter.appendUInt64` emits ahead of
    /// every variable-length field.
    static func bigEndianCount(_ count: Int) -> Data {
        var bytes = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: UInt64(count) >> UInt64(shift)))
        }
        return bytes
    }

    /// Signature purposes that actually embed their domain.
    ///
    /// Identified by BEHAVIOUR, not by name: a purpose whose framing is `.absent` accepts empty
    /// bytes, and that is the only observable difference from outside the type. Naming the legacy
    /// ones by spelling would break the day a third legacy purpose is added under a different name.
    static var taggedSignaturePurposes: [Domain] {
        allDomains.filter { $0.name.hasPrefix("Signature.") && $0.purpose.signingBytes(Data()) == nil }
    }

    /// The two `.absent`-framed signature purposes accept untagged bytes — stated as a POSITIVE so
    /// the exclusion above is a documented property rather than a convenience.
    ///
    /// These are read-compatibility paths for transcripts shipped peers already signed, before any
    /// domain existed to embed. Their permissiveness is the reason a NEW write format must never
    /// use one — and the reason the exclusion above is safe rather than a hole.
    @Test func absentFramingAcceptsAnythingByDesign() {
        let absent = Self.allDomains.filter {
            $0.name.hasPrefix("Signature.") && $0.purpose.signingBytes(Data()) != nil
        }
        #expect(
            absent.count == 2,
            """
            Expected exactly the two known `.absent`-framed signature purposes
            (identityEnvelopeLegacyV1, meshAdmissionTokenLegacyV1), found \(absent.count):
            \(absent.map(\.name).sorted().joined(separator: ", ")).
            A purpose that accepts an EMPTY transcript verifies signatures over attacker-chosen
            bytes with no domain at all. If a new one appeared, it had better be a read path for a
            format that shipped before separation — never a write format.
            """
        )
        for domain in absent {
            #expect(
                domain.purpose.signingBytes(Data("bytes from a shipped peer".utf8)) != nil,
                "\(domain.name) is a legacy read path and must keep verifying pre-separation transcripts"
            )
        }
    }

    /// A prefix pair that is nonetheless safe, and the argument for why.
    struct PrefixException: Sendable {
        /// `rawValue` of the shorter purpose.
        let shorter: String
        /// `rawValue` of the longer one it prefixes.
        let longer: String
        /// Why the prefix relation cannot be reached here.
        let reason: String
    }

    /// Every allowlisted prefix pair. Keep this list at one entry if at all possible: the argument
    /// below is about where these two values are CONSUMED, and a consumer added later invalidates
    /// it without touching this file.
    static let prefixExceptions: [PrefixException] = [
        PrefixException(
            shorter: "com.fernlet.sealed-backup",
            longer: "com.fernlet.sealed-backup.v2",
            reason: """
                Both are HKDF `info` inputs and nothing else. Their ONLY call site is                 `IdentityService.deriveSealedBackupKey`, which passes one or the other to                 `HKDF<SHA256>.deriveKey(inputKeyMaterial:salt:info:outputByteCount:)` — never to                 `signingBytes`, and never concatenated with anything. Neither hazard the rule                 guards can reach them: HKDF commits to the info's LENGTH inside its HMAC, so a                 prefix derives an unrelated key (`everyPurposePairDerivesADistinctKey` proves it                 for this pair specifically), and there is no concatenation to make ambiguous.                 Renaming is not the fix and must not be attempted: the v1 spelling is the input to                 every sealed backup written before the v2 format, and changing it makes them                 permanently unreadable.                 THIS ENTRY EXPIRES the moment either value reaches a signature transcript or is                 concatenated into an AAD blob — at which point the prefix becomes exploitable and                 the fix is a new, non-prefixing v3 spelling with a migration.
                """
        ),
    ]

    /// No purpose's bytes are a proper prefix of another's.
    ///
    /// Two shipped constructions make a prefix relation dangerous, and neither is hypothetical in
    /// this codebase:
    ///
    /// * `signingBytes` accepts by `Data.starts(with:)`. A purpose spelled as a prefix of a longer
    ///   one therefore ACCEPTS every transcript tagged for the longer one — full cross-domain
    ///   acceptance in the direction that matters, from nothing worse than a tidy naming scheme.
    /// * Several call sites build authenticated data by CONCATENATION — `ColumnCrypto` writes
    ///   `purpose.data + binding`, `IdentityService` writes `proximityTransportV2.data + peerKey`,
    ///   `SealedBackupService` writes `sealedBackupV2.data + Data([0])`. Concatenation without a
    ///   length prefix is ambiguous exactly when one domain prefixes another: `A ‖ (B_suffix ‖ X)`
    ///   and `B ‖ X` are the same bytes, so two contexts can be made to authenticate one blob.
    ///
    /// Adding `"fernlet.mesh"` beside the existing `"fernlet.mesh.groupkey.v1"` would do it, and
    /// every other test in this file would still pass: the spellings differ, the derived keys
    /// differ, the digests differ. Only the prefix relation is broken, and only this notices.
    @Test func noPurposeIsAPrefixOfAnother() {
        var pairs: [(shorter: Domain, longer: Domain)] = []
        for shorter in Self.allDomains {
            for longer in Self.allDomains
            where longer.purpose.rawValue != shorter.purpose.rawValue
                && longer.purpose.rawValue.hasPrefix(shorter.purpose.rawValue) {
                pairs.append((shorter, longer))
            }
        }

        let offenders = pairs.filter { pair in
            !Self.prefixExceptions.contains {
                $0.shorter == pair.shorter.purpose.rawValue && $0.longer == pair.longer.purpose.rawValue
            }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) purpose spelling(s) are a proper prefix of another. See this test's
            doc comment for the two shipped constructions that makes exploitable. Give the new
            purpose a spelling that prefixes nothing — or, if it genuinely cannot be reached through
            either construction, add a `PrefixException` WITH that argument:
            \(offenders.map { "\($0.shorter.name) (\"\($0.shorter.purpose.rawValue)\") prefixes \($0.longer.name)" }
                .sorted().joined(separator: "\n"))
            """
        )

        let unused = Self.prefixExceptions.filter { entry in
            !pairs.contains { $0.shorter.purpose.rawValue == entry.shorter && $0.longer.purpose.rawValue == entry.longer }
        }
        #expect(
            unused.isEmpty,
            """
            \(unused.count) allowlisted prefix pair(s) match nothing any more — one of the two
            spellings changed. A changed spelling is an at-rest format change: confirm the migration
            exists, then delete the entry.
            \(unused.map { "\($0.shorter) → \($0.longer)" }.sorted().joined(separator: "\n"))
            """
        )
    }
}
