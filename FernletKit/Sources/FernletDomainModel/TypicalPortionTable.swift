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
//   juiced, cooked or otherwise different form weighs something else — and, for a USDA row, the
//   catalog files it where that ingredient is filed (fix round 1: a head noun alone let a chocolate
//   egg, a sesame butter, an oat milk and a pasta sauce take a raw ingredient's size, so a USDA row
//   must sit in one of the entry's ``TypicalPortionEntry/categories`` — fail-closed, a row type the
//   lists never anticipated gets no estimate). The first matching entry wins, so the specific ("roma
//   tomato", "peanut butter", "brown sugar") precede the general.
//
// Every key, excluded word, category and label is a FROZEN ENGLISH TOKEN (localization wall): keys,
// exclusions and categories are matched against the catalog's English names and categories; a label is
// saved beside a recipe line's grams as its `RecipeHouseholdMeasure` label.
// `LocalizationBoundaryTests.frozenTypicalPortionTokens` pins them.

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
    /// The USDA catalog categories a USDA row of this ingredient may be in (fix round 1): a row outside
    /// them is a sweet, a dish, a sauce or a canned, frozen or snack form whose name happens to end in
    /// the ingredient — "Cadbury Mini Eggs Chocolate Egg" ("Confectionery Products"), "Prego Sauces
    /// Garlic", canned "Whole Potatoes" — and gets no typical size. Read only for a `.usda` row; a
    /// person's own food or a scanned product carries no USDA category. Frozen English matching
    /// inputs, compared with `FoodItem.category` exactly.
    public let categories: Set<String>
    /// The typical sizes: counts first (the first is the default "one"), then volumes.
    public let portions: [TypicalPortion]

    public init(_ key: String, excluding: Set<String> = [], categories: Set<String>, _ portions: [TypicalPortion]) {
        self.key = key
        self.excluding = excluding
        self.categories = categories
        self.portions = portions
    }

    /// Whether `foodItem` may be this ingredient by where the catalog files it: any row that is not
    /// USDA's, and a USDA row in one of ``categories``.
    public func admitsCategory(of foodItem: FoodItem) -> Bool {
        foodItem.source != .usda || categories.contains(foodItem.category)
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
    /// item. Frozen English matching inputs. Not "peel" or "skin": USDA writes "Cucumber, with peel,
    /// raw" and "Potatoes, russet, without skin, raw" of the whole vegetable (fix round 1) — a citrus
    /// entry excludes its peel on its own.
    public static let processedWords: Set<String> = [
        "babyfood", "baby", "baked", "battered", "beverage", "boiled", "bread", "breaded", "cake", "candied",
        "canned", "chips", "chopped", "concentrate", "cooked", "crinkle", "crushed", "cut", "cuts", "dehydrated", "diced",
        "dried", "drink", "flakes", "flour", "fried", "frozen", "grilled", "jam", "jelly", "juice", "julienned", "leaves",
        "mashed", "matchstick", "microwaved", "nectar", "oil", "paste", "pickled", "pie", "powder", "puree", "pureed",
        "riced", "roasted", "salad", "sauce", "sauteed", "seed", "seeds", "shredded", "sliced", "slices", "smashed",
        "smoothie", "soup", "spiral", "spirals", "spread", "steamed", "stewed", "strained", "strips", "stuffed",
        "sulfured", "syrup"
    ]

    /// Words that make a row a sweet, a dish, a drink or a product built on the ingredient — a chocolate
    /// egg, a sauce, a gratin, a flavoured water — or a miniature no typical size fits ("petite"
    /// potatoes, "mini" cucumbers), for the entries whose names products borrow (fix round 1). Frozen
    /// English matching inputs.
    public static let productWords: Set<String> = [
        "bacon", "bite", "bites", "candy", "caramel", "casserole", "cheddar", "chocolate", "chocolaty", "chunky",
        "cocktail", "creme", "deviled", "easter", "flavored", "fudge", "gratin", "marshmallow", "mini", "mix",
        "parmesan", "pesto", "petite", "prepared", "ranch", "sauces", "scalloped", "seasoned", "seasoning", "skillet",
        "steamers", "toffee", "water"
    ]

    /// ``processedWords`` and ``productWords``: what the produce and egg entries exclude.
    static let produceWords: Set<String> = processedWords.union(productWords)

    /// Words that make a chicken row a cut the typical boneless, skinless piece does not weigh: skin on,
    /// bone in ("split"), ground or shaved (fix round 1). Frozen English matching inputs.
    public static let cutWords: Set<String> = ["bone", "ground", "shaved", "skin", "split"]

    /// Words that make a grain, dairy or pantry row a cooked or prepared form, whose cup weighs something
    /// else. Frozen English matching inputs.
    public static let preparedWords: Set<String> = [
        "boiled", "cooked", "fried", "instant", "mix", "prepared", "steamed"
    ]

    /// The table, specific entries before general ones.
    public static let entries: [TypicalPortionEntry] = countEntries + volumeEntries

    /// Produce, eggs, chicken and butter: what one is.
    static let countEntries: [TypicalPortionEntry] = [
        TypicalPortionEntry("roma tomato", excluding: produceWords, categories: produceCategories, [
            TypicalPortion("Italian tomato", 62, fdc: 170457, "Italian tomato")
        ]),
        TypicalPortionEntry("plum tomato", excluding: produceWords, categories: produceCategories, [
            TypicalPortion("Italian tomato", 62, fdc: 170457, "Italian tomato")
        ]),
        TypicalPortionEntry("cherry tomato", excluding: produceWords, categories: produceCategories, [
            TypicalPortion("cherry tomato", 17, fdc: 170457, "cherry")
        ]),
        TypicalPortionEntry("tomato", excluding: produceWords.union([
            "cherry", "grape", "roma", "plum", "green", "sun", "tomatillo", "tomatillos"
        ]), categories: produceCategories, [
            TypicalPortion("medium", 123, fdc: 170457, "medium whole (2-3/5\" dia)"),
            TypicalPortion("small", 91, fdc: 170457, "small whole (2-2/5\" dia)"),
            TypicalPortion("large", 182, fdc: 170457, "large whole (3\" dia)")
        ]),
        TypicalPortionEntry("sweet potato", excluding: produceWords, categories: produceCategories, [
            TypicalPortion("sweet potato", 130, fdc: 168482, "sweetpotato, 5\" long")
        ]),
        TypicalPortionEntry("potato", excluding: produceWords.union([
            "sweet", "skins", "fries", "french", "hash", "starch", "puffs", "sticks", "tots", "au", "sour", "cream",
            "cheese", "chives", "loaded", "creamer", "fingerling"
        ]), categories: produceCategories, [
            TypicalPortion("medium", 213, fdc: 170026, "Potato medium (2-1/4\" to 3-1/4\" dia)"),
            TypicalPortion("small", 170, fdc: 170026, "Potato small (1-3/4\" to 2-1/2\" dia)"),
            TypicalPortion("large", 369, fdc: 170026, "Potato large (3\" to 4-1/4\" dia)")
        ]),
        TypicalPortionEntry("banana", excluding: produceWords.union(["plantain", "plantains", "pepper", "peppers", "wax", "hungarian"]), categories: produceCategories, [
            TypicalPortion("medium", 118, fdc: 173944, "medium (7\" to 7-7/8\" long)"),
            TypicalPortion("small", 101, fdc: 173944, "small (6\" to 6-7/8\" long)"),
            TypicalPortion("large", 136, fdc: 173944, "large (8\" to 8-7/8\" long)")
        ]),
        TypicalPortionEntry("apple", excluding: produceWords.union([
            "crab", "crabapple", "crabapples", "cider", "applesauce", "butter", "rose", "custard", "sugar", "star",
            "mammy", "cashew", "wax"
        ]), categories: produceCategories, [
            TypicalPortion("medium", 182, fdc: 171688, "medium (3\" dia)"),
            TypicalPortion("small", 149, fdc: 171688, "small (2-3/4\" dia)"),
            TypicalPortion("large", 223, fdc: 171688, "large (3-1/4\" dia)")
        ]),
        TypicalPortionEntry("egg white", excluding: produceWords.union(["yolk", "yolks", "substitute"]), categories: eggCategories, [
            TypicalPortion("large", 33, fdc: 172183, "large"),
            TypicalPortion("cup", 243, fdc: 172183, "cup")
        ]),
        TypicalPortionEntry("egg", excluding: produceWords.union([
            "white", "whites", "yolk", "yolks", "substitute", "duck", "goose", "quail", "turkey", "roll", "rolls",
            "nog", "eggnog", "noodles", "omelet", "scrambled", "benedict", "sandwich", "drop", "plant", "vegan",
            "bagel", "bagels", "biscuit", "biscuits", "custard", "fish", "herring", "roe", "cookies", "armadillo",
            "roadrunner", "liquid", "beaters", "jalapeno", "beet"
        ]), categories: eggCategories, [
            TypicalPortion("large", 50, fdc: 171287, "large"),
            TypicalPortion("medium", 44, fdc: 171287, "medium"),
            TypicalPortion("extra large", 56, fdc: 171287, "extra large")
        ]),
        TypicalPortionEntry("garlic", excluding: produceWords.union([
            "salt", "pepper", "chives", "wild", "bulbs", "herb", "herbs"
        ]), categories: produceCategories, [
            TypicalPortion("clove", 3, fdc: 169230, "clove"),
            TypicalPortion("tsp", 2.8, fdc: 169230, "tsp"),
            TypicalPortion("cup", 136, fdc: 169230, "cup")
        ]),
        TypicalPortionEntry("onion", excluding: produceWords.union([
            "spring", "scallion", "scallions", "green", "pearl", "rings", "dip", "welsh"
        ]), categories: produceCategories, [
            TypicalPortion("medium", 110, fdc: 170000, "medium (2-1/2\" dia)"),
            TypicalPortion("small", 70, fdc: 170000, "small"),
            TypicalPortion("large", 150, fdc: 170000, "large")
        ]),
        TypicalPortionEntry("lemon", excluding: produceWords.union(["grass", "lemongrass", "zest", "peel"]), categories: produceCategories, [
            TypicalPortion("fruit", 58, fdc: 167746, "fruit (2-1/8\" dia)"),
            TypicalPortion("large fruit", 84, fdc: 167746, "fruit (2-3/8\" dia)")
        ]),
        TypicalPortionEntry("lime", excluding: produceWords.union(["kaffir", "key", "peel"]), categories: produceCategories, [
            TypicalPortion("fruit", 67, fdc: 168155, "fruit (2\" dia)")
        ]),
        TypicalPortionEntry("orange", excluding: produceWords.union([
            "mandarin", "mandarins", "tangerine", "tangerines", "blood", "bitter", "peel"
        ]), categories: produceCategories, [
            TypicalPortion("fruit", 131, fdc: 169097, "fruit (2-5/8\" dia)"),
            TypicalPortion("small", 96, fdc: 169097, "small (2-3/8\" dia)"),
            TypicalPortion("large", 184, fdc: 169097, "large (3-1/16\" dia)")
        ]),
        TypicalPortionEntry("avocado", excluding: produceWords, categories: produceCategories, [
            TypicalPortion("fruit", 136, fdc: 171706, "fruit, without skin and seed")
        ]),
        TypicalPortionEntry("carrot", excluding: produceWords, categories: produceCategories, [
            TypicalPortion("medium", 61, fdc: 170393, "medium"),
            TypicalPortion("small", 50, fdc: 170393, "small (5-1/2\" long)"),
            TypicalPortion("large", 72, fdc: 170393, "large (7-1/4\" to 8-/1/2\" long)")
        ]),
        TypicalPortionEntry("celery", excluding: produceWords.union(["salt", "root", "celeriac"]), categories: produceCategories, [
            TypicalPortion("medium stalk", 40, fdc: 169988, "stalk, medium (7-1/2\" - 8\" long)"),
            TypicalPortion("small stalk", 17, fdc: 169988, "stalk, small (5\" long)"),
            TypicalPortion("large stalk", 64, fdc: 169988, "stalk, large (11\"-12\" long)")
        ]),
        TypicalPortionEntry("bell pepper", excluding: produceWords, categories: produceCategories, [
            TypicalPortion("medium", 119, fdc: 170427, "medium (approx 2-3/4\" long, 2-1/2\" dia)"),
            TypicalPortion("small", 74, fdc: 170427, "small"),
            TypicalPortion("large", 164, fdc: 170427, "large (2-1/4 per lb, approx 3-3/4\" long, 3\" dia)")
        ]),
        TypicalPortionEntry("jalapeno", excluding: produceWords, categories: produceCategories, [
            TypicalPortion("pepper", 14, fdc: 168576, "pepper")
        ]),
        TypicalPortionEntry("cucumber", excluding: produceWords.union(["sea", "pickle", "pickles"]), categories: produceCategories, [
            TypicalPortion("medium", 201, fdc: 169225, "medium"),
            TypicalPortion("small", 158, fdc: 169225, "small (6-3/8\" long)"),
            TypicalPortion("large", 280, fdc: 169225, "large (8-1/4\" long)")
        ]),
        TypicalPortionEntry("zucchini", excluding: produceWords, categories: produceCategories, [
            TypicalPortion("medium", 196, fdc: 169291, "medium"),
            TypicalPortion("small", 118, fdc: 169291, "small"),
            TypicalPortion("large", 323, fdc: 169291, "large")
        ]),
        TypicalPortionEntry("mushroom", excluding: produceWords.union([
            "shiitake", "portabella", "portobello", "portabello", "enoki", "oyster", "maitake", "morel", "morels",
            "chanterelle", "chanterelles", "straw", "wood", "ear", "truffle", "truffles", "reishi"
        ]), categories: produceCategories, [
            TypicalPortion("medium", 18, fdc: 169251, "medium"),
            TypicalPortion("small", 10, fdc: 169251, "small"),
            TypicalPortion("large", 23, fdc: 169251, "large")
        ]),
        TypicalPortionEntry("strawberry", excluding: produceWords, categories: produceCategories, [
            TypicalPortion("medium", 12, fdc: 167762, "medium (1-1/4\" dia)"),
            TypicalPortion("small", 7, fdc: 167762, "small (1\" dia)"),
            TypicalPortion("large", 18, fdc: 167762, "large (1-3/8\" dia)")
        ]),
        TypicalPortionEntry("peach", excluding: produceWords, categories: produceCategories, [
            TypicalPortion("medium", 150, fdc: 169928, "medium (2-2/3\" dia)"),
            TypicalPortion("small", 130, fdc: 169928, "small (2-1/2\" dia)"),
            TypicalPortion("large", 175, fdc: 169928, "large (2-3/4\" dia)")
        ]),
        TypicalPortionEntry("pear", excluding: produceWords.union(["prickly", "asian"]), categories: produceCategories, [
            TypicalPortion("medium", 178, fdc: 169118, "medium"),
            TypicalPortion("small", 148, fdc: 169118, "small"),
            TypicalPortion("large", 230, fdc: 169118, "large")
        ]),
        TypicalPortionEntry("chicken thigh", excluding: processedWords.union(cutWords), categories: poultryCategories, [
            TypicalPortion("thigh", 149, fdc: 173627, "thigh without skin")
        ]),
        TypicalPortionEntry("chicken breast", excluding: processedWords.union(cutWords).union([
            "tenders", "tenderloins", "nuggets", "patty", "patties", "crusted", "encrusted", "rotisserie", "seared"
        ]), categories: poultryCategories, [
            TypicalPortion("breast half", 118, fdc: 171509, "breast")
        ]),
        TypicalPortionEntry("butter", excluding: productWords.union([
            "peanut", "almond", "cashew", "apple", "cocoa", "shea", "nut", "seed", "sunflower", "soy", "oil",
            "ghee", "clarified", "whipped", "light", "margarine", "spread", "blend", "cookies", "cookie",
            "cake", "sauce", "beans", "bean", "lettuce", "squash", "milk", "buttermilk", "cream", "herb",
            "popcorn", "crackers", "pecan", "toffee", "rum", "bread", "rolls", "sesame", "tahini", "hazelnut",
            "cacao", "coconut", "plum", "baba", "walnut", "pistachio", "macadamia", "pumpkin", "soynut", "honey",
            "pear", "peach", "pecans", "spreadable", "sugar", "cinnamon", "maple", "brownie", "batter", "granola",
            "coffee", "bourbon", "bagel", "kit", "lobster", "tails", "brussels", "sprouts", "potato", "potatoes",
            "lamb"
        ]), categories: butterCategories, [
            TypicalPortion("stick", 113, fdc: 173410, "stick"),
            TypicalPortion("tbsp", 14.2, fdc: 173410, "tbsp"),
            TypicalPortion("cup", 227, fdc: 173410, "cup")
        ])
    ]

    /// Baking and pantry staples: what a cup or spoon of them weighs.
    static let volumeEntries: [TypicalPortionEntry] = bakingEntries + pantryEntries

    /// Flours, sugars, chips, grains and dairy.
    static let bakingEntries: [TypicalPortionEntry] = [
        TypicalPortionEntry("all purpose flour", excluding: preparedWords.union(["self", "rising", "tortilla"]), categories: flourCategories, [
            TypicalPortion("cup", 125, fdc: 168894, "cup")
        ]),
        TypicalPortionEntry("bread flour", excluding: preparedWords, categories: flourCategories, [
            TypicalPortion("cup", 137, fdc: 168896, "cup")
        ]),
        TypicalPortionEntry("whole wheat flour", excluding: preparedWords.union(["pastry"]), categories: flourCategories, [
            TypicalPortion("cup", 120, fdc: 168893, "cup")
        ]),
        TypicalPortionEntry("brown sugar", excluding: preparedWords.union([
            "cookies", "cereal", "oatmeal", "syrup", "ham", "bacon", "glaze", "sauce", "maple", "cinnamon"
        ]), categories: sugarCategories, [
            TypicalPortion("cup, packed", 220, fdc: 168833, "cup packed"),
            TypicalPortion("tsp, packed", 4.6, fdc: 168833, "tsp packed")
        ]),
        TypicalPortionEntry("powdered sugar", excluding: preparedWords.union(["icing", "glaze", "frosting"]), categories: sugarCategories, [
            TypicalPortion("cup", 120, fdc: 169656, "cup unsifted"),
            TypicalPortion("tbsp", 8, fdc: 169656, "tbsp unsifted")
        ]),
        TypicalPortionEntry("sugar", excluding: preparedWords.union([
            "brown", "powdered", "confectioners", "maple", "coconut", "substitute", "free", "cookies", "cookie",
            "snap", "snaps", "syrup", "alcohol", "alcohols", "wafers", "cereal", "sprinkles", "candy", "cubes",
            "icing", "glaze", "cinnamon", "vanilla", "frosted", "coated", "liquid"
        ]), categories: sugarCategories, [
            TypicalPortion("cup", 200, fdc: 169655, "cup"),
            TypicalPortion("tsp", 4.2, fdc: 169655, "tsp")
        ]),
        TypicalPortionEntry("white chocolate chips", excluding: preparedWords, categories: chipCategories, [
            TypicalPortion("cup", 170, fdc: 167571, "cup chips")
        ]),
        TypicalPortionEntry("milk chocolate chips", excluding: preparedWords, categories: chipCategories, [
            TypicalPortion("cup", 168, fdc: 167587, "cup chips")
        ]),
        TypicalPortionEntry("chocolate chips", excluding: preparedWords.union([
            "white", "milk", "cookie", "cookies", "dough", "bar", "bars", "granola", "muffin", "muffins",
            "pancake", "pancakes", "waffle", "waffles", "cereal", "ice", "cream", "trail", "brownie", "brownies"
        ]), categories: chipCategories, [
            TypicalPortion("cup", 168, fdc: 167976, "cup chips (6 oz package)")
        ]),
        TypicalPortionEntry("oats", excluding: preparedWords.union(productWords).union([
            "steel", "bran", "flour", "milk", "cereal", "cookie", "cookies", "bar", "bars", "granola", "oatmeal",
            "barista", "overnight", "crispy", "toasted", "honey", "frosted", "buttered", "chilled", "drink",
            "beverage", "oatmilk", "tots", "snacks", "strudel", "cranberry", "banana", "peach", "pumpkin", "plum",
            "fruit", "apple", "cinnamon", "almond", "pecan", "butter", "flavor", "maple", "brown", "sugar", "blueberry",
            "berry", "vanilla", "coconut", "matcha", "acai", "turmeric", "lemon", "collagen", "protein", "porridge",
            "walnut", "cashew"
        ]), categories: oatCategories, [
            TypicalPortion("cup", 81, fdc: 173904, "cup")
        ]),
        TypicalPortionEntry("brown rice", excluding: preparedWords.union(riceProductWords), categories: grainCategories, [
            TypicalPortion("cup", 185, fdc: 169703, "cup")
        ]),
        TypicalPortionEntry("rice", excluding: preparedWords.union(riceProductWords).union([
            "brown", "wild", "black", "red", "milk", "pudding", "wine", "vinegar", "paper", "krispies", "beans",
            "bean", "sweet", "sticky", "glutinous", "cheese"
        ]), categories: grainCategories, [
            TypicalPortion("cup", 185, fdc: 168877, "cup")
        ]),
        TypicalPortionEntry("quinoa", excluding: preparedWords.union([
            "flour", "flakes", "puffed", "pasta", "bulgur", "mixture", "medley", "mediterranean", "spinach", "mushroom",
            "mushrooms", "herb", "herbs", "garlic", "parmesan"
        ]), categories: grainCategories, [
            TypicalPortion("cup", 170, fdc: 168874, "cup")
        ]),
        TypicalPortionEntry("almond milk", excluding: preparedWords.union(["chocolate", "creamer", "cacao"]),
                           categories: plantMilkCategories, [
            TypicalPortion("cup", 262, fdc: 174832, "cup")
        ]),
        TypicalPortionEntry("buttermilk", excluding: preparedWords.union(dryDairyWords).union([
            "biscuit", "biscuits", "pancake", "pancakes", "ranch", "dressing"
        ]), categories: milkCategories, [
            TypicalPortion("cup", 245, fdc: 170874, "cup")
        ]),
        TypicalPortionEntry("heavy cream", excluding: preparedWords.union(["whipped", "sour", "cheese", "ice", "sauce", "soup"]), categories: milkCategories, [
            TypicalPortion("cup", 238, fdc: 170859, "cup, fluid (yields 2 cups whipped)"),
            TypicalPortion("tbsp", 15, fdc: 170859, "tbsp")
        ]),
        TypicalPortionEntry("sour cream", excluding: preparedWords.union(["dip", "onion", "chips", "sauce", "dressing", "imitation"]), categories: milkCategories, [
            TypicalPortion("cup", 230, fdc: 171257, "cup"),
            TypicalPortion("tbsp", 12, fdc: 171257, "tbsp")
        ]),
        TypicalPortionEntry("cream cheese", excluding: preparedWords.union(["whipped", "frosting", "icing", "wontons", "rangoon"]), categories: cheeseCategories, [
            TypicalPortion("tbsp", 14.5, fdc: 173418, "tbsp"),
            TypicalPortion("cup", 232, fdc: 173418, "cup")
        ]),
        TypicalPortionEntry("milk", excluding: preparedWords.union(dryDairyWords).union([
            "chocolate", "buttermilk", "almond", "oat", "soy", "rice", "coconut", "cashew", "hemp", "goat",
            "human", "shake", "shakes", "cheese", "bread", "cereal", "substitute", "imitation", "creamer",
            "eggnog", "malted", "pudding", "sauce", "gravy", "tea", "coffee", "latte", "toast"
        ]), categories: milkCategories, [
            TypicalPortion("cup", 244, fdc: 171265, "cup"),
            TypicalPortion("tbsp", 15, fdc: 171265, "tbsp")
        ]),
        TypicalPortionEntry("yogurt", excluding: preparedWords.union([
            "greek", "frozen", "covered", "coated", "raisins", "pretzels", "drink", "dressing", "dip",
            "smoothie", "bar", "bars", "parfait", "tube", "tubes"
        ]), categories: yogurtCategories, [
            TypicalPortion("cup", 245, fdc: 171284, "cup (8 fl oz)")
        ]),
        TypicalPortionEntry("shredded coconut", excluding: preparedWords, categories: bakingCategories, [
            TypicalPortion("cup", 93, fdc: 168586, "cup, shredded")
        ]),
        TypicalPortionEntry("cocoa powder", excluding: preparedWords.union(["drink", "beverage", "hot"]), categories: bakingCategories, [
            TypicalPortion("tbsp", 5.4, fdc: 169593, "tbsp"),
            TypicalPortion("cup", 86, fdc: 169593, "cup")
        ]),
        TypicalPortionEntry("cornstarch", excluding: preparedWords, categories: bakingCategories, [
            TypicalPortion("cup", 128, fdc: 169698, "cup")
        ]),
        TypicalPortionEntry("baking powder", excluding: preparedWords.union(["biscuits", "biscuit"]), categories: bakingCategories, [
            TypicalPortion("tsp", 4.6, fdc: 172804, "tsp")
        ]),
        TypicalPortionEntry("vanilla extract", excluding: preparedWords, categories: bakingCategories, [
            TypicalPortion("tsp", 4.2, fdc: 173471, "tsp"),
            TypicalPortion("tbsp", 13, fdc: 173471, "tbsp")
        ])
    ]

    /// Oils, sweeteners, spreads, condiments, broth, greens and pulses.
    static let pantryEntries: [TypicalPortionEntry] = [
        TypicalPortionEntry("olive oil", excluding: oilProductWords, categories: oilCategories, [
            TypicalPortion("tbsp", 13.5, fdc: 171413, "tablespoon"),
            TypicalPortion("cup", 216, fdc: 171413, "cup")
        ]),
        TypicalPortionEntry("vegetable oil", excluding: oilProductWords, categories: oilCategories, [
            TypicalPortion("tbsp", 13.6, fdc: 171411, "tbsp"),
            TypicalPortion("cup", 218, fdc: 171411, "cup")
        ]),
        TypicalPortionEntry("canola oil", excluding: oilProductWords, categories: oilCategories, [
            TypicalPortion("tbsp", 14, fdc: 172336, "tbsp"),
            TypicalPortion("cup", 218, fdc: 172336, "cup")
        ]),
        TypicalPortionEntry("coconut oil", excluding: oilProductWords, categories: oilCategories, [
            TypicalPortion("tbsp", 13.6, fdc: 171412, "tbsp"),
            TypicalPortion("cup", 218, fdc: 171412, "cup")
        ]),
        TypicalPortionEntry("honey", excluding: preparedWords.union([
            "mustard", "roasted", "nut", "nuts", "graham", "grahams", "ham", "turkey", "cereal", "bbq",
            "barbecue", "dew", "honeydew", "melon", "wheat", "oat", "oats", "bun", "buns", "butter", "glazed",
            "crisp", "crunch", "dressing", "sauce", "chicken", "flavored", "cookies", "grahams", "granulated", "dried",
            "crystals", "powder"
        ]), categories: sweetenerCategories, [
            TypicalPortion("tbsp", 21, fdc: 169640, "tbsp"),
            TypicalPortion("cup", 339, fdc: 169640, "cup")
        ]),
        TypicalPortionEntry("maple syrup", excluding: preparedWords.union([
            "sausage", "bacon", "oatmeal", "pancake", "pancakes", "flavored", "imitation"
        ]), categories: sweetenerCategories, [
            TypicalPortion("tbsp", 20, fdc: 169661, "tbsp"),
            TypicalPortion("cup", 315, fdc: 169661, "cup")
        ]),
        TypicalPortionEntry("molasses", excluding: preparedWords.union(["cookie", "cookies", "bread"]), categories: sweetenerCategories, [
            TypicalPortion("tbsp", 20, fdc: 168820, "serving 1 tbsp"),
            TypicalPortion("cup", 337, fdc: 168820, "cup")
        ]),
        TypicalPortionEntry("peanut butter", excluding: preparedWords.union([
            "cookie", "cookies", "chips", "crackers", "cracker", "sandwich", "bar", "bars", "candy", "fudge",
            "pie", "cereal", "filled", "powdered", "powder", "cups", "puffs"
        ]), categories: nutButterCategories, [
            TypicalPortion("tbsp", 16, fdc: 174265, "tbsp"),
            TypicalPortion("cup", 258, fdc: 174265, "cup")
        ]),
        TypicalPortionEntry("cinnamon", excluding: preparedWords.union([
            "roll", "rolls", "bun", "buns", "toast", "raisin", "bread", "sugar", "apple", "cereal", "crunch",
            "stick", "sticks", "swirl", "bagel", "candy", "grahams", "cookies"
        ]), categories: spiceCategories, [
            TypicalPortion("tsp", 2.6, fdc: 171320, "tsp"),
            TypicalPortion("tbsp", 7.8, fdc: 171320, "tbsp")
        ]),
        TypicalPortionEntry("ketchup", excluding: preparedWords, categories: condimentCategories, [
            TypicalPortion("tbsp", 17, fdc: 168556, "tbsp"),
            TypicalPortion("cup", 240, fdc: 168556, "cup")
        ]),
        TypicalPortionEntry("mayonnaise", excluding: preparedWords.union(["light", "reduced", "fat", "free"]), categories: condimentCategories, [
            TypicalPortion("tbsp", 13.8, fdc: 171009, "tbsp"),
            TypicalPortion("cup", 220, fdc: 171009, "cup")
        ]),
        TypicalPortionEntry("mustard", excluding: preparedWords.union([
            "seed", "seeds", "greens", "powder", "dry", "ground", "spinach", "oil", "dressing", "honey"
        ]), categories: condimentCategories, [
            TypicalPortion("tsp", 5, fdc: 172234, "tsp or 1 packet"),
            TypicalPortion("cup", 249, fdc: 172234, "cup")
        ]),
        TypicalPortionEntry("balsamic vinegar", excluding: preparedWords.union(vinegarProductWords), categories: condimentCategories, [
            TypicalPortion("tbsp", 16, fdc: 172241, "tbsp"),
            TypicalPortion("cup", 255, fdc: 172241, "cup")
        ]),
        TypicalPortionEntry("vinegar", excluding: preparedWords.union(vinegarProductWords).union(["balsamic"]), categories: condimentCategories, [
            TypicalPortion("tbsp", 14.9, fdc: 173469, "tbsp"),
            TypicalPortion("cup", 239, fdc: 173469, "cup")
        ]),
        TypicalPortionEntry("soy sauce", excluding: preparedWords.union(["chili", "sambal", "sweet", "kecap"]),
                           categories: condimentCategories, [
            TypicalPortion("tbsp", 16, fdc: 174277, "tbsp"),
            TypicalPortion("cup", 255, fdc: 174277, "cup")
        ]),
        TypicalPortionEntry("tomato paste", excluding: preparedWords, categories: condimentCategories, [
            TypicalPortion("tbsp", 16, fdc: 170459, "tbsp"),
            TypicalPortion("cup", 262, fdc: 170459, "cup")
        ]),
        TypicalPortionEntry("chicken broth", excluding: preparedWords.union([
            "cubes", "cube", "dry", "bouillon", "condensed", "powder", "granules"
        ]), categories: brothCategories, [
            TypicalPortion("cup", 249, fdc: 174536, "cup")
        ]),
        TypicalPortionEntry("spinach", excluding: preparedWords.union([
            "frozen", "canned", "souffle", "dip", "pasta", "noodles", "tortilla", "wrap", "pie", "creamed",
            "sauteed", "water", "malabar", "mustard", "new", "zealand", "artichoke"
        ]), categories: produceCategories, [
            TypicalPortion("cup", 30, fdc: 168462, "cup")
        ]),
        TypicalPortionEntry("chickpeas", excluding: preparedWords.union([
            "canned", "flour", "hummus", "roasted", "snack", "pasta", "puffs"
        ]), categories: pulseCategories, [
            TypicalPortion("cup", 200, fdc: 173756, "cup")
        ]),
        TypicalPortionEntry("lentils", excluding: preparedWords.union([
            "canned", "sprouted", "pasta", "chips", "soup", "flour"
        ]), categories: pulseCategories, [
            TypicalPortion("cup", 192, fdc: 172420, "cup")
        ]),
        TypicalPortionEntry("parmesan", excluding: preparedWords.union([
            "hard", "crisps", "dressing", "sauce", "chicken", "eggplant", "veal", "crusted"
        ]), categories: cheeseCategories, [
            TypicalPortion("tbsp", 5, fdc: 171247, "tbsp"),
            TypicalPortion("cup", 100, fdc: 171247, "cup")
        ]),
        TypicalPortionEntry("cheddar", excluding: preparedWords.union([
            "soup", "sauce", "crackers", "sliced", "slices", "string", "spread", "powder", "dip", "bread",
            "biscuits", "chips", "puffs", "popcorn", "bites"
        ]), categories: cheeseCategories, [
            TypicalPortion("cup, shredded", 113, fdc: 173414, "cup, shredded")
        ])
    ]

    // MARK: - Where USDA files each ingredient (fix round 1)

    /// Fresh produce: USDA's reference produce groups and the branded fresh-produce aisle — never
    /// "Canned Vegetables", "Frozen Vegetables", the branded "Tomatoes" aisle (crushed, peeled and strained
    /// tomatoes in cans and jars) or a sauce, dish or snack aisle.
    static let produceCategories: Set<String> = [
        "Berries/Small Fruit", "Fruits - Unprepared/Unprocessed (Shelf Stable)", "Fruits and Fruit Juices",
        "Pre-Packaged Fruit & Vegetables", "Vegetables - Unprepared/Unprocessed (Shelf Stable)",
        "Vegetables and Vegetable Products"
    ]

    /// Shell eggs and egg whites.
    static let eggCategories: Set<String> = ["Dairy and Egg Products", "Eggs & Egg Substitutes", "Eggs/Eggs Substitutes"]

    /// Raw chicken — never cold cuts, canned meat or a cooked, prepared product.
    static let poultryCategories: Set<String> = [
        "Frozen Poultry, Chicken & Turkey", "Meat/Poultry/Other Animals  Unprepared/Unprocessed",
        "Meat/Poultry/Other Animals - Unprepared/Unprocessed", "Poultry Products", "Poultry, Chicken & Turkey"
    ]

    /// Dairy butter — never a nut, seed or fruit butter.
    static let butterCategories: Set<String> = [
        "Butter & Spread", "Butter/Butter Substitutes", "Dairy and Egg Products", "Fats Edible", "Fats and Oils"
    ]

    /// Flours.
    static let flourCategories: Set<String> = [
        "Cereal Grains and Pasta", "Flour - Cereal/Pulse (Shelf Stable)", "Flours & Corn Meal", "Grains/Flour"
    ]

    /// Sugars — never a decorating sugar or a seasoning.
    static let sugarCategories: Set<String> = [
        "Baking", "Granulated, Brown & Powdered Sugar", "Sugars/Sugar Substitute Products", "Sweets"
    ]

    /// Baking chips.
    static let chipCategories: Set<String> = [
        "Baking Additives & Extracts", "Baking Decorations & Dessert Toppings", "Chocolate", "Sweets"
    ]

    /// Oats, which USDA's branded aisle files as cereal.
    static let oatCategories: Set<String> = [
        "Breakfast Cereals", "Cereal", "Cereal Grains and Pasta", "Cereals Products - Not Ready to Eat (Shelf Stable)",
        "Grains/Flour", "Other Grains & Seeds"
    ]

    /// Rice and quinoa — never a soup, a deli side or a cereal.
    static let grainCategories: Set<String> = ["Cereal Grains and Pasta", "Grains/Flour", "Other Grains & Seeds", "Rice"]

    /// Almond milk.
    static let plantMilkCategories: Set<String> = ["Beverages", "Milk/Milk Substitutes", "Plant Based Milk"]

    /// Milk and cream — never a cheese or a yogurt drink.
    static let milkCategories: Set<String> = [
        "Cream", "Cream/Cream Substitutes", "Dairy and Egg Products", "Milk", "Milk/Milk Substitutes"
    ]

    /// Yogurt.
    static let yogurtCategories: Set<String> = [
        "Dairy and Egg Products", "Yogurt", "Yogurt/Yogurt Substitutes", "Yogurt/Yogurt Substitutes (Perishable)"
    ]

    /// Cheese, cream cheese among them.
    static let cheeseCategories: Set<String> = ["Cheese", "Cheese/Cheese Substitutes", "Dairy and Egg Products"]

    /// Baking staples: coconut, cocoa, cornstarch, leavening and extracts.
    static let bakingCategories: Set<String> = [
        "Baked Products", "Baking Additives & Extracts", "Baking/Cooking Supplies (Shelf Stable)", "Cereal Grains and Pasta",
        "Flours & Corn Meal", "Herbs & Spices", "Herbs/Spices/Extracts", "Nut and Seed Products", "Spices and Herbs", "Sweets"
    ]

    /// Pourable oils (a branded olive oil may be filed beside the dressings).
    static let oilCategories: Set<String> = [
        "Fats Edible", "Fats and Oils", "Oils Edible", "Salad Dressing & Mayonnaise", "Vegetable & Cooking Oils"
    ]

    /// Honey and syrups.
    static let sweetenerCategories: Set<String> = ["Honey", "Sweets", "Syrups & Molasses"]

    /// Peanut butter.
    static let nutButterCategories: Set<String> = ["Legumes and Legume Products", "Nut & Seed Butters"]

    /// Ground spices.
    static let spiceCategories: Set<String> = ["Herbs & Spices", "Herbs/Spices/Extracts", "Spices and Herbs"]

    /// Condiments, vinegars and sauces used as ingredients (USDA files vinegar and mustard with the
    /// spices, soy sauce with the legumes, ketchup and tomato paste with the vegetables — a branded
    /// tomato paste with the canned tomatoes or the prepared vegetables).
    static let condimentCategories: Set<String> = [
        "Fats and Oils", "Ketchup, Mustard, BBQ & Cheese Sauce", "Legumes and Legume Products",
        "Oriental, Mexican & Ethnic Sauces", "Other Condiments", "Other Cooking Sauces", "Salad Dressing & Mayonnaise",
        "Sauces/Spreads/Dips/Condiments", "Spices and Herbs", "Tomatoes", "Vegetables - Prepared/Processed",
        "Vegetables  Prepared/Processed", "Vegetables and Vegetable Products", "Vinegars/Cooking Wines"
    ]

    /// Broth, which the branded aisle files with the soups.
    static let brothCategories: Set<String> = [
        "Canned Condensed Soup", "Canned Soup", "Other Soups", "Prepared Soups", "Soups - Prepared (Shelf Stable)",
        "Soups, Sauces, and Gravies"
    ]

    /// Dry pulses — never canned beans.
    static let pulseCategories: Set<String> = [
        "Chickpeas", "Legumes and Legume Products", "Other Grains & Seeds", "Pre-Packaged Fruit & Vegetables",
        "Vegetable and Lentil Mixes"
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
    /// says, whose excluded words it does not, whose categories admit it
    /// (``TypicalPortionEntry/admitsCategory(of:)``), and whose head noun names it
    /// (``FoodIngredientIdentity``).
    public static func entry(for foodItem: FoodItem) -> TypicalPortionEntry? {
        let nameWords = Set(FoodItemSearch.normalized(foodItem.name).split(separator: " ").map(String.init))
        guard !nameWords.isEmpty else { return nil }
        for (index, entry) in entries.enumerated() {
            guard entry.excluding.isDisjoint(with: nameWords), entry.admitsCategory(of: foodItem),
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
