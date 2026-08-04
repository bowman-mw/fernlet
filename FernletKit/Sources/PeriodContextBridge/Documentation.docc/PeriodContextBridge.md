# ``PeriodContextBridge``

The sanctioned egress layer that converts raw sealed cycle data into the abstract, privacy-preserving period signals the rest of Fernlet is allowed to see.

## Overview

PeriodContextBridge is the layer-4 module in FernletKit's S3-wall DAG whose entire job is *controlled leakage*: it is the single sanctioned path from the sealed cycle store (`PrivateHealthStore`) out to scoring, the companion, and the food/move suggestion surfaces. Raw cycle types — `CycleDayEntry`, `CyclePrediction`, `CyclePhase`, sealed `MenstrualNarrative` symptom flags — are visible *to* this module and are never re-exported by it. What crosses out is a deliberately tiny abstract vocabulary: coarse phase enums, kind-plus-strength hints with no quantities, and direction/confidence *bands* with no underlying statistics. Per spec §4, no dates, counts, predicted dates, raw HealthKit samples, or confidence doubles ever leave.

The module's position relative to the S3 privacy wall matters: it sits on the **protected side**, above `PrivateHealthStore` (it depends on it, plus `FernletScoring`, `FernletFoundation`, and `FernletDomainModel`). The walled consumers (`AIProviders`, `CloudKitSync`) can never import it — nor do they need to, because the abstract signal types scoring consumes (`PeriodPhaseSignal`, `PeriodSignalStrength`, `PeriodScoringAdjustment`) are declared down in `FernletScoring`, below the wall. Only the raw→abstract *conversion* lives here, where `CyclePhase` is nameable. That split is why `PeriodPhaseSignal.init(_: CyclePhase)` is an extension in this module rather than an initializer in FernletScoring.

The pieces fit together in one short pipeline. ``PeriodContextBridge`` (the `@Observable` class the module is named for) reads the live period store through the ``PeriodContextSource`` seam — held weakly, re-read on every query, so deleting period data degrades every output on the very next read ("deliberate forgetfulness"). ``CyclePhaseResolver`` is the pure calendar-math engine that places a day in a phase: observed bleeding always wins; follicular/ovulatory/luteal are filled in from the standard luteal≈14-day model only when a prediction exists. ``PeriodPhaseTrendEngine`` is the deterministic, AI-free correlation engine that compares each phase's wellbeing means against the user's own baseline and emits ``PeriodHealthTrend`` values — direction and confidence band only. Inbound, the app supplies non-sensitive per-day component scores as ``PeriodWellbeingSample`` values; outbound, `FernletStore` holds the bridge only as an `any` ``PeriodScoringContextProviding`` and applies the user's opt-in gate before ever consulting it.

Concurrency and persistence invariants: the target builds with `defaultIsolation(MainActor.self)` — the bridge and both seam protocols are `@MainActor` (scoring calls the bridge synchronously on the main actor) while the pure engines and value types are explicitly `nonisolated`. Nothing in this module persists anything, ever: trends and the one performance memo (detected period starts) live only in bridge memory, and `PeriodContextBridge/refresh(unlocked:wellbeingByDay:)` is the module's **only** invalidation point — the app must call it after every period-data mutation, lock-state change, or score change, or scoring reads keep using memoized starts and stale trends. The lock is honored twice over: the source store nils its `prediction` while locked (killing calendar-math phases and softening), and the bridge's own fail-closed `unlocked` flag gates the symptom-severity-dependent nutrition/exercise hints to `.noData`. Phase-aware inference additionally requires three *completed* cycles; below that gate only directly observed flow can place the user.

## Topics

### The bridge and its seams

- ``PeriodContextBridge``
- ``PeriodContextSource``
- ``PeriodScoringContextProviding``

### Abstract egress vocabulary

- ``PeriodPhaseBand``
- ``PeriodNutritionSignal``
- ``PeriodExerciseSignal``
- ``PeriodHealthTrend``

### Inbound wellbeing data

- ``PeriodWellbeingSample``

### Deterministic engines

- ``CyclePhaseResolver``
- ``PeriodPhaseTrendEngine``
