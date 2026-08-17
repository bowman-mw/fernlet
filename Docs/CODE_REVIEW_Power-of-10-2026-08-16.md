# Code review — NASA Power of 10 (Swift adaptation), 2026-08-16

Scope: every shipping Swift file (366 files, ~127k lines) in `FernletKit/Sources`, `App/Fernlet`, `App/FernletWidgets`, `App/FernletShareExtension`, audited slice by slice (16 slices, one auditor each) against [Power-of-10-Swift.md](Power-of-10-Swift.md). Mechanical baseline from `Scripts/power-of-10-scan.py`; review-only rules (R1 recursion, R2 loop bounds, R3 bounded growth, R5 validation, R7 result checking, R9 seams) from reading every file.

## Mechanical baseline (before the fix phase)

| Check | Count |
|---|---|
| R4-LENGTH (bodies > 60 code lines) | 93 |
| R7-SWALLOW (bare `try?`) | 138 |
| R9-UNSAFE (unsafe pointer / `nonisolated(unsafe)` sites) | 94 |
| R5-FORCE (`!`, `as!`, IUO) | 32 |
| R6-STATIC-VAR (stored mutable statics) | 6 |
| R8-IF-NEST (nested `#if`) | 5 |
| R2-WHILE-TRUE | 3 |
| R5-TRAP (`fatalError`) | 2 |
| **Total enforced violations** | **373** |
| Assertion density (guard+assert / logic functions ≥ 3 lines) | 0.684 (floor 0.60) |
| Compiler warnings, app targets | 0 |
| Compiler warnings, FernletKit package (hidden by Xcode's `-suppress-warnings`) | ~55 → **0** after rule-10 fixes |
| **After the fix phase: enforced violations** | **0** (allowlist 12, density 0.686) |
| Compiler warnings, test targets | 14 → **0** |

## Rule 10 — done in this round

- Xcode passes `-suppress-warnings` to every local-package target, so ~55 real Sendable/isolation warnings in the sealed `Private*` repositories, `FernletLockService`, `HealthKitService`, `ProtectedSidecar`, `CoachPlan` (a real `.none` ambiguity bug) had never been visible. All fixed properly (checked `Sendable`, `Mutex`, `@MainActor`, no `nonisolated(unsafe)`, no pragma silencing); the 14 test warnings fixed.
- `SWIFT_TREAT_WARNINGS_AS_ERRORS` / `GCC_TREAT_WARNINGS_AS_ERRORS = YES` at project level; `Scripts/spm-wall-check.sh` builds with `SUPPRESS_WARNINGS=NO` + both flags (`.treatAllWarnings` in `Package.swift` conflicts with Xcode's flag and breaks the build — verified). `PowerOfTenBoundaryTests` pins all of it; CI: `power-of-10.yml` + the S3-wall workflow.

## Findings by slice (auditor findings, false-positives excluded)

| Slice | Findings | Real | By rule |
|---|---|---|---|
| AI-UI-Extensions | 32 | 29 | R1-RECURSION 4, R3-GROWTH 4, R4-LENGTH 3, R5-TRAP 1, R5-VALIDATION 3, R7-DISCARD 2, R7-SWALLOW 11, R9-UNSAFE 1 |
| App-Duress-Backup-Social | 66 | 51 | R3-GROWTH 4, R4-LENGTH 10, R5-FORCE 7, R5-VALIDATION 1, R6-SCOPE 1, R7-DISCARD 10, R7-SWALLOW 10, R9-UNSAFE 8 |
| App-Food-Capture | 37 | 34 | R1-RECURSION 1, R3-GROWTH 5, R4-LENGTH 8, R5-FORCE 1, R5-VALIDATION 7, R6-SCOPE 1, R7-SWALLOW 10, R9-UNSAFE 1 |
| App-Food-Recipes | 28 | 28 | R3-GROWTH 4, R4-LENGTH 13, R5-FORCE 1, R5-VALIDATION 3, R6 1, R7-DISCARD 1, R7-SWALLOW 5 |
| App-Home-Companion | 43 | 39 | R3-GROWTH 6, R4-LENGTH 6, R5-VALIDATION 5, R6-SCOPE 1, R7-SWALLOW 21 |
| App-Move-Coach | 43 | 38 | R2-WHILE-TRUE 1, R3-GROWTH 4, R4-LENGTH 18, R5-FORCE 1, R5-VALIDATION 4, R7-DISCARD 6, R7-SWALLOW 4 |
| App-Private-Journal-Photos | 54 | 50 | R3-GROWTH 3, R4-LENGTH 10, R5-FORCE 1, R5-TRAP 3, R5-VALIDATION 7, R6-SCOPE 2, R7-DISCARD 1, R7-SWALLOW 22, R9-UNSAFE 1 |
| App-Settings-Privacy | 30 | 27 | R3-GROWTH 4, R4-LENGTH 8, R6-SCOPE 4, R7-DISCARD 4, R7-SWALLOW 7 |
| App-Store-Shell | 102 | 71 | R1-RECURSION 2, R2-BOUND 2, R3-GROWTH 3, R4-LENGTH 3, R5-FORCE 2, R5-TRAP 1, R5-VALIDATION 3, R7-DISCARD 39, R7-SWALLOW 11, R8-IF-NEST 5 |
| FernletDomainModel | 76 | 71 | R1-RECURSION 1, R3-GROWTH 6, R4-LENGTH 3, R5-FORCE 7, R5-VALIDATION 10, R6-STATIC-VAR 1, R7-SWALLOW 2, R9-UNSAFE 41 |
| Foundation-Services | 51 | 51 | R1-RECURSION 1, R2-BOUND 2, R3-GROWTH 4, R4-LENGTH 2, R5-VALIDATION 8, R6-SCOPE 1, R6-STATIC-VAR 3, R7-DISCARD 16, R7-SWALLOW 10, R9-UNSAFE 4 |
| Lock-Crypto | 47 | 40 | R2-BOUND 1, R3-GROWTH 1, R4-LENGTH 3, R5-FORCE 2, R5-VALIDATION 9, R6-SCOPE 1, R6-STATIC-VAR 1, R7-DISCARD 4, R7-SWALLOW 9, R9-UNSAFE 9 |
| Persistence-Sync | 62 | 57 | R2-BOUND 1, R2-WHILE-TRUE 1, R3-GROWTH 8, R4-LENGTH 1, R5-FORCE 3, R5-VALIDATION 5, R6 3, R6-STATIC-VAR 1, R7-DISCARD 22, R7-SWALLOW 10, R9-UNSAFE 2 |
| PrivateStores | 60 | 56 | R3-GROWTH 5, R5-FORCE 2, R5-VALIDATION 7, R6 2, R7-DISCARD 16, R7-SWALLOW 20, R9-UNSAFE 4 |
| ProximityKit-Engine-Heart | 81 | 66 | R3-GROWTH 7, R4-LENGTH 4, R5-FORCE 1, R5-VALIDATION 3, R6-SCOPE 1, R7-DISCARD 16, R7-SWALLOW 28, R9-UNSAFE 6 |
| ProximityKit-Mesh-Wire | 93 | 77 | R2-WHILE 3, R2-WHILE-TRUE 1, R3-GROWTH 11, R4-LENGTH 1, R5-FORCE 5, R5-TRAP 2, R5-VALIDATION 6, R6-SCOPE 1, R7-DISCARD 6, R7-SWALLOW 24, R9-UNSAFE 17 |

Totals: 905 findings, 785 real ({'medium': 272, 'low': 473, 'high': 40}); by rule: R1-RECURSION 9, R2-BOUND 6, R2-WHILE 3, R2-WHILE-TRUE 3, R3-GROWTH 79, R4-LENGTH 93, R5-FORCE 33, R5-TRAP 7, R5-VALIDATION 81, R6 6, R6-SCOPE 13, R6-STATIC-VAR 6, R7-DISCARD 143, R7-SWALLOW 204, R8-IF-NEST 5, R9-UNSAFE 94.

## Review-only rules — what the scanner cannot see

### R3 — input-driven growth without a cap (87)

| Slice | Where | Input | Cap |
|---|---|---|---|
| AI-UI-Extensions | `RecipeWebImporter.swift` importedRecipe(from:sourceURL:catalog:) — `ingredients` | JSON-LD `recipeIngredient` from an arbitrary fetched recipe  | NONE (only the 3 MB HTML fetch cap upstr |
| AI-UI-Extensions | `RecipeWebImporter.swift` orderedSteps(from:) — returned [RecipeStep] | JSON-LD `recipeInstructions` from an arbitrary fetched recip | NONE |
| AI-UI-Extensions | `WidgetSharedModels.swift` PendingWidgetActionWriter.append(_:) — `records` | repeated widget +1-water taps while the app is never opened  | NONE (dedupe by row id only, and ids are |
| AI-UI-Extensions | `SharedRecipeImportQueueWriter.swift` enqueue(_:) — `records` | repeated user shares into the extension while the app is nev | NONE (dedupe by identical URL string onl |
| App-Duress-Backup-Social | `SealedBackupService.swift` restoreChunks(payloadType:) -> records / plaintexts (and SealedBackupC | CloudKit private DB: head.chunkCount (unauthenticated field) | NONE (entry point in CloudKitSync, out o |
| App-Duress-Backup-Social | ` ConnectView.swift` Task per tap: completeEnrollment / completeRecovery / DuressPINEntrySh | Repeated user taps | NONE (no in-flight guard) — reported as  |
| App-Food-Capture | `FoundationDishDecomposition.swift` MealDecompositionResolver.resolve `resolvedIngredients` / per-componen | on-device model output (decomposition.components) | NONE (prompt asks 2-6, not enforced) |
| App-Food-Capture | `BarcodeServingStepView.swift` BarcodeServingMemory UserDefaults dictionary | repeated user action (each distinct scanned GTIN) | NONE |
| App-Food-Recipes | `RecipeShareCodec.swift` decodePayload(from:) → SharedRecipePayload.ingredients / .steps / name | pasted share text (RecipeImportSheet editor / pasteboard) —  | NONE (no text-length cap, no ingredient/ |
| App-Food-Recipes | `FoodView.swift` RecipeSheet.ingredients / RecipeSheet.steps | repeated user taps on 'Add ingredient' / 'Add step' (plus ba | NONE (Stepper bounds servings 1...24 but |
| App-Food-Recipes | `RecipeWebImageAttemptMemory.swift` recordAttempt(_:defaults:) → UserDefaults string array | one entry per saved recipe whose web image this device attem | NONE explicit; pruned only by local dele |
| App-Home-Companion | `ContentView.swift` body .onChange(of: lockService.state) Task { drainPendingPeriodNarrati | lock-state transitions (user unlock/lock, auto-lock, duress) | NONE — one unstructured Task per transit |
| App-Home-Companion | `ContentView.swift` body .onChange(of: activeSheet?.id) Task { loadPeriodEntriesIfPossible | .logPeriod sheet dismissals | NONE — one Task per dismissal, no dedupe |
| App-Home-Companion | `ContentView.swift` body .onChange(of: lockService.state) Task { settleSealedBackupsAfterH | hub unlocks | NONE at the spawn (coordinator's store-e |
| App-Home-Companion | `HomeView.swift` refreshRecentPeriodActivity Tasks (.task, onChange activeSheet, onChan | every sheet dismissal + visibility flips | NONE — one HealthKit-querying Task per e |
| App-Home-Companion | `HomeView.swift` syncCompanionSettled Task | companion pets during a settled window | NONE — one 10-minute sleeping Task per p |
| App-Home-Companion | `AmbientCards.swift` computeForgottenWorkout counts / recent | store.loadDays() — entire diary history | NONE (bounded only by total history) |
| App-Move-Coach | `CoachPlanImporter.swift` FernletStore.settings.customExercises (applyCoachPlan:568) | clipboard-pasted CoachPlan.newExercises (≤ 60 per paste) | NONE across imports |
| App-Move-Coach | `CoachPlanPasteSheet.swift` text (@State) via PasteButton | clipboard | NONE at entry (512 KB applied only later |
| App-Move-Coach | `GuidedWorkoutEditorSheet.swift` rows (persisted via updateGuidedSession) | repeated user picker selections | NONE |
| App-Move-Coach | `WorkoutLocationSetupView.swift` locations (persisted via setWorkoutLocations) | repeated user adds (template/custom) | NONE |
| App-Private-Journal-Photos | `WorryBoxService.swift` WorryBoxService.worries / addWorry text | user text (First Aid entry view and the hub composer) | count: NONE (one row per explicit gestur |
| App-Private-Journal-Photos | `DisposableCameraView.swift` DisposableCameraView.postSessionMessageNotification (Task per unread i | inbound session chat messages (peers) | NONE — one Task per event with no dedupe |
| App-Private-Journal-Photos | `DisposableCameraView.swift` renameMeshSheet.newMeshName | user text broadcast to peers | NONE at the sheet (advertised copy is pr |
| App-Private-Journal-Photos | `ProgressPhotoTimeline.swift` ProgressPhotoDetailView.caption | user text | NONE (see R5-VALIDATION finding) |
| App-Private-Journal-Photos | `CreationStudioView.swift` CreationStudioView.name | user text | NONE for the unlisted save (ItemNameMode |
| App-Settings-Privacy | `SettingsSheet.swift` personalCareSettings 'Add task' -> store.addPersonalCareTask (settings | repeated user action (button tap) + free-text label | NONE (DiaryStore.addPersonalCareTask tri |
| App-Settings-Privacy | `SettingsSheet.swift` generalTab .onChange(of: dailyCheckInTime) -> Task { scheduleDailyChec | repeated user action (DatePicker ticks) — task fan-out | NONE (one Task per tick, no cancel/dedup |
| App-Settings-Privacy | `SettingsSheet.swift` healthSyncedProfileBinding.set -> Task { healthKit.syncBodyProfileMeas | repeated user action (Stepper/Picker ticks) — task fan-out | NONE (one Task per edit, no cancel/dedup |
| App-Settings-Privacy | `PrivacyDataSettingsView.swift` retrySealedRestore -> Task { store.restoreSealedBackupsIfNeeded(userIn | repeated user action ('Retry restore' taps) — task fan-out | NONE (button not disabled; SealedBackupC |
| App-Store-Shell | `WidgetBridge.swift` PendingWidgetActionQueue.append(_:) / claimAll() | widget + Siri App Intent taps (other processes) via the app- | NONE |
| App-Store-Shell | `FernletStore.swift` importRecipe(from:) -> foodItems.append | pasted clipboard share text; mesh .local recipe (via importP | NONE (RecipeShareCodec.decodePayload imp |
| App-Store-Shell | `FernletStore.swift` importProximityRecipeShare(_:) -> addSavedRecipe (ingredientLines / no | verified mesh peer | imageJPEGData capped at ProximityRecipeS |
| App-Store-Shell | `FernletStore.swift` ingestModerationRows(_:) -> moderationLedger.ingestForeign | verified mesh peers (one-hop relay) | NONE at the store; ModerationLedger.inge |
| FernletDomainModel | `CoachPlan.swift` CoachExerciseDefinition.primaryMuscles / secondaryMuscles; all String  | untrusted pasted text | NONE at decode for array counts or strin |
| FernletDomainModel | `NutritionModels.swift` SharedRecipePayload.ingredients / steps / name / notes; SharedRecipeIn | untrusted pasted share text (RecipeShareCodec.decodePayload) | NONE (synthesized Codable; no byte gate  |
| FernletDomainModel | `FriendPhotoPayloads.swift` FriendPhotoManifestPayload.entries / FriendPhotoRequestPayload.missing | untrusted mesh peer plaintext | NONE in the types; MeshNetworkManager ha |
| FernletDomainModel | `PayloadType.swift` PayloadSummary.extraDetails / title / subtitle | peer wire (sender-built disclosure summary) | NONE in the type |
| FernletDomainModel | `SettingsModel.swift` FernletSettings.parkedUnknownKeys | synced settings blob (own iCloud account; any newer/foreign  | NONE — deliberately uncapped per comment |
| FernletDomainModel | `SettingsModel.swift` FernletSettings.sickDays / intentDismissedDays | repeated user actions (one key per day) via DiaryStore | NONE (append-only day-keyed maps; DiaryS |
| FernletDomainModel | `SettingsModel.swift` FernletSettings.customExercises + WorkoutExerciseCatalog.custom | repeated coach-plan imports (<= 60 per plan) | NONE total |
| FernletDomainModel | `SettingsModel.swift` FernletSettings.workoutLocations / personalCareTasks | repeated user actions (add location / add custom care task) | NONE |
| Foundation-Services | `HealthKitService.swift` HealthKitService.startAnchoredQuery(for:handler:) — samples/deletedObj | HealthKit anchored query, predicate nil, limit HKObjectQuery | NONE |
| Foundation-Services | `HealthKitService.swift` HealthKitService.activeQueries / observationRegistrations | repeated startObserving / enableIntegration calls (app code) | observationRegistrations keyed by type;  |
| Foundation-Services | `HealthKitService.swift` stressMetricDays — days array + four dailyAverages dictionaries | HealthKit statistics over caller-supplied daysBack | NONE (daysBack floored to 1, never cappe |
| Foundation-Services | `WorkoutHealthKitSync.swift` reconcileWorkouts — Task per tombstoned sample | HealthKit delivery batch | NONE (one Task per tombstoned sample; ra |
| Foundation-Services | `SharedRecipeImportQueue.swift` SharedRecipeImportQueue.records() / modifyRecords | App-Group JSON queue file written by the share extension (an | NONE on queue length (attempt cap 5 boun |
| Foundation-Services | `FernletDate.swift` FernletDate.dayKeys(in:) — keys array | caller DateInterval built from persisted/decoded dates | NONE (interval length) |
| Foundation-Services | `BundledFoodStore.swift` SQLiteBundledFoodSource.items(ids:) — placeholder list / results | caller id list (recipe ingredient ids, user data) | NONE on placeholder count (SQLite variab |
| Lock-Crypto | `FernletLockView.swift` FernletLockSetupView.finalizeSetup() Task | repeated taps on the disclosure confirm button | NONE — no in-flight guard; two concurren |
| Persistence-Sync | `CloudKitDataService.swift` SystemCloudKitRecordDatabase.recordIDs(from:) | CloudKit query pages (network, server-controlled cursor) | NONE (no page cap, no result cap) |
| Persistence-Sync | `CloudKitDataService.swift` recordIDsForExistingType / deleteAllCloudKitData recordIDs accumulator | every record of 20 record types across every zone (network) | NONE in memory (the DELETE itself is bat |
| Persistence-Sync | `CloudKitDataService.swift` sealedBackupChunks(payloadType:) — (1..<head.chunkCount).map | the `chunkCount` field of a CloudKit record (unvalidated ext | NONE |
| Persistence-Sync | `CoreDataFernletRepository.swift` cachedAllDays / loadAllDays() | every DayRecord row, including rows imported by CloudKit syn | NONE (deliberately uncapped row store; t |
| Persistence-Sync | `PendingWriteBuffer.swift` DebouncedRowBuffer.pendingUpserts / pendingDeletes | repeated local user mutations while the store keeps failing | NONE |
| Persistence-Sync | `PendingWriteBuffer.swift` DebouncedAppendBuffer.pending | repeated local ledger mints while the store keeps failing | NONE |
| Persistence-Sync | `AIRetryQueueService.swift` apply(_:) | the persisted / CloudKit-synced snapshot blob | NONE (the cap and TTL are enforced only  |
| Persistence-Sync | `DiaryStore.swift` dailyScores | one row per day, appended by storeDaySummary; each row carri | NONE |
| Persistence-Sync | `DiaryStore.swift` settings.intentDismissedDays / settings.sickDays | one permanent key per day dismissed / marked sick, in the sy | NONE |
| Persistence-Sync | `DiaryStore.swift` settings.workoutProgression | one permanent key per distinct exercise NAME (free text from | NONE (keys are removed only when a count |
| Persistence-Sync | `DiaryStore.swift` foodItems | web imports, barcode/label scans, and one minted FoodItem pe | NONE (only USDA rows are filtered out);  |
| Persistence-Sync | `DiaryStore.swift` workshop.textureEntries / memories / recipes | explicit user creations (one per deliberate action), in the  | NONE (memories' TEXT is capped at 240 ch |
| PrivateStores | `PeriodTrackerStore.swift` PeriodTrackerStore.entries / CycleDayEntry.samples | HealthKit — every cycle-relevant sample from every source ap | NONE on sample count (the day count is b |
| PrivateStores | `PeriodTrackerStore.swift` UserLoggedCycleEvent.customSymptomScales sealed into MenstrualNarrativ | user-authored custom symptom names + values from the log she | NONE (the note is capped at 1000 chars o |
| PrivateStores | `IntimacyLogRepository.swift` IntimacyLogRepository.logs(contentKey:) | repeated user actions (every intimacy log ever written), all | NONE — no `fetchLimit` (the paged `logs( |
| PrivateStores | `WorryNarrativeRepository.swift` WorryNarrativeRepository.worries(contentKey:) and reencryptAll(from:to | repeated user actions (every worry row), decrypted / re-seal | NONE — no `fetchLimit`, no paging |
| PrivateStores | `ProgressPhotoStore.swift` ProgressPhotoStore index records (`add` → `persist`) | repeated user captures of body photos | NONE — the sealed index grows unboundedl |
| ProximityKit-Engine-Heart | `ProximityCoordinator.swift` per-event Tasks in subscribeToTransport()/subscribeToRanging() | every inbound message, transport state, distance sample, ran | NONE |
| ProximityKit-Engine-Heart | `ProximityCoordinator.swift` fail() cleanup Task | every failure (incl. per bad inbound envelope) | NONE (no dedupe once already .failed) |
| ProximityKit-Engine-Heart | `ProximityCoordinator.swift` ProximityInspectorEventRecorder.events | every coordinator event (peer/transport driven) | NONE |
| ProximityKit-Engine-Heart | `ProximityRecipeShareManager.swift` lastAcceptedBySender | peer fingerprint / display name per received share | NONE (never pruned, not cleared on stop) |
| ProximityKit-Engine-Heart | `ProximityTrustVault.swift` auditEvents | coordinator audit sink (per envelope/transition) | 500 on record; NONE on init/apply |
| ProximityKit-Engine-Heart | `ModerationReportRelay.swift` verifiedRows(from:) result / ModerationReportPayload.reports on decode | peer .itemReport payload | NONE at receive (maxReports enforced onl |
| ProximityKit-Engine-Heart | `SessionMessageStore.swift` seenIDs | peer + own message ids | NONE explicit (rate-limited growth, clea |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift` pendingAdmissionRequests | .meshAdmissionRequest payloads (pre-commit peers included) | NONE (dedup key requesterSigningPublicKe |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift` approvedRemovalProposalIDs / removedMemberFingerprints | .meshRemovalSecond ids and target strings | NONE (cleared only at session end) |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift` currentMesh.members | .meshDescriptor payloads (mergeMeshDescriptor append; wholes | NONE |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift` sessionRoster / pendingFriendReview.entries | slot commits (peers may re-commit with fresh identities) | NONE (dedup by fingerprint only) |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift` epochLog | .meshKeyRotation / .meshAdmissionGrant payloads | NONE (append-only, never read) |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift` pendingQRVerifications | user QR scans keyed by slot id | NONE (not pruned on slot removal despite |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift` pendingRotationAcks | .meshKeyAck memberFingerprint (wire claim, not sender-bound) | NONE during the 10 s window |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift` FriendPhotoPayload.session.participants (persisted via cachePhoto) | .friendPhoto metadata | NONE |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift` Task fan-out: sendRequestedPhotos | .friendPhotoRequest ids | NONE (one Task per requested photo per r |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift` Task fan-out: .meshRotationSync handler | .meshRotationSync payloads from the elected coordinator | NONE (one 3 s Task per payload, no dedup |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift` handlePhotoManifest missing → FriendPhotoRequestPayload | .friendPhotoManifest entries | NONE (reflected into the outgoing reques |
| ProximityKit-Mesh-Wire | `PresenceManager.swift` ownEphemeralPeerNames | repeated start() (scene/tab/lock toggles) | NONE |
| ProximityKit-Mesh-Wire | `PresenceManager.swift` Task fan-out: handleLostPeer sweep tasks | Bonjour lostPeer events | NONE (one 46 s Task per event) |

### R2 — loops with no visible bound (4)

| Slice | Where | Bound |
|---|---|---|
| App-Move-Coach | `EquipmentIcons.swift:229` | NONE — `while true`; exits only via `guard let peek … else break` and per-case r |
| App-Store-Shell | `FernletStore.swift:1640` | NONE at the loop — spins on Task.yield() until the in-flight heartDropService.pu |
| Persistence-Sync | `HeartDropCloudTransport.swift:116` | NONE at the loop — `while true`. The real bounds are `chunkCount < perChunkBudge |
| ProximityKit-Mesh-Wire | `SealedPayloadFraming.swift:144` | NONE visible (`while true`); implicit: output ≤ limit (16 MiB decode / Int.max e |

### R1 — recursion (10)

| Slice | Where | Form | Bounded | Notes |
|---|---|---|---|---|
| AI-UI-Extensions | `RecipeWebImporter.swift` imageURLValue(_:relativeTo:) | direct | False | Recurses per array element (375) and on the dictionary's url/contentUrl keys (380-381). In |
| AI-UI-Extensions | `RecipeWebImporter.swift` orderedSteps(from:) | direct | False | Recurses via `values.flatMap(orderedSteps(from:))` (932) and the HowToSection branch `orde |
| AI-UI-Extensions | `RecipeWebImporter.swift` parseServings(from:) | direct | False | `parseServings(from: array.first)` (702). Depth follows `recipeYield` array nesting from t |
| AI-UI-Extensions | `RecipeWebImporter.swift` instructionText(from: Any) ↔ instructionText(from: | indirect | False | Mutual cycle: (Any) → (dictionary) at 959, and (dictionary) → `itemList.compactMap(instruc |
| App-Food-Capture | `FoodProductWebImporter.swift` imageValues(in:) | direct | False | Recurses into array elements (832) and dictionary 'image' / '@graph' / ImageObject 'url' ( |
| App-Store-Shell | `FernletApp.swift` reloadPersistenceForPreferenceChange(_:) | direct | False | Awaits itself with the parked pendingPreferenceReload after a reload; the await keeps the  |
| App-Store-Shell | `FernletApp.swift` UIView.navigationBars() | direct | False | Recurses over subviews (found.append(contentsOf: subview.navigationBars())); depth = view- |
| FernletDomainModel | `SettingsModel.swift` JSONValue.init(from:) / JSONValue.encode(to:) | indirect | False | init(from:) -> container.decode([JSONValue]/[String: JSONValue]) -> JSONValue.init(from:)  |
| Foundation-Services | `JSONLDScraper.swift` JSONLDScraper.object(ofType:in:) | direct | False | Calls itself for every @graph item, itemListElement item, and bare-array element (lines 81 |
| Persistence-Sync | `CloudKitDataService.swift` SystemCloudKitRecordDatabase.recordIDs(from:) | direct | False | Line 1037 calls itself, but from inside `Task { }` spawned in the `queryResultBlock` callb |

### R7 — `@discardableResult` on a success/failure signal (201)

| Slice | Where | Why |
|---|---|---|
| AI-UI-Extensions | `AIAuditLog.swift:215` AIAuditLogPersisting.clear() -> Bool | @discardableResult on a documented success/failure Bool ("false when the erase failed and the log ma |
| AI-UI-Extensions | `AIAuditLog.swift:326` AIAuditLog.clear() — `_ = sink?.clear()` | `_ =` discards a failure signal. Today the delete-all funnel happens to clear the sink directly and  |
| App-Duress-Backup-Social | `SealedBackupCoordinator.swift:362` setSealedBackupEnabled(...) -> Bool | Doc says 'returns whether it succeeded; callers should only persist the on preference when true' — a |
| App-Duress-Backup-Social | `SealedBackupCoordinator.swift:448` retryDeferredReuploadIfNeeded(...) -> Bool | Bool conflates skipped and failed; recovery lives inside so return Void instead of a discardable Boo |
| App-Duress-Backup-Social | `SealedBackupCoordinator.swift:485` retryDeferredPeriodReuploadIfNeeded() -> Bool | Same as 448. |
| App-Duress-Backup-Social | `SealedBackupCoordinator.swift:748` adoptSyncedEscrowAndReupload() -> Bool | 'Whether a synced key was adopted' is a success/failure Bool for a user action; the UI caller discar |
| App-Duress-Backup-Social | `SealedBackupCoordinator.swift:764` _ = await setSealedBackupEnabled(true, .sensitiveN | Drops the re-seal success Bool after an escrow adopt; only the inner audit line remains. |
| App-Duress-Backup-Social | `SealedBackupCoordinator.swift:800` _ = await setSealedBackupEnabled(true, .journalNar | Drops the re-seal failure; unlike the period branch (771) no deferral is recorded, so the stale-key  |
| App-Duress-Backup-Social | `SealedBackupCoordinator.swift:808` _ = await setSealedBackupEnabled(true, .intimacyLo | Same as 800 for intimacy. |
| App-Duress-Backup-Social | `SealedBackupCoordinator.swift:958` restoreSealedBackup(payloadType:) -> Bool | didRestore Bool is NOT recorded on the host by this wrapper; the value is the only signal — remove t |
| App-Duress-Backup-Social | `OwnPhotoBackupCoordinator.swift:246` setEnabled(_:) -> Bool | Success/failure Bool that gates an irreversible key binding; caller reads it today but the attribute |
| App-Duress-Backup-Social | `OwnPhotoBackupCoordinator.swift:547` tearDownForDeleteAll() -> Bool | 'Whether every corpus cleared' is a success/failure Bool; both callers branch on it, so simply drop  |
| App-Food-Capture | `MealPhotoRecognizer.swift:53` identify `(try? await classifier.classifications(i | Feeds a decision, but a Vision failure becomes `.nothingRecognized` with no log — error path silentl |
| App-Food-Capture | `DishTemplateLexicon.swift:77` catalog `try? Data(contentsOf:)` / `try? JSONDecod | Feeds the guard, but a bundled-resource failure silently disables the M2 tier with no log/assert (sp |
| App-Food-Capture | `FoodCatalogDatabaseBuilder.swift:95` insertRows `(try? encoder.encode(...))` x3 | Encode failure becomes a NULL column in the generated catalog instead of failing the build (spirit f |
| App-Food-Capture | `MealResolutionService.swift:113` resolveMeals `catch {}` (and 124) | Not a try? but the same swallow: the tier's error is dropped unnamed at the cascade (spirit finding) |
| App-Food-Recipes | `FoodView.swift:2071` @discardableResult MealSheet.attachPhoto(_:data:to | Bool is the photo-seal success/failure signal; both callers bind it (`let photoAttached = …`), so th |
| App-Food-Recipes | `FoodView.swift:677` try? await Task.sleep(for: .seconds(1.2)) (importF | Bare try? — the cancellation error feeds no decision (dismiss runs regardless). Scanner-enforced; fi |
| App-Food-Recipes | `IngredientSubstitutionSheet.swift:91` try? await Task.sleep(nanoseconds: 200_000_000) | Bare try?; the following guard !Task.isCancelled compensates instead of the catch naming the recover |
| App-Food-Recipes | `CookingMode.swift:695` try? await Task.sleep(for: .seconds(remaining)) (a | Bare try?; the following `if Task.isCancelled { return }` compensates. Scanner-enforced; fix listed. |
| App-Home-Companion | `StressService.swift:182` guard let data = try? JSONEncoder().encode(state)  | Feeds a decision but silently; folded into the R7-SWALLOW fix at line 185 (do/catch + audit line). |
| App-Home-Companion | `AgeAssuranceStore.swift:108` guard let data = try? JSONEncoder().encode(updated | In-memory record already updated; a persist failure is silent and reverts the gate on relaunch — see |
| App-Move-Coach | `MoveView.swift:1937` WorkoutExerciseDraft.commit(into:includingSetsAndR | Bool success/failure signal ('false, rows untouched'); WorkoutSheet.addDraftExercise discards it — r |
| App-Move-Coach | `CoachPlanImporter.swift:529` FernletStore.applyCoachPlan -> CoachPlanImportResu | Optional whose nil means 'refused/nothing written' — a success signal; the production caller consume |
| App-Move-Coach | `GuidedWorkoutEditorSheet.swift:291` call site: store.updateGuidedSession(_:) -> Bool ( | Refusal Bool ignored, sheet dismisses as if saved. |
| App-Move-Coach | `GuidedWorkout.swift:199` call sites: store.startGuidedRun(_:replacingActive | 'whether the run actually started' ignored. |
| App-Move-Coach | `MoveView.swift:71` call sites: store.reworkTodaysGuidedPlan() -> Bool | Refusal Bool ignored (line 71 asserts in a comment that it cannot refuse — make that checkable). |
| App-Move-Coach | `TrainerExportView.swift:122` call sites: store.discardExportedFile(at:) -> Bool | 'file is gone' Bool ignored; plaintext export may remain while UI state says discarded. |
| App-Private-Journal-Photos | `WorryBoxService.swift:148` WorryBoxService.releaseAll() -> Bool (@discardable | Bool is the success/failure signal the 'delete everything' outcome depends on; the sole caller consu |
| App-Settings-Privacy | `DataExportBuilder.swift:391` @discardableResult purgeDataExports() -> Bool | Bool is a success/failure signal (plaintext export dir removed?); ignored at PrivacyDataSettingsView |
| App-Settings-Privacy | `DataExportBuilder.swift:429` @discardableResult discardExportedFile(at:) -> Boo | Bool is a success/failure signal (file gone?); ignored at TrainerExportView.swift:122 and :162. |
| App-Settings-Privacy | `PrivacyDataSettingsView.swift:861` _ = await store.resolveSealedBackupEscrowConflict( | Discards a Bool success signal; a false leaves the user with no message on the nothing-silent screen |
| App-Settings-Privacy | `PrivacyDataSettingsView.swift:1528` try? await Task.sleep(for: .milliseconds(1500)) | Enforced R7-SWALLOW; duplicate of the mock reloader's own delay — delete or propagate with `try awai |
| App-Settings-Privacy | `SettingsSheet.swift:2216` Task { try? await lockService.setBiometricEnabled( | Swallowed try? (scanner miss — mid-line inside Task {}); replace with do/catch that logs and sets ve |
| App-Settings-Privacy | `DataExportBuilder.swift:407` (try? fileManager.contentsOfDirectory(at:including | The `?? []` fallback changes the function's answer: a listing failure reads as 'nothing to sweep' an |
| App-Settings-Privacy | `DataExportBuilder.swift:374` purgeDataExports() (result ignored inside writeDat | Silently drops the purge Bool; log the miss (see the @discardableResult finding). |
| App-Settings-Privacy | `PrivacyDataSettingsView.swift:224` store?.purgeDataExports() (share-sheet completion) | Silently drops the purge Bool; a plaintext export left in tmp/ is unlogged. |
| App-Store-Shell | `FernletStore.swift:1278` spendCoins | Bool refusal (insufficient / already spent); only caller ignores it |
| App-Store-Shell | `FernletStore.swift:1414` buyClothingItem | ClothingPurchaseResult carries refusals; attribute unnecessary (caller uses it) |
| App-Store-Shell | `FernletStore.swift:1498` listCustomItemForSale | ShopListingResult carries refusals; attribute unnecessary |
| App-Store-Shell | `FernletStore.swift:1996` logNutrientSuggestionFood | Meal? nil = nothing logged (unresolvable pinned food); AmbientCards ignores |
| App-Store-Shell | `FernletStore.swift:2166` saveMealPhoto(_:) | UUID? nil = seal failed; callers assign, attribute unneeded |
| App-Store-Shell | `FernletStore.swift:2177` saveMealPhoto(data:) | UUID? nil = seal failed |
| App-Store-Shell | `FernletStore.swift:2225` addProgressPhoto(data:capturedAt:) | Record? nil = seal failed; MoveView checks |
| App-Store-Shell | `FernletStore.swift:2240` addProgressPhoto(_:caption:) | Record? nil = seal failed; MoveView checks |
| App-Store-Shell | `FernletStore.swift:2250` seedProgressPhoto (DEBUG) | Record? nil = seal failed; seeder ignores |
| App-Store-Shell | `FernletStore.swift:2477` removeWorkout | Bool refusal; MoveView branches, attribute unneeded |
| App-Store-Shell | `FernletStore.swift:2514` updateWorkout | Bool refusal; MoveView branches |
| App-Store-Shell | `FernletStore.swift:2803` setSealedBackupEnabled | Bool success; ignored at 986 and in SealedBackupCoordinator |
| App-Store-Shell | `FernletStore.swift:2877` setOwnPhotoBackupEnabled | Bool success; caller checks |
| App-Store-Shell | `FernletStore.swift:2897` deleteOwnPhotoEscrowBackups | Bool success; deleteAllData checks |
| App-Store-Shell | `FernletStore.swift:2904` resolveSealedBackupEscrowConflict | Bool success; PrivacyDataSettingsView discards with _ = |
| App-Store-Shell | `FernletStore.swift:2912` restoreSealedBackup | Bool success; test-only wrapper |
| App-Store-Shell | `FernletStore.swift:2920` restoreSealedBackupOutcome | outcome value; recorded observably by coordinator, but attribute still on a success/failure value |
| App-Store-Shell | `FernletStore.swift:2927` restorePeriodBackupTargeted | outcome value; ContentView/coordinator discard |
| App-Store-Shell | `FernletStore.swift:2936` restoreJournalBackupTargeted | outcome value; ContentView discards |
| App-Store-Shell | `FernletStore.swift:2946` restoreIntimacyBackupTargeted | outcome value; ContentView discards |
| App-Store-Shell | `FernletStore.swift:3268` reworkTodaysGuidedPlan | Bool refusal; MoveView 71/1018 ignore |
| App-Store-Shell | `FernletStore.swift:3353` updateGuidedSession | Bool refusal; GuidedWorkoutEditorSheet ignores |
| App-Store-Shell | `FernletStore.swift:3438` startGuidedRun | Bool 'run started' (fail-closed refusal); GuidedWorkout 104/199 ignore |
| App-Store-Shell | `FernletStore.swift:3808` saveCustomIngredient | FoodItem? nil = refused (empty name); attribute unneeded |
| App-Store-Shell | `FernletStore.swift:3873` saveRecipePhoto(_:for:) | Bool seal success; FoodView guards |
| App-Store-Shell | `FernletStore.swift:3882` saveRecipePhoto(data:for:) | Bool seal success; ignored at 3944 and 4142 |
| App-Store-Shell | `FernletStore.swift:4246` _ = diary.mutateDay (retryOldestMeal) | discards Bool write-success of a past-day removal before re-adding |
| App-Store-Shell | `FernletStore.swift:4396` deleteAllData | DeleteAllOutcome is the failure report; ContentView duress hook discards with _ = |
| App-Store-Shell | `FernletStore.swift:4721` resetAll | [String] of failed stores; attribute lets a standalone caller ignore it (no such caller today) |
| App-Store-Shell | `FernletStore.swift:5202` _ = repository.updateDay (scrubLeakedPastDayJourna | discards Bool persist-success; a failed stripped-day write still counts as a clean pass and the scru |
| App-Store-Shell | `FernletStore.swift:5274` mutateDay(date:_:) facade | re-declares @discardableResult on a Bool write-success signal |
| App-Store-Shell | `WidgetBridge.swift:130` WidgetSnapshotFileStore.write | Bool success; publish checks it |
| App-Store-Shell | `WidgetBridge.swift:193` WidgetSnapshotFileStore.delete | Bool success; clear() uses it |
| App-Store-Shell | `WidgetBridge.swift:247` PendingWidgetActionQueue.append | Bool durably-queued; doc explicitly invites ignoring it |
| App-Store-Shell | `WidgetBridge.swift:311` PendingWidgetActionQueue.write(_:to:) | Bool success ignored twice in claimAll → possible double-application |
| App-Store-Shell | `WidgetBridge.swift:354` WidgetSnapshotMirror.clear | Bool success; deleteAllData reports it |
| App-Store-Shell | `FileAIAuditLogStore.swift:83` FileAIAuditLogStore.clear | Bool success; deleteAllData reports it (protocol also carries the attribute — AIContext slice) |
| App-Store-Shell | `BackupExclusionLaunchGate.swift:173` resolveAtLaunch | LaunchResolution must be acted on (needsPrompt / deferred) |
| FernletDomainModel | `WorkoutProgram.swift:326` WorkoutLocation.init(from:) — (try? decodeIfPresen | The fallback hides corruption: decodeIfPresent only throws on a present-but-wrong-typed value, and t |
| Foundation-Services | `FernletAuditLog.swift:40` addCaptureHandler(_:) -> UUID | The token is the only way to remove the handler; discarding it leaks a permanent handler in an uncap |
| Foundation-Services | `KeychainHelpers.swift:103` store(_:account:service:accessibility:synchronizab | OSStatus is a pure success/failure signal; multiple callers across modules drop keychain write failu |
| Foundation-Services | `KeychainHelpers.swift:232` store(_:for:service:) -> OSStatus | Same OSStatus success/failure signal; StoragePreferencesStore.persist and loadOrCreateSymmetricKey i |
| Foundation-Services | `KeychainHelpers.swift:213` SecItemDelete(...) implicit discard (also line 225 | Imported C function's OSStatus dropped with no `_ =`; delete-everything / lock-reset flows cannot se |
| Foundation-Services | `NotificationService.swift:27` requestAuthorization() -> Bool | Bool = granted/denied, a success/failure signal; all callers use it, so the attribute is only a haza |
| Foundation-Services | `SharedRecipeImportQueue.swift:135` clear() -> Bool | Bool = whether the queue file was actually emptied; a wipe that ignores it re-imports recipes after  |
| Foundation-Services | `SharedRecipeImportQueue.swift:183` save(_:) -> Bool | Write success/failure signal; tests discard it today. |
| Foundation-Services | `SharedRecipeImportQueue.swift:194` writeRecords(_:to:) -> Bool | modifyRecords (line 177) discards it, so failed rewrites after remove/markAttempt are invisible in R |
| Foundation-Services | `HealthKitService.swift:474` KeychainItem.store(...) statement-level discard (a | Anchor write failures are dropped; a persistent failure replays history every launch with no log. |
| Foundation-Services | `HealthKitService.swift:459` KeychainItem.delete(...) statement-level (Void) —  | disableIntegration's anchor wipe cannot detect a failed delete; the fail-closed contract is not chec |
| Foundation-Services | `WorkoutHealthKitSync.swift:173` _ = try await service.deleteWorkout(fernletWorkout | A `false` on a real old sample means the resync leaves a duplicate in Health with no audit line; log |
| Foundation-Services | `StoragePreferences.swift:350` KeychainItem.store(data, for: .storagePreferences, | The persisted privacy choices silently fail to write (e.g. before first unlock) while the in-memory  |
| Foundation-Services | `StoragePreferences.swift:349` guard let data = try? encoder.encode(preferences)  | The try? feeds a decision but the recovery is a silent return; no log names why the preferences were |
| Foundation-Services | `KeychainHelpers.swift:261` store(keyData, for: account, service:) inside load | A dropped store failure returns an unpersisted content key — sealed data written with it is unrecove |
| Foundation-Services | `BundledFoodStore.swift:12` sqlite3_bind_text / sqlite3_bind_null / sqlite3_fi | Bind failures leave a parameter unbound and the query returns nothing with no log (finalize/close st |
| Foundation-Services | `MonotonicClock.swift:35` mach_timebase_info(&timebase) kern_return_t implic | On failure denom is 0 and the clock reads inf/NaN; guard the status and denom. |
| Foundation-Services | `HealthKitService.swift:628` (try? Self.types(for:).share) ?? [] in deleteAllAu | In the delete-everything sweep the fallback silently drops a capability from the wipe; elsewhere (sn |
| Foundation-Services | `SharedRecipeImportQueue.swift:111` try? Data(contentsOf:) / try? decoder.decode in re | Feeds a decision (empty / abort) but with no log; a corrupt queue file is silently permanent (see sp |
| Foundation-Services | `HealthKitService.swift:473` guard let data = try? NSKeyedArchiver.archivedData | The archive error is dropped and the anchor silently not persisted. |
| Lock-Crypto | `FernletLockService.swift:618` @discardableResult KeychainItem.store(_:for:servic | OSStatus is a success/failure signal; the discard is relied on at line 3034 (hardBindingNoticePendin |
| Lock-Crypto | `FernletLockService.swift:2310` @discardableResult handleDuress(_:passcode:scope:) | nil = 'unlock refused (.appLockSettings)'; three settings-side callers discard it and return success |
| Lock-Crypto | `FernletLockService.swift:2343` _ = try? await cryptoProvider.deriveVerifier (spen | The result is legitimately a discard (timing clock), but the try? swallows the error — enforced R7-S |
| Lock-Crypto | `FernletLockService.swift:3034` KeychainItem.store(Data([1]), for: .hardBindingNot | OSStatus dropped; a failed flag write should at least be audit-logged. |
| Lock-Crypto | `SecureEnclaveContentKeyWrap.swift:150` SecItemDelete(query) in deleteKey(service:) (impli | The enclave-key deletion reset()/duress wipe rely on for the crypto-erase claim is not status-checke |
| Persistence-Sync | `AppendOnlyRowStore.swift:75` append(_:) | Bool save-success signal; documented as false on a rolled-back save. |
| Persistence-Sync | `CoinLedgerRepository.swift:70` append(_:) | Bool write result — a dropped false is a lost coin row. |
| Persistence-Sync | `CoinLedgerRepository.swift:75` deleteAll() | Bool wipe result the delete-everything funnel must report. |
| Persistence-Sync | `CoreDataFernletRepository.swift:162` saveSnapshot(_:) | Bool durability signal; false means the coordinator must retry. |
| Persistence-Sync | `CoreDataFernletRepository.swift:215` updateDay(_:for:todayKey:) | Bool durability signal for a past-day write. |
| Persistence-Sync | `CoreDataFernletRepository.swift:373` _ = saveDatabase(migrated) | Drops whether the 'migration complete' blob was persisted; the in-memory cache then claims a backfil |
| Persistence-Sync | `CoreDataFernletRepository.swift:443` replaceTierTwoMemories(_:) | Bool write result for sealed-backup restore. |
| Persistence-Sync | `CoreDataFernletRepository.swift:528` _ = saveDatabase(migrated) | First-launch legacy migration save result dropped (scanner blind spot: line starts with `if`). |
| Persistence-Sync | `CoreDataFernletRepository.swift:617` purgeAllPersistedData() | Bool wipe result; the funnel reports it to the user. |
| Persistence-Sync | `CoreDataFernletRepository.swift:646` saveDatabase(_:invalidatesDayCache:) | Bool save result; the attribute is what hid the two `_ =` discards above. |
| Persistence-Sync | `CustomItemRepository.swift:71` upsert(_:) | Bool write result. |
| Persistence-Sync | `CustomItemRepository.swift:76` delete(ids:) | Bool write result. |
| Persistence-Sync | `CustomItemRepository.swift:97` deleteAll() | Bool wipe result. |
| Persistence-Sync | `DayRecordRepository.swift:87` upsert(_:) | Bool write result the row-write-first contract depends on. |
| Persistence-Sync | `DayRecordRepository.swift:129` delete(dateKeys:) | Bool write result. |
| Persistence-Sync | `DayRecordRepository.swift:150` deleteAll() | Bool wipe result. |
| Persistence-Sync | `HeartDropCloudTransport.swift:155` _ = try await database.modifyRecords(saving:deleti | Drops per-record delete Results; CloudKit reports partial failures there rather than throwing. |
| Persistence-Sync | `MilestoneLedgerRepository.swift:67` append(_:) | Bool write result for rows that are never re-derivable (no delete path, lifetime retention). |
| Persistence-Sync | `SavedRecipe.swift:178` _ = upsert(migrated) in load() | Failure ignored, then the one-time migration flag is set unconditionally — permanent legacy-recipe l |
| Persistence-Sync | `SavedRecipe.swift:197` _ = upsert(migrated) in loadAsync() | Same as line 178. |
| Persistence-Sync | `SavedRecipe.swift:221` upsert(_:) | Bool write result. |
| Persistence-Sync | `SavedRecipe.swift:254` delete(ids:) | Bool write result. |
| Persistence-Sync | `SavedRecipe.swift:275` deleteAll() | Bool wipe result. |
| Persistence-Sync | `SavedRecipe.swift:486` LegacySavedRecipeJSONRepository.save(_:) | Bool file-write result. |
| Persistence-Sync | `CoinLedgerRepositoring.swift:29` append(_:) | Protocol declaration of a Bool success signal. |
| Persistence-Sync | `CoinLedgerRepositoring.swift:31` deleteAll() | Protocol declaration of a Bool success signal. |
| Persistence-Sync | `CustomItemRepositoring.swift:31` upsert(_:) | Protocol declaration of a Bool success signal. |
| Persistence-Sync | `CustomItemRepositoring.swift:33` delete(ids:) | Protocol declaration of a Bool success signal. |
| Persistence-Sync | `CustomItemRepositoring.swift:35` deleteAll() | Protocol declaration of a Bool success signal. |
| Persistence-Sync | `DayRecordRepositoring.swift:69` upsert(_:) | Protocol declaration of a Bool success signal. |
| Persistence-Sync | `DayRecordRepositoring.swift:71` delete(dateKeys:) | Protocol declaration of a Bool success signal. |
| Persistence-Sync | `DayRecordRepositoring.swift:73` deleteAll() | Protocol declaration of a Bool success signal. |
| Persistence-Sync | `FernletRepository.swift:38` saveSnapshot(_:) | Protocol declaration of a Bool durability signal. |
| Persistence-Sync | `FernletRepository.swift:40` updateDay(_:for:todayKey:) | Protocol declaration of a Bool durability signal. |
| Persistence-Sync | `FernletRepository.swift:51` replaceTierTwoMemories(_:) | Bool signal actually being dropped by DiaryStore.swift:1318. |
| Persistence-Sync | `FernletRepository.swift:58` purgeAllPersistedData() | Bool wipe result surfaced to the user. |
| Persistence-Sync | `FernletRepository.swift:68` default replaceTierTwoMemories(_:) { false } | Same signal on the default implementation. |
| Persistence-Sync | `FernletRepository.swift:71` default purgeAllPersistedData() { true } | Same signal, and the default claims success for a conformer that purged nothing. |
| Persistence-Sync | `MilestoneLedgerRepositoring.swift:32` append(_:) | Protocol declaration of a Bool success signal. |
| Persistence-Sync | `SavedRecipeRepositoring.swift:19` upsert(_:) | Protocol declaration of a Bool success signal. |
| Persistence-Sync | `SavedRecipeRepositoring.swift:21` delete(ids:) | Protocol declaration of a Bool success signal. |
| Persistence-Sync | `SavedRecipeRepositoring.swift:23` deleteAll() | Protocol declaration of a Bool success signal. |
| Persistence-Sync | `LocalFernletRepository.swift:245` saveSnapshot(_:) | Bool durability signal (false under read-only recovery). |
| Persistence-Sync | `LocalFernletRepository.swift:262` updateDay(_:for:todayKey:) | Bool durability signal. |
| Persistence-Sync | `LocalFernletRepository.swift:300` replaceTierTwoMemories(_:) | Bool write result. |
| Persistence-Sync | `LocalFernletRepository.swift:351` purgeAllPersistedData() | Bool wipe result. |
| Persistence-Sync | `CoinLedgerService.swift:113` spend(amount:ref:) | false means the coins were NOT debited; ignoring it hands over goods for free. |
| Persistence-Sync | `CoinLedgerService.swift:128` reset() | Its own doc says the value must be threaded back so a failed wipe is not reported as complete. |
| Persistence-Sync | `CustomItemService.swift:105` reset() | Same self-contradicting wipe contract. |
| Persistence-Sync | `SavedRecipeService.swift:130` reset() | Same self-contradicting wipe contract. |
| Persistence-Sync | `DiaryStore.swift:783` removeWorkout(id:date:) | Bool 'was a row actually removed' — the facade's reversal logic must not run on a miss. |
| Persistence-Sync | `DiaryStore.swift:801` updateWorkout(_:date:) | Bool 'was a matching row found and replaced'. |
| Persistence-Sync | `DiaryStore.swift:1439` mutateDay(date:_:) | Documented 'whether the write succeeded'; every in-file caller discards it, so past-day write failur |
| Persistence-Sync | `DiaryStore.swift:1453` mutatePastDay(_:_:) | The actual repository write result; only an assert (compiled out in Release) looks at it. |
| PrivateStores | `MealPhotoStore.swift:102` MealPhotoStore.save(_:forID:) | @discardableResult on a Bool that means 'the photo was written' (false = nothing written). No caller |
| PrivateStores | `MealPhotoStore.swift:162` MealPhotoStore.restoreSealedPhoto(_:forID:) | @discardableResult on the escrow-restore write result; a discarded false is a photo silently missing |
| PrivateStores | `MealPhotoStore.swift:276` MealPhotoStore.deleteAll() | @discardableResult on a wipe result; both callers already check it. Remove the attribute so a future |
| PrivateStores | `MediaAtRestCrypto.swift:35` PrivateMediaKeyProviding.sealAndWrite(_:to:) | @discardableResult on the module's fail-closed write primitive, genuinely ignored at six sites (Meal |
| PrivateStores | `MealPhotoStore.swift:131` MealPhotoStore.imageData(for:) dual-open re-seal | Implicit discard of `sealAndWrite`'s Bool: a failed re-seal leaves the file in the pre-split generat |
| PrivateStores | `PrivateMediaStore.swift:128` PrivateMediaStore.save(_:) thumbnail write | Implicit discard of `sealAndWrite`'s Bool; a failed thumbnail write is silently retried on every rea |
| PrivateStores | `PrivateMediaStore.swift:150` PrivateMediaStore.imageData(for:) legacy-plaintext | Implicit discard: a failed upgrade means a plaintext friend photo stays unencrypted on disk indefini |
| PrivateStores | `PrivateMediaStore.swift:168` PrivateMediaStore.thumbnailData(for:) legacy thumb | Implicit discard of the re-seal result — same unencrypted-residue consequence as line 150. Route thr |
| PrivateStores | `PrivateMediaStore.swift:176` PrivateMediaStore.thumbnailData(for:) regenerated  | Implicit discard: the regenerated thumbnail silently fails to cache, so every render re-decodes the  |
| PrivateStores | `ProgressPhotoStore.swift:327` ProgressPhotoStore.readIndex() dual-open re-seal | Implicit discard: the sealed index stays under the pre-split key. Documented as fail-closed-and-retr |
| PrivateStores | `OwnPhotoKeyBinding.swift:181` OwnPhotoKeyBinder.bindIfEligible() | @discardableResult on a Result-shaped outcome carrying `.rebindFailed(OSStatus)`. All three app call |
| PrivateStores | `OwnPhotoKeyBinding.swift:203` OwnPhotoKeyBinder.recordConsentAndBind() | @discardableResult on the user-facing ceremony's outcome. Its only caller uses it — remove the attri |
| PrivateStores | `OwnPhotoKeyMigration.swift:270` OwnPhotoKeyMigrator.run(maxPasses:) | @discardableResult on the Bool that gates an irreversible key binding. The production caller uses it |
| PrivateStores | `OwnPhotoKeyMigration.swift:293` OwnPhotoKeyMigrator.performPass() | @discardableResult on the pass tally, which carries `abortedNoOwnKey` / `resealFailures` / `indeterm |
| PrivateStores | `ProgressPhotoStore.swift:117` ProgressPhotoStore.add(_:caption:capturedAt:) | @discardableResult on an optional whose nil IS the failure (nothing written). All callers return it  |
| PrivateStores | `ProgressPhotoStore.swift:145` ProgressPhotoStore.updateCaption(id:caption:) | `_ = persist(all)` drops the sealed-index write result: the caption edit is silently lost. Replace w |
| PrivateStores | `ProgressPhotoStore.swift:155` ProgressPhotoStore.updateCapturedAt(id:date:) | `_ = persist(all)` — the corrected capture date is silently lost on a failed index write. Same guard |
| PrivateStores | `ProgressPhotoStore.swift:166` ProgressPhotoStore.delete(id:) | `_ = persist(all)` after the bytes have already been deleted: a failed index write leaves a phantom  |
| PrivateStores | `ProgressPhotoStore.swift:171` ProgressPhotoStore.deleteAll() | @discardableResult on a wipe result for the body-photo timeline; its caller already checks it — remo |
| PrivateStores | `ProgressPhotoStore.swift:217` ProgressPhotoStore.restoreIndexPayload(_:) | @discardableResult on the restore no-clobber gate's Bool; the coordinator uses it — remove the attri |
| PrivateStores | `ProgressPhotoStore.swift:233` ProgressPhotoStore.restoreSealedPhoto(_:forID:) | @discardableResult forwarding the inner store's write result on the restore path; the coordinator us |
| PrivateStores | `PendingNarrativeBuffer.swift:224` PendingNarrativeBuffer.loadBufferKey() — KeychainI | The `OSStatus` of the v2 key write is discarded, and the legacy row is then deleted unconditionally  |
| PrivateStores | `PendingNarrativeBuffer.swift:238` PendingNarrativeBuffer.loadBufferKey() — SecItemDe | `SecItemDelete`'s OSStatus is dropped (Security imports it without `warn_unused_result`, so the comp |
| ProximityKit-Engine-Heart | `HeartDropOutbox.swift:109` HeartDropOutbox.retryLoad() -> Bool | Bool success signal; discarded at HeartDropService:377 and :648. Fix: Void retryLoad(); callers read |
| ProximityKit-Engine-Heart | `HeartDropOutbox.swift:151` HeartDropOutbox.enqueue(_:) -> EnqueueOutcome | Refusal enum; the only caller switches on it — remove the attribute. |
| ProximityKit-Engine-Heart | `HeartDropOutbox.swift:170` HeartDropOutbox.markUploaded(id:recordName:) -> Bo | Doc says false must not be continued past silently (possible orphaned public-DB record). |
| ProximityKit-Engine-Heart | `HeartDropOutbox.swift:400` HeartDropDedupStore.retryLoad() -> Bool | Same family as line 109; discarded at HeartDropService:378. |
| ProximityKit-Engine-Heart | `HeartDropPeerBundleCache.swift:86` HeartDropPeerBundleCache.retryLoad() -> Bool | Same family; discarded at HeartDropService:379. |
| ProximityKit-Engine-Heart | `HeartDropService.swift:626` HeartDropService.purgeDeadDrop() async -> Bool | false = records may remain on the public DB; App FernletStore.swift:1656 discards it. |
| ProximityKit-Engine-Heart | `HeartDropService.swift:648` _ = outbox.retryLoad() | `_ =` on a Bool; resolved by the Void retryLoad refactor. |
| ProximityKit-Engine-Heart | `HeartPrekeyStore.swift:302` HeartPrekeyStore.persist(_:) -> Bool | 'caller must not treat the state as durable' when false; all callers check it — attribute is dead, r |
| ProximityKit-Engine-Heart | `ProtectedSidecar.swift:229` ProtectedSidecar.mutate(_:) -> MutateOutcome | Tri-state success signal; `.refused` neither logged nor observed at nine ignoring call sites. |
| ProximityKit-Engine-Heart | `ProtectedSidecar.swift:253` ProtectedSidecar.mutateIfPersisted(_:) -> Bool | false on failed write, unlogged; ignored at HeartDropPeerBundleCache:112/190/206. |
| ProximityKit-Engine-Heart | `ProtectedSidecar.swift:268` ProtectedSidecar.retryLoad() -> Bool | Bool == (state == .ready); discarded by the unlock hop and by store tick calls. Make Void. |
| ProximityKit-Engine-Heart | `ProtectedSidecar.swift:449` ProtectedDataRetrying.retryLoad() -> Bool | Protocol twin of line 268; goes Void with it. |
| ProximityKit-Engine-Heart | `ProximityHeartLedger.swift:155` ProximityHeartLedger.retryLoad() -> Bool | Same family; discarded at HeartDropService:380. |
| ProximityKit-Engine-Heart | `ProximityHeartLedger.swift:191` ProximityHeartLedger.recordReceivedHeart(...) -> B | false conflates by-design duplicate with fail-closed unloaded (heart lost); callers consume it, so r |
| ProximityKit-Engine-Heart | `ProximityHeartLedger.swift:221` ProximityHeartLedger.recordReceivedDropHeart(...)  | Same as line 191; HeartDropService:586 consumes it. |
| ProximityKit-Engine-Heart | `IdentityService.swift:658` IdentityService.loadBackupEscrowKeyForOpen() -> Bo | false = 'not synced yet' retryable state; remove the attribute (both callers already consume). |
| ProximityKit-Engine-Heart | `IdentityService.swift:728` IdentityService.reconcileBackupEscrowKey() -> Back | `.conflict` obliges the caller to surface a user choice. |
| ProximityKit-Engine-Heart | `IdentityService.swift:788` IdentityService.adoptSyncedBackupEscrowKey() -> Da | nil = no synced key adopted. |
| ProximityKit-Engine-Heart | `ModerationBanStore.swift:230` _ = KeychainItem.store(...) | OSStatus discarded; a ban that failed to persist is logged as applied. |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift:1862` beginQRVerification(with:) @discardableResult -> B | Bool = scan accepted or not (failure signal); production caller consumes it — drop the attribute. |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift:1992` _ = await sendEnvelopeCore(... auditSendFailure: f | Discards the wire-send result AND suppresses the audit line; ceremony send failures are fully swallo |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift:2640` sendEnvelope(_:encodable:via:sealed:) @discardable | Bool = wire write succeeded; encode/seal/sign failures return false with no log and ~30 callers disc |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift:2944` _ = SecRandomCopyBytes(...) | Discards the OSStatus; a failed RNG leaves an all-zero group key. Removed by the safe-RNG rewrite. |
| ProximityKit-Mesh-Wire | `PresenceManager.swift:1083` evaluateConnectedCoordinatorForTesting @discardabl | Bool = accepted as eligible friend (success/failure); shipping-code declaration — drop the attribute |

### R9 — unsafe seams (34; refactor 22, allowlist 12)

| Slice | File | Seam | Recommendation |
|---|---|---|---|
| AI-UI-Extensions | `RecipeWebImporter.swift` | POSIX/BSD sockets — `inet_pton(AF_INET6, host, &address)` fills a fixe | refactor |
| App-Duress-Backup-Social | `SealedBackupService.swift` | CryptoKit value extraction: big-endian integer serialization for the G | refactor |
| App-Duress-Backup-Social | `SealedPhotoBackupService.swift` | Same CryptoKit value extraction as SealedBackupService (v3 AAD integer | refactor |
| App-Food-Capture | `FoodCatalogDatabaseBuilder.swift` | SQLite3 C API — sqlite3_exec's errmsg out-parameter | refactor |
| App-Private-Journal-Photos | `CustomItemRendering.swift` | CoreGraphics CGContext(data:width:height:...) fed from [UInt8].withUns | refactor |
| FernletDomainModel | `CompanionModels.swift` | none — a static let of a plain value type annotated only because the t | refactor |
| FernletDomainModel | `FoodItemSearch.swift` | none — immutable empty index of Sendable-shaped structs | refactor |
| FernletDomainModel | `NutritionModels.swift` | none — the only non-Sendable member is a pure accessor closure | refactor |
| FernletDomainModel | `WorkoutModels.swift` | process-global exercise registry (baseExercises immutable; custom muta | refactor |
| FernletDomainModel | `WorkoutProgram.swift` | none — an immutable static session/split library of plain value types | refactor |
| Foundation-Services | `FernletAuditLog.swift` | process-global test-capture registry (nonisolated(unsafe) static var + | refactor |
| Foundation-Services | `KeychainHelpers.swift` | CryptoKit — SymmetricKey bytes via ContiguousBytes.withUnsafeBytes | allowlist |
| Foundation-Services | `BundledFoodStore.swift` | SQLite C API — SQLITE_TRANSIENT destructor sentinel | allowlist |
| Foundation-Services | `Scoring.swift` | immutable static table of a non-Sendable value type (nonisolated(unsaf | refactor |
| Lock-Crypto | `FernletLockService.swift` | Security framework — SecAccessControlCreateWithFlags CFError out-param | allowlist |
| Lock-Crypto | `FernletLockService.swift` | CryptoKit SymmetricKey→Data extraction; Foundation Data↔fixed-width in | refactor |
| Lock-Crypto | `SecureEnclaveContentKeyWrap.swift` | Security framework — SecKey/SecAccessControl Create-rule CFError out-p | allowlist |
| Lock-Crypto | `DeviceBindingID.swift` | process-global read-through cache of an immutable per-install keychain | refactor |
| Persistence-Sync | `Persistence.swift` | Core Data / NSPersistentCloudKitContainer stack — a process-wide singl | allowlist |
| Persistence-Sync | `Persistence.swift` | DEBUG-only once-latch for the CloudKit schema deploy (a mutable static | refactor |
| PrivateStores | `PendingNarrativeBuffer.swift` | CryptoKit → keychain: converting a `SymmetricKey` to `Data` for `Keych | allowlist |
| PrivateStores | `PrivateMediaKeyStore.swift` | CryptoKit → keychain: converting the freshly minted media key to `Data | allowlist |
| PrivateStores | `PrivatePersistenceController.swift` | Core Data: the process-wide sealed (never-iCloud) persistent container | allowlist |
| ProximityKit-Engine-Heart | `HeartDropSealer.swift` | none — UUID tuple → 16 bytes | refactor |
| ProximityKit-Engine-Heart | `HeartDropSidecarKey.swift` | CryptoKit SymmetricKey byte export for a keychain row | refactor |
| ProximityKit-Engine-Heart | `ProtectedSidecar.swift` | NotificationCenter token read from a nonisolated deinit of a @MainActo | refactor |
| ProximityKit-Engine-Heart | `IdentityService.swift` | big-endian UInt64 serialization (283, 348) and AES.GCM.Nonce byte expo | refactor |
| ProximityKit-Mesh-Wire | `MeshNetworkManager.swift` | CryptoKit AES.GCM.Nonce → Data copy; SecRandomCopyBytes group-key fill | refactor |
| ProximityKit-Mesh-Wire | `CanonicalSignatureSerializer.swift` | integer/UUID byte serialization | refactor |
| ProximityKit-Mesh-Wire | `ProximityVerification.swift` | UInt64 big-endian serialization | refactor |
| ProximityKit-Mesh-Wire | `SealedPayloadFraming.swift` | Apple Compression framework C API (compression_stream_init/process/des | allowlist |
| ProximityKit-Mesh-Wire | `MeshMultipeerSession.swift` | MultipeerConnectivity delegate → MainActor bridging (non-Sendable MCPe | allowlist |
| ProximityKit-Mesh-Wire | `NIRangingSession.swift` | NearbyInteraction delegate → MainActor bridging (non-Sendable NISessio | allowlist |
| ProximityKit-Mesh-Wire | `ProximityForegroundAnchor.swift` | ActivityKit `Activity` (non-Sendable class) passed to its nonisolated  | allowlist |

## High-severity findings (40)

| Slice | Rule | Where | Description |
|---|---|---|---|
| App-Duress-Backup-Social | R4-LENGTH | `FriendListView.swift:46` FriendListView.body | `var body` is 155 code lines: display-name row, search row, picker, the whole peer list with per-row expansion and three swipe actions, plus |
| App-Duress-Backup-Social | R4-LENGTH | `ProximityRecipeShareSheet.swift:51` ProximityRecipeShareSheet.body | `var body` is 130 code lines: an 74-line recipient card (toggles, searching/no-nearby branches, the recipient row list), status text, diagno |
| App-Food-Capture | R5-VALIDATION | `FoodProductWebImporter.swift:507` FoodProductWebImporter.importedProduct(s | `Int(protein.rounded())` / `Int(carbs.rounded())` / `Int(fat.rounded())` (and `Int($0.rounded())` for calories at 475 and 995) are trapping  |
| App-Food-Capture | R5-VALIDATION | `DishTemplateLexicon.swift:228` DishTemplateLexicon.extractLeadingCount( | Returns any positive Double parsed from the user's typed text ("99999999999999999999 nigiri" -> 1e20). `assemble` (line 203) multiplies `com |
| App-Food-Capture | R5-VALIDATION | `BarcodeServingStepView.swift:80` BarcodeServingStepView.sanitizedServings | Only floors at 0. The `TextField(value:format:)` (129) accepts any magnitude (22 typed digits on the decimal pad -> 1e22), and `scaledMacros |
| App-Food-Recipes | R4-LENGTH | `FoodView.swift:40` FoodView.body | FoodView.body is 245 code lines: header, MacroCard, cooking-resume card, pending-retry card, the per-meal-type 'Today' cards, the five-row r |
| App-Food-Recipes | R4-LENGTH | `FoodView.swift:963` RecipeSheet.recipeContent | RecipeSheet.recipeContent is 166 code lines: title, name/notes fields, the ingredients section (ForEach with expanded/collapsed editors + Ad |
| App-Food-Recipes | R4-LENGTH | `FoodView.swift:1427` RecipeIngredientEditor.body | RecipeIngredientEditor.body is 121 code lines: search/Done/remove header, the typeahead suggestion list (each row a Button with a two-line l |
| App-Food-Recipes | R4-LENGTH | `FoodView.swift:1692` MealSheet.body | MealSheet.body is 152 code lines: the NavigationStack + the seven-case navigationDestination switch, the interactiveDismiss/overlay/animatio |
| App-Food-Recipes | R4-LENGTH | `FoodView.swift:1878` MealSheet.mealContent | MealSheet.mealContent is 111 code lines: title, photo preview + Identify button, description editor, the Capture/Scan/Recent/Import button c |
| App-Food-Recipes | R4-LENGTH | `FoodView.swift:3524` RecipeDetailView.body | RecipeDetailView.body is 91 code lines: the ScrollView content (photo, two notice lines, title block, macros/yield/ingredients/notes/actions |
| App-Food-Recipes | R4-LENGTH | `FoodView.swift:4251` RecipeBookSheet.body | RecipeBookSheet.body is 179 code lines: header, Create button, planner/shopping-list pair, search field, three near-identical card lists (ma |
| App-Home-Companion | R3-GROWTH | `ContentView.swift:116` ContentView.body .onChange(of: lockServi | Every lock-state transition spawns a fresh unstructured `Task { await drainPendingPeriodNarrativesIfUnlocked(newState) }` with no dedupe, an |
| App-Private-Journal-Photos | R4-LENGTH | `DisposableCameraView.swift:1305` DisposableCameraView.infoSheet | infoSheet is 189 code lines — the session-info sheet (rename header, participant count, film count, access picker, roster with heart button  |
| App-Store-Shell | R7-DISCARD | `FernletStore.swift:4396` deleteAllData(includingHealthKitSamples: | `@discardableResult` on `DeleteAllOutcome` — the incomplete-store list is the failure information this whole funnel exists to surface. `Cont |
| App-Store-Shell | R7-DISCARD | `FernletStore.swift:5202` scrubLeakedPastDayJournalsIfNeeded() — ` | `_ =` discards `updateDay`'s `Bool`. If persisting a stripped day fails, its plaintext journal text stays in the (iCloud-synced) blob, yet ` |
| Foundation-Services | R7-DISCARD | `KeychainHelpers.swift:103` KeychainItem.store(_:account:service:acc | `@discardableResult` on a function whose only result is the SecItemAdd `OSStatus` — a pure success/failure signal. Because of it, StoragePre |
| Foundation-Services | R7-DISCARD | `KeychainHelpers.swift:232` KeychainItem.store(_:for:service:) | Same `@discardableResult` on an OSStatus result as line 103; this is the typed overload StoragePreferencesStore.persist and loadOrCreateSymm |
| Foundation-Services | R7-DISCARD | `KeychainHelpers.swift:261` KeychainItem.loadOrCreateSymmetricKey(fo | The freshly minted device journal / Worry Box content key is stored with its OSStatus discarded ('a failed store is silently discarded' per  |
| Lock-Crypto | R7-SWALLOW | `FernletLockService.swift:2254` duressSaltEnsuringPresence() | `try? storeVerified(minted, for: .duressSalt)` swallows the persist of a freshly minted duress salt. On its own the doc calls this best-effo |
| Lock-Crypto | R7-SWALLOW | `FernletLockService.swift:3129` migrateLegacyVerifierIfNeeded(_:computed | `try? storeVerified(FernletLockCrypto.verifierDigest(of: computedVerifier), for: .verifier)` swallows a write to THE passcode gate, then unc |
| Lock-Crypto | R5-VALIDATION | `FernletLockService.swift:1030` FernletLockService.init(...) | The launch-time state is derived from the collapsing read `keychainLoad(.salt) == nil` → `.notConfigured`. `KeychainItem.load` returns nil f |
| Lock-Crypto | R5-VALIDATION | `FernletLockService.swift:1169` configure(credential:grantingScope:) | The public first-time-setup entry point validates the credential but not its precondition — that NO lock exists. `mintLockRecords` deletes t |
| Lock-Crypto | R5-VALIDATION | `FernletLockService.swift:3079` maintainSecureEnclaveWrap(contentKeyData | The 'never overwrite an openable HARD-BOUND blob' guard is only as strong as its read, and both halves collapse failure into absence: `keych |
| Lock-Crypto | R5-VALIDATION | `FernletLockService.swift:2248` duressSaltEnsuringPresence() | Mint-on-nil over a collapsing read: `if let existing = keychainLoad(.duressSalt) { return existing }` treats a FAILED read as 'no salt', min |
| Persistence-Sync | R5-FORCE | `DayRecordRepository.swift:212` DayRecordRepository.dedupedDays(fetching | `let winner = topRows.min { $0.tiebreak < $1.tiebreak }!` force-unwraps the result of a trailing-closure call. SCANNER BLIND SPOT: `FORCE_UN |
| Persistence-Sync | R7-DISCARD | `CoreDataFernletRepository.swift:373` CoreDataFernletRepository.migrateDaysToR | `_ = saveDatabase(migrated)` drops the Bool that says whether the 'migration complete' state (`daysMigratedToRows = true`, `days = [:]`) was |
| Persistence-Sync | R7-DISCARD | `SavedRecipe.swift:178` SavedRecipeRepository.load() / loadAsync | `_ = upsert(migrated)` (line 178 in `load()`, line 197 in `loadAsync()`) discards the write result, and `defaults.set(true, forKey: Self.mig |
| Persistence-Sync | R7-DISCARD | `CoinLedgerService.swift:113` CoinLedgerService.spend(amount:ref:) / r | Two Bool success/failure results carry `@discardableResult`: `spend(amount:ref:)` (attribute 113, declaration 114) returns false when the ba |
| Persistence-Sync | R7-DISCARD | `DiaryStore.swift:1439` DiaryStore.mutateDay(date:_:) / mutatePa | Four Bool success/failure results carry `@discardableResult`: `mutateDay` (attribute 1439, declaration 1440) documents 'Returns: Whether the |
| Persistence-Sync | R7-SWALLOW | `DiaryStore.swift:1470` DiaryStore.mutatePastDay(_:_:) | The ONLY handling of a failed past-day repository write is `assert(saved, "past-date save failed for \(dateKey)")`, which compiles out in Re |
| Persistence-Sync | R3-GROWTH | `CloudKitDataService.swift:462` CloudKitDataService.sealedBackupChunks(p | `head.chunkCount` is an UNVALIDATED CloudKit field: `decodeSealedBackup` reads it as `(record["chunkCount"] as? Int) ?? 1` (line 749) with n |
| PrivateStores | R5-FORCE | `PendingNarrativeStorageScope.swift:50` PendingNarrativeStorageScope.production | `.first!` on `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)` is a silent trap on the production path of t |
| PrivateStores | R7-SWALLOW | `PeriodTrackerStore.swift:540` PeriodTrackerStore.deleteEntry(_:) | `try? narrativeRepository.delete(id: narrative.id)` in the DELETE path. The HealthKit samples are deleted (throwing), the entry is removed f |
| PrivateStores | R7-SWALLOW | `PrivateMediaStore.swift:132` PrivateMediaStore.save(_:) | `try? data.write(to: indexURL, …)` immediately followed (line 133) by `removeOrphanedFiles(keeping: Set(capped.map(\.id)))`. If the index wr |
| PrivateStores | R5-VALIDATION | `PeriodTrackerStore.swift:438` PeriodTrackerStore.loadEntries(unlockedC | `Dictionary(uniqueKeysWithValues: narratives.map { ($0.hkExternalUUID, $0) })` is an uncaught trapping initializer: two `MenstrualNarrative` |
| PrivateStores | R7-DISCARD | `PendingNarrativeBuffer.swift:238` PendingNarrativeBuffer.loadBufferKey() | The v1→v2 buffer-key migration ignores the `OSStatus` of `KeychainItem.store` (line 224, `@discardableResult`) and then UNCONDITIONALLY dele |
| ProximityKit-Engine-Heart | R7-DISCARD | `IdentityService.swift:445` IdentityService.ensureProvisioned() — Ke | Every `KeychainItem.store` OSStatus is implicitly discarded (the helper is @discardableResult). If storing a freshly minted signing/KA priva |
| ProximityKit-Engine-Heart | R7-DISCARD | `IdentityService.swift:644` IdentityService.provisionBackupEscrowKey | The OSStatus of storing the freshly minted escrow key is discarded and `identity.escrow.mintedLocal` is logged regardless. On failure `backu |
| ProximityKit-Mesh-Wire | R5-VALIDATION | `MeshNetworkManager.swift:2170` MeshNetworkManager.handleRemovalSecond(_ | The two-party removal vote is not validated at the boundary: a `MeshRemovalSecondPayload` carries the proposal inline, the proposal is unsig |

## Fix phase

Sixteen fixers (one per slice, each in an isolated worktree, compile-checked against the strict build) then three sequential cross-slice follow-ups. Result: **scanner 0 violations across 366 files**, strict build-for-testing green (warnings as errors, package warnings un-suppressed), full `FernletTests` green, doc coverage 0, allowlist = 12 reasoned entries.

| Slice | Fixed | Refuted | Allowlisted | Left for cross-slice | Files |
|---|---|---|---|---|---|
| App-Food-Capture | 34 | 3 | 0 | 2 | 12 |
| App-Home-Companion | 38 | 13 | 0 | 5 | 11 |
| App-Settings-Privacy | 28 | 4 | 0 | 4 | 6 |
| App-Private-Journal-Photos | 48 | 3 | 1 | 0 | 16 |
| App-Food-Recipes | 29 | 0 | 0 | 3 | 5 |
| App-Duress-Backup-Social | 36 | 0 | 0 | 3 | 15 |
| App-Move-Coach | 39 | 4 | 0 | 2 | 13 |
| App-Store-Shell | 30 | 1 | 0 | 7 | 17 |
| FernletDomainModel | 32 | 5 | 0 | 4 | 16 |
| Lock-Crypto | 32 | 4 | 2 | 5 | 9 |
| PrivateStores | 45 | 7 | 3 | 6 | 17 |
| Persistence-Sync | 56 | 5 | 1 | 11 | 27 |
| ProximityKit-Engine-Heart | 43 | 3 | 0 | 8 | 21 |
| Foundation-Services | 25 | 7 | 3 | 6 | 21 |
| AI-UI-Extensions | 21 | 6 | 1 | 3 | 13 |
| ProximityKit-Mesh-Wire | 32 | 0 | 4 | 3 | 12 |
| **Total** | **568** | **65** | 15 (→ 12 after follow-ups) | 72 | — |

Fixes by rule (per-slice phase): R7-SWALLOW 143, R4-LENGTH 96, R7-DISCARD 85, R5-VALIDATION 76, R3-GROWTH 69, R9-UNSAFE 30, R5-FORCE 21, R6-SCOPE 12, R1-RECURSION 8, R2-BOUND 6, R5-TRAP 4, R6 4, R6-STATIC-VAR 4, R2-WHILE-TRUE 3, R10 2, R2-WHILE 2, R7 1, R8-IF-NEST 1, R1 1.

### Cross-slice follow-ups (three sequential agents on the merged tree)

**Follow-up 1** — 19 fixed, 6 deliberately left, 60 files. Fixed the DuressRecoveryTests regression from the merge and worked the R7 cross-slice queue: removed @discardableResult from every success/failure-signal API named in the brief (plus the ones the advisory listed whose result is Bool/Result/OSStatus/optional-error) and made every caller consume the value — guard/if with a FernletAuditLog "<area>.<op>.failed" line and a recovery in shipping code, #expect/XCTAssert in tests.

**Follow-up 2** — 17 fixed, 4 deliberately left, 29 files. All 13 cross-slice Power-of-10 items addressed in the main working tree.

**Follow-up 3** — 6 fixed, 7 deliberately left, 6 files. Three cross-slice Power-of-10 items fixed in the main working tree.

Highlights (the ProximityCoordinator fan-out item was reverted, see Residuals): every `@discardableResult` on a Bool/Result/OSStatus/optional-error signal is gone and its callers consume the value (delete-everything now names a surviving stress sidecar and a surviving widget run-state file; a sustained heart-drop fetch outage surfaces as `DeliveryProblem.incomingUnreachable`); the byte-format twins agree on caps and eviction ends (widget pending actions 512/refuse, shared-recipe queue 100/oldest-out); `PeriodTrackerStore.loadEntries` re-checks visibility and the live key after its HealthKit await; `isVisible`/`duressPurgeHook`/`isAdultVerified` are `private(set)` behind attach seams; `PersistenceController.shared` is `@MainActor`; the CryptoKit `SymmetricKey→Data` idiom is one documented `rawBytes` helper.

### Integration notes

- Two 3-way merge conflicts (`ProtectedSidecar.retryLoad` Void vs Bool; `WorkoutModels` `Mutex` vs `NSLock`) resolved toward the fixers' versions; two merge interactions fixed by hand (`biometricPromptTimeout` needed `nonisolated`; a test had to assert `SharedRecipeImportQueue.clear()`'s new Bool).
- **HealthKit lesson:** an `HKAnchoredObjectQuery` with both a `limit` and an `updateHandler` throws `NSInvalidArgumentException` — the R3 batch cap a fixer added crashed the test runner seven times, and every 'failing' suite in that run was a casualty. Restored `HKObjectQueryNoLimit`; the correct bounded design (paginate the first-run backfill with limited one-shot queries, then attach the unlimited update query) is a residual below.
- `configure(credential:)` now refuses to mint over an existing lock (a re-mint orphans the sealed corpus's only content key); the one test that modelled that operation now asserts the refusal and the reset-then-configure sweep.

### Residuals (tracked, not silent)

- R3 — `ProximityCoordinator` still spawns one `Task { @MainActor }` per Combine event (inbound message, transport state, UWB distance, ranging state). Follow-up 3 replaced this with one long-lived consumer per stream over a bounded FIFO (`ProximityEventQueue`, caps 256/64/32/16, cancelled in `deinit`, overflow audited) — green alone, but the extra wake-up hop made 12 `ProximityCoordinatorTests`/`CoachSessionHardeningTests` expectations time out under full-suite load, so it was reverted at the capstone. The draft is preserved (session scratchpad `ProximityCoordinator.bounded-fifo.swift`) and the description above is the design to land together with deadline-based test waits (see memory: wall-clock deadlines vs MainActor starvation).
- R3 — HealthKit first-run backfill is bounded only by the 30-day window predicate; paginated one-shot backfill before the update query is the follow-up (`HealthKitService.startAnchoredQuery`).
- R3 — `ModerationLedger` per-reporter quota is a moderation-semantics decision (total and per-delivery caps are in place).
- R7 — value-returning `@discardableResult`s (Meal/Recipe/UUID/Data results, fluent wrappers) stay, each with a doc note on why the discard is safe; `_ =` discards in shipping code were reviewed, the two security-relevant ones carry fail-closed rationales.
- R5 — the density floor is a repo-wide ratchet (now 0.68; achieved 0.686); view-heavy slices sit below it individually by design.
- The 12 allowlist entries: CryptoKit/Security/SQLite/Compression/Core Data/MC/NI/ActivityKit seams (R9), the two unreachable `init(coder:)` traps (R5), and the process-global HealthKit cache-clearer registry (R6) — each with its invariant in `Scripts/power-of-10-allowlist.json`.

