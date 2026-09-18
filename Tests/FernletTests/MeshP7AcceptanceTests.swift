// MeshP7AcceptanceTests.swift
// FernletTests
//
// Network migration **P7's acceptance battery** (plan §13.4, launcher item 7): one serialized suite
// per clause, each promoting the named tier-1 claims of the item it speaks for and running its
// clause END TO END on the shipping seams, so CI gating a clause fails on this battery's own
// assertions. Where an exhaustive space already exists it is CITED and re-run whole rather than
// sampled — the §11.4 idiom, and the reason the run-policy clause evaluates all 23 040 rows here.
//
// **Six suites.** The run policy (item 1), the gate's single writer (item 2), the radios' seams
// (item 3), the poller's three consumers each driven to a verdict (item 4), the resume decision
// over every restore outcome (item 5), and an honesty suite naming what the battery does not claim.
// `CIGateSelectorBoundaryTests` therefore moves its battery pin from 36 to 42.
//
// **Written without a toolchain.** The session that wrote this battery (2026-09-18) could not build
// or run it; its first Mac run is its first execution, and the honesty suite says so rather than
// leaving it to be inferred. The two determinism digests keep their one home in
// `MeshP5DeterminismAcceptanceTests`; nothing in P7 touched the overlay, a schedule draw or
// `MeshScheduleEvent`, and this file spells neither digest.

import Foundation
import SwiftUI
import Testing
@testable import FernletCrypto
import LocalPersistence
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshP7Acceptance

/// The thin rig P7's clauses share: the source walker, the pinned binding, and a store.
@MainActor
enum MeshP7Acceptance {

    /// Every Swift file under `relativePath`, comment-stripped.
    nonisolated static func sources(under relativePath: String) throws -> [(name: String, code: String)] {
        let root = RepoRoot.url(relativePath)
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        var sources: [(name: String, code: String)] = []
        // R2: bounded by the root's own file list.
        for file in files.sorted(by: { $0.path < $1.path }) {
            sources.append((
                file.lastPathComponent,
                MeshRoutedSourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8))
            ))
        }
        return sources
    }

    /// The file names in which `needle` occurs, one entry per occurrence.
    nonisolated static func homes(of needle: String, in sources: [(name: String, code: String)]) -> [String] {
        var homes: [String] = []
        // R2: bounded by the file list.
        for source in sources {
            let count = source.code.components(separatedBy: needle).count - 1
            homes.append(contentsOf: Array(repeating: source.name, count: count))
        }
        return homes
    }

    /// A poll under the founding rig's pinned install binding, so a persisting effect (the ceiling's
    /// termination mark, the idle lapse) is written rather than refused.
    static func poll(_ manager: MeshNetworkManager, now: Date) async -> MeshSessionPollReport {
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await manager.pollSession(now: now)
        }
    }

    /// A real store on its own directories, in `AgeGateWiringTests`'s shape.
    static func makeStore(_ name: String) -> FernletStore {
        FernletStore(
            repository: LocalFernletRepository(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(name)-\(UUID().uuidString).json")
            ),
            sensitiveVisibilityDefaults: UserDefaults(suiteName: "\(name)-\(UUID().uuidString)") ?? .standard,
            appGroupDirectory: uniqueAppGroupDirectory(),
            photoDocumentsDirectory: uniquePhotoDirectory(),
            proximitySupportDirectory: uniqueProximityDirectory(),
            heartDropKeychainService: uniqueHeartDropKeychainService()
        )
    }

    /// One stated instant for the store clauses; nothing here reads a clock.
    static let instant = Date(timeIntervalSince1970: 1_700_000_000)

    /// A founded pair, settled, with the election's roles resolved.
    struct FoundedPair {
        /// The rig; the caller tears it down.
        let rig: MeshFoundingRig
        /// The election's winner.
        let winner: MeshNetworkManager
        /// The election's yielder.
        let yielder: MeshNetworkManager
    }

    /// Founds a pair and resolves the election by role, never by index.
    static func foundPair(label: String) async throws -> FoundedPair {
        let rig = try MeshFoundingRig.build(2, label: label)
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle(until: { rig.roster(0).count == 2 && rig.roster(1).count == 2 })
        let lowerFounds = MeshNetworkManager.foundsPairwiseMesh(
            local: rig.identities[0].localFingerprint, peer: rig.identities[1].localFingerprint
        )
        return FoundedPair(
            rig: rig,
            winner: rig.nodes[lowerFounds ? 0 : 1].manager,
            yielder: rig.nodes[lowerFounds ? 1 : 0].manager
        )
    }
}

// MARK: - (a) The run policy

/// **Item 1: the matrix, whole.** Every row of the input product, evaluated and compared with its
/// flat statement; §13's load-bearing rows by hand; and the only value the app can feed today
/// claims no background anywhere.
@MainActor
@Suite(.serialized)
struct MeshP7RunPolicyAcceptanceTests {

    /// All 23 040 rows, distinct, each agreeing with its flat re-statement, `.inactive` a foreground
    /// scene on every one.
    @Test func theInputProductIsWholeAndEveryRowAgreesWithItsFlatStatement() {
        let rows = ProximityRunPolicyProduct.rows()
        #expect(rows.count == 23_040 && Set(rows).count == 23_040,
                "3 × 5 × 4 × 3 × 2⁷ rows, no two the same — a new input must move this number deliberately")
        let agrees = rows.allSatisfy { r in
            let v = ProximityRunPolicy.verdict(for: r)
            return v.mesh == ProximityRunPolicyProduct.expectedMesh(r)
                && v.discovery == ProximityRunPolicyProduct.expectedDiscovery(r)
                && v.presence == ProximityRunPolicyProduct.expectedPresence(r)
                && v.recipeShare == ProximityRunPolicyProduct.expectedRecipeShare(r)
        }
        #expect(agrees, "every radio on every row agrees with its flat statement")
        let inactiveIsForeground = rows.filter { $0.scenePhase == .inactive }.allSatisfy {
            ProximityRunPolicy.verdict(for: $0) == ProximityRunPolicy.verdict(for: ProximityRunPolicyProduct.copy($0, phase: .active))
        }
        #expect(inactiveIsForeground, "an inactive scene is a foreground scene on every row")
    }

    /// §13's load-bearing rows.
    @Test func theLoadBearingRowsOfSection13() {
        let continued = ProximityRunPolicy.verdict(for: ProximityRunPolicyProduct.row(
            phase: .background, continuation: .running, session: .peerCommitted
        ))
        #expect(continued.mesh == .run && continued.discovery == .stop,
                "user-started mesh + CPT granted: the mesh runs in the background, discovery never does (invariant 5)")
        #expect(continued.presence == .stop && continued.recipeShare == .stop, "presence and recipe stop on background")
        let refused = ProximityRunPolicy.verdict(for: ProximityRunPolicyProduct.row(continuation: .refused, session: .peerCommitted))
        #expect(refused.mesh == .foregroundOnly, "CPT refused: the mesh is foreground-only")
        let stops = [
            ProximityRunPolicyProduct.row(wipe: true, session: .peerCommitted),
            ProximityRunPolicyProduct.row(belowAge: true, session: .peerCommitted),
            ProximityRunPolicyProduct.row(duress: true, session: .peerCommitted)
        ].map { ProximityRunPolicy.verdict(for: $0) }
        let allStopped = stops.allSatisfy {
            $0.mesh == .stop && $0.discovery == .stop && $0.presence == .stop && $0.recipeShare == .stop
        }
        #expect(allStopped, "delete-all, below-age and duress: every radio stops")
    }

    /// Under `.notRequested` — the only value the app can feed until P8 — no radio claims the
    /// background, and the gate reads only its three facts.
    @Test func nothingClaimsTheBackgroundUnderTheOnlyValueTheAppCanFeed() {
        let rows = ProximityRunPolicyProduct.rows().filter { $0.continuation == .notRequested }
        #expect(rows.count == 5_760, "a quarter of the product")
        let inert = rows.allSatisfy { r in
            let v = ProximityRunPolicy.verdict(for: r)
            return v.mesh != .run && v.discovery != .run && v.presence != .run && v.recipeShare != .run
        }
        #expect(inert, "no radio ever claims the background while the task is not requested")
        let gateIsThreeFacts = rows.allSatisfy { r in
            ProximityRunPolicy.verdict(for: r).routedAccessGate == MeshRoutedAccessGate(
                protectedDataAvailable: r.protectedDataAvailable,
                appIsForeground: FernletApp.routedGateForeground(for: r.scenePhase),
                duressActive: r.duressSessionActive
            )
        }
        #expect(gateIsThreeFacts, "and the gate is the three facts the app assembled before P7, nothing more")
    }
}

// MARK: - (b) The gate's single writer

/// **Item 2: one writer, and it writes what the policy decided.**
@MainActor
@Suite(.serialized)
struct MeshP7GateWriterAcceptanceTests {

    /// Exactly one call site writes the gate outside ProximityKit, the gate value is assembled once,
    /// and a real store's manager holds exactly the gate the policy decided on every edge.
    @Test func theGateHasOneWriterAndItWritesWhatThePolicyDecided() throws {
        let sources = try MeshP7Acceptance.sources(under: "App")
        #expect(sources.count >= 100, "the app-target scan lost its files")
        #expect(MeshP7Acceptance.homes(of: "applyRoutedAccessGate(", in: sources) == ["FernletStore.swift"],
                "the routed access gate has exactly one writer outside ProximityKit — the store's run-policy core")
        #expect(MeshP7Acceptance.homes(of: "MeshRoutedAccessGate(", in: sources) == ["ProximityRunPolicy.swift"],
                "and the gate value is assembled exactly once, by the policy")

        let store = MeshP7Acceptance.makeStore("p7-gate")
        #expect(store.meshNetworkManager.routedAccessGate == .closed, "every manager starts fail-closed")
        let opened = store.applyProximityRunPolicy(
            scenePhase: .active, protectedDataAvailable: true, appLockEngaged: true,
            duressSessionActive: false, now: MeshP7Acceptance.instant
        )
        #expect(store.meshNetworkManager.routedAccessGate == opened.routedAccessGate && opened.routedAccessGate.isOpen,
                "a foreground, unlocked-device edge opens the gate the manager holds — the app lock closes no leg")
        let closed = store.applyProximityRunPolicy(
            scenePhase: .background, protectedDataAvailable: false, appLockEngaged: true,
            duressSessionActive: false, now: MeshP7Acceptance.instant
        )
        #expect(store.meshNetworkManager.routedAccessGate == closed.routedAccessGate && !closed.routedAccessGate.isOpen,
                "a background, locked-device edge closes it — and the manager holds exactly that")
    }

    /// The scene file hands its six edges down and decides nothing.
    @Test func theSceneFileHandsSixEdgesDownAndDecidesNothing() throws {
        let app = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletApp.swift"))
        let edges = app.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("pushProximityRunPolicy(") && !$0.contains("private func") }
        #expect(edges.count == 6, "the launch mount, two scene legs, two protected-data notifications, duress")
        #expect(!app.contains("routedGateForeground(for:"), "and it reads the foreground mapping nowhere — the policy does, once")
    }
}

// MARK: - (c) The radios' seams

/// **Item 3: the seams decide as a table, and one file speaks every radio verb.**
@MainActor
@Suite(.serialized)
struct MeshP7RadioSeamsAcceptanceTests {

    /// The transition table's headline rows, end to end through the pure half.
    @Test func theHeadlineTransitionsDecideTheRightVerbs() {
        let fresh = ProximityRunPolicy.verdict(for: ProximityRunPolicyProduct.row())
        let none = ProximityRunTransition.MeshFacts(isSearching: false, isInSession: false, hasCommittedPeer: false)
        #expect(ProximityRunTransition.actions(from: nil, to: fresh, mesh: none)
                == [.startJoin, .armDiscoveryTimeout, .presence(.foregroundOnly), .recipeShare(.stop)],
                "a fresh Friends visit starts a search, arms the timeout, starts presence")
        let committed = ProximityRunPolicy.verdict(for: ProximityRunPolicyProduct.row(session: .peerCommitted))
        let offTab = ProximityRunPolicy.verdict(for: ProximityRunPolicyProduct.row(tab: .home, session: .peerCommitted))
        let live = ProximityRunTransition.MeshFacts(isSearching: true, isInSession: true, hasCommittedPeer: true)
        #expect(ProximityRunTransition.actions(from: committed, to: offTab, mesh: live)
                == [.cancelDiscoveryTimeout, .recipeShare(.foregroundOnly)],
                "a tab exit keeps a committed link — no stopJoin over it")
        let duress = ProximityRunPolicy.verdict(for: ProximityRunPolicyProduct.row(duress: true, session: .peerCommitted))
        #expect(ProximityRunTransition.actions(from: committed, to: duress, mesh: live)
                == [.cancelDiscoveryTimeout, .leaveSession, .presence(.stop)],
                "a hard stop tears a live session down through leaveSession()")
        let continued = ProximityRunPolicy.verdict(for: ProximityRunPolicyProduct.row(continuation: .running, session: .peerCommitted))
        let continuedBackground = ProximityRunPolicy.verdict(for: ProximityRunPolicyProduct.row(
            phase: .background, continuation: .running, session: .peerCommitted
        ))
        #expect(ProximityRunTransition.actions(from: continued, to: continuedBackground, mesh: live)
                == [.refuseBackgroundDiscoveryStop, .presence(.stop)],
                "the one transition P7 cannot execute is refused by name, links kept")
    }

    /// Every mesh radio verb under `App/` lives in the seams file once (the DEBUG harness's
    /// `startJoin()` exempted by name), no listener is started or stopped by a qualified call, and
    /// the view names none of the retired chain.
    @Test func oneFileSpeaksEveryRadioVerb() throws {
        let sources = try MeshP7Acceptance.sources(under: "App")
        let seams = "ProximityRunSeams.swift"
        #expect(MeshP7Acceptance.homes(of: ".startJoin(", in: sources).sorted() == ["MeshRejectionMatrixHarness.swift", seams],
                "startJoin(): the seams once, the Lane C harness once, by name")
        #expect(MeshP7Acceptance.homes(of: ".stopJoin(", in: sources) == [seams], "stopJoin(): the seams once")
        #expect(MeshP7Acceptance.homes(of: ".resumeSearchingForPartitionedMesh(", in: sources) == [seams], "the resume: the seams once")
        #expect(MeshP7Acceptance.homes(of: ".leaveSession()", in: sources) == [seams], "the silent teardown: the seams once")
        let listeners = ["presenceManager.start(", "presenceManager.stop(", "recipeShareManager.start(", "recipeShareManager.stop("]
        let noQualifiedListenerCall = listeners.allSatisfy { MeshP7Acceptance.homes(of: $0, in: sources).isEmpty }
        #expect(noQualifiedListenerCall, "no listener is started or stopped by a qualified call anywhere")
        let view = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ContentView.swift"))
        let retired = ["startFriendsDiscovery", "stopFriendsDiscovery", "updatePresenceListener", "updateRecipeShareListener", "shouldRunPresence"]
        let viewIsClean = retired.allSatisfy { !view.contains($0) }
        #expect(viewIsClean, "the view names none of the retired chain")
    }
}

// MARK: - (d) The poller

/// **Item 4: the three consumers, each driven to its verdict through the one poll seam.**
@MainActor
@Suite(.serialized)
struct MeshP7PollerAcceptanceTests {

    /// The ceiling: a yielding founder's session — which held no ceiling at all before P7 — ends at
    /// the winner's own signed deadline, through the poll.
    @Test func theCeilingEndsAYieldersSessionThroughThePoll() async throws {
        let pair = try await MeshP7Acceptance.foundPair(label: "p7-poll-ceiling")
        defer { pair.rig.teardown() }
        let deadline = try #require(pair.yielder.sessionCeiling?.hardDeadline, "the yielder armed a ceiling from the adopted mesh")
        #expect(deadline == pair.winner.sessionCeiling?.hardDeadline, "the winner's own signed deadline")
        let late = await MeshP7Acceptance.poll(pair.yielder, now: deadline.addingTimeInterval(3_600))
        #expect(late.polled && late.ceilingReached && !late.sessionLiveAfter, "an hour past it, the ceiling ends the session")
        #expect(!pair.yielder.isSessionLive, "P6 §12.3 finding 3, closed")
    }

    /// Partition then idle lapse: a lost link is judged a partition on the next poll, the idle
    /// window it arms lapses on a poll past its deadline, and the state follows — in that order.
    @Test func aLostLinkIsJudgedAPartitionAndTheIdleWindowThenLapsesThroughThePoll() async throws {
        let pair = try await MeshP7Acceptance.foundPair(label: "p7-poll-partition")
        defer { pair.rig.teardown() }
        let manager = pair.winner
        let slot = try #require(manager.slots.first, "the commit seated a slot")
        manager.evictSlotForTesting(peerID: slot.id)
        #expect(manager.isSessionLive && !manager.hasCommittedPeer, "a blip: the mesh outlived its link")
        let ceilingDeadline = try #require(manager.sessionCeiling?.hardDeadline)

        let judged = await MeshP7Acceptance.poll(manager, now: ceilingDeadline.addingTimeInterval(-5 * 3_600))
        #expect(judged.polled && !judged.ceilingReached, "an hour into the session the ceiling is far off")
        #expect(manager.branchView?.isPartitioned == true, "the poll re-derived the branch view over the live reachable set — self alone")
        #expect(manager.sessionState == .partitioned, "and the session is partitioned")
        let idleDeadline = try #require(manager.idleLapseDeadline, "a partition of one arms the 30-minute window")

        let lapsed = await MeshP7Acceptance.poll(manager, now: idleDeadline.addingTimeInterval(1))
        #expect(lapsed.polled && lapsed.idleLapsed, "one second past the window, the lapse is applied")
        #expect(manager.sessionState == .localIdleStop, "local participation stopped; membership did not move")
        #expect(manager.membershipVerifier?.roster.members.count == 2, "a partition and a lapse never shrink a roster")
    }

    /// A dead session polls nothing, and the app's timer rule says so too.
    @Test func aDeadSessionPollsNothingAndTheTimerRuleAgrees() async throws {
        let rig = try MeshFoundingRig.build(1, label: "p7-poll-dead")
        defer { rig.teardown() }
        let report = await MeshP7Acceptance.poll(rig.nodes[0].manager, now: MeshP7Acceptance.instant)
        #expect(report == .skipped, "no live session, no consumer runs")
        #expect(ProximitySessionPoller.decision(isSessionLive: false, isPolling: true) == .stop, "and a timer over it is stopped")
        #expect(ProximitySessionPoller.decision(isSessionLive: false, isPolling: false) == .keep, "or never started")
        #expect(ProximitySessionPoller.interval == 30, "at 30 s")
    }
}

// MARK: - (e) The resume decision

/// **Item 5: every restore outcome decides, and every presented case has its sentence.**
@MainActor
@Suite(.serialized)
struct MeshP7ResumeAcceptanceTests {

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

    /// Every outcome case decides, a session surface up silences all of them, and every presented
    /// case has its own card.
    @Test func everyRestoreOutcomeDecidesAndEveryPresentedCaseHasItsCard() {
        var outcomes: [MeshSessionRestoreOutcome] = [
            .resumable(Self.context()), .expired(Self.context()), .noSession,
            .retryAfterUnlock(MeshSessionDeferral(reason: .fileUnreadable, detail: "x")),
            .retryAfterRefusal(MeshSessionSealRefusal(operation: .open, cause: .installBindingUnavailable)),
            .quarantineCorruptFile(MeshSessionCorruption(detail: .emptyFile))
        ]
        // R2: bounded by the frozen reason vocabulary.
        for reason in MeshSessionTerminationReason.allCases {
            outcomes.append(.terminated(
                Self.context(termination: MeshSessionLocalTermination(reason: reason, at: MeshMembershipFixtures.base)), reason
            ))
        }
        #expect(outcomes.count == 14, "six shapes plus the eight terminations")
        let decided = outcomes.map {
            MeshSessionResumePresentation.presentation(outcome: $0, offersForegroundResume: true, isInSession: false)
        }
        #expect(decided.filter { $0 == .nothing }.count == 3, "the green field, the deferral and the refusal are silent")
        #expect(decided.contains(.offerResume) && decided.contains(.previousSessionCouldNotBeReopened), "the offer and the set-aside speak")
        #expect(decided.filter { if case .previousSessionEnded = $0 { return true } else { return false } }.count == 9,
                "the eight endings and the expiry speak as ended, never failed")
        let silenced = outcomes.allSatisfy {
            MeshSessionResumePresentation.presentation(outcome: $0, offersForegroundResume: true, isInSession: true) == .nothing
        }
        #expect(silenced, "a session surface up owns the tab")
        let carded = Set(decided).filter { $0 != .nothing }.allSatisfy { SessionResumeCopy.card(for: $0) != nil }
        #expect(carded, "every presented case has a card")
        #expect(SessionResumeCopy.card(for: .nothing) == nil, "and nothing to say shows none")
    }
}

// MARK: - (f) Honesty

/// **What P7's battery deliberately does NOT claim, named rather than implied.**
@MainActor
@Suite(.serialized)
struct MeshP7HonestyAcceptanceTests {

    /// No scene, no continuation task, no device lock and no UI run here; `.continuingInBackground`
    /// is unreachable because nothing in shipping raises `.backgrounded` / `.foregrounded`; the app
    /// feeds `.notRequested` and nothing else; the run vocabulary has four values; and the two
    /// determinism digests keep their one home. Written in a session with no toolchain: its first
    /// Mac run is its first execution.
    @Test func theBatteryNamesWhatItDoesNotClaim() throws {
        #expect(ProximityRunState.allCases.count == 4, "run, foregroundOnly, hold, stop — hold is P7's recorded deviation from §13")
        #expect(ProximityContinuationState.allCases.count == 4, "not requested, running, refused, expired")
        let app = try MeshP7Acceptance.sources(under: "App")
        #expect(MeshP7Acceptance.homes(of: "continuation: .running", in: app).isEmpty,
                "the app never feeds a running task — that is P8's claim")
        #expect(MeshP7Acceptance.homes(of: "continuation: .notRequested", in: app) == ["FernletStore.swift"],
                "it feeds .notRequested, once, in the run-policy core")
        let kit = try MeshP7Acceptance.sources(under: "FernletKit/Sources/ProximityKit")
        #expect(kit.count >= 100, "the ProximityKit scan lost its files")
        let raised = MeshP7Acceptance.homes(of: "applySessionEvent(.backgrounded", in: kit).count
            + MeshP7Acceptance.homes(of: "applySessionEvent(.foregrounded", in: kit).count
        #expect(raised == 0, "nothing in shipping raises .backgrounded or .foregrounded, so .continuingInBackground is unreachable")
        let me = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("Tests/FernletTests/MeshP7AcceptanceTests.swift"))
        let spellsADigest = me.contains("ca898" + "bcc") || me.contains("594b6" + "f77")
        #expect(!spellsADigest, "the two determinism digests keep their one home in MeshP5DeterminismAcceptanceTests")
    }

    /// The battery is gated: every suite in this file is named on the workflow's mesh step, and the
    /// selector wall's pin counts them.
    @Test func everySuiteHereIsOnTheMeshStep() throws {
        let workflow = try RepoRoot.source(".github/workflows/s3-wall.yml")
        let suites = ["MeshP7RunPolicyAcceptanceTests", "MeshP7GateWriterAcceptanceTests", "MeshP7RadioSeamsAcceptanceTests",
                      "MeshP7PollerAcceptanceTests", "MeshP7ResumeAcceptanceTests", "MeshP7HonestyAcceptanceTests"]
        let allGated = suites.allSatisfy { workflow.contains($0) }
        #expect(allGated, "every P7 clause suite is named on the mesh-batteries step")
    }
}
