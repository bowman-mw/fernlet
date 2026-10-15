// TestHookBoundaryTests.swift
// FernletTests
//
// The grep-wall for debug/test hooks, sibling of the S3, no-tracking, Power-of-10 and
// memory-lifecycle walls:
//
//  TH1  Every non-comment source line in a shipping root that reads
//       a launch hook from any of the six families in `hookTokens` — Fernlet's `FERNLET_UI_TEST_`,
//       `FERNLET_SKIP_`, `FERNLET_MESH`, `FERNLET_PROBE` and ProximityKit's `PROXIMITYKIT_UI_TEST_`,
//       `PROXIMITYKIT_MESH` — must sit inside an open `#if DEBUG` region.
//  TH2  `UITestSupport`'s `#else` block must define a no-op for every `static var` its `#if DEBUG`
//       block declares, so a flag added to only one half cannot break the Release build (or, worse,
//       be silently missing while the file's header claims completeness).
//
// Why a wall rather than a one-time fix: these hooks fabricate answers the app then treats as real —
// a canned `DeletionResult` for the "delete my cloud data" screen, a mock existing-cloud-data
// detector whose answer decides the durable `cloudCopyKept` flag, a synthetic `MeshDescriptor`, a
// skip of the sealed-backup restore/upload pass. In a shipping binary they must be ABSENT, not
// merely unreachable: nothing for a reverse-engineer to find and nothing an environment can reach.
// The precedent is `CloudKitSync/Persistence.swift`, which DEBUG-wraps `INITIALIZE_CLOUDKIT_SCHEMA`
// at both definition and call site (Docs/CloudKit-Schema-Deploy.md).
//
// The `FERNLET_MESH_*` / `FERNLET_PROBE_*` families joined the wall in P2 item 14. They arrived
// (items 0/8/9) with `#if DEBUG` as their ONLY guard, which is the same "correct today, unenforced
// tomorrow" position the UI-test flags were in before TH1 existed — and they are the more dangerous
// half: `FERNLET_MESH_TRANSPORT` selected a whole radio until the deletion round, the chaos keys make
// this device misbehave during a signed handshake and write the roster's barred set, and
// `FERNLET_MESH_MATRIX*` seeds a synthetic mesh descriptor and joins it at launch. All fourteen
// reads were already inside `#if DEBUG` when the wall was widened; the point of widening is that the
// fifteenth cannot be added outside one.
//
// ProximityKit's keys are two families of their own since plan step A1.0, when the package took its
// own name for them: `PROXIMITYKIT_UI_TEST_`, the three flags its mesh manager seeds a canned mesh
// from (`PROXIMITYKIT_UI_TEST_MESH_OPEN`, `_CLOSED`, `_ADMISSION`), and `PROXIMITYKIT_MESH`, its
// transport's console mirror and the two chaos keys (`PROXIMITYKIT_MESH_CONSOLE_LOG`,
// `PROXIMITYKIT_MESH_CHAOS`, `PROXIMITYKIT_MESH_CHAOS_BARRED`), which the app's rejection-matrix
// banner echoes. ProximityKit's own reads of them are its own package suite's to hold
// (`ProximitySourceWallTests`, since plan step A1.1.15); ProximityKit is a package dependency since
// plan step A1.3, not one of this repository's shipping roots, and TH1 holds what Fernlet's own code
// reads of the two families to the same rule: the banner's two echoes, and any app-side read of a
// UI-test flag, of which there is none today.
//
// The scan discovers its inputs from the file system and carries hard FLOORS — global and PER
// FAMILY, so a matcher that stops seeing one family cannot hide behind the others (a moved root
// or a broken matcher must fail loudly, never pass vacuously — the S3BoundaryTests house rule) — and
// the checker must trip on a planted token from every family.

import Foundation
import Testing

/// Grep-wall proving no debug/test launch hook survives into a Release build.
struct TestHookBoundaryTests {

    // MARK: - Scope and floors

    /// The five shipping roots — same set as the Power-of-10 scanner's `SHIPPING_ROOTS`, which
    /// `PowerOfTenBoundaryTests.everyShippingCodeWallScansEveryShippingRoot()` now enforces (the
    /// Messages extension was missing here until 2026-09-23).
    static let shippingRoots = [
        "FernletKit/Sources", "App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension",
        "App/FernletMessagesExtension"
    ]

    /// Floor for the shipping scan (367 files when it was written, 552 since plan step A1.1.15 left
    /// ProximityKit's 135 to its own package suite); a root that stops resolving trips it.
    static let minimumShippingFilesScanned = 300

    /// Real (non-comment) hook reads today: **64** across the six families (measured 2026-10-14, when
    /// plan step A1.1.15 left ProximityKit's own six to its package suite; 70 on 2026-10-11, when plan
    /// step A1.0 moved eight of them to ProximityKit's two families and added or removed none).
    /// A wall that finds fewer has stopped looking — comment stripping or the token matcher has broken.
    static let minimumHookLines = 40

    /// The tokens that name a debug/test launch hook: Fernlet's four families, then ProximityKit's two.
    ///
    /// The mesh families are matched WITHOUT a trailing underscore (`FERNLET_MESH` and
    /// `PROXIMITYKIT_MESH`, not `FERNLET_MESH_`) so a bare future `FERNLET_MESH` cannot slip past the
    /// prefix. That is safe against double-counting because `hookReads` records one read per LINE
    /// however many tokens match, to the first family in this list it names. No hook's name holds
    /// another family's token (a `…_UI_TEST_MESH_*` flag holds `MESH` but neither mesh token), so the
    /// order decides only a line that names two families: the one such line, `UITestSupport`'s harness
    /// check over both UI-test prefixes, counts once, toward `FERNLET_UI_TEST_`.
    static let hookTokens = [
        "FERNLET_UI_TEST_", "FERNLET_SKIP_", "FERNLET_MESH", "FERNLET_PROBE",
        "PROXIMITYKIT_UI_TEST_", "PROXIMITYKIT_MESH"
    ]

    /// Per-family floors. Fernlet's are each comfortably below today's real count (39 / 8 / 12 / 3,
    /// measured 2026-10-11: plan step A1.0 moved ProximityKit's three UI-test flags and its five
    /// console and chaos reads, the app banner's two among them, to its own families, 42 - 3 and
    /// 17 - 5; the mesh family measured 18 on 2026-09-12 and lost `FERNLET_MESH_TRANSPORT`'s
    /// declaration in the deletion round, 2026-09-22), and they do not move for an ADDED hook — only
    /// for a removed family. ProximityKit's are what Fernlet's own code reads of its keys, MEASURED
    /// 2026-10-14, when plan step A1.1.15 left ProximityKit's own reads to its package suite (3 / 5
    /// before): `PROXIMITYKIT_MESH` 2, the app's rejection-matrix banner's echoes of the two chaos
    /// keys, exact, so an echo that leaves fails here by family until its floor is lowered in the same
    /// commit; and `PROXIMITYKIT_UI_TEST_` 0, since no Fernlet line reads a UI-test flag of
    /// ProximityKit's (`UITestSupport`'s harness check names the prefix and counts toward
    /// `FERNLET_UI_TEST_`). The token stays at floor 0 so that TH1 still refuses an app-side read of
    /// one outside `#if DEBUG`; no other rule would, and its two samples below hold the matcher to it.
    ///
    /// The global floor above cannot catch a matcher that loses one family: drop every mesh and
    /// probe read and 47 remain, comfortably past it. These are what make each family's membership
    /// in the wall load-bearing rather than decorative, but `PROXIMITYKIT_UI_TEST_`'s: at floor 0,
    /// only its two samples hold it.
    static let hookTokenFloors: [String: Int] = [
        "FERNLET_UI_TEST_": 25, "FERNLET_SKIP_": 5, "FERNLET_MESH": 7, "FERNLET_PROBE": 2,
        "PROXIMITYKIT_UI_TEST_": 0, "PROXIMITYKIT_MESH": 2
    ]

    /// `UITestSupport`, whose two halves TH2 pins against each other.
    static let uiTestSupportFile = "App/Fernlet/UITestSupport.swift"

    // MARK: - Scan

    /// One hook read: where it is, which family named it, and whether a `#if DEBUG` region was open
    /// at that point.
    struct HookRead: Hashable, Sendable {
        let path: String
        let line: Int
        let text: String
        /// The first entry of ``hookTokens`` this line matched — the family it counts toward.
        let token: String
        let insideDebug: Bool
    }

    /// The whole shipping scan: every hook read plus anything that could not be read.
    struct TreeScan: Sendable {
        var filesScanned: [String] = []
        var reads: [HookRead] = []
        var unreadable: [String] = []
    }

    static let sharedScan: TreeScan = scan(repoRoot: RepoRoot.url)

    /// Scans the five shipping roots. ProximityKit's reads are its own package suite's,
    /// `ProximitySourceWallTests`, which holds them to the same rule. Never throws or traps: unreadable
    /// files are listed for the enforcement tests to fail on.
    static func scan(repoRoot: URL) -> TreeScan {
        var result = TreeScan()
        for root in shippingRoots {
            for path in PowerOfTenBoundaryTests.swiftFiles(under: root, repoRoot: repoRoot) {
                guard let source = try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8) else {
                    result.unreadable.append(path)
                    continue
                }
                result.filesScanned.append(path)
                result.reads.append(contentsOf: hookReads(for: path, source: source))
            }
        }
        return result
    }

    /// Every hook read in one file, each tagged with whether a DEBUG region was open.
    ///
    /// Comment stripping is load-bearing: most textual matches in the tree are `//`/`///` prose (the
    /// `UITestSupport` doc block alone holds ~20), and a wall that counted those would be satisfied
    /// by documentation while real reads shipped. Its one known narrowness, ProximityKit's copy's
    /// too: a line that opens with `/*` is skipped whole, so code after a `*/` on that same line is not
    /// read.
    static func hookReads(for path: String, source: String) -> [HookRead] {
        var reads: [HookRead] = []
        var regions: [Bool] = []          // one entry per open `#if`; true when it is a DEBUG region
        var inBlockComment = false
        for (index, rawLine) in source.components(separatedBy: "\n").enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if inBlockComment {
                if trimmed.contains("*/") { inBlockComment = false }
                continue
            }
            if trimmed.hasPrefix("/*") {
                if !trimmed.contains("*/") { inBlockComment = true }
                continue
            }
            updateRegions(&regions, with: trimmed)
            guard !trimmed.hasPrefix("//") else { continue }
            guard let token = hookTokens.first(where: { trimmed.contains($0) }) else { continue }
            reads.append(HookRead(path: path, line: index + 1, text: String(trimmed.prefix(120)),
                                  token: token, insideDebug: regions.contains(true)))
        }
        return reads
    }

    /// Tracks the `#if` stack. A condition counts as DEBUG when it names `DEBUG` as a whole word, so
    /// `#if DEBUG && canImport(UIKit)` counts and a bare `#if canImport(UIKit)` does not; `#else` /
    /// `#elseif` leave the DEBUG region (the Release half of the same directive).
    private static func updateRegions(_ regions: inout [Bool], with trimmed: String) {
        if trimmed.hasPrefix("#if") {
            regions.append(namesDebug(trimmed))
        } else if trimmed.hasPrefix("#elseif") {
            if !regions.isEmpty { regions[regions.count - 1] = namesDebug(trimmed) }
        } else if trimmed.hasPrefix("#else") {
            if !regions.isEmpty { regions[regions.count - 1] = false }
        } else if trimmed.hasPrefix("#endif") {
            if !regions.isEmpty { regions.removeLast() }
        }
    }

    /// Whether a `#if`/`#elseif` condition names `DEBUG` as a whole word (never `NOT_DEBUG_X`).
    private static func namesDebug(_ directive: String) -> Bool {
        let separators = CharacterSet(charactersIn: " \t()!&|,")
        return directive.components(separatedBy: separators).contains("DEBUG")
    }

    // MARK: - Floors

    /// The roots resolve and the enumerator found a shipping-sized tree; unreadable files fail loudly.
    @Test func scanFloorsHold() {
        let scan = Self.sharedScan
        #expect(scan.unreadable.isEmpty, "Unreadable shipping files: \(scan.unreadable)")
        #expect(scan.filesScanned.count >= Self.minimumShippingFilesScanned,
                "Scanned only \(scan.filesScanned.count) files (floor \(Self.minimumShippingFilesScanned)) — a shipping root stopped resolving; fix RepoRoot / shippingRoots rather than the floor")
        #expect(scan.reads.count >= Self.minimumHookLines,
                "Found only \(scan.reads.count) hook reads (floor \(Self.minimumHookLines)) — the token matcher or the comment stripper has stopped matching")
        for root in Self.shippingRoots {
            #expect(scan.filesScanned.contains { $0.hasPrefix(root + "/") }, "Root \(root) contributed no files")
        }
    }

    /// Every family still contributes at its floor. A token that stops matching — renamed hooks, a
    /// prefix edited to something no source line carries — would otherwise leave that family silently
    /// unwalled while the global floor stayed green on the others. `PROXIMITYKIT_UI_TEST_`'s floor is
    /// 0, since no Fernlet line reads one of its flags, so this cell holds nothing for it; its two
    /// samples in the fixture cell hold its matcher.
    @Test func everyHookFamilyStillMatches() {
        let byToken = Dictionary(grouping: Self.sharedScan.reads, by: \.token)
        for token in Self.hookTokens {
            let floor = Self.hookTokenFloors[token] ?? 1
            let found = byToken[token]?.count ?? 0
            #expect(found >= floor, """
                Family \(token) matched only \(found) shipping lines (floor \(floor)) — either its \
                hooks were removed (then remove the token and its floor in the same commit) or the \
                matcher stopped seeing them. Do not lower the floor to make this pass.
                """)
        }
        #expect(Set(Self.hookTokenFloors.keys) == Set(Self.hookTokens),
                "every token needs a floor, and a floor without a token walls nothing")
    }

    // MARK: - TH1: every hook read is DEBUG-only

    @Test func everyHookReadSitsInsideDebug() {
        let violations = Self.sharedScan.reads
            .filter { !$0.insideDebug }
            .map { "\($0.path):\($0.line): \($0.text)" }
        #expect(violations.isEmpty, """
            TH1: these lines read a FERNLET_UI_TEST_* / FERNLET_SKIP_* / FERNLET_MESH_* / \
            FERNLET_PROBE_* / PROXIMITYKIT_UI_TEST_* / PROXIMITYKIT_MESH_* launch hook outside any \
            `#if DEBUG` region, so the hook — and whatever \
            mock, canned result, skipped guard, alternate radio or handshake misbehaviour it selects \
            — ships in Release. Wrap the BODY (never a `public func` signature crossing the \
            app/package boundary), and keep any hoisted `let environment` binding inside the region \
            so it is not an unused-variable error in Release. The two-half pattern
            (`#if DEBUG` … `#else` no-op … `#endif`) is how MeshTransportDebugHooks and \
            MeshRejectionMatrixHarness keep an unguarded CALL site legal:
            \(violations.joined(separator: "\n"))
            """)
    }

    // MARK: - TH2: UITestSupport's two halves declare the same surface

    @Test func uiTestSupportReleaseHalfCoversEveryFlag() throws {
        let url = RepoRoot.url.appending(path: Self.uiTestSupportFile)
        let source = try String(contentsOf: url, encoding: .utf8)
        let (debugNames, releaseNames) = Self.uiTestSupportStaticVars(in: source)

        #expect(debugNames.count >= 10,
                "Found only \(debugNames.count) DEBUG flags in UITestSupport — the declaration matcher has broken")
        let missing = debugNames.subtracting(releaseNames)
        #expect(missing.isEmpty, """
            TH2: UITestSupport's `#else` (Release) half is missing a no-op for: \(missing.sorted()). \
            Every flag needs both halves — the file's header promises the whole surface degrades to a \
            hard-coded no-op, and a one-sided flag breaks the Release build the moment anything \
            outside a DEBUG region reads it.
            """)
        let extra = releaseNames.subtracting(debugNames)
        #expect(extra.isEmpty, "TH2: the Release half declares flags the DEBUG half does not: \(extra.sorted())")
    }

    /// Splits `UITestSupport`'s non-private `static var` names into its DEBUG and `#else` halves.
    static func uiTestSupportStaticVars(in source: String) -> (debug: Set<String>, release: Set<String>) {
        var debug: Set<String> = []
        var release: Set<String> = []
        var half: String?
        for rawLine in source.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if DEBUG") { half = "debug"; continue }
            if trimmed.hasPrefix("#else") { half = half == "debug" ? "release" : half; continue }
            if trimmed.hasPrefix("#endif") { half = nil; continue }
            guard let half, trimmed.hasPrefix("static var ") else { continue }
            let afterKeyword = trimmed.dropFirst("static var ".count)
            let name = String(afterKeyword.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            guard !name.isEmpty else { continue }
            if half == "debug" { debug.insert(name) } else { release.insert(name) }
        }
        return (debug, release)
    }

    // MARK: - Fixtures (the checker must trip on a planted token and pass its near-misses)

    @Test func plantedTokenTrips() {
        let unguarded = "func f() {\n    if ProcessInfo.processInfo.environment[\"FERNLET_UI_TEST_X\"] == \"1\" { return }\n}\n"
        let guarded = "func f() {\n    #if DEBUG\n    if ProcessInfo.processInfo.environment[\"FERNLET_UI_TEST_X\"] == \"1\" { return }\n    #endif\n}\n"
        let conjunction = "#if DEBUG && canImport(UIKit)\nlet x = ProcessInfo.processInfo.environment[\"FERNLET_UI_TEST_X\"]\n#endif\n"
        let wrongCondition = "#if canImport(UIKit)\nlet x = ProcessInfo.processInfo.environment[\"FERNLET_UI_TEST_X\"]\n#endif\n"
        let releaseHalf = "#if DEBUG\nlet a = 1\n#else\nlet x = ProcessInfo.processInfo.environment[\"FERNLET_SKIP_Y\"]\n#endif\n"
        let commentOnly = "// FERNLET_UI_TEST_X is documented here only\n/// and here: FERNLET_SKIP_Y\n"
        // The two families P2 item 14 added, each in the exact shape its real hooks take: a key
        // constant, and an inline environment read.
        let meshKey = "static let key = \"FERNLET_MESH_TRANSPORT\"\n"
        let probeRead = "let x = ProcessInfo.processInfo.environment[\"FERNLET_PROBE_AUTOSTART\"]\n"
        let meshGuarded = "#if DEBUG\nstatic let key = \"FERNLET_MESH_MATRIX\"\n#endif\n"
        // A near-miss the widened matcher must NOT reassign: a UI-test flag whose name contains
        // MESH belongs to the FERNLET_UI_TEST_ family.
        let uiTestMesh = "#if DEBUG\nlet x = environment[\"FERNLET_UI_TEST_MESH_X\"]\n#endif\n"

        // Evaluated into locals rather than inline: `contains`/`allSatisfy` are `rethrows`, and the
        // #expect macro expands them as throwing calls inside a non-throwing test.
        let unguardedReported = Self.hookReads(for: "a.swift", source: unguarded).filter { !$0.insideDebug }
        let guardedOutsideDebug = Self.hookReads(for: "b.swift", source: guarded).filter { !$0.insideDebug }
        let conjunctionOutsideDebug = Self.hookReads(for: "c.swift", source: conjunction).filter { !$0.insideDebug }
        let wrongConditionReported = Self.hookReads(for: "d.swift", source: wrongCondition).filter { !$0.insideDebug }
        let releaseHalfReported = Self.hookReads(for: "e.swift", source: releaseHalf).filter { !$0.insideDebug }
        let commentReads = Self.hookReads(for: "f.swift", source: commentOnly)
        let meshKeyReported = Self.hookReads(for: "g.swift", source: meshKey).filter { !$0.insideDebug }
        let probeReadReported = Self.hookReads(for: "h.swift", source: probeRead).filter { !$0.insideDebug }
        let meshGuardedOutsideDebug = Self.hookReads(for: "i.swift", source: meshGuarded)
            .filter { !$0.insideDebug }
        let uiTestMeshReads = Self.hookReads(for: "j.swift", source: uiTestMesh)

        #expect(!unguardedReported.isEmpty, "an unguarded hook read must be reported")
        #expect(guardedOutsideDebug.isEmpty, "a #if DEBUG-guarded hook read must not be reported")
        #expect(conjunctionOutsideDebug.isEmpty,
                "#if DEBUG && canImport(UIKit) is still a DEBUG region")
        #expect(!wrongConditionReported.isEmpty,
                "a non-DEBUG condition must not count as a guard")
        #expect(!releaseHalfReported.isEmpty,
                "the #else half of a DEBUG directive is the Release half")
        #expect(commentReads.isEmpty, "prose mentioning a hook is not a read")
        #expect(!meshKeyReported.isEmpty,
                "an unguarded FERNLET_MESH_* key constant must be reported — the constant IS the hook")
        #expect(!probeReadReported.isEmpty, "an unguarded FERNLET_PROBE_* read must be reported")
        #expect(meshGuardedOutsideDebug.isEmpty, "a DEBUG-guarded mesh hook must not be reported")
        #expect(uiTestMeshReads.map(\.token) == ["FERNLET_UI_TEST_"],
                "FERNLET_UI_TEST_MESH_* is a UI-test flag, and must score to that family exactly once")
        Self.expectProximityKitFamiliesTrip()
    }

    /// ProximityKit's two families, fixtured the same way as Fernlet's, each in the exact shape its
    /// real hooks take (the transport's key constants, the mesh manager's inline reads), with the
    /// two near-misses its names make: a UI-test flag whose name contains MESH scores to the UI-test
    /// family, and a line naming both UI-test prefixes counts once, toward Fernlet's.
    static func expectProximityKitFamiliesTrip() {
        let meshKey = "static let behaviourKey = \"PROXIMITYKIT_MESH_CHAOS\"\n"
        let uiTestRead = "if env[\"PROXIMITYKIT_UI_TEST_MESH_CLOSED\"] == \"1\" {\n"
        let meshGuarded = "#if DEBUG\nstatic let enabledKey = \"PROXIMITYKIT_MESH_CONSOLE_LOG\"\n#endif\n"
        let uiTestMesh = "#if DEBUG\nif env[\"PROXIMITYKIT_UI_TEST_MESH_OPEN\"] == \"1\" {\n#endif\n"
        let bothPrefixes = "#if DEBUG\nlet any = keys.contains { $0.hasPrefix(\"FERNLET_UI_TEST_\") "
            + "|| $0.hasPrefix(\"PROXIMITYKIT_UI_TEST_\") }\n#endif\n"

        let meshKeyReported = hookReads(for: "k.swift", source: meshKey).filter { !$0.insideDebug }
        let uiTestReadReported = hookReads(for: "l.swift", source: uiTestRead).filter { !$0.insideDebug }
        let meshGuardedReads = hookReads(for: "m.swift", source: meshGuarded)
        let meshGuardedOutsideDebug = meshGuardedReads.filter { !$0.insideDebug }
        let uiTestMeshReads = hookReads(for: "n.swift", source: uiTestMesh)
        let bothPrefixesReads = hookReads(for: "o.swift", source: bothPrefixes)

        #expect(meshKeyReported.map(\.token) == ["PROXIMITYKIT_MESH"],
                "an unguarded PROXIMITYKIT_MESH_* key constant must be reported, in its own family")
        #expect(uiTestReadReported.map(\.token) == ["PROXIMITYKIT_UI_TEST_"],
                "an unguarded PROXIMITYKIT_UI_TEST_* read must be reported, in its own family")
        #expect(meshGuardedReads.map(\.token) == ["PROXIMITYKIT_MESH"],
                "a DEBUG-guarded ProximityKit mesh hook is still read, in its own family")
        #expect(meshGuardedOutsideDebug.isEmpty, "a DEBUG-guarded ProximityKit mesh hook must not be reported")
        #expect(uiTestMeshReads.map(\.token) == ["PROXIMITYKIT_UI_TEST_"],
                "PROXIMITYKIT_UI_TEST_MESH_* is a UI-test flag, and must score to that family exactly once")
        #expect(bothPrefixesReads.map(\.token) == ["FERNLET_UI_TEST_"],
                "a line naming both UI-test prefixes is one read, counted toward the first family listed")
    }
}
