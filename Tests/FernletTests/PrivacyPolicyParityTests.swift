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
        "App/Fernlet/PrivacyPolicyView.swift",
        "Docs/Privacy-Policy.md",
        "Site/privacy/index.html"
    ]

    /// Substance markers every copy must contain: the perpetual-promise clauses, the
    /// verifiability pointer added 2026-08-09, and the manual-plan-exchange disclosure added
    /// 2026-08-12. Chosen as exact phrases that survive each format's markup (Swift string
    /// literal, Markdown, HTML).
    ///
    /// The plan-exchange marker is here because that disclosure is the only one describing data
    /// the user can hand to a third party — it landed in the canonical document alone and sat
    /// out of sync in the other two copies until it was caught, which is exactly the drift this
    /// suite exists to prevent.
    ///
    /// The report-sharing marker (added 2026-08-19, finding L21) pins the same kind of disclosure
    /// for the other user-to-user flow: a moderation report is not device-local and not anonymous —
    /// it is signed and relayed to friends met in person, the reported maker among them — and all
    /// three copies previously said only that "moderation actions take effect on-device".
    ///
    /// The away-hearts marker (added 2026-08-19, finding I32) pins the one exception to "friend
    /// features are in-person only": the opt-in setting leaves sealed hearts in the developer's
    /// CloudKit PUBLIC database, deletable only by the sending device and with no server-side
    /// expiry. All three copies previously said friend activity stays device-to-device, full stop.
    ///
    /// The two markers added 2026-08-20 pin the corrections that closed the largest accuracy gap
    /// this document has had. All three copies previously said Fernlet wrote "only the workouts you
    /// log" and "never" wrote period data, and that the export "excludes the encrypted sealed
    /// categories". Both were false: `HealthKitService` also writes cycle samples, sexual activity,
    /// mindful minutes, and height/body mass (each behind its own Apple permission prompt), and
    /// `DataExportBuilder` deliberately includes journal text because the export sits behind a
    /// fresh biometric check. Nothing in the app changed — the prose was wrong — but a policy that
    /// under-describes what the app writes to Apple Health is exactly the kind of error that only
    /// gets caught by pinning it, because every copy was consistently wrong and the parity check
    /// was therefore green. `cervical mucus quality` pins the write list; the journal phrase pins
    /// the export's contents.
    private static let substanceMarkers = [
        "never retroactively repurposed",
        "The no-collection guarantee does not expire",
        "requires your fresh, affirmative consent",
        "verifiability statement",
        "Docs/Verifiability.md",
        "Manual plan exchange",
        "signed record of that report",
        "Deliver hearts when apart",
        "cervical mucus quality",
        "includes your journal entries"
    ]

    /// Loads each copy's text, keyed by its repo-relative path.
    private func loadCopies() throws -> [(path: String, text: String)] {
        let repoRoot = RepoRoot.url
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
