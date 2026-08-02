# Fernlet File Index

This index maps the main project files to their responsibilities. It is intended as a quick orientation guide for app navigation, feature work, tests, and documentation.

Last updated: 2026-07-19. Paths are written from the directory containing the repo checkout, so `Fernlet/…` is the repo root: `Fernlet/Fernlet/…` is the app target folder, `Fernlet/FernletKit/…` is the local Swift package, and `Fernlet/FernletTests/…` etc. are the sibling test/extension targets.

## FernletKit Package (Module Map)

The on-device source is carved into the `FernletKit` local SPM package (see [SPM-Module-Carveup-Plan.md](SPM-Module-Carveup-Plan.md)). The app links one umbrella product; the layered dependency DAG *is* the S3 privacy wall — the walled `AIProviders` and `CloudKitSync` modules list no `Private*` dependency, so a forbidden `import` is a hard build error. Per-file rows appear in the feature sections below; this table is the module-level map.

| Module | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Package.swift` | Package manifest: the layered target DAG, per-target MainActor isolation choices, and the single external dependency (CryptoSwift, for FernletLock's Scrypt KDF). |
| `FernletFoundation` | Layer 0 — shared utilities: dates, keychain helpers, audit log, storage preferences, monotonic clock, startup timing, backup exclusion. |
| `FernletCrypto` | Layer 0 — pure sealing primitives (`ColumnCrypto`, CryptoKit-only). |
| `FernletDomainModel` | Layer 1 — portable, nonisolated domain value types (nutrition/workout/wellbeing/companion models, settings aggregate, wire DTOs). |
| `FernletScoring` | Layer 1 — scoring/goal-weight/meal-parse/workout-plan engines, abstract period-scoring signal types, and the stress engine. |
| `FoodCatalog` | Layer 1 — USDA food search/scoring; owns the bundled read-only `FoodCatalog.sqlite` resource (loaded via `Bundle.module`). |
| `FernletPersistence` | Layer 2 — persistence contract: `FernletRepository` protocol, `FernletSnapshot` aggregate, and the per-store repositoring protocols. |
| `LocalPersistence` | Layer 2 — Foundation-only local JSON repository, log-record DTOs, and the derived-signal / Tier-2 memory engines. |
| `PrivateStoreCore` | Layer 2.5 — sealed local-only Core Data stack shared by the `Private*` stores (protected side of the S3 wall). |
| `PrivateHealthStore` | Layer 3 — sealed cycle/intimacy store: `PeriodTrackerStore`, cycle prediction, menstrual-narrative and intimacy repositories, raw cycle types. |
| `PrivateMemoryStore` | Layer 3 — sealed journal and worry-box narrative repositories. |
| `PrivateMediaStore` | Layer 3 — at-rest AES-GCM-sealed photo stores (mesh friend photos, meal photos, progress photos). |
| `PeriodContextBridge` | Layer 4 — sanctioned egress converting raw cycle data into the abstract period signals scoring consumes. |
| `AIContext` | Layer 4 — typed AI context payloads (the de-identification contract), the `MemoryAgent` gatekeeper, and the AI audit log. |
| `AIProviders` | Layer 5 — **walled** on-device Foundation-model consumers; structurally cannot import any `Private*` store. |
| `CloudKitSync` | Layer 6 — **walled** iCloud-synced Core Data + CloudKit persistence; must never name a sealed type. |
| `StoreCore` | Layer 7 — store-side services lifted out of the app: derived signals, snapshot saves, AI retry queue, saved recipes, coins/custom items/milestones. |
| `DiaryStore` | Layer 8 — the portable `@Observable` diary slice of `FernletStore` (days, meals, journals, goals, scoring methods); the app-side facade forwards to it. |
| `HealthKitGateway` | Layer 6 — HealthKit platform shim: `HealthKitService`, workout sync, activity-type catalog, authorization seams. |
| `FernletLock` | Layer 6 — app-lock service (Scrypt via CryptoSwift); drains the sealed pending-narrative buffer on unlock. |
| `AppServices` | Layer 6 — assorted platform services: notifications, WeatherKit, nutrition-label OCR, barcode scanning, food image classification, share-extension import queue. |
| `ProximityKit` | Layer 6 — the peer-to-peer subsystem as one black-box shim: mesh transport, identity, trust, ranging, and the recipe/photo/clothing/heart/message/moderation flows. |

## App Entry And Shell

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/FernletApp.swift` | SwiftUI app entry point. Creates the shared persistence, app store, period tracker, launch preparation service, and lock service objects. |
| `Fernlet/Fernlet/ContentView.swift` | Main app container and navigation shell. Hosts primary tabs, launch state, personal screen, lock gate integration, quick sheets, and meal/journal notifications. |
| `Fernlet/FernletKit/Sources/FernletUI/FernletUIComponents.swift` | Shared UI primitives: adaptive color tokens, headers, chip styles, sheet fields, section pickers, layout helpers, searching pulse, medallion/coin glyphs. |
| `Fernlet/FernletKit/Sources/FernletUI/FernletPrimitives.swift` | `FernletCard`, `SectionLabel`, `EmptyState` — the cross-screen layout primitives extracted from HomeView for package-resident views. |
| `Fernlet/FernletKit/Sources/FernletUI/FernletTheme.swift` | App-wide color palette, theme defaults, custom light/dark background support, and UIKit/SwiftUI color vending. |
| `Fernlet/FernletKit/Sources/FernletUI/FernletDesignSystem.swift` | Design-system foundation: the `FernletTextRole` serif/sans type scale, warm token palette, 8pt spacing/radii/shadow/motion tokens, and bundled-font resolution. |
| `Fernlet/FernletKit/Sources/FernletUI/ModelColors.swift` | SwiftUI `Color` extensions mapping domain enums (`MealType`, `WorkoutSplit`, `WorkoutType`…) to palette colors; split out so domain models stay Foundation-only. |
| `Fernlet/Fernlet/FernletNotificationDelegate.swift` | `UNUserNotificationCenterDelegate` that presents gentle notifications while foregrounded and routes a check-in tap to the journal sheet via a pending-open flag `ContentView` consumes. |
| `Fernlet/Fernlet/UITestSupport.swift` | DEBUG-only launch hooks for UI tests: central reader of the `FERNLET_UI_TEST_*` appearance-test flags (seed demo, bypass private lock, jump-to-screen). |
| `Fernlet/Fernlet/Assets.xcassets` | Image and color assets used by the app. |
| `Fernlet/Fernlet/Info.plist` | App bundle metadata and platform configuration. |
| `Fernlet/Fernlet/Fernlet.entitlements` | App capability entitlements. |

## Feature Views

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/HomeView.swift` | Home dashboard with companion state, quick logging, signal trends, macro summaries, hygiene, and photo wall UI. |
| `Fernlet/Fernlet/FoodView.swift` | Food logging, recipes, imported recipe review, ingredient editing, meal creation, macro display, saved recipe book, and Safari presentation. Also hosts the in-file `RecipeDetailView` (sealed photo, macros, edit/log/share actions, in-app Safari source link). |
| `Fernlet/Fernlet/MoveView.swift` | Movement/workout screen with workout logging, suggestions, workout rows, and goal summaries. |
| `Fernlet/Fernlet/ActivityPickerSection.swift` | Activity-mode workout picker, recent activity shortcuts, and activity-specific workout fields. |
| `Fernlet/Fernlet/JournalView.swift` | Journal calendar, prompts, entry creation/editing, day detail, day nutrition breakdowns, and daily edit sheets. |
| `Fernlet/Fernlet/PeriodTrackerView.swift` | Cycle tracking main view. |
| `Fernlet/Fernlet/PeriodDayDetailView.swift` | Detail view for a specific period/cycle day. |
| `Fernlet/Fernlet/LogPeriodSheet.swift` | Sheet for logging period events. |
| `Fernlet/Fernlet/PrivateHubView.swift` | Private hub screen with private-section navigation. |
| `Fernlet/Fernlet/SocialHubView.swift` | Social hub entry point for the Friends photo wall and active disposable-camera session flow. |
| `Fernlet/Fernlet/ConnectView.swift` | Friends tab photo wall, nearby-discovery status, connection-success transition, session photo review, and full-screen saved-photo feed. Presents `DisposableCameraView` while a Friends session is active. |
| `Fernlet/Fernlet/CreationStudioView.swift` | Animal-Crossing-style grid fabric editor for designing custom clothing/accessories (per-slot pixel canvas, palette, live companion preview). Pushed from the customization sheet. |
| `Fernlet/Fernlet/WardrobeView.swift` | The closet: owned custom items grouped by slot; equip/unequip, edit, delete, mark shop-shareable. Entry point into the Creation Studio. |
| `Fernlet/Fernlet/CustomItemRendering.swift` | Renders a palette-indexed `ItemGridTexture` to a cached `CGImage` (`ItemTextureRenderer`) and the `CustomItemThumbnail` preview tile. |
| `Fernlet/Fernlet/CompanionVectorAssets.swift` | Vector companion renderer (`CompanionView` + body/accessory/clothing/side-item layers). Hosts `CompanionCustomItemLayer`, which draws equipped user-designed grid items in per-slot regions. |
| `Fernlet/Fernlet/OnboardingView.swift` | First-run profile setup, nutrition profile editing, and nutrition preview UI. |
| `Fernlet/Fernlet/SettingsSheet.swift` | Settings sheet and user preferences UI. |
| `Fernlet/Fernlet/SharedSheets.swift` | Reusable logging sheets for water, sleep, goals, hygiene, and texture entries. |
| `Fernlet/Fernlet/AmbientCards.swift` | `AmbientCardsView` — low-cost ambient Home surfaces: once-a-day gentle offer, look-back journal card, macro-gap meal nudge, forgotten-favorite/workout nudges, and a preventive-care micronutrient bubble. |
| `Fernlet/Fernlet/CompanionAmbienceLayer.swift` | Full-bleed environment layer behind the Home companion: local-hour time-of-day tint (`CompanionDayPhase`) plus optional WeatherKit sky accents (clouds/rain/snow). |
| `Fernlet/Fernlet/QuickMoodRow.swift` | `QuickMoodRow` — one-tap mood check-in row of `FeelingTag` chips (Home + Journal) logging a tag-only journal entry via `logQuickMood`, updating today's check-in in place. |
| `Fernlet/Fernlet/GoalPresetCards.swift` | `GoalPresetCards` — selectable goal preset cards (one per `GoalType`) surfacing the paired nutrition + training setup each goal configures. |
| `Fernlet/Fernlet/JournalPromptLibrary.swift` | `JournalPromptLibrary` — static curated journaling prompts with a deterministic per-`dateKey` daily rotation (deliberately non-AI, journal text stays walled from models). |
| `Fernlet/Fernlet/MilestonesView.swift` | `MilestonesView` — lifetime-milestones surface: warm cumulative care counts and coin gifts from the append-only ledger, plus a keepsake-medallion shelf. |
| `Fernlet/Fernlet/PetInteractionGovernor.swift` | `PetInteractionGovernor` — gentle anti-compulsion pacing state machine for tap-to-pet (rolling window → settling → calm-idle), state kept in device-local `UserDefaults`. |
| `Fernlet/Fernlet/PhotoCaptureControl.swift` | `PhotoCaptureControl` — reusable camera-first / library photo-capture control shared by meal capture and progress photos, with raw-`Data` or `UIImage` sinks. |
| `Fernlet/Fernlet/LogIntimacySheet.swift` | `LogIntimacySheet` — sealed intimacy-log entry sheet (date, note, protection used) written through the fail-closed decrypt/seam gate. |
| `Fernlet/Fernlet/TrainerExportView.swift` | `TrainerExportView` — trainer/nutritionist export review + consent screen: pick optional includes and see exactly what is always/never shared before preparing the file. |
| `Fernlet/Fernlet/LinkMetadataPrototypeView.swift` | DEBUG-only D11 link-metadata prototype (temporary): tests whether sender-supplied `LPLinkMetadata` survives into a sent iMessage bubble; not wired into any screen. |

## Wellbeing, Stress, And First Aid

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/FirstAidView.swift` | `FirstAidView` / `FirstAidTool` — calm first-aid sheet routing to breathing, 5-4-3-2-1 grounding, and the Worry Box, plus a static 988 support row. |
| `Fernlet/Fernlet/BreathingExerciseView.swift` | `BreathingExerciseView` — animated breathing circle (box 4-4-4-4 / relax 4-7-8, 1–3 min, optional haptics); a completed session reports its interval to the caller for Apple Health. |
| `Fernlet/Fernlet/GroundingView.swift` | `GroundingView` — 5-4-3-2-1 grounding: a stepped tap-to-advance sensory flow with a per-sense colour wash, ending on a soft affirmation. |
| `Fernlet/Fernlet/WorryBoxView.swift` | Worry Box surfaces: `WorryEntryView` write-and-let-go entry flow (hosted in First Aid) and the Private-hub kept-worries list with per-worry release. |
| `Fernlet/Fernlet/WorryBoxService.swift` | `WorryBoxService` — app-side owner of sealed, local-only Worry Box notes (user-lock/device-key model, never synced, absent from SealedBackup). |
| `Fernlet/Fernlet/StressService.swift` | `StressService` (`StressScoringContextProviding`) — opt-in body-signals stress estimate joining HealthKit HRV/RHR/respiration/temp with diary confounders via `StressEngine`; baselines in a device-local sidecar. |
| `Fernlet/FernletKit/Sources/FernletScoring/StressEngine.swift` | Pure personal-baseline stress estimator (`StressDaySample`) mapping HRV/resting-HR deviation to gentle wellness states. |
| `Fernlet/Fernlet/StressExplainerSheet.swift` | `StressExplainerSheet` — gentle "how we estimate this" body-signals explainer (wellness framing, not-medical disclaimer) that can chain into First Aid. |
| `Fernlet/Fernlet/GentleOffers.swift` | `GentleOfferKind` + pure gating/rotation logic for the once-per-day ambient gentle-offer card (breathing / worry box / short walk). |

## Workouts And Guided Training

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/WorkoutSetupView.swift` | `WorkoutSetupSheet` — captures durable workout context: split, training location/equipment, weekly frequency, experience, interests, and areas to work around. |
| `Fernlet/Fernlet/WorkoutLocationSetupView.swift` | `WorkoutLocationSetupView` — location creator + equipment picker: choose where you train, then check off equipment in a categorized grid mapped to coarse planning capabilities. |
| `Fernlet/Fernlet/WorkoutPlanningService.swift` | `WorkoutPlanningService` — split recommendation, day-plan generation, and AI day-plan adjustment extracted from `FernletStore` (owns the FoundationModels workout dependency). |
| `Fernlet/Fernlet/GuidedWorkout.swift` | `GuidedWorkoutSheet` — in-app guided workout runner (current exercise, set X of Y, live rest countdown) driven by `store.guidedRunState` and mirrored to the Live Activity. |
| `Fernlet/Fernlet/GuidedWorkoutEditorSheet.swift` | `GuidedWorkoutEditorSheet` — manual editor for a suggested session (per-exercise sets/reps/rest override, remove, reorder, add from catalog); saving replaces the session in today's plan. |
| `Fernlet/Fernlet/EquipmentIcons.swift` | `EquipmentIconLibrary` + a lightweight SVG renderer — editable stroke-only vector glyphs for gym equipment / locations, tinted to foreground, with SF Symbol fallback. |
| `Fernlet/Fernlet/ProgressPhotoTimeline.swift` | `ProgressPhotoSection` — Move-tab gym progress-photo timeline: sealed-at-rest body photos behind the global Fernlet lock, with camera/library add and tap-through detail. |

## Custom Clothing, Coins, And Friend Shop

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/ZoomablePixelCanvas.swift` | `ZoomablePixelCanvas` — zoomable/pannable `UIScrollView` pixel-painting surface for the clothing editor (pinch-zoom, two-finger pan, one-finger paint), rendering via `ItemTextureRenderer`. |
| `Fernlet/Fernlet/FriendShopView.swift` | `FriendShopView` — browse friends' post-session shops and buy items with coins (banned-seller filtered, with per-item report). |
| `Fernlet/Fernlet/ClothingShareCodec.swift` | `ClothingShareCodec` — domain⇄wire codec for the in-person clothing shop: builds the device's own-designs `ClothingCatalogPayload` and re-sanitizes every incoming item before use. |
| `Fernlet/FernletKit/Sources/StoreCore/CoinLedgerService.swift` | `@MainActor @Observable CoinLedgerService` owning the coin ledger in memory with debounced append-only persistence. |
| `Fernlet/FernletKit/Sources/StoreCore/CustomItemService.swift` | `@MainActor @Observable CustomItemService` owning the custom-item collection with debounced append/upsert persistence. |
| `Fernlet/FernletKit/Sources/StoreCore/MilestoneLedgerService.swift` | `@MainActor @Observable MilestoneLedgerService` owning the milestone ledger with debounced append-only persistence. |
| `Fernlet/FernletKit/Sources/CloudKitSync/CoinLedgerRepository.swift` | Per-row Core Data + iCloud coin-ledger store (`CoinLedgerRepository`), append-only JSON payload rows. |
| `Fernlet/FernletKit/Sources/CloudKitSync/CustomItemRepository.swift` | Per-row Core Data + iCloud custom-item store (`CustomItemRepository`), append/upsert-only JSON payload rows. |
| `Fernlet/FernletKit/Sources/CloudKitSync/MilestoneLedgerRepository.swift` | Per-row Core Data + iCloud milestone-ledger store (`MilestoneLedgerRepository`), append-only, no delete path. |
| `Fernlet/FernletKit/Sources/ProximityKit/ClothingSharing/MeshClothingShop.swift` | Friend-mesh clothing shop: accumulates pairwise-sealed `.clothingCatalog` payloads from committed slots, then opens a 1-hour memory-only post-session browse window; receive/window state only, never persisted. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/ClothingSharePayloads.swift` | In-person clothing-shop wire models: `ClothingCatalogPayload` carrying a peer's anonymous designer id, display name, and capped deterministically-ordered `CustomizationItem`s. |

## Onboarding

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/OnboardingCoordinator.swift` | Onboarding state machine, step progression, storage choice, lock setup deferral, iCloud data detection, and `OnboardingDefaults` keys. |
| `Fernlet/Fernlet/OnboardingWelcomeView.swift` | First onboarding screen presenting the Fernlet welcome message and entry CTA. |
| `Fernlet/Fernlet/OnboardingPermissionsView.swift` | Onboarding step for requesting HealthKit and notification permissions. |
| `Fernlet/Fernlet/OnboardingStorageChoiceView.swift` | Onboarding step for choosing local vs. iCloud storage, with existing cloud data detection and migration summary. |
| `Fernlet/Fernlet/OnboardingLockSetupView.swift` | Onboarding step for setting up a passcode or biometrics-only lock, with a skip/defer path. |

## Lock And Privacy

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/FernletLockUI/FernletLockGate.swift` | View modifier that gates protected UI behind the Fernlet lock state. |
| `Fernlet/Fernlet/AgeAssuranceStore.swift` | `AgeAssuranceStore` — owns the device-local age determination behind the intimacy (16+) and mesh-chat (13+) gates. Persists to the never-synced sidecar; fail-closed on a fresh or undecodable record. |
| `Fernlet/Fernlet/AgeAssuranceRequest.swift` | The single seam to Apple's `DeclaredAgeRange` framework: one prompt for gates 13/16/18, plus the `.requestsAgeRange` view modifier. Every failure path lands on undetermined. |
| `Fernlet/Fernlet/AgeGateNotice.swift` | `AgeGateNotice` — the locked-state row for an age-gated feature: states the true reason, and offers a re-check plus the manual confirmation only when the system never ruled. |
| `Fernlet/FernletKit/Sources/FernletLockUI/FernletLockView.swift` | Lock setup, unlock UI, numeric pad, passcode entry, and related lock interaction views. |
| `Fernlet/FernletKit/Sources/FernletLock/FernletLockService.swift` | Lock service protocols, lock state, credential types, crypto provider, keychain item handling, audit logging, and lock/unlock orchestration. |
| `Fernlet/FernletKit/Sources/FernletFoundation/KeychainHelpers.swift` | Low-level Keychain read/write/delete helpers shared by lock and identity services. |
| `Fernlet/FernletKit/Sources/FernletFoundation/FernletLockError.swift` | `FernletLockError` error enum for app-lock/passcode/biometric failures with localized descriptions. |
| `Fernlet/FernletKit/Sources/FernletCrypto/ColumnCrypto.swift` | Shared ChaChaPoly column-encryption helper (`ColumnCrypto`) sealing/opening per-column values under a per-label derived key. |
| `Fernlet/Fernlet/JournalSealingCoordinator.swift` | `JournalSealingCoordinator` (`JournalSealingContext`) — sealed journal management (content key, device fallback key, sealed-ID set, narrative repository) extracted from `FernletStore`; `isSealed` drives the snapshot text-strip. |
| `Fernlet/Fernlet/SealedBackupService.swift` | `SealedBackupCrypto` — AES-GCM seal/open of `SealedBackupRecord`s bound to the iCloud-Keychain escrow signing key. |
| `Fernlet/Fernlet/SealedBackupCoordinator.swift` | `SealedBackupCoordinator` (`SealedBackupContext`) — sealed iCloud backup/restore of Tier-2 memory, journals, and period narratives under the escrow key, extracted from `FernletStore`. |
| `Fernlet/Fernlet/DeleteAllDataConfirmation.swift` | `DeleteAllDataConfirmation` — the single shared destructive confirm dialog for "delete everything", funneling both Settings entry points to `FernletStore.deleteAllData`. |
| `Fernlet/Fernlet/PrivacyPolicyView.swift` | `PrivacyPolicyView` — in-app Privacy Policy screen rendering the policy in the app's voice/type, with a DEBUG-only draft banner. |
| `Fernlet/Fernlet/PrivacyDataSettingsView.swift` | Privacy and data settings screen for managing storage preferences, HealthKit toggles, and sealed backup options. Routes every destructive/OFF toggle through a pre-commit warning; surfaces the sealed-backup restore status + escrow-conflict banner (retry / re-link). |
| `Fernlet/Fernlet/DestructiveConfirmation.swift` | Reusable destructive-action confirmation (`DestructiveConfirmation` + `.destructiveConfirmation` modifier): the mutation runs only on an explicit destructive-role confirm, so no destructive settings toggle can ship without a warning. |

## Data, Persistence, And State

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/FernletDomainModel/` | Core domain models (formerly the app's `Models.swift`), split per area — see the Domain Models section. |
| `Fernlet/Fernlet/FernletStore.swift` | Main observable app store that coordinates repository data and app-level state changes. |
| `Fernlet/FernletKit/Sources/StoreCore/AIRetryQueueService.swift` | AI analysis retry queue; stores pending retry records and calls `onChange` on each mutation. Extracted sub-service of `FernletStore`. |
| `Fernlet/FernletKit/Sources/StoreCore/DerivedSignalsService.swift` | Derived signal computation and deferred post-launch rebuild scheduling. Extracted sub-service of `FernletStore`. |
| `Fernlet/FernletKit/Sources/StoreCore/DerivedSignalsRebuilder.swift` | Pure helper that rebuilds derived signals from a historical day window; used by `DerivedSignalsService`. |
| `Fernlet/FernletKit/Sources/StoreCore/SavedRecipeService.swift` | Observable saved recipe list manager; loads, adds, deletes, and persists saved recipes. Extracted sub-service of `FernletStore`. |
| `Fernlet/FernletKit/Sources/StoreCore/SnapshotSaveCoordinator.swift` | Debounced snapshot persistence coordinator and remote-change reload handler. Extracted sub-service of `FernletStore`. |
| `Fernlet/Fernlet/FernletStoreLoader.swift` | Async store bootstrap coordinator that manages `preparing → ready → failed` phase transitions at launch. |
| `Fernlet/Fernlet/DataExportBuilder.swift` | `FernletDataExport` + `FernletStore` builder — assembles the user's non-sealed data into one human-readable JSON export file (allowlist projection; sealed/sensitive data excluded by construction). |
| `Fernlet/Fernlet/TrainerExportBuilder.swift` | `TrainerExportBundle` / `TrainerExportOptions` + `FernletStore` builder — curated fail-closed-allowlist workout + nutrition export for a trainer/nutritionist, with opt-in extras. |
| `Fernlet/Fernlet/FernletStore+DemoSeed.swift` | DEBUG-only `FernletStore` extension that seeds today's diary with representative demo content (day-idempotent) so every tab renders populated cards for the UX appearance UI tests. |
| `Fernlet/FernletKit/Sources/LocalPersistence/LocalFernletRepository.swift` | Local JSON-style repository contract and implementation, snapshot/database records, derived signal creation, limits, and memory engine logic. |
| `Fernlet/FernletKit/Sources/CloudKitSync/CoreDataFernletRepository.swift` | Core Data-backed repository implementation. |
| `Fernlet/FernletKit/Sources/CloudKitSync/Persistence.swift` | Core Data persistence controller setup for runtime and previews/tests. |
| `Fernlet/FernletKit/Sources/CloudKitSync/CloudKitDataService.swift` | CloudKit record read/write service and `ExistingDataSummary` detection used during onboarding migration. |
| `Fernlet/FernletKit/Sources/FernletFoundation/StoragePreferences.swift` | Codable model for user storage preferences: iCloud sync, local backup exclusion, HealthKit capability toggles, and sealed backup flags. |
| `Fernlet/FernletKit/Sources/PrivateHealthStore/PeriodTrackerStore.swift` | Period tracker domain state, cycle events, symptom/flow models, cycle phase logic, HealthKit integration contract, and store behavior. |
| `Fernlet/FernletKit/Sources/PrivateHealthStore/MenstrualNarrativeRepository.swift` | Persistence for menstrual narrative entries. |
| `Fernlet/FernletKit/Sources/PrivateStoreCore/PendingNarrativeBuffer.swift` | Codable buffer for pending menstrual narrative payloads. |
| `Fernlet/FernletKit/Sources/CloudKitSync/SavedRecipe.swift` | Saved recipe model and repository implementations, including legacy JSON migration support. |
| `Fernlet/FernletKit/Sources/HealthKitGateway/ActivityTypeCatalog.swift` | Workout activity type search and HealthKit activity type mapping. |
| `Fernlet/FernletKit/Sources/FernletPersistence/FernletRepository.swift` | The abstract `FernletRepository` persistence contract for snapshot/day/tier-two load and save. |
| `Fernlet/FernletKit/Sources/FernletPersistence/FernletSnapshot.swift` | `FernletSnapshot` persisted aggregate value type serialized to/from storage. |
| `Fernlet/FernletKit/Sources/FernletPersistence/RemoteChangePublishingRepository.swift` | `RemoteChangePublishingRepository` refinement exposing an iCloud remote-change `AnyPublisher`. |
| `Fernlet/FernletKit/Sources/FernletPersistence/DayRecordRepositoring.swift` | Per-day persistence protocol (`DayRecordRepositoring`) plus the sanitize-barrier `DayRecordUpsert` mint. |
| `Fernlet/FernletKit/Sources/FernletPersistence/SavedRecipeRepositoring.swift` | `@MainActor` append/upsert-only saved-recipe persistence protocol (`SavedRecipeRepositoring`). |
| `Fernlet/FernletKit/Sources/FernletPersistence/CoinLedgerRepositoring.swift` | `@MainActor` append-only coin-ledger persistence protocol (`CoinLedgerRepositoring`). |
| `Fernlet/FernletKit/Sources/FernletPersistence/CustomItemRepositoring.swift` | `@MainActor` append/upsert-only custom-item persistence protocol (`CustomItemRepositoring`). |
| `Fernlet/FernletKit/Sources/FernletPersistence/MilestoneLedgerRepositoring.swift` | `@MainActor` milestone-ledger persistence protocol (`MilestoneLedgerRepositoring`); append-only, deliberately no delete. |
| `Fernlet/FernletKit/Sources/LocalPersistence/DayContentSummary.swift` | `DayContentSummary` precomputed content-count roll-up carried in the aggregate blob for single-read existing-data detection. |
| `Fernlet/FernletKit/Sources/LocalPersistence/DerivedSignalFactory.swift` | `DerivedSignalFactory` computing the rolling derived-signal window (mood/energy/eating/progression/micronutrient trends) from stored day pairs. |
| `Fernlet/FernletKit/Sources/LocalPersistence/LogRecords.swift` | Derived-table DTO records (`DailyLogRecord`) persisted alongside the local database. |
| `Fernlet/FernletKit/Sources/LocalPersistence/TierTwoMemoryEngine.swift` | `TierTwoMemoryEngine` deriving capped tier-two behavioral memories from the rolling 14-day window. |
| `Fernlet/FernletKit/Sources/CloudKitSync/DayRecordRepository.swift` | Per-row Core Data + iCloud day-history store (`DayRecordRepository`) with duplicate-row dedup by `dateKey`. |
| `Fernlet/FernletKit/Sources/CloudKitSync/RowPayloadCoders.swift` | `RowPayloadCoders`: single source of truth for the per-row JSON encoder/decoder config (sorted keys + ISO-8601 dates). |
| `Fernlet/FernletKit/Sources/CloudKitSync/MultiDeviceSyncWarning.swift` | Pure `MultiDeviceSyncWarning` classifier for the "devices will diverge without iCloud" warning state. |
| `Fernlet/FernletKit/Sources/CloudKitSync/SealedBackupRecord.swift` | Sealed-backup transport DTOs (`SealedBackupRecord`, `SealedBackupPayloadType`): the opaque encrypted CloudKit record shape. |
| `Fernlet/FernletKit/Sources/DiaryStore/DiaryStore.swift` | `@MainActor @Observable DiaryStore`: the portable diary-state slice (scoring, meal/recipe/workout/journal/settings) carved from `FernletStore`. |
| `Fernlet/FernletKit/Sources/PrivateStoreCore/PrivatePersistenceController.swift` | `PrivatePersistenceController`: dedicated local-only (never-iCloud) Core Data store for sealed, encrypted entities. |
| `Fernlet/FernletKit/Sources/PrivateHealthStore/IntimacyLogRepository.swift` | Sealed Core Data repository for `IntimacyLog` records (ChaChaPoly column-encrypted intimacy notes). |
| `Fernlet/FernletKit/Sources/PrivateHealthStore/IntimacyLogStore.swift` | `@MainActor IntimacyLogStore`: the fail-closed, visibility-gated funnel for every intimacy sealed-note read/write. |
| `Fernlet/FernletKit/Sources/PrivateMemoryStore/JournalNarrativeRepository.swift` | Sealed journal-narrative store: `JournalNarrative` model, `JournalNarrativeStoring` protocol, and its encrypted repository. |
| `Fernlet/FernletKit/Sources/PrivateMemoryStore/WorryNarrativeRepository.swift` | Sealed, device-only Worry Box store: `WorryNarrative` model, `WorryStoring` protocol, and its encrypted repository. |
| `Fernlet/FernletKit/Sources/PeriodContextBridge/PeriodContextBridge.swift` | Period-module egress bridge: raw→abstract cycle conversions (`PeriodPhaseBand`) exporting only coarse enums past the S3 wall. |
| `Fernlet/FernletKit/Sources/PeriodContextBridge/PeriodPhaseTrendEngine.swift` | `PeriodHealthTrend` device-sealed per-phase wellbeing trend (coarse direction + confidence band) from the user's own history. |

## Domain Models (FernletDomainModel)

The portable value-type layer that replaced the app's old `Models.swift`, split per area.

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/FernletDomainModel/WellbeingModels.swift` | Day, health-context, journal, sleep, hygiene, goals, and daily-score value models (`FernletDay`, …). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/NutritionModels.swift` | Nutrition, food, meal, recipe, and macro/micronutrient value models (`UserNutritionProfile`, …). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/WorkoutModels.swift` | Workout, exercise, muscle, and equipment value models (`Workout`, …). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/WorkoutProgram.swift` | Workout program/training model value types: `ExperienceLevel`, `WorkoutProfile`, training-split selection. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/WorkoutRestGuidance.swift` | Evidence-based default rest-between-sets table (`WorkoutRestGuidance`) keyed by movement `Demand` and training goal. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/CompanionModels.swift` | Companion appearance, workshop, and texture value models (`WorkshopData`, `TextureEntry`). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/SettingsModel.swift` | `FernletSettings` app-settings serialization aggregate (hydration, companion, equipped items, designer provenance). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/AgeAssurance.swift` | `AgeGate` (13/16/18), `AgeGateVerdict`, `AgeAssuranceProvenance`, and `AgeAssuranceRecord` — the pure age-gate rules: fail-closed, a below-gate verdict is unappealable, and provenance is asymmetric (it can close a gate but not open one). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/NavigationEnums.swift` | Screen/widget/shortcut navigation enums (`FernletScreen`, `ConnectionInspectorMode`). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ScoringValueTypes.swift` | Pure scoring value types (`ScoringWeights`) carved out of the app-layer scoring logic. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/FoodItemSearch.swift` | Pure relevance-search value logic over `FoodItem` plus a restaurant-chain brand lexicon (`FoodItemSearch`, `FoodBrandLexicon`). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/EnumDecodeCompat.swift` | Forward-compatible decode helpers (`EnumDecodeCompat`) for synced raw-value enums: park and re-adopt unknown tokens via side channels. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/AIAnalysisRetryRecord.swift` | Codable retry-queue record (`AIAnalysisRetryRecord`) for pending AI-analysis payloads; element type of `FernletSnapshot.retryQueue`. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/AIDestination.swift` | `AIDestination` enum naming where an AI call is routed (on-device FoundationModels or web nutrition lookup). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/TierTwoMemoryRecord.swift` | Codable tier-two behavioral memory record (`TierTwoMemoryRecord`) referenced by the repository and memory agent. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/DiagnosticLanguage.swift` | Pure best-effort classifier (`DiagnosticLanguage`) flagging clinical/diagnostic language to screen out of AI prompts and stored memories. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/CustomItemModels.swift` | User-designed custom clothing/accessory models: `ItemSlot` taxonomy, palette-indexed grid textures, `CustomizationItem`. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ItemDesigner.swift` | `ItemDesigner` provenance value carrying only an anonymous, stable designer id for "designed by …" attribution. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ItemNameModeration.swift` | Pure profanity/slur name gate (`ItemNameModeration`) for items listed for sale in the clothing shop. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ClothingModeration.swift` | Value types and pure verdict math for the in-person clothing-shop report/ban moderation ledger (`ReportReason`). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ClothingShopLimits.swift` | Shared constants and a wire-boundary sanitizer (`ClothingShopLimits`) clamping untrusted peer-received shop items. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/CoinEconomy.swift` | Append-only coin-ledger model (`CoinLedgerEntry`, `CoinLedgerKind` earn/spend) and balance-aggregation math with structural idempotency. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/MilestoneLedger.swift` | Append-only cumulative care-milestone ledger model (`MilestoneEventKind`, `MilestoneLedgerEntry`); lifetime counts that survive resets. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/Closeness.swift` | Deterministic closeness math and close-friend slot assignment: `FriendInteractionDayCounts` and capped daily warmth points. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/FriendState.swift` | Friend-facing fuzzy wellbeing state (`FriendFuzzyState`) and its sealed shareable payload, derived from the state enum, never the score. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/HeartSharing.swift` | Wire model (`HeartPayload`) and presentation math for proximity "send good vibes" hearts between friends. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ActivityModels.swift` | Pure value types for proximity group activities: host-signed versioned rosters, join tokens, and `ActivityLimits`. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ProximityCoordinatorEnums.swift` | Top-level proximity enums (`ProximityRole`, `ProximityMode`, `ProximityRangingMode`) hoisted out of `ProximityCoordinator`. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ProximityPersistenceRecords.swift` | Codable proximity trust/audit DTOs (`ProximityTrustedPeerRecord`) for the persisted, synced trust vault. |

## Food, Nutrition, And Recipe Services

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/FoodCatalog/FoodDataCatalog.swift` | USDA food item record decoder (compact + raw FDC), source-JSON loading for the DB generator, `FoodItemSearch` scorer, and recipe search helpers. |
| `Fernlet/FernletKit/Sources/FoodCatalog/FoodCatalog.swift` | `FoodCatalog` service: merges the SQLite bundled food source with the in-memory user-item snapshot; search via FTS candidate prefilter → `FoodItemSearch` scorer, plus ID/exact-name resolution. Replaces the old in-memory `allFoodItems` array. |
| `Fernlet/FernletKit/Sources/FoodCatalog/BundledFoodStore.swift` | `BundledFoodSource` protocol + read-only SQLite-backed `SQLiteBundledFoodSource` (FTS5 candidate query, id/exact lookups, hydration) and `InMemoryBundledFoodSource` for tests; shared `FoodCatalogSchema`. |
| `Fernlet/Fernlet/FoodCatalogDatabaseBuilder.swift` | Build-time generator that converts the `FoodDataSource/*.json` foods into the shipped read-only `FoodCatalog.sqlite` (run via the gated `FoodCatalogGenerationTests`). Not used at runtime. |
| `Fernlet/FoodDataSource/USDAFoodItems.json` | Source USDA food item dataset consumed by the build-time DB generator (not bundled at runtime). |
| `Fernlet/FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite` | The shipped read-only SQLite food catalog (FTS5), generated from `FoodDataSource/` and loaded via `Bundle.module`. |
| `Fernlet/Fernlet/WorkoutExercises.json` | Bundled exercise dataset consumed by the workout system. |
| `Fernlet/FernletKit/Sources/AIProviders/FoundationFoodSelection.swift` | Foundation model availability and food selection model helpers. |
| `Fernlet/FernletKit/Sources/AppServices/NutritionLabelScanner.swift` | Nutrition label scan result model, scan errors, and scanner implementation. |
| `Fernlet/Fernlet/NutritionLabelCameraSheet.swift` | Camera and image picker UI for capturing nutrition labels and reviewing scan results. |
| `Fernlet/FernletKit/Sources/AIProviders/RecipeWebImporter.swift` | Recipe import pipeline for extracting structured recipes from web content and metadata. |
| `Fernlet/Fernlet/RecipeShareCodec.swift` | Encodes and decodes recipes into a shareable text format for peer-to-peer recipe sharing. |
| `Fernlet/Fernlet/MealBuilder.swift` | Converts a `FoodSelectionPlan` and food candidates into structured `Meal` records and inline recipe definitions, with good-protein threshold logic. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/CustomIngredientUpsert.swift` | Resolves manual recipe ingredient inputs into `FoodItem` records, creating or updating custom food entries in the catalog. |
| `Fernlet/Fernlet/MealResolutionService.swift` | `MealResolutionService` + `MealPlausibility` — the quick-log meal-resolution cascade (AI decomposition → AI selection → lexicon → plan → heuristic) plus the micronutrient fallback and implausible-total gate. |
| `Fernlet/Fernlet/FoundationDishDecomposition.swift` | `FoundationDishDecompositionModel` — on-device Foundation Models decomposition of a meal description into catalog-resolved, scaled `Meal` components with a match confidence. |
| `Fernlet/Fernlet/DishTemplateLexicon.swift` | `DishTemplateLexicon` + JSON template types — loads `DishTemplates.json` for deterministic, count-aware dish-template lookup (the decomposition fallback path). |
| `Fernlet/Fernlet/FoodCaptureRouter.swift` | `FoodCaptureRoute` + router — auto-detects a captured photo (barcode / nutrition label / meal) and routes to the matching existing flow, or `.ambiguous` for a gentle chooser. |
| `Fernlet/Fernlet/MealPhotoRecognizer.swift` | `MealPhotoRecognizer` (+ host protocol) — on-device Vision food-photo classification that composes a text description into the existing `resolveMeals` cascade, always pausing at review. |
| `Fernlet/Fernlet/MealPhotoPolaroid.swift` | `MealPhotoPolaroid` — polaroid-framed meal-photo tile with lazy sealed-byte load and `MealPhotoPresence` classification (here / on other device / unreadable). |
| `Fernlet/Fernlet/RecentBites.swift` | `RecentBite` + `MealPhotoPresence` — pure 7-day windowing behind Home's "Recent bites" photo strip (resolves which photographed meals to show without reading sealed bytes). |
| `Fernlet/Fernlet/BarcodeScanView.swift` | `BarcodeResolveFlowView` / `BarcodeScanView` — scan a product barcode and resolve it (user items → catalog → gentle not-found that creates a food item with the barcode remembered). |
| `Fernlet/Fernlet/BrandedCatalogResourceLoader.swift` | `BrandedCatalogResourceLoader` — loads the ~364k-product branded food DB (`FoodCatalogBranded.sqlite`) via bundle-first or On-Demand Resource and attaches it as a secondary `FoodCatalog` source. |
| `Fernlet/Fernlet/FoodProductWebImporter.swift` | `FoodProductWebImporter` / `FoodProductWebSearch` / `ImportedFoodProduct` — on-device Foundation Models import of a branded product's nutrition from a web product page. |
| `Fernlet/Fernlet/NutritionTargetsEditor.swift` | `NutritionTargetsEditor` — Settings card to edit macro targets (calories/protein/fat overridable, carbs shown as the live rebalancing residual). |
| `Fernlet/FernletKit/Sources/FernletScoring/Scoring.swift` | Health scoring, goal weights, meal parsing, workout planning, workout suggestions, and date helpers. |
| `Fernlet/FernletKit/Sources/FernletScoring/PeriodScoringSignals.swift` | Abstract period-scoring vocabulary (`PeriodSignalStrength`, `PeriodPhaseSignal`, `PeriodScoringAdjustment`) consumed by the scoring engine. |
| `Fernlet/FernletKit/Sources/AppServices/BarcodeScanner.swift` | Vision still-photo product-barcode detection (`BarcodePayloadDetecting` seam + `VisionBarcodeDetector`/`BarcodeScanner`) over EAN-13/EAN-8/UPC-E, the fallback for devices lacking live `DataScannerViewController`. |
| `Fernlet/FernletKit/Sources/AppServices/FoodImageClassifier.swift` | On-device meal-photo image classification behind the `FoodImageClassifying` seam (`VisionFoodImageClassifier` via `VNClassifyImageRequest`), returning raw taxonomy labels; the photo never leaves the device. |

## AI Context And Providers

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/AIContext/AIContextPayload.swift` | `AIContextPayload` marker protocol and concrete payload types (food-selection, meal-decomposition, etc.) defining the exact allowlisted fields that may enter each AI prompt. |
| `Fernlet/FernletKit/Sources/AIContext/MemoryAgent.swift` | Gate routing Tier-2 memory into AI prompts through a destination allowlist, recency filter, confidence filter, and diagnostic-language post-classifier, returning a char-capped context string. |
| `Fernlet/FernletKit/Sources/AIContext/AIAuditLog.swift` | `AIAuditEntry` metadata record plus the in-session `AIAuditLog` actor logging each AI call's payload kind, destination, included field names, and memory char count — metadata only, never persisted. |
| `Fernlet/FernletKit/Sources/AIProviders/FoundationWorkoutAdjustment.swift` | On-device workout adjuster: `WorkoutAdjustmentCandidateBuilder` builds the equipment/injury-filtered, ranked, capped candidate pool and `FoundationWorkoutAdjustmentModel` maps a natural-language request to substitutions within it via FoundationModels. |

## Health And Launch Services

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/HealthKitGateway/HealthKitService.swift` | HealthKit service protocol and implementation, capability metadata, authorization snapshots, body/activity/cycle/mindfulness context, and authorization view model. |
| `Fernlet/FernletKit/Sources/HealthKitGateway/WorkoutHealthKitSync.swift` | HealthKit workout import pipeline; reads `HKWorkout` samples and upserts matching `Workout` records via a `WorkoutSyncContext`. |
| `Fernlet/Fernlet/HealthSyncCoordinator.swift` | `HealthSyncCoordinator` (`HealthSyncContext`) — HealthKit ingestion (daily-context merge, derived sleep, workout import/backfill/observe) extracted from `FernletStore`. |
| `Fernlet/Fernlet/CoreDataHealthKitCacheCleaner.swift` | `CoreDataHealthKitCacheCleaner` — concrete `HealthKitCacheClearing` that scrubs HealthKit-cached values from Core Data / the local DB, fail-closed so opt-out never silently "succeeds". |
| `Fernlet/Fernlet/WorkoutTombstoneStore.swift` | `WorkoutTombstoneStore` — persisted capped FIFO ring of removed workout ids so a resurrected orphan HealthKit sample is deleted-and-skipped rather than re-imported. |
| `Fernlet/FernletKit/Sources/PrivateHealthStore/CyclePredictionEngine.swift` | Statistical cycle prediction engine using historical period data to forecast next period start, flow patterns, confidence level, and predicted flow days. |
| `Fernlet/Fernlet/LaunchPreparationService.swift` | Launch preparation state and photo wall seed loading. |
| `Fernlet/FernletKit/Sources/FernletFoundation/StartupTiming.swift` | `os_signpost`-based startup timing probes for measuring and instrumenting app launch phases. |
| `Fernlet/FernletKit/Sources/AppServices/NotificationService.swift` | Thin `UNUserNotificationCenter` wrapper for the opt-in gentle daily check-in local reminder: authorization, status check, and scheduling. |
| `Fernlet/FernletKit/Sources/AppServices/WeatherKitService.swift` | Opt-in coarse-location WeatherKit service producing tiny derived snapshots (`WeatherComfort` walk-friendliness, `AmbientSky` sky bucket) for mood-recovery prompts and Home ambience; degrades to nil, leaking no raw data. |
| `Fernlet/FernletKit/Sources/FernletFoundation/FernletDate.swift` | Layer-0 date helpers (`FernletDate`): canonical `yyyy-MM-dd` day-key formatting, enumeration, and display. |
| `Fernlet/FernletKit/Sources/FernletFoundation/MonotonicClock.swift` | `MonotonicClock` protocol plus sleep-counting `SystemMonotonicClock` (`mach_continuous_time`) for the store-ban clock. |
| `Fernlet/FernletKit/Sources/FernletFoundation/FernletAuditLog.swift` | Privacy audit-log facade (`FernletAuditLog`) emitting os_log events with a test-observable capture-handler registry. |
| `Fernlet/FernletKit/Sources/FernletFoundation/BackupExclusion.swift` | Layer-0 helper (`BackupExclusion`) toggling `isExcludedFromBackupKey` across a Core Data store file and its sidecars. |
| `Fernlet/FernletKit/Sources/FernletFoundation/FernletFoundation.swift` | Overview/placeholder source standing up the layer-0 `FernletFoundation` module. |

## Social And Mesh Networking

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift` | Observable mesh network coordinator managing active/lightweight peer slots, proximity-join (15 cm commit gate), pairwise/mesh promotion, session open/closed state, member removal proposals, admission requests, friend-of-friend vouchers, photo session metadata, encrypted mesh payloads, coordinator beacons, and key rotation. Its observation loop explicitly finishes cancelled streams so repeated Friends-tab discovery sessions do not retain suspended observers. |
| `Fernlet/Fernlet/DisposableCameraView.swift` | Active Friends-session disposable-camera UI: `CameraCaptureController` (`@Observable`, queued `AVCaptureSession` lifecycle, rotation handling, and arm/wind gate), `CameraPreviewView`, and the full-screen camera. The session-info sheet exposes the 10-shot film count, open/closed access, mesh rename, participant options, friend-of-friend labels, diagnostics, removal requests, and end-session flow; admission requests and mesh errors are presented as popups. |
| `Fernlet/Fernlet/MeshAdmissionPromptSheet.swift` | Reusable sheet for reviewing and approving/declining peer join requests to a named mesh. Presented by the active disposable-camera session flow. |
| `Fernlet/Fernlet/FriendListView.swift` | Friend list screen for browsing trusted proximity peers with all/friends/blocked filters and block management. |
| `Fernlet/Fernlet/ActivitiesView.swift` | `ActivitiesView` — Group Activities screen (host form / nearby invites / hosting roster / joined states) off the Friends tab, driven by `ProximityActivityManager`. |
| `Fernlet/Fernlet/ActivityJoinPromptSheet.swift` | `ActivityJoinPromptSheet` — host's "someone wants to join" confirmation for Group Activities (pure presentation; shows the verified joiner fingerprint and inline admit errors). |
| `Fernlet/Fernlet/SessionChatPanel.swift` | `SessionChatPanel` — live-session ephemeral chat panel (memory-only transcript cleared at session end) over `MeshNetworkManager`. |
| `Fernlet/Fernlet/SafetyReportingView.swift` | `SafetyReportingView` — always-available report/block explainer and no-tolerance policy for shared shop items and people (App Store UGC compliance). |

## Proximity

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/ProximityKit/Engine/ProximityCoordinator.swift` | High-level coordinator for proximity sessions; orchestrates MultipeerConnectivity transport, signed identity/ranging-token handshake, UWB startup, heartbeat RTT, payload dispatch, and inspector recording. |
| `Fernlet/FernletKit/Sources/ProximityKit/Transport/MultipeerPeer.swift` | MultipeerConnectivity peer model plus persistent `MCPeerID` storage shared by active mesh transport and future trainer transport work. |
| `Fernlet/FernletKit/Sources/ProximityKit/Transport/MultipeerTransport.swift` | Neutral MultipeerConnectivity transport protocol, state, invite, inbound-message, error, and reserved trainer-service definitions. |
| `Fernlet/FernletKit/Sources/ProximityKit/Engine/ProximityCommitDetector.swift` | Rolling distance-window detector used by proximity commit and trainer tap gates. |
| `Fernlet/FernletKit/Sources/ProximityKit/Ranging/RangingProvider.swift` | Ranging provider contract plus shared distance and state models. |
| `Fernlet/FernletKit/Sources/ProximityKit/Transport/MeshMultipeerSession.swift` | Shared `MCSession` host for multi-peer mesh; `PeerChannelTransport` adapts per-peer state and data routing without managing the MC lifecycle directly. |
| `Fernlet/FernletKit/Sources/ProximityKit/Mesh/MeshSessionTypes.swift` | Mesh session slot, group-key, ranking-window sample, participant, and encryption-error support models extracted from the manager. |
| `Fernlet/FernletKit/Sources/ProximityKit/Mesh/MeshNameGenerator.swift` | Generates random human-readable two-word mesh names from adjective/noun word lists. |
| `Fernlet/FernletKit/Sources/ProximityKit/Ranging/NIRangingSession.swift` | NearbyInteraction UWB ranging session for measuring real-time distance and direction between Fernlet devices. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/FernletIdentityEnvelope.swift` | Ed25519-signed wire envelope for all peer-to-peer transfers, including canonical JSON encoding and verification. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/PayloadType.swift` | Peer-to-peer payload classification, envelope encryption mode, and payload summary models. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/MeshPayloads.swift` | Mesh descriptor, admission, removal, voucher, group-encryption, and coordinator-beacon wire models plus admission-token signing and verification. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/FriendPhotoPayloads.swift` | Friend-photo payload, session metadata, manifest, and missing-photo request wire models. |
| `Fernlet/FernletKit/Sources/ProximityKit/Identity/IdentityService.swift` | Per-device Ed25519 signing identity and X25519 key-agreement, with keys stored in Keychain under `AfterFirstUnlockThisDeviceOnly`. |
| `Fernlet/FernletKit/Sources/ProximityKit/Identity/ReplayCache.swift` | Rolling 24-hour envelope-ID cache for replay-attack prevention; injectable clock for deterministic testing. |
| `Fernlet/Fernlet/Proximity/Audit/ConnectionInspector.swift` | Live and historical proximity session logging, ranging mode/distance samples, RTT samples, event subsampling, and session lifecycle recording (`ProximityInspectorRecording`). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ConnectionSessionLog.swift` | Structured session log model capturing peer info, ranging state, transport counters, envelope records, and error events. |
| `Fernlet/Fernlet/Proximity/UI/ConnectionInspectorView.swift` | On-demand live connection inspector UI for real-time proximity diagnostics, distance, RTT, and fallback status. |
| `Fernlet/Fernlet/Proximity/UI/ConnectionInspectorHistoryView.swift` | View for browsing and reviewing historical proximity connection session logs. |
| `Fernlet/FernletKit/Sources/ProximityKit/UI/KeepFriendsPromptSheet.swift` | `KeepFriendsSection` + prompt sheet — session-end one-sided "keep as a friend?" affordance that mints a local-only trust-vault record (peer never notified). |
| `Fernlet/Fernlet/Proximity/UI/ProximityRecipeShareSheet.swift` | `ProximityRecipeShareSheet` + `ProximityRecipeShareDraft` — outbound sheet to share a recipe with a nearby Fernlet over the proximity channel. |
| `Fernlet/Fernlet/Proximity/UI/ProximityRecipeShareReviewSheet.swift` | `ProximityRecipeShareReviewSheet` — review an incoming proximity-shared recipe (title, servings, macros) before saving it. |
| `Fernlet/Fernlet/ProximityHostAdapter.swift` | Conforms `FernletStore` to the Proximity subsystem's `ProximityHost` seam (proximity display name, nearby-hearts opt-in). |
| `Fernlet/FernletKit/Sources/ProximityKit/Trust/TrainerAuditLog.swift` | Trusted peer records, `ProximityTrustPolicy`, and trainer-named audit event vocabulary shared by proximity sessions. |
| `Fernlet/FernletKit/Sources/ProximityKit/Trust/FriendSessionTrustPolicy.swift` | Friend-session trust-policy wrapper over `ProximityTrustVault`; blocked, revoked, and audit operations delegate to the vault while proximity-gated sessions remain permissive for remembered-trust checks. |
| `Fernlet/FernletKit/Sources/ProximityKit/Trust/ProximityTrustVault.swift` | Trusted proximity peer records and trainer audit event vault; implements `ProximityTrustPolicy`. Extracted sub-service of `FernletStore`. |
| `Fernlet/FernletKit/Sources/ProximityKit/UI/FriendPhotoReviewSheet.swift` | Review tile, review sheet, and photo-library saver for shared friend photos. |
| `Fernlet/FernletKit/Sources/ProximityKit/ForegroundAnchor/ProximityForegroundAnchor.swift` | Live Activity anchor that keeps proximity sessions alive when the app moves to the background. |
| `Fernlet/FernletKit/Sources/ProximityKit/ProximityHost.swift` | `@MainActor` host-protocol seam letting the mesh/recipe-share managers reach app state (display name, trusted peers, trust vault, block/fingerprint checks, nearby-hearts opt-in) without naming concrete `FernletStore`. |
| `Fernlet/FernletKit/Sources/ProximityKit/Activities/ProximityActivityManager.swift` | State-and-logic brain for Group Activities riding the friend mesh: roster state, host-authoritative join-token minting/verification, and a device-local never-synced sidecar surviving relaunch until expiry. |
| `Fernlet/FernletKit/Sources/ProximityKit/HeartSharing/ProximityHeartLedger.swift` | Device-local JSON sidecar for received hearts (Home bubble + 24h health-bar glow) plus the rolling 1-per-friend-per-5-minute rate limit enforced both directions; never synced. |
| `Fernlet/FernletKit/Sources/ProximityKit/Messaging/SessionMessageStore.swift` | Deliberately non-`Codable`, memory-only holder of the current friend-session chat transcript; sanitizes/caps/dedupes/rate-limits messages and clears them at every session end and formation. |
| `Fernlet/FernletKit/Sources/ProximityKit/Presence/PresenceManager.swift` | Standing presence radio on `fernlet-near` broadcasting only rotating pairwise-DH tags for nearby-friend recognition, and driving the on-demand short-lived pairwise heart send/receive handshake; memory-only. |
| `Fernlet/FernletKit/Sources/ProximityKit/Presence/ClosenessLedger.swift` | Device-local day-granularity per-friend interaction counters feeding the deterministic closeness score and close-slot assignment (with persisted hysteresis); capped, never synced. |
| `Fernlet/FernletKit/Sources/ProximityKit/Presence/FriendStateCache.swift` | Device-local cache of a friend's fuzzy wellbeing state + avatar appearance captured at the last in-person meet (`CachedFriendState`), with 30-day staleness treatment; never synced. |
| `Fernlet/FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift` | `@MainActor` `@Observable` manager for one-at-a-time in-person recipe sharing: nearby-recipient discovery, a single verified sealed connection, send-state machine, pending inbound shares, and diagnostics. |
| `Fernlet/FernletKit/Sources/ProximityKit/Trust/FriendMintingReview.swift` | Pure view-free decision logic for the post-session keep-as-friend prompt: chooses the session-end review mode and filters roster candidates for eligibility against the trust vault at presentation time. |
| `Fernlet/FernletKit/Sources/ProximityKit/Moderation/ModerationBanStore.swift` | Tamper-resistant 30-day designer store-ban clock: reinstall-proof via a dedicated Keychain service and clock-tamper-proof via a `mach_continuous_time` countdown plus a wall-clock high-water ratchet. |
| `Fernlet/FernletKit/Sources/ProximityKit/Moderation/ModerationContentHash.swift` | Stable content key an abuse report binds to: order-stable SHA-256 over a sanitized item's artwork (texture grid + slot), so relisting under a new id/name cannot evade a report. |
| `Fernlet/FernletKit/Sources/ProximityKit/Moderation/ModerationLedger.swift` | `@MainActor` append-only JSON sidecar of moderation report/retract rows keyed for idempotent de-dupe and supersede-by-`reporterSeq`; bounded, never synced. |
| `Fernlet/FernletKit/Sources/ProximityKit/Moderation/ModerationReportRelay.swift` | One-hop report wire: `SignedModerationReport`/`ModerationReportPayload` models plus verification of each row's Ed25519 signature against the transport-verified sender key (no transitive relay — the Sybil defense). |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/ActivityPayloads.swift` | Group Activities wire envelopes plus `schemaVersion`-gated join-token/roster-snapshot signing and verification and the `ActivityParamsHash` descriptor hash. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/CanonicalSignatureSerializer.swift` | Deterministic, cross-platform-stable positional length-prefixed binary canonical-byte serializer for Ed25519 signing, replacing JSON `.sortedKeys` to prevent cross-stack `signatureInvalid`. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/MessagePayloads.swift` | `TempMessagePayload` wire value type for a single sealed live-session chat message (id/text/sentAt); receiver sanitizes and length-caps before use. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/RecipeSharePayloads.swift` | `ProximityRecipeSharePayload` wire envelope wrapping a `ProximitySharedRecipe` for in-person recipe sharing, with a share-notes convenience check. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/SealedIntroductionEnvelope.swift` | Transport wrapper carrying only the ciphertext of a KA-sealed identity intro/ack for presence-heart handshakes, so a tag-replay forger cannot deanonymize the sender's identity. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/TrainerPayloads.swift` | `TrainerExportPayload` wire envelope carrying the opaque, size-bounded curated Trainer/Nutritionist export bundle; sealing-required so an unsealed send fails closed at verify. |

## Private Media Stores

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/PrivateMediaStore/PrivateMediaStore.swift` | Disk-backed mesh photo index with **AES-256-GCM at-rest encryption** of image/thumbnail bytes, thumbnail generation, hydration, FIFO eviction (1000 cap / 900 warn), and orphan cleanup. (Formerly `MeshPhotoCacheStore`.) |
| `Fernlet/FernletKit/Sources/PrivateMediaStore/PrivateMediaKeyStore.swift` | `PrivateMediaKeyProviding` + keychain-backed (backup-restorable, `AfterFirstUnlock`) AES key provider for `PrivateMediaStore`. |
| `Fernlet/FernletKit/Sources/PrivateMediaStore/FriendPhotoImageHelpers.swift` | `UIImage` resizing and thumbnail JPEG helpers for friend-photo sharing. |
| `Fernlet/FernletKit/Sources/PrivateMediaStore/MealPhotoStore.swift` | `MealPhotoStore`: on-device AES-256-GCM-sealed store for meal and other private photos with bounded downscale. |
| `Fernlet/FernletKit/Sources/PrivateMediaStore/ProgressPhotoStore.swift` | `ProgressPhotoStore`: sealed gym progress-photo timeline over `MealPhotoStore` bytes plus a GCM-sealed dated index. |

## Widgets, Live Activities, And App Intents

| File | Purpose |
| --- | --- |
| `Fernlet/FernletWidgets/FernletWidgetsBundle.swift` | `@main` `WidgetBundle` registering the companion widget (mood glyph + water) and the guided-workout Live Activity. |
| `Fernlet/FernletWidgets/WidgetSharedModels.swift` | Deliberately duplicated app-group models (`WidgetSnapshot`, `PendingWidgetAction`, `WidgetCompanionState`, day-key/JSON helpers) so the standalone widget extension avoids linking FernletKit. |
| `Fernlet/FernletWidgets/WaterPlusOneIntent.swift` | `AppIntent` behind the companion widget's interactive "+1 water" button; queues a pending action and reloads the widget timeline. |
| `Fernlet/FernletWidgets/WorkoutLiveActivity.swift` | Widget-target `Widget` rendering the Lock Screen card and Dynamic Island for the guided-workout rest-timer Live Activity. |
| `Fernlet/FernletWidgets/WorkoutActivityAttributes.swift` | `ActivityAttributes`/`ContentState` contract for the guided-workout Live Activity, compiled into both the app and widget targets. |
| `Fernlet/FernletWidgets/GuidedWorkoutRunState.swift` | Codable/Hashable value type for an in-progress guided workout, mirrored into the app-group container so Lock Screen intents can advance it. |
| `Fernlet/FernletWidgets/GuidedWorkoutRunStateStore.swift` | `NSFileCoordinator`-backed app-group reader/writer for the single in-progress `GuidedWorkoutRunState` JSON file. |
| `Fernlet/FernletWidgets/GuidedWorkoutActivityBridge.swift` | Shared bridge (app + widget targets) that syncs a `GuidedWorkoutRunState` onto the live workout Activity, updating or ending it. |
| `Fernlet/FernletWidgets/GuidedWorkoutLiveActivityIntents.swift` | `LiveActivityIntent`s for the guided-workout Live Activity's "Done set" and "Skip rest" Lock Screen buttons. |
| `Fernlet/Fernlet/WidgetBridge.swift` | `WidgetSnapshot` + bridge — app side of the FernletWidgets app-group JSON bridge: outbound benign snapshot and inbound pending widget actions (deliberately S3-walled twin types). |
| `Fernlet/Fernlet/WorkoutLiveActivityController.swift` | `WorkoutLiveActivityController` — app-side requester for the guided-workout Live Activity (starts one, ends any stale one; degrades silently when Live Activities are disabled). |
| `Fernlet/Fernlet/FernletNavigation.swift` | App navigation enums (`FernletTab`, `FernletSheet`) — split out of the design system when it moved into the FernletUI package target (`FernletSheet` references app-resident `FirstAidTool`). |
| `Fernlet/Fernlet/FernletAppIntents.swift` | App Intents — `LogWaterIntent` (background app-group queue append, no app launch), `LogMealIntent` / `OpenJournalIntent` (open the app to the matching sheet via a persisted deep-link). |
| `Fernlet/Fernlet/FernletShortcuts.swift` | `FernletShortcuts` (`AppShortcutsProvider`) — surfaces the log-water/log-meal/open-journal App Intents to Siri and Spotlight with natural phrases. |

## Share Extension

| File | Purpose |
| --- | --- |
| `Fernlet/FernletShareExtension/ShareViewController.swift` | Share-extension entry `UIViewController` that extracts the shared URL and enqueues it via `SharedRecipeImportQueueWriter`. |
| `Fernlet/FernletShareExtension/SharedRecipeImportQueueWriter.swift` | App-group JSON queue writer that records shared recipe URLs (`SharedRecipeImportRecord`) for the app to import later. |
| `Fernlet/FernletKit/Sources/AppServices/SharedRecipeImportQueue.swift` | App-group-backed queue of shared recipe-URL import records (`SharedRecipeImportRecord` with attempt/error tracking) handed off from the share extension for later import. |

## Tests

### Unit Tests

| File | Purpose |
| --- | --- |
| `Fernlet/FernletTests/FernletTests.swift` | Core app/domain tests. |
| `Fernlet/FernletTests/FernletPersistenceTests.swift` | Persistence behavior tests. |
| `Fernlet/FernletTests/FernletLockTests.swift` | Lock-related integration or behavior tests. |
| `Fernlet/FernletTests/FernletLockCryptoTests.swift` | Lock crypto tests. |
| `Fernlet/FernletTests/FernletLockServiceTests.swift` | Lock service tests plus local fake providers and harnesses. |
| `Fernlet/FernletTests/FernletTestHelpers.swift` | Shared test helper utilities. |
| `Fernlet/FernletTests/ActivityTypeCatalogTests.swift` | Activity type taxonomy, search, and HealthKit mapping tests. |
| `Fernlet/FernletTests/MoveRefactorTests.swift` | Move refactor taxonomy tests for workout modes, muscle groups, body regions, and equipment. |
| `Fernlet/FernletTests/HealthKitWorkoutTests.swift` | HealthKit workout logging configuration, duration default, and metadata helper tests. |
| `Fernlet/FernletTests/HealthKitDisableTests.swift` | Tests for disabling individual HealthKit capabilities via `StoragePreferences`. |
| `Fernlet/FernletTests/NutritionLabelScannerTests.swift` | Nutrition label scanner tests. |
| `Fernlet/FernletTests/PeriodTrackerTests.swift` | Period tracker domain tests. |
| `Fernlet/FernletTests/CyclePredictionEngineTests.swift` | Cycle prediction accuracy, edge cases, and confidence scoring tests. |
| `Fernlet/FernletTests/CloudKitDataServiceTests.swift` | CloudKit data service and existing-data detection tests. |
| `Fernlet/FernletTests/StoragePreferencesTests.swift` | Storage preferences model encoding, defaults, and mutation tests. |
| `Fernlet/FernletTests/StoragePrivacyIntegrationTests.swift` | Integration tests for storage preference changes propagating through the app. |
| `Fernlet/FernletTests/IdentityServiceTests.swift` | Ed25519/X25519 identity provisioning, signing, and key-agreement tests. |
| `Fernlet/FernletTests/FernletIdentityEnvelopeTests.swift` | Envelope signing, verification, canonical encoding, and payload type tests. |
| `Fernlet/FernletTests/MultipeerPeerTests.swift` | Extracted MultipeerConnectivity peer-ID persistence tests. |
| `Fernlet/FernletTests/NearbyRangingSessionTests.swift` | NearbyInteraction ranging session state machine and distance update tests. |
| `Fernlet/FernletTests/ConnectionInspectorTests.swift` | Connection inspector session recording, subsampling, and purge-old logic tests. |
| `Fernlet/FernletTests/ProximityCoordinatorTests.swift` | Proximity coordinator handshake, payload dispatch, and error recovery tests. |
| `Fernlet/FernletTests/TrainerProximityServiceTests.swift` | Trainer proximity service disclosure card and audit event tests. |
| `Fernlet/FernletTests/FriendPhotoManifestPayloadTests.swift` | Friend-photo manifest payload round-trip and blocked-sender request filtering tests. |
| `Fernlet/FernletTests/RecipeShareCodecTests.swift` | Recipe share codec encoding and round-trip tests. |
| `Fernlet/FernletTests/FernletSnapshotRoundTripTests.swift` | Snapshot serialization round-trip integrity tests. |
| `Fernlet/FernletTests/ProximityTrustVaultTests.swift` | ProximityTrustVault trust/revoke idempotency, audit ring-buffer cap, onChange callback, and apply atomicity tests. |
| `Fernlet/FernletTests/AIRetryQueueServiceTests.swift` | AIRetryQueueService queue, clear, apply, reset, and onChange callback tests. |
| `Fernlet/FernletTests/DerivedSignalsServiceTests.swift` | DerivedSignalsService rebuild accuracy and deferred-rebuild single-run guard tests. |
| `Fernlet/FernletTests/DerivedSignalsRebuilderTests.swift` | Derived signals rebuilder accuracy and day-window boundary tests. |
| `Fernlet/FernletTests/MeshNetworkManagerTests.swift` | Mesh network manager discovery visibility, session open/closed transitions, slot allocation, peer admission, lifecycle, session-photo retention, and film-quota tests (10-shot limit, `filmRemaining`, `leaveSession` reset). |
| `Fernlet/FernletTests/DisposableCameraControllerTests.swift` | Pure state-machine unit tests for `CameraCaptureController`: initial armed state, disarm, wind progress, arm-on-full-wind, re-arm cycle, and no-op guards. |
| `Fernlet/FernletTests/MealBuilderTests.swift` | Meal builder food plan to meal/recipe conversion tests. |
| `Fernlet/FernletTests/SavedRecipeServiceTests.swift` | Saved recipe service load, add, delete, and persistence tests. |
| `Fernlet/FernletTests/SnapshotSaveCoordinatorTests.swift` | Snapshot save coordinator debounce and remote-reload tests. |
| `Fernlet/FernletTests/WorkoutHealthKitSyncTests.swift` | HealthKit workout import and upsert logic tests. |
| `Fernlet/FernletTests/FoodCatalogTests.swift` | SQLite food catalog round-trip/hydration, search parity with the in-memory scorer, user-item merging, and the gated `FoodCatalog.sqlite` regeneration test. |
| `Fernlet/FernletTests/CustomIngredientUpsertTests.swift` | Custom ingredient resolution and food item creation tests. |
| `Fernlet/FernletTests/AIContextPayloadTests.swift` | AI context payload de-identification: forbidden and allowlisted field tests. |
| `Fernlet/FernletTests/ActivityTests.swift` | Proximity group-activity token/snapshot crypto and join-token verification tests. |
| `Fernlet/FernletTests/AppIntentsTests.swift` | App Intents pending-sheet deep-link round-trip, consume-once, and expiry-window tests. |
| `Fernlet/FernletTests/BarcodeScanTests.swift` | Barcode scan GTIN normalization, schema-tolerance, and resolution-cascade tests. |
| `Fernlet/FernletTests/BrandedODRCatalogTests.swift` | Branded On-Demand-Resource food catalog attach, resolve, and detach-fallback integration tests. |
| `Fernlet/FernletTests/ClosenessTests.swift` | Friend closeness day-point weighting and closeness-formula tests. |
| `Fernlet/FernletTests/ClothingShareCodecTests.swift` | Clothing-share codec catalog-building and untrusted-catalog sanitization tests. |
| `Fernlet/FernletTests/CoinEconomyTests.swift` | Coin-economy ledger aggregation, idempotent earn/spend, and store-wiring tests. |
| `Fernlet/FernletTests/CommitResolutionPersistenceTests.swift` | Regression test for meal-resolution recipe creation persisting without accompanying meals. |
| `Fernlet/FernletTests/CreationStudioEditorTests.swift` | Creation Studio item-editor texture reprojection and dimension round-trip tests. |
| `Fernlet/FernletTests/CustomItemModelTests.swift` | Custom clothing-item texture helpers, Codable round-trip, and CRUD persistence tests. |
| `Fernlet/FernletTests/CyclePhaseResolverTests.swift` | Cycle-phase resolver tests deriving phase from entries, predictions, and calendar math. |
| `Fernlet/FernletTests/DataExportTests.swift` | Data-export shape round-trip and sensitive-vocabulary exclusion tests. |
| `Fernlet/FernletTests/DayDecodeCompatTests.swift` | Forward-compatibility tests for unknown enum tokens in day-resident fields. |
| `Fernlet/FernletTests/DayHistoryUncappedTests.swift` | Day-history uncapped per-row storage and read-cache invalidation tests. |
| `Fernlet/FernletTests/DayRecordRepositoryTests.swift` | DayRecordRepository upsert/load round-trip and non-destructive-upsert tests. |
| `Fernlet/FernletTests/DayRowMigrationTests.swift` | Day-row migration tests moving legacy blob days into the per-row store. |
| `Fernlet/FernletTests/DeleteAllDataTests.swift` | "Delete all data" reset tests verifying day history and inbox are fully purged. |
| `Fernlet/FernletTests/DestructiveConfirmationTests.swift` | Destructive-action confirmation tests verifying mutation is deferred until confirm. |
| `Fernlet/FernletTests/EquipmentIconTests.swift` | Equipment/location SVG icon markup parsing and path-bounds sanity tests. |
| `Fernlet/FernletTests/FernletFontRegistrationTests.swift` | Bundled font registration and text-role-to-font resolution tests. |
| `Fernlet/FernletTests/FoodProductWebImportTests.swift` | Food-product web-import structured-data (schema.org) nutrition extraction tests. |
| `Fernlet/FernletTests/FoodSearchLabelAndFallbackTests.swift` | Food-search data-source labeling and micronutrient-fallback tests. |
| `Fernlet/FernletTests/FriendMintingTests.swift` | One-sided friend-minting session-roster, review-batch, and vouch-list-gate tests. |
| `Fernlet/FernletTests/FriendShopTests.swift` | In-person friend-shop buy-flow, listing-cap, and ephemeral-catalog tests. |
| `Fernlet/FernletTests/FriendStateTests.swift` | Friend companion-state fuzzy-fold and constant-length wire-payload contract tests. |
| `Fernlet/FernletTests/GentleOffersTests.swift` | Gentle-intervention offer-engine gating/rotation, weather-comfort, and HealthKit write-gating tests. |
| `Fernlet/FernletTests/GoalSelectionPersistenceTests.swift` | Goal-selection persistence regression test (`setSelectedGoal` schedules a save and survives reload). |
| `Fernlet/FernletTests/GuidedWorkoutRunStoreTests.swift` | Guided-workout-run store approval-gate, start/finish/log, and Live-Activity mirroring tests. |
| `Fernlet/FernletTests/HealthKitCacheCleanerTests.swift` | HealthKit cache-cleaner opt-out purge tests preserving user-authored sleep entries. |
| `Fernlet/FernletTests/HealthKitScoringTests.swift` | HealthKit-aware scoring-engine tests verifying backward-compatible score computation. |
| `Fernlet/FernletTests/HeartShareTests.swift` | Presence-layer heart-share codec, trust-gate, rate-limit, and glow-decay tests. |
| `Fernlet/FernletTests/IdentityServiceEscrowTests.swift` | Identity-service backup-escrow-key provisioning-race and conflict-reconciliation tests. |
| `Fernlet/FernletTests/IslandViewfinderMetricsTests.swift` | Dynamic Island viewfinder geometry and device-classification tests. |
| `Fernlet/FernletTests/ItemNameModerationTests.swift` | Clothing-listing item-name moderation and sanitization tests. |
| `Fernlet/FernletTests/JournalNarrativeRepositoryTests.swift` | Sealed journal-narrative repository insert/fetch encryption round-trip tests. |
| `Fernlet/FernletTests/JournalQuickMoodTests.swift` | Quick-mood tag-only journal-entry and prompt-rotation tests. |
| `Fernlet/FernletTests/KnownDesignerNamesBoundTests.swift` | Known-designer-names map cardinality-bound regression test against hostile peer cycling. |
| `Fernlet/FernletTests/LogRecordsDecodeCompatTests.swift` | Forward-compatibility tests for derived log-record unknown-enum decoding. |
| `Fernlet/FernletTests/MacroRingProgressTests.swift` | Macro-ring progress NaN/Infinity guard tests for zero or degenerate goals. |
| `Fernlet/FernletTests/MealPhotoRecognitionTests.swift` | Meal-photo recognition taxonomy-filtering and resolveMeals-pipeline tests. |
| `Fernlet/FernletTests/MealPhotoStoreTests.swift` | Meal-photo store at-rest encryption, downscaling, and fail-closed-without-key tests. |
| `Fernlet/FernletTests/MemoryStorageScreeningTests.swift` | Memory-storage diagnostic-language screening classifier (storage-time gate) tests. |
| `Fernlet/FernletTests/MeshClothingShopTests.swift` | Mesh friend-clothing-shop catalog lifecycle, exchange, and hostile-input guard tests. |
| `Fernlet/FernletTests/MeshEncryptionTests.swift` | Mesh group symmetric-encryption (group key) unit tests. |
| `Fernlet/FernletTests/MeshTransportErrorSurfacingTests.swift` | Mesh transport didNotStart-error surfacing callback tests. |
| `Fernlet/FernletTests/MilestoneLedgerTests.swift` | Milestone-ledger aggregation, exactly-once coin-award, and reset-survival tests. |
| `Fernlet/FernletTests/ModerationBanTests.swift` | Moderation self-ban store default-state and reinstall-persistence tests. |
| `Fernlet/FernletTests/ModerationTests.swift` | Moderation content-hash stability and local report-ledger idempotency tests. |
| `Fernlet/FernletTests/MultiDeviceSyncWarningTests.swift` | Multi-device sync-warning classification tests across iCloud/sync-state combinations. |
| `Fernlet/FernletTests/NutritionTargetOverrideTests.swift` | Nutrition-target-override derivation and settings round-trip tests. |
| `Fernlet/FernletTests/PastDayJournalScrubMigrationTests.swift` | Past-day journal scrub-migration retry regression test for failed sealing passes. |
| `Fernlet/FernletTests/PastDayJournalSealingTests.swift` | Past-day journal sealing tests ensuring no plaintext leaks into the synced blob. |
| `Fernlet/FernletTests/PeriodAwareScoringTests.swift` | Period-aware scoring adjustment and backward-compatibility tests. |
| `Fernlet/FernletTests/PeriodContextBridgeTests.swift` | Period-context bridge phase-signal derivation and 3-cycle-gate tests. |
| `Fernlet/FernletTests/PeriodPhaseTrendEngineTests.swift` | Period phase-trend correlation-engine minimum-cycle-gate and trend-detection tests. |
| `Fernlet/FernletTests/PeriodPredictionUITests.swift` | Period-prediction UI visibility-gating (`hidePredictions` setting) tests. |
| `Fernlet/FernletTests/PeriodTestSupport.swift` | Shared deterministic fixtures and scoring-context stub used by the period-aware test suites. |
| `Fernlet/FernletTests/PetInteractionGovernorTests.swift` | Pet-interaction time-lock governor and ambience pure-function tests. |
| `Fernlet/FernletTests/PhotowallPhotoSelectorTests.swift` | Photowall photo-selector next-launch dedup and ranking-strategy tests. |
| `Fernlet/FernletTests/PresenceHeartsTests.swift` | Presence-layer heart reachability, invitation-gate, and opt-out tests. |
| `Fernlet/FernletTests/PresenceManagerTests.swift` | Presence-manager radio state-machine roster, advertise-cap, and epoch-rotation tests. |
| `Fernlet/FernletTests/PresenceTagTests.swift` | Presence-tag Diffie-Hellman primitive mutual-derivation and epoch-rotation tests. |
| `Fernlet/FernletTests/PrivateEncryptedRepositoryRecoveryTests.swift` | Private encrypted-repository recovery tests skipping rows keyed by a destroyed key. |
| `Fernlet/FernletTests/PrivateHistoryPruningTests.swift` | Private-history deletion/pruning tests verifying no residual record remains. |
| `Fernlet/FernletTests/PrivateMediaStoreTests.swift` | Private media-store (mesh photo cache) decompression-bomb defense and at-rest encryption tests. |
| `Fernlet/FernletTests/ProgressPhotoStoreTests.swift` | Progress-photo store at-rest encryption and fail-closed-without-key tests. |
| `Fernlet/FernletTests/ProximityRecipeShareCapTests.swift` | Proximity recipe-share two-device cap and radio pause/resume lifecycle tests. |
| `Fernlet/FernletTests/ProximityRecipeShareDiagnosticsTests.swift` | Proximity recipe-share diagnostics capped ring-buffer append/ordering tests. |
| `Fernlet/FernletTests/ProximityRecordDecodeCompatTests.swift` | Forward-compatibility tests for persisted proximity records (trust vault, audit, session logs). |
| `Fernlet/FernletTests/ProximityWireOffMainDecodeTests.swift` | Proximity wire-type Sendable conformance and off-main decode/signature-verification tests. |
| `Fernlet/FernletTests/RecentBitesTests.swift` | Home "Recent bites" 7-day photographed-meal window tests. |
| `Fernlet/FernletTests/RecipeWebImporterTests.swift` | Recipe web-importer SSRF/URL-safety allow- and block-list tests. |
| `Fernlet/FernletTests/ReplayCacheTests.swift` | Replay-cache oldest-eviction and envelope-replay-detection tests. |
| `Fernlet/FernletTests/S3BoundaryTests.swift` | S3 privacy-wall grep-based backstop tests scanning AI-facing sources for sealed-store access. |
| `Fernlet/FernletTests/SavedRecipeMigrationTests.swift` | Legacy SavedRecipe-to-RecipeDefinition migration round-trip tests. |
| `Fernlet/FernletTests/SealedBackupChunkTests.swift` | Sealed-backup chunked-export paging and multi-chunk restore-writeback tests. |
| `Fernlet/FernletTests/SealedBackupRestoreOutcomeTests.swift` | Sealed-backup restore-outcome classification and status-recording tests. |
| `Fernlet/FernletTests/SealedBackupRestoreTests.swift` | Sealed-backup restore-into-stores tests (empty-store guard, Tier-2 writeback, locked-key path). |
| `Fernlet/FernletTests/SealedBackupTests.swift` | Sealed-backup crypto round-trip and escrow-key provisioning tests. |
| `Fernlet/FernletTests/SealedIntroductionTests.swift` | Sealed-introduction mesh handshake tests guarding against unsealed identity leakage. |
| `Fernlet/FernletTests/SealedStoreConfigTests.swift` | Sealed-store/CloudKit-model isolation tests keeping sensitive entities out of the synced model. |
| `Fernlet/FernletTests/AgeAssuranceTests.swift` | Age-gate tests: the pure record rules, the device-local store's persistence and fail-closed decode, and the wiring into the intimacy visibility gate, the mesh chat seams, and `resetAll`. |
| `Fernlet/FernletTests/SensitiveSurfaceGateTests.swift` | Sensitive-surface (period/intimacy) hard hide-gate visibility tests. |
| `Fernlet/FernletTests/SessionMessageTests.swift` | Live-session ephemeral message codec, dispatch-gate, and transcript-clearing tests. |
| `Fernlet/FernletTests/SettingsDecodeCompatTests.swift` | Forward-compatibility tests for unknown enum tokens in synced `FernletSettings` fields. |
| `Fernlet/FernletTests/SnapshotModelsDecodeCompatTests.swift` | Forward-compatibility tests for unknown enum tokens across remaining synced-blob model types. |
| `Fernlet/FernletTests/StressEngineTests.swift` | Stress-engine HRV z-score classification and scoring-modifier tests. |
| `Fernlet/FernletTests/TabBarCompactionTests.swift` | Tab-bar compaction hysteresis decision-logic tests. |
| `Fernlet/FernletTests/TrainerExportTests.swift` | Trainer/nutritionist export bundle fail-closed category-exclusion tests. |
| `Fernlet/FernletTests/WidgetBridgeTests.swift` | Widget-bridge snapshot mirroring and pending-action-queue codec tests. |
| `Fernlet/FernletTests/WorkoutProgramTests.swift` | Workout-program location identity-stability and template-ID collision tests. |
| `Fernlet/FernletTests/WorkoutRecoveryTests.swift` | Logged-workout removal/edit recoverability and bookkeeping-reversal tests. |
| `Fernlet/FernletTests/WorryBoxTests.swift` | Worry Box sealed repository round-trip, deletion, and key-migration tests. |

### Test Mocks

| File | Purpose |
| --- | --- |
| `Fernlet/FernletTests/Mocks/MockMultipeerTransport.swift` | In-memory mock for MultipeerConnectivity transport used in proximity unit tests. |
| `Fernlet/FernletTests/Mocks/MockRangingProvider.swift` | Controllable mock for NearbyInteraction ranging used in coordinator and session tests. |

### UI Tests

| File | Purpose |
| --- | --- |
| `Fernlet/FernletUITests/FernletUITests.swift` | UI automation tests for core app workflows. |
| `Fernlet/FernletUITests/FernletUITestsLaunchTests.swift` | UI launch and performance tests. |
| `Fernlet/FernletUITests/OnboardingFlowUITests.swift` | End-to-end UI tests for the onboarding flow. |
| `Fernlet/FernletUITests/PrivacyDataSettingsUITests.swift` | UI tests for the privacy and data settings screen. |
| `Fernlet/FernletUITests/StoragePrivacyUITests.swift` | UI tests for storage and privacy preference flows. |
| `Fernlet/FernletUITests/MeshNetworkUITests.swift` | Legacy mesh-lobby UI automation suite. Currently skipped pending replacement with coverage for the active Friends-session disposable-camera flow. |
| `Fernlet/FernletUITests/UXScreenProbe.swift` | Test harness (`UXTestApp` launcher + chainable `UXScreenProbe` geometry assertions/screenshot capture) backing the appearance UI-test suites. |
| `Fernlet/FernletUITests/ScreenAppearanceUITests.swift` | Visual/layout regression suite screenshotting every primary tab, private hub, and logging sheet, asserting nothing is clipped or blank. |
| `Fernlet/FernletUITests/OnboardingAppearanceUITests.swift` | Walks the 8-screen onboarding flow, screenshotting each screen and asserting its title and primary action button render on-screen. |
| `Fernlet/FernletUITests/SettingsAppearanceUITests.swift` | Walks each Settings sub-screen (pushed destination), screenshotting and asserting its nav bar renders on-screen. |
| `Fernlet/FernletUITests/HomeCardsRedesignUITests.swift` | UI test guarding the redesigned First Aid and Milestones home cards render and open their destinations. |
| `Fernlet/FernletUITests/GoalPresetCardsUITests.swift` | UI test for the Goal & Nutrition preset cards: renders and verifies tapping a card updates the selection. |
| `Fernlet/FernletUITests/NutritionTargetsEditorUITests.swift` | End-to-end UI test of the Settings nutrition targets editor, covering residual rebalancing and the fat placeholder tracking calorie overrides. |
| `Fernlet/FernletUITests/RecentBitesUITests.swift` | UI test verifying the Home "Recent bites" polaroid strip of photographed meals renders. |
| `Fernlet/FernletUITests/RecipeDetailUITests.swift` | UI test for the read-only recipe detail view, opened from both the recipe book and the Food page's Recipes section. |
| `Fernlet/FernletUITests/ProgressPhotoUITests.swift` | UI test for the Move tab's progress-photo timeline: strip renders and its detail view (caption + delete) is reachable. |
| `Fernlet/FernletUITests/WorkoutLocationUITests.swift` | UI test for gym-location delete/rename, asserting a deletion persists after closing and reopening the sheet. |
| `Fernlet/FernletUITests/ItemCreationFlowUITests.swift` | UI test for the split item-creation flow: the drawing-only editor leading to a separate naming/shop-listing confirmation step. |
| `Fernlet/FernletUITests/DeleteAllDataUITests.swift` | End-to-end UI test proving "Delete everything" empties the app and stays deleted across a relaunch. |
| `Fernlet/FernletUITests/DeleteAllDialogAppearanceUITests.swift` | Screenshots the "Delete everything?" confirm dialog and logs its rendered copy/buttons for review. |

## Documentation

### Active

| File | Purpose |
| --- | --- |
| `Docs/FernletSpecificationV3.md` | Product specification. |
| `Docs/ImplementationPlan.md` | Implementation planning notes. |
| `Docs/SPM-Module-Carveup-Plan.md` | SPM carve-up plan for the `FernletKit` package: the S3 compile-time privacy wall and the cross-platform shared-core layering. |
| `Docs/CODE_REVIEW_2026-06-12.md` | 2026-06-12 multi-agent code review report: 193 confirmed findings, resolutions, and author design decisions. |
| `Docs/Custom-Clothing-Plan-2026-06-29.md` | Phased plan for the custom-clothing feature: Increment 1 (grid editor / wardrobe — shipped), Increment 2 (coins), Increment 3 (in-person friend shop). Self-contained per-increment sections for one-increment-per-session work. |
| `Docs/Fernlet-Review-and-Plan-Updates.md` | 2026-05-28 architecture review: security/privacy findings (SEC-1 through SEC-8), progress-vs-spec audit, French-fries meal bug root-cause, new phases S1/S2/M1/S3 and Mesh Phase 4, settings consolidation IA, and friction-reduction features. |
| `Docs/FileIndex.md` | This file index. |
| `Docs/ProximityFunctionIndex.md` | Function-level map for proximity, mesh, transport, identity, trust, audit, friend-photo, recipe-share, and related UI code. Use this before adding proximity or mesh behavior to avoid duplicating existing helpers and flows. |
| `Docs/StoreRepositoryFunctionIndex.md` | Function-level map for `FernletStore`, models, repositories, persistence controllers, storage preferences, snapshot saves, launch preparation, and extracted store services. Use this before adding data mutation, save/load, derived-signal, retry, saved-recipe, or sealed-buffer behavior. |

### Completed Implementations

| File | Purpose |
| --- | --- |
| `Docs/Completed Implemtations/PR0-Incremental-Migration-Plan.md` | PR0 incremental @Observable migration plan. |
| `Docs/Completed Implemtations/MeshNetworkImplementationPlan.md` | Mesh network and MultipeerConnectivity implementation plan. |
| `Docs/Completed Implemtations/FernletStore-Refactor-Plan-v2.md` | Refactor plan for the FernletStore architecture (v2). |
| `Docs/Completed Implemtations/Life-Tab-Redesign-Implementation-Plan.md` | Life tab (Friends/social) redesign implementation plan. |
| `Docs/Completed Implemtations/Dead-Code-and-Carryover-Gap-Review.md` | Dead-code review plus the `MeshLobbyView` → `ConnectView`/disposable-camera carryover-gap audit. |
| `Docs/Completed Implemtations/healthkit-integration-plan.md` | HealthKit integration plan. |
| `Docs/Completed Implemtations/fernlet-period-intimacy-plan.md` | Period and intimacy feature plan. |
| `Docs/Completed Implemtations/PeriodAlgorithimResearch.md` | Research notes on period/cycle prediction algorithms. |
| `Docs/Completed Implemtations/phase7-proximity-implementation-plan.md` | Phase 7 proximity feature implementation plan. |
| `Docs/Completed Implemtations/proximity-handshake-process-map.md` | Process map for the proximity identity handshake flow. |
| `Docs/Completed Implemtations/StartupAndBiometricFixPlan.md` | Plan for startup sequence and biometric authentication fixes. |
| `Docs/Completed Implemtations/codex-implementation-prompts.md` | Codex-style prompts used to guide feature implementation. |

## Scripts And CI

| Path | Purpose |
| --- | --- |
| `Fernlet/Scripts/spm-wall-check.sh` | S3 wall enforcement: builds with `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` so a forbidden cross-wall `import` fails the build. Run pre-merge and in CI. |
| `Fernlet/Scripts/spm-wall-selftest.sh` | Negative test proving the wall is load-bearing: plants a forbidden `import PrivateHealthStore` in `AIProviders`, asserts the build fails, then reverts. |
| `Fernlet/Scripts/install-git-hooks.sh` | Once per clone: points `core.hooksPath` at the versioned `Scripts/git-hooks` so pushes run the wall check. |
| `Fernlet/Scripts/git-hooks/pre-push` | Versioned pre-push hook running `spm-wall-check.sh` when a push touches wall-relevant files. |
| `Fernlet/Scripts/branded-catalog/` | Python pipeline converting the USDA branded dataset into the curated and On-Demand-Resource SQLite catalogs. |
| `Fernlet/.github/workflows/s3-wall.yml` | CI workflow running the wall enforcement self-test plus the grep-wall on push/PR to `main`. |

## Dependency

| Path | Purpose |
| --- | --- |
| `Fernlet/FernletKit/` | The local Swift package holding the carved-up on-device modules (see the FernletKit Package module map above). |
| CryptoSwift | Remote SPM dependency (`.upToNextMinor` from 1.10.0) supplying the Scrypt KDF used by `FernletLock`; no longer checked into the repo. |
