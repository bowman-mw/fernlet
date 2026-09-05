// MeshRoutedItemSealTests.swift
// FernletTests
//
// P5 item 13, pass A (plan §11, invariant §3.3): the routed ITEM seal and the routed photo BODY —
// the reserved half of item 1's pair, now written.
//
// Four claims are walled here:
//
// 1. **The authenticated data is pinned, and derived independently.** `goldenItemAADHex` and
//    `goldenItemBlobHex` were computed from the FORMAT by a Python re-implementation
//    (`derive_golden_item.py`) that first reproduced item 1's shipped `goldenWrapAADHex`
//    byte-for-byte. A golden that only records what the code did proves nothing; these were
//    computed apart and then met. The blob vector is an OPEN-side vector, so no test-only nonce
//    injection reaches production.
// 2. **The seal is a transplant proof.** Perturbing any one of the four authenticated fields —
//    mesh, item, origin, type token — refuses the open, which is what lets branch and epoch stop
//    deciding decryptability.
// 3. **One number bounds both ends.** The seal refuses exactly the plaintext the open would refuse,
//    so no recipient can receipt an item it will later decline to open.
// 4. **The body framing is frozen**: a length-prefixed JSON header and the image RAW, never one
//    `Codable` blob, because base64 would inflate every byte bound in the phase by a third. Two
//    vectors pin it — one without a `session` and one with, since a populated `session` is the only
//    part of the routed body whose keys belong to `FernletDomainModel` rather than to this module.
//
// Nothing here sleeps, touches disk, or reads a wall clock for a decision.

import Foundation
@testable import FernletCrypto
import FernletDomainModel
import Testing
@testable import ProximityKit

// MARK: - Fixtures

/// Fixed values for the item-seal vectors. The mesh, item, origin and type token are item 1's own,
/// so the item AAD reads beside the wrap AAD as one story and a reviewer can diff them field by
/// field.
enum MeshRoutedItemSealFixtures {

    /// Item 1's binding: mesh `1F1F…`, item `5A5A…`, origin `fp001`.
    static var binding: MeshRoutedWrapBinding { MeshRoutedManifestFixtures.binding }
    /// Item 1's 42-byte golden type token.
    static let typeToken = MeshRoutedManifestFixtures.typeToken
    /// `00 01 … 1f` — the golden vector's content key, matching the Python derivation's `range(32)`.
    static let contentKey = Data((0..<32).map { UInt8($0) })
    /// A second 32-byte key, so the wrong-key cell reaches the AEAD rather than a width guard.
    static let foreignContentKey = Data(repeating: 0x5C, count: 32)
    /// The golden vector's plaintext.
    static let goldenPlaintext = Data("routed item golden plaintext".utf8)
    /// The photo body fixture's four "image" bytes.
    static let fixtureImage = Data([0xDE, 0xAD, 0xBE, 0xEF])

    /// The golden body header: item 1's item id, `base + 480`, a fixed name, no session.
    static func header() -> MeshRoutedPhotoHeader {
        MeshRoutedPhotoHeader(
            id: MeshRoutedManifestFixtures.itemID,
            addedAt: Date(timeIntervalSince1970: 1_700_000_480),
            senderName: "Fixture Origin",
            session: nil
        )
    }

    /// The golden body.
    static func body() -> MeshRoutedPhotoBody {
        MeshRoutedPhotoBody(header: header(), imageData: fixtureImage)
    }

    /// The SECOND golden body's header: the first one plus a populated ``session``.
    ///
    /// `session` is the one field of the routed body whose encoding this module does not own — it is
    /// `FernletDomainModel`'s `FriendPhotoSessionMetadata`, with a `FriendPhotoSessionParticipant`
    /// inside it. Vector 1 leaves it `nil` (the synthesized encoder omits an absent optional), so
    /// without this fixture a key rename over there would move the routed body's bytes with the whole
    /// suite green. `meshID` and `meshName` are non-nil so all five session keys ride, and the mesh
    /// name carries a `/` so `.withoutEscapingSlashes` is pinned rather than assumed.
    static func sessionHeader() -> MeshRoutedPhotoHeader {
        MeshRoutedPhotoHeader(
            id: MeshRoutedManifestFixtures.itemID,
            addedAt: Date(timeIntervalSince1970: 1_700_000_480),
            senderName: "Fixture Origin",
            session: FriendPhotoSessionMetadata(
                id: UUID(uuidString: "7C7C7C7C-8D8D-4E4E-9F9F-1A1A1A1A1A1A") ?? UUID(),
                meshID: MeshRoutedManifestFixtures.meshID,
                meshName: "Fixture Mesh /1",
                startedAt: Date(timeIntervalSince1970: 1_700_000_400),
                participants: [FriendPhotoSessionParticipant(
                    fingerprint: "fp002", displayName: "Second Friend"
                )]
            )
        )
    }

    /// The second golden body: ``sessionHeader()`` over the same four image bytes.
    static func sessionBody() -> MeshRoutedPhotoBody {
        MeshRoutedPhotoBody(header: sessionHeader(), imageData: fixtureImage)
    }

    static func hex(_ data: Data) -> String {
        MeshRoutedManifestFixtures.hex(data)
    }

    /// Hex → bytes, for the externally derived vectors. Bounded, and a bad pair is skipped rather
    /// than force-unwrapped.
    static func bytes(fromHex hex: String) -> Data {
        let characters = Array(hex)
        var data = Data()
        for pair in stride(from: 0, to: characters.count - 1, by: 2) {
            if let byte = UInt8(String(characters[pair...(pair + 1)]), radix: 16) { data.append(byte) }
        }
        return data
    }
}

/// One authenticated field per case, each changed alone. The three binding fields reuse item 1's
/// perturbation rather than restating it; the fourth is the field the wrap does not carry.
enum MeshRoutedItemAADPerturbation: String, CaseIterable, Sendable {
    case meshID, itemID, originFingerprint, typeToken

    /// The binding this perturbation opens with.
    func appliedBinding(_ binding: MeshRoutedWrapBinding) -> MeshRoutedWrapBinding {
        switch self {
        case .meshID: return MeshRoutedWrapBindingPerturbation.meshID.applied(to: binding)
        case .itemID: return MeshRoutedWrapBindingPerturbation.itemID.applied(to: binding)
        case .originFingerprint:
            return MeshRoutedWrapBindingPerturbation.originFingerprint.applied(to: binding)
        case .typeToken: return binding
        }
    }

    /// The type token this perturbation opens with.
    func appliedToken(_ token: String) -> String {
        self == .typeToken ? MeshRoutedManifestFixtures.altTypeToken : token
    }
}

// MARK: - Seal and open

struct MeshRoutedItemSealTests {

    /// S-4: the round trip is the identity.
    @Test func sealThenOpenReturnsThePlaintext() throws {
        let blob = try MeshRoutedItemSealer.seal(
            MeshRoutedItemSealFixtures.goldenPlaintext,
            contentKey: MeshRoutedItemSealFixtures.contentKey,
            binding: MeshRoutedItemSealFixtures.binding,
            typeToken: MeshRoutedItemSealFixtures.typeToken
        )
        let opened = try MeshRoutedItemSealer.open(
            blob,
            contentKey: MeshRoutedItemSealFixtures.contentKey,
            binding: MeshRoutedItemSealFixtures.binding,
            typeToken: MeshRoutedItemSealFixtures.typeToken
        )
        #expect(opened == MeshRoutedItemSealFixtures.goldenPlaintext)
    }

    /// The blob's shape is exactly the declared layout: 33 bytes of overhead over the plaintext.
    @Test func aSealedBlobIsTheMarkerNonceCiphertextAndTag() throws {
        let blob = try Self.sealedFixtureBlob()
        #expect(blob.count == MeshRoutedItemSealFixtures.goldenPlaintext.count
            + MeshRoutedItemSealFormat.overheadByteCount)
        #expect(blob.starts(with: MeshRoutedItemSealFormat.marker))
    }

    /// S-5: an unmarked blob is refused by name, not swallowed.
    @Test func anUnmarkedBlobIsRefusedByName() throws {
        let blob = try Self.sealedFixtureBlob()
        let unmarked = blob.dropFirst(MeshRoutedItemSealFormat.markerByteCount)
        #expect(throws: MeshRoutedItemSealError.retiredOrForeignFormat) {
            _ = try Self.openFixture(Data(unmarked))
        }
    }

    /// S-6: a flipped marker byte reads as a foreign format, not as a decrypt failure.
    @Test func aFlippedMarkerByteIsRefusedByName() throws {
        var blob = try Self.sealedFixtureBlob()
        blob[blob.startIndex + 4] = UInt8(ascii: "2")
        #expect(throws: MeshRoutedItemSealError.retiredOrForeignFormat) {
            _ = try Self.openFixture(blob)
        }
    }

    /// S-7: a flipped ciphertext byte is refused.
    @Test func aTamperedCiphertextByteIsRefused() throws {
        var blob = try Self.sealedFixtureBlob()
        let target = blob.startIndex + MeshRoutedItemSealFormat.overheadByteCount - 16
        blob[target] ^= 0xFF
        #expect(throws: MeshRoutedItemSealError.openFailed) {
            _ = try Self.openFixture(blob)
        }
    }

    /// S-8: another content key does not open it — the routed twin of the retired `epochKeyIsolation`.
    @Test func aForeignContentKeyIsRefused() throws {
        let blob = try Self.sealedFixtureBlob()
        #expect(throws: MeshRoutedItemSealError.openFailed) {
            _ = try MeshRoutedItemSealer.open(
                blob,
                contentKey: MeshRoutedItemSealFixtures.foreignContentKey,
                binding: MeshRoutedItemSealFixtures.binding,
                typeToken: MeshRoutedItemSealFixtures.typeToken
            )
        }
    }

    /// S-9: the transplant proof — perturbing any authenticated field refuses the open.
    @Test(arguments: MeshRoutedItemAADPerturbation.allCases)
    func perturbingAnyAADFieldRefusesTheOpen(perturbation: MeshRoutedItemAADPerturbation) throws {
        let blob = try Self.sealedFixtureBlob()
        #expect(throws: MeshRoutedItemSealError.openFailed) {
            _ = try MeshRoutedItemSealer.open(
                blob,
                contentKey: MeshRoutedItemSealFixtures.contentKey,
                binding: perturbation.appliedBinding(MeshRoutedItemSealFixtures.binding),
                typeToken: perturbation.appliedToken(MeshRoutedItemSealFixtures.typeToken)
            )
        }
    }

    /// S-10: an empty plaintext is a manifest, not an item.
    @Test func anEmptyPlaintextIsRefused() {
        #expect(throws: MeshRoutedItemSealError.emptyPlaintext) {
            _ = try MeshRoutedItemSealer.seal(
                Data(),
                contentKey: MeshRoutedItemSealFixtures.contentKey,
                binding: MeshRoutedItemSealFixtures.binding,
                typeToken: MeshRoutedItemSealFixtures.typeToken
            )
        }
    }

    /// A content key of the wrong width is refused at the seal, by its own name.
    @Test func aContentKeyOfTheWrongWidthIsRefusedAtTheSeal() {
        #expect(throws: MeshRoutedItemSealError.invalidContentKey) {
            _ = try MeshRoutedItemSealer.seal(
                MeshRoutedItemSealFixtures.goldenPlaintext,
                contentKey: Data(repeating: 0x01, count: 16),
                binding: MeshRoutedItemSealFixtures.binding,
                typeToken: MeshRoutedItemSealFixtures.typeToken
            )
        }
    }

    /// S-11: an over-bound plaintext is refused at the MINT, so no recipient receipts an item it
    /// would then decline to open.
    @Test func aPlaintextAboveTheResidentBoundIsRefusedAtTheSeal() {
        let overBound = MeshRoutedItemSealFormat.maxPlaintextByteCount + 1
        #expect(throws: MeshRoutedItemSealError.plaintextTooLarge(byteCount: overBound)) {
            _ = try MeshRoutedItemSealer.seal(
                Data(repeating: 0x7A, count: overBound),
                contentKey: MeshRoutedItemSealFixtures.contentKey,
                binding: MeshRoutedItemSealFixtures.binding,
                typeToken: MeshRoutedItemSealFixtures.typeToken
            )
        }
    }

    /// S-12: defence in depth for a blob this device did not mint — refused before any plaintext is
    /// allocated.
    @Test func aBlobAboveTheResidentBoundIsRefusedWithoutOpening() {
        let overBound = MeshRoutedItemSealFormat.maxResidentBlobByteCount + 1
        var blob = MeshRoutedItemSealFormat.marker
        blob.append(Data(repeating: 0x00, count: overBound - MeshRoutedItemSealFormat.markerByteCount))
        #expect(throws: MeshRoutedItemSealError.blobTooLargeToOpen(byteCount: overBound)) {
            _ = try Self.openFixture(blob)
        }
    }

    /// S-12b: the seal bound and the open bound are one number.
    @Test func theSealBoundAndTheOpenBoundAreTheSameNumber() {
        #expect(MeshRoutedItemSealFormat.maxPlaintextByteCount
            + MeshRoutedItemSealFormat.overheadByteCount
            == MeshRoutedItemSealFormat.maxResidentBlobByteCount)
    }

    /// A blob with no room for a single ciphertext byte is malformed, not "foreign".
    @Test func aBlobWithNoCiphertextIsMalformed() {
        var blob = MeshRoutedItemSealFormat.marker
        blob.append(Data(repeating: 0x00, count: MeshRoutedItemSealFormat.nonceByteCount
            + MeshRoutedItemSealFormat.tagByteCount))
        #expect(throws: MeshRoutedItemSealError.malformed) {
            _ = try Self.openFixture(blob)
        }
    }

    // MARK: - Body

    /// B-1: encode → decode is the identity.
    @Test func theRoutedPhotoBodyRoundTrips() throws {
        let decoded = try MeshRoutedPhotoBody(decoding: MeshRoutedItemSealFixtures.body().encoded())
        #expect(decoded == MeshRoutedItemSealFixtures.body())
    }

    /// B-2: the sealed plaintext names no epoch — the property that makes branch and epoch stop
    /// deciding decryptability.
    @Test func theRoutedPhotoBodyNamesNoEpoch() throws {
        let body = try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshRoutedItemBody.swift")
        let seal = try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshRoutedItemSeal.swift")
        #expect(!MeshRoutedSourceScan.codeOnly(body).contains("keyEpoch"))
        #expect(!MeshRoutedSourceScan.codeOnly(seal).contains("keyEpoch"))
    }

    /// B-4: an unknown header field is ignored on decode (invariant 8's tolerance half).
    @Test func anUnknownFieldIsIgnoredOnDecode() throws {
        let json = Data("""
            {"addedAt":1700000480,"id":"5A5A5A5A-6B6B-4C4C-8D8D-3E3E3E3E3E3E",\
            "senderName":"Fixture Origin","unknownFieldFromALaterBuild":42}
            """.utf8)
        var writer = CanonicalByteWriter()
        writer.appendLengthPrefixed(json)
        let decoded = try MeshRoutedPhotoBody(
            decoding: writer.bytes + MeshRoutedItemSealFixtures.fixtureImage
        )
        #expect(decoded == MeshRoutedItemSealFixtures.body())
    }

    /// B-6: the JPEG is carried raw — not base64, which would inflate every byte bound by a third.
    @Test func theImageBytesAreCarriedRawNotBase64() throws {
        let framed = try MeshRoutedItemSealFixtures.body().encoded()
        #expect(framed.suffix(MeshRoutedItemSealFixtures.fixtureImage.count)
            == MeshRoutedItemSealFixtures.fixtureImage)
        #expect(framed.count == MeshRoutedItemBodyFormat.headerLengthPrefixByteCount + 96
            + MeshRoutedItemSealFixtures.fixtureImage.count)
    }

    /// B-7: a header length beyond the body is refused, never a truncated slice or a trap.
    @Test func aHeaderLengthBeyondTheBodyIsRefused() {
        var writer = CanonicalByteWriter()
        writer.appendUInt64(UInt64.max)
        let bytes = writer.bytes + Data("{}".utf8)
        #expect(throws: MeshRoutedItemSealError.malformed) {
            _ = try MeshRoutedPhotoBody(decoding: bytes)
        }
    }

    /// A body shorter than its own length prefix is refused at the first guard.
    @Test func aBodyShorterThanItsLengthPrefixIsRefused() {
        #expect(throws: MeshRoutedItemSealError.malformed) {
            _ = try MeshRoutedPhotoBody(decoding: Data([0x00, 0x01, 0x02]))
        }
    }

    /// The third hostile framing shape: an IN-BOUNDS length prefix over bytes that are not the
    /// header's JSON. It lands on the family's own `malformed`, not on a raw `DecodingError` — one
    /// frozen vocabulary covers the whole framing, so pass B and P6's bodies have one audit line.
    @Test func anInBoundsHeaderSliceThatIsNotJSONIsMalformed() {
        var writer = CanonicalByteWriter()
        writer.appendLengthPrefixed(Data("not json at all".utf8))
        #expect(throws: MeshRoutedItemSealError.malformed) {
            _ = try MeshRoutedPhotoBody(decoding: writer.bytes + MeshRoutedItemSealFixtures.fixtureImage)
        }
    }

    /// The same token covers valid JSON that is missing a required key — an older or hostile origin
    /// omitting `senderName` is a framing refusal, not an untyped decode error.
    @Test func aHeaderMissingARequiredKeyIsMalformed() {
        var writer = CanonicalByteWriter()
        writer.appendLengthPrefixed(Data("{\"addedAt\":1700000480}".utf8))
        #expect(throws: MeshRoutedItemSealError.malformed) {
            _ = try MeshRoutedPhotoBody(decoding: writer.bytes + MeshRoutedItemSealFixtures.fixtureImage)
        }
    }

    // MARK: - Helpers

    private static func sealedFixtureBlob() throws -> Data {
        try MeshRoutedItemSealer.seal(
            MeshRoutedItemSealFixtures.goldenPlaintext,
            contentKey: MeshRoutedItemSealFixtures.contentKey,
            binding: MeshRoutedItemSealFixtures.binding,
            typeToken: MeshRoutedItemSealFixtures.typeToken
        )
    }

    private static func openFixture(_ blob: Data) throws -> Data {
        try MeshRoutedItemSealer.open(
            blob,
            contentKey: MeshRoutedItemSealFixtures.contentKey,
            binding: MeshRoutedItemSealFixtures.binding,
            typeToken: MeshRoutedItemSealFixtures.typeToken
        )
    }
}

// MARK: - Golden vectors

/// The item seal's and routed body's pinned wire vectors.
///
/// Every hex below was derived from the FORMAT — by the Python scripts in the item's scratch
/// directory, which first reproduced item 1's shipped `goldenWrapAADHex` byte for byte — never read
/// back out of Swift. `goldenItemAADHex` pins the authenticated data, `goldenItemBlobHex` an
/// OPEN-side blob sealed outside this tree, `goldenItemBlobContentHashHex` C12's claim that the hash
/// measures the complete blob, and the two body vectors the frozen `u64BE(len) ‖ headerJSON ‖ image`
/// framing — the second one with a populated `session`, so `FernletDomainModel`'s own keys are
/// pinned here too.
///
/// A failing golden is a WIRE decision — never re-pin it from Swift's output to go green. The
/// failure message prints the actual hex precisely so the change can be *read*; re-derive the vector
/// from the format instead, and if the format really moved, say so in the commit.
@Suite(.serialized)
struct MeshRoutedItemSealGoldenTests {

    /// The item seal's authenticated data, 127 bytes:
    /// `AEAD.meshRoutedItemV1.data ‖ meshID ‖ itemID ‖ lp("fp001") ‖ lp(typeToken)`.
    /// Derived from the FORMAT in Python, by a script that first reproduced item 1's shipped
    /// `goldenWrapAADHex` byte-for-byte.
    static let goldenItemAADHex = "6665726e6c65742e6d6573682e726f757465642e6974656d2e616561642e76311f1f1f1f2e2e4d4d8c8c0b0b0b0b0b0b5a5a5a5a6b6b4c4c8d8d3e3e3e3e3e3e00000000000000056670303031000000000000002a6665726e6c65742e6d6573682e726f757465642d747970652e676f6c64656e2d666978747572652e7631"

    /// An OPEN-side blob vector: fixed key `00…1f`, fixed nonce `0c×12`, the fixture plaintext, and
    /// the AAD above — sealed OUTSIDE this tree so production `open` is what the cell exercises. No
    /// nonce injection reaches the sealer, which mints its own.
    static let goldenItemBlobHex = "464d5249310c0c0c0c0c0c0c0c0c0c0c0c86dc6e8d3b7d4a06b7925d6bb1ede85acbc9a39fcc046857478a787667f6c96f035222e43d92488598e783a3"

    /// `MeshRoutedContentDigest.contentHash(of:)` over the blob above — C12's statement that the
    /// hash measures the COMPLETE sealed blob, marker included.
    static let goldenItemBlobContentHashHex = "4230a963cca76b4644d282984b21800b438f3e0db42528f541d8b061deecf2b0"

    /// The routed photo body's frozen framing: `u64BE(96) ‖ headerJSON ‖ DEADBEEF`, 108 bytes.
    static let goldenBodyHex = "00000000000000607b2261646465644174223a313730303030303438302c226964223a2235413541354135412d364236422d344334432d384438442d334533453345334533453345222c2273656e6465724e616d65223a2246697874757265204f726967696e227ddeadbeef"

    /// The routed photo body with a populated `session`: `u64BE(323) ‖ headerJSON ‖ DEADBEEF`,
    /// 335 bytes. The half of the frozen body this module does not own.
    static let goldenSessionBodyHex = "00000000000001437b2261646465644174223a313730303030303438302c226964223a2235413541354135412d364236422d344334432d384438442d334533453345334533453345222c2273656e6465724e616d65223a2246697874757265204f726967696e222c2273657373696f6e223a7b226964223a2237433743374337432d384438442d344534452d394639462d314131413141314131413141222c226d6573684944223a2231463146314631462d324532452d344434442d384338432d304230423042304230423042222c226d6573684e616d65223a2246697874757265204d657368202f31222c227061727469636970616e7473223a5b7b22646973706c61794e616d65223a225365636f6e6420467269656e64222c2266696e6765727072696e74223a226670303032227d5d2c22737461727465644174223a313730303030303430307d7ddeadbeef"

    /// S-1.
    @Test func theItemAADIsGoldenStable() {
        let actual = MeshRoutedItemSealFixtures.hex(MeshRoutedItemSealer.additionalData(
            binding: MeshRoutedItemSealFixtures.binding,
            typeToken: MeshRoutedItemSealFixtures.typeToken
        ))
        #expect(actual == Self.goldenItemAADHex, "actual item AAD golden hex = \(actual)")
        #expect(actual.count == 127 * 2)
    }

    /// S-2: the structural companion — the same bytes rebuilt with the writer in the test, with the
    /// type token in the slot the wrap gives its recipient.
    @Test func theItemAADIsBuiltFromItsFourFields() {
        var writer = CanonicalByteWriter()
        writer.appendUUID(MeshRoutedManifestFixtures.meshID)
        writer.appendUUID(MeshRoutedManifestFixtures.itemID)
        writer.appendString(MeshRoutedManifestFixtures.originFingerprint)
        writer.appendString(MeshRoutedItemSealFixtures.typeToken)
        let expected = FernletCryptoPurpose.AEAD.meshRoutedItemV1.data + writer.bytes
        let actual = MeshRoutedItemSealer.additionalData(
            binding: MeshRoutedItemSealFixtures.binding,
            typeToken: MeshRoutedItemSealFixtures.typeToken
        )
        #expect(actual == expected)
    }

    /// S-3: production `open` accepts the externally derived vector.
    @Test func aFixedVectorOpensToItsPlaintext() throws {
        let blob = MeshRoutedItemSealFixtures.bytes(fromHex: Self.goldenItemBlobHex)
        #expect(blob.count == 61)
        let opened = try MeshRoutedItemSealer.open(
            blob,
            contentKey: MeshRoutedItemSealFixtures.contentKey,
            binding: MeshRoutedItemSealFixtures.binding,
            typeToken: MeshRoutedItemSealFixtures.typeToken
        )
        #expect(opened == MeshRoutedItemSealFixtures.goldenPlaintext)
    }

    /// S-13: the content hash measures the complete sealed blob (C12).
    @Test func theSealedBlobIsWhatTheContentHashMeasures() {
        let blob = MeshRoutedItemSealFixtures.bytes(fromHex: Self.goldenItemBlobHex)
        let actual = MeshRoutedItemSealFixtures.hex(MeshRoutedContentDigest.contentHash(of: blob))
        #expect(actual == Self.goldenItemBlobContentHashHex, "actual blob content hash = \(actual)")
    }

    /// S-14: the vectors below the new one are untouched (the P4 idiom, carried through P5).
    @Test func theWrapAndManifestGoldensAreUnmoved() {
        let wrapAAD = MeshRoutedItemSealFixtures.hex(MeshRoutedContentKeyWrapper.additionalData(
            binding: MeshRoutedManifestFixtures.binding, recipientFingerprint: "fp002"
        ))
        #expect(wrapAAD == MeshRoutedManifestGoldenTests.goldenWrapAADHex, "actual wrap AAD hex = \(wrapAAD)")
        let manifest = MeshRoutedItemSealFixtures.hex(canonicalBytes(for: MeshRoutedManifestFixtures.manifest()))
        #expect(manifest == MeshRoutedManifestGoldenTests.goldenRoutedManifestHex,
                "actual manifest golden hex = \(manifest)")
    }

    /// B-5: the body framing is a frozen contract, pinned by a hex derived from the format.
    @Test func theBodyFramingIsGoldenStable() throws {
        let actual = MeshRoutedItemSealFixtures.hex(try MeshRoutedItemSealFixtures.body().encoded())
        #expect(actual == Self.goldenBodyHex, "actual routed body golden hex = \(actual)")
        #expect(actual.count == 108 * 2)
    }

    /// B-8: the routed body's `session` is pinned too — five `FriendPhotoSessionMetadata` keys, two
    /// `FriendPhotoSessionParticipant` keys, `startedAt` under `.secondsSince1970`, and a `/` that
    /// stays unescaped. Those bytes are `FernletDomainModel`'s, and mesh peers run different builds:
    /// without this vector a rename over there moves the routed wire with the suite green.
    @Test func theBodyFramingIsGoldenStableWithASession() throws {
        let actual = MeshRoutedItemSealFixtures.hex(try MeshRoutedItemSealFixtures.sessionBody().encoded())
        #expect(actual == Self.goldenSessionBodyHex, "actual routed session body golden hex = \(actual)")
        #expect(actual.count == 335 * 2)
    }

    /// B-9: and it decodes back — the frozen framing is an identity over the session half as well.
    @Test func theSessionBodyRoundTripsFromItsGoldenBytes() throws {
        let decoded = try MeshRoutedPhotoBody(
            decoding: MeshRoutedItemSealFixtures.bytes(fromHex: Self.goldenSessionBodyHex)
        )
        #expect(decoded == MeshRoutedItemSealFixtures.sessionBody())
    }

    /// T-F1: the item seal owes NO framing case and NO new domain row — an AEAD purpose never
    /// reaches `signingBytes(_:)`, and the registry row has existed since item 1. Asserted as a
    /// non-change, in both directions, so "we forgot the trio" and "we grew the registry" are both
    /// failures rather than silences.
    @Test func theItemSealAddsNoSignatureFramingAndNoDomainRow() throws {
        #expect(CryptographicDomainSeparationTests.allDomains.count == 74)
        let rows = CryptographicDomainSeparationTests.allDomains.filter {
            $0.purpose.rawValue == FernletCryptoPurpose.AEAD.meshRoutedItemV1.rawValue
        }
        #expect(rows.count == 1)
        let framingWall = try RepoRoot.source("Tests/FernletTests/CryptographicPurposeBoundaryTests.swift")
        #expect(!framingWall.contains("meshRoutedItemV1"))
    }
}
