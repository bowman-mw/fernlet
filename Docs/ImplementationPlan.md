# Fernlet Implementation Plan

> **Status reconciled 2026-08-09.** This document is the **phase definition + rationale** reference;
> the table below is its status layer, reconciled against the live tracker
> ([RemainingWork-2026-07-19.md](RemainingWork-2026-07-19.md)) plus code spot-checks. The prose
> inside each phase section is **as-written-at-the-time** and is not updated as work lands — read it
> for intent, and take completion state from this table. For the fine-grained list of what is
> actually left, the tracker remains authoritative.

## Phase status at a glance (2026-08-09)

Legend: ✅ shipped · ⚠️ partial (residuals on the tracker) · ⏸ deferred/superseded · 🔜 next up

| Phase | Status | Notes |
| --- | --- | --- |
| **0** — Data model, storage, website port | ✅ | Typed persistence + repositories shipped. |
| **P1** — Prototype scoring & sickness | ✅ | |
| **P2** — Prototype AI resilience | ✅ | Deterministic fallbacks + retry queue. |
| **S1** — Proximity security hardening | ✅ | Full signing-key trust, `.required` encryption, sealed 1:1 payloads, tap gate, envelope expiry. |
| **S2** — At-rest sealing + CloudKit period isolation | ✅ | Sealed entities on a non-mirrored store; `S3BoundaryTests` asserts it. |
| **M1** — Meal-tracking & food-search overhaul | ⚠️ | Core shipped (data-type classification, generic-first ranking, SQLite catalog). Residue: chain-restaurant importer, dynamic product-image discovery — see [Meal-Estimation-Overhaul-Plan.md](Meal-Estimation-Overhaul-Plan.md). |
| **P3** — Memory, derived signals, trends | ⚠️ | Derived signals + trends shipped. Outstanding: editable Core Memory UI, natural-language forget/edit, derived-signal inspection. |
| **P4a** — Food KB, recipes, micronutrients | ⚠️ | Backend shipped (`micronutrientTotals(for:)`); no recipe-builder UI binding yet. |
| **P4** — Ambient, recipe, day-history features | ⚠️ | Most ambient cards shipped; crisis nudge decided-SHIP but unbuilt (see Phase 16). |
| **1** — Baseline hygiene & file split | ✅ | |
| **2** — Scoring v3 | ✅ | |
| **3 / S3** — Privacy modules, AI boundary, sealed stores | ✅ | The `FernletKit` carve-up + compile-time S3 wall, CI-enforced (`Scripts/spm-wall-check.sh`). One optional carve item remains (AI-file inversions, [SPM-Module-Carveup-Plan.md](SPM-Module-Carveup-Plan.md) §14). |
| **4** — Onboarding & permissions | ⚠️ | Flow shipped; production polish outstanding. Known defect: the lock-setup sheet advances on Cancel. |
| **5** — HealthKit integration | ✅ | Residuals: no contextual first-use request (Settings-only), sleep HealthKit summary. |
| **6** — Core screens v3 | ⚠️ | Residual: Move per-exercise progress. |
| **11** (deferred) — Foundation Models on-device AI | ✅ | Shipped, with the provider ladder layered on top — see [AI-Provider-Ladder-2026-07-23.md](AI-Provider-Ladder-2026-07-23.md). |
| **12** (deferred) — Production memory system | ⚠️ | Storage-time classifier shipped; two-tier AI journal extraction deferred. |
| **13** (deferred) — Period tracking & context bridge | ✅ | |
| **14** (deferred) — Photos & photowall | ⚠️ | Shipped. Outstanding: manual people-tagging UI; photo-surfacing exclusion (blocked on the deferred Sensitive Memory store). |
| **7** — Identity, proximity handshake, local file sharing | ✅ | |
| **8** — Trainer/nutritionist local sharing | ✅ | Trainer export + allowlist shipped; the file is now deleted on share completion. |
| **9** — Cloud-assisted multi-person group sharing | ⏸ | Cloud cascading-trust for large group activities deferred by scope. |
| **10** — Friends, hearts, activities, shops | ✅ | Includes remote send-heart (CloudKit E2EE dead-drop, opt-in, default OFF). |
| **15** — Wardrobe, backgrounds, milestones, Creation Studio | ⚠️ | Increment 1 shipped; Increments 2–3 pending — [Custom-Clothing-Plan-2026-06-29.md](Custom-Clothing-Plan-2026-06-29.md). |
| **16** — Ambient features | ⚠️ | Crisis nudge (`moodTrend` → First Aid) decided SHIP 2026-07-19, still unbuilt — closes a safety flag. |
| **17** — Third-party AI via OHTTP | ⏸ | Superseded for the third-party tier by [AI-Provider-Ladder-2026-07-23.md](AI-Provider-Ladder-2026-07-23.md) §8. Cloud/BYOK tracks gated. |
| **18a** — iCloud sync + encrypted sealed backup | ✅ | Outstanding follow-up: BIP39 recovery codes. |
| **18** — App Store readiness | ⚠️ | Code-side done. Remaining steps are **owner-only** in App Store Connect (hosted policy URL, support email, nutrition labels, encryption declaration) plus promoting the `HeartDrop` record type to the CloudKit Production schema. |
| **Coach track** | 🔜 | Not in this plan — specified in [FernletCoach-Specification-2026-07-19.md](FernletCoach-Specification-2026-07-19.md). Primitives shipped; the in-person session manager/UI is the next build. See "Next up" below. |

This plan assumes the current app is a single-target SwiftUI prototype with local `UserDefaults` persistence. The next implementation step is a local data model and storage layer integrated into the SwiftUI work ported from the website. That storage layer replaces Notion as an implementation dependency/source of truth. The production v3 spec still moves toward module-enforced privacy boundaries, typed persistence, HealthKit, on-device AI, and proximity features.

## Planning Assumptions

- Target iOS 26 or later for Foundation Models in the production app.
- Keep all non-AI features functional when Apple Intelligence or third-party AI is unavailable.
- Implement privacy boundaries before implementing any production feature that depends on sensitive data.
- Ship no remote friend behavior until in-person handshake primitives exist.
- Keep third-party AI out of production scope until on-device AI and payload tests are mature.
- AI fallbacks must be built before AI integration so every feature has a durable manual path.
- Notion is no longer an active implementation dependency. Prototype inspection should use local debug/prototype views backed by the app's storage layer.

## Current Prototype Scope

Execution order for the next line was: Phase 0 storage, P1 scoring/sickness, P2 AI fallbacks, P3 memory/signals, P4 ambient/recipe, Phase 1 cleanup, Phase 7 local proximity/file sharing, Phase 8 trainer/nutritionist local sharing, then Phase 9 cloud-assisted group sharing. **As of 2026-05-28, the priority sequence is revised: the next phases are S1 (proximity security hardening), S2 (at-rest sealing and CloudKit period isolation), M1 (meal-tracking overhaul), and S3 (AI privacy boundary), all ahead of the remaining ambient/recipe polish.** Proximity/mesh Phase 1 and much of Phase 2 are already implemented; see Completed Prototype Work below.

The next prototype line prioritizes practical product behavior over the full production architecture:
- In scope now: local data model/storage, goal-based scoring, sickness mode, deterministic AI fallbacks, meal retry queue, Fernlet-voice error/fallback messaging, AI status indicator, recipe parsing, derived signals, log trends, selected ambient features, expanded memory handling, and local proximity/file sharing.
- In scope as prototype-only: readable Tier 2 memory in a local debug/prototype view.
- Coming soon after fallback-first solo features: proximity handshake, local file sharing between devices, and trainer/nutritionist export over Bluetooth/proximity.
- Later after local sharing works: cloud support for multi-person group sharing.
- Out of scope for now: period tracker, period-aware scoring, photowall, coaching tone profile, avatar event reactions, customization/wardrobe/milestones/Creation Studio, and historical snapshot storage.

## Completed Prototype Work as of 2026-05-18

Some prototype work has landed out of the original phase order. This section is the current source of truth for what is already implemented in the app.

Storage and app structure:
- Local JSON repository (`LocalFernletRepository`) is implemented and backs current app state. It persists days, settings, meals, workouts, journals, retry queue, food items, recipes, scores, goals, memories, and workshop data.
- File split is substantially complete for the current prototype: models, store, repository, scoring, food, home, move, journal, settings, shared sheets, and UI components live in separate Swift files.
- Past-date write paths exist for meals, workouts, journals, sleep, hydration, and hygiene. Past-date meal and workout write paths are covered by repository/store tests.
- Derived table records are rebuilt into the local JSON database for daily logs, meal logs, workout logs, journal logs, derived signals, retry queue, Tier 2 memory records, recipes, and daily scores.

Food knowledge base and recipes:
- Bundled USDA data is implemented as a reduced JSON resource (`USDAFoodItems.json`) rather than the originally planned SQLite. It is generated from Foundation Foods April 2026, SR Legacy April 2018, and a curated Branded Foods April 2026 subset.
- Current bundle contains 13,104 foods; 13,078 include at least one micronutrient and 12,302 include USDA `foodPortions` or serving gram weights for measure conversion. Runtime lookup does not use the USDA API.
- `FoodItem` now supports macros, optional micronutrients, tags, verification fields, and optional `FoodPortion` records.
- Recipe ingredient search uses an in-memory `FoodItemSearch.Index`, normalized token matching, and a 3-character minimum before results show.
- Manual recipe creation is implemented with USDA search, selected-item read-only macros, unmatched manual macro entry, quantity/unit controls, and live per-serving totals.
- Unit selection uses a picker (`g`, `oz`, `cup`, `tbsp`, `tsp`, `each`, `serving`). USDA portion gram weights are used first for conversion; generic conversions are fallback only.
- Saved recipes are editable, searchable by recipe or ingredient text, and have optional notes.
- Recipe export is implemented via `ShareLink` as readable text with an embedded `fernlet.recipe` JSON payload. Import is intentionally deferred to the next pass.
- URL recipe import exists through `RecipeWebImporter`/`SavedRecipe` as a separate SwiftData-backed flow; it can log imported recipes as meals, but it is not yet merged with the local `RecipeDefinition` builder/import path.

Scoring, fallback behavior, and tests:
- Goal types, goal scoring weights, sickness redistribution, hydration target behavior, companion states, AI status, deterministic meal/workout/journal/goal fallbacks, retry queue, and Fernlet-voice messages are implemented for the current prototype scope.
- Nutrition profile/preferences, computed nutrition targets, and a first-run onboarding cover/profile/goal flow are implemented. Settings can edit the nutrition profile and display current targets.
- Foundation Models meal selection is implemented behind availability checks for iOS 26+, with deterministic candidate selection as the fallback. This landed before the broader deferred on-device AI provider/audit architecture.
- Test coverage currently includes repository persistence, local database table rebuilds, past-date logging, scoring, sickness redistribution, nutrition targets, food data decoding, ingredient search, unit defaults/conversions, recipe editing, recipe search, and recipe export text.

Navigation and UX:
- Main tabs now support horizontal swipe navigation in `ContentView` in addition to the tab bar.

Proximity and mesh networking:
- `IdentityService` with Ed25519/X25519 Keychain-backed identity, envelope signing/verification, and ChaCha20-Poly1305 `seal/open` with forward-secret ephemeral X25519 is implemented and tested.
- `MultipeerSession` 1:1 transport, `ProximityCoordinator` state machine (identity intro/ack, NI token exchange, tap confirmation, heartbeat RTT), `NIRangingSession`, and `ReplayCache` are implemented and tested.
- Mesh Phase 1 and much of Phase 2 are implemented: `MeshMultipeerSession`, `PeerChannelTransport`, `MeshNetworkManager` (slot table, admission flow, open/closed mode, photo routing, block enforcement), `MeshAdmissionToken`, `MeshNameGenerator`, `MeshLobbyView`, `MeshAdmissionPromptSheet`, and `FriendListView`. Admission tokens, block model, photo-provenance fields, and cache-cap bump are complete.
- App lock (`FernletLockService`) is implemented with passcode/biometric gates, scrypt key derivation, monotonic anchor, and reboot detection.
- Period tracker with sealed menstrual narrative (ChaChaPoly per-column, HKDF column keys) is implemented. CloudKit isolation of sealed entities is not yet complete (see Phase S2).
- Note: the original plan listed Phase 7/8/9 proximity work as future. That work is largely done. Remaining open items are security hardening (S1–S3) and group encryption (Mesh Phase 3/4).

## Phase 0 — Data Model, Storage, and Website-Port Integration

Goal: create the local source of truth and integrate it into the current SwiftUI app ported from the website. This replaces Notion integration for app state.

Tasks:
- Define the first local schema for `User`, `MealDefinition`, `MealLog`, `Workout`, `JournalEntry`, `HygieneLog`, `HydrationLog`, `SleepRecord`, `SicknessFlag`, `DerivedSignal`, `CoreMemory`, prototype Tier 2 memory, recipes, retry queue items, and trainer/nutritionist export bundles.
  - Prototype status: mostly complete as JSON-backed app/domain models. Trainer/nutritionist export bundle types exist, but the export UI and local transfer are not implemented.
- Add `FoodItem` to schema with all fields: name, brand/source, servingSize, servingUnit, macros, calories, micronutrients (17 optional fields), category, source, verificationPolicy, lastVerified, isFlagged, tags.
  - Prototype status: complete for the JSON-backed `FoodItem` shape, including optional USDA portions.
- Add `Micronutrients` as a value type (struct) used on both `FoodItem` and as a snapshot on `MealLog`.
  - Prototype status: complete.
- Add `RecipeDefinition` to schema: name, servings, ingredients array (foodItemId + quantity + unit), computed macro/calorie/micronutrient fields, source, timestamps.
  - Prototype status: complete for local recipes; URL-imported `SavedRecipe` remains a separate SwiftData model.
- Update `MealLog` to store `macroSnapshot`, `calorieSnapshot`, and `micronutrientSnapshot` at log time. Add `mealSource` enum (`.mealDefinition`, `.recipe`, `.manual`). Snapshots are immutable after logging.
  - Prototype status: complete in the current `Meal` model.
- All logging types (`MealLog`, `Workout`, `HygieneLog`, `HydrationLog`) must include an explicit `date` field and all write paths must accept a target date parameter — never hardcode "today" as the write target. This is required for Day Detail past-date editing and historical backfill.
  - Prototype status: write paths accept explicit dates for meals, workouts, journals, sleep, hydration, and hygiene. Some current in-memory log structs still rely on their containing `FernletDay.date` rather than duplicating `date` on every nested record.
- Add `daySummaryText: String?` to `DailyHealthScore` for cached overnight AI summaries.
  - Prototype status: model field and JSON round-trip tests exist; generation is not implemented.
- Bundle the USDA FoodData Central subset as a read-only SQLite file in the app bundle at build time. Extract and include ~5000 common ingredients with full micronutrient data plus curated restaurant chain entries. This file is never written to at runtime.
  - Prototype status: implemented as read-only bundled JSON with 13,104 foods, not SQLite.
- Choose the persistence layer for the prototype-to-production path. Prefer SwiftData unless Core Data migration constraints make the existing Core Data stack more practical.
  - Prototype status: current app state uses local JSON. SwiftData is only used for the separate `SavedRecipe` URL-import path.
- Build repository protocols for each feature area so views do not talk directly to storage.
  - Prototype status: partially complete through `FernletRepository`; feature-area protocols are not split yet.
- Migrate the current in-memory/UserDefaults-style data from the website port into repositories.
  - Prototype status: complete for current app state through `LocalFernletRepository`, including legacy import.
- Remove Notion as a source of truth or required sync path.
  - Prototype status: complete.
- Add local debug/prototype views for Tier 2 memory, derived signals, and log trends if inspection is needed.
  - Prototype status: records exist in storage; dedicated inspection UI remains incomplete.
- Keep the current SwiftUI screens working while swapping their backing store.
  - Prototype status: complete.

Exit criteria:
- All current solo logging flows read/write through the new repository layer with an explicit date parameter.
- App data survives restart through the selected local store.
- No current feature requires Notion to function.
- Tests cover repository save/load for meals, workouts, journals, hydration, hygiene, settings, and retry queue.
- Tests confirm a meal or workout logged for a past date is attributed to that date, not today.

## Phase P1 — Prototype Scoring and Sickness

Goal: implement the highest-impact behavior gaps on top of the new storage layer.

Tasks:
- Add the six goal types: Wellness, Strength, Weight Management, Mental Health, Recovery, and Exploring.
  - Prototype status: complete.
- Add goal-based scoring weight vectors.
  - Prototype status: complete and tested.
- Add component score calculators that can work with the current local data.
  - Prototype status: complete for current score inputs and tested.
- Add sickness mode toggle in Settings.
  - Prototype status: complete.
- Add sick avatar state, hydration target +20%, and exercise-weight redistribution to sleep/hygiene.
  - Prototype status: complete and tested for redistribution.
- Remove any user-facing calorie target or deficit copy.
  - Prototype status: calorie display is hidden by default and no deficit copy remains; onboarding/settings can expose computed targets when enabled.

Exit criteria:
- Changing the selected goal changes the live score composition.
- Sickness mode visibly changes avatar state and scoring behavior.
- Tests cover all goal vectors and sickness redistribution.

## Phase P2 — Prototype AI Resilience

Goal: every AI-assisted feature works when AI is unavailable.

Tasks:
- Add `AIStatus`: ready, sleepy, resting, off.
  - Prototype status: complete.
- Add Settings row for AI status and manual AI-off mode.
  - Prototype status: complete.
- Add deterministic fallback for meal analysis: manual macros form and auto meal type.
  - Prototype status: complete; current meal resolution also uses local USDA candidate matching.
- Add deterministic fallback for workout suggestions: local template library tagged by energy/equipment/goal.
  - Prototype status: complete for goal/intensity templates.
- Add deterministic fallback for journal analysis: save entry; skip or queue emotion/memory extraction.
  - Prototype status: complete for save-first behavior and simple memory extraction.
- Add deterministic fallback for goal crafting: editable local goal templates.
  - Prototype status: complete for local editable goals.
- Add deterministic fallback for thought bubbles: context-aware local template bank.
  - Prototype status: partially complete through local contextual home thoughts.
- Add deterministic fallback for recipe parsing: manual recipe/ingredient entry.
  - Prototype status: complete.
- Add `AIAnalysisRetry` queue for meals first, then journal/recipe analyses.
  - Prototype status: meal retry queue is implemented and tested; journal/recipe retry expansion remains.
- Replace raw errors with Fernlet-voice messages.
  - Prototype status: current message bank exists and is tested for coverage.

Exit criteria:
- No current AI failure blocks logging.
- Pending meal analysis can be retried later.
- User-facing error messages do not expose provider or HTTP details.

## Phase S1 — Proximity Security Hardening

Goal: make the local sharing transport secure by construction, not by convention. Addresses SEC-1 (fingerprint trust), SEC-2 (transport encryption), SEC-6 (friend proximity gate), and SEC-7 (envelope expiry).

Tasks:
- Re-key trust on the **full signing public key**. `isTrusted`, `isRevoked`, and `isBlocked` in `ProximityTrustVault` compare the full 32-byte key (or full SHA-256). The 8-char fingerprint becomes display-only; lengthen the user-facing fingerprint to ≥16 hex.
- In `ProximityCoordinator.handleIdentityEnvelope`, require `storedPeer.signingPublicKey == envelope.senderSigningPublicKey` before any auto-confirm. A fingerprint match alone is not sufficient.
- Set `encryptionPreference: .required` on every `MCSession` (`MultipeerSession` and `MeshMultipeerSession`). Do not negotiate down.
- Send sensitive 1:1 payloads (friend photos, trainer attachments) with `payloadEncryption: .sealedTo(recipientKeyAgreementPublicKey:)` using the existing `IdentityService.seal/open` helpers. The crypto is built and tested; the senders just aren't using it.
- Require a proximity confirmation for **friend** handshakes: UWB ≤-threshold tap when `NIRangingSession.isHardwareSupported`; explicit user confirmation prompt otherwise. No auto-proceed on transport connect.
- Set `expiresAt` on all outbound envelopes. Bind photo/attachment envelopes to the current session/epoch.

Exit criteria:
- A crafted keypair with the same 8-char fingerprint as a trusted peer is rejected — it cannot be auto-confirmed or rejoin via a cached admission token.
- Packet capture of a 1:1 friend photo or trainer attachment shows ciphertext, not plaintext image data.
- A friend handshake cannot complete without a UWB tap or explicit user confirmation.
- A replayed envelope after an app restart is rejected.
- Unit test: `isTrustedProximityPeer` returns false when fingerprint matches but public key differs.

## Phase S2 — At-Rest Sealing and CloudKit Period Isolation

Goal: make "sealed/encrypted" mean every sensitive surface behind the lock gate, and keep period data off the cloud unless explicitly opted in. Addresses SEC-3 (period narrative in CloudKit), SEC-4 (journal/intimacy plaintext), and SEC-8 (metadata leaks).

Tasks:
- Extend the `MenstrualNarrativeRepository` pattern (ChaChaPoly + HKDF column key) to **journal text and emotion tags** and **local intimacy notes**. Gate reads/writes on `contentKey()` from `FernletLockService`.
- Move sealed Core Data entities (`MenstrualNarrative`, future sealed types) into a **non-CloudKit-mirrored** persistent store configuration. A second `NSPersistentStoreDescription` targeting a local-only store file is the recommended approach.
- Add a test asserting that no sealed entity (by entity name) appears in the CloudKit-mirrored store description's managed object model.
- Ensure period data leaves the device **only** via the dedicated AES-GCM sealed-backup path gated by `sealedBackupPeriodEnabled` in `StoragePreferences`.
- Treat period narrative `dateKey` as sensitive: either derive/obfuscate the lookup key or document and accept it as metadata. Prune `NSPersistentHistoryTrackingKey` history for sealed entities on delete.

Exit criteria:
- Journal text and local intimacy note bytes on disk are ciphertext when the lock is set. Disabling the lock / clearing the content key makes them unreadable.
- With iCloud sync enabled but period backup disabled, no period record and no period date metadata (dateKey, createdAt) appears in the CloudKit private database.
- Test: sealed entities are not in the CloudKit-mirrored store model.
- Test: `MenstrualNarrativeRepository` reads and writes round-trip through encryption.

## Phase M1 — Meal-Tracking and Food-Search Overhaul

Goal: correct single-food meal logging and generic-first ingredient search. Root-cause analysis in the 2026-05-28 review document identifies five root causes for the "French fries → three-brand recipe" bug.

Tasks:
1. **Add a data-type classification to `FoodItem`** (`foundation`, `srLegacy`, `branded`/`restaurant`) derived at bundle-generation time and persisted. This is the keystone for the items below.
2. **Generic-first ranking.** Rank `foundation`/`srLegacy` above `branded` in `FoodDataCatalog` unless the query contains a brand/restaurant token. Add a curated brand/chain lexicon. When a chain is named ("McDonald's fries"), flip to restaurant mode and prefer that brand's entries.
3. **Single-best candidate for atomic foods.** In `FoundationFoodSelection` and `deterministicIngredients`, an atomic food (non-composite) yields **one** ingredient — the best match — not `itemCandidates.prefix(3)`.
4. **Composite detection by lexicon, not by count.** Replace `if resolved.count > 1 { createRecipe(…) }` in `MealBuilder` with "is this item a known composite?" using a lexicon (sandwich, burger, bowl, salad, tacos, wrap, stir fry, smoothie, …). Only genuine composites expand into parts.
5. **Dedupe near-identical results.** Collapse multiple brand variants of the same food in search and candidate building; surface one generic with a "more brands" disclosure.
6. **Ingredient-search UX.** Generic first, deduped, grouped; branded/restaurant items behind a disclosure row; show data source label (Foundation, SR-Legacy, Branded) on each row.
7. **Quantity sanity.** Default atomic foods to one realistic portion (USDA `foodPortions` gram weight when present). Make the sandwich/grilled-cheese 2-slice heuristic lexicon-driven.

Exit criteria:
- "French fries" logs **one** generic fries portion, not three branded variants. Macro total is realistic for a single portion.
- Naming a chain ("Wendy's fries") logs that chain's entry.
- "Grilled cheese" still expands to bread + cheese (genuine composite).
- Ingredient search surfaces the generic food first; brand variants are behind a disclosure row.
- Tests: single-food parse returns exactly one ingredient; composite parse returns multiple; chain-named parse prefers the named brand.

## Phase P3 — Prototype Memory, Derived Signals, and Trends

Goal: make memory and signal inspection useful for iteration while keeping all prototype data local.

Tasks:
- Add editable Core Memory entries, not just deletion.
  - Prototype status: memory records exist, but the full edit UI is not complete.
- Add natural-language forget/edit shell; deterministic keyword matching is acceptable before AI parsing.
  - Prototype status: not complete.
- Add Tier 2 memory model in local storage.
  - Prototype status: complete at the storage-record level.
- Label any readable Tier 2 debug/prototype view as test-only and not production-private.
  - Prototype status: dedicated readable debug UI remains incomplete.
- Add derived signals: moodTrend, energyTrend, eatingPattern, progressionTrend, intensityReadiness.
  - Prototype status: storage records and local table rebuild exist; full signal computation/consumer UI remains incomplete.
- Add locally stored log trends and a local inspection view if needed.
  - Prototype status: local record storage exists; inspection UI remains incomplete.
- Add diagnostic-language filter rules even before a trained classifier exists.
  - Prototype status: not complete.

Exit criteria:
- Core Memory can be edited and deleted.
- Tier 2 memory and derived signals are inspectable locally in prototype/debug UI.
- Derived signals feed thought bubbles and workout suggestions.

## Phase P4a — Food Knowledge Base, Recipes, and Micronutrients

Goal: replace macro estimation with a local food reference database and add recipe creation.

Tasks:

**FoodItem lookup system:**
- Build `FoodItemRepository` that queries the user's local SwiftData store first, then falls back to the bundled read-only USDA SQLite.
  - Prototype status: local `foodItems` are seeded from bundled `USDAFoodItems.json`; no SQLite repository yet.
- Implement exact-name and fuzzy-match lookup used by meal parsing and recipe creation.
  - Prototype status: indexed normalized token search is implemented for recipe ingredient search and USDA-backed meal candidate selection; unresolved manual meals can still fall back to deterministic macro estimates.
- When AI resolves a new item (web lookup or Foundation Models inference), save it to the user's local store with `source: .aiResolved` and an initial `lastVerified` date.
- Implement staleness flagging: on app open, scan user's local store for items where `lastVerified` is older than the `verificationPolicy` window and set `isFlagged = true`.
- When a flagged restaurant item is encountered during meal parsing and AI is available, re-verify macros and update the stored record.

**Recipe creation — primary path (paste and parse):**
- Update `aiParseRecipe` to return ingredient names and quantities rather than estimated macros. Resolve each ingredient through `FoodItemRepository`. Queue unresolved items as `AIAnalysisRetry` entries.
- Build two-step recipe modal: (1) paste text → AI parses ingredient list → each ingredient resolved and shown with its source, (2) review per-serving macros/calories/micronutrients → set servings → save as `RecipeDefinition`.
- Surface a "nutrition may have changed" notice on a saved recipe if any of its ingredient `FoodItem` records are updated after the recipe was last viewed.

**Recipe creation — secondary path (ingredient builder):**
- Build an ingredient picker that searches `FoodItemRepository` with a quantity + unit input. Macros and micronutrients update live as ingredients are added or removed.
  - Prototype status: complete for macros and modeled micronutrients using bundled USDA/user food items.
- This is both the manual-fallback path when AI is unavailable and the primary editing interface for saved recipes.
  - Prototype status: saved recipes can be edited in place, logged as meals, and logged recipe meals snapshot macro and micronutrient totals.
- Recipe edits do not retroactively change any `MealLog` that already references that recipe. Past logs keep their frozen snapshots.

**Recipe search, notes, and export:**
- Add recipe list search across recipe names and ingredients.
  - Prototype status: complete.
- Add optional recipe notes to create/edit and row preview.
  - Prototype status: complete.
- Add recipe export through the iOS share sheet.
  - Prototype status: readable text plus embedded `fernlet.recipe` JSON payload is complete. Import is deferred.

**Micronutrient tracking:**
- Update `MealLog` write path to capture `micronutrientSnapshot` from the resolved `FoodItem` values at log time.
  - Prototype status: complete for USDA/recipe-resolved local meals; manual fallback meals can still have empty micronutrient snapshots.
- Add micronutrient summary to the Day Detail Sheet: show a simple breakdown of key nutrients for the day alongside macros.
  - Prototype status: not complete.
- Build rolling 7-day and 14-day micronutrient window computation as part of `computeDerivedSignals`. Add `micronutrientGaps: [NutrientGap]` to the `DerivedSignal` output.
- Implement the food score micronutrient modifier: soft positive for ≥50% RDI coverage, soft negative for persistent gap (7+ days <25% RDI where data exists). Never fires when <50% of logged meals have micronutrient data for that nutrient.
- Implement the micronutrient gap preventive-care thought bubble: fires after 14-day gap, Fernlet voice, dismissible, 2-week cooldown per nutrient.

**Nutritionist export update:**
- Replace any recipe ingredient list in the export with per-serving macro and micronutrient totals from `MealLog` snapshots only.

Exit criteria:
- A logged meal whose source item is in the USDA bundle uses stored macros with no AI call.
- A restaurant item parsed 7+ months ago is flagged and re-verified on next AI-available parse.
- Editing a saved recipe does not change past `MealLog` macroSnapshot values.
- A recipe created via paste uses `FoodItem` table values, not AI macro estimates.
- The food score responds correctly to micronutrient coverage (positive and negative signals tested independently).
- The micronutrient gap thought bubble fires after 14 days, respects the 50% data-coverage threshold, and does not repeat within 2 weeks.

## Phase P4 — Prototype Ambient, Recipe, and Day History Features (in progress)

Goal: add low-cost delight, utility, and day history browsing without touching deferred systems.

Tasks:
- Phase 4 status: in progress.
- Add year-ago journal card.
  - Prototype status: partially present through journal history surfaces; a dedicated year-ago ambient card still needs review.
- Add macro-gap meal suggestions from meal history.
  - Prototype status: not complete.
- Add forgotten-good-things prompts from meal/workout history.
  - Prototype status: not complete.
- Add preventive-care thought bubbles.
  - Prototype status: not complete.
- Add "Today's intent" empty-state line (after 14:00 local with nothing logged).
  - Prototype status: not complete.
- Add recipe parsing with AI path plus manual fallback.
  - Prototype status: manual recipe builder is complete; URL recipe import exists separately; full AI paste-and-parse recipe flow remains incomplete.
- Add `SignalsCard` on home screen and `TrendsModal` showing all five derived signals.
  - Prototype status: not complete.
- Add Day Detail Sheet:
  - Tapping a calendar day opens a modal sheet with that day's score, avatar state, summary, meals, workouts, hydration, hygiene, sleep, and journal entry.
    - Prototype status: day detail/history view exists for logged days and supports multiple data types.
  - Month navigation: `<` `>` chevrons flanking the month/year label; navigation covers the full range of logged history.
    - Prototype status: complete.
  - "Back to today" pill appears when viewing a past month; tapping snaps back to the current month with today highlighted.
    - Prototype status: complete.
  - Today's date always shows a highlight box.
    - Prototype status: complete.
  - Past-date food and workout logging: log flows launched from Day Detail accept the target date and write to that day. Journals are read-only from this view.
    - Prototype status: complete for food and workout, and the current edit sheet also supports journal/sleep/hydration/hygiene updates.
  - Empty days show "Nothing logged this day." plus Log food and Log workout buttons.
    - Prototype status: complete.
- Add overnight Foundation Models day summary batch: on first app open after midnight, generate `daySummaryText` (<50 words, Fernlet voice) for yesterday and any day in logged history missing a cached summary. Store on the `DailyHealthScore` record. Skip silently if Foundation Models is unavailable.
  - Prototype status: model storage exists; generation batch is not implemented.
- Invalidate and re-queue a day's `daySummaryText` when new food or workout data is written for that date.
  - Prototype status: not complete.

Exit criteria:
- At least three ambient features are visible in normal use.
- Recipe parsing does not require AI to save a recipe.
- Tapping any logged past day opens Day Detail with correct data.
- A meal logged for a past date from Day Detail appears on that date, not today.
- Month navigation reaches back to the earliest logged day.
- Day summaries are present for logged days after an overnight pass and absent for days with no data.

## Phase 1 — Baseline Hygiene and File Split

Goal: make the current prototype maintainable after storage is in place.

Tasks:
- Split the large `ContentView.swift` prototype into feature folders: `Home`, `Food`, `Move`, `Journal`, `Settings`, `Shared`.
- Move data models, repositories, scoring, fallback helpers, and UI components into separate files.
- Remove calorie-deficit display from UI to align with the spec guardrail.
- Add snapshot tests or lightweight UI tests for the main tabs.

Exit criteria:
- App builds cleanly after file split.
- Unit tests cover scoring, meal classification, hydration, hygiene, and journal floor behavior.
- No user-facing calorie target or deficit copy remains.

## Phase 2 — Scoring v3

Goal: replace the prototype score with the full v3 wellness formula.

Tasks:
- Add goal types and weight vectors.
- Implement component score calculators for food, exercise, sleep, hydration, hygiene, and journal.
- Add sickness override and weight redistribution.
- Add avatar states: thriving, okay, tired, fainted, sick.
- Add default seed behavior for first-day limited history.
- Add guardrail tests: hard journal entries still count, overshooting macros does not punish, missing days do not create streak penalties.

Exit criteria:
- Scoring logic is deterministic and unit-tested.
- UI shows fuzzy state and subtle live score without optimization framing.

## Phase 3 / Phase S3 — Privacy Modules, AI Boundary, and Sealed Stores

Goal: establish compile-time boundaries before any third-party AI path and before period, photo, or sensitive memory work. This phase expands the original Phase 3 scope with the S3 requirements from the 2026-05-28 audit. **Must be complete before any OHTTP or third-party provider is introduced.**

Tasks:
- Create separate Swift packages:
  - `PrivateHealthStore`
  - `PeriodContextBridge`
  - `PrivateMemoryStore`
  - `PrivateMediaStore`
  - `ContextBuilder`
  - `AIProviders`
- Move period raw types into `PrivateHealthStore`. Move `SensitiveMemory` into `PrivateMemoryStore`. Move `Photo` into `PrivateMediaStore`.
- Add import-boundary build checks (e.g., forbidden-import Swift package tests or `swiftpackage-forbidden-imports` CI checks) proving that `OHTTPProvider` and AI modules cannot import sealed types.
- Define typed per-request `AIContextPayload`s with field allowlists. Unit-test that forbidden fields (period, raw journal text, sensitive memory, photos, location, friend data) are absent from each payload type.
- Add the local **AI audit log**: records request type, provider, field names (not values), whether period context was included, and success/failure. No plaintext sensitive content in the log.
- Route Tier-2 memory access through the **Memory Agent** (recency/destination filtering + `containsDiagnosticLanguage` post-classifier) before any text reaches a prompt. Remove the raw `tierTwoContextSummary`-into-prompt path in `LaunchPreparationService`/`FernletStore`.

Exit criteria:
- `OHTTPProvider` (when it exists) cannot import period bridge, sensitive memory, raw journal, or photo types — enforced by build.
- Payload unit tests assert forbidden fields are absent from each AI request type.
- No Tier-2 text reaches any prompt without Memory-Agent filtering and diagnostic-language check.
- `MemoryExtractionContext` cannot import period modules.

## Phase 4 — Onboarding and Permissions

Goal: collect only the minimal data required and request permissions contextually.

Tasks:
- Build 6-screen production onboarding: privacy promise, goal, starter customization, optional details, dietary pattern, HealthKit/notifications.
  - Prototype status: not complete as production onboarding.
- Prototype shortcut: add goal selector and sickness toggle before full onboarding.
  - Prototype status: complete through Settings plus first-run onboarding for goal/profile/preferences.
- Add user profile fields: goal, age bracket, optional sex/height/current weight, dietary pattern.
  - Prototype status: complete as concrete age, sex, height, weight, activity level, dietary pattern, and guidance intensity fields.
- Add contextual first-use prompts for exercise, food, hydration, period, and friends when those features are enabled.
  - Prototype status: not complete.
- Add Info.plist usage descriptions for HealthKit, Bluetooth, NearbyInteraction, Camera, Photo Library Add, Location, and Notifications.
  - Prototype status: not complete.

Exit criteria:
- Fresh install routes through onboarding.
- Permission prompts appear only when feature context requires them, except notifications if kept in onboarding.

## Phase 5 — HealthKit Integration

Goal: make sleep and workout data real while preserving user control.

Tasks:
- Add `HealthKitManager` with read authorization for heart rate, active energy, sleep analysis, step count, and workouts.
- Add write authorization for workouts.
- Implement workout write-back for Fernlet-logged workouts.
- Import external HealthKit workouts and deduplicate by HealthKit UUID/source metadata.
- Compute `SleepRecord.derivedQualityScore` from stages when available, duration fallback otherwise.
- Add Settings toggles for HealthKit read/write and write-back.

Exit criteria:
- Manual Fernlet workouts can appear in Apple Health when permitted.
- Apple Watch workouts import once and contribute to exercise scoring.
- Sleep scoring uses HealthKit data when authorized.

## Phase 6 — Core Screens v3

Goal: align primary UX with the spec.

Tasks:
- Home: avatar, health bar, quick log, thought bubbles. Heart bonuses and fixed photowall slot remain deferred until friend/photo systems resume.
  - Prototype status: mostly complete for solo use; swipe navigation between main tabs is also implemented.
- Food: macro rings only, meal definitions/logs, add by history/manual first; recipe parsing can be added in the prototype; photo/search later.
  - Prototype status: local food logging, macro summary, nutrition guidance, recipe builder/search/edit/export, and URL recipe import are implemented.
- Exercise: suggestion slot, manual workout logging, HealthKit summary, per-exercise progress.
  - Prototype status: manual logging and local suggestions are implemented; HealthKit and per-exercise progress remain incomplete.
- Journal: <=100 words, color tag, heatmap, year-ago card, optional photo hook.
  - Prototype status: journal entry, tags, calendar/history, and day detail exist; photo hook remains deferred.
- Hygiene: toggles and weekly overview.
  - Prototype status: toggles exist; weekly overview needs review.
- Hydration: container fill state and picker.
  - Prototype status: bottle count controls exist.
- Sleep: HealthKit summary and richer-data indicator.
  - Prototype status: manual sleep logging exists; HealthKit summary remains incomplete.
- Settings: goal, macro goals, HealthKit controls, sickness toggle, privacy center shell.
  - Prototype status: goal, nutrition profile/preferences/targets, AI status, and sickness toggle exist; HealthKit controls and privacy center shell remain incomplete.

Exit criteria:
- Main solo app feels complete without AI, friends, or period tracking.
- Guardrails are visible in copy and interaction design.

## Deferred Phase 11 — Foundation Models On-Device AI

Status: broader provider/audit work remains deferred. A narrow Foundation Models meal-selection path has already landed because Phase P2 fallbacks are implemented for meal logging.

Goal: add on-device intelligence with typed outputs and strict context budgets.

Documentation notes verified locally:
- Use `SystemLanguageModel.default.availability` to gate AI UI.
- Use `LanguageModelSession` for async responses.
- Sessions handle one request at a time.
- Use guided generation through `Generable` and `Guide` for structured outputs.
- Enforce context window budgets and handle exceeded-window errors.

Tasks:
- Add `OnDeviceProvider` behind `AIProvider`.
- Add `AIRequestType` and per-request token budgets.
- Implement guided-generation outputs for journal emotions, memory extraction, workout suggestions, meal suggestions, recipe parsing, coaching tone, and tamagotchi reaction.
  - Prototype status: meal selection has a guided-generation path in `FoundationFoodSelection`; the other outputs remain incomplete.
- Add prewarming on screens that may trigger generation.
- Add graceful unavailable states for older devices or disabled Apple Intelligence.
- Add local AI audit log.

Exit criteria:
- On-device AI can be disabled or unavailable without breaking core logging.
- AI payload tests cover field allowlists and budget truncation.

## Deferred Phase 12 — Production Memory System

Goal: implement Core and Sensitive Memory, with a prototype inspection path that is explicitly not the production privacy model.

Tasks:
- Build Core Memory screen with browse/edit/delete/export controls.
- Prototype: add Tier 2 memory as a separate readable local debug/prototype view for testing.
- Production: implement Sensitive Memory store with no browse UI.
- Implement Memory Agent as the only reader of both stores in production.
- Add journal memory extraction with one on-device structured call when Foundation Models are available.
- Add deterministic extraction/fallback rules for prototype builds when AI is resting/off.
- Add deny-list and classifier checks for diagnostic language.
- Add natural-language forget/edit routing through the Memory Agent; keyword matching is acceptable for the first prototype.
- Add wipe Core, wipe Sensitive, and wipe all controls.

Exit criteria:
- Prototype Tier 2 local debug/prototype view is clearly labeled test-only.
- Production Sensitive Memory cannot be shown or exported by any screen.
- Third-party destinations cannot receive Sensitive Memory by type/import design.

## Deferred Phase 13 — Period Tracking and Period Context Bridge

Status: deferred for the current prototype. Do not implement until sealed storage and data protection boundaries exist.

Goal: add the walled-off period feature and its abstract outputs.

Tasks:
- Build `PrivateHealthStore` data models: entries, cycle history, predictions, trends.
- Build Period screen: calendar, log entry, predictions, trends, adjustment toggles, privacy banner.
- Implement prediction calendar math with minimum 3 cycles.
- Implement overnight/on-demand trend computation.
- Implement `PeriodContextBridge` signals for phase, nutrition, and exercise.
- Add period-aware scoring adjustments based only on medium/high-confidence personal trends.
- Add deletion flow and tests showing bridge returns `.unknown` / `.noData` after deletion.

Exit criteria:
- Raw period data remains sealed.
- Period-aware scoring and suggestions work only through bridge signals.

## Deferred Phase 14 — Photos and Photowall

Status: deferred for the current prototype.

Goal: implement private on-device photos without face recognition or AI exposure.

Tasks:
- Build encrypted `PrivateMediaStore` for photo bytes.
- Add journal photo capture with camera-first flow and library behind extra tap.
- Add photowall on Home with fixed placement and slow rotation.
- Add gallery with filters by source/person metadata, copy-to-Photos, delete.
- Add eviction policy: warning at 900, FIFO at 1000.
- Add photo-surfacing exclusion integration through Sensitive Memory.

Exit criteria:
- Photos never enter AI payloads.
- No face recognition or face database exists.

## Phase 7 — Identity, Proximity Handshake, and Local File Sharing

Goal: create the local physical-presence primitive earlier, before cloud group sharing.

Tasks:
- Implement Keychain-backed Ed25519 and X25519 identity manager.
- Store raw CryptoKit keys as synchronizable generic password items.
- Add TOFU peer public key storage.
- Implement BLE advertising/scanning transport for handshake mode.
- Implement signed `HandshakePacket` encoding, chunking, nonce and timestamp validation.
- Implement NearbyInteraction token exchange and ranging where supported.
- Add capability fallback for unsupported devices.
- Add `HandshakeEvent` logging.
- Add a local file-sharing envelope for explicit export bundles: schema version, sender public key, payload type, payload summary, created date, optional expiration, signature, and encrypted payload when appropriate.
- Implement one-device-to-one-device transfer for trainer/nutritionist export bundles before friend/social features.

Documentation notes verified locally:
- NearbyInteraction requires separate peer discovery/data exchange.
- For peer devices, exchange `NISession.discoveryToken` over that transport.
- Start ranging with `NINearbyPeerConfiguration(peerToken:)`.
- NearbyInteraction distance is not a secure access-control primitive by itself, so signature and mutual confirmation remain required.

Exit criteria:
- Two supported devices can confirm proximity and exchange signed identity packets.
- Two devices can transfer an explicit export bundle locally with user confirmation on both sides.
- Key mismatch triggers re-pair flow instead of silent overwrite.

## Phase 8 — Trainer/Nutritionist Local Sharing

Goal: share selected longitudinal workout and nutrition data with a trusted trainer/nutritionist over local Bluetooth/proximity only.

Tasks:
- Add an in-app `Trainer/Nutritionist Export` view as the default v1 approach.
- Let the user choose included categories: workouts, exercises, sets/reps/weights, macro/nutrient summaries, meal definitions, recipe history, hydration summaries, sleep summaries, derived signals, log trends, and goal type.
- Exclude by default: raw journal text, Sensitive/Tier 2 memory, period data, photos, friend data, location, and hidden debug fields.
- Show a review screen before transfer with counts, date ranges, and exact categories.
- Transfer the bundle through the local file-sharing envelope from Phase 7.
- Keep a local export audit record.
- Leave separate companion app as an open decision for later; revisit only if professionals need a client roster, persistent dashboard, or separate App Store positioning.

Exit criteria:
- User can locally share an explicit trainer/nutritionist bundle without cloud.
- Export content is reviewable before transfer.
- No excluded categories appear in the export tests.

## Phase 9 — Cloud-Assisted Multi-Person Group Sharing

Goal: add cloud only after two-device proximity and file sharing are reliable.

Tasks:
- Add minimal cloud schema for multi-person group rosters and ephemeral join tokens.
- Keep cloud payloads limited to public keys, group/activity metadata, and signed roster/vouch records.
- Do not upload trainer/nutritionist health export bundles by default.
- Preserve proximity requirements for joining and vouching.

Exit criteria:
- Multi-person group sharing works without remote-only friend adding.
- Cloud never receives health content, scores, journals, photos, period data, or memory.

## Phase 10 — Friends, Hearts, Activities, and Shops

Goal: add social features with fuzzy visibility only.

Tasks:
- Add minimal cloud schema for Friend, FriendLink, Activity, ActivityJoinToken, HeartSent.
- Add friend slots: 8 core and 4 close.
- Add fuzzy state publishing without scores or components.
- Add hearts with server-side one-per-pair-per-day limit and 24h decay.
- Add activity creation/joining through handshake.
- Add closeness scoring from activities.
- Add 6-hour shop access window after handshake.
- Add friend avatar cache refresh on every successful meetup.

Exit criteria:
- No remote-only friend adding.
- Friends see only fuzzy state and cached appearance.

## Phase 15 — Wardrobe, Backgrounds, Milestones, Creation Studio

Status: deferred to v8.

Goal: add gentle cumulative gamification.

Tasks:
- Build customization catalog and starter customization.
- Implement cumulative, non-resettable milestone progress.
- Add wardrobe and background composer.
- Add creation credits: one per 30 cumulative active days, cap 3.
- Add creation studio with guide-box canvas.
- Add on-device moderation for published items.
- Add in-person-only shop sharing.

Exit criteria:
- No streak-like unlock exists.
- Accessibility items are always available and never locked.

## Phase 16 — Ambient Features

Goal: layer in the subtle moments after the core data is reliable.

Tasks:
- Loading-screen companions during AI inference.
- Preventive-care thought bubbles.
- Year-ago journal card.
- Context-aware thought bubble templates.
- Macro-gap meal suggestions from history.
- Forgotten-good-things prompts from meal/workout history.
- Later production additions: Tamagotchi event reactions, WeatherKit mood-recovery prompts, friend mood nudges, optional background auto-decorations, and seasonal rhythm recognition.

Exit criteria:
- Ambient features are rate-limited and non-nagging.
- No feature creates a streak or shame mechanic.

## Phase 17 — Third-Party AI via OHTTP

Goal: optional advanced model fallback with explicit privacy limits.

Tasks:
- Defer until on-device AI, ContextBuilder, and audit logging are stable.
- Design OHTTP relay/gateway split.
- Implement or integrate OHTTP client stack with security review.
- Add per-feature opt-in UI and privacy disclosure.
- Ensure `OHTTPProvider` cannot import period bridge, Sensitive Memory, photos, raw journal, friend data, or location.
- Add payload stripping tests and audit log entries.

Exit criteria:
- Third-party AI is off by default.
- Period-aware adjustments remain on-device only.
- Security review completed before release.

## Phase 18a — iCloud Sync and Encrypted Backup

Goal: add CloudKit sync for core data and an opt-in encrypted backup path for sealed store types.

### Part 1 — Core Data CloudKit Sync

Tasks:
- Enable CloudKit sync on the SwiftData (or Core Data) persistent container targeting the user's CloudKit private database.
  - **Landed:** `NSPersistentCloudKitContainer` is in use. `PersistenceController` accepts `StoragePreferences` and enables or disables CloudKit accordingly.
- Define additive-only CloudKit schema. Mark `DerivedSignal` and `daySummaryText` as local-only (excluded from sync) since they are computed values.
- Add conflict resolution: last-write-wins by `modifiedAt` for most types; append-only behavior for `JournalEntry` (surfacing both on conflict, user dismisses duplicate).
- Add Settings → Privacy → "Sync to iCloud" toggle. Disabling excludes the persistent store from CloudKit sync without deleting local data.
  - **Landed:** `PrivacyDataSettingsView` has the iCloud sync toggle, disable confirmation sheet with DELETE confirmation, and "Delete iCloud data" action. Toggle triggers `PersistenceController.reload(with:)`.
- Add onboarding-time storage choice so the correct sync configuration is active from the first container load.
  - **Landed:** `OnboardingStorageChoiceView` presents a two-card picker (iCloud / local-only). Selection persists immediately via `StoragePreferencesStore`. `PersistenceController.shared` is now lazily initialized using `StoragePreferencesStore().preferences`, so it reads the user's saved choice from Keychain on first access.
- Subscribe to `StoragePreferencesStore` changes in `FernletApp` and trigger `PersistenceController.reload` when `iCloudSyncEnabled` or `localBackupExcludedFromiOSBackup` changes.
  - **Landed:** `FernletApp.onChange(of: storagePreferencesStore.preferences)` reloads if either storage field changes. Guard on `isReloading` prevents concurrent overlapping reloads.
- Instrument storage transitions with audit log entries.
  - **Landed:** `FernletAuditLog` calls added at: onboarding storage choice made, onboarding lock setup choice (passcode / biometricOnly / skipped), iCloud sync enabled, iCloud deletion initiated, iCloud sync disabled, HealthKit master enabled/disabled, HealthKit per-capability enabled/disabled, sealed backup sensitive-notes toggle changed, sealed backup period toggle changed, persistence reload started/completed/failed.
- Add `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription` to `Info.plist`.
  - **Landed.**
- Test: data written on one device appears on a second device signed into the same Apple ID.
- Test: disabling sync stops new records appearing on the second device; existing synced data remains.

### Part 2 — Encrypted Sealed Backup

Tasks:
- Implement HKDF-SHA256 key derivation from the X25519 private key with info label `com.fernlet.sealed-backup`.
- Implement AES-GCM encryption/decryption helpers with random 96-bit nonce and additional authenticated data (payload type + Ed25519 public key).
- Define `SealedBackupRecord` CloudKit record type: user public key, payload type, encrypted blob as `CKAsset`, nonce, created/modified timestamps.
- Add Settings → Privacy → Backup section with two independent toggles: "Back up sensitive notes" (Sensitive Memory) and "Back up period data."
- Implement the opt-in warning modal for each toggle. The modal must state: (1) data leaves the device encrypted, (2) Apple cannot read it, (3) losing iCloud Keychain on all devices makes this data permanently unrecoverable. User must tap a confirm button.
- Period data toggle gets an additional disclosure sentence about the sensitivity of period data leaving a device in any form.
- On enable: encrypt and upload existing records. On disable: delete the `SealedBackupRecord` from CloudKit and stop future uploads. Local data is never deleted.
- On new device restore: if toggle was on, download and decrypt on first app open after sign-in. Show a progress indicator; do not block logging.
- Add "Save to Photos" export action to individual photo items in `PrivateMediaStore`. Uses `PHPhotoLibrary` write-only. No automatic iCloud Photos sync.

### Deferred (future hardening phase)

- Recovery code mechanism: generate a BIP39-style mnemonic, store an escrow key blob, build a recovery UI flow. Deferred until the encrypted backup path is proven stable in production.

Exit criteria:
- Core data syncs across two devices on the same Apple ID when sync is enabled.
- Disabling sync is non-destructive to local data.
- Enabling either sealed backup toggle requires explicit modal confirmation.
- Period data toggle shows the additional political-sensitivity disclosure.
- Encrypted blob in CloudKit is verified to be unreadable without the derived key.
- Disabling sealed backup deletes the CloudKit record.
- "Save to Photos" writes a single photo to the system library without triggering any sync or further upload.
- Tests cover: key derivation determinism, AES-GCM round-trip, CloudKit record creation/deletion, opt-in modal appearance, and disclosure text content.

## Phase 18 — App Store Readiness

Goal: make the app reviewable and privacy claims defensible.

Tasks:
- Add `PrivacyInfo.xcprivacy`.
- Confirm App Privacy nutrition labels. CloudKit sync for core data changes the "Linked to You" classification for health and journal types — confirm with legal before shipping.
- Write privacy policy sections for HealthKit, AI, period data, photos, CloudKit sync, encrypted sealed backup, and OHTTP.
- Verify usage descriptions, including `NSPhotoLibraryAddUsageDescription` for the "Save to Photos" action.
- Verify HealthKit guideline compliance.
- Verify UGC moderation story for in-person shops.
- Add data export and delete controls, including a "Delete all iCloud data" action that removes CloudKit records and sealed backup blobs without deleting local data.

Exit criteria:
- Privacy manifest matches actual code paths.
- No tracking domains.
- Data flow claims are backed by module boundaries and tests.
- CloudKit data deletion is verified to remove records from the private database.

## Next up (2026-08-09)

> Supersedes the "Suggested Immediate Next Sprint" block that stood here from 2026-05-28. All four
> of its priorities — S1, S2, M1, and S3 — have since shipped, and its "after security phases" list
> is now split across the table above and the tracker.

**1 — Fernlet Coach: the in-person session (primary channel).** The blocking track. The 2026-07-27
round shipped the coach *primitives* — `CoachVerificationCeremony`, `CoachSessionTrustPolicy`, the
all-hardware tap-gate fix, a pre-decrypt wire-size gate — and deliberately stopped short of the
session manager and UI. Those primitives currently have **zero production callers**; no
`ProximityCoordinator` is constructed in `.trainer` mode. Before writing code, revise
[FernletCoach-Specification-2026-07-19.md](FernletCoach-Specification-2026-07-19.md) §3.3, §3.6, §6
and §8: they still describe the iMessage + CloudKit hybrid as the primary channel, which the owner
reversed on 2026-07-26 (in-person mesh is primary; the hybrid is the off-week fallback). The session
manager must pass a real `localCapabilities` array or wire2 silently degrades to legacy for the whole
coach channel. Detail: [Plan-Prekeys-ProtectedLoad-CoachMesh-2026-07-26.md](Plan-Prekeys-ProtectedLoad-CoachMesh-2026-07-26.md)
Increment 10 + the "Coach channel model" note.

**2 — The owner-decided queue from 2026-07-19 (small, none built).** Crisis nudge (Phase 16 —
closes a safety flag); body-photo lock-setup nudge; barcode web UPC lookup behind
`webNutritionLookupEnabled`; wire `MeshAdmissionPromptSheet`. Plus the dead "Request access" button
in Settings → Move, which advertises a shipped feature as unbuilt. See
[RemainingWork-2026-07-19.md](RemainingWork-2026-07-19.md) §2–§3.

**3 — Triage [Doc-Pass-Anomalies-2026-08-04.md](Doc-Pass-Anomalies-2026-08-04.md).** Never triaged.
Several entries are real defects rather than smells — notably the `PeriodTrackerStore.loadEntries`
crash-on-duplicate-`hkExternalUUID`, the in-session photo save that skips rehydration, and the
in-app privacy policy still claiming 18+ for intimacy where the shipped gate is 16+.

**Then, unsequenced:** localization Phase 0 (live locale bugs even in English), multi-device without
iCloud Phases 2–3, BIP39 recovery codes, Background App Refresh, the memory-controls suite, and the
coach dead-drop (Increment 9) as the secondary channel.
