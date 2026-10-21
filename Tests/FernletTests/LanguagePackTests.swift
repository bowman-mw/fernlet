import Foundation
import Testing
import FernletDomainModel

/// Every language beyond English has a well-formed matching pack (localization plan §5.2).
///
/// The packs are the modular half of Phase 3: a new language is a `LanguagePack+<Language>.swift`
/// and one line in `LanguagePack.pack(for:)`, and no engine changes. These checks are what make that
/// safe: a key the engines' fold would never produce can never match, so a pack written with an
/// accent or a capital letter in a key would silently do nothing.
struct LanguagePackTests {

    @Test func everyLanguageButEnglishHasAPack() {
        #expect(LanguagePack.pack(for: .english) == nil)
        for language in FernletLanguage.allCases where language != .english {
            #expect(LanguagePack.pack(for: language)?.language == language, "\(language) has no pack")
        }
        #expect(LanguagePack.all.map(\.language) == FernletLanguage.allCases.filter { $0 != .english })
    }

    @Test func everyPackFillsItsFoodTextTables() {
        for pack in LanguagePack.all {
            #expect(!pack.unitSpellings.isEmpty, "\(pack.language): no unit words")
            #expect(!pack.mealJoiners.isEmpty, "\(pack.language): no word for \"and\"")
            #expect(!pack.mealCompanions.isEmpty, "\(pack.language): no word for \"with\"")
            #expect(!pack.pluralRules.isEmpty, "\(pack.language): no plural rule")
        }
    }

    @Test func everyKeyIsAlreadyInTheFoldedFormTheEnginesLookUp() {
        for pack in LanguagePack.all {
            let words = Array(pack.unitSpellings.keys) + Array(pack.countWords) + pack.quantityConnectors
                + pack.mealJoiners + pack.mealCompanions + pack.companionModifiers + pack.joinedDishNames
            for word in words {
                #expect(word == LanguagePack.folded(word) && !word.isEmpty, "\(pack.language): \"\(word)\" is not folded")
            }
            for rule in pack.pluralRules {
                #expect(rule.suffix == LanguagePack.folded(rule.suffix) && !rule.suffix.isEmpty)
            }
        }
    }

    @Test func everyPackFillsItsScreenTermsInTheFormTheScreensNormalizeTo() {
        for pack in LanguagePack.all {
            #expect(!pack.clinicalStems.isEmpty, "\(pack.language): no clinical-language terms")
            #expect(!pack.blockedNameStems.isEmpty, "\(pack.language): no blocked name terms")
            let terms = pack.clinicalStems + pack.clinicalWholeWords + pack.blockedNameStems + pack.blockedNameWholeWords
            for term in terms {
                // Both screens strip every separator, so a term must be lowercase letters and digits.
                #expect(!term.isEmpty && term.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII && !$0.isUppercase },
                        "\(pack.language): \"\(term)\" cannot match normalized text")
            }
            // A whole word that is also a stem would be read twice; one list says how a term matches.
            #expect(Set(pack.clinicalStems).isDisjoint(with: pack.clinicalWholeWords))
            #expect(Set(pack.blockedNameStems).isDisjoint(with: pack.blockedNameWholeWords))
        }
    }

    @Test func noPackShadowsAnEnglishUnitOrReadsAConnectorAsAUnit() {
        for pack in LanguagePack.all {
            #expect(Set(pack.unitSpellings.keys).isDisjoint(with: RecipeUnit.englishSpellings.keys), "\(pack.language)")
            let connectors = Set(pack.mealJoiners + pack.mealCompanions + pack.quantityConnectors)
            #expect(connectors.isDisjoint(with: pack.unitSpellings.keys), "\(pack.language)")
            #expect(connectors.isDisjoint(with: pack.countWords), "\(pack.language)")
        }
    }

    @Test func everyProtectedDishNameCarriesOneOfThePacksConnectors() {
        for pack in LanguagePack.all {
            let connectors = Set(pack.mealJoiners + pack.mealCompanions)
            for name in pack.joinedDishNames {
                #expect(name.split(separator: " ").contains { connectors.contains(String($0)) },
                        "\(pack.language): \"\(name)\" protects nothing")
            }
        }
    }

    @Test func foldingIsLocaleIndependentAndCollapsesWhitespace() {
        #expect(LanguagePack.folded("  Cucharadíta\t SOPERA ") == "cucharadita sopera")
        #expect(LanguagePack.folded("Porción") == "porcion")
        #expect(LanguagePack.folded("İ") == LanguagePack.folded("i"))
    }
}
