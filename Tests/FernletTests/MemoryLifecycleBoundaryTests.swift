// MemoryLifecycleBoundaryTests.swift
// FernletTests
//
// The static half of the memory-lifecycle wall (Docs/Memory-Leak-Review-2026-08-17.md), sibling of
// the S3, no-tracking and Power-of-10 grep-walls. ``MemoryLifecycleTests`` is the runtime half — it
// pins the specific edges the review found broken. This file pins the five DISCIPLINES a long-lived
// object must follow — ML1-ML3 as the 2026-08-17 review concluded them, ML4-ML5 added by P5 item 1a
// for the `unowned` host trap — so a new class cannot quietly opt out:
//
//  ML1  A type that STORES a `Task<…>` handle owns a long-running job. The file must either cancel
//       it in a `deinit`/`isolated deinit`, or be allowlisted with the invariant that makes the
//       missing cancel safe (process-lifetime singleton, or every task captures `[weak self]` and
//       finishes on its own). SwiftUI `@State` handles are excluded: views are structs, and their
//       tasks are cancelled by `.task`/`onDisappear` — a different discipline.
//  ML2  A block-based `NotificationCenter.addObserver(forName:…)` token is RETAINED by the center
//       (with everything its block captures) until it is removed. The file must `removeObserver` it,
//       or be allowlisted with the reason it never needs to.
//  ML3  `withObservationTracking` re-arm loops live in exactly ONE place — ProximityKit's
//       `ObservationLoop` — whose owner-held-weakly-across-the-await contract
//       ``ObservationLoopLifecycleTests`` covers. Any other use is a hand-rolled copy of the machinery
//       that leaked before the extraction, so Fernlet's own code holds none at all.
//  ML4  A file holding an `unowned` `ProximityHost` (or, since ProximityKit plan step A0.5.10, its
//       FernletSocial refinement `FernletSocialHost`) may not contain an UNMARKED `Task` construction.
//       Those managers read a host they do not own, so a detached task that outlives the host reads
//       destroyed memory and `swift_abortRetainUnowned` kills the whole process (P5 item 1a). Every
//       such spawn goes through `spawnHostPinned(_:)`, which pins the host for the operation that
//       reads it (HP1); the literals that stay carry a `// host-pin:` marker of exactly one kind —
//       `helper` (the one inside `spawnHostPinned`), `timer — <reason>` (a spawn whose handle the
//       manager STORES, which must never be pinned: that pin is a permanent cycle, HP2) or
//       `exempt — <reason>` (a spawn touching neither `self` nor the host). The scoped pin taken
//       inside an async callee is marked `scoped — <reason>` and sits on no `Task` line. Since
//       ProximityKit plan step A0.5.5 a second audit reads, the same way, every file that spells
//       FernletSocial's `FernletMeshHost` (the mesh features' one `unowned` host holder) as the type
//       of a name: a stored property, or since plan step A0.5.13 a parameter, which is how the
//       activity manager's mesh wiring reads the host. Such a file declares no helper of its own: the
//       one helper is the holder's. Every file the mesh manager's host-reading code moved to holds the
//       host (the first audit) or holds or takes a holder (the second), so its spawns stay scanned; a
//       file that reached the host by any other spelling would not be.
//  ML5  In the test tree, a proximity manager may not be constructed over a host expression that is
//       itself a call: `MeshNetworkManager(store: makeTestStore(), …)` gives the manager a host that
//       dies at the end of the expression (invariant HP0), which is a dangling `unowned` from birth.
//       The mesh composition's two constructions, `FernletMeshFeatures(host:` and the test rig's
//       `FernletMeshRig.features(store:`, and the recipe pair session's, `ProximityPairSession(host:`,
//       are held to the same rule. ProximityKit's own package tests hold its two holders'
//       constructions in their tests (`PackageTestTreeWallTests`), so that half travels with the package.
//
// ML1-ML4 read the five shipping roots; ProximityKit is a package dependency, not one of them (plan
// step A1.3): its package suite `ProximityMemoryLifecycleTests` holds its code to the same four rules
// (since ProximityKit plan step A1.1.17), its one sanctioned `withObservationTracking` home and its two
// `unowned` host holders, the mesh manager and the pair session, among them, so that half travels with
// the package.
//
// Every scan discovers its inputs from the file system and carries a hard FLOOR (a moved root or a
// broken enumerator must fail loudly, never pass vacuously — the S3BoundaryTests house rule), every
// allowlist entry must be USED, and each rule's planted-token fixture must trip it.

import Foundation
import Testing

/// Grep-wall for the five memory-lifecycle disciplines (ML1-ML5). Scans the five shipping roots but
/// ProximityKit's folder once (``sharedScan``); every enforcement test reads from that immutable value.
struct MemoryLifecycleBoundaryTests {

    // MARK: - Scope, floors, allowlist

    /// The five shipping roots — same set as the Power-of-10 scanner's `SHIPPING_ROOTS`, which
    /// `PowerOfTenBoundaryTests.everyShippingCodeWallScansEveryShippingRoot()` now enforces (the
    /// Messages extension was missing here until 2026-09-23).
    static let shippingRoots = [
        "FernletKit/Sources", "App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension",
        "App/FernletMessagesExtension"
    ]

    /// Floor for the shipping scan (366 files at the time of writing, 552 with ProximityKit's folder left
    /// to its own suite at ProximityKit plan step A1.1.17); a root that stops resolving trips it.
    static let minimumShippingFilesScanned = 300

    /// Files that store a `Task<…>` handle today; a wall that finds fewer has stopped looking. Thirteen
    /// since ProximityKit's folder left the scan (plan step A1.1.17); ProximityKit's six are its own
    /// suite's.
    static let minimumTaskHolderFiles = 8

    /// Files with a block-based observer today; a wall that finds fewer has stopped looking. Exactly two
    /// since ProximityKit's folder left the scan (plan step A1.1.17); ProximityKit's one is its own
    /// suite's.
    static let minimumObserverFiles = 2

    /// Files holding an `unowned` `ProximityHost` today, three: presence and the activity manager in
    /// FernletSocial, and, since ProximityKit plan step A0.5.5, the mesh features' `FernletMeshHost`;
    /// presence and the holder hold it as FernletSocial's `FernletSocialHost` since plan step A0.5.10.
    /// Pinned at today's count (plan step A0.5.13): a matcher that finds fewer has stopped looking, or a
    /// holder has left the scan, and either fails here; a new holder raises the count, and is found and
    /// held to ML4. MEASURED 5 -> 3 at ProximityKit plan step A1.1.17 (2026-10-14): the mesh manager and
    /// the recipe pair session, ProximityKit's two holders, left the scan with its folder, and its own
    /// `ProximityMemoryLifecycleTests` holds them (FernletSocial's recipe-share manager holds none: its
    /// session does).
    static let minimumHostHoldingFiles = 3

    /// Files that hold or take a `FernletMeshHost` today, ten (ML4's second audit, plan step A0.5.5):
    /// the mesh composition, its capability and vouch-list objects, the clothing shop's, moderation's
    /// and friend state's exchanges, the chat, the session hearts and the session photos, each through
    /// a stored property, and the activity manager's mesh wiring (`ProximityActivityManager+Mesh.swift`)
    /// through its parameters (plan step A0.5.13). Pinned at today's count: a matcher that finds fewer
    /// has stopped looking, or a holder has left the scan, and either fails here.
    static let minimumMeshHostHoldingFiles = 10

    /// The test roots ML5 scans: the app's unit tests (308 files when the scan was written).
    /// ProximityKit's package tests are the package's own `PackageTestTreeWallTests`' to scan, since plan
    /// step A1.1.14. Each root must yield at least one file (``TestTreeScan/filesScannedPerRoot``), so a
    /// root added here cannot go dark behind another's hundreds.
    static let testRoots = ["Tests/FernletTests"]

    /// Floor for the ML5 test-tree scan, over every root together.
    static let minimumTestFilesScanned = 200

    /// This file — the ONE file the ML5 scan skips, because its planted-token fixtures spell out the
    /// violation ML5 forbids. Every other test file is scanned.
    static let wallFile = "Tests/FernletTests/MemoryLifecycleBoundaryTests.swift"

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
            invariant: "FernletStore is the process-lifetime composition root (created once by FernletStoreLoader, never released); its four settle/purge/sync tasks are one-shot, replace-on-restart, and die with the process — and the fifth and sixth, the fresh-search discovery timeout the run policy's seams arm (P7 item 3, `discoveryTimeoutTask`) and the session poller (P7 item 4, `sessionPollTask`), both capture [weak self], replace themselves on re-arm, are cancelled at every stand-down, and the poller is additionally bounded by the ceiling in ticks and stops itself when a poll reports the session gone — and the seventh, the first-workout Health offer (2026-09-23, `workoutHealthAccessOfferTask`), is started at most once per install (the wipe clears it for a fresh start), captures [weak self], and finishes on its own once the user answers the Health sheet."),
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
            rule: "ML1", path: "FernletKit/Sources/FernletSocial/HeartSharing/HeartDropService.swift",
            invariant: "Owned by the store for the process lifetime; `syncTask` captures [weak self] and runs a bounded number of coalesced sync passes, then finishes."),
        Exemption(
            rule: "ML1", path: "App/Fernlet/FernletStoreAccess.swift",
            invariant: "`FernletStoreAccess` is a process-lifetime `shared` singleton, so it has no deinit to cancel from; `loadingStore` is a single in-flight store load that the caller awaits and that clears itself on BOTH the success and the throwing path, so no handle is retained past the call that made it."),
        Exemption(
            rule: "ML1", path: "App/Fernlet/CompanionRefresh/CompanionRefreshCoordinator.swift",
            invariant: "`CompanionRefreshCoordinator` is a process-lifetime `shared` singleton (the same shape as FernletStoreAccess), so it has no deinit to cancel from; `pipelineRun` is a single in-flight refresh run that captures [weak self], is cancelled by the expiration door before that door completes the task, is replaced by the next delivery, and may complete only the handle it was started for and only while that handle is still held — so a run that outlives its task ends without doing anything."),
        Exemption(
            rule: "ML1", path: "FernletKit/Sources/PrivateHealthStore/PeriodTrackerStore.swift",
            invariant: "`PeriodTrackerStore` is ContentView's root `@State`, alive for the process; `legacyImportTask` is the held legacy cycle import (period-data design 2026-09-30, §8.4), which captures [weak self], is awaited to completion by `runLegacyImportIfNeeded` — a method of the store, so the store is held for the whole run and cannot be released under it — clears itself when it finishes, and is cancelled by `cancelBackgroundWriters()` in the first leg of \"Delete everything\"."),
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
        /// Whether the file declares an `unowned` `ProximityHost` — the ML4 trigger.
        let holdsUnownedHost: Bool
        /// ML4's per-file audit; all-zero for a file that holds no such host (the rule is silent there).
        let hostPin: HostPinAudit
    }

    /// One host-holding file's `// host-pin:` audit — ML4's inputs.
    ///
    /// Line numbers are 1-based and name the `Task` construction, not the marker line, because that
    /// is the line an author has to edit. Empty for every file that does not hold an `unowned`
    /// `ProximityHost`.
    struct HostPinAudit: Hashable, Sendable {
        /// `Task` constructions carrying no `// host-pin:` marker on their own line or the one above.
        var unmarkedSpawns: [Int] = []
        /// Markers on a `Task` construction whose kind is not `helper` / `timer` / `exempt`.
        var badKinds: [String] = []
        /// `timer` / `exempt` / `scoped` markers with nothing after the em-dash.
        var reasonlessMarkers: [Int] = []
        /// `// host-pin:` markers attached to no `Task` construction; only `scoped` may be one.
        var strayMarkers: [String] = []
        /// `// host-pin: helper` markers — exactly one per host-holding file, derived from the file
        /// list rather than written down as a total.
        var helperMarkers: Int = 0
        /// Every `Task` construction found, marked or not — the matcher's own floor.
        var spawns: Int = 0

        /// Files the rule does not apply to.
        static let none = HostPinAudit()

        /// Records the marker found on a `Task` construction at `line`.
        mutating func record(spawnKind kind: String, reason: String, line: Int) {
            switch kind {
            case "helper": helperMarkers += 1
            case "timer", "exempt": if reason.isEmpty { reasonlessMarkers.append(line) }
            default: badKinds.append("\(line): \(kind)")
            }
        }

        /// Records a marker that sits on no `Task` construction. Only the scoped pin may.
        mutating func record(strayKind kind: String, reason: String, line: Int) {
            guard kind == "scoped" else { return strayMarkers.append("\(line): \(kind)") }
            if reason.isEmpty { reasonlessMarkers.append(line) }
        }
    }

    /// ML5's scan of the test tree: how many files it read, in all and per root, and every place a
    /// proximity manager was built over a host expression nobody holds.
    struct TestTreeScan: Sendable {
        /// Files read across every root of ``MemoryLifecycleBoundaryTests/testRoots``.
        var filesScanned = 0
        /// Files read under each root, keyed by the root as ``MemoryLifecycleBoundaryTests/testRoots``
        /// spells it; a root that yields none is a scan silently narrower than it claims.
        var filesScannedPerRoot: [String: Int] = [:]
        /// `path:line` of every inline-host construction ML5 forbids.
        var violations: [String] = []
        /// Files the scan could not read.
        var unreadable: [String] = []
    }

    /// The whole shipping scan: every file's facts plus anything that could not be read.
    struct TreeScan: Sendable {
        var files: [FileFacts] = []
        var unreadable: [String] = []
    }

    static let sharedScan: TreeScan = scan(repoRoot: RepoRoot.url)

    static let sharedTestTreeScan: TestTreeScan = scanTestTree(repoRoot: RepoRoot.url)

    /// One shipping file that holds or takes a `FernletMeshHost`, with its ML4 audit.
    struct MeshHostHolder: Hashable, Sendable {
        let path: String
        let hostPin: HostPinAudit
    }

    /// ML4's second audit's inputs: every shipping file that holds or takes a `FernletMeshHost`
    /// (``meshHostHolderPattern``), read once from the files the shipping scan found.
    static let sharedMeshHostScan: [MeshHostHolder] = meshHostHolders(in: sharedScan, repoRoot: RepoRoot.url)

    /// Every file of `scan` that holds or takes a `FernletMeshHost`, with its host-pin audit. An
    /// unreadable file is the shipping scan's to report.
    static func meshHostHolders(in scan: TreeScan, repoRoot: URL) -> [MeshHostHolder] {
        var holders: [MeshHostHolder] = []
        for file in scan.files {
            guard let source = try? String(contentsOf: repoRoot.appendingPathComponent(file.path), encoding: .utf8),
                  holdsMeshHost(source) else { continue }
            holders.append(MeshHostHolder(path: file.path, hostPin: hostPinAudit(of: source)))
        }
        return holders
    }

    /// Scans every root of ``testRoots`` for ML5. Never throws or traps: unreadable files are listed
    /// for the enforcement test to fail on. ``wallFile`` is skipped — its fixtures spell out the
    /// violation.
    static func scanTestTree(repoRoot: URL) -> TestTreeScan {
        var result = TestTreeScan()
        // R2: bounded by the test roots.
        for root in testRoots {
            result.filesScannedPerRoot[root] = 0
            // R2: bounded by the Swift files under the root.
            for path in PowerOfTenBoundaryTests.swiftFiles(under: root, repoRoot: repoRoot) {
                guard let source = try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8) else {
                    result.unreadable.append(path)
                    continue
                }
                result.filesScanned += 1
                result.filesScannedPerRoot[root, default: 0] += 1
                guard path != wallFile else { continue }
                result.violations.append(contentsOf: inlineHostViolations(in: source).map { "\(path):\($0)" })
            }
        }
        return result
    }

    /// Scans the five shipping roots. ProximityKit's code is its package suite
    /// `ProximityMemoryLifecycleTests`' to hold to ML1-ML4 (since plan step A1.1.17).
    /// Never throws or traps: unreadable files are listed for the enforcement tests to fail on.
    static func scan(repoRoot: URL) -> TreeScan {
        var result = TreeScan()
        // R2: bounded by the five shipping roots.
        for root in shippingRoots {
            // R2: bounded by the Swift files under the root.
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

    /// A manager that holds its host `unowned`. Deliberately looser than the two spellings in the
    /// tree today (`unowned let store: any ProximityHost`, and `any FernletSocialHost`, FernletSocial's
    /// refinement, which presence and the mesh features' host holder take since ProximityKit plan step
    /// A0.5.10): a fifth manager written `unowned var`, or holding a differently-named host, is
    /// SCANNED AND FAILED rather than silently skipped.
    static let unownedHostPattern = #"unowned\s+(let|var)\s+\w+\s*:\s*any (ProximityHost|FernletSocialHost)"#

    /// A file that holds or takes the mesh features' host holder, FernletSocial's `FernletMeshHost`,
    /// which holds the host `unowned` for every feature object and declares their one
    /// `spawnHostPinned(_:)` (ProximityKit plan step A0.5.5): any `name: FernletMeshHost` in the file,
    /// so a stored property (`private let meshHost: FernletMeshHost`) and, since plan step A0.5.13, a
    /// parameter (`meshHost: FernletMeshHost`) both count, and code that reads the host through a
    /// holder it was handed is scanned like code that keeps one. A longer type name does not match. The
    /// holder's own file (`final class FernletMeshHost`) matches nothing here: it holds the host, not a
    /// holder, and ``unownedHostPattern`` reads it instead.
    static let meshHostHolderPattern = #"\w+\s*:\s*FernletMeshHost\b"#

    /// A `Task` CONSTRUCTION in any of its spellings — `Task {`, `Task.detached {`,
    /// `Task(priority: .background) {`, `Task<Void, Never> {`. All four spawn the same detached,
    /// un-cancellable task, and `Task.detached` additionally drops `@_inheritActorContext` so it
    /// would start off the main actor as well. The trailing `{` keeps property declarations
    /// (`var beaconTimer: Task<Void, Never>?`) and `await Task.yield()` out of the match.
    static let spawnPattern = #"\bTask\b\s*(?:\.detached)?\s*(?:<[^>]*>)?\s*(?:\([^)]*\))?\s*\{"#

    /// ML5: a proximity manager constructed over a host expression that is itself a call.
    /// `MeshNetworkManager(store: makeTestStore(), …)` trips; `MeshNetworkManager(store: store)` and
    /// `PresenceManager(store: host, ledger: ledger)` pass. The mesh composition is held the same way
    /// (ProximityKit plan step A0.5.5): `FernletMeshFeatures(host: makeTestStore())` and
    /// `FernletMeshRig.features(store: makeTestStore())` trip, and so does the recipe pair session,
    /// which holds the host the manager over it does not: `ProximityPairSession(host: makeTestStore(),
    /// …)`. Each holder trips spelled `.init(` too, and so does an implicit `.init(store: …)` or
    /// `.init(host: …)` whatever type it builds (no type is spelled there), a qualified host call
    /// (`Fixtures.host()`) and a call after `try` or `await`; the regex runs over the whole file, so a
    /// call broken across lines is read. Known narrowness, stated on purpose: a host expression that does
    /// not open with a name or a dotted name called in place (`store: (makeHost())`,
    /// `store: hosts[0].make()`, a closure called where it stands), and a holder built through an alias
    /// or a factory of its own, are not read — ML5 is a ratchet on a repaired site, not a proof.
    static let inlineHostPattern =
        #"(?:(?:MeshNetworkManager|PresenceManager|ProximityRecipeShareManager|ProximityActivityManager)(?:\s*\.\s*init)?\(\s*store:"#
        + #"|(?:ProximityPairSession|FernletMeshFeatures)(?:\s*\.\s*init)?\(\s*host:|FernletMeshRig\s*\.\s*features\(\s*store:"#
        + #"|(?<![A-Za-z0-9_])\.\s*init\(\s*(?:store|host):)\s*(?:(?:try[?!]?|await)\s+)*[\w.]+\("#

    /// Whether `line` constructs a `Task`. `///` documentation lines are excluded (the helper's own
    /// doc comment quotes the literal it replaces), as is a match that sits after a `//` on the line.
    static func isSpawnConstruction(_ line: String) -> Bool {
        guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("///"),
              let regex = try? NSRegularExpression(pattern: spawnPattern, options: []),
              let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
              let matched = Range(match.range, in: line) else { return false }
        if let comment = line.range(of: "//"), comment.lowerBound < matched.lowerBound { return false }
        return true
    }

    /// The `// host-pin:` marker on a line, split into its kind and the reason after the em-dash.
    /// `///` documentation lines carry none, so the helper may quote the marker vocabulary it names.
    static func hostPinMarker(in line: String) -> (kind: String, reason: String)? {
        guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("///"),
              let start = line.range(of: "// host-pin:") else { return nil }
        let rest = line[start.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let dash = rest.range(of: "\u{2014}") else { return (rest, "") }
        return (String(rest[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces),
                String(rest[dash.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// Audits one host-holding file's `Task` constructions against ML4.
    static func hostPinAudit(of source: String) -> HostPinAudit {
        let lines = source.components(separatedBy: "\n")
        var audit = HostPinAudit()
        for (index, line) in lines.enumerated() {
            let marker = hostPinMarker(in: line)
            guard isSpawnConstruction(line) else {
                let attached = index + 1 < lines.count && isSpawnConstruction(lines[index + 1])
                if let marker, !attached { audit.record(strayKind: marker.kind, reason: marker.reason, line: index + 1) }
                continue
            }
            audit.spawns += 1
            let own = marker ?? (index > 0 ? hostPinMarker(in: lines[index - 1]) : nil)
            guard let own else {
                audit.unmarkedSpawns.append(index + 1)
                continue
            }
            audit.record(spawnKind: own.kind, reason: own.reason, line: index + 1)
        }
        return audit
    }

    /// ML5's matcher over one source, as 1-based line numbers. Shared by the scan and its fixture.
    static func inlineHostViolations(in source: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: inlineHostPattern, options: []) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, options: [], range: range).compactMap { match in
            guard let matched = Range(match.range, in: source) else { return nil }
            return source[..<matched.lowerBound].components(separatedBy: "\n").count
        }
    }

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
        let holdsHost = matches(unownedHostPattern, in: source)
        return FileFacts(
            path: path,
            storesTaskHandle: storesTask,
            cancelsInDeinit: matches(deinitCancelPattern, in: source),
            addsBlockObserver: matches(blockObserverPattern, in: source),
            removesObserver: source.contains("removeObserver("),
            usesObservationTracking: source.contains("withObservationTracking {") || source.contains("withObservationTracking("),
            holdsUnownedHost: holdsHost,
            hostPin: holdsHost ? hostPinAudit(of: source) : .none
        )
    }

    /// Whether `source` holds or takes a `FernletMeshHost` (``meshHostHolderPattern``): ML4's second
    /// audit's matcher, shared by the scan and its fixture.
    static func holdsMeshHost(_ source: String) -> Bool {
        matches(meshHostHolderPattern, in: source)
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
            MeshNetworkManager / PresenceManager / ProximityPairSession use), or add an Exemption \
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

    /// No file Fernlet's scan reads uses `withObservationTracking` at all: its one sanctioned home,
    /// ProximityKit's `Engine/ObservationLoop.swift`, is in the folder this scan leaves to ProximityKit's
    /// own `ProximityMemoryLifecycleTests`, which holds it as the module's one use (since plan step
    /// A1.1.17). The matcher is held to its samples in ``fixturesTripEachMatcher()``.
    @Test func ml3ObservationTrackingLivesOnlyInObservationLoop() {
        let strays = Self.sharedScan.files.filter(\.usesObservationTracking).map(\.path)
        #expect(strays.isEmpty, """
            ML3: withObservationTracking may only be used through ProximityKit's ObservationLoop.start \
            (owner held weakly across the suspension, cancellation finishes the stream); Fernlet's code \
            holds no use of its own. Route these through it instead of hand-rolling the loop:
            \(strays.joined(separator: "\n"))
            """)
    }

    // MARK: - ML4: every Task in a host-holding file is pinned or marked

    /// The marker's own `— <reason>` text is the per-site invariant, which is why ML4 uses it rather
    /// than adding eleven path-duplicate ``Exemption`` rows: `Exemption` is keyed by FILE, and these
    /// exemptions are per SITE (several per file, each safe for its own reason). Counts stay floors
    /// or are derived from the discovered file list — never a literal a failing run can be "fixed"
    /// by bumping.
    @Test func ml4HostHoldingFilesPinOrMarkEveryTaskConstruction() {
        let holders = Self.sharedScan.files.filter(\.holdsUnownedHost)
        #expect(holders.count >= Self.minimumHostHoldingFiles,
                "Found only \(holders.count) files holding an unowned ProximityHost (floor \(Self.minimumHostHoldingFiles)) — the matcher has stopped matching, or a holder has left the scan")
        let unmarked = holders.flatMap { file in file.hostPin.unmarkedSpawns.map { "\(file.path):\($0)" } }
        #expect(unmarked.isEmpty, """
            ML4: these Task constructions live in a file that reads an unowned ProximityHost, so a task \
            outliving the host reads destroyed memory and aborts the whole process. Route them through \
            spawnHostPinned(_:), or mark them `// host-pin: timer — <reason>` (a handle the manager \
            stores: a pin there is a permanent cycle, HP2) / `// host-pin: exempt — <reason>` (no self, \
            no host read):
            \(unmarked.joined(separator: "\n"))
            """)
        let badKinds = holders.flatMap { file in file.hostPin.badKinds.map { "\(file.path):\($0)" } }
        #expect(badKinds.isEmpty, "ML4: a host-pin marker's kind must be helper / timer / exempt: \(badKinds)")
        let reasonless = holders.flatMap { file in file.hostPin.reasonlessMarkers.map { "\(file.path):\($0)" } }
        #expect(reasonless.isEmpty, "ML4: every timer / exempt / scoped marker states the invariant that makes it safe: \(reasonless)")
        let strays = holders.flatMap { file in file.hostPin.strayMarkers.map { "\(file.path):\($0)" } }
        #expect(strays.isEmpty, "ML4: only the `scoped` pin may carry a host-pin marker off a Task line: \(strays)")
        let helperCounts = holders.filter { $0.hostPin.helperMarkers != 1 }.map { "\($0.path) has \($0.hostPin.helperMarkers)" }
        #expect(helperCounts.isEmpty, "ML4: each host-holding file declares exactly one spawnHostPinned helper: \(helperCounts)")
        let silent = holders.filter { $0.hostPin.spawns == 0 }.map(\.path)
        #expect(silent.isEmpty, "ML4: a host-holding file with no Task construction at all has lost its helper: \(silent)")
        // The second audit (ProximityKit plan step A0.5.5): a file that holds or takes a
        // `FernletMeshHost` (a parameter too, since plan step A0.5.13) reads the host through it, so
        // every Task it constructs carries a marker as above, and it declares no helper of its own —
        // the one helper is `FernletMeshHost`'s.
        let meshHolders = Self.sharedMeshHostScan
        #expect(meshHolders.count >= Self.minimumMeshHostHoldingFiles,
                "Found only \(meshHolders.count) files holding or taking a FernletMeshHost (floor \(Self.minimumMeshHostHoldingFiles)) — the matcher has stopped matching, or a holder has left the scan")
        let unmarkedThere = meshHolders.flatMap { file in file.hostPin.unmarkedSpawns.map { "\(file.path):\($0)" } }
        #expect(unmarkedThere.isEmpty, """
            ML4: these Task constructions live in a file that holds or takes a FernletMeshHost, which \
            reads an unowned ProximityHost. Route them through the holder's spawnHostPinned(_:), or mark them \
            `// host-pin: timer — <reason>` / `// host-pin: exempt — <reason>`:
            \(unmarkedThere.joined(separator: "\n"))
            """)
        let badKindsThere = meshHolders.flatMap { file in file.hostPin.badKinds.map { "\(file.path):\($0)" } }
        #expect(badKindsThere.isEmpty, "ML4: a FernletMeshHost holder's marker kind must be timer / exempt: \(badKindsThere)")
        let reasonlessThere = meshHolders.flatMap { file in file.hostPin.reasonlessMarkers.map { "\(file.path):\($0)" } }
        #expect(reasonlessThere.isEmpty, "ML4: every marker in a FernletMeshHost holder states its invariant: \(reasonlessThere)")
        let straysThere = meshHolders.flatMap { file in file.hostPin.strayMarkers.map { "\(file.path):\($0)" } }
        #expect(straysThere.isEmpty, "ML4: only the `scoped` pin may carry a host-pin marker off a Task line: \(straysThere)")
        let helpersThere = meshHolders.filter { $0.hostPin.helperMarkers != 0 }.map(\.path)
        #expect(helpersThere.isEmpty, "ML4: a FernletMeshHost holder declares no helper of its own: \(helpersThere)")
    }

    // MARK: - ML5: a test never hands a manager a host nobody holds

    @Test func ml5TestsNeverBuildAManagerOverAnInlineHost() {
        let scan = Self.sharedTestTreeScan
        #expect(scan.unreadable.isEmpty, "Unreadable test files: \(scan.unreadable)")
        #expect(scan.filesScanned >= Self.minimumTestFilesScanned,
                "Scanned only \(scan.filesScanned) test files (floor \(Self.minimumTestFilesScanned)) — the test roots \(Self.testRoots) stopped resolving")
        // Per-root floor, as the no-tracking wall's: one root going dark must not be masked by
        // another's hundreds of files. R2: bounded by the test roots.
        for root in Self.testRoots {
            let count = scan.filesScannedPerRoot[root] ?? 0
            #expect(count > 0, "ML5 scanned zero Swift files under '\(root)' — the root moved and ML5 is silently narrower")
        }
        #expect(scan.violations.isEmpty, """
            ML5: these build a proximity manager over a host expression that dies at the end of the \
            expression, so the manager is born with a dangling unowned host (invariant HP0). Hoist the \
            host into its own `let` that outlives the manager:
            \(scan.violations.joined(separator: "\n"))
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

        let host = "    private unowned let store: any ProximityHost\n"
        #expect(Self.facts(for: "i.swift", source: host).holdsUnownedHost)
        #expect(Self.facts(for: "j.swift", source: "    private let store: any ProximityHost\n").holdsUnownedHost == false,
                "a strongly held host is not ML4's subject")
        let socialHost = "    private unowned let store: any FernletSocialHost\n"
        let strongSocialHost = "    private let store: any FernletSocialHost\n"
        #expect(Self.facts(for: "i2.swift", source: socialHost).holdsUnownedHost,
                "FernletSocial's refinement of the host is ML4's subject as the host is")
        #expect(Self.facts(for: "j2.swift", source: strongSocialHost).holdsUnownedHost == false,
                "and a strongly held one is not")
        for spelling in ["Task {", "Task.detached {", "Task(priority: .background) {", "Task<Void, Never> {"] {
            let planted = Self.facts(for: "k.swift", source: host + "        \(spelling) await f() }\n")
            #expect(planted.hostPin.unmarkedSpawns == [2], "\(spelling) must trip ML4")
        }
        let nearMisses = host + "    var t: Task<Void, Never>?\n    await Task.yield()\n    /// as the `Task { … }` literal\n"
        #expect(Self.facts(for: "l.swift", source: nearMisses).hostPin.spawns == 0, "declarations, yields and docs are not spawns")
        let marked = host + "        Task {   // host-pin: helper\n        }\n        // host-pin: exempt — no self, no host read\n        Task { await c.cancel() }\n"
        let markedAudit = Self.facts(for: "m.swift", source: marked).hostPin
        #expect(markedAudit.unmarkedSpawns.isEmpty && markedAudit.helperMarkers == 1 && markedAudit.spawns == 2)
        let emptyReason = host + "        // host-pin: timer —\n        Task { await f() }\n"
        #expect(Self.facts(for: "n.swift", source: emptyReason).hostPin.reasonlessMarkers == [3], "a reasonless marker must trip")
        let strayKind = host + "        // host-pin: whatever — not a kind\n        let x = 1\n"
        #expect(Self.facts(for: "o.swift", source: strayKind).hostPin.strayMarkers.isEmpty == false, "only `scoped` may sit off a Task line")
        Self.expectTheHostReadersReachEverySpelling(host: host)
        Self.expectTheInlineHostMatcherFixtured()

        let meshHostHolder = "    private let meshHost: FernletMeshHost\n"
        #expect(Self.holdsMeshHost(meshHostHolder), "a feature holding the composition's host holder is ML4's subject")
        #expect(Self.holdsMeshHost("    func attach(to mesh: MeshNetworkManager, meshHost: FernletMeshHost) {\n"),
                "a file taking the host holder as a parameter reads the host through it, and is ML4's subject too")
        #expect(!Self.holdsMeshHost("final class FernletMeshHost {\n    unowned let host: any FernletSocialHost\n"),
                "the holder's own file holds the host, not a holder")
        #expect(!Self.holdsMeshHost("    let meshHost: FernletMeshHostSpy\n"), "a longer type name is not the holder")
        let plantedThere = Self.hostPinAudit(of: meshHostHolder + "        Task { await f() }\n")
        #expect(plantedThere.unmarkedSpawns == [2] && plantedThere.helperMarkers == 0,
                "an unmarked spawn in a holder's file must trip the second audit")
    }

    /// ML4's readers reach what their docs promise: a marker of no kind on a `Task` line is a bad kind,
    /// never an exemption, and the host pattern reads an `unowned var` and a host under another name, of
    /// the host protocol and of FernletSocial's refinement alike.
    private static func expectTheHostReadersReachEverySpelling(host: String) {
        let pinned = facts(for: "p.swift", source: host + "        Task {   // host-pin: pinned — x\n        }\n").hostPin
        #expect(pinned.badKinds == ["2: pinned"], "a Task line's marker of no kind must trip as a bad kind: \(pinned)")
        let holders = [
            "    unowned var host: any ProximityHost\n", "    private unowned let owner: any ProximityHost\n",
            "    unowned var host: any FernletSocialHost\n", "    private unowned let owner: any FernletSocialHost\n"
        ]
        // R2: bounded by the fixed list.
        for holder in holders {
            #expect(facts(for: "q.swift", source: holder).holdsUnownedHost, "ML4 skipped an unowned host: \(holder)")
        }
    }

    /// ML5's matcher reads every holder built over a call, in every spelling it names (a call broken
    /// across lines, `.init(` spelled or implicit, a qualified host call, a call after `try` or `await`),
    /// each on the line the construction opens, and none built over a held host.
    private static func expectTheInlineHostMatcherFixtured() {
        let inline = [
            "let bare = MeshNetworkManager(store: makeTestStore(), transport: t)\n",
            "let f = FernletMeshFeatures(host: makeTestStore())\n",
            "let f = FernletMeshRig.features(store: makeTestStore(), transport: t)\n",
            "let wrapped = MeshNetworkManager(\n    store: makeTestStore(),\n    transport: t\n)\n",
            "let spelled = PresenceManager.init(store: makeTestStore(), ledger: ledger)\n",
            "let implicit: MeshNetworkManager = .init(store: makeTestStore(), transport: t)\n",
            "let qualified = MeshNetworkManager(store: Fixtures.host(), transport: t)\n",
            "let tried = MeshNetworkManager(store: try makeTestStore(), transport: t)\n",
            "let awaited: ProximityPairSession = .init(host: await makeTestStore(), profile: p)\n"
        ]
        let held = [
            "let bare = MeshNetworkManager(store: bareHost, transport: t)\n",
            "let p = PresenceManager(store: host, ledger: ledger)\n", "let f = FernletMeshFeatures(host: store)\n",
            "let f = FernletMeshRig.features(store: store, transport: t)\n",
            "let spelled = MeshNetworkManager.init(store: host)\n", "self.init(store: store, transport: nil)\n"
        ]
        // R2: bounded by the two fixed lists.
        for sample in inline {
            #expect(inlineHostViolations(in: sample) == [1], "ML5 missed a holder built over an inline host: \(sample)")
        }
        for sample in held {
            #expect(inlineHostViolations(in: sample).isEmpty, "ML5 read a holder built over a held host: \(sample)")
        }
    }
}
