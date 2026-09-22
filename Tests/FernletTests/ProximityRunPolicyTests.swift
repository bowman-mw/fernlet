// ProximityRunPolicyTests.swift
// FernletTests
//
// Network migration P7 item 1: `ProximityRunPolicy`'s matrix over the FULL input product — the
// phase's central test, and one that needs no simulator, no scene and no manager.
//
// The table is the artefact. `ProximityRunPolicyProduct.rows()` enumerates every row of the input
// product (3 phases × 5 tabs × 4 continuation states × 3 session presences × 2⁶ Bool facts =
// 11 520) from the enums' own `allCases`, so a new input widens the pinned count deliberately and
// a dropped dimension collapses the set visibly. Over that product the suite states each claim
// the policy makes — the gate reads only its three facts, `.inactive` is a foreground scene, nothing
// but a continued mesh claims the background, discovery never runs there (invariant 5), a hard stop
// stops every radio, nothing outside the opt-in, the scene, the tab and the three hard stops parks a
// listener, the three non-running continuation states are one row — and pins plan §13's load-bearing
// rows by hand. A flat re-statement of every
// radio's rule (`expectedMesh` and friends) is compared on all 23 040 rows as the named expectation
// per row; being a re-statement, its value is catching a guard-order slip, not proving the
// semantics — the clauses do that.
//
// Item 2 added two projections, of which `belowMinimumAge(_:)` survives — P9-3-A's fix
// (2026-09-22) retired `appLockEngaged(_:)` with the input fact it projected, dropping the product
// from 23 040 rows to 11 520 — and the second
// suite in this file, `ProximityRunPolicyFunnelTests`: the store's funnel driven without a scene,
// asserting the manager holds exactly the gate the policy decided. `-only-testing:` names a SUITE,
// so this file answers to two names.
//
// House rules: `#expect(_, "one literal")` only, every `allSatisfy` bound to a `let` first, no
// `@Test(arguments: [])`, no rig, no clock, no RNG.

import Foundation
import SwiftUI
import Testing
import FernletDomainModel
import FernletLock
import LocalPersistence
import ProximityKit
@testable import Fernlet

// MARK: - ProximityRunPolicyProduct

/// The whole input product, enumerated dimension by dimension so no row can be skipped by a typo,
/// plus the hand-written rows and the flat re-statements the cells compare against.
enum ProximityRunPolicyProduct {

    /// The three phases SwiftUI declares today. `ScenePhase` is neither `CaseIterable` nor frozen,
    /// so this is a literal list; a fourth phase widens ``count`` deliberately.
    static let scenePhases: [ScenePhase] = [.active, .inactive, .background]

    /// The size of the product: 3 phases × 5 tabs × 4 continuation states × 3 presences × 2⁶.
    static let count = 3 * 5 * 4 * 3 * 64

    /// Every row of the product.
    static func rows() -> [ProximityRunPolicy.Input] {
        var rows: [ProximityRunPolicy.Input] = []
        rows.reserveCapacity(count)
        for phase in scenePhases {
            for tab in FernletTab.allCases {
                for continuation in ProximityContinuationState.allCases {
                    for session in ProximitySessionPresence.allCases {
                        rows.append(contentsOf: flagRows(
                            phase: phase, tab: tab, continuation: continuation, session: session
                        ))
                    }
                }
            }
        }
        return rows
    }

    /// The six Bool inputs as one 6-bit counter, so none can be left out. It was SEVEN until
    /// P9-3-A's fix retired `appLockEngaged`.
    private static func flagRows(
        phase: ScenePhase,
        tab: FernletTab,
        continuation: ProximityContinuationState,
        session: ProximitySessionPresence
    ) -> [ProximityRunPolicy.Input] {
        (0..<64).map { bits in
            ProximityRunPolicy.Input(
                scenePhase: phase,
                selectedTab: tab,
                duressSessionActive: (bits & 1) != 0,
                protectedDataAvailable: (bits & 2) != 0,
                belowMinimumAge: (bits & 4) != 0,
                deleteAllInProgress: (bits & 8) != 0,
                continuation: continuation,
                session: session,
                allowNearbyPresence: (bits & 16) != 0,
                allowNearbyRecipeShares: (bits & 32) != 0
            )
        }
    }

    /// One row with named defaults — a fresh, opted-in Friends visit — for the hand-written cells.
    static func row(
        phase: ScenePhase = .active,
        tab: FernletTab = .social,
        duress: Bool = false,
        protected: Bool = true,
        belowAge: Bool = false,
        wipe: Bool = false,
        continuation: ProximityContinuationState = .notRequested,
        session: ProximitySessionPresence = .absent,
        presence: Bool = true,
        recipe: Bool = true
    ) -> ProximityRunPolicy.Input {
        ProximityRunPolicy.Input(
            scenePhase: phase,
            selectedTab: tab,
            duressSessionActive: duress,
            protectedDataAvailable: protected,
            belowMinimumAge: belowAge,
            deleteAllInProgress: wipe,
            continuation: continuation,
            session: session,
            allowNearbyPresence: presence,
            allowNearbyRecipeShares: recipe
        )
    }

    /// A copy of one row with the named facts replaced and every other fact kept.
    static func copy(
        _ r: ProximityRunPolicy.Input,
        phase: ScenePhase? = nil,
        belowAge: Bool? = nil,
        wipe: Bool? = nil,
        continuation: ProximityContinuationState? = nil
    ) -> ProximityRunPolicy.Input {
        ProximityRunPolicy.Input(
            scenePhase: phase ?? r.scenePhase,
            selectedTab: r.selectedTab,
            duressSessionActive: r.duressSessionActive,
            protectedDataAvailable: r.protectedDataAvailable,
            belowMinimumAge: belowAge ?? r.belowMinimumAge,
            deleteAllInProgress: wipe ?? r.deleteAllInProgress,
            continuation: continuation ?? r.continuation,
            session: r.session,
            allowNearbyPresence: r.allowNearbyPresence,
            allowNearbyRecipeShares: r.allowNearbyRecipeShares
        )
    }

    /// The policy's verdict for one row — a shorthand.
    static func verdict(_ r: ProximityRunPolicy.Input) -> ProximityRunPolicy.Verdict {
        ProximityRunPolicy.verdict(for: r)
    }

    // MARK: The flat re-statements

    /// The raw foreground fact, spelled as a phase compare ON PURPOSE: this is the independent
    /// statement the policy's `routedGateForeground(for:)` call is checked against.
    static func foreground(_ r: ProximityRunPolicy.Input) -> Bool {
        r.scenePhase != .background
    }

    /// The three hard stops, flat.
    static func hardStop(_ r: ProximityRunPolicy.Input) -> Bool {
        r.deleteAllInProgress || r.duressSessionActive || r.belowMinimumAge
    }

    /// The mesh rule as an `if` chain.
    static func expectedMesh(_ r: ProximityRunPolicy.Input) -> ProximityRunState {
        if hardStop(r) { return .stop }
        let somethingToContinue = r.session == .meshHeld || r.session == .peerCommitted
        if r.continuation == .running && somethingToContinue { return .run }
        return foreground(r) ? .foregroundOnly : .hold
    }

    /// The discovery rule as an `if` chain.
    static func expectedDiscovery(_ r: ProximityRunPolicy.Input) -> ProximityRunState {
        if hardStop(r) { return .stop }
        let keep: ProximityRunState = r.session == .peerCommitted ? .hold : .stop
        if foreground(r) { return r.selectedTab == .social ? .foregroundOnly : keep }
        if r.continuation == .running { return .stop }
        return keep
    }

    /// The presence rule, flat, with `.inactive` counted as foreground. The `!appLockEngaged` leg
    /// it carried over from `ContentView.shouldRunPresence` is gone (P9-3-A).
    static func expectedPresence(_ r: ProximityRunPolicy.Input) -> ProximityRunState {
        let mainTab = r.selectedTab == .home || r.selectedTab == .food
            || r.selectedTab == .move || r.selectedTab == .social
        let runs = r.allowNearbyPresence && foreground(r) && mainTab && !hardStop(r)
        return runs ? .foregroundOnly : .stop
    }

    /// The recipe-listener rule, flat, with `.inactive` counted as foreground — its app-lock leg
    /// retired with presence's (P9-3-A).
    static func expectedRecipeShare(_ r: ProximityRunPolicy.Input) -> ProximityRunState {
        let listeningTab = r.selectedTab == .home || r.selectedTab == .food || r.selectedTab == .move
        let runs = r.allowNearbyRecipeShares && foreground(r) && listeningTab && !hardStop(r)
        return runs ? .foregroundOnly : .stop
    }
}

// MARK: - ProximityRunPolicyTests

/// The matrix, whole.
@Suite struct ProximityRunPolicyTests {

    /// The product and its helpers, shortened.
    private typealias Product = ProximityRunPolicyProduct

    // MARK: The product

    /// The product is the size it says, and no dimension collapsed into another.
    @Test func theInputProductIsWholeAndDistinct() {
        let rows = Product.rows()
        #expect(Product.scenePhases.count == 3,
                "the three phases SwiftUI declares today; a fourth widens the product on purpose")
        #expect(Product.count == 11_520, "3 × 5 × 4 × 3 × 64 — a new input must move this deliberately")
        #expect(rows.count == 11_520, "every row was built")
        #expect(Set(rows).count == 11_520, "and no two rows are the same input — no dimension collapsed")
        #expect(FernletTab.allCases.count == 5, "the five tabs")
        #expect(ProximityContinuationState.allCases.count == 4, "not requested, running, refused, expired")
        #expect(ProximitySessionPresence.allCases.count == 3, "absent, mesh held, peer committed")
    }

    // MARK: §13's load-bearing rows, by hand

    /// §13: user-started mesh + CPT granted → mesh `run` in the background, discovery foreground-only
    /// (invariant 5), presence and recipe `stop` on background.
    @Test func aContinuedMeshRunsInTheBackgroundAndAdmitsNobody() {
        let background = Product.verdict(Product.row(
            phase: .background, continuation: .running, session: .peerCommitted
        ))
        #expect(background.mesh == .run, "a running task lets the mesh keep its links in the background")
        #expect(background.discovery == .stop, "and a live background process never browses or admits")
        #expect(background.presence == .stop, "presence stops on background, as today")
        #expect(background.recipeShare == .stop, "recipe stops on background, as today")
        #expect(!background.routedAccessGate.appIsForeground,
                "while the gate's foreground leg fell with the scene — a continued mesh decrypts nothing")

        let foreground = Product.verdict(Product.row(continuation: .running, session: .peerCommitted))
        #expect(foreground.mesh == .run, "the task still exists in the foreground, so the claim stands")
        #expect(foreground.discovery == .foregroundOnly, "the Friends tab wants discovery")
        #expect(foreground.presence == .foregroundOnly, "presence runs on the Friends tab")
        #expect(foreground.recipeShare == .stop, "recipe never listens on the Friends tab")

        let held = Product.verdict(Product.row(
            phase: .background, continuation: .running, session: .meshHeld
        ))
        #expect(held.mesh == .run,
                "a held mesh with no links is still something to continue — reconnecting members is what invariant 5 allows")
        let nothing = Product.verdict(Product.row(
            phase: .background, continuation: .running, session: .absent
        ))
        #expect(nothing.mesh == .hold, "a task with nothing to continue grants nothing")
    }

    /// §13: CPT refused → mesh `foregroundOnly`; and an expired task is the same row.
    @Test func aRefusedOrExpiredTaskLeavesTheMeshForegroundOnly() {
        let refused = Product.verdict(Product.row(continuation: .refused, session: .peerCommitted))
        #expect(refused.mesh == .foregroundOnly, "no background claim, so the mesh is a foreground radio")
        let refusedBackground = Product.verdict(Product.row(
            phase: .background, continuation: .refused, session: .peerCommitted
        ))
        #expect(refusedBackground.mesh == .hold, "and in the background it is held for the OS to suspend")
        #expect(refusedBackground.discovery == .hold, "with its committed link kept, not stood down")
        let expired = Product.verdict(Product.row(
            phase: .background, continuation: .expired, session: .peerCommitted
        ))
        #expect(expired == refusedBackground, "an expired task is the same row as a refused one")
    }

    /// §13: delete-all / below-age / duress → `stop` + teardown — every radio, and the gate touched
    /// only through its own duress leg.
    @Test func theThreeHardStopsStopEveryRadio() {
        let wipe = Product.verdict(Product.row(wipe: true, session: .peerCommitted))
        #expect(wipe.mesh == .stop && wipe.discovery == .stop, "a delete-all tears the session down")
        #expect(wipe.presence == .stop && wipe.recipeShare == .stop, "and stops both listeners")
        #expect(wipe.routedAccessGate.isOpen,
                "while the gate reads no wipe fact — the wipe's own guard is the manager's, not the gate's")

        let age = Product.verdict(Product.row(belowAge: true, session: .peerCommitted))
        #expect(age.mesh == .stop && age.discovery == .stop, "a below-minimum-age ruling tears the session down")
        #expect(age.presence == .stop && age.recipeShare == .stop, "and stops both listeners")
        #expect(age.routedAccessGate.isOpen, "and the gate reads no age fact either")

        let duress = Product.verdict(Product.row(duress: true, session: .peerCommitted))
        #expect(duress.mesh == .stop && duress.discovery == .stop, "a duress session tears the session down")
        #expect(duress.presence == .stop && duress.recipeShare == .stop, "and stops both listeners")
        #expect(duress.routedAccessGate.duressActive, "and closes the gate through its own leg")
        #expect(!duress.routedAccessGate.isOpen, "so nothing is decrypted under duress")
    }

    /// Today's sessions, one row each: the fresh visit, a blip off-tab, a committed session off-tab.
    @Test func todaysForegroundSessionsAsRows() {
        let fresh = Product.verdict(Product.row())
        #expect(fresh.discovery == .foregroundOnly, "a fresh Friends visit searches")
        #expect(fresh.mesh == .foregroundOnly, "and a session may form")
        #expect(fresh.presence == .foregroundOnly, "presence runs on the Friends tab")
        #expect(fresh.recipeShare == .stop, "recipe does not")

        let blipOffTab = Product.verdict(Product.row(tab: .home, session: .meshHeld))
        #expect(blipOffTab.discovery == .stop,
                "a mesh that outlived its links stands its radios down off-tab — nothing is dropped")
        #expect(blipOffTab.mesh == .foregroundOnly, "and the held mesh is never torn down by a tab")

        let committedOffTab = Product.verdict(Product.row(tab: .home, session: .peerCommitted))
        #expect(committedOffTab.discovery == .hold,
                "a committed peer's links are kept off-tab, exactly the `hasCommittedPeer` guard today")
        #expect(committedOffTab.mesh == .foregroundOnly, "the session continues")
        #expect(committedOffTab.presence == .foregroundOnly && committedOffTab.recipeShare == .foregroundOnly,
                "and Home runs both listeners")

        let privateTab = Product.verdict(Product.row(tab: .personal, session: .peerCommitted))
        #expect(privateTab.presence == .stop && privateTab.recipeShare == .stop,
                "the Private tab runs no listener")
        #expect(privateTab.discovery == .hold, "but keeps a committed link")
    }

    /// Today's backgrounded session, and the row P9-3-A used to park, one each.
    @Test func todaysBackgroundedSessionAndTheRowTheLockUsedToParkAsRows() {
        let suspended = Product.verdict(Product.row(phase: .background, session: .peerCommitted))
        #expect(suspended.mesh == .hold, "no task, so the session is kept for the OS to suspend")
        #expect(suspended.discovery == .hold, "with its link kept — today's guard, as a value")
        #expect(suspended.presence == .stop && suspended.recipeShare == .stop, "and both listeners stop")
        #expect(!suspended.anyRadioRuns, "nothing is up in a suspended session")

        let searchingBackgrounded = Product.verdict(Product.row(phase: .background))
        #expect(searchingBackgrounded.discovery == .stop, "a search with nobody stands down on background")
        #expect(searchingBackgrounded.mesh == .hold, "and there is nothing to tear down")

        // P9-3-A's row, from the other side. With a configured Fernlet Lock at rest this exact
        // visit read `policy=stop` on both listeners forever, while the mesh and the gate — which
        // never had the leg — carried on, so nothing in the app could show the person a reason.
        let homeWithAPeer = Product.verdict(Product.row(tab: .home, session: .peerCommitted))
        #expect(homeWithAPeer.presence == .foregroundOnly && homeWithAPeer.recipeShare == .foregroundOnly,
                "a Home visit with a committed peer runs both listeners, lock or no lock")
        #expect(homeWithAPeer.discovery == .hold && homeWithAPeer.mesh == .foregroundOnly,
                "while the mesh row, which never carried the lock leg, is unmoved (D-10.3)")
        #expect(homeWithAPeer.routedAccessGate.isOpen, "and the gate is open — only the OS lock closes that")
    }

    // MARK: Clauses over the whole product

    /// The gate is the same three facts the app assembles today, and nothing else.
    @Test func theGateReadsOnlyItsThreeFacts() {
        let rows = Product.rows()
        let agrees = rows.allSatisfy { r in
            Product.verdict(r).routedAccessGate == MeshRoutedAccessGate(
                protectedDataAvailable: r.protectedDataAvailable,
                appIsForeground: FernletApp.routedGateForeground(for: r.scenePhase),
                duressActive: r.duressSessionActive
            )
        }
        #expect(agrees, "on every row the gate is protected data, the one foreground mapping, and duress")
        let blindToStops = rows.allSatisfy { r in
            let flipped = Product.copy(r, belowAge: !r.belowMinimumAge, wipe: !r.deleteAllInProgress)
            return Product.verdict(r).routedAccessGate == Product.verdict(flipped).routedAccessGate
        }
        #expect(blindToStops, "and flipping the wipe and age facts moves no gate leg — radios only, never plaintext")
        let blindToTheTask = rows.allSatisfy { r in
            let flipped = Product.copy(r, continuation: .running)
            return Product.verdict(r).routedAccessGate == Product.verdict(flipped).routedAccessGate
        }
        #expect(blindToTheTask, "nor does a continuation task — and Fernlet's app lock cannot, having no fact left")
    }

    /// `.inactive` is a foreground scene: every inactive row equals its active twin.
    @Test func anInactiveSceneIsAForegroundScene() {
        let rows = Product.rows()
        let inactive = rows.filter { $0.scenePhase == .inactive }
        #expect(inactive.count == 3_840, "one third of the product")
        let sameAsActive = inactive.allSatisfy { Product.verdict($0) == Product.verdict(Product.copy($0, phase: .active)) }
        #expect(sameAsActive,
                "Control Center, a call banner, the Face ID sheet and Split View change no radio and no gate leg")
        let backgroundDiffers = rows.filter { $0.scenePhase == .active }.contains {
            Product.verdict($0) != Product.verdict(Product.copy($0, phase: .background))
        }
        #expect(backgroundDiffers, "while a background scene IS a different row — the claim is not vacuous")
    }

    /// Only a mesh continued by a running task ever claims the background — and it always does.
    @Test func nothingButAContinuedMeshClaimsTheBackground() {
        let rows = Product.rows()
        let continued = rows.filter { r in
            r.continuation == .running && r.session != .absent && !ProximityRunPolicy.isHardStop(r)
        }
        #expect(continued.count == 240, "3 phases × 5 tabs × 2 presences × the 8 hard-stop-free flag rows")
        let everyContinuedRuns = continued.allSatisfy { Product.verdict($0).mesh == .run }
        #expect(everyContinuedRuns, "a running task with something to continue always grants the background")
        let onlyContinuedRuns = rows.filter { Product.verdict($0).mesh == .run }.count == continued.count
        #expect(onlyContinuedRuns, "and nothing else does")
        let otherRadiosNeverRun = rows.allSatisfy { r in
            let v = Product.verdict(r)
            return v.discovery != .run && v.presence != .run && v.recipeShare != .run
        }
        #expect(otherRadiosNeverRun, "`run` is the mesh's alone")
        let background = rows.filter { $0.scenePhase == .background }
        let noForegroundOnlyInBackground = background.allSatisfy { r in
            let v = Product.verdict(r)
            return v.mesh != .foregroundOnly && v.discovery != .foregroundOnly
                && v.presence != .foregroundOnly && v.recipeShare != .foregroundOnly
        }
        #expect(noForegroundOnlyInBackground, "`foregroundOnly` is a foreground verdict, never a mode")
        let listenersStopInBackground = background.allSatisfy { r in
            let v = Product.verdict(r)
            return v.presence == .stop && v.recipeShare == .stop
        }
        #expect(listenersStopInBackground, "presence and recipe stop on every background row")
    }

    /// Invariant 5: admission is foreground-only. Discovery never runs in the background, and a
    /// live background process stops it outright.
    @Test func discoveryNeverRunsInTheBackground() {
        let background = Product.rows().filter { $0.scenePhase == .background }
        let heldOrStopped = background.allSatisfy { r in
            let d = Product.verdict(r).discovery
            return d == .hold || d == .stop
        }
        #expect(heldOrStopped, "in the background discovery is held or stopped, never up")
        let stoppedUnderATask = background.filter { $0.continuation == .running }
            .allSatisfy { Product.verdict($0).discovery == .stop }
        #expect(stoppedUnderATask, "and a live background process must not browse or admit — P8's seam")
        let heldForALink = background.filter { r in
            r.session == .peerCommitted && r.continuation != .running && !ProximityRunPolicy.isHardStop(r)
        }.allSatisfy { Product.verdict($0).discovery == .hold }
        #expect(heldForALink, "while without a task a committed link is kept for the OS to suspend")
        let stoodDownWithNobody = background.filter { $0.session != .peerCommitted }
            .allSatisfy { Product.verdict($0).discovery == .stop }
        #expect(stoodDownWithNobody, "and a search with nobody stands down")
    }

    /// A hard stop stops every radio; and the mesh's `stop` is a teardown that only a hard stop asks
    /// for.
    @Test func aHardStopStopsEveryRadioAndOnlyAHardStopTearsTheMeshDown() {
        let rows = Product.rows()
        let hard = rows.filter { ProximityRunPolicy.isHardStop($0) }
        #expect(hard.count == 10_080, "seven of every eight rows carry at least one of the three")
        let allStopped = hard.allSatisfy { r in
            let v = Product.verdict(r)
            return v.mesh == .stop && v.discovery == .stop && v.presence == .stop && v.recipeShare == .stop
        }
        #expect(allStopped, "every radio, whatever the scene, tab, lock, task or session says")
        let meshStopsOnlyForAHardStop = rows.filter { !ProximityRunPolicy.isHardStop($0) }
            .allSatisfy { Product.verdict($0).mesh != .stop }
        #expect(meshStopsOnlyForAHardStop,
                "a tab bounce or a scene exit never tears the session down — that is `hold`'s whole job")
    }

    /// P9-3-A (2026-09-22): Fernlet's own app lock reaches NO radio, so the cell that used to say
    /// "the lock moves presence and recipe only" is replaced by its inverse, stated positively —
    /// on every opted-in, foreground, hard-stop-free row of a listening tab the listener RUNS.
    ///
    /// The finding this answers: `FernletLockState.locked` is the RESTING state of a configured
    /// lock, so the retired leg parked both 1:1 radios permanently for anyone who had one — while
    /// the mesh row, carrying the same person's session, never had the leg at all, and no surface
    /// said why the two radios had gone quiet. A scoped lock protects the Private tab, the progress
    /// photos and the lock settings; it is not a radio switch.
    @Test func noLockLegSurvivesAndAListenerRunsWheneverItsOwnRuleAllows() {
        let rows = Product.rows()
        #expect(Product.count == 11_520, "the product lost its lock dimension: 2⁶ flag rows, not 2⁷")
        let presenceRows = rows.filter { r in
            r.allowNearbyPresence && Product.foreground(r) && !Product.hardStop(r) && r.selectedTab != .personal
        }
        #expect(presenceRows.count == 384,
                "2 foreground phases × 4 presence tabs × 4 tasks × 3 presences × the 4 opted-in, hard-stop-free flag rows")
        let everyPresenceRowRuns = presenceRows.allSatisfy { Product.verdict($0).presence == .foregroundOnly }
        #expect(everyPresenceRowRuns,
                "presence runs on every one of them — a configured lock at rest can no longer park it")
        let recipeRows = rows.filter { r in
            r.allowNearbyRecipeShares && Product.foreground(r) && !Product.hardStop(r)
                && (r.selectedTab == .home || r.selectedTab == .food || r.selectedTab == .move)
        }
        #expect(recipeRows.count == 288, "and three listening tabs' worth for the recipe listener")
        let everyRecipeRowRuns = recipeRows.allSatisfy { Product.verdict($0).recipeShare == .foregroundOnly }
        #expect(everyRecipeRowRuns, "which runs on every one of its own")
        let listenersStillStopSomewhere = rows.contains { r in
            let v = Product.verdict(r)
            return v.presence == .stop && v.recipeShare == .stop
        }
        #expect(listenersStillStopSomewhere, "while the remaining rules do stop them somewhere — the claim is not vacuous")
    }

    /// The three non-running continuation states are one row, and under the only state the app can
    /// feed today no radio claims the background — "inert until P8" stated positively.
    @Test func theNonRunningContinuationStatesAreOneRow() {
        let rows = Product.rows()
        let oneRow = rows.filter { $0.continuation == .refused || $0.continuation == .expired }
            .allSatisfy { Product.verdict($0) == Product.verdict(Product.copy($0, continuation: .notRequested)) }
        #expect(oneRow, "refused and expired decide exactly what not-requested decides — the difference is P8's copy")
        let nothingRunsInert = rows.filter { $0.continuation == .notRequested }.allSatisfy { r in
            let v = Product.verdict(r)
            return v.mesh != .run && v.discovery != .run && v.presence != .run && v.recipeShare != .run
        }
        #expect(nothingRunsInert, "so P7's wiring, which can only feed not-requested, never asserts a running task")
    }

    /// The listener rules are today's `ContentView` chains, flat, on every row.
    @Test func thePresenceAndRecipeRulesAreTodaysListenerChains() {
        let rows = Product.rows()
        let presenceAgrees = rows.allSatisfy { Product.verdict($0).presence == Product.expectedPresence($0) }
        #expect(presenceAgrees, "presence: opted in, foreground, unlocked, on Home / Food / Move / Friends")
        let recipeAgrees = rows.allSatisfy { Product.verdict($0).recipeShare == Product.expectedRecipeShare($0) }
        #expect(recipeAgrees, "recipe: opted in, foreground, unlocked, on Home / Food / Move")
        let recipeNeverOnFriends = rows.filter { $0.selectedTab == .social }
            .allSatisfy { Product.verdict($0).recipeShare == .stop }
        #expect(recipeNeverOnFriends, "the recipe listener never runs on the Friends tab")
        let someRecipeRuns = rows.contains { Product.verdict($0).recipeShare == .foregroundOnly }
        #expect(someRecipeRuns, "and it does run somewhere — the rule is not vacuous")
    }

    /// The flat re-statements of the mesh and discovery rules agree on every row — the named
    /// expectation per row, whose value is catching a guard-order slip.
    @Test func theMirrorOracleAgreesOnEveryRow() {
        let rows = Product.rows()
        let meshAgrees = rows.allSatisfy { Product.verdict($0).mesh == Product.expectedMesh($0) }
        #expect(meshAgrees, "mesh: hard stop, then a continued mesh, then the scene")
        let discoveryAgrees = rows.allSatisfy { Product.verdict($0).discovery == Product.expectedDiscovery($0) }
        #expect(discoveryAgrees, "discovery: hard stop, then the tab in the foreground, then the task, then the link")
    }

    // MARK: The fold, and what is not claimed

    /// `ProximitySessionPresence.folding` is total, and answers the unrepresentable row rather than
    /// trapping on it.
    @Test func theSessionPresenceFoldIsTotal() {
        #expect(ProximitySessionPresence.folding(isInSession: false, hasCommittedPeer: false) == .absent,
                "no mesh and no slot is nothing to keep")
        #expect(ProximitySessionPresence.folding(isInSession: true, hasCommittedPeer: false) == .meshHeld,
                "a mesh with no committed slot is held")
        #expect(ProximitySessionPresence.folding(isInSession: true, hasCommittedPeer: true) == .peerCommitted,
                "a committed slot is a peer")
        #expect(ProximitySessionPresence.folding(isInSession: false, hasCommittedPeer: true) == .peerCommitted,
                "and the unrepresentable row is ANSWERED as a peer, not trapped — `FriendsDiscoveryEntry`'s rule")
    }

    /// What this table does not claim: no scene, no manager, no seam (items 2–4 wire the policy; until
    /// then no shipping code calls it), no continuation task (`.running` is P8 item 6's line, and
    /// `.continuingInBackground` — unreachable when this was written — is raised since P8 item 5 by
    /// `MeshContinuationDriver`, which feeds this policy nothing), and no derivation of
    /// `belowMinimumAge` (item 3's).
    /// What it does pin: the vocabulary's shape.
    @Test func whatThisTableDoesNotClaim() {
        #expect(ProximityRunState.allCases.count == 4,
                "four run states — `hold` is the one §13's sketch lacks, and it is a recorded deviation")
        #expect(ProximityRunState.run.isRunning && ProximityRunState.foregroundOnly.isRunning,
                "two of them mean the radio is up")
        #expect(!ProximityRunState.hold.isRunning && !ProximityRunState.stop.isRunning,
                "and two mean it is not")
        let silent = ProximityRunPolicy.Verdict(
            mesh: .hold, discovery: .stop, presence: .stop, recipeShare: .stop, routedAccessGate: .closed
        )
        #expect(!silent.anyRadioRuns, "a held session with everything else stopped has no radio up")
        let up = ProximityRunPolicy.Verdict(
            mesh: .foregroundOnly, discovery: .stop, presence: .stop, recipeShare: .stop, routedAccessGate: .closed
        )
        #expect(up.anyRadioRuns, "and one foreground radio is enough to say something is up")
    }

    // MARK: The projection (item 2; `appLockEngaged(_:)` retired by P9-3-A, 2026-09-22)

    /// `belowMinimumAge(_:)` is a RULING, never an absence: only the system's final `.below` against
    /// the chat gate, or a guardian's communication limits, stop the radios.
    @Test func theAgeProjectionIsARulingNeverAnAbsence() {
        let epoch = Date(timeIntervalSince1970: 0)
        let never = AgeAssuranceRecord.unknown
        #expect(!ProximityRunPolicy.belowMinimumAge(never), "a device that never asked keeps its radios")
        let declined = never.undetermined(now: epoch)
        #expect(!ProximityRunPolicy.belowMinimumAge(declined), "and so does one that declined to share")
        let below = never.determining(lowerBound: nil, upperBound: 13, provenance: .confirmed, now: epoch)
        #expect(ProximityRunPolicy.belowMinimumAge(below), "a bracket under the line is final")
        let atTheLineUnproven = never.determining(lowerBound: 13, upperBound: nil, provenance: nil, now: epoch)
        #expect(!ProximityRunPolicy.belowMinimumAge(atTheLineUnproven),
                "a bracket at the line with no provenance is undetermined, not below — chat stays shut, the radios do not")
        let meets = never.determining(lowerBound: 16, upperBound: nil, provenance: .confirmed, now: epoch)
        #expect(!ProximityRunPolicy.belowMinimumAge(meets), "a bracket over the line keeps everything")
        let limited = never.determining(
            lowerBound: 16, upperBound: nil, provenance: .confirmed, hasCommunicationLimits: true, now: epoch
        )
        #expect(ProximityRunPolicy.belowMinimumAge(limited),
                "a guardian's communication limits close every interpersonal gate, whatever the age says")
        let agreesWithTheChatGate = !below.allows(.chat) && !limited.allows(.chat) && meets.allows(.chat)
        #expect(agreesWithTheChatGate, "and on the rulings the projection agrees with the chat gate itself")
    }
}

// MARK: - ProximityRunPolicyFunnelTests

/// The store's funnel (P7 items 2–3): the ONE place the app assembles the policy's input, the only
/// writer of the routed access gate outside ProximityKit, and — since item 3 — the one caller of
/// the seams' executor. Driven here without a scene, on a real `FernletStore`.
///
/// **Every row here keeps every radio stopped or held.** A row that starts a radio (`foregroundOnly`
/// for discovery or a listener) would call the real manager's `startJoin()` / `start()` on the
/// store's production transports inside a unit test, so the rows use the Private tab (which stops
/// both listeners and the search without closing a gate leg), the background scene, or duress. The
/// app lock did that job until P9-3-A's fix (2026-09-22) retired it from the policy, and
/// `allowNearbyRecipeShares` DEFAULTS TO TRUE — so a foreground row on a listening tab would now
/// start a real recipe listener, and the Private tab is what keeps these rows honest. Which tab the
/// funnel reads is pinned by the pure table and by construction, not by a row here.
///
/// Serialized and main-actor like `AgeGateWiringTests`, whose store construction this mirrors: each
/// cell pins its own directories so the manager's sidecars are never shared across cells.
@MainActor
@Suite(.serialized)
struct ProximityRunPolicyFunnelTests {

    /// One instant every push is judged against; nothing here reads a clock.
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore(_ name: String) -> FernletStore {
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

    /// The manager holds exactly the gate the policy decided, on every edge, and the verdict is kept.
    @Test func theFunnelWritesTheGateItDecided() {
        let store = makeStore("run-policy-funnel")
        store.selectedTab = .personal
        #expect(store.meshNetworkManager.routedAccessGate == .closed, "every manager starts fail-closed")
        #expect(store.proximityRunVerdict == nil, "and no verdict exists before the first edge")

        let opened = store.applyProximityRunPolicy(
            scenePhase: .active, protectedDataAvailable: true, duressSessionActive: false, now: Self.epoch
        )
        let openGate = MeshRoutedAccessGate(protectedDataAvailable: true, appIsForeground: true, duressActive: false)
        #expect(opened.routedAccessGate == openGate,
                "an unlocked-device, foreground, duress-free edge opens the gate")
        #expect(store.meshNetworkManager.routedAccessGate == openGate,
                "and the manager holds exactly the gate the policy decided")
        #expect(store.proximityRunVerdict == opened, "the store keeps the last verdict — the next edge is diffed against it")
        #expect(opened.presence == .stop && opened.recipeShare == .stop,
                "the Private tab keeps both listeners stopped, so this row starts no radio")
        #expect(opened.discovery == .stop, "and it wants no search")

        let backgrounded = store.applyProximityRunPolicy(
            scenePhase: .background, protectedDataAvailable: true, duressSessionActive: false, now: Self.epoch
        )
        #expect(!store.meshNetworkManager.routedAccessGate.appIsForeground, "a background edge drops the foreground leg")
        #expect(backgrounded.mesh == .hold && backgrounded.discovery == .stop,
                "and the radio half is decided — held, stopped — even though nothing was up")

        let duress = store.applyProximityRunPolicy(
            scenePhase: .active, protectedDataAvailable: true, duressSessionActive: true, now: Self.epoch
        )
        let held = store.meshNetworkManager.routedAccessGate
        #expect(held.duressActive && !held.isOpen, "duress closes the gate through its own leg")
        #expect(duress.mesh == .stop && duress.presence == .stop, "and stops every radio in the verdict")
        #expect(!store.meshNetworkManager.isInSession && !store.meshNetworkManager.isSearching,
                "with nothing to tear down on a fresh store")
    }

    /// The view's entry reuses the scene facts the last scene edge retained, the store's entry
    /// reuses everything — and before any scene edge both assume the most restrictive scene.
    @Test func theViewAndStoreEntriesReuseTheRetainedSceneFacts() {
        let store = makeStore("run-policy-funnel-entries")
        let beforeAnyEdge = store.reapplyProximityRunPolicy(now: Self.epoch)
        #expect(beforeAnyEdge.routedAccessGate == .closed,
                "before the first scene edge the store's entry assumes a backgrounded, locked-down scene")
        #expect(store.meshNetworkManager.routedAccessGate == .closed,
                "so the manager's fail-closed gate is left exactly as it was")
        #expect(beforeAnyEdge.mesh == .hold && beforeAnyEdge.discovery == .stop,
                "and every radio is held or stopped — never started")

        store.applyProximityRunPolicy(
            scenePhase: .background, protectedDataAvailable: true, duressSessionActive: false, now: Self.epoch
        )
        let viewEdge = store.applyProximityRunPolicy(duressSessionActive: true, now: Self.epoch)
        #expect(!viewEdge.routedAccessGate.appIsForeground, "a view edge reuses the retained background phase")
        #expect(viewEdge.routedAccessGate.protectedDataAvailable, "and the retained protected-data fact")
        #expect(viewEdge.routedAccessGate.duressActive && viewEdge.presence == .stop,
                "while reading its own fresh duress fact, which the retained scene facts did not carry")

        let storeEdge = store.reapplyProximityRunPolicy(now: Self.epoch)
        #expect(storeEdge == viewEdge, "a store edge reuses everything the view edge left retained")
        #expect(store.proximityRunVerdict == storeEdge, "and the kept verdict is the latest")
    }

    /// The store's own facts reach the input: the tab mirror, no ruling, no wipe, no task, no session.
    @Test func theFunnelReadsTheStoresFactsAndTheEdgesFacts() {
        let store = makeStore("run-policy-funnel-facts")
        store.selectedTab = .personal
        let verdict = store.applyProximityRunPolicy(
            scenePhase: .active, protectedDataAvailable: true, duressSessionActive: false, now: Self.epoch
        )
        let expected = ProximityRunPolicy.verdict(for: ProximityRunPolicy.Input(
            scenePhase: .active,
            selectedTab: .personal,
            duressSessionActive: false,
            protectedDataAvailable: true,
            belowMinimumAge: false,
            deleteAllInProgress: false,
            continuation: .notRequested,
            session: .absent,
            allowNearbyPresence: store.settings.allowNearbyPresence,
            allowNearbyRecipeShares: store.settings.allowNearbyRecipeShares
        ))
        #expect(verdict == expected,
                "a fresh store's input is the edge's three facts, the mirrored tab, the two opt-ins, no ruling, no wipe, no task, no session")
        #expect(!store.deleteAllInProgress, "no wipe is in flight on a fresh store")
        #expect(store.discoveryTimeoutTask == nil, "and no fresh-search timeout was armed — nothing here starts a search")
    }
}
