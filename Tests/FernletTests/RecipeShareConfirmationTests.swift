// RecipeShareConfirmationTests.swift
// FernletTests
//
// The recipe share sheet's confirmation (owner request 2026-09-29: "for sharing recipes, there
// should be a confirmation screen that pops up. Right now it just clears and makes the user
// uncertain if anything was shared or if they need to retry").
//
// Three pure pieces, pinned here without a radio:
//
//  * `RecipeShareConfirmation` — the mapping from ProximityKit's frozen `RecipeShareOutcome` to the
//    panel's words. The cells resolve every sentence (the keys are not in the catalog until the
//    integration sync, so `String(localized:)` answers the English default) and pin the HONESTY of
//    the copy: the sender can only ever know "sent" (handed to the transport; there is no receipt),
//    so no success sentence may say delivered / received / accepted / saved, nor say what the other
//    person can now do except on the condition that it reached them, and "may not have it" must
//    never be merged with "nothing was sent".
//  * `RecipeShareOutcomeLatch` — the rule that a published outcome becomes a panel only for a share
//    the sheet began, for the tapped row, once. It is what keeps a CANCELLED share (Done or a swipe
//    down, whose teardown publishes `interrupted`) from raising anything.
//  * `RecipeShareRadioCustody` / `RecipeShareRadioHandBack` — the drain rule: after a successful
//    send the radio is kept for the hand back's delay whatever the sheet does, so a Done tapped the
//    moment the panel appears cannot stop it early; then the hand back stands it down for its own
//    share only, and restarts passive listening only when it is wanted.
//
// The manager half (which outcome each path publishes) is in ProximityRecipeShareCapTests.

import Foundation
import Testing
import FernletUI
import ProximityKit
@testable import Fernlet

@MainActor
struct RecipeShareConfirmationTests {

    private nonisolated static let rowID = UUID()

    /// An outcome for the fixture row: "Banana bread" to "Blair".
    private func outcome(
        _ result: RecipeShareOutcome.Result,
        recipientID: UUID = rowID,
        otherPeerName: String? = nil
    ) -> RecipeShareOutcome {
        RecipeShareOutcome(
            recipientID: recipientID,
            recipientName: "Blair",
            recipeTitle: "Banana bread",
            otherPeerName: otherPeerName,
            result: result
        )
    }

    /// The English a resource resolves to.
    private func words(_ resource: LocalizedStringResource) -> String {
        String(localized: resource)
    }

    /// Every sentence a confirmation can put in front of the user, resolved.
    private func allWords(_ confirmation: RecipeShareConfirmation) -> [String] {
        [confirmation.headline, confirmation.detail, confirmation.announcement].map(words)
    }

    // MARK: - Mapping

    @Test func everyFailureIsARetryableErrorWithASentenceOfItsOwn() {
        var details: [RecipeShareFailure: String] = [:]
        for failure in RecipeShareFailure.allCases {
            let confirmation = RecipeShareConfirmation(outcome(.notSent(failure)))
            #expect(confirmation.tone == .notSent, "\(failure)")
            #expect(confirmation.offersRetry, "\(failure) must offer Try again")
            #expect(confirmation.announcementKind == .error, "\(failure)")
            let detail = words(confirmation.detail)
            #expect(!detail.isEmpty, "\(failure) has no sentence")
            details[failure] = detail
        }
        #expect(Set(details.values).count == RecipeShareFailure.allCases.count,
                "two causes share one sentence, so the panel cannot tell the user which happened")
    }

    @Test func aSentShareIsASuccessWithNoRetryAndItsOwnHeadline() {
        let sent = RecipeShareConfirmation(outcome(.sent))

        #expect(sent.tone == .sent)
        #expect(!sent.offersRetry)
        #expect(sent.announcementKind == .success)
        let failureHeadlines = RecipeShareFailure.allCases.map {
            words(RecipeShareConfirmation(outcome(.notSent($0))).headline)
        }
        #expect(!failureHeadlines.contains(words(sent.headline)))
    }

    /// The honesty ceiling. `sent` is a transport hand-off with no receipt behind it, so the success
    /// panel must name the person and the recipe and claim nothing stronger than "sent".
    ///
    /// Two lists, because an overclaim does not need the word "received": "Blair can look it over"
    /// asserts the recipe is on Blair's phone just as surely, and the receiving side drops some
    /// shares without a word back (a mismatched version, a full review queue, its per-sender rate
    /// limit). So the copy may say what the other person can do only on the condition that it
    /// reached them.
    @Test func theSuccessCopySaysSentAndNothingStronger() {
        let sent = RecipeShareConfirmation(outcome(.sent))

        let overclaims = ["deliver", "received", "accepted", "saved", "arrived", "reached them",
                          "look it over", "has it", "have it", "will see", "can see", "got it"]
        let receiverStateClaims = ["blair can", "blair will", "blair has", "blair is", "they can",
                                   "they will", "they have"]
        for sentence in allWords(sent) {
            let lowered = sentence.lowercased()
            for overclaim in overclaims {
                #expect(!lowered.contains(overclaim), "\"\(sentence)\" claims \(overclaim)")
            }
            for clause in lowered.split(separator: ".") {
                for claim in receiverStateClaims where clause.contains(claim) {
                    #expect(clause.contains("if it reaches"),
                            "\"\(clause)\" says what the other person can do, as if the recipe arrived")
                }
            }
        }
        #expect(words(sent.headline).contains("Blair"))
        #expect(words(sent.detail).contains("Blair") && words(sent.detail).contains("Banana bread"))
        #expect(words(sent.announcement).contains("Blair") && words(sent.announcement).contains("Banana bread"))
    }

    /// "They may have it" and "nothing was sent" are different facts, and a single "didn't send"
    /// would tell someone whose recipe DID go out that it did not.
    @Test func mayHaveItIsNeverMergedWithNothingWasSent() {
        for failure in RecipeShareFailure.allCases {
            let detail = words(RecipeShareConfirmation(outcome(.notSent(failure))).detail).lowercased()
            if failure.mayHaveReachedRecipient {
                #expect(detail.contains("may not have it"), "\(failure): \(detail)")
                #expect(!detail.contains("nothing"), "\(failure) says nothing was sent, but it may have been")
            } else {
                #expect(detail.contains("nothing"), "\(failure) must say nothing was sent: \(detail)")
            }
        }
        #expect(RecipeShareFailure.allCases.filter(\.mayHaveReachedRecipient) == [.sendIncomplete])
    }

    /// Every failure names both halves somewhere the user reads or hears it: the recipe and the person.
    @Test func everyFailureNamesTheRecipeAndThePerson() {
        for failure in RecipeShareFailure.allCases {
            let confirmation = RecipeShareConfirmation(outcome(.notSent(failure)))
            let spoken = words(confirmation.announcement)
            #expect(spoken.contains("Banana bread") && spoken.contains("Blair"), "\(failure): \(spoken)")
            #expect(words(confirmation.detail).contains("Blair"), "\(failure) does not name the person")
        }
        let nothingWent = RecipeShareConfirmation(outcome(.notSent(.noAnswer)))
        #expect(words(nothingWent.headline).contains("Banana bread"))
    }

    @Test func theCapRefusalNamesWhoHoldsTheLinkAndStillReadsWithoutIt() {
        let named = words(RecipeShareConfirmation(
            outcome(.notSent(.pairedWithAnother), otherPeerName: "Alex")).detail)
        #expect(named.contains("Alex") && named.contains("Blair"))

        for missing in [nil, ""] as [String?] {
            let unnamed = words(RecipeShareConfirmation(
                outcome(.notSent(.pairedWithAnother), otherPeerName: missing)).detail)
            #expect(unnamed.contains("another Fernlet") && unnamed.contains("Blair"), "\(unnamed)")
        }
    }

    // MARK: - Latch
    //
    // Every mutating call is made on its own line and its result asserted afterwards: the testing
    // macros expand their argument inside a closure, where the latch would be immutable.

    @Test func anOutcomeNobodyBeganHereRaisesNothing() {
        var latch = RecipeShareOutcomeLatch()

        let raised = latch.receive(outcome(.notSent(.interrupted)))

        #expect(raised == nil, "a closing sheet's own teardown publishes `interrupted`; it must not pop up")
        #expect(latch.confirmation == nil)
    }

    @Test func anOutcomeForADifferentRowIsIgnored() {
        var latch = RecipeShareOutcomeLatch()
        latch.beganShare(to: Self.rowID)

        let stranger = latch.receive(outcome(.sent, recipientID: UUID()))
        #expect(stranger == nil)
        #expect(latch.confirmation == nil)

        let awaited = latch.receive(outcome(.sent))
        #expect(awaited != nil, "and the awaited row still latches afterwards")
    }

    @Test func aShareLatchesOnceUntilTryAgain() throws {
        var latch = RecipeShareOutcomeLatch()
        latch.beganShare(to: Self.rowID)
        let latched = latch.receive(outcome(.notSent(.noAnswer)))
        let first = try #require(latched)

        let second = latch.receive(outcome(.notSent(.couldNotConnect)))

        #expect(second == nil, "a second outcome must not replace the panel")
        #expect(latch.confirmation == first)
    }

    /// The partial-failure-then-recovery path the owner described: it failed, they tried again, it went.
    @Test func aFailureThenTryAgainThenSentEndsOnTheSentPanel() throws {
        var latch = RecipeShareOutcomeLatch()
        latch.beganShare(to: Self.rowID)
        let failed = latch.receive(outcome(.notSent(.sendIncomplete)))
        #expect(failed?.offersRetry == true)

        let retriedRow = latch.retry()
        let retried = try #require(retriedRow)
        #expect(retried == Self.rowID)
        #expect(latch.confirmation == nil)
        let early = latch.receive(outcome(.sent))
        #expect(early == nil, "retry alone waits for nothing until the re-send begins")

        latch.beganShare(to: retried)
        let resent = latch.receive(outcome(.sent))
        let final = try #require(resent)
        #expect(final.tone == .sent)
        let retryAfterSuccess = latch.retry()
        #expect(retryAfterSuccess == nil, "a success offers no Try again")
        #expect(latch.confirmation == final)
    }

    @Test func resetForgetsTheShareAndThePanel() {
        var latch = RecipeShareOutcomeLatch()
        latch.beganShare(to: Self.rowID)
        let latched = latch.receive(outcome(.notSent(.noAnswer)))
        #expect(latched != nil)

        latch.reset()
        #expect(latch.confirmation == nil)
        #expect(latch.awaitingRecipientID == nil)

        latch.beganShare(to: Self.rowID)
        latch.reset()
        let afterCancel = latch.receive(outcome(.sent))
        #expect(afterCancel == nil, "a share cancelled by closing the sheet raises nothing")
    }

    // MARK: - Radio hand back
    //
    // The drain rule: a text recipe's frame is handed to QUIC when the send returns, and stopping the
    // radio tears the tunnel down with whatever has not drained. The panel's Done appears at exactly
    // that moment, so the sheet's disappearance must not be what stops the radio inside the window.

    /// The sheet holds custody from appear, so a cancel (Done before any send) still stops the radio
    /// and restarts passive listening, exactly as before.
    @Test func theSheetStopsTheRadioOnDisappearUntilASendSucceeds() {
        let custody = RecipeShareRadioCustody.sheet

        #expect(custody.sheetStopsRadioOnDisappear)
    }

    /// C-F1: once a send succeeds, custody moves to the hand back, so a Done tapped the moment the
    /// panel appears closes the sheet WITHOUT stopping the radio; the hand back does that after the
    /// delay, on its own clock.
    @Test func aSuccessfulSendMovesCustodySoAnEarlyDoneLeavesTheRadioAlone() throws {
        var custody = RecipeShareRadioCustody.sheet
        let outcomeID = UUID()

        let handedOff = custody.handOff(afterSendOf: outcomeID)
        let handBack = try #require(handedOff)

        #expect(handBack.outcomeID == outcomeID)
        #expect(!custody.sheetStopsRadioOnDisappear, "the sheet's disappearance would cut an undrained frame")
        #expect(custody == .handBack(handBack))

        let again = custody.handOff(afterSendOf: UUID())
        #expect(again == nil, "one hand back per custody; a second success must not reschedule it")
        #expect(custody == .handBack(handBack))
    }

    /// The window is never shorter than the post-send pairing lifetime the old auto-dismiss gave.
    @Test func theHandBackWaitsAtLeastThePostSendPairingLifetime() {
        #expect(RecipeShareRadioHandBack.delay >= .milliseconds(1_400))
    }

    /// When the delay has passed: stop, then listen again only when it is wanted, for the share it
    /// followed; a newer share (its outcome cleared or replaced) or a delete-all is left alone.
    @Test func theHandBackActsOnlyForItsOwnShareAndListensOnlyWhenWanted() {
        let own = UUID()
        let handBack = RecipeShareRadioHandBack(outcomeID: own)

        #expect(handBack.step(currentOutcomeID: own, listeningWanted: true) == .stopAndListen)
        #expect(handBack.step(currentOutcomeID: own, listeningWanted: false) == .stop,
                "not wanted (backgrounded, opted out, locked, off a recipe tab): stand down, start nothing")
        #expect(handBack.step(currentOutcomeID: nil, listeningWanted: true) == .leaveAlone,
                "a newer share cleared the outcome, or a delete-all did: its owner has the radio")
        #expect(handBack.step(currentOutcomeID: UUID(), listeningWanted: true) == .leaveAlone,
                "a newer share's outcome: stopping now would cut THAT share's drain")
    }
}
