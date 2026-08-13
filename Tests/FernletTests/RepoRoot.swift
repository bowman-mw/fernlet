import Foundation

/// Locates the repository root for the grep-wall suites, which read shipping source off disk rather
/// than through a bundle.
///
/// **Why this exists as one type.** Every wall suite used to derive the root by counting
/// `deletingLastPathComponent()` calls up from its own `#filePath` — a hardcoded depth that was only
/// correct while the test target sat directly at the repo root. Moving `FernletTests/` under
/// `Tests/` silently made every one of those counts resolve one directory short. That failure mode
/// is the dangerous one: a wall suite handed a wrong root enumerates *nothing*, finds no violations,
/// and **passes vacuously** — the wall reports green precisely when it has stopped looking. Anchoring
/// on marker files instead of a depth count means a future layout change either still resolves or
/// fails loudly, never quietly.
///
/// **Concurrency.** `url` is an immutable `let` resolved once on first touch; safe from any actor.
enum RepoRoot {

    /// Directories and files that together identify the repo root and no other directory. All three
    /// must be present, so a partial match (e.g. some unrelated `Docs/`) cannot satisfy the search.
    private static let markers = ["FernletKit/Package.swift", "App/Fernlet", "Docs"]

    /// The repository root, found by walking up from this file until every entry in ``markers``
    /// resolves.
    ///
    /// Traps rather than returning a fallback: a wall suite that cannot find the source tree must
    /// stop the run, not scan an empty directory and call itself green.
    static let url: URL = {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.pathComponents.count > 1 {
            if markers.allSatisfy({
                FileManager.default.fileExists(atPath: candidate.appendingPathComponent($0).path)
            }) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        fatalError("""
            Could not locate the repo root by walking up from \(#filePath).
            Expected an ancestor containing all of: \(markers.joined(separator: ", ")).
            If the repository layout moved, update RepoRoot.markers — do NOT let the wall suites \
            fall back to a guessed path, because a wrong root makes them pass without scanning.
            """)
    }()

    /// `url` joined with a repo-root-relative path, e.g. `App/Fernlet/FernletStore.swift`.
    static func url(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }

    /// The UTF-8 contents of a repo-root-relative file. Throws if it is missing, so a rename fails
    /// loudly instead of yielding an empty string that every `contains` check would pass against.
    static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }
}
