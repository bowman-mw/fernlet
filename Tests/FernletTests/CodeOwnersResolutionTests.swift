import Foundation
import Testing

/// The CODEOWNERS resolution wall: every pattern in `.github/CODEOWNERS` must resolve to a file or
/// directory that actually exists, so a repo restructure fails loudly instead of silently
/// unprotecting the walls.
///
/// **Why this exists.** GitHub never complains about a CODEOWNERS pattern that matches nothing — it
/// simply stops requiring review for the files the pattern used to cover. The 2026-08-12
/// `App/`+`Tests/` restructure left 11 of 26 entries matching nothing, including all seven wall and
/// crypto test files, and both `Docs/Release-Process.md` §1 and the tripwire comment in
/// `KeyCustodyBoundaryTests` went on asserting a protection that had quietly become false.
///
/// **Path semantics modeled here** (deliberately the subset this file uses, checked strictly):
/// a leading `/` anchors the pattern to the repo root; a trailing `/` means the pattern must be an
/// existing directory; anything else must exist as a file or directory. Patterns that use CODEOWNERS
/// features this matcher does not model — unanchored patterns or `*` globs — fail with instructions
/// to extend the matcher, never silently pass: an unmodeled pattern is an unverified protection.
///
/// In the house style of the other boundary suites: floors against a vacuous pass (an entry count
/// and a known-critical set that must always be present), and failures that name every offending
/// line.
struct CodeOwnersResolutionTests {

    /// One parsed CODEOWNERS rule: the original line (for failure messages) plus its pattern.
    private struct Entry {
        let lineNumber: Int
        let line: String
        let pattern: String
        let owners: [String]
    }

    /// Parses the non-comment lines of `.github/CODEOWNERS` into pattern + owners.
    private func loadEntries() throws -> [Entry] {
        let source = try RepoRoot.source(".github/CODEOWNERS")
        var entries: [Entry] = []
        for (index, rawLine) in source.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let pattern = tokens.first else { continue }
            entries.append(Entry(
                lineNumber: index + 1,
                line: line,
                pattern: pattern,
                owners: Array(tokens.dropFirst())
            ))
        }
        return entries
    }

    /// Every entry must carry at least one `@owner`, use only the anchored glob-free pattern form
    /// this matcher models, and resolve to an existing file or directory under the repo root.
    @Test func everyPatternResolvesToAnExistingPath() throws {
        let entries = try loadEntries()
        var failures: [String] = []
        for entry in entries {
            if entry.owners.isEmpty || !entry.owners.allSatisfy({ $0.hasPrefix("@") }) {
                failures.append("line \(entry.lineNumber): '\(entry.line)' — every rule needs at least one @owner")
                continue
            }
            if entry.pattern.contains("*") {
                failures.append("line \(entry.lineNumber): '\(entry.pattern)' uses a glob this matcher does not model — extend CodeOwnersResolutionTests deliberately before introducing globs, or the entry is an unverified protection")
                continue
            }
            guard entry.pattern.hasPrefix("/") else {
                failures.append("line \(entry.lineNumber): '\(entry.pattern)' is unanchored (no leading /) — this file's style is root-anchored patterns so resolution can be checked; anchor it")
                continue
            }
            let relative = String(entry.pattern.dropFirst())
            let url = RepoRoot.url(relative)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if !exists {
                failures.append("line \(entry.lineNumber): '\(entry.pattern)' matches nothing — the protected file moved or was deleted; fix the path in the same commit")
            } else if entry.pattern.hasSuffix("/") && !isDirectory.boolValue {
                failures.append("line \(entry.lineNumber): '\(entry.pattern)' has a trailing / (directory) but resolves to a file")
            }
        }
        #expect(failures.isEmpty, "CODEOWNERS entries that no longer protect anything:\n\(failures.joined(separator: "\n"))")
    }

    /// The paths whose protection the docs assert by name. A floor set, not the whole file: if a
    /// restructure moves one of these, the resolution test above fails on the stale path, and this
    /// test fails even if someone "fixes" that by deleting the entry.
    private static let requiredPatterns: Set<String> = [
        "/Tests/FernletTests/NoTrackingBoundaryTests.swift",
        "/Tests/FernletTests/S3BoundaryTests.swift",
        "/Tests/FernletTests/KeyCustodyBoundaryTests.swift",
        "/Tests/FernletTests/ColumnCryptoDeviceBindingTests.swift",
        "/Tests/FernletTests/SealedBackupFormatPinTests.swift",
        "/Tests/FernletTests/SecureEnclaveWrapTests.swift",
        "/Tests/FernletTests/FernletLockCryptoTests.swift",
        "/Tests/FernletTests/PowerOfTenBoundaryTests.swift",
        "/Tests/FernletTests/LocalizationBoundaryTests.swift",
        "/Tests/FernletTests/CIGateSelectorBoundaryTests.swift",
        "/Tests/FernletTests/IdentityProvisioningReadTests.swift",
        "/Scripts/run-gated-suites.sh",
        "/FernletKit/Package.swift",
        "/.github/CODEOWNERS",
        "/.github/workflows/s3-wall.yml",
        "/.github/workflows/power-of-10.yml",
    ]

    /// The wall files named in Docs/Verifiability.md and Docs/Release-Process.md stay covered, and
    /// the file cannot silently shrink below the size that covers them.
    @Test func theCriticalSetStaysCovered() throws {
        let entries = try loadEntries()
        let patterns = Set(entries.map(\.pattern))
        let missing = Self.requiredPatterns.subtracting(patterns).sorted()
        #expect(missing.isEmpty, "CODEOWNERS no longer lists wall-critical paths:\n\(missing.joined(separator: "\n"))")
        #expect(entries.count >= 20, "CODEOWNERS parsed only \(entries.count) rules — the parser or the file has broken; the wall set alone is larger than this")
    }
}
