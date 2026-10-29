import Foundation
import Testing

/// The feeling faces on the Home Screen widgets (owner's Q37, round 6b), pinned over the widget's own
/// sources (the extension has no test target; the render harness draws and checks the faces): the Home
/// Screen families draw happy, sad, hungry and thirsty with their motifs, the Lock Screen keeps the state
/// face, and the feelings stay outside the map painter's twin.
@MainActor
struct WidgetFeelingFaceTests {
    private static let widgetRoot = "App/FernletWidgets/"

    /// The small card, the medium card and the map widget wear the feeling and its motif.
    @Test func theHomeScreenFamiliesDrawTheFeeling() throws {
        let cards = try RepoRoot.source(Self.widgetRoot + "CompanionWidgetViews.swift")
        let map = try RepoRoot.source(Self.widgetRoot + "MapWidgetViews.swift")
        #expect(cards.components(separatedBy: "grid: entry.homeScreenGrid(increasedContrast: contrast == .increased)").count == 3,
                "the small and the medium card draw the feeling's face")
        #expect(cards.components(separatedBy: "motif: entry.homeScreenMotif").count == 3, "and its motif")
        #expect(map.contains("grid: entry.companion.homeScreenGrid(increasedContrast: contrast == .increased)"))
        #expect(map.contains("motif: entry.companion.homeScreenMotif"))
    }

    /// The Lock Screen face draws the state only (owner, 2026-09-24), feelings or not.
    @Test func theLockScreenKeepsTheStateFace() throws {
        let cards = try RepoRoot.source(Self.widgetRoot + "CompanionWidgetViews.swift")
        let lock = try #require(cards.components(separatedBy: "struct CompanionLockView: View {").dropFirst().first?
            .components(separatedBy: "\n}\n").first, "the Lock Screen face is gone")
        #expect(lock.contains("grid: entry.companionGrid,"), "the Lock Screen draws the state's grid")
        #expect(!lock.contains("homeScreen"), "and never the Home Screen's feeling")
    }

    /// Exactly the four feelings the owner named, with their motifs. The painter's twin never names the
    /// widget's feelings: since group 17 it lays out their faces' shapes (`WidgetCompanionFace`), so one rule
    /// places every face, but its painter only ever draws the band's face.
    @Test func theFourFeelingsAndTheirMotifs() throws {
        let faces = try RepoRoot.source(Self.widgetRoot + "WidgetFeelingFaces.swift")
        #expect(faces.contains("static let drawn: Set<WidgetCompanionEmotion> = [.happy, .sad, .hungry, .thirsty]"))
        for motif in ["case .happy: self = .twinkle", "case .hungry: self = .apple", "case .thirsty: self = .drop"] {
            #expect(faces.contains(motif), "lost: \(motif)")
        }
        let painter = try RepoRoot.source(Self.widgetRoot + "WidgetPixelCompanion.swift")
        let twin = try #require(WidgetWorldTests.twin(in: painter), "the painter's twin markers are gone")
        #expect(!twin.contains("Feeling") && !twin.contains("Emotion"), "the widget's feelings stay outside the map's twin")
        #expect(twin.contains("let layout = WidgetCompanionFaceLayout(body: body, face: .state(state, pose: pose))"),
                "the map's painter lays out and draws the band's face only")
    }
}
