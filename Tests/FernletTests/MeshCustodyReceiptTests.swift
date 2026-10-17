// MeshCustodyReceiptTests.swift
// FernletTests
//
// P5 item 3 (plan §11, §3.6): the CUSTODY RECEIPT — the third routed wire family, and the one
// record whose subject did not sign it.
//
// Four claims are walled here, each one a thing a later item cannot cheaply re-derive:
//
// 1. **The signed bytes are pinned.** `goldenCustodyReceiptHex` and `goldenCustodyReceiptIDHex` were
//    derived from the FORMAT by an independent Python re-implementation that first reproduced the
//    shipped `goldenInventoryHex`, `goldenEpochHeadsHex`, `goldenRoutedManifestHex` AND
//    `goldenRoutedChunkHex` byte-for-byte. A golden that only records what the code did proves
//    nothing; these were computed independently and then met. The frame is additive: nothing above
//    it moves, and both routed goldens are re-asserted here untouched.
// 2. **Durable before acknowledged is a TYPE rule.** The mint takes a
//    `MeshCustodyDurabilityWitness`, whose initializer is `fileprivate` to the file holding
//    `committingCustody` — so there is no argument list that produces a receipt for bytes no durable
//    write returned. Every receipt in this file comes out of a real store commit.
// 3. **The custodian signs, about the origin's item.** Two fingerprints in two fixed positions: the
//    signing key is resolved by the CUSTODIAN from the admission ledger, a departed custodian's
//    receipt still verifies, a quorum-removed one's does not, and a receipt lifted onto another
//    origin's item fails.
// 4. **The derived id is stable across a re-mint.** CryptoKit's Ed25519 signing is hedged, so two
//    mints of one logical receipt differ in the signature; `receiptID` excludes it — and excludes
//    `custodiedAt` too, because a re-mint of the same claim is the same claim.
//
// Since the re-pin to ProximityKit 0.1.1 (2026-10-17) the mint and the door
// (`MeshCustodyReceiptSigningTests`, `MeshCustodyReceiptVerifierTests`), which held claims 2 and 3 over
// real store commits, are ProximityKit's package suites of the same names and cells, which its own CI
// runs; the goldens and the id's stability stay here.
//
// Nothing here sleeps or reads a wall clock for a decision.

import CryptoKit
import Foundation
@testable import FernletCrypto
import FernletConnections
import FernletDomainModel
import FernletFoundation
import Testing
@testable import ProximityKit

// MARK: - Fixtures

/// Fixed values for the receipt golden vectors — every pinned byte traces to a line here; nothing
/// reads a clock. `meshID`, `itemID`, `contentHash`, `expiresAt` and `opaqueSignature` are item 1's
/// own, so the receipt vector reads beside the manifest and chunk vectors as one story.
enum MeshCustodyReceiptFixtures {

    static let meshID = MeshRoutedManifestFixtures.meshID
    static let itemID = MeshRoutedManifestFixtures.itemID
    static let base = MeshRoutedManifestFixtures.base
    /// The item's author — the SUBJECT of the receipt.
    static let originFingerprint = MeshRoutedManifestFixtures.originFingerprint
    static let contentHash = MeshRoutedManifestFixtures.contentHash
    static let expiresAt = MeshRoutedManifestFixtures.expiresAt
    static let hardDeadline = MeshRoutedManifestFixtures.hardDeadline
    static let opaqueSignature = MeshMembershipEventFixtures.opaqueSignature

    /// Deliberately **neither the origin nor a destination** (`fp002`/`fp003` are the manifest's), so
    /// the golden itself says a custodian need not be a recipient of the item it is holding.
    static let custodianFingerprint = "fp004"

    /// `base + 540` — the offset item 2's design reserved for item 3 (taken: +60 … +480).
    static let custodiedAt = base.addingTimeInterval(540)

    /// The golden receipt, built from already-"signed" parts through the memberwise init.
    static func receipt() -> MeshCustodyReceipt {
        MeshCustodyReceipt(
            meshID: meshID,
            itemID: itemID,
            originFingerprint: originFingerprint,
            contentHash: contentHash,
            custodianFingerprint: custodianFingerprint,
            custodiedAt: custodiedAt,
            expiresAt: expiresAt,
            signature: opaqueSignature
        )
    }

    static func hex(_ data: Data) -> String {
        MeshMembershipEventFixtures.hex(data)
    }

    /// A `UUID`'s 16 network-order bytes, through the same writer the derivation uses.
    static func bytes(of uuid: UUID) -> Data {
        var writer = CanonicalByteWriter()
        writer.appendUUID(uuid)
        return writer.bytes
    }
}

// MARK: - Test-only rebuilders

extension MeshCustodyReceipt {
    /// Test-only: a copy with the named fields replaced, through the flooring memberwise init.
    func replacing(
        meshID: UUID? = nil,
        itemID: UUID? = nil,
        originFingerprint: String? = nil,
        contentHash: Data? = nil,
        custodianFingerprint: String? = nil,
        custodiedAt: Date? = nil,
        expiresAt: Date? = nil,
        signature: Data? = nil
    ) -> MeshCustodyReceipt {
        MeshCustodyReceipt(
            meshID: meshID ?? self.meshID,
            itemID: itemID ?? self.itemID,
            originFingerprint: originFingerprint ?? self.originFingerprint,
            contentHash: contentHash ?? self.contentHash,
            custodianFingerprint: custodianFingerprint ?? self.custodianFingerprint,
            custodiedAt: custodiedAt ?? self.custodiedAt,
            expiresAt: expiresAt ?? self.expiresAt,
            signature: signature ?? self.signature
        )
    }
}

/// One wrong width per case — each a refusal, never a repair.
enum MeshCustodyReceiptShapeFault: String, CaseIterable, Sendable {
    case signature63, signature65, contentHash31, contentHash33
    case emptyOrigin, origin65, emptyCustodian, custodian65, custodyAtExpiry, custodyPastExpiry

    /// The golden fixture with this one fault applied through the memberwise init.
    func applied(to base: MeshCustodyReceipt) -> MeshCustodyReceipt {
        switch self {
        case .signature63: return base.replacing(signature: Data(repeating: 0xAB, count: 63))
        case .signature65: return base.replacing(signature: Data(repeating: 0xAB, count: 65))
        case .contentHash31: return base.replacing(contentHash: Data(repeating: 0x02, count: 31))
        case .contentHash33: return base.replacing(contentHash: Data(repeating: 0x02, count: 33))
        case .emptyOrigin: return base.replacing(originFingerprint: "")
        case .origin65: return base.replacing(originFingerprint: String(repeating: "f", count: 65))
        case .emptyCustodian: return base.replacing(custodianFingerprint: "")
        case .custodian65: return base.replacing(custodianFingerprint: String(repeating: "c", count: 65))
        case .custodyAtExpiry: return base.replacing(custodiedAt: base.expiresAt)
        case .custodyPastExpiry: return base.replacing(custodiedAt: base.expiresAt.addingTimeInterval(1))
        }
    }
}

// MARK: - Golden vectors

/// Pinned canonical bytes and the derived id for the custody receipt (P5 item 3).
///
/// Both vectors were derived by an independent Python re-implementation of the FORMAT header in
/// `CanonicalSignatureSerializer.swift` — length-prefixed domain, 16 raw UUID bytes, length-prefixed
/// UTF-8 strings, length-prefixed `Data` for the hash, two i64 floored-seconds dates, signature
/// excluded — and proved honest the same way items 1 and 2's were: by first reproducing
/// ``MeshMembershipEventGoldenTests/goldenInventoryHex``,
/// ``MeshMembershipEventGoldenTests/goldenEpochHeadsHex``,
/// ``MeshRoutedManifestGoldenTests/goldenRoutedManifestHex`` and
/// ``MeshChunkGoldenTests/goldenRoutedChunkHex`` byte-for-byte before either of these was minted.
///
/// The frame is **additive**: its own token, its own signature domain, its own hash domain, its own
/// goldens and framing case, and no vector above it moves — both routed goldens are re-asserted here
/// untouched. A failing golden is a WIRE decision — never re-pin it from Swift's output to go green.
/// Each failure message reprints the actual hex so a deliberate bump can be re-pinned by copy-paste.
@Suite(.serialized)
struct MeshCustodyReceiptGoldenTests {

    /// 153 bytes. Field order: domain ‖ meshID ‖ itemID ‖ origin ‖ lp(contentHash) ‖ custodian ‖
    /// custodiedAt ‖ expiresAt. Signature excluded.
    static let goldenCustodyReceiptHex = "000000000000001f6665726e6c65742e6d6573682e637573746f64792d726563656970742e76311f1f1f1f2e2e4d4d8c8c0b0b0b0b0b0b5a5a5a5a6b6b4c4c8d8d3e3e3e3e3e3e000000000000000566703030310000000000000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f00000000000000056670303034000000006553f31c0000000065544a10"

    /// The derived dedup id for `(itemID, "fp001", "fp004")`: the first 16 bytes of
    /// `SHA-256(lp("fernlet.mesh.custody-receipt-id.hash.v1") ‖ uuid(itemID) ‖ lp(origin) ‖
    /// lp(custodian))`. Item 12 depends on this derivation, so it is pinned before anything keys on it.
    static let goldenCustodyReceiptIDHex = "d734679daafd27097f2a6392a60d3669"

    @Test func theFixtureIDsAreTheLiteralsNotFallbacks() {
        #expect(MeshCustodyReceiptFixtures.itemID.uuidString == "5A5A5A5A-6B6B-4C4C-8D8D-3E3E3E3E3E3E")
        #expect(MeshCustodyReceiptFixtures.meshID.uuidString == "1F1F1F1F-2E2E-4D4D-8C8C-0B0B0B0B0B0B")
    }

    @Test func aCustodyReceiptIsGoldenStable() {
        let actual = MeshCustodyReceiptFixtures.hex(canonicalBytes(for: MeshCustodyReceiptFixtures.receipt()))
        #expect(actual == Self.goldenCustodyReceiptHex, "actual custody receipt golden hex = \(actual)")
    }

    @Test func theCustodyReceiptGoldenIsTheExpectedLength() {
        let actual = canonicalBytes(for: MeshCustodyReceiptFixtures.receipt())
        #expect(actual.count == Self.goldenCustodyReceiptHex.count / 2)
        #expect(actual.count == 153)
    }

    @Test func theReceiptIDIsGoldenStable() {
        let actual = MeshCustodyReceiptFixtures.hex(
            MeshCustodyReceiptFixtures.bytes(of: MeshCustodyReceiptFixtures.receipt().receiptID)
        )
        #expect(actual == Self.goldenCustodyReceiptIDHex, "actual receipt id golden hex = \(actual)")
    }

    /// The property a FRAME owes that a record's own golden cannot prove: the signed bytes survive
    /// the wire, signature included — the courier rule as bytes.
    @Test func aReceiptPreservesTheSignedBytesAcrossTheWire() throws {
        let original = MeshCustodyReceiptFixtures.receipt()
        let wire = try JSONEncoder().encode(MeshCustodyReceiptPayload(receipt: original))
        let forwarded = try JSONDecoder().decode(MeshCustodyReceiptPayload.self, from: wire).receipt
        #expect(forwarded == original)
        #expect(forwarded.signature == original.signature)
        let actual = MeshCustodyReceiptFixtures.hex(canonicalBytes(for: forwarded))
        #expect(actual == Self.goldenCustodyReceiptHex, "actual round-tripped golden hex = \(actual)")
    }

    @Test func aReceiptsSignatureIsExcludedFromItsCanonicalBytes() {
        let resigned = MeshCustodyReceiptFixtures.receipt().replacing(signature: Data(repeating: 0xCD, count: 64))
        #expect(canonicalBytes(for: resigned) == canonicalBytes(for: MeshCustodyReceiptFixtures.receipt()))
    }

    /// The id excludes the signature AND the custody instant: a re-mint of the same claim is the
    /// same claim, and the replay window should treat it as one.
    @Test func theReceiptIDIsDeterministicAndFieldSensitive() {
        let receipt = MeshCustodyReceiptFixtures.receipt()
        #expect(receipt.receiptID == MeshCustodyReceiptFixtures.receipt().receiptID)
        #expect(receipt.replacing(signature: Data(repeating: 0x01, count: 64)).receiptID == receipt.receiptID)
        #expect(receipt.replacing(custodiedAt: receipt.custodiedAt.addingTimeInterval(-30)).receiptID
                == receipt.receiptID)
        #expect(receipt.replacing(itemID: UUID()).receiptID != receipt.receiptID)
        #expect(receipt.replacing(originFingerprint: "fp009").receiptID != receipt.receiptID)
        #expect(receipt.replacing(custodianFingerprint: "fp009").receiptID != receipt.receiptID)
    }

    /// Token, record and signing domain are one vocabulary.
    @Test func theTokenVocabularyIsShared() {
        #expect(PayloadType.meshCustodyReceipt.rawValue == FernletCryptoPurpose.Signature.meshCustodyReceiptV1.rawValue)
        #expect(PayloadType.meshCustodyReceipt.rawValue == "fernlet.mesh.custody-receipt.v1")
    }

    /// Both vectors below the new one are untouched by item 3 (the P4/P5 idiom).
    @Test func theRoutedGoldensAreUntouchedByItem3() {
        let manifest = MeshCustodyReceiptFixtures.hex(canonicalBytes(for: MeshRoutedManifestFixtures.manifest()))
        #expect(manifest == MeshRoutedManifestGoldenTests.goldenRoutedManifestHex,
                "actual routed manifest golden hex = \(manifest)")
        let chunk = MeshCustodyReceiptFixtures.hex(canonicalBytes(for: MeshChunkFixtures.chunk()))
        #expect(chunk == MeshChunkGoldenTests.goldenRoutedChunkHex, "actual routed chunk golden hex = \(chunk)")
        let inventory = MeshCustodyReceiptFixtures.hex(
            canonicalBytes(for: MeshMembershipEventFixtures.inventoryPayload())
        )
        #expect(inventory == MeshMembershipEventGoldenTests.goldenInventoryHex,
                "actual inventory golden hex = \(inventory)")
    }

    @Test(arguments: MeshCustodyReceiptShapeFault.allCases)
    func everyShapeFaultIsRefused(fault: MeshCustodyReceiptShapeFault) {
        #expect(MeshCustodyReceiptFixtures.receipt().isWellFormed)
        #expect(fault.applied(to: MeshCustodyReceiptFixtures.receipt()).isWellFormed == false, "\(fault)")
    }

    /// Both doors floor the instants to the signed whole seconds, so a relay's re-encoding cannot
    /// produce a receipt `!=` the custodian's that still verifies.
    @Test func bothDoorsFloorTheInstantsToTheSignedWholeSeconds() throws {
        let signed = MeshCustodyReceiptFixtures.receipt()
        let fractional = signed.replacing(
            custodiedAt: signed.custodiedAt.addingTimeInterval(0.999),
            expiresAt: signed.expiresAt.addingTimeInterval(0.999)
        )
        #expect(fractional == signed)
        let wire = try JSONEncoder().encode(UnclampedReceiptWire(signed))
        let decoded = try JSONDecoder().decode(MeshCustodyReceipt.self, from: wire)
        #expect(decoded == signed)
        #expect(canonicalBytes(for: decoded) == canonicalBytes(for: signed))
    }

    @Test func aReceiptIsStillLiveAtExactlyItsExpiryAndNotOneSecondLater() {
        let receipt = MeshCustodyReceiptFixtures.receipt()
        #expect(receipt.isLive(at: MeshCustodyReceiptFixtures.expiresAt))
        #expect(receipt.isLive(at: MeshCustodyReceiptFixtures.expiresAt.addingTimeInterval(1)) == false)
    }

    /// The eight fields, and nothing receiver-local, epoch-shaped or relay-shaped.
    @Test func aReceiptCarriesNoEpochNoHopCountAndNoDestinationSet() {
        let labels = Mirror(reflecting: MeshCustodyReceiptFixtures.receipt()).children.compactMap(\.label)
        #expect(labels == [
            "meshID", "itemID", "originFingerprint", "contentHash", "custodianFingerprint",
            "custodiedAt", "expiresAt", "signature"
        ])
        for label in labels.map({ $0.lowercased() }) {
            #expect(label.contains("epoch") == false)
            #expect(label.contains("branch") == false)
            #expect(label.contains("hop") == false)
            #expect(label.contains("ttl") == false)
            #expect(label.contains("destination") == false)
            #expect(label.contains("schema") == false)
        }
    }

    /// The replay window admits one receipt id once, then answers `replayed`. A smoke test — the
    /// wiring itself is item 12's, and its window sizing is still an open question there.
    @Test func aReceiptIsAdmittedOnceByTheReplayWindow() {
        let receipt = MeshCustodyReceiptFixtures.receipt()
        var window = MeshFrameReplayWindow(meshID: receipt.meshID)
        let first = window.admit(
            frameID: receipt.receiptID, from: receipt.custodianFingerprint,
            meshID: receipt.meshID, expiresAt: receipt.expiresAt,
            now: MeshCustodyReceiptFixtures.base
        )
        let second = window.admit(
            frameID: receipt.receiptID, from: receipt.custodianFingerprint,
            meshID: receipt.meshID, expiresAt: receipt.expiresAt,
            now: MeshCustodyReceiptFixtures.base
        )
        #expect(first == .admitted)
        #expect(second == .replayed)
    }
}

/// A receipt's JSON with NO floor on either instant — what a re-encoded frame from a peer looks like
/// on the wire. Same coding keys and encoder strategy as the real type, so decoding it as a
/// ``MeshCustodyReceipt`` exercises `init(from:)` exactly.
private struct UnclampedReceiptWire: Encodable {
    let meshID: UUID
    let itemID: UUID
    let originFingerprint: String
    let contentHash: Data
    let custodianFingerprint: String
    let custodiedAt: Date
    let expiresAt: Date
    let signature: Data

    /// `receipt`, with both instants pushed a fraction of a second past the signed value.
    init(_ receipt: MeshCustodyReceipt) {
        meshID = receipt.meshID
        itemID = receipt.itemID
        originFingerprint = receipt.originFingerprint
        contentHash = receipt.contentHash
        custodianFingerprint = receipt.custodianFingerprint
        custodiedAt = receipt.custodiedAt.addingTimeInterval(0.999)
        expiresAt = receipt.expiresAt.addingTimeInterval(0.999)
        signature = receipt.signature
    }
}
