# Fernlet — Remaining Work & Implementation Tracker (2026-06-23)

Derived from a multi-agent spec-vs-code audit (18 feature areas, each verified against actual
source with an adversarial confirmation pass). This supersedes the stale "Prototype status"
markers in [ImplementationPlan.md](ImplementationPlan.md) where they conflict — several items the
plan calls "not complete" are in fact implemented, and a few marked "complete" have regressed.

**Legend:** `[ ]` not started · `[~]` in progress · `[x]` done · 🚨 safety-critical

---

## Executive summary

The privacy-first foundation is substantially built and tested: local data model + repository /
store / snapshot machinery, sealed encrypted stores (journal/cycle/intimacy), keychain app lock,
scoring engine + all derived signals, the on-device AI substrate, period tracking, HealthKit
integration, and the entire proximity/mesh handshake subsystem (incl. Phase 3/4 group encryption
and S1 hardening) are implemented and live.

Remaining work clusters in four places: (1) a safety-critical, unbuilt mental-health crisis nudge;
(2) the friend social layer; (3) privacy/sync production-hardening; (4) App Store readiness blockers.

---

## Scope decision (this effort)

Selected by the product owner on 2026-06-23. The list below is the committed work for this pass.

**IN SCOPE — implement now:**
- **All "In progress / partial" items** (§1 below).
- From "Not started / missing" (§2): PeriodContextBridge + period-aware scoring, S3 compile-time
  module split, ambient cards, onboarding permission acquisition, App Store blockers, memory
  diagnostic classifier at storage time.
- From "Deferred by design" (§3): USDA bundled store → **SQLite**, **WeatherKit** integration.

**STILL DEFERRED (not this pass):** the friend social layer (trainer/nutritionist export, hearts,
fuzzy state, slots, activities, shops, cloud group sharing), OHTTP third-party AI tier, the
production AI control plane / coaching tone, Sensitive Memory store + wipe/export tiers,
milestones/unlocks/wardrobe/Creation Studio + Core ML design moderation, avatar event reactions,
shopping lists, and historical data import.

> ⚠️ **Note on the 988 crisis nudge:** the audit flagged the soft mental-health crisis nudge (§0
> Guardrails) as the single highest-priority safety gap. Owner decided 2026-06-24 to **leave it
> deferred** for this effort (still tracked in §2). Revisit before App Store submission — it is
> unblocked (hangs off the existing `moodTrend = declining` signal) and carries App Review weight.

---

## PR sequencing plan (remaining heavy work)

Order verified against the code (hard dependencies + shared-file conflicts). Land each **invasive**
item as its own PR, merged **sequentially**; fold the noted light items into their heavy PR; batch the
rest into one **"new items" PR done first**.

**Order:** `new-items batch → 1 photowall → 2 usda-sqlite → 3 food/recipe → 4 sealedbackup-restore →
5 healthkit→scoring → 6 period-context-bridge → 7 s3-package-split`

1. **Photowall gallery + `PrivateMediaStore`** — ✅ LANDED (2026-06-24). Isolated in `Proximity/Photos/`;
   at-rest AES-256-GCM encryption (backup-restorable keychain key), per-photo Save-to-Photos + delete,
   and the 900-warning banner all shipped. (Manual people-tagging + photo-surfacing exclusion remain,
   tracked separately in §1.)
2. **USDA → SQLite** — ✅ LANDED (2026-06-24). Read-only `FoodCatalog.sqlite` + `FoodCatalog`
   service replaces the in-memory bundled array; FTS5 candidate prefilter → existing scorer. See §3.
3. **Food/recipe** (RecipeDefinition↔SavedRecipe merge) — hard dependency on #2. Fold in the
   ingredient-search labels/dedup, live micros, and `.aiResolved` light items (all operate on
   `FoodDataCatalog.FoodItemSearch`, which #2 rewrites — doing them earlier = rework).
4. **SealedBackup restore** — Tier-2 setter + `MenstrualNarrative` Core Data writeback + onboarding
   hook + empty-store guard. Store-heavy → serialized with #3/#5/#6.
5. **HealthKit → scoring** — changes `compute`/`computeBreakdown`/`sleepScore` **first**.
6. **PeriodContextBridge + period-aware scoring + per-phase trends** — layers `adjustedForPeriod` onto
   #5's new signature.
7. **S3 Swift-package split** — **last**; it edits `Models.swift` / `FernletStore.swift` /
   `project.pbxproj` that every other item also touches. Ship #6 against the existing grep boundary
   (`S3BoundaryTests`); retrofit compiler module walls here. (Only do S3 first if the bridge must be
   module-walled day one — then all six others rebase onto the new layout.)

**Non-negotiable adjacencies (same files — never in parallel, merge between):**
- **#5 ↔ #6** both edit `Scoring.swift` + the `FernletStore` scoring call sites. HealthKit first
  (changes the signature); the period bridge adds onto it.
- **#2 ↔ #3** both edit `FoodDataCatalog.FoodItemSearch`. SQLite backend first.
- `FernletStore.swift` is the universal hotspot (#3/#4/#5/#6) — the order serializes them.

**"New items" PR (do first; light, independent):** Day Detail modal sheet + empty-day buttons, period
`dateKey` accepted-risk note, `recentWorkouts` array, goal-weight reconcile, contextual HealthKit
first-use request, mindfulness write, AI audit-log durability, companion loading states, contextual
Tier-2 first-use prompts, Settings daily-check-in toggle. (Food/photowall light items fold into #1/#3,
not here.)

---

## §1 — In progress / partial (IN SCOPE — finish all)

### Data Model & Storage
- [ ] **CloudKit sync startup gap** — `PersistenceController.shared` force-disables sync at startup,
  re-enables after a 5s deferred reload; no cross-device test. → Validate the forced-off/deferred
  window on iOS 26; add a cross-device sync integration test.
- [ ] **Period `dateKey` accepted-risk note** — `MenstrualNarrative.dateKey/createdAt` are plaintext
  but local-only (spec met); unlike the journal entity it lacks the accepted-risk comment. →
  Obfuscate the lookup key or add the documented accepted-risk note.
- [~] **Wire `SealedBackupService`** — DONE (export): `FernletStore.setSealedBackupEnabled(_:payloadType:)`
  seals + uploads/deletes for BOTH payloads (period → MenstrualNarrative JSON; sensitive notes → Tier-2
  memories); wired to the toggles via a disclosure-confirmation modal. **Remaining: restore-into-stores**
  on a new device (needs a Tier-2 setter + Core Data writeback + onboarding hook + empty-store guard;
  build-verified, needs device runtime verification for iCloud/provisioning). Original note: AES-GCM/HKDF crypto + CKAsset I/O fully built & unit-tested
  but never instantiated (dead code). → Wire `reconcile` into the backup toggles + a restore path.
- [x] **PendingNarrativeBuffer drain ordering (regression #37)** — RE-CONFIRMED FIXED (2026-06-24):
  `drainAll()` is non-destructive; `PeriodTrackerStore.drainPendingBuffer` purges only after all
  inserts succeed; `pendingNarrativeBufferAppendDrainRoundTrip` guards it. No change needed.
- [x] **daySummaryText overnight batch** — Covers yesterday only and writes deterministic fallback.
  → Backfill all logged days missing a summary; leave the slot empty when FM unavailable.

### Scoring, Wellness Formula & Derived Signals
- [x] **Per-day sickness persistence** — single global `isSick` bool applies today's flag to all
  history. → Key by date (`is-sick-{date}`), auto-clear at midnight, read per-day in past scoring.
- [x] **DailyHealthScore snapshot fields** — stores only score/state/summary. → Persist per-component
  scores, weight vector, sickness-override flag, optional period phase.
- [ ] **`recentWorkouts` array** — signals use a 14-day window vs. the spec's cap-30 array. → Add the
  explicit array if the contract is required.
- [x] **Home SignalsCard** — TrendsModal exists; no mood/energy/readiness chip row. → Build the
  SignalsCard tapping into TrendsModal.
- [x] **Trends reachable by default** — `.trends` widget wired but omitted from `defaultWidgets`. →
  Add to defaults or surface via SignalsCard.
- [ ] **Goal weight numbers** — values differ from spec §6 table (intentional tuning). → Reconcile
  if exact parity required (else document the tuning).

### Meal Tracking, Food Search, Recipes & Micronutrients
- [ ] **Ingredient-search UX** — no data-source label, no dedup, no brand-disclosure grouping. → Add
  per-row source labels, collapse variants, disclosure grouping.
- [ ] **`.aiResolved` inline meal-parse** — only the web-product label path creates them. → Add an FM
  inference branch that resolves unknown ingredients and persists as `.aiResolved`.
- [ ] **Live micronutrients in recipe builder** — builder shows macros only. → Surface per-serving
  micros live as ingredients change.
- [ ] **MealLog micronutrientSnapshot for manual fallback** — manual parses yield empty micros. →
  Resolve fallback meals through the food store, or accept + document the gap.
- [ ] **Merge dual recipe models** — `RecipeDefinition` + `SavedRecipe` coexist. → Merge the
  URL-imported `SavedRecipe` into `RecipeDefinition`.

### Period Context Bridge & Intimate Tracking
- [ ] **PrivateHealthStore facade / `PeriodHealthTrend` type** — functionality split across
  PeriodTrackerStore/CyclePredictionEngine/MenstrualNarrativeRepository; no named facade, history
  recomputed each load. → Consolidate into the spec facade (or accept split) + add the trend model.
- [ ] **Period deletion → bridge `.noData` test** — add once the bridge exists (see §2).
- [ ] **Period context first-use onboarding** — only HK `cycleTracking` permission requested. → Add a
  baseline-cycle/goals prompt if intended.

### HealthKit & Sensor Integration
- [ ] **Continuous heart-rate read** — reads resting HR + HRV, not continuous `.heartRate`. → Add or
  update spec.
- [ ] **Sleep stages** — total asleep hours only. → Query stages for the derived-quality formula.
- [ ] **Consume activity context** — `HealthActivitySummary` loaded but unused. → Feed steps/active
  energy into the exercise score or surface it.
- [ ] **Consume body context** — resting HR/HRV loaded but unused. → Feed into intensityReadiness /
  recovery, or remove.
- [ ] **Onboarding HK request decision** — permissions screen informational only. → Wire to request,
  or keep contextual deliberately (see Onboarding in §2).
- [ ] **Mindfulness write** — read-authorized scaffolding only. → Add write+consumer or treat as
  scaffolding.

### Proximity Handshake & Mesh Networking
- [ ] **Surface mesh-management UI** — admission prompt, open/closed toggle, removal-voting, vouch all
  exist + tested at the manager level; confirm they're wired into the redesigned live UI.

### Photowall & Friend Photos
- [x] **`PrivateMediaStore` at-rest encryption** — DONE (PR #1, 2026-06-24): `MeshPhotoCacheStore`
  renamed/refactored to `PrivateMediaStore` (isolated in `Proximity/Photos/`); image + thumbnail bytes
  are AES-256-GCM-encrypted before disk via an injectable `PrivateMediaKeyProviding`. Key is a dedicated
  256-bit AES key in the keychain, stored **backup-restorable** (`kSecAttrAccessibleAfterFirstUnlock`,
  not ThisDeviceOnly) so the cache survives device migration with the app-container backup. Legacy
  plaintext files are recognised on read (positive image-bounds check) and re-encrypted in place on
  first access; bytes that are neither openable nor a valid image (wrong/lost key, corruption) resolve
  to nil rather than being handed back as garbage. Files keep `.completeFileProtection`. (Hardened per
  an adversarial review of the diff — see the 7 confirmed findings now fixed.)
- [ ] **Manual people-tagging UI** — only the handshake-metadata branch exists. → Add manual tag
  assign/edit. *(Out of scope for PR #1; separate follow-up.)*
- [x] **Gallery Save-to-Photos** — DONE (PR #1): per-photo "Save to Photos" action added to the
  persistent gallery carousel (`FriendPhotoCarouselPostView`), reusing `FriendPhotoLibrarySaver` with the
  same add-only auth + Settings-deeplink error handling as the session review sheet.
- [x] **Gallery per-photo delete** — DONE (PR #1): `MeshNetworkManager.deletePhoto(_:)` removes the
  photo from the in-memory lists, clears favorite/cover prefs pointing at it, and re-saves so the store's
  orphan cleanup deletes its image + thumbnail files; wired to a per-photo trash action with a
  destructive confirmation dialog.
- [x] **Eviction policy** — DONE (PR #1): cap is the spec's **1000** (FIFO by recency) via
  `PrivateMediaStore.maxCachedPhotos`; the in-memory `meshPhotos` cap raised 200→1000 (metadata-only
  entries) so the disk cap and the soft-warning are real; the **900-photo soft-warning banner** is now
  surfaced (dismissible) in the Friends album.
- [ ] **Photo-surfacing exclusion** — no excluded-people path. → Add the exclusion fact type + feed
  into the selector. *(Out of scope for PR #1; depends on the deferred Sensitive Memory store.)*

### Ambient Features (partial set)
- [x] **Preventive-care micronutrient bubble** — gap data computed + shown as trends bars; no
  dismissible Fernlet-voice bubble, no consecutive-day enforcement, no 2-week cooldown. → Build the
  bubble + dismissal state.
- [x] **Today's-intent dismissible** — implemented + gated, not dismissible. → Add per-day dismissed
  flag + affordance.
- [ ] **Companion loading states during AI inference** — only cold-launch is companion-led. → Add
  companion loading to meal/recipe/product/thought inference.
- [x] **Overnight day-summary batch** — yesterday-only, no midnight gate, substitutes fallback. →
  Backfill history, add a midnight gate, drop fallback when FM unavailable. (shared with §1 Data)

### Onboarding & Permissions (partial)
- [x] **Permissions screen requests** — now makes a real Notifications request + honest primers. → Wire real
  HealthKit/Notifications requests or relabel as a primer. (see §2 acquisition)
- [ ] **Contextual HealthKit request** — only via Settings toggle. → Trigger at first Exercise/Sleep
  use.
- [ ] **Background App Refresh** — only `remote-notification` mode declared; no BGTaskScheduler. →
  Register tasks + add modes if background work is needed.

### Privacy Architecture, Sealed Stores & AI Boundary (partial)
- [ ] **Local AI audit log durability** — in-session/in-memory, no outcome, no period flag. → Add
  outcome + period flag; persist to disk if "records locally" implies durability.
- [ ] **Import-boundary enforcement** — string-scan over 5 hardcoded files. → Convert to true
  package forbidden-import checks (ties into S3 split in §2).
- [~] **Encrypted sealed CloudKit backup pipeline** — DONE for reconcile/upload+delete + disclosure
  modal (restore-into-stores remains). crypto/transport built; `SealedBackupService`
  never instantiated; toggles only flip a preference. → Wire reconcile/restore + required warning
  modal. (shared with §1 Data)
- [ ] **Two-tier AI journal memory extraction** — Tier-2 deterministic; no AI
  `{coreMemories, sensitiveMemories}` pass, classifier runs at read-time not pre-storage. → Add the
  extraction pass (in scope only for the *classifier-before-storage* part; the AI extraction pass
  itself stays deferred — see §2 memory classifier).

### Third-Party Integrations / Cloud Fallbacks (partial — boundary only)
- [ ] **Payload stripping enforcement coverage** — allowlist real but grep-based, misses
  OHTTPProvider/photos/location/friend tokens. → Extend coverage + make compile-time (ties to S3).
- [ ] **AI audit log for cloud calls** — web-nutrition path audited but no success/failure or period
  flag, in-memory only. → Add fields + persistence. (OHTTP routing itself stays deferred.)

### iCloud Sync & Encrypted Sealed Backup (partial)
- [~] **Sealed-backup upload/delete orchestration** — DONE: reconcile (upload-on-enable /
  delete-on-disable) wired via `FernletStore.setSealedBackupEnabled`. Restore-on-new-device remains. →
  Instantiate; collect plaintext on toggle + call reconcile; wire restore on the new-device path.
  (same work as §1 Data "Wire SealedBackupService")

### Milestones / Screens (partial, low-risk fidelity)
- [ ] **Starter customization scope** — name + 4 colors vs spec's full slot set. → Broaden if desired
  (otherwise acceptable for prototype).
- [ ] **Day Detail as modal sheet** — currently a NavigationStack push. → Present as a modal sheet
  with detents/close (or update spec).
- [ ] **Day Detail editing scope** — edit sheet allows journal/hydration/hygiene/sleep, which spec
  marks read-only "for now" (line 707). → Restrict to food/workout per spec, or update spec.
- [ ] **Day Detail empty-day state** — copy differs, routes through one "Edit day" button. → Add
  distinct Log food / Log workout buttons + exact "Nothing logged this day." copy.
- [ ] **Home render completeness** — heart-bonus health-bar render (depends on Hearts model, deferred)
  and period-prediction bubbles on Home (depends on PeriodContextBridge — in scope §2). → Add the
  period-prediction renderer once the bridge lands; defer the heart-bonus render.

### App Store Compliance (partial — finished fully in §2)
- [x] **Single HealthKit usage string** — defined twice with conflicting text (Info.plist vs pbxproj
  `INFOPLIST_KEY_*`). → Keep one source.
- [x] **Sealed-backup opt-in warning modals** — DONE: 3-point disclosure alert (+ period-sensitivity
  line) gates enabling; only flips the pref on confirm + successful reconcile. Original note: toggles flip preference with no disclosure modal. →
  Add confirm modal (+ period political-sensitivity sentence).

---

## §2 — Not started / missing (IN SCOPE — selected items)

### 🚨 Safety (DEFERRED by owner decision 2026-06-24)
- [ ] **Soft mental-health crisis nudge with 988 link** — entirely absent. Spec §0 Guardrails
  requires a dismissible, **non-repeating** nudge for extended low mood, with a 988 link. Hangs off
  the existing `moodTrend = declining` signal → unblocked. *Owner chose to leave deferred for this
  effort (2026-06-24); revisit before App Store submission.*

### PeriodContextBridge + period-aware scoring
- [ ] **PeriodContextBridge** — read-only bridge exporting abstract phase/nutrition/exercise signals;
  returns `.unknown`/`.noData` on deletion or lock. Prereq (sealed boundaries) substantially met;
  residual prereq is the S3 split (below).
- [ ] **Period-aware scoring adjustments** — add `adjustedForPeriod`; soften hydration/scoring by
  phase (medium/high-confidence only).
- [ ] **Per-phase health trends** — statistical per-phase correlation engine
  (sleep/mood/exercise/nutrition/symptoms) with confidence.
- [ ] **Period screen adjustment toggles** — add period-aware-scoring toggles (only `hidePredictions`
  exists today).

### S3 compile-time module split
- [ ] **Swift package boundaries** — no `Package.swift`; boundaries are grep-enforced. → Carve sealed
  types + AI layer into compiler-enforced packages with forbidden-import checks. Gates OHTTP and is
  the residual prerequisite for the PeriodContextBridge.

### Ambient cards
- [x] **Year-ago / looking-back journal card** — N-days-ago lookup + card above Today.
- [x] **Macro-gap meal suggestion** — gap math + nudge card + tap-to-copy.
- [x] **Forgotten favorites (food)** — frequency analyzer + chips.
- [x] **Forgotten-good-things (workout)** — workout "haven't done" surface w/ monthly rate-limit (or
  confirm meal-only).

### Onboarding permission acquisition
- [x] **Permissions screen actually requests** — DONE for Notifications (real opt-in with status
  reflected); Health/Camera/Location kept as honest "asked at first use" primers per the app's
  contextual-permission philosophy. (Contextual HealthKit first-use trigger tracked separately.)
- [x] **Notifications permission + scheduling** — DONE: `NotificationService` (request + repeating
  daily gentle check-in + cancel); opt-in offered on the onboarding permissions screen. (Future: a
  Settings toggle to change/disable the reminder time.) Original note: zero notification code today. Add UserNotifications
  auth + scheduling (or remove from advertised permissions).
- [ ] **Contextual Tier-2 first-use prompts** — per-feature first-use flags + prompts.
- [x] **Coarse location / WeatherKit permission** — DONE: `NSLocationWhenInUseUsageDescription` added,
  `com.apple.developer.weatherkit` entitlement added, coarse-location request via `WeatherKitService`.

### App Store blockers
- [x] **`PrivacyInfo.xcprivacy` manifest** — absent; required-reason API use (UserDefaults in 9
  files). HARD submission blocker. Author for app + share-extension targets; add to Copy Bundle
  Resources.
- [x] **`ITSAppUsesNonExemptEncryption`** — missing; every upload stalls on the manual prompt. Add
  key + classification.
- [ ] **Privacy policy** — draft + host + in-app link + supply URL to App Store Connect.
- [ ] **App Privacy nutrition labels** — produce the label spec (re-evaluate post-S2 sealing).
- [ ] **User data export** — add an "Export my data" archive action (only proximity-log export
  exists).
- [ ] **Per-content report action** — block-user exists + enforced; no report mechanism / EULA. Add
  report + documented moderation story.

### Memory diagnostic classifier
- [x] **Run classifier at storage time** — `containsDiagnosticLanguage` runs only at
  prompt-injection time; core memories stored unscreened. → Run on every proposed memory before
  storage. (The full AI extraction pass stays deferred; only the storage-time classifier is in
  scope.)

---

## §3 — Deferred by design → SELECTED for this pass

### USDA → SQLite
- [x] **Bundled USDA store → SQLite** — DONE (builds + all 584 FernletTests pass). Source JSON
  (`USDAFoodItems.json` — actually **68,114** foods, not the ~13k the spec claims, + 202 curated)
  moved out of the bundle to `FoodDataSource/` and converted to a read-only `FoodCatalog.sqlite`
  (`food` table + contentless FTS5 index, ~34 MB) generated from the real `FoodItem` decoder by
  `FoodCatalogDatabaseBuilder` (regenerate via the gated `FoodCatalogGenerationTests`). New
  `FoodCatalog` service (`BundledFoodStore.swift` + `FoodCatalog.swift`) answers search via an FTS
  candidate prefilter → existing `FoodItemSearch` scorer (ranking parity verified) and resolves
  ingredient IDs via `SELECT … WHERE id IN (…)`. `FernletStore.bundledFoodItems`/`allFoodItems` and
  the `BundledFoodSeedingService` (24 MB JSON parse + 68k-struct in-memory load + bplist cache) are
  gone — only the small user-item set stays resident.

### WeatherKit
- [x] **WeatherKit integration** — DONE (builds + signs for simulator): `WeatherKitService` (opt-in,
  coarse location via CoreLocation, current-conditions fetch, graceful nil on missing
  permission/entitlement/error); Settings opt-in toggle that requests location only on enable;
  weather-aware recovery card in `AmbientCards`; Info.plist location string + WeatherKit entitlement.
  ⚠️ Runtime requires the WeatherKit capability enabled on the Apple Developer team (build-verified on
  simulator; degrades to no-card without it).

---

## §4 — Remaining deferred (NOT this pass, for reference)

Friend social layer (trainer/nutritionist export, fuzzy state, hearts, slots, closeness, activities,
shops, cloud group sharing) · OHTTP third-party AI tier · production AI control plane (provider
abstraction, token budgets, AI memory extraction, status pill) · Coaching Tone triad (model +
screen + AI wrapper) · Sensitive Memory store + wipe/export tiers · milestones/unlocks/wardrobe/
backgrounds/Creation Studio + Core ML design moderation · avatar event reactions · shopping lists ·
seasonal rhythm · per-type CloudKit schema + append-only journal merge (production sync hardening) ·
historical data import (Apple Health XML / MyFitnessPal CSV / paste).

---

*Full audit narrative and per-area evidence: see the workflow result that generated this doc
(2026-06-23). Canonical intent: [FernletSpecificationV3.md](FernletSpecificationV3.md).*
