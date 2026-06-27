import Foundation

struct ProximityRecipeSharePayload: Codable, Equatable, Identifiable {
    var format = "fernlet.proximity.recipe"
    var version = 1
    var id = UUID()
    var sentAt = Date()
    var recipe: ProximitySharedRecipe

    var hasShareNotes: Bool {
        switch recipe.kind {
        case .local:
            !(recipe.local?.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case .saved:
            !(recipe.saved?.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    func omittingShareNotes() -> ProximityRecipeSharePayload {
        var copy = self
        switch copy.recipe.kind {
        case .local:
            if var local = copy.recipe.local {
                local.notes = ""
                copy.recipe.local = local
            }
        case .saved:
            if var saved = copy.recipe.saved {
                saved.summary = ""
                copy.recipe.saved = saved
            }
        }
        return copy
    }
}

enum ProximitySharedRecipeKind: String, Codable, Equatable {
    case local
    case saved
}

struct ProximitySharedRecipe: Codable, Equatable {
    var kind: ProximitySharedRecipeKind
    var local: SharedRecipePayload?
    var saved: SharedSavedRecipePayload?

    var title: String {
        switch kind {
        case .local:
            local?.name ?? "Recipe"
        case .saved:
            saved?.name ?? "Saved recipe"
        }
    }

    var servings: Int {
        switch kind {
        case .local:
            local?.servings ?? 1
        case .saved:
            saved?.servings ?? 1
        }
    }

    var ingredientCount: Int {
        switch kind {
        case .local:
            local?.ingredients.count ?? 0
        case .saved:
            saved?.ingredients.count ?? 0
        }
    }
}

struct SharedSavedRecipePayload: Codable, Equatable {
    var name: String
    var sourceURLString: String
    var ingredients: [String]
    var summary: String
    var servings: Int
    var protein: Int
    var carbs: Int
    var fat: Int
    var micronutrients: Micronutrients
}

struct PendingProximityRecipeShare: Identifiable, Equatable {
    var id: UUID { payload.id }
    var senderDisplayName: String
    var senderFingerprint: String?
    var receivedAt: Date
    var payload: ProximityRecipeSharePayload
}

struct ProximityRecipeShareRecipient: Identifiable, Equatable {
    var id: UUID
    var displayName: String
    var fingerprint: String?  // nil until identity introduction completes
}
