// ProximityRunPolicyHostTests.swift
// FernletTests
//
// Network migration P7 items 2 and 3: the WIRING half of plan §13's run policy, the wall that says
// the routed access gate has exactly one writer, and — from item 3's pass B — the ZERO WALL that
// says the four proximity radios are driven from the host's door closures and from nowhere else in
// the app target.
//
// A separate suite from `ProximityRunPolicyTests` on purpose. That one's subject is the MATRIX — a
// 23 040-row enumeration of a pure function's whole input product, whose header says so in as many
// words — and it holds no object, injects nothing and touches no app state. This one's subject is a
// live `@MainActor` host with a door injected into it, plus a grep-wall over the app target. Two
// subjects, two suites; folding the second into the first would make "the matrix is the artefact"
// false the moment someone skimmed it.
//
// What the wall says, and why it is worth a cell:
//
//   * `applyRoutedAccessGate(` appears EXACTLY ONCE outside ProximityKit, and ONCE is counted as an
//     OCCURRENCE total rather than as a one-element file list — a second call parked inside
//     `FernletApp.swift` would leave the file list right and the claim false. Before this item the
//     app assembled the gate in a private helper and called the door from six sites
//     (`FernletApp.swift:337`, `:383`, `:416`, `:435`, `:447`, `:491`); four of them had compared
//     `== .active` while the scene handler fell only on `.background`, which is the failure a single
//     writer exists to make impossible. `ProximityRunPolicy.decide(` is counted the same way.
//   * The one remaining caller is named from a BRACE-MATCHED body, not from text proximity, and
//     that body is shown to carry a gate it was handed rather than one it built.
//   * The retired helper is a zero-list, in `theRetiredTextTransportIsGone`'s shape: keeping both
//     spellings alive is what makes a retirement a fiction.
//   * Every count is proven non-vacuous — the file sweep is non-empty, `FernletApp.swift` is in it,
//     and each zero-list needle is fixtured against a planted string. A wall handed a wrong root
//     enumerates nothing and passes green, which is the dangerous failure mode.
//
// What the ZERO WALL says (pass B):
//
//   * `startJoin()`, `stopJoin()`, `resumeSearchingForPartitionedMesh()`, both listeners'
//     `start()` / `stop()`, `applyRunState(` and `armDiscoveryTimeout` appear in `App/` ONLY inside
//     `FernletApp.mountRoutedRunPolicy(_:)`'s door closures — counted, not file-listed, and the
//     surviving occurrences are shown to be CONTAINED in that brace-matched body rather than merely
//     near it.
//   * The DEBUG rejection-matrix harness is exempt **by file name**, and the exemption is fixtured
//     against the one `startJoin()` and the `#if DEBUG` / `MeshMatrixDebugOptions.isEnabled` pair it
//     was written for, because an exemption that matches nothing is a hole nobody can see.
//   * Non-vacuity names `ContentView.swift` and `FernletStore.swift` specifically: between them they
//     held eight of these calls before pass B, and a sweep that stopped reaching either would report
//     a clean retirement of code it never read.
//
// The unit half drives the host through its edges with recording doors: the two scene legs, an
// inactive scene (which is a FOREGROUND scene — P5's post-close correction), the duress edge that
// moves at neither a scene nor a protected-data transition, a protected-data edge, and the launch
// sequence in which nothing is written until the first explicit push. Pass B adds the radio half —
// no seam ever receives `foregroundOnly`, the mesh door receives the `(links, discovery)` pair the
// decision resolved, the teardown fires once on a RISE and again only after the condition clears,
// and a second `connect(…)` re-points every door so a rebuilt store is re-mounted. The last cell is
// the general claim the others are instances of: over a step list that exercises every setter the
// host declares, what the host writes equals — element for element — a HAND-DERIVED list of gate
// literals, each written out from the gate's three rules rather than re-computed from the policy.
// Re-deciding over the host's own inputs would restate the host's arithmetic back to it and could
// not fail.
//
// **Item 4 adds the poller**, the one `Task` this host owns, and with it a third wall and a live
// mesh. What the poller half says:
//
//   * **The arm is an EDGE on `isSessionLive`.** Armed on the rise, nil on the fall, one handle
//     however many times the leg is re-fed, cancelled again when the doors are replaced and when
//     the teardown door runs. `isPollerArmed` is read rather than tick counts, because "nothing may
//     spin" is a claim about the task not EXISTING and a cancelled task ticks exactly as little as
//     an absent one.
//   * **The interval is injected.** `pollInterval` defaults to the shipping 30 s and one cell passes
//     milliseconds, so the REAL arm — sleep, tick, re-arm — is exercised rather than only
//     `pollNow(at:)`. That cell also pins that two ticks never arrive inside one interval, which is
//     what a second stacked timer would look like.
//   * **The three consumers are driven to their verdicts THROUGH a tick**, over a real
//     `MeshNetworkManager` on a fake transport — the rig `MeshPartitionDetectionTests` builds, cut
//     to what a tick needs. The headline is P6 item 2's live consequence (plan §12.3 finding 3): a
//     live mesh whose ceiling has elapsed is ENDED by ONE tick, and the same rig inside its ceiling
//     is not.
//   * **The wall.** `enforceSessionCeiling(`, `evaluateIdleLapse(` and `evaluatePartition(` appear
//     EXACTLY ONCE each across `App/`, all three inside `mountRoutedRunPolicy(`'s brace-matched
//     body, in that index order — the order is the decision, so the wall is where it is pinned. The
//     ProximityKit side is pinned too, as MEASURED counts: these three had no shipping caller at all
//     before this item, and the wall is what makes that stay true of the package.

import Foundation
import SwiftUI
import Testing
@testable import FernletCrypto
@testable import ProximityKit
@testable import Fernlet

/// Records what the host writes through all five doors, standing in for
/// `MeshNetworkManager.applyRoutedAccessGate(_:now:)`, the three `applyRunState` seams and the
/// session teardown.
///
/// A class rather than captured local `var`s so each door is an ordinary main-actor object the
/// closure holds, which is the shape production uses (the closures hold the store) and the shape
/// that keeps every cell readable at its assertion.
@MainActor
final class ProximityRunDoorRecorder {

    /// Every gate written, oldest first.
    private(set) var gates: [MeshRoutedAccessGate] = []

    /// Every instant the host stamped a gate write with, oldest first, positionally paired with
    /// ``gates``.
    private(set) var instants: [Date] = []

    /// Every `(links, discovery)` pair pushed at the mesh seam, oldest first.
    private(set) var meshDirectives: [(links: ProximityRunState, discovery: ProximityRunState)] = []

    /// Every directive pushed at the presence seam, oldest first.
    private(set) var presenceDirectives: [ProximityRunState] = []

    /// Every directive pushed at the recipe-share seam, oldest first.
    private(set) var recipeShareDirectives: [ProximityRunState] = []

    /// How many times the teardown door was called.
    private(set) var teardowns = 0

    /// Every instant a poller tick handed the session door, oldest first (network migration P7
    /// item 4). The list rather than a count, because the gaps between them are what a second
    /// stacked timer would show up in.
    private(set) var polls: [Date] = []

    /// Records one gate write.
    ///
    /// - Parameters:
    ///   - gate: The gate the host decided.
    ///   - now: The instant it stamped the write with.
    func record(_ gate: MeshRoutedAccessGate, at now: Date) {
        gates.append(gate)
        instants.append(now)
    }

    /// Records one push at the mesh seam.
    ///
    /// - Parameters:
    ///   - links: The mesh-links directive as the seam received it.
    ///   - discovery: The discovery/admission directive as the seam received it.
    func recordMesh(links: ProximityRunState, discovery: ProximityRunState) {
        meshDirectives.append((links: links, discovery: discovery))
    }

    /// Records one push at the presence seam.
    ///
    /// - Parameter state: The directive as the seam received it.
    func recordPresence(_ state: ProximityRunState) {
        presenceDirectives.append(state)
    }

    /// Records one push at the recipe-share seam.
    ///
    /// - Parameter state: The directive as the seam received it.
    func recordRecipeShare(_ state: ProximityRunState) {
        recipeShareDirectives.append(state)
    }

    /// Records one call of the teardown door.
    func recordTeardown() {
        teardowns += 1
    }

    /// Records one poller tick.
    ///
    /// - Parameter now: The instant the tick handed the session door.
    func recordPoll(at now: Date) {
        polls.append(now)
    }

    /// The gap between each consecutive pair of ticks, in seconds — empty for fewer than two.
    ///
    /// One timer produces gaps of at least its interval; two stacked timers produce a gap near
    /// zero, which is the whole reason ``polls`` keeps instants rather than a count.
    var pollGaps: [TimeInterval] {
        var gaps: [TimeInterval] = []
        // R2: bounded by the ticks this recorder has already stored.
        for (index, instant) in polls.enumerated() where index > 0 {
            gaps.append(instant.timeIntervalSince(polls[index - 1]))
        }
        return gaps
    }

    /// Every directive any radio seam received, in push order — the list the "no seam ever sees
    /// `foregroundOnly`" claim is made over.
    var everyRadioDirective: [ProximityRunState] {
        var directives: [ProximityRunState] = []
        // R2: bounded by the pushes this recorder has already stored.
        for pair in meshDirectives {
            directives.append(pair.links)
            directives.append(pair.discovery)
        }
        return directives + presenceDirectives + recipeShareDirectives
    }
}

/// P7 items 2, 3 and 4's wiring: the single writer of the routed access gate and of the four
/// proximity radios, the poller that drives the three session judgements, and the three walls that
/// count all of it.
@MainActor
@Suite struct ProximityRunPolicyHostTests {

    // MARK: - Fixtures

    /// A connected host and the recorder holding all six of its doors.
    ///
    /// - Returns: the host, and the recorder every write lands in.
    static func connectedHost() -> (host: ProximityRunPolicyHost, recorder: ProximityRunDoorRecorder) {
        let recorder = ProximityRunDoorRecorder()
        let host = ProximityRunPolicyHost()
        Self.connect(host, to: recorder)
        return (host, recorder)
    }

    /// Installs one recorder as all six of a host's doors.
    ///
    /// Hoisted out of ``connectedHost()`` so the cells that build a host by hand — the launch
    /// sequence, and the re-mount — install the same set rather than a gate door alone.
    ///
    /// The poll door always records, and additionally runs `poll` when one is supplied: the cells
    /// that only care whether a tick happened get a count, and the cells that drive a real
    /// `MeshNetworkManager` get the mount's three consumers behind the same recorder.
    ///
    /// - Parameters:
    ///   - host: The host to connect.
    ///   - recorder: The recorder every door writes into.
    ///   - poll: What the tick runs after recording, or nil to only record.
    static func connect(
        _ host: ProximityRunPolicyHost,
        to recorder: ProximityRunDoorRecorder,
        poll: (@MainActor (Date) async -> Void)? = nil
    ) {
        host.connect(
            accessGate: { gate, now in recorder.record(gate, at: now) },
            meshRadios: { links, discovery in
                recorder.recordMesh(links: links, discovery: discovery)
            },
            presence: { state in recorder.recordPresence(state) },
            recipeShare: { state in recorder.recordRecipeShare(state) },
            tearDownSession: { recorder.recordTeardown() },
            poll: { now in
                recorder.recordPoll(at: now)
                if let poll {
                    await poll(now)
                }
            }
        )
    }

    /// A connected host whose poller ticks every `interval` seconds instead of every 30.
    ///
    /// The injection is what lets a cell exercise the REAL arm — sleep, tick, re-arm — rather than
    /// only `pollNow(at:)`. Shipping never passes it.
    ///
    /// - Parameter interval: Seconds between ticks.
    /// - Returns: the host, and the recorder every door writes into.
    static func polledHost(
        interval: TimeInterval
    ) -> (host: ProximityRunPolicyHost, recorder: ProximityRunDoorRecorder) {
        let recorder = ProximityRunDoorRecorder()
        let host = ProximityRunPolicyHost(pollInterval: interval)
        Self.connect(host, to: recorder)
        return (host, recorder)
    }

    /// Waits until the recorder has seen `count` ticks, or until a generous ceiling — never a fixed
    /// sleep, so a slow machine makes the cell slower and not red.
    ///
    /// - Parameters:
    ///   - count: How many ticks to wait for.
    ///   - recorder: The recorder the ticks land in.
    static func waitForPolls(_ count: Int, in recorder: ProximityRunDoorRecorder) async {
        // R2: at most 400 checks, 5 ms apart — a two-second ceiling, whatever the scheduler does.
        for _ in 0..<400 where recorder.polls.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - A live mesh for the poller to judge

    /// Everything a poller cell drives: a live mesh, the host whose tick judges it, and the recorder.
    struct PollerRig {

        /// The `ProximityHost` the manager reads `unowned`. The CELL holds this, which is the whole
        /// reason it is on the rig: a store that died at the end of the building call would leave
        /// the manager with a dangling host from birth (rule HP0/ML5).
        let store: FernletStore

        /// The mesh manager the mount's three consumers run on.
        let manager: MeshNetworkManager

        /// The seeded roster's fingerprints, ascending — three of them, this device among them.
        let names: [String]

        /// The policy host whose poll door is those three consumers, in the mount's order.
        let host: ProximityRunPolicyHost

        /// Every tick, recorded.
        let recorder: ProximityRunDoorRecorder
    }

    /// The three session consumers, in the mount's order, as a poller door over one manager.
    ///
    /// Written out here rather than reached from `FernletApp`, whose production door is a closure
    /// inside a `private func` on a `App` type that no test can call.
    /// ``thePollDoorsThreeCallsSitInsideTheMountInTheDecidedOrder()`` is what pins that the two are
    /// the same three calls in the same order, `monotonicElapsed: nil` included — so this is a
    /// COPY the wall keeps honest, not a second opinion.
    ///
    /// - Parameter manager: The mesh manager a tick judges.
    /// - Returns: the door to hand `connect(…)`.
    static func sessionConsumerDoor(
        for manager: MeshNetworkManager
    ) -> @MainActor (Date) async -> Void {
        { now in
            await manager.enforceSessionCeiling(now: now, monotonicElapsed: nil)
            manager.evaluateIdleLapse(now: now)
            manager.evaluatePartition(now: now)
        }
    }

    /// A LIVE mesh with an armed ceiling, and a host whose poll door is the mount's three calls
    /// over it.
    ///
    /// Cut down from `MeshPartitionDetectionTests.makeRig(memberCount:)` to what one tick needs: a
    /// descriptor created at `createdAt`, a seeded roster of three (so the partition call has
    /// something to be partitioned from), the two events that make `sessionState` live, and the
    /// ceiling `foundMesh(_:now:)` arms in shipping. Every seal runs under `MeshP3Acceptance`'s
    /// pinned install identity, so a refused save cannot quietly change what a cell sees.
    ///
    /// `createdAt` is anchored to the REAL clock by its callers, because the ceiling's signed bound
    /// is judged against the instant the tick hands the door and the shipping tick hands `Date()`.
    ///
    /// - Parameter createdAt: The instant the mesh was founded and the ceiling armed from.
    /// - Returns: the rig, `store` included so the caller can hold it.
    static func pollerRig(createdAt: Date) throws -> PollerRig {
        let store = makeTestStore()
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        let meshID = UUID()
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager, meshID: meshID, createdAt: createdAt)
        let local = manager.identityForTesting
        let others = try (0..<2).map { try MeshPartitionFixtures.identity("poller\($0)") }
        manager.seedMembershipLedgerForTesting(
            meshID: meshID,
            founderSigningPublicKey: local.localSigningPublicKey,
            ledger: try MeshPartitionFixtures.ledger(founder: local, others: others, meshID: meshID)
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
            manager.startSessionCeiling(
                hardDeadline: createdAt.addingTimeInterval(MeshSessionCeiling.ceilingSeconds),
                startedAt: createdAt
            )
        }
        let host = ProximityRunPolicyHost()
        let recorder = ProximityRunDoorRecorder()
        Self.connect(host, to: recorder, poll: Self.sessionConsumerDoor(for: manager))
        return PollerRig(
            store: store,
            manager: manager,
            names: manager.membershipVerifier?.roster.memberFingerprints ?? [],
            host: host,
            recorder: recorder
        )
    }

    /// One call against a host: the shape every entry of ``legSteps`` carries.
    ///
    /// A named type rather than the element type written inline, because a bare
    /// `@MainActor (ProximityRunPolicyHost) -> Void` sitting in an array literal's annotation has no
    /// precedent anywhere in this repo and a typealias is the spelling that does.
    typealias LegStep = @MainActor (ProximityRunPolicyHost) -> Void

    /// One leg update per entry, each paired with the gate that step must produce.
    ///
    /// A literal list rather than a product: the policy's own input product is
    /// `ProximityRunPolicyTests`' subject, and what this suite has to show is that each SETTER
    /// records its OWN leg and re-decides. The order deliberately moves a leg back and forth (the
    /// scene three times, protected data twice, the lock in and out of duress), so a setter that
    /// assigned the wrong field would move a gate leg its own `expected` literal holds still.
    ///
    /// `expected` is an INDEPENDENT hand-derivation, never `ProximityRunPolicy.decide(_:)`'s answer
    /// re-computed over the host's own inputs — that comparison restates the host's arithmetic back
    /// to it and cannot fail. Each literal is read straight off the gate's three rules, against a
    /// host that starts fail-closed (`.background`, protected data false, lock `.locked`):
    /// `protectedDataAvailable` is the protected-data leg verbatim, `appIsForeground` is true for
    /// `.active` and `.inactive` and false for `.background`, and `duressActive` holds exactly while
    /// the lock leg is `.duress`. Six of the thirteen steps drive a setter the GATE does not read
    /// and repeat the previous literal unchanged, which is the claim that those legs stay out of it;
    /// the `.inactive` → `.active` step repeats too, because both phases are foreground.
    static let legSteps: [(step: LegStep, expected: MeshRoutedAccessGate)] = [
        (step: { $0.setScenePhase(.background) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: false, appIsForeground: false, duressActive: false
        )),
        (step: { $0.setProtectedDataAvailable(true) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: false, duressActive: false
        )),
        (step: { $0.setScenePhase(.inactive) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setAppLockState(.duress) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: true
        )),
        (step: { $0.setSelectedTab(.social) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: true
        )),
        (step: { $0.setHasCommittedPeer(true) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: true
        )),
        (step: { $0.setAppLockState(.unlocked) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setChatAgeGate(.below) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setAllowsNearbyPresence(true) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setAllowsNearbyRecipeShares(true) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setDeletingAllData(true) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setScenePhase(.active) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setProtectedDataAvailable(false) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: false, appIsForeground: true, duressActive: false
        ))
    ]

    /// Every `.swift` file under `App/`, comments stripped, sorted by path.
    ///
    /// The whole app target rather than `App/Fernlet` alone, so a second writer parked in the
    /// widget, share or Messages extension would be counted too.
    ///
    /// Body-identical to `MeshRoutedLockedDeviceTests.codeSources(under:)` and kept separate because
    /// that one is `private static` on another suite and cannot be called from here. Promoting it
    /// would move a file this item does not own; the duplicate is five lines of enumeration.
    ///
    /// - Returns: each file's name and its comment-stripped source.
    static func appSources() throws -> [(name: String, code: String)] {
        let root = RepoRoot.url("App")
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        var sources: [(name: String, code: String)] = []
        // R2: bounded by the app target's own file list.
        for file in files.sorted(by: { $0.path < $1.path }) {
            sources.append((
                file.lastPathComponent,
                MeshRoutedSourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8))
            ))
        }
        return sources
    }

    /// Every `.swift` file under `FernletKit/Sources/ProximityKit`, comments stripped, sorted by
    /// path — the package half of item 4's wall.
    ///
    /// Same body as ``appSources()`` over the other root, and kept separate for the same reason
    /// that one is: the two claims are about two trees and a shared helper taking a root would make
    /// each cell one argument away from measuring the wrong one.
    ///
    /// - Returns: each file's name and its comment-stripped source.
    static func proximityKitSources() throws -> [(name: String, code: String)] {
        let root = RepoRoot.url("FernletKit/Sources/ProximityKit")
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        var sources: [(name: String, code: String)] = []
        // R2: bounded by ProximityKit's own file list.
        for file in files.sorted(by: { $0.path < $1.path }) {
            sources.append((
                file.lastPathComponent,
                MeshRoutedSourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8))
            ))
        }
        return sources
    }

    /// How many times `needle` occurs in `haystack`.
    ///
    /// - Parameters:
    ///   - needle: The substring counted.
    ///   - haystack: The text searched.
    /// - Returns: the occurrence count.
    static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - The zero wall (P7 item 3, pass B)

    /// Every spelling that MOVES a proximity radio, and which the app target may therefore name
    /// only inside `FernletApp.mountRoutedRunPolicy(_:)`'s door closures.
    ///
    /// Nine needles, chosen because each is a call the app used to make for itself:
    /// `ContentView.startFriendsDiscovery()` resolved a three-way into `startJoin()` or
    /// `resumeSearchingForPartitionedMesh()`, `stopFriendsDiscovery()` called `stopJoin()`,
    /// `updatePresenceListener()` and `updateRecipeShareListener()` called both listeners'
    /// `start()` / `stop()`, and `FernletStore` reached around all of it at three more sites.
    /// `applyRunState(` is here as the door's OWN spelling — the point of the wall is that it too
    /// has exactly one caller — and `armDiscoveryTimeout` is a pure zero-list: its successor is
    /// `MeshNetworkManager.armFriendRadios()`, and keeping both alive is what makes a retirement a
    /// fiction.
    static let radioCalls = [
        "startJoin()",
        "stopJoin()",
        "resumeSearchingForPartitionedMesh()",
        "presenceManager.start()",
        "presenceManager.stop()",
        "recipeShareManager.start()",
        "recipeShareManager.stop()",
        "applyRunState(",
        "armDiscoveryTimeout"
    ]

    /// The DEBUG rejection-matrix harness (runbook Lane C), exempted BY NAME: its `startJoin()` is
    /// compiled out of release entirely and gated on `MeshMatrixDebugOptions.isEnabled` at runtime.
    static let debugHarnessFile = "MeshRejectionMatrixHarness.swift"

    /// The active-share sheet, exempted BY NAME — the second and last exemption (P7 item 3, pass B
    /// fix review).
    ///
    /// It drives the recipe radio through its OWN injected `manager`, which is the same instance
    /// `store.recipeShareManager` names, so the receiver-qualified needles in ``radioCalls`` were
    /// blind to it and ``listenerCalls`` is not. The exemption is written for the ACTIVE share
    /// flow and nothing else: a user tapped "Share", so the radio runs for as long as the sheet is
    /// up whatever the policy would have said about PASSIVE listening. What the sheet may not do is
    /// decide the RESTING state — the dismissal hands that back with `pushNow()`, and
    /// ``theActiveShareSheetsExemptionIsExactlyTheShareFlow()`` pins both halves.
    static let recipeShareSheetFile = "ProximityRecipeShareSheet.swift"

    /// Its path under the repo root, for the fixture that reads it directly.
    static let recipeShareSheetPath = "App/Fernlet/Proximity/UI/ProximityRecipeShareSheet.swift"

    /// Every file either wall lets off, by name. Two, and each one carries a fixture pinning the
    /// exact calls it was written for — an exemption that stops matching what it excuses is a hole
    /// nobody can see.
    static let byNameExemptions: Set<String> = [debugHarnessFile, recipeShareSheetFile]

    /// How many `manager.start()` calls the exempted share sheet may hold — MEASURED after the fix
    /// review, never inherited: `handleAppear()`'s (the share the user asked for) and the "Search
    /// again" button's. The third, `handleDisappear()`'s three-condition restart, is what the
    /// review removed; it was a second opinion about the RESTING listener.
    static let recipeShareSheetStarts = 2

    /// How many `manager.stop()` calls it may hold — one, `handleDisappear()`'s, which ends the
    /// share SESSION (coordinators, recipient list, send status) rather than standing a radio down.
    static let recipeShareSheetStops = 1

    /// The mentions that put an `App/` file into the receiver-agnostic sweep: either listener named
    /// as a store property, or either manager named as a TYPE (which is how a view that takes one as
    /// a parameter refers to it).
    static let listenerMentions = [
        "recipeShareManager",
        "presenceManager",
        "RecipeShareManager",
        "PresenceManager"
    ]

    /// The two spellings that move a listener whatever the receiver is called. Deliberately bare:
    /// the point is to catch the instance reached under another name.
    static let listenerCalls = [".start()", ".stop()"]

    /// How many ``listenerCalls`` the mount's door closures hold — MEASURED: the teardown door's
    /// two listener stops, and nothing else in the file.
    static let mountListenerCallCount = 2

    /// How many occurrences of ``radioCalls`` the mount's door closures are allowed to hold —
    /// MEASURED, never inherited: `stopJoin()`, `presenceManager.stop()` and
    /// `recipeShareManager.stop()` once each in the teardown door, plus `applyRunState(` three
    /// times (the mesh pair, presence, recipe).
    ///
    /// **Item 4 did not move it**, and that is checked rather than assumed: the poll door adds three
    /// calls to the same body, and not one of them is a radio.
    static let mountRadioCallCount = 6

    /// The three session judgements the poller drives, **in the order one tick makes them**.
    ///
    /// The order is the decision, not a detail: the ceiling can END the session, after which the
    /// other two are refused by the state machine rather than acting on an expired one; and the
    /// partition call is what ARMS the idle window the lapse reads, so running it first would let a
    /// single tick both arm a thirty-minute window and judge it. The list is used twice — as a set
    /// of needles for the "exactly once, and only in the mount" count, and as an ORDER for the
    /// index comparison inside the brace-matched body.
    static let sessionConsumers = [
        "enforceSessionCeiling(",
        "evaluateIdleLapse(",
        "evaluatePartition("
    ]

    /// How often each of ``sessionConsumers`` may be spelled inside
    /// `FernletKit/Sources/ProximityKit` — **MEASURED at this commit, and they move only with a
    /// decision.**
    ///
    /// Before item 4 these three had **no shipping caller anywhere**: every caller in the tree was a
    /// test, and the only exception inside the package was `evaluatePartition(now:)`'s call to its
    /// own `evaluatePartition(reachable:now:)`. So the counts here are declarations plus that one
    /// in-module convenience — one, one and three — and the point of pinning them is that item 4
    /// gave these doors a caller in the APP and must not have quietly given them a second one in
    /// the package, where a timer would be exactly the thing the on-demand design refuses.
    static let proximityKitConsumerCounts = [
        "enforceSessionCeiling(": 1,
        "evaluateIdleLapse(": 1,
        "evaluatePartition(": 3
    ]

    /// **The four proximity radios are driven from the run policy's doors and nowhere else**
    /// (P7 item 3, pass B — the retirement pass's wall).
    ///
    /// The claim has three parts and each is counted rather than asserted by file list alone:
    ///
    ///   * **Zero outside `FernletApp.swift`.** `ContentView` and `FernletStore` between them held
    ///     eight of these calls at pass A; both must now hold none, which is what makes
    ///     `ProximityRunPolicy` the single writer rather than a third opinion beside two others.
    ///   * **Containment, not adjacency.** Every surviving occurrence sits inside the brace-matched
    ///     body of `mountRoutedRunPolicy(`, and the total inside equals the total in the file — so a
    ///     tenth call added anywhere else in `FernletApp` reddens this even though the file list
    ///     stays at one element.
    ///   * **Two files are exempt by NAME**, and each exemption is fixtured: the DEBUG harness is
    ///     shown to be in the sweep, to carry exactly the one `startJoin()` it was written for, and
    ///     to guard it with `#if DEBUG`; the active-share sheet is pinned at its exact surviving
    ///     `manager.start()` / `manager.stop()` counts by
    ///     ``theActiveShareSheetsExemptionIsExactlyTheShareFlow()``. An exemption that matches
    ///     nothing is a hole nobody can see.
    ///
    /// **These nine needles name a RECEIVER, and that is their blind spot.** The share sheet held
    /// `manager.start()` — the same instance `store.recipeShareManager` names, injected under
    /// another name — and no needle here could see it, which is the miss the pass-B fix review
    /// found. ``theListenerRadiosAreNotMovedByAnyOtherReceiver()`` is the receiver-agnostic half,
    /// and it is the sweep the two by-name exemptions actually exist for.
    ///
    /// Non-vacuity first, and it names the two files the retirement is ABOUT: a sweep that stopped
    /// reaching `ContentView.swift` or `FernletStore.swift` would report a clean retirement of code
    /// it never read.
    @Test func theProximityRadiosAreDrivenOnlyFromTheHostsDoors() throws {
        let sources = try Self.appSources()
        #expect(!sources.isEmpty, "the App/ sweep found no Swift files at all")
        #expect(sources.contains(where: { $0.name == "ContentView.swift" }),
                "the sweep no longer reaches ContentView.swift")
        #expect(sources.contains(where: { $0.name == "FernletStore.swift" }),
                "the sweep no longer reaches FernletStore.swift")
        let everyExemptionIsInTheSweep = Self.byNameExemptions.allSatisfy { name in
            sources.contains(where: { $0.name == name })
        }
        #expect(everyExemptionIsInTheSweep, "an exempted file is not in the sweep at all")
        var strays: [String] = []
        var inFernletApp = 0
        // R2: nine needles over the app target's own file list.
        for source in sources where !Self.byNameExemptions.contains(source.name) {
            for needle in Self.radioCalls {
                let hits = Self.occurrences(of: needle, in: source.code)
                guard hits > 0 else { continue }
                if source.name == "FernletApp.swift" {
                    inFernletApp += hits
                } else {
                    strays.append("\(source.name): \(needle) ×\(hits)")
                }
            }
        }
        #expect(strays.isEmpty, "a proximity radio is driven from outside the run policy's doors")
        #expect(inFernletApp == Self.mountRadioCallCount,
                "the number of radio calls in FernletApp moved without this pin moving")
    }

    /// The containment half of the wall, plus the DEBUG exemption's fixture.
    ///
    /// Split from the count above only to stay inside the 60-line rule; the two are one claim.
    @Test func everySurvivingRadioCallSitsInsideTheMountsDoors() throws {
        let appCode = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletApp.swift"))
        let mount = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func mountRoutedRunPolicy(", in: appCode),
            "the launch mount was renamed, or its brace-matched body does not close"
        )
        #expect(!mount.contains("private func restoreMeshSessionContextIfNeeded"),
                "the body matcher is measuring the file rather than the brace-matched mount")
        var insideMount = 0
        var inWholeFile = 0
        // R2: bounded by the needle list.
        for needle in Self.radioCalls {
            insideMount += Self.occurrences(of: needle, in: mount)
            inWholeFile += Self.occurrences(of: needle, in: appCode)
        }
        #expect(insideMount == Self.mountRadioCallCount, "the mount's door closures lost a radio call")
        #expect(insideMount == inWholeFile,
                "a radio call sits in FernletApp OUTSIDE the mount's door closures")
        let harness = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/Proximity/Feasibility/\(Self.debugHarnessFile)")
        )
        #expect(Self.occurrences(of: "startJoin()", in: harness) == 1,
                "the by-name exemption must match exactly the one call it was written for")
        #expect(harness.contains("#if DEBUG"),
                "the exempted call is no longer compiled out of release")
        #expect(harness.contains("MeshMatrixDebugOptions.isEnabled"),
                "the exempted call is no longer gated on the Lane C launch flag")
    }

    /// **Neither listener is moved through a receiver the needle list cannot see** (P7 item 3, pass
    /// B fix review).
    ///
    /// ``radioCalls`` names a RECEIVER — `recipeShareManager.start()`, `presenceManager.stop()` —
    /// and that is exactly what the share sheet slipped past: it holds the very same
    /// `ProximityRecipeShareManager` the store's property names, injected under the name `manager`,
    /// and called `manager.start()` on it from a dismissal. The wall was green and the radio had two
    /// owners.
    ///
    /// So this half drops the receiver entirely. Any `App/` file whose comment-stripped code so much
    /// as MENTIONS a listener — as `store.presenceManager` / `store.recipeShareManager`, or as the
    /// type a view takes as a parameter — is swept for bare `.start()` / `.stop()`, and a file that
    /// holds one must be `FernletApp.swift` (where the containment half puts it inside the mount) or
    /// one of the two ``byNameExemptions``. Nothing else may spell either call at all.
    ///
    /// Non-vacuity twice over: the mount and the exempted sheet are both shown to be IN the sweep,
    /// because a mention list that stopped matching them would sweep an empty set and pass green.
    @Test func theListenerRadiosAreNotMovedByAnyOtherReceiver() throws {
        let sources = try Self.appSources()
        #expect(!sources.isEmpty, "the App/ sweep found no Swift files at all")
        var swept: [String] = []
        var strays: [String] = []
        var inFernletApp = 0
        // R2: bounded by the app target's own file list.
        for source in sources {
            let mentionsAListener = Self.listenerMentions.contains { source.code.contains($0) }
            guard mentionsAListener else { continue }
            swept.append(source.name)
            var hits = 0
            for needle in Self.listenerCalls {
                hits += Self.occurrences(of: needle, in: source.code)
            }
            guard hits > 0 else { continue }
            if source.name == "FernletApp.swift" {
                inFernletApp += hits
            } else if !Self.byNameExemptions.contains(source.name) {
                strays.append("\(source.name): ×\(hits)")
            }
        }
        #expect(swept.contains("FernletApp.swift"), "the sweep no longer reaches the launch mount")
        #expect(swept.contains(Self.recipeShareSheetFile),
                "the sweep no longer reaches the exempted share sheet, so the exemption is vacuous")
        #expect(strays.isEmpty, "a listener radio is moved through a receiver the wall cannot see")
        #expect(inFernletApp == Self.mountListenerCallCount,
                "the listener calls in FernletApp moved without this pin moving")
        let appCode = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletApp.swift"))
        guard let mount = MeshRoutedSourceScan.bracedBody(
            after: "private func mountRoutedRunPolicy(", in: appCode
        ) else {
            Issue.record("the launch mount was renamed, or its brace-matched body does not close")
            return
        }
        var insideMount = 0
        // R2: bounded by the needle list.
        for needle in Self.listenerCalls {
            insideMount += Self.occurrences(of: needle, in: mount)
        }
        #expect(insideMount == Self.mountListenerCallCount,
                "a listener call sits in FernletApp OUTSIDE the mount's door closures")
    }

    /// **The share sheet's exemption is exactly the ACTIVE share flow, and the resting state is
    /// still the policy's** (P7 item 3, pass B fix review).
    ///
    /// Two calls survive and they are both the user's own act: `handleAppear()` starts the radio
    /// because they tapped "Share", and "Search again" restarts discovery because they asked it to.
    /// The third — `handleDisappear()`'s `scenePhase == .active && allowNearbyRecipeShares &&
    /// unlocked` restart — is gone, and its absence is the point of the pin: those three conditions
    /// LOOKED like the recipe directive and were not it, so a dismissal during a duress session
    /// (still `.unlocked`), under a `.below` verdict or mid-delete-all restarted the radio against
    /// the policy's `stop`.
    ///
    /// What replaced it is counted too: the sheet must name `runPolicyHost.pushNow()`, which is the
    /// whole difference between handing the question back and answering it.
    @Test func theActiveShareSheetsExemptionIsExactlyTheShareFlow() throws {
        let sheet = MeshRoutedSourceScan.codeOnly(try RepoRoot.source(Self.recipeShareSheetPath))
        #expect(!sheet.isEmpty, "the exempted sheet could not be read, so every count below is vacuous")
        #expect(Self.occurrences(of: "manager.start()", in: sheet) == Self.recipeShareSheetStarts,
                "the share sheet's surviving start() count moved without this pin moving")
        #expect(Self.occurrences(of: "manager.stop()", in: sheet) == Self.recipeShareSheetStops,
                "the share sheet's surviving stop() count moved without this pin moving")
        #expect(sheet.contains("runPolicyHost.pushNow()"),
                "the dismissal no longer hands the resting listener state back to the policy")
        #expect(!sheet.contains("isUnlockedForListening"),
                "the sheet is deciding the lock half of the recipe directive for itself again")
        #expect(!sheet.contains("allowNearbyRecipeShares"),
                "the sheet is reading the recipe consent, which is a policy INPUT and not its own gate")
    }

    // MARK: - The wall

    /// **The gate has exactly one writer, and this is the wall that says so** (P7 item 2; the same
    /// shape as `theDrainFiresOnlyFromTheMergeDoor`, which is why P5's drain survived three phases).
    ///
    /// `applyRoutedAccessGate(` appears once across the whole app target, and the body holding it is
    /// brace-matched and shown to carry a gate it was HANDED: it names the closure's `accessGate`
    /// parameter and constructs no `MeshRoutedAccessGate` of its own. The decision that produced
    /// that value is pinned on the other side — `ProximityRunPolicy.decide(` also has exactly one
    /// app-target call site, inside `ProximityRunPolicyHost.pushNow()`, whose brace-matched body
    /// names both the decision and its gate.
    ///
    /// Each needle is counted TWICE over: the list of FILES that carry it, and the total number of
    /// OCCURRENCES. The file list on its own is not the claim — a second `applyRoutedAccessGate(`
    /// added inside `FernletApp.swift` keeps that list at one element while the single writer is
    /// already gone, and that is the cheapest way to lose it.
    ///
    /// Non-vacuity first, because a wall handed a wrong root enumerates nothing and passes green.
    @Test func theRoutedAccessGateHasExactlyOneWriterInTheAppTarget() throws {
        let sources = try Self.appSources()
        #expect(!sources.isEmpty, "the App/ sweep found no Swift files at all")
        #expect(sources.contains(where: { $0.name == "FernletApp.swift" }),
                "the App/ sweep no longer reaches FernletApp.swift, so every count below is vacuous")
        var writers: [String] = []
        var deciders: [String] = []
        var writeCalls = 0
        var decideCalls = 0
        // R2: bounded by the app target's own file list.
        for source in sources {
            let writes = Self.occurrences(of: "applyRoutedAccessGate(", in: source.code)
            let decides = Self.occurrences(of: "ProximityRunPolicy.decide(", in: source.code)
            writeCalls += writes
            decideCalls += decides
            if writes > 0 {
                writers.append(source.name)
            }
            if decides > 0 {
                deciders.append(source.name)
            }
        }
        #expect(writers == ["FernletApp.swift"],
                "the routed access gate must have exactly one writer, and it is FernletApp")
        #expect(writeCalls == 1,
                "the routed access gate is written from more than one call site in the app target")
        #expect(deciders == ["ProximityRunPolicyHost.swift"],
                "the run policy must be consulted in exactly one place, and it is the host")
        #expect(decideCalls == 1,
                "the run policy is consulted from more than one call site in the app target")
    }

    /// The writer's brace-matched body carries a gate it was handed, and the host's push is where
    /// that gate was decided.
    ///
    /// Split from the count above only to stay inside the 60-line rule; the two are one claim.
    @Test func theOneWriterCarriesTheGateThePolicyDecided() throws {
        let appCode = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletApp.swift"))
        let mount = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func mountRoutedRunPolicy(", in: appCode),
            "the launch mount was renamed, or its brace-matched body does not close"
        )
        #expect(mount.contains("runPolicyHost.connect("), "the launch mount no longer installs the doors")
        #expect(mount.contains("runPolicyHost.pushNow()"), "the launch mount no longer pushes")
        #expect(mount.contains("applyRoutedAccessGate("), "the injected door no longer reaches the seam")
        #expect(mount.contains("accessGate: { accessGate, now in"),
                "the door no longer names the gate it was handed")
        #expect(!mount.contains("MeshRoutedAccessGate("),
                "the door assembles a gate of its own again, so the policy is not the single writer")
        #expect(!mount.contains("restoreMeshSessionContextIfNeeded"),
                "the body matcher is measuring the file rather than the brace-matched mount")
        let hostCode = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ProximityRunPolicyHost.swift")
        )
        let push = try #require(
            MeshRoutedSourceScan.bracedBody(after: "func pushNow(", in: hostCode),
            "the host's pushNow() was renamed, or its brace-matched body does not close"
        )
        #expect(push.contains("ProximityRunPolicy.decide("), "the host no longer asks the policy")
        #expect(push.contains("decision.accessGate"), "the host no longer writes the decision's gate")
    }

    /// **The retired six-site gate push is gone**, spelling by spelling — the zero-list shape
    /// `theRetiredTextTransportIsGone` uses, and owed for the same reason: keeping both paths alive
    /// is what makes a retirement a fiction.
    ///
    /// Three spellings, one flow — the private helper the six sites called, the `foreground:`
    /// argument every one of them routed through `routedGateForeground(for:)`, and the sampled
    /// `protectedData:` argument the two scene sites passed. Each needle is fixtured against a
    /// planted string in the same cell, because a matcher that cannot find the thing it forbids
    /// passes vacuously.
    @Test func theRetiredSixSiteGatePushIsGone() throws {
        let retired = [
            "pushRoutedAccessGate",
            "foreground: Self.routedGateForeground",
            "protectedData: protectedDataAvailableNow"
        ]
        let sources = try Self.appSources()
        #expect(!sources.isEmpty, "the App/ sweep found no Swift files at all")
        var survivors: [String] = []
        // R2: three names over the app target's own file list.
        for source in sources {
            for symbol in retired where source.code.contains(symbol) {
                survivors.append(source.name)
            }
        }
        #expect(survivors.isEmpty, "a spelling of the retired six-site gate push came back")
        let planted = """
            pushRoutedAccessGate(store, protectedData: protectedDataAvailableNow, \
            foreground: Self.routedGateForeground(for: scenePhase))
            """
        var matched = 0
        // R2: the same three names.
        for symbol in retired where planted.contains(symbol) {
            matched += 1
        }
        #expect(matched == retired.count, "a needle in the zero-list cannot match what it forbids")
    }

    // MARK: - The six edges, through an injected door

    /// The two scene legs: backgrounding closes the foreground fact, activating opens it.
    @Test func theSceneLegsPushTheForegroundFactDownThenUp() throws {
        let (host, recorder) = Self.connectedHost()
        host.setScenePhase(.background)
        host.setScenePhase(.active)
        #expect(recorder.gates.count == 2, "each leg update re-decides and writes exactly once")
        let down = try #require(recorder.gates.first, "the backgrounding leg wrote nothing")
        let up = try #require(recorder.gates.last, "the activation leg wrote nothing")
        #expect(!down.appIsForeground, "a backgrounded scene is not a foreground scene")
        #expect(up.appIsForeground, "an active scene is a foreground scene")
    }

    /// An INACTIVE scene is a FOREGROUND scene (P5's post-close correction): Control Center, a call
    /// banner, a system prompt, the app's own Face ID sheet, iPad Split View. The host never
    /// compares a phase itself — `ProximityRunInputs`' initialiser routes it through
    /// `FernletApp.routedGateForeground(for:)`, which is the whole reason that initialiser is the
    /// only one.
    @Test func anInactiveSceneLegPushesAForegroundGate() throws {
        let (host, recorder) = Self.connectedHost()
        host.setScenePhase(.inactive)
        let gate = try #require(recorder.gates.last, "the inactive leg wrote nothing")
        #expect(gate.appIsForeground,
                "an inactive scene is still foreground: the device is unlocked and the process is live")
        let wholeGate = MeshRoutedAccessGate(
            protectedDataAvailable: false, appIsForeground: true, duressActive: false
        )
        #expect(gate == wholeGate,
                "the inactive leg must raise the foreground fact and leave the other two fail-closed")
    }

    /// The duress edge raises `duressActive` and moves NEITHER other leg — it is entered at an
    /// already-foreground lock screen and cleared by a real-passcode unlock in the same foreground,
    /// so it rides no scene and no protected-data transition and keeps its own `.onChange`.
    @Test func theDuressEdgePushesDuressAndMovesNoOtherLeg() throws {
        let (host, recorder) = Self.connectedHost()
        host.setProtectedDataAvailable(true)
        host.setScenePhase(.active)
        host.setAppLockState(.duress)
        #expect(recorder.gates.count == 3, "three leg updates, three writes")
        let before = try #require(recorder.gates.dropLast().last, "the scene leg wrote nothing")
        let after = try #require(recorder.gates.last, "the duress leg wrote nothing")
        #expect(!before.duressActive, "duress was not in force before its own edge")
        #expect(after.duressActive, "the duress edge must close the gate")
        #expect(after.protectedDataAvailable == before.protectedDataAvailable,
                "the duress edge moved the protected-data leg")
        #expect(after.appIsForeground == before.appIsForeground,
                "the duress edge moved the foreground leg")
    }

    /// A protected-data edge moves its own leg and nothing else — the fact is passed literally from
    /// the notification that says so, because `isProtectedDataAvailable` still answers `true` inside
    /// the will-become-unavailable handler.
    @Test func aProtectedDataEdgeMovesOnlyItsOwnLeg() throws {
        let (host, recorder) = Self.connectedHost()
        host.setScenePhase(.active)
        host.setProtectedDataAvailable(true)
        #expect(recorder.gates.count == 2, "two leg updates, two writes")
        let before = try #require(recorder.gates.first, "the scene leg wrote nothing")
        let after = try #require(recorder.gates.last, "the protected-data leg wrote nothing")
        #expect(!before.protectedDataAvailable, "the host starts fail-closed on data protection")
        #expect(after.protectedDataAvailable, "the rising leg must open the ciphertext fact")
        #expect(after.appIsForeground == before.appIsForeground,
                "the protected-data edge moved the foreground leg")
        #expect(after.duressActive == before.duressActive,
                "the protected-data edge moved the duress leg")
    }

    /// The launch sequence: legs set before the doors are installed are RECORDED and not written,
    /// connecting writes nothing by itself, and the first explicit push is the launch push — one
    /// push per seam, not one per leg that was seeded. What a SECOND `connect(…)` does is the next
    /// cell's claim.
    @Test func nothingIsWrittenUntilTheFirstExplicitPush() throws {
        let recorder = ProximityRunDoorRecorder()
        let host = ProximityRunPolicyHost()
        host.setScenePhase(.active)
        host.setProtectedDataAvailable(true)
        Self.connect(host, to: recorder)
        #expect(recorder.gates.isEmpty, "installing the doors must write nothing on its own")
        #expect(recorder.everyRadioDirective.isEmpty, "and must move no radio either")
        host.pushNow()
        #expect(recorder.gates.count == 1, "the first explicit push is the launch push")
        let launch = try #require(recorder.gates.last, "the launch push wrote nothing")
        #expect(launch.appIsForeground && launch.protectedDataAvailable,
                "the legs set before the doors were installed are carried into the launch push")
        #expect(recorder.presenceDirectives.count == 1,
                "the launch push is one push per seam, not one per leg that was seeded")
    }

    /// **A rebuilt store is re-mounted**: a second `connect(…)` re-points every door at the new
    /// set, and the old one stops receiving.
    ///
    /// `FernletStore` is never actually rebuilt in shipping — `FernletStoreLoader.retry()` re-enters
    /// only from `.failed`, when no store was ever built, and a delete-all rebuilds the Core Data
    /// stores UNDER the same `FernletStore` object rather than replacing it — so the second call
    /// this pins is in practice the ready view's `.onAppear` re-firing with the same store and
    /// handing back equivalent closures. The claim is worth a cell anyway, because the shape a
    /// one-shot latch would have produced is the dangerous one: doors still pointing at a dead
    /// store, with the wall that counts the call sites still green.
    @Test func aSecondConnectRePointsEveryDoorAtTheNewStore() {
        let first = ProximityRunDoorRecorder()
        let host = ProximityRunPolicyHost()
        Self.connect(host, to: first)
        host.pushNow()
        #expect(first.gates.count == 1, "the first mount's doors are live")
        let second = ProximityRunDoorRecorder()
        Self.connect(host, to: second)
        host.pushNow()
        #expect(second.gates.count == 1, "the re-mount's doors receive the next push")
        #expect(second.presenceDirectives.count == 1, "including every radio seam")
        #expect(second.teardowns == 0, "a re-mount is not a teardown")
        #expect(first.gates.count == 1, "and the replaced doors are never written to again")
    }

    // MARK: - The radios, through the injected seams

    /// **No seam ever sees `foregroundOnly`.** The host resolves every directive against the one
    /// foreground fact before it pushes, so a manager — which knows about neither scene phase —
    /// receives `run` or `stop` and nothing else.
    ///
    /// The claim is made over the WHOLE of ``legSteps``, which drives every setter the host declares
    /// and moves the scene three times, so it covers both resolutions of every `foregroundOnly`
    /// directive the policy can produce. `ProximityRunStateSeam.unresolved` exists for a caller that
    /// gets this wrong; this is the cell that says the only shipping caller does not.
    @Test func noRadioSeamEverReceivesAnUnresolvedDirective() {
        let (host, recorder) = Self.connectedHost()
        // R2: bounded by the literal step list.
        for entry in Self.legSteps {
            entry.step(host)
        }
        let directives = recorder.everyRadioDirective
        let everyDirectiveIsResolved = directives.allSatisfy { $0 != .foregroundOnly }
        let everyDirectiveIsRunOrStop = directives.allSatisfy { $0 == .run || $0 == .stop }
        #expect(!directives.isEmpty, "no radio was pushed at all, so the claim below is vacuous")
        #expect(everyDirectiveIsResolved,
                "a seam was handed foregroundOnly, which is a policy answer no manager can resolve")
        #expect(everyDirectiveIsRunOrStop, "a seam was handed something that is neither run nor stop")
        #expect(recorder.meshDirectives.count == Self.legSteps.count,
                "the mesh seam is pushed exactly once per leg update, like the gate")
        #expect(recorder.presenceDirectives.count == recorder.recipeShareDirectives.count,
                "the two listener seams are pushed in step")
    }

    /// The mesh door receives the PAIR the decision resolved — both directives together, because
    /// `startJoin()` / `stopJoin()` is one door for two radios.
    ///
    /// Hand-derived from the policy's own rules against a host that starts fail-closed, never
    /// re-computed from `ProximityRunPolicy.decide(_:)`. On the Friends tab, unlocked, foreground,
    /// with both consents on and no committed peer: mesh links and discovery/admission are each
    /// `foregroundOnly` (nothing is CPT-granted in P7), so both resolve UP; presence is
    /// `foregroundOnly` on Friends and resolves up; the recipe listener is `stop` on Friends, which
    /// is the row that shows the four radios really are decided separately. Backgrounding then puts
    /// all four down, and it is the RESOLUTION that does it — the directives never changed.
    @Test func theMeshDoorReceivesTheResolvedLinksAndDiscoveryPair() throws {
        let (host, recorder) = Self.connectedHost()
        host.setAppLockState(.unlocked)
        host.setAllowsNearbyPresence(true)
        host.setAllowsNearbyRecipeShares(true)
        host.setSelectedTab(.social)
        host.setScenePhase(.active)
        // The mesh seam records a LABELLED TUPLE, which has no precedent as a `#require` subject in
        // this tree — destructured into a local instead, and the miss recorded by hand.
        guard let up = recorder.meshDirectives.last else {
            Issue.record("the mesh seam was never pushed")
            return
        }
        let presenceUp = try #require(recorder.presenceDirectives.last, "presence was never pushed")
        let recipeUp = try #require(recorder.recipeShareDirectives.last, "recipe was never pushed")
        #expect(up.links == .run, "a Friends-tab foreground search runs the links")
        #expect(up.discovery == .run, "and the admission door with them")
        #expect(presenceUp == .run, "presence runs on the Friends tab")
        #expect(recipeUp == .stop, "and the recipe listener does not — its tab set excludes Friends")
        host.setScenePhase(.background)
        guard let down = recorder.meshDirectives.last else {
            Issue.record("the backgrounding leg pushed nothing")
            return
        }
        let presenceDown = try #require(recorder.presenceDirectives.last, "presence pushed nothing")
        #expect(down.links == .stop, "backgrounding resolves foregroundOnly links to stop")
        #expect(down.discovery == .stop, "and the admission door with them — invariant 5")
        #expect(presenceDown == .stop, "presence stops on background")
        #expect(recorder.teardowns == 0, "and none of that is a teardown")
    }

    /// **The teardown fires once on a RISE, and not again until the condition clears.**
    ///
    /// `tearsDownSession` is a LEVEL — a wipe holds it for the length of the funnel, a duress
    /// session until a real-passcode unlock — and every leg setter re-decides, so without the host's
    /// latch a tab switch mid-wipe would re-run the whole teardown (`stopJoin()`, both listener
    /// stops) on a mesh that is already down. The second half is the other failure: a latch that is
    /// never cleared would leave a second duress session in the same launch with no teardown at all.
    @Test func theTeardownFiresOnceOnARiseAndAgainOnlyAfterItClears() throws {
        let (host, recorder) = Self.connectedHost()
        host.setScenePhase(.active)
        #expect(recorder.teardowns == 0, "no dominating input is in force at launch")
        host.setDeletingAllData(true)
        #expect(recorder.teardowns == 1, "the wipe's rising edge tears the session down once")
        // A labelled tuple again — bound through a `guard` rather than `#require`, like the pair in
        // `theMeshDoorReceivesTheResolvedLinksAndDiscoveryPair()`.
        guard let wiping = recorder.meshDirectives.last else {
            Issue.record("the wipe pushed no mesh directive")
            return
        }
        #expect(wiping.links == .stop && wiping.discovery == .stop,
                "and every mesh radio is stood down in the same push")
        host.setSelectedTab(.social)
        host.setAllowsNearbyPresence(true)
        #expect(recorder.teardowns == 1, "a leg change under a standing wipe must not re-run it")
        host.setDeletingAllData(false)
        #expect(recorder.teardowns == 1, "and clearing the condition tears nothing down by itself")
        host.setAppLockState(.duress)
        #expect(recorder.teardowns == 2, "a fresh dominating input arms the latch again")
    }

    /// The general claim the five cells above are instances of: over a sequence that exercises every
    /// setter the host declares, the gates the host writes are exactly ``legSteps``' hand-derived
    /// literals, in order.
    ///
    /// The expectation is INDEPENDENT of the code under test on purpose. Re-deciding
    /// `ProximityRunPolicy.decide(host.inputs).accessGate` here would ask the host's own inputs for
    /// the answer the host just wrote from those same inputs, so nothing could ever differ; the list
    /// on ``legSteps`` is written out from the gate's three rules instead, and a setter that
    /// assigned the wrong field lands on a literal that says otherwise.
    ///
    /// The host is not allowed a second opinion about the gate — it neither builds one nor
    /// deduplicates one. `MeshNetworkManager.applyRoutedAccessGate(_:now:)` owns the edge and
    /// already ignores an unchanged gate, which is why the write count here is one per leg update
    /// rather than one per CHANGED leg update, and why seven of the thirteen literals repeat a value
    /// already written.
    @Test func everyWrittenGateIsTheHandDerivedGateForThatStep() {
        let (host, recorder) = Self.connectedHost()
        var expected: [MeshRoutedAccessGate] = []
        // R2: bounded by the literal step list.
        for entry in Self.legSteps {
            entry.step(host)
            expected.append(entry.expected)
        }
        let everyGateMatchesItsLiteral = recorder.gates == expected
        #expect(recorder.gates.count == Self.legSteps.count,
                "every leg update must write exactly once")
        #expect(everyGateMatchesItsLiteral,
                "a written gate differs from the literal the gate's own rules derive for that step")
        #expect(recorder.instants.count == recorder.gates.count,
                "every write is stamped with the instant the manager judges it against")
    }

    // MARK: - The poller's wall (P7 item 4)

    /// **The three session consumers are called from the poller's door and nowhere else in the app
    /// target**, each exactly once.
    ///
    /// The counting shape is `theProximityRadiosAreDrivenOnlyFromTheHostsDoors()`'s, and it is owed
    /// for a sharper reason here: these three have had NO shipping caller since P3 — detection is on
    /// demand *by design so that nothing spins* — so the first caller is the one that decides
    /// whether the design survives. A second call site anywhere would be a second cadence, and the
    /// counts are occurrences rather than a file list because a second call parked inside
    /// `FernletApp.swift` would leave the list right and the claim already false.
    ///
    /// Non-vacuity first: a sweep handed a wrong root enumerates nothing and passes green.
    @Test func theSessionConsumersAreCalledOnlyFromThePollersDoor() throws {
        let sources = try Self.appSources()
        #expect(!sources.isEmpty, "the App/ sweep found no Swift files at all")
        #expect(sources.contains(where: { $0.name == "FernletApp.swift" }),
                "the App/ sweep no longer reaches FernletApp.swift, so every count below is vacuous")
        #expect(sources.contains(where: { $0.name == "ProximityRunPolicyHost.swift" }),
                "the sweep no longer reaches the host, which is the other file that could grow one")
        var strays: [String] = []
        var inFernletApp = 0
        // R2: three needles over the app target's own file list.
        for source in sources {
            for needle in Self.sessionConsumers {
                let hits = Self.occurrences(of: needle, in: source.code)
                guard hits > 0 else { continue }
                if source.name == "FernletApp.swift" {
                    inFernletApp += hits
                } else {
                    strays.append("\(source.name): \(needle) ×\(hits)")
                }
            }
        }
        #expect(strays.isEmpty, "a session consumer is called from outside the poller's one door")
        #expect(inFernletApp == Self.sessionConsumers.count,
                "each of the three consumers must be spelled exactly once in the app target")
    }

    /// The containment and ORDER half: all three calls sit inside `mountRoutedRunPolicy(`'s
    /// brace-matched body, in the order one tick makes them.
    ///
    /// Split from the count above only to stay inside the 60-line rule; the two are one claim. The
    /// order is asserted by INDEX inside that body rather than by reading the closure, because the
    /// order is the decision this item took: ceiling first (it can end the session, after which the
    /// other two are refused rather than acting on an expired one), then the idle lapse, then the
    /// partition evaluation — which is what ARMS the window the lapse reads, so swapping the last
    /// two would let one tick both arm a thirty-minute window and judge it.
    @Test func thePollDoorsThreeCallsSitInsideTheMountInTheDecidedOrder() throws {
        let appCode = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletApp.swift"))
        let mount = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func mountRoutedRunPolicy(", in: appCode),
            "the launch mount was renamed, or its brace-matched body does not close"
        )
        #expect(!mount.contains("private func restoreMeshSessionContextIfNeeded"),
                "the body matcher is measuring the file rather than the brace-matched mount")
        var indices: [Int] = []
        // R2: bounded by the three needles.
        for needle in Self.sessionConsumers {
            #expect(Self.occurrences(of: needle, in: mount) == 1,
                    "a session consumer is not spelled exactly once inside the mount")
            guard let found = mount.range(of: needle) else { continue }
            indices.append(mount.distance(from: mount.startIndex, to: found.lowerBound))
        }
        #expect(indices.count == Self.sessionConsumers.count,
                "a needle in the order list is not in the mount at all, so the order below is vacuous")
        let inTheDecidedOrder = indices == indices.sorted() && Set(indices).count == indices.count
        #expect(inTheDecidedOrder, "ceiling, then idle lapse, then partition — the order IS the decision")
        #expect(mount.contains("monotonicElapsed: nil"),
                "the ceiling call must measure from the manager's own monotonic origin, not the app's")
        #expect(mount.contains("runPolicyHost.setSessionLive("),
                "the mount no longer seeds the leg that switches the poller on")
    }

    /// **Inside ProximityKit the three consumers gained no caller**, which is what keeps "on demand,
    /// so that nothing spins" true of the package after the app grew a cadence.
    ///
    /// The counts are MEASURED at this commit and move only with a decision: one declaration each
    /// for the ceiling and the idle lapse, and three for partition — its two declarations plus
    /// `evaluatePartition(now:)`'s call to its own `reachable:` overload, which was the ONLY
    /// non-test caller of any of them before this item.
    @Test func theSessionConsumersGainedNoCallerInsideProximityKit() throws {
        let sources = try Self.proximityKitSources()
        #expect(!sources.isEmpty, "the ProximityKit sweep found no Swift files at all")
        #expect(sources.contains(where: { $0.name == "MeshNetworkManager.swift" }),
                "the sweep no longer reaches the file that declares all three, so the counts are vacuous")
        var counted: [String: Int] = [:]
        // R2: three needles over ProximityKit's own file list.
        for source in sources {
            for needle in Self.sessionConsumers {
                counted[needle, default: 0] += Self.occurrences(of: needle, in: source.code)
            }
        }
        var mismatched: [String] = []
        // R2: bounded by the three pinned needles.
        for (needle, pinned) in Self.proximityKitConsumerCounts where counted[needle] != pinned {
            mismatched.append("\(needle): \(counted[needle] ?? 0), pinned at \(pinned)")
        }
        #expect(counted.count == Self.sessionConsumers.count, "a needle was never counted at all")
        #expect(mismatched.isEmpty, """
            a session consumer's spelling count inside ProximityKit moved without this pin moving — \
            re-measure it and say which decision moved it, because a new in-package caller is a \
            second cadence beside the app's one poller
            """)
    }

    // MARK: - The poller, armed and cancelled

    /// **Nothing is armed until a session is live**, and arming is not a push.
    ///
    /// `isPollerArmed` rather than a tick count, because "nothing may spin" is a claim about the
    /// task not EXISTING: a cancelled task and an absent one tick equally little, and only one of
    /// them is what this host promises.
    @Test func thePollerIsNilUntilASessionIsLiveAndArmsOnTheRise() {
        let (host, recorder) = Self.connectedHost()
        #expect(!host.isPollerArmed, "with the liveness leg false there is no task at all")
        host.setSessionLive(true)
        #expect(host.isPollerArmed, "the liveness RISE arms the one timer this host owns")
        #expect(recorder.polls.isEmpty, "arming is not a tick")
        #expect(recorder.gates.isEmpty,
                "the liveness leg is the poller's switch, not a policy input — it must push nothing")
        #expect(recorder.everyRadioDirective.isEmpty, "and move no radio")
        host.setSessionLive(false)
    }

    /// A FALL cancels and nils the handle; a second rise arms again; a repeated `true` is the same
    /// one timer.
    ///
    /// The repeat matters more than it looks: re-arming cancels the sleeping one-shot and starts its
    /// interval over, so a leg re-fed faster than the interval would never tick at all. This setter
    /// is the ONE on the host that deduplicates, and this is the cell that says so.
    @Test func aLivenessFallCancelsThePollerAndASecondRiseArmsItAgain() {
        let (host, recorder) = Self.connectedHost()
        host.setSessionLive(true)
        host.setSessionLive(false)
        #expect(!host.isPollerArmed, "the FALL cancels the handle and nils it")
        host.setSessionLive(true)
        #expect(host.isPollerArmed, "a second rise arms it again")
        host.setSessionLive(true)
        host.setSessionLive(true)
        #expect(host.isPollerArmed, "and a repeated true is the same one timer")
        #expect(recorder.polls.isEmpty,
                "none of that ticked — this host carries the shipping 30-second interval")
        host.setSessionLive(false)
        #expect(!host.isPollerArmed, "the last fall leaves nothing behind")
    }

    /// **The real arm, exercised**: an injected millisecond interval, a sleeping one-shot, a tick,
    /// and the one-shot it arms in its place.
    ///
    /// The other poller cells drive `pollNow(at:)` directly, which proves what a tick DOES and
    /// nothing about whether one ever happens; this is the cell that awaits the timer itself. The
    /// gap assertion is the "exactly one timer" claim made observable: one self-re-arming one-shot
    /// can never produce two ticks inside one interval, and a second stacked timer would produce a
    /// gap near zero. Half the interval is the threshold, which leaves a 2× margin for a loaded
    /// scheduler — and a loaded scheduler makes ticks LATER, never sooner.
    @Test func theArmedPollerTicksOnItsIntervalAndNeverStacksASecondTimer() async {
        let interval: TimeInterval = 0.05
        let (host, recorder) = Self.polledHost(interval: interval)
        host.setSessionLive(true)
        host.setSessionLive(false)
        host.setSessionLive(true)
        host.setSessionLive(true)
        await Self.waitForPolls(3, in: recorder)
        host.setSessionLive(false)
        #expect(!host.isPollerArmed, "the fall must cancel the re-armed one-shot as well as the first")
        #expect(recorder.polls.count >= 3,
                "the armed poller must tick and RE-ARM itself, not fire once and stop")
        let gaps = recorder.pollGaps
        let everyGapIsAWholeInterval = gaps.allSatisfy { $0 >= interval / 2 }
        #expect(!gaps.isEmpty, "fewer than two ticks, so the gap claim below is vacuous")
        #expect(everyGapIsAWholeInterval,
                "two ticks arrived inside one interval, so a second timer is in flight")
    }

    /// **The no-spin cell.** With the liveness leg false, several intervals pass and nothing ticks.
    @Test func nothingTicksWhileNoSessionIsLive() async {
        let (host, recorder) = Self.polledHost(interval: 0.01)
        #expect(!host.isPollerArmed, "with the leg false there is no task to spin")
        // R2: twenty sleeps of 10 ms — twenty of the injected intervals, and then some.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.polls.isEmpty, "a poller that never armed cannot have ticked")
        #expect(!host.isPollerArmed, "and nothing armed itself in the meantime")
    }

    /// One tick is ONE call of the ONE door, carrying the instant it woke at — and it decides
    /// nothing: no gate, no directive, no teardown.
    @Test func aTickCallsThePollDoorOnceWithTheInstantItWokeAt() async {
        let (host, recorder) = Self.connectedHost()
        let before = Date()
        await host.pollNow()
        #expect(recorder.polls.count == 1, "one tick is one call of the one door")
        let stamp = recorder.polls.last ?? Date.distantPast
        #expect(stamp >= before, "the tick hands the door the instant it woke at")
        #expect(recorder.gates.isEmpty, "a tick is not a push — the policy decides nothing here")
        #expect(recorder.everyRadioDirective.isEmpty, "and no radio moves")
        #expect(recorder.teardowns == 0, "and nothing is torn down")
    }

    /// A tick before the doors are installed reaches nothing — the same latch every other write on
    /// this host carries.
    @Test func aTickBeforeTheDoorsAreInstalledReachesNothing() async {
        let host = ProximityRunPolicyHost()
        host.setSessionLive(true)
        #expect(host.isPollerArmed,
                "the leg is recorded and the timer armed before there is a store, exactly like every leg")
        await host.pollNow()
        let recorder = ProximityRunDoorRecorder()
        Self.connect(host, to: recorder)
        await host.pollNow()
        #expect(recorder.polls.count == 1,
                "only the tick after the doors were installed may have reached one")
        host.setSessionLive(false)
    }

    /// **A re-mount moves the poller to the new door.** A tick in flight closes over the door it was
    /// installed with, so a second `connect(…)` cancels it and arms a fresh one against the
    /// replaced set.
    @Test func aSecondConnectMovesThePollerToTheNewDoor() async {
        let first = ProximityRunDoorRecorder()
        let host = ProximityRunPolicyHost()
        Self.connect(host, to: first)
        host.setSessionLive(true)
        #expect(host.isPollerArmed, "the first mount's poller is armed")
        let second = ProximityRunDoorRecorder()
        Self.connect(host, to: second)
        #expect(host.isPollerArmed, "a re-mount replaces the tick in flight rather than losing it")
        await host.pollNow()
        #expect(second.polls.count == 1, "the tick reaches the re-mounted door")
        #expect(first.polls.isEmpty, "and never the replaced one")
        host.setSessionLive(false)
        #expect(!host.isPollerArmed, "and the fall still cancels after a re-mount")
    }

    /// **The teardown cancels the poller**, by lowering the liveness leg rather than by reaching
    /// past it.
    ///
    /// `stopJoin()` empties the committed slots and clears the group-key state, so the session the
    /// poller was judging is over the moment that door returns; waiting for `ContentView`'s
    /// `.onChange` to notice would be waiting for an observation edge in the middle of a delete-all.
    @Test func theTeardownLowersTheLivenessLegAndCancelsThePoller() {
        let (host, recorder) = Self.connectedHost()
        host.setScenePhase(.active)
        host.setSessionLive(true)
        #expect(host.isPollerArmed, "a live session arms the poller")
        host.setDeletingAllData(true)
        #expect(recorder.teardowns == 1, "the wipe's rising edge tears the session down once")
        #expect(!host.isPollerArmed,
                "and the teardown lowers the liveness leg, so no tick outlives the session it judged")
        host.setSessionLive(true)
        #expect(host.isPollerArmed,
                "the leg is a value again afterwards: a fresh session re-arms in the ordinary way")
        host.setSessionLive(false)
    }

    // MARK: - The three consumers, driven to their verdicts through a tick

    /// **THE HEADLINE (plan §12.3 finding 3).** A live mesh whose ceiling has elapsed is ENDED by
    /// ONE tick.
    ///
    /// P6 item 2's founding change made this the item's first live consequence: a mesh outlives its
    /// links, `enforceSessionCeiling(now:monotonicElapsed:)` had no shipping caller, and so a
    /// session could run past the six-hour bound with nothing left to notice. The rig is founded six
    /// hours and an hour ago against the REAL clock, because the signed bound is judged against the
    /// instant the tick hands the door — the SIGNED bound is what this cell drives, since
    /// `monotonicElapsed: nil` measures a monotonic origin armed seconds ago.
    ///
    /// What it claims is the LOCAL ending, and that is deliberate: the rig's roster is three, and
    /// `MeshDevelopmentPlan.permitsTermination(_:)` refuses to sign a `terminated.v1` above a final
    /// pair, so the announcement half is refused here and is `MeshSessionLifecycleManagerTests`'
    /// subject over its own two-member rig. `enforceSessionCeiling` ends local participation either
    /// way — the state moves before the effects run — and "the session is over on this device" is
    /// the thing that was missing.
    @Test func oneTickEndsALiveMeshWhoseCeilingHasElapsed() async throws {
        let elapsed = MeshSessionCeiling.ceilingSeconds + 3_600
        let rig = try Self.pollerRig(createdAt: Date().addingTimeInterval(-elapsed))
        #expect(rig.manager.isSessionLive, "the rig must start from a LIVE mesh or the cell is vacuous")
        rig.host.setSessionLive(true)
        #expect(rig.host.isPollerArmed, "which is what arms the poller in the first place")
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await rig.host.pollNow()
        }
        rig.host.setSessionLive(false)
        #expect(rig.recorder.polls.count == 1, "exactly one tick ran")
        #expect(rig.manager.sessionState == .expired,
                "a live mesh whose ceiling has elapsed must be ENDED by one tick")
        #expect(!rig.manager.isSessionLive, "and the session predicate must agree that it ended")
        rig.manager.leaveMesh()
    }

    /// The same rig INSIDE its ceiling ends nothing — the negative the headline needs to mean
    /// anything.
    ///
    /// The tick still runs all three consumers, and the partition call still finds a roster of three
    /// with one reachable member, so the session is `partitioned` rather than untouched. That is the
    /// point: `partitioned` is a LIVE state, and the cell is about the ceiling.
    @Test func aTickInsideTheCeilingEndsNothing() async throws {
        let rig = try Self.pollerRig(createdAt: Date())
        rig.host.setSessionLive(true)
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await rig.host.pollNow()
        }
        rig.host.setSessionLive(false)
        #expect(rig.recorder.polls.count == 1, "the same rig, the same one tick")
        #expect(rig.manager.sessionState != .expired,
                "a ceiling six hours away must end nothing at all")
        #expect(rig.manager.isSessionLive, "and the session stays live")
        rig.manager.leaveMesh()
    }

    /// **Partition, through a tick.** A roster of three that can reach only itself is a partition of
    /// one, and the tick's third call is what finds it.
    @Test func oneTickPartitionsALiveMeshThatCanReachNobody() async throws {
        let rig = try Self.pollerRig(createdAt: Date())
        #expect(rig.names.count == 3, "a roster of three, or there is nothing to be partitioned from")
        #expect(rig.manager.branchView == nil, "this device has not looked yet")
        rig.host.setSessionLive(true)
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await rig.host.pollNow()
        }
        rig.host.setSessionLive(false)
        #expect(rig.manager.sessionState == .partitioned,
                "the tick's third call finds a roster of three and one reachable member")
        #expect(rig.manager.branchView?.isAlone == true, "a partition of one")
        #expect(rig.manager.idleLapseDeadline != nil,
                "and the partition ARMS the window the tick's second call reads")
        rig.manager.leaveMesh()
    }

    /// **The idle lapse, through a tick — and the ORDER, made behavioural.**
    ///
    /// Two ticks with an injected clock thirty minutes apart. The FIRST tick's partition call arms
    /// the idle window; the SECOND tick's idle-lapse call reads it and stops participation. That
    /// dependency is exactly why the partition call is last: were it first, one tick could arm a
    /// thirty-minute window and judge it in the same breath.
    @Test func aLaterTickLapsesTheWindowAnEarlierTicksPartitionArmed() async throws {
        let rig = try Self.pollerRig(createdAt: Date())
        let start = Date()
        rig.host.setSessionLive(true)
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await rig.host.pollNow(at: start)
            await rig.host.pollNow(at: start.addingTimeInterval(MeshNetworkManager.idleWindowSeconds))
        }
        rig.host.setSessionLive(false)
        #expect(rig.recorder.polls.count == 2, "two ticks, thirty minutes apart on the injected clock")
        #expect(rig.manager.sessionState == .localIdleStop,
                "the second tick's idle-lapse call must stop participation")
        #expect(rig.manager.idleLapseDeadline == nil, "and clear the window it just spent")
        rig.manager.leaveMesh()
    }
}
