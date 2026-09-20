// CIGateSelectorBoundaryTests.swift
// FernletTests
//
// The STATIC half of the CI non-vacuity guard (P5 close-out review, finding 4). The dynamic half is
// `Scripts/run-gated-suites.sh`: every test step in `.github/workflows/s3-wall.yml` runs through it,
// and it refuses a green run whose result bundle counts fewer tests than the step's floor.
//
// What this file adds is the check that can run WITHOUT a simulator: `-only-testing:` matches suite
// names exactly and matches nothing on a misspelling, so a workflow line can name a suite that no
// longer exists and stay green forever. Here every suite the workflow names must be a declared
// top-level `struct` / `class` in `Tests/FernletTests`, every mesh acceptance battery declared in
// the tree must be named by the workflow (the P3/P4/P5 batteries were ungated for three phases
// because nothing said they had to be), and this suite gates itself.

import Foundation
import Testing

/// Every gated selector is a declared suite, every declared battery is gated, and every step runs
/// through the floor.
@Suite struct CIGateSelectorBoundaryTests {

    private static let workflowPath = ".github/workflows/s3-wall.yml"
    private static let floorScript = "Scripts/run-gated-suites.sh"

    /// The batteries the workflow must name: any top-level suite matching these shapes, wherever it
    /// is declared. Adding a `MeshP6…AcceptanceTests` suite therefore fails CI until it is gated.
    private static func isMeshBattery(_ name: String) -> Bool {
        if name == "MeshRoutedDrainConvergenceTests" || name == "MeshConvergencePropertyTests"
            || name == "MeshConvergenceScheduleTests" {
            return true
        }
        guard name.hasPrefix("MeshP"), name.hasSuffix("AcceptanceTests") else { return false }
        let afterP = name.dropFirst("MeshP".count)
        return afterP.first.map { $0.isNumber } ?? false
    }

    /// One `run-gated-suites.sh` invocation in the workflow: its label, floor and suite names.
    struct GatedStep: Equatable {
        /// The bundle label.
        let label: String
        /// The test-count floor.
        let floor: Int
        /// The suite names, in workflow order.
        let suites: [String]
    }

    /// The MEASURED suite-name count of every gated step — the half of the non-vacuity guard that
    /// needs no simulator (P9 item 6's fix review, NOTE-3).
    ///
    /// `-only-testing:` names that go missing are invisible to everything else here: a name leaving
    /// a workflow line still leaves every remaining name declared, and `everyMeshAcceptanceBatteryIsGated`
    /// only asks after `MeshP<n>…AcceptanceTests` / convergence batteries. Thirteen of P9 item 6's
    /// fourteen are behaviour suites under none of those shapes, so the step's TEST-count floor —
    /// which needs a Mac, a simulator and ~3 minutes — was the only thing holding them on the line.
    /// A count of names is the generic rule the tally comment cannot be (the parser drops `#` lines
    /// by design) and a hand-list of 85 names should never be: `gatedSteps` already returns them.
    ///
    /// MEASURED from the workflow, parsed exactly as `gatedSteps` parses it, at P9 item 6's fix
    /// review (2026-09-20). RAISE an entry in the same commit that adds names; LOWER one only
    /// deliberately, with the retirement argued, which is the whole point of the pin.
    private static let measuredSuiteNameCounts: [String: Int] = [
        "s3-grep": 2,
        "no-tracking": 1,
        "power-of-10": 1,
        "localization": 1,
        "key-custody": 4,
        "crypto-goldens": 3,
        "mesh-batteries": 97
    ]

    /// Every floor-script invocation in the workflow, with backslash continuations joined and
    /// comment lines ignored — a commented-out step is not a step.
    static func gatedSteps(in workflow: String) -> [GatedStep] {
        var joined: [String] = []
        var carry = ""
        // R2: bounded by the workflow's line count.
        for rawLine in workflow.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasSuffix("\\") {
                carry += String(line.dropLast()) + " "
                continue
            }
            joined.append(carry + line)
            carry = ""
        }
        var steps: [GatedStep] = []
        // R2: bounded by the joined line count.
        for line in joined where line.contains(floorScript) {
            let words = line.split(separator: " ").map(String.init)
            guard let at = words.firstIndex(of: floorScript), words.count >= at + 4,
                  let floor = Int(words[at + 2]) else { continue }
            steps.append(GatedStep(label: words[at + 1], floor: floor, suites: Array(words[(at + 3)...])))
        }
        return steps
    }

    /// Every top-level `struct` / `class` name declared in the test target, subdirectories included
    /// (the target is a synchronized folder group, so a suite may live anywhere under it).
    static func declaredTopLevelTypes() throws -> Set<String> {
        let directory = RepoRoot.url("Tests/FernletTests")
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var files: [URL] = []
        // R2: bounded by the file count under the test directory.
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url)
        }
        var names: Set<String> = []
        // R2: bounded by the file count.
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            // R2: bounded by the file's line count.
            for line in source.components(separatedBy: "\n") {
                guard let name = topLevelTypeName(line) else { continue }
                names.insert(name)
            }
        }
        return names
    }

    /// The type a column-0 declaration line names, or nil for anything else. Leading attributes on
    /// the same line (`@Suite struct X`, `@Suite(.serialized) struct X`, `@MainActor final class X`)
    /// are skipped; a leading space means a nested type, which no selector can name.
    private static func topLevelTypeName(_ line: String) -> String? {
        guard line.hasPrefix("@") || line.first?.isLetter == true else { return nil }
        var rest = Substring(line)
        // R2: bounded by the line's attribute count — each pass consumes at least one character.
        while rest.hasPrefix("@") {
            var depth = 0
            var index = rest.startIndex
            // R2: bounded by the line length.
            while index < rest.endIndex {
                let character = rest[index]
                if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
                if character == " " && depth == 0 { break }
                index = rest.index(after: index)
            }
            rest = rest[index...].drop { $0 == " " }
        }
        let prefixes = ["struct ", "final class ", "class ", "actor ", "enum "]
        // R2: bounded by the prefix list.
        for prefix in prefixes where rest.hasPrefix(prefix) {
            let name = rest.dropFirst(prefix.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    /// Every suite the workflow gates is a declared top-level type — no selector can match nothing.
    @Test func everyGatedSelectorNamesADeclaredSuite() throws {
        let steps = Self.gatedSteps(in: try RepoRoot.source(Self.workflowPath))
        let declared = try Self.declaredTopLevelTypes()
        #expect(steps.count >= 6, "the workflow lost test steps — \(steps.count) floor-script invocations found")
        var undeclared: [String] = []
        // R2: bounded by the step count × the suite count.
        for step in steps {
            #expect(!step.suites.isEmpty, "step \(step.label) names no suite")
            #expect(step.floor >= 1, "step \(step.label) has a vacuous floor")
            let measured = Self.measuredSuiteNameCounts[step.label]
            #expect(measured != nil, """
                step \(step.label) has no entry in `measuredSuiteNameCounts` — a new gated step \
                must record its own measured suite-name count, or names can leave it unnoticed
                """)
            #expect(step.suites.count >= (measured ?? 1), """
                step \(step.label) names \(step.suites.count) suites; \(measured ?? 1) were \
                measured on the line. A name that leaves is a silent loss of coverage which only \
                the step's TEST-count floor would catch, and that needs a simulator — lower this \
                number in the same commit that retires the suite, or put the name back.
                """)
            for suite in step.suites where !declared.contains(suite) {
                undeclared.append("\(step.label): \(suite)")
            }
        }
        #expect(undeclared.isEmpty, """
            The workflow names suites that no file in Tests/FernletTests declares at top level — \
            `-only-testing:` would match nothing and the step would pass having run zero tests:
            \(undeclared.joined(separator: "\n"))
            """)
    }

    /// Every mesh acceptance battery declared in the tree is gated, so a new phase's suites cannot
    /// sit ungated the way P3, P4 and P5's did.
    @Test func everyMeshAcceptanceBatteryIsGated() throws {
        let gated = Set(Self.gatedSteps(in: try RepoRoot.source(Self.workflowPath)).flatMap(\.suites))
        let batteries = try Self.declaredTopLevelTypes().filter(Self.isMeshBattery)
        // MEASURED at the commit that moved it, never inherited: 28 at P6 item 7 (2 convergence
        // generators + the routed convergence battery + 4×P3 + 9×P4 + 12×P5), plus P6 item 9's
        // eight clause suites = 36, plus P7 item 7's six clause suites (run policy, gate writer,
        // radio seams, poller, resume, honesty) = 42, plus P8 item 10's six (the coordinator's
        // table, the hold verb, the raises and the disagreement, the presentation table, the task
        // wiring, honesty) = 48, plus P9 item 9's five clause suites (the ephemeral posture, the
        // presence swap, the recipe swap, the MC retirement as an honesty row, honesty) = 53. A
        // count of DECLARATIONS, taken by reading the tree.
        #expect(batteries.count >= 53, "the mesh batteries shrank: \(batteries.count) declared")
        let ungated = batteries.subtracting(gated).sorted()
        #expect(ungated.isEmpty, """
            Mesh acceptance batteries declared in Tests/FernletTests but not named in \
            \(Self.workflowPath) — add each to the mesh step's Scripts/run-gated-suites.sh line and \
            raise that step's floor by its test count:
            \(ungated.joined(separator: "\n"))
            """)
    }

    /// No test step bypasses the floor, and this suite gates itself.
    @Test func everyTestStepRunsThroughTheFloorScript() throws {
        let workflow = try RepoRoot.source(Self.workflowPath)
        let code = workflow.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        #expect(!code.contains("xcodebuild test-without-building"),
                "a raw test-without-building step in the workflow has no floor — route it through \(Self.floorScript)")
        #expect(!code.contains("-only-testing:"),
                "a raw -only-testing: selector in the workflow is unchecked — name the suite on the floor script's line")
        let gated = Set(Self.gatedSteps(in: workflow).flatMap(\.suites))
        let selfGates = Self.gatedSteps(in: workflow).filter { $0.suites.contains("CIGateSelectorBoundaryTests") }
        #expect(selfGates.count >= 2, "this suite must gate itself on two independent steps, so editing one cannot silence it")
        #expect(gated.contains("IdentityProvisioningReadTests") && gated.contains("MeshRoutedRefusalBudgetTests"),
                "the two walls the P5 correction pass added are gated")
        // `MeshRoutedDrainWallTests` is a WALL with no compiler half — the retirement and parking
        // zero-lists item 4 and item 6 put there run nowhere else — so removing it from the line
        // must be a failure rather than a silence, exactly as the two above are.
        // `MeshContinuationRaiseWallTests` joins it at P8 item 10 on the same argument: the two
        // session-state raises have exactly one home each in ProximityKit, the app speaks each
        // exactly once and from one file, and the app offers `applySessionEvent(` zero times — three
        // source counts that exist nowhere else and that no compiler checks.
        // `MeshContinuationTaskHostWallTests` (item 6) is that case again: the `BackgroundTasks`
        // names have one app home outside the DEBUG probe, the feed has one call site, the host
        // speaks no radio verb and the funnel never calls it back — all uncompiled source counts.
        // `MeshRoutedLockedDeviceTests` is gated beside them but is deliberately NOT on this pin: it
        // is 26 behaviour cells over five store states (measured at item 9's own gated run, and the
        // number the workflow's floor decomposition uses), not a zero-list, and
        // `MeshP5LockedDeviceAcceptanceTests` is already its acceptance clause. `MeshRoutedDrainTests`
        // (gated at P8 item 1, 2026-09-18) is the same case and is left off this pin for the same
        // reason: 43 behaviour cells, walled by the step's measured floor, not by a name here. So are
        // P8's five behaviour suites, gated by item 10 in the same commit as the two walls above —
        // `MeshContinuationCoordinatorTests`, `MeshContinuationProgressTests`,
        // `MeshContinuationCardPresentationTests`, `MeshContinuationDriverTests` and
        // `MeshContinuationDisagreementTests`: each is a table or a rig walk whose cells the floor
        // counts, and each has an acceptance clause of its own in `MeshP8AcceptanceTests`.
        // P9 item 6 gates FOURTEEN more on the same argument — the three `MeshKeyAgreement*` suites,
        // the three photo / key-advertisement delivery suites and eight routed behaviour suites,
        // 247 cells: behaviour, not zero-lists, so the step's re-measured floor is what holds them
        // on the line. Two of them (`MeshRoutedItemSealTests`, `MeshRoutedStoreIsolationTests`)
        // carry no `@Suite` attribute at all and seven do not share their file's name — this suite
        // reads DECLARATIONS for exactly that reason, and a selector naming a FILE matches nothing.
        #expect(gated.contains("MeshRoutedDrainWallTests"),
                "the routed path's retirement and parking zero-lists are gated")
        #expect(gated.contains("MeshContinuationRaiseWallTests")
                && gated.contains("MeshContinuationTaskHostWallTests"),
                "P8's two source walls with no compiler half are gated")
        // The one wall among P9 item 6's fourteen: `MeshRoutedStoreIsolationTests` source-scans the
        // test tree for a `MeshRoutedStore(` that names no scope of its own, pins the production
        // scope unreachable from tests, and pins the one construction site of
        // `MeshCustodyDurabilityWitness` — uncompiled source counts that run nowhere else, the
        // `MeshRoutedDrainWallTests` argument. Without this line the thirteen behaviour suites
        // beside it are held by the step's floor alone, which needs a simulator; this half is the
        // one that reds with no simulator at all when a name leaves the workflow.
        #expect(gated.contains("MeshRoutedStoreIsolationTests"),
                "the routed store's scope-isolation grep-wall is gated")
        // P9 item 9 adds the one of its seven newly-gated suites that earns a NAME pin on the
        // existing argument: `TransportNeutralityBoundaryTests` is a source grep-wall with no
        // compiler half — `import MultipeerConnectivity` confined to two files, every framework
        // type matched as a WHOLE identifier, and a permit list whose entries must still EXIST —
        // and it is what `MeshP9McRetirementAcceptanceTests` defers to for the app target, where a
        // substring walk cannot run (the connection inspector renders the literal row label
        // "MCSession", and `FileMCPeerIDStore` is Fernlet's own name). It is also the wall the
        // MC->QUIC cutover empties, so it must be impossible to drop from the line silently first.
        // The other six of the seven are behaviour suites held by the step's measured floor, the
        // `MeshRoutedLockedDeviceTests` precedent.
        #expect(gated.contains("TransportNeutralityBoundaryTests"),
                "the MultipeerConnectivity permit wall is gated")
        let script = try RepoRoot.source(Self.floorScript)
        #expect(script.contains("totalTestCount") && script.contains("-resultBundlePath"),
                "the floor script no longer reads the result bundle's own count")
        // NOTE-4 of P9 item 6's fix review: a restart re-runs suites, so `totalTestCount` counts
        // some cells twice and every floor above it becomes unreadable — 13 of the mesh step's
        // suites are held by that floor alone. The guard is a grep in a shell script with no
        // compiler half, so it is pinned here, beside the bundle-count pin it protects.
        #expect(script.contains("Restarting after unexpected exit, crash, or test timeout"),
                "the floor script no longer refuses a run xcodebuild restarted")
    }

    /// The parser reads the workflow's real shape: a continuation-joined invocation with a label, a
    /// floor and several suites, and ignores everything else.
    @Test func theParserReadsContinuationJoinedInvocations() {
        let sample = """
            run: |
              set -euo pipefail
              # every Scripts/run-gated-suites.sh line must name a declared suite
              Scripts/run-gated-suites.sh mesh-batteries 101 \\
                MeshP3SessionAcceptanceTests \\
                MeshRoutedDrainConvergenceTests
              echo done
              # Scripts/run-gated-suites.sh commented 9 CommentedOutTests
              Scripts/run-gated-suites.sh s3-grep 1 S3BoundaryTests
            """
        let steps = Self.gatedSteps(in: sample)
        #expect(steps == [
            GatedStep(label: "mesh-batteries", floor: 101,
                      suites: ["MeshP3SessionAcceptanceTests", "MeshRoutedDrainConvergenceTests"]),
            GatedStep(label: "s3-grep", floor: 1, suites: ["S3BoundaryTests"])
        ])
        #expect(Self.isMeshBattery("MeshP5HonestyAcceptanceTests"))
        #expect(Self.isMeshBattery("MeshP12FooAcceptanceTests"))
        #expect(!Self.isMeshBattery("MeshPhotoAcceptanceTests"))
        #expect(!Self.isMeshBattery("MeshP5AcceptanceFailure"))
        #expect(Self.topLevelTypeName("@Suite struct CIGateSelectorBoundaryTests {") == "CIGateSelectorBoundaryTests")
        #expect(Self.topLevelTypeName("@Suite(.serialized) struct MeshP5HonestyAcceptanceTests {") == "MeshP5HonestyAcceptanceTests")
        #expect(Self.topLevelTypeName("@MainActor final class Rig: XCTestCase {") == "Rig")
        #expect(Self.topLevelTypeName("final class MeshRoutedBackpressureAuditCapture {") == "MeshRoutedBackpressureAuditCapture")
        #expect(Self.topLevelTypeName("    struct Nested {") == nil, "a nested type is not a selector")
        #expect(Self.topLevelTypeName("// struct InAComment") == nil)
    }
}
