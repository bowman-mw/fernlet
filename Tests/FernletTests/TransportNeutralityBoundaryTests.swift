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
///
/// ProximityKit's own sources, where the radios and their wire and engine live, are a package
/// dependency since ProximityKit plan step A1.3: its package suite of this name holds them to the same
/// three rules. This wall holds the Fernlet code that builds on its radios.
struct TransportNeutralityBoundaryTests {

    /// Everything that must stay free of the framework, each root with the fewest Swift files it may
    /// hold (four fifths of its count, measured at ProximityKit plan step A1.3: 4, 17, 52 and 248), so a
    /// root that stops resolving fails rather than scanning nothing. The modules that build on
    /// ProximityKit's radios: `FernletProximityUI` holds the review screens that left ProximityKit's
    /// `UI/` folder (ProximityKit plan step A0.1), `FernletConnections` Fernlet's connection rules over
    /// the mesh, `FernletSocial` the features that left ProximityKit for it (ProximityKit plan step
    /// A0.4), the presence and recipe-share managers among them, and the app.
    private static let scanRoots: [(root: String, floor: Int)] = [
        (root: "FernletKit/Sources/FernletProximityUI", floor: 3),
        (root: "FernletKit/Sources/FernletConnections", floor: 13),
        (root: "FernletKit/Sources/FernletSocial", floor: 41),
        (root: "App/Fernlet", floor: 198)
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

    /// A hard floor: these files must stay scanned, one or more per root. The presence manager was
    /// neutralized in P1; the recipe-share manager drives the recipe radio, the review sheet shows a
    /// mesh session's photos, the pair profiles name each radio's row, and the rejection-matrix harness
    /// drives the mesh from the app. If one is renamed out of the roots the scan would silently stop
    /// covering it, which is how a wall quietly stops being one. ProximityKit's own floor files (the
    /// coordinator, the mesh manager, the pair session and the transport surface) are its package
    /// suite's.
    private static let floorFiles = [
        "FernletKit/Sources/FernletSocial/Presence/PresenceManager.swift",
        "FernletKit/Sources/FernletSocial/RecipeSharing/ProximityRecipeShareManager.swift",
        "FernletKit/Sources/FernletProximityUI/FriendPhotoReviewSheet.swift",
        "FernletKit/Sources/FernletConnections/FernletPairProfiles.swift",
        "App/Fernlet/Proximity/Feasibility/MeshRejectionMatrixHarness.swift"
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

    /// Repo-relative paths of every Swift file under ``scanRoots``, each root held to its floor: a root
    /// that does not resolve, or holds fewer files than its floor, is recorded as an issue rather than
    /// skipped, so no cell can pass over a walk that lost a root.
    private static func scannedSwiftFiles() throws -> [String] {
        var found: [String] = []
        // R2: bounded by the four roots and each root's finite file list.
        for (root, floor) in scanRoots {
            let rootURL = RepoRoot.url.appendingPathComponent(root)
            let walker = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil)
            let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            #expect(files.count >= floor, "the scan saw \(files.count) Swift files under \(root), below its floor \(floor)")
            found += files.map(repoRelativePath)
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
