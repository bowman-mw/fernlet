// MeshP7AcceptanceTests.swift
// FernletTests
//
// Network migration **P7's acceptance battery** (plan §13, launcher item 7): one serialized suite
// per §13 clause, each RE-RUNNING that clause end to end under one gated name, so CI can fail the
// phase on this file's own assertions rather than on a list of other suites' names.
//
// **That idiom is mostly RE-STATEMENT, and saying otherwise would be the first dishonest line in a
// file about honesty.** Roughly a dozen of the thirty-five cells here are near-verbatim re-runs of
// a cell the doc comment beside them cites, and each of those says so where it stands. A handful
// do reach a property no unit cell had reached — the whole-product vocabulary pin, the zero wall
// re-measured from this file's own sweep, the yielding founder that arms nothing by hand — and
// those are named as additions rather than left to be inferred from being here.
//
// The shape is `MeshP5AcceptanceTests.swift`'s and `MeshP6AcceptanceTests.swift`'s, deliberately:
// one clause per suite, driven against the same shipping seams the clause ships on. Where an
// exhaustive space already exists it is CITED in the doc comment and the canonical corner of it is
// run here — §11.4's idiom, and the reason a re-run is not a waste: the citation is what says which
// suite holds the whole space, and the corner is what CI can fail on when only this line is gated.
//
// **Six suites**, matching §13's five clauses plus the honesty clause P5 and P6 both earned:
// `MeshP7PolicyMatrixAcceptanceTests` (item 1), `MeshP7GateWriterAcceptanceTests` (item 2),
// `MeshP7RadioSeamAcceptanceTests` (item 3), `MeshP7PollerAcceptanceTests` (item 4),
// `MeshP7ResumeAcceptanceTests` (item 5) and `MeshP7HonestyAcceptanceTests`.
// `CIGateSelectorBoundaryTests` therefore moves its battery pin from 36 to 42.
//
// **Which helpers are REUSED and which are re-stated, named rather than left to be discovered.**
// Reused because they are `internal` in this target: `ProximityRunPolicyTests.inputs(…)` and its
// `scenePhases`; `ProximityRunPolicyHostTests.appSources()`, `proximityKitSources()`,
// `occurrences(of:in:)`, `connectedHost()`, `polledHost(interval:)`, `waitForPolls(_:in:)`,
// `connect(_:to:poll:)`, `pollerRig(createdAt:)`, `sessionConsumerDoor(for:)`, `radioCalls` and
// `byNameExemptions`; `ProximityRunDoorRecorder`, which that suite declares at file scope beside
// itself; `ProximityResumeDecisionTests.allOutcomes()`, `barReasons()`, `kind(for:)`
// and `label(_:)`; `MeshP3Acceptance.install` / `attachSlot(to:fingerprint:)`;
// `CIGateSelectorBoundaryTests.declaredTopLevelTypes()`; `MeshFoundingRig`;
// `MeshRoutedBackpressureAuditCapture` (the audit capture `ProximityRunStateSeamTests` keeps
// `private` to its own file, already promoted once for exactly this reason);
// `MeshRoutedSourceScan.codeOnly` / `bracedBody(after:in:)`; `RepoRoot`; `makeTestStore()`;
// `FakeMeshTransportSession`; `MeshSessionStoreFixtures.save(_:into:install:)`.
// Re-stated MINIMALLY here, because the original is `private` to another suite and widening it
// would move a file this item does not own: the ten-input enumeration
// (`ProximityRunPolicyTests.allRows()` / `boolLeaves(…)`, both `private`) is re-stated as
// ``MeshP7Acceptance/policyRows()``; the 522-row launch-restore product
// (`ProximityResumeDecisionTests.productRows()` / `oracle(_:)` / `row(…)`, all `private` because
// their signatures name a file-scope `private` type) is re-stated as
// ``MeshP7Acceptance/resumeRows()``; and the sealed-launch fixture (`ProximityResumeLaunch`,
// `private` to its file) is re-stated as ``MeshP7ResumeLaunch``.
// **Deliberately NOT reused: `ProximityRunPolicyHostTests.mountRadioCallCount`.** It is `internal`
// and would import cleanly, which is exactly the problem — an acceptance clause that re-makes a
// count from its own sweep and then compares it against the cited suite's own pin stays green
// through a move of the code AND the pin together. The zero-wall cell writes its seven as a
// literal with the decomposition beside it.
//
// **Every audit-counting cell is `@MainActor` and SYNCHRONOUS**, for the reason
// `ProximityRunStateSeamTests`' header gives: `FernletAuditLog`'s registry is process-global and
// suites run in parallel, so what makes a count this cell's own is that a synchronous main-actor
// body cannot suspend — install → drive → assert → uninstall can never interleave with another
// main-actor cell's capture window. One `async` cell in the radio-seam suite would silently break
// every count in it AND in `ProximityRunStateSeamTests`. The poller suite is `async` and counts no
// audit line.
//
// **What this battery does NOT claim is a suite, not a comment**: `MeshP7HonestyAcceptanceTests`.
// And one honesty line has no cell at all because nothing in this process can assert it — **the
// session that wrote this battery compiled nothing.** There is no Swift toolchain on the machine
// that authored it, so every symbol it names was checked by reading a declaration, every `@Test`
// count quoted in `.github/workflows/s3-wall.yml` and in `CIGateSelectorBoundaryTests` is a STATIC
// count of `@Test` declarations in this file, and none of it has been held against a
// `Test run with N tests` line on a Mac. The first green run on a simulator is what turns those
// numbers from arithmetic into a measurement.
//
// **What lives elsewhere, and why.** The two determinism digests keep their one home in
// `MeshP5DeterminismAcceptanceTests` (`:1160` / `:1174`) and this file re-pins neither: P7 touches
// `MeshRoutedScheduleOverlay`, `MeshConvergenceSchedule` and `MeshScheduleEvent` not at all, so
// `ca898bcc…6930` and `594b6f77…5765` are unchanged by construction rather than by assertion, and
// a move would be a red in P5's suite, never a re-pin here. `MeshRoutedDrainTests` stays ungated —
// that is item 6's call and it needs a measured step time on a Mac.

import Foundation
import SwiftUI
import Testing
@testable import FernletCrypto
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshP7Acceptance

/// The two enumerations P7's clauses share, re-stated here because both originals are `private` to
/// the suite that owns them.
@MainActor
enum MeshP7Acceptance {

    /// One row of the policy's ten-input product: the raw `ScenePhase` it was built from, beside the
    /// inputs the policy is handed.
    ///
    /// The phase is carried because `ProximityRunInputs` stores
    /// `FernletApp.routedGateForeground(for:)`'s ANSWER rather than the phase, so `.active` and
    /// `.inactive` build one byte-identical value. Reading `isForeground` back off that value is
    /// what made the first version of `ProximityRunPolicyTests` a tautology.
    struct PolicyRow {

        /// The scene phase this row was built from.
        let phase: ScenePhase

        /// The inputs handed to the policy.
        let inputs: ProximityRunInputs
    }

    /// One row of the launch-restore product: the RAW outcome and bar hit, beside the flattened
    /// inputs the decision takes.
    struct ResumeRow {

        /// The outcome as ProximityKit spells it, or nil for a launch whose restore has not run.
        let outcome: MeshSessionRestoreOutcome?

        /// The reason of a rejoin-bar HIT this run, or nil for no hit.
        let hit: MeshSessionTerminationReason?

        /// `MeshNetworkManager.offersForegroundResume`.
        let offers: Bool

        /// The flattened facts the app-side decision actually reads.
        let inputs: ProximityResumeInputs
    }

    /// Every combination of every policy input, each exactly once, each carrying the phase it was
    /// built from — 3 phases × 5 tabs × 4 lock states × 3 age states × 4 task states × five `Bool`s.
    ///
    /// A minimal re-statement of `ProximityRunPolicyTests.allRows()`, which is `private`. The leaf
    /// is split out for the same reason the original splits it: neither function then nests ten
    /// loops or runs past the 60-line rule.
    ///
    /// - Returns: the full product, in a stable order.
    static func policyRows() -> [PolicyRow] {
        var rows: [PolicyRow] = []
        // R2: bounded by the cases of each input — 23 040 iterations.
        for phase in ProximityRunPolicyTests.scenePhases {
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

    /// The five-`Bool` leaf of the policy product for one fixed combination of the enumerable
    /// inputs.
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
    ) -> [PolicyRow] {
        var leaves: [PolicyRow] = []
        // R2: bounded — 2^5 iterations.
        for protectedData in [false, true] {
            for deletingAll in [false, true] {
                for committedPeer in [false, true] {
                    for presence in [false, true] {
                        for recipes in [false, true] {
                            leaves.append(PolicyRow(phase: phase, inputs: ProximityRunPolicyTests.inputs(
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

    /// The whole launch-restore product: 29 outcome values × 2 offer flags × 9 bar-hit reasons.
    ///
    /// A minimal re-statement of `ProximityResumeDecisionTests.productRows()`, which is `private`
    /// because its signature names a file-scope `private` row type. The two enumerations it walks
    /// (`allOutcomes()`, `barReasons()`) and the flattening it applies (`kind(for:)`) are that
    /// suite's own `internal` members and are reused rather than copied.
    ///
    /// - Returns: every row, enumerated.
    static func resumeRows() -> [ResumeRow] {
        var rows: [ResumeRow] = []
        // R2: bounded by the two enumerations and the two offer flags.
        for outcome in ProximityResumeDecisionTests.allOutcomes() {
            for offers in [false, true] {
                for hit in ProximityResumeDecisionTests.barReasons() {
                    let inputs = ProximityResumeInputs(
                        outcome: ProximityResumeDecisionTests.kind(for: outcome),
                        offersForegroundResume: offers,
                        rejoinBarHit: hit.flatMap { ProximityMeshEndedReason(rawValue: $0.rawValue) }
                    )
                    rows.append(ResumeRow(outcome: outcome, hit: hit, offers: offers, inputs: inputs))
                }
            }
        }
        return rows
    }

    /// The decisions table, written as ordered clauses over the RAW facts — the bar HIT, then the
    /// corrupt file, then the retryable silence, then the offer.
    ///
    /// Independent of the code under test by construction: it never reads the app's flattened
    /// `ProximityRestoreOutcomeKind`, and its "is this retried?" leg is ProximityKit's own
    /// `MeshSessionRestoreOutcome.isRetryable`.
    ///
    /// - Parameter row: One row of the launch-restore product.
    /// - Returns: what the table says that row presents.
    static func resumeOracle(_ row: ResumeRow) -> ProximityResumePresentation {
        if let reason = row.hit, let ended = ProximityMeshEndedReason(rawValue: reason.rawValue) {
            return .ended(ended)
        }
        guard let outcome = row.outcome else { return .nothing }
        if case .quarantineCorruptFile = outcome { return .couldNotReopen }
        if outcome.isRetryable { return .nothing }
        return row.offers ? .offerResume : .nothing
    }
}

/// One launch whose sealed restore has already run, with the host kept alive beside the manager.
///
/// A minimal re-statement of `ProximityResumeDecisionTests`' `ProximityResumeLaunch`, which is
/// `private` to that file. The install binding is `MeshP3Acceptance.install` rather than a fourth
/// pinned identity of its own, so every seal in this battery runs under the identity the routed
/// suites already share; the binding is a task-local, so a suite running beside this one cannot
/// see it.
///
/// The transport is the in-memory fake: every cell here asserts that nothing arms a radio, and a
/// real `MeshMultipeerSession` would start a live advertiser out of a unit test.
@MainActor
private final class MeshP7ResumeLaunch {

    /// The host the manager is `unowned` on.
    let store: FernletStore

    /// The manager, with its one launch restore already taken.
    let manager: MeshNetworkManager

    /// Seals `context` into a fresh, per-test session scope and runs the launch restore over it.
    ///
    /// `_ =` on the binding because the closure YIELDS: `restoreSessionContextOncePerLaunch(now:)`
    /// answers a `Bool`, so a single-expression closure makes `withValue` return one.
    ///
    /// - Parameters:
    ///   - context: The sealed context this launch finds on the disk.
    ///   - now: The instant the restore judges the ceiling against.
    init(sealing context: MeshSessionContext, at now: Date) throws {
        let host = makeTestStore()
        let sessionStore = MeshSessionStore(scope: host.meshSessionStorage)
        try MeshSessionStoreFixtures.save(context, into: sessionStore, install: MeshP3Acceptance.install)
        let restored = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        _ = DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            restored.restoreSessionContextOncePerLaunch(now: now)
        }
        store = host
        manager = restored
    }
}

// MARK: - (a) The policy matrix — item 1

/// **P7 item 1's clause: the ten-input product is decided WHOLE, every row of it, and nothing in
/// the policy is left to a control flow.**
///
/// Cites, rather than re-runs, the independent oracle: `ProximityRunPolicyTests` holds all 23 040
/// rows against the RETIRED shipping conditions (`ContentView.shouldRunPresence`,
/// `shouldListenForRecipeShares`, and the Friends start/stop pair with its committed-peer bail) and
/// pins the one deliberate disagreement at 832 inactive-scene rows. That suite is the only written
/// record of what the app did before the policy owned it, and this battery does not copy it.
///
/// What this clause adds is the WHOLENESS claim stated positively — every row decides, the
/// vocabulary is exhausted rather than defaulted to, and nothing is deferred — plus §13's
/// load-bearing rows with LITERAL expectations and no reference to any oracle, so a regression
/// names itself.
@MainActor
@Suite(.serialized)
struct MeshP7PolicyMatrixAcceptanceTests {

    /// **The artefact: the product is enumerated whole, and no row is left undecided.**
    ///
    /// **This cell is a SUBSTITUTION, and says so.** The item-7 row asked for `deferred` to be shown
    /// EMPTY as a positive claim. There is no `deferred` to show: the decision vocabulary is
    /// `ProximityRunState`, whose three cases are `.run`, `.foregroundOnly` and `.stop`, and no
    /// other type on the policy's answer side carries such a case either. An empty-`deferred`
    /// assertion could therefore only be written by first inventing the case it claims is unused,
    /// which is a test of this file rather than of the policy.
    ///
    /// What is asserted instead is the property the absent case was standing in for: DEFAULTING.
    /// "Undecided" is not a case `ProximityRunState` has, so the claim that can actually fail is
    /// that a policy answering one directive everywhere would agree with every containment check
    /// and still be wrong. So the observed vocabulary is pinned per radio — three answers for the
    /// mesh links, exactly two for the admission door (invariant 5 forbids the third), and two each
    /// for the listeners — beside the row count and the distinct-value count the collapse of the two
    /// foreground phases produces. An empty set and a one-element set both fail it, which is the
    /// half an "is `deferred` empty?" question would have answered.
    @Test func theTenInputProductIsEnumeratedWholeAndNoRowIsLeftUndecided() {
        let rows = MeshP7Acceptance.policyRows()
        #expect(rows.count == 23_040,
                "3 phases, 5 tabs, 4 lock states, 3 age states, 4 task states, five Bools")
        #expect(Set(rows.map(\.inputs)).count == 15_360,
                "the two foreground phases build ONE input value, and that is the only collapse")
        #expect(ProximityRadio.allCases.count == 4, "four radios, and every row answers for all four")
        var seen: [ProximityRadio: Set<ProximityRunState>] = [:]
        // R2: bounded by the enumerated product × the four radios.
        for row in rows {
            let decision = ProximityRunPolicy.decide(row.inputs)
            for radio in ProximityRadio.allCases {
                seen[radio, default: []].insert(decision.directive(for: radio))
            }
        }
        let neverRun = Set<ProximityRunState>([.foregroundOnly, .stop])
        let whole = Set(ProximityRunState.allCases)
        #expect((seen[.meshLinks] ?? []) == whole,
                "the mesh links reach all three answers, so no row of the product defaulted")
        #expect((seen[.discoveryAdmission] ?? []) == neverRun,
                "invariant 5: the admission door reaches two of the three and never run")
        #expect((seen[.presence] ?? []) == neverRun, "presence is never directed to run")
        #expect((seen[.recipeShare] ?? []) == neverRun, "nor is the recipe listener")
    }

    /// **§13's continuation-task rows, literal.** A granted task over a committed peer runs the mesh
    /// through the background; a refused, expired or inert one drops it to `foregroundOnly`; and
    /// the admission door stays `foregroundOnly` in both phases whatever the mesh is doing.
    @Test func theContinuationTaskRowsAreLiteralAndOnlyGrantedEverRunsTheMesh() {
        let granted = ProximityRunPolicy.decide(
            ProximityRunPolicyTests.inputs(phase: .background, task: .granted, committedPeer: true)
        )
        #expect(granted.meshLinks == .run, "user-started mesh + CPT granted ⇒ mesh run in background")
        #expect(granted.isUp(.meshLinks), "and the run directive resolves UP once backgrounded")
        #expect(granted.discoveryAdmission == .foregroundOnly,
                "invariant 5: admitting a NEW peer stays a foreground act beside a continued mesh")
        #expect(!granted.isUp(.discoveryAdmission), "so the door resolves down in the same breath")
        #expect(!granted.isUp(.presence), "presence does not follow the mesh into the background")
        #expect(!granted.isUp(.recipeShare), "and the recipe listener does not either")
        #expect(!granted.tearsDownSession, "background continuation is not a teardown")
        // R2: bounded by the three non-granted cases.
        for task in [ProximityContinuationTaskState.refused, .expired, .inert] {
            let background = ProximityRunPolicy.decide(
                ProximityRunPolicyTests.inputs(phase: .background, task: task)
            )
            #expect(background.meshLinks == .foregroundOnly,
                    "without a granted task the mesh is a foreground affair — §13's refused row")
            #expect(!background.isUp(.meshLinks), "so it resolves down once the app is backgrounded")
        }
        let peerless = ProximityRunPolicy.decide(
            ProximityRunPolicyTests.inputs(phase: .background, task: .granted, committedPeer: false)
        )
        #expect(peerless.meshLinks != .run,
                "hasCommittedPeer is the radio guard: a mesh with nobody in it earns no run")
    }

    /// **§13's three dominating inputs, literal**: delete-all, a final below-age verdict and a
    /// duress session each stop every radio and raise the teardown flag — over a GRANTED task, so
    /// the domination is shown to outrank the one input that could have run the mesh.
    ///
    /// The right-hand side of the whole-product claim is spelled from the three FIELDS, never from
    /// `ProximityRunInputs.demandsTeardown`: that is the policy's own answer, and comparing a
    /// decision against it proves only that one expression was evaluated twice.
    @Test func theThreeDominatingInputsStopEveryRadioAndTearTheSessionDown() {
        let rows = [
            ProximityRunPolicyTests.inputs(deletingAll: true, task: .granted),
            ProximityRunPolicyTests.inputs(age: .below, task: .granted),
            ProximityRunPolicyTests.inputs(lock: .duress, task: .granted)
        ]
        // R2: bounded by the three dominating inputs.
        for row in rows {
            let decision = ProximityRunPolicy.decide(row)
            #expect(decision.tearsDownSession, "a dominating input tears the session down")
            let allStopped = ProximityRadio.allCases.allSatisfy {
                decision.directive(for: $0) == .stop && !decision.isUp($0)
            }
            #expect(allStopped, "and stops every radio, granted continuation task or not")
        }
        let exactly = MeshP7Acceptance.policyRows().allSatisfy { row in
            ProximityRunPolicy.decide(row.inputs).tearsDownSession
                == (row.inputs.isDeletingAllData
                    || row.inputs.chatAgeGate == .below
                    || row.inputs.lockState == .duress)
        }
        #expect(exactly, "exactly the three dominating inputs tear down, and nothing else does")
    }

    /// **An INACTIVE scene is a FOREGROUND scene** (P5's post-close correction), at every radio and
    /// over the whole product.
    ///
    /// Control Center, the notification shade, the app switcher, a call banner, a system prompt, the
    /// app's own Face ID sheet and iPad Split View are all states where the device is unlocked, the
    /// user is present and the process is live. The strong form is the one asserted: the two
    /// foreground phases build one input value, so they cannot decide differently — and the whole
    /// product is checked for a row that resolved a directive against anything but
    /// `phase != .background`.
    @Test func anInactiveSceneIsAForegroundSceneAtEveryRadio() {
        let inactive = ProximityRunPolicy.decide(
            ProximityRunPolicyTests.inputs(phase: .inactive, tab: .home)
        )
        let active = ProximityRunPolicy.decide(ProximityRunPolicyTests.inputs(phase: .active, tab: .home))
        let background = ProximityRunPolicy.decide(
            ProximityRunPolicyTests.inputs(phase: .background, tab: .home)
        )
        #expect(inactive.isForeground, "an inactive scene is still foreground")
        #expect(inactive == active, "the two foreground phases build one input value and one decision")
        #expect(inactive != background, "and only the backgrounded phase decides differently")
        #expect(inactive.isUp(.presence),
                "so presence survives a Control Center pull rather than bouncing with it")
        let oneForegroundFact = MeshP7Acceptance.policyRows().allSatisfy { row in
            ProximityRunPolicy.decide(row.inputs).isForeground == (row.phase != .background)
        }
        #expect(oneForegroundFact, """
            a row resolved its directives against something other than \
            `FernletApp.routedGateForeground(for:)`'s answer, which is the one foreground fact
            """)
    }

    /// **The gate is CARRIED, never interpreted** (D-10.3): the decision hands on exactly the value
    /// the app used to assemble at its six push sites, and the policy never asks it anything.
    ///
    /// Two halves. The behavioural half runs the whole product: every row's `accessGate` is the
    /// three facts spelled from the RAW phase, and the decision's own `isForeground` never drifts
    /// from the gate's `appIsForeground` leg. The source half is the boundary: "may we decrypt" has
    /// exactly one owner and it is not this type, so the policy file must spell neither `isOpen` nor
    /// `permits(` — each needle fixtured against a planted line, because a matcher that cannot find
    /// the thing it forbids passes vacuously.
    @Test func theGateIsCarriedThroughUntouchedAndNeverInterpreted() throws {
        let carried = MeshP7Acceptance.policyRows().allSatisfy { row in
            let decision = ProximityRunPolicy.decide(row.inputs)
            return decision.accessGate == MeshRoutedAccessGate(
                protectedDataAvailable: row.inputs.isProtectedDataAvailable,
                appIsForeground: row.phase != .background,
                duressActive: row.inputs.lockState == .duress
            ) && decision.isForeground == decision.accessGate.appIsForeground
        }
        #expect(carried, "a row carries a gate that is not the app's own three facts, unchanged")
        let code = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ProximityRunPolicy.swift")
        )
        #expect(code.components(separatedBy: "MeshRoutedAccessGate(").count - 1 == 1,
                "the policy file builds exactly one gate, and P7 item 2 made it the only one in App/")
        #expect(!code.contains("isOpen"),
                "the policy reads the gate's own verdict, so it is deciding plaintext (D-10.3)")
        #expect(!code.contains("permits("),
                "the policy asks the gate what it permits, which is ProximityKit's question")
        let planted = "if gate.isOpen && gate.permits(.meshRoutedItem) { }"
        #expect(planted.contains("isOpen") && planted.contains("permits("),
                "both needles match what they forbid, so the two zeroes above are not vacuous")
    }
}

// MARK: - (b) The gate's single writer — item 2

/// **P7 item 2's clause: the routed access gate has ONE writer in the app target, the policy is the
/// one thing consulted, and the six edges that used to assemble a gate each survive as an edge.**
///
/// Cites `ProximityRunPolicyHostTests.theRoutedAccessGateHasExactlyOneWriterInTheAppTarget()`,
/// `theOneWriterCarriesTheGateThePolicyDecided()` and `theRetiredSixSiteGatePushIsGone()` for the
/// containment and zero-list halves. What this clause runs is the count made again from this
/// battery's own sweep — so gating this suite fails on its own evidence — plus the six edges driven
/// END TO END through an injected door, each against a gate literal derived by hand from the gate's
/// three rules rather than from `ProximityRunPolicy.decide(_:)`'s answer.
@MainActor
@Suite(.serialized)
struct MeshP7GateWriterAcceptanceTests {

    /// **One `applyRoutedAccessGate(` and one `ProximityRunPolicy.decide(` in the whole app
    /// target**, counted as OCCURRENCES and not as a file list.
    ///
    /// The file list on its own is not the claim: a second write added inside `FernletApp.swift`
    /// keeps that list at one element while the single writer is already gone, and that is the
    /// cheapest way to lose it. Non-vacuity first, because a sweep handed a wrong root enumerates
    /// nothing and passes green.
    @Test func theAppTargetHoldsOneGateWriterAndOneDecideCall() throws {
        let sources = try ProximityRunPolicyHostTests.appSources()
        #expect(!sources.isEmpty, "the App/ sweep found no Swift files at all")
        #expect(sources.contains(where: { $0.name == "FernletApp.swift" }),
                "the sweep no longer reaches the launch mount, so every count below is vacuous")
        #expect(sources.contains(where: { $0.name == "ProximityRunPolicyHost.swift" }),
                "nor the host, which is the other file that could grow one")
        var writers: [String] = []
        var deciders: [String] = []
        var writes = 0
        var decides = 0
        // R2: two needles over the app target's own file list.
        for source in sources {
            let wrote = ProximityRunPolicyHostTests.occurrences(
                of: "applyRoutedAccessGate(", in: source.code
            )
            let decided = ProximityRunPolicyHostTests.occurrences(
                of: "ProximityRunPolicy.decide(", in: source.code
            )
            writes += wrote
            decides += decided
            if wrote > 0 { writers.append(source.name) }
            if decided > 0 { deciders.append(source.name) }
        }
        #expect(writers == ["FernletApp.swift"], "the gate has exactly one writing FILE")
        #expect(writes == 1, "and exactly one call site inside it")
        #expect(deciders == ["ProximityRunPolicyHost.swift"], "the policy is consulted in one file")
        #expect(decides == 1, "and from exactly one call site inside it")
    }

    /// **The six edges the retired push sites became, each driven and each writing its OWN leg.**
    ///
    /// P5 item 10 found four of the six sites comparing `== .active` while the scene handler fell
    /// only on `.background`, so the stored answer for one physical state depended on which event
    /// pushed last. The assembly is now one place; the EDGES survive because a fact that moves at a
    /// scene transition, at a protected-data notification and at the duress `.onChange` each needs
    /// its own observer, and the duress one moves at neither of the other two transitions.
    ///
    /// Every `expected` is hand-derived from the gate's three rules against a host that starts
    /// fail-closed (`.background`, protected data false, lock `.locked`) — never
    /// `ProximityRunPolicy.decide(_:)` re-computed over the host's own inputs, which would restate
    /// the host's arithmetic back to it and could not fail.
    @Test func theSixEdgesEachWriteTheGateTheyOwnAndNoOther() throws {
        let (host, recorder) = ProximityRunPolicyHostTests.connectedHost()
        host.setScenePhase(.active)
        host.setProtectedDataAvailable(true)
        host.setAppLockState(.duress)
        host.setAppLockState(.unlocked)
        host.setProtectedDataAvailable(false)
        host.setScenePhase(.background)
        #expect(recorder.gates.count == 6, "six edges, six writes — each setter re-decides exactly once")
        let expected = [
            MeshRoutedAccessGate(protectedDataAvailable: false, appIsForeground: true, duressActive: false),
            MeshRoutedAccessGate(protectedDataAvailable: true, appIsForeground: true, duressActive: false),
            MeshRoutedAccessGate(protectedDataAvailable: true, appIsForeground: true, duressActive: true),
            MeshRoutedAccessGate(protectedDataAvailable: true, appIsForeground: true, duressActive: false),
            MeshRoutedAccessGate(protectedDataAvailable: false, appIsForeground: true, duressActive: false),
            MeshRoutedAccessGate(protectedDataAvailable: false, appIsForeground: false, duressActive: false)
        ]
        #expect(recorder.gates == expected, """
            an edge moved a leg it does not own — the duress edge is the one that must move at \
            neither a scene nor a protected-data transition
            """)
        let first = try #require(recorder.gates.first, "the first edge wrote nothing")
        #expect(first.appIsForeground, "the scene edge raises the foreground fact on its own")
        #expect(!first.protectedDataAvailable, "and leaves the fail-closed data leg exactly as it was")
    }

    /// **The mount installs the doors and pushes BEFORE the launch restore runs** (plan §24.1), and
    /// it is one `.onAppear` closure rather than two observers that could reorder.
    ///
    /// The order is the wiring decision: the gate says what may be DECRYPTED, and
    /// `restoreSessionContextOncePerLaunch(now:)` reads a sealed file — so the restore must run
    /// against a gate this launch has already pushed, not the fail-closed seed. Asserted by INDEX
    /// over the comment-stripped file, with each call counted at exactly one so the comparison is
    /// between the two calls that exist rather than between two of several.
    @Test func theLaunchMountInstallsTheDoorsBeforeTheRestoreRuns() throws {
        let app = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletApp.swift"))
        #expect(ProximityRunPolicyHostTests.occurrences(of: "mountRoutedRunPolicy(store)", in: app) == 1,
                "the mount is called from exactly one place")
        #expect(ProximityRunPolicyHostTests.occurrences(
            of: "restoreMeshSessionContextIfNeeded(store)", in: app
        ) == 1, "and so is the launch restore")
        let mountCall = try #require(app.range(of: "mountRoutedRunPolicy(store)"),
                                     "the mount call was renamed, so the order below is unmeasured")
        let restoreCall = try #require(app.range(of: "restoreMeshSessionContextIfNeeded(store)"),
                                       "the restore call was renamed, so the order below is unmeasured")
        #expect(mountCall.lowerBound < restoreCall.lowerBound, """
            the sealed session context is restored BEFORE the run policy has pushed a gate, so the \
            restore judges a launch against the fail-closed seed rather than this launch's facts
            """)
        let mount = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func mountRoutedRunPolicy(", in: app),
            "the launch mount was renamed, or its brace-matched body does not close"
        )
        #expect(!mount.contains("private func restoreMeshSessionContextIfNeeded"),
                "the body matcher is measuring the file rather than the brace-matched mount")
        #expect(mount.contains("runPolicyHost.connect("), "the mount no longer installs the doors")
        #expect(mount.contains("runPolicyHost.pushNow()"), "and no longer makes the launch push")
        #expect(!mount.contains("MeshRoutedAccessGate("),
                "the door assembles a gate of its own, so the policy is not the single writer")
    }

    /// **Nothing is written before the doors are installed** — the latch each of the six retired
    /// push sites used to carry for itself (`if case .ready(let store) = loader.phase`), held in one
    /// place.
    ///
    /// Every leg set before `connect(…)` is RECORDED and nothing else; the launch is then one
    /// explicit push rather than one per leg. The second half is what makes that a claim about
    /// state and not about silence: the push that follows carries the legs seeded before it.
    @Test func nothingIsWrittenBeforeTheDoorsAreInstalled() throws {
        let host = ProximityRunPolicyHost()
        host.setScenePhase(.active)
        host.setProtectedDataAvailable(true)
        host.setAppLockState(.unlocked)
        let recorder = ProximityRunDoorRecorder()
        ProximityRunPolicyHostTests.connect(host, to: recorder)
        #expect(recorder.gates.isEmpty, "connecting pushes nothing on its own")
        #expect(recorder.everyRadioDirective.isEmpty, "and moves no radio")
        host.pushNow()
        #expect(recorder.gates.count == 1, "the launch is ONE push, not one per leg")
        let gate = try #require(recorder.gates.last, "the launch push wrote nothing")
        #expect(gate == MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        ), "and it carries the legs seeded before the doors existed, not the fail-closed seed")
    }
}

// MARK: - (c) The radios' seams — item 3

/// **P7 item 3's clause: each manager has one `apply(_:)` door, every row of the mesh door's table
/// is driven to its verdict on a BARE manager over a fake transport, and the app target names a
/// radio nowhere but the mount.**
///
/// Cites `ProximityRunStateSeamTests` for the exhaustive space — the vocabulary, the resolver, the
/// give-up clock's two halves, the `.resume` row and its refusal, the `.none` row and the
/// refusal-dedupe. What this clause runs is the five verdicts §13 is actually about, end to end,
/// plus the zero wall's counts.
///
/// **Every cell here is `@MainActor` and SYNCHRONOUS.** `FernletAuditLog`'s registry is
/// process-global and suites run in parallel, so what makes each count this cell's own is that a
/// synchronous main-actor body cannot suspend: install → drive → assert → uninstall can never
/// interleave with another main-actor cell's capture window. Adding one `async` cell to this suite
/// would silently break every count in it and in `ProximityRunStateSeamTests` alike. The second
/// fact the counts rest on is that `mesh.runState.*` has exactly three emitters in the build and no
/// shipping caller reachable from a unit-test process, which mounts no scene.
@MainActor
@Suite(.serialized)
struct MeshP7RadioSeamAcceptanceTests {

    /// **A `run` arms the friend radios once**, and the second push is a silent no-op.
    ///
    /// Idempotence is `isSearching`'s, exactly as the retired `ContentView.startFriendsDiscovery()`'s
    /// bail was — a second `startJoin()` re-mints the radio's Bonjour name mid-run. `applied` is a
    /// CHANGE line, so the second push says nothing, which is what lets the host push on every leg
    /// setter without a second opinion about edges.
    @Test func aRunArmsTheFriendRadiosOnceAndASecondPushIsSilent() {
        let audit = MeshRoutedBackpressureAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`, so an
        // inline `makeTestStore()` would die at the end of the expression that built the manager.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }
        #expect(!manager.isSearching, "a bare manager starts with its radios down")

        manager.applyRunState(links: .run, discovery: .run)
        #expect(manager.isSearching, "a discovery run arms the radios")
        #expect(manager.isProximityJoin, "through startJoin(), so a discovered peer is invited")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1, "and the change is named once")

        manager.applyRunState(links: .run, discovery: .run)
        #expect(manager.isSearching, "the second push leaves the radios exactly as they were")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1,
                "and emits nothing: `applied` is a CHANGE line, not a receipt for every call")
    }

    /// **A `stop` with NO committed peer stands the radios down**, and refuses nothing.
    ///
    /// The only row of the mesh door's table in which `stopJoin()` runs at all — the whole of the
    /// retired `ContentView.stopFriendsDiscovery()` when its `hasCommittedPeer` guard passed.
    @Test func aStopWithNoCommittedPeerStandsTheRadiosDown() {
        let audit = MeshRoutedBackpressureAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())

        manager.applyRunState(links: .run, discovery: .run)
        #expect(manager.isSearching, "armed, so there is something to stand down")
        #expect(!manager.hasCommittedPeer, "with nobody committed, which is what lets the stop through")

        manager.applyRunState(links: .stop, discovery: .stop)
        #expect(!manager.isSearching, "the radios are down")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 2,
                "one line for the arm and one for the stand-down, and neither for a no-op")
        #expect(audit.count(of: ProximityRunStateSeam.held) == 0, "and nothing was refused")
    }

    /// **The trap: a links `stop` over a COMMITTED peer tears nothing down.**
    ///
    /// `stopJoin()` runs `stopSearching()`, which empties `slots`, drops `slotTrustPolicies`,
    /// cancels every slot coordinator and runs `clearGroupKeyState()` — so running it here would be
    /// ending a live session rather than standing radios down. Being backgrounded or leaving the tab
    /// is the OS suspending the links; the session survives as `.linksLost` → partition → restore.
    /// The guard is `hasCommittedPeer`, never `isSessionLive` and never `isInSession` — P6 item 2's
    /// pass-B P1 is what confusing the three cost.
    @Test func aStopOverACommittedPeerTearsNothingDown() {
        let audit = MeshRoutedBackpressureAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }

        manager.applyRunState(links: .run, discovery: .run)
        MeshP3Acceptance.attachSlot(to: manager, fingerprint: "00000000000000a7")
        #expect(manager.hasCommittedPeer, "a peer is committed right now")
        #expect(manager.isSessionLive, "so the session is live")
        let fingerprints = manager.slots.compactMap(\.fingerprint)

        manager.applyRunState(links: .stop, discovery: .stop)

        #expect(manager.hasCommittedPeer, "the committed peer survives the stand-down request")
        #expect(manager.isSessionLive, "and so does the session — a stop is not a teardown")
        #expect(manager.slots.compactMap(\.fingerprint) == fingerprints, "the slots are intact")
        #expect(manager.isSearching, "and the radios were never stood down, because that IS the teardown")
        #expect(audit.values(of: ProximityRunStateSeam.held, key: "reason")
                == [ProximityRunStateSeam.committedPeer],
                "and the refusal names the predicate it bailed on, once")
    }

    /// **The P8-only pair — links `run`, discovery `stop` — moves nothing and names itself.**
    ///
    /// A mesh continued in the background whose admission door should be shut needs a primitive that
    /// stops browsing and advertising while KEEPING the committed links. There is none:
    /// `stopSearching()` is the only stand-down there is and it takes the slots and the group key
    /// with it. Inventing that primitive is P8's work; until then the safe answer is to move
    /// nothing, and the audit token is how the claim stays visible rather than becoming a silence.
    @Test func theP8OnlyPairMovesNothingAndNamesItself() {
        let audit = MeshRoutedBackpressureAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }

        manager.applyRunState(links: .run, discovery: .run)
        #expect(manager.isSearching, "the radios are up")

        manager.applyRunState(links: .run, discovery: .stop)

        #expect(manager.isSearching, "and stay up: nothing can shut the admission door on its own")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1,
                "nothing changed, so nothing is claimed")
        #expect(audit.values(of: ProximityRunStateSeam.held, key: "reason")
                == [ProximityRunStateSeam.noStandAloneDiscoveryStop],
                "the combination names itself rather than being silently rounded to a stop")
    }

    /// **An UNANSWERED launch-restore offer holds the fresh search** (item 5, pass 2).
    ///
    /// The collision is what makes the whole resume affordance reachable: the policy's discovery
    /// directive is `foregroundOnly` on the Friends tab, so the first visit after a relaunch pushes
    /// `run`, `armFriendRadios()` resolves `.fresh` (nothing is adopted yet), and `startJoin()` ends
    /// in `resetSessionStateMachine(keepingTerminalState: false)` — which clears
    /// `offersForegroundResume`, `restoredSessionContext` and the ceiling. The offer would be gone
    /// before the card could be drawn, and the sentence it shows ("It isn't looking for anyone until
    /// you say so") would be false at the instant it appeared. Bounded by the ANSWER, not a timer.
    @Test func anUnansweredResumeOfferHoldsTheFreshSearch() {
        let audit = MeshRoutedBackpressureAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }
        manager.applySessionEvent(.contextRestored(.resumable))
        #expect(manager.offersForegroundResume, "the restore raised the offer")
        #expect(!manager.isInSession, "and adopted nothing, so the three-way reads `.fresh`")

        manager.applyRunState(links: .run, discovery: .run)

        #expect(!manager.isSearching,
                "a fresh search would have wiped the offer before the card could be drawn")
        #expect(audit.values(of: ProximityRunStateSeam.held, key: "reason")
                == [ProximityRunStateSeam.resumeOffered],
                "and the hold has a name rather than being the door's one silent row")

        manager.declineForegroundResume()
        manager.applyRunState(links: .run, discovery: .run)
        #expect(manager.isSearching, "once the offer is ANSWERED the ordinary fresh search arms")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 1, "and says so exactly once")
    }

    /// **The two listener seams stand their radio down once and are idempotent.**
    ///
    /// Driven from the RUNNING side, because `PresenceManager.start()` brings up a real
    /// `MCNearbyServiceAdvertiser` and `ProximityRecipeShareManager.start()` a real browser, which a
    /// unit test must never do. `stop` is also the direction shipping actually takes — at
    /// consent-off, at a wipe and on the way to background — and all three of those were re-aimed at
    /// the policy by item 3's pass B. Said out loud rather than skipped: the missing half is
    /// `start()` itself, unchanged by P7.
    @Test func thePresenceAndRecipeSeamsStandDownOnceAndAreIdempotent() {
        let audit = MeshRoutedBackpressureAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let store = makeTestStore()
        let presence = store.presenceManager
        let recipe = store.recipeShareManager
        presence.activateForTesting()
        recipe.markRunningForTesting()
        #expect(presence.isRunning, "the presence radio is up (without a real advertiser)")
        #expect(recipe.isRunningForTesting, "and the recipe listener too (without a real browser)")

        presence.applyRunState(.stop)
        recipe.applyRunState(.stop)
        #expect(!presence.isRunning, "the presence seam stands its radio down")
        #expect(!recipe.isRunningForTesting, "and the recipe seam stands its listener down")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 2, "one change line each")

        presence.applyRunState(.stop)
        recipe.applyRunState(.stop)
        #expect(!presence.isRunning, "a second stop changes nothing")
        #expect(!recipe.isRunningForTesting, "at either seam")
        #expect(audit.count(of: ProximityRunStateSeam.applied) == 2, "and says nothing")
        #expect(store.presenceManager === presence, """
            one store, one presence radio — and the store is read here so it is held for the pair's \
            whole life, because both managers hold their `ProximityHost` unowned (rule ML5)
            """)
    }

    /// **The zero wall's counts: the app target names a radio only inside the mount's doors.**
    ///
    /// `ProximityRunPolicyHostTests.theProximityRadiosAreDrivenOnlyFromTheHostsDoors()` and
    /// `everySurvivingRadioCallSitsInsideTheMountsDoors()` are the wall; this is the acceptance
    /// clause re-making the count from its own sweep, so gating this suite fails on its own
    /// evidence. Two files are exempt BY NAME — the `#if DEBUG` rejection-matrix harness and the
    /// active-share sheet — and each exemption is shown to be IN the sweep, because an exemption
    /// that matches nothing is a hole nobody can see. The exemption set is checked NON-EMPTY first,
    /// because `allSatisfy` over an empty set is true and would report a swept exemption list that
    /// does not exist.
    ///
    /// **The expected seven is a LITERAL, not `ProximityRunPolicyHostTests.mountRadioCallCount`.**
    /// That constant is `internal` and would import cleanly, and importing it would undo the whole
    /// point of re-measuring: a change that moved the code and that suite's pin together would pass
    /// here in silence. MEASURED over the comment-stripped `App/Fernlet/FernletApp.swift` at this
    /// commit: `stopJoin()` 1, `leaveSession()` 1, `presenceManager.stop()` 1 and
    /// `recipeShareManager.stop()` 1 — the teardown door — plus `applyRunState(` 3, being the mesh
    /// pair, presence and the recipe listener. 1 + 1 + 1 + 1 + 3 = 7. The two suites agreeing on
    /// seven by two independent routes is the claim; the day they disagree, one of them is right.
    @Test func theZeroWallStillCountsEveryRadioCallInsideTheMount() throws {
        let sources = try ProximityRunPolicyHostTests.appSources()
        #expect(!sources.isEmpty, "the App/ sweep found no Swift files at all")
        #expect(sources.contains(where: { $0.name == "ContentView.swift" }),
                "the sweep no longer reaches the view the retirement is ABOUT")
        #expect(sources.contains(where: { $0.name == "FernletStore.swift" }),
                "nor the store that reached around it at three more sites")
        let exemptions = ProximityRunPolicyHostTests.byNameExemptions
        #expect(!exemptions.isEmpty, "an empty exemption list makes the sweep check below vacuous")
        let exemptionsAreSwept = exemptions.allSatisfy { name in
            sources.contains(where: { $0.name == name })
        }
        #expect(exemptionsAreSwept, "an exempted file is not in the sweep at all, so it excuses nothing")
        var strays: [String] = []
        var inFernletApp = 0
        // R2: the needle list over the app target's own file list.
        for source in sources where !exemptions.contains(source.name) {
            for needle in ProximityRunPolicyHostTests.radioCalls {
                let hits = ProximityRunPolicyHostTests.occurrences(of: needle, in: source.code)
                guard hits > 0 else { continue }
                if source.name == "FernletApp.swift" {
                    inFernletApp += hits
                } else {
                    strays.append("\(source.name) spells \(needle) \(hits)×")
                }
            }
        }
        // `Issue.record` rather than an interpolated `#expect` comment (house rule: literal
        // comments only). A stray that names only the NEEDLE — which is all the first version of
        // this cell reported — is a red nobody can act on without re-running the sweep by hand.
        if !strays.isEmpty {
            Issue.record("""
                a proximity radio is driven from outside the run policy's doors — \
                \(strays.joined(separator: "; "))
                """)
        }
        #expect(strays.isEmpty, "a proximity radio is driven from outside the run policy's doors")
        #expect(inFernletApp == 7, """
            the mount's doors hold seven radio calls — stopJoin(), leaveSession(), \
            presenceManager.stop() and recipeShareManager.stop() once each, plus applyRunState( \
            three times — and FernletApp no longer spells exactly that many
            """)
    }
}

// MARK: - (d) The poller and its three consumers — item 4

/// **P7 item 4's clause: ONE timer, armed and cancelled by session liveness alone, and each of the
/// three consumers that have been waiting since P3 driven to its verdict through a tick.**
///
/// Cites `ProximityRunPolicyHostTests` for the wall half — the three consumers spelled exactly once
/// in the app target, inside the mount's brace-matched body, in the decided order, with no new
/// caller inside ProximityKit. What this clause runs is the behaviour: the handle's four edges, the
/// no-stacking property over a REAL millisecond arm, and the three verdicts.
///
/// **The headline is the yielding founder** (plan §12.3 finding 3). P6 item 2's founding change
/// left the half of every symmetric pair that YIELDS with a mesh and no ceiling until item 4
/// existed; that cell arms nothing by hand and lets the election decide which half yields.
@MainActor
@Suite(.serialized)
struct MeshP7PollerAcceptanceTests {

    /// **Nothing exists until a session is live, and the FALL leaves nothing behind.**
    ///
    /// `isPollerArmed` rather than a tick count, because "nothing may spin" is a claim about the
    /// task not EXISTING: a cancelled task and an absent one tick equally little and only one of
    /// them is what this host promises. Arming is not a push, which is what tells the liveness leg
    /// apart from the ten policy legs at a glance.
    @Test func thePollerIsNilUntilASessionIsLiveAndCancelledWhenTheLegFalls() {
        let (host, recorder) = ProximityRunPolicyHostTests.connectedHost()
        #expect(!host.isPollerArmed, "with the liveness leg false there is no task at all")
        host.setSessionLive(true)
        #expect(host.isPollerArmed, "the liveness RISE arms the one timer this host owns")
        #expect(recorder.polls.isEmpty, "arming is not a tick")
        #expect(recorder.gates.isEmpty,
                "the liveness leg is the poller's switch, not a policy input — it must push nothing")
        #expect(recorder.everyRadioDirective.isEmpty, "and move no radio")
        host.setSessionLive(false)
        #expect(!host.isPollerArmed, "the FALL cancels the handle and nils it")
        host.setSessionLive(true)
        host.setSessionLive(true)
        #expect(host.isPollerArmed, "a second rise arms again, and a repeated true is the same timer")
        host.setSessionLive(false)
        #expect(!host.isPollerArmed, "and the last fall leaves nothing behind")
    }

    /// **The real arm, exercised: a self-re-arming ONE-SHOT that never stacks a second timer.**
    ///
    /// The cells that drive `pollNow(at:)` prove what a tick DOES and nothing about whether one ever
    /// happens; this awaits the timer itself with an injected millisecond interval. The gap
    /// assertion is the "exactly one timer" claim made observable: one self-re-arming one-shot can
    /// never produce two ticks inside one interval, while a second stacked timer produces a gap near
    /// zero. Half the interval is the threshold, which leaves a 2× margin for a loaded scheduler —
    /// and a loaded scheduler makes ticks LATER, never sooner.
    @Test func theArmedPollerTicksAndNeverStacksASecondTimer() async {
        let interval: TimeInterval = 0.05
        let (host, recorder) = ProximityRunPolicyHostTests.polledHost(interval: interval)
        host.setSessionLive(true)
        host.setSessionLive(false)
        host.setSessionLive(true)
        host.setSessionLive(true)
        await ProximityRunPolicyHostTests.waitForPolls(3, in: recorder)
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

    /// **Consumer 1: an elapsed ceiling ENDS the mesh, in one tick.**
    ///
    /// The rig is founded six hours and an hour ago against the REAL clock, because the SIGNED bound
    /// is what a tick with `monotonicElapsed: nil` judges — the monotonic origin was armed seconds
    /// ago. What is claimed is the LOCAL ending: the rig's roster is three and
    /// `MeshDevelopmentPlan.permitsTermination(_:)` refuses to sign a `terminated.v1` above a final
    /// pair, so the announcement half is refused here and is `MeshSessionLifecycleManagerTests`'
    /// subject. `enforceSessionCeiling` ends local participation either way.
    @Test func oneTickEndsAMeshWhoseCeilingHasElapsed() async throws {
        let elapsed = MeshSessionCeiling.ceilingSeconds + 3_600
        let rig = try ProximityRunPolicyHostTests.pollerRig(
            createdAt: Date().addingTimeInterval(-elapsed)
        )
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

    /// **Consumer 3: a mesh that can reach nobody is PARTITIONED by the tick's third call.**
    ///
    /// A roster of three that can reach only itself is a partition of one. The cell also pins the
    /// coupling the order exists for: the partition call is what ARMS the thirty-minute window the
    /// idle-lapse call reads, so running it first would let one tick both arm a window and judge it.
    @Test func oneTickPartitionsALiveMeshThatCanReachNobody() async throws {
        let rig = try ProximityRunPolicyHostTests.pollerRig(createdAt: Date())
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
        #expect(rig.manager.isSessionLive, "while `partitioned` is still a LIVE state")
        rig.manager.leaveMesh()
    }

    /// **Consumer 2: the idle lapse, armed by one tick and spent by the next thirty minutes later.**
    ///
    /// Two ticks on an injected clock, no sleep: the first tick's partition call arms the window and
    /// the second tick's idle-lapse call reads it and stops participation.
    ///
    /// It is deliberately NOT the order made behavioural. `applyPartitionVerdict(_:at:)` anchors
    /// `idleLapseDeadline = now + 1800`, so a window armed at `now` can never lapse at `now`
    /// whatever order the three calls are made in — swapping calls 2 and 3 inside one tick passes
    /// this cell identically. The order is pinned where it can be: the INDEX assertion over the
    /// mount's brace-matched body, in `ProximityRunPolicyHostTests`.
    @Test func theIdleLapseIsSpentByTheSecondOfTwoTicks() async throws {
        let rig = try ProximityRunPolicyHostTests.pollerRig(createdAt: Date())
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

    /// **THE HEADLINE (plan §12.3 finding 3): the YIELDING founder's ADOPTED ceiling is expired by
    /// one tick.**
    ///
    /// This cell arms NOTHING. It builds the real pairwise founding — two proximity-join managers on
    /// `FakePeerNetwork`, no seeded mesh, no seeded ledger, both halves committing and both founding
    /// — lets the election decide which half yields, and asserts the ceiling the YIELDER holds after
    /// adopting. It is the WINNER's deadline: the yield arm derives `createdAt + 6 h` from the
    /// ADOPTED descriptor, so the two halves of one mesh expire at one instant rather than six hours
    /// apart (plan §8.2 — "six hours of membership, whatever any clock says").
    ///
    /// The tick is handed an instant past the signed bound AND past its ±120 s skew tolerance, which
    /// is what `MeshSessionCeiling.verdict(now:monotonicElapsed:)` compares against.
    @Test func aYieldingFoundersAdoptedCeilingIsExpiredByOneTick() async throws {
        let rig = try MeshFoundingRig.build(2, label: "p7yield")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        // Roles, not indices: the identities are freshly provisioned, so the election decides which
        // half yields per run.
        let lowerFounds = MeshNetworkManager.foundsPairwiseMesh(
            local: rig.identities[0].localFingerprint, peer: rig.identities[1].localFingerprint
        )
        let manager = rig.nodes[lowerFounds ? 1 : 0].manager
        let winner = rig.nodes[lowerFounds ? 0 : 1].manager
        try await rig.settle(until: { rig.roster(0).count == 2 && rig.roster(1).count == 2 })

        let adopted = try #require(manager.currentMesh, "the yielder must have adopted a mesh at all")
        #expect(adopted.meshID == winner.currentMesh?.meshID,
                "the side the order names keeps its mesh and the other adopts it")
        let ceiling = try #require(manager.sessionCeiling, """
            the yielder holds NO ceiling, so the poller has nothing to enforce for it — which is \
            the gap this headline is about
            """)
        #expect(ceiling.hardDeadline
                == adopted.createdAt.addingTimeInterval(MeshSessionCeiling.ceilingSeconds),
                "the yielder adopts the WINNER's deadline, not a fresh six hours of its own")
        #expect(manager.isSessionLive, "and its session is live, or the tick below judges nothing")

        let recorder = ProximityRunDoorRecorder()
        let host = ProximityRunPolicyHost()
        ProximityRunPolicyHostTests.connect(
            host, to: recorder, poll: ProximityRunPolicyHostTests.sessionConsumerDoor(for: manager)
        )
        host.setSessionLive(true)
        let past = ceiling.hardDeadline.addingTimeInterval(
            MeshSessionCeiling.skewToleranceSeconds + 60
        )
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await host.pollNow(at: past)
        }
        host.setSessionLive(false)
        #expect(recorder.polls.count == 1, "exactly one tick ran")
        #expect(manager.sessionState == .expired,
                "one tick past the ADOPTED deadline must end the yielder's session")
        #expect(!manager.isSessionLive, "and the session predicate must agree that it ended")
    }
}

// MARK: - (e) The resume decision — item 5

/// **P7 item 5's clause: the launch restore's presentation is decided over EVERY
/// `MeshSessionRestoreOutcome` case and payload variant, and the two doors behind the affordance arm
/// no radio.**
///
/// Cites `ProximityResumeDecisionTests` for the copy fork, the `String`-typed-display-copy wall and
/// the one-app-call-site wall. What this clause runs is the whole 522-row product against an
/// INDEPENDENT oracle written over ProximityKit's own vocabulary, the four named rows as literals,
/// the module boundary, and the accept / decline / barred-try verdicts on real managers.
///
/// **A restore ARMS NO RADIO** (invariant 5, and `restoreSessionContextOncePerLaunch`'s own doc
/// comment): every cell that touches a manager asserts `isSearching` is false afterwards.
@MainActor
@Suite(.serialized)
struct MeshP7ResumeAcceptanceTests {

    /// **The artefact: 29 outcome values × 2 offer flags × 9 bar-hit reasons, every row decided.**
    ///
    /// The count is pinned as a literal so a shrunken product cannot pass vacuously, and the set of
    /// presentations actually observed is pinned too — a table that answered `.nothing` everywhere
    /// would otherwise agree with an oracle that had the same bug.
    @Test func everyRestoreOutcomeAndPayloadVariantIsDecidedAgainstTheTable() {
        let rows = MeshP7Acceptance.resumeRows()
        #expect(ProximityResumeDecisionTests.allOutcomes().count == 29, """
            every MeshSessionRestoreOutcome case with every payload variant that can be \
            constructed: 1 nil + 1 resumable + 8 terminated + 1 expired + 1 noSession + 3 deferrals \
            + 10 refusals + 4 corruptions
            """)
        #expect(ProximityResumeDecisionTests.barReasons().count == 9,
                "eight sealed reasons that map to an app twin, plus no hit at all")
        #expect(rows.count == 522, "the whole product, not a thinned one")
        var mismatch: String?
        var seen: Set<String> = []
        // R2: bounded by the enumerated product above.
        for row in rows {
            let decided = ProximityResumeDecision.decide(row.inputs)
            seen.insert(ProximityResumeDecisionTests.label(decided))
            if decided != MeshP7Acceptance.resumeOracle(row), mismatch == nil {
                mismatch = ProximityResumeDecisionTests.label(decided)
            }
        }
        #expect(mismatch == nil, """
            a row disagreed with the decisions table: the bar HIT, then the corrupt file, then the \
            retryable silence, then the offer
            """)
        #expect(seen == ["nothing", "offerResume", "couldNotReopen", "ended"],
                "and all four presentations are reached, so the agreement is not one answer everywhere")
    }

    /// **The four named rows, literal**, with no reference to the oracle.
    ///
    /// A deferral (and a refusal, and a launch whose restore has not concluded) says NOTHING, as a
    /// positive claim: both are retried at the next protected-data rise, so a sentence about either
    /// would be a cold-start apology for something about to succeed. A corrupt file is the one
    /// outcome that owes the user a sentence. An offered resumable context is the one affordance
    /// with an action behind it. A bar HIT outranks everything, including a standing offer.
    @Test func theFourNamedRowsOfTheTableAreLiteral() {
        let deferred = ProximityResumeInputs(
            outcome: .deferred, offersForegroundResume: true, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(deferred) == .nothing,
                "a restore that read nothing this launch offers nothing, whatever a stale flag says")
        let corrupt = ProximityResumeInputs(
            outcome: .corrupt, offersForegroundResume: true, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(corrupt) == .couldNotReopen,
                "a file that did not decode is never offered as a resume")
        let offered = ProximityResumeInputs(
            outcome: .resumable, offersForegroundResume: true, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(offered) == .offerResume, "the one affordance it earns")
        let noOffer = ProximityResumeInputs(
            outcome: .resumable, offersForegroundResume: false, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(noOffer) == .nothing,
                "the flag IS the offer: a resumable context the machine did not offer says nothing")
        var wrong: String?
        // R2: bounded by the enum's eight cases.
        for reason in ProximityMeshEndedReason.allCases {
            let hit = ProximityResumeInputs(
                outcome: .resumable, offersForegroundResume: true, rejoinBarHit: reason
            )
            if ProximityResumeDecision.decide(hit) != .ended(reason), wrong == nil {
                wrong = reason.rawValue
            }
        }
        #expect(wrong == nil, "a refused TRY is ENDED even where the manager still offers a resume")
    }

    /// **The module boundary loses no row.** Every outcome flattens into the app's vocabulary the
    /// way the mapping pinned before the projection existed says it must, and the two vocabularies
    /// are the same eight frozen tokens.
    ///
    /// The strong form is the one asserted: each of the 522 rows is decided twice — once from
    /// hand-built inputs and once through a real `MeshSessionResumeProjection` and
    /// `ProximityResumeInputs(projection:)` — and the two agree. A field dropped or mis-mapped at
    /// the boundary shows up here rather than as a presentation nobody notices.
    @Test func theProjectionFlattensEveryOutcomeIntoTheAppsVocabulary() {
        #expect(MeshSessionResumeProjection.Outcome.allCases.map(\.rawValue)
                == ProximityRestoreOutcomeKind.allCases.map(\.rawValue),
                "a kind the module knows and this target does not would have no clause")
        #expect(ProximityMeshEndedReason.allCases.map(\.rawValue)
                == MeshSessionTerminationReason.allCases.map(\.rawValue),
                "and the ended vocabulary is the sealed context's, one for one")
        var mismatch: String?
        var rows = 0
        // R2: bounded by the enumerated product.
        for row in MeshP7Acceptance.resumeRows() {
            rows += 1
            let projection = MeshSessionResumeProjection(
                outcome: MeshSessionResumeProjection.Outcome(restoring: row.outcome),
                offersForegroundResume: row.offers,
                rejoinBarHit: row.hit
            )
            let crossed = ProximityResumeDecision.decide(ProximityResumeInputs(projection: projection))
            if crossed != ProximityResumeDecision.decide(row.inputs), mismatch == nil {
                mismatch = ProximityResumeDecisionTests.label(crossed)
            }
        }
        #expect(rows == 522, "the whole product crossed the boundary, not a thinned one")
        #expect(mismatch == nil, "a row decided differently once it crossed the module boundary")
    }

    /// **Accepting ADOPTS the restored context and arms NO radio.**
    ///
    /// The adoption is the whole point: without it `isInSession` stays false after a relaunch, the
    /// Friends three-way resolves `.fresh`, and the first visit to the tab calls `startJoin()` —
    /// which resets the session state machine and founds a SECOND mesh beside the one on the disk.
    /// The three-way's answer is stated directly, so the claim is about the shipping decision rather
    /// than about a flag. The radio push that follows an accept is the policy's, from
    /// `ConnectView.resumeLastSession()`, and is walled in `ProximityResumeDecisionTests`.
    @Test func acceptingTheResumeAdoptsTheContextAndArmsNoRadio() throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let meshID = UUID()
        let context = MeshSessionContext(
            meshID: meshID, protocolVersion: 3, createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        let launch = try MeshP7ResumeLaunch(sealing: context, at: created.addingTimeInterval(60))
        #expect(launch.manager.sessionResumeProjection.outcome == .resumable,
                "a live context well inside its ceiling")
        #expect(ProximityResumeDecision.decide(
            ProximityResumeInputs(projection: launch.manager.sessionResumeProjection)) == .offerResume,
            "which is the one presentation with an action behind it")
        #expect(launch.manager.currentMesh == nil, "and the restore itself adopted nothing")

        #expect(launch.manager.acceptForegroundResume(now: created.addingTimeInterval(120)) == .accepted,
                "the offer was standing and the context was there")
        #expect(launch.manager.currentMesh?.meshID == meshID, "the restored context IS the mesh now")
        #expect(launch.manager.currentMesh?.createdAt == created,
                "and its creation instant came off the sealed file, so the ceiling agrees with the mesh")
        #expect(!launch.manager.offersForegroundResume, "the offer is spent")
        #expect(!launch.manager.isSearching, "and NO radio was armed — that push is the run policy's")
        #expect(launch.manager.slots.isEmpty, "nothing was invited and nothing committed")
        #expect(FriendsDiscoveryEntry.entry(isInSession: launch.manager.isInSession,
                                            hasCommittedPeer: launch.manager.hasCommittedPeer) == .resume,
                "and the three-way every entry to the Friends surface uses now answers `.resume`")
        #expect(ProximityResumeDecision.decide(
            ProximityResumeInputs(projection: launch.manager.sessionResumeProjection)) == .nothing,
            "so the card goes quiet on its own, with no second state to keep in step")
        launch.manager.leaveMesh()
    }

    /// **Declining CLEARS the offer, adopts nothing, and is silent the second time.**
    ///
    /// The silence is load-bearing for the app: one `onDismiss` closure serves the offer AND the two
    /// notices, so it runs for a `couldNotReopen` card too, where there was never an offer to
    /// decline. Nothing durable moves either way — the restored context stays, which is what still
    /// lets a launch expiry be written back and a custodied routed item drain.
    @Test func decliningTheResumeClearsTheOfferAndAdoptsNothing() throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let meshID = UUID()
        let context = MeshSessionContext(
            meshID: meshID, protocolVersion: 3, createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        let launch = try MeshP7ResumeLaunch(sealing: context, at: created.addingTimeInterval(60))
        #expect(launch.manager.offersForegroundResume, "the restore raised the offer")

        launch.manager.declineForegroundResume()
        #expect(!launch.manager.offersForegroundResume, "the offer is spent")
        #expect(launch.manager.currentMesh == nil, "a decline adopts nothing")
        #expect(launch.manager.restoredSessionContext?.meshID == meshID,
                "and keeps the restored context, the writer's identity for a launch expiry")
        #expect(!launch.manager.isSearching, "and arms nothing, exactly like the restore before it")
        #expect(ProximityResumeDecision.decide(
            ProximityResumeInputs(projection: launch.manager.sessionResumeProjection)) == .nothing,
            "so the offer is not re-presented on the next visit to the tab")

        launch.manager.declineForegroundResume()
        #expect(!launch.manager.offersForegroundResume,
                "a decline with no offer standing changes nothing, so one closure can serve the notices")
    }

    /// **A barred TRY is `.ended`, and a terminated launch is SILENT until there is one.**
    ///
    /// The defect this closes shipped for one pass: the bar is durable and cleared nowhere, a
    /// `terminated` context is never reaped, an `expired` one is written back AS terminated, and the
    /// card's dismissal is per-launch `@State` — so "That session has ended." was re-presented on
    /// every cold start for the rest of the install, to a reader who had done nothing but open the
    /// app. The input is the HIT: the reason carried by the last entry `rejoinRefusal(for:)`
    /// actually refused this run.
    ///
    /// The try is driven through `acceptForegroundResume(now:)`, the one barred door a cell can
    /// reach — the descriptor and admission-grant doors are `private` and need a committed slot and
    /// a sealed envelope. Founding the next mesh takes the notice down, because the hit is
    /// run-scoped and every founding runs `resetSessionStateMachine(keepingTerminalState:)`.
    @Test func aBarredTryIsEndedWhileATerminatedLaunchStaysSilent() throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let ended = MeshSessionContext(
            meshID: UUID(), protocolVersion: 3, createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds),
            localTermination: MeshSessionLocalTermination(reason: .verifiedTerminationRecord, at: created)
        )
        let quiet = try MeshP7ResumeLaunch(sealing: ended, at: created.addingTimeInterval(60))
        #expect(quiet.manager.sessionResumeProjection.outcome == .terminated,
                "the file already records an ending")
        #expect(quiet.manager.lastRejoinBarHit == nil, "a launch refuses nothing: nobody has tried")
        #expect(ProximityResumeDecision.decide(
            ProximityResumeInputs(projection: quiet.manager.sessionResumeProjection)) == .nothing,
            "so the cold start is SILENT — the sentence waits for the try")

        let live = MeshSessionContext(
            meshID: UUID(), protocolVersion: 3, createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        let launch = try MeshP7ResumeLaunch(sealing: live, at: created.addingTimeInterval(60))
        _ = DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            launch.manager.applySessionEvent(.departureRequested)
        }
        #expect(launch.manager.rejoinRefusal(for: live.meshID) == .ownDeparture, "the bar is up")
        #expect(launch.manager.acceptForegroundResume(now: created.addingTimeInterval(120))
                == .refused(.rejoinBarred(.ownDeparture)), "so the tap is refused, and says why")
        #expect(launch.manager.lastRejoinBarHit == .ownDeparture, "which is the HIT this run")
        #expect(ProximityResumeDecision.decide(
            ProximityResumeInputs(projection: launch.manager.sessionResumeProjection))
            == .ended(.ownDeparture), "and the card answers in the same turn")
        #expect(launch.manager.currentMesh == nil, "the refused try adopted nothing")
        _ = DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            launch.manager.promoteToMeshForTesting()
        }
        #expect(launch.manager.lastRejoinBarHit == nil, "founding the next mesh takes the notice down")
        launch.manager.leaveMesh()
    }
}

// MARK: - (f) Honesty

/// **What P7's battery does NOT claim, named rather than implied — one `@Test` per absence, each
/// documenting itself by asserting a true negative or a pinned fact.**
///
/// A doc comment is a promise nobody can break; a cell is one somebody has to. So each thing this
/// battery leaves unproven is written as an assertion about the mechanism that makes it unprovable
/// here, and every count below is **MEASURED at this commit** rather than inherited.
///
/// **The one line with no cell, because nothing in this process can assert it: the session that
/// wrote this battery compiled nothing.** There was no Swift toolchain on the authoring machine.
/// Every symbol this file names was checked by reading its declaration; every `@Test` count quoted
/// in `.github/workflows/s3-wall.yml`'s mesh step and in `CIGateSelectorBoundaryTests` is a STATIC
/// count of `@Test` declarations in this file; and none of it has been held against a
/// `Test run with N tests` line on a Mac. The first green gated run is what turns those numbers
/// from arithmetic into a measurement, and until it happens the floor is a claim about this file's
/// text rather than about a run.
@MainActor
@Suite(.serialized)
struct MeshP7HonestyAcceptanceTests {

    /// **No scene phase was driven.** `ScenePhase` enters the policy exactly ONCE, as the
    /// initialiser's parameter, and every cell in this battery hands it a phase rather than
    /// observing one.
    ///
    /// The type-name count is what closes the gaps a needle list always leaves: `switch phase {`,
    /// `case .inactive`, `== .inactive`, `!= .active` and whatever the next spelling turns out to be
    /// all need the type to be named. `ScenePhase` is not frozen, and an `@unknown default` under
    /// warnings-as-errors would have to pick a side for a phase that does not exist yet — so the
    /// battery asserts the ONE derivation and claims nothing about a real scene, which only a
    /// running app has.
    @Test func noScenePhaseWasDrivenAndThePolicyNamesTheTypeOnce() throws {
        let code = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ProximityRunPolicy.swift")
        )
        #expect(code.contains("FernletApp.routedGateForeground(for: scenePhase)"),
                "the policy still derives its foreground fact through the one mapping")
        #expect(code.components(separatedBy: "ScenePhase").count - 1 == 1,
                "the scene phase enters the policy file once, as the initialiser's parameter")
        #expect(ProximityRunPolicyTests.scenePhases.count == 3, """
            and the three phases this battery enumerates are a literal list, because `ScenePhase` is \
            neither frozen nor CaseIterable — a fourth would be invisible to every cell here
            """)
    }

    /// **No continuation task exists.** `ProximityContinuationTaskState.inert` is the only value
    /// shipping ever passes, so every `.run` directive in the policy matrix is an answer about P8.
    ///
    /// Measured over the comment-stripped app target: the type is named in exactly two files, the
    /// host binds its one mention to `.inert` as a `let` rather than a leg, and NOT ONE of the three
    /// non-inert cases is handed to the policy or set on the host anywhere outside the file that
    /// declares them.
    ///
    /// **All three cases are counted, because the needles are SCOPED TO THE TYPE.** The first
    /// version of this cell zero-listed a bare `.granted` and could not reach `.refused` or
    /// `.expired` at all: all three are ordinary spellings elsewhere in the app —
    /// `RoutedShareRefusalCopy`, `DuressRecoveryCoordinator`, `ProximityResumeDecision` — so an
    /// unscoped needle is a wall about the wrong vocabulary, and a name promising that no
    /// continuation task exists was carrying a count over one case in three. Scoping fixes both
    /// halves at once. Three spellings per case, being the three ways a non-inert task could reach
    /// the policy: the initialiser's argument (`continuationTask: .granted`), the fully qualified
    /// case (`ProximityContinuationTaskState.granted`), and the setter P8 will have to add
    /// (`setContinuationTask(.granted`). NINE needles, every one of them 0 at this commit, and none
    /// of them matchable by prose about a refusal or an expiry that has nothing to do with P8.
    @Test func noContinuationTaskExistsAndInertIsTheOnlyValueShipping() throws {
        let sources = try ProximityRunPolicyHostTests.appSources()
        #expect(!sources.isEmpty, "the App/ sweep found no Swift files at all")
        var named: [String] = []
        var liveTasks: [String] = []
        // R2: three cases × three spellings over the app target's own file list.
        for source in sources {
            if source.code.contains("ProximityContinuationTaskState") { named.append(source.name) }
            guard source.name != "ProximityRunPolicy.swift" else { continue }
            for state in ["granted", "refused", "expired"] {
                for needle in ["continuationTask: .\(state)",
                               "ProximityContinuationTaskState.\(state)",
                               "setContinuationTask(.\(state)"] {
                    let hits = ProximityRunPolicyHostTests.occurrences(of: needle, in: source.code)
                    guard hits > 0 else { continue }
                    liveTasks.append("\(source.name) spells \(needle) \(hits)×")
                }
            }
        }
        #expect(named.sorted() == ["ProximityRunPolicy.swift", "ProximityRunPolicyHost.swift"],
                "the continuation task is named in exactly the two files P7 gave it")
        if !liveTasks.isEmpty {
            // `Issue.record` for the dynamic detail; the `#expect` comment below stays literal.
            Issue.record("""
                a non-inert continuation task reaches the policy — \
                \(liveTasks.joined(separator: "; "))
                """)
        }
        #expect(liveTasks.isEmpty, """
            a granted, refused or expired continuation task is handed to the policy or set on the \
            host somewhere in the app target outside the file that declares the cases — P7 ships \
            `.inert` and nothing else until P8's coordinator exists
            """)
        let host = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ProximityRunPolicyHost.swift")
        )
        #expect(host.contains("private let continuationTask: ProximityContinuationTaskState = .inert"),
                "the host binds it as a `let`, so nothing in P7 can pretend a task exists")
        #expect(ProximityContinuationTaskState.allCases.count == 4,
                "four states, three of which P7's wiring can never produce")
    }

    /// **No device lock was driven.** `simctl` has no lock verb, so no cell in this battery — or in
    /// any suite it cites — has ever seen iOS data protection actually fall.
    ///
    /// What is asserted instead is the SHAPE of the leg that would carry it: a `Bool` fed literally
    /// from the two `UIApplication` notifications (the notification IS the fact, because
    /// `isProtectedDataAvailable` still answers `true` inside the will-become-unavailable handler),
    /// with three setter call sites in `FernletApp` — the two notification handlers and the launch
    /// seed. The behavioural half everywhere in P7 is a `Bool` a test set, and D-10.3 is why that is
    /// enough for the RADIOS: protected data decides plaintext and moves no directive anywhere in
    /// the 23 040-row product.
    @Test func noDeviceLockWasDrivenAndProtectedDataIsABoolLegFedByTwoNotifications() throws {
        let app = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletApp.swift"))
        #expect(ProximityRunPolicyHostTests.occurrences(
            of: "runPolicyHost.setProtectedDataAvailable(", in: app
        ) == 3, """
            the protected-data leg is fed from three sites in FernletApp — the two UIApplication \
            notifications and the launch seed — and that count moved without this pin moving
            """)
        #expect(app.contains("UIApplication.protectedDataWillBecomeUnavailableNotification"),
                "the falling edge is still a notification rather than a poll of the flag")
        #expect(app.contains("UIApplication.protectedDataDidBecomeAvailableNotification"),
                "and so is the rising one")
        let host = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ProximityRunPolicyHost.swift")
        )
        #expect(host.contains("private var isProtectedDataAvailable = false"),
                "the leg is a Bool that starts fail-closed, and nothing here reads the system flag")
    }

    /// **`.continuingInBackground` is unreachable, so the deferred-heart quarter is P8's.**
    ///
    /// The state exists and its arithmetic is tested (`MeshP6HeartCeremonyAcceptanceTests` drives it
    /// through the state machine directly), but NOTHING in shipping raises
    /// `MeshSessionEvent.backgrounded` or `.foregrounded`: the two edges are spelled only inside
    /// `MeshSessionStateMachine.swift`, which declares them. So no product path reaches the state,
    /// and P7 is forbidden from raising it — doing so would assert a continued-processing task is
    /// running, which is P8's claim.
    @Test func continuingInBackgroundIsUnreachableBecauseNothingRaisesTheEdge() throws {
        let app = try ProximityRunPolicyHostTests.appSources()
        let kit = try ProximityRunPolicyHostTests.proximityKitSources()
        #expect(!app.isEmpty && !kit.isEmpty, "a sweep that enumerated nothing passes green")
        #expect(kit.contains(where: { $0.name == "MeshSessionStateMachine.swift" }),
                "the file that declares both edges is in the sweep, or the counts are vacuous")
        var raises = 0
        var carriers: [String] = []
        // R2: two needles over two file lists.
        for source in app + kit {
            for needle in ["applySessionEvent(.backgrounded)", "applySessionEvent(.foregrounded)"] {
                raises += ProximityRunPolicyHostTests.occurrences(of: needle, in: source.code)
            }
            if source.code.contains("continuingInBackground") { carriers.append(source.name) }
        }
        #expect(raises == 0, """
            something in shipping raises a background or foreground session edge, so \
            `.continuingInBackground` is reachable and this battery's silence about it is wrong
            """)
        #expect(carriers == ["MeshSessionStateMachine.swift"],
                "and the state is named only where it is declared, never in the app")
    }

    /// **The ordinary proximity joiner still arms no ceiling.** P7 item 4 gave the poller something
    /// to enforce; it did not give a fresh peerless search a six-hour bound.
    ///
    /// Counts over the comment-stripped declaring file, MEASURED at this commit: five spellings of
    /// `startSessionCeiling(` — one declaration and four call sites, being `foundMesh(_:now:)`,
    /// `adoptSessionCeiling(of:now:)`, the launch restore and the accepted resume — and two of
    /// `adoptSessionCeiling(`, its declaration and the yield arm's one call. `startJoin()` is on
    /// neither list, which is the claim: a device that only searches holds no ceiling, and the
    /// five-minute give-up clock rather than a ceiling is what ends a search that found nobody.
    @Test func theOrdinaryProximityJoinerStillArmsNoCeiling() throws {
        let code = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift")
        )
        #expect(ProximityRunPolicyHostTests.occurrences(of: "startSessionCeiling(", in: code) == 5, """
            one declaration and four callers — the founding, the yielder's adopt, the launch restore \
            and the accepted resume; a fifth caller is a decision, not an addition
            """)
        #expect(ProximityRunPolicyHostTests.occurrences(of: "adoptSessionCeiling(", in: code) == 2,
                "one declaration and the yield arm's one call, which is §12.3 finding 3's fix")
        let join = try #require(
            MeshRoutedSourceScan.bracedBody(after: "public func startJoin(", in: code),
            "startJoin() was renamed, or its brace-matched body does not close"
        )
        #expect(!join.contains("startSessionCeiling("),
                "the ordinary joiner arms a ceiling, so a peerless search now carries a six-hour bound")
        #expect(!join.contains("adoptSessionCeiling("), "and it adopts none either")
    }

    /// **The resume card's UI suite is named in NO workflow step**, and the selector wall cannot see
    /// it.
    ///
    /// `ProximityResumeCardUITests` is an `XCTestCase` in `Tests/FernletUITests`, so it is outside
    /// the tree `CIGateSelectorBoundaryTests.declaredTopLevelTypes()` walks and outside the
    /// `FernletTests` bundle every `run-gated-suites.sh` line selects into. Nothing in CI runs it
    /// today. That is a gap named rather than papered over: the tap that raises the session surface
    /// is its subject, and this battery's resume clause asserts the DECISION and the two manager
    /// doors instead.
    ///
    /// **EVERY workflow is read, not `s3-wall.yml` alone.** "Named in no workflow step" is a claim
    /// about the whole of `.github/workflows`, and a one-file read makes it silently unfalsifiable
    /// the day a second file adds a UI-test step. The sweep is derived from the directory rather
    /// than from a list written here, guarded non-empty and checked to contain the gated workflow,
    /// because an enumeration that found nothing passes a zero-list green. Both YAML extensions are
    /// taken, since GitHub accepts either and a `.yaml` step would otherwise walk straight past a
    /// `.yml`-only filter. The BUNDLE name is on the needle list beside the suite name: a step that
    /// runs the whole `FernletUITests` target names no suite at all and would be invisible to a
    /// suite-name needle. Three files match at this commit — `pages.yml`, `power-of-10.yml` and
    /// `s3-wall.yml` — and none of them names either needle.
    @Test func theResumeCardsUiSuiteIsNamedInNoWorkflowStep() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: RepoRoot.url(".github/workflows"), includingPropertiesForKeys: nil
        )
        let workflows = entries
            .filter { $0.pathExtension == "yml" || $0.pathExtension == "yaml" }
            .sorted { $0.path < $1.path }
        #expect(!workflows.isEmpty, "the workflow sweep enumerated nothing, so its zero-list is vacuous")
        #expect(workflows.contains(where: { $0.lastPathComponent == "s3-wall.yml" }),
                "and the gated workflow itself is not in the sweep, so neither is any step it holds")
        var namers: [String] = []
        // R2: two needles over the workflow directory's own file list.
        for workflow in workflows {
            let text = try String(contentsOf: workflow, encoding: .utf8)
            for needle in ["ProximityResumeCardUITests", "FernletUITests"] where text.contains(needle) {
                namers.append("\(workflow.lastPathComponent) names \(needle)")
            }
        }
        if !namers.isEmpty {
            // `Issue.record` for the dynamic detail; the `#expect` comment below stays literal.
            Issue.record("a workflow step reaches the UI target — \(namers.joined(separator: "; "))")
        }
        #expect(namers.isEmpty,
                "the UI suite or its bundle is named in a workflow, so this honesty note is stale")
        let wall = try RepoRoot.source(".github/workflows/s3-wall.yml")
        #expect(wall.contains("Scripts/run-gated-suites.sh"),
                "non-vacuity: the gated workflow really is being read")
        let declared = try CIGateSelectorBoundaryTests.declaredTopLevelTypes()
        #expect(!declared.isEmpty, "non-vacuity: the declaration sweep really found the test tree")
        #expect(!declared.contains("ProximityResumeCardUITests"), """
            the UI suite is declared under Tests/FernletTests after all, which would make it \
            selectable and this note wrong
            """)
        #expect(declared.contains("MeshP7HonestyAcceptanceTests"),
                "while this suite IS declared there, which is what the gate wall binds")
    }

    /// **The 30-second poll interval is UNMEASURED.** It is a starting value, not a result.
    ///
    /// The three consumers it drives have their own resolutions — a 6-hour ceiling, a 30-minute idle
    /// window, and a partition edge only a link change can move — so 30 s is the shortest of them
    /// that still costs nothing noticeable, and the honest question the first soak has to answer is
    /// how much LATER than 30 s a tick can be before a user notices a session outliving its ceiling.
    /// No cell in this battery waits 30 s: every poller cell either injects a millisecond interval
    /// or drives `pollNow(at:)` with an instant, which measures the CONSUMERS and says nothing about
    /// the cadence.
    @Test func theThirtySecondPollIntervalIsUnmeasured() {
        #expect(ProximityRunPolicyHost.defaultPollInterval == 30,
                "the shipping interval is 30 s, and moving it is a decision rather than a tuning")
        #expect(MeshNetworkManager.idleWindowSeconds == 30 * 60,
                "the idle window it has to resolve is thirty minutes — sixty ticks wide")
        #expect(MeshSessionCeiling.ceilingSeconds == 6 * 60 * 60,
                "and the ceiling six hours, so the interval is nowhere near either bound")
        #expect(MeshSessionCeiling.skewToleranceSeconds == 120, """
            while the ceiling's own skew tolerance is ±120 s — four ticks — which is the real \
            budget a lateness measurement would have to fit inside
            """)
    }
}
