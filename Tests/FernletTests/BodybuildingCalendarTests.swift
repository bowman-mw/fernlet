import Foundation
import Testing
import FernletDomainModel
import FernletScoring

/// The Bodybuilding goal (`bb-goal`, approved 2026-10-29) and what it shapes: nutrition, rest, the split
/// ranking, the volume style and the score weights.
struct BodybuildingGoalTests {
    @Test func theGoalIsATrainingGoalWithItsFrozenToken() {
        #expect(GoalType.bodybuilding.rawValue == "bodybuilding")
        #expect(GoalType(persistedToken: "bodybuilding") == .bodybuilding)
        #expect(GoalType.bodybuilding.isTrainingFocused)
        #expect(GoalType.bodybuilding.displayName == "Bodybuilding")
        #expect(GoalType.bodybuilding.tagline == "Build on purpose, rest on purpose.")
        #expect(GoalType.bodybuilding.nutritionSummary == "A small surplus · high protein")
        #expect(GoalType.bodybuilding.trainingSummary == "Push, pull and legs, with deload weeks.")
    }

    @Test func onlyBodybuildingHasACalendarLine() {
        #expect(GoalType.bodybuilding.calendarSummary == "Turns on the day calendar in Move.")
        for goal in GoalType.allCases where goal != .bodybuilding {
            #expect(goal.calendarSummary == nil, "\(goal.rawValue)")
        }
    }

    @Test func aSmallSurplusWithAtLeastStrengthsProtein() {
        var settings = FernletSettings()
        settings.selectedGoal = .wellness
        let maintenance = NutritionTargetCalculator.targets(for: settings)
        settings.selectedGoal = .strength
        let strength = NutritionTargetCalculator.targets(for: settings)
        settings.selectedGoal = .bodybuilding
        let bodybuilding = NutritionTargetCalculator.targets(for: settings)
        #expect(bodybuilding.calories > maintenance.calories, "a surplus")
        #expect(bodybuilding.calories <= strength.calories, "no bigger than Strength's")
        #expect(bodybuilding.protein >= strength.protein)
    }

    @Test func restSitsBetweenStrengthAndTheEverydayGoals() {
        for demand in [WorkoutRestGuidance.Demand.heavyCompound, .compound, .isolation, .core] {
            let rest = WorkoutRestGuidance.restSeconds(demand: demand, goal: .bodybuilding)
            #expect(rest <= WorkoutRestGuidance.restSeconds(demand: demand, goal: .strength))
            #expect(rest >= WorkoutRestGuidance.restSeconds(demand: demand, goal: .wellness))
        }
    }

    @Test func pushPullLegsLeadsTheRanking() {
        let ranked = WorkoutSplitRecommender.ranked(goal: .bodybuilding, experience: .intermediate,
                                                    consistency: .medium, activity: .moderate, preferredDays: 3)
        #expect(ranked.first?.id == "ppl-3")
        let six = WorkoutSplitRecommender.ranked(goal: .bodybuilding, experience: .advanced,
                                                 consistency: .medium, activity: .active, preferredDays: 6)
        #expect(six.first.map { WorkoutSplitRecommender.pushPullLegsSplitIDs.contains($0.id) } == true)
        // Every other goal ranks as it did: no bonus.
        let strength = WorkoutSplitRecommender.ranked(goal: .strength, experience: .intermediate,
                                                      consistency: .medium, activity: .moderate, preferredDays: 3)
        #expect(strength.first?.id != nil)
        for split in WorkoutSplitCatalog.all {
            #expect(WorkoutSplitRecommender.preferenceBonus(split, goal: .strength) == 0)
        }
    }

    @Test func hypertrophyVolumeAndMainLiftTracking() {
        let style = WorkoutGoalStyle.style(for: .bodybuilding, energy: .moderate, sport: "")
        #expect(style.mainSets == 4 && style.mainReps == "6-10" && style.accessoryReps == "10-15")
        #expect(PlateauTracking.forGoal(.bodybuilding) == .mainLifts)
    }

    @Test func scoreWeightsSumToOneAndLeanOnSleep() {
        let weights = GoalWeights.forGoal(.bodybuilding)
        #expect(abs(weights.total - 1) < 0.000_001)
        #expect(weights.sleepWeight > GoalWeights.forGoal(.strength).sleepWeight)
    }

    @Test func theFallbackLibraryHasBodybuildingTemplatesUnderFrozenNames() {
        let suggestions = WorkoutSuggestionLibrary.suggestions(for: .bodybuilding, intensity: .moderate, addressing: .masculine)
        #expect(suggestions.map(\.name) == [WorkoutFallbackName.strengthBase.rawValue])
        #expect(suggestions.first?.exercises.contains("4 x 10") == true)
    }
}

/// The day calendar's settings (`bb-signals`): defaults, the month's four, the deload weeks, and a
/// tolerant decode that keeps older blobs and a newer build's tokens.
struct BodybuildingCalendarSettingsTests {
    @Test func defaultsMatchTheSpec() {
        let settings = BodybuildingCalendarSettings()
        #expect(settings.signals == [.training, .sleep, .bathroom, .freeMeals, .weight])
        #expect(settings.opensOn == .month)
        #expect(settings.deloadWeekStarts.isEmpty)
        #expect(settings.deloadSuggestionDecline == nil)
        #expect(!settings.bathroomTileSeeded)
        #expect(BodybuildingSignal.allCases.map(\.rawValue)
            == ["training", "sleep", "bathroom", "freeMeals", "weight", "steps", "macros", "dayFelt"])
    }

    @Test func everySignalHasANameAndASource() {
        let names = BodybuildingSignal.allCases.map(\.displayName)
        #expect(names == ["Training", "Sleep", "Bathroom visits", "Free meals", "Weight", "Steps", "Macros", "How the day felt"])
        #expect(BodybuildingSignal.allCases.map(\.sourceLine) == [
            "From your workouts", "From your sleep log", "A count per day", "Meals you tag", "From Health",
            "From Health", "From your meals", "From your care score",
        ])
    }

    @Test func switchingKeepsTheStandardOrder() {
        var settings = BodybuildingCalendarSettings()
        settings.setSignal(.steps, on: true)
        settings.setSignal(.training, on: false)
        settings.setSignal(.training, on: true)
        #expect(settings.signals == [.training, .sleep, .bathroom, .freeMeals, .weight, .steps])
    }

    @Test func theMonthPicksFourAndWeightHasItsOwnLine() {
        var settings = BodybuildingCalendarSettings()
        #expect(settings.monthCellSignals == [.training, .sleep, .bathroom, .freeMeals])
        #expect(settings.showsWeightLine)
        settings.setSignal(.bathroom, on: false)
        settings.setSignal(.macros, on: true)
        settings.setSignal(.steps, on: true)
        #expect(settings.monthCellSignals == [.training, .sleep, .freeMeals, .steps])
        settings.setSignal(.weight, on: false)
        #expect(!settings.showsWeightLine)
    }

    @Test func deloadWeeksStaySortedUniqueAndWellFormed() {
        var settings = BodybuildingCalendarSettings()
        settings.setDeload(weekStart: "2026-10-19", true)
        settings.setDeload(weekStart: "2026-09-07", true)
        settings.setDeload(weekStart: "2026-10-19", true)
        settings.setDeload(weekStart: "not a day", true)
        #expect(settings.deloadWeekStarts == ["2026-09-07", "2026-10-19"])
        settings.setDeload(weekStart: "2026-09-07", false)
        #expect(settings.deloadWeekStarts == ["2026-10-19"])
        #expect(settings.isDeload(weekStart: "2026-10-19"))
    }

    @Test func anOlderBlobDecodesToTheDefaultAndKeepsItsShape() throws {
        let legacy = try JSONEncoder().encode(FernletSettings())
        let object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        #expect(object["bodybuildingCalendar"] == nil, "a default calendar adds no key to the blob")
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: legacy)
        #expect(decoded.bodybuildingCalendar == BodybuildingCalendarSettings())
        #expect(decoded.parkedUnknownKeys["bodybuildingCalendar"] == nil)
    }

    @Test func aChosenCalendarRoundTripsThroughTheSettingsBlob() throws {
        var settings = FernletSettings()
        settings.bodybuildingCalendar.setSignal(.macros, on: true)
        settings.bodybuildingCalendar.opensOn = .week
        settings.bodybuildingCalendar.setDeload(weekStart: "2026-10-19", true)
        settings.bodybuildingCalendar.deloadSuggestionDecline = BodybuildingDeloadDecline(runStart: "2026-09-07", runLength: 6)
        settings.bodybuildingCalendar.bathroomTileSeeded = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: data)
        #expect(decoded.bodybuildingCalendar == settings.bodybuildingCalendar)
    }

    @Test func aNewerBuildsTokensParkAndComeBack() throws {
        let json = """
        {"signals": ["training", "heartRate", "sleep"], "opensOn": "year",
         "deloadWeekStarts": ["2026-10-19", "2026-10-19", "garbage", "2026-01-05"]}
        """
        let decoded = try JSONDecoder().decode(BodybuildingCalendarSettings.self, from: Data(json.utf8))
        #expect(decoded.signals == [.training, .sleep])
        #expect(decoded.unknownSignalTokens == ["heartRate"])
        #expect(decoded.opensOn == .month)
        #expect(decoded.unknownOpensOnToken == "year")
        #expect(decoded.deloadWeekStarts == ["2026-01-05", "2026-10-19"])
        let again = try JSONDecoder().decode(BodybuildingCalendarSettings.self, from: JSONEncoder().encode(decoded))
        #expect(again.unknownSignalTokens == ["heartRate"])
        #expect(again.unknownOpensOnToken == "year")
        var chosen = again
        chosen.opensOn = .week
        #expect(chosen.unknownOpensOnToken == nil, "an explicit choice here clears the parked token")
    }

    @Test func anEmptyObjectDecodesToTheDefault() throws {
        let decoded = try JSONDecoder().decode(BodybuildingCalendarSettings.self, from: Data("{}".utf8))
        #expect(decoded == BodybuildingCalendarSettings())
    }

    @Test func deloadWeeksAreCapped() throws {
        let keys = (0..<600).compactMap {
            BodybuildingWeeks.dayKey("2010-01-04", addingDays: 7 * $0, calendar: BodybuildingWeeksTests.calendar)
        }
        let json = try JSONSerialization.data(withJSONObject: ["deloadWeekStarts": keys])
        let decoded = try JSONDecoder().decode(BodybuildingCalendarSettings.self, from: json)
        #expect(decoded.deloadWeekStarts.count == BodybuildingCalendarSettings.maxDeloadWeeks)
        #expect(decoded.deloadWeekStarts.last == keys.last, "the newest weeks are kept")
    }
}

/// Monday-first week and month math.
struct BodybuildingWeeksTests {
    static let calendar = BodybuildingWeeks.calendar(timeZone: TimeZone(secondsFromGMT: 0) ?? .current)

    @Test func weeksStartOnMonday() {
        #expect(BodybuildingWeeks.weekStartKey(forDayKey: "2026-10-26", calendar: Self.calendar) == "2026-10-26")
        #expect(BodybuildingWeeks.weekStartKey(forDayKey: "2026-10-29", calendar: Self.calendar) == "2026-10-26")
        #expect(BodybuildingWeeks.weekStartKey(forDayKey: "2026-11-01", calendar: Self.calendar) == "2026-10-26")
        #expect(BodybuildingWeeks.weekStartKey(forDayKey: "2027-01-01", calendar: Self.calendar) == "2026-12-28")
        #expect(BodybuildingWeeks.weekStartKey(forDayKey: "2026-02-30", calendar: Self.calendar) == nil)
    }

    @Test func aWeekIsSevenDaysAcrossAMonthEnd() {
        #expect(BodybuildingWeeks.weekDayKeys(weekStart: "2026-10-26", calendar: Self.calendar) == [
            "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01",
        ])
        #expect(BodybuildingWeeks.weekDayKeys(weekStart: "nope", calendar: Self.calendar).isEmpty)
    }

    @Test func octoberTwentyTwentySixMatchesTheApprovedGrid() throws {
        // The approved month: the 1st is a Thursday, so three blanks lead.
        let date = try #require(BodybuildingWeeks.date(fromDayKey: "2026-10-15", calendar: Self.calendar))
        let layout = BodybuildingWeeks.monthLayout(containing: date, calendar: Self.calendar)
        #expect(layout.firstDayKey == "2026-10-01")
        #expect(layout.leadingBlanks == 3)
        #expect(layout.dayKeys.count == 31)
        #expect(layout.trailingBlanks == 1)
        #expect(layout.rows.count == 5)
        #expect(layout.rows.allSatisfy { $0.count == 7 })
        #expect(layout.rows[0] == [nil, nil, nil, "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"])
    }

    @Test func aMonthStartingOnMondayHasNoLeadingBlanks() throws {
        let date = try #require(BodybuildingWeeks.date(fromDayKey: "2027-02-10", calendar: Self.calendar))
        let layout = BodybuildingWeeks.monthLayout(containing: date, calendar: Self.calendar)
        #expect(layout.leadingBlanks == 0)
        #expect(layout.dayKeys.count == 28)
        #expect(layout.trailingBlanks == 0)
        #expect(layout.rows.count == 4)
    }
}

/// One calendar day built from a day record plus the inputs kept elsewhere.
struct BodybuildingDayTests {
    static let calendar = BodybuildingWeeksTests.calendar

    static func context(today: String = "2026-10-28", deloads: Set<String> = [], suggested: String? = nil) -> BodybuildingDayContext {
        BodybuildingDayContext(todayKey: today, deloadWeeks: deloads, suggestedWeek: suggested, calendar: calendar)
    }

    @Test func aTrainedDayNamesItsPlannedSplit() {
        let plan = PlannedWorkout(name: WorkoutSplit.legs.defaultPlanName, split: .legs, source: .user, notes: "", duration: 50)
        var day = FernletDay(date: "2026-10-21", workouts: [plan.completedWorkout], plannedWorkouts: [plan])
        day.sleep = SleepLog(hours: 8, quality: .good, note: "")
        day.healthContext = HealthDailyContext(activity: HealthActivitySummary(steps: 9_000))
        day.meals = [Meal(name: "Bowl", mealType: .lunch, macros: Macros(protein: 40, carbs: 60, fat: 15), quality: .good,
                          confidence: "", note: "", source: "manual")]
        day.journals = [JournalEntry(text: "", tag: .tired, date: Date(timeIntervalSince1970: 100), isQuickMood: true),
                        JournalEntry(text: "", tag: .bright, date: Date(timeIntervalSince1970: 200), isQuickMood: true)]
        let inputs = BodybuildingDayInputs(bathroomVisits: 3, freeMeal: true, weightKilograms: 81, careScore: 140)
        let built = BodybuildingDay(day: day, inputs: inputs, targets: Macros(protein: 150, carbs: 250, fat: 70),
                                    context: Self.context(deloads: ["2026-10-19"]))
        #expect(built.trained && built.workoutCount == 1)
        #expect(built.trainingName == "Legs")
        #expect(built.sleepHours == 8)
        #expect(built.steps == 9_000)
        #expect(built.macros == Macros(protein: 40, carbs: 60, fat: 15))
        #expect(built.feeling == .bright, "the day's last mood")
        #expect(built.bathroomVisits == 3 && built.freeMeal && built.weightKilograms == 81)
        #expect(built.careScore == 100, "clamped")
        #expect(built.isDeload && !built.isToday && !built.isFuture && !built.isSuggestedDeload)
    }

    @Test func aWorkoutWithoutASplitPlanKeepsItsOwnName() {
        let workout = Workout(name: "Arms and abs", type: .upper, exercises: "", rpe: nil, notes: "", duration: 40, intensity: .moderate)
        let day = FernletDay(date: "2026-10-27", workouts: [workout])
        #expect(BodybuildingDay(day: day, inputs: .empty, targets: nil, context: Self.context()).trainingName == "Arms and abs")
    }

    @Test func aRestDayHasNoTraining() {
        let built = BodybuildingDay(day: FernletDay(date: "2026-10-28"), inputs: .empty, targets: nil, context: Self.context())
        #expect(!built.trained && built.trainingName == nil)
        #expect(built.isToday)
        #expect(built.sleepHours == nil && built.steps == nil && !built.hasDayFelt)
    }

    @Test func daysToComeStayEmptyAndTheSuggestedWeekIsMarked() {
        let plan = PlannedWorkout(name: "Push", split: .push, source: .user, notes: "", duration: 50)
        let future = FernletDay(date: "2026-11-03", workouts: [plan.completedWorkout], plannedWorkouts: [plan])
        let built = BodybuildingDay(day: future, inputs: BodybuildingDayInputs(bathroomVisits: 2), targets: nil,
                                    context: Self.context(suggested: "2026-11-02"))
        #expect(built.isFuture && built.isSuggestedDeload)
        #expect(!built.trained && built.bathroomVisits == nil)
    }

    @Test func theBuilderFillsEveryKeyInOrder() {
        let keys = BodybuildingWeeks.weekDayKeys(weekStart: "2026-10-26", calendar: Self.calendar)
        let records = ["2026-10-27": FernletDay(date: "2026-10-27", workouts: [BodybuildingDeloadRuleTests.workout()])]
        let days = BodybuildingCalendarBuilder.days(
            for: keys, records: records, inputs: { $0 == "2026-10-26" ? BodybuildingDayInputs(bathroomVisits: 1) : .empty },
            targets: nil, context: Self.context())
        #expect(days.map(\.dateKey) == keys)
        #expect(days[0].bathroomVisits == 1 && !days[0].trained)
        #expect(days[1].trained)
        #expect(days[2].isToday)
        #expect(days[3...].allSatisfy(\.isFuture))
    }
}
