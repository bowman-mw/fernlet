//
//  SillyFoodCounter.swift
//  Fernlet
//
//  Counts cookies, bananas, eggs, pizza slices and cups of coffee or tea in logged meals, for the
//  silly stats. Matching is by name — the meal's and each component's — because a logged meal
//  carries no food category of its own. The match words are English tokens and stay English in
//  every locale (they read what the food database and the user typed, not what the app displays).
//
//  Counting is deliberately approximate: a serving of Oreos is three Oreos, 50 g of egg is one
//  egg, a meal named "2 bananas" is two bananas, and anything logged from one of the user's own
//  recipes that is a cookie is one whole homemade cookie, whatever its size.
//

import Foundation
import FernletDomainModel

/// How to recognise one food by name and how many items a logged amount of it holds.
struct SillyFoodRule: Sendable {
    /// Normalised words or phrases that identify the food ("oreo", "thin mint").
    let keywords: [String]
    /// Normalised words or phrases that rule a match out ("cookie dough").
    let exclusions: [String]
    /// Items in one logged serving.
    let itemsPerServing: Double
    /// Grams in one item, for components logged by weight (milliliters for drinks).
    let gramsPerItem: Double
}

/// A kind of cookie on the cookie table and what one of it is worth in cookies.
///
/// The table is the joke the user asked for: an Oreo is half a cookie, a Samoa is doing a lot, and a
/// homemade cookie (``SillyFoodCounter/homemadeCookieValue``) is always worth a full one.
struct SillyCookieRule: Identifiable, Sendable {
    /// Which row of the cookie table this is.
    enum Kind: CaseIterable, Sendable {
        case fortune, animalCracker, giantBakery, sandwich, girlScoutHalf, figNewton, girlScoutFull, standard
    }

    let kind: Kind
    let food: SillyFoodRule
    /// Cookie-equivalents per cookie of this kind.
    let value: Double

    var id: Kind { kind }
}

/// Counts silly-stat foods in meals.
///
/// Pure. Every count is capped per meal at ``maxItemsPerMeal`` so one mistyped quantity cannot
/// swamp a lifetime total.
enum SillyFoodCounter {
    /// The most items one meal can add to any count.
    static let maxItemsPerMeal = 100.0
    /// A cookie made from one of the user's own recipes is always one whole cookie.
    static let homemadeCookieValue = 1.0
    /// The most leading digits read as a quantity from a meal name ("2 bananas").
    private static let maxNameQuantity = 50.0

    /// Words that mean the food is in something else rather than eaten as itself.
    private static let cookieExclusions = [
        "cookie dough", "cookie and cream", "cookie n cream", "cookie cream", "cookie butter",
        "cookie crisp", "cookie crumb", "ice cream", "cheesecake", "milkshake", "shake", "mcflurry",
        "blizzard", "crust", "cereal", "pudding",
    ]

    /// The cookie table, most specific first: the first rule that matches a name wins, so
    /// "fortune cookie" is never read as a plain cookie.
    static let cookieTable: [SillyCookieRule] = [
        cookie(.fortune, ["fortune cookie"], value: 0.25, perServing: 1, grams: 8),
        cookie(.animalCracker, ["animal cracker"], value: 0.1, perServing: 16, grams: 2),
        cookie(.giantBakery, ["giant cookie", "bakery cookie", "jumbo cookie", "crumbl", "cookie cake"],
               value: 2, perServing: 1, grams: 85),
        cookie(.sandwich, ["oreo", "sandwich cookie", "creme cookie", "hydrox"], value: 0.5, perServing: 3, grams: 11.3),
        cookie(.girlScoutHalf, ["thin mint", "trefoil", "do si do", "do si dos", "dosido"],
               value: 0.5, perServing: 4, grams: 8),
        cookie(.figNewton, ["fig newton", "newton"], value: 0.5, perServing: 2, grams: 14),
        cookie(.girlScoutFull, ["samoa", "caramel delite", "tagalong", "peanut butter pattie", "peanut butter patty"],
               value: 1, perServing: 2, grams: 15),
        cookie(.standard, ["cookie", "biscotti", "biscotto", "snickerdoodle", "macaron", "macaroon", "shortbread", "gingersnap"],
               value: 1, perServing: 1, grams: 15),
    ]

    static let banana = SillyFoodRule(
        keywords: ["banana"],
        exclusions: ["banana bread", "banana pepper", "banana chip", "banana muffin", "banana pudding", "banana cake",
                     "banana pancake", "banana waffle", "banana cream", "banana nut"],
        itemsPerServing: 1, gramsPerItem: 118)

    static let egg = SillyFoodRule(
        keywords: ["egg"], exclusions: ["egg roll", "egg noodle", "egg drop"], itemsPerServing: 1, gramsPerItem: 50)

    static let pizzaSlice = SillyFoodRule(
        keywords: ["pizza"], exclusions: ["pizza sauce", "pizza dough", "pizza crust", "pizza seasoning"],
        itemsPerServing: 1, gramsPerItem: 107)

    static let cupOfCoffeeOrTea = SillyFoodRule(
        keywords: ["coffee", "latte", "cappuccino", "espresso", "americano", "macchiato", "mocha", "cold brew",
                   "flat white", "cortado", "tea", "chai", "matcha"],
        exclusions: ["cake", "cookie", "ice cream", "creamer", "bean", "ground", "tiramisu", "bread", "muffin",
                     "biscuit", "cracker"],
        itemsPerServing: 1, gramsPerItem: 240)

    private static func cookie(
        _ kind: SillyCookieRule.Kind, _ keywords: [String], value: Double, perServing: Double, grams: Double
    ) -> SillyCookieRule {
        SillyCookieRule(
            kind: kind,
            food: SillyFoodRule(keywords: keywords, exclusions: cookieExclusions, itemsPerServing: perServing, gramsPerItem: grams),
            value: value)
    }

    // MARK: - Counting

    /// Cookie-equivalents in one meal: a homemade cookie counts one, anything else counts its
    /// cookies times its row of the cookie table.
    static func cookieEquivalents(in meal: Meal) -> Double {
        if meal.mealSource == .recipe {
            return cookieRule(matching: meal.name) == nil ? 0 : homemadeCookieValue
        }
        var total = 0.0
        for component in meal.componentSnapshots {
            guard let rule = cookieRule(matching: component.name) else { continue }
            total += items(in: component, rule: rule.food) * rule.value
        }
        if total > 0 { return min(total, maxItemsPerMeal) }
        guard let rule = cookieRule(matching: meal.name) else { return 0 }
        return min(nameQuantity(meal.name, rule: rule.food) * rule.value, maxItemsPerMeal)
    }

    /// Items of `rule`'s food in one meal: matching components first, then the meal's own name.
    static func items(of rule: SillyFoodRule, in meal: Meal) -> Double {
        var total = 0.0
        for component in meal.componentSnapshots where matches(rule, name: component.name) {
            total += items(in: component, rule: rule)
        }
        if total > 0 { return min(total, maxItemsPerMeal) }
        guard matches(rule, name: meal.name) else { return 0 }
        return min(nameQuantity(meal.name, rule: rule), maxItemsPerMeal)
    }

    /// The first row of the cookie table whose food matches `name`.
    static func cookieRule(matching name: String) -> SillyCookieRule? {
        cookieTable.first { matches($0.food, name: name) }
    }

    /// Whether `name` names `rule`'s food and none of its exclusions.
    static func matches(_ rule: SillyFoodRule, name: String) -> Bool {
        let words = normalizedWords(name)
        guard !words.isEmpty else { return false }
        let padded = " " + words.joined(separator: " ") + " "
        if rule.exclusions.contains(where: { padded.contains(" \($0) ") }) { return false }
        return rule.keywords.contains { padded.contains(" \($0) ") }
    }

    /// Lowercased letter-and-digit words with a plain plural `s` dropped, so "Oreos" reads "oreo"
    /// and "Do-si-dos" reads "do si dos".
    static func normalizedWords(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let words = lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.map { word in
            guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return word }
            return String(word.dropLast())
        }
    }

    /// Items in one logged component: by weight when it was weighed, by servings when it was
    /// served, and as a plain count for any other unit ("2 cookie", "1 slice", "3 large").
    static func items(in component: MealComponentSnapshot, rule: SillyFoodRule) -> Double {
        let quantity = component.quantity
        guard quantity.isFinite, quantity > 0, rule.gramsPerItem > 0 else { return 0 }
        switch component.unit.lowercased().trimmingCharacters(in: .whitespaces) {
        case "g", "gram", "grams", "ml", "milliliter", "milliliters":
            return quantity / rule.gramsPerItem
        case "kg", "kilogram", "kilograms", "l", "liter", "liters":
            return quantity * 1_000 / rule.gramsPerItem
        case "oz", "ounce", "ounces", "fl oz":
            return quantity * 28.349523125 / rule.gramsPerItem
        case "lb", "lbs", "pound", "pounds":
            return quantity * 453.59237 / rule.gramsPerItem
        case "serving", "servings":
            return quantity * rule.itemsPerServing
        default:
            return quantity
        }
    }

    /// A leading number in a meal's name ("2 bananas", "1.5 cookies"), or one serving.
    static func nameQuantity(_ name: String, rule: SillyFoodRule) -> Double {
        let first = name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard let number = LocaleTolerantNumber.double(from: first), number.isFinite, number > 0 else {
            return rule.itemsPerServing
        }
        return min(number, maxNameQuantity)
    }
}
