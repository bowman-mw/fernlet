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
        // Raw tier-two behavioral memory record (WI-7b). `TierTwoMemoryRecord` lives in
        // `FernletDomainModel`, a direct dependency of BOTH walled consumers — so the compiler wall
        // cannot keep it out of an AI prompt builder. AI may only receive `MemoryAgent`'s de-identified
        // String projection (recency/confidence/diagnostic-filtered + char-capped), never the raw
        // record. Naming the type in any AI-facing file OTHER than the sanctioned `MemoryAgent` gate
        // (see `sanctionedGateExemptions`) means a builder reached past that boundary.
        "TierTwoMemoryRecord",
        // Any direct import of a sealed module — the highest-value check: it fails a reach into a
        // sealed store regardless of which type is named.
        "import PrivateHealthStore", "import PrivateMemoryStore",
        "import PrivateMediaStore", "import PrivateStoreCore"
    ]

    /// Per-file token exemptions for the *sanctioned* de-identification gate(s). A gate is allowed to
    /// name the raw type it gates on — that is its entire job — while every OTHER forbidden token stays
    /// enforced for that file (so the gate still cannot, e.g., `import PrivateHealthStore`).
    ///
    /// `MemoryAgent` is the sole sanctioned reader of raw `TierTwoMemoryRecord`s: `filteredContext`
    /// projects them down to a recency/confidence/diagnostic-filtered, char-capped String before any
    /// prompt sees them. Exempting only the `TierTwoMemoryRecord` token here keeps the gate green while
    /// still flagging any NEW AI-facing file that reaches the raw record directly.
    private static let sanctionedGateExemptions: [String: Set<String>] = [
        "MemoryAgent.swift": ["TierTwoMemoryRecord"]
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

        // 3) Scan every covered file for forbidden sealed-store tokens, minus any token the file is the
        //    sanctioned gate for (e.g. MemoryAgent may name TierTwoMemoryRecord — every OTHER token still
        //    applies to it).
        for url in covered.values.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: url, encoding: .utf8)
            let name = url.lastPathComponent
            let exempt = Self.sanctionedGateExemptions[name] ?? []
            let hits = Self.forbiddenTokens(in: source).filter { !exempt.contains($0) }
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

    /// WI-7b: the raw `TierTwoMemoryRecord` is a forbidden token, and the sanctioned-gate exemption is
    /// scoped to exactly `MemoryAgent.swift` + exactly that token — so the de-identification gate stays
    /// green while any OTHER AI-facing file reaching the raw record is flagged, and the gate cannot use
    /// the exemption to smuggle a different sealed-store token.
    @Test func tierTwoMemoryRecordTokenIsGatedToMemoryAgentOnly() {
        let names = "func filteredContext(from m: [TierTwoMemoryRecord]) -> String { \"\" }"

        // The pure matcher flags the raw record type.
        #expect(S3BoundaryTests.forbiddenTokens(in: names).contains("TierTwoMemoryRecord"))

        // The sanctioned gate (MemoryAgent) is exempted for that one token -> clean.
        func hits(_ source: String, file: String) -> [String] {
            let exempt = S3BoundaryTests.sanctionedGateExemptions[file] ?? []
            return S3BoundaryTests.forbiddenTokens(in: source).filter { !exempt.contains($0) }
        }
        #expect(hits(names, file: "MemoryAgent.swift").isEmpty)

        // Any OTHER AI-facing file naming the raw record is still a wall breach.
        #expect(hits(names, file: "SomeFuturePromptBuilder.swift").contains("TierTwoMemoryRecord"))

        // The exemption is token-scoped: it does NOT let the gate reach a different sealed store.
        let leakyGate = "import PrivateHealthStore\nfunc f(_ m: [TierTwoMemoryRecord]) {}"
        #expect(hits(leakyGate, file: "MemoryAgent.swift").contains("import PrivateHealthStore"))
    }

    /// F12: identifier-boundary matching must NOT fire on a sealed token embedded in a longer,
    /// unrelated identifier (the source of false-positive CI hard-fails), but MUST still catch the
    /// sealed symbol used as a whole identifier or qualified member access.
    @Test func forbiddenTokenMatcherIgnoresSubstringsOfLongerIdentifiers() {
        // Benign longer identifiers that merely CONTAIN a forbidden token as a substring → no hit.
        #expect(S3BoundaryTests.forbiddenTokens(in: "let x = CyclePhaseResolver()").isEmpty)
        #expect(S3BoundaryTests.forbiddenTokens(in: "protocol JournalNarrativeStoring {}").isEmpty)
        #expect(S3BoundaryTests.forbiddenTokens(in: "struct IntimacyLogFormatter {}").isEmpty)

        // Real whole-identifier uses → still flagged.
        #expect(S3BoundaryTests.forbiddenTokens(in: "let p: CyclePhase = .follicular").contains("CyclePhase"))
        #expect(S3BoundaryTests.forbiddenTokens(in: "PrivateHealthStore.MenstrualNarrative.self")
            .contains("MenstrualNarrative"))
        #expect(S3BoundaryTests.forbiddenTokens(in: "import PrivateMemoryStore").contains("import PrivateMemoryStore"))
    }

    /// The forbidden sealed-store tokens present in `source`, matched at IDENTIFIER BOUNDARIES so a
    /// token never fires as a substring of a longer, unrelated identifier (e.g. `CyclePhase` must not
    /// match `CyclePhaseResolver`; `JournalNarrative` must not match `JournalNarrativeStoring`). This
    /// removes false-positive CI hard-fails while still catching every real use of the sealed symbol
    /// (real uses appear as whole identifiers or `import X` lines). Pure + testable.
    static func forbiddenTokens(in source: String) -> [String] {
        forbiddenPrivateStoreTokens.filter { containsAtIdentifierBoundary(source, $0) }
    }

    /// True iff `token` occurs in `source` NOT flanked by identifier characters ([A-Za-z0-9_]) on its
    /// alphanumeric ends — i.e. as a whole symbol, not embedded in a longer identifier. Boundary hits
    /// are a strict subset of plain-substring hits, so this can only ever REMOVE false positives; it
    /// never lets a real whole-identifier breach slip through.
    static func containsAtIdentifierBoundary(_ source: String, _ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let chars = Array(source)
        let tok = Array(token)
        guard chars.count >= tok.count else { return false }
        func isIdentifierChar(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }
        for start in 0...(chars.count - tok.count) where Array(chars[start..<(start + tok.count)]) == tok {
            let leftIsIdentifier = start > 0 && isIdentifierChar(chars[start - 1])
            let rightIndex = start + tok.count
            let rightIsIdentifier = rightIndex < chars.count && isIdentifierChar(chars[rightIndex])
            if !leftIsIdentifier && !rightIsIdentifier { return true }
        }
        return false
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
