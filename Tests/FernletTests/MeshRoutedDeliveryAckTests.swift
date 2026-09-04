// MeshRoutedDeliveryAckTests.swift
// FernletTests
//
// P5 item 4 (plan §11's acknowledgement stages, §3.6, §19.5): what makes a routed item FINAL at a
// destination, and who is allowed to say so.
//
// Five claims are walled here:
//
// 1. **The per-type matrix is plan §11's three clauses, not a `switch`.** Photos and text are final
//    on durable recipient storage with no decrypt anywhere in the path; a heart is not final on
//    ciphertext alone and needs a foreground ledger commit; a control item is final immediately with
//    no held chunks at all. An unknown token is refused and acknowledges nothing.
// 2. **Durable before acknowledged.** The ack instant is written before any witness exists, survives
//    a new store instance on the same scope, and a failed index write mints nothing. Before first
//    unlock every path refuses BY NAME and writes nothing — `refused`, `deferred` and `absent` stay
//    three different answers.
// 3. **The `delivered` rung has exactly one writer**, and it takes a signed receipt whose signer is
//    that destination. `committingDelivery` moves no rung at all, so no caller's word can close a
//    peer's destination — asserted behaviourally here and by source walls in
//    `MeshRoutedStoreIsolationTests`.
// 4. **The heart evidence is per-GIFT, not per-pass.** `MeshHeartCommit.commit` is a batch door, so a
//    pass carrying two hearts judges twice; both hearts still receipt, and a gift the ledger cannot
//    stand behind yields no evidence at all.
// 5. **Every state a retry must reach is enumerated.** The window between a stamped ack and a stored
//    receipt, a heart whose custody a repair cleared, and an incomplete destination copy are all
//    named by `itemsAwaitingLocalAck(at:for:)` — a retry list that missed one would strand it.
//
// Every test runs on its OWN scope (temp directory + `com.fernlet.mesh-routed.test.<uuid>` keychain
// service) and its own heart-ledger file. Nothing sleeps or reads a wall clock for a decision.

import CryptoKit
import Foundation
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
import Testing
@testable import ProximityKit

// MARK: - Fixtures

/// The heart half of the ack matrix: an isolated ledger and the merged hearts offered to it.
@MainActor
enum MeshRoutedAckFixtures {

    /// A ledger on its own temp root (the shared-disk-root flake family) with an injected clock.
    static func ledger(
        at instant: Date = MeshRoutedStoreFixtures.now,
        writeData: ((Data, URL) throws -> Void)? = nil
    ) -> ProximityHeartLedger {
        ProximityHeartLedger(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("mesh-routed-ack-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("HeartLedger.json"),
            now: { instant },
            writeData: writeData
        )
    }

    /// A merged heart for `giftID`. For a routed heart the gift id IS the item id.
    static func heart(_ giftID: UUID, sender: String = "alice") -> MeshMergedHeart {
        MeshMergedHeart(
            giftID: giftID, senderFingerprint: sender, senderDisplayName: sender,
            firstSeenAt: MeshRoutedStoreFixtures.now
        )
    }

    /// A rig whose item is a HEART, so `itemID == giftID` and the default table gives it the
    /// foreground-commit stage.
    static func heartRig(_ scope: MeshRoutedStorageScope) throws -> MeshRoutedCustodyRig {
        try MeshRoutedCustodyFixtures.rig(scope: scope, typeToken: MeshRoutedTypeToken.heart)
    }

    /// A rig whose item is a PHOTO — final on durable storage, no decrypt in the path.
    static func photoRig(_ scope: MeshRoutedStorageScope) throws -> MeshRoutedCustodyRig {
        try MeshRoutedCustodyFixtures.rig(scope: scope, typeToken: MeshRoutedTypeToken.photo)
    }

    /// Commits the heart through the real ledger and builds the evidence, or fails the test.
    static func evidence(
        for rig: MeshRoutedCustodyRig,
        in ledger: ProximityHeartLedger,
        sender: String = "alice"
    ) throws -> MeshRoutedAckEvidence {
        let outcome = MeshHeartCommit.commit([heart(rig.manifest.itemID, sender: sender)], into: ledger)
        let ack = try #require(
            MeshRoutedHeartAck(outcome: outcome, giftID: rig.manifest.itemID, ledger: ledger),
            "the ledger refused to stand behind the committed gift: \(outcome)"
        )
        return .heartLedgerCommit(ack)
    }

    /// Admits the manifest WITHOUT staging any chunk — the control-item shape, and the only way to
    /// reach a known, manifest-bound item with nothing held.
    static func admitManifestOnly(_ rig: MeshRoutedCustodyRig) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshRoutedStoreFixtures.installA)) {
            let admitted = rig.store.admittingManifest(rig.manifest, now: MeshRoutedStoreFixtures.now)
            #expect(admitted.value != nil, "manifest admission: \(admitted)")
        }
    }

    /// A table that maps the RESERVED control token to `immediate` — a test-only affordance, and the
    /// reason `shippingCodeNamesOneAckStageTable` exists.
    static let controlTable = MeshRoutedAckStageTable(rows: [
        MeshRoutedAckStageRow(typeToken: MeshRoutedTypeToken.control, finalAck: .immediate)
    ])

    /// The record for `rig`'s item under a pinned binding, or nil.
    static func record(_ rig: MeshRoutedCustodyRig) -> MeshRoutedItemRecord? {
        MeshRoutedCustodyFixtures.loadedIndex(rig.store)?.record(for: rig.key)
    }

    /// Ingests `receipt` into `rig`'s store under a pinned binding.
    static func ingest(
        _ receipt: MeshRecipientReceipt,
        into rig: MeshRoutedCustodyRig
    ) -> MeshRoutedOutcome<MeshDeliveryOutcome> {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshRoutedStoreFixtures.installA)) {
            rig.store.recordingRecipientReceipt(
                item: rig.key, receipt: receipt, now: MeshRoutedStoreFixtures.now
            )
        }
    }
}

/// A writer that always fails, so a ledger can be driven into the applied-but-not-persisted state
/// `recordReceivedHeart` still answers `true` for.
private struct MeshRoutedAckWriteFailure: Error {}

// MARK: - The stage vocabulary

/// The three clauses as values, the table that maps tokens onto them, and the heart evidence's two
/// legs.
@MainActor
@Suite(.serialized)
struct MeshRoutedAckStageTests {

    @Test func theThreeStagesAreTheThreeClauses() {
        #expect(MeshRoutedAckStage.allCases.map(\.rawValue) == [
            "immediate", "durableRecipientStorage", "foregroundDecryptAndLedgerCommit"
        ])
        for stage in MeshRoutedAckStage.allCases {
            #expect(stage.rawValue.allSatisfy { $0.isASCII }, "\(stage)")
        }
    }

    @Test func theTableMapsEachRegisteredTypeToItsStage() {
        let table = MeshRoutedAckStageTable.increment1
        #expect(table.stage(for: MeshRoutedTypeToken.photo) == .durableRecipientStorage)
        #expect(table.stage(for: MeshRoutedTypeToken.tempMessage) == .durableRecipientStorage)
        #expect(table.stage(for: MeshRoutedTypeToken.heart) == .foregroundDecryptAndLedgerCommit)
    }

    /// The three REGISTERED spellings, pinned as literals.
    ///
    /// `theTableMapsEachRegisteredTypeToItsStage` and `theTableHasNoDuplicateTokens` compare the
    /// constants to themselves, so they hold under ANY spelling — but these tokens are origin-signed
    /// manifest vocabulary that travels on the wire in `MeshRoutedManifest.typeToken` and keys the
    /// whole ack matrix. A rename would be a silent wire break with a clean build, which is exactly
    /// what the frozen-token rule exists to catch. Same idiom the receipt's `PayloadType` spelling
    /// gets in `theTokenVocabularyIsShared`.
    @Test func theRegisteredTypeTokensAreFrozen() {
        #expect(MeshRoutedTypeToken.photo == "fernlet.mesh.routed-type.photo.v1")
        #expect(MeshRoutedTypeToken.tempMessage == "fernlet.mesh.routed-type.temp-message.v1")
        #expect(MeshRoutedTypeToken.heart == "fernlet.mesh.routed-type.heart.v1")
    }

    /// The reserved token is a valid spelling and is deliberately unregistered: a door with no
    /// handler behind it is worse than no door.
    @Test func controlIsFrozenButUnregistered() {
        #expect(MeshRoutedTypeToken.control == "fernlet.mesh.routed-type.control.v1")
        #expect(MeshRoutedTypeToken.control.utf8.count <= MeshRoutedManifestFormat.maxTypeTokenLength)
        #expect(MeshRoutedAckStageTable.increment1.stage(for: MeshRoutedTypeToken.control) == nil)
    }

    @Test func anUnknownTokenIsNilNotADefault() {
        #expect(MeshRoutedAckStageTable.increment1.stage(for: "fernlet.mesh.routed-type.unknown.v1") == nil)
        #expect(MeshRoutedAckStageTable.increment1.stage(for: "") == nil)
        #expect(MeshRoutedAckStageTable.increment1
            .stage(for: MeshRoutedManifestFixtures.typeToken) == nil)
    }

    @Test func theTableHasNoDuplicateTokens() {
        #expect(MeshRoutedAckStageTable.increment1.tokens.count == 3)
        #expect(MeshRoutedAckStageTable.increment1.tokens == [
            MeshRoutedTypeToken.photo, MeshRoutedTypeToken.tempMessage, MeshRoutedTypeToken.heart
        ])
        // Every token stays inside the manifest's own width bound.
        for token in MeshRoutedAckStageTable.increment1.tokens {
            #expect(token.utf8.count <= MeshRoutedManifestFormat.maxTypeTokenLength, "\(token)")
        }
    }

    /// Both legs, and neither is a caller's word: the per-gift judgement count, and the ledger's own
    /// proof.
    @Test func aHeartAckRefusesUnlessBothLegsHold() throws {
        let ledger = MeshRoutedAckFixtures.ledger()
        let gift = UUID()
        let outcome = MeshHeartCommit.commit([MeshRoutedAckFixtures.heart(gift)], into: ledger)
        let proof = try #require(ledger.commitProof(for: gift))

        #expect(MeshRoutedHeartAck(outcome: outcome, giftID: gift, proof: proof)?.judgementsForGift == 1)

        // Leg 1: a gift the pass never judged, and a gift judged twice.
        let unjudged = MeshHeartCommitOutcome(receivedGiftIDs: [], refusedGiftIDs: [], judgements: 0)
        #expect(MeshRoutedHeartAck(outcome: unjudged, giftID: gift, proof: proof) == nil)
        let twice = MeshHeartCommitOutcome(
            receivedGiftIDs: [gift], refusedGiftIDs: [gift], judgements: 2
        )
        #expect(MeshRoutedHeartAck(outcome: twice, giftID: gift, proof: proof) == nil)

        // Leg 2: a proof for a DIFFERENT gift closes nothing.
        let elsewhere = UUID()
        let otherOutcome = MeshHeartCommit.commit(
            [MeshRoutedAckFixtures.heart(elsewhere, sender: "bob")], into: ledger
        )
        let otherProof = try #require(ledger.commitProof(for: elsewhere))
        #expect(MeshRoutedHeartAck(outcome: otherOutcome, giftID: gift, proof: otherProof) == nil)
    }

    /// The batch shape, pinned: two hearts in one pass judge twice, and BOTH build evidence. A
    /// per-pass leg would have failed both — silently, until expiry.
    @Test func aTwoHeartBatchReceiptsBothHearts() throws {
        let ledger = MeshRoutedAckFixtures.ledger()
        let first = UUID()
        let second = UUID()
        let outcome = MeshHeartCommit.commit(
            [MeshRoutedAckFixtures.heart(first, sender: "alice"),
             MeshRoutedAckFixtures.heart(second, sender: "bob")],
            into: ledger
        )
        #expect(outcome.judgements == 2, "the shipped commit door is a BATCH door")
        #expect(outcome.receivedGiftIDs.count == 2)

        for gift in [first, second] {
            let ack = try #require(MeshRoutedHeartAck(outcome: outcome, giftID: gift, ledger: ledger),
                                   "a per-pass leg would strand \(gift)")
            #expect(ack.giftID == gift)
            #expect(ack.judgementsForGift == 1)
        }
    }

    /// Legs 2 and 3 come from the ledger and nowhere else: no proof for a gift it never stored, and
    /// none for a write that did not land even though the receive answered `true`.
    @Test func theLedgerIsTheOnlySourceOfLegsTwoAndThree() {
        let ledger = MeshRoutedAckFixtures.ledger()
        #expect(ledger.commitProof(for: UUID()) == nil)

        let unwritable = MeshRoutedAckFixtures.ledger(writeData: { _, _ in
            throw MeshRoutedAckWriteFailure()
        })
        let gift = UUID()
        let outcome = MeshHeartCommit.commit([MeshRoutedAckFixtures.heart(gift)], into: unwritable)
        #expect(outcome.receivedGiftIDs == [gift], "the in-memory receive still accepted it")
        #expect(unwritable.receivedHearts.map(\.id) == [gift])
        #expect(unwritable.commitProof(for: gift) == nil,
                "an applied-but-unpersisted mutation is not a durable ledger write")
        #expect(MeshRoutedHeartAck(outcome: outcome, giftID: gift, ledger: unwritable) == nil)
    }

    /// The liveness half: a gift the ledger has ALREADY recorded is refused on a re-offer and still
    /// yields evidence, because the proof reads the ledger's stored answer rather than this pass's.
    @Test func anAlreadyRecordedGiftStillYieldsEvidence() throws {
        let ledger = MeshRoutedAckFixtures.ledger()
        let gift = UUID()
        _ = MeshHeartCommit.commit([MeshRoutedAckFixtures.heart(gift)], into: ledger)

        let again = MeshHeartCommit.commit([MeshRoutedAckFixtures.heart(gift)], into: ledger)
        #expect(again.refusedGiftIDs == [gift])
        #expect(again.receivedGiftIDs.isEmpty)
        let ack = try #require(MeshRoutedHeartAck(outcome: again, giftID: gift, ledger: ledger))
        #expect(ack.judgementsForGift == 1)
    }
}

// MARK: - The per-type matrix

/// One section per plan §11 clause, plus the refusals that come before any stage is asked.
@MainActor
@Suite(.serialized)
struct MeshRoutedDeliveryAckTests {

    private typealias Fixture = MeshRoutedStoreFixtures
    private typealias Ack = MeshRoutedAckFixtures

    // MARK: durableRecipientStorage — photos and text

    @Test func aPhotoIsFinalOnDurableStorageWithNoDecryptInThePath() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        MeshRoutedCustodyFixtures.stageAll(rig)
        #expect(MeshRoutedCustodyFixtures.witness(MeshRoutedCustodyFixtures.commit(rig)) != nil)

        let outcome = MeshRoutedCustodyFixtures.commitDelivery(rig)
        let witness = try #require(MeshRoutedCustodyFixtures.deliveryWitness(outcome), "\(outcome)")
        #expect(witness.ackStage == .durableRecipientStorage)
        #expect(witness.recipientFingerprint == rig.custodian.localFingerprint)
        #expect(witness.originFingerprint == rig.origin.localFingerprint)
        #expect(Ack.record(rig)?.deliveredAt == witness.deliveredAt)
    }

    @Test func aTextItemUsesTheSameStageAsAPhoto() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try MeshRoutedCustodyFixtures.rig(
            scope: scope, typeToken: MeshRoutedTypeToken.tempMessage
        )
        MeshRoutedCustodyFixtures.stageAll(rig)
        _ = MeshRoutedCustodyFixtures.commit(rig)

        let witness = try #require(
            MeshRoutedCustodyFixtures.deliveryWitness(MeshRoutedCustodyFixtures.commitDelivery(rig))
        )
        #expect(witness.ackStage == .durableRecipientStorage)
    }

    @Test func aPhotoWhoseDurableStorageSeamRefusedGetsNoReceipt() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        MeshRoutedCustodyFixtures.stageAll(rig)   // complete, but NO custody commit

        let outcome = MeshRoutedCustodyFixtures.commitDelivery(rig)
        #expect(outcome.value == .unsatisfied(.custodyNotCommitted), "\(outcome)")
        let record = try #require(Ack.record(rig))
        #expect(record.deliveredAt == nil)
        #expect(record.deliveryTarget?.state(of: rig.custodian.localFingerprint) != .delivered)
        #expect(MeshRoutedCustodyFixtures.loadedIndex(rig.store)?
            .outstandingDestinations(for: rig.key, in: rig.rig.roster)
            .contains(rig.custodian.localFingerprint) == true)
    }

    @Test func anIncompleteItemGetsNoReceipt() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        Ack.admitManifestOnly(rig)
        let staged = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            rig.store.stagingChunk(rig.chunks[0], now: Fixture.now)
        }
        #expect(staged.value != nil)

        let outcome = MeshRoutedCustodyFixtures.commitDelivery(rig)
        #expect(outcome.value == .unsatisfied(.itemIncomplete(received: 1, expected: rig.chunks.count)),
                "\(outcome)")
        #expect(Ack.record(rig)?.deliveredAt == nil)
    }

    // MARK: foregroundDecryptAndLedgerCommit — hearts

    @Test func aHeartIsNotFinalOnDurableCiphertextAlone() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.heartRig(scope)
        MeshRoutedCustodyFixtures.stageAll(rig)
        #expect(MeshRoutedCustodyFixtures.witness(MeshRoutedCustodyFixtures.commit(rig)) != nil)

        let outcome = MeshRoutedCustodyFixtures.commitDelivery(rig)
        #expect(outcome.value == .unsatisfied(.ledgerJudgementMissing), "\(outcome)")
        let record = try #require(Ack.record(rig))
        #expect(record.deliveredAt == nil)
        #expect(record.isCustodied, "the ciphertext IS held — custody is not delivery")
        #expect(record.deliveryTarget?.state(of: rig.custodian.localFingerprint) != .delivered)
    }

    @Test func aHeartIsFinalAfterTheForegroundCommit() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.heartRig(scope)
        let ledger = Ack.ledger()
        MeshRoutedCustodyFixtures.stageAll(rig)
        _ = MeshRoutedCustodyFixtures.commit(rig)

        let evidence = try Ack.evidence(for: rig, in: ledger)
        let outcome = MeshRoutedCustodyFixtures.commitDelivery(rig, evidence: evidence)
        let witness = try #require(MeshRoutedCustodyFixtures.deliveryWitness(outcome), "\(outcome)")
        #expect(witness.ackStage == .foregroundDecryptAndLedgerCommit)
        #expect(Ack.record(rig)?.deliveredAt == witness.deliveredAt)
        // The rung has NOT moved yet: only a signed receipt writes it.
        #expect(Ack.record(rig)?.deliveryTarget?.state(of: rig.custodian.localFingerprint) != .delivered)

        let receipt = try MeshRecipientReceipt.signed(
            witness: witness, manifest: rig.manifest, identity: rig.custodian
        )
        #expect(Ack.ingest(receipt, into: rig).value?.target != nil)
        #expect(Ack.record(rig)?.deliveryTarget?.state(of: rig.custodian.localFingerprint) == .delivered)
    }

    /// Two routed hearts committed in ONE ledger pass both acknowledge — the store-level companion
    /// to the batch-shape assertion, and the case a per-pass leg would have stranded silently.
    @Test func twoRoutedHeartsInOneBatchBothReceipt() throws {
        let first = Fixture.scope()
        let second = Fixture.scope()
        defer { Fixture.tearDown(first); Fixture.tearDown(second) }
        let rigA = try Ack.heartRig(first)
        let rigB = try Ack.heartRig(second)
        let ledger = Ack.ledger()
        for rig in [rigA, rigB] {
            MeshRoutedCustodyFixtures.stageAll(rig)
            _ = MeshRoutedCustodyFixtures.commit(rig)
        }

        let outcome = MeshHeartCommit.commit(
            [Ack.heart(rigA.manifest.itemID, sender: "alice"),
             Ack.heart(rigB.manifest.itemID, sender: "bob")],
            into: ledger
        )
        #expect(outcome.judgements == 2)

        for rig in [rigA, rigB] {
            let ack = try #require(
                MeshRoutedHeartAck(outcome: outcome, giftID: rig.manifest.itemID, ledger: ledger)
            )
            let acknowledged = MeshRoutedCustodyFixtures.commitDelivery(
                rig, evidence: .heartLedgerCommit(ack)
            )
            #expect(MeshRoutedCustodyFixtures.deliveryWitness(acknowledged) != nil, "\(acknowledged)")
        }
    }

    /// The ledger is asked once per gift, ever: the stored ack instant is the durable gate that stops
    /// the second ask, and a re-commit is byte-identical.
    @Test func aSecondCommitOfTheSameHeartYieldsTheSameJudgementAndNoSecondCount() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.heartRig(scope)
        let ledger = Ack.ledger()
        MeshRoutedCustodyFixtures.stageAll(rig)
        _ = MeshRoutedCustodyFixtures.commit(rig)
        let evidence = try Ack.evidence(for: rig, in: ledger)
        let firstWitness = try #require(MeshRoutedCustodyFixtures.deliveryWitness(
            MeshRoutedCustodyFixtures.commitDelivery(rig, evidence: evidence)
        ))
        let sealed = try Data(contentsOf: rig.store.indexURL)

        // No fresh evidence, and no second ask of the ledger.
        let again = MeshRoutedCustodyFixtures.commitDelivery(rig, evidence: .none)
        let secondWitness = try #require(MeshRoutedCustodyFixtures.deliveryWitness(again), "\(again)")
        #expect(secondWitness.deliveredAt == firstWitness.deliveredAt)
        #expect(try Data(contentsOf: rig.store.indexURL) == sealed, "a re-commit re-wrote the index")

        let first = try MeshRecipientReceipt.signed(
            witness: firstWitness, manifest: rig.manifest, identity: rig.custodian
        )
        let second = try MeshRecipientReceipt.signed(
            witness: secondWitness, manifest: rig.manifest, identity: rig.custodian
        )
        #expect(canonicalBytes(for: first) == canonicalBytes(for: second))
        #expect(first.receiptID == second.receiptID)
    }

    @Test func aHeartEvidenceForAnotherItemIsRefused() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.heartRig(scope)
        let ledger = Ack.ledger()
        MeshRoutedCustodyFixtures.stageAll(rig)
        _ = MeshRoutedCustodyFixtures.commit(rig)

        let elsewhere = UUID()
        let outcome = MeshHeartCommit.commit([Ack.heart(elsewhere)], into: ledger)
        let ack = try #require(MeshRoutedHeartAck(outcome: outcome, giftID: elsewhere, ledger: ledger))

        let refused = MeshRoutedCustodyFixtures.commitDelivery(rig, evidence: .heartLedgerCommit(ack))
        #expect(refused.value == .unsatisfied(.evidenceForAnotherItem), "\(refused)")
        #expect(Ack.record(rig)?.deliveredAt == nil)
    }

    // MARK: immediate — the reserved control stage

    @Test func controlIsFinalImmediatelyWithoutHeldChunks() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try MeshRoutedCustodyFixtures.rig(
            scope: scope, typeToken: MeshRoutedTypeToken.control
        )
        Ack.admitManifestOnly(rig)
        let record = try #require(Ack.record(rig))
        #expect(record.isComplete == false)
        #expect(record.isCustodied == false)

        let outcome = MeshRoutedCustodyFixtures.commitDelivery(rig, stages: Ack.controlTable)
        let witness = try #require(MeshRoutedCustodyFixtures.deliveryWitness(outcome), "\(outcome)")
        #expect(witness.ackStage == .immediate)
        #expect(Ack.record(rig)?.deliveredAt == witness.deliveredAt,
                "even `immediate` acknowledges only after the ack record's own write returned")
    }

    // MARK: refusals, before any stage is asked

    @Test func anUnknownTypeTokenRefusesAndAcknowledgesNothing() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try MeshRoutedCustodyFixtures.rig(scope: scope)   // the golden-fixture token
        MeshRoutedCustodyFixtures.stageAll(rig)
        _ = MeshRoutedCustodyFixtures.commit(rig)
        let sealed = try Data(contentsOf: rig.store.indexURL)

        let outcome = MeshRoutedCustodyFixtures.commitDelivery(rig)
        #expect(outcome.refusal == .unknownTypeToken, "\(outcome)")
        #expect(Ack.record(rig)?.deliveredAt == nil)
        #expect(try Data(contentsOf: rig.store.indexURL) == sealed, "a refused ack wrote to the store")
    }

    @Test func aNonDestinationCannotAcknowledge() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        MeshRoutedCustodyFixtures.stageAll(rig)
        _ = MeshRoutedCustodyFixtures.commit(rig)

        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            rig.store.committingDelivery(
                item: rig.key, recipient: "fp404", stages: .increment1,
                evidence: .none, now: Fixture.now
            )
        }
        #expect(outcome.refusal == .notADestination, "\(outcome)")
        #expect(Ack.record(rig)?.deliveredAt == nil)
    }

    /// The wall the split buys: naming a PEER destination moves no rung for that peer, and the
    /// witness it yields is refused at the mint — so no signed receipt exists either.
    @Test func oneDestinationCannotAcknowledgeOnAnothersBehalf() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        MeshRoutedCustodyFixtures.stageAll(rig)
        _ = MeshRoutedCustodyFixtures.commit(rig)
        let peer = try #require(rig.otherDestinations.first)
        let before = try #require(Ack.record(rig))

        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            rig.store.committingDelivery(
                item: rig.key, recipient: peer, stages: .increment1,
                evidence: .none, now: Fixture.now
            )
        }
        let witness = try #require(MeshRoutedCustodyFixtures.deliveryWitness(outcome), "\(outcome)")

        let after = try #require(Ack.record(rig))
        #expect(after.delivery == before.delivery, "a caller's word moved a peer's rung")
        #expect(after.recipientReceipts.isEmpty)
        #expect(MeshRoutedCustodyFixtures.loadedIndex(rig.store)?
            .outstandingDestinations(for: rig.key, in: rig.rig.roster).contains(peer) == true)
        #expect(throws: MeshRecipientReceiptMintError.notTheRecipient) {
            _ = try MeshRecipientReceipt.signed(
                witness: witness, manifest: rig.manifest, identity: rig.custodian
            )
        }
    }

    @Test func aParkedItemCannotBeDelivered() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            for chunk in rig.chunks {
                #expect(rig.store.stagingChunk(chunk, now: Fixture.now).value != nil)
            }
        }
        #expect(Ack.record(rig)?.isParked == true)

        let outcome = MeshRoutedCustodyFixtures.commitDelivery(rig)
        #expect(outcome.refusal == .manifestMismatch, "\(outcome)")
        #expect(Ack.record(rig)?.deliveredAt == nil)
    }

    /// A stored map this device cannot restore takes the CORRUPTION route, never a refusal — and
    /// nothing is re-derived over it.
    @Test func anUnrestorableDeliveryMapTakesTheCorruptionRoute() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshRoutedStore(scope: scope)
        let manifest = MeshRoutedManifestFixtures.manifest()
            .replacing(typeToken: MeshRoutedTypeToken.photo)
        let broken = MeshRoutedDeliveryRecord(
            contentID: manifest.itemID,
            progress: ["fp002": MeshRoutedDeliveryProgress(token: "departed", custodian: nil)]
        )
        try Fixture.plant(
            MeshRoutedIndex(items: [Self.record(manifest, delivery: broken)]), into: store
        )
        let sealed = try Data(contentsOf: store.indexURL)

        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            store.committingDelivery(
                item: MeshRoutedItemKey(manifest), recipient: "fp002", stages: .increment1,
                evidence: .none, now: Fixture.now
            )
        }
        #expect(outcome.unavailability
                == .corrupt(MeshRoutedCorruption(detail: .undecodableJSON("deliveryRestore"))),
                "\(outcome)")
        #expect(try Data(contentsOf: store.indexURL) == sealed)
    }

    /// A complete, custodied, manifest-bound record with no chunk files — planted so an at-rest
    /// state no shipped writer produces can be driven through the doors.
    private static func record(
        _ manifest: MeshRoutedManifest,
        delivery: MeshRoutedDeliveryRecord
    ) -> MeshRoutedItemRecord {
        MeshRoutedItemRecord(
            key: MeshRoutedItemKey(manifest),
            contentHash: manifest.contentHash,
            chunkCount: 0,
            expiresAt: manifest.expiresAt,
            manifest: manifest,
            firstSeenAt: MeshRoutedManifestFixtures.base,
            custodiedAt: MeshRoutedManifestFixtures.base,
            deliveredAt: nil,
            chunks: [],
            delivery: delivery,
            receipts: [],
            recipientReceipts: []
        )
    }
}

// MARK: - Durability, §19.5 and the locked device

/// The ack record is what must survive a restart, and nothing is acknowledged that would not.
@MainActor
@Suite(.serialized)
struct MeshRoutedDeliveryDurabilityTests {

    private typealias Fixture = MeshRoutedStoreFixtures
    private typealias Ack = MeshRoutedAckFixtures

    @Test func theAckInstantIsDurableBeforeTheReceiptExists() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        let receipt = try MeshRoutedCustodyFixtures.recipientReceipt(rig)

        // A NEW store instance on the same scope — everything the receipt claims survived the
        // process that made it.
        let reopened = MeshRoutedStore(scope: scope)
        let recommitted = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            reopened.committingDelivery(
                item: rig.key, recipient: rig.custodian.localFingerprint,
                stages: .increment1, evidence: .none, now: Fixture.now.addingTimeInterval(30)
            )
        }
        let second = try #require(MeshRoutedCustodyFixtures.deliveryWitness(recommitted))
        #expect(second.deliveredAt == receipt.receivedAt, "a re-commit must re-use the stored instant")

        let remint = try MeshRecipientReceipt.signed(
            witness: second, manifest: rig.manifest, identity: rig.custodian
        )
        #expect(canonicalBytes(for: remint) == canonicalBytes(for: receipt))
        #expect(remint.receiptID == receipt.receiptID)

        let verifier = MeshRecipientReceiptVerifier(
            meshID: rig.rig.meshID, hardDeadline: MeshRoutedManifestFixtures.hardDeadline,
            ledger: rig.rig.ledger, manifest: rig.manifest
        )
        #expect(verifier.verify(receipt) == nil)
        #expect(verifier.verify(remint) == nil)
    }

    /// The crash window, ship-tested rather than described: an ack stamped with no stored receipt is
    /// ENUMERATED, and the recovery re-mints without touching the ledger.
    @Test func anAckWithNoStoredReceiptIsEnumeratedAndRecoverable() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.heartRig(scope)
        let ledger = Ack.ledger()
        MeshRoutedCustodyFixtures.stageAll(rig)
        _ = MeshRoutedCustodyFixtures.commit(rig)
        let evidence = try Ack.evidence(for: rig, in: ledger)
        let first = try #require(MeshRoutedCustodyFixtures.deliveryWitness(
            MeshRoutedCustodyFixtures.commitDelivery(rig, evidence: evidence)
        ))
        // …and then STOP: no mint, no ingest. That is the reachable crash window.

        let reopened = MeshRoutedStore(scope: scope)
        let awaiting = try #require(MeshRoutedCustodyFixtures.loadedIndex(reopened))
            .itemsAwaitingLocalAck(at: Fixture.now, for: rig.custodian.localFingerprint)
        #expect(awaiting.map(\.key) == [rig.key])
        #expect(awaiting.first?.isAcknowledgedLocally == true)

        // The recovery: a re-commit with NO fresh evidence, because the durable ack IS the satisfied
        // precondition — the ledger cannot be asked twice.
        let recovered = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            reopened.committingDelivery(
                item: rig.key, recipient: rig.custodian.localFingerprint,
                stages: .increment1, evidence: .none, now: Fixture.now
            )
        }
        let second = try #require(MeshRoutedCustodyFixtures.deliveryWitness(recovered), "\(recovered)")
        #expect(second.deliveredAt == first.deliveredAt)
        let receipt = try MeshRecipientReceipt.signed(
            witness: second, manifest: rig.manifest, identity: rig.custodian
        )
        #expect(Ack.ingest(receipt, into: rig).value?.target != nil)
        #expect(Ack.record(rig)?.deliveryTarget?.state(of: rig.custodian.localFingerprint) == .delivered)
        #expect(MeshRoutedCustodyFixtures.loadedIndex(rig.store)?
            .itemsAwaitingLocalAck(at: Fixture.now, for: rig.custodian.localFingerprint).isEmpty == true)
    }

    /// The invariant the split buys, stated once: no `delivered` entry exists without a stored
    /// receipt from that very signer.
    @Test func theRungIsWrittenOnlyByTheReceiptDoor() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        _ = try MeshRoutedCustodyFixtures.recipientReceipt(rig)

        let record = try #require(Ack.record(rig))
        let target = try #require(record.deliveryTarget)
        var delivered = 0
        for destination in target.destinations where target.state(of: destination) == .delivered {
            delivered += 1
            let evidence = record.recipientReceipt(from: destination)
            #expect(evidence != nil, "\(destination) is delivered with no receipt behind it")
            #expect(evidence?.recipientFingerprint == destination)
        }
        #expect(delivered == 1, "exactly this device's own destination closed")
    }

    @Test func anAckWhoseIndexWriteFailsMintsNoWitness() throws {
        let scope = Fixture.scope()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scope.directory.path)
            Fixture.tearDown(scope)
        }
        let rig = try Ack.photoRig(scope)
        MeshRoutedCustodyFixtures.stageAll(rig)
        _ = MeshRoutedCustodyFixtures.commit(rig)
        let before = try Data(contentsOf: rig.store.indexURL)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: scope.directory.path
        )
        let outcome = MeshRoutedCustodyFixtures.commitDelivery(rig)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scope.directory.path
        )

        #expect(MeshRoutedCustodyFixtures.deliveryWitness(outcome) == nil,
                "a failed index write minted a witness")
        guard case .unavailable(.notWritten(let detail)) = outcome else {
            Issue.record("an unwritable index answered \(outcome)")
            return
        }
        #expect(detail != MeshRoutedStore.indexFileName, "the failure must name the write error, not the file")
        #expect(detail.isEmpty == false)
        #expect(try Data(contentsOf: rig.store.indexURL) == before, "the previous index must be byte-identical")
        // …and no receipt exists for anything a restart would lose.
        #expect(Ack.record(rig)?.deliveredAt == nil)
        #expect(Ack.record(rig)?.recipientReceipts.isEmpty == true)
    }

    /// §19.5's fifth wrinkle at both new doors: before first unlock the ack record cannot be sealed,
    /// so every path refuses BY NAME and acknowledges nothing.
    @Test func beforeFirstUnlockEveryAckPathRefusesByName() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        let receipt = try MeshRoutedCustodyFixtures.recipientReceipt(rig)
        let before = Fixture.snapshot(scope)

        let refused = DeviceBindingID.$testOverride.withValue(.unavailable) {
            (
                ack: rig.store.committingDelivery(
                    item: rig.key, recipient: rig.custodian.localFingerprint,
                    stages: .increment1, evidence: .none, now: Fixture.now
                ),
                ingest: rig.store.recordingRecipientReceipt(
                    item: rig.key, receipt: receipt, now: Fixture.now
                ),
                forward: rig.store.forwardableRecipientReceipts(item: rig.key)
            )
        }
        #expect(refused.ack.unavailability?.logToken == "refused:installBindingUnavailable")
        #expect(refused.ingest.unavailability?.logToken == "refused:installBindingUnavailable")
        #expect(refused.forward.unavailability?.logToken == "refused:installBindingUnavailable")
        #expect(MeshRoutedCustodyFixtures.deliveryWitness(refused.ack) == nil)
        #expect(Fixture.snapshot(scope) == before, "a refused ack attempt wrote to the store")
    }

    /// `deferred`, `refused` and `absent` are three distinct answers at BOTH new doors, and the first
    /// two are retryable.
    @Test func aDeferredLoadIsNeverReportedAsAbsent() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        let receipt = try MeshRoutedCustodyFixtures.recipientReceipt(rig)

        let deferred = DeviceBindingID.$testOverride.withValue(.readError) {
            (
                ack: rig.store.committingDelivery(
                    item: rig.key, recipient: rig.custodian.localFingerprint,
                    stages: .increment1, evidence: .none, now: Fixture.now
                ),
                ingest: rig.store.recordingRecipientReceipt(
                    item: rig.key, receipt: receipt, now: Fixture.now
                )
            )
        }
        for cause in [deferred.ack.unavailability, deferred.ingest.unavailability] {
            let named = try #require(cause)
            guard case .deferred = named else {
                Issue.record("a read error presented as \(named.logToken)")
                return
            }
            #expect(named.isRetryable)
        }
        let refusal = MeshRoutedUnavailability.refused(
            MeshRoutedSealRefusal(operation: .seal, cause: .installBindingUnavailable)
        )
        #expect(refusal.isRetryable)
        #expect(MeshRoutedUnavailability.corrupt(MeshRoutedCorruption(detail: .emptyFile)).isRetryable == false)
    }

    /// A heart's ciphertext-only state survives a restart and is enumerable as awaiting the
    /// foreground pass — nothing has been acknowledged, and the destination is still outstanding.
    @Test func aHeartsCiphertextOnlyStateSurvivesARestartAndIsEnumerable() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.heartRig(scope)
        MeshRoutedCustodyFixtures.stageAll(rig)
        _ = MeshRoutedCustodyFixtures.commit(rig)
        #expect(MeshRoutedCustodyFixtures.commitDelivery(rig).value == .unsatisfied(.ledgerJudgementMissing))

        let reopened = MeshRoutedStore(scope: scope)
        let index = try #require(MeshRoutedCustodyFixtures.loadedIndex(reopened))
        #expect(index.itemsAwaitingLocalAck(at: Fixture.now, for: rig.custodian.localFingerprint)
            .map(\.key) == [rig.key])
        #expect(index.outstandingDestinations(for: rig.key, in: rig.rig.roster)
            .contains(rig.custodian.localFingerprint))
        #expect(index.record(for: rig.key)?.deliveredAt == nil)
    }

    /// A repair clears custody, because the bytes are gone — but it does NOT undo an acknowledgement
    /// already given: plan §11's final ack is a fact, and `delivered` is terminal.
    @Test func aRepairThatDropsAChunkDoesNotUndoAnAcknowledgement() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        _ = try MeshRoutedCustodyFixtures.recipientReceipt(rig)
        let acknowledged = try #require(Ack.record(rig)?.deliveredAt)

        let files = MeshRoutedCustodyFixtures.chunkFilesOnDisk(scope)
        try FileManager.default.removeItem(at: try #require(files.first))
        let recommitted = MeshRoutedCustodyFixtures.commit(rig)
        guard case .completed(.incomplete) = recommitted else {
            Issue.record("a lost chunk file answered \(recommitted)")
            return
        }

        let record = try #require(Ack.record(rig))
        #expect(record.custodiedAt == nil, "custody asserts bytes we hold")
        #expect(record.deliveredAt == acknowledged, "an acknowledgement already given is a fact")
        #expect(record.deliveryTarget?.state(of: rig.custodian.localFingerprint) == .delivered)
        #expect(record.recipientReceipt(from: rig.custodian.localFingerprint) != nil)
    }

    /// The stated cost of binding the heart stage to held custody, bounded in a test: an unacked
    /// heart whose custody a repair cleared stays ENUMERABLE, refuses by name, and completes after a
    /// re-fetch — with no second ask of the ledger.
    @Test func aRepairedAwayCustodyLeavesAnUnackedHeartEnumerableNotStranded() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.heartRig(scope)
        let ledger = Ack.ledger()
        MeshRoutedCustodyFixtures.stageAll(rig)
        _ = MeshRoutedCustodyFixtures.commit(rig)
        let evidence = try Ack.evidence(for: rig, in: ledger)   // the ledger commit landed…

        // …and then the bytes went away before the ack could be written.
        let files = MeshRoutedCustodyFixtures.chunkFilesOnDisk(scope)
        try FileManager.default.removeItem(at: try #require(files.first))
        _ = MeshRoutedCustodyFixtures.commit(rig)
        #expect(Ack.record(rig)?.isCustodied == false)

        let index = try #require(MeshRoutedCustodyFixtures.loadedIndex(rig.store))
        #expect(index.itemsAwaitingLocalAck(at: Fixture.now, for: rig.custodian.localFingerprint)
            .map(\.key) == [rig.key], "a repaired-away heart must stay enumerable")
        #expect(index.outstandingDestinations(for: rig.key, in: rig.rig.roster)
            .contains(rig.custodian.localFingerprint))

        // The repair took a chunk with it, so the retry names the incompleteness BY NAME rather
        // than acknowledging on a guess.
        let retried = MeshRoutedCustodyFixtures.commitDelivery(rig, evidence: evidence)
        #expect(retried.value == .unsatisfied(
            .itemIncomplete(received: rig.chunks.count - 1, expected: rig.chunks.count)
        ), "\(retried)")

        // The re-fetch route: re-stage the dropped slot (the held ones are not re-admitted), and the
        // item is complete again while custody is still not committed — the second named shortfall.
        MeshRoutedCustodyFixtures.stageAll(rig)
        #expect(Ack.record(rig)?.isComplete == true)
        let uncustodied = MeshRoutedCustodyFixtures.commitDelivery(rig, evidence: evidence)
        #expect(uncustodied.value == .unsatisfied(.custodyNotCommitted), "\(uncustodied)")

        // Then custody re-commits, and the evidence still builds off the ledger's STORED answer
        // rather than a second judgement.
        _ = MeshRoutedCustodyFixtures.commit(rig)
        let reOffer = MeshHeartCommit.commit([Ack.heart(rig.manifest.itemID)], into: ledger)
        #expect(reOffer.refusedGiftIDs == [rig.manifest.itemID], "the ledger judges one gift once")
        let ack = try #require(
            MeshRoutedHeartAck(outcome: reOffer, giftID: rig.manifest.itemID, ledger: ledger)
        )
        let completed = MeshRoutedCustodyFixtures.commitDelivery(rig, evidence: .heartLedgerCommit(ack))
        #expect(MeshRoutedCustodyFixtures.deliveryWitness(completed) != nil, "\(completed)")
    }
}

// MARK: - Ingest, idempotence and the ladder

/// The one rung writer: what it advances, what it refuses, and what a second arrival costs.
@MainActor
@Suite(.serialized)
struct MeshRoutedDeliveryIngestTests {

    private typealias Fixture = MeshRoutedStoreFixtures
    private typealias Ack = MeshRoutedAckFixtures

    @Test func aPeerReceiptAdvancesOnlyItsOwnSigner() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        let receipt = try MeshRoutedCustodyFixtures.recipientReceipt(rig)
        let peer = try #require(rig.otherDestinations.first)

        let target = try #require(Ack.record(rig)?.deliveryTarget)
        #expect(target.state(of: receipt.recipientFingerprint) == .delivered)
        #expect(target.state(of: peer) == .pending, "one signer's receipt moved somebody else")
    }

    @Test func theSameReceiptAppliedTwiceLeavesTheIndexIdentical() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        let receipt = try MeshRoutedCustodyFixtures.recipientReceipt(rig)

        let before = try #require(Ack.record(rig))
        for _ in 0..<2 {
            let again = Ack.ingest(receipt, into: rig)
            #expect(again.value?.target != nil, "\(again)")
        }
        // The RECORD is identical, value for value. (The sealed file's bytes are not compared: the
        // seal carries a fresh nonce, so a byte comparison would assert about the sealer, not the
        // store.)
        #expect(Ack.record(rig) == before, "a re-arrival changed the record")
        #expect(Ack.record(rig)?.recipientReceipts.count == 1, "the evidence array grew")
    }

    @Test func aDeliveredDestinationDisappearsFromEveryOutstandingEnumerator() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        let receipt = try MeshRoutedCustodyFixtures.recipientReceipt(rig)
        let me = receipt.recipientFingerprint
        let index = try #require(MeshRoutedCustodyFixtures.loadedIndex(rig.store))
        let branch = MeshBranchView(
            roster: rig.rig.roster, reachable: Set(rig.manifest.destinations),
            selfFingerprint: rig.origin.localFingerprint
        )

        #expect(index.outstandingDestinations(for: rig.key, in: rig.rig.roster).contains(me) == false)
        #expect(index.outstandingReachable(for: rig.key, from: branch, in: rig.rig.roster)
            .contains(me) == false)
        #expect(index.outstandingItems(at: Fixture.now, in: rig.rig.roster)[me] == nil)
        #expect(index.itemsFullyDelivered(at: Fixture.now, in: rig.rig.roster).isEmpty,
                "one destination is still outstanding")

        // Close the peer too, and the item reports fully delivered.
        let peer = try #require(rig.otherDestinations.first)
        let peerReceipt = try Self.peerReceipt(rig, from: peer)
        #expect(Ack.ingest(peerReceipt, into: rig).value?.target != nil)
        let closed = try #require(MeshRoutedCustodyFixtures.loadedIndex(rig.store))
        #expect(closed.itemsFullyDelivered(at: Fixture.now, in: rig.rig.roster).map(\.key) == [rig.key])
        #expect(closed.itemsAwaitingHandoff(at: Fixture.now, in: rig.rig.roster).isEmpty)
    }

    /// A recipient's own inbox copy is "fully delivered" and is emphatically NOT reclaimable — the
    /// distinction that stops item 9 deleting the only copy of a received photo.
    @Test func aRecipientsOwnInboxCopyIsFullyDeliveredButNotReclaimable() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        let receipt = try MeshRoutedCustodyFixtures.recipientReceipt(rig)
        let peer = try #require(rig.otherDestinations.first)
        #expect(Ack.ingest(try Self.peerReceipt(rig, from: peer), into: rig).value?.target != nil)
        let index = try #require(MeshRoutedCustodyFixtures.loadedIndex(rig.store))

        #expect(index.itemsFullyDelivered(at: Fixture.now, in: rig.rig.roster).map(\.key) == [rig.key])
        #expect(index.record(for: rig.key)?.isDeliveredLocally == true)
        // This device IS a destination, so nothing here is reclaimable: the consumed-locally signal
        // does not exist yet, and item 9 reads only the list below.
        #expect(index.itemsReclaimableAsCustodian(
            at: Fixture.now, in: rig.rig.roster, for: receipt.recipientFingerprint
        ).isEmpty)
        // A pure courier — not a destination — is named by both.
        #expect(index.itemsReclaimableAsCustodian(
            at: Fixture.now, in: rig.rig.roster, for: "fp404"
        ).map(\.key) == [rig.key])
    }

    @Test func deliveredNeverRegresses() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        let receipt = try MeshRoutedCustodyFixtures.recipientReceipt(rig)
        let me = receipt.recipientFingerprint
        let custody = try MeshCustodyReceipt.signed(
            witness: try #require(MeshRoutedCustodyFixtures.witness(MeshRoutedCustodyFixtures.commit(rig))),
            manifest: rig.manifest, identity: rig.custodian
        )

        let regressed = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            rig.store.recordingCustodyTransfer(
                item: rig.key, for: [me], receipt: custody, now: Fixture.now
            )
        }
        #expect(regressed.value?.refusal == .alreadyDelivered, "\(regressed)")
        #expect(Ack.record(rig)?.deliveryTarget?.state(of: me) == .delivered)

        // …and a max-merge of two views keeps `delivered`, with `departed` still never encoded.
        let target = try #require(Ack.record(rig)?.deliveryTarget)
        guard case .restored(let fresh) = MeshDeliveryTarget.restoring(
            contentID: rig.manifest.itemID, destinations: rig.manifest.destinations, progress: [:]
        ) else {
            Issue.record("a fresh target for the item's own destination set refused to restore")
            return
        }
        #expect(target.merging(fresh).target?.state(of: me) == .delivered)
        let encoded = MeshRoutedDeliveryRecord(encoding: target)
        #expect(encoded.progress.values.allSatisfy { $0.token != MeshDeliveryStateToken.departed.rawValue })
    }

    @Test func aFullRecipientEvidenceSetRefusesByName() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshRoutedStore(scope: scope)
        let manifest = MeshRoutedManifestFixtures.manifest()
            .replacing(typeToken: MeshRoutedTypeToken.photo)
        let full = (0..<MeshRoutedStoreFormat.maxReceiptsPerItem).map {
            MeshRecipientReceiptFixtures.receipt().replacing(recipientFingerprint: "fpr\($0)")
        }
        try Fixture.plant(
            MeshRoutedIndex(items: [Self.record(manifest, recipientReceipts: full)]), into: store
        )
        let sealed = try Data(contentsOf: store.indexURL)

        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            store.recordingRecipientReceipt(
                item: MeshRoutedItemKey(manifest),
                receipt: MeshRecipientReceiptFixtures.receipt(), now: Fixture.now
            )
        }
        #expect(outcome.refusal == .capacityRecipientReceipts, "\(outcome)")
        #expect(try Data(contentsOf: store.indexURL) == sealed)
    }

    /// A signer the origin never addressed writes nothing, and neither does a receipt about another
    /// item.
    @Test func theIngestDoorRechecksIdentityAndDestination() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        MeshRoutedCustodyFixtures.stageAll(rig)
        _ = MeshRoutedCustodyFixtures.commit(rig)
        let witness = try #require(
            MeshRoutedCustodyFixtures.deliveryWitness(MeshRoutedCustodyFixtures.commitDelivery(rig))
        )
        let receipt = try MeshRecipientReceipt.signed(
            witness: witness, manifest: rig.manifest, identity: rig.custodian
        )
        let before = try #require(Ack.record(rig))

        let stranger = Ack.ingest(receipt.replacing(recipientFingerprint: "fp404"), into: rig)
        #expect(stranger.refusal == .notADestination, "\(stranger)")
        let mismatched = Ack.ingest(receipt.replacing(itemID: UUID()), into: rig)
        #expect(mismatched.refusal == .manifestMismatch, "\(mismatched)")
        let unknown = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            rig.store.recordingRecipientReceipt(
                item: MeshRoutedItemKey(originFingerprint: "fp404", itemID: UUID()),
                receipt: receipt, now: Fixture.now
            )
        }
        #expect(unknown.refusal == .unknownItem, "\(unknown)")
        #expect(Ack.record(rig) == before, "a refused ingest wrote to the record")
    }

    /// The courier rule as bytes: stored receipts are handed on verbatim, this device's own included.
    @Test func forwardableReceiptsAreTheStoredBytesInSignerOrder() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        let mine = try MeshRoutedCustodyFixtures.recipientReceipt(rig)
        let peer = try #require(rig.otherDestinations.first)
        let theirs = try Self.peerReceipt(rig, from: peer)
        #expect(Ack.ingest(theirs, into: rig).value?.target != nil)

        let forwarded = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            rig.store.forwardableRecipientReceipts(item: rig.key)
        }
        let receipts = try #require(forwarded.value)
        #expect(receipts.map(\.recipientFingerprint) == [mine, theirs]
            .map(\.recipientFingerprint).sorted())
        for stored in receipts {
            let original = stored.recipientFingerprint == mine.recipientFingerprint ? mine : theirs
            #expect(stored.signature == original.signature)
            #expect(canonicalBytes(for: stored) == canonicalBytes(for: original))
        }
    }

    /// The record round-trips with `delivered` entries and the new evidence array, and the two new
    /// fields decode differently on purpose.
    @Test func aSchemaTwoRecordMissingTheReceiptsKeyIsCorrupt() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshRoutedStore(scope: scope)
        let manifest = MeshRoutedManifestFixtures.manifest()
        try Fixture.plant(
            LegacyRecordIndexWire(record: LegacyItemRecordWire(manifest: manifest)), into: store
        )

        let load = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) { store.load() }
        guard case .corrupt = load else {
            Issue.record("a schema-2 record with no `recipientReceipts` key loaded as \(load)")
            return
        }

        // …while an absent `deliveredAt` is a genuine nil and loads clean.
        let clean = MeshRoutedStore(scope: Fixture.scope())
        defer { Fixture.tearDown(clean.scope) }
        try Fixture.plant(
            MeshRoutedIndex(items: [Self.record(manifest, recipientReceipts: [])]), into: clean
        )
        let reloaded = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            clean.load()
        }
        guard case .loaded(let index, _) = reloaded else {
            Issue.record("a record with no ack instant loaded as \(reloaded)")
            return
        }
        #expect(index.record(for: MeshRoutedItemKey(manifest))?.deliveredAt == nil)
    }

    /// Flagged for item 8, not fixed here: `advancingAll` stops at the first refusal, so a custody
    /// batch naming an already-delivered destination refuses the WHOLE batch. Item 8 chooses between
    /// skip-delivered and refuse-batch; item 4 changes nothing.
    @Test func aCustodyTransferBatchNamingADeliveredDestinationRefusesTheWholeBatch() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try Ack.photoRig(scope)
        let receipt = try MeshRoutedCustodyFixtures.recipientReceipt(rig)
        let peer = try #require(rig.otherDestinations.first)
        let custody = try MeshCustodyReceipt.signed(
            witness: try #require(MeshRoutedCustodyFixtures.witness(MeshRoutedCustodyFixtures.commit(rig))),
            manifest: rig.manifest, identity: rig.custodian
        )

        let batch = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            rig.store.recordingCustodyTransfer(
                item: rig.key, for: [receipt.recipientFingerprint, peer],
                receipt: custody, now: Fixture.now
            )
        }
        #expect(batch.value?.refusal == .alreadyDelivered)
        #expect(Ack.record(rig)?.deliveryTarget?.state(of: peer) == .pending,
                "nothing is half-applied — the whole batch was refused")
    }

    /// A peer's signed receipt, minted on that peer's own store so the signature is honest.
    private static func peerReceipt(
        _ rig: MeshRoutedCustodyRig,
        from peer: String
    ) throws -> MeshRecipientReceipt {
        let scope = MeshRoutedStoreFixtures.scope()
        defer { MeshRoutedStoreFixtures.tearDown(scope) }
        let identity = try #require(rig.rig.identities[peer])
        let store = MeshRoutedStore(scope: scope)
        try MeshRoutedStoreFixtures.plant(
            MeshRoutedIndex(items: [record(rig.manifest, recipientReceipts: [])]), into: store
        )
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(MeshRoutedStoreFixtures.installA)) {
            store.committingDelivery(
                item: rig.key, recipient: peer, stages: .increment1,
                evidence: .none, now: MeshRoutedStoreFixtures.now
            )
        }
        let witness = try #require(MeshRoutedCustodyFixtures.deliveryWitness(outcome), "\(outcome)")
        return try MeshRecipientReceipt.signed(
            witness: witness, manifest: rig.manifest, identity: identity
        )
    }

    /// A complete, custodied, manifest-bound record with no chunk files — planted so the peer's mint
    /// and the capacity door can be driven without staging a second copy of the content.
    private static func record(
        _ manifest: MeshRoutedManifest,
        recipientReceipts: [MeshRecipientReceipt]
    ) -> MeshRoutedItemRecord {
        MeshRoutedItemRecord(
            key: MeshRoutedItemKey(manifest),
            contentHash: manifest.contentHash,
            chunkCount: 0,
            expiresAt: manifest.expiresAt,
            manifest: manifest,
            firstSeenAt: MeshRoutedManifestFixtures.base,
            custodiedAt: MeshRoutedManifestFixtures.base,
            deliveredAt: nil,
            chunks: [],
            delivery: MeshRoutedDeliveryRecord(contentID: manifest.itemID, progress: [:]),
            receipts: [],
            recipientReceipts: recipientReceipts
        )
    }
}

// MARK: - Planted at-rest shapes

/// A schema-2 item record with **no** `recipientReceipts` key — the partial reinterpretation the hard
/// decode refuses.
private struct LegacyItemRecordWire: Encodable {
    let key: MeshRoutedItemKey
    let contentHash: Data
    let chunkCount: UInt32
    let expiresAt: Date
    let manifest: MeshRoutedManifest
    let firstSeenAt: Date
    let chunks: [MeshRoutedChunkDescriptor]
    let receipts: [MeshCustodyReceipt]

    init(manifest: MeshRoutedManifest) {
        key = MeshRoutedItemKey(manifest)
        contentHash = manifest.contentHash
        chunkCount = 0
        expiresAt = manifest.expiresAt
        self.manifest = manifest
        firstSeenAt = MeshRoutedManifestFixtures.base
        chunks = []
        receipts = []
    }
}

/// An index at the CURRENT schema whose one record is missing a key this build requires.
private struct LegacyRecordIndexWire: Encodable {
    let schemaVersion = MeshRoutedIndexSchema.current
    let items: [LegacyItemRecordWire]

    init(record: LegacyItemRecordWire) {
        items = [record]
    }
}
