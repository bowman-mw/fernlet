import Foundation
import Testing
import FernletDomainModel
import FernletPersistence
import CloudKitSync
@testable import Fernlet

/// The user-adjustable Weight Management deficit, from the app's side (2026-09-24).
///
/// Owner: "do 10% as a baseline, users can change this as afterwards". The math, range and floors are
/// pinned in `WeightManagementDeficitTests`. This suite pins what the user touches: the Nutrition
/// targets row (``WeightManagementDeficitControl``) shows only for Weight Management, reads the value
/// in effect, and says when a pinned calorie target outranks it. The store setter saves the choice
/// durably. The goal card and the targets card read the same number, and Settings search finds the row.
@MainActor
struct WeightManagementDeficitSettingTests {

    private func settings(goal: GoalType, deficit: Int? = nil, pinnedCalories: Int? = nil) -> FernletSettings {
        var settings = FernletSettings()
        settings.selectedGoal = goal
        settings.weightManagementDeficitPercent = deficit
        settings.calorieTargetOverride = pinnedCalories
        return settings
    }

    // MARK: - The row's rules

    @Test func theRowShowsOnlyForWeightManagement() {
        for goal in GoalType.allCases {
            let control = WeightManagementDeficitControl(settings: settings(goal: goal))
            #expect(control.isShown == (goal == .weightManagement), "\(goal.rawValue)")
        }
    }

    @Test func theRowReadsTheDefaultUntilTheUserChooses() {
        let untouched = WeightManagementDeficitControl(settings: settings(goal: .weightManagement))
        #expect(untouched.percent == 10)
        #expect(untouched.isDefault)
        #expect(untouched.isInEffect)
        let chosen = WeightManagementDeficitControl(settings: settings(goal: .weightManagement, deficit: 15))
        #expect(chosen.percent == 15)
        #expect(!chosen.isDefault)
        // Whatever reached the blob, the row shows the number the math uses.
        let foreign = WeightManagementDeficitControl(settings: settings(goal: .weightManagement, deficit: 90))
        #expect(foreign.percent == 20)
    }

    @Test func aPinnedCalorieTargetTakesTheRowOutOfEffect() {
        let pinned = WeightManagementDeficitControl(settings: settings(goal: .weightManagement, deficit: 5, pinnedCalories: 1_900))
        #expect(pinned.isShown, "the row stays, disabled, so the user can see why their choice does nothing")
        #expect(!pinned.isInEffect)
    }

    // MARK: - Through the store

    @Test func choosingThroughTheStoreMovesTheTargetAndSurvivesReload() {
        let (store, repository, _) = makeTestStoreWithRepositories()
        store.setSelectedGoal(.weightManagement)
        let atDefault = store.nutritionTargets.calories

        store.setWeightManagementDeficitPercent(20)
        #expect(store.settings.weightManagementDeficitPercent == 20)
        #expect(store.nutritionTargets.calories < atDefault, "a larger deficit must lower the calorie target")

        // `flushPendingSnapshotSave()` writes only when a save was scheduled, so a setter that forgot to
        // schedule one would reload the default here.
        store.flushPendingSnapshotSave()
        let reloaded = repository.loadSnapshot(todayKey: store.todayKey).settings
        #expect(reloaded.weightManagementDeficitPercent == 20)

        store.setWeightManagementDeficitPercent(10)
        #expect(store.settings.weightManagementDeficitPercent == nil, "going back to the default clears the choice")
        #expect(store.nutritionTargets.calories == atDefault)
    }

    @Test func theStoreEnforcesTheRange() {
        let store = makeTestStore()
        store.setWeightManagementDeficitPercent(45)
        #expect(store.settings.weightManagementDeficitPercent == 20)
        store.setWeightManagementDeficitPercent(-5)
        #expect(store.settings.weightManagementDeficitPercent == 0)
    }

    // MARK: - The goal card and the targets card read one number

    @Test func theGoalCardReadsTheStoresChoice() {
        let store = makeTestStore()
        store.setSelectedGoal(.weightManagement)
        store.setWeightManagementDeficitPercent(15)
        let percent = NutritionTargetCalculator.weightManagementDeficitPercent(for: store.settings)
        let card = GoalType.weightManagement.nutritionSummary(weightManagementDeficitPercent: percent)
        #expect(card.contains("up to 15%"), "the card says \"\(card)\"")
        #expect(WeightManagementDeficitControl(settings: store.settings).percent == percent)
    }

    /// A source pin, because dropping the argument still compiles (it defaults to 10%) and would leave
    /// a customized user's card claiming the default.
    @Test func settingsPassesTheValueInEffectToTheGoalCards() throws {
        let sheet = try RepoRoot.source("App/Fernlet/SettingsSheet.swift")
        #expect(sheet.contains("weightManagementDeficitPercent: NutritionTargetCalculator.weightManagementDeficitPercent(for: store.settings)"),
                "Settings no longer hands the goal cards the user's deficit")
        let editor = try RepoRoot.source("App/Fernlet/NutritionTargetsEditor.swift")
        #expect(editor.contains("WeightManagementDeficitRow(store: store)"),
                "the Nutrition targets card no longer carries the deficit row")
    }

    // MARK: - The targets card's footnote stays true at every choice

    /// Seen in the simulator: at 20% the default profile's carbs are 255.5 g, shown as 256 g, so the
    /// four macros sum to 2,127 kcal against 2,125. That is rounding, and the card must not blame
    /// the carb minimum for it. A real carb-floor case still gets the note.
    @Test func carbRoundingIsNotReportedAsTheCarbMinimum() {
        var twentyPercent = settings(goal: .weightManagement, deficit: 20)
        twentyPercent.userProfile = UserNutritionProfile()
        let targets = NutritionTargetCalculator.targets(for: twentyPercent)
        #expect(targets.calories == 2_125)
        #expect(targets.macroTotals.calories - targets.calories <= NutritionTargetsEditor.carbRoundingAllowanceKilocalories)
        #expect(!NutritionTargetsEditor.totalsExceedCalories(targets))

        var floorBinds = FernletSettings()
        floorBinds.calorieTargetOverride = 2_000
        floorBinds.proteinTargetOverride = 250
        floorBinds.fatTargetOverride = 90
        #expect(NutritionTargetsEditor.totalsExceedCalories(NutritionTargetCalculator.targets(for: floorBinds)),
                "protein and fat this high leave carbs on their floor, and the note must say so")
    }

    // MARK: - Findable

    @Test func settingsSearchFindsTheRow() {
        let results = SettingsSearchIndex.results(for: "deficit")
        #expect(results.contains { $0.title == "Calorie deficit" })
        #expect(results.allSatisfy { $0.route == .goalNutrition })
    }
}
