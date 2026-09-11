// MeshRoutedTextDeliveryTests.swift
// FernletTests
//
// Network migration P6 item 4 (plan §12): temporary text END TO END on the routed store — the
// sender's outcome table, and a message that reaches the other side's TRANSCRIPT.
//
// Every cell drives `MeshFoundingRig`, i.e. `startJoin`-mode managers with **no seeded mesh and no
// seeded ledger**, through the real dwell commit, the founding, the auto-granted admission, the
// digest re-gossip, `sendTempMessage` → `originateRoutedItem` → the drain → the recipient's access
// gate → the recipient's transcript. That matters more here than anywhere: the P6 ledger records
// that the app's proximity-join path had never exercised the routed content path at all before item
// 2, so these are the first end-to-end text-over-routed exercises in the project.
//
// Two green-for-the-wrong-reason guards are structural. A delivery cell asserts at the RECIPIENT
// (its `sessionMessages`), which is the only place that separates a delivery from a successful
// mint; and the sender cells assert the OUTCOME, because `.skipped(.noDestinations)` and a staged
// mint are indistinguishable from a silent return. The retired legacy handler can no longer make
// any of them pass: `MeshRoutedDrainTests.theRetiredTextTransportIsGone` pins it at zero.

@testable import ProximityKit
import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

// MARK: - The rig's text half

extension MeshFoundingRig {

    /// Opens the 13+ chat gate at every node. The rig builds managers directly, so
    /// `chatAllowedProvider` is nil — i.e. **fail-closed** — until a cell says otherwise, which is
    /// itself the shape `aMessageBelowTheRecipientsAgeGateIsNotProjected` relies on.
    func allowChatEverywhere() {
        // R2: bounded by the rig's own node count.
        for node in nodes { node.manager.chatAllowedProvider = { true } }
    }

    /// Sends one message at `node` through the real public API and returns what the send decided.
    func sendText(at node: Int, _ text: String) -> MeshTextSendOutcome {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            nodes[node].manager.sendTempMessage(text)
        }
    }

    /// Closes one node's routed access gate, so an item completes into custody unprojected.
    func closeGate(at node: Int) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = nodes[node].manager.applyRoutedAccessGate(
                MeshRoutedAccessGate(
                    protectedDataAvailable: false, appIsForeground: true, duressActive: false
                ),
                now: Date()
            )
        }
    }

    /// One node's visible transcript, oldest-first in §10.3's total order.
    func transcript(at node: Int) -> [String] {
        nodes[node].manager.sessionMessages.messages.map(\.text)
    }

    /// The rows one node shows, for the attribution assertions.
    func transcriptRows(at node: Int) -> [SessionMessageStore.Message] {
        nodes[node].manager.sessionMessages.messages
    }

    /// Brings a founded, mutually admitted, chat-enabled pair up with both access gates open — the
    /// precondition every delivery cell shares.
    func settleChattingPair() async throws {
        allowChatEverywhere()
        openGate(at: 0)
        openGate(at: 1)
        link(0, 1)
        commit(0, 1)
        commit(1, 0)
        try await settle(until: { self.roster(0).count == 2 && self.roster(1).count == 2 })
        #expect(roster(0).count == 2 && roster(1).count == 2,
                "the destination set the mint needs is the derived roster, and it must be 2 here")
    }
}

// MARK: - Sender

@Suite(.serialized) @MainActor
struct MeshRoutedTextSenderTests {

    /// The outcome table, on the shape that actually produces it: the FOUNDING WINDOW.
    ///
    /// Founding is synchronous at the first commit and leaves a roster of ONE, so
    /// `MeshDeliveryTarget.destinationCount` is 0 until the second admission lands — a real second
    /// or two on UWB and longer on the tap-to-tap fallback. For a photo that is correct and silent
    /// (the echo is on the user's own wall either way). For a message it is a message that reached
    /// nobody forever: destinations are frozen at the mint and there is no offline queue.
    ///
    /// The pair of cases is the non-vacuity — `.noDestinations` in the window, `.staged` after the
    /// admission — because either one alone passes against a sender that always answers it.
    @Test func aMessageSentInTheFoundingWindowSaysNoRecipientsAndOneSentAfterItStages() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-window")
        defer { rig.teardown() }
        rig.allowChatEverywhere()
        var outcomes: [MeshTextSendOutcome] = []
        rig.nodes[0].manager.onTextSendForTesting = { outcomes.append($0) }
        rig.link(0, 1)
        rig.commit(0, 1)
        #expect(rig.roster(0).count == 1, "the founder's own roster is ONE until the grant lands")

        #expect(rig.sendText(at: 0, "too early") == .noDestinations)
        #expect(outcomes == [.noDestinations], "reported once, and not silently")
        #expect(rig.transcript(at: 0).isEmpty, """
            and NOT echoed: the transcript has no failed-row state, so an echo here is a claim the \
            user cannot dismiss and that can never come true
            """)
        #expect(rig.stagedOwnItemID(at: 0) == nil, "nothing was minted either")

        rig.commit(1, 0)
        try await rig.settle(until: { rig.roster(0).count == 2 })
        #expect(rig.sendText(at: 0, "now then") == .staged)
        #expect(rig.transcript(at: 0) == ["now then"], "the echo lands ONLY on a staged mint")
        #expect(rig.stagedOwnItemID(at: 0) != nil, "and the item is in this device's routed store")
    }

    /// The two refusals that never reach the mint, and the one that does. `.ageGated` and `.empty`
    /// are asserted against a fully founded pair, so nothing about them can be an accident of
    /// having no destinations.
    @Test func theSendOutcomeTableIsTotalOverTheGateAndTheSanitizer() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-table")
        defer { rig.teardown() }
        try await rig.settleChattingPair()
        var outcomes: [MeshTextSendOutcome] = []
        rig.nodes[0].manager.onTextSendForTesting = { outcomes.append($0) }

        #expect(rig.sendText(at: 0, "   \n\t ") == .empty)
        #expect(rig.transcript(at: 0).isEmpty)

        rig.nodes[0].manager.chatAllowedProvider = { false }
        #expect(rig.sendText(at: 0, "hello") == .ageGated)
        #expect(rig.transcript(at: 0).isEmpty, "not even the local echo below the gate")

        rig.nodes[0].manager.chatAllowedProvider = { true }
        #expect(rig.sendText(at: 0, "hello") == .staged)
        #expect(outcomes == [.empty, .ageGated, .staged],
                "every outcome is reported exactly once, in order, through the one seam")
    }

    /// The local echo carries the MINTED id and the BOUNDED text, so what the sender shows and what
    /// the roster receives are the same bytes.
    @Test func theLocalEchoCarriesTheMintedItemIDAndTheBoundedText() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-echo")
        defer { rig.teardown() }
        try await rig.settleChattingPair()

        #expect(rig.sendText(at: 0, "  spaced   out  ") == .staged)
        let itemID = try #require(rig.stagedOwnItemID(at: 0))
        let row = try #require(rig.transcriptRows(at: 0).first)
        #expect(row.id == itemID, """
            the echo's id IS the routed item id — `SessionMessageStore` dedups on it, so a \
            different id would let this device's own message project a second time
            """)
        #expect(row.text == "spaced out", "and it is the sanitized text, not the raw draft")
        #expect(row.isOutgoing)
    }
}

// MARK: - Delivery and projection

@Suite(.serialized) @MainActor
struct MeshRoutedTextDeliveryTests {

    /// The headline: a pair's messages are DELIVERED both ways and PROJECTED into both transcripts,
    /// in §10.3's order, with two members interleaved.
    ///
    /// The order is asserted at BOTH ends, and the claims are deliberately interleaved so append
    /// order is not the intended order at either one — a backlog drains in index order,
    /// `(originFingerprint, itemID)`, so on the routed path arrival order is not send order.
    @Test func aPairsMessagesAreDeliveredBothWaysAndOrderedAtBothEnds() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-pair")
        defer { rig.teardown() }
        try await rig.settleChattingPair()

        #expect(rig.sendText(at: 0, "A1") == .staged)
        #expect(rig.sendText(at: 1, "B1") == .staged)
        #expect(rig.sendText(at: 0, "A2") == .staged)
        #expect(rig.sendText(at: 1, "B2") == .staged)

        try await rig.settle(until: {
            rig.transcript(at: 0).count == 4 && rig.transcript(at: 1).count == 4
        })
        #expect(rig.transcript(at: 0) == ["A1", "B1", "A2", "B2"], """
            the founder's transcript holds both members' messages in SEND order — delivered, not \
            merely minted, and not grouped by sender the way index order would give
            """)
        #expect(rig.transcript(at: 1) == ["A1", "B1", "A2", "B2"],
                "and the joiner's transcript is the same total order")
    }

    /// The attribution: the fingerprint on the row is the origin's SIGNED one, resolved against the
    /// admission ledger, and the display name is the body's claim re-moderated by the store.
    ///
    /// The body carries no fingerprint field at all, which is what makes the first half structural.
    @Test func theTranscriptRowCarriesTheSignedOriginFingerprint() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-attrib")
        defer { rig.teardown() }
        try await rig.settleChattingPair()

        #expect(rig.sendText(at: 0, "who said this") == .staged)
        try await rig.settle(until: { rig.transcript(at: 1).count == 1 })
        let row = try #require(rig.transcriptRows(at: 1).first)
        #expect(row.senderFingerprint == rig.identities[0].localFingerprint, """
            resolved from `manifest.originFingerprint` against `admissions − removals`, never from \
            the live transport identity and never from the body
            """)
        #expect(!row.isOutgoing)
        #expect(!row.senderDisplayName.isEmpty, "and the display claim survives moderation")
    }

    /// The cell that makes the token bucket's RETIREMENT load-bearing: six messages in one backlog
    /// all arrive. Under the retired burst allowance of 5 the sixth was dropped, and a drain answer
    /// carries up to 16 items — so a chatty pair reaching a joining device lost 11 of them.
    @Test func aBurstOfSixDrainedMessagesAllReachTheTranscript() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-burst")
        defer { rig.teardown() }
        try await rig.settleChattingPair()

        // R2: a fixed six, one more than the retired allowance.
        for index in 0..<6 {
            #expect(rig.sendText(at: 0, "burst\(index)") == .staged)
        }
        try await rig.settle(until: { rig.transcript(at: 1).count == 6 })
        #expect(rig.transcript(at: 1) == (0..<6).map { "burst\($0)" }, """
            all six, in order: the per-second flood guard retired with the transport it belonged \
            to, and its replacement is a per-session TOTAL that six messages cannot reach
            """)
    }

    /// The 13+ gate at the RECIPIENT, fail-closed — and final. Nothing is projected while the gate
    /// is shut, and nothing appears later when it opens: the gate is a durable product rule about
    /// this recipient, and §12's transcript belongs to the session that produced it.
    @Test func aMessageBelowTheRecipientsAgeGateProjectsNothingNowOrLater() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-gated")
        defer { rig.teardown() }
        try await rig.settleChattingPair()
        rig.nodes[1].manager.chatAllowedProvider = { false }

        #expect(rig.sendText(at: 0, "not for you") == .staged)
        try await rig.settle(until: { rig.stagedOwnItemID(at: 0) != nil })
        let itemID = try #require(rig.stagedOwnItemID(at: 0))
        try await rig.settle(until: { rig.routedIndex(1)?.items.isEmpty == false })

        #expect(rig.transcript(at: 1).isEmpty, "the gated recipient shows nothing")
        #expect(rig.routedIndex(1)?.items.contains { $0.key.itemID == itemID } == true, """
            while the CIPHERTEXT is held and acknowledged — delivery is final on durable ciphertext, \
            so the sender is not lied to either
            """)

        // The gate opens and a fresh rising access edge re-runs the projection pass.
        rig.nodes[1].manager.chatAllowedProvider = { true }
        rig.openGate(at: 1)
        try await rig.settle()
        #expect(rig.transcript(at: 1).isEmpty, """
            and still nothing: an age-gated projection is FINAL, so the message does not surface in \
            a later session's transcript when the recipient's gate changes
            """)
    }

    /// A message whose SESSION has ended is never projected, keeps its custody, and is marked FINAL
    /// so it leaves the retry list.
    ///
    /// Two doors in one cell, because they are one fact: the transcript was cleared, and the
    /// generation moved with it — so even a resumed session in the SAME mesh (which
    /// `startSearching()` un-ends) must not surface it.
    @Test func aMessageWhoseSessionHasEndedIsNeverProjectedAndIsMarkedFinal() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-ended")
        defer { rig.teardown() }
        try await rig.settleChattingPair()

        // The recipient's gate is CLOSED, so the item completes into custody unprojected.
        let recipient = rig.nodes[1].manager
        rig.closeGate(at: 1)
        #expect(rig.sendText(at: 0, "in the old session") == .staged)
        let itemID = try #require(rig.stagedOwnItemID(at: 0))
        try await rig.settle(until: {
            rig.routedIndex(1)?.items.contains { $0.key.itemID == itemID } == true
        })
        #expect(rig.transcript(at: 1).isEmpty, "nothing projected behind a closed gate")

        // The recipient's session ends, which CLEARS the transcript and bumps the generation.
        let generationBefore = recipient.transcriptGeneration
        recipient.leaveSession()
        #expect(recipient.transcriptGeneration > generationBefore, "the clear bumped the generation")

        rig.openGate(at: 1)
        try await rig.settle()
        #expect(rig.transcript(at: 1).isEmpty, """
            the message belongs to a transcript that vanished: same custody, ended session, so the \
            projection refuses and the ciphertext is kept until expiry
            """)
    }

    /// A **blip** is not an ending, so a message custodied around one projects when the link heals.
    ///
    /// This is the cell the design check raised as a P1: keying liveness on slot presence, with an
    /// unconditional projected-mark, would have marked a blip-time message FINAL and lost it from a
    /// transcript that was never cleared.
    @Test func aMessageCustodiedAcrossABlipStillProjectsAfterTheHeal() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-blip")
        defer { rig.teardown() }
        try await rig.settleChattingPair()
        let recipient = rig.nodes[1].manager

        #expect(rig.sendText(at: 0, "mid-blip") == .staged)
        let slot = try #require(recipient.slots.first)
        recipient.evictSlotForTesting(peerID: slot.id)
        #expect(!recipient.hasCommittedPeer, "the link is down")
        #expect(recipient.isSessionLive, "but the session is NOT over — a founded mesh outlives it")
        #expect(recipient.sessionMessages.messages.isEmpty, "and nothing was cleared")

        rig.reseat(1, toward: 0)
        rig.commit(1, 0)
        try await rig.settle(until: { rig.transcript(at: 1).count == 1 })
        #expect(rig.transcript(at: 1) == ["mid-blip"], """
            a liveness skip over a mesh that is STILL live must never be final — the item retries \
            at the next pass and lands once the link heals
            """)
    }

    /// A recipient that BLOCKS the origin after the item was custodied projects nothing, and the
    /// refusal is final: the block is a local judgement that does not expire.
    @Test func aBlockedOriginsMessageIsNotProjectedAndIsFinal() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-blocked")
        defer { rig.teardown() }
        try await rig.settleChattingPair()
        rig.closeGate(at: 1)
        #expect(rig.sendText(at: 0, "blocked later") == .staged)
        let itemID = try #require(rig.stagedOwnItemID(at: 0))
        try await rig.settle(until: {
            rig.routedIndex(1)?.items.contains { $0.key.itemID == itemID } == true
        })

        rig.nodes[1].store.proximityTrustVault.block(
            signingPublicKey: rig.identities[0].localSigningPublicKey
        )
        rig.openGate(at: 1)
        try await rig.settle()
        #expect(rig.transcript(at: 1).isEmpty, """
            the block is applied by `routedProjectionAuthor` BEFORE the content key is unwrapped, so \
            a blocked person's message is never materialised and then discarded
            """)
    }

    /// Nothing decrypts while the routed access gate is closed — the text twin of the photo claim,
    /// and the reason the mutation predicate is hoisted above the open.
    @Test func nothingProjectsWhileTheRoutedGateIsClosed() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-locked")
        defer { rig.teardown() }
        try await rig.settleChattingPair()
        rig.closeGate(at: 1)

        #expect(rig.sendText(at: 0, "locked out") == .staged)
        let itemID = try #require(rig.stagedOwnItemID(at: 0))
        try await rig.settle(until: {
            rig.routedIndex(1)?.items.contains { $0.key.itemID == itemID } == true
        })
        #expect(rig.transcript(at: 1).isEmpty, "held as ciphertext, projected nowhere")

        rig.openGate(at: 1)
        try await rig.settle(until: { rig.transcript(at: 1).count == 1 })
        #expect(rig.transcript(at: 1) == ["locked out"], """
            and the re-entry pass fills the transcript the moment the gate opens — a deferred \
            projection is RETRYABLE, which is the other half of the same claim
            """)
    }

    /// One message, ONE row, across a second rising access edge — the idempotence the projection
    /// and the store each guarantee separately, asserted where both are live.
    ///
    /// Two mechanisms would have to fail together for this to double: the projection skips an item
    /// already in `routedProjectedItems`, and if it did re-offer it `receiveIncoming` answers
    /// `alreadyHeld` (the dedup set deliberately never forgets an id, so a re-send cannot resurrect
    /// one). The per-origin quota's third guarantee rides on the same fact — an already-accepted id
    /// is free, so a re-projection after a restart cannot spend a slot it already spent. The quota
    /// and cap CONSTANTS are pinned in `MeshRoutedTypeRegistryTests.theProjectionQuotasAreBoundedOnBothAxes`.
    @Test func aRepeatedProjectionPassAppendsTheMessageOnce() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-once")
        defer { rig.teardown() }
        try await rig.settleChattingPair()

        #expect(rig.sendText(at: 0, "just once") == .staged)
        try await rig.settle(until: { rig.transcript(at: 1).count == 1 })
        #expect(rig.transcript(at: 1) == ["just once"])

        // A closed-then-open gate is a real rising edge, so the whole re-entry projection pass runs
        // again over an index that still holds the item.
        rig.closeGate(at: 1)
        rig.openGate(at: 1)
        try await rig.settle()
        #expect(rig.transcript(at: 1) == ["just once"],
                "a second pass over the same item must not append a second row")
    }
}
