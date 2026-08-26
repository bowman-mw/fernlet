import FernletDomainModel
import FernletExchange
import Foundation
import Testing
@testable import Fernlet

/// Pins the containing app's delete-everything seam, not just the portable inbox files in
/// isolation. Both records must be gone before a post-wipe deep link can reach a review sheet.
@MainActor
struct MessagesInboxCoordinatorTests {
    @Test func coordinatorClearsRecipeAndWorkoutReviewRecordsTogether() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recipes = FernletMessagesInboxStore(directory: directory)
        let workouts = FernletMessagesWorkoutInboxStore(directory: directory)
        let recipe = try recipes.enqueue(recipePacket())
        let workout = try workouts.enqueue(workoutPacket(), suggestedStartDayKey: "2026-09-02")
        let coordinator = FernletMessagesRecipeInboxCoordinator(directory: directory)

        #expect(coordinator.clear())
        #expect(try recipes.record(id: recipe.id) == nil)
        #expect(try workouts.record(id: workout.id) == nil)
    }

    private func recipePacket() throws -> RecipeExchangePacket {
        let foodID = UUID()
        let food = FoodItem(id: foodID, name: "Oats", servingSize: 40, servingUnit: "g",
                            macros: Macros(protein: 5, carbs: 27, fat: 3), micronutrients: Micronutrients(),
                            category: "test", source: .manual, tags: ["recipe"])
        let recipe = RecipeDefinition(name: "Wipe oats", servings: 1,
                                      ingredients: [RecipeIngredient(foodItemId: foodID, quantity: 40, unit: "g")],
                                      source: "test", createdAt: .now, updatedAt: .now)
        return try RecipeExchangePacket(recipe: recipe, foodItems: [food], includesNotes: false)
    }

    private func workoutPacket() throws -> WorkoutPlanExchangePacket {
        let plan = CoachPlan(title: "Wipe workout", coachDisplayName: "Fernlet",
                             days: [CoachPlanDay(dayIndex: 1, title: "Day 1", sessions: [CoachSession(title: "Move")])])
        return try WorkoutPlanExchangePacket(plan: plan)
    }
}
