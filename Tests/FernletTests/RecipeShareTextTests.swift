import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The text "Share as text" hands the system share sheet (`RecipeShareText`, 2026-09-30): readable,
/// in the sender's language, and carrying no Fernlet data.
///
/// The owner's report: sharing a recipe outside Fernlet "pastes the raw json data". These pin that no
/// shape of recipe produces any of it, the exact text for a one-part recipe, a recipe made in parts,
/// a household amount, the "Include notes" rule (notes AND steps for a recipe the person made, notes
/// only for a web recipe), a web recipe's lines, estimate note and source, and that the new text
/// does not import — the paste reader is for text OLDER builds shared (`RecipeShareCodecTests`).
/// The locale is pinned to `en_US`, and the labels resolve against the app bundle's English.
@MainActor
struct RecipeShareTextTests {
    static let english = Locale(identifier: "en_US")

    // MARK: - No Fernlet data, whatever the recipe

    @Test func noShapeOfRecipeCarriesJSONOrTheOldMarker() {
        let bowl = Self.trainingBowl()
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let banana = RecipeHouseholdMeasureTests.banana()
        let smoothie = RecipeHouseholdMeasureTests.recipe(
            "Smoothie", [RecipeHouseholdMeasureTests.line(banana, 1, "each").savingHouseholdAsGrams(using: banana)])
        let texts = [
            Self.text(bowl.recipe, bowl.foodItems),
            Self.text(bowl.recipe, bowl.foodItems, showCalories: true),
            Self.text(salad.recipe, salad.foodItems),
            Self.text(smoothie, [banana]),
            Self.text(Self.webRecipe(), [])
        ]
        for text in texts {
            #expect(!text.contains("Fernlet recipe data:"))
            #expect(!text.contains("{") && !text.contains("\"version\"") && !text.contains("fernlet."))
            #expect(!text.contains("(P"), "no per-ingredient macro codes")
        }
    }

    // MARK: - A recipe the person made

    @Test func aOnePartRecipeReadsAsAGolden() {
        let bowl = Self.trainingBowl()
        #expect(Self.text(bowl.recipe, bowl.foodItems) == """
            Training Bowl
            Servings: 2
            Per serving: 24 g protein, 47 g carbs, 3 g fat

            Ingredients
            • 80 g Rolled oats
            • 340 g Greek yogurt
            • 200 g Blueberries

            Steps
            1. Combine oats and yogurt.
            2. Top with berries and chill.

            Notes
            Chill before serving.
            """)
    }

    @Test func caloriesAppearOnlyWhenThePersonShowsThem() {
        let bowl = Self.trainingBowl()
        #expect(Self.text(bowl.recipe, bowl.foodItems, showCalories: true)
            .contains("Per serving: 311 cal, 24 g protein, 47 g carbs, 3 g fat"))
        #expect(!Self.text(bowl.recipe, bowl.foodItems).contains(" cal"))
    }

    @Test func aRecipeMadeInPartsGroupsIngredientsAndStepsByPart() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let blocks = Self.text(salad.recipe, salad.foodItems).components(separatedBy: "\n\n")
        #expect(blocks.first == """
            Garden salad with lemon-dijon dressing
            Servings: 4
            Per serving: 3 g protein, 14 g carbs, 15 g fat
            """)
        #expect(blocks.contains("Ingredients"))
        #expect(blocks.contains("""
            Lemon-dijon dressing
            • 3 tbsp Olive oil
            • 2 tbsp Lemon juice
            • 1 tsp Dijon mustard
            • 1 tsp Honey
            """))
        #expect(blocks.contains("""
            Lemon-dijon dressing
            1. Whisk the lemon juice, mustard and honey.
            2. Stream in the olive oil while whisking until it thickens.
            """), "steps are numbered from 1 within each part, under its name")
        let steps = try #require(blocks.firstIndex(of: "Steps"))
        let ingredients = try #require(blocks.firstIndex(of: "Ingredients"))
        #expect(ingredients < steps)
        #expect(blocks[steps + 2].hasPrefix("Salad\n1. Toss the bread cubes"), "parts stay in making order")
        #expect(blocks.last == "Notes\nKeep the dressing in the fridge for up to a week.")
    }

    @Test func aHouseholdLineReadsAsTheRecipePageShowsIt() {
        let banana = RecipeHouseholdMeasureTests.banana()
        let line = RecipeHouseholdMeasureTests.line(banana, 1, "each").savingHouseholdAsGrams(using: banana)
        let smoothie = RecipeHouseholdMeasureTests.recipe("Smoothie", [line])
        #expect(Self.text(smoothie, [banana]).contains("\n• 1 medium (118 g) Bananas, raw"))
    }

    @Test func numbersFollowTheSendersLocale() {
        let banana = RecipeHouseholdMeasureTests.banana()
        let smoothie = RecipeHouseholdMeasureTests.recipe(
            "Smoothie", [RecipeHouseholdMeasureTests.line(banana, 50.5, "g")])
        let german = RecipeShareText.text(for: smoothie, foodItems: [banana], showCalories: false,
                                          includesNotes: true, locale: Locale(identifier: "de_DE"))
        #expect(german.contains("• 50,5 g Bananas, raw"))
        #expect(Self.text(smoothie, [banana]).contains("• 50.5 g Bananas, raw"))
    }

    @Test func notesOffWithholdsTheNotesAndTheStepsOfARecipeThePersonMade() {
        let bowl = Self.trainingBowl()
        let text = Self.text(bowl.recipe, bowl.foodItems, includesNotes: false)
        #expect(!text.contains("Chill before serving.") && !text.contains("Notes"))
        #expect(!text.contains("Steps") && !text.contains("Combine oats"))
        #expect(text.contains("• 80 g Rolled oats"), "the ingredients still go")
    }

    @Test func anIngredientWhoseFoodIsMissingIsLeftOut() {
        let bowl = Self.trainingBowl()
        let text = Self.text(bowl.recipe, Array(bowl.foodItems.dropFirst()))
        #expect(!text.contains("Rolled oats"))
        #expect(text.contains("• 340 g Greek yogurt"))
    }

    // MARK: - A recipe saved from a web page

    @Test func aWebRecipeCarriesItsLinesEstimateStepsAndSource() {
        let text = Self.text(Self.webRecipe())
        #expect(text == """
            Saved Training Bowl
            Servings: 3
            Per serving: 24 g protein, 42 g carbs, 6 g fat
            2 ingredients not counted in this estimate

            Ingredients
            • 1 cup oats
            • 2 cups Greek yogurt
            • a handful of blueberries

            Steps
            1. Follow the linked recipe.

            Notes
            A saved web recipe summary.

            Source: https://example.com/saved-training-bowl
            """)
    }

    @Test func notesOffKeepsAWebRecipesStepsFromItsPublicPage() {
        let text = Self.text(Self.webRecipe(), includesNotes: false)
        #expect(!text.contains("A saved web recipe summary.") && !text.contains("Notes"))
        #expect(text.contains("1. Follow the linked recipe."))
    }

    @Test func aWebRecipeWithoutAnEstimateOrAWebLinkSaysNothingAboutEither() {
        var recipe = Self.webRecipe()
        recipe.webImport?.macros = Macros(protein: 0, carbs: 0, fat: 0)
        recipe.webImport?.sourceURLString = "file:///etc/hosts"
        let text = Self.text(recipe)
        #expect(!text.contains("Per serving") && !text.contains("not counted"))
        #expect(!text.contains("Source:"), "only a web address is offered as a source")
    }

    // MARK: - The store and the paste importer

    /// The store renders through the person's "show calories" setting, and the text it hands the share
    /// sheet does not import: it is for reading. (An older build's text still does —
    /// `RecipeShareCodecTests.legacyShareTextStillImports`.)
    @Test func theStoresTextFollowsShowCaloriesAndDoesNotImport() throws {
        let store = makeTestStore()
        let bowl = Self.trainingBowl()
        store.foodItems.append(contentsOf: bowl.foodItems)
        store.settings.showCalories = false
        let text = store.recipeShareText(for: bowl.recipe, includesNotes: true)
        #expect(text.hasPrefix("Training Bowl\nServings: 2\nPer serving: 24 g protein"))
        store.settings.showCalories = true
        #expect(store.recipeShareText(for: bowl.recipe, includesNotes: true).contains(" cal, "))
        #expect(throws: RecipeImportError.missingPayload) { try store.importRecipe(from: text) }
    }

    // MARK: - Fixtures

    static func text(
        _ recipe: RecipeDefinition, _ foodItems: [FoodItem] = [], showCalories: Bool = false, includesNotes: Bool = true
    ) -> String {
        RecipeShareText.text(for: recipe, foodItems: foodItems, showCalories: showCalories,
                             includesNotes: includesNotes, locale: english)
    }

    /// Oats, yogurt and blueberries for two: whole-recipe P48 C94 F6, so P24 C47 F3 a serving.
    static func trainingBowl() -> (recipe: RecipeDefinition, foodItems: [FoodItem]) {
        let oats = food("Rolled oats", 40, Macros(protein: 5, carbs: 27, fat: 3))
        let yogurt = food("Greek yogurt", 170, Macros(protein: 18, carbs: 6, fat: 0))
        let berries = food("Blueberries", 100, Macros(protein: 1, carbs: 14, fat: 0))
        let recipe = RecipeDefinition(
            name: "Training Bowl",
            servings: 2,
            ingredients: [
                RecipeIngredient(foodItemId: oats.id, quantity: 80, unit: "g"),
                RecipeIngredient(foodItemId: yogurt.id, quantity: 340, unit: "g"),
                RecipeIngredient(foodItemId: berries.id, quantity: 200, unit: "g")
            ],
            notes: "Chill before serving.",
            source: "manual",
            createdAt: Date(timeIntervalSince1970: 1_779_664_800),
            updatedAt: Date(timeIntervalSince1970: 1_779_664_800),
            steps: [RecipeStep(text: "Combine oats and yogurt."), RecipeStep(text: "Top with berries and chill.")]
        )
        return (recipe, [oats, yogurt, berries])
    }

    /// A recipe saved from a web page whose USDA estimate left two of its lines out.
    static func webRecipe() -> RecipeDefinition {
        RecipeDefinition(
            name: "Saved Training Bowl",
            servings: 3,
            ingredients: [],
            notes: "A saved web recipe summary.",
            source: MealLogSource.webImport,
            createdAt: Date(timeIntervalSince1970: 1_779_664_800),
            updatedAt: Date(timeIntervalSince1970: 1_779_664_800),
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/saved-training-bowl",
                ingredientLines: ["1 cup oats", "2 cups Greek yogurt", "a handful of blueberries"],
                macros: Macros(protein: 24, carbs: 42, fat: 6),
                uncountedIngredientLines: 2
            ),
            steps: [RecipeStep(text: "Follow the linked recipe.")]
        )
    }

    private static func food(_ name: String, _ grams: Double, _ macros: Macros) -> FoodItem {
        FoodItem(name: name, brandSource: nil, servingSize: grams, servingUnit: "g", macros: macros,
                 micronutrients: Micronutrients(), category: "test", source: .manual, tags: ["recipe"])
    }
}
