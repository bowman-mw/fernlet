import Foundation
import Testing

/// Pins the privacy-policy triple in sync (Docs/Release-Process.md §2.3): the in-app copy
/// (`Fernlet/PrivacyPolicyView.swift`), the canonical document (`Docs/Privacy-Policy.md`), and
/// the hosted page (`Site/privacy/index.html`) must carry the same effective date and the same
/// load-bearing substance.
///
/// House style of the grep-wall suites: reads the three files from the repo tree anchored at
/// `#filePath`. The substance markers are deliberately few and deliberately the perpetual-promise
/// clauses — the exact section where a copy silently drifting apart matters most (this suite
/// exists because the in-app copy once shipped without the verifiability paragraph the other two
/// copies gained).
struct PrivacyPolicyParityTests {
    /// The three copies Release-Process.md §2.3 requires to match, repo-root-relative.
    private static let copies = [
        "Fernlet/PrivacyPolicyView.swift",
        "Docs/Privacy-Policy.md",
        "Site/privacy/index.html"
    ]

    /// Substance markers every copy must contain: the perpetual-promise clauses plus the
    /// verifiability pointer added 2026-08-09. Chosen as exact phrases that survive each
    /// format's markup (Swift string literal, Markdown, HTML).
    private static let substanceMarkers = [
        "never retroactively repurposed",
        "The no-collection guarantee does not expire",
        "requires your fresh, affirmative consent",
        "verifiability statement",
        "Docs/Verifiability.md"
    ]

    /// Loads each copy's text, keyed by its repo-relative path.
    private func loadCopies() throws -> [(path: String, text: String)] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Self.copies.map { path in
            (path, try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8))
        }
    }

    // MARK: Proves all three copies carry the effective date declared by the in-app view (the
    // "same effective date" half of Release-Process.md §2.3).
    @Test func effectiveDateMatchesAcrossAllThreeCopies() throws {
        let texts = try loadCopies()
        let swiftSource = try #require(texts.first { $0.path.hasSuffix(".swift") }).text
        // The in-app declaration is the reference: `private static let effectiveDate = "…"`.
        let marker = "effectiveDate = \""
        let start = try #require(swiftSource.range(of: marker)?.upperBound,
                                 "could not find the effectiveDate declaration in PrivacyPolicyView.swift")
        let end = try #require(swiftSource[start...].firstIndex(of: "\""))
        let date = String(swiftSource[start..<end])
        #expect(!date.isEmpty)
        for (path, text) in texts {
            #expect(text.contains(date), "\(path) does not carry effective date \(date)")
        }
    }

    // MARK: Proves all three copies carry the perpetual-promise substance, including the
    // verifiability paragraph (the "same substance" half of Release-Process.md §2.3).
    @Test func perpetualPromiseSubstanceExistsInAllThreeCopies() throws {
        for (path, text) in try loadCopies() {
            for marker in Self.substanceMarkers {
                #expect(text.contains(marker), "\(path) is missing the clause: \(marker)")
            }
        }
    }
}
