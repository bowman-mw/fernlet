// MeshP10HonestyAcceptanceTests.swift
// FernletTests
//
// Network migration **P10's acceptance battery, clause (5)** (launcher item 9): the HONESTY suite —
// what P10 did not prove, asserted rather than said.
//
// The shape is P8's and P9's, and the reason for it is the same: an honesty suite that merely
// *stated* "we did not run X" in a comment would go stale silently, and a phase would look more
// proven than it is. Every row below is an assertion over the record that carries the unrun claim,
// so deleting the record reddens — and where a source fact can stand in for an execution, the
// substitution is named out loud rather than left to be inferred.
//
// **Four things only a device can show, and P10 shows none of them:**
// 1. the real `SystemCompanionRefreshScheduler` registration ACCEPTED by `BGTaskScheduler` on a
//    phone — every tier-1 cell in this battery drives a fake;
// 2. a submission GRANTED and the task actually launched by iOS, which no test can make happen;
// 3. the expiration handler firing on the real `SystemCompanionRefreshTaskHandle`, hopped from no
//    actor at all by the framework;
// 4. a chain surviving a cold launch — the pending request the system holds is the mechanism's only
//    durable state, and nothing in this process can observe it.
//
// **What a Simulator could show, item 8 measured, and the answer was: almost nothing.** Lane E of
// the runbook is now a MEASURED verdict rather than an open question — registration is accepted, and
// everything after it is refused, the submission with the same `BGTaskSchedulerErrorDomain` code 1
// that P8 found for the continuation path. ``theSimulatorLaneVerdictIsRecordedWithWhatItCouldNotShow``
// pins that verdict AND the six rows the lane names as reachable only on a phone, so a measurement
// cannot be taken and then quietly forgotten.
//
// **And the older debts P10 does not close:** plan §15.1–§15.4 (P8's device gate, never run),
// item 0 (`blocked (owner)` — no phones), 9.4-LATER (the MC→QUIC cutover, D-4.1 hold), P9-3-A (the
// lock parking both 1:1 radios) and D-10.4.5 (the foreground publish path, deferred).
//
// **Why no ledger read.** P8's and P9's honesty suites read their phase ledger, which was committed
// early in each phase. `Docs/Mesh-Migration-Loop-Ledger-P10.md` is not committed until this phase's
// close-out, so a cell that read it would pass in the worktree that wrote it and throw in every
// clean checkout and on CI — an acceptance battery that can only pass where it was authored. Every
// row below reads a TRACKED record instead: the plan, the runbook, the workflow, the tree itself,
// and — for P10's own deferred decision, which the plan does not carry — `Docs/FileIndex.md`.
//
// Neither determinism digest moves and neither is spelled here contiguously: each keeps its ONE
// home in `MeshP5AcceptanceTests`, and the gate that runs this battery re-runs the determinism
// suites, which is where a moved digest actually reddens.

import Foundation
import Testing

/// **Clause (5): honesty.** What P10 did not prove, and where each unrun claim is recorded.
@Suite(.serialized)
struct MeshP10HonestyAcceptanceTests {

    /// The runbook's Lane E section alone, from its heading to the next `###`.
    ///
    /// Sliced rather than searched whole: "Low Power Mode" is a row of Lane B as well, and a claim
    /// about what LANE E records must not be satisfied by a sentence in another lane.
    ///
    /// - Parameter runbook: The whole runbook.
    /// - Returns: The section's text, or nil when the lane has not been written.
    private func laneESection(in runbook: String) -> String? {
        guard let heading = runbook.range(of: "### Lane E") else { return nil }
        let rest = runbook[heading.upperBound...]
        guard let next = rest.range(of: "\n### ") else { return String(rest) }
        return String(rest[..<next.lowerBound])
    }

    /// **Every clause suite of this battery is declared, and is named once on the mesh step.**
    ///
    /// `everyMeshAcceptanceBatteryIsGated` demands the five by SHAPE — that is exactly why they are
    /// named `MeshP10<Clause>AcceptanceTests` — but it says nothing about duplicates, and a suite
    /// named twice on one line runs its tests twice and inflates the step's measured floor by a
    /// number nobody can decompose afterwards.
    @Test func everyClauseSuiteIsDeclaredAndNamedOnceOnTheMeshStep() throws {
        let workflow = try RepoRoot.source(MeshP10Acceptance.workflowPath)
        let steps = CIGateSelectorBoundaryTests.gatedSteps(in: workflow).filter { $0.label == "mesh-batteries" }
        #expect(steps.count == 1, "one mesh-batteries step")
        let listed = steps.first?.suites ?? []
        let named = Set(listed)
        let declared = try CIGateSelectorBoundaryTests.declaredTopLevelTypes()

        // R2: bounded by the five clause names.
        for clause in MeshP10Acceptance.clauseSuites {
            #expect(declared.contains(clause), """
                `\(clause)` is declared by no file in Tests/FernletTests — a selector naming it \
                would match nothing and the step would pass having run zero of its tests
                """)
            #expect(named.contains(clause), "P10 clause suite `\(clause)` is not on the mesh-batteries step")
        }
        #expect(listed.count == named.count,
                "no suite is named twice — a duplicate selector runs its tests twice and inflates the floor")
    }

    /// **Neither determinism digest moved, nor left its one home.**
    ///
    /// Nothing in P10 touches `MeshConvergenceSchedule`, `MeshRoutedScheduleOverlay` or
    /// `MeshScheduleEvent` — this phase never enters `ProximityKit` at all — so both digests are
    /// UNCHANGED, and a move is a red rather than a re-pin. Each is spelled split here so this file
    /// is not itself a second home, and the last assertion proves that split rather than trusting it.
    @Test func neitherDeterminismDigestMovedNorLeftItsOneHome() throws {
        let tests = try MeshP7Acceptance.sources(under: "Tests/FernletTests")
        #expect(tests.count >= 280, "the test-target scan lost its files (351 when this was measured)")
        #expect(MeshP7Acceptance.homes(of: "ca898" + "bcc", in: tests) == ["MeshP5AcceptanceTests.swift"],
                "the schedule digest has exactly one home, and this file's split spelling is not a second")
        #expect(MeshP7Acceptance.homes(of: "594b6" + "f77", in: tests) == ["MeshP5AcceptanceTests.swift"],
                "and so does the overlay digest — a move is a red, never a re-pin")
        let me = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("Tests/FernletTests/MeshP10HonestyAcceptanceTests.swift"))
        let spellsADigest = me.contains("ca898" + "bcc") || me.contains("594b6" + "f77")
        #expect(!spellsADigest, "and P10's battery spells neither contiguously")
    }

    /// **The production conformers are built by nothing in the test target, and their device rows
    /// are recorded as owed.**
    ///
    /// This is the honest statement of what tier 1 covers, made MECHANICALLY instead of in prose.
    /// `SystemCompanionRefreshScheduler` and `SystemCompanionRefreshTaskHandle` are the only parts
    /// of the mechanism that touch `BGTaskScheduler` and `BGAppRefreshTask`; if no test constructs
    /// either, then no test has ever seen a registration accepted, a submission granted, a task
    /// launched or an expiration handler fired — which is precisely the claim, and it stops being
    /// true the moment somebody writes `SystemCompanionRefreshScheduler()` in a suite.
    ///
    /// It is also the cell that proves this battery never reached `BGTaskScheduler` at all: five
    /// serialized clause suites, twenty-six cells, and not one of them constructs the only two
    /// types that could have.
    ///
    /// Both needles are spelled split, because this file is inside the directory being scanned.
    @Test func theProductionConformersAreBuiltByNothingHereAndTheirRowsAreOwed() throws {
        let tests = try MeshP7Acceptance.sources(under: "Tests/FernletTests")
        #expect(tests.count >= 280, "the test-target scan lost its files")
        let schedulerCall = "SystemCompanionRefreshScheduler" + "("
        let handleCall = "SystemCompanionRefreshTaskHandle" + "("

        #expect(MeshP7Acceptance.homes(of: schedulerCall, in: tests).isEmpty, """
            a test now constructs the production scheduler. If that is deliberate, this honesty \
            row is obsolete and must be REWRITTEN rather than deleted — it would be claiming less \
            than the tree proves, which is the opposite failure and just as misleading
            """)
        #expect(MeshP7Acceptance.homes(of: handleCall, in: tests).isEmpty,
                "and nothing wraps a real `BGAppRefreshTask` either")

        let refresh = try MeshP7Acceptance.sources(under: MeshP10Acceptance.refreshRoot)
        #expect(MeshP7Acceptance.homes(of: "final class SystemCompanionRefreshScheduler", in: refresh).count == 1,
                "the untested remainder is still exactly one type…")
        #expect(MeshP7Acceptance.homes(of: "final class SystemCompanionRefreshTaskHandle", in: refresh).count == 1,
                "…beside exactly one more")

        let plan = try RepoRoot.source(MeshP10Acceptance.planPath)
        #expect(plan.contains("P10's own device row"), """
            §27.2's tier-3 sentence is gone. It is the only place the migration records that a real \
            refresh launch granted by iOS on a phone has never been seen at any tier
            """)
    }

    /// **Item 8's Simulator verdict is recorded, together with what the Simulator could not show.**
    ///
    /// Lane E is a MEASUREMENT, not a plan, and this cell pins it as one. The verdict has three
    /// parts and all three must survive: a registration that WAS observed (a positive event, so the
    /// finding does not rest on the absence of a line); a submission refused with the same
    /// `BGTaskSchedulerErrorDomain` code 1 P8 found for the continuation path, which is why nothing
    /// after it is reachable; and `companionRefresh.runFinished` never emitted on any machine,
    /// anywhere — the single sentence that says how much of this mechanism has never run end to end.
    ///
    /// Then the six rows the lane names as phone-only, by NAME rather than by count, because a row
    /// quietly dropped from that list is a device measurement silently removed from the close-out's
    /// bill; and the two audit events that fall with them, which somebody would otherwise go looking
    /// for on a Simulator.
    ///
    /// Scoped to the Lane E section: "Low Power Mode" is also a Lane B row, and a claim about what
    /// Lane E records must not be satisfied by a different lane's table.
    @Test func theSimulatorLaneVerdictIsRecordedWithWhatItCouldNotShow() throws {
        let runbook = try RepoRoot.source(MeshP10Acceptance.runbookPath)
        let lane = try #require(laneESection(in: runbook), """
            the runbook's Lane E section is gone. It is the only record of the one lane question \
            worth an hour — whether a Simulator will launch a registered `BGAppRefreshTask` at all \
            — and of the answer, which was no
            """)
        #expect(lane.contains("companionRefresh.registered"), """
            the one thing a Simulator DID show is no longer recorded. Registration accepted is a \
            positive observation; without it the lane reads as "nothing worked", which is a \
            stronger claim than the measurement supports
            """)
        #expect(lane.contains("BGTaskSchedulerErrorDomain") && lane.contains("Code=1"), """
            the submission's refusal lost its domain and code. "It did not work" is not a \
            measurement; the exact error is what makes P8's continuation finding extend to the \
            refresh path as a FACT rather than as an analogy
            """)
        #expect(lane.contains("has never been emitted on any machine"), """
            the sentence that says how far this mechanism has ever run is gone. \
            `companionRefresh.runFinished` is emitted only by a completed pipeline behind a real \
            delivery, and no machine has ever produced one
            """)

        // R2: bounded by the six rows the lane names, plus the two audit events that fall with them.
        for row in ["A cold background launch by iOS.",
                    "A refresh granted and launched by iOS on its own schedule.",
                    "The real conformer's expiration handler under a genuine time budget.",
                    "The 15-minute floor honoured.",
                    "Background App Refresh disabled in Settings.",
                    "Low Power Mode.",
                    "companionRefresh.edgeFoundARequestAlreadyPending",
                    "companionRefresh.deliveryAbsorbed"] {
            #expect(lane.contains(row), """
                Lane E's "Rows a Simulator cannot give" no longer names `\(row)`. Each is a device \
                measurement this phase owes; a row deleted here is one nobody will run, because \
                nothing else records that it is outstanding
                """)
        }
    }

    /// **The device gate and every owner call P10 inherited are still recorded as owed.**
    ///
    /// P10 is explicitly NOT gated by plan §15 — that is a decision, not an omission — so the four
    /// section headings are named here: a renamed or deleted one would quietly narrow what the
    /// migration admits it has not proved. The plan carries the rest of the inherited debts too:
    /// item 0 blocked for want of phones, the MC→QUIC cutover held at D-4.1, and the lock finding.
    ///
    /// P10's own deferred decision is the one that has no home in the plan, because it was taken
    /// inside this phase. It is pinned on `Docs/FileIndex.md`, which is tracked and which this
    /// commit writes it into — for the reason this file's header gives: the phase ledger that would
    /// otherwise carry it is not committed until the close-out, and a cell that read it would pass
    /// only in the worktree that wrote it.
    @Test func theDeviceGateAndTheOwnerCallsAreStillRecordedAsOwed() throws {
        let plan = try RepoRoot.source(MeshP10Acceptance.planPath)
        // R2: bounded by the four stated sections.
        for section in ["**15.1 Radio matrix:**",
                        "**15.2 Partition walks:**",
                        "**15.3 Progress soak:**",
                        "**15.4 Wi-Fi Aware evaluation"] {
            #expect(plan.contains(section), "plan §15's `\(section)` is gone — the gate it named is still unrun")
        }
        #expect(plan.contains("blocked (owner)"), """
            item 0 is no longer recorded as blocked. Two phases have now shipped without it, and \
            the only install in existence is the owner's own phone
            """)
        #expect(plan.contains("9.4-LATER"), "the MC→QUIC cutover's deferred half (D-4.1 hold) left the plan")
        #expect(plan.contains("P9-3-A"), """
            the lock finding is gone: a configured Fernlet Lock parks the presence and \
            recipe-share radios permanently, and nothing tells the person why. Pre-existing, and \
            not fixable here — the policy row belongs to P7's 23 040-row product
            """)

        let index = try RepoRoot.source(MeshP10Acceptance.fileIndexPath)
        #expect(index.contains("D-10.4.5"), """
            P10's own deferred decision left the tracked record: the foreground `publish(_:)` still \
            reloads unconditionally. Clause (3) pins that as the CURRENT truth, which is only \
            honest for as long as the decision is written down somewhere as open
            """)
    }
}
