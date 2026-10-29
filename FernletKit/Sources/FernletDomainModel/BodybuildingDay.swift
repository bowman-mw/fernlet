// BodybuildingDay.swift
// FernletDomainModel
//
// One day of the Bodybuilding day calendar (`bb-month`, `bb-week`, `bb-day`), built from a FernletDay plus
// the inputs that live elsewhere (``BodybuildingDayInputs``). A value the views draw and VoiceOver reads;
// display strings in it are resolved in the device's language when it is built.

import Foundation

/// Everything the day calendar shows for one day.
public nonisolated struct BodybuildingDay: Equatable, Sendable, Identifiable {
    /// The day's `yyyy-MM-dd` key.
    public var dateKey: String
    /// Whether any workout was logged.
    public var trained: Bool
    /// How many workouts were logged (the deload rule counts these).
    public var workoutCount: Int
    /// The training's name for screens: the planned split ("Push", "Pull", "Legs") when a logged workout
    /// came from a plan with one, else the workout's own drawn name; several are joined. Nil on a rest day.
    public var trainingName: String?
    /// Hours slept, from the sleep log (or Health's reading on this device), or nil.
    public var sleepHours: Double?
    /// Bathroom visits counted, or nil.
    public var bathroomVisits: Int?
    /// Whether a meal carries the Free meal tag.
    public var freeMeal: Bool
    /// The day's weight in kilograms, or nil.
    public var weightKilograms: Double?
    /// Steps from Health on this device, or nil.
    public var steps: Int?
    /// Grams eaten: protein, carbs and fat.
    public var macros: Macros
    /// The day's macro targets, or nil when none apply.
    public var macroTargets: Macros?
    /// The last mood the day's journal holds (a check-in or an entry's tag), or nil.
    public var feeling: FeelingTag?
    /// The day's care score, 0 to 100, or nil.
    public var careScore: Int?
    /// Whether the day falls in a marked deload week.
    public var isDeload: Bool
    /// Whether the day falls in the week the deload suggestion points at (drawn dashed until chosen).
    public var isSuggestedDeload: Bool
    /// Whether the day is today.
    public var isToday: Bool
    /// Whether the day is still to come (drawn dashed and empty).
    public var isFuture: Bool

    public var id: String { dateKey }

    /// Whether "how the day felt" has anything to show.
    public var hasDayFelt: Bool { feeling != nil || careScore != nil }

    /// A day still to come, or with nothing on it: every signal empty.
    public init(emptyOn dateKey: String, context: BodybuildingDayContext) {
        self.dateKey = dateKey
        trained = false
        workoutCount = 0
        trainingName = nil
        sleepHours = nil
        bathroomVisits = nil
        freeMeal = false
        weightKilograms = nil
        steps = nil
        macros = Macros(protein: 0, carbs: 0, fat: 0)
        macroTargets = nil
        feeling = nil
        careScore = nil
        let week = BodybuildingWeeks.weekStartKey(forDayKey: dateKey, calendar: context.calendar)
        isDeload = week.map { context.deloadWeeks.contains($0) } ?? false
        isSuggestedDeload = week != nil && week == context.suggestedWeek
        isToday = dateKey == context.todayKey
        isFuture = dateKey > context.todayKey
    }

    /// The day `day` with `inputs` and `targets`. A day still to come stays empty whatever it holds.
    public init(day: FernletDay, inputs: BodybuildingDayInputs, targets: Macros?, context: BodybuildingDayContext) {
        self.init(emptyOn: day.date, context: context)
        guard !isFuture else { return }
        trained = !day.workouts.isEmpty
        workoutCount = day.workouts.count
        trainingName = Self.trainingName(for: day)
        sleepHours = day.sleep?.hours ?? day.healthContext?.body?.sleepHours
        bathroomVisits = inputs.bathroomVisits
        freeMeal = inputs.freeMeal
        weightKilograms = inputs.weightKilograms
        steps = day.healthContext?.activity?.steps
        macros = Macros(protein: day.meals.reduce(0) { $0 + $1.macroSnapshot.protein },
                        carbs: day.meals.reduce(0) { $0 + $1.macroSnapshot.carbs },
                        fat: day.meals.reduce(0) { $0 + $1.macroSnapshot.fat })
        macroTargets = targets
        feeling = day.journals.max { $0.date < $1.date }?.tag
        careScore = inputs.careScore.map { min(max($0, 0), 100) }
    }

    /// The splits a plan name stands for on the calendar; a generic `.workout` plan names nothing, so the
    /// workout's own name is drawn instead.
    private static let namingSplits: Set<String> = Set(WorkoutSplit.allCases.filter { $0 != .workout }.map(\.rawValue))

    /// The day's training name: each logged workout's planned split title, or its drawn name, joined.
    static func trainingName(for day: FernletDay) -> String? {
        let plans = Dictionary(day.plannedWorkouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String] = []
        for workout in day.workouts.prefix(8) {
            let plan = workout.plannedWorkoutID.flatMap { plans[$0] }
            let name: String
            if let plan, namingSplits.contains(plan.split.rawValue) {
                name = plan.split.title
            } else {
                name = workout.displayedName
            }
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        guard !names.isEmpty else { return nil }
        return names.count == 1 ? names[0] : ListFormatter.localizedString(byJoining: names)
    }
}

/// Builds the calendar's days from the day records.
public nonisolated enum BodybuildingCalendarBuilder {
    /// The most days one call builds: ten years, the day-key span's own bound.
    public static let maxDays = 3_660

    /// One ``BodybuildingDay`` per key in `keys`, in order: a recorded day from `days`, else an empty one.
    /// `inputs` supplies each day's sealed and Health values; `targets` the macro targets.
    public static func days(
        for keys: [String],
        records days: [String: FernletDay],
        inputs: (String) -> BodybuildingDayInputs,
        targets: Macros?,
        context: BodybuildingDayContext
    ) -> [BodybuildingDay] {
        keys.prefix(maxDays).map { key in
            guard let record = days[key] else {
                var empty = BodybuildingDay(emptyOn: key, context: context)
                let extra = inputs(key)
                guard !empty.isFuture else { return empty }
                empty.bathroomVisits = extra.bathroomVisits
                empty.freeMeal = extra.freeMeal
                empty.weightKilograms = extra.weightKilograms
                empty.careScore = extra.careScore.map { min(max($0, 0), 100) }
                return empty
            }
            return BodybuildingDay(day: record, inputs: inputs(key), targets: targets, context: context)
        }
    }
}
