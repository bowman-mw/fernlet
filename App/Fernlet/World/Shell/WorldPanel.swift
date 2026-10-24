import Foundation

/// One full-screen panel of the World Home (design `b1-frame-root`, draft 3; World app plan step 1b).
///
/// Four of them are today's tabs, drawn inside the panel frame (`friends` is the Album since `b4-mem-name`;
/// its raw value and tab stay `friends` / `.social`): opening one selects its `FernletTab`, so
/// every gate that keys off the tab (the Private lock, Private data activation, the radio run policy,
/// the disposable camera) works exactly as before. The other three are not tabs: Today (today's Home,
/// until the Today panel of step 4), Log (Home's Quick log and mood card) and Settings. They open over
/// everything and leave the tab on Home.
///
/// The raw value is a frozen token (accessibility identifiers, UI tests); display text is ``title`` and
/// ``barName``.
nonisolated enum WorldPanel: String, CaseIterable, Identifiable, Sendable {
    case today, food, move, log, friends, personal, settings

    var id: String { rawValue }

    /// The item bar's slots, left to right (Log in the middle, raised).
    static let itemBar: [WorldPanel] = [.food, .move, .log, .friends, .personal, .settings]

    /// The tab this panel shows, or nil for a panel that opens over the map without leaving Home.
    var tab: FernletTab? {
        switch self {
        case .food: .food
        case .move: .move
        case .friends: .social
        case .personal: .personal
        case .today, .log, .settings: nil
        }
    }

    /// The panel for a selected tab, or nil for Home (the map).
    static func panel(for tab: FernletTab) -> WorldPanel? {
        allCases.first { $0.tab == tab }
    }

    /// The panel's title on its wooden plate.
    var title: String {
        switch self {
        case .today: String(localized: "worldPanel.today", defaultValue: "Today",
                            comment: "World Home: the title plate of the Today panel (Home's cards)")
        case .settings: String(localized: "worldPanel.settings", defaultValue: "Settings",
                               comment: "World Home: the title plate of the Settings panel")
        default: barName
        }
    }

    /// The panel's short name under its item-bar icon (kept short: a sixth of the bar's width).
    var barName: String {
        switch self {
        case .food: String(localized: "itemBar.food", defaultValue: "Food", comment: "World Home item bar: meals, recipes and nutrition")
        case .move: String(localized: "itemBar.move", defaultValue: "Move", comment: "World Home item bar: workouts and movement")
        case .log: String(localized: "itemBar.log", defaultValue: "Log", comment: "World Home item bar: the raised middle button, Quick log")
        case .friends: String(localized: "itemBar.album", defaultValue: "Album",
                              comment: "World Home item bar and the panel's title: the photo album, shared hangout photos and your own (Spanish: Álbum). Keep it short; it shares the bar with five others")
        case .personal: String(localized: "itemBar.private", defaultValue: "Private", comment: "World Home item bar: the locked area — journal, cycle, intimacy, worry box")
        case .settings: String(localized: "itemBar.settings", defaultValue: "Settings", comment: "World Home item bar: Settings. Keep it short; it shares the bar with five others (Spanish: Ajustes)")
        case .today: String(localized: "itemBar.today", defaultValue: "Today", comment: "World Home: Today, opened from the status plate")
        }
    }

    /// What Voice Control answers to for the item-bar slot: its name, and for the Album its old name
    /// "Friends" too, so the habit of saying "Tap Friends" keeps working (`b4-mem-name`).
    var inputNames: [String] {
        guard self == .friends else { return [barName] }
        return [barName, String(localized: "itemBar.album.formerName", defaultValue: "Friends",
                                comment: "World Home item bar, Voice Control only: the Album's former name, still answered to (Spanish: Amigos)")]
    }

    /// The accessibility identifier of the panel's item-bar slot (UI tests), a frozen token.
    var itemIdentifier: String { "world.item.\(rawValue)" }
}
