import FernletUI
import SwiftUI
import WorldMapStore

/// Round 6's pixel art on the map (owner-approved 2026-10-25), key for key from the design page's own
/// tables (`ref.js`: HOUSE, HOTEL, CASE, ZEE): Sprout's house (`ref-home-arrive`), the hotel and Sprout's
/// suitcase (`ref-hotel`), the night's z's (`ref-home-night`), and the bowl and dumbbell of a kept place to
/// eat or train (`ref-places-map`, ink-only so they ink light in dark mode).
nonisolated enum WorldPlaceSprites {
    /// The design's palette for homes and hotels.
    private static let palette: [Character: UInt32] = ["k": 0x4A2E1C, "r": 0xB4573E, "w": 0xF2E3C2, "y": 0xF2D58A,
                                                       "d": 0x7A4B2A, "b": 0x7E9CC4, "g": 0x5E844D]
    static let house = WorldSprite(rows: [".....kkk.....", "....krrrk....", "...krrrrrk...", "..krrrrrrrk..", ".krrrrrrrrrk.",
                                          "kkkkkkkkkkkkk", ".kwwwwwwwwwk.", ".kwyywwwyywk.", ".kwyywwwyywk.", ".kwwwwddwwwk.",
                                          ".kwwwwddwwwk.", ".kkkkkkkkkkk."], palette: palette)
    static let hotel = WorldSprite(rows: ["..kkkkkkkkk..", "..kgggggggk..", "..kkkkkkkkk..", "..kbbbbbbbk..", "..kbyybyybk..",
                                          "..kbbbbbbbk..", "..kbyybyybk..", "..kbbbbbbbk..", "..kbyybyybk..", "..kbbbbbbbk..",
                                          "..kbbbddbbk..", "..kbbbddbbk..", "..kkkkkkkkk.."], palette: palette)
    static let suitcase = WorldSprite(rows: [".kkk.", "k...k", "kdddk", "kdydk", "kdddk", "kkkkk"], palette: palette)
    static let zee = WorldSprite(rows: ["kkkk", "..k.", ".k..", "kkkk"], palette: ["k": 0xFFF6E2])
    /// The bowl of a place to eat, ink only (the recipe bowl's outline).
    static let bowl = WorldSprite(rows: ["......kk.", ".....k...", "kkkkkkkkk", "k.......k", ".k.....k.", "..kkkkk.."],
                                  palette: ["k": WorldSprite.ink])
    /// The dumbbell of a place to train, ink only.
    static let dumbbell = WorldSprite(rows: [".kk.....kk.", "kkk.....kkk", "kkkkkkkkkkk", "kkk.....kkk", ".kk.....kk."],
                                      palette: ["k": WorldSprite.ink])

    /// Where a home's or hotel's sprite stands: its bottom right just left of the spot, so Sprout standing
    /// on the spot stands at its door.
    static func baseOffset(scale: CGFloat) -> CGSize {
        CGSize(width: -(13 * scale) / 2 - 16, height: -(12 * scale) / 2)
    }
}

/// A home's house or the hotel on the map (`ref-home-arrive`, `ref-hotel`): its pixel building, the house's
/// windows glowing at night (`ref-home-night`). Decoration with a name: VoiceOver "Sprout's house, at
/// Home" or "The Ace, your hotel" (the companion's own name in place of Sprout).
struct WorldHomeMarkerView: View {
    let place: HomePlace
    let isNight: Bool
    /// The companion's name.
    let companion: String

    var body: some View {
        WorldSpriteView(sprite: place.kind == .home ? WorldPlaceSprites.house : WorldPlaceSprites.hotel, scale: 4)
            .background(alignment: .center) {
                if isNight && place.kind == .home {
                    // The windows' glow: a warm light behind the house, under the night's tint.
                    Ellipse().fill(Color(red: 0.95, green: 0.84, blue: 0.54).opacity(0.45)).blur(radius: 10)
                        .frame(width: 62, height: 40).offset(y: 6)
                }
            }
            .shadow(color: WorldPalette.ink.opacity(0.3), radius: 0, x: 0, y: 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: WorldHomeMapCopy.spoken(place, companion: companion)))
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier(place.kind == .home ? "world.home.house" : "world.home.hotel")
    }
}

/// Sprout's suitcase while a hotel stay goes on (`ref-hotel`), beside it. VoiceOver "Sprout's suitcase".
struct WorldSuitcaseView: View {
    /// The companion's name.
    let companion: String

    var body: some View {
        WorldSpriteView(sprite: WorldPlaceSprites.suitcase, scale: 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: WorldHomeMapCopy.suitcase(companion: companion)))
            .accessibilityIdentifier("world.home.suitcase")
    }
}

/// Sprout asleep by its house at bedtime (`ref-home-night`): three z's rising; still with Reduce Motion.
/// VoiceOver: "Sprout, asleep by its house."
struct WorldSleepZees: View {
    /// The companion's name.
    let companion: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rising = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            WorldSpriteView(sprite: WorldPlaceSprites.zee, scale: 2).offset(x: 0, y: 22)
            WorldSpriteView(sprite: WorldPlaceSprites.zee, scale: 3).offset(x: 14, y: 8)
            WorldSpriteView(sprite: WorldPlaceSprites.zee, scale: 3).offset(x: 32, y: -10)
        }
        .frame(width: 60, height: 50, alignment: .topLeading)
        .offset(y: rising && !reduceMotion ? -4 : 0)
        .opacity(rising && !reduceMotion ? 0.7 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: rising)
        .onAppear { rising = true }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: WorldHomeMapCopy.asleep(companion: companion)))
    }
}

/// The map's words for homes and hotels (`ref-home-arrive`, `ref-hotel`, `ref-home-night`). "Sprout" in the
/// approved copy is the companion's name: the person's own when they chose one.
nonisolated enum WorldHomeMapCopy {
    /// "Sprout's suitcase".
    static func suitcase(companion: String) -> String {
        String(localized: "worldHome.suitcase", defaultValue: "\(companion)'s suitcase",
               comment: "World Home, VoiceOver: the little suitcase beside the companion during a hotel stay; the companion's name, e.g. 'Sprout's suitcase'")
    }

    /// "Sprout, asleep by its house."
    static func asleep(companion: String) -> String {
        String(localized: "worldHome.asleep", defaultValue: "\(companion), asleep by its house.",
               comment: "World Home, VoiceOver: at bedtime at home the companion sleeps by its house; the companion's name")
    }

    /// What VoiceOver says for a house or the hotel: "Sprout's house, at Home" / "The Ace, your hotel".
    static func spoken(_ place: HomePlace, companion: String) -> String {
        let name = place.label.isEmpty ? WorldHomeCopy.defaultHomeName : place.label
        switch place.kind {
        case .home:
            return String(localized: "worldHome.house.spoken", defaultValue: "\(companion)'s house, at \(name)",
                          comment: "World Home, VoiceOver: the pixel house at one of the person's homes; the companion's name, then the home's name, e.g. 'Sprout's house, at Home'")
        case .hotel:
            return String(localized: "worldHome.hotel.spoken", defaultValue: "\(name), your hotel",
                          comment: "World Home, VoiceOver: the pixel hotel of the person's stay; the hotel's name")
        }
    }

    /// Sprout's greeting: back home (three lines rotate), or checking in at a hotel.
    static func greeting(_ greeting: HomeGreeting, place: HomePlace) -> String {
        switch greeting.kind {
        case .cameHome:
            switch greeting.line {
            case 1: return String(localized: "worldHome.greeting.sweet", defaultValue: "Home sweet home.",
                                  comment: "World Home: Sprout's line on getting home after an hour or more away (one of three that rotate)")
            case 2: return String(localized: "worldHome.greeting.door", defaultValue: "There's the door.",
                                  comment: "World Home: Sprout's line on getting home after an hour or more away (one of three that rotate)")
            default: return String(localized: "worldHome.greeting.home", defaultValue: "You're home! Long day?",
                                   comment: "World Home: Sprout's line on getting home after an hour or more away")
            }
        case .hotelFirst:
            return String(localized: "worldHome.greeting.hotel", defaultValue: "Ooh, a hotel! I'll unpack.",
                          comment: "World Home: Sprout's line on checking in at a hotel for the first time")
        case .hotelAgain:
            return String(localized: "worldHome.greeting.hotelAgain", defaultValue: "Welcome back to the \(place.label)!",
                          comment: "World Home: Sprout's line on checking in again at a hotel stayed at before; the hotel's name, e.g. 'Welcome back to the Ace!'")
        }
    }
}
