// CompanionLookModels.swift
// The companion's hair, eyes, pattern and background (roadmap G8, the owner's picks on the
// "Sprout's New Looks" review page, 2026-11-15). Like the closet enums in CompanionModels.swift, each
// raw value is a FROZEN token the synced appearance and the friend wire carry, and
// ``CompanionAppearance`` decodes each tolerantly, so a style a newer build adds never bricks an older
// device. The pixels live with the app's painter (`WorldCompanionPainter`); this module holds tokens
// and names only.

import Foundation

/// The companion's hair: a few pixels on the top of the head, under the sleep cap or a drawn hat.
public nonisolated enum CompanionHairStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case tuft
    case fringe
    case spiky
    case bun
    case curly
    case long
    case swoop

    public var id: String { rawValue }

    /// The style's name in Customize. `rawValue` is the frozen token.
    public var label: String {
        switch self {
        case .none: String(localized: "companionHair.none", defaultValue: "None", bundle: .module,
                           comment: "Customize › Hair: no hair on the companion")
        case .tuft: String(localized: "companionHair.tuft", defaultValue: "Tuft", bundle: .module,
                           comment: "Customize › Hair: a small curl of hair on top of the head")
        case .fringe: String(localized: "companionHair.fringe", defaultValue: "Fringe", bundle: .module,
                             comment: "Customize › Hair: hair cut straight across the forehead (bangs)")
        case .spiky: String(localized: "companionHair.spiky", defaultValue: "Spiky", bundle: .module,
                            comment: "Customize › Hair: short hair standing up in spikes")
        case .bun: String(localized: "companionHair.bun", defaultValue: "Bun", bundle: .module,
                          comment: "Customize › Hair: hair tied up in a bun on top")
        case .curly: String(localized: "companionHair.curly", defaultValue: "Curly", bundle: .module,
                            comment: "Customize › Hair: curly hair")
        case .long: String(localized: "companionHair.long", defaultValue: "Long", bundle: .module,
                           comment: "Customize › Hair: long hair falling down the sides")
        case .swoop: String(localized: "companionHair.swoop", defaultValue: "Swoop", bundle: .module,
                            comment: "Customize › Hair: hair swept over to one side")
        }
    }
}

/// The companion's eyes. Every style keeps the moods readable: heavy lids when tired, closed when
/// resting, sick or asleep.
public nonisolated enum CompanionEyes: String, Codable, CaseIterable, Identifiable, Sendable {
    case round
    case dot
    case big
    case button
    case lashes
    case wide

    public var id: String { rawValue }

    /// Whether the eyes are large enough to show a colour, and the glasses' lenses grow to fit them.
    public var isLarge: Bool { self == .big || self == .button }

    /// The style's name in Customize. `rawValue` is the frozen token.
    public var label: String {
        switch self {
        case .round: String(localized: "companionEyes.round", defaultValue: "Round", bundle: .module,
                            comment: "Customize › Eyes: small round eyes, the companion's original eyes")
        case .dot: String(localized: "companionEyes.dot", defaultValue: "Dot", bundle: .module,
                          comment: "Customize › Eyes: tiny single-dot eyes")
        case .big: String(localized: "companionEyes.big", defaultValue: "Big and shiny", bundle: .module,
                          comment: "Customize › Eyes: large eyes with a white shine")
        case .button: String(localized: "companionEyes.button", defaultValue: "Button", bundle: .module,
                             comment: "Customize › Eyes: large solid eyes like buttons")
        case .lashes: String(localized: "companionEyes.lashes", defaultValue: "Lashes", bundle: .module,
                             comment: "Customize › Eyes: round eyes with eyelashes")
        case .wide: String(localized: "companionEyes.wide", defaultValue: "Wide-set", bundle: .module,
                           comment: "Customize › Eyes: round eyes set further apart")
        }
    }
}

/// A pattern on the companion's body, drawn in a lighter or darker shade of the body's own colour
/// (moss is always green). It never covers the face or the outline.
public nonisolated enum CompanionPattern: String, Codable, CaseIterable, Identifiable, Sendable {
    case plain
    case freckles
    case belly
    case stripes
    case moss

    public var id: String { rawValue }

    /// The pattern's name in Customize. `rawValue` is the frozen token.
    public var label: String {
        switch self {
        case .plain: String(localized: "companionPattern.plain", defaultValue: "Plain", bundle: .module,
                            comment: "Customize › Pattern: no pattern on the companion's body")
        case .freckles: String(localized: "companionPattern.freckles", defaultValue: "Freckles", bundle: .module,
                               comment: "Customize › Pattern: a few freckles on the cheeks")
        case .belly: String(localized: "companionPattern.belly", defaultValue: "Belly patch", bundle: .module,
                            comment: "Customize › Pattern: a lighter patch on the companion's tummy")
        case .stripes: String(localized: "companionPattern.stripes", defaultValue: "Stripes", bundle: .module,
                              comment: "Customize › Pattern: darker stripes on the head and sides")
        case .moss: String(localized: "companionPattern.moss", defaultValue: "Moss", bundle: .module,
                            comment: "Customize › Pattern: green moss growing on top of the head")
        }
    }
}

/// The small pixel scene behind the companion wherever it stands away from the map: Customize's
/// previews, the passport's first page and the Home Screen widgets. On the map, the map is the
/// background. Kept on this phone's synced settings and never sent to friends
/// (``CompanionAppearance/forFriends``).
public nonisolated enum CompanionBackground: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case meadow
    case forest
    case beach
    case night
    case snow
    case room
    case rain

    public var id: String { rawValue }

    /// The scene's name in Customize. `rawValue` is the frozen token.
    public var label: String {
        switch self {
        case .none: String(localized: "companionBackground.none", defaultValue: "Plain", bundle: .module,
                           comment: "Customize › Background: no scene, the plain box")
        case .meadow: String(localized: "companionBackground.meadow", defaultValue: "Meadow", bundle: .module,
                             comment: "Customize › Background: a sunny meadow scene")
        case .forest: String(localized: "companionBackground.forest", defaultValue: "Forest", bundle: .module,
                             comment: "Customize › Background: a forest scene")
        case .beach: String(localized: "companionBackground.beach", defaultValue: "Beach", bundle: .module,
                            comment: "Customize › Background: a beach scene with the sea")
        case .night: String(localized: "companionBackground.night", defaultValue: "Night sky", bundle: .module,
                            comment: "Customize › Background: a starry night sky with the moon")
        case .snow: String(localized: "companionBackground.snow", defaultValue: "Snow", bundle: .module,
                           comment: "Customize › Background: a snowy scene")
        case .room: String(localized: "companionBackground.room", defaultValue: "Cosy room", bundle: .module,
                           comment: "Customize › Background: a cosy room with a window and a rug")
        case .rain: String(localized: "companionBackground.rain", defaultValue: "Rainy day", bundle: .module,
                           comment: "Customize › Background: a rainy day scene")
        }
    }
}
