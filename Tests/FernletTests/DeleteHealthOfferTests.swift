// DeleteHealthOfferTests.swift
// FernletTests
//
// Round 2026-08-20 Part 4.1c: the most privacy-conscious user got the least deletion. "Delete
// everything" offered its SECOND button — delete the entries Fernlet wrote to Apple Health too —
// only while `healthKitMasterEnabled` was on. A user who turned the Health master toggle off kept
// every sexual-activity and menstrual-flow sample Fernlet had already written, with no in-app route
// to remove them, because turning the integration off does not retract what was written. The offer
// now also keys off the persisted capability ledger (Part 4.1a), and the dialog copy has to stay
// truthful in the state that opens up: integration off, samples possibly still in Health.
//
// The ledger answer is INJECTED (`everRequestedWritableHealthCapability`) rather than seeded on the
// real keychain slot: `HealthKitService.disableIntegration()` and the wipe both clear the production
// row, so a fixture written there would be deleted mid-test by any concurrently running suite.

import Foundation
import SwiftUI
import Testing
import FernletFoundation
@testable import Fernlet

@MainActor
struct DeleteHealthOfferTests {

    /// Builds the dialog exactly as both Settings entry points do, with the ledger answer injected.
    private func confirmation(healthOn: Bool, everWroteToHealth: Bool) -> DestructiveConfirmation {
        DeleteEverythingFlow().makeConfirmation(
            preferences: StoragePreferences(healthKitMasterEnabled: healthOn),
            store: makeTestStore(),
            everRequestedWritableHealthCapability: everWroteToHealth
        )
    }

    /// The dialog body for one offer state, without standing up a store — the copy is what is asserted.
    ///
    /// Calls the copy BUILDER rather than reading `.message` off the built dialog: since review
    /// T2-1 the dialog's body is a `Text` (THIS dialog — the only one of the 26 — assembles its from conditional
    /// fragments, so it cannot be a single catalog key), and a `Text` cannot be read back out.
    private func message(for offer: DeleteAllDataConfirmation.HealthSampleOffer) -> String {
        DeleteAllDataConfirmation.message(
            healthSamples: offer,
            hasICloudDayCopy: false,
            hasSealedBackup: false
        )
    }

    // MARK: - The offer

    /// The finding itself: Health off, but Fernlet was prompted for a write-capable capability, so
    /// samples it authored may sit in Apple Health. Before this round this produced one "Delete"
    /// button and the samples stayed.
    @Test func healthOffWithAuthoredSamplesStillOffersTheHealthDelete() {
        let action = confirmation(healthOn: false, everWroteToHealth: true)

        #expect(action.confirmLabel == "Delete, keep Health")
        #expect(action.secondaryConfirm != nil, "the toggle-off user is offered no way to delete Fernlet's Health entries")
        #expect(action.secondaryConfirm?.label == "Delete, and from Health")
        // Frozen audit token — the log must still record WHICH irreversible choice was made.
        #expect(action.secondaryConfirm?.auditEvent == "settings.deleteAll.withHealthSamplesConfirmed")
        #expect(action.auditEvent == "settings.deleteAll.confirmed")
    }

    /// The pre-existing case must not regress, and must not start depending on the ledger: an
    /// integrated user is offered the choice even with nothing recorded (a ledger read that failed,
    /// or a prompt shown before the ledger existed).
    @Test func healthOnOffersTheHealthDeleteWithoutTheLedger() {
        let action = confirmation(healthOn: true, everWroteToHealth: false)

        #expect(action.confirmLabel == "Delete, keep Health")
        #expect(action.secondaryConfirm?.label == "Delete, and from Health")
    }

    /// Neither signal: Fernlet has no record of ever being prompted for a capability that writes, so
    /// there is nothing of its own in Health and the question would be noise. One outcome, not two.
    @Test func neitherSignalMeansNoHealthOffer() {
        let action = confirmation(healthOn: false, everWroteToHealth: false)

        #expect(action.secondaryConfirm == nil, "a keep-vs-delete question about Health Fernlet never wrote to")
    }

    /// The single-button copy: when Health was never involved the primary button stays the plain
    /// "Delete" — "Delete, keep Health" beside no second button would name a choice that isn't offered.
    @Test func noHealthInvolvementKeepsThePlainDeleteLabel() {
        #expect(confirmation(healthOn: false, everWroteToHealth: false).confirmLabel == "Delete")
    }

    // MARK: - The copy that has to stay truthful

    /// The toggle-off paragraph must say what Fernlet wrote is still there AND that the deletion works
    /// without re-enabling Health — the old copy sent this user back to a switch they deliberately
    /// turned off, for a delete that never needed it. "Anything Fernlet wrote", not "the entries
    /// Fernlet wrote": the ledger records a prompt, not a write, so the hedge is load-bearing.
    @Test func toggleOffCopySaysTheSamplesRemainAndFernletCanStillReachThem() {
        let body = message(for: .integrationOff)

        #expect(body.contains("anything Fernlet wrote to Apple Health before that is still in Apple Health"))
        #expect(body.contains("Fernlet can still delete it"))
        #expect(body.contains("you don't have to turn Health back on"))
        // The one case the offer cannot honour is named rather than papered over: revoked share
        // access comes back `.accessRevoked` and lands in the failure alert.
        #expect(body.contains("Health access away"))
    }

    /// The no-record paragraph stays a hedge and keeps the Health-app route. A flat "Fernlet has never
    /// written anything to Apple Health" would be the one sentence here the code cannot back up: the
    /// ledger errs toward forgetting, so an unreadable row reads as never-requested.
    @Test func noRecordCopyHedgesAndKeepsTheHealthAppRoute() {
        let body = message(for: .nothingAuthored)

        #expect(body.contains("no record of writing anything to Apple Health"))
        #expect(body.contains("Health app"))
    }

    /// The integrated copy is unchanged, and every state still closes with the "only its own" limit —
    /// no app can delete another app's samples, and the dialog must never imply otherwise.
    @Test func everyStateThatOffersTheDeleteStatesTheOnlyItsOwnLimit() {
        #expect(message(for: .integrationOn).contains("It can only ever delete its own"))
        #expect(message(for: .integrationOff).contains("It can only ever delete its own"))
    }
}
