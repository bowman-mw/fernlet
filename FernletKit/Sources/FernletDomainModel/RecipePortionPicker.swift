// RecipePortionPicker.swift
// FernletDomainModel
//
// The recipe editor's per-food amount picker — Docs/Ingredient-Search-Deep-Research-2026-09-29.md §6.3
// Rung A and §8 F4b (owner decision 2026-09-30: the picker may list USDA's named portions, "medium
// banana, 118 g").
//
// Before F4b the editor's unit menu listed all sixteen `RecipeUnit`s for every food, whether or not
// they could convert, and a food's own USDA household portions were reachable only through the
// converter's narrow reading of them: "Bananas, raw" ships "medium" (118 g), "large" (136 g), "cup,
// sliced" (150 g) and "cup, mashed" (225 g), and the cup refused because the two cups disagree. The
// picker lists what the food itself says one of something weighs — a banana's cup becomes a CHOICE
// between sliced and mashed instead of a refusal — then the units that convert, and hides the rest.
//
// A named choice is saved the way F4a saves a household amount: as its GRAMS, with the choice kept
// beside them as the line's `RecipeHouseholdMeasure` (display metadata). No `RecipeUnit` token is
// added and the share wire is unchanged, so every build and every peer totals the line.

import Foundation

/// One entry of the recipe editor's per-food amount picker (ingredient-search round, F4b).
///
/// A ``Source/unit`` option is a `RecipeUnit` the converter resolves for the food ("Grams", "Tablespoons");
/// every other option names what ONE of something weighs — one of the food's own USDA household
/// portions (``Source/usdaPortion``), a curated USDA typical size (``Source/typicalSize``, an estimate
/// the person may edit), or the person's own grams for one (``Source/personal``). A named option's
/// amount is saved as grams (``householdMeasure``), never as a new unit token.
///
/// Not persisted: an option is rebuilt from the food every time the editor opens, and its ``id`` is a
/// picker tag only.
public nonisolated struct RecipePortionOption: Identifiable, Equatable, Hashable, Sendable {
    /// Where an option's weight comes from.
    public enum Source: String, Sendable, CaseIterable {
        /// A recipe unit the converter resolves for the food.
        case unit
        /// One of the food's own USDA household portions ("medium", "cup, sliced").
        case usdaPortion
        /// A curated USDA typical size (``TypicalPortionTable``), shown as an estimate.
        case typicalSize
        /// The person's own grams for one, remembered on this device.
        case personal
    }

    /// What an option measures — the family a count, volume or mass amount belongs to.
    public enum Dimension: String, Sendable {
        /// One of something: a size, a named item ("clove", "stick"), a count unit.
        case count
        /// A cup, spoon or other volume.
        case volume
        /// A mass unit.
        case mass
        /// The food's own declared serving.
        case serving
    }

    /// Where the weight comes from.
    public let source: Source
    /// For a ``Source/unit`` option, the `RecipeUnit` raw value; otherwise what one is, in words —
    /// USDA's own portion words shown verbatim, like a food name ("medium", "cup, sliced"), or a
    /// curated frozen English token. Never localized.
    public let label: String
    /// Grams in one; nil for a ``Source/unit`` option (the converter weighs a unit).
    public let gramsPerOne: Double?
    /// What the option measures.
    public let dimension: Dimension

    public init(source: Source, label: String, gramsPerOne: Double?, dimension: Dimension) {
        self.source = source
        self.label = label
        self.gramsPerOne = gramsPerOne
        self.dimension = dimension
    }

    /// A unit option for `unit`.
    public init(unit: RecipeUnit) {
        self.init(source: .unit, label: unit.rawValue, gramsPerOne: nil, dimension: Self.dimension(of: unit))
    }

    /// The picker tag: the source, the label and — for a named option — its grams, so two USDA
    /// portions with one label (a lemon's two "fruit" sizes) stay distinct.
    public var id: String {
        guard let gramsPerOne else { return "\(source.rawValue):\(label)" }
        return "\(source.rawValue):\(label):\(gramsPerOne)"
    }

    /// The unit a ``Source/unit`` option stands for, or nil.
    public var unit: RecipeUnit? {
        source == .unit ? RecipeUnit(rawValue: label) : nil
    }

    /// Whether the option is a curated estimate the editor badges and lets the person correct.
    public var isEstimate: Bool {
        source == .typicalSize
    }

    /// Whether the person may edit the option's grams: a typical size, or their own grams.
    public var hasEditableGrams: Bool {
        source == .typicalSize || source == .personal
    }

    /// What a line counted in this option is saved beside its grams, or nil for a unit option.
    public var householdMeasure: RecipeHouseholdMeasure? {
        guard source != .unit, let gramsPerOne else { return nil }
        let measure = RecipeHouseholdMeasure(label: label, gramsPerUnit: gramsPerOne)
        return measure.isValid ? measure : nil
    }

    /// What a household label measures: a volume when its first word is a volume unit ("cup, packed",
    /// "tbsp"), else a count ("medium", "clove").
    public static func dimension(ofLabel label: String) -> Dimension {
        let first = FoodItemSearch.normalized(label).split(separator: " ").first.map(String.init) ?? ""
        guard let unit = RecipeUnit.normalized(first), unit.isVolume else { return .count }
        return .volume
    }

    /// The measurement family of `unit`.
    public static func dimension(of unit: RecipeUnit) -> Dimension {
        switch unit.dimension {
        case .count: .count
        case .volume: .volume
        case .mass: .mass
        case nil: .serving
        }
    }
}

/// Builds the recipe editor's per-food amount picker (ingredient-search round, F4b, report §6.3 Rung A).
///
/// The order, one menu:
/// 1. **The food's own USDA household portions** (``RecipePortionOption/Source/usdaPortion``), read
///    tolerantly — "medium (7" to 7-7/8" long)" is "medium", "stalk, medium (…)" is "medium stalk",
///    "cup, sliced" keeps its qualifier — each with its grams for one: counts by weight, then volumes.
///    A reference serving (RACC, NLEA) is a label basis, not a household measure, and a mass
///    ("oz (approx 60 pcs)") is physical, so neither is listed; a portion that names no one thing it
///    could count ("10 strips", a yield) is left out.
/// 2. The person's own grams for one (``RecipePortionOption/Source/personal``).
/// 3. **USDA typical sizes** (``TypicalPortionTable``) — only for a dimension the food's own data
///    leaves empty: a typical count when the food offers no count, a typical cup when it offers no
///    volume. Estimates; the editor badges them "USDA typical size, estimate".
/// 4. **The units that convert** — the rest are hidden. A unit whose one converts through exactly one
///    of the listed portions ("each" of a banana IS its medium, "cup" of garlic IS its stated cup) is
///    folded into that portion (``Choices/standIns``), so the menu never offers the same amount twice.
///
/// Pure and bounded: a food's portions are read up to ``FoodPortionReader/maxPortionsRead``, and the
/// unit and typical lists are fixed tables.
public nonisolated enum RecipePortionPicker {
    /// The picker's choices for one food.
    public struct Choices: Equatable, Sendable {
        /// Every option, in menu order.
        public let options: [RecipePortionOption]
        /// Each unit folded into a listed portion, and the portion that stands for one of it — so a tap
        /// default of "1 each" on a banana selects "medium (118 g)".
        public let standIns: [RecipeUnit: RecipePortionOption]

        public init(options: [RecipePortionOption], standIns: [RecipeUnit: RecipePortionOption]) {
            self.options = options
            self.standIns = standIns
        }

        /// The option shown for an amount held as `unit`: the portion the unit is folded into, else the
        /// unit's own option, else nil when neither is on the menu.
        public func option(for unit: RecipeUnit) -> RecipePortionOption? {
            if let standIn = standIns[unit] { return standIn }
            return options.first { $0.unit == unit }
        }

        /// The unit `option` stands in for, or nil — a portion one of a unit IS ("medium" for "each" of
        /// a banana). The editor holds such a choice as that unit, so the line saves exactly as a typed
        /// "1 each" or "2 cup" always has (F4a's save rule keeps a line an older build reads).
        public func unit(standingIn option: RecipePortionOption) -> RecipeUnit? {
            RecipePortionPicker.unitOrder.first { standIns[$0] == option }
        }
    }

    /// How a saved line re-opens in the editor: its amount, its unit token and — for a named choice
    /// that is no unit's stand-in — the portion it was counted in.
    public struct Reopened: Equatable, Sendable {
        /// The amount, in ``unit`` or in ``portion``.
        public let quantity: Double
        /// The unit token the row holds.
        public let unit: String
        /// The named portion the amount is counted in, or nil.
        public let portion: RecipePortionOption?

        public init(quantity: Double, unit: String, portion: RecipePortionOption?) {
            self.quantity = quantity
            self.unit = unit
            self.portion = portion
        }
    }

    /// The editor row a saved `line` of `foodItem` re-opens as (F4b): F4a's household restore first
    /// ("118 g" saved from "1 each" re-opens as "1 each", shown as "medium (118 g)"); else a grams line
    /// saved from a named choice goes back to that choice — the menu's option at the same label and
    /// grams, or the one USDA portion at those grams (held as its unit when it is a unit's stand-in),
    /// else the saved measure itself as the person's own grams for one, so a choice the menu no longer
    /// offers (a typical size edited, the food's data changed) still re-opens as "1 fruit (150 g)" and
    /// never silently as bare grams; else the line as saved.
    public static func reopened(_ line: RecipeIngredient, foodItem: FoodItem, choices: Choices) -> Reopened {
        let restored = line.restoringHouseholdAmount(using: [foodItem])
        guard restored == line, let measure = line.householdMeasure, measure.isValid,
              RecipeUnit.normalized(line.unit) == .gram, line.quantity.isFinite, line.quantity > 0 else {
            return Reopened(quantity: restored.quantity, unit: restored.unit, portion: nil)
        }
        let saved = RecipePortionOption(source: .personal, label: measure.label, gramsPerOne: measure.gramsPerUnit,
                                        dimension: RecipePortionOption.dimension(ofLabel: measure.label))
        let named = choices.options.filter { $0.source != .unit }
        let sameGrams = named.filter { $0.source == .usdaPortion && sameWeight($0, saved) }
        let match = named.first { sameAmount($0, saved) } ?? (sameGrams.count == 1 ? sameGrams.first : nil) ?? saved
        let count = (line.quantity / (match.gramsPerOne ?? measure.gramsPerUnit) * 1_000).rounded() / 1_000
        if let unit = choices.unit(standingIn: match) {
            return Reopened(quantity: count, unit: unit.rawValue, portion: nil)
        }
        return Reopened(quantity: count, unit: RecipeUnit.gram.rawValue, portion: match)
    }

    /// The amount a row keeps when the person picks `option` from the menu while holding `quantity` in
    /// `unit` (and `portion`, when the amount is counted in a named portion). `standIn` is the unit the
    /// option stands for, if any (``Choices/unit(standingIn:)``).
    /// - From a named portion to a mass unit, the same grams: one fruit (136 g) becomes 136 g, 4.8 oz.
    /// - From grams, a mass unit or servings to a count or volume, ONE: a tap default of 100 g of a Hass
    ///   avocado becomes one fruit (136 g), not a hundred (13,600 g, which no line converts).
    /// - Anything else keeps the typed amount ("2 medium" becomes "2 large").
    public static func quantity(
        afterChoosing option: RecipePortionOption, standingIn standIn: RecipeUnit?,
        from quantity: Double, unit: String, portion: RecipePortionOption?
    ) -> Double {
        guard quantity.isFinite, quantity > 0 else { return 1 }
        let target = option.unit ?? standIn
        if let portion, let perOne = portion.gramsPerOne {
            guard let target, target.dimension == .mass, let one = target.baseAmount(for: 1) else { return quantity }
            return (quantity * perOne / one * 100).rounded() / 100
        }
        let held = RecipeUnit.normalized(unit)
        let fromMassOrServing = held == nil || held?.dimension == .mass || held == .serving
        let toCountOrVolume = option.dimension == .count || option.dimension == .volume
        guard fromMassOrServing, toCountOrVolume else { return quantity }
        return 1
    }

    /// Units in menu order: mass, then volume, then count, then the food's own serving.
    public static let unitOrder: [RecipeUnit] = [
        .gram, .ounce, .pound, .kilogram, .milligram,
        .cup, .tablespoon, .teaspoon, .fluidOunce, .milliliter, .liter, .glass,
        .each, .piece, .slice, .serving
    ]

    /// How far two weights may differ and still be one amount (0.5%).
    public static let sameGramsTolerance = 0.005

    /// How far two portions with ONE label may differ and still be listed once (5%): oats state "1 cup"
    /// at 81 g and "0.33 cup" at 27 g (81.8 g a cup) — USDA's rounding, one cup. A lemon's two "fruit"
    /// sizes (58 g, 84 g) stay two.
    public static let sameLabelTolerance = 0.05

    /// The choices for `foodItem`. `personal` is the person's own grams for one of this food
    /// (``RecipePortionOption/Source/personal``), newest first.
    public static func choices(for foodItem: FoodItem, personal: [RecipeHouseholdMeasure] = []) -> Choices {
        let named = usdaOptions(for: foodItem)
        let units = convertingUnits(for: foodItem)
        var standIns: [RecipeUnit: RecipePortionOption] = [:]
        var unitOptions: [RecipePortionOption] = []
        for (unit, conversion) in units {
            if let standIn = portionStandingIn(for: conversion, among: named, foodItem: foodItem) {
                standIns[unit] = standIn
            } else {
                unitOptions.append(RecipePortionOption(unit: unit))
            }
        }
        let own = named + unitOptions
        let personalOptions = personal.filter(\.isValid).map {
            RecipePortionOption(source: .personal, label: $0.label, gramsPerOne: $0.gramsPerUnit,
                                dimension: RecipePortionOption.dimension(ofLabel: $0.label))
        }
        let typical = TypicalPortionTable.options(for: foodItem, lacking: missingDimensions(in: own))
        return Choices(options: named + personalOptions + typical + unitOptions, standIns: standIns)
    }

    /// The food's own USDA household portions as named options — counts by weight, then the rest by
    /// weight — one per label and weight.
    public static func usdaOptions(for foodItem: FoodItem) -> [RecipePortionOption] {
        let read = foodItem.portions.prefix(FoodPortionReader.maxPortionsRead)
        var options: [RecipePortionOption] = []
        for portion in read {
            guard let option = namedOption(for: portion),
                  !options.contains(where: { sameAmount($0, option, tolerance: sameLabelTolerance) }) else { continue }
            options.append(option)
        }
        let counts = options.filter { $0.dimension == .count }.sorted(by: lighter)
        let others = options.filter { $0.dimension != .count }.sorted(by: lighter)
        return counts + others
    }

    /// `portion` as a named option, or nil when it is no household measure the menu lists: a
    /// reference serving, a mass (physical — the mass units weigh it), an invalid weight, or text
    /// that names no one thing (``FoodPortionReader/householdLabel(of:)``).
    static func namedOption(for portion: FoodPortion) -> RecipePortionOption? {
        guard portion.hasValidGramMeasure else { return nil }
        let measure = portion.measure
        let dimension: RecipePortionOption.Dimension
        switch measure {
        case .reference?: return nil
        case .unit(let unit)?:
            dimension = RecipePortionOption.dimension(of: unit)
            guard dimension != .mass else { return nil }
        case .count?, nil:
            dimension = .count
        }
        guard let label = FoodPortionReader.householdLabel(of: portion) else { return nil }
        let grams = portion.gramWeight / portion.amount
        guard grams.isFinite, grams > 0, grams <= RecipeConversionLimits.maxGrams else { return nil }
        return RecipePortionOption(source: .usdaPortion, label: label, gramsPerOne: grams, dimension: dimension)
    }

    /// Every unit one of which converts for `foodItem`, in ``unitOrder``, with that conversion.
    static func convertingUnits(for foodItem: FoodItem) -> [(RecipeUnit, RecipeServingConversion)] {
        unitOrder.compactMap { unit in
            let one = RecipeIngredient(foodItemId: foodItem.id, quantity: 1, unit: unit.rawValue)
            return one.servingConversion(using: foodItem).map { (unit, $0) }
        }
    }

    /// The listed portion one of a unit converts through, when that one IS the portion — its source
    /// portion, at that portion's grams — so the unit is folded into it; else nil.
    static func portionStandingIn(
        for conversion: RecipeServingConversion, among named: [RecipePortionOption], foodItem: FoodItem
    ) -> RecipePortionOption? {
        guard conversion.provenance == .sourcePortion, let grams = conversion.grams,
              let portion = conversion.sourcePortion, let source = namedOption(for: portion),
              abs(grams - (source.gramsPerOne ?? 0)) <= sameGramsTolerance * grams else { return nil }
        return named.first { sameAmount($0, source, tolerance: sameLabelTolerance) }
    }

    /// The dimensions `options` leaves without a single entry — the ones a typical size may fill.
    static func missingDimensions(in options: [RecipePortionOption]) -> Set<RecipePortionOption.Dimension> {
        let present = Set(options.map(\.dimension))
        return Set([RecipePortionOption.Dimension.count, .volume]).subtracting(present)
    }

    /// Whether two named options are one amount: the same label at the same grams (within `tolerance`).
    static func sameAmount(
        _ first: RecipePortionOption, _ second: RecipePortionOption, tolerance: Double = sameGramsTolerance
    ) -> Bool {
        first.label == second.label && sameWeight(first, second, tolerance: tolerance)
    }

    /// Whether two named options weigh the same for one (within `tolerance` of the heavier).
    static func sameWeight(
        _ first: RecipePortionOption, _ second: RecipePortionOption, tolerance: Double = sameGramsTolerance
    ) -> Bool {
        guard let firstGrams = first.gramsPerOne, let secondGrams = second.gramsPerOne else { return false }
        return abs(firstGrams - secondGrams) <= tolerance * max(firstGrams, secondGrams)
    }

    /// The menu order within a group: lighter first, then label.
    private static func lighter(_ first: RecipePortionOption, _ second: RecipePortionOption) -> Bool {
        let firstGrams = first.gramsPerOne ?? 0
        let secondGrams = second.gramsPerOne ?? 0
        guard firstGrams == secondGrams else { return firstGrams < secondGrams }
        return first.label < second.label
    }
}

extension FoodPortionReader {
    /// What ONE of `portion` is, in words, as the recipe editor lists it (F4b): the size and count noun
    /// a named count states ("medium", "clove", "medium stalk" — the words F4a saves), else the
    /// portion's own text without its parentheticals ("cup, sliced", "slice, thin", "regular"). Nil
    /// when the text is empty, names a yield ("(yield from 1 lb raw meat)" is a pound's cooked yield,
    /// not one of anything; a named count keeps its yield — "lemon yields" is the juice of one lemon),
    /// or states several of something the reader cannot name one of ("10 strips"). Source data shown
    /// verbatim; never localized.
    public static func householdLabel(of portion: FoodPortion) -> String? {
        let measure = portion.measure
        if case .count(let noun, let size)? = measure {
            let words = [size, noun].compactMap { $0 }
            if !words.isEmpty { return words.joined(separator: " ") }
        }
        guard !statesYield(portion), measure != nil || portion.amount == 1 else { return nil }
        return displayText(of: portion)
    }

    /// The portion's text as a person reads it: the unit (or, for an FNDDS "undetermined" unit, the
    /// description less its leading amount), parentheticals removed, whitespace collapsed, cut at a
    /// word end to ``RecipeHouseholdMeasure/maxLabelCharacters``. Nil when nothing is left.
    static func displayText(of portion: FoodPortion) -> String? {
        let unitWords = FoodItemSearch.normalized(portion.unit)
        // A generic unit says nothing of what one is: FNDDS writes "undetermined" and puts "1 banana"
        // in the description, and a branded label serving kept as an "each" portion reads "1 serving
        // (35 g)" there (`BundledRowCorrection`) — so read the description.
        let generic = unitWords.isEmpty || unitWords == "undetermined"
            || (unitWords == RecipeUnit.each.rawValue && !(portion.description ?? "").isEmpty)
        let raw = generic ? droppingLeadingAmount(portion.description ?? "") : portion.unit
        let words = removingParentheticals(String(raw.prefix(maxMeasureCharacters)))
            .split(whereSeparator: \.isWhitespace).map(String.init)
        var kept: [String] = []
        for word in words {
            let next = (kept + [word]).joined(separator: " ")
            guard next.count <= RecipeHouseholdMeasure.maxLabelCharacters else { break }
            kept.append(word)
        }
        let text = kept.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
        return text.isEmpty ? nil : text
    }
}
