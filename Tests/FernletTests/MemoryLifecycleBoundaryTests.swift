// MemoryLifecycleBoundaryTests.swift
// FernletTests
//
// The static half of the memory-lifecycle wall (Docs/Memory-Leak-Review-2026-08-17.md), sibling of
// the S3, no-tracking and Power-of-10 grep-walls. ``MemoryLifecycleTests`` is the runtime half — it
// pins the specific edges the review found broken. This file pins the three DISCIPLINES the review
// concluded every long-lived object must follow, so a new class cannot quietly opt out:
//
//  ML1  A type that STORES a `Task<…>` handle owns a long-running job. The file must either cancel
//       it in a `deinit`/`isolated deinit`, or be allowlisted with the invariant that makes the
//       missing cancel safe (process-lifetime singleton, or every task captures `[weak self]` and
//       finishes on its own). SwiftUI `@State` handles are excluded: views are structs, and their
//       tasks are cancelled by `.task`/`onDisappear` — a different discipline.
//  ML2  A block-based `NotificationCenter.addObserver(forName:…)` token is RETAINED by the center
//       (with everything its block captures) until it is removed. The file must `removeObserver` it,
//       or be allowlisted with the reason it never needs to.
//  ML3  `withObservationTracking` re-arm loops live in exactly ONE place — `ObservationLoop` — whose
//       owner-held-weakly-across-the-await contract ``ObservationLoopLifecycleTests`` covers. Any
//       other use is a hand-rolled copy of the machinery that leaked before the extraction.
//
// Every scan discovers its inputs from the file system and carries a hard FLOOR (a moved root or a
// broken enumerator must fail loudly, never pass vacuously — the S3BoundaryTests house rule), every
// allowlist entry must be USED, and each rule's planted-token fixture must trip it.

import Foundation
import Testing

/// Grep-wall for the three memory-lifecycle disciplines. Scans the four shipping roots once
/// (``sharedScan``); every enforcement test reads from that immutable value.
struct MemoryLifecycleBoundaryTests {

    // MARK: - Scope, floors, allowlist

    /// The four shipping roots — same set as the Power-of-10 scanner's `SHIPPING_ROOTS`.
    static let shippingRoots = ["FernletKit/Sources", "App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension"]

    /// Floor for the shipping scan (366 files at the time of writing); a root that stops resolving trips it.
    static let minimumShippingFilesScanned = 300

    /// Files that store a `Task<…>` handle today; a wall that finds fewer has stopped looking.
    static let minimumTaskHolderFiles = 8

    /// Files with a block-based observer today; a wall that finds fewer has stopped looking.
    static let minimumObserverFiles = 2

    /// The single sanctioned home of `withObservationTracking`.
    static let observationLoopFile = "FernletKit/Sources/ProximityKit/Engine/ObservationLoop.swift"

    /// One allowlist entry: a repo-relative file path plus the invariant that makes the exemption safe.
    /// Every entry must be USED by the rule it exempts (``allowlistIsFullyUsed()``), so an entry cannot
    /// outlive the site it describes.
    struct Exemption: Hashable, Sendable {
        let rule: String
        let path: String
        let invariant: String
    }

    /// The exemptions. Each states the invariant a reviewer must re-check before touching the site.
    static let allowlist: [Exemption] = [
        Exemption(
            rule: "ML1", path: "App/Fernlet/FernletStore.swift",
            invariant: "FernletStore is the process-lifetime composition root (created once by FernletStoreLoader, never released); its four settle/purge/sync tasks are one-shot, replace-on-restart, and die with the process."),
        Exemption(
            rule: "ML1", path: "FernletKit/Sources/StoreCore/SnapshotSaveCoordinator.swift",
            invariant: "Owned by the store for the process lifetime; both debounce tasks capture [weak self] and finish on their own after a bounded sleep, and cancelPending()/flushPending() end them early."),
        Exemption(
            rule: "ML1", path: "FernletKit/Sources/AppServices/WeatherKitService.swift",
            invariant: "A process-lifetime `shared` singleton; the three request tasks capture [weak self] and each completes on its own (auth prompt, one location fix, one WeatherKit fetch)."),
        Exemption(
            rule: "ML1", path: "App/Fernlet/BrandedCatalogResourceLoader.swift",
            invariant: "Owned by the store for the process lifetime; `inFlight` is a single one-shot ODR fetch that the caller awaits to completion and clears."),
        Exemption(
            rule: "ML1", path: "FernletKit/Sources/ProximityKit/HeartSharing/HeartDropService.swift",
            invariant: "Owned by the store for the process lifetime; `syncTask` captures [weak self] and runs a bounded number of coalesced sync passes, then finishes."),
        Exemption(
            rule: "ML2", path: "App/Fernlet/FernletStore.swift",
            invariant: "The cooking-intent observer is installed once on the process-lifetime store and must outlive every scene; there is no earlier moment at which removing it would be correct."),
    ]

    // MARK: - Scan

    /// One file's lifecycle-relevant facts.
    struct FileFacts: Hashable, Sendable {
        let path: String
        let storesTaskHandle: Bool
        let cancelsInDeinit: Bool
        let addsBlockObserver: Bool
        let removesObserver: Bool
        let usesObservationTracking: Bool
    }

    /// The whole shipping scan: every file's facts plus anything that could not be read.
    struct TreeScan: Sendable {
        var files: [FileFacts] = []
        var unreadable: [String] = []
    }

    static let sharedScan: TreeScan = scan(repoRoot: RepoRoot.url)

    /// Scans the four shipping roots. Never throws or traps: unreadable files are listed for the
    /// enforcement tests to fail on.
    static func scan(repoRoot: URL) -> TreeScan {
        var result = TreeScan()
        for root in shippingRoots {
            for path in PowerOfTenBoundaryTests.swiftFiles(under: root, repoRoot: repoRoot) {
                guard let source = try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8) else {
                    result.unreadable.append(path)
                    continue
                }
                result.files.append(facts(for: path, source: source))
            }
        }
        return result
    }

    /// A stored `Task<…>` property that is not a SwiftUI `@State` (views are structs; their tasks
    /// are cancelled by `.task`/`onDisappear`, a different discipline). Matches `var name: Task<`
    /// and dictionary-of-tasks properties like `[UUID: Task<`.
    static let storedTaskPattern = #"^\s*(@ObservationIgnored\s+)?(private\s+|fileprivate\s+|internal\s+|public\s+)?(private\(set\)\s+)?var\s+[A-Za-z_][A-Za-z_0-9]*\s*:\s*(\[[A-Za-z_][A-Za-z_0-9]*\s*:\s*)?Task<"#

    /// A `deinit` (plain or `isolated`) whose body — the next few lines — cancels a task. The
    /// look-ahead window is generous on purpose: what matters is that the file's teardown site
    /// cancels *something*; ``MemoryLifecycleTests`` proves the specific handles.
    static let deinitCancelPattern = #"(?s)\bdeinit\s*\{[^}]*?\.cancel\(\)"#

    /// A block-based observer registration (`addObserver(forName:` possibly split across lines).
    static let blockObserverPattern = #"(?s)\.addObserver\(\s*forName:"#

    /// Reduces one file to its facts. Line-based for the property rule (which is line-shaped) and
    /// whole-source for the multi-line ones.
    static func facts(for path: String, source: String) -> FileFacts {
        let taskRegex = try? NSRegularExpression(pattern: storedTaskPattern, options: [.anchorsMatchLines])
        let storesTask: Bool = {
            guard let taskRegex else { return false }
            let range = NSRange(source.startIndex..., in: source)
            let candidates = taskRegex.matches(in: source, options: [], range: range)
            // Exclude SwiftUI @State handles: the matched line must not carry `@State`.
            return candidates.contains { match in
                guard let lineRange = Range(match.range, in: source) else { return false }
                let lineStart = source[..<lineRange.lowerBound].lastIndex(of: "\n").map(source.index(after:)) ?? source.startIndex
                let lineEnd = source[lineRange.upperBound...].firstIndex(of: "\n") ?? source.endIndex
                return !source[lineStart..<lineEnd].contains("@State")
            }
        }()
        return FileFacts(
            path: path,
            storesTaskHandle: storesTask,
            cancelsInDeinit: matches(deinitCancelPattern, in: source),
            addsBlockObserver: matches(blockObserverPattern, in: source),
            removesObserver: source.contains("removeObserver("),
            usesObservationTracking: source.contains("withObservationTracking {") || source.contains("withObservationTracking(")
        )
    }

    private static func matches(_ pattern: String, in source: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        return regex.firstMatch(in: source, options: [], range: NSRange(source.startIndex..., in: source)) != nil
    }

    private static func exempt(_ path: String, rule: String) -> Bool {
        allowlist.contains { $0.rule == rule && $0.path == path }
    }

    // MARK: - Floors

    /// The roots resolve and the enumerator found a shipping-sized tree; unreadable files fail loudly.
    @Test func shippingRootsResolveAndClearTheFileFloor() {
        let scan = Self.sharedScan
        #expect(scan.unreadable.isEmpty, "Unreadable shipping files: \(scan.unreadable)")
        #expect(scan.files.count >= Self.minimumShippingFilesScanned,
                "Scanned only \(scan.files.count) files (floor \(Self.minimumShippingFilesScanned)) — a shipping root stopped resolving; fix RepoRoot / shippingRoots rather than the floor")
        for root in Self.shippingRoots {
            #expect(scan.files.contains { $0.path.hasPrefix(root + "/") }, "Root \(root) contributed no files")
        }
    }

    // MARK: - ML1: stored Task handles are cancelled in deinit or exempted with an invariant

    @Test func ml1StoredTaskHandlesAreCancelledInDeinitOrExempted() {
        let holders = Self.sharedScan.files.filter(\.storesTaskHandle)
        #expect(holders.count >= Self.minimumTaskHolderFiles,
                "Found only \(holders.count) task-holding files (floor \(Self.minimumTaskHolderFiles)) — the property matcher has stopped matching")
        let violations = holders
            .filter { !$0.cancelsInDeinit && !Self.exempt($0.path, rule: "ML1") }
            .map(\.path)
        #expect(violations.isEmpty, """
            ML1: these files store a Task<…> handle but neither cancel it in a deinit / isolated deinit \
            nor state an allowlisted invariant. Add `isolated deinit { <handle>?.cancel() }` (the pattern \
            MeshNetworkManager / PresenceManager / ProximityRecipeShareManager use), or add an Exemption \
            naming the invariant that makes the missing cancel safe:
            \(violations.joined(separator: "\n"))
            """)
    }

    // MARK: - ML2: block-based observers are removed or exempted with an invariant

    @Test func ml2BlockObserversAreRemovedOrExempted() {
        let registrars = Self.sharedScan.files.filter(\.addsBlockObserver)
        #expect(registrars.count >= Self.minimumObserverFiles,
                "Found only \(registrars.count) block-observer files (floor \(Self.minimumObserverFiles)) — the observer matcher has stopped matching")
        let violations = registrars
            .filter { !$0.removesObserver && !Self.exempt($0.path, rule: "ML2") }
            .map(\.path)
        #expect(violations.isEmpty, """
            ML2: these files register a block-based NotificationCenter observer (the center retains the \
            block and everything it captures) but never removeObserver it. Hold the token and remove it in \
            a deinit (see NotificationObserverBag in CaptureProtection.swift, or ProtectedSidecar's \
            isolated deinit), or add an Exemption naming the invariant:
            \(violations.joined(separator: "\n"))
            """)
    }

    // MARK: - ML3: withObservationTracking lives only in ObservationLoop

    @Test func ml3ObservationTrackingLivesOnlyInObservationLoop() {
        let users = Self.sharedScan.files.filter(\.usesObservationTracking).map(\.path)
        #expect(users.contains(Self.observationLoopFile),
                "ObservationLoop.swift no longer uses withObservationTracking — the matcher or the file moved; update observationLoopFile")
        let strays = users.filter { $0 != Self.observationLoopFile }
        #expect(strays.isEmpty, """
            ML3: withObservationTracking may only be used through ObservationLoop.start (owner held weakly \
            across the suspension, cancellation finishes the stream). Route these through it instead of \
            hand-rolling the loop:
            \(strays.joined(separator: "\n"))
            """)
    }

    // MARK: - Allowlist contract

    /// Every exemption must be USED — an entry whose site gained a deinit / removeObserver, or moved,
    /// is stale and must be deleted so the wall never carries a dead invariant.
    @Test func allowlistIsFullyUsed() {
        let scan = Self.sharedScan
        let stale = Self.allowlist.filter { exemption in
            guard let facts = scan.files.first(where: { $0.path == exemption.path }) else { return true }
            switch exemption.rule {
            case "ML1": return !(facts.storesTaskHandle && !facts.cancelsInDeinit)
            case "ML2": return !(facts.addsBlockObserver && !facts.removesObserver)
            default: return true
            }
        }
        #expect(stale.isEmpty, "Stale exemptions (site fixed, moved, or unknown rule): \(stale.map { "\($0.rule) \($0.path)" })")
        #expect(Self.allowlist.allSatisfy { !$0.invariant.isEmpty }, "Every exemption must state its invariant")
    }

    // MARK: - Fixtures (each matcher must trip on a planted token and pass a near-miss)

    @Test func fixturesTripEachMatcher() {
        let taskHolder = "final class X {\n    @ObservationIgnored private var job: Task<Void, Never>?\n}\n"
        let stateHolder = "struct V: View {\n    @State private var job: Task<Void, Never>?\n}\n"
        let holderWithDeinit = taskHolder + "extension X {}\n" + "final class Y {\n    var t: Task<Void, Never>?\n    isolated deinit {\n        t?.cancel()\n    }\n}\n"
        #expect(Self.facts(for: "a.swift", source: taskHolder).storesTaskHandle)
        #expect(!Self.facts(for: "b.swift", source: stateHolder).storesTaskHandle, "@State handles are excluded")
        #expect(!Self.facts(for: "a.swift", source: taskHolder).cancelsInDeinit)
        #expect(Self.facts(for: "c.swift", source: holderWithDeinit).cancelsInDeinit)

        let blockObserver = "let t = NotificationCenter.default.addObserver(\n    forName: .x, object: nil, queue: nil) { _ in }\n"
        let selectorObserver = "NotificationCenter.default.addObserver(self, selector: #selector(f), name: .x, object: nil)\n"
        #expect(Self.facts(for: "d.swift", source: blockObserver).addsBlockObserver)
        #expect(!Self.facts(for: "e.swift", source: selectorObserver).addsBlockObserver, "selector observers are not retained blocks")
        #expect(Self.facts(for: "f.swift", source: blockObserver + "deinit { NotificationCenter.default.removeObserver(t) }").removesObserver)

        #expect(Self.facts(for: "g.swift", source: "withObservationTracking {\n  _ = x\n} onChange: {}\n").usesObservationTracking)
        #expect(!Self.facts(for: "h.swift", source: "// withObservationTracking is discussed here only\n").usesObservationTracking)
    }
}
