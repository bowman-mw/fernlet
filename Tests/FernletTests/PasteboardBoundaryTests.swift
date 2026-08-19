// PasteboardBoundaryTests.swift
// FernletTests
//
// Grep-wall for the general pasteboard, sibling of the S3, no-tracking, Power-of-10 and
// memory-lifecycle walls. One discipline:
//
//  PB1  Every shipping write to `UIPasteboard.general` goes through `setItems(_:options:)` with
//       `.localOnly: true`. A plain `UIPasteboard.general.string = …` is Handoff-synced to every
//       device on the same Apple Account — the copy leaves the phone with no consent surface — and
//       there is NO API to read an item's options back, so this static check is the whole
//       enforcement. `CoachPlanExchangeTests` covers what the coach handoff copies; nothing can
//       cover how it was written except this file.
//
// Reads are deliberately out of scope: `UIPasteboard.general.string` as an r-value (FoodView's
// recipe-URL paste) is a different control, already fronted by the system's "Allow Paste?" prompt.
//
// House rules copied verbatim from the sibling walls: the scan discovers its inputs from the file
// system and carries a hard FLOOR (a moved root must fail loudly, never pass vacuously), every
// allowlist entry must be USED, and the matcher must trip on a planted token.

import Foundation
import Testing

/// Grep-wall proving every shipping pasteboard WRITE is marked device-local.
struct PasteboardBoundaryTests {

    // MARK: - Scope, floors, allowlist

    /// The four shipping roots — same set as the Power-of-10 scanner's `SHIPPING_ROOTS`.
    static let shippingRoots = ["FernletKit/Sources", "App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension"]

    /// Floor for the shipping scan; a root that stops resolving trips it rather than passing empty.
    static let minimumShippingFilesScanned = 300

    /// One allowlist entry: a repo-relative file path plus the invariant that makes it safe.
    struct Exemption: Hashable, Sendable {
        let path: String
        let invariant: String
    }

    /// The exemptions. Each states the invariant a reviewer must re-check before touching the site.
    static let allowlist: [Exemption] = [
        Exemption(
            path: "App/Fernlet/LinkMetadataPrototypeView.swift",
            invariant: "The whole file sits inside `#if DEBUG` (line 8) — a D11 prototype harness that is never compiled into a shipping build, and whose copied value is a test-case URL, not user data."),
    ]

    // MARK: - Scan

    /// One file's pasteboard-relevant facts.
    struct FileFacts: Hashable, Sendable {
        let path: String
        /// A direct property assignment onto the general pasteboard (`.string =`, `.url =`, …).
        let assignsToGeneralPasteboard: Bool
        /// A `setItems(_:options:)` call on the general pasteboard.
        let callsSetItems: Bool
        /// A `.localOnly` option accompanying it.
        let namesLocalOnly: Bool
    }

    /// The whole shipping scan: every file's facts plus anything that could not be read.
    struct TreeScan: Sendable {
        var files: [FileFacts] = []
        var unreadable: [String] = []
    }

    static let sharedScan: TreeScan = scan(repoRoot: RepoRoot.url)

    /// Scans the four shipping roots. Never throws or traps: unreadable files are listed for the
    /// enforcement tests to fail on.
    static func scan(repoRoot: URL) -> TreeScan {
        var result = TreeScan()
        for root in shippingRoots {
            for path in PowerOfTenBoundaryTests.swiftFiles(under: root, repoRoot: repoRoot) {
                guard let source = try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8) else {
                    result.unreadable.append(path)
                    continue
                }
                result.files.append(facts(for: path, source: source))
            }
        }
        return result
    }

    /// A write through a property assignment. `(?!=)` keeps `==` comparisons out, and anchoring on
    /// the property name keeps r-value READS (`= UIPasteboard.general.string`) out.
    static let assignmentPattern =
        #"UIPasteboard\.general\.(string|strings|url|urls|image|images|items|color|colors)\s*=(?!=)"#

    /// A `setItems` call on the general pasteboard, possibly split across lines.
    static let setItemsPattern = #"(?s)UIPasteboard\.general\.setItems\("#

    /// Reduces one file to its facts.
    static func facts(for path: String, source: String) -> FileFacts {
        FileFacts(
            path: path,
            assignsToGeneralPasteboard: matches(assignmentPattern, in: source),
            callsSetItems: matches(setItemsPattern, in: source),
            namesLocalOnly: source.contains(".localOnly")
        )
    }

    private static func matches(_ pattern: String, in source: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        return regex.firstMatch(in: source, options: [], range: NSRange(source.startIndex..., in: source)) != nil
    }

    private static func exempt(_ path: String) -> Bool {
        allowlist.contains { $0.path == path }
    }

    // MARK: - Floors

    /// The roots resolve and the enumerator found a shipping-sized tree; unreadable files fail loudly.
    @Test func shippingRootsResolveAndClearTheFileFloor() {
        let scan = Self.sharedScan
        #expect(scan.unreadable.isEmpty, "Unreadable shipping files: \(scan.unreadable)")
        #expect(scan.files.count >= Self.minimumShippingFilesScanned,
                "Scanned only \(scan.files.count) files (floor \(Self.minimumShippingFilesScanned)) — a shipping root stopped resolving; fix RepoRoot / shippingRoots rather than the floor")
        for root in Self.shippingRoots {
            #expect(scan.files.contains { $0.path.hasPrefix(root + "/") }, "Root \(root) contributed no files")
        }
    }

    // MARK: - PB1: every shipping pasteboard write is localOnly

    @Test func everyShippingPasteboardWriteIsLocalOnly() {
        let writers = Self.sharedScan.files.filter { $0.callsSetItems && !$0.assignsToGeneralPasteboard }
        #expect(!writers.isEmpty,
                "No shipping setItems(_:options:) writer found — the matcher has stopped matching, or the coach handoff copy was removed")

        let assigners = Self.sharedScan.files
            .filter { $0.assignsToGeneralPasteboard && !Self.exempt($0.path) }
            .map(\.path)
        #expect(assigners.isEmpty, """
            PB1: these files write the general pasteboard by assignment. The general pasteboard is \
            Handoff-synced to every device on the same Apple Account unless the item is written \
            localOnly, so an assignment silently copies user data off this device. Use \
            `UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])` \
            (see TrainerExportView.copyForAssistant), or add an Exemption naming the invariant:
            \(assigners.joined(separator: "\n"))
            """)

        let unmarked = writers.filter { !$0.namesLocalOnly }.map(\.path)
        #expect(unmarked.isEmpty, """
            PB1: these files call UIPasteboard.general.setItems without naming `.localOnly`. There is no \
            API to read an item's options back, so this grep is the only thing that can hold the line:
            \(unmarked.joined(separator: "\n"))
            """)
    }

    // MARK: - Allowlist contract

    /// Every exemption must be USED — an entry whose site changed or moved is stale and must be
    /// deleted so the wall never carries a dead invariant.
    @Test func allowlistIsFullyUsed() {
        let scan = Self.sharedScan
        let stale = Self.allowlist.filter { exemption in
            guard let facts = scan.files.first(where: { $0.path == exemption.path }) else { return true }
            return !facts.assignsToGeneralPasteboard
        }
        #expect(stale.isEmpty, "Stale exemptions (site fixed, moved, or unknown): \(stale.map(\.path))")
        #expect(Self.allowlist.allSatisfy { !$0.invariant.isEmpty }, "Every exemption must state its invariant")
    }

    // MARK: - Fixtures (the matcher must trip on a planted token and pass a near-miss)

    @Test func fixturesTripTheMatcher() {
        #expect(Self.facts(for: "a.swift", source: "UIPasteboard.general.string = text\n").assignsToGeneralPasteboard)
        #expect(Self.facts(for: "b.swift", source: "UIPasteboard.general.url = u\n").assignsToGeneralPasteboard)
        #expect(!Self.facts(for: "c.swift", source: "let s = UIPasteboard.general.string?.trimmed\n").assignsToGeneralPasteboard,
                "reads are a different control, fronted by the system paste prompt")
        #expect(!Self.facts(for: "d.swift", source: "if UIPasteboard.general.string == other { }\n").assignsToGeneralPasteboard,
                "a comparison is not a write")

        let good = "UIPasteboard.general.setItems([[t: text]],\n    options: [.localOnly: true])\n"
        #expect(Self.facts(for: "e.swift", source: good).callsSetItems)
        #expect(Self.facts(for: "e.swift", source: good).namesLocalOnly)
        #expect(!Self.facts(for: "f.swift", source: "UIPasteboard.general.setItems([[t: text]])\n").namesLocalOnly)
    }
}
