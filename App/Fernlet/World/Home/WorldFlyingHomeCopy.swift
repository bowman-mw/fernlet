import Foundation

/// The words of Home in the air (World-Airports-Spec §6.2, §12): Sprout's three bubble lines (drafts; the first's Spanish
/// is the mockup's approved `T()` pair, the rest are drafts in `r7-airports-ui-es-flying.json`) and the scene's one
/// VoiceOver label.
nonisolated enum WorldFlyingHomeCopy {
    /// How many lines Sprout takes in turn in the air.
    static let lineCount = 3

    /// Sprout's line in the air for its `turn`: "Up in the air! Wake me when we land." first, then the other two, in
    /// turn each time the bubble comes up again.
    static func line(turn: Int) -> String {
        switch max(turn, 0) % lineCount {
        case 1:
            String(localized: "worldAirport.flying.line.2", defaultValue: "Clouds look like snacks.",
                   comment: "Sprout's bubble on Home while flying, line 2 of 3")
        case 2:
            String(localized: "worldAirport.flying.line.3", defaultValue: "Are we there yet?",
                   comment: "Sprout's bubble on Home while flying, line 3 of 3")
        default:
            String(localized: "worldAirport.flying.line.1", defaultValue: "Up in the air! Wake me when we land.",
                   comment: "Sprout's bubble on Home while flying, line 1 of 3")
        }
    }

    /// VoiceOver for the whole scene, one image: "Sprout, flying, its face pressed to the plane's window".
    static func scene(companion: String) -> String {
        String(localized: "worldAirport.flying.scene", defaultValue: "\(companion), flying, its face pressed to the plane's window",
               comment: "VoiceOver: Home while flying, the scene of the companion looking out of a plane's window; the companion's name")
    }
}
