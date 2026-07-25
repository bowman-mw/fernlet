import Foundation
import FernletDomainModel
import FernletScoring

/// One hand-authored "good source" of a tracked micronutrient — the F2 gap-filling
/// nudge's payload. Pinned to a real bundled-catalog `FoodItem` id so the card can
/// bind the food deterministically and offer "add it"; `normalizedNameFallback` is
/// the exact catalog `normalized_name` so a future catalog regeneration (which would
/// re-mint ids) can still resolve the food by name.
public nonisolated struct CuratedFoodSource: Codable, Sendable, Identifiable, Equatable {
    public let nutrientKey: String
    /// User-facing food name, as it appears in the nudge copy and is prefilled into
    /// the food-add flow (e.g. "lentils", "a banana"). Deliberately natural language,
    /// not the catalog's verbose USDA description.
    public let displayName: String
    /// Deterministic USDA id: `00000000-0000-5000-8000-<12-digit fdcId>`.
    public let foodItemId: UUID
    /// Exact catalog `normalized_name` — the id-independent regeneration fallback.
    public let normalizedNameFallback: String
    /// A gentle, portion-realistic note (not shown as clinical guidance).
    public let portionNote: String

    public var id: String { "\(nutrientKey)-\(foodItemId.uuidString)" }

    public init(nutrientKey: String, displayName: String, foodItemId: UUID, normalizedNameFallback: String, portionNote: String) {
        self.nutrientKey = nutrientKey
        self.displayName = displayName
        self.foodItemId = foodItemId
        self.normalizedNameFallback = normalizedNameFallback
        self.portionNote = portionNote
    }
}

/// Loads and serves the curated good-sources table (`CuratedNutrientSources.json`,
/// owned by this module via `Bundle.module`, mirroring `FoodCatalog.sqlite`). The
/// table is small (~55 rows) and read-once; there is no index or catalog query
/// involved — §3.3's deliberately cheap design.
public nonisolated final class CuratedNutrientSources: @unchecked Sendable {

    private struct Payload: Decodable {
        let version: Int
        let sources: [CuratedFoodSource]
    }

    /// All entries, in authored order. Order is meaningful: the nudge names the top
    /// 1-2 entries per nutrient deterministically.
    public let all: [CuratedFoodSource]
    private let byNutrient: [String: [CuratedFoodSource]]

    public init(sources: [CuratedFoodSource]) {
        self.all = sources
        // `Dictionary(grouping:)` preserves first-seen order within each group, so the
        // authored per-nutrient ordering survives.
        self.byNutrient = Dictionary(grouping: sources, by: { $0.nutrientKey })
    }

    /// Production loader — reads the bundled JSON. Falls back to an empty table (the
    /// nudge simply never names a food) rather than crashing if the resource is absent.
    /// `bundle` defaults to this module's resource bundle; `nil` resolves to `.module`
    /// (which, being synthesized as internal, cannot be a default-argument value).
    public static func bundled(bundle: Bundle? = nil) -> CuratedNutrientSources {
        let bundle = bundle ?? .module
        guard
            let url = bundle.url(forResource: "CuratedNutrientSources", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return CuratedNutrientSources(sources: [])
        }
        return CuratedNutrientSources(sources: payload.sources)
    }

    /// The shared production table.
    public static let shared = CuratedNutrientSources.bundled()

    /// Curated sources for a nutrient key, in authored order (may be empty).
    public func sources(for nutrientKey: String) -> [CuratedFoodSource] {
        byNutrient[nutrientKey] ?? []
    }

    /// The top `count` curated foods to name for a nutrient — the deterministic
    /// selection the AI-off path uses (§3.3: "the nudge names the top curated entry
    /// deterministically").
    public func topSources(for nutrientKey: String, count: Int = 2) -> [CuratedFoodSource] {
        Array(sources(for: nutrientKey).prefix(max(0, count)))
    }

    /// Resolves a curated source against a catalog: the pinned id first, then the
    /// normalized-name fallback (covers a catalog regeneration that re-mints ids).
    public func resolve(_ source: CuratedFoodSource, in catalog: FoodCatalog) -> FoodItem? {
        catalog.item(id: source.foodItemId)
            ?? catalog.exactNameMatch(forNormalized: source.normalizedNameFallback)
    }
}

/// Chooses the ambient nutrient nudge to show, as a pure nonisolated function so the
/// 7-vs-14-day window policy is unit-testable without the SwiftUI card.
public nonisolated enum NutrientNudgePlanner {

    public struct Plan: Equatable {
        public let gap: NutrientGap
        /// Curated foods to name — empty for a passive 7-day observation, populated only
        /// when a 14-day gap exists.
        public let foods: [CuratedFoodSource]
        public var namesFoods: Bool { !foods.isEmpty }

        public init(gap: NutrientGap, foods: [CuratedFoodSource]) {
            self.gap = gap
            self.foods = foods
        }
    }

    /// Selects the active nutrient nudge from the derived-signal gaps:
    /// 1. Dedups the 7-day and 14-day records to one entry per nutrient (§3.5 bug fix) —
    ///    the survivor carries the longest window for its key.
    /// 2. Keeps the passive observation on the 7-day window (`windowDays >= 7`).
    /// 3. Names curated foods only when the surviving gap is a 14-day gap (decision §11.1),
    ///    picking the top one or two in authored table order (deterministic).
    /// Among several eligible nutrients the choice is deterministic (nutrient-key order).
    public static func plan(
        from gaps: [NutrientGap],
        sources: CuratedNutrientSources,
        isActive: (String) -> Bool
    ) -> Plan? {
        let deduped = FernletScoring.dedupedNutrientGaps(from: gaps)
        guard let gap = deduped
            .filter({ $0.status == .gap && $0.windowDays >= 7 && $0.dataCoverageRatio >= 0.5 })
            .sorted(by: { $0.nutrientKey < $1.nutrientKey })
            .first(where: { isActive($0.nutrientKey) })
        else { return nil }

        let foods = gap.windowDays >= 14 ? sources.topSources(for: gap.nutrientKey, count: 2) : []
        return Plan(gap: gap, foods: foods)
    }
}

/// The user-facing copy for the ambient nutrient nudge, extracted here as a pure,
/// nonisolated helper so it is unit-testable (both for wording and for the
/// `DiagnosticLanguage` copy-safety gate) without instantiating the SwiftUI card.
///
/// Voice: a gentle observation, never a nag (§3, and matching the shipped card copy).
/// The copy never implies cycle/period awareness — iron needs vary with menstruation,
/// but that signal is walled off and must not surface here (§3.4).
public nonisolated enum NutrientNudgeCopy {

    /// The small eyebrow label on the card.
    public static let headline = "A gentle nudge"

    /// The passive observation (no food named) — the 7-day-window card's copy, kept
    /// identical to what shipped.
    public static func passive(nutrientName: String) -> String {
        "\(nutrientName) has been a little low lately. No pressure — a bit more when it's easy."
    }

    /// The food-naming suggestion (14-day-window gap): names the top one or two curated
    /// foods. Falls back to the passive copy when no food is available.
    public static func suggestion(nutrientName: String, foods: [CuratedFoodSource]) -> String {
        guard let phrase = foodPhrase(foods) else { return passive(nutrientName: nutrientName) }
        return "\(nutrientName) has been a little low lately. No pressure — \(phrase) would help when it's easy."
    }

    /// The "add it" affordance label.
    public static func addButtonLabel(food: CuratedFoodSource) -> String {
        "Add \(food.displayName)"
    }

    /// "lentils" / "lentils or chickpeas" — the top one or two food names, joined gently.
    public static func foodPhrase(_ foods: [CuratedFoodSource]) -> String? {
        let names = foods.prefix(2).map(\.displayName)
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        default: return "\(names[0]) or \(names[1])"
        }
    }
}
