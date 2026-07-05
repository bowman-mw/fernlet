import Foundation
import Vision

#if canImport(UIKit)
import UIKit

// MARK: - Classification value + protocol seam

/// One label from an on-device image classification pass.
public nonisolated struct FoodImageClassification: Equatable, Sendable {
    public let identifier: String
    public let confidence: Double

    public init(identifier: String, confidence: Double) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

/// Image classification behind a seam so the meal-photo flow can be unit-tested with a fake
/// classifier — the Vision specifics never leak into callers.
public nonisolated protocol FoodImageClassifying: Sendable {
    func classifications(in image: UIImage) async throws -> [FoodImageClassification]
}

/// Production classifier: `VNClassifyImageRequest` (fully on-device — the photo never leaves the
/// device). Returns the raw taxonomy labels; food filtering/composition is `FoodImageTaxonomy`'s job.
public nonisolated struct VisionFoodImageClassifier: FoodImageClassifying {
    public init() {}

    public func classifications(in image: UIImage) async throws -> [FoodImageClassification] {
        guard let cgImage = image.cgImage else { return [] }
        return try await Task.detached(priority: .userInitiated) {
            try Self.classifySynchronously(cgImage)
        }.value
    }

    nonisolated private static func classifySynchronously(_ cgImage: CGImage) throws -> [FoodImageClassification] {
        var classificationError: Error?
        var results: [FoodImageClassification] = []
        let request = VNClassifyImageRequest { request, error in
            if let error {
                classificationError = error
                return
            }
            let observations = request.results as? [VNClassificationObservation] ?? []
            results = observations.map {
                FoodImageClassification(identifier: $0.identifier, confidence: Double($0.confidence))
            }
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        if let classificationError {
            throw classificationError
        }
        return results
    }
}

// MARK: - Food taxonomy filter + description composition (pure, unit-tested)

/// Filters Vision's ~1300-class taxonomy down to food-related labels and composes the short text
/// description that feeds the EXISTING meal-resolution cascade (`store.resolveMeals`). Deliberately
/// conservative: only concrete foods are kept (no generic "food"/"dessert" buckets — those resolve
/// to nothing useful), a confidence floor drops wild guesses, and everything downstream still passes
/// through the normal pre-log review sheet.
public nonisolated enum FoodImageTaxonomy {
    public static let confidenceFloor = 0.3
    public static let maxLabels = 3

    /// True when the (underscore-separated) taxonomy identifier names something edible — matched
    /// per-token so compounds like `fruit_salad` or `ice_cream` hit via their food tokens.
    public static func isFoodIdentifier(_ identifier: String) -> Bool {
        tokens(of: identifier).contains { foodTokens.contains($0) }
    }

    /// The composed meal description for `resolveMeals` — top food labels above the confidence
    /// floor, joined with " and " (the form `MealItemSplitter` splits back into items). Nil when the
    /// photo yields nothing food-like, so callers can fall back gently ("want to type it?").
    public static func mealDescription(
        from classifications: [FoodImageClassification],
        confidenceFloor: Double = FoodImageTaxonomy.confidenceFloor,
        maxLabels: Int = FoodImageTaxonomy.maxLabels
    ) -> String? {
        var seen = Set<String>()
        let labels = classifications
            .filter { $0.confidence >= confidenceFloor && isFoodIdentifier($0.identifier) }
            .sorted { $0.confidence > $1.confidence }
            .map { displayName(for: $0.identifier) }
            .filter { seen.insert($0).inserted }
            .prefix(maxLabels)
        guard labels.isEmpty == false else { return nil }
        return labels.joined(separator: " and ")
    }

    /// "french_fries" → "french fries".
    static func displayName(for identifier: String) -> String {
        identifier.lowercased().replacingOccurrences(of: "_", with: " ")
    }

    private static func tokens(of identifier: String) -> [String] {
        displayName(for: identifier).split(separator: " ").map(String.init)
    }

    /// Concrete food tokens drawn from Vision's classification taxonomy. Generic buckets ("food",
    /// "dish", "dessert", "snack") are deliberately absent — a generic-only photo should take the
    /// "couldn't tell" fallback rather than resolve garbage.
    static let foodTokens: Set<String> = [
        // Fruits
        "apple", "apricot", "avocado", "banana", "blackberry", "blueberry", "cantaloupe", "cherry",
        "clementine", "coconut", "cranberry", "currant", "date", "fig", "fruit", "grape", "grapefruit",
        "grapes", "guava", "kiwi", "lemon", "lime", "lychee", "mango", "melon", "nectarine", "orange",
        "papaya", "peach", "pear", "persimmon", "pineapple", "plum", "pomegranate", "raspberry",
        "strawberry", "tangerine", "watermelon",
        // Vegetables
        "artichoke", "asparagus", "bean", "beans", "beet", "broccoli", "cabbage", "carrot",
        "cauliflower", "celery", "chickpea", "corn", "cucumber", "eggplant", "garlic", "kale", "leek",
        "lentil", "lettuce", "mushroom", "okra", "onion", "pea", "peas", "pepper", "potato", "pumpkin",
        "radish", "scallion", "spinach", "squash", "tomato", "turnip", "vegetable", "zucchini",
        // Grains & staples
        "bagel", "baguette", "biscuit", "bread", "cereal", "couscous", "cracker", "crepe", "dumpling",
        "gnocchi", "granola", "lasagna", "macaroni", "noodle", "noodles", "oatmeal", "pancake", "pasta",
        "pita", "polenta", "porridge", "pretzel", "quinoa", "ramen", "rice", "risotto", "spaghetti",
        "toast", "tortilla", "waffle",
        // Proteins
        "bacon", "beef", "brisket", "chicken", "clam", "cod", "crab", "egg", "eggs", "fish", "ham",
        "lamb", "lobster", "meatball", "meatloaf", "mussel", "octopus", "omelet", "omelette", "oyster",
        "pork", "prawn", "ribs", "salmon", "sausage", "scallop", "shrimp", "squid", "steak", "tempeh",
        "tofu", "trout", "tuna", "turkey",
        // Dishes
        "burger", "burrito", "casserole", "cheeseburger", "chili", "chowder", "coleslaw", "curry",
        "enchilada", "fajita", "falafel", "frittata", "fries", "guacamole", "gyro", "hamburger",
        "hotdog", "hummus", "kebab", "nacho", "nachos", "paella", "pizza", "quesadilla", "quiche",
        "salad", "salsa", "sandwich", "sashimi", "soup", "stew", "sushi", "taco", "tempura",
        "teriyaki", "wonton", "wrap",
        // Dairy
        "butter", "cheese", "cream", "milk", "yogurt",
        // Sweets & baked
        "brownie", "cake", "candy", "caramel", "cheesecake", "chocolate", "cookie", "croissant",
        "cupcake", "custard", "donut", "doughnut", "fudge", "gelato", "honey", "jam", "jelly",
        "macaron", "macaroon", "marshmallow", "muffin", "pie", "pudding", "scone", "sorbet", "tart",
        "tiramisu",
        // Drinks
        "cappuccino", "cocoa", "coffee", "espresso", "juice", "latte", "lemonade", "milkshake",
        "smoothie", "tea",
        // Nuts, seeds, snacks
        "almond", "cashew", "chips", "hazelnut", "nut", "peanut", "pecan", "pistachio", "popcorn",
        "walnut"
    ]
}

#endif
