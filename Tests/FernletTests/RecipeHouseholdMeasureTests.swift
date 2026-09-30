// RecipeHouseholdMeasureTests.swift
// FernletTests
//
// How a household choice is SAVED — Docs/Ingredient-Search-Deep-Research-2026-09-29.md §6.3
// "Persistence" and §8 F4a. "1 each" of a banana resolves only on a build whose portion reader knows
// what one banana weighs; an older build (a paired device, a peer, a pre-round install) would convert
// it to nothing and total the recipe at zero. So the recipe editor saves the choice as the grams it
// converts to (`118 g`) with the choice beside them in the additive optional `householdMeasure` key
// ("medium", 118 g per one), re-opens it as "1 each", and shows "1 medium (118 g)". Pinned here: the
// save and re-open rules, the persisted keys (absent when nil, so every other line's bytes are
// unchanged), an older reader decoding the new blob and totalling the same grams, and the recipe
// share wire carrying plain grams that a receiving peer totals exactly as the sender does. Fix round 1:
// a line an older build already reads to the same grams ("1 cup" of a food stating one cup) is kept as
// typed, and a recipe a meal log mints and a substitution fork are saved by the same rule.

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins the grams-plus-display-metadata encoding of household recipe amounts.
struct RecipeHouseholdMeasureTests {
    static func banana() -> FoodItem {
        FoodItem(name: "Bananas, raw", servingSize: 100, servingUnit: "g", macros: Macros(protein: 1, carbs: 23, fat: 0),
                 micronutrients: Micronutrients(fiber: 3), category: "Fruits", source: .usda, dataType: .srLegacy, tags: [],
                 portions: [
                    FoodPortion(amount: 1, unit: "NLEA serving", gramWeight: 126),
                    FoodPortion(amount: 1, unit: "large (8\" to 8-7/8\" long)", gramWeight: 136),
                    FoodPortion(amount: 1, unit: "cup, sliced", gramWeight: 150),
                    FoodPortion(amount: 1, unit: "small (6\" to 6-7/8\" long)", gramWeight: 101),
                    FoodPortion(amount: 1, unit: "medium (7\" to 7-7/8\" long)", gramWeight: 118)
                 ])
    }

    static func butter() -> FoodItem {
        FoodItem(name: "Butter, salted", servingSize: 100, servingUnit: "g", macros: Macros(protein: 1, carbs: 0, fat: 81),
                 micronutrients: Micronutrients(), category: "Dairy", source: .usda, dataType: .srLegacy, tags: [],
                 portions: [FoodPortion(amount: 1, unit: "stick", gramWeight: 113),
                            FoodPortion(amount: 1, unit: "cup", gramWeight: 227),
                            FoodPortion(amount: 1, unit: "tbsp", gramWeight: 14.2)])
    }

    static func garlic() -> FoodItem {
        FoodItem(name: "Garlic, raw", servingSize: 100, servingUnit: "g", macros: Macros(protein: 6, carbs: 33, fat: 1),
                 micronutrients: Micronutrients(), category: "Vegetables", source: .usda, dataType: .srLegacy, tags: [],
                 portions: [FoodPortion(amount: 1, unit: "clove", gramWeight: 3),
                            FoodPortion(amount: 3, unit: "cloves", gramWeight: 9)])
    }

    static func line(_ food: FoodItem, _ quantity: Double, _ unit: String) -> RecipeIngredient {
        RecipeIngredient(foodItemId: food.id, quantity: quantity, unit: unit)
    }

    static func recipe(_ name: String, servings: Int = 1, _ lines: [RecipeIngredient]) -> RecipeDefinition {
        RecipeDefinition(name: name, servings: servings, ingredients: lines, source: "manual",
                         createdAt: Date(), updatedAt: Date())
    }

    // MARK: - Save

    /// A count or volume amount that converts through a USDA portion is saved as its grams, with the
    /// choice kept per ONE unit.
    @Test func aHouseholdChoiceIsSavedAsGrams() {
        let banana = Self.banana()
        let typed = Self.line(banana, 1, "each")
        let one = typed.savingHouseholdAsGrams(using: banana)
        #expect(one.id == typed.id && one.foodItemId == banana.id, "the line keeps its id and food")
        #expect(one.quantity == 118 && one.unit == "g")
        #expect(one.householdMeasure == RecipeHouseholdMeasure(label: "medium", gramsPerUnit: 118))
        let two = Self.line(banana, 2, "each").savingHouseholdAsGrams(using: banana)
        #expect(two.quantity == 236 && two.householdMeasure?.gramsPerUnit == 118)
        let garlic = Self.garlic()
        let cloves = Self.line(garlic, 3, "each").savingHouseholdAsGrams(using: garlic)
        #expect(cloves.quantity == 9 && cloves.householdMeasure?.label == "clove")
        let butter = Self.butter()
        let halfCup = Self.line(butter, 0.5, "cup").savingHouseholdAsGrams(using: butter)
        #expect(halfCup.quantity == 113.5 && halfCup.unit == "g")
        #expect(halfCup.householdMeasure == RecipeHouseholdMeasure(label: "cup", gramsPerUnit: 227))
        let stick = Self.line(butter, 1, "each").savingHouseholdAsGrams(using: butter)
        #expect(stick.quantity == 113 && stick.householdMeasure?.label == "stick")
    }

    /// Every other line is returned exactly as given: grams, ounces, servings, a volume-served food
    /// (its cup is physical, not a portion), and a line that does not convert. (A banana's one
    /// "cup, sliced" IS a household choice: `150 g`, "cup".)
    @Test func otherLinesAreSavedAsTyped() {
        let banana = Self.banana()
        let slicedCup = Self.line(banana, 1, "cup").savingHouseholdAsGrams(using: banana)
        #expect(slicedCup.quantity == 150 && slicedCup.householdMeasure?.label == "cup")
        for (quantity, unit) in [(118.0, "g"), (4.0, "oz"), (1.0, "serving"), (1.0, "slice")] {
            let typed = Self.line(banana, quantity, unit)
            #expect(typed.savingHouseholdAsGrams(using: banana) == typed, "\(quantity) \(unit)")
        }
        let milk = FoodItem(name: "Milk", servingSize: 240, servingUnit: "ml", macros: Macros(protein: 8, carbs: 12, fat: 8),
                            micronutrients: Micronutrients(), category: "Dairy", source: .usda, dataType: .srLegacy, tags: [],
                            portions: [FoodPortion(amount: 1, unit: "cup", gramWeight: 244)])
        let cup = Self.line(milk, 1, "cup")
        #expect(cup.savingHouseholdAsGrams(using: milk) == cup, "a volume-served food keeps its cup")
        let other = Self.line(Self.garlic(), 1, "each")
        #expect(other.savingHouseholdAsGrams(using: banana) == other, "a different food never rewrites the line")
    }

    static func food(_ name: String, _ portions: [FoodPortion]) -> FoodItem {
        FoodItem(name: name, servingSize: 100, servingUnit: "g", macros: Macros(protein: 3, carbs: 28, fat: 0),
                 micronutrients: Micronutrients(), category: "Test", source: .usda, dataType: .srLegacy, tags: [],
                 portions: portions)
    }

    /// Fix round 1 (u2-L-M2, u2-C-U2-2): a line a build from before this round already converts to the
    /// same grams — one stated cup, an exact "slice", an exact "each" — is kept as typed, so the grocery
    /// list, share text and export still read "1 cup" and "2 slice". Only a line that needs this round's
    /// readers (a banana's "each", a cup of butter beside its tablespoon) becomes grams; and a line whose
    /// strict reading gives OTHER grams than today's (a qualified "tbsp, chopped" beside a stated cup)
    /// is saved as today's grams, so every build totals the same.
    @Test func aLineAnOlderBuildReadsIsKeptAsTyped() {
        let rice = Self.food("Rice, white, cooked", [FoodPortion(amount: 1, unit: "cup", gramWeight: 158)])
        for (quantity, unit) in [(1.0, "cup"), (2.0, "tbsp"), (0.5, "cup")] {
            let typed = Self.line(rice, quantity, unit)
            #expect(typed.savingHouseholdAsGrams(using: rice) == typed, "\(quantity) \(unit) of a food stating one cup")
        }
        let bread = Self.food("Bread, whole-wheat", [FoodPortion(amount: 1, unit: "slice", gramWeight: 32)])
        let slices = Self.line(bread, 2, "slice")
        #expect(slices.savingHouseholdAsGrams(using: bread) == slices)
        let sandwich = Self.food("Sandwich", [FoodPortion(amount: 1, unit: "each", gramWeight: 210),
                                              FoodPortion(amount: 1, unit: "medium", gramWeight: 200)])
        let one = Self.line(sandwich, 1, "each")
        #expect(one.savingHouseholdAsGrams(using: sandwich) == one, "a stated \"each\" answers first on every build")
        let herb = Self.food("Herb", [FoodPortion(amount: 1, unit: "cup", gramWeight: 158),
                                      FoodPortion(amount: 1, unit: "tbsp, chopped", gramWeight: 5)])
        let spoon = Self.line(herb, 1, "tbsp").savingHouseholdAsGrams(using: herb)
        #expect(spoon.quantity == 5 && spoon.unit == "g" && spoon.householdMeasure?.label == "tbsp",
                "an older build reads the cup's density (9.9 g); today reads the chopped tbsp (5 g): saved as 5 g")
    }

    /// Fix round 1 (u2-C-U2-3): every path that MINTS a recipe line applies the rule — a recipe a meal
    /// log creates ("4 each" of a banana at yield 4) and a substitution fork ("0.6 each" of apples).
    @Test func mintedAndForkedLinesAreSavedAsGrams() {
        let banana = Self.banana()
        let rice = Self.food("Rice, white, cooked", [FoodPortion(amount: 1, unit: "cup", gramWeight: 158)])
        let stranger = Self.line(Self.garlic(), 2, "each")
        let cups = Self.line(rice, 4, "cup")
        let minted = Self.recipe("Banana rice", servings: 4, [Self.line(banana, 4, "each"), cups, stranger])
            .savingHouseholdAsGrams(using: [banana, rice])
        #expect(minted.ingredients[0].quantity == 472 && minted.ingredients[0].unit == "g")
        #expect(minted.ingredients[0].householdMeasure?.label == "medium")
        #expect(minted.ingredients[1] == cups, "one stated cup stays a cup")
        #expect(minted.ingredients[2] == stranger, "a line whose food is not given is kept")
        let apples = Self.food("Apples, raw, with skin", [
            FoodPortion(amount: 1, unit: "small (2-3/4\" dia)", gramWeight: 149),
            FoodPortion(amount: 1, unit: "medium (3\" dia)", gramWeight: 182),
            FoodPortion(amount: 1, unit: "large (3-1/4\" dia)", gramWeight: 223)
        ])
        #expect(apples.preferredRecipeUnit == .each)
        let swapped = RecipeSubstitution.substitutedIngredient(
            replacing: Self.line(banana, 118, "g"), originalFoodItem: banana, with: apples)
        #expect(swapped.unit == "g" && swapped.householdMeasure?.label == "medium")
        #expect(abs((swapped.householdMeasure?.gramsPerUnit ?? 0) - 182) < 0.001)
        #expect(abs(swapped.quantity - 0.6 * 182) < 0.001, "118 g of banana → 0.6 of a 182 g apple, saved as its grams")
    }

    /// A recipe a quick log mints reaches the book through `FernletStore.commitResolution`, which saves
    /// its lines as the editor does.
    @MainActor
    @Test func commitResolutionSavesMintedRecipesAsGrams() throws {
        let banana = Self.banana()
        let store = makeTestStore(bundledFoodItems: [banana])
        let minted = Self.recipe("Banana smoothie", servings: 4, [Self.line(banana, 4, "each")])
        store.commitResolution(MealResolution(meals: [], createdRecipes: [minted], confidence: .high, isFallback: false))
        let saved = try #require(store.recipes.first { $0.id == minted.id })
        #expect(saved.ingredients.map(\.unit) == ["g"] && saved.ingredients.map(\.quantity) == [472])
        #expect(saved.ingredients.first?.householdMeasure?.label == "medium")
        #expect(MealBuilder.macroTotals(for: saved, foodItems: [banana]) == MealBuilder.macroTotals(for: minted, foodItems: [banana]))
    }

    /// The recipe editor's save path (`CustomIngredientUpsert.recipeIngredients`) applies the rule to a
    /// catalog-bound row and leaves a custom food's own serving alone.
    @Test func theEditorSavePathStoresGrams() {
        let banana = Self.banana()
        var foods = [banana]
        let inputs = [
            ManualRecipeIngredientInput(name: banana.name, selectedFoodItemId: banana.id, quantity: 2, unit: "each"),
            ManualRecipeIngredientInput(name: "My granola", quantity: 1, unit: "each", protein: 5, carbs: 30, fat: 6)
        ]
        let saved = CustomIngredientUpsert.recipeIngredients(from: inputs, in: &foods, verifiedAt: Date())
        #expect(saved.count == 2)
        #expect(saved[0].quantity == 236 && saved[0].unit == "g" && saved[0].householdMeasure?.label == "medium")
        #expect(saved[1].unit == "each" && saved[1].householdMeasure == nil, "a custom food's own serving")
    }

    // MARK: - Re-open and display

    /// The editor re-opens the saved grams as the choice, and keeps grams when the food no longer
    /// converts the choice to the same weight.
    @Test func aSavedChoiceReopensAsTheChoice() throws {
        let banana = Self.banana()
        let saved = Self.line(banana, 2, "each").savingHouseholdAsGrams(using: banana)
        let reopened = saved.restoringHouseholdAmount(using: [banana])
        #expect(reopened.quantity == 2 && reopened.unit == "each" && reopened.id == saved.id)
        let inputs = RecipeEditorInputs.inputs(for: [saved], foodItems: [banana])
        let row = try #require(inputs.first)
        #expect(row.quantity == 2 && row.unit == "each" && row.selectedFoodItemId == banana.id)
        var bigger = banana
        bigger.portions = bigger.portions.map { $0.gramWeight == 118 ? FoodPortion(amount: 1, unit: $0.unit, gramWeight: 125) : $0 }
        #expect(saved.restoringHouseholdAmount(using: [bigger]) == saved, "the portion changed: stay 236 g")
        let butter = Self.butter()
        let halfCup = Self.line(butter, 0.5, "cup").savingHouseholdAsGrams(using: butter).restoringHouseholdAmount(using: [butter])
        #expect(halfCup.quantity == 0.5 && halfCup.unit == "cup")
        let plain = Self.line(banana, 118, "g")
        #expect(plain.restoringHouseholdAmount(using: [banana]) == plain)
    }

    /// The recipe page shows the choice beside its grams, and scaling the recipe keeps it true.
    @Test func theAmountReadsAsTheChoice() throws {
        let banana = Self.banana()
        let saved = Self.line(banana, 1, "each").savingHouseholdAsGrams(using: banana)
        let grams = (118.0).formatted(.number.precision(.fractionLength(0...1)))
        #expect(saved.amountText == "1 medium (\(grams) g)")
        #expect(Self.line(banana, 118, "g").amountText == "\(grams) g", "an ordinary line reads as before")
        let recipe = Self.recipe("Bread", [saved])
        let scaled = try #require(RecipeScaling.scaledIngredients(recipe, forYield: 2).first)
        let doubled = (236.0).formatted(.number.precision(.fractionLength(0...1)))
        #expect(scaled.amountText == "2 medium (\(doubled) g)")
        var invalid = saved
        invalid.householdMeasure = RecipeHouseholdMeasure(label: " ", gramsPerUnit: 118)
        #expect(invalid.amountText == "\(grams) g", "an invalid measure reads as absent")
    }

    // MARK: - Persistence and peers

    /// Wire keys of one encoded line.
    static func keys(_ ingredient: RecipeIngredient) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ingredient))
        return Set(try #require(object as? [String: Any]).keys)
    }

    /// A line without a measure encodes exactly the four keys every build wrote; a household line adds
    /// only `householdMeasure` (`label`, `gramsPerUnit`), and both round-trip.
    @Test func theBlobKeysAreAdditive() throws {
        let banana = Self.banana()
        let plain = Self.line(banana, 100, "g")
        #expect(try Self.keys(plain) == ["id", "foodItemId", "quantity", "unit"])
        let saved = Self.line(banana, 1, "each").savingHouseholdAsGrams(using: banana)
        #expect(try Self.keys(saved) == ["id", "foodItemId", "quantity", "unit", "householdMeasure"])
        let measureObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try #require(saved.householdMeasure)))
        #expect(Set(try #require(measureObject as? [String: Any]).keys) == ["label", "gramsPerUnit"])
        #expect(try JSONDecoder().decode(RecipeIngredient.self, from: JSONEncoder().encode(saved)) == saved)
        #expect(try JSONDecoder().decode(RecipeIngredient.self, from: JSONEncoder().encode(plain)) == plain)
    }

    /// A blob written before this round (no key) decodes with no measure.
    @Test func anOlderBlobDecodes() throws {
        let id = UUID()
        let food = UUID()
        let json = #"{"id":"\#(id.uuidString)","foodItemId":"\#(food.uuidString)","quantity":2,"unit":"cup"}"#
        let decoded = try JSONDecoder().decode(RecipeIngredient.self, from: Data(json.utf8))
        #expect(decoded == RecipeIngredient(id: id, foodItemId: food, quantity: 2, unit: "cup"))
    }

    /// What an older build decodes a line into: the four fields it knows, ignoring any other key.
    struct PreRoundRecipeIngredient: Decodable {
        let id: UUID
        let foodItemId: UUID
        let quantity: Double
        let unit: String
    }

    /// An older build reads the new blob as `118 g` and totals the recipe exactly as this build does,
    /// where "1 each" would have totalled zero there.
    @MainActor
    @Test func anOlderReaderTotalsTheSameGrams() throws {
        let banana = Self.banana()
        let saved = Self.line(banana, 1, "each").savingHouseholdAsGrams(using: banana)
        let recipe = Self.recipe("Smoothie", [saved])
        let blob = try JSONEncoder().encode(recipe)
        let object = try #require(try JSONSerialization.jsonObject(with: blob) as? [String: Any])
        let lines = try JSONSerialization.data(withJSONObject: try #require(object["ingredients"]))
        let old = try #require(try JSONDecoder().decode([PreRoundRecipeIngredient].self, from: lines).first)
        #expect(old.quantity == 118 && old.unit == "g")
        let oldLine = RecipeIngredient(id: old.id, foodItemId: old.foodItemId, quantity: old.quantity, unit: old.unit)
        let oldRecipe = Self.recipe("Smoothie", [oldLine])
        let expected = MealBuilder.macroTotals(for: recipe, foodItems: [banana])
        #expect(expected.carbs == 27 && expected.protein == 1)
        #expect(MealBuilder.macroTotals(for: oldRecipe, foodItems: [banana]) == expected)
        let decoded = try JSONDecoder().decode(RecipeDefinition.self, from: blob)
        #expect(decoded.ingredients == [saved], "this build round-trips the measure")
    }

    /// The share wire is unchanged: the line travels as plain grams with the sender's macros, under
    /// the same six keys, and the receiving peer's import totals exactly what the sender's recipe does.
    @MainActor
    @Test func aPeerTotalsASharedHouseholdLine() throws {
        let banana = Self.banana()
        let garlic = Self.garlic()
        let recipe = Self.recipe("Banana bread", servings: 2, [
            Self.line(banana, 3, "each").savingHouseholdAsGrams(using: banana),
            Self.line(garlic, 2, "each").savingHouseholdAsGrams(using: garlic)
        ])
        let payload = RecipeShareCodec.payload(for: recipe, foodItems: [banana, garlic])
        #expect(payload.ingredients.map(\.unit) == ["g", "g"] && payload.ingredients.map(\.quantity) == [354, 6])
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload.ingredients[0]))
        #expect(Set(try #require(wire as? [String: Any]).keys) == ["name", "quantity", "unit", "protein", "carbs", "fat"])
        let store = makeTestStore()
        let imported = try store.importRecipe(from: RecipeShareCodec.shareText(for: recipe, foodItems: [banana, garlic]))
        let sender = MealBuilder.macroTotals(for: recipe, foodItems: [banana, garlic])
        #expect(sender.carbs > 0)
        #expect(MealBuilder.macroTotals(for: imported, foodItems: store.foodItems) == sender)
    }
}
