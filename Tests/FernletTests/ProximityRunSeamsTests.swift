// ProximityRunSeamsTests.swift
// FernletTests
//
// Network migration P7 item 3: the seams' decision table and the retirement wall.
//
// `ProximityRunTransition.actions(from:to:mesh:)` is pure — last verdict, new verdict, the mesh
// manager's three live predicates → an ordered action list — so every "which radio verb, and
// when" claim the old `ContentView` chain made by construction is a row here: the fresh Friends
// visit, the tab exit that keeps a committed link, the tab exit that stands a blipped search down,
// the background exit, the return after a blip, the three hard stops, the cleared hard stop, and
// the one transition this phase refuses by name. The executor is a `switch` with nothing to
// decide, and the two listener seams are `switch`es too; neither is driven here, because a real
// manager starts a real radio — the honesty cell says so.
//
// The wall: every radio verb under `App/` lives in `ProximityRunSeams.swift`, exactly once each,
// except the DEBUG Lane C harness's own `startJoin()`, exempted BY NAME; the two listeners are
// never started or stopped by a qualified call anywhere; `ContentView` names none of the retired
// chain; and the store's own edges run the policy rather than reaching around it.

import Foundation
import SwiftUI
import Testing
import ProximityKit
@testable import Fernlet

/// The transition table, and the wall that keeps every radio verb in the seams file.
@Suite struct ProximityRunSeamsTests {

    // MARK: Fixtures

    /// One verdict from the policy, named by the facts that differ from a fresh Friends visit.
    private static func verdict(
        phase: ScenePhase = .active,
        tab: FernletTab = .social,
        duress: Bool = false,
        wipe: Bool = false,
        continuation: ProximityContinuationState = .notRequested,
        session: ProximitySessionPresence = .absent
    ) -> ProximityRunPolicy.Verdict {
        ProximityRunPolicy.verdict(for: ProximityRunPolicyProduct.row(
            phase: phase, tab: tab, lock: false, duress: duress, protected: true, belowAge: false,
            wipe: wipe, continuation: continuation, session: session, presence: true, recipe: true
        ))
    }

    /// The mesh manager's facts, named by what is up.
    private static func facts(
        searching: Bool = false, inSession: Bool = false, committed: Bool = false
    ) -> ProximityRunTransition.MeshFacts {
        ProximityRunTransition.MeshFacts(
            isSearching: searching, isInSession: inSession, hasCommittedPeer: committed
        )
    }

    /// The transition, shortened.
    private static func actions(
        from previous: ProximityRunPolicy.Verdict?,
        to next: ProximityRunPolicy.Verdict,
        _ mesh: ProximityRunTransition.MeshFacts
    ) -> [ProximityRunAction] {
        ProximityRunTransition.actions(from: previous, to: next, mesh: mesh)
    }

    // MARK: The table

    /// The first application counts every radio as an edge: a fresh Friends visit starts a fresh
    /// search, arms the tab's timeout, starts presence and leaves recipe stopped.
    @Test func theFirstApplicationTreatsEveryRadioAsAnEdge() {
        let fresh = Self.actions(from: nil, to: Self.verdict(), Self.facts())
        #expect(fresh == [.startJoin, .armDiscoveryTimeout, .presence(.foregroundOnly), .recipeShare(.stop)],
                "a fresh Friends visit: `startJoin()`, the timeout, presence on, recipe off — in that order")
    }

    /// An unchanged verdict asks for nothing — the discipline that keeps `stopSearching()`'s
    /// once-per-ending hooks from firing on every tab bounce.
    @Test func anUnchangedVerdictIsSilent() {
        let same = Self.verdict(session: .peerCommitted)
        let again = Self.actions(from: same, to: same, Self.facts(searching: true, inSession: true, committed: true))
        #expect(again.isEmpty, "the same verdict twice runs no verb at all")
        let stillStopped = Self.actions(
            from: Self.verdict(duress: true, session: .peerCommitted),
            to: Self.verdict(duress: true, wipe: true, session: .peerCommitted),
            Self.facts()
        )
        #expect(stillStopped.isEmpty, "a hard stop that stays a hard stop tears nothing down twice")
    }

    /// Leaving the Friends tab with a committed peer keeps the link — `hold` — and only cancels the
    /// tab's timeout, exactly the `hasCommittedPeer` guard `stopFriendsDiscovery()` had.
    @Test func aTabExitKeepsACommittedLinkAndCancelsTheTimeout() {
        let moved = Self.actions(
            from: Self.verdict(session: .peerCommitted),
            to: Self.verdict(tab: .home, session: .peerCommitted),
            Self.facts(searching: true, inSession: true, committed: true)
        )
        #expect(moved == [.cancelDiscoveryTimeout, .recipeShare(.foregroundOnly)],
                "no `stopJoin()` over a committed link; Home turns the recipe listener on")
    }

    /// Leaving the Friends tab with a mesh that outlived its links stands the search down — nothing
    /// committed is dropped — and the mesh itself is never torn down by a tab.
    @Test func aTabExitStandsABlippedSearchDown() {
        let moved = Self.actions(
            from: Self.verdict(session: .meshHeld),
            to: Self.verdict(tab: .home, session: .meshHeld),
            Self.facts(searching: true, inSession: true)
        )
        #expect(moved == [.cancelDiscoveryTimeout, .stopJoin, .recipeShare(.foregroundOnly)],
                "the radios stand down, the held mesh stays, recipe comes on for Home")
        #expect(!moved.contains(.leaveSession), "a tab never tears a mesh down")
    }

    /// Entering the Friends tab over a live session arms nothing: the radios are already up, and
    /// `FriendsDiscoveryEntry.none` never arms the timeout.
    @Test func aTabEntryOverALiveSessionArmsNothing() {
        let entered = Self.actions(
            from: Self.verdict(tab: .home, session: .peerCommitted),
            to: Self.verdict(session: .peerCommitted),
            Self.facts(searching: true, inSession: true, committed: true)
        )
        #expect(entered == [.recipeShare(.stop)],
                "only the recipe listener moves — Friends never listens for recipes")
        #expect(!entered.contains(.armDiscoveryTimeout) && !entered.contains(.startJoin),
                "a live session's radios are not re-armed and its timeout is not re-armed")
    }

    /// Backgrounding a committed session holds the link for the OS to suspend and stops the
    /// listeners; nothing is torn down.
    @Test func aBackgroundExitHoldsTheLinkAndStopsTheListeners() {
        let backgrounded = Self.actions(
            from: Self.verdict(session: .peerCommitted),
            to: Self.verdict(phase: .background, session: .peerCommitted),
            Self.facts(searching: true, inSession: true, committed: true)
        )
        #expect(backgrounded == [.cancelDiscoveryTimeout, .presence(.stop)],
                "the timeout goes, presence stops, the link is held — no `stopJoin()`, no `leaveSession()`")
    }

    /// Returning to the foreground on the Friends tab after a blip resumes the partitioned mesh
    /// rather than founding a new one, and arms the timeout for the resumed search.
    @Test func aForegroundReturnAfterABlipResumesTheSearch() {
        let resumed = Self.actions(
            from: Self.verdict(phase: .background, session: .meshHeld),
            to: Self.verdict(session: .meshHeld),
            Self.facts(inSession: true)
        )
        #expect(resumed == [.resumeSearch, .armDiscoveryTimeout, .presence(.foregroundOnly)],
                "`resumeSearchingForPartitionedMesh()`, never `startJoin()` — that would nil the ceiling")
    }

    /// A hard stop over a live session tears it down through `leaveSession()`, the mesh's own
    /// teardown, and stops the listeners.
    @Test func aHardStopTearsALiveSessionDown() {
        let duress = Self.actions(
            from: Self.verdict(session: .peerCommitted),
            to: Self.verdict(duress: true, session: .peerCommitted),
            Self.facts(searching: true, inSession: true, committed: true)
        )
        #expect(duress == [.cancelDiscoveryTimeout, .leaveSession, .presence(.stop)],
                "duress: the session is torn down, not merely stood down")
        #expect(!duress.contains(.stopJoin), "and `leaveSession()` already funnels through the stand-down, so `stopJoin()` is not run on top")
    }

    /// A hard stop over a mere search stands the search down; over nothing it only cancels.
    @Test func aHardStopStandsASearchDownAndCancelsOverNothing() {
        let searching = Self.actions(
            from: Self.verdict(),
            to: Self.verdict(wipe: true),
            Self.facts(searching: true)
        )
        #expect(searching == [.cancelDiscoveryTimeout, .stopJoin, .presence(.stop)],
                "a delete-all during a search stands it down")
        let nothing = Self.actions(from: nil, to: Self.verdict(duress: true), Self.facts())
        #expect(nothing == [.cancelDiscoveryTimeout, .presence(.stop), .recipeShare(.stop)],
                "a hard stop with nothing up runs no mesh verb — the first application still counts every radio")
    }

    /// A cleared hard stop on the Friends tab starts a fresh search again.
    @Test func aClearedHardStopStartsAFreshSearch() {
        let cleared = Self.actions(from: Self.verdict(duress: true), to: Self.verdict(), Self.facts())
        #expect(cleared == [.startJoin, .armDiscoveryTimeout, .presence(.foregroundOnly)],
                "the real passcode clears duress: search, timeout, presence — recipe stays off on Friends")
    }

    /// The one transition this phase cannot execute is refused by name rather than executed:
    /// discovery `stop` while the mesh keeps `run` needs a seam that stops browsing and admitting
    /// while KEEPING the links, which P8 builds. `stopJoin()` would drop them.
    @Test func theOneTransitionThisPhaseCannotExecuteIsRefusedByName() {
        let continued = Self.actions(
            from: Self.verdict(continuation: .running, session: .peerCommitted),
            to: Self.verdict(phase: .background, continuation: .running, session: .peerCommitted),
            Self.facts(searching: true, inSession: true, committed: true)
        )
        #expect(continued == [.refuseBackgroundDiscoveryStop, .presence(.stop)],
                "no `stopJoin()`, no `leaveSession()` — the refusal is audible and the links are kept")
    }

    /// A discovery verdict of `run` never occurs (invariant 5); the transition answers it with no
    /// mesh verb rather than trapping.
    @Test func discoveryRunIsAnsweredNotTrapped() {
        let impossible = ProximityRunPolicy.Verdict(
            mesh: .foregroundOnly, discovery: .run, presence: .stop, recipeShare: .stop, routedAccessGate: .closed
        )
        let answered = Self.actions(from: nil, to: impossible, Self.facts())
        #expect(answered == [.presence(.stop), .recipeShare(.stop)], "no mesh verb for a value the policy never emits")
    }

    // MARK: The wall

    /// Every Swift file under `App/`, comment-stripped.
    private static func appSources() throws -> [(name: String, code: String)] {
        let root = RepoRoot.url("App")
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        var sources: [(name: String, code: String)] = []
        // R2: bounded by the app's own file list.
        for file in files.sorted(by: { $0.path < $1.path }) {
            sources.append((
                file.lastPathComponent,
                MeshRoutedSourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8))
            ))
        }
        return sources
    }

    /// The file names in which `needle` occurs, one entry per occurrence.
    private static func homes(of needle: String, in sources: [(name: String, code: String)]) -> [String] {
        var homes: [String] = []
        // R2: bounded by the file list.
        for source in sources {
            let count = source.code.components(separatedBy: needle).count - 1
            homes.append(contentsOf: Array(repeating: source.name, count: count))
        }
        return homes
    }

    /// **The retirement wall.** Every mesh radio verb under `App/` lives in the seams file exactly
    /// once — plus the DEBUG Lane C harness's own `startJoin()`, exempted by name — and the two
    /// listeners are started and stopped by no qualified call anywhere.
    @Test func everyRadioVerbLivesInTheSeamsFile() throws {
        let sources = try Self.appSources()
        #expect(sources.count >= 100, "the app-target scan lost its files")
        let seams = "ProximityRunSeams.swift"
        #expect(Self.homes(of: ".startJoin(", in: sources).sorted() == ["MeshRejectionMatrixHarness.swift", seams],
                "`startJoin()` is spoken by the seams once, and by the DEBUG Lane C harness once, by name")
        #expect(Self.homes(of: ".stopJoin(", in: sources) == [seams], "`stopJoin()` is spoken by the seams once")
        #expect(Self.homes(of: ".resumeSearchingForPartitionedMesh(", in: sources) == [seams],
                "the resume seam is spoken by the seams once")
        #expect(Self.homes(of: ".leaveSession()", in: sources) == [seams],
                "the silent teardown is spoken by the seams once — user endings go through `leaveSessionAfterNotifyingPeers()`")
        #expect(Self.homes(of: ".endSessionAfterDiscoveryTimeout(", in: sources) == [seams],
                "door 3's tab half fires from the seams' timeout once")
        let listenerVerbs = ["presenceManager.start(", "presenceManager.stop(",
                             "recipeShareManager.start(", "recipeShareManager.stop("]
        for verb in listenerVerbs {
            let found = Self.homes(of: verb, in: sources)
            #expect(found.isEmpty, "a listener is started or stopped by a qualified call outside its seam")
        }
        let applied = Self.homes(of: ".apply(", in: sources)
        #expect(applied.filter { $0 == seams }.count == 2, "each listener's `apply(_:)` seam is called exactly once, by the executor")
    }

    /// The retired chain is gone from the view, and the store's own edges run the policy.
    @Test func theViewSpeaksNoRadioVerbAndTheStoreRunsThePolicyOnItsOwnEdges() throws {
        let view = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ContentView.swift"))
        let retired = ["startFriendsDiscovery", "stopFriendsDiscovery", "armDiscoveryTimeout",
                       "discoveryTimeoutTask", "updatePresenceListener", "updateRecipeShareListener",
                       "shouldRunPresence", "shouldListenForRecipeShares"]
        for name in retired {
            #expect(!view.contains(name), "a retired radio member came back to ContentView")
        }
        let viewEdges = view.components(separatedBy: "applyProximityRunPolicyFromView()").count - 1
        #expect(viewEdges == 7, "the view hands the funnel six edges through one helper — tab, lock, opt-in, age, session liveness, launch — plus that helper's declaration")
        let store = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletStore.swift"))
        let storeEdges = store.components(separatedBy: "reapplyProximityRunPolicy(").count - 1
        #expect(storeEdges == 5, "the store's own edges — two opt-in setters, the wipe's raise and lower — plus the declaration")
        let wipe = try #require(
            MeshRoutedSourceScan.bracedBody(after: "func deleteAllData(includingHealthKitSamples", in: store),
            "the wipe funnel is gone"
        )
        #expect(wipe.contains("deleteAllInProgress = true") && wipe.contains("reapplyProximityRunPolicy()"),
                "the wipe raises the fact and re-runs the policy at leg 0, so every radio stands down there")
    }

    /// What this file does not claim: the executor's `switch` and the two listener seams are not
    /// driven here (a real `MeshNetworkManager`, `PresenceManager` or `ProximityRecipeShareManager`
    /// starts a real radio), so their correctness rests on the wall — one verb per case, all in one
    /// file — and on the funnel tests, which only ever apply verdicts that start nothing.
    @Test func whatThisTableDoesNotClaim() {
        let held = Self.actions(from: nil, to: Self.verdict(phase: .background, session: .peerCommitted), Self.facts(searching: true, inSession: true, committed: true))
        #expect(held == [.cancelDiscoveryTimeout, .presence(.stop), .recipeShare(.stop)],
                "a first application into a held session runs no mesh verb — the only kind of first application a test may execute for real")
    }
}
