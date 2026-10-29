// BodybuildingCalendarSettings.swift
// FernletDomainModel
//
// The Bodybuilding goal's day calendar preferences (World round 7, `bb-signals`, `bb-deload`,
// `bb-deload-suggest`; spec Docs/Handoff/World-Bodybuilding-Spec.md, approved 2026-10-29): which signals
// show, which view it opens on, the deload weeks, and the deload suggestion's "Not now". One field of the
// synced settings blob (`FernletSettings.bodybuildingCalendar`), decoded tolerantly like the quick-log
// shortcuts: unknown signal tokens from a newer build are parked, never thrown on.

import Foundation

/// One of the eight things the day calendar can show for a day (`bb-signals`).
///
/// `rawValue` is the FROZEN persisted token in ``BodybuildingCalendarSettings/signals``; screens read
/// ``displayName`` and ``sourceLine``.
public nonisolated enum BodybuildingSignal: String, Codable, CaseIterable, Identifiable, Sendable {
    case training
    case sleep
    case bathroom
    case freeMeals
    case weight
    case steps
    case macros
    case dayFelt

    public var id: String { rawValue }

    /// The signals on to start (the spec's "On to start" column).
    public static let defaultOn: [BodybuildingSignal] = [.training, .sleep, .bathroom, .freeMeals, .weight]

    /// The order the month cells pick their marks in: the four the approved month draws first, then the
    /// rest. ``weight`` is not here: it has its own line under the grid.
    public static let monthCellPriority: [BodybuildingSignal] = [.training, .sleep, .bathroom, .freeMeals,
                                                                 .steps, .dayFelt, .macros]

    /// How many signals fit in one month cell.
    public static let monthCellCapacity = 4

    /// The switch's name on Calendar signals.
    public var displayName: String {
        switch self {
        case .training: String(localized: "bodybuilding.signal.training", defaultValue: "Training", bundle: .module,
                               comment: "Day calendar signal: whether the person trained that day")
        case .sleep: String(localized: "bodybuilding.signal.sleep", defaultValue: "Sleep", bundle: .module,
                            comment: "Day calendar signal: hours of sleep")
        case .bathroom: String(localized: "bodybuilding.signal.bathroom", defaultValue: "Bathroom visits", bundle: .module,
                               comment: "Day calendar signal: how many times the person went to the bathroom (a bowel-movement count)")
        case .freeMeals: String(localized: "bodybuilding.signal.freeMeals", defaultValue: "Free meals", bundle: .module,
                                comment: "Day calendar signal: meals the person tagged as a free meal (a planned, relaxed meal; never 'cheat')")
        case .weight: String(localized: "bodybuilding.signal.weight", defaultValue: "Weight", bundle: .module,
                             comment: "Day calendar signal: body weight")
        case .steps: String(localized: "bodybuilding.signal.steps", defaultValue: "Steps", bundle: .module,
                            comment: "Day calendar signal: steps walked")
        case .macros: String(localized: "bodybuilding.signal.macros", defaultValue: "Macros", bundle: .module,
                             comment: "Day calendar signal: protein, carbs and fat eaten")
        case .dayFelt: String(localized: "bodybuilding.signal.dayFelt", defaultValue: "How the day felt", bundle: .module,
                              comment: "Day calendar signal: how the day felt, from the person's mood or care score")
        }
    }

    /// Where the signal comes from, under its switch on Calendar signals.
    public var sourceLine: String {
        switch self {
        case .training: String(localized: "bodybuilding.signal.training.source", defaultValue: "From your workouts", bundle: .module,
                               comment: "Calendar signals: where the Training signal comes from")
        case .sleep: String(localized: "bodybuilding.signal.sleep.source", defaultValue: "From your sleep log", bundle: .module,
                            comment: "Calendar signals: where the Sleep signal comes from")
        case .bathroom: String(localized: "bodybuilding.signal.bathroom.source", defaultValue: "A count per day", bundle: .module,
                               comment: "Calendar signals: what the Bathroom visits signal is (a simple count for each day)")
        case .freeMeals: String(localized: "bodybuilding.signal.freeMeals.source", defaultValue: "Meals you tag", bundle: .module,
                                comment: "Calendar signals: where the Free meals signal comes from (meals the person tags as free meals)")
        case .weight: String(localized: "bodybuilding.signal.weight.source", defaultValue: "From Health", bundle: .module,
                             comment: "Calendar signals: the Weight signal comes from Apple Health")
        case .steps: String(localized: "bodybuilding.signal.steps.source", defaultValue: "From Health", bundle: .module,
                            comment: "Calendar signals: the Steps signal comes from Apple Health")
        case .macros: String(localized: "bodybuilding.signal.macros.source", defaultValue: "From your meals", bundle: .module,
                             comment: "Calendar signals: where the Macros signal comes from")
        case .dayFelt: String(localized: "bodybuilding.signal.dayFelt.source", defaultValue: "From your care score", bundle: .module,
                              comment: "Calendar signals: where the How the day felt signal comes from")
        }
    }
}

/// The view the day calendar opens on (`bb-signals`: "Opens on: Month | Week").
///
/// `rawValue` is the FROZEN persisted token; screens read ``displayName``.
public nonisolated enum BodybuildingCalendarMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case month
    case week

    public var id: String { rawValue }

    /// The segment's label.
    public var displayName: String {
        switch self {
        case .month: String(localized: "bodybuilding.mode.month", defaultValue: "Month", bundle: .module,
                            comment: "Day calendar: the month view, one cell per day")
        case .week: String(localized: "bodybuilding.mode.week", defaultValue: "Week", bundle: .module,
                           comment: "Day calendar: the week view, one row per day")
        }
    }
}

/// A "Not now" on the deload suggestion: which run of hard weeks it was said to, and how long that run
/// was then. ``BodybuildingDeloadRule`` asks again only once the same run is two hard weeks longer.
public nonisolated struct BodybuildingDeloadDecline: Codable, Equatable, Sendable {
    /// The Monday day key of the first week of the run the person said "Not now" to.
    public var runStart: String
    /// How many hard weeks the run held when they said it.
    public var runLength: Int

    public init(runStart: String, runLength: Int) {
        self.runStart = runStart
        self.runLength = runLength
    }
}

/// The day calendar's synced preferences (``FernletSettings/bodybuildingCalendar``).
///
/// Every field decodes tolerantly with a default, so a blob saved before the calendar existed decodes
/// to ``init()``. Signal tokens this build does not know park in ``unknownSignalTokens`` and are written
/// back, exactly like ``FernletSettings/unknownQuickLogTokens``. Nothing here counts anything against the
/// person: there is no streak, only the weeks they marked as deloads.
public nonisolated struct BodybuildingCalendarSettings: Codable, Equatable, Sendable {
    /// The most deload weeks kept: ten years of weekly marks.
    public static let maxDeloadWeeks = 520

    /// The signals that are on, in the switches' standard order.
    public var signals: [BodybuildingSignal] = BodybuildingSignal.defaultOn
    /// Signal tokens a newer build turned on that this build does not know; written back untouched.
    public var unknownSignalTokens: [String] = []
    /// The view the calendar opens on.
    public var opensOn: BodybuildingCalendarMode = .month {
        didSet { unknownOpensOnToken = nil }
    }
    /// A newer build's `opensOn` token this build does not know; cleared by an explicit choice here.
    public var unknownOpensOnToken: String?
    /// The Monday day keys (`yyyy-MM-dd`) of the weeks marked as deloads: sorted, unique, at most
    /// ``maxDeloadWeeks``. Write through ``setDeload(weekStart:_:)``.
    public private(set) var deloadWeekStarts: [String] = []
    /// The last "Not now" on the deload suggestion, or nil.
    public var deloadSuggestionDecline: BodybuildingDeloadDecline?
    /// Whether the Log panel's Bathroom tile has been put in Care's place once (a later piece reads it,
    /// so the swap happens only the first time Bodybuilding is chosen).
    public var bathroomTileSeeded: Bool = false

    public init() {}

    /// Whether `signal` is on.
    public func isOn(_ signal: BodybuildingSignal) -> Bool {
        signals.contains(signal)
    }

    /// Turns `signal` on or off, keeping the switches' standard order.
    public mutating func setSignal(_ signal: BodybuildingSignal, on: Bool) {
        var chosen = Set(signals)
        if on { chosen.insert(signal) } else { chosen.remove(signal) }
        signals = BodybuildingSignal.allCases.filter { chosen.contains($0) }
    }

    /// The signals one month cell draws: the on-list in ``BodybuildingSignal/monthCellPriority`` order,
    /// at most ``BodybuildingSignal/monthCellCapacity``. Weight never takes a cell (see ``showsWeightLine``).
    public var monthCellSignals: [BodybuildingSignal] {
        let chosen = Set(signals)
        return Array(BodybuildingSignal.monthCellPriority.filter { chosen.contains($0) }
            .prefix(BodybuildingSignal.monthCellCapacity))
    }

    /// Whether the month draws the weight line under its grid.
    public var showsWeightLine: Bool { isOn(.weight) }

    /// Whether the week starting on the Monday key `weekStart` is a deload week.
    public func isDeload(weekStart: String) -> Bool {
        deloadWeekStarts.contains(weekStart)
    }

    /// Marks or clears the week starting on the Monday key `weekStart` as a deload week. A key that is
    /// not a `yyyy-MM-dd` day is ignored.
    public mutating func setDeload(weekStart: String, _ isDeload: Bool) {
        guard Self.isDayKey(weekStart) else { return }
        var weeks = Set(deloadWeekStarts)
        if isDeload { weeks.insert(weekStart) } else { weeks.remove(weekStart) }
        deloadWeekStarts = Self.normalizedWeeks(Array(weeks))
    }

    /// Sorted, unique, well-formed day keys, keeping the newest ``maxDeloadWeeks``.
    static func normalizedWeeks(_ keys: [String]) -> [String] {
        let valid = Set(keys.filter(isDayKey)).sorted()
        return Array(valid.suffix(maxDeloadWeeks))
    }

    /// Whether `key` reads as a `yyyy-MM-dd` day (shape only: ten characters, digits and two dashes).
    static func isDayKey(_ key: String) -> Bool {
        let characters = Array(key)
        guard characters.count == 10, characters[4] == "-", characters[7] == "-" else { return false }
        return characters.enumerated().allSatisfy { index, character in
            index == 4 || index == 7 || character.isASCII && character.isNumber
        }
    }

    /// The persisted keys; renaming one is a wire-format break.
    private enum CodingKeys: String, CodingKey {
        case signals, unknownSignalTokens, opensOn, unknownOpensOnToken, deloadWeekStarts,
             deloadSuggestionDecline, bathroomTileSeeded
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tokens = try container.decodeIfPresent([String].self, forKey: .signals)
            ?? BodybuildingSignal.defaultOn.map(\.rawValue)
        let parked = try container.decodeIfPresent([String].self, forKey: .unknownSignalTokens) ?? []
        let split = EnumDecodeCompat.splitRawTokens(tokens + parked, as: BodybuildingSignal.self)
        let known = Set(split.known)
        signals = BodybuildingSignal.allCases.filter { known.contains($0) }
        unknownSignalTokens = split.unknown
        let mode = try container.decodeTolerantEnum(BodybuildingCalendarMode.self, forKey: .opensOn,
                                                    parkedTokenKey: .unknownOpensOnToken, default: .month)
        opensOn = mode.value
        unknownOpensOnToken = mode.parkedToken
        let weeks = try container.decodeIfPresent([String].self, forKey: .deloadWeekStarts) ?? []
        deloadWeekStarts = Self.normalizedWeeks(Array(weeks.prefix(Self.maxDeloadWeeks * 2)))
        deloadSuggestionDecline = try container.decodeIfPresent(BodybuildingDeloadDecline.self, forKey: .deloadSuggestionDecline)
        bathroomTileSeeded = try container.decodeIfPresent(Bool.self, forKey: .bathroomTileSeeded) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(signals.map(\.rawValue), forKey: .signals)
        try container.encode(unknownSignalTokens, forKey: .unknownSignalTokens)
        try container.encode(opensOn, forKey: .opensOn)
        try container.encodeIfPresent(unknownOpensOnToken, forKey: .unknownOpensOnToken)
        try container.encode(deloadWeekStarts, forKey: .deloadWeekStarts)
        try container.encodeIfPresent(deloadSuggestionDecline, forKey: .deloadSuggestionDecline)
        try container.encode(bathroomTileSeeded, forKey: .bathroomTileSeeded)
    }
}
