import Foundation
import FernletDomainModel

/// Whether a catalog query came directly from a person's search field or was synthesized by code.
/// History is a personalization signal for the former only; token filtering is an independent
/// retrieval choice and must never stand in for this context.
public nonisolated enum FoodSearchContext: Sendable, Equatable {
    case userTyped
    case machineGenerated
}

/// The app's food lookup surface — search, point lookups, and resolver candidate pools over the
/// bundled USDA/curated foods plus the user's own items.
///
/// Replaces the old in-memory `allFoodItems` array: the ~13k bundled USDA/curated foods live in a
/// read-only SQLite store (``BundledFoodSource``) and are queried on demand, while the small mutable
/// set of user-added items is held as a snapshot kept in sync from `FernletStore.foodItems` via
/// ``setUserItems(_:)``. Search runs the existing `FoodItemSearch` scorer over (SQLite candidates +
/// user items), preserving all of the preparation / form / data-type ranking; point lookups resolve
/// ingredient IDs straight from SQLite. A second ``BundledFoodSource`` — the ~364k-product branded
/// catalog delivered as a purgeable On-Demand Resource — can be attached and detached at runtime
/// (``attachBrandedSource(_:)`` / ``detachBrandedSource()``); every read unions base + branded +
/// user items with source priority user > base > branded.
///
/// Consumers span the module graph: `DiaryStore`, the app's `FernletStore` and meal-resolution /
/// barcode / grocery flows, and the walled `AIProviders` module all query it — this module sits
/// below the S3 wall and holds no sealed data, so that edge is wall-legal.
///
/// A third snapshot, added for research §26 fix 1.10, is the **local correction memory**: normalized
/// query → the food id the user picked when they replaced a wrong match for that query
/// (``setSearchAliases(_:)``). It is a pure ranking input on ``results(for:limit:stripsStopwords:)``,
/// holds no nutrition data of its own, and is empty on every catalog the app has not hydrated — so
/// the measured cold path (`Tests/FernletTests/FoodSearchCorpusTests`) is untouched by it.
///
/// A fourth, added for research §26 fix 1.9, is the **history profile**: the foods this user has
/// actually logged, weighted by frequency and recency (``setSearchHistory(_:)``). It is the top key
/// of the search comparator on ``results(for:limit:stripsStopwords:context:)`` for a TYPED query only, is
/// derived from `DiaryStore.recentMeals` rather than persisted anywhere new, and — like the alias
/// snapshot — is empty on any catalog the app has not hydrated.
///
/// Thread-safe: the SQLite source serializes its own access, and the user-items snapshot, the
/// correction-alias snapshot, the history profile and the branded-source slot are guarded by one
/// lock, so the catalog can be queried from any actor (the AI meal-resolution path runs off the main
/// actor) — hence the nonisolated `@unchecked Sendable` class.
public nonisolated final class FoodCatalog: @unchecked Sendable {
    private let source: BundledFoodSource
    private let lock = NSLock()
    private var _userItems: [FoodItem] = []
    /// Optional secondary bundled source — the full branded catalog delivered later via On-Demand
    /// Resource and purgeable at runtime. Guarded by the SAME `lock` as `_userItems`; every read
    /// snapshots it into a local `let` so a concurrent `detachBrandedSource()` mid-query is safe.
    private var _brandedSource: BundledFoodSource?
    /// Research §26 fix 1.10's snapshot: normalized query → the food id the user themselves chose
    /// for that query. Guarded by the SAME `lock` as `_userItems`; empty until the app pushes its
    /// device-local memory in via ``setSearchAliases(_:)``, which is what keeps every catalog built
    /// in a test (or before hydration) on the cold, alias-free path.
    private var _searchAliases: [String: UUID] = [:]
    /// Research §26 fix 1.9's snapshot: the weighted foods this user has actually logged. Guarded by
    /// the SAME `lock` as `_userItems`; ``FoodSearchHistory/empty`` until `DiaryStore` publishes one,
    /// which is what keeps every catalog built in a test (or before hydration) on the cold path.
    private var _searchHistory: FoodSearchHistory = .empty
    /// The fallback visits at most three variants × 24 rows × two bundled sources, plus this many
    /// user rows. It is intentionally smaller than the normal FTS cap: partial matching is a
    /// zero-result aid.
    private static let partialUserCandidateLimit = 72

    /// Creates a catalog over `source` with an empty user-items snapshot and no branded source.
    public init(source: BundledFoodSource) {
        self.source = source
    }

    /// Convenience for production: opens the bundled `FoodCatalog.sqlite`, falling back to an empty
    /// catalog (user items only) if the resource is missing. `bundle` defaults to this module's
    /// resource bundle (`.module`); it is passed as `nil` here because `.module` is synthesized as
    /// internal and cannot appear as a default-argument value in this public API.
    public static func bundled(bundle: Bundle? = nil) -> FoodCatalog {
        FoodCatalog(source: SQLiteBundledFoodSource(bundle: bundle) ?? InMemoryBundledFoodSource())
    }

    private var userItems: [FoodItem] {
        lock.lock(); defer { lock.unlock() }
        return _userItems
    }

    private var brandedSource: BundledFoodSource? {
        lock.lock(); defer { lock.unlock() }
        return _brandedSource
    }

    private var searchAliases: [String: UUID] {
        lock.lock(); defer { lock.unlock() }
        return _searchAliases
    }

    private var searchHistory: FoodSearchHistory {
        lock.lock(); defer { lock.unlock() }
        return _searchHistory
    }

    /// Keeps the catalog's view of user-added foods in sync with `FernletStore.foodItems`.
    public func setUserItems(_ items: [FoodItem]) {
        lock.lock(); _userItems = items; lock.unlock()
    }

    /// Publishes the local correction memory (research §26 fix 1.10): normalized query → the food id
    /// the user picked when they replaced a wrong match for that query.
    ///
    /// Replaces the snapshot wholesale, exactly like ``setUserItems(_:)`` — the app owns the durable
    /// copy (a device-local, never-synced sidecar) and re-publishes after every write, at launch, and
    /// after "Delete everything" (which pushes an empty map, so a wipe empties the live catalog too
    /// rather than leaving corrections answering searches until relaunch).
    ///
    /// **Bounded growth (Power-of-10 R3) is the WRITER's job**, as it is for `setUserItems`: the app's
    /// `FoodSearchCorrectionMemory` caps what it stores and evicts oldest-first, so this snapshot is
    /// bounded by that cap. Nothing here re-caps a map it did not author.
    public func setSearchAliases(_ aliases: [String: UUID]) {
        lock.lock(); _searchAliases = aliases; lock.unlock()
    }

    /// Publishes this user's meal history as a ranking input (research §26 fix 1.9).
    ///
    /// Replaces the snapshot wholesale, exactly like ``setUserItems(_:)`` and ``setSearchAliases(_:)``.
    /// `DiaryStore` owns the derivation and republishes on every `recentMeals` write — including the
    /// `recentMeals = []` inside `resetDiary()`, which is how a wipe empties the live catalog's copy
    /// instead of leaving it promoting the deleted meals' foods until the app relaunches.
    ///
    /// **No durable copy lives here or anywhere else.** The profile is derived from `recentMeals`,
    /// which is already in the synced snapshot; fix 1.9 adds no persisted surface of its own. See
    /// ``FoodSearchHistory``'s header for why that divergence from §26's data note was taken.
    ///
    /// **Bounded growth (Power-of-10 R3) is the WRITER's job**, as it is for `setUserItems`:
    /// `FoodSearchHistory.from(recentMeals:)` reads at most its own meal and component caps.
    public func setSearchHistory(_ history: FoodSearchHistory) {
        lock.lock(); _searchHistory = history; lock.unlock()
    }

    /// Captures the existing correction and derived-history inputs for one deterministic resolver
    /// pass. The snapshot is intentionally read-only: `DiaryStore.recentMeals` remains the only
    /// source of history and `FoodSearchCorrectionMemory` remains the only correction store.
    public func recentIngredientPersonalization() -> FoodIngredientPersonalization {
        lock.lock(); defer { lock.unlock() }
        return FoodIngredientPersonalization(corrections: _searchAliases, history: _searchHistory)
    }

    /// Attaches the optional branded catalog (e.g. once the On-Demand Resource has downloaded).
    /// Replaces any previously attached source. Every read unions base + branded + user items.
    public func attachBrandedSource(_ source: BundledFoodSource) {
        lock.lock(); _brandedSource = source; lock.unlock()
    }

    /// Drops the branded catalog (e.g. when the ODR is purged). Reads fall back to base + user items.
    public func detachBrandedSource() {
        lock.lock(); _brandedSource = nil; lock.unlock()
    }

    /// Whether a branded source is currently attached.
    public var hasBrandedSource: Bool {
        lock.lock(); defer { lock.unlock() }
        return _brandedSource != nil
    }

    /// Number of bundled foods — used by callers that previously guarded on `!foodItems.isEmpty`.
    /// Includes the branded source's rows when one is attached.
    public var bundledCount: Int { source.count + (brandedSource?.count ?? 0) }

    // MARK: - Search

    /// The top `limit` foods for a free-text query, ranked by the `FoodItemSearch` scorer over
    /// bundled + branded candidates plus the user items.
    ///
    /// As of research §26 fixes 1.6/1.7a/1.8 the two floors and the prepared-dish demotion apply
    /// here AND on the resolver's ``candidates(for:limit:)``, so the two surfaces no longer disagree
    /// about whether a dish outranks an ingredient or whether a tag-only row is presentable.
    ///
    /// They still differ in two ways, both deliberate. `candidates` splits the description into
    /// sub-phrases first, reaching rows a single AND gate cannot — and for exactly that reason it
    /// passes `stripsStopwords: false`, because in a sub-phrase a quantity word is the discriminator
    /// rather than leading noise. Fix 1.6 applies to the query a PERSON TYPED, which is this one.
    /// A third difference exists as of research §26 fix 1.10: a query the user has already corrected
    /// once returns their own choice first, ahead of — and independently of — the FTS gate. See
    /// ``promotingCorrection(_:for:limit:)``. `candidates(for:limit:)` inherits it by construction,
    /// because it draws its pool from this method; ``scoredResults(for:limit:stripsStopwords:)``
    /// deliberately does NOT (see its doc).
    ///
    /// **A fourth difference, research §26 fix 1.9: the history tier applies to a TYPED query only.**
    /// ``FoodSearchContext`` is the explicit discriminator; `stripsStopwords` remains solely a token-
    /// retrieval policy. `candidates(for:limit:)` passes `.machineGenerated` and gets cold ranking.
    /// That is a deliberate narrowing of §26's "add a tier to the comparator", for three measured
    /// reasons. (1) A sub-phrase is a FRAGMENT of a description, so promoting on it applies a
    /// whole-food signal to one word: an alias-style promotion on the sub-phrase `cheese` of
    /// `cheese pizza slice` is a cheese the user likes shouldering into a pizza decomposition. (2) The
    /// promotion DISPLACES — fix 1.10 measured one evicted row per fired phrase in an 18-row pool —
    /// and history is orders of magnitude denser than corrections (dozens of foods versus a handful),
    /// so the resolver pool would be substantially rewritten by it. (3) Keeping the pool cold means
    /// the resolver's bind firewall needs no new proof: `deterministicIngredients`' alias-free
    /// re-search, `bindConfidence`'s re-score and `retrievalGatedConfidence`'s cap are all measuring a
    /// pool this fix never touched.
    ///
    /// **Precedence, when a query has BOTH a correction and history (fix 1.10 vs fix 1.9): the
    /// correction wins**, structurally — history re-ranks inside `FoodItemSearch`, and
    /// `promotingCorrection` then prepends. That ordering is the intended one: a correction is an
    /// explicit statement ("when I type this, I mean that food") made by a person who was looking at
    /// the wrong answer, while history is an inference from behaviour. An inference must not overrule
    /// a statement. `FoodSearchHistoryCatalogTests` pins it rather than leaving it to code order.
    /// - Parameter stripsStopwords: See `FoodItemSearch.results(for:in:limit:stripsStopwords:)`.
    /// - Parameter context: `.userTyped` enables history; synthesized resolver/import queries pass
    ///   `.machineGenerated`. Required so every caller states which surface it serves.
    public func results(
        for query: String,
        limit: Int = 6,
        stripsStopwords: Bool = true,
        context: FoodSearchContext
    ) -> [FoodItem] {
        let rankingNow = Date()
        let normal = FoodItemSearch.results(
            for: query,
            in: index(for: query, stripsStopwords: stripsStopwords),
            limit: limit,
            stripsStopwords: stripsStopwords,
            history: context == .userTyped ? searchHistory : .empty,
            now: rankingNow
        )
        let ranked: [FoodItem]
        if normal.isEmpty, context == .userTyped {
            ranked = FoodItemSearch.partialResults(
                for: query,
                in: partialIndex(for: query, stripsStopwords: stripsStopwords),
                limit: limit,
                stripsStopwords: stripsStopwords,
                history: searchHistory,
                now: rankingNow
            )
        } else {
            ranked = normal
        }
        return promotingCorrection(ranked, for: query, limit: limit)
    }

    /// Like ``results(for:limit:)`` but pairs each item with its match score, for callers that gate
    /// on match quality (e.g. the meal-resolution review floor). Every row returned already carries
    /// every search token in its NAME.
    ///
    /// **Correction memory (fix 1.10) deliberately does not apply here.** A promoted correction has no
    /// score of its own, and every caller of this method spends the score on a CONFIDENCE gate —
    /// `minimumBindScore` / `confidentBindScore` in `DishTemplateLexicon` and
    /// `FoundationDishDecomposition` (fixes 1.1/1.2). Synthesising a score would silently let one
    /// correction promote a future quick-log past the review sheet, which is a different (and much
    /// larger) product decision than "show me my own answer first". The correction is a RETRIEVAL
    /// signal here, never a bind-confidence one.
    ///
    /// **This abstention is one of three defences, and on its own it is the weakest** — the 2026-08-23
    /// review found that the plan tier reaches its scores through `FoundationFoodSelectionModel`, which
    /// calls `FoodItemSearch.scoredResults(for:in:)` over its OWN index, not this method. The two that
    /// actually carry the weight are `FoundationFoodSelectionModel.deterministicIngredients`
    /// re-deriving every bind against an alias-free index, and `MealResolutionService.bindConfidence`
    /// re-scoring the whole item name through fix 1.8's `carries` floor. The AI-selection tier, which
    /// has neither, is capped by `MealResolutionService.retrievalGatedConfidence`.
    ///
    /// **Two ungated machine consumers of `results(for:limit: 1)` remain, both by design.**
    /// `MealResolutionService.fallbackMicronutrients` borrows the top row's micronutrient profile for a
    /// keyword-parsed meal — an ESTIMATE on a meal that is already `.low`/reviewed, where the user's
    /// own correction is a better guess than the scorer's — and
    /// `RecipeWebImporter.estimateMacrosFromIngredients` binds imported ingredient lines the same way,
    /// on a recipe the user reviews before saving.
    /// Neither gates auto-commit, so neither needs the floor above.
    ///
    /// Research §26 fix 1.9's history tier does NOT reach those consumers: resolver and importer
    /// callers explicitly pass `.machineGenerated`. Whether they strip stopwords is independent.
    public func scoredResults(for query: String, limit: Int = 6, stripsStopwords: Bool = true) -> [(item: FoodItem, score: Int)] {
        FoodItemSearch.scoredResults(for: query, in: index(for: query, stripsStopwords: stripsStopwords), limit: limit, stripsStopwords: stripsStopwords)
    }

    /// Puts the user's own remembered answer for `query` at rank 1 (research §26 fix 1.10).
    ///
    /// This is the "check aliases BEFORE the FTS gate" half of the fix: the promoted row is fetched by
    /// id, so it appears even when the FTS5 prefix-AND gate excludes it — which is the whole point,
    /// since the query that needed correcting is usually one whose gate returned the wrong rows (or
    /// none). A promotion never grows the result list: the row is de-duplicated out of `ranked` and the
    /// list is re-truncated to `limit`, so a caller asking for one row still gets one.
    ///
    /// **That truncation DISPLACES a row, and the displacement compounds through
    /// ``candidates(for:limit:)``.** The promoted food takes rank 1 and the previous last row of the
    /// window falls off — per FIRED PHRASE, so a resolver pool assembled from several sub-phrases loses
    /// one row for each phrase an alias answers (measured during the 2026-08-23 review: an alias on the
    /// SUB-PHRASE `cheese`, resolving the description `cheese pizza slice`, evicted
    /// *Cheeseburger (McDonalds)* from an 18-row pool — note the key was one word of the description,
    /// not the description itself, which is exactly how a short alias reaches many meals). Deliberate — the
    /// alternative is a pool one row longer than every caller's limit — but it means a correction is
    /// not purely additive, and a resolver bank pinned against a WARM catalog will differ from the cold
    /// one by more than the promoted row alone.
    ///
    /// Inert in three cases, all silent by design: no alias for this query, a query below
    /// `minimumQueryLength` (the searcher itself returns nothing there, so a two-letter key must not
    /// become a back door into the catalog), and an alias whose food no longer resolves — a branded
    /// row whose On-Demand Resource has been purged, or a user item since deleted.
    private func promotingCorrection(_ ranked: [FoodItem], for query: String, limit: Int) -> [FoodItem] {
        let aliases = searchAliases
        guard !aliases.isEmpty, limit > 0 else { return ranked }
        let key = FoodItemSearch.normalized(query)
        guard key.count >= FoodItemSearch.minimumQueryLength,
              let correctedID = aliases[key],
              let corrected = item(id: correctedID) else { return ranked }
        var promoted: [FoodItem] = [corrected]
        promoted.append(contentsOf: ranked.filter { $0.id != corrected.id })
        return Array(promoted.prefix(limit))
    }

    /// The single food whose normalized name equals `normalizedName`, or nil. Priority: the user's
    /// manual entries, then the base catalog, then the branded catalog, then remaining user items.
    public func exactNameMatch(forNormalized normalizedName: String) -> FoodItem? {
        let users = userItems
        let branded = brandedSource
        // Manual user entries win ties (source priority manual > usda > aiResolved), matching the old
        // in-memory `Index.exactNameMatch`.
        if let manual = users.first(where: { $0.source == .manual && FoodItemSearch.normalized($0.name) == normalizedName }) {
            return manual
        }
        if let bundled = source.exactMatch(normalizedName: normalizedName) { return bundled }
        if let brandedMatch = branded?.exactMatch(normalizedName: normalizedName) { return brandedMatch }
        return users.first(where: { FoodItemSearch.normalized($0.name) == normalizedName })
    }

    /// Builds the candidate pool a meal description should be resolved against, mirroring the legacy
    /// `FoodSelectionCandidateBuilder.candidates(for:foodItems:)` but sourcing matches from SQLite.
    public func candidates(for description: String, limit: Int = 18) -> [FoodSelectionCandidate] {
        var selected: [FoodItem] = []
        for phrase in FoodSelectionCandidateBuilder.searchPhrases(from: description) {
            // These are synthesized SUB-PHRASES: keep quantity tokens and keep history cold.
            for match in results(
                for: phrase, limit: 4, stripsStopwords: false, context: .machineGenerated
            ) where !selected.contains(where: { $0.id == match.id }) {
                selected.append(match)
                if selected.count >= limit { break }
            }
            if selected.count >= limit { break }
        }
        // Prefer raw ingredients over assembled/prepared dishes for a bare-ingredient query (mirrors
        // FoodSelectionCandidateBuilder.candidates), so the candidate pool the resolver/AI draws from
        // isn't dominated by FNDDS "sandwich"/"on-bun" composites that outrank raw foods on data-type.
        let ordered = PreparedDishHeuristic.demotingDishes(selected, forQuery: description)
        return ordered.enumerated().map { FoodSelectionCandidate(id: $0.offset + 1, foodItem: $0.element) }
    }

    /// `stripsStopwords` reaches the SOURCE, not just the scorer: retrieval and scoring must gate on
    /// the same token set or the fetch cap truncates a set the scorer never asked for.
    private func index(for query: String, stripsStopwords: Bool) -> FoodItemSearch.Index {
        let branded = brandedSource
        let candidates = source.candidates(forQuery: query, stripsStopwords: stripsStopwords)
            + (branded?.candidates(forQuery: query, stripsStopwords: stripsStopwords) ?? [])
        return FoodItemSearch.Index(foodItems: candidates + userItems)
    }

    /// Fetches only leave-one-out AND variants after normal retrieval produced no presented rows.
    /// Source and scorer share ``FoodItemSearch/partialQueryVariants(in:stripsStopwords:)``; no
    /// single-token OR query exists, and every source fetch is bounded before hydration.
    private func partialIndex(for query: String, stripsStopwords: Bool) -> FoodItemSearch.Index {
        let variants = FoodItemSearch.partialQueryVariants(in: query, stripsStopwords: stripsStopwords)
        let branded = brandedSource
        var selected: [FoodItem] = []
        for variant in variants {
            let base = source.candidates(
                forQuery: variant, stripsStopwords: stripsStopwords,
                limit: FoodItemSearch.partialMatchCandidateLimit)
            let brandedItems = branded?.candidates(
                forQuery: variant, stripsStopwords: stripsStopwords,
                limit: FoodItemSearch.partialMatchCandidateLimit) ?? []
            for item in base + brandedItems where !selected.contains(where: { $0.id == item.id }) {
                selected.append(item)
            }
        }
        for item in userItems.prefix(Self.partialUserCandidateLimit)
        where !selected.contains(where: { $0.id == item.id }) {
            selected.append(item)
        }
        return FoodItemSearch.Index(foodItems: selected)
    }

    // MARK: - Resolution

    /// Point lookup by food-item id: user items first, then the base catalog, then the branded catalog.
    public func item(id: UUID) -> FoodItem? {
        let branded = brandedSource
        return userItems.first(where: { $0.id == id }) ?? source.item(id: id) ?? branded?.item(id: id)
    }

    /// Resolves a scanned product barcode: user items first (a product the user already paired via
    /// the label-scan flow — their macros win), then the bundled catalog (only answers when the
    /// backing file is v2 with barcode data; the shipped v1 file returns nil). `raw` may be any
    /// scanner rendering (UPC-A/EAN-13/EAN-8/GTIN-14) — comparison is on the normalized GTIN.
    public func item(forBarcode raw: String) -> FoodItem? {
        guard let normalized = FoodBarcode.normalized(raw) else { return nil }
        let branded = brandedSource
        if let user = userItems.first(where: { FoodBarcode.normalized($0.barcode) == normalized }) {
            return user
        }
        return source.item(barcode: normalized) ?? branded?.item(barcode: normalized)
    }

    /// Batch point lookup — each id resolves from the first source that has it (user > base >
    /// branded). Results are grouped by source, not returned in the caller's `ids` order.
    public func items(ids: [UUID]) -> [FoodItem] {
        guard !ids.isEmpty else { return [] }
        let branded = brandedSource
        let wanted = Set(ids)
        let users = userItems.filter { wanted.contains($0.id) }
        var resolvedIDs = Set(users.map(\.id))
        let bundled = source.items(ids: ids.filter { !resolvedIDs.contains($0) })
        resolvedIDs.formUnion(bundled.map(\.id))
        let brandedItems = branded?.items(ids: ids.filter { !resolvedIDs.contains($0) }) ?? []
        // First source that has an id wins: user items > base > branded (dedupe by id).
        return users + bundled + brandedItems
    }

    /// The foods referenced by a single recipe's ingredients — what callers pass to MealBuilder /
    /// RecipeShareCodec instead of the whole catalog.
    public func items(forRecipe recipe: RecipeDefinition) -> [FoodItem] {
        items(ids: recipe.ingredients.map(\.foodItemId))
    }

    /// The foods referenced across several recipes (deduplicated) — for the meal-plan builder, which
    /// may match any existing recipe.
    public func items(forRecipes recipes: [RecipeDefinition]) -> [FoodItem] {
        items(ids: Array(Set(recipes.flatMap { $0.ingredients.map(\.foodItemId) })))
    }

    /// The (zero or one) food a recipe-editor input is currently bound to — enough to resolve its
    /// locked macros without materializing the full catalog.
    public func resolved(for input: ManualRecipeIngredientInput) -> [FoodItem] {
        items(ids: [input.selectedFoodItemId].compactMap { $0 })
    }
}
