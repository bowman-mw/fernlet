import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The companion's emotions are never persisted, never synced, and never on the friend wire
/// (owner decision 2026-09-24).
///
/// Three mechanical halves:
/// - the type cannot be encoded, so no `Codable` model can carry it without a compile error;
/// - every shipping file that names it is on a reviewed allowlist, so a sync, export, proximity or
///   persistence file that starts to is red here in the commit that does it;
/// - the friend fold and the persisted day score are pinned unchanged.
///
/// The one place the token leaves the app process — the widget snapshot's emotion timeline in the
/// app-group file — is covered by `CompanionEmotionPresentationTests` and the widget contract in
/// `LocalizationBoundaryTests`.
struct CompanionEmotionPrivacyTests {

    /// Every shipping Swift file allowed to name the emotion (`CompanionEmotion…` or
    /// `companionEmotion…`, which covers the engine, the widget mirror and the snapshot field).
    ///
    /// Adding a file here is a privacy decision, not bookkeeping: say in the commit why the new file
    /// needs the emotion and that it neither persists nor transmits it.
    static let allowedFiles: Set<String> = [
        "FernletKit/Sources/FernletDomainModel/CompanionEmotion.swift",
        "FernletKit/Sources/FernletScoring/CompanionEmotionEngine.swift",
        "App/Fernlet/CompanionEmotionArt.swift",
        "App/Fernlet/CompanionEmotionMotifs.swift",
        "App/Fernlet/CompanionEmotionPreferences.swift",
        "App/Fernlet/CompanionFeelingsSettingsCard.swift",
        "App/Fernlet/CompanionVectorAssets.swift",
        "App/Fernlet/FernletStore+CompanionEmotion.swift",
        "App/Fernlet/FernletStore.swift",
        "App/Fernlet/HomeView.swift",
        "App/Fernlet/WidgetBridge.swift",
        "App/FernletWidgets/FernletWidgetsBundle.swift",
        "App/FernletWidgets/WidgetSharedModels.swift"
    ]

    /// The shipping roots scanned — every target the app ships.
    static let scanRoots = ["FernletKit/Sources", "App"]

    @Test func theEmotionCannotBeEncoded() {
        #expect(!(CompanionEmotion.happy as Any is any Encodable), "CompanionEmotion became Encodable — it can now be persisted or sent")
        #expect(!(CompanionEmotion.self as Any is any Decodable.Type), "CompanionEmotion became Decodable")
    }

    /// Code only — comments are stripped, so a doc line pointing at the type is not a use of it.
    @Test func onlyTheAllowlistedFilesNameTheEmotion() throws {
        var namers: Set<String> = []
        var scanned = 0
        for root in Self.scanRoots {
            let enumerator = try #require(FileManager.default.enumerator(at: RepoRoot.url(root), includingPropertiesForKeys: nil),
                                          "could not enumerate \(root)")
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                scanned += 1
                let code = source.components(separatedBy: "\n").map { line -> String in
                    guard let comment = line.range(of: "//") else { return line }
                    return String(line[..<comment.lowerBound])
                }.joined(separator: "\n")
                guard code.contains("CompanionEmotion") || code.contains("companionEmotion") else { continue }
                namers.insert(Self.repoRelativePath(of: url))
            }
        }
        #expect(scanned > 500, "scanned \(scanned) files — the roots moved and this wall is looking at nothing")
        #expect(namers.subtracting(Self.allowedFiles).isEmpty, """
            these files name the companion's emotion but are not on the reviewed allowlist: \
            \(namers.subtracting(Self.allowedFiles).sorted()). The emotion is never persisted, synced, \
            exported or sent to a friend; if the new use does none of those, add the file with the reason.
            """)
        #expect(Self.allowedFiles.subtracting(namers).isEmpty,
                "allowlisted files that no longer name the emotion (prune them): \(Self.allowedFiles.subtracting(namers).sorted())")
    }

    /// Friends keep the three-way fold of the STATE — the emotion changes nothing on the friend wire.
    @Test func theFriendFoldIsUnchanged() {
        let fold: [CompanionState: FriendFuzzyState] = [
            .thriving: .thriving, .okay: .okay, .tired: .struggling, .resting: .struggling, .sick: .struggling
        ]
        for (state, bucket) in fold {
            #expect(state.fuzzy == bucket, "\(state) now folds to \(state.fuzzy)")
        }
        let payload = FriendStatePayload(state: .okay, appearance: .standard)
        let fields = Mirror(reflecting: payload).children.compactMap(\.label)
        #expect(fields == ["format", "version", "id", "state", "appearance"], "the friend payload grew a field: \(fields)")
    }

    /// The persisted day score carries no emotion: its JSON has the same keys it always had.
    @Test func theDailyHealthScoreCarriesNoEmotion() throws {
        let score = DailyHealthScore(dateKey: "2026-09-24", score: 0.6, companionState: .okay, computedAt: Date(timeIntervalSince1970: 0))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(score)) as? [String: Any] ?? [:]
        #expect(!json.keys.contains { $0.lowercased().contains("emotion") }, "DailyHealthScore now encodes \(json.keys.sorted())")
    }

    /// The widget path never reads the heart ledger: the store's widget timeline and the inputs it is
    /// built from name no heart, so a cold background refresh touches no ProximityKit sidecar.
    @Test func theWidgetPathNeverReadsTheHeartLedger() throws {
        let source = try RepoRoot.source("App/Fernlet/FernletStore+CompanionEmotion.swift")
        for signature in ["func widgetEmotionTimeline(", "func companionEmotionInputs(appetiteCuesEnabled:"] {
            let body = try #require(Self.body(of: signature, in: source), "\(signature) is gone")
            #expect(!body.contains("heart"), "\(signature) now reads a heart — the widget path must not touch the ledger")
        }
    }

    /// A scanned file's path relative to the repository root.
    static func repoRelativePath(of url: URL) -> String {
        let root = RepoRoot.url.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    /// The text between a function's opening brace and its matching closing brace.
    static func body(of signature: String, in source: String) -> String? {
        guard let start = source.range(of: signature),
              let open = source[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1 }
            if depth == 0 { return String(source[open...index]) }
            index = source.index(after: index)
        }
        return nil
    }
}
