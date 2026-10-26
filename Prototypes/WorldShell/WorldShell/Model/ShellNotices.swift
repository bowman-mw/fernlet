import Foundation

/// What the item bar, the status bar, the photo strip and the companion can open: one framed panel.
nonisolated enum PanelKind: String, CaseIterable, Identifiable, Sendable {
    case today, food, move, log, friends, privacy, settings, wall, customize

    var id: String { rawValue }

    /// The panel's title plate.
    var title: String {
        switch self {
        case .today: "Today"
        case .food: "Food"
        case .move: "Move"
        case .log: "Quick log"
        case .friends: "Friends"
        case .privacy: "Private"
        case .settings: "Settings"
        case .wall: "Photo wall"
        case .customize: "Customize"
        }
    }

    /// The pixel icon on the title plate.
    var icon: PixelSprite {
        switch self {
        case .today, .customize: PixelSprites.heart
        case .food: PixelSprites.onigiri
        case .move: PixelSprites.shoe
        case .log: PixelSprites.basket
        case .friends, .wall: PixelSprites.face
        case .privacy: PixelSprites.diary
        case .settings: PixelSprites.gear
        }
    }
}

/// The action button a toast can carry.
nonisolated enum ToastAction: Sendable, Equatable {
    case undoWater, undoRide

    /// The button's label.
    var label: String { "Undo" }
}

/// A short note above the item bar, as today's toasts, with an optional Undo.
nonisolated struct ShellToast: Equatable, Sendable {
    let id = UUID()
    let message: String
    var action: ToastAction?
}

/// A pixel banner under the status bar: a new stamp, or a change of ride. In-app only, never a push.
nonisolated struct ShellBanner: Equatable, Sendable {
    /// Which pixel badge the banner shows.
    enum Badge: Sendable { case cookie, bike, car, star }

    let id = UUID()
    let badge: Badge
    let title: String
    let subtitle: String
}

/// One line in the companion's speech bubble on the map.
nonisolated struct ShellSpeech: Equatable, Sendable {
    let id = UUID()
    let text: String
}
