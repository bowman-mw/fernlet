// MeshRoutedInventoryTests.swift
// FernletTests
//
// P5 item 5 (plan §11, §10.3): the ROUTED CONTENT digest — the fifth routed wire family, and the
// one that says what a device is holding rather than what it received.
//
// Four claims are walled here, each a thing a later item cannot cheaply re-derive:
//
// 1. **The signed bytes are pinned.** `goldenRoutedInventoryHex` was derived from the FORMAT by an
//    independent Python re-implementation that first reproduced ALL EIGHT prior vectors —
//    `goldenInventoryHex`, `goldenEpochHeadsHex`, `goldenRoutedManifestHex`, `goldenRoutedChunkHex`,
//    `goldenCustodyReceiptHex`, `goldenCustodyReceiptIDHex`, `goldenRecipientReceiptHex` and
//    `goldenRecipientReceiptIDHex` — byte-for-byte. The frame is additive: nothing above it moves.
// 2. **The two digest families do not collide.** `MeshInventoryDigest` summarises a MEMBERSHIP
//    ledger; this summarises a routed STORE. The wire spellings deliberately share the
//    `inventory-digest` stem, so `grep` is NOT decisive — what is decisive is the value-type stems,
//    asserted clause by clause below.
// 3. **An over-cap or non-canonical digest is REFUSED BY NAME, never repaired.** Clamping a count
//    loses precision; clamping a *list* silently claims not to hold something, and repairing an
//    order would make the refusal unreachable and set equality meaningless.
// 4. **The advertiser signs, and D14 holds.** A departed advertiser's digest still verifies (it may
//    still hold custody inside the development grace); a quorum-removed one does not.
//
// Since the re-pin to ProximityKit 0.1.1 (2026-10-17) the mint and the door
// (`MeshRoutedInventorySigningTests`, `MeshRoutedInventoryVerifierTests`), which held claim 4, are
// ProximityKit's package suites of the same names and cells, which its own CI runs; the golden, the
// collision wall and the shape and cap refusals stay here.
//
// Nothing here sleeps or reads a wall clock for a decision.

import Foundation
@testable import FernletCrypto
import FernletDomainModel
import FernletConnections
import FernletFoundation
import Testing
@testable import ProximityKit

// MARK: - Fixtures

/// Fixed values for the routed-inventory golden vector — every pinned byte traces to a line here;
/// nothing reads a clock. `meshID` and the first `itemID` are item 1's own, so the vector reads
/// beside the manifest, chunk and receipt vectors as one story.
enum MeshRoutedInventoryFixtures {

    static let meshID = MeshRoutedManifestFixtures.meshID
    static let base = MeshRoutedManifestFixtures.base
    static let opaqueSignature = MeshMembershipEventFixtures.opaqueSignature

    /// The item the manifest, chunk and both receipt vectors are about — held complete here.
    static let itemID = MeshRoutedManifestFixtures.itemID

    /// A second item, held PARKED (chunks, no manifest) so the vector carries both shapes.
    static let parkedItemID = UUID(uuidString: "6B6B6B6B-7C7C-4E4E-9F9F-4A4A4A4A4A4A") ?? UUID()

    /// The ADVERTISER — the device whose disk the digest describes.
    static let senderFingerprint = "fp001"

    /// `base + 720` — the next free fixture offset (+60 … +660 are taken by items 1–4, +600 by
    /// `MeshRoutedStoreFixtures.now`).
    static let sentAt = base.addingTimeInterval(720)

    /// The minimal fingerprint table: the first item's origin and the second's, the latter also
    /// being the first item's custody signer.
    static let members = ["fp001", "fp004"]

    /// The complete, manifest-bound item: 3 chunks, all held (`0b0000_0111`), one custody signer.
    static func completeEntry() -> MeshRoutedInventoryEntry {
        MeshRoutedInventoryEntry(
            originIndex: 0, itemID: itemID, holdsManifest: true, chunkCount: 3,
            heldChunks: Data([0x07]), custodySigners: [1], recipientSigners: []
        )
    }

    /// The parked item: 2 chunks, index 0 only (`0b0000_0001`), and — as a parked record always
    /// must — empty signer lists.
    static func parkedEntry() -> MeshRoutedInventoryEntry {
        MeshRoutedInventoryEntry(
            originIndex: 1, itemID: parkedItemID, holdsManifest: false, chunkCount: 2,
            heldChunks: Data([0x01]), custodySigners: [], recipientSigners: []
        )
    }

    /// The golden inventory.
    static func inventory() -> MeshRoutedInventory {
        MeshRoutedInventory(meshID: meshID, members: members, entries: [completeEntry(), parkedEntry()])
    }

    /// The golden payload, built from already-"signed" parts through the memberwise init.
    static func payload() -> MeshRoutedInventoryPayload {
        MeshRoutedInventoryPayload(
            inventory: inventory(), senderFingerprint: senderFingerprint,
            sentAt: sentAt, signature: opaqueSignature
        )
    }

    static func hex(_ data: Data) -> String {
        MeshMembershipEventFixtures.hex(data)
    }

    /// A synthetic maximal inventory: `maxEntries` entries, `maxReferencedMembers` members, both
    /// signer lists at their caps, and the widest bitmap. Shape is not asserted — only size is.
    static func maximalInventory() -> MeshRoutedInventory {
        let table = (0..<MeshRoutedInventoryFormat.maxReferencedMembers).map { "fp\(String(format: "%03d", $0))" }
        let custody = (0..<MeshRoutedInventoryFormat.maxCustodySignersPerEntry).map { UInt8($0) }
        let recipient = (0..<MeshRoutedInventoryFormat.maxRecipientSignersPerEntry).map { UInt8($0) }
        let widest = Data(repeating: 0xFF, count: MeshRoutedInventoryFormat.maxHeldChunkBitmapBytes)
        let entries = (0..<MeshRoutedInventoryFormat.maxEntries).map { position in
            MeshRoutedInventoryEntry(
                originIndex: UInt8(position % MeshRoutedInventoryFormat.maxReferencedMembers),
                itemID: UUID(), holdsManifest: true,
                chunkCount: UInt32(MeshRoutedInventoryFormat.maxChunkCount),
                heldChunks: widest, custodySigners: custody, recipientSigners: recipient
            )
        }
        return MeshRoutedInventory(meshID: meshID, members: table, entries: entries)
    }
}

// MARK: - Test-only rebuilders

extension MeshRoutedInventoryEntry {
    /// Test-only: a copy with the named fields replaced, through the verbatim memberwise init.
    func replacing(
        originIndex: UInt8? = nil,
        itemID: UUID? = nil,
        holdsManifest: Bool? = nil,
        chunkCount: UInt32? = nil,
        heldChunks: Data? = nil,
        custodySigners: [UInt8]? = nil,
        recipientSigners: [UInt8]? = nil
    ) -> MeshRoutedInventoryEntry {
        MeshRoutedInventoryEntry(
            originIndex: originIndex ?? self.originIndex,
            itemID: itemID ?? self.itemID,
            holdsManifest: holdsManifest ?? self.holdsManifest,
            chunkCount: chunkCount ?? self.chunkCount,
            heldChunks: heldChunks ?? self.heldChunks,
            custodySigners: custodySigners ?? self.custodySigners,
            recipientSigners: recipientSigners ?? self.recipientSigners
        )
    }
}

extension MeshRoutedInventory {
    /// Test-only: a copy with the named fields replaced, through the verbatim memberwise init.
    func replacing(
        meshID: UUID? = nil, members: [String]? = nil, entries: [MeshRoutedInventoryEntry]? = nil
    ) -> MeshRoutedInventory {
        MeshRoutedInventory(
            meshID: meshID ?? self.meshID,
            members: members ?? self.members,
            entries: entries ?? self.entries
        )
    }
}

extension MeshRoutedInventoryPayload {
    /// Test-only: a copy with the named fields replaced, through the flooring memberwise init.
    func replacing(
        inventory: MeshRoutedInventory? = nil,
        senderFingerprint: String? = nil,
        sentAt: Date? = nil,
        signature: Data? = nil
    ) -> MeshRoutedInventoryPayload {
        MeshRoutedInventoryPayload(
            inventory: inventory ?? self.inventory,
            senderFingerprint: senderFingerprint ?? self.senderFingerprint,
            sentAt: sentAt ?? self.sentAt,
            signature: signature ?? self.signature
        )
    }
}

/// One non-canonical encoding per case — each a refusal, never a repair.
enum MeshRoutedInventoryShapeFault: String, CaseIterable, Sendable {
    case unsortedMembers, duplicateMember, unreferencedMember, emptyMemberFingerprint
    case originIndexOutOfRange, signerIndexOutOfRange, unsortedSignerList, duplicateSignerIndex
    case duplicateEntry, entriesOutOfCanonicalOrder
    case chunkCountZero, chunkCountAboveTheCap
    case bitmapOneByteShort, bitmapOneByteLong, bitSetAboveTheChunkCount

    /// The golden inventory with this one fault applied through the verbatim memberwise init.
    func applied(to base: MeshRoutedInventory) -> MeshRoutedInventory {
        if let members = replacementMembers(base) { return base.replacing(members: members) }
        return base.replacing(entries: replacementEntries(base))
    }

    /// The member-table faults, or nil when this case rewrites entries instead.
    private func replacementMembers(_ base: MeshRoutedInventory) -> [String]? {
        switch self {
        case .unsortedMembers: return base.members.reversed()
        case .duplicateMember: return [base.members[0], base.members[0]]
        case .unreferencedMember: return base.members + ["fp009"]
        case .emptyMemberFingerprint: return ["", base.members[1]]
        default: return nil
        }
    }

    /// The entry faults.
    private func replacementEntries(_ base: MeshRoutedInventory) -> [MeshRoutedInventoryEntry] {
        let first = base.entries[0]
        let second = base.entries[1]
        switch self {
        case .originIndexOutOfRange: return [first.replacing(originIndex: 9), second]
        case .signerIndexOutOfRange: return [first.replacing(custodySigners: [9]), second]
        case .unsortedSignerList: return [first.replacing(custodySigners: [1, 0]), second]
        case .duplicateSignerIndex: return [first.replacing(custodySigners: [1, 1]), second]
        case .duplicateEntry: return [first, first]
        case .entriesOutOfCanonicalOrder: return [second, first]
        case .chunkCountZero: return [first.replacing(chunkCount: 0, heldChunks: Data()), second]
        case .chunkCountAboveTheCap:
            // An over-cap chunk count has no canonical bitmap (its width would be 129 bytes, itself
            // over a cap), so this fault carries a short map: clauses 3 and 4 both fire, and the
            // refusal is `.malformed` rather than `.overCapacity`.
            let over = UInt32(MeshRoutedInventoryFormat.maxChunkCount + 1)
            return [first.replacing(chunkCount: over, heldChunks: Data([0x00])), second]
        case .bitmapOneByteShort: return [first.replacing(heldChunks: Data()), second]
        case .bitmapOneByteLong: return [first.replacing(heldChunks: Data([0x07, 0x00])), second]
        case .bitSetAboveTheChunkCount: return [first.replacing(heldChunks: Data([0x0F])), second]
        default: return base.entries
        }
    }
}

/// One over-cap collection per case — each `.overCapacity` **by name**, and distinct from
/// `.malformed`: the two refusals mean different things and a single boolean would blur them.
enum MeshRoutedInventoryCapFault: String, CaseIterable, Sendable {
    case tooManyEntries, tooManyMembers, tooManyCustodySigners, tooManyRecipientSigners
    case overLongMemberFingerprint

    /// The golden inventory with this one cap broken.
    func applied(to base: MeshRoutedInventory) -> MeshRoutedInventory {
        switch self {
        case .tooManyEntries:
            let entries = (0...MeshRoutedInventoryFormat.maxEntries).map { _ in
                base.entries[0].replacing(itemID: UUID())
            }
            return base.replacing(entries: entries)
        case .tooManyMembers:
            let table = (0...MeshRoutedInventoryFormat.maxReferencedMembers)
                .map { "fp\(String(format: "%03d", $0))" }
            return base.replacing(members: table)
        case .tooManyCustodySigners:
            let signers = (0...MeshRoutedInventoryFormat.maxCustodySignersPerEntry).map { UInt8($0) }
            return base.replacing(entries: [base.entries[0].replacing(custodySigners: signers)])
        case .tooManyRecipientSigners:
            let signers = (0...MeshRoutedInventoryFormat.maxRecipientSignersPerEntry).map { UInt8($0) }
            return base.replacing(entries: [base.entries[0].replacing(recipientSigners: signers)])
        case .overLongMemberFingerprint:
            let wide = String(repeating: "f", count: MeshRoutedInventoryFormat.maxFingerprintLength + 1)
            return base.replacing(members: [base.members[0], wide])
        }
    }
}

// MARK: - Golden vectors

/// Pinned canonical bytes for the routed inventory digest (P5 item 5), and the collision wall
/// between the two digest families.
///
/// The vector was derived by an independent Python re-implementation of the FORMAT header in
/// `CanonicalSignatureSerializer.swift` and proved honest the same way items 1–4's were: by first
/// reproducing all EIGHT shipped vectors byte-for-byte before this one was minted.
///
/// A failing golden is a WIRE decision — never re-pin it from Swift's output to go green. The
/// failure message reprints the actual hex so a deliberate bump can be re-pinned by copy-paste.
@Suite(.serialized)
struct MeshRoutedInventoryGoldenTests {

    /// 229 bytes. Field order: domain ‖ meshID ‖ members ‖ entries ‖ sender ‖ sentAt. Signature
    /// excluded.
    static let goldenRoutedInventoryHex = "00000000000000276665726e6c65742e6d6573682e726f757465642d696e76656e746f72792d6469676573742e76311f1f1f1f2e2e4d4d8c8c0b0b0b0b0b0b000000000000000200000000000000056670303031000000000000000566703030340000000000000002005a5a5a5a6b6b4c4c8d8d3e3e3e3e3e3e0100000000000000030000000000000001070000000000000001010000000000000000016b6b6b6b7c7c4e4e9f9f4a4a4a4a4a4a0000000000000000020000000000000001010000000000000000000000000000000000000000000000056670303031000000006553f3d0"

    @Test func theFixtureIDsAreTheLiteralsNotFallbacks() {
        #expect(MeshRoutedInventoryFixtures.itemID.uuidString == "5A5A5A5A-6B6B-4C4C-8D8D-3E3E3E3E3E3E")
        #expect(MeshRoutedInventoryFixtures.parkedItemID.uuidString
                == "6B6B6B6B-7C7C-4E4E-9F9F-4A4A4A4A4A4A")
        #expect(MeshRoutedInventoryFixtures.meshID.uuidString == "1F1F1F1F-2E2E-4D4D-8C8C-0B0B0B0B0B0B")
    }

    @Test func theCanonicalTranscriptIsPinned() {
        let actual = MeshRoutedInventoryFixtures.hex(
            canonicalBytes(for: MeshRoutedInventoryFixtures.payload())
        )
        #expect(actual == Self.goldenRoutedInventoryHex, "actual routed inventory golden hex = \(actual)")
    }

    @Test func theGoldenIsTheExpectedLength() {
        let actual = canonicalBytes(for: MeshRoutedInventoryFixtures.payload())
        #expect(actual.count == Self.goldenRoutedInventoryHex.count / 2)
        #expect(actual.count == 229)
    }

    /// Every vector below the new one is untouched by item 5 (the P4/P5 idiom).
    @Test func theOlderRoutedGoldensAreUnmoved() {
        let manifest = MeshRoutedInventoryFixtures.hex(canonicalBytes(for: MeshRoutedManifestFixtures.manifest()))
        #expect(manifest == MeshRoutedManifestGoldenTests.goldenRoutedManifestHex,
                "actual routed manifest golden hex = \(manifest)")
        let chunk = MeshRoutedInventoryFixtures.hex(canonicalBytes(for: MeshChunkFixtures.chunk()))
        #expect(chunk == MeshChunkGoldenTests.goldenRoutedChunkHex, "actual routed chunk golden hex = \(chunk)")
        let custody = MeshRoutedInventoryFixtures.hex(canonicalBytes(for: MeshCustodyReceiptFixtures.receipt()))
        #expect(custody == MeshCustodyReceiptGoldenTests.goldenCustodyReceiptHex,
                "actual custody receipt golden hex = \(custody)")
        let recipient = MeshRoutedInventoryFixtures.hex(canonicalBytes(for: MeshRecipientReceiptFixtures.receipt()))
        #expect(recipient == MeshRecipientReceiptGoldenTests.goldenRecipientReceiptHex,
                "actual recipient receipt golden hex = \(recipient)")
        let membership = MeshRoutedInventoryFixtures.hex(
            canonicalBytes(for: MeshMembershipEventFixtures.inventoryPayload())
        )
        #expect(membership == MeshMembershipEventGoldenTests.goldenInventoryHex,
                "actual membership inventory golden hex = \(membership)")
    }

    /// Token and signing domain are one vocabulary.
    @Test func theTokenVocabularyIsShared() {
        #expect(PayloadType.meshRoutedInventoryDigest.rawValue
                == FernletCryptoPurpose.Signature.meshRoutedInventoryDigestV1.rawValue)
        #expect(PayloadType.meshRoutedInventoryDigest.rawValue
                == "fernlet.mesh.routed-inventory-digest.v1")
    }

    /// The collision wall the brief asks for, asserting **what actually holds**.
    ///
    /// The wire vocabulary deliberately SHARES the `inventory-digest` spelling, so
    /// `grep InventoryDigest` returns both families and is not decisive. What is decisive is the stem
    /// pair over Swift **value types** — no routed value type carries `InventoryDigest`, no
    /// membership value type carries `Routed` — plus two distinct rawValues, neither a prefix of the
    /// other.
    @Test func theDigestNamesDoNotCollide() {
        #expect(!String(describing: MeshRoutedInventory.self).contains("InventoryDigest"))
        #expect(!String(describing: MeshRoutedInventoryPayload.self).contains("InventoryDigest"))
        #expect(!String(describing: MeshRoutedInventoryDelta.self).contains("InventoryDigest"))
        #expect(!String(describing: MeshRoutedInventoryEntry.self).contains("InventoryDigest"))
        #expect(!String(describing: MeshInventoryDigest.self).contains("Routed"))
        #expect(!String(describing: MeshInventoryDigestPayload.self).contains("Routed"))
        #expect(PayloadType.meshRoutedInventoryDigest.rawValue != PayloadType.meshInventoryDigest.rawValue)
        #expect(!PayloadType.meshRoutedInventoryDigest.rawValue
            .hasPrefix(PayloadType.meshInventoryDigest.rawValue))
        #expect(!PayloadType.meshInventoryDigest.rawValue
            .hasPrefix(PayloadType.meshRoutedInventoryDigest.rawValue))
    }

    @Test func aCodableRoundTripPreservesTheCanonicalBytes() throws {
        let original = MeshRoutedInventoryFixtures.payload()
        let wire = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeshRoutedInventoryPayload.self, from: wire)
        #expect(decoded == original)
        #expect(decoded.signature == original.signature)
        let actual = MeshRoutedInventoryFixtures.hex(canonicalBytes(for: decoded))
        #expect(actual == Self.goldenRoutedInventoryHex, "actual round-tripped golden hex = \(actual)")
    }

    @Test func aPayloadsSignatureIsExcludedFromItsCanonicalBytes() {
        let resigned = MeshRoutedInventoryFixtures.payload()
            .replacing(signature: Data(repeating: 0xCD, count: 64))
        #expect(canonicalBytes(for: resigned)
                == canonicalBytes(for: MeshRoutedInventoryFixtures.payload()))
    }

    /// A maximal digest still rides one frame: the arithmetic item 9 and tier 2 both want stated as
    /// a number rather than an adjective.
    @Test func theWorstCaseFrameIsUnderTheTransportCeiling() {
        let maximal = MeshRoutedInventoryPayload(
            inventory: MeshRoutedInventoryFixtures.maximalInventory(),
            senderFingerprint: String(repeating: "f", count: MeshRoutedInventoryFormat.maxFingerprintLength),
            sentAt: MeshRoutedInventoryFixtures.sentAt,
            signature: MeshRoutedInventoryFixtures.opaqueSignature
        )
        let bytes = canonicalBytes(for: maximal).count
        #expect(bytes < SealedPayloadFraming.maxInflatedByteCount, "maximal canonical bytes = \(bytes)")
        #expect(bytes > 100_000, "the maximal vector must actually be maximal: \(bytes)")
    }

    /// The seven fields, and nothing receiver-local, epoch-shaped, relay-shaped or destination-shaped.
    @Test func anEntryCarriesNoEpochNoDestinationSetAndNoFirstSeen() {
        let labels = Mirror(reflecting: MeshRoutedInventoryFixtures.completeEntry()).children.compactMap(\.label)
        #expect(labels == [
            "originIndex", "itemID", "holdsManifest", "chunkCount", "heldChunks",
            "custodySigners", "recipientSigners"
        ])
        for label in labels.map({ $0.lowercased() }) {
            #expect(label.contains("epoch") == false)
            #expect(label.contains("branch") == false)
            #expect(label.contains("hop") == false)
            #expect(label.contains("ttl") == false)
            #expect(label.contains("destination") == false)
            #expect(label.contains("firstseen") == false)
            #expect(label.contains("schema") == false)
            #expect(label.contains("hash") == false)
        }
    }
}

// MARK: - Shape

/// The untrusted-bytes half: one non-canonical encoding per case, refused and never repaired, and
/// the two caps that are deliberately different numbers.
@Suite(.serialized)
struct MeshRoutedInventoryShapeTests {

    /// A verifier whose ledger knows nobody: the caps and shape steps run before any lookup, so a
    /// well-formed payload reaches `.senderNotAdmitted` and a broken one does not.
    private func door() -> MeshRoutedInventoryVerifier {
        MeshRoutedInventoryVerifier(meshID: MeshRoutedInventoryFixtures.meshID, ledger: .empty)
    }

    @Test func theGoldenFixtureIsCanonical() {
        let inventory = MeshRoutedInventoryFixtures.inventory()
        #expect(inventory.isWithinCaps)
        #expect(inventory.isWellFormed)
        #expect(MeshRoutedInventoryFixtures.payload().isWellFormed)
        #expect(door().verify(MeshRoutedInventoryFixtures.payload()) == .senderNotAdmitted)
    }

    @Test(arguments: MeshRoutedInventoryShapeFault.allCases)
    func everyShapeFaultIsMalformed(fault: MeshRoutedInventoryShapeFault) {
        let broken = fault.applied(to: MeshRoutedInventoryFixtures.inventory())
        #expect(broken.isWellFormed == false, "\(fault)")
        let payload = MeshRoutedInventoryFixtures.payload().replacing(inventory: broken)
        #expect(door().verify(payload) == .malformed, "\(fault)")
    }

    @Test(arguments: MeshRoutedInventoryCapFault.allCases)
    func everyCapFaultIsOverCapacityByName(fault: MeshRoutedInventoryCapFault) {
        let broken = fault.applied(to: MeshRoutedInventoryFixtures.inventory())
        #expect(broken.isWithinCaps == false, "\(fault)")
        let payload = MeshRoutedInventoryFixtures.payload().replacing(inventory: broken)
        #expect(door().verify(payload) == .overCapacity, "\(fault)")
    }

    /// A decode repairs nothing: a mis-ordered or over-cap value survives the wire unchanged, which
    /// is what makes the refusal reachable at the verifier rather than unreachable behind a clamp.
    @Test func aDecodeNeitherSortsNorClampsNorRepairs() throws {
        let unordered = MeshRoutedInventoryShapeFault.entriesOutOfCanonicalOrder
            .applied(to: MeshRoutedInventoryFixtures.inventory())
        let wire = try JSONEncoder().encode(unordered)
        let decoded = try JSONDecoder().decode(MeshRoutedInventory.self, from: wire)
        #expect(decoded == unordered)
        #expect(decoded.entries.map(\.originIndex) == [1, 0])
        #expect(decoded.isWellFormed == false)
    }

    /// The two payload scalars no door clamps, checked BEFORE the ledger lookup.
    @Test func aWrongWidthSignatureIsMalformed() {
        let narrow = MeshRoutedInventoryFixtures.payload()
            .replacing(signature: Data(repeating: 0xAB, count: 63))
        #expect(narrow.isWellFormed == false)
        #expect(door().verify(narrow) == .malformed)
    }

    @Test func anEmptyOrOverLongSenderFingerprintIsMalformed() {
        let empty = MeshRoutedInventoryFixtures.payload().replacing(senderFingerprint: "")
        let wide = MeshRoutedInventoryFixtures.payload().replacing(
            senderFingerprint: String(repeating: "s", count: MeshRoutedInventoryFormat.maxFingerprintLength + 1)
        )
        #expect(empty.isWellFormed == false)
        #expect(wide.senderFingerprint.utf8.count
                == MeshRoutedInventoryFormat.maxFingerprintLength + 1, "the door must NOT clamp the scalar")
        #expect(wide.isWellFormed == false)
        #expect(door().verify(empty) == .malformed)
        #expect(door().verify(wide) == .malformed)
    }

    /// The bitmap's frozen bit order and its derived reads, for every width shape.
    @Test func theBitmapIsCanonicalForEveryChunkCount() {
        for count in [1, 7, 8, 9, MeshRoutedInventoryFormat.maxChunkCount] {
            let width = MeshRoutedInventoryEntry.bitmapByteCount(forChunkCount: UInt32(count))
            #expect(width == (count + 7) / 8, "\(count)")
            let full = Data((0..<width).map { byte in
                var value: UInt8 = 0
                for bit in 0..<8 where byte * 8 + bit < count { value |= UInt8(1) << UInt8(bit) }
                return value
            })
            #expect(MeshRoutedInventoryEntry.bitmapIsCanonical(full, for: UInt32(count)), "\(count)")
            let entry = MeshRoutedInventoryFixtures.completeEntry()
                .replacing(chunkCount: UInt32(count), heldChunks: full)
            #expect(entry.heldChunkCount == count, "\(count)")
            #expect(entry.isComplete, "\(count)")
        }
    }

    /// The reads the delta depends on, over a hole-punched set: `{0, 2}` of 4.
    @Test func partialHoldingsReportTheExactHeldSet() {
        let entry = MeshRoutedInventoryFixtures.completeEntry()
            .replacing(chunkCount: 4, heldChunks: Data([0b0000_0101]))
        #expect(entry.heldChunkCount == 2)
        #expect(entry.isComplete == false)
        #expect(entry.holdsChunk(0))
        #expect(entry.holdsChunk(1) == false)
        #expect(entry.holdsChunk(2))
        #expect(entry.holdsChunk(3) == false)
        #expect(entry.holdsChunk(9) == false, "an index past the map is not held, never a crash")
    }
}
