import Foundation
import Testing
import FernletDomainModel
@testable import AIProviders

/// Localization plan §5.2 for Spanish: the deterministic food parsers read Spanish unit words,
/// connectors and plurals — as matching INPUTS only. "2 tazas" still stores the `cup` token, and
/// nothing a person sees changes.
///
/// Spanish is read only while it is an input language (``InputLanguages``: English plus the app's
/// language). The test host ships English alone, so each Spanish case passes `languages:` or binds
/// `InputLanguages.$testOverride`; the English-only cases prove a Spanish word changes nothing for an
/// English-interface user.
struct SpanishFoodParsingTests {
    private static let spanish = InputLanguages([.spanish])

    // MARK: - Input languages

    @Test func englishIsAlwaysFirstAndEachLanguageIsListedOnce() {
        #expect(InputLanguages.englishOnly.languages == [.english])
        #expect(InputLanguages([.spanish, .english, .spanish]).languages == [.english, .spanish])
        #expect(InputLanguages.englishOnly.packs.isEmpty)
        #expect(Self.spanish.packs.map(\.language) == [.spanish])
        // The test host's app language is English, so production input is English alone here.
        #expect(InputLanguages.current == .englishOnly)
        InputLanguages.$testOverride.withValue(Self.spanish) {
            #expect(InputLanguages.current == Self.spanish)
        }
    }

    // MARK: - Units

    @Test func spanishUnitWordsNormalizeToTheFrozenTokens() {
        let cases: [(String, RecipeUnit)] = [
            ("taza", .cup), ("Tazas", .cup), ("cucharada", .tablespoon), ("cda", .tablespoon),
            ("cda.", .tablespoon), ("cdas", .tablespoon), ("cucharadas soperas", .tablespoon),
            ("cucharadita", .teaspoon), ("cdta.", .teaspoon), ("gramos", .gram), ("gr", .gram),
            ("kilos", .kilogram), ("mililitros", .milliliter), ("litro", .liter), ("onzas", .ounce),
            ("libra", .pound), ("vaso", .glass), ("rebanadas", .slice), ("rodaja", .slice),
            ("pieza", .piece), ("trozos", .piece), ("unidades", .each), ("porción", .serving),
            ("raciones", .serving), ("onzas líquidas", .fluidOunce)
        ]
        for (word, unit) in cases {
            #expect(RecipeUnit.normalized(word, languages: Self.spanish) == unit, "\(word)")
        }
    }

    @Test func spanishUnitWordsAreDormantForAnEnglishInterface() {
        for word in ["taza", "cucharada", "gramos", "vaso", "porción"] {
            #expect(RecipeUnit.normalized(word, languages: .englishOnly) == nil, "\(word)")
            #expect(RecipeUnit.normalized(word) == nil, "\(word) read in the English-only test host")
        }
    }

    @Test func everyPersistedTokenStillRoundTripsInSpanish() {
        for unit in RecipeUnit.allCases {
            #expect(RecipeUnit.normalized(unit.rawValue, languages: Self.spanish) == unit)
        }
        // The plural abbreviations the line reader used to fold on its own now live in the one table.
        #expect(RecipeUnit.normalized("tbsps") == .tablespoon)
        #expect(RecipeUnit.normalized("tsps") == .teaspoon)
    }

    @Test func noSpanishUnitSpellingShadowsAnEnglishOne() throws {
        let pack = try #require(LanguagePack.pack(for: .spanish))
        #expect(Set(pack.unitSpellings.keys).isDisjoint(with: RecipeUnit.englishSpellings.keys))
        #expect(RecipeUnit.spellings(languages: Self.spanish).count
                == RecipeUnit.englishSpellings.count + pack.unitSpellings.count)
    }

    // MARK: - Recipe lines

    @Test func aSpanishRecipeLineReadsItsAmountUnitAndFood() throws {
        let cases: [(String, Double, String, String)] = [
            ("2 tazas de harina", 2, "cup", "harina"),
            ("1 cda. de aceite de oliva", 1, "tbsp", "aceite de oliva"),
            ("½ taza de leche", 0.5, "cup", "leche"),
            ("1 1/2 cucharaditas de sal", 1.5, "tsp", "sal"),
            ("200 gramos de pollo", 200, "g", "pollo"),
            ("3 rebanadas de pan", 3, "slice", "pan"),
            ("2 cucharadas soperas de azúcar", 2, "tbsp", "azúcar")
        ]
        for (line, quantity, unit, name) in cases {
            let parsed = try #require(RecipeWebImporter.parseIngredientLine(line, languages: Self.spanish), "\(line)")
            #expect(parsed.quantity == quantity, "\(line)")
            #expect(parsed.unit == unit, "\(line)")
            #expect(parsed.name == name, "\(line)")
            #expect(parsed.unitReading == .stated, "\(line)")
        }
    }

    @Test func aSpanishCountWordBindsEach() throws {
        let parsed = try #require(RecipeWebImporter.parseIngredientLine("3 dientes de ajo", languages: Self.spanish))
        #expect(parsed.unit == "each")
        #expect(parsed.unitReading == .countWord)
        #expect(parsed.name == "ajo")
    }

    @Test func englishRecipeLinesReadTheSameInSpanish() throws {
        for languages in [InputLanguages.englishOnly, Self.spanish] {
            let eggs = try #require(RecipeWebImporter.parseIngredientLine("2 large eggs", languages: languages))
            #expect(eggs.unit == "each" && eggs.name == "eggs")
            let flour = try #require(RecipeWebImporter.parseIngredientLine("2 cups of flour", languages: languages))
            #expect(flour.unit == "cup" && flour.name == "flour")
            let oil = try #require(RecipeWebImporter.parseIngredientLine("2 tbsps olive oil", languages: languages))
            #expect(oil.unit == "tbsp" && oil.unitReading == .stated)
            let lemon = try #require(RecipeWebImporter.parseIngredientLine("1 lemon", languages: languages))
            #expect(lemon.unitReading == .bareCount)
        }
    }

    @Test func theLineReaderTriesLongerUnitWordsFirst() {
        let alternatives = RecipeWebImporter.unitAlternatives(languages: Self.spanish)
        // An alternation takes its first match: "cucharadas" before "cda", "grams" before "g".
        let counts = alternatives.map { $0.replacingOccurrences(of: #"\s+"#, with: " ").count }
        #expect(counts == counts.sorted(by: >))
        #expect(alternatives.contains(#"cucharadas\s+soperas"#))
        #expect(alternatives.contains(#"fl\s+oz"#) && alternatives.contains("floz"))
    }

    // MARK: - Meal connectors

    @Test func aSpanishMealSplitsAtYAndCon() {
        let items = { (text: String) in MealItemSplitter.items(from: text, languages: Self.spanish) }
        #expect(items("pollo con arroz y frijoles") == ["pollo", "arroz", "frijoles"])
        #expect(items("huevos revueltos y pan tostado") == ["huevos revueltos", "pan tostado"])
        #expect(items("Café con leche") == ["Café", "leche"])
    }

    @Test func aModifierAfterConDescribesTheFoodBeforeIt() {
        let items = { (text: String) in MealItemSplitter.items(from: text, languages: Self.spanish) }
        #expect(items("hamburguesa con doble queso") == ["hamburguesa con doble queso"])
        #expect(items("tacos con 2 tortillas") == ["tacos con 2 tortillas"])
        #expect(items("burrito con extra queso y una soda") == ["burrito con extra queso", "una soda"])
    }

    @Test func aDishWhoseNameCarriesConNeverSplits() {
        let items = { (text: String) in MealItemSplitter.items(from: text, languages: Self.spanish) }
        #expect(items("chili con carne y arroz") == ["chili con carne", "arroz"])
        #expect(items("Arroz con leche") == ["Arroz con leche"])
    }

    @Test func spanishConnectorsAreDormantForAnEnglishInterface() {
        #expect(MealItemSplitter.items(from: "pollo con arroz y frijoles", languages: .englishOnly)
                == ["pollo con arroz y frijoles"])
        #expect(MealItemSplitter.items(from: "pollo con arroz y frijoles") == ["pollo con arroz y frijoles"])
        // English input is read the same way whatever else is active.
        #expect(MealItemSplitter.items(from: "eggs and toast with jam", languages: Self.spanish) == ["eggs", "toast", "jam"])
        #expect(MealItemSplitter.items(from: "burger with 2 patties", languages: Self.spanish) == ["burger with 2 patties"])
    }

    // MARK: - Plurals

    @Test func spanishPluralsReachTheirSingulars() throws {
        let pack = try #require(LanguagePack.pack(for: .spanish))
        #expect(pack.singularForms(of: "manzanas").first == "manzana")
        #expect(pack.singularForms(of: "huevos").first == "huevo")
        #expect(pack.singularForms(of: "tomates").first == "tomate")
        #expect(pack.singularForms(of: "limones").first == "limon")
        #expect(pack.singularForms(of: "frijoles").first == "frijol")
        #expect(pack.singularForms(of: "panes").first == "pan")
        #expect(pack.singularForms(of: "nueces").first == "nuez")
        // Not plurals: too short, or no rule's letter before the ending.
        #expect(pack.singularForms(of: "res").isEmpty)
        #expect(pack.singularForms(of: "mis").isEmpty)
        #expect(pack.singularForms(of: "arroz").isEmpty)
    }

    @Test func searchMatchVariantsAddSpanishSingularsOnlyInSpanish() {
        #expect(FoodItemSearch.matchVariants(for: "limones") == ["limones", "limone"])
        #expect(FoodItemSearch.matchVariants(for: "eggs") == ["eggs", "egg"])
        InputLanguages.$testOverride.withValue(Self.spanish) {
            #expect(FoodItemSearch.matchVariants(for: "limones") == ["limones", "limone", "limon"])
            #expect(FoodItemSearch.matchVariants(for: "nueces") == ["nueces", "nuece", "nuez"])
            // English tokens keep their English variants first.
            #expect(FoodItemSearch.matchVariants(for: "eggs") == ["eggs", "egg"])
        }
    }
}
