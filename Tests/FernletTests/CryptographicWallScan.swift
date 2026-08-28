import Foundation

/// The source-scanning half shared by the two cryptographic grep-walls.
///
/// ``CryptographicPurposeBoundaryTests`` proves every raw primitive call NAMES a purpose;
/// ``CryptographicEscapeHatchCensusTests`` pins how many calls answer that demand with an escape
/// hatch instead. Both must scan the same bytes with the same window, or the census pins a number
/// the wall does not enforce over — so the roots, the primitive markers and the context window live
/// here once rather than twice.
///
/// ## Why the roots are enumerated rather than globbed
///
/// A shipping target no wall enumerates is a target with no wall. The three extension roots were
/// added in the crypto standardization round's Phase 5 for exactly that reason: all three were
/// clean, and nothing checked that they stayed clean.
enum CryptographicWallScan {

    /// Every shipping Swift root, repo-relative. Matches `Scripts/power-of-10-scan.py`'s
    /// `SHIPPING_ROOTS`: the set of directories whose Swift reaches a user's device.
    static let roots = [
        "FernletKit/Sources",
        "App/Fernlet",
        "App/FernletWidgets",
        "App/FernletShareExtension",
        "App/FernletMessagesExtension"
    ]

    /// The raw CryptoKit call sites the purpose wall demands a domain at.
    static let primitiveMarkers = [
        "signature(for:", "isValidSignature(", "hkdfDerivedSymmetricKey", "HKDF<", "HMAC<",
        "ChaChaPoly.seal", "ChaChaPoly.open", "AES.GCM.seal", "AES.GCM.open"
    ]

    /// The comment that silences the purpose wall, for the paths with no domain to name.
    static let escapeHatchMarker = "cryptographic-domain:"

    /// A root that does not resolve to a directory of Swift.
    ///
    /// Thrown rather than shrugged off with an empty array: a renamed or mistyped root would
    /// otherwise make both walls pass by scanning nothing, which is the one failure mode a grep-wall
    /// cannot survive.
    struct MissingRoot: Error, CustomStringConvertible {
        let relativePath: String
        var description: String {
            "Cryptographic wall root '\(relativePath)' holds no Swift files. If the target moved or"
                + " was renamed, update CryptographicWallScan.roots — do NOT let the walls scan an"
                + " empty directory and call themselves green."
        }
    }

    /// Every `.swift` file under every root, with a missing or empty root raised as an error.
    static func sourceFiles() throws -> [URL] {
        let repoRoot = RepoRoot.url
        var all: [URL] = []
        // R2: bounded by `roots`.
        for relativePath in roots {
            let files = swiftFiles(under: repoRoot.appendingPathComponent(relativePath))
            guard !files.isEmpty else { throw MissingRoot(relativePath: relativePath) }
            all.append(contentsOf: files)
        }
        return all
    }

    /// The path a failure message should print — repo-relative, so it is the same string on every
    /// machine and in CI.
    static func repoRelativePath(_ url: URL) -> String {
        let root = RepoRoot.url.path
        guard url.path.hasPrefix(root) else { return url.path }
        return String(url.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The window the purpose wall reads around a primitive call.
    ///
    /// Asymmetric: a multi-line primitive call names its purpose inside its own argument list, which
    /// sits BELOW the call's opening line, never above it.
    static func context(around index: Int, in lines: [String]) -> String {
        let lower = max(0, index - 3)
        let upper = min(lines.count - 1, index + 6)
        return lines[lower...upper].joined(separator: "\n")
    }

    /// Whether a line opens a raw primitive call the wall demands a domain at.
    static func isPrimitiveCall(_ line: String) -> Bool {
        primitiveMarkers.contains(where: line.contains)
    }

    private static func swiftFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
