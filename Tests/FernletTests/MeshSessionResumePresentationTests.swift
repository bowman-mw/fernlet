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
@testable import FernletCrypto
@testable import ProximityKit
@testable import Fernlet

/// The presentation table, and the manager's derived read on a fresh manager.
@MainActor
@Suite(.serialized)
struct MeshSessionResumePresentationTests {

    /// A live context inside its ceiling, or one carrying a recorded local ending — and, for the
    /// owner-calls item 3 rows, whether that ending has already been shown.
    private static func context(
        termination: MeshSessionLocalTermination? = nil, endingPresented: Bool = false
    ) -> MeshSessionContext {
        MeshSessionContext(
            meshID: MeshMembershipFixtures.meshID,
            protocolVersion: 3,
            createdAt: MeshMembershipFixtures.base,
            hardDeadline: MeshMembershipFixtures.base.addingTimeInterval(6 * 3_600),
            localTermination: termination,
            endingPresented: endingPresented
        )
    }

    /// The install binding every sealed fixture in the store-backed rows is opened under.
    private static let install = Data(repeating: 0x5A, count: 16)

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

    // MARK: - Owner-calls item 3 (2026-09-22): an ending is news ONCE

    /// An ending the context records as already shown presents nothing — every termination reason
    /// and the expiry — while the same ending unshown still speaks, and the mark gates endings only.
    @Test func anEndingAlreadyShownPresentsNothing() {
        var shown: [MeshSessionRestoreOutcome] = [.expired(Self.context(endingPresented: true))]
        var unshown: [MeshSessionRestoreOutcome] = [.expired(Self.context())]
        // R2: bounded by the frozen reason vocabulary.
        for reason in MeshSessionTerminationReason.allCases {
            let mark = MeshSessionLocalTermination(reason: reason, at: MeshMembershipFixtures.base)
            shown.append(.terminated(Self.context(termination: mark, endingPresented: true), reason))
            unshown.append(.terminated(Self.context(termination: mark), reason))
        }
        #expect(shown.count == 9 && unshown.count == 9, "the expiry plus the eight reasons, each way")
        let silent = shown.allSatisfy { Self.present($0) == .nothing }
        #expect(silent, "an ending already shown is not news at the next launch")
        let spoken = unshown.allSatisfy { if case .previousSessionEnded = Self.present($0) { return true }; return false }
        #expect(spoken, "the same ending unshown still speaks — the mark, not the reason, silenced it")
        #expect(Self.present(.resumable(Self.context(endingPresented: true)), offer: true) == .offerResume,
                "and the mark gates endings only: an offer is not silenced by it")
    }

    /// Restores one sealed context the way a cold start does, under the fixture's install binding.
    private static func launch(_ manager: MeshNetworkManager, now: Date) -> MeshSessionResumePresentation {
        DeviceBindingID.$testOverride.withValue(.identifier(install)) {
            manager.restoreSessionContextAtLaunch(now: now)
            return manager.sessionResumePresentation
        }
    }

    /// Seeds a sealed context this device LEFT, into a node's own store.
    private static func seedOwnDeparture(into store: FernletStore) throws -> UUID {
        let meshID = UUID()
        let base = MeshMembershipFixtures.base
        let left = MeshSessionContext(
            meshID: meshID, protocolVersion: 3, createdAt: base,
            hardDeadline: base.addingTimeInterval(MeshSessionCeiling.ceilingSeconds),
            localTermination: MeshSessionLocalTermination(reason: .ownDeparture, at: base)
        )
        try MeshSessionStoreFixtures.save(left, into: MeshSessionStore(scope: store.meshSessionStorage), install: install)
        return meshID
    }

    /// **The finding's pin.** Two cold starts over ONE sealed `ownDeparture` context, the card
    /// appearing on the first: ONE presentation, not two — and the durable rejoin bar, which the
    /// same file carries, still refuses the mesh at the second launch.
    @Test func anEndingIsPresentedOnceAcrossTwoLaunchesAndTheRejoinBarSurvives() throws {
        let rig = try MeshFoundingRig.build(1, label: "resume-once")
        defer { rig.teardown() }
        let node = rig.nodes[0]
        let meshID = try Self.seedOwnDeparture(into: node.store)
        let now = MeshMembershipFixtures.base.addingTimeInterval(60)
        var presentations: [MeshSessionResumePresentation] = []
        // R2: two launches, stated.
        for _ in 0..<2 {
            let presented = Self.launch(node.manager, now: now)
            guard presented != .nothing else { continue }
            presentations.append(presented)
            // What the card's appearance does.
            DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
                node.manager.acknowledgeSessionEndingPresented()
            }
        }
        #expect(presentations == [.previousSessionEnded(.youLeft)],
                "the ending is told once — the second cold start is silent, not a second 'You left'")
        #expect(node.manager.rejoinRefusal(for: meshID) == .ownDeparture,
                "and the mesh this device left is still barred: the mark silenced the card, not the bar")
    }

    /// The mark is written by the card APPEARING, not by the restore: a launch whose Friends tab was
    /// never opened leaves the ending unshown, so the next launch still tells it.
    @Test func anEndingNeverShownIsToldAgainAtTheNextLaunch() throws {
        let rig = try MeshFoundingRig.build(1, label: "resume-unseen")
        defer { rig.teardown() }
        let node = rig.nodes[0]
        _ = try Self.seedOwnDeparture(into: node.store)
        let now = MeshMembershipFixtures.base.addingTimeInterval(60)
        let first = Self.launch(node.manager, now: now)
        let second = Self.launch(node.manager, now: now)
        #expect(first == .previousSessionEnded(.youLeft), "the first launch tells it")
        #expect(second == .previousSessionEnded(.youLeft), "and, never shown, so does the next — nothing was lost")
    }

    /// An offer is never marked: acknowledging while a live context is on offer writes nothing, so
    /// the one-shot mark cannot leak onto a session the person may still resume.
    @Test func anOfferIsNeverMarkedAsShown() throws {
        let rig = try MeshFoundingRig.build(1, label: "resume-offer")
        defer { rig.teardown() }
        let node = rig.nodes[0]
        let sessionStore = MeshSessionStore(scope: node.store.meshSessionStorage)
        let base = MeshMembershipFixtures.base
        let live = MeshSessionContext(
            meshID: UUID(), protocolVersion: 3, createdAt: base,
            hardDeadline: base.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        try MeshSessionStoreFixtures.save(live, into: sessionStore, install: Self.install)
        let presented = Self.launch(node.manager, now: base.addingTimeInterval(60))
        #expect(presented != .previousSessionEnded(.youLeft), "a live context is not an ending")
        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            node.manager.acknowledgeSessionEndingPresented()
        }
        let reread = DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) { sessionStore.load() }
        guard case .loaded(let context, _) = reread else {
            Issue.record("Expected the live context back, got \(reread)")
            return
        }
        #expect(!context.endingPresented, "the acknowledgement wrote nothing for a non-ending")
    }

    /// Decode compatibility: a schema-3 file written before the mark existed decodes as NOT yet
    /// shown — the conservative direction, one more telling and then the mark — and the mark
    /// survives a round trip. No schema bump: `localTermination`'s precedent.
    @Test func aContextWrittenBeforeTheMarkDecodesAsNotYetShown() throws {
        let marked = Self.context(
            termination: MeshSessionLocalTermination(reason: .ownDeparture, at: MeshMembershipFixtures.base),
            endingPresented: true
        )
        let bytes = try JSONEncoder().encode(marked)
        let roundTrip = try JSONDecoder().decode(MeshSessionContext.self, from: bytes)
        #expect(roundTrip.endingPresented && roundTrip == marked, "the mark survives the round trip")
        var object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object.removeValue(forKey: "endingPresented") != nil, "the key is on the wire to be stripped")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MeshSessionContext.self, from: legacy)
        #expect(decoded.schemaVersion == 3, "still schema 3 — additive, not a bump")
        #expect(!decoded.endingPresented, "a file from before the mark reads as not yet shown")
        #expect(decoded.localTermination == marked.localTermination, "and everything beside it is intact")
    }

    /// A fresh manager has attempted no restore and presents nothing.
    @Test func aFreshManagerPresentsNothing() throws {
        let rig = try MeshFoundingRig.build(1, label: "resume-fresh")
        defer { rig.teardown() }
        #expect(rig.nodes[0].manager.sessionResumePresentation == .nothing,
                "no restore attempted, nothing to present — the derived read agrees with the table")
    }
}
