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
//
// Since the re-pin to ProximityKit 0.1.1 (2026-10-17) claim 3's suite, `MeshMembershipRecordVerifierTests`,
// and the removal frame's on the manager, `MeshMemberRemovalFrameTests`, are ProximityKit's package
// suites of the same names and cells, which its own CI runs; the goldens, the inventory digest and the
// legacy goodbye's interop stay here.

import FernletConnections
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

    /// The two divergent branch heads the epoch-head vector carries: one counter, two minting
    /// coordinators — the only shape a merge actually has to reconcile (plan §10.3).
    ///
    /// Built through ``MeshEpochRef/minted(counter:coordinatorFingerprint:meshID:)`` so the ids in
    /// the pinned hex are the *derived* ones a real branch would compute, not literals a test made
    /// up: a change to the epoch-id derivation must move this golden.
    static func divergentHeads() -> [MeshEpochRef] {
        [
            MeshEpochRef.minted(counter: 7, coordinatorFingerprint: "00000000000000aa", meshID: meshID),
            MeshEpochRef.minted(counter: 7, coordinatorFingerprint: "00000000000000bb", meshID: meshID)
        ].compactMap { $0 }
    }

    /// The `fernlet.mesh.epoch-heads.v1` frame's payload (P4 item 3).
    static func epochHeadsPayload() -> MeshEpochHeadsPayload {
        MeshEpochHeadsPayload(
            meshID: meshID,
            heads: divergentHeads(),
            senderFingerprint: "fp001",
            sentAt: base.addingTimeInterval(300),
            signature: opaqueSignature
        )
    }

    /// P4 item 5's proposal id — a third one, so the quorum vectors are their own records rather
    /// than variants of the two the removal goldens already pinned.
    static let quorumProposalID = UUID(uuidString: "4E4E4E4E-5F5F-4A4A-9B9B-2C2C2C2C2C2C") ?? UUID()

    /// The `fernlet.mesh.removal-proposal.v1` frame (plan §10.4). Its target is the same `fp004`
    /// the removal record names, so the three vectors read as one story: propose, vote, complete.
    static func removalProposal() -> SignedRemovalProposal {
        SignedRemovalProposal(
            meshID: meshID,
            proposalID: quorumProposalID,
            targetFingerprint: "fp004",
            proposerFingerprint: "fp001",
            issuedAt: base.addingTimeInterval(360),
            signature: opaqueSignature
        )
    }

    /// The `fernlet.mesh.removal-vote.v1` frame: `fp002` agreeing with the proposal above.
    static func removalVote() -> SignedRemovalVote {
        SignedRemovalVote(
            meshID: meshID,
            proposalID: quorumProposalID,
            targetFingerprint: "fp004",
            voterFingerprint: "fp002",
            castAt: base.addingTimeInterval(420),
            signature: opaqueSignature
        )
    }

    /// The 32-byte key-agreement public key the P6 item 1 vector advertises. A fixed pattern, and
    /// deliberately not the signature blob's `0xAB`, so a transposed field would move the golden.
    static let keyAgreementKey = Data(
        repeating: 0x5A, count: MeshMembershipEventFormat.keyAgreementByteCount
    )

    /// The `fernlet.mesh.key-agreement.v1` statement (P6 item 1): `fp001` naming its own durable
    /// key-agreement public key. `advertisedAt` continues the same one-minute story the records
    /// above tell, so every byte in the pinned hex is traceable to a line here.
    static func keyAdvertisement() -> SignedKeyAgreementAdvertisement {
        SignedKeyAgreementAdvertisement(
            meshID: meshID,
            memberFingerprint: "fp001",
            keyAgreementPublicKey: keyAgreementKey,
            advertisedAt: base.addingTimeInterval(480),
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

    /// P4 item 3's vector: two divergent branch heads at one counter, derived by the same
    /// independent Python re-implementation of the FORMAT that minted
    /// ``goldenRemovalAtVoterCapHex`` — and proved honest the same way, by first reproducing
    /// ``goldenInventoryHex`` byte-for-byte before minting this one.
    ///
    /// The frame is **additive**: it has its own token, its own registered signature domain and its
    /// own golden, and no vector above it moves. Widening the inventory digest to carry heads would
    /// have moved ``goldenInventoryHex``, which is a wire decision rather than a merge fix.
    static let goldenEpochHeadsHex = "000000000000001b6665726e6c65742e6d6573682e65706f63682d68656164732e76311f1f1f1f2e2e4d4d8c8c0b0b0b0b0b0b00000000000000056670303031000000006553f22c00000000000000020000000000000033372e33353563383737613338333466663262396238366230373466636361663265372e303030303030303030303030303061610000000000000033372e64613561343166343766666635343264326163616631323630616230316433312e30303030303030303030303030306262"

    /// P4 item 5's vectors: the signed proposal and the signed vote, derived by the same
    /// independent Python re-implementation of the FORMAT that minted ``goldenEpochHeadsHex`` —
    /// length-prefixed domain, 16 raw UUID bytes, length-prefixed UTF-8 strings, an i64
    /// floored-seconds date, signature excluded — and proved honest the same way, by first
    /// reproducing ``goldenRemovalHex`` byte-for-byte before either of these was minted.
    ///
    /// Both frames are **additive**. Nothing above them moves: the completed removal's canonical
    /// bytes are untouched by item 5, which is the point of giving the live quorum its own two
    /// domains instead of widening the record everybody has already pinned.
    static let goldenRemovalProposalHex = "00000000000000206665726e6c65742e6d6573682e72656d6f76616c2d70726f706f73616c2e76311f1f1f1f2e2e4d4d8c8c0b0b0b0b0b0b4e4e4e4e5f5f4a4a9b9b2c2c2c2c2c2c0000000000000005667030303400000000000000056670303031000000006553f268"

    static let goldenRemovalVoteHex = "000000000000001c6665726e6c65742e6d6573682e72656d6f76616c2d766f74652e76311f1f1f1f2e2e4d4d8c8c0b0b0b0b0b0b4e4e4e4e5f5f4a4a9b9b2c2c2c2c2c2c0000000000000005667030303400000000000000056670303032000000006553f2a4"

    /// P6 item 1's vector: a member's own signed key-agreement public key, derived by the same
    /// independent re-implementation of the FORMAT that minted ``goldenEpochHeadsHex`` —
    /// length-prefixed domain, 16 raw UUID bytes, length-prefixed UTF-8 strings, a length-prefixed
    /// OPAQUE 32-byte key, an i64 floored-seconds date, signature excluded — and proved honest the
    /// same way: that re-implementation first parsed and re-emitted ``goldenEpochHeadsHex`` and
    /// reproduced ``goldenInventoryHex`` byte-for-byte, and only then minted this one.
    ///
    /// The frame is **additive**. Nothing above it moves, and nothing above it could: an
    /// advertisement is not a ``MeshMembershipRecord``, so it cannot enter the membership digest's
    /// kind-tagged flattening even by accident — which is what keeps ``goldenInventoryHex`` and
    /// ``goldenRecordsHashHex`` still.
    static let goldenKeyAgreementHex = "000000000000001d6665726e6c65742e6d6573682e6b65792d61677265656d656e742e76311f1f1f1f2e2e4d4d8c8c0b0b0b0b0b0b0000000000000005667030303100000000000000205a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a000000006553f2e0"

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

    /// P6 item 1's vector.
    @Test func aKeyAgreementAdvertisementIsGoldenStable() {
        let advertisement = MeshMembershipEventFixtures.keyAdvertisement()
        #expect(
            advertisement.keyAgreementPublicKey.count == MeshMembershipEventFormat.keyAgreementByteCount,
            "the vector must carry the format's fixed key width"
        )
        let actual = MeshMembershipEventFixtures.hex(canonicalBytes(for: advertisement))
        #expect(actual == Self.goldenKeyAgreementHex, "actual key-agreement golden hex = \(actual)")
    }

    /// The signature is the OUTPUT of signing these bytes, so it cannot be one of them. Asserted
    /// directly rather than inferred from the golden, because Ed25519 signing is hedged: two
    /// signatures over the same advertisement differ, and any comparison of signed records by full
    /// `==` would be a flake waiting for a re-sign.
    @Test func aKeyAgreementAdvertisementExcludesItsOwnSignature() {
        let advertisement = MeshMembershipEventFixtures.keyAdvertisement()
        let reSigned = SignedKeyAgreementAdvertisement(
            meshID: advertisement.meshID,
            memberFingerprint: advertisement.memberFingerprint,
            keyAgreementPublicKey: advertisement.keyAgreementPublicKey,
            advertisedAt: advertisement.advertisedAt,
            signature: Data(repeating: 0x11, count: MeshMembershipEventFormat.signatureByteCount)
        )
        #expect(canonicalBytes(for: reSigned) == canonicalBytes(for: advertisement))
        #expect(reSigned != advertisement, "the two values differ; only their transcripts match")
    }

    /// Every field the transcript binds, moved one at a time. A field that is bound but *not*
    /// bound distinctly — the fingerprint and the key transposed, say — would pass a
    /// "the golden is stable" test and still let a relay rewrite the pair.
    @Test func everyBoundKeyAgreementFieldMovesTheTranscript() {
        let base = MeshMembershipEventFixtures.keyAdvertisement()
        let golden = canonicalBytes(for: base)
        let variants = [
            SignedKeyAgreementAdvertisement(
                meshID: MeshMembershipEventFixtures.proposalID,
                memberFingerprint: base.memberFingerprint,
                keyAgreementPublicKey: base.keyAgreementPublicKey,
                advertisedAt: base.advertisedAt, signature: base.signature
            ),
            SignedKeyAgreementAdvertisement(
                meshID: base.meshID, memberFingerprint: "fp002",
                keyAgreementPublicKey: base.keyAgreementPublicKey,
                advertisedAt: base.advertisedAt, signature: base.signature
            ),
            SignedKeyAgreementAdvertisement(
                meshID: base.meshID, memberFingerprint: base.memberFingerprint,
                keyAgreementPublicKey: Data(
                    repeating: 0x5B, count: MeshMembershipEventFormat.keyAgreementByteCount
                ),
                advertisedAt: base.advertisedAt, signature: base.signature
            ),
            SignedKeyAgreementAdvertisement(
                meshID: base.meshID, memberFingerprint: base.memberFingerprint,
                keyAgreementPublicKey: base.keyAgreementPublicKey,
                advertisedAt: base.advertisedAt.addingTimeInterval(1), signature: base.signature
            )
        ]
        #expect(variants.count == 4, "one variant per bound field")
        for variant in variants {
            #expect(canonicalBytes(for: variant) != golden)
        }
    }

    /// The frame property a record's own golden cannot prove: the signed bytes survive the wire.
    @Test func aKeyAgreementAdvertisementSurvivesItsOwnWireForm() throws {
        let wire = try JSONEncoder().encode(MeshMembershipEventFixtures.keyAdvertisement())
        let decoded = try JSONDecoder().decode(SignedKeyAgreementAdvertisement.self, from: wire)
        #expect(MeshMembershipEventFixtures.hex(canonicalBytes(for: decoded)) == Self.goldenKeyAgreementHex)
    }

    @Test func anInventoryDigestMessageIsGoldenStable() {
        let payload = MeshMembershipEventFixtures.inventoryPayload()
        let hashHex = MeshMembershipEventFixtures.hex(payload.digest.recordsHash)
        #expect(hashHex == Self.goldenRecordsHashHex, "actual records hash hex = \(hashHex)")
        let actual = MeshMembershipEventFixtures.hex(canonicalBytes(for: payload))
        #expect(actual == Self.goldenInventoryHex, "actual inventory golden hex = \(actual)")
    }

    /// P4 item 3's frame, pinned. The heads' canonical strings are what the transcript carries, so
    /// a change to ``MeshEpochRef/canonicalString`` or to the epoch-id derivation moves this
    /// vector — which is exactly the alarm a silently re-spelled epoch name should raise.
    @Test func anEpochHeadsMessageIsGoldenStable() {
        let payload = MeshMembershipEventFixtures.epochHeadsPayload()
        #expect(payload.heads.count == 2, "the vector needs both branch heads to have minted")
        #expect(payload.isWellFormed)
        let actual = MeshMembershipEventFixtures.hex(canonicalBytes(for: payload))
        #expect(actual == Self.goldenEpochHeadsHex, "actual epoch-heads golden hex = \(actual)")
    }

    /// The frame survives the wire with its signed bytes intact — the property a `Codable`
    /// round-trip alone cannot show, and the one that matters because every head is re-parsed from
    /// its canonical string on the way in.
    @Test func anEpochHeadsFramePreservesTheSignedBytesAcrossTheWire() throws {
        let payload = MeshMembershipEventFixtures.epochHeadsPayload()
        let wire = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MeshEpochHeadsPayload.self, from: wire)
        #expect(decoded == payload)
        #expect(MeshMembershipEventFixtures.hex(canonicalBytes(for: decoded)) == Self.goldenEpochHeadsHex)
    }

    /// P4 item 5's two frames, pinned — and the claim the pinning is *for*: the completed removal's
    /// bytes did not move. A quorum folded into the removal record would have moved
    /// ``goldenRemovalHex``, which is a wire decision, not a merge fix.
    @Test func theRemovalQuorumFramesAreGoldenStable() {
        let proposal = MeshMembershipEventFixtures.removalProposal()
        let vote = MeshMembershipEventFixtures.removalVote()
        #expect(proposal.isWellFormed)
        #expect(vote.isWellFormed)
        let proposalHex = MeshMembershipEventFixtures.hex(canonicalBytes(for: proposal))
        let voteHex = MeshMembershipEventFixtures.hex(canonicalBytes(for: vote))
        #expect(proposalHex == Self.goldenRemovalProposalHex, "actual proposal golden hex = \(proposalHex)")
        #expect(voteHex == Self.goldenRemovalVoteHex, "actual vote golden hex = \(voteHex)")
        #expect(
            MeshMembershipEventFixtures.hex(canonicalBytes(for: MeshMembershipEventFixtures.removal()))
                == Self.goldenRemovalHex,
            "the completed removal record's bytes are untouched by item 5"
        )
    }

    /// Both quorum frames survive the wire with their signed bytes intact.
    @Test func theRemovalQuorumFramesPreserveTheSignedBytesAcrossTheWire() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let proposal = try decoder.decode(
            SignedRemovalProposal.self,
            from: try encoder.encode(MeshMembershipEventFixtures.removalProposal())
        )
        let vote = try decoder.decode(
            SignedRemovalVote.self, from: try encoder.encode(MeshMembershipEventFixtures.removalVote())
        )
        #expect(proposal == MeshMembershipEventFixtures.removalProposal())
        #expect(vote == MeshMembershipEventFixtures.removalVote())
        #expect(MeshMembershipEventFixtures.hex(canonicalBytes(for: proposal)) == Self.goldenRemovalProposalHex)
        #expect(MeshMembershipEventFixtures.hex(canonicalBytes(for: vote)) == Self.goldenRemovalVoteHex)
    }

    /// The proposal, the vote and the completed record are three domains, not one.
    ///
    /// The pairing that matters is proposal↔vote: they are the SAME field shape with the author in
    /// the same position, so only the domain keeps them apart. If a vote's transcript satisfied the
    /// proposal domain, one member could re-point somebody else's proposal at a different target.
    @Test func theQuorumFramesEachGetTheirOwnDomain() {
        let proposal = canonicalBytes(for: MeshMembershipEventFixtures.removalProposal())
        let vote = canonicalBytes(for: MeshMembershipEventFixtures.removalVote())
        let removal = canonicalBytes(for: MeshMembershipEventFixtures.removal())
        #expect(Set([proposal, vote, removal]).count == 3)

        let proposalPurpose = FernletCryptoPurpose.Signature.meshRemovalProposalV1
        let votePurpose = FernletCryptoPurpose.Signature.meshRemovalVoteV1
        let removalPurpose = FernletCryptoPurpose.Signature.meshMemberRemovalV1
        #expect(proposalPurpose.signingBytes(proposal) != nil)
        #expect(votePurpose.signingBytes(vote) != nil)
        #expect(proposalPurpose.signingBytes(vote) == nil)
        #expect(votePurpose.signingBytes(proposal) == nil)
        #expect(removalPurpose.signingBytes(proposal) == nil)
        #expect(removalPurpose.signingBytes(vote) == nil)
        #expect(proposalPurpose.signingBytes(removal) == nil)
        #expect(votePurpose.signingBytes(removal) == nil)
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

    /// Record kind, wire token and crypto domain are ONE frozen English vocabulary in Fernlet's
    /// namespace: each kind's token in `.fernlet`'s record kinds, read through the kind's own
    /// `token(in:)` as the inventory digest reads it. If they ever diverge, a grep for the token
    /// stops finding the layer that signs it.
    @Test func theTokenVocabularyIsShared() {
        let kinds = ProximityNamespace.fernlet.family.vocabulary.membershipRecordKinds
        #expect(MeshMembershipRecordKind.admission.token(in: kinds) == PayloadType.meshMemberAdmission.rawValue)
        #expect(MeshMembershipRecordKind.departure.token(in: kinds) == PayloadType.meshMemberDeparture.rawValue)
        #expect(MeshMembershipRecordKind.removal.token(in: kinds) == PayloadType.meshMemberRemoval.rawValue)
        #expect(MeshMembershipRecordKind.termination.token(in: kinds) == PayloadType.meshTerminated.rawValue)
        #expect(
            MeshMembershipRecordKind.departure.token(in: kinds)
                == FernletCryptoPurpose.Signature.meshMemberDepartureV1.rawValue
        )
        #expect(
            MeshMembershipRecordKind.removal.token(in: kinds)
                == FernletCryptoPurpose.Signature.meshMemberRemovalV1.rawValue
        )
        #expect(
            MeshMembershipRecordKind.termination.token(in: kinds)
                == FernletCryptoPurpose.Signature.meshTerminatedV1.rawValue
        )
        #expect(
            PayloadType.meshInventoryDigest.rawValue
                == FernletCryptoPurpose.Signature.meshInventoryDigestV1.rawValue
        )
        // P4 item 3's frame joins the same vocabulary: one frozen English spelling across the wire
        // token and the signature domain.
        #expect(
            PayloadType.meshEpochHeads.rawValue
                == FernletCryptoPurpose.Signature.meshEpochHeadsV1.rawValue
        )
        #expect(PayloadType.meshEpochHeads.rawValue == "fernlet.mesh.epoch-heads.v1")
        // P4 item 5's pair, same rule — and the frozen LEGACY pair beside them, which is a
        // different spelling on purpose: dots for the unsigned two-party vote already-shipped
        // builds speak, hyphens for the signed quorum. A grep for either finds exactly one family.
        #expect(
            PayloadType.meshRemovalProposalSigned.rawValue
                == FernletCryptoPurpose.Signature.meshRemovalProposalV1.rawValue
        )
        #expect(
            PayloadType.meshRemovalVote.rawValue
                == FernletCryptoPurpose.Signature.meshRemovalVoteV1.rawValue
        )
        #expect(PayloadType.meshRemovalProposalSigned.rawValue == "fernlet.mesh.removal-proposal.v1")
        #expect(PayloadType.meshRemovalVote.rawValue == "fernlet.mesh.removal-vote.v1")
        #expect(PayloadType.meshRemovalProposal.rawValue == "fernlet.mesh.removal.proposal.v1")
        #expect(PayloadType.meshRemovalSecond.rawValue == "fernlet.mesh.removal.second.v1")
        #expect(PayloadType.meshRemovalProposalSigned != PayloadType.meshRemovalProposal)
        // The admission frame is the one member of the family with NO signing domain of its own:
        // the record it carries is the existing `MeshAdmissionToken`, signed under
        // `meshAdmissionTokenV2`. A domain spelled like the frame would be a second admission
        // format, which is exactly what `SignedAdmissionRecord` exists to avoid.
        #expect(
            PayloadType.meshMemberAdmission.rawValue
                != FernletCryptoPurpose.Signature.meshAdmissionTokenV2.rawValue,
            "the admission frame names a wire token; the record inside it stays signed under meshAdmissionTokenV2"
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
    /// different meaning, and the new departure token is a different string. The rule names the
    /// frame by role; Fernlet's token for it is `.fernlet`'s mesh message.
    @Test func theGoodbyeTokenStaysFrozenAndDistinct() {
        let mesh = ProximityNamespace.fernlet.family.vocabulary.mesh
        #expect(MeshMembershipGoodbyeInterop.payloadType.token(in: mesh) == "fernlet.session.bye.v1")
        #expect(
            MeshMembershipGoodbyeInterop.payloadType.token(in: mesh) != PayloadType.meshMemberDeparture.rawValue
        )
    }

    /// No shipping code path emits it any more. A grep-wall rather than a behavioural test,
    /// because "did not send" is otherwise only visible with two radios in a room.
    ///
    /// Over every shipping root of this repository, floored at 448 files (four fifths of the 561
    /// measured at ProximityKit plan step A1.3), so a walk that lost a root reds rather than passing
    /// on what is left. ProximityKit's own code, which holds the mesh's one sender, is its package
    /// suite of this name's to sweep.
    @Test func noShippingSourceEmitsAGoodbye() throws {
        let files = try CryptographicWallScan.sourceFiles()
        #expect(files.count >= 448, "the goodbye wall read only \(files.count) shipping files")
        var offenders: [String] = []
        for url in files {
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
