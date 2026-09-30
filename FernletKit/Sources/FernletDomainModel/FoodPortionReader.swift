// FoodPortionReader.swift
// FernletDomainModel
//
// The tolerant reader for USDA household portions — Docs/Ingredient-Search-Deep-Research-2026-09-29.md
// §3.2, §6.3 Rung A and §8 F4a ("the minimal banana fix").
//
// "Bananas, raw" ships eight USDA portions, among them "medium (7" to 7-7/8" long)" at 118 g, and the
// converter read none of them: a portion counted only when its WHOLE unit string was one of the
// sixteen `RecipeUnit` spellings, so "medium (…)" and "cup, sliced" were noise and "1 banana" refused.
// This reader takes the leading measure word and drops the qualifiers — a parenthetical, anything
// after the first comma — and classifies what is left: a unit word (cup, tbsp, tsp, fl oz → volume;
// oz, lb → mass; slice, piece, each), a reference serving (RACC, NLEA, serving), or a NAMED COUNT —
// a size word ("medium", "extra large") or one of a closed list of count nouns ("egg", "clove",
// "fruit", "stick", "pepper", "tortilla", …).
//
// Every word it matches is a FROZEN ENGLISH TOKEN: USDA writes its portion text in English, so these
// are matching inputs, never display text, and translating one matches nothing
// (LocalizationBoundaryTests pins them). Every value a portion yields is USDA's own gram weight — the
// reader invents no size, so item 12's "one source-backed portion" rule still holds.

import Foundation

/// What one household portion measures, as ``FoodPortionReader`` reads it.
public nonisolated enum FoodPortionMeasure: Equatable {
    /// A unit word leads the portion: "cup, sliced" is a cup, "tbsp chopped" a tablespoon, "oz" a
    /// mass ounce, "slice, thin" a slice.
    case unit(RecipeUnit)
    /// A reference serving — RACC, "NLEA serving", "serving" — which is a label amount, not a
    /// household measure, and never answers a unit.
    case reference
    /// A named count: a size word ("medium", "extra large"), a count noun ("clove", "fruit"), or both
    /// ("Potato medium", "stalk, medium"). At least one of the two is present.
    case count(noun: String?, size: String?)

    /// The recipe unit this measure answers: its unit, `.each` for a named count, nil for a
    /// reference serving.
    public var recipeUnit: RecipeUnit? {
        switch self {
        case .unit(let unit): unit
        case .count: .each
        case .reference: nil
        }
    }
}

/// Reads USDA household portions tolerantly and picks the one "each" means (ingredient-search round,
/// F4a). Pure and bounded: a portion's text is read up to ``maxMeasureCharacters`` characters and a
/// food's portion list up to ``maxPortionsRead`` portions.
public nonisolated enum FoodPortionReader {
    /// USDA's size words, longest first so "extra large" is read before "large". FROZEN matching
    /// tokens (USDA's English portion text); never localize.
    public static let sizeWords = ["extra large", "extra small", "large", "medium", "small"]

    /// The size "each" means when a food states several sizes. A frozen matching token.
    public static let defaultSize = "medium"

    /// The count nouns a portion may lead with and still mean "one of this food": the produce, egg and
    /// tortilla nouns USDA uses for a whole item. A CLOSED list on purpose — packaging ("can", "jar",
    /// "package"), cuts ("strip", "wedge", "ring") and servings of a dish are not "one" of anything a
    /// recipe counts. FROZEN matching tokens, singular; ``countNoun(_:)`` reads a regular plural.
    public static let countNouns: Set<String> = [
        "apple", "apricot", "artichoke", "avocado", "banana", "beet", "carrot", "clove", "cucumber",
        "date", "egg", "eggplant", "fig", "fruit", "kiwifruit", "leek", "lemon", "lime", "mango",
        "mushroom", "nectarine", "olive", "onion", "orange", "parsnip", "peach", "pear", "pepper",
        "plantain", "plum", "potato", "radish", "stalk", "stick", "tomato", "tortilla"
    ]

    /// Words that lead a reference serving rather than a household measure. Frozen matching tokens.
    public static let referenceWords: Set<String> = ["nlea", "portion", "racc", "serving", "servings"]

    /// How far (as a fraction of their median) several portions of ONE named count may spread and
    /// still be one size — "clove" (3 g) and "3 cloves" (9 g) are one size; a lemon's two "fruit"
    /// portions (58 g and 84 g) are two.
    public static let countAgreementTolerance = 0.15

    /// How close (as a fraction) a named count must sit to the food's reference serving to be the one
    /// USDA's own label serving names — a lemon's "NLEA serving" is 58 g, its smaller fruit.
    public static let referenceMatchTolerance = 0.02

    /// Longest portion text read, in characters (Rule 2).
    public static let maxMeasureCharacters = 200

    /// Most portions of one food read when choosing "each" (Rule 2); far above USDA's longest list.
    public static let maxPortionsRead = 64

    /// The measure `portion` states, or nil when its leading word is none this reader knows.
    public static func measure(of portion: FoodPortion) -> FoodPortionMeasure? {
        let (head, tail) = measureWords(portion)
        guard let first = head.first else { return nil }
        if let whole = RecipeUnit.normalized(head.joined(separator: " ")) {
            return whole == .serving ? .reference : .unit(whole)
        }
        if head.count >= 2, first == "fl", head[1] == "oz" { return .unit(.fluidOunce) }
        if let unit = RecipeUnit.normalized(first) { return unit == .serving ? .reference : .unit(unit) }
        guard !referenceWords.contains(first) else { return .reference }
        if let leading = sizeWord(in: head, at: 0) {
            let next = head.count > leading.width ? head[leading.width] : nil
            if let next, let unit = RecipeUnit.normalized(next), unit != .serving { return .unit(unit) }
            return .count(noun: next.flatMap(countNoun), size: leading.size)
        }
        guard let noun = countNoun(first) else { return nil }
        let size = sizeWord(in: head, at: 1)?.size ?? sizeWord(in: tail, at: 0)?.size
        return .count(noun: noun, size: size)
    }

    /// The portion "1 each" means among `portions`, from the food's own named counts:
    /// 1. with two or more SIZE portions, the one "medium" one (a banana's 118 g);
    /// 2. otherwise the single named count — every unsized count portion (or the one sized portion
    ///    when there is no other) naming one noun whose gram weights agree within
    ///    ``countAgreementTolerance`` (garlic's "clove" and "3 cloves"); the median one is used;
    /// 3. otherwise the one such portion whose weight matches the food's reference serving within
    ///    ``referenceMatchTolerance`` (a lemon's 58 g fruit is its NLEA serving).
    /// Anything else is ambiguous and returns nil. A portion stated exactly as `each` is the caller's
    /// first answer (``FoodItem``'s strict reading); this is the fallback beneath it.
    public static func eachPortion(in portions: [FoodPortion]) -> FoodPortion? {
        let read = Array(portions.prefix(maxPortionsRead))
        let counted = read.compactMap(NamedCount.init)
        let sized = counted.filter { $0.size != nil }
        if sized.count >= 2, let medium = single(sized.filter { $0.size == defaultSize }) {
            return medium.portion
        }
        let unsized = counted.filter { $0.size == nil }
        let pool = unsized.isEmpty && sized.count == 1 ? sized : unsized
        guard !pool.isEmpty else { return nil }
        if let agreed = agreeingCount(pool) { return agreed.portion }
        let references = read.filter { $0.hasValidGramMeasure && measure(of: $0) == .reference }
        return single(pool.filter { $0.matchesReference(in: references) })?.portion
    }

    /// `word` as a count noun (singular), reading a regular "-s" / "-es" plural, or nil.
    public static func countNoun(_ word: String) -> String? {
        if countNouns.contains(word) { return word }
        if word.hasSuffix("es"), countNouns.contains(String(word.dropLast(2))) { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), countNouns.contains(String(word.dropLast())) { return String(word.dropLast()) }
        return nil
    }

    /// The words a portion's measure is read from, split at the first comma into the measure (head)
    /// and its qualifiers (tail), with parentheticals dropped. A unit that is empty or
    /// "undetermined" (FNDDS) is read from the description, less a leading amount ("1 banana").
    static func measureWords(_ portion: FoodPortion) -> (head: [String], tail: [String]) {
        let unitWords = FoodItemSearch.normalized(portion.unit)
        var text = portion.unit
        if unitWords.isEmpty || unitWords == "undetermined" {
            text = droppingLeadingAmount(portion.description ?? "")
        }
        let bare = removingParentheticals(String(text.prefix(maxMeasureCharacters)))
        let parts = bare.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let words = { (part: Substring?) in
            FoodItemSearch.normalized(String(part ?? "")).split(separator: " ").map(String.init)
        }
        return (words(parts.first), words(parts.count > 1 ? parts[1] : nil))
    }

    /// `text` without its first whitespace-separated token when that token is a number.
    private static func droppingLeadingAmount(_ text: String) -> String {
        let parts = text.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, LocaleTolerantNumber.double(from: String(parts[0])) != nil else { return text }
        return String(parts[1])
    }

    /// `text` with every parenthetical group removed; an unmatched ")" is ignored. Bounded by the
    /// text's length.
    private static func removingParentheticals(_ text: String) -> String {
        var depth = 0
        var kept = ""
        for character in text {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth = max(depth - 1, 0)
            } else if depth == 0 {
                kept.append(character)
            }
        }
        return kept
    }

    /// The size word starting at `index` in `words` and how many words it spans, or nil.
    private static func sizeWord(in words: [String], at index: Int) -> (size: String, width: Int)? {
        guard index >= 0, index < words.count else { return nil }
        if index + 1 < words.count, sizeWords.contains("\(words[index]) \(words[index + 1])") {
            return ("\(words[index]) \(words[index + 1])", 2)
        }
        return sizeWords.contains(words[index]) ? (words[index], 1) : nil
    }

    /// The one element of `values`, or nil when there are none or several.
    private static func single<T>(_ values: [T]) -> T? {
        values.count == 1 ? values.first : nil
    }

    /// The median named count when every one in `pool` names the same noun and their per-one gram
    /// weights agree within ``countAgreementTolerance``; with an even count the lower middle one
    /// (ties keep their stored order).
    private static func agreeingCount(_ pool: [NamedCount]) -> NamedCount? {
        guard !pool.isEmpty, Set(pool.map(\.noun)).count == 1 else { return nil }
        let ordered = pool.enumerated().sorted { ($0.element.gramsPerOne, $0.offset) < ($1.element.gramsPerOne, $1.offset) }
        let median = ordered[(ordered.count - 1) / 2].element
        let spread = countAgreementTolerance * median.gramsPerOne
        guard ordered.allSatisfy({ abs($0.element.gramsPerOne - median.gramsPerOne) <= spread }) else { return nil }
        return median
    }
}

/// One portion read as a named count (``FoodPortionMeasure/count(noun:size:)``), with the grams one
/// of it weighs. A qualified "each"/"unit" word ("unit, yield from 1 lb raw" — a whole pound's yield
/// of ground turkey) is NOT a named count: only a portion stated exactly as `each` answers "each"
/// without naming what one is.
private nonisolated struct NamedCount {
    let portion: FoodPortion
    let noun: String?
    let size: String?
    let gramsPerOne: Double

    init?(_ portion: FoodPortion) {
        guard portion.hasValidGramMeasure,
              case .count(let noun, let size)? = FoodPortionReader.measure(of: portion) else { return nil }
        self.noun = noun
        self.size = size
        self.portion = portion
        self.gramsPerOne = portion.gramWeight / portion.amount
    }

    /// Whether one of this count weighs what one of the food's reference servings does.
    func matchesReference(in references: [FoodPortion]) -> Bool {
        references.contains { reference in
            let referenceGrams = reference.gramWeight / reference.amount
            return abs(gramsPerOne - referenceGrams) <= FoodPortionReader.referenceMatchTolerance * referenceGrams
        }
    }
}

extension FoodPortion {
    /// The measure this portion states, read tolerantly (``FoodPortionReader/measure(of:)``).
    public var measure: FoodPortionMeasure? {
        FoodPortionReader.measure(of: self)
    }

    /// The recipe unit this portion answers (ingredient-search round, F4a): its ``exactRecipeUnit``
    /// when its whole unit string is one, else the unit its leading measure word states — "cup,
    /// sliced" is a cup, "medium (7" to 7-7/8" long)" and "clove" are `.each`. Nil for a reference
    /// serving or a measure the reader does not know ("package (5 oz)", "strip large").
    public var recipeUnit: RecipeUnit? {
        exactRecipeUnit ?? measure?.recipeUnit
    }
}
