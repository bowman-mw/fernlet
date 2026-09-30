// TypicalPortionTableTests.swift
// FernletTests
//
// The curated USDA typical sizes — Docs/Ingredient-Search-Deep-Research-2026-09-29.md §6.3 Rungs C and
// D, §8 F4b (owner decision 2026-09-30: a badged, editable "USDA typical size, estimate" table). Pinned
// here: every size is read from the SR Legacy row it cites, found in the SHIPPED catalog with that
// portion and those grams (so no value can be typed in from memory); a row IS an entry's ingredient
// only by its head noun and words, never a dish or a processed form that contains them; a typical size
// fills only what the food's own data leaves empty; and the web importer weighs a line the bound row
// cannot ("3 cloves garlic" on a row with no clove).

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog

/// Pins the typical-size table's citations, matching and lookups.
struct TypicalPortionTableTests {
    static func row(_ name: String, type: FoodDataType = .srLegacy, source: FoodItemSource = .usda,
                    portions: [FoodPortion] = []) -> FoodItem {
        FoodItem(name: name, servingSize: 100, servingUnit: "g", macros: Macros(protein: 5, carbs: 10, fat: 2),
                 micronutrients: Micronutrients(), category: "Fixtures", source: source, dataType: type, tags: [],
                 portions: portions)
    }

    /// The catalog id an SR Legacy row's FDC id maps to.
    static func catalogID(_ fdc: Int) -> UUID? {
        UUID(uuidString: String(format: "00000000-0000-5000-8000-%012d", fdc))
    }

    /// Every typical size is a portion of the SR Legacy row it cites, in the shipped catalog, at the
    /// grams it states — per the portion as stated, or per one when USDA states several ("2 tbsp",
    /// "0.5 breast").
    @Test func everyTypicalSizeIsReadFromItsCitedUSDARow() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount >= FoodSearchCorpusTests.shippedRowCount, "the shipped catalog must be loaded")
        var missing: [String] = []
        for entry in TypicalPortionTable.entries {
            for portion in entry.portions {
                let id = try #require(Self.catalogID(portion.fdcID))
                guard let cited = catalog.items(ids: [id]).first, cited.dataType == .srLegacy, portion.fdcID < 1_000_000 else {
                    missing.append("\(entry.key): FDC \(portion.fdcID) is not a shipped SR Legacy row")
                    continue
                }
                let stated = cited.portions.contains { usda in
                    (usda.unit == portion.usdaPortion || usda.description == portion.usdaPortion)
                        && (abs(usda.gramWeight - portion.grams) < 0.01 || abs(usda.gramWeight / usda.amount - portion.grams) < 0.01)
                }
                if !stated { missing.append("\(entry.key) \(portion.label): \(cited.name) has no \"\(portion.usdaPortion)\" at \(portion.grams) g") }
            }
        }
        #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
    }

    /// Each key names its own entry — the specific ones ("peanut butter", "brown sugar", "roma tomato")
    /// before the general ones they contain — and no key appears twice.
    @Test func everyKeyNamesItsOwnEntry() {
        let keys = TypicalPortionTable.entries.map(\.key)
        #expect(Set(keys).count == keys.count, "a duplicate key could never be reached")
        for key in keys {
            let named = Self.row(key.prefix(1).uppercased() + key.dropFirst())
            #expect(TypicalPortionTable.entry(for: named)?.key == key, "\"\(key)\" matched \(TypicalPortionTable.entry(for: named)?.key ?? "nothing")")
        }
        #expect(TypicalPortionTable.entries.allSatisfy { !$0.portions.isEmpty })
    }

    /// The thin rows the corpus lands on are their ingredient; dishes, processed forms and look-alikes
    /// are not.
    @Test func aRowIsTheIngredientItsHeadNounNames() {
        let expected: [(String, String?)] = [
            ("Avocado, Hass, peeled, raw", "avocado"), ("Garlic, raw", "garlic"),
            ("Flour, wheat, all-purpose, enriched, bleached", "all purpose flour"), ("Tomato, roma", "roma tomato"),
            ("Peppers, bell, green, raw", "bell pepper"), ("Chicken, thigh, boneless, skinless, raw", "chicken thigh"),
            ("Butter, stick, unsalted", "butter"), ("Peanut butter, creamy", "peanut butter"),
            ("Apples, fuji, with skin, raw", "apple"), ("Celery, raw", "celery"), ("Egg, white, raw, fresh", "egg white"),
            ("Sweet potato, raw, unprepared", "sweet potato"), ("Tomato, paste, canned, without salt added", "tomato paste"),
            ("Rice, brown, long grain, unenriched, raw", "brown rice"), ("Oats, whole grain, rolled, old fashioned", "oats"),
            ("Bread, banana", nil), ("Bananas, dehydrated, or banana powder", nil), ("Lemon grass (citronella), raw", nil),
            ("Cookies, chocolate chip, dry mix", nil), ("Spices, garlic powder", nil), ("Carrots, baby, raw", nil),
            ("Onions, spring or scallions (includes tops and bulb), raw", nil), ("Rice, white, long-grain, regular, cooked", nil),
            ("Oats, whole grain, steel cut", nil), ("Lemon juice, raw", nil), ("Onion rings, breaded, par fried, frozen", nil)
        ]
        for (name, key) in expected {
            #expect(TypicalPortionTable.entry(for: Self.row(name))?.key == key, "\(name)")
        }
        let branded = Self.row("Milk Chocolate Premium Baking Chips, Milk Chocolate", type: .branded)
        #expect(TypicalPortionTable.entry(for: branded)?.key == "milk chocolate chips")
    }

    /// A typical size fills only a dimension the food's own data leaves empty, and the editor lists
    /// counts lightest first and spoons before the cup.
    @Test func aTypicalSizeFillsOnlyWhatTheFoodLeavesEmpty() {
        let hass = Self.row("Avocado, Hass, peeled, raw", portions: [FoodPortion(amount: 1, unit: "RACC", gramWeight: 140)])
        let hassChoices = RecipePortionPicker.choices(for: hass).options.filter { $0.source == .typicalSize }
        #expect(hassChoices.map(\.label) == ["fruit"] && hassChoices.first?.gramsPerOne == 136)
        let flour = Self.row("Flour, wheat, all-purpose, enriched, bleached", portions: [FoodPortion(amount: 1, unit: "RACC", gramWeight: 30)])
        let flourChoices = RecipePortionPicker.choices(for: flour).options.filter { $0.source == .typicalSize }
        #expect(flourChoices.map { "\($0.label) \($0.gramsPerOne ?? 0)" } == ["tsp 2.6", "tbsp 7.8", "cup 125.0"])
        let butter = Self.row("Butter, stick, unsalted")
        #expect(RecipePortionPicker.choices(for: butter).options.filter { $0.source == .typicalSize }.map(\.label)
                == ["stick", "tsp", "tbsp", "cup"])
        let ownCount = Self.row("Garlic, raw", portions: [FoodPortion(amount: 1, unit: "clove", gramWeight: 3)])
        let ownCountTypical = RecipePortionPicker.choices(for: ownCount).options.filter { $0.source == .typicalSize }
        #expect(ownCountTypical.allSatisfy { $0.dimension == .volume }, "its own clove answers the count: \(ownCountTypical)")
        #expect(ownCountTypical.map(\.label) == ["tsp", "tbsp", "cup"])
        #expect(TypicalPortionTable.options(for: hass, lacking: []).isEmpty)
    }

    /// The importer's fallback: "each" by the default count, a stated spoon by its own grams, any
    /// other volume by the cup; nothing for a mass, a row no entry names, or an amount past the bound.
    @Test func theImporterWeighsALineTheRowCannot() throws {
        let garlic = Self.row("Garlic, raw")
        #expect(TypicalPortionTable.grams(quantity: 3, unit: .each, for: garlic) == 9)
        #expect(TypicalPortionTable.grams(quantity: 1, unit: .teaspoon, for: garlic) == 2.8)
        let flour = Self.row("Flour, wheat, all-purpose, enriched, bleached")
        #expect(TypicalPortionTable.grams(quantity: 2, unit: .cup, for: flour) == 250)
        let halfCup = try #require(TypicalPortionTable.grams(quantity: 0.5, unit: .cup, for: flour))
        #expect(abs(halfCup - 62.5) < 0.001)
        #expect(TypicalPortionTable.grams(quantity: 1, unit: .each, for: flour) == nil, "flour has no count")
        #expect(TypicalPortionTable.grams(quantity: 100, unit: .gram, for: flour) == nil)
        #expect(TypicalPortionTable.grams(quantity: 1, unit: .each, for: Self.row("Bread, banana")) == nil)
        #expect(TypicalPortionTable.grams(quantity: 50, unit: .cup, for: flour) == nil, "past the 3,000 g bound")
        #expect(TypicalPortionTable.grams(quantity: 2, unit: .tablespoon, for: Self.row("Honey")) == 42, "honey's stated tbsp")
    }
}
