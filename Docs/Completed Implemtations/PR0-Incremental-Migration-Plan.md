# PR 0 — `@Observable` Migration: Incremental Per-File Plan

**Context.** A prior attempt to migrate all 13 `ObservableObject` classes in one pass broke multiple files. Some had to be recreated from scratch. This plan rebuilds PR 0 as 13 small, independently verifiable steps, with explicit integration checkpoints between batches.

**Anchor document.** This plan assumes the `@Observable Migration Audit` you produced (the one inventorying all 13 classes, 9 `@StateObject` sites, 30+ `@ObservedObject` sites, 12 `@EnvironmentObject` sites, 13 `.environmentObject()` sites, and the four §3–§6 special-concern sections). Each prompt references audit findings inline so the assistant doesn't need to consult it directly.

**Implementation status (2026-05-26).** PR 0 has been implemented in production code. The app target is Observation-native: no production-code `ObservableObject`, `@Published`, `@ObservedObject`, `@StateObject`, `@EnvironmentObject`, or `.environmentObject(` references remain under `Fernlet/Fernlet`. `FernletStore` is now `@MainActor @Observable`; its former published state remains tracked; repository/task/bookkeeping fields are `@ObservationIgnored`; and the Combine `remoteChangeSubject` `.sink` subscription remains intact through `cancellables`.

**Verification status (2026-05-26).** The project builds cleanly with zero warnings. Non-UI tests passed in focused batches: 334 passed, 3 HealthKit environment-dependent skips, 0 failures. The full UI-test batch hit a simulator/debugger attach interruption; the two UI assertions surfaced afterward passed when rerun individually. Manual smoke testing, optional two-device iCloud sync, tagging, and PR creation remain final release tasks.

---

## 1. Operating Principles

These are non-negotiable rules for the human running this plan:

1. **One step = one class.** Never combine steps. If a step finishes in 5 minutes, that's fine — move to the next one.
2. **One commit per step.** Commit message format: `PR 0 step N: migrate <ClassName> to @Observable`. Easy bisection if something breaks.
3. **Build between steps.** After every step, the project must build clean. If it doesn't, revert the commit and try again with a tighter prompt.
4. **Don't proceed past a failing checkpoint.** Integration checkpoints A, B, and C are gates. If they fail, fix before moving on.
5. **The assistant must list files before writing.** Every prompt ends with a process clause requiring the assistant to enumerate intended changes and pause for confirmation. If it skips this, stop it.
6. **Scope is tight.** Each prompt names exactly which files are in scope. If the assistant proposes touching anything else, push back.

---

## 2. Sequencing

The order minimizes risk by tackling leaf classes first (small blast radius) and building up to the critical infrastructure (`FernletLockService`, `FernletStore`). Three integration checkpoints split the work into natural batches.

**Batch 1 — Leaf classes (build confidence):**
- Step 0: Pre-flight verification
- Step 1: `TrainerProximityService` (trivial — declaration only)
- Step 2: `HealthKitAuthorizationViewModel`
- Step 3: `StoragePreferencesStore`
- Step 4: `OnboardingCoordinatorModel`
- Step 5: `PeriodTrackerStore`
- **Checkpoint A** — onboarding, settings, period tracker smoke test

**Batch 2 — Proximity stack (special concerns §3, §5):**
- Step 6: `FriendPhotoSharingService` (deletes the `objectWillChange` forwarding — §5)
- Step 7: `ConnectionInspector`
- Step 8: `ProximityCoordinator` (Combine `.sink` subscriptions stay — §3)
- **Checkpoint B** — proximity / mesh smoke test

**Batch 3 — Core infrastructure (most critical):**
- Step 9: `PersistenceController` (Combine infrastructure stays — §3)
- Step 10: `FernletLockService` (CRITICAL — `statePublisher` rework — §4)
- Step 11: `LaunchPreparationService`
- Step 12: `FernletStoreLoader`
- Step 13: `FernletStore` (the big one, 22 properties)
- **Checkpoint C** — full app smoke test, no `ObservableObject` survivors

---

## 3. Per-Step Verification Pattern

Every step ends with the same verification block:

```
1. Build the project (clean build for safety: ⌘+Shift+K then ⌘+B).
2. Search for forbidden tokens in the migrated file:
     grep -n "ObservableObject\|@Published\|@StateObject\|@ObservedObject\|@EnvironmentObject" <file>
   The only matches permitted in this file after migration are inside CryptoSwift
   or comments. Note: `import Combine` may remain if the file uses other Combine API.
3. Run focused tests (specified per step).
4. If something fails: git reset --hard HEAD, retry with a tighter prompt.
```

---

## 4. The Steps

---

### Step 0 — Pre-flight verification

**Purpose:** Ensure the baseline is clean before starting. The previous attempt may have left partial changes. This step is human-driven, no AI assistance needed.

**Checklist:**
- [ ] `git status` shows a clean working tree.
- [ ] You are on a fresh branch: `git checkout -b refactor/observable-migration` (or similar).
- [ ] The project builds clean: ⌘+Shift+K, then ⌘+B. Zero errors, zero warnings related to observation.
- [ ] The full test suite passes: run all targets in Xcode (⌘+U).
- [ ] You have the `@Observable Migration Audit` document open for reference.
- [ ] Take a baseline snapshot of warnings count and test runtime. These should not regress.

If any of the above fails, fix it before proceeding. **Do not start the migration on top of a broken baseline.**

---

### Step 1 — `TrainerProximityService`

**Why first:** Trivial. Zero `@Published`, declaration-only conformance, no view observes it. Builds confidence in the workflow.

**Prompt:**

```
You are migrating a single class from ObservableObject to @Observable. This is
Step 1 of a 13-step PR 0 migration. The class is trivial — declaration-only
conformance with no @Published properties.

SCOPE (do not touch any other file)
  Modify: Fernlet/Fernlet/Proximity/TrainerProximityService.swift

CHANGES
1. Locate the class declaration at line 5:
       final class TrainerProximityService: ObservableObject { ... }
2. Replace with:
       @MainActor
       @Observable
       final class TrainerProximityService { ... }
   (Preserve the existing @MainActor if present; if absent, add it.)
3. Remove `import Combine` if and only if the file has no other Combine usage.
   Search the file for: AnyCancellable, PassthroughSubject, .sink, AnyPublisher,
   Just, Publishers. If none appear, remove the import.

NOT IN SCOPE
- No view files.
- No other class.
- No behavior changes.

PROCESS
1. Read the current file.
2. List the exact changes you plan to make.
3. Wait for confirmation before writing.
4. After writing, confirm the file compiles in isolation by reading it back.

VERIFICATION
The human will: build the project, run grep for ObservableObject in the file
(should return nothing), and run the proximity-related test files in Xcode.
```

**Verification commands:**
```
grep -n "ObservableObject\|@Published" Fernlet/Fernlet/Proximity/TrainerProximityService.swift
# Expected: no matches
```
**Tests to run:** any proximity tests in `FernletTests` (search for `Proximity` or `Trainer` in test target).

---

### Step 2 — `HealthKitAuthorizationViewModel`

**Why second:** 4 `@Published` properties. Used as `@StateObject` in 3 views — each view owns its own instance. Clean migration with view-side changes.

**Prompt:**

```
You are migrating HealthKitAuthorizationViewModel from ObservableObject to
@Observable, along with the 3 views that own instances via @StateObject. This
is Step 2 of a 13-step PR 0 migration.

SCOPE
  Modify (class):
    Fernlet/Fernlet/HealthKitService.swift                   (line 1031)
  Modify (view sites):
    Fernlet/Fernlet/SettingsSheet.swift                      (line 21)
    Fernlet/Fernlet/PeriodTrackerView.swift                  (line 9)
    Fernlet/Fernlet/LogPeriodSheet.swift                     (line 7)

CLASS CHANGES (HealthKitService.swift)
1. At line 1031:
   `final class HealthKitAuthorizationViewModel: ObservableObject {`
   becomes:
   `@MainActor
    @Observable
    final class HealthKitAuthorizationViewModel {`
2. Remove the 4 `@Published` annotations. The properties keep their names,
   types, defaults, and access levels.
3. Mark internal bookkeeping properties with @ObservationIgnored if any read
   would not cause UI re-render. (Examples: Task handles, cached service refs.)
4. If `import Combine` is in the file and no other Combine API is used in the
   file, remove it. Otherwise leave it.

VIEW CHANGES (3 files)
In each of the 3 view files at the listed line, change:
    @StateObject private var <name> = HealthKitAuthorizationViewModel(...)
to:
    @State private var <name> = HealthKitAuthorizationViewModel(...)

The property name and initializer arguments stay identical.

CHECK FOR BINDINGS
Search each of the 3 view files for `$<name>.` (e.g., `$healthKit.`,
`$authorization.`). If any binding exists, the property must be declared as
`@State private var <name>` AND any child view that takes a binding may need
`@Bindable var <name>` at the binding site. Report any bindings found before
making the change.

NOT IN SCOPE
- Any other ObservableObject class.
- Any other view file.
- Behavior changes.

PROCESS
1. Read the class file and 3 view files.
2. Report any $-prefixed bindings you found in the view files.
3. List the exact changes per file. Wait for confirmation.
4. Make changes one file at a time. Confirm each file compiles in isolation.

VERIFICATION
The human will:
- Build the project (must be clean).
- Run grep across the 4 files for the forbidden tokens.
- Run the HealthKit-related tests and the period tracker tests in Xcode.
- Smoke test: open Settings (HealthKit section), open Period Tracker, open Log
  Period sheet. Confirm authorization status reads display correctly.
```

---

### Step 3 — `StoragePreferencesStore`

**Why third:** Single `@Published`, environment-injected, touches 7 view sites — a good test of the `@EnvironmentObject` → `@Environment(T.self)` pattern.

**Prompt:**

```
You are migrating StoragePreferencesStore from ObservableObject to @Observable,
along with all views that observe it. This is Step 3 of a 13-step PR 0 migration.

SCOPE
  Modify (class):
    Fernlet/Fernlet/StoragePreferences.swift                 (line 37)
  Modify (view + injection sites):
    Fernlet/Fernlet/FernletApp.swift                         (line 9, 88, 98, 107)
    Fernlet/Fernlet/ContentView.swift                        (line 15, 238, 254)
    Fernlet/Fernlet/PrivacyDataSettingsView.swift            (line 30, 74)
    Fernlet/Fernlet/OnboardingStorageChoiceView.swift        (line 8)

CLASS CHANGES
1. StoragePreferences.swift line 37:
   `final class StoragePreferencesStore: ObservableObject {`
   becomes:
   `@MainActor
    @Observable
    final class StoragePreferencesStore {`
2. Remove the 1 @Published annotation.
3. Mark immutable infrastructure properties (UserDefaults ref, etc.) with
   @ObservationIgnored.
4. Remove `import Combine` if no other Combine API is used in the file.

VIEW CHANGES
- FernletApp.swift:9 — `@StateObject private var storagePreferencesStore = StoragePreferencesStore(...)`
  becomes `@State private var storagePreferencesStore = StoragePreferencesStore(...)`
- FernletApp.swift:88, 98, 107 — `.environmentObject(storagePreferencesStore)`
  becomes `.environment(storagePreferencesStore)`
- ContentView.swift:15 — `@EnvironmentObject var storagePreferencesStore: StoragePreferencesStore`
  becomes `@Environment(StoragePreferencesStore.self) private var storagePreferencesStore`
- ContentView.swift:238, 254 — `.environmentObject(storagePreferencesStore)`
  becomes `.environment(storagePreferencesStore)`
- PrivacyDataSettingsView.swift:30 — `@EnvironmentObject var storagePreferencesStore: StoragePreferencesStore`
  becomes `@Environment(StoragePreferencesStore.self) private var storagePreferencesStore`
- PrivacyDataSettingsView.swift:74 — `.environmentObject(...)` becomes `.environment(...)`
- OnboardingStorageChoiceView.swift:8 — `@EnvironmentObject var storagePreferencesStore: StoragePreferencesStore`
  becomes `@Environment(StoragePreferencesStore.self) private var storagePreferencesStore`

CHECK FOR BINDINGS
Search the 4 view files for `$storagePreferencesStore.`. If any binding exists,
the view needs `@Bindable var storagePreferencesStore: StoragePreferencesStore`
or you must compute the binding manually. Report findings.

NOT IN SCOPE
- Any other ObservableObject class.
- Any other view file.

PROCESS as in Step 2. List intended changes before writing.

VERIFICATION
- grep across all 5 files for forbidden tokens (none should match).
- Build clean.
- Run any storage-preferences-related tests.
- Smoke test: launch the app, open Privacy & Data settings, toggle iCloud sync,
  confirm the toggle persists and the UI updates.
```

---

### Step 4 — `OnboardingCoordinatorModel`

**Why fourth:** 6 `@Published`, used in one place (`OnboardingCoordinator.swift:107` via `@StateObject`). Self-contained, low blast radius.

**Prompt:**

```
You are migrating OnboardingCoordinatorModel from ObservableObject to @Observable.
This is Step 4 of a 13-step PR 0 migration.

SCOPE
  Modify (class + view, same file):
    Fernlet/Fernlet/OnboardingCoordinator.swift

CHANGES
1. Class at line 47:
   `final class OnboardingCoordinatorModel: ObservableObject { ... }`
   becomes:
   `@MainActor
    @Observable
    final class OnboardingCoordinatorModel { ... }`
2. Remove all 6 @Published annotations.
3. Mark internal bookkeeping with @ObservationIgnored if appropriate.
4. View site at line 107: `@StateObject private var model = OnboardingCoordinatorModel(...)`
   becomes `@State private var model = OnboardingCoordinatorModel(...)`.
5. Remove `import Combine` if no other Combine API is used.

CHECK FOR BINDINGS
Search this file and any onboarding child views for `$model.`. Onboarding is
form-heavy and likely has bindings. For every $model.xxx binding found in a
child view, that child needs `@Bindable var model: OnboardingCoordinatorModel`
declared at its property site.

Files likely to contain child onboarding views — search each for $model:
  - Fernlet/Fernlet/OnboardingView.swift
  - Fernlet/Fernlet/OnboardingPermissionsView.swift
  - Fernlet/Fernlet/OnboardingWelcomeView.swift
  - Fernlet/Fernlet/OnboardingLockSetupView.swift
  - Fernlet/Fernlet/OnboardingStorageChoiceView.swift

Report bindings before making changes. If a child view holds the model as
`@ObservedObject var model: OnboardingCoordinatorModel`, change to:
- `var model: OnboardingCoordinatorModel` if no bindings, OR
- `@Bindable var model: OnboardingCoordinatorModel` if bindings exist.

NOT IN SCOPE
- Any other ObservableObject class.

PROCESS as in Step 2. Pay special attention to listing every binding found.

VERIFICATION
- grep across all touched files.
- Build clean.
- Run any onboarding tests.
- Smoke test: cold launch the app (delete and reinstall, or reset onboarding
  state). Walk through every onboarding screen. Confirm form fields update,
  navigation works, completion flows to the main app.
```

---

### Step 5 — `PeriodTrackerStore`

**Why fifth:** 3 `@Published`, used as `@StateObject` in ContentView and as `@ObservedObject` in 3 views. Last leaf-class step before Checkpoint A.

**Prompt:**

```
You are migrating PeriodTrackerStore from ObservableObject to @Observable.
This is Step 5 of a 13-step PR 0 migration.

SCOPE
  Modify (class):
    Fernlet/Fernlet/PeriodTrackerStore.swift                 (line 213)
  Modify (view sites):
    Fernlet/Fernlet/ContentView.swift                        (line 13)
    Fernlet/Fernlet/PrivateHubView.swift                     (line 16)
    Fernlet/Fernlet/PeriodTrackerView.swift                  (line 5)
    Fernlet/Fernlet/LogPeriodSheet.swift                     (line 4)

CLASS CHANGES
1. PeriodTrackerStore.swift line 213:
   `final class PeriodTrackerStore: ObservableObject {`
   becomes:
   `@MainActor
    @Observable
    final class PeriodTrackerStore {`
2. Remove the 3 @Published annotations.
3. Mark repository / lock-service references and any caches with
   @ObservationIgnored.
4. Remove `import Combine` if no other Combine API is used.

VIEW CHANGES
- ContentView.swift:13 — `@StateObject private var periodStore = PeriodTrackerStore(...)`
  becomes `@State private var periodStore = PeriodTrackerStore(...)`
- PrivateHubView.swift:16 — `@ObservedObject var periodStore: PeriodTrackerStore`
  becomes `var periodStore: PeriodTrackerStore` (or @Bindable if bindings found)
- PeriodTrackerView.swift:5 — same pattern as PrivateHubView
- LogPeriodSheet.swift:4 — same pattern

CHECK FOR BINDINGS
Search each view file for `$periodStore.`. Report findings. If bindings exist
in PeriodTrackerView or LogPeriodSheet (likely — period logging is form-heavy),
those views need `@Bindable var periodStore: PeriodTrackerStore`.

NOT IN SCOPE
- Any other class.
- The lock service is referenced by PeriodTrackerStore but is migrated in
  Step 10 — do not touch FernletLockService here.

PROCESS as in Step 2.

VERIFICATION
- grep across all 5 files.
- Build clean.
- Run PeriodTrackerTests.swift specifically — this is a critical test file
  and must stay green.
- Smoke test: open Period Tracker tab, log a period day, edit a past day,
  confirm predictions update correctly.
```

---

### Checkpoint A — Onboarding, Settings, Period Tracker

**Gate before Batch 2.** Do not proceed if any item fails.

```
□ Full test suite passes (⌘+U on all targets).
□ Project builds clean with zero new warnings.
□ Cold-launch smoke test:
  □ Delete the app from the simulator. Reinstall.
  □ Walk the entire onboarding flow end-to-end.
  □ Confirm storage preference selection persists.
  □ Confirm HealthKit permission prompt appears.
  □ Land on the main app.
□ Settings smoke test:
  □ Open Settings.
  □ Toggle every available option. Confirm UI updates.
  □ Open HealthKit section — confirm authorization status displays correctly.
□ Period Tracker smoke test:
  □ Log today as a period day.
  □ Log a past day as a period day.
  □ Confirm cycle predictions update.
  □ Open Log Period sheet, confirm form fields work.
□ git log shows 5 commits since Step 0, one per step.
□ grep at repo root for forbidden tokens in the 5 migrated classes returns nothing.
```

If checkpoint passes: tag the commit (`git tag pr0-checkpoint-a`) and proceed to Batch 2.

---

### Step 6 — `FriendPhotoSharingService` (CRITICAL: delete forwarding §5)

**Why first in Batch 2:** Has the `objectWillChange` forwarding block that must be deleted. This is the single most important change in the entire PR 0 because it's also a demonstration that `@Observable`'s tracking handles nested observation automatically.

**Prompt:**

```
You are migrating FriendPhotoSharingService from ObservableObject to @Observable.
This step has a CRITICAL deletion: a manual objectWillChange forwarding block
must be removed entirely. This is Step 6 of a 13-step PR 0 migration.

SCOPE
  Modify (class + view, same file):
    Fernlet/Fernlet/Proximity/FriendPhotoShareView.swift

CRITICAL DELETION (§5 of the migration audit)
At approximately lines 101–105, this block exists:

    self.coordinator.objectWillChange
        .sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        .store(in: &cancellables)

This block must be DELETED ENTIRELY. Under @Observable, the Observation framework
tracks nested property reads automatically. When a view reads
`service.isConnected` (which internally reads `coordinator.state`), the view
re-renders when `coordinator.state` changes — no manual forwarding required.

CLASS CHANGES
1. Line 69:
   `final class FriendPhotoSharingService: ObservableObject, ProximityPayloadHandling {`
   becomes:
   `@MainActor
    @Observable
    final class FriendPhotoSharingService: ProximityPayloadHandling {`
2. Remove the 2 @Published annotations.
3. DELETE the objectWillChange forwarding block (lines ~101–105).
4. DELETE the `cancellables` set declaration (it was only used by the forwarding).
5. The `coordinator: ProximityCoordinator` reference stays — but it must be
   marked @ObservationIgnored because the coordinator itself will be migrated
   to @Observable in Step 8 and you don't want to over-trigger.
   Actually: since coordinator IS read by computed properties (isConnected,
   statusText) and we WANT those reads to be tracked, do NOT mark coordinator
   @ObservationIgnored. Leave it as a plain property.
6. Remove `import Combine` from the file.

VIEW CHANGES (same file)
- Line 319: `@ObservedObject var service: FriendPhotoSharingService` becomes
  `var service: FriendPhotoSharingService` (or @Bindable if needed)
- Line 323: `@StateObject private var service = FriendPhotoSharingService(...)`
  becomes `@State private var service = FriendPhotoSharingService(...)`

CHECK FOR BINDINGS
Search for `$service.` in the file. Report findings.

NOT IN SCOPE
- ProximityCoordinator (Step 8).
- TrainerProximityService (already done in Step 1).
- Any other file.

PROCESS as in Step 2. Confirm the forwarding-block deletion explicitly before
writing.

VERIFICATION
- grep in the file for: ObservableObject, @Published, objectWillChange,
  cancellables, "import Combine". All should return nothing.
- Build clean.
- Run any photo-sharing tests.
- Smoke test (defer to Checkpoint B for the full proximity test).
```

---

### Step 7 — `ConnectionInspector`

**Why now:** Self-contained. 2 `@Published`. Conforms to `ProximityInspectorRecording` (plain protocol, not observation-related). Two view consumers.

**Prompt:**

```
You are migrating ConnectionInspector from ObservableObject to @Observable.
This is Step 7 of a 13-step PR 0 migration.

SCOPE
  Modify (class):
    Fernlet/Fernlet/Proximity/ConnectionInspector.swift      (line 6)
  Modify (view sites):
    Fernlet/Fernlet/Proximity/ConnectionInspectorView.swift  (line 4)
    Fernlet/Fernlet/Proximity/ConnectionInspectorHistoryView.swift (line 7)

CLASS CHANGES
1. Line 6:
   `final class ConnectionInspector: ObservableObject, ProximityInspectorRecording {`
   becomes:
   `@MainActor
    @Observable
    final class ConnectionInspector: ProximityInspectorRecording {`
2. Remove the 2 @Published annotations.
3. The `weak var store: FernletStore?` back-reference must be marked
   @ObservationIgnored — it's an internal back-ref, not view-observed state.
   IMPORTANT: FernletStore is still ObservableObject at this point in the
   migration. The weak ref's type does not change here. Just add the attribute.
4. Mark any other internal bookkeeping with @ObservationIgnored.
5. Remove `import Combine` if no other Combine API is used.

VIEW CHANGES
- ConnectionInspectorView.swift:4 — `@ObservedObject var inspector: ConnectionInspector`
  becomes `var inspector: ConnectionInspector` (or @Bindable if needed)
- ConnectionInspectorHistoryView.swift:7 — same pattern

CHECK FOR BINDINGS
Search the 2 view files for `$inspector.`. Report findings.

NOT IN SCOPE
- FernletStore (still ObservableObject; migrated in Step 13).
- Any proximity transport classes.

PROCESS as in Step 2.

VERIFICATION
- grep the 3 files.
- Build clean.
- Smoke test: open the Connection Inspector from settings or wherever it's
  accessible. Confirm it displays current session and historical logs.
```

---

### Step 8 — `ProximityCoordinator` (Combine stays §3)

**Why now:** Has 4 `.sink` subscriptions on transport publishers that **must not be touched**. This step is mostly about not breaking the Combine infrastructure while still migrating the observation layer.

**Prompt:**

```
You are migrating ProximityCoordinator from ObservableObject to @Observable.
This class uses Combine for transport/ranging publisher subscriptions, which
must be preserved. This is Step 8 of a 13-step PR 0 migration.

SCOPE
  Modify (class only — no direct view observation):
    Fernlet/Fernlet/Proximity/ProximityCoordinator.swift     (line 67)

CRITICAL PRESERVATION (§3 of the migration audit)
This file contains 4 Combine .sink subscriptions in `subscribeToTransport()`
and `subscribeToRanging()`. These subscribe to MultipeerSession and
NIRangingSession publishers — NOT to ObservableObject types. The Combine
pipeline is intentional design. PRESERVE:
- The cancellables Set<AnyCancellable>
- All 4 .sink subscriptions
- The `import Combine` at the top of the file
- The transport and ranging publisher types

Only the ObservableObject conformance and @Published annotations on the
coordinator's own state are migrated.

CLASS CHANGES
1. Line 67:
   `final class ProximityCoordinator: ObservableObject { ... }`
   becomes:
   `@MainActor
    @Observable
    final class ProximityCoordinator { ... }`
2. Remove the 2 @Published annotations on the coordinator's own state
   (likely `state` and one other — confirm from the file).
3. Mark @ObservationIgnored on:
   - The transport reference (MultipeerSession or similar)
   - The ranging session reference
   - The cancellables Set (it's bookkeeping)
   - Any trustPolicy weak reference
   - Any other infrastructure ref
4. DO NOT remove `import Combine`.
5. DO NOT touch the .sink subscriptions or their handlers.

VIEW CHANGES
None. ProximityCoordinator is held by FriendPhotoSharingService (already
migrated in Step 6) and TrainerProximityService (already migrated in Step 1).
No view observes it directly.

NOT IN SCOPE
- Transport or ranging session classes (these are not ObservableObject).
- Any view file.

PROCESS
1. Read the entire ProximityCoordinator.swift file.
2. List every property, classifying each as: (a) observation-tracked,
   (b) @ObservationIgnored, (c) preserved Combine infrastructure.
3. Confirm the 4 .sink blocks will be preserved unchanged.
4. Wait for confirmation before writing.

VERIFICATION
- grep for: ObservableObject (none), @Published (none).
- grep for: .sink, cancellables, AnyCancellable. ALL should still be present.
- Build clean.
- Smoke test deferred to Checkpoint B.
```

---

### Checkpoint B — Proximity / Mesh

**Gate before Batch 3.** Critical because the user's next workstream is the mesh implementation; this baseline must be solid.

```
□ Full test suite passes.
□ Project builds clean.
□ Proximity smoke test (best done with two physical devices, but simulator
  with mock proximity is acceptable):
  □ Open the Connection Inspector — confirm it loads.
  □ Initiate a friend-photo share flow if reachable from the UI.
  □ Confirm coordinator state updates flow through to UI (this is the
    objectWillChange-forwarding deletion working).
  □ If mesh is reachable from the UI, attempt a peer discovery and connection.
□ Verify §3 preservation: open ProximityCoordinator.swift, confirm the
  4 .sink subscriptions and cancellables set still exist.
□ git tag pr0-checkpoint-b
```

---

### Step 9 — `PersistenceController` (Combine infrastructure stays §3)

**Why first in Batch 3:** Standalone. Has 1 `@Published` (`isReloading`) but also exposes a Combine `remoteChangePublisher` used by `CoreDataFernletRepository`. Combine stays.

**Prompt:**

```
You are migrating PersistenceController from ObservableObject to @Observable.
This file uses Combine for notification bridging which must be preserved.
This is Step 9 of a 13-step PR 0 migration.

SCOPE
  Modify (class):
    Fernlet/Fernlet/Persistence.swift                        (line 12)

CRITICAL PRESERVATION (§3 of the migration audit)
This file owns `remoteChangePublisher: AnyPublisher<..., Never>` and a
`remoteChangeSubject: PassthroughSubject<..., Never>` used by
CoreDataFernletRepository. PRESERVE:
- remoteChangePublisher
- remoteChangeSubject
- Any AnyCancellable
- NotificationCenter subscription bridging into the subject
- `import Combine`

CLASS CHANGES
1. Line 12:
   `final class PersistenceController: ObservableObject {`
   becomes:
   `@Observable
    final class PersistenceController {`
   (No @MainActor unless it currently has one — match existing.)
2. Remove the @Published annotation on `isReloading`.
3. Mark @ObservationIgnored on:
   - container (NSPersistentContainer or similar)
   - remoteChangeSubject
   - remoteChangePublisher
   - Any cancellable
   - Any internal queue / actor reference
4. DO NOT remove `import Combine`.

VIEW CHANGES
None. PersistenceController is not observed by any view directly. It's used
internally by the repository layer.

PROCESS as in Step 8.

VERIFICATION
- grep for ObservableObject, @Published (none).
- grep for remoteChangePublisher, remoteChangeSubject (must still be present).
- Build clean.
- Run FernletPersistenceTests specifically.
```

---

### Step 10 — `FernletLockService` (CRITICAL §4: statePublisher rework)

**Why now:** Has the single most subtle migration in PR 0. The `FernletLockServicing` protocol declares `statePublisher: AnyPublisher<FernletLockState, Never>`. Currently implemented via `$state.eraseToAnyPublisher()`. Under `@Observable`, `$state` doesn't exist. The fix is a `PassthroughSubject` + `didSet` pattern — protocol and `MockLockService` stay unchanged.

**Prompt:**

```
You are migrating FernletLockService from ObservableObject to @Observable.
This step has a CRITICAL protocol-implementation rework: the existing
statePublisher implementation depends on @Published's projected value ($state)
which does not exist under @Observable. The fix is a PassthroughSubject pattern.
This is Step 10 of a 13-step PR 0 migration.

SCOPE
  Modify (class):
    Fernlet/Fernlet/FernletLockService.swift                 (line ~408–417)
  Modify (view + injection sites):
    Fernlet/Fernlet/FernletApp.swift                         (line 8, 87, 97, 106)
    Fernlet/Fernlet/ContentView.swift                        (line 14, 237)
    Fernlet/Fernlet/SettingsSheet.swift                      (line 12, 1252, 1556, 106, 110, 112, 1284, 1288)
    Fernlet/Fernlet/FernletLockView.swift                    (line 15, 389)
    Fernlet/Fernlet/FernletLockGate.swift                    (line 23, 57, 128)
    Fernlet/Fernlet/PrivacyDataSettingsView.swift            (line 29)
    Fernlet/Fernlet/PeriodTrackerView.swift                  (line 8)
    Fernlet/Fernlet/LogPeriodSheet.swift                     (line 5)
  Modify (test):
    Fernlet/FernletTests/FernletLockTests.swift              (line 416, 423, 455)

DO NOT MODIFY
- The FernletLockServicing protocol declaration.
- MockLockService in PeriodTrackerTests.swift — it implements statePublisher
  via Just(state).eraseToAnyPublisher() and is unaffected.

CRITICAL CLASS CHANGES (§4 of the migration audit)

Current code (approximate):
    final class FernletLockService: ObservableObject, FernletLockServicing {
        @Published var state: FernletLockState = .notConfigured
        @Published var isLocked: Bool = false
        @Published var lastError: ...

        var statePublisher: AnyPublisher<FernletLockState, Never> {
            $state.eraseToAnyPublisher()
        }
        ...
    }

New code:
    @MainActor
    @Observable
    final class FernletLockService: FernletLockServicing {
        @ObservationIgnored
        private let stateSubject = PassthroughSubject<FernletLockState, Never>()

        var state: FernletLockState = .notConfigured {
            didSet { stateSubject.send(state) }
        }
        var isLocked: Bool = false
        var lastError: ...

        var statePublisher: AnyPublisher<FernletLockState, Never> {
            stateSubject.eraseToAnyPublisher()
        }
        ...
    }

KEY POINTS
- The `stateSubject` is @ObservationIgnored because it's infrastructure, not
  view-observed state.
- The didSet on `state` fires the subject. This preserves the exact semantic
  of the old $state.eraseToAnyPublisher() — every state change emits.
- Existing semantics for initial value: the old $state would NOT emit the
  initial value on subscription (PassthroughSubject doesn't either). So the
  behavior is identical.
- DO NOT remove `import Combine`. The file still uses PassthroughSubject and
  AnyPublisher.
- Mark @ObservationIgnored on: stateSubject, any keychain helpers, any internal
  task handles.

VIEW CHANGES
- FernletApp.swift:8 — `@StateObject private var lockService = FernletLockService(...)`
  becomes `@State private var lockService = FernletLockService(...)`
- FernletApp.swift:87, 97, 106 — `.environmentObject(lockService)` → `.environment(lockService)`
- ContentView.swift:14 — `@EnvironmentObject var lockService: FernletLockService`
  becomes `@Environment(FernletLockService.self) private var lockService`
- ContentView.swift:237 — `.environmentObject(...)` → `.environment(...)`
- SettingsSheet.swift:12 — same @EnvironmentObject → @Environment pattern
- SettingsSheet.swift:1252, 1556 — same pattern (these may be in nested views)
- SettingsSheet.swift:106, 110, 112, 1284, 1288 — these are .environmentObject sites → .environment
- FernletLockView.swift:15, 389 — @EnvironmentObject → @Environment
- FernletLockGate.swift:23 — @EnvironmentObject → @Environment
- FernletLockGate.swift:57, 128 — .environmentObject → .environment
- PrivacyDataSettingsView.swift:29 — @EnvironmentObject → @Environment
- PeriodTrackerView.swift:8 — @EnvironmentObject → @Environment
- LogPeriodSheet.swift:5 — @EnvironmentObject → @Environment

CHECK FOR BINDINGS
Search every view file for `$lockService.`. Report findings. If any view uses
$lockService.x, it needs `@Bindable` instead of @Environment, but @Environment
in iOS 17+ supports bindings via @Bindable on the property — confirm syntax in
that case.

TEST CHANGES
FernletLockTests.swift uses UIHostingController + .environmentObject(service)
at lines 416, 423, 455. Change each to .environment(service).

PROCESS
1. Read FernletLockService.swift in full.
2. Confirm the statePublisher rework plan (PassthroughSubject + didSet).
3. List every view file change with the exact line.
4. List the test file changes.
5. Wait for confirmation. DO NOT proceed without it.
6. Migrate the class first. Build. Verify.
7. Migrate view files one at a time. Build after each.
8. Migrate the test file. Run the lock tests.

VERIFICATION
- grep in FernletLockService.swift for: @Published (none), ObservableObject (none).
- grep for: PassthroughSubject, AnyPublisher, statePublisher (all present).
- Build clean.
- Run FernletLockTests.swift specifically — every test must pass.
- Smoke test:
  - Lock the app from Settings.
  - Confirm the lock screen appears.
  - Unlock with the configured method.
  - Confirm the gate releases and the main app appears.
  - Toggle settings that depend on lock state.
```

---

### Step 11 — `LaunchPreparationService`

**Why now:** 2 `@Published`. One view site (`ContentView`). Trivial after the foundation is laid.

**Prompt:**

```
You are migrating LaunchPreparationService from ObservableObject to @Observable.
This is Step 11 of a 13-step PR 0 migration.

SCOPE
  Modify (class):
    Fernlet/Fernlet/LaunchPreparationService.swift           (line 20)
  Modify (view):
    Fernlet/Fernlet/ContentView.swift                        (line 12)

CLASS CHANGES
1. Line 20:
   `final class LaunchPreparationService: ObservableObject {`
   becomes:
   `@MainActor
    @Observable
    final class LaunchPreparationService {`
2. Remove the 2 @Published annotations.
3. Mark internal task handles, store references, defaults references as
   @ObservationIgnored.
4. Remove `import Combine` if no other Combine API is used in the file.

VIEW CHANGES
- ContentView.swift:12 — `@StateObject private var launcher = LaunchPreparationService(...)`
  becomes `@State private var launcher = LaunchPreparationService(...)`

CHECK FOR BINDINGS
Search ContentView.swift for `$launcher.`. Report findings.

PROCESS as in Step 2.

VERIFICATION
- grep the 2 files.
- Build clean.
- Smoke test: cold launch the app. Confirm the launch progress UI displays
  correctly and transitions to the main app.
```

---

### Step 12 — `FernletStoreLoader`

**Why now:** Penultimate step. Wraps `FernletStore` (still `ObservableObject` until Step 13 — that's fine, types nest cleanly).

**Prompt:**

```
You are migrating FernletStoreLoader from ObservableObject to @Observable.
This is Step 12 of a 13-step PR 0 migration. Note: FernletStore is migrated in
the NEXT step (13), not this one.

SCOPE
  Modify (class):
    Fernlet/Fernlet/FernletStoreLoader.swift                 (line 5)
  Modify (view):
    Fernlet/Fernlet/FernletApp.swift                         (line 10)

CLASS CHANGES
1. Line 5:
   `final class FernletStoreLoader: ObservableObject {`
   becomes:
   `@MainActor
    @Observable
    final class FernletStoreLoader {`
2. Remove the 2 @Published annotations (likely `store` and a loading/status
   property).
3. The `store: FernletStore?` property: do NOT mark @ObservationIgnored.
   Views reading `loader.store?.something` need this property tracked so they
   re-render when the loader sets the store.
4. Mark internal task handles, repository references, and the lock-service
   reference as @ObservationIgnored.
5. Remove `import Combine` if no other Combine API is used.

VIEW CHANGES
- FernletApp.swift:10 — `@StateObject private var loader = FernletStoreLoader(...)`
  becomes `@State private var loader = FernletStoreLoader(...)`

NOTE ON FERNLETSTORE
FernletStore is still ObservableObject at this point. That's fine — the
loader's `store: FernletStore?` property is observed by the @Observable
machinery, and FernletStore's own changes are still observed by views that
hold it via @ObservedObject (until Step 13). The two coexist.

CHECK FOR BINDINGS
Search FernletApp.swift for `$loader.`. Report findings.

PROCESS as in Step 2.

VERIFICATION
- grep the 2 files.
- Build clean.
- Smoke test: cold launch the app. Confirm the store loads and the main UI
  appears.
```

---

### Step 13 — `FernletStore` (the big one)

**Why last:** 22 `@Published`, observed by ~20 view files, conforms to `ProximityTrustPolicy`, holds a `.sink` subscription on `remoteChangeSubject` that must stay. This is the step most likely to bite. The previous failed attempt almost certainly broke things here.

**Prompt:**

```
You are migrating FernletStore from ObservableObject to @Observable. This is
the final and largest step of PR 0 (13 of 13). FernletStore has 22 @Published
properties and is observed by approximately 20 view files. It also has a
Combine .sink subscription on remoteChangeSubject that MUST be preserved.

SCOPE — CLASS
  Modify: Fernlet/Fernlet/FernletStore.swift                 (line 6)

SCOPE — VIEW FILES (per the migration audit)
  ContentView.swift:11, 333, 460
  FoodView.swift:8, 256, 405, 516, 1042, 1308, 1416
  MoveView.swift:4, 66, 326, 410, 1033, 1097
  JournalView.swift:4, 95, 311, 664, 1103
  HomeView.swift:5, 793
  SharedSheets.swift:5, 58, 137, 204, 256
  SettingsSheet.swift:11, 1166
  PrivateHubView.swift:15
  PeriodTrackerView.swift:4
  OnboardingView.swift:4
  SocialHubView.swift:11
  WorkshopView.swift:4

CRITICAL PRESERVATION (§3 of the migration audit)
FernletStore's `subscribeToRemoteChangesIfNeeded()` method subscribes to
`CoreDataFernletRepository.remoteChangeSubject` via .sink. This subscription
is Combine infrastructure, NOT observation. PRESERVE:
- cancellables (Set<AnyCancellable>)
- The .sink block subscribing to remoteChangeSubject
- `import Combine`

CLASS CHANGES
1. Line 6:
   `final class FernletStore: ObservableObject {`
   becomes:
   `@MainActor
    @Observable
    final class FernletStore {`
2. Remove ALL 22 @Published annotations.
3. Mark @ObservationIgnored on every property that is internal bookkeeping
   or infrastructure. AT MINIMUM:
   - repository (FernletRepository)
   - savedRecipeRepository (SavedRecipeRepository)
   - healthKitService ((any HealthKitServicing)?)
   - todayKey (let)
   - cancellables (Set<AnyCancellable>)
   - snapshotSaveTask (Task)
   - remoteReloadTask (Task)
   - savedRecipeSaveScheduled (Bool flag)
   - bundledFoodSeedSavePending (Bool flag)
   - launchScreenDismissed (Bool flag)
   - deferredPostLaunchTasksStarted (Bool flag)
   - isReloadingFromRepository (Bool flag)
   - Any other Bool flag, Task, Cancellable, or repository ref
4. Do NOT mark @ObservationIgnored on any of the 22 properties that were
   @Published — these must remain observation-tracked.
5. DO NOT remove `import Combine`.

VIEW CHANGES PATTERN
For every @ObservedObject site listed above:
- `@ObservedObject var store: FernletStore` becomes:
  - `var store: FernletStore` if no $store. bindings exist in this view
  - `@Bindable var store: FernletStore` if any $store. bindings exist

CHECK FOR BINDINGS — REQUIRED BEFORE ANY VIEW IS MODIFIED
Run a global search: `grep -rn "\$store\." Fernlet/Fernlet/`
Report every match. Every file that contains `$store.<anything>` MUST use
`@Bindable var store: FernletStore`. Settings-related views (SettingsSheet,
OnboardingView, SharedSheets) are highly likely to have bindings. Confirm
with a complete list before making any view change.

PROCESS — MANDATORY GRANULARITY
This step has previously failed when attempted as a single sweep. You MUST
follow this sequence:

1. Read FernletStore.swift in full. Catalog every property by category:
   (a) was @Published → keep tracked, remove the @Published annotation
   (b) infrastructure → mark @ObservationIgnored
   (c) preserved Combine → mark @ObservationIgnored (cancellables, tasks)
2. Run the global $store. binding search. Report findings.
3. Output a complete migration plan listing:
   - The class declaration change.
   - Every property and its disposition (a/b/c).
   - Every view file with its line number and the new attribute.
   - Confirmation that the .sink subscription on remoteChangeSubject is preserved.
4. WAIT for confirmation from the human before writing any code.
5. After confirmation, modify FernletStore.swift FIRST. Build. Verify
   compilation. If it doesn't build, STOP and report what's wrong.
6. Modify view files ONE FILE AT A TIME, in this order:
   a. SharedSheets.swift (heavy bindings, do first to flush out @Bindable issues)
   b. SettingsSheet.swift (heavy bindings)
   c. OnboardingView.swift
   d. ContentView.swift
   e. HomeView.swift
   f. FoodView.swift
   g. MoveView.swift
   h. JournalView.swift
   i. PrivateHubView.swift
   j. PeriodTrackerView.swift
   k. SocialHubView.swift
   l. WorkshopView.swift
7. After each view file: confirm it compiles in isolation before moving on.
   If a file fails to compile, STOP. Do not move to the next file.

VERIFICATION
- grep in FernletStore.swift:
    - ObservableObject (none)
    - @Published (none)
    - cancellables, .sink, AnyCancellable (all present)
- grep across the entire codebase:
    - @ObservedObject (only matches should be in CryptoSwift or comments)
    - @StateObject (only matches in CryptoSwift or comments)
    - @EnvironmentObject (only matches in CryptoSwift or comments)
    - .environmentObject( (only matches in CryptoSwift or comments)
- Build clean.
- Run FernletPersistenceTests, FernletTests, and any other store-related tests.
- DEFER comprehensive smoke testing to Checkpoint C.

FAILURE PROTOCOL
If any view file fails to compile after migration:
1. Do not move to the next file.
2. Read the compiler errors.
3. Most likely cause: a $store. binding in that view requires @Bindable.
4. Fix by changing `var store: FernletStore` to `@Bindable var store: FernletStore`
   in that specific view.
5. Rebuild. If still failing, STOP and report.
```

---

### Checkpoint C — Full integration

**Final gate. The migration is not complete until this passes.**

```
□ Full test suite green across all targets.
□ Project builds clean with no new warnings vs. the baseline from Step 0.
□ Repo-wide forbidden token search returns no production-code matches:
    grep -rn "ObservableObject" Fernlet/Fernlet/   # expect: zero
    grep -rn "@Published" Fernlet/Fernlet/          # expect: zero
    grep -rn "@ObservedObject" Fernlet/Fernlet/     # expect: zero
    grep -rn "@StateObject" Fernlet/Fernlet/        # expect: zero
    grep -rn "@EnvironmentObject" Fernlet/Fernlet/  # expect: zero
    grep -rn "\.environmentObject(" Fernlet/Fernlet/ # expect: zero
  Note: historical planning docs under Fernlet/Docs may still mention legacy tokens.
□ Cold-launch smoke test:
  □ Delete and reinstall on the simulator.
  □ Walk full onboarding.
  □ Land in main app.
□ Every tab smoke test:
  □ Home: log a quick item, confirm UI updates.
  □ Food: log a meal, add a custom ingredient, import a recipe, log a saved recipe.
  □ Move: log a workout, edit a past workout.
  □ Journal: write an entry, edit, delete.
  □ Workshop: add a texture.
  □ Period Tracker: log today, edit a past day.
  □ Social/Private hubs: open both, navigate.
□ Settings smoke test:
  □ Toggle every option. Confirm bindings work.
  □ Open HealthKit section, confirm authorization status.
  □ Open Privacy & Data, toggle iCloud sync, confirm reload.
□ Lock smoke test:
  □ Lock the app. Confirm lock screen.
  □ Unlock. Confirm gate releases.
□ Proximity smoke test:
  □ Open Connection Inspector. Confirm logs display.
  □ If reachable, attempt a peer discovery flow.
□ iCloud sync test (best with two devices, otherwise optional):
  □ Mutate state on device A.
  □ Verify device B receives the change after remote-change reload.
□ git tag pr0-complete
□ Open the PR. Description should reference this plan and list the 13 commits.
```

---

## 5. Failure Recovery

If any step breaks the build or tests:

1. **Don't try to fix forward.** `git reset --hard HEAD` to undo the step's commit.
2. **Read the audit again** for that class — make sure you're handling its §3/§4/§5 concerns correctly.
3. **Re-run the prompt with tighter scope.** If the assistant tried to modify a file outside scope, add an explicit "DO NOT MODIFY" line for that file.
4. **If a view file specifically is failing:** the cause is almost always missing `@Bindable` on a view that uses `$store.something` bindings. Search the file for `$<storeName>.` and change the attribute.
5. **If `import Combine` removal broke something:** add it back. The §6 audit table marks files as "Safe to remove" but `grep` for any remaining Combine API in the file (`AnyCancellable`, `PassthroughSubject`, `.sink`, `AnyPublisher`, `Just`, `Publishers.`) before removing.

If two consecutive retries fail on the same step, stop and have a human read the audit and the file together — there's likely an undocumented constraint.

---

## 6. Done Criteria

PR 0 is done when:

1. All 13 steps committed individually.
2. Checkpoints A, B, C all passed and tagged.
3. The repo-wide forbidden-token grep is clean.
4. Full test suite green.
5. All smoke tests in Checkpoint C completed manually.
6. PR description references this plan and the original migration audit.

After PR 0 ships, the rest of the FernletStore refactor (Phase 1 services, Phase 2 sub-services) follows the v2 plan with one change: every new `@Observable` type can be written directly without any `ObservableObject` consideration. The codebase is now Observation-native.
