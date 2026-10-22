import SwiftUI

/// The time-of-day phase, ported from `CompanionDayPhase` in `App/Fernlet/CompanionAmbienceLayer.swift`
/// (dawn 5–8, day 8–17, dusk 17–21, night otherwise), with the same wash colours.
///
/// On the live map the phase tints the whole map (the parity table's "the map's light") and
/// colours the sky square in the clock badge. Night also switches Apple's map to its dark style.
nonisolated enum SkyPhase: String, CaseIterable, Identifiable, Sendable {
    case dawn, day, dusk, night

    var id: String { rawValue }

    /// The shipping hour → phase mapping, unchanged.
    static func phase(forHour hour: Int) -> SkyPhase {
        switch hour {
        case 5..<8: .dawn
        case 8..<17: .day
        case 17..<21: .dusk
        default: .night
        }
    }

    /// The phase's display name.
    var label: String { rawValue.capitalized }

    /// The design page's sample clock for this phase, shown when the phase is a fixture.
    var sampleClock: String {
        switch self {
        case .dawn: "6:40"
        case .day: "12:30"
        case .dusk: "7:15"
        case .night: "10:20"
        }
    }

    /// The sky square's fill in the clock badge (design page `PHASES[].hud`).
    var badgeSkyHex: UInt32 {
        switch self {
        case .dawn: 0xF3B98F
        case .day: 0x8CC7E6
        case .dusk: 0xD98A6C
        case .night: 0x2B3557
        }
    }

    /// The pixel icons in the sky square.
    var badgeIcons: [PixelSprite] {
        switch self {
        case .dawn, .dusk: [PixelSprites.sun]
        case .day: [PixelSprites.sun, PixelSprites.cloud]
        case .night: [PixelSprites.moon]
        }
    }

    /// Whether Apple's map should draw in its dark style.
    var isDark: Bool { self == .night }
}

/// The full-screen wash over the map for a ``SkyPhase``: the ambience layer's `tintGradient`, its
/// stops copied from `AmbiencePalette` (dawn and day rise from the top, dusk wells up from the
/// bottom, night is a deep-blue vertical wash, lighter here because the map itself turns dark).
struct SkyWash: View {
    let phase: SkyPhase

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
                LinearGradient(colors: [Self.rgb(58, 68, 112).opacity(0.24), Self.rgb(44, 52, 90).opacity(0.30)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: 1)
    }
}
