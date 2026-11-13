// FoodIngredientIdentity+Aisles.swift
// Roadmap G1, branded-category gate (owner decision 2026-11-13; Docs/Ingredient-Search-Deep-Research-2026-09-29.md
// "Update 2026-09-30 (later)": "a branded-category gate for flavor-last names such as lemon and lime").
import Foundation

extension FoodIngredientIdentity {
    /// FoodData Central's branded food categories whose products are composite goods — sweets, snacks,
    /// drinks, mixes, sauces, prepared meals — where a product name usually puts its FLAVOR last ("Cake
    /// Mix Extra Moist Lemon", "Sparkling Water Lime", "Candy Corn"), so the name's last word is not what
    /// the product is. Normalized (`FoodItemSearch.normalized`), so "Non Alcoholic Beverages - Ready to
    /// Drink" and the catalog's double-spaced spelling of it are one entry.
    ///
    /// FROZEN ENGLISH MATCHING INPUT (localization wall): compared with the catalog's English category
    /// text, never displayed.
    static let compositeAisles: Set<String> = [
        "alcohol",
        "baby infant foods beverages",
        "biscuits cookies",
        "bread",
        "bread muffin mixes",
        "breads buns",
        "cake cookie cupcake mixes",
        "cakes cupcakes snack cakes",
        "candy",
        "canned condensed soup",
        "canned soup",
        "cereal",
        "chewing gum mints",
        "chili stew",
        "chips crisps snack mixes natural extruded shelf stable",
        "chips pretzels snacks",
        "confectionery products",
        "cookies biscuits",
        "crackers biscotti",
        "croissants sweet rolls muffins other pastries",
        "dips salsa",
        "energy protein muscle recovery drinks",
        "entrees sides small meals",
        "flavored rice dishes",
        "flavored snack crackers",
        "frozen dinners entrees",
        "frozen pancakes waffles french toast crepes",
        "fruit vegetable juice nectars fruit drinks",
        "gelatin gels pectins desserts",
        "gravy mix",
        "ice cream frozen yogurt",
        "iced bottle tea",
        "jam jelly fruit spreads",
        "ketchup mustard bbq cheese sauce",
        "liquid water enhancer",
        "non alcoholic beverages ready to drink",
        "oriental mexican ethnic sauces",
        "other cooking sauces",
        "other drinks",
        "other frozen desserts",
        "other snacks",
        "other soups",
        "pasta dinners",
        "pastry shells fillings",
        "pizza",
        "pizza mixes other dry dinners",
        "popcorn peanuts seeds related snacks",
        "plant based water",
        "powdered drinks",
        "prepared soups",
        "processed cereal products",
        "puddings custards",
        "salad dressing mayonnaise",
        "sauces spreads dips condiments",
        "seasoning mixes salts marinades tenderizers",
        "snack energy granola bars",
        "snacks",
        "soda",
        "sport drinks",
        "sweet bakery products",
        "sweet spreads",
        "wholesome snacks",
        "yogurt",
        "yogurt yogurt substitutes"
    ]

    /// Whether a product row may be the ingredient a query names — the branded-category gate (roadmap
    /// G1, 2026-11-13). `headForms` are the spellings of the query's head nouns, `modifierForms` those
    /// of the words typed before them (``QueryHead``).
    ///
    /// The identity key reads a product name as one phrase whose last word is its head, and its own
    /// documentation records what that cannot see: a single-segment product name that puts its flavor
    /// last reads like the flavor. The category can see it. In a ``compositeAisles`` category a product
    /// counts as the ingredient only when one of these holds:
    /// - the category names the noun or a typed modifier ("Chocolate Chip Cookie" in "Cookies &
    ///   Biscuits" is a cookie; "Candy Corn" in "Candy" for "candy corn");
    /// - the person typed modifiers and the name says every one ("Chicken Broth" in "Canned Soup" for
    ///   "chicken broth", "Graham Crackers" in "Cookies & Biscuits" for "graham crackers");
    /// - the name is only the typed words, variant words and size words ("Honey" in "Sweet Spreads",
    ///   "Mini Marshmallows" in "Candy").
    /// So "Cake Mix Extra Moist Lemon" (a cake mix) is not a lemon and "Candy Corn" is not corn. Any
    /// other category — produce, spices, oils, cheese — leaves the name's reading alone.
    static func categoryAdmits(_ item: FoodItem, headForms: Set<String>, modifierForms: Set<String>) -> Bool {
        let aisle = FoodItemSearch.normalized(item.category)
        guard compositeAisles.contains(aisle) else { return true }
        let typed = headForms.union(modifierForms)
        let says: (Substring) -> Bool = { !forms(of: String($0)).isDisjoint(with: typed) }
        if aisle.split(separator: " ").contains(where: says) { return true }
        let nameWords = FoodItemSearch.normalized(item.name).split(separator: " ").prefix(maxNameWords)
        if !modifierForms.isEmpty, modifierForms.isSubset(of: Set(nameWords.flatMap { forms(of: String($0)) })) {
            return true
        }
        return nameWords.allSatisfy { word in
            says(word) || variantDescriptors.contains(String(word)) || sizeWords.contains(String(word))
        }
    }

    /// Size words a plain product's name may carry beside the typed words ("Mini Marshmallows").
    /// FROZEN ENGLISH MATCHING INPUT.
    static let sizeWords: Set<String> = ["mini", "miniature", "jumbo", "giant", "large", "small", "petite"]

    /// The most name words the gate reads (Power-of-10 R2).
    static let maxNameWords = 24
}
