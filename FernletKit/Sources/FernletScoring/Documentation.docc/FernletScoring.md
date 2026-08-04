# ``FernletScoring``

The deterministic engines that turn a day's logs into Fernlet's gentle 0–1 wellbeing score, plus the abstract period signals, the stress ("body signals") estimator, and the always-available local fallbacks for meals and workouts.

## Overview

FernletScoring is the numeric heart of Fernlet: pure, stateless functions that map a day's
logged signals — journal feeling, meals, movement, sleep, hydration, personal care — to the
0–1 daily score that drives the companion. The namespace enum ``FernletScoring/FernletScoring``
(it deliberately shares the module's name) exposes `computeBreakdown` as the single scoring
entry point: it blends six 0–1 component scores under a goal-derived `ScoringWeights` vector
(from ``GoalWeights``), then layers on the gentle modifiers — sickness reweighting, the
``PeriodScoringAdjustment`` leniencies, the capped micronutrient nudge, and the capped
``StressEngine`` nudge — and returns a ``ScoreBreakdown`` that `DiaryStore` persists into each
day's `DailyHealthScore`. `state(for:)` finally bands the score into the companion's
presentation state.

The module's governing invariant is **identity-preserving determinism**: every optional
refinement (HealthKit sleep stages and activity, nutrient gaps, period adjustment, stress
modifier) defaults to an identity value, so a call supplying only the original inputs
reproduces the original scores byte-for-byte, and every additive nudge is clamped so no single
modifier can dominate the weighted sum. There is no I/O, no clock reads inside the math, no
persistence, and no crypto here — callers assemble the inputs and persist the outputs
(`DailyHealthScore`, the device-local stress sidecar). Everything is a nonisolated static or a
`Sendable` value type: the target opts out of `defaultIsolation(MainActor.self)` in
`FernletKit/Package.swift`, so the engines are callable from any isolation context.

**Position in the graph and the S3 wall.** FernletScoring is a Layer-1 target depending only on
`FernletFoundation` and `FernletDomainModel`. It sits *below* the S3 privacy wall and is
imported on both sides of it: by the walled `AIProviders` target and the protected-side
`PeriodContextBridge`, as well as by `LocalPersistence`, `StoreCore`, `DiaryStore`, and
`FoodCatalog`. Because a walled consumer can import this module, **nothing sealed may ever
appear here** — which is exactly why the period types in this module are abstract.
``PeriodPhaseSignal``, ``PeriodSignalStrength``, and ``PeriodScoringAdjustment`` form the
sanctioned egress *vocabulary* for cycle data: they carry coarse enums only (never a date,
count, or confidence), the raw→abstract conversion from the sealed `CyclePhase` lives up in
`PeriodContextBridge` where the sealed store is visible, and `.none` is a strict identity. For
the same reason ``StressEngine`` deliberately accepts no cycle/period inputs at all — a
stress engine that consumed cycle phase would open a second egress path for menstrual data —
and instead tolerates luteal-phase HRV noise as estimation error its gentle copy absorbs.

The stress subsystem is a self-contained pipeline within the module: the caller (the app-side
stress service, fed by the HealthKit gateway) assembles a window of ``StressDaySample``s;
``StressEngine`` builds personal `MetricBaseline`s, combines per-metric z-scores, smooths them
with a heavy EWMA, and classifies the result into ``StressState`` — with a cold-start floor
(no output below 7 valid HRV days), a sustained-deviation requirement for `.needsCare`, and
confounder annotations (``StressAnnotation``) that cap rather than alarm. ``StressProvider``
is the seam future cross-vendor providers will plug into (nothing conforms yet). The output
``StressAssessment`` feeds back into scoring only as the tightly clamped modifier.

Finally, the module carries the deterministic local fallbacks that keep Fernlet fully
functional with AI off, resting, or failed: ``MealParser`` (keyword-heuristic meal estimation,
the bottom rung of the meal-analysis ladder), ``WorkoutPlanner`` (starter fitness goals and an
energy-matched session), ``WorkoutSuggestionLibrary`` (hand-written suggestion templates), and
``FernletVoice`` (the companion's consistent, gentle copy for every AI-degraded moment).
The behavior is pinned by `FernletTests` — notably `PeriodAwareScoringTests`,
`StressEngineTests`, and `HealthKitScoringTests`.

## Topics

### Daily scoring

- ``FernletScoring/FernletScoring``
- ``ScoreBreakdown``
- ``GoalWeights``

### Period-aware adjustment (sanctioned egress vocabulary)

- ``PeriodScoringAdjustment``
- ``PeriodPhaseSignal``
- ``PeriodSignalStrength``

### Stress ("body signals")

- ``StressEngine``
- ``StressDaySample``
- ``StressAssessment``
- ``StressState``
- ``StressAnnotation``
- ``StressConfidence``
- ``StressProvider``

### Local fallbacks and companion voice

- ``MealParser``
- ``WorkoutPlanner``
- ``WorkoutSuggestionLibrary``
- ``FernletVoice``
