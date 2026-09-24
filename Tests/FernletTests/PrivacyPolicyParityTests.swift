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
    /// The background-continuation marker (added 2026-09-18, network migration P8 item 7, plan
    /// §17.3) pins the sentence that says a live in-person session may keep running for a while
    /// after the app leaves the screen — that it uses the local network and battery, and that iOS
    /// may refuse or end it. It is the first thing the friend features do while the person is not
    /// looking at them, so a copy that drifts out of sync on this one is a copy that under-describes
    /// what the app does in the background.
    ///
    /// The nine markers added 2026-09-24 pin the disclosures of the 2026-09-23 owner-decisions round.
    /// Several of them replaced text that was false in all three copies at once, the same trap as the
    /// 2026-08-20 pair — a parity check stays green over a policy that is consistently wrong:
    /// - `Nothing Fernlet reads from Apple Health is stored in iCloud` — Health readings had synced in
    ///   the day records while the policy said Health data was used only on the device;
    /// - `Share with Health` — every write is gated on Fernlet's own switch (a logged workout used to
    ///   be written with it off);
    /// - `never leave this device in any form` — sensitive (Tier-2) memories had synced in plaintext
    ///   while the policy placed them in the sealed store;
    /// - `Core memories never hold your journal text` — a memory had kept a 120-character excerpt;
    /// - `Apple's Vision framework` — the on-device photo reads for food logging ("never analyzed"
    ///   was wrong);
    /// - `through Apple's Messages service` — the iMessage app's cards, the one route by which the
    ///   user hands an item to people who are not in the room;
    /// - `Data from Open Food Facts (ODbL)` — the barcode lookup's new destination and its licence;
    /// - `right after the age check` — intimacy tracking is on by default for users 16+ ("hidden and
    ///   off by default" was wrong), with the onboarding choice;
    /// - `how long is left` — the shop pause, whose record survives Delete Everything.
    private static let substanceMarkers = [
        "iOS may refuse or end it at any time",
        "never retroactively repurposed",
        "The no-collection guarantee does not expire",
        "requires your fresh, affirmative consent",
        "verifiability statement",
        "Docs/Verifiability.md",
        "Manual plan exchange",
        "signed record of that report",
        "Deliver hearts later",
        "cervical mucus quality",
        "includes your journal entries",
        "Nothing Fernlet reads from Apple Health is stored in iCloud",
        "Share with Health",
        "never leave this device in any form",
        "Core memories never hold your journal text",
        "Apple's Vision framework",
        "through Apple's Messages service",
        "Data from Open Food Facts (ODbL)",
        "right after the age check",
        "how long is left"
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
            // The Swift copy is read comment-stripped: a marker satisfied by a `//` line explaining
            // the clause would be a green wall over a policy that no longer says it. The Markdown
            // and the HTML are prose end to end, so they are read whole.
            let policy = path.hasSuffix(".swift") ? MeshRoutedSourceScan.codeOnly(text) : text
            for marker in Self.substanceMarkers {
                #expect(policy.contains(marker), "\(path) is missing the clause: \(marker)")
            }
        }
    }
}
