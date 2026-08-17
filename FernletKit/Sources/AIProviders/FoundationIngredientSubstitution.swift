import Foundation
import AIContext
import FoodCatalog
import FernletDomainModel

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device AI stage for F4 ingredient substitution (decision §11.4).
///
/// The model contributes WORLD KNOWLEDGE only — "what could stand in for butter here" — by proposing
/// substitute food NAMES (the catalog has no dairy/allergen/ingredient-class taxonomy to derive them
/// from; see §5.2). It returns names plus an optional short reason and NOTHING else: no quantity, no
/// macro, no candidate it must bind. Code then rebinds each proposed name through the local catalog
/// (`resolve` → `FoodCatalog.candidates(for:)`), takes the first real match, and the caller computes the
/// replacement quantity by gram-equivalence. So the model names a food; CODE supplies the actual
/// `FoodItem` and its macros — the model never emits a food it invented, a number, or a macro.
///
/// Routing goes through the shipped `FernletAIGate` (standard tier, user-invoked): the gate caps by
/// device capability, applies the sleepy/resting budget, and charges exactly one call. A `nil` gate
/// result (off / resting / incapable) returns `nil` so the caller takes its deterministic path (the
/// manual catalog-search sheet).
///
/// Every model call is recorded in `AIAuditLog` (payload kind + included field names, never
/// content); session errors are audited and rethrown. MainActor by the module's default isolation,
/// with the pure binding helpers (``bindNames(picks:resolve:limit:)``, ``bind(picks:candidates:limit:)``,
/// ``deterministicSuggestions(candidates:)``) explicitly `nonisolated` so tests exercise the
/// world-knowledge → catalog handoff without `FoundationModels`.
public enum FoundationIngredientSubstitutionModel {

    /// Runs the substitution model for one ingredient. `resolve` maps a model-proposed food name to local
    /// catalog candidates (the caller backs it with `FoodCatalog.candidates(for:)`); the first match for
    /// each name is bound. Returns the bound suggestions (ordered as the model ranked them), or `nil` when
    /// AI did not run / produced nothing usable (no name resolved to a real food) — the signal for the
    /// caller to fall back to manual catalog search.
    public static func suggest(
        _ payload: IngredientSubstitutionPayload,
        gate: FernletAIGate,
        resolve: @Sendable (String) -> [FoodSelectionCandidate]
    ) async throws -> [IngredientSubstitutionSuggestion]? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard let destination = gate.dispatch(tier: .standard, userInvoked: true) else { return nil }
            let auditKind = payload.payloadKind
            let auditFields = payload.includedFieldNames
            let instructions = """
            You help a home cook swap one ingredient in a recipe for another.
            You are given the recipe name and the single ingredient to replace.
            Using general culinary knowledge, name the best few real, common foods that could stand in for
            it in THIS dish, best first (e.g. butter -> olive oil or coconut oil; buttermilk -> yogurt).
            Output food NAMES only — plain grocery-store food names a cook could buy.
            Give each pick a short, friendly reason (a few words). Never invent a food that does not exist.
            Do not output any quantities, measurements, or nutrition numbers.
            """
            let prompt = """
            Recipe: \(payload.recipeName)
            Replace this ingredient: \(payload.ingredientToReplace)
            """
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: FoundationSubstitutionSuggestions.self)
                let bound = response.content.bound(resolve: resolve)
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

    /// Rebinds model-proposed substitute NAMES (world knowledge) to real catalog foods, then binds by
    /// number. PUBLIC + pure so the world-knowledge → catalog handoff is unit-testable without
    /// `FoundationModels`. For each name in model-ranked order: `resolve` maps it to local catalog
    /// candidates and the FIRST match is taken (CODE supplies the food + its macros; the model supplied
    /// only the name). Resolved foods are numbered into a pool and run through `bind`, so the drop /
    /// dedupe / order / cap invariants are shared with the number-binding path. A name that resolves to
    /// nothing is dropped.
    public nonisolated static func bindNames(
        picks: [(name: String, reason: String?)],
        resolve: (String) -> [FoodSelectionCandidate],
        limit: Int = 6
    ) -> [IngredientSubstitutionSuggestion] {
        // R5: validate the cap at entry rather than building a pool `bind` would then discard.
        guard limit > 0 else { return [] }
        var pool: [FoodSelectionCandidate] = []
        var numberPicks: [(candidateNumber: Int, reason: String?)] = []
        for pick in picks {
            let trimmedName = pick.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, let food = resolve(trimmedName).first?.foodItem else { continue }
            let number: Int
            if let existing = pool.first(where: { $0.foodItem.id == food.id }) {
                number = existing.id
            } else {
                number = pool.count + 1
                pool.append(FoodSelectionCandidate(id: number, foodItem: food))
            }
            numberPicks.append((candidateNumber: number, reason: pick.reason))
        }
        return bind(picks: numberPicks, candidates: pool, limit: limit)
    }

    /// The longest substitution reason we display — the model's `reason` is free-form copy, so cap it
    /// before it reaches a persisted-nothing UI label (it feeds no number, macro, or stored field).
    nonisolated static let maxReasonLength = 120

    /// Binds model-emitted (candidateNumber, reason) pairs back to catalog candidates. PUBLIC + pure so
    /// the binding invariant is unit-testable without `FoundationModels`:
    /// - a number matching no candidate id is dropped (out-of-range / hallucinated),
    /// - duplicate numbers keep only the first (a food is suggested once),
    /// - order follows the model's ranking,
    /// - the result is capped at `limit` — a `limit` of zero or less yields nothing, since the cap is
    ///   checked after an append.
    public nonisolated static func bind(
        picks: [(candidateNumber: Int, reason: String?)],
        candidates: [FoodSelectionCandidate],
        limit: Int = 6
    ) -> [IngredientSubstitutionSuggestion] {
        // R5: the cap below is enforced AFTER an append, so a non-positive limit would otherwise
        // return one suggestion instead of none — validate it at entry.
        guard limit > 0 else { return [] }
        var seen: Set<UUID> = []
        var result: [IngredientSubstitutionSuggestion] = []
        for pick in picks {
            guard let candidate = candidates.first(where: { $0.id == pick.candidateNumber }) else { continue }
            guard seen.insert(candidate.foodItem.id).inserted else { continue }
            let trimmed = (pick.reason?.trimmingCharacters(in: .whitespacesAndNewlines)).map { String($0.prefix(maxReasonLength)) }
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
/// The `@Generable` response schema for F4 ingredient substitution: an ordered list of substitute
/// picks, best first.
///
/// Guided generation guarantees only shape; ``bound(resolve:)`` funnels the raw names through
/// ``FoundationIngredientSubstitutionModel``'s `bindNames`, so the drop / dedupe / order / cap
/// invariants apply before anything reaches the UI.
@available(iOS 26.0, *)
@Generable
private struct FoundationSubstitutionSuggestions {
    var suggestions: [FoundationSubstitutionPick]

    /// Rebinds the model's proposed names to real catalog foods via
    /// `FoundationIngredientSubstitutionModel.bindNames`; names resolving to nothing are dropped.
    func bound(resolve: (String) -> [FoodSelectionCandidate]) -> [IngredientSubstitutionSuggestion] {
        FoundationIngredientSubstitutionModel.bindNames(
            picks: suggestions.map { (name: $0.foodName, reason: $0.reason) },
            resolve: resolve
        )
    }
}

/// One model-proposed substitute: a plain grocery-store food name plus a short friendly reason.
///
/// The name is world knowledge only — it is re-resolved against the local catalog by
/// ``FoundationIngredientSubstitutionModel``, which supplies the actual `FoodItem` and macros; the
/// reason is display copy, capped before it reaches the UI and never persisted.
@available(iOS 26.0, *)
@Generable
private struct FoundationSubstitutionPick {
    var foodName: String
    var reason: String
}
#endif
