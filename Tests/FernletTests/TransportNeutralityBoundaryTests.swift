import Foundation
import Testing

/// Grep-wall for P1's whole point: **MultipeerConnectivity stops at two files.**
///
/// Transport neutrality is only worth having if it stays true. Nothing in the compiler enforces it —
/// `MultipeerConnectivity` is an SDK framework, so the S3 wall's
/// `DIAGNOSE_MISSING_TARGET_DEPENDENCIES` mechanism cannot see it, and re-adding `import
/// MultipeerConnectivity` to a manager compiles clean and passes every existing test. This scan is
/// the only thing that would notice.
///
/// It matters most in P2, when a second `PeerTransport` conformer lands over Network.framework QUIC.
/// The value of that arrangement is that the managers cannot tell which transport they are on; a
/// stray MC type in a manager quietly takes that away, and the symptom would not appear until P9
/// tried to delete MultipeerConnectivity and found it load-bearing somewhere nobody expected.
struct TransportNeutralityBoundaryTests {

    /// Everything that must stay free of the framework. The three radio managers are the ones that
    /// actually dropped their import in P1; the wire and engine roots are scanned so a new file
    /// cannot introduce one.
    private static let scanRoots = [
        "FernletKit/Sources/ProximityKit",
        "App/Fernlet"
    ]

    /// The two files allowed to name MultipeerConnectivity types, by repo-relative path.
    ///
    /// `MeshMultipeerSession.swift` owns the framework: the MCSession, the delegates, the one
    /// `MCSessionSendDataMode` mapping, and the private `MCPeerID ↔ PeerEndpointKey` map.
    /// `MCPeerIDStore.swift` persists the MC peer identity itself and is named in the privacy-wipe
    /// ledger, so it retires with MC in P9 rather than being neutralized now.
    private static let permittedFiles = [
        "FernletKit/Sources/ProximityKit/Transport/MeshMultipeerSession.swift",
        "FernletKit/Sources/ProximityKit/Transport/MCPeerIDStore.swift"
    ]

    /// Framework type prefixes. Deliberately matched as whole identifiers so `MCPeerIDStoring`,
    /// `FileMCPeerIDStore` and `MeshMultipeerSession` — Fernlet's own names — do not trip the scan.
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

    @Test func multipeerConnectivityIsNotImportedOutsideItsTwoFiles() throws {
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

    @Test func noFrameworkPeerTypeAppearsOutsideItsTwoFiles() throws {
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
