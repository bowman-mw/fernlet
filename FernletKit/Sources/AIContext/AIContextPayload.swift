import Foundation
import FernletDomainModel

// MARK: - Payload protocol

/// Marker protocol for all AI context payloads — the de-identification contract.
///
/// Each conforming type defines the exact fields that may enter an AI prompt; anything not expressed
/// in a payload type cannot reach the model. This is the S3 wall's sanctioned-egress mechanism in
/// type form: the walled `AIProviders` module (and the app-target AI call sites) consume ONLY these
/// typed payloads, never raw sealed data, and the app builds each payload from already-allowed
/// values. The two requirements feed the audit trail — ``AIAuditLog`` records `payloadKind` and
/// `includedFieldNames` (names, never values) for every call. All conformers are `Sendable` value
/// types, safe to carry across the actor hop into a model session.
public protocol AIContextPayload: Sendable {
    /// Stable kind token for this payload family (e.g. `"companion-thought"`), recorded in the audit
    /// log and matched against `MemoryAgent.allowedPayloadKinds`.
    ///
    /// **DO NOT LOCALIZE ANY `payloadKind` LITERAL IN THIS FILE.** These hyphenated lowercase
    /// strings are tokens with two consumers, neither of which is a screen: `AIAuditLog` persists
    /// them as the audit trail's key (so a translated value orphans every historical row for that
    /// family), and `MemoryAgent.filteredContext` compares them by exact equality against
    /// `allowedPayloadKinds` — a fail-closed privacy gate whose miss path is `return ""`, with no
    /// throw and no log. Localizing `"companion-thought"` on either side of that comparison does
    /// not break the build or the prompt; it silently and permanently strips the user's behavioral
    /// memory from every companion thought, which surfaces only as "the AI got worse in Spanish".
    /// If a payload kind ever needs a human-readable name, add a separate `displayName` property —
    /// never translate the token.
    var payloadKind: String { get }
    /// The NAMES of the fields this payload carries — what the audit log stores; never the values.
    var includedFieldNames: [String] { get }
}

// MARK: - Food selection payload

/// Fields allowed for food-selection inference.
///
/// Built by the app's `MealResolutionService` and consumed by `AIProviders`' food-selection provider:
/// the model picks the best catalog candidates for a described meal.
/// Forbidden: journal text, period data, health metrics, TierTwo memories, narratives.
public struct FoodSelectionPayload: AIContextPayload {
    /// Frozen English token — **DO NOT LOCALIZE**. Audit-log key and `MemoryAgent` gate input;
    /// never rendered. See ``AIContextPayload/payloadKind``.
    public let payloadKind = "food-selection"
    /// The user's free-text meal description — the only user prose this payload carries.
    public let mealDescription: String
    /// The catalog candidates the model may choose among; it never invents foods outside this list.
    public let candidates: [FoodSelectionCandidate]
    /// Meal slot to assume when the description does not imply one.
    public let fallbackMealType: MealType?

    public var includedFieldNames: [String] { ["mealDescription", "candidates", "fallbackMealType"] }

    public init(mealDescription: String, candidates: [FoodSelectionCandidate], fallbackMealType: MealType?) {
        self.mealDescription = mealDescription
        self.candidates = candidates
        self.fallbackMealType = fallbackMealType
    }
}

// MARK: - Meal decomposition payload

/// Fields allowed for AI dish decomposition (M1).
///
/// Built by the app's `MealResolutionService` when a described dish must be split into component
/// foods before candidate matching. Sends strictly less than ``FoodSelectionPayload`` — no candidate
/// list required.
public struct MealDecompositionPayload: AIContextPayload {
    /// Frozen English token — **DO NOT LOCALIZE**. Audit-log key and `MemoryAgent` gate input;
    /// never rendered. See ``AIContextPayload/payloadKind``.
    public let payloadKind = "meal-decomposition"
    public let mealDescription: String
    public let fallbackMealType: MealType?

    public var includedFieldNames: [String] { ["mealDescription", "fallbackMealType"] }

    public init(mealDescription: String, fallbackMealType: MealType?) {
        self.mealDescription = mealDescription
        self.fallbackMealType = fallbackMealType
    }
}

// MARK: - Web nutrition payload

/// Fields allowed for web nutrition lookup.
///
/// The one payload whose destination LEAVES the device today: the meal description is sent to a
/// search provider, so this path requires explicit first-use consent and is audited at DISPATCH time (see
/// ``AIAuditLog``'s dispatch-then-update contract). Built by the app's food view flow.
public struct WebNutritionLookupPayload: AIContextPayload {
    /// Frozen English token — **DO NOT LOCALIZE**. Audit-log key and `MemoryAgent` gate input;
    /// never rendered. See ``AIContextPayload/payloadKind``.
    public let payloadKind = "web-nutrition"
    public let mealDescription: String

    public var includedFieldNames: [String] { ["mealDescription"] }

    public init(mealDescription: String) {
        self.mealDescription = mealDescription
    }
}

// MARK: - Day summary payload

/// Fields allowed for day-summary generation.
///
/// Built by the app's `LaunchPreparationService` for the ambient day-summary task — names and labels
/// only. Forbidden: journal text, period data, TierTwo memories, symptom flags, narratives.
///
/// The two name lists are EXTERNALLY AUTHORED — a recipe name can come from a scraped web page or a
/// peer's mesh share, a workout name from a pasted coach plan — and they are interpolated into a
/// free-text prompt. Sanitizing in `init` rather than at the call site makes that unbypassable: a
/// name can no longer carry a line break and forge a prompt section, nor run unbounded.
public struct DaySummaryPayload: AIContextPayload {
    /// Frozen English token — **DO NOT LOCALIZE**. Audit-log key and `MemoryAgent` gate input;
    /// never rendered. See ``AIContextPayload/payloadKind``.
    public let payloadKind = "day-summary"
    public let mealNames: [String]
    public let workoutNames: [String]
    public let sleepQualityLabel: String?
    public let sleepHours: Double?
    /// Tag label only (e.g. "Good", "Hard") — never the journal entry text.
    public let journalTagLabel: String?

    public var includedFieldNames: [String] {
        ["mealNames", "workoutNames", "sleepQualityLabel", "sleepHours", "journalTagLabel"]
    }


    public init(
        mealNames: [String],
        workoutNames: [String],
        sleepQualityLabel: String?,
        sleepHours: Double?,
        journalTagLabel: String?
    ) {
        // Sleep/journal labels are app-generated enum labels and stay verbatim; only these two
        // lists carry externally authored text.
        //
        // Those two labels are the double-duty risk in this type: `sleepQualityLabel` and
        // `journalTagLabel` are today the same strings the UI shows ("Good", "Hard"), and they are
        // interpolated straight into a free-text prompt. If the display side of those enums is ever
        // localized, the caller must pass the enum's rawValue here instead — the prompt vocabulary
        // has to stay one stable language, or the model's grounding shifts per device locale with
        // no error and no test failure. Callers live in the app target, so this file cannot enforce
        // it; the invariant is "whatever reaches these two parameters is a token, not UI copy".
        self.mealNames = mealNames.map {
            ItemNameModeration.sanitizedName($0, maxLength: AIPromptTextLimits.maxNameCharacters)
        }
        self.workoutNames = workoutNames.map {
            ItemNameModeration.sanitizedName($0, maxLength: AIPromptTextLimits.maxNameCharacters)
        }
        self.sleepQualityLabel = sleepQualityLabel
        self.sleepHours = sleepHours
        self.journalTagLabel = journalTagLabel
    }
}

// MARK: - Companion thought payload

/// A single derived-signal item — name and trend value only; no raw health samples.
///
/// The line-item form derived wellbeing signals take inside ``CompanionThoughtPayload``, keeping the
/// prompt at the abstraction level of "sleep: trending up" rather than clinical numbers.
public struct AISignalSummary: Equatable, Sendable {
    /// The signal's display name (e.g. "sleep").
    public let signalName: String
    /// The already-abstracted trend/value string; never a raw HealthKit sample.
    public let value: String

    public init(signalName: String, value: String) {
        self.signalName = signalName
        self.value = value
    }
}

/// Fields allowed for companion-thought generation.
///
/// Built by the app's `LaunchPreparationService` for the ambient thought-bubble task — the only
/// payload kind allowed any TierTwo behavioral context, and only after ``MemoryAgent`` filtering.
/// Forbidden: journal text, period data, raw narratives, raw TierTwo records.
/// `filteredMemorySummary` MUST be the output of ``MemoryAgent/filteredContext(from:destinedFor:recencyDays:maxChars:)``
/// — never a raw `tierTwoContextSummary` call.
public struct CompanionThoughtPayload: AIContextPayload {
    /// Frozen English token — **DO NOT LOCALIZE**. This is the ONE value in
    /// `MemoryAgent.allowedPayloadKinds`, so it is the single string standing between the
    /// user's TierTwo behavioral memory and the prompt. Translate it and the gate stops
    /// matching, `filteredContext` returns "" forever, and nothing throws or logs.
    /// See ``AIContextPayload/payloadKind``.
    public let payloadKind = "companion-thought"
    public let signalSummaries: [AISignalSummary]
    /// Tag label only — never journal entry text.
    public let journalTagLabel: String?
    /// Pre-filtered, character-capped context produced by MemoryAgent.
    public let filteredMemorySummary: String

    public var includedFieldNames: [String] {
        ["signalSummaries", "journalTagLabel", "filteredMemorySummary"]
    }

    public init(signalSummaries: [AISignalSummary], journalTagLabel: String?, filteredMemorySummary: String) {
        self.signalSummaries = signalSummaries
        self.journalTagLabel = journalTagLabel
        self.filteredMemorySummary = filteredMemorySummary
    }
}

// MARK: - Workout adjustment payload

/// Fields allowed for on-device workout-session adjustment.
///
/// Built by the app's `WorkoutPlanningService` and consumed by `AIProviders`' workout-adjustment
/// provider when the user asks to tweak a session in free text.
/// Forbidden: journal text, period data, health metrics, narratives. Only the session's exercise
/// names, the user's free-text request, and how many catalog candidates were offered are sent.
public struct WorkoutAdjustmentPayload: AIContextPayload {
    /// Frozen English token — **DO NOT LOCALIZE**. Audit-log key and `MemoryAgent` gate input;
    /// never rendered. See ``AIContextPayload/payloadKind``.
    public let payloadKind = "workout-adjustment"
    public let request: String
    public let currentExercises: [String]
    public let candidateCount: Int

    public var includedFieldNames: [String] { ["request", "currentExercises", "candidateCount"] }

    public init(request: String, currentExercises: [String], candidateCount: Int) {
        self.request = request
        self.currentExercises = currentExercises
        self.candidateCount = candidateCount
    }
}

// MARK: - Ingredient substitution payload

/// Fields allowed for AI ingredient substitution (F4, decision §11.4).
///
/// Forbidden: journal text, period data, health metrics, TierTwo memories, narratives, and any user
/// free-text beyond the two NAMES below. Only dish/ingredient names cross:
/// - `recipeName` — the recipe's own title (a dish name), for world-knowledge context ("what pairs
///   with a carbonara").
/// - `ingredientToReplace` — the NAME of the catalog food being swapped out (e.g. "butter"). Not a
///   quantity, not a macro, not user prose.
///
/// The model contributes WORLD KNOWLEDGE — it proposes substitute food *names* from general culinary
/// knowledge ("butter → olive oil"), which the catalog has no taxonomy to derive (§5.2). No local
/// candidate pool is sent: the caller rebinds each proposed name through `FoodCatalog.candidates(for:)`
/// and binds the resolved food (with its macros) in code — the model never emits a food it invented, a
/// quantity, or a macro. Sending only two dish/ingredient names also keeps the payload genuinely
/// names-only.
///
/// This payload is deliberately NOT in ``MemoryAgent/allowedPayloadKinds``: a substitution prompt must
/// receive zero TierTwo behavioral context — it needs only names — so `MemoryAgent.filteredContext`
/// returns an empty string for `"ingredient-substitution"` by default (fail-closed).
public struct IngredientSubstitutionPayload: AIContextPayload {
    /// Frozen English token — **DO NOT LOCALIZE**. Audit-log key and `MemoryAgent` gate input;
    /// never rendered. See ``AIContextPayload/payloadKind``.
    public let payloadKind = "ingredient-substitution"
    public let recipeName: String
    public let ingredientToReplace: String

    public var includedFieldNames: [String] { ["recipeName", "ingredientToReplace"] }

    /// Both fields are EXTERNALLY AUTHORED — they come from an imported recipe, which may have been
    /// scraped from a web page or shared by a mesh peer — and each is interpolated onto its own line
    /// of a labelled prompt (`Recipe:` / `Replace this ingredient:`). Sanitizing in `init` is what
    /// stops a newline inside a name from forging the other line, and is unbypassable at the call site.
    public init(recipeName: String, ingredientToReplace: String) {
        self.recipeName = ItemNameModeration.sanitizedName(
            recipeName, maxLength: AIPromptTextLimits.maxNameCharacters)
        self.ingredientToReplace = ItemNameModeration.sanitizedName(
            ingredientToReplace, maxLength: AIPromptTextLimits.maxNameCharacters)
    }
}

// MARK: - Web page extraction payloads

/// Shared bounds for externally authored text that reaches an on-device model prompt.
///
/// One source of truth so the payload types cannot drift apart: a name that is safe to interpolate
/// into a labelled, newline-delimited prompt is the same shape whether it came from a meal, a
/// workout session, or a recipe being substituted into.
public enum AIPromptTextLimits {
    /// Per-name cap for prompt use. Far above a real recipe, session or ingredient title, but a
    /// bound: a 200 KB "name" is not a name. Prompt-only — the stored name is never changed.
    public static let maxNameCharacters = 80
}

/// Fields allowed for on-device nutrition extraction from a product webpage.
///
/// Built by the app's `FoodProductWebImporter` when the on-device model reads an already-fetched
/// product page. Only the source host and approximate text length are recorded; page content is
/// never logged.
public struct WebPageNutritionExtractionPayload: AIContextPayload {
    /// Frozen English token — **DO NOT LOCALIZE**. Audit-log key and `MemoryAgent` gate input;
    /// never rendered. See ``AIContextPayload/payloadKind``.
    public let payloadKind = "web-nutrition-extraction"
    public let sourceHost: String
    public let cleanedTextCharCount: Int

    public var includedFieldNames: [String] { ["sourceHost", "cleanedTextCharCount"] }

    public init(sourceHost: String, cleanedTextCharCount: Int) {
        self.sourceHost = sourceHost
        self.cleanedTextCharCount = cleanedTextCharCount
    }
}

/// Fields allowed for on-device recipe extraction from a webpage.
///
/// Built by `AIProviders`' `RecipeWebImporter` when the on-device model parses an already-fetched
/// recipe page. Only the source host and approximate text length are recorded; page content is
/// never logged.
public struct RecipeExtractionPayload: AIContextPayload {
    /// Frozen English token — **DO NOT LOCALIZE**. Audit-log key and `MemoryAgent` gate input;
    /// never rendered. See ``AIContextPayload/payloadKind``.
    public let payloadKind = "recipe-extraction"
    public let sourceHost: String
    public let cleanedTextCharCount: Int

    public var includedFieldNames: [String] { ["sourceHost", "cleanedTextCharCount"] }

    public init(sourceHost: String, cleanedTextCharCount: Int) {
        self.sourceHost = sourceHost
        self.cleanedTextCharCount = cleanedTextCharCount
    }
}
