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
//
// Fix round 1 (findings s2-C-F4B-C3, s2-C-F4B-C4, s2-L-F4b-DT-1): a USDA row must also be filed where
// its ingredient is (a chocolate egg is "Confectionery Products", an oat milk "Plant Based Milk"), and
// "without skin" / "with peel" no longer hide the thin potato and cucumber rows. Those pins read the
// SHIPPED rows by exact name, so the category and name are the catalog's own.

import Foundation
import SQLite3
import Testing
import FernletDomainModel
import FoodCatalog

/// Pins the typical-size table's citations, matching and lookups.
struct TypicalPortionTableTests {
    static let vegetables = "Vegetables and Vegetable Products"
    static let fruits = "Fruits and Fruit Juices"
    static let dairy = "Dairy and Egg Products"
    static let grains = "Cereal Grains and Pasta"

    static func row(_ name: String, category: String = vegetables, type: FoodDataType = .srLegacy,
                    source: FoodItemSource = .usda, portions: [FoodPortion] = []) -> FoodItem {
        FoodItem(name: name, servingSize: 100, servingUnit: "g", macros: Macros(protein: 5, carbs: 10, fat: 2),
                 micronutrients: Micronutrients(), category: category, source: source, dataType: type, tags: [],
                 portions: portions)
    }

    /// Every shipped row whose name is exactly `name`, hydrated through the catalog (so its category,
    /// source and load-time shims are the app's own). Empty when the name is not in the file.
    static func shippedRows(named name: String, catalog: FoodCatalog) -> [FoodItem] {
        var handle: OpaquePointer?
        let path = FoodCatalogFileProbe.shippedCatalogURL.path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return []
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT id FROM food WHERE name = ? LIMIT 20;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, name)
        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqliteColumnText(stmt, 0), let id = UUID(uuidString: text) { ids.append(id) }
        }
        return catalog.items(ids: ids)
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
            // A person's own food carries no USDA category, so only the key's words and head decide.
            let named = Self.row(key.prefix(1).uppercased() + key.dropFirst(), type: .branded, source: .manual)
            #expect(TypicalPortionTable.entry(for: named)?.key == key, "\"\(key)\" matched \(TypicalPortionTable.entry(for: named)?.key ?? "nothing")")
        }
        #expect(TypicalPortionTable.entries.allSatisfy { !$0.portions.isEmpty })
    }

    /// The thin rows the corpus lands on are their ingredient; dishes, processed forms and look-alikes
    /// are not.
    @Test func aRowIsTheIngredientItsHeadNounNames() {
        let expected: [(String, String, String?)] = [
            ("Avocado, Hass, peeled, raw", Self.fruits, "avocado"), ("Garlic, raw", Self.vegetables, "garlic"),
            ("Flour, wheat, all-purpose, enriched, bleached", Self.grains, "all purpose flour"),
            ("Tomato, roma", Self.vegetables, "roma tomato"), ("Peppers, bell, green, raw", Self.vegetables, "bell pepper"),
            ("Chicken, thigh, boneless, skinless, raw", "Poultry Products", "chicken thigh"),
            ("Butter, stick, unsalted", Self.dairy, "butter"), ("Peanut butter, creamy", "Legumes and Legume Products", "peanut butter"),
            ("Apples, fuji, with skin, raw", Self.fruits, "apple"), ("Celery, raw", Self.vegetables, "celery"),
            ("Egg, white, raw, fresh", Self.dairy, "egg white"), ("Sweet potato, raw, unprepared", Self.vegetables, "sweet potato"),
            ("Tomato, paste, canned, without salt added", Self.vegetables, "tomato paste"),
            ("Rice, brown, long grain, unenriched, raw", Self.grains, "brown rice"),
            ("Oats, whole grain, rolled, old fashioned", Self.grains, "oats"),
            ("Bread, banana", "Baked Products", nil), ("Bananas, dehydrated, or banana powder", Self.fruits, nil),
            ("Lemon grass (citronella), raw", Self.vegetables, nil), ("Cookies, chocolate chip, dry mix", "Baked Products", nil),
            ("Spices, garlic powder", "Spices and Herbs", nil), ("Carrots, baby, raw", Self.vegetables, nil),
            ("Onions, spring or scallions (includes tops and bulb), raw", Self.vegetables, nil),
            ("Rice, white, long-grain, regular, cooked", Self.grains, nil), ("Oats, whole grain, steel cut", Self.grains, nil),
            ("Lemon juice, raw", Self.fruits, nil), ("Onion rings, breaded, par fried, frozen", Self.vegetables, nil),
            // The ingredient's name in the wrong aisle is not the ingredient (fix round 1).
            ("Avocado, Hass, peeled, raw", "Confectionery Products", nil), ("Garlic, raw", "Canned Vegetables", nil)
        ]
        for (name, category, key) in expected {
            #expect(TypicalPortionTable.entry(for: Self.row(name, category: category))?.key == key, "\(name) in \(category)")
        }
        let branded = Self.row("Milk Chocolate Premium Baking Chips, Milk Chocolate",
                               category: "Baking Decorations & Dessert Toppings", type: .branded)
        #expect(TypicalPortionTable.entry(for: branded)?.key == "milk chocolate chips")
        let own = Self.row("Avocado", category: "custom ingredient", type: .branded, source: .manual)
        #expect(TypicalPortionTable.entry(for: own)?.key == "avocado", "a person's own food has no USDA aisle to check")
    }

    /// Fix round 1, on the SHIPPED rows the two reviews named: the thin potato and cucumber rows that
    /// "without skin" / "with peel" used to hide are their vegetable; the sweets, nut and fruit butters,
    /// cereals, oat milk, sauces, mixes and a seed spice whose names end in an entry's noun are not.
    @Test func shippedRowsTheReviewsNamedAreOrAreNotTheIngredient() {
        let catalog = FoodCatalog.bundled()
        let expected: [(String, String?)] = [
            ("Potatoes, russet, without skin, raw", "potato"), ("Potatoes, red, without skin, raw", "potato"),
            ("Potatoes, gold, without skin, raw", "potato"), ("Cucumber, with peel, raw", "cucumber"),
            ("Sesame butter, creamy", nil), ("Chocolaty Real Hazelnut Butter", nil), ("Plum Butter, Plum", nil),
            ("Cacao Butter", nil), ("Organic Coconut Butter, Coconut", nil), ("300 MINI BABA BUTTER WITH CUP 1.4\"", nil),
            ("Au Gratin Potatoes", nil), ("Betty Crocker Sour Cream & Chives Potatoes", nil), ("Whole Potatoes", nil),
            ("Honey Nut Crispy Oats", nil), ("Barista Edition Oat, Barista Edition", nil),
            ("Custard-apple, (bullock's-heart), raw", nil), ("Spices, celery seed", nil),
            ("Cadbury Mini Eggs Chocolate Egg", nil), ("Cadbury Creme Egg Chocolate Egg", nil), ("Milk Chocolate Eggs", nil),
            ("Candy Filled Easter Eggs", nil), ("Bagels Egg", nil), ("Gummy Carrots", nil), ("Ground Chicken Breast", nil),
            ("Prego Sauces Mushroom", nil), ("Prego Sauces Garlic", nil), ("Prego Sauces Tomato", nil)
        ]
        for (name, key) in expected {
            let rows = Self.shippedRows(named: name, catalog: catalog)
            #expect(!rows.isEmpty, "\(name) is not in the shipped catalog")
            for row in rows {
                #expect(TypicalPortionTable.entry(for: row)?.key == key, "\(name) (\(row.category))")
            }
        }
        let potato = Self.shippedRows(named: "Potatoes, russet, without skin, raw", catalog: catalog).first
        let counts = potato.map { RecipePortionPicker.choices(for: $0).options.filter { $0.source == .typicalSize } } ?? []
        #expect(counts.map(\.label) == ["small", "medium", "large"], "a russet offers USDA's typical potato sizes: \(counts)")
    }

    /// A typical size fills only a dimension the food's own data leaves empty, and the editor lists
    /// counts lightest first and spoons before the cup.
    @Test func aTypicalSizeFillsOnlyWhatTheFoodLeavesEmpty() {
        let hass = Self.row("Avocado, Hass, peeled, raw", category: Self.fruits,
                            portions: [FoodPortion(amount: 1, unit: "RACC", gramWeight: 140)])
        let hassChoices = RecipePortionPicker.choices(for: hass).options.filter { $0.source == .typicalSize }
        #expect(hassChoices.map(\.label) == ["fruit"] && hassChoices.first?.gramsPerOne == 136)
        let flour = Self.row("Flour, wheat, all-purpose, enriched, bleached", category: Self.grains,
                             portions: [FoodPortion(amount: 1, unit: "RACC", gramWeight: 30)])
        let flourChoices = RecipePortionPicker.choices(for: flour).options.filter { $0.source == .typicalSize }
        #expect(flourChoices.map { "\($0.label) \($0.gramsPerOne ?? 0)" } == ["tsp 2.6", "tbsp 7.8", "cup 125.0"])
        let butter = Self.row("Butter, stick, unsalted", category: Self.dairy)
        #expect(RecipePortionPicker.choices(for: butter).options.filter { $0.source == .typicalSize }.map(\.label)
                == ["stick", "tsp", "tbsp", "cup"])
        let ownCount = Self.row("Garlic, raw", portions: [FoodPortion(amount: 1, unit: "clove", gramWeight: 3)])
        let ownCountTypical = RecipePortionPicker.choices(for: ownCount).options.filter { $0.source == .typicalSize }
        #expect(ownCountTypical.allSatisfy { $0.dimension == .volume }, "its own clove answers the count: \(ownCountTypical)")
        #expect(ownCountTypical.map(\.label) == ["tsp", "tbsp", "cup"])
        #expect(TypicalPortionTable.options(for: hass, lacking: []).isEmpty)
    }

    /// Every category an entry admits is one the shipped catalog files rows under — a typo would admit
    /// nothing, silently (fix round 1).
    @Test func everyAdmittedCategoryIsTheCatalogsOwn() throws {
        var handle: OpaquePointer?
        let path = FoodCatalogFileProbe.shippedCatalogURL.path
        let opened = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(handle) }
        try #require(opened == SQLITE_OK && handle != nil, "the shipped catalog must open")
        var stmt: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, "SELECT DISTINCT category FROM food LIMIT 2000;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        try #require(prepared == SQLITE_OK)
        var shipped: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqliteColumnText(stmt, 0) { shipped.insert(text) }
        }
        try #require(shipped.count > 100, "the shipped catalog's categories must be read")
        let admitted = Set(TypicalPortionTable.entries.flatMap(\.categories))
        #expect(admitted.subtracting(shipped).isEmpty, "\(admitted.subtracting(shipped).sorted())")
        #expect(TypicalPortionTable.entries.allSatisfy { !$0.categories.isEmpty })
    }

    /// The importer's fallback: "each" by the default count, a stated spoon by its own grams, any
    /// other volume by the cup; nothing for a mass, a row no entry names, or an amount past the bound.
    @Test func theImporterWeighsALineTheRowCannot() throws {
        let garlic = Self.row("Garlic, raw")
        #expect(TypicalPortionTable.grams(quantity: 3, unit: .each, for: garlic) == 9)
        #expect(TypicalPortionTable.grams(quantity: 1, unit: .teaspoon, for: garlic) == 2.8)
        let flour = Self.row("Flour, wheat, all-purpose, enriched, bleached", category: Self.grains)
        #expect(TypicalPortionTable.grams(quantity: 2, unit: .cup, for: flour) == 250)
        let halfCup = try #require(TypicalPortionTable.grams(quantity: 0.5, unit: .cup, for: flour))
        #expect(abs(halfCup - 62.5) < 0.001)
        #expect(TypicalPortionTable.grams(quantity: 1, unit: .each, for: flour) == nil, "flour has no count")
        #expect(TypicalPortionTable.grams(quantity: 100, unit: .gram, for: flour) == nil)
        #expect(TypicalPortionTable.grams(quantity: 1, unit: .each, for: Self.row("Bread, banana", category: "Baked Products")) == nil)
        #expect(TypicalPortionTable.grams(quantity: 50, unit: .cup, for: flour) == nil, "past the 3,000 g bound")
        #expect(TypicalPortionTable.grams(quantity: 2, unit: .tablespoon, for: Self.row("Honey", category: "Sweets")) == 42,
                "honey's stated tbsp")
    }
}
