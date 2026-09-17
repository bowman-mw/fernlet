// ProximityRunPolicyTests.swift
// FernletTests
//
// Network migration P7 item 1 (plan §13, option A). THE MATRIX IS THE ARTEFACT.
//
// `ProximityRunPolicy` is a pure function over ten enumerable facts, so this suite enumerates the
// WHOLE input product — 23 040 rows — and gives every row a named expectation from an independent
// oracle, rather than spot-checking the rows that happened to be interesting while it was written.
// The oracle is a second spelling of the same rules, written from the SHIPPING conditions
// (`ContentView.shouldRunPresence`, `ContentView.shouldListenForRecipeShares`, the Friends-tab
// start/stop pair and its `hasCommittedPeer` guard) rather than from the policy, and the clause that
// fixed each row is carried in the compared VALUE so it lands in the failure — Swift Testing's
// `Comment?` rejects interpolation as well as concatenation, so it can never be in the comment.
//
// The named `@Test`s underneath are plan §13's load-bearing rows, stated one at a time so a
// regression names itself: a granted continuation task running the mesh through the background, the
// admission door staying `foregroundOnly` (invariant 5), presence and recipe stopping on background,
// a refused task dropping the mesh to `foregroundOnly`, and delete-all / below-age / duress stopping
// everything with the teardown flag up.
//
// Three more cells guard the two rules P5 item 10 handed forward: the decision carries exactly the
// `MeshRoutedAccessGate` the app already assembles, an inactive scene is a foreground scene, and the
// policy file itself contains no raw scene-phase comparison (`ScenePhase` is not frozen).

import Foundation
import SwiftUI
import Testing
import ProximityKit
@testable import Fernlet

/// One row's expectation: the decision the oracle predicts, and the name of the clause that fixed
/// it. Carried as a value so the clause name reaches a failure without an interpolated comment.
private struct ProximityRunClauseVerdict {

    /// The ordered clause that decided this row.
    let clause: String

    /// The decision that clause predicts.
    let decision: ProximityRunDecision
}

/// Plan §13's run policy, over its whole input product.
@MainActor
@Suite struct ProximityRunPolicyTests {

    // MARK: - The product

    /// The three scene phases that exist today, spelled as a literal list because `ScenePhase` is
    /// neither frozen nor `CaseIterable`. A fourth phase would land here and nowhere else — the
    /// policy never compares a phase itself.
    static let scenePhases: [ScenePhase] = [.active, .inactive, .background]

    /// The size of the full input product: 3 phases, 5 tabs, 4 lock states, 3 age states, 4
    /// continuation-task states and five independent `Bool`s.
    static let productSize =
        scenePhases.count
        * FernletTab.allCases.count
        * ProximityAppLockState.allCases.count
        * ProximityChatAgeGate.allCases.count
        * ProximityContinuationTaskState.allCases.count
        * 2 * 2 * 2 * 2 * 2

    /// Every combination of every input, each exactly once.
    ///
    /// - Returns: the full product, in a stable order.
    static func allRows() -> [ProximityRunInputs] {
        var rows: [ProximityRunInputs] = []
        // R2: bounded by the cases of each input — `productSize` iterations.
        for phase in scenePhases {
            for tab in FernletTab.allCases {
                for lock in ProximityAppLockState.allCases {
                    for age in ProximityChatAgeGate.allCases {
                        for task in ProximityContinuationTaskState.allCases {
                            rows.append(contentsOf: boolLeaves(phase, tab, lock, age, task))
                        }
                    }
                }
            }
        }
        return rows
    }

    /// The five-`Bool` leaf of the product for one fixed combination of the enumerable inputs.
    ///
    /// Split out of ``allRows()`` so neither function nests ten loops or runs past the 60-line rule.
    ///
    /// - Parameters:
    ///   - phase: The scene phase.
    ///   - tab: The selected tab.
    ///   - lock: The app-lock state.
    ///   - age: The chat age gate.
    ///   - task: The continuation-task state.
    /// - Returns: the 32 rows that differ only in the five `Bool`s.
    static func boolLeaves(
        _ phase: ScenePhase,
        _ tab: FernletTab,
        _ lock: ProximityAppLockState,
        _ age: ProximityChatAgeGate,
        _ task: ProximityContinuationTaskState
    ) -> [ProximityRunInputs] {
        var leaves: [ProximityRunInputs] = []
        // R2: bounded — 2^5 iterations.
        for protectedData in [false, true] {
            for deletingAll in [false, true] {
                for committedPeer in [false, true] {
                    for presence in [false, true] {
                        for recipes in [false, true] {
                            leaves.append(ProximityRunInputs(
                                scenePhase: phase, selectedTab: tab, lockState: lock,
                                isProtectedDataAvailable: protectedData, chatAgeGate: age,
                                isDeletingAllData: deletingAll, continuationTask: task,
                                hasCommittedPeer: committedPeer, allowsNearbyPresence: presence,
                                allowsNearbyRecipeShares: recipes
                            ))
                        }
                    }
                }
            }
        }
        return leaves
    }

    /// A single row, with every field defaulted to a live Friends session on an unlocked device.
    ///
    /// - Parameters:
    ///   - phase: The scene phase.
    ///   - tab: The selected tab.
    ///   - lock: The app-lock state.
    ///   - protectedData: Whether iOS data protection is available.
    ///   - age: The chat age gate.
    ///   - deletingAll: Whether a delete-all is running.
    ///   - task: The continuation-task state.
    ///   - committedPeer: Whether a peer is committed.
    ///   - presence: The presence consent.
    ///   - recipes: The recipe-share consent.
    /// - Returns: the inputs.
    static func inputs(
        phase: ScenePhase = .active,
        tab: FernletTab = .social,
        lock: ProximityAppLockState = .unlocked,
        protectedData: Bool = true,
        age: ProximityChatAgeGate = .meets,
        deletingAll: Bool = false,
        task: ProximityContinuationTaskState = .inert,
        committedPeer: Bool = true,
        presence: Bool = true,
        recipes: Bool = true
    ) -> ProximityRunInputs {
        ProximityRunInputs(
            scenePhase: phase, selectedTab: tab, lockState: lock,
            isProtectedDataAvailable: protectedData, chatAgeGate: age,
            isDeletingAllData: deletingAll, continuationTask: task,
            hasCommittedPeer: committedPeer, allowsNearbyPresence: presence,
            allowsNearbyRecipeShares: recipes
        )
    }

    // MARK: - The independent oracle

    /// The tabs `ContentView.shouldRunPresence` permits — everything but Private
    /// (`App/Fernlet/ContentView.swift:1781`).
    static let presenceTabs: Set<FernletTab> = [.home, .food, .move, .social]

    /// The tabs `ContentView.shouldListenForRecipeShares` permits
    /// (`App/Fernlet/ContentView.swift:1722`). Friends is deliberately absent.
    static let recipeTabs: Set<FernletTab> = [.home, .food, .move]

    /// The expected decision for one row, and the clause that fixed it.
    ///
    /// Written as an ORDERED clause scan, first match wins, from the shipping conditions rather than
    /// from `ProximityRunPolicy`: set membership where the policy switches, an explicit dominating
    /// prefix where the policy guards. Clauses 1 to 3 are plan §13's dominating inputs; clauses 4 to
    /// 6 name the mesh's reason, which is what §13's load-bearing rows are about, and the other three
    /// radios are resolved beside them.
    ///
    /// - Parameter row: One row of the product.
    /// - Returns: the predicted decision and its clause name.
    private static func oracle(_ row: ProximityRunInputs) -> ProximityRunClauseVerdict {
        let gate = MeshRoutedAccessGate(
            protectedDataAvailable: row.isProtectedDataAvailable,
            appIsForeground: row.isForeground,
            duressActive: row.lockState == .duress
        )
        if row.isDeletingAllData { return torn("delete-all wins", gate, row.isForeground) }
        if row.chatAgeGate == .below { return torn("below-age wins", gate, row.isForeground) }
        if row.lockState == .duress { return torn("duress wins", gate, row.isForeground) }
        let mesh = meshClause(row)
        return ProximityRunClauseVerdict(clause: mesh.0, decision: ProximityRunDecision(
            meshLinks: mesh.1,
            discoveryAdmission: doorClause(row),
            presence: presenceClause(row),
            recipeShare: recipeClause(row),
            tearsDownSession: false,
            isForeground: row.isForeground,
            accessGate: gate
        ))
    }

    /// The decision all three dominating clauses share: every radio down, the session torn down.
    ///
    /// - Parameters:
    ///   - clause: The clause name.
    ///   - gate: The routed access gate for this row.
    ///   - isForeground: The row's foreground fact.
    /// - Returns: the verdict.
    private static func torn(
        _ clause: String, _ gate: MeshRoutedAccessGate, _ isForeground: Bool
    ) -> ProximityRunClauseVerdict {
        ProximityRunClauseVerdict(clause: clause, decision: ProximityRunDecision(
            meshLinks: .stop, discoveryAdmission: .stop, presence: .stop, recipeShare: .stop,
            tearsDownSession: true, isForeground: isForeground, accessGate: gate
        ))
    }

    /// Clauses 4 to 6: the mesh links' reason and directive.
    ///
    /// - Parameter row: One row of the product.
    /// - Returns: the clause name and the mesh directive.
    static func meshClause(_ row: ProximityRunInputs) -> (String, ProximityRunState) {
        let armed = row.hasCommittedPeer || row.selectedTab == .social
        if !armed {
            return ("off the Friends tab with no committed peer: nothing mesh-side runs", .stop)
        }
        if row.hasCommittedPeer && row.continuationTask == .granted {
            return ("CPT granted keeps the mesh up in background", .run)
        }
        return ("a user-started mesh is up while the app is foreground", .foregroundOnly)
    }

    /// The admission door: up on the Friends tab or over a committed peer, never in the background.
    ///
    /// - Parameter row: One row of the product.
    /// - Returns: the discovery/admission directive.
    static func doorClause(_ row: ProximityRunInputs) -> ProximityRunState {
        (row.selectedTab == .social || row.hasCommittedPeer) ? .foregroundOnly : .stop
    }

    /// Presence: consent, an app lock that is not locked, and one of the four non-Private tabs.
    ///
    /// - Parameter row: One row of the product.
    /// - Returns: the presence directive.
    static func presenceClause(_ row: ProximityRunInputs) -> ProximityRunState {
        let allowed = row.allowsNearbyPresence
            && row.lockState != .locked
            && presenceTabs.contains(row.selectedTab)
        return allowed ? .foregroundOnly : .stop
    }

    /// Recipe shares: consent, an app lock that is not locked, and one of the three Home/Food/Move
    /// tabs.
    ///
    /// - Parameter row: One row of the product.
    /// - Returns: the recipe-share directive.
    static func recipeClause(_ row: ProximityRunInputs) -> ProximityRunState {
        let allowed = row.allowsNearbyRecipeShares
            && row.lockState != .locked
            && recipeTabs.contains(row.selectedTab)
        return allowed ? .foregroundOnly : .stop
    }

    // MARK: - The matrix

    /// **The artefact.** Every row of the input product, against its named clause.
    @Test func everyRowOfTheInputProductMatchesItsNamedClause() {
        var mismatches: [String] = []
        // R2: bounded by the enumerated product.
        for row in Self.allRows() {
            let expected = Self.oracle(row)
            let actual = ProximityRunPolicy.decide(row)
            if actual != expected.decision {
                mismatches.append(
                    "clause [\(expected.clause)] row \(row) expected \(expected.decision) got \(actual)"
                )
            }
        }
        #expect(mismatches.first == nil, "a row of the input product disagrees with its named clause")
        #expect(mismatches.isEmpty, "the whole input product agrees with the oracle")
    }

    /// The enumeration is the WHOLE product and nothing is counted twice — a table that silently
    /// skipped a row would pass the matrix above for the wrong reason.
    @Test func theInputProductIsEnumeratedWhole() {
        let rows = Self.allRows()
        #expect(rows.count == Self.productSize, "the enumeration covers the whole input product")
        #expect(Set(rows).count == Self.productSize,
                "no combination is enumerated twice, so none is skipped")
        #expect(Self.productSize == 23_040,
                "3 phases, 5 tabs, 4 lock states, 3 age states, 4 task states, five Bools")
        #expect(Self.scenePhases.count == 3, "the three scene phases that exist today")
    }

    // MARK: - Plan §13's load-bearing rows

    /// **§13:** user-started mesh + CPT granted ⇒ mesh `run` in background.
    @Test func aGrantedContinuationTaskRunsTheMeshThroughTheBackground() {
        let background = ProximityRunPolicy.decide(
            Self.inputs(phase: .background, task: .granted, committedPeer: true)
        )
        #expect(background.meshLinks == .run,
                "only a granted continuation task over a committed peer earns a run directive")
        #expect(background.isUp(.meshLinks), "a run directive resolves up in the background")
        #expect(!background.isForeground, "the backgrounded phase is the one leg that is not foreground")
        #expect(!background.tearsDownSession, "background continuation is not a teardown")
        let noPeer = ProximityRunPolicy.decide(
            Self.inputs(phase: .background, task: .granted, committedPeer: false)
        )
        #expect(noPeer.meshLinks != .run,
                "hasCommittedPeer is the radio guard: a mesh with nobody in it earns no run")
    }

    /// **§13, invariant 5:** discovery/admission is `foregroundOnly` and never `run` — admitting a
    /// NEW peer stays a foreground act whatever the mesh itself is doing.
    @Test func theAdmissionDoorIsForegroundOnlyAndNeverRuns() {
        let foreground = ProximityRunPolicy.decide(Self.inputs(phase: .active, task: .granted))
        let background = ProximityRunPolicy.decide(Self.inputs(phase: .background, task: .granted))
        #expect(foreground.discoveryAdmission == .foregroundOnly, "the door is a foreground affair")
        #expect(background.discoveryAdmission == .foregroundOnly,
                "the directive reads the same in both phases; the resolution is what differs")
        #expect(foreground.isUp(.discoveryAdmission), "resolved up while the app is foreground")
        #expect(!background.isUp(.discoveryAdmission), "resolved down once the app is backgrounded")
        let neverRuns = Self.allRows().allSatisfy {
            ProximityRunPolicy.decide($0).discoveryAdmission != .run
        }
        #expect(neverRuns, "invariant 5: no row of the product ever runs the admission door")
    }

    /// **§13:** presence + recipe `stop` on background — and neither is ever directed to `run`.
    @Test func presenceAndRecipeStopOnBackground() {
        let background = ProximityRunPolicy.decide(
            Self.inputs(phase: .background, tab: .home, task: .granted)
        )
        #expect(!background.isUp(.presence), "presence does not follow the mesh into the background")
        #expect(!background.isUp(.recipeShare), "the recipe listener does not either")
        let active = ProximityRunPolicy.decide(Self.inputs(phase: .active, tab: .home))
        #expect(active.isUp(.presence), "presence runs on Home with consent and an unlocked app")
        #expect(active.isUp(.recipeShare), "so does the recipe listener")
        let neverRun = Self.allRows().allSatisfy { row in
            let decision = ProximityRunPolicy.decide(row)
            return decision.presence != .run && decision.recipeShare != .run
        }
        #expect(neverRun, "no row ever grants presence or the recipe listener a background run")
    }

    /// **§13:** CPT refused ⇒ mesh `foregroundOnly`. Expired and inert land in the same place, and
    /// inert is the only value P7's wiring ever passes.
    @Test func aRefusedOrExpiredContinuationTaskDropsTheMeshToForegroundOnly() {
        // R2: bounded by the three non-granted cases.
        for task in [ProximityContinuationTaskState.refused, .expired, .inert] {
            let background = ProximityRunPolicy.decide(Self.inputs(phase: .background, task: task))
            let foreground = ProximityRunPolicy.decide(Self.inputs(phase: .active, task: task))
            #expect(background.meshLinks == .foregroundOnly,
                    "without a granted task the mesh is a foreground affair")
            #expect(!background.isUp(.meshLinks), "and so it resolves down once backgrounded")
            #expect(foreground.isUp(.meshLinks), "while it stays up in the foreground")
            #expect(!background.tearsDownSession, "a refusal stands the radio down, it does not tear down")
        }
        let onlyGrantedRuns = Self.allRows().allSatisfy { row in
            ProximityRunPolicy.decide(row).meshLinks != .run || row.continuationTask == .granted
        }
        #expect(onlyGrantedRuns, "no row runs the mesh without a granted continuation task")
    }

    /// **§13:** delete-all / below-age / duress ⇒ every radio `stop`, teardown true. Each of the
    /// three is checked on its own, then the claim is made over the whole product in both
    /// directions — nothing else tears down.
    @Test func deleteAllBelowAgeAndDuressStopEveryRadioAndTearDown() {
        let rows = [
            Self.inputs(deletingAll: true, task: .granted),
            Self.inputs(age: .below, task: .granted),
            Self.inputs(lock: .duress, task: .granted)
        ]
        // R2: bounded by the three dominating inputs.
        for row in rows {
            let decision = ProximityRunPolicy.decide(row)
            #expect(decision.tearsDownSession, "a dominating input tears the session down")
            let allStopped = ProximityRadio.allCases.allSatisfy {
                decision.directive(for: $0) == .stop && !decision.isUp($0)
            }
            #expect(allStopped, "a dominating input stops every radio, granted task or not")
        }
        let exactly = Self.allRows().allSatisfy { row in
            ProximityRunPolicy.decide(row).tearsDownSession == row.demandsTeardown
        }
        #expect(exactly, "exactly the three dominating inputs tear down, and nothing else does")
    }

    /// The app lock gates NOTHING in the mesh (D-10.3) — it takes presence and the recipe listener
    /// down, as `ContentView` does today, and leaves the two mesh radios untouched.
    @Test func theAppLockGatesTheTwoListenersAndNothingInTheMesh() {
        let locked = ProximityRunPolicy.decide(Self.inputs(tab: .home, lock: .locked))
        let unlocked = ProximityRunPolicy.decide(Self.inputs(tab: .home, lock: .unlocked))
        #expect(locked.presence == .stop, "a locked app stops the presence radio")
        #expect(locked.recipeShare == .stop, "and the recipe listener")
        #expect(locked.meshLinks == unlocked.meshLinks, "the app lock does not gate the mesh links")
        #expect(locked.discoveryAdmission == unlocked.discoveryAdmission,
                "nor the admission door — no lock scope covers Friends")
        let unconfigured = ProximityRunPolicy.decide(Self.inputs(tab: .home, lock: .notConfigured))
        #expect(unconfigured.presence == .foregroundOnly,
                "an unconfigured lock reads as unlocked, as the shipping condition does")
    }

    /// Protected data decides PLAINTEXT, never a radio: flipping it moves the gate leg and no
    /// directive anywhere in the product.
    @Test func protectedDataMovesTheGateAndNoRadio() {
        var mismatches: [String] = []
        // R2: bounded by the enumerated product.
        for row in Self.allRows() where row.isProtectedDataAvailable {
            let twin = Self.inputs(
                phase: row.isForeground ? .active : .background, tab: row.selectedTab,
                lock: row.lockState, protectedData: false, age: row.chatAgeGate,
                deletingAll: row.isDeletingAllData, task: row.continuationTask,
                committedPeer: row.hasCommittedPeer, presence: row.allowsNearbyPresence,
                recipes: row.allowsNearbyRecipeShares
            )
            let withData = ProximityRunPolicy.decide(row)
            let withoutData = ProximityRunPolicy.decide(twin)
            let sameRadios = ProximityRadio.allCases.allSatisfy {
                withData.directive(for: $0) == withoutData.directive(for: $0)
            }
            if !sameRadios || withData.accessGate == withoutData.accessGate {
                mismatches.append("row \(row) available \(withData) unavailable \(withoutData)")
            }
        }
        #expect(mismatches.first == nil, "protected data moved a radio, or failed to move the gate")
    }

    // MARK: - The two rules P5 item 10 handed forward

    /// The decision carries exactly the gate `FernletApp.pushRoutedAccessGate` assembles today —
    /// protected data, `routedGateForeground(for:)`'s answer, and the duress session — for every
    /// phase, and its own foreground fact never drifts from the gate's leg.
    @Test func theDecisionCarriesTheGateTheAppAlreadyAssembles() {
        // R2: bounded by the three known phases.
        for phase in Self.scenePhases {
            let decision = ProximityRunPolicy.decide(Self.inputs(phase: phase, lock: .duress))
            let expected = MeshRoutedAccessGate(
                protectedDataAvailable: true,
                appIsForeground: FernletApp.routedGateForeground(for: phase),
                duressActive: true
            )
            #expect(decision.accessGate == expected, "the gate is the app's three facts, unchanged")
        }
        let consistent = Self.allRows().allSatisfy { row in
            let decision = ProximityRunPolicy.decide(row)
            return decision.accessGate == MeshRoutedAccessGate(
                protectedDataAvailable: row.isProtectedDataAvailable,
                appIsForeground: row.isForeground,
                duressActive: row.lockState == .duress
            ) && decision.isForeground == decision.accessGate.appIsForeground
        }
        #expect(consistent, "every row carries the app's gate, and one foreground fact only")
    }

    /// An INACTIVE scene is a FOREGROUND scene (P5's post-close correction): Control Center, a call
    /// banner, a system prompt, the app's own Face ID sheet, iPad Split View. It decides exactly as
    /// an active scene does, and only the backgrounded phase differs.
    @Test func anInactiveSceneIsAForegroundScene() {
        let inactive = ProximityRunPolicy.decide(Self.inputs(phase: .inactive, tab: .home))
        let active = ProximityRunPolicy.decide(Self.inputs(phase: .active, tab: .home))
        let background = ProximityRunPolicy.decide(Self.inputs(phase: .background, tab: .home))
        #expect(inactive.isForeground, "an inactive scene is still foreground")
        #expect(inactive == active, "an inactive scene decides exactly as an active one")
        #expect(inactive != background, "only the backgrounded phase decides differently")
        #expect(FernletApp.routedGateForeground(for: .inactive),
                "the one mapping the policy derives its foreground fact through says so too")
        #expect(inactive.isUp(.presence),
                "presence survives a Control Center pull rather than bouncing with it")
    }

    /// The policy file decides its foreground fact in ONE place and compares no phase itself —
    /// `ScenePhase` is not frozen, and an `@unknown default` under warnings-as-errors would have to
    /// pick a side for a phase that does not exist yet.
    ///
    /// Whole-line comments are stripped and whitespace collapsed before the search, so the claim is
    /// about CODE and cannot be dodged by re-wrapping. Every needle is fixtured the other way in the
    /// same cell: a matcher that cannot find the thing it forbids passes vacuously.
    @Test func thePolicyFileHoldsNoRawScenePhaseCompare() throws {
        let path = "App/Fernlet/ProximityRunPolicy.swift"
        let code = Self.collapsed(MeshRoutedSourceScan.codeOnly(try RepoRoot.source(path)))
        #expect(code.contains("FernletApp.routedGateForeground(for: scenePhase)"),
                "the policy still derives its foreground fact through the one mapping")
        #expect(!code.contains("== .background"), "a raw phase compare decides the foreground fact")
        #expect(!code.contains("!= .background"), "a raw phase compare decides the foreground fact")
        #expect(!code.contains("== .active"), "a raw phase compare decides the foreground fact")
        #expect(!code.contains("case .background"), "a switch over a non-frozen ScenePhase")
        #expect(!code.contains("switch scenePhase"), "a switch over a non-frozen ScenePhase")
        let broken = Self.collapsed("if phase\n    ==   .background { }\nswitch scenePhase {\ncase .background: break\n}")
        #expect(broken.contains("== .background"), "the needle matches a re-wrapped raw compare")
        #expect(broken.contains("case .background"), "the needle matches a re-wrapped switch arm")
        #expect(broken.contains("switch scenePhase"), "the needle matches a re-wrapped switch head")
        #expect(Self.collapsed("a  !=\n.background").contains("!= .background"),
                "the inequality needle matches too")
        #expect(Self.collapsed("x ==\n\t.active").contains("== .active"),
                "the active-phase needle matches too")
    }

    /// `source` with every run of whitespace collapsed to one space, so a needle cannot be dodged by
    /// wrapping a line.
    ///
    /// - Parameter source: Comment-stripped Swift.
    /// - Returns: the same code on one line.
    static func collapsed(_ source: String) -> String {
        source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
