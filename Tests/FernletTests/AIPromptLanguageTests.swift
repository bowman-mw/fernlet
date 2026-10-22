import Foundation
import Testing
import AIContext
@testable import AIProviders
import FernletDomainModel
import FernletScoring
@testable import Fernlet

/// Localization plan §5.1, Phase 3 for Spanish: the on-device model is told which language to work in.
///
/// Two prompt families, two different lines. A PROSE prompt (day summary, companion thought, journal
/// memory line) answers in the app's language, in the glossary's register, with the person's
/// grammatical gender; a CATALOG prompt (dish decomposition, candidate selection, ingredient
/// substitution, the workout adjuster) reads the person's language but keeps every field code
/// matches in English. In English nothing changes — not a byte of any prompt, not a field of any
/// audit row — and an app language the model does not support turns the model off for routing.
struct AIPromptLanguageTests {

    private static let spanishFeminine = AIPromptLanguage(language: .spanish, address: .feminine)
    private static let spanishMasculine = AIPromptLanguage(language: .spanish, address: .masculine)
    private static let spanishCatalog = AIPromptLanguage(language: .spanish)

    // MARK: - The language itself

    @Test func identifiersResolveToFernletsLanguagesOnly() {
        #expect(FernletLanguage(identifier: "es") == .spanish)
        #expect(FernletLanguage(identifier: "es-MX") == .spanish)
        #expect(FernletLanguage(identifier: "es_419") == .spanish)
        #expect(FernletLanguage(identifier: "en-GB") == .english)
        #expect(FernletLanguage(identifier: "fr") == nil)
        #expect(FernletLanguage(identifier: "Base") == nil)
        #expect(FernletLanguage(identifier: "  ") == nil)
    }

    @Test func theAppLanguageIsTheFirstShippedLocalizationFernletKnows() {
        #expect(FernletLanguage.appLanguage(preferredLocalizations: ["fr", "es", "en"]) == .spanish)
        #expect(FernletLanguage.appLanguage(preferredLocalizations: ["fr"]) == .english)
        #expect(FernletLanguage.appLanguage(preferredLocalizations: []) == .english)
        // The test host ships English alone, so the process constant is English, and so is every prompt.
        #expect(FernletLanguage.app == .english)
        #expect(AIPromptLanguage.forApp(addressing: .feminine) == .english)
    }

    @Test func promptNamesAreFrozenEnglish() {
        #expect(FernletLanguage.allCases.map(\.rawValue) == ["en", "es"])
        #expect(FernletLanguage.allCases.map(\.promptName) == ["English", "Spanish"])
    }

    // MARK: - The gate

    @Test func anUnsupportedAppLanguageSendsEveryCallerToItsDeterministicPath() {
        #expect(AIPromptLanguage.resolve(appLanguage: .spanish, modelSupportsLanguage: false, address: .feminine) == nil)
        #expect(AIPromptLanguage.resolve(appLanguage: .spanish, modelSupportsLanguage: true, address: .feminine)
                == Self.spanishFeminine)
        // English is always usable: the instructions themselves are English.
        #expect(AIPromptLanguage.resolve(appLanguage: .english, modelSupportsLanguage: false, address: nil) == .english)
        #expect(OnDeviceModelLanguage.supports(.english))
    }

    @Test func aReadyModelWithoutTheAppsLanguageIsReportedAndRoutedAsUnavailable() {
        let gate = { SystemLanguageModelCapabilityProvider.availability(model: $0, appLanguageSupported: $1) }
        #expect(gate(.available, false) == .languageNotSupported)
        #expect(gate(.available, true) == .available)
        // Every other answer passes through: the device's own reason is the truer one.
        for reason: OnDeviceModelAvailability in [.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unavailable] {
            #expect(gate(reason, false) == reason)
        }
    }

    @Test @MainActor func settingsSaysTheLanguageIsWhyTheHelperIsOff() {
        let presentation = AIStatusPresentation(effective: .ready, availability: .languageNotSupported)
        #expect(presentation == .notAvailableInThisLanguage)
        #expect(presentation.voiceLine == .aiUnavailable)
    }

    // MARK: - English is unchanged

    @Test func englishAddsNoLineAndNoAuditField() {
        #expect(AIPromptLanguage.english.replyInstruction == nil)
        #expect(AIPromptLanguage.english.inputInstruction(keepingEnglish: "x", writingInLanguage: "y") == nil)
        #expect(AIPromptLanguage.english.includedFieldNames.isEmpty)
        // English genders nothing about the person, so an English prompt can never carry an address.
        #expect(AIPromptLanguage(language: .english, address: .feminine).address == nil)
        #expect(AIPromptLanguage.joined("base", nil) == "base")
    }

    @Test func englishPromptsAreByteIdentical() {
        #expect(LaunchPreparationService.daySummaryInstructions(for: Self.daySummary(.english))
                == "You write brief warm wellness day summaries for a companion app called Fernlet. Under 50 words. No advice. No lists. Warm observation only.")
        #expect(LaunchPreparationService.thoughtInstructions(for: Self.thought(.english))
                == "You write one-sentence gentle observations for a wellness companion called Fernlet. Under 20 words. No advice. Just warm noticing. You have honest behavioral context about the user — use it to write something that resonates, not something generic.")
        let journal = FoundationJournalSummaryModel.instructions(for: JournalSummaryPayload(entryText: "x"))
        #expect(journal.hasSuffix("No advice, no judgment, no questions. Write a short note, not a full paragraph."))
        let catalogPrompts = Self.catalogInstructions(.english)
        for prompt in catalogPrompts + [journal] {
            #expect(!prompt.contains("Spanish"))
            #expect(!prompt.contains("The person may write"))
        }
        #expect(catalogPrompts[0].hasSuffix("Set overallConfidence for how well the whole breakdown matches what was eaten."))
        #expect(catalogPrompts[1].hasSuffix("sandwiches usually use 2 bread slices and 2 cheese slices. Keep names short."))
        #expect(catalogPrompts[2].hasSuffix("Do not output any quantities, measurements, or nutrition numbers."))
        #expect(catalogPrompts[3].hasSuffix(#"Give realistic sets (2–6) and reps (e.g. "5", "8-12", or "30 sec")."#))
    }

    @Test func englishPayloadsKeepTheirAuditFields() {
        #expect(Self.daySummary(.english).includedFieldNames
                == ["mealNames", "workoutNames", "sleepQualityLabel", "sleepHours", "journalTagLabel"])
        #expect(Self.thought(.english).includedFieldNames == ["signalSummaries", "journalTagLabel", "filteredMemorySummary"])
        #expect(JournalSummaryPayload(entryText: "x").includedFieldNames == ["entryText"])
        #expect(MealDecompositionPayload(mealDescription: "x", fallbackMealType: nil).includedFieldNames
                == ["mealDescription", "fallbackMealType"])
        #expect(WorkoutAdjustmentPayload(request: "x", currentExercises: [], candidateCount: 1).includedFieldNames
                == ["request", "currentExercises", "candidateCount"])
        #expect(IngredientSubstitutionPayload(recipeName: "x", ingredientToReplace: "y").includedFieldNames
                == ["recipeName", "ingredientToReplace"])
    }

    // MARK: - Spanish prose prompts

    @Test func aSpanishProsePromptAnswersInSpanishWithTuAndThePersonsGender() throws {
        let feminine = try #require(Self.spanishFeminine.replyInstruction)
        #expect(feminine.hasPrefix("Write your reply in Spanish."))
        #expect(feminine.contains("neutral Latin American Spanish"))
        #expect(feminine.contains("with tú, never usted"))
        #expect(feminine.contains("use its feminine form"))
        let masculine = try #require(Self.spanishMasculine.replyInstruction)
        #expect(masculine.contains("use its masculine form"))
        // A prose prompt with no address says nothing about gender rather than guessing one.
        let unaddressed = try #require(Self.spanishCatalog.replyInstruction)
        #expect(!unaddressed.contains("form."))
    }

    @Test func everyProsePromptCarriesTheReplyLineAfterItsEnglishInstructions() throws {
        let line = try #require(Self.spanishFeminine.replyInstruction)
        let prompts = [
            LaunchPreparationService.daySummaryInstructions(for: Self.daySummary(Self.spanishFeminine)),
            LaunchPreparationService.thoughtInstructions(for: Self.thought(Self.spanishFeminine)),
            FoundationJournalSummaryModel.instructions(
                for: JournalSummaryPayload(entryText: "Hoy caminé", promptLanguage: Self.spanishFeminine))
        ]
        for prompt in prompts {
            #expect(prompt.hasSuffix("\n" + line))
            #expect(prompt.hasPrefix("You write"))
        }
    }

    @Test func theAddressIsAGrammaticalInstructionNeverTheProfileValue() throws {
        let prompts = [Self.spanishFeminine, Self.spanishMasculine].compactMap(\.replyInstruction)
        for prompt in prompts {
            for word in ["sex", "female", "male", "woman", "gender"] {
                #expect(!prompt.lowercased().contains(word), "prompt names the profile value: \(word)")
            }
        }
    }

    @Test func aSpanishProsePayloadDeclaresWhatItAdds() {
        #expect(Self.daySummary(Self.spanishFeminine).includedFieldNames.suffix(2) == ["promptLanguage", "termOfAddress"])
        #expect(Self.thought(Self.spanishMasculine).includedFieldNames.suffix(2) == ["promptLanguage", "termOfAddress"])
        #expect(JournalSummaryPayload(entryText: "x", promptLanguage: Self.spanishFeminine).includedFieldNames
                == ["entryText", "promptLanguage", "termOfAddress"])
    }

    // MARK: - Spanish catalog prompts

    @Test func aSpanishCatalogPromptReadsSpanishAndKeepsMatchedFieldsEnglish() {
        let prompts = Self.catalogInstructions(Self.spanishCatalog)
        for prompt in prompts {
            #expect(prompt.contains("\nThe person may write in Spanish.\nAlways write "))
            // A catalog prompt writes nothing about the person, so it never carries a gender.
            #expect(!prompt.contains("feminine") && !prompt.contains("masculine"))
        }
        #expect(prompts[0].contains("Always write ingredient names, preparations, meal types and confidence words in English"))
        #expect(prompts[0].contains("Write the dish name in Spanish."))
        #expect(prompts[1].contains("Always write item names, units and the meal type in English"))
        #expect(prompts[1].contains("Write the meal name in Spanish."))
        #expect(prompts[2].contains("Always write food names in English"))
        #expect(prompts[2].contains("Write each reason in Spanish."))
        // The adjuster has no prose output, and its reps are read back by their English unit word.
        #expect(prompts[3].contains("Always write reps in English"))
        #expect(!prompts[3].contains("Write each") && !prompts[3].contains("tú"))
    }

    @Test func aSpanishCatalogPayloadDeclaresOnlyTheLanguage() {
        let language = Self.spanishCatalog
        #expect(MealDecompositionPayload(mealDescription: "x", fallbackMealType: nil, promptLanguage: language)
            .includedFieldNames == ["mealDescription", "fallbackMealType", "promptLanguage"])
        #expect(FoodSelectionPayload(mealDescription: "x", candidates: [], fallbackMealType: nil, promptLanguage: language)
            .includedFieldNames == ["mealDescription", "candidates", "fallbackMealType", "promptLanguage"])
        #expect(WorkoutAdjustmentPayload(request: "x", currentExercises: [], candidateCount: 1, promptLanguage: language)
            .includedFieldNames == ["request", "currentExercises", "candidateCount", "promptLanguage"])
        #expect(IngredientSubstitutionPayload(recipeName: "x", ingredientToReplace: "y", promptLanguage: language)
            .includedFieldNames == ["recipeName", "ingredientToReplace", "promptLanguage"])
    }

    // MARK: - Fixtures

    private static func daySummary(_ language: AIPromptLanguage) -> DaySummaryPayload {
        DaySummaryPayload(
            mealNames: ["Avena"], workoutNames: [], sleepQualityLabel: "good", sleepHours: 7,
            journalTagLabel: nil, promptLanguage: language
        )
    }

    private static func thought(_ language: AIPromptLanguage) -> CompanionThoughtPayload {
        CompanionThoughtPayload(
            signalSummaries: [AISignalSummary(signalName: "sleep", value: "steady")],
            journalTagLabel: nil, filteredMemorySummary: "", promptLanguage: language
        )
    }

    /// Dish decomposition, candidate selection, ingredient substitution and the workout adjuster, in
    /// that order.
    private static func catalogInstructions(_ language: AIPromptLanguage) -> [String] {
        [
            FoundationDishDecompositionModel.instructions(
                for: MealDecompositionPayload(mealDescription: "pollo con arroz", fallbackMealType: nil, promptLanguage: language)),
            FoundationFoodSelectionModel.instructions(
                for: FoodSelectionPayload(mealDescription: "pollo", candidates: [], fallbackMealType: nil, promptLanguage: language)),
            FoundationIngredientSubstitutionModel.instructions(
                for: IngredientSubstitutionPayload(recipeName: "Pastel", ingredientToReplace: "mantequilla", promptLanguage: language)),
            FoundationWorkoutAdjustmentModel.instructions(
                for: WorkoutAdjustmentPayload(request: "sin barra", currentExercises: [], candidateCount: 1, promptLanguage: language))
        ]
    }
}
