# ``FernletWidgets``

The WidgetKit extension that puts Fernlet's companion, water and stamp widgets, the water control, and the guided-workout and cooking-mode Live Activities on the Home Screen, Lock Screen, Control Center and Dynamic Island.

## Overview

FernletWidgets is a `com.apple.widgetkit-extension` app extension. Its `@main` entry point, ``FernletWidgetsBundle``, registers seven surfaces. The Home Screen and Lock Screen widgets are drawn in the World design language (World Review Batch 4, approved 2026-10-24): paper in a 3-point ink frame (``WidgetTheme``, ``WidgetPaperFrame``), the World's pixel art (``WidgetSprites``, hand-copied from the app's `WorldSprites`), Fraunces and DM Sans (``WidgetFont``), in light and dark, under Increase Contrast, and in one colour for the Lock Screen and the tinted and clear Home Screens (every view takes a `mono` flag; empty hearts and drops become outlines, a friend's gold heart a checked fill). ``FernletCompanionWidget`` shows the person's own companion as the map's pixel companion (``WidgetCompanionPainter``, the twin of the app's `WorldCompanionPainter`: the body in the state's colour or the person's own, the sprout, glasses and scarf, the night taupe and a pixel "z" while asleep): the small card adds its name, the state word and Home's six hearts (``WidgetHeartRow``, each heart two of the day's 12 care segments) with a friend's gold hearts after them; the medium card sets the companion and its hearts beside one of the widget's own lines (``WidgetThoughtLines``, chosen by state and time of day, the bedtime slots following the person's own bedtime) in the pixel speech bubble (``WidgetSpeechBubble``); the Lock Screen has the silhouette alone and a rectangle with the name, the hearts and today's water (``CompanionLockRectView``, whose name and hearts hide until the phone is unlocked). ``FernletWaterWidget`` is the small water card — the bottle and "Water", the count, Home's pixel drops (``WidgetDropRow``) and a framed moss "+" (``WaterPlusButton``), the rest of the tile opening Water where a mis-tap can be undone — and a Lock Screen "+1" circle drawn as a pixel drop and plus; ``FernletWaterControl`` puts the same "+1 water" in Control Center and on the Action button, its icon the pixel drop shipped as a custom symbol in the extension's asset catalog. All three water surfaces log through ``WaterPlusOneIntent``. ``FernletStampWidget`` shows a stamp from the person's stamp book (``WidgetStampShelf``: the newest earned today with a "New today" ribbon, otherwise a different one each day; the medium card adds the last four and "5 of 19"); its names and art are hand-copied from the app (``WidgetStampKind``, ``WidgetStampArt``) and a tap opens the Stamp book. The other two are ``WorkoutLiveActivity`` (the guided workout: the rest timer between sets with "−15 s" / "+15 s" beside "Skip rest", the hold countdown of a timed step — a warm-up stretch, a plank — with its side, a guided cardio segment's countdown with its pace in words and its round and its heart-rate cue — the live reading against the part's target zone with a calm word, or the talk test without one, worded by ``WorkoutActivityZoneText`` — and a lift's weight, range and last time's numbers, shown and never edited, formatted in the reader's locale by ``WorkoutActivityLoadText``; a lift's lighter warm-up sets read "Warm-up 1 of 3", and "1/3" in the compact Island, spoken in words), and ``CookingLiveActivity`` (the step-by-step cooking walker). In one colour the pixel companion is a silhouette with its face punched out, so the expression survives the Lock Screen's and the tinted Home Screen's rendering, and every companion family that shows the state is marked `privacySensitive` because the state encodes wellbeing (including sickness); so is the stamp widget, because a stamp can be a Health-derived fact.

**Emotions** (owner decision 2026-09-24). The widgets carry the companion's momentary feeling — happy, sad, tired, sleepy, asleep, hungry or thirsty (``WidgetCompanionEmotion``) — in the spoken status ("Okay, feeling sleepy") and in the thought card's bedtime and night lines. Since World Review Batch 4 the drawn face is the state's, as on Home's map, with asleep the one feeling drawn (closed eyes, the night body and a pixel "z"); since round 6b (owner's Q37) the Home Screen families — the small and medium cards and the map widget — draw four feelings again in pixels (``WidgetFeelingFace``, run after the map's painter, which stays its word-for-word twin): happy (eyes bowed up, a wide smile, a blush, and a twinkle beside the head), sad (brows lifted at the inner ends, a soft frown and a tear), hungry and thirsty (eyes raised toward a thought bubble holding an apple or a drop, ``WidgetFeelingMotif``), only on bare body, so glasses, the scarf, the cap and a drawn piece stay on top. Tired and sleepy keep the state's face. The app publishes the whole day's feelings at once as the snapshot's `companionEmotionTimeline` (one moment per change, from local midnight through the next wake time, on whole seconds), and ``FernletCompanionProvider`` adds a timeline entry at every upcoming moment, so the companion turns sleepy at bedtime, falls asleep thirty minutes later, or turns hungry at the hunger onset with the app closed. *Asleep* (owner decision 2026-10-21) hides the day: the body wears a neutral night colour (`FernletWidgetPalette.night`), the written and spoken status is "Asleep" alone, and no state or feeling about the day shows. ``WidgetEmotionTimeline`` reads a moment only on its own local day — the twin of the app's `CompanionEmotionEngine.emotion(in:at:)` — so a stale snapshot never draws yesterday's feeling, while the sleepy night the app computed past midnight still applies. The Lock Screen accessories draw the STATE face only (``FernletWidgetEmotionPolicy``, the privacy-forward default the owner confirmed on 2026-09-24): a sad or hungry face there would tell anyone who glances at the phone how the day went. Asleep is the one exception, because it says nothing about the day. The body-signal, friend-heart and petting feelings never reach this process at all.

**The map widget** (`b4-new-map`, built in round 6b on the owner's Q36: "Places + trails, not history"). ``FernletMapWidget`` is a large Home Screen widget, Home in miniature: Sprout stands on a picture of the map around the person, under Home's status plate (the hearts with a friend's gold hearts, the protein, carbs and fat bars drawn against the day's targets the snapshot now carries, ``WidgetMacros``, and the water drops) with "Map from 9:40" in the corner (``MapWidgetCard``). The picture is the app's, read from `WidgetMap.plist` in the App Group (``WidgetMapPicture``, ``WidgetMapPictureStore``): Apple's muted map for about 400 m round where the person stood, with their marked places (homes, the hotel of a stay, the places they keep to eat and train) and saved trails already drawn on it, light and dark. It never carries a coordinate, a visit count, a day or a photo. The app writes it only while the person has added this widget, with complete file protection and never into a backup, and deletes it with every wipe, "Delete map history" and a decoy's start; before there is one (and in a decoy) the card shows Home's plain ground and "Open Fernlet". Because the picture is locked away with the phone, ``FernletMapProvider`` never reloads on a schedule (`.never`): the app reloads it while the phone is unlocked, every moment the day needs is already in the timeline, and a water tap from the Lock Screen leaves it as last drawn (``WidgetMapPictureStore/mayReload``). iOS offers no large widget on the Lock Screen or in StandBy; the card is `privacySensitive` anyway.

Every byte the extension exchanges with the app crosses through JSON files in the shared App Group `group.MBO.Fernlet`, under a `App/FernletWidgets/` directory in the container. Four files form the contract: `WidgetSnapshot.json` (outbound — the app mirrors a deliberately benign ``WidgetSnapshot`` of mood, the emotion timeline, score, water, macro grams, when a friend's gold hearts fade and the stamp book's tokens and days on every save; never journal text, cycle, stress, or intimacy data, and never a place — the World map's location, fog, routes and pins never enter the app group, which is why the large map widget waits on the owner), `PendingWidgetActions.json` (inbound — ``WaterPlusOneIntent`` appends ``PendingWidgetAction`` rows that `FernletStore.processPendingWidgetActions()` drains idempotently by row id), and the two Live Activity run states, `GuidedWorkoutRunState.json` and `CookingRunState.json` (both read and written through the one generic ``AppGroupRunStateStore``, of which ``GuidedWorkoutRunStateStore`` and ``CookingRunStateStore`` are type aliases). All file access is `NSFileCoordinator`-guarded, ISO-8601/sorted-keys encoded, written atomically with file protection until first user authentication, and failure-silent: a missing or corrupt file reads as "nothing active" rather than an error. Day handling is anchored on the canonical `yyyy-MM-dd` key (``WidgetDayKey``): each timeline entry gates the snapshot through ``WidgetDayGate`` so that after local midnight — with the app closed — the widget self-corrects to a fresh, empty day instead of showing yesterday's mood and bottle count.

A deliberate constraint shapes the target: it links no FernletKit modules at all. The FernletKit umbrella product also carries the sealed `Private*` stores, `AIProviders`, and `CloudKitSync`, so linking it would be an S3-wall regression vector (and a WidgetKit memory hazard). The handful of shared types in `WidgetSharedModels.swift` — the app-group id, ``WidgetCompanionState``, ``WidgetCompanionEmotion``, ``WidgetEmotionTimeline``, ``WidgetSnapshot``, ``PendingWidgetAction``, ``WidgetDayKey``, and the JSON codecs in ``WidgetBridgeFiles`` — are therefore documented byte-for-byte mirrors of their app-side twins, kept identical by convention: the shared JSON files are the only contract between the two processes. Because those raw values are wire bytes, no surface here ever draws or speaks one: the mood word comes from `WidgetCompanionState.displayName`, the display fork of the frozen token (the same split `CompanionState.displayName` makes on the app side), and translating `rawValue` instead would make the extension's own parse fail and pin every widget to its neutral fallback forever, silently. The target is an app extension rather than an SPM module, so its `Text` literals and `String(localized:)` calls resolve against `Bundle.main` — which *is* `App/FernletWidgets/Localizable.xcstrings` — and must NOT pass `bundle: .module`.

The Live Activities use a second wiring mechanism: dual target membership. The ActivityKit attribute types (``WorkoutActivityAttributes``, ``CookingActivityAttributes``), the run states (``GuidedWorkoutRunState``, ``CookingRunState``), their stores, the activity bridges, and the `LiveActivityIntent` types are compiled into BOTH the app target and this extension via build-file exception sets on the FernletWidgets folder group. That is what makes the interactive buttons work: the widget renders a button bound to an intent such as ``GuidedWorkoutMarkSetDoneIntent`` or ``NextCookingStepIntent``, but the system executes `perform()` in the app's process (cold-launching it in the background if needed), where the intent runner reads the app-group run state, applies a pure transition, writes it back, and reflects the result onto the activity through ``GuidedWorkoutActivityBridge`` or ``CookingActivityBridge`` — thin per-activity seams over the shared generic engine ``LiveActivityReflector`` (parameterized by ``LiveActivityRunReflectable``). The app reconciles the same file on its next foreground, so the in-app UI, the file, and the activity never disagree. The two activity types are distinct `ActivityAttributes`, so ending one never touches the other.

Two rendering rules recur throughout: countdowns are always drawn from a fixed, ordered `start...end` window via `Text(timerInterval:)` — never a live `Date()...end` range, whose inverted bounds crash once a deadline passes (over-resting and over-running a step are designed states) — and a stale activity (one that outlived its process via jetsam or force-quit) degrades to a dimmed "Paused / Open Fernlet" register instead of a frozen timer or set count.

Both Live Activities wear the World look (World Review Batch 4, approved 2026-10-24). On the Lock Screen the card is paper inside a 3-point ink frame, light or dark with the Lock Screen and deeper under Increase Contrast (``LiveActivityLook``, ``LiveActivityCard``), with Fraunces for the exercise, the step and the countdowns and DM Sans for the rest (``LiveActivityFont``), pixel icons instead of SF Symbols (``LiveActivitySprites``, drawn by ``LiveActivitySpriteView``), the workout's place as pixel progress squares in the header (``LiveActivityProgressSquares``) and framed buttons (``LiveActivityButtonFace``). The Dynamic Island stays black, as iOS requires; its icons are pixel art in leaf green and its buttons framed (``LiveActivityIslandLook``, ``LiveActivityIslandButtonFace``). Each button is still a plain `Button(intent:)`; only its face is drawn, so the intents run exactly as before. A paused (stale) run shows ``LiveActivityPausedCard``. In DEBUG builds the app's `FERNLET_UI_TEST_LIVE_ACTIVITY=<scene>` launch hook puts one canned activity on screen for screenshots and device checks.

## Topics

### Extension entry point

- ``FernletWidgetsBundle``
- ``FernletWidgetKind``

### Companion widget

- ``FernletCompanionWidget``
- ``FernletCompanionProvider``
- ``FernletCompanionEntry``
- ``FernletCompanionWidgetView``
- ``CompanionSmallView``
- ``CompanionThoughtView``
- ``WidgetSpeechBubble``
- ``WidgetBubbleTail``
- ``CompanionLockView``
- ``CompanionLockRectView``
- ``WidgetLockWaterLine``
- ``PlaceholderView``
- ``WidgetThoughtLines``
- ``WidgetThoughtSlot``
- ``FernletWidgetPalette``
- ``FernletWidgetEmotionPolicy``
- ``FernletWidgetLink``

### The pixel companion

- ``WidgetCompanionSprite``
- ``WidgetCompanionPainter``
- ``WidgetCompanionGrid``
- ``WidgetCompanionBody``
- ``WidgetPixelLook``
- ``WidgetCompanionInk``
- ``WidgetCompanionLook``
- ``WidgetFeelingFace``
- ``WidgetFeelingMotif``
- ``WidgetFeelingSprites``

### Pixel art, hearts and water

- ``WidgetSprite``
- ``WidgetSprites``
- ``WidgetSpritePaint``
- ``WidgetSpriteView``
- ``WidgetHeartFill``
- ``WidgetHearts``
- ``WidgetHeartRow``
- ``WidgetWater``
- ``WidgetDropRow``

### Water

- ``FernletWaterWidget``
- ``WaterSmallView``
- ``WaterPlusButton``
- ``WaterLockView``
- ``FernletWaterControl``
- ``WaterControlValueProvider``
- ``WaterPlusOneIntent``

### Stamps

- ``FernletStampWidget``
- ``StampWidgetView``
- ``StampSmallView``
- ``StampMediumView``
- ``StampFeatureText``
- ``StampLatestRow``
- ``StampRibbon``
- ``StampFirstWaiting``
- ``WidgetStampDisc``
- ``WidgetStampShelf``
- ``StampWords``
- ``WidgetStampKind``
- ``WidgetStampArt``

### Map widget

- ``FernletMapWidget``
- ``FernletMapProvider``
- ``FernletMapEntry``
- ``FernletMapWidgetView``
- ``MapWidgetCard``
- ``MapWidgetGround``
- ``MapWidgetPlate``
- ``MapWidgetMacroBars``
- ``MapWidgetTag``
- ``WidgetMacros``
- ``WidgetMapPicture``
- ``WidgetMapPictureRead``
- ``WidgetMapPictureStore``

### Theme

- ``WidgetTheme``
- ``WidgetFixedInk``
- ``WidgetPaperFrame``
- ``WidgetFont``

### App-group bridge

- ``WidgetSnapshot``
- ``WidgetCompanionState``
- ``WidgetCompanionEmotion``
- ``WidgetEmotionTimeline``
- ``PendingWidgetAction``
- ``WidgetDayKey``
- ``WidgetDayGate``
- ``WidgetBridgeFiles``
- ``WidgetSnapshotStore``
- ``PendingWidgetActionWriter``
- ``AppGroupRunStateStore``
- ``AppGroupRunStatePersistable``

### Live Activity look

- ``LiveActivityLook``
- ``LiveActivityIslandLook``
- ``LiveActivityFont``
- ``LiveActivityCard``
- ``LiveActivitySprite``
- ``LiveActivitySprites``
- ``LiveActivitySpriteView``
- ``LiveActivityButtonRole``
- ``LiveActivityButtonFace``
- ``LiveActivityIslandButtonFace``
- ``LiveActivityHeaderLabel``
- ``LiveActivityProgressSquares``
- ``LiveActivityPausedCard``

### Live Activity reflection

- ``LiveActivityRunReflectable``
- ``LiveActivityReflector``

### Guided-workout Live Activity

- ``WorkoutActivityAttributes``
- ``WorkoutLiveActivity``
- ``GuidedWorkoutRunState``
- ``GuidedWorkoutRunStateStore``
- ``GuidedWorkoutActivityBridge``
- ``WorkoutActivityLoadText``
- ``WorkoutActivityZoneText``
- ``GuidedWorkoutMarkSetDoneIntent``
- ``GuidedWorkoutSkipRestIntent``
- ``GuidedWorkoutAddRestIntent``
- ``GuidedWorkoutShortenRestIntent``
- ``GuidedWorkoutIntentRunner``

### Cooking-mode Live Activity

A multipart recipe (a dressing made first, then the salad) walks part by part. Each run step may carry
its part's name (``CookingRunState``'s optional `partName` key, absent on runs persisted before parts
existed), and the content state's step text leads with it ("Lemon dressing · Whisk the oil…"). That
puts the part on the Lock Screen without a new content-state field or a widget-view change.

- ``CookingActivityAttributes``
- ``CookingLiveActivity``
- ``CookingRunState``
- ``CookingRunStateStore``
- ``CookingActivityBridge``
- ``NextCookingStepIntent``
- ``RepeatCookingStepIntent``
- ``CookingIntentRunner``
