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

    /// Whether one node has marked an item FINAL — i.e. `MeshRoutedProjectionVerdict`'s
    /// `leavesTheRetryList` half fired and `routedProjectedItems` holds the key.
    ///
    /// The cells that claim "…AndIsMarkedFinal" have to OBSERVE this: asserting only that the
    /// transcript stayed empty stays green when the verdict flips to `refusedForNow`, because the
    /// underlying predicate refuses again at every pass (P6 item 4 fix review, finding P2-5).
    func isMarkedFinal(at node: Int, itemID: UUID) -> Bool {
        nodes[node].manager.routedProjectedItems.contains { $0.itemID == itemID }
    }

    /// Whether one node's projection pass would still OFFER this item, or has dropped it from the
    /// list for good.
    ///
    /// The observable half of "final" for an item whose own transcript has ended:
    /// `isProjectableAtThisPass` runs BEFORE the allowance is spent, so such an item never reaches
    /// the verdict and is therefore never in `routedProjectedItems` — which is a stronger
    /// statement than the mark, not a weaker one. Flipping the liveness arm to `refusedForNow`
    /// reddens this (the item stays on the list and the pass keeps paying for it).
    func isStillOfferedToTheProjection(at node: Int, itemID: UUID) -> Bool {
        guard let index = routedIndex(node),
              let record = index.items.first(where: { $0.key.itemID == itemID }) else { return false }
        return nodes[node].manager.isProjectableAtThisPass(record.reference, in: index)
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
        #expect(row.messageID == itemID, """
            the echo's message id IS the routed item id — `SessionMessageStore` dedups on \
            `(senderFingerprint, id)`, so a different id would let this device's own message \
            project a second time
            """)
        #expect(row.id == MeshContentKey(
            senderFingerprint: rig.identities[0].localFingerprint, contentID: itemID
        ), "and the ROW's identity is that id paired with this device's own fingerprint")
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

    /// A message whose SESSION has ended is never projected, keeps its custody, and **leaves the
    /// projection list for good** so it cannot starve the next pass.
    ///
    /// Renamed and re-asserted at item 4's fix review (finding P2-5): the cell used to claim
    /// "…AndIsMarkedFinal" while asserting only an empty transcript, which stays green if the
    /// verdict flips to `refusedForNow`. The mark is also the wrong thing to look for here —
    /// `isProjectableAtThisPass` drops an ended-transcript item from the list BEFORE the verdict
    /// runs, so it never reaches `routedProjectedItems` at all, and never spends a pass slot
    /// either. That exclusion is what is asserted, and it is the stronger claim.
    ///
    /// This cell's ending is `leaveSession()`, so the MESH leg answers; the generation leg's own
    /// shape is `aResumedSessionDoorThreeGaveUpOnProjectsNothingFromTheClearedTranscript` below.
    @Test func aMessageWhoseSessionHasEndedIsNeverProjectedAndLeavesTheProjectionList() async throws {
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
        #expect(!rig.isStillOfferedToTheProjection(at: 1, itemID: itemID), """
            and it has LEFT the projection list — observed, not inferred from an empty transcript: \
            a `refusedForNow` here would leave the item on a 16-slot re-entry list until expiry, \
            which is the outage this distinction exists to prevent. The starvation that makes it \
            load-bearing is driven in `MeshRoutedRetryAllowanceTests` \
            (`aNewItemProjectsOnItsFirstPassBehindAFullAllowanceOfRetries` and its restart twin), \
            not duplicated here
            """)
        #expect(rig.routedIndex(1)?.items.contains { $0.key.itemID == itemID } == true,
                "with the ciphertext kept — a final PROJECTION is not a dropped item")
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
        #expect(rig.isMarkedFinal(at: 1, itemID: itemID), """
            and FINAL, observed on the mark: a block is a durable local judgement, so sixteen \
            blocked-origin items must leave the re-entry list rather than hold it until expiry
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

    /// **Door 3's generation leg, on the only shape that reaches it** (P6 item 4 fix review,
    /// finding P2-3).
    ///
    /// `MeshTranscriptLiveness` has three legs and the cell above exercises the MESH one:
    /// `leaveSession()` calls `leaveMesh()`, which nils `currentMesh`, so leg 2 answers first and
    /// deleting the generation guard reddened nothing. The generation leg's own shape needs a
    /// session that ends with the **mesh retained** and then becomes live again — which is exactly
    /// door 3: the five-minute discovery give-up raises `sessionSearchGaveUp` and stands the radios
    /// down without tearing the mesh, and `startSearching()` (through
    /// `resumeSearchingForPartitionedMesh()`) clears that flag. Same mesh, live again, cleared
    /// transcript: only the generation can say no.
    ///
    /// Driven with an injected instant and no sleep, the give-up clock's own idiom.
    @Test func aResumedSessionDoorThreeGaveUpOnProjectsNothingFromTheClearedTranscript() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-door3")
        defer { rig.teardown() }
        try await rig.settleChattingPair()
        let recipient = rig.nodes[1].manager

        // Behind a closed gate the item completes into custody unprojected — but it IS offered, so
        // `noteRoutedItemOffered` stamps it with the generation it arrived in.
        rig.closeGate(at: 1)
        #expect(rig.sendText(at: 0, "before the give-up") == .staged)
        let itemID = try #require(rig.stagedOwnItemID(at: 0))
        try await rig.settle(until: {
            rig.routedIndex(1)?.items.contains { $0.key.itemID == itemID } == true
        })
        let generationBefore = recipient.transcriptGeneration

        // Door 3: the peer goes away, the clock arms, and five minutes later the session is over.
        let slot = try #require(recipient.slots.first, "the commit must have seated a slot")
        let blipAt = Date()
        recipient.evictSlotForTesting(peerID: slot.id)
        #expect(recipient.isSessionGiveUpClockArmed, "a blip over a founded mesh arms door 3")
        recipient.evaluateSessionGiveUp(now: blipAt.addingTimeInterval(6 * 60))

        #expect(!recipient.isSessionLive, "the session ended by door 3")
        #expect(recipient.currentMesh != nil, """
            with the MESH RETAINED — which is the whole point: `leaveSession()` would nil it and \
            the mesh leg would answer instead, leaving this leg unexercised
            """)
        #expect(recipient.transcriptGeneration > generationBefore, "and the clear moved the generation")

        // The radios come back over the same mesh, which UN-ENDS the session: legs 1 and 2 both
        // say live, and leg 3 is the only refusal left.
        recipient.resumeSearchingForPartitionedMesh()
        #expect(recipient.isSessionLive, "leg 1 is reversible — that is why leg 3 exists")
        #expect(recipient.currentMesh?.meshID != nil, "and leg 2 still matches")

        rig.openGate(at: 1)
        try await rig.settle()
        #expect(rig.transcript(at: 1).isEmpty, """
            so the item does not surface: it belongs to a transcript §12 says vanished, and custody \
            deliberately outlives the session
            """)
        #expect(!rig.isStillOfferedToTheProjection(at: 1, itemID: itemID),
                """
                and the generation never goes back, so the item has left the projection list rather \
                than holding a slot on it until expiry
                """)
    }

    /// **Nothing projects while the app's delete-all funnel is running** (P6 item 4 fix review,
    /// finding P2-1).
    ///
    /// Delete-all drops the live transcript at the top of the funnel and destroys the routed
    /// ciphertext near the end of it, with real suspension points in between — so a rising access
    /// edge landing in the middle re-projected items whose bytes the user had just asked to have
    /// destroyed, into surfaces the same funnel had already emptied.
    ///
    /// **The subject is a PHOTO as well as a message, and the photo is what makes the guard
    /// load-bearing.** `beginPrivacyWipe()` also bumps the transcript generation, so for a text
    /// item the generation leg would refuse it anyway and an empty transcript cannot tell the two
    /// apart. The photo arm has no such leg: without the guard the wall is fed in the middle of a
    /// wipe that purged the photo corpora at leg 4. The last two assertions are the other half —
    /// the refusal is RETRYABLE and uncharged (a wipe is the gate's own answer for every item,
    /// never a fact about one of them), so once the funnel is over the item really does land.
    @Test func nothingProjectsWhileADeleteAllWipeIsInProgress() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-wipe")
        defer { rig.teardown() }
        try await rig.settleChattingPair()
        let recipient = rig.nodes[1].manager

        // Behind a closed gate both items complete into custody unprojected. The photo's id is read
        // before the message is minted, because `stagedOwnItemID` answers "the first item I minted".
        rig.closeGate(at: 1)
        rig.capturePhoto(at: 0)
        let photoID = try #require(rig.stagedOwnItemID(at: 0), "the capture must have staged")
        #expect(rig.sendText(at: 0, "wiped mid-funnel") == .staged)
        try await rig.settle(until: {
            rig.routedIndex(1)?.items.contains { $0.key.itemID == photoID } == true
        })
        let generationBefore = recipient.transcriptGeneration

        recipient.beginPrivacyWipe()
        #expect(recipient.privacyWipeInProgress)
        #expect(recipient.transcriptGeneration > generationBefore, """
            the wipe drops the transcript through the manager's ONE clear funnel, so the generation \
            moves with it — leg 7b's old `sessionMessages.clear()` did not
            """)

        rig.openGate(at: 1)
        try await rig.settle()
        #expect(rig.wallEntries(at: 1, itemID: photoID) == 0, """
            a rising edge INSIDE the funnel feeds nothing to the photo wall — the funnel purged the \
            photo corpora at leg 4, and this is the assertion the guard itself owns
            """)
        #expect(rig.transcript(at: 1).isEmpty, "and nothing reaches the transcript either")
        #expect(!rig.isMarkedFinal(at: 1, itemID: photoID), """
            and the refusal is RETRYABLE and uncharged: the wipe is the gate's own answer for every \
            item, so marking one final here would lose it to a wipe that failed halfway
            """)

        recipient.endPrivacyWipe()
        #expect(!recipient.privacyWipeInProgress, "and the funnel lowers it on every exit")

        // The proof that it really was retryable: one more rising edge, and the item lands.
        rig.closeGate(at: 1)
        rig.openGate(at: 1)
        try await rig.settle(until: { rig.wallEntries(at: 1, itemID: photoID) == 1 })
        #expect(rig.wallEntries(at: 1, itemID: photoID) == 1,
                "nothing was lost — the wipe deferred the projection, it did not retire it")
    }

    /// **Two overlapping wipe funnels: the gate falls with the LAST of them** (P6 item 4 fix review
    /// P3-2, taken in item 7).
    ///
    /// Two entry points reach `FernletStore.deleteAllData(includingHealthKitSamples:)` with no
    /// in-flight guard between them — `DeleteEverythingFlow.runWipe` *sets* `isDeleting` rather than
    /// checking it, and the duress purge hook fires the same funnel with no UI gate at all — and
    /// both are `@MainActor`, so they interleave at the funnel's five `await`s. With a `Bool`, the
    /// inner funnel's `defer` lowered the flag while the outer one still had the routed-store purge
    /// ahead of it, re-opening exactly the window the flag closes, on the path where the user's
    /// intent is strongest. The depth counter is the fix, and the middle assertion is the defect in
    /// its own words.
    ///
    /// The tail is the cap, and it pins SYMMETRY (P6 item 7 fix review, P3-7): begins past
    /// `maxPrivacyWipeDepth` saturate the depth but are counted in the overflow, ends drain the
    /// overflow first, and the gate therefore falls on the LAST paired end rather than one end
    /// early. A saturating depth alone was fail-open in its own small way — the ninth begin did not
    /// increment and the ninth end still decremented, so the routed projection ran again while an
    /// outer funnel still had the ciphertext purge ahead of it. (It was ALSO said to keep
    /// `mesh.privacyWipe.began` pairing with `mesh.privacyWipe.ended` for a transcript reader.
    /// That was never true and this counter cannot make it true: `ended` is written only at depth
    /// zero, so N nested funnels always wrote N begins and one end — P6 item 10 SET A, P3-a.)
    ///
    /// The LAST leg is the overflow's own cap, which was remembered rather than pinned (P6 item 10
    /// SET A, P3-d): past `2 × maxPrivacyWipeDepth` overlapping funnels the counter saturates, the
    /// begin is audited `saturated` and dropped, and the gate really does fall one end early again
    /// — the documented honest failure, now asserted. It needs seventeen concurrent `@MainActor`
    /// delete-all funnels, which the two shipping entry points cannot produce; the leg exists so
    /// the cap's behaviour is a fact about the code rather than a sentence about it.
    @Test func overlappingWipeFunnelsKeepTheProjectionShutUntilTheLastOneEnds() throws {
        let rig = try MeshFoundingRig.build(2, label: "wipe-depth")
        defer { rig.teardown() }
        let manager = rig.nodes[0].manager
        #expect(manager.privacyWipeDepth == 0)

        manager.beginPrivacyWipe()
        manager.beginPrivacyWipe()
        #expect(manager.privacyWipeDepth == 2)
        manager.endPrivacyWipe()
        #expect(manager.privacyWipeInProgress, """
            the inner funnel's `defer` lowered the gate while the outer one still had the \
            routed-store purge ahead of it — the window a Bool re-opened
            """)
        manager.endPrivacyWipe()
        #expect(!manager.privacyWipeInProgress)

        // Never negative: an unpaired end at zero is a no-op, so the next begin still raises it.
        manager.endPrivacyWipe()
        #expect(manager.privacyWipeDepth == 0)
        manager.beginPrivacyWipe()
        #expect(manager.privacyWipeInProgress)
        manager.endPrivacyWipe()

        // And bounded: begins past the cap saturate the DEPTH rather than growing without limit
        // (R2) — but they are counted, so their ends still pair.
        let cap = MeshNetworkManager.maxPrivacyWipeDepth
        // R2: a hard constant ceiling.
        for _ in 0..<(cap + 3) { manager.beginPrivacyWipe() }
        #expect(manager.privacyWipeDepth == cap, "the depth grew past its own cap")
        #expect(manager.privacyWipeOverflow == 3, "the begins past the cap were dropped, not counted")
        // R2: the three overflow ends, which must drain the overflow and NOT the depth.
        for _ in 0..<3 { manager.endPrivacyWipe() }
        #expect(manager.privacyWipeDepth == cap, "an end past the cap lowered the gate's own counter")
        #expect(manager.privacyWipeOverflow == 0, "the three overflow ends did not drain the overflow")
        // R2: the same ceiling, one end short of the last.
        for _ in 0..<(cap - 1) { manager.endPrivacyWipe() }
        #expect(manager.privacyWipeInProgress, "the gate fell before the LAST paired end")
        manager.endPrivacyWipe()
        #expect(!manager.privacyWipeInProgress, "the counter came back down to zero")

        // The overflow's OWN cap and its `saturated` arm (P6 item 10 SET A, P3-d). `2 × cap + 1`
        // begins: the depth saturates at the cap, the overflow saturates at the cap, and the last
        // begin is audited `saturated` rather than counted — so it has no end to pair with and the
        // gate falls one end early again. That is the documented honest failure; it is asserted
        // here so it is a fact about the code rather than a sentence about it.
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        // R2: a hard constant ceiling.
        for _ in 0..<(2 * cap + 1) { manager.beginPrivacyWipe() }
        #expect(manager.privacyWipeDepth == cap, "the depth grew past its own cap under saturation")
        #expect(manager.privacyWipeOverflow == cap, "the overflow counter grew past its own cap")
        #expect(capture.values(of: "mesh.privacyWipe.depthExceeded", key: "saturated").contains("true"),
                "the begin the counters could not hold was dropped without saying so")
        // R2: the same ceiling — one end short of the begins, which is the whole point.
        for _ in 0..<(2 * cap) { manager.endPrivacyWipe() }
        #expect(!manager.privacyWipeInProgress, """
            past 2 × maxPrivacyWipeDepth overlapping funnels the gate falls one end early again — \
            the named cost of a bounded counter, unreachable from the two @MainActor entry points \
            and pinned here rather than remembered
            """)
        manager.endPrivacyWipe()
        #expect(manager.privacyWipeDepth == 0 && manager.privacyWipeOverflow == 0,
                "the unpaired end drove a counter somewhere other than zero")
    }

    /// **The per-origin message quota's three legs** (P6 item 4 fix review, finding P2-4): it
    /// refuses past its cap, a re-send of an accepted id is free, and the map is bounded on its
    /// other axis rather than growing.
    ///
    /// Until this cell the door that REPLACED the retired token bucket had only a constants pin
    /// (`MeshRoutedTypeRegistryTests.theProjectionQuotasAreBoundedOnBothAxes`), so making the body
    /// `return true` unconditionally reddened nothing — a retired rate limit replaced by an
    /// untested total. Driven at the door rather than end to end, because 200 delivered messages is
    /// a load test and the subject is the map.
    @Test func theIncomingTextQuotaRefusesPastItsCapAndIsFreeForAReSend() async throws {
        let rig = try MeshFoundingRig.build(2, label: "text-quota")
        defer { rig.teardown() }
        let perOrigin = rig.nodes[0].manager
        let cap = MeshNetworkManager.maxTextMessagesPerSenderPerSession
        let manifest = Self.quotaManifest(origin: "quota-origin")

        var accepted: [UUID] = []
        // R2: bounded by the cap itself.
        for _ in 0..<cap {
            let id = UUID()
            #expect(perOrigin.allowIncomingRoutedText(id, from: manifest))
            accepted.append(id)
        }
        #expect(!perOrigin.allowIncomingRoutedText(UUID(), from: manifest),
                "the cap+1th id from one origin in one mesh is refused")
        let alreadyAccepted = try #require(accepted.first)
        #expect(perOrigin.allowIncomingRoutedText(alreadyAccepted, from: manifest), """
            while a re-send of an id already accepted is FREE — a re-projection after a restart \
            must not cost a slot it already spent
            """)
        #expect(perOrigin.allowIncomingRoutedText(UUID(), from: Self.quotaManifest(origin: "other")),
                "and another origin in the same mesh has its own budget")
        #expect(perOrigin.allowIncomingRoutedText(
            UUID(), from: Self.quotaManifest(origin: "quota-origin", mesh: UUID())
        ), "as does the same origin in another MESH — the key is the ITEM's mesh (D-13.23)")

        // The other axis, on a manager whose map is still empty: `MeshRoutedStoreFormat.maxItems`
        // keys, and then a fresh `(mesh, origin)` is refused rather than admitted.
        let mapBound = rig.nodes[1].manager
        // R2: bounded by the store's own item cap.
        for index in 0..<MeshRoutedStoreFormat.maxItems {
            #expect(mapBound.allowIncomingRoutedText(
                UUID(), from: Self.quotaManifest(origin: "bulk-\(index)")
            ))
        }
        #expect(!mapBound.allowIncomingRoutedText(UUID(), from: Self.quotaManifest(origin: "one-too-many")),
                "the map refuses a new key at its bound instead of growing")
        #expect(mapBound.allowIncomingRoutedText(UUID(), from: Self.quotaManifest(origin: "bulk-0")),
                "while an origin already in the map keeps its budget")
    }

    /// A manifest that is real in the fields the quota reads — `(meshID, originFingerprint)` — and
    /// opaque everywhere else. It never reaches a verifier: `allowIncomingRoutedText` is a map
    /// lookup, and signing one would test the signer.
    private static func quotaManifest(
        origin: String, mesh: UUID = MeshRoutedManifestFixtures.meshID
    ) -> MeshRoutedManifest {
        MeshRoutedManifest(
            meshID: mesh,
            itemID: UUID(),
            originFingerprint: origin,
            typeToken: MeshRoutedManifestFixtures.typeToken,
            contentHash: MeshRoutedManifestFixtures.contentHash,
            size: 1,
            createdAt: MeshRoutedManifestFixtures.createdAt,
            expiresAt: MeshRoutedManifestFixtures.expiresAt,
            destinations: [],
            keyWraps: [],
            signature: MeshRoutedManifestFixtures.opaqueSignature
        )
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
