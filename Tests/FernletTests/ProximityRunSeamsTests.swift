// ProximityRunSeamsTests.swift
// FernletTests
//
// Network migration P7 item 3: the seams' decision table and the retirement wall.
//
// `ProximityRunTransition.actions(from:to:mesh:)` is pure — last verdict, new verdict, the mesh
// manager's three live predicates → an ordered action list — so every "which radio verb, and
// when" claim the old `ContentView` chain made by construction is a row here: the fresh Friends
// visit, the tab exit that keeps a committed link, the tab exit that stands a blipped search down,
// the background exit, the return after a blip, the three hard stops, the cleared hard stop, the
// background-continuation row P7 could only refuse and P8 item 3 now HOLDS, and the foreground
// return out of that hold. The executor is a `switch` with nothing to decide, and the two listener
// seams are `switch`es too; neither is driven here, because a real manager starts a real radio —
// the honesty cell says so.
//
// Two walls beside the retirement one, both P8 item 3's: `.holdCommittedLinks(` has exactly one
// home, and `proximityRunPolicy.unsupportedTransition` has NONE — the app refuses no policy row
// any more. A third cell names the three spellings of the hold, so pass 1 cannot ship without
// pass 2: a verb nobody calls has no home for the retirement wall to count.
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

    /// The mesh manager's facts, named by what is up. A listener left unnamed AGREES with the
    /// verdict it is applied under — the steady state every cell below assumes unless it is the
    /// reconcile it is testing.
    private struct Facts {
        var searching = false
        var inSession = false
        var committed = false
        var presenceListening: Bool?
        var recipeListening: Bool?
    }

    /// The facts, named by what is up.
    private static func facts(
        searching: Bool = false, inSession: Bool = false, committed: Bool = false,
        presenceListening: Bool? = nil, recipeListening: Bool? = nil
    ) -> Facts {
        Facts(searching: searching, inSession: inSession, committed: committed,
              presenceListening: presenceListening, recipeListening: recipeListening)
    }

    /// The transition, shortened: an unnamed listener is resolved to the verdict's own state.
    private static func actions(
        from previous: ProximityRunPolicy.Verdict?,
        to next: ProximityRunPolicy.Verdict,
        _ mesh: Facts
    ) -> [ProximityRunAction] {
        ProximityRunTransition.actions(from: previous, to: next, mesh: ProximityRunTransition.MeshFacts(
            isSearching: mesh.searching, isInSession: mesh.inSession, hasCommittedPeer: mesh.committed,
            presenceListening: mesh.presenceListening ?? next.presence.isRunning,
            recipeShareListening: mesh.recipeListening ?? next.recipeShare.isRunning
        ))
    }

    // MARK: The table

    /// The first application counts every radio as an edge: a fresh Friends visit starts a fresh
    /// search, arms the tab's timeout, starts presence and leaves recipe stopped.
    @Test func theFirstApplicationTreatsEveryRadioAsAnEdge() {
        let fresh = Self.actions(from: nil, to: Self.verdict(), Self.facts())
        #expect(fresh == [.startJoin, .armDiscoveryTimeout, .presence(.foregroundOnly), .recipeShare(.stop)],
                "a fresh Friends visit: `startJoin()`, the timeout, presence on, recipe off — in that order")
    }

    /// An unchanged verdict asks for nothing while the radios agree with it — the discipline that
    /// keeps `stopSearching()`'s once-per-ending hooks from firing on every tab bounce. The mesh
    /// radio is edge-triggered without exception; the two listeners are silent only while they
    /// match (the next two cells are the exception).
    @Test func anUnchangedVerdictIsSilent() {
        let same = Self.verdict(session: .peerCommitted)
        let again = Self.actions(from: same, to: same, Self.facts(searching: true, inSession: true, committed: true))
        #expect(again.isEmpty, "the same verdict twice, radios matching, runs no verb at all")
        let stillStopped = Self.actions(
            from: Self.verdict(duress: true, session: .peerCommitted),
            to: Self.verdict(duress: true, wipe: true, session: .peerCommitted),
            Self.facts()
        )
        #expect(stillStopped.isEmpty, "a hard stop that stays a hard stop tears nothing down twice")
    }

    /// P8 item 0, device finding (b): a listener that stood itself down — the recipe manager's
    /// self-stop on a `didNotStart*`, which the Local Network prompt guarantees on a fresh
    /// install's very first start — is re-started on the next policy run even though the verdict
    /// never moved. The prompt's inactive → active round trip is not a verdict change (`.inactive`
    /// is foreground by design), so an edge-only seam left the listener dark until the share
    /// sheet's own `start()` — the owner's observed workaround.
    @Test func aStoppedListenerUnderAnUnchangedRunningVerdictIsRestarted() {
        let home = Self.verdict(tab: .home)
        let recipeDark = Self.actions(from: home, to: home, Self.facts(recipeListening: false))
        #expect(recipeDark == [.recipeShare(.foregroundOnly)],
                "the recipe listener the verdict wants up, and which is down, is started — nothing else runs")
        let presenceDark = Self.actions(from: home, to: home, Self.facts(presenceListening: false))
        #expect(presenceDark == [.presence(.foregroundOnly)],
                "and the presence radio on the same terms")
        let bothDark = Self.actions(from: home, to: home, Self.facts(presenceListening: false, recipeListening: false))
        #expect(bothDark == [.presence(.foregroundOnly), .recipeShare(.foregroundOnly)],
                "both, in the executor's order, and still no mesh verb")
    }

    /// The reconcile runs the other way too: a listener still up under a verdict that says `stop`
    /// is stopped, and a listener the verdict would `hold` is never touched — `hold` keeps what it
    /// has, up or down.
    @Test func aRunningListenerUnderAnUnchangedStopVerdictIsStopped() {
        let friends = Self.verdict()
        let recipeUp = Self.actions(from: friends, to: friends, Self.facts(searching: true, recipeListening: true))
        #expect(recipeUp == [.recipeShare(.stop)],
                "the Friends tab wants the recipe listener down; one that is up is stopped")
        let background = Self.verdict(phase: .background, session: .peerCommitted)
        let presenceUp = Self.actions(
            from: background, to: background,
            Self.facts(searching: true, inSession: true, committed: true, presenceListening: true)
        )
        #expect(presenceUp == [.presence(.stop)],
                "presence is stopped in the background, not held: the mesh is what `hold` is for")
        #expect(!ProximityRunTransition.listenerNeedsReconciling(.hold, listening: true)
                && !ProximityRunTransition.listenerNeedsReconciling(.hold, listening: false),
                "`hold` reconciles nothing, whichever way the radio is")
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

    /// The row P7 could only refuse is executed now: discovery `stop` while the mesh keeps `run`
    /// runs `holdCommittedLinks()`, which stops browsing and admission and keeps every committed
    /// link. `stopJoin()` would drop them, and is still not emitted here.
    @Test func theBackgroundContinuationRowHoldsTheLinksInsteadOfRefusing() {
        let continued = Self.actions(
            from: Self.verdict(continuation: .running, session: .peerCommitted),
            to: Self.verdict(phase: .background, continuation: .running, session: .peerCommitted),
            Self.facts(searching: true, inSession: true, committed: true)
        )
        #expect(continued == [.holdLinks, .presence(.stop)],
                "the hold, not `stopJoin()` and not `leaveSession()` — and no timeout to cancel")
    }

    /// **The way back out**, which the three-way alone does not have (P8 item 3).
    ///
    /// After the hold the radios are down with a peer still committed, and
    /// `FriendsDiscoveryEntry.entry(true, true)` is `.none` — right for a Friends visit over a live
    /// session, and a ONE-WAY DOOR here: the session would never browse, admit or re-dial again.
    /// The explicit row emits `.resumeSearch` and arms NO timeout, because a committed peer is not
    /// "found nobody".
    @Test func aForegroundReturnFromTheBackgroundHoldResumesTheSearch() {
        let held = Self.verdict(phase: .background, continuation: .running, session: .peerCommitted)
        let returned = Self.actions(
            from: held,
            to: Self.verdict(continuation: .running, session: .peerCommitted),
            Self.facts(inSession: true, committed: true)
        )
        #expect(returned == [.resumeSearch, .presence(.foregroundOnly)],
                "the radios come back, and no `armDiscoveryTimeout` rides along")
        #expect(!FriendsDiscoveryEntry.entry(isInSession: true, hasCommittedPeer: true).armsDiscoveryTimeout,
                "the three-way it overrides answers `.none` here — read through the property, never `== .none`")
        let stillUp = Self.actions(
            from: held,
            to: Self.verdict(continuation: .running, session: .peerCommitted),
            Self.facts(searching: true, inSession: true, committed: true)
        )
        #expect(stillUp == [.presence(.foregroundOnly)], """
            and the row is gated on the radios actually being DOWN: a session still searching asks \
            for nothing, exactly as the tab's own `!isSearching` arm always did
            """)
        let heldWithNoPeer = Self.actions(
            from: Self.verdict(phase: .background, continuation: .running, session: .meshHeld),
            to: Self.verdict(continuation: .running, session: .meshHeld),
            Self.facts(inSession: true)
        )
        #expect(heldWithNoPeer == [.resumeSearch, .armDiscoveryTimeout, .presence(.foregroundOnly)],
                "a hold with no committed peer falls through to the three-way, which arms the clock")
    }

    /// The way out is not required to be DIRECT, which is why the row reads the facts and not the
    /// verdict it is leaving.
    ///
    /// Foreground on any tab but Friends is discovery `hold` — "keep what you have" — which after a
    /// background hold means "keep the radios down", and leaves the hold row two verdicts behind by
    /// the time the user opens Friends. A row keyed on `previous` would see `(run, hold)` there and
    /// answer nothing, and the session would be just as stranded as before item 3.
    @Test func theWayOutOfAHoldSurvivesAStopOnAnotherTab() {
        let held = Self.verdict(phase: .background, continuation: .running, session: .peerCommitted)
        let downstairs = Self.verdict(tab: .home, continuation: .running, session: .peerCommitted)
        let ontoHome = Self.actions(from: held, to: downstairs, Self.facts(inSession: true, committed: true))
        #expect(ontoHome == [.cancelDiscoveryTimeout, .presence(.foregroundOnly), .recipeShare(.foregroundOnly)],
                "discovery `hold` touches no radio — the mesh is still held, and still dark")
        let ontoFriends = Self.actions(
            from: downstairs,
            to: Self.verdict(continuation: .running, session: .peerCommitted),
            Self.facts(inSession: true, committed: true)
        )
        #expect(ontoFriends == [.resumeSearch, .recipeShare(.stop)],
                "and the next Friends visit still gets its radios back")
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
    ///
    /// **P8 item 5's raise pair is deliberately NOT on this needle list.**
    /// `MeshNetworkManager.beginBackgroundContinuation()` / `endBackgroundContinuation()` touch no
    /// radio whatever — each offers one event to the session state machine — so listing them here
    /// would say the continuation driver is a radio speaker, which is the one claim P8 must not
    /// make. They are counted by `MeshContinuationRaiseWallTests` instead.
    @Test func everyRadioVerbLivesInTheSeamsFile() throws {
        let sources = try Self.appSources()
        #expect(sources.count >= 100, "the app-target scan lost its files")
        let seams = "ProximityRunSeams.swift"
        #expect(Self.homes(of: ".startJoin(", in: sources).sorted() == ["MeshRejectionMatrixHarness.swift", seams],
                "`startJoin()` is spoken by the seams once, and by the DEBUG Lane C harness once, by name")
        #expect(Self.homes(of: ".stopJoin(", in: sources) == [seams], "`stopJoin()` is spoken by the seams once")
        #expect(Self.homes(of: ".resumeSearchingForPartitionedMesh(", in: sources) == [seams],
                "the resume seam is spoken by the seams once")
        #expect(Self.homes(of: ".holdCommittedLinks(", in: sources) == [seams],
                "P8 item 3's hold is spoken by the seams once — and by no continuation coordinator")
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

    /// **The zero-count wall.** P7's refusal is gone from the app — the action case, the executor
    /// arm and the audit token with it.
    ///
    /// The token is the wall's subject rather than the case name because it is what a device
    /// transcript is read for (`Docs/Mesh-P7-Physical-Device-Test-Plan-2026-09-18.md`: one sighting
    /// is a bug), and because a dead refusal arm left standing beside the verb that replaced it is
    /// exactly the shape this must forbid. Scanned over `App/` only, so this file's own literal can
    /// never be the thing it counts.
    @Test func theRefusedRowsTokenIsGoneFromTheApp() throws {
        let sources = try Self.appSources()
        #expect(sources.count >= 100, "the app-target scan lost its files")
        #expect(Self.homes(of: "proximityRunPolicy.unsupportedTransition", in: sources).isEmpty,
                "no shipping file refuses a policy row any more — item 3 executes the only one there was")
        #expect(Self.homes(of: "refuseBackgroundDiscoveryStop", in: sources).isEmpty,
                "and the action case it rode on is gone with it")
    }

    /// **The gate's proof that pass 2 ran.** Pass 1 could ship the verb and leave the seam refusing,
    /// and every other wall here would survive it — `everyRadioVerbLivesInTheSeamsFile` counts the
    /// verb's *home*, and a verb nobody calls has no home to count, so `[]` would be its answer and
    /// `== [seams]` its only complaint. This says the two halves out loud instead: the transition
    /// EMITS the action for the mesh-`run` row, and the executor RUNS the verb.
    ///
    /// Deliberately **not** a check that `case holdLinks` is declared. A source scan cannot police a
    /// rename: the needle is a literal in this file, so renaming the case here and there in one
    /// sweep satisfies the cell by accident (observed, when this cell's own red-once was planted as
    /// a rename). What a rename cannot survive is the row cells above, which name the actions by
    /// case and stop compiling — that is where a rename is caught, and this is where a missing
    /// pass 2 is.
    @Test func theSeamsFileDeclaresEmitsAndExecutesTheHold() throws {
        let seams = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ProximityRunSeams.swift"))
        #expect(seams.contains("return [.holdLinks]"), "the transition emits it for the mesh-`run` row")
        #expect(seams.contains("meshNetworkManager.holdCommittedLinks()"), "and the executor runs the verb")
        #expect(seams.contains("case .resumeSearch:"), "the inverse still has its arm")
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
        #expect(storeEdges == 6, "the store's own edges — two opt-in setters, P8 item 6's continuation feed, the wipe's raise and lower — plus the declaration")
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
