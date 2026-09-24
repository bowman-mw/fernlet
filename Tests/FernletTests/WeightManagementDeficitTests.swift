import Foundation
import Testing
import FernletDomainModel

/// The Weight Management goal's gentle starting deficit (2026-09-23).
///
/// Owner: "12% seem a tad bit agressive, need to research what a good starting place is". The
/// research and the options are in `Docs/Calorie-Deficit-Research-2026-09-23.md` — OWNER SIGN-OFF
/// NEEDED on the chosen value. What ships: 10% below estimated maintenance, never under 1,200 kcal
/// (female) / 1,500 kcal (male) or the estimated resting metabolic rate, and never ABOVE maintenance
/// (a maintenance already under the floor gets no deficit, not a surplus).
///
/// Every expectation reads through the public `targets(for:)` entry point, and the worked numbers
/// are the research note's table, so a change to the constant or the floor moves a pinned number
/// here and in the note together.
struct WeightManagementDeficitTests {

    // MARK: - Fixtures

    private func settings(goal: GoalType, _ profile: UserNutritionProfile) -> FernletSettings {
        var settings = FernletSettings()
        settings.selectedGoal = goal
        settings.userProfile = profile
        return settings
    }

    private func calories(_ goal: GoalType, _ profile: UserNutritionProfile) -> Int {
        NutritionTargetCalculator.targets(for: settings(goal: goal, profile)).calories
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
}
