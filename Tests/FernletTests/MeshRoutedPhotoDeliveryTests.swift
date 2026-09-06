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

    /// Pushes one node's access gate under the pinned install binding, which is the re-entry's edge.
    @discardableResult
    func pushGate(_ gate: MeshRoutedAccessGate, at node: Int) -> MeshRoutedReentryReport? {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            nodes[node].manager.applyRoutedAccessGate(gate, now: MeshRoutedDrainRig.now)
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
        #expect(rig.nodes[0].manager.meshPhotos.count == 1, "and the echo is on the sender's own wall")
    }

    /// **R-17.** A capture with no destinations at all reaches the sender's own wall, silently.
    ///
    /// This is the premise the ten legacy send-side cells rest on: both retired arms of `addPhoto`
    /// cached before any send and incremented the session counter whichever way the send went, so a
    /// solo member has always had a wall entry and no error. Conditioning the echo on a successful
    /// mint would break every session that has no membership ledger yet — a solo host, and the whole
    /// proximity-join pairwise phase.
    @Test func aCaptureWithNoDestinationsStillReachesTheOwnWallSilently() throws {
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
        var absent = false
        if case .absent = MeshRoutedStore(scope: store.meshRoutedStorage).load() { absent = true }
        #expect(absent, "nothing was staged, because there was nothing to stage for")
    }

    /// **R-12.** A destination with no handshake-verified key refuses the whole mint, visibly.
    @Test func aMintWithAnUnverifiedDestinationRefusesVisibly() throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-unverified")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        rig.capturePhoto(at: 0)

        #expect(rig.nodes[0].manager.meshError != nil, "a mint that failed must reach the user")
        #expect(rig.routedIndex(rig.nodes[0]) == nil, "nothing was staged")
        #expect(capture.values(of: "mesh.routedShare.refused", key: "reason")
                == ["destinationNotAddressable"],
                "the refusal is named once, by its frozen token")
        #expect(rig.nodes[0].manager.meshPhotos.count == 1,
                "the echo still runs: only the transport is conditional")
    }

    /// **R-16.** The ledger-scoped/session-scoped divergence, asserted rather than met on device.
    ///
    /// Destinations come from the DERIVED ROSTER, which is durable; the wrap keys come from live
    /// slots and the memory-only session roster, which are not. A process restart, an idle-lapse
    /// resume or a rejoin therefore restores the ledger and not the keys, and the mint refuses by
    /// name until a signed key-advertisement frame exists (D-13.22, handed to the owner / P6).
    @Test func aMintAfterASessionResetRefusesVisiblyWithTheLedgerIntact() throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "photo-resumed")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.nodes[0].manager.clearSessionRoster()

        rig.capturePhoto(at: 0)

        #expect(rig.nodes[0].manager.membershipVerifier?.roster.memberCount == 2,
                "the precondition: the LEDGER survived the reset")
        #expect(rig.routedIndex(rig.nodes[0]) == nil, "nothing was staged")
        #expect(rig.nodes[0].manager.meshError != nil, "and the outage is visible, not silent")
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
        #expect(rig.nodes[0].manager.meshError != nil, "and it is visible, never silent")
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
        #expect(capture.count(of: "mesh.merge.routedQuiescentUnbound") == 0,
                "nothing overwrote the advertisement the answer quotes")
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
    /// `.tempMessage` and `.heart` are registered, admitted, custodied and complete today with **no**
    /// dispatch arm behind them — P6 lands those. They are therefore permanently "awaiting local
    /// projection", and `MeshRoutedIndex.items` is ordered by ``MeshRoutedItemKey``, i.e. by origin
    /// fingerprint first: an origin whose fingerprint sorts low can fill one pass's whole item
    /// allowance with items nobody can finish, and every photo behind them waits until expiry. The
    /// remedy is R-18's, one layer out — the list is narrowed to what this build can finish before
    /// the allowance is spent.
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
