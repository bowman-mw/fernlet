import Foundation

// The multipart half of the `fernlet.recipe` wire (2026-09-24).
//
// COMPATIBILITY RULE: a multipart recipe travels as an ordinary version-1 payload whose flat
// `ingredients` and `steps` already hold the WHOLE recipe, in part order, with each step's text
// labelled "<part name>: ". One extra optional key, `components`, partitions those flat arrays by
// COUNT. Every shipped reader decodes with a synthesized-style `Codable` that ignores unknown keys and
// rejects any `version` other than 1. So an older build reads a multipart share as a flat recipe with
// section-labelled steps, instead of refusing it. A newer build reads the partition, strips the labels
// and rebuilds the parts exactly. This is the same additive rule `steps` and the mesh picture used
// ("Do NOT bump `version`" on ``SharedRecipePayload/steps``). A one-part recipe carries no
// `components` key at all, so its bytes are identical to every build before this one.
//
// The one wire that cannot carry the key as an ignorable extra is the hash-covered exchange packet
// (Files, Shortcuts, Messages): an older reader re-encodes the decoded payload WITHOUT the unknown key
// and fails the content hash. So that packet VERSIONS instead (the Messages v2 work, 2026-09-24): a
// multipart recipe travels as `RecipeExchangePacket` format version 2, partition and all, under a
// version-2 content hash, which an older build refuses cleanly as a format it does not know; a
// one-part recipe stays version 1, byte for byte. The flattened old-reader form,
// ``SharedRecipePayload/droppingComponents()`` (`ExchangeRecipePayloadBuilder.payload(for:foodItems:)`),
// is no longer sent on any wire.

/// One part of a multipart recipe on the `fernlet.recipe` wire: its name and how many of the payload's
/// flat ingredients and steps belong to it, counted from the front in order.
///
/// Decoded from untrusted bytes (pasted text, a mesh envelope, an exchange file), so the decode is
/// STRICT: a missing key, a blank, multi-line or over-long name, or an out-of-range count throws
/// ``RecipeImportError/invalidPayload``. The whole-partition rules (two to
/// ``RecipeComponentLimits/maxComponents`` parts, none empty, counts summing to the flat arrays) are
/// ``isValidPartition(_:ingredientCount:stepCount:)``, which ``SharedRecipePayload``'s decode enforces.
public nonisolated struct SharedRecipeComponent: Codable, Equatable, Sendable {
    public var name: String
    public var ingredientCount: Int
    public var stepCount: Int

    public init(name: String, ingredientCount: Int, stepCount: Int) {
        self.name = name
        self.ingredientCount = ingredientCount
        self.stepCount = stepCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        ingredientCount = try container.decode(Int.self, forKey: .ingredientCount)
        stepCount = try container.decode(Int.self, forKey: .stepCount)
        guard isValid else { throw RecipeImportError.invalidPayload }
    }

    /// True when the name is one non-blank line of at most ``RecipeComponentLimits/maxNameCharacters``
    /// characters and both counts are within the whole-recipe caps.
    public var isValid: Bool {
        (1...RecipeComponentLimits.maxNameCharacters).contains(name.count)
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0) }
            && (0...SharedRecipeLimits.maxIngredients).contains(ingredientCount)
            && (0...SharedRecipeLimits.maxSteps).contains(stepCount)
    }

    /// Whether `components` is a well-formed partition of a payload holding `ingredientCount`
    /// ingredients and `stepCount` steps: 2...``RecipeComponentLimits/maxComponents`` valid parts,
    /// none empty, whose counts add up to exactly the flat arrays' lengths.
    public static func isValidPartition(_ components: [SharedRecipeComponent], ingredientCount: Int, stepCount: Int) -> Bool {
        let partCount = RecipeComponentLimits.minComponents...RecipeComponentLimits.maxComponents
        guard partCount.contains(components.count) else { return false }
        var ingredients = 0
        var steps = 0
        for component in components {
            // `isValid` first: it bounds both counts, so the sums below can never overflow.
            guard component.isValid, component.ingredientCount + component.stepCount > 0 else { return false }
            ingredients += component.ingredientCount
            steps += component.stepCount
        }
        return ingredients == ingredientCount && steps == stepCount
    }

    /// Wire JSON keys. Frozen tokens: they are read by every build that understands parts.
    private enum CodingKeys: String, CodingKey {
        case name, ingredientCount, stepCount
    }
}

/// The step-label half of the flattening rule: how a part's name rides in each of its steps' text,
/// so an older reader still sees which part a step belongs to.
public nonisolated enum RecipeComponentWire {
    /// What joins a part's name to a step's text in the flattened form: "Lemon dressing: Whisk the oil".
    /// A frozen TOKEN, because a newer reader strips exactly this string. It never localizes.
    public static let labelSeparator = ": "

    /// `step` with its text prefixed by `partName` and ``labelSeparator``.
    ///
    /// Returns `step` unchanged when the labelled text would break an older reader's step-text cap
    /// (``SharedRecipeLimits/maxStepTextCharacters``). An over-long label would get the whole recipe
    /// rejected, where a missing label only costs a cue. It also returns `step` unchanged when
    /// ``unlabelled(_:partName:)`` would not recover the exact text, e.g. a step starting with a
    /// combining mark that fuses with the separator's space. Every label the sender writes is
    /// therefore one the reader removes losslessly.
    public static func labelled(_ step: RecipeStep, partName: String) -> RecipeStep {
        let text = partName + labelSeparator + step.text
        let candidate = RecipeStep(id: step.id, text: text, durationSeconds: step.durationSeconds)
        guard text.count <= SharedRecipeLimits.maxStepTextCharacters,
              unlabelled(candidate, partName: partName).text == step.text else { return step }
        return candidate
    }

    /// `step` with ONE leading "`partName`: " removed, or unchanged when it does not start with it.
    ///
    /// Applied only to the steps inside that part's slice. The one lossy case is a step the sender
    /// could not label (over-long) whose own text already began with its part's label. That step
    /// loses a redundant copy of the heading it sits under, and nothing else.
    public static func unlabelled(_ step: RecipeStep, partName: String) -> RecipeStep {
        let prefix = partName + labelSeparator
        guard step.text.hasPrefix(prefix) else { return step }
        return RecipeStep(id: step.id, text: String(step.text.dropFirst(prefix.count)),
                          durationSeconds: step.durationSeconds)
    }
}

/// One part's content on the SENDING side, before flattening: its name, its ingredients already
/// resolved to wire form, and its unlabelled steps.
public nonisolated struct SharedRecipeComponentContent: Equatable, Sendable {
    public var name: String
    public var ingredients: [SharedRecipeIngredient]
    public var steps: [RecipeStep]

    public init(name: String, ingredients: [SharedRecipeIngredient], steps: [RecipeStep]) {
        self.name = name
        self.ingredients = ingredients
        self.steps = steps
    }
}

/// One part of a RECEIVED payload as a components-aware reader rebuilds it: its name, its slice of
/// the flat ingredients, and its steps with the flattening label removed.
public nonisolated struct SharedRecipeComponentSlice: Equatable, Sendable {
    public var name: String
    public var ingredients: [SharedRecipeIngredient]
    public var steps: [RecipeStep]

    public init(name: String, ingredients: [SharedRecipeIngredient], steps: [RecipeStep]) {
        self.name = name
        self.ingredients = ingredients
        self.steps = steps
    }
}

extension SharedRecipePayload {
    /// A payload for a recipe made of `parts`, flattened by the compatibility rule: every ingredient in
    /// part order, every step labelled with its part, and the `components` partition over both.
    ///
    /// Empty parts are dropped. When fewer than two parts survive, or more than
    /// ``RecipeComponentLimits/maxComponents`` arrive, the result is a plain one-part payload: the
    /// same rows, unlabelled, with no partition. Nothing is lost either way.
    public static func assembled(
        name: String, servings: Int, notes: String, parts: [SharedRecipeComponentContent]
    ) -> SharedRecipePayload {
        let kept = parts.filter { !$0.ingredients.isEmpty || !$0.steps.isEmpty }
        let ingredients = kept.flatMap(\.ingredients)
        let partCount = RecipeComponentLimits.minComponents...RecipeComponentLimits.maxComponents
        guard partCount.contains(kept.count) else {
            let steps = kept.flatMap(\.steps)
            return SharedRecipePayload(name: name, servings: servings, notes: notes,
                                       ingredients: ingredients, steps: steps.isEmpty ? nil : steps)
        }
        var steps: [RecipeStep] = []
        var components: [SharedRecipeComponent] = []
        for (position, part) in kept.enumerated() {
            let partName = RecipeComponentNaming.normalized(part.name, position: position)
            steps += part.steps.map { RecipeComponentWire.labelled($0, partName: partName) }
            components.append(SharedRecipeComponent(name: partName, ingredientCount: part.ingredients.count,
                                                    stepCount: part.steps.count))
        }
        return SharedRecipePayload(name: name, servings: servings, notes: notes, ingredients: ingredients,
                                   steps: steps.isEmpty ? nil : steps, components: components)
    }

    /// The form an OLDER reader gets: this payload minus the `components` key.
    ///
    /// The flat arrays already hold the whole recipe with section-labelled steps, so nothing else
    /// changes. For a one-part payload this is the identity.
    public func droppingComponents() -> SharedRecipePayload {
        var copy = self
        copy.components = nil
        return copy
    }

    /// This payload with its steps withheld: the "Include notes" toggle's local-recipe half.
    ///
    /// The partition is rewritten to match. Every part's step count becomes zero, parts left with no
    /// ingredients are dropped, and the partition disappears when fewer than two parts remain. So a
    /// withheld-steps multipart share still decodes, and still groups its ingredients by part.
    public func withoutSteps() -> SharedRecipePayload {
        var copy = self
        copy.steps = nil
        guard let components else { return copy }
        let kept = components.filter { $0.ingredientCount > 0 }
            .map { SharedRecipeComponent(name: $0.name, ingredientCount: $0.ingredientCount, stepCount: 0) }
        copy.components = kept.count >= RecipeComponentLimits.minComponents ? kept : nil
        return copy
    }

    /// The payload's parts as a components-aware reader rebuilds them, or `nil` for a one-part payload
    /// (or one whose partition no longer matches its flat arrays).
    public var componentSlices: [SharedRecipeComponentSlice]? {
        let allSteps = steps ?? []
        guard let components, SharedRecipeComponent.isValidPartition(
            components, ingredientCount: ingredients.count, stepCount: allSteps.count
        ) else { return nil }
        var ingredientStart = 0
        var stepStart = 0
        var slices: [SharedRecipeComponentSlice] = []
        for component in components {
            // In bounds by the partition check above: the counts are non-negative and sum to the lengths.
            let ingredientEnd = ingredientStart + component.ingredientCount
            let stepEnd = stepStart + component.stepCount
            slices.append(SharedRecipeComponentSlice(
                name: component.name,
                ingredients: Array(ingredients[ingredientStart..<ingredientEnd]),
                steps: allSteps[stepStart..<stepEnd].map { RecipeComponentWire.unlabelled($0, partName: component.name) }
            ))
            ingredientStart = ingredientEnd
            stepStart = stepEnd
        }
        return slices
    }
}

extension SharedRecipeComponent {
    /// The decode-time gate for ``SharedRecipePayload/components``. `nil` stays `nil` (a one-part
    /// payload). A partition that is not well-formed throws ``RecipeImportError/invalidPayload``,
    /// because an honest sender never produces one.
    public static func validatedPartition(
        _ components: [SharedRecipeComponent]?, ingredientCount: Int, stepCount: Int
    ) throws -> [SharedRecipeComponent]? {
        guard let components else { return nil }
        guard isValidPartition(components, ingredientCount: ingredientCount, stepCount: stepCount) else {
            throw RecipeImportError.invalidPayload
        }
        return components
    }
}

/// Rebuilds an imported recipe's steps and parts from a received payload, once the importer has
/// minted one ingredient per payload ingredient.
///
/// Every import path (pasted text, a mesh share, an exchange file or message) funnels through
/// `FernletStore.importRecipe(from:)`, which calls ``layout(for:ingredientIDs:)``. So one rule decides
/// what every path does with a partition.
public nonisolated enum RecipeComponentImport {
    /// The imported recipe's steps and parts.
    public struct Layout: Equatable {
        public var steps: [RecipeStep]?
        public var components: [RecipeComponent]?
    }

    /// For a one-part payload: its steps through ``RecipeStepSanitizer``, exactly as before parts
    /// existed, and no partition. For a multipart payload, each part's steps are unlabelled,
    /// sanitized and given fresh ids (a peer's ids are never trusted as keys). Each part claims its
    /// slice of `ingredientIDs`, which must hold one id per payload ingredient in payload order. Parts
    /// left empty are dropped, and fewer than two collapse to a one-part recipe.
    public static func layout(for payload: SharedRecipePayload, ingredientIDs: [UUID]) -> Layout {
        guard let slices = payload.componentSlices, ingredientIDs.count == payload.ingredients.count else {
            return Layout(steps: RecipeStepSanitizer.sanitized(payload.steps), components: nil)
        }
        var cursor = 0
        var steps: [RecipeStep] = []
        var components: [RecipeComponent] = []
        for slice in slices {
            let end = cursor + slice.ingredients.count
            let partIngredientIDs = Array(ingredientIDs[cursor..<end])
            cursor = end
            let partSteps = (RecipeStepSanitizer.sanitized(slice.steps) ?? [])
                .map { RecipeStep(text: $0.text, durationSeconds: $0.durationSeconds) }
            steps += partSteps
            guard !partIngredientIDs.isEmpty || !partSteps.isEmpty else { continue }
            components.append(RecipeComponent(
                name: RecipeComponentNaming.normalized(slice.name, position: components.count),
                ingredientIDs: partIngredientIDs,
                stepIDs: partSteps.map(\.id)
            ))
        }
        return Layout(steps: steps.isEmpty ? nil : steps,
                      components: components.count >= RecipeComponentLimits.minComponents ? components : nil)
    }
}
