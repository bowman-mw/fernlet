// MeshRoutedTypeRegistryTests.swift
// FernletTests
//
// Network migration P5 item 11 (plan §11): the routed type-token registry — "unknown type tokens are
// rejected, not forwarded; every future routed type declares size cap, destination semantics,
// relay-retention, final-ack condition, and expiry at registration."
//
// Three claims, one suite each:
//
// 1. **The registry is one value with three rows**, every column defined AS the constant or decision
//    already shipped, with the unregisterable and out-of-bound rows dropped by construction rather
//    than by comment.
// 2. **Every consumer reads it** — the mint's two new guards and its expiry, the verifier's accepted
//    set, and the ack door's stage projection. A changed row changes the consumer's answer, which is
//    the only way to prove the seam is real.
// 3. **Unknown is refused at every forwarding door**, and a fourth type registered in an injected
//    registry flows end to end with **no shipping consumer edited** — the two directions of the same
//    claim.
//
// Reachability, stated plainly (item 2's discipline): in one shipping build the drain-offer, the
// departure push, the answer builder's receipt half and the hand-off claim are UNREACHABLE — nothing
// carrying an unregistered token can be admitted, so no such record exists at rest. The cells below
// reach them the only two ways that exist: a hand-planted index (an item of an unregistered type
// staged straight into a store) and a build that narrowed its own registry
// (`routedTypeRegistryForTesting`). Neither is a production path, and neither pretends to be.
//
// Tier 1 throughout: `MeshRoutedDrainRig` on `FakePeerNetwork` plus per-instance store scopes, an
// injected clock, no radio and no wall-clock sleeps.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
@testable import ProximityKit
@testable import Fernlet

// MARK: - Fixtures

/// The fourth-type probe every consumer and door cell is driven with, plus the two registry
/// transforms P6 will make for real.
@MainActor
enum MeshRoutedTypeRegistryFixtures {

    /// A token no shipping build registers — P6's stand-in, and the "unknown" every door must refuse.
    /// Frozen English, inside ``MeshRoutedManifestFormat/maxTypeTokenLength``.
    static let probeToken = "fernlet.mesh.routed-type.p6-probe.v1"

    /// The probe's row: photo-shaped, so nothing about the flow it drives is heart-specific.
    static func probeEntry(
        maxItemByteCount: UInt64? = nil,
        destinations: MeshRoutedDestinationSemantics = .fullRosterAtCreation,
        finalAck: MeshRoutedAckStage = .durableRecipientStorage,
        token: String? = nil
    ) -> MeshRoutedTypeEntry {
        MeshRoutedTypeEntry(
            token: token ?? probeToken,
            maxItemByteCount: maxItemByteCount ?? MeshRoutedManifestFormat.maxContentByteCount,
            destinations: destinations,
            relayRetention: .originRetainsUntilDeparture,
            finalAck: finalAck,
            expiry: .meshHardDeadlinePlusGrace,
            canonicalStore: .friendPhotoWall
        )
    }

    /// The shipping registry's own rows, read back out of it so no cell restates a column.
    static var shippingRows: [MeshRoutedTypeEntry] {
        MeshRoutedTypeRegistry.increment1.tokens.compactMap {
            MeshRoutedTypeRegistry.increment1.entry(for: $0)
        }
    }

    /// The shipping registry plus one more row — P6's "add a row, not a branch".
    static func widened(with entry: MeshRoutedTypeEntry) -> MeshRoutedTypeRegistry {
        MeshRoutedTypeRegistry(entries: shippingRows + [entry])
    }

    /// The shipping registry minus one row — a build that narrowed itself, which is the only way the
    /// forwarding gates become reachable for a type this build once held.
    static func narrowed(dropping token: String) -> MeshRoutedTypeRegistry {
        MeshRoutedTypeRegistry(entries: shippingRows.filter { $0.token != token })
    }

    /// A registry holding only the probe row.
    static func onlyProbe(_ entry: MeshRoutedTypeEntry? = nil) -> MeshRoutedTypeRegistry {
        MeshRoutedTypeRegistry(entries: [entry ?? probeEntry()])
    }

    /// Commits one node's own durable custody of a staged item, the way `finishLocalRungs` would
    /// have on the wire — the state the ack pass needs before "no ack" can mean "no STAGE".
    ///
    /// The re-entry pass does not reach it for us: job 2 recovers only legs whose delivery map
    /// already says `custodied(by: self)`, i.e. item 8's handed-off custody, never a destination's
    /// own first commit.
    static func commitOwnCustody(
        _ rig: MeshRoutedDrainRig, at node: Int, _ key: MeshRoutedItemKey
    ) {
        let outcome = DeviceBindingID.$testOverride.withValue(
            .identifier(MeshP3Acceptance.install)
        ) {
            rig.routedStore(rig.nodes[node]).committingCustody(
                item: key, custodian: rig.nodes[node].fingerprint, now: MeshRoutedDrainRig.now
            )
        }
        guard case .completed(.committed) = outcome else {
            #expect(Bool(false), "custody commit did not stand: \(outcome)")
            return
        }
    }
}

// MARK: - The registry value

/// One value, three rows, seven columns — and the two registerability predicates that make a policy
/// this build does not implement unreachable by construction.
@MainActor
@Suite(.serialized)
struct MeshRoutedTypeRegistryTests {

    @Test func theRegistryHasExactlyThreeEntries() {
        #expect(MeshRoutedTypeRegistry.increment1.tokens.count == 3)
        #expect(MeshRoutedTypeRegistry.increment1.tokens == [
            "fernlet.mesh.routed-type.photo.v1",
            "fernlet.mesh.routed-type.temp-message.v1",
            "fernlet.mesh.routed-type.heart.v1"
        ])
    }

    /// The spellings, pinned as literals rather than through the constants: a rename would otherwise
    /// hold under any spelling, and these travel inside the origin's signature.
    @Test func theRegisteredTokensAreTheFrozenSpellings() {
        let registry = MeshRoutedTypeRegistry.increment1
        #expect(registry.entry(for: "fernlet.mesh.routed-type.photo.v1")?.token
                == MeshRoutedTypeToken.photo)
        #expect(registry.entry(for: "fernlet.mesh.routed-type.temp-message.v1")?.token
                == MeshRoutedTypeToken.tempMessage)
        #expect(registry.entry(for: "fernlet.mesh.routed-type.heart.v1")?.token
                == MeshRoutedTypeToken.heart)
    }

    /// The reserved token stays unregistered: a door with no handler behind it is worse than no door.
    @Test func controlIsNotRegistered() {
        #expect(MeshRoutedTypeRegistry.increment1.entry(for: MeshRoutedTypeToken.control) == nil)
        #expect(MeshRoutedTypeRegistry.increment1.ackStages.stage(for: MeshRoutedTypeToken.control) == nil)
    }

    @Test func anUnknownTokenIsNilNotADefault() {
        #expect(MeshRoutedTypeRegistry.increment1
            .entry(for: "fernlet.mesh.routed-type.nobody-registered.v1") == nil)
        #expect(MeshRoutedTypeRegistry.increment1.entry(for: "") == nil)
    }

    @Test func theRegistryHasNoDuplicateTokens() {
        let first = MeshRoutedTypeRegistryFixtures.probeEntry(finalAck: .durableRecipientStorage)
        let second = MeshRoutedTypeRegistryFixtures.probeEntry(finalAck: .immediate)
        let registry = MeshRoutedTypeRegistry(entries: [first, second])
        #expect(registry.tokens.count == 1)
        #expect(registry.entry(for: MeshRoutedTypeRegistryFixtures.probeToken)?.finalAck
                == .durableRecipientStorage, "the FIRST row wins, as the ack table's builder does")
    }

    /// Every column of every row is the constant or decision already shipped — which is what makes
    /// the registry safe to become the single source without moving any behaviour.
    @Test func everyFieldOfEveryEntryIsSet() throws {
        let registry = MeshRoutedTypeRegistry.increment1
        let stores: [String: MeshRoutedCanonicalStore] = [
            MeshRoutedTypeToken.photo: .friendPhotoWall,
            MeshRoutedTypeToken.tempMessage: .sessionTranscript,
            MeshRoutedTypeToken.heart: .heartLedger
        ]
        let stages: [String: MeshRoutedAckStage] = [
            MeshRoutedTypeToken.photo: .durableRecipientStorage,
            MeshRoutedTypeToken.tempMessage: .durableRecipientStorage,
            MeshRoutedTypeToken.heart: .foregroundDecryptAndLedgerCommit
        ]
        for token in registry.tokens {
            let entry = try #require(registry.entry(for: token), "\(token)")
            #expect(entry.maxItemByteCount == MeshRoutedManifestFormat.maxContentByteCount, "\(token)")
            #expect(entry.destinations == .fullRosterAtCreation, "\(token)")
            #expect(entry.relayRetention == .originRetainsUntilDeparture, "\(token)")
            #expect(entry.expiry == .meshHardDeadlinePlusGrace, "\(token)")
            #expect(entry.canonicalStore == stores[token], "\(token)")
            #expect(entry.finalAck == stages[token], "\(token)")
        }
    }

    /// One policy, not two that can disagree: the foreground requirement is the stage, read again.
    @Test func theForegroundDecryptRequirementIsDerivedFromTheStage() throws {
        let registry = MeshRoutedTypeRegistry.increment1
        let heart = try #require(registry.entry(for: MeshRoutedTypeToken.heart))
        let photo = try #require(registry.entry(for: MeshRoutedTypeToken.photo))
        let text = try #require(registry.entry(for: MeshRoutedTypeToken.tempMessage))
        #expect(heart.requiresForegroundDecryptBeforeFinal)
        #expect(photo.requiresForegroundDecryptBeforeFinal == false)
        #expect(text.requiresForegroundDecryptBeforeFinal == false)
    }

    @Test func theBuildLoopIsBounded() {
        let rows = (0..<20).map {
            MeshRoutedTypeRegistryFixtures.probeEntry(token: "fernlet.mesh.routed-type.bulk-\($0).v1")
        }
        #expect(MeshRoutedTypeRegistry(entries: rows).tokens.count == MeshRoutedTypeRegistry.maxEntries)
    }

    /// D-11.16's tie, asserted from the TEST target: the registry declares its own cap rather than
    /// reading the ack table's, because naming that type in shipping registry source would trip the
    /// one-table wall's member assertion. The number is written twice and pinned equal here.
    @Test func theRegistrysCapEqualsTheAckTablesCap() {
        #expect(MeshRoutedTypeRegistry.maxEntries == MeshRoutedAckStageTable.maxRows)
    }

    /// The projection, against the literal spellings. Asserting `table == registry.ackStages` would
    /// compare a value with its own definition and could not fail.
    @Test func theAckStageTableProjectsTheRegistrysRows() {
        let literals = [
            "fernlet.mesh.routed-type.photo.v1",
            "fernlet.mesh.routed-type.temp-message.v1",
            "fernlet.mesh.routed-type.heart.v1"
        ]
        for literal in literals {
            let projected = MeshRoutedAckStageTable.increment1.stage(for: literal)
            #expect(projected != nil, "\(literal)")
            #expect(projected == MeshRoutedTypeRegistry.increment1.entry(for: literal)?.finalAck,
                    "\(literal)")
        }
        #expect(MeshRoutedTypeRegistry.increment1.tokens == Set(literals))
    }

    /// D-11.7: increment 2's retention is declared and **unregisterable**, so its token answers nil
    /// at every door. Zero hop plumbing behind it.
    @Test func anIncrement2RelayRetentionIsUnregisterable() {
        let row = MeshRoutedTypeEntry(
            token: MeshRoutedTypeRegistryFixtures.probeToken,
            maxItemByteCount: MeshRoutedManifestFormat.maxContentByteCount,
            destinations: .fullRosterAtCreation,
            relayRetention: .relayInFlight,
            finalAck: .durableRecipientStorage,
            expiry: .meshHardDeadlinePlusGrace,
            canonicalStore: .friendPhotoWall
        )
        let registry = MeshRoutedTypeRegistry(entries: [row])
        #expect(registry.tokens.isEmpty)
        #expect(registry.entry(for: MeshRoutedTypeRegistryFixtures.probeToken) == nil)
    }

    /// D-11.17: a cap outside the wire bound is dropped by construction. Above it the mint's global
    /// guard would silently override the row; at zero the row would refuse every item of its type
    /// with no diagnostic.
    @Test func anEntryDeclaringACapOutsideTheWireBoundIsUnregisterable() {
        let tooLarge = MeshRoutedTypeRegistryFixtures.probeEntry(
            maxItemByteCount: MeshRoutedManifestFormat.maxContentByteCount + 1
        )
        let zero = MeshRoutedTypeRegistryFixtures.probeEntry(maxItemByteCount: 0)
        #expect(MeshRoutedTypeRegistry(entries: [tooLarge]).tokens.isEmpty)
        #expect(MeshRoutedTypeRegistry(entries: [zero]).tokens.isEmpty)
    }

    /// The declared slot, pinned. Read by P6's dispatch, by nothing today.
    @Test func theCanonicalStoreSlotNamesTheThreeP6Stores() {
        #expect(MeshRoutedCanonicalStore.allCases.map(\.rawValue)
                == ["friendPhotoWall", "sessionTranscript", "heartLedger"])
    }
}

// MARK: - Each consumer reads the registry

/// The mint, the verifier and the ack door, each driven with an injected registry whose row differs
/// from the shipping one — the only way to show the consumer reads the registry rather than a
/// constant that happens to agree with it.
@MainActor
@Suite(.serialized)
struct MeshRoutedTypeRegistryConsumerTests {

    /// A two-member rig and the mint every cell here drives.
    private func mint(
        _ rig: MeshDeliveryRig,
        typeToken: String,
        size: UInt64,
        types: MeshRoutedTypeRegistry
    ) throws -> MeshRoutedManifest {
        let originFingerprint = rig.fingerprints[0]
        let origin = try #require(rig.identities[originFingerprint])
        let target = MeshDeliveryTarget(
            contentID: UUID(), roster: rig.roster, selfFingerprint: originFingerprint
        )
        return try MeshRoutedManifest.signed(
            meshID: rig.meshID,
            target: target,
            typeToken: typeToken,
            contentHash: MeshRoutedManifestFixtures.contentHash,
            size: size,
            createdAt: MeshRoutedManifestFixtures.base,
            hardDeadline: MeshRoutedManifestFixtures.hardDeadline,
            contentKey: MeshRoutedContentKeyWrapper.makeContentKey(),
            recipientKeys: rig.identities.mapValues(\.localKeyAgreementPublicKey),
            identity: origin,
            types: types
        )
    }

    private func verifier(
        _ rig: MeshDeliveryRig, accepting registry: MeshRoutedTypeRegistry
    ) -> MeshRoutedManifestVerifier {
        MeshRoutedManifestVerifier(
            meshID: rig.meshID, hardDeadline: MeshRoutedManifestFixtures.hardDeadline,
            ledger: rig.ledger, acceptedTypeTokens: registry.tokens
        )
    }

    @Test func theMintRefusesAnItemOverItsTypesDeclaredCap() throws {
        let rig = try MeshDeliveryFixtures.rig(memberCount: 2)
        let narrow = MeshRoutedTypeRegistryFixtures.onlyProbe(
            MeshRoutedTypeRegistryFixtures.probeEntry(maxItemByteCount: 1_024)
        )
        #expect(throws: MeshRoutedManifestMintError.sizeExceedsTypeCap(
            token: MeshRoutedTypeRegistryFixtures.probeToken
        )) {
            _ = try mint(
                rig, typeToken: MeshRoutedTypeRegistryFixtures.probeToken, size: 2_048, types: narrow
            )
        }
    }

    /// D-11.5's asymmetry, asserted rather than assumed: the mint does not enforce acceptance, so the
    /// same item mints cleanly under the shipping registry — which does not register that token —
    /// and is refused at every receiver door instead.
    @Test func theMintAcceptsTheSameItemUnderTheShippingRegistry() throws {
        let rig = try MeshDeliveryFixtures.rig(memberCount: 2)
        let manifest = try mint(
            rig, typeToken: MeshRoutedTypeRegistryFixtures.probeToken, size: 2_048,
            types: MeshRoutedTypeRegistry.increment1
        )
        #expect(manifest.typeToken == MeshRoutedTypeRegistryFixtures.probeToken)
    }

    @Test func theMintRefusesANarrowedDestinationSemantics() throws {
        let rig = try MeshDeliveryFixtures.rig(memberCount: 2)
        let narrow = MeshRoutedTypeRegistryFixtures.onlyProbe(
            MeshRoutedTypeRegistryFixtures.probeEntry(destinations: .singleRecipient)
        )
        #expect(throws: MeshRoutedManifestMintError.unsupportedDestinationSemantics(
            token: MeshRoutedTypeRegistryFixtures.probeToken
        )) {
            _ = try mint(
                rig, typeToken: MeshRoutedTypeRegistryFixtures.probeToken, size: 2_048, types: narrow
            )
        }
    }

    /// D-11.8's derivation, pinned rather than asserted in prose: `destinations` has **no**
    /// receiver-side reader, so a registered `.singleRecipient` row cannot make a receiver fall
    /// through to increment-1 behaviour — there is no receive-side behaviour for it to fall through
    /// to. Same verdict, same admitted destination set.
    @Test func aNarrowedDestinationSemanticsChangesNothingOnReceive() throws {
        let rig = try MeshDeliveryFixtures.rig(memberCount: 3)
        let minted = try mint(
            rig, typeToken: MeshRoutedTypeRegistryFixtures.probeToken, size: 2_048,
            types: MeshRoutedTypeRegistryFixtures.onlyProbe()
        )
        let narrowed = MeshRoutedTypeRegistryFixtures.onlyProbe(
            MeshRoutedTypeRegistryFixtures.probeEntry(destinations: .singleRecipient)
        )
        #expect(verifier(rig, accepting: MeshRoutedTypeRegistryFixtures.onlyProbe()).verify(minted) == nil)
        #expect(verifier(rig, accepting: narrowed).verify(minted) == nil,
                "the destinations column has no receiver-side reader")
        #expect(minted.destinations == Array(rig.fingerprints.dropFirst()))
    }

    /// **D6 preserved, and that is ALL this cell proves.** The minted `expiresAt` is still the one
    /// shared formula the four receiver-side verifiers check for exact floored equality — a real
    /// regression pin, since a per-type grace would be a fleet-wide flag day.
    ///
    /// It does **not** discriminate the registry's `expiry` column, and it is not named as if it
    /// did. `MeshRoutedExpiryRule` has exactly one case, that case delegates to the same
    /// `MeshRoutedManifest.expiry(afterHardDeadline:)` the pre-item-11 mint called directly, and an
    /// unregistered token falls back to it — so this assertion holds byte-identically whether the
    /// mint reads `types.entry(for:)?.expiry` or ignores the registry outright. The column gets a
    /// discriminating cell when P6 adds a second rule to inject; until then the gap is stated here
    /// and carried as a hand-off row rather than papered over by a name.
    @Test func theMintsExpiryIsStillTheOneSharedFormula() throws {
        let rig = try MeshDeliveryFixtures.rig(memberCount: 2)
        let minted = try mint(
            rig, typeToken: MeshRoutedTypeToken.photo, size: 2_048,
            types: MeshRoutedTypeRegistry.increment1
        )
        #expect(minted.expiresAt == MeshRoutedManifest.expiry(
            afterHardDeadline: MeshRoutedManifestFixtures.hardDeadline
        ))
    }

    @Test func theVerifierAcceptsExactlyTheRegistrysTokens() throws {
        let rig = try MeshDeliveryFixtures.rig(memberCount: 2)
        let probe = try mint(
            rig, typeToken: MeshRoutedTypeRegistryFixtures.probeToken, size: 2_048,
            types: MeshRoutedTypeRegistryFixtures.onlyProbe()
        )
        let photo = try mint(
            rig, typeToken: MeshRoutedTypeToken.photo, size: 2_048,
            types: MeshRoutedTypeRegistry.increment1
        )
        let onlyProbe = MeshRoutedTypeRegistryFixtures.onlyProbe()
        #expect(verifier(rig, accepting: onlyProbe).verify(probe) == nil)
        #expect(verifier(rig, accepting: onlyProbe).verify(photo) == .unknownTypeToken)
    }

    /// The ack door resolves its stage through the registry's projection: with the fourth type's row
    /// declaring the heart stage the complete, custodied item stops at `.ledgerJudgementMissing` —
    /// a shortfall only that stage can produce — and the same item is `.refused(.unknownTypeToken)`
    /// the moment its row leaves the registry.
    @Test func theAckDoorResolvesItsStageThroughTheRegistrysProjection() throws {
        let rig = try MeshRoutedCustodyFixtures.rig(
            scope: MeshRoutedStoreFixtures.scope(),
            typeToken: MeshRoutedTypeRegistryFixtures.probeToken
        )
        MeshRoutedCustodyFixtures.stageAll(rig)
        #expect(MeshRoutedCustodyFixtures.witness(MeshRoutedCustodyFixtures.commit(rig)) != nil,
                "the cell needs durable custody before the stage can be the only thing missing")
        let heartShaped = MeshRoutedTypeRegistryFixtures.onlyProbe(
            MeshRoutedTypeRegistryFixtures.probeEntry(finalAck: .foregroundDecryptAndLedgerCommit)
        )
        let registered = MeshRoutedCustodyFixtures.commitDelivery(rig, stages: heartShaped.ackStages)
        let unregistered = MeshRoutedCustodyFixtures.commitDelivery(
            rig, stages: MeshRoutedTypeRegistry.increment1.ackStages
        )
        #expect(registered == .completed(.unsatisfied(.ledgerJudgementMissing)))
        #expect(unregistered == .refused(.unknownTypeToken))
    }

    /// **D-6.9's real invariant.** One seam moves `acceptedTypeTokens` and `ackStages` together: with
    /// the photo row dropped from one node's registry, that node's verifier refuses a photo manifest
    /// AND its re-entry ack pass resolves no stage for a photo it already holds.
    @Test func theManagersTwoReadsComeFromOneRegistry() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "registry-one-seam")
        defer { rig.teardown() }
        // One photo already held and custodied at node 1 — every leg of the ack pass but the STAGE
        // resolution is satisfied — and a second photo, minted at node 0, for the verifier half.
        let held = try MeshRoutedDrainItem.mint(rig, origin: 0, typeToken: MeshRoutedTypeToken.photo)
        let inbound = try MeshRoutedDrainItem.mint(rig, origin: 0, typeToken: MeshRoutedTypeToken.photo)
        held.stage(into: rig, at: 1)
        MeshRoutedTypeRegistryFixtures.commitOwnCustody(rig, at: 1, held.key)
        rig.nodes[1].manager.routedTypeRegistryForTesting =
            MeshRoutedTypeRegistryFixtures.narrowed(dropping: MeshRoutedTypeToken.photo)

        let report = DeviceBindingID.$testOverride.withValue(
            .identifier(MeshP3Acceptance.install)
        ) {
            rig.nodes[1].manager.applyRoutedAccessGate(
                MeshRoutedAccessGate(
                    protectedDataAvailable: true, appIsForeground: true, duressActive: false
                ),
                now: MeshRoutedDrainRig.now
            )
        }
        rig.link(0, 1)
        try await rig.deliver(
            MeshRoutedManifestPayload(manifest: inbound.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 1
        )

        #expect(report?.acksFiled == 0, "the ack pass resolved a stage the registry does not carry")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: held.key)?.recipientReceipts.isEmpty == true,
                "an unregistered type was acknowledged")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: inbound.key) == nil,
                "the verifier admitted a token the SAME registry refuses at the ack pass")
    }
}

// MARK: - Unknown at every door

/// Plan §11's wall on the fake fabric: an item whose type this build does not register is never
/// offered, never pushed at a departure, never receipt-forwarded, never claimed and never
/// acknowledged — and is not dropped either.
@MainActor
@Suite(.serialized)
struct MeshRoutedTypeRegistryDoorTests {

    /// The four routed content payload types — what "forwarded" means on the wire.
    private static let contentFrames: Set<String> = [
        PayloadType.meshRoutedManifest.rawValue, PayloadType.meshRoutedChunk.rawValue,
        PayloadType.meshCustodyReceipt.rawValue, PayloadType.meshRecipientReceipt.rawValue
    ]

    /// An open gate — the only value that runs a foreground re-entry pass.
    private static let openGate = MeshRoutedAccessGate(
        protectedDataAvailable: true, appIsForeground: true, duressActive: false
    )

    /// **D4.** A complete item of an unregistered type is in no offer list, so no manifest and no
    /// chunk for it enters any drain answer.
    @Test func anUnregisteredTypeIsNeverOffered() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "registry-offer")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(
            rig, origin: 0, typeToken: MeshRoutedTypeRegistryFixtures.probeToken
        )
        item.stage(into: rig, at: 0)
        rig.link(0, 1)

        rig.commit(0, 1)
        try await rig.settle()

        let crossed = Set(rig.tokens(at: 1, from: 0)).intersection(Self.contentFrames)
        #expect(crossed.isEmpty, "an unregistered type reached the wire: \(crossed)")
    }

    /// **D4c.** The half the offer gate cannot reach: `receiptsToForward()` takes no entitlement
    /// argument, so an unregistered item's origin-signed receipts would still cross unless the
    /// manager withholds its keys at the plan. Node 0 holds real receipts for a registered item, then
    /// narrows its own registry — and node 2 gets nothing at all.
    @Test func anUnregisteredTypesReceiptsAreNeverForwarded() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "registry-receipts")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0, typeToken: MeshRoutedTypeToken.photo)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle([0, 1], until: {
            rig.routedIndex(rig.nodes[0])?.record(for: item.key)?.recipientReceipts.isEmpty == false
        })
        let held = try #require(rig.routedIndex(rig.nodes[0])?.record(for: item.key))
        #expect(held.receipts.isEmpty == false && held.recipientReceipts.isEmpty == false,
                "the cell needs node 0 to actually hold both receipts")

        rig.nodes[0].manager.routedTypeRegistryForTesting =
            MeshRoutedTypeRegistryFixtures.narrowed(dropping: MeshRoutedTypeToken.photo)
        rig.link(0, 2)
        rig.commit(0, 2)
        try await rig.settle()

        let crossed = Set(rig.tokens(at: 2, from: 0)).intersection(Self.contentFrames)
        #expect(crossed.isEmpty, "an unregistered type's frames reached a third member: \(crossed)")
    }

    /// **D4b.** The departure push does not build its own offer set — it narrows `offerableKeys`
    /// through `intersection(pushable)` — so it inherits the gate rather than needing a second one.
    @Test func anUnregisteredTypeIsNotPushedAtADeparture() async throws {
        // Three members, because a roster of two develops into a TERMINATION, which hands nothing
        // off and would make this cell vacuous.
        let rig = try MeshRoutedDrainRig.build(3, label: "registry-push")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let item = try MeshRoutedDrainItem.mint(
            rig, origin: 0, typeToken: MeshRoutedTypeRegistryFixtures.probeToken
        )
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle()

        let base = MeshRoutedDrainRig.now
        await rig.develop(0, clock: [base, base.addingTimeInterval(2), base.addingTimeInterval(2)])
        try await rig.settle([1])

        // The push RAN with this item in its pushable set — otherwise the assertion below would be
        // a claim about a code path the cell never reached.
        #expect(capture.values(of: "mesh.development.handoffPushed", key: "items").contains("1"),
                "the departure push never offered the item, so this cell proves nothing")
        let crossed = Set(rig.tokens(at: 1, from: 0)).intersection(Self.contentFrames)
        #expect(crossed.isEmpty, "a departure pushed an unregistered type: \(crossed)")
        await rig.quiesce()
    }

    /// **D5.** A leg the leaver's signed record entitles this device to is not claimed when the item's
    /// type left this build's registry — and the refusal is named, never silent.
    @Test func anUnregisteredTypesLegIsNeverClaimedAtADeparture() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "registry-claim")
        defer { scenario.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        let custodian = scenario.rig.nodes[MeshCustodyHandoffScenario.custodian].manager
        custodian.routedTypeRegistryForTesting = MeshRoutedTypeRegistryFixtures.narrowed(
            dropping: MeshRoutedTypeToken.photo
        )
        try await scenario.developInsideTheWindow(at: base)

        #expect(scenario.rig.target(
            MeshCustodyHandoffScenario.custodian, scenario.key
        )?.state(of: scenario.destinationFingerprint) == .pending,
                "a leg of an unregistered type was claimed")
        #expect(capture.count(of: "mesh.development.handoffClaimUnknownType") > 0,
                "the refused claim was not named")
    }

    /// **D3a/D3b.** A destination holding the complete ciphertext of an unregistered type files no
    /// recipient receipt: the ack door resolves no stage, and the re-entry pass skips the item.
    @Test func anUnregisteredTypeIsNeverAcknowledged() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "registry-ack")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(
            rig, origin: 0, typeToken: MeshRoutedTypeRegistryFixtures.probeToken
        )
        item.stage(into: rig, at: 1)
        // Custody committed first, so the ONLY leg of the ack pass left unsatisfied is the stage
        // resolution — otherwise `acksFiled == 0` would hold for a registered type too.
        MeshRoutedTypeRegistryFixtures.commitOwnCustody(rig, at: 1, item.key)
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.custodiedAt != nil,
                "the cell needs durable custody before 'no ack' can mean 'no stage'")

        let report = DeviceBindingID.$testOverride.withValue(
            .identifier(MeshP3Acceptance.install)
        ) {
            rig.nodes[1].manager.applyRoutedAccessGate(Self.openGate, now: MeshRoutedDrainRig.now)
        }
        #expect(report?.acksFiled == 0)
        let record = try #require(rig.routedIndex(rig.nodes[1])?.record(for: item.key))
        #expect(record.recipientReceipts.isEmpty, "an unregistered type was acknowledged")
        #expect(record.deliveredAt == nil)
    }

    /// The positive control for the cell above, and the reason its `acksFiled == 0` means anything:
    /// the identical setup with a REGISTERED type is acknowledged at the same door, in the same pass.
    @Test func aRegisteredTypeIsAcknowledgedAtTheSameDoor() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "registry-ack-control")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0, typeToken: MeshRoutedTypeToken.photo)
        item.stage(into: rig, at: 1)
        MeshRoutedTypeRegistryFixtures.commitOwnCustody(rig, at: 1, item.key)

        let report = DeviceBindingID.$testOverride.withValue(
            .identifier(MeshP3Acceptance.install)
        ) {
            rig.nodes[1].manager.applyRoutedAccessGate(Self.openGate, now: MeshRoutedDrainRig.now)
        }
        #expect(report?.acksFiled == 1)
        let record = try #require(rig.routedIndex(rig.nodes[1])?.record(for: item.key))
        #expect(record.recipientReceipts.contains { $0.recipientFingerprint == rig.nodes[1].fingerprint })
    }

    /// **D-11.21.** The chunk door, at the one place the type is decidable: a chunk carries no token,
    /// but an item whose manifest this device already holds does — so a narrowed build stops GROWING
    /// what it can never acknowledge, offer, forward or claim, instead of filling its caps with it.
    ///
    /// The cell is its own positive control: the SAME chunk is refused while the registry is narrowed
    /// and staged the moment the seam is unset, so the registry is the only thing that moved.
    @Test func anUnregisteredTypesChunkIsRefusedWhenTheManifestIsHeld() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "registry-chunk")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0, typeToken: MeshRoutedTypeToken.photo)
        let chunk = try #require(item.chunks.first)
        rig.link(0, 1)
        try await rig.deliver(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 1
        )
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.manifest != nil,
                "the cell needs the manifest held, or the chunk door has no token to decide on")

        rig.nodes[1].manager.routedTypeRegistryForTesting =
            MeshRoutedTypeRegistryFixtures.narrowed(dropping: MeshRoutedTypeToken.photo)
        try await rig.deliver(
            MeshChunkPayload(chunk: chunk), type: .meshRoutedChunk, sender: 0, receiver: 1
        )
        #expect(rig.heldChunkCount(1, item.key) == 0,
                "a narrowed build kept growing an item it can never acknowledge")
        #expect(capture.values(of: "mesh.routedDrain.rejected", key: "reason")
            .contains("unregisteredTypeChunk"), "the chunk refusal was silent")

        rig.nodes[1].manager.routedTypeRegistryForTesting = nil
        try await rig.deliver(
            MeshChunkPayload(chunk: chunk), type: .meshRoutedChunk, sender: 0, receiver: 1
        )
        #expect(rig.heldChunkCount(1, item.key) == 1,
                "the same chunk is staged once the type is registered again")
    }

    /// **D-11.13.** A build narrowing its own registry is not the origin's refusal, so the held record
    /// and its bytes survive: held, never offered, collected by expiry — never dropped.
    @Test func aHeldRecordOfAnUnregisteredTypeIsNotDropped() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "registry-held")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(
            rig, origin: 0, typeToken: MeshRoutedTypeRegistryFixtures.probeToken
        )
        item.stage(into: rig, at: 0)
        rig.link(0, 1)

        rig.commit(0, 1)
        try await rig.settle()

        let record = try #require(rig.routedIndex(rig.nodes[0])?.record(for: item.key),
                                  "a held record of an unregistered type was dropped")
        #expect(record.chunks.count == item.chunks.count, "its bytes went with it")
    }
}

// MARK: - P6 adds a row, not a branch

/// The forward direction of the same claim: a fourth type registered in an injected registry flows
/// mint → verify → custody → delivery with **no shipping consumer edited**, and is refused end to end
/// the moment the seam is unset.
@MainActor
@Suite(.serialized)
struct MeshRoutedTypeRegistryFourthTypeTests {

    @Test func afourthTypeRegisteredInAnInjectedRegistryFlowsEndToEnd() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "registry-fourth")
        defer { rig.teardown() }
        let widened = MeshRoutedTypeRegistryFixtures.widened(
            with: MeshRoutedTypeRegistryFixtures.probeEntry()
        )
        for node in rig.nodes { node.manager.routedTypeRegistryForTesting = widened }
        let item = try MeshRoutedDrainItem.mint(
            rig, origin: 0, typeToken: MeshRoutedTypeRegistryFixtures.probeToken
        )
        item.stage(into: rig, at: 0)
        rig.link(0, 1)

        rig.commit(0, 1)
        try await rig.settle(until: {
            rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.deliveredAt != nil
        })

        let delivered = try #require(rig.routedIndex(rig.nodes[1])?.record(for: item.key))
        #expect(delivered.manifest != nil, "the destination admitted the fourth type's manifest")
        #expect(delivered.custodiedAt != nil)
        #expect(delivered.deliveredAt != nil)
        #expect(delivered.recipientReceipts.contains { $0.recipientFingerprint == rig.nodes[1].fingerprint })
    }

    @Test func theSameFourthTypeIsRefusedUnderTheShippingRegistry() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "registry-fourth-off")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(
            rig, origin: 0, typeToken: MeshRoutedTypeRegistryFixtures.probeToken
        )
        item.stage(into: rig, at: 0)
        rig.link(0, 1)

        rig.commit(0, 1)
        try await rig.settle()

        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.manifest == nil,
                "the registry, not the plumbing, is what admits a type")
    }
}
