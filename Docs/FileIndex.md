# Fernlet File Index

This index maps the main project files to their responsibilities. It is intended as a quick orientation guide for app navigation, feature work, tests, and documentation.

## App Entry And Shell

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/FernletApp.swift` | SwiftUI app entry point. Creates the shared persistence, app store, period tracker, launch preparation service, and lock service objects. |
| `Fernlet/Fernlet/ContentView.swift` | Main app container and navigation shell. Hosts primary tabs, launch state, personal screen, lock gate integration, quick sheets, and meal/journal notifications. |
| `Fernlet/Fernlet/FernletUIComponents.swift` | Shared UI primitives and navigation metadata, including `FernletTab`, `FernletSheet`, headers, chip styles, sheet fields, section pickers, and layout helpers. |
| `Fernlet/Fernlet/FernletTheme.swift` | App-wide color palette, theme defaults, custom light/dark background support, and UIKit/SwiftUI color vending. |
| `Fernlet/Fernlet/Assets.xcassets` | Image and color assets used by the app. |
| `Fernlet/Fernlet/Info.plist` | App bundle metadata and platform configuration. |
| `Fernlet/Fernlet/Fernlet.entitlements` | App capability entitlements. |

## Feature Views

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/HomeView.swift` | Home dashboard with companion state, quick logging, signal trends, macro summaries, hygiene, and photo wall UI. |
| `Fernlet/Fernlet/FoodView.swift` | Food logging, recipes, imported recipe review, ingredient editing, meal creation, macro display, saved recipe book, and Safari presentation. |
| `Fernlet/Fernlet/MoveView.swift` | Movement/workout screen with workout logging, suggestions, workout rows, and goal summaries. |
| `Fernlet/Fernlet/ActivityPickerSection.swift` | Activity-mode workout picker, recent activity shortcuts, and activity-specific workout fields. |
| `Fernlet/Fernlet/JournalView.swift` | Journal calendar, prompts, entry creation/editing, day detail, day nutrition breakdowns, and daily edit sheets. |
| `Fernlet/Fernlet/PeriodTrackerView.swift` | Cycle tracking main view. |
| `Fernlet/Fernlet/PeriodDayDetailView.swift` | Detail view for a specific period/cycle day. |
| `Fernlet/Fernlet/LogPeriodSheet.swift` | Sheet for logging period events. |
| `Fernlet/Fernlet/PrivateHubView.swift` | Private hub screen with private-section navigation. |
| `Fernlet/Fernlet/SocialHubView.swift` | Social hub entry point for the Friends photo wall and active disposable-camera session flow. |
| `Fernlet/Fernlet/ConnectView.swift` | Friends tab photo wall, nearby-discovery status, connection-success transition, session photo review, and full-screen saved-photo feed. Presents `DisposableCameraView` while a Friends session is active. |
| `Fernlet/Fernlet/WorkshopView.swift` | Workshop screen for texture-related tracking and tabbed workshop UI. |
| `Fernlet/Fernlet/OnboardingView.swift` | First-run profile setup, nutrition profile editing, and nutrition preview UI. |
| `Fernlet/Fernlet/SettingsSheet.swift` | Settings sheet and user preferences UI. |
| `Fernlet/Fernlet/SharedSheets.swift` | Reusable logging sheets for water, sleep, goals, hygiene, and texture entries. |

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
| `Fernlet/Fernlet/FernletLockGate.swift` | View modifier that gates protected UI behind the Fernlet lock state. |
| `Fernlet/Fernlet/FernletLockView.swift` | Lock setup, unlock UI, numeric pad, passcode entry, and related lock interaction views. |
| `Fernlet/Fernlet/FernletLockService.swift` | Lock service protocols, lock state, credential types, crypto provider, keychain item handling, audit logging, and lock/unlock orchestration. |
| `Fernlet/Fernlet/KeychainHelpers.swift` | Low-level Keychain read/write/delete helpers shared by lock and identity services. |
| `Fernlet/Fernlet/PrivacyDataSettingsView.swift` | Privacy and data settings screen for managing storage preferences, HealthKit toggles, and sealed backup options. |

## Data, Persistence, And State

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/Models.swift` | Core domain models for days, settings, nutrition, meals, recipes, workouts, journal entries, sleep, hygiene, goals, workshop data, and companion state. |
| `Fernlet/Fernlet/FernletStore.swift` | Main observable app store that coordinates repository data and app-level state changes. |
| `Fernlet/Fernlet/AIRetryQueueService.swift` | AI analysis retry queue; stores pending retry records and calls `onChange` on each mutation. Extracted sub-service of `FernletStore`. |
| `Fernlet/Fernlet/DerivedSignalsService.swift` | Derived signal computation and deferred post-launch rebuild scheduling. Extracted sub-service of `FernletStore`. |
| `Fernlet/Fernlet/DerivedSignalsRebuilder.swift` | Pure helper that rebuilds derived signals from a historical day window; used by `DerivedSignalsService`. |
| `Fernlet/Fernlet/SavedRecipeService.swift` | Observable saved recipe list manager; loads, adds, deletes, and persists saved recipes. Extracted sub-service of `FernletStore`. |
| `Fernlet/Fernlet/SnapshotSaveCoordinator.swift` | Debounced snapshot persistence coordinator and remote-change reload handler. Extracted sub-service of `FernletStore`. |
| `Fernlet/Fernlet/FernletStoreLoader.swift` | Async store bootstrap coordinator that manages `preparing → ready → failed` phase transitions at launch. |
| `Fernlet/Fernlet/LocalFernletRepository.swift` | Local JSON-style repository contract and implementation, snapshot/database records, derived signal creation, limits, and memory engine logic. |
| `Fernlet/Fernlet/CoreDataFernletRepository.swift` | Core Data-backed repository implementation. |
| `Fernlet/Fernlet/Persistence.swift` | Core Data persistence controller setup for runtime and previews/tests. |
| `Fernlet/Fernlet/CloudKitDataService.swift` | CloudKit record read/write service and `ExistingDataSummary` detection used during onboarding migration. |
| `Fernlet/Fernlet/StoragePreferences.swift` | Codable model for user storage preferences: iCloud sync, local backup exclusion, HealthKit capability toggles, and sealed backup flags. |
| `Fernlet/Fernlet/PeriodTrackerStore.swift` | Period tracker domain state, cycle events, symptom/flow models, cycle phase logic, HealthKit integration contract, and store behavior. |
| `Fernlet/Fernlet/MenstrualNarrativeRepository.swift` | Persistence for menstrual narrative entries. |
| `Fernlet/Fernlet/PendingNarrativeBuffer.swift` | Codable buffer for pending menstrual narrative payloads. |
| `Fernlet/Fernlet/SavedRecipe.swift` | Saved recipe model and repository implementations, including legacy JSON migration support. |
| `Fernlet/Fernlet/ActivityTypeCatalog.swift` | Workout activity type search and HealthKit activity type mapping. |

## Food, Nutrition, And Recipe Services

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/FoodDataCatalog.swift` | USDA food item record decoder (compact + raw FDC), source-JSON loading for the DB generator, `FoodItemSearch` scorer, and recipe search helpers. |
| `Fernlet/Fernlet/FoodCatalog.swift` | `FoodCatalog` service: merges the SQLite bundled food source with the in-memory user-item snapshot; search via FTS candidate prefilter → `FoodItemSearch` scorer, plus ID/exact-name resolution. Replaces the old in-memory `allFoodItems` array. |
| `Fernlet/Fernlet/BundledFoodStore.swift` | `BundledFoodSource` protocol + read-only SQLite-backed `SQLiteBundledFoodSource` (FTS5 candidate query, id/exact lookups, hydration) and `InMemoryBundledFoodSource` for tests; shared `FoodCatalogSchema`. |
| `Fernlet/Fernlet/FoodCatalogDatabaseBuilder.swift` | Build-time generator that converts the `FoodDataSource/*.json` foods into the shipped read-only `FoodCatalog.sqlite` (run via the gated `FoodCatalogGenerationTests`). Not used at runtime. |
| `Fernlet/Fernlet/USDAFoodItems.json` | Bundled USDA food item dataset consumed by the food catalog. |
| `Fernlet/Fernlet/WorkoutExercises.json` | Bundled exercise dataset consumed by the workout system. |
| `Fernlet/Fernlet/FoundationFoodSelection.swift` | Foundation model availability and food selection model helpers. |
| `Fernlet/Fernlet/NutritionLabelScanner.swift` | Nutrition label scan result model, scan errors, and scanner implementation. |
| `Fernlet/Fernlet/NutritionLabelCameraSheet.swift` | Camera and image picker UI for capturing nutrition labels and reviewing scan results. |
| `Fernlet/Fernlet/RecipeWebImporter.swift` | Recipe import pipeline for extracting structured recipes from web content and metadata. |
| `Fernlet/Fernlet/RecipeShareCodec.swift` | Encodes and decodes recipes into a shareable text format for peer-to-peer recipe sharing. |
| `Fernlet/Fernlet/MealBuilder.swift` | Converts a `FoodSelectionPlan` and food candidates into structured `Meal` records and inline recipe definitions, with good-protein threshold logic. |
| `Fernlet/Fernlet/CustomIngredientUpsert.swift` | Resolves manual recipe ingredient inputs into `FoodItem` records, creating or updating custom food entries in the catalog. |
| `Fernlet/Fernlet/Scoring.swift` | Health scoring, goal weights, meal parsing, workout planning, workout suggestions, and date helpers. |

## Health And Launch Services

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/HealthKitService.swift` | HealthKit service protocol and implementation, capability metadata, authorization snapshots, body/activity/cycle/mindfulness context, and authorization view model. |
| `Fernlet/Fernlet/WorkoutHealthKitSync.swift` | HealthKit workout import pipeline; reads `HKWorkout` samples and upserts matching `Workout` records via a `WorkoutSyncContext`. |
| `Fernlet/Fernlet/CyclePredictionEngine.swift` | Statistical cycle prediction engine using historical period data to forecast next period start, flow patterns, confidence level, and predicted flow days. |
| `Fernlet/Fernlet/LaunchPreparationService.swift` | Launch preparation state and photo wall seed loading. |
| `Fernlet/Fernlet/StartupTiming.swift` | `os_signpost`-based startup timing probes for measuring and instrumenting app launch phases. |

## Social And Mesh Networking

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/Proximity/Mesh/MeshNetworkManager.swift` | Observable mesh network coordinator managing active/lightweight peer slots, proximity-join (15 cm commit gate), pairwise/mesh promotion, session open/closed state, member removal proposals, admission requests, friend-of-friend vouchers, photo session metadata, encrypted mesh payloads, coordinator beacons, and key rotation. Its observation loop explicitly finishes cancelled streams so repeated Friends-tab discovery sessions do not retain suspended observers. |
| `Fernlet/DisposableCameraView.swift` | Active Friends-session disposable-camera UI: `CameraCaptureController` (`@Observable`, queued `AVCaptureSession` lifecycle, rotation handling, and arm/wind gate), `CameraPreviewView`, and the full-screen camera. The session-info sheet exposes the 10-shot film count, open/closed access, mesh rename, participant options, friend-of-friend labels, diagnostics, removal requests, and end-session flow; admission requests and mesh errors are presented as popups. |
| `Fernlet/Fernlet/MeshAdmissionPromptSheet.swift` | Reusable sheet for reviewing and approving/declining peer join requests to a named mesh. Presented by the active disposable-camera session flow. |
| `Fernlet/Fernlet/FriendListView.swift` | Friend list screen for browsing trusted proximity peers with all/friends/blocked filters and block management. |

## Proximity

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/Proximity/Engine/ProximityCoordinator.swift` | High-level coordinator for proximity sessions; orchestrates MultipeerConnectivity transport, signed identity/ranging-token handshake, UWB startup, heartbeat RTT, payload dispatch, and inspector recording. |
| `Fernlet/Fernlet/Proximity/Transport/MultipeerPeer.swift` | MultipeerConnectivity peer model plus persistent `MCPeerID` storage shared by active mesh transport and future trainer transport work. |
| `Fernlet/Fernlet/Proximity/Transport/MultipeerTransport.swift` | Neutral MultipeerConnectivity transport protocol, state, invite, inbound-message, error, and reserved trainer-service definitions. |
| `Fernlet/Fernlet/Proximity/Engine/ProximityCommitDetector.swift` | Rolling distance-window detector used by proximity commit and trainer tap gates. |
| `Fernlet/Fernlet/Proximity/Ranging/RangingProvider.swift` | Ranging provider contract plus shared distance and state models. |
| `Fernlet/Fernlet/Proximity/Transport/MeshMultipeerSession.swift` | Shared `MCSession` host for multi-peer mesh; `PeerChannelTransport` adapts per-peer state and data routing without managing the MC lifecycle directly. |
| `Fernlet/Fernlet/Proximity/Mesh/MeshSessionTypes.swift` | Mesh session slot, group-key, ranking-window sample, participant, and encryption-error support models extracted from the manager. |
| `Fernlet/Fernlet/Proximity/Mesh/MeshNameGenerator.swift` | Generates random human-readable two-word mesh names from adjective/noun word lists. |
| `Fernlet/Fernlet/Proximity/Ranging/NIRangingSession.swift` | NearbyInteraction UWB ranging session for measuring real-time distance and direction between Fernlet devices. |
| `Fernlet/Fernlet/Proximity/Wire/FernletIdentityEnvelope.swift` | Ed25519-signed wire envelope for all peer-to-peer transfers, including canonical JSON encoding and verification. |
| `Fernlet/Fernlet/Proximity/Wire/PayloadType.swift` | Peer-to-peer payload classification, envelope encryption mode, and payload summary models. |
| `Fernlet/Fernlet/Proximity/Wire/MeshPayloads.swift` | Mesh descriptor, admission, removal, voucher, group-encryption, and coordinator-beacon wire models plus admission-token signing and verification. |
| `Fernlet/Fernlet/Proximity/Wire/FriendPhotoPayloads.swift` | Friend-photo payload, session metadata, manifest, and missing-photo request wire models. |
| `Fernlet/Fernlet/Proximity/Photos/PrivateMediaStore.swift` | Disk-backed mesh photo index with **AES-256-GCM at-rest encryption** of image/thumbnail bytes, thumbnail generation, hydration, FIFO eviction (1000 cap / 900 warn), and orphan cleanup. (Formerly `MeshPhotoCacheStore`.) |
| `Fernlet/Fernlet/Proximity/Photos/PrivateMediaKeyStore.swift` | `PrivateMediaKeyProviding` + keychain-backed (backup-restorable, `AfterFirstUnlock`) AES key provider for `PrivateMediaStore`. |
| `Fernlet/Fernlet/Proximity/Photos/FriendPhotoImageHelpers.swift` | `UIImage` resizing and thumbnail JPEG helpers for friend-photo sharing. |
| `Fernlet/Fernlet/Proximity/Identity/IdentityService.swift` | Per-device Ed25519 signing identity and X25519 key-agreement, with keys stored in Keychain under `AfterFirstUnlockThisDeviceOnly`. |
| `Fernlet/Fernlet/Proximity/Identity/ReplayCache.swift` | Rolling 24-hour envelope-ID cache for replay-attack prevention; injectable clock for deterministic testing. |
| `Fernlet/Fernlet/Proximity/Audit/ConnectionInspector.swift` | Live and historical proximity session logging, ranging mode/distance samples, RTT samples, event subsampling, and session lifecycle recording (`ProximityInspectorRecording`). |
| `Fernlet/Fernlet/Proximity/Audit/ConnectionSessionLog.swift` | Structured session log model capturing peer info, ranging state, transport counters, envelope records, and error events. |
| `Fernlet/Fernlet/Proximity/UI/ConnectionInspectorView.swift` | On-demand live connection inspector UI for real-time proximity diagnostics, distance, RTT, and fallback status. |
| `Fernlet/Fernlet/Proximity/UI/ConnectionInspectorHistoryView.swift` | View for browsing and reviewing historical proximity connection session logs. |
| `Fernlet/Fernlet/Proximity/Trust/TrainerAuditLog.swift` | Trusted peer records, `ProximityTrustPolicy`, and trainer-named audit event vocabulary shared by proximity sessions. |
| `Fernlet/Fernlet/Proximity/Trust/FriendSessionTrustPolicy.swift` | Friend-session trust-policy wrapper over `ProximityTrustVault`; blocked, revoked, and audit operations delegate to the vault while proximity-gated sessions remain permissive for remembered-trust checks. |
| `Fernlet/Fernlet/Proximity/Trust/ProximityTrustVault.swift` | Trusted proximity peer records and trainer audit event vault; implements `ProximityTrustPolicy`. Extracted sub-service of `FernletStore`. |
| `Fernlet/Fernlet/Proximity/Photos/FriendPhotoReviewSheet.swift` | Review tile, review sheet, and photo-library saver for shared friend photos. |
| `Fernlet/Fernlet/Proximity/ForegroundAnchor/ProximityForegroundAnchor.swift` | Live Activity anchor that keeps proximity sessions alive when the app moves to the background. |

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

## Documentation

### Active

| File | Purpose |
| --- | --- |
| `Docs/FernletSpecificationV3.md` | Product specification. |
| `Docs/ImplementationPlan.md` | Implementation planning notes. |
| `Docs/MeshNetworkImplementationPlan.md` | Mesh network and MultipeerConnectivity implementation plan. |
| `Docs/FernletStore-Refactor-Plan-v2.md` | Refactor plan for the FernletStore architecture (v2). |
| `Docs/Fernlet-Review-and-Plan-Updates.md` | 2026-05-28 architecture review: security/privacy findings (SEC-1 through SEC-8), progress-vs-spec audit, French-fries meal bug root-cause, new phases S1/S2/M1/S3 and Mesh Phase 4, settings consolidation IA, and friction-reduction features. |
| `Docs/FileIndex.md` | This file index. |
| `Docs/ProximityFunctionIndex.md` | Function-level map for proximity, mesh, transport, identity, trust, audit, friend-photo, recipe-share, and related UI code. Use this before adding proximity or mesh behavior to avoid duplicating existing helpers and flows. |
| `Docs/StoreRepositoryFunctionIndex.md` | Function-level map for `FernletStore`, models, repositories, persistence controllers, storage preferences, snapshot saves, launch preparation, and extracted store services. Use this before adding data mutation, save/load, derived-signal, retry, saved-recipe, or sealed-buffer behavior. |

### Completed Implementations

| File | Purpose |
| --- | --- |
| `Docs/Completed Implemtations/PR0-Incremental-Migration-Plan.md` | PR0 incremental @Observable migration plan. |
| `Docs/Completed Implemtations/healthkit-integration-plan.md` | HealthKit integration plan. |
| `Docs/Completed Implemtations/fernlet-period-intimacy-plan.md` | Period and intimacy feature plan. |
| `Docs/Completed Implemtations/PeriodAlgorithimResearch.md` | Research notes on period/cycle prediction algorithms. |
| `Docs/Completed Implemtations/phase7-proximity-implementation-plan.md` | Phase 7 proximity feature implementation plan. |
| `Docs/Completed Implemtations/proximity-handshake-process-map.md` | Process map for the proximity identity handshake flow. |
| `Docs/Completed Implemtations/StartupAndBiometricFixPlan.md` | Plan for startup sequence and biometric authentication fixes. |
| `Docs/Completed Implemtations/codex-implementation-prompts.md` | Codex-style prompts used to guide feature implementation. |

## Dependency

| Path | Purpose |
| --- | --- |
| `CryptoSwift/` | Checked-in CryptoSwift package dependency used by lock crypto tests and app cryptography support. |
| `CryptoSwift/Sources/CryptoSwift/` | CryptoSwift library source. |
| `CryptoSwift/Package.swift` | Swift package manifest for CryptoSwift. |
