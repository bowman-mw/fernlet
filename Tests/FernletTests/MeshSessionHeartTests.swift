// MeshSessionHeartTests.swift
// FernletTests
//
// Network migration P6 item 6 (plan §12): the in-session heart SENDER, on the routed store.
//
// This file used to cover the legacy `.friendHeart` mesh transport — a sealed envelope written to a
// live committed slot — and its whole receive half went with that transport (the handler, the
// per-slot send and the slot-keyed test seam are pinned at zero by
// `MeshRoutedDrainTests.theRetiredMeshHeartTransportIsGone`). What replaced the receive half is the
// ACK CEREMONY, which is not a handler at all and is covered in `MeshRoutedHeartTests.swift`
// against a real two-node founding rig. What is left here is the sender: five gates, the three
// origination lines, consume-on-stage, and the in-flight claim.
//
// Two fixture facts this file rests on:
//
// - **The send needs a real mesh.** `originateRoutedItem`'s first guard is `currentMesh` plus a
//   membership ledger, so a cell with slots and no founding answers `.skipped(.noDestinations)` and
//   proves nothing. Every send cell drives `MeshFoundingRig`, where the founding is the REAL commit
//   path and the key advertisements are minted by the production doors — the trap item 1's ledger
//   row names ("the convergence rig must arm the advertisements or the addressing half is green
//   over nothing"), applied here.
// - **Consume-on-stage moved the cooldown's arming.** `.staged` arms it, so a second tap in the
//   same turn is refused by the COOLDOWN rather than by the in-flight claim, and a refused first
//   tap leaves the cooldown clear. Both directions are asserted, because the old assertion in this
//   file ("the refusal burns no cooldown") inverts under the new rule for a STAGED send.

@testable import ProximityKit
import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

@Suite(.serialized) @MainActor
struct MeshSessionHeartTests {

    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    private func randomKey() -> Data { Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }) }

    /// A fresh, temp-file-backed ledger so assertions are isolated from the shared on-disk
    /// `HeartLedger.json` and from the presence path's ledger.
    private func isolatedLedger() -> ProximityHeartLedger {
        ProximityHeartLedger(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("mesh-heart-tests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("HeartLedger.json"),
            now: { self.day })
    }

    private func friendRecord(fingerprint: String, name: String) -> ProximityTrustedPeerRecord {
        ProximityTrustedPeerRecord(
            displayName: name,
            fingerprint: fingerprint,
            signingPublicKey: randomKey(),
            keyAgreementPublicKey: Data([1]),
            mode: .friend,
            firstAcceptedAt: day,
            lastSeenAt: day
        )
    }

    /// A founded pair with hearts on at both ends and a ledger at the sender — the state every send
    /// cell needs before `sendSessionHeart` can do anything but skip.
    private func foundedPair(_ label: String) async throws -> (rig: MeshFoundingRig, ledger: ProximityHeartLedger) {
        let rig = try MeshFoundingRig.build(2, label: label)
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle()
        let ledger = isolatedLedger()
        rig.nodes[0].manager.heartLedger = ledger
        rig.nodes[1].manager.heartLedger = isolatedLedger()
        rig.nodes[0].store.setAllowNearbyHearts(true)
        rig.nodes[1].store.setAllowNearbyHearts(true)
        return (rig, ledger)
    }

    // MARK: - The three origination lines

    /// **The item's headline.** A heart to an admitted member is minted with EXACTLY ONE
    /// destination, staged durably, and consumed on the stage — with no live-slot requirement
    /// anywhere in the path.
    @Test func aHeartMintsOneDestinationAndIsConsumedOnStage() async throws {
        let (rig, ledger) = try await foundedPair("heart-send")
        defer { rig.teardown() }
        let recipient = rig.nodes[1].fingerprint
        try #require(rig.roster(0).contains(recipient), "the pair must have founded with a ledger")
        var outcomes: [MeshRoutedOriginationOutcome] = []
        var closeness: [String] = []
        rig.nodes[0].manager.onHeartSendForTesting = { outcomes.append($0) }
        rig.nodes[0].manager.onHeartSent = { closeness.append($0) }

        rig.sendHeart(from: 0, to: friendRecord(fingerprint: recipient, name: "Robin"))

        let outcome = try #require(outcomes.first, "the mint seam must fire exactly once")
        #expect(outcomes.count == 1)
        guard case .staged(let key, _) = outcome else {
            Issue.record("the heart must stage: \(outcome)")
            return
        }
        let record = try #require(rig.routedIndex(0)?.record(for: key))
        let manifest = try #require(record.manifest)
        #expect(manifest.destinations == [recipient],
                "a single-recipient mint names its recipient and nobody else")
        #expect(manifest.itemID == key.itemID)
        #expect(manifest.typeToken == MeshRoutedTypeToken.heart)
        #expect(closeness == [recipient], "the stage feeds closeness, once")
        #expect(!ledger.canSendHeart(to: recipient), "and arms the cooldown — consume-on-stage")
        #expect(rig.nodes[0].manager.sessionHeartState == .sent(recipientName: "Robin"))
    }

    /// The body's id IS the gift id, and the gift id IS the routed item id. One `UUID`, three roles,
    /// frozen for this token — and the sealed body carries it too, so a receiver can enforce it.
    @Test func theBodyIsHeaderOnlyAndItsIDIsTheGiftID() async throws {
        let (rig, _) = try await foundedPair("heart-body-id")
        defer { rig.teardown() }
        var outcomes: [MeshRoutedOriginationOutcome] = []
        rig.nodes[0].manager.onHeartSendForTesting = { outcomes.append($0) }

        rig.sendHeart(from: 0, to: friendRecord(fingerprint: rig.nodes[1].fingerprint, name: "Robin"))

        guard case .staged(let key, let chunkCount) = try #require(outcomes.first) else {
            Issue.record("the heart must stage")
            return
        }
        #expect(chunkCount == 1, "a header-only body is one chunk")
        let record = try #require(rig.routedIndex(0)?.record(for: key))
        let manifest = try #require(record.manifest)
        #expect(manifest.size <= UInt64(MeshRoutedHeartBody.maxSealedBlobByteCount),
                "a minted heart must fit the cap its own row declares")
    }

    // MARK: - The five gates

    @Test func theOptOutRefusesTheSendWithItsOwnCause() async throws {
        let (rig, ledger) = try await foundedPair("heart-optout")
        defer { rig.teardown() }
        rig.nodes[0].store.setAllowNearbyHearts(false)
        var sends = 0
        rig.nodes[0].manager.onHeartSendForTesting = { _ in sends += 1 }
        let recipient = rig.nodes[1].fingerprint

        rig.sendHeart(from: 0, to: friendRecord(fingerprint: recipient, name: "Robin"))

        #expect(sends == 0, "hearts-off refuses before the mint")
        #expect(rig.nodes[0].manager.sessionHeartState
                == .failed(.heartsOff, recipientName: "Robin"))
        #expect(ledger.canSendHeart(to: recipient), "a refusal burns no cooldown")
    }

    /// The §2.1 bug fix: `canSendHeart` is fail-closed and answers false for an UNLOADED ledger too,
    /// where the cooldown sentence is a lie — nothing was sent. The app already distinguished the
    /// two for its accessibility label; the send did not.
    @Test func anUnloadedLedgerRefusesWithItsOwnCause() async throws {
        let (rig, _) = try await foundedPair("heart-unloaded")
        defer { rig.teardown() }
        // A file that EXISTS and cannot be read — the `.unloaded` sidecar state. A merely absent
        // file loads as an empty ledger, which is a different fact and would make this cell vacuous
        // (`HeartDropTests.unreadableLedgerFailsClosedAndRecovers` is the same construction).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heart-unreadable-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("HeartLedger.json")
        let seeder = ProximityHeartLedger(fileURL: url, now: { self.day })
        seeder.recordHeartSent(to: "someone-else")
        let unreadable = ProximityHeartLedger(
            fileURL: url, now: { self.day },
            readData: { _ in throw CocoaError(.fileReadNoPermission) }
        )
        try #require(!unreadable.isLoaded, "the precondition: this ledger cannot be read")
        rig.nodes[0].manager.heartLedger = unreadable
        var sends = 0
        rig.nodes[0].manager.onHeartSendForTesting = { _ in sends += 1 }

        rig.sendHeart(from: 0, to: friendRecord(fingerprint: rig.nodes[1].fingerprint, name: "Robin"))

        #expect(sends == 0)
        #expect(rig.nodes[0].manager.sessionHeartState
                == .failed(.ledgerUnavailable, recipientName: "Robin"),
                "an unloaded ledger is not a cooldown — nothing was sent")
    }

    @Test func theCooldownRefusesTheSend() async throws {
        let (rig, ledger) = try await foundedPair("heart-cooldown")
        defer { rig.teardown() }
        let recipient = rig.nodes[1].fingerprint
        ledger.recordHeartSent(to: recipient)
        var sends = 0
        rig.nodes[0].manager.onHeartSendForTesting = { _ in sends += 1 }

        rig.sendHeart(from: 0, to: friendRecord(fingerprint: recipient, name: "Robin"))

        #expect(sends == 0, "a heart inside the 5-minute cooldown is not re-minted")
        #expect(rig.nodes[0].manager.sessionHeartState
                == .failed(.cooldown, recipientName: "Robin"))
    }

    @Test func aBlockedOrRevokedRecordIsRefusedSilently() async throws {
        let (rig, _) = try await foundedPair("heart-revoked")
        defer { rig.teardown() }
        var sends = 0
        rig.nodes[0].manager.onHeartSendForTesting = { _ in sends += 1 }
        var revoked = friendRecord(fingerprint: rig.nodes[1].fingerprint, name: "Robin")
        revoked.revokedAt = day

        rig.sendHeart(from: 0, to: revoked)

        #expect(sends == 0)
        #expect(rig.nodes[0].manager.sessionHeartState == .idle,
                "silent: the affordance is not drawn for such a record, so reaching here is a caller bug")
    }

    /// **Re-aimed from `aSecondTapDuringAnInFlightSendIsRefusedNotDuplicated`.** The claim changed
    /// mechanism: the mint is synchronous, so the second tap sees a RELEASED claim and an ARMED
    /// cooldown. Asserting the cause token is what stops this staying green while testing something
    /// else.
    @Test func aSecondTapIsRefusedByTheCooldownTheStageArmed() async throws {
        let (rig, ledger) = try await foundedPair("heart-second-tap")
        defer { rig.teardown() }
        let recipient = rig.nodes[1].fingerprint
        var sends = 0
        rig.nodes[0].manager.onHeartSendForTesting = { _ in sends += 1 }
        let friend = friendRecord(fingerprint: recipient, name: "Robin")

        rig.sendHeart(from: 0, to: friend)
        #expect(sends == 1, "the precondition: the first tap really staged")
        #expect(!ledger.canSendHeart(to: recipient), "and really armed the cooldown")
        rig.sendHeart(from: 0, to: friend)

        #expect(sends == 1, "only one heart is minted for two taps")
        #expect(rig.nodes[0].manager.sessionHeartState
                == .failed(.cooldown, recipientName: "Robin"),
                "and the second is refused by the cooldown the STAGE armed, not by the in-flight claim")
    }

    /// The in-flight claim must not outlive the session that took it, or it would refuse the FIRST
    /// heart of the next one. Unchanged in substance; the claim is now a fence over an empty window.
    @Test func sessionEndClearsAStrandedInFlightHeartClaim() async throws {
        let (rig, _) = try await foundedPair("heart-stranded")
        defer { rig.teardown() }
        let manager = rig.nodes[0].manager
        manager.claimSessionHeartForTesting(rig.nodes[1].fingerprint)
        #expect(manager.holdsSessionHeartClaimForTesting(rig.nodes[1].fingerprint),
                "the precondition: the claim is held")

        manager.leaveMesh()

        #expect(!manager.holdsSessionHeartClaimForTesting(rig.nodes[1].fingerprint),
                "a fresh session's first heart must not be refused by a stranded claim")
    }

    /// A member the derived roster no longer holds is a `.noDestinations` SKIP at the mint, and the
    /// heart says so rather than staying silent — the one place this row differs from a photo's.
    @Test func aHeartToADepartedMemberSaysTheyLeft() async throws {
        let (rig, ledger) = try await foundedPair("heart-departed")
        defer { rig.teardown() }
        var sends = 0
        rig.nodes[0].manager.onHeartSendForTesting = { _ in sends += 1 }
        let stranger = "fp-\(UUID().uuidString)"
        try #require(!rig.roster(0).contains(stranger))

        rig.sendHeart(from: 0, to: friendRecord(fingerprint: stranger, name: "Robin"))

        #expect(sends == 1, "the mint was attempted — the seam fires on every outcome")
        #expect(rig.nodes[0].manager.sessionHeartState
                == .failed(.recipientLeft, recipientName: "Robin"))
        #expect(ledger.canSendHeart(to: stranger), "and a skip burns no cooldown")
    }

    /// Every origination outcome maps to a cause, exhaustively — the switch is the wall, this is the
    /// statement that the vocabulary has no gap the compiler cannot see.
    @Test func everyHeartFailureCauseIsAFrozenToken() {
        #expect(MeshNetworkManager.SessionHeartFailure.allCases.map(\.rawValue) == [
            "heartsOff", "ledgerUnavailable", "cooldown", "alreadySending", "recipientLeft",
            "notReachableYet", "identityUnconfirmed", "couldNotSend", "storageUnreachable",
            "holdingAllItCan"
        ], "audit vocabulary; a rename breaks every reader of mesh.routedHeart.sendFailed")
    }

    // MARK: - Reachability, and the presence ordering

    /// `canSendSessionHeart` answers "is this a member this device can address", not "are they
    /// linked" — and `hasLiveHeartSlot` is the separate question the app's ordering asks first.
    @Test func addressabilityAndLivenessAreTwoQuestions() async throws {
        let (rig, _) = try await foundedPair("heart-reach")
        defer { rig.teardown() }
        let manager = rig.nodes[0].manager
        let recipient = rig.nodes[1].fingerprint

        #expect(manager.canSendSessionHeart(toFingerprint: recipient),
                "an admitted member with a resolvable key is addressable")
        #expect(!manager.canSendSessionHeart(toFingerprint: rig.nodes[0].fingerprint),
                "this device is never addressable for its own heart")
        #expect(!manager.canSendSessionHeart(toFingerprint: "fp-\(UUID().uuidString)"),
                "and a stranger is not in the roster")
        #expect(manager.hasLiveHeartSlot(forFingerprint: recipient),
                "the pair is linked, so the liveness question is true too")
    }

    /// The app's three-way order, as an exhaustive table over the three seams the view reads.
    ///
    /// It is a PRODUCT rule — a custodied heart is strictly worse than a delivered one — and since
    /// the item 6 fix review (P3-6) it is a BEHAVIOUR pin rather than three literal substrings of
    /// `DisposableCameraView.swift`: the old form red on a rename and was blind to a reordering that
    /// kept the same three lines. All eight combinations, so there is no arm the table does not name.
    ///
    /// **The `enabled` column is P6 item 9's SET A (the fix review's P3-e).** The button's own
    /// `reachable` was `meshLinked || presenceReachable || meshAddressable`, which disagrees with
    /// the transport on exactly row 4: a live hearts slot facing a peer this device cannot address
    /// is not a transport, but it made the disjunction true — so the affordance was enabled over a
    /// switch with nothing to run, and the tap fired a haptic and did nothing. Enablement is now the
    /// transport's own answer, and this column is what says the two cannot drift apart again.
    @Test func thePresenceOrderPrefersADeliveredHeartOverACustodiedOne() throws {
        typealias Transport = DisposableCameraView.SessionHeartTransport
        let table: [(linked: Bool, presence: Bool, addressable: Bool, want: Transport, enabled: Bool)] = [
            (true, true, true, .mesh, true),      // linked and addressable: delivered now, over a slot
            (true, false, true, .mesh, true),
            (true, true, false, .presence, true), // a slot we cannot address is not a transport
            (true, false, false, .unavailable, false), // …and with no presence it is no transport at all
            (false, true, true, .presence, true), // THE ordering: presence delivers now, routed custodies
            (false, true, false, .presence, true),
            (false, false, true, .mesh, true),    // the star case — staged and custodied, the unlock
            (false, false, false, .unavailable, false)
        ]
        #expect(table.count == 8, "every combination of the three seams is named")
        let disagreements = table.filter {
            ($0.linked || $0.presence || $0.addressable) != $0.enabled
        }
        #expect(disagreements.count == 1,
                "row 4 is the one shape where the old disjunction and the transport disagree")
        // R2: bounded by the table.
        for row in table {
            let transport = DisposableCameraView.sessionHeartTransport(
                meshLinked: row.linked, presenceReachable: row.presence,
                meshAddressable: row.addressable
            )
            #expect(transport == row.want,
                    "the heart tap's transport order is a product rule, not an accident")
            #expect((transport != .unavailable) == row.enabled,
                    "the affordance is enabled exactly where a transport can carry the tap")
        }
        // And the button really consults it, rather than re-deciding in the body — both halves: the
        // transport itself, and the enablement derived from it rather than from the three seams.
        let camera = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/DisposableCameraView.swift")
        )
        #expect(camera.contains("let transport = Self.sessionHeartTransport("),
                "the order is read from the pinned function, not re-derived in the view body")
        #expect(camera.contains("let reachable = transport != .unavailable"),
                "and enablement is the transport's answer, not a disjunction that disagrees on row 4")
    }

    /// **A heart addressed to this device is a CALLER bug with its own frozen audit token** — the
    /// fix review's P3-4. The refusal was right and the log named a different fact
    /// (`destinationSemanticsMismatch`, which is the audience-vs-column question), so the one
    /// condition `MeshDeliveryRefusal.recipientIsSelf` exists to distinguish was indistinguishable
    /// in the log. The user-facing refusal is deliberately unchanged.
    @Test func aHeartAddressedToThisDeviceIsAuditedAsSuch() async throws {
        let (rig, _) = try await foundedPair("heart-self")
        defer { rig.teardown() }
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let me = rig.nodes[0].fingerprint

        rig.sendHeart(from: 0, to: friendRecord(fingerprint: me, name: "Robin"))

        #expect(capture.count(of: "mesh.routedShare.recipientIsSelf") == 1,
                "the refusal names the fact it actually found")
        #expect(capture.count(of: "mesh.routedShare.destinationSemanticsMismatch") == 0,
                "and no longer borrows the audience-vs-column token")
        #expect(rig.nodes[0].manager.sessionHeartState
                == .failed(.couldNotSend, recipientName: "Robin"),
                "while what the user is told is unchanged — there is nothing here they can act on")
    }

    /// **An ABSENT ledger is refused exactly like an unloaded one** — the fix review's P3-5.
    ///
    /// `heartLedger?.isLoaded != false` and `heartLedger?.canSendHeart(to:) ?? true` both passed a
    /// manager with no ledger wired, so it staged a heart with no cooldown at all while the
    /// function's own doc claimed every gate the legacy sealed send had is kept. Production always
    /// wires one, so this is the guard that makes the doc true rather than a live defect.
    @Test func anAbsentLedgerRefusesTheSendFailClosed() async throws {
        let (rig, _) = try await foundedPair("heart-no-ledger")
        defer { rig.teardown() }
        rig.nodes[0].manager.heartLedger = nil
        var sends = 0
        rig.nodes[0].manager.onHeartSendForTesting = { _ in sends += 1 }

        rig.sendHeart(from: 0, to: friendRecord(fingerprint: rig.nodes[1].fingerprint, name: "Robin"))

        #expect(sends == 0, "no ledger means no cooldown to check, so nothing is minted")
        #expect(rig.nodes[0].manager.sessionHeartState
                == .failed(.ledgerUnavailable, recipientName: "Robin"),
                "and the cause is the honest one, not a cooldown that was never armed")
    }

    // MARK: - Capability advertisement (unchanged by the retirement)

    /// `localCapabilities()` still gates `.hearts` on the opt-out. It is now an
    /// **advertised-but-unread** capability on the send side — the routed sender consults the roster
    /// and the key resolver, not a slot's capabilities — and it is kept because the app's ordering
    /// reads it through `hasLiveHeartSlot` and because a peer's build advertises it too.
    @Test func localCapabilitiesAdvertiseHearts() {
        let store = makeTestStore()
        let manager = store.meshNetworkManager

        store.setAllowNearbyHearts(true)
        #expect(manager.localCapabilities().contains(ProximityCapability.hearts.rawValue))

        store.setAllowNearbyHearts(false)
        #expect(!manager.localCapabilities().contains(ProximityCapability.hearts.rawValue))
        #expect(manager.localCapabilities().contains(ProximityCapability.photos.rawValue))
    }
}
