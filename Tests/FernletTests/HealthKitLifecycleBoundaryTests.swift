import Foundation
import Testing
@testable import Fernlet

/// Grep-wall for the two lifecycle invariants `269003c` established and left unpinned.
///
/// **Why a wall and not behavioural tests.** `269003c` came with 199 lines of tests, and they are
/// good ones: `HealthKitDisableTests` proves that cancelling a Swift task really stops the
/// underlying `HKQuery`, that observation starts no queries for unrequested capabilities, and that
/// repeated observation reuses queries instead of accumulating them. Three of the round's five
/// invariants are therefore genuinely held.
///
/// The other two are not reachable that way:
///
/// * **The coalescing window** lives in `ContentView.scheduleHealthRefreshAfterObservedChange`, a
///   `private func` on a SwiftUI `View`. A test cannot call it, cannot observe the `Task` it
///   creates, and cannot inject a clock into `Task.sleep`. Testing it properly means extracting the
///   debounce into its own type — worth doing, and a bigger change than this pass should make to
///   the health-refresh path it is trying to protect.
/// * **The construction inventory** is a whole-tree property. No single test can observe "nobody
///   else made one of these"; only a scan can.
///
/// So this is a source scan, with the honesty that implies: it proves the shapes are still written,
/// not that they still behave. That is worth having anyway, because BOTH regressions are invisible
/// at runtime — a shortened coalescing window and an extra per-view service both just make the app
/// do more work, which no assertion anywhere would notice.
struct HealthKitLifecycleBoundaryTests {

    // MARK: - The construction inventory

    /// What a given `HealthKitService()` construction is FOR.
    enum ServiceRole: Sendable, Equatable {
        /// The one instance held for the life of the app.
        case appLifetime
        /// Built for a single awaited write and discarded. Cheap and correct: the alternative is
        /// threading the app's instance through a sheet that needs it once.
        case transientWrite
        /// A `?? HealthKitService()` default behind an injectable parameter. The risk class — it is
        /// correct only while every call site remembers to inject.
        case injectionFallback
        /// `#Preview` or other non-shipping code.
        case preview
    }

    /// Every place the tree constructs a `HealthKitService`, with its role.
    ///
    /// This is an INVENTORY, not an allowlist: the point is not that these are permitted but that
    /// the set is known and small. A new entry is not automatically wrong — it needs a role and a
    /// glance, which is exactly what a silent regression does not get.
    struct ConstructionSite: Sendable {
        let path: String
        let role: ServiceRole
        let note: String
    }

    static let constructionSites: [ConstructionSite] = [
        ConstructionSite(
            path: "App/Fernlet/FernletApp.swift",
            role: .appLifetime,
            note: """
                THE one. `State(initialValue: HealthKitService())` in the app's init, after \
                `defaultCacheClearer` is installed — the ordering matters, because the gateway has \
                no default cleaner and `disableIntegration()` fails closed without one.
                """
        ),
        ConstructionSite(
            path: "App/Fernlet/FirstAidView.swift",
            role: .transientWrite,
            note: "One awaited `saveMindfulSession` at the end of a breathing exercise, then discarded."
        ),
        ConstructionSite(
            path: "App/Fernlet/LogIntimacySheet.swift",
            role: .transientWrite,
            note: "One awaited `saveIntimacyEvent` when the sheet saves, then discarded."
        ),
        ConstructionSite(
            path: "App/Fernlet/HealthAccessSettingsView.swift",
            role: .transientWrite,
            note: """
                `makeHealthKitService()` builds one per call, and is also the seam that returns a \
                mock under UI test. The settings screen reads authorization state; it starts no \
                observers.
                """
        ),
        ConstructionSite(
            path: "App/Fernlet/HealthSyncCoordinator.swift",
            role: .injectionFallback,
            note: """
                `providedHealthKitService ?? HealthKitService()`, behind a `lazy var` so the \
                fallback is not even built when a service was injected. Every production host \
                injects.
                """
        ),
        ConstructionSite(
            path: "App/Fernlet/CycleTrackerView.swift",
            role: .injectionFallback,
            note: """
                `healthKitService ?? HealthKitService()` in the initializer. Its one production \
                call site (`PrivateHubView`) injects; the fallback exists for the two tests that \
                construct the view directly.
                """
        ),
        ConstructionSite(
            path: "FernletKit/Sources/HealthKitGateway/HealthKitService.swift",
            role: .injectionFallback,
            note: """
                `service ?? HealthKitService()` inside the gateway module's own `init`, resolving \
                its test seam. In-module, so it can never be the app's instance by construction.
                """
        ),
        ConstructionSite(
            path: "App/Fernlet/ContentView.swift",
            role: .preview,
            note: "`#Preview` only. Not in the shipping binary."
        ),
    ]

    /// Roots scanned. Test sources are excluded: a test constructing its own service is the point.
    static let scanRoots = ["App", "FernletKit/Sources"]

    /// Floor for the scan (408 `.swift` files at the time of writing).
    static let minimumFilesScanned = 320

    /// Exactly one long-lived `HealthKitService` exists.
    ///
    /// This is the invariant `269003c` was largely about: before it, a service was built per view
    /// appearance, so every tab switch stood up a fresh gateway, re-read authorization, and
    /// restarted observers. The fix is one instance in `FernletApp`, injected downward — and it is
    /// held today by every call site remembering to pass it, which is not a mechanism.
    ///
    /// Note what the invariant actually is, because "one `HealthKitService` in the app" is not
    /// true and stating it that way would make this test wrong: there is one LONG-LIVED service,
    /// plus a bounded set of transient per-write instances that are awaited and dropped, plus
    /// injection fallbacks that production never reaches.
    @Test func exactlyOneAppLifetimeHealthKitServiceExists() {
        let appLifetime = Self.constructionSites.filter { $0.role == .appLifetime }
        #expect(
            appLifetime.count == 1,
            """
            Expected exactly one `.appLifetime` HealthKitService, found \(appLifetime.count): \
            \(appLifetime.map(\.path).sorted().joined(separator: ", ")). A second long-lived \
            gateway means two authorization snapshots, two observer sets, and two background \
            deliveries for the same types — the churn 269003c removed, back with nothing failing.
            """
        )
        #expect(appLifetime.first?.path == "App/Fernlet/FernletApp.swift")
    }

    /// No file constructs a `HealthKitService` without an inventory entry.
    @Test func everyHealthKitServiceConstructionSiteIsInventoried() throws {
        let (sites, filesScanned) = try Self.scanForConstructionSites()

        #expect(
            filesScanned >= Self.minimumFilesScanned,
            """
            Scanned only \(filesScanned) Swift files under \(Self.scanRoots.joined(separator: ", ")) \
            (floor \(Self.minimumFilesScanned)) — a root moved or the enumerator broke, and this \
            wall is now passing without looking at anything.
            """
        )

        let inventoried = Set(Self.constructionSites.map(\.path))
        let unknown = Set(sites.map(\.path)).subtracting(inventoried)
        #expect(
            unknown.isEmpty,
            """
            \(unknown.count) file(s) construct a HealthKitService with no inventory entry. Decide \
            which it is — a transient write (fine), an injection fallback (fine if every production \
            caller injects), or a second long-lived gateway (not fine: it re-reads authorization \
            and restarts observers behind the app's own instance) — then add a `ConstructionSite` \
            saying so:
            \(unknown.sorted().joined(separator: "\n"))
            """
        )

        let stale = inventoried.subtracting(Set(sites.map(\.path)))
        #expect(
            stale.isEmpty,
            """
            \(stale.count) inventoried construction site(s) no longer construct anything. Delete \
            them — a stale entry is a hole nobody is watching:
            \(stale.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Every `HealthKitService(` construction in the shipping roots, by file.
    static func scanForConstructionSites() throws -> (sites: [(path: String, line: Int)], filesScanned: Int) {
        var sites: [(path: String, line: Int)] = []
        var filesScanned = 0
        for root in scanRoots {
            let rootURL = RepoRoot.url(root)
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
                Issue.record("Could not enumerate \(root) — moved or renamed? This wall is unenforced.")
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                filesScanned += 1
                let relativePath = url.path.replacingOccurrences(of: RepoRoot.url.path + "/", with: "")
                for (offset, line) in source.components(separatedBy: "\n").enumerated()
                where Self.constructsService(line) {
                    sites.append((relativePath, offset + 1))
                }
            }
        }
        return (sites, filesScanned)
    }

    /// True when `line` constructs a `HealthKitService`, and not merely mentions one.
    ///
    /// `MockPrivacyHealthKitService(` and `PrivacyHealthKitService(` must not match — they end in
    /// the same characters, which a naive `contains` would accept.
    static func constructsService(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { return false }
        let chars = Array(line)
        let needle = Array("HealthKitService(")
        for start in 0...(max(chars.count - needle.count, 0)) where start + needle.count <= chars.count {
            guard Array(chars[start..<(start + needle.count)]) == needle else { continue }
            // The character before must not continue an identifier, or `MockPrivacyHealthKitService(`
            // and `PrivacyHealthKitService(` match too.
            guard start == 0 || !(chars[start - 1].isLetter || chars[start - 1].isNumber) else { continue }
            return true
        }
        return false
    }

    /// Fixture: the construction matcher separates a real construction from the near-misses that
    /// live in the same files.
    @Test func theConstructionMatcherSeesOnlyRealConstructions() {
        #expect(Self.constructsService("        _healthKitService = State(initialValue: HealthKitService())"))
        #expect(Self.constructsService("        let service = healthKitService ?? HealthKitService()"))
        #expect(Self.constructsService("        return HealthKitService(preferencesStore: storagePreferencesStore)"))
        #expect(!Self.constructsService("            return MockPrivacyHealthKitService(preferencesStore: store)"),
                "a differently-named type that ends in the same characters is not a construction")
        #expect(!Self.constructsService("    private let service: any HealthKitServicing"),
                "a protocol-typed property constructs nothing")
        #expect(!Self.constructsService("        // HealthKitService() used to be built here"),
                "a comment constructs nothing")
        #expect(!Self.constructsService("/// See `HealthKitService(preferencesStore:)` for the seam."),
                "a doc comment constructs nothing")
    }

    // MARK: - The coalescing window

    /// The observed-change refresh still coalesces a burst into one refresh.
    ///
    /// Three things have to be true together, and all three are one line each — which is exactly
    /// why they are easy to lose in an edit and impossible to notice at runtime:
    /// 1. the pending set accumulates the changed type,
    /// 2. the previous task is CANCELLED before a new one is scheduled (newest-wins),
    /// 3. the new task waits `healthChangeCoalescingWindow` before draining.
    ///
    /// Drop (2) and every notification in a batch schedules its own refresh, which is the
    /// pre-`269003c` storm. Shorten (3) to zero and the batch no longer coalesces at all. Neither
    /// breaks anything a person or a test can see; the app just does N times the work.
    @Test func theObservedHealthRefreshStaysCoalesced() throws {
        let source = try RepoRoot.source("App/Fernlet/ContentView.swift")
        guard let body = Self.functionBody(named: "scheduleHealthRefreshAfterObservedChange", in: source) else {
            Issue.record("`scheduleHealthRefreshAfterObservedChange` is gone from ContentView — was the coalescing removed, or just renamed? Either way this wall is now unenforced.")
            return
        }

        #expect(
            body.contains("pendingObservedHealthTypeIdentifiers.insert("),
            "the changed type is no longer accumulated, so a coalesced batch would refresh the wrong things"
        )
        #expect(
            body.contains("healthRefreshTask?.cancel()"),
            """
            The previous refresh task is no longer cancelled. Without newest-wins cancellation every \
            notification in a Health write batch schedules its own refresh — the exact storm \
            269003c removed — and nothing else in the suite notices.
            """
        )
        #expect(
            body.contains("Task.sleep(for: Self.healthChangeCoalescingWindow)"),
            """
            The refresh no longer waits the named coalescing window. If the window was inlined \
            again, put it back behind `healthChangeCoalescingWindow`: an inline literal is what \
            made this invariant unpinnable in the first place.
            """
        )
    }

    /// The coalescing window keeps a value that can actually outlast a write batch.
    ///
    /// A floor, not an equality: 500 ms is a judgement call and tuning it is fine. Going to zero,
    /// or to something shorter than the tens of milliseconds an `HKHealthStore.save` batch takes to
    /// deliver its callbacks, is not tuning — it is removing the coalescing while leaving the code
    /// that looks like it.
    @Test func theCoalescingWindowIsLongEnoughToOutlastAWriteBatch() {
        #expect(ContentView.healthChangeCoalescingWindow >= .milliseconds(100))
        #expect(ContentView.healthChangeCoalescingWindow <= .seconds(5), "a window this long would read as a hang")
    }

    /// The body of `func <name>(`, brace-balanced from its declaration.
    static func functionBody(named name: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("func \(name)(") }) else { return nil }
        var depth = 0
        var opened = false
        var body: [String] = []
        for line in lines[start...] {
            for character in line {
                if character == "{" { depth += 1; opened = true }
                if character == "}" { depth -= 1 }
            }
            body.append(line)
            if opened, depth <= 0 { return body.joined(separator: "\n") }
        }
        return nil
    }

    /// Fixture: the body reader stops at the function's own closing brace.
    @Test func theBodyReaderStopsAtTheFunctionsOwnBrace() {
        let source = """
            func target() {
                if condition { doThing() }
                inside()
            }

            func next() {
                outside()
            }
            """
        let body = Self.functionBody(named: "target", in: source)
        #expect(body?.contains("inside()") == true)
        #expect(body?.contains("outside()") == false, "the reader ran past the closing brace into the next function")
        #expect(Self.functionBody(named: "absent", in: source) == nil)
    }
}
