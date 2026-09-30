import Foundation
import FernletDomainModel

/// The readable text a recipe is shared as through the system share sheet ("Share as text"): the
/// name, servings, one per-serving macro line, the ingredients (under each part's name for a recipe
/// made in parts), numbered steps, notes and, for a recipe saved from a web page, its source link.
///
/// **Text for people, not for Fernlet (2026-09-30).** Until then the share sheet sent
/// `RecipeShareCodec`'s paste format: a machine-shaped header ("- 80 g Rolled oats (P10 C54 F6)")
/// and a "Fernlet recipe data:" line carrying the recipe's JSON, which Mail, Notes and every chat app
/// showed verbatim — the owner's report. Fernlet-to-Fernlet now travels as a Messages card (the
/// Share screen's "Send in Messages") or over the nearby radio; this text carries no payload, and
/// pasting it into Import recipe finds none. Text an OLDER build shared still imports:
/// `RecipeShareCodec.decodePayload(from:)` reads it unchanged.
///
/// **Localization.** Once nothing parses this text, its labels ("Servings: 4", "Ingredients",
/// "Steps", "Notes", "Source: …", the per-serving line and the step number) are display text, so
/// they are catalogued in `App/Fernlet/Localizable.xcstrings` and rendered in the SENDER's language,
/// with numbers in `locale`. Everything the person or a source wrote stays verbatim: the recipe,
/// part and food names, the notes, the steps, a web page's ingredient lines, and the unit tokens
/// ("g", "cup") the recipe page shows too.
///
/// **What "Include notes" withholds** matches the nearby share
/// (`ProximityRecipeSharePayload.omittingShareNotes()`): for a recipe the person made, the notes AND
/// the steps (step text is free-form and can carry the same personal remarks); for a recipe saved
/// from a web page, only the notes, since its steps came from a public page.
///
/// Pure and bounded: every loop walks a recipe whose sizes `RecipeLimits` caps where it enters.
enum RecipeShareText {

    /// The text for `recipe`.
    ///
    /// - Parameters:
    ///   - foodItems: The catalog rows the recipe's lines are bound to (`FoodCatalog.items(forRecipe:)`).
    ///     A line whose food is missing is left out, exactly as the recipe payload leaves it out.
    ///   - showCalories: The person's "show calories" setting; calories appear only when it is on.
    ///   - includesNotes: The Share screen's "Include notes" switch (see the type's doc comment).
    ///   - locale: The locale numbers and the catalogued labels are rendered in.
    static func text(
        for recipe: RecipeDefinition,
        foodItems: [FoodItem],
        showCalories: Bool,
        includesNotes: Bool,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let style = Style(showCalories: showCalories, locale: locale)
        let blocks: [[String]]
        if let webImport = recipe.webImport {
            blocks = webBlocks(recipe, webImport: webImport, includesNotes: includesNotes, style: style)
        } else {
            blocks = localBlocks(recipe, foodItems: foodItems, includesNotes: includesNotes, style: style)
        }
        return blocks.filter { !$0.isEmpty }
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    /// How the numbers and labels are rendered for one share.
    private struct Style {
        let showCalories: Bool
        let locale: Locale
    }

    // MARK: - A recipe the person made

    private static func localBlocks(
        _ recipe: RecipeDefinition, foodItems: [FoodItem], includesNotes: Bool, style: Style
    ) -> [[String]] {
        let names = Dictionary(foodItems.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let totals = MealBuilder.macroTotals(for: recipe, foodItems: foodItems)
        let perServing = perServingMacros(totals, servings: recipe.servings)
        let parts = recipe.resolvedComponents
        var ingredientParts: [(name: String?, lines: [String])] = []
        for part in parts {
            let lines = part.ingredients.compactMap { ingredient in
                names[ingredient.foodItemId].map { "• \(ingredient.amountText(locale: style.locale)) \($0)" }
            }
            ingredientParts.append((part.name, lines))
        }
        var blocks = [header(recipe, perServing: perServing, uncountedLines: nil, style: style)]
        blocks += section(title: sectionTitle(.ingredients, style), parts: ingredientParts)
        if includesNotes {
            let stepParts = parts.map { part in (name: part.name, lines: numberedSteps(part.steps, style: style)) }
            blocks += section(title: sectionTitle(.steps, style), parts: stepParts)
            blocks.append(notesBlock(recipe.notes, style: style))
        }
        return blocks
    }

    /// Whole-recipe totals divided by the servings, rounded the way the recipe page rounds them.
    private static func perServingMacros(_ totals: MacroTotals, servings: Int) -> MacroTotals {
        let divisor = Double(max(servings, 1))
        return MacroTotals(
            protein: Int((Double(totals.protein) / divisor).rounded()),
            carbs: Int((Double(totals.carbs) / divisor).rounded()),
            fat: Int((Double(totals.fat) / divisor).rounded())
        )
    }

    // MARK: - A recipe saved from a web page

    private static func webBlocks(
        _ recipe: RecipeDefinition, webImport: RecipeWebImport, includesNotes: Bool, style: Style
    ) -> [[String]] {
        let perServing = MacroTotals(protein: webImport.macros.protein, carbs: webImport.macros.carbs,
                                     fat: webImport.macros.fat)
        var blocks = [header(recipe, perServing: perServing,
                             uncountedLines: webImport.uncountedIngredientLines, style: style)]
        let lines = webImport.ingredientLines.map { "• \($0)" }
        blocks += section(title: sectionTitle(.ingredients, style), parts: [(nil, lines)])
        blocks += section(title: sectionTitle(.steps, style),
                          parts: [(nil, numberedSteps(recipe.steps ?? [], style: style))])
        if includesNotes {
            blocks.append(notesBlock(recipe.notes, style: style))
        }
        if let url = webImport.sourceURL, url.isSafariPresentable {
            let link = url.absoluteString
            blocks.append([String(localized: "recipeShareText.source", defaultValue: "Source: \(link)",
                                  locale: style.locale,
                                  comment: "Last line of a recipe shared as text, for a recipe saved from a web page. %@ is the page's address, shown verbatim.")])
        }
        return blocks
    }

    // MARK: - Shared pieces

    /// The name, the servings, the per-serving line (when anything is known) and, for a web
    /// estimate that left lines out, how many — so a partial estimate never reads as a whole one.
    private static func header(
        _ recipe: RecipeDefinition, perServing: MacroTotals, uncountedLines: Int?, style: Style
    ) -> [String] {
        let servings = recipe.servings
        var lines = [
            recipe.name,
            String(localized: "recipeShareText.servings", defaultValue: "Servings: \(servings)",
                   locale: style.locale,
                   comment: "Second line of a recipe shared as text from the recipe's Share screen, e.g. 'Servings: 4'. A label and a number, so no plural form is needed.")
        ]
        guard perServing.protein > 0 || perServing.carbs > 0 || perServing.fat > 0 else { return lines }
        lines.append(perServingLine(perServing, style: style))
        if let uncountedLines, uncountedLines > 0 {
            let note = AttributedString(
                localized: "^[\(uncountedLines) ingredient](inflect: true) not counted in this estimate",
                locale: style.locale
            )
            lines.append(String(note.characters))
        }
        return lines
    }

    private static func perServingLine(_ macros: MacroTotals, style: Style) -> String {
        let protein = macros.protein
        let carbs = macros.carbs
        let fat = macros.fat
        guard style.showCalories else {
            return String(localized: "recipeShareText.perServing",
                          defaultValue: "Per serving: \(protein) g protein, \(carbs) g carbs, \(fat) g fat",
                          locale: style.locale,
                          comment: "A recipe shared as text: its macros for one serving, in grams. The three numbers are protein, carbs and fat. Calories are left out on purpose (the person has calories hidden).")
        }
        let calories = macros.calories
        return String(localized: "recipeShareText.perServingWithCalories",
                      defaultValue: "Per serving: \(calories) cal, \(protein) g protein, \(carbs) g carbs, \(fat) g fat",
                      locale: style.locale,
                      comment: "A recipe shared as text: calories and macros for one serving. The first number is calories ('cal', as the app writes it elsewhere), then grams of protein, carbs and fat.")
    }

    /// A titled section: the title line, then each part's lines — under the part's name, after a
    /// blank line, for a recipe made in parts. Empty when no part has a line.
    private static func section(title: String, parts: [(name: String?, lines: [String])]) -> [[String]] {
        let filled = parts.filter { !$0.lines.isEmpty }
        guard !filled.isEmpty else { return [] }
        guard filled.count > 1 || filled.first?.name != nil else { return [[title] + (filled.first?.lines ?? [])] }
        return [[title]] + filled.map { part in [part.name].compactMap { $0 } + part.lines }
    }

    /// "1. Whisk the dressing.", numbered from 1 within the list it is given.
    private static func numberedSteps(_ steps: [RecipeStep], style: Style) -> [String] {
        let texts = steps.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return texts.enumerated().map { index, text in
            let number = index + 1
            return String(localized: "recipeShareText.step", defaultValue: "\(number). \(text)",
                          locale: style.locale,
                          comment: "One numbered cooking step in a recipe shared as text, e.g. '2. Whisk the dressing.'. The number comes first; the %@ is the person's own step text, shown verbatim. Keep or change the punctuation after the number to suit this language's numbered lists.")
        }
    }

    private static func notesBlock(_ notes: String, style: Style) -> [String] {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [sectionTitle(.notes, style), trimmed]
    }

    /// The three section headings of a recipe shared as text.
    private enum SectionTitle {
        case ingredients, steps, notes
    }

    private static func sectionTitle(_ title: SectionTitle, _ style: Style) -> String {
        switch title {
        case .ingredients:
            String(localized: "recipeShareText.ingredients", defaultValue: "Ingredients", locale: style.locale,
                   comment: "Heading above the ingredient list in a recipe shared as text.")
        case .steps:
            String(localized: "recipeShareText.steps", defaultValue: "Steps", locale: style.locale,
                   comment: "Heading above the numbered cooking steps in a recipe shared as text.")
        case .notes:
            String(localized: "recipeShareText.notes", defaultValue: "Notes", locale: style.locale,
                   comment: "Heading above the person's own notes in a recipe shared as text.")
        }
    }
}
