# ``Fernlet``

The iOS app layer of Fernlet — the composition root that wires the FernletKit modules into a privacy-first, "tamagotchi-of-yourself" health and self-care app.

## Overview

The `Fernlet` app target is deliberately thin on policy and heavy on wiring: almost every domain rule lives in the local `FernletKit` package (`FernletDomainModel`, `FernletScoring`, `DiaryStore`, `StoreCore`, the `Private*` sealed stores, `ProximityKit`, and the walled `AIProviders` / `CloudKitSync` modules, among others), and this target is where all of those modules are composed into a running app. It is the one layer allowed to see both sides of the SPM "S3 wall": the walled AI and iCloud-sync modules must never import the sealed `Private*` stores, so any flow that touches both — a snapshot save, a delete-everything funnel, an AI call over health context — is stitched together here, without ever handing sealed plaintext across the wall.

``FernletApp`` is the `@main` entry point and launch state machine. It owns the app-lifetime singletons a cold launch needs before any view exists — the keychain-backed `FernletLockService`, the `StoragePreferencesStore`, and ``FernletStoreLoader``, which loads the store off the first frame and drives the preparing/ready/failed launch phases. Scene-phase changes relock the app and flush pending saves; storage-preference changes reload persistence and re-apply the sealed store's and the local day blob's backup exclusion. The ready phase also runs the one-shot ``BackupExclusionLaunchGate`` (security-hardening Phase 6): fresh installs — detected via the device-local ``FernletPriorUseMarker`` plus legacy onboarding evidence — silently default to backup-excluded, while existing installs with no recorded choice get a one-time honest trade-off alert whose answer is recorded in `StoragePreferences.backupExclusionChoiceMade` and never asked again.

``FernletStore`` is the central `@MainActor` `@Observable` facade every screen reads and mutates. The portable diary slice lives in `DiaryStore`; the facade owns everything app-only — per-row ledger services, the proximity subsystem, the coordinators (`SnapshotSaveCoordinator`, ``JournalSealingCoordinator``, ``SealedBackupCoordinator``, ``HealthSyncCoordinator``), the sealed photo stores, and the AI gate/quota/audit plumbing. Mutations persist through a debounced snapshot save against the active `FernletRepository` — Core Data + CloudKit or local JSON, selected by `StoragePreferences`. Sensitive data never enters that snapshot: journal, cycle, and intimacy text is sealed into the encrypted narrative stores, and device-local sidecars (AI quota, hearts, moderation, age assurance, sensitive-surface visibility) deliberately never sync.

``ContentView`` is the post-onboarding root shell: the five-tab pager (Home, Food, Move, Friends, Private), the single-active-sheet modal router, and the runtime wiring hub that injects the sensitive-surface visibility gates, scoring contexts, delete-everything hooks, widget bridge, and proximity listener lifecycles.

### App Shell & Core State

Beyond the entry points above, the shell's second-stage launch pipeline runs in ``LaunchPreparationService`` behind the companion launch screen — guided-run and cooking reconciliation, photowall seeding, ambient AI day summaries, and the companion thought. System integration flows through narrow persisted seams: App Intents and Shortcuts ride the widget's app-group action queue (``PendingWidgetActionQueue``) for background water logging or the expiring ``PendingIntentSheet`` token for foreground opens, ``FernletNotificationDelegate`` hands sheet requests across launch via a pending flag, and ``WidgetSnapshotMirror``'s two `NSFileCoordinator`-guarded JSON files are deliberate byte-format twins of the widget-side copies so the extension never links the FernletKit umbrella. AI plumbing stays wall-respecting — ``FernletAIComposition`` alone names the concrete `SystemLanguageModel` capability provider, and the device-local, never-synced ``UserDefaultsAICallQuotaStore`` and ``FileAIAuditLogStore`` back the sleepy/resting quota overlay and the "what left my device" audit ledger. ``HealthSyncCoordinator`` owns HealthKit ingestion behind the `HealthSyncContext` seam, with ``CoreDataHealthKitCacheCleaner`` providing the fail-closed opt-out scrub of cached clinical values from both the per-row day records and the aggregate synced blob. The Home dashboard (``HomeView``, ``AmbientCardsView``, ``GentleOfferEngine``) renders the companion-centered daily view with quiet, at-most-once-a-day nudges that disappear rather than nag, and ``UITestSupport`` gives the UX-appearance UI-test suite deterministic DEBUG-only launch hooks that never ship in release builds.

### Food & Nutrition

The entire eating surface. ``FoodView`` is the tab root (today's meals by type, macro totals vs. targets, cooking-resume card, recipe previews) and ``MealSheet`` is the quick-log front door reachable from any tab. A typed description runs ``MealResolutionService``'s tiered cascade — on-device AI dish decomposition (``FoundationDishDecompositionModel``, re-grounded in the food catalog by ``MealDecompositionResolver``), candidate-constrained AI selection, the deterministic ``DishTemplateLexicon``, a deterministic plan, and a keyword fallback — with ``MealBuilder`` assembling catalog-bound meals and a calorie plausibility gate downgrading implausible results to the pre-log ``MealReviewSheet``, so no low-confidence guess ever commits silently. ``FoodCaptureRouter`` unifies camera capture, auto-detecting barcode → nutrition label → meal photo and routing into the live scanner (``BarcodeScanView``), the OCR label sheet, the per-GTIN serving-count confirm step, and Vision-based photo identification that always pauses at review. The catalog side ships a build-time-generated USDA SQLite database plus a ~364k-product branded database attached as an On-Demand Resource (``BrandedCatalogResourceLoader``), and the opt-in, egress-audited web importer (``FoodProductWebImporter``). Recipes round out the group: editors and a read-only detail view, ``RecipeShareCodec`` for text and proximity-mesh sharing, AI-assisted ingredient substitution that forks rather than mutates, the grocery planner, and the cooking mode whose shared run state survives app kills and drives an interactive Live Activity (``CookingModeView``, ``CookingLiveActivityController``). Meal photos are sealed in the private media store and rendered honestly via ``MealPhotoPresence``/``RecentBites``; everything renders macros-first, with calories only behind an explicit opt-in.

### Movement & Workouts

The Move tab end to end: ``MoveView`` hosts a week-strip workout calendar over per-day plan/log drill-ins, manual logging (full ``WorkoutSheet``, quick-exercise fast path, plan-ahead ``WorkoutPlanSheet``), and the deterministic suggestion engine ``WorkoutPlanningService`` — split recommendation and weekday-rotated day plans filtered by equipment and injuries, with an optional on-device-AI natural-language adjustment that degrades to the unchanged plan. A committed day plan flows into the guided runner (``GuidedWorkoutSheet``), whose run state lives on ``FernletStore`` mirrored into the app group so the Lock Screen Live Activity buttons (``WorkoutLiveActivityController``, which — like its cooking counterpart — requests its activity through the shared ``LiveActivityStarter``) advance the same run, and ``GuidedWorkoutAvailability``/``GuidedWorkoutCardState`` reconcile "already logged" across relaunches. Durable context comes from ``WorkoutSetupSheet`` (split, frequency, experience, injuries) and ``WorkoutLocationSetupView`` with its granular equipment checklist rendered from hand-drawn SVG glyphs (``EquipmentIconLibrary``); ``GoalPresetCards`` surfaces the paired nutrition+training consequences of each goal. ``WorkoutTombstoneStore`` is the small persisted ring that stops a removed workout's in-flight Apple Health copy from resurrecting as an unremovable import. ``ProgressPhotoSection`` gives a sealed, lock-gated, snapshot-redacted body-photo timeline, and ``TrainerExportView`` builds the fail-closed allowlisted trainer/nutritionist bundle — sensitive categories strictly opt-in, sealed data with no representation in the DTO at all.

### Proximity, Social & Companion Customization

The in-person social layer plus the companion economy that feeds it. The Friends tab (``FriendsView``) is a shared photo album when idle and swaps into ``DisposableCameraView`` — a wind-to-arm "disposable camera" whose viewfinder morphs out of the Dynamic Island — once the mesh commits a session; session end runs a model-state-driven review that saves photos and mints one-sided friends against the trust vault. Around the live session sit the ceremony and safety surfaces: QR identity verification (``VerifyQRDisplaySheet``), the one shared gatekeeper confirmation ``JoinPromptSheet`` behind both mesh admission requests and Group Activity join requests, session-scoped vanishing chat (``SessionChatPanel``, 13+ gated), Group Activities hosting and joining (``ActivitiesView``), the Friends & Blocks roster with block/report/remove and both live-presence and dead-drop "away" hearts (``FriendListView``, ``AwayHeartsCopy``), and the App-Store-compliance safety-reporting flow. ``ConnectionInspector`` records per-session proximity diagnostics, and `ProximityHostAdapter` is the one seam bridging `ProximityKit`'s host abstraction onto ``FernletStore``. The companion economy runs from the ``CreationStudioView`` pixel editor (over ``ZoomablePixelCanvas``, unlisted-first saves, name moderation) through ``WardrobeView`` into the post-session ``FriendShopView`` window, with ``ClothingShareCodec`` sanitizing the catalog wire format in both directions and ``ItemTextureRenderer`` as the single rasterization path; a refused listing (flagged name, shop cap, store ban) surfaces the shared ``ShopAlert`` cases from both the studio and the wardrobe, worded per ``ShopAlertContext``. ``CompanionView`` is the app-wide vector-drawn creature whose stress/calm accents are presentation-only and deliberately never persisted; ``PetInteractionGovernor`` paces tap-to-pet anti-compulsively, and ``MilestonesView`` shows append-only, grow-only care counts whose coin gifts fund the shop.

### Cycle, Journal & Private Data

The sealed/private surface: everything the app promises stays encrypted, device-local, or behind the app lock. ``PrivateHubView`` (wrapped in the app-lock gate) pages between the Journal, the merged Cycle page, and Worry Box, with the Cycle page conditional on the store's derived visibility — it exists while either the period or the intimacy half is visible, each half gates itself independently inside ``CycleTrackerView``, and the clamped selection can never land on a hidden page. The journal and cycle pages draw their month grids from one shared ``MonthCalendarCard`` — canonical day keys, paging chevrons, weekday row — and fill it with their own per-feature cells; the cycle calendar layers period flow tints and a distinct intimacy marker in one grid, and day taps open the combined ``CycleDayDetailView``. Clinical cycle facts live as HealthKit samples, while free-text narratives are sealed into the `Private*` stores under the lock content key or a device-bound Keychain fallback — ``JournalSealingCoordinator`` enforces that plaintext never reaches the synced snapshot blob, and ``WorryBoxService`` is its deliberately simpler, never-synced sibling. ``SealedBackupCrypto``, ``SealedBackupService``, and ``SealedBackupCoordinator`` add the opt-in AES-GCM sealed CloudKit backup with escrow-key reconciliation and fail-closed, no-clobber restore gates. ``FirstAidView`` offers slow breathing, grounding, the Worry Box, and a static 988 support row; ``StressService`` computes the opt-in body-signals estimate into a device-local sidecar it scrubs the moment consent lapses. ``AgeAssuranceStore`` walls intimacy tracking (16+) and mesh chat (13+) behind DeclaredAgeRange verdicts, stored device-locally and failing closed on anything undetermined.

### Onboarding, Settings & Shared UI

The app's front door and its conscience: first-run onboarding, the Settings hub with its privacy and data controls, and the reusable sheets those surfaces share. ``OnboardingCoordinatorModel`` drives the eight-step, strictly-forward flow, accumulating every choice as draft state and committing it to ``FernletStore`` in a single `complete()` call — except the lock step (recorded immediately) and the storage step, which probes the iCloud account through ``ExistingCloudDataDetecting`` so a returning user is steered toward "Restore from iCloud". ``SettingsSheet`` is a searchable hub navigating over ``SettingsRoute`` with ``SettingsSearchIndex`` as its hand-written catalog; ``PrivacyDataSettingsView`` is the privacy control room — iCloud sync and typed-DELETE cloud deletion, sealed backups with informed-consent disclosures, HealthKit switches, plaintext JSON export via an allowlist projection that excludes sealed categories by construction, and the delete-everything funnel. The connective tissue is the nothing-destructive-happens-silently invariant: every data-destroying action routes through ``DestructiveConfirmation``, ``DeleteAllDataConfirmation`` enumerates exactly what is deleted, kept, and unreachable, and ``DeletingEverythingOverlay`` blocks interaction for the duration of a wipe. Both Settings entry points drive that wipe through their own instance of the shared ``DeleteEverythingFlow`` — one copy of the busy/success/failure state and its outcome alerts, deliberately per-screen so each screen's overlay, button disabling, and dismissal guards key off the wipe it actually started.

## Topics

### App Shell & Core State

- ``FernletStore``
- ``FernletApp``
- ``ContentView``
- ``FernletStoreLoader``
- ``LaunchPreparationService``
- ``BackupExclusionLaunchGate``
- ``FernletPriorUseMarker``
- ``FernletSheet``
- ``FernletTab``
- ``FernletNotificationDelegate``
- ``PendingIntentSheet``
- ``WidgetSnapshotMirror``
- ``PendingWidgetActionQueue``
- ``HealthSyncCoordinator``
- ``CoreDataHealthKitCacheCleaner``
- ``UserDefaultsAICallQuotaStore``
- ``FileAIAuditLogStore``
- ``FernletAIComposition``
- ``HomeView``
- ``AmbientCardsView``
- ``GentleOfferEngine``
- ``UITestSupport``

### Food & Nutrition

- ``FoodView``
- ``MealSheet``
- ``MealResolutionService``
- ``MealBuilder``
- ``FoundationDishDecompositionModel``
- ``MealDecompositionResolver``
- ``DishTemplateLexicon``
- ``FoodCaptureRouter``
- ``MealPhotoRecognizer``
- ``MealReviewSheet``
- ``RecipeSheet``
- ``RecipeDetailView``
- ``RecipeBookSheet``
- ``BarcodeScanView``
- ``BarcodeNotFoundView``
- ``BarcodeServingStepView``
- ``NutritionLabelCameraSheet``
- ``NutritionTargetsEditor``
- ``BrandedCatalogResourceLoader``
- ``FoodProductWebImporter``
- ``FoodProductWebSearch``
- ``RecipeShareCodec``
- ``ShoppingListBuilderView``
- ``WeeklyMealPlannerView``
- ``IngredientSubstitutionSheet``
- ``CookingModeView``
- ``CookingLiveActivityController``
- ``RecentBites``
- ``MealPhotoPresence``

### Movement & Workouts

- ``MoveView``
- ``WorkoutSuggestionSheet``
- ``GuidedWorkoutAvailability``
- ``GuidedWorkoutCardState``
- ``GuidedWorkoutSheet``
- ``GuidedWorkoutEditorSheet``
- ``WorkoutSheet``
- ``WorkoutPlanSheet``
- ``WorkoutSetupSheet``
- ``WorkoutLocationSetupView``
- ``ActivityPickerSection``
- ``WorkoutPlanningService``
- ``WorkoutPlanningContext``
- ``WorkoutLiveActivityController``
- ``LiveActivityStarter``
- ``WorkoutTombstoneStore``
- ``ProgressPhotoSection``
- ``ProgressPhotoDetailView``
- ``TrainerExportBundle``
- ``TrainerExportOptions``
- ``TrainerExportView``
- ``GoalPresetCards``
- ``EquipmentIconLibrary``

### Proximity, Social & Companion Customization

- ``FriendsView``
- ``DisposableCameraView``
- ``CameraCaptureController``
- ``IslandViewfinderMetrics``
- ``ConnectionInspector``
- ``FriendListView``
- ``SendGoodVibesLabel``
- ``AwayHeartsCopy``
- ``ActivitiesView``
- ``JoinPromptSheet``
- ``SessionChatPanel``
- ``VerifyQRDisplaySheet``
- ``ProximityRecipeShareSheet``
- ``ProximityRecipeShareReviewSheet``
- ``ClothingShareCodec``
- ``FriendShopView``
- ``CreationStudioView``
- ``WardrobeView``
- ``ShopAlert``
- ``ShopAlertContext``
- ``ZoomablePixelCanvas``
- ``ItemTextureRenderer``
- ``CompanionView``
- ``PetInteractionGovernor``
- ``MilestonesView``

### Cycle, Journal & Private Data

- ``PrivateHubView``
- ``JournalSealingCoordinator``
- ``JournalSealingContext``
- ``WorryBoxService``
- ``SealedBackupCoordinator``
- ``SealedBackupService``
- ``SealedBackupCrypto``
- ``SealedBackupContext``
- ``SealedBackupRestoreOutcome``
- ``StressService``
- ``StressScoringContextProviding``
- ``AgeAssuranceStore``
- ``AgeAssuranceRequest``
- ``AgeGateNotice``
- ``CycleTrackerView``
- ``CycleDayDetailView``
- ``LogPeriodSheet``
- ``LogIntimacySheet``
- ``JournalView``
- ``FirstAidView``

### Onboarding, Settings & Shared UI

- ``OnboardingCoordinatorModel``
- ``OnboardingCoordinator``
- ``ExistingCloudDataDetecting``
- ``OnboardingStorageChoiceView``
- ``OnboardingLockSetupView``
- ``SettingsSheet``
- ``SettingsRoute``
- ``SettingsSearchIndex``
- ``PrivacyDataSettingsView``
- ``AppLockSettingsView``
- ``DestructiveConfirmation``
- ``DeleteAllDataConfirmation``
- ``DeleteEverythingFlow``
- ``DeletingEverythingOverlay``
- ``FernletDataExport``
- ``PrivacyPolicyView``
- ``PhotoCaptureControl``
- ``MonthCalendarCard``
