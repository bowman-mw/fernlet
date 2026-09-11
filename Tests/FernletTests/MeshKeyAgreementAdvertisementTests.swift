// MeshKeyAgreementAdvertisementTests.swift
// FernletTests
//
// P6 item 1 (plan §11.3 item 13(ii)): the signed key-advertisement family, below the manager.
//
// Four claims are walled here, each one a thing a later pass cannot cheaply re-derive:
//
// 1. **The verifier refuses by name, over the whole table.** Wrong mesh, malformed widths, a
//    non-admitted signer, a departed signer, a removed signer, a tampered key, a tampered instant,
//    a re-stamped mesh id and a cross-domain signature each land on their own frozen name.
// 2. **Verification happens BEFORE any conflict decision.** An unverified advertisement that could
//    mark a fingerprint conflicted would let any peer in radio range permanently un-address any
//    member with a few forged bytes. The negative control is non-negotiable, and the compile fence
//    beneath it is `MeshVerifiedKeyAgreementAdvertisement`'s `fileprivate` initializer.
// 3. **The fold refuses a conflict rather than picking one.** `MeshMembershipRecordSet.merging` is
//    earliest-wins and silently keeps ONE of two rows; for a key that is a fail-open, so the set is
//    its own type with its own fold and no merge door at all.
// 4. **The schema bump is real in both directions.** A v2 blob is `corrupt`, not migrated, and the
//    retired `routingInventoryDigest` is gone from the shape rather than left decoding.
//
// The goldens and the framing pairs live where every other membership vector does —
// `MeshMembershipEventGoldenTests` and `CryptographicPurposeBoundaryTests` — so a new vector cannot
// drift away from the family it belongs to.
//
// Fixture instants are anchored to `MeshMembershipEventFixtures.base`, the one epoch every
// membership golden shares, rather than to `MeshRoutedFixtureClock`: nothing under test here reads
// a clock, and nothing here has an expiry, a deadline or a settle path for a wall clock to overtake.

import FernletCrypto
import FernletFoundation
import Foundation
import Testing
@testable import ProximityKit

// MARK: - Fixtures

/// Everything the key-advertisement suites need that is not already a membership fixture.
///
/// The pure value helpers are `nonisolated` so the at-rest suite can use them; only the three that
/// touch `IdentityService` are `@MainActor`, because signing reads the device's long-term key.
enum MeshKeyAgreementFixtures {

    /// A distinct 32-byte key for member `index`, so "a second, DIFFERENT key" is expressible.
    static func key(_ index: Int) -> Data {
        Data(
            (0..<MeshMembershipEventFormat.keyAgreementByteCount)
                .map { UInt8((index &* 13 &+ $0) % 251) }
        )
    }

    /// A fresh, provisioned identity and the keychain service to tear down with it.
    @MainActor
    static func identity() throws -> (IdentityService, String) {
        let service = "com.fernlet.mesh-key-agreement.test.\(UUID().uuidString)"
        let identity = IdentityService(keychainService: service)
        try identity.ensureProvisioned()
        return (identity, service)
    }

    /// An admission of `joiner` signed by `admitter`.
    @MainActor
    static func admission(
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

    /// A verifier holding `founder` plus every identity in `others`, all admitted by the founder.
    @MainActor
    static func verifier(
        founder: IdentityService,
        others: [IdentityService] = [],
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

    /// `identity`'s own signed advertisement, `secondsIn` seconds after the shared base instant.
    @MainActor
    static func advertisement(
        of identity: IdentityService,
        meshID: UUID,
        secondsIn: Int = 480
    ) throws -> SignedKeyAgreementAdvertisement {
        try SignedKeyAgreementAdvertisement.signed(
            meshID: meshID,
            identity: identity,
            advertisedAt: MeshMembershipEventFixtures.base.addingTimeInterval(TimeInterval(secondsIn))
        )
    }

    /// A placeholder-signed row for `index` — the at-rest door's input, never the fold's.
    ///
    /// - Parameters:
    ///   - index: The member index, which becomes `fp%03d` and, by default, the instant.
    ///   - meshID: The mesh the row claims.
    ///   - keyIndex: A different key than `index`'s, so "a second, DIFFERENT key" is expressible.
    ///   - secondsIn: The instant, when a cell needs the alphabetical order and the instant order
    ///     to DISAGREE — the shape that separates a mark derived from the surviving rows from one
    ///     truncated alphabetically.
    static func unverifiedRow(
        _ index: Int,
        meshID: UUID,
        keyIndex: Int? = nil,
        secondsIn: Int? = nil
    ) -> SignedKeyAgreementAdvertisement {
        SignedKeyAgreementAdvertisement(
            meshID: meshID,
            memberFingerprint: String(format: "fp%03d", index),
            keyAgreementPublicKey: key(keyIndex ?? index),
            advertisedAt: MeshMembershipEventFixtures.base
                .addingTimeInterval(TimeInterval(secondsIn ?? index)),
            signature: Data(repeating: 0xAB, count: MeshMembershipEventFormat.signatureByteCount)
        )
    }
}

// MARK: - The verifier's accept/refuse table

/// Every way an advertisement can be refused, each by its own frozen name.
///
/// The trust root is the ledger's own admission set, so every cell here mints real Ed25519
/// identities and real admissions — a placeholder-signed fixture would be refused for the wrong
/// reason and the table would prove nothing.
@MainActor
@Suite(.serialized)
struct MeshKeyAgreementVerificationTests {

    @Test func aSelfSignedAdvertisementFromAnAdmittedMemberVerifies() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let advertisement = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID)

        #expect(advertisement.memberFingerprint == founder.localFingerprint)
        #expect(advertisement.authorFingerprint == advertisement.memberFingerprint)
        #expect(advertisement.keyAgreementPublicKey == founder.localKeyAgreementPublicKey)
        #expect(verifier.verify(advertisement).rejection == nil)
    }

    @Test func anAdvertisementForAnotherMeshIsRefused() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let foreign = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: UUID())

        #expect(verifier.verify(foreign).rejection == .foreignMesh)
    }

    /// Every width the format fixes, refused before any signature work. A signature check on a
    /// malformed value is a signature check on attacker-chosen widths.
    @Test func aMalformedAdvertisementIsRefusedBeforeAnySignatureCheck() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let honest = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID)
        let shapes: [(String, SignedKeyAgreementAdvertisement)] = [
            ("a short key", honest.with(key: Data(repeating: 1, count: 31))),
            ("a long key", honest.with(key: Data(repeating: 1, count: 33))),
            ("a short signature", honest.with(signature: Data(repeating: 2, count: 63))),
            ("an empty fingerprint", honest.with(fingerprint: "")),
            ("an over-long fingerprint", honest.with(
                fingerprint: String(repeating: "f", count: MeshMembershipEventFormat.maxFingerprintLength + 1)
            ))
        ]
        #expect(shapes.count == 5, "one shape per width the format fixes")
        for (name, malformed) in shapes {
            #expect(!malformed.isWellFormed, "\(name) must not be well formed")
            #expect(verifier.verify(malformed).rejection == .malformedRecord, "\(name)")
        }
    }

    @Test func anAdvertisementFromANonAdmittedSignerIsRefused() throws {
        let (founder, founderService) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: founderService) }
        let (stranger, strangerService) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: strangerService) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let advertisement = try MeshKeyAgreementFixtures.advertisement(of: stranger, meshID: meshID)

        #expect(verifier.verify(advertisement).rejection == .signerNotAdmitted)
    }

    /// A departed member is refused: a mint's destinations come from the derived roster, which
    /// subtracts departures, so no path ever needs its key — and a 16-row durable set must not
    /// spend a slot on a row nothing can use. The departure is a REAL signed record, so the roster
    /// actually loses the member rather than the cell passing for a different reason.
    @Test func aDepartedMembersAdvertisementIsRefused() throws {
        let (founder, founderService) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: founderService) }
        let (leaver, leaverService) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: leaverService) }
        let meshID = UUID()
        var verifier = try MeshKeyAgreementFixtures.verifier(
            founder: founder, others: [leaver], meshID: meshID
        )
        let advertisement = try MeshKeyAgreementFixtures.advertisement(of: leaver, meshID: meshID)
        #expect(verifier.verify(advertisement).rejection == nil, "the precondition: it verified while a member")

        let departure = try SignedDepartureRecord.signed(
            meshID: meshID,
            identity: leaver,
            occurredAt: MeshMembershipEventFixtures.base.addingTimeInterval(600)
        )
        #expect(verifier.insert(departure) == nil)
        #expect(!verifier.roster.contains(fingerprint: leaver.localFingerprint))
        #expect(verifier.verify(advertisement).rejection == .signerNotAMember)
    }

    /// The mirror of the departure cell, on a three-member roster so the quorum arithmetic is real.
    @Test func aRemovedMembersAdvertisementIsRefused() throws {
        let (founder, founderService) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: founderService) }
        let (second, secondService) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: secondService) }
        let (target, targetService) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: targetService) }
        let meshID = UUID()
        var verifier = try MeshKeyAgreementFixtures.verifier(
            founder: founder, others: [second, target], meshID: meshID
        )
        let advertisement = try MeshKeyAgreementFixtures.advertisement(of: target, meshID: meshID)
        #expect(verifier.verify(advertisement).rejection == nil, "the precondition: it verified while a member")

        let removal = try SignedRemovalRecord.signed(
            meshID: meshID,
            identity: founder,
            memberFingerprint: target.localFingerprint,
            proposalID: MeshMembershipEventFixtures.proposalID,
            voterFingerprints: [founder.localFingerprint, second.localFingerprint],
            occurredAt: MeshMembershipEventFixtures.base.addingTimeInterval(660)
        )
        #expect(verifier.insert(removal) == nil)
        #expect(!verifier.roster.contains(fingerprint: target.localFingerprint))
        #expect(verifier.verify(advertisement).rejection == .signerNotAMember)
    }

    /// The key is BOUND. Swapping it for another member's would otherwise be the whole attack:
    /// a content key wrapped to a device the attacker controls, under an authentic fingerprint.
    @Test func anAdvertisementWhoseKeyWasEditedIsRefused() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let honest = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID)
        let edited = honest.with(key: MeshKeyAgreementFixtures.key(9))

        #expect(edited.isWellFormed, "the edit keeps every width — only the signature can catch it")
        #expect(verifier.verify(edited).rejection == .signatureInvalid)
    }

    /// `advertisedAt` is bound, so a replay cannot be re-dated into a row that would win the set's
    /// earliest-wins order.
    @Test func anAdvertisementWhoseInstantWasEditedIsRefused() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let honest = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID)
        let backdated = honest.with(advertisedAt: MeshMembershipEventFixtures.base)

        #expect(verifier.verify(backdated).rejection == .signatureInvalid)
    }

    /// `meshID` is bound into the signed bytes, which is what `foreignMesh` alone cannot prove: an
    /// advertisement minted for mesh A and re-stamped with mesh B's id reaches B's verifier past
    /// check 1 and dies at the signature.
    @Test func anAdvertisementReStampedForAnotherMeshIsRefusedAtTheSignature() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let otherMesh = UUID()
        let thisMesh = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: thisMesh)
        let elsewhere = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: otherMesh)
        let reStamped = elsewhere.with(meshID: thisMesh)

        #expect(verifier.verify(elsewhere).rejection == .foreignMesh)
        #expect(verifier.verify(reStamped).rejection == .signatureInvalid)
    }

    /// The cross-domain negative in code as well as in the framing wall: a departure's signature,
    /// carried on an advertisement of the same subject at the same instant, does not verify. Only
    /// the signing domain keeps the two apart, and "here is my key" must never be replayable as the
    /// permanent, grow-only "I have left".
    @Test func anAdvertisementCarryingADepartureSignatureIsRefused() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let at = MeshMembershipEventFixtures.base.addingTimeInterval(480)
        let departure = try SignedDepartureRecord.signed(
            meshID: meshID, identity: founder, occurredAt: at
        )
        let borrowed = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID)
            .with(signature: departure.signature)

        #expect(borrowed.isWellFormed)
        #expect(verifier.verify(borrowed).rejection == .signatureInvalid)
    }

    /// Every refusal this family can produce, spelled out, so a reader can see the vocabulary is
    /// the ledger's own and no new case was minted for addressing.
    @Test func theRefusalVocabularyIsTheLedgersOwn() {
        let used: [MeshMembershipRecordRejection] = [
            .foreignMesh, .malformedRecord, .signerNotAdmitted, .signerNotAMember, .signatureInvalid
        ]
        for rejection in used {
            #expect(!rejection.diagnosticDescription.isEmpty)
        }
    }
}

// MARK: - The fold

/// The set's decision table: what folding one advertisement does, and what it refuses to do.
@MainActor
@Suite(.serialized)
struct MeshKeyAgreementFoldTests {

    @Test func aVerifiedAdvertisementIsFolded() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let advertisement = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID)

        let result = MeshKeyAdvertisementFold.folding(
            [advertisement], into: .empty, verifiedBy: verifier
        )
        #expect(result.outcomes == [.folded(founder.localFingerprint)])
        #expect(result.changed)
        #expect(result.set.count == 1)
        #expect(result.set.keyAgreementPublicKey(for: founder.localFingerprint)
            == founder.localKeyAgreementPublicKey)
        #expect(result.outcomes.first?.auditToken == "mesh.keyAgreement.folded")
    }

    /// A replayed frame must cost nothing: no change, therefore no seal.
    @Test func aReplayedIdenticalAdvertisementChangesNothingAndAuditsNothing() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let advertisement = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID)
        let once = MeshKeyAdvertisementFold.folding([advertisement], into: .empty, verifiedBy: verifier)

        let twice = MeshKeyAdvertisementFold.folding(
            [advertisement], into: once.set, verifiedBy: verifier
        )
        #expect(twice.outcomes == [.alreadyHeld(founder.localFingerprint)])
        #expect(!twice.changed)
        #expect(twice.set == once.set)
        #expect(twice.outcomes.first?.auditToken == nil, "an honest replay writes no audit line")
    }

    /// The idempotence pre-filter compares the WHOLE value, so a near-miss is still verified.
    ///
    /// Pass A review, finding 3: a pre-filter that compared only fingerprint, key and instant
    /// reported a foreign-mesh row — or one carrying garbage where a signature belongs — as
    /// `alreadyHeld`, which is unaudited, not a refusal, and free of any per-sender charge. An
    /// attacker echoing known triples could therefore buy unlimited unbudgeted fold work.
    @Test func aNearMissOfAHeldRowIsVerifiedRatherThanAssumedHeld() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let held = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID)
        let once = MeshKeyAdvertisementFold.folding([held], into: .empty, verifiedBy: verifier)
        let foreign = SignedKeyAgreementAdvertisement(
            meshID: UUID(),
            memberFingerprint: held.memberFingerprint,
            keyAgreementPublicKey: held.keyAgreementPublicKey,
            advertisedAt: held.advertisedAt,
            signature: held.signature
        )
        let junkSignature = SignedKeyAgreementAdvertisement(
            meshID: held.meshID,
            memberFingerprint: held.memberFingerprint,
            keyAgreementPublicKey: held.keyAgreementPublicKey,
            advertisedAt: held.advertisedAt,
            signature: Data(repeating: 0x11, count: MeshMembershipEventFormat.signatureByteCount)
        )

        let result = MeshKeyAdvertisementFold.folding(
            [foreign, junkSignature], into: once.set, verifiedBy: verifier
        )
        #expect(result.outcomes == [.refused(.foreignMesh), .refused(.signatureInvalid)],
                "both are refusals the verifier names, not an assumed replay")
        #expect(!result.changed)
        let bothAudited = result.outcomes.allSatisfy { $0.auditToken == "mesh.keyAgreement.rejected" }
        #expect(bothAudited, "and both are audited under the rejection token")
    }

    /// The same key at a later instant is an honest re-advertisement after a reconnect: earliest
    /// wins, nothing changes, and it is emphatically not a conflict.
    @Test func aReAdvertisementOfTheSameKeyKeepsTheEarliestRow() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let first = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID, secondsIn: 480)
        let later = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID, secondsIn: 900)
        let once = MeshKeyAdvertisementFold.folding([first], into: .empty, verifiedBy: verifier)

        let again = MeshKeyAdvertisementFold.folding([later], into: once.set, verifiedBy: verifier)
        #expect(again.outcomes == [.alreadyHeld(founder.localFingerprint)])
        #expect(!again.changed)
        #expect(again.set.advertisement(for: founder.localFingerprint)?.advertisedAt == first.advertisedAt)
        #expect(!again.set.isConflicted(founder.localFingerprint))
    }

    /// The duplicate-key cell. A second, DIFFERENT verified key for one fingerprint is refused by
    /// name and the member becomes unaddressable — never "pick the earliest one", because either
    /// choice means wrapping a content key to a device that may not hold it.
    @Test func aSecondDifferentKeyIsRefusedByNameAndMarksTheMemberConflicted() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let honest = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID)
        let held = MeshKeyAdvertisementFold.folding([honest], into: .empty, verifiedBy: verifier).set
        // A second key the same member really signed: unreachable by any legitimate provisioning
        // path, which is exactly why it is treated as a substitution rather than an update.
        let other = try SignedKeyAgreementAdvertisement.signedForTesting(
            meshID: meshID,
            identity: founder,
            keyAgreementPublicKey: MeshKeyAgreementFixtures.key(7),
            advertisedAt: MeshMembershipEventFixtures.base.addingTimeInterval(540)
        )
        #expect(verifier.verify(other).rejection == nil, "the precondition: the second key VERIFIED")

        let result = MeshKeyAdvertisementFold.folding([other], into: held, verifiedBy: verifier)
        #expect(result.outcomes == [.conflicted(founder.localFingerprint)])
        #expect(result.changed)
        #expect(result.set.conflictedFingerprints == [founder.localFingerprint])
        #expect(result.set.keyAgreementPublicKey(for: founder.localFingerprint) == nil,
                "a conflicted member is unaddressable — fail closed")
        #expect(result.set.advertisement(for: founder.localFingerprint)?.keyAgreementPublicKey
            == honest.keyAgreementPublicKey, "the set only grows: the earliest row stays")
        #expect(result.outcomes.first?.auditToken == "mesh.keyAgreement.conflicted")
    }

    /// **The denial-of-service negative control.** An advertisement that does not verify must
    /// change NOTHING — not the set, and above all not the conflict list. If a forged row could
    /// mark a fingerprint conflicted, any peer on the link could permanently un-address any member.
    @Test func anUnverifiableConflictingAdvertisementDoesNotMarkAnythingConflicted() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let honest = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID)
        let held = MeshKeyAdvertisementFold.folding([honest], into: .empty, verifiedBy: verifier).set
        let forged = honest.with(key: MeshKeyAgreementFixtures.key(11))

        let result = MeshKeyAdvertisementFold.folding([forged], into: held, verifiedBy: verifier)
        #expect(result.outcomes == [.refused(.signatureInvalid)])
        #expect(!result.changed)
        #expect(result.set == held)
        #expect(result.set.conflictedFingerprints.isEmpty)
        #expect(result.set.keyAgreementPublicKey(for: founder.localFingerprint)
            == honest.keyAgreementPublicKey, "the honest key is still addressable")
        #expect(result.outcomes.first?.auditToken == "mesh.keyAgreement.rejected")
    }

    /// Two members, both orders, twice: the fold is commutative and idempotent, so two devices that
    /// folded the same rows over different links hold the same set.
    @Test func theFoldIsCommutativeAndIdempotent() throws {
        let (founder, founderService) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: founderService) }
        let (second, secondService) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: secondService) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(
            founder: founder, others: [second], meshID: meshID
        )
        let first = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID, secondsIn: 480)
        let other = try MeshKeyAgreementFixtures.advertisement(of: second, meshID: meshID, secondsIn: 540)

        let forward = MeshKeyAdvertisementFold.folding([first, other], into: .empty, verifiedBy: verifier)
        let backward = MeshKeyAdvertisementFold.folding([other, first], into: .empty, verifiedBy: verifier)
        #expect(forward.set == backward.set)
        #expect(forward.set.count == 2)
        let again = MeshKeyAdvertisementFold.folding([first, other], into: forward.set, verifiedBy: verifier)
        #expect(again.set == forward.set)
        #expect(!again.changed)
    }

    /// A relayed set legitimately carries rows this device refuses — a member it has not been told
    /// was admitted, or one that has departed. A refusal must not abort the batch.
    @Test func aRefusedRowDoesNotAbortTheBatch() throws {
        let (founder, founderService) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: founderService) }
        let (stranger, strangerService) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: strangerService) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        let unknown = try MeshKeyAgreementFixtures.advertisement(of: stranger, meshID: meshID)
        let mine = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID)

        let result = MeshKeyAdvertisementFold.folding([unknown, mine], into: .empty, verifiedBy: verifier)
        #expect(result.outcomes == [.refused(.signerNotAdmitted), .folded(founder.localFingerprint)])
        #expect(result.set.count == 1)
        #expect(result.outcomes.filter { $0.isRefusal }.count == 1)
    }

    /// The bound refuses BY NAME rather than dropping a row. It is also unreachable on an honest
    /// mesh, and the proof is the roster cap, not the record cap: at most eight distinct
    /// fingerprints can ever pass the verifier's roster check over the life of one mesh.
    @Test func theSetRefusesANewMemberAtItsBoundRatherThanDroppingOne() throws {
        let (founder, service) = try MeshKeyAgreementFixtures.identity()
        defer { KeychainItem.deleteAll(service: service) }
        let meshID = UUID()
        let verifier = try MeshKeyAgreementFixtures.verifier(founder: founder, meshID: meshID)
        #expect(
            MeshMembershipBounds.maxRosterMembers < MeshKeyAgreementAdvertisementSet.capacity,
            "the roster cap is the tighter one, which is why the bound cannot be reached honestly"
        )
        let full = MeshKeyAgreementAdvertisementSet(
            advertisements: (1...MeshKeyAgreementAdvertisementSet.capacity).map {
                MeshKeyAgreementFixtures.unverifiedRow($0, meshID: meshID)
            }
        )
        #expect(full.isAtCapacity)
        #expect(full.count == MeshKeyAgreementAdvertisementSet.capacity)
        // `secondsIn: 0` is load-bearing (pass A review, finding 5). The incumbents sit at
        // `base + 1 ... base + 16`, so a row minted LATER would be the one a silent truncation
        // dropped and "nothing was evicted" would hold whatever the guard did. Minted EARLIEST, a
        // truncation evicts an incumbent instead, and all three assertions can fail.
        let mine = try MeshKeyAgreementFixtures.advertisement(of: founder, meshID: meshID, secondsIn: 0)

        let result = MeshKeyAdvertisementFold.folding([mine], into: full, verifiedBy: verifier)
        #expect(result.outcomes == [.refusedSetFull(founder.localFingerprint)])
        #expect(!result.changed)
        #expect(result.set == full, "nothing was evicted to make room")
        #expect(result.outcomes.first?.auditToken == "mesh.keyAgreement.setFull")
    }

    /// The at-rest door is no more trusting than the fold: two different keys for one member in a
    /// decoded or hand-built set mark that member conflicted there too.
    @Test func theAtRestDoorAlsoRefusesAConflict() {
        let meshID = UUID()
        let set = MeshKeyAgreementAdvertisementSet(advertisements: [
            MeshKeyAgreementFixtures.unverifiedRow(1, meshID: meshID, keyIndex: 1),
            MeshKeyAgreementFixtures.unverifiedRow(1, meshID: meshID, keyIndex: 2)
        ])
        #expect(set.count == 1)
        #expect(set.isConflicted("fp001"))
        #expect(set.keyAgreementPublicKey(for: "fp001") == nil)
    }

    /// Bounded growth is a property of the at-rest format, not only of the writer.
    @Test func aDecodedSetIsBoundedAndKeepsItsConflictMarks() throws {
        let meshID = UUID()
        let oversized = MeshKeyAgreementAdvertisementSet(
            advertisements: (1...40).map { MeshKeyAgreementFixtures.unverifiedRow($0, meshID: meshID) },
            conflictedFingerprints: ["fp003"]
        )
        let wire = try JSONEncoder().encode(oversized)
        let decoded = try JSONDecoder().decode(MeshKeyAgreementAdvertisementSet.self, from: wire)

        #expect(decoded.count == MeshKeyAgreementAdvertisementSet.capacity)
        #expect(decoded == oversized)
        #expect(decoded.isConflicted("fp003"))
        #expect(decoded.memberFingerprints.count == MeshKeyAgreementAdvertisementSet.capacity)
    }

    /// A conflict mark survives exactly as long as its row does — the two caps are ONE cap.
    ///
    /// The shape that separates the two rules (pass A review, finding 1): seventeen conflicting
    /// pairs whose instant order is the REVERSE of their alphabetical order. The row cap keeps the
    /// sixteen earliest — `fp017` down to `fp002` — while an alphabetically-truncated mark list
    /// would keep `fp001…fp016`, dropping `fp017`'s mark while its row survived and making a
    /// conflicted member addressable again.
    @Test func aMarkIsKeptForEverySurvivingRowAndOnlyForThose() {
        let meshID = UUID()
        let pairs = MeshKeyAgreementAdvertisementSet.capacity + 1
        var rows: [SignedKeyAgreementAdvertisement] = []
        // R2: bounded by the set's capacity plus one.
        for index in 1...pairs {
            let instant = pairs + 1 - index
            rows.append(MeshKeyAgreementFixtures.unverifiedRow(
                index, meshID: meshID, keyIndex: index, secondsIn: instant
            ))
            rows.append(MeshKeyAgreementFixtures.unverifiedRow(
                index, meshID: meshID, keyIndex: index + 100, secondsIn: instant
            ))
        }

        let set = MeshKeyAgreementAdvertisementSet(advertisements: rows)

        #expect(set.count == MeshKeyAgreementAdvertisementSet.capacity)
        #expect(set.conflictedFingerprints.count == MeshKeyAgreementAdvertisementSet.capacity,
                "one mark per surviving row, because every pair conflicted")
        #expect(set.isConflicted("fp017"),
                "the alphabetically-last member survived the row cap, so its mark must survive too")
        #expect(set.keyAgreementPublicKey(for: "fp017") == nil, "and it stays unaddressable")
        #expect(set.advertisement(for: "fp001") == nil, "the latest row is the one the cap dropped")
        #expect(!set.isConflicted("fp001"), "and a mark with no row is dropped with it")
    }

    /// Every spelling that reaches the at-rest initializer, matched against **whitespace-collapsed**
    /// text rather than against a raw line.
    ///
    /// The collapse is the third review's P2. This module's house form for a multi-argument
    /// initializer puts the first label on the NEXT line — the declaring file's own
    /// `init(from decoder:)` writes `self.init(` and then `advertisements:` below it — so a per-line
    /// `contains` never saw the declaring file's own construction site, and the allowlist entry that
    /// had been written for it (`init(from decoder: Decoder) throws {`) matched nothing at all.
    /// Every needle here is whitespace-free, which is what lets one `contains` over collapsed text
    /// answer for a site written across two lines as well as for one written on a single line.
    ///
    /// The first needle is the BARE type-with-paren, not `…Set(advertisements:` (pass B review
    /// finding 6) — the same hazard from the other side, where a labelled needle was defeated by a
    /// line break. The second closes `X.init(`, which does not contain `X(`. The third names no type
    /// at all, which is what catches an inferred `= .init(advertisements:`, a bare `.init(` and the
    /// decoder's `self.init(` alike (second fix review finding 9, third review P2).
    static let constructionNeedles = [
        "MeshKeyAgreementAdvertisementSet(",
        "MeshKeyAgreementAdvertisementSet.init(",
        ".init(advertisements:"
    ]

    /// `text` with every whole-line comment dropped and every whitespace character removed.
    ///
    /// Comments go first for the reason `MeshRoutedSourceScan.codeOnly(_:)` exists: a header that
    /// *names* the constructor it forbids is the documentation of the rule, not a violation of it.
    /// Whitespace goes next so a needle can span the line break the house form puts inside a call.
    static func collapsed(_ text: String) -> String {
        MeshRoutedSourceScan.codeOnly(text).filter { !$0.isWhitespace }
    }

    /// The set has no silent merge door, and nothing outside its own file may hand it a row.
    ///
    /// `MeshMembershipRecordSet.merging(_:)`/`.inserting(_:)` dedup earliest-wins and silently keep
    /// ONE of two conflicting rows — for a key that is a fail-open every cell above would pass
    /// straight through, because they all drive the per-element door. So the type declares no
    /// `merging` at all, and its two mutating doors take a value only the verifier can mint.
    ///
    /// **The at-rest constructor is the third door, and it is walled here too** (pass A review,
    /// finding 1): it takes RAW rows and normalization marks conflicts from them, so shipping code
    /// that reached for `MeshKeyAgreementAdvertisementSet(advertisements: payload.advertisements)`
    /// would make conflict decisions on unverified bytes with nothing to stop it. Only the
    /// declaring file — the decoder and the two verified doors — may name it. `markingConflicted(`
    /// is walled on the same principle from the other side: only the fold may mark a member
    /// unaddressable, whatever receiver name a caller gives the set.
    ///
    /// **The needles this cell carries, by name** (third review P3 11 — they had drifted onto the
    /// constant's own doc comment): the three in ``constructionNeedles``, which are the at-rest
    /// initializer's spellings, plus `keyAdvertisements.merging(`, `keyAdvertisements.inserting(`
    /// and `markingConflicted(`, which are the receiver-named doors. Every one of them is tested
    /// against ``collapsed(_:)`` text, so a line break inside a call defeats none of them, and four
    /// union-door declarations (`merging`, `folded`, `union`, `combining`) are refused in the
    /// declaring file itself.
    @Test func theAdvertisementSetNamesNoSilentMergeDoor() throws {
        let declaring = "FernletKit/Sources/ProximityKit/Mesh/MeshKeyAgreementAdvertisement.swift"
        let source = try RepoRoot.source(declaring)
        #expect(source.count > 2_000, "the source scan must not be reading an empty file")
        // R2: bounded by the needle list.
        for spelling in ["func merging(", "func folded(", "func union(", "func combining("] {
            #expect(!source.contains(spelling), "the set must not grow a union door: \(spelling)")
        }
        var namedElsewhere: [String] = []
        // R2: bounded by the shipping source file list.
        for url in try CryptographicWallScan.sourceFiles() {
            let path = CryptographicWallScan.repoRelativePath(url)
            guard path != declaring else { continue }
            let text = Self.collapsed(try String(contentsOf: url, encoding: .utf8))
            guard Self.constructionNeedles.contains(where: text.contains)
                    || text.contains("keyAdvertisements.merging(")
                    || text.contains("keyAdvertisements.inserting(")
                    || text.contains("markingConflicted(") else { continue }
            namedElsewhere.append(path)
        }
        #expect(
            namedElsewhere.isEmpty,
            """
            The advertisement set may only be folded through `MeshKeyAdvertisementFold`, which
            verifies first. These files reach around it: \(namedElsewhere.joined(separator: ", "))
            """
        )
    }

    /// The declaring file's exemption is per **declaring type and function**, not per file.
    ///
    /// The at-rest initializer verifies nothing, so even inside the type's own file only the
    /// functions that ARE the set's algebra may name it — otherwise a new fold door added there
    /// reaches the unverified constructor under cover of the file exemption the wall above grants.
    /// Allowlisted by file + **enclosing type** + enclosing declaration, so a new site has to be
    /// argued for by name.
    ///
    /// The type half is the third review's P3 2: the park (`MeshKeyAdvertisementPark`) declares its
    /// own `static var empty:`, which made a declaration-only entry written for the SET into a
    /// second, unintended exemption inside a different type — and the two `init(from decoder:)`
    /// declarations in this file are textually identical, so the pair is the only thing that can
    /// tell them apart. The six entries below are the six sites that exist.
    @Test func theSetsOwnConstructionSitesAreAllowlistedByFunction() throws {
        let allowed = [
            "MeshKeyAgreementAdvertisementSet / static var empty:",
            "MeshKeyAgreementAdvertisementSet / init(from decoder: Decoder) throws {",
            "MeshKeyAgreementAdvertisementSet / func inserting(_ verified:",
            "MeshKeyAgreementAdvertisementSet / func markingConflicted(",
            "MeshKeyAgreementAdvertisementSet / func clearingConflicts(outside",
            "MeshKeyAdvertisementFold / static func restoring("
        ]
        let source = try RepoRoot.source(
            "FernletKit/Sources/ProximityKit/Mesh/MeshKeyAgreementAdvertisement.swift"
        )
        let lines = source.components(separatedBy: "\n")
        var unallowlisted: [String] = []
        var matched: Set<String> = []
        // R2: bounded by the file's own line count.
        for index in lines.indices {
            let window = Self.constructionWindow(at: index, in: lines)
            guard Self.constructionNeedles.contains(where: window.contains) else { continue }
            let site = Self.enclosingSite(of: index, in: lines)
            guard let entry = allowed.first(where: { site.hasPrefix($0) }) else {
                unallowlisted.append("line \(index + 1) in \(site)")
                continue
            }
            matched.insert(entry)
        }
        #expect(
            unallowlisted.isEmpty,
            """
            Only the set's own algebra may name the at-rest initializer, which verifies nothing.
            Unallowlisted sites: \(unallowlisted.joined(separator: " | "))
            """
        )
        // An entry that matches nothing is an exemption for a site that no longer exists — which is
        // exactly what the third review found, and it is indistinguishable from a wall doing its job
        // unless it is asserted (third review P2).
        #expect(matched.count == allowed.count,
                "every allowlist entry must match a real site, or it is exempting nothing")
        #expect(lines.count > 100, "the line scan must not be reading an empty file")
    }

    /// The line at `index`, collapsed, with its continuation folded in when the module's house form
    /// split a construction across two lines.
    ///
    /// The continuation is appended only when the collapsed line **ends at an open paren**, which is
    /// exactly the shape that defeated the per-line scan (`self.init(` with `advertisements:`
    /// below). Extending every line unconditionally would report one site twice — once at its own
    /// line and once at the signature line above it, whose return type names the same set.
    private static func constructionWindow(at index: Int, in lines: [String]) -> String {
        let line = Self.collapsed(lines[index])
        guard line.hasSuffix("("), lines.indices.contains(index + 1) else { return line }
        return line + Self.collapsed(lines[index + 1])
    }

    /// The enclosing type and declaration of the line at `index`, as `"Type / declaration"` — the
    /// key the allowlist is written in.
    private static func enclosingSite(of index: Int, in lines: [String]) -> String {
        let type = Self.enclosingType(of: index, in: lines)
        return "\(type) / \(Self.enclosingDeclaration(of: index, in: lines))"
    }

    /// The nearest declaration at or above `index` — a construction site's owning function.
    ///
    /// **Indentation plus a keyword set**, not a list of modifier spellings (third review P3 3).
    /// The old rule enumerated six starter and five member prefixes, and `public var`,
    /// `private(set) var`, `lazy var`, `internal let` and `public static func` matched none of them:
    /// a construction site inside one walked straight past its own declaration and inherited an
    /// allowlisted function's name from up to forty lines above. Any line at the type's own member
    /// indent of four spaces whose first keyword is `let`/`var`/`func`/`init`/`subscript`/`case` is
    /// now the boundary. A **local** is indented eight, which is what keeps
    /// `restoring(_:verifiedBy:)`'s two local `var`s from standing in for a declaration; the same
    /// indent rule is what makes a stored or computed property a boundary rather than a pass.
    private static func enclosingDeclaration(of index: Int, in lines: [String]) -> String {
        // R2: a construction site is never forty lines from its own signature.
        for offset in 0..<min(40, index + 1) {
            let line = lines[index - offset]
            let text = line.trimmingCharacters(in: .whitespaces)
            guard line.prefix(while: { $0 == " " }).count == 4,
                  Self.declaresMember(text) else { continue }
            return text
        }
        return "no enclosing declaration"
    }

    /// Whether `text` declares a member: any run of modifiers followed by a member keyword.
    ///
    /// The prefix scan is what recognises `@ObservationIgnored private(set) var` and
    /// `public static func` as declarations without naming either spelling. A false positive only
    /// ever NARROWS the allowlist, which is the safe direction for a wall.
    private static func declaresMember(_ text: String) -> Bool {
        let keywords: Set<String> = ["let", "var", "func", "init", "subscript", "case"]
        // R2: bounded by the modifier words one declaration can carry.
        for word in text.split(separator: " ").prefix(6) {
            if keywords.contains(String(word.prefix { $0.isLetter })) { return true }
        }
        return false
    }

    /// The top-level type the line at `index` sits inside, by name.
    ///
    /// A declaration at indent zero that ends in a brace, read from the first type keyword it
    /// carries — so `nonisolated struct MeshKeyAgreementAdvertisementSet: Codable, …` answers
    /// `MeshKeyAgreementAdvertisementSet` however its modifiers and conformances move.
    private static func enclosingType(of index: Int, in lines: [String]) -> String {
        let starters = ["struct ", "enum ", "class ", "actor ", "extension ", "protocol "]
        // R2: bounded by the file's own line count.
        for offset in 0..<(index + 1) {
            let line = lines[index - offset]
            guard line.first?.isWhitespace == false, line.hasSuffix("{") else { continue }
            // R2: bounded by the starter list.
            for starter in starters {
                guard let range = line.range(of: starter) else { continue }
                let name = line[range.upperBound...].prefix {
                    $0.isLetter || $0.isNumber || $0 == "_"
                }
                guard !name.isEmpty else { continue }
                return String(name)
            }
        }
        return "no enclosing type"
    }
}

// MARK: - Schema 3

/// The at-rest half: the set round-trips, a v2 blob is refused, and the retired field is gone.
@Suite(.serialized)
struct MeshKeyAgreementSchemaTests {

    private static func context(
        keyAdvertisements: MeshKeyAgreementAdvertisementSet = .empty
    ) -> MeshSessionContext {
        MeshSessionContext(
            meshID: MeshMembershipEventFixtures.meshID,
            protocolVersion: 1,
            createdAt: MeshMembershipEventFixtures.base,
            hardDeadline: MeshMembershipEventFixtures.base.addingTimeInterval(6 * 60 * 60),
            keyAdvertisements: keyAdvertisements
        )
    }

    @Test func theSchemaIsThree() {
        #expect(MeshSessionContextSchema.current == 3, "P6 item 1's bump")
        #expect(Self.context().schemaVersion == 3)
        #expect(MeshSessionContextSchema.token == "fernlet.mesh.session-context.v1",
                "the sealing domain did not change; only the shape did")
    }

    @Test func aSchemaThreeContextRoundTripsItsAdvertisementSetAndConflicts() throws {
        let meshID = MeshMembershipEventFixtures.meshID
        let set = MeshKeyAgreementAdvertisementSet(
            advertisements: [
                MeshKeyAgreementFixtures.unverifiedRow(1, meshID: meshID),
                MeshKeyAgreementFixtures.unverifiedRow(2, meshID: meshID)
            ],
            // A mark for a member the set holds a row for: normalization derives the marks from
            // the SURVIVING rows, so a mark for an absent fingerprint is dropped (and would prove
            // nothing — an absent member is unaddressable either way).
            conflictedFingerprints: ["fp002"]
        )
        let wire = try JSONEncoder().encode(Self.context(keyAdvertisements: set))
        let decoded = try JSONDecoder().decode(MeshSessionContext.self, from: wire)

        #expect(decoded.keyAdvertisements == set)
        #expect(decoded.keyAdvertisements.count == 2)
        #expect(decoded.keyAdvertisements.isConflicted("fp002"))
        #expect(decoded.keyAdvertisements.keyAgreementPublicKey(for: "fp002") == nil,
                "a conflicted member survives the round trip unaddressable")
        #expect(decoded.schemaVersion == 3)
    }

    /// The forward direction of the bump. A v2 blob decoded as v3 would resume with an EMPTY
    /// advertisement set and then silently refuse every mint it was not linked for — the exact
    /// outage the field closes, re-created by a stale file and invisible. So it is refused by name.
    ///
    /// The existing v1 cell cannot prove this: a v1 blob was already refused before the bump, so it
    /// stays green whatever `current` is.
    @Test func aSchemaTwoBlobIsRefusedRatherThanMigrated() throws {
        let json = """
            {"schemaVersion":2,"meshID":"\(MeshMembershipEventFixtures.meshID.uuidString)",
             "protocolVersion":1,"createdAt":0,"hardDeadline":21600,
             "ledger":{"admissions":[],"departures":[],"removals":[],"terminations":[]},
             "epochHeads":[],"developedLocally":false}
            """
        let error = #expect(throws: MeshSessionContextDecodingError.self) {
            try JSONDecoder().decode(MeshSessionContext.self, from: Data(json.utf8))
        }
        #expect(error == .unsupportedSchemaVersion(2))
    }

    /// The reverse direction, stated as a decoded fact rather than left to a reader: the version
    /// guard is exact equality, so a v3 blob would be refused by a v2 build too.
    @Test func theVersionGuardIsExactEqualityInBothDirections() throws {
        let json = """
            {"schemaVersion":4,"meshID":"\(MeshMembershipEventFixtures.meshID.uuidString)",
             "protocolVersion":1,"createdAt":0,"hardDeadline":21600,
             "ledger":{"admissions":[],"departures":[],"removals":[],"terminations":[]}}
            """
        let error = #expect(throws: MeshSessionContextDecodingError.self) {
            try JSONDecoder().decode(MeshSessionContext.self, from: Data(json.utf8))
        }
        #expect(error == .unsupportedSchemaVersion(4))
    }

    /// The retired field, as a zero-list. `routingInventoryDigest` had been provably dead since P5
    /// item 5 (always nil) and was still a decoded field of the schema-2 blob; item 1's bump is the
    /// cheap moment to remove it, and this cell is what stops it coming back by copy-paste.
    ///
    /// The needles are **declaration and use** shapes rather than the bare identifier, because
    /// ``MeshSessionContextSchema``'s own version history says in prose what version 3 retired —
    /// the same way the record kinds' doc still names the retired `sessionGoodbye`. A wall that
    /// forbade the word would forbid the record of the removal.
    @Test func theRetiredRoutingInventoryDigestIsGone() throws {
        let needles = [
            "var routingInventoryDigest", "let routingInventoryDigest",
            ".routingInventoryDigest", "routingInventoryDigest:"
        ]
        var survivors: [String] = []
        // R2: bounded by the shipping source file list.
        for url in try CryptographicWallScan.sourceFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard needles.contains(where: text.contains) else { continue }
            survivors.append(CryptographicWallScan.repoRelativePath(url))
        }
        #expect(
            survivors.isEmpty,
            "the retired field is declared or read again in: \(survivors.joined(separator: ", "))"
        )
    }
}

// MARK: - Test-only helpers

extension SignedKeyAgreementAdvertisement {

    /// A copy with one field replaced, so a tamper cell states exactly what it moved.
    func with(
        meshID: UUID? = nil,
        fingerprint: String? = nil,
        key: Data? = nil,
        advertisedAt: Date? = nil,
        signature: Data? = nil
    ) -> SignedKeyAgreementAdvertisement {
        SignedKeyAgreementAdvertisement(
            meshID: meshID ?? self.meshID,
            memberFingerprint: fingerprint ?? memberFingerprint,
            keyAgreementPublicKey: key ?? keyAgreementPublicKey,
            advertisedAt: advertisedAt ?? self.advertisedAt,
            signature: signature ?? self.signature
        )
    }

    /// Signs an advertisement naming a key the signer does not actually hold.
    ///
    /// Test-only, and it exists for exactly one cell: the duplicate-key refusal needs a SECOND
    /// advertisement that genuinely verifies, and no legitimate path produces one —
    /// `ensureProvisioned()` mints the signing and key-agreement pair together in all four of its
    /// cases, so a device cannot change its key-agreement key and keep its fingerprint. Shipping
    /// code has no such door: ``signed(meshID:identity:advertisedAt:)`` always advertises the
    /// device's own key.
    @MainActor
    static func signedForTesting(
        meshID: UUID,
        identity: IdentityService,
        keyAgreementPublicKey: Data,
        advertisedAt: Date
    ) throws -> SignedKeyAgreementAdvertisement {
        let unsigned = SignedKeyAgreementAdvertisement(
            meshID: meshID,
            memberFingerprint: identity.localFingerprint,
            keyAgreementPublicKey: keyAgreementPublicKey,
            advertisedAt: advertisedAt,
            signature: Data()
        )
        return unsigned.with(signature: try identity.sign(
            canonicalBytes(for: unsigned),
            purpose: FernletCryptoPurpose.Signature.meshKeyAgreementV1
        ))
    }
}
