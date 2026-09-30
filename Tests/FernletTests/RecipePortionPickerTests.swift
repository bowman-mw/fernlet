// RecipePortionPickerTests.swift
// FernletTests
//
// The recipe editor's per-food amount menu — Docs/Ingredient-Search-Deep-Research-2026-09-29.md §6.3
// Rung A and §8 F4b (owner decision 2026-09-30). Before F4b the unit menu listed all sixteen units
// for every food and a banana's cup refused, because USDA states two cups (sliced 150 g, mashed
// 225 g). Pinned here: the menu lists a food's own USDA portions first with their grams, hides the
// units that cannot convert, folds a unit into the portion one of it IS (so no amount is offered
// twice and a line held as "1 each" still saves as F4a saves it), makes the banana's cup a CHOICE,
// saves a named choice as its grams beside the choice (no new unit token), re-opens it as the choice,
// and captions it with a count its noun agrees with ("Counted as 2 eggs", never "2 egg").

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

/// Pins the per-food amount menu, its save and re-open rules, and the counted caption.
struct RecipePortionPickerTests {
    static func food(_ name: String, _ portions: [FoodPortion], type: FoodDataType = .srLegacy) -> FoodItem {
        FoodItem(name: name, servingSize: 100, servingUnit: "g", macros: Macros(protein: 1, carbs: 23, fat: 0),
                 micronutrients: Micronutrients(), category: "Fixtures", source: .usda, dataType: type, tags: [],
                 portions: portions)
    }

    /// USDA SR 173944's eight portions.
    static func banana() -> FoodItem {
        food("Bananas, raw", [
            FoodPortion(amount: 1, unit: "NLEA serving", gramWeight: 126),
            FoodPortion(amount: 1, unit: "extra large (9\" or longer)", gramWeight: 152),
            FoodPortion(amount: 1, unit: "large (8\" to 8-7/8\" long)", gramWeight: 136),
            FoodPortion(amount: 1, unit: "cup, sliced", gramWeight: 150),
            FoodPortion(amount: 1, unit: "small (6\" to 6-7/8\" long)", gramWeight: 101),
            FoodPortion(amount: 1, unit: "extra small (less than 6\" long)", gramWeight: 81),
            FoodPortion(amount: 1, unit: "medium (7\" to 7-7/8\" long)", gramWeight: 118),
            FoodPortion(amount: 1, unit: "cup, mashed", gramWeight: 225)
        ])
    }

    /// USDA SR 169230's four portions.
    static func garlic() -> FoodItem {
        food("Garlic, raw", [
            FoodPortion(amount: 1, unit: "tsp", gramWeight: 2.8), FoodPortion(amount: 1, unit: "clove", gramWeight: 3),
            FoodPortion(amount: 3, unit: "cloves", gramWeight: 9), FoodPortion(amount: 1, unit: "cup", gramWeight: 136)
        ])
    }

    static func named(_ choices: RecipePortionPicker.Choices) -> [String] {
        choices.options.filter { $0.source == .usdaPortion }.map { "\($0.label) \(String(format: "%g", $0.gramsPerOne ?? 0))" }
    }

    // MARK: - The menu

    /// A banana's own portions lead, counts by weight then its two cups; the cup, spoon and "each"
    /// units are not offered on their own — the cups cannot convert (they disagree), and "each" IS the
    /// medium banana, which stands for it.
    @Test func aBananaListsItsOwnPortionsAndItsCupIsAChoice() throws {
        let choices = RecipePortionPicker.choices(for: Self.banana())
        #expect(Self.named(choices) == [
            "extra small 81", "small 101", "medium 118", "large 136", "extra large 152", "cup, sliced 150", "cup, mashed 225"
        ])
        let units = choices.options.compactMap(\.unit)
        #expect(units == [.gram, .ounce, .pound, .kilogram, .milligram, .serving],
                "the cups and spoons cannot convert, and each is folded into medium")
        let medium = try #require(choices.options.first { $0.label == "medium" })
        #expect(choices.standIns == [.each: medium])
        #expect(choices.option(for: .each) == medium, "a tap default of 1 each shows as medium (118 g)")
        #expect(choices.unit(standingIn: medium) == .each)
        #expect(choices.options.first == choices.options.first { $0.source == .usdaPortion }, "portions first")
        #expect(!choices.options.contains { $0.source == .typicalSize }, "a food's own data is never overridden")
    }

    /// Units whose one IS a stated portion fold into it ("cup" of garlic is its 136 g cup, "each" its
    /// clove); a unit that converts only by density ("tbsp") is offered on its own. "3 cloves" is the
    /// same clove, listed once.
    @Test func aUnitWhoseOneIsAListedPortionIsFoldedIntoIt() {
        let choices = RecipePortionPicker.choices(for: Self.garlic())
        #expect(Self.named(choices) == ["clove 3", "tsp 2.8", "cup 136"])
        #expect(Set(choices.standIns.keys) == [.each, .teaspoon, .cup])
        #expect(choices.options.contains { $0.unit == .tablespoon }, "a tablespoon converts by the cup's density")
        #expect(!choices.options.contains { $0.unit == .piece || $0.unit == .slice }, "units that cannot convert are hidden")
    }

    /// Two sizes under one label stay two (a lemon's fruit), and one cup at USDA's rounding stays one
    /// (oats' "1 cup" 81 g and "0.33 cup" 27 g).
    @Test func oneLabelIsListedOncePerSize() {
        let lemon = Self.food("Lemons, raw, without peel", [
            FoodPortion(amount: 1, unit: "fruit (2-3/8\" dia)", gramWeight: 84),
            FoodPortion(amount: 1, unit: "fruit (2-1/8\" dia)", gramWeight: 58),
            FoodPortion(amount: 1, unit: "NLEA serving", gramWeight: 58)
        ])
        let lemonChoices = RecipePortionPicker.choices(for: lemon)
        #expect(Self.named(lemonChoices) == ["fruit 58", "fruit 84"])
        #expect(Set(lemonChoices.options.map(\.id)).count == lemonChoices.options.count, "every picker tag is distinct")
        #expect(lemonChoices.standIns[.each]?.gramsPerOne == 58, "each is the fruit its NLEA serving names")
        let oats = Self.food("Cereals, oats, regular and quick, not fortified, dry", [
            FoodPortion(amount: 1, unit: "cup", gramWeight: 81), FoodPortion(amount: 0.33, unit: "cup", gramWeight: 27)
        ])
        #expect(Self.named(RecipePortionPicker.choices(for: oats)) == ["cup 81"])
    }

    /// What one of a portion is, in the words a person reads: size and noun for a named count, the
    /// text without its parentheticals otherwise; nothing for a reference serving, a mass, a yield or
    /// "10 strips".
    @Test func labelsReadTheWayAPersonDoes() {
        let cases: [(FoodPortion, String?)] = [
            (FoodPortion(amount: 1, unit: "stalk, medium (7-1/2\" - 8\" long)", gramWeight: 40), "medium stalk"),
            (FoodPortion(amount: 1, unit: "Potato medium (2-1/4\" to 3-1/4\" dia)", gramWeight: 213), "medium potato"),
            (FoodPortion(amount: 1, unit: "slice, thin", gramWeight: 9), "slice, thin"),
            (FoodPortion(amount: 1, unit: "cup, sliced", gramWeight: 150), "cup, sliced"),
            (FoodPortion(amount: 1, unit: "regular", gramWeight: 7.2), "regular"),
            (FoodPortion(amount: 1, unit: "lemon yields", gramWeight: 48), "lemon"),
            (FoodPortion(amount: 1, unit: "undetermined", gramWeight: 126, description: "1 banana"), "banana"),
            (FoodPortion(amount: 1, unit: "each", gramWeight: 35, description: "1 serving (35 g)"), "serving"),
            (FoodPortion(amount: 10, unit: "strips", gramWeight: 27), nil),
            (FoodPortion(amount: 1, unit: "piece, cooked, excluding refuse (yield from 1 lb raw meat with refuse)", gramWeight: 283), nil)
        ]
        for (portion, label) in cases {
            #expect(FoodPortionReader.householdLabel(of: portion) == label, "\(portion.unit)")
        }
        let listed = RecipePortionPicker.usdaOptions(for: Self.food("Candies, semisweet chocolate", [
            FoodPortion(amount: 1, unit: "serving", gramWeight: 14.5),
            FoodPortion(amount: 1, unit: "oz (approx 60 pcs)", gramWeight: 28.35),
            FoodPortion(amount: 1, unit: "cup chips (6 oz package)", gramWeight: 168)
        ]))
        #expect(listed.map(\.label) == ["cup chips"], "a reference serving and a mass are not household measures")
    }

    /// The amount a pick keeps: a gram tap default becomes ONE of a count or volume (never a hundred
    /// avocados), a named portion becomes its grams in a mass unit, and a count stays a count.
    @Test func aPickKeepsASensibleAmount() {
        let fruit = RecipePortionOption(source: .typicalSize, label: "fruit", gramsPerOne: 136, dimension: .count)
        let large = RecipePortionOption(source: .usdaPortion, label: "large", gramsPerOne: 136, dimension: .count)
        let medium = RecipePortionOption(source: .usdaPortion, label: "medium", gramsPerOne: 118, dimension: .count)
        let grams = RecipePortionOption(unit: .gram)
        let ounces = RecipePortionOption(unit: .ounce)
        func kept(_ option: RecipePortionOption, _ quantity: Double, _ unit: String,
                  portion: RecipePortionOption? = nil, standIn: RecipeUnit? = nil) -> Double {
            RecipePortionPicker.quantity(afterChoosing: option, standingIn: standIn, from: quantity, unit: unit, portion: portion)
        }
        #expect(kept(fruit, 100, "g") == 1, "100 g tap default → one fruit, not 13,600 g")
        #expect(kept(RecipePortionOption(unit: .cup), 1, "serving") == 1)
        #expect(kept(grams, 2, "g", portion: fruit) == 272, "two fruits → their grams")
        #expect(kept(ounces, 1, "g", portion: fruit) == 4.8)
        #expect(kept(large, 2, "g", portion: medium) == 2, "2 medium → 2 large")
        #expect(kept(medium, 3, "g", portion: large, standIn: .each) == 3)
        #expect(kept(large, 2, "each") == 2, "a count stays a count")
        #expect(kept(ounces, 150, "g") == 150, "a mass stays as typed, as before")
    }

    // MARK: - Save and re-open

    /// A named choice is saved as its grams with the choice beside them — the F4a encoding, no new unit
    /// token — and an unbound (custom) row never reads a portion.
    @Test func aNamedChoiceIsSavedAsItsGrams() throws {
        let banana = Self.banana()
        let sliced = try #require(RecipePortionPicker.choices(for: banana).options.first { $0.label == "cup, sliced" })
        let row = ManualRecipeIngredientInput(name: banana.name, selectedFoodItemId: banana.id, quantity: 2, unit: "g", portion: sliced)
        let line = row.recipeLine(for: banana)
        #expect(line.quantity == 300 && line.unit == "g")
        #expect(line.householdMeasure == RecipeHouseholdMeasure(label: "cup, sliced", gramsPerUnit: 150))
        #expect(row.resolvedMacros(foodItems: [banana]) == banana.scaledMacros(by: 3))
        var foods = [banana]
        let saved = try #require(CustomIngredientUpsert.recipeIngredients(from: [row], selectionCatalog: [banana], in: &foods,
                                                                          verifiedAt: Date()).first)
        #expect(saved.quantity == 300 && saved.unit == "g" && saved.householdMeasure?.label == "cup, sliced")
        #expect(RecipeUnit.allCases.count == 16, "no unit token was added")
        let custom = ManualRecipeIngredientInput(name: "My banana mash", quantity: 1, unit: "cup", protein: 1, portion: sliced)
        #expect(custom.recipeLine(for: banana).unit == "cup", "an unbound row's amount is its own serving")
    }

    /// A saved line re-opens as its choice: "1 each" as each (shown as medium), a named portion as that
    /// portion, a typed "2 cup" of garlic as typed (an older build reads it the same, so it is kept),
    /// and a choice the menu no longer offers as the saved size itself — never silently as bare grams.
    @Test func aSavedChoiceReopensAsTheChoice() throws {
        let banana = Self.banana()
        let choices = RecipePortionPicker.choices(for: banana)
        let each = RecipeIngredient(foodItemId: banana.id, quantity: 2, unit: "each").savingHouseholdAsGrams(using: banana)
        #expect(RecipePortionPicker.reopened(each, foodItem: banana, choices: choices)
                == .init(quantity: 2, unit: "each", portion: nil))
        let sliced = RecipeIngredient(foodItemId: banana.id, quantity: 300, unit: "g",
                                      householdMeasure: RecipeHouseholdMeasure(label: "cup, sliced", gramsPerUnit: 150))
        let reopened = RecipePortionPicker.reopened(sliced, foodItem: banana, choices: choices)
        #expect(reopened.quantity == 2 && reopened.portion?.label == "cup, sliced" && reopened.portion?.source == .usdaPortion)
        let rice = Self.food("Rice, white, long-grain, regular, enriched, cooked", [FoodPortion(amount: 1, unit: "cup", gramWeight: 158)])
        let riceCups = RecipeIngredient(foodItemId: rice.id, quantity: 2, unit: "cup").savingHouseholdAsGrams(using: rice)
        #expect(riceCups.unit == "cup", "an older build reads one stated cup, so the line is kept as typed")
        let riceChoices = RecipePortionPicker.choices(for: rice)
        #expect(RecipePortionPicker.reopened(riceCups, foodItem: rice, choices: riceChoices) == .init(quantity: 2, unit: "cup", portion: nil))
        #expect(riceChoices.option(for: .cup)?.label == "cup", "…and shows as the stated cup (158 g)")
        let garlic = Self.garlic()
        let cups = RecipeIngredient(foodItemId: garlic.id, quantity: 2, unit: "cup").savingHouseholdAsGrams(using: garlic)
        #expect(cups.unit == "g" && cups.quantity == 272, "two stated volumes: older builds refuse, so grams")
        #expect(RecipePortionPicker.reopened(cups, foodItem: garlic, choices: RecipePortionPicker.choices(for: garlic))
                == .init(quantity: 2, unit: "cup", portion: nil))
        let ownSize = RecipeIngredient(foodItemId: banana.id, quantity: 260, unit: "g",
                                       householdMeasure: RecipeHouseholdMeasure(label: "huge", gramsPerUnit: 130))
        let kept = RecipePortionPicker.reopened(ownSize, foodItem: banana, choices: choices)
        #expect(kept.quantity == 2 && kept.portion == RecipePortionOption(source: .personal, label: "huge", gramsPerOne: 130, dimension: .count))
        let inputs = RecipeEditorInputs.inputs(for: [sliced], foodItems: [banana])
        #expect(inputs.first?.portion?.label == "cup, sliced" && inputs.first?.quantity == 2)
    }

    // MARK: - Caption

    /// The caption's noun agrees with its count; a size word does not take a plural, and a qualifier
    /// stays after the noun it qualifies.
    @Test func theCountedCaptionAgreesWithItsCount() {
        let english = Locale(identifier: "en_US")
        func caption(_ grams: Double, _ label: String, _ perOne: Double) -> String? {
            let line = RecipeIngredient(foodItemId: UUID(), quantity: grams, unit: "g",
                                        householdMeasure: RecipeHouseholdMeasure(label: label, gramsPerUnit: perOne))
            return RecipeHouseholdCaption.caption(for: line, locale: english).map { String($0.characters) }
        }
        #expect(caption(100.6, "egg", 50.3) == "Counted as 2 eggs (100.6 g)")
        #expect(caption(50.3, "egg", 50.3) == "Counted as 1 egg (50.3 g)")
        #expect(caption(236, "medium", 118) == "Counted as 2 medium (236 g)")
        #expect(caption(300, "cup, sliced", 150) == "Counted as 2 cups, sliced (300 g)")
        #expect(caption(80, "medium stalk", 40) == "Counted as 2 medium stalks (80 g)")
        #expect(caption(6, "clove", 3) == "Counted as 2 cloves (6 g)")
        #expect(RecipeHouseholdCaption.caption(for: RecipeIngredient(foodItemId: UUID(), quantity: 118, unit: "g"), locale: english) == nil)
    }

    /// Which labels take a plural: a noun the portion reader knows, a recipe unit, a listed portion
    /// noun — never a size word or a word it does not know.
    @Test func onlyANounTakesAPlural() {
        let plural = ["egg", "clove", "cup, sliced", "medium stalk", "Italian tomato", "tbsp", "breast half", "stick", "serving"]
        let invariant = ["medium", "extra large", "large", "regular", "strip large"]
        for label in plural {
            #expect(RecipeHouseholdMeasure(label: label, gramsPerUnit: 1).headTakesPlural, "\(label)")
        }
        for label in invariant {
            #expect(!RecipeHouseholdMeasure(label: label, gramsPerUnit: 1).headTakesPlural, "\(label)")
        }
    }
}
