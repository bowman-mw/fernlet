// ProximityRunPolicyHostTests.swift
// FernletTests
//
// Network migration P7 items 2 and 3: the WIRING half of plan §13's run policy, the wall that says
// the routed access gate has exactly one writer, and — from item 3's pass B — the ZERO WALL that
// says the four proximity radios are driven from the host's door closures and from nowhere else in
// the app target.
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
// What the ZERO WALL says (pass B):
//
//   * `startJoin()`, `stopJoin()`, `resumeSearchingForPartitionedMesh()`, both listeners'
//     `start()` / `stop()`, `applyRunState(` and `armDiscoveryTimeout` appear in `App/` ONLY inside
//     `FernletApp.mountRoutedRunPolicy(_:)`'s door closures — counted, not file-listed, and the
//     surviving occurrences are shown to be CONTAINED in that brace-matched body rather than merely
//     near it.
//   * The DEBUG rejection-matrix harness is exempt **by file name**, and the exemption is fixtured
//     against the one `startJoin()` and the `#if DEBUG` / `MeshMatrixDebugOptions.isEnabled` pair it
//     was written for, because an exemption that matches nothing is a hole nobody can see.
//   * Non-vacuity names `ContentView.swift` and `FernletStore.swift` specifically: between them they
//     held eight of these calls before pass B, and a sweep that stopped reaching either would report
//     a clean retirement of code it never read.
//
// The unit half drives the host through its edges with recording doors: the two scene legs, an
// inactive scene (which is a FOREGROUND scene — P5's post-close correction), the duress edge that
// moves at neither a scene nor a protected-data transition, a protected-data edge, and the launch
// sequence in which nothing is written until the first explicit push. Pass B adds the radio half —
// no seam ever receives `foregroundOnly`, the mesh door receives the `(links, discovery)` pair the
// decision resolved, the teardown fires once on a RISE and again only after the condition clears,
// and a second `connect(…)` re-points every door so a rebuilt store is re-mounted. The last cell is
// the general claim the others are instances of: over a step list that exercises every setter the
// host declares, what the host writes equals — element for element — a HAND-DERIVED list of gate
// literals, each written out from the gate's three rules rather than re-computed from the policy.
// Re-deciding over the host's own inputs would restate the host's arithmetic back to it and could
// not fail.

import Foundation
import ProximityKit
import SwiftUI
import Testing
@testable import Fernlet

/// Records what the host writes through all five doors, standing in for
/// `MeshNetworkManager.applyRoutedAccessGate(_:now:)`, the three `applyRunState` seams and the
/// session teardown.
///
/// A class rather than captured local `var`s so each door is an ordinary main-actor object the
/// closure holds, which is the shape production uses (the closures hold the store) and the shape
/// that keeps every cell readable at its assertion.
@MainActor
final class ProximityRunDoorRecorder {

    /// Every gate written, oldest first.
    private(set) var gates: [MeshRoutedAccessGate] = []

    /// Every instant the host stamped a gate write with, oldest first, positionally paired with
    /// ``gates``.
    private(set) var instants: [Date] = []

    /// Every `(links, discovery)` pair pushed at the mesh seam, oldest first.
    private(set) var meshDirectives: [(links: ProximityRunState, discovery: ProximityRunState)] = []

    /// Every directive pushed at the presence seam, oldest first.
    private(set) var presenceDirectives: [ProximityRunState] = []

    /// Every directive pushed at the recipe-share seam, oldest first.
    private(set) var recipeShareDirectives: [ProximityRunState] = []

    /// How many times the teardown door was called.
    private(set) var teardowns = 0

    /// Records one gate write.
    ///
    /// - Parameters:
    ///   - gate: The gate the host decided.
    ///   - now: The instant it stamped the write with.
    func record(_ gate: MeshRoutedAccessGate, at now: Date) {
        gates.append(gate)
        instants.append(now)
    }

    /// Records one push at the mesh seam.
    ///
    /// - Parameters:
    ///   - links: The mesh-links directive as the seam received it.
    ///   - discovery: The discovery/admission directive as the seam received it.
    func recordMesh(links: ProximityRunState, discovery: ProximityRunState) {
        meshDirectives.append((links: links, discovery: discovery))
    }

    /// Records one push at the presence seam.
    ///
    /// - Parameter state: The directive as the seam received it.
    func recordPresence(_ state: ProximityRunState) {
        presenceDirectives.append(state)
    }

    /// Records one push at the recipe-share seam.
    ///
    /// - Parameter state: The directive as the seam received it.
    func recordRecipeShare(_ state: ProximityRunState) {
        recipeShareDirectives.append(state)
    }

    /// Records one call of the teardown door.
    func recordTeardown() {
        teardowns += 1
    }

    /// Every directive any radio seam received, in push order — the list the "no seam ever sees
    /// `foregroundOnly`" claim is made over.
    var everyRadioDirective: [ProximityRunState] {
        var directives: [ProximityRunState] = []
        // R2: bounded by the pushes this recorder has already stored.
        for pair in meshDirectives {
            directives.append(pair.links)
            directives.append(pair.discovery)
        }
        return directives + presenceDirectives + recipeShareDirectives
    }
}

/// P7 items 2 and 3's wiring: the single writer of the routed access gate and of the four proximity
/// radios, and the two walls that count them.
@MainActor
@Suite struct ProximityRunPolicyHostTests {

    // MARK: - Fixtures

    /// A connected host and the recorder holding all five of its doors.
    ///
    /// - Returns: the host, and the recorder every write lands in.
    static func connectedHost() -> (host: ProximityRunPolicyHost, recorder: ProximityRunDoorRecorder) {
        let recorder = ProximityRunDoorRecorder()
        let host = ProximityRunPolicyHost()
        Self.connect(host, to: recorder)
        return (host, recorder)
    }

    /// Installs one recorder as all five of a host's doors.
    ///
    /// Hoisted out of ``connectedHost()`` so the cells that build a host by hand — the launch
    /// sequence, and the re-mount — install the same set rather than a gate door alone.
    ///
    /// - Parameters:
    ///   - host: The host to connect.
    ///   - recorder: The recorder every door writes into.
    static func connect(_ host: ProximityRunPolicyHost, to recorder: ProximityRunDoorRecorder) {
        host.connect(
            accessGate: { gate, now in recorder.record(gate, at: now) },
            meshRadios: { links, discovery in
                recorder.recordMesh(links: links, discovery: discovery)
            },
            presence: { state in recorder.recordPresence(state) },
            recipeShare: { state in recorder.recordRecipeShare(state) },
            tearDownSession: { recorder.recordTeardown() }
        )
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

    // MARK: - The zero wall (P7 item 3, pass B)

    /// Every spelling that MOVES a proximity radio, and which the app target may therefore name
    /// only inside `FernletApp.mountRoutedRunPolicy(_:)`'s door closures.
    ///
    /// Nine needles, chosen because each is a call the app used to make for itself:
    /// `ContentView.startFriendsDiscovery()` resolved a three-way into `startJoin()` or
    /// `resumeSearchingForPartitionedMesh()`, `stopFriendsDiscovery()` called `stopJoin()`,
    /// `updatePresenceListener()` and `updateRecipeShareListener()` called both listeners'
    /// `start()` / `stop()`, and `FernletStore` reached around all of it at three more sites.
    /// `applyRunState(` is here as the door's OWN spelling — the point of the wall is that it too
    /// has exactly one caller — and `armDiscoveryTimeout` is a pure zero-list: its successor is
    /// `MeshNetworkManager.armFriendRadios()`, and keeping both alive is what makes a retirement a
    /// fiction.
    static let radioCalls = [
        "startJoin()",
        "stopJoin()",
        "resumeSearchingForPartitionedMesh()",
        "presenceManager.start()",
        "presenceManager.stop()",
        "recipeShareManager.start()",
        "recipeShareManager.stop()",
        "applyRunState(",
        "armDiscoveryTimeout"
    ]

    /// The one file exempted BY NAME: the DEBUG rejection-matrix harness (runbook Lane C), whose
    /// `startJoin()` is compiled out of release entirely and gated on
    /// `MeshMatrixDebugOptions.isEnabled` at runtime.
    static let debugHarnessFile = "MeshRejectionMatrixHarness.swift"

    /// How many occurrences of ``radioCalls`` the mount's door closures are allowed to hold —
    /// MEASURED, never inherited: `stopJoin()`, `presenceManager.stop()` and
    /// `recipeShareManager.stop()` once each in the teardown door, plus `applyRunState(` three
    /// times (the mesh pair, presence, recipe).
    static let mountRadioCallCount = 6

    /// **The four proximity radios are driven from the run policy's doors and nowhere else**
    /// (P7 item 3, pass B — the retirement pass's wall).
    ///
    /// The claim has three parts and each is counted rather than asserted by file list alone:
    ///
    ///   * **Zero outside `FernletApp.swift`.** `ContentView` and `FernletStore` between them held
    ///     eight of these calls at pass A; both must now hold none, which is what makes
    ///     `ProximityRunPolicy` the single writer rather than a third opinion beside two others.
    ///   * **Containment, not adjacency.** Every surviving occurrence sits inside the brace-matched
    ///     body of `mountRoutedRunPolicy(`, and the total inside equals the total in the file — so a
    ///     tenth call added anywhere else in `FernletApp` reddens this even though the file list
    ///     stays at one element.
    ///   * **The DEBUG harness is exempt by NAME**, and the exemption is fixtured: the file is shown
    ///     to be in the sweep, to carry exactly the one `startJoin()` the exemption is written for,
    ///     and to guard it with `#if DEBUG`. An exemption that matches nothing is a hole nobody can
    ///     see.
    ///
    /// Non-vacuity first, and it names the two files the retirement is ABOUT: a sweep that stopped
    /// reaching `ContentView.swift` or `FernletStore.swift` would report a clean retirement of code
    /// it never read.
    @Test func theProximityRadiosAreDrivenOnlyFromTheHostsDoors() throws {
        let sources = try Self.appSources()
        #expect(!sources.isEmpty, "the App/ sweep found no Swift files at all")
        #expect(sources.contains(where: { $0.name == "ContentView.swift" }),
                "the sweep no longer reaches ContentView.swift")
        #expect(sources.contains(where: { $0.name == "FernletStore.swift" }),
                "the sweep no longer reaches FernletStore.swift")
        #expect(sources.contains(where: { $0.name == Self.debugHarnessFile }),
                "the exempted file is not in the sweep at all")
        var strays: [String] = []
        var inFernletApp = 0
        // R2: nine needles over the app target's own file list.
        for source in sources where source.name != Self.debugHarnessFile {
            for needle in Self.radioCalls {
                let hits = Self.occurrences(of: needle, in: source.code)
                guard hits > 0 else { continue }
                if source.name == "FernletApp.swift" {
                    inFernletApp += hits
                } else {
                    strays.append("\(source.name): \(needle) ×\(hits)")
                }
            }
        }
        #expect(strays.isEmpty, "a proximity radio is driven from outside the run policy's doors")
        #expect(inFernletApp == Self.mountRadioCallCount,
                "the number of radio calls in FernletApp moved without this pin moving")
    }

    /// The containment half of the wall, plus the DEBUG exemption's fixture.
    ///
    /// Split from the count above only to stay inside the 60-line rule; the two are one claim.
    @Test func everySurvivingRadioCallSitsInsideTheMountsDoors() throws {
        let appCode = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletApp.swift"))
        let mount = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func mountRoutedRunPolicy(", in: appCode),
            "the launch mount was renamed, or its brace-matched body does not close"
        )
        #expect(!mount.contains("private func restoreMeshSessionContextIfNeeded"),
                "the body matcher is measuring the file rather than the brace-matched mount")
        var insideMount = 0
        var inWholeFile = 0
        // R2: bounded by the needle list.
        for needle in Self.radioCalls {
            insideMount += Self.occurrences(of: needle, in: mount)
            inWholeFile += Self.occurrences(of: needle, in: appCode)
        }
        #expect(insideMount == Self.mountRadioCallCount, "the mount's door closures lost a radio call")
        #expect(insideMount == inWholeFile,
                "a radio call sits in FernletApp OUTSIDE the mount's door closures")
        let harness = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/Proximity/Feasibility/\(Self.debugHarnessFile)")
        )
        #expect(Self.occurrences(of: "startJoin()", in: harness) == 1,
                "the by-name exemption must match exactly the one call it was written for")
        #expect(harness.contains("#if DEBUG"),
                "the exempted call is no longer compiled out of release")
        #expect(harness.contains("MeshMatrixDebugOptions.isEnabled"),
                "the exempted call is no longer gated on the Lane C launch flag")
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
        let mount = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func mountRoutedRunPolicy(", in: appCode),
            "the launch mount was renamed, or its brace-matched body does not close"
        )
        #expect(mount.contains("runPolicyHost.connect("), "the launch mount no longer installs the doors")
        #expect(mount.contains("runPolicyHost.pushNow()"), "the launch mount no longer pushes")
        #expect(mount.contains("applyRoutedAccessGate("), "the injected door no longer reaches the seam")
        #expect(mount.contains("accessGate: { accessGate, now in"),
                "the door no longer names the gate it was handed")
        #expect(!mount.contains("MeshRoutedAccessGate("),
                "the door assembles a gate of its own again, so the policy is not the single writer")
        #expect(!mount.contains("restoreMeshSessionContextIfNeeded"),
                "the body matcher is measuring the file rather than the brace-matched mount")
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

    /// The launch sequence: legs set before the doors are installed are RECORDED and not written,
    /// connecting writes nothing by itself, and the first explicit push is the launch push — one
    /// push per seam, not one per leg that was seeded. What a SECOND `connect(…)` does is the next
    /// cell's claim.
    @Test func nothingIsWrittenUntilTheFirstExplicitPush() throws {
        let recorder = ProximityRunDoorRecorder()
        let host = ProximityRunPolicyHost()
        host.setScenePhase(.active)
        host.setProtectedDataAvailable(true)
        Self.connect(host, to: recorder)
        #expect(recorder.gates.isEmpty, "installing the doors must write nothing on its own")
        #expect(recorder.everyRadioDirective.isEmpty, "and must move no radio either")
        host.pushNow()
        #expect(recorder.gates.count == 1, "the first explicit push is the launch push")
        let launch = try #require(recorder.gates.last, "the launch push wrote nothing")
        #expect(launch.appIsForeground && launch.protectedDataAvailable,
                "the legs set before the doors were installed are carried into the launch push")
        #expect(recorder.presenceDirectives.count == 1,
                "the launch push is one push per seam, not one per leg that was seeded")
    }

    /// **A rebuilt store is re-mounted**: a second `connect(…)` re-points every door at the new
    /// set, and the old one stops receiving.
    ///
    /// `FernletStore` is never actually rebuilt in shipping — `FernletStoreLoader.retry()` re-enters
    /// only from `.failed`, when no store was ever built, and a delete-all rebuilds the Core Data
    /// stores UNDER the same `FernletStore` object rather than replacing it — so the second call
    /// this pins is in practice the ready view's `.onAppear` re-firing with the same store and
    /// handing back equivalent closures. The claim is worth a cell anyway, because the shape a
    /// one-shot latch would have produced is the dangerous one: doors still pointing at a dead
    /// store, with the wall that counts the call sites still green.
    @Test func aSecondConnectRePointsEveryDoorAtTheNewStore() {
        let first = ProximityRunDoorRecorder()
        let host = ProximityRunPolicyHost()
        Self.connect(host, to: first)
        host.pushNow()
        #expect(first.gates.count == 1, "the first mount's doors are live")
        let second = ProximityRunDoorRecorder()
        Self.connect(host, to: second)
        host.pushNow()
        #expect(second.gates.count == 1, "the re-mount's doors receive the next push")
        #expect(second.presenceDirectives.count == 1, "including every radio seam")
        #expect(second.teardowns == 0, "a re-mount is not a teardown")
        #expect(first.gates.count == 1, "and the replaced doors are never written to again")
    }

    // MARK: - The radios, through the injected seams

    /// **No seam ever sees `foregroundOnly`.** The host resolves every directive against the one
    /// foreground fact before it pushes, so a manager — which knows about neither scene phase —
    /// receives `run` or `stop` and nothing else.
    ///
    /// The claim is made over the WHOLE of ``legSteps``, which drives every setter the host declares
    /// and moves the scene three times, so it covers both resolutions of every `foregroundOnly`
    /// directive the policy can produce. `ProximityRunStateSeam.unresolved` exists for a caller that
    /// gets this wrong; this is the cell that says the only shipping caller does not.
    @Test func noRadioSeamEverReceivesAnUnresolvedDirective() {
        let (host, recorder) = Self.connectedHost()
        // R2: bounded by the literal step list.
        for entry in Self.legSteps {
            entry.step(host)
        }
        let directives = recorder.everyRadioDirective
        let everyDirectiveIsResolved = directives.allSatisfy { $0 != .foregroundOnly }
        let everyDirectiveIsRunOrStop = directives.allSatisfy { $0 == .run || $0 == .stop }
        #expect(!directives.isEmpty, "no radio was pushed at all, so the claim below is vacuous")
        #expect(everyDirectiveIsResolved,
                "a seam was handed foregroundOnly, which is a policy answer no manager can resolve")
        #expect(everyDirectiveIsRunOrStop, "a seam was handed something that is neither run nor stop")
        #expect(recorder.meshDirectives.count == Self.legSteps.count,
                "the mesh seam is pushed exactly once per leg update, like the gate")
        #expect(recorder.presenceDirectives.count == recorder.recipeShareDirectives.count,
                "the two listener seams are pushed in step")
    }

    /// The mesh door receives the PAIR the decision resolved — both directives together, because
    /// `startJoin()` / `stopJoin()` is one door for two radios.
    ///
    /// Hand-derived from the policy's own rules against a host that starts fail-closed, never
    /// re-computed from `ProximityRunPolicy.decide(_:)`. On the Friends tab, unlocked, foreground,
    /// with both consents on and no committed peer: mesh links and discovery/admission are each
    /// `foregroundOnly` (nothing is CPT-granted in P7), so both resolve UP; presence is
    /// `foregroundOnly` on Friends and resolves up; the recipe listener is `stop` on Friends, which
    /// is the row that shows the four radios really are decided separately. Backgrounding then puts
    /// all four down, and it is the RESOLUTION that does it — the directives never changed.
    @Test func theMeshDoorReceivesTheResolvedLinksAndDiscoveryPair() throws {
        let (host, recorder) = Self.connectedHost()
        host.setAppLockState(.unlocked)
        host.setAllowsNearbyPresence(true)
        host.setAllowsNearbyRecipeShares(true)
        host.setSelectedTab(.social)
        host.setScenePhase(.active)
        let up = try #require(recorder.meshDirectives.last, "the mesh seam was never pushed")
        let presenceUp = try #require(recorder.presenceDirectives.last, "presence was never pushed")
        let recipeUp = try #require(recorder.recipeShareDirectives.last, "recipe was never pushed")
        #expect(up.links == .run, "a Friends-tab foreground search runs the links")
        #expect(up.discovery == .run, "and the admission door with them")
        #expect(presenceUp == .run, "presence runs on the Friends tab")
        #expect(recipeUp == .stop, "and the recipe listener does not — its tab set excludes Friends")
        host.setScenePhase(.background)
        let down = try #require(recorder.meshDirectives.last, "the backgrounding leg pushed nothing")
        let presenceDown = try #require(recorder.presenceDirectives.last, "presence pushed nothing")
        #expect(down.links == .stop, "backgrounding resolves foregroundOnly links to stop")
        #expect(down.discovery == .stop, "and the admission door with them — invariant 5")
        #expect(presenceDown == .stop, "presence stops on background")
        #expect(recorder.teardowns == 0, "and none of that is a teardown")
    }

    /// **The teardown fires once on a RISE, and not again until the condition clears.**
    ///
    /// `tearsDownSession` is a LEVEL — a wipe holds it for the length of the funnel, a duress
    /// session until a real-passcode unlock — and every leg setter re-decides, so without the host's
    /// latch a tab switch mid-wipe would re-run the whole teardown (`stopJoin()`, both listener
    /// stops) on a mesh that is already down. The second half is the other failure: a latch that is
    /// never cleared would leave a second duress session in the same launch with no teardown at all.
    @Test func theTeardownFiresOnceOnARiseAndAgainOnlyAfterItClears() throws {
        let (host, recorder) = Self.connectedHost()
        host.setScenePhase(.active)
        #expect(recorder.teardowns == 0, "no dominating input is in force at launch")
        host.setDeletingAllData(true)
        #expect(recorder.teardowns == 1, "the wipe's rising edge tears the session down once")
        let wiping = try #require(recorder.meshDirectives.last, "the wipe pushed no mesh directive")
        #expect(wiping.links == .stop && wiping.discovery == .stop,
                "and every mesh radio is stood down in the same push")
        host.setSelectedTab(.social)
        host.setAllowsNearbyPresence(true)
        #expect(recorder.teardowns == 1, "a leg change under a standing wipe must not re-run it")
        host.setDeletingAllData(false)
        #expect(recorder.teardowns == 1, "and clearing the condition tears nothing down by itself")
        host.setAppLockState(.duress)
        #expect(recorder.teardowns == 2, "a fresh dominating input arms the latch again")
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
