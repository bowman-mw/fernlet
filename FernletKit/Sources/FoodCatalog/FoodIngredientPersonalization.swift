// FoodIngredientPersonalization.swift
// FoodCatalog

import Foundation
import FernletDomainModel

/// A read-only snapshot used only after deterministic resolver candidates have passed their cold
/// retrieval, name, score, and food-form gates. It records no food data and persists nothing.
///
/// Corrections are explicit choices and therefore outrank inferred recent history. Both signals can
/// only choose from the supplied compatible candidates, so neither can inject a food, mint binding
/// confidence, or affect a selected food's quantity, unit, portions, or nutrition.
public nonisolated struct FoodIngredientPersonalization: Sendable {
    public static let empty = FoodIngredientPersonalization(corrections: [:], history: .empty)

    private let corrections: [String: UUID]
    private let history: FoodSearchHistory

    public init(corrections: [String: UUID], history: FoodSearchHistory) {
        self.corrections = corrections
        self.history = history
    }

    /// Returns the explicit correction for a whole ingredient phrase when compatible; otherwise a
    /// clearly leading recent specialization. `nil` preserves the caller's cold ranking.
    public func preferredFoodID(
        forCompletePhrase completePhrase: String,
        among candidates: [FoodItem],
        now: Date = Date()
    ) -> UUID? {
        let compatible = compatibleCandidates(for: completePhrase, among: candidates)
        guard compatible.isEmpty == false else { return nil }
        let key = FoodItemSearch.normalized(completePhrase)
        if let correctedID = corrections[key], compatible.contains(where: { $0.id == correctedID }) {
            return correctedID
        }
        return history.preferredRecentIngredientID(
            forCompletePhrase: completePhrase, among: compatible, now: now
        )
    }

    private func compatibleCandidates(for completePhrase: String, among candidates: [FoodItem]) -> [FoodItem] {
        guard FoodItemSearch.searchTokens(in: completePhrase).isEmpty == false else { return [] }
        return candidates.prefix(FoodSearchHistory.maximumIngredientSpecializationCandidates).filter {
            FoodItemSearch.nameCarriesQuery($0.name, query: completePhrase)
        }
    }
}
