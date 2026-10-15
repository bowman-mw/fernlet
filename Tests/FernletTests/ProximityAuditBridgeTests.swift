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
// The spelling the source walls over ProximityKit's code rely on (they count `ProximityAudit.log(`
// in the digest doors, or forbid `ProximityAudit` in the planner) is ProximityKit's to hold: its
// package suite of this name scans its code for `FernletAuditLog`, so a line that bypassed the sink
// could not hide from them under the old spelling (since plan step A1.3, when the sources left).
//
// Nothing here installs a sink. The process-wide slot is the app's, and a test that replaced it
// would silence or redirect ProximityKit's lines for every suite running beside it. So this suite also
// holds who may install one in Fernlet's trees: Fernlet's app, at launch, and no file of Fernlet's
// modules or test targets. It reads every spelling of the installer's name, a reference included, and
// refuses an extension of ProximityAudit, an alias for it and its metatype, through which a bare or
// aliased `install` would reach the slot unseen. ProximityKit's sources and its own package tests are
// its repository's to hold (since plan step A1.3): its `PackageTestTreeWallTests` holds their installer
// (TestSupport/PackageTestEnvironment.swift) to one install, for their unhosted bundle, which no app
// hosts, and ProximityKit's code to none.

import Foundation
import os
import Testing
import FernletConnections
import FernletFoundation
@testable import ProximityKit

/// The installed bridge delivers a ProximityKit audit line to a `FernletAuditLog` capture handler
/// verbatim and before the emitting call returns, and only Fernlet's app installs a sink.
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

    // MARK: - Who installs a sink (ProximityKit plan step A1.1)

    /// The roots the install-site scan reads, each with the fewest Swift files it may hold (about four
    /// fifths of its count when measured: 264 and 485 when the cell was written, and 288 under
    /// FernletKit/Sources but ProximityKit's own at plan step A1.1.14, 289 once they left at A1.3), so
    /// a root that stops resolving fails rather than reading as clean: the app and its extensions,
    /// FernletKit's sources, and Fernlet's test targets. ProximityKit is a package dependency, not one
    /// of these roots: its sources and its package tests are its own `PackageTestTreeWallTests`' to
    /// read.
    static let installSiteRoots: [(root: String, floor: Int)] = [
        (root: "App", floor: 210), (root: "FernletKit/Sources", floor: 230), (root: "Tests", floor: 385)
    ]

    /// The files that install a sink, each with its one call: Fernlet's app, first thing in
    /// `FernletApp.init`.
    static let installSites: [String: Int] = ["App/Fernlet/FernletApp.swift": 1]

    /// `FernletKit/Tests` holds no Swift file: Fernlet's walls over its test trees (this audit wall, the
    /// two store isolation walls, the acceptance batteries' test-tree scans and ML5) read `Tests`, so a
    /// FernletKit test target would be read by none of them. Such a target fails here until the walls
    /// that must read it are decided. (ProximityKit's package tests lived there from plan step A0.8 and
    /// left with the package at A1.3; this cell's floor-holding walk over them went with them, and the
    /// install-site roots' own floors hold the walker.)
    static func expectFernletKitHoldsNoTestTarget() {
        let files = PowerOfTenBoundaryTests.swiftFiles(under: "FernletKit/Tests", repoRoot: RepoRoot.url)
        #expect(files.isEmpty, """
            FernletKit/Tests holds Swift files: \(files). No wall reads them: Fernlet's test-tree walls \
            read Tests. Decide which walls read the new target, and widen their roots, before adding it.
            """)
    }

    /// `ProximityAudit.install` is named exactly once in Fernlet's app, and in no other file Fernlet
    /// holds: no file of Fernlet's modules, and none of Fernlet's test targets, so this hosted bundle
    /// runs on the bridge `FernletApp.init` installed, which every capture handler here reads through. A
    /// reference with no call counts, since a later call could apply it. No code here extends
    /// `ProximityAudit`, aliases it or takes its metatype: inside such an extension a bare `install(`
    /// names the slot, and through an alias or a metatype an `install` call no longer spells the type, so
    /// either would reach the slot unseen. Read as lexed code (`SwiftSourceLexer`), so a comment or a
    /// string that spells the name is not one, over every root at its file floor (ProximityKit's sources
    /// are none of them: its own `PackageTestTreeWallTests` holds them, the declaration's file among
    /// them, and its package tests' one install), with the matchers held to their samples and neighbours
    /// first. And `FernletKit/Tests` holds no Swift file (``expectFernletKitHoldsNoTestTarget()``), the
    /// root none of these walls reads.
    @Test func onlyTheAppInstallsAnAuditSink() throws {
        Self.expectTheInstallMatchersSeeTheirSamplesAndNoNeighbour()
        Self.expectFernletKitHoldsNoTestTarget()
        var sites: [String: Int] = [:]
        var aliases: [String] = []
        // R2: bounded by the three roots and each root's finite file list.
        for (root, floor) in Self.installSiteRoots {
            let files = PowerOfTenBoundaryTests.swiftFiles(under: root, repoRoot: RepoRoot.url)
            #expect(files.count >= floor, "the install-site scan saw \(files.count) Swift files under \(root), below its floor \(floor)")
            for path in files {
                let source = try RepoRoot.source(path)
                guard source.contains("ProximityAudit") else { continue }
                let code = SwiftSourceLexer.lex(source).code
                let calls = Self.installCalls(in: code)
                if calls > 0 {
                    sites[path] = calls
                }
                aliases += Self.auditAliasLines(in: code).map { "\(path):\($0)" }
            }
        }
        #expect(sites == Self.installSites, """
            `ProximityAudit.install` is named in \(sites.sorted { $0.key < $1.key }); only \
            \(Self.installSites.keys.sorted()) may name it, once. A sink installed by a Fernlet test \
            replaces the app's bridge for every suite running beside it, and one installed by a Fernlet \
            module replaces it for the whole app.
            """)
        #expect(aliases.isEmpty, """
            `ProximityAudit` is extended, aliased or taken as a metatype at \(aliases); no file Fernlet \
            holds may do any of the three, since a bare `install(` in an extension, or an `install` through \
            an alias or a metatype, reaches the sink's slot by a spelling the install count cannot see.
            """)
    }

    /// The spellings of `ProximityAudit.install` in lexed `code`, a call or a reference, the type and its
    /// member read across whitespace and line breaks, or -1, which no file and no sample yields, when the
    /// pattern does not compile.
    static func installCalls(in code: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])ProximityAudit\s*\.\s*install(?![A-Za-z0-9_])"#) else {
            return -1
        }
        return regex.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// The 1-based lines of lexed `code` that extend `ProximityAudit`, alias it or take its metatype,
    /// qualified by its module or not, or `[-1]`, which no file and no sample yields, when the pattern
    /// does not compile. A longer name holding it (`ProximityAuditSink`) is not one.
    static func auditAliasLines(in code: String) -> [Int] {
        let pattern = #"(?<![A-Za-z0-9_])extension\s+(?:ProximityKit\s*\.\s*)?ProximityAudit\b"#
            + #"|(?<![A-Za-z0-9_])typealias\s+\w+\s*=\s*(?:ProximityKit\s*\.\s*)?ProximityAudit\b"#
            + #"|(?<![A-Za-z0-9_])ProximityAudit\s*\.\s*self\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [-1] }
        let text = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: text.length)).map {
            text.substring(to: $0.range.location).count(where: { $0 == "\n" }) + 1
        }
    }

    /// The install matcher reads every way the name is spelled, a call and a reference, and none of its
    /// nearest neighbours (a longer name, the declaration, another member, a comment, a string); the alias
    /// matcher reads an extension of the type, an alias for it and its metatype, and none of the sink
    /// protocol's. Each sample is lexed first, as the files are.
    private static func expectTheInstallMatchersSeeTheirSamplesAndNoNeighbour() {
        let calls = [
            "ProximityAudit.install(FernletAuditBridge())", "ProximityAudit\n    .install(sink)",
            "ProximityKit.ProximityAudit.install(sink)", "ProximityAudit . install (sink)",
            "let put = ProximityAudit.install", "[sink].forEach(ProximityAudit.install)"
        ]
        let neither = [
            "nonisolated public static func install(_ sink: any ProximityAuditSink) {", "MyProximityAudit.install(sink)",
            "ProximityAudit.installed(sink)", "ProximityAudit.log(\"install\")", "/// ProximityAudit.install(sink)",
            #"let s = "ProximityAudit.install(sink)""#
        ]
        let aliases = [
            "extension ProximityAudit {", "extension ProximityKit.ProximityAudit {", "typealias PA = ProximityAudit",
            "let t = ProximityAudit.self"
        ]
        let notAliases = ["extension ProximityAuditSink {", "typealias S = ProximityAuditSink", "/// extension ProximityAudit {"]
        // R2: bounded by the four fixture lists.
        for sample in calls {
            #expect(installCalls(in: SwiftSourceLexer.lex(sample).code) == 1, "missed the call in: \(sample)")
        }
        for neighbour in neither {
            #expect(installCalls(in: SwiftSourceLexer.lex(neighbour).code) == 0, "read a call in: \(neighbour)")
        }
        for sample in aliases {
            #expect(auditAliasLines(in: SwiftSourceLexer.lex(sample).code) == [1], "missed the alias in: \(sample)")
        }
        for neighbour in notAliases {
            #expect(auditAliasLines(in: SwiftSourceLexer.lex(neighbour).code).isEmpty, "read an alias in: \(neighbour)")
        }
    }
}
