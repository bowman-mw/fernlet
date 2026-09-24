import Foundation

// Multipart recipes (owner decision 2026-09-24: "Think like a salad recipe with a homemade dressing.
// You make the dressing seperatly then assemble the salad").
//
// The shape chosen is COMPONENTS INSIDE ONE RECIPE, not an ingredient that references another saved
// recipe. A part names a group of the recipe's OWN ingredient and step rows, so a multipart recipe
// stays self-contained on every wire, has no dangling references when another recipe is deleted, and
// cannot form a cycle (which the no-recursion rule would forbid walking anyway). Reusing one dressing
// across salads is a later follow-up: "add a part from a saved recipe" can COPY that recipe's rows
// into a new part without introducing a live reference.

/// One named part of a multipart recipe ("Lemon dressing", then "Salad"), stored as a PARTITION over
/// the owning ``RecipeDefinition``'s flat `ingredients` and `steps`, never as a second copy of them.
///
/// The flat arrays remain the recipe's single source of truth. Nutrition (`MealBuilder`), "cook for N"
/// scaling (``RecipeScaling``), grocery aggregation (``GroceryAggregation``), logging and every older
/// reader keep working on them unchanged, and each ingredient counts exactly once, whichever part it
/// sits in. A part only NAMES a group of those rows, by their stable ids, and fixes the order the parts
/// are made in. Read parts through ``RecipeDefinition/resolvedComponents``, the one resolution rule
/// every consumer shares. Never walk `ingredientIDs` directly.
///
/// Persisted state, so the decode is tolerant (a missing field defaults), unlike the strict wire twin
/// ``SharedRecipeComponent``.
public nonisolated struct RecipeComponent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// The part's display name as the user wrote it. User content, never a token.
    public var name: String
    /// The ``RecipeIngredient/id``s this part owns.
    public var ingredientIDs: [UUID]
    /// The ``RecipeStep/id``s this part owns.
    public var stepIDs: [UUID]

    public init(id: UUID = UUID(), name: String, ingredientIDs: [UUID] = [], stepIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.ingredientIDs = ingredientIDs
        self.stepIDs = stepIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        ingredientIDs = try container.decodeIfPresent([UUID].self, forKey: .ingredientIDs) ?? []
        stepIDs = try container.decodeIfPresent([UUID].self, forKey: .stepIDs) ?? []
    }

    /// Persisted JSON keys. Frozen tokens: they ride the synced blob and `SavedRecipeRecord.payloadData`.
    private enum CodingKeys: String, CodingKey {
        case id, name, ingredientIDs, stepIDs
    }
}

/// One part of a recipe as every consumer reads it: the recipe's own ingredient and step values,
/// grouped under the part's name, in making order.
///
/// Produced only by ``RecipeDefinition/resolvedComponents``. A one-part recipe resolves to exactly one
/// of these, with `name == nil` (the implicit whole recipe). A multipart recipe resolves to one per
/// non-empty part, each with a non-blank display name.
public nonisolated struct ResolvedRecipeComponent: Identifiable, Equatable {
    /// The part's id, or the recipe's own id for the implicit single part.
    public var id: UUID
    /// The part's display name; `nil` only for the implicit single part of a one-part recipe.
    public var name: String?
    public var ingredients: [RecipeIngredient]
    public var steps: [RecipeStep]

    public init(id: UUID, name: String?, ingredients: [RecipeIngredient], steps: [RecipeStep]) {
        self.id = id
        self.name = name
        self.ingredients = ingredients
        self.steps = steps
    }
}

/// The named bounds on a multipart recipe, shared by the editor, the wire decoder and the importer.
///
/// The ingredient and step caps stay the WHOLE-recipe caps (``SharedRecipeLimits``), counted across
/// every part. These bound only the parts themselves.
public nonisolated enum RecipeComponentLimits {
    /// Fewest non-empty parts that make a recipe multipart. One named part is just a recipe.
    public static let minComponents = 2
    /// Most parts one recipe may have. Generous: a layered cake is five (sponge, syrup, filling,
    /// ganache, decoration), and each part costs only a name and two counts on the wire.
    public static let maxComponents = 12
    /// Longest part name, in characters. Short on purpose: the name also prefixes each of the part's
    /// steps as its label for an older reader (see ``RecipeComponentWire``).
    public static let maxNameCharacters = 40
}

/// Normalizes a part's name at every entry point (the editor, the importer, the resolver), so no
/// consumer ever sees a blank, multi-line or over-long part name.
public nonisolated enum RecipeComponentNaming {
    /// Trims, folds line breaks and C0/C1 control characters to spaces (a name is one line: it heads a
    /// section of the share text and labels steps), and caps at
    /// ``RecipeComponentLimits/maxNameCharacters``. Format characters such as the zero-width joiner
    /// inside "👩‍🍳" are kept. A name left blank becomes the localized "Part N" for its 0-based `position`.
    public static func normalized(_ name: String, position: Int) -> String {
        let folded = String(name.unicodeScalars.map { scalar -> Character in
            scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar)
                ? " " : Character(scalar)
        })
        let trimmed = folded.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return fallbackName(position: position) }
        let capped = String(trimmed.prefix(RecipeComponentLimits.maxNameCharacters))
        return capped.trimmingCharacters(in: .whitespaces)
    }

    /// The display name a part gets when its author left it blank: "Part 1", "Part 2", ... for a
    /// 0-based `position`. Display text, so it localizes. Once saved, it is the user's content.
    public static func fallbackName(position: Int) -> String {
        let number = max(position, 0) + 1
        return String(localized: "recipePart.fallbackName", defaultValue: "Part \(number)", bundle: .module,
                      comment: "Name given to a part of a multipart recipe the user left unnamed, e.g. Part 2")
    }
}

extension RecipeDefinition {
    /// True when the recipe has at least ``RecipeComponentLimits/minComponents`` non-empty parts.
    public var isMultipart: Bool {
        resolvedComponents.count >= RecipeComponentLimits.minComponents
    }

    /// The recipe grouped into its parts, in making order. Never empty.
    ///
    /// A recipe with no `components`, or whose parts would leave fewer than two non-empty groups,
    /// resolves to ONE implicit part holding every ingredient and step in stored order. Otherwise:
    /// - every flat ingredient and step appears in exactly one part, so a consumer summing the parts
    ///   can never double-count or drop a row;
    /// - within a part, rows keep their flat-array order;
    /// - a row no part claims joins the LAST part (the only sensible home for a row appended by a path
    ///   that did not know about parts), and when two parts claim the same row, the first claim wins;
    /// - empty parts are dropped;
    /// - only the first ``RecipeComponentLimits/maxComponents`` parts are honoured;
    /// - names are normalized, so none is blank.
    public var resolvedComponents: [ResolvedRecipeComponent] {
        RecipeComponentResolver.resolve(self)
    }
}

/// The single resolution rule behind ``RecipeDefinition/resolvedComponents``.
///
/// Bounded by construction: one pass over the parts' id lists, then one pass over the flat
/// ingredient and step arrays. No recursion, no lookups that grow with anything but the recipe.
private nonisolated enum RecipeComponentResolver {
    static func resolve(_ recipe: RecipeDefinition) -> [ResolvedRecipeComponent] {
        let whole = [ResolvedRecipeComponent(id: recipe.id, name: nil,
                                             ingredients: recipe.ingredients, steps: recipe.steps ?? [])]
        guard let stored = recipe.components, stored.count >= RecipeComponentLimits.minComponents else {
            return whole
        }
        let parts = Array(stored.prefix(RecipeComponentLimits.maxComponents))
        let lastIndex = parts.count - 1
        let ingredientOwner = ownerIndex(parts.map(\.ingredientIDs))
        let stepOwner = ownerIndex(parts.map(\.stepIDs))
        var ingredientGroups = Array(repeating: [RecipeIngredient](), count: parts.count)
        var stepGroups = Array(repeating: [RecipeStep](), count: parts.count)
        for ingredient in recipe.ingredients {
            ingredientGroups[ingredientOwner[ingredient.id] ?? lastIndex].append(ingredient)
        }
        for step in recipe.steps ?? [] {
            stepGroups[stepOwner[step.id] ?? lastIndex].append(step)
        }
        var resolved: [ResolvedRecipeComponent] = []
        for (index, part) in parts.enumerated()
        where !ingredientGroups[index].isEmpty || !stepGroups[index].isEmpty {
            resolved.append(ResolvedRecipeComponent(
                id: part.id,
                name: RecipeComponentNaming.normalized(part.name, position: resolved.count),
                ingredients: ingredientGroups[index],
                steps: stepGroups[index]
            ))
        }
        return resolved.count >= RecipeComponentLimits.minComponents ? resolved : whole
    }

    /// Maps each claimed id to the index of the FIRST part claiming it.
    private static func ownerIndex(_ claims: [[UUID]]) -> [UUID: Int] {
        var owner: [UUID: Int] = [:]
        for (index, ids) in claims.enumerated() {
            for id in ids where owner[id] == nil {
                owner[id] = index
            }
        }
        return owner
    }
}

/// The recipe editor's working state for one part of a multipart recipe: a name, its ingredient rows
/// and its steps.
///
/// Never persisted. ``RecipeComponentAssembly`` turns a list of these into the recipe's flat rows plus
/// its ``RecipeComponent`` partition.
public nonisolated struct RecipeComponentInput: Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var ingredients: [ManualRecipeIngredientInput]
    public var steps: [RecipeStep]

    public init(
        id: UUID = UUID(),
        name: String = "",
        ingredients: [ManualRecipeIngredientInput] = [ManualRecipeIngredientInput()],
        steps: [RecipeStep] = []
    ) {
        self.id = id
        self.name = name
        self.ingredients = ingredients
        self.steps = steps
    }
}

/// Builds a multipart recipe's stored shape from the editor's parts: the flat ingredient and step rows
/// in part order, plus the ``RecipeComponent`` partition naming them.
///
/// Each part resolves its ingredient rows through the SAME ``CustomIngredientUpsert`` path a one-part
/// recipe uses, and its steps through the same ``RecipeStepSanitizer``, so a part is never a second,
/// divergent way to create a recipe row. Pure value logic; the caller owns persistence.
public nonisolated enum RecipeComponentAssembly {
    /// The assembled recipe rows and partition.
    ///
    /// `components` is `nil` whenever fewer than two non-empty parts survive, or more parts than the
    /// cap arrive. The rows are then a plain one-part recipe and nothing is lost.
    public struct Result: Equatable {
        public var ingredients: [RecipeIngredient]
        public var steps: [RecipeStep]?
        public var components: [RecipeComponent]?
    }

    public static func assemble(
        _ parts: [RecipeComponentInput],
        selectionCatalog: [FoodItem]? = nil,
        in foodItems: inout [FoodItem],
        verifiedAt: Date
    ) -> Result {
        var ingredients: [RecipeIngredient] = []
        var steps: [RecipeStep] = []
        var components: [RecipeComponent] = []
        for part in parts {
            let partIngredients = CustomIngredientUpsert.recipeIngredients(
                from: part.ingredients, selectionCatalog: selectionCatalog, in: &foodItems, verifiedAt: verifiedAt
            )
            let partSteps = RecipeStepSanitizer.sanitized(part.steps) ?? []
            ingredients += partIngredients
            steps += partSteps
            guard !partIngredients.isEmpty || !partSteps.isEmpty else { continue }
            components.append(RecipeComponent(
                id: part.id,
                name: RecipeComponentNaming.normalized(part.name, position: components.count),
                ingredientIDs: partIngredients.map(\.id),
                stepIDs: partSteps.map(\.id)
            ))
        }
        let isMultipart = (RecipeComponentLimits.minComponents...RecipeComponentLimits.maxComponents)
            .contains(components.count)
        return Result(ingredients: ingredients, steps: steps.isEmpty ? nil : steps,
                      components: isMultipart ? components : nil)
    }
}

/// One cooking step in making order, with the part it belongs to, for cooking mode and its Live
/// Activity.
///
/// `partName` is `nil` for a one-part recipe, so a single-part walk renders exactly as before.
public nonisolated struct RecipeCookingStep: Equatable {
    public var step: RecipeStep
    public var partName: String?

    public init(step: RecipeStep, partName: String?) {
        self.step = step
        self.partName = partName
    }
}

extension RecipeDefinition {
    /// Every step in making order: the first part's steps (the dressing), then the next part's (the
    /// salad), each carrying its part's name. A one-part recipe returns its steps in stored order with
    /// no part name.
    public var cookingSteps: [RecipeCookingStep] {
        let parts = resolvedComponents
        let named = parts.count >= RecipeComponentLimits.minComponents
        return parts.flatMap { part in
            part.steps.map { RecipeCookingStep(step: $0, partName: named ? part.name : nil) }
        }
    }
}
