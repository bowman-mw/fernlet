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
        #expect(batteries.count >= 28, "the mesh batteries shrank: \(batteries.count) declared")
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
        let script = try RepoRoot.source(Self.floorScript)
        #expect(script.contains("totalTestCount") && script.contains("-resultBundlePath"),
                "the floor script no longer reads the result bundle's own count")
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
