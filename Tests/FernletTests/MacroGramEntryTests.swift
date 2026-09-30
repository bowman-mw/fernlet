import Foundation
import Testing
import FernletDomainModel

/// The typed-grams rule behind every ingredient macro field (2026-09-29): "3.4" and "3,4" both mean
/// 3.4 g in every shipped locale, garbage and negatives never commit, and the prefill the field shows
/// always parses back to the value it came from.
struct MacroGramEntryTests {

    private static let locales = ["en_US", "de_DE", "fr_FR", "es_ES"].map(Locale.init(identifier:))
    private static let english = Locale(identifier: "en_US")
    private static let german = Locale(identifier: "de_DE")
    private static let ingredientRange = 0.0...250.0

    // MARK: - Parsing

    @Test func eitherSeparatorParsesInEveryShippedLocale() {
        for locale in Self.locales {
            #expect(MacroGramEntry.parse("3.4", in: Self.ingredientRange, locale: locale) == 3.4, "\(locale.identifier)")
            #expect(MacroGramEntry.parse("3,4", in: Self.ingredientRange, locale: locale) == 3.4, "\(locale.identifier)")
            #expect(MacroGramEntry.parse(" 3.4 ", in: Self.ingredientRange, locale: locale) == 3.4, "\(locale.identifier)")
            #expect(MacroGramEntry.parse("12", in: Self.ingredientRange, locale: locale) == 12, "\(locale.identifier)")
        }
    }

    @Test func typedValuesAreStoredToATenthOfAGram() {
        #expect(MacroGramEntry.parse("0,05", in: Self.ingredientRange, locale: Self.german) == 0.1)
        #expect(MacroGramEntry.parse("3.44", in: Self.ingredientRange, locale: Self.english) == 3.4)
        #expect(MacroGramEntry.parse("3.45", in: Self.ingredientRange, locale: Self.english) == 3.5)
        #expect(MacroGramEntry.parse("0.04", in: Self.ingredientRange, locale: Self.english) == 0)
        #expect(MacroGramEntry.quantized(-0.0).sign == .plus)
        #expect(MacroGramEntry.quantized(.nan) == 0)
        #expect(MacroGramEntry.quantized(.infinity) == 0)
    }

    @Test func garbageNeverCommits() {
        let garbage = ["3.4.5", "3,4,5", "abc", "", "  ", "1e3", "inf", "nan", "0x1p3", "12g", "3..4",
                       String(repeating: "1", count: 40)]
        for text in garbage {
            #expect(MacroGramEntry.parse(text, in: Self.ingredientRange, locale: Self.english) == nil, "\(text)")
            #expect(MacroGramEntry.parse(text, in: Self.ingredientRange, locale: Self.german) == nil, "\(text)")
        }
    }

    @Test func negativesNeverCommitEvenAsZero() {
        for text in ["-3", "-0", "-0,5", " -3.4", "-0.0"] {
            #expect(MacroGramEntry.parse(text, in: Self.ingredientRange, locale: Self.english) == nil, "\(text)")
        }
    }

    @Test func theRangeIsCheckedAfterRounding() {
        #expect(MacroGramEntry.parse("250", in: Self.ingredientRange, locale: Self.english) == 250)
        #expect(MacroGramEntry.parse("251", in: Self.ingredientRange, locale: Self.english) == nil)
        #expect(MacroGramEntry.parse("250.04", in: Self.ingredientRange, locale: Self.english) == 250)
        #expect(MacroGramEntry.parse("250.05", in: Self.ingredientRange, locale: Self.english) == nil)
        // "1,500" is ambiguous: 1500 in en (out of range), 1.5 in de.
        #expect(MacroGramEntry.parse("1,500", in: Self.ingredientRange, locale: Self.english) == nil)
        #expect(MacroGramEntry.parse("1,500", in: Self.ingredientRange, locale: Self.german) == 1.5)
    }

    @Test func wholeGramModeRefusesAFractionRatherThanRoundingIt() {
        #expect(MacroGramEntry.parse("3.4", in: 0...300, allowsDecimals: false, locale: Self.english) == nil)
        #expect(MacroGramEntry.parse("3,4", in: 0...300, allowsDecimals: false, locale: Self.german) == nil)
        #expect(MacroGramEntry.parse("12", in: 0...300, allowsDecimals: false, locale: Self.english) == 12)
        #expect(MacroGramEntry.parse("-12", in: 0...300, allowsDecimals: false, locale: Self.english) == nil)
    }

    // MARK: - Display

    @Test func displayUsesTheLocaleSeparatorAndDropsAWholeNumbersPoint() {
        #expect(MacroGramEntry.display(3.4, locale: Self.english) == "3.4")
        #expect(MacroGramEntry.display(3.4, locale: Self.german) == "3,4")
        #expect(MacroGramEntry.display(3.0, locale: Self.english) == "3")
        #expect(MacroGramEntry.display(0, locale: Self.english) == "0")
        #expect(MacroGramEntry.display(-0.0, locale: Self.english) == "0")
        #expect(MacroGramEntry.display(250, locale: Self.german) == "250")
        #expect(MacroGramEntry.display(1234, locale: Self.english) == "1234")
        #expect(MacroGramEntry.display(3.45, locale: Self.english) == "3.5")
        #expect(MacroGramEntry.display(.nan, locale: Self.english) == "0")
    }

    @Test func everyDisplayedValueParsesBackToItselfInItsOwnLocale() {
        let values: [Double] = [0, 0.1, 0.5, 1, 3.4, 9.9, 12.5, 99.9, 100, 199.9, 250]
        for locale in Self.locales {
            for value in values {
                let shown = MacroGramEntry.display(value, locale: locale)
                #expect(MacroGramEntry.parse(shown, in: Self.ingredientRange, locale: locale) == value,
                        "\(value) shown as \(shown) in \(locale.identifier)")
            }
        }
    }

    // MARK: - The quantity beside the grams (fix round 1, 2026-09-30)

    @Test func aQuantityUsesTheSameSeparatorAsTheGramsBesideIt() {
        for locale in Self.locales {
            let separator = MacroGramEntry.display(3.4, locale: locale).contains(",") ? "," : "."
            #expect(RecipeQuantityDisplay.display(1.5, locale: locale) == "1\(separator)5", "\(locale.identifier)")
            let line = "\(RecipeQuantityDisplay.display(2.5, locale: locale)) tbsp · P\(MacroGramEntry.display(3.4, locale: locale))g"
            #expect(line == "2\(separator)5 tbsp · P3\(separator)4g", "\(locale.identifier)")
        }
        #expect(RecipeQuantityDisplay.display(40, locale: Self.english) == "40")
        #expect(RecipeQuantityDisplay.display(0.25, locale: Self.german) == "0,25")
        #expect(RecipeQuantityDisplay.display(1.0 / 3.0, locale: Self.english) == "0.33")
        #expect(RecipeQuantityDisplay.display(1_500, locale: Self.german) == "1500")   // never grouped
        #expect(RecipeQuantityDisplay.display(.nan, locale: Self.english) == "0")
    }
}
