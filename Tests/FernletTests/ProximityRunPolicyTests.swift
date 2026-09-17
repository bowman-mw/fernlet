// ProximityRunPolicyTests.swift
// FernletTests
//
// Network migration P7 item 1 (plan §13, option A). THE MATRIX IS THE ARTEFACT.
//
// `ProximityRunPolicy` is a pure function over ten enumerable facts, so this suite enumerates the
// WHOLE input product — 23 040 constructor calls over 15 360 DISTINCT `ProximityRunInputs`, because
// the struct stores `FernletApp.routedGateForeground(for:)`'s answer rather than the phase and the
// two foreground phases therefore build one value — and holds every row against an INDEPENDENT
// oracle.
//
// The oracle is not a second spelling of the policy. It takes the RAW `ScenePhase` and spells the
// SHIPPING conditions wherever plan §13 is silent: `ContentView.shouldRunPresence`
// (`App/Fernlet/ContentView.swift:1778–1788`), `shouldListenForRecipeShares` (`:1719–1729`), and the
// Friends-tab start/stop pair (`:329`, `:348–369`) with its `stopFriendsDiscovery()` bail on a
// committed peer (`:1858–1863`). Every one of those asks for `scenePhase == .active` — a fact
// `ProximityRunInputs` cannot carry, which is exactly why the old oracle, reading `row.isForeground`
// back off the value the policy's own initialiser computed, could never check that leg. Where §13
// speaks, §13 wins and the clause says so: a granted continuation task over a committed peer keeps
// the mesh up in the background (shipping has no such notion), the admission door is never up in the
// background (invariant 5), and the three dominating inputs stop every radio and tear the session
// down. A raw phase compare is the POINT of this oracle; the wall that forbids one binds the POLICY
// file, and `thePolicyFileHoldsNoRawScenePhaseCompare` keeps it there.
//
// Policy and shipping therefore DISAGREE, deliberately, and the matrix pins that disagreement
// exactly rather than papering over it: 832 rows, every one of them an inactive scene, every one of
// them a radio `ContentView` stands down and the policy holds `foregroundOnly`. That is the widening
// `ProximityRunPolicy.presenceDirective(_:)` documents, and it reaches all four radios. Any other
// disagreement — a different phase, the opposite direction, a moved teardown flag, a moved gate — is
// a failure.
//
// The named `@Test`s underneath are plan §13's load-bearing rows, stated one at a time with LITERAL
// expected values and no reference to the oracle, so a regression names itself: a granted
// continuation task running the mesh through the background, the admission door staying
// `foregroundOnly` (invariant 5), presence and recipe stopping on background, a refused task
// dropping the mesh to `foregroundOnly`, and delete-all / below-age / duress stopping everything
// with the teardown flag up.
//
// Four more cells guard the rules P5 item 10 handed forward: the decision carries exactly the
// `MeshRoutedAccessGate` the app already assembles, both gate-construction sites are brace-matched
// and shown to name the same three facts, an inactive scene is a foreground scene, and the policy
// file itself contains no raw scene-phase comparison (`ScenePhase` is not frozen).

import Foundation
import SwiftUI
import Testing
import ProximityKit
@testable import Fernlet

/// One row of the product: the raw `ScenePhase` it was built from, beside the inputs the policy is
/// handed.
///
/// The phase has to be carried alongside because `ProximityRunInputs` deliberately stores
/// `FernletApp.routedGateForeground(for:)`'s ANSWER and not the phase, so `.active` and `.inactive`
/// build byte-identical values. The oracle is written from shipping conditions that ask for
/// `.active`, so it needs the phase itself; reading `isForeground` instead is what made the first
/// version of this suite a tautology.
private struct ProximityRunProductRow: Hashable {

    /// The scene phase this row was built from.
    let phase: ScenePhase

    /// The inputs handed to the policy.
    let inputs: ProximityRunInputs
}

/// One row's verdict against the oracle.
///
/// The offending row is carried as a VALUE rather than named in a comment: Swift Testing's
/// `Comment?` rejects interpolation as well as concatenation, so a failure can only carry detail
/// this way.
private struct ProximityRunRowVerdict {

    /// A description of the first strict-leg disagreement — teardown flag, carried gate or
    /// foreground fact — or nil when all three matched.
    let strictFailure: String?

    /// Whether any radio disagreed with shipping on this row.
    let deviates: Bool

    /// A description of the first disagreement that is NOT the documented inactive-scene widening,
    /// or nil when every disagreement on this row was.
    let undocumented: String?
}

/// Plan §13's run policy, over its whole input product.
@MainActor
@Suite struct ProximityRunPolicyTests {

    // MARK: - The product

    /// The three scene phases that exist today, spelled as a literal list because `ScenePhase` is
    /// neither frozen nor `CaseIterable`. A fourth phase would land here and nowhere else — the
    /// policy never compares a phase itself.
    static let scenePhases: [ScenePhase] = [.active, .inactive, .background]

    /// How many `ProximityRunInputs` the enumeration CONSTRUCTS: 3 phases, 5 tabs, 4 lock states, 3
    /// age states, 4 continuation-task states and five independent `Bool`s.
    ///
    /// **Not the number of distinct input values** — see ``distinctInputValues``. The name says
    /// "enumerated" for that reason: it counts constructor calls.
    static let rowsEnumerated =
        scenePhases.count
        * FernletTab.allCases.count
        * ProximityAppLockState.allCases.count
        * ProximityChatAgeGate.allCases.count
        * ProximityContinuationTaskState.allCases.count
        * 2 * 2 * 2 * 2 * 2

    /// How many DISTINCT `ProximityRunInputs` those calls can produce: 2 foreground facts × 5 tabs ×
    /// 4 lock states × 3 age states × 4 task states × five `Bool`s = 15 360, two thirds of
    /// ``rowsEnumerated``.
    ///
    /// The struct has no phase field: its one initialiser stores
    /// `FernletApp.routedGateForeground(for:)`'s answer, so `.active` and `.inactive` collapse to
    /// ONE input value by construction. That collapse is the policy's design (an inactive scene is a
    /// foreground scene), which is why the matrix carries the phase beside the inputs instead. The
    /// leading `2` is the whole difference from ``rowsEnumerated``: two foreground FACTS where the
    /// enumeration walks three phases.
    static let distinctInputValues =
        2
        * FernletTab.allCases.count
        * ProximityAppLockState.allCases.count
        * ProximityChatAgeGate.allCases.count
        * ProximityContinuationTaskState.allCases.count
        * 2 * 2 * 2 * 2 * 2

    /// How many rows of the product the policy decides differently from shipping — the deliberate
    /// inactive-scene widening, counted by hand from the enumeration rather than read off a run.
    ///
    /// Only `.inactive` rows can deviate, and only rows no dominating input has already stopped:
    /// delete-all false, age in `{meets, undetermined}`, lock in `{notConfigured, unlocked, locked}`.
    /// The continuation task (4), protected data (2) and the two surviving age states (2) change no
    /// radio here, so they are a flat ×16 over the combinations that do —
    /// (tab, lock, committed peer, presence consent, recipe consent) = 5 × 3 × 2 × 2 × 2 = 120.
    ///
    /// Of those 120, a row deviates when the policy holds a radio up at `.inactive` that shipping
    /// stands down:
    ///
    ///   * Home / Food / Move (3 tabs): presence or the recipe listener is up ⇒ lock not `.locked`
    ///     (2 of 3) × at least one of the two consents (3 of 4) × committed peer free (2) = 12 each,
    ///     so **36**.
    ///   * Friends (1 tab): (presence consent ∧ lock not `.locked`) ∨ no committed peer — the
    ///     peerless Friends search takes the mesh links and the admission door with it. Of the 24
    ///     combinations, the 8 that do NOT deviate are peer committed (1 of 2) ∧ not
    ///     (presence consent ∧ lock not `.locked`) (4 of 6) × recipe consent free (2), so **16**.
    ///   * Private (1 tab): presence and the recipe listener both stop on it, and the two mesh
    ///     radios follow the committed peer in both spellings, so **0**.
    ///
    /// (36 + 16 + 0) × 16 = 52 × 16 = **832**.
    static let inactiveWideningRows = 832

    /// Every combination of every input, each exactly once, each carrying the phase it was built
    /// from.
    ///
    /// - Returns: the full product, in a stable order.
    private static func allRows() -> [ProximityRunProductRow] {
        var rows: [ProximityRunProductRow] = []
        // R2: bounded by the cases of each input — `rowsEnumerated` iterations.
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
    private static func boolLeaves(
        _ phase: ScenePhase,
        _ tab: FernletTab,
        _ lock: ProximityAppLockState,
        _ age: ProximityChatAgeGate,
        _ task: ProximityContinuationTaskState
    ) -> [ProximityRunProductRow] {
        var leaves: [ProximityRunProductRow] = []
        // R2: bounded — 2^5 iterations.
        for protectedData in [false, true] {
            for deletingAll in [false, true] {
                for committedPeer in [false, true] {
                    for presence in [false, true] {
                        for recipes in [false, true] {
                            leaves.append(ProximityRunProductRow(phase: phase, inputs: Self.inputs(
                                phase: phase, tab: tab, lock: lock, protectedData: protectedData,
                                age: age, deletingAll: deletingAll, task: task,
                                committedPeer: committedPeer, presence: presence, recipes: recipes
                            )))
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

    /// Plan §13's three dominating inputs, spelled from the three FIELDS rather than read back off
    /// `ProximityRunInputs.demandsTeardown` — which is the policy's own answer, so comparing against
    /// it would be the policy agreeing with itself.
    ///
    /// - Parameter inputs: One row's inputs.
    /// - Returns: `true` for a delete-all, a final below-age verdict, or a duress session.
    private static func dominates(_ inputs: ProximityRunInputs) -> Bool {
        inputs.isDeletingAllData || inputs.chatAgeGate == .below || inputs.lockState == .duress
    }

    /// `ContentView.shouldRunPresence` (`App/Fernlet/ContentView.swift:1778–1788`), spelled out:
    /// consent, the ACTIVE phase, one of the four non-Private tabs, and a lock that is not `.locked`.
    ///
    /// - Parameter row: One row of the product.
    /// - Returns: whether shipping runs the presence radio in this row's phase.
    private static func shippingPresenceIsUp(_ row: ProximityRunProductRow) -> Bool {
        row.inputs.allowsNearbyPresence
            && row.phase == .active
            && presenceTabs.contains(row.inputs.selectedTab)
            && row.inputs.lockState != .locked
    }

    /// `ContentView.shouldListenForRecipeShares` (`App/Fernlet/ContentView.swift:1719–1729`):
    /// consent, the ACTIVE phase, one of the three Home/Food/Move tabs, and a lock that is not
    /// `.locked`.
    ///
    /// - Parameter row: One row of the product.
    /// - Returns: whether shipping runs the recipe listener in this row's phase.
    private static func shippingRecipeIsUp(_ row: ProximityRunProductRow) -> Bool {
        row.inputs.allowsNearbyRecipeShares
            && row.phase == .active
            && recipeTabs.contains(row.inputs.selectedTab)
            && row.inputs.lockState != .locked
    }

    /// The Friends search as `ContentView` actually drives it. `handleTabChange`
    /// (`App/Fernlet/ContentView.swift:329`) and `handleScenePhaseChange` (`:348–369`) arm it only on
    /// the Friends tab in the ACTIVE phase and stand it down otherwise — except that
    /// `stopFriendsDiscovery()` (`:1858–1863`) bails on a committed peer, so a committed mesh survives
    /// every tab exit and every scene change.
    ///
    /// - Parameter row: One row of the product.
    /// - Returns: whether shipping has the friend radios armed in this row's phase.
    private static func shippingSearchIsUp(_ row: ProximityRunProductRow) -> Bool {
        row.inputs.hasCommittedPeer || (row.phase == .active && row.inputs.selectedTab == .social)
    }

    /// The admission door. §13's invariant 5 amends shipping here: admitting a NEW peer is a
    /// foreground act, so the door is down in the background even over a committed peer, which is
    /// the one thing shipping's single `startJoin`/`stopJoin` seam cannot express.
    ///
    /// - Parameter row: One row of the product.
    /// - Returns: whether the door is open in this row's phase.
    private static func shippingDoorIsUp(_ row: ProximityRunProductRow) -> Bool {
        row.phase != .background && shippingSearchIsUp(row)
    }

    /// The mesh links. §13 amends shipping twice: a granted continuation task over a committed peer
    /// keeps the links up in the background (shipping has no continuation task at all), and without
    /// one the links are a foreground affair even over a committed peer (shipping's
    /// `stopFriendsDiscovery()` bail would have kept them up through a backgrounding).
    ///
    /// - Parameter row: One row of the product.
    /// - Returns: whether the links are up in this row's phase.
    private static func shippingMeshIsUp(_ row: ProximityRunProductRow) -> Bool {
        if row.inputs.hasCommittedPeer && row.inputs.continuationTask == .granted { return true }
        return row.phase != .background && shippingSearchIsUp(row)
    }

    /// Shipping's answer for one radio in one scene phase, with §13's amendments where §13 speaks.
    ///
    /// - Parameters:
    ///   - radio: The radio being asked about.
    ///   - row: One row of the product.
    /// - Returns: whether that radio is up right now.
    private static func shippingIsUp(_ radio: ProximityRadio, _ row: ProximityRunProductRow) -> Bool {
        guard !dominates(row.inputs) else { return false }
        switch radio {
        case .meshLinks: return shippingMeshIsUp(row)
        case .discoveryAdmission: return shippingDoorIsUp(row)
        case .presence: return shippingPresenceIsUp(row)
        case .recipeShare: return shippingRecipeIsUp(row)
        }
    }

    /// The gate the app assembles for this row, with the foreground leg spelled `phase !=
    /// .background` from the RAW phase rather than echoed back from `ProximityRunInputs`.
    ///
    /// - Parameter row: One row of the product.
    /// - Returns: the expected gate value.
    private static func shippingGate(_ row: ProximityRunProductRow) -> MeshRoutedAccessGate {
        MeshRoutedAccessGate(
            protectedDataAvailable: row.inputs.isProtectedDataAvailable,
            appIsForeground: row.phase != .background,
            duressActive: row.inputs.lockState == .duress
        )
    }

    /// Holds one row against the oracle.
    ///
    /// - Parameter row: One row of the product.
    /// - Returns: its verdict.
    private static func verdict(_ row: ProximityRunProductRow) -> ProximityRunRowVerdict {
        let decision = ProximityRunPolicy.decide(row.inputs)
        var strict: String?
        if decision.tearsDownSession != dominates(row.inputs) {
            strict = "teardown flag: row \(row) decided \(decision)"
        } else if decision.accessGate != shippingGate(row) {
            strict = "carried gate: row \(row) decided \(decision)"
        } else if decision.isForeground != (row.phase != .background) {
            strict = "foreground fact: row \(row) decided \(decision)"
        }
        var deviates = false
        var undocumented: String?
        // R2: bounded by the four radios.
        for radio in ProximityRadio.allCases where decision.isUp(radio) != shippingIsUp(radio, row) {
            deviates = true
            let isTheWidening = row.phase == .inactive
                && !shippingIsUp(radio, row)
                && decision.directive(for: radio) == .foregroundOnly
            if !isTheWidening && undocumented == nil {
                undocumented = "radio \(radio): row \(row) decided \(decision)"
            }
        }
        return ProximityRunRowVerdict(
            strictFailure: strict, deviates: deviates, undocumented: undocumented
        )
    }

    // MARK: - The matrix

    /// **The artefact.** Every row of the input product against the SHIPPING conditions — and the one
    /// deliberate widening pinned by count, so it can neither grow nor quietly shrink.
    @Test func everyRowOfTheProductMatchesShippingOrTheOneDocumentedWidening() {
        var strictFailures: [String] = []
        var undocumented: [String] = []
        var deviatingRows = 0
        // R2: bounded by the enumerated product.
        for row in Self.allRows() {
            let rowVerdict = Self.verdict(row)
            if let failure = rowVerdict.strictFailure { strictFailures.append(failure) }
            if let note = rowVerdict.undocumented { undocumented.append(note) }
            if rowVerdict.deviates { deviatingRows += 1 }
        }
        #expect(strictFailures.first == nil,
                "a row's teardown flag, carried gate or foreground fact is not the app's own")
        #expect(undocumented.first == nil,
                "a row leaves shipping other than by holding a foregroundOnly radio up while inactive")
        #expect(deviatingRows == Self.inactiveWideningRows,
                "the inactive-scene widening covers a different set of rows than this suite counts")
    }

    /// The enumeration is the WHOLE product and nothing is counted twice — a table that silently
    /// skipped a row would pass the matrix above for the wrong reason. The distinct-value count is
    /// SMALLER on purpose, and pinned so the reason stays visible.
    @Test func theInputProductIsEnumeratedWhole() {
        let rows = Self.allRows()
        #expect(rows.count == Self.rowsEnumerated, "the enumeration makes one call per combination")
        #expect(Set(rows).count == Self.rowsEnumerated,
                "no phase-and-inputs combination is enumerated twice")
        #expect(Self.rowsEnumerated == 23_040,
                "3 phases, 5 tabs, 4 lock states, 3 age states, 4 task states, five Bools")
        #expect(Set(rows.map(\.inputs)).count == Self.distinctInputValues,
                "the two foreground phases build one input value, and that is the only collapse")
        #expect(Self.distinctInputValues == 15_360,
                "2 foreground facts, 5 tabs, 4 lock states, 3 age states, 4 task states, five Bools")
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
            ProximityRunPolicy.decide($0.inputs).discoveryAdmission != .run
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
            let decision = ProximityRunPolicy.decide(row.inputs)
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
            ProximityRunPolicy.decide(row.inputs).meshLinks != .run
                || row.inputs.continuationTask == .granted
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
        // The right-hand side is spelled from the three FIELDS, never from `demandsTeardown` — that
        // is the policy's own answer, and comparing a decision against it proves only that one
        // expression was evaluated twice.
        let exactly = Self.allRows().allSatisfy { row in
            ProximityRunPolicy.decide(row.inputs).tearsDownSession
                == (row.inputs.isDeletingAllData
                    || row.inputs.chatAgeGate == .below
                    || row.inputs.lockState == .duress)
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

    /// Protected data decides PLAINTEXT, never a radio (D-10.3): flipping it moves no directive
    /// anywhere in the product.
    ///
    /// The gate half of this claim is NOT made here. It used to be, as an `||` arm comparing the two
    /// gate values — an arm that can only fire if the policy stops carrying the leg at all, which
    /// ``theDecisionCarriesTheGateTheAppAlreadyAssembles`` already pins over the whole product and
    /// the matrix re-checks on every row. One claim, one place.
    @Test func protectedDataMovesNoRadioAnywhereInTheProduct() {
        var mismatches: [String] = []
        // R2: bounded by the enumerated product.
        for row in Self.allRows() where row.inputs.isProtectedDataAvailable {
            let twin = Self.inputs(
                phase: row.phase, tab: row.inputs.selectedTab, lock: row.inputs.lockState,
                protectedData: false, age: row.inputs.chatAgeGate,
                deletingAll: row.inputs.isDeletingAllData, task: row.inputs.continuationTask,
                committedPeer: row.inputs.hasCommittedPeer, presence: row.inputs.allowsNearbyPresence,
                recipes: row.inputs.allowsNearbyRecipeShares
            )
            let withData = ProximityRunPolicy.decide(row.inputs)
            let withoutData = ProximityRunPolicy.decide(twin)
            let sameRadios = ProximityRadio.allCases.allSatisfy {
                withData.directive(for: $0) == withoutData.directive(for: $0)
            }
            if !sameRadios {
                mismatches.append("row \(row) available \(withData) unavailable \(withoutData)")
            }
        }
        #expect(mismatches.first == nil, "protected data moved a radio somewhere in the product")
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
            let decision = ProximityRunPolicy.decide(row.inputs)
            return decision.accessGate == MeshRoutedAccessGate(
                protectedDataAvailable: row.inputs.isProtectedDataAvailable,
                appIsForeground: row.phase != .background,
                duressActive: row.inputs.lockState == .duress
            ) && decision.isForeground == decision.accessGate.appIsForeground
        }
        #expect(consistent, "every row carries the app's gate, and one foreground fact only")
    }

    /// Both places that BUILD a `MeshRoutedAccessGate` outside ProximityKit name the same three
    /// facts, measured by CONTAINMENT in a brace-matched body rather than by text proximity.
    ///
    /// The named cell above pins the gate's three VALUES; nothing pinned the app's own construction
    /// site, so `FernletApp.pushRoutedAccessGate` could have gained or lost a leg with the whole
    /// matrix still green. The negative fixture proves the body is really the body: six call sites
    /// of `routedGateForeground(for:` sit in `FernletApp.swift`, and none of them is inside this one.
    @Test func bothGateConstructionSitesNameTheSameThreeFacts() throws {
        let labels = ["protectedDataAvailable:", "appIsForeground:", "duressActive:"]
        let appCode = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletApp.swift"))
        let appBody = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func pushRoutedAccessGate(", in: appCode),
            "the app's gate-push site was renamed, or its brace-matched body does not close"
        )
        let policyCode = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ProximityRunPolicy.swift")
        )
        let policyBody = try #require(
            MeshRoutedSourceScan.bracedBody(after: "static func decide(", in: policyCode),
            "the policy's decide(_:) was renamed, or its brace-matched body does not close"
        )
        let appNamesThem = labels.allSatisfy { appBody.contains($0) }
        let policyNamesThem = labels.allSatisfy { policyBody.contains($0) }
        #expect(appNamesThem, "pushRoutedAccessGate no longer assembles the gate from the three facts")
        #expect(policyNamesThem, "the policy no longer assembles the gate from the same three facts")
        #expect(appBody.contains("applyRoutedAccessGate("), "the push site no longer reaches the door")
        #expect(policyBody.contains("MeshRoutedAccessGate("), "the policy no longer builds a gate here")
        #expect(!appBody.contains("routedGateForeground(for:"),
                "the body matcher is measuring the file rather than the braced body")
    }

    /// An INACTIVE scene is a FOREGROUND scene (P5's post-close correction): Control Center, a call
    /// banner, a system prompt, the app's own Face ID sheet, iPad Split View. It decides exactly as
    /// an active scene does — by construction, since both build one input value — and only the
    /// backgrounded phase differs.
    @Test func anInactiveSceneIsAForegroundScene() {
        let inactive = ProximityRunPolicy.decide(Self.inputs(phase: .inactive, tab: .home))
        let active = ProximityRunPolicy.decide(Self.inputs(phase: .active, tab: .home))
        let background = ProximityRunPolicy.decide(Self.inputs(phase: .background, tab: .home))
        #expect(inactive.isForeground, "an inactive scene is still foreground")
        #expect(inactive == active, "the two foreground phases build one input value and one decision")
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
    /// same cell: a matcher that cannot find the thing it forbids passes vacuously. The count over
    /// `ScenePhase` itself is what closes the gaps a needle list always leaves — `switch phase {`,
    /// `case .inactive`, `== .inactive`, `!= .active` and whatever the next spelling turns out to be
    /// all need the type to be named, and it is named exactly once, as the initialiser's parameter.
    @Test func thePolicyFileHoldsNoRawScenePhaseCompare() throws {
        let path = "App/Fernlet/ProximityRunPolicy.swift"
        let code = Self.collapsed(MeshRoutedSourceScan.codeOnly(try RepoRoot.source(path)))
        #expect(code.contains("FernletApp.routedGateForeground(for: scenePhase)"),
                "the policy still derives its foreground fact through the one mapping")
        #expect(code.components(separatedBy: "ScenePhase").count - 1 == 1,
                "the scene phase enters the policy file once, as the initialiser's parameter")
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
        #expect(Self.collapsed("var p:\nScenePhase").components(separatedBy: "ScenePhase").count - 1 == 1,
                "the type-name count sees a re-wrapped annotation too")
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
