// MeshRoutedDrainAnswerTests.swift
// FernletTests
//
// Network migration P5 item 6 (plan §11, §10.3, §22.1): the drain-answer frame — its pinned golden,
// its shape, its mint and its receive door.
//
// The vector was derived by extending item 5's independent Python re-implementation of the FORMAT
// header (`…/p5/item6/derive_golden_drain_answer.py`) and was proved honest the same way items 1–5's
// were: by first reproducing all NINE shipped vectors byte-for-byte before this one was minted.
//
// A failing golden is a WIRE decision — never re-pin it from Swift's output to go green.
//
// Since the re-pin to ProximityKit 0.1.1 (2026-10-17) the mint and the receive door
// (`MeshRoutedDrainAnswerSigningTests`, `MeshRoutedDrainAnswerVerifierTests`) are ProximityKit's
// package suites of the same names and cells, which its own CI runs; the golden and the shape stay
// here.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
import FernletConnections
@testable import ProximityKit
@testable import Fernlet

// MARK: - Fixtures

/// The golden drain answer: `fp004` telling `fp001` that its delta against `fp001`'s item-5 golden
/// advertisement is empty.
enum MeshRoutedDrainAnswerFixtures {

    static let meshID = MeshRoutedManifestFixtures.meshID
    static let base = MeshRoutedManifestFixtures.base
    static let opaqueSignature = MeshMembershipEventFixtures.opaqueSignature

    /// The peer whose inventory is being answered — item 5's advertiser.
    static let advertiserFingerprint = "fp001"

    /// The answering device — the custody signer of item 5's complete entry.
    static let senderFingerprint = "fp004"

    /// `base + 720` — item 5's golden `sentAt`, copied verbatim, because that is exactly what the
    /// binding check compares against.
    static let advertisedAt = base.addingTimeInterval(720)

    /// `base + 780` — the next free fixture offset.
    static let sentAt = base.addingTimeInterval(780)

    static func answer(quiescent: Bool = true) -> MeshRoutedDrainAnswer {
        MeshRoutedDrainAnswer(
            meshID: meshID, advertiserFingerprint: advertiserFingerprint,
            advertisedAt: advertisedAt, quiescent: quiescent
        )
    }

    static func payload(quiescent: Bool = true) -> MeshRoutedDrainAnswerPayload {
        MeshRoutedDrainAnswerPayload(
            answer: answer(quiescent: quiescent), senderFingerprint: senderFingerprint,
            sentAt: sentAt, signature: opaqueSignature
        )
    }

    static func hex(_ data: Data) -> String { MeshMembershipEventFixtures.hex(data) }
}

// MARK: - Test-only rebuilders

extension MeshRoutedDrainAnswer {
    /// Test-only: a copy with the named fields replaced, through the verbatim memberwise init.
    func replacing(
        meshID: UUID? = nil,
        advertiserFingerprint: String? = nil,
        advertisedAt: Date? = nil,
        quiescent: Bool? = nil
    ) -> MeshRoutedDrainAnswer {
        MeshRoutedDrainAnswer(
            meshID: meshID ?? self.meshID,
            advertiserFingerprint: advertiserFingerprint ?? self.advertiserFingerprint,
            advertisedAt: advertisedAt ?? self.advertisedAt,
            quiescent: quiescent ?? self.quiescent
        )
    }
}

extension MeshRoutedDrainAnswerPayload {
    /// Test-only: a copy with the named fields replaced, through the verbatim memberwise init.
    func replacing(
        answer: MeshRoutedDrainAnswer? = nil,
        senderFingerprint: String? = nil,
        sentAt: Date? = nil,
        signature: Data? = nil
    ) -> MeshRoutedDrainAnswerPayload {
        MeshRoutedDrainAnswerPayload(
            answer: answer ?? self.answer,
            senderFingerprint: senderFingerprint ?? self.senderFingerprint,
            sentAt: sentAt ?? self.sentAt,
            signature: signature ?? self.signature
        )
    }
}

// MARK: - Golden vectors

/// Pinned canonical bytes for the drain answer (P5 item 6), and the collision wall against the two
/// digest families it must never be confused with.
@Suite(.serialized)
struct MeshRoutedDrainAnswerGoldenTests {

    /// 102 bytes. Field order: domain ‖ meshID ‖ advertiser ‖ advertisedAt ‖ quiescent ‖ sender ‖
    /// sentAt. Signature excluded.
    static let goldenRoutedDrainAnswerHex = "00000000000000236665726e6c65742e6d6573682e726f757465642d647261696e2d616e737765722e76311f1f1f1f2e2e4d4d8c8c0b0b0b0b0b0b00000000000000056670303031000000006553f3d00100000000000000056670303034000000006553f40c"

    @Test func theCanonicalTranscriptIsPinned() {
        let actual = MeshRoutedDrainAnswerFixtures.hex(
            canonicalBytes(for: MeshRoutedDrainAnswerFixtures.payload())
        )
        #expect(actual == Self.goldenRoutedDrainAnswerHex, "actual drain answer golden hex = \(actual)")
    }

    @Test func theGoldenIsTheExpectedLength() {
        let actual = canonicalBytes(for: MeshRoutedDrainAnswerFixtures.payload())
        #expect(actual.count == Self.goldenRoutedDrainAnswerHex.count / 2)
        #expect(actual.count == 102)
    }

    /// Every vector below the new one is untouched by item 6 (the P4/P5 idiom).
    @Test func theOlderRoutedGoldensAreUnmoved() {
        let manifest = MeshRoutedDrainAnswerFixtures.hex(canonicalBytes(for: MeshRoutedManifestFixtures.manifest()))
        #expect(manifest == MeshRoutedManifestGoldenTests.goldenRoutedManifestHex,
                "actual routed manifest golden hex = \(manifest)")
        let chunk = MeshRoutedDrainAnswerFixtures.hex(canonicalBytes(for: MeshChunkFixtures.chunk()))
        #expect(chunk == MeshChunkGoldenTests.goldenRoutedChunkHex, "actual routed chunk golden hex = \(chunk)")
        let custody = MeshRoutedDrainAnswerFixtures.hex(canonicalBytes(for: MeshCustodyReceiptFixtures.receipt()))
        #expect(custody == MeshCustodyReceiptGoldenTests.goldenCustodyReceiptHex,
                "actual custody receipt golden hex = \(custody)")
        let recipient = MeshRoutedDrainAnswerFixtures.hex(canonicalBytes(for: MeshRecipientReceiptFixtures.receipt()))
        #expect(recipient == MeshRecipientReceiptGoldenTests.goldenRecipientReceiptHex,
                "actual recipient receipt golden hex = \(recipient)")
        let routed = MeshRoutedDrainAnswerFixtures.hex(canonicalBytes(for: MeshRoutedInventoryFixtures.payload()))
        #expect(routed == MeshRoutedInventoryGoldenTests.goldenRoutedInventoryHex,
                "actual routed inventory golden hex = \(routed)")
        let membership = MeshRoutedDrainAnswerFixtures.hex(
            canonicalBytes(for: MeshMembershipEventFixtures.inventoryPayload())
        )
        #expect(membership == MeshMembershipEventGoldenTests.goldenInventoryHex,
                "actual membership inventory golden hex = \(membership)")
    }

    @Test func aRoundTripPreservesCanonicalBytes() throws {
        let original = MeshRoutedDrainAnswerFixtures.payload()
        let wire = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeshRoutedDrainAnswerPayload.self, from: wire)
        #expect(decoded == original)
        let actual = MeshRoutedDrainAnswerFixtures.hex(canonicalBytes(for: decoded))
        #expect(actual == Self.goldenRoutedDrainAnswerHex, "actual round-tripped golden hex = \(actual)")
    }

    @Test func aPayloadsSignatureIsExcludedFromItsCanonicalBytes() {
        let resigned = MeshRoutedDrainAnswerFixtures.payload()
            .replacing(signature: Data(repeating: 0xCD, count: 64))
        #expect(canonicalBytes(for: resigned)
                == canonicalBytes(for: MeshRoutedDrainAnswerFixtures.payload()))
    }

    /// The quiescence bit is IN the signed bytes — the one field an attacker would flip.
    @Test func theQuiescenceBitIsSigned() {
        let flipped = MeshRoutedDrainAnswerFixtures.payload().replacing(
            answer: MeshRoutedDrainAnswerFixtures.answer(quiescent: false)
        )
        #expect(canonicalBytes(for: flipped)
                != canonicalBytes(for: MeshRoutedDrainAnswerFixtures.payload()))
    }

    /// Token and signing domain are one vocabulary.
    @Test func theTokenVocabularyIsShared() {
        #expect(PayloadType.meshRoutedDrainAnswer.rawValue
                == FernletCryptoPurpose.Signature.meshRoutedDrainAnswerV1.rawValue)
        #expect(PayloadType.meshRoutedDrainAnswer.rawValue == "fernlet.mesh.routed-drain-answer.v1")
    }

    /// The collision wall: three tokens under one family prefix, none a prefix of another, and no
    /// value type carrying another family's stem.
    @Test func theDrainAnswerNamesDoNotCollide() {
        let answer = PayloadType.meshRoutedDrainAnswer.rawValue
        let routed = PayloadType.meshRoutedInventoryDigest.rawValue
        let membership = PayloadType.meshInventoryDigest.rawValue
        #expect(answer != routed)
        #expect(answer != membership)
        #expect(!answer.hasPrefix(routed))
        #expect(!routed.hasPrefix(answer))
        #expect(!answer.hasPrefix(membership))
        #expect(!membership.hasPrefix(answer))
        #expect(!String(describing: MeshRoutedDrainAnswer.self).contains("InventoryDigest"))
        #expect(!String(describing: MeshRoutedDrainAnswerPayload.self).contains("Inventory"))
    }

    /// The two domains reject each other's transcripts, both ways, and their own domain bytes
    /// positionally.
    @Test func theTwoDigestDomainsRejectTheAnswersTranscript() {
        let answerPurpose = FernletCryptoPurpose.Signature.meshRoutedDrainAnswerV1
        let routedPurpose = FernletCryptoPurpose.Signature.meshRoutedInventoryDigestV1
        let membershipPurpose = FernletCryptoPurpose.Signature.meshInventoryDigestV1
        let answer = canonicalBytes(for: MeshRoutedDrainAnswerFixtures.payload())
        let routed = canonicalBytes(for: MeshRoutedInventoryFixtures.payload())
        let membership = canonicalBytes(for: MeshMembershipEventFixtures.inventoryPayload())
        #expect(answerPurpose.signingBytes(answer) != nil)
        #expect(routedPurpose.signingBytes(answer) == nil)
        #expect(answerPurpose.signingBytes(routed) == nil)
        #expect(membershipPurpose.signingBytes(answer) == nil)
        #expect(answerPurpose.signingBytes(membership) == nil)
        #expect(answerPurpose.signingBytes(answerPurpose.data) == nil)
    }
}

// MARK: - Shape

/// The untrusted-bytes half: the four scalars no other door clamps, refused and never repaired.
@Suite(.serialized)
struct MeshRoutedDrainAnswerShapeTests {

    /// A verifier whose ledger knows nobody: the shape step runs before any lookup, so a well-formed
    /// payload reaches `.senderNotAdmitted` and a broken one does not.
    private func door() -> MeshRoutedDrainAnswerVerifier {
        MeshRoutedDrainAnswerVerifier(meshID: MeshRoutedDrainAnswerFixtures.meshID, ledger: .empty)
    }

    @Test func theGoldenFixtureIsWellFormed() {
        #expect(MeshRoutedDrainAnswerFixtures.payload().isWellFormed)
        #expect(door().verify(MeshRoutedDrainAnswerFixtures.payload()) == .senderNotAdmitted)
    }

    @Test func aWrongWidthSignatureIsMalformed() {
        let broken = MeshRoutedDrainAnswerFixtures.payload()
            .replacing(signature: Data(repeating: 0x01, count: 63))
        #expect(broken.isWellFormed == false)
        #expect(door().verify(broken) == .malformed)
    }

    @Test func anEmptyOrOverLongFingerprintIsMalformed() {
        let wide = String(repeating: "f", count: MeshRoutedDrainAnswerFormat.maxFingerprintLength + 1)
        for broken in [
            MeshRoutedDrainAnswerFixtures.payload().replacing(senderFingerprint: ""),
            MeshRoutedDrainAnswerFixtures.payload().replacing(senderFingerprint: wide),
            MeshRoutedDrainAnswerFixtures.payload().replacing(
                answer: MeshRoutedDrainAnswerFixtures.answer().replacing(advertiserFingerprint: "")
            ),
            MeshRoutedDrainAnswerFixtures.payload().replacing(
                answer: MeshRoutedDrainAnswerFixtures.answer().replacing(advertiserFingerprint: wide)
            )
        ] {
            #expect(broken.isWellFormed == false)
            #expect(door().verify(broken) == .malformed)
        }
    }

    /// Both instants are floored at both doors, so the stored value and the canonical bytes agree —
    /// which is what makes the receiver's exact-equality binding check possible at all.
    @Test func bothInstantsAreFlooredToWholeSeconds() throws {
        let ragged = MeshRoutedDrainAnswerPayload(
            answer: MeshRoutedDrainAnswer(
                meshID: MeshRoutedDrainAnswerFixtures.meshID,
                advertiserFingerprint: MeshRoutedDrainAnswerFixtures.advertiserFingerprint,
                advertisedAt: MeshRoutedDrainAnswerFixtures.advertisedAt.addingTimeInterval(0.5),
                quiescent: true
            ),
            senderFingerprint: MeshRoutedDrainAnswerFixtures.senderFingerprint,
            sentAt: MeshRoutedDrainAnswerFixtures.sentAt.addingTimeInterval(0.75),
            signature: MeshRoutedDrainAnswerFixtures.opaqueSignature
        )
        #expect(ragged.sentAt == MeshRoutedDrainAnswerFixtures.sentAt)
        #expect(ragged.answer.advertisedAt == MeshRoutedDrainAnswerFixtures.advertisedAt)
        let actual = MeshRoutedDrainAnswerFixtures.hex(canonicalBytes(for: ragged))
        #expect(actual == MeshRoutedDrainAnswerGoldenTests.goldenRoutedDrainAnswerHex,
                "a ragged instant must floor onto the golden: \(actual)")
    }
}
