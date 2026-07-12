# Fernlet Specification v3

Working name. Domain: `fernlet.com` (also owned: `dewpip.com`).

Fernlet is a tamagotchi-of-yourself iOS health app emphasizing gentle, consistent self-care over optimization and streaks.

This document captures the product and architecture requirements from the v3 specification provided on 2026-05-16. Treat it as the canonical implementation reference for future work.

## 0. Prototype Decision Layer

The production specification remains privacy-first and module-enforced. Current prototype and web proof-of-concept builds may use a narrower feature set and simpler storage so the product shape can be tested quickly. Prototype exceptions must be labeled as such and must not silently become production privacy policy.

Current prototype priorities:
- Phase 0 is data model and storage: define the local domain model, replace prototype `UserDefaults` blobs where practical, and remove Notion as an implementation dependency/source of truth.
- All logging writes (`MealLog`, `Workout`, `HygieneLog`, `HydrationLog`) must accept an explicit `date` parameter from day one — never assume "today" as a hardcoded write target. This is required for past-date backfill and Day Detail editing.
- Integrate the new storage layer into the current SwiftUI work that came from the website before adding large new systems.
- Add goal-based scoring for the six goal types: Wellness, Strength, Weight Management, Mental Health, Recovery, and Exploring.
- Add sickness mode with a Settings toggle, sick avatar state, exercise-weight redistribution, and hydration target bump.
- Add all per-feature deterministic AI fallbacks before adding or expanding AI integration. Logging flows must keep working when AI is unavailable, rate-limited, disabled, or not implemented.
- Add a meal retry queue: failed meal analyses save immediately as manual/pending entries with a tap-to-analyze-later action.
- Add voice-matched messaging for errors, empty states, and fallback states. User-facing failures should sound like Fernlet, not transport errors.
- Add AI status indicator in Settings: `AI ready`, `AI sleepy` for low usage remaining, `AI resting` for unavailable/rate-limited, and `AI off` for manual mode.
- Add recipe parsing with a manual fallback.
- Add derived signals and log trends to local storage.
- Add a prototype Tier 2 memory store locally. Production Sensitive Memory remains sealed, opaque, non-exportable, and never transmitted.
- Add Journal day history browsing: a Day Detail sheet showing all data logged for any past day, month navigation with chevrons, and past-date food and workout logging.
- Begin proximity handshake and local file sharing not too long after fallback-first solo features are stable.
- Add a trainer/nutritionist sharing surface that can share workouts, nutrients, derived trends, and other explicitly selected relevant data over local Bluetooth/proximity only. Whether this is an in-app view or a companion app is an open product decision.
- Add three to five low-cost ambient features before larger systems.

Prototype implementation status as of 2026-05-28:
- Local JSON repository is active for current app state (`LocalFernletRepository`) and persists days, settings, meals, journals, workouts, retry queue, food items, recipes, daily scores, memories, goals, and workshop data. The Core Data shell remains present, but current feature state is backed by the local repository.
- Food and recipe work now uses a bundled USDA FoodData Central subset in `USDAFoodItems.json`, generated from Foundation Foods April 2026, SR Legacy April 2018, and a curated Branded Foods April 2026 subset. The bundled file is a reduced read-only JSON resource, not SQLite, and currently contains 13,104 foods; 13,078 include at least one micronutrient and 12,302 include USDA portion or serving gram weights. No USDA API is used at runtime.
- Ingredient search is local and indexed in memory for the recipe sheet. It normalizes punctuation/case, token-matches out-of-order USDA names, and does not show suggestions until at least 3 characters are entered.
- Recipe ingredient lookup supports selected USDA items with read-only macros and unmatched manual items with editable macros.
- Recipe unit selection uses a fixed picker (`g`, `oz`, `cup`, `tbsp`, `tsp`, `each`, `serving`). USDA `foodPortions` gram weights are used for mass/volume conversion when available; generic conversions are fallback only.
- Recipes are create/edit capable, searchable by recipe name and ingredient names/categories, and support optional notes.
- Recipe export is implemented through the iOS share sheet as readable text plus an embedded `fernlet.recipe` JSON payload for future import support. Import is not implemented yet.
- App lock is implemented: passcode and biometric gates (`FernletLockService`) with scrypt key derivation, monotonic anchor, and reboot detection. Period tracker with sealed menstrual narrative (ChaChaPoly per-column storage, HKDF column keys) is implemented.
- Mesh networking Phase 1 through group-encryption hardening are implemented: `MeshMultipeerSession`, `MeshNetworkManager`, admission tokens, open/closed mode, block model, `MeshAdmissionPromptSheet`, and `FriendListView` all exist. The legacy `MeshLobbyView` has been removed; the active flow is the single-Join `ConnectView` / `DisposableCameraView` surface.
- **Life-tab redesign (workstreams B + C) is implemented:** The Connect surface uses a single **Join** button; peers are committed via a 15 cm / 0.8 s UWB proximity gate (manual confirm fallback on non-UWB). One committed peer = pairwise; two or more = mesh (auto-promoted in place). In session, `ConnectView` shows `DisposableCameraView`: small live viewfinder, 27-shot film counter, shutter gated behind a thumbwheel wind gesture, photos hidden until "Develop" triggers the existing review-and-save flow (`FriendPhotoReviewSheet`).
- Foundation Models is wired for meal-candidate selection (`FoundationFoodSelection`), overnight day summaries, and thought bubbles. No third-party or OHTTP AI path exists yet; all AI is on-device.

Stretch goals (not yet prioritized):
- Historical data import from external sources (Apple Health XML export, CSV from apps such as MyFitnessPal or Cronometer, manual paste). Foundation Models maps imported rows to Fernlet data types so new users can seed historical data at setup.

Deferred for current prototype builds:
- Period tracker and period-aware scoring are deferred until data protection and sealed module boundaries exist.
- Customization, wardrobe, milestones, background composer, and Creation Studio are deferred to v8.
- Photowall, gallery, journal photos, and photo surfacing are deferred.
- Coaching tone profile is deferred.
- Avatar event reactions are deferred.
- Historical daily snapshots can remain live-only for now.
- Cloud-backed multi-person group sharing is deferred until local proximity handshake and file sharing work reliably.

Recommended first ambient subset:
- Year-ago journal card.
- Context-aware thought bubble template bank.
- Macro-gap meal suggestions from the user's own history.
- Forgotten-good-things prompts from recent meal/workout history.
- Preventive care thought bubbles.

## 1. Overview and Design Philosophy

Core thesis: Fernlet is a small persistent character whose state reflects how the user has treated themself over a rolling 24-hour window. The app rejects optimization framing and focuses on consistent-enough self-care.

Design axioms:
- Enough, not everything.
- No streaks. Unlocks must be cumulative and non-resettable.
- No calorie targets, target weight, body composition, or aesthetic goals.
- Privacy by architecture, enforced through module boundaries and types.
- Friends see fuzzy vibes, never numbers.
- Gentle gamification: the tamagotchi reacts but does not punish.
- Friend primitives require physical co-location.
- Gentlest exactly when life is hardest: sickness softens scoring and hard journal tags still count.

Platform requirements:
- iOS 26 or later for Foundation Models.
- Full AI features require Apple Intelligence-capable hardware, with graceful degradation elsewhere.
- Proximity features require NearbyInteraction-capable devices with UWB support.
- Apple Watch is optional but useful for sleep stage data and continuous heart rate.

Explicitly not building:
- No chat interface.
- No year-in-review data story.
- No predictive scoring.
- No compare-to-others metrics.
- No data-gap shaming.
- No face recognition.
- No remote-only friend features.

## 2. Identity and Cryptography

On first install, generate:
- Ed25519 signing keypair using `Curve25519.Signing.PrivateKey`.
- X25519 key agreement keypair using `Curve25519.KeyAgreement.PrivateKey`.

The Ed25519 public key is the only persistent identifier shared with peers. Private keys never leave Keychain.

Keychain storage:
- Store CryptoKit raw key bytes as `kSecClassGenericPassword` items.
- Service: `com.fernlet.identity`.
- Accounts: `primary-ed25519`, `primary-x25519`.
- Accessible after first unlock.
- Synchronizable enabled for iCloud Keychain.

> **Decision needed (identity key sync):** The specification states identity keys are synchronizable, but the current implementation stores them with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-local, not synchronizable. This means the sealed-backup iCloud Keychain recovery story does not hold on a new device. Choose: (a) make identity keys synchronizable to match the spec's recovery design, or (b) change the spec to "device-local keys; recovery via the deferred recovery-code mechanism only." Document the chosen direction before enabling encrypted backup in production.

Secure Enclave is not used because Secure Enclave does not support Curve25519 keys.

Sealed store encryption key derivation:
- When encrypted sealed store backup is enabled, derive a symmetric key from the X25519 private key using HKDF-SHA256 with a fixed `com.fernlet.sealed-backup` info label.
- Encrypt sealed backup payloads with AES-GCM (256-bit key, random 96-bit nonce per payload).
- The X25519 private key is already in iCloud Keychain with `kSecAttrSynchronizable` enabled. On any device the user signs into with the same Apple ID and Keychain access, the derived key is automatically available.
- Key recovery: the iCloud Keychain sync is the primary recovery mechanism. If iCloud Keychain is unavailable on a new device, encrypted sealed data cannot be decrypted. The user must be informed of this at the time they enable encrypted backup. A formal recovery code mechanism is deferred to a production hardening phase.

Trust model:
- Trust on first use for friend public keys.
- Future handshakes must be signed by the same key.
- Key changes trigger a re-pair prompt.
- Trust, block, and revoke decisions key on the **full 32-byte Ed25519 signing public key**, not a short fingerprint prefix. The displayed fingerprint (≥16 hex characters) is a human-readable verification aid only — never the primary key for trust decisions.
- Friend handshakes require a physical-proximity confirmation: a UWB ≤-threshold tap when hardware supports it, or an explicit user confirmation step on non-UWB devices. Auto-proceeding on transport connect alone is not sufficient for friend mode.

## 3. Data Model and Storage Architecture

Storage zones:
1. Device encrypted local store: most app data. Synced to CloudKit private database (opt-in, default on).
2. Device-sealed store: period data, sensitive memory, and photo bytes. AI/cloud modules cannot import raw types. Sealed types may be backed up to CloudKit as client-side AES-GCM encrypted blobs (see Section 19); period data backup is a separate hard opt-in. Once Phase S2 is complete, journal text/emotions and local intimacy notes also join this sealed store. Sealed Core Data entities must be in a **non-CloudKit-mirrored** store configuration; period date metadata (dateKey, createdAt) must not appear in the CloudKit-synced store.
3. Cloud minimal store: friend links, fuzzy state, ephemeral hearts, activity rosters.
4. Transient inference context: exists only during Foundation Models or Core ML calls.
5. Bundled read-only reference store: production target remains a compact USDA FoodData Central reference store plus curated entries for major restaurant chains. Current prototype ships a reduced JSON resource generated from Foundation Foods April 2026, SR Legacy April 2018, and a curated Branded Foods April 2026 subset (`USDAFoodItems.json`, 13,104 foods; 13,078 include at least one micronutrient and 12,302 include USDA portion or serving gram weights). This resource is never written to by the app; user-added/manual `FoodItem` records go into local app storage. Lookup checks the local food table seeded from the bundle plus user-added records.

Core device types:
- `User`: display name, goal type, macro goals, AI provider settings, and AI mode/status preference.
- `AIStatus`: prototype-visible status enum: `ready`, `sleepy`, `resting`, `off`. Production implementations may derive this from on-device availability, third-party quota, local manual-mode preference, and recent failures.
- `FoodItem`: a single ingredient or menu item. Fields: name, brand/source, servingSize, servingUnit (gram, oz, cup, tablespoon, teaspoon, ml, item, slice), macros (protein, carbs, fat), calories, micronutrients (see below), category (`.restaurant`, `.ingredient`, `.packagedGood`, `.produce`), source (`.usdaBundle`, `.aiResolved`, `.userAdded`), verificationPolicy (`.never`, `.yearly`, `.biannual`), lastVerified date, isFlagged bool, tags, and optional portion gram weights. All micronutrient fields are optional — absence means data not available, not zero. Prototype status: macros, USDA portion gram weights, and available USDA micronutrients are populated in the bundled JSON subset.
- `Micronutrients`: optional per-serving values captured on `FoodItem` and snapshotted on `MealLog`. Fields: fiber (g), sugar (g), saturatedFat (g), cholesterol (mg), vitaminA (µg RAE), vitaminC (mg), vitaminD (µg), vitaminE (mg), vitaminB12 (µg), folate (µg DFE), calcium (mg), iron (mg), magnesium (mg), potassium (mg), sodium (mg), zinc (mg), omega3 (g).
- `RecipeDefinition`: user-created recipe. Fields: name, servings, ingredients (array of `RecipeIngredient`: foodItemId, foodItemNameSnapshot, quantity, unit), perServingMacros (computed), perServingCalories (computed), perServingMicronutrients (computed, optional), notes, source (`.userBuilt`, `.aiParsed`), createdAt, updatedAt. Macros and micronutrients are computed live from current ingredient values. If an ingredient's `FoodItem` is updated, a "nutrition may have changed" notice surfaces on next view — no silent retroactive change. Prototype status: recipes can be created, edited, searched, noted, and exported; import and nutrition-change notices remain future work.
- `MealDefinition`: reusable meal template, optionally assembled from `FoodItem` references. Stores macro and micronutrient values at creation time.
- `MealLog`: timestamped record with a reference to a `MealDefinition` or `RecipeDefinition` plus the target date. Stores a frozen `macroSnapshot`, `calorieSnapshot`, and `micronutrientSnapshot` captured at log time. Snapshots never change after logging — editing the source recipe or meal definition does not retroactively alter past logs.
- `Workout`: exercise details, duration, HealthKit refs, heart rate, active energy, source.
- `JournalEntry`: date, color tag, <=100 words, derived emotions, optional photo reference.
- `HygieneLog`: date and toggles.
- `HydrationLog`: date, container units, container type.
- `SleepRecord`: HealthKit-derived sleep data and derived quality score.
- `SicknessFlag`: active sickness window.
- `DailyHealthScore`: stored snapshot with component scores, weights, avatar state, sickness override, optional period phase enum, and `daySummaryText` (optional cached <50-word AI-generated plain-language summary of the day; generated overnight by Foundation Models; never regenerated unless that day's logged data changes).
- `ScheduledSnapshot`: per-day random 2pm-10pm local snapshot schedule.
- `DerivedSignal`: cached derived signals such as mood trend, energy trend, progression trend, intensity readiness, eating pattern, and log trends. Prototype builds store these locally; production builds keep derived signals on-device unless a specific privacy-reviewed sync path is added.
- `AIAnalysisRetry`: pending analysis item for meals, journals, recipes, or other AI-assisted flows that saved successfully but still need analysis retry.
- `CoreMemory`: user-visible memory, editable and deletable.
- `CoachingToneProfile`: bounded tone adaptation.
- `UserCreation`, `CreationCredit`, `CustomizationItem`, `UserCustomization`, and `MilestoneProgress` for wardrobe/background systems.

Device-sealed types:
- `PeriodEntry`, `PeriodCycleHistory`, `PeriodPrediction`, `PeriodHealthTrend` in `PrivateHealthStore`.
- `SensitiveMemory` in `PrivateMemoryStore`.
- `Photo` in `PrivateMediaStore`.

Cloud-minimal types:
- `Friend`: display name, public key, fuzzy state, last active.
- `FriendLink`: peer relation.
- `Activity`: creator, title, type, participants, optional coarse location.
- `ActivityJoinToken`: ephemeral group activity trust token.
- `HeartSent`: ephemeral, ~24h, rate-limited.

Module boundaries are part of the privacy guarantee. `OHTTPProvider` must not import raw period types, period bridge signals, sensitive memory, photos, or raw journal text. `PrivateMediaStore` must not be importable by AI providers. `MemoryExtractionContext` must not import period modules.

## 4. Period Context Bridge

`PeriodContextBridge` is the only path from private period data to scoring or AI systems. It imports `PrivateHealthStore` read-only and exports abstract signals only:
- `PeriodPhaseSignal`
- `PeriodNutritionSignal`
- `PeriodExerciseSignal`

The bridge must not export raw period rows, exact historical period dates, symptom details, sexual activity data, or anything that can reconstruct a log.

Bridge signals are recomputed on demand and not cached independently. Deleting period data immediately causes bridge outputs to return `.unknown` or `.noData`.

Period predictions use pure calendar math, not AI:
- Rolling mean from last 6-12 completed cycles.
- Standard deviation for confidence window.
- Minimum 3 completed cycles.
- Weighted average for flow and duration.

Period health trends use statistical correlations in a `BGProcessingTask`, not AI:
- Sleep by phase.
- Mood by phase.
- Exercise by phase.
- Nutrition by phase.
- Symptom correlations.

## 5. HealthKit and Sensor Integration

Read authorization:
- Heart rate.
- Active energy burned.
- Sleep analysis.
- Step count.
- Workouts.

Write authorization:
- Fernlet writes logged workouts to HealthKit so they count in Apple Health and Apple Watch activity rings.
- Fernlet does not write sleep, hydration, journal, mood, hygiene, or period data.

Workout sync:
- Fernlet-created workouts are written to HealthKit and store the resulting HealthKit UUID.
- HealthKit workouts not already linked are imported into Fernlet.
- Deduplication is based on HealthKit workout ID and source metadata.
- Settings include a HealthKit write-back toggle.

Sleep quality derivation:
- With stages: weighted total of sleep duration, deep ratio, REM ratio, and awakening penalty.
- Without stages: fallback to total sleep hours divided by age target.

WeatherKit is used only for gentle mood-recovery prompts and can use coarse location.

### 5.1 Intimate Tracking Placeholder

Intimate tracking is a planned optional HealthKit-backed capability. This section is intentionally a placeholder for future product and privacy detail.

Current guardrails:
- Hidden by default and not requested during onboarding.
- Available only when the manual body profile age is 18 or older.
- HealthKit sexual activity access is requested only after the age gate passes and the user explicitly enables the feature.
- Local prototype storage stays minimal; event counts are acceptable, while event details are deferred pending a privacy review.
- Revocation happens through iOS Health permissions; Fernlet guides the user to Settings rather than implying in-app revocation is possible.

To define later:
- Product purpose and user-facing copy.
- Data fields, if any, beyond aggregate counts.
- Whether any local non-HealthKit manual logging exists.
- Retention, deletion, export, and visibility rules.
- Interactions with cycle tracking, scoring, AI, sharing, and sensitive memory.

## 6. Scoring and Wellness Formula

Formula:

```text
weightedTotal = sum(weight_i * componentScore_i)
```

Components:
- Food.
- Exercise.
- Sleep.
- Hydration.
- Hygiene.
- Journal.

Goal weight vectors (each row sums to 1.0):

| Goal           | Food | Exercise | Sleep | Hydration | Hygiene | Journal |
|----------------|------|----------|-------|-----------|---------|---------|
| Wellness       | 0.20 | 0.20     | 0.20  | 0.10      | 0.10    | 0.20    |
| Strength       | 0.25 | 0.30     | 0.20  | 0.10      | 0.05    | 0.10    |
| Weight Mgmt    | 0.30 | 0.25     | 0.20  | 0.10      | 0.05    | 0.10    |
| Mental Health  | 0.10 | 0.10     | 0.25  | 0.05      | 0.20    | 0.30    |
| Recovery       | 0.10 | 0.05     | 0.30  | 0.10      | 0.25    | 0.20    |
| Exploring      | 0.18 | 0.18     | 0.18  | 0.12      | 0.12    | 0.22    |

Weight management goal does not involve calorie targets or deficits. User goal is persisted at storage key `user-goal`, default `wellness`.

Avatar states:
- Thriving: >= 0.75.
- Okay: 0.50-0.74.
- Tired: 0.25-0.49.
- Fainted: < 0.25.
- Sick: manual override. Color: terracotta. Label: "Resting". Rendered with terracotta body, mild blush, and drooped eyes.

Component score notes:
- Food uses macros, variety, healthiness, sufficiency, and micronutrient coverage. Overshooting macros does not punish. Micronutrient signals: a day where logged meals cover ≥50% RDI across most tracked micronutrients provides a soft positive nudge to the food score. A rolling 7-day window where a specific micronutrient is consistently below 25% RDI on days with micronutrient data produces a soft negative signal after 7 days and surfaces a dismissible preventive-care thought bubble after 14 days. Neither signal fires when fewer than 50% of the day's logged meals have micronutrient data, to avoid penalizing incomplete records. RDI reference values use standard adult FDA values; personalization by age, sex, or goal is a future enhancement. No clinical language is ever used in micronutrient nudges.
- Exercise gives a baseline floor for any movement and adjusts intensity match by goal and recovery context.
- Sleep uses derived quality score.
- Hydration uses container units over daily target; sickness and period signals may adjust target.
- Hygiene component score is `completedToggles / totalToggles`.
- Journal gives a 0.5 floor for any entry, including hard days.

`FoodItem` verification policy:
- `.never`: USDA bundle commodity ingredients (flour, oil, eggs, common produce). Nutritional profiles are stable; these are never flagged.
- `.yearly`: AI-resolved ingredients, branded packaged goods. Formula or labeling changes are rare but possible.
- `.biannual`: restaurant and fast food menu items. Menus change seasonally; items may be reformulated or discontinued. When an item is flagged, the next AI-available meal parse re-verifies and replaces the stored values.

`FoodItem` lookup order when parsing a meal description:
1. Exact name match in user's local store → use immediately.
2. Fuzzy match in user's local store or USDA bundle → suggest match; user confirms.
3. No match → AI resolves (Foundation Models inference or web lookup) → save to user's local store → use. Future parses of the same item hit the store directly.

Sickness override:
- Avatar switches to sick regardless of computed score. UI surfaces a small terracotta "resting today" chip on the home screen.
- Exercise weight redistributes proportionally to sleep and hygiene, preserving their existing weight ratio.
- Hydration target increases 20%.
- Sickness state persisted at key `is-sick-{YYYY-MM-DD}` (per calendar day; auto-clears at midnight rollover). Default false.

Snapshot rules:
- One per local calendar date.
- Random intended time between 2pm and 10pm local.
- Rolling absolute 24h window.
- If app is closed, fire on next open with intended timestamp.
- First-day limited history uses a high-but-not-perfect seed.

## 6a. Derived Signals

Derived signals are computed from existing logged data. No AI involved. `computeDerivedSignals(state)` returns `{moodTrend, energyTrend, eatingPattern, progressionTrend, intensityReadiness, computedAt}`. Recomputed after any data save.

`recentWorkouts` state array: cap 30, persisted at `recent-workouts`. Every workout save appends to it.

Signal definitions:

- **moodTrend** (`improving | stable | declining | volatile | insufficient data`): computed from journal emotion tag scores over the last 7 entries. Compare first-half average to second-half average; flag `volatile` if variance is high. Requires ≥4 entries to produce a non-insufficient result.

- **energyTrend** (`high | steady | low | depleted | insufficient data`): derived from today's sleep quality score plus hydration progress. No minimum history required.

- **eatingPattern** (`varied | repetitive | insufficient | on track | insufficient data`): computed from distinct meal names in `recentMeals`. Requires ≥3 logged meals.

- **progressionTrend** (`progressing | plateau | regressing | insufficient data`): derived from recent workout count and average RPE across `recentWorkouts`. Requires ≥3 recent workouts.

- **intensityReadiness** (`ready for hard | ready for moderate | needs light | needs rest`): synthesizes moodTrend, energyTrend, progressionTrend, and the sickness flag. Sickness always forces `needs rest`.

Signal display strings are lowercase and plainspoken. Signals never alarm the user.

Home screen `SignalsCard` shows mood, energy, and readiness as chips. Tapping opens `TrendsModal` with all five signals and plain-language one-line explanations. Move screen header shows "Today's readiness" when `intensityReadiness` is not `insufficient data`. `intensityReadiness` is passed as context to `aiSuggestWorkout`.

## 7. AI Layer and On-Device Intelligence

AI tiers:
1. Apple Foundation Models on-device by default.
2. Third-party AI via OHTTP, explicit per-feature opt-in, off by default.

> **Implementation status (Phase S3 required before any OHTTP path):** Module boundaries (`PrivateHealthStore`, `PeriodContextBridge`, `PrivateMemoryStore`, `PrivateMediaStore`, `ContextBuilder`, `AIProviders`), typed per-request `AIContextPayload` allowlists, the local AI audit log, and the Memory Agent diagnostic filter are **required but not yet implemented**. Tier-2 memory must not reach any prompt except through the Memory Agent. No third-party or OHTTP AI path may be introduced until Phase S3 is complete and import-boundary build checks pass.

Foundation Models notes from Apple documentation:
- `SystemLanguageModel.default.availability` must be checked at runtime.
- Availability depends on Apple Intelligence support and user settings.
- `LanguageModelSession` handles one response at a time.
- Guided generation uses `Generable`, `Guide`, and generation schemas.
- Context window limits must be respected; exceeding it throws a generation error.

Foundation Models is used for:
- Journal emotion extraction.
- Journal memory extraction.
- Sensitive memory rewriting.
- Memory agent retrieval/filtering.
- Natural-language forget/edit parsing.
- Workout suggestions.
- Meal suggestions.
- Recipe parsing.
- Day summary generation (overnight batch; see Day Detail Sheet in Section 15).
- Coaching tone wrapper copy.
- Mental-health diagnostic-language classifier around memory output.

Every AI-assisted feature must have a deterministic fallback:
- Meal analysis falls back to a manual stub with macros zeroed, `confidence: Manual`, and `needsRetry: true`. The original description is added to the meal retry queue (cap 20, persisted at `retry-queue`).
- Workout suggestion falls back to a curated local template library (`WORKOUT_TEMPLATES`) bucketed by energy level (low / moderate / good), two templates per bucket.
- Journal analysis falls back to saving the entry only, returning empty memory sets so the journal write still completes. Entry marked `savedWithoutAI: true`.
- Goal crafting falls back to editable local templates (`GOAL_TEMPLATES`) by goal type and level (beginner / intermediate / advanced).
- Thought bubbles fall back to a hardcoded ambient observation bank (`FALLBACK_THOUGHTS`, ~10 entries).
- Recipe parsing falls back to a manual macro + servings entry form.

All fallback notices use Fernlet voice: "Saved without analysis. You can fill in macros yourself." Never surface raw provider errors, HTTP status codes, or rate-limit language.

Voice messaging bank (`VOICE_MSGS`) categories:
- `loading` — per-feature loading phrases (meal, workout, journal, goal, recipe, thought); pick randomly per use.
- `error` — rateLimit, network, parse, timeout, aiOff, resting, generic.
- `empty` — meals, workouts, journals, goals, memories, signals.
- `status` — one-line status label per AI state (ready / sleepy / resting / off).
- `statusDesc` — longer explanation for the AI status modal.
- `fallback` — per-feature notice shown when a fallback path is used.

All strings match the app's warm, plainspoken voice. Example error tone: "The little one needs a rest" not "Rate limit exceeded."

AI status thresholds and tracking:
- `AI_BUDGET_SLEEPY = 30` calls per day. Status transitions to `sleepy` at this threshold.
- `AI_BUDGET_RESTING = 60` calls per day. Status transitions to `resting` at this threshold.
- `AI_RESTING_COOLDOWN_MS = 300000` (5 minutes). Status also transitions to `resting` if the most recent error was a rate-limit within this window.
- `_aiCallsToday`: date + count, resets at midnight rollover.
- `_aiLastError`: `{type, at}` — error type and timestamp of most recent failure.
- `_aiUserOff`: bool, persisted. User-selected manual mode.
- `getAIStatus()` returns `ready | sleepy | resting | off`. The AI call wrapper refuses calls and throws a voice-matched error when status is `resting` or `off`.

AI status indicator: a small pill visible in the home screen header. Tinted by status (moss for ready, goldenrod for sleepy, lavender for resting, slate for off). Tapping opens a modal with the `statusDesc` explanation.

Settings include an AI mode/status row and a user toggle to flip `_aiUserOff`:
- `AI ready`: feature calls can run normally.
- `AI sleepy`: low quota or constrained availability; prefer deterministic fallbacks for nonessential features.
- `AI resting`: unavailable, rate-limited, model not ready, or provider unreachable.
- `AI off`: user-selected manual mode. All AI features use deterministic fallbacks.

Meal retry queue behavior:
- Failed meal parses save the original description to `retry-queue` (cap 20).
- A badge on the Food tab shows the queued count when greater than zero.
- "Retry queued meals" button at the bottom of the Food screen: iterates the queue, attempts parse on each, upgrades the manual entry in place on success, leaves in queue on failure.
- On app open, if `aiStatus === ready` and queue is non-empty, attempt one automatic retry.

Recipe parsing function shape: `aiParseRecipe(text)` takes up to 4000 characters of recipe text and returns `{name, servings, ingredients: [{name, quantity, unit}], note, quality}`. The parser extracts ingredient names and quantities; macros and micronutrients are resolved by looking up each ingredient in the `FoodItem` table rather than having the AI estimate them. Unresolved ingredients are queued for AI resolution and saved back to the table. Falls back to the manual ingredient builder when AI is unavailable. The recipe modal follows the same two-step pattern as meal entry: paste/parse → review ingredient list + per-serving macros → save.

Retry queue behavior (general):
- Failed meal, recipe, journal-memory, or derived-signal analyses save the user's input immediately.
- The saved item receives a small pending-analysis badge where useful.
- When AI becomes available again, batch retries may run opportunistically if the user has enabled AI.

Vision/Core ML is used for:
- Meal photo analysis.
- Moderation classifier for user-created item designs.

No AI is used for:
- Period predictions.
- Period health trends.
- Scoring formula.
- Milestone progress.
- Closeness score.

Token budgets must be enforced by context builders. Payloads must be typed per request and unit-tested against forbidden fields.

AI audit log records locally:
- Request type.
- Provider.
- Field names, not values.
- Whether period context was included.
- Success or failure.

## 8. Memory System

Two tiers:

Core Memory:
- User-visible, editable, deletable.
- Safe durable facts: people, work, places, pursuits, preferences, themes, injuries/limitations.
- May be included in third-party AI only with explicit opt-in per feature.

Sensitive Memory:
- Opaque to user, never browsable, never exportable, never transmitted in production builds.
- Categories: emotional context, relationship friction, financial stress, grief, intimacy, photo-surfacing exclusion, other.
- Used only by on-device AI through the Memory Agent in production builds.
- Prototype exception: test builds may expose Tier 2 memory in a local debug/prototype view for inspection. This must be labeled as a prototype-only privacy exception, disabled for production, and never described to users as the production privacy model.

Sensitive Memory categories (enum `SENSITIVE_CATEGORIES`): `emotionalContext`, `relationshipFriction`, `financialStress`, `grief`, `intimacy`, `photoSurfacingExclusion`, `other`.

Caps: Core Memory cap follows existing system limits. Sensitive Memory cap: `MAX_SENSITIVE = 150` entries.

Journal analysis extracts both Core and Sensitive memories in a single inference pass. Return shape: `{thoughtBubble, emotions, coreMemories: [...], sensitiveMemories: [...]}`. The prompt must explicitly forbid clinical labels in both sets.

Hard deny list:
- No generated mental-health diagnostic or pseudo-clinical labels.
- `DIAGNOSTIC_PATTERNS` is a regex array matching: depressed, anxious, ADHD, bipolar, traumatized, burned out, codependent, avoidant, OCD, PTSD, insomnia, panic disorder, eating disorder, manic, dissociation, narcissism.
- A `containsDiagnosticLanguage(text)` post-classifier runs on every proposed memory before storage; any match is silently rejected.
- User-provided self-descriptions may be stored only as direct quotes in Sensitive Memory.
- Period data never enters memory extraction because memory extraction cannot import period modules.

Memory Agent is the only reader of memory stores. It filters facts by request type, context type, recency, max facts, and destination.

Natural-language forget: `aiNaturalLanguageForget(command, coreMemories, sensitiveMemories)` returns `{coreToRemove: [indices], sensitiveToRemove: [indices], confirmation: "warm 8–15 word phrase"}`. Confirmations are warm, not transactional ("Forgot anything about your old job." not "2 entries removed.").

User controls:
- Browse Core Memory grouped by category; each entry is inline-editable (tap text → editable input; saving sets `userEdited: true`).
- Browse Sensitive Memory grouped by category in prototype builds only (labeled "visible in test mode — would be invisible in the real app").
- Natural-language forget input applies to both tiers.
- Wipe Core Memory (with confirmation).
- Wipe Sensitive Memory (with confirmation).
- Turn extraction off.
- Export both memory tiers as a single JSON download (Core + Sensitive; production builds may restrict Sensitive export).
- Sensitive Memory cannot be viewed, revealed, or exported in production builds.
- Prototype exception: a readable local Tier 2 view may exist for test builds only, clearly labeled.

## 9. Proximity Handshake Protocol

Prototype direction:
- Proximity handshake should start earlier than cloud-backed friend systems.
- First implementation goal is local identity exchange and local file sharing between two devices.
- Cloud-backed multi-person group sharing comes after the two-device BLE/NearbyInteraction path works reliably.
- Trainer/nutritionist sharing uses the same local-first transport and should not require cloud.

Core architecture:
- **MultipeerConnectivity** (Wi-Fi, peer-to-peer Wi-Fi, and Bluetooth) handles discovery and packet transport via `MCSession`. All `MCSession` instances must use `encryptionPreference: .required`. Sensitive 1:1 payloads (friend photos, trainer attachments) must use `payloadEncryption: .sealedTo(recipientKeyAgreementPublicKey:)` via the existing `IdentityService.seal/open` ChaCha20-Poly1305 path.
- NearbyInteraction handles UWB ranging.

Apple documentation notes:
- `NISession.discoveryToken` is exchanged over a separate transport.
- `NINearbyPeerConfiguration(peerToken:)` starts peer interaction after token exchange.
- NearbyInteraction provides distance/direction and is not secure access control by itself.
- Runtime capability checks are required.

Handshake supports:
- Add friend.
- Join activity.
- Open shop.
- Generic presence/appearance refresh.

Flow:
1. User initiates a handshake flow.
2. App starts BLE advertising and scanning.
3. Both users confirm.
4. Signed handshake packets are exchanged.
5. NearbyInteraction ranging starts.
6. Physical confirmation at <=30 cm.
7. Side effects commit based on intent.
8. Appearance sync always refreshes on successful friend handshake.
9. Session ends; no persistent connection.

Handshake packet includes protocol version, intent, sender public key, display name, avatar snapshot, NI discovery token, optional activity context, nonce, timestamp, and Ed25519 signature.

Group activities use direct host handshakes for small groups and cloud-assisted cascading trust for larger groups.

## 10. Friend System and State Sharing

### Trainer and Nutritionist Sharing

Fernlet should support a local-only professional sharing mode for a personal trainer, nutritionist, coach, or similar trusted helper. The first version should use the same proximity/Bluetooth transport as the handshake system, with no cloud requirement.

Shared data should be explicit and reviewable before transfer. Candidate export bundles:
- Workouts over time, including exercise names, sets, reps, weights, duration, and perceived effort.
- Nutrition summaries over time: macro and micronutrient totals per day from `MealLog` snapshots, meal names, nutrient gaps, and derived eating patterns. Recipe ingredient lists are not exported — only the computed per-serving macro and micronutrient values that were logged.
- Hydration, sleep summary, sickness mode windows, derived signals, and goal type when the user chooses to include them.
- Excluded by default: raw journal text, Sensitive Memory, period data, photos, friend data, location, recipe ingredient details, and any hidden/debug-only prototype fields.

Open product decision: this can be implemented either as another authenticated view inside Fernlet or as a separate companion app. Default recommendation for v1 is an in-app `Trainer/Nutritionist Export` view because it avoids a second app, keeps consent screens close to the data, and can still transfer files locally over Bluetooth/proximity. A separate app should be considered only if the professional workflow needs its own long-lived dashboard, client roster, or App Store positioning.

Friend limits:
- Up to **12 friends total**: 8 core friend slots plus 4 additional close friend slots.
- Close friends are not added as a separate relationship. They are the 4 friends with the highest
  closeness, promoted automatically; the remaining friends occupy the core slots.

Closeness score (deterministic, no AI, trailing 30 days, computed and kept on-device):
- Derived from in-person interaction signals recorded over the last 30 days: in-person friend
  sessions (weighted most heavily, since friend primitives require physical co-location), photos taken
  together, recipes/clothing shared and accepted, and hearts sent and received. More recent days count
  for more than older days (linear decay across the 30-day window).
- Hearts count at most once per direction per day toward closeness, so sending many hearts can never
  outweigh real in-person time.
- Closeness is a private, per-device view. A friend never sees their closeness value or whether they
  occupy one of your close slots. Closeness never leaves the device and is never synced to iCloud.

Close-friend promotion (evaluated once per day at local midnight, with hysteresis to avoid churn):
- The 4 highest-closeness friends hold the close slots. An empty close slot fills freely with the
  next-highest friend.
- To keep the close circle stable, a challenger displaces the lowest-scoring close friend only when it
  leads by a clear margin, and a newly promoted close friend keeps its slot for a short minimum period
  before it can be challenged. At most one close slot changes per day.
- Blocking, removing, or revoking a friend frees their slot immediately.
- When you already have 12 friends, adding another drops the lowest-closeness core friend to make
  room (or declines the new friend) — a close friend is never dropped to admit a new acquaintance.

Friends see:
- Fuzzy state only: thriving, okay, struggling.
- Cached appearance from last in-person handshake.
- Send-heart button.

Friends never see:
- Numeric score.
- Component breakdown.
- Goal type.
- Cycle phase.
- Raw health data.

Hearts:
- Rate-limited to one per friend per day.
- Receiver gets decaying health-bar bonus segments for about 24h.

## 11. Photowall

Purpose: photos of real moments, not curation.

Rules:
- Photos are stored in `PrivateMediaStore` with encryption.
- Photos are never sent to AI or cloud.
- No face recognition.
- People tags come from handshake metadata or manual tagging.
- Hard cap of 1000 photos, warning at 900, FIFO eviction at 1000.

Sources:
- One photo per participant during active handshake.
- One photo per journal entry; camera first, library behind extra tap.

Photos stay in `PrivateMediaStore` by default and are not synced to iCloud Photos. They are included in standard iCloud device backup through the app container. A user may explicitly save an individual photo to their system Photos library via a "Save to Photos" action; this is an intentional one-way export, not automatic sync. `NSPhotoLibraryAddUsageDescription` covers this write.

Memory-aware exclusion:
- Sensitive Memory can hold `photoSurfacingExclusion` facts.
- Surfacing filters out excluded people and recently shown photos.

## 12. Ambient Features

Ambient features should avoid dashboards, charts, percentiles, comparisons, and nags.

Features:
- Loading-screen companions during AI inference.
- Gentle pattern observations.
- Reappearance of forgotten good things, max once per month per category.
- Seasonal rhythm recognition after roughly one year.
- Symmetric privacy-clean friend activity suggestions.
- Matched struggling-state heart nudges.
- Meal suggestions from user history and macro gaps.
- Gentle mood-recovery prompts using WeatherKit.
- Shopping lists via share sheet and optionally Reminders.
- Tamagotchi reactions to logged events.
- Wardrobe unlocks from cumulative patterns.
- Optional temporary background auto-decorations.
- Preventive-care thought bubbles.
- Year-ago journal card.

Prototype ambient subset:
- Start with three to five low-risk features that do not require photos, friends, coaching profiles, or sealed stores.
- Preferred first set: year-ago journal card, context-aware thought templates, macro-gap meal suggestions, forgotten-good-things prompts, and preventive-care thought bubbles.
- Avatar event reactions are explicitly deferred for the current prototype even though they remain part of the production concept.

### Prototype Ambient Feature Specifications

**Looking-back journal card (Journal screen):** Show a card above today's entries if an entry exists from approximately N days ago. Try 365, 180, 90, 30 in that order — use the most recent match. Card shows relative date label ("a year ago", "six months back", etc.), the entry's color tag, and entry text. Styled with a goldenrod left border to distinguish it from regular entries.

**Macro-gap meal suggestion (Food screen):** After macro rings, if today has a meaningful gap in any macro (>15g remaining) and `recentMeals` contains a meal high in that macro not already logged today, show one suggestion card: "A nudge — protein gap of 40g" + meal name + macros + "tap to log again." Tapping copies the meal to today. Empty/insufficient state renders nothing.

**Forgotten favorites (Food screen):** Meals from `recentMeals` that appear 2+ times historically but have not been logged in the last 7 entries. Display as small tappable chips with a goldenrod tint. Section label: "Haven't had in a while." Limit to 3. Empty state renders nothing.

**Ambient signal observations in thought bubble:** When generating the ambient home thought, pass `derivedSignals` to the prompt so the model may surface a high-confidence observation ("You tend to sleep better the weeks you move more often"). This is a prompt-level change, not new infrastructure.

**"Today's intent" empty state (Home screen):** If by mid-afternoon (local time >= 14:00) the user has logged nothing, show a single voice-matched line: "Most of the day is still here." Dismissible; does not repeat that calendar day.

**Micronutrient gap observations (preventive-care thought bubble variant):** After 14 consecutive days where a specific micronutrient is consistently below 25% RDI on days with micronutrient data, surface a single dismissible preventive-care thought bubble in Fernlet voice. Example: "You haven't had much vitamin C lately — citrus, peppers, and broccoli are good sources." Never uses clinical or deficiency language. Does not repeat for the same nutrient within 2 weeks of dismissal. Does not fire if fewer than 50% of logged meals have data for that nutrient (to avoid false positives from incomplete records).

All ambient features are either dismissible or ephemeral (today only). Each has an insufficient-data path that renders nothing rather than a "no data" card.

## 13. Onboarding and Permissions

Onboarding: 6 screens max.
1. Welcome and privacy promise.
2. Goal selection.
3. Starter customization.
4. Optional personal details.
5. Dietary pattern.
6. HealthKit and notification permissions.

Tier 1 onboarding data:
- Goal required.
- Age bracket required.
- Biological sex optional.
- Height optional.
- Current weight optional and never tracked over time.
- Dietary pattern optional.

Tier 2 contextual data:
- Exercise context on first Exercise use.
- Food preferences on first food log.
- Hydration container on first hydration use.
- Period context on first Period use.
- Friends via proximity handshake.

Never collect exact weight goals, target weight, weight history, body fat, diagnoses, medications, or social-demographic data.

Permissions are requested at first use where practical:
- HealthKit read/write.
- Bluetooth.
- Camera.
- Photo Library Add.
- Notifications.
- Coarse location for WeatherKit.
- Background App Refresh.

## 14. Milestones, Unlocks, and Customization

Starter customization:
- Hair, eyes, skin, glasses, clothing color, bottle, accessibility items.
- No body type selection; one silhouette.

Unlock rules:
- Every unlock is cumulative and non-resettable.
- No streak-like conditions.
- No weight/calorie/body-composition unlocks.
- No friend count target.

User-created items:
- One credit per 30 cumulative days of app use.
- Cap of 3 credits.
- Drafts unlimited; publishing costs 1 credit.
- On-device moderation via Core ML and text classifier.
- Sharing only in person via shop access window.

## 15. Screens and Navigation

Primary screens:
- Home / Tamagotchi.
- Food.
- Exercise.
- Journal.
- Hygiene.
- Period.
- Hydration.
- Sleep.
- Friends.
- Photo Gallery.
- Activities.
- Wardrobe and Background.
- Creation Studio.
- Friend Shops.
- Memory.
- Coaching Tone.
- Settings.

Home includes avatar, health bar with heart bonus, equipped container, photowall background, quick log row, subtle live score, preventive-care bubbles, and period prediction bubbles when enabled.

Food shows macro rings only, no calorie number or deficit goal.

Exercise shows suggestion, workout logging, progress, and HealthKit summary.

Journal shows heatmap with month navigation, <=100-word entry, optional photo, year-ago card, entry detail, and day history browsing via Day Detail Sheet.

Period screen is walled off and includes predictions, trends, adjustment toggles, and privacy reaffirmation.

### Day Detail Sheet

Tapping any day in the Journal calendar heatmap opens a modal sheet for that day. The sheet can be dismissed with a swipe or close button.

**Calendar and navigation:**
- Month/year label is flanked by `<` `>` chevron buttons. Navigation goes as far back as the earliest logged data; no hard cutoff.
- Today's date always has a highlight box. When browsing a past month, a "Back to today" pill appears below the month header and snaps the calendar to the current month with today's date highlighted.

**Day Detail content:**
- Day score and avatar state for that day (from stored snapshot if available, otherwise computed live).
- `daySummaryText`: a short (<50 words) AI-generated plain-language summary of the day. Displayed if cached; otherwise shows a quiet placeholder. Never alarming — tone matches Fernlet voice.
- Logged meals for that day: meal names, macro totals. Empty state shows nothing plus a "Log food" button.
- Logged workouts for that day: exercise names, duration, RPE. Empty state shows nothing plus a "Log workout" button.
- Hydration for that day: units vs. target.
- Hygiene for that day: completed toggles.
- Sleep for that day: quality label and hours.
- Journal entry for that day: text and color tag. Read-only — past journal entries cannot be edited or deleted from this view.

**Past-date logging:**
- Food and workout log flows launched from Day Detail pass the target date as a parameter. The write is attributed to that calendar day, not today.
- All other data (hydration, hygiene, sleep) is read-only in Day Detail for now; editing those for past dates is a future extension.
- Empty days (no data at all) show a quiet "Nothing logged this day." line plus Log food and Log workout buttons.

**Day summary generation:**
- Summaries are generated by Foundation Models in a lightweight overnight batch on first app open after midnight.
- The batch covers yesterday and any day within the user's logged history that has no cached summary.
- Once generated, `daySummaryText` is stored on the day's record and not regenerated unless that day's logged data changes (new meal, workout edit, etc.).
- If Foundation Models is unavailable, the summary slot stays empty; no fallback text is substituted.

## 16. Privacy Architecture and Data Flow

On-device (always):
- Raw journal text.
- Sensitive memory.
- Period entries, predictions, trends.
- Photos (stored in `PrivateMediaStore`; included in standard iCloud device backup through app container).
- On-device AI inferences.
- Scoring.
- Meals, workouts, customization, creations.

iCloud Keychain:
- Identity keypairs (Ed25519, X25519). Synchronizable; used as the key recovery path for encrypted sealed backup.

CloudKit private database (opt-in, default on for core data):
- Core device data: meals, workouts, journal entries, hydration, hygiene, sleep records, scoring snapshots, settings, derived signals, core memories. Synced to the user's CloudKit private database. Apple sees this data in its standard CloudKit privacy model.
- Encrypted sealed backup (separate opt-in, default off): sealed store types (sensitive memory, period data) encrypted client-side with AES-GCM before upload. Apple sees only ciphertext. See Section 19 for architecture.
- Period data encrypted backup is a hard opt-in with a dedicated warning modal explaining that period data will leave the device in encrypted form, and that losing iCloud Keychain access on all devices makes this data permanently unrecoverable. Default off.
- Sensitive memory encrypted backup: opt-in, default off. Same key derivation and unrecoverability disclosure.
- Photos: never uploaded to CloudKit. Included in standard iCloud device backup through the app container only.
- Friend and activity metadata: public-key-keyed records only, no health content.

HealthKit:
- Workout samples written with consent.
- No period, mood, journal, hydration, or hygiene data.

Third-party AI:
- Explicit per-feature opt-in only.
- Routed through OHTTP.
- No raw journal text except explicit reflection action.
- No Sensitive Memory.
- No period data or period bridge signals.
- No photos, friend data, or location.

## 17. Third-Party Integrations and Cloud Fallbacks

Default: all third-party AI off.

OHTTP architecture:
- App encrypts payload for gateway.
- Relay sees IP, not content.
- Gateway sees content, not IP.
- Response returns through same path.

Implementation is a multi-week security-sensitive task because iOS has no built-in OHTTP client.

Third-party AI cannot provide period-aware meal/workout adjustments because period bridge signals are stripped and unavailable to `OHTTPProvider`.

## 18. App Store Compliance

Privacy manifest declares:
- Health and Fitness.
- User Content.
- Identifiers: public key only.
- Diagnostics.
- No tracking domains.

App privacy labels:
- Data Used to Track You: None.
- Data Linked to You: Health and Fitness (meals, workouts, sleep, hydration, hygiene — synced to user's own CloudKit private database), User Content (journal entries — synced to user's own CloudKit private database).

> **Label review needed after Phase S2:** If Phase S2 seals journal text and excludes it from plaintext CloudKit sync, the "User Content (journal entries — synced to CloudKit)" label must be revised. Review labels with legal before shipping.
- Data Not Linked to You: Diagnostics.

Note: CloudKit private database sync means health and journal data is associated with the user's Apple ID in Apple's infrastructure, changing the "Not Linked to You" classification for those types. Encrypted sealed backup (period data, sensitive memory) may be considered separately — review with legal before shipping.

Usage descriptions required:
- `NSNearbyInteractionUsageDescription`.
- `NSCameraUsageDescription`.
- `NSPhotoLibraryAddUsageDescription`.
- `NSHealthShareUsageDescription`.
- `NSHealthUpdateUsageDescription`.
- `NSLocationWhenInUseUsageDescription`.
- `NSLocalNetworkUsageDescription` + `NSBonjourServices` (the `_fernlet-*` service families).

> **Reconciled 2026-07-11:** `NSBluetoothAlwaysUsageDescription` is intentionally **not** declared.
> The proximity transport is MultipeerConnectivity over the **Local Network** permission (Bonjour) plus
> NearbyInteraction/UWB — there is no direct `CoreBluetooth`/`CBCentralManager` use, so no Bluetooth
> usage string is required or appropriate. Declare only permissions the app actually exercises.

## 19. iCloud Sync and Encrypted Backup

### Onboarding Storage Choice

During onboarding (step 3 of 8), the user sees a two-card picker: **Sync to iCloud** and **Just on this device**. If existing Fernlet data is detected in iCloud, the first card reads **Restore from iCloud** and shows a summary count of found records. The Continue button is disabled until one card is selected.

This is the primary surface for setting `StoragePreferences.iCloudSyncEnabled`. The choice is persisted immediately to the Keychain via `StoragePreferencesStore` and audited as `onboarding.storage.chosen`.

Default at fresh install: no selection (user must choose). The user may change their choice at any time in Settings → Privacy & Data.

### Core Data CloudKit Sync

Core device types are synced to the user's CloudKit private database using `NSPersistentCloudKitContainer`.

- Sync is opt-in, chosen at onboarding. The user can change it in Settings → Privacy & Data.
- `PersistenceController` is initialised with the user's persisted `StoragePreferences` at first access, so CloudKit is enabled or disabled from the first container load — there is no window where the wrong configuration is active.
- `FernletApp` subscribes to `StoragePreferencesStore` changes. When `iCloudSyncEnabled` or `localBackupExcludedFromiOSBackup` changes, `PersistenceController.reload(with:)` is triggered automatically. This is a safety net for programmatic updates; the Privacy & Data screen also triggers reload directly before updating preferences.
- Conflict resolution: last-write-wins by `modifiedAt` timestamp for most types. Journal entries are append-only; conflicts produce both entries and let the user dismiss the duplicate.
- CloudKit schema versioning must be managed carefully; additive-only changes are preferred to avoid migration requirements.
- The `DerivedSignal` and `DaySummaryText` types are excluded from CloudKit sync by default — they are computed values that can be regenerated locally and their sync is not worth the quota or merge complexity.

### Asymmetric Deletion

Deleting iCloud data (the "Delete iCloud data" action in Privacy & Data) removes all CloudKit records from the user's private database. **HealthKit data is never deleted by this action.** Health samples written by Fernlet remain in Apple Health and must be removed by the user through the Health app if desired. Fernlet's local Core Data store is also unaffected — the local copy of app data is always preserved.

This asymmetry is intentional: iCloud deletion is about removing the cloud copy, not destroying the user's health history.

### Encrypted Sealed Backup

The encrypted sealed backup path covers Sensitive Memory and period data. Each is controlled by a separate opt-in toggle in Settings → Privacy → Backup.

Encryption model:
- Derive a 256-bit symmetric key from the user's X25519 private key using HKDF-SHA256, info label `com.fernlet.sealed-backup`.
- Encrypt each backup payload with AES-GCM: 256-bit key, 96-bit random nonce, authenticated with the payload type and user public key as additional data.
- Store the encrypted blob as a CloudKit `CKAsset` on a `SealedBackupRecord` keyed by the user's Ed25519 public key and payload type.
- Apple sees only ciphertext. The decryption key never leaves the device except via iCloud Keychain sync.

Opt-in UX:
- Each sealed type (Sensitive Memory, period data) has its own toggle.
- Enabling either toggle presents a modal with three pieces of information: (1) the data will leave the device encrypted, (2) Apple cannot read it, (3) if iCloud Keychain is permanently lost, the data cannot be recovered on a new device. The user must tap a confirm button, not just dismiss.
- Period data toggle is a hard opt-in with additional context about the political sensitivity of period data leaving a device in any form, even encrypted.

Key recovery:
- Primary recovery path: iCloud Keychain sync carries the X25519 private key to new devices automatically.
- Fallback: if iCloud Keychain is unavailable, encrypted sealed data is unrecoverable. This is disclosed at toggle-on time.
- A formal recovery code mechanism (generate mnemonic → escrow encrypted key blob) is deferred to a production hardening phase.

### Photos

Photos are not synced to CloudKit. They are stored in `PrivateMediaStore` inside the app container and included in standard iCloud device backup automatically. An explicit "Save to Photos" action lets the user export an individual photo to their system Photos library at their discretion.

## Prototype Guardrails

These temporary decisions apply to the current test/prototype line and should be revisited before production hardening:
- Goal-based scoring and sickness mode are immediate priorities.
- Period tracker is deferred until data protection and sealed stores exist.
- Customization and Creation Studio are deferred to v8.
- Tier 2 memory may be readable in a local debug/prototype view only for test builds.
- Derived signals and log trends are stored locally; Notion is not an active implementation dependency.
- No photowall or coaching profile in the current prototype.
- Score can remain live-only for now; historical snapshot rules remain production requirements.
- AI failures should route to deterministic fallbacks, retry queues, and Fernlet-voice messaging.
- Settings should show AI status as ready, sleepy, resting, or off.

## Guardrails Recap

- No streaks.
- No calorie goals or deficits.
- Fuzzy friend visibility only.
- Hearts one per friend per day.
- Period data walled off by module boundary.
- Soft mental-health nudge only for extended low mood, dismissible, non-repeating, with 988 link.
- No aesthetic goals.
- Sickness softens scoring.
- Period-aware scoring softens only user-specific historically harder phases.
- Third-party AI off by default.
- No face recognition.
- No Private Cloud Compute escalation assumption for third-party apps.
- BLE plus NearbyInteraction for proximity.
- Vision plus Core ML for image analysis.
- Foundation Models and Core ML are stateless for app data.
- Sexual content may exist only in Sensitive Memory under the strongest privacy guarantees.
