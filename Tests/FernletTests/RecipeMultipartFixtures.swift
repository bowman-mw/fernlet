import Foundation
import FernletDomainModel

/// The canonical multipart recipe for tests (owner decision 2026-09-24: "Think like a salad recipe with
/// a homemade dressing. You make the dressing seperatly then assemble the salad").
///
/// A garden salad in two parts. **Lemon-dijon dressing** comes first: 4 ingredients, 2 steps. Then
/// **Salad**: 5 ingredients, 3 steps, the first with an 8-minute timer. Olive oil appears in BOTH parts
/// (3 tbsp in the dressing, 1 tbsp for the croutons), so grocery aggregation must merge it into 4 tbsp.
/// Every id and date is fixed, so encodings are byte-stable and can be pinned as goldens.
///
/// Whole-recipe macros: P12 C56 F58 (dressing P0 C8 F42, salad P12 C48 F16), 4 servings.
///
/// Reused by W2-messages-v2's envelope tests: `RecipeMultipartFixtures.saladWithHomemadeDressing()`
/// for the recipe and its foods, `saladPayload()` for the wire payload, and `saladPayloadGoldenJSON`
/// for its exact canonical (`.sortedKeys`) bytes.
enum RecipeMultipartFixtures {
    /// The fixture recipe plus the catalog foods its ingredients are bound to.
    struct Salad {
        let recipe: RecipeDefinition
        let foodItems: [FoodItem]
    }

    static let recipeName = "Garden salad with lemon-dijon dressing"
    static let dressingName = "Lemon-dijon dressing"
    static let saladName = "Salad"
    static let createdAt = Date(timeIntervalSince1970: 1_790_000_000)

    /// A deterministic UUID whose last byte is `last`, rendered "00000000-0000-0000-0000-0000000000XX".
    static func fixedID(_ last: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, last))
    }

    /// The recipe as the multipart editor would have saved it: flat rows in part order, plus the
    /// two-part partition over them.
    static func saladWithHomemadeDressing() -> Salad {
        let foods = foodItems()
        let dressingIngredients = [
            RecipeIngredient(id: fixedID(0x11), foodItemId: foods.oliveOil.id, quantity: 3, unit: "tbsp"),
            RecipeIngredient(id: fixedID(0x12), foodItemId: foods.lemonJuice.id, quantity: 2, unit: "tbsp"),
            RecipeIngredient(id: fixedID(0x13), foodItemId: foods.mustard.id, quantity: 1, unit: "tsp"),
            RecipeIngredient(id: fixedID(0x14), foodItemId: foods.honey.id, quantity: 1, unit: "tsp")
        ]
        let saladIngredients = [
            RecipeIngredient(id: fixedID(0x21), foodItemId: foods.romaine.id, quantity: 4, unit: "cup"),
            RecipeIngredient(id: fixedID(0x22), foodItemId: foods.tomatoes.id, quantity: 1, unit: "cup"),
            RecipeIngredient(id: fixedID(0x23), foodItemId: foods.cucumber.id, quantity: 1, unit: "cup"),
            RecipeIngredient(id: fixedID(0x24), foodItemId: foods.bread.id, quantity: 2, unit: "cup"),
            RecipeIngredient(id: fixedID(0x25), foodItemId: foods.oliveOil.id, quantity: 1, unit: "tbsp")
        ]
        let recipe = RecipeDefinition(
            id: fixedID(0x01),
            name: recipeName,
            servings: 4,
            ingredients: dressingIngredients + saladIngredients,
            notes: "Keep the dressing in the fridge for up to a week.",
            source: "manual",
            createdAt: createdAt,
            updatedAt: createdAt,
            steps: dressingSteps + saladSteps,
            components: [
                RecipeComponent(id: fixedID(0x0D), name: dressingName,
                                ingredientIDs: dressingIngredients.map(\.id), stepIDs: dressingSteps.map(\.id)),
                RecipeComponent(id: fixedID(0x0E), name: saladName,
                                ingredientIDs: saladIngredients.map(\.id), stepIDs: saladSteps.map(\.id))
            ]
        )
        return Salad(recipe: recipe, foodItems: foods.all)
    }

    static let dressingSteps = [
        RecipeStep(id: fixedID(0xD1), text: "Whisk the lemon juice, mustard and honey."),
        RecipeStep(id: fixedID(0xD2), text: "Stream in the olive oil while whisking until it thickens.")
    ]

    static let saladSteps = [
        RecipeStep(id: fixedID(0xE1), text: "Toss the bread cubes with the olive oil and toast until golden.",
                   durationSeconds: 480),
        RecipeStep(id: fixedID(0xE2), text: "Chop the romaine, halve the tomatoes and slice the cucumber."),
        RecipeStep(id: fixedID(0xE3), text: "Toss the salad with the dressing just before serving.")
    ]

    /// The multipart wire payload for the fixture: what the paste text and the mesh `.local` arm carry.
    static func saladPayload() -> SharedRecipePayload {
        let salad = saladWithHomemadeDressing()
        return SharedRecipePayload.assembled(
            name: salad.recipe.name, servings: salad.recipe.servings, notes: salad.recipe.notes,
            parts: [
                SharedRecipeComponentContent(name: dressingName, ingredients: [
                    wireIngredient("Olive oil", 3, "tbsp", fat: 42),
                    wireIngredient("Lemon juice", 2, "tbsp", carbs: 2),
                    wireIngredient("Dijon mustard", 1, "tsp"),
                    wireIngredient("Honey", 1, "tsp", carbs: 6)
                ], steps: dressingSteps),
                SharedRecipeComponentContent(name: saladName, ingredients: [
                    wireIngredient("Romaine lettuce", 4, "cup", protein: 4, carbs: 8),
                    wireIngredient("Cherry tomatoes", 1, "cup", protein: 1, carbs: 6),
                    wireIngredient("Cucumber", 1, "cup", protein: 1, carbs: 4),
                    wireIngredient("Bread cubes", 2, "cup", protein: 6, carbs: 30, fat: 2),
                    wireIngredient("Olive oil", 1, "tbsp", fat: 14)
                ], steps: saladSteps)
            ]
        )
    }

    /// The fixture payload's exact canonical encoding (`JSONEncoder` with `.sortedKeys`, as the share
    /// text embeds it): the published schema, pinned byte for byte.
    static let saladPayloadGoldenJSON = """
    {"components":[{"ingredientCount":4,"name":"Lemon-dijon dressing","stepCount":2},\
    {"ingredientCount":5,"name":"Salad","stepCount":3}],"format":"fernlet.recipe","ingredients":[\
    {"carbs":0,"fat":42,"name":"Olive oil","protein":0,"quantity":3,"unit":"tbsp"},\
    {"carbs":2,"fat":0,"name":"Lemon juice","protein":0,"quantity":2,"unit":"tbsp"},\
    {"carbs":0,"fat":0,"name":"Dijon mustard","protein":0,"quantity":1,"unit":"tsp"},\
    {"carbs":6,"fat":0,"name":"Honey","protein":0,"quantity":1,"unit":"tsp"},\
    {"carbs":8,"fat":0,"name":"Romaine lettuce","protein":4,"quantity":4,"unit":"cup"},\
    {"carbs":6,"fat":0,"name":"Cherry tomatoes","protein":1,"quantity":1,"unit":"cup"},\
    {"carbs":4,"fat":0,"name":"Cucumber","protein":1,"quantity":1,"unit":"cup"},\
    {"carbs":30,"fat":2,"name":"Bread cubes","protein":6,"quantity":2,"unit":"cup"},\
    {"carbs":0,"fat":14,"name":"Olive oil","protein":0,"quantity":1,"unit":"tbsp"}],\
    "name":"Garden salad with lemon-dijon dressing","notes":"Keep the dressing in the fridge for up to a week.",\
    "servings":4,"steps":[\
    {"id":"00000000-0000-0000-0000-0000000000D1","text":"Lemon-dijon dressing: Whisk the lemon juice, mustard and honey."},\
    {"id":"00000000-0000-0000-0000-0000000000D2","text":"Lemon-dijon dressing: Stream in the olive oil while whisking until it thickens."},\
    {"durationSeconds":480,"id":"00000000-0000-0000-0000-0000000000E1","text":"Salad: Toss the bread cubes with the olive oil and toast until golden."},\
    {"id":"00000000-0000-0000-0000-0000000000E2","text":"Salad: Chop the romaine, halve the tomatoes and slice the cucumber."},\
    {"id":"00000000-0000-0000-0000-0000000000E3","text":"Salad: Toss the salad with the dressing just before serving."}],\
    "version":1}
    """

    private static func wireIngredient(
        _ name: String, _ quantity: Double, _ unit: String, protein: Int = 0, carbs: Int = 0, fat: Int = 0
    ) -> SharedRecipeIngredient {
        SharedRecipeIngredient(name: name, quantity: quantity, unit: unit, protein: protein, carbs: carbs, fat: fat)
    }

    /// The fixture's catalog foods, one serving of each in the unit its ingredient is measured in.
    private struct Foods {
        let oliveOil, lemonJuice, mustard, honey, romaine, tomatoes, cucumber, bread: FoodItem
        var all: [FoodItem] { [oliveOil, lemonJuice, mustard, honey, romaine, tomatoes, cucumber, bread] }
    }

    private static func foodItems() -> Foods {
        Foods(
            oliveOil: food(0xF1, "Olive oil", "tbsp", Macros(protein: 0, carbs: 0, fat: 14)),
            lemonJuice: food(0xF2, "Lemon juice", "tbsp", Macros(protein: 0, carbs: 1, fat: 0)),
            mustard: food(0xF3, "Dijon mustard", "tsp", Macros(protein: 0, carbs: 0, fat: 0)),
            honey: food(0xF4, "Honey", "tsp", Macros(protein: 0, carbs: 6, fat: 0)),
            romaine: food(0xF5, "Romaine lettuce", "cup", Macros(protein: 1, carbs: 2, fat: 0)),
            tomatoes: food(0xF6, "Cherry tomatoes", "cup", Macros(protein: 1, carbs: 6, fat: 0)),
            cucumber: food(0xF7, "Cucumber", "cup", Macros(protein: 1, carbs: 4, fat: 0)),
            bread: food(0xF8, "Bread cubes", "cup", Macros(protein: 3, carbs: 15, fat: 1))
        )
    }

    private static func food(_ id: UInt8, _ name: String, _ unit: String, _ macros: Macros) -> FoodItem {
        FoodItem(id: fixedID(id), name: name, servingSize: 1, servingUnit: unit, macros: macros,
                 micronutrients: Micronutrients(), category: "test", source: .manual, tags: ["recipe"])
    }
}
