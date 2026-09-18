// MeshSessionPollTests.swift
// FernletTests
//
// Network migration P7 item 4: the poll seam and the joiner-side ceiling arm, driven on the
// founding rig (`MeshFoundingRig`, `MeshPairwiseFoundingTests.swift`) with stated instants — no
// clock is read, no timer runs; the app's timer is `ProximitySessionPollerTests`' subject.
//
// The headline is P6 §12.3 finding 3 closed: a yielding founder — and every proximity joiner —
// held a mesh with no session ceiling because `startSessionCeiling` had only the founder and the
// launch restore as callers and `enforceSessionCeiling` had no shipping caller at all. Now the
// adoption arms the deadline every member shares, and one poll past it ends the session.

import Foundation
import Testing
@testable import FernletCrypto
@testable import ProximityKit
@testable import Fernlet

/// The poller's ProximityKit half: the order, the short circuit, and the ceiling every member holds.
@MainActor
@Suite(.serialized)
struct MeshSessionPollTests {

    /// A stated instant for the idle rig; nothing here reads a clock.
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// A poll under the founding rig's pinned install binding, so a persisting effect — the
    /// ceiling's termination mark — is written rather than refused (the rig pins every commit and
    /// pump the same way).
    private static func poll(_ manager: MeshNetworkManager, now: Date) async -> MeshSessionPollReport {
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await manager.pollSession(now: now)
        }
    }

    /// P6 §12.3 finding 3, closed: the yielding half of a symmetric founding arms a ceiling from
    /// the adopted mesh — the winner's own signed deadline — and a poll past it ends the session.
    @Test func aYieldingFounderHoldsACeilingAndThePollEnforcesIt() async throws {
        let rig = try MeshFoundingRig.build(2, label: "poll-yield")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle(until: { rig.roster(0).count == 2 && rig.roster(1).count == 2 })
        let lowerFounds = MeshNetworkManager.foundsPairwiseMesh(
            local: rig.identities[0].localFingerprint, peer: rig.identities[1].localFingerprint
        )
        let winner = rig.nodes[lowerFounds ? 0 : 1].manager
        let yielder = rig.nodes[lowerFounds ? 1 : 0].manager
        let ceiling = try #require(yielder.sessionCeiling, "the yielder arms a ceiling from the adopted mesh")
        let winnerCeiling = try #require(winner.sessionCeiling, "the winner armed its own at the founding")
        #expect(ceiling.hardDeadline == winnerCeiling.hardDeadline,
                "the same signed deadline on both sides — createdAt + 6 h, the one every member shares")
        #expect(yielder.isSessionLive, "and the session is live")

        let early = await Self.poll(yielder, now: ceiling.hardDeadline.addingTimeInterval(-3600))
        #expect(early.polled && !early.ceilingReached && early.sessionLiveAfter,
                "an hour before the deadline the poll runs and ends nothing")
        #expect(yielder.isSessionLive, "the session is still live")

        let late = await Self.poll(yielder, now: ceiling.hardDeadline.addingTimeInterval(3600))
        #expect(late.polled && late.ceilingReached, "an hour past the deadline the ceiling is reached")
        #expect(!late.sessionLiveAfter && !yielder.isSessionLive,
                "and the yielder's session ended there — the residual is closed")
        #expect(!late.idleLapsed && !late.partitionMoved,
                "the ceiling ended the poll: idle lapse and partition were not judged after it (the order)")
        let after = await Self.poll(yielder, now: ceiling.hardDeadline.addingTimeInterval(7200))
        #expect(after == .skipped, "and a poll over the ended session runs nothing — the timer's stop condition")
    }

    /// A device with no session polls nothing, and the arm refuses with no mesh.
    @Test func aPollWithNoLiveSessionRunsNothing() async throws {
        let rig = try MeshFoundingRig.build(1, label: "poll-idle")
        defer { rig.teardown() }
        let manager = rig.nodes[0].manager
        #expect(!manager.isSessionLive, "a fresh manager holds no session")
        let report = await Self.poll(manager, now: Self.epoch)
        #expect(report == .skipped, "no session: no consumer runs, nothing to report")
        #expect(!report.polled && !report.sessionLiveAfter, "and both flags say so")
        #expect(!manager.armSessionCeilingFromAdoptedMeshIfNeeded(now: Self.epoch), "the arm refuses with no mesh")
        #expect(manager.sessionCeiling == nil, "and arms nothing")
    }

    /// The arm is idempotent: the founder's own ceiling is kept, origin and deadline alike.
    @Test func theAdoptedMeshArmKeepsAnArmedCeiling() async throws {
        let rig = try MeshFoundingRig.build(2, label: "poll-arm")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle(until: { rig.roster(0).count == 2 && rig.roster(1).count == 2 })
        let lowerFounds = MeshNetworkManager.foundsPairwiseMesh(
            local: rig.identities[0].localFingerprint, peer: rig.identities[1].localFingerprint
        )
        let winner = rig.nodes[lowerFounds ? 0 : 1].manager
        let before = try #require(winner.sessionCeiling?.hardDeadline)
        #expect(!winner.armSessionCeilingFromAdoptedMeshIfNeeded(now: Self.epoch),
                "a ceiling already armed is kept — re-arming would reset the monotonic origin")
        #expect(winner.sessionCeiling?.hardDeadline == before, "and its deadline did not move")
    }
}
