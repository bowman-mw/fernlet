import Foundation
import Testing

/// Grep-wall for what P1 set up and the deletion round finished: **MultipeerConnectivity is gone.**
///
/// Transport neutrality is only worth having if it stays true. Nothing in the compiler enforces it —
/// `MultipeerConnectivity` is an SDK framework, so the S3 wall's
/// `DIAGNOSE_MISSING_TARGET_DEPENDENCIES` mechanism cannot see it, and re-adding `import
/// MultipeerConnectivity` to a manager compiles clean and passes every existing test. This scan is
/// the only thing that would notice.
///
/// P1 narrowed the framework to two files so a later phase could delete them; P9 crossed the three
/// radios to Network.framework QUIC behind that seam, the cutover round flipped the default, and the
/// deletion round (2026-09-22) removed the two files. The wall stays because the risk it names never
/// went away: a stray framework type in a manager would compile clean today exactly as it would
/// have in P2, and this scan is still the only thing that would notice.
struct TransportNeutralityBoundaryTests {

    /// Everything that must stay free of the framework. The three radio managers are the ones that
    /// actually dropped their import in P1; the wire and engine roots are scanned so a new file
    /// cannot introduce one.
    private static let scanRoots = [
        "FernletKit/Sources/ProximityKit",
        "App/Fernlet"
    ]

    /// The files allowed to name MultipeerConnectivity types, by repo-relative path. **Empty, and
    /// that is the point.**
    ///
    /// P1 narrowed the framework to two files so a later phase could delete them; the deletion round
    /// (2026-09-22) did. An empty permit list does not switch this wall off — both scans below still
    /// walk every Swift file under ``scanRoots`` and now assert **zero** occurrences instead of two
    /// exceptions, which is the strongest this wall has ever been. Do not prune the suite for looking
    /// vacuous: it is the only thing standing between the tree and a re-added `import
    /// MultipeerConnectivity`, which would compile clean (the framework is an SDK one, so the S3
    /// wall cannot see it) and pass every other test.
    ///
    /// Re-adding an entry here is a phase decision, not a fix for a red.
    private static let permittedFiles: [String] = []

    /// Framework type prefixes, matched as whole identifiers.
    ///
    /// The whole-identifier rule outlived the names it was written for (`MCPeerIDStoring`,
    /// `FileMCPeerIDStore`, `MeshMultipeerSession` — Fernlet's own, all deleted in the deletion
    /// round). It stays because the rule is the correct one: a future `MCSessionFoo` of Fernlet's
    /// own would otherwise be reported under `MCSession`, and `MCSessionSendDataMode` must be
    /// reported once, under its own entry. ``containsIdentifier(_:in:)`` is where it lives; its own
    /// cells pin both edges.
    private static let frameworkSymbols = [
        "MCSession",
        "MCPeerID",
        "MCNearbyServiceAdvertiser",
        "MCNearbyServiceBrowser",
        "MCSessionSendDataMode",
        "MCSessionState",
        "MCError"
    ]

    /// A hard floor: these files were neutralized in P1 and must stay scanned. If one is renamed out
    /// of the roots the scan would silently stop covering it, which is how a wall quietly stops
    /// being one.
    private static let floorFiles = [
        "FernletKit/Sources/ProximityKit/Engine/ProximityCoordinator.swift",
        "FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift",
        "FernletKit/Sources/ProximityKit/Presence/PresenceManager.swift",
        "FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift",
        "FernletKit/Sources/ProximityKit/Transport/PeerTransport.swift",
        "FernletKit/Sources/ProximityKit/Transport/PeerHandle.swift"
    ]

    @Test func multipeerConnectivityIsNotImportedAnywhere() throws {
        var offenders: [String] = []
        for path in try Self.scannedSwiftFiles() where !Self.permittedFiles.contains(path) {
            let source = try String(contentsOf: RepoRoot.url.appendingPathComponent(path), encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated()
            where line.hasPrefix("import MultipeerConnectivity") {
                offenders.append("\(path):\(index + 1)")
            }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) file(s) import MultipeerConnectivity outside the two files that own it.
            The shared transport surface is framework-free so a QUIC conformer can slot in beside the
            MC one (plan §6/§7); an import here is how that quietly stops being true:
            \(offenders.sorted().joined(separator: "\n"))
            """
        )
    }

    @Test func noFrameworkPeerTypeAppearsAnywhere() throws {
        var offenders: [String] = []
        for path in try Self.scannedSwiftFiles() where !Self.permittedFiles.contains(path) {
            let source = try String(contentsOf: RepoRoot.url.appendingPathComponent(path), encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                offenders.append(contentsOf: Self.violations(in: line, at: index, of: path))
            }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) MultipeerConnectivity type reference(s) outside the two files that own
            them. Prose about MC is fine — a type is not:
            \(offenders.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Every floor file exists and is inside a scan root, so coverage cannot drop by a rename.
    @Test func everyFloorFileIsStillCovered() throws {
        let scanned = Set(try Self.scannedSwiftFiles())
        for path in Self.floorFiles {
            #expect(scanned.contains(path), "floor file dropped out of the scan: \(path)")
        }
        for path in Self.permittedFiles {
            #expect(
                FileManager.default.fileExists(atPath: RepoRoot.url.appendingPathComponent(path).path),
                "permitted file no longer exists — prune the entry or the wall is scanning nothing: \(path)"
            )
        }
    }

    // MARK: - Scanning

    /// Repo-relative paths of every Swift file under ``scanRoots``.
    private static func scannedSwiftFiles() throws -> [String] {
        var found: [String] = []
        for root in scanRoots {
            let rootURL = RepoRoot.url.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(
                at: rootURL, includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                found.append(repoRelativePath(url))
            }
        }
        return found
    }

    private static func repoRelativePath(_ url: URL) -> String {
        let base = RepoRoot.url.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base + "/") else { return full }
        return String(full.dropFirst(base.count + 1))
    }

    /// Framework symbols used as CODE on one line. Comment lines are skipped: the neutralized files
    /// deliberately explain what the MC layer beneath them does, and prose is not a dependency.
    private static func violations(in line: String, at index: Int, of path: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { return [] }
        let code = withoutStringLiterals(withoutTrailingComment(line))
        var hits: [String] = []
        for symbol in frameworkSymbols where containsIdentifier(symbol, in: code) {
            hits.append("\(path):\(index + 1) — \(symbol)")
        }
        return hits
    }

    /// Drops a trailing `//` comment. Prose beside code is prose; only the code half is a dependency.
    private static func withoutTrailingComment(_ line: String) -> String {
        guard let marker = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<marker.lowerBound])
    }

    /// Blanks out double-quoted literals. A UI label or an audit key that spells a framework type —
    /// the connection inspector's own "MCSession" row is the live example — names it for a human,
    /// and is not a compile-time dependency on it.
    private static func withoutStringLiterals(_ line: String) -> String {
        var result = ""
        var insideLiteral = false
        var escaped = false
        for character in line {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" && insideLiteral {
                escaped = true
                continue
            }
            if character == "\"" {
                insideLiteral.toggle()
                continue
            }
            if !insideLiteral { result.append(character) }
        }
        return result
    }

    /// Whole-identifier match: the character before must not be a Swift identifier character (so
    /// `FileMCPeerIDStore` does not match `MCPeerID`) and the character after must not continue the
    /// identifier (so `MCSessionSendDataMode` is reported once, under its own entry, not as
    /// `MCSession`).
    private static func containsIdentifier(_ symbol: String, in line: String) -> Bool {
        var searchStart = line.startIndex
        while let range = line.range(of: symbol, range: searchStart..<line.endIndex) {
            let beforeOK = range.lowerBound == line.startIndex
                || !isIdentifierCharacter(line[line.index(before: range.lowerBound)])
            let afterOK = range.upperBound == line.endIndex
                || !isIdentifierCharacter(line[range.upperBound])
            if beforeOK && afterOK { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
