import SwiftUI

/// The companion's five wellness bands, mirroring `CompanionState` in FernletKit.
///
/// Colours, breath tempo and the low-energy rule are copied from the shipping code
/// (`ModelColors.swift`'s `CompanionState.color` and `CompanionVectorAssets.swift`'s
/// `animationTempo` / `isLowEnergy`). The care scores and thoughts are the design page's fixtures.
nonisolated enum ShellCompanionState: String, CaseIterable, Identifiable, Sendable {
    case thriving, okay, tired, resting, sick

    var id: String { rawValue }

    /// The band's display name.
    var label: String {
        switch self {
        case .thriving: "Thriving"
        case .okay: "Okay"
        case .tired: "Tired"
        case .resting: "Resting"
        case .sick: "Sick"
        }
    }

    /// The body colour, as `CompanionState.color` resolves it in light mode.
    var colorHex: UInt32 {
        switch self {
        case .thriving: 0x5E844D
        case .okay: 0xD2973B
        case .tired: 0xB67073
        case .resting: 0x5C6B78
        case .sick: 0xB9543D
        }
    }

    /// The body colour as a SwiftUI colour.
    var color: Color { FernColors.rgb(colorHex) }

    /// Seconds per half breath (`CompanionState.animationTempo`).
    var breathTempo: Double {
        switch self {
        case .thriving: 1.25
        case .okay: 1.65
        case .tired: 2.35
        case .resting: 3.20
        case .sick: 2.80
        }
    }

    /// Tired, resting and sick draw half-lidded eyes (`CompanionState.isLowEnergy`).
    var isLowEnergy: Bool { self == .tired || self == .resting || self == .sick }

    /// The fixture care score for the day, 0...1.
    var careScore: Double {
        switch self {
        case .thriving: 0.92
        case .okay: 0.58
        case .tired: 0.42
        case .resting: 0.50
        case .sick: 0.33
        }
    }

    /// The companion's thought for the speech bubble.
    var thought: String {
        switch self {
        case .thriving: "Good day. Let's see what's out there."
        case .okay: "A glass of water sounds nice."
        case .tired: "A bit tired today. That's okay."
        case .resting: "Taking it slow. Nothing's going anywhere."
        case .sick: "Staying in today. The map will keep."
        }
    }

    /// Resting and sick days are gentle: quick starts say rest counts first.
    var isGentle: Bool { self == .resting || self == .sick }
}
