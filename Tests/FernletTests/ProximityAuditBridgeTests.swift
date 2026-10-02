// ProximityAuditBridgeTests.swift
// FernletTests
//
// ProximityKit plan step A0.2, the audit sink: ProximityKit writes every audit line through
// `ProximityAudit.log(_:context:)` to the sink its host installs, and drops the line while none is
// installed. Fernlet's sink is `FernletAuditBridge` (FernletConnections), installed first thing in
// `FernletApp.init`. This suite is the canary for that install. The 25 test files that capture
// ProximityKit events do so through `FernletAuditLog.addCaptureHandler`, and many of their
// assertions are NEGATIVE ("no `mesh.routedProjection.noDispatchArm` line was logged"): with the
// bridge missing, no ProximityKit line would reach `FernletAuditLog` at all, every one of those
// would pass vacuously, and only this suite would go red.
//
// It also holds the spelling the re-pointed source walls rely on (`MeshRoutedRefusalBudgetTests`
// counts `ProximityAudit.log(` in the digest doors, `MeshRoutedRetryPlanTests` forbids
// `ProximityAudit` in the planner): ProximityKit code names `FernletAuditLog` nowhere, so a line
// that bypassed the sink could not hide from them under the old spelling.
//
// Nothing here installs a sink. The process-wide slot is the app's, and a test that replaced it
// would silence or redirect ProximityKit's lines for every suite running beside it.

import Foundation
import os
import Testing
import FernletConnections
import FernletFoundation
@testable import ProximityKit

/// The installed bridge delivers a ProximityKit audit line to a `FernletAuditLog` capture handler
/// verbatim and before the emitting call returns, and ProximityKit has no other way to audit.
@Suite struct ProximityAuditBridgeTests {

    /// One `FernletAuditLog` line as a capture handler saw it.
    private struct Line: Equatable, Sendable {
        /// The event name.
        let event: String
        /// The context dictionary.
        let context: [String: String]
    }

    /// The emitting cell's own mark, bound only around its emitting call.
    ///
    /// Task-local, so a handler sees it only inside that call or in a task the call created: a sink
    /// that hopped to a detached task or a dispatch queue would deliver the line where the mark is
    /// unbound, and one that deferred it into a new task would deliver it after the cell has read
    /// its capture, so either way the cell sees nothing. It also scopes each cell's capture, since
    /// the capture registry is process-global and suites run in parallel.
    @TaskLocal private static var emitter: UUID?

    /// Every `FernletAuditLog` line a capture handler saw while `emit` ran inside this call's own
    /// task-local scope, read the moment `emit` returns, with no suspension between the two.
    ///
    /// - Parameter emit: The synchronous emitting call.
    /// - Returns: The lines delivered during `emit`, in order.
    private func linesDelivered(during emit: () -> Void) -> [Line] {
        let mark = UUID()
        let seen = OSAllocatedUnfairLock<[Line]>(initialState: [])
        let token = FernletAuditLog.addCaptureHandler { event, context in
            guard Self.emitter == mark else { return }
            seen.withLock { $0.append(Line(event: event, context: context)) }
        }
        defer { FernletAuditLog.removeCaptureHandler(token) }
        Self.$emitter.withValue(mark) { emit() }
        return seen.withLock { $0 }
    }

    /// **The canary.** A line ProximityKit logs reaches `FernletAuditLog`'s capture handlers through
    /// the bridge `FernletApp.init` installed: once, with its event name and every context key and
    /// value unchanged, before `ProximityAudit.log` returns.
    @Test func aProximityKitAuditLineReachesFernletAuditLogVerbatimBeforeTheCallReturns() {
        let context = [
            "held": UUID().uuidString, "peer": "0a1b2c3d4e5f", "reason": "canary", "count": "3"
        ]
        let lines = linesDelivered {
            ProximityAudit.log("proximityAudit.bridge.canary", context: context)
        }
        #expect(lines == [Line(event: "proximityAudit.bridge.canary", context: context)], """
            a ProximityKit audit line did not reach FernletAuditLog's capture handlers as one \
            unchanged line before the call returned (saw \(lines)). Either `FernletApp.init` no \
            longer installs `FernletAuditBridge` (then every ProximityKit line in this process is \
            dropped, and every test asserting an event was NOT logged passes vacuously), or the \
            sink it installs rewrites, buffers or hops instead of forwarding in line.
            """)
    }

    /// A bare event, logged with the `context` default (122 of ProximityKit's 427 call sites when
    /// the sink landed), arrives with an empty context, not an altered one.
    @Test func aBareProximityKitAuditLineArrivesWithAnEmptyContext() {
        let lines = linesDelivered { ProximityAudit.log("proximityAudit.bridge.bare") }
        #expect(lines == [Line(event: "proximityAudit.bridge.bare", context: [:])],
                "a bare ProximityKit audit line arrived as \(lines)")
    }

    /// The bridge on its own, whatever the slot holds: one `record` is one `FernletAuditLog` line,
    /// unchanged, delivered in line. When the canary is red and this is green, the bridge works and
    /// the install is what is missing.
    @Test func theBridgeForwardsOneLineUnchangedInLine() {
        let context = ["state": "joining", "items": "2", "saturated": "false"]
        let lines = linesDelivered {
            FernletAuditBridge().record("proximityAudit.bridge.direct", context: context)
        }
        #expect(lines == [Line(event: "proximityAudit.bridge.direct", context: context)],
                "FernletAuditBridge forwarded \(lines)")
    }

    /// ProximityKit code names `FernletAuditLog` nowhere: every audit line in the module goes
    /// through the host's sink, spelled `ProximityAudit.log(`.
    ///
    /// The source walls that count or forbid audit lines read that one spelling, so a line written
    /// straight to `FernletAuditLog` would bypass the sink AND hide from them. Comments may still
    /// name it (three doc comments explain its redaction and its process-global registry); the scan
    /// reads code lines only.
    @Test func proximityKitCodeNamesFernletAuditLogNowhere() throws {
        let root = RepoRoot.url("FernletKit/Sources/ProximityKit")
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        var sinkCalls = 0
        var offenders: [String] = []
        // R2: bounded by the module's own file list.
        for file in files.sorted(by: { $0.path < $1.path }) {
            let code = MeshRoutedSourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8))
            sinkCalls += code.components(separatedBy: "ProximityAudit.log(").count - 1
            if code.contains("FernletAuditLog") {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(files.count >= 50, "the ProximityKit sweep read only \(files.count) Swift files")
        #expect(sinkCalls > 0, "the sweep found no `ProximityAudit.log(` call: wrong tree?")
        #expect(offenders.isEmpty, """
            ProximityKit code names FernletAuditLog in \(offenders). Audit through \
            `ProximityAudit.log(_:context:)`, which reaches Fernlet's log through the installed \
            bridge and every other host's sink too.
            """)
    }
}
