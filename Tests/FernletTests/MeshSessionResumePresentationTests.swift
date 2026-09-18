// MeshSessionResumePresentationTests.swift
// FernletTests
//
// Network migration P7 item 5: the resume surface's decision as a table over every
// `MeshSessionRestoreOutcome` case — the pure half the launcher asked for, so the surface is a
// screenshot's worth of `switch` and not a claim only a launch can reach. Contexts are the
// state-machine suite's fixture shape (`MeshSessionRestoreMappingTests.liveContext`), stated
// instants only.

import Foundation
import Testing
@testable import ProximityKit
@testable import Fernlet

/// The presentation table, and the manager's derived read on a fresh manager.
@MainActor
@Suite(.serialized)
struct MeshSessionResumePresentationTests {

    /// A live context inside its ceiling, or one carrying a recorded local ending.
    private static func context(termination: MeshSessionLocalTermination? = nil) -> MeshSessionContext {
        MeshSessionContext(
            meshID: MeshMembershipFixtures.meshID,
            protocolVersion: 3,
            createdAt: MeshMembershipFixtures.base,
            hardDeadline: MeshMembershipFixtures.base.addingTimeInterval(6 * 3_600),
            localTermination: termination
        )
    }

    /// The decision, shortened.
    private static func present(
        _ outcome: MeshSessionRestoreOutcome?, offer: Bool = false, inSession: Bool = false
    ) -> MeshSessionResumePresentation {
        MeshSessionResumePresentation.presentation(
            outcome: outcome, offersForegroundResume: offer, isInSession: inSession
        )
    }

    /// Every outcome case once, for the rows that sweep them.
    private static func everyOutcome() -> [MeshSessionRestoreOutcome] {
        var outcomes: [MeshSessionRestoreOutcome] = [
            .resumable(context()),
            .expired(context()),
            .noSession,
            .retryAfterUnlock(MeshSessionDeferral(reason: .fileUnreadable, detail: "x")),
            .retryAfterRefusal(MeshSessionSealRefusal(operation: .open, cause: .installBindingUnavailable)),
            .quarantineCorruptFile(MeshSessionCorruption(detail: .emptyFile))
        ]
        // R2: bounded by the frozen reason vocabulary.
        for reason in MeshSessionTerminationReason.allCases {
            outcomes.append(.terminated(context(termination: MeshSessionLocalTermination(reason: reason, at: MeshMembershipFixtures.base)), reason))
        }
        return outcomes
    }

    /// A resumable context is offered only while the state machine's foreground offer is raised.
    @Test func aResumableContextIsOfferedOnlyWhileTheOfferIsRaised() {
        #expect(Self.present(.resumable(Self.context()), offer: true) == .offerResume,
                "a live context with the offer raised is an offer")
        #expect(Self.present(.resumable(Self.context()), offer: false) == .nothing,
                "the same context once the offer was consumed is nothing to say")
    }

    /// Each of the eight frozen reasons folds to its ending, and a passed ceiling is expired.
    @Test func everyTerminationReasonFoldsToItsEnding() {
        let folds: [(MeshSessionTerminationReason, MeshSessionEndingPresentation)] = [
            (.ownDeparture, .youLeft), (.removedFromRoster, .youWereRemoved),
            (.hardDeadlineSigned, .expired), (.hardDeadlineMonotonic, .expired),
            (.verifiedTerminationRecord, .ended), (.finalPairTermination, .ended),
            (.epochCounterExhausted, .ended), (.developed, .ended)
        ]
        #expect(folds.count == MeshSessionTerminationReason.allCases.count, "every frozen reason has a row")
        // R2: bounded by the frozen reason vocabulary.
        for (reason, ending) in folds {
            let context = Self.context(termination: MeshSessionLocalTermination(reason: reason, at: MeshMembershipFixtures.base))
            #expect(Self.present(.terminated(context, reason)) == .previousSessionEnded(ending),
                    "a recorded ending is presented as ended, by how")
            #expect(reason.presentation == ending, "and the fold itself agrees")
        }
        #expect(Self.present(.expired(Self.context())) == .previousSessionEnded(.expired),
                "a ceiling that passed while the process was gone is expired")
    }

    /// A green field, a deferral and a refusal are silent — the re-entry retries the last two at
    /// the next protected-data rise, and a launch on a locked device is not news.
    @Test func theSilentOutcomesPresentNothing() {
        #expect(Self.present(nil) == .nothing, "no restore attempted yet")
        #expect(Self.present(.noSession) == .nothing, "a green field")
        #expect(Self.present(.retryAfterUnlock(MeshSessionDeferral(reason: .fileUnreadable, detail: "x")), offer: true) == .nothing,
                "a deferral is silent even if an offer were somehow raised")
        #expect(Self.present(.retryAfterRefusal(MeshSessionSealRefusal(operation: .open, cause: .installBindingUnavailable))) == .nothing,
                "and so is a refusal")
    }

    /// A file that does not decode was set aside deliberately, and the person is told so.
    @Test func aSetAsideFileSaysItCouldNotBeReopened() {
        #expect(Self.present(.quarantineCorruptFile(MeshSessionCorruption(detail: .emptyFile)))
                == .previousSessionCouldNotBeReopened, "the set-aside file is named as such")
    }

    /// A session surface up presents nothing, whatever the last restore concluded.
    @Test func aSessionSurfaceUpPresentsNothingWhateverTheOutcome() {
        let outcomes = Self.everyOutcome()
        #expect(outcomes.count == 14, "six shapes plus the eight terminations")
        let silent = outcomes.allSatisfy { Self.present($0, offer: true, inSession: true) == .nothing }
        #expect(silent, "the live session owns the tab")
        let spoken = outcomes.filter { Self.present($0, offer: true) != .nothing }.count
        #expect(spoken == 11, "off a session, the offer, the set-aside, the expiry and the eight endings all speak")
    }

    /// A fresh manager has attempted no restore and presents nothing.
    @Test func aFreshManagerPresentsNothing() throws {
        let rig = try MeshFoundingRig.build(1, label: "resume-fresh")
        defer { rig.teardown() }
        #expect(rig.nodes[0].manager.sessionResumePresentation == .nothing,
                "no restore attempted, nothing to present — the derived read agrees with the table")
    }
}
