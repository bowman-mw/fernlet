import Foundation
import Testing

/// One escape hatch, located and classified.
struct CryptographicEscapeHatch: Sendable {
    /// Repo-relative path, so a failure message reads the same on every machine and in CI.
    let path: String
    /// 1-indexed source line.
    let line: Int
    /// The text after `cryptographic-domain:`, trimmed — the label the hatch gives itself.
    let label: String
    /// Whether the marker sits in a `///` documentation comment (prose ABOUT a hatch) rather than on
    /// a line of source (a hatch).
    let isProse: Bool

    /// `path:line`, for the failure messages.
    var printed: String { "\(path):\(line)" }
}

/// Pins how many `// cryptographic-domain:` escape hatches exist, by label.
///
/// ``CryptographicPurposeBoundaryTests`` proves every raw primitive call names a purpose; this suite
/// counts the calls that answer with a hatch instead. [Crypto-Domain-Separation.md](Docs/Crypto-Domain-Separation.md)
/// §Escape-hatch abuse stated the problem the pin exists to fix: the markers are "more than the
/// handful the mechanism reads like, and nothing tracks the number, so a nineteenth passes
/// unremarked." Now a nineteenth fails here.
///
/// ## What each assertion catches
///
/// - The **total** catches a hatch added anywhere in the five shipping roots.
/// - The **per-label counts** catch a hatch that is added and another removed in the same commit,
///   and a hatch relabelled to hide under a more benign category.
/// - The **known-label set** catches a NEW category of hatch, which is a policy change and not a
///   count change.
/// - The **prose-mention window check** catches the way this pin could be evaded honestly: the
///   purpose wall reads a raw context window, so a `///` line merely *mentioning* the marker near a
///   primitive call silences the wall while reading as documentation here.
///
/// ## Updating the pins
///
/// Deliberately. A hatch removed by the crypto standardization round's Phase 3 decrements its label
/// here in the same commit as the deletion, and §Escape-hatch abuse's table is updated to match.
/// Both numbers reach zero for `legacy-read` when the last Class-A and Class-B legacy reader goes.
struct CryptographicEscapeHatchCensusTests {

    /// The label → count pin. The sum is the number §Escape-hatch abuse quotes.
    private static let pinnedByLabel: [String: Int] = [
        "legacy-read": 10,
        "purpose-derived salt": 2,
        "key-derived": 2,
        "authenticatedData-bound aad": 2,
        "v2 device-bound read": 1,
        "purpose-derived legacy-write": 1
    ]

    /// The number of distinct files holding a hatch. §Escape-hatch abuse said 11; the tree has only
    /// ever held 10 (verified against the commit that wrote the sentence), so the doc is what
    /// changed, not the code.
    private static let pinnedFileCount = 10

    /// Prose that merely names the marker, by repo-relative path. Not hatches — but not free either,
    /// which is what ``proseMentionsCannotSilenceTheWall`` checks.
    private static let pinnedProseMentions: [String: Int] = [
        "FernletKit/Sources/PrivateStoreCore/PendingNarrativeBufferFormatCensus.swift": 1
    ]

    @Test func theTotalEscapeHatchCountIsPinned() throws {
        let hatches = try Self.scan().filter { !$0.isProse }
        let expected = Self.pinnedByLabel.values.reduce(0, +)
        let sites = hatches.map { "  \($0.printed) — \($0.label)" }.joined(separator: "\n")
        let message = "Escape-hatch total moved: \(hatches.count) found, \(expected) pinned."
            + " Adding one is a policy act — update pinnedByLabel AND"
            + " Docs/Crypto-Domain-Separation.md §Escape-hatch abuse in the same commit.\n\(sites)"
        #expect(hatches.count == expected, "\(message)")
    }

    @Test func everyEscapeHatchLabelIsPinnedAtItsOwnCount() throws {
        let hatches = try Self.scan().filter { !$0.isProse }
        let found = Dictionary(grouping: hatches, by: \.label).mapValues(\.count)
        for label in Set(found.keys).union(Self.pinnedByLabel.keys).sorted() {
            let sites = found[label] ?? 0
            let pinned = Self.pinnedByLabel[label] ?? 0
            let message = "Escape-hatch label '\(label)': \(sites) found, \(pinned) pinned."
                + " A label the pin does not know is a NEW category of exemption, not a count"
                + " change — say what it means in §Escape-hatch abuse before pinning it."
            #expect(sites == pinned, "\(message)")
        }
    }

    @Test func escapeHatchesStayInTheFilesThatAlreadyHaveThem() throws {
        let hatches = try Self.scan().filter { !$0.isProse }
        let files = Set(hatches.map(\.path))
        let listed = files.sorted().map { "  \($0)" }.joined(separator: "\n")
        let message = "Escape hatches now span \(files.count) files,"
            + " pinned at \(Self.pinnedFileCount):\n\(listed)"
        #expect(files.count == Self.pinnedFileCount, "\(message)")
    }

    /// The purpose wall reads a raw context window, so ANY line carrying the marker silences it —
    /// including a `///` line that only talks about a hatch elsewhere. Prose is allowed; prose
    /// within reach of a primitive call is a hatch wearing documentation.
    @Test func proseMentionsCannotSilenceTheWall() throws {
        let all = try Self.scan()
        let prose = all.filter(\.isProse)
        let found = Dictionary(grouping: prose, by: \.path).mapValues(\.count)
        let foundList = found.sorted { $0.key < $1.key }
        let pinnedList = Self.pinnedProseMentions.sorted { $0.key < $1.key }
        let message = "Prose mentions of the escape-hatch marker moved."
            + " Found: \(foundList), pinned: \(pinnedList)."
        #expect(found == Self.pinnedProseMentions, "\(message)")
        for mention in prose {
            let silencesTheWall = try Self.sitsInsideAPrimitiveWindow(mention)
            let message = "The prose mention at \(mention.printed) sits within the purpose wall's"
                + " context window of a raw primitive call, so it silences the wall exactly as a"
                + " real hatch would. Move the sentence, or make it an honest hatch and pin it."
            #expect(!silencesTheWall, "\(message)")
        }
    }

    // MARK: - Scanning

    private static func scan() throws -> [CryptographicEscapeHatch] {
        var found: [CryptographicEscapeHatch] = []
        // R2: bounded by the file list the roots enumerate.
        for url in try CryptographicWallScan.sourceFiles() {
            let path = CryptographicWallScan.repoRelativePath(url)
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            // R2: bounded by the file's line count.
            for index in lines.indices {
                guard let hatch = hatch(in: lines[index], path: path, line: index + 1) else { continue }
                found.append(hatch)
            }
        }
        return found
    }

    private static func hatch(in line: String, path: String, line number: Int) -> CryptographicEscapeHatch? {
        guard let range = line.range(of: CryptographicWallScan.escapeHatchMarker) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // A documentation comment is prose ABOUT a hatch. A plain `//` line is not exempt: a marker
        // on its own line above a call silences the wall just as a trailing one does, so it counts.
        let isProse = trimmed.hasPrefix("///")
        let label = String(line[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t`"))
        return CryptographicEscapeHatch(path: path, line: number, label: label, isProse: isProse)
    }

    private static func sitsInsideAPrimitiveWindow(_ mention: CryptographicEscapeHatch) throws -> Bool {
        let url = RepoRoot.url.appendingPathComponent(mention.path)
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
        let index = mention.line - 1
        // The wall reads [call - 3, call + 6], so a mention at `index` is reachable from any call in
        // [index - 6, index + 3]. Same asymmetry, mirrored.
        let lower = max(0, index - 6)
        let upper = min(lines.count - 1, index + 3)
        guard lower <= upper else { return false }
        return lines[lower...upper].contains(where: CryptographicWallScan.isPrimitiveCall)
    }
}
