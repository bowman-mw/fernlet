import Foundation
import Testing
import FernletDomainModel

/// Macro target overrides (#17): calories, protein and fat can be pinned on `FernletSettings`; carbs
/// stays the residual, so pinning any of the three re-solves the plan and the four numbers always
/// agree with the calorie total. These pin the derivation contract and the settings round-trip
/// (overrides are `nil` on every blob written before the feature, i.e. derive).
struct NutritionTargetOverrideTests {

    /// The exact residual the calculator uses, recomputed here so the carbs assertion survives the
    /// floor logic (`max(remaining, 30% of calories)` then `max(_, 50)`) rather than guessing a number.
    private func expectedCarbs(calories: Int, protein: Int, fat: Int) -> Int {
        let remaining = max(calories - protein * 4 - fat * 9, Int(Double(calories) * 0.30))
        return max(Int((Double(remaining) / 4).rounded()), 50)
    }

    // MARK: - Derivation

    @Test func noOverridesProduceAWholeDerivedPlan() {
        let settings = FernletSettings()
        let plan = NutritionTargetCalculator.targets(for: settings)
        #expect(settings.calorieTargetOverride == nil)
        #expect(plan.calories > 0 && plan.protein > 0 && plan.fat > 0 && plan.carbs > 0)
    }

    @Test func calorieOverridePinsCaloriesAndRebalancesTheRest() {
        var settings = FernletSettings()
        let base = NutritionTargetCalculator.targets(for: settings)
        settings.calorieTargetOverride = base.calories + 600
        let plan = NutritionTargetCalculator.targets(for: settings)
        #expect(plan.calories == base.calories + 600)
        #expect(plan.protein == base.protein)          // protein not pinned → unchanged
        #expect(plan.carbs != base.carbs)              // residual re-solved against new calories
        #expect(plan.carbs == expectedCarbs(calories: plan.calories, protein: plan.protein, fat: plan.fat))
    }

    @Test func proteinOverridePinsProteinAndLeavesCaloriesAlone() {
        var settings = FernletSettings()
        let base = NutritionTargetCalculator.targets(for: settings)
        settings.proteinTargetOverride = base.protein + 80
        let plan = NutritionTargetCalculator.targets(for: settings)
        #expect(plan.protein == base.protein + 80)
        #expect(plan.calories == base.calories)        // calories not pinned → unchanged
        #expect(plan.fat == base.fat)                  // fat derives from (unchanged) calories
        #expect(plan.carbs == expectedCarbs(calories: plan.calories, protein: plan.protein, fat: plan.fat))
    }

    @Test func fatOverridePinsFat() {
        var settings = FernletSettings()
        let base = NutritionTargetCalculator.targets(for: settings)
        settings.fatTargetOverride = base.fat + 25
        let plan = NutritionTargetCalculator.targets(for: settings)
        #expect(plan.fat == base.fat + 25)
        #expect(plan.calories == base.calories)
        #expect(plan.protein == base.protein)
        #expect(plan.carbs == expectedCarbs(calories: plan.calories, protein: plan.protein, fat: plan.fat))
    }

    @Test func moreProteinMeansFewerCarbsAtFixedCalories() {
        // Pin calories + fat so only protein moves; both protein values keep the residual above the
        // 30%-of-calories floor, so the rebalance is a strict decrease.
        var settings = FernletSettings()
        settings.calorieTargetOverride = 2_500
        settings.fatTargetOverride = 70
        settings.proteinTargetOverride = 120
        let lowProtein = NutritionTargetCalculator.targets(for: settings)
        settings.proteinTargetOverride = 200
        let highProtein = NutritionTargetCalculator.targets(for: settings)
        #expect(lowProtein.calories == highProtein.calories)
        #expect(highProtein.carbs < lowProtein.carbs)
    }

    @Test func allThreePinnedGiveExactlyThoseNumbersWithResidualCarbs() {
        var settings = FernletSettings()
        settings.calorieTargetOverride = 2_200
        settings.proteinTargetOverride = 190
        settings.fatTargetOverride = 70
        let plan = NutritionTargetCalculator.targets(for: settings)
        #expect(plan.calories == 2_200)
        #expect(plan.protein == 190)
        #expect(plan.fat == 70)
        #expect(plan.carbs == expectedCarbs(calories: 2_200, protein: 190, fat: 70))
    }

    @Test func clearingAnOverrideReturnsToTheDerivedPlan() {
        var settings = FernletSettings()
        let base = NutritionTargetCalculator.targets(for: settings)
        settings.proteinTargetOverride = 999
        settings.proteinTargetOverride = nil
        #expect(NutritionTargetCalculator.targets(for: settings) == base)
    }

    // MARK: - Persistence

    @Test func overridesSurviveEncodeAndDecode() throws {
        var settings = FernletSettings()
        settings.calorieTargetOverride = 2_100
        settings.proteinTargetOverride = 175
        settings.fatTargetOverride = 65
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: data)
        #expect(decoded.calorieTargetOverride == 2_100)
        #expect(decoded.proteinTargetOverride == 175)
        #expect(decoded.fatTargetOverride == 65)
    }

    @Test func aSettingsBlobFromBeforeOverridesDecodesAsDerived() throws {
        // No override keys (every pre-feature blob) ⇒ nil ⇒ derive. `{}` exercises the absent-key path.
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: Data("{}".utf8))
        #expect(decoded.calorieTargetOverride == nil)
        #expect(decoded.proteinTargetOverride == nil)
        #expect(decoded.fatTargetOverride == nil)
    }
}
