import Foundation
import FernletDomainModel
import FernletFoundation
import FernletScoring
import FoodCatalog

// MARK: - JSON types

/// One ingredient line of a dish template as decoded from `DishTemplates.json`: a catalog search
/// term, the edible grams contributed per natural unit of the dish, and an optional preparation.
///
/// `search` (prefixed by `preparation` when present) becomes the ``DishTemplateLexicon`` catalog
/// query; `gramsPerUnit × count` gives the resolved quantity. `displayName` is a SEPARATE, human-
/// readable food name for the review sheet's "Couldn't find" card (research §26 fix 1.3) — the
/// matching `search`/`preparation` strings are optimized for the catalog's FTS gate ("ground beef
/// patty cooked broiled") and read badly sentence-cased as-is; `displayName` is what a person
/// recognizes ("Ground beef patty"). Both are food-name DATA in the same class as a catalog
/// `FoodItem.name`, not localized UI copy, and stay frozen English (`DishTemplateBindQuality`'s doc
/// comment explains why rendering one is not a localization-wall breach). Optional so a template
/// that omits it — none do today, but a future JSON edit could — degrades to the query-derived
/// sentence-cased fallback rather than failing to decode.
struct DishTemplateComponent: Decodable {
    let search: String
    let gramsPerUnit: Double
    let preparation: String?
    let displayName: String?
}

/// A per-alias component substitution inside a dish template (e.g. "salmon nigiri" swapping the
/// generic fish for salmon).
///
/// When the alias matches, its `componentOverrides` are ADDED to the template's base components
/// during assembly by default (`cheeseburger` = `burger`'s four base components + one cheese
/// component). `replacesBaseComponents` opts an alias OUT of that additive default when the override
/// names a food that already fully substitutes for the base — e.g. `vegetable fried rice` binds its
/// own catalog row (*Rice, fried, meatless*) INSTEAD OF the generic `fried rice` row, not alongside
/// it; additive semantics there would double-log the dish. Optional and defaulting to `false`/additive
/// so `cheeseburger`, written before this field existed, decodes and behaves unchanged.
struct DishTemplateAliasOverride: Decodable {
    let alias: String
    let componentOverrides: [DishTemplateComponent]
    let replacesBaseComponents: Bool?
}

/// One dish entry decoded from `DishTemplates.json`: canonical name, lookup aliases, natural unit
/// ("piece", "roll"…), a default count, and its ingredient components.
///
/// The backing data for the M2 deterministic tier — ``DishTemplateLexicon`` indexes every name and
/// alias, and `MealBuilder.defaultRecipeServings` reads `defaultCount` as the auto-mint yield hint.
struct DishTemplate: Decodable {
    let name: String
    let aliases: [String]
    let aliasOverrides: [DishTemplateAliasOverride]?
    let isComposite: Bool
    let unit: String
    let defaultCount: Double
    let components: [DishTemplateComponent]
}

/// A lexicon index hit: the matched template plus any alias-specific component overrides that the
/// matched key carried.
///
/// Produced by ``DishTemplateLexicon``'s lookup and consumed by its assembly and gram-bound paths.
struct DishTemplateMatch {
    let template: DishTemplate
    let componentOverrides: [DishTemplateComponent]
    /// Whether `componentOverrides` REPLACES `template.components` for this match instead of
    /// following them — see `DishTemplateAliasOverride.replacesBaseComponents`. `false` for every
    /// match through the template's own name/plain aliases (there is no override to replace with).
    let replacesBaseComponents: Bool

    /// The components this match actually resolves to — the single source both assembly and the
    /// gram-bounds path read, so they can never disagree about what an alias binds.
    var resolvedComponents: [DishTemplateComponent] {
        replacesBaseComponents ? componentOverrides : template.components + componentOverrides
    }
}

/// How strongly a dish template's components bound to catalog rows — the only honest signal this
/// tier has about whether its decomposition describes what the person actually ate.
///
/// `bound` counts components that produced an ingredient; `dropped` counts everything that fell out
/// of the meal — a component whose best catalog hit was below `FoodItemSearch.minimumBindScore`
/// (matched via category/tags only), or a whole named dish that produced no bindable component at
/// all; `weak` counts components that bound below `FoodItemSearch.confidentBindScore`; `minScore` is
/// the weakest bind score seen. Mirrors `FoundationDishDecomposition`'s `ComponentBinding` — the bind
/// gate every other tier of the quick-log cascade already applies (research §26 fix 1.2).
///
/// `unmatched` is the *visible* half of `dropped`: the human-readable names that ride out to
/// `MealResolution.unmatchedItems`, which forces review and renders in the review sheet's
/// "Couldn't find" card. A drop that is counted but not named is a meal quietly missing food — a
/// burger showing two rows with the patty gone and nothing on screen saying so.
struct DishTemplateBindQuality {
    private(set) var minScore = Int.max
    private(set) var bound = 0
    private(set) var dropped = 0
    private(set) var weak = 0
    private(set) var unmatched: [String] = []

    /// Records one component that bound at `score`.
    mutating func record(score: Int) {
        bound += 1
        minScore = min(minScore, score)
        if score < FoodItemSearch.confidentBindScore { weak += 1 }
    }

    /// Records one component whose best catalog hit was below the bind floor, so it was dropped from
    /// the meal. `displayName` is the component's JSON-declared human-readable name (research §26
    /// fix 1.3); `query` is its catalog query (preparation included, because what went missing from
    /// fried rice is FRIED rice, not rice) and is the fallback ONLY when a component predates
    /// `displayName` and the field decoded to nil.
    mutating func recordDropped(component query: String, displayName: String?) {
        dropped += 1
        appendUnmatched(displayName ?? Self.displayName(for: query))
    }

    /// Records one item of the description that matched a template but produced no bindable component
    /// at all, so no meal was built for it. The typed text is surfaced verbatim, matching what
    /// `MealResolution.unmatchedItems` documents.
    mutating func recordUnresolved(item text: String) {
        dropped += 1
        appendUnmatched(text.trimmingCharacters(in: .whitespaces))
    }

    /// Records one brand/retailer chip the typed description named that the matched template's
    /// key did not account for — the alias/name match consumed only PART of the text ("cheese pizza"
    /// out of "costco cheese pizza slice"), and the store/chain name silently vanished instead of
    /// steering resolution or getting flagged (research §26 fix 1.5, closing the exact gap
    /// `theTesterQueryNowRoutesToReviewNamingCostco` names). Counts as a drop, same as an unbound
    /// component, so it forces review the identical way `recordDropped` does.
    ///
    /// `chip` is surfaced EXACTLY as passed — the caller (`unaccountedBrandChips`) is responsible for
    /// handing this the user's own typed substring, verbatim, punctuation and casing intact
    /// ("Wendy's" stays "Wendy's"). Matches `recordUnresolved`'s documented verbatim convention.
    /// **Was** sentence-cased via `Self.displayName` (the lexicon's own spelling, "costco" →
    /// "Costco") until the fix's adversarial review, finding F3: that mangled the chip into neither
    /// the user's text nor a real catalog name, and diverged from `recordUnresolved` sitting right
    /// above this for no principled reason.
    mutating func recordUnmatchedBrandToken(_ chip: String) {
        dropped += 1
        appendUnmatched(chip)
    }

    /// Folds another item's bind quality into this one — one description can name several dishes,
    /// and the resolution is only as good as its worst component.
    mutating func merge(_ other: DishTemplateBindQuality) {
        minScore = min(minScore, other.minScore)
        bound += other.bound
        dropped += other.dropped
        weak += other.weak
        for name in other.unmatched { appendUnmatched(name) }
    }

    /// Appends a name to ``unmatched`` unless it is already there, preserving first-seen order.
    ///
    /// Two dishes in one description can drop the SAME component ("burger and BLT" both lose their
    /// lettuce). The review sheet renders this list with `ForEach(id: \.self)`, where a repeated
    /// element is undefined behaviour in SwiftUI — and "Lettuce, Lettuce" would be absurd copy even
    /// if it rendered.
    private mutating func appendUnmatched(_ name: String) {
        guard name.isEmpty == false, unmatched.contains(name) == false else { return }
        unmatched.append(name)
    }

    /// The FALLBACK review-sheet name for a component whose JSON declared no `displayName`: the raw
    /// catalog query, sentence-cased ("fried rice white cooked" → "Fried rice white cooked"). Every
    /// shipped component carries a real `displayName` as of research §26 fix 1.3, so this only fires
    /// for a template edited without one — it keeps the review sheet showing SOMETHING recognizable
    /// rather than failing to decode.
    ///
    /// **These strings are food-name DATA, not UI copy.** They are the same class as a catalog
    /// `FoodItem.name` ("Mozzarella Cheese", "Beans, black, mature seeds, cooked, boiled, with
    /// salt"), which this app already renders untranslated on every food surface — so rendering one
    /// here does not breach the localization wall, and they stay frozen English in the JSON because
    /// the un-fallback-to'd `search`/`preparation` strings they are derived from are also matching
    /// inputs.
    private static func displayName(for query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return trimmed }
        return String(first).uppercased() + trimmed.dropFirst()
    }

    /// The confidence these binds justify: `.high` only when every component bound at or above
    /// `FoodItemSearch.confidentBindScore` and none was dropped; `.low` otherwise (research §26
    /// fix 1.1 — this tier used to assert `.high` unconditionally).
    ///
    /// `.medium` is deliberately never produced here. `MealResolutionConfidence.needsReview` is
    /// `== .low`, so a `.medium` template resolution would still auto-commit — which is precisely
    /// the failure this derivation exists to close. Anything short of "every component bound
    /// confidently" therefore lands on `.low`, and the quick-log flow pauses on the review sheet
    /// before the meal counts toward the day.
    var confidence: MealResolutionConfidence {
        guard bound > 0, dropped == 0, weak == 0, minScore >= FoodItemSearch.confidentBindScore else {
            return .low
        }
        return .high
    }
}

/// The outcome of a dish-template resolution: the assembled meals plus the confidence their
/// component binds justify.
///
/// Replaces the bare `[Meal]?` the tier used to return, which left ``MealResolutionService`` with
/// nothing to judge and made it stamp `.high` on every template hit however badly the components
/// bound (research §26 fix 1.1).
///
/// `unmatchedItems` carries what fell out — dropped components and dishes that produced nothing — so
/// `MealResolution.needsReview` fires and the review sheet names them.
struct DishTemplateResolution {
    let meals: [Meal]
    let confidence: MealResolutionConfidence
    let unmatchedItems: [String]
}

/// The top-level shape of `DishTemplates.json` — a schema version plus the dish list.
///
/// Decoded once by ``DishTemplateLexicon``'s lazy catalog load; a decode failure degrades to an
/// empty lexicon rather than failing.
private struct DishTemplateFile: Decodable {
    let version: Int
    let dishes: [DishTemplate]
}

// MARK: - Lexicon

/// Loads DishTemplates.json once and provides deterministic dish lookup for the M2 fallback path.
///
/// The first deterministic tier of the quick-log cascade (``MealResolutionService``): when AI is off
/// or the AI tiers fall through, it matches composite dishes ("6 pieces salmon nigiri") by exact or
/// longest-substring name/alias, extracts a leading count, and assembles catalog-grounded meals via
/// ``MealBuilder``. It also supplies per-component gram bounds that ``MealDecompositionResolver``
/// uses to sanity-clamp the AI tier's estimates, and default yields for auto-minted recipes. A
/// missing or undecodable JSON degrades to an empty lexicon (every lookup misses).
enum DishTemplateLexicon {
    /// Single lazy load — both templates and the name index built together.
    private static let catalog: (templates: [DishTemplate], index: [String: DishTemplateMatch]) = {
        guard let url = Bundle.main.url(forResource: "DishTemplates", withExtension: "json") else {
            // Recovery: an empty lexicon — every lookup misses and the cascade falls to its next tier.
            FernletAuditLog.log("dishTemplates.load.failed", context: ["reason": "bundled resource missing"])
            return ([], [:])
        }
        let file: DishTemplateFile
        do {
            let data = try Data(contentsOf: url)
            file = try JSONDecoder().decode(DishTemplateFile.self, from: data)
        } catch {
            // A bundled resource that won't decode is a build error, not a runtime condition — name it
            // in DEBUG and log it in Release, then degrade to an empty lexicon (M2 tier disabled).
            assertionFailure("DishTemplates.json failed to load: \(error)")
            FernletAuditLog.log("dishTemplates.load.failed", context: ["error": error.localizedDescription])
            return ([], [:])
        }

        var index: [String: DishTemplateMatch] = [:]
        for template in file.dishes {
            for rawName in [template.name] + template.aliases {
                index[FoodItemSearch.normalized(rawName)] = DishTemplateMatch(
                    template: template,
                    componentOverrides: [],
                    replacesBaseComponents: false
                )
            }
            for override in template.aliasOverrides ?? [] {
                index[FoodItemSearch.normalized(override.alias)] = DishTemplateMatch(
                    template: template,
                    componentOverrides: override.componentOverrides,
                    replacesBaseComponents: override.replacesBaseComponents ?? false
                )
            }
        }
        return (file.dishes, index)
    }()

    /// Upper bound on a typed leading count ("6 pieces nigiri"): a plausible number of natural units of
    /// one dish. R5 — the count is user input and scales every component's grams.
    static let maxLeadingCount = 100.0

    // MARK: Lookup

    /// Returns the best-matching template and the count extracted from the item name.
    /// e.g. "6 pieces salmon nigiri" → (nigiriTemplate, 6.0)
    static func matchWithCount(_ itemName: String) -> (DishTemplate?, Double) {
        let details = matchDetailsWithCount(itemName)
        return (details.match?.template, details.count)
    }

    /// `matchedKey` is the normalized index key that actually produced `match`: for an exact match
    /// that is `norm` itself (the whole typed item IS the template, so nothing can be left over —
    /// "chipotle bowl" must not later read as an unaccounted "chipotle"); for a longest-substring
    /// match it is only the matched portion ("cheese pizza" out of "costco cheese pizza slice").
    /// Threaded out to ``resolve(description:mealType:catalog:)`` so it can tell what the match did
    /// NOT cover (research §26 fix 1.5) without re-deriving the same lookup a second time.
    private static func matchDetailsWithCount(
        _ itemName: String
    ) -> (match: DishTemplateMatch?, count: Double, matchedKey: String) {
        let norm = FoodItemSearch.normalized(itemName)
        let count = extractLeadingCount(from: norm)

        // Exact key match
        if let match = catalog.index[norm] {
            return (match, count ?? fallbackCount(norm: norm, template: match.template), norm)
        }
        // Longest-substring match (avoids "roll" matching "roll" in "spring roll blend"). Tie-broken
        // lexicographically on the key itself (research §26 fix 1.5 review finding F9): `catalog.index`
        // is a Dictionary, whose iteration order is hash-seed-randomized per process, so an unbroken
        // length tie used to pick whichever key iteration visited first — nondeterministic across
        // process launches. Harmless while `matchedKey` was internal; not harmless now that it feeds
        // user-visible unmatched-item text (fix 1.5). The tuple comparison makes the larger key win a
        // tie, an arbitrary but now-STABLE choice.
        let best = catalog.index
            .filter { norm.contains($0.key) }
            .max { ($0.key.count, $0.key) < ($1.key.count, $1.key) }
        if let best {
            return (best.value, count ?? fallbackCount(norm: norm, template: best.value.template), best.key)
        }
        return (nil, 1, "")
    }

    /// The count to use when the typed text carries no leading number (research §26 fix 1.4).
    ///
    /// Previously every uncounted mention fell back to `template.defaultCount` — a "typical order"
    /// guess (2 pizza slices, 2 tacos) baked in for the common case of a bare dish name. That guess is
    /// wrong the moment the person names the template's own UNIT WORD without a number: "pizza slice"
    /// or "a slice of pizza" is naming ONE slice, not asserting the typical-order default, and
    /// `defaultCount: 2` silently doubled it. When the typed text contains that unit word (singular
    /// form only — see ``namesOwnUnit(_:unit:)``), the count is 1; otherwise the prior default-count
    /// behavior is unchanged.
    private static func fallbackCount(norm: String, template: DishTemplate) -> Double {
        namesOwnUnit(norm, unit: template.unit) ? 1 : template.defaultCount
    }

    /// Whether `norm` (already `FoodItemSearch.normalized`) contains the template's `unit` word as a
    /// whole token — a frozen-English matching check, not display text (localization wall: `unit` is
    /// internal vocabulary the JSON declares, never shown to the user as-is).
    ///
    /// Deliberately SINGULAR-only: a plural mention ("2 slices", "tacos") either already carried a
    /// leading count (handled before this ever runs) or plausibly implies more than one, so it keeps
    /// falling back to `defaultCount` rather than being flattened to 1.
    private static func namesOwnUnit(_ norm: String, unit: String) -> Bool {
        let unitToken = FoodItemSearch.normalized(unit)
        guard !unitToken.isEmpty else { return false }
        return norm.split(separator: " ").map(String.init).contains(unitToken)
    }

    /// Whether the item name matches a template flagged as a composite dish (one made of several
    /// distinct components, like nigiri or a burrito).
    ///
    /// **Consumer-less as of 2026-08-22** — no call site in the app target reads this function or
    /// `DishTemplate.isComposite` (confirmed by grep during an adversarial review). It is outside
    /// current behavior: flipping a template's `isComposite` (as fix 1.3's fried-rice collapse did,
    /// true → false, matching its new single-component shape) changes no runtime path today. Kept
    /// because the field is still honest data about the template's shape and a future caller (a
    /// "decompose this dish" UI affordance, per the field's original intent) would read it correctly.
    static func isComposite(_ itemName: String) -> Bool {
        matchWithCount(itemName).0?.isComposite == true
    }

    // MARK: Component bounds

    /// Plausible gram ranges (0.5×–1.75× of the template amount) for each component of every dish the
    /// description names, keyed by normalized search term. Used by `MealDecompositionResolver` to
    /// clamp the AI tier's per-component gram estimates toward template reality.
    static func componentGramBounds(description: String) -> [String: ClosedRange<Double>] {
        var bounds: [String: ClosedRange<Double>] = [:]
        for itemName in MealItemSplitter.items(from: description) {
            let details = matchDetailsWithCount(itemName)
            guard let match = details.match else { continue }
            for component in match.resolvedComponents {
                let grams = max(component.gramsPerUnit * details.count, 1)
                let lower = max(1, grams * 0.5)
                let upper = max(lower, grams * 1.75)
                bounds[FoodItemSearch.normalized(component.search)] = lower...upper
                bounds[FoodItemSearch.normalized(catalogQuery(for: component))] = lower...upper
            }
        }
        return bounds
    }

    // MARK: Resolution

    /// Resolves `description` into `Meal`s using dish templates + the full food catalog, together
    /// with the confidence the component binds justify and whatever fell out along the way.
    ///
    /// Every item split from the description must be KNOWN to the lexicon: if any is unrecognised the
    /// whole call returns nil, so the next tier sees the entire description rather than half of it.
    /// But an item the lexicon knows and cannot build — a template whose every component drops — no
    /// longer discards its siblings: the successful dishes are kept and the failed item's text rides
    /// out in `unmatchedItems`, which forces the review sheet. Returning nil there destroyed the good
    /// half of "smoothie and tomato soup" and handed the whole description to a tier that answered
    /// with a peach-mango juice.
    ///
    /// The returned confidence is `.high` only when every component of every matched template bound
    /// confidently and nothing was dropped — see ``DishTemplateBindQuality/confidence``.
    static func resolve(
        description: String,
        mealType: MealType?,
        catalog: FoodCatalog
    ) -> DishTemplateResolution? {
        let items = MealItemSplitter.items(from: description)
        guard !items.isEmpty else { return nil }

        var resolvedMeals: [Meal] = []
        var quality = DishTemplateBindQuality()

        for itemName in items {
            let details = matchDetailsWithCount(itemName)
            guard let match = details.match else { return nil }  // an unknown item belongs to a later tier

            // research §26 fix 1.5: a brand/retailer chip the match's key didn't cover ("costco" out
            // of "cheese pizza" matching only "cheese pizza") silently vanishes unless named here.
            // Computed regardless of whether assembly below succeeds, but only ever RECORDED on the
            // success path, inside `assemble` — see the guard's comment (review finding F7) for why.
            let brandChips = unaccountedBrandChips(itemName: itemName, matchedKey: details.matchedKey)

            guard let assembled = assemble(
                match: match, count: details.count, itemName: itemName,
                mealType: mealType, description: description, catalog: catalog,
                unaccountedBrandChips: brandChips
            ) else {
                // review finding F7: `brandChips` is deliberately NOT recorded here.
                // `recordUnresolved` below already surfaces the WHOLE typed item verbatim, which
                // already contains whatever brand word was in it — a separate "Costco" chip alongside
                // "costco cheese pizza slice" would double-name the same problem. Unreachable today
                // (every shipped template that can name a brand also binds at least one component,
                // per `DishTemplateBindAuditTests`' full-catalog audit), kept as a guard against a
                // future template that could combine both rather than a live behavior.
                quality.recordUnresolved(item: itemName)
                continue
            }
            resolvedMeals.append(assembled.meal)
            quality.merge(assembled.quality)
        }

        guard resolvedMeals.isEmpty == false else { return nil }
        return DishTemplateResolution(
            meals: resolvedMeals,
            confidence: quality.confidence,
            unmatchedItems: quality.unmatched
        )
    }

    /// Verbatim, AS-TYPED chips for the brand/retailer tokens `itemName` names that `matchedKey` —
    /// the template name/alias that actually matched it — does not account for (research §26 fix 1.5).
    ///
    /// `matchedKey` equals ``FoodItemSearch/normalized(_:)`` of `itemName` exactly for an exact-key
    /// match, so a template whose OWN alias names a chain ("chipotle bowl") never false-positives: the
    /// token is inside the key by construction. It is only ever a strict prefix/substring of the
    /// normalized item for a longest-substring match, which is the one case where typed text can
    /// extend past what the template accounted for.
    ///
    /// Reuses ``FoodProductWebSearch/retailerTerms`` (store/grocer names — verified possessive-safe:
    /// "trader joe" already matches "trader joe's" as a plain substring with no collapsing needed) and
    /// ``FoodBrandLexicon/matchedChainTokens(in:)`` (restaurant chains, possessive-aware as of the
    /// review's finding F1) rather than a third parallel list. Returns each match's ORIGINAL substring
    /// out of `itemName` — not the lexicon's own spelling — so "Wendy's" surfaces as "Wendy's", not a
    /// sentence-cased "Wendys" (review finding F3, which also dissolves finding F8: `retailerTerms`
    /// stays undisplayed matching-input English, because what reaches the screen is the user's own
    /// text, never the lexicon term). §37 Q7 is an open owner question about token-boundary matching
    /// (over-matching a food word that collides with a chain name, like "chipotle" the pepper or
    /// "chilis" the vegetable — review finding F2, pinned not fixed) — deliberately not touched here.
    private static func unaccountedBrandChips(itemName: String, matchedKey: String) -> [String] {
        let itemNorm = FoodItemSearch.normalized(itemName)
        var terms: [String] = []
        for term in FoodProductWebSearch.retailerTerms
        where itemNorm.contains(term) && !matchedKey.contains(term) {
            terms.append(term)
        }
        for term in FoodBrandLexicon.matchedChainTokens(in: itemNorm) where !matchedKey.contains(term) {
            if !terms.contains(term) { terms.append(term) }
        }
        guard !terms.isEmpty else { return [] }

        let spans = possessiveCollapsedWordSpans(in: itemName)
        return terms.map { term in
            guard let range = spanOfTerm(term, in: spans) else {
                // Recovery: should not happen — `term` was just confirmed present in `itemNorm` (or
                // its possessive-collapsed form), and `spans` tokenizes + collapses `itemName` the
                // same way. Falls back to the lexicon's own spelling rather than dropping the chip.
                return term
            }
            return String(itemName[range])
        }
    }

    /// One run of letters/numbers in the ORIGINAL `itemName`, tagged with its own range and its
    /// individually-normalized spelling — the unit ``spanOfTerm(_:in:)`` searches over to recover a
    /// verbatim substring for a matched brand/retailer term (research §26 fix 1.5 review finding F3).
    private struct WordSpan {
        let normalized: String
        let range: Range<String.Index>
    }

    /// Tokenizes `itemName` into ``WordSpan``s the same way `FoodItemSearch.normalized` tokenizes
    /// text (a run of `isLetter || isNumber` characters is one word; anything else is a separator) —
    /// except each span keeps its ORIGINAL range in `itemName` instead of being flattened into one
    /// lowercase string. A lone "s" span is merged into the PRECEDING span (its normalized text
    /// appended, its range extended through the "s"), mirroring `FoodBrandLexicon`'s possessive
    /// collapse (review finding F1): a stripped apostrophe is the only realistic source of a
    /// standalone "s" token in typed food text, and merging the two spans' ORIGINAL ranges naturally
    /// recaptures the apostrophe that sat between them — "wendy" + "s" merges into the range spanning
    /// "wendy's" verbatim, punctuation and casing intact.
    private static func possessiveCollapsedWordSpans(in itemName: String) -> [WordSpan] {
        var spans: [WordSpan] = []
        var wordStart: String.Index?
        var index = itemName.startIndex
        while index < itemName.endIndex {
            let isWordChar = itemName[index].isLetter || itemName[index].isNumber
            if isWordChar, wordStart == nil {
                wordStart = index
            } else if !isWordChar, let start = wordStart {
                appendWordSpan(itemName: itemName, range: start..<index, into: &spans)
                wordStart = nil
            }
            index = itemName.index(after: index)
        }
        if let start = wordStart {
            appendWordSpan(itemName: itemName, range: start..<itemName.endIndex, into: &spans)
        }
        return spans
    }

    /// Appends one word's span to `spans`, collapsing it into the previous span when it is a lone
    /// possessive "s" (see ``possessiveCollapsedWordSpans(in:)``).
    private static func appendWordSpan(itemName: String, range: Range<String.Index>, into spans: inout [WordSpan]) {
        let normalized = FoodItemSearch.normalized(String(itemName[range]))
        if normalized == "s", let last = spans.indices.last {
            spans[last] = WordSpan(normalized: spans[last].normalized + "s", range: spans[last].range.lowerBound..<range.upperBound)
        } else {
            spans.append(WordSpan(normalized: normalized, range: range))
        }
    }

    /// Locates the ORIGINAL range in `itemName` that a matched `term` (a raw lexicon spelling like
    /// "wendys" or "trader joe") corresponds to: joins `spans`' normalized text with single spaces
    /// (character-identical to `FoodItemSearch.normalized` of the whole item, except wherever a
    /// possessive was collapsed), finds `term`'s FIRST occurrence in that one joined string — the same
    /// unanchored-substring rule the membership check uses — then maps the matched character range
    /// back to which span(s) it overlaps and returns their combined ORIGINAL range.
    ///
    /// Deliberately NOT a "grow a window from every start until it contains `term`" search: that
    /// shape has a real bug — searching "green chilis" for "chilis" from `start = 0` (word "green")
    /// finds it the moment the window grows to include "chilis" too, because the CONCATENATED string
    /// "green chilis" trivially contains "chilis" as its own suffix — returning "green chilis" instead
    /// of the tight "chilis" match. Locating the match ONCE in the fully-joined string and mapping
    /// back avoids manufacturing a false window match at every start position.
    private static func spanOfTerm(_ term: String, in spans: [WordSpan]) -> Range<String.Index>? {
        guard !spans.isEmpty else { return nil }
        var joined = ""
        var joinedRanges: [Range<String.Index>] = []
        for (index, span) in spans.enumerated() {
            if index > 0 { joined += " " }
            let start = joined.endIndex
            joined += span.normalized
            joinedRanges.append(start..<joined.endIndex)
        }
        guard let found = joined.range(of: term),
              let first = joinedRanges.firstIndex(where: { $0.upperBound > found.lowerBound }),
              let last = joinedRanges.lastIndex(where: { $0.lowerBound < found.upperBound }) else {
            return nil
        }
        return spans[first].range.lowerBound..<spans[last].range.upperBound
    }

    // MARK: Private assembly

    private static func assemble(
        match: DishTemplateMatch,
        count: Double,
        itemName: String,
        mealType: MealType?,
        description: String,
        catalog: FoodCatalog,
        unaccountedBrandChips: [String]
    ) -> (meal: Meal, quality: DishTemplateBindQuality)? {
        let template = match.template
        let bound = bindComponents(match.resolvedComponents, count: count, catalog: catalog)
        guard !bound.ingredients.isEmpty else { return nil }

        // research §26 fix 1.5 review finding F6: folded in BEFORE the confidence stamp below, not
        // after. The resolution-level confidence (`DishTemplateResolution.confidence`, `resolve`'s
        // outer accumulator) always reflected an unaccounted brand chip via `quality.merge` — but the
        // MEAL's OWN persisted stamp used to be computed from a component-binds-ONLY local copy that
        // never saw it, so a meal whose components all bound confidently but which also carried
        // "costco" persisted as "Food match" even though the resolution routed to review as `.low`.
        var quality = bound.quality
        for chip in unaccountedBrandChips {
            quality.recordUnmatchedBrandToken(chip)
        }

        let resolvedType = mealType ?? MealParser.classifyMealType(description)
        let displayName = itemName.trimmingCharacters(in: .whitespaces).isEmpty
            ? template.name.capitalized
            : itemName.capitalized
        let meal = MealBuilder.mealFromIngredients(
            itemName: displayName,
            resolvedIngredients: bound.ingredients,
            mealType: resolvedType,
            // The meal carries the same verdict as the resolution: a template whose components only
            // bound weakly (or which carries an unaccounted brand chip) is an estimate, and saying
            // "matched to a food" on it is the false label the research calls out (§6).
            confidenceToken: quality.confidence.mealConfidence.token
        )
        return (meal, quality)
    }

    /// Binds each template component to its best catalog row, applying the same bind floor the AI
    /// decomposition tier applies (`FoundationDishDecomposition.bindComponents`), and reports how
    /// well each one bound.
    ///
    /// A component whose top hit scores below `FoodItemSearch.minimumBindScore` matched via
    /// category/tags only — no real name signal — so it is DROPPED rather than silently contributing
    /// an unrelated food's macros; the drop is recorded so the resolution confidence can reflect the
    /// missing ingredient instead of hiding it (research §26 fix 1.2).
    private static func bindComponents(
        _ components: [DishTemplateComponent],
        count: Double,
        catalog: FoodCatalog
    ) -> (ingredients: [(FoodSelectionIngredient, FoodItem)], quality: DishTemplateBindQuality) {
        var ingredients: [(FoodSelectionIngredient, FoodItem)] = []
        var quality = DishTemplateBindQuality()
        for component in components {
            let query = catalogQuery(for: component)
            guard let match = catalog.scoredResults(for: query, limit: 1).first,
                  match.score >= FoodItemSearch.minimumBindScore else {
                quality.recordDropped(component: query, displayName: component.displayName)
                continue
            }
            quality.record(score: match.score)
            // R3/R5: no single template component may exceed the shared single-log gram cap, however
            // large a count the user typed.
            let grams = min(component.gramsPerUnit * count, MealPlausibility.maxSingleLogGrams)
            let ingredient = FoodSelectionIngredient(
                candidateId: 0,
                foodName: match.item.name,
                quantity: grams,
                unit: RecipeUnit.gram.rawValue
            )
            ingredients.append((ingredient, match.item))
        }
        return (ingredients, quality)
    }

    /// Every decoded dish template, in file order.
    ///
    /// The audit surface for `DishTemplateBindAuditTests`, which replays each component's catalog
    /// query against the shipped catalog and pins which ones clear the bind floor — the data-quality
    /// half of the same defect (research §26 fix 1.3 owns repairing the search strings this exposes).
    static var allTemplates: [DishTemplate] { catalog.templates }

    /// The catalog query one template component binds through: its `preparation` prefixed onto its
    /// `search` term when present.
    ///
    /// The single definition of that string — the gram-bounds path, the bind path, and the bind audit
    /// all build it here, so an audit can never measure a query the resolver does not actually run.
    static func catalogQuery(for component: DishTemplateComponent) -> String {
        let prep = (component.preparation ?? "").trimmingCharacters(in: .whitespaces)
        return prep.isEmpty ? component.search : "\(prep) \(component.search)"
    }

    // MARK: Count extraction

    /// Extracts a leading numeric count from a normalised item name, e.g. "6 pieces" → 6.
    ///
    /// The value comes straight from typed user text and is multiplied by `gramsPerUnit` downstream,
    /// so it is validated (finite, positive) and clamped to ``maxLeadingCount`` at this boundary —
    /// unclamped, "99999999999999999999 nigiri" would overflow the `Int(Double)` conversion inside
    /// `Macros.scaled(by:)` and trap.
    private static func extractLeadingCount(from normalized: String) -> Double? {
        guard let firstToken = normalized.split(separator: " ").first.map(String.init),
              let count = LocaleTolerantNumber.double(from: firstToken),
              count.isFinite, count > 0 else { return nil }
        return min(count, maxLeadingCount)
    }
}
