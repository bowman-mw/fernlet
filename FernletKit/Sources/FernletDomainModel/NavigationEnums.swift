// NavigationEnums.swift
// Split out of Models.swift (SPM carve-up §5c). Screen / widget / shortcut navigation enums (app target).

import Foundation

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

    nonisolated public static let defaultWidgets: [HomeWidget] = [.companion, .todaySummary, .todayIntent, .ambient, .quickLog, .macros, .trends, .firstAid, .milestones]

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
        case .hygiene: "Hygiene"
        case .macros: "Macros"
        case .trends: "Trends"
        case .ambient: "Moments"
        case .milestones: "Milestones"
        case .firstAid: "First aid"
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
        }
    }

    public var isAction: Bool {
        switch self {
        case .logFood, .recipeBook, .newRecipe, .workout, .journal, .sleep, .water, .hygiene, .trends:
            true
        case .companion, .todaySummary, .todayIntent, .quickLog, .macros, .ambient, .milestones, .firstAid:
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
        case .periodTracking: "Period"
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

    public static func visibleQuickLog(_ items: [FernletShortcut], allowsIntimacy: Bool) -> [FernletShortcut] {
        let availableItems = allowsIntimacy ? items : items.filter { $0 != .intimacyTracking }
        return normalizedQuickLog(availableItems)
    }

    public static func selectableQuickLogItems(allowsIntimacy: Bool) -> [FernletShortcut] {
        allCases.filter { allowsIntimacy || $0 != .intimacyTracking }
    }
}
