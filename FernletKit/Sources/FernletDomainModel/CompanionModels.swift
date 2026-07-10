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
    public var createdAt = Date()

    public init(id: UUID = UUID(), title: String = FernletDate.shortDate(for: .now) + " observation", body: String, tags: Set<TextureTag> = [], createdAt: Date = Date()) {
        self.id = id; self.title = title; self.body = body; self.tags = tags; self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? (FernletDate.shortDate(for: .now) + " observation")
        body = try c.decode(String.self, forKey: .body)
        tags = try c.decodeIfPresent(Set<TextureTag>.self, forKey: .tags) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public nonisolated enum TextureTag: String, Codable, CaseIterable, Identifiable {
    case tension, delight, friction
    public var id: String { rawValue }
}

public nonisolated struct CompanionAppearance: Codable, Equatable {
    public var bodyStyle: CompanionBodyStyle = .circle
    public var palette: CompanionPalette = .state
    public var bodyColor: CompanionAssetColor = .state
    public var bodyCustomColorHex: String?
    public var accessory: CompanionAccessory = .sprout
    public var accessoryColor: CompanionAssetColor = .fern
    public var accessoryCustomColorHex: String?
    public var clothing: CompanionClothing = .none
    public var clothingColor: CompanionAssetColor = .terracotta
    public var clothingCustomColorHex: String?
    public var sideItem: CompanionSideItem = .none
    public var sideItemColor: CompanionAssetColor = .bark
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
        bodyStyle = try container.decodeIfPresent(CompanionBodyStyle.self, forKey: .bodyStyle) ?? .circle
        palette = try container.decodeIfPresent(CompanionPalette.self, forKey: .palette) ?? .state
        bodyColor = try container.decodeIfPresent(CompanionAssetColor.self, forKey: .bodyColor) ?? CompanionAssetColor(palette: palette)
        bodyCustomColorHex = try container.decodeIfPresent(String.self, forKey: .bodyCustomColorHex)
        accessory = try container.decodeIfPresent(CompanionAccessory.self, forKey: .accessory) ?? .sprout
        accessoryColor = try container.decodeIfPresent(CompanionAssetColor.self, forKey: .accessoryColor) ?? .fern
        accessoryCustomColorHex = try container.decodeIfPresent(String.self, forKey: .accessoryCustomColorHex)
        clothing = try container.decodeIfPresent(CompanionClothing.self, forKey: .clothing) ?? .none
        clothingColor = try container.decodeIfPresent(CompanionAssetColor.self, forKey: .clothingColor) ?? .terracotta
        clothingCustomColorHex = try container.decodeIfPresent(String.self, forKey: .clothingCustomColorHex)
        sideItem = try container.decodeIfPresent(CompanionSideItem.self, forKey: .sideItem) ?? .none
        sideItemColor = try container.decodeIfPresent(CompanionAssetColor.self, forKey: .sideItemColor) ?? .bark
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
