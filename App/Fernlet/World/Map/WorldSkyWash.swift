import SwiftUI

/// The full-screen wash over the map for the time of day: the map's light in the parity table
/// ("Sky and weather → the map's light, and the sky in the clock").
///
/// Its stops are `CompanionAmbienceLayer`'s tint for each `CompanionDayPhase` (dawn and day rise from
/// the top, dusk wells up from the bottom). Night is the time of day, not Dark Mode (design
/// `b1-home-night`): after sunset the light map dims under the approved navy tint, and in Dark Mode,
/// where the map and plates already wear their dark palette, night adds no tint. Decoration only: no
/// touches, hidden from VoiceOver.
struct WorldSkyWash: View {
    let phase: CompanionDayPhase
    /// Whether Dark Mode is on (the map is already dark).
    var darkMode = false

    var body: some View {
        GeometryReader { proxy in
            let reach = max(proxy.size.width, proxy.size.height) * 0.92
            switch phase {
            case .dawn:
                RadialGradient(colors: [Self.rgb(244, 176, 146).opacity(0.42), Self.rgb(244, 176, 146).opacity(0)],
                               center: .top, startRadius: 0, endRadius: reach)
            case .day:
                RadialGradient(colors: [Self.rgb(158, 200, 224).opacity(0.28), Self.rgb(158, 200, 224).opacity(0)],
                               center: .top, startRadius: 0, endRadius: reach)
            case .dusk:
                RadialGradient(colors: [Self.rgb(226, 150, 74).opacity(0.40), Self.rgb(226, 150, 74).opacity(0)],
                               center: .bottom, startRadius: 0, endRadius: reach)
            case .night:
                // The approved tint, `rgba(22, 32, 74, .42)`, over the light map only.
                Self.rgb(22, 32, 74).opacity(darkMode ? 0 : 0.42)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: 1)
    }
}
