// MeshRoutedPhotoDeliveryTests.swift
// FernletTests
//
// Network migration P5 item 13 (plan §11, §12's photo bullet): the friend-photo wall, end to end,
// on the routed store — and the three `keyEpoch` gates retired with the path that carried it.
//
// Tier 1 only: `FakePeerNetwork` + `FakeMeshTransportSession` + an injected clock, no radio and no
// wall-clock sleeps. The rig is `MeshRoutedDrainRig`, item 6's, extended by one seam — the
// handshake-verified agreement keys a real mint needs, which the drain's own cells never needed
// because `MeshRoutedDrainItem.mint` hands the whole roster's keys over by hand.
//
// Three fixture facts this suite is built on, each of which the drain rig paid for once:
//
// - **One pinned install binding.** `MeshP3Acceptance.install`, around every store-touching call —
//   including `addPhoto`, which now writes the routed store on the SENDER's side.
// - **The gate starts closed.** `MeshNetworkManager.routedAccessGate` is `.closed` until the app
//   pushes it, so a cell that wants plaintext must open it and a cell that wants ciphertext-only
//   custody simply does not.
// - **The rig's nodes are joiner-shaped**, so no node has a `sessionCeiling`; every routed instant
//   derives from `MeshRoutedDrainRig.createdAt` and the manager's own `routedHardDeadline`.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
import PrivateMediaStore
#if canImport(UIKit)
import UIKit
#endif
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshRoutedPhotoFixtures

/// The routed photo item a real sender would mint, built outside the manager so a cell can make
/// eleven of them, or one whose origin never linked to this device.
///
/// It is the same sequence `MeshNetworkManager.originateRoutedItem` runs — frame the body, seal it
/// under a fresh content key, hash the complete blob, sign the manifest, mint the chunks — and it
/// deliberately does NOT reach through a test hook into the manager: a fixture that borrowed the
/// production door could not be used to drive the door's own inputs out of range.
@MainActor
enum MeshRoutedPhotoFixtures {

    /// A real 24×24 JPEG. Real bytes because `addPhoto` decodes and re-encodes through `UIImage`,
    /// and `PrivateMediaStore` validates pixel dimensions on ingestion.
    static func tinyJPEG() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format)
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        return image.jpegData(compressionQuality: 0.6) ?? Data(repeating: 0x2A, count: 512)
    }

    /// The framed plaintext of one routed photo body.
    static func body(itemID: UUID, senderName: String = "Origin") throws -> Data {
        try MeshRoutedPhotoBody(
            header: MeshRoutedPhotoHeader(
                id: itemID,
                addedAt: MeshRoutedDrainRig.createdAt.addingTimeInterval(30),
                senderName: senderName,
                session: nil
            ),
            imageData: tinyJPEG()
        ).encoded()
    }

    /// One sealed, signed routed photo item — the fixture form of the sender door's own sequence.
    ///
    /// - Parameters:
    ///   - meshID: The mesh the manifest belongs to.
    ///   - roster: The derived roster the destination set is taken from.
    ///   - signer: The origin.
    ///   - recipientKeys: Every destination's X25519 key, by fingerprint. A cell driving the
    ///     unwrap out of range passes another identity's key for one destination — the manifest
    ///     verifier checks the wraps' FINGERPRINTS against the destination set and never the keys,
    ///     so such an item is admitted, custodied and complete, and fails only at the unwrap.
    ///   - itemID: The item id, which is also the photo id inside the sealed body.
    ///   - bodyID: The id written into the BODY, defaulting to `itemID`. A cell that means to drive
    ///     the delivery door's identity guard passes a different one.
    ///   - typeToken: The registered routed type. A cell that means to drive a type this build has
    ///     no dispatch arm for passes one of the other two registered tokens.
    ///   - createdAt: The manifest's creation instant.
    ///   - hardDeadline: The session ceiling the expiry derives from.
    /// - Returns: the signed manifest and its chunks.
    static func item(
        meshID: UUID,
        roster: MeshDerivedRoster,
        signer: IdentityService,
        recipientKeys: [String: Data],
        itemID: UUID = UUID(),
        bodyID: UUID? = nil,
        typeToken: String = MeshRoutedTypeToken.photo,
        createdAt: Date,
        hardDeadline: Date
    ) throws -> (manifest: MeshRoutedManifest, chunks: [MeshChunk]) {
        let plaintext = try body(itemID: bodyID ?? itemID)
        let target = MeshDeliveryTarget(
            contentID: itemID, roster: roster, selfFingerprint: signer.localFingerprint
        )
        let contentKey = MeshRoutedContentKeyWrapper.makeContentKey()
        let blob = try MeshRoutedItemSealer.seal(
            plaintext,
            contentKey: contentKey,
            binding: MeshRoutedWrapBinding(
                meshID: meshID, itemID: itemID, originFingerprint: signer.localFingerprint
            ),
            typeToken: typeToken
        )
        let manifest = try MeshRoutedManifest.signed(
            meshID: meshID,
            target: target,
            typeToken: typeToken,
            contentHash: MeshRoutedContentDigest.contentHash(of: blob),
            size: UInt64(blob.count),
            createdAt: createdAt,
            hardDeadline: hardDeadline,
            contentKey: contentKey,
            recipientKeys: recipientKeys,
            identity: signer
        )
        return (manifest, try MeshChunker.chunks(of: blob, for: manifest, identity: signer))
    }

    /// The drain rig's convenience form of
    /// ``item(meshID:roster:signer:recipientKeys:itemID:bodyID:typeToken:createdAt:hardDeadline:)``.
    ///
    /// - Parameter recipientKeyOverrides: Replaces one destination's wrap key by fingerprint, so a
    ///   cell can mint an item that peer cannot open.
    static func item(
        _ rig: MeshRoutedDrainRig,
        origin: Int,
        itemID: UUID = UUID(),
        bodyID: UUID? = nil,
        typeToken: String = MeshRoutedTypeToken.photo,
        recipientKeyOverrides: [String: Data] = [:]
    ) throws -> (manifest: MeshRoutedManifest, chunks: [MeshChunk]) {
        var recipientKeys = Dictionary(uniqueKeysWithValues:
            rig.identities.map { ($0.localFingerprint, $0.localKeyAgreementPublicKey) })
        // R2: bounded by the roster, itself bounded by the rig's node count.
        for (fingerprint, key) in recipientKeyOverrides { recipientKeys[fingerprint] = key }
        return try item(
            meshID: rig.meshID,
            roster: rig.roster,
            signer: rig.identities[origin],
            recipientKeys: recipientKeys,
            itemID: itemID,
            bodyID: bodyID,
            typeToken: typeToken,
            createdAt: MeshRoutedDrainRig.createdAt.addingTimeInterval(60),
            hardDeadline: MeshRoutedDrainRig.hardDeadline
        )
    }
}

// MARK: - The rig seam

@MainActor
extension MeshRoutedDrainRig {

    /// The gate a cell pushes when it wants plaintext.
    static var openGate: MeshRoutedAccessGate {
        MeshRoutedAccessGate(protectedDataAvailable: true, appIsForeground: true, duressActive: false)
    }

    /// Records every other member as a committed session participant on every node.
    ///
    /// This is the ONE thing a real mint needs that the drain's own cells never did: P5 item 13's
    /// wrap-key lookup takes handshake-verified keys only (a live slot's
    /// `verifiedKeyAgreementPublicKey`, or the session-roster entry `recordSessionParticipant` wrote
    /// from that same verified value), and refuses the whole mint when a destination has neither.
    /// `MeshRoutedDrainItem.mint` hands the whole roster's keys over as a parameter, so it never
    /// exercised the lookup at all.
    func seedAgreementKeys() {
        // R2: bounded by the rig's own node count, squared.
        for (position, node) in nodes.enumerated() {
            for (other, identity) in identities.enumerated() where other != position {
                node.manager.recordSessionParticipant(
                    displayName: "peer-\(other)",
                    fingerprint: identity.localFingerprint,
                    signingPublicKey: identity.localSigningPublicKey,
                    keyAgreementPublicKey: identity.localKeyAgreementPublicKey
                )
            }
        }
    }

    /// Mints every node's OWN key advertisement through the production door (P6 item 1).
    ///
    /// The production door, not a seeded set: `armOwnKeyAdvertisementForTesting(now:)` signs a real
    /// advertisement, folds it through the real verifier and seals the real session context. The
    /// rigs need the seam only because they arm their ledgers through
    /// `seedMembershipLedgerForTesting`, which bypasses the founder and joiner doors the shipping
    /// mint hangs off and therefore mints nothing.
    func armKeyAdvertisements() {
        // R2: bounded by the rig's own node count.
        for node in nodes {
            armKeyAdvertisement(at: node)
        }
    }

    /// Mints ONE node's own key advertisement, for the cells whose claim is about a node that has
    /// a row while another does not.
    func armKeyAdvertisement(at position: Int) { armKeyAdvertisement(at: nodes[position]) }

    private func armKeyAdvertisement(at node: MeshDepartureNode) {
        let armed = DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            node.manager.armOwnKeyAdvertisementForTesting(now: MeshRoutedDrainRig.now)
        }
        #expect(armed, "this node's own advertisement is the cell's precondition")
    }

    /// Links a pair, commits both ends and settles — the real link-open exchange, which is what
    /// carries the advertisement frames.
    func heal(_ near: Int, _ far: Int) async throws {
        link(near, far)
        commit(near, far)
        try await settle()
    }

    /// Seats a handshake-verified key-agreement key on every slot one node holds toward another.
    ///
    /// The rig's links seat committed slots with `verifiedKeyAgreementPublicKey` nil — a fresh
    /// handshake is the only thing that fills it in shipping code — so a cell that means to drive
    /// tier A's own precedence, or a tier-A-against-tier-B disagreement, has to say so.
    func seedSlotKey(at node: Int, toward peer: Int, key: Data) {
        let fingerprint = nodes[peer].fingerprint
        // R2: bounded by the slot cap.
        for index in nodes[node].manager.slots.indices
        where nodes[node].manager.slots[index].fingerprint == fingerprint {
            nodes[node].manager.slots[index].verifiedKeyAgreementPublicKey = key
        }
    }

    /// How many advertisement rows one node holds.
    func advertisementCount(at node: Int) -> Int { nodes[node].manager.keyAdvertisements.count }

    /// How many rows one node has PARKED, across every sender's share.
    func parkedCount(at node: Int) -> Int {
        nodes[node].manager.parkedKeyAdvertisementCountForTesting
    }

    /// Re-seats ONE node's verifier on a ledger that admits only `members`.
    ///
    /// The same seam every rig starts from (`seedMembershipLedgerForTesting`), used a second time.
    /// A cell about the park needs a device whose admission set is NARROWER than the mesh's: that
    /// is the only state in which a genuinely signed row is refused `signerNotAdmitted` rather than
    /// `signatureInvalid`, and it is the state the grant door actually produces — a joiner on the
    /// bootstrap ledger its admitter rooted. Calling it a second time with a wider list is the
    /// widening.
    ///
    /// - Parameters:
    ///   - node: Which node's verifier to re-seat.
    ///   - members: The rig positions the new ledger admits; position 0 is always the founder.
    func reseedLedger(at node: Int, admitting members: [Int]) throws {
        let others = members.filter { $0 != 0 }.map { identities[$0] }
        let ledger = try MeshPartitionFixtures.ledger(
            founder: identities[0], others: others, meshID: meshID
        )
        nodes[node].manager.seedMembershipLedgerForTesting(
            meshID: meshID,
            founderSigningPublicKey: identities[0].localSigningPublicKey,
            ledger: ledger
        )
    }

    /// Drives one node's production re-offer of its parked rows under a pinned binding.
    ///
    /// - Parameters:
    ///   - node: Which node re-offers.
    ///   - binding: The device binding the re-offer's sealed write runs under; `.unavailable` is
    ///     how a cell drives the durable-before-it-counts rollback.
    func reofferParked(at node: Int, binding: DeviceBindingID.TestOverride? = nil) {
        DeviceBindingID.$testOverride.withValue(binding ?? .identifier(MeshP3Acceptance.install)) {
            nodes[node].manager.foldParkedKeyAdvertisementsForTesting()
        }
    }

    /// One advertisement frame, addressed from one rig node.
    ///
    /// - Parameters:
    ///   - rows: The rows the frame carries.
    ///   - sender: The rig position the frame is attributed to.
    /// - Returns: The payload.
    func advertisementFrame(
        _ rows: [SignedKeyAgreementAdvertisement], from sender: Int
    ) -> MeshKeyAgreementPayload {
        MeshKeyAgreementPayload(
            meshID: meshID, advertisements: rows, senderFingerprint: nodes[sender].fingerprint
        )
    }

    /// Delivers one frame through the **membership** dispatch family, on the real receive entry
    /// point and after the real envelope verification.
    ///
    /// The rig's own `dispatch(_:type:sender:receiver:…)` reaches `dispatchRoutedPayload` and is
    /// therefore routed-only; an advertisement rides the membership family, whose door applies the
    /// committed-slot and verifier-present gates this has to go through.
    /// - Parameter binding: The device binding the receive runs under. `.unavailable` makes every
    ///   sealed write fail, which is how a cell drives the durable-before-it-counts rollback.
    func deliverMembershipFrame(
        _ payload: some Encodable, type: PayloadType, sender: Int, receiver: Int,
        binding: DeviceBindingID.TestOverride? = nil
    ) throws {
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: identities[sender], senderDisplayName: "advert",
            recipientFingerprint: nodes[receiver].fingerprint,
            payloadType: type, payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "membership"),
            payload: try JSONEncoder().encode(payload),
            createdAt: MeshRoutedDrainRig.now
        )
        let node = nodes[receiver]
        let coordinator = try #require(node.coordinators[nodes[sender].handle.endpoint],
                                       "the pair must be linked before a frame can be attributed")
        let plaintext = try envelope.verify(
            identityService: node.manager.identityForTesting, replayCache: node.replayCache
        )
        // Resolved in the body, not as a default argument: `MeshP3Acceptance.install` is
        // `@MainActor`, and a `@MainActor` value cannot be a default-argument expression.
        DeviceBindingID.$testOverride.withValue(binding ?? .identifier(MeshP3Acceptance.install)) {
            node.manager.proximityCoordinator(
                coordinator, didReceive: envelope, plaintext: plaintext, from: nil
            )
        }
    }

    /// Files one member's OWN signed departure at another node, through the real membership door.
    ///
    /// A real record, relayed by a linked peer: membership records are signed gossip, so the
    /// verifier checks the record's own signature rather than who carried it. That is what lets a
    /// cell narrow a roster for a member it was never linked to.
    func fileDeparture(of leaver: Int, into receiver: Int, relayedBy relay: Int = 1) throws {
        let record = try SignedDepartureRecord.signed(
            meshID: meshID, identity: identities[leaver],
            occurredAt: MeshRoutedDrainRig.now.addingTimeInterval(120)
        )
        try deliverMembershipFrame(
            MeshMemberDeparturePayload(record: record),
            type: .meshMemberDeparture, sender: relay, receiver: receiver
        )
    }

    /// Pushes one node's access gate under the pinned install binding, which is the re-entry's edge.
    ///
    /// - Parameter now: The pass's instant. Nil takes the rig's own `now`, which is an INTEGRAL
    ///   second — the only reason the carried-over cut's two clocks agreed before item 5's review
    ///   floored the cut (P1-1), so the cell that proves the flooring passes a fractional instant
    ///   explicitly. `Date?` rather than a default expression because the anchor is `@MainActor`.
    @discardableResult
    func pushGate(
        _ gate: MeshRoutedAccessGate, at node: Int, now: Date? = nil
    ) -> MeshRoutedReentryReport? {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            nodes[node].manager.applyRoutedAccessGate(gate, now: now ?? MeshRoutedDrainRig.now)
        }
    }

    /// Captures one photo at `node`, through the real public API and the pinned binding.
    func capturePhoto(at node: Int) {
        let jpeg = MeshRoutedPhotoFixtures.tinyJPEG()
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            nodes[node].manager.addPhoto(jpeg)
        }
    }

    /// Hands one already-minted item to `receiver` as `sender` would: manifest, then every chunk.
    func handOver(
        _ item: (manifest: MeshRoutedManifest, chunks: [MeshChunk]),
        sender: Int,
        receiver: Int
    ) throws {
        try dispatch(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: sender, receiver: receiver
        )
        // R2: bounded by the item's own chunk count.
        for chunk in item.chunks {
            try dispatch(
                MeshChunkPayload(chunk: chunk), type: .meshRoutedChunk, sender: sender, receiver: receiver
            )
        }
    }

    /// How many wall entries `node` holds for one item id.
    func wallEntries(at node: Int, itemID: UUID) -> [FriendPhotoPayload] {
        nodes[node].manager.meshPhotos.filter { $0.id == itemID }
    }
}

// MARK: - The sender door

/// What `addPhoto` does now: cache locally always, mint a routed item when there is somewhere to
/// send it, and say so out loud only when a mint was attempted and failed.
@MainActor
@Suite(.serialized)
struct MeshRoutedPhotoSenderTests {

    /// **R-1.** A capture on a mesh with an addressable roster stages one complete own item.
    @Test func sharingAPhotoStagesAnOwnRoutedItem() throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-stage")
        defer { rig.teardown() }
        rig.seedAgreementKeys()

        rig.capturePhoto(at: 0)

        let index = try #require(rig.routedIndex(rig.nodes[0]), "the origin's store must be loaded")
        #expect(index.items.count == 1, "one capture is one routed item")
        let record = try #require(index.items.first)
        #expect(record.isComplete, "the origin stages every chunk of its own item")
        #expect(record.chunkCount >= 1 && record.chunkCount <= 2, "a resized photo is one or two chunks")
        #expect(record.key.originFingerprint == rig.nodes[0].fingerprint)
        #expect(rig.nodes[0].manager.meshError == nil, "a staged item is silent")
        #expect(rig.nodes[0].manager.routedShareRefusal == nil, "and publishes no refusal")
        #expect(rig.nodes[0].manager.meshPhotos.count == 1, "and the echo is on the sender's own wall")
    }

    /// **R-17.** A capture with no destinations at all reaches the sender's own wall, silently.
    ///
    /// **Untouched by items 1 and 2, and re-documented rather than flipped — twice.** The launcher
    /// asked item 1 for a flip that would have been wrong, and named item 2 as the item that would
    /// flip it. Neither is right, and the reason is that this cell exercises the **LEDGERLESS** leg:
    /// a mesh with no membership verifier at all, which exits `originateRoutedItem` on its FIRST
    /// guard (`membershipVerifier?.roster`) and never reaches the destination count. No key
    /// advertisement can change that, and item 2 did not either — what item 2 changed is
    /// *reachability*: before it, every proximity-join session was in this shape (`promoteToMesh`
    /// minted a descriptor and armed no ledger, and `startNewMesh` had no caller), and afterwards
    /// this shape is reachable only as a **hand-built manager** like the one below. It is therefore
    /// kept as the ledgerless control, beside
    /// ``aSoloMemberWithAnArmedLedgerStillReachesOnlyItsOwnWallSilently()``, which is the same
    /// silence reached through the OTHER leg (`destinationCount == 0`, a genuine roster of one).
    /// The two together are what stop either from being green for the wrong reason — the skip has
    /// two legs and this cell cannot tell them apart, so it says which one it drives.
    ///
    /// This is the premise the ten legacy send-side cells rest on: both retired arms of `addPhoto`
    /// cached before any send and incremented the session counter whichever way the send went, so a
    /// solo member has always had a wall entry and no error. Conditioning the echo on a successful
    /// mint would break every session whose derived roster is one — a solo host, and the founder's
    /// window between the founding and its first admission grant.
    @Test func aCaptureWithNoDestinationsStillReachesTheOwnWallSilently() throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let store = makeTestStore()
        defer { withExtendedLifetime(store) {} }
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = MeshP3Acceptance.mesh(
            for: manager, meshID: UUID(), createdAt: MeshP3Acceptance.base
        )

        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.addPhoto(MeshRoutedPhotoFixtures.tinyJPEG())
        }

        #expect(manager.meshPhotos.count == 1, "the echo is unconditional")
        #expect(manager.photosAddedThisSession == 1, "and so is the session counter")
        #expect(manager.meshError == nil, "sending to nobody is not an error")
        #expect(manager.routedShareRefusal == nil, "and publishes no refusal")
        #expect(manager.photosKeptOnThisPhone == 1,
                "but it is COUNTED: the photo is on this wall and no other, and never will be (P8 item 0 (c))")
        #expect(capture.count(of: "mesh.routedShare.skipped") == 1, "and the skip is audited, once")
        #expect(manager.membershipVerifier == nil,
                "and the leg under test is the LEDGERLESS one, not a roster of one")
        var absent = false
        if case .absent = MeshRoutedStore(scope: store.meshRoutedStorage).load() { absent = true }
        #expect(absent, "nothing was staged, because there was nothing to stage for")
    }

    /// **The solo control R-17 could not be** (P6 item 2): a member with a real mesh and a real
    /// one-member ledger still reaches only its own wall, and still says nothing.
    ///
    /// This is the `destinationCount == 0` leg — the second of the two legs that answer
    /// `.skipped(.noDestinations)` — and after item 2 it is the *only* shipping shape that reaches
    /// the skip at all: a solo host, and the founder's window between the founding and the first
    /// admission grant. The ledger is armed through the real founder door (`startNewMesh(name:)` →
    /// `foundMesh(_:now:)` → `prepareMembershipLedger` + `seedFounderAdmission`), so the first guard
    /// is genuinely passed and the assertion below names which one refused.
    ///
    /// Why it has to exist beside R-17: the two legs are one `.skipped(.noDestinations)` case, and a
    /// cell that asserts only "nothing staged, no refusal" passes identically for "no ledger", "no
    /// mesh", "no hard deadline" and "a roster of one". Item 2's delivery cells assert the opposite
    /// of this on the same door, so if the skip moved legs both could be green while the mechanism
    /// was wrong.
    @Test func aSoloMemberWithAnArmedLedgerStillReachesOnlyItsOwnWallSilently() throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let store = makeTestStore()
        defer { withExtendedLifetime(store) {} }
        let identity = try MeshPartitionFixtures.identity("solo-armed")
        let manager = MeshNetworkManager(
            store: store, transport: FakeMeshTransportSession(), identity: identity
        )
        defer { manager.leaveMesh() }
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.startNewMesh(name: "Solo Meadow")
        }
        #expect(manager.currentMesh != nil, "a real founded mesh")
        #expect(manager.membershipVerifier?.roster.memberCount == 1, """
            with a real ledger holding exactly this device's own admission — which is what makes \
            `destinationCount == 0` the leg under test rather than the missing verifier
            """)

        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.addPhoto(MeshRoutedPhotoFixtures.tinyJPEG())
        }

        #expect(manager.meshPhotos.count == 1, "the echo is unconditional here too")
        #expect(manager.photosAddedThisSession == 1, "and so is the session counter")
        #expect(manager.meshError == nil, "a roster of one is not an error")
        #expect(manager.routedShareRefusal == nil, "and publishes no refusal")
        #expect(manager.photosKeptOnThisPhone == 1, "but the capture that reached nobody is counted")
        #expect(capture.count(of: "mesh.routedShare.skipped") == 1, "and audited, once")
        var absent = false
        if case .absent = MeshRoutedStore(scope: store.meshRoutedStorage).load() { absent = true }
        #expect(absent, "nothing is staged for a destination set of zero")
        manager.leaveMesh()
        #expect(manager.photosKeptOnThisPhone == 0, "the count is the session's, and leaves with it")
    }

    /// **R-12a, the negative control.** A destination NO source has stated a key for — no
    /// handshake this session, and no verified advertisement either — still refuses the whole mint,
    /// visibly.
    ///
    /// Re-documented by P6 item 1 rather than flipped: it is what keeps the `notAddressable` arm of
    /// the resolver honest now that a second source exists. No `seedAgreementKeys()`, no
    /// `armKeyAdvertisements()`, no link — so both tiers are genuinely empty. The cases that DID
    /// flip are `R-12` (the star) and `R-16` (the resumption), below.
    @Test func aMintWithAnUnverifiedDestinationRefusesVisibly() throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-unverified")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        rig.capturePhoto(at: 0)

        #expect(rig.nodes[0].manager.routedShareRefusal == .destinationNotAddressable,
                "a mint that failed must reach the user, as its frozen cause")
        #expect(rig.nodes[0].manager.meshError == nil,
                "and no English sentence is composed in the package (P5 review finding 5)")
        #expect(rig.routedIndex(rig.nodes[0]) == nil, "nothing was staged")
        #expect(capture.values(of: "mesh.routedShare.refused", key: "reason")
                == ["destinationNotAddressable"],
                "the refusal is named once, by its frozen token")
        #expect(rig.nodes[0].manager.meshPhotos.count == 1,
                "the echo still runs: only the transport is conditional")
        rig.nodes[0].manager.leaveMesh()
        #expect(rig.nodes[0].manager.routedShareRefusal == nil,
                "a refusal about a session that ended has no reader")
    }

    /// **R-16, FLIPPED by P6 item 1: the resumption is a DELIVERY.**
    ///
    /// This is the one of D-13.22's three refusals that becomes an end-to-end delivery, and the
    /// cell is deliberately driven that way rather than seeded: node 1's advertisement reaches
    /// node 0 as a **real frame** through the real link-open exchange and the real membership
    /// dispatch; node 0's process then dies and a new manager comes up over the same store and
    /// **reloads the context from disk**; the link re-forms with slots that carry no
    /// handshake-verified key and a session roster that is empty, so the restored advertisement is
    /// the ONLY source the mint can resolve node 1 from; and the item is then really delivered.
    ///
    /// A seeded-set version of this cell would pass with the send door, the receive door, the
    /// verifier, the frame and the schema all deleted — it would prove only that the resolver reads
    /// a dictionary.
    ///
    /// **One seam IS set by hand, and the name says so** (P6 item 7 fix review, P3-2): `currentMesh`.
    /// The restore deliberately leaves it nil — restoring is not reconnecting — and the only
    /// shipping writer from nil on a re-link is the descriptor-adoption arm of
    /// `receiveMeshDescriptor(_:from:)` (the `currentMesh == nil` branch, which
    /// `prepareMembershipLedger`'s same-meshID early return then leaves the restored ledger alone
    /// for). No cell in the tree drives that frame today, so the assignment below stands in for it:
    /// what this cell proves is that the restored ADDRESSING survives a restart and really carries a
    /// delivery, not that the shipping resume path reaches it. P7's resume wiring owns that half.
    @Test func aMintAfterARestartDeliversFromTheRestoredAdvertisementsOnceReAdopted() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-resumed")
        defer { rig.teardown() }
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        #expect(rig.advertisementCount(at: 0) == 2,
                "the real frame crossed: node 0 folded node 1's own signed row")

        // The process dies and comes back over the same sealed bytes, with the same identity.
        let reborn = MeshNetworkManager(
            store: rig.nodes[0].store, transport: FakeMeshTransportSession(),
            identity: rig.identities[0]
        )
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            reborn.restoreSessionContextAtLaunch(now: MeshRoutedDrainRig.now)
        }
        #expect(outcome.context?.meshID == rig.meshID, "the restore read the sealed context")
        #expect(reborn.membershipVerifier?.roster.memberCount == 2,
                "the precondition: the LEDGER survived the restart")
        #expect(reborn.sessionRoster.isEmpty, "and the memory-only session roster did NOT")
        #expect(reborn.keyAdvertisements.count == 2,
                "the addressing came back with the ledger, re-proved against it")
        // Hand-set, standing in for `receiveMeshDescriptor`'s adoption arm — see the doc above.
        reborn.currentMesh = MeshP3Acceptance.mesh(
            for: reborn, meshID: rig.meshID, createdAt: MeshRoutedDrainRig.createdAt
        )
        let rebornNode = MeshDepartureRig.node(
            "photo-resumed-reborn", identity: rig.identities[0], on: rig.fabric,
            manager: reborn, store: rig.nodes[0].store
        )
        MeshDepartureRig.link(rebornNode, rig.nodes[1], on: rig.fabric)
        let slotKeys = reborn.slots.compactMap(\.verifiedKeyAgreementPublicKey)
        #expect(slotKeys.isEmpty, "the re-formed slot carries no handshake key, or tier B is bypassed")
        #expect(reborn.membershipVerifier?.roster.memberCount == 2, "the mint needs the roster")
        #expect(reborn.currentMesh?.meshID == rig.meshID, "and the mesh it is scoped to")
        #expect(reborn.slots.count == 1, "and a committed slot to push over")

        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            reborn.addPhoto(MeshRoutedPhotoFixtures.tinyJPEG())
        }

        #expect(reborn.routedShareRefusal == nil, "the mint must not refuse: the key was restored")
        let staged = try #require(rig.routedIndex(rig.nodes[0]), "the origin must hold its own item")
        #expect(staged.items.count == 1, "the mint staged, sampled before the settle can drain it")
        #expect(staged.items.first?.deliveryTarget?.destinationCount == 1,
                "wrapped for the one member it could only address from the restored advertisement")

        try await MeshDepartureRig.settle([rebornNode, rig.nodes[1]], on: rig.fabric)

        let delivered = try #require(rig.routedIndex(rig.nodes[1]), "the destination must hold it")
        #expect(delivered.items.count == 1, "a restored advertisement carried a real delivery")
        #expect(delivered.items.first?.isComplete == true, "and every chunk of it")
        reborn.leaveMesh()
    }

    /// **R-13.** An own item the capacity caps refuse raises item 9's existing `.storeFull` hold.
    @Test func anOwnItemRefusedByCapacityRaisesTheExistingHold() throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-capacity")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        let hog = MeshRoutedStoreFixtures.record(
            chunks: [MeshRoutedStoreFixtures.descriptor(
                index: 0, count: 1, bytes: Int(MeshRoutedStoreFormat.maxContentBytes)
            )],
            expiresAt: MeshRoutedManifest.expiry(afterHardDeadline: MeshRoutedDrainRig.hardDeadline)
        )
        try MeshRoutedStoreFixtures.plant(
            MeshRoutedIndex(items: [hog]),
            into: rig.routedStore(rig.nodes[0]),
            install: MeshP3Acceptance.install
        )

        rig.capturePhoto(at: 0)

        #expect(rig.nodes[0].manager.routedDeliveryHold?.cause == .storeFull,
                "an origin's own refusal rides the surface item 9 already built")
        #expect(rig.nodes[0].manager.routedShareRefusal == .storeRefused, "and it is visible, never silent")
        #expect(rig.routedIndex(rig.nodes[0])?.items.count == 1, "only the hog is held")
        #expect(rig.nodes[0].manager.meshPhotos.count == 1, "the echo is still on the sender's wall")
    }

    /// **R-14.** An origination pushes once to the committed slots and opens no exchange.
    ///
    /// The counts are read before and after the capture, so the initial commit's own exchange cannot
    /// make this pass: what the origination adds is content frames, and what it must NOT add is a
    /// routed inventory digest — an advertisement asks the PEER to push to this device, which is the
    /// opposite of what a fresh item needs.
    @Test func sharingAPhotoPushesOnceToTheCommittedSlots() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-push")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle()
        let digestsBefore = rig.tokens(at: 1, from: 0)
            .filter { $0 == PayloadType.meshRoutedInventoryDigest.rawValue }.count
        let manifestsBefore = rig.tokens(at: 1, from: 0)
            .filter { $0 == PayloadType.meshRoutedManifest.rawValue }.count

        rig.capturePhoto(at: 0)
        try await rig.settle()

        let after = rig.tokens(at: 1, from: 0)
        #expect(after.filter { $0 == PayloadType.meshRoutedManifest.rawValue }.count
                == manifestsBefore + 1,
                "the origination pushed exactly one manifest to the committed slot")
        #expect(after.contains(PayloadType.meshRoutedChunk.rawValue), "with its bytes")
        #expect(after.filter { $0 == PayloadType.meshRoutedInventoryDigest.rawValue }.count
                == digestsBefore,
                "an origination TELLS: it opens no exchange and advertises nothing")
    }

    /// **R-14b.** An origination cannot unbind an open merge exchange's quiescence answer.
    ///
    /// The ask door records the advertisement instant an inbound answer must quote. A fourth
    /// `sendRoutedInventory` site here would overwrite it, and the peer's answer to the ASK would
    /// then be dropped as unbound — feeding item 7's merge window a bit that never arrives. The
    /// origination door sends no digest at all, so the binding stands.
    @Test func anOriginationDoesNotUnbindAnOpenMergeExchange() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-binding")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.link(0, 1)
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await rig.nodes[0].manager.sendRoutedInventory(
                to: [rig.nodes[1].fingerprint], now: MeshRoutedDrainRig.now
            )
        }
        rig.capturePhoto(at: 0)
        try await rig.settle()

        #expect(capture.count(of: "mesh.merge.routedQuiescent") >= 1,
                "the ask door's own answer must still bind after an origination")
        // Witnessed on THIS rig's own state, not on the process-global audit count (D-6a.10, and a
        // 2026-09-11 sighting: `mesh.merge.routedQuiescentUnbound` is emitted by every other drain
        // suite's rigs in the same process, so an `== 0` over the capture is a per-cell claim
        // witnessed by a process-wide signal, and any change of interleaving turns it red).
        let bound = try #require(
            rig.nodes[0].manager.peerRoutedInventories[rig.nodes[1].fingerprint],
            "the peer's answer must have bound to the advertisement the ask recorded"
        )
        #expect(bound.reportsQuiescent,
                "nothing overwrote the advertisement the answer quotes: the bit landed")
        #expect(bound.advertisedAt != nil, "and the binding instant is still the ask door's")
    }
}

// MARK: - The receiver

/// What the destination does with a routed photo: custody first, plaintext only behind the gate, and
/// the same wall the legacy handler fed.
@MainActor
@Suite(.serialized)
struct MeshRoutedPhotoDeliveryTests {

    /// **R-2.** The whole path: sender API → frames → delivery → access gate → the wall.
    @Test func aSharedPhotoReachesTheDestinationsWall() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-wall")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)

        rig.capturePhoto(at: 0)
        let itemID = try #require(rig.routedIndex(rig.nodes[0])?.items.first?.key.itemID)
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle(until: { rig.nodes[1].manager.meshPhotos.isEmpty == false })

        #expect(rig.wallEntries(at: 1, itemID: itemID).count == 1,
                "the destination's wall holds the photo the origin shared")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: MeshRoutedItemKey(
            originFingerprint: rig.nodes[0].fingerprint, itemID: itemID
        ))?.isComplete == true, "and the ciphertext it was opened from")
    }

    /// **R-3.** The origin learns it landed: its delivery map reads `delivered` for that destination.
    ///
    /// Three nodes with one link, so the item is still owed to the third and the origin's own record
    /// cannot be reclaimed out from under the assertion.
    @Test func aRecipientReceiptComesBackForASharedPhoto() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "photo-receipt")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)

        rig.capturePhoto(at: 0)
        let key = try #require(rig.routedIndex(rig.nodes[0])?.items.first?.key)
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle(until: {
            rig.routedIndex(rig.nodes[0])?.record(for: key)?.recipientReceipts.isEmpty == false
        })

        let target = try #require(rig.routedIndex(rig.nodes[0])?.record(for: key)?.deliveryTarget)
        #expect(target.state(of: rig.nodes[1].fingerprint) == .delivered,
                "the destination that opened it reads delivered at the origin")
        #expect(target.state(of: rig.nodes[2].fingerprint) == .pending,
                "and the one that was never linked is still pending, never dropped")
    }

    /// **R-4.** Nothing decrypts while the gate is closed — and nothing is lost either.
    @Test func nothingDecryptsWhileTheGateIsClosed() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-locked")
        defer { rig.teardown() }
        rig.seedAgreementKeys()

        rig.capturePhoto(at: 0)
        let key = try #require(rig.routedIndex(rig.nodes[0])?.items.first?.key)
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle(until: {
            rig.routedIndex(rig.nodes[1])?.record(for: key)?.isComplete == true
        })

        #expect(rig.routedIndex(rig.nodes[1])?.record(for: key)?.isComplete == true,
                "the ciphertext is durably held")
        #expect(rig.nodes[1].manager.meshPhotos.isEmpty,
                "and no plaintext exists behind a closed gate")
    }

    /// **R-5.** The rising edge fills the wall — R-4 and R-5 are the pair that proves the gate is the
    /// enforcement, not the plumbing.
    @Test func theReentryPassFillsTheWallWhenTheGateOpens() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-unlock")
        defer { rig.teardown() }
        rig.seedAgreementKeys()

        rig.capturePhoto(at: 0)
        let key = try #require(rig.routedIndex(rig.nodes[0])?.items.first?.key)
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle(until: {
            rig.routedIndex(rig.nodes[1])?.record(for: key)?.isComplete == true
        })
        #expect(rig.nodes[1].manager.meshPhotos.isEmpty, "the precondition: still sealed")

        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)

        #expect(rig.wallEntries(at: 1, itemID: key.itemID).count == 1,
                "the re-entry pass hands the deferred plaintext to the wall")
    }

    /// **R-6 — the regression the whole item exists for.** Content minted while a member was away is
    /// delivered to it after the heal.
    ///
    /// Under the retired path this could not happen twice over: `handlePhotoManifest`'s
    /// `keyEpoch >= localJoinedEpoch` filter suppressed the ASK, and `handleFriendPhotoEnvelope`'s
    /// `key.epoch == photo.keyEpoch` would have dropped the answer — and the two branches of a split
    /// rotate their own epochs, so the counters need not even differ for the compare to fail. The
    /// routed path names no epoch anywhere, which is what lets both gates be deleted rather than
    /// loosened.
    @Test func otherBranchContentIsDeliveredAfterAHeal() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "photo-heal")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 2)
        // Two branches on their own epochs — SAME counter, different mints, which is exactly the
        // divergent-branch state `key.epoch == photo.keyEpoch` could not tell from a match and
        // `keyEpoch >= localJoinedEpoch` suppressed the ask for.
        MeshDepartureRig.seedEpoch(rig.nodes[0], head: MeshEpochRef(
            counter: 4, epochID: UUID(), coordinatorFingerprint: rig.nodes[0].fingerprint
        ))
        MeshDepartureRig.seedEpoch(rig.nodes[2], head: MeshEpochRef(
            counter: 4, epochID: UUID(), coordinatorFingerprint: rig.nodes[2].fingerprint
        ))

        rig.link(0, 1)
        rig.commit(0, 1)
        rig.capturePhoto(at: 0)
        let key = try #require(rig.routedIndex(rig.nodes[0])?.items.first?.key)
        try await rig.settle()
        #expect(rig.nodes[2].manager.meshPhotos.isEmpty, "the precondition: node 2 was away")

        rig.link(0, 2)
        rig.commit(0, 2)
        try await rig.settle(until: { rig.nodes[2].manager.meshPhotos.isEmpty == false })

        #expect(rig.wallEntries(at: 2, itemID: key.itemID).count == 1,
                "the branch that was away shows the photo after the heal")
    }

    /// **R-7.** A blocked origin's photo is not handed to the wall — and its content key is never
    /// unwrapped, because the check is hoisted to the position the legacy author check held.
    ///
    /// The fourth assertion is the ordering claim, and it is only a claim because the item is minted
    /// with a wrap node 1 **cannot open**: its own fingerprint carries node 0's X25519 key. The
    /// manifest verifier checks the wraps' fingerprints against the destination set and never the
    /// keys, so the item is still admitted, custodied and complete. If the block check were moved
    /// back below the unwrap, the door would reach `MeshRoutedContentKeyWrapper.unwrap`, fail, and
    /// log `openFailed` — so `== 0` is reachable only when the door returned before the unwrap ran.
    /// Without the foreign wrap the same cell would pass with the check in either position, since
    /// node 1 is a real destination and the open would simply have succeeded.
    @Test func aBlockedOriginsPhotoIsNotHandedToTheWall() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-blocked")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)
        rig.nodes[1].store.blockProximityPeer(
            signingPublicKey: rig.identities[0].localSigningPublicKey
        )
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let item = try MeshRoutedPhotoFixtures.item(
            rig, origin: 0,
            recipientKeyOverrides: [
                rig.nodes[1].fingerprint: rig.identities[0].localKeyAgreementPublicKey
            ]
        )
        rig.link(0, 1)

        try rig.handOver(item, sender: 0, receiver: 1)
        try await rig.settle()

        let key = MeshRoutedItemKey(item.manifest)
        #expect(rig.nodes[1].manager.meshPhotos.isEmpty, "a blocked origin never reaches the wall")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: key)?.isComplete == true,
                "custody is kept: a view filter over an unmutated union, never a drop")
        #expect(capture.count(of: "mesh.routedProjection.blockedOrigin") >= 1,
                "the refusal is named")
        #expect(capture.count(of: "mesh.routedProjection.openFailed") == 0,
                "and nothing was opened before it: the unopenable wrap was never reached")
    }

    /// **R-15.** A projection whose origin the ledger cannot resolve refuses and keeps custody.
    ///
    /// The routed body carries no identity claim, so the wall entry's signing key comes from the
    /// admission ledger's roster entry for the signed origin. When that cannot be resolved the
    /// projection refuses: an entry is never written with a nil, empty or body-supplied key.
    @Test func aProjectionWithNoResolvableOriginRefusesAndKeepsCustody() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-unresolvable")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        let item = try MeshRoutedPhotoFixtures.item(rig, origin: 0)
        rig.link(0, 1)
        try rig.handOver(item, sender: 0, receiver: 1)
        try await rig.settle()
        let key = MeshRoutedItemKey(item.manifest)
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: key)?.isComplete == true,
                "the precondition: the ciphertext really is held")

        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        rig.nodes[1].manager.leaveMesh()
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)

        #expect(rig.nodes[1].manager.membershipVerifier == nil, "the ledger is gone")
        #expect(rig.nodes[1].manager.meshPhotos.isEmpty, "so nothing may be attributed, or shown")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: key) != nil, "custody is kept")
        #expect(capture.count(of: "mesh.routedProjection.originUnresolvable") >= 1,
                "and the refusal is named once per attempt")
    }

    /// **R-10 and R-11.** The wall entry carries the ORIGIN's attribution, from the ledger.
    ///
    /// The bytes arrive from a courier — node 2 signs the envelope, node 0 signed the manifest — and
    /// the two claims the legacy path could not make are asserted together: the fingerprint is the
    /// origin's, and the signing key is the roster's key for that origin rather than anything the
    /// payload carried, because the routed body carries no key at all.
    @Test func theWallEntryCarriesTheOriginsAttributionNotTheCouriers() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "photo-courier")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)
        let item = try MeshRoutedPhotoFixtures.item(rig, origin: 0)
        rig.link(1, 2)

        try rig.handOver(item, sender: 2, receiver: 1)
        try await rig.settle()

        let entry = try #require(
            rig.wallEntries(at: 1, itemID: item.manifest.itemID).first,
            "a courier-forwarded photo still reaches the wall"
        )
        #expect(entry.senderFingerprint == rig.nodes[0].fingerprint,
                "the attribution is the origin's, not the courier's")
        #expect(entry.senderSigningPublicKey == rig.identities[0].localSigningPublicKey,
                "and its signing key came from the ledger, because the body carries none")
    }

    /// **R-9.** One photo, one wall entry, however many times the pass runs.
    @Test func aPhotoIsHandedToTheWallOnce() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-once")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        let item = try MeshRoutedPhotoFixtures.item(rig, origin: 0)
        rig.link(0, 1)
        try rig.handOver(item, sender: 0, receiver: 1)
        try await rig.settle()

        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)
        rig.pushGate(.closed, at: 1)
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)

        #expect(rig.wallEntries(at: 1, itemID: item.manifest.itemID).count == 1,
                "two rising edges hand one photo to the wall once")
    }

    /// **R-8.** The per-origin quota still bites on the routed path.
    @Test func theEleventhPhotoFromOneSenderIsNotHandedToTheWall() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-quota")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)
        rig.link(0, 1)

        // The cap, DERIVED rather than written twice: `filmRemaining` on a manager that has
        // captured nothing is exactly `maxPhotosPerSenderPerSession`, which is `private`.
        let cap = rig.nodes[1].manager.filmRemaining
        var eleventh: UUID?
        // R2: a hard constant ceiling, one above the per-origin cap.
        for position in 0...cap {
            let item = try MeshRoutedPhotoFixtures.item(rig, origin: 0)
            if position == cap { eleventh = item.manifest.itemID }
            try rig.handOver(item, sender: 0, receiver: 1)
        }
        try await rig.settle()

        #expect(rig.nodes[1].manager.meshPhotos.count == cap,
                "one origin fills its own budget and no more")
        #expect(rig.wallEntries(at: 1, itemID: try #require(eleventh)).isEmpty,
                "and the item over the cap is the one that did not land")
    }

    /// **R-8b.** The quota is spent against the ITEM's mesh, not the live one.
    ///
    /// The legacy counter reset whenever `currentMesh` changed — sound while the check always ran
    /// inside the session that produced the photo, and wrong on a routed path whose hand-off runs at
    /// any later access-gate edge. Here the eleventh item is custodied, the device moves to another
    /// mesh, and only then does the plaintext pass run: a live-mesh-keyed counter would have handed
    /// that origin a fresh budget for content it had already queued.
    ///
    /// The move is made the way production makes it — `leaveMesh()` and then a **new mesh's ledger**
    /// — not by assigning `currentMesh`, which reaches none of the resets. That path runs
    /// `clearRoutedDrainState()`, so this cell is also the claim that the quota is not cleared there
    /// (D-13.23a): mesh A's items outlive the move (expiry is A's `hardDeadline + 20 min`, and the
    /// projection never compares the item's mesh to the live one), so refunding the budget on the
    /// move would hand this origin ten more of its mesh-A backlog.
    @Test func theQuotaIsSpentAgainstTheItemsMeshNotTheLiveOne() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-quota-mesh")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)
        rig.link(0, 1)
        let cap = rig.nodes[1].manager.filmRemaining
        // R2: a hard constant ceiling — exactly the per-origin budget, all projected.
        for _ in 0..<cap {
            try rig.handOver(try MeshRoutedPhotoFixtures.item(rig, origin: 0), sender: 0, receiver: 1)
        }
        try await rig.settle()
        #expect(rig.nodes[1].manager.meshPhotos.count == cap,
                "the precondition: the budget is spent under the item's own mesh")

        rig.pushGate(.closed, at: 1)
        let eleventh = try MeshRoutedPhotoFixtures.item(rig, origin: 0)
        try rig.handOver(eleventh, sender: 0, receiver: 1)
        try await rig.settle()

        let secondMeshID = UUID()
        let secondLedger = try MeshPartitionFixtures.ledger(
            founder: rig.identities[0], others: Array(rig.identities.dropFirst()),
            meshID: secondMeshID
        )
        rig.nodes[1].manager.leaveMesh()
        MeshDepartureRig.start(
            rig.nodes[1], ledger: secondLedger,
            founderKey: rig.identities[0].localSigningPublicKey, meshID: secondMeshID,
            createdAt: MeshRoutedDrainRig.createdAt
        )
        #expect(rig.nodes[1].manager.currentMesh?.meshID == secondMeshID,
                "the precondition: the device really is on another mesh")
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)

        #expect(rig.wallEntries(at: 1, itemID: eleventh.manifest.itemID).isEmpty,
                "a deferred hand-off cannot buy a fresh budget by changing mesh")
        #expect(rig.nodes[1].manager.meshPhotos.count == cap,
                "the wall still holds exactly the budget")
    }

    /// **B-3.** A body whose id is not the item id the origin signed is refused at the door.
    ///
    /// The seal binds the MANIFEST's item id, not the body's, so an origin picks the body's id
    /// freely inside an otherwise fully authenticated blob. The friend-photo surface keys and dedups
    /// on that id, so a body carrying another sender's photo id would land in that row's dedup
    /// contest — which is why the delivery door checks the equality the header's doc promises.
    @Test func aBodyWhoseIDIsNotTheItemIDIsRefused() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-idmismatch")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let item = try MeshRoutedPhotoFixtures.item(rig, origin: 0, bodyID: UUID())
        rig.link(0, 1)

        try rig.handOver(item, sender: 0, receiver: 1)
        try await rig.settle()

        #expect(rig.nodes[1].manager.meshPhotos.isEmpty, "a mismatched body id reaches no wall")
        #expect(capture.count(of: "mesh.routedProjection.openFailed") >= 1,
                "and the refusal is named on the projection's own audit line")
        #expect(rig.routedIndex(rig.nodes[1])?
            .record(for: MeshRoutedItemKey(item.manifest))?.isComplete == true,
                "custody is kept — the bytes are final, only the projection refused")
    }

    /// **R-18** (found reviewing pass B, not on the design's list). A locked window's backlog is not
    /// stranded above one pass's item allowance.
    ///
    /// Job 5's retry list is deliberately **non-shrinking**: `itemsAwaitingLocalProjection` names
    /// every live, complete, locally-destined item whether or not its plaintext has already been
    /// handed on, because there is no fourth stored rung to shrink it by — idempotence is the
    /// memory-only projected set plus the wall's own id dedup. Job 4's list, by contrast, shrinks as
    /// its durable stamps are written, so the two jobs may not spend their allowance the same way:
    /// taking the prefix FIRST and skipping the already-projected inside it hands every later rising
    /// edge the same sixteen items and strands the remainder until expiry. The allowance is
    /// therefore spent on items that still owe work.
    @Test func aBacklogAboveOnePassesAllowanceIsNotStranded() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "photo-backlog")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.link(0, 2)
        rig.link(1, 2)

        // One pass's allowance plus a remainder, split across two origins so that no per-origin
        // budget bites before the allowance does. R2: a hard constant ceiling.
        let allowance = MeshRoutedDrainBounds.increment1.maxItems
        let total = allowance + 2
        for position in 0..<total {
            let origin = position % 2
            try rig.handOver(
                try MeshRoutedPhotoFixtures.item(rig, origin: origin), sender: origin, receiver: 2
            )
        }
        try await rig.settle()
        #expect(rig.nodes[2].manager.meshPhotos.isEmpty,
                "the precondition: the whole backlog is custodied behind a closed gate")

        rig.pushGate(MeshRoutedDrainRig.openGate, at: 2)
        try await rig.settle()
        rig.pushGate(.closed, at: 2)
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 2)
        try await rig.settle()

        #expect(rig.nodes[2].manager.meshPhotos.count == total,
                "every item of the backlog reaches the wall across successive rising edges")
    }

    /// **R-19** (found reviewing pass B). A routed type this build cannot dispatch does not spend
    /// the projection allowance, so nothing sorted behind it is stranded.
    ///
    /// `MeshRoutedIndex.items` is ordered by ``MeshRoutedItemKey``, i.e. by origin fingerprint
    /// first, so an origin whose fingerprint sorts low can fill one pass's whole item allowance
    /// with items this device cannot finish, and every photo behind them waits until expiry. The
    /// remedy is R-18's, one layer out — the list is narrowed before the allowance is spent.
    ///
    /// **What makes `.tempMessage` unfinishable here changed at P6 item 4**, and the claim is the
    /// same either way. It used to be that the token had no dispatch arm at all; now it has one, and
    /// what keeps it out of the allowance on THIS rig is the other half of the same rule — the
    /// narrowed set is "one token per store this build has an arm for **and may write**", and these
    /// managers have no `chatAllowedProvider`, so the 13+ gate is shut and fail-closed. `.heart` is
    /// still the no-arm case until item 6. A device that could finish these items would project
    /// them, which is the behaviour, not a hole in this cell.
    @Test func aTypeWithNoDispatchArmDoesNotSpendTheProjectionAllowance() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "photo-noarm")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.link(0, 2)
        rig.link(1, 2)

        // The low-sorting origin fills the allowance with a type that has no arm; the photo is
        // minted by the other one, so it sorts strictly behind every one of them.
        let lower = rig.nodes[0].fingerprint < rig.nodes[1].fingerprint ? 0 : 1
        let allowance = MeshRoutedDrainBounds.increment1.maxItems
        // R2: a hard constant ceiling — exactly one pass's item allowance.
        for _ in 0..<allowance {
            try rig.handOver(
                try MeshRoutedPhotoFixtures.item(
                    rig, origin: lower, typeToken: MeshRoutedTypeToken.tempMessage
                ),
                sender: lower, receiver: 2
            )
        }
        let photo = try MeshRoutedPhotoFixtures.item(rig, origin: 1 - lower)
        try rig.handOver(photo, sender: 1 - lower, receiver: 2)
        try await rig.settle()
        #expect(rig.nodes[2].manager.meshPhotos.isEmpty,
                "the precondition: everything is custodied behind a closed gate")

        rig.pushGate(MeshRoutedDrainRig.openGate, at: 2)
        try await rig.settle()

        #expect(rig.wallEntries(at: 2, itemID: photo.manifest.itemID).count == 1,
                "one rising edge reaches the photo sorted behind a full allowance of unfinishable items")
    }

    /// **R-20** (found reviewing pass B). A DEPARTED origin's photo still reaches the wall.
    ///
    /// This is increment 1's headline case, not a corner: §11 ships origin-retains plus
    /// custody-transfer-on-departure, so the origin leaves, hands its outstanding items to the
    /// custodians it named, and those custodians deliver **afterwards** — by which time every
    /// destination's derived roster (`admitted − departed − removed`) already excludes the origin.
    /// The manifest verifier that admitted the item consults admissions and removals only, because
    /// leaving is not a retraction, and the projection resolves the author from the same set. A
    /// projection reading `roster.members` would refuse here forever, after the item had been
    /// custodied, completed and receipted — the origin would read `delivered` for content the
    /// recipient could never see.
    @Test func aDepartedOriginsPhotoStillReachesTheWall() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "photo-departed")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        let item = try MeshRoutedPhotoFixtures.item(rig, origin: 0)
        rig.link(0, 1)
        try rig.handOver(item, sender: 0, receiver: 1)
        try await rig.settle()
        #expect(rig.routedIndex(rig.nodes[1])?
            .record(for: MeshRoutedItemKey(item.manifest))?.isComplete == true,
                "the precondition: the ciphertext really is held")

        var departed = rig.ledger
        departed.departures = departed.departures.inserting(
            try SignedDepartureRecord.signed(meshID: rig.meshID, identity: rig.identities[0])
        )
        rig.nodes[1].manager.seedMembershipLedgerForTesting(
            meshID: rig.meshID,
            founderSigningPublicKey: rig.identities[0].localSigningPublicKey,
            ledger: departed
        )
        #expect(rig.nodes[1].manager.membershipVerifier?.roster.memberFingerprints
            .contains(rig.nodes[0].fingerprint) == false,
                "the precondition: the derived roster no longer names the origin")

        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)

        let entry = try #require(
            rig.wallEntries(at: 1, itemID: item.manifest.itemID).first,
            "a departed origin's already-custodied photo still reaches the wall"
        )
        #expect(entry.senderSigningPublicKey == rig.identities[0].localSigningPublicKey,
                "and its signing key still comes from the admission that let it in")
    }

    /// **R-21** (found reviewing pass B, the other half of R-20). A REMOVED origin's photo is
    /// refused, by name.
    ///
    /// The asymmetry is deliberate and is the manifest verifier's own (plan §10.4): a departure is
    /// the member's own choice and retracts nothing, while a quorum removal is the mesh's moderation
    /// act. It is also the only membership record the content path may consult, because the routed
    /// content key is wrapped to each recipient's static X25519 key — the group-key rotation that
    /// excludes a removed member from live control traffic excludes it from nothing here.
    @Test func aRemovedOriginsPhotoIsRefusedByName() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "photo-removed")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        let item = try MeshRoutedPhotoFixtures.item(rig, origin: 0)
        rig.link(0, 1)
        try rig.handOver(item, sender: 0, receiver: 1)
        try await rig.settle()

        var removed = rig.ledger
        removed.removals = removed.removals.inserting(try SignedRemovalRecord.signed(
            meshID: rig.meshID,
            identity: rig.identities[1],
            memberFingerprint: rig.nodes[0].fingerprint,
            proposalID: UUID(),
            voterFingerprints: [rig.nodes[1].fingerprint, rig.nodes[2].fingerprint],
            occurredAt: MeshP3Acceptance.base
        ))
        rig.nodes[1].manager.seedMembershipLedgerForTesting(
            meshID: rig.meshID,
            founderSigningPublicKey: rig.identities[0].localSigningPublicKey,
            ledger: removed
        )
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)

        #expect(rig.nodes[1].manager.meshPhotos.isEmpty, "a removed origin reaches no wall")
        #expect(capture.count(of: "mesh.routedProjection.originRemoved") >= 1,
                "and the refusal is named, distinctly from an origin nobody ever admitted")
        #expect(rig.routedIndex(rig.nodes[1])?
            .record(for: MeshRoutedItemKey(item.manifest)) != nil,
                "custody is kept — the refusal is a view filter, never a drop")
    }

    /// **R-22** (found reviewing pass B). The routed twin of the retired `preCommitFriendPhotoIsDropped`:
    /// a routed frame on an **uncommitted** slot creates no record and is dropped by name.
    ///
    /// The legacy claim — "an uncommitted slot must never reach the photo wall" — retired with
    /// `handleFriendPhotoEnvelope`, and photo ingest moved onto `dispatchRoutedPayload`, whose
    /// `guard let senderFingerprint = slot?.fingerprint` is now the only thing between a merely
    /// introduced peer and the wall. The second half of the cell is what makes the first
    /// non-vacuous: the identical frame on the committed slot IS admitted, so the drop is the slot's
    /// doing rather than the fixture's.
    @Test func aRoutedPhotoOnAnUncommittedSlotIsDropped() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-precommit")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let item = try MeshRoutedPhotoFixtures.item(rig, origin: 0)
        let key = MeshRoutedItemKey(item.manifest)
        rig.link(0, 1)

        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 1, committedSlot: false
        )

        #expect(rig.routedIndex(rig.nodes[1])?.record(for: key) == nil,
                "an uncommitted slot writes no routed record")
        #expect(rig.nodes[1].manager.meshPhotos.isEmpty, "and reaches no wall")
        #expect(capture.count(of: "mesh.routedDrain.droppedUncommittedSlot") == 1,
                "the drop is named once, at the routed door")

        try rig.handOver(item, sender: 0, receiver: 1)
        try await rig.settle()

        #expect(rig.routedIndex(rig.nodes[1])?.record(for: key) != nil,
                "the same manifest on the committed slot is admitted: the drop was the slot's doing")
    }
}

// MARK: - The addressing family (network migration P6 item 1)

/// What `twoDoorsFiringForOnePeerInOneTurnWriteOneFrame` observed about the interleaving it needs.
///
/// A one-frame count is true both when the second door ran *inside* the first door's suspension —
/// the state the in-flight claim exists for — and when it ran after the first had completed and
/// latched the peer. Only the first of those is the property, so the second door records its own
/// return and the suspension records whether that had already happened. `@MainActor`, like every
/// other value the cell touches, so nothing here crosses an isolation boundary.
@MainActor
final class MeshDoubleDoorProbe {

    /// Set by the second door as its last act.
    var secondDoorReturned = false

    /// What ``secondDoorReturned`` held while the first door was still parked inside its write.
    var secondDoorReturnedInsideTheSuspension = false
}

/// What the key advertisement buys the mint, and what it deliberately does not.
///
/// Every cell here drives the real doors: the real send at a real link-open, the real membership
/// dispatch at the receiver, the real verifier against the receiver's own admission set. The rig's
/// one seam is `armKeyAdvertisements()`, which calls the production self-mint — the tier-1 rigs arm
/// their ledgers through a seed that bypasses both arming doors, so without it no node would have
/// its own row to relay.
///
/// The honest labels, which the plan's §11.3/§23.4 rewrite must use verbatim: of D-13.22's three
/// refusals the advertisement converts **one** into a delivery (the resumption, `R-16`) and the
/// other two — the **star** and the **over-cap roster** — into a successful mint whose delivery
/// waits for a link or a departure hand-off. `relayInFlight` is increment 2's, so a destination that
/// holds an item never forwards it: a cell that asserted only "`.staged`, no refusal" would be green
/// while the unlinked member held nothing at all.
@MainActor
@Suite(.serialized)
struct MeshKeyAdvertisementDeliveryTests {

    /// **R-12, FLIPPED: the star topology mints, with custody, for a member it has never linked.**
    ///
    /// A–B and B–C are linked; A and C never are. B relays A's own signed row to C and C's to A, so
    /// A can address C for the first time. The explicit negative is the half that stops the cell
    /// overclaiming: while A retains custody, **C's store holds nothing** — the origin serves its
    /// destinations itself, and B may not forward what it holds.
    @Test func aStarTopologyMintsForAMemberItHasNeverLinkedAndCustodiesUntilALinkForms() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "advert-star")
        defer { rig.teardown() }
        rig.armKeyAdvertisements()

        try await rig.heal(0, 1)
        try await rig.heal(1, 2)
        // B's set grew when it folded C's row, so B owes A a second frame — and the version bound
        // re-arms exactly there. A second commit of the SAME pair is what fires it.
        rig.commit(0, 1)
        try await rig.settle()

        #expect(rig.advertisementCount(at: 0) == 3,
                "A must hold every member's row, C's relayed through B")
        #expect(rig.nodes[0].manager.keyAdvertisements
                .keyAgreementPublicKey(for: rig.nodes[2].fingerprint)
                == rig.identities[2].localKeyAgreementPublicKey,
                "and it must be C's real durable key, not a descriptor's claim")

        rig.capturePhoto(at: 0)
        try await rig.settle()

        #expect(rig.nodes[0].manager.routedShareRefusal == nil,
                "the mint must not refuse: C is addressable from its advertisement")
        let staged = try #require(rig.routedIndex(rig.nodes[0]), "A must hold its own item")
        let record = try #require(staged.items.first)
        #expect(record.deliveryTarget?.destinationCount == 2, "both other members are destinations")
        #expect(rig.routedIndex(rig.nodes[1])?.items.count == 1, "B is linked, so B was served")
        #expect(rig.routedIndex(rig.nodes[2]) == nil,
                "C holds NOTHING while A retains custody: a destination never forwards")
        #expect(record.deliveryTarget?.state(of: rig.nodes[2].fingerprint) != .delivered,
                "and A's own rung for C says so")
    }

    /// The over-cap twin of the star: a roster larger than the slot cap mints for every admitted
    /// member, and the unlinked ones are custodied.
    ///
    /// Six members against `maxTotalSlots` of five, so the origin cannot possibly be linked to
    /// everybody at once — the case D-13.22 named second.
    @Test func aRosterAboveTheSlotCapMintsForEveryAdmittedMember() async throws {
        let rig = try MeshRoutedDrainRig.build(6, label: "advert-overcap")
        defer { rig.teardown() }
        #expect(rig.nodes.count == 6,
                "six members against a five-slot cap: the origin cannot be linked to all of them")
        rig.armKeyAdvertisements()
        // A chain, so no node is ever linked to more than two others and the origin is linked to
        // exactly one: every other destination is addressable only from a relayed advertisement.
        // R2: bounded by the rig's node count.
        for index in 0..<(rig.nodes.count - 1) { try await rig.heal(index, index + 1) }
        // R2: the same bound, in reverse — the relay needs one pass per hop to carry every row
        // back down the chain, and each pass is re-armed by the set that grew on the last.
        for index in stride(from: rig.nodes.count - 2, through: 0, by: -1) {
            rig.commit(index, index + 1)
            try await rig.settle()
        }

        #expect(rig.nodes[0].manager.slots.count == 1,
                "the origin is linked to exactly one peer, which is what makes the cell honest")
        #expect(rig.advertisementCount(at: 0) == rig.nodes.count,
                "every member's row must reach the origin through the chain")

        rig.capturePhoto(at: 0)
        try await rig.settle()

        #expect(rig.nodes[0].manager.routedShareRefusal == nil, "the mint must not refuse")
        let record = try #require(rig.routedIndex(rig.nodes[0])?.items.first)
        #expect(record.deliveryTarget?.destinationCount == rig.nodes.count - 1,
                "the destination set is the whole roster minus this device")
    }

    /// A second heal of the same pair carries a key the peer learned in between.
    ///
    /// This is the residual the send bound deliberately does NOT inherit: `reGossipedToFingerprints`
    /// is spent forever, so a second heal of one pair inside a session exchanges no records. For
    /// addressing that rule would mean a peer that folded a third member's key after it last spoke
    /// to this one could never pass it on — which is the star case, un-fixed. The bound is the SET's
    /// version instead: told once per version, re-armed when the set actually grows.
    @Test func aSecondHealOfTheSamePairCarriesAKeyLearnedInBetween() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "advert-second-heal")
        defer { rig.teardown() }
        rig.armKeyAdvertisements()

        try await rig.heal(0, 1)
        #expect(rig.advertisementCount(at: 0) == 2, "the first heal carried B's own row")
        #expect(rig.nodes[0].manager.keyAdvertisements
                .advertisement(for: rig.nodes[2].fingerprint) == nil,
                "and nobody has told A about C yet")

        try await rig.heal(1, 2)
        #expect(rig.advertisementCount(at: 1) == 3, "B now holds a row A lacks")
        rig.commit(0, 1)
        try await rig.settle()

        #expect(rig.nodes[0].manager.keyAdvertisements
                .advertisement(for: rig.nodes[2].fingerprint) != nil,
                "the second heal must carry the row B learned in between")
    }

    /// The frame is unsealed and enumerates the roster, so it is written to NAMED committed
    /// recipients only — never to every slot.
    ///
    /// The negative is structural: `sendKeyAdvertisements(to:)` takes a non-optional set, and
    /// `broadcastMembershipFrame`'s named-set path skips any slot with no fingerprint. A nil there
    /// would write every member's fingerprint and public key, in the clear, to an unauthenticated
    /// peer in radio range.
    @Test func anUncommittedSlotReceivesNoAdvertisementFrame() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "advert-uncommitted")
        defer { rig.teardown() }
        rig.armKeyAdvertisements()
        rig.link(0, 1)
        // R2: bounded by the slot cap. An introduced-but-uncommitted peer carries no fingerprint.
        for index in rig.nodes[0].manager.slots.indices {
            rig.nodes[0].manager.slots[index].fingerprint = nil
        }

        rig.commit(1, 0)
        try await rig.settle()

        let received = rig.tokens(at: 1, from: 0)
        #expect(!received.contains(PayloadType.meshKeyAgreement.rawValue),
                "an uncommitted slot must never be written an advertisement")
        #expect(rig.advertisementCount(at: 1) == 1, "so node 1 still holds only its own row")
    }

    /// A destination the set has marked **conflicted** refuses the whole mint by name.
    ///
    /// Two different keys under one fingerprint, both verified, means this device cannot say which
    /// key that member holds — so it refuses rather than picking one. Driven through the real
    /// receive door: the second row is a real advertisement, signed by the same member over a
    /// re-provisioned key, relayed on a real frame.
    @Test func aConflictedDestinationRefusesTheMintByName() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "advert-conflict")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        #expect(rig.advertisementCount(at: 0) == 2, "the honest row must be folded first")

        // The same member, a second DIFFERENT key, signed by that member's own key: the only actor
        // who can produce one, and no legitimate provisioning path does.
        let second = try SignedKeyAgreementAdvertisement.signedForTesting(
            meshID: rig.meshID, identity: rig.identities[1],
            keyAgreementPublicKey: MeshKeyAgreementFixtures.key(77),
            advertisedAt: MeshRoutedDrainRig.now.addingTimeInterval(60)
        )
        try rig.deliverMembershipFrame(
            MeshKeyAgreementPayload(
                meshID: rig.meshID, advertisements: [second],
                senderFingerprint: rig.nodes[1].fingerprint
            ),
            type: .meshKeyAgreement, sender: 1, receiver: 0
        )

        #expect(rig.nodes[0].manager.keyAdvertisements.isConflicted(rig.nodes[1].fingerprint),
                "a second verified key marks the member unaddressable")
        #expect(capture.count(of: "mesh.keyAgreement.conflicted") == 1, "named once")

        rig.capturePhoto(at: 0)

        #expect(rig.nodes[0].manager.routedShareRefusal == .keyMismatch,
                "a conflicted destination refuses the mint by its own frozen name")
        #expect(rig.routedIndex(rig.nodes[0]) == nil, "and nothing is staged")
        #expect(rig.nodes[0].manager.meshPhotos.count == 1, "the local echo still runs")
        #expect(capture.values(of: "mesh.routedShare.refused", key: "reason") == ["keyMismatch"],
                "the refusal is audited by its frozen token")
    }

    /// A handshake-verified key that DISAGREES with a verified advertisement refuses too, and for
    /// the same reason: both are verified sources, and picking one would mean either wrapping to a
    /// key the peer no longer holds or accepting a substitution.
    @Test func aDisagreeingHandshakeKeyRefusesTheMintByName() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "advert-mismatch")
        defer { rig.teardown() }
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        #expect(rig.advertisementCount(at: 0) == 2, "the advertised key must be present")

        rig.seedSlotKey(at: 0, toward: 1, key: MeshKeyAgreementFixtures.key(77))

        rig.capturePhoto(at: 0)

        #expect(rig.nodes[0].manager.routedShareRefusal == .keyMismatch,
                "two verified sources that disagree are a refusal, never a choice")
        #expect(rig.routedIndex(rig.nodes[0]) == nil, "and nothing is staged")
    }

    /// The handshake-verified key WINS when the two sources agree — precedence, not coincidence.
    @Test func theHandshakeVerifiedKeyResolvesWhenBothSourcesAgree() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "advert-precedence")
        defer { rig.teardown() }
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        rig.seedSlotKey(at: 0, toward: 1, key: rig.identities[1].localKeyAgreementPublicKey)

        rig.capturePhoto(at: 0)
        try await rig.settle()

        #expect(rig.nodes[0].manager.routedShareRefusal == nil, "agreeing sources resolve")
        #expect(rig.routedIndex(rig.nodes[1])?.items.count == 1, "and the item is delivered")
    }

    /// The ADMITTER's own addressing reaches the member it just admitted, on the grant door.
    ///
    /// None of the five link-open doors fires on the admitter's side of a first grant:
    /// `handleAdmissionGrant(` is the joiner's door, and `openBlipMergeIfReconnected(_:from:peer:)`
    /// deliberately opens no merge exchange for a peer that was not already on the roster
    /// ("admission ≠ reconnect"). Without the grant door the joiner's set would reach the admitter
    /// and the admitter's set would reach nobody — so a fresh pair, which never has a merge
    /// exchange at all, would leave the joiner unable to address the member that let it in.
    ///
    /// The pair is linked and **never committed through the session machine**, which is what makes
    /// the cell honest: no ask door can fire, so the frame that arrives arrived from the grant. The
    /// grant is idempotent here (the rig seeds both members into the ledger, so
    /// `recordGrantedAdmission(_:)` re-files a record it already holds and the roster does not
    /// move) — what is under test is the door, not the admission.
    @Test func aGrantCarriesTheAdmittersOwnAdvertisementAfterTheGrantItself() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "advert-grant")
        defer { rig.teardown() }
        rig.armKeyAdvertisements()
        rig.link(0, 1)
        #expect(rig.advertisementCount(at: 1) == 1, "the admitted peer starts with its own row only")

        rig.nodes[0].manager.allowAdmission(MeshAdmissionRequestPayload(
            meshID: rig.meshID,
            requesterFingerprint: rig.nodes[1].fingerprint,
            requesterDisplayName: "joiner",
            requesterSigningPublicKey: rig.identities[1].localSigningPublicKey,
            requesterKeyAgreementPublicKey: rig.identities[1].localKeyAgreementPublicKey
        ))
        try await rig.settle()

        #expect(rig.advertisementCount(at: 1) == 2,
                "the grant door must carry the admitter's own row")
        #expect(rig.nodes[1].manager.keyAdvertisements
                .keyAgreementPublicKey(for: rig.nodes[0].fingerprint)
                == rig.identities[0].localKeyAgreementPublicKey,
                "and it must be the admitter's real durable key")
        let received = rig.tokens(at: 1, from: 0)
        let grantAt = received.firstIndex(of: PayloadType.meshAdmissionGrant.rawValue)
        let addressingAt = received.firstIndex(of: PayloadType.meshKeyAgreement.rawValue)
        #expect(grantAt != nil, "the grant itself must have been sent")
        #expect(addressingAt != nil, "and the addressing with it")
        if let grantAt, let addressingAt {
            #expect(grantAt < addressingAt,
                    "the order is load-bearing: before the grant the joiner has no ledger to verify against")
        }
    }

    /// **Three lines carry the frame in, and a missing one of them is SILENT.** Pinned by source.
    ///
    /// This is not paranoia: the first draft of pass B had the `decodeMembershipFrame` arm, the
    /// `DecodedMembershipRecord` case and the dispatch arm — and not the top-level routing line — and
    /// every advertisement was dropped at the dispatch switch's `default` with no audit line at all.
    /// Two of the three are compile-fenced (`mergeOffer(for:)`, `insertMembershipRecord` and
    /// `bufferedForAdoption` are `default`-free switches over `DecodedMembershipRecord`); the other
    /// two are not, and `decodeMembershipFrame`'s `default: return nil` plus
    /// `dispatchMembershipEventPayload`'s unaudited `guard let decoded` is exactly how a forgotten
    /// arm becomes a frame that never arrived.
    @Test func theKeyAgreementFrameIsRoutedDecodedAndDispatched() throws {
        let source = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift")
        )
        #expect(source.contains(".meshInventoryDigest, .meshEpochHeads, .meshKeyAgreement:"),
                "the top-level switch must route the token to the membership-event family")
        #expect(source.contains("case .meshKeyAgreement:"),
                "decodeMembershipFrame must have its own arm, or the frame decodes to nil")
        #expect(source.contains("case .keyAdvertisements(let payload) = decoded"),
                "and the dispatch must hand the decoded batch to the receive door")
        #expect(source.contains("receiveKeyAdvertisements(payload, from: senderFingerprint)"),
                "with the AUTHENTICATED sender, never the frame's own audit-only field")
    }

    /// A persisted advertisement whose admission the CURRENT ledger no longer proves is dropped at
    /// the restore, not trusted from the file seal.
    ///
    /// The narrowing is real and durable: the same sealed blob carries C's own signed departure, so
    /// the ledger that comes back derives a roster C is not on, and the verifier's membership check
    /// refuses C's row. The file seal proves only that this install wrote the bytes.
    @Test func aPersistedAdvertisementWhoseAdmissionNarrowedIsDroppedAtRestore() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "advert-narrowed")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        try await rig.heal(1, 2)
        rig.commit(0, 1)
        try await rig.settle()
        #expect(rig.advertisementCount(at: 0) == 3, "all three rows must be folded and sealed")

        // C leaves, with its own signed departure — the record that narrows the derived roster.
        try rig.fileDeparture(of: 2, into: 0)
        #expect(rig.nodes[0].manager.membershipVerifier?.roster
                .contains(fingerprint: rig.nodes[2].fingerprint) == false,
                "the precondition: the ledger no longer names C")

        let reborn = MeshNetworkManager(
            store: rig.nodes[0].store, transport: FakeMeshTransportSession(),
            identity: rig.identities[0]
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = reborn.restoreSessionContextAtLaunch(now: MeshRoutedDrainRig.now)
        }

        #expect(reborn.keyAdvertisements.count == 2,
                "the row for the member the ledger cannot prove was dropped")
        #expect(reborn.keyAdvertisements.advertisement(for: rig.nodes[2].fingerprint) == nil,
                "and it is that row, not another")
        #expect(capture.count(of: "mesh.keyAgreement.rejected") >= 1,
                "the drop is named, never silent")
        reborn.leaveMesh()
    }

    // MARK: The send latch, the repair order and the receive budget (pass B review findings 1-4)

    /// **A frame the wire never wrote leaves its recipient OWED, and the next door re-sends.**
    ///
    /// The latch used to be written for every owed peer before the `await`, and nothing re-arms it
    /// except the local set changing — and no door fires on a fold. So on a stable pair whose set
    /// never grows again, one frame written to nobody (a disconnect between the door firing and the
    /// write, or a failed write) meant the peer was never told for the rest of the session and every
    /// mint refused `destinationNotAddressable`.
    ///
    /// The lost recipient is node 2, whose row node 0 learns through a relay *before* it has ever
    /// been linked to it — so the door fires for a roster member node 0 holds no slot for, the frame
    /// is written to nobody, and node 0's set is already complete by the time the link forms. That
    /// last part is what makes the cell load-bearing: nothing re-arms the latch on the later heal,
    /// because node 2's own row is one node 0 already holds.
    @Test func anAdvertisementFrameWrittenToNobodyLeavesItsRecipientOwed() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "advert-relatch")
        defer { rig.teardown() }
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        let third = try #require(rig.nodes[2].manager.keyAdvertisements
            .advertisement(for: rig.nodes[2].fingerprint))
        try rig.deliverMembershipFrame(
            MeshKeyAgreementPayload(
                meshID: rig.meshID, advertisements: [third],
                senderFingerprint: rig.nodes[1].fingerprint
            ),
            type: .meshKeyAgreement, sender: 1, receiver: 0
        )
        #expect(rig.advertisementCount(at: 0) == 3, "node 0's set is complete before any link to C")

        // The door fires for a roster member node 0 holds no slot for.
        await rig.nodes[0].manager.sendKeyAdvertisements(to: [rig.nodes[2].fingerprint])
        #expect(rig.advertisementCount(at: 2) == 1, "unlinked, so nothing can have been written")

        try await rig.heal(0, 2)

        #expect(rig.advertisementCount(at: 2) == 3,
                "the peer stayed owed, so the first real link-open carried the whole set")
    }

    /// The bounded self-mint repair is **not** spent when there is nobody to tell.
    ///
    /// Five of the six doors are peer-driven, so with the repair above the roster filter three link
    /// flaps burned all three attempts — a signature and a sealed write each — with `owed` empty.
    /// Here every recipient is off the roster, so the send has nothing to do and must mint nothing.
    @Test func aDoorWithNoMemberToTellSpendsNoSelfMintAttempt() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "advert-repair-order")
        defer { rig.teardown() }
        #expect(rig.advertisementCount(at: 0) == 0, "nothing is armed: the repair is what would mint")

        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            // R2: three calls, the repair's own per-session cap.
            for _ in 0..<3 {
                await rig.nodes[0].manager.sendKeyAdvertisements(to: ["not-a-member-fingerprint"])
            }
        }

        #expect(rig.advertisementCount(at: 0) == 0,
                "a recipient set the ledger does not name spends no attempt and mints nothing")
    }

    /// The repair's per-session cap: three attempts, then named and refused.
    ///
    /// `.unavailable` makes every sealed write fail, which is the outage the repair exists for — and
    /// the one that must not become per-link-open work forever on a device whose store is broken.
    ///
    /// **The door count and the expected line count are LITERALS** (second fix review finding 10).
    /// Driving the loop from the constant made this cell unable to fail on a mutation of its own
    /// bound: raising `selfMintAttemptsPerSession` raised the loop with it, so the count still
    /// matched and the only red the log ever showed was collateral from a different mutation. Six
    /// doors against three expected lines reds on a raised cap (five lines), on a lowered one, and
    /// on a deleted guard (six).
    @Test func theSelfMintRepairIsSpentThreeTimesAndThenNamed() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "advert-repair-cap")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        #expect(MeshKeyAdvertisementSendBounds.selfMintAttemptsPerSession == 3,
                "the cap is three; the literals below are pinned against it")

        await DeviceBindingID.$testOverride.withValue(.unavailable) {
            // R2: six doors — twice the cap, as a literal.
            for _ in 0..<6 {
                await rig.nodes[0].manager.sendKeyAdvertisements(to: [rig.nodes[1].fingerprint])
            }
        }

        #expect(capture.count(of: "mesh.keyAgreement.selfMintUnavailable") == 3,
                "three attempts are named, one per attempt, and the cap stops the other three doors")
        #expect(rig.advertisementCount(at: 0) == 0,
                "and a mint the store refused is rolled back out of memory")
    }

    /// The repair still runs once every member has been TOLD — the state it exists for.
    ///
    /// The pre-check used to be "a member is OWED the current version", which is stricter than "a
    /// member exists" in exactly one reachable state, and it is the outage state: the arm-time seal
    /// was refused, a peer's row was then folded and sent, so every member is latched at the current
    /// version with the self row still missing. Attempts two and three were forfeited for the
    /// session, silently, and a store that recovered mid-session never minted the row — leaving the
    /// device unaddressable to every member it is not linked to, which is the whole outage this
    /// family closes.
    @Test func aRecoveredStoreStillMintsTheSelfRowAfterEveryMemberWasTold() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "advert-repair-recovers")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        rig.armKeyAdvertisement(at: 1)
        rig.link(0, 1)
        let peerRow = try #require(rig.nodes[1].manager.keyAdvertisements
            .advertisement(for: rig.nodes[1].fingerprint))
        try rig.deliverMembershipFrame(
            rig.advertisementFrame([peerRow], from: 1),
            type: .meshKeyAgreement, sender: 1, receiver: 0
        )
        #expect(rig.advertisementCount(at: 0) == 1,
                "the precondition: node 0 holds the peer's row and not its own")

        // A door fires while the store refuses every seal: the repair fails, the frame is still
        // written, so node 1 ends LATCHED at the current version with the self row still missing.
        await DeviceBindingID.$testOverride.withValue(.unavailable) {
            await rig.nodes[0].manager.sendKeyAdvertisements(to: [rig.nodes[1].fingerprint])
        }
        #expect(capture.count(of: "mesh.keyAgreement.selfMintUnavailable") == 1,
                "one attempt was spent and named")
        #expect(rig.advertisementCount(at: 0) == 1, "and the refused mint was rolled back")

        // The store recovers and the next door fires. Nobody is owed anything.
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await rig.nodes[0].manager.sendKeyAdvertisements(to: [rig.nodes[1].fingerprint])
        }

        #expect(rig.nodes[0].manager.keyAdvertisements
                .advertisement(for: rig.nodes[0].fingerprint) != nil,
                "a recovered store mints the row its arm could not")
        try await rig.settle()
        #expect(rig.advertisementCount(at: 1) == 2,
                "and the mint moved the version, so the latch re-armed and the peer was re-sent")
    }

    /// Two doors firing for one peer inside one turn write the frame **once**.
    ///
    /// The latch is the in-flight claim as well as the "already told" record. Recording only what
    /// the wire reached — the fix for one lost frame becoming a session-long outage — moved the
    /// write under the `await` and left nothing claimed while it was in flight: this manager is
    /// MainActor-isolated, so a second door (`beginMergeExchange`, `readvertiseMergeProof` and
    /// `askOneReconnectedPeer` all spawn their own send and their recipient sets overlap) recomputed
    /// the same `owed` and wrote the frame again, spending an encode, a signature and one frame of
    /// the receiver's per-sender budget. The suspension is installed in the fake channel because
    /// this fabric's `send` has no suspension point of its own — see `sendSuspension`.
    ///
    /// **The interleaving is observed, not assumed** (third review P3 8). `sentFrames.count == 1`
    /// alone passes for the wrong reason whenever the second door runs *after* the first completed:
    /// the peer is then latched by a successful write, `owed` is empty and the count is one anyway.
    /// Eight `Task.yield()`s is the only lever, so on another scheduler the cell could go on
    /// passing with the property gone. The probe records, from inside the suspension, whether the
    /// second door had already returned — which it can only have done by evaluating `owed` against
    /// a latch the first door claimed and has not yet released.
    @Test func twoDoorsFiringForOnePeerInOneTurnWriteOneFrame() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "advert-double-door")
        defer { rig.teardown() }
        rig.armKeyAdvertisements()
        rig.link(0, 1)
        #expect(rig.nodes[0].channel.sentFrames.isEmpty, "nothing has been written yet")
        let probe = MeshDoubleDoorProbe()
        rig.nodes[0].channel.sendSuspension = { index in
            guard index == 0 else { return }
            // R2: a fixed number of yields — enough for the queued door to run to completion.
            for _ in 0..<8 { await Task.yield() }
            probe.secondDoorReturnedInsideTheSuspension = probe.secondDoorReturned
        }

        async let first: Void = rig.nodes[0].manager
            .sendKeyAdvertisements(to: [rig.nodes[1].fingerprint])
        async let second: Void = Self.sendRecordingReturn(
            from: rig.nodes[0].manager, to: rig.nodes[1].fingerprint, recordingOn: probe
        )
        _ = await (first, second)
        rig.nodes[0].channel.sendSuspension = nil

        #expect(probe.secondDoorReturnedInsideTheSuspension,
                "the second door must have run its owed computation while the first was in flight")
        #expect(rig.nodes[0].channel.sentFrames.count == 1,
                "the second door saw the claim and wrote nothing")
    }

    /// The second door of the cell above, with its return recorded so the interleaving is a fact
    /// the assertion can read rather than a hope about the scheduler.
    private static func sendRecordingReturn(
        from manager: MeshNetworkManager, to peer: String, recordingOn probe: MeshDoubleDoorProbe
    ) async {
        await manager.sendKeyAdvertisements(to: [peer])
        probe.secondDoorReturned = true
    }

    /// A fold the store refused is **rolled back**, with its conflict marks, and named.
    ///
    /// Durable before it counts (plan §3.6): "verified" and "remembered" have to be the same set,
    /// or a relaunch silently forgets a key the mint has already wrapped content to.
    @Test func aFoldTheStoreRefusedIsRolledBackAndNamed() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "advert-notdurable")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        #expect(rig.advertisementCount(at: 0) == 2, "the pair's two rows must be folded first")

        // Node 2's own row, relayed by node 1 — a real fold that really changes the set — with
        // every sealed write failing.
        let third = try #require(rig.nodes[2].manager.keyAdvertisements
            .advertisement(for: rig.nodes[2].fingerprint))
        try rig.deliverMembershipFrame(
            MeshKeyAgreementPayload(
                meshID: rig.meshID, advertisements: [third],
                senderFingerprint: rig.nodes[1].fingerprint
            ),
            type: .meshKeyAgreement, sender: 1, receiver: 0, binding: .unavailable
        )

        #expect(rig.advertisementCount(at: 0) == 2, "the set is rolled back to what is on disk")
        #expect(rig.nodes[0].manager.keyAdvertisements
                .advertisement(for: rig.nodes[2].fingerprint) == nil, "and it is that row")
        #expect(capture.count(of: "mesh.keyAgreement.notDurable") == 1, "named, never silent")
    }

    /// A fold the store refused costs the sender's VERSION nothing, so nobody is re-told a set they
    /// already hold.
    ///
    /// Third review P3 5. `adoptKeyAdvertisements(_:)` bumps on every difference and a rollback
    /// differs from the value it undoes, so a refused fold used to move the version **twice** and
    /// end byte-identical to what every peer had already been told. Every member was then owed the
    /// set again and re-sent an unchanged frame, each one charged against that receiver's
    /// `framesPerSenderPerSession` — the one path on which an honest device can spend a peer's whole
    /// forty-eight on frames carrying nothing new and then have the frame that matters refused. The
    /// observable is the send: a peer already told the current version is written nothing, and a
    /// refused fold must not change that.
    @Test func aFoldTheStoreRefusedLeavesNobodyOwedTheSetTheyHold() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "advert-rollback-version")
        defer { rig.teardown() }
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        #expect(rig.advertisementCount(at: 0) == 2, "the pair's two rows must be folded first")

        // Quiesced first, and that takes two sends: the heal's own send goes out BEFORE node 0
        // folds node 1's row, so node 1 is genuinely owed the post-fold set afterwards. The second
        // send is the one that must write nothing.
        await rig.nodes[0].manager.sendKeyAdvertisements(to: [rig.nodes[1].fingerprint])
        let beforeQuiet = rig.nodes[0].channel.sentFrames.count
        await rig.nodes[0].manager.sendKeyAdvertisements(to: [rig.nodes[1].fingerprint])
        #expect(rig.nodes[0].channel.sentFrames.count == beforeQuiet,
                "the precondition: node 1 is already latched at node 0's current version")

        // A real fold that really changes the set, with every sealed write failing.
        let third = try #require(rig.nodes[2].manager.keyAdvertisements
            .advertisement(for: rig.nodes[2].fingerprint))
        try rig.deliverMembershipFrame(
            MeshKeyAgreementPayload(
                meshID: rig.meshID, advertisements: [third],
                senderFingerprint: rig.nodes[1].fingerprint
            ),
            type: .meshKeyAgreement, sender: 1, receiver: 0, binding: .unavailable
        )
        #expect(rig.advertisementCount(at: 0) == 2, "the set is back to what is on disk")

        let beforeRetry = rig.nodes[0].channel.sentFrames.count
        await rig.nodes[0].manager.sendKeyAdvertisements(to: [rig.nodes[1].fingerprint])
        #expect(rig.nodes[0].channel.sentFrames.count == beforeRetry,
                "and the version came back with the set, so the unchanged set is not re-sent")
    }

    /// The per-sender receive bound: one sender's frames are capped and the cap is named.
    ///
    /// The frame is unsigned at frame level and can cost sixteen Ed25519 verifications, so this is
    /// the one bound in front of it. Every flooded frame carries a row this device already holds, so
    /// nothing can grow — the charge is spent before the fold either way, which is the point.
    ///
    /// **The bound and its derivation are pinned, and the loop is driven by a literal** (third
    /// review P3 6). Driving the loop from the constant made this cell green on a raised cap, green
    /// on a lowered one, and red only on a deleted guard — the same defect the repair cell's own
    /// `#expect(… == 3)` was added to close, applied to the two cells covering the number this phase
    /// re-derived (32 → 48).
    @Test func oneSendersAdvertisementFramesAreCappedPerSession() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "advert-sender-budget")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        #expect(MeshKeyAdvertisementReceiveBounds.framesPerSenderPerSession == 48,
                "the cap is 48; the literal below is pinned against it")
        #expect(MeshKeyAdvertisementReceiveBounds.framesPerSenderPerSession
                == MeshKeyAgreementAdvertisementSet.capacity
                * MeshKeyAdvertisementReceiveBounds.transitionsPerMember,
                "and it stays capacity × transitionsPerMember, never a chosen number")
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        let held = try #require(rig.nodes[0].manager.keyAdvertisements
            .advertisement(for: rig.nodes[1].fingerprint))
        #expect(capture.count(of: "mesh.keyAgreement.senderBudgetSpent") == 0,
                "the honest exchange must not have spent the bound")

        let payload = MeshKeyAgreementPayload(
            meshID: rig.meshID, advertisements: [held],
            senderFingerprint: rig.nodes[1].fingerprint
        )
        // R2: 49 — the bound plus one, as a literal, so the refusal after it is observed.
        for _ in 0..<49 {
            try rig.deliverMembershipFrame(payload, type: .meshKeyAgreement, sender: 1, receiver: 0)
        }

        #expect(capture.count(of: "mesh.keyAgreement.senderBudgetSpent") >= 1,
                "past the per-sender bound a frame is refused by name, never quietly accepted")
        #expect(rig.advertisementCount(at: 0) == 2, "and the set never grew")
    }

    /// A committed peer the ledger does **not** name can spend none of this device's addressing
    /// budget.
    ///
    /// The budget map is bounded by the roster cap and never evicts, so keyed by *committed* sender
    /// eight non-members could lock every real member out of this device's addressing for the whole
    /// session. Keyed by roster member the cap is true by construction: the refusal happens before
    /// the map, before the decode and before any verification.
    ///
    /// The loop below is driven by the literal 49 for the reason
    /// `oneSendersAdvertisementFramesAreCappedPerSession` states: driven from the constant, this
    /// cell was green whichever way the cap moved (third review P3 6).
    @Test func aNonMemberSenderCannotSpendAnAdvertisementBudget() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "advert-nonmember")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        #expect(MeshKeyAdvertisementReceiveBounds.framesPerSenderPerSession == 48,
                "the cap is 48; the literal below is pinned against it")
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        try await rig.heal(0, 2)
        let row = try #require(rig.nodes[2].manager.keyAdvertisements
            .advertisement(for: rig.nodes[2].fingerprint))

        // Node 2 leaves: its slot at node 0 stays committed, its membership does not.
        try rig.fileDeparture(of: 2, into: 0)
        #expect(rig.nodes[0].manager.membershipVerifier?.roster
                .contains(fingerprint: rig.nodes[2].fingerprint) == false,
                "the precondition: node 2 is committed but no longer a member")
        let stillCommitted = rig.nodes[0].manager.slots
            .contains { $0.fingerprint == rig.nodes[2].fingerprint }
        #expect(stillCommitted, "and the slot is still committed, which is the whole hazard")

        let spentBefore = capture.count(of: "mesh.keyAgreement.senderBudgetSpent")
        let payload = MeshKeyAgreementPayload(
            meshID: rig.meshID, advertisements: [row],
            senderFingerprint: rig.nodes[2].fingerprint
        )
        // R2: 49 — the bound plus one, as a literal; every one must be refused before the map.
        for _ in 0..<49 {
            try rig.deliverMembershipFrame(payload, type: .meshKeyAgreement, sender: 2, receiver: 0)
        }

        #expect(capture.count(of: "mesh.keyAgreement.senderBudgetSpent") == spentBefore,
                "a non-member's frames are refused before the map, so they charge nothing")
    }

    // MARK: Parking, the roster fence and the conflict-mark relief

    /// A parked row whose signer the ledger will **never** name is refused at the bound and leaves
    /// with the session — it never enters the set, and every refusal is named.
    ///
    /// Parking exists for one shape only: a row relayed before this device's ledger names its
    /// signer. A widening arrives in stages, so a row that still fails is re-parked rather than
    /// dropped on the first re-offer. Two of the **three** ends that bound it are under test here —
    /// the share refusal and the session reset; the third, the drop after
    /// `failedRosterMovesPerRow` failed roster moves, is
    /// `aParkedRowIsDroppedAfterThreeFailedWidenings`'.
    @Test func aParkedRowFromANeverAdmittedSignerIsRefusedAtTheBoundAndAtSessionEnd() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "advert-park-drop")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        try await rig.heal(0, 2)
        // A full frame of rows for fingerprints no admission names — the park's whole capacity.
        // R2: bounded by the frame's own clamp.
        let strangers = (0..<MeshKeyAgreementAdvertisementSet.capacity).map {
            MeshKeyAgreementFixtures.unverifiedRow($0 + 700, meshID: rig.meshID)
        }
        let sender = rig.nodes[1].fingerprint
        try rig.deliverMembershipFrame(
            MeshKeyAgreementPayload(
                meshID: rig.meshID, advertisements: strangers, senderFingerprint: sender
            ),
            type: .meshKeyAgreement, sender: 1, receiver: 0
        )
        #expect(rig.nodes[0].manager.parkedKeyAdvertisementCountForTesting
                == MeshKeyAgreementAdvertisementSet.capacity,
                "a row the ledger cannot prove is parked, not folded")
        #expect(rig.advertisementCount(at: 0) == 3,
                "and a parked row is NOT in the set: it has verified nothing")

        // One more, from a seventeenth fingerprint: the park is full and says so.
        try rig.deliverMembershipFrame(
            MeshKeyAgreementPayload(
                meshID: rig.meshID,
                advertisements: [MeshKeyAgreementFixtures.unverifiedRow(999, meshID: rig.meshID)],
                senderFingerprint: sender
            ),
            type: .meshKeyAgreement, sender: 1, receiver: 0
        )
        #expect(capture.count(of: "mesh.keyAgreement.parkFull") == 1, "the bound is named, not silent")
        #expect(rig.nodes[0].manager.parkedKeyAdvertisementCountForTesting
                == MeshKeyAgreementAdvertisementSet.capacity, "and nothing was displaced")

        // A roster move re-offers every parked row through the one fold door; none can verify.
        try rig.fileDeparture(of: 2, into: 0)
        // Scoped to THIS rig's mesh (P9 item 7): the capture is process-global, and the sibling
        // cell below read 4 instead of 3 under full-suite load at the P8 close-out — another rig's
        // fold, counted here. The mesh id is the only thing in the line no sibling rig can mint.
        let reoffers = capture.count(of: "mesh.keyAgreement.parkedReoffered") {
            $0["held"] == rig.meshID.uuidString
        }
        #expect(reoffers == 1, "the re-offer is named, once, in this rig's mesh")
        #expect(rig.advertisementCount(at: 0) == 3, "and still nothing entered the set")

        rig.nodes[0].manager.leaveMesh()
        #expect(rig.nodes[0].manager.parkedKeyAdvertisementCountForTesting == 0,
                "the park dies with the session, like the rest of the addressing state")
    }

    /// Tier B reads a row only for a fingerprint the **current** ledger still names.
    ///
    /// The set is grow-only and a roster is not, so a row folded before a departure stays in the
    /// set. Unobservable through the mint today — destinations ARE the derived roster — which is
    /// why this reads the resolver's tier B directly: item 6's subset target inherits this fence,
    /// and an unpinned fence is one a refactor deletes for free.
    @Test func tierBRefusesARowTheCurrentLedgerNoLongerNames() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "advert-tierb-fence")
        defer { rig.teardown() }
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        try await rig.heal(1, 2)
        rig.commit(0, 1)
        try await rig.settle()
        #expect(rig.advertisementCount(at: 0) == 3, "all three rows must be folded first")

        try rig.fileDeparture(of: 2, into: 0)

        #expect(rig.nodes[0].manager.keyAdvertisements
                .keyAgreementPublicKey(for: rig.nodes[2].fingerprint) != nil,
                "the set still holds the departed member's row: it only grows")
        #expect(rig.nodes[0].manager
                .advertisedKeyAgreementKeyForTesting(for: rig.nodes[2].fingerprint) == nil,
                "but tier B refuses it, because the current ledger no longer names that member")
        #expect(rig.nodes[0].manager
                .advertisedKeyAgreementKeyForTesting(for: rig.nodes[1].fingerprint) != nil,
                "while a member the ledger still names resolves")
    }

    /// A conflict mark is released once the derived roster no longer names its member.
    ///
    /// The bounded relief for a refusal whose blast radius is the whole mint, mesh-wide and durable
    /// across restarts: the mesh's own answer to a misbehaving member — a departure or a removal
    /// vote — has to end the outage rather than leave a mark that outlives the membership. No fence
    /// is given up: a member the roster does not name is never a mint destination anyway.
    @Test func aConflictMarkIsReleasedWhenTheRosterNoLongerNamesItsMember() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "advert-mark-relief")
        defer { rig.teardown() }
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        try await rig.heal(0, 2)
        #expect(rig.advertisementCount(at: 0) == 3, "all three rows must be folded first")

        let second = try SignedKeyAgreementAdvertisement.signedForTesting(
            meshID: rig.meshID, identity: rig.identities[2],
            keyAgreementPublicKey: MeshKeyAgreementFixtures.key(91),
            advertisedAt: MeshRoutedDrainRig.now.addingTimeInterval(60)
        )
        try rig.deliverMembershipFrame(
            MeshKeyAgreementPayload(
                meshID: rig.meshID, advertisements: [second],
                senderFingerprint: rig.nodes[2].fingerprint
            ),
            type: .meshKeyAgreement, sender: 2, receiver: 0
        )
        #expect(rig.nodes[0].manager.keyAdvertisements.isConflicted(rig.nodes[2].fingerprint),
                "two verified keys under one fingerprint mark that member unaddressable")

        try rig.fileDeparture(of: 2, into: 0)

        #expect(!rig.nodes[0].manager.keyAdvertisements.isConflicted(rig.nodes[2].fingerprint),
                "and the mark is released once the roster no longer names the member")
        #expect(rig.nodes[0].manager.keyAdvertisements
                .keyAgreementPublicKey(for: rig.nodes[1].fingerprint) != nil,
                "while the honest member's row is untouched")
    }

    /// One sender cannot fill the park: the share is **per sender**.
    ///
    /// The verifier answers `signerNotAdmitted` before it checks the signature, so a parked row is
    /// attacker-chosen bytes under an attacker-chosen fingerprint — and one frame carries sixteen of
    /// them, which is exactly the whole capacity a flat container had. A misbehaving member could
    /// therefore disable the park for the session with a single frame, and every other peer's
    /// genuine relay was refused with nothing in the transcript to say so.
    @Test func oneSendersParkShareCannotStarveAnother() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "advert-park-share")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        try await rig.heal(0, 2)
        // Node 1 spends its WHOLE share in one frame: rows for fingerprints no admission names.
        // R2: bounded by the share's own constant.
        let strangers = (0..<MeshKeyAdvertisementParkBounds.rowsPerSender).map {
            MeshKeyAgreementFixtures.unverifiedRow($0 + 700, meshID: rig.meshID)
        }
        try rig.deliverMembershipFrame(
            rig.advertisementFrame(strangers, from: 1),
            type: .meshKeyAgreement, sender: 1, receiver: 0
        )
        #expect(rig.parkedCount(at: 0) == MeshKeyAdvertisementParkBounds.rowsPerSender,
                "the share is full of rows the ledger cannot prove")

        // One more from node 1: its share is spent, and the refusal is named.
        try rig.deliverMembershipFrame(
            rig.advertisementFrame(
                [MeshKeyAgreementFixtures.unverifiedRow(999, meshID: rig.meshID)], from: 1
            ),
            type: .meshKeyAgreement, sender: 1, receiver: 0
        )
        #expect(capture.count(of: "mesh.keyAgreement.parkFull") == 1, "the bound is named, not silent")
        #expect(rig.parkedCount(at: 0) == MeshKeyAdvertisementParkBounds.rowsPerSender,
                "and nothing was displaced")

        // Node 2 relays a row for one of the same never-admitted fingerprints. Different sender,
        // different share.
        let relayed = try #require(strangers.first)
        try rig.deliverMembershipFrame(
            rig.advertisementFrame([relayed], from: 2),
            type: .meshKeyAgreement, sender: 2, receiver: 0
        )

        #expect(rig.parkedCount(at: 0) == MeshKeyAdvertisementParkBounds.rowsPerSender + 1,
                "one member's junk cannot spend another member's share")
        #expect(rig.nodes[0].manager.parkedKeyAdvertisementForTesting(
            from: rig.nodes[2].fingerprint, for: relayed.memberFingerprint
        ) == relayed, "and the relay landed in the relaying sender's own share")
        #expect(rig.advertisementCount(at: 0) == 3, "no parked row entered the set")
    }

    /// A parked row a widening cannot prove is dropped after **three** failures, by name.
    ///
    /// Without a drop, a row for a fingerprint no admission will ever name is immortal: it is
    /// re-verified at every widening for the life of the mesh and its slot is never freed. Not one
    /// failure, because a widening arrives in stages — measured, not reasoned: a third device adopts
    /// the moment the chain to its own admission proves, which can be a two-member ledger, with the
    /// record naming the third member arriving through the live insert afterwards.
    ///
    /// The re-offer count is a LITERAL against the pinned constant, for finding 10's reason: driving
    /// the loop from the bound would make this cell unable to fail on a mutation of that bound.
    @Test func aParkedRowIsDroppedAfterThreeFailedWidenings() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "advert-park-drop-after-n")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        #expect(MeshKeyAdvertisementParkBounds.failedRosterMovesPerRow == 3,
                "three failed roster moves; the literals below are pinned against it")
        rig.armKeyAdvertisements()
        try await rig.heal(0, 1)
        try rig.deliverMembershipFrame(
            rig.advertisementFrame(
                [MeshKeyAgreementFixtures.unverifiedRow(700, meshID: rig.meshID)], from: 1
            ),
            type: .meshKeyAgreement, sender: 1, receiver: 0
        )
        #expect(rig.parkedCount(at: 0) == 1, "the row is parked, not folded")

        // R2: two re-offers, a literal — one less than the bound.
        for _ in 0..<2 { rig.reofferParked(at: 0) }
        #expect(rig.parkedCount(at: 0) == 1,
                "a widening arrives in stages, so an early failure is not a drop")
        #expect(capture.count(of: "mesh.keyAgreement.parkDropped") == 0, "nothing dropped yet")

        rig.reofferParked(at: 0)

        #expect(rig.parkedCount(at: 0) == 0, "the third failure drops it")
        #expect(capture.count(of: "mesh.keyAgreement.parkDropped") == 1, "and names the drop")
        // P9 item 7: this exact assertion read 4 under the P8 full-suite run and 3 alone — a
        // sibling rig's fold, counted against this cell. Scoped to this rig's own mesh id it is a
        // claim about the three re-offers driven above, and nothing else in the process.
        let reoffers = capture.count(of: "mesh.keyAgreement.parkedReoffered") {
            $0["held"] == rig.meshID.uuidString
        }
        #expect(reoffers == 3, "every re-offer was through the one fold door")
    }

    /// A row that has failed a roster move yields its slot, and the genuine row then folds.
    ///
    /// The squat this closes: junk parked under member M's fingerprint meant M's genuine relayed row
    /// was **not** parked when it arrived, the non-park was invisible in the transcript, and the
    /// sender's version latch never re-sent it — so the junk was evicted at the next widening and
    /// the real row was simply gone. Earliest arrival still wins while the held row has failed
    /// nothing; once it has failed a roster move, a newcomer that has failed nothing takes the slot,
    /// and a verified row always beats an unverified parked one.
    @Test func aRowThatFailedAWideningYieldsItsSlotAndTheGenuineRowThenFolds() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "advert-park-displace")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        // Node 0's ledger admits only itself and node 1 — the joiner-bootstrap shape, and the only
        // state in which node 2's genuinely signed row is refused `signerNotAdmitted`.
        try rig.reseedLedger(at: 0, admitting: [0, 1])
        rig.armKeyAdvertisement(at: 2)
        rig.link(0, 1)
        let genuine = try #require(rig.nodes[2].manager.keyAdvertisements
            .advertisement(for: rig.nodes[2].fingerprint))
        let junk = SignedKeyAgreementAdvertisement(
            meshID: rig.meshID,
            memberFingerprint: rig.nodes[2].fingerprint,
            keyAgreementPublicKey: MeshKeyAgreementFixtures.key(77),
            advertisedAt: MeshRoutedDrainRig.now,
            signature: Data(repeating: 0xAB, count: MeshMembershipEventFormat.signatureByteCount)
        )
        try rig.deliverMembershipFrame(
            rig.advertisementFrame([junk], from: 1),
            type: .meshKeyAgreement, sender: 1, receiver: 0
        )
        try rig.deliverMembershipFrame(
            rig.advertisementFrame([genuine], from: 1),
            type: .meshKeyAgreement, sender: 1, receiver: 0
        )
        #expect(rig.nodes[0].manager.parkedKeyAdvertisementForTesting(
            from: rig.nodes[1].fingerprint, for: rig.nodes[2].fingerprint
        ) == junk, "earliest arrival keeps the slot while it has failed nothing")
        #expect(capture.count(of: "mesh.keyAgreement.parkCollision") == 1,
                "and the collision the refusal used to hide is named")

        // One widening the junk cannot survive proving, then the genuine row again.
        rig.reofferParked(at: 0)
        try rig.deliverMembershipFrame(
            rig.advertisementFrame([genuine], from: 1),
            type: .meshKeyAgreement, sender: 1, receiver: 0
        )
        #expect(rig.nodes[0].manager.parkedKeyAdvertisementForTesting(
            from: rig.nodes[1].fingerprint, for: rig.nodes[2].fingerprint
        ) == genuine, "a row that failed a roster move yields to one that has not")
        #expect(capture.count(of: "mesh.keyAgreement.parkCollision") == 2, "named both times")

        // The real widening: node 2's admission reaches node 0.
        try rig.reseedLedger(at: 0, admitting: [0, 1, 2])
        rig.reofferParked(at: 0)

        #expect(rig.nodes[0].manager.advertisedKeyAgreementKeyForTesting(
            for: rig.nodes[2].fingerprint
        ) == rig.identities[2].localKeyAgreementPublicKey,
                "the genuine row folded, so node 2 is addressable")
        #expect(rig.parkedCount(at: 0) == 0, "and the park is empty")
    }

    /// A re-offer the store refused rolls the park back **with** the set.
    ///
    /// `commitKeyAdvertisementFold` already rolls the set back — durable before it counts — but the
    /// park had been emptied before the fold, so a row that had become provable and whose save
    /// failed was in neither container. Nothing re-sends it: the sender's latch is spent at that
    /// (peer, version) and no door fires on a fold.
    @Test func aReOfferTheStoreRefusedRollsBackTheParkWithTheSet() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "advert-park-rollback")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        try rig.reseedLedger(at: 0, admitting: [0, 1])
        rig.armKeyAdvertisement(at: 2)
        rig.link(0, 1)
        let genuine = try #require(rig.nodes[2].manager.keyAdvertisements
            .advertisement(for: rig.nodes[2].fingerprint))
        try rig.deliverMembershipFrame(
            rig.advertisementFrame([genuine], from: 1),
            type: .meshKeyAgreement, sender: 1, receiver: 0
        )
        #expect(rig.parkedCount(at: 0) == 1, "parked: node 0's ledger cannot prove node 2 yet")
        try rig.reseedLedger(at: 0, admitting: [0, 1, 2])

        rig.reofferParked(at: 0, binding: .unavailable)

        #expect(rig.advertisementCount(at: 0) == 0, "the set is rolled back to what is on disk")
        #expect(rig.parkedCount(at: 0) == 1,
                "and the park with it: a row in neither container is a row nothing re-sends")
        #expect(capture.count(of: "mesh.keyAgreement.notDurable") == 1, "the set's rollback is named")
        #expect(capture.count(of: "mesh.keyAgreement.parkRolledBack") == 1, "and the park's")

        rig.reofferParked(at: 0)

        #expect(rig.advertisementCount(at: 0) == 1, "and once the store takes it, the row lands")
        #expect(rig.parkedCount(at: 0) == 0, "leaving the park empty")
    }
}
