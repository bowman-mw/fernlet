// MeshMembershipEventWireTests.swift
// FernletTests
//
// P3 item 3 (plan §8.3, §9, §10.5): the membership events that move signed bytes.
//
// Four claims are walled here, each one a thing a later item cannot cheaply re-derive:
//
// 1. **The signed bytes are pinned.** Golden vectors written from the FORMAT — a length-prefixed
//    domain, fixed-width integers and dates, length-prefixed strings — not copied out of the
//    serializer's own output. A golden that only records what the code did proves nothing about
//    what the code should do; these were computed independently and then met.
// 2. **The registry's declared framing matches the bytes.** Every new purpose is `.lengthPrefixed`
//    and every new serializer must satisfy it. That pairing is what broke silently in `91c3956`,
//    so it is asserted in `CryptographicPurposeBoundaryTests` beside the introduction's — and the
//    cross-domain half is asserted here: a departure signature must not verify as a termination.
// 3. **Verification happens BEFORE insertion.** Item 1's sets are capped at sixteen and keep the
//    EARLIEST records, so unverified junk with a low timestamp does not merely add noise — it
//    crowds a real removal out of the set on every device it reaches.
// 4. **A legacy goodbye cannot end a membership.** It is unsigned; the strongest thing it can mean
//    is "this link is going away". Letting it mint a permanent, grow-only departure record would
//    make eviction forgeable by anyone who can reach the link, with no way to undo it.

import Foundation
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
import Testing
@testable import ProximityKit
@testable import Fernlet

// MARK: - Fixtures

/// Fixed values shared by the golden vectors, so every byte in a pinned hex string is traceable to
/// a line here and nothing reads a wall clock.
enum MeshMembershipEventFixtures {

    static let meshID = UUID(uuidString: "1F1F1F1F-2E2E-4D4D-8C8C-0B0B0B0B0B0B") ?? UUID()
    static let proposalID = UUID(uuidString: "2A2A2A2A-3B3B-4C4C-8D8D-0E0E0E0E0E0E") ?? UUID()
    /// A second proposal, so the voter-cap vector is a different record rather than a variant of
    /// the one item 3 already pinned.
    static let cappedProposalID = UUID(uuidString: "3C3C3C3C-4D4D-4E4E-8F8F-1A1A1A1A1A1A") ?? UUID()
    static let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// A 64-byte blob standing in for a signature in the golden vectors. Signatures are EXCLUDED
    /// from canonical bytes, so its value must not be able to change a single pinned byte — which
    /// is itself one of the things the goldens prove.
    static let opaqueSignature = Data(repeating: 0xAB, count: 64)

    static func departure() -> SignedDepartureRecord {
        SignedDepartureRecord(
            meshID: meshID,
            memberFingerprint: "fp001",
            occurredAt: base.addingTimeInterval(60),
            custodyHandoff: MeshCustodyHandoffSummary(
                custodianFingerprints: ["fp002", "fp003"],
                handedOffItemCount: 4
            ),
            signature: opaqueSignature
        )
    }

    static func removal() -> SignedRemovalRecord {
        SignedRemovalRecord(
            meshID: meshID,
            memberFingerprint: "fp004",
            proposalID: proposalID,
            voterFingerprints: ["fp001", "fp002"],
            occurredAt: base.addingTimeInterval(120),
            authorFingerprint: "fp001",
            signature: opaqueSignature
        )
    }

    /// A completed removal citing the §9 maximum number of voters — the widest voter list the
    /// format ever has to carry, and the one a frame's clamp is judged against.
    static func removalAtVoterCap() -> SignedRemovalRecord {
        SignedRemovalRecord(
            meshID: meshID,
            memberFingerprint: "fp009",
            proposalID: cappedProposalID,
            voterFingerprints: (1...MeshMembershipBounds.maxVoters).map { String(format: "fp%03d", $0) },
            occurredAt: base.addingTimeInterval(300),
            authorFingerprint: "fp002",
            signature: opaqueSignature
        )
    }

    static func termination() -> SignedTerminationRecord {
        SignedTerminationRecord(
            meshID: meshID,
            memberFingerprint: "fp001",
            rosterAtSigning: ["fp001", "fp002"],
            occurredAt: base.addingTimeInterval(180),
            signature: opaqueSignature
        )
    }

    /// A ledger holding exactly one admission, built from item 1's own fixtures so the digest's
    /// pinned hash is reproducible.
    static func singleAdmissionLedger() -> MeshMembershipLedger {
        MeshMembershipLedger(admissions: MeshMembershipRecordSet([MeshMembershipFixtures.admission(1)]))
    }

    static func inventoryPayload() -> MeshInventoryDigestPayload {
        MeshInventoryDigestPayload(
            digest: MeshInventoryDigest(meshID: meshID, ledger: singleAdmissionLedger()),
            senderFingerprint: "fp001",
            sentAt: base.addingTimeInterval(240),
            signature: opaqueSignature
        )
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Golden vectors

/// Pinned canonical signing bytes for the three membership records and the digest message.
///
/// If one of these fails and the change was NOT a deliberate wire-format change, the change has
/// left item 3's scope — do not re-pin it to make the suite green. Each failure message reprints
/// the actual hex so a genuinely deliberate bump can be re-pinned by copy-paste.
@Suite(.serialized)
struct MeshMembershipEventGoldenTests {

    static let goldenDepartureHex = "00000000000000206665726e6c65742e6d6573682e6d656d6265722d6465706172747572652e76311f1f1f1f2e2e4d4d8c8c0b0b0b0b0b0b00000000000000056670303031000000006553f13c000000000000000200000000000000056670303032000000000000000566703030330000000000000004"

    static let goldenRemovalHex = "000000000000001e6665726e6c65742e6d6573682e6d656d6265722d72656d6f76616c2e76311f1f1f1f2e2e4d4d8c8c0b0b0b0b0b0b000000000000000566703030342a2a2a2a3b3b4c4c8d8d0e0e0e0e0e0e00000000000000020000000000000005667030303100000000000000056670303032000000006553f17800000000000000056670303031"

    /// Item 3b's vector: a completed removal at the §9 voter cap (eight voters), derived by the
    /// same independent Python re-implementation of the FORMAT header in
    /// `CanonicalSignatureSerializer.swift` — length-prefixed domain, 16 raw UUID bytes,
    /// length-prefixed UTF-8 strings, a u64 voter count, an i64 floored-seconds date, signature
    /// excluded. That re-implementation was proved honest by first reproducing
    /// ``goldenRemovalHex`` byte-for-byte, and only then used to mint this one.
    static let goldenRemovalAtVoterCapHex = "000000000000001e6665726e6c65742e6d6573682e6d656d6265722d72656d6f76616c2e76311f1f1f1f2e2e4d4d8c8c0b0b0b0b0b0b000000000000000566703030393c3c3c3c4d4d4e4e8f8f1a1a1a1a1a1a00000000000000080000000000000005667030303100000000000000056670303032000000000000000566703030330000000000000005667030303400000000000000056670303035000000000000000566703030360000000000000005667030303700000000000000056670303038000000006553f22c00000000000000056670303032"

    static let goldenTerminationHex = "000000000000001a6665726e6c65742e6d6573682e7465726d696e617465642e76311f1f1f1f2e2e4d4d8c8c0b0b0b0b0b0b0000000000000005667030303100000000000000020000000000000005667030303100000000000000056670303032000000006553f1b4"

    /// SHA-256 over the domain-tagged, sorted record identities of a one-admission ledger.
    static let goldenRecordsHashHex = "68a143515034a365db8d43758d2f6458b29c33481f9c4b3d9c54e503bed603e9"

    static let goldenInventoryHex = "00000000000000206665726e6c65742e6d6573682e696e76656e746f72792d6469676573742e76311f1f1f1f2e2e4d4d8c8c0b0b0b0b0b0b00000000000000056670303031000000006553f1f00000000000000001000000000000000000000000000000000000000000000000000000000000002068a143515034a365db8d43758d2f6458b29c33481f9c4b3d9c54e503bed603e9"

    @Test func aDepartureRecordIsGoldenStable() {
        let actual = MeshMembershipEventFixtures.hex(canonicalBytes(for: MeshMembershipEventFixtures.departure()))
        #expect(actual == Self.goldenDepartureHex, "actual departure golden hex = \(actual)")
    }

    @Test func aRemovalRecordIsGoldenStable() {
        let actual = MeshMembershipEventFixtures.hex(canonicalBytes(for: MeshMembershipEventFixtures.removal()))
        #expect(actual == Self.goldenRemovalHex, "actual removal golden hex = \(actual)")
    }

    /// Item 3b's new vector. Nothing above it moves: the removal record's canonical bytes were
    /// already pinned by item 3 and framing the record does not touch them.
    @Test func aRemovalAtTheVoterCapIsGoldenStable() {
        let record = MeshMembershipEventFixtures.removalAtVoterCap()
        #expect(record.voterFingerprints.count == MeshMembershipBounds.maxVoters)
        let actual = MeshMembershipEventFixtures.hex(canonicalBytes(for: record))
        #expect(actual == Self.goldenRemovalAtVoterCapHex, "actual capped removal golden hex = \(actual)")
    }

    /// The property a FRAME owes that a record's own golden cannot prove: the signed bytes survive
    /// the wire. A frame that re-ordered, truncated or re-typed one field would leave a record
    /// whose signature no receiver could verify, and a round-trip equality test alone would not
    /// see it — the record would round-trip to itself perfectly and still hash differently.
    @Test func aRemovalFramePreservesTheSignedBytesAcrossTheWire() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for (record, golden) in [
            (MeshMembershipEventFixtures.removal(), Self.goldenRemovalHex),
            (MeshMembershipEventFixtures.removalAtVoterCap(), Self.goldenRemovalAtVoterCapHex)
        ] {
            let wire = try encoder.encode(MeshMemberRemovalPayload(record: record))
            let decoded = try decoder.decode(MeshMemberRemovalPayload.self, from: wire)
            #expect(MeshMembershipEventFixtures.hex(canonicalBytes(for: decoded.record)) == golden)
        }
    }

    @Test func aTerminationRecordIsGoldenStable() {
        let actual = MeshMembershipEventFixtures.hex(canonicalBytes(for: MeshMembershipEventFixtures.termination()))
        #expect(actual == Self.goldenTerminationHex, "actual termination golden hex = \(actual)")
    }

    @Test func anInventoryDigestMessageIsGoldenStable() {
        let payload = MeshMembershipEventFixtures.inventoryPayload()
        let hashHex = MeshMembershipEventFixtures.hex(payload.digest.recordsHash)
        #expect(hashHex == Self.goldenRecordsHashHex, "actual records hash hex = \(hashHex)")
        let actual = MeshMembershipEventFixtures.hex(canonicalBytes(for: payload))
        #expect(actual == Self.goldenInventoryHex, "actual inventory golden hex = \(actual)")
    }

    /// The signature is the OUTPUT of signing these bytes, so changing it must not move one byte.
    /// A serializer that folded the signature in would make every signature unverifiable, and no
    /// round-trip test would see it.
    @Test func aRecordsSignatureIsExcludedFromItsCanonicalBytes() {
        var tampered = MeshMembershipEventFixtures.departure()
        tampered = SignedDepartureRecord(
            meshID: tampered.meshID,
            memberFingerprint: tampered.memberFingerprint,
            occurredAt: tampered.occurredAt,
            custodyHandoff: tampered.custodyHandoff,
            signature: Data(repeating: 0x01, count: 64)
        )
        #expect(MeshMembershipEventFixtures.hex(canonicalBytes(for: tampered)) == Self.goldenDepartureHex)
    }

    /// The four domains keep the four records apart. Same fingerprint, same instant, same mesh —
    /// and four different transcripts, so a departure signature can never validate as the
    /// termination that ends the mesh for everyone.
    @Test func everyRecordKindGetsItsOwnDomain() {
        let departure = canonicalBytes(for: MeshMembershipEventFixtures.departure())
        let removal = canonicalBytes(for: MeshMembershipEventFixtures.removal())
        let termination = canonicalBytes(for: MeshMembershipEventFixtures.termination())
        let inventory = canonicalBytes(for: MeshMembershipEventFixtures.inventoryPayload())
        let all = [departure, removal, termination, inventory]
        #expect(Set(all).count == all.count)

        #expect(FernletCryptoPurpose.Signature.meshMemberDepartureV1.signingBytes(departure) != nil)
        #expect(FernletCryptoPurpose.Signature.meshMemberDepartureV1.signingBytes(termination) == nil)
        #expect(FernletCryptoPurpose.Signature.meshTerminatedV1.signingBytes(termination) != nil)
        #expect(FernletCryptoPurpose.Signature.meshTerminatedV1.signingBytes(departure) == nil)
        #expect(FernletCryptoPurpose.Signature.meshMemberRemovalV1.signingBytes(removal) != nil)
        #expect(FernletCryptoPurpose.Signature.meshInventoryDigestV1.signingBytes(inventory) != nil)
    }

    /// Record kind, wire token and crypto domain are ONE frozen English vocabulary. If they ever
    /// diverge, a grep for the token stops finding the layer that signs it.
    @Test func theTokenVocabularyIsShared() {
        #expect(MeshMembershipRecordKind.departure.rawValue == PayloadType.meshMemberDeparture.rawValue)
        #expect(MeshMembershipRecordKind.removal.rawValue == PayloadType.meshMemberRemoval.rawValue)
        #expect(MeshMembershipRecordKind.termination.rawValue == PayloadType.meshTerminated.rawValue)
        #expect(
            MeshMembershipRecordKind.departure.rawValue
                == FernletCryptoPurpose.Signature.meshMemberDepartureV1.rawValue
        )
        #expect(
            MeshMembershipRecordKind.removal.rawValue
                == FernletCryptoPurpose.Signature.meshMemberRemovalV1.rawValue
        )
        #expect(
            MeshMembershipRecordKind.termination.rawValue
                == FernletCryptoPurpose.Signature.meshTerminatedV1.rawValue
        )
        #expect(
            PayloadType.meshInventoryDigest.rawValue
                == FernletCryptoPurpose.Signature.meshInventoryDigestV1.rawValue
        )
    }

    /// The four frames survive a JSON round trip — they are `Codable` wire types, and the record
    /// inside each one carries its own clamped decode.
    @Test func everyFrameRoundTrips() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let departure = MeshMemberDeparturePayload(record: MeshMembershipEventFixtures.departure())
        #expect(try decoder.decode(
            MeshMemberDeparturePayload.self, from: encoder.encode(departure)) == departure)
        let removal = MeshMemberRemovalPayload(record: MeshMembershipEventFixtures.removal())
        #expect(try decoder.decode(
            MeshMemberRemovalPayload.self, from: encoder.encode(removal)) == removal)
        let termination = MeshTerminationPayload(record: MeshMembershipEventFixtures.termination())
        #expect(try decoder.decode(
            MeshTerminationPayload.self, from: encoder.encode(termination)) == termination)
        let inventory = MeshMembershipEventFixtures.inventoryPayload()
        #expect(try decoder.decode(
            MeshInventoryDigestPayload.self, from: encoder.encode(inventory)) == inventory)
    }
}

// MARK: - Inventory digest

/// The digest is a pure function of the record SET (plan §10.5): equal ledgers agree no matter how
/// they were assembled, and one differing record is visible.
@Suite(.serialized)
struct MeshInventoryDigestTests {

    private func ledger(_ indices: [Int]) -> MeshMembershipLedger {
        MeshMembershipLedger(
            admissions: MeshMembershipRecordSet(indices.map { MeshMembershipFixtures.admission($0) })
        )
    }

    @Test func equalLedgersProduceEqualDigests() {
        let meshID = MeshMembershipEventFixtures.meshID
        let forward = MeshInventoryDigest(meshID: meshID, ledger: ledger([1, 2, 3]))
        let reversed = MeshInventoryDigest(meshID: meshID, ledger: ledger([3, 2, 1]))
        #expect(forward == reversed)
        #expect(forward.recordsHash == reversed.recordsHash)
        #expect(forward.isWellFormed)
        #expect(forward.recordCount == 3)
    }

    @Test func oneExtraRecordChangesTheDigest() {
        let meshID = MeshMembershipEventFixtures.meshID
        let smaller = MeshInventoryDigest(meshID: meshID, ledger: ledger([1, 2]))
        let larger = MeshInventoryDigest(meshID: meshID, ledger: ledger([1, 2, 3]))
        #expect(smaller != larger)
        #expect(smaller.recordsHash != larger.recordsHash)
    }

    /// The counts alone are not the digest. Two ledgers with the same SHAPE but different records
    /// must differ, or a peer could hide a substitution behind a matching count.
    @Test func sameCountsWithDifferentRecordsDiffer() {
        let meshID = MeshMembershipEventFixtures.meshID
        let first = MeshInventoryDigest(meshID: meshID, ledger: ledger([1, 2]))
        let second = MeshInventoryDigest(meshID: meshID, ledger: ledger([1, 5]))
        #expect(first.admissionCount == second.admissionCount)
        #expect(first.recordsHash != second.recordsHash)
    }

    /// Every kind contributes, and it contributes UNDER ITS KIND: a departure and a removal of the
    /// same member at the same instant are different records, and a digest that conflated them
    /// would report convergence between two ledgers that disagree about why somebody is out.
    @Test func theDigestCoversEveryRecordKind() {
        let meshID = MeshMembershipEventFixtures.meshID
        let base = ledger([1, 2])
        var withDeparture = base
        withDeparture.departures = MeshMembershipRecordSet([MeshMembershipEventFixtures.departure()])
        var withTermination = base
        withTermination.terminations = MeshMembershipRecordSet([MeshMembershipEventFixtures.termination()])
        let digests = [base, withDeparture, withTermination]
            .map { MeshInventoryDigest(meshID: meshID, ledger: $0) }
        #expect(Set(digests.map(\.recordsHash)).count == 3)
        #expect(MeshInventoryDigest(meshID: meshID, ledger: withDeparture).departureCount == 1)
    }

    /// Counts arrive from a peer, so they are clamped on decode exactly as on init — a digest is
    /// bounded input like every other record (plan §9).
    @Test func decodedCountsAreClamped() throws {
        let json = """
        {"meshID":"1F1F1F1F-2E2E-4D4D-8C8C-0B0B0B0B0B0B","admissionCount":9999,\
        "departureCount":-4,"removalCount":0,"terminationCount":77,"recordsHash":""}
        """
        let decoded = try JSONDecoder().decode(MeshInventoryDigest.self, from: Data(json.utf8))
        #expect(decoded.admissionCount == MeshMembershipBounds.maxRecordsPerKind)
        #expect(decoded.departureCount == 0)
        #expect(decoded.terminationCount == MeshMembershipBounds.maxTerminationRecords)
        #expect(!decoded.isWellFormed)   // a zero-length hash is malformed, not a cheap collision
    }
}

// MARK: - Verify-then-insert

/// The seam item 1 deliberately left open: a record enters a ledger only after its signature
/// verifies against the signer's ADMITTED key.
@MainActor
@Suite(.serialized)
struct MeshMembershipRecordVerifierTests {

    private func makeIdentity() throws -> (IdentityService, String) {
        let id = "com.fernlet.mesh-membership.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: id)
        try service.ensureProvisioned()
        return (service, id)
    }

    /// A verifier holding `founder` plus every identity in `others`, all admitted by the founder.
    private func seeded(
        founder: IdentityService,
        others: [IdentityService],
        meshID: UUID
    ) throws -> MeshMembershipRecordVerifier {
        var verifier = MeshMembershipRecordVerifier(
            meshID: meshID,
            founderSigningPublicKey: founder.localSigningPublicKey
        )
        #expect(verifier.insert(try admission(of: founder, by: founder, meshID: meshID)) == nil)
        for member in others {
            #expect(verifier.insert(try admission(of: member, by: founder, meshID: meshID)) == nil)
        }
        return verifier
    }

    private func admission(
        of joiner: IdentityService,
        by admitter: IdentityService,
        meshID: UUID
    ) throws -> SignedAdmissionRecord {
        SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
            meshID: meshID,
            joinerFingerprint: joiner.localFingerprint,
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            admitterIdentity: admitter,
            grantedAt: MeshMembershipEventFixtures.base
        ))
    }

    @Test func aFoundersOwnAdmissionBootstrapsTheRoster() throws {
        let (founder, id) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: id) }
        let meshID = UUID()
        let verifier = try seeded(founder: founder, others: [], meshID: meshID)
        #expect(verifier.roster.memberFingerprints == [founder.localFingerprint])
    }

    /// Without the founder key there is nothing to root the first admission in, so the ledger stays
    /// empty. Fail closed: an empty roster admits nobody, which is the right answer for a device
    /// that cannot tell who started the mesh.
    @Test func anUnrootedAdmissionIsRefused() throws {
        let (founder, id) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: id) }
        let meshID = UUID()
        var verifier = MeshMembershipRecordVerifier(meshID: meshID, founderSigningPublicKey: nil)
        let rejection = verifier.insert(try admission(of: founder, by: founder, meshID: meshID))
        #expect(rejection == .unauthorizedAdmitter)
        #expect(verifier.ledger.admissions.isEmpty)
    }

    @Test func aSignedDepartureIsAcceptedAndSubtracts() throws {
        let (founder, fid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: fid) }
        let (leaver, lid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: lid) }
        let meshID = UUID()
        var verifier = try seeded(founder: founder, others: [leaver], meshID: meshID)
        #expect(verifier.roster.memberCount == 2)

        let record = try SignedDepartureRecord.signed(
            meshID: meshID, identity: leaver, occurredAt: MeshMembershipEventFixtures.base)
        #expect(verifier.insert(record) == nil)
        #expect(verifier.roster.memberFingerprints == [founder.localFingerprint])
    }

    /// The whole reason this seam exists: junk must be refused BEFORE it competes for one of the
    /// sixteen slots. A forged departure with a very low timestamp would otherwise win the
    /// earliest-wins truncation on every device it reached.
    @Test func aForgedDepartureNeverReachesTheCappedSet() throws {
        let (founder, fid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: fid) }
        let (member, mid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: mid) }
        let (stranger, sid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: sid) }
        let meshID = UUID()
        var verifier = try seeded(founder: founder, others: [member], meshID: meshID)

        // Signed by a stranger, claiming to be the member.
        let honest = try SignedDepartureRecord.signed(
            meshID: meshID, identity: stranger, occurredAt: Date(timeIntervalSince1970: 1))
        let forged = SignedDepartureRecord(
            meshID: meshID,
            memberFingerprint: member.localFingerprint,
            occurredAt: honest.occurredAt,
            signature: honest.signature
        )
        #expect(verifier.insert(forged) == .signatureInvalid)
        #expect(verifier.ledger.departures.isEmpty)
        #expect(verifier.roster.memberCount == 2)

        // And a departure about somebody the mesh never admitted has no key to check at all.
        let outsider = try SignedDepartureRecord.signed(meshID: meshID, identity: stranger)
        #expect(verifier.insert(outsider) == .signerNotAdmitted)
        #expect(verifier.ledger.departures.isEmpty)
    }

    @Test func aRecordFromAnotherMeshIsRefused() throws {
        let (founder, fid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: fid) }
        let (member, mid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: mid) }
        let meshID = UUID()
        var verifier = try seeded(founder: founder, others: [member], meshID: meshID)
        let record = try SignedDepartureRecord.signed(meshID: UUID(), identity: member)
        #expect(verifier.insert(record) == .foreignMesh)
    }

    /// Plan §10.4's arithmetic, re-checked against the RECEIVER's merged roster. Roster 3 needs 2
    /// votes; one vote is short, and the target's own vote never counts.
    @Test func aRemovalNeedsQuorumFromTheReceiversRoster() throws {
        let (founder, fid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: fid) }
        let (second, sid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: sid) }
        let (target, tid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: tid) }
        let meshID = UUID()
        var verifier = try seeded(founder: founder, others: [second, target], meshID: meshID)
        #expect(verifier.roster.quorumThreshold == 2)

        let short = try SignedRemovalRecord.signed(
            meshID: meshID,
            identity: founder,
            memberFingerprint: target.localFingerprint,
            proposalID: MeshMembershipEventFixtures.proposalID,
            voterFingerprints: [founder.localFingerprint]
        )
        #expect(verifier.insert(short) == .quorumNotMet(required: 2, presented: 1))

        let selfVote = try SignedRemovalRecord.signed(
            meshID: meshID,
            identity: founder,
            memberFingerprint: target.localFingerprint,
            proposalID: MeshMembershipEventFixtures.proposalID,
            voterFingerprints: [founder.localFingerprint, target.localFingerprint]
        )
        #expect(verifier.insert(selfVote) == .voterNotEligible)

        let complete = try SignedRemovalRecord.signed(
            meshID: meshID,
            identity: founder,
            memberFingerprint: target.localFingerprint,
            proposalID: MeshMembershipEventFixtures.proposalID,
            voterFingerprints: [founder.localFingerprint, second.localFingerprint]
        )
        #expect(verifier.insert(complete) == nil)
        #expect(!verifier.roster.contains(fingerprint: target.localFingerprint))
    }

    /// A cited voter who is not on the receiver's roster is not evidence. The record is refused
    /// whether the voter is a stranger the mesh never admitted or a member who has since left —
    /// quorum is arithmetic over the roster the RECEIVER derives, at the moment it derives it.
    @Test func aRemovalCitingANonMemberVoterIsRefused() throws {
        let (founder, fid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: fid) }
        let (second, sid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: sid) }
        let (target, tid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: tid) }
        let meshID = UUID()
        var verifier = try seeded(founder: founder, others: [second, target], meshID: meshID)

        let stranger = try SignedRemovalRecord.signed(
            meshID: meshID,
            identity: founder,
            memberFingerprint: target.localFingerprint,
            proposalID: MeshMembershipEventFixtures.proposalID,
            voterFingerprints: [founder.localFingerprint, "fp-never-admitted"]
        )
        #expect(verifier.insert(stranger) == .voterNotEligible)

        // The same is true of a voter who WAS a member: the departure subtracted them, so their
        // vote no longer counts towards a quorum evaluated after it.
        #expect(verifier.insert(try SignedDepartureRecord.signed(meshID: meshID, identity: second)) == nil)
        let departedVoter = try SignedRemovalRecord.signed(
            meshID: meshID,
            identity: founder,
            memberFingerprint: target.localFingerprint,
            proposalID: MeshMembershipEventFixtures.proposalID,
            voterFingerprints: [founder.localFingerprint, second.localFingerprint]
        )
        #expect(verifier.insert(departedVoter) == .voterNotEligible)
        #expect(verifier.ledger.removals.isEmpty)
    }

    /// A re-gossiped removal is the NORMAL case (plan §10.5), so replaying one must be free: the
    /// set dedups by removed member, and the roster it derives does not move a second time. If it
    /// did, every re-gossip on every later connect would spend a rotation.
    @Test func aReplayedRemovalIsDedupedRatherThanCountedTwice() throws {
        let (founder, fid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: fid) }
        let (second, sid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: sid) }
        let (target, tid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: tid) }
        let meshID = UUID()
        var verifier = try seeded(founder: founder, others: [second, target], meshID: meshID)

        let record = try SignedRemovalRecord.signed(
            meshID: meshID,
            identity: founder,
            memberFingerprint: target.localFingerprint,
            proposalID: MeshMembershipEventFixtures.proposalID,
            voterFingerprints: [founder.localFingerprint, second.localFingerprint]
        )
        #expect(verifier.insert(record) == nil)
        let rosterAfterFirst = verifier.roster
        #expect(verifier.insert(record) == nil, "a re-gossiped record is not an error")
        #expect(verifier.ledger.removals.count == 1, "and it does not spend a second of sixteen slots")
        #expect(verifier.roster == rosterAfterFirst, "so the roster does not move twice")
    }

    /// A termination from somebody who is not a member must not be able to end the mesh.
    @Test func aTerminationMustComeFromAMember() throws {
        let (founder, fid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: fid) }
        let (member, mid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: mid) }
        let (stranger, sid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: sid) }
        let meshID = UUID()
        var verifier = try seeded(founder: founder, others: [member], meshID: meshID)

        let outsider = try SignedTerminationRecord.signed(
            meshID: meshID, identity: stranger, rosterAtSigning: [])
        #expect(verifier.insert(outsider) == .signerNotAdmitted)
        #expect(verifier.roster.status == .active)

        let real = try SignedTerminationRecord.signed(
            meshID: meshID,
            identity: member,
            rosterAtSigning: [founder.localFingerprint, member.localFingerprint]
        )
        #expect(verifier.insert(real) == nil)
        #expect(verifier.roster.status == .terminated)
    }

    /// A signed digest verifies, and the same records on both sides compare equal (plan §10.5).
    @Test func anInventoryDigestVerifiesAndCompares() throws {
        let (founder, fid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: fid) }
        let (member, mid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: mid) }
        let meshID = UUID()
        let verifier = try seeded(founder: founder, others: [member], meshID: meshID)

        let payload = try MeshInventoryDigestPayload.signed(
            meshID: meshID,
            ledger: verifier.ledger,
            identity: member,
            sentAt: MeshMembershipEventFixtures.base
        )
        #expect(verifier.verify(payload) == nil)
        #expect(verifier.matchesLocalInventory(payload.digest))

        let stale = MeshInventoryDigestPayload.signedForTestingWithTamperedDigest(payload)
        #expect(verifier.verify(stale) == .signatureInvalid)
    }

    /// A merge imports records ONE AT A TIME through the same door — a peer that forged one record
    /// must not be able to import all of them by handing over a whole ledger.
    @Test func mergingAPeersLedgerVerifiesEveryRecord() throws {
        let (founder, fid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: fid) }
        let (member, mid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: mid) }
        let meshID = UUID()
        var verifier = try seeded(founder: founder, others: [member], meshID: meshID)

        var hostile = MeshMembershipLedger.empty
        hostile.departures = MeshMembershipRecordSet([SignedDepartureRecord(
            meshID: meshID,
            memberFingerprint: founder.localFingerprint,
            occurredAt: Date(timeIntervalSince1970: 1),
            signature: Data(repeating: 0x11, count: 64)
        )])
        let rejections = verifier.merge(hostile)
        #expect(rejections == [.signatureInvalid])
        #expect(verifier.roster.memberCount == 2)
    }
}

// MARK: - Test-only helper

extension MeshInventoryDigestPayload {
    /// The same signed payload with a DIFFERENT digest spliced in — the shape a relay would take
    /// if it tried to rewrite a peer's inventory claim while re-gossiping it.
    static func signedForTestingWithTamperedDigest(
        _ payload: MeshInventoryDigestPayload
    ) -> MeshInventoryDigestPayload {
        MeshInventoryDigestPayload(
            digest: MeshInventoryDigest(
                meshID: payload.digest.meshID,
                admissionCount: payload.digest.admissionCount + 1,
                departureCount: payload.digest.departureCount,
                removalCount: payload.digest.removalCount,
                terminationCount: payload.digest.terminationCount,
                recordsHash: payload.digest.recordsHash
            ),
            senderFingerprint: payload.senderFingerprint,
            sentAt: payload.sentAt,
            signature: payload.signature
        )
    }
}

// MARK: - Legacy goodbye interop

/// `fernlet.session.bye.v1`: parsed, never emitted, and never a departure (plan §8.2, §8.3).
@Suite(.serialized)
struct MeshLegacyGoodbyeInteropTests {

    @Test func aGoodbyeOnlyMeansTheLinkIsGone() {
        #expect(MeshMembershipGoodbyeInterop.outcome(forGoodbyeFrom: "fp001") == .disconnected)
        #expect(MeshMembershipGoodbyeInterop.outcome(forGoodbyeFrom: nil) == .disconnected)
    }

    /// The claim this whole decision rests on. Departures are grow-only and permanent, so an
    /// unsigned frame that could mint one would let anybody reachable on the link evict a member
    /// from a signed roster with no way to undo it.
    @Test func aGoodbyeCannotProduceADepartureRecord() {
        #expect(MeshMembershipGoodbyeInterop.departureRecord(forGoodbyeFrom: "fp001") == nil)
        #expect(MeshMembershipGoodbyeInterop.departureRecord(forGoodbyeFrom: nil) == nil)
    }

    /// The token stays frozen and parked: a retired wire spelling must never be re-used for a
    /// different meaning, and the new departure token is a different string.
    @Test func theGoodbyeTokenStaysFrozenAndDistinct() {
        #expect(MeshMembershipGoodbyeInterop.payloadType.rawValue == "fernlet.session.bye.v1")
        #expect(
            MeshMembershipGoodbyeInterop.payloadType.rawValue != PayloadType.meshMemberDeparture.rawValue
        )
    }

    /// No shipping code path emits it any more. A grep-wall rather than a behavioural test,
    /// because "did not send" is otherwise only visible with two radios in a room.
    @Test func noShippingSourceEmitsAGoodbye() throws {
        var offenders: [String] = []
        for url in try CryptographicWallScan.sourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            for line in source.components(separatedBy: .newlines)
            where line.contains("sendEnvelope(.sessionGoodbye") {
                offenders.append(CryptographicWallScan.repoRelativePath(url))
            }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) shipping source file(s) still EMIT `.sessionGoodbye`. It is parsed,
            never emitted (plan §8.3): membership ends via a signed departure or removal record,
            and an unsigned goodbye can only mean the link went away:
            \(offenders.sorted().joined(separator: "\n"))
            """
        )
    }
}

// MARK: - The removal frame on the manager

/// P3 item 3b (plan §8.3, §10.4): `fernlet.mesh.member-removal.v1` end to end.
///
/// Item 5 mints a removal record where the vote completes and files it locally; item 3 framed the
/// other three record kinds. This suite walls the fourth frame's two directions and the one edge
/// item 6 could not wire:
///
/// 1. **The removed member is not sent the record.** Exclusion is computed by item 5's own
///    key-distribution rule, so "who gets the new key" and "who is told why" cannot drift apart.
/// 2. **A received record is verified, made durable, and only then counted** — and if it names this
///    device, it ends this device's session (plan §8.2's `removed` edge).
/// 3. **The legacy `.meshRemovalSecond` path still agrees.** It is the interim exclusion authority
///    until item 7, so the two must never disagree about who is out.
@MainActor
@Suite(.serialized)
struct MeshMemberRemovalFrameTests {

    let store = makeTestStore()

    /// A pinned install identity, so every seal in this suite is deterministic.
    private static let install = Data(repeating: 0x3B, count: 16)

    // MARK: Fixtures

    private func makeIdentity() throws -> (IdentityService, String) {
        let id = "com.fernlet.mesh-removal-frame.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: id)
        try service.ensureProvisioned()
        return (service, id)
    }

    private func makeMesh(_ manager: MeshNetworkManager) -> MeshDescriptor {
        let now = Date()
        let local = MeshMember(
            fingerprint: manager.identityForTesting.localFingerprint,
            displayName: "Local",
            signingPublicKey: manager.identityForTesting.localSigningPublicKey,
            keyAgreementPublicKey: manager.identityForTesting.localKeyAgreementPublicKey,
            joinedAt: now
        )
        return MeshDescriptor(
            meshID: UUID(),
            name: "Removal Meadow",
            mode: .open,
            members: [local],
            nameSetAt: now,
            nameSetBy: local.fingerprint,
            modeSetAt: now,
            modeSetBy: local.fingerprint,
            createdAt: now
        )
    }

    /// A ledger admitting `founder` (by itself) and every identity in `others` (by the founder) —
    /// the roster a removal's quorum is re-derived against.
    private func ledger(
        founder: IdentityService,
        others: [IdentityService],
        meshID: UUID
    ) throws -> MeshMembershipLedger {
        var built = MeshMembershipLedger.empty
        for member in [founder] + others {
            built.admissions = built.admissions.inserting(
                SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
                    meshID: meshID,
                    joinerFingerprint: member.localFingerprint,
                    joinerSigningPublicKey: member.localSigningPublicKey,
                    admitterIdentity: founder
                ))
            )
        }
        return built
    }

    /// A coordinator with no live dependencies, for slots this suite only needs to exist.
    private static func throwawayCoordinator() -> ProximityCoordinator {
        ProximityCoordinator(
            identity: IdentityService(keychainService: "test.mesh.removal-frame.\(UUID().uuidString)"),
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            inspector: nil,
            replayCache: ReplayCache(),
            foregroundAnchor: nil,
            displayName: "Local",
            timeoutSeconds: 0
        )
    }

    /// Attaches a COMMITTED slot for `fingerprint` and returns the coordinator that owns it, which
    /// is how the real dispatch entry point finds the slot a frame arrived on.
    @discardableResult
    private func attachSlot(to manager: MeshNetworkManager, fingerprint: String) -> ProximityCoordinator {
        let coordinator = Self.throwawayCoordinator()
        manager.addSlotForTesting(
            coordinator: coordinator,
            peer: PeerHandle(
                id: UUID(),
                displayHint: "iPhone",
                discoveryInfo: ["v": "1"],
                advertisedFingerprint: fingerprint,
                endpoint: PeerEndpointKey()
            ),
            fingerprint: fingerprint
        )
        return coordinator
    }

    /// Delivers a removal frame through the REAL receive entry point, under a pinned install so the
    /// seal the receive path owes can actually be written.
    ///
    /// - Parameter binding: The device-binding behaviour to deliver under; nil is the pinned,
    ///   sealable install. (A default argument cannot name ``install`` — a `@MainActor` type's
    ///   static member is not available as a default-argument value.)
    private func deliver(
        _ record: SignedRemovalRecord,
        to manager: MeshNetworkManager,
        from sender: IdentityService,
        over coordinator: ProximityCoordinator,
        binding: DeviceBindingID.TestOverride? = nil
    ) throws {
        let plaintext = try JSONEncoder().encode(MeshMemberRemovalPayload(record: record))
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: sender,
            senderDisplayName: "Peer",
            payloadType: .meshMemberRemoval,
            payloadSummary: PayloadSummary(title: "Removal"),
            payload: plaintext
        )
        DeviceBindingID.$testOverride.withValue(binding ?? .identifier(Self.install)) {
            manager.proximityCoordinator(
                coordinator, didReceive: envelope, plaintext: plaintext, from: nil
            )
        }
    }

    /// Reads the sealed context back, under the same pinned install everything here writes with.
    private func loadContext() -> MeshSessionContext? {
        let sessionStore = MeshSessionStore(scope: store.meshSessionStorage)
        let load = DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            sessionStore.load()
        }
        guard case .loaded(let context, _) = load else { return nil }
        return context
    }

    // MARK: Bounds (plan §9)

    /// A frame carrying more voters than the mesh can hold is CLAMPED on decode, not trimmed after
    /// it is trusted and never a trap — and because the clamp changes the bytes the tallier signed,
    /// the padded record is then refused outright rather than crediting an inflated quorum.
    @Test func aPaddedVoterListIsClampedOnDecodeAndThenRefused() throws {
        let (founder, fid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: fid) }
        let (second, sid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: sid) }
        let (target, tid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: tid) }
        let meshID = UUID()

        let honest = try SignedRemovalRecord.signed(
            meshID: meshID,
            identity: founder,
            memberFingerprint: target.localFingerprint,
            proposalID: MeshMembershipEventFixtures.proposalID,
            voterFingerprints: [founder.localFingerprint, second.localFingerprint]
        )
        let padded = SignedRemovalRecord(
            meshID: meshID,
            memberFingerprint: honest.memberFingerprint,
            proposalID: honest.proposalID,
            voterFingerprints: (0..<99).map { "fp-pad-\($0)" },
            occurredAt: honest.occurredAt,
            authorFingerprint: honest.authorFingerprint,
            signature: honest.signature
        )
        // The initializer already clamped; the DECODE of a hostile frame must clamp too, which a
        // synthesized `Codable` would not have done.
        let wire = try JSONEncoder().encode(MeshMemberRemovalPayload(record: padded))
        let decoded = try JSONDecoder().decode(MeshMemberRemovalPayload.self, from: wire)
        #expect(decoded.record.voterFingerprints.count == MeshMembershipBounds.maxVoters)

        var verifier = MeshMembershipRecordVerifier(
            meshID: meshID, founderSigningPublicKey: founder.localSigningPublicKey,
            ledger: try ledger(founder: founder, others: [second, target], meshID: meshID)
        )
        #expect(verifier.insert(decoded.record) == .voterNotEligible)
        #expect(verifier.ledger.removals.isEmpty)
    }

    // MARK: Emission

    /// The removed member is not sent the record that removes them (plan §8.3): they learn of it as
    /// a key that no longer opens anything. Every other committed member is.
    @Test func theRemovalFrameExcludesTheRemovedMember() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeMesh(manager)
        attachSlot(to: manager, fingerprint: "fp-target")
        attachSlot(to: manager, fingerprint: "fp-witness")

        let recipients = manager.membershipEventRecipients(excluding: "fp-target")

        #expect(!recipients.contains("fp-target"), "the removed member must not receive the record")
        #expect(recipients.contains("fp-witness"), "every other member must")
        #expect(recipients.contains(manager.identityForTesting.localFingerprint),
                "and this device is always in the set the key distribution uses")
        manager.leaveMesh()
    }

    /// The vote completing puts the signed record on the wire — the gap item 5 named and left open,
    /// where peers learned of a removal only from the legacy broadcast and the descriptor.
    @Test func aCompletedVoteBroadcastsTheSignedRecord() async {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeMesh(manager)
        attachSlot(to: manager, fingerprint: "fp-witness")
        var emitted: [PayloadType] = []
        manager.onMembershipEventSentForTesting = { emitted.append($0) }

        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.secondRemoval(MeshRemovalProposalPayload(
                id: UUID(),
                targetFingerprint: "fp-target",
                targetDisplayName: "Target",
                proposerFingerprint: "fp-proposer",
                proposerDisplayName: "Proposer",
                createdAt: Date(),
                expiresAt: Date().addingTimeInterval(60)
            ))
        }
        // The emit is fire-and-forget on a task, so let the main actor drain it. Bounded, and it
        // completes in a hop or two — the yields are a settle, never a timeout.
        var yields = 0
        while emitted.isEmpty, yields < 100 {
            await Task.yield()
            yields += 1
        }

        #expect(emitted == [.meshMemberRemoval],
                "a completed removal now ships its record, not only the legacy second")
        manager.leaveMesh()
    }

    /// Both removal paths agree on who is out. The legacy `.meshRemovalSecond` vote is the interim
    /// exclusion authority until item 7 and the signed record is the durable one; a mesh in which
    /// they disagreed would exclude a member from the key and keep them on the roster, or worse.
    @Test func theLegacyPathAndTheRecordAgreeOnExclusion() {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeMesh(manager)
        attachSlot(to: manager, fingerprint: "fp-target")

        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.secondRemoval(MeshRemovalProposalPayload(
                id: UUID(),
                targetFingerprint: "fp-target",
                targetDisplayName: "Target",
                proposerFingerprint: "fp-proposer",
                proposerDisplayName: "Proposer",
                createdAt: Date(),
                expiresAt: Date().addingTimeInterval(60)
            ))
        }

        #expect(manager.removedMemberFingerprints.contains("fp-target"),
                "the legacy path still records the exclusion")
        #expect(!manager.membershipEventRecipients(excluding: "fp-other").contains("fp-target"),
                "and the record path excludes exactly the same member")
        #expect(manager.rotationTriggers.pendingCause == .membership,
                "a completed removal still rotates the key at once")
        manager.leaveMesh()
    }

    // MARK: Reception

    /// A verified removal from a peer inserts, reaches the disk, moves the roster and rotates —
    /// the whole receive contract for a member who is not the one being removed.
    @Test func aReceivedRemovalInsertsPersistsAndRotates() throws {
        let manager = MeshNetworkManager(store: store)
        let mesh = makeMesh(manager)
        manager.currentMesh = mesh
        let (founder, fid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: fid) }
        let (target, tid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: tid) }
        manager.seedMembershipLedgerForTesting(
            meshID: mesh.meshID,
            founderSigningPublicKey: founder.localSigningPublicKey,
            ledger: try ledger(
                founder: founder, others: [manager.identityForTesting, target], meshID: mesh.meshID
            )
        )
        #expect(manager.membershipVerifier?.roster.memberCount == 3)
        let coordinator = attachSlot(to: manager, fingerprint: founder.localFingerprint)

        let record = try SignedRemovalRecord.signed(
            meshID: mesh.meshID,
            identity: founder,
            memberFingerprint: target.localFingerprint,
            proposalID: MeshMembershipEventFixtures.proposalID,
            voterFingerprints: [founder.localFingerprint, manager.identityForTesting.localFingerprint]
        )
        try deliver(record, to: manager, from: founder, over: coordinator)

        #expect(manager.membershipVerifier?.ledger.removals.count == 1)
        #expect(manager.membershipVerifier?.roster.contains(fingerprint: target.localFingerprint) == false)
        #expect(loadContext()?.ledger.removals.count == 1, "the record is on the disk, not only in RAM")
        #expect(manager.rotationTriggers.pendingCause == .membership,
                "a roster move rotates as `membership` (plan §8.3)")
        #expect(manager.sessionState != .departed, "somebody else's removal is not this device's")
        manager.leaveMesh()
    }

    /// Durable before acknowledged (plan §3.6): a seal the store refuses rolls the record back out
    /// of the ledger, and the rotation it would have caused never fires.
    @Test func aRemovalTheStoreCannotSealIsNotAcknowledged() throws {
        let manager = MeshNetworkManager(store: store)
        let mesh = makeMesh(manager)
        manager.currentMesh = mesh
        let (founder, fid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: fid) }
        let (target, tid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: tid) }
        manager.seedMembershipLedgerForTesting(
            meshID: mesh.meshID,
            founderSigningPublicKey: founder.localSigningPublicKey,
            ledger: try ledger(
                founder: founder, others: [manager.identityForTesting, target], meshID: mesh.meshID
            )
        )
        let coordinator = attachSlot(to: manager, fingerprint: founder.localFingerprint)

        let record = try SignedRemovalRecord.signed(
            meshID: mesh.meshID,
            identity: founder,
            memberFingerprint: target.localFingerprint,
            proposalID: MeshMembershipEventFixtures.proposalID,
            voterFingerprints: [founder.localFingerprint, manager.identityForTesting.localFingerprint]
        )
        try deliver(record, to: manager, from: founder, over: coordinator, binding: .unavailable)

        #expect(manager.membershipVerifier?.ledger.removals.isEmpty == true,
                "a record that could not be written down is not inserted for roster purposes")
        #expect(manager.membershipVerifier?.roster.contains(fingerprint: target.localFingerprint) == true)
        #expect(manager.rotationTriggers.pendingCause == nil,
                "and the rotation it would have caused must not fire")
        manager.leaveMesh()
    }

    /// The edge item 6 built and could not wire: a verified record naming THIS device ends its
    /// membership. State `departed`, the durable mark written, the rejoin bar up, participation
    /// stopped — and the mesh carries on without it, which is why it is not `terminated`.
    @Test func aReceivedRemovalNamingThisDeviceEndsItsSession() throws {
        let manager = MeshNetworkManager(store: store)
        let mesh = makeMesh(manager)
        manager.currentMesh = mesh
        let (founder, fid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: fid) }
        let (second, sid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: sid) }
        manager.seedMembershipLedgerForTesting(
            meshID: mesh.meshID,
            founderSigningPublicKey: founder.localSigningPublicKey,
            ledger: try ledger(
                founder: founder, others: [second, manager.identityForTesting], meshID: mesh.meshID
            )
        )
        let coordinator = attachSlot(to: manager, fingerprint: founder.localFingerprint)
        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
        }

        let record = try SignedRemovalRecord.signed(
            meshID: mesh.meshID,
            identity: founder,
            memberFingerprint: manager.identityForTesting.localFingerprint,
            proposalID: MeshMembershipEventFixtures.proposalID,
            voterFingerprints: [founder.localFingerprint, second.localFingerprint]
        )
        try deliver(record, to: manager, from: founder, over: coordinator)

        #expect(manager.sessionState == .departed,
                "a verified removal of this device is terminal for this device only")
        #expect(manager.rejoinBar?.reason == .removedFromRoster, "and the rejoin bar names why")
        #expect(loadContext()?.localTermination?.reason == .removedFromRoster,
                "the ending mark is on the disk before the teardown")
        #expect(manager.currentMesh == nil, "participation is torn down, as the legacy path does")
        #expect(manager.slots.isEmpty, "and the links with it")
    }
}
