import Foundation
import FernletDomainModel

// MARK: - Payload protocol

/// Marker protocol for all AI context payloads.
/// Each conforming type defines the exact fields that may enter an AI prompt.
/// Anything not expressed in a payload type cannot reach the model.
public protocol AIContextPayload: Sendable {
    var payloadKind: String { get }
    var includedFieldNames: [String] { get }
}

// MARK: - Food selection payload

/// Fields allowed for food-selection inference.
/// Forbidden: journal text, period data, health metrics, TierTwo memories, narratives.
public struct FoodSelectionPayload: AIContextPayload {
    public let payloadKind = "food-selection"
    public let mealDescription: String
    public let candidates: [FoodSelectionCandidate]
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
/// Sends strictly less than FoodSelectionPayload — no candidate list required.
public struct MealDecompositionPayload: AIContextPayload {
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
/// The meal description is sent to a search provider, so this path is opt-in and audited.
public struct WebNutritionLookupPayload: AIContextPayload {
    public let payloadKind = "web-nutrition"
    public let mealDescription: String

    public var includedFieldNames: [String] { ["mealDescription"] }

    public init(mealDescription: String) {
        self.mealDescription = mealDescription
    }
}

// MARK: - Day summary payload

/// Fields allowed for day-summary generation.
/// Forbidden: journal text, period data, TierTwo memories, symptom flags, narratives.
public struct DaySummaryPayload: AIContextPayload {
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
        self.mealNames = mealNames
        self.workoutNames = workoutNames
        self.sleepQualityLabel = sleepQualityLabel
        self.sleepHours = sleepHours
        self.journalTagLabel = journalTagLabel
    }
}

// MARK: - Companion thought payload

/// A single derived-signal item — name and trend value only; no raw health samples.
public struct AISignalSummary: Equatable, Sendable {
    public let signalName: String
    public let value: String

    public init(signalName: String, value: String) {
        self.signalName = signalName
        self.value = value
    }
}

/// Fields allowed for companion-thought generation.
/// Forbidden: journal text, period data, raw narratives, raw TierTwo records.
/// `filteredMemorySummary` MUST be the output of `MemoryAgent.filteredContext` — never a raw
/// `tierTwoContextSummary` call.
public struct CompanionThoughtPayload: AIContextPayload {
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
/// Forbidden: journal text, period data, health metrics, narratives. Only the session's exercise
/// names, the user's free-text request, and how many catalog candidates were offered are sent.
public struct WorkoutAdjustmentPayload: AIContextPayload {
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

// MARK: - Web page extraction payloads

/// Fields allowed for on-device nutrition extraction from a product webpage.
/// Only the source host and approximate text length are recorded; page content is never logged.
public struct WebPageNutritionExtractionPayload: AIContextPayload {
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
/// Only the source host and approximate text length are recorded; page content is never logged.
public struct RecipeExtractionPayload: AIContextPayload {
    public let payloadKind = "recipe-extraction"
    public let sourceHost: String
    public let cleanedTextCharCount: Int

    public var includedFieldNames: [String] { ["sourceHost", "cleanedTextCharCount"] }

    public init(sourceHost: String, cleanedTextCharCount: Int) {
        self.sourceHost = sourceHost
        self.cleanedTextCharCount = cleanedTextCharCount
    }
}
