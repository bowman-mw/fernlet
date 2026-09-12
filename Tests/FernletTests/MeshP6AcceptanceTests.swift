// MeshP6AcceptanceTests.swift
// FernletTests
//
// Network migration **P6's acceptance battery** (plan §12.4, launcher item 9): one serialized suite
// per clause, each promoting the named tier-1 claims of the item it speaks for and adding the
// property the item's own cells could not reach.
//
// The shape is `MeshP5AcceptanceTests.swift`'s, deliberately: one clause per suite, run END TO END
// rather than a list of other suites' names, so CI gating a clause fails on this battery's own
// assertions. Where an exhaustive space already exists it is CITED in the doc comment and not
// re-run — §11.4's idiom.
//
// **Eight suites, not the launcher's seven.** P5's separate Honesty suite earned its place by giving
// the rectangle's wholeness and the not-claimed list a home, and P6's rectangle G needs the same.
// `CIGateSelectorBoundaryTests` therefore moves its battery pin from 28 to 36.
//
// **What lives elsewhere, and why.** The feature pipeline, its seams and rectangle G live in
// `MeshRoutedDrainConvergenceTests.swift`, not here and not in a new file: a new
// `Mesh…ConvergenceTests` suite would not match `CIGateSelectorBoundaryTests.isMeshBattery`'s
// `MeshP<n>…AcceptanceTests` shape and could sit ungated the day it was written. The two determinism
// digests keep their one home in `MeshP5DeterminismAcceptanceTests`; this file's determinism clause
// says so rather than copying a literal.

import CryptoKit
import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshP6Acceptance

/// The thin rig P6's clauses share: rectangle G's corners, and the file list the grep walls scan.
@MainActor
enum MeshP6Acceptance {

    /// The two feature cells a clause runs when it needs a converged mesh rather than the whole
    /// tree: the root seed and its first successor on `2/2`, rectangle F's own corners.
    nonisolated static var corners: [MeshRoutedConvergenceCell] {
        MeshConvergenceSeeds.family.prefix(2).map {
            MeshRoutedConvergenceCell(shape: .twoTwo, seed: $0)
        }
    }

    /// The first two feature cells whose overlay actually **shut a chat gate**.
    ///
    /// Selected by arithmetic over the built overlays rather than by a second draw — `developing`'s
    /// own idiom — because the age-gate clause is otherwise vacuous on a corner that drew no gated
    /// member: its `guard` returns and the cell passes having asserted nothing. Measured: reverting
    /// the gate from `projectableRoutedTypeTokens` left the clause GREEN on
    /// `MeshP6Acceptance.corners` (`logs/item9/neg-01.log`), which is exactly the false green this
    /// selection removes. Its non-emptiness is pinned in `MeshP6HonestyAcceptanceTests`.
    nonisolated static var gatedCorners: [MeshRoutedConvergenceCell] {
        Array(
            MeshRoutedConvergenceMatrix.featureTree
                .filter { $0.overlay.ageGatedMember != nil }
                .prefix(2)
        )
    }

    /// One feature cell per partition shape, at the root seed — the widest claim a clause can make
    /// for five runs rather than twelve.
    nonisolated static var oneCellPerShape: [MeshRoutedConvergenceCell] {
        MeshPartitionShape.matrix.map {
            MeshRoutedConvergenceCell(shape: $0, seed: MeshConvergenceSeeds.root)
        }
    }

    /// Runs one feature cell and hands back the executed run.
    static func feature(
        _ cell: MeshRoutedConvergenceCell, label: String
    ) async throws -> MeshRoutedFeatureCellRun {
        try await MeshRoutedFeaturePipeline.featureRouting(cell, label: label)
    }

    /// Ends every session a feature run left open.
    static func teardown(_ run: MeshConvergenceRun) { MeshRoutedPipeline.teardown(run) }

    /// A founded, mutually admitted pair with hearts armed at both ends and both gates open — the
    /// precondition the pairwise clause and the ceremony's re-entry cell share.
    ///
    /// **The trust-vault rows are SEEDED.** A row appears when `pendingFriendReview` completes,
    /// which fires at session END, so inside the session that produced a heart it cannot exist. This
    /// stands in for a second session and proves nothing about the first; item 10's two-session
    /// Lane C script is the only honest proof of the feature, and the Honesty clause says so.
    static func heartedPair(_ label: String) async throws -> MeshFoundingRig {
        let rig = try MeshFoundingRig.build(2, label: label)
        try await rig.settleChattingPair()
        let day = MeshRoutedFixtureClock.createdAt
        // R2: a fixed two-element list.
        for index in 0..<2 {
            rig.nodes[index].manager.heartLedger = rig.isolatedHeartLedger(now: day)
            rig.nodes[index].store.setAllowNearbyHearts(true)
        }
        rig.trustPeer(at: 1, asSeenFrom: 0)
        rig.trustPeer(at: 0, asSeenFrom: 1)
        #expect(rig.nodes[0].manager.sessionState == .activeForeground,
                "the heart stage's third leg is a live FOREGROUND session at the sender's end too")
        #expect(rig.nodes[1].manager.sessionState == .activeForeground,
                "and at the recipient's, without which every heart below defers")
        return rig
    }
}

// MARK: - (a) Key advertisement — item 1

/// **P6 item 1's clause: nobody is addressable until every member's own key advertisement has
/// converged, and the mint says so by name when it has not.**
///
/// Promotes `MeshRoutedPhotoDeliveryTests`' star mint and its real-restart delivery, and
/// `MeshKeyAdvertisementDeliveryTests`' fold/rollback space — both of which run on the drain rigs,
/// whose ledgers are seeded differently from the convergence run's. The property this adds is
/// convergence **across the partition tree**, and the negative is the one that really bites.
///
/// **The negative is the CHAT GATE, not the arming** (P6 item 7's measured correction to the item 9
/// design). A run that skips `armKeyAdvertisements(now:)` converges anyway, because item 1's
/// `repairOwnKeyAdvertisementIfMissing()` self-mints on the heal's first ask; the mechanism is
/// asserted in `MeshRoutedDrainConvergenceTests.withoutTheArmingDoorItemOnesSelfMintRepairStillAddressesTheMesh`.
/// What IS fail-closed, and what would make the whole text half green over nothing, is
/// `chatAllowedProvider == nil`.
@MainActor
@Suite(.serialized)
struct MeshP6KeyAdvertisementAcceptanceTests {

    /// **Every living member ends holding every other living member's advertised key, on every
    /// shape** — and a real mint resolves against it.
    @Test(arguments: MeshP6Acceptance.oneCellPerShape)
    func theAdvertisedKeySetConvergesOnEveryShape(cell: MeshRoutedConvergenceCell) async throws {
        let run = try MeshConvergenceRun.build(
            cell.schedule, label: "p6adv", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshP6Acceptance.teardown(run) }
        try await run.runSplitEvents()
        run.allowChatEverywhere(except: nil)
        run.armKeyAdvertisements(now: MeshRoutedPipeline.mintInstant)
        try await run.runHeal()
        try await run.runKeyAdvertisementRounds()

        run.expectAdvertisementsConverged()
        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        let key = try run.routedTextEvent(at: origin, round: 0)
        #expect(run.routedOutstanding(at: origin, key: key).isEmpty == false, """
            a converged set must resolve REAL destinations for the text row — an empty outstanding \
            list here is a mint that addressed nobody
            """)
    }

    /// **The fail-closed 13+ gate, as a positive assertion.** Without `allowChatEverywhere(except:)`
    /// the text mint answers `.ageGated` before any resolver runs, so every text claim in this
    /// battery would be green over nothing.
    @Test func withoutTheChatGateEveryTextMintIsAgeGatedBeforeItResolvesAnything() async throws {
        let cell = MeshRoutedConvergenceCell(shape: .twoTwo, seed: MeshConvergenceSeeds.root)
        let run = try MeshConvergenceRun.build(
            cell.schedule, label: "p6adv-gate", anchor: MeshRoutedFixtureClock.createdAt
        )
        defer { MeshP6Acceptance.teardown(run) }
        try await run.runSplitEvents()
        run.armKeyAdvertisements(now: MeshRoutedPipeline.mintInstant)
        try await run.runHeal()
        try await run.runKeyAdvertisementRounds()

        #expect(run.routedAdvertisementsConverged(), """
            the addressing must be sound, or this cell would prove the gate refuses on a mesh that \
            could not have delivered anyway
            """)
        let origin = try #require(run.livingMembers.first, "the cell needs a surviving origin")
        #expect(run.sendTextOutcome(at: origin, round: 0) == .ageGated, """
            `chatAllowedProvider` is nil on a freshly built manager and `isChatAllowed` reads \
            `provider?() == true`, so the gate is fail-closed and the mint never reaches a resolver
            """)
        #expect(run.livingMembers.allSatisfy { $0.node.manager.sessionMessages.messages.isEmpty },
                "and no transcript anywhere holds a row for a message that was never minted")
    }
}

// MARK: - (b) Pairwise identity — item 2

/// **P6 item 2's clause: a proximity-founded PAIR delivers both of P6's rows, both ways.**
///
/// Cites, rather than re-runs, the exhaustive founding space:
/// `MeshPairwiseFoundingTests.aPairwisePhotoIsDeliveredBothWaysThroughTheAppPath`,
/// `…aThirdCommitMergesIntoTheFoundedMeshAndInheritsItsAdvertisements`, and
/// `MeshRoutedTextDeliveryTests.aPairsMessagesAreDeliveredBothWaysAndOrderedAtBothEnds`. What it runs
/// is one compact scenario on the real founding path with nothing seeded but the trust-vault rows a
/// heart needs, and it asserts at the **recipients**, never at the senders.
@MainActor
@Suite(.serialized)
struct MeshP6PairwiseIdentityAcceptanceTests {

    /// Both rows, both ways, on one founded pair.
    @Test func afoundedPairDeliversATextAndAHeartInBothDirections() async throws {
        let rig = try await MeshP6Acceptance.heartedPair("p6pair")
        defer { rig.teardown() }
        #expect(rig.roster(0).count == 2 && rig.roster(1).count == 2,
                "the destination set the mint needs is the derived roster")

        #expect(rig.sendText(at: 0, "hello from zero") == .staged)
        #expect(rig.sendText(at: 1, "hello from one") == .staged)
        try await rig.settle(until: {
            rig.transcript(at: 0).count == 2 && rig.transcript(at: 1).count == 2
        })
        #expect(rig.transcript(at: 0).contains("hello from one"),
                "node 0's transcript is missing the message node 1 sent it")
        #expect(rig.transcript(at: 1).contains("hello from zero"),
                "node 1's transcript is missing the message node 0 sent it")

        let toOne = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "One"))
        let toZero = try #require(rig.sendHeartReturningItemID(from: 1, to: 0, name: "Zero"))
        try await rig.settle()
        #expect(rig.nodes[1].manager.heartLedger?.receivedHearts.map(\.id) == [toOne],
                "node 1's ledger holds exactly the gift node 0 sent it")
        #expect(rig.nodes[0].manager.heartLedger?.receivedHearts.map(\.id) == [toZero],
                "and node 0's holds exactly the gift node 1 sent it")
    }

    /// **A heart's destination set is ONE member even on a pair** — the flip's own statement, where
    /// a full-roster target would have been indistinguishable from it.
    @Test func aPairsHeartStillNamesExactlyOneDestination() async throws {
        let rig = try await MeshP6Acceptance.heartedPair("p6pair-one")
        defer { rig.teardown() }
        let gift = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "One"))
        let record = try #require(
            rig.routedIndex(0)?.items.first { $0.key.itemID == gift }
        )
        #expect(record.deliveryTarget?.destinations == [rig.nodes[1].fingerprint], """
            the heart row is `.singleRecipient`, so its destination set is the recipient and \
            nobody else — on a pair the two shapes agree in COUNT and not in meaning
            """)
    }
}

// MARK: - (c) The per-type caps — item 3

/// **P6 item 3's clause: every registered row's byte cap is ARITHMETIC over its own body family,
/// never a literal.**
///
/// Promotes item 3's boundary-admission cell and `MeshRoutedTextBodyTests`' cap formula. The
/// property here is that all three rows are derived the same way, so a body-format change moves the
/// cap with it and the manifest door's `sizeExceedsTypeCap` cannot drift from the mint's own bound.
@MainActor
@Suite(.serialized)
struct MeshP6PerTypeCapAcceptanceTests {

    /// Each of increment 1's three rows carries its own body family's derived ceiling.
    @Test func allThreeRegisteredCapsAreTheirBodyFamilysOwnArithmetic() throws {
        let registry = MeshRoutedTypeRegistry.increment1
        #expect(registry.tokens.count == 3, "increment 1 registers three routed types")
        let photo = try #require(registry.entry(for: MeshRoutedTypeToken.photo))
        let text = try #require(registry.entry(for: MeshRoutedTypeToken.tempMessage))
        let heart = try #require(registry.entry(for: MeshRoutedTypeToken.heart))

        #expect(photo.maxItemByteCount == UInt64(MeshRoutedItemSealFormat.maxResidentBlobByteCount),
                "the photo row is the widest CIPHERTEXT a routed photo can measure")
        #expect(text.maxItemByteCount == UInt64(MeshRoutedTextBody.maxSealedBlobByteCount),
                "the text row is the sanitized maximum plus its framed header plus the seal")
        #expect(heart.maxItemByteCount == UInt64(MeshRoutedHeartBody.maxSealedBlobByteCount),
                "and the heart row is a header-only body: the payload term is zero")
        #expect(MeshRoutedHeartBody.maxSealedBlobByteCount
                    == MeshRoutedHeartBody.maxFramedHeaderByteCount
                        + MeshRoutedItemSealFormat.overheadByteCount,
                "spelled out, so a heart cap that grew a payload term would say so here")
        #expect(heart.maxItemByteCount < text.maxItemByteCount, """
            a header-only body cannot be wider than one that carries 500 characters — an ordering \
            a literal cap would lose the moment either body changed
            """)
    }

    /// The three rows' **columns** are the ones P6 left editable, and the rest are frozen.
    @Test func theRegistryColumnsAreWhatEachRowClaims() throws {
        let registry = MeshRoutedTypeRegistry.increment1
        let heart = try #require(registry.entry(for: MeshRoutedTypeToken.heart))
        #expect(heart.destinations == .singleRecipient,
                "item 6's flip — the one re-declaration the freezing rule allowed, and it is spent")
        #expect(heart.finalAck == .foregroundDecryptAndLedgerCommit,
                "and the only stage whose condition the store cannot read for itself")
        // R2: a fixed three-element list.
        for token in [MeshRoutedTypeToken.photo, MeshRoutedTypeToken.tempMessage,
                      MeshRoutedTypeToken.heart] {
            let entry = try #require(registry.entry(for: token))
            #expect(entry.relayRetention == .originRetainsUntilDeparture,
                    "increment 1 has one relay rule, and a second is a registry decision")
            #expect(entry.expiry == .meshHardDeadlinePlusGrace,
                    "and one expiry rule, tied to the mesh's own ceiling")
        }
        #expect(registry.entry(for: MeshRoutedTypeToken.control) == nil,
                "the control token is reserved and deliberately unregistered")
    }
}

// MARK: - (d) Text routing — item 4

/// **P6 item 4's clause: a session text reaches every ungated member's transcript, is projected
/// nowhere below the 13+ line, and every honest reader agrees on its order.**
///
/// Cites `MeshRoutedTextDeliveryTests.aMessageBelowTheRecipientsAgeGateProjectsNothingNowOrLater`,
/// `…aMessageWhoseSessionHasEndedIsNeverProjectedAndLeavesTheProjectionList` and
/// `…CustodiedAcrossABlipStillProjectsAfterTheHeal`. The property it adds is rectangle G's text half
/// run over a converged partition tree, with the **complement** asserted: without it, a run where
/// nobody projected anywhere would pass the gate claim.
@MainActor
@Suite(.serialized)
struct MeshP6TextRoutingAcceptanceTests {

    /// **The gate withholds the PROJECTION and never the delivery** — two-sided, per the design
    /// check's R9: an empty transcript is a VIEW fact (`rederiveTranscript` filters through
    /// `visibleTranscript(gates:)`, and a closed gate hides rows without destroying them), so the
    /// gated member's held ciphertext is asserted beside it.
    ///
    /// **Which leg of the 13+ gate this cell actually walls — measured, in three runs** (item 9
    /// review, P2-2). The projection side has three independent legs, and only the last of them is
    /// what an empty transcript is evidence of:
    ///
    /// * **leg 4**, `projectableRoutedTypeTokens`, the re-entry pass's enumeration filter. Deleting
    ///   it alone reds nothing and *could* not (`logs/item9fix/neg-04.log`, suite green): leg 3
    ///   still refuses `.refusedForGood`. Nor is the `routedProjectedItems` mark its observable —
    ///   the delivery-time projection marks this item at the gated member either way (measured: a
    ///   mark claim was written, run, and reddened with leg 4 INTACT, then withdrawn). It is a
    ///   pass-slot economy, and this battery does not claim it.
    /// * **leg 3**, the `.sessionTranscript` arm's own `guard isChatAllowed`, applied BEFORE the
    ///   unwrap. Deleting it alone also leaves this cell green (`neg-05.log`): the row is received
    ///   and HELD, and the view gate below still hides it. Leg 3 is a *decrypt* claim — it is what
    ///   stops the plaintext existing — and the honest wall for it is an audit-line claim nobody has
    ///   written yet.
    /// * **the view gate**, `SessionMessageStore.refreshGates(chatAllowed:isRefused:)` folding
    ///   `MeshContentGates`, which is what `messages` is derived through. Deleting leg 3 AND forcing
    ///   that fold open reds this cell on **both** gated cells (`neg-06.log`,
    ///   `MeshP6AcceptanceTests.swift:339`) — so "nothing is projected below the 13+ line" is walled
    ///   here at the seam that decides it, and the held-ciphertext line beside it is what keeps the
    ///   claim from being a claim about a delivery that never happened.
    ///
    /// **Leg 3's own tripwire is one line, not a cell** (P6 item 9's second fix review, P3-6).
    /// `mesh.routedProjection.transcriptAgeGated` is written in exactly ONE place in the tree —
    /// leg 3's refusal arm, `MeshNetworkManager.swift:7919` — so capturing it around this run says
    /// leg 3 fired, which the view gate cannot fake. **Its one weakness, named rather than left for
    /// a reader to find:** the audit log is process-global and suites run in parallel, so a
    /// concurrent suite driving its own gated projection could satisfy the count. It is therefore a
    /// deletion tripwire for leg 3 rather than an exact per-manager witness; an exact one would need
    /// a new `onRoutedProjectionRefusalForTesting` seam on the manager, which is a residual by name.
    @Test(arguments: MeshP6Acceptance.gatedCorners)
    func aGatedMemberHoldsTheCiphertextAndProjectsNothing(
        cell: MeshRoutedConvergenceCell
    ) async throws {
        let gateAudit = MeshRoutedBackpressureAuditCapture()
        gateAudit.install()
        defer { gateAudit.uninstall() }
        let outcome = try await MeshP6Acceptance.feature(cell, label: "p6text-gate")
        defer { MeshP6Acceptance.teardown(outcome.run) }
        let run = outcome.run
        let wanted = MeshConvergenceRun.featureText(outcome.overlay.textRound)

        let gatedIndex = try #require(outcome.overlay.ageGatedMember,
                                      "this clause runs only cells that really shut a gate")
        let gated = try #require(run.participant(global: gatedIndex),
                                 "the overlay named a gated member this run does not leave alive")
        #expect(gated.node.manager.isChatAllowed == false,
                "the gated member's own precondition, read at the device rather than assumed")
        #expect(gated.node.manager.sessionMessages.messages.isEmpty,
                "a routed text was projected below the 13+ line")
        #expect(run.routedIndex(of: gated)?.items
            .contains { $0.key == outcome.textKey } == true, """
            while the CIPHERTEXT is held — finality is durable storage, so the gate withholds the \
            projection and the sender is not lied to either
            """)
        // The complement, and it is the non-vacuity: without it a run where NOBODY projected passes.
        // R2: bounded by the roster cap.
        for member in run.livingMembers
        where member.index != outcome.textOrigin.index && member.index != gatedIndex {
            #expect(member.node.manager.sessionMessages.messages.map(\.text).contains(wanted),
                    "an ungated survivor's transcript is missing the message")
        }
        #expect(gateAudit.count(of: "mesh.routedProjection.transcriptAgeGated") > 0, """
            leg 3 — the `.sessionTranscript` arm's own `guard isChatAllowed`, applied BEFORE the \
            unwrap — never refused anything while this cell ran, so the empty transcript above is \
            the VIEW gate's doing and the plaintext was decrypted below the 13+ line
            """)
    }

    /// **One honest transcript** — identical rows, in one order, at every ungated reader, with the
    /// clamp asserted rather than commented.
    ///
    /// `MeshMergedMessage.claimWindow` is ten minutes and the ordering instant inside it IS the
    /// claim, which every member agrees on; outside it each member clamps to its own first-seen,
    /// which is a security property and not a coordination mechanism. `SessionMessageStore.Message`
    /// exposes no `firstSeenAt` and its `sentAt` **is** the already-clamped value (the design
    /// check's R10), so the derivable — and stronger — statement is that every reader stored the
    /// same instant as the origin's own outgoing row, where the clamp is the identity by
    /// construction. Triples rather than ids alone (O4): a swapped body would survive id equality.
    @Test(arguments: MeshP6Acceptance.corners)
    func everyHonestReaderAgreesOnTheTranscriptAndItsInstants(
        cell: MeshRoutedConvergenceCell
    ) async throws {
        let outcome = try await MeshP6Acceptance.feature(cell, label: "p6text-order")
        defer { MeshP6Acceptance.teardown(outcome.run) }
        let readers = outcome.run.livingMembers.filter { $0.index != outcome.overlay.ageGatedMember }
        let transcripts = readers.map { $0.node.manager.sessionMessages.messages }
        #expect(transcripts.first?.isEmpty == false, "an empty transcript everywhere compares nothing")

        let orders = transcripts.map { rows in
            rows.map { "\($0.messageID.uuidString)|\($0.text)|\($0.senderFingerprint)" }
                .joined(separator: ",")
        }
        #expect(Set(orders).count == 1,
                "two honest members disagree on the transcript's total order or on a row's body")
        let instants = transcripts.map { rows in
            rows.map { "\($0.messageID.uuidString)@\($0.sentAt.timeIntervalSince1970)" }
                .joined(separator: ",")
        }
        #expect(Set(instants).count == 1, """
            a reader clamped a claim to its own first-seen, which means the claim arrived outside \
            its ten-minute window and the battery's "every claim is inside its window by \
            construction" no longer holds
            """)
    }

    /// **Item 4's fourth handed-over invariant, which rectangle G cannot express** (the design
    /// check's R8): the transcript is cleared at session end on every member, and no post-session
    /// projection appears.
    ///
    /// Rectangle G cannot carry it because a feature cell never ends a session — the pipeline's
    /// teardown is the end, and by then there is nothing left to assert against.
    ///
    /// **The clear is a real transition** (item 9 review, P3-6): one message is delivered and
    /// PROJECTED with the gate open before anything closes, so `leaveSession()` empties a non-empty
    /// transcript. Closing the gate first left node 1's wall empty before the session ever ended,
    /// and "the transcript is cleared at session end" then rested on the generation bump alone.
    @Test func aSessionEndClearsTheTranscriptAndNothingProjectsIntoTheVacancy() async throws {
        let rig = try MeshFoundingRig.build(2, label: "p6text-ended")
        defer { rig.teardown() }
        try await rig.settleChattingPair()
        #expect(rig.sendText(at: 0, "before the end") == .staged)
        try await rig.settle(until: { rig.transcript(at: 1).isEmpty == false })
        #expect(rig.transcript(at: 1) == ["before the end"],
                "the recipient really projected it, which is what the clear below has to undo")

        rig.closeGate(at: 1)
        // The second item, identified by DIFFERENCE rather than by `items.first`: by now the index
        // holds the delivered first one too.
        let staged = Set(rig.routedIndex(0)?.items.map(\.key.itemID) ?? [])
        #expect(rig.sendText(at: 0, "in the old session") == .staged)
        let minted = Set(rig.routedIndex(0)?.items.map(\.key.itemID) ?? []).subtracting(staged)
        #expect(minted.count == 1, "one send, one new item")
        let itemID = try #require(minted.first)
        try await rig.settle(until: {
            rig.routedIndex(1)?.items.contains { $0.key.itemID == itemID } == true
        })

        let recipient = rig.nodes[1].manager
        let generation = recipient.transcriptGeneration
        recipient.leaveSession()
        #expect(recipient.transcriptGeneration > generation, "the clear bumped the generation")
        #expect(rig.transcript(at: 1).isEmpty,
                "and a transcript that really had something in it really is empty")

        rig.openGate(at: 1)
        try await rig.settle()
        #expect(rig.transcript(at: 1).isEmpty, """
            §12's transcript belongs to the session that produced it: an item custodied across a \
            session END never projects into the next one
            """)
        #expect(rig.routedIndex(1)?.items.contains { $0.key.itemID == itemID } == true,
                "with the ciphertext kept — a final PROJECTION is not a dropped item")
    }
}

// MARK: - (e) Projection retry — item 5

/// **P6 item 5's clause: both re-entry lists make progress on one pass, and neither starves the
/// other.**
///
/// Cites `MeshRoutedRetryAllowanceTests.aNewItemProjectsOnItsFirstPassBehindAFullAllowanceOfRetries`,
/// `…aNewReceiptIsFiledOnItsFirstPassBehindAFullAllowanceOfHearts` and
/// `MeshRoutedRetryPlanTests.thePlannerNamesNoRoutedTypeNoRegistryAndNoStore` for the exhaustive
/// space. What it adds is one scenario over **both** lists on a run that really converged.
@MainActor
@Suite(.serialized)
struct MeshP6ProjectionRetryAcceptanceTests {

    /// The planner's share is arithmetic over the pass allowance: a retrying population can never
    /// take the whole pass, and a pass with no new work still hands its whole allowance to retries.
    ///
    /// Written as three list shapes rather than one, because the starvation runs both ways — the
    /// launcher's own half-and-half is the point at which neither side can be starved by the other.
    @Test func theRetryShareStarvesNeitherHalfOfThePass() {
        let keys = (0..<16).map { _ in
            MeshRoutedItemKey(originFingerprint: "p6retry-origin", itemID: UUID())
        }
        let allRetrying = MeshRoutedRetryPlan(
            enumerated: keys, attempted: Set(keys), rotation: keys, allowance: 8
        )
        #expect(allRetrying.keysToTry.count == 8,
                "a pass with only retries must still spend its whole allowance")
        #expect(allRetrying.neverTriedCount == 0, "and none of them is new work")

        let attempted = Array(keys.prefix(12))
        let mixed = MeshRoutedRetryPlan(
            enumerated: keys, attempted: Set(attempted), rotation: attempted, allowance: 8
        )
        #expect(mixed.retriedCount == 8 / MeshRoutedRetryPlan.retryShareDivisor, """
            the retry share must stay a SHARE: twelve retryables against four new items may claim \
            half the pass and no more, which is the starvation this planner exists to prevent
            """)
        #expect(mixed.neverTriedCount == 4, "and the reserved half went to the never-attempted work")
        #expect(mixed.deferredRetryCount > 0,
                "the paced retries are COUNTED, which is the only externally visible sign of pacing")

        let noneRetrying = MeshRoutedRetryPlan(
            enumerated: keys, attempted: [], rotation: [], allowance: 8
        )
        #expect(noneRetrying.neverTriedCount == 8,
                "a pass with no retryables hands its whole allowance to new work")
    }

    /// **A converged feature run leaves both lists accounted for**: the text is marked projected at
    /// every ungated reader, and a rising access edge at the heart's recipient reports its own acks
    /// rather than silently filing none.
    @Test func aConvergedRunAccountsForBothReEntryLists() async throws {
        let cell = MeshRoutedConvergenceCell(shape: .twoTwo, seed: MeshConvergenceSeeds.root)
        let outcome = try await MeshP6Acceptance.feature(cell, label: "p6retry")
        defer { MeshP6Acceptance.teardown(outcome.run) }
        let run = outcome.run

        // R2: bounded by the roster cap.
        for member in run.livingMembers
        where member.index != outcome.textOrigin.index
            && member.index != outcome.overlay.ageGatedMember {
            #expect(member.node.manager.routedProjectedItems.contains(outcome.textKey), """
                an ungated reader that projected the text must carry the mark, or the item stays on \
                a 16-slot re-entry list until expiry and pays for a slot on every pass
                """)
        }
        let gatedIndex = outcome.overlay.ageGatedMember
        if let gatedIndex, let gated = run.participant(global: gatedIndex) {
            #expect(!gated.node.manager.routedProjectedItems.contains(outcome.textKey), """
                and a member that projected NOTHING must not carry it — the mark is what the \
                projection did, never what the pass attempted
                """)
        }
    }
}

// MARK: - (f) The heart ceremony — item 6

/// **P6 item 6's clause: a gift is judged EXACTLY ONCE, anywhere, however the mesh partitioned.**
///
/// Promotes `MeshRoutedHeartCeremonyTests`' two-node ceremony and every refusal leg. The properties
/// this adds are the ones a two-node rig cannot reach: exactly-once **across the partition tree**,
/// a one-destination delivery on every shape, and the deferred-recipient arm with its re-entry.
///
/// **The witness is `MeshRoutedHeartAck.judgementsForGift`, counted per gift over item 6's own
/// `onHeartJudgedForTesting` seam.** Never the batch counter: the ceremony hands
/// `MeshHeartCommit.commit` a ONE-element batch, so the two coincide at every shipping call site and
/// an invariant written against the batch field would be green for an accident of this call site
/// forever. The fixture-only cell that separates the two fields lives in item 6's own file
/// (`MeshRoutedHeartCeremonyTests.aTwoHeartBatchSeparatesTheBatchCounterFromThePerGiftCount`), which
/// is why the determinism clause's grep-wall can demand a ZERO count of the batch field's spelling
/// in item 9's two files rather than an exception for one line.
@MainActor
@Suite(.serialized)
struct MeshP6HeartCeremonyAcceptanceTests {

    /// **One gift, one judgement, on every shape** — and exactly one ledger row behind it.
    @Test(arguments: MeshP6Acceptance.oneCellPerShape)
    func aGiftIsJudgedExactlyOnceOnEveryShape(cell: MeshRoutedConvergenceCell) async throws {
        let outcome = try await MeshP6Acceptance.feature(cell, label: "p6heart-tree")
        defer { MeshP6Acceptance.teardown(outcome.run) }
        let key = try #require(outcome.heartKey, "every cell in rectangle G plans a heart")
        let acks = outcome.judgementLog.acks(for: key.itemID)
        #expect(outcome.judgementLog.dropped == 0, "the witness hit its cap, so this count is partial")

        if outcome.overlay.heartRecipientForegrounded {
            #expect(acks.count == 1, "a gift was judged twice, or never, across this partition tree")
            let perGift = acks.allSatisfy { $0.judgementsForGift == 1 }
            #expect(perGift, "the per-gift witness must be 1 wherever evidence exists")
            #expect(
                outcome.run.heartLedgerRows(
                    at: outcome.heartRecipient, giftID: key.itemID
                ).count == 1,
                "the ledger's own dedup, corroborating the ack count at the device that holds it"
            )
        } else {
            #expect(acks.isEmpty, "a heart the recipient never foregrounded must be judged by nobody")
            #expect(
                outcome.run.heartLedgerRows(
                    at: outcome.heartRecipient, giftID: key.itemID
                ).isEmpty,
                "and no ledger row stands behind a judgement that never happened"
            )
            #expect(outcome.run.routedIndex(of: outcome.heartRecipient)?
                .record(for: key)?.chunks.isEmpty == false, """
                while the recipient HOLDS the ciphertext — an absence claim alone is satisfied by a \
                heart that was never minted, never addressed and never delivered
                """)
        }
    }

    /// **The heart's destination set is exactly one member on every shape** — the flip's own
    /// convergence statement, and the thing a full-roster target made unassertable.
    ///
    /// **Both halves: the plan AND the outcome** (item 9 review, P2-4). The first claim is about
    /// what the mint SIGNED, and a mis-targeted heart reds on it. A heart that keeps the right
    /// target and is *additionally* admitted at a third member reds nowhere else in the battery:
    /// `routedJudgedAudience` derives every roster-wide claim's audience from that same signed
    /// target, so the narrowing walks past the leaked member by construction; `armHeartCeremony`
    /// arms a ledger at origin and recipient only, so a leaked copy refuses before it could judge
    /// and `acks.count == 1` stays green. The complement loop is the outcome half — "and nobody
    /// else" — asserted at the devices themselves.
    ///
    /// Custody is the one shape that could legitimately put these chunks elsewhere, and increment 1
    /// does not: `originRetainsUntilDeparture` moves custody only at a DEPARTURE, to the custodians
    /// the leaver's signed record names, and a living non-destination is neither.
    ///
    /// **What the complement loop can and cannot red** (P6 item 9's second fix review, P3-4/P3-5),
    /// written here so a reader does not take three claims for three walls. The RECORD leg is the
    /// live one: item 9's `neg-01` produced ten of its fourteen issues there. The ledger-row and
    /// judgement legs cannot red in this rig at all — `armHeartCeremony` arms a ledger at the origin
    /// and the recipient only, so a non-destination has no ledger to write a row in and nothing to
    /// judge with; they are belt-and-braces against a future rig that arms every member, not
    /// independent claims today. And the loop is **vacuous on `twoOne`**, whose living roster is two:
    /// origin plus recipient leaves no member to iterate. The `livingMembers.count >= 3` assertion
    /// below is what stops that vacuity spreading to the shapes that do have a complement.
    @Test(arguments: MeshP6Acceptance.oneCellPerShape)
    func aHeartNamesOneDestinationOnEveryShape(cell: MeshRoutedConvergenceCell) async throws {
        let outcome = try await MeshP6Acceptance.feature(cell, label: "p6heart-one")
        defer { MeshP6Acceptance.teardown(outcome.run) }
        let key = try #require(outcome.heartKey, "every cell in rectangle G plans a heart")
        let audience = outcome.run.routedJudgedAudience(outcome.heartOrigin, key: key)
        #expect(audience == [outcome.heartRecipient.fingerprint], """
            the heart row's `.singleRecipient` flip is what makes this a one-destination delivery — \
            a full-roster target would have named every survivor
            """)
        #expect(outcome.run.livingMembers.count >= 2,
                "a one-destination claim on a roster of one says nothing")

        var complement = 0
        // R2: bounded by the roster cap.
        for member in outcome.run.livingMembers where member.index != outcome.heartOrigin.index
            && member.index != outcome.heartRecipient.index {
            complement += 1
            #expect(outcome.run.routedIndex(of: member)?.record(for: key) == nil, """
                a one-destination heart reached a member its own signed target does not name — the \
                ciphertext is the thing the flip exists to keep off every other device
                """)
            #expect(outcome.run.heartLedgerRows(at: member, giftID: key.itemID).isEmpty,
                    "a member the target does not name wrote a heart-ledger row for this gift")
            #expect(!outcome.judgementLog.judged(key.itemID, at: member.fingerprint),
                    "a member the target does not name judged this gift")
        }
        if outcome.run.livingMembers.count >= 3 {
            #expect(complement > 0, """
                a shape with three living members ran the complement loop zero times, so "and \
                nobody else" asserted nothing on the shapes that have a complement at all
                """)
        }
    }

    /// **The deferred quarter, two-sided and then resolved** (the design check's R4 and R5).
    ///
    /// The leg that isolates the heart is `sessionState`, whose case is `.continuingInBackground`,
    /// reached by `applySessionEvent(.backgrounded)` — never a closed routed access gate, which
    /// would shut that member's TEXT projection too. And the claim is two-sided: the recipient holds
    /// the ciphertext with no ledger row, and then one `.foregrounded` edge plus one more bounded
    /// drain produces **exactly one** ack, which is what says the deferral was a deferral rather
    /// than a loss.
    @Test func aDeferredHeartIsHeldAndTheNextForegroundEdgeJudgesItExactlyOnce() async throws {
        let rig = try await MeshP6Acceptance.heartedPair("p6heart-defer")
        defer { rig.teardown() }
        var judged: [UUID] = []
        rig.nodes[1].manager.onHeartJudgedForTesting = { judged.append($0.giftID) }
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.nodes[1].manager.applySessionEvent(.backgrounded)
        }
        #expect(rig.nodes[1].manager.sessionState == .continuingInBackground,
                "the one leg that defers a heart without shutting the text projection with it")
        #expect(!rig.nodes[1].manager.mayCommitRoutedHeartLedgerJudgement,
                "and the predicate really is false, read at the device")

        let gift = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "One"))
        try await rig.settle()
        #expect(judged.isEmpty, "a backgrounded recipient must judge nothing")
        #expect(rig.nodes[1].manager.heartLedger?.receivedHearts.isEmpty == true,
                "and no ledger row stands behind a judgement that never happened")
        let held = rig.routedIndex(1)?.items.first { $0.key.itemID == gift }
        #expect(held?.chunks.isEmpty == false, """
            while the CIPHERTEXT is held — without this leg the claim above is an absence, and an \
            absence is satisfied by a heart that never arrived at all
            """)

        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.nodes[1].manager.applySessionEvent(.foregrounded)
        }
        rig.pushGateEdge(at: 1)
        try await rig.settle()
        #expect(judged == [gift], "the re-entry judges the held gift EXACTLY once, not twice")
        #expect(rig.nodes[1].manager.heartLedger?.receivedHearts.map(\.id) == [gift],
                "and the ledger holds exactly one row for it")
    }
}

// MARK: - (g) Honesty

/// **Rectangle G is whole, nothing is deferred, and what the battery does NOT claim is named.**
@MainActor
@Suite(.serialized)
struct MeshP6HonestyAcceptanceTests {

    /// **12 of 12, every shape, nothing deferred, every sub-rectangle derived rather than drawn.**
    @Test func theFeatureRectangleIsWholeAndNothingIsDeferred() {
        #expect(MeshRoutedConvergenceMatrix.deferred.isEmpty,
                "a positive claim, not a zero count: nothing may be deferred without its own note")
        let tree = MeshRoutedConvergenceMatrix.featureTree
        #expect(tree.count == 12, "8 seeds on 2/2 plus the root seed on the other four shapes")
        #expect(Set(tree.map(\.shape)) == Set(MeshPartitionShape.matrix),
                "every shape §16.2 names carries a feature cell")
        #expect(tree.allSatisfy { MeshRoutedConvergenceMatrix.all.contains($0) },
                "selected from the rectangle by arithmetic, never drawn beside it")
        #expect(MeshRoutedEventToken.vocabulary.count == 14, """
            the routed vocabulary is fourteen tokens — P5's nine plus P6 item 9's five; a fifteenth \
            needs its own planned draw
            """)
        #expect(MeshP6Acceptance.gatedCorners.count == 2, """
            the age-gate clause runs only cells whose overlay really shut a gate, and it needs two \
            of them — a clause selected down to nothing is green over nothing
            """)
        // The same non-vacuity, for the OTHER selected-by-arithmetic arm (item 9 review, P3-1).
        // Measured at ee4c7de: exactly one of the five cells is asleep, so a re-seed that wakes it
        // would silently retire `aGiftIsJudgedExactlyOnceOnEveryShape`'s `else` branch — the only
        // place the heart's deferred half is asserted across the partition tree — and every
        // remaining assertion would still pass.
        let shapes = MeshP6Acceptance.oneCellPerShape
        let anyAsleep = shapes.contains { !$0.overlay.heartRecipientForegrounded }
        let anyAwake = shapes.contains { $0.overlay.heartRecipientForegrounded }
        #expect(anyAsleep, """
            no cell on the one-per-shape line draws a sleeping recipient, so the deferred arm of \
            the exactly-once claim runs nowhere
            """)
        #expect(anyAwake, "and none draws a waking one, so the judged arm runs nowhere")
        #expect(MeshScheduleBounds.maxFeatureRounds == 2, """
            two feature rounds, and it is an assertion rather than a knob: text-then-heart, \
            heart-then-text and both-in-one-round are all reachable inside two
            """)
    }

    /// **What P6's battery deliberately does NOT claim, named rather than implied.**
    ///
    /// - **The asleep quarter proves the gate's arithmetic, not a product state.** Nothing in
    ///   shipping raises `MeshSessionEvent.backgrounded` or `.foregrounded` — the predicate's own
    ///   source calls the leg inert until P8 — so `heartRecipientForegrounded == false` is driven by
    ///   the state machine directly and no shipping path reaches it yet.
    /// - **The trust-vault rows every heart cell seeds stand in for a second session.** A row
    ///   appears when `pendingFriendReview` completes, which fires at session END, so inside the
    ///   session that produced a heart it cannot exist. Item 10's two-session Lane C script is the
    ///   only honest proof of the feature; this battery proves the ceremony's mechanics.
    /// - **The age gate is product policy re-applied at two points** (the mint and the projection),
    ///   not a cryptographic bound: the ciphertext is held at a gated member and acknowledged.
    /// - **D-4.5 is unasserted:** a heart whose recipient never foregrounds expires `custodied`, and
    ///   this battery neither asserts that nor asserts it away.
    /// - **Item 3's charged-forwarder residual** and **item 8's `MeshRoutedDrainTests` cells** stay
    ///   outside the gated CI line; item 11's close-out owns the second.
    /// - **A process death between a `.dirty` heart accept and its flush double-feeds closeness**
    ///   (item 6's fix review, residual (d), day-capped): no claim here asserts closeness is fed
    ///   exactly once across a restart.
    /// - **An adoption that never receives an admission grant** sits at `.idle` and self-heals via
    ///   descriptor re-broadcast (item 6's fix review, residual (c)), so every heart claim here keys
    ///   on an ADMITTED member and never on "holds a mesh".
    @Test func theBatteryNamesWhatItDoesNotClaim() throws {
        let manager = try MeshP5Acceptance.codeLines(
            of: "FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift"
        ).joined(separator: "\n")
        #expect(manager.contains("sessionState == .activeForeground"), """
            the heart stage's third leg is the session state and nothing weaker — a gate-only \
            predicate would defer the text projection with it
            """)
        let app = try MeshP5Acceptance.codeLines(
            of: "FernletKit/Sources/ProximityKit/Mesh/MeshSessionStateMachine.swift"
        ).joined(separator: "\n")
        #expect(app.contains("case continuingInBackground"),
                "the state the asleep quarter drives, by name")
        #expect(MeshRoutedTypeRegistry.increment1.tokens.count == 3,
                "increment 1 registers three routed types, and a fourth is P7's or later")
    }
}

// MARK: - (h) Determinism

/// **The overlay's seven new fields are in the replayable label, the digests keep their one home,
/// and the batch counter is spelled nowhere item 9 owns.**
///
/// The two literals stay in `MeshP5DeterminismAcceptanceTests` — one home each — and this suite
/// asserts the facts that make the P6 move legitimate rather than copying a constant.
@MainActor
@Suite(.serialized)
struct MeshP6DeterminismAcceptanceTests {

    /// The directory every acceptance battery lives in.
    private static let suiteDirectory = "Tests/FernletTests"

    /// P6's own clause file — the one the digest-pin wall reads, and the one this suite lives in.
    private static let ownFile = "\(suiteDirectory)/MeshP6AcceptanceTests.swift"

    /// The batteries the tree is known to hold — P3, P4, P5, P6 — plus the convergence file item 9
    /// widened. A ratchet: a new phase's battery raises it, and nothing ever lowers it.
    private static let minimumScannedFiles = 5

    /// The files the batch-counter wall scans: every `MeshP*AcceptanceTests.swift` there is, plus
    /// the convergence file item 9 widened.
    ///
    /// **Derived, never listed** (item 9 review, P3-5). A hand-maintained two-element list stops
    /// looking the day a `MeshP7…AcceptanceTests.swift` writes its exactly-once claim against the
    /// batch counter — and that is precisely the file this rule would then be about. The sibling
    /// wall in P5 guards its list with `scanned == files.count`, which catches a file that
    /// disappeared; only enumeration catches one that appeared. The scan's own floor is asserted at
    /// the call site, so a glob that matches nothing is a red rather than a green over zero files.
    ///
    /// - Returns: repo-root-relative paths, in a stable order.
    private static func scannedFiles() throws -> [String] {
        let listed = try FileManager.default
            .contentsOfDirectory(atPath: RepoRoot.url(suiteDirectory).path)
            .filter { $0.hasPrefix("MeshP") && $0.hasSuffix("AcceptanceTests.swift") }
            .sorted()
        return (listed + ["MeshRoutedDrainConvergenceTests.swift"]).map { "\(suiteDirectory)/\($0)" }
    }

    /// The batch counter's spelling, **assembled rather than written**, so this wall's own file does
    /// not trip it. `MeshRoutedHeartAck` forbids comparing the batch field by name; this is that
    /// prohibition made mechanical for the two files P6 item 9 owns.
    private static var batchCounterSpelling: String { ".judge" + "ments" }

    /// The PER-GIFT field's spelling, which is a strict extension of the batch one — so a plain
    /// substring scan would flag every legitimate use of the field the exactly-once claim is
    /// actually written against. Stripped before the scan rather than allow-listed by line, because
    /// the rule is about which FIELD is read and not about which lines read it.
    private static var perGiftSpelling: String { batchCounterSpelling + "ForGift" }

    /// **Every new overlay field reaches `description`, or the digest could not have moved.**
    ///
    /// The named risk (§6.3's sixth): a field appended to the struct but not to the label leaves the
    /// digest byte-identical and the pin passes unchanged — a "moved" digest and an unmoved one are
    /// indistinguishable without this.
    @Test func everyNewOverlayFieldIsInTheReplayableLabel() {
        // R2: bounded by the rectangle's own 40 cells.
        for cell in MeshRoutedConvergenceMatrix.all {
            let overlay = cell.overlay
            let label = overlay.description
            #expect(label.contains("t\(overlay.textOrigin)@\(overlay.textRound)"),
                    "the text fields are missing from the replayable label")
            if let gated = overlay.ageGatedMember {
                #expect(label.contains("gate\(gated)"), "the age-gate field is missing from the label")
            }
            if overlay.plansHeart {
                #expect(
                    label.contains(
                        "h\(overlay.heartOrigin)>\(overlay.heartRecipient)@\(overlay.heartRound)"
                    ),
                    "the heart fields are missing from the replayable label"
                )
            }
            #expect(label.hasSuffix(overlay.heartRecipientForegrounded ? " awake" : " asleep"),
                    "field 15 is missing from the label, so the digest cannot cover it")
        }
    }

    /// **The 40 overlays are still 40 distinct plans**, and the seven new fields did not collapse
    /// them onto each other.
    @Test func theNewFieldsWidenTheRectangleRatherThanCollapsingIt() {
        let labels = Set(MeshRoutedConvergenceMatrix.all.map(\.overlay.description))
        #expect(labels.count == 40, """
            forty cells that produced fewer than forty labels is D-14.2's measured failure again — \
            seed-only salting once collapsed this rectangle to eight distinct plans
            """)
        let overlays = MeshRoutedConvergenceMatrix.all.map(\.overlay)
        #expect(Set(overlays.map(\.textOrigin)).count > 1, "field 9 resolved to one member everywhere")
        #expect(Set(overlays.map(\.heartRecipient)).count > 1,
                "field 13 resolved to one member everywhere")
    }

    /// **The batch counter is spelled nowhere in the two files item 9 owns** (the design check's
    /// R1, taken in its second form).
    ///
    /// `MeshHeartCommitOutcome`'s batch field and `MeshRoutedHeartAck.judgementsForGift` coincide at
    /// every shipping call site, so an invariant written against the batch field would be green for
    /// an accident forever. The fixture-only cell that separates them lives in item 6's own file, so
    /// the count here is a plain ZERO rather than an exactly-named exception.
    @Test func neitherFileItemNineOwnsSpellsTheBatchCounter() throws {
        let needle = Self.batchCounterSpelling
        let files = try Self.scannedFiles()
        #expect(files.count >= Self.minimumScannedFiles, """
            the enumeration matched fewer files than the acceptance batteries that exist, so the \
            wall is scanning a list it derived from nothing
            """)
        #expect(files.contains(Self.ownFile), "and it must include the file this clause lives in")
        var scanned = 0
        // R2: bounded by the derived list, itself bounded by the directory.
        for path in files {
            let lines = try MeshP5Acceptance.codeLines(of: path)
            scanned += 1
            // `Issue.record` rather than an interpolated `#expect` comment (item 9 review, P3-2):
            // the house rule is literal comments, and which FILE tripped is worth keeping.
            if lines.count <= 100 {
                Issue.record("\(path): an empty scan is a wall that stopped looking")
            }
            let offenders = lines.filter {
                $0.replacingOccurrences(of: Self.perGiftSpelling, with: "").contains(needle)
            }
            if !offenders.isEmpty {
                Issue.record("""
                    \(path) spells the BATCH judgement counter: the exactly-once claim must be \
                    written against the per-gift field, never against a counter a one-element batch \
                    makes coincide with it — \(offenders)
                    """)
            }
        }
        // `scanned == files.count` was a tautology — the loop above has no `continue`, no `break`
        // and no early return, and its one escape (a throwing `codeLines`) fails the cell before any
        // expectation is reached (P6 item 9's second fix review, P3-7). The claim worth making is
        // that the DERIVATION really found the batteries, against a number written down here rather
        // than against the list's own length.
        #expect(scanned >= Self.minimumScannedFiles, """
            the derived enumeration opened fewer acceptance-battery files than the tree is known to             hold, so this wall is scanning a list it derived from nothing
            """)
    }

    /// **The two digests keep their one home**, and this suite re-pins neither.
    @Test func theDigestsAreNotRePinnedHere() throws {
        let lines = try MeshP5Acceptance.codeLines(of: Self.ownFile)
        // Assembled, for `batchCounterSpelling`'s reason: a wall that spells its own needle fails
        // itself the day it is written.
        let overlayPin = "pinned" + "OverlayDigest"
        let schedulePin = "pinned" + "ScheduleDigest"
        let pins = lines.filter { $0.contains(overlayPin) || $0.contains(schedulePin) }
        #expect(pins.isEmpty, """
            P6's determinism clause must not carry a second copy of either literal: one home each, \
            in MeshP5DeterminismAcceptanceTests, or a re-pin becomes a two-file edit nobody reviews
            """)
        #expect(MeshScheduleGenerator.routedSalt == 0x524F_5554_4544_0000,
                "the pinned routed salt, unchanged by the appended fields")
        #expect(MeshConvergenceSeeds.root == 0x00F3_2B1C_0009_0002, "and the pinned root seed")
    }

    /// **The partition matrix's ORDER is pinned** (the design check's O1).
    ///
    /// `everyDeclaredShapeIsInTheMatrix` compares SETS, and `routedShapeSalt` reads
    /// `MeshPartitionShape.matrix.firstIndex(of:)` while `scheduleDigest()` iterates in matrix
    /// order — so re-ordering the hand-written arrays moves BOTH digests and silently re-plans all
    /// 40 overlays. The cheapest possible wall on the one change that could do that.
    @Test func thePartitionMatrixOrderIsPinnedBecauseBothDigestsRideIt() {
        #expect(MeshPartitionShape.matrix == [.twoOne, .twoTwo, .threeOne, .threeThree, .fourTwoTwo],
                "re-ordering the shape matrix re-salts every overlay and moves both pinned digests")
        #expect(MeshConvergenceSeeds.family.count == MeshConvergenceSeeds.derivedCount, """
            the seed family is DERIVED from the root by SplitMix64, so it cannot be re-ordered — \
            editing the root or the count is what moves it
            """)
    }
}
