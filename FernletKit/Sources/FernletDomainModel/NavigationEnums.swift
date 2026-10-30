// NavigationEnums.swift
// Split out of Models.swift (SPM carve-up §5c). Screen / widget / shortcut navigation enums (app target).

import Foundation

/// How much the proximity Connection Inspector records and shows (disabled, passive, live).
///
/// A synced setting on ``FernletSettings``, decoded tolerantly there so a mode added by a newer
/// build parks instead of bricking the blob.
public nonisolated enum ConnectionInspectorMode: String, Codable, CaseIterable, Identifiable {
    case disabled
    case passive
    case live

    public var id: String { rawValue }

    /// The Settings picker's name for the mode. Display only: the setting persists `rawValue`.
    public var title: String {
        switch self {
        case .disabled:
            String(localized: "connectionInspector.mode.disabled", defaultValue: "Disabled", bundle: .module,
                   comment: "Settings, Connection Inspector mode picker: records nothing")
        case .passive:
            String(localized: "connectionInspector.mode.passive", defaultValue: "Passive", bundle: .module,
                   comment: "Settings, Connection Inspector mode picker: records quietly in the background")
        case .live:
            String(localized: "connectionInspector.mode.live", defaultValue: "Live", bundle: .module,
                   comment: "Settings, Connection Inspector mode picker: shows connections as they happen")
        }
    }
}

/// The navigable feature screens a shortcut or home widget can deep-link to.
///
/// Carries the symbol each launcher surface draws; the sensitive screens are filtered through
/// ``SensitiveSurfaceVisibility`` before display. Its `title` and `subtitle` were deleted in the
/// Spanish round (2026-10-20) rather than localized: nothing read them.
public nonisolated enum FernletScreen: String, Codable, CaseIterable, Identifiable {
    case food
    case move
    case journal
    case periodTracking
    case intimacyTracking
    case friends
    case photos

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .food: "fork.knife"
        case .move: "figure.walk"
        case .journal: "book.closed.fill"
        case .periodTracking: "calendar.badge.clock"
        case .intimacyTracking: "lock.shield.fill"
        case .friends: "person.2.fill"
        case .photos: "photo.on.rectangle.fill"
        }
    }
}

/// The configurable home-feed widgets, in user-chosen order.
///
/// Persisted as raw tokens in ``FernletSettings``' `homeWidgets` with a parked side channel for
/// tokens only newer builds know; `normalized` de-dupes and falls back to `defaultWidgets` when the
/// list decodes empty.
public nonisolated enum HomeWidget: String, Codable, CaseIterable, Identifiable, Sendable {
    case companion
    case todaySummary
    case todayIntent
    case quickLog
    case logFood
    case recipeBook
    case newRecipe
    case workout
    case journal
    case sleep
    case water
    case hygiene
    case macros
    case trends
    case ambient
    case milestones
    case firstAid
    case mealPhotos
    /// The silly stats card (cookies per day, the Moonwalk, …), which opens the stats page.
    case sillyStats

    nonisolated public static let defaultWidgets: [HomeWidget] = [.companion, .todaySummary, .todayIntent, .ambient, .quickLog, .macros, .trends, .firstAid, .milestones, .mealPhotos, .sillyStats]

    public var id: String { rawValue }

    /// The widget's display name. Display only: layouts persist `rawValue`.
    public var title: String {
        switch self {
        case .companion:
            String(localized: "homeWidget.companion", defaultValue: "Companion", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: the companion creature and its speech bubble")
        case .todaySummary:
            String(localized: "homeWidget.todaySummary", defaultValue: "Today", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: today's summary card")
        case .todayIntent:
            String(localized: "homeWidget.todayIntent", defaultValue: "Today's intent", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: the card holding the user's intention for today")
        case .quickLog:
            String(localized: "homeWidget.quickLog", defaultValue: "Quick log", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: the grid of quick-log tiles")
        case .logFood:
            String(localized: "homeWidget.logFood", defaultValue: "Log food", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: a button that opens food logging")
        case .recipeBook:
            String(localized: "homeWidget.recipeBook", defaultValue: "Recipe book", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: a button that opens the saved recipes")
        case .newRecipe:
            String(localized: "homeWidget.newRecipe", defaultValue: "New recipe", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: a button that starts a new recipe")
        case .workout:
            String(localized: "homeWidget.workout", defaultValue: "Workout", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: a button that logs a workout")
        case .journal:
            String(localized: "homeWidget.journal", defaultValue: "Journal", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: a button that opens the journal")
        case .sleep:
            String(localized: "homeWidget.sleep", defaultValue: "Sleep", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: a button that logs sleep")
        case .water:
            String(localized: "homeWidget.water", defaultValue: "Water", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: a button that logs water")
        // "Personal care", matching the card this widget draws and the sheet that card opens. The
        // same set of tasks used to be called Care (tile), Personal care (sheet) and Hygiene (here),
        // so the widget-order list named a feature nothing else in the app called by that name.
        case .hygiene:
            String(localized: "homeWidget.hygiene", defaultValue: "Personal care", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: the personal care checklist card")
        case .macros:
            String(localized: "homeWidget.macros", defaultValue: "Macros", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: the protein, carbs and fat card")
        case .trends:
            String(localized: "homeWidget.trends", defaultValue: "Trends", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: the weekly trends card")
        case .ambient:
            String(localized: "homeWidget.ambient", defaultValue: "Moments", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: small seasonal and time-of-day moments")
        case .milestones:
            String(localized: "homeWidget.milestones", defaultValue: "Milestones", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: gentle milestones reached")
        case .firstAid:
            String(localized: "homeWidget.firstAid", defaultValue: "First aid", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: the card that opens calming tools and crisis support")
        case .mealPhotos:
            String(localized: "homeWidget.mealPhotos", defaultValue: "Recent bites", bundle: .module,
                   comment: "Home widget name, in the Home layout list and on the card: photos of recent meals")
        case .sillyStats:
            String(localized: "homeWidget.sillyStats", defaultValue: "Silly stats", bundle: .module,
                   comment: "Home widget name: the card of deliberately useless lifetime stats")
        }
    }

    public var systemImage: String {
        switch self {
        case .companion: "leaf.fill"
        case .todaySummary: "calendar"
        case .todayIntent: "sun.max"
        case .quickLog: "square.grid.2x2"
        case .logFood: "fork.knife"
        case .recipeBook: "book.closed"
        case .newRecipe: "plus.square.on.square"
        case .workout: "figure.strengthtraining.traditional"
        case .journal: "book.closed"
        case .sleep: "moon"
        case .water: "drop"
        case .hygiene: "checklist"
        case .macros: "chart.pie"
        case .trends: "chart.line.uptrend.xyaxis"
        case .ambient: "sparkles"
        case .milestones: "seal"
        case .firstAid: "heart.circle"
        case .mealPhotos: "photo.stack"
        case .sillyStats: "face.smiling"
        }
    }

    public var isAction: Bool {
        switch self {
        case .logFood, .recipeBook, .newRecipe, .workout, .journal, .sleep, .water, .hygiene, .trends:
            true
        case .companion, .todaySummary, .todayIntent, .quickLog, .macros, .ambient, .milestones, .firstAid, .mealPhotos, .sillyStats:
            false
        }
    }

    public static func normalized(_ widgets: [HomeWidget]) -> [HomeWidget] {
        var result: [HomeWidget] = []
        for widget in widgets where !result.contains(widget) {
            result.append(widget)
        }
        if result.isEmpty { return defaultWidgets }
        return result
    }
}

/// The quick-log tiles on Home (at most six shown).
///
/// Persisted as raw tokens in ``FernletSettings``' `quickLogItems` with parked-token forward
/// compat. Rendering filters through ``SensitiveSurfaceVisibility`` DISPLAY-ONLY — the stored
/// array keeps every choice so un-hiding a surface restores the user's layout (see
/// `visibleQuickLog`).
public nonisolated enum FernletShortcut: String, Codable, CaseIterable, Identifiable, Sendable {
    case meal
    case water
    case move
    case sleep
    case journal
    case care
    case logPeriod
    case periodTracking
    case intimacyTracking
    case friends
    case breathing
    case grounding
    case worryBox
    /// The Bodybuilding goal's bathroom count (World round 7, `bb-bowel`). Shown only while that goal
    /// is chosen (``visibleQuickLog(_:visibility:bathroomAvailable:)``), never a default or a filler
    /// tile; an older build parks the token in `unknownQuickLogTokens` and writes it back.
    case bathroom

    nonisolated public static let defaultQuickLog: [FernletShortcut] = [.meal, .water, .move, .sleep, .journal, .care]

    public var id: String { rawValue }

    /// The tile's display name. Display only: quick-log layouts persist `rawValue`.
    public var title: String {
        switch self {
        case .meal:
            String(localized: "quickLog.meal", defaultValue: "Meal", bundle: .module,
                   comment: "Home quick-log tile and its editor: log a meal")
        case .water:
            String(localized: "quickLog.water", defaultValue: "Water", bundle: .module,
                   comment: "Home quick-log tile and its editor: log water")
        case .move:
            String(localized: "quickLog.move", defaultValue: "Move", bundle: .module,
                   comment: "Home quick-log tile and its editor: log movement")
        case .sleep:
            String(localized: "quickLog.sleep", defaultValue: "Sleep", bundle: .module,
                   comment: "Home quick-log tile and its editor: log sleep")
        case .journal:
            String(localized: "quickLog.journal", defaultValue: "Journal", bundle: .module,
                   comment: "Home quick-log tile and its editor: open the journal")
        case .care:
            String(localized: "quickLog.care", defaultValue: "Care", bundle: .module,
                   comment: "Home quick-log tile and its editor: the personal care checklist")
        case .logPeriod:
            String(localized: "quickLog.logPeriod", defaultValue: "Log period", bundle: .module,
                   comment: "Home quick-log tile and its editor: log a period day")
        // Display fork (SETT-23, 2026-08-21): the tile OPENS the Cycle page, and next to
        // "Log period" a bare "Period" read as a second logging action. The rawValue token
        // stays `periodTracking` — persisted quick-log layouts must keep decoding.
        case .periodTracking:
            String(localized: "quickLog.periodTracking", defaultValue: "Cycle page", bundle: .module,
                   comment: "Home quick-log tile and its editor: open the cycle page (not a logging action)")
        case .intimacyTracking:
            String(localized: "quickLog.intimacyTracking", defaultValue: "Intimacy", bundle: .module,
                   comment: "Home quick-log tile and its editor: open intimacy notes")
        case .friends:
            String(localized: "quickLog.friends", defaultValue: "Friends", bundle: .module,
                   comment: "Home quick-log tile and its editor: open friends")
        case .breathing:
            String(localized: "quickLog.breathing", defaultValue: "Slow breathing", bundle: .module,
                   comment: "Home quick-log tile and its editor: start the slow breathing exercise")
        case .grounding:
            String(localized: "quickLog.grounding", defaultValue: "Grounding", bundle: .module,
                   comment: "Home quick-log tile and its editor: start the grounding exercise")
        case .worryBox:
            String(localized: "quickLog.worryBox", defaultValue: "Worry box", bundle: .module,
                   comment: "Home quick-log tile and its editor: open the worry box")
        case .bathroom:
            String(localized: "quickLog.bathroom", defaultValue: "Bathroom", bundle: .module,
                   comment: "Log panel tile and the quick-log editor, Bodybuilding goal only: a count of today's bathroom visits")
        }
    }

    public var systemImage: String {
        switch self {
        case .meal: "fork.knife"
        case .water: "drop"
        case .move: "figure.walk"
        case .sleep: "moon"
        case .journal: "book.closed"
        case .care: "checklist"
        case .logPeriod: "drop.fill"
        case .periodTracking: "calendar.badge.clock"
        case .intimacyTracking: "lock.shield"
        case .friends: "person.2"
        case .breathing: "wind"
        case .grounding: "leaf"
        case .worryBox: "archivebox"
        case .bathroom: "toilet"
        }
    }

    public var screen: FernletScreen? {
        switch self {
        case .move: .move
        case .journal: .journal
        case .periodTracking: .periodTracking
        case .intimacyTracking: .intimacyTracking
        case .friends: .friends
        case .meal, .water, .sleep, .care, .logPeriod, .breathing, .grounding, .worryBox, .bathroom:
            nil
        }
    }

    public static func normalizedQuickLog(_ items: [FernletShortcut]) -> [FernletShortcut] {
        var result: [FernletShortcut] = []
        for item in items where !result.contains(item) {
            result.append(item)
            if result.count == 6 { break }
        }
        for item in defaultQuickLog where result.count < 6 && !result.contains(item) {
            result.append(item)
        }
        // Bathroom is never a filler: it belongs to the Bodybuilding goal and joins only by choice.
        for item in allCases where result.count < 6 && !result.contains(item) && item != .bathroom {
            result.append(item)
        }
        return Array(result.prefix(6))
    }

    /// Which sensitive surfaces the user can currently see. One value type rather than a widening
    /// list of `allows…` Bools, so adding a future gate doesn't re-touch every call site.
    ///
    /// IMPORTANT: filtering by this is DISPLAY-ONLY. Never persist a filtered list back to settings —
    /// hiding a surface would then permanently destroy the user's own quick-log layout, and un-hiding
    /// would not restore it. The stored array keeps every choice; only rendering filters.
    ///
    /// `bathroomAvailable` is whether the Bodybuilding goal is chosen: without it a stored Bathroom
    /// tile shows as Care in its place (``hidingBathroom(_:)``), display only, like the gates above.
    public static func visibleQuickLog(_ items: [FernletShortcut], visibility: SensitiveSurfaceVisibility,
                                       bathroomAvailable: Bool = false) -> [FernletShortcut] {
        let shown = bathroomAvailable ? items : hidingBathroom(items)
        return normalizedQuickLog(shown.filter { visibility.allows($0) })
    }

    public static func selectableQuickLogItems(visibility: SensitiveSurfaceVisibility,
                                               bathroomAvailable: Bool = false) -> [FernletShortcut] {
        allCases.filter { visibility.allows($0) && (bathroomAvailable || $0 != .bathroom) }
    }
}

/// The visibility of Fernlet's gated sensitive surfaces. Defaults to fully visible so callers that
/// don't care (and tests) read naturally.
public nonisolated struct SensitiveSurfaceVisibility: Equatable, Sendable {
    public var intimacy: Bool
    public var period: Bool

    public init(intimacy: Bool = true, period: Bool = true) {
        self.intimacy = intimacy
        self.period = period
    }

    /// Everything visible — the pre-gate behavior.
    public static let all = SensitiveSurfaceVisibility()

    /// Exhaustive on purpose — no `default`. A `default: true` here silently fails OPEN: `.logPeriod`
    /// was missed exactly that way, leaving a live period-logging tile on Home while the feature was
    /// hidden. Listing every case means a new shortcut cannot join without someone deciding whether it
    /// is gated.
    public func allows(_ shortcut: FernletShortcut) -> Bool {
        switch shortcut {
        case .intimacyTracking: intimacy
        // `.logPeriod` writes cycle data; it is gated with the period surfaces, not merely hidden.
        case .periodTracking, .logPeriod: period
        // `.bathroom` is not a sensitive surface: the Bodybuilding goal gates it (`visibleQuickLog`).
        case .meal, .water, .move, .sleep, .journal, .care, .friends, .breathing, .grounding, .worryBox, .bathroom: true
        }
    }

    public func allows(_ screen: FernletScreen) -> Bool {
        switch screen {
        case .intimacyTracking: intimacy
        case .periodTracking: period
        case .food, .move, .journal, .friends, .photos: true
        }
    }
}
