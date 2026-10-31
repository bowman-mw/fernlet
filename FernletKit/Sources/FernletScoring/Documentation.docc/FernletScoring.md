# ``FernletScoring``

The deterministic engines that turn a day's logs into Fernlet's gentle 0–1 wellbeing score, plus the abstract period signals, the stress ("body signals") estimator, and the always-available local fallbacks for meals and workouts.

## Overview

FernletScoring is the numeric heart of Fernlet: pure, stateless functions that map a day's
logged signals — journaling, meals, movement, sleep, hydration, personal care — to the
0–1 daily score that drives the companion. The namespace enum ``FernletScoring/FernletScoring``
(it deliberately shares the module's name) exposes `computeBreakdown` as the single scoring
entry point: it blends six 0–1 component scores under a goal-derived `ScoringWeights` vector
(from ``GoalWeights``), then layers on the gentle modifiers — sickness reweighting, the
``PeriodScoringAdjustment`` leniencies, the capped micronutrient nudge, and the capped
``StressEngine`` nudge — and returns a ``ScoreBreakdown`` that `DiaryStore` persists into each
day's `DailyHealthScore`. `state(for:)` finally bands the score into the companion's
presentation state, and ``CompanionEmotionEngine`` layers the companion's momentary feeling on top.

**Journaling is scored by habit, not by feeling** (owner decision, 2026-09-23). Any written journal
entry earns the same journal component — `journalEntryScore`, the top of the retired tag scale —
whatever its feeling tag, and a day with no entry keeps `noJournalEntryScore` (0.55), so writing about
a hard day can never score below not writing. **A check-in counts half** (owner decision, 2026-09-24):
a day whose only entries are one-tap mood check-ins (`isCheckInOnly(_:)`: every entry marked
`isQuickMood` with no text) earns `checkInOnlyScore`, half the credit above not journaling
(0.55 + 0.45 / 2 = 0.775), so a check-in still beats writing nothing; one written entry that day earns
the full credit. The tag survives only as the breakdown's unweighted `mood` reading
(`journalMoodScore(for:)`, the retired values exactly, check-in or not), which the app's period
bridge reads to learn which cycle phases are personally harder; it never enters the overall score.
Pinned by `JournalScoringParityTests`.

**Companion emotions** (owner decision 2026-09-24) are a presentation LAYER over the state, never
a new state. ``CompanionEmotionEngine`` derives the companion's momentary feeling — happy, sad, tired,
sleepy, asleep, hungry, thirsty, loved, comforted, playful, calm or a little frazzled (the `CompanionEmotion`
tokens live in `FernletDomainModel`) — as a pure function of ``CompanionEmotionInputs`` (today's
band, the latest journal tag, the mood trend, the last meal, the water, a friend's heart, the opt-in
body signals, a recent pet, the person's ``CompanionSleepWindow``) and a caller-supplied instant. The
first rule of ``CompanionEmotionEngine/precedence`` that fires decides:

| # | Rule | Shows | Fires when |
|---|---|---|---|
| 1 | `asleep` | asleep | inside the sleep window, past the 30-minute wind-down |
| 2 | `unwell` | — (the sick face) | today is marked unwell |
| 3 | `bedtime` | sleepy | inside the sleep window (the wind-down) |
| 4 | `held` | comforted | gentle day, and a heart is glowing or the companion was just petted |
| 5 | `hardDay` | sad | today's latest entry is tagged hard |
| 6 | `tiredDay` | tired | today's latest entry is tagged tired |
| 7 | `tense` | frazzled | body signals read tense, band thriving or okay |
| 8 | `petted` | playful | petted in the last few minutes, day not gentle |
| 9 | `hunger` | hungry | cues on, waking hours, band not resting, no meal for a while |
| 10 | `thirst` | thirsty | cues on, waking hours, band not resting, water behind pace |
| 11 | `heart` | loved | a friend's heart is glowing, day not gentle |
| 12 | `brightDay` | happy | today's latest entry is tagged bright or good |
| 13 | `lowBand` | tired | band tired or resting |
| 14 | `calmBody` | calm | body signals read calm, band thriving or okay, day not gentle |
| 15 | `thriving` | happy | band thriving, day not gentle |

*Asleep* (owner decision 2026-10-21) begins ``CompanionSleepWindow/windDownMinutes`` (30) after
bedtime and lasts until the wake time. It sits above even the unwell flag because an asleep companion
shows nothing of the day: renders draw it in a neutral night colour with no state word or care bar
(`CompanionEmotion.hidesTheDay`), and it is the one emotion the Lock Screen may draw.

A *gentle day* (``CompanionEmotionInputs/isGentleDay``) — tagged hard or tired, or no entry yet and a
mood trend that needs gentleness — never yields a happy-looking emotion; sad only ever mirrors a day
the person tagged hard, never a low score or a missing log. Hunger and thirst come from LOGGING gaps,
so they are bounded to waking hours minus a quiet evening, silent when unwell or resting, and switched
off by the person's cue setting. ``CompanionEmotionEngine/timeline(for:dayContaining:calendar:)``
turns the same rules into a time-stable, whole-second timeline for the widget (one WidgetKit entry per
moment, each moment scoped to its own local day), built from ``CompanionEmotionInputs/widgetSafe``
inputs so the body-signal, heart and petting emotions never leave the app. Nothing here is persisted
or synced; the emotion never reaches the friend wire, an export, or `DailyHealthScore`. Pinned by
`CompanionEmotionEngineTests`.

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

**Localization** (Spanish round step 2, 2026-10-20). The module owns a `Localizable.xcstrings`, and
every lookup passes `bundle: .module`. ``FernletVoice``'s lines are display copy (`fernletVoice.*`).
The workout fallbacks' notes and the starter goals are composed in the device's language
(`workoutFallback.*`), as the planner's own notes are: they are stored on the row or the goal and
drawn as stored, and nothing compares them. A line that describes the user agrees with them
(gendered-address lane, 2026-10-21): ``FernletVoice/message(for:addressing:)`` and
``WorkoutSuggestionLibrary/suggestions(for:intensity:addressing:)`` take the user's term of address,
and the retry banner's "when you are ready" and Balanced Strength Circuit's "feel grounded" resolve
through FernletDomainModel's `AddressedCopy` with a resource built against this module's bundle. The fallback workouts' NAMES are tokens: a taken
suggestion is saved under its frozen `WorkoutFallbackName` (FernletDomainModel, where the draw-time
mapping lives), and screens draw it through `Workout.displayedName`. Their exercise lines are plan
text and stay English. **The travel-day session** (World-Airports-Spec §13.2, 2026-10-31):
`WorkoutPlanner.travelDayPlan(locationName:)` and `suggestion(energy:goal:context:goals:travelDay:)` are
chosen by one yes/no the app works out; "Travel-day reset" is a frozen `WorkoutFallbackName`, its eight
moves are bundled catalog names, and its one reason line comes from `WorkoutFallbackCopy`. No flight,
airport, time or place reaches this module. ``MealParser``'s "Meal" default name and "Estimated locally…" note are stored
meal text the food log draws verbatim, so they stay English until that draw site maps them. No
derived-signal or readiness phrasing lives here (that is `LocalPersistence`'s `DerivedSignalFactory`,
whose values six gates compare). Pinned by `LocalizationBoundaryTests.frozenFallbackWorkoutNames`.

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

### Companion emotions (presentation only)

- ``CompanionEmotionEngine``
- ``CompanionEmotionInputs``
- ``CompanionEmotionRule``
- ``CompanionEmotionMoment``
- ``CompanionSleepWindow``
- ``CompanionBodySignal``

### Local fallbacks and companion voice

- ``MealParser``
- ``WorkoutPlanner``
- ``WorkoutSuggestionLibrary``
- ``FernletVoice``
