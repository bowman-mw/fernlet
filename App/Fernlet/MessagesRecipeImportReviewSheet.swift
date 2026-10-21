import FernletExchange
import FernletDomainModel
import FernletUI
import SwiftUI

/// Fernlet-owned confirmation for a recipe received in Messages. The actual import remains in the
/// canonical exchange service, which uses the warm process-wide store installed by the UI loader.
///
/// Save confirms itself (report B22, 2026-10-20): a saved recipe swaps the button for the "added"
/// line and plays `done`, holds for a beat, closes, and VoiceOver hears the line once the close has
/// settled; an error plays `failed` and is spoken beside the red line; a save whose review could not be
/// cleared plays `caveat` (``ImportReviewLanding``). Cancel plays nothing.
struct MessagesRecipeImportReviewSheet: View {
    let record: FernletMessagesInboxRecord
    let inbox: FernletMessagesRecipeInboxCoordinator
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isImporting = false
    @State private var errorMessage: String?
    /// The "added" line, set when the save landed; the sheet holds it for a beat, then closes.
    @State private var landedLine: String?

    init(
        record: FernletMessagesInboxRecord,
        inbox: FernletMessagesRecipeInboxCoordinator,
        onCompleted: @escaping () -> Void
    ) {
        self.record = record
        self.inbox = inbox
        self.onCompleted = onCompleted
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    recipeDetails
                    duplicatePolicyNote
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    saveButton
                }
                .padding()
            }
            .navigationTitle("Import recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { dismissButton }
        }
        .interactiveDismissDisabled(isImporting)
    }

    private var recipeDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.packet.recipe.name).font(.title2.weight(.semibold))
            Text("\(record.packet.recipe.servings) servings · \(record.packet.recipe.ingredients.count) ingredients")
            Text("\(record.packet.recipe.steps?.count ?? 0) steps · \(notesStatus)")
            // A recipe made in parts names them, in making order — a dressing first, then the salad.
            // The names are the sender's own words; the payload's decode bounded them.
            if let parts = record.packet.recipe.components, !parts.isEmpty {
                Text("Parts: \(parts.map(\.name).joined(separator: " · "))")
            }
            if record.packet.includesNotes, !record.packet.recipe.notes.isEmpty {
                Text("Notes")
                    .font(.headline)
                Text(record.packet.recipe.notes)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Save recipe, or — once the save landed — the "added" line in its place.
    @ViewBuilder
    private var saveButton: some View {
        if let landedLine {
            ImportLandedLine(text: landedLine)
                .font(.headline)
        } else {
            Button(action: beginImport) {
                Text(isImporting ? "Saving recipe…" : "Save recipe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting)
        }
    }

    private var notesStatus: String {
        record.packet.includesNotes ? "Notes included" : "No notes"
    }

    private var duplicatePolicyNote: some View {
        Text("If this exact recipe is already in Fernlet, it will stay a single copy.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    @ToolbarContentBuilder
    private var dismissButton: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
                .disabled(isImporting)
        }
    }

    /// Saves the recipe and hands the outcome to ``ImportReviewLanding``. `isImporting` stays set
    /// through a landed save's beat, so Cancel and the swipe stay off until the sheet closes itself.
    private func beginImport() {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        Task { @MainActor in
            let outcome = await Self.outcome(
                importing: { try await ExchangeIntentService.shared.importRecipe(record.packet, policy: .skipExactDuplicate) },
                consume: { inbox.consume(id: record.id) }
            )
            switch outcome {
            case .added(let line):
                landedLine = line
            case .caveat(let line), .failed(let line):
                isImporting = false
                errorMessage = line
            }
            await ImportReviewLanding().answer(outcome) {
                onCompleted()
                dismiss()
            }
        }
    }

    /// What one Save came to, decided only after the import returned: `failed` when it threw, a
    /// `caveat` when it saved but this review could not be cleared, and the "added" line otherwise.
    ///
    /// - Parameters:
    ///   - run: The exchange service's import — the recipe, or the copy already in Fernlet.
    ///   - consume: Clears this review from the Messages inbox; false when it could not.
    static func outcome(
        importing run: () async throws -> RecipeEntity,
        consume: () -> Bool
    ) async -> ImportReviewOutcome {
        let saved: RecipeEntity
        do {
            saved = try await run()
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription
                ?? String(localized: "messagesRecipeImport.error.saveFallback",
                          defaultValue: "Fernlet couldn't save this recipe.",
                          comment: "Shown in the Messages recipe review sheet when saving fails and the thrown error carries no description of its own."))
        }
        guard consume() else {
            return .caveat(String(
                localized: "messagesRecipeImport.savedNotCleared",
                defaultValue: "Saved the recipe, but Fernlet couldn't clear this review. Please try Save recipe again.",
                comment: "Shown in the Messages recipe review sheet when the recipe was saved but the review it came from could not be cleared. 'Save recipe' is the exact label of the sheet's button."))
        }
        return .added(String(
            localized: "messagesRecipeImport.added",
            defaultValue: "\u{201C}\(saved.name)\u{201D} is in your recipe book.",
            comment: "Shown in the Messages recipe review sheet for a moment after Save recipe, before it closes, and spoken once it has. The name is the recipe's; if the same recipe was already in Fernlet, it stays a single copy, so the line says it is there rather than that it was added."))
    }
}
