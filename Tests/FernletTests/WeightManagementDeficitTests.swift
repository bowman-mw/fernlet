import Foundation
import Testing
import FernletDomainModel

/// The Weight Management goal's deficit: 10% by default, user-adjustable, floors always.
///
/// Owner, 2026-09-23: "12% seem a tad bit agressive, need to research what a good starting place is".
/// The research and the options are in `Docs/Calorie-Deficit-Research-2026-09-23.md`. Owner,
/// 2026-09-24: "do 10% as a baseline, users can change this as afterwards". What ships: 10% below
/// estimated maintenance unless the user chooses 0–20% in 5% steps, never under 1,200 kcal (female)
/// / 1,500 kcal (male) or the estimated resting metabolic rate, and never ABOVE maintenance (a
/// maintenance already under the floor gets no deficit, not a surplus). The owner also chose NO
/// under-18 exception (2026-09-24): the same rule, floors included, for every age.
///
/// Every expectation reads through the public `targets(for:)` entry point, and the worked numbers
/// are the research note's table, so a change to the default or the floor moves a pinned number
/// here and in the note together.
struct WeightManagementDeficitTests {

    // MARK: - Fixtures

    private func settings(goal: GoalType, _ profile: UserNutritionProfile, deficit: Int? = nil) -> FernletSettings {
        var settings = FernletSettings()
        settings.selectedGoal = goal
        settings.userProfile = profile
        settings.weightManagementDeficitPercent = deficit
        return settings
    }

    private func calories(_ goal: GoalType, _ profile: UserNutritionProfile, deficit: Int? = nil) -> Int {
        NutritionTargetCalculator.targets(for: settings(goal: goal, profile, deficit: deficit)).calories
    }

    /// Mifflin–St Jeor, re-derived here rather than read from the calculator, so the RMR guard is
    /// checked against the textbook equation.
    private func restingMetabolicRate(_ profile: UserNutritionProfile) -> Double {
        let sexAdjustment = profile.sex == .male ? 5.0 : -161.0
        return 10 * profile.weightKilograms + 6.25 * profile.heightCentimeters - 5 * Double(profile.age) + sexAdjustment
    }

    /// The research note's worked profiles, with the target each should now get.
    private static let workedExamples: [(name: String, profile: UserNutritionProfile, target: Int)] = [
        ("app default, 10% applies", UserNutritionProfile(), 2_375),
        ("F 35y 150 lb light, 10% applies",
         UserNutritionProfile(age: 35, weightPounds: 150, heightInches: 64, sex: .female, activityLevel: .light), 1_675),
        ("F 65y 125 lb sedentary, female floor binds",
         UserNutritionProfile(age: 65, weightPounds: 125, heightInches: 61, sex: .female, activityLevel: .sedentary), 1_200),
        ("M 70y 130 lb sedentary, male floor binds",
         UserNutritionProfile(age: 70, weightPounds: 130, heightInches: 64, sex: .male, activityLevel: .sedentary), 1_500),
        ("M 25y 200 lb very active, 10% applies",
         UserNutritionProfile(age: 25, weightPounds: 200, heightInches: 72, sex: .male, activityLevel: .veryActive), 3_300)
    ]

    // MARK: - The pinned value

    @Test func theWorkedExamplesMatchTheResearchNote() {
        for example in Self.workedExamples {
            #expect(calories(.weightManagement, example.profile) == example.target,
                    "\(example.name): \(calories(.weightManagement, example.profile)) kcal, expected \(example.target)")
        }
    }

    @Test func theDefaultProfileRunsATenPercentDeficit() {
        let maintenance = calories(.wellness, UserNutritionProfile())
        let target = calories(.weightManagement, UserNutritionProfile())
        let cut = Double(maintenance - target) / Double(maintenance)
        // Both numbers are rounded to 25 kcal, so the ratio carries up to ~1% of rounding noise.
        #expect(abs(cut - 0.10) < 0.011, "the default profile's cut is \(cut), not ~10%")
    }

    // MARK: - The floor

    @Test func aDeficitNeverTakesAFemaleProfileBelow1200() {
        let small = UserNutritionProfile(age: 60, weightPounds: 130, heightInches: 62, sex: .female, activityLevel: .sedentary)
        #expect(calories(.weightManagement, small) >= 1_200, "12% put this profile at 1,175 kcal")
    }

    @Test func maintenanceUnderTheFloorMeansNoDeficitRatherThanASurplus() {
        let petite = UserNutritionProfile(age: 75, weightPounds: 110, heightInches: 59, sex: .female, activityLevel: .sedentary)
        let maintenance = calories(.wellness, petite)
        #expect(maintenance < 1_200, "fixture drifted: maintenance \(maintenance) is no longer under the floor")
        #expect(calories(.weightManagement, petite) == maintenance,
                "under the floor the goal must not cut (12% gave 950 kcal) and must not add")
    }

    @Test func theFloorIsTheSexFloorOrTheRestingRateWhicheverIsHigher() {
        let small = UserNutritionProfile(age: 70, weightPounds: 110, heightInches: 59, sex: .female, activityLevel: .sedentary)
        #expect(NutritionTargetCalculator.deficitFloorKilocalories(for: small) == 1_200)
        let large = UserNutritionProfile(age: 25, weightPounds: 300, heightInches: 76, sex: .male, activityLevel: .moderate)
        #expect(NutritionTargetCalculator.deficitFloorKilocalories(for: large) == restingMetabolicRate(large),
                "a large body's resting rate is above 1,500 kcal and must be the floor")
    }

    // MARK: - Invariants over a grid of bodies

    /// 5 ages × 5 weights × 4 heights × 2 sexes × 5 activity levels = 1,000 profiles.
    private static var grid: [UserNutritionProfile] {
        var profiles: [UserNutritionProfile] = []
        for age in [18, 30, 50, 70, 90] {
            for weight in [100.0, 130, 170, 220, 300] {
                for height in [58.0, 64, 70, 76] {
                    for sex in BiologicalSex.allCases {
                        for activity in ActivityLevel.allCases {
                            profiles.append(UserNutritionProfile(age: age, weightPounds: weight, heightInches: height,
                                                                 sex: sex, activityLevel: activity))
                        }
                    }
                }
            }
        }
        return profiles
    }

    @Test func weightManagementIsNeverAboveMaintenanceNorBelowTheFloor() {
        for profile in Self.grid {
            let maintenance = calories(.wellness, profile)
            let target = calories(.weightManagement, profile)
            let sexFloor = profile.sex == .male ? 1_500 : 1_200
            #expect(target <= maintenance, "\(profile): \(target) is above maintenance \(maintenance)")
            #expect(target >= min(maintenance, sexFloor), "\(profile): \(target) is under the floor")
            // Rounding to 25 kcal may land up to 12.5 kcal either side of the unrounded value.
            #expect(Double(target) >= restingMetabolicRate(profile) - 12.5, "\(profile): \(target) is under RMR")
        }
    }

    @Test func theCutIsNeverMoreThanTenPercentOfMaintenance() {
        for profile in Self.grid {
            let maintenance = calories(.wellness, profile)
            guard maintenance > 0 else { continue }
            let cut = Double(maintenance - calories(.weightManagement, profile))
            // Both targets are rounded to 25 kcal, in either direction, so the rounded cut can exceed
            // 10% of the rounded maintenance by at most 25 kcal plus 10% of maintenance's own 12.5.
            #expect(cut <= 0.10 * Double(maintenance) + 26.25, "\(profile): the cut is \(cut) kcal of \(maintenance)")
        }
    }

    // MARK: - The card copy stays honest

    @Test func theGoalCardStatesTheCeilingFromTheConstant() {
        let summary = GoalType.weightManagement.nutritionSummary
        #expect(summary.contains("up to 10%"), "the card says \"\(summary)\"")
        #expect(summary.localizedCaseInsensitiveContains("gentle"))
        #expect(!summary.localizedCaseInsensitiveContains("lose"), "no rate or weight-loss promise on the card")
    }

    @Test func otherGoalsAreUntouched() {
        let profile = UserNutritionProfile()
        let maintenance = calories(.wellness, profile)
        #expect(calories(.mentalHealth, profile) == maintenance)
        #expect(calories(.exploring, profile) == maintenance)
        #expect(calories(.strength, profile) > maintenance)
        #expect(calories(.sportsPrep, profile) > maintenance)
    }

    // MARK: - User-adjustable (2026-09-24)

    @Test func theDefaultIsTenPercentUntilTheUserChooses() {
        #expect(NutritionTargetCalculator.defaultWeightManagementDeficitPercent == 10)
        #expect(FernletSettings().weightManagementDeficitPercent == nil, "a fresh install has made no choice")
        #expect(NutritionTargetCalculator.weightManagementDeficitPercent(for: FernletSettings()) == 10)
        let profile = UserNutritionProfile()
        #expect(calories(.weightManagement, profile, deficit: 10) == calories(.weightManagement, profile),
                "an explicit 10% must be the same plan as no choice")
    }

    @Test func theChoicesAreNoneToTwentyPercentInFivePercentSteps() {
        #expect(NutritionTargetCalculator.weightManagementDeficitPercentOptions == [0, 5, 10, 15, 20])
        #expect(NutritionTargetCalculator.weightManagementDeficitPercentRange == 0...20)
        #expect(NutritionTargetCalculator.weightManagementDeficitPercentStep == 5)
    }

    @Test func eachChoiceMovesTheDefaultProfilesTarget() {
        // Worked by hand from Mifflin–St Jeor × 1.55 (maintenance ≈ 2,644 kcal), rounded to 25 kcal.
        let expected: [Int: Int] = [0: 2_650, 5: 2_500, 10: 2_375, 15: 2_250, 20: 2_125]
        let profile = UserNutritionProfile()
        for (percent, target) in expected {
            #expect(calories(.weightManagement, profile, deficit: percent) == target,
                    "\(percent)%: \(calories(.weightManagement, profile, deficit: percent)) kcal, expected \(target)")
        }
        #expect(calories(.weightManagement, profile, deficit: 0) == calories(.wellness, profile),
                "0% is maintenance")
    }

    @Test func theFloorsStillBindAtTheLargestChoice() {
        // A small, older, sedentary body: 20% would be ~1,007 kcal; the female floor holds it at 1,200.
        let small = UserNutritionProfile(age: 65, weightPounds: 125, heightInches: 61, sex: .female, activityLevel: .sedentary)
        #expect(calories(.weightManagement, small, deficit: 20) == 1_200)
        // A large sedentary body: 20% (0.8 × 1.2 = 0.96 × RMR) dips under its resting rate, so the RMR
        // half of the floor binds. It cannot bind at 10% or 15%.
        let large = UserNutritionProfile(age: 25, weightPounds: 300, heightInches: 76, sex: .male, activityLevel: .sedentary)
        let rmr = restingMetabolicRate(large)
        #expect(abs(Double(calories(.weightManagement, large, deficit: 20)) - rmr) <= 12.5,
                "the resting-rate floor did not hold at 20% (RMR \(rmr))")
        #expect(Double(calories(.weightManagement, large, deficit: 15)) > rmr)
        // Under the floor already: no choice can cut, and none may add.
        let petite = UserNutritionProfile(age: 75, weightPounds: 110, heightInches: 59, sex: .female, activityLevel: .sedentary)
        for percent in NutritionTargetCalculator.weightManagementDeficitPercentOptions {
            #expect(calories(.weightManagement, petite, deficit: percent) == calories(.wellness, petite))
        }
    }

    @Test func everyChoiceStaysInsideTheFloorsAndItsOwnCeilingOverTheGrid() {
        for percent in NutritionTargetCalculator.weightManagementDeficitPercentOptions {
            for profile in Self.grid {
                let maintenance = calories(.wellness, profile)
                let target = calories(.weightManagement, profile, deficit: percent)
                let sexFloor = profile.sex == .male ? 1_500 : 1_200
                #expect(target <= maintenance, "\(percent)% \(profile): \(target) is above maintenance \(maintenance)")
                #expect(target >= min(maintenance, sexFloor), "\(percent)% \(profile): \(target) is under the floor")
                #expect(Double(target) >= restingMetabolicRate(profile) - 12.5, "\(percent)% \(profile): \(target) is under RMR")
                // The same 25-kcal rounding allowance as `theCutIsNeverMoreThanTenPercentOfMaintenance`.
                let cut = Double(maintenance - target)
                #expect(cut <= Double(percent) / 100 * Double(maintenance) + 26.25,
                        "\(percent)% \(profile): the cut is \(cut) kcal of \(maintenance)")
            }
        }
    }

    @Test func theRangeAndStepAreEnforcedWhateverIsStored() {
        let normalize = NutritionTargetCalculator.normalizedWeightManagementDeficitPercent
        #expect(normalize(-5) == 0)
        #expect(normalize(Int.min) == 0)
        #expect(normalize(0) == 0)
        #expect(normalize(7) == 5, "between two steps rounds DOWN, to the gentler cut")
        #expect(normalize(13) == 10)
        #expect(normalize(19) == 15)
        #expect(normalize(20) == 20)
        #expect(normalize(35) == 20)
        #expect(normalize(Int.max) == 20)
        // A value that bypassed the setter (a foreign blob, a future bug) still cannot reach the math.
        let profile = UserNutritionProfile()
        #expect(calories(.weightManagement, profile, deficit: 90) == calories(.weightManagement, profile, deficit: 20))
        #expect(calories(.weightManagement, profile, deficit: -10) == calories(.wellness, profile))
    }

    @Test func choosingStoresTheNormalizedValueAndTheDefaultAsNoChoice() {
        var settings = FernletSettings()
        settings.setWeightManagementDeficitPercent(15)
        #expect(settings.weightManagementDeficitPercent == 15)
        settings.setWeightManagementDeficitPercent(10)
        #expect(settings.weightManagementDeficitPercent == nil, "the default is stored as no choice")
        settings.setWeightManagementDeficitPercent(0)
        #expect(settings.weightManagementDeficitPercent == 0, "none is a real choice, not the default")
        settings.setWeightManagementDeficitPercent(50)
        #expect(settings.weightManagementDeficitPercent == 20)
        settings.setWeightManagementDeficitPercent(-3)
        #expect(settings.weightManagementDeficitPercent == 0)
    }

    @Test func theChoiceSurvivesEncodeAndDecode() throws {
        var settings = FernletSettings()
        settings.setWeightManagementDeficitPercent(15)
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.weightManagementDeficitPercent == 15)
        #expect(decoded.parkedUnknownKeys.isEmpty, "a known key must never be parked")
        // Absent from the blob when the user made no choice, so an untouched blob keeps its old shape.
        let fresh = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FernletSettings())) as? [String: Any]
        #expect(fresh?["weightManagementDeficitPercent"] == nil)
    }

    @Test func blobsFromBeforeTheSettingOrFromElsewhereDecodeSafely() throws {
        func decode(_ json: String) throws -> FernletSettings {
            try JSONDecoder().decode(FernletSettings.self, from: Data(json.utf8))
        }
        #expect(try decode("{}").weightManagementDeficitPercent == nil, "a pre-feature blob keeps the default")
        #expect(try decode(#"{"weightManagementDeficitPercent": 20}"#).weightManagementDeficitPercent == 20)
        #expect(try decode(#"{"weightManagementDeficitPercent": 90}"#).weightManagementDeficitPercent == 20)
        #expect(try decode(#"{"weightManagementDeficitPercent": 13}"#).weightManagementDeficitPercent == 10)
        #expect(try decode(#"{"weightManagementDeficitPercent": -4}"#).weightManagementDeficitPercent == 0)
    }

    @Test func aPinnedCalorieTargetOutranksTheDeficit() {
        var pinned = settings(goal: .weightManagement, UserNutritionProfile(), deficit: 20)
        pinned.calorieTargetOverride = 2_000
        #expect(NutritionTargetCalculator.targets(for: pinned).calories == 2_000)
    }

    @Test func noOtherGoalReadsTheDeficit() {
        let profile = UserNutritionProfile()
        for goal in GoalType.allCases where goal != .weightManagement {
            #expect(calories(goal, profile, deficit: 20) == calories(goal, profile), "\(goal.rawValue) read the deficit")
        }
    }

    /// Owner, 2026-09-24: no under-18 exception ("No, same for every age"). Pinned so that adding one
    /// is a deliberate decision, not a drive-by edit: a teenage profile gets the same adjustable
    /// deficit, and the same floors.
    @Test func underEighteensGetTheSameRuleAndTheSameFloors() {
        let teen = UserNutritionProfile(age: 16, weightPounds: 130, heightInches: 64, sex: .female, activityLevel: .light)
        #expect(calories(.weightManagement, teen) == 1_700, "the 10% default applies at 16")
        #expect(calories(.weightManagement, teen, deficit: 0) == calories(.wellness, teen))
        for age in 13...17 {
            let profile = UserNutritionProfile(age: age, weightPounds: 110, heightInches: 60, sex: .female, activityLevel: .sedentary)
            let target = calories(.weightManagement, profile, deficit: 20)
            #expect(target >= min(calories(.wellness, profile), 1_200), "age \(age): \(target) is under the floor")
        }
    }

    // MARK: - The card copy tells the truth for every choice

    private func card(_ percent: Int) -> String {
        GoalType.weightManagement.nutritionSummary(weightManagementDeficitPercent: percent)
    }

    @Test func theGoalCardStatesTheUsersOwnChoice() {
        #expect(card(10) == GoalType.weightManagement.nutritionSummary, "the default card is the plain property")
        #expect(!card(10).contains("your choice"))
        #expect(card(5).contains("up to 5%") && card(5).contains("your choice") && card(5).contains("gentle"))
        for larger in [15, 20] {
            #expect(card(larger).contains("up to \(larger)%") && card(larger).contains("your choice"), "\(card(larger))")
            #expect(!card(larger).localizedCaseInsensitiveContains("gentle"), "a larger-than-default cut is not called gentle")
        }
        #expect(card(0).contains("Maintenance") && card(0).contains("no deficit"), "\(card(0))")
        #expect(!card(0).contains("up to"))
        #expect(card(35).contains("up to 20%"), "the card must state the number the math will use")
        for percent in NutritionTargetCalculator.weightManagementDeficitPercentOptions {
            #expect(!card(percent).localizedCaseInsensitiveContains("lose"), "no rate or weight-loss promise on the card")
            #expect(card(percent).contains("higher protein"))
        }
    }

    @Test func otherGoalCardsIgnoreTheDeficit() {
        for goal in GoalType.allCases where goal != .weightManagement {
            #expect(goal.nutritionSummary(weightManagementDeficitPercent: 20) == goal.nutritionSummary)
        }
    }
}
