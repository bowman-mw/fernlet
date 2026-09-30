import Foundation

/// Protein/carb/fat grams that may carry a fraction: the precision side channel for an ingredient a
/// person typed as "3.4 g".
///
/// ``Macros`` stays whole grams (`Int`) everywhere it is stored and summed — meals, day records,
/// HealthKit, the widget, exports, targets. This type exists only where a person types an
/// ingredient's grams: the recipe editor's manual rows, a custom food, and the ``FoodItem`` those
/// mint (``FoodItem/preciseMacros``, an additive optional key in the synced blob). Every total is
/// still whole grams: each consumer rounds ONCE per ingredient, from the exact value, through
/// ``rounded``.
///
/// Invariants:
/// - The memberwise initializer sanitizes: a non-finite or negative gram value becomes 0 and `-0`
///   becomes `+0`. `JSONEncoder` throws on a non-finite `Double`, so an unsanitized value here would
///   fail the whole snapshot save rather than one field.
/// - ``rounded`` applies ``Macros/clampedInt(_:)`` to each field, the rule ``Macros/scaled(by:)``
///   already uses, and ``scaled(by:)`` mirrors ``Macros/scaled(by:)`` exactly (a non-finite scale
///   returns `self`, a negative one floors at 0). So for every whole-gram `m` and every scale `s`,
///   `PreciseMacros(m).scaled(by: s).rounded == m.scaled(by: s)`: a food with no fraction produces
///   the numbers it always did.
/// - Tenths of a gram are the precision an ingredient's grams are stored and shown at
///   (``MacroGramEntry/quantized(_:)``). ``roundedToTenths`` applies it, and ``scaledToTenths(by:)`` is
///   the scaling a decimal food's row and total share: scale, then round to a tenth, then (for a
///   total) ``rounded``. So a row that reads "2.5 g" always counts 3 g, never the 2 g a raw 2.46
///   would round to.
/// - Decoding is the synthesized, RAW decode: a value read from bytes is not sanitized. Every
///   container that decodes one checks ``isValid`` first — ``FoodItem`` drops an invalid value, and
///   the `fernlet.recipe` wire (``SharedRecipeIngredient``) refuses the payload.
public nonisolated struct PreciseMacros: Codable, Equatable, Sendable {
    /// Largest gram value accepted from storage or a wire: the wire's per-ingredient macro ceiling.
    /// No real ingredient approaches it; typed rows stop at a few hundred grams.
    public static let maxGrams = Double(SharedRecipeLimits.maxMacroGrams)

    public let protein: Double
    public let carbs: Double
    public let fat: Double

    /// Sanitizing initializer: non-finite or negative grams become 0 (see the type's invariants).
    public init(protein: Double, carbs: Double, fat: Double) {
        self.protein = Self.sanitized(protein)
        self.carbs = Self.sanitized(carbs)
        self.fat = Self.sanitized(fat)
    }

    /// The exact equivalent of whole-gram `macros`.
    public init(_ macros: Macros) {
        self.init(protein: Double(macros.protein), carbs: Double(macros.carbs), fat: Double(macros.fat))
    }

    /// Whole grams, by the same rounding rule as ``Macros/scaled(by:)`` (half away from zero,
    /// clamped, never a trap).
    public var rounded: Macros {
        Macros(protein: Macros.clampedInt(protein), carbs: Macros.clampedInt(carbs), fat: Macros.clampedInt(fat))
    }

    /// True when any field is not a whole number of grams, i.e. when ``rounded`` would lose something.
    public var hasFractionalPart: Bool {
        [protein, carbs, fat].contains { $0.isFinite && $0.rounded(.towardZero) != $0 }
    }

    /// True when every field is finite and between 0 and ``maxGrams``. The check a container runs on
    /// a decoded value, since the synthesized decode does not sanitize.
    public var isValid: Bool {
        [protein, carbs, fat].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= Self.maxGrams }
    }

    /// These grams multiplied by `scale`, mirroring ``Macros/scaled(by:)``: a non-finite scale leaves
    /// the value unchanged and a negative one counts as 0.
    public func scaled(by scale: Double) -> PreciseMacros {
        guard scale.isFinite else { return self }
        let safeScale = max(scale, 0)
        return PreciseMacros(protein: protein * safeScale, carbs: carbs * safeScale, fat: fat * safeScale)
    }

    /// Each field rounded to the nearest tenth of a gram (``MacroGramEntry/quantized(_:)``): the
    /// precision a typed value is stored and shown at. Idempotent, and it preserves ``isValid``.
    public var roundedToTenths: PreciseMacros {
        PreciseMacros(protein: MacroGramEntry.quantized(protein),
                      carbs: MacroGramEntry.quantized(carbs),
                      fat: MacroGramEntry.quantized(fat))
    }

    /// These grams for `scale` servings at the precision a row shows them: ``scaled(by:)``, then
    /// ``roundedToTenths``. Its ``rounded`` is the whole grams a total counts for the same amount.
    public func scaledToTenths(by scale: Double) -> PreciseMacros {
        scaled(by: scale).roundedToTenths
    }

    /// The sanitizing rule behind the initializer: finite and positive, or exactly `+0`.
    private static func sanitized(_ grams: Double) -> Double {
        guard grams.isFinite, grams > 0 else { return 0 }
        return grams
    }
}
