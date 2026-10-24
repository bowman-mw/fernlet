// LiveActivityWorldLookTests.swift
// FernletTests
//
// The workout and cooking Live Activities in the World look (World Review Batch 4, b4-la-* and
// b4-di-*, approved 2026-10-24). The views live in the widget extension, which this app-hosted suite
// cannot import, so these read the sources, as WorkoutLiveActivityParityTests does: pixel art instead
// of SF Symbols, the framed paper card with a dark version, every control still running its intent,
// the compact island still speaking, and the card's colours clearing WCAG AA in both appearances.

import Foundation
import Testing

/// Source-level checks that the Live Activities wear the approved World look without losing a value,
/// a control or a spoken label.
struct LiveActivityWorldLookTests {

    private static let workout = "App/FernletWidgets/WorkoutLiveActivity.swift"
    private static let cooking = "App/FernletWidgets/CookingLiveActivity.swift"
    private static let parts = "App/FernletWidgets/LiveActivityParts.swift"
    private static let look = "App/FernletWidgets/LiveActivityLook.swift"

    /// Every icon is pixel art now: no SF Symbol is left on either activity or their shared parts.
    @Test func theActivitiesDrawPixelArtNotSymbols() throws {
        for path in [Self.workout, Self.cooking, Self.parts] {
            let source = try RepoRoot.source(path)
            #expect(!source.contains("Image(systemName:"), "\(path) still draws an SF Symbol")
            #expect(!source.contains("systemImage:"), "\(path) still labels with an SF Symbol")
            #expect(source.contains("LiveActivitySpriteView("), "\(path) draws no pixel icon")
        }
    }

    /// Both Lock Screen cards sit in the framed paper card, and both islands keep the leaf keyline.
    @Test func bothCardsAreFramedPaperAndBothIslandsLeafGreen() throws {
        for path in [Self.workout, Self.cooking] {
            let source = try RepoRoot.source(path)
            #expect(source.contains("LiveActivityCard {"), "\(path) is not in the framed card")
            #expect(source.contains(".keylineTint(LiveActivityIslandLook.leaf)"))
        }
        let look = try RepoRoot.source(Self.look)
        #expect(look.contains("static let dark = LiveActivityLook("), "the card has no dark version")
        #expect(look.contains("ContainerRelativeShape().strokeBorder(look.frame, lineWidth: 3)"))
    }

    /// The restyle moved faces, not behaviour: every control still runs its intent in the app's process.
    @Test func everyControlStillRunsItsIntent() throws {
        let workout = try RepoRoot.source(Self.workout)
        for intent in ["GuidedWorkoutMarkSetDoneIntent()", "GuidedWorkoutSkipRestIntent()",
                       "GuidedWorkoutAddRestIntent()", "GuidedWorkoutShortenRestIntent()"] {
            #expect(workout.contains("Button(intent: \(intent))"), "lost \(intent)")
        }
        #expect(workout.components(separatedBy: ".buttonStyle(.plain)").count - 1 == 4)
        #expect(workout.contains(".accessibilityInputLabels([Text(\"Minus 15 seconds\")"))
        #expect(workout.contains(".accessibilityInputLabels([Text(\"Plus 15 seconds\")"))
        let cooking = try RepoRoot.source(Self.cooking)
        #expect(cooking.contains("Button(intent: NextCookingStepIntent())"))
        #expect(cooking.contains("state.isLastStep ? Text(\"Finish\") : Text(\"Next\")"))
    }

    /// The compact and minimal slots carry no words, so their pixel icons still say which activity is
    /// running, and the pause bars say "Paused".
    @Test func theCompactIslandStillSpeaks() throws {
        let workout = try RepoRoot.source(Self.workout)
        for label in ["label: Text(\"Workout\")", "label: Text(\"Paused\")", "label: Text(\"In progress\")"] {
            #expect(workout.contains(label), "the workout island lost \(label)")
        }
        let cooking = try RepoRoot.source(Self.cooking)
        for label in ["label: Text(\"Cooking\")", "label: Text(\"Paused\")"] {
            #expect(cooking.contains(label), "the cooking island lost \(label)")
        }
    }

    /// Data parity on the Lock Screen: the cardio part keeps its countdown (the design drew the round
    /// without it, but the run still counts it down), and the rest card keeps the set's weight.
    @Test func theCardKeepsEveryValue() throws {
        let workout = try RepoRoot.source(Self.workout)
        #expect(workout.contains("} else if holdWindow(state) != nil {\n            HoldCountdownText(state: state, font: LiveActivityFont.countdown"))
        #expect(workout.contains("WorkoutRestLoadLine(load: load)"))
        #expect(workout.contains("LiveActivityProgressSquares(index: state.exerciseIndex, total: state.totalExercises)"))
    }

    /// Every text colour on the card clears 4.5:1 on its paper, and each button's word on its fill, in
    /// light and in dark.
    @Test func theCardsColoursClearAAInBothAppearances() throws {
        let source = try RepoRoot.source(Self.look)
        for (name, start, end) in [("light", "static let light = LiveActivityLook(", "static let dark"),
                                   ("dark", "static let dark = LiveActivityLook(", "static func current")] {
            let colours = try #require(Self.colours(in: source, from: start, to: end), "\(name) look not found")
            let pairs = [("ink", "paper"), ("soft", "paper"), ("moss", "paper"),
                         ("buttonInk", "buttonFill"), ("secondaryInk", "secondaryFill")]
            for (text, ground) in pairs {
                let fore = try #require(colours[text], "\(name) has no \(text)")
                let back = try #require(colours[ground], "\(name) has no \(ground)")
                let ratio = Self.contrast(fore, back)
                #expect(ratio >= 4.5, "\(name) \(text) is \(ratio):1 on \(ground)")
            }
        }
    }

    /// The `name: Color(laHex: 0xRRGGBB)` pairs between two markers.
    private static func colours(in source: String, from start: String, to end: String) -> [String: UInt32]? {
        guard let lower = source.range(of: start)?.upperBound,
              let upper = source.range(of: end, range: lower..<source.endIndex)?.lowerBound else { return nil }
        let block = String(source[lower..<upper])
        let pattern = #/(\w+): Color\(laHex: 0x([0-9A-Fa-f]{6})\)/#
        var found: [String: UInt32] = [:]
        for match in block.matches(of: pattern) {
            found[String(match.1)] = UInt32(match.2, radix: 16)
        }
        return found.isEmpty ? nil : found
    }

    /// WCAG 2 contrast ratio of two `0xRRGGBB` colours.
    private static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// WCAG 2 relative luminance of an `0xRRGGBB` colour.
    private static func luminance(_ value: UInt32) -> Double {
        let channels = [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF].map { channel -> Double in
            let c = Double(channel) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
