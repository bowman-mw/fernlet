// ProximitySessionPollerTests.swift
// FernletTests
//
// Network migration P7 item 4: the app's half of the poller — the start/stop rule as a table, the
// interval and its bound, and the wall that keeps the timer to one place: one caller of
// `pollSession(now:)`, one stored handle, one sync inside the run-policy core, one liveness observer.

import Foundation
import Testing
import ProximityKit
@testable import Fernlet

/// The poller's decision table and its wall.
@Suite struct ProximitySessionPollerTests {

    /// A timer if and only if a live session.
    @Test func theTimerRuleIsATimerIffALiveSession() {
        #expect(ProximitySessionPoller.decision(isSessionLive: true, isPolling: false) == .start,
                "a session came alive with no timer: start one")
        #expect(ProximitySessionPoller.decision(isSessionLive: false, isPolling: true) == .stop,
                "the session is gone and a timer runs: stop it")
        #expect(ProximitySessionPoller.decision(isSessionLive: true, isPolling: true) == .keep,
                "a live session with its timer: nothing to do")
        #expect(ProximitySessionPoller.decision(isSessionLive: false, isPolling: false) == .keep,
                "no session and no timer: nothing spins")
        #expect(ProximitySessionPoller.Decision.allCases.count == 3, "three answers, all reachable")
    }

    /// The interval and the loop bound are the ceiling's, in ticks.
    @Test func theIntervalAndTheBoundAreTheCeilingsInTicks() {
        #expect(ProximitySessionPoller.interval == 30, "30 s — coarse enough for nothing to spin, fine enough for the 30-minute idle stop")
        #expect(ProximitySessionPoller.maxTicks == 721, "6 h of 30 s ticks, plus one — a session cannot outlive its ceiling")
        #expect(Double(ProximitySessionPoller.maxTicks - 1) * ProximitySessionPoller.interval == MeshSessionCeiling.ceilingSeconds,
                "the bound is derived from the ceiling, not a second number")
    }

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

    /// **The wall.** One caller of the poll seam, one stored handle, one timer construction, one
    /// sync inside the run-policy core, one liveness observer — and the loop bounded by the ceiling.
    @Test func thePollerHasOneTimerOneCallerAndOneObserver() throws {
        let sources = try Self.appSources()
        #expect(sources.count >= 100, "the app-target scan lost its files")
        #expect(Self.homes(of: ".pollSession(", in: sources) == ["ProximitySessionPoller.swift"],
                "the poll seam is driven from exactly one place in the app")
        #expect(Self.homes(of: "sessionPollTask = Task", in: sources) == ["ProximitySessionPoller.swift"],
                "and the one timer is constructed exactly once, there")
        #expect(Self.homes(of: "var sessionPollTask", in: sources) == ["FernletStore.swift"],
                "while its handle lives on the composition root, which the memory-lifecycle wall exempts by invariant")
        let poller = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ProximitySessionPoller.swift"))
        #expect(poller.contains("for _ in 0..<ProximitySessionPoller.maxTicks"),
                "the loop is bounded by the ceiling in ticks, never `while true`")
        #expect(poller.contains("if !report.sessionLiveAfter"),
                "and a poll that reports the session gone stops the timer from inside")
        let store = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletStore.swift"))
        let core = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func runProximityPolicy(", in: store),
            "the run-policy core is gone"
        )
        #expect(core.contains("syncSessionPoller()"), "the core syncs the timer after every edge, after the seams")
        let view = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ContentView.swift"))
        #expect(view.contains("onChange(of: store.meshNetworkManager.isSessionLive)"),
                "and the view observes session liveness so a session founded or ended between edges reaches the timer")
    }
}
