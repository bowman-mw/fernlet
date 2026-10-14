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
// would silence or redirect ProximityKit's lines for every suite running beside it. So this suite also
// holds who may install one: Fernlet's app, at launch, and ProximityKit's own package tests' installer
// (FernletKit/Tests/ProximityKitTests/TestSupport/PackageTestEnvironment.swift), once, for their
// unhosted bundle, which no app hosts; no file of Fernlet's test targets.

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

    // MARK: - Who installs a sink (ProximityKit plan step A1.1)

    /// The roots the install-site scan reads, each with the fewest Swift files it may hold (about four
    /// fifths of its count when the cell was written: 264, 423, 485 and 23), so a root that stops
    /// resolving fails rather than reading as clean: the app and its extensions, the package's sources,
    /// Fernlet's test targets and the package's tests.
    static let installSiteRoots: [(root: String, floor: Int)] = [
        (root: "App", floor: 210), (root: "FernletKit/Sources", floor: 335), (root: "Tests", floor: 385),
        (root: "FernletKit/Tests", floor: 18)
    ]

    /// The files that install a sink, each with its one call: Fernlet's app, first thing in
    /// `FernletApp.init`, and ProximityKit's package tests' installer, `PackageTestEnvironment.audit`,
    /// once, for their unhosted bundle.
    static let installSites: [String: Int] = [
        "App/Fernlet/FernletApp.swift": 1,
        "FernletKit/Tests/ProximityKitTests/TestSupport/PackageTestEnvironment.swift": 1
    ]

    /// `ProximityAudit.install(` is called exactly once in each of two files, Fernlet's app and the package
    /// tests' installer, and in no other: no file of Fernlet's test targets, so this hosted bundle runs on
    /// the bridge `FernletApp.init` installed, which every capture handler here reads through, and no
    /// package suite replaces the sink its installer put in place. Read as lexed code
    /// (`SwiftSourceLexer`), so a comment or a string that spells the call is not one, over every root at
    /// its file floor, with the matcher held to its samples and neighbours first.
    @Test func onlyTheAppAndThePackageTestsInstallerInstallASink() throws {
        Self.expectTheInstallMatcherSeesItsSamplesAndNoNeighbour()
        var sites: [String: Int] = [:]
        // R2: bounded by the four roots and each root's finite file list.
        for (root, floor) in Self.installSiteRoots {
            let files = PowerOfTenBoundaryTests.swiftFiles(under: root, repoRoot: RepoRoot.url)
            #expect(files.count >= floor, "the install-site scan saw \(files.count) Swift files under \(root), below its floor \(floor)")
            for path in files {
                let source = try RepoRoot.source(path)
                guard source.contains("install") else { continue }
                let calls = Self.installCalls(in: SwiftSourceLexer.lex(source).code)
                if calls > 0 {
                    sites[path] = calls
                }
            }
        }
        #expect(sites == Self.installSites, """
            `ProximityAudit.install(` is called in \(sites.sorted { $0.key < $1.key }); only \
            \(Self.installSites.keys.sorted()) may call it, once each. A sink installed by a Fernlet test \
            replaces the app's bridge for every suite running beside it, and a second install in the \
            package's tests replaces the sink every package capture reads.
            """)
    }

    /// The calls of `ProximityAudit.install(` in lexed `code`, the type and its member read across
    /// whitespace and line breaks, or -1, which no file and no sample yields, when the pattern does not
    /// compile.
    static func installCalls(in code: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])ProximityAudit\s*\.\s*install\s*\("#) else {
            return -1
        }
        return regex.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// The install matcher reads every way the call is spelled and none of its nearest neighbours (a
    /// longer name, the declaration, another member, a comment, a string). Each sample is lexed first,
    /// as the files are.
    private static func expectTheInstallMatcherSeesItsSamplesAndNoNeighbour() {
        let calls = [
            "ProximityAudit.install(FernletAuditBridge())", "ProximityAudit\n    .install(sink)",
            "ProximityKit.ProximityAudit.install(sink)", "ProximityAudit . install (sink)"
        ]
        let neither = [
            "nonisolated public static func install(_ sink: any ProximityAuditSink) {", "MyProximityAudit.install(sink)",
            "ProximityAudit.installed(sink)", "ProximityAudit.log(\"install\")", "/// ProximityAudit.install(sink)",
            #"let s = "ProximityAudit.install(sink)""#
        ]
        // R2: bounded by the two fixture lists.
        for sample in calls {
            #expect(installCalls(in: SwiftSourceLexer.lex(sample).code) == 1, "missed the call in: \(sample)")
        }
        for neighbour in neither {
            #expect(installCalls(in: SwiftSourceLexer.lex(neighbour).code) == 0, "read a call in: \(neighbour)")
        }
    }
}
