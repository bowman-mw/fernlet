import Foundation
import AIContext
import FoodCatalog
import FernletDomainModel

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device AI stage for F4 ingredient substitution (decision §11.4).
///
/// The model contributes WORLD KNOWLEDGE only — "what could stand in for butter here" — by selecting
/// from a numbered local candidate list. It returns candidate NUMBERS plus an optional short reason and
/// NOTHING else: no quantity, no macro, no food it invented. Code binds each number back to the catalog
/// `FoodItem` (`bind`), drops anything out of range or duplicated, and the caller computes the
/// replacement quantity by gram-equivalence. This is the exact `FoundationFoodSelection` handoff shape.
///
/// Routing goes through the shipped `FernletAIGate` (standard tier, user-invoked): the gate caps by
/// device capability, applies the sleepy/resting budget, and charges exactly one call. A `nil` gate
/// result (off / resting / incapable) returns `nil` so the caller takes its deterministic path (the
/// manual catalog-search sheet).
public enum FoundationIngredientSubstitutionModel {

    /// Runs the substitution model for one ingredient. Returns the bound suggestions (ordered as the
    /// model ranked them), or `nil` when AI did not run / produced nothing usable — the signal for the
    /// caller to fall back to manual catalog search.
    public static func suggest(
        _ payload: IngredientSubstitutionPayload,
        gate: FernletAIGate
    ) async throws -> [IngredientSubstitutionSuggestion]? {
        let candidates = payload.candidates
        guard candidates.isEmpty == false else { return nil }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard let destination = gate.dispatch(tier: .standard, userInvoked: true) else { return nil }
            let auditKind = payload.payloadKind
            let auditFields = payload.includedFieldNames
            let instructions = """
            You help a home cook swap one ingredient in a recipe for another.
            You are given the recipe name, the ingredient to replace, and a numbered list of candidate foods.
            Pick the best few replacements FROM THE NUMBERED LIST ONLY, best first, using candidateNumber values.
            Prefer foods that play a similar culinary role to the ingredient being replaced.
            Give each pick a short, friendly reason (a few words). Never invent a food that is not in the list.
            Do not output any quantities or nutrition numbers.
            """
            let prompt = """
            Recipe: \(payload.recipeName)
            Replace this ingredient: \(payload.ingredientToReplace)

            Candidate foods:
            \(candidates.map(\.promptLine).joined(separator: "\n"))
            """
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: FoundationSubstitutionSuggestions.self)
                let bound = response.content.bound(candidates: candidates)
                await AIAuditLog.shared.record(
                    payloadKind: auditKind,
                    destination: destination,
                    modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                    includedFields: auditFields,
                    outcome: bound.isEmpty ? .fellBack : .succeeded
                )
                return bound.isEmpty ? nil : bound
            } catch {
                await AIAuditLog.shared.record(
                    payloadKind: auditKind,
                    destination: destination,
                    modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                    includedFields: auditFields,
                    outcome: AIAuditOutcome.fromModelError(error)
                )
                throw error
            }
        }
        #endif

        return nil
    }

    /// Deterministic fallback ranking: the candidate pool itself, in catalog order, as suggestions with
    /// no reason. Used to seed the manual-search sheet's suggestion section when AI is off/unavailable —
    /// the user still picks manually, this just offers a sensible starting order.
    public nonisolated static func deterministicSuggestions(
        candidates: [FoodSelectionCandidate]
    ) -> [IngredientSubstitutionSuggestion] {
        candidates.map { IngredientSubstitutionSuggestion(foodItem: $0.foodItem, reason: nil) }
    }

    /// Binds model-emitted (candidateNumber, reason) pairs back to catalog candidates. PUBLIC + pure so
    /// the binding invariant is unit-testable without `FoundationModels`:
    /// - a number matching no candidate id is dropped (out-of-range / hallucinated),
    /// - duplicate numbers keep only the first (a food is suggested once),
    /// - order follows the model's ranking,
    /// - the result is capped at `limit`.
    public nonisolated static func bind(
        picks: [(candidateNumber: Int, reason: String?)],
        candidates: [FoodSelectionCandidate],
        limit: Int = 6
    ) -> [IngredientSubstitutionSuggestion] {
        var seen: Set<UUID> = []
        var result: [IngredientSubstitutionSuggestion] = []
        for pick in picks {
            guard let candidate = candidates.first(where: { $0.id == pick.candidateNumber }) else { continue }
            guard seen.insert(candidate.foodItem.id).inserted else { continue }
            let trimmed = pick.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(IngredientSubstitutionSuggestion(
                foodItem: candidate.foodItem,
                reason: (trimmed?.isEmpty == false) ? trimmed : nil
            ))
            if result.count >= limit { break }
        }
        return result
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
private struct FoundationSubstitutionSuggestions {
    var suggestions: [FoundationSubstitutionPick]

    func bound(candidates: [FoodSelectionCandidate]) -> [IngredientSubstitutionSuggestion] {
        FoundationIngredientSubstitutionModel.bind(
            picks: suggestions.map { (candidateNumber: $0.candidateNumber, reason: $0.reason) },
            candidates: candidates
        )
    }
}

@available(iOS 26.0, *)
@Generable
private struct FoundationSubstitutionPick {
    var candidateNumber: Int
    var reason: String
}
#endif
