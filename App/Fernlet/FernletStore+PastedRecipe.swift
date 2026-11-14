// FernletStore+PastedRecipe.swift
// Fernlet
//
// AI recipe paste-and-parse (roadmap G1, Phase P4a; owner-approved design 2026-11-13): the Import
// recipe screen's text field reads pasted recipe text (``AIProviders/PastedRecipeReader``) and opens
// the manual recipe editor pre-filled with it. Nothing is saved until the person taps Save.

import Foundation
import AIContext
import AIProviders
import FernletDomainModel
import FernletUI
import SwiftUI

/// What the manual recipe editor opens with for pasted text: the draft's name, servings, notes and
/// steps, each ingredient's editor row, and a note on every row the person should look at.
struct PastedRecipeSeed {
    /// The note a pasted row carries while it still holds what the reader put there.
    struct RowNote: Equatable {
        /// How the line bound.
        let match: PastedIngredientMatch
        /// The line as pasted.
        let original: String
        /// The food the row was seeded with (nil for a line nothing matched). The note shows only while
        /// the row still holds it — picking another food answers the question.
        let seededFoodItemId: UUID?

        func applies(to row: ManualRecipeIngredientInput) -> Bool {
            row.selectedFoodItemId == seededFoodItemId
        }
    }

    let name: String
    let servings: Int
    let notes: String
    let steps: [RecipeStep]
    let ingredients: [ManualRecipeIngredientInput]
    /// Keyed by the row's id; confident rows carry none.
    let rowNotes: [UUID: RowNote]
    /// The text was read line by line (AI off, resting or failed).
    let readLineByLine: Bool
    /// The text was longer than the reader takes and was cut.
    let wasShortened: Bool

    init(draft: PastedRecipeDraft, rows: [PastedIngredientRow]) {
        name = draft.name
        servings = draft.servings
        notes = draft.notes
        steps = draft.steps.map { RecipeStep(text: $0) }
        ingredients = rows.map(\.input)
        var notesByRow: [UUID: RowNote] = [:]
        for row in rows where row.match != .confident {
            notesByRow[row.input.id] = RowNote(
                match: row.match, original: row.original, seededFoodItemId: row.input.selectedFoodItemId)
        }
        rowNotes = notesByRow
        readLineByLine = draft.reader == .lineByLine
        wasShortened = draft.wasShortened
    }

    /// The first row nothing matched, which the editor opens expanded so its suggestions show.
    var firstUnmatchedRowID: UUID? {
        ingredients.first { rowNotes[$0.id]?.match == .noMatch }?.id
    }
}

extension FernletStore {
    /// Reads pasted recipe text and binds its ingredients against the catalog; nil when no ingredient
    /// line was found. Runs the on-device model only when AI is not off (a user tap, standard tier).
    func pastedRecipeSeed(from text: String) async -> PastedRecipeSeed? {
        guard let draft = await PastedRecipeReader.read(
            text, aiEnabled: settings.aiStatus != .off, gate: aiGate, promptLanguage: AIPromptLanguage.forApp()
        ) else { return nil }
        return PastedRecipeSeed(draft: draft, rows: PastedRecipeReader.rows(for: draft, catalog: foodCatalog))
    }
}

/// The line a pasted recipe's editor opens with when the reading needs a word: it was read line by
/// line (AI off, resting or failed), and/or the text was cut at the reader's limit. Nil when neither.
struct PastedReadNote: Equatable {
    let readLineByLine: Bool
    let wasShortened: Bool

    init?(seed: PastedRecipeSeed) {
        guard seed.readLineByLine || seed.wasShortened else { return nil }
        readLineByLine = seed.readLineByLine
        wasShortened = seed.wasShortened
    }

    var text: Text {
        switch (readLineByLine, wasShortened) {
        case (true, true):
            Text("The quiet helper is off or resting, so I read this line by line, and only its first part because it was long. Check the name, ingredients and steps.")
        case (true, false):
            Text("The quiet helper is off or resting, so I read this line by line. Check the name, ingredients and steps.")
        default:
            Text("The text was long, so I read only its first part. Check that nothing is missing.")
        }
    }
}

/// The note under a pasted ingredient row the person should look at (``PastedRecipeSeed/RowNote``).
struct PastedRowNoteView: View {
    let note: PastedRecipeSeed.RowNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            WorldSpriteView(sprite: WorldSprites.pen, scale: 1)
                .accessibilityHidden(true)
            Group {
                switch note.match {
                case .noMatch:
                    Text("Pick a food for “\(note.original)”.")
                default:
                    Text("Check this match. You pasted “\(note.original)”.")
                }
            }
            .font(FernletFramedFont.note)
            .foregroundStyle(WorldPalette.dim)
            .fernletWrappingText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recipeEditor.pastedRowNote")
    }
}
