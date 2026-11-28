import Foundation
import FernletDomainModel
import FernletFoundation

// AmbientReminders.swift
//
// The pure half of Home's "gentle reminders" (spec §12: "Reappearance of forgotten good things, max
// once per month per category" and "Seasonal rhythm recognition after roughly one year"; owner's
// G8 wording and rules, 2026-11-13). Everything here is value types with the clock injected, so the
// caps, thresholds and the one-year gate are tested without SwiftUI. `AmbientCardsView` gathers the
// inputs, `AmbientReminderMemory` keeps the device-local record, and `AmbientReminderCopy` holds the
// words.
//
// CAP-2 (G3, PR #152): Home is not behind the lock, so nothing here reads sealed or Private-hub data.
// The inputs are meals, recipes, workouts, water and nightly sleep totals from the diary, the
// breathing and grounding finish dates this iPhone keeps, and the weather's coarse latitude (rounded
// to 1°, never stored). Never the journal, mood tags, the Worry Box, the cycle, intimacy, or the World
// map's places (sealed under the hub key). `AmbientRemindersTests` scans this file.
//
// CAP-2's one named exception (owner's P1-A, 2026-11-27): the quiet-place card reads Home's place
// summary, `PlaceVisitSummary`, through its one reader, `PlaceVisitSummaryReader`, and nothing else of
// the World map. The fold under the hub key writes that summary (per place: the person's own name or
// Fernlet's kind token, the last-visit day and a 60-day visit count; never Apple's name, a point, a
// reference or the timeline) under the map vault's buffer key, device-only. It is never written or read
// in a decoy, and every wipe removes it with the map vault. `FernletStore+AmbientPlaces.swift` is the
// only file that touches the reader; `AmbientRemindersSealedBoundaryTests` allows exactly that type.
//
// Never on the list: streaks, goals, personal bests, milestones, counts shown to the person, or any
// comparison of now with before. A seasonal card says what last year was like and nothing else.

/// One kind of gentle reminder. The raw values are FROZEN persisted tokens: the schedule in
/// `AmbientReminderMemory` keys on them, so never rename them.
nonisolated enum AmbientReminderKind: String, CaseIterable, Sendable {
    /// "Haven't had these in a while": meal chips for favourites not eaten lately.
    case forgottenMeal
    /// "Remember this one?": a workout done before and not lately.
    case forgottenWorkout
    /// "Still sound good?": a recipe made a few times and not lately.
    case forgottenRecipe
    /// "It's still here": a breathing or grounding tool that helped before.
    case forgottenCalm
    /// "Soup season": last year's same season was full of soup.
    case seasonalSoup
    /// "This time last year": lots of walks around now last year.
    case seasonalWalks
    /// "This time last year": last year's same season was a busy stretch of workouts.
    case seasonalWorkouts
    /// "Warm days ahead": last summer the water kept coming.
    case seasonalWater
    /// "A favourite spot": a place the person used to enjoy and hasn't been to in a while (P2-A, 2026-11-27).
    case quietPlace
    /// "Short days": short daylight and short nights lately (S1-C, 2026-11-27).
    case shortDays

    /// Whether the kind is a seasonal-rhythm card, which shares one monthly cap with the others.
    var isSeasonal: Bool {
        switch self {
        case .seasonalSoup, .seasonalWalks, .seasonalWorkouts, .seasonalWater: true
        case .forgottenMeal, .forgottenWorkout, .forgottenRecipe, .forgottenCalm, .quietPlace, .shortDays: false
        }
    }
}

/// The calm tools whose finished sessions this iPhone remembers (dates only). The raw values are
/// FROZEN persisted tokens in `AmbientReminderMemory`.
nonisolated enum AmbientCalmTool: String, CaseIterable, Sendable {
    /// Slow breathing with the Box pattern.
    case boxBreathing
    /// Slow breathing with the Relax (4-7-8) pattern.
    case relaxBreathing
    /// The 5-4-3-2-1 grounding exercise.
    case grounding

    /// The breathing tool for a stored preset id (`BreathingPreset.id`, a frozen token: "box" or "relax";
    /// `AmbientForgottenTests` pins the two together); nil for an unknown one.
    init?(breathingPresetID id: String) {
        switch id {
        case "box": self = .boxBreathing
        case "relax": self = .relaxBreathing
        default: return nil
        }
    }

    /// The breathing preset the tool opens on; nil for grounding.
    var breathingPresetID: String? {
        switch self {
        case .boxBreathing: "box"
        case .relaxBreathing: "relax"
        case .grounding: nil
        }
    }
}

/// A meteorological season (three whole months).
///
/// The hemisphere comes from the person's region setting (`isSouthern(region:)`), the one cheap hint
/// the app has; with no region it is the Northern one.
nonisolated enum AmbientSeason: String, CaseIterable, Sendable {
    /// March–May in the north, September–November in the south.
    case spring
    /// June–August in the north, December–February in the south.
    case summer
    /// September–November in the north, March–May in the south.
    case autumn
    /// December–February in the north, June–August in the south.
    case winter

    /// Regions wholly or mostly south of the equator, where the seasons turn the other way round.
    static let southernRegions: Set<String> = [
        "AR", "AU", "BO", "BR", "BW", "CL", "FJ", "LS", "MG", "MU", "MW", "MZ", "NA", "NZ",
        "PE", "PG", "PY", "SB", "SZ", "TO", "UY", "VU", "WS", "ZA", "ZM", "ZW"
    ]

    /// Whether `region` (an ISO 3166 code such as "AU") is in the southern hemisphere.
    static func isSouthern(region: String?) -> Bool {
        guard let region, !region.isEmpty else { return false }
        return southernRegions.contains(region.uppercased())
    }

    /// The season a calendar `month` (1–12) falls in.
    static func season(forMonth month: Int, southern: Bool) -> AmbientSeason {
        assert((1...12).contains(month), "a calendar month is 1–12")
        // 0 = March–May, 1 = June–August, 2 = September–November, 3 = December–February.
        let quarter = ((month - 3 + 12) % 12) / 3
        let north: [AmbientSeason] = [.spring, .summer, .autumn, .winter]
        let south: [AmbientSeason] = [.autumn, .winter, .spring, .summer]
        return (southern ? south : north)[quarter]
    }
}

/// A dated amount in the history: one meal, one workout, or a day's bottles of water.
nonisolated struct AmbientDatedAmount: Equatable, Sendable {
    /// When it happened.
    let date: Date
    /// How much (1 for an event, the bottle count for water).
    let amount: Double
}

/// One recipe the person made, with every date it was logged.
nonisolated struct AmbientRecipeUse: Equatable, Sendable {
    /// The recipe's id, for "Open recipe".
    let id: UUID
    /// The recipe's name as the person wrote it.
    let name: String
    /// Each day it was logged.
    let dates: [Date]
}

/// A reminder chosen for Home: its kind and what it is about.
nonisolated struct AmbientReminder: Equatable, Sendable {
    /// What the reminder is about.
    enum Subject: Equatable, Sendable {
        /// Nothing beyond the kind (meal chips and the workout carry their own state).
        case none
        /// A recipe: its id and name.
        case recipe(id: UUID, name: String)
        /// A breathing or grounding tool.
        case calm(AmbientCalmTool)
        /// Last year's season the card talks about.
        case season(AmbientSeason)
        /// A quiet place: the person's own name for it, or nil to name it by its kind.
        case place(label: String?, kind: AmbientPlaceKind?)
        /// Short days and short nights: nothing more to say.
        case shortDays
    }

    /// The kind, which the caps count by.
    let kind: AmbientReminderKind
    /// What it is about.
    let subject: Subject
}
