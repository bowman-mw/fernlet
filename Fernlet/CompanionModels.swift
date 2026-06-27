// CompanionModels.swift
// Split out of Models.swift (SPM carve-up §5c). Companion appearance, workshop, and texture models.

import Foundation
import FernletFoundation

struct WorkshopData: Codable, Equatable {
    var textureEntries: [TextureEntry] = []
    var handoffEntries: [TextureEntry] = [
        TextureEntry(title: "Native handoff", body: "Core logging flows are now modeled as SwiftUI screens with local persistence.", tags: [.delight])
    ]
    var claudeNotesEntries: [TextureEntry] = [
        TextureEntry(title: "AI behavior", body: "External web AI calls are represented with deterministic local suggestions until an iOS API layer is added.", tags: [.tension])
    ]

    nonisolated init() {}

    init(textureEntries: [TextureEntry], handoffEntries: [TextureEntry], claudeNotesEntries: [TextureEntry]) {
        self.textureEntries = textureEntries
        self.handoffEntries = handoffEntries
        self.claudeNotesEntries = claudeNotesEntries
    }

    init(from decoder: Decoder) throws {
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

struct TextureEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = FernletDate.shortDate(for: .now) + " observation"
    var body: String
    var tags: Set<TextureTag>
    var createdAt = Date()

    init(id: UUID = UUID(), title: String = FernletDate.shortDate(for: .now) + " observation", body: String, tags: Set<TextureTag> = [], createdAt: Date = Date()) {
        self.id = id; self.title = title; self.body = body; self.tags = tags; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? (FernletDate.shortDate(for: .now) + " observation")
        body = try c.decode(String.self, forKey: .body)
        tags = try c.decodeIfPresent(Set<TextureTag>.self, forKey: .tags) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

enum TextureTag: String, Codable, CaseIterable, Identifiable {
    case tension, delight, friction
    var id: String { rawValue }
}

struct CompanionAppearance: Codable, Equatable {
    var bodyStyle: CompanionBodyStyle = .circle
    var palette: CompanionPalette = .state
    var bodyColor: CompanionAssetColor = .state
    var bodyCustomColorHex: String?
    var accessory: CompanionAccessory = .sprout
    var accessoryColor: CompanionAssetColor = .fern
    var accessoryCustomColorHex: String?
    var clothing: CompanionClothing = .none
    var clothingColor: CompanionAssetColor = .terracotta
    var clothingCustomColorHex: String?
    var sideItem: CompanionSideItem = .none
    var sideItemColor: CompanionAssetColor = .bark
    var sideItemCustomColorHex: String?

    static let standard = CompanionAppearance()

    init(
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

    init(from decoder: Decoder) throws {
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

enum CompanionBodyStyle: String, Codable, CaseIterable, Identifiable {
    case circle
    case softBlob
    case pear
    case puddle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .circle: "Circle"
        case .softBlob: "Soft"
        case .pear: "Pear"
        case .puddle: "Puddle"
        }
    }
}

enum CompanionPalette: String, Codable, CaseIterable, Identifiable {
    case state
    case fern
    case rose
    case sun
    case slate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .state: "Mood"
        case .fern: "Fern"
        case .rose: "Rose"
        case .sun: "Sun"
        case .slate: "Slate"
        }
    }
}

enum CompanionAssetColor: String, Codable, CaseIterable, Identifiable {
    case state
    case moss
    case fern
    case rose
    case sun
    case slate
    case terracotta
    case cream
    case bark

    var id: String { rawValue }

    var label: String {
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

    init(palette: CompanionPalette) {
        switch palette {
        case .state: self = .state
        case .fern: self = .fern
        case .rose: self = .rose
        case .sun: self = .sun
        case .slate: self = .slate
        }
    }
}

enum CompanionAccessory: String, Codable, CaseIterable, Identifiable {
    case none
    case sprout
    case flower
    case glasses

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .sprout: "Sprout"
        case .flower: "Flower"
        case .glasses: "Glasses"
        }
    }
}

enum CompanionClothing: String, Codable, CaseIterable, Identifiable {
    case none
    case scarf
    case sleepCap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .scarf: "Scarf"
        case .sleepCap: "Sleep cap"
        }
    }
}

enum CompanionSideItem: String, Codable, CaseIterable, Identifiable {
    case none
    case mug
    case book
    case dumbbell
    case waterBottle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .mug: "Mug"
        case .book: "Book"
        case .dumbbell: "Weight"
        case .waterBottle: "Bottle"
        }
    }

    var systemImage: String {
        switch self {
        case .none: "circle.slash"
        case .mug: "mug"
        case .book: "book.closed"
        case .dumbbell: "dumbbell"
        case .waterBottle: "waterbottle"
        }
    }
}

enum CompanionState: String, Codable {
    case thriving = "Thriving"
    case okay = "Okay"
    case tired = "Tired"
    case resting = "Resting"
    case sick = "Sick"
}
