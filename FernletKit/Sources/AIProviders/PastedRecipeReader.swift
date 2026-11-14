// PastedRecipeReader.swift
// AIProviders
//
// AI recipe paste-and-parse (roadmap G1, Phase P4a; owner-approved design 2026-11-13). A person pastes
// recipe text; the on-device model reads it into a name, servings, ingredient lines (amount, unit,
// food) and steps — never a nutrition number. Each ingredient then binds in CODE through the same
// line parser and `FoodCatalog` machine-generated search the web importer uses, so a pasted recipe's
// nutrition is always catalog values. The person reviews every row in the manual recipe editor before
// anything is saved: a confident bind is an ordinary row, a low-confidence bind is bound and marked
// "Check this match", and a line nothing matched stays unbound with its food typed into the search.
//
// With AI off, resting, or failing, the text is read line by line instead (``PastedRecipeReader/readLineByLine(_:languages:)``),
// and the draft says so (``PastedRecipeDraft/Reader/lineByLine``).

import Foundation
import AIContext
import FernletDomainModel
import FoodCatalog
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One ingredient line read from pasted text: the line as written, and the amount, unit and food the
/// reader found in it. `quantity` and `unit` are nil when the line states no amount ("salt to taste").
public nonisolated struct PastedIngredientLine: Equatable, Sendable {
    /// The line as the person pasted it (trimmed, bullet removed) — shown beside a row to check.
    public var original: String
    /// The amount, or nil when the line gives none.
    public var quantity: Double?
    /// The `RecipeUnit` token (or "each"/"serving") the amount binds, or nil with no amount.
    public var unit: String?
    /// The food name the catalog is searched for.
    public var food: String

    public init(original: String, quantity: Double?, unit: String?, food: String) {
        self.original = original
        self.quantity = quantity
        self.unit = unit
        self.food = food
    }
}

/// What a pasted recipe reads as, before any binding: everything the editor is pre-filled with.
public nonisolated struct PastedRecipeDraft: Equatable, Sendable {
    /// Who read the text.
    public enum Reader: Equatable, Sendable {
        /// The on-device model.
        case model
        /// The line-by-line reader: AI is off, resting or failed, so the name and steps may need fixing.
        case lineByLine
    }

    public var name: String
    public var servings: Int
    public var ingredients: [PastedIngredientLine]
    public var steps: [String]
    public var reader: Reader
    /// Prose the line-by-line reader found before the first ingredient (a recipe's description); it
    /// pre-fills the editor's notes. Empty from the model.
    public var notes: String
    /// Whether the pasted text was longer than ``PastedRecipeReader/maxPastedCharacters`` and cut.
    public var wasShortened: Bool

    public init(
        name: String, servings: Int, ingredients: [PastedIngredientLine], steps: [String],
        reader: Reader, notes: String = "", wasShortened: Bool = false
    ) {
        self.name = name
        self.servings = servings
        self.ingredients = ingredients
        self.steps = steps
        self.reader = reader
        self.notes = notes
        self.wasShortened = wasShortened
    }
}

/// How one pasted ingredient bound to the catalog.
public nonisolated enum PastedIngredientMatch: Equatable, Sendable {
    /// A confident bind: an ordinary editor row.
    case confident
    /// Bound, but the person should look: a weak name match, an amount weighed only by a USDA typical
    /// size, or an amount the bound food cannot weigh.
    case check
    /// Nothing bound: the row is left unbound with its food typed into the search.
    case noMatch
}

/// One editor row seeded from a pasted line, with how it bound.
public nonisolated struct PastedIngredientRow: Equatable {
    /// The editor row: bound to `selectedFoodItemId` for a match, unbound with `name` for none.
    public let input: ManualRecipeIngredientInput
    /// How the line bound.
    public let match: PastedIngredientMatch
    /// The line as pasted, for the "Check this match" note.
    public let original: String
}

/// Reads pasted recipe text and binds its ingredients. See the file header.
public enum PastedRecipeReader {
    /// The longest pasted text read (spec: `aiParseRecipe` takes up to 4000 characters); longer text is
    /// cut there and the draft says so.
    nonisolated public static let maxPastedCharacters = 4_000

    // MARK: - Reading

    /// Reads `text`: with the on-device model when `aiEnabled` and the gate allows a user-invoked
    /// standard-tier call, else (or when the model fails or finds no ingredient) line by line. Returns
    /// nil only when neither reader finds a single ingredient line.
    public static func read(
        _ text: String, aiEnabled: Bool, gate: FernletAIGate,
        promptLanguage: AIPromptLanguage = .english, languages: InputLanguages = .current
    ) async -> PastedRecipeDraft? {
        let (bounded, wasShortened) = boundedText(text)
        guard !bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if aiEnabled, var draft = await readWithModel(bounded, gate: gate, promptLanguage: promptLanguage, languages: languages) {
            draft.wasShortened = wasShortened
            return draft
        }
        guard var draft = readLineByLine(bounded, languages: languages) else { return nil }
        draft.wasShortened = wasShortened
        return draft
    }

    /// `text` cut to ``maxPastedCharacters``, and whether it was cut.
    nonisolated static func boundedText(_ text: String) -> (String, Bool) {
        guard text.count > maxPastedCharacters else { return (text, false) }
        return (String(text.prefix(maxPastedCharacters)), true)
    }

    /// The model's reading, or nil when the gate falls back, the model throws, or it finds no
    /// ingredient. Every dispatched call is recorded in `AIAuditLog` with the character count only.
    static func readWithModel(
        _ text: String, gate: FernletAIGate, promptLanguage: AIPromptLanguage, languages: InputLanguages
    ) async -> PastedRecipeDraft? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            guard let destination = gate.dispatch(tier: .standard, userInvoked: true) else { return nil }
            let payload = RecipeTextParsePayload(pastedTextCharCount: text.count, promptLanguage: promptLanguage)
            let session = LanguageModelSession(instructions: instructions(for: promptLanguage))
            do {
                let response = try await session.respond(to: "Recipe text:\n\(text)", generating: PastedRecipeResponse.self)
                let draft = response.content.draft(languages: languages)
                await AIAuditLog.shared.record(
                    payloadKind: payload.payloadKind, destination: destination,
                    modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                    includedFields: payload.includedFieldNames,
                    outcome: draft == nil ? .fellBack : .succeeded
                )
                return draft
            } catch {
                await AIAuditLog.shared.record(
                    payloadKind: payload.payloadKind, destination: destination,
                    modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                    includedFields: payload.includedFieldNames,
                    outcome: AIAuditOutcome.fromModelError(error)
                )
                return nil
            }
        }
        #endif
        return nil
    }

    /// The model's instructions: read, never estimate. Food names stay English (code searches the
    /// English catalog); the name and steps stay in the language they were pasted in.
    nonisolated static func instructions(for promptLanguage: AIPromptLanguage) -> String {
        AIPromptLanguage.joined(
            """
            You read one cooking recipe that a person pasted as plain text.
            Give the recipe's name, how many servings it makes (1 when the text does not say), every \
            ingredient, and the cooking steps in order.
            For each ingredient give the line exactly as written, its amount as written (such as 2, \
            1 1/2 or 3/4; empty when there is none), its unit (such as cup, tbsp, g or clove; empty when \
            there is none), and the plain grocery-store name of the food without preparation words \
            (for "2 cloves garlic, minced" the food is garlic).
            Do not output nutrition, calories or any number the text does not state. Do not invent \
            ingredients or steps.
            """,
            promptLanguage.inputInstruction(
                keepingEnglish: "each food name", writingInLanguage: "the recipe name and the steps as the text writes them"
            )
        )
    }

    // MARK: - Line-by-line reader

    /// Section headings, FROZEN matching inputs compared folded and without a trailing colon. Not display
    /// copy — they are the words recipe text arrives with.
    nonisolated static let ingredientHeadings: Set<String> = ["ingredients", "ingredientes"]
    nonisolated static let stepHeadings: Set<String> = [
        "instructions", "directions", "method", "steps", "preparation",
        "instrucciones", "preparacion", "elaboracion", "pasos", "modo de preparacion"
    ]
    /// Words a servings line opens with ("Serves 4", "Makes 12", "Raciones: 4"). FROZEN matching inputs.
    nonisolated static let servingWords: [String] = [
        "serves", "servings", "serving", "makes", "yield", "yields",
        "raciones", "porciones", "rinde", "para"
    ]

    /// Most description lines kept as notes, and their characters.
    nonisolated static let maxNoteLines = 6
    nonisolated static let maxNoteCharacters = 1_000

    /// Most lines read (R2): the text is already capped at ``maxPastedCharacters``.
    nonisolated static let maxLinesRead = 400

    /// Reads `text` without the model: the first plain line is the name; a servings line sets the
    /// servings; a line that opens with an amount, or any line under an ingredients heading, is an
    /// ingredient; every other line after the first ingredient (or under a steps heading) is a step,
    /// and prose before it is the notes. Nil when no ingredient line is found.
    nonisolated public static func readLineByLine(_ text: String, languages: InputLanguages = .current) -> PastedRecipeDraft? {
        enum Section { case none, ingredients, steps }
        var section = Section.none
        var name = ""
        var servings = 1
        var ingredients: [PastedIngredientLine] = []
        var steps: [String] = []
        var notes: [String] = []
        let lines = text.split(whereSeparator: \.isNewline).prefix(maxLinesRead)
        for raw in lines {
            let line = strippedBullet(String(raw))
            guard !line.isEmpty else { continue }
            let folded = LanguagePack.folded(line.lowercased()).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            if ingredientHeadings.contains(folded) { section = .ingredients; continue }
            if stepHeadings.contains(folded) { section = .steps; continue }
            if let count = servingsCount(in: folded) { servings = count; continue }
            if let stepText = numberedStep(line) {
                steps.append(stepText)
                section = .steps
                continue
            }
            if section != .steps, let parsed = RecipeWebImporter.parseIngredientLine(line, languages: languages) {
                ingredients.append(PastedIngredientLine(
                    original: line, quantity: parsed.quantity, unit: parsed.unit, food: parsed.name))
                if section == .none { section = .ingredients }
                continue
            }
            if section == .ingredients, RecipeWebImporter.startsWithAmount(line),
               ingredients.count < RecipeWebImporter.maxImportedIngredients {
                // An amount the parser cannot read past ("2 pinches salt"): kept as a line to pick a food for.
                let original = String(line.prefix(RecipeWebImporter.maxImportedIngredientLineCharacters))
                ingredients.append(PastedIngredientLine(original: original, quantity: nil, unit: nil, food: original))
                continue
            }
            if name.isEmpty && section == .none {
                name = String(line.prefix(RecipeWebImporter.maxImportedNameCharacters))
                continue
            }
            if section == .ingredients, !line.hasSuffix(":"), !RecipeWebImporter.startsWithAmount(line),
               line.count <= RecipeWebImporter.maxImportedIngredientLineCharacters,
               ingredients.count < RecipeWebImporter.maxImportedIngredients,
               looksLikeIngredient(line) {
                ingredients.append(PastedIngredientLine(original: line, quantity: nil, unit: nil, food: unamountedFood(line)))
                continue
            }
            if line.hasSuffix(":") { continue }
            if section == .none {
                // Before any ingredient or heading: the recipe's description, not a step.
                if notes.count < maxNoteLines { notes.append(line) }
                continue
            }
            steps.append(String(line.prefix(RecipeWebImporter.maxImportedStepTextCharacters)))
        }
        guard !ingredients.isEmpty else { return nil }
        return PastedRecipeDraft(
            name: name, servings: servings,
            ingredients: Array(ingredients.prefix(RecipeWebImporter.maxImportedIngredients)),
            steps: Array(steps.prefix(RecipeWebImporter.maxImportedSteps)),
            reader: .lineByLine,
            notes: String(notes.joined(separator: "\n").prefix(maxNoteCharacters))
        )
    }

    /// `line` trimmed, without a leading bullet ("-", "•", "*", "▢", "□", "·").
    nonisolated static func strippedBullet(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        // R2: a bullet is a mark or two; stop after a few.
        for _ in 0..<4 {
            guard let first = s.first, "-•*▢□·–".contains(first) else { break }
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// The servings a line states ("serves 4", "makes 12 cookies", "servings: 6", "para 4 personas"),
    /// clamped into the importer's range, or nil when the line is not a servings line.
    nonisolated static func servingsCount(in foldedLine: String) -> Int? {
        guard let word = servingWords.first(where: { foldedLine == $0 || foldedLine.hasPrefix($0 + " ") || foldedLine.hasPrefix($0 + ":") }),
              foldedLine.count <= 40 else { return nil }
        let rest = foldedLine.dropFirst(word.count)
        guard let digits = rest.split(whereSeparator: { !$0.isNumber }).first, let count = Int(digits) else { return nil }
        return min(max(count, 1), RecipeWebImporter.maxImportedServings)
    }

    /// A numbered step's text ("1. Heat the oven", "2) Stir") or nil. A number then a period or a
    /// parenthesis then a space marks a step, never an amount ("1 cup").
    nonisolated static func numberedStep(_ line: String) -> String? {
        guard let range = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) else { return nil }
        let text = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !RecipeWebImporter.startsWithAmount(text) else { return nil }
        return String(text.prefix(RecipeWebImporter.maxImportedStepTextCharacters))
    }

    /// Whether an amount-less line under an ingredients heading reads as one ("salt to taste") rather
    /// than a sentence: at most eight words and no sentence end.
    nonisolated static func looksLikeIngredient(_ line: String) -> Bool {
        line.split(separator: " ").count <= 8 && !line.hasSuffix(".")
    }

    /// The food an amount-less line names: no parenthetical, nothing after a comma, no "to taste".
    nonisolated static func unamountedFood(_ line: String) -> String {
        var s = line.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        if let comma = s.range(of: ",") { s = String(s[s.startIndex..<comma.lowerBound]) }
        for tail in [" to taste", " for serving", " as needed", " al gusto", " para servir"] where s.lowercased().hasSuffix(tail) {
            s = String(s.dropLast(tail.count))
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Binding

    /// Binds every line in `draft` to an editor row (one catalog search per line; the draft is capped at
    /// `RecipeWebImporter.maxImportedIngredients` lines).
    nonisolated public static func rows(for draft: PastedRecipeDraft, catalog: FoodCatalog) -> [PastedIngredientRow] {
        draft.ingredients.prefix(RecipeWebImporter.maxImportedIngredients).map { bind($0, catalog: catalog) }
    }

    /// One line's editor row.
    ///
    /// The amount is read by the importer's own line parser (``RecipeWebImporter/parseIngredientLine(_:languages:)``)
    /// so a count word, a bare count and a stated unit mean what they mean on a web import. The food
    /// binds the catalog's first `.machineGenerated` row in the recipe editor's ingredient-identity order
    /// — the row the editor's own search would show first for those words. Confident only when the
    /// amount converts on that row's own data AND the row clears the meal-review rule
    /// (`FoodItemSearch.confidentBindScore`, and its name states the food as words); a typical size or
    /// an amount the row cannot weigh is a row to check, and a line with no amount is left unbound.
    nonisolated static func bind(_ line: PastedIngredientLine, catalog: FoodCatalog) -> PastedIngredientRow {
        let food = String(line.food.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RecipeWebImporter.maxImportedIngredientLineCharacters))
        let unbound = PastedIngredientRow(
            input: ManualRecipeIngredientInput(name: food.isEmpty ? line.original : food),
            match: .noMatch, original: line.original)
        guard let parsed = parsedLine(line), parsed.name.count >= FoodItemSearch.minimumQueryLength,
              let match = catalog.results(
                for: parsed.name, limit: 1, context: .machineGenerated, ranking: .ingredientIdentity).first
        else { return unbound }

        let grams = match.exactMacros
        func row(quantity: Double, unit: String, portion: RecipePortionOption?, _ result: PastedIngredientMatch) -> PastedIngredientRow {
            PastedIngredientRow(
                input: ManualRecipeIngredientInput(
                    name: match.name, selectedFoodItemId: match.id, quantity: quantity, unit: unit,
                    protein: grams.protein, carbs: grams.carbs, fat: grams.fat, portion: portion),
                match: result, original: line.original)
        }

        let units = parsed.candidateUnits(on: match)
        for unit in units where RecipeIngredient(foodItemId: match.id, quantity: parsed.quantity, unit: unit)
            .servingConversion(using: match) != nil {
            return row(quantity: parsed.quantity, unit: unit, portion: nil,
                       isConfident(match, query: parsed.name, catalog: catalog) ? .confident : .check)
        }
        for unit in units {
            guard let recipeUnit = RecipeUnit.normalized(unit),
                  let total = TypicalPortionTable.grams(quantity: parsed.quantity, unit: recipeUnit, for: match),
                  parsed.quantity > 0 else { continue }
            let perOne = total / parsed.quantity
            let option = RecipePortionPicker.choices(for: match).options.first {
                $0.source == .typicalSize && abs(($0.gramsPerOne ?? -1) - perOne) <= 0.05
            }
            if let option {
                return row(quantity: parsed.quantity, unit: unit, portion: option, .check)
            }
            return row(quantity: total, unit: RecipeUnit.gram.rawValue, portion: nil, .check)
        }
        // The food bound but cannot weigh this amount: the editor asks what one weighs (Rung E).
        return row(quantity: parsed.quantity, unit: parsed.unit, portion: nil, .check)
    }

    /// `line` as the importer's parser reads it: the model's amount, unit and food recomposed, else the
    /// original line. Nil when neither states an amount.
    nonisolated static func parsedLine(_ line: PastedIngredientLine) -> ParsedIngredientLine? {
        if let quantity = line.quantity, quantity.isFinite, quantity > 0 {
            let amount = quantity == quantity.rounded() ? String(Int(quantity)) : String(quantity)
            let composed = [amount, line.unit ?? "", line.food].filter { !$0.isEmpty }.joined(separator: " ")
            if let parsed = RecipeWebImporter.parseIngredientLine(composed) { return parsed }
        }
        return RecipeWebImporter.parseIngredientLine(line.original)
    }

    /// The meal-review confidence rule on one bind: the row's cold score for `query` reaches
    /// `FoodItemSearch.confidentBindScore` and its name states `query` as words.
    nonisolated static func isConfident(_ item: FoodItem, query: String, catalog: FoodCatalog) -> Bool {
        guard FoodItemSearch.nameStatesQueryAsWords(item.name, query: query),
              let score = catalog.scoredResults(for: query, limit: 25).first(where: { $0.item.id == item.id })?.score
        else { return false }
        return score >= FoodItemSearch.confidentBindScore
    }
}

extension PastedRecipeReader {
    /// One ingredient as the model answered it, in plain strings.
    struct ModelIngredient: Equatable {
        var text: String
        var amount: String
        var unit: String
        var food: String
    }

    /// Trims and caps the model's answer into a draft; nil when it holds no ingredient with a food.
    /// Each amount is read by the importer's own line parser, never trusted as a number.
    nonisolated static func modelDraft(
        name: String, servings: Int, ingredients: [ModelIngredient], steps: [String], languages: InputLanguages
    ) -> PastedRecipeDraft? {
        let lines = ingredients.prefix(RecipeWebImporter.maxImportedIngredients).compactMap { modelLine($0, languages: languages) }
        guard !lines.isEmpty else { return nil }
        let cappedSteps = steps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(RecipeWebImporter.maxImportedSteps)
            .map { String($0.prefix(RecipeWebImporter.maxImportedStepTextCharacters)) }
        return PastedRecipeDraft(
            name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RecipeWebImporter.maxImportedNameCharacters)),
            servings: min(max(servings, 1), RecipeWebImporter.maxImportedServings),
            ingredients: lines, steps: Array(cappedSteps), reader: .model)
    }

    /// One model ingredient as a line; nil without a food.
    nonisolated static func modelLine(_ ingredient: ModelIngredient, languages: InputLanguages) -> PastedIngredientLine? {
        let cap = RecipeWebImporter.maxImportedIngredientLineCharacters
        let original = String(ingredient.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(cap))
        let foodName = String(ingredient.food.trimmingCharacters(in: .whitespacesAndNewlines).prefix(cap))
        guard !foodName.isEmpty else { return nil }
        let composed = [ingredient.amount, ingredient.unit, foodName].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let parsed = RecipeWebImporter.parseIngredientLine(composed, languages: languages)
        return PastedIngredientLine(
            original: original.isEmpty ? composed : original,
            quantity: parsed?.quantity, unit: parsed?.unit, food: parsed?.name ?? foodName)
    }
}

#if canImport(FoundationModels)
/// The `@Generable` schema for pasted recipe text: words only — the model supplies no nutrition.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct PastedRecipeResponse {
    var name: String
    var servings: Int
    var ingredients: [PastedRecipeIngredientResponse]
    var steps: [String]

    func draft(languages: InputLanguages) -> PastedRecipeDraft? {
        PastedRecipeReader.modelDraft(
            name: name, servings: servings,
            ingredients: ingredients.map { .init(text: $0.text, amount: $0.amount, unit: $0.unit, food: $0.food) },
            steps: steps, languages: languages)
    }
}

/// One ingredient as the model read it.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct PastedRecipeIngredientResponse {
    var text: String
    var amount: String
    var unit: String
    var food: String
}
#endif
