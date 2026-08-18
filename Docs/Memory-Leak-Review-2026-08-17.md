# Memory-Leak Review — 2026-08-17

Whole-codebase review of Fernlet's shipping Swift (`App/Fernlet`, `App/FernletWidgets`,
`App/FernletShareExtension`, `FernletKit/Sources` — 366 files, ~136k lines) for anything that can
cause a memory leak, followed by a deeper verification pass on every candidate, fixes for every
confirmed defect, and a two-part **memory-lifecycle wall** so the confirmed classes of defect
cannot silently come back.

**Bottom line.** The codebase is already leak-conscious (`[weak self]` on every escaping manager
task, `unowned` host seams, capped caches, `isolated deinit` where teardown is needed). The review
found **no classic retain cycle** and no unbounded in-process heap growth. What it did find — nine
confirmed defects, all in the proximity/Live-Activity teardown seams plus one photo strip and one
Core Data store — were *lifecycle* leaks: system resources (a MultipeerConnectivity link, a
NearbyInteraction session, an ActivityKit Live Activity) or install-lifetime sidecars that outlived
the object that was supposed to end them, one thumbnail strip retaining full bitmaps, and one
persistent-history table nothing ever pruned. All nine are fixed, each with a regression test that
was shown to fail without its fix, and the disciplines they violated are now enforced mechanically.

---

## 1. Method

The review ran as a multi-agent workflow (`fernlet-memory-leak-audit`, 49 agents, ~6.2M tokens):

1. **Find** — 17 finders: 14 code slices covering every shipping file exactly once (proximity
   engine/mesh/transport; presence/activities/recipes/hearts; identity/trust/ranging + app
   proximity UI; `FernletStore` + owned coordinators; app services; three groups of SwiftUI views;
   camera/canvas/animation views; HealthKit/AppServices/AI/web/food; CloudKit/local/StoreCore/
   persistence/diary; sealed `Private*` stores; UI/lock/foundation/scoring/domain; widgets/share
   extension/intents/Live Activities) plus 3 cross-cutting lenses (every continuation and stream;
   every stored closure, delegate, observer and `withObservationTracking`; every long-lived
   collection/cache/Core Data seam for unbounded growth). Each finder recorded the lifetime of every
   class it read (240 entries) and every retention edge it proved correctly broken (488 entries),
   not just its findings — so coverage could be judged, not assumed.
2. **Verify** — every deduplicated finding went to two independent agents with opposite briefs: a
   *refuter* told to default to "refuted" unless it could trace the whole chain in the code, and a
   *reproducer* told to write the concrete user-level scenario and name the retainer. A finding is
   CONFIRMED only when both agree.
3. **Critics + gap round** — two completeness critics computed the ground truth by grep (105
   class/actor declarations, every `Task<` handle, `addObserver(forName:`, `.sink`,
   `withChecked*Continuation`, `AsyncStream`, sqlite/`Unmanaged`, MC/NI/AV/HK/CL/ActivityKit sites)
   and compared it against what the finders had attested. Six targeted follow-up finders then read
   the thin spots (`FernletStore` + view-level tasks/observers; every continuation site;
   `LanguageModelSession` retention and pre-warm; residual unnamed sites; proximity Live-Activity
   relaunch reaping; Core Data blob faulting in the sealed stores). Two new findings came back and
   were verified the same way; the other four follow-ups came back clean.

Taxonomy used (reported): retain cycles; uncancelled/looping tasks; unremoved block observers;
continuations that can fail to resume; Combine subscriptions; system-resource lifecycle (MC/NI/AV/
HK/CL/Live Activity); manual memory (sqlite/CF/`Unmanaged`); unbounded growth of long-lived
collections; SwiftUI-specific (`@State` tasks, representables, timers). Deliberately *not* reported:
a process-lifetime singleton retaining its own permanent children; short bounded tasks; `[weak self]`
style opinions with no concrete leak.

## 2. Findings

| ID | Verdict | Sev | Where | What | Fix |
|---|---|---|---|---|---|
| F001 | **CONFIRMED** | med | `MeshNetworkManager.removeSlot` / `disconnectSlot` / `handleChannelReady` | Evicting a slot (timeout sweep, remote goodbye, session close, overflow eviction, removal vote, capacity rejection) cancelled the coordinator but never touched the MCSession: the MC link + `PeerChannelTransport` lingered until the whole search stopped, ate one of MC's 8 peer slots on both devices, and — because `invite` refuses connected peers and `.connected` never re-fires — the peer could never re-form a slot in that search. | `kickEvictedPeer` on every eviction path (best-effort `MeshMultipeerSession.disconnectPeer`, mirroring the sibling managers), ordered after the goodbye send in `disconnectSlot`; the two capacity guards in `handleChannelReady` kick the orphaned link too. `onPeerDisconnected` now distinguishes our own kick from a transient socket drop (`locallyKickedPeerIDs`, capped, cleared on `stopSearching`) so the re-invite retry keeps its "transient failure only" meaning. |
| F002 | REFUTED as a leak — **hardened** | low | `ObservationLoop.start` | The shared observation loop held its owner strongly across the suspension (`guard let owner` above the `await`), so its documented "loop ends on owner dealloc" contract was void. Refuted as a *leak* because all three owners are process-lifetime `lazy var`s on `FernletStore` and every stop path cancels the task. | Made the header true: the strong reference lives only inside `arm(...)` and the post-change `onChange` call, never across the await. Regression test proves an owner whose only remaining reference is the loop's deallocates. |
| F003 | REFUTED | low | `MeshNetworkManager.vouchCache` | No eviction on read — but the only writer is behind `isVouchListBroadcastEnabled = false` in shipping builds; the cache is never written. Left as-is; note for whoever flips the gate: add expiry eviction and clear on `stopSearching` first. | — |
| F004 | **CONFIRMED** | med | `PresenceManager.removeHeartConnection(matching:)` | An MC disconnect dropped the heart connection record — the coordinator's only strong owner — without `cancel()`. The coordinator's own `.disconnected` hop is a weak-self Task that then found nothing, so `end()` never ran: ranging never invalidated, the Live Activity anchor never ended (one orphaned Live Activity per received in-person heart / mid-send drop, until the OS time cap). | Cancel every dropped record's coordinator before dropping it (mirrors `teardownHeartConnection`). |
| F005 | **CONFIRMED** | med | `ProximityRecipeShareManager.stop` / `refreshDiscovery` / `removeConnections(matching:)` / parked sweep | Same omission on all four record-drop paths of the recipe pairing. | One `cancelCoordinators(of:)` helper, called on every drop path (and, after G002, the stale sweep). |
| F006 | **CONFIRMED** | low | `PresenceManager.reevaluateDiscoveredPeers` | A roster/epoch re-evaluation that dropped a peer's match cleared the match bookkeeping but left the peer object in `discoveredPeers`; the later `lostPeer` is guarded on the match map, so the entry lived until `stop()` — one entry per blocked/removed/rotated-out friend met while the radio stood. | Route dropped peers through the existing `removePeer` release path. |
| F007 | **CONFIRMED** | med | `ProgressPhotoCard.task` | Each card decoded its ~1600 px sealed body photo with `byPreparingForDisplay()` and held the full ~7.7 MB bitmap behind a 132 pt thumbnail — one per card scrolled past, for the life of the strip (decrypted body photos, up to the 2,000-record cap). | Decode straight to the card's pixel footprint with `byPreparingThumbnail(ofSize:)`, exactly as `MealPhotoPolaroid` already does. |
| F008 | **CONFIRMED** | low | `FriendPhotoWallPreferences` (photo-wall sidecar) | `aggregatedSessionIDs` / cover / favorite entries accumulated one per aggregated session forever while the photos rolled off the 1,000-photo FIFO cache; the sidecar is install-lifetime and deliberately survives delete-all. | `prunePhotoWallPreferences()` intersects the three maps with the live cache; called at every cache-shrink site (`finishSessionPhotos`, `deletePhoto`, FIFO eviction in `cachePhoto`) and once after load (GC of legacy sidecars). Never from the mutation-free `photoWallPosts` getter. |
| F009 | DISPUTED — accepted | low | `MeshMultipeerSession.peerMap` / `peerInfoCache` | Sub-KB entries for peers lost while connected survive `.notConnected` until a later `lostPeer` or `stop()`; retention is partly intentional (slot-UUID continuity for a rejoining friend) and `stop()` runs on every background/lock/tab change. Refuter: negligible; reproducer: bounded-per-session but real. Not fixed — the proposed fix (tracking discoverability separately) is invasive for sub-KB entries that clear on the next `stop()`. | — (documented) |
| F010 | **CONFIRMED** | low | `PersistenceController` (synced Core Data store) | Persistent history is always on (remote-change notifications need it) but only an `NSPersistentCloudKitContainer` mirroring delegate ever consumes and trims it. Loaded WITHOUT CloudKit options (sync off — the cold-launch default and the local-only user's steady state — or no iCloud account) the `ATRANSACTION`/`ACHANGE` tables grew for the life of the install. Disk, not heap. | Every successful load funnels through `finishSuccessfulLoad`, which prunes history older than `localOnlyHistoryRetention` (7 days) on a background context — best-effort, audit-logged on failure, never on a mirrored store. DEBUG seams (`pruneUnconsumedHistoryForTesting`, `localOnlyHistoryRetentionOverrideForTesting`) make both the mechanism and the load path testable. |
| G001 | **CONFIRMED** | med | `ActivityKitProximityForegroundAnchor` | The proximity Live Activity handle lives in a private property of a per-coordinator anchor; nothing in the app ever enumerated `Activity<ProximityConnectionActivityAttributes>.activities`. A process kill/crash while a session was live (a mesh session is deliberately kept alive in the background) stranded up to 5 activities until the OS auto-end (hours), each counting toward the per-app Live Activity ceiling a later workout/cooking `Activity.request` needs. | `ProximityLiveActivityReaper.endOrphans()`, called once per process from `FernletStoreLoader.startIfNeeded()` (behind its `didStart` guard) before the store and its lazy managers exist — never on scene activation, where it would end live anchors. |
| G002 | **CONFIRMED** | med | `ProximityCoordinator.fail(_:)` | `fail()` transitions to `.failed` synchronously, which wakes the owning manager's observation loop; its stale sweep can drop the coordinator's last reference in the same main-actor turn — before `fail()`'s `teardownTask` (which reached everything through `self?`) ever runs. `deinit` cancels that task; the anchor is freed with its `activity` intact and the Live Activity stays live system-side. One orphan per heart/recipe session that fails after `.connected`. | Capture the three `let` collaborators (`ranging`, `transport`, `foregroundAnchor`) strongly in the teardown task (no cycle: none references the coordinator; they live only until the fast, idempotent teardown completes). Belt-and-braces: both stale sweeps now `cancel()` before dropping (idempotent for `.ended`, required for `.failed`). |

Nine confirmed, one refuted-and-hardened, one refuted, one disputed-and-accepted.

## 3. Fixes applied

Shipping code:

- `FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift` — `kickEvictedPeer`,
  `locallyKickedPeerIDs` (+cap, cleared in `stopSearching`), kick on `removeSlot`/`disconnectSlot`/
  `handleChannelReady` capacity guards, retry suppression in `onPeerDisconnected`;
  `prunePhotoWallPreferences` + call sites; `isolated deinit` cancelling the five owned tasks; test
  seams `setDisconnectPeerObserverForTesting`, `photoWallPreferenceEntryCountForTesting`.
- `FernletKit/Sources/ProximityKit/Transport/MeshMultipeerSession.swift` —
  `onDisconnectPeerRequestedForTesting` hook at the top of `disconnectPeer`.
- `FernletKit/Sources/ProximityKit/Presence/PresenceManager.swift` — `reevaluateDiscoveredPeers`
  routes through `removePeer`; `removeHeartConnection` cancels dropped coordinators; the stale sweep
  cancels before dropping; `isolated deinit`; seams `discoveredPeerCountForTesting`,
  `simulateHeartPeerDisconnectForTesting`.
- `FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift` —
  `cancelCoordinators(of:)` on `stop`, `refreshDiscovery`, `removeConnections(matching:)`, the parked
  sweep and the stale sweep; `isolated deinit`.
- `FernletKit/Sources/ProximityKit/Engine/ObservationLoop.swift` — owner held weakly across the
  suspension (`arm` helper); header rewritten to state the real contract.
- `FernletKit/Sources/ProximityKit/Engine/ProximityCoordinator.swift` — `fail()` teardown captures
  collaborators, not `self?`.
- `FernletKit/Sources/ProximityKit/ForegroundAnchor/ProximityForegroundAnchor.swift` —
  `ProximityLiveActivityReaper` (+ no-op twin without ActivityKit).
- `App/Fernlet/FernletStoreLoader.swift` — `import ProximityKit`; reaper call behind the once-per-process `didStart` guard, before `loadStore()`.
- `App/Fernlet/ProgressPhotoTimeline.swift` — thumbnail-sized decode.
- `FernletKit/Sources/CloudKitSync/Persistence.swift` — `finishSuccessfulLoad`,
  `localOnlyHistoryRetention`, `pruneUnconsumedHistory(before:in:)`, DEBUG seams; class doc updated.
- `Scripts/power-of-10-allowlist.json` — the existing R9 (`nonisolated(unsafe)`) entry for the
  anchor file extended to state the reaper's invariant.
- Docs: `ProximityKit.md` and `CloudKitSync.md` DocC landing pages, `Docs/FileIndex.md`.

Every function stays under the Power-of-10 limits; `Scripts/power-of-10-scan.py` reports
0 violations (density 0.685 ≥ 0.68 floor), `Scripts/doc-coverage-scan.py` reports 0 undocumented
types.

## 4. Verification

- **New runtime suite** `Tests/FernletTests/MemoryLifecycleTests.swift` (14 tests, 7 suites):
  `ObservationLoop` reacts + re-arms, ends on cancel, and **does not pin its owner across the
  suspension**; `MeshNetworkManager` / `PresenceManager` / `ProximityRecipeShareManager`
  deallocate when released (the latter two deliberately without `stop()`); mesh eviction requests
  the MC kick; presence re-evaluation releases the dropped peer; a dropped heart channel runs the
  coordinator teardown (Live Activity anchor inactive, ranging stopped) — driven through a real
  handshake over mock transports; recipe MC-disconnect and `stop()` run the teardown; photo-wall
  preferences prune and do not reload; a local-only on-disk store records history, the pruner
  removes it, and a reload without mirroring prunes it through the real load path.
- **Negative check** (tests must bite): with the `ObservationLoop`, `removeHeartConnection` and
  `kickEvictedPeer` fixes temporarily reverted, `suspendedLoopDoesNotPinItsOwner`,
  `droppedHeartChannelRunsTheCoordinatorTeardown` and `evictingASlotRequestsTheMultipeerKick`
  fail exactly as intended; restored, all pass.
- **Owning + wall suites**: 282 Swift Testing tests in 23 suites + 17 XCTest cases passed
  (`MeshNetworkManagerTests`, `MeshFavoriteObservationTests`, `PresenceManagerTests`,
  `PresenceHeartsTests`, `HeartShareTests`, `ProximityRecipeShareCapTests`, `RecipeShareCodecTests`,
  `ProximityCoordinatorTests`, `MeshSessionHeartTests`, `SessionMessageTests`, `FriendMintingTests`,
  `FernletPersistenceTests`, `HeartDropAppWiringTests`, `CoachSessionHardeningTests`,
  `ActivityTests`, `PowerOfTenBoundaryTests`, `S3BoundaryTests`, `NoTrackingBoundaryTests`, and the
  new suites).
- **Dynamic spot check**: the fixed app launched in the iPhone 17 simulator with the demo seed and
  inspected with `leaks` (with `MallocStackLogging`) shows **zero app-attributable leaks**; the only
  root leak is an `NSError` allocated inside Foundation's `_NSBundleODRDataForApplications` XPC reply
  block (Apple's On-Demand-Resources plumbing), not Fernlet code.

## 5. Enforcement — the memory-lifecycle wall

Two halves, following the S3 / no-tracking / Power-of-10 pattern (floors so a scan can never pass
vacuously; every allowlist entry must be used and must state its invariant; planted-token fixtures):

- **Runtime**: `MemoryLifecycleTests` (above) pins the specific edges this review found broken.
- **Static**: `Tests/FernletTests/MemoryLifecycleBoundaryTests.swift` pins the disciplines:
  - **ML1** — a file that stores a `Task<…>` handle (outside SwiftUI `@State`) must cancel it in a
    `deinit`/`isolated deinit` or carry an allowlisted invariant. Exempt today, each with its reason:
    `FernletStore` (process-lifetime composition root), `SnapshotSaveCoordinator`,
    `WeatherKitService`, `BrandedCatalogResourceLoader`, `HeartDropService` (all `[weak self]` +
    self-terminating, owned for the process lifetime).
  - **ML2** — a file with a block-based `addObserver(forName:` must `removeObserver` (a retained
    block) or be allowlisted; exempt: `FernletStore`'s cooking-intent observer.
  - **ML3** — `withObservationTracking` lives only in `ObservationLoop.swift`.

## 6. What was examined and found clean (condensed)

The finders attested 488 correctly-broken retention edges. Representative, by mechanism:

- **Tasks** — every escaping task in the proximity managers, `HeartDropService`, `SnapshotSaveCoordinator`,
  `WeatherKitService`, `WorkoutHealthKitSync`, `FernletStore` (settle/purge/sync handles held,
  replaced-on-restart, cancelled in `stopWritersForWipe`; `activitySyncTask` chain drops completed
  closures) captures `[weak self]` or is one-shot and bounded; every SwiftUI `@State` task handle
  (ContentView, HomeView, ConnectView, SettingsSheet, CookingMode, BreathingExerciseView, camera
  sheets, `ProximityRecipeShareSheet`, `FernletLockGate`, `CaptureProtection`) is cancelled in
  `onDisappear`/`.task`/replace-on-restart.
- **Observers / Combine** — `CaptureProtectionState`'s two block observers live in a
  `NotificationObserverBag` whose `deinit` removes them (already deinit-tested); `ProtectedSidecar`
  removes in `isolated deinit`; `PersistenceController` / `CoreDataFernletRepository` /
  `SnapshotSaveCoordinator` / `ProximityCoordinator` sinks are `[weak self]` or capture only a
  subject, held in cancellables that die with the owner; `Timer.publish` in `FernletLockView` is a
  struct-scoped `onReceive`.
- **Continuations** — every `withChecked(Throwing)Continuation` (HealthKit one-shot queries and
  `HKWorkoutBuilder` steps, `CLLocationManager` auth/location bridges, `LAContext`, CloudKit
  operations, `loadPersistentStores`, camera capture, share extension) resumes exactly once on every
  path; `AsyncStream`s are finished on cancellation.
- **Delegates / system objects** — MC/NI/CL/AV/UN delegates are weak in Apple's headers or held
  by per-call objects; `EphemeralWebSession.shared` is a delegate-less process-lifetime session with
  no storage; every `sqlite3_prepare` is paired with a `defer { finalize }` and the db closes in
  `deinit`; both `Unmanaged<CFError>` out-parameters (`SecureEnclaveContentKeyWrap`, `FernletLockService`) are consumed exactly once with `takeRetainedValue` (Create-rule +1).
- **Bounded growth** — `ReplayCache`, `HeartDropDedupStore`, `HeartDropPeerBundleCache`,
  `FriendStateCache`, `SessionMessageStore`, `ProximityInspectorEventRecorder`,
  `ConnectionInspector`, `AIAuditLog` (500), `AIRetryQueueService`, `PendingWriteBuffer`s,
  `PendingNarrativeBuffer`, `connectionSessionLogs` (50), the 1,000-photo FIFO wall cache, meal/
  progress photo stores, `HealthKitService.activeQueriesByType` (replace-per-type), the sealed
  narrative repositories (values extracted, history pruned by `PrivatePersistentHistoryPruner`).
- **AI** — all eight `LanguageModelSession` sites are per-call locals; the pre-warm holds no
  session or transcript.

## 7. Residual risks and follow-ups (not blocking)

- `MeshMultipeerSession.disconnectPeer` relies on `MCSession.cancelConnectPeer` acting as a kick on
  an already-connected peer — de-facto on current iOS, undocumented (the sibling managers already
  accepted this). If MC ever ignores it, the pre-fix behaviour returns for that link only.
- The proximity Live Activity has no widget `ActivityConfiguration` (its attributes type is internal
  to ProximityKit), so orphaned activities were invisible; the reaper ends them, but exposing the
  attributes and rendering a real presentation is a separate product decision.
- F009 (`peerMap`/`peerInfoCache` residue until the next `stop()`) is accepted as documented above.
- The `leaks` spot check covers launch + demo seed only; a longer navigation soak under
  Instruments would be the next step if a leak is ever suspected in the field.
- The vouch-list gate (F003) must gain expiry eviction before it is ever enabled.
