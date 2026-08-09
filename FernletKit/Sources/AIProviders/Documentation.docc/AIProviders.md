# ``AIProviders``

On-device AI providers for Fernlet's food, recipe, and workout features — the walled consumers of
Apple's FoundationModels, reachable only through typed, de-identified context payloads.

## Overview

This module is one of the two **walled consumers** on Fernlet's S3 privacy wall (the other is
`CloudKitSync`). Its position in `FernletKit/Package.swift` is the enforcement mechanism: its
dependency list is exactly `AIContext`, `FernletDomainModel`, `FernletScoring`, and `FoodCatalog` —
no `Private*` store appears, so no sealed type (`CyclePhase`, `JournalNarrative`,
`MenstrualNarrativeRepository`, `PrivateMediaStore`, …) is even nameable here. Building with
`DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` (see `Scripts/spm-wall-check.sh`) turns a forbidden
`import PrivateHealthStore` into a hard build error. The only path from sensitive data to a model is
the typed, `Sendable` payload DTOs in `AIContext` (`FoodSelectionPayload`,
`WorkoutAdjustmentPayload`, `IngredientSubstitutionPayload`, `RecipeExtractionPayload`) — the
de-identification contract. When editing this module, never add a dependency edge; if a type you
need is unreachable, that is the wall working.

The module contains four Foundation-model "stages" plus the production capability probe. Every stage
follows the same shape:

1. **Candidates built in code.** The caller (or ``WorkoutAdjustmentCandidateBuilder``) assembles a
   numbered pool of real catalog entries — foods from `FoodCatalog`, exercises already filtered by
   `WorkoutSafetyFilter` — so safety and validity constraints are enforced *before* the prompt exists.
2. **Gate check at the dispatch point.** Each model call routes through `FernletAIGate` (from
   `AIContext`) immediately before dispatch: it caps by device capability, applies the daily
   sleepy/resting budget, and charges exactly one call. A gate fallback returns `nil` (or, for recipe
   import, throws a typed error) so the caller runs its deterministic path — every stage has one.
3. **Guided generation.** The prompt is answered into a private `@Generable` schema
   (`FoundationMealSelection`-style shapes). Guided generation guarantees shape, never validity.
4. **Code-side binding.** The response carries candidate *numbers* or food *names*, which code
   re-binds to real catalog entries — unknown numbers dropped, duplicates deduped, quantities and
   sets clamped, results capped. The model contributes judgment and world knowledge only; it never
   emits a food, exercise, macro, or number that persists unchecked.
5. **Audit.** Every dispatch outcome (succeeded / fell back / error class) is recorded to
   `AIAuditLog` with the payload kind and included *field names* — never content. Session errors are
   audited, then rethrown.

``RecipeWebImporter`` is the one place the module touches the network: an SSRF-guarded, bounded
HTTPS fetch of a user-supplied recipe page, preferring the page's own JSON-LD structured data (no
model call at all) and falling back to gated on-device extraction. Its error enum encodes the
distinction deferred queues rely on: a *transient* daily-budget fallback
(``RecipeWebImportError/aiBudgetExhausted``, clears at midnight) versus *persistent* device
incapability (``RecipeWebImportError/modelUnavailable``). It also owns the app's only
recipe-image HTTP path (owner decision 2026-08-09, reversing the 2026-07-16 "no external image
fetch" tester decision): ``RecipeWebImporter/extractedImageURL(from:sourceURL:)`` pulls the page's
main food-picture URL from the already-fetched HTML (JSON-LD `image` first, OpenGraph/Twitter meta
fallback — no extra request), and ``RecipeWebImporter/downloadImage(from:userAgent:maxBytes:)``
downloads image bytes under the same SSRF/redirect guard plus an `image/*` MIME check and an
oversize-aborting byte cap. Import itself never downloads the image — only user-present app paths
do (see `Docs/No-Tracking-Wall.md` §4b), and the app-side caller owns sealing and storage.

Concurrency: the target sets `defaultIsolation(MainActor.self)`, so the provider enums are
MainActor-isolated; pure value types (``WorkoutAdjustmentCandidate``, ``ImportedRecipe``) and the
testable binding/parsing helpers are explicitly `nonisolated`. The module holds no state and
persists nothing — every entry point returns a value to an app-side caller, which owns storage.
Capability rungs beyond the on-device model (Private Cloud Compute, BYOK) are iOS 27 APIs and
report unavailable via ``SystemLanguageModelCapabilityProvider``, the single slot-in point for them.

Note: three further AI files (`FoundationDishDecomposition`, `FoodProductWebImporter`,
`LaunchPreparationService`) still live in the app target — they need app-side helpers a package
cannot import — and are held sealed-free by the `FernletTests/S3BoundaryTests` grep-wall until
their helpers are extracted.

## Topics

### Meal food selection

- ``FoundationFoodSelectionModel``
- ``FoodSelectionAvailability``

### Ingredient substitution

- ``FoundationIngredientSubstitutionModel``

### Workout adjustment

- ``FoundationWorkoutAdjustmentModel``
- ``WorkoutAdjustmentCandidateBuilder``
- ``WorkoutAdjustmentCandidate``

### Recipe web import

- ``RecipeWebImporter``
- ``ImportedRecipe``
- ``RecipeWebImportError``

### Device capability

- ``SystemLanguageModelCapabilityProvider``
