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

    public var title: String {
        switch self {
        case .disabled: return "Disabled"
        case .passive: return "Passive"
        case .live: return "Live"
        }
    }
}

/// The navigable feature screens a shortcut or home widget can deep-link to.
///
/// Carries the display metadata (title/subtitle/symbol) each launcher surface renders; the
/// sensitive screens are filtered through ``SensitiveSurfaceVisibility`` before display.
public nonisolated enum FernletScreen: String, Codable, CaseIterable, Identifiable {
    case food
    case move
    case journal
    case periodTracking
    case intimacyTracking
    case friends
    case photos

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .food: "Food"
        case .move: "Move"
        case .journal: "Journal"
        case .periodTracking: "Period"
        case .intimacyTracking: "Intimacy"
        case .friends: "Friends"
        case .photos: "Photos"
        }
    }

    public var subtitle: String {
        switch self {
        case .food: "Meals, macros, and recipes."
        case .move: "Training, walks, and recovery."
        case .journal: "Mood and short daily notes."
        case .periodTracking: "Cycle notes and Health context."
        case .intimacyTracking: "Private intimacy notes."
        case .friends: "People to remember."
        case .photos: "A small photo wall."
        }
    }

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

    nonisolated public static let defaultWidgets: [HomeWidget] = [.companion, .todaySummary, .todayIntent, .ambient, .quickLog, .macros, .trends, .firstAid, .milestones, .mealPhotos]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .companion: "Companion"
        case .todaySummary: "Today"
        case .todayIntent: "Today's intent"
        case .quickLog: "Quick log"
        case .logFood: "Log food"
        case .recipeBook: "Recipe book"
        case .newRecipe: "New recipe"
        case .workout: "Workout"
        case .journal: "Journal"
        case .sleep: "Sleep"
        case .water: "Water"
        // "Personal care", matching the card this widget draws and the sheet that card opens. The
        // same set of tasks used to be called Care (tile), Personal care (sheet) and Hygiene (here),
        // so the widget-order list named a feature nothing else in the app called by that name.
        case .hygiene: "Personal care"
        case .macros: "Macros"
        case .trends: "Trends"
        case .ambient: "Moments"
        case .milestones: "Milestones"
        case .firstAid: "First aid"
        case .mealPhotos: "Recent bites"
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
        }
    }

    public var isAction: Bool {
        switch self {
        case .logFood, .recipeBook, .newRecipe, .workout, .journal, .sleep, .water, .hygiene, .trends:
            true
        case .companion, .todaySummary, .todayIntent, .quickLog, .macros, .ambient, .milestones, .firstAid, .mealPhotos:
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

    nonisolated public static let defaultQuickLog: [FernletShortcut] = [.meal, .water, .move, .sleep, .journal, .care]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .meal: "Meal"
        case .water: "Water"
        case .move: "Move"
        case .sleep: "Sleep"
        case .journal: "Journal"
        case .care: "Care"
        case .logPeriod: "Log period"
        // Display fork (SETT-23, 2026-08-21): the tile OPENS the Cycle page, and next to
        // "Log period" a bare "Period" read as a second logging action. The rawValue token
        // stays `periodTracking` — persisted quick-log layouts must keep decoding.
        case .periodTracking: "Cycle page"
        case .intimacyTracking: "Intimacy"
        case .friends: "Friends"
        case .breathing: "Slow breathing"
        case .grounding: "Grounding"
        case .worryBox: "Worry box"
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
        }
    }

    public var screen: FernletScreen? {
        switch self {
        case .move: .move
        case .journal: .journal
        case .periodTracking: .periodTracking
        case .intimacyTracking: .intimacyTracking
        case .friends: .friends
        case .meal, .water, .sleep, .care, .logPeriod, .breathing, .grounding, .worryBox:
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
        for item in allCases where result.count < 6 && !result.contains(item) {
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
    public static func visibleQuickLog(_ items: [FernletShortcut], visibility: SensitiveSurfaceVisibility) -> [FernletShortcut] {
        normalizedQuickLog(items.filter { visibility.allows($0) })
    }

    public static func selectableQuickLogItems(visibility: SensitiveSurfaceVisibility) -> [FernletShortcut] {
        allCases.filter { visibility.allows($0) }
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
        case .meal, .water, .move, .sleep, .journal, .care, .friends, .breathing, .grounding, .worryBox: true
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
