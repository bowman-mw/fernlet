// FoodIngredientIdentity.swift
// Ingredient-search round F5 (Docs/Ingredient-Search-Deep-Research-2026-09-29.md §8 F5, owner decision
// 2026-09-30: "for the recipe it's more important to rank the plain ingredients first"). Pure value
// logic: does a catalog row's NAME say that it IS the ingredient a person typed into a recipe line?

import Foundation

/// How a search surface orders the rows that passed the match gate and both of fix 1.8's floors.
///
/// Not persisted and not a token: a caller states it per call, and every entry point defaults to
/// ``standard`` so a surface that says nothing keeps the order it had.
public nonisolated enum FoodSearchRanking: Sendable, Equatable {
    /// History, source, data type, score, name — the order of every surface before F5, and still
    /// the order of quick-log, the meal composer, Adjust meal, the meal resolver and every
    /// confidence gate.
    case standard
    /// The recipe ingredient surfaces only — the recipe editor's typeahead and the swap sheet: a row
    /// that IS the typed ingredient (``FoodIngredientIdentity``) ranks ahead of one that merely
    /// contains its words, and the ``standard`` keys order each side.
    case ingredientIdentity
}

/// Decides whether a catalog row's name IS the ingredient a query names — the ingredient-identity
/// key of ``FoodSearchRanking/ingredientIdentity`` (ingredient-search round, F5).
///
/// **Why a key of its own.** The standard comparator sorts on data type before score, and its score
/// measures literal text overlap. Neither says "this row is the ingredient itself", so "brown sugar"
/// listed cereals that contain the phrase above USDA's "Sugars, brown", and "egg" listed survey
/// burritos above every egg (report §5). Identity answers that question per row, once, from the
/// row's own name, and the recipe ranking reads it ahead of every other key.
///
/// **What "is the ingredient" means here: the head noun.** A name's head is the last word of its
/// main noun phrase — "Bananas, raw" is bananas, "Cookies, chocolate chip, dry mix" is cookies, "Bread,
/// banana" is bread — and a row is the ingredient when its head is the query's last word, plural-aware
/// (``forms(of:)``). So a processed food whose head is a different noun ("Cookies, chocolate chip",
/// "Bread, banana", "Milk and cereal bar") is never the ingredient, however well its words match.
/// The rules that find the head, each for a naming convention the catalog really uses:
///
/// - **USDA's "Category, specific, qualifiers" form.** The first comma segment is the food. When that
///   segment is one of USDA's ingredient CLASSES (``classNames`` — "Cheese", "Spices", "Nuts",
///   "Squash", "Fish" …), the second segment names a member that stands alone as the ingredient
///   ("Cheese, parmesan" is parmesan, "Squash, zucchini" is zucchini), so its head counts too. When the
///   second segment only QUALIFIES the class (``qualifierSegments`` — "Squash, summer, zucchini",
///   "Chicken, broilers or fryers, thigh", "Pork, cured, bacon") or its head is one of the typed
///   modifiers ("Beef, flank, steak" for "flank steak"), the member is the third segment, and its head
///   counts as well. Dish and product categories ("Cookies", "Bread", "Soup", "Oil", "Flour") are
///   deliberately NOT classes: "Oil, olive" is not an olive and "Flour, almond" is not an almond.
///   USDA reference rows only (``followsReferenceNaming(of:)``).
/// - **A product name is read as one phrase** (every row that is not a USDA reference row: branded,
///   restaurant, scanned — and a person's own, less the echo rule, see the next rule). FDC product
///   descriptions are free-form, so two USDA conventions do not apply to them. A preposition in the
///   product phrase makes the row a composite ("Zucchini With Marinara", "Yeast With Poppy Seed Filling
///   Cake"), which is no head at all. And the first segment is the product only when every later
///   segment merely repeats its words — the catalog's `, <flavor>` echo ("Dark Chocolate Chips, Dark")
///   — or names a variant of it (``variantDescriptors``: "Chocolate Chips, Semi-sweet", "Salsa, Mild",
///   "Butter, Salted"); otherwise the first segment is a flavor list ("Lemon, Ginger Drink", "Lime,
///   Cherry, Berry Blue, … Jelly Beans") and the name gives no head
///   (``productPhraseCounts(_:personNamed:)``).
/// - **A person's own food is read by its first segment** (``isNamedByPerson(_:)``, fix round 2): the
///   person named it, so what follows the comma is theirs too — "Chicken breast, grilled" is chicken
///   breast, never a flavor list — and the echo requirement does not apply. A preposition still makes it
///   a composite ("Chicken with rice").
/// - **A phrase ends at a preposition** (``phraseEndWords``, USDA reference rows): "Pork with chili and
///   tomatoes" is pork, "Chicken, canned, no broth" says nothing about broth.
/// - **Coordination** ("or", "and", "&"): "Chicken or turkey salad" shares the head "salad"; two whole
///   phrases ("Egg omelet or scrambled egg", "Macaroni and cheese", "Wild Pacific Sardines Cumin &
///   Coriander") count only when both end in the same noun ("Half and half").
/// - **A part that is the food** (``partNouns``): "Ginger root" is ginger and "garlic cloves" are
///   garlic. Leaves are not on the list: grape and sweet-potato leaves are not grapes or sweet potatoes.
/// - **A one-word parenthetical is a synonym**: "Coriander (cilantro) leaves" is cilantro, "Green
///   onion, (scallion)" a scallion.
/// - **A seed spice is its plant** (``memberPartNouns``, class members only): "Spices, cumin seed" is
///   cumin, the spice a recipe calls cumin.
/// - **USDA's inverted compound**: USDA writes "tomato paste" as "Tomato, paste" and "cocoa powder" as
///   "Cocoa, dry powder" — the modifier first. When the first segment's head is one of the query's
///   modifiers, the second segment's head counts too (USDA reference rows only).
///
/// **Two levels: the compound the person typed.** For a query with modifiers ("whole milk", "olive
/// oil", "black pepper") the head alone cannot tell "Milk, whole" from "Milk, buttermilk, fluid, whole"
/// or "Oil, olive" from "Oil, corn, peanut, and olive". USDA's reference form can: it writes the kind
/// right after the food ("Milk, whole", "Oil, olive", "Beans, black") and, for a class, in the member's
/// qualifier ("Spices, pepper, black"). A reference row that says a typed modifier there
/// (``namesKind(_:modifierForms:)``) is ``compoundLevel``; the rest of the identity group is
/// ``ingredientLevel``. Product names never reach it — their word order is free, so "All Purpose Flour"
/// would otherwise leap over "Flour, wheat, all-purpose", which gives the kind one segment later — and
/// neither does any row in a brand query, where the brand tier already leads.
///
/// **The level is read below the person's own signals** (fix round 2): the recipe comparator
/// (`FoodItemSearch.ranksAhead`) puts every identity row above every other row, then orders the identity
/// group by history and source BEFORE the level. So a food the person made or scanned (a higher source)
/// or has logged (history) and that IS the ingredient still leads every USDA "Milk, whole" row, and the
/// level only orders USDA rows of equal history among themselves — reference above branded, which is
/// where "Milk, whole" beating "Milk, buttermilk, fluid, whole" and the branded milks is decided.
///
/// **Only a finished word is a head.** While a word is still being typed ("choc", "ban", "chocolate c")
/// the row that happens to end in those letters is an abbreviated product ("F1 CHSCK BAR CHOC"), not the
/// ingredient. So the key is off when the typed text ends in a single letter, and off when fewer than one
/// ranked row in ``completenessDivisor`` says the head as a whole word (``QueryHead/sharesHead(_:)``):
/// measured over the 160-query corpus, every unfinished prefix sits under 1% and every finished word
/// over 60%. Off means every row is 0 and the standard order stands, unchanged.
///
/// **What it cannot see.** A single-segment product name that puts its flavor LAST ("Cake Mix Extra
/// Moist Lemon", "Apple Cinnamon") reads like a plain noun phrase whose head is the flavor, so it still
/// counts; telling a flavor from a product noun there needs something other than the name. Nor can it
/// tell a flavor-first name whose second segment happens to be a variant word ("Southwest Cilantro,
/// Medium", a salsa) from the plain product.
///
/// Every word list here is a FROZEN ENGLISH MATCHING INPUT (localization wall): each is compared with
/// the catalog's English USDA names after `FoodItemSearch.normalized`, never displayed.
/// `LocalizationBoundaryTests.frozenIngredientIdentityWords` pins them.
///
/// Bounded (Power-of-10 R2/R3): a name is scanned for at most ``maxScannedCharacters`` characters and
/// ``maxSegments`` comma segments; every other loop walks one of those segments.
public nonisolated enum FoodIngredientIdentity {
    /// Words that end a name's main noun phrase: what follows them accompanies or qualifies the food.
    static let phraseEndWords: Set<String> = [
        "with", "in", "on", "from", "made", "without", "over", "served", "topped", "containing", "no", "for"
    ]

    /// Parts whose name is the food's own: "ginger root" is ginger, a garlic clove is garlic.
    static let partNouns: Set<String> = ["root", "roots", "clove", "cloves"]

    /// Parts that name the food only inside a class member: "Spices, cumin seed" is the spice cumin. Not
    /// a part elsewhere — "pumpkin seeds" are not a pumpkin.
    static let memberPartNouns: Set<String> = ["seed", "seeds"]

    /// USDA ingredient classes: a first segment whose member (the second segment) names the ingredient
    /// on its own. Taxonomic groups only — never a dish or product category.
    static let classNames: Set<String> = [
        "alcoholic beverage", "beef", "beverages", "cabbage", "candies", "cereals", "cheese", "chicken",
        "crustaceans", "duck", "egg", "fish", "game meat", "lamb", "leavening agents", "lettuce",
        "melons", "mollusks", "mushroom", "mushrooms", "nuts", "onions", "peppers", "pork", "seaweed", "seeds",
        "spices", "squash", "turkey", "veal"
    ]

    /// Second segments that qualify a class instead of naming its member, so the member is the third
    /// segment: "Squash, summer, zucchini", "Chicken, broilers or fryers, thigh", "Pork, fresh,
    /// shoulder", "Duck, domesticated, liver". Each is a whole segment, words joined by one space.
    /// Not "winter": its members are varieties named WITH the class ("spaghetti squash", "acorn
    /// squash"), and "Squash, winter, spaghetti" read as spaghetti pushed the pasta out of view.
    static let qualifierSegments: Set<String> = [
        "summer", "broilers or fryers", "broiler or fryers", "broiler", "fresh", "cured", "whole",
        "domesticated", "wild", "mixed species", "dark meat", "light meat", "roasting", "stewing", "retail parts"
    ]

    /// Words that name a variant of a product rather than a flavor, so a later segment made only of them
    /// (and the first segment's own words) still leaves the first segment the product: "Chocolate Chips,
    /// Semi-sweet", "Chocolate Chips, Semisweet Morsels", "Salsa, Mild", "Butter, Salted", "Peanut Butter,
    /// Creamy", "Almonds, Roasted Salted". Measured on the full candidate dumps (fix round 2): corpus
    /// plain rows in the six 449 → 455 with no rank pin moving, and on the held-out set "Breadcrumbs,
    /// Plain", "Salsa, Mild" and "Jalapenos, Hot" back in view. Only unlocks the first segment's head —
    /// a variant word is never a head itself.
    static let variantDescriptors: Set<String> = [
        "plain", "original", "mild", "medium", "hot", "salted", "unsalted", "semi", "sweet", "semisweet",
        "morsels", "classic", "regular", "natural", "organic", "raw", "roasted", "smooth", "creamy", "chunky"
    ]

    /// Coordinators, "or" before "and"; "&" is read as "and".
    static let coordinators = ["or", "and"]

    /// The identity of a row that IS the typed ingredient (its head is the query's).
    public static let ingredientLevel = 1

    /// The identity of a USDA reference row that is the ingredient AND says a typed modifier as its
    /// kind ("Milk, whole" for "whole milk") — see the type's "Two levels". The recipe comparator reads
    /// it after history and source, so it never lifts a USDA row over a person's own or logged food.
    public static let compoundLevel = 2

    /// The completeness gate: the head is a finished word when at least one ranked row in this many
    /// says it whole.
    public static let completenessDivisor = 10

    /// The most characters of a name the parser reads.
    static let maxScannedCharacters = 400

    /// The most comma segments the parser keeps (the food, its member, one qualifier).
    static let maxSegments = 3

    /// The query side of identity, prepared once per query.
    public struct QueryHead: Sendable, Equatable {
        /// Every spelling a row head may share with the query's head nouns (``forms(of:)``).
        public let forms: Set<String>
        /// Whole-word spellings of the head nouns: a row that says none of them cannot be the ingredient,
        /// so its name is never parsed.
        public let spokenForms: Set<String>
        /// Whole-word spellings of the LAST typed word alone — the completeness gate's test.
        public let lastWordForms: Set<String>
        /// Every spelling of the words typed before the head ("tomato" in "tomato paste"): the modifiers
        /// USDA's inverted compounds lead with.
        public let modifierForms: Set<String>

        /// Prepares `searchTokens` (`FoodItemSearch.searchTokens`) for identity; nil when the head noun
        /// has not been typed yet — no token, or the typed text (`normalizedQuery`) ends in one letter.
        public init?(searchTokens: [String], normalizedQuery: String) {
            guard let head = searchTokens.last, !head.isEmpty,
                  let lastTyped = normalizedQuery.split(separator: " ").last, lastTyped.count >= 2 else { return nil }
            var heads: Set<String> = [head]
            if FoodIngredientIdentity.partNouns.contains(head), searchTokens.count >= 2 {
                heads.insert(searchTokens[searchTokens.count - 2])
            }
            forms = heads.reduce(into: Set<String>()) { $0.formUnion(FoodIngredientIdentity.forms(of: $1)) }
            spokenForms = heads.reduce(into: Set<String>()) { $0.formUnion(FoodIngredientIdentity.spokenForms(of: $1)) }
            lastWordForms = FoodIngredientIdentity.spokenForms(of: head)
            modifierForms = searchTokens.dropLast().reduce(into: Set<String>()) {
                $0.formUnion(FoodIngredientIdentity.forms(of: $1))
            }
        }

        /// Whether a name whose tokens are `nameTokens` says a head noun as a whole word.
        public func isSaid(in nameTokens: Set<String>) -> Bool {
            !nameTokens.isDisjoint(with: spokenForms)
        }

        /// Whether the typed head is a finished word for this ranked set: at least one row in
        /// ``FoodIngredientIdentity/completenessDivisor`` says it whole. `nameTokenSets` is one entry
        /// per ranked row.
        public func sharesHead(_ nameTokenSets: [Set<String>]) -> Bool {
            guard !nameTokenSets.isEmpty else { return false }
            let saying = nameTokenSets.filter { !$0.isDisjoint(with: lastWordForms) }.count
            return saying * FoodIngredientIdentity.completenessDivisor >= nameTokenSets.count
        }

        /// `foodItem`'s identity for this query: 0 when its name is not the queried ingredient (no head
        /// noun shares a form with the query's), ``FoodIngredientIdentity/ingredientLevel`` when it is,
        /// and ``FoodIngredientIdentity/compoundLevel`` when it is a USDA reference row that also says a
        /// typed modifier as its kind — never in a brand query (`brandQuery`), whose tier leads instead.
        public func level(of foodItem: FoodItem, brandQuery: Bool) -> Int {
            let parsed = NameSegments(foodItem.name)
            let reference = FoodIngredientIdentity.followsReferenceNaming(of: foodItem)
            let heads = FoodIngredientIdentity.heads(
                of: parsed, referenceNaming: reference,
                personNamed: FoodIngredientIdentity.isNamedByPerson(foodItem), modifierForms: modifierForms
            )
            guard heads.contains(where: { !FoodIngredientIdentity.forms(of: $0).isDisjoint(with: forms) }) else {
                return 0
            }
            guard reference, !brandQuery, !modifierForms.isEmpty,
                  FoodIngredientIdentity.namesKind(parsed, modifierForms: modifierForms) else {
                return FoodIngredientIdentity.ingredientLevel
            }
            return FoodIngredientIdentity.compoundLevel
        }

        /// Whether `foodItem`'s name IS the queried ingredient, at either level.
        public func isNamed(by foodItem: FoodItem) -> Bool {
            level(of: foodItem, brandQuery: false) > 0
        }
    }

    // MARK: - Words

    /// A word and its regular singulars — "tomatoes" → tomatoe, tomato; "berries" → berry; "chips" →
    /// chip. Two words name the same noun when their forms intersect. Wider than
    /// `FoodItemSearch.matchVariants` (which adds only the trailing-s stem) because "tomatoes" must meet
    /// "Tomato, roma" and "potatoes" "Potato, …".
    public static func forms(of word: String) -> Set<String> {
        var forms: Set<String> = [word]
        let count = word.count
        if count >= 4, word.hasSuffix("s"), !word.hasSuffix("ss") { forms.insert(String(word.dropLast())) }
        if count >= 5, word.hasSuffix("es") { forms.insert(String(word.dropLast(2))) }
        if count >= 5, word.hasSuffix("ies") { forms.insert(String(word.dropLast(3)) + "y") }
        return forms
    }

    /// ``forms(of:)`` plus the regular plurals, so a name token in either number is recognised.
    static func spokenForms(of word: String) -> Set<String> {
        var spoken = forms(of: word)
        spoken.insert(word + "s")
        spoken.insert(word + "es")
        if word.hasSuffix("y") { spoken.insert(String(word.dropLast()) + "ies") }
        return spoken
    }

    // MARK: - Names

    /// Whether a row's name follows USDA's reference naming — "Category, specific, qualifiers", a
    /// class's member, a phrase that ends at a preposition, the inverted compound: USDA reference rows
    /// only. A product description (branded, restaurant, a person's own food) is free-form and is read
    /// as one product phrase instead (``productPhraseCounts(_:personNamed:)``).
    public static func followsReferenceNaming(of foodItem: FoodItem) -> Bool {
        guard foodItem.source == .usda else { return false }
        switch foodItem.dataType {
        case .foundation, .survey, .srLegacy: return true
        case .branded, .restaurant: return false
        }
    }

    /// Whether a row's name was written by the person — their own food (`.manual`: a custom food, a
    /// custom recipe ingredient) — so it is read by its first segment, without the product echo
    /// requirement (``productPhraseCounts(_:personNamed:)``). A scanned product (`.openFoodFacts`) keeps
    /// the product reading: its name is the label's, not theirs.
    public static func isNamedByPerson(_ foodItem: FoodItem) -> Bool {
        foodItem.source == .manual
    }

    /// The head nouns of a catalog name — see the type's documentation for each rule.
    /// `referenceNaming` (``followsReferenceNaming(of:)``) says which conventions apply, `personNamed`
    /// (``isNamedByPerson(_:)``) that a product-style name is the person's own; `modifierForms` are the
    /// query's words before its head (``QueryHead/modifierForms``), empty for a one-word query.
    public static func heads(
        ofName name: String, referenceNaming: Bool, personNamed: Bool = false, modifierForms: Set<String> = []
    ) -> Set<String> {
        heads(of: NameSegments(name), referenceNaming: referenceNaming, personNamed: personNamed, modifierForms: modifierForms)
    }

    /// ``heads(ofName:referenceNaming:personNamed:modifierForms:)`` on a name already parsed.
    static func heads(
        of parsed: NameSegments, referenceNaming: Bool, personNamed: Bool, modifierForms: Set<String>
    ) -> Set<String> {
        var heads = Set(parsed.synonyms)
        guard let food = parsed.segments.first, !food.isEmpty,
              referenceNaming || productPhraseCounts(parsed, personNamed: personNamed) else { return heads }
        let core = phraseCore(food)
        heads.formUnion(coordinatedHead(core))
        heads.formUnion(partOwner(core, parts: partNouns))
        guard referenceNaming, parsed.segments.count > 1 else { return heads }
        heads.formUnion(classMemberHeads(parsed.segments, modifierForms: modifierForms))
        // USDA's inverted compound: "Tomato, paste" for "tomato paste".
        if let foodHead = core.last, !forms(of: foodHead).isDisjoint(with: modifierForms),
           let memberHead = phraseCore(parsed.segments[1]).last {
            heads.insert(memberHead)
        }
        return heads
    }

    /// Whether a product name's first segment IS its product: it holds no preposition (a composite —
    /// "Zucchini With Marinara") and every later segment only repeats its words or names a variant (the
    /// `, <flavor>` echo, "Dark Chocolate Chips, Dark"; ``variantDescriptors``, "Salsa, Mild").
    /// Otherwise the first segment is a flavor or the first item of a list ("Lemon, Ginger Drink"). A
    /// name the person wrote (`personNamed`) needs no echo: its later segments are theirs.
    static func productPhraseCounts(_ parsed: NameSegments, personNamed: Bool) -> Bool {
        guard let food = parsed.segments.first, !food.contains(where: phraseEndWords.contains) else { return false }
        guard !personNamed else { return true }
        let said = Set(food)
        return parsed.segments.dropFirst().allSatisfy { segment in
            segment.allSatisfy { said.contains($0) || variantDescriptors.contains($0) }
        }
    }

    /// The heads a class category's member names: the second segment's, and the third's when the second
    /// only qualifies the class or names one of the typed modifiers (``readsThirdSegment(_:modifierForms:)``).
    static func classMemberHeads(_ segments: [[String]], modifierForms: Set<String>) -> Set<String> {
        guard segments.count > 1, classNames.contains(segments[0].joined(separator: " ")) else { return [] }
        var heads = memberHeads(segments[1])
        if segments.count > 2, readsThirdSegment(segments[1], modifierForms: modifierForms) {
            heads.formUnion(memberHeads(segments[2]))
        }
        return heads
    }

    /// Whether a class's second segment defers its member to the third: it is one of
    /// ``qualifierSegments``, or its head is one of the typed modifiers ("Beef, flank, steak").
    static func readsThirdSegment(_ second: [String], modifierForms: Set<String>) -> Bool {
        if qualifierSegments.contains(second.joined(separator: " ")) { return true }
        guard let head = phraseCore(second).last else { return false }
        return !forms(of: head).isDisjoint(with: modifierForms)
    }

    /// Whether a reference name says one of the typed modifiers as its food's kind: in the first
    /// segment's phrase, in the specific after it ("Milk, whole", "Oil, olive"), or — for a class — in
    /// the member's qualifier ("Spices, pepper, black"). Bounded by the three parsed segments.
    static func namesKind(_ parsed: NameSegments, modifierForms: Set<String>) -> Bool {
        let segments = parsed.segments
        let isClass = segments.first.map { classNames.contains($0.joined(separator: " ")) } ?? false
        let kindSegments = segments.prefix(isClass ? 3 : 2)
        return kindSegments.contains { segment in
            phraseCore(segment).contains { !forms(of: $0).isDisjoint(with: modifierForms) }
        }
    }

    /// The heads a class member names: each "or" alternative's last word, and a part's owner.
    static func memberHeads(_ member: [String]) -> Set<String> {
        var heads: Set<String> = []
        for alternative in alternatives(member) {
            let memberCore = phraseCore(alternative)
            if let last = memberCore.last { heads.insert(last) }
            heads.formUnion(partOwner(memberCore, parts: partNouns.union(memberPartNouns)))
        }
        return heads
    }

    /// The tokens before the first ``phraseEndWords`` word — empty when the segment opens with one.
    static func phraseCore(_ tokens: [String]) -> [String] {
        guard let end = tokens.firstIndex(where: phraseEndWords.contains) else { return tokens }
        return Array(tokens[..<end])
    }

    /// The head of a phrase that may be coordinated: its last word, unless two phrases are joined and
    /// end in different nouns, in which case it has none. A one-word first conjunct before a longer
    /// phrase shares that phrase's head ("chicken or turkey salad"); two single words are two phrases
    /// ("macaroni and cheese" is neither, "half and half" is half).
    static func coordinatedHead(_ core: [String]) -> Set<String> {
        guard let last = core.last else { return [] }
        guard core.count >= 3 else { return [last] }
        for coordinator in coordinators {
            guard let index = core[1..<(core.count - 1)].firstIndex(of: coordinator) else { continue }
            if index == 1, core.count > 3 { return [last] }
            let firstHead = core[index - 1]
            return forms(of: firstHead).isDisjoint(with: forms(of: last)) ? [] : [last]
        }
        return [last]
    }

    /// The owner of a part noun (one of `parts`) at the end of a phrase: "ginger root" → ginger.
    static func partOwner(_ core: [String], parts: Set<String>) -> Set<String> {
        guard core.count >= 2, let last = core.last, parts.contains(last) else { return [] }
        return [core[core.count - 2]]
    }

    /// A class member segment split on "or": "spring or scallions" → spring | scallions.
    static func alternatives(_ tokens: [String]) -> [[String]] {
        tokens.split(separator: "or").map(Array.init)
    }
}

/// A catalog name cut into comma segments of normalized tokens, with its one-word parentheticals.
///
/// Folds as `FoodItemSearch.normalized` does (diacritics and case, locale-independent; every run of
/// non-letters and non-digits separates words) in one pass, so the tokens are the index's own words.
/// Commas inside parentheses do not split ("Chickpeas (garbanzo beans, bengal gram)"), and "&" is read
/// as the word "and". Bounded by ``FoodIngredientIdentity/maxScannedCharacters`` and
/// ``FoodIngredientIdentity/maxSegments``.
///
/// **Per-keystroke cost.** It runs once per ranked row that says the typed head, so a finished broad
/// word ("chocolate", ~8,700 rows) parses thousands of names. It therefore walks Unicode scalars, not
/// grapheme clusters, and skips the Foundation fold for an ASCII name (nearly every catalog name),
/// whose fold is exactly its lowercasing.
nonisolated struct NameSegments {
    /// Up to ``FoodIngredientIdentity/maxSegments`` segments, each its words in order (a segment that
    /// held only a parenthetical is empty and keeps its place).
    private(set) var segments: [[String]] = [[]]
    /// Every parenthetical of exactly one word (of three letters or more) inside those segments.
    private(set) var synonyms: [String] = []
    private var word = ""
    private var parenthetical: [String] = []
    private var depth = 0

    /// Parses `name`.
    init(_ name: String) {
        let text = name.utf8.allSatisfy { $0 < 0x80 }
            ? name.lowercased()
            : name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        for scalar in text.unicodeScalars.prefix(FoodIngredientIdentity.maxScannedCharacters) {
            guard consume(scalar) else { break }
        }
        flushWord()
    }

    /// Whether `scalar` belongs to a word: `Character.isLetter`/`isNumber`'s categories, plus the marks
    /// a grapheme would carry with its letter.
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            return ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || ("A"..."Z").contains(scalar)
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    /// Takes one scalar; false once the segment limit is reached.
    private mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "(":
            flushWord()
            if depth == 0 { parenthetical = [] }
            depth += 1
        case ")":
            flushWord()
            guard depth > 0 else { return true }
            depth -= 1
            if depth == 0, parenthetical.count == 1, let only = parenthetical.first, only.count >= 3 {
                synonyms.append(only)
            }
        case "&":
            flushWord()
            appendWord("and")
        case "," where depth == 0:
            flushWord()
            guard segments.count < FoodIngredientIdentity.maxSegments else { return false }
            segments.append([])
        default:
            if Self.isWordScalar(scalar) { word.unicodeScalars.append(scalar) } else { flushWord() }
        }
        return true
    }

    private mutating func flushWord() {
        guard !word.isEmpty else { return }
        appendWord(word)
        word = ""
    }

    private mutating func appendWord(_ token: String) {
        if depth > 0 {
            parenthetical.append(token)
        } else if let last = segments.indices.last {
            segments[last].append(token)
        }
    }
}
