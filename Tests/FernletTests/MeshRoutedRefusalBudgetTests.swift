// MeshRoutedRefusalBudgetTests.swift
// FernletTests
//
// The P5 review's finding 3, closing D-12.14: routed content frames refused BEFORE any store verb
// were replayable without bound by a committed member — the replay window records only a
// `.completed` outcome on a verified author, and every pre-store refusal (a verifier rejection,
// `notADestinationOrHandoff`, `unknownItemNotFromOrigin`, `unregisteredTypeChunk`, an undecodable
// frame) costs an Ed25519 verify or a sealed-index load. `MeshRoutedRefusalBudget` bounds them per
// authenticated envelope sender; this file is its decision table, one real cell through the drain's
// own dispatch door, and the wall that keeps every refusal exit on the one charging door.
//
// The audit log is process-global and suites run in parallel, so every claim about a logged line is
// a containment claim; the per-instance budget on the receiving manager is the exact witness.

import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
@testable import ProximityKit
@testable import Fernlet

/// The pre-store refusal budget: its table, its one drain cell, and its source wall.
@MainActor
@Suite(.serialized)
struct MeshRoutedRefusalBudgetTests {

    // MARK: - The value

    /// The transition is reported exactly once, and only at the cap.
    @Test func theCapIsReportedOnceAndOnlyAtTheCap() {
        var budget = MeshRoutedRefusalBudget(cap: 3, maxSenders: 2)
        #expect(!budget.isSpent("a"))
        #expect(budget.charge("a") == .charged)
        #expect(budget.charge("a") == .charged)
        #expect(!budget.isSpent("a"), "two of three is not spent")
        #expect(budget.charge("a") == .spent, "the third charge is the one transition")
        #expect(budget.isSpent("a"))
        #expect(budget.charge("a") == .alreadySpent, "a fourth charge changes nothing")
        #expect(budget.refusals["a"] == 3, "the count is capped at the cap")
        #expect(!budget.isSpent("b"), "another sender is untouched")
    }

    /// The sender axis is bounded and full is fail-closed: an untracked sender on a full axis is
    /// spent without a row — a bug's signature, since committed slots never outnumber the roster.
    @Test func aFullSenderAxisFailsClosed() {
        var budget = MeshRoutedRefusalBudget(cap: 5, maxSenders: 2)
        #expect(budget.charge("a") == .charged)
        #expect(budget.charge("b") == .charged)
        #expect(budget.charge("c") == .untracked, "a third row is refused")
        #expect(budget.isSpent("c"), "and the untracked sender is dropped, never let through")
        #expect(budget.refusals.count == 2, "the map did not grow")
        #expect(!budget.isSpent("a") && !budget.isSpent("b"))
    }

    /// A cap of one spends on the first refusal; degenerate arguments are floored, not trapped.
    @Test func aCapOfOneSpendsImmediatelyAndArgumentsAreFloored() {
        var one = MeshRoutedRefusalBudget(cap: 1, maxSenders: 1)
        #expect(one.charge("a") == .spent)
        let floored = MeshRoutedRefusalBudget(cap: 0, maxSenders: -4)
        #expect(floored.cap == 1 && floored.maxSenders == 1)
        var reset = MeshRoutedRefusalBudget(cap: 2, maxSenders: 8)
        #expect(reset.charge("a") == .charged)
        reset.reset()
        #expect(reset.refusals.isEmpty && !reset.isSpent("a"))
    }

    /// The shipping defaults are derived, not literals: the cap is the drain's own per-peer frame
    /// budget, and the axis is the roster cap.
    @Test func theShippingDefaultsAreDerived() {
        let budget = MeshRoutedRefusalBudget()
        #expect(budget.cap == MeshRoutedDrainBounds.sessionFramesPerPeer)
        #expect(budget.cap == 1056, "one maximal item plus its manifests and receipts")
        #expect(budget.maxSenders == MeshMembershipBounds.maxRecordsPerKind,
                "the sender axis is the admission set's capacity, as the replay window's is")
        #expect(budget.maxSenders == 16)
    }

    /// A courier facing a FULL receiver is not starved: the manifest is refused at the store (never
    /// charged) and the chunks of the same batch — refused before the store as `unknownItemNotFromOrigin`
    /// — are the receiver's own refusal arriving in pieces, named but not charged.
    @Test func aCapacityHeldItemsChunksAreNamedButNotCharged() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "refusal-capacity-held")
        defer { rig.teardown() }
        rig.link(1, 2)
        try rig.plantByteHog(at: 2)
        let receiver = rig.nodes[2].manager
        let courier = rig.nodes[1].fingerprint
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        // The courier forwards node 0's manifest; node 2 is a destination, so the door admits it to
        // the store, which refuses it for capacity — the receiver's own refusal, remembered per sender.
        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: item.manifest),
            type: .meshRoutedManifest, sender: 1, receiver: 2
        )
        #expect(receiver.routedDeliveryHold?.cause == .storeFull, "precondition: the receiver is full")
        #expect(receiver.routedRefusalBudgetForTesting.refusals[courier] == nil,
                "a store refusal is never a charge")
        // R2: bounded by the item's own chunk count.
        for chunk in item.chunks {
            try rig.dispatch(MeshChunkPayload(chunk: chunk), type: .meshRoutedChunk, sender: 1, receiver: 2)
        }
        #expect(receiver.routedRefusalBudgetForTesting.refusals[courier] == nil,
                "the chunks behind a capacity-held manifest are the receiver's refusal, not the courier's")
    }

    // MARK: - The drain cell

    /// A committed member repeating `unknownItemNotFromOrigin` — a chunk for an item this device
    /// has never seen, from a sender that is not its origin, which costs a sealed-index load each
    /// time — is charged per refusal, reported once at the cap, and then dropped unread: after the
    /// cap even its VALID manifest lands nowhere, while another member's frames still land.
    @Test func aSpentSenderIsDroppedBeforeTheDoorAndOthersAreNot() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "refusal-budget")
        defer { rig.teardown() }
        rig.link(1, 2)
        rig.link(0, 2)
        let receiver = rig.nodes[2].manager
        let courier = rig.nodes[1].fingerprint
        receiver.routedRefusalBudgetForTesting = MeshRoutedRefusalBudget(cap: 3, maxSenders: 8)
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        // Minted at node 0, never staged at node 2: to node 2 the item is unknown, and node 1 is
        // not its origin.
        let foreign = try MeshRoutedDrainItem.mint(rig, origin: 0)
        let chunk = MeshChunkPayload(chunk: try #require(foreign.chunks.first))
        // R2: a fixed count — three to spend, two past the cap.
        for _ in 0..<5 {
            try rig.dispatch(chunk, type: .meshRoutedChunk, sender: 1, receiver: 2)
        }
        #expect(receiver.routedRefusalBudgetForTesting.refusals[courier] == 3,
                "three refusals were charged; the two past the cap never reached the door")
        #expect(receiver.routedRefusalBudgetForTesting.isSpent(courier))
        #expect(capture.values(of: "mesh.routedDrain.refusalBudgetSpent", key: "reason")
                    .contains("unknownItemNotFromOrigin"),
                "the one transition names the refusal that spent it")

        // The spent sender's OWN, valid manifest is dropped unread.
        let own = try MeshRoutedDrainItem.mint(rig, origin: 1)
        own.stage(into: rig, at: 1)
        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: own.manifest),
            type: .meshRoutedManifest, sender: 1, receiver: 2
        )
        #expect(rig.routedIndex(rig.nodes[2])?.record(for: own.key) == nil,
                "a spent sender's valid manifest is dropped before the door")
        #expect(receiver.routedRefusalBudgetForTesting.refusals[courier] == 3,
                "and a drop is not a charge")

        // Another member is unaffected: node 0's manifest, for which node 2 is a destination, lands.
        foreign.stage(into: rig, at: 0)
        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: foreign.manifest),
            type: .meshRoutedManifest, sender: 0, receiver: 2
        )
        #expect(rig.routedIndex(rig.nodes[2])?.record(for: foreign.key) != nil,
                "the budget is per sender: node 0 still lands")
        #expect(receiver.routedRefusalBudgetForTesting.refusals[rig.nodes[0].fingerprint] == nil,
                "an admitted frame is not a refusal")
    }

    /// An honest refusal under the cap changes nothing about the door: the same courier chunk is
    /// still refused by name, and the sender's later valid manifest still lands.
    @Test func anHonestRefusalUnderTheCapIsStillJustARefusal() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "refusal-under-cap")
        defer { rig.teardown() }
        rig.link(1, 2)
        let receiver = rig.nodes[2].manager
        let foreign = try MeshRoutedDrainItem.mint(rig, origin: 0)
        let chunk = MeshChunkPayload(chunk: try #require(foreign.chunks.first))
        try rig.dispatch(chunk, type: .meshRoutedChunk, sender: 1, receiver: 2)
        #expect(receiver.routedRefusalBudgetForTesting.refusals[rig.nodes[1].fingerprint] == 1)
        #expect(!receiver.routedRefusalBudgetForTesting.isSpent(rig.nodes[1].fingerprint))

        let own = try MeshRoutedDrainItem.mint(rig, origin: 1)
        own.stage(into: rig, at: 1)
        try rig.dispatch(
            MeshRoutedManifestPayload(manifest: own.manifest),
            type: .meshRoutedManifest, sender: 1, receiver: 2
        )
        #expect(rig.routedIndex(rig.nodes[2])?.record(for: own.key) != nil,
                "one refusal costs nothing but the refusal")
    }

    // MARK: - The wall

    /// Every pre-store refusal exit in the four content doors charges the sender: inside the doors
    /// the rejected token is never spelled directly (every exit goes through the one charging
    /// door), the dispatch decode goes through it too, the gate sits at the dispatch, and the
    /// budget is reset with the drain state — nowhere else. The two digest doors are outside the
    /// budget by design (D-5.12 / D-6.10: a digest costs one verify, is bound to its slot, and its
    /// answer is bounded by the per-peer frame budget), and their three spellings are pinned so a
    /// fourth cannot appear unnoticed.
    @Test func everyPreStoreRefusalGoesThroughTheOneChargingDoor() throws {
        let code = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift")
        )
        let token = "\"mesh.routedDrain.rejected\""
        let total = code.components(separatedBy: token).count - 1
        #expect(total == 5, "the probe, the charging door and the three digest-door lines; found \(total)")

        let doorsStart = try #require(code.range(of: "private func ingestRoutedManifest("))
        let doorsEnd = try #require(code.range(of: "private nonisolated enum RoutedDrainVerdict"))
        let doors = String(code[doorsStart.lowerBound..<doorsEnd.lowerBound])
        #expect(!doors.contains(token), "a content door spells the rejected token instead of charging the sender")
        let doorCalls = doors.components(separatedBy: "refuseRoutedFrameBeforeStore(").count - 1
        #expect(doorCalls == 7, "manifest ×2, chunk ×3, custody ×1, recipient ×1; found \(doorCalls)")

        let dispatchStart = try #require(code.range(of: "private func dispatchRoutedContent("))
        let dispatchEnd = try #require(code.range(of: "private struct RoutedIngestContext"))
        let dispatch = String(code[dispatchStart.lowerBound..<dispatchEnd.lowerBound])
        #expect(dispatch.contains("guard !routedRefusalBudget.isSpent(context.sender) else { return }"),
                "a spent sender is dropped at the dispatch, before the decode")
        #expect(dispatch.components(separatedBy: "refuseRoutedFrameBeforeStore(").count - 1 == 4,
                "all four undecodable exits charge the sender")
        #expect(!dispatch.contains("FernletAuditLog.log("),
                "the dispatch writes no audit line of its own — every refusal there goes through the charging door")

        let resets = code.components(separatedBy: "routedRefusalBudget.reset()").count - 1
        #expect(resets == 1, "the budget is reset with the drain state only — never on a disconnect or a flap")
        #expect(code.contains("routedRefusalBudget = MeshRoutedRefusalBudget()"))
    }
}
