import FernletExchange
import FernletDomainModel
import SwiftUI

/// Fernlet-owned confirmation for a recipe received in Messages. The actual import remains in the
/// canonical exchange service, which uses the warm process-wide store installed by the UI loader.
struct MessagesRecipeImportReviewSheet: View {
    let record: FernletMessagesInboxRecord
    let inbox: FernletMessagesRecipeInboxCoordinator
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isImporting = false
    @State private var errorMessage: String?

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
                    Button(action: beginImport) {
                        Text(isImporting ? "Saving recipe…" : "Save recipe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting)
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
            Text("\(record.packet.recipe.steps?.count ?? 0) steps · No notes")
        }
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

    private func beginImport() {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        Task { @MainActor in
            do {
                _ = try await ExchangeIntentService.shared.importRecipe(
                    record.packet, policy: .skipExactDuplicate
                )
                guard inbox.consume(id: record.id) else {
                    isImporting = false
                    errorMessage = "Saved the recipe, but Fernlet couldn't clear this review. Please try Save recipe again."
                    return
                }
                onCompleted()
                dismiss()
            } catch {
                isImporting = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Fernlet couldn't save this recipe."
            }
        }
    }
}
