import Foundation

/// Pure, value-level shopping-list aggregation (F3, decision §11.3).
///
/// This is the hard half of the grocery feature (§4.2): merging the ingredients of several recipes
/// into one consolidated list. It is deliberately **below the wall** and **catalog-free** — it never
/// resolves a `FoodItem`, never touches `FoodCatalog`, and holds no I/O — so it is trivially testable
/// and both the UI and a future engine can call it. `FoodItem` resolution stays the caller's job: the
/// caller resolves structured ingredients through `FoodCatalog.items(forRecipes:)` and passes them in
/// already-named, and (per §4.4) resolves web-import free-text via the shipped both-shapes unifier
/// `DataExportBuilder.recipeIngredientLines`. "Cook for 6" is likewise the caller's job: it feeds
/// `RecipeScaling.scaledIngredients(recipe, forYield:)` output in as the structured items, so scaling
/// composes with aggregation without this engine knowing about yields.
///
/// Merge rules (§4.4):
/// - Structured ingredients merge across recipes by `foodItemId`, with `FoodItemSearch.normalized`
///   name as the fallback key so the same food resolved to two different ids (custom-ingredient
///   upserts) still collapses.
/// - Quantities are summed ONLY when `RecipeUnit.normalized` says the units are compatible (same
///   normalized `RecipeUnit`). Incompatible or un-normalizable units (raw USDA codes like `GRM`/`MLT`
///   that `RecipeUnit.normalized` returns nil for) keep separate lines rather than silently adding
///   grams to cups.
/// - Web-imported recipes have no structured ingredients (§4.2), so they contribute their free-text
///   `ingredientLines` under a per-recipe heading, unmerged, until STEP 0 backfills structure.
///
/// This is a value-only namespace adding only NEW types, so it does not change the memory layout of
/// any existing `FernletDomainModel` type.
public nonisolated enum GroceryAggregation {

    /// A structured ingredient the caller has already resolved against the catalog and (if the user
    /// chose "cook for N") already scaled. `name` is the resolved catalog food name, or `""` when the
    /// food could not be resolved — an unresolvable item still contributes a measure-only line rather
    /// than vanishing, matching `recipeIngredientLines`' "measure only" fallback.
    public struct StructuredItem: Equatable, Sendable {
        public var foodItemId: UUID
        public var name: String
        public var quantity: Double
        public var unit: String

        public init(foodItemId: UUID, name: String, quantity: Double, unit: String) {
            self.foodItemId = foodItemId
            self.name = name
            self.quantity = quantity
            self.unit = unit
        }
    }

    /// One selected recipe's contribution. A manual/structured recipe fills `structured` (and leaves
    /// `freeTextLines` empty); a web-imported recipe fills `freeTextLines` (and leaves `structured`
    /// empty). A recipe that somehow carries both contributes to both halves.
    public struct RecipeSource: Equatable, Sendable {
        public var recipeName: String
        public var structured: [StructuredItem]
        public var freeTextLines: [String]

        public init(recipeName: String, structured: [StructuredItem] = [], freeTextLines: [String] = []) {
            self.recipeName = recipeName
            self.structured = structured
            self.freeTextLines = freeTextLines
        }
    }

    /// One consolidated line: a food, a summed quantity, and the unit it was summed in. `unit` is the
    /// canonical `RecipeUnit.rawValue` for summed lines and the original unit string for lines whose
    /// unit could not be normalized (and were therefore never merged).
    public struct Line: Equatable, Sendable {
        public var name: String
        public var quantity: Double
        public var unit: String

        public init(name: String, quantity: Double, unit: String) {
            self.name = name
            self.quantity = quantity
            self.unit = unit
        }

        /// `Flour (2 cup)` — name-first, matching `DataExportBuilder.recipeIngredientLines`. An empty
        /// name renders measure-only (`2 cup`); an empty measure renders the bare name.
        public var display: String {
            let measure = "\(GroceryAggregation.formatQuantity(quantity)) \(unit)"
                .trimmingCharacters(in: .whitespaces)
            if name.isEmpty { return measure }
            return measure.isEmpty ? name : "\(name) (\(measure))"
        }
    }

    /// A per-recipe section (a web-import recipe's free-text lines under its name).
    public struct RecipeSection: Equatable, Sendable {
        public var recipeName: String
        public var lines: [String]

        public init(recipeName: String, lines: [String]) {
            self.recipeName = recipeName
            self.lines = lines
        }
    }

    public struct GroceryList: Equatable, Sendable {
        public var consolidated: [Line]
        public var recipeSections: [RecipeSection]

        public init(consolidated: [Line] = [], recipeSections: [RecipeSection] = []) {
            self.consolidated = consolidated
            self.recipeSections = recipeSections
        }
    }

    // MARK: - Build

    public static func build(from sources: [RecipeSource]) -> GroceryList {
        GroceryList(
            consolidated: consolidate(sources.flatMap(\.structured)),
            recipeSections: sources.compactMap { source in
                let lines = source.freeTextLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                return lines.isEmpty ? nil : RecipeSection(recipeName: source.recipeName, lines: lines)
            }
        )
    }

    /// Merge structured items by food, then by compatible unit. Order is stable: food groups keep
    /// first-appearance order, and within a group the unit buckets keep first-appearance order too, so
    /// the output (and its golden test) is deterministic.
    private static func consolidate(_ items: [StructuredItem]) -> [Line] {
        // Food group = normalized-name key when a name exists (catches same-food/different-id), else the
        // raw foodItemId (an unresolvable item can only merge with an identical id).
        struct Bucket { var name: String; var quantity: Double; var unit: String }
        var order: [String] = []
        var buckets: [String: Bucket] = [:]

        func append(key: String, name: String, quantity: Double, unit: String) {
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = Bucket(name: name, quantity: quantity, unit: unit)
            } else {
                buckets[key]!.quantity += quantity
                // Prefer a resolved name if the first occurrence was unresolvable.
                if buckets[key]!.name.isEmpty, !name.isEmpty { buckets[key]!.name = name }
            }
        }

        // A monotonically increasing suffix makes every un-summable (nil-normalized unit) item its own
        // unique bucket key, so incompatible units are NEVER folded together.
        var standaloneCounter = 0

        for item in items {
            let foodKey = item.name.isEmpty
                ? "id:\(item.foodItemId.uuidString)"
                : "name:\(FoodItemSearch.normalized(item.name))"

            if let normalized = RecipeUnit.normalized(item.unit) {
                // Summable: bucket by (food, canonical unit). Same food + same canonical unit accrues.
                append(key: "\(foodKey)|unit:\(normalized.rawValue)",
                       name: item.name, quantity: item.quantity, unit: normalized.rawValue)
            } else {
                // Un-normalizable unit (raw USDA code / unknown): keep as its own line, never merged.
                standaloneCounter += 1
                append(key: "\(foodKey)|raw:\(standaloneCounter)",
                       name: item.name, quantity: item.quantity,
                       unit: item.unit.trimmingCharacters(in: .whitespaces))
            }
        }

        return order.compactMap { key in
            buckets[key].map { Line(name: $0.name, quantity: $0.quantity, unit: $0.unit) }
        }
    }

    // MARK: - Render

    /// Plain text for the share sheet (§4.4 delivery — Notes receives it as a new note). Deterministic
    /// so it can be golden-tested: title, then the consolidated block, then each per-recipe section.
    public static func plainText(_ list: GroceryList, title: String = "Shopping list") -> String {
        var lines: [String] = [title]
        if !list.consolidated.isEmpty {
            lines.append("")
            lines += list.consolidated.map { "- \($0.display)" }
        }
        for section in list.recipeSections {
            lines.append("")
            lines.append(section.recipeName)
            lines += section.lines.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    /// Whole numbers render without a trailing decimal; everything else uses `%g` (drops trailing
    /// zeros), matching `RecipeShareCodec.shareText`'s quantity formatting.
    static func formatQuantity(_ q: Double) -> String {
        guard q.isFinite else { return String(q) }
        if q == q.rounded(), abs(q) < 1e15 { return String(Int(q)) }
        return String(format: "%g", q)
    }
}
