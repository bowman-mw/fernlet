// PastedRecipeReaderTests.swift
// FernletTests
//
// AI recipe paste-and-parse (roadmap G1, Phase P4a; owner-approved design 2026-11-13): the
// line-by-line reader, the model answer's conversion, how each line binds (confident / check / no
// match), the editor seed's row notes, and the audit payload. The model itself is not run here.

import Foundation
import Testing
import AIContext
import FernletDomainModel
import FoodCatalog
@testable import AIProviders
@testable import Fernlet

@MainActor
struct PastedRecipeReaderTests {
    private static let english = InputLanguages([.english])
    private static let spanish = InputLanguages([.spanish])

    private static func ramenCatalog() -> (FoodCatalog, FoodItem) {
        let ramen = FoodItem(name: "Ramen", servingSize: 100, servingUnit: "g",
                             macros: Macros(protein: 5, carbs: 10, fat: 2), micronutrients: Micronutrients(),
                             category: "Fixtures", source: .usda, tags: [])
        return (FoodCatalog(source: InMemoryBundledFoodSource([ramen])), ramen)
    }

    // MARK: - Line-by-line reader

    @Test func aPlainRecipeReadsIntoNameServingsIngredientsAndSteps() throws {
        let text = """
        Garlic Ramen Bowls
        A quick weeknight bowl.
        Serves 4
        Ingredients:
        - 200 g ramen
        • 3 cloves garlic, minced
        salt to taste
        Instructions
        1. Boil the ramen.
        2) Fry the garlic and toss.
        """
        let draft = try #require(PastedRecipeReader.readLineByLine(text, languages: Self.english))
        #expect(draft.name == "Garlic Ramen Bowls")
        #expect(draft.notes == "A quick weeknight bowl.")
        #expect(draft.servings == 4)
        #expect(draft.reader == .lineByLine)
        #expect(draft.ingredients.map(\.original) == ["200 g ramen", "3 cloves garlic, minced", "salt to taste"])
        #expect(draft.ingredients[0].quantity == 200 && draft.ingredients[0].unit == "g" && draft.ingredients[0].food == "ramen")
        #expect(draft.ingredients[2].quantity == nil && draft.ingredients[2].food == "salt")
        #expect(draft.steps == ["Boil the ramen.", "Fry the garlic and toss."])
    }

    @Test func withoutHeadingsAmountLinesAreIngredientsAndTheRestAreSteps() throws {
        let text = "Pancakes\n2 cups flour\n2 large eggs\nWhisk everything together until smooth and cook on a hot pan."
        let draft = try #require(PastedRecipeReader.readLineByLine(text, languages: Self.english))
        #expect(draft.name == "Pancakes")
        #expect(draft.ingredients.count == 2)
        #expect(draft.steps == ["Whisk everything together until smooth and cook on a hot pan."])
        #expect(draft.servings == 1)
    }

    @Test func spanishHeadingsAndConnectorsRead() throws {
        let text = "Tortitas\nPara 2 personas\nIngredientes\n2 tazas de harina\nPreparación\nMezclar todo."
        let draft = try #require(PastedRecipeReader.readLineByLine(text, languages: Self.spanish))
        #expect(draft.servings == 2)
        #expect(draft.ingredients.first?.food == "harina")
        #expect(draft.steps == ["Mezclar todo."])
    }

    @Test func textWithNoIngredientLineReadsAsNothing() {
        #expect(PastedRecipeReader.readLineByLine("Just a note about dinner.\nNothing to cook.", languages: Self.english) == nil)
    }

    @Test func longTextIsCutAtTheLimitAndSaysSo() {
        let (cut, wasCut) = PastedRecipeReader.boundedText(String(repeating: "a", count: 4_100))
        #expect(cut.count == PastedRecipeReader.maxPastedCharacters && wasCut)
        let (kept, keptCut) = PastedRecipeReader.boundedText("2 cups flour")
        #expect(kept == "2 cups flour" && !keptCut)
    }

    // MARK: - The model's answer

    @Test func theModelsAnswerIsTrimmedCappedAndReadByTheLineParser() throws {
        let draft = try #require(PastedRecipeReader.modelDraft(
            name: "  Soup  ", servings: 900,
            ingredients: [
                .init(text: "1 1/2 cups broth", amount: "1 1/2", unit: "cups", food: "broth"),
                .init(text: "a pinch of salt", amount: "", unit: "", food: "salt"),
                .init(text: "garnish", amount: "", unit: "", food: "  ")
            ],
            steps: ["Simmer.", "  "], languages: Self.english))
        #expect(draft.name == "Soup")
        #expect(draft.servings == RecipeWebImporter.maxImportedServings)
        #expect(draft.reader == .model)
        #expect(draft.ingredients.count == 2, "a line with no food is dropped")
        #expect(draft.ingredients[0].quantity == 1.5 && draft.ingredients[0].unit == "cup")
        #expect(draft.ingredients[1].quantity == nil && draft.ingredients[1].food == "salt")
        #expect(draft.steps == ["Simmer."])
        #expect(PastedRecipeReader.modelDraft(name: "x", servings: 1, ingredients: [], steps: [], languages: Self.english) == nil)
    }

    @Test func theInstructionsAskForWordsOnlyAndKeepFoodNamesEnglish() {
        let english = PastedRecipeReader.instructions(for: .english)
        #expect(english.contains("Do not output nutrition"))
        #expect(!english.contains("Spanish"))
        let spanish = PastedRecipeReader.instructions(for: AIPromptLanguage(language: .spanish))
        #expect(spanish.contains("Always write each food name in English"))
    }

    // MARK: - Binding

    @Test func eachLineBindsConfidentForCheckOrNotAtAll() {
        let (catalog, ramen) = Self.ramenCatalog()
        let draft = PastedRecipeDraft(name: "Bowl", servings: 1, ingredients: [
            PastedIngredientLine(original: "200 g ramen", quantity: 200, unit: "g", food: "ramen"),
            PastedIngredientLine(original: "2 large ramen", quantity: 2, unit: "each", food: "ramen"),
            PastedIngredientLine(original: "1 cup dragonfruit sauce", quantity: 1, unit: "cup", food: "dragonfruit sauce"),
            PastedIngredientLine(original: "salt to taste", quantity: nil, unit: nil, food: "salt")
        ], steps: [], reader: .model)
        let rows = PastedRecipeReader.rows(for: draft, catalog: catalog)
        #expect(rows.map(\.match) == [.confident, .check, .noMatch, .noMatch])
        #expect(rows[0].input.selectedFoodItemId == ramen.id && rows[0].input.quantity == 200 && rows[0].input.unit == "g")
        #expect(rows[1].input.selectedFoodItemId == ramen.id, "a count the row cannot weigh stays bound, to check")
        #expect(rows[2].input.selectedFoodItemId == nil && rows[2].input.name == "dragonfruit sauce")
        #expect(rows[3].input.selectedFoodItemId == nil && rows[3].input.name == "salt",
                "a line with no amount is never guessed: it waits for a food and an amount")
        #expect(rows[3].original == "salt to taste")
    }

    @Test func aTypicalSizeBindIsBoundToThatSizeAndMarkedToCheck() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount > 100_000, "the shipped catalog must be loaded")
        let line = PastedIngredientLine(original: "3 cloves garlic, minced", quantity: 3, unit: "each", food: "garlic")
        let row = PastedRecipeReader.bind(line, catalog: catalog)
        #expect(row.match == .check)
        #expect(row.input.selectedFoodItemId != nil)
        if let portion = row.input.portion {
            #expect(portion.source == .typicalSize && row.input.quantity == 3)
        } else {
            #expect(row.input.unit == "g", "without a matching menu size the line keeps its typical grams")
        }
    }

    // MARK: - Editor seed

    @Test func theSeedNotesOnlyRowsToLookAtAndANotePassesOnceAnotherFoodIsPicked() throws {
        let (catalog, ramen) = Self.ramenCatalog()
        let draft = PastedRecipeDraft(name: "Bowl", servings: 2, ingredients: [
            PastedIngredientLine(original: "200 g ramen", quantity: 200, unit: "g", food: "ramen"),
            PastedIngredientLine(original: "1 cup dragonfruit sauce", quantity: 1, unit: "cup", food: "dragonfruit sauce")
        ], steps: ["Cook."], reader: .lineByLine, wasShortened: true)
        let seed = PastedRecipeSeed(draft: draft, rows: PastedRecipeReader.rows(for: draft, catalog: catalog))
        #expect(seed.rowNotes.count == 1)
        let unmatched = try #require(seed.firstUnmatchedRowID)
        let note = try #require(seed.rowNotes[unmatched])
        #expect(note.match == .noMatch && note.original == "1 cup dragonfruit sauce")
        var row = try #require(seed.ingredients.first { $0.id == unmatched })
        #expect(note.applies(to: row))
        row.selectedFoodItemId = ramen.id
        #expect(!note.applies(to: row))
        #expect(seed.steps.map(\.text) == ["Cook."])
        let readNote = try #require(PastedReadNote(seed: seed))
        #expect(readNote.readLineByLine && readNote.wasShortened)
    }

    @Test func aModelReadWithinTheLimitOpensWithNoReadNote() {
        let draft = PastedRecipeDraft(name: "Bowl", servings: 1, ingredients: [], steps: [], reader: .model)
        #expect(PastedReadNote(seed: PastedRecipeSeed(draft: draft, rows: [])) == nil)
    }

    // MARK: - Audit payload

    @Test func thePayloadRecordsOnlyTheTextsLength() {
        let payload = RecipeTextParsePayload(pastedTextCharCount: 1_234)
        #expect(payload.payloadKind == "recipe-text-parse")
        #expect(payload.includedFieldNames == ["pastedTextCharCount"])
        let spanish = RecipeTextParsePayload(pastedTextCharCount: 10, promptLanguage: AIPromptLanguage(language: .spanish))
        #expect(spanish.includedFieldNames == ["pastedTextCharCount", "promptLanguage"])
        #expect(!MemoryAgent.allowedPayloadKinds.contains("recipe-text-parse"))
    }
}
