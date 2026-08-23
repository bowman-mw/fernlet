# ``FernletWidgets``

The WidgetKit extension that puts Fernlet's companion widget — and the guided-workout and cooking-mode Live Activities — on the Home Screen, Lock Screen, and Dynamic Island.

## Overview

FernletWidgets is a `com.apple.widgetkit-extension` app extension. Its `@main` entry point, ``FernletWidgetsBundle``, registers three surfaces: ``FernletCompanionWidget`` (a systemSmall card plus circular and rectangular Lock Screen accessories showing the companion's mood and today's water, with an interactive "+1" button), ``WorkoutLiveActivity`` (the guided-workout rest timer), and ``CookingLiveActivity`` (the step-by-step cooking walker). The companion widget renders the mood as a glyph whose face is negative space — a filled blob with the expression punched out — so it survives the Lock Screen's monochrome/tinted rendering, and the whole widget is marked `privacySensitive` because the companion state encodes wellbeing (including sickness).

Every byte the extension exchanges with the app crosses through JSON files in the shared App Group `group.MBO.Fernlet`, under a `App/FernletWidgets/` directory in the container. Four files form the contract: `WidgetSnapshot.json` (outbound — the app mirrors a deliberately benign ``WidgetSnapshot`` of mood, score, water, and macro grams on every save; never journal, cycle, stress, or intimacy data), `PendingWidgetActions.json` (inbound — ``WaterPlusOneIntent`` appends ``PendingWidgetAction`` rows that `FernletStore.processPendingWidgetActions()` drains idempotently by row id), and the two Live Activity run states, `GuidedWorkoutRunState.json` and `CookingRunState.json` (both read and written through the one generic ``AppGroupRunStateStore``, of which ``GuidedWorkoutRunStateStore`` and ``CookingRunStateStore`` are type aliases). All file access is `NSFileCoordinator`-guarded, ISO-8601/sorted-keys encoded, written atomically with file protection until first user authentication, and failure-silent: a missing or corrupt file reads as "nothing active" rather than an error. Day handling is anchored on the canonical `yyyy-MM-dd` key (``WidgetDayKey``): each timeline entry gates the snapshot through ``WidgetDayGate`` so that after local midnight — with the app closed — the widget self-corrects to a fresh, empty day instead of showing yesterday's mood and bottle count.

A deliberate constraint shapes the target: it links no FernletKit modules at all. The FernletKit umbrella product also carries the sealed `Private*` stores, `AIProviders`, and `CloudKitSync`, so linking it would be an S3-wall regression vector (and a WidgetKit memory hazard). The handful of shared types in `WidgetSharedModels.swift` — the app-group id, ``WidgetCompanionState``, ``WidgetSnapshot``, ``PendingWidgetAction``, ``WidgetDayKey``, and the JSON codecs in ``WidgetBridgeFiles`` — are therefore documented byte-for-byte mirrors of their app-side twins, kept identical by convention: the shared JSON files are the only contract between the two processes. Because those raw values are wire bytes, no surface here ever draws or speaks one: the mood word comes from `WidgetCompanionState.displayName`, the display fork of the frozen token (the same split `CompanionState.displayName` makes on the app side), and translating `rawValue` instead would make the extension's own parse fail and pin every widget to its neutral fallback forever, silently. The target is an app extension rather than an SPM module, so its `Text` literals and `String(localized:)` calls resolve against `Bundle.main` — which *is* `App/FernletWidgets/Localizable.xcstrings` — and must NOT pass `bundle: .module`.

The Live Activities use a second wiring mechanism: dual target membership. The ActivityKit attribute types (``WorkoutActivityAttributes``, ``CookingActivityAttributes``), the run states (``GuidedWorkoutRunState``, ``CookingRunState``), their stores, the activity bridges, and the `LiveActivityIntent` types are compiled into BOTH the app target and this extension via build-file exception sets on the FernletWidgets folder group. That is what makes the interactive buttons work: the widget renders a button bound to an intent such as ``GuidedWorkoutMarkSetDoneIntent`` or ``NextCookingStepIntent``, but the system executes `perform()` in the app's process (cold-launching it in the background if needed), where the intent runner reads the app-group run state, applies a pure transition, writes it back, and reflects the result onto the activity through ``GuidedWorkoutActivityBridge`` or ``CookingActivityBridge`` — thin per-activity seams over the shared generic engine ``LiveActivityReflector`` (parameterized by ``LiveActivityRunReflectable``). The app reconciles the same file on its next foreground, so the in-app UI, the file, and the activity never disagree. The two activity types are distinct `ActivityAttributes`, so ending one never touches the other.

Two rendering rules recur throughout: countdowns are always drawn from a fixed, ordered `start...end` window via `Text(timerInterval:)` — never a live `Date()...end` range, whose inverted bounds crash once a deadline passes (over-resting and over-running a step are designed states) — and a stale activity (one that outlived its process via jetsam or force-quit) degrades to a dimmed "Paused / Open Fernlet" register instead of a frozen timer or set count.

## Topics

### Extension entry point

- ``FernletWidgetsBundle``
- ``FernletWidgetKind``

### Companion widget

- ``FernletCompanionWidget``
- ``FernletCompanionProvider``
- ``FernletCompanionEntry``
- ``FernletCompanionWidgetView``
- ``FernletWidgetPalette``
- ``WaterPlusOneIntent``

### App-group bridge

- ``WidgetSnapshot``
- ``WidgetCompanionState``
- ``PendingWidgetAction``
- ``WidgetDayKey``
- ``WidgetDayGate``
- ``WidgetBridgeFiles``
- ``WidgetSnapshotStore``
- ``PendingWidgetActionWriter``
- ``AppGroupRunStateStore``
- ``AppGroupRunStatePersistable``

### Live Activity reflection

- ``LiveActivityRunReflectable``
- ``LiveActivityReflector``

### Guided-workout Live Activity

- ``WorkoutActivityAttributes``
- ``WorkoutLiveActivity``
- ``GuidedWorkoutRunState``
- ``GuidedWorkoutRunStateStore``
- ``GuidedWorkoutActivityBridge``
- ``GuidedWorkoutMarkSetDoneIntent``
- ``GuidedWorkoutSkipRestIntent``
- ``GuidedWorkoutIntentRunner``

### Cooking-mode Live Activity

- ``CookingActivityAttributes``
- ``CookingLiveActivity``
- ``CookingRunState``
- ``CookingRunStateStore``
- ``CookingActivityBridge``
- ``NextCookingStepIntent``
- ``RepeatCookingStepIntent``
- ``CookingIntentRunner``
