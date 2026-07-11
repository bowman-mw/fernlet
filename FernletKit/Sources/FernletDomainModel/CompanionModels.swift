// CompanionModels.swift
// Split out of Models.swift (SPM carve-up §5c). Companion appearance, workshop, and texture models.

import Foundation
import FernletFoundation

public nonisolated struct WorkshopData: Codable, Equatable {
    public var textureEntries: [TextureEntry] = []
    public var handoffEntries: [TextureEntry] = [
        TextureEntry(title: "Native handoff", body: "Core logging flows are now modeled as SwiftUI screens with local persistence.", tags: [.delight])
    ]
    public var claudeNotesEntries: [TextureEntry] = [
        TextureEntry(title: "AI behavior", body: "External web AI calls are represented with deterministic local suggestions until an iOS API layer is added.", tags: [.tension])
    ]

    nonisolated public init() {}

    public init(textureEntries: [TextureEntry], handoffEntries: [TextureEntry], claudeNotesEntries: [TextureEntry]) {
        self.textureEntries = textureEntries
        self.handoffEntries = handoffEntries
        self.claudeNotesEntries = claudeNotesEntries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        textureEntries = try c.decodeIfPresent([TextureEntry].self, forKey: .textureEntries) ?? []
        handoffEntries = try c.decodeIfPresent([TextureEntry].self, forKey: .handoffEntries) ?? [
            TextureEntry(title: "Native handoff", body: "Core logging flows are now modeled as SwiftUI screens with local persistence.", tags: [.delight])
        ]
        claudeNotesEntries = try c.decodeIfPresent([TextureEntry].self, forKey: .claudeNotesEntries) ?? [
            TextureEntry(title: "AI behavior", body: "External web AI calls are represented with deterministic local suggestions until an iOS API caller is added.", tags: [.tension])
        ]
    }
}

public nonisolated struct TextureEntry: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var title: String = FernletDate.shortDate(for: .now) + " observation"
    public var body: String
    public var tags: Set<TextureTag>
    /// Unknown `tags` tokens from a newer build, parked instead of thrown on (a throw in the
    /// blob's `workshop` bricks the store) and re-encoded so a save here can't strip them
    /// (`EnumDecodeCompat`).
    public var unknownTagTokens: [String] = []
    public var createdAt = Date()

    public init(id: UUID = UUID(), title: String = FernletDate.shortDate(for: .now) + " observation", body: String, tags: Set<TextureTag> = [], createdAt: Date = Date()) {
        self.id = id; self.title = title; self.body = body; self.tags = tags; self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? (FernletDate.shortDate(for: .now) + " observation")
        body = try c.decode(String.self, forKey: .body)
        let tagSplit = try c.decodeTolerantEnumSet(
            TextureTag.self, forKey: .tags, parkedTokensKey: .unknownTagTokens)
        tags = tagSplit.known
        unknownTagTokens = tagSplit.unknownTokens
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public nonisolated enum TextureTag: String, Codable, CaseIterable, Identifiable {
    case tension, delight, friction
    public var id: String { rawValue }
}

public nonisolated struct CompanionAppearance: Codable, Equatable {
    // Every enum field decodes tolerantly (freeze-on-unknown + parked-token side channel): these
    // are the closet/customization enums, exactly the surface a newer build extends with new
    // cosmetics, and a present-but-unknown raw value in the synced settings blob would otherwise
    // throw and brick the older device into read-only recovery. The parked token is re-encoded
    // (so a save here can't clobber the newer device's choice), re-adopted by a build that knows
    // it, and cleared on an explicit local edit via `didSet` (`EnumDecodeCompat`). The wardrobe
    // bindings write through `WritableKeyPath` subscripts, which go through the property setters,
    // so the observers fire on every user edit.
    public var bodyStyle: CompanionBodyStyle = .circle {
        didSet { unknownBodyStyleToken = nil }
    }
    public var unknownBodyStyleToken: String? = nil
    public var palette: CompanionPalette = .state {
        didSet { unknownPaletteToken = nil }
    }
    public var unknownPaletteToken: String? = nil
    public var bodyColor: CompanionAssetColor = .state {
        didSet { unknownBodyColorToken = nil }
    }
    public var unknownBodyColorToken: String? = nil
    public var bodyCustomColorHex: String?
    public var accessory: CompanionAccessory = .sprout {
        didSet { unknownAccessoryToken = nil }
    }
    public var unknownAccessoryToken: String? = nil
    public var accessoryColor: CompanionAssetColor = .fern {
        didSet { unknownAccessoryColorToken = nil }
    }
    public var unknownAccessoryColorToken: String? = nil
    public var accessoryCustomColorHex: String?
    public var clothing: CompanionClothing = .none {
        didSet { unknownClothingToken = nil }
    }
    public var unknownClothingToken: String? = nil
    public var clothingColor: CompanionAssetColor = .terracotta {
        didSet { unknownClothingColorToken = nil }
    }
    public var unknownClothingColorToken: String? = nil
    public var clothingCustomColorHex: String?
    public var sideItem: CompanionSideItem = .none {
        didSet { unknownSideItemToken = nil }
    }
    public var unknownSideItemToken: String? = nil
    public var sideItemColor: CompanionAssetColor = .bark {
        didSet { unknownSideItemColorToken = nil }
    }
    public var unknownSideItemColorToken: String? = nil
    public var sideItemCustomColorHex: String?

    // Immutable default appearance. `nonisolated(unsafe)` (rather than making the whole
    // CompanionAppearance/enum tree Sendable) because the value is a constant and never mutated.
    nonisolated(unsafe) public static let standard = CompanionAppearance()

    public init(
        bodyStyle: CompanionBodyStyle = .circle,
        palette: CompanionPalette = .state,
        bodyColor: CompanionAssetColor = .state,
        bodyCustomColorHex: String? = nil,
        accessory: CompanionAccessory = .sprout,
        accessoryColor: CompanionAssetColor = .fern,
        accessoryCustomColorHex: String? = nil,
        clothing: CompanionClothing = .none,
        clothingColor: CompanionAssetColor = .terracotta,
        clothingCustomColorHex: String? = nil,
        sideItem: CompanionSideItem = .none,
        sideItemColor: CompanionAssetColor = .bark,
        sideItemCustomColorHex: String? = nil
    ) {
        self.bodyStyle = bodyStyle
        self.palette = palette
        self.bodyColor = bodyColor
        self.bodyCustomColorHex = bodyCustomColorHex
        self.accessory = accessory
        self.accessoryColor = accessoryColor
        self.accessoryCustomColorHex = accessoryCustomColorHex
        self.clothing = clothing
        self.clothingColor = clothingColor
        self.clothingCustomColorHex = clothingCustomColorHex
        self.sideItem = sideItem
        self.sideItemColor = sideItemColor
        self.sideItemCustomColorHex = sideItemCustomColorHex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bodyStyleSplit = try container.decodeTolerantEnum(
            CompanionBodyStyle.self, forKey: .bodyStyle, parkedTokenKey: .unknownBodyStyleToken, default: .circle)
        bodyStyle = bodyStyleSplit.value
        unknownBodyStyleToken = bodyStyleSplit.parkedToken
        let paletteSplit = try container.decodeTolerantEnum(
            CompanionPalette.self, forKey: .palette, parkedTokenKey: .unknownPaletteToken, default: .state)
        palette = paletteSplit.value
        unknownPaletteToken = paletteSplit.parkedToken
        let bodyColorSplit = try container.decodeTolerantEnum(
            CompanionAssetColor.self, forKey: .bodyColor, parkedTokenKey: .unknownBodyColorToken,
            default: CompanionAssetColor(palette: palette))
        bodyColor = bodyColorSplit.value
        unknownBodyColorToken = bodyColorSplit.parkedToken
        bodyCustomColorHex = try container.decodeIfPresent(String.self, forKey: .bodyCustomColorHex)
        let accessorySplit = try container.decodeTolerantEnum(
            CompanionAccessory.self, forKey: .accessory, parkedTokenKey: .unknownAccessoryToken, default: .sprout)
        accessory = accessorySplit.value
        unknownAccessoryToken = accessorySplit.parkedToken
        let accessoryColorSplit = try container.decodeTolerantEnum(
            CompanionAssetColor.self, forKey: .accessoryColor, parkedTokenKey: .unknownAccessoryColorToken, default: .fern)
        accessoryColor = accessoryColorSplit.value
        unknownAccessoryColorToken = accessoryColorSplit.parkedToken
        accessoryCustomColorHex = try container.decodeIfPresent(String.self, forKey: .accessoryCustomColorHex)
        let clothingSplit = try container.decodeTolerantEnum(
            CompanionClothing.self, forKey: .clothing, parkedTokenKey: .unknownClothingToken, default: .none)
        clothing = clothingSplit.value
        unknownClothingToken = clothingSplit.parkedToken
        let clothingColorSplit = try container.decodeTolerantEnum(
            CompanionAssetColor.self, forKey: .clothingColor, parkedTokenKey: .unknownClothingColorToken, default: .terracotta)
        clothingColor = clothingColorSplit.value
        unknownClothingColorToken = clothingColorSplit.parkedToken
        clothingCustomColorHex = try container.decodeIfPresent(String.self, forKey: .clothingCustomColorHex)
        let sideItemSplit = try container.decodeTolerantEnum(
            CompanionSideItem.self, forKey: .sideItem, parkedTokenKey: .unknownSideItemToken, default: .none)
        sideItem = sideItemSplit.value
        unknownSideItemToken = sideItemSplit.parkedToken
        let sideItemColorSplit = try container.decodeTolerantEnum(
            CompanionAssetColor.self, forKey: .sideItemColor, parkedTokenKey: .unknownSideItemColorToken, default: .bark)
        sideItemColor = sideItemColorSplit.value
        unknownSideItemColorToken = sideItemColorSplit.parkedToken
        sideItemCustomColorHex = try container.decodeIfPresent(String.self, forKey: .sideItemCustomColorHex)
    }
}

public nonisolated enum CompanionBodyStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case circle
    case softBlob
    case pear
    case puddle

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .circle: "Circle"
        case .softBlob: "Soft"
        case .pear: "Pear"
        case .puddle: "Puddle"
        }
    }
}

public nonisolated enum CompanionPalette: String, Codable, CaseIterable, Identifiable {
    case state
    case fern
    case rose
    case sun
    case slate

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .state: "Mood"
        case .fern: "Fern"
        case .rose: "Rose"
        case .sun: "Sun"
        case .slate: "Slate"
        }
    }
}

public nonisolated enum CompanionAssetColor: String, Codable, CaseIterable, Identifiable {
    case state
    case moss
    case fern
    case rose
    case sun
    case slate
    case terracotta
    case cream
    case bark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .state: "Mood"
        case .moss: "Moss"
        case .fern: "Fern"
        case .rose: "Rose"
        case .sun: "Sun"
        case .slate: "Slate"
        case .terracotta: "Clay"
        case .cream: "Cream"
        case .bark: "Bark"
        }
    }

    public init(palette: CompanionPalette) {
        switch palette {
        case .state: self = .state
        case .fern: self = .fern
        case .rose: self = .rose
        case .sun: self = .sun
        case .slate: self = .slate
        }
    }
}

public nonisolated enum CompanionAccessory: String, Codable, CaseIterable, Identifiable {
    case none
    case sprout
    case flower
    case glasses

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: "None"
        case .sprout: "Sprout"
        case .flower: "Flower"
        case .glasses: "Glasses"
        }
    }
}

public nonisolated enum CompanionClothing: String, Codable, CaseIterable, Identifiable {
    case none
    case scarf
    case sleepCap

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: "None"
        case .scarf: "Scarf"
        case .sleepCap: "Sleep cap"
        }
    }
}

public nonisolated enum CompanionSideItem: String, Codable, CaseIterable, Identifiable {
    case none
    case mug
    case book
    case dumbbell
    case waterBottle

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: "None"
        case .mug: "Mug"
        case .book: "Book"
        case .dumbbell: "Weight"
        case .waterBottle: "Bottle"
        }
    }

    public var systemImage: String {
        switch self {
        case .none: "circle.slash"
        case .mug: "mug"
        case .book: "book.closed"
        case .dumbbell: "dumbbell"
        case .waterBottle: "waterbottle"
        }
    }
}

public nonisolated enum CompanionState: String, Codable, Sendable {
    case thriving = "Thriving"
    case okay = "Okay"
    case tired = "Tired"
    case resting = "Resting"
    case sick = "Sick"
}
