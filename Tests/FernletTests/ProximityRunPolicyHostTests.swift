// ProximityRunPolicyHostTests.swift
// FernletTests
//
// Network migration P7 item 2: the WIRING half of plan §13's run policy, and the wall that says the
// routed access gate has exactly one writer.
//
// A separate suite from `ProximityRunPolicyTests` on purpose. That one's subject is the MATRIX — a
// 23 040-row enumeration of a pure function's whole input product, whose header says so in as many
// words — and it holds no object, injects nothing and touches no app state. This one's subject is a
// live `@MainActor` host with a door injected into it, plus a grep-wall over the app target. Two
// subjects, two suites; folding the second into the first would make "the matrix is the artefact"
// false the moment someone skimmed it.
//
// What the wall says, and why it is worth a cell:
//
//   * `applyRoutedAccessGate(` appears EXACTLY ONCE outside ProximityKit, and ONCE is counted as an
//     OCCURRENCE total rather than as a one-element file list — a second call parked inside
//     `FernletApp.swift` would leave the file list right and the claim false. Before this item the
//     app assembled the gate in a private helper and called the door from six sites
//     (`FernletApp.swift:337`, `:383`, `:416`, `:435`, `:447`, `:491`); four of them had compared
//     `== .active` while the scene handler fell only on `.background`, which is the failure a single
//     writer exists to make impossible. `ProximityRunPolicy.decide(` is counted the same way.
//   * The one remaining caller is named from a BRACE-MATCHED body, not from text proximity, and
//     that body is shown to carry a gate it was handed rather than one it built.
//   * The retired helper is a zero-list, in `theRetiredTextTransportIsGone`'s shape: keeping both
//     spellings alive is what makes a retirement a fiction.
//   * Every count is proven non-vacuous — the file sweep is non-empty, `FernletApp.swift` is in it,
//     and each zero-list needle is fixtured against a planted string. A wall handed a wrong root
//     enumerates nothing and passes green, which is the dangerous failure mode.
//
// The unit half drives the host through the six edges with a recording door: the two scene legs, an
// inactive scene (which is a FOREGROUND scene — P5's post-close correction), the duress edge that
// moves at neither a scene nor a protected-data transition, a protected-data edge, and the launch
// sequence in which nothing is written until the first explicit push. The last cell is the general
// claim the others are instances of: over a step list that exercises every setter the host declares,
// what the host writes equals — element for element — a HAND-DERIVED list of gate literals, each
// written out from the gate's three rules rather than re-computed from the policy. Re-deciding over
// the host's own inputs would restate the host's arithmetic back to it and could not fail.

import Foundation
import ProximityKit
import SwiftUI
import Testing
@testable import Fernlet

/// Records what the host writes, standing in for `MeshNetworkManager.applyRoutedAccessGate(_:now:)`.
///
/// A class rather than a captured local `var` so the door is an ordinary main-actor object the
/// closure holds, which is the shape production uses (the closure holds the store) and the shape
/// that keeps every cell readable at its assertion.
@MainActor
final class ProximityRunGateRecorder {

    /// Every gate written, oldest first.
    private(set) var gates: [MeshRoutedAccessGate] = []

    /// Every instant the host stamped a write with, oldest first, positionally paired with
    /// ``gates``.
    private(set) var instants: [Date] = []

    /// Records one write.
    ///
    /// - Parameters:
    ///   - gate: The gate the host decided.
    ///   - now: The instant it stamped the write with.
    func record(_ gate: MeshRoutedAccessGate, at now: Date) {
        gates.append(gate)
        instants.append(now)
    }
}

/// P7 item 2's wiring: the single writer of the routed access gate, and the wall that counts it.
@MainActor
@Suite struct ProximityRunPolicyHostTests {

    // MARK: - Fixtures

    /// A connected host and the recorder holding its door.
    ///
    /// - Returns: the host, and the recorder every write lands in.
    static func connectedHost() -> (host: ProximityRunPolicyHost, recorder: ProximityRunGateRecorder) {
        let recorder = ProximityRunGateRecorder()
        let host = ProximityRunPolicyHost()
        host.connect { gate, now in recorder.record(gate, at: now) }
        return (host, recorder)
    }

    /// One call against a host: the shape every entry of ``legSteps`` carries.
    ///
    /// A named type rather than the element type written inline, because a bare
    /// `@MainActor (ProximityRunPolicyHost) -> Void` sitting in an array literal's annotation has no
    /// precedent anywhere in this repo and a typealias is the spelling that does.
    typealias LegStep = @MainActor (ProximityRunPolicyHost) -> Void

    /// One leg update per entry, each paired with the gate that step must produce.
    ///
    /// A literal list rather than a product: the policy's own input product is
    /// `ProximityRunPolicyTests`' subject, and what this suite has to show is that each SETTER
    /// records its OWN leg and re-decides. The order deliberately moves a leg back and forth (the
    /// scene three times, protected data twice, the lock in and out of duress), so a setter that
    /// assigned the wrong field would move a gate leg its own `expected` literal holds still.
    ///
    /// `expected` is an INDEPENDENT hand-derivation, never `ProximityRunPolicy.decide(_:)`'s answer
    /// re-computed over the host's own inputs — that comparison restates the host's arithmetic back
    /// to it and cannot fail. Each literal is read straight off the gate's three rules, against a
    /// host that starts fail-closed (`.background`, protected data false, lock `.locked`):
    /// `protectedDataAvailable` is the protected-data leg verbatim, `appIsForeground` is true for
    /// `.active` and `.inactive` and false for `.background`, and `duressActive` holds exactly while
    /// the lock leg is `.duress`. Six of the thirteen steps drive a setter the GATE does not read
    /// and repeat the previous literal unchanged, which is the claim that those legs stay out of it;
    /// the `.inactive` → `.active` step repeats too, because both phases are foreground.
    static let legSteps: [(step: LegStep, expected: MeshRoutedAccessGate)] = [
        (step: { $0.setScenePhase(.background) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: false, appIsForeground: false, duressActive: false
        )),
        (step: { $0.setProtectedDataAvailable(true) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: false, duressActive: false
        )),
        (step: { $0.setScenePhase(.inactive) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setAppLockState(.duress) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: true
        )),
        (step: { $0.setSelectedTab(.social) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: true
        )),
        (step: { $0.setHasCommittedPeer(true) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: true
        )),
        (step: { $0.setAppLockState(.unlocked) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setChatAgeGate(.below) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setAllowsNearbyPresence(true) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setAllowsNearbyRecipeShares(true) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setDeletingAllData(true) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setScenePhase(.active) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: true, appIsForeground: true, duressActive: false
        )),
        (step: { $0.setProtectedDataAvailable(false) }, expected: MeshRoutedAccessGate(
            protectedDataAvailable: false, appIsForeground: true, duressActive: false
        ))
    ]

    /// Every `.swift` file under `App/`, comments stripped, sorted by path.
    ///
    /// The whole app target rather than `App/Fernlet` alone, so a second writer parked in the
    /// widget, share or Messages extension would be counted too.
    ///
    /// Body-identical to `MeshRoutedLockedDeviceTests.codeSources(under:)` and kept separate because
    /// that one is `private static` on another suite and cannot be called from here. Promoting it
    /// would move a file this item does not own; the duplicate is five lines of enumeration.
    ///
    /// - Returns: each file's name and its comment-stripped source.
    static func appSources() throws -> [(name: String, code: String)] {
        let root = RepoRoot.url("App")
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        var sources: [(name: String, code: String)] = []
        // R2: bounded by the app target's own file list.
        for file in files.sorted(by: { $0.path < $1.path }) {
            sources.append((
                file.lastPathComponent,
                MeshRoutedSourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8))
            ))
        }
        return sources
    }

    /// How many times `needle` occurs in `haystack`.
    ///
    /// - Parameters:
    ///   - needle: The substring counted.
    ///   - haystack: The text searched.
    /// - Returns: the occurrence count.
    static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - The wall

    /// **The gate has exactly one writer, and this is the wall that says so** (P7 item 2; the same
    /// shape as `theDrainFiresOnlyFromTheMergeDoor`, which is why P5's drain survived three phases).
    ///
    /// `applyRoutedAccessGate(` appears once across the whole app target, and the body holding it is
    /// brace-matched and shown to carry a gate it was HANDED: it names the closure's `accessGate`
    /// parameter and constructs no `MeshRoutedAccessGate` of its own. The decision that produced
    /// that value is pinned on the other side — `ProximityRunPolicy.decide(` also has exactly one
    /// app-target call site, inside `ProximityRunPolicyHost.pushNow()`, whose brace-matched body
    /// names both the decision and its gate.
    ///
    /// Each needle is counted TWICE over: the list of FILES that carry it, and the total number of
    /// OCCURRENCES. The file list on its own is not the claim — a second `applyRoutedAccessGate(`
    /// added inside `FernletApp.swift` keeps that list at one element while the single writer is
    /// already gone, and that is the cheapest way to lose it.
    ///
    /// Non-vacuity first, because a wall handed a wrong root enumerates nothing and passes green.
    @Test func theRoutedAccessGateHasExactlyOneWriterInTheAppTarget() throws {
        let sources = try Self.appSources()
        #expect(!sources.isEmpty, "the App/ sweep found no Swift files at all")
        #expect(sources.contains(where: { $0.name == "FernletApp.swift" }),
                "the App/ sweep no longer reaches FernletApp.swift, so every count below is vacuous")
        var writers: [String] = []
        var deciders: [String] = []
        var writeCalls = 0
        var decideCalls = 0
        // R2: bounded by the app target's own file list.
        for source in sources {
            let writes = Self.occurrences(of: "applyRoutedAccessGate(", in: source.code)
            let decides = Self.occurrences(of: "ProximityRunPolicy.decide(", in: source.code)
            writeCalls += writes
            decideCalls += decides
            if writes > 0 {
                writers.append(source.name)
            }
            if decides > 0 {
                deciders.append(source.name)
            }
        }
        #expect(writers == ["FernletApp.swift"],
                "the routed access gate must have exactly one writer, and it is FernletApp")
        #expect(writeCalls == 1,
                "the routed access gate is written from more than one call site in the app target")
        #expect(deciders == ["ProximityRunPolicyHost.swift"],
                "the run policy must be consulted in exactly one place, and it is the host")
        #expect(decideCalls == 1,
                "the run policy is consulted from more than one call site in the app target")
    }

    /// The writer's brace-matched body carries a gate it was handed, and the host's push is where
    /// that gate was decided.
    ///
    /// Split from the count above only to stay inside the 60-line rule; the two are one claim.
    @Test func theOneWriterCarriesTheGateThePolicyDecided() throws {
        let appCode = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletApp.swift"))
        let door = try #require(
            MeshRoutedSourceScan.bracedBody(after: "runPolicyHost.connect {", in: appCode),
            "the production door is no longer installed by a `runPolicyHost.connect {` closure"
        )
        #expect(door.contains("applyRoutedAccessGate("), "the injected door no longer reaches the seam")
        #expect(door.contains("accessGate"), "the door no longer names the gate it was handed")
        #expect(!door.contains("MeshRoutedAccessGate("),
                "the door assembles a gate of its own again, so the policy is not the single writer")
        #expect(!door.contains("restoreMeshSessionContextIfNeeded"),
                "the body matcher is measuring the file rather than the braced closure")
        let mount = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func mountRoutedRunPolicy(", in: appCode),
            "the launch mount was renamed, or its brace-matched body does not close"
        )
        #expect(mount.contains("runPolicyHost.connect {"), "the launch mount no longer installs the door")
        #expect(mount.contains("runPolicyHost.pushNow()"), "the launch mount no longer pushes")
        let hostCode = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ProximityRunPolicyHost.swift")
        )
        let push = try #require(
            MeshRoutedSourceScan.bracedBody(after: "func pushNow(", in: hostCode),
            "the host's pushNow() was renamed, or its brace-matched body does not close"
        )
        #expect(push.contains("ProximityRunPolicy.decide("), "the host no longer asks the policy")
        #expect(push.contains("decision.accessGate"), "the host no longer writes the decision's gate")
    }

    /// **The retired six-site gate push is gone**, spelling by spelling — the zero-list shape
    /// `theRetiredTextTransportIsGone` uses, and owed for the same reason: keeping both paths alive
    /// is what makes a retirement a fiction.
    ///
    /// Three spellings, one flow — the private helper the six sites called, the `foreground:`
    /// argument every one of them routed through `routedGateForeground(for:)`, and the sampled
    /// `protectedData:` argument the two scene sites passed. Each needle is fixtured against a
    /// planted string in the same cell, because a matcher that cannot find the thing it forbids
    /// passes vacuously.
    @Test func theRetiredSixSiteGatePushIsGone() throws {
        let retired = [
            "pushRoutedAccessGate",
            "foreground: Self.routedGateForeground",
            "protectedData: protectedDataAvailableNow"
        ]
        let sources = try Self.appSources()
        #expect(!sources.isEmpty, "the App/ sweep found no Swift files at all")
        var survivors: [String] = []
        // R2: three names over the app target's own file list.
        for source in sources {
            for symbol in retired where source.code.contains(symbol) {
                survivors.append(source.name)
            }
        }
        #expect(survivors.isEmpty, "a spelling of the retired six-site gate push came back")
        let planted = """
            pushRoutedAccessGate(store, protectedData: protectedDataAvailableNow, \
            foreground: Self.routedGateForeground(for: scenePhase))
            """
        var matched = 0
        // R2: the same three names.
        for symbol in retired where planted.contains(symbol) {
            matched += 1
        }
        #expect(matched == retired.count, "a needle in the zero-list cannot match what it forbids")
    }

    // MARK: - The six edges, through an injected door

    /// The two scene legs: backgrounding closes the foreground fact, activating opens it.
    @Test func theSceneLegsPushTheForegroundFactDownThenUp() throws {
        let (host, recorder) = Self.connectedHost()
        host.setScenePhase(.background)
        host.setScenePhase(.active)
        #expect(recorder.gates.count == 2, "each leg update re-decides and writes exactly once")
        let down = try #require(recorder.gates.first, "the backgrounding leg wrote nothing")
        let up = try #require(recorder.gates.last, "the activation leg wrote nothing")
        #expect(!down.appIsForeground, "a backgrounded scene is not a foreground scene")
        #expect(up.appIsForeground, "an active scene is a foreground scene")
    }

    /// An INACTIVE scene is a FOREGROUND scene (P5's post-close correction): Control Center, a call
    /// banner, a system prompt, the app's own Face ID sheet, iPad Split View. The host never
    /// compares a phase itself — `ProximityRunInputs`' initialiser routes it through
    /// `FernletApp.routedGateForeground(for:)`, which is the whole reason that initialiser is the
    /// only one.
    @Test func anInactiveSceneLegPushesAForegroundGate() throws {
        let (host, recorder) = Self.connectedHost()
        host.setScenePhase(.inactive)
        let gate = try #require(recorder.gates.last, "the inactive leg wrote nothing")
        #expect(gate.appIsForeground,
                "an inactive scene is still foreground: the device is unlocked and the process is live")
        let wholeGate = MeshRoutedAccessGate(
            protectedDataAvailable: false, appIsForeground: true, duressActive: false
        )
        #expect(gate == wholeGate,
                "the inactive leg must raise the foreground fact and leave the other two fail-closed")
    }

    /// The duress edge raises `duressActive` and moves NEITHER other leg — it is entered at an
    /// already-foreground lock screen and cleared by a real-passcode unlock in the same foreground,
    /// so it rides no scene and no protected-data transition and keeps its own `.onChange`.
    @Test func theDuressEdgePushesDuressAndMovesNoOtherLeg() throws {
        let (host, recorder) = Self.connectedHost()
        host.setProtectedDataAvailable(true)
        host.setScenePhase(.active)
        host.setAppLockState(.duress)
        #expect(recorder.gates.count == 3, "three leg updates, three writes")
        let before = try #require(recorder.gates.dropLast().last, "the scene leg wrote nothing")
        let after = try #require(recorder.gates.last, "the duress leg wrote nothing")
        #expect(!before.duressActive, "duress was not in force before its own edge")
        #expect(after.duressActive, "the duress edge must close the gate")
        #expect(after.protectedDataAvailable == before.protectedDataAvailable,
                "the duress edge moved the protected-data leg")
        #expect(after.appIsForeground == before.appIsForeground,
                "the duress edge moved the foreground leg")
    }

    /// A protected-data edge moves its own leg and nothing else — the fact is passed literally from
    /// the notification that says so, because `isProtectedDataAvailable` still answers `true` inside
    /// the will-become-unavailable handler.
    @Test func aProtectedDataEdgeMovesOnlyItsOwnLeg() throws {
        let (host, recorder) = Self.connectedHost()
        host.setScenePhase(.active)
        host.setProtectedDataAvailable(true)
        #expect(recorder.gates.count == 2, "two leg updates, two writes")
        let before = try #require(recorder.gates.first, "the scene leg wrote nothing")
        let after = try #require(recorder.gates.last, "the protected-data leg wrote nothing")
        #expect(!before.protectedDataAvailable, "the host starts fail-closed on data protection")
        #expect(after.protectedDataAvailable, "the rising leg must open the ciphertext fact")
        #expect(after.appIsForeground == before.appIsForeground,
                "the protected-data edge moved the foreground leg")
        #expect(after.duressActive == before.duressActive,
                "the protected-data edge moved the duress leg")
    }

    /// The launch sequence: legs set before the door is installed are RECORDED and not written,
    /// connecting writes nothing by itself, the first explicit push is the launch push, and a second
    /// `connect(_:)` is ignored so a re-fired `.onAppear` cannot stack a second door.
    @Test func nothingIsWrittenUntilTheFirstExplicitPush() throws {
        let recorder = ProximityRunGateRecorder()
        let host = ProximityRunPolicyHost()
        host.setScenePhase(.active)
        host.setProtectedDataAvailable(true)
        host.connect { gate, now in recorder.record(gate, at: now) }
        #expect(recorder.gates.isEmpty, "installing the door must write nothing on its own")
        host.pushNow()
        #expect(recorder.gates.count == 1, "the first explicit push is the launch push")
        let launch = try #require(recorder.gates.last, "the launch push wrote nothing")
        #expect(launch.appIsForeground && launch.protectedDataAvailable,
                "the legs set before the door was installed are carried into the launch push")
        let second = ProximityRunGateRecorder()
        host.connect { gate, now in second.record(gate, at: now) }
        host.pushNow()
        #expect(second.gates.isEmpty, "a second connect(_:) must be ignored")
        #expect(recorder.gates.count == 2, "the first door keeps writing")
    }

    /// The general claim the five cells above are instances of: over a sequence that exercises every
    /// setter the host declares, the gates the host writes are exactly ``legSteps``' hand-derived
    /// literals, in order.
    ///
    /// The expectation is INDEPENDENT of the code under test on purpose. Re-deciding
    /// `ProximityRunPolicy.decide(host.inputs).accessGate` here would ask the host's own inputs for
    /// the answer the host just wrote from those same inputs, so nothing could ever differ; the list
    /// on ``legSteps`` is written out from the gate's three rules instead, and a setter that
    /// assigned the wrong field lands on a literal that says otherwise.
    ///
    /// The host is not allowed a second opinion about the gate — it neither builds one nor
    /// deduplicates one. `MeshNetworkManager.applyRoutedAccessGate(_:now:)` owns the edge and
    /// already ignores an unchanged gate, which is why the write count here is one per leg update
    /// rather than one per CHANGED leg update, and why seven of the thirteen literals repeat a value
    /// already written.
    @Test func everyWrittenGateIsTheHandDerivedGateForThatStep() {
        let (host, recorder) = Self.connectedHost()
        var expected: [MeshRoutedAccessGate] = []
        // R2: bounded by the literal step list.
        for entry in Self.legSteps {
            entry.step(host)
            expected.append(entry.expected)
        }
        let everyGateMatchesItsLiteral = recorder.gates == expected
        #expect(recorder.gates.count == Self.legSteps.count,
                "every leg update must write exactly once")
        #expect(everyGateMatchesItsLiteral,
                "a written gate differs from the literal the gate's own rules derive for that step")
        #expect(recorder.instants.count == recorder.gates.count,
                "every write is stamped with the instant the manager judges it against")
    }
}
