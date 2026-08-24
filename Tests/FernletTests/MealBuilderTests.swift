import Foundation
import Testing
import FernletDomainModel
import AIProviders
@testable import Fernlet

@MainActor
struct MealBuilderTests {
    @Test func planWithNoCandidatesReturnsNil() {
        let plan = FoodSelectionPlan(
            mealName: "Lunch",
            mealType: .lunch,
            items: []
        )

        let result = MealBuilder.meals(
            from: plan,
            candidates: [],
            recipes: [],
            foodItems: []
        )

        #expect(result == nil)
    }

    @Test func planMatchingExistingRecipeReturnsRecipeMeal() throws {
        let turkey = foodItem(name: "Turkey", source: .manual, macros: Macros(protein: 24, carbs: 0, fat: 2))
        let bread = foodItem(name: "Bread", source: .manual, macros: Macros(protein: 4, carbs: 22, fat: 1))
        let recipe = recipe(
            name: "Turkey Sandwich",
            ingredients: [
                RecipeIngredient(foodItemId: turkey.id, quantity: 1, unit: RecipeUnit.serving.rawValue),
                RecipeIngredient(foodItemId: bread.id, quantity: 1, unit: RecipeUnit.serving.rawValue)
            ]
        )
        let plan = FoodSelectionPlan(
            mealName: "Lunch",
            mealType: .lunch,
            items: [FoodSelectionMealItem(name: "turkey sandwich", ingredients: [])]
        )

        let result = try #require(MealBuilder.meals(
            from: plan,
            candidates: [],
            recipes: [recipe],
            foodItems: [turkey, bread]
        ))

        #expect(result.createdRecipes.isEmpty)
        #expect(result.meals.count == 1)
        let meal = try #require(result.meals.first)
        #expect(meal.name == "Turkey Sandwich")
        #expect(meal.mealSource == .recipe)
        #expect(meal.source == MealLogSource.manual)
    }

    @Test func multipleResolvedIngredientsCreateRecipeAndRecipeMeal() throws {
        let oats = foodItem(name: "Oats", source: .manual, macros: Macros(protein: 5, carbs: 27, fat: 3))
        let yogurt = foodItem(name: "Greek yogurt", source: .manual, macros: Macros(protein: 18, carbs: 6, fat: 0))
        let candidates = [
            FoodSelectionCandidate(id: 1, foodItem: oats),
            FoodSelectionCandidate(id: 2, foodItem: yogurt)
        ]
        let plan = FoodSelectionPlan(
            mealName: "Breakfast",
            mealType: .breakfast,
            items: [
                FoodSelectionMealItem(
                    name: "oats yogurt",
                    ingredients: [
                        ingredient(candidateId: 1, foodName: "Oats", quantity: 1, unit: RecipeUnit.serving.rawValue),
                        ingredient(candidateId: 2, foodName: "Greek yogurt", quantity: 1, unit: RecipeUnit.serving.rawValue)
                    ]
                )
            ]
        )

        let result = try #require(MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: [],
            foodItems: [oats, yogurt]
        ))

        #expect(result.createdRecipes.count == 1)
        let createdRecipe = try #require(result.createdRecipes.first)
        #expect(createdRecipe.name == "Oats Yogurt")
        #expect(createdRecipe.source == "meal-log")
        #expect(createdRecipe.ingredients.count == 2)
        #expect(result.meals.count == 1)
        let meal = try #require(result.meals.first)
        #expect(meal.mealSource == .recipe)
        #expect(meal.macros == Macros(protein: 23, carbs: 33, fat: 3))
    }

    @Test func singleResolvedIngredientProducesManualMealWithoutRecipe() throws {
        let banana = foodItem(name: "Banana", source: .manual, macros: Macros(protein: 1, carbs: 27, fat: 0))
        let candidates = [FoodSelectionCandidate(id: 1, foodItem: banana)]
        let plan = FoodSelectionPlan(
            mealName: "Snack",
            mealType: .snack,
            items: [
                FoodSelectionMealItem(
                    name: "banana",
                    ingredients: [ingredient(candidateId: 1, foodName: "Banana")]
                )
            ]
        )

        let result = try #require(MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: [],
            foodItems: [banana]
        ))

        #expect(result.createdRecipes.isEmpty)
        #expect(result.meals.count == 1)
        let meal = try #require(result.meals.first)
        #expect(meal.mealSource == .manual)
        #expect(meal.source == MealLogSource.foundationModelFoodSelection)
        #expect(meal.name == "Banana")
    }

    @Test func numericRecipeTokenDoesNotReplaceReviewedProductMatch() throws {
        let chickenMelt = foodItem(
            name: "Sandwich Bros Chicken Melts",
            source: .aiResolved,
            macros: Macros(protein: 9, carbs: 18, fat: 7),
            category: "web product",
            tags: ["web-import", "costco"]
        )
        let steak = foodItem(name: "Steak", source: .manual, macros: Macros(protein: 24, carbs: 0, fat: 8))
        let candidates = [FoodSelectionCandidate(id: 1, foodItem: chickenMelt)]
        let plan = try #require(FoundationFoodSelectionModel.deterministicPlan(
            description: "2 costco chicken melts",
            candidates: candidates,
            fallbackType: .lunch
        ))

        let result = try #require(MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: [
                recipe(
                    name: "Steak 2",
                    ingredients: [RecipeIngredient(foodItemId: steak.id, quantity: 1, unit: RecipeUnit.serving.rawValue)]
                )
            ],
            foodItems: [chickenMelt, steak]
        ))

        let meal = try #require(result.meals.first)
        #expect(meal.mealSource == .manual)
        #expect(meal.macros == Macros(protein: 18, carbs: 36, fat: 14))
        #expect(meal.note.contains("2 serving Sandwich Bros Chicken Melts"))
    }

    // MARK: - Bare-count vs explicit-unit quantity resolution (deterministic tier-2 path)

    @Test func bareCountOfGramServingFoodLogsServingsNotGrams() throws {
        // "2 eggs" must resolve to two servings (~two eggs of macros), not 2 grams. The pre-fix bug
        // stamped quantity=2 in grams → scale ≈ 2/50 ≈ 0.04 → ~0 macros committed silently at .high.
        let eggs = gramFood(name: "Eggs", servingSize: 50, macros: Macros(protein: 6, carbs: 0, fat: 5))
        let (quantity, unit) = try resolveSingleIngredient(description: "2 eggs", food: eggs)

        #expect(unit == RecipeUnit.gram.rawValue)
        #expect(quantity == 100) // 2 servings × 50 g
        let macros = try #require(RecipeIngredient(
            foodItemId: eggs.id, quantity: quantity, unit: unit
        ).servingConversion(using: eggs)).scaledMacros(for: eggs)
        #expect(macros == Macros(protein: 12, carbs: 0, fat: 10))
        #expect(macros.calories > 100) // guards against the ~3 kcal undercount regression
    }

    @Test func explicitGramWeightStaysInGrams() throws {
        // "100 g chicken" must stay 100 g (one serving here), not be re-read as 100 servings.
        let chicken = gramFood(name: "Chicken", servingSize: 100, macros: Macros(protein: 30, carbs: 0, fat: 3))
        let (quantity, unit) = try resolveSingleIngredient(description: "100 g chicken", food: chicken)

        #expect(unit == RecipeUnit.gram.rawValue)
        #expect(quantity == 100)
        let macros = try #require(RecipeIngredient(
            foodItemId: chicken.id, quantity: quantity, unit: unit
        ).servingConversion(using: chicken)).scaledMacros(for: chicken)
        #expect(macros == Macros(protein: 30, carbs: 0, fat: 3))
    }

    @Test func bareFoodWithNoNumberLogsOneServing() throws {
        // Plain "eggs" (no count) is one serving.
        let eggs = gramFood(name: "Eggs", servingSize: 50, macros: Macros(protein: 6, carbs: 0, fat: 5))
        let (quantity, unit) = try resolveSingleIngredient(description: "eggs", food: eggs)

        #expect(unit == RecipeUnit.gram.rawValue)
        #expect(quantity == 50) // one serving
        let macros = try #require(RecipeIngredient(
            foodItemId: eggs.id, quantity: quantity, unit: unit
        ).servingConversion(using: eggs)).scaledMacros(for: eggs)
        #expect(macros == Macros(protein: 6, carbs: 0, fat: 5))
    }

    @Test func explicitCupUnitScalesByVolume() throws {
        // "2 cups rice" uses the typed cup unit (1 cup = 240 g = one serving here → two servings).
        var rice = gramFood(name: "Rice", servingSize: 240, macros: Macros(protein: 4, carbs: 45, fat: 0))
        rice.portions = [FoodPortion(amount: 1, unit: "cup", gramWeight: 240)]
        let (quantity, unit) = try resolveSingleIngredient(description: "2 cups rice", food: rice)

        #expect(unit == RecipeUnit.cup.rawValue)
        #expect(quantity == 2)
        let macros = try #require(RecipeIngredient(
            foodItemId: rice.id, quantity: quantity, unit: unit
        ).servingConversion(using: rice)).scaledMacros(for: rice)
        #expect(macros == Macros(protein: 8, carbs: 90, fat: 0)) // 480 g / 240 g = 2 servings
    }

    /// Runs the deterministic tier-2 planner end to end for a single-food description and returns the
    /// lone resolved ingredient plus its quantity/unit for macro assertions.
    private func resolveSingleIngredient(
        description: String,
        food: FoodItem
    ) throws -> (quantity: Double, unit: String) {
        let candidates = [FoodSelectionCandidate(id: 1, foodItem: food)]
        let plan = try #require(FoundationFoodSelectionModel.deterministicPlan(
            description: description,
            candidates: candidates,
            fallbackType: .lunch
        ))
        let item = try #require(plan.items.first)
        let ingredient = try #require(item.ingredients.first)
        return (ingredient.quantity, ingredient.unit)
    }

    private func gramFood(name: String, servingSize: Double, macros: Macros) -> FoodItem {
        FoodItem(
            name: name,
            brandSource: nil,
            servingSize: servingSize,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: macros,
            micronutrients: Micronutrients(),
            category: "test",
            source: .usda,
            tags: []
        )
    }

    @Test func conversionRejectsUnprovenVolumeBridgeAndRamenIdentityFallback() {
        let ramen = gramFood(name: "Ramen", servingSize: 43, macros: Macros(protein: 7, carbs: 54, fat: 14))
        let unsupported = RecipeIngredient(foodItemId: ramen.id, quantity: 100, unit: RecipeUnit.each.rawValue)
        #expect(unsupported.servingConversion(using: ramen) == nil)

        let glass = RecipeIngredient(foodItemId: ramen.id, quantity: 1, unit: RecipeUnit.glass.rawValue)
        #expect(glass.servingConversion(using: ramen) == nil)
        let input = ManualRecipeIngredientInput(
            name: ramen.name, selectedFoodItemId: ramen.id, quantity: 100, unit: RecipeUnit.each.rawValue
        )
        #expect(input.resolvedMacros(foodItems: [ramen]) == nil)
        #expect(input.hasResolvedMacros(foodItems: [ramen]) == false)
        #expect(MealBuilder.mealFromIngredients(
            itemName: "Ramen", resolvedIngredients: [(ingredient(candidateId: 1, foodName: "Ramen", quantity: 100, unit: "each"), ramen)],
            mealType: .lunch
        ) == nil)
    }

    @Test func conversionKeepsMassAndVolumeSeparateAndNamesGlassDefault() throws {
        let drink = FoodItem(
            name: "Milk",
            brandSource: nil,
            servingSize: 354.882,
            servingUnit: RecipeUnit.milliliter.rawValue,
            macros: Macros(protein: 12, carbs: 18, fat: 8),
            micronutrients: Micronutrients(),
            category: "test",
            source: .manual,
            tags: []
        )
        let glass = try #require(RecipeIngredient(
            foodItemId: drink.id, quantity: 1, unit: RecipeUnit.glass.rawValue
        ).servingConversion(using: drink))
        #expect(glass.servingScale == 1)
        #expect(glass.provenance == .glassDefault)
        #expect(RecipeUnit.normalized("oz") == .ounce)
        #expect(RecipeUnit.normalized("fl oz") == .fluidOunce)
        #expect(RecipeUnit.normalized("mg") == .milligram)
        #expect(RecipeUnit.normalized("kg") == .kilogram)
        #expect(RecipeUnit.normalized("l") == .liter)
        #expect(RecipeUnit.normalized("slice") == .slice)
        #expect(RecipeUnit.normalized("piece") == .piece)
        #expect(RecipeUnit.glass.label == "Glass (12 US fl oz)")
    }

    @Test func conversionUsesExactIntraDimensionPhysicalFactors() throws {
        let massFood = gramFood(name: "Flour", servingSize: 100, macros: Macros(protein: 10, carbs: 76, fat: 1))
        let massCases: [(Double, RecipeUnit, Double)] = [
            (1_000, .milligram, 0.01), (0.001, .kilogram, 0.01), (1, .ounce, 0.283495), (1, .pound, 4.53592)
        ]
        for (quantity, unit, expectedScale) in massCases {
            let conversion = try #require(RecipeIngredient(
                foodItemId: massFood.id, quantity: quantity, unit: unit.rawValue
            ).servingConversion(using: massFood))
            #expect(abs(conversion.servingScale - expectedScale) < 0.000_001)
        }

        let volumeFood = FoodItem(
            name: "Broth", brandSource: nil, servingSize: 1_000, servingUnit: "ml",
            macros: Macros(protein: 0, carbs: 0, fat: 0), micronutrients: Micronutrients(),
            category: "test", source: .manual, tags: []
        )
        let volumeCases: [(Double, RecipeUnit, Double)] = [
            (1, .liter, 1), (1, .teaspoon, 0.00492892), (1, .tablespoon, 0.0147868),
            (1, .cup, 0.236588), (1, .fluidOunce, 0.0295735)
        ]
        for (quantity, unit, expectedScale) in volumeCases {
            let conversion = try #require(RecipeIngredient(
                foodItemId: volumeFood.id, quantity: quantity, unit: unit.rawValue
            ).servingConversion(using: volumeFood))
            #expect(abs(conversion.servingScale - expectedScale) < 0.000_001)
        }
        #expect(RecipeIngredient(foodItemId: volumeFood.id, quantity: 1, unit: "oz")
            .servingConversion(using: volumeFood) == nil)
    }

    @Test func sourceFaithfulFNDDSBlankAmountPieceDerivesWithoutRewritingRawFields() throws {
        let sourceID = "usda_fdc:2708615"
        let sourceVersion = "2026-04-30"
        let sourceMemberSHA256 = "378fea2f2f70801c6710119fdb3c7de47f5a57db636db972a661dda23988d780"
        let rawPortionID = "303668"
        let rawAmount: String? = nil
        let rawUnit = "undetermined"
        let rawDescription = "1 piece, NFS"
        let rawGramWeight = 86.0

        #expect(sourceID == "usda_fdc:2708615")
        #expect(sourceVersion == "2026-04-30")
        #expect(sourceMemberSHA256.count == 64)
        #expect(rawPortionID == "303668")
        #expect(rawAmount == nil)
        #expect(rawUnit == "undetermined")
        #expect(rawDescription == "1 piece, NFS")

        let derived = FoodPortion(
            amount: 1, unit: rawUnit, gramWeight: rawGramWeight, description: rawDescription
        )
        #expect(derived.recipeUnit == .piece)
        let pizza = FoodItem(
            name: "Pizza, cheese, from restaurant or fast food, thin crust",
            brandSource: nil, servingSize: 1, servingUnit: "piece",
            macros: Macros(protein: 12, carbs: 30, fat: 13), micronutrients: Micronutrients(fiber: 2),
            category: "Survey (FNDDS)", source: .usda, dataType: .survey, tags: [], portions: [derived]
        )
        let conversion = try #require(RecipeIngredient(
            foodItemId: pizza.id, quantity: 1, unit: "piece"
        ).servingConversion(using: pizza))
        #expect(conversion.componentQuantity == 1)
        #expect(conversion.componentUnit == "piece")
        #expect(conversion.grams == rawGramWeight)
        #expect(conversion.sourcePortion == derived)
        #expect(conversion.scaledMacros(for: pizza) == pizza.macros)
        #expect(conversion.scaledMicronutrients(for: pizza) == pizza.micronutrients)
    }

    @Test func conversionRejectsInvalidBoundsAndAmbiguousSourcePortions() {
        var food = gramFood(name: "Toast", servingSize: 100, macros: Macros(protein: 4, carbs: 18, fat: 2))
        food.portions = [
            FoodPortion(amount: 1, unit: "slice", gramWeight: 50),
            FoodPortion(amount: 1, unit: "slice", gramWeight: 50)
        ]
        let invalid: [(Double, String)] = [
            (0, "g"), (-1, "g"), (.nan, "g"), (.infinity, "g"), (3_001, "g"), (101, "slice"), (1, "slice")
        ]
        for (quantity, unit) in invalid {
            let ingredient = RecipeIngredient(foodItemId: food.id, quantity: quantity, unit: unit)
            #expect(ingredient.servingConversion(using: food) == nil)
        }
    }

    @Test func sandwichAcceptsBreadOrCheeseIngredientsAsRelevant() throws {
        let bread = foodItem(name: "Sourdough bread", source: .manual, macros: Macros(protein: 4, carbs: 22, fat: 1), category: "bread")
        let cheese = foodItem(name: "Cheddar cheese", source: .manual, macros: Macros(protein: 7, carbs: 1, fat: 9), category: "cheese")
        let candidates = [
            FoodSelectionCandidate(id: 1, foodItem: bread),
            FoodSelectionCandidate(id: 2, foodItem: cheese)
        ]
        let plan = FoodSelectionPlan(
            mealName: "Lunch",
            mealType: .lunch,
            items: [
                FoodSelectionMealItem(
                    name: "sandwich",
                    ingredients: [
                        ingredient(candidateId: 1, foodName: "Sourdough bread"),
                        ingredient(candidateId: 2, foodName: "Cheddar cheese")
                    ]
                )
            ]
        )

        let result = try #require(MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: [],
            foodItems: [bread, cheese]
        ))

        #expect(result.createdRecipes.count == 1)
        let createdRecipe = try #require(result.createdRecipes.first)
        #expect(createdRecipe.ingredients.count == 2)
        #expect(Set(createdRecipe.ingredients.map(\.foodItemId)) == Set([bread.id, cheese.id]))
    }

    @Test func grilledCheeseAcceptsBreadOrSourdoughIngredientsAsRelevant() throws {
        let sourdough = foodItem(name: "Sourdough", source: .manual, macros: Macros(protein: 4, carbs: 22, fat: 1), category: "bread")
        let candidates = [FoodSelectionCandidate(id: 1, foodItem: sourdough)]
        let plan = FoodSelectionPlan(
            mealName: "Lunch",
            mealType: .lunch,
            items: [
                FoodSelectionMealItem(
                    name: "grilled cheese",
                    ingredients: [ingredient(candidateId: 1, foodName: "Sourdough")]
                )
            ]
        )

        let result = try #require(MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: [],
            foodItems: [sourdough]
        ))

        #expect(result.createdRecipes.isEmpty)
        #expect(result.meals.count == 1)
        let meal = try #require(result.meals.first)
        #expect(meal.mealSource == .manual)
    }

    @Test func mealFromRecipeClassifiesLogSource() throws {
        let usda = foodItem(name: "USDA chicken", source: .usda, macros: Macros(protein: 26, carbs: 0, fat: 3))
        let scanned = foodItem(
            name: "Scanned bar",
            source: .manual,
            macros: Macros(protein: 12, carbs: 22, fat: 6),
            micronutrients: Micronutrients(fiber: 4, sugar: 8, saturatedFat: 2, potassium: 80, sodium: 120)
        )
        let manual = foodItem(name: "Manual rice", source: .manual, macros: Macros(protein: 4, carbs: 45, fat: 1))

        let usdaMeal = try #require(MealBuilder.mealFromRecipe(
            recipe(name: "Chicken", ingredients: [RecipeIngredient(foodItemId: usda.id, quantity: 1, unit: RecipeUnit.serving.rawValue)]),
            mealType: .lunch,
            foodItems: [usda]
        ))
        let scannedMeal = try #require(MealBuilder.mealFromRecipe(
            recipe(name: "Scanned Bar", ingredients: [RecipeIngredient(foodItemId: scanned.id, quantity: 1, unit: RecipeUnit.serving.rawValue)]),
            mealType: .snack,
            foodItems: [scanned]
        ))
        let webImportMeal = try #require(MealBuilder.mealFromRecipe(
            recipe(name: "Web Bowl", ingredients: [RecipeIngredient(foodItemId: manual.id, quantity: 1, unit: RecipeUnit.serving.rawValue)], source: MealLogSource.webImport),
            mealType: .dinner,
            foodItems: [manual]
        ))
        let manualMeal = try #require(MealBuilder.mealFromRecipe(
            recipe(name: "Manual Bowl", ingredients: [RecipeIngredient(foodItemId: manual.id, quantity: 1, unit: RecipeUnit.serving.rawValue)]),
            mealType: .dinner,
            foodItems: [manual]
        ))

        #expect(usdaMeal.source == MealLogSource.usdaRecipe)
        #expect(scannedMeal.source == MealLogSource.labelScan)
        #expect(webImportMeal.source == MealLogSource.webImport)
        #expect(manualMeal.source == MealLogSource.manual)
    }

    @Test func directIngredientMealStoresComponentSnapshots() throws {
        let rice = foodItem(
            name: "Cooked rice",
            source: .manual,
            macros: Macros(protein: 3, carbs: 28, fat: 0),
            micronutrients: Micronutrients(fiber: 1)
        )

        let meal = try #require(MealBuilder.mealFromIngredients(
            itemName: "rice bowl",
            resolvedIngredients: [(ingredient(candidateId: 1, foodName: "Cooked rice", quantity: 2), rice)],
            mealType: .lunch
        ))

        let component = try #require(meal.componentSnapshots.first)
        #expect(meal.componentSnapshots.count == 1)
        #expect(component.name == "Cooked rice")
        #expect(component.quantity == 2)
        #expect(component.macros == Macros(protein: 6, carbs: 56, fat: 0))
        #expect(meal.macros == component.macros)
        #expect(meal.micronutrientSnapshot.fiber == 2)
    }

    @Test func recipeMealStoresPerServingComponentSnapshots() throws {
        let yogurt = foodItem(name: "Greek yogurt", source: .manual, macros: Macros(protein: 18, carbs: 6, fat: 0))
        let berries = foodItem(name: "Berries", source: .manual, macros: Macros(protein: 1, carbs: 12, fat: 0))
        let recipe = RecipeDefinition(
            name: "Yogurt Bowl",
            servings: 2,
            ingredients: [
                RecipeIngredient(foodItemId: yogurt.id, quantity: 2, unit: RecipeUnit.serving.rawValue),
                RecipeIngredient(foodItemId: berries.id, quantity: 2, unit: RecipeUnit.serving.rawValue)
            ],
            source: "manual",
            createdAt: Date(timeIntervalSince1970: 1_779_664_800),
            updatedAt: Date(timeIntervalSince1970: 1_779_664_800)
        )

        let meal = try #require(MealBuilder.mealFromRecipe(
            recipe, mealType: .breakfast, foodItems: [yogurt, berries]
        ))

        #expect(meal.macros == Macros(protein: 19, carbs: 18, fat: 0))
        #expect(meal.componentSnapshots.count == 2)
        #expect(meal.componentSnapshots.map(\.quantity) == [1, 1])
    }

    @Test func mealCorrectionRecomputesFromComponentSnapshots() {
        let store = makeTestStore()
        let meal = Meal(
            name: "Rice Bowl",
            mealType: .lunch,
            macros: Macros(protein: 10, carbs: 50, fat: 5),
            micronutrientSnapshot: Micronutrients(fiber: 4),
            componentSnapshots: [
                MealComponentSnapshot(
                    name: "Chicken",
                    quantity: 100,
                    unit: RecipeUnit.gram.rawValue,
                    macros: Macros(protein: 20, carbs: 0, fat: 3),
                    micronutrients: Micronutrients(sodium: 60)
                ),
                MealComponentSnapshot(
                    name: "Rice",
                    quantity: 150,
                    unit: RecipeUnit.gram.rawValue,
                    macros: Macros(protein: 4, carbs: 42, fat: 1),
                    micronutrients: Micronutrients(fiber: 2)
                )
            ],
            quality: .ok,
            confidence: "Food match",
            note: "Matched locally from food selection: chicken, rice.",
            source: MealLogSource.foundationModelFoodSelection
        )
        store.day.meals.append(meal)
        let corrected = [
            MealComponentSnapshot(
                id: meal.componentSnapshots[0].id,
                name: "Chicken",
                quantity: 150,
                unit: RecipeUnit.gram.rawValue,
                macros: Macros(protein: 30, carbs: 0, fat: 5),
                micronutrients: Micronutrients(sodium: 90)
            ),
            meal.componentSnapshots[1]
        ]

        store.updateMealCorrection(
            mealID: meal.id,
            name: "Chicken Rice Bowl",
            mealType: .dinner,
            macros: meal.macros,
            componentSnapshots: corrected
        )

        let updated = store.day.meals[0]
        #expect(updated.name == "Chicken Rice Bowl")
        #expect(updated.mealType == .dinner)
        #expect(updated.macros == Macros(protein: 34, carbs: 42, fat: 6))
        #expect(updated.micronutrientSnapshot.sodium == 90)
        #expect(updated.micronutrientSnapshot.fiber == 2)
        #expect(updated.componentSnapshots == corrected)
        #expect(updated.confidence == MealConfidence.corrected.token)
    }

    @Test func mealDecodingDefaultsMissingComponentSnapshots() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Legacy Meal",
          "mealType": "Lunch",
          "macros": { "protein": 1, "carbs": 2, "fat": 3 },
          "quality": "ok",
          "confidence": "Legacy",
          "note": "Old meal"
        }
        """
        let meal = try JSONDecoder().decode(Meal.self, from: Data(json.utf8))
        #expect(meal.componentSnapshots.isEmpty)
        #expect(meal.source == MealLogSource.manual)
    }

    // MARK: - Resolution plausibility gate (belt-and-suspenders total-calorie cap)

    @Test func implausibleCalorieResolutionIsGatedToReview() {
        // A high-confidence resolution whose meals sum past the single-log ceiling — the "2 burger
        // patties" → 81,688 kcal bug — must be DOWNGRADED to review rather than silently committed.
        // The data is preserved (confidence lowered, meals kept) so the user can correct it, not lose it.
        let absurd = Meal(
            name: "Double hamburgers, broccoli slaw salad, pork with chilli and tomatoes",
            mealType: .lunch,
            macros: Macros(protein: 3_000, carbs: 3_000, fat: 6_000), // 4·3000 + 4·3000 + 9·6000 = 78,000 kcal
            quality: .ok,
            confidence: "Food match",
            note: "",
            source: MealLogSource.foundationModelFoodSelection
        )
        let resolution = MealResolution(meals: [absurd], createdRecipes: [], confidence: .high, isFallback: false)
        #expect(resolution.needsReview == false) // sanity: high-confidence would auto-commit as-is

        let gated = MealResolutionService.plausibilityGated(resolution)
        #expect(gated.confidence == .low)
        #expect(gated.needsReview)
        #expect(gated.meals == resolution.meals) // preserved for review, not dropped
    }

    @Test func plausibleResolutionStaysHighConfidence() {
        // A normal meal well under the ceiling passes the gate unchanged.
        let normal = Meal(
            name: "Chicken and rice",
            mealType: .dinner,
            macros: Macros(protein: 45, carbs: 60, fat: 15), // 4·45 + 4·60 + 9·15 = 555 kcal
            quality: .good,
            confidence: "Food match",
            note: "",
            source: MealLogSource.foundationModelFoodSelection
        )
        let resolution = MealResolution(meals: [normal], createdRecipes: [], confidence: .high, isFallback: false)
        let gated = MealResolutionService.plausibilityGated(resolution)
        #expect(gated.confidence == .high)
        #expect(gated.needsReview == false)
    }

    // MARK: - Deterministic bind-score floor

    @Test func deterministicPlanDropsBelowFloorGarbageMatch() throws {
        // A food that matches "burger patties" ONLY through its category/tags (no name signal) scores
        // below the bind floor and must be dropped, not logged — the "broccoli slaw for burger patties"
        // class of bug. With ~50k branded foods in the catalog these weak binds are common.
        let garbage = foodItem(
            name: "Broccoli Slaw Salad",
            source: .usda,
            macros: Macros(protein: 2, carbs: 6, fat: 0),
            category: "burger",
            tags: ["patties"]
        )
        let garbageOnly = [FoodSelectionCandidate(id: 1, foodItem: garbage)]
        #expect(FoundationFoodSelectionModel.deterministicPlan(
            description: "burger patties",
            candidates: garbageOnly,
            fallbackType: .lunch
        ) == nil)

        // A real name match for the same query clears the floor and is bound instead of the garbage.
        let patty = foodItem(
            name: "Burger Patty",
            source: .usda,
            macros: Macros(protein: 20, carbs: 0, fat: 15),
            category: "beef"
        )
        let mixed = [
            FoodSelectionCandidate(id: 1, foodItem: garbage),
            FoodSelectionCandidate(id: 2, foodItem: patty)
        ]
        let plan = try #require(FoundationFoodSelectionModel.deterministicPlan(
            description: "burger patties",
            candidates: mixed,
            fallbackType: .lunch
        ))
        let ingredients = plan.items.flatMap(\.ingredients)
        #expect(ingredients.contains(where: { $0.candidateId == 2 }))
        #expect(ingredients.contains(where: { $0.candidateId == 1 }) == false)
    }

    private func ingredient(
        candidateId: Int,
        foodName: String,
        quantity: Double = 1,
        unit: String = RecipeUnit.serving.rawValue
    ) -> FoodSelectionIngredient {
        FoodSelectionIngredient(candidateId: candidateId, foodName: foodName, quantity: quantity, unit: unit)
    }

    private func recipe(
        name: String,
        ingredients: [RecipeIngredient],
        source: String = "manual",
        updatedAt: Date = Date(timeIntervalSince1970: 1_779_664_800)
    ) -> RecipeDefinition {
        RecipeDefinition(
            name: name,
            servings: 1,
            ingredients: ingredients,
            source: source,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    @Test func multiItemResolutionFoldsIntoSingleMeal() {
        func part(_ name: String, _ p: Int, _ c: Int, _ f: Int) -> Meal {
            let component = MealComponentSnapshot(
                foodItemId: UUID(), name: name, quantity: 1, unit: RecipeUnit.serving.rawValue,
                macros: Macros(protein: p, carbs: c, fat: f), micronutrients: Micronutrients()
            )
            return Meal(
                name: name, mealType: .lunch, macros: Macros(protein: p, carbs: c, fat: f),
                componentSnapshots: [component], quality: .ok, confidence: "Food match", note: "", source: "manual"
            )
        }
        // Three plan items (as MealBuilder emits one Meal each) must fold into ONE meal — the "burger
        // patties with cottage cheese and ketchup logged as 3 separate meals" bug.
        let resolution = MealResolution(
            meals: [part("Beef patty", 20, 0, 15), part("Cottage cheese", 12, 4, 2), part("Ketchup", 0, 5, 0)],
            createdRecipes: [], confidence: .high, isFallback: false
        )
        let merged = MealResolutionService.mergedIntoSingleMeal(resolution, description: "burger patties with cottage cheese and ketchup")
        #expect(merged.meals.count == 1)
        #expect(merged.meals[0].componentSnapshots.count == 3)
        #expect(merged.meals[0].macros.protein == 32)   // 20 + 12 + 0
        #expect(merged.meals[0].macros.carbs == 9)       // 0 + 4 + 5
        #expect(merged.meals[0].macros.fat == 17)        // 15 + 2 + 0

        // A single-meal resolution is returned untouched.
        let single = MealResolution(meals: [part("Egg", 6, 0, 5)], createdRecipes: [], confidence: .high, isFallback: false)
        let unchanged = MealResolutionService.mergedIntoSingleMeal(single, description: "egg")
        #expect(unchanged.meals.count == 1)
        #expect(unchanged.meals[0].name == "Egg")
    }

    /// The merged meal's persisted provenance stamp must not depend on WORD ORDER.
    ///
    /// `mergedIntoSingleMeal` took `parts[0].confidence`, so "smoothie and taco" persisted
    /// `foodMatch` while "taco and smoothie" persisted `roughEstimate` for identical food — and a
    /// resolution that skips the review sheet (the AI-retry commit path does not consult
    /// `needsReview`) carried that wrong stamp into the diary. A merged row can only honestly carry
    /// its weakest part's stamp.
    @Test func mergedMealTakesTheLeastConfidentStampRegardlessOfOrder() {
        func part(_ name: String, _ confidence: MealConfidence) -> Meal {
            let component = MealComponentSnapshot(
                foodItemId: UUID(), name: name, quantity: 1, unit: RecipeUnit.serving.rawValue,
                macros: Macros(protein: 5, carbs: 5, fat: 5), micronutrients: Micronutrients()
            )
            return Meal(
                name: name, mealType: .lunch, macros: Macros(protein: 5, carbs: 5, fat: 5),
                componentSnapshots: [component], quality: .ok, confidence: confidence.token,
                note: "", source: "manual"
            )
        }
        let clean = part("Smoothie", .foodMatch)
        let weak = part("Taco", .roughEstimate)
        func mergedToken(_ parts: [Meal]) -> String? {
            MealResolutionService.mergedIntoSingleMeal(
                MealResolution(meals: parts, createdRecipes: [], confidence: .low, isFallback: false),
                description: "two dishes"
            ).meals.first?.confidence
        }
        #expect(mergedToken([clean, weak]) == MealConfidence.roughEstimate.token)
        #expect(mergedToken([weak, clean]) == MealConfidence.roughEstimate.token)
        // All-clean parts keep the confident stamp — the fold is pessimistic, not punitive.
        #expect(mergedToken([clean, part("Sashimi", .foodMatch)]) == MealConfidence.foodMatch.token)
        // The legacy English spellings resolve too, so an old part cannot dodge the fold.
        let legacyWeak = part("Taco", .foodMatch)
        var legacy = legacyWeak
        legacy.confidence = "Rough estimate"
        #expect(mergedToken([clean, legacy]) == MealConfidence.roughEstimate.token)
    }

    /// A recipe-backed part is NOT relabelled by the fold.
    ///
    /// `MealBuilder.mealFromRecipe` stamps `MealConfidence.recipe`, and those meals reach
    /// `mergedIntoSingleMeal` through `MealBuilder.meals(from:)` on both the AI-selection and the
    /// deterministic plan tiers — so "no resolver tier produces another stamp" was simply false.
    /// `MealConfidence` is documented as a PROVENANCE stamp ("how this row got its numbers"), and
    /// `recipe` names a source rather than a rung on a confidence ladder — that ladder is
    /// `MealResolutionConfidence`. Ordering `recipe` against `foodMatch` would invent an order the
    /// enum does not define, so a part carrying any stamp outside the estimate-grade set
    /// (`roughEstimate`/`estimated`/`foodMatch`) short-circuits the fold to the pre-existing
    /// `parts[0]` behaviour. These pins therefore record BOTH that no answer regressed and that
    /// `[foodMatch, recipe]` is still word-order dependent — an open owner question, not a fix.
    @Test func recipeStampedPartsKeepThePreExistingFold() {
        func part(_ name: String, _ confidence: MealConfidence) -> Meal {
            let component = MealComponentSnapshot(
                foodItemId: UUID(), name: name, quantity: 1, unit: RecipeUnit.serving.rawValue,
                macros: Macros(protein: 5, carbs: 5, fat: 5), micronutrients: Micronutrients()
            )
            return Meal(
                name: name, mealType: .lunch, macros: Macros(protein: 5, carbs: 5, fat: 5),
                componentSnapshots: [component], quality: .ok, confidence: confidence.token,
                note: "", source: "manual"
            )
        }
        let recipeBacked = part("Chili", .recipe)
        let matched = part("Rice", .foodMatch)
        let rough = part("Guess", .roughEstimate)
        let fold = MealResolutionService.pessimisticConfidenceToken

        // The measured regression, now closed: this returned `foodMatch` before this round's repair.
        #expect(fold([recipeBacked, matched]) == MealConfidence.recipe.token)
        // The other order is unchanged from pre-fix too — and still order-dependent. Owner question.
        #expect(fold([matched, recipeBacked]) == MealConfidence.foodMatch.token)
        #expect(fold([recipeBacked, rough]) == MealConfidence.recipe.token)
        #expect(fold([recipeBacked, recipeBacked]) == MealConfidence.recipe.token)
        #expect(fold([recipeBacked]) == MealConfidence.recipe.token)
        // Every other provenance-only stamp behaves the same way — the fold is total, not partial.
        for stamp in MealConfidence.allCases where [.roughEstimate, .estimated, .foodMatch].contains(stamp) == false {
            #expect(fold([part("A", stamp), rough]) == stamp.token, "\(stamp.token) must not be relabelled")
        }
        // An unparseable stamp (a newer build's token arriving over sync) is likewise left alone.
        var unknown = matched
        unknown.confidence = "somethingNewerBuildsWrite"
        #expect(fold([unknown, rough]) == "somethingNewerBuildsWrite")
    }

    @Test func burgerPattyCanonicalizesToBeefButLeavesDishesAndNonBeefAlone() {
        // "burger patties" is the meat — rewrite so it matches "beef patty", not FNDDS hamburger dishes.
        #expect(MealResolutionService.canonicalizedQuery("two burger patties") == "two beef patties")
        #expect(MealResolutionService.canonicalizedQuery("a burger patty") == "a beef patty")
        // Never touch the assembled-dish words themselves.
        #expect(MealResolutionService.canonicalizedQuery("hamburger") == "hamburger")
        #expect(MealResolutionService.canonicalizedQuery("cheeseburger with fries") == "cheeseburger with fries")
        // Leave non-beef patties alone.
        #expect(MealResolutionService.canonicalizedQuery("turkey burger patty") == "turkey burger patty")
        #expect(MealResolutionService.canonicalizedQuery("two veggie burger patties") == "two veggie burger patties")
        // Unrelated text is unchanged.
        #expect(MealResolutionService.canonicalizedQuery("grilled chicken and rice") == "grilled chicken and rice")
    }

    @Test func preparedDishHeuristicDemotesAssembledDishesForIngredientQueries() {
        let sandwich = foodItem(name: "Chicken sandwich", source: .usda, macros: Macros(protein: 20, carbs: 30, fat: 12))
        let onBun = foodItem(name: "Double hamburger, on wheat bun, 2 large patties", source: .usda, macros: Macros(protein: 60, carbs: 27, fat: 52))
        let rawChicken = foodItem(name: "Chicken, breast, cooked, roasted", source: .usda, macros: Macros(protein: 31, carbs: 0, fat: 4))
        let beefPatty = foodItem(name: "Beef, ground, patty, cooked", source: .usda, macros: Macros(protein: 25, carbs: 0, fat: 19))

        // Classification: carrier/assembly words + FNDDS "on wheat bun" mark a dish.
        #expect(PreparedDishHeuristic.isPreparedDish(sandwich))
        #expect(PreparedDishHeuristic.isPreparedDish(onBun))
        #expect(!PreparedDishHeuristic.isPreparedDish(rawChicken))
        #expect(!PreparedDishHeuristic.isPreparedDish(beefPatty))

        // Intent is the query's HEAD noun: a bare ingredient does NOT want a dish; a dish name does.
        #expect(!PreparedDishHeuristic.queryWantsDish("grilled chicken"))
        #expect(!PreparedDishHeuristic.queryWantsDish("two burger patties"))
        #expect(!PreparedDishHeuristic.queryWantsDish("scrambled eggs"))
        #expect(PreparedDishHeuristic.queryWantsDish("cheeseburger"))
        #expect(PreparedDishHeuristic.queryWantsDish("chicken sandwich"))
        #expect(PreparedDishHeuristic.queryWantsDish("burger"))
        // The three-way distinction the user asked about, decided by the HEAD noun of the main phrase:
        #expect(PreparedDishHeuristic.queryWantsDish("a burger"))            // head = burger  → dish (bun)
        #expect(!PreparedDishHeuristic.queryWantsDish("a burger patty"))     // head = patty   → just the meat
        #expect(PreparedDishHeuristic.queryWantsDish("a burger with 2 patties")) // head = burger (before "with") → dish
        // Component/cut nouns are ingredients even under a dish modifier.
        #expect(!PreparedDishHeuristic.queryWantsDish("chicken breast"))
        #expect(!PreparedDishHeuristic.queryWantsDish("grilled chicken with rice"))

        // An ingredient query sinks the dish below the raw food; a dish query leaves order intact.
        #expect(PreparedDishHeuristic.demotingDishes([sandwich, rawChicken], forQuery: "grilled chicken").first?.name == rawChicken.name)
        #expect(PreparedDishHeuristic.demotingDishes([sandwich, rawChicken], forQuery: "chicken sandwich").first?.name == sandwich.name)
    }

    @Test func mealItemSplitterKeepsQuantityModifiersButSplitsSeparateFoods() {
        // "with <quantity/modifier> <component>" describes the head food — kept as ONE item.
        #expect(MealItemSplitter.items(from: "burger with 2 patties") == ["burger with 2 patties"])
        #expect(MealItemSplitter.items(from: "burger with two patties") == ["burger with two patties"])
        #expect(MealItemSplitter.items(from: "burger with extra cheese") == ["burger with extra cheese"])
        // "with <a separate food>" still splits.
        #expect(MealItemSplitter.items(from: "burger with fries") == ["burger", "fries"])
        #expect(MealItemSplitter.items(from: "eggs with toast") == ["eggs", "toast"])
        // Mixed: the burger's patty count stays attached, the truly separate food splits off.
        #expect(MealItemSplitter.items(from: "a burger with 2 patties and cottage cheese") == ["a burger with 2 patties", "cottage cheese"])
    }

    private func foodItem(
        name: String,
        source: FoodItemSource,
        macros: Macros,
        micronutrients: Micronutrients = Micronutrients(),
        category: String = "test",
        tags: [String] = []
    ) -> FoodItem {
        FoodItem(
            name: name,
            brandSource: nil,
            servingSize: 1,
            servingUnit: RecipeUnit.serving.rawValue,
            macros: macros,
            micronutrients: micronutrients,
            category: category,
            source: source,
            tags: tags
        )
    }
}
