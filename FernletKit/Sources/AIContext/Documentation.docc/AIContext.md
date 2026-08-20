# ``AIContext``

The AI control plane: typed de-identified payloads, the capability-capped routing ladder, the daily call budget, and the device-local "what left my device" audit log.

## Overview

`AIContext` is the sanctioned-egress layer of Fernlet's S3 privacy wall for AI work. In the
FernletKit dependency DAG it sits at Layer 4 with exactly one in-package dependency —
`FernletDomainModel` (for `AIDestination`, `AIStatus`, `MealType`, `TierTwoMemoryRecord`,
`DiagnosticLanguage`, and the `EnumDecodeCompat` freeze/park helpers) — and it never imports a
`Private*` store, a persistence module, or any platform framework beyond Foundation (plus a
system-framework `canImport(FoundationModels)` guard for error classification, which adds no SwiftPM
edge). The walled `AIProviders` module and the app-target AI call sites both import it, and the
build-enforced wall (`DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR`, see
`Scripts/spm-wall-check.sh`) guarantees that the ONLY route from user data to a model prompt is
through the typed payloads defined here. The module is not *inside* the wall and not *outside* it —
it IS the gate in the wall.

The pieces fit together as one dispatch pipeline. A call site builds an ``AIContextPayload``
conformer — the de-identification contract, where each payload type enumerates the exact fields
that may enter a prompt and anything unexpressed cannot reach the model. It then asks a
``FernletAIGate`` (rebuilt per call by the app so the stored `FernletSettings.aiStatus` intent is
fresh) to resolve the task: the gate overlays the stored intent with the device-local
``AICallQuota`` via ``AIStatusOverlay``, hands the effective status to ``FernletModelRouter``, and
the router walks the task's ``AICapabilityTier`` escalation ladder capped by ``AIDeviceCapability``.
The result is an ``AIRouteResolution`` — a concrete `AIDestination` to dispatch (charging exactly
one call against the daily budget at that single decision point), or a deterministic fallback with
an ``AIDeterministicReason`` the caller must honor with its non-AI path. After (or, for off-device
destinations, *before*) the call, the site records an ``AIAuditEntry`` in ``AIAuditLog``.
``MemoryAgent`` guards the one road from Tier-2 behavioral memories into prompts.

Three hard privacy invariants are enforced in code, not convention. First, the `light` tier
(journal- and memory-adjacent work) can never resolve to a destination whose `leavesDevice` is true
— ``FernletModelRouter`` asserts this at resolution time and fails closed in release builds. Second,
a provider content refusal never steps down the ladder: re-sending the same health-adjacent data to
a different vendor would widen the leak, so `contentRefusal` terminates to the deterministic
fallback. Third, everything this module tracks is device-local by construction: the quota counter
and the audit log are reached only through the injectable ``AICallQuotaStore`` and
``AIAuditLogPersisting`` seams (concrete `UserDefaults`- and file-backed stores live in the app
target and are never nameable from the walled module), and neither ever enters `FernletSnapshot`,
CloudKit, the sealed backup, or the data export. The derived `.sleepy` / `.resting` states are
likewise never written back into synced settings — device A's usage must not throttle device B.

The audit log deserves special care when editing. ``AIAuditEntry`` stores metadata only — payload
kind, destination, model identifier, outcome, field *names*, and a character count — never prompt
text or values. Destinations that leave the device must record at DISPATCH and update the outcome at
completion, so a crash mid-flight cannot hide an egress. Its two persisted enums
(`AIDestination`, ``AIAuditOutcome``) follow the `EnumDecodeCompat` freeze/park discipline: an
unknown future token freezes to a default and parks the raw token, and any UI must prefer the parked
token because the freeze defaults deliberately read in the privacy-worst direction.

Concurrency is simple by design: the target has no `MainActor` default isolation; every type is a
`Sendable` value type or caseless-enum namespace except ``AIAuditLog``, an `actor` that serializes
records arriving from arbitrary tasks. Nothing here does I/O of its own beyond the injected seams,
so gate resolution is safe to run on the main thread immediately before an `await` on a model
session. Today only the on-device Foundation-model rung (and the distinct, settings-gated
web-nutrition search path) is reachable; the PCC and BYOK rungs are encoded in the ladders but
report unavailable on the installed SDK, so the router lands on-device or deterministic everywhere.

### Localization: every string in this module is a token

Nothing in `AIContext` is display copy, and two families of literal here are load-bearing enough
that translating them breaks behavior silently. The `payloadKind` values
(`"companion-thought"`, `"food-selection"`, …) are the audit trail's key AND the input to
``MemoryAgent``'s allowlist, which is a fail-closed gate: a kind that is not in
``MemoryAgent/allowedPayloadKinds`` gets `""` back from `filteredContext` — no throw, no log, just a
companion thought permanently stripped of the user's behavioral memory. `TierTwoMemoryRecord`'s
`confidence` (`"low"`/`"medium"`/`"high"`) is compared the same way. Prompt vocabulary is the third
case: strings that reach a model must stay in one stable language, or the model's grounding shifts
per device locale with nothing to catch it. Where a human-readable name is genuinely needed, add a
separate display property in the UI layer and leave the token alone.

## Topics

### Typed payloads (the de-identification contract)

- ``AIContextPayload``
- ``FoodSelectionPayload``
- ``MealDecompositionPayload``
- ``WebNutritionLookupPayload``
- ``DaySummaryPayload``
- ``CompanionThoughtPayload``
- ``AISignalSummary``
- ``WorkoutAdjustmentPayload``
- ``IngredientSubstitutionPayload``
- ``WebPageNutritionExtractionPayload``
- ``RecipeExtractionPayload``

### Dispatch gate and routing

- ``FernletAIGate``
- ``FernletModelRouter``
- ``AICapabilityTier``
- ``AIRouteResolution``
- ``AIDeterministicReason``
- ``AIRouteFailureReason``

### Device capability

- ``AIDeviceCapability``
- ``AIDeviceCapabilityProviding``
- ``StaticAIDeviceCapabilityProvider``

### Daily call budget

- ``AICallQuota``
- ``AIStatusOverlay``
- ``AICallQuotaStore``

### Audit log

- ``AIAuditLog``
- ``AIAuditEntry``
- ``AIAuditOutcome``
- ``AIAuditLogPersisting``

### Memory gatekeeping

- ``MemoryAgent``
