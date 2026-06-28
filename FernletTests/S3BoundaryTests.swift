import Foundation
import Testing
import FernletDomainModel

/// Grep-wall backstop for the S3 privacy wall (WI-4, Docs/Security-Hardening-Plan-2026-06-27.md).
///
/// The compiler wall (`DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR`) covers the package modules
/// `AIProviders`/`CloudKitSync`, but the AI prompt-builders that still live in the APP target are
/// outside the package, so the compiler wall cannot reach them. This test is their only backstop: it
/// scans every AI-facing source for any token that would mean it reached a sealed `Private*` store
/// directly instead of consuming the typed, de-identified `AIContext` payloads.
///
/// AI-facing files are DISCOVERED dynamically (any file that uses the Apple FoundationModels API), so a
/// new on-device-AI call site is auto-covered. A hard-coded FLOOR additionally pins the known boundary
/// files — including the de-identification types that do not themselves use the API — and fails loudly
/// if one is renamed/moved out of coverage (no silent fail-soft).
struct S3BoundaryTests {
    /// Roots scanned for AI-facing sources: the whole app target (which lives OUTSIDE the compiler
    /// wall) plus the two package modules that build/relay AI payloads (belt-and-suspenders — these are
    /// already compiler-walled).
    private static let scanRoots = [
        "Fernlet",
        "FernletKit/Sources/AIProviders",
        "FernletKit/Sources/AIContext"
    ]

    /// Markers identifying an on-device-AI prompt builder (Apple FoundationModels API). Any Swift file
    /// under `scanRoots` containing one of these is treated as AI-facing and scanned.
    private static let aiMarkers = [
        "LanguageModelSession",
        "SystemLanguageModel",
        "@Generable",
        "import FoundationModels"
    ]

    /// Files that MUST always be covered even if they stop matching `aiMarkers` (the de-identification
    /// boundary types) plus the two app-resident prompt builders the old hard-coded list omitted. A
    /// missing floor file is a HARD failure — it means coverage silently dropped via a rename/move.
    private static let floorFiles = [
        "AIContextPayload.swift",            // the sanctioned de-identified AI egress payload
        "AIAuditLog.swift",                  // AI audit trail
        "MemoryAgent.swift",                 // memory -> AI de-identification gate
        "FoundationFoodSelection.swift",     // AIProviders prompt builder
        "LaunchPreparationService.swift",    // app-resident: memory -> AI launch path
        "FoundationDishDecomposition.swift", // app-resident prompt builder (previously uncovered)
        "FoodProductWebImporter.swift"       // app-resident prompt builder (previously uncovered)
    ]

    /// Tokens naming a raw sealed/private store type, repository, controller, sealed value type, or a
    /// direct sealed-module import. An AI-facing file containing any of these has reached past the
    /// `AIContext` de-identification boundary, which the S3 wall forbids.
    private static let forbiddenPrivateStoreTokens = [
        // Sealed narrative/log stores, repositories + the private persistence controller.
        "PrivatePersistenceController",
        "MenstrualNarrativeRepository", "JournalNarrativeRepository", "IntimacyLogRepository",
        "MenstrualNarrative", "JournalNarrative", "IntimacyLog",
        // Raw cycle/intimacy value types — must travel only as de-identified AIContext payloads.
        "CyclePhase", "CycleDayEntry", "UserLoggedCycleEvent", "PeriodTrackerStore",
        // Sealed media stores + the pending-narrative buffer/payload.
        "PrivateMediaStore", "MealPhotoStore", "PendingNarrativeBuffer", "PendingNarrativePayload",
        // Any direct import of a sealed module — the highest-value check: it fails a reach into a
        // sealed store regardless of which type is named.
        "import PrivateHealthStore", "import PrivateMemoryStore",
        "import PrivateMediaStore", "import PrivateStoreCore"
    ]

    @Test func aiFacingSourcesCannotReachRawPrivateStoreTypes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        // 1) Discover AI-facing sources by marker across the scan roots (keyed by path to dedupe).
        var covered: [String: URL] = [:]
        for root in Self.scanRoots {
            let rootURL = repoRoot.appendingPathComponent(root)
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if Self.aiMarkers.contains(where: { source.contains($0) }) {
                    covered[url.path] = url
                }
            }
        }

        // 2) Pin the floor. A missing floor file is a hard failure (coverage silently dropped).
        for name in Self.floorFiles {
            if let url = locate(name, under: Self.scanRoots, repoRoot: repoRoot) {
                covered[url.path] = url
            } else {
                Issue.record("S3 grep-wall floor file '\(name)' not found under \(Self.scanRoots) — renamed/moved? Coverage dropped.")
            }
        }

        // Discovery must never collapse to empty (a broken root would otherwise pass vacuously).
        #expect(!covered.isEmpty, "S3 grep-wall discovered zero AI-facing files — discovery is broken.")

        // 3) Scan every covered file for forbidden sealed-store tokens.
        for url in covered.values.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: url, encoding: .utf8)
            let name = url.lastPathComponent
            let hits = Self.forbiddenTokens(in: source)
            #expect(
                hits.isEmpty,
                "\(name) must consume typed, de-identified AIContext payloads, not sealed-store token(s) \(hits)"
            )
        }
    }

    /// Fixture: prove the matcher actually catches a planted sealed-store token (so the scan above is
    /// not vacuously passing). A synthetic AI-facing source that reaches a sealed module/type is flagged;
    /// one that only names the sanctioned de-identified payload is clean.
    @Test func forbiddenTokenMatcherFlagsPlantedSealedTokens() {
        let leaky = """
        import FoundationModels
        import PrivateHealthStore
        @MainActor func build() {
            let session = LanguageModelSession()
            _ = CyclePhase.self
            _ = session
        }
        """
        let hits = S3BoundaryTests.forbiddenTokens(in: leaky)
        #expect(hits.contains("import PrivateHealthStore"))
        #expect(hits.contains("CyclePhase"))

        let clean = """
        import FoundationModels
        @MainActor func build() {
            let session = LanguageModelSession()
            _ = AIContextPayload.self
            _ = session
        }
        """
        #expect(S3BoundaryTests.forbiddenTokens(in: clean).isEmpty)
    }

    /// The forbidden sealed-store tokens present in `source`. Pure + testable.
    static func forbiddenTokens(in source: String) -> [String] {
        forbiddenPrivateStoreTokens.filter { source.contains($0) }
    }

    /// Finds the first file named `filename` under any of `roots`. Returns nil if absent (caller
    /// decides whether that is a hard failure).
    private func locate(_ filename: String, under roots: [String], repoRoot: URL) -> URL? {
        for root in roots {
            let rootURL = repoRoot.appendingPathComponent(root)
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent == filename {
                return url
            }
        }
        return nil
    }
}
