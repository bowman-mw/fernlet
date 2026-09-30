import Foundation
import FernletDomainModel

/// The paste text Fernlet shared through the system share sheet until 2026-09-30, rebuilt here so
/// the reader that still accepts it (`RecipeShareCodec.decodePayload(from:)`) keeps a test.
///
/// Builds stopped WRITING this format when the share sheet moved to readable text
/// (`RecipeShareText`), but a person can still paste text an older build shared, so the reader stays
/// and so do its tests. The shape: a readable header (name, "Servings: N", an "Ingredients:" list
/// with per-line macro codes, "Notes:"), then the frozen marker line "Fernlet recipe data:" and the
/// payload's single-line JSON with sorted keys. Only the marker and the JSON are ever parsed; the
/// header is reproduced for realism (for a recipe made in parts the old header grouped lines under
/// part names, which no reader looked at, so this flat header stands in for it).
///
/// ``frozenText`` is, line for line, what `RecipeShareCodec.shareText(for:foodItems:)` at `3c8c9313`
/// (its last version) wrote for a one-part recipe whose payload is ``frozenPayload``, so the helper
/// cannot drift from what older builds put on people's clipboards:
/// `RecipeShareCodecTests.theLegacyFixtureIsWhatOlderBuildsShared` pins ``text(for:)`` to it.
enum LegacyRecipeShareTextFixture {
    /// The old share text for `payload`.
    static func text(for payload: SharedRecipePayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
        var lines = [payload.name, "Servings: \(payload.servings)", "", "Ingredients:"]
        lines += payload.ingredients.map { ingredient in
            "- \(String(format: "%g", ingredient.quantity)) \(ingredient.unit) \(ingredient.name) "
                + "(P\(ingredient.protein) C\(ingredient.carbs) F\(ingredient.fat))"
        }
        if !payload.notes.isEmpty {
            lines += ["", "Notes:", payload.notes]
        }
        lines += ["", "Fernlet recipe data:", json]
        return lines.joined(separator: "\n")
    }

    /// A small one-part recipe with a step, every value fixed so its encoding is byte-stable.
    static let frozenPayload = SharedRecipePayload(
        name: "Training Bowl",
        servings: 2,
        notes: "Chill before serving.",
        ingredients: [
            SharedRecipeIngredient(name: "Rolled oats", quantity: 80, unit: "g", protein: 10, carbs: 54, fat: 6),
            SharedRecipeIngredient(name: "Greek yogurt", quantity: 340, unit: "g", protein: 36, carbs: 12, fat: 0),
            SharedRecipeIngredient(name: "Blueberries", quantity: 150, unit: "g", protein: 2, carbs: 21, fat: 0)
        ],
        steps: [
            RecipeStep(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x51)),
                       text: "Combine oats and yogurt."),
            RecipeStep(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x52)),
                       text: "Top with berries and chill.", durationSeconds: 600)
        ]
    )

    /// ``frozenPayload`` as an older build shared it, byte for byte. Never regenerate this from the
    /// helper: it is the evidence the helper is checked against.
    static let frozenText = """
    Training Bowl
    Servings: 2

    Ingredients:
    - 80 g Rolled oats (P10 C54 F6)
    - 340 g Greek yogurt (P36 C12 F0)
    - 150 g Blueberries (P2 C21 F0)

    Notes:
    Chill before serving.

    Fernlet recipe data:
    {"format":"fernlet.recipe","ingredients":[\
    {"carbs":54,"fat":6,"name":"Rolled oats","protein":10,"quantity":80,"unit":"g"},\
    {"carbs":12,"fat":0,"name":"Greek yogurt","protein":36,"quantity":340,"unit":"g"},\
    {"carbs":21,"fat":0,"name":"Blueberries","protein":2,"quantity":150,"unit":"g"}],\
    "name":"Training Bowl","notes":"Chill before serving.","servings":2,"steps":[\
    {"id":"00000000-0000-0000-0000-000000000051","text":"Combine oats and yogurt."},\
    {"durationSeconds":600,"id":"00000000-0000-0000-0000-000000000052","text":"Top with berries and chill."}],\
    "version":1}
    """
}
