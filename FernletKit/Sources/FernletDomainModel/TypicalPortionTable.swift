// TypicalPortionTable.swift
// FernletDomainModel
//
// Curated USDA typical sizes — Docs/Ingredient-Search-Deep-Research-2026-09-29.md §6.3 Rungs C and D,
// §8 F4b (owner decision 2026-09-30: a badged, editable "USDA typical size, estimate" table is
// acceptable).
//
// The row a person taps is often a thin one. USDA's newer Foundation rows ("Avocado, Hass, peeled,
// raw", "Garlic, raw" FDC 1104647, "Flour, wheat, all-purpose, enriched, bleached", "Butter, stick,
// unsalted") carry one reference amount (RACC) or nothing, so "1 avocado", "3 cloves" or "2 cups" of
// them has no weight in the row's own data — while an SR Legacy row for the same food, shipped in the
// same catalog, states it: a California avocado is 136 g (FDC 171706), a clove 3 g (FDC 169230), a
// cup of all-purpose flour 125 g (FDC 168894). This table carries those SR weights to the thin rows.
//
// The rules, all deliberate:
// - **Every weight is USDA's.** Each ``TypicalPortion`` names the SR Legacy row it is read from (its
//   FDC id) and that row's portion text, verbatim; `TypicalPortionTableTests` finds every one in the
//   shipped catalog and checks the grams. A spoon measure a row does not state is its stated
//   volume's density times the spoon's volume (``volumeOptions(for:)``) — arithmetic on a cited value,
//   never a new value.
// - **Only where the food says nothing.** A typical count is offered only when the food's own data
//   offers no count, a typical volume only when it offers no volume (``RecipePortionPicker``). A food
//   whose own USDA portions answer is never overridden.
// - **Always an estimate.** The recipe editor badges every one "USDA typical size, estimate" and lets
//   the person type their own grams, which it remembers for that food.
// - **Recipes only.** The recipe editor's picker and the web recipe importer read it. Quick log, the
//   meal composer and the meal resolver do not: the converter (`RecipeServingConversion`) never reads
//   this table, so a meal's amount stays grounded in the food's own data.
// - **A row IS the entry's ingredient** when the entry's head noun names it
//   (``FoodIngredientIdentity``, the F5 reading: "Bread, banana" is bread, "Peanut butter" is not
//   butter), its name says every word of the key, and none of the entry's excluded words — a dried,
//   juiced, cooked or otherwise different form weighs something else. The first matching entry wins,
//   so the specific ("roma tomato", "peanut butter", "brown sugar") precede the general.
//
// Every key, excluded word and label is a FROZEN ENGLISH TOKEN (localization wall): keys and exclusions
// are matched against the catalog's English names; a label is saved beside a recipe line's grams as
// its `RecipeHouseholdMeasure` label. `LocalizationBoundaryTests.frozenTypicalPortionTokens` pins them.

import Foundation

/// One curated USDA typical size: what one is, what it weighs, and the SR Legacy row it is read from.
public nonisolated struct TypicalPortion: Sendable, Equatable {
    /// What one is — a frozen English token saved as a recipe line's household label ("medium",
    /// "clove", "cup", "tbsp", "cup, packed").
    public let label: String
    /// USDA's grams for one.
    public let grams: Double
    /// The SR Legacy row (FDC id) the weight is read from.
    public let fdcID: Int
    /// That row's portion text, verbatim — its unit, or its description where the unit is generic.
    public let usdaPortion: String

    public init(_ label: String, _ grams: Double, fdc fdcID: Int, _ usdaPortion: String) {
        self.label = label
        self.grams = grams
        self.fdcID = fdcID
        self.usdaPortion = usdaPortion
    }

    /// Count or volume, read from the label's first word.
    public var dimension: RecipePortionOption.Dimension {
        RecipePortionOption.dimension(ofLabel: label)
    }

    /// The volume unit a volume label states ("cup, packed" is a cup), or nil for a count.
    public var volumeUnit: RecipeUnit? {
        TypicalPortionTable.volumeUnit(ofLabel: label)
    }
}

/// One ingredient of ``TypicalPortionTable``: its key, the words that make a row something else, and its
/// typical sizes — the default count first.
public nonisolated struct TypicalPortionEntry: Sendable, Equatable {
    /// The ingredient, in `FoodItemSearch.normalized` words; its last word is the head noun a row must
    /// be (``FoodIngredientIdentity``). A frozen English matching input.
    public let key: String
    /// Name words that make a row a different form of the ingredient. Frozen English matching inputs.
    public let excluding: Set<String>
    /// The typical sizes: counts first (the first is the default "one"), then volumes.
    public let portions: [TypicalPortion]

    public init(_ key: String, excluding: Set<String> = [], _ portions: [TypicalPortion]) {
        self.key = key
        self.excluding = excluding
        self.portions = portions
    }

    /// The key's words.
    public var words: [String] {
        key.split(separator: " ").map(String.init)
    }

    /// The default count — what "one" of the ingredient is — or nil for a volume-only entry.
    public var defaultCount: TypicalPortion? {
        portions.first { $0.dimension == .count }
    }
}

/// The curated USDA typical-size table and its lookups (ingredient-search round, F4b). See the file
/// header for the rules. Bounded: a fixed table, read once per row.
public nonisolated enum TypicalPortionTable {
    /// Words that make a produce or egg row a processed form: one of it no longer weighs a whole raw
    /// item. Frozen English matching inputs.
    public static let processedWords: Set<String> = [
        "babyfood", "baby", "baked", "battered", "beverage", "boiled", "bread", "breaded", "cake", "candied",
        "canned", "chips", "chopped", "concentrate", "cooked", "dehydrated", "diced", "dried", "drink", "flakes",
        "flour", "fried", "frozen", "grilled", "jam", "jelly", "juice", "leaves", "mashed", "microwaved",
        "nectar", "oil", "paste", "peel", "pickled", "pie", "powder", "puree", "pureed", "roasted", "salad",
        "sauce", "sauteed", "seeds", "sliced", "slices", "smoothie", "soup", "spread", "steamed", "stewed",
        "strips", "stuffed", "sulfured", "syrup"
    ]

    /// Words that make a grain, dairy or pantry row a cooked or prepared form, whose cup weighs something
    /// else. Frozen English matching inputs.
    public static let preparedWords: Set<String> = [
        "boiled", "cooked", "fried", "instant", "mix", "prepared", "steamed"
    ]

    /// The table, specific entries before general ones.
    public static let entries: [TypicalPortionEntry] = countEntries + volumeEntries

    /// Produce, eggs, chicken and butter: what one is.
    static let countEntries: [TypicalPortionEntry] = [
        TypicalPortionEntry("roma tomato", excluding: processedWords, [
            TypicalPortion("Italian tomato", 62, fdc: 170457, "Italian tomato")
        ]),
        TypicalPortionEntry("plum tomato", excluding: processedWords, [
            TypicalPortion("Italian tomato", 62, fdc: 170457, "Italian tomato")
        ]),
        TypicalPortionEntry("cherry tomato", excluding: processedWords, [
            TypicalPortion("cherry tomato", 17, fdc: 170457, "cherry")
        ]),
        TypicalPortionEntry("tomato", excluding: processedWords.union([
            "cherry", "grape", "roma", "plum", "green", "sun", "tomatillo", "tomatillos"
        ]), [
            TypicalPortion("medium", 123, fdc: 170457, "medium whole (2-3/5\" dia)"),
            TypicalPortion("small", 91, fdc: 170457, "small whole (2-2/5\" dia)"),
            TypicalPortion("large", 182, fdc: 170457, "large whole (3\" dia)")
        ]),
        TypicalPortionEntry("sweet potato", excluding: processedWords, [
            TypicalPortion("sweet potato", 130, fdc: 168482, "sweetpotato, 5\" long")
        ]),
        TypicalPortionEntry("potato", excluding: processedWords.union([
            "sweet", "skin", "fries", "french", "hash", "starch", "puffs", "sticks", "tots"
        ]), [
            TypicalPortion("medium", 213, fdc: 170026, "Potato medium (2-1/4\" to 3-1/4\" dia)"),
            TypicalPortion("small", 170, fdc: 170026, "Potato small (1-3/4\" to 2-1/2\" dia)"),
            TypicalPortion("large", 369, fdc: 170026, "Potato large (3\" to 4-1/4\" dia)")
        ]),
        TypicalPortionEntry("banana", excluding: processedWords.union(["plantain", "plantains"]), [
            TypicalPortion("medium", 118, fdc: 173944, "medium (7\" to 7-7/8\" long)"),
            TypicalPortion("small", 101, fdc: 173944, "small (6\" to 6-7/8\" long)"),
            TypicalPortion("large", 136, fdc: 173944, "large (8\" to 8-7/8\" long)")
        ]),
        TypicalPortionEntry("apple", excluding: processedWords.union([
            "crab", "crabapple", "crabapples", "cider", "applesauce", "butter", "rose"
        ]), [
            TypicalPortion("medium", 182, fdc: 171688, "medium (3\" dia)"),
            TypicalPortion("small", 149, fdc: 171688, "small (2-3/4\" dia)"),
            TypicalPortion("large", 223, fdc: 171688, "large (3-1/4\" dia)")
        ]),
        TypicalPortionEntry("egg white", excluding: processedWords.union(["yolk", "yolks", "substitute"]), [
            TypicalPortion("large", 33, fdc: 172183, "large"),
            TypicalPortion("cup", 243, fdc: 172183, "cup")
        ]),
        TypicalPortionEntry("egg", excluding: processedWords.union([
            "white", "whites", "yolk", "yolks", "substitute", "duck", "goose", "quail", "turkey", "roll", "rolls",
            "nog", "eggnog", "noodles", "omelet", "scrambled", "benedict", "sandwich", "drop", "plant", "vegan"
        ]), [
            TypicalPortion("large", 50, fdc: 171287, "large"),
            TypicalPortion("medium", 44, fdc: 171287, "medium"),
            TypicalPortion("extra large", 56, fdc: 171287, "extra large")
        ]),
        TypicalPortionEntry("garlic", excluding: processedWords.union([
            "salt", "pepper", "chives", "wild", "bulbs", "herb", "herbs"
        ]), [
            TypicalPortion("clove", 3, fdc: 169230, "clove"),
            TypicalPortion("tsp", 2.8, fdc: 169230, "tsp"),
            TypicalPortion("cup", 136, fdc: 169230, "cup")
        ]),
        TypicalPortionEntry("onion", excluding: processedWords.union([
            "spring", "scallion", "scallions", "green", "pearl", "rings", "dip", "welsh"
        ]), [
            TypicalPortion("medium", 110, fdc: 170000, "medium (2-1/2\" dia)"),
            TypicalPortion("small", 70, fdc: 170000, "small"),
            TypicalPortion("large", 150, fdc: 170000, "large")
        ]),
        TypicalPortionEntry("lemon", excluding: processedWords.union(["grass", "lemongrass", "zest"]), [
            TypicalPortion("fruit", 58, fdc: 167746, "fruit (2-1/8\" dia)"),
            TypicalPortion("large fruit", 84, fdc: 167746, "fruit (2-3/8\" dia)")
        ]),
        TypicalPortionEntry("lime", excluding: processedWords.union(["kaffir", "key"]), [
            TypicalPortion("fruit", 67, fdc: 168155, "fruit (2\" dia)")
        ]),
        TypicalPortionEntry("orange", excluding: processedWords.union([
            "mandarin", "mandarins", "tangerine", "tangerines", "blood", "bitter"
        ]), [
            TypicalPortion("fruit", 131, fdc: 169097, "fruit (2-5/8\" dia)"),
            TypicalPortion("small", 96, fdc: 169097, "small (2-3/8\" dia)"),
            TypicalPortion("large", 184, fdc: 169097, "large (3-1/16\" dia)")
        ]),
        TypicalPortionEntry("avocado", excluding: processedWords, [
            TypicalPortion("fruit", 136, fdc: 171706, "fruit, without skin and seed")
        ]),
        TypicalPortionEntry("carrot", excluding: processedWords, [
            TypicalPortion("medium", 61, fdc: 170393, "medium"),
            TypicalPortion("small", 50, fdc: 170393, "small (5-1/2\" long)"),
            TypicalPortion("large", 72, fdc: 170393, "large (7-1/4\" to 8-/1/2\" long)")
        ]),
        TypicalPortionEntry("celery", excluding: processedWords.union(["salt", "root", "celeriac"]), [
            TypicalPortion("medium stalk", 40, fdc: 169988, "stalk, medium (7-1/2\" - 8\" long)"),
            TypicalPortion("small stalk", 17, fdc: 169988, "stalk, small (5\" long)"),
            TypicalPortion("large stalk", 64, fdc: 169988, "stalk, large (11\"-12\" long)")
        ]),
        TypicalPortionEntry("bell pepper", excluding: processedWords, [
            TypicalPortion("medium", 119, fdc: 170427, "medium (approx 2-3/4\" long, 2-1/2\" dia)"),
            TypicalPortion("small", 74, fdc: 170427, "small"),
            TypicalPortion("large", 164, fdc: 170427, "large (2-1/4 per lb, approx 3-3/4\" long, 3\" dia)")
        ]),
        TypicalPortionEntry("jalapeno", excluding: processedWords, [
            TypicalPortion("pepper", 14, fdc: 168576, "pepper")
        ]),
        TypicalPortionEntry("cucumber", excluding: processedWords.union(["sea", "pickle", "pickles"]), [
            TypicalPortion("medium", 201, fdc: 169225, "medium"),
            TypicalPortion("small", 158, fdc: 169225, "small (6-3/8\" long)"),
            TypicalPortion("large", 280, fdc: 169225, "large (8-1/4\" long)")
        ]),
        TypicalPortionEntry("zucchini", excluding: processedWords, [
            TypicalPortion("medium", 196, fdc: 169291, "medium"),
            TypicalPortion("small", 118, fdc: 169291, "small"),
            TypicalPortion("large", 323, fdc: 169291, "large")
        ]),
        TypicalPortionEntry("mushroom", excluding: processedWords.union([
            "shiitake", "portabella", "portobello", "portabello", "enoki", "oyster", "maitake", "morel", "morels",
            "chanterelle", "chanterelles", "straw", "wood", "ear", "truffle", "truffles", "reishi"
        ]), [
            TypicalPortion("medium", 18, fdc: 169251, "medium"),
            TypicalPortion("small", 10, fdc: 169251, "small"),
            TypicalPortion("large", 23, fdc: 169251, "large")
        ]),
        TypicalPortionEntry("strawberry", excluding: processedWords, [
            TypicalPortion("medium", 12, fdc: 167762, "medium (1-1/4\" dia)"),
            TypicalPortion("small", 7, fdc: 167762, "small (1\" dia)"),
            TypicalPortion("large", 18, fdc: 167762, "large (1-3/8\" dia)")
        ]),
        TypicalPortionEntry("peach", excluding: processedWords, [
            TypicalPortion("medium", 150, fdc: 169928, "medium (2-2/3\" dia)"),
            TypicalPortion("small", 130, fdc: 169928, "small (2-1/2\" dia)"),
            TypicalPortion("large", 175, fdc: 169928, "large (2-3/4\" dia)")
        ]),
        TypicalPortionEntry("pear", excluding: processedWords.union(["prickly", "asian"]), [
            TypicalPortion("medium", 178, fdc: 169118, "medium"),
            TypicalPortion("small", 148, fdc: 169118, "small"),
            TypicalPortion("large", 230, fdc: 169118, "large")
        ]),
        TypicalPortionEntry("chicken thigh", excluding: processedWords.union(["skin"]), [
            TypicalPortion("thigh", 149, fdc: 173627, "thigh without skin")
        ]),
        TypicalPortionEntry("chicken breast", excluding: processedWords.union([
            "skin", "tenders", "tenderloins", "nuggets", "patty", "patties"
        ]), [
            TypicalPortion("breast half", 118, fdc: 171509, "breast")
        ]),
        TypicalPortionEntry("butter", excluding: [
            "peanut", "almond", "cashew", "apple", "cocoa", "shea", "nut", "seed", "sunflower", "soy", "oil",
            "ghee", "clarified", "whipped", "light", "margarine", "spread", "blend", "cookies", "cookie",
            "cake", "sauce", "beans", "bean", "lettuce", "squash", "milk", "buttermilk", "cream", "herb",
            "popcorn", "crackers", "pecan", "toffee", "rum", "bread", "rolls"
        ], [
            TypicalPortion("stick", 113, fdc: 173410, "stick"),
            TypicalPortion("tbsp", 14.2, fdc: 173410, "tbsp"),
            TypicalPortion("cup", 227, fdc: 173410, "cup")
        ])
    ]

    /// Baking and pantry staples: what a cup or spoon of them weighs.
    static let volumeEntries: [TypicalPortionEntry] = bakingEntries + pantryEntries

    /// Flours, sugars, chips, grains and dairy.
    static let bakingEntries: [TypicalPortionEntry] = [
        TypicalPortionEntry("all purpose flour", excluding: preparedWords.union(["self", "rising", "tortilla"]), [
            TypicalPortion("cup", 125, fdc: 168894, "cup")
        ]),
        TypicalPortionEntry("bread flour", excluding: preparedWords, [
            TypicalPortion("cup", 137, fdc: 168896, "cup")
        ]),
        TypicalPortionEntry("whole wheat flour", excluding: preparedWords.union(["pastry"]), [
            TypicalPortion("cup", 120, fdc: 168893, "cup")
        ]),
        TypicalPortionEntry("brown sugar", excluding: preparedWords.union([
            "cookies", "cereal", "oatmeal", "syrup", "ham", "bacon", "glaze", "sauce", "maple", "cinnamon"
        ]), [
            TypicalPortion("cup, packed", 220, fdc: 168833, "cup packed"),
            TypicalPortion("tsp, packed", 4.6, fdc: 168833, "tsp packed")
        ]),
        TypicalPortionEntry("powdered sugar", excluding: preparedWords.union(["icing", "glaze", "frosting"]), [
            TypicalPortion("cup", 120, fdc: 169656, "cup unsifted"),
            TypicalPortion("tbsp", 8, fdc: 169656, "tbsp unsifted")
        ]),
        TypicalPortionEntry("sugar", excluding: preparedWords.union([
            "brown", "powdered", "confectioners", "maple", "coconut", "substitute", "free", "cookies", "cookie",
            "snap", "snaps", "syrup", "alcohol", "alcohols", "wafers", "cereal", "sprinkles", "candy", "cubes",
            "icing", "glaze", "cinnamon", "vanilla", "frosted", "coated"
        ]), [
            TypicalPortion("cup", 200, fdc: 169655, "cup"),
            TypicalPortion("tsp", 4.2, fdc: 169655, "tsp")
        ]),
        TypicalPortionEntry("white chocolate chips", excluding: preparedWords, [
            TypicalPortion("cup", 170, fdc: 167571, "cup chips")
        ]),
        TypicalPortionEntry("milk chocolate chips", excluding: preparedWords, [
            TypicalPortion("cup", 168, fdc: 167587, "cup chips")
        ]),
        TypicalPortionEntry("chocolate chips", excluding: preparedWords.union([
            "white", "milk", "cookie", "cookies", "dough", "bar", "bars", "granola", "muffin", "muffins",
            "pancake", "pancakes", "waffle", "waffles", "cereal", "ice", "cream", "trail", "brownie", "brownies"
        ]), [
            TypicalPortion("cup", 168, fdc: 167976, "cup chips (6 oz package)")
        ]),
        TypicalPortionEntry("oats", excluding: preparedWords.union([
            "steel", "bran", "flour", "milk", "cereal", "cookie", "cookies", "bar", "bars", "granola", "oatmeal"
        ]), [
            TypicalPortion("cup", 81, fdc: 173904, "cup")
        ]),
        TypicalPortionEntry("brown rice", excluding: preparedWords.union(riceProductWords), [
            TypicalPortion("cup", 185, fdc: 169703, "cup")
        ]),
        TypicalPortionEntry("rice", excluding: preparedWords.union(riceProductWords).union([
            "brown", "wild", "black", "red", "milk", "pudding", "wine", "vinegar", "paper", "krispies", "beans",
            "bean", "sweet", "sticky", "glutinous"
        ]), [
            TypicalPortion("cup", 185, fdc: 168877, "cup")
        ]),
        TypicalPortionEntry("quinoa", excluding: preparedWords.union(["flour", "flakes", "puffed", "pasta"]), [
            TypicalPortion("cup", 170, fdc: 168874, "cup")
        ]),
        TypicalPortionEntry("almond milk", excluding: preparedWords.union(["chocolate", "creamer"]), [
            TypicalPortion("cup", 262, fdc: 174832, "cup")
        ]),
        TypicalPortionEntry("buttermilk", excluding: preparedWords.union(dryDairyWords).union([
            "biscuit", "biscuits", "pancake", "pancakes", "ranch", "dressing"
        ]), [
            TypicalPortion("cup", 245, fdc: 170874, "cup")
        ]),
        TypicalPortionEntry("heavy cream", excluding: preparedWords.union(["whipped", "sour", "cheese", "ice", "sauce", "soup"]), [
            TypicalPortion("cup", 238, fdc: 170859, "cup, fluid (yields 2 cups whipped)"),
            TypicalPortion("tbsp", 15, fdc: 170859, "tbsp")
        ]),
        TypicalPortionEntry("sour cream", excluding: preparedWords.union(["dip", "onion", "chips", "sauce", "dressing", "imitation"]), [
            TypicalPortion("cup", 230, fdc: 171257, "cup"),
            TypicalPortion("tbsp", 12, fdc: 171257, "tbsp")
        ]),
        TypicalPortionEntry("cream cheese", excluding: preparedWords.union(["whipped", "frosting", "icing", "wontons", "rangoon"]), [
            TypicalPortion("tbsp", 14.5, fdc: 173418, "tbsp"),
            TypicalPortion("cup", 232, fdc: 173418, "cup")
        ]),
        TypicalPortionEntry("milk", excluding: preparedWords.union(dryDairyWords).union([
            "chocolate", "buttermilk", "almond", "oat", "soy", "rice", "coconut", "cashew", "hemp", "goat",
            "human", "shake", "shakes", "cheese", "bread", "cereal", "substitute", "imitation", "creamer",
            "eggnog", "malted", "pudding", "sauce", "gravy", "tea", "coffee", "latte", "toast"
        ]), [
            TypicalPortion("cup", 244, fdc: 171265, "cup"),
            TypicalPortion("tbsp", 15, fdc: 171265, "tbsp")
        ]),
        TypicalPortionEntry("yogurt", excluding: preparedWords.union([
            "greek", "frozen", "covered", "coated", "raisins", "pretzels", "drink", "dressing", "dip",
            "smoothie", "bar", "bars", "parfait", "tube", "tubes"
        ]), [
            TypicalPortion("cup", 245, fdc: 171284, "cup (8 fl oz)")
        ]),
        TypicalPortionEntry("shredded coconut", excluding: preparedWords, [
            TypicalPortion("cup", 93, fdc: 168586, "cup, shredded")
        ]),
        TypicalPortionEntry("cocoa powder", excluding: preparedWords.union(["drink", "beverage", "hot"]), [
            TypicalPortion("tbsp", 5.4, fdc: 169593, "tbsp"),
            TypicalPortion("cup", 86, fdc: 169593, "cup")
        ]),
        TypicalPortionEntry("cornstarch", excluding: preparedWords, [
            TypicalPortion("cup", 128, fdc: 169698, "cup")
        ]),
        TypicalPortionEntry("baking powder", excluding: preparedWords.union(["biscuits", "biscuit"]), [
            TypicalPortion("tsp", 4.6, fdc: 172804, "tsp")
        ]),
        TypicalPortionEntry("vanilla extract", excluding: preparedWords, [
            TypicalPortion("tsp", 4.2, fdc: 173471, "tsp"),
            TypicalPortion("tbsp", 13, fdc: 173471, "tbsp")
        ])
    ]

    /// Oils, sweeteners, spreads, condiments, broth, greens and pulses.
    static let pantryEntries: [TypicalPortionEntry] = [
        TypicalPortionEntry("olive oil", excluding: oilProductWords, [
            TypicalPortion("tbsp", 13.5, fdc: 171413, "tablespoon"),
            TypicalPortion("cup", 216, fdc: 171413, "cup")
        ]),
        TypicalPortionEntry("vegetable oil", excluding: oilProductWords, [
            TypicalPortion("tbsp", 13.6, fdc: 171411, "tbsp"),
            TypicalPortion("cup", 218, fdc: 171411, "cup")
        ]),
        TypicalPortionEntry("canola oil", excluding: oilProductWords, [
            TypicalPortion("tbsp", 14, fdc: 172336, "tbsp"),
            TypicalPortion("cup", 218, fdc: 172336, "cup")
        ]),
        TypicalPortionEntry("coconut oil", excluding: oilProductWords, [
            TypicalPortion("tbsp", 13.6, fdc: 171412, "tbsp"),
            TypicalPortion("cup", 218, fdc: 171412, "cup")
        ]),
        TypicalPortionEntry("honey", excluding: preparedWords.union([
            "mustard", "roasted", "nut", "nuts", "graham", "grahams", "ham", "turkey", "cereal", "bbq",
            "barbecue", "dew", "honeydew", "melon", "wheat", "oat", "oats", "bun", "buns", "butter", "glazed",
            "crisp", "crunch", "dressing", "sauce", "chicken", "flavored", "cookies", "grahams"
        ]), [
            TypicalPortion("tbsp", 21, fdc: 169640, "tbsp"),
            TypicalPortion("cup", 339, fdc: 169640, "cup")
        ]),
        TypicalPortionEntry("maple syrup", excluding: preparedWords.union([
            "sausage", "bacon", "oatmeal", "pancake", "pancakes", "flavored", "imitation"
        ]), [
            TypicalPortion("tbsp", 20, fdc: 169661, "tbsp"),
            TypicalPortion("cup", 315, fdc: 169661, "cup")
        ]),
        TypicalPortionEntry("molasses", excluding: preparedWords.union(["cookie", "cookies", "bread"]), [
            TypicalPortion("tbsp", 20, fdc: 168820, "serving 1 tbsp"),
            TypicalPortion("cup", 337, fdc: 168820, "cup")
        ]),
        TypicalPortionEntry("peanut butter", excluding: preparedWords.union([
            "cookie", "cookies", "chips", "crackers", "cracker", "sandwich", "bar", "bars", "candy", "fudge",
            "pie", "cereal", "filled", "powdered", "powder", "cups", "puffs"
        ]), [
            TypicalPortion("tbsp", 16, fdc: 174265, "tbsp"),
            TypicalPortion("cup", 258, fdc: 174265, "cup")
        ]),
        TypicalPortionEntry("cinnamon", excluding: preparedWords.union([
            "roll", "rolls", "bun", "buns", "toast", "raisin", "bread", "sugar", "apple", "cereal", "crunch",
            "stick", "sticks", "swirl", "bagel", "candy", "grahams", "cookies"
        ]), [
            TypicalPortion("tsp", 2.6, fdc: 171320, "tsp"),
            TypicalPortion("tbsp", 7.8, fdc: 171320, "tbsp")
        ]),
        TypicalPortionEntry("ketchup", excluding: preparedWords, [
            TypicalPortion("tbsp", 17, fdc: 168556, "tbsp"),
            TypicalPortion("cup", 240, fdc: 168556, "cup")
        ]),
        TypicalPortionEntry("mayonnaise", excluding: preparedWords.union(["light", "reduced", "fat", "free"]), [
            TypicalPortion("tbsp", 13.8, fdc: 171009, "tbsp"),
            TypicalPortion("cup", 220, fdc: 171009, "cup")
        ]),
        TypicalPortionEntry("mustard", excluding: preparedWords.union([
            "seed", "seeds", "greens", "powder", "dry", "ground", "spinach", "oil", "dressing", "honey"
        ]), [
            TypicalPortion("tsp", 5, fdc: 172234, "tsp or 1 packet"),
            TypicalPortion("cup", 249, fdc: 172234, "cup")
        ]),
        TypicalPortionEntry("balsamic vinegar", excluding: preparedWords.union(vinegarProductWords), [
            TypicalPortion("tbsp", 16, fdc: 172241, "tbsp"),
            TypicalPortion("cup", 255, fdc: 172241, "cup")
        ]),
        TypicalPortionEntry("vinegar", excluding: preparedWords.union(vinegarProductWords).union(["balsamic"]), [
            TypicalPortion("tbsp", 14.9, fdc: 173469, "tbsp"),
            TypicalPortion("cup", 239, fdc: 173469, "cup")
        ]),
        TypicalPortionEntry("soy sauce", excluding: preparedWords, [
            TypicalPortion("tbsp", 16, fdc: 174277, "tbsp"),
            TypicalPortion("cup", 255, fdc: 174277, "cup")
        ]),
        TypicalPortionEntry("tomato paste", excluding: preparedWords, [
            TypicalPortion("tbsp", 16, fdc: 170459, "tbsp"),
            TypicalPortion("cup", 262, fdc: 170459, "cup")
        ]),
        TypicalPortionEntry("chicken broth", excluding: preparedWords.union([
            "cubes", "cube", "dry", "bouillon", "condensed", "powder", "granules"
        ]), [
            TypicalPortion("cup", 249, fdc: 174536, "cup")
        ]),
        TypicalPortionEntry("spinach", excluding: preparedWords.union([
            "frozen", "canned", "souffle", "dip", "pasta", "noodles", "tortilla", "wrap", "pie", "creamed",
            "sauteed", "water", "malabar", "mustard", "new", "zealand", "artichoke"
        ]), [
            TypicalPortion("cup", 30, fdc: 168462, "cup")
        ]),
        TypicalPortionEntry("chickpeas", excluding: preparedWords.union([
            "canned", "flour", "hummus", "roasted", "snack", "pasta", "puffs"
        ]), [
            TypicalPortion("cup", 200, fdc: 173756, "cup")
        ]),
        TypicalPortionEntry("lentils", excluding: preparedWords.union([
            "canned", "sprouted", "pasta", "chips", "soup", "flour"
        ]), [
            TypicalPortion("cup", 192, fdc: 172420, "cup")
        ]),
        TypicalPortionEntry("parmesan", excluding: preparedWords.union([
            "hard", "crisps", "dressing", "sauce", "chicken", "eggplant", "veal", "crusted"
        ]), [
            TypicalPortion("tbsp", 5, fdc: 171247, "tbsp"),
            TypicalPortion("cup", 100, fdc: 171247, "cup")
        ]),
        TypicalPortionEntry("cheddar", excluding: preparedWords.union([
            "soup", "sauce", "crackers", "sliced", "slices", "string", "spread", "powder", "dip", "bread",
            "biscuits", "chips", "puffs", "popcorn", "bites"
        ]), [
            TypicalPortion("cup, shredded", 113, fdc: 173414, "cup, shredded")
        ])
    ]

    /// Rice products that are not raw rice. Frozen English matching inputs.
    static let riceProductWords: Set<String> = [
        "flour", "cakes", "cake", "crackers", "cracker", "noodles", "bran", "syrup", "pasta", "parboiled"
    ]

    /// A dairy row's dry forms. Frozen English matching inputs.
    static let dryDairyWords: Set<String> = [
        "dry", "dried", "powder", "powdered", "condensed", "evaporated"
    ]

    /// Oil products that are not a pourable oil. Frozen English matching inputs.
    static let oilProductWords: Set<String> = [
        "spray", "dressing", "mayonnaise", "packed", "tuna", "sardines", "anchovies", "marinated", "pesto",
        "hydrogenated", "shortening", "margarine", "spread", "popcorn", "chips"
    ]

    /// Vinegar products that are not a vinegar. Frozen English matching inputs.
    static let vinegarProductWords: Set<String> = [
        "glaze", "dressing", "vinaigrette", "reduction", "pickled", "chips", "sauce"
    ]

    /// The volume unit a household label's first word states ("cup, packed" is a cup), or nil.
    public static func volumeUnit(ofLabel label: String) -> RecipeUnit? {
        let first = FoodItemSearch.normalized(label).split(separator: " ").first.map(String.init) ?? ""
        guard let unit = RecipeUnit.normalized(first), unit.isVolume else { return nil }
        return unit
    }

    /// Each entry's identity key, prepared once (``FoodIngredientIdentity/QueryHead``).
    static let heads: [FoodIngredientIdentity.QueryHead?] = entries.map { entry in
        FoodIngredientIdentity.QueryHead(searchTokens: entry.words, normalizedQuery: entry.key)
    }

    // MARK: - Lookups

    /// The entry whose ingredient `foodItem` IS, or nil: the first entry whose key words the row's name
    /// says, whose excluded words it does not, and whose head noun names it (``FoodIngredientIdentity``).
    public static func entry(for foodItem: FoodItem) -> TypicalPortionEntry? {
        let nameWords = Set(FoodItemSearch.normalized(foodItem.name).split(separator: " ").map(String.init))
        guard !nameWords.isEmpty else { return nil }
        for (index, entry) in entries.enumerated() {
            guard entry.excluding.isDisjoint(with: nameWords),
                  entry.words.allSatisfy({ !FoodIngredientIdentity.spokenForms(of: $0).isDisjoint(with: nameWords) }),
                  let head = heads[index], head.isNamed(by: foodItem) else { continue }
            return entry
        }
        return nil
    }

    /// The typical sizes the recipe editor offers for `foodItem` in the dimensions `lacking` — the ones
    /// its own data leaves empty (``RecipePortionPicker``): counts lightest first, then cup, tablespoon
    /// and teaspoon.
    public static func options(
        for foodItem: FoodItem, lacking: Set<RecipePortionOption.Dimension>
    ) -> [RecipePortionOption] {
        guard !lacking.isEmpty, let entry = entry(for: foodItem) else { return [] }
        let counts = lacking.contains(.count) ? entry.portions.filter { $0.dimension == .count }
            .sorted { $0.grams < $1.grams }
            .map { RecipePortionOption(source: .typicalSize, label: $0.label, gramsPerOne: $0.grams, dimension: .count) } : []
        let volumes = lacking.contains(.volume) ? volumeOptions(for: entry) : []
        return counts + volumes
    }

    /// The teaspoon, tablespoon and cup an entry's volume sizes offer, lightest first (the cup last): a
    /// spoon or cup the entry states, else the first stated volume's density times its volume ("tbsp,
    /// packed" of brown sugar is its packed cup's density), rounded to a tenth of a gram. Empty for a
    /// count-only entry.
    public static func volumeOptions(for entry: TypicalPortionEntry) -> [RecipePortionOption] {
        let stated = entry.portions.filter { $0.volumeUnit != nil }
        guard let basis = stated.first, let basisUnit = basis.volumeUnit,
              let basisMilliliters = basisUnit.baseAmount(for: 1) else { return [] }
        let qualifier = basis.label.split(separator: ",", maxSplits: 1).dropFirst().first.map { ",\($0)" } ?? ""
        return [RecipeUnit.teaspoon, .tablespoon, .cup].compactMap { unit in
            if let own = stated.first(where: { $0.volumeUnit == unit }) {
                return RecipePortionOption(source: .typicalSize, label: own.label, gramsPerOne: own.grams, dimension: .volume)
            }
            guard let milliliters = unit.baseAmount(for: 1) else { return nil }
            let grams = (basis.grams / basisMilliliters * milliliters * 10).rounded() / 10
            guard grams > 0 else { return nil }
            return RecipePortionOption(source: .typicalSize, label: unit.rawValue + qualifier, gramsPerOne: grams, dimension: .volume)
        }
    }

    /// The grams `quantity` `unit` of `foodItem` weighs by its typical size, for the web recipe
    /// importer when the row's own data cannot weigh the line: "each" through the entry's default count
    /// ("3 cloves garlic" on a row with no clove), a volume through the entry's volume sizes ("2 cups
    /// all-purpose flour" on a row with no cup). Nil for every other unit, a row no entry names, or an
    /// amount past the conversion bound.
    public static func grams(quantity: Double, unit: RecipeUnit, for foodItem: FoodItem) -> Double? {
        guard quantity.isFinite, quantity > 0, let entry = entry(for: foodItem) else { return nil }
        let grams: Double
        if unit == .each {
            guard quantity <= RecipeConversionLimits.maxCount, let one = entry.defaultCount else { return nil }
            grams = quantity * one.grams
        } else {
            let options = volumeOptions(for: entry)
            guard unit.isVolume, let milliliters = unit.baseAmount(for: quantity),
                  let cupGrams = options.last?.gramsPerOne, let cup = RecipeUnit.cup.baseAmount(for: 1) else { return nil }
            // A spoon or cup the entry states answers in its own grams; any other volume by the cup's.
            let stated = options.first { volumeUnit(ofLabel: $0.label) == unit }?.gramsPerOne
            grams = stated.map { quantity * $0 } ?? milliliters / cup * cupGrams
        }
        guard grams.isFinite, grams > 0, grams <= RecipeConversionLimits.maxGrams else { return nil }
        return grams
    }
}
