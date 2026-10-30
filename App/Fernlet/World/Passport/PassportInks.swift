import Foundation
import SwiftUI

/// The passport's inks (World-Exploration-Spec §3): one ink per stamp, deep blues for the oceans and bright blues
/// for the seas, and dark mode's lightening of every ink 38 % toward white (the mockup's `mix2`).
nonisolated enum PassportInk {
    /// How far dark mode moves each ink toward white.
    static let darkLift = 0.38

    /// `hex` (`0xRRGGBB`) moved 38 % toward white, each channel rounded as the mockup's `mix2` rounds it.
    static func mix2(_ hex: UInt32) -> UInt32 {
        let channels = [(hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF].map { channel -> UInt32 in
            let value = Double(channel)
            return UInt32((value + (255 - value) * darkLift).rounded(.toNearestOrAwayFromZero))
        }
        return (channels[0] << 16) | (channels[1] << 8) | channels[2]
    }

    /// The ink to draw `hex` in: as given in light mode, ``mix2(_:)`` in dark.
    static func resolved(_ hex: UInt32, dark: Bool) -> UInt32 {
        dark ? mix2(hex) : hex
    }

    /// The passport's paper, which a date box is filled with and measured against (the mockup's `--pp-paper`).
    static func paper(dark: Bool) -> UInt32 { dark ? 0x2A2721 : 0xFFF9EA }

    /// The colour of a stamp's date box (World-Passport-Spec §6): the stamp's ink (``mix2(_:)`` in dark mode)
    /// moved toward `#2A1808` (toward cream `#FFF1CF` in dark mode) in steps of 8 % until it reads at 4.6:1 on the
    /// paper, 7:1 with Increase Contrast (the mockup's `textInk`). Bounded: at most 13 steps.
    static func dateInk(_ hex: UInt32, dark: Bool, increasedContrast: Bool) -> UInt32 {
        let start = resolved(hex, dark: dark), target: UInt32 = dark ? 0xFFF1CF : 0x2A1808
        let background = paper(dark: dark), floor = increasedContrast ? 7.0 : 4.6
        var ink = start, fraction = 0.0
        for _ in 0..<13 where contrast(ink, background) < floor && fraction < 1 {
            fraction += 0.08
            ink = mix(start, toward: target, fraction)
        }
        return ink
    }

    /// `hex` moved `fraction` of the way toward `target`, each channel rounded.
    static func mix(_ hex: UInt32, toward target: UInt32, _ fraction: Double) -> UInt32 {
        let shifts: [UInt32] = [16, 8, 0]
        return shifts.reduce(UInt32(0)) { result, shift in
            let from = Double((hex >> shift) & 0xFF), to = Double((target >> shift) & 0xFF)
            let value = UInt32(min(max((from + (to - from) * fraction).rounded(.toNearestOrAwayFromZero), 0), 255))
            return result | (value << shift)
        }
    }

    /// The WCAG contrast ratio of two colours.
    static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The WCAG relative luminance of `hex`.
    static func luminance(_ hex: UInt32) -> Double {
        let weights: [(UInt32, Double)] = [(16, 0.2126), (8, 0.7152), (0, 0.0722)]
        return weights.reduce(0) { sum, pair in
            let value = Double((hex >> pair.0) & 0xFF) / 255
            let linear = value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            return sum + linear * pair.1
        }
    }

    /// `hex` as a colour.
    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

/// The stable seed every stamp's tilt and wear come from: the mockup's own hash of the stamp's name
/// (`seed = seed × 31 + code unit`, kept to 32 bits), never Swift's `Hasher`, which changes every launch.
nonisolated enum PassportStampSeed {
    /// The most UTF-16 code units hashed (a stamp's key is a short token).
    static let maxUnits = 64

    /// The seed of `name`: a stamp's frozen key (a country's lower-case code, a continent's or ocean's key, a sea's
    /// token).
    static func seed(_ name: String) -> UInt32 {
        var seed: UInt32 = 0
        for unit in name.utf16.prefix(maxUnits) {
            seed = seed &* 31 &+ UInt32(unit)
        }
        return seed
    }

    /// The stamp's tilt in whole degrees, −6 to +6 (`seed mod 13 − 6`, the mockup's rule).
    static func tilt(_ name: String) -> Int {
        Int(seed(name) % 13) - 6
    }

    /// How far a stamp sits off its spot on a page, in points (World-Passport-Spec §6): −7…+7 across and −5…+5
    /// down, from the same seed as its tilt (the mockup's `(seed >> 3) mod 15 − 7` and `(seed >> 7) mod 11 − 5`,
    /// with unsigned shifts so a long key stays in range).
    static func nudge(_ name: String) -> (across: Int, down: Int) {
        let seed = seed(name)
        return (Int((seed >> 3) % 15) - 7, Int((seed >> 7) % 11) - 5)
    }

    /// The next value of the wear generator after `value` (a 32-bit linear congruential step).
    static func next(_ value: UInt32) -> UInt32 {
        value &* 1_103_515_245 &+ 12_345
    }

    /// Whether a pixel whose generator value is `value` is worn away (about 7 % of them).
    static func isWorn(_ value: UInt32) -> Bool {
        value % 100 < 7
    }
}

/// Each sea's bright blue (World-Exploration-Spec §3, `ex-pass-oceans` draft 2 and `ex-med-seas`): the Caribbean,
/// the Sea of Japan and the Mediterranean's nine as the spec lists them, every other sea from the eight bright
/// blues by a stable hash of its token, moved along the list past any ink a neighbouring sea already has.
///
/// Built once from the atlas's sea tokens and their neighbours (`WorldAtlas.seaNeighbours()`), in token order so
/// the same atlas always gives the same inks. Bounded by the atlas's sea table (at most 250).
nonisolated struct PassportSeaInks: Equatable, Sendable {
    /// The bright blues, in the spec's order (each at least 3.2:1 on both passport papers).
    static let palette: [UInt32] = [0x0E8EA6, 0x2F86C8, 0x12938A, 0x4A7FD0, 0x2E78C2, 0x2C8FB0, 0x1B8C80, 0x0F7F99]
    /// The seas the spec gives an ink by name, by Wikidata token.
    static let fixed: [String: UInt32] = [
        "Q1247": 0x0E8EA6,   // Caribbean Sea
        "Q27092": 0x2F86C8,  // Sea of Japan
        "Q4918": 0x2F86C8,   // Mediterranean Sea
        "Q199408": 0x12938A, // Alboran Sea
        "Q200712": 0x4A7FD0, // Balearic Sea
        "Q42820": 0x1B8C80,  // Ligurian Sea
        "Q38882": 0x0E8EA6,  // Tyrrhenian Sea
        "Q37495": 0x2E78C2,  // Ionian Sea
        "Q13924": 0x2C8FB0,  // Adriatic Sea
        "Q34575": 0x0F7F99,  // Aegean Sea
        "Q193149": 0x12938A  // Sea of Crete
    ]

    /// Each sea's ink, by token.
    let inks: [String: UInt32]

    /// The inks for `tokens` (the atlas's seas), keeping each sea's ink off its `neighbours`' where the list allows.
    init(tokens: [String], neighbours: [String: Set<String>]) {
        var inks: [String: UInt32] = [:]
        for token in tokens { inks[token] = Self.fixed[token] }
        // Bounded: the atlas's sea table, each sea trying at most the eight blues.
        for token in tokens.sorted() where inks[token] == nil {
            let taken = Set((neighbours[token] ?? []).compactMap { inks[$0] })
            let start = Int(PassportStampSeed.seed(token) % UInt32(Self.palette.count))
            let free = (0..<Self.palette.count).map { Self.palette[(start + $0) % Self.palette.count] }
                .first { !taken.contains($0) }
            inks[token] = free ?? Self.palette[start]
        }
        self.inks = inks
    }

    /// `token`'s ink: its assigned blue, or (a sea this table doesn't know) its hash's.
    func ink(for token: String) -> UInt32 {
        inks[token] ?? Self.fixed[token]
            ?? Self.palette[Int(PassportStampSeed.seed(token) % UInt32(Self.palette.count))]
    }
}
