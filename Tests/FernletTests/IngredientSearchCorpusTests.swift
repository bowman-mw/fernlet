// IngredientSearchCorpusTests.swift
// FernletTests
//
// F10 of Docs/Ingredient-Search-Deep-Research-2026-09-29.md — the measuring stick the rest of that
// report's fix list (F2, F1, F6, F7, F4a, F3 …) is gated on.
//
// WHAT THIS SUITE IS. It replays the 160-query recipe-ingredient corpus of
// `IngredientSearchReplayProbeTests` (55 baking, 45 produce, 47 pantry, 13 typing prefixes) through
// the exact call the recipe ingredient editor makes — `FoodCatalog.bundled()`'s
// `results(for:context: .userTyped, ranking: .ingredientIdentity)` at its default limit of SIX, the
// whole list the person sees (the identity-first order is F5's, 2026-09-30) — and pins, per query,
// where the first PLAIN form of the ingredient sits in those six rows and how many of the six are
// plain (the list's composition, which a first-row pin cannot see — F5's fix round 1), plus a few
// named rows the six must lead with, show or never show (`sixPins`).
//
// "PLAIN" IS A JUDGEMENT, AND IT IS WRITTEN DOWN. Each query carries an include regex, an optional
// exclude regex and (for the chocolate family) a "must name chocolate" guard, ported verbatim from the
// research's `replay/accept.py`. Those patterns were written from the query's recipe meaning before
// the probe output was read, and judge NAMES only. One was tightened here, as the report's verifiers
// asked: "carrot"/"carrots" no longer accept "Carrots, raw, salad" (an FNDDS coleslaw). One was
// widened by F6: "water" accepts SR Legacy's "Water, bottled, …" rows, which F6 restored. Two were
// widened by F5's fix round 2: "semisweet chocolate chips" and "semi sweet chocolate chips" accept
// "Chocolate Chips, Semi-sweet" — the catalog's inverted spelling, which the pattern read only in
// word order — as "milk chocolate chips" already accepted "Chocolate Chips, Milk Chocolate".
//
// …AND A PLAIN ROW MUST ALSO BE PHYSICALLY POSSIBLE. §4.1a found six #1 answers landing on branded
// rows whose macros cannot exist (per-100 g values stored against a 15 g label serving: 3,767 kcal
// per 100 g). A row counts only when `IngredientSearchCorpusTests.isPlausible` holds: at most
// 900 kcal per 100 g and no more macro grams than the serving weighs. `nameRank` records the
// names-only answer beside it, so a fix that corrects nutrition (F2) and a fix that moves ranking
// (F7, F3) each flip the column they are meant to.
//
// WHY IT IS GREEN WHILE A THIRD OF THE CORPUS IS WRONG. Like `FoodSearchCorpusTests`, the baseline is
// a photograph, not a specification: today's failures are the current-state expectation. A fix is a
// deliberate, reviewable edit — change the pins it is meant to move and the tuple they derive — and
// a pin that moves WITHOUT such an edit is exactly the regression this suite exists to catch. Re-take
// the photograph with the dump, never by hand:
//
//     TEST_RUNNER_INGREDIENT_CORPUS_DUMP=/abs/out.txt xcodebuild test-without-building … \
//       -only-testing:FernletTests/IngredientSearchCorpusTests
//
// writes every pin in paste-ready literal form.
//
// COLD CATALOG, LIKE THE PROBE. No user items, no correction aliases, no history — a fresh install.
// A device adds those three personal tiers on top (report §2.6's 30-second check).
//
// Read-only and self-contained: opens the shipped catalog read-only and shares no mutable fixture.
// One pass of 160 editor calls is ~10–20 s on the simulator (broad prefixes such as "choc" hydrate
// ~9,000 rows each, report §2.2), so the replay runs once, in one test.

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog

/// Which part of a recipe a corpus query was drawn from — the replay probe's four categories.
enum IngredientCorpusCategory: String, Sendable {
    /// Flour, sugar, chocolate chips, butter, eggs, oils …
    case baking
    /// Fruit, vegetables and herbs.
    case produce
    /// Proteins, grains, dairy, spices, condiments.
    case pantry
    /// A mid-word prefix a person passes through while typing ("choc", "chocolate c", "ban").
    case prefix
}

/// How one corpus query is judged: which row names count as a plain form of the ingredient.
///
/// The patterns are FROZEN ENGLISH MATCHING INPUTS (localization wall): they are matched against the
/// catalog's English USDA names and must never be localized.
struct IngredientCorpusJudge: Sendable {
    /// The research corpus category.
    let category: IngredientCorpusCategory
    /// The typed text, exactly as the probe replays it.
    let query: String
    /// The ingredient being typed. Equal to `query` except for a typing prefix, which is judged
    /// against the word the person is on the way to ("chocolate c" → "chocolate chips").
    let target: String
    /// Case-insensitive regex a plain row's name must match.
    let include: String
    /// Case-insensitive regex a plain row's name must NOT match, if any.
    let exclude: String?
    /// The chocolate family's second guard: the name must actually say chocolate (a bare
    /// "Chips, Salt And Vinegar" otherwise satisfies the all-optional prefix of the chips pattern).
    let requiresChocolate: Bool

    /// Builds one judge. `target` defaults to the query itself.
    init(
        _ category: IngredientCorpusCategory, _ query: String, target: String? = nil,
        _ include: String, _ exclude: String?, chocolate: Bool = false
    ) {
        self.category = category
        self.query = query
        self.target = target ?? query
        self.include = include
        self.exclude = exclude
        self.requiresChocolate = chocolate
    }
}

/// One query's pinned outcome today, in the editor's six-row list.
struct IngredientCorpusPin: Sendable, Equatable {
    /// The typed text.
    let query: String
    /// 1-based rank of the first visible row whose NAME is a plain form; nil when none of the six is.
    let nameRank: Int?
    /// The same, counting only rows that also pass the plausibility check; nil when none does.
    let plausibleRank: Int?
    /// How many of the six rows the judge accepts by NAME — the list's composition, not just its first
    /// plain row (fix round 1 of F5: identity once filled rows 2–6 of "lemon" with ginger drinks and
    /// gelatin while the first plain row stayed #1, and no rank pin moved).
    let plainInSix: Int
    /// Count nouns only (nil otherwise): whether that plausible plain row resolves "1 each" to
    /// nutrition — the banana case (report §3) — through a portion that IS one item. A branded label
    /// serving ("1 serving (35 g)", `BundledRowCorrection.rebasingBrandedNutrients`) converts but is a
    /// serving, not a count, so it reads false. False when no plausible plain row is visible.
    let eachConverts: Bool?

    /// Builds one pin; `each` is given only for the count-noun queries.
    init(_ query: String, _ nameRank: Int?, _ plausibleRank: Int?, plain: Int, each: Bool? = nil) {
        self.query = query
        self.nameRank = nameRank
        self.plausibleRank = plausibleRank
        self.plainInSix = plain
        self.eachConverts = each
    }

    /// The pin in the literal form this file declares it, for the dump.
    var literal: String {
        let name = nameRank.map(String.init) ?? "nil"
        let plausible = plausibleRank.map(String.init) ?? "nil"
        let each = eachConverts.map { ", each: \($0)" } ?? ""
        return "        .init(\"\(query)\", \(name), \(plausible), plain: \(plainInSix)\(each)),"
    }
}

/// A named row a query's six must show, lead with, or never show — the rows fix round 1 of F5 was
/// about, pinned by name because a rank pin cannot see them (the first plain row did not move).
struct IngredientCorpusSixPin: Sendable {
    /// The typed text.
    let query: String
    /// The exact name the six must lead with, if pinned.
    let leads: String?
    /// Exact names that must be among the six rows.
    let shows: [String]
    /// Exact names that must not be among the six rows.
    let hides: [String]
}

/// One judge with its regexes compiled once.
struct IngredientCorpusMatcher {
    /// The judge this matcher applies.
    let judge: IngredientCorpusJudge
    private let include: NSRegularExpression
    private let exclude: NSRegularExpression?
    private let chocolate: NSRegularExpression?

    /// Compiles `judge`'s patterns; throws on a malformed pattern rather than judging nothing.
    init(_ judge: IngredientCorpusJudge) throws {
        self.judge = judge
        include = try NSRegularExpression(pattern: judge.include, options: .caseInsensitive)
        exclude = try judge.exclude.map { try NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        chocolate = judge.requiresChocolate
            ? try NSRegularExpression(pattern: IngredientSearchCorpusTests.chocolateGuard, options: .caseInsensitive)
            : nil
    }

    /// Whether `name` is a plain form of the judged ingredient (names only; see `isPlausible`).
    func accepts(_ name: String) -> Bool {
        guard Self.matches(include, name) else { return false }
        if let chocolate, !Self.matches(chocolate, name) { return false }
        if let exclude, Self.matches(exclude, name) { return false }
        return true
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }
}

/// The F10 ingredient corpus: 160 editor calls pinned by plain-row rank, names-only and plausible.
///
/// See the file header for what a pin means and how to re-take the photograph.
struct IngredientSearchCorpusTests {
    /// **The measured baseline** (plausible plain row at #1, plausible plain row anywhere in the six).
    /// Derived from `pins` by `baselineTuplesAreDerivedFromThePins`; this is the only place the
    /// headline appears. A fix edits the pins it moves and this tuple, in the same commit.
    /// History: 91 / 127 on cf46b8eb; 96 / 131 with F2 (the branded per-100 g rebase made six
    /// names-only answers — semi sweet chips, sprinkles, both olive oils, cherry tomatoes, cider
    /// vinegar, dijon — physically possible); unchanged by F1(a); 103 / 136 with F6: the supplement
    /// restored salt, baking soda, "baking s" and water (water under the widened judge); retyping
    /// misfiled products out of the generic tier lifted black pepper, oregano, sprinkles, cocoa
    /// powder, olive oil and mayonnaise, and — by letting the dish-demotion window reach a branded
    /// "Onion Rings" row the heuristic reads as an ingredient — onion (see `FoodSearchCorpusTests`'
    /// review battery); the one-row-per-name collapse lifted tomatoes. Shrimp fell 2 → 3: the row it
    /// had landed on was the misfiled product "Cooked Shrimp", which left the generic tier.
    /// 112 / 144 with F7: the curated aliases put USDA's "Candies, semisweet chocolate" first for
    /// chocolate chip(s) and the four typing prefixes "chocolate c/ch/chi/chip", "Spices, pepper, red
    /// or cayenne" for red pepper flakes, the soybean salad or cooking oil for vegetable oil, and the
    /// SR "Garlic, raw" for garlic clove (2 → 1).
    /// 136 / 151 with F5 (2026-09-30), when the recipe editor's call began ranking by ingredient
    /// identity (`FoodIngredientIdentity`): 36 pins moved, every one up and none down — brown sugar,
    /// brown rice and green beans from out of view to #1; butter, yeast, lemon, corn, shrimp, canola oil,
    /// cheddar, mozzarella, parmesan, cinnamon, chicken broth, water, bread flour, cocoa powder, dark
    /// chocolate chips, graham crackers, tomato, black beans, white rice, bread and "chocolate" to #1;
    /// whole milk, apple, apples and rice into view; sugar, milk chocolate chips, olive oil, tomatoes,
    /// bacon, salmon, tofu and mayonnaise up within it.
    /// 139 / 151 with F5's fix round 1: a USDA reference row that names the typed compound leads
    /// ("Milk, whole" 4 → 1, "Oil, olive" 2 → 1), and a branded product whose first segment is only a
    /// flavor is no longer the ingredient ("Tater Chips, Milk Chocolate" left #1 for real milk
    /// chocolate chips, 2 → 1). No pin moved down.
    static let measuredBaseline = (plainAtOne: 139, plainVisible: 151)

    /// The names-only baseline beside it — the report's §4.1 table (97 at #1, 132 visible on
    /// cf46b8eb), which judged names without nutrition. Kept so the gap between the two is visible.
    /// 113 / 145 before F5, 137 / 152 with it, 140 / 152 with its fix round 1 (the gap is still white
    /// chocolate chips).
    static let nameOnlyBaseline = (plainAtOne: 140, plainVisible: 152)

    /// Count-noun queries whose first plausible plain VISIBLE row takes "1 each". Zero on cf46b8eb:
    /// the report's §4.3 "1 of 26" counted "1 each" OR "1 piece" on the first plain row of the top
    /// 10 ("Chicken breast, roasted" takes "1 piece" only). One with F2: "garlic clove" lands on a
    /// branded jar whose label serving became its "each" (15 g — a serving, not a clove; since F7 it
    /// lands on USDA's raw garlic and its own 3 g clove, still one of the count). Seventeen
    /// with F4a, from the rows' own USDA counts: banana(s) and onions to their medium, eggs to the
    /// Foundation row's 50.3 g egg, lemon to the fruit its NLEA serving names, lime, orange, carrot(s),
    /// cucumber, jalapeno, grape tomatoes, corn tortillas and zucchini. Still refused: apple(s), egg,
    /// potato, sweet potato (no plain row in view), avocado and tomato (RACC-only rows), bell
    /// peppers, chicken, graham crackers and marshmallows. Eighteen with F5: graham crackers' first
    /// plain row became the branded "Graham Crackers" #1, whose label serving is its "each". Seventeen
    /// again with F5's fix round 1, which stopped counting a label serving as an item
    /// (`countsOneItem`): "9 graham crackers" on that row is nine 35 g servings, not nine crackers, so
    /// the F5 "gain" was a unit regression, now named in the round's worsened list.
    static let eachBaseline = 17

    /// How many of the 960 visible rows (160 queries × six) the judges accept by name — the six
    /// lists' composition in one number, derived from the pins' `plainInSix` (fix round 1 of F5, from
    /// the reviewers' measurement: 366 on the standard order, 438 with F5 as first built, when branded
    /// flavor lists and composites filled the lists behind a first plain row that never moved; 449
    /// once a product name is read as one phrase and a qualified USDA class names its member third).
    /// 455 with fix round 2, when a later segment of variant words ("Chocolate Chips, Semi-sweet",
    /// "Chocolate Chips, Semisweet Morsels") stopped reading as a flavor list: chocolate chips 3 → 5 and
    /// chocolate chip 2 → 4 (the baking query and the typing prefix). The two semi-sweet judges were
    /// widened in the same commit to accept "Chocolate Chips, Semi-sweet" (see the file header);
    /// without that, "semi sweet chocolate chips" would have read 6 → 5 for a row that is plainly one.
    static let plainRowsInSixBaseline = 455

    /// The description `BundledRowCorrection.rebasingBrandedNutrients` gives a branded label serving
    /// it keeps as the row's count portion — a serving, not an item.
    static let labelServingPrefix = "1 serving ("

    /// The named rows (fix round 1 of F5): the flavor-first product lists and composites identity once
    /// counted as the ingredient (hidden), the canonical USDA rows they pushed out of view (shown), and
    /// the typed compounds' own rows (leading). Fix round 2 adds the plain products whose later segment
    /// is a variant, not a flavor ("Chocolate Chips, Semi-sweet", "Salsa, Mild", "Breadcrumbs, Plain"),
    /// which round 1's echo rule dropped — salsa and breadcrumbs are held-out ingredients, outside the
    /// corpus. Exact catalog names — the catalog is never regenerated.
    static let sixPins: [IngredientCorpusSixPin] = [
        .init(query: "lemon", leads: "Lemons, raw, without peel", shows: [], hides: [
            "Lemon, Ginger Drink, Lemon, Ginger", "Lemon, Lime Gelatin Mix, Lemon, Lime",
            "Lemon, Sea Salt And Extra Virgin Olive Oil Crackers, Lemon, Sea Salt"
        ]),
        .init(query: "lime", leads: "Limes, raw", shows: [], hides: [
            "Lime, Cherry, Berry Blue, Strawberry, Orange Jelly Beans, Orange",
            "Lime, Lemongrass, & Sweet Coconut Thai Green Curry Starter, & Sweet Coconut"
        ]),
        .init(query: "zucchini", leads: "Squash, zucchini, baby, raw",
              shows: ["Squash, summer, zucchini, includes skin, raw"], hides: [
            "Roasted Vegetable Zucchini, Spinach, Eggplant, Peppers, & Broccoli Pizza, Roasted Vegetable",
            "Grifled Zucchini, Butternut Squash & Tomatoes With Quinoa Duo Quinoa Blends, Butternut Squash & Tomatoes"
        ]),
        .init(query: "avocado", leads: "Avocado, Hass, peeled, raw", shows: [], hides: [
            "Avocado, Cucumber, And Surimi Topped With Shrimp", "Avocado, Cilantro & Lime Flavor Crackers, Cilantro & Lime"
        ]),
        .init(query: "basil", leads: "Basil, fresh", shows: ["Spices, basil, dried"],
              hides: ["Basil, Garlic & Oregano Diced Tomatoes, Garlic & Oregano"]),
        .init(query: "cilantro", leads: "Coriander (cilantro) leaves, raw", shows: [],
              hides: ["Cilantro With Lime Fully Cooked Chicken Sausage, Cilantro With Lime"]),
        .init(query: "strawberries", leads: "Strawberries, raw", shows: [],
              hides: ["Strawberries, Mangoes, Bananas Tropical Blend, Strawberries, Mangoes, Bananas"]),
        .init(query: "chicken thighs", leads: nil,
              shows: ["Chicken, broilers or fryers, thigh, meat only, cooked, roasted"], hides: ["Pollo Adobado Chicken Thighs"]),
        .init(query: "whole milk", leads: "Milk, whole, 3.25% milkfat, with added vitamin D", shows: [], hides: []),
        .init(query: "olive oil", leads: "Oil, olive, salad or cooking", shows: [], hides: []),
        .init(query: "milk chocolate chips", leads: "Milk Chocolate Premium Baking Chips, Milk Chocolate", shows: [], hides: []),
        .init(query: "black beans", leads: "Beans, black, mature seeds, raw", shows: [], hides: []),
        .init(query: "chocolate chips", leads: "Candies, semisweet chocolate",
              shows: ["Chocolate Chips, Semi-sweet", "Chocolate Chips, Semisweet Morsels"],
              hides: ["100% Cacao Organic Baking Chocolate Chips, 100% Cacao"]),
        .init(query: "salsa", leads: "Salsa", shows: ["Salsa, Mild", "Salsa, Medium", "Salsa, Hot"], hides: []),
        .init(query: "breadcrumbs", leads: "Breadcrumbs, Plain", shows: [], hides: []),
    ]

    /// The count-noun queries — the research's `replay/units.py` list. Frozen English matching inputs.
    static let countNouns: Set<String> = [
        "banana", "bananas", "apple", "apples", "lemon", "lime", "orange", "avocado", "tomato",
        "tomatoes", "onion", "red onion", "yellow onion", "garlic clove", "carrot", "carrots", "potato",
        "sweet potato", "cucumber", "bell pepper", "red bell pepper", "jalapeno", "egg", "eggs",
        "zucchini", "tortillas", "chicken breast", "chicken thighs", "graham crackers", "marshmallows"
    ]

    /// The chocolate family's second guard (`replay/accept.py`'s REQUIRE).
    static let chocolateGuard = #"chocolate|semi[- ]*sweet|morsel|cacao"#

    /// Names of composite products that contain an ingredient word without being the ingredient.
    static let composite = #"cookie|cake|brownie|muffin|bar\b|bars\b|granola|ice cream|yogurt|trail mix|pancake|waffle|biscuit|dough|cereal|bread|pie\b|crust|candy bar|smoothie|shake|frosting|pudding|mix\b|cupcake|scone|donut|doughnut|sandwich|cracker|pretzel|popcorn|madeleine|croissant|bagel|wafer|protein|snack|cluster|bite|bark|fudge|truffle|drink|beverage|latte|mocha|coffee|cheesecake|tart|danish|roll\b|loaf|flatbread|oatmeal|kit|cone"#

    /// The chips family's exclusion: every composite plus the savoury and non-chocolate "chips".
    static let chipExclusion = composite + #"|toffee|almond|tater|butterscotch|peanut butter chip|potato|tortilla|corn chip|banana chip|coconut chip|apple chip|kale chip|veggie chip|pita"#

    // MARK: - The judges (report replay/accept.py, ported verbatim; carrot tightened)

    static let judges: [IngredientCorpusJudge] = [
        .init(.baking, "all-purpose flour", #"^flour, wheat, all-purpose|wheat flour, white, all-purpose|all[- ]purpose (\w+ )?flour"#, #"mix|tortilla|gluten free|gluten-free|cake|pancake|biscuit|batter|baking mix|bread\b"#),
        .init(.baking, "flour", #"^flour, wheat, (all-purpose|bread)|^flour, whole wheat|^wheat flour, white|^wheat flour, whole|all[- ]purpose (\w+ )?flour$|^(unbleached |enriched |bleached )*(all[- ]purpose |bread |whole wheat )?flour$"#, #"mix|tortilla|cake|pancake|biscuit|batter"#),
        .init(.baking, "bread flour", #"^flour, wheat, bread|^wheat flours?, bread|wheat flour, white, bread|^(unbleached |enriched |organic )*bread flour$"#, #"mix"#),
        .init(.baking, "whole wheat flour", #"^flour, whole wheat|wheat flour, whole|^(organic |stone ground )*whole[- ]wheat (\w+ )?flour$|whole grain wheat flour"#, #"mix|pastry"#),
        .init(.baking, "sugar", #"^sugars?, granulated|^(pure )?(cane )?(granulated )?sugar$|^granulated (white |cane )?sugar$|^sugar, (granulated|white)"#, nil),
        .init(.baking, "granulated sugar", #"^sugars?, granulated|^(pure )?(cane )?granulated (white |cane )?sugar$"#, nil),
        .init(.baking, "brown sugar", #"^sugars?, brown|^(pure cane )?(light |dark |golden )?brown sugar$"#, nil),
        .init(.baking, "powdered sugar", #"^sugars?, powdered|^(10x )?powdered sugar$|^confectioners'? (powdered )?sugar$"#, nil),
        .init(.baking, "baking soda", #"leavening agents, baking soda|^(pure )?baking soda$"#, nil),
        .init(.baking, "baking powder", #"leavening agents, baking powder|^(double acting )?baking powder$"#, nil),
        .init(.baking, "vanilla extract", #"^vanilla extract|^(pure |imitation )?vanilla extract$"#, #"flavored|syrup"#),
        .init(.baking, "cocoa powder", #"^cocoa, dry powder, unsweetened|^(100% |natural |unsweetened |dutch[- ]process(ed)? |baking |pure )*(cocoa|cacao)( powder)?$"#, #"mix|drink|hot|beverage|(?<!un)sweetened"#),
        .init(.baking, "chocolate chips", #"^candies, semisweet chocolate$|^(organic |premium |real |pure )*(mini |big |mega )*(semi[- ]*sweet |bittersweet |dark |milk |white )?(chocolate )?(flavored )?(baking )?(chips|morsels)\b"#, chipExclusion, chocolate: true),
        .init(.baking, "chocolate chip", #"^candies, semisweet chocolate$|^(organic |premium |real |pure )*(mini |big |mega )*(semi[- ]*sweet |bittersweet |dark |milk |white )?(chocolate )?(flavored )?(baking )?(chips|morsels)\b"#, chipExclusion, chocolate: true),
        .init(.baking, "semisweet chocolate chips", #"^candies, semisweet chocolate$|(semi[- ]*sweet).*(chips|morsels)|^chocolate chips, semi[- ]*sweet"#, chipExclusion, chocolate: true),
        .init(.baking, "semi sweet chocolate chips", #"^candies, semisweet chocolate$|(semi[- ]*sweet).*(chips|morsels)|^chocolate chips, semi[- ]*sweet"#, chipExclusion, chocolate: true),
        .init(.baking, "dark chocolate chips", #"(dark|bittersweet).*chocolate.*(chips|morsels)|^candies, semisweet chocolate$"#, chipExclusion, chocolate: true),
        .init(.baking, "milk chocolate chips", #"^candies, milk chocolate$|milk chocolate.*(chips|morsels)|^chocolate chips, milk chocolate"#, chipExclusion, chocolate: true),
        .init(.baking, "white chocolate chips", #"^candies, white chocolate$|white (chocolate |baking )?.*(chips|morsels)"#, chipExclusion, chocolate: true),
        .init(.baking, "butter", #"^butter, (salted|without salt|stick|unsalted|light, stick)|^(salted |unsalted |sweet cream |organic )*butter$"#, nil),
        .init(.baking, "unsalted butter", #"^butter, stick, unsalted|^butter, without salt|^(organic )?(sweet cream )?unsalted (sweet cream )?butter$"#, nil),
        .init(.baking, "eggs", #"^eggs?, grade a, large, egg whole|^eggs?, whole, raw|^(large |grade a |fresh |brown |white |organic |cage free |free range )*(large )?eggs?$"#, nil),
        .init(.baking, "egg", #"^eggs?, grade a, large, egg whole|^eggs?, whole, raw|^(large |grade a |fresh |brown |white |organic |cage free |free range )*(large )?eggs?$"#, nil),
        .init(.baking, "egg whites", #"^eggs?, white, raw|^(100% )?(liquid )?egg whites?$"#, nil),
        .init(.baking, "yeast", #"leavening agents, yeast, baker|^(active dry |instant |rapid rise |fast[- ]rising |bread machine |highly active )*yeast$"#, #"extract|nutritional|roll"#),
        .init(.baking, "cornstarch", #"^cornstarch$|^corn starch$"#, nil),
        .init(.baking, "honey", #"^honey$|^(pure |raw |clover |natural |organic |wildflower |local |100% )+honey$"#, nil),
        .init(.baking, "maple syrup", #"^syrups?, maple|^(100% )?(pure |organic )*maple syrup$"#, #"flavored|pancake"#),
        .init(.baking, "molasses", #"^molasses$|^(unsulphured |blackstrap )*molasses$"#, nil),
        .init(.baking, "oats", #"^oats\b|cereals, oats, regular and quick.*(dry|unenriched)|^(old fashioned |rolled |quick |quick[- ]cooking |whole grain |organic )*(rolled )?oats$"#, #"cooked|prepared|flavored|bar|cereal, ready"#),
        .init(.baking, "rolled oats", #"^oats, whole grain, rolled|cereals, oats, regular and quick.*(dry|unenriched)|^(old fashioned |organic |whole grain )*rolled oats$"#, #"cooked|prepared"#),
        .init(.baking, "walnuts", #"^nuts, walnuts|^(chopped |english |raw |shelled |california )*walnuts?( halves| pieces| halves (and|&) pieces)?$"#, nil),
        .init(.baking, "pecans", #"^nuts, pecans|^(raw |chopped )*pecans?( halves| pieces| halves (and|&) pieces)?$"#, nil),
        .init(.baking, "almonds", #"^nuts, almonds$|^nuts, almonds, (blanched|dry roasted)|^(raw |whole |natural |sliced |slivered )*almonds$"#, nil),
        .init(.baking, "raisins", #"^raisins, seeded|^raisins, (seedless|dark|golden)|^(seedless |golden |california |thompson )*raisins$"#, nil),
        .init(.baking, "shredded coconut", #"coconut meat, dried|^(sweetened |unsweetened )?(shredded|flaked) coconut$|coconut, (shredded|flaked)"#, nil),
        .init(.baking, "sprinkles", #"^(rainbow |chocolate |candy |jimmies )*sprinkles$|candies, sprinkles"#, nil),
        .init(.baking, "cream cheese", #"^cream cheese, (full fat|regular|original|plain)|^cheese, cream$|^(original |regular )?cream cheese$|^cream cheese, (regular|original|plain)"#, #"frosting|spread, (?!original)"#),
        .init(.baking, "heavy cream", #"^cream, heavy$|^cream, fluid, heavy|^(ultra[- ]pasteurized )?heavy (whipping )?cream$"#, nil),
        .init(.baking, "sour cream", #"^sour cream, (regular|full fat|light|reduced fat|fat free)$|^cream, sour|^(regular |original )?sour cream$"#, #"dip|onion"#),
        .init(.baking, "buttermilk", #"^buttermilk, (low fat|whole|fat free)|^milk, buttermilk|^(lowfat |cultured |low fat )*buttermilk$"#, nil),
        .init(.baking, "milk", #"^milk, (whole|reduced fat|lowfat|nonfat|fluid)"#, nil),
        .init(.baking, "whole milk", #"^milk, whole|^(vitamin d )?whole milk$"#, nil),
        .init(.baking, "almond milk", #"almond ?milk"#, #"chocolate|creamer|yogurt|ice|coffee"#),
        .init(.baking, "oat milk", #"oat ?milk"#, #"chocolate|creamer|yogurt|ice|coffee"#),
        .init(.baking, "sweetened condensed milk", #"^milk, canned, condensed, sweetened|^sweetened condensed (whole )?milk$"#, nil),
        .init(.baking, "graham crackers", #"graham crackers?, plain|^(honey |original |cinnamon )?graham crackers?$"#, #"crust|chocolate|pie"#),
        .init(.baking, "marshmallows", #"^candies, marshmallows|^(mini |jumbo |large |miniature )*marshmallows$"#, nil),
        .init(.baking, "peanut butter", #"^peanut butter, (smooth|chunk|chunky|creamy)|^(creamy |crunchy |natural |smooth |chunky )*peanut butter$"#, composite + #"|cup|chip"#),
        .init(.baking, "almond flour", #"^flour, almond|almond flour|almond meal"#, #"mix|cracker|tortilla"#),
        .init(.baking, "coconut oil", #"^oil, coconut|^(organic |virgin |extra virgin |refined |unrefined )*coconut oil$"#, #"spray"#),
        .init(.baking, "vegetable oil", #"^oil, vegetable|^(pure )?vegetable oil$|^oil, soybean, salad or cooking"#, #"spray|spread"#),
        .init(.baking, "canola oil", #"^oil, canola$|^(pure )?canola oil$"#, #"spray"#),
        .init(.baking, "olive oil", #"^oil, olive|^(pure |light |extra virgin |classic )*olive oil$"#, #"spray"#),
        .init(.baking, "extra virgin olive oil", #"extra virgin olive oil$|^oil, olive, extra virgin"#, #"spray"#),
        .init(.produce, "banana", #"^bananas?(, raw|, ripe|, overripe|$)"#, nil),
        .init(.produce, "bananas", #"^bananas?(, raw|, ripe|, overripe|$)"#, nil),
        .init(.produce, "apple", #"^apples?, (raw|[a-z ]+, (with|without) skin, raw|[a-z ]+, raw)|^apples?$"#, #"juice|sauce|dried|canned|frozen"#),
        .init(.produce, "apples", #"^apples?, (raw|[a-z ]+, (with|without) skin, raw|[a-z ]+, raw)|^apples?$"#, #"juice|sauce|dried|canned|frozen"#),
        .init(.produce, "lemon", #"^lemons?, raw|^lemons?$"#, nil),
        .init(.produce, "lemon juice", #"^lemon juice(, raw|, from concentrate|$)|^(100% )?lemon juice$"#, nil),
        .init(.produce, "lime", #"^limes?, raw|^limes?$"#, nil),
        .init(.produce, "orange", #"^oranges?, raw|^oranges?$"#, nil),
        .init(.produce, "strawberries", #"^strawberries, (raw|frozen, unsweetened)|^strawberries$"#, nil),
        .init(.produce, "blueberries", #"^blueberries, (raw|frozen, unsweetened)|^blueberries$"#, nil),
        .init(.produce, "raspberries", #"^raspberries, (raw|frozen, (red, )?unsweetened)|^raspberries$"#, nil),
        .init(.produce, "avocado", #"^avocados?, hass, peeled, raw|^avocados?, raw|^avocados?$"#, nil),
        .init(.produce, "tomato", #"^tomato, roma|^tomatoes, (grape|roma|plum|cherry), raw|^tomatoes, red, ripe, raw|^tomatoe?s?$|^tomatoes, (orange|yellow), raw"#, nil),
        .init(.produce, "tomatoes", #"^tomato, roma|^tomatoes, (grape|roma|plum|cherry), raw|^tomatoes, red, ripe, raw|^tomatoe?s?$|^tomatoes, (orange|yellow), raw"#, nil),
        .init(.produce, "cherry tomatoes", #"cherry tomato(es)?$|^tomatoes, cherry"#, #"sauce|salsa|salad"#),
        .init(.produce, "onion", #"^onions?, raw|^onions?$|^onions, (yellow|white|red|sweet), raw"#, nil),
        .init(.produce, "red onion", #"^red onions?$|^onions?, red, raw"#, nil),
        .init(.produce, "yellow onion", #"^yellow onions?$|^onions?, yellow, raw"#, nil),
        .init(.produce, "garlic", #"^garlic, raw|^garlic$|^(fresh |peeled )*garlic( cloves)?$"#, nil),
        .init(.produce, "garlic clove", #"^([\w ]+, )?garlic cloves$|^garlic, raw|^(fresh |peeled )*garlic cloves?$"#, nil),
        .init(.produce, "ginger", #"^ginger root, raw|^spices, ginger, ground|^(fresh )?ginger( root)?$|^(ground )?ginger$"#, nil),
        .init(.produce, "carrot", #"^carrots?, (raw|baby, raw)|^carrots?$"#, #", salad"#),
        .init(.produce, "carrots", #"^carrots?, (raw|baby, raw)|^carrots?$"#, #", salad"#),
        .init(.produce, "celery", #"^celery, raw|^celery$"#, nil),
        .init(.produce, "potato", #"^potato(es)?, (flesh and skin, raw|russet, flesh and skin, raw|white, flesh and skin, raw|red, flesh and skin, raw|raw)|^potato(es)?$"#, #"sweet"#),
        .init(.produce, "sweet potato", #"^sweet ?potato(es)?, raw|^sweet ?potato(es)?$"#, nil),
        .init(.produce, "spinach", #"^spinach, (baby|mature)$|^spinach, raw|^(baby |fresh )?spinach$"#, nil),
        .init(.produce, "kale", #"^kale, raw|^kale$"#, nil),
        .init(.produce, "lettuce", #"^lettuce, .*raw|^lettuce$"#, nil),
        .init(.produce, "cucumber", #"^cucumbers?, peeled, raw|^cucumbers?, (with peel, )?raw|^cucumbers?$"#, nil),
        .init(.produce, "bell pepper", #"^peppers, bell, (red|green|yellow|orange), raw|^peppers, sweet, (red|green|yellow|orange), raw|^(red |green |yellow |orange )?bell peppers?$"#, nil),
        .init(.produce, "red bell pepper", #"^peppers, bell, red, raw|^peppers, sweet, red, raw|^red bell peppers?$"#, nil),
        .init(.produce, "jalapeno", #"^peppers, jalapeno, raw|^jalapeno( peppers?)?$"#, nil),
        .init(.produce, "broccoli", #"^broccoli, raw|^broccoli( florets)?$|^broccoli, frozen"#, nil),
        .init(.produce, "cauliflower", #"^cauliflower, raw|^cauliflower( florets)?$|^cauliflower, frozen"#, nil),
        .init(.produce, "zucchini", #"^squash, zucchini, baby, raw|squash, summer, zucchini, includes skin, raw|^zucchini( squash)?$"#, nil),
        .init(.produce, "mushrooms", #"^mushrooms, (white|brown|portabella|shiitake|crimini|oyster|enoki|maitake)[^,]*, raw|^mushrooms, white|^(white |sliced |baby bella )?mushrooms$"#, nil),
        .init(.produce, "corn", #"^corn, sweet, (yellow|white), (raw|frozen|canned)|^(sweet |whole kernel |yellow )*corn$"#, nil),
        .init(.produce, "peas", #"^peas, green, (raw|frozen)|^(sweet |green )?peas$"#, nil),
        .init(.produce, "green beans", #"^beans, snap, green, (raw|frozen|canned)|^(cut |french style )?green beans$"#, nil),
        .init(.produce, "cilantro", #"coriander \(cilantro\) leaves, raw|^(fresh )?cilantro$"#, nil),
        .init(.produce, "parsley", #"^parsley, fresh|^spices, parsley, dried|^(fresh |italian |flat leaf )?parsley$"#, nil),
        .init(.produce, "basil", #"^basil, fresh|^spices, basil, dried|^(fresh |sweet )?basil$"#, nil),
        .init(.produce, "green onions", #"^green onion, \(scallion\)|^onions, young green|onions, spring or scallions.*raw|^green onions?$|^scallions?$"#, nil),
        .init(.produce, "scallions", #"^green onion, \(scallion\)|onions, spring or scallions.*raw|^green onions?$|^scallions?$"#, nil),
        .init(.pantry, "chicken breast", #"^chicken breast, (roasted|raw)$|^chicken, broilers? or fryers?, breast, (meat only|skinless)|^chicken breast, (raw|boneless|skinless)|^(boneless,? skinless |organic )*chicken breasts?( fillets?)?$|^chicken, breast, boneless, skinless"#, #"breaded|fried|nugget|sandwich|strips|tenders|salad"#),
        .init(.pantry, "chicken thighs", #"^chicken, thighs?, boneless, skinless, raw|^chicken, broilers? or fryers?, (dark meat, )?thigh, meat only|^(boneless,? skinless |bone-in )*chicken thighs?$"#, #"breaded|fried"#),
        .init(.pantry, "ground beef", #"^beef, grass-fed, ground, raw|^beef, ground, \d+% lean|^(\d+% lean )?ground beef$"#, nil),
        .init(.pantry, "ground turkey", #"^turkey, ground|^ground turkey$|^(\d+% lean )?ground turkey$"#, nil),
        .init(.pantry, "bacon", #"^bacon, (pre-sliced|sliced|thick|center)|^pork, cured, bacon, (unprepared|cooked)|^(thick cut |hickory smoked |applewood smoked |center cut |original )*bacon$"#, #"bits|turkey"#),
        .init(.pantry, "salmon", #"^fish, salmon, (atlantic|coho|chinook|sockeye|pink|chum)[^,]*(, (wild|farmed))?, (raw|cooked)|^(atlantic |wild |sockeye )?salmon( fillets?)?$"#, nil),
        .init(.pantry, "shrimp", #"^crustaceans, shrimp|^(raw |cooked |peeled )*shrimp$"#, #"breaded|fried"#),
        .init(.pantry, "tofu", #"^tofu, (hard|raw|firm|soft|extra firm|silken)|^(firm |extra firm |silken |organic )*tofu$"#, #"fried"#),
        .init(.pantry, "black beans", #"^beans, dry, black|^beans, black, mature seeds|^(organic )?black beans$"#, nil),
        .init(.pantry, "chickpeas", #"^chickpeas,? \(garbanzo|^(organic )?(chickpeas|garbanzo beans)$"#, nil),
        .init(.pantry, "lentils", #"^lentils, (dry|raw|mature seeds|pink or red, raw)|^(green |brown |red )?lentils$"#, nil),
        .init(.pantry, "rice", #"^rice, (white|brown)"#, nil),
        .init(.pantry, "white rice", #"^rice, white"#, nil),
        .init(.pantry, "brown rice", #"^rice, brown"#, nil),
        .init(.pantry, "pasta", #"^pasta, (dry|cooked|plain|fresh-refrigerated, plain)|^pasta$"#, nil),
        .init(.pantry, "spaghetti", #"^spaghetti, (dry|cooked|whole-wheat)|^pasta, .*spaghetti|^spaghetti$|^spaghetti pasta$"#, #"sauce|meatball|squash"#),
        .init(.pantry, "quinoa", #"^quinoa, (uncooked|cooked)|^(organic |white )?quinoa$"#, nil),
        .init(.pantry, "bread", #"^bread, \w+( \w+)?$|^bread, (white|whole-wheat|wheat|multi-grain|french|italian|rye|sourdough|reduced-calorie, white)"#, #"crumbs, dry|pudding|stuffing|sticks"#),
        .init(.pantry, "tortillas", #"^tortillas, ready-to-bake or -fry, (flour|corn)|^(flour |corn )tortillas$"#, nil),
        .init(.pantry, "cheddar cheese", #"^cheese, cheddar|^(sharp |mild |medium |extra sharp )?cheddar cheese$"#, #"sauce|soup|crackers|spread"#),
        .init(.pantry, "mozzarella", #"^cheese, mozzarella|^(fresh |whole milk |part skim )?mozzarella( cheese)?$"#, #"stick"#),
        .init(.pantry, "parmesan", #"^cheese, parmesan|^(grated |shredded )?parmesan( cheese)?$"#, #"crisps|dressing"#),
        .init(.pantry, "feta", #"^cheese, feta|^(crumbled )?feta( cheese)?$"#, nil),
        .init(.pantry, "greek yogurt", #"^yogurt, greek, plain|^(plain |nonfat plain |whole milk plain )?greek yogurt(, plain)?$"#, nil),
        .init(.pantry, "yogurt", #"^yogurt, (plain|greek, plain)|^(plain )?yogurt$"#, nil),
        .init(.pantry, "soy sauce", #"^soy sauce( made from| \(|$)|^(low sodium |less sodium |naturally brewed )?soy sauce$"#, nil),
        .init(.pantry, "salt", #"^salt, table|^(sea |kosher |iodized |table |fine )*salt$"#, nil),
        .init(.pantry, "black pepper", #"^spices, pepper, black$|^(ground |pure ground |coarse ground )?black pepper$"#, nil),
        .init(.pantry, "cinnamon", #"^spices, cinnamon, ground|^(ground )?cinnamon$"#, nil),
        .init(.pantry, "cumin", #"^spices, cumin seed|^(ground )?cumin$"#, nil),
        .init(.pantry, "paprika", #"^spices, paprika|^(smoked |sweet )?paprika$"#, nil),
        .init(.pantry, "chili powder", #"^spices, chili powder|^chili powder$"#, nil),
        .init(.pantry, "oregano", #"^spices, oregano, dried|^(dried )?oregano( leaves)?$"#, nil),
        .init(.pantry, "garlic powder", #"^spices, garlic powder|^garlic powder$"#, nil),
        .init(.pantry, "onion powder", #"^spices, onion powder|^onion powder$"#, nil),
        .init(.pantry, "red pepper flakes", #"red pepper flakes$|^crushed red pepper$|^spices, pepper, red or cayenne"#, nil),
        .init(.pantry, "vinegar", #"^vinegar, (distilled|cider|red wine|balsamic)|^(distilled )?(white )?vinegar$"#, nil),
        .init(.pantry, "apple cider vinegar", #"^vinegar, cider|^(organic |raw |unfiltered )*apple cider vinegar$"#, nil),
        .init(.pantry, "balsamic vinegar", #"^vinegar, balsamic|^balsamic vinegar( of modena)?$"#, nil),
        .init(.pantry, "dijon mustard", #"dijon mustard$|^mustard, .*dijon"#, nil),
        .init(.pantry, "ketchup", #"^ketchup, restaurant|^catsup$|^(tomato )?ketchup$"#, nil),
        .init(.pantry, "mayonnaise", #"^salad dressing, mayonnaise, regular|^(real )?mayonnaise$"#, nil),
        .init(.pantry, "chicken broth", #"^soup, chicken broth(, ready-to-serve|, low sodium, canned| or bouillon)|^(low sodium |fat free |organic )*chicken broth$"#, #"dry|cube|powder|granules"#),
        .init(.pantry, "tomato paste", #"^tomato, paste|^tomato products, canned, paste|^tomato paste$"#, nil),
        .init(.pantry, "canned tomatoes", #"^tomatoes, (canned, red, ripe, diced|crushed, canned|whole, canned)|^tomatoes, red, ripe, canned|^(canned )?(diced|whole peeled|crushed) tomatoes$"#, nil),
        .init(.pantry, "coconut milk", #"^nuts, coconut milk|^(canned )?(unsweetened )?coconut milk$"#, #"beverage|creamer"#),
        // Widened by F6: "Water, bottled, generic" and "Water, bottled, non-carbonated, NAYA" are SR
        // Legacy's own spellings of plain water, absent from the catalog when the judge was written.
        .init(.pantry, "water", #"^beverages, water, (tap|bottled, (generic|non-carbonated))|^water, bottled, (generic|non-carbonated)|^(purified |spring |drinking |pure )?water$"#, nil),
        .init(.prefix, "choc", target: "chocolate", #"^chocolate, dark, \d|^candies, (semisweet|milk|dark|sweet|white) chocolate$|^baking chocolate, (unsweetened|mexican)|^candies, chocolate, dark|^candies, semisweet chocolate$|^(organic |premium |real |pure )*(mini |big |mega )*(semi[- ]*sweet |bittersweet |dark |milk |white )?(chocolate )?(flavored )?(baking )?(chips|morsels)\b"#, chipExclusion, chocolate: true),
        .init(.prefix, "chocolate", #"^chocolate, dark, \d|^candies, (semisweet|milk|dark|sweet|white) chocolate$|^baking chocolate, (unsweetened|mexican)|^candies, chocolate, dark|^candies, semisweet chocolate$|^(organic |premium |real |pure )*(mini |big |mega )*(semi[- ]*sweet |bittersweet |dark |milk |white )?(chocolate )?(flavored )?(baking )?(chips|morsels)\b"#, chipExclusion, chocolate: true),
        .init(.prefix, "chocolate c", target: "chocolate chips", #"^candies, semisweet chocolate$|^(organic |premium |real |pure )*(mini |big |mega )*(semi[- ]*sweet |bittersweet |dark |milk |white )?(chocolate )?(flavored )?(baking )?(chips|morsels)\b"#, chipExclusion, chocolate: true),
        .init(.prefix, "chocolate ch", target: "chocolate chips", #"^candies, semisweet chocolate$|^(organic |premium |real |pure )*(mini |big |mega )*(semi[- ]*sweet |bittersweet |dark |milk |white )?(chocolate )?(flavored )?(baking )?(chips|morsels)\b"#, chipExclusion, chocolate: true),
        .init(.prefix, "chocolate chi", target: "chocolate chips", #"^candies, semisweet chocolate$|^(organic |premium |real |pure )*(mini |big |mega )*(semi[- ]*sweet |bittersweet |dark |milk |white )?(chocolate )?(flavored )?(baking )?(chips|morsels)\b"#, chipExclusion, chocolate: true),
        .init(.prefix, "chocolate chip", target: "chocolate chips", #"^candies, semisweet chocolate$|^(organic |premium |real |pure )*(mini |big |mega )*(semi[- ]*sweet |bittersweet |dark |milk |white )?(chocolate )?(flavored )?(baking )?(chips|morsels)\b"#, chipExclusion, chocolate: true),
        .init(.prefix, "ban", target: "banana", #"^bananas?(, raw|, ripe|, overripe|$)"#, nil),
        .init(.prefix, "bana", target: "banana", #"^bananas?(, raw|, ripe|, overripe|$)"#, nil),
        .init(.prefix, "banan", target: "banana", #"^bananas?(, raw|, ripe|, overripe|$)"#, nil),
        .init(.prefix, "brown s", target: "brown sugar", #"^sugars?, brown|^(pure cane )?(light |dark |golden )?brown sugar$"#, nil),
        .init(.prefix, "baking s", target: "baking soda", #"leavening agents, baking soda|^(pure )?baking soda$"#, nil),
        .init(.prefix, "chicken b", target: "chicken breast", #"^chicken breast, (roasted|raw)$|^chicken, broilers? or fryers?, breast, (meat only|skinless)|^chicken breast, (raw|boneless|skinless)|^(boneless,? skinless |organic )*chicken breasts?( fillets?)?$|^chicken, breast, boneless, skinless"#, #"breaded|fried|nugget|sandwich|strips|tenders|salad"#),
        .init(.prefix, "peanut b", target: "peanut butter", #"^peanut butter, (smooth|chunk|chunky|creamy)|^(creamy |crunchy |natural |smooth |chunky )*peanut butter$"#, composite + #"|cup|chip"#),
    ]

    // MARK: - The pins (measured; re-take with the dump)

    static let pins: [IngredientCorpusPin] = [
        .init("all-purpose flour", 1, 1, plain: 6),
        .init("flour", nil, nil, plain: 0),
        .init("bread flour", 1, 1, plain: 3),
        .init("whole wheat flour", 1, 1, plain: 4),
        .init("sugar", 4, 4, plain: 1),
        .init("granulated sugar", 1, 1, plain: 3),
        .init("brown sugar", 1, 1, plain: 4),
        .init("powdered sugar", 1, 1, plain: 3),
        .init("baking soda", 1, 1, plain: 1),
        .init("baking powder", 1, 1, plain: 4),
        .init("vanilla extract", 1, 1, plain: 4),
        .init("cocoa powder", 1, 1, plain: 4),
        .init("chocolate chips", 1, 1, plain: 5),
        .init("chocolate chip", 1, 1, plain: 4),
        .init("semisweet chocolate chips", 1, 1, plain: 4),
        .init("semi sweet chocolate chips", 1, 1, plain: 6),
        .init("dark chocolate chips", 1, 1, plain: 3),
        .init("milk chocolate chips", 1, 1, plain: 2),
        .init("white chocolate chips", 1, nil, plain: 2),
        .init("butter", 1, 1, plain: 5),
        .init("unsalted butter", 1, 1, plain: 2),
        .init("eggs", 1, 1, plain: 1, each: true),
        .init("egg", nil, nil, plain: 0, each: false),
        .init("egg whites", 1, 1, plain: 4),
        .init("yeast", 1, 1, plain: 3),
        .init("cornstarch", 1, 1, plain: 2),
        .init("honey", 1, 1, plain: 3),
        .init("maple syrup", 1, 1, plain: 3),
        .init("molasses", 1, 1, plain: 1),
        .init("oats", 1, 1, plain: 4),
        .init("rolled oats", 1, 1, plain: 3),
        .init("walnuts", 1, 1, plain: 6),
        .init("pecans", 1, 1, plain: 6),
        .init("almonds", 1, 1, plain: 3),
        .init("raisins", 1, 1, plain: 4),
        .init("shredded coconut", 1, 1, plain: 1),
        .init("sprinkles", 1, 1, plain: 2),
        .init("cream cheese", 1, 1, plain: 2),
        .init("heavy cream", 1, 1, plain: 3),
        .init("sour cream", 1, 1, plain: 3),
        .init("buttermilk", 1, 1, plain: 3),
        .init("milk", nil, nil, plain: 0),
        .init("whole milk", 1, 1, plain: 2),
        .init("almond milk", 1, 1, plain: 4),
        .init("oat milk", 1, 1, plain: 3),
        .init("sweetened condensed milk", 1, 1, plain: 2),
        .init("graham crackers", 1, 1, plain: 1, each: false),
        .init("marshmallows", 1, 1, plain: 4, each: false),
        .init("peanut butter", 1, 1, plain: 4),
        .init("almond flour", 1, 1, plain: 6),
        .init("coconut oil", 1, 1, plain: 2),
        .init("vegetable oil", 1, 1, plain: 4),
        .init("canola oil", 1, 1, plain: 2),
        .init("olive oil", 1, 1, plain: 2),
        .init("extra virgin olive oil", 1, 1, plain: 1),
        .init("banana", 1, 1, plain: 4, each: true),
        .init("bananas", 1, 1, plain: 3, each: true),
        .init("apple", 4, 4, plain: 3, each: false),
        .init("apples", 4, 4, plain: 3, each: false),
        .init("lemon", 1, 1, plain: 1, each: true),
        .init("lemon juice", 1, 1, plain: 1),
        .init("lime", 1, 1, plain: 1, each: true),
        .init("orange", 1, 1, plain: 6, each: true),
        .init("strawberries", 1, 1, plain: 2),
        .init("blueberries", 1, 1, plain: 1),
        .init("raspberries", 1, 1, plain: 2),
        .init("avocado", 1, 1, plain: 5, each: false),
        .init("tomato", 1, 1, plain: 4, each: false),
        .init("tomatoes", 2, 2, plain: 3, each: true),
        .init("cherry tomatoes", 1, 1, plain: 2),
        .init("onion", 1, 1, plain: 4, each: true),
        .init("red onion", 1, 1, plain: 2, each: true),
        .init("yellow onion", 1, 1, plain: 2, each: true),
        .init("garlic", 1, 1, plain: 3),
        .init("garlic clove", 1, 1, plain: 2, each: true),
        .init("ginger", 1, 1, plain: 2),
        .init("carrot", 1, 1, plain: 2, each: true),
        .init("carrots", 1, 1, plain: 2, each: true),
        .init("celery", 1, 1, plain: 2),
        .init("potato", nil, nil, plain: 0, each: false),
        .init("sweet potato", nil, nil, plain: 0, each: false),
        .init("spinach", 1, 1, plain: 3),
        .init("kale", 1, 1, plain: 1),
        .init("lettuce", 1, 1, plain: 6),
        .init("cucumber", 1, 1, plain: 2, each: true),
        .init("bell pepper", 1, 1, plain: 4, each: false),
        .init("red bell pepper", 1, 1, plain: 1, each: false),
        .init("jalapeno", 1, 1, plain: 2, each: true),
        .init("broccoli", 1, 1, plain: 1),
        .init("cauliflower", 1, 1, plain: 2),
        .init("zucchini", 1, 1, plain: 2, each: true),
        .init("mushrooms", 1, 1, plain: 4),
        .init("corn", 1, 1, plain: 5),
        .init("peas", 1, 1, plain: 1),
        .init("green beans", 1, 1, plain: 4),
        .init("cilantro", 1, 1, plain: 1),
        .init("parsley", 1, 1, plain: 2),
        .init("basil", 1, 1, plain: 2),
        .init("green onions", 1, 1, plain: 2),
        .init("scallions", 1, 1, plain: 1),
        .init("chicken breast", 2, 2, plain: 2, each: false),
        .init("chicken thighs", 2, 2, plain: 3, each: false),
        .init("ground beef", 1, 1, plain: 6),
        .init("ground turkey", 1, 1, plain: 6),
        .init("bacon", 5, 5, plain: 1),
        .init("salmon", 4, 4, plain: 3),
        .init("shrimp", 1, 1, plain: 5),
        .init("tofu", 2, 2, plain: 3),
        .init("black beans", 1, 1, plain: 3),
        .init("chickpeas", 1, 1, plain: 6),
        .init("lentils", 1, 1, plain: 4),
        .init("rice", 6, 6, plain: 1),
        .init("white rice", 1, 1, plain: 6),
        .init("brown rice", 1, 1, plain: 6),
        .init("pasta", 1, 1, plain: 3),
        .init("spaghetti", nil, nil, plain: 0),
        .init("quinoa", 1, 1, plain: 3),
        .init("bread", 1, 1, plain: 6),
        .init("tortillas", 1, 1, plain: 5, each: true),
        .init("cheddar cheese", 1, 1, plain: 3),
        .init("mozzarella", 1, 1, plain: 6),
        .init("parmesan", 1, 1, plain: 6),
        .init("feta", 1, 1, plain: 3),
        .init("greek yogurt", 1, 1, plain: 2),
        .init("yogurt", 1, 1, plain: 3),
        .init("soy sauce", 1, 1, plain: 4),
        .init("salt", 1, 1, plain: 1),
        .init("black pepper", 1, 1, plain: 2),
        .init("cinnamon", 1, 1, plain: 2),
        .init("cumin", 1, 1, plain: 2),
        .init("paprika", 1, 1, plain: 2),
        .init("chili powder", 1, 1, plain: 2),
        .init("oregano", 1, 1, plain: 3),
        .init("garlic powder", 1, 1, plain: 2),
        .init("onion powder", 1, 1, plain: 2),
        .init("red pepper flakes", 1, 1, plain: 1),
        .init("vinegar", 1, 1, plain: 5),
        .init("apple cider vinegar", 1, 1, plain: 1),
        .init("balsamic vinegar", 1, 1, plain: 2),
        .init("dijon mustard", 1, 1, plain: 5),
        .init("ketchup", 1, 1, plain: 3),
        .init("mayonnaise", 5, 5, plain: 1),
        .init("chicken broth", 1, 1, plain: 2),
        .init("tomato paste", 1, 1, plain: 2),
        .init("canned tomatoes", 1, 1, plain: 6),
        .init("coconut milk", 1, 1, plain: 4),
        .init("water", 1, 1, plain: 4),
        .init("choc", 2, 2, plain: 4),
        .init("chocolate", 1, 1, plain: 5),
        .init("chocolate c", 1, 1, plain: 1),
        .init("chocolate ch", 1, 1, plain: 1),
        .init("chocolate chi", 1, 1, plain: 1),
        .init("chocolate chip", 1, 1, plain: 4),
        .init("ban", 1, 1, plain: 3),
        .init("bana", 1, 1, plain: 3),
        .init("banan", 1, 1, plain: 3),
        .init("brown s", nil, nil, plain: 0),
        .init("baking s", 1, 1, plain: 1),
        .init("chicken b", nil, nil, plain: 0),
        .init("peanut b", 1, 1, plain: 4),
    ]

    // MARK: - Plausibility

    /// Whether a row's nutrition is physically possible for its serving — the research's
    /// `revise/plaus.py` rule. Only gram and milliliter servings are judged (a milliliter read as a
    /// gram, and the raw FDC `GRM`/`MLT` codes included); any other serving passes, because it
    /// carries no weight to judge against.
    static func isPlausible(_ item: FoodItem) -> Bool {
        let unit = item.servingUnit.trimmingCharacters(in: .whitespaces).lowercased()
        guard ["g", "grm", "ml", "mlt"].contains(unit), item.servingSize > 0 else { return true }
        let macros = item.macros
        let kcalPer100 = Double(4 * macros.protein + 4 * macros.carbs + 9 * macros.fat) * 100 / item.servingSize
        let macroGrams = Double(macros.protein + macros.carbs + macros.fat)
        return kcalPer100 <= 900 && macroGrams <= item.servingSize
    }

    // MARK: - Measurement

    /// Replays one query through the editor's call and reads its pin off the six rows.
    static func measure(_ matcher: IngredientCorpusMatcher, catalog: FoodCatalog) -> IngredientCorpusPin {
        let query = matcher.judge.query
        let visible = catalog.results(for: query, context: .userTyped, ranking: .ingredientIdentity)
        let nameIndex = visible.firstIndex { matcher.accepts($0.name) }
        let plausibleIndex = visible.firstIndex { matcher.accepts($0.name) && isPlausible($0) }
        let plain = visible.filter { matcher.accepts($0.name) }.count
        var each: Bool?
        if countNouns.contains(query) {
            each = plausibleIndex.map { countsOneItem(visible[$0]) } ?? false
        }
        return IngredientCorpusPin(query, nameIndex.map { $0 + 1 }, plausibleIndex.map { $0 + 1 }, plain: plain, each: each)
    }

    /// Whether "1 each" of `item` converts through a portion that is one item — not a branded label
    /// serving kept as the row's count portion (`BundledRowCorrection`'s "1 serving (N g)").
    static func countsOneItem(_ item: FoodItem) -> Bool {
        let line = RecipeIngredient(foodItemId: item.id, quantity: 1, unit: RecipeUnit.each.rawValue)
        guard let conversion = line.servingConversion(using: item) else { return false }
        return conversion.sourcePortion?.description?.hasPrefix(labelServingPrefix) != true
    }

    // MARK: - Tests

    /// THE replay: all 160 queries against their pins, every mismatch named in one message.
    @Test func corpusReplaysToThePinnedRanks() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount >= FoodSearchCorpusTests.shippedRowCount,
                     "the shipped catalog must be loaded — this suite must never pass vacuously")
        let matchers = try Self.judges.map(IngredientCorpusMatcher.init)
        let measured = matchers.map { Self.measure($0, catalog: catalog) }
        Self.writeDumpIfAsked(measured)
        // Positional: "chocolate chip" is both a baking query and a typing prefix, so a query is not
        // a key. `baselineTuplesAreDerivedFromThePins` holds pins and judges to the same order.
        try #require(measured.count == Self.pins.count, "every judged query needs exactly one pin")
        let moved = zip(measured, Self.pins).filter { $0 != $1 }.map { now, was -> String in
            "now \(now.literal.trimmingCharacters(in: .whitespaces)) — pinned \(was.literal.trimmingCharacters(in: .whitespaces))"
        }
        #expect(moved.isEmpty, """
            \(moved.count) ingredient pin(s) moved without a deliberate edit — if a fix meant to move \
            them, update these pins and the baseline tuples in the same commit:
            \(moved.joined(separator: "\n"))
            """)
    }

    /// The tuples are measured facts derived from the pins, and the pins cover the probe's corpus
    /// exactly, in its order — so neither can drift from the other.
    /// The named rows of fix rounds 1 and 2: the canonical USDA rows identity must keep in view, the
    /// compound rows it must lead with, the flavored products it must no longer count as the ingredient,
    /// and the variant-named plain products it must count again.
    @Test func theSixShowTheNamedRows() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount >= FoodSearchCorpusTests.shippedRowCount,
                     "the shipped catalog must be loaded — this suite must never pass vacuously")
        for pin in Self.sixPins {
            let names = catalog.results(for: pin.query, context: .userTyped, ranking: .ingredientIdentity).map(\.name)
            if let leads = pin.leads { #expect(names.first == leads, "\(pin.query) leads with \(names.first ?? "nothing")") }
            for name in pin.shows { #expect(names.contains(name), "\(pin.query) must show \(name): \(names)") }
            for name in pin.hides { #expect(!names.contains(name), "\(pin.query) must not show \(name): \(names)") }
        }
    }

    @Test func baselineTuplesAreDerivedFromThePins() {
        #expect(Self.judges.map(\.query) == IngredientReplayCorpus.all.map(\.query),
                "the judges must cover the replay probe's corpus, in its order")
        #expect(Self.pins.map(\.query) == Self.judges.map(\.query), "every judged query needs exactly one pin")
        #expect(Self.judges.map { $0.category.rawValue.uppercased() }
                == IngredientReplayCorpus.all.map(\.category))
        let plausibleAtOne = Self.pins.filter { $0.plausibleRank == 1 }.count
        let plausibleVisible = Self.pins.filter { $0.plausibleRank != nil }.count
        #expect((plausibleAtOne, plausibleVisible) == Self.measuredBaseline)
        let nameAtOne = Self.pins.filter { $0.nameRank == 1 }.count
        let nameVisible = Self.pins.filter { $0.nameRank != nil }.count
        #expect((nameAtOne, nameVisible) == Self.nameOnlyBaseline)
        #expect(Self.pins.filter { $0.eachConverts == true }.count == Self.eachBaseline)
        #expect(Self.pins.map(\.plainInSix).reduce(0, +) == Self.plainRowsInSixBaseline)
        #expect(Set(Self.pins.filter { $0.eachConverts != nil }.map(\.query)) == Self.countNouns)
    }

    /// The carrot judge rejects the FNDDS coleslaw the research's first pattern accepted, and still
    /// accepts the plain rows.
    @Test func carrotJudgeRejectsTheColeslawRow() throws {
        for query in ["carrot", "carrots"] {
            let judge = try #require(Self.judges.first { $0.query == query })
            let matcher = try IngredientCorpusMatcher(judge)
            #expect(!matcher.accepts("Carrots, raw, salad"))
            #expect(matcher.accepts("Carrots, raw"))
            #expect(matcher.accepts("Carrots, baby, raw"))
        }
    }

    /// The chips guard: a savoury "chips" row never counts as chocolate chips, and the USDA
    /// semisweet row always does.
    @Test func chocolateJudgesRequireChocolate() throws {
        let judge = try #require(Self.judges.first { $0.query == "chocolate chips" })
        let matcher = try IngredientCorpusMatcher(judge)
        #expect(!matcher.accepts("Chips, Salt And Vinegar"))
        #expect(!matcher.accepts("Cookies, chocolate chip, dry mix"))
        #expect(matcher.accepts("Candies, semisweet chocolate"))
        #expect(matcher.accepts("Chocolate Chips, Chocolate"))
    }

    /// The plausibility rule on the report's own examples (§2.6, §4.1a).
    @Test func plausibilityRejectsImpossibleNutrition() {
        func food(_ size: Double, _ unit: String, _ p: Int, _ c: Int, _ f: Int) -> FoodItem {
            FoodItem(name: "Probe", servingSize: size, servingUnit: unit,
                     macros: Macros(protein: p, carbs: c, fat: f), micronutrients: Micronutrients(),
                     category: "Test", source: .usda, tags: [])
        }
        #expect(!Self.isPlausible(food(15, "g", 7, 60, 33)), "Organic Semi-Sweet Chocolate Chips: 3,767 kcal/100 g")
        #expect(!Self.isPlausible(food(15, "g", 0, 67, 27)), "row 64235: 82 g of macros in a 15 g serving")
        #expect(Self.isPlausible(food(15, "g", 0, 10, 4)), "row 106868 is the correct twin")
        #expect(Self.isPlausible(food(15, "GRM", 0, 10, 4)))
        #expect(Self.isPlausible(food(100, "g", 0, 67, 27)), "the same macros on a 100 g basis are real chips")
        #expect(Self.isPlausible(food(1, "sandwich", 30, 40, 20)), "a non-mass serving is not judged")
    }

    // MARK: - Dump

    /// Writes the measured pins, paste-ready, to the file named by `INGREDIENT_CORPUS_DUMP`
    /// (`TEST_RUNNER_INGREDIENT_CORPUS_DUMP` on the xcodebuild line). Inert otherwise.
    private static func writeDumpIfAsked(_ measured: [IngredientCorpusPin]) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["INGREDIENT_CORPUS_DUMP"] ?? env["TEST_RUNNER_INGREDIENT_CORPUS_DUMP"] else { return }
        let atOne = measured.filter { $0.plausibleRank == 1 }.count
        let visible = measured.filter { $0.plausibleRank != nil }.count
        let nameAtOne = measured.filter { $0.nameRank == 1 }.count
        let nameVisible = measured.filter { $0.nameRank != nil }.count
        let each = measured.filter { $0.eachConverts == true }.count
        let plainRows = measured.map(\.plainInSix).reduce(0, +)
        let text = """
            measuredBaseline = (plainAtOne: \(atOne), plainVisible: \(visible))
            nameOnlyBaseline = (plainAtOne: \(nameAtOne), plainVisible: \(nameVisible))
            eachBaseline = \(each)
            plainRowsInSixBaseline = \(plainRows)
            \(measured.map(\.literal).joined(separator: "\n"))

            """
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            print("IngredientSearchCorpusTests: dump write failed (\(error))\n\(text)")
        }
    }
}
