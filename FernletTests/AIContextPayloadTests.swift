import Foundation
import Testing
import AIContext
import FernletDomainModel
@testable import Fernlet

@Suite struct AIContextPayloadTests {

    // MARK: - FoodSelectionPayload forbidden fields

    @Test func foodSelectionPayloadHasNoJournalText() {
        let payload = FoodSelectionPayload(mealDescription: "oatmeal", candidates: [], fallbackMealType: nil)
        let fields = Mirror(reflecting: payload).children.compactMap(\.label)
        #expect(!fields.contains("journalText"))
        #expect(!fields.contains("journalEntry"))
        #expect(!fields.contains("periodData"))
        #expect(!fields.contains("tierTwoMemories"))
        #expect(!fields.contains("narrative"))
        #expect(!fields.contains("symptoms"))
    }

    @Test func foodSelectionPayloadAllowedFieldsOnly() {
        let payload = FoodSelectionPayload(mealDescription: "salad", candidates: [], fallbackMealType: nil)
        #expect(payload.includedFieldNames == ["mealDescription", "candidates", "fallbackMealType"])
    }

    // MARK: - DaySummaryPayload forbidden fields

    @Test func daySummaryPayloadHasNoJournalText() {
        let payload = DaySummaryPayload(
            mealNames: ["oatmeal"], workoutNames: [],
            sleepQualityLabel: nil, sleepHours: nil, journalTagLabel: "Good"
        )
        let fields = Mirror(reflecting: payload).children.compactMap(\.label)
        #expect(!fields.contains("journalText"))
        #expect(!fields.contains("journalEntry"))
        #expect(!fields.contains("periodData"))
        #expect(!fields.contains("tierTwoMemories"))
        #expect(!fields.contains("menstrualNarrative"))
        #expect(!fields.contains("symptomFlags"))
    }

    @Test func daySummaryPayloadJournalFieldIsTagLabelNotText() {
        let payload = DaySummaryPayload(
            mealNames: [], workoutNames: [],
            sleepQualityLabel: nil, sleepHours: nil, journalTagLabel: "Hard"
        )
        let fields = Mirror(reflecting: payload).children.compactMap(\.label)
        #expect(fields.contains("journalTagLabel"))
        #expect(!fields.contains("journalText"))
    }

    // MARK: - CompanionThoughtPayload forbidden fields

    @Test func companionThoughtPayloadHasNoRawTierTwoRecords() {
        let payload = CompanionThoughtPayload(signalSummaries: [], journalTagLabel: nil, filteredMemorySummary: "")
        let fields = Mirror(reflecting: payload).children.compactMap(\.label)
        #expect(!fields.contains("tierTwoMemories"))
        #expect(!fields.contains("journalText"))
        #expect(!fields.contains("periodData"))
        #expect(!fields.contains("menstrualNarrative"))
        // Filtered summary string is the only memory field
        #expect(fields.contains("filteredMemorySummary"))
    }

    @Test func companionThoughtPayloadIncludedFields() {
        let payload = CompanionThoughtPayload(signalSummaries: [], journalTagLabel: nil, filteredMemorySummary: "")
        #expect(payload.includedFieldNames == ["signalSummaries", "journalTagLabel", "filteredMemorySummary"])
    }

    // MARK: - MemoryAgent destination allowlist

    @Test func memoryAgentBlocksFoodSelectionDestination() {
        let record = TierTwoMemoryRecord(category: "movement", text: "Active user", evidence: "")
        let result = MemoryAgent.filteredContext(from: [record], destinedFor: "food-selection")
        #expect(result.isEmpty)
    }

    @Test func memoryAgentBlocksDaySummaryDestination() {
        let record = TierTwoMemoryRecord(category: "movement", text: "Active user", evidence: "")
        let result = MemoryAgent.filteredContext(from: [record], destinedFor: "day-summary")
        #expect(result.isEmpty)
    }

    @Test func memoryAgentPassesCompanionThoughtDestination() {
        var record = TierTwoMemoryRecord(category: "movement", text: "Tends to walk daily", evidence: "based on step patterns")
        record.confidence = "medium"
        record.active = true
        let result = MemoryAgent.filteredContext(from: [record], destinedFor: "companion-thought")
        #expect(result.contains("Tends to walk daily"))
    }

    // MARK: - MemoryAgent diagnostic filter

    @Test func memoryAgentBlocksDiagnosticText() {
        let record = TierTwoMemoryRecord(category: "mood", text: "User shows signs of depression", evidence: "")
        #expect(MemoryAgent.containsDiagnosticLanguage(record))
        let result = MemoryAgent.filteredContext(from: [record], destinedFor: "companion-thought")
        #expect(result.isEmpty)
    }

    @Test func memoryAgentBlocksDiagnosticEvidence() {
        let record = TierTwoMemoryRecord(category: "mood", text: "Mood varies", evidence: "may indicate anxiety disorder")
        #expect(MemoryAgent.containsDiagnosticLanguage(record))
    }

    @Test func memoryAgentAllowsCleanBehavioralText() {
        let record = TierTwoMemoryRecord(category: "movement", text: "Works out 3x per week on average", evidence: "based on workout logs")
        #expect(!MemoryAgent.containsDiagnosticLanguage(record))
    }

    @Test func memoryAgentCoversAllDiagnosticPatterns() {
        let sensitive = [
            "has a disorder", "rare syndrome", "diagnos something", "depression mood",
            "anxiety levels", "bipolar pattern", "adhd traits", "autism spectrum",
            "ocd behavior", "ptsd response", "trauma history", "schizophrenia signs",
            "psychosis episode", "on medication", "prescription use",
            "in therapy", "psychiatric eval", "clinical assessment"
        ]
        for text in sensitive {
            let record = TierTwoMemoryRecord(category: "test", text: text, evidence: "")
            #expect(MemoryAgent.containsDiagnosticLanguage(record), "Expected '\(text)' to match a diagnostic pattern")
        }
    }

    // MARK: - MemoryAgent recency filter

    @Test func memoryAgentExcludesOldRecords() {
        var old = TierTwoMemoryRecord(category: "movement", text: "Old habit", evidence: "")
        old.extractedDate = Calendar.current.date(byAdding: .day, value: -60, to: Date())!
        old.active = true
        let result = MemoryAgent.filteredContext(from: [old], destinedFor: "companion-thought", recencyDays: 30)
        #expect(result.isEmpty)
    }

    @Test func memoryAgentIncludesFreshRecords() {
        var fresh = TierTwoMemoryRecord(category: "movement", text: "Recent pattern", evidence: "")
        fresh.extractedDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        fresh.active = true
        let result = MemoryAgent.filteredContext(from: [fresh], destinedFor: "companion-thought", recencyDays: 30)
        #expect(result.contains("Recent pattern"))
    }

    // MARK: - MemoryAgent confidence filter

    @Test func memoryAgentExcludesLowConfidence() {
        let record = TierTwoMemoryRecord(category: "movement", text: "Uncertain pattern", evidence: "", confidence: "low")
        let result = MemoryAgent.filteredContext(from: [record], destinedFor: "companion-thought")
        #expect(result.isEmpty)
    }

    @Test func memoryAgentIncludesMediumAndHighConfidence() {
        let medium = TierTwoMemoryRecord(category: "movement", text: "Medium pattern", evidence: "", confidence: "medium")
        let high = TierTwoMemoryRecord(category: "movement", text: "High pattern", evidence: "", confidence: "high")
        let result = MemoryAgent.filteredContext(from: [medium, high], destinedFor: "companion-thought")
        #expect(result.contains("Medium pattern"))
        #expect(result.contains("High pattern"))
    }

    // MARK: - MemoryAgent char cap

    @Test func memoryAgentRespectsCharCap() {
        let records = (0..<10).map { i in
            TierTwoMemoryRecord(category: "test", text: "Pattern \(i) is a behavioral observation", evidence: "", confidence: "high")
        }
        let result = MemoryAgent.filteredContext(from: records, destinedFor: "companion-thought", maxChars: 80)
        #expect(result.count <= 80)
    }
}
