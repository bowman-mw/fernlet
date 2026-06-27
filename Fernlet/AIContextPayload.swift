import Foundation
import FernletDomainModel

// MARK: - Payload protocol

/// Marker protocol for all AI context payloads.
/// Each conforming type defines the exact fields that may enter an AI prompt.
/// Anything not expressed in a payload type cannot reach the model.
protocol AIContextPayload: Sendable {
    var payloadKind: String { get }
    var includedFieldNames: [String] { get }
}

// MARK: - Food selection payload

/// Fields allowed for food-selection inference.
/// Forbidden: journal text, period data, health metrics, TierTwo memories, narratives.
struct FoodSelectionPayload: AIContextPayload {
    let payloadKind = "food-selection"
    let mealDescription: String
    let candidates: [FoodSelectionCandidate]
    let fallbackMealType: MealType?

    var includedFieldNames: [String] { ["mealDescription", "candidates", "fallbackMealType"] }
}

// MARK: - Meal decomposition payload

/// Fields allowed for AI dish decomposition (M1).
/// Sends strictly less than FoodSelectionPayload — no candidate list required.
struct MealDecompositionPayload: AIContextPayload {
    let payloadKind = "meal-decomposition"
    let mealDescription: String
    let fallbackMealType: MealType?

    var includedFieldNames: [String] { ["mealDescription", "fallbackMealType"] }
}

// MARK: - Web nutrition payload

/// Fields allowed for web nutrition lookup.
/// The meal description is sent to a search provider, so this path is opt-in and audited.
struct WebNutritionLookupPayload: AIContextPayload {
    let payloadKind = "web-nutrition"
    let mealDescription: String

    var includedFieldNames: [String] { ["mealDescription"] }
}

// MARK: - Day summary payload

/// Fields allowed for day-summary generation.
/// Forbidden: journal text, period data, TierTwo memories, symptom flags, narratives.
struct DaySummaryPayload: AIContextPayload {
    let payloadKind = "day-summary"
    let mealNames: [String]
    let workoutNames: [String]
    let sleepQualityLabel: String?
    let sleepHours: Double?
    /// Tag label only (e.g. "Good", "Hard") — never the journal entry text.
    let journalTagLabel: String?

    var includedFieldNames: [String] {
        ["mealNames", "workoutNames", "sleepQualityLabel", "sleepHours", "journalTagLabel"]
    }
}

// MARK: - Companion thought payload

/// A single derived-signal item — name and trend value only; no raw health samples.
struct AISignalSummary: Equatable, Sendable {
    let signalName: String
    let value: String
}

/// Fields allowed for companion-thought generation.
/// Forbidden: journal text, period data, raw narratives, raw TierTwo records.
/// `filteredMemorySummary` MUST be the output of `MemoryAgent.filteredContext` — never a raw
/// `tierTwoContextSummary` call.
struct CompanionThoughtPayload: AIContextPayload {
    let payloadKind = "companion-thought"
    let signalSummaries: [AISignalSummary]
    /// Tag label only — never journal entry text.
    let journalTagLabel: String?
    /// Pre-filtered, character-capped context produced by MemoryAgent.
    let filteredMemorySummary: String

    var includedFieldNames: [String] {
        ["signalSummaries", "journalTagLabel", "filteredMemorySummary"]
    }
}

// MARK: - Workout adjustment payload

/// Fields allowed for on-device workout-session adjustment.
/// Forbidden: journal text, period data, health metrics, narratives. Only the session's exercise
/// names, the user's free-text request, and how many catalog candidates were offered are sent.
struct WorkoutAdjustmentPayload: AIContextPayload {
    let payloadKind = "workout-adjustment"
    let request: String
    let currentExercises: [String]
    let candidateCount: Int

    var includedFieldNames: [String] { ["request", "currentExercises", "candidateCount"] }
}

// MARK: - Web page extraction payloads

/// Fields allowed for on-device nutrition extraction from a product webpage.
/// Only the source host and approximate text length are recorded; page content is never logged.
struct WebPageNutritionExtractionPayload: AIContextPayload {
    let payloadKind = "web-nutrition-extraction"
    let sourceHost: String
    let cleanedTextCharCount: Int

    var includedFieldNames: [String] { ["sourceHost", "cleanedTextCharCount"] }
}

/// Fields allowed for on-device recipe extraction from a webpage.
/// Only the source host and approximate text length are recorded; page content is never logged.
struct RecipeExtractionPayload: AIContextPayload {
    let payloadKind = "recipe-extraction"
    let sourceHost: String
    let cleanedTextCharCount: Int

    var includedFieldNames: [String] { ["sourceHost", "cleanedTextCharCount"] }
}
