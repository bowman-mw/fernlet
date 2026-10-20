// FeedbackBoundaryTests.swift
// FernletTests
//
// Grep-wall for haptics and sound, sibling of the pasteboard, no-tracking, Power-of-10 and
// memory-lifecycle walls (sounds-and-haptics pass, 2026-10-20; report §3.9). One discipline:
//
//  FB1  Every haptic, tone and spoken line in shipping code goes through FernletUI's two seams:
//       `FernletFeedback.swift` (haptics and tones, named `FernletFeedbackEvent`s mapped to a feel in
//       one table) and `FernletSpeech.swift` (the opt-in spoken cues). A raw feedback generator, Core
//       Haptics engine, audio player, speech synthesizer, system sound or `.sensoryFeedback(` anywhere
//       else is a cue that skips the person's switches — the app-wide Haptics level, the surface's
//       own switch — and the one table where every feel is tuned. Only the allowlist
//       (`Scripts/feedback-allowlist.json`) can open the wall, and each entry names its invariant.
//
// `.sensoryFeedback(` is banned in the seams too: the player renders every feel through UIKit
// generators, so a SwiftUI kind that plays nothing on iPhone (`.increase`, `.decrease`, `.start`,
// `.stop`, `.levelChange`) has no way back in.
//
// House rules copied from the sibling walls: the scan discovers its inputs from the file system and
// carries a hard FLOOR (a moved root must fail loudly, never pass vacuously), every allowlist entry
// must be USED, and the matcher must trip on a planted token. Comments and string literals are
// stripped before matching (`BackgroundRefreshBoundaryTests.codeLines`), so a doc comment that NAMES a
// generator is not a call.

import Foundation
import Testing

/// Grep-wall proving every shipping haptic, tone and spoken line goes through FernletUI's seams.
struct FeedbackBoundaryTests {

    // MARK: - Scope, floors, seams

    /// The five shipping roots — the canonical set `PowerOfTenBoundaryTests` holds every wall to.
    static let shippingRoots = [
        "FernletKit/Sources", "App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension",
        "App/FernletMessagesExtension"
    ]

    /// Floor for the shipping scan; a root that stops resolving trips it rather than passing empty.
    static let minimumShippingFilesScanned = 300

    /// One banned spelling: a name for the failure message and the pattern that finds it in code.
    struct BannedToken: Hashable, Sendable {
        let name: String
        let pattern: String
    }

    /// Everything that makes a phone buzz, chime or speak on its own.
    static let bannedTokens: [BannedToken] = [
        BannedToken(name: "UIImpactFeedbackGenerator", pattern: #"\bUIImpactFeedbackGenerator\b"#),
        BannedToken(name: "UINotificationFeedbackGenerator", pattern: #"\bUINotificationFeedbackGenerator\b"#),
        BannedToken(name: "UISelectionFeedbackGenerator", pattern: #"\bUISelectionFeedbackGenerator\b"#),
        BannedToken(name: "CHHapticEngine", pattern: #"\bCHHapticEngine\b"#),
        BannedToken(name: "AVAudioPlayer", pattern: #"\bAVAudioPlayer\b"#),
        BannedToken(name: "AVSpeechSynthesizer", pattern: #"\bAVSpeechSynthesizer\b"#),
        // A prefix on purpose: `…WithCompletion` is the same call.
        BannedToken(name: "AudioServicesPlaySystemSound", pattern: #"\bAudioServicesPlaySystemSound"#),
        BannedToken(name: "AudioServicesPlayAlertSound", pattern: #"\bAudioServicesPlayAlertSound"#),
        BannedToken(name: ".sensoryFeedback(", pattern: #"\.sensoryFeedback\s*\("#),
    ]

    /// The two seams and exactly which banned spellings each may hold.
    static let seams: [String: Set<String>] = [
        "FernletKit/Sources/FernletUI/FernletFeedback.swift": [
            "UIImpactFeedbackGenerator", "UINotificationFeedbackGenerator", "UISelectionFeedbackGenerator",
            "AudioServicesPlaySystemSound",
        ],
        "FernletKit/Sources/FernletUI/FernletSpeech.swift": ["AVSpeechSynthesizer"],
    ]

    /// One allowlist entry, decoded from `Scripts/feedback-allowlist.json`: a repo-relative path, the
    /// banned spelling it may hold, and the invariant that makes it safe.
    struct Exemption: Decodable, Hashable, Sendable {
        let path: String
        let token: String
        let reason: String
    }

    static let allowlistPath = "Scripts/feedback-allowlist.json"

    static func allowlist() throws -> [Exemption] {
        let url = RepoRoot.url.appendingPathComponent(allowlistPath)
        return try JSONDecoder().decode([Exemption].self, from: Data(contentsOf: url))
    }

    // MARK: - Scan

    /// One banned spelling found in code.
    struct Hit: Hashable, Sendable {
        let path: String
        let line: Int
        let token: String
    }

    /// The whole shipping scan: every hit, the files seen, and anything that could not be read.
    struct TreeScan: Sendable {
        var hits: [Hit] = []
        var files: [String] = []
        var unreadable: [String] = []
    }

    static let sharedScan: TreeScan = scan(repoRoot: RepoRoot.url)

    /// Scans the five shipping roots. Never throws or traps: unreadable files are listed for the
    /// enforcement tests to fail on.
    static func scan(repoRoot: URL) -> TreeScan {
        var result = TreeScan()
        for root in shippingRoots {
            for path in PowerOfTenBoundaryTests.swiftFiles(under: root, repoRoot: repoRoot) {
                guard let source = try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8) else {
                    result.unreadable.append(path)
                    continue
                }
                result.files.append(path)
                result.hits += hits(in: source, path: path)
            }
        }
        return result
    }

    /// Every banned spelling in `source`'s code, comments and string literals removed.
    static func hits(in source: String, path: String) -> [Hit] {
        var found: [Hit] = []
        for (number, code) in BackgroundRefreshBoundaryTests.codeLines(source, removingStringLiterals: true) {
            for token in bannedTokens where matches(token.pattern, in: code) {
                found.append(Hit(path: path, line: number, token: token.name))
            }
        }
        return found
    }

    private static func matches(_ pattern: String, in line: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Whether `hit` sits in a seam that may hold its spelling, or is allowlisted.
    static func permitted(_ hit: Hit, allowlist: [Exemption]) -> Bool {
        if seams[hit.path]?.contains(hit.token) == true { return true }
        return allowlist.contains { $0.path == hit.path && $0.token == hit.token }
    }

    // MARK: - Floors

    /// The roots resolve and the enumerator found a shipping-sized tree; unreadable files fail loudly.
    @Test func shippingRootsResolveAndClearTheFileFloor() {
        let scan = Self.sharedScan
        #expect(scan.unreadable.isEmpty, "Unreadable shipping files: \(scan.unreadable)")
        #expect(scan.files.count >= Self.minimumShippingFilesScanned,
                "Scanned only \(scan.files.count) files (floor \(Self.minimumShippingFilesScanned)) — a shipping root stopped resolving; fix RepoRoot / shippingRoots rather than the floor")
        for root in Self.shippingRoots {
            #expect(scan.files.contains { $0.hasPrefix(root + "/") }, "Root \(root) contributed no files")
        }
        for seam in Self.seams.keys {
            #expect(scan.files.contains(seam), "Seam \(seam) moved — update FeedbackBoundaryTests.seams with it")
        }
    }

    // MARK: - FB1: every cue goes through a seam

    @Test func everyShippingCueGoesThroughFernletUIsSeams() throws {
        let allowlist = try Self.allowlist()
        let seamHits = Self.sharedScan.hits.filter { Self.seams[$0.path] != nil }
        #expect(seamHits.contains { $0.token == "UIImpactFeedbackGenerator" },
                "FernletFeedback.swift no longer plays an impact — the matcher stopped matching, or the renderer moved")
        #expect(seamHits.contains { $0.token == "AVSpeechSynthesizer" },
                "FernletSpeech.swift no longer names its synthesizer — the matcher stopped matching, or the voice moved")

        let stray = Self.sharedScan.hits.filter { !Self.permitted($0, allowlist: allowlist) }
        #expect(stray.isEmpty, """
            FB1: these lines make a cue outside FernletUI's seams, so the app-wide Haptics level and the \
            surface's own switch never see them, and the feel is tuned nowhere. Name the moment as a \
            `FernletFeedbackEvent` and play it — `FernletFeedback.system.play(.failed)`, or \
            `.fernletFeedback(.captured, trigger: value)` for a value change — or add an entry to \
            \(Self.allowlistPath) naming the invariant that makes the raw call safe:
            \(stray.map { "\($0.path):\($0.line) \($0.token)" }.joined(separator: "\n"))
            """)
    }

    /// The widget process can never play a cue (haptics need a foreground app), and the runner's state
    /// file compiles into it — so the widget target must not reach for the player at all.
    @Test func theWidgetNeverReachesForThePlayer() throws {
        for path in Self.sharedScan.files where path.hasPrefix("App/FernletWidgets/") {
            let source = try String(contentsOf: RepoRoot.url.appendingPathComponent(path), encoding: .utf8)
            let code = BackgroundRefreshBoundaryTests.codeLines(source, removingStringLiterals: true).map { $0.1 }
            #expect(!code.contains { $0.contains("FernletFeedback") }, "\(path) names FernletFeedback; the widget plays nothing")
        }
    }

    // MARK: - Allowlist contract

    /// Every exemption must be USED and must state its invariant.
    @Test func allowlistIsFullyUsed() throws {
        let allowlist = try Self.allowlist()
        let stale = allowlist.filter { exemption in
            !Self.sharedScan.hits.contains { $0.path == exemption.path && $0.token == exemption.token }
        }
        #expect(stale.isEmpty, "Stale exemptions (site fixed, moved, or unknown): \(stale.map { "\($0.path) \($0.token)" })")
        #expect(allowlist.allSatisfy { !$0.reason.trimmingCharacters(in: .whitespaces).isEmpty },
                "Every exemption must state its invariant")
        let known = Set(Self.bannedTokens.map(\.name))
        #expect(allowlist.allSatisfy { known.contains($0.token) }, "An exemption names a token the wall does not ban")
    }

    // MARK: - Fixtures (the matcher must trip on a planted token and pass a near-miss)

    @Test func fixturesTripTheMatcher() {
        func tokens(_ source: String) -> [String] { Self.hits(in: source, path: "x.swift").map(\.token) }
        #expect(tokens("UIImpactFeedbackGenerator(style: .soft).impactOccurred()\n") == ["UIImpactFeedbackGenerator"])
        #expect(tokens("let g = UISelectionFeedbackGenerator()\n") == ["UISelectionFeedbackGenerator"])
        #expect(tokens("UINotificationFeedbackGenerator().notificationOccurred(.success)\n") == ["UINotificationFeedbackGenerator"])
        #expect(tokens("let engine = try CHHapticEngine()\n") == ["CHHapticEngine"])
        #expect(tokens("let p = try AVAudioPlayer(contentsOf: url)\n") == ["AVAudioPlayer"])
        #expect(tokens("let s = AVSpeechSynthesizer()\n") == ["AVSpeechSynthesizer"])
        #expect(tokens("AudioServicesPlaySystemSoundWithCompletion(id) {}\n") == ["AudioServicesPlaySystemSound"])
        #expect(tokens("AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)\n") == ["AudioServicesPlayAlertSound"])
        #expect(tokens("  .sensoryFeedback(.success, trigger: x)\n") == [".sensoryFeedback("])
        #expect(tokens("  .sensoryFeedback (trigger: x) { _, _ in nil }\n") == [".sensoryFeedback("])
        // Near-misses: a comment naming a generator, a string mentioning one, the helper itself.
        #expect(tokens("// replaces UIImpactFeedbackGenerator(style: .heavy)\n").isEmpty, "a comment is not a call")
        #expect(tokens("let doc = \"see .sensoryFeedback(\"\n").isEmpty, "a string is not a call")
        #expect(tokens("FernletFeedback.system.play(.failed)\n").isEmpty)
        #expect(tokens(".fernletFeedback(.captured, trigger: handedOff) { _, caught in caught }\n").isEmpty)

        let inSeam = Hit(path: "FernletKit/Sources/FernletUI/FernletFeedback.swift", line: 1, token: "UIImpactFeedbackGenerator")
        #expect(Self.permitted(inSeam, allowlist: []))
        let wrongSeam = Hit(path: "FernletKit/Sources/FernletUI/FernletSpeech.swift", line: 1, token: "UIImpactFeedbackGenerator")
        #expect(!Self.permitted(wrongSeam, allowlist: []), "each seam may hold only its own spellings")
        let swiftUIInSeam = Hit(path: "FernletKit/Sources/FernletUI/FernletFeedback.swift", line: 1, token: ".sensoryFeedback(")
        #expect(!Self.permitted(swiftUIInSeam, allowlist: []), ".sensoryFeedback( is banned in the seams too")
        let elsewhere = Hit(path: "App/Fernlet/HomeView.swift", line: 1, token: "UIImpactFeedbackGenerator")
        #expect(!Self.permitted(elsewhere, allowlist: []))
        #expect(Self.permitted(elsewhere, allowlist: [Exemption(path: elsewhere.path, token: elsewhere.token, reason: "r")]))
    }
}
